import Darwin
import Foundation

/// Reader-writer lock: many concurrent searches, short exclusive commits from the builder and FSEvents.
final class RWLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    init() {
        lock = .allocate(capacity: 1)
        pthread_rwlock_init(lock, nil)
    }
    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }
    @inline(__always) func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock); defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
    @inline(__always) func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock); defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}

/// Which folders the index skips. Skipped folders are still listed by name; only their contents are left out.
public struct IndexExclusions: Equatable, Sendable {
    public var names: Set<String>
    public var paths: Set<String>

    public init(names: Set<String>, paths: Set<String>) {
        self.names = names
        self.paths = paths
    }

    public static let defaultNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "DerivedData", ".build", "Pods", ".gradle", ".m2", ".npm",
        ".pnpm-store", ".yarn", ".cache", ".cargo", ".rustup", ".nvm", ".venv", "venv", "__pycache__", ".tox",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".terraform", ".ollama", ".docker", ".Trash",
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", ".vscode-server", ".gem",
    ]

    public static func standard(home: String = NSHomeDirectory()) -> IndexExclusions {
        IndexExclusions(names: defaultNames, paths: [home + "/Library", home + "/.Trash"])
    }

    func excludes(name: String, path: String) -> Bool { names.contains(name) || paths.contains(path) }

    var fingerprint: String { names.sorted().joined(separator: ",") + "|" + paths.sorted().joined(separator: ",") }
}

/// An in-memory index of every file and folder name under a set of roots.
///
/// Storage is columnar (parallel arrays plus two byte buffers) so a million entries cost ~60 MB and a search is
/// a parallel `memmem` over one contiguous buffer of folded names. Entry ids only grow: a child always has a
/// larger id than its parent, which keeps path reconstruction, compaction and cache loading single-pass.
public final class FileIndex: @unchecked Sendable {
    enum Flag {
        static let directory: UInt8 = 1
        static let hidden: UInt8 = 2
        static let package: UInt8 = 4
        static let dead: UInt8 = 8
        static let symlink: UInt8 = 16
        static let root: UInt8 = 32
    }

    public let roots: [String]
    public let exclusions: IndexExclusions

    // Columnar storage, guarded by `lock`.
    var parent: [Int32] = []
    var nameStart: [UInt32] = []
    var nameLen: [UInt16] = []
    var foldStart: [UInt32] = []
    var foldLen: [UInt16] = []
    var flags: [UInt8] = []
    var size: [Int64] = []
    var modified: [UInt32] = []
    var names: [UInt8] = []
    /// Folded names, each followed by a 0 byte so a match can never span two entries.
    var folded: [UInt8] = []
    var dirIDs: [String: Int32] = [:]
    var deadCount = 0

