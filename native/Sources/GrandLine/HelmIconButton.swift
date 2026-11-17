// Grand Line - native macOS app.
//
// S20 of the 2026-11-17 UI/UX proposals: one recipe for a glyph-only button.
//
// Glyph-only buttons on cards and rows were drawn at the glyph's own size,
// about 16pt, with no visible hit area - the host card's bolt and pencil sat
// 12pt apart. Apple's guidance is a 28pt minimum pointer target on macOS, and
// the app's own bar tiles are 34pt. Keeping card actions always visible was a
// captain choice (H5) and is not changed here; the target under the glyph is.
//
// `HelmIconButton` is that target: the glyph at 14pt in the middle of at least
// 28 x 28pt, invisible at rest, an inset fill under the pointer, a real
// `.exterior` focus ring on keyboard focus (GL-16), and a label that is both
// the tooltip and what VoiceOver reads. It is a sibling of `HelmButton(.quiet)`
// rather than a new `HelmButton` style, because a quiet labelled button and a
// square glyph target answer to different sizing rules.
//
// `UIUXProposalsSelfTest` fails on a bare `NSButton` set to `.imageOnly`
// outside the kit unless its line says why it is exempt.

import AppKit

final class HelmIconButton: NSButton {

    static let minimumSide: CGFloat = 28
    static let glyphPointSize: CGFloat = 14

    /// A hue for the glyph (contrast-corrected against the surface), or `nil`
    /// for the muted ink a resting card action wears.
    var tint: HelmTint? { didSet { if tint != oldValue { restyle() } } }

    private(set) var symbolName: String
    private var isHovering = false
    private var tracking: NSTrackingArea?
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(symbol: String, label: String, target: AnyObject? = nil, action: Selector? = nil) {
        symbolName = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumSide, height: Self.minimumSide))
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rControl
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        setLabel(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSide),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSide),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.minimumSide, height: Self.minimumSide) }

    /// The tooltip and the accessibility label are one string.
    func setLabel(_ label: String) {
        toolTip = label
        setAccessibilityLabel(label)
    }

    func setSymbol(_ symbol: String) {
        guard symbol != symbolName else { return }
        symbolName = symbol
        restyle()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        restyle()
    }

    private func restyle() {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let glyph: NSColor = tint.map {
            HelmContrast.legibleTintedText(tintHex: $0.hex(in: theme), over: surface, theme: theme)
        } ?? HelmTheme.mutedInk(theme)
        image = HelmSymbol.image(symbolName, pointSize: Self.glyphPointSize, weight: .medium)
        contentTintColor = glyph
        layer?.backgroundColor = isHovering && isEnabled ? HelmField.fill(theme).cgColor : NSColor.clear.cgColor
    }

    // MARK: Hover and focus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        HelmMotion.withoutImplicitAnimation { restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        HelmMotion.withoutImplicitAnimation { restyle() }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: HelmMetrics.rControl, yRadius: HelmMetrics.rControl).fill()
    }

    #if FM_SELFTESTS
    var debugGlyphColor: NSColor? { contentTintColor }
    var debugHoverFill: NSColor? { layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    func debugHover(_ on: Bool) {
        isHovering = on
        restyle()
    }
    #endif
}
