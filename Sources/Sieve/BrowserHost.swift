import AppKit
import SieveCore

/// What a content view (columns, list, search results) needs from its window.
protocol BrowserHost: AnyObject {
    var window: NSWindow? { get }
    var undoManager: UndoManager? { get }
    func contentSelectionDidChange()
    func contentLocationDidChange()
    func openItems(_ items: [FileItem])
    func quickLook()
    func trash(_ items: [FileItem])
    func makeContextMenu() -> NSMenu
    func renameItem(_ item: FileItem, to newName: String) -> String?
}

/// The views a window can show in its content area.
protocol BrowserContent: NSViewController {
    var selectedItems: [FileItem] { get }
    /// Folder new items and pastes go into.
    var targetDirectory: String { get }
    /// Items shown for the current folder (after filters), for the status bar.
    var visibleItemCount: Int { get }
    func focusContent()
    func applyViewOptions()
    func beginRename(_ path: String)
}

/// Pastes and drops into folders, shared by all tables.
enum DropSupport {
    static func validate(_ info: NSDraggingInfo, directory: String?) -> NSDragOperation {
        guard let directory else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty || urls.contains(where: { directory == $0.path || directory.hasPrefix($0.path + "/") }) { return [] }
        return FileActions.dragOperation(info, to: directory)
    }

    static func accept(_ info: NSDraggingInfo, directory: String, host: BrowserHost?) -> Bool {
        let op = validate(info, directory: directory)
        guard !op.isEmpty else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        FileActions.transfer(urls, into: directory, move: op == .move, window: host?.window, undo: host?.undoManager)
        return true
    }
}

/// Watches one directory for changes to its listing (create, delete, rename) and calls back on the main queue.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending = false

    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !self.pending else { return }
            // Coalesce bursts (a copy of 500 files) into one reload.
            self.pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.pending = false
                onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
