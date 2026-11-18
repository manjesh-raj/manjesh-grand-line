// Grand Line - native macOS app.
//
// The feel pass's hero (the Fable second-opinion review, Stage 1: "a gradient
// hero for the briefing with the ring gauge inside it"). One full-width card
// on the theme's accent, washed from a lighter corner to a deeper one, with a
// soft glow in the top-right, a kicker, a headline, a short body, up to two
// actions and an 86pt count ring on the trailing side.
//
// **The gradient is the accent, and the ink is measured against it.** The
// prototype draws white text on the accent at 92% and the accent at 62%. On a
// pale accent (Ayu's amber, Alucard's pink) white would sit far under the
// text floor, so `palette(for:)` deepens both stops by the smallest step that
// lets white clear `HelmContrast.textTarget` against the *lighter* stop - the
// darker one then clears it by construction - and only where no deepening
// can do it does the ink step toward black instead. The rule is asserted for
// every theme the app ships (`FeelPassSelfTest`).
//
// **The gradient and the glow are `HelmHeroSurface`'s** (1.0.2). The recipe
// and the palette rule moved there when two Home cards took the hero style,
// so this card and `HelmModuleCard` paint one copy of it.
//
// **Not a button.** The hero's actions are real `HelmButton`s; the card
// itself takes no click, so there is no second target competing with them
// (gotcha (20)).

import AppKit

final class HelmHeroCard: NSView {

    /// The colours one hero is drawn in. The recipe lives on
    /// `HelmHeroSurface`, which a module card paints too.
    typealias Palette = HelmHeroSurface.Palette

