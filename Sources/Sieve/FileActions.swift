import AppKit
import SieveCore

/// File operations shared by every view. Mutations are undoable where macOS allows it and report errors in a
/// sheet instead of failing silently.
enum FileActions {
    static func open(_ items: [FileItem]) {
        for item in items { NSWorkspace.shared.open(item.url) }
    }

    static func open(_ items: [FileItem], with app: URL) {
        NSWorkspace.shared.open(items.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copyToPasteboard(_ items: [FileItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }

    static func copyPaths(_ items: [FileItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func pasteboardURLs() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func showInFinder(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    static func openTerminal(at directory: String) {
        let config = NSWorkspace.OpenConfiguration()
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: directory, isDirectory: true)], withApplicationAt: terminal, configuration: config)
        }
    }

    static func trash(_ items: [FileItem], window: NSWindow?, undo: UndoManager?) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.recycle(items.map(\.url)) { trashed, error in
            if let error { present(error, window) }
            guard !trashed.isEmpty else { return }
            undo?.registerUndo(withTarget: NSWorkspace.shared) { _ in
                for (original, inTrash) in trashed { try? FileManager.default.moveItem(at: inTrash, to: original) }
            }
            undo?.setActionName(items.count == 1 ? "Move to Trash" : "Move \(items.count) Items to Trash")
        }
    }

    @discardableResult
    static func rename(_ item: FileItem, to newName: String, window: NSWindow?, undo: UndoManager?) -> String? {
        guard !newName.contains("/"), !newName.hasPrefix(".") || item.name.hasPrefix(".") else {
            alert("“\(newName)” can’t be used as a name.", window)
            return nil
        }
        let target = (item.parentPath as NSString).appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(atPath: item.path, toPath: target)
            undo?.registerUndo(withTarget: FileManager.default) { fm in try? fm.moveItem(atPath: target, toPath: item.path) }
            undo?.setActionName("Rename")
            return target
        } catch {
            present(error, window)
            return nil
        }
    }

    static func uniquePath(in directory: String, name: String) -> String {
        let fm = FileManager.default
        var candidate = (directory as NSString).appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            let numbered = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = (directory as NSString).appendingPathComponent(numbered)
            n += 1
        } while fm.fileExists(atPath: candidate)
        return candidate
    }

    static func newFolder(in directory: String, window: NSWindow?, undo: UndoManager?) -> String? {
        let path = uniquePath(in: directory, name: "untitled folder")
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            undo?.registerUndo(withTarget: FileManager.default) { _ in undoCreation(path) }
            undo?.setActionName("New Folder")
            return path
        } catch {
            present(error, window)
            return nil
        }
    }

    static func duplicate(_ items: [FileItem], window: NSWindow?) -> [String] {
        var created: [String] = []
        for item in items {
            let (stem, ext) = item.displayParts
            let target = uniquePath(in: item.parentPath, name: "\(stem) copy\(ext)")
            do { try FileManager.default.copyItem(atPath: item.path, toPath: target); created.append(target) } catch { present(error, window) }
        }
        return created
    }

    /// Copies or moves `urls` into `directory` off the main thread. Moves within one volume are instant renames.
    static func transfer(_ urls: [URL], into directory: String, move: Bool, window: NSWindow?, undo: UndoManager?, done: (() -> Void)? = nil) {
        let dest = URL(fileURLWithPath: directory, isDirectory: true)
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != dest.standardizedFileURL || !move }
        guard !sources.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var done_: [(URL, URL)] = []
            var firstError: Error?
            for src in sources {
                if dest.path.hasPrefix(src.path + "/") || dest.path == src.path { continue } // into itself
                let target = URL(fileURLWithPath: uniquePath(in: directory, name: src.lastPathComponent))
                do {
                    if move { try FileManager.default.moveItem(at: src, to: target) } else { try FileManager.default.copyItem(at: src, to: target) }
                    done_.append((src, target))
                } catch { if firstError == nil { firstError = error } }
            }
            DispatchQueue.main.async {
                if let firstError { present(firstError, window) }
                if !done_.isEmpty {
                    undo?.registerUndo(withTarget: FileManager.default) { fm in
                        for (src, target) in done_.reversed() {
                            if move { try? fm.moveItem(at: target, to: src) } else { undoCreation(target.path) }
                        }
                    }
                    undo?.setActionName(move ? "Move" : "Copy")
                }
                done?()
            }
        }
    }

    /// Finder's rule: dragging within one volume moves, across volumes copies; ⌥ forces copy, ⌘ forces move.
    static func dragOperation(_ info: NSDraggingInfo, to directory: String) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let first = urls.first else { return [] }
        let sameVolume = volume(of: first.path) == volume(of: directory)
        return sameVolume ? .move : .copy
    }

    private static func volume(of path: String) -> String {
        if path.hasPrefix("/Volumes/") { return path.split(separator: "/").prefix(2).joined(separator: "/") }
        return "/"
    }

    /// Undoing "create" never deletes data: an empty folder is removed, anything else goes to the Trash
    /// (the user may have put files into the new folder or edited the copy since).
    private static func undoCreation(_ path: String) {
        if rmdir(path) == 0 { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
    }

    static func present(_ error: Error, _ window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func alert(_ message: String, _ window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func applications(toOpen item: FileItem) -> [URL] {
        Array(NSWorkspace.shared.urlsForApplications(toOpen: item.url).prefix(12))
    }
}