    let lock = RWLock()
    private let stateLock = NSLock()
    private var _version: UInt64 = 0
    private var _isBuilding = false
    /// FSEvents id up to which this index is current; persisted with the cache.
    public var lastEventID: UInt64 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastEventID }
        set { stateLock.lock(); _lastEventID = newValue; stateLock.unlock() }
    }
    private var _lastEventID: UInt64 = 0
    private var _cancelled = false

    /// Stops a running build or walk at the next directory (used when the index is being replaced).
    public func cancel() { stateLock.lock(); _cancelled = true; stateLock.unlock() }
    var isCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _cancelled }

    public init(roots: [String], exclusions: IndexExclusions) {
        self.roots = roots
        self.exclusions = exclusions
    }

    /// Changes every time entries are added or removed; the UI re-runs a visible search when it moves.
    public var version: UInt64 { stateLock.lock(); defer { stateLock.unlock() }; return _version }
    public var isBuilding: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isBuilding }
    public var count: Int { lock.read { parent.count - deadCount } }

    func bumpVersion() { stateLock.lock(); _version &+= 1; stateLock.unlock() }
    private func setBuilding(_ value: Bool) { stateLock.lock(); _isBuilding = value; stateLock.unlock() }

    var fingerprint: String { roots.joined(separator: ":") + "#" + exclusions.fingerprint }

    // MARK: - Building

    /// Walks all roots in parallel and fills the index. Searches may run while this is in progress.
    public func build() {
        setBuilding(true)
        defer { setBuilding(false) }
        var start: [(Int32, String)] = []
        lock.write {
            for root in roots {
                let id = Int32(parent.count)
                appendRaw(parent: -1, name: Array(root.utf8), folded: [], flags: Flag.directory | Flag.root, size: 0, modified: 0)
                dirIDs[root] = id
                start.append((id, root))
            }
        }
        bumpVersion()
        walk(start)
    }

    private struct Batch {
        var names: [UInt8] = []
        var folded: [UInt8] = []
        var nameLens: [UInt16] = []
        var foldLens: [UInt16] = []
        var flags: [UInt8] = []
        var sizes: [Int64] = []
        var mtimes: [UInt32] = []
        /// Local indices of entries to descend into, with their names.
        var descend: [(Int, String)] = []
        var count: Int { flags.count }

        mutating func reset() {
            names.removeAll(keepingCapacity: true); folded.removeAll(keepingCapacity: true)
            nameLens.removeAll(keepingCapacity: true); foldLens.removeAll(keepingCapacity: true)
            flags.removeAll(keepingCapacity: true); sizes.removeAll(keepingCapacity: true)
            mtimes.removeAll(keepingCapacity: true); descend.removeAll(keepingCapacity: true)
        }
    }

    private final class WorkStack: @unchecked Sendable {
        private var items: [(Int32, String)]
        private var active = 0
        private let condition = NSCondition()
        init(_ items: [(Int32, String)]) { self.items = items }

        func pop() -> (Int32, String)? {
            condition.lock(); defer { condition.unlock() }
            while items.isEmpty {
                if active == 0 { condition.broadcast(); return nil }
                condition.wait()
            }
            active += 1
            return items.removeLast()
        }

        func finish(pushing new: [(Int32, String)]) {
            condition.lock()
            items.append(contentsOf: new)
            active -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Parallel depth-first walk from the given (already indexed) directories.
    func walk(_ start: [(Int32, String)]) {
        guard !start.isEmpty else { return }
        let stack = WorkStack(start)
        let workers = max(2, min(12, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var batch = Batch()
            while let (id, path) = stack.pop() {
                if isCancelled { stack.finish(pushing: []); continue }
                batch.reset()
                read(path, into: &batch)
                let subdirs = commit(batch, parentID: id, parentPath: path)
                stack.finish(pushing: subdirs)
            }
        }
    }

    private func read(_ path: String, into batch: inout Batch) {
        try? DirectoryReader.scan(path) { raw in
            var f: UInt8 = 0
            var name: String?
            switch raw.type {
            case .directory:
                f |= Flag.directory
                let n = String(decoding: raw.name, as: UTF8.self)
                name = n
                if raw.name.contains(UInt8(ascii: ".")), PackageTypes.isPackage(extension: FileCategory.pathExtension(of: n)) {
                    f |= Flag.package
                }
            case .symlink: f |= Flag.symlink
            default: break
            }
            if raw.isHidden { f |= Flag.hidden }
            let foldedBefore = batch.folded.count
            TextFold.append(raw.name, to: &batch.folded)
            batch.foldLens.append(UInt16(clamping: batch.folded.count - foldedBefore))
            batch.folded.append(0)
            batch.names.append(contentsOf: raw.name)
            batch.nameLens.append(UInt16(clamping: raw.name.count))
            batch.flags.append(f)
            batch.sizes.append(raw.size)
            batch.mtimes.append(UInt32(clamping: Int64(raw.modified)))
            if let name, f & Flag.package == 0 {
                let full = Self.join(path, name)
                if !exclusions.excludes(name: name, path: full) { batch.descend.append((batch.flags.count - 1, name)) }
            }
        }
    }

    /// Appends a batch read from `parentPath` and returns the new subdirectories to walk.
    private func commit(_ batch: Batch, parentID: Int32, parentPath: String) -> [(Int32, String)] {
        guard batch.count > 0 else { return [] }
        var subdirs: [(Int32, String)] = []
        subdirs.reserveCapacity(batch.descend.count)
        lock.write {
            // A concurrent rescan may have replaced or removed this folder while it was being read.
            let p = Int(parentID)
            guard p < flags.count, flags[p] & Flag.dead == 0, dirIDs[parentPath] == parentID else { return }
            let base = Int32(parent.count)
            var nameOffset = UInt32(names.count)
            var foldOffset = UInt32(folded.count)
            parent.reserveCapacity(parent.count + batch.count)
            for i in 0..<batch.count {
                parent.append(parentID)
                nameStart.append(nameOffset)
                nameLen.append(batch.nameLens[i])
                foldStart.append(foldOffset)
                foldLen.append(batch.foldLens[i])
                nameOffset += UInt32(batch.nameLens[i])
                foldOffset += UInt32(batch.foldLens[i]) + 1
            }
            flags.append(contentsOf: batch.flags)
            size.append(contentsOf: batch.sizes)
            modified.append(contentsOf: batch.mtimes)
            names.append(contentsOf: batch.names)
            folded.append(contentsOf: batch.folded)
            for (local, name) in batch.descend {
                let id = base + Int32(local)
                let path = Self.join(parentPath, name)
                dirIDs[path] = id
                subdirs.append((id, path))
            }
        }
        bumpVersion()
        return subdirs
    }

    private func appendRaw(parent p: Int32, name: [UInt8], folded f: [UInt8], flags fl: UInt8, size s: Int64, modified m: UInt32) {
        parent.append(p)
        nameStart.append(UInt32(names.count)); nameLen.append(UInt16(clamping: name.count))
        foldStart.append(UInt32(folded.count)); foldLen.append(UInt16(clamping: f.count))
        names.append(contentsOf: name); folded.append(contentsOf: f); folded.append(0)
        flags.append(fl); size.append(s); modified.append(m)
    }

    static func join(_ dir: String, _ name: String) -> String { dir == "/" ? "/" + name : dir + "/" + name }

    // MARK: - Live updates

    /// Re-reads the given directories after FSEvents reported changes in them. `subtree` asks for a full
    /// re-walk (the kernel coalesced events and could not say which descendants changed).
    ///
    /// Calls must be serialized with each other and with `build()` (IndexManager runs them all on one queue);
    /// searches may run concurrently with any of them.
    public func applyChanges(_ changes: [(path: String, subtree: Bool)]) {
        var seen = Set<String>()
        for (rawPath, subtree) in changes {
            let path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard seen.insert(path + (subtree ? "#" : "")).inserted, isIndexable(path) else { continue }
            if let id = lock.read({ dirIDs[path] }) {
                rescan(id: id, path: path, subtree: subtree)
            } else {
                // A directory we do not know yet: its parent's listing changed too, rescan that.
                let parentPath = (path as NSString).deletingLastPathComponent
                if let pid = lock.read({ dirIDs[parentPath] }) { rescan(id: pid, path: parentPath, subtree: false) }
            }
        }
        compactIfNeeded()
    }

    private func isIndexable(_ path: String) -> Bool {
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return false }
        for component in path.split(separator: "/") where exclusions.names.contains(String(component)) { return false }
        return !exclusions.paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    private func rescan(id: Int32, path: String, subtree: Bool) {
        var batch = Batch()
        var exists = true
        do {
            try DirectoryReader.scan(path) { _ in }
            read(path, into: &batch)
        } catch let error as DirectoryReader.ReadError {
            // Only "not there" means gone; a folder we may not read (EACCES, TCC) or a transient error
            // (EMFILE) keeps its last known contents.
            guard error.code == ENOENT || error.code == ENOTDIR else { return }
            exists = false
        } catch { return }
        var toWalk: [(Int32, String)] = []
        lock.write {
            guard Int(id) < parent.count, flags[Int(id)] & Flag.dead == 0, dirIDs[path] == id else { return }
            if !exists {
                if flags[Int(id)] & Flag.root == 0 {
                    markDead(Int(id), path: path)
                    propagateDeath(from: lowestNewlyDead)
                    lowestNewlyDead = .max
                    pruneDirectoryMap()
                }
                return
            }
            // Existing live children by name.
            var existing: [String: Int32] = [:]
            parent.withUnsafeBufferPointer { pb in
                flags.withUnsafeBufferPointer { fb in
                    for i in Int(id + 1)..<pb.count where pb[i] == id && fb[i] & Flag.dead == 0 {
                        existing[nameString(i)] = Int32(i)
                    }
                }
            }
            var offset = 0
            var nameOffset = 0
            let descendSet = Set(batch.descend.map(\.0))
            for i in 0..<batch.count {
                let len = Int(batch.foldLens[i]), nlen = Int(batch.nameLens[i])
                let name = String(decoding: batch.names[nameOffset..<nameOffset + nlen], as: UTF8.self)
                let fold = Array(batch.folded[offset..<offset + len])
                defer { offset += len + 1; nameOffset += nlen }
                if let old = existing.removeValue(forKey: name) {
                    let o = Int(old)
                    let sameKind = (flags[o] & Flag.directory) == (batch.flags[i] & Flag.directory)
                    if sameKind && !(subtree && descendSet.contains(i)) {
                        // Unchanged entry: update attributes in place and keep its subtree.
                        flags[o] = batch.flags[i]; size[o] = batch.sizes[i]; modified[o] = batch.mtimes[i]
                        continue
                    }
                    // Replaced (file ↔ folder) or the kernel asked for a full re-walk: drop the old entry and
                    // its whole subtree, then index it again from scratch below.
                    markDead(o, path: Self.join(path, name))
                }
                let newID = Int32(parent.count)
                appendRaw(parent: id, name: Array(name.utf8), folded: fold, flags: batch.flags[i], size: batch.sizes[i], modified: batch.mtimes[i])
                if descendSet.contains(i) {
                    let childPath = Self.join(path, name)
                    dirIDs[childPath] = newID
                    toWalk.append((newID, childPath))
                }
            }
            for (name, old) in existing { markDead(Int(old), path: Self.join(path, name)) }
            if lowestNewlyDead != Int.max {
                propagateDeath(from: lowestNewlyDead)
                lowestNewlyDead = .max
                pruneDirectoryMap()
            }
        }
        bumpVersion()
        walk(toWalk)
    }

    /// Lowest id marked dead since the last propagation (guarded by the write lock).
    private var lowestNewlyDead = Int.max

    /// Called with the write lock held.
    private func markDead(_ i: Int, path: String) {
        guard flags[i] & Flag.dead == 0 else { return }
        flags[i] |= Flag.dead
        deadCount += 1
        lowestNewlyDead = min(lowestNewlyDead, i + 1)
        if flags[i] & Flag.directory != 0 { dirIDs.removeValue(forKey: path) }
    }

    /// Called with the write lock held, after `propagateDeath`: drops map entries of folders that died with
    /// an ancestor, in one pass instead of one prefix scan per dead folder.
    private func pruneDirectoryMap() {
        dirIDs = dirIDs.filter { flags[Int($0.value)] & Flag.dead == 0 }
    }

    /// Called with the write lock held. Marks every descendant of a dead entry dead too, in one forward pass
    /// (a child's id is always larger than its parent's), so counts stay honest and compaction kicks in.
    private func propagateDeath(from first: Int) {
        guard first < parent.count else { return }
        parent.withUnsafeBufferPointer { pb in
            flags.withUnsafeMutableBufferPointer { fb in
                for i in first..<pb.count where fb[i] & Flag.dead == 0 {
                    let p = Int(pb[i])
                    if p >= 0 && fb[p] & Flag.dead != 0 {
                        fb[i] |= Flag.dead
                        deadCount += 1
                    }
                }
            }
        }
    }

    /// Rebuilds the arrays without dead entries once they make up a fifth of the index.
    func compactIfNeeded() {
        let needs = lock.read { deadCount > 20_000 && deadCount * 5 > parent.count }
        if needs { compact() }
    }

    public func compact() {
        lock.write {
            let n = parent.count
            var remap = [Int32](repeating: -1, count: n)
            var np: [Int32] = [], ns: [UInt32] = [], nl: [UInt16] = [], fs: [UInt32] = [], fl: [UInt16] = []
            var nf: [UInt8] = [], nsz: [Int64] = [], nm: [UInt32] = [], nn: [UInt8] = [], nfo: [UInt8] = []
            np.reserveCapacity(n - deadCount); nn.reserveCapacity(names.count); nfo.reserveCapacity(folded.count)
            for i in 0..<n {
                let p = parent[i]
                guard flags[i] & Flag.dead == 0, p < 0 || remap[Int(p)] >= 0 else { continue }
                remap[i] = Int32(np.count)
                np.append(p < 0 ? -1 : remap[Int(p)])
                ns.append(UInt32(nn.count)); nl.append(nameLen[i])
                nn.append(contentsOf: names[Int(nameStart[i])..<Int(nameStart[i]) + Int(nameLen[i])])
                fs.append(UInt32(nfo.count)); fl.append(foldLen[i])
                nfo.append(contentsOf: folded[Int(foldStart[i])..<Int(foldStart[i]) + Int(foldLen[i]) + 1])
                nf.append(flags[i]); nsz.append(size[i]); nm.append(modified[i])
            }
            parent = np; nameStart = ns; nameLen = nl; foldStart = fs; foldLen = fl
            flags = nf; size = nsz; modified = nm; names = nn; folded = nfo
            deadCount = 0
            rebuildDirectoryMap()
        }
        bumpVersion()
    }

    /// Called with the write lock held.
    func rebuildDirectoryMap() {
        var paths = [String?](repeating: nil, count: parent.count)
        var map: [String: Int32] = [:]
        for i in 0..<parent.count where flags[i] & Flag.directory != 0 && flags[i] & (Flag.dead | Flag.package) == 0 {
            let path: String
            if flags[i] & Flag.root != 0 {
                path = nameString(i)
            } else if let pp = paths[Int(parent[i])] {
                path = Self.join(pp, nameString(i))
            } else { continue }
            if parent[i] >= 0 && exclusions.excludes(name: nameString(i), path: path) { continue }
            paths[i] = path
            map[path] = Int32(i)
        }
        dirIDs = map
    }

    /// Called with a lock held.
    @inline(__always) func nameString(_ i: Int) -> String {
        let start = Int(nameStart[i]), len = Int(nameLen[i])
        return names.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[start..<start + len]), as: UTF8.self) }
    }

    // MARK: - Lookups

    public struct Entry: Sendable {
        public let id: Int32
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let isPackage: Bool
        public let isHidden: Bool
        public let size: Int64
        public let modified: Double
    }

    public func id(forDirectory path: String) -> Int32? { lock.read { dirIDs[path] } }

    public func entry(_ id: Int32) -> Entry? { lock.read { unlockedEntry(id) } }

    /// Called with a lock held (pthread read locks must not be taken recursively).
    private func unlockedEntry(_ id: Int32) -> Entry? {
        do {
            let i = Int(id)
            guard i >= 0, i < parent.count, flags[i] & Flag.dead == 0 else { return nil }
            var components: [String] = []
            var a = i
            while a >= 0 {
                if flags[a] & Flag.dead != 0 { return nil }
                components.append(nameString(a))
                a = Int(parent[a])
            }
            var path = components.removeLast()
            for c in components.reversed() { path = Self.join(path, c) }
            let f = flags[i]
            return Entry(id: id, path: path, name: nameString(i), isDirectory: f & Flag.directory != 0,
                         isPackage: f & Flag.package != 0, isHidden: f & Flag.hidden != 0, size: size[i],
                         modified: Double(modified[i]))
        }
    }

    public func entries(_ ids: [Int32]) -> [Entry] { lock.read { ids.compactMap(unlockedEntry) } }

    // MARK: - Search

    public struct Hit: Sendable {
        public let id: Int32
        public let score: Int32
        public init(id: Int32, score: Int32) { self.id = id; self.score = score }
    }

    public struct Outcome: Sendable {
        public var hits: [Hit]
        /// The hits resolved to paths inside the same lock as the search, so they stay valid after compaction.
        public var entries: [Entry] = []
        /// All matches, including those beyond `limit`.
        public var total: Int
        public var seconds: Double
    }

    public struct Options: Sendable {
        /// Only entries inside this folder; nil searches everything. Resolved under the search's own lock.
        public var scopePath: String?
        public var filter: FilterOptions
        public var limit: Int

        public init(scopePath: String? = nil, filter: FilterOptions = FilterOptions(), limit: Int = 2000) {
            self.scopePath = scopePath
            self.filter = filter
            self.limit = limit
        }
    }

    /// Every entry whose name contains all tokens of `query`, best first.
    public func search(_ query: SearchQuery, options: Options) -> Outcome {
        let started = CFAbsoluteTimeGetCurrent()
        guard let scanToken = query.scanToken else { return Outcome(hits: [], total: 0, seconds: 0) }
        let now = Date().timeIntervalSince1970
        return lock.read {
            let n = parent.count
            guard n > 0 else { return Outcome(hits: [], total: 0, seconds: 0) }
            var scope: Int32?
            if let scopePath = options.scopePath {
                guard let id = dirIDs[scopePath] else { return Outcome(hits: [], total: 0, seconds: 0) }
                scope = id
            }
            let chunks = min(max(1, n / 4096), ProcessInfo.processInfo.activeProcessorCount * 3)
            let slots = UnsafeMutablePointer<(hits: [Hit], total: Int)>.allocate(capacity: chunks)
            slots.initialize(repeating: ([], 0), count: chunks)
            defer { slots.deinitialize(count: chunks); slots.deallocate() }

            folded.withUnsafeBufferPointer { fb in
            foldStart.withUnsafeBufferPointer { fs in
            foldLen.withUnsafeBufferPointer { fl in
            parent.withUnsafeBufferPointer { pb in
            flags.withUnsafeBufferPointer { fgb in
            size.withUnsafeBufferPointer { sb in
            modified.withUnsafeBufferPointer { mb in
            names.withUnsafeBufferPointer { nb in
            nameStart.withUnsafeBufferPointer { nsb in
            nameLen.withUnsafeBufferPointer { nlb in
            scanToken.withUnsafeBufferPointer { tok in
                let base = fb.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = n * c / chunks, hi = n * (c + 1) / chunks
                    var p = Int(fs[lo])
                    let end = hi < n ? Int(fs[hi]) : fb.count
                    var hits: [Hit] = []
                    var total = 0
                    var extCache: [String: Set<FileCategory>] = [:]
                    while p < end {
                        guard let m = memmem(base + p, end - p, tok.baseAddress!, tok.count) else { break }
                        let offset = UnsafeRawPointer(m).assumingMemoryBound(to: UInt8.self) - base
                        // The entry whose folded name contains `offset`.
                        var l = lo, h = hi - 1
                        while l < h {
                            let mid = (l + h + 1) >> 1
                            if Int(fs[mid]) <= offset { l = mid } else { h = mid - 1 }
                        }
                        let e = l
                        p = Int(fs[e]) + Int(fl[e]) + 1
                        let f = fgb[e]
                        if f & (Flag.dead | Flag.root) != 0 { continue }
                        if !options.filter.showHidden && f & Flag.hidden != 0 { continue }
                        let nameBuf = UnsafeBufferPointer(rebasing: fb[Int(fs[e])..<Int(fs[e]) + Int(fl[e])])
                        guard query.containsAll(nameBuf) else { continue }
                        // Walk up: drop dead or hidden ancestors, measure depth, check the scope.
                        var a = Int(pb[e]), depth = 0, inScope = scope == nil, ok = true
                        while a >= 0 {
                            if let s = scope, a == Int(s) { inScope = true; break }
                            let af = fgb[a]
                            if af & Flag.dead != 0 || (!options.filter.showHidden && af & Flag.hidden != 0) { ok = false; break }
                            depth += 1
                            a = Int(pb[a])
                        }
                        guard ok, inScope else { continue }
                        let isContainer = f & Flag.directory != 0 && f & Flag.package == 0
                        if !Self.passes(options.filter, isContainer: isContainer, isPackage: f & Flag.package != 0,
                                        size: sb[e], modified: Double(mb[e]), now: now,
                                        name: UnsafeBufferPointer(rebasing: nb[Int(nsb[e])..<Int(nsb[e]) + Int(nlb[e])]),
                                        cache: &extCache) { continue }
                        total += 1
                        let score = query.score(nameBuf, depth: depth, isDirectory: isContainer,
                                                ageDays: (now - Double(mb[e])) / 86400)
                        hits.append(Hit(id: Int32(e), score: score))
                    }
                    slots[c] = (hits, total)
                }
            }}}}}}}}}}}

            var all: [Hit] = []
            var total = 0
            for c in 0..<chunks { all.append(contentsOf: slots[c].hits); total += slots[c].total }
            all.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            if all.count > options.limit { all.removeSubrange(options.limit...) }
            return Outcome(hits: all, entries: all.compactMap { unlockedEntry($0.id) }, total: total,
                           seconds: CFAbsoluteTimeGetCurrent() - started)
        }
    }

    private static func passes(_ filter: FilterOptions, isContainer: Bool, isPackage: Bool, size: Int64, modified: Double,
                               now: Double, name: UnsafeBufferPointer<UInt8>, cache: inout [String: Set<FileCategory>]) -> Bool {
        if !filter.date.matches(modified, now: now) { return false }
        if isContainer { return filter.categories.isEmpty || filter.categories.contains(.folder) }
        if !filter.size.matches(size) { return false }
        guard !filter.categories.isEmpty else { return true }
        var dot = name.count - 1
        while dot > 0 && name[dot] != UInt8(ascii: ".") { dot -= 1 }
        guard dot > 0 else { return false }
        let ext = String(decoding: UnsafeBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self).lowercased()
        let cats: Set<FileCategory>
        if let hit = cache[ext] { cats = hit } else {
            var c = FileCategory.categories(forExtension: ext)
            if isPackage && ext == "app" { c.insert(.app) }
            cache[ext] = c
            cats = c
        }
        return !cats.isDisjoint(with: filter.categories)
    }

    /// Most recently modified files (not folders), newest first.
    public func recentFiles(limit: Int, scopePath: String? = nil, showHidden: Bool = false) -> [Entry] {
        guard limit > 0 else { return [] }
        return lock.read {
            var scope: Int32?
            if let scopePath {
                guard let id = dirIDs[scopePath] else { return [] }
                scope = id
            }
            var top: [(UInt32, Int32)] = []
            var floor: UInt32 = 0
            let now = UInt32(clamping: Int64(Date().timeIntervalSince1970) + 86400)
            for i in 0..<parent.count {
                let f = flags[i]
                guard f & (Flag.dead | Flag.root) == 0, f & Flag.directory == 0 || f & Flag.package != 0,
                      showHidden || f & Flag.hidden == 0 else { continue }
                let m = modified[i]
                guard m > floor, m < now else { continue }
                var a = Int(parent[i]), ok = true, inScope = scope == nil
                while a >= 0 {
                    if let s = scope, a == Int(s) { inScope = true; break }
                    if flags[a] & Flag.dead != 0 || (!showHidden && flags[a] & Flag.hidden != 0) { ok = false; break }
                    a = Int(parent[a])
                }
                guard ok, inScope else { continue }
                top.append((m, Int32(i)))
                if top.count >= limit * 2 {
                    top.sort { $0.0 > $1.0 }
                    top.removeSubrange(limit...)
                    floor = top.last!.0
                }
            }
            top.sort { $0.0 > $1.0 }
            return top.prefix(limit).compactMap { unlockedEntry($0.1) }
        }
    }
}
