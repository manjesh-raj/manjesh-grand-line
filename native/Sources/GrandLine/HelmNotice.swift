// Grand Line - native macOS app.
//
// S17 of the 2026-11-17 UI/UX proposals: one banner for "something on this
// page needs you".
//
// Four pages put a notice above their content and each drew it differently:
//
//   - Home's tip was a row with a blue accent edge and a quiet action, on a
//     page whose rule (UI-4) is that only the attention card carries an edge.
//   - Secrets' Automic Vault page painted a full-width amber band with bold
//     amber text.
//   - GitHub sync's "Pushing is paused" was a card with a red edge, a tile and
//     two buttons under the text (`SetupPausedPushNotice`, now removed).
//   - Crew's answer banner was a row with a blue edge, a kicker, a title, a
//     body and a link pill.
//
// `HelmNotice` is the one recipe: a card surface, a tinted tile, an optional
// kicker, a title, a body and up to two actions on the trailing side. The
// edge rule becomes code rather than convention: an informational notice
// (any tint but `.warn` and `.critical`) has no edge, and a warning or a
// failure carries the card's 3pt attention edge in its own hue, because an
// edge means "this needs you".
//
// A dismissible notice adds a quiet trailing button. The caller owns what
// "dismissed" means and where it is remembered (Home's tips use
// `AppSettings.homeTipsDismissed`), so the notice never invents a second
// store for a setting that already has one.

import AppKit

final class HelmNotice: NSView {

    struct Content: Equatable {
        var tint: HelmTint
        var symbol: String
        /// Uppercased and kern'd, in `mutedInk`. For a notice that is one of a
        /// series ("Things you can do · day 1 of 7").
        var kicker: String? = nil
        var title: String
        var body: String? = nil
    }

    static let tileSide: CGFloat = 30
    /// At most two actions: a notice asks for one thing, sometimes with an
    /// alternative.
    static let maximumActions = 2

    /// Whether a notice in `tint` carries the attention edge.
    static func hasEdge(_ tint: HelmTint) -> Bool { tint == .warn || tint == .critical }

    let card = HelmCard()
    private let tile = IconTileView(size: HelmNotice.tileSide, cornerRadius: 8)
    private let kickerLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let actions = NSStackView()
    private var dismissButton: HelmButton?
    private var content = Content(tint: .info, symbol: "info.circle", title: "")
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Called after the dismiss button hides the notice.
    var onDismiss: (() -> Void)?

    /// - Parameters:
    ///   - actions: up to two `HelmButton`s, on the trailing side.
    ///   - dismissTitle: when given, a quiet trailing button that hides the
    ///     notice and calls `onDismiss`.
    init(actions buttons: [NSView] = [], dismissTitle: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        precondition(buttons.count <= Self.maximumActions, "a HelmNotice takes at most two actions")

        kickerLabel.font = HelmType.kicker()
        titleLabel.font = HelmType.cardTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.font = HelmType.body()
        bodyLabel.maximumNumberOfLines = 0
        for label in [kickerLabel, titleLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [kickerLabel, titleLabel, bodyLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s1
        text.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        actions.translatesAutoresizingMaskIntoConstraints = false
        for button in buttons { actions.addArrangedSubview(button) }
        if let dismissTitle {
            let button = HelmButton(title: dismissTitle, variant: .quiet, size: .small,
                                    target: self, action: #selector(dismissTapped))
            dismissButton = button
            actions.addArrangedSubview(button)
        }
        for view in actions.arrangedSubviews {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        actions.isHidden = actions.arrangedSubviews.isEmpty

        // Gotcha (10): `.fill` with only the text column flexible.
        let row = NSStackView(views: [tile, text, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false

        card.setBody(row, insets: HelmCard.contentInsets)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ content: Content, theme: HelmTheme) {
        self.content = content
        kickerLabel.isHidden = (content.kicker ?? "").isEmpty
        titleLabel.stringValue = content.title
        bodyLabel.stringValue = content.body ?? ""
        bodyLabel.isHidden = (content.body ?? "").isEmpty
        tile.configure(symbol: content.symbol, tint: content.tint)
        card.setAttentionEdge(Self.hasEdge(content.tint) ? content.tint : nil)
        setAccessibilityLabel([content.kicker, content.title, content.body].compactMap { $0 }.joined(separator: ". "))
        applyTheme(theme)
        needsLayout = true
    }

    /// Replaces the trailing actions (a dismiss button, if any, stays last).
    func setActions(_ buttons: [NSView]) {
        precondition(buttons.count <= Self.maximumActions, "a HelmNotice takes at most two actions")
        for view in actions.arrangedSubviews where view !== dismissButton {
            actions.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, button) in buttons.enumerated() {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.insertArrangedSubview(button, at: index)
        }
        actions.isHidden = actions.arrangedSubviews.isEmpty
        needsLayout = true
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        tile.applyTheme(theme)
        let muted = HelmTheme.mutedInk(theme)
        kickerLabel.attributedStringValue = NSAttributedString(
            string: (content.kicker ?? "").uppercased(), attributes: HelmType.kickerAttributes(color: muted))
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        bodyLabel.textColor = muted
    }

    /// Gotcha (22): the body wraps at the notice's own width less the tile,
    /// the actions and the insets - widths the label does not decide.
    override func layout() {
        super.layout()
        let insets = HelmCard.contentInsets
        let actionsWidth = actions.isHidden ? 0 : actions.fittingSize.width + HelmMetrics.s3
        let width = max(160, floor(bounds.width - insets.left - insets.right - Self.tileSide - HelmMetrics.s3
                                   - actionsWidth))
        if abs(bodyLabel.preferredMaxLayoutWidth - width) > 0.5 {
            bodyLabel.preferredMaxLayoutWidth = width
            bodyLabel.invalidateIntrinsicContentSize()
        }
    }

    @objc private func dismissTapped() {
        isHidden = true
        onDismiss?()
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugBody: String { bodyLabel.isHidden ? "" : bodyLabel.stringValue }
    var debugKicker: String { kickerLabel.isHidden ? "" : kickerLabel.stringValue }
    var debugHasEdge: Bool { card.debugAttentionEdgeColor != nil }
    var debugActionTitles: [String] { actions.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    var debugContent: Content { content }
    func debugDismiss() { dismissButton?.performClick(nil) }
    #endif
}
