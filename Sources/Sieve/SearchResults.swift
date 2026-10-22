import AppKit
import SieveCore

enum SearchScope: Equatable {
    case folder, home, everywhere
}

struct SearchHit {
    let item: FileItem
    let score: Int32
    /// The suggested term this related hit matched.
    let via: String?
}

enum AIState: Equatable {
    case off, idle, thinking, done, unavailable(LocalModel.Status)
}

/// Search results: what literally contains the query comes first and appears in milliseconds; names the
/// local model suggests follow in their own section once it has answered.
final class SearchResultsViewController: NSViewController, BrowserContent, NSTableViewDataSource, NSTableViewDelegate, FileTableKeyHandler {
    weak var host: BrowserHost?
    /// Called when the user clicks a suggested term or a scope; the window updates the search field.
    var onSearchTerm: ((String) -> Void)?
    var onRevealItem: ((FileItem) -> Void)?
    var onModelAction: (() -> Void)?

    private let indexes: () -> IndexManager
    private let model: LocalModel
    private let table = FileTableView()
    private let scopeBar = ScopeBar()
    private let split = NSSplitView()
    private let preview = PreviewPane()
    private var previewCard: NSView!
    private let queue = DispatchQueue(label: "sieve.search", qos: .userInitiated)

    private(set) var query = SearchQuery("")
    private(set) var folder = NSHomeDirectory()
    var scope: SearchScope = .folder
    private var literal: [SearchHit] = []
    private var related: [SearchHit] = []
    private var terms: [String] = []
    private var literalTotal = 0
    private var elapsed: Double = 0
    private var aiState: AIState = .idle
    private var generation = 0
    private var aiTask: Task<Void, Never>?
    /// The query text the model was last asked about (nil after an explicit retry, model change or download).
    private var aiAskedFor: String?
    private var rows: [Row] = []

    enum Row {
        case literalHeader, relatedHeader, recentsHeader, hit(SearchHit)
    }
    private var showingRecents = false

