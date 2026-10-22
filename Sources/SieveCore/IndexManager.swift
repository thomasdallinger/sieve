import Foundation

/// Owns the persistent home index (cache on disk, FSEvents to stay current) and short-lived indexes for folders
/// outside it, such as external drives or ~/Library.
public final class IndexManager: @unchecked Sendable {
    public static let didChange = Notification.Name("SieveIndexDidChange")

    public let main: FileIndex
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "sieve.index", qos: .utility)
    private let lock = NSLock()
    private var watcher: FSEventsWatcher?
    /// Ad-hoc indexes; `built` is nil until the walk has finished.
    private var adHoc: [(path: String, index: FileIndex, built: Date?)] = []
    private var notifyScheduled = false
    private var dirty = false
    private var stopped = false
    /// SIEVE_LOG_EVENTS=1 prints every change batch (for diagnosing index churn).
    private let logEvents = ProcessInfo.processInfo.environment["SIEVE_LOG_EVENTS"] != nil

    private let queueKey = DispatchSpecificKey<Bool>()

    public init(roots: [String] = IndexManager.defaultRoots, exclusions: IndexExclusions = .standard(),
                cacheURL: URL = IndexManager.defaultCacheURL) {
        main = FileIndex(roots: roots, exclusions: exclusions)
        self.cacheURL = cacheURL
        queue.setSpecific(key: queueKey, value: true)
    }

    public static var defaultRoots: [String] {
        [NSHomeDirectory(), "/Applications", "/System/Applications"].filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.thomasdallinger.sieve/index.bin")
    }

    /// Loads the cached index (or walks the disk the first time) and starts watching for changes.
    ///
    /// Every mutation of `main` (initial build, history replay, live events, saves) runs on the one serial
    /// `queue`: the FSEvents stream delivers there too, so events that arrive during a build simply wait
    /// until the build is done.
    public func start() {
        queue.async { [self] in
            if main.load(from: cacheURL) != nil {
                postChange()
                // Replays everything since the snapshot, then keeps streaming live changes.
                startWatcher(since: main.lastEventID)
            } else {
                let since = FSEventsWatcher.currentEventID
                startWatcher(since: since)
                let progress = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                progress.schedule(deadline: .now() + 0.25, repeating: 0.25)
                progress.setEventHandler { [weak self] in self?.postChange() }
                progress.resume()
                main.build()
                progress.cancel()
                guard !isStopped else { return }
                main.lastEventID = since
                postChange()
                save()
            }
        }
        // Keep the snapshot fresh so a crash or force quit loses little.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in
            guard let self, self.takeDirty() else { return }
            self.save()
        }
        timer.resume()
        saveTimer = timer
    }
    private var saveTimer: DispatchSourceTimer?

    private func startWatcher(since: UInt64) {
        watcher = FSEventsWatcher(paths: main.roots, since: since, queue: queue, handler: { [weak self] changes, newest in
            guard let self, !self.isStopped else { return }
            if self.logEvents {
                for c in changes { print("[fsevents] \(c.subtree ? "SUBTREE " : "")\(c.path)") }
            }
            self.main.applyChanges(changes.map { ($0.path, $0.subtree) })
            self.main.lastEventID = max(self.main.lastEventID, newest)
            self.lock.withLock { self.dirty = true }
            self.postChange()
        })
    }

    private var isStopped: Bool { lock.withLock { stopped } }
    private func takeDirty() -> Bool { lock.withLock { defer { dirty = false }; return dirty } }

    /// Writes the snapshot. Safe from any thread; runs after any change that is being applied right now.
    public func save() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try? main.save(to: cacheURL)
        } else {
            queue.sync { try? main.save(to: cacheURL) }
        }
    }

    /// Saves (unless the first build is still running) and stops watching. Used on quit.
    public func saveAndStop() {
        lock.withLock { stopped = true }
        main.cancel()
        saveTimer?.cancel()
        let watcher = self.watcher
        queue.async { watcher?.stop() }
        // A cancelled first build leaves a partial index; never write that over a good snapshot.
        if main.lastEventID != 0 { save() }
    }

    /// Stops everything without saving (the index is being replaced).
    public func stop() {
        lock.withLock { stopped = true }
        main.cancel()
        saveTimer?.cancel()
        let watcher = self.watcher
        queue.async { watcher?.stop() }
        lock.withLock { adHoc.forEach { $0.index.cancel() } }
    }

    /// Coalesces change notifications to at most five per second, delivered on the main queue.
    private func postChange() {
        lock.lock()
        if notifyScheduled { lock.unlock(); return }
        notifyScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            lock.lock(); notifyScheduled = false; lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// The index and scope to search for "everything inside `directory`". Folders outside the main index get
    /// their own index, built on demand and searchable while it builds. `refresh` (a new search, not a re-run
    /// triggered by index changes) rebuilds an ad-hoc index that finished more than two minutes ago.
    public func target(for directory: String, refresh: Bool = false) -> (index: FileIndex, scopePath: String?) {
        if main.id(forDirectory: directory) != nil { return (main, directory) }
        lock.lock()
        if let i = adHoc.firstIndex(where: { $0.path == directory }) {
            let entry = adHoc[i]
            let stale = entry.built.map { Date().timeIntervalSince($0) > 120 } ?? false
            if !(refresh && stale) {
                lock.unlock()
                return (entry.index, directory)
            }
            adHoc.remove(at: i)
        }
        let index = FileIndex(roots: [directory], exclusions: IndexExclusions(names: main.exclusions.names, paths: []))
        adHoc.insert((directory, index, nil), at: 0)
        if adHoc.count > 3 { adHoc.removeLast().index.cancel() }
        lock.unlock()
        let progress = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        progress.schedule(deadline: .now() + 0.15, repeating: 0.15)
        progress.setEventHandler { [weak self] in self?.postChange() }
        progress.resume()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            index.build()
            progress.cancel()
            guard let self else { return }
            self.lock.withLock {
                if let i = self.adHoc.firstIndex(where: { $0.index === index }) { self.adHoc[i].built = Date() }
            }
            self.postChange()
        }
        // The root entry exists as soon as build() has started; wait briefly so the scope resolves.
        let deadline = Date().addingTimeInterval(0.2)
        while index.id(forDirectory: directory) == nil && Date() < deadline { usleep(1000) }
        return (index, directory)
    }
}