    static var startLift: Double { HelmHeroSurface.startLift }
    static let insets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 28)
    static let titleSize: CGFloat = 22
    static let bodySize: CGFloat = 13.5
    static let bodyLines = 3
    /// The prototype's `max-width: 62ch` for the body, in points at 13.5.
    static let textMaxWidth: CGFloat = 560

    struct Content: Equatable {
        var kicker: String
        var title: String
        var body: String
        /// A count ring and the words under it. `nil` hides the ring.
        var ring: Ring?

        struct Ring: Equatable {
            var value: Int
            var total: Int
            var caption: String
        }
    }

    /// The gradient and the glow - the one copy of the recipe.
    private let surface = HelmHeroSurface()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let actionsRow = NSStackView()
    /// The prototype's 86pt ring (`HelmRingGauge.heroSide`).
    private let ring = HelmRingGauge(side: HelmRingGauge.heroSide)
    private let ringCaption = NSTextField(labelWithString: "")
    private let ringColumn = NSStackView()
    private let textColumn = NSStackView()
    private var content = Content(kicker: "", title: "", body: "", ring: nil)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        kickerLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.font = .systemFont(ofSize: HelmType.scaled(Self.bodySize))
        bodyLabel.maximumNumberOfLines = Self.bodyLines
        // Word wrapping, with an ellipsis only on the last line it keeps: a
        // truncating break mode on a wrapping cell makes it one line.
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.cell?.truncatesLastVisibleLine = true
        for label in [kickerLabel, titleLabel, bodyLabel] as [NSTextField] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // Gotcha (5): the words give way, never the card.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        actionsRow.orientation = .horizontal
        actionsRow.spacing = HelmMetrics.s2
        actionsRow.detachesHiddenViews = true

        textColumn.setViews([kickerLabel, titleLabel, bodyLabel, actionsRow], in: .top)
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = HelmMetrics.s2
        textColumn.setCustomSpacing(HelmMetrics.s1 + 2, after: kickerLabel)
        textColumn.setCustomSpacing(HelmMetrics.s3 + 2, after: bodyLabel)
        textColumn.detachesHiddenViews = true
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        ringCaption.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .medium)
        ringCaption.alignment = .center
        ringCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        ringColumn.setViews([ring, ringCaption], in: .top)
        ringColumn.orientation = .vertical
        ringColumn.alignment = .centerX
        ringColumn.spacing = HelmMetrics.s1 + 2
        ringColumn.detachesHiddenViews = true
        ringColumn.translatesAutoresizingMaskIntoConstraints = false
        // Below the caption's required width: a required hug here tied with
        // it, and the caption lost - "services healthy" clipped to the ring's
        // 86pt (measured in a tour render).
        ringColumn.setHuggingPriority(.defaultHigh, for: .horizontal)
        ringColumn.setClippingResistancePriority(.required, for: .horizontal)

        addSubview(textColumn)
        addSubview(ringColumn)
        let i = Self.insets
        NSLayoutConstraint.activate([
            textColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
            textColumn.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
            textColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -i.bottom),
            textColumn.trailingAnchor.constraint(lessThanOrEqualTo: ringColumn.leadingAnchor, constant: -HelmMetrics.s5),
            textColumn.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -i.right),
            textColumn.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textMaxWidth),
            ringColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right),
            ringColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            ringColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: i.top),
            ringColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -i.bottom),
        ])
        // The card is as tall as its text column, or its ring when that is
        // taller - each a required floor, so neither is clipped.
        let tall = heightAnchor.constraint(equalToConstant: 0)
        tall.priority = .defaultLow
        tall.isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    /// The words and the ring.
    func configure(_ content: Content) {
        self.content = content
        kickerLabel.stringValue = content.kicker.uppercased()
        kickerLabel.isHidden = content.kicker.isEmpty
        titleLabel.stringValue = content.title
        bodyLabel.stringValue = content.body
        bodyLabel.isHidden = content.body.isEmpty
        if let value = content.ring {
            ringColumn.isHidden = false
            ring.configure(value: value.value, total: value.total)
            ring.setSpokenLabel("\(value.value) of \(value.total) \(value.caption)")
            ringCaption.stringValue = value.caption
        } else {
            ringColumn.isHidden = true
        }
        setAccessibilityLabel([content.kicker, content.title, content.body,
                               content.ring.map { "\($0.value) of \($0.total) \($0.caption)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        applyTheme(theme)
        needsLayout = true
    }

    /// Up to two actions under the body, in order. A card with none shows no
    /// row at all.
    func setActions(_ buttons: [HelmButton]) {
        for view in actionsRow.arrangedSubviews {
            actionsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for button in buttons.prefix(2) {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionsRow.addArrangedSubview(button)
        }
        actionsRow.isHidden = buttons.isEmpty
    }

    // MARK: The palette

    /// The hero's colours for `theme`. See `HelmHeroSurface` for the rule.
    static func palette(for theme: HelmTheme) -> Palette {
        HelmHeroSurface.palette(for: theme)
    }

    static func palette(accent: (Double, Double, Double)) -> Palette {
        HelmHeroSurface.palette(accent: accent)
    }

    // MARK: Theme and layout

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = Self.palette(for: theme)
        let ink = HelmContrast.color(palette.ink)
        let radius = HelmModuleCard.cornerRadius(for: theme)
        // The app's one gradient gate, as at every other gradient site
        // (`DaylightHardeningSelfTest` guards it): instant under Reduce
        // Motion, and a theme change is the window's own crossfade anyway.
        // The surface's own colour writes go through the same gate.
        HelmMotion.withoutImplicitAnimation {
            layer?.cornerRadius = radius
        }
        surface.apply(palette)
        // The kicker keeps the page's kicker recipe, in the hero's ink.
        kickerLabel.attributedStringValue = NSAttributedString(string: kickerLabel.stringValue,
                                                               attributes: HelmType.kickerAttributes(color: ink))
        titleLabel.textColor = ink
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .bold)
        bodyLabel.textColor = ink
        bodyLabel.font = .systemFont(ofSize: HelmType.scaled(Self.bodySize))
        ringCaption.textColor = ink
        ring.valueColorOverride = ink
        ring.trackColorOverride = ink.withAlphaComponent(0.25)
        ring.labelColorOverride = ink
        ring.applyTheme(theme, hue: .blue)
        // Item 2 of `ThemeManager`'s checklist: system-resolved colours in the
        // buttons follow the theme's mode, not the OS's.
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        // Gotcha (22): the body wraps at a width this label does not decide -
        // the card's own, less the insets and the ring's column.
        let ringRoom = ringColumn.isHidden ? 0 : ringColumn.fittingSize.width + HelmMetrics.s5
        let width = min(Self.textMaxWidth,
                        max(120, floor(bounds.width - Self.insets.left - Self.insets.right - ringRoom)))
        if abs(bodyLabel.preferredMaxLayoutWidth - width) > 0.5 {
            bodyLabel.preferredMaxLayoutWidth = width
            bodyLabel.invalidateIntrinsicContentSize()
        }
    }

    #if FM_SELFTESTS
    var debugContent: Content { content }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugBodyColor: NSColor? { bodyLabel.textColor }
    var debugGradientColors: [CGColor] { surface.debugGradientColors }
    var debugRing: HelmRingGauge { ring }
    var debugRingShown: Bool { !ringColumn.isHidden }
    var debugActionTitles: [String] { actionsRow.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    #endif
}
