// Grand Line - native macOS app.
//
// `HelmMetricCard` - the prototype's summary card: a caption over one large
// number, on the app's one card surface (stage 6 of the modular-shell
// migration). Logs' Errors, Warnings and Patterns and Health's Healthy,
// Warnings, Failing and Not run yet are this card, in a row.
//
// Why not `HelmStatTile`: that tile is a glyph, a 19pt metric and a caption
// under it, sized for a dense strip. The prototype's summary row is a
// different object - a card per figure, the caption first and the number
// large - and drawing it out of a tile would mean overriding the tile's
// fonts and order from outside, which is how a second copy starts.
//
// The rules it carries:
//
//   - **A tint is for a number that is the signal**, and only when it is not
//     zero: "Failing 0" is ink, "Failing 1" is the critical hue. The number is
//     corrected until it clears the text floor on the card
//     (`HelmContrast.legibleTintedText`), because a hue is safe as a fill and
//     not automatically as text (`FM_RUN_CONTRAST_TESTS`' rule).
//   - **Unknown is never zero (GL-14).** `configure(value: nil ...)` draws a
//     dash and says why in the caption's tooltip.

import AppKit

final class HelmMetricCard: NSView {

    static let height: CGFloat = 82
    /// The metric's size: the prototype's summary figure.
    static let metricSize: CGFloat = 26

    private let card = HelmCard()
    private let captionLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var tint: HelmTint?
    private var signals = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(caption: String, tint: HelmTint? = nil) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        captionLabel.stringValue = caption
        captionLabel.font = HelmType.caption()
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.font = HelmType.metric(Self.metricSize)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [captionLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(stack, insets: HelmCard.contentInsets)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The figure, as text ("6 / 8") or a count. `signals` says whether this
    /// figure is the state worth colouring - a non-zero failure count is, a
    /// zero is not. `nil` is a reading not taken yet: a dash, never a zero.
    func configure(text: String?, signals: Bool, unknownReason: String? = nil) {
        valueLabel.stringValue = text ?? "\u{2014}"
        self.signals = signals && text != nil
        toolTip = text == nil ? unknownReason : nil
        setAccessibilityLabel("\(captionLabel.stringValue), \(text ?? "not known yet")")
        applyTheme(theme)
    }

    func configure(count: Int?, unknownReason: String? = nil) {
        configure(text: count.map(String.init), signals: (count ?? 0) > 0, unknownReason: unknownReason)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        captionLabel.textColor = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        if signals, let tint {
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            valueLabel.textColor = HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme), overAnyOf: [surface],
                                                                  theme: theme)
        } else {
            valueLabel.textColor = ink
        }
    }

    #if FM_SELFTESTS
    var debugCaption: String { captionLabel.stringValue }
    var debugValue: String { valueLabel.stringValue }
    var debugValueColor: NSColor? { valueLabel.textColor }
    var debugCard: HelmCard { card }
    #endif
}

/// A row of metric cards sharing the width equally - the prototype's summary
/// row. Equal widths come from `.fillEqually`, which needs no width priority
/// of its own, so nothing here can reach the window (gotcha (13)).
final class HelmMetricRow: NSStackView {
    init(_ cards: [HelmMetricCard]) {
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fillEqually
        alignment = .top
        spacing = HelmMetrics.s4
        translatesAutoresizingMaskIntoConstraints = false
        for card in cards { addArrangedSubview(card) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
