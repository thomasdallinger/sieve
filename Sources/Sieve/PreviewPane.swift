import AppKit
import ImageIO
import Quartz
import SieveCore

/// Quick Look preview plus the facts people actually look for (kind, size, dates, dimensions, location).
/// Used as the last column in column view and as the side pane in list and search views.
final class PreviewPane: NSView {
    private let quickLook: QLPreviewView
    private let iconView = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Path", target: nil, action: nil)
    private let placeholder = NSTextField(labelWithString: "Select a file to preview it")
    private var items: [FileItem] = []
    private var pendingUpdate: DispatchWorkItem?
    private var metadataGeneration = 0

    override init(frame: NSRect) {
        quickLook = QLPreviewView(frame: .zero, style: .compact)!
        super.init(frame: frame)
        quickLook.autostarts = true
        quickLook.shouldCloseWithWindow = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        grid.rowSpacing = 5
        grid.columnSpacing = 10
        for b in [openButton, copyButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.target = self
        }
        openButton.action = #selector(openItem)
        openButton.bezelColor = Theme.selection
        openButton.keyEquivalent = ""
        copyButton.action = #selector(copyPath)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        for v in [quickLook, iconView, title, subtitle, grid, openButton, copyButton, placeholder] as [NSView] {
            addSubview(v)
        }
        showPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ items: [FileItem]) {
        pendingUpdate?.cancel()
        self.items = items
        // Holding an arrow key flies through rows; only preview where the selection comes to rest.
        let work = DispatchWorkItem { [weak self] in self?.update() }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func clear() {
        pendingUpdate?.cancel()
        items = []
        showPlaceholder()
    }

    private func showPlaceholder() {
        quickLook.previewItem = nil
        for v in [quickLook, iconView, title, subtitle, grid, openButton, copyButton] as [NSView] { v.isHidden = true }
        placeholder.isHidden = false
        needsLayout = true
    }

    private func update() {
        guard !items.isEmpty else { showPlaceholder(); return }
        placeholder.isHidden = true
        for v in [title, subtitle, grid, openButton, copyButton] as [NSView] { v.isHidden = false }
        metadataGeneration += 1
        if items.count == 1, let item = items.first {
            let canPreview = !item.isContainer
            quickLook.isHidden = !canPreview
            iconView.isHidden = canPreview
            if canPreview { quickLook.previewItem = item.url as NSURL } else { quickLook.previewItem = nil; iconView.image = IconProvider.shared.icon(forPath: item.path) }
            title.stringValue = item.name
            subtitle.stringValue = item.isContainer ? "Folder" : "\(Format.kind(item)) · \(Format.size(item.size))"
            var rows: [(String, String)] = [
                ("Modified", Format.longDate(item.modified)),
                ("Created", Format.longDate(item.created)),
            ]
            if let added = item.addedDate { rows.append(("Added", Format.longDate(added.timeIntervalSince1970))) }
            rows.append(("Where", Format.displayPath(item.parentPath)))
            setRows(rows)
            openButton.isHidden = false
            loadDimensions(item, generation: metadataGeneration, rows: rows)
        } else {
            quickLook.isHidden = true
            quickLook.previewItem = nil
            iconView.isHidden = false
            iconView.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .ultraLight))
            iconView.contentTintColor = .tertiaryLabelColor
            title.stringValue = Format.count(items.count, "item")
            let bytes = items.reduce(Int64(0)) { $0 + $1.size }
            let folders = items.filter(\.isContainer).count
            subtitle.stringValue = [folders > 0 ? Format.count(folders, "folder") : nil, bytes > 0 ? Format.size(bytes) : nil]
                .compactMap { $0 }.joined(separator: " · ")
            setRows([])
            openButton.isHidden = false
        }
        needsLayout = true
    }

    private func loadDimensions(_ item: FileItem, generation: Int, rows: [(String, String)]) {
        guard item.categories.contains(.image) || item.categories.contains(.pdf) else { return }
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var extra: (String, String)?
            if item.categories.contains(.pdf), let doc = CGPDFDocument(url as CFURL) {
                extra = ("Pages", "\(doc.numberOfPages)")
            } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                extra = ("Dimensions", "\(w) × \(h)")
            }
            guard let extra else { return }
            DispatchQueue.main.async {
                guard let self, self.metadataGeneration == generation else { return }
                self.setRows([extra] + rows)
                self.needsLayout = true
            }
        }
    }

    private func setRows(_ rows: [(String, String)]) {
        // removeRow keeps the cell views around, so remove them explicitly.
        grid.subviews.forEach { $0.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for (label, value) in rows {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            let v = NSTextField(labelWithString: value)
            v.font = .systemFont(ofSize: 11)
            v.textColor = .labelColor
            v.lineBreakMode = .byTruncatingMiddle
            v.isSelectable = true
            grid.addRow(with: [l, v])
        }
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).width = 74
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 20
        let width = bounds.width - inset * 2
        placeholder.frame = NSRect(x: inset, y: bounds.midY - 10, width: width, height: 20)
        var y: CGFloat = 20
        let previewHeight = min(max(160, bounds.height * 0.48), width * 1.1)
        if !quickLook.isHidden {
            quickLook.frame = NSRect(x: inset, y: y, width: width, height: previewHeight)
            y += previewHeight + 14
        } else if !iconView.isHidden {
            let s = min(128, previewHeight)
            iconView.frame = NSRect(x: bounds.midX - s / 2, y: y + 12, width: s, height: s)
            y += s + 30
        }
        title.preferredMaxLayoutWidth = width
        let titleHeight = min(60, title.intrinsicContentSize.height)
        title.frame = NSRect(x: inset, y: y, width: width, height: titleHeight)
        y += titleHeight + 2
        subtitle.frame = NSRect(x: inset, y: y, width: width, height: 16)
        y += 26
        let gridSize = grid.fittingSize
        grid.frame = NSRect(x: max(inset, bounds.midX - gridSize.width / 2), y: y, width: min(width, gridSize.width), height: gridSize.height)
        y += gridSize.height + 16
        let bw: CGFloat = 96, gap: CGFloat = 8
        let total = openButton.isHidden ? bw : bw * 2 + gap
        var x = bounds.midX - total / 2
        if !openButton.isHidden { openButton.frame = NSRect(x: x, y: y, width: bw, height: 24); x += bw + gap }
        copyButton.frame = NSRect(x: x, y: y, width: bw, height: 24)
    }

    @objc private func openItem() { FileActions.open(items) }
    @objc private func copyPath() { FileActions.copyPaths(items) }
}