    init(indexes: @escaping () -> IndexManager, model: LocalModel) {
        self.indexes = indexes
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("name", "Name", 300.0), ("where", "Where", 200.0), ("modified", "Date Modified", 120.0), ("size", "Size", 72.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        styleFileTable(table, rowHeight: Theme.searchRowHeight)
        table.dataSource = self
        table.delegate = self
        table.keyHandler = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.floatsGroupRows = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autosaveName = "SieveSearchColumns"
        table.autosaveTableColumns = true
        let scroll = makeScrollView(for: table)

        let left = NSView()
        scopeBar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(scopeBar)
        left.addSubview(scroll)
        NSLayoutConstraint.activate([
            scopeBar.topAnchor.constraint(equalTo: left.topAnchor),
            scopeBar.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scopeBar.heightAnchor.constraint(equalToConstant: 38),
            scroll.topAnchor.constraint(equalTo: scopeBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])
        scopeBar.onSelect = { [weak self] scope in
            guard let self else { return }
            self.scope = scope
            self.run(self.query.raw, folder: self.folder, keepAI: true)
        }
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(onCard(left, inset: NSEdgeInsets(top: 0, left: Theme.cardGap, bottom: Theme.cardGap, right: Theme.cardGap / 2)))
        previewCard = onCard(preview, inset: NSEdgeInsets(top: 0, left: Theme.cardGap / 2, bottom: Theme.cardGap, right: Theme.cardGap))
        split.addArrangedSubview(previewCard)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        view = split
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: IndexManager.didChange, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        table.menu = host?.makeContextMenu()
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
            split.setPosition(max(320, split.bounds.width - 320), ofDividerAt: 0)
        }
    }

    // MARK: Running searches

    /// Runs the literal search now and the AI expansion shortly after. `keepAI` re-uses the current suggestions
    /// (scope or filter changes don't need a new answer from the model).
    func run(_ text: String, folder: String, keepAI: Bool = false) {
        let newQuery = SearchQuery(text)
        let textChanged = newQuery.raw != query.raw || showingRecents
        showingRecents = false
        scopeBar.isHidden = false
        query = newQuery
        if folder != self.folder { self.folder = folder; if !keepAI { scope = .folder } }
        generation += 1
        let gen = generation
        if query.isEmpty {
            literal = []; related = []; terms = []; literalTotal = 0
            rebuildRows()
            return
        }
        let q = query, scope = self.scope, folder = self.folder
        let filter = Preferences.shared.filter
        let manager = indexes()
        let refresh = !keepAI
        queue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let target = Self.target(scope, folder: folder, manager: manager, refresh: refresh)
            let outcome = target.index.search(q, options: .init(scopePath: target.scopePath, filter: filter, limit: 1500))
            let hits = Self.hits(outcome, via: nil)
            let counts = Self.counts(q, folder: folder, filter: filter, manager: manager)
            let seconds = CFAbsoluteTimeGetCurrent() - started
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.literal = hits
                self.literalTotal = outcome.total
                self.elapsed = seconds
                self.scopeBar.update(folder: folder, scope: scope, counts: counts, seconds: seconds, building: manager.main.isBuilding)
                if !keepAI || textChanged { self.related = []; self.terms = [] }
                self.rebuildRows()
                if keepAI && !textChanged {
                    // Same text (scope, filter or index change): reuse the model's answer, keep waiting for it, or
                    // leave a failure on screen. Only a text the model was never asked about starts a request.
                    if !self.terms.isEmpty { self.searchRelated(gen: gen) }
                    else if self.aiAskedFor != self.query.raw { self.startAI(gen: gen) }
                } else {
                    self.startAI(gen: gen)
                }
            }
        }
    }

    /// Recently modified files in the home folder, newest first, straight from the index.
    func showRecents() {
        aiTask?.cancel()
        generation += 1
        let gen = generation
        query = SearchQuery("")
        showingRecents = true
        scopeBar.isHidden = true
        related = []; terms = []
        let filter = Preferences.shared.filter
        let manager = indexes()
        queue.async { [weak self] in
            let entries = manager.main.recentFiles(limit: 400, scopePath: NSHomeDirectory(), showHidden: filter.showHidden)
            let now = Date().timeIntervalSince1970
            let hits = entries.map { SearchHit(item: Self.item(for: $0), score: 0, via: nil) }
                .filter { filter.matches($0.item, browsing: false, now: now) }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.literal = hits
                self.literalTotal = hits.count
                self.rebuildRows()
            }
        }
    }

    private static func target(_ scope: SearchScope, folder: String, manager: IndexManager, refresh: Bool = false) -> (index: FileIndex, scopePath: String?) {
        switch scope {
        case .folder: return manager.target(for: folder, refresh: refresh)
        case .home: return (manager.main, NSHomeDirectory())
        case .everywhere: return (manager.main, nil)
        }
    }

    private static func counts(_ q: SearchQuery, folder: String, filter: FilterOptions, manager: IndexManager) -> [SearchScope: Int] {
        var out: [SearchScope: Int] = [:]
        for scope in [SearchScope.folder, .home, .everywhere] {
            let t = target(scope, folder: folder, manager: manager)
            out[scope] = t.index.search(q, options: .init(scopePath: t.scopePath, filter: filter, limit: 0)).total
        }
        return out
    }

    private static func item(for e: FileIndex.Entry) -> FileItem {
        FileItem(path: e.path, name: e.name, type: e.isDirectory ? .directory : .file,
                 isContainer: e.isDirectory && !e.isPackage, isPackage: e.isPackage, isHidden: e.isHidden,
                 size: e.size, created: 0, modified: e.modified, added: 0)
    }

    /// Hits with their entries, as resolved inside the search's lock (ids alone can go stale on compaction).
    private static func hits(_ outcome: FileIndex.Outcome, via term: String?) -> [SearchHit] {
        let entries = Dictionary(outcome.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return outcome.hits.compactMap { hit in
            entries[hit.id].map { SearchHit(item: item(for: $0), score: hit.score, via: term) }
        }
    }

    /// The next scope to try when the current one has no literal matches.
    private var widerScope: SearchScope? {
        switch scope {
        case .folder: return folder == NSHomeDirectory() ? .everywhere : .home
        case .home: return .everywhere
        case .everywhere: return nil
        }
    }

    private func startAI(gen: Int) {
        aiTask?.cancel()
        guard Preferences.shared.aiEnabled else { setAI(.off); return }
        guard query.raw.trimmingCharacters(in: .whitespaces).count >= 3 else { setAI(.idle); return }
        setAI(.thinking)
        let text = query.raw
        aiAskedFor = text
        aiTask = Task { [weak self, model] in
            // Wait for a pause in typing; the literal results are already on screen.
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            do {
                let terms = try await model.expand(text)
                await MainActor.run {
                    guard let self, self.query.raw == text else { return }
                    self.terms = terms
                    self.searchRelated(gen: self.generation)
                }
            } catch {
                // A newer query replaced this one; that is not a failure worth showing.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                let status = await model.status()
                await MainActor.run {
                    guard let self, self.query.raw == text else { return }
                    self.setAI(status == .ready ? .unavailable(.failed(error.localizedDescription)) : .unavailable(status))
                }
            }
        }
    }

    private func searchRelated(gen: Int) {
        let terms = self.terms, scope = self.scope, folder = self.folder, queryText = query.raw
        let filter = Preferences.shared.filter
        let manager = indexes()
        let literalIDs = Set(literal.map(\.item.path))
        guard !terms.isEmpty else { setAI(.done); return }
        queue.async { [weak self] in
            let target = Self.target(scope, folder: folder, manager: manager)
            // Keyed by path: each term is its own search, and ids may change between them.
            var best: [String: SearchHit] = [:]
            for (rank, term) in terms.enumerated() {
                let outcome = target.index.search(SearchQuery(term), options: .init(scopePath: target.scopePath, filter: filter, limit: 80))
                // A term matching thousands of names ("pic") says little; keep only its best few.
                let keep = outcome.total > 800 ? 10 : 80
                for hit in Self.hits(outcome, via: term).prefix(keep) where !literalIDs.contains(hit.item.path) {
                    let score = hit.score - Int32(rank * 12)
                    if best[hit.item.path].map({ $0.score < score }) ?? true {
                        best[hit.item.path] = SearchHit(item: hit.item, score: score, via: term)
                    }
                }
            }
            let hits = Array(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.path < $1.item.path }.prefix(300))
            DispatchQueue.main.async {
                guard let self, self.generation == gen || self.terms == terms && self.query.raw == queryText else { return }
                self.related = hits
                self.aiState = .done
                self.rebuildRows()
            }
        }
    }

    private func setAI(_ state: AIState) {
        aiState = state
        rebuildRows()
    }

    @objc private func indexChanged() {
        if showingRecents, view.window != nil, literal.isEmpty { showRecents(); return }
        guard !query.isEmpty, view.window != nil else { return }
        run(query.raw, folder: folder, keepAI: true)
    }

    // MARK: Rows

    private func rebuildRows() {
        let selected = Set(selectedItems.map(\.path))
        let sort = Preferences.shared.searchSort
        func ordered(_ hits: [SearchHit]) -> [SearchHit] {
            guard sort.key != .relevance else { return hits }
            let byPath = Dictionary(hits.map { ($0.item.path, $0) }, uniquingKeysWith: { a, _ in a })
            return sort.sorted(hits.map(\.item)).compactMap { byPath[$0.path] }
        }
        rows = []
        if showingRecents {
            rows.append(.recentsHeader)
            rows += (sort.key == .relevance ? literal : ordered(literal)).map { .hit($0) }
        } else if !query.isEmpty {
            rows.append(.literalHeader)
            rows += ordered(literal).map { .hit($0) }
            rows.append(.relatedHeader)
            rows += ordered(related).map { .hit($0) }
        }
        table.emptyMessage = query.isEmpty && !showingRecents ? "Type to search names" : nil
        table.reloadData()
        let restore = IndexSet(rows.indices.filter { if case .hit(let h) = rows[$0] { return selected.contains(h.item.path) }; return false })
        if !restore.isEmpty { table.selectRowIndexes(restore, byExtendingSelection: false) } else { preview.clear() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .hit = rows[row] { return SieveRowView() }
        return SectionRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .hit = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .hit: return Theme.searchRowHeight
        case .literalHeader, .recentsHeader: return 30
        case .relatedHeader: return terms.isEmpty ? 34 : 58
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .hit = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .literalHeader:
            let header = SectionHeader()
            let shown = literal.count < literalTotal ? " · showing \(literal.count.formatted())" : ""
            let title = "Name contains “\(query.raw.trimmingCharacters(in: .whitespaces))”"
            if literalTotal == 0, let wider = widerScope {
                // Nothing here: offer the next wider scope instead of a dead end.
                header.configure(title: title, detail: "No matches in “\((folder as NSString).lastPathComponent)”",
                                 button: wider == .home ? "Search Home" : "Search Everywhere") { [weak self] in
                    guard let self else { return }
                    self.scope = wider
                    self.run(self.query.raw, folder: self.folder)
                }
            } else {
                header.configure(title: title, detail: literalTotal == 0 ? "No matches" : Format.count(literalTotal, "match", "matches") + shown)
            }
            return header
        case .recentsHeader:
            let header = SectionHeader()
            header.symbol = "clock"
            header.configure(title: "Recently modified in Home", detail: literal.isEmpty ? "Nothing yet — the index is still building" : Format.count(literal.count, "file"))
            return header
        case .relatedHeader:
            let header = SectionHeader()
            header.symbol = "sparkles"
            switch aiState {
            case .off:
                header.configure(title: "Related", detail: "Suggestions from the local model are off", button: "Turn On") { [weak self] in
                    Preferences.shared.aiEnabled = true
                    self?.startAI(gen: self?.generation ?? 0)
                }
            case .idle:
                header.configure(title: "Related", detail: "Type at least 3 characters for suggestions")
            case .thinking:
                header.configure(title: "Related", detail: "Asking \(Preferences.shared.modelName) for similar names…", spinning: true)
            case .done:
                let detail = related.isEmpty ? "Nothing else found" : Format.count(related.count, "result")
                let modelName = Preferences.shared.modelName.split(separator: ":").first.map(String.init) ?? ""
                header.configure(title: "Related", detail: "\(detail) · names suggested by \(modelName), running on this Mac")
                header.setTerms(terms) { [weak self] term in self?.onSearchTerm?(term) }
            case .unavailable(let status):
                switch status {
                case .serverNotRunning:
                    header.configure(title: "Related", detail: "Ollama isn’t running", button: "Start Ollama") { [weak self] in self?.onModelAction?() }
                case .modelMissing:
                    header.configure(title: "Related", detail: "Model \(Preferences.shared.modelName) isn’t downloaded yet",
                                     button: "Download (\(LocalModel.defaultModelSize))") { [weak self] in self?.onModelAction?() }
                case .downloading(let p):
                    header.configure(title: "Related", detail: "Downloading model… \(Int(p * 100))%", spinning: true)
                default:
                    header.configure(title: "Related", detail: "The local model didn’t answer", button: "Retry") { [weak self] in
                        self?.aiAskedFor = nil
                        self?.startAI(gen: self?.generation ?? 0)
                    }
                }
            }
            return header
        case .hit(let hit):
            guard let id = tableColumn?.identifier.rawValue else { return nil }
            if id == "name" {
                let cell = tableView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? FileCellView()
                let highlight = hit.via.map { SearchQuery($0) } ?? query
                cell.configure(hit.item, query: highlight, accessoryText: hit.via.map { "≈ \($0)" })
                cell.onRenameCommit = { [weak self] item, name in
                    guard let self, self.host?.renameItem(item, to: name) != nil else { return }
                    self.run(self.query.raw, folder: self.folder, keepAI: true)
                }
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("text-" + id)
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCell
                ?? TextCell(identifier: identifier, font: id == "where" ? .systemFont(ofSize: 12) : Theme.monoDigits,
                            alignment: id == "size" ? .right : .left, truncation: id == "where" ? .byTruncatingHead : .byTruncatingTail)
            let field = cell.label
            switch id {
            case "where": field.stringValue = Format.displayPath(hit.item.parentPath); field.toolTip = hit.item.parentPath
            case "modified": field.stringValue = Format.date(hit.item.modified)
            case "size": field.stringValue = hit.item.isContainer ? "—" : Format.size(hit.item.size)
            default: break
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selection = selectedItems.compactMap { FileItem.at(path: $0.path) }
        if selection.isEmpty { preview.clear() } else { preview.show(selection) }
        host?.contentSelectionDidChange()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if case .hit(let h) = rows[row] { return h.item.url as NSURL }
        return nil
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        if case .hit(let h) = rows[row], tableColumn?.identifier.rawValue == "name" { return h.item.name }
        return nil
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, case .hit(let hit) = rows[row] else { return }
        host?.openItems([hit.item])
    }

    // MARK: BrowserContent

    var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { row in
            guard row < rows.count, case .hit(let h) = rows[row] else { return nil }
            return h.item
        }
    }

    var targetDirectory: String { selectedItems.first?.parentPath ?? folder }
    var visibleItemCount: Int { literal.count + related.count }

    func focusContent() {
        view.window?.makeFirstResponder(table)
        if table.selectedRow < 0, let first = rows.firstIndex(where: { if case .hit = $0 { return true }; return false }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
    }

    func applyViewOptions() {
        guard isViewLoaded else { return }
        updatePreviewVisibility()
        if showingRecents { showRecents(); return }
        if !query.isEmpty { run(query.raw, folder: folder, keepAI: true) }
    }

    func beginRename(_ path: String) {
        guard let row = rows.firstIndex(where: { if case .hit(let h) = $0 { return h.item.path == path }; return false }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView)?.beginRename()
    }

    func refreshModelState(_ status: LocalModel.Status) {
        if case .downloading = status { aiTask?.cancel(); setAI(.unavailable(status)); return }
        aiAskedFor = nil
        if status == .ready { startAI(gen: generation) } else { setAI(.unavailable(status)) }
    }

    // MARK: Keys

    func fileTableOpen(_ table: NSTableView) { host?.openItems(selectedItems) }
    func fileTableRename(_ table: NSTableView) { if selectedItems.count == 1 { beginRename(selectedItems[0].path) } }
    func fileTableQuickLook(_ table: NSTableView) { host?.quickLook() }
    func fileTableTrash(_ table: NSTableView) { host?.trash(selectedItems) }
    func fileTableMoveRight(_ table: NSTableView) -> Bool {
        if let item = selectedItems.first { onRevealItem?(item) }
        return true
    }
}

/// Group row: section title with detail text, an optional action button, spinner and clickable term chips.
final class SectionHeader: NSTableCellView {
    var symbol: String? {
        didSet {
            icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) }
            icon.isHidden = symbol == nil
        }
    }
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let button = NSButton(title: "", target: nil, action: nil)
    private let chips = NSStackView()
    private var action: (() -> Void)?
    private var termAction: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        icon.contentTintColor = Theme.accent
        icon.isHidden = true
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(buttonPressed)
        chips.orientation = .horizontal
        chips.spacing = 6
        let top = NSStackView(views: [icon, title, detail, spinner, button])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.setCustomSpacing(5, after: icon)
        top.detachesHiddenViews = true
        let column = NSStackView(views: [top, chips])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            top.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String, spinning: Bool = false, button: String? = nil, action: (() -> Void)? = nil) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        self.button.title = button ?? ""
        self.button.isHidden = button == nil
        self.action = action
        chips.isHidden = chips.arrangedSubviews.isEmpty
    }

    func setTerms(_ terms: [String], action: @escaping (String) -> Void) {
        termAction = action
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for term in terms {
            let chip = NSButton(title: term, target: self, action: #selector(chipPressed(_:)))
            chip.bezelStyle = .recessed
            chip.controlSize = .small
            chip.font = .systemFont(ofSize: 11)
            chip.toolTip = "Search for “\(term)”"
            chips.addArrangedSubview(chip)
        }
        chips.isHidden = terms.isEmpty
    }

    @objc private func buttonPressed() { action?() }
    @objc private func chipPressed(_ sender: NSButton) { termAction?(sender.title) }
}

