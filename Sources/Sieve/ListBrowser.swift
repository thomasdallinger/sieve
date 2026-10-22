import AppKit
import SieveCore

/// List view: one folder as an outline with sortable columns. Clicking a header uses the same sort rule as the
/// toolbar menu (new key → its natural direction, same key → flip), so both controls always agree.
final class ListBrowserViewController: NSViewController, BrowserContent, NSOutlineViewDataSource, NSOutlineViewDelegate, FileTableKeyHandler {
    weak var host: BrowserHost?
    private let outline = FileOutlineView()
    private var scroll: NSScrollView!
    private var split = NSSplitView()
    private let preview = PreviewPane()
    private var previewCard: NSView!
    private(set) var directory = NSHomeDirectory()
    private var roots: [FileItem] = []
    private var listings: [String: [FileItem]] = [:]
    private var watchers: [String: DirectoryWatcher] = [:]
    private var error: String?

    private static let columns: [(id: String, title: String, width: CGFloat, key: SortKey)] = [
        ("name", "Name", 340, .name), ("modified", "Date Modified", 150, .modified), ("size", "Size", 84, .size),
        ("kind", "Kind", 140, .kind), ("added", "Date Added", 150, .added),
    ]

    override func loadView() {
        for spec in Self.columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.id == "name" ? 160 : 60
            if spec.id == "size" { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if spec.id == "name" { outline.outlineTableColumn = column }
        }
        styleFileTable(outline)
        outline.usesAlternatingRowBackgroundColors = false
        outline.dataSource = self
        outline.delegate = self
        outline.keyHandler = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.autosaveName = "SieveListColumns"
        outline.autosaveTableColumns = true
        outline.indentationPerLevel = 14
        outline.menu = host?.makeContextMenu()
        scroll = makeScrollView(for: outline)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(onCard(scroll, inset: NSEdgeInsets(top: 0, left: Theme.cardGap, bottom: Theme.cardGap, right: Theme.cardGap / 2)))
        previewCard = onCard(preview, inset: NSEdgeInsets(top: 0, left: Theme.cardGap / 2, bottom: Theme.cardGap, right: Theme.cardGap))
        split.addArrangedSubview(previewCard)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        view = split
        NotificationCenter.default.addObserver(self, selector: #selector(iconLoaded(_:)), name: IconProvider.didLoad, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        outline.menu = host?.makeContextMenu()
        updatePreviewVisibility()
    }

    private var placedDivider = false

    override func viewDidLayout() {
        super.viewDidLayout()
        if !placedDivider, split.bounds.width > 0 { placedDivider = true; updatePreviewVisibility() }
    }

    func updatePreviewVisibility() {
        // Options can change before this view was ever shown; there is nothing to lay out yet.
        guard isViewLoaded else { return }
        previewCard.isHidden = !Preferences.shared.showPreview
        split.adjustSubviews()
        if !previewCard.isHidden, previewCard.frame.width < 200 || previewCard.frame.width > split.bounds.width * 0.4 {
            split.setPosition(max(300, split.bounds.width - 320), ofDividerAt: 0)
        }
    }

    func show(_ path: String, selecting: String? = nil) {
        directory = path
        listings = [:]
        watchers = [:]
        load(path)
        roots = listings[path] ?? []
        outline.reloadData()
        updateSortIndicators()
        if let selecting, let item = roots.first(where: { $0.path == selecting }) {
            let row = outline.row(forItem: item)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
        }
        host?.contentLocationDidChange()
    }

    private func load(_ path: String) {
        let prefs = Preferences.shared
        var all: [FileItem] = []
        do {
            all = try DirectoryListing.load(path)
            if path == directory { error = nil }
        } catch let e as DirectoryReader.ReadError {
            if path == directory { error = e.isPermissionDenied ? "No permission to read this folder" : "Can’t read this folder" }
        } catch {}
        let now = Date().timeIntervalSince1970
        listings[path] = prefs.sort.sorted(all.filter { prefs.filter.matches($0, browsing: true, now: now) })
        if path == directory {
            outline.emptyMessage = error ?? (all.isEmpty ? "Nothing here" : listings[path]!.isEmpty ? "Filtered out" : nil)
        }
        if watchers[path] == nil {
            watchers[path] = DirectoryWatcher(path: path) { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let selected = Set(selectedItems.map(\.path))
        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileItem }.filter { outline.isItemExpanded($0) }.map(\.path)
        let loaded = Array(listings.keys)
        listings = [:]
        for path in loaded where path == directory || expanded.contains(path) { load(path) }
        roots = listings[directory] ?? []
        outline.reloadData()
        for path in expanded { if let item = findItem(path) { outline.expandItem(item) } }
        let rows = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? FileItem).map { selected.contains($0.path) } ?? false })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    private func findItem(_ path: String) -> FileItem? {
        for row in 0..<outline.numberOfRows { if let item = outline.item(atRow: row) as? FileItem, item.path == path { return item } }
        return nil
    }

