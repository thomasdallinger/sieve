import CoreServices
import Darwin
import Foundation

/// Binary on-disk snapshot of a `FileIndex`, so launches start with a warm index and only replay the FSEvents
/// that happened since the snapshot instead of walking the disk again.
///
/// The file is untrusted input: every length is overflow-checked and every structural invariant is verified
/// before the arrays are used. A file that fails any check is deleted and the index is rebuilt.
extension FileIndex {
    private static let magic: UInt32 = 0x5149_5833 // "QIX3"

    /// Identifies the FSEvents database of the volume holding the first root; event ids are only meaningful
    /// against the same database (a restored or migrated disk starts a new one).
    static func eventDatabaseID(for path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }

    public func save(to url: URL) throws {
        // Read the event id first: if changes land while we copy, the arrays are newer than the id and the
        // next launch merely replays a few events twice (applying them is idempotent).
        let eventID = lastEventID
        var data = Data()
        lock.read {
            func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
            func putArray<T>(_ array: [T]) {
                put(UInt64(array.count))
                array.withUnsafeBytes { data.append(contentsOf: $0) }
            }
            put(Self.magic)
            put(eventID)
            put(Date().timeIntervalSince1970)
            putArray(Array(fingerprint.utf8))
            putArray(Array(Self.eventDatabaseID(for: roots.first ?? "/").utf8))
            putArray(parent); putArray(nameStart); putArray(nameLen); putArray(foldStart); putArray(foldLen)
            putArray(flags); putArray(size); putArray(modified); putArray(names); putArray(folded)
            put(UInt64(deadCount))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Loads a snapshot written by `save`. Returns the snapshot's age in seconds, or nil when it is missing,
    /// invalid, or was built with different roots, exclusions or FSEvents database. Invalid files are deleted.
    public func load(from url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        guard let snapshot = Self.decode(data, fingerprint: fingerprint,
                                         eventDatabase: Self.eventDatabaseID(for: roots.first ?? "/")) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        lock.write {
            parent = snapshot.parent; nameStart = snapshot.nameStart; nameLen = snapshot.nameLen
            foldStart = snapshot.foldStart; foldLen = snapshot.foldLen; flags = snapshot.flags
            size = snapshot.size; modified = snapshot.modified; names = snapshot.names; folded = snapshot.folded
            deadCount = snapshot.deadCount
            rebuildDirectoryMap()
        }
        lastEventID = snapshot.eventID
        bumpVersion()
        return Date().timeIntervalSince1970 - snapshot.savedAt
    }

    private struct Snapshot {
        var eventID: UInt64 = 0, savedAt = 0.0
        var parent: [Int32] = [], nameStart: [UInt32] = [], nameLen: [UInt16] = []
        var foldStart: [UInt32] = [], foldLen: [UInt16] = [], flags: [UInt8] = []
        var size: [Int64] = [], modified: [UInt32] = [], names: [UInt8] = [], folded: [UInt8] = []
        var deadCount = 0
    }

    private static func decode(_ data: Data, fingerprint: String, eventDatabase: String) -> Snapshot? {
        var offset = 0
        func get<T>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard data.count - offset >= size else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        func getArray<T>(_: T.Type) -> [T]? {
            guard let raw = get(UInt64.self), let count = Int(exactly: raw) else { return nil }
            let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
            guard !overflow, bytes <= data.count - offset else { return nil }
            defer { offset += bytes }
            return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + bytes]))
                }
                initialized = count
            }
        }
        var s = Snapshot()
        guard get(UInt32.self) == magic, let eventID = get(UInt64.self), let savedAt = get(Double.self),
              let fp = getArray(UInt8.self), String(decoding: fp, as: UTF8.self) == fingerprint,
              let db = getArray(UInt8.self), !eventDatabase.isEmpty, String(decoding: db, as: UTF8.self) == eventDatabase,
              let p = getArray(Int32.self), let ns = getArray(UInt32.self), let nl = getArray(UInt16.self),
              let fs = getArray(UInt32.self), let fl = getArray(UInt16.self), let f = getArray(UInt8.self),
              let sz = getArray(Int64.self), let m = getArray(UInt32.self), let n = getArray(UInt8.self),
              let fo = getArray(UInt8.self), let rawDead = get(UInt64.self), let dead = Int(exactly: rawDead),
              offset == data.count else { return nil }
        s.eventID = eventID; s.savedAt = savedAt
        s.parent = p; s.nameStart = ns; s.nameLen = nl; s.foldStart = fs; s.foldLen = fl; s.flags = f
        s.size = sz; s.modified = m; s.names = n; s.folded = fo; s.deadCount = dead
        return validate(s) ? s : nil
    }

    /// Every invariant the index code relies on without bounds checks.
    private static func validate(_ s: Snapshot) -> Bool {
        let count = s.parent.count
        guard [s.nameStart.count, s.nameLen.count, s.foldStart.count, s.foldLen.count, s.flags.count,
               s.size.count, s.modified.count].allSatisfy({ $0 == count }),
              s.deadCount >= 0, s.deadCount <= count else { return false }
        var expectedFold = 0
        for i in 0..<count {
            let p = Int(s.parent[i])
            let isRoot = s.flags[i] & Flag.root != 0
            // Parents come first; only roots have no parent.
            guard p >= -1, p < i, (p == -1) == isRoot else { return false }
            let ns = Int(s.nameStart[i]), nl = Int(s.nameLen[i])
            guard ns + nl <= s.names.count else { return false }
            // Folded names are contiguous, in id order, each followed by a 0 byte.
            let fs = Int(s.foldStart[i]), fl = Int(s.foldLen[i])
            guard fs == expectedFold, fs + fl < s.folded.count, s.folded[fs + fl] == 0 else { return false }
            expectedFold = fs + fl + 1
        }
        return expectedFold == s.folded.count
    }
}