/// "In Downloads 12 · Home 340 · Everywhere 352" as pills, with the match time.
final class ScopeBar: NSView {
    var onSelect: ((SearchScope) -> Void)?
    private let pills = NSStackView()
    private let timing = NSTextField(labelWithString: "")
    private var scopes: [SearchScope] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        pills.orientation = .horizontal
        pills.spacing = 6
        timing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timing.textColor = .tertiaryLabelColor
        for v in [pills, timing] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            pills.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pills.centerYAnchor.constraint(equalTo: centerYAnchor),
            timing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(folder: String, scope: SearchScope, counts: [SearchScope: Int], seconds: Double, building: Bool) {
        let home = NSHomeDirectory()
        scopes = folder == home ? [.home, .everywhere] : [.folder, .home, .everywhere]
        let effective = folder == home && scope == .folder ? SearchScope.home : scope
        pills.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, s) in scopes.enumerated() {
            let name: String
            switch s {
            case .folder: name = "In “\((folder as NSString).lastPathComponent)”"
            case .home: name = "Home"
            case .everywhere: name = "Everywhere"
            }
            let count = s == .folder && folder == home ? counts[.home] : counts[s]
            let pill = PillButton(title: "\(name)  \(count?.formatted() ?? "–")", target: self, action: #selector(changed(_:)))
            pill.tag = i
            pill.isOn = s == effective
            pills.addArrangedSubview(pill)
        }
        let ms = seconds * 1000
        timing.stringValue = (building ? "Indexing… · " : "") + (ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms))
    }

    @objc private func changed(_ sender: NSButton) {
        guard scopes.indices.contains(sender.tag) else { return }
        onSelect?(scopes[sender.tag])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.cardBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Group row background: the card color, so floating section headers cover the rows scrolling beneath them.
final class SectionRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        Theme.card.setFill()
        bounds.fill()
    }
}
