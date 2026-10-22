import AppKit
import SieveCore

/// Column view: one table per folder from the location root down to the selection, then a preview of the
/// selected file. Built from plain view-based tables (not NSBrowser) so rows, keys and drag & drop behave the
/// same as in every other Sieve view.
final class ColumnBrowserViewController: NSViewController, BrowserContent {
    weak var host: BrowserHost?
    private let scrollView = NSScrollView()
    private let strip = FlippedView()
    private(set) var columns: [DirectoryColumn] = []
    private let preview = PreviewPane()
    private let previewCard = CardView()
    private var previewVisible = false
    private var previewWidth: CGFloat = 340
    private(set) var rootPath = NSHomeDirectory()
    private weak var focusedColumn: DirectoryColumn?

    override func loadView() {
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.canvas
        scrollView.documentView = strip
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns(animated: false)
    }

    // MARK: Navigation

    /// Shows `root` as the first column and opens columns down to `selecting` if it lies inside it.
    /// Columns that are already on the way stay as they are, so moving within one tree is nearly free.
    func show(root: String, selecting path: String? = nil, focusSelection: Bool = false) {
        var chain = [root]
        if let path, path != root, path.hasPrefix(root == "/" ? "/" : root + "/") {
            for component in path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/") {
                chain.append(FileIndex.joinPath(chain.last!, String(component)))
            }
        }
        if columns.first?.path != root {
            rootPath = root
            for c in columns { c.container.removeFromSuperview() }
            columns = []
            setPreview(nil)
            addColumn(root)
        }
        for i in 1..<max(1, chain.count) {
            let column = columns[i - 1], next = chain[i]
            // Selecting posts a selection change, which opens the next column. Hidden folders on the way
            // (/private, ~/.config) stay visible because you explicitly went there.
            let alreadySelected = column.selectedItems.count == 1 && column.selectedItems[0].path == next
            if !alreadySelected, !column.reveal(path: next) { break }
            if i < chain.count - 1, columns.count <= i || columns[i].path != next { break }
        }
        // A folder target shows its contents with nothing selected inside it.
        let target = chain.last!
        // Nothing stays selected inside the target folder, so deeper columns from earlier visits close.
        if let column = columns.first(where: { $0.path == target }), !column.selectedItems.isEmpty { column.table.deselectAll(nil) }
        // Opening a folder puts you in its contents; revealing a file (or ⌘↑) puts you on the item itself.
        let opensFolder = columns.contains { $0.path == target } && !focusSelection
        focusedColumn = opensFolder ? columns.last
            : columns.first { $0.selectedItems.contains { $0.path == target } } ?? columns.last { !$0.selectedItems.isEmpty } ?? columns.first
        if view.window?.firstResponder is NSTableView { view.window?.makeFirstResponder(focusedColumn?.table) }
        layoutColumns(animated: false)
        scrollToEnd(animated: false)
        host?.contentLocationDidChange()
    }

    /// The deepest folder that is open as a column, i.e. "where you are".
    var currentDirectory: String { columns.last?.path ?? rootPath }

    var targetDirectory: String { (focusedColumn ?? columns.last)?.path ?? rootPath }
    var visibleItemCount: Int { columns.last?.items.count ?? 0 }

    /// The path the columns currently lead to: the selected item of the deepest column with a selection.
    var selectedPath: String? {
        for column in columns.reversed() { if let item = column.selectedItems.first { return item.path } }
        return nil
    }

    var selectedItems: [FileItem] { (focusedColumn ?? columns.last)?.selectedItems ?? [] }

    func focusContent() {
        let column = focusedColumn ?? columns.last
        // No automatic selection: it would open a column nobody asked for. ↓ selects the first row.
        view.window?.makeFirstResponder(column?.table)
    }

    func applyViewOptions() {
        for c in columns { c.applyOptions() }
    }

    func beginRename(_ path: String) {
        for column in columns where column.path == (path as NSString).deletingLastPathComponent {
            column.beginRename(path)
        }
    }

    @discardableResult
    private func addColumn(_ path: String) -> DirectoryColumn {
        let column = DirectoryColumn(path: path, width: CGFloat(Preferences.shared.columnWidth))
        column.owner = self
        column.table.menu = host?.makeContextMenu()
        column.load()
        columns.append(column)
        strip.addSubview(column.container)
        return column
    }

    func columnSelectionChanged(_ column: DirectoryColumn) {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        // Close everything to the right of this column.
        for c in columns[(index + 1)...] { c.container.removeFromSuperview() }
        columns.removeSubrange((index + 1)...)
        let selection = column.selectedItems
        if selection.count == 1, let item = selection.first, item.isContainer {
            setPreview(nil)
            addColumn(item.path)
        } else if selection.count == 1, let item = selection.first {
            setPreview([item])
        } else if selection.count > 1 {
            setPreview(selection)
        } else {
            setPreview(nil)
        }
        layoutColumns(animated: true)
        scrollToEnd(animated: true)
        host?.contentSelectionDidChange()
        host?.contentLocationDidChange()
    }

    private func setPreview(_ items: [FileItem]?) {
        if let items {
            preview.show(items)
            if !previewVisible {
                if preview.superview == nil {
                    preview.frame = previewCard.contentView.bounds
                    preview.autoresizingMask = [.width, .height]
                    previewCard.contentView.addSubview(preview)
                }
                strip.addSubview(previewCard)
                previewVisible = true
            }
        } else if previewVisible {
            previewCard.removeFromSuperview()
            previewVisible = false
        }
    }

    func columnDidFocus(_ column: DirectoryColumn) {
        focusedColumn = column
        host?.contentSelectionDidChange()
    }

    func moveFocus(from column: DirectoryColumn, by delta: Int) -> Bool {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return false }
        let target = index + delta
        guard columns.indices.contains(target) else { return false }
        let next = columns[target]
        if delta < 0 {
            // Leaving a column clears its selection, so the view collapses back to the folder you came from.
            column.table.deselectAll(nil)
        } else if next.table.selectedRow < 0 {
            guard next.items.count > 0 else { return false }
            next.table.selectRowIndexes([0], byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(next.table)
        if let row = next.table.selectedRowIndexes.first { next.table.scrollRowToVisible(row) }
        return true
    }

    func resizeColumn(_ column: DirectoryColumn, to width: CGFloat, all: Bool) {
        let w = min(800, max(140, width))
        if all {
            for c in columns { c.width = w }
            Preferences.shared.columnWidth = Double(w)
        } else {
            column.width = w
        }
        layoutColumns(animated: false)
    }

    // MARK: Layout

    private func layoutColumns(animated: Bool) {
        let height = scrollView.contentSize.height
        var x: CGFloat = Theme.cardGap / 2
        let animate = animated && !Theme.reduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animate ? Theme.motion : 0
            ctx.allowsImplicitAnimation = animate
            for column in columns {
                let frame = NSRect(x: x, y: 0, width: column.width, height: height)
                if column.container.frame.height == 0 || !animate { column.container.frame = frame } else { column.container.animator().frame = frame }
                x += column.width
            }
            if previewVisible {
                let available = scrollView.contentSize.width - x - Theme.cardGap
                let w = max(previewWidth, available)
                previewCard.frame = NSRect(x: x + Theme.cardGap / 2, y: 0, width: w - Theme.cardGap / 2, height: height - Theme.cardGap)
                x += w
            }
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(x + Theme.cardGap, scrollView.contentSize.width), height: height)
    }

    private func scrollToEnd(animated: Bool) {
        let clip = scrollView.contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        guard abs(clip.bounds.origin.x - maxX) > 1 else { return }
        let target = NSPoint(x: maxX, y: 0)
        if animated && !Theme.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.motion
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension FileIndex {
    static func joinPath(_ dir: String, _ name: String) -> String { dir == "/" ? "/" + name : dir + "/" + name }
}

/// One folder column.
final class DirectoryColumn: NSObject, NSTableViewDataSource, NSTableViewDelegate, FileTableKeyHandler {
    let path: String
    var width: CGFloat
    weak var owner: ColumnBrowserViewController?
    let table = FileTableView()
    let container = NSView()
    private let card = CardView()
    private let header = ColumnHeader()
    private let scroll: NSScrollView
    private let handle = ColumnResizeHandle()
    private var all: [FileItem] = []
    private(set) var items: [FileItem] = []
    private var watcher: DirectoryWatcher?
    private var error: String?

    init(path: String, width: CGFloat) {
        self.path = path
        self.width = width
        scroll = makeScrollView(for: table)
        super.init()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        styleFileTable(table)
        table.dataSource = self
        table.delegate = self
        table.keyHandler = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        header.title = path == "/" ? SidebarViewController.title(for: "/") : FileManager.default.displayName(atPath: path)
        card.contentView.addSubview(header)
        card.contentView.addSubview(scroll)
        container.addSubview(card)
        container.addSubview(handle)
        handle.onDrag = { [weak self] dx, all in
            guard let self else { return }
            self.owner?.resizeColumn(self, to: self.width + dx, all: all)
        }
        handle.onDoubleClick = { [weak self] in self?.sizeToFit() }
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(containerResized), name: NSView.frameDidChangeNotification, object: container)
        NotificationCenter.default.addObserver(self, selector: #selector(iconLoaded(_:)), name: IconProvider.didLoad, object: nil)
        watcher = DirectoryWatcher(path: path) { [weak self] in self?.reload() }
    }

    /// Card inset by half the gap on each side (so neighbours are a full gap apart) and the gap at the bottom.
    @objc private func containerResized() {
        let b = container.bounds
        let gap = Theme.cardGap
        card.frame = NSRect(x: gap / 2, y: gap, width: max(0, b.width - gap), height: max(0, b.height - gap))
        let inner = card.contentView.bounds
        header.frame = NSRect(x: 0, y: inner.height - ColumnHeader.height, width: inner.width, height: ColumnHeader.height)
        scroll.frame = NSRect(x: 0, y: 0, width: inner.width, height: max(0, inner.height - ColumnHeader.height))
        handle.frame = NSRect(x: b.width - gap, y: gap, width: gap, height: max(0, b.height - gap))
    }

    @objc private func iconLoaded(_ note: Notification) {
        guard let p = note.object as? String, (p as NSString).deletingLastPathComponent == path,
              let row = items.firstIndex(where: { $0.path == p }) else { return }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    func load() {
        do {
            all = try DirectoryListing.load(path)
            error = nil
        } catch let e as DirectoryReader.ReadError {
            all = []
            error = e.isPermissionDenied ? "No permission to read this folder" : "Can’t read this folder"
        } catch {
            all = []
        }
        applyOptions(preserveSelection: false)
    }

    func reload() {
        let selected = Set(selectedItems.map(\.path))
        let focusedRow = table.selectedRow
        do { all = try DirectoryListing.load(path) } catch { all = [] }
        applyOptions(preserveSelection: false)
        let rows = IndexSet(items.indices.filter { selected.contains(items[$0].path) })
        if !rows.isEmpty {
            table.selectRowIndexes(rows, byExtendingSelection: false)
        } else if focusedRow >= 0, !selected.isEmpty {
            // The selected item vanished (deleted, renamed elsewhere): select its neighbor.
            let row = min(focusedRow, items.count - 1)
            if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    func applyOptions(preserveSelection: Bool = true) {
        let prefs = Preferences.shared
        let selected = preserveSelection ? Set(selectedItems.map(\.path)) : []
        let now = Date().timeIntervalSince1970
        items = prefs.sort.sorted(all.filter { prefs.filter.matches($0, browsing: true, now: now) || forcedVisible.contains($0.path) })
        table.emptyMessage = error ?? (all.isEmpty ? "Nothing here" : items.isEmpty ? "Filtered out" : nil)
        // "12 of 40" only when filters hide something; hidden files you chose not to see don't count.
        let eligible = prefs.filter.showHidden ? all.count : all.reduce(0) { $0 + ($1.isHidden ? 0 : 1) }
        header.detail = items.count >= eligible ? "\(items.count.formatted())" : "\(items.count.formatted()) of \(eligible.formatted())"
        table.reloadData()
        if !selected.isEmpty {
            let rows = IndexSet(items.indices.filter { selected.contains(items[$0].path) })
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    var selectedItems: [FileItem] { table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil } }

    /// Paths shown even when the filters would hide them (the route to an explicit navigation target).
    private var forcedVisible = Set<String>()

    func reveal(path: String) -> Bool {
        if !items.contains(where: { $0.path == path }), all.contains(where: { $0.path == path }) {
            forcedVisible.insert(path)
            applyOptions()
        }
        return select(path: path)
    }

    @discardableResult
    func select(path: String) -> Bool {
        guard let row = items.firstIndex(where: { $0.path == path }) else { return false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return true
    }

    func beginRename(_ itemPath: String) {
        if !select(path: itemPath) { reload(); select(path: itemPath) }
        let row = table.selectedRow
        guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView else { return }
        cell.beginRename()
    }

    private func sizeToFit() {
        let widest = items.prefix(2000).map { Theme.name($0).size().width }.max() ?? 160
        owner?.resizeColumn(self, to: widest + 64, all: false)
    }

    @objc private func doubleClicked() {
        let clicked = table.clickedRow
        guard clicked >= 0, clicked < items.count else { return }
        let item = items[clicked]
        if !item.isContainer { owner?.host?.openItems([item]) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? FileCellView()
        let item = items[row]
        cell.configure(item, showChevron: item.isContainer)
        cell.onRenameCommit = { [weak self] item, name in
            guard let self, let newPath = self.owner?.host?.renameItem(item, to: name) else { return }
            self.reload()
            self.select(path: newPath)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { items[row].name }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SieveRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        owner?.columnSelectionChanged(self)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { items[row].url as NSURL }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on, row < items.count, items[row].isContainer {
            return DropSupport.validate(info, directory: items[row].path)
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return DropSupport.validate(info, directory: path)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let target = row >= 0 && row < items.count && items[row].isContainer && dropOperation == .on ? items[row].path : path
        return DropSupport.accept(info, directory: target, host: owner?.host)
    }

    // MARK: Keys

    func fileTableMoveLeft(_ table: NSTableView) -> Bool { owner?.moveFocus(from: self, by: -1) ?? false }

    func fileTableMoveRight(_ table: NSTableView) -> Bool {
        guard selectedItems.count == 1, selectedItems[0].isContainer else { return false }
        return owner?.moveFocus(from: self, by: 1) ?? false
    }

    func fileTableOpen(_ table: NSTableView) {
        let selection = selectedItems
        if selection.count == 1, selection[0].isContainer { _ = fileTableMoveRight(table) } else { owner?.host?.openItems(selection) }
    }

    func fileTableRename(_ table: NSTableView) {
        if let item = selectedItems.first, selectedItems.count == 1 { beginRename(item.path) }
    }

    func fileTableQuickLook(_ table: NSTableView) { owner?.host?.quickLook() }
    func fileTableTrash(_ table: NSTableView) { owner?.host?.trash(selectedItems) }
    func fileTableDidBecomeFirstResponder(_ table: NSTableView) { owner?.columnDidFocus(self) }
}

/// Invisible drag handle in the gap between two column cards. ⌥-drag resizes every column;
/// double-click fits the column to its longest name.
final class ColumnResizeHandle: NSView {
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX, event.modifierFlags.contains(.option))
        lastX = x
    }
}

/// Card header of a column: the folder's name and how many items it shows (or "12 of 40" when filtered).
final class ColumnHeader: NSView {
    static let height: CGFloat = 30
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue; titleLabel.toolTip = newValue }
    }
    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue; setFrameSize(frame.size) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = Theme.headerFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .right
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let dw = min(newSize.width * 0.4, ceil(detailLabel.intrinsicContentSize.width) + 2)
        detailLabel.frame = NSRect(x: newSize.width - dw - 12, y: (newSize.height - 15) / 2, width: dw, height: 15)
        titleLabel.frame = NSRect(x: 12, y: (newSize.height - 16) / 2, width: max(0, newSize.width - dw - 32), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.cardBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
