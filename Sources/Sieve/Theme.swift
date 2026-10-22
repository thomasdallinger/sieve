import AppKit
import SieveCore
import SwiftUI

/// Sieve's visual language: content floats on cards over a cool ink canvas, one violet accent marks what is
/// selected or matched, and everything else stays in three levels of grey.
enum Theme {
    static let rowHeight: CGFloat = 26
    static let searchRowHeight: CGFloat = 30
    static let nameFont = NSFont.systemFont(ofSize: 13)
    static let smallFont = NSFont.systemFont(ofSize: 11)
    static let monoDigits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let motion: TimeInterval = 0.16
    static let cardRadius: CGFloat = 10
    static let cardGap: CGFloat = 8
    static let rowRadius: CGFloat = 7

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> NSColor {
        NSColor(name: name) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, isDark ? darkAlpha ?? alpha : alpha)
        }
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Sieve violet: selection, active filters, matches, the AI lane.
    static let accent = dynamic("SieveAccent", light: 0x5B4CF0, dark: 0x8F84FF)
    /// Solid selection behind white text (deeper than `accent` in dark mode for contrast).
    static let selection = dynamic("SieveSelection", light: 0x5B4CF0, dark: 0x6352F0)
    /// The accent as a quiet tint: unfocused selection trail, chip backgrounds, match highlights.
    static let accentSoft = dynamic("SieveAccentSoft", light: 0x5B4CF0, dark: 0x8F84FF, alpha: 0.13, darkAlpha: 0.24)
    /// Text on the accent tint.
    static let accentText = dynamic("SieveAccentText", light: 0x3F31D1, dark: 0xB4ACFF)
    /// Window background behind the cards.
    static let canvas = dynamic("SieveCanvas", light: 0xEDEDF2, dark: 0x111115)
    /// Cards: columns, lists, results, preview.
    static let card = dynamic("SieveCard", light: 0xFFFFFF, dark: 0x1A1A20)
    static let cardBorder = dynamic("SieveCardBorder", light: 0x000000, dark: 0xFFFFFF, alpha: 0.07)
    static let hover = dynamic("SieveHover", light: 0x000000, dark: 0xFFFFFF, alpha: 0.045)
    static let sidebar = dynamic("SieveSidebar", light: 0xE6E6EC, dark: 0x0C0C0F)

    static var swiftAccent: Color { Color(nsColor: accent) }

    /// Name with the extension in secondary color and query matches marked in the accent.
    static func name(_ item: FileItem, query: SearchQuery? = nil, font: NSFont = nameFont, dimmed: Bool = false,
                     onSelection: Bool = false) -> NSAttributedString {
        let (stem, ext) = item.displayParts
        let primary: NSColor = onSelection ? .white : dimmed ? .secondaryLabelColor : .labelColor
        let secondary: NSColor = onSelection ? NSColor.white.withAlphaComponent(0.7) : .secondaryLabelColor
        let out = NSMutableAttributedString(string: stem, attributes: [.font: font, .foregroundColor: primary])
        if !ext.isEmpty {
            out.append(NSAttributedString(string: ext, attributes: [.font: font, .foregroundColor: secondary]))
        }
        if let query, !query.isEmpty {
            let full = out.string
            let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            for range in query.highlightRanges(in: full) {
                let ns = NSRange(range, in: full)
                if onSelection {
                    out.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .font: bold], range: ns)
                } else {
                    out.addAttributes([.backgroundColor: accentSoft, .foregroundColor: accentText, .font: bold], range: ns)
                }
            }
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// Row with Sieve's selection: a solid accent pill where the keyboard is, a soft tinted pill for the trail of
/// folders behind it, and a faint hover.
final class SieveRowView: NSTableRowView {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var pill: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: Theme.rowRadius, yRadius: Theme.rowRadius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected, !isGroupRowStyle else { return }
        Theme.hover.setFill()
        pill.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.selection : Theme.accentSoft).setFill()
        pill.fill()
    }

    /// Text on the soft trail pill stays dark; only the solid pill turns it white.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

/// Rounded card on the canvas. Content added to `contentView` is clipped to the rounded corners.
final class CardView: NSView {
    let contentView = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        addSubview(contentView)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.card.cgColor
            layer?.borderColor = Theme.cardBorder.cgColor
        }
    }
}

/// Plain view filled with a theme color (canvas, sidebar), following light and dark mode.
final class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// Small rounded toggle used for scopes: accent when selected, quiet tint otherwise.
final class PillButton: NSButton {
    var isOn = false { didSet { updateLook() } }

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 12, weight: .medium)
        updateLook()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 20, height: 24)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isOn ? Theme.selection : Theme.hover).cgColor
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: isOn ? NSColor.white : NSColor.labelColor,
        ])
    }
}
