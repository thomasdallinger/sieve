import CoreServices
import Foundation

/// Directory-level FSEvents stream. Delivers batches of changed directories, and can replay everything that
/// happened since a stored event id (so a cached index catches up on launch).
public final class FSEventsWatcher: @unchecked Sendable {
    public struct Change: Sendable {
        public let path: String
        /// The kernel dropped detail; re-walk the whole subtree.
        public let subtree: Bool
    }

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let handler: ([Change], UInt64) -> Void
    private let onHistoryDone: (() -> Void)?
    private let lock = NSLock()

    /// `handler` gets the changes and the newest event id of the batch, on `queue` (pass a serial queue to
    /// serialize event handling with other work on the same data).
    public init(paths: [String], since: UInt64?, latency: Double = 0.4, queue: DispatchQueue,
                handler: @escaping ([Change], UInt64) -> Void, onHistoryDone: (() -> Void)? = nil) {
        self.handler = handler
        self.onHistoryDone = onHistoryDone
        self.queue = queue
        // The stream retains the watcher for as long as it can still call back, so a callback never runs on
        // a freed object even if the last outside reference goes away meanwhile.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FSEventsWatcher>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventsWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flagsPointer, idsPointer in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue() as? [String] ?? []
            var changes: [Change] = []
            var newest: UInt64 = 0
            var historyDone = false
            for i in 0..<count {
                let flags = Int(flagsPointer[i])
                newest = max(newest, idsPointer[i])
                if flags & kFSEventStreamEventFlagHistoryDone != 0 { historyDone = true; continue }
                let subtree = flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                if i < paths.count { changes.append(Change(path: paths[i], subtree: subtree)) }
            }
            if !changes.isEmpty { watcher.handler(changes, newest) }
            if historyDone { watcher.onHistoryDone?() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                     since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        // Only reached after stop(): the stream holds a reference while it is alive.
        stop()
    }
}
