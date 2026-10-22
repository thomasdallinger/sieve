import AppKit
import SieveCore

/// Sidebar: Recent Files (from the index), Pinned folders (drag folders in to pin) and mounted Drives.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum Entry: Equatable {
        case recents
        case folder(String)
    }

    final class Section {
        let title: String
        var entries: [Entry]
        init(_ title: String, _ entries: [Entry]) { self.title = title; self.entries = entries }
    }

    final class Node: NSObject {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }

    var onSelect: ((Entry) -> Void)?
    private let outline = NSOutlineView()
    private var sections: [Section] = []
    private var nodes: [[Node]] = []
    private var suppressSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 30
        outline.indentationPerLevel = 0
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.focusRingType = .none
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // A solid panel instead of the translucent system sidebar.
        let panel = FillView(Theme.sidebar)
        scroll.frame = panel.bounds
        scroll.autoresizingMask = [.width, .height]
        panel.addSubview(scroll)
        view = panel
        reloadSections()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func volumesChanged() { reloadSections() }

    func reloadSections() {
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable ?? true }
            .map(\.path)
        sections = [
            Section("", [.recents]),
            Section("Pinned", Preferences.shared.favorites.filter { FileManager.default.fileExists(atPath: $0) }.map { .folder($0) }),
            Section("Drives", volumes.map { .folder($0) }),
        ]
        nodes = sections.map { $0.entries.map(Node.init) }
        let selected = selectedEntry
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
        if let selected { highlight(selected) }
    }

    private var selectedEntry: Entry? { (outline.item(atRow: outline.selectedRow) as? Node)?.entry }

    /// Marks the entry for `path` without triggering navigation (used when the location changes elsewhere).
    func highlight(_ entry: Entry?) {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let entry else { outline.deselectAll(nil); return }
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? Node)?.entry == entry {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            return
        }
        outline.deselectAll(nil)
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        if let s = item as? Section, let i = sections.firstIndex(where: { $0 === s }) { return nodes[i].count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        let i = sections.firstIndex { $0 === (item as! Section) }!
        return nodes[i][index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Node }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? Section {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = NSAttributedString(string: section.title.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .kern: 0.9, .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            cell.textField = label
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        }
        guard let node = item as? Node else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("SidebarCell"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("SidebarCell")
            let image = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            c.imageView = image
            c.textField = label
            for v in [image, label] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        switch node.entry {
        case .recents:
            cell.textField?.stringValue = "Recent Files"
            cell.imageView?.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        case .folder(let path):
            cell.textField?.stringValue = Self.title(for: path)
            cell.imageView?.image = NSImage(systemSymbolName: Self.symbol(for: path), accessibilityDescription: nil)
        }
        cell.textField?.font = .systemFont(ofSize: 13)
        let row = outlineView.row(forItem: item)
        colorCell(cell, selected: row >= 0 && row == outlineView.selectedRow)
        return cell
    }

    static func title(for path: String) -> String {
        if path == "/" { return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD" }
        if path == NSHomeDirectory() { return NSUserName() }
        return FileManager.default.displayName(atPath: path)
    }

    static func symbol(for path: String) -> String {
        let home = NSHomeDirectory()
        switch path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case home + "/Pictures": return "photo"
        case home + "/Movies": return "film"
        case home + "/Music": return "music.note"
        case "/Applications": return "square.grid.2x2"
        case "/": return "internaldrive"
        default: return path.hasPrefix("/Volumes/") ? "externaldrive" : "folder"
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        item is Section ? nil : SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let section = item as? Section else { return 30 }
        return section.title.isEmpty ? 8 : 30
    }

    /// The selected entry reads in the accent (icon and text); the rest stays neutral.
    private func colorCell(_ cell: NSTableCellView, selected: Bool) {
        cell.imageView?.contentTintColor = selected ? Theme.accentText : .secondaryLabelColor
        cell.textField?.textColor = selected ? Theme.accentText : .labelColor
    }

    private func refreshSelectionColors() {
        for row in 0..<outline.numberOfRows {
            guard outline.item(atRow: row) is Node,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { continue }
            colorCell(cell, selected: row == outline.selectedRow)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshSelectionColors()
        guard !suppressSelection, let entry = selectedEntry else { return }
        onSelect?(entry)
    }

    // Drop folders onto Favorites to pin them.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.contains(where: { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return [] }
        outlineView.setDropItem(sections[1], dropChildIndex: sections[1].entries.count)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.path)
        addFavorites(folders)
        return !folders.isEmpty
    }

    func addFavorites(_ paths: [String]) {
        var favorites = Preferences.shared.favorites
        for p in paths where !favorites.contains(p) { favorites.append(p) }
        Preferences.shared.favorites = favorites
        reloadSections()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, case .folder(let path) = node.entry,
              Preferences.shared.favorites.contains(path) else { return }
        let item = NSMenuItem(title: "Unpin", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = path
        menu.addItem(item)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Preferences.shared.favorites.removeAll { $0 == path }
        reloadSections()
    }
}

/// Sidebar selection: always the soft accent pill, wherever the keyboard focus is.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.accentSoft.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: Theme.rowRadius, yRadius: Theme.rowRadius).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
