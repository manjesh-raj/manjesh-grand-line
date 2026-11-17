// Grand Line - native macOS app.
//
// S25 of the 2026-11-17 UI/UX proposals: a choice drawn as a card.
//
// The welcome sheet's first step asked "How will you use Grand Line?" with
// Personal as a secondary button and Operator as a primary one, which read as
// "Operator is the recommended answer" when the question is who you are, and
// each description sat under its button rather than in the choice. A choice
// card is equal weight for every answer: a title, the description inside the
// card, and a selected ring with a check on the one that is chosen.
//
// It is a radio button to VoiceOver, it takes keyboard focus, Return or Space
// picks it, and the arrow keys move the choice to the previous or next card
// in the same group (its siblings in the superview), the way a radio group
// does.

import AppKit

final class HelmChoiceCard: NSView {

    static let ringWidth: CGFloat = 2
    static let checkSize: CGFloat = 14

    /// Called when this card is picked by a click, a key or VoiceOver.
    var onPick: (() -> Void)?

    private(set) var isSelected = false
    private let hover = HoverHighlightView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(title: String, body: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rRow
        layer?.borderWidth = 1
        focusRingType = .exterior

        titleLabel.stringValue = title
        titleLabel.font = HelmType.cardTitle()
        bodyLabel.stringValue = body
        bodyLabel.font = HelmType.caption()
        bodyLabel.maximumNumberOfLines = 0
        for label in [titleLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        check.image = HelmSymbol.image("checkmark.circle.fill", pointSize: Self.checkSize, weight: .semibold)
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [check, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = HelmMetrics.s2
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [titleRow, bodyLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1
        column.translatesAutoresizingMaskIntoConstraints = false

        hover.cornerRadius = HelmMetrics.rRow
        hover.translatesAutoresizingMaskIntoConstraints = false
        hover.accessibilityRoleOverride = .radioButton
        hover.accessibilityLabelOverride = "\(title). \(body)"
        hover.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        hover.onAccessibilityPress = { [weak self] in self?.pick() }
        hover.addSubview(column)
        addSubview(hover)
        let inset = HelmMetrics.s4
        NSLayoutConstraint.activate([
            hover.leadingAnchor.constraint(equalTo: leadingAnchor),
            hover.trailingAnchor.constraint(equalTo: trailingAnchor),
            hover.topAnchor.constraint(equalTo: topAnchor),
            hover.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -inset),
            column.topAnchor.constraint(equalTo: hover.topAnchor, constant: inset),
            column.bottomAnchor.constraint(lessThanOrEqualTo: hover.bottomAnchor, constant: -inset),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        hover.setAccessibilityValue(selected ? 1 : 0)
        applyTheme(theme)
    }

    @objc private func clicked() { pick() }

    private func pick() { onPick?() }

    /// Gotcha (22): the description wraps at the card's own width less its
    /// insets, never at a width it decided.
    override func layout() {
        super.layout()
        let width = max(80, bounds.width - 2 * HelmMetrics.s4)
        if abs(bodyLabel.preferredMaxLayoutWidth - width) > 0.5 {
            bodyLabel.preferredMaxLayoutWidth = width
            bodyLabel.invalidateIntrinsicContentSize()
        }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    // GL-16: a focusable view draws a real exterior ring.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: HelmMetrics.rRow, yRadius: HelmMetrics.rRow).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: // Return, Space, Enter
            pick()
        case 123, 126: // left, up
            moveChoice(by: -1)
        case 124, 125: // right, down
            moveChoice(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    /// The cards in this card's group: its siblings, in order.
    private var group: [HelmChoiceCard] {
        superview?.subviews.compactMap { $0 as? HelmChoiceCard } ?? [self]
    }

    private func moveChoice(by step: Int) {
        let cards = group
        guard let index = cards.firstIndex(where: { $0 === self }) else { return }
        let next = cards[(index + step + cards.count) % cards.count]
        next.pick()
        window?.makeFirstResponder(next)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accent = HelmTheme.nsColor(theme.accentHex)
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderWidth = isSelected ? Self.ringWidth : 1
        layer?.borderColor = (isSelected ? accent : HelmTheme.nsColor(theme.chromeLineHex)).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
        check.contentTintColor = isSelected ? accent : HelmTheme.nsColor(theme.chromeLineHex)
        check.image = HelmSymbol.image(isSelected ? "checkmark.circle.fill" : "circle", pointSize: Self.checkSize,
                                       weight: .semibold)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugBody: String { bodyLabel.stringValue }
    var debugBorderWidth: CGFloat { layer?.borderWidth ?? 0 }
    func debugPress() { _ = hover.accessibilityPerformPress() }
    func debugKey(_ keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: " ",
                                           charactersIgnoringModifiers: " ", isARepeat: false, keyCode: keyCode)
        else { return }
        keyDown(with: event)
    }
    #endif
}