    @objc private func iconLoaded(_ note: Notification) {
        guard let p = note.object as? String, let item = findItem(p) else { return }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    // MARK: BrowserContent

    var selectedItems: [FileItem] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileItem } }
    var targetDirectory: String { directory }
    var visibleItemCount: Int { roots.count }
    func focusContent() {
        view.window?.makeFirstResponder(outline)
        if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
    }
    func applyViewOptions() {
        guard isViewLoaded else { return }
        refresh()
        updateSortIndicators()
        updatePreviewVisibility()
    }
    func beginRename(_ path: String) {
        if findItem(path) == nil { refresh() }
        guard let item = findItem(path) else { return }
        let row = outline.row(forItem: item)
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView)?.beginRename()
    }

    private func updateSortIndicators() {
        let sort = Preferences.shared.sort
        for column in outline.tableColumns {
            let key = Self.columns.first { $0.id == column.identifier.rawValue }?.key
            outline.setIndicatorImage(key == sort.key ? NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil, in: column)
        }
        outline.highlightedTableColumn = outline.tableColumns.first { col in Self.columns.first { $0.id == col.identifier.rawValue }?.key == sort.key }
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? FileItem else { return }
        host?.openItems([item])
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? FileItem else { return roots.count }
        if listings[item.path] == nil { load(item.path) }
        return listings[item.path]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? FileItem else { return roots[index] }
        return listings[item.path]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileItem)?.isContainer ?? false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileItem, let id = tableColumn?.identifier.rawValue else { return nil }
        if id == "name" {
            let cell = outlineView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? FileCellView()
            cell.configure(item)
            cell.onRenameCommit = { [weak self] item, name in
                guard let self, let newPath = self.host?.renameItem(item, to: name) else { return }
                self.refresh()
                if let renamed = self.findItem(newPath) { self.outline.selectRowIndexes([self.outline.row(forItem: renamed)], byExtendingSelection: false) }
            }
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("text-" + id)
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TextCell
            ?? TextCell(identifier: identifier, font: id == "kind" ? .systemFont(ofSize: 12) : Theme.monoDigits,
                        alignment: id == "size" ? .right : .left, truncation: .byTruncatingTail)
        let field = cell.label
        switch id {
        case "modified": field.stringValue = Format.date(item.modified)
        case "added": field.stringValue = item.added > 0 ? Format.date(item.added) : "—"
        case "size": field.stringValue = item.isContainer ? "—" : Format.size(item.size)
        case "kind": field.stringValue = Format.kind(item)
        default: break
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SieveRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selection = selectedItems
        if selection.isEmpty { preview.clear() } else { preview.show(selection) }
        host?.contentSelectionDidChange()
    }

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        guard let key = Self.columns.first(where: { $0.id == tableColumn.identifier.rawValue })?.key else { return }
        Preferences.shared.sort.select(key)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        tableColumn?.identifier.rawValue == "name" ? (item as? FileItem)?.name : nil
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileItem)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let folder = item as? FileItem, folder.isContainer, index == NSOutlineViewDropOnItemIndex {
            return DropSupport.validate(info, directory: folder.path)
        }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return DropSupport.validate(info, directory: directory)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let target = (item as? FileItem).flatMap { $0.isContainer ? $0.path : nil } ?? directory
        return DropSupport.accept(info, directory: target, host: host)
    }

    // MARK: Keys

    func fileTableMoveRight(_ table: NSTableView) -> Bool {
        for item in selectedItems where item.isContainer { outline.expandItem(item) }
        return true
    }

    func fileTableMoveLeft(_ table: NSTableView) -> Bool {
        for item in selectedItems {
            if outline.isItemExpanded(item) { outline.collapseItem(item) }
            else if let parent = outline.parent(forItem: item) {
                outline.selectRowIndexes([outline.row(forItem: parent)], byExtendingSelection: false)
            }
        }
        return true
    }

    func fileTableOpen(_ table: NSTableView) { host?.openItems(selectedItems) }
    func fileTableRename(_ table: NSTableView) { if selectedItems.count == 1 { beginRename(selectedItems[0].path) } }
    func fileTableQuickLook(_ table: NSTableView) { host?.quickLook() }
    func fileTableTrash(_ table: NSTableView) { host?.trash(selectedItems) }
}

final class FileOutlineView: NSOutlineView {
    weak var keyHandler: FileTableKeyHandler?
    var emptyMessage: String? { didSet { needsDisplay = true } }

    // Same keys as FileTableView (NSOutlineView cannot inherit from it).
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        switch event.keyCode {
        case 123 where !cmd: _ = keyHandler?.fileTableMoveLeft(self); return
        case 124 where !cmd: _ = keyHandler?.fileTableMoveRight(self); return
        case 125 where cmd: keyHandler?.fileTableOpen(self); return
        case 36, 76:
            if cmd { keyHandler?.fileTableOpen(self) } else { keyHandler?.fileTableRename(self) }
            return
        case 49 where !cmd: keyHandler?.fileTableQuickLook(self); return
        case 51 where cmd, 117 where cmd: keyHandler?.fileTableTrash(self); return
        default: break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return super.menu(for: event)
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard numberOfRows == 0, let emptyMessage else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
        let size = emptyMessage.size(withAttributes: attrs)
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        emptyMessage.draw(at: NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40), withAttributes: attrs)
    }
}
