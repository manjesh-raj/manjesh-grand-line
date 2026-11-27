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

    /// How the button is drawn. `.plain` is the resting card action: a glyph
    /// that only shows a fill on hover. `.circle` is a solid round button of
    /// the given side, for an action that sits on a scene rather than a card
    /// (the lock screen's in-field arrow, the Secrets page's round Touch ID).
    /// The caller derives the colours from its theme.
    enum Style: Equatable {
        case plain
        case circle(side: CGFloat, fill: NSColor, glyph: NSColor, border: NSColor?)
    }

    var style: Style = .plain {
        didSet {
            guard style != oldValue else { return }
            invalidateIntrinsicContentSize()
            restyle()
        }
    }

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

    override var intrinsicContentSize: NSSize {
        if case .circle(let side, _, _, _) = style { return NSSize(width: side, height: side) }
        return NSSize(width: Self.minimumSide, height: Self.minimumSide)
    }

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
        if case .circle(let side, let fill, let glyph, let border) = style {
            image = HelmSymbol.image(symbolName, pointSize: min(Self.glyphPointSize, side * 0.48), weight: .semibold)
            contentTintColor = glyph
            layer?.cornerRadius = side / 2
            // A press or hover darkens the fill a step, the way a HelmButton does.
            let shown = isHovering && isEnabled ? (fill.blended(withFraction: 0.12, of: glyph) ?? fill) : fill
            layer?.backgroundColor = shown.withAlphaComponent(isEnabled ? fill.alphaComponent : fill.alphaComponent * 0.5).cgColor
            layer?.borderWidth = border == nil ? 0 : 1
            layer?.borderColor = border?.cgColor
            return
        }
        layer?.cornerRadius = HelmMetrics.rControl
        layer?.borderWidth = 0
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
        super.mouseEntered(with: event)
        isHovering = true
        HelmMotion.withoutImplicitAnimation { restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        HelmMotion.withoutImplicitAnimation { restyle() }
    }

    /// A `.circle` lays out at exactly its side. A borderless `NSButton`
    /// carries 3.5pt top and bottom alignment insets (measured on macOS 26:
    /// a 32x32 intrinsic size came out as a 32.5x39 frame), so without this
    /// every circle drew as an oval - the Secrets page's round Touch ID
    /// button at 31.5x39 and the lock screen's in-pill arrow at 28x31.
    override var alignmentRectInsets: NSEdgeInsets {
        if case .circle = style { return NSEdgeInsetsZero }
        return super.alignmentRectInsets
    }

    /// Opt-in: Tab reaches this button whether or not macOS's Full Keyboard
    /// Access is on, the way `SceneGateHotspotView` joins its gate's key view
    /// loop (A-02). A click still never takes focus, so a typing-first gate
    /// keeps its field. Only while the button is enabled and visible.
    var joinsKeyViewLoop = false

    override var acceptsFirstResponder: Bool {
        guard joinsKeyViewLoop else { return super.acceptsFirstResponder }
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown?, .rightMouseDown?, .otherMouseDown?: return false
        default: return true
        }
    }

    override var canBecomeKeyView: Bool {
        guard joinsKeyViewLoop else { return super.canBecomeKeyView }
        return acceptsFirstResponder && !bounds.isEmpty
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        if case .circle = style { NSBezierPath(ovalIn: bounds).fill(); return }
        NSBezierPath(roundedRect: bounds, xRadius: HelmMetrics.rControl, yRadius: HelmMetrics.rControl).fill()
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { restyle() } }
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
