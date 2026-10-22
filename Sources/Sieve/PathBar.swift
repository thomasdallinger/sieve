import AppKit
import SieveCore

/// Toolbar location pill: clickable breadcrumbs for the current item; click the empty part (or ⌘L) to type a
/// path, with Tab completion.
final class LocationBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((String) -> Void)?
    private let crumbs = NSStackView()
    private let field = NSTextField()
    private var path = NSHomeDirectory()

    override var intrinsicContentSize: NSSize { NSSize(width: 420, height: 28) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumbs.orientation = .horizontal
        crumbs.spacing = 2
        crumbs.setHuggingPriority(.defaultLow, for: .horizontal)
        crumbs.setClippingResistancePriority(.defaultLow, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        toolTip = "Click to type a path (⌘L)"
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.placeholderString = "Jump to a path…  (Tab completes, Esc cancels)"
        field.isHidden = true
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        for v in [crumbs, field] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            crumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        let preferred = widthAnchor.constraint(equalToConstant: 520)
        preferred.priority = .defaultLow
        preferred.isActive = true
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.hover.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(path: String) {
        guard path != self.path || crumbs.arrangedSubviews.isEmpty else { return }
        self.path = path
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Paths inside home start at the home folder; everything else at the disk.
        var parts: [String] = []
        var p = path
        while true {
            parts.insert(p, at: 0)
            if p == "/" || p == NSHomeDirectory() { break }
            p = (p as NSString).deletingLastPathComponent
        }
        // Deep paths keep the first crumb and the last three; the middle collapses into "…" (click to type).
        if parts.count > 5 { parts = [parts[0], "…"] + parts.suffix(3) }
        for (i, crumbPath) in parts.enumerated() {
            if crumbPath == "…" {
                let more = NSButton(title: "…", target: self, action: #selector(ellipsisClicked))
                more.isBordered = false
                more.font = .systemFont(ofSize: 12)
                more.contentTintColor = .secondaryLabelColor
                more.toolTip = path
                crumbs.addArrangedSubview(more)
                continue
            }
            if i > 0 {
                let sep = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!
                    .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))!)
                sep.contentTintColor = .tertiaryLabelColor
                crumbs.addArrangedSubview(sep)
            }
            let button = NSButton(title: crumbTitle(crumbPath), image: IconProvider.shared.icon(forPath: crumbPath), target: self, action: #selector(crumbClicked(_:)))
            button.image?.size = NSSize(width: 14, height: 14)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: i == parts.count - 1 ? .semibold : .regular)
            button.contentTintColor = i == parts.count - 1 ? .labelColor : .secondaryLabelColor
            button.identifier = NSUserInterfaceItemIdentifier(crumbPath)
            button.toolTip = crumbPath
            button.setContentCompressionResistancePriority(i == parts.count - 1 ? .defaultHigh : .defaultLow - Float(parts.count - i), for: .horizontal)
            crumbs.addArrangedSubview(button)
        }
    }

    private func crumbTitle(_ p: String) -> String {
        p == "/" ? SidebarViewController.title(for: "/") : FileManager.default.displayName(atPath: p)
    }

    @objc private func ellipsisClicked() { beginEditing() }

    @objc private func crumbClicked(_ sender: NSButton) {
        if let p = sender.identifier?.rawValue { onNavigate?(p) }
    }

    override func mouseDown(with event: NSEvent) { beginEditing() }

    func beginEditing(initial: String? = nil) {
        crumbs.isHidden = true
        field.isHidden = false
        field.stringValue = initial ?? (Format.displayPath(path) + (path == "/" ? "" : "/"))
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func endEditing() {
        field.isHidden = true
        crumbs.isHidden = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let target = (field.stringValue as NSString).expandingTildeInPath
            endEditing()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target, isDirectory: &isDir) {
                onNavigate?(target.count > 1 && target.hasSuffix("/") ? String(target.dropLast()) : target)
            } else {
                NSSound.beep()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            onNavigate?(path)
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete(textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    /// Completes the last path component to the longest prefix shared by the matching entries.
    private func complete(_ textView: NSTextView) {
        let typed = field.stringValue
        let expanded = (typed as NSString).expandingTildeInPath
        let dir = typed.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = typed.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { NSSound.beep(); return }
        let matches = names.filter { !$0.hasPrefix(".") || prefix.hasPrefix(".") }
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.sorted()
        guard let first = matches.first else { NSSound.beep(); return }
        var common = first
        for m in matches.dropFirst() {
            while !m.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
        }
        var completed = (dir as NSString).appendingPathComponent(common)
        var isDir: ObjCBool = false
        if matches.count == 1, FileManager.default.fileExists(atPath: completed, isDirectory: &isDir), isDir.boolValue { completed += "/" }
        field.stringValue = Format.displayPath(completed.hasSuffix("/") ? String(completed.dropLast()) : completed) + (completed.hasSuffix("/") ? "/" : "")
        textView.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        if matches.count > 1 { NSSound.beep() }
    }
}

/// Bottom strip: what the current folder or search shows, and how the index is doing.
final class StatusBar: NSView {
    let status = NSTextField(labelWithString: "")
    private let index = NSTextField(labelWithString: "")
    private let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [status, index] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        index.alignment = .right
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -16),
            index.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            index.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: index.leadingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(status text: String) { status.stringValue = text }

    /// "Index live · 907,785 names" with a green dot, or an amber dot while the first walk is running.
    func showIndex(names: Int, building: Bool) {
        index.stringValue = building ? "Indexing · \(names.formatted()) names" : "Index live · \(names.formatted()) names"
        dot.layer?.backgroundColor = (building ? NSColor.systemOrange : NSColor.systemGreen).cgColor
    }
}
