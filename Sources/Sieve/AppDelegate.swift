import AppKit
import SieveCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var indexManager: IndexManager
    let model: LocalModel
    private var windows: [BrowserWindowController] = []
    private var settingsWindow: NSWindow?

    override init() {
        let prefs = Preferences.shared
        indexManager = IndexManager(exclusions: prefs.exclusions)
        model = LocalModel(model: prefs.modelName)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        indexManager.start()
        let start = CommandLine.arguments.dropFirst().first { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        makeWindowController(start: start ?? NSHomeDirectory()).showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            if Preferences.shared.aiEnabled, await model.status() == .ready { model.warmUp() }
        }
        #if DEBUG || SCENARIO
        DebugScenario.runIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        indexManager.saveAndStop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { makeWindowController(start: url.path).showWindow(nil) }
    }

    @discardableResult
    func makeWindowController(start: String) -> BrowserWindowController {
        let controller = BrowserWindowController(indexes: { [unowned self] in self.indexManager }, model: model, start: start)
        windows.append(controller)
        return controller
    }

    func windowClosed(_ controller: BrowserWindowController) {
        DispatchQueue.main.async { self.windows.removeAll { $0 === controller } }
    }

    /// Re-creates the index after its roots or exclusions changed.
    func rebuildIndex() {
        indexManager.stop()
        try? FileManager.default.removeItem(at: IndexManager.defaultCacheURL)
        indexManager = IndexManager(exclusions: Preferences.shared.exclusions)
        indexManager.start()
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindowController(start: NSHomeDirectory()).showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let view = SettingsView(prefs: .shared, model: model, indexes: { [unowned self] in self.indexManager },
                                    rebuild: { [weak self] in self?.rebuildIndex() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Sieve Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Don't open with the exclusion list selected for typing.
        settingsWindow?.makeFirstResponder(nil)
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            item.submenu = sub
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], represented: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.representedObject = represented
            return i
        }
        let sep = { NSMenuItem.separator() }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        menu("Sieve", [
            item("About Sieve", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            sep(),
            item("Settings…", #selector(showSettings(_:)), ","),
            sep(),
            item("Hide Sieve", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("Quit Sieve", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("New Window", #selector(newWindow(_:)), "n"),
            item("New Tab", #selector(BrowserWindowController.newWindowForTab(_:)), "t"),
            item("New Folder", #selector(BrowserWindowController.newFolder(_:)), "n", [.command, .shift]),
            sep(),
            item("Open", #selector(BrowserWindowController.openSelection(_:)), "o"),
            item("Open", #selector(BrowserWindowController.openSelection(_:)), down),
            item("Peek", #selector(BrowserWindowController.toggleQuickLook(_:)), "y"),
            item("Reveal in Folder", #selector(BrowserWindowController.revealSelection(_:)), "r"),
            item("Open in Terminal", #selector(BrowserWindowController.openInTerminal(_:))),
            item("Reveal in Finder", #selector(BrowserWindowController.showInFinder(_:))),
            sep(),
            item("Rename", #selector(BrowserWindowController.renameSelection(_:))),
            item("Duplicate", #selector(BrowserWindowController.duplicate(_:)), "d"),
            item("Move to Trash", #selector(BrowserWindowController.moveToTrash(_:)), "\u{8}"),
            item("Pin to Sidebar", #selector(BrowserWindowController.addToSidebar(_:)), "t", [.command, .control]),
            sep(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        // The alternate "Open" (⌘↓) works but stays out of the menu.
        if let file = main.item(withTitle: "File")?.submenu, let alt = file.items.first(where: { $0.keyEquivalent == down }) {
            alt.isHidden = true
            alt.allowsKeyEquivalentWhenHidden = true
        }
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Copy Path", #selector(BrowserWindowController.copyPath(_:)), "c", [.command, .option]),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Move Here", #selector(BrowserWindowController.pasteMove(_:)), "v", [.command, .option]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            sep(),
            item("Find by Name", #selector(BrowserWindowController.focusSearch(_:)), "f"),
        ])
        let sortItems: [NSMenuItem] = SortKey.allCases.map { key in
            item(key.title, #selector(BrowserWindowController.sortBy(_:)), "", [], represented: key.rawValue)
        }
        for (i, key) in [SortKey.name, .kind, .modified, .size].enumerated() {
            sortItems.first { $0.representedObject as? String == key.rawValue }.map { $0.keyEquivalent = "\(i + 1)"; $0.keyEquivalentModifierMask = [.command, .control, .option] }
        }
        let sortMenu = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
        sortMenu.submenu = NSMenu(title: "Sort")
        sortItems.forEach { sortMenu.submenu?.addItem($0) }
        let kindMenu = NSMenuItem(title: "Filter by Kind", action: nil, keyEquivalent: "")
        kindMenu.submenu = NSMenu(title: "Filter by Kind")
        for category in FileCategory.allCases {
            kindMenu.submenu?.addItem(item(category.title, #selector(BrowserWindowController.toggleFilterKind(_:)), "", [], represented: category.rawValue))
        }
        menu("View", [
            item("Columns", #selector(BrowserWindowController.setColumnsView(_:)), "1"),
            item("List", #selector(BrowserWindowController.setListView(_:)), "2"),
            sep(),
            sortMenu,
            kindMenu,
            item("Clear Filters", #selector(BrowserWindowController.clearFilters(_:)), "0", [.command, .option]),
            item("Show Hidden Files", #selector(BrowserWindowController.toggleHidden(_:)), ".", [.command, .shift]),
            item("Show Preview Pane", #selector(BrowserWindowController.togglePreview(_:)), "p", [.command, .option]),
            sep(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        menu("Go", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
            item("Up One Level", #selector(BrowserWindowController.goEnclosing(_:)), up),
            sep(),
            item("Recent Files", #selector(BrowserWindowController.goRecents(_:)), "f", [.command, .shift]),
            item("Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift]),
            item("Desktop", #selector(BrowserWindowController.goDesktop(_:)), "d", [.command, .shift]),
            item("Documents", #selector(BrowserWindowController.goDocuments(_:)), "o", [.command, .shift]),
            item("Downloads", #selector(BrowserWindowController.goDownloads(_:)), "l", [.command, .option]),
            item("Applications", #selector(BrowserWindowController.goApplications(_:)), "a", [.command, .shift]),
            item("Startup Disk", #selector(BrowserWindowController.goComputer(_:)), "c", [.command, .shift]),
            sep(),
            item("Jump to Path…", #selector(BrowserWindowController.goToPath(_:)), "l"),
            item("Jump to Path…", #selector(BrowserWindowController.goToPath(_:)), "g", [.command, .shift]),
        ])
        if let go = main.item(withTitle: "Go")?.submenu, let alt = go.items.last {
            alt.isHidden = true
            alt.allowsKeyEquivalentWhenHidden = true
        }
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(sep())
        windowMenu.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]))
        windowMenu.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]))
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
