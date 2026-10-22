import AppKit
import Combine
import Quartz
import SieveCore
import SwiftUI

/// One browser window: sidebar, view options bar, the current content (columns, list or search) and the path bar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, BrowserHost, NSToolbarDelegate,
    NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    struct Location: Equatable {
        var root: String
        var selected: String?
        /// Keep the keyboard on the selected item instead of moving into a selected folder's contents
        /// (⌘↑ selects the folder you came from).
        var focusSelection = false
    }

    private let indexes: () -> IndexManager
    private let model: LocalModel
    let sidebar = SidebarViewController()
    let columns = ColumnBrowserViewController()
    let list = ListBrowserViewController()
    let search: SearchResultsViewController
    private let contentHost = NSView()
    let locationBar = LocationBar()
    let statusBar = StatusBar()
    private var optionsBar: NSHostingView<ViewOptionsBar>!
    private(set) var current: BrowserContent
    private var searchField: NSSearchField?
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []
    private(set) var location = Location(root: NSHomeDirectory(), selected: nil)
    private var subscriptions: Set<AnyCancellable> = []
    private var isSearching: Bool { current === search }
    private var showingRecents = false

    init(indexes: @escaping () -> IndexManager, model: LocalModel, start: String = NSHomeDirectory()) {
        self.indexes = indexes
        self.model = model
        search = SearchResultsViewController(indexes: indexes, model: model)
        current = columns
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 400)
        window.titlebarSeparatorStyle = .none
        // The location pill in the toolbar names the folder; no separate window title.
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.canvas
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "SieveBrowser"
        // Recomputing the key-view loop for every table row that scrolls in costs more than drawing the row;
        // focus moves are handled explicitly (Tab, arrows, ⌘F).
        window.autorecalculatesKeyViewLoop = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        buildToolbar()
        columns.host = self
        list.host = self
        search.host = self
        search.onSearchTerm = { [weak self] term in self?.setSearchText(term) }
        search.onRevealItem = { [weak self] item in self?.reveal(item) }
        search.onModelAction = { [weak self] in self?.resolveModelProblem() }
        sidebar.onSelect = { [weak self] entry in self?.sidebarSelected(entry) }
        locationBar.onNavigate = { [weak self] path in self?.navigate(to: path) }
        NotificationCenter.default.addObserver(self, selector: #selector(indexDidChange), name: IndexManager.didChange, object: nil)
        indexDidChange()
        observePreferences()
        window.setFrameAutosaveName("SieveBrowserWindow")
        if window.frame.origin == .zero { window.center() }
        setViewMode(Preferences.shared.viewMode, focus: false)
        navigate(to: start, root: start, record: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let content = NSViewController()
        let root = FillView(Theme.canvas)
        content.view = root
        optionsBar = NSHostingView(rootView: ViewOptionsBar(prefs: .shared, searching: false))
        for v in [optionsBar!, contentHost, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            optionsBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            optionsBar.heightAnchor.constraint(equalToConstant: 38),
            contentHost.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "SieveSidebarSplit"
        for vc in [columns, list, search] as [NSViewController] { content.addChild(vc) }
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1180, height: 720))
    }

    private func setContent(_ content: BrowserContent) {
        guard content !== current || contentHost.subviews.isEmpty else { return }
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        current = content
        let v = content.view
        v.frame = contentHost.bounds
        v.autoresizingMask = [.width, .height]
        contentHost.addSubview(v)
        optionsBar.rootView = ViewOptionsBar(prefs: .shared, searching: content === search)
        updateChrome()
    }

    private func observePreferences() {
        let prefs = Preferences.shared
        prefs.$sort.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.columns.applyViewOptions(); self?.list.applyViewOptions() }
        }.store(in: &subscriptions)
        prefs.$searchSort.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.search.applyViewOptions() }
        }.store(in: &subscriptions)
        prefs.$filter.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.columns.applyViewOptions(); self.list.applyViewOptions(); self.search.applyViewOptions()
                self.updateChrome()
            }
        }.store(in: &subscriptions)
        prefs.$showPreview.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.list.updatePreviewVisibility(); self?.search.updatePreviewVisibility() }
        }.store(in: &subscriptions)
        prefs.$favorites.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.sidebar.reloadSections() }
        }.store(in: &subscriptions)
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let location = NSToolbarItem.Identifier("location")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let preview = NSToolbarItem.Identifier("preview")
        static let newFolder = NSToolbarItem.Identifier("newFolder")
        static let search = NSToolbarItem.Identifier("search")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "SieveToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.navigation, ToolbarID.location, .flexibleSpace,
         ToolbarID.viewMode, ToolbarID.preview, ToolbarID.newFolder, ToolbarID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: label)!
        }
        switch id {
        case ToolbarID.location:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = locationBar
            item.label = "Location"
            item.visibilityPriority = .high
            return item
        case ToolbarID.navigation:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [symbol("chevron.left", "Back"), symbol("chevron.right", "Forward")],
                                           selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navigationClicked(_:)))
            group.controlRepresentation = .expanded
            group.isNavigational = true
            group.label = "Back/Forward"
            return group
        case ToolbarID.viewMode:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: ViewMode.allCases.map { symbol($0.symbol, $0.title) },
                                           selectionMode: .selectOne, labels: ViewMode.allCases.map(\.title), target: self,
                                           action: #selector(viewModeClicked(_:)))
            group.label = "View"
            group.toolTip = "Columns (⌘1) or List (⌘2)"
            group.selectedIndex = ViewMode.allCases.firstIndex(of: Preferences.shared.viewMode) ?? 0
            return group
        case ToolbarID.preview:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("sidebar.right", "Preview")
            item.label = "Preview"
            item.toolTip = "Show or hide the preview pane in list and search (⌥⌘P)"
            item.target = self
            item.action = #selector(togglePreview(_:))
            return item
        case ToolbarID.newFolder:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("folder.badge.plus", "New Folder")
            item.label = "New Folder"
            item.toolTip = "New Folder (⇧⌘N)"
            item.target = self
            item.action = #selector(newFolder(_:))
            return item
        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.placeholderString = "Find by name"
            item.preferredWidthForSearchField = 280
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    @objc private func navigationClicked(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { goBack(nil) } else { goForward(nil) }
    }

    @objc private func viewModeClicked(_ sender: NSToolbarItemGroup) {
        setViewMode(ViewMode.allCases[sender.selectedIndex], focus: true)
    }

    private func updateToolbarState() {
        for item in window?.toolbar?.items ?? [] {
            if item.itemIdentifier == ToolbarID.navigation, let group = item as? NSToolbarItemGroup {
                group.subitems[0].isEnabled = !back.isEmpty || isSearching
                group.subitems[1].isEnabled = !forward.isEmpty
            }
            if item.itemIdentifier == ToolbarID.viewMode, let group = item as? NSToolbarItemGroup {
                group.selectedIndex = ViewMode.allCases.firstIndex(of: Preferences.shared.viewMode) ?? 0
            }
        }
    }

    // MARK: Navigation

    /// Opens `path`. Folders show their contents; files are selected inside their folder.
    func navigate(to rawPath: String, root explicitRoot: String? = nil, record: Bool = true) {
        if isSearching || showingRecents { endSearch(restore: false) }
        // Resolve symlinks (/tmp → /private/tmp) so every path component exists as a real folder.
        let path = Self.realPath(rawPath)
        let target = location(for: path, root: explicitRoot)
        if record, target != location { back.append(location); forward.removeAll() }
        apply(target)
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func location(for path: String, root explicitRoot: String?) -> Location {
        if let explicitRoot { return Location(root: explicitRoot, selected: path == explicitRoot ? nil : path) }
        // Columns start at the deepest pinned folder or home that contains the target, or at the current root
        // when that is deeper still (so moving around inside it keeps the columns' context).
        func contains(_ root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
        let candidates = Preferences.shared.favorites + [NSHomeDirectory(), location.root]
        let root = candidates.filter(contains).max { $0.count < $1.count } ?? "/"
        return Location(root: root, selected: path == root ? nil : path)
    }

    private func apply(_ target: Location) {
        location = target
        switch Preferences.shared.viewMode {
        case .columns:
            columns.show(root: target.root, selecting: target.selected, focusSelection: target.focusSelection)
        case .list:
            let path = target.selected ?? target.root
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let item = FileItem.at(path: path)
            if isDir.boolValue && (item?.isContainer ?? true) { list.show(path) } else { list.show((path as NSString).deletingLastPathComponent, selecting: path) }
        }
        updateChrome()
    }

    private func sidebarSelected(_ entry: SidebarViewController.Entry) {
        switch entry {
        case .recents: showRecents()
        case .folder(let path): navigate(to: path, root: path)
        }
    }

    /// The folder you are in: the deepest open column, or the list's folder.
    private var currentFolder: String {
        switch Preferences.shared.viewMode {
        case .columns: return columns.currentDirectory
        case .list: return list.directory
        }
    }

    func setViewMode(_ mode: ViewMode, focus: Bool) {
        let previous = Preferences.shared.viewMode
        let selected = previous == .columns ? columns.selectedPath : list.selectedItems.first?.path
        Preferences.shared.viewMode = mode
        if !isSearching && !showingRecents { setContent(mode == .columns ? columns : list) }
        if previous != mode || contentHost.subviews.isEmpty {
            if mode == .list {
                let folder = previous == .columns ? columns.currentDirectory : location.root
                let file = selected.flatMap { FileItem.at(path: $0) }.flatMap { $0.isContainer ? nil : $0.path }
                list.show(file.map { ($0 as NSString).deletingLastPathComponent } ?? folder, selecting: file)
            } else {
                apply(Location(root: location.root, selected: selected ?? (list.directory == location.root ? nil : list.directory)))
            }
        }
        updateToolbarState()
        if focus { current.focusContent() }
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        handleSearchText(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            if isSearching { search.focusContent() } else { current.focusContent() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField?.stringValue.isEmpty == false { setSearchText("") }
            current.focusContent()
            return true
        default:
            return false
        }
    }

    private func handleSearchText(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            if isSearching { endSearch(restore: true) }
            return
        }
        let folder = showingRecents ? NSHomeDirectory() : (isSearching ? search.folder : currentFolder)
        showingRecents = false
        if !isSearching {
            search.scope = .folder
            setContent(search)
        }
        search.run(text, folder: folder)
        updateChrome()
    }

    func setSearchText(_ text: String) {
        searchField?.stringValue = text
        handleSearchText(text)
    }

    private func endSearch(restore: Bool) {
        searchField?.stringValue = ""
        showingRecents = false
        search.run("", folder: search.folder)
        setContent(Preferences.shared.viewMode == .columns ? columns : list)
        if restore { current.focusContent() }
        updateChrome()
    }

    func showRecents() {
        if isSearching { searchField?.stringValue = "" }
        showingRecents = true
        setContent(search)
        search.showRecents()
        updateChrome()
    }

    /// Leaves search and shows `item` in its folder.
    private func reveal(_ item: FileItem) {
        let path = item.path
        endSearch(restore: false)
        navigate(to: path)
        current.focusContent()
    }

    private func resolveModelProblem() {
        Task { @MainActor in
            let status = await model.status()
            switch status {
            case .serverNotRunning:
                if LocalModel.startServer() {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    search.refreshModelState(await model.status())
                } else {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                }
            case .modelMissing:
                search.refreshModelState(.downloading(0))
                do {
                    let search = self.search
                    try await model.pull { p in
                        DispatchQueue.main.async { search.refreshModelState(.downloading(p)) }
                    }
                    search.refreshModelState(await model.status())
                } catch {
                    search.refreshModelState(.failed(error.localizedDescription))
                }
            default:
                search.refreshModelState(status)
            }
        }
    }

    // MARK: Chrome

    private var chromeUpdateScheduled = false

    /// Coalesces the many selection and location callbacks of one navigation into a single chrome refresh.
    private func updateChrome() {
        guard !chromeUpdateScheduled else { return }
        chromeUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.chromeUpdateScheduled = false
            self?.refreshChrome()
        }
    }

    private func refreshChrome() {
        let folder = isSearching && !showingRecents ? search.folder : currentFolder
        let title: String
        if showingRecents { title = "Recent Files" }
        else if isSearching { title = "Searching “\(search.query.raw)”" }
        else { title = folder == "/" ? SidebarViewController.title(for: "/") : FileManager.default.displayName(atPath: folder) }
        window?.title = title
        window?.representedURL = isSearching ? nil : URL(fileURLWithPath: folder)
        if let window, !isSearching { window.standardWindowButton(.documentIconButton)?.image = IconProvider.shared.icon(forPath: folder) }
        searchField?.placeholderString = "Find by name in \(FileManager.default.displayName(atPath: folder))"
        let selection = current.selectedItems
        let shownPath = selection.count == 1 ? selection[0].path : (isSearching ? folder : (columns.selectedPath.flatMap { _ in selection.first?.path } ?? folder))
        locationBar.show(path: shownPath)
        statusBar.show(status: statusText(folder: folder, selection: selection))
        if !isSearching && !showingRecents {
            sidebar.highlight(Preferences.shared.favorites.contains(location.root) || location.root.hasPrefix("/Volumes/") || location.root == "/"
                              ? .folder(location.root) : nil)
        } else if showingRecents {
            sidebar.highlight(.recents)
        }
        updateToolbarState()
    }

    private func statusText(folder: String, selection: [FileItem]) -> String {
        var parts: [String] = []
        if !isSearching { parts.append(Format.count(current.visibleItemCount, "item")) }
        if selection.count > 0 {
            let bytes = selection.reduce(Int64(0)) { $0 + $1.size }
            parts.append("\(selection.count.formatted()) selected" + (bytes > 0 ? " (\(Format.size(bytes)))" : ""))
        }
        if Preferences.shared.filter.isActive { parts.append("filtered") }
        if let free = Self.freeSpace(at: folder) { parts.append("\(Format.size(free)) available") }
        return parts.joined(separator: "  ·  ")
    }

    private static var freeSpaceCache: (volume: String, bytes: Int64, at: Date)?

    /// Free space of the folder's volume, refreshed at most every 10 seconds.
    private static func freeSpace(at folder: String) -> Int64? {
        let volume = folder.hasPrefix("/Volumes/") ? folder.split(separator: "/").prefix(2).joined(separator: "/") : "/"
        if let c = freeSpaceCache, c.volume == volume, Date().timeIntervalSince(c.at) < 10 { return c.bytes }
        guard let bytes = try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        freeSpaceCache = (volume, bytes, Date())
        return bytes
    }

    // MARK: BrowserHost

    override var undoManager: UndoManager? { window?.undoManager }

    func contentSelectionDidChange() {
        updateChrome()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func contentLocationDidChange() {
        if current === columns, let selected = columns.selectedPath, selected != location.selected {
            location.selected = selected
            location.focusSelection = false
        }
        updateChrome()
    }

    func openItems(_ items: [FileItem]) {
        let folders = items.filter(\.isContainer)
        let files = items.filter { !$0.isContainer }
        FileActions.open(files)
        if let folder = folders.first, files.isEmpty {
            if isSearching || showingRecents { reveal(folder) } else if current === list { navigate(to: folder.path) }
        }
    }

    func quickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func trash(_ items: [FileItem]) {
        FileActions.trash(items, window: window, undo: undoManager)
        if isSearching { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.search.applyViewOptions() } }
    }

    func renameItem(_ item: FileItem, to newName: String) -> String? {
        FileActions.rename(item, to: newName, window: window, undo: undoManager)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = current.selectedItems
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }
        if items.isEmpty {
            add("New Folder", #selector(newFolder(_:)), "n", [.command, .shift])
            add("Paste", #selector(paste(_:)), "v")
            menu.addItem(.separator())
            add("Open in Terminal", #selector(openInTerminal(_:)))
            add("Copy Path of Folder", #selector(copyFolderPath(_:)))
            return
        }
        add("Open", #selector(openSelection(_:)), "o")
        if items.count == 1, !items[0].isContainer {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for app in FileActions.applications(toOpen: items[0]) {
                let entry = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(openWithApp(_:)), keyEquivalent: "")
                entry.representedObject = app
                entry.target = self
                entry.image = IconProvider.shared.icon(forPath: app.path)
                entry.image?.size = NSSize(width: 16, height: 16)
                sub.addItem(entry)
            }
            openWith.submenu = sub
            menu.addItem(openWith)
        }
        add("Peek", #selector(toggleQuickLook(_:)), "y")
        if isSearching { add("Reveal in Folder", #selector(revealSelection(_:)), "r") }
        menu.addItem(.separator())
        if items.count == 1 { add("Rename", #selector(renameSelection(_:))) }
        add("Duplicate", #selector(duplicate(_:)), "d")
        add("Move to Trash", #selector(moveToTrash(_:)), "\u{8}")
        menu.addItem(.separator())
        add(items.count == 1 ? "Copy “\(items[0].name)”" : "Copy \(items.count) Items", #selector(copy(_:)), "c")
        add(items.count == 1 ? "Copy Path" : "Copy Paths", #selector(copyPath(_:)), "c", [.command, .option])
        if !FileActions.pasteboardURLs().isEmpty { add("Paste", #selector(paste(_:)), "v") }
        menu.addItem(.separator())
        if items.allSatisfy(\.isContainer) {
            add("Pin to Sidebar", #selector(addToSidebar(_:)), "t", [.command, .control])
            add("Open in Terminal", #selector(openInTerminal(_:)))
        }
        add("Reveal in Finder", #selector(showInFinder(_:)))
    }

    // MARK: Actions (menus and toolbar)

    private var isEditingText: Bool { window?.firstResponder is NSText }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = current.selectedItems
        switch menuItem.action {
        case #selector(moveToTrash(_:)), #selector(duplicate(_:)), #selector(openSelection(_:)), #selector(copyPath(_:)),
             #selector(toggleQuickLook(_:)), #selector(renameSelection(_:)):
            return !isEditingText && !selection.isEmpty
        case #selector(copy(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)), #selector(pasteMove(_:)):
            return !isEditingText && !FileActions.pasteboardURLs().isEmpty && !isSearching
        case #selector(revealSelection(_:)):
            return isSearching && !selection.isEmpty
        case #selector(goBack(_:)): return !back.isEmpty || isSearching
        case #selector(goForward(_:)): return !forward.isEmpty
        case #selector(goEnclosing(_:)): return !isEditingText && currentFolder != "/"
        case #selector(setColumnsView(_:)):
            menuItem.state = Preferences.shared.viewMode == .columns ? .on : .off
            return true
        case #selector(setListView(_:)):
            menuItem.state = Preferences.shared.viewMode == .list ? .on : .off
            return true
        case #selector(toggleHidden(_:)):
            menuItem.title = Preferences.shared.filter.showHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return true
        case #selector(togglePreview(_:)):
            menuItem.title = Preferences.shared.showPreview ? "Hide Preview Pane" : "Show Preview Pane"
            return true
        case #selector(addToSidebar(_:)):
            return !selection.isEmpty && selection.allSatisfy(\.isContainer)
        default:
            return true
        }
    }

    @objc func openSelection(_ sender: Any?) { openItems(current.selectedItems) }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        FileActions.open(current.selectedItems, with: app)
    }

    @objc func toggleQuickLook(_ sender: Any?) { quickLook() }
    @objc func revealSelection(_ sender: Any?) { if let item = current.selectedItems.first { reveal(item) } }
    @objc func renameSelection(_ sender: Any?) { if let item = current.selectedItems.first { current.beginRename(item.path) } }
    @objc func moveToTrash(_ sender: Any?) { trash(current.selectedItems) }
    @objc func copyPath(_ sender: Any?) { FileActions.copyPaths(current.selectedItems) }
    @objc func copyFolderPath(_ sender: Any?) { FileActions.copyPaths([FileItem.at(path: current.targetDirectory)].compactMap { $0 }) }
    @objc func showInFinder(_ sender: Any?) { FileActions.showInFinder(current.selectedItems) }
    @objc func copy(_ sender: Any?) { FileActions.copyToPasteboard(current.selectedItems) }
    @objc func paste(_ sender: Any?) { transferPasteboard(move: false) }
    @objc func pasteMove(_ sender: Any?) { transferPasteboard(move: true) }

    private func transferPasteboard(move: Bool) {
        let urls = FileActions.pasteboardURLs()
        guard !urls.isEmpty else { return }
        FileActions.transfer(urls, into: current.targetDirectory, move: move, window: window, undo: undoManager)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let folder = current.selectedItems.first(where: \.isContainer)?.path ?? current.targetDirectory
        FileActions.openTerminal(at: folder)
    }

    @objc func addToSidebar(_ sender: Any?) {
        sidebar.addFavorites(current.selectedItems.filter(\.isContainer).map(\.path))
    }

    @objc func newFolder(_ sender: Any?) {
        if isSearching { endSearch(restore: false) }
        let directory = current.targetDirectory
        guard let path = FileActions.newFolder(in: directory, window: window, undo: undoManager) else { return }
        // The folder watcher reloads shortly; rename once the row exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.current.beginRename(path) }
    }

    @objc func duplicate(_ sender: Any?) {
        let created = FileActions.duplicate(current.selectedItems, window: window)
        if let first = created.first, created.count == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.current.beginRename(first) }
        }
    }

    @objc func goBack(_ sender: Any?) {
        if isSearching || showingRecents { endSearch(restore: true); return }
        guard let previous = back.popLast() else { return }
        forward.append(location)
        apply(previous)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forward.popLast() else { return }
        back.append(location)
        apply(next)
    }

    @objc func goEnclosing(_ sender: Any?) {
        // The folder the keyboard is in, so repeated ⌘↑ keeps climbing.
        let folder = Preferences.shared.viewMode == .columns ? columns.targetDirectory : list.directory
        guard folder != "/" else { return }
        let parent = (folder as NSString).deletingLastPathComponent
        let insideRoot = folder != location.root && folder.hasPrefix(location.root == "/" ? "/" : location.root + "/")
        // Show the parent with the folder we came from selected.
        let target = Location(root: insideRoot ? location.root : parent, selected: folder, focusSelection: true)
        if target != location { back.append(location); forward.removeAll() }
        apply(target)
        current.focusContent()
    }

    @objc func goHome(_ sender: Any?) { navigate(to: NSHomeDirectory(), root: NSHomeDirectory()) }
    @objc func goDesktop(_ sender: Any?) { go(NSHomeDirectory() + "/Desktop") }
    @objc func goDocuments(_ sender: Any?) { go(NSHomeDirectory() + "/Documents") }
    @objc func goDownloads(_ sender: Any?) { go(NSHomeDirectory() + "/Downloads") }
    @objc func goApplications(_ sender: Any?) { go("/Applications") }
    @objc func goComputer(_ sender: Any?) { go("/") }
    @objc func goRecents(_ sender: Any?) { showRecents() }
    private func go(_ path: String) { navigate(to: path, root: path); current.focusContent() }

    @objc func goToPath(_ sender: Any?) { locationBar.beginEditing() }

    @objc private func indexDidChange() {
        let main = indexes().main
        statusBar.showIndex(names: main.count, building: main.isBuilding)
    }
    @objc func focusSearch(_ sender: Any?) { if let searchField { window?.makeFirstResponder(searchField) } }
    @objc func setColumnsView(_ sender: Any?) { setViewMode(.columns, focus: true) }
    @objc func setListView(_ sender: Any?) { setViewMode(.list, focus: true) }
    @objc func toggleHidden(_ sender: Any?) { Preferences.shared.filter.showHidden.toggle() }
    @objc func togglePreview(_ sender: Any?) { Preferences.shared.showPreview.toggle() }
    @objc func toggleFilterKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let category = FileCategory(rawValue: raw) else { return }
        let prefs = Preferences.shared
        prefs.filter.categories = prefs.filter.categories == [category] ? [] : [category]
    }
    @objc func clearFilters(_ sender: Any?) { Preferences.shared.filter.clear() }
    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        if isSearching { Preferences.shared.searchSort.select(key) } else { Preferences.shared.sort.select(key) }
    }

    @objc override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        let controller = (NSApp.delegate as? AppDelegate)?.makeWindowController(start: currentFolder)
        if let tab = controller?.window {
            window.addTabbedWindow(tab, ordered: .above)
            tab.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Quick Look panel

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { current.selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = current.selectedItems
        return index < items.count ? items[index].url as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move the selection in the window.
        if event.type == .keyDown, let responder = window?.firstResponder as? NSView {
            responder.keyDown(with: event)
            return true
        }
        return false
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window { current.focusContent() }
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }
}
