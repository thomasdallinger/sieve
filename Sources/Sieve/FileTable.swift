import AppKit
import SieveCore

/// Keys every file table understands. Return renames (as in Finder), ⌘↓ opens, Space previews.
protocol FileTableKeyHandler: AnyObject {
    func fileTableMoveLeft(_ table: NSTableView) -> Bool
    func fileTableMoveRight(_ table: NSTableView) -> Bool
    func fileTableOpen(_ table: NSTableView)
    func fileTableRename(_ table: NSTableView)
    func fileTableQuickLook(_ table: NSTableView)
    func fileTableTrash(_ table: NSTableView)
    func fileTableDidBecomeFirstResponder(_ table: NSTableView)
}

extension FileTableKeyHandler {
    func fileTableMoveLeft(_ table: NSTableView) -> Bool { false }
    func fileTableMoveRight(_ table: NSTableView) -> Bool { false }
    func fileTableDidBecomeFirstResponder(_ table: NSTableView) {}
}

final class FileTableView: NSTableView {
    weak var keyHandler: FileTableKeyHandler?
    /// Shown when the table has no rows ("Empty folder", "No matches").
    var emptyMessage: String? { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch event.keyCode {
        case 123 where !cmd: if keyHandler?.fileTableMoveLeft(self) == true { return }
        case 124 where !cmd: if keyHandler?.fileTableMoveRight(self) == true { return }
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

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyHandler?.fileTableDidBecomeFirstResponder(self) }
        return ok
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking an unselected row selects it first, like Finder.
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
        emptyMessage.draw(at: NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28), withAttributes: attrs)
    }
}

/// Icon + name row used by every file list. The name shows the extension in secondary color and query matches
/// highlighted; the trailing accessory is a chevron (folders in column view) or short secondary text.
final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let accessory = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    private(set) var item: FileItem?
    var onRenameCommit: ((FileItem, String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        name.delegate = self
        accessory.font = Theme.smallFont
        accessory.textColor = .tertiaryLabelColor
        accessory.alignment = .right
        accessory.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor
        for v in [icon, name, accessory, chevron] as [NSView] { addSubview(v) }
        imageView = icon
        textField = name
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, query: SearchQuery? = nil, accessoryText: String? = nil, showChevron: Bool = false) {
        self.item = item
        currentQuery = query
        icon.image = IconProvider.shared.icon(for: item)
        name.attributedStringValue = Theme.name(item, query: query, dimmed: item.isHidden)
        icon.alphaValue = item.isHidden ? 0.55 : 1
        accessory.stringValue = accessoryText ?? ""
        accessory.isHidden = accessoryText == nil
        chevron.isHidden = !showChevron
        toolTip = item.name
        layoutContents()
    }

    // Manual layout: rows are created by the hundred while scrolling, and Auto Layout per row costs more than
    // everything else in the row together. Re-layout whenever the column is resized.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let h = bounds.height, w = bounds.width
        icon.frame = NSRect(x: 4, y: (h - 18) / 2, width: 18, height: 18)
        var right = w - 4
        if !chevron.isHidden {
            chevron.frame = NSRect(x: right - 10, y: (h - 12) / 2, width: 10, height: 12)
            right -= 16
        }
        if !accessory.isHidden {
            let aw = min(w * 0.42, ceil(accessory.attributedStringValue.size().width) + 4)
            accessory.frame = NSRect(x: right - aw, y: (h - 15) / 2, width: aw, height: 15)
            right -= aw + 8
        }
        name.frame = NSRect(x: 28, y: (h - 17) / 2, width: max(10, right - 28), height: 17)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            chevron.contentTintColor = emphasized ? .white : .tertiaryLabelColor
            accessory.textColor = emphasized ? NSColor.white.withAlphaComponent(0.8) : Theme.accentText
            if let item, !name.isEditable {
                // Highlights read badly on the accent fill; plain white text on selection.
                name.attributedStringValue = Theme.name(item, query: currentQuery, dimmed: item.isHidden, onSelection: emphasized)
            }
        }
    }
    var currentQuery: SearchQuery?

    /// Inline rename, selecting only the stem so the extension survives a quick retype.
    func beginRename() {
        guard let item, let window else { return }
        name.isEditable = true
        name.isSelectable = true
        name.drawsBackground = true
        name.backgroundColor = .textBackgroundColor
        name.stringValue = item.name
        window.makeFirstResponder(name)
        let stemLength = (item.displayParts.stem as NSString).length
        name.currentEditor()?.selectedRange = NSRange(location: 0, length: stemLength)
    }

    private func endRename() {
        name.isEditable = false
        name.isSelectable = false
        name.drawsBackground = false
        if let item { name.attributedStringValue = Theme.name(item, query: currentQuery) }
    }
}

extension FileCellView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename()
            window?.makeFirstResponder(enclosingTableView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard name.isEditable, let item else { return }
        let newName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
        window?.makeFirstResponder(enclosingTableView)
        if !newName.isEmpty, newName != item.name { onRenameCommit?(item, newName) }
    }

    private var enclosingTableView: NSTableView? {
        var v: NSView? = superview
        while let view = v, !(view is NSTableView) { v = view.superview }
        return v as? NSTableView
    }
}

/// Configures a table the way all Sieve file lists look: plain rows on a card, selection drawn by
/// `SieveRowView` (the delegate returns one per row), no grid.
func styleFileTable(_ table: NSTableView, rowHeight: CGFloat = Theme.rowHeight) {
    table.style = .plain
    table.selectionHighlightStyle = .regular
    table.gridStyleMask = []
    table.rowHeight = rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.backgroundColor = .clear
    table.allowsMultipleSelection = true
    table.allowsEmptySelection = true
    table.allowsTypeSelect = true
    table.usesAutomaticRowHeights = false
    table.focusRingType = .none
    table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
    table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    table.registerForDraggedTypes([.fileURL])
    table.draggingDestinationFeedbackStyle = .regular
}

func makeScrollView(for table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    return scroll
}

/// Single-line secondary text cell (dates, sizes, kinds, locations), vertically centered with side padding.
final class TextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, font: NSFont, alignment: NSTextAlignment, truncation: NSLineBreakMode) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = font
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.lineBreakMode = truncation
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { label.textColor = backgroundStyle == .emphasized ? NSColor.white.withAlphaComponent(0.9) : .secondaryLabelColor }
    }
}

/// Puts `content` on a card inset from a canvas-colored background (lists, results, preview).
func onCard(_ content: NSView, inset: NSEdgeInsets = NSEdgeInsets(top: 0, left: Theme.cardGap, bottom: Theme.cardGap, right: Theme.cardGap)) -> NSView {
    let canvas = FillView(Theme.canvas)
    let card = CardView()
    card.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    canvas.addSubview(card)
    card.contentView.addSubview(content)
    NSLayoutConstraint.activate([
        card.topAnchor.constraint(equalTo: canvas.topAnchor, constant: inset.top),
        card.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: inset.left),
        card.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -inset.right),
        card.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -inset.bottom),
        content.topAnchor.constraint(equalTo: card.contentView.topAnchor),
        content.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
        content.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
    ])
    return canvas
}
