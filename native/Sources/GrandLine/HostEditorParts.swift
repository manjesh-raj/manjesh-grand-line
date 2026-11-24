// Grand Line - native macOS app.
//
// The pieces Host-1 of the Console / Add Host / Add Key board added to the
// host form (`HostEditorController`), and Key-1 reuses for the key form:
//
//   - `RecordPreviewHeader`: the hero at the top of the side panel. It draws
//     the record as its card will look on the Connections page - tile, name,
//     address, environment, key and tags - and the form updates it on every
//     change, so a host is visibly being built rather than described.
//     TK-1 of the hero restyle board puts the same header across the top of
//     the New Task and Edit Task sheet, in its `.sheet` style.
//   - `HostKeyPicker`: the SSH key as a list of real choices (the system
//     agent, then every saved key with its type, how many hosts use it and
//     whether Touch ID guards it), with New Key and Import beside it. It
//     replaces a popup whose closed state showed one title and nothing else.
//
// Neither touches a store. The form hands them plain values and gets back the
// chosen key's id, the same "editor computes, caller persists" split the form
// itself keeps.

import AppKit

// MARK: - RecordPreviewHeader

/// The panel's hero: a gradient (`HelmHeroSurface`, the theme's hero colour)
/// with a kicker, the record's own card and a row of small facts.
final class RecordPreviewHeader: NSView {
    struct Content: Equatable {
        var kicker: String
        var title: String
        /// Shown, in a quieter italic, when `title` is empty.
        var titlePlaceholder: String
        var subtitle: String
        /// A short tag beside the title (an environment, a key type).
        var badge: String?
        var badgeTint: HelmTint = .info
        var facts: [String] = []
        /// A glyph before the subtitle (TK-1's calendar before the due date).
        /// Only the `.sheet` style draws it.
        var subtitleSymbol: String?
    }

    /// How the header is drawn.
    ///
    /// `.panel` is Host-1's, and the default: a rounded hero inside the
    /// inspector's gutter, the plain hero palette, the record's address in
    /// mono under its name, and one row of facts.
    ///
    /// `.sheet` is TK-1's: the head of an editor sheet
    /// (`HelmFormSheet.setHeroHeader`), square and edge to edge, its content
    /// on the sheet's own gutter. It paints the quiet-ink palette, because
    /// its kicker is the ink at less than full strength: on the plain palette
    /// that line sits under the text floor, as `PopoverHeroHeader`'s 86% line
    /// does (4.20:1 on Lavender, the board's measurement). A glass tile leads
    /// the kicker, the card is raised, the subtitle is prose after an
    /// optional glyph, and the facts wrap as shade capsules: white on a wash
    /// of white fails the floor (4.49:1), and a shade can only add contrast.
    enum Style {
        case panel
        case sheet
    }

    let style: Style
    private let hero = HelmHeroSurface()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let kickerTile = NSView()
    private let kickerGlyph = NSImageView()
    private let kickerSymbol: String?
    private let card = NSView()
    let tile: IconTileView
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let subtitleGlyph = NSImageView()
    private let extras = NSStackView()
    private let factsRow = NSStackView()
    /// The `.sheet` style's facts, which wrap rather than truncate: a task
    /// with a repeat, a reminder and two tags carries six.
    private let factsFlow = ChipFlowView()
    private var factLabels: [NSTextField] = []
    private var factChips: [NSView] = []
    private(set) var content = Content(kicker: "", title: "", titlePlaceholder: "", subtitle: "")
    private var observation: ThemeObservation?

    static let cornerRadius: CGFloat = 14
    /// The `.sheet` style's kicker tile, the board's 22pt glass square.
    static let kickerTileSide: CGFloat = 22
    /// The `.sheet` style's insets: 16pt above, 14pt below, and the sheet's
    /// own gutter at the sides so the card lines up with the fields under it.
    static let sheetTopInset: CGFloat = HelmMetrics.s4
    static let sheetBottomInset: CGFloat = HelmMetrics.s3 + HelmMetrics.s0
    /// The gap between the facts in the `.sheet` style, across and down.
    static let factSpacing: CGFloat = HelmMetrics.s1 + HelmMetrics.s0

    /// `extraViews` sit under the subtitle inside the card - a live status
    /// pill, a connection-test pill - and keep their own theming.
    /// `kickerSymbol` names the glyph in the `.sheet` style's kicker tile.
    init(tileSize: CGFloat = 40, extraViews: [NSView] = [], style: Style = .panel, kickerSymbol: String? = nil) {
        self.style = style
        self.kickerSymbol = style == .sheet ? kickerSymbol : nil
        tile = IconTileView(size: tileSize, cornerRadius: 10)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = style == .panel ? Self.cornerRadius : 0
        layer?.masksToBounds = true
        // The board's glow on a band far wider than it is tall: an ellipse
        // from the band's own bounds rather than a card's 220pt circle.
        if style == .sheet { hero.glowShape = .capsule }
        addSubview(hero)

        kickerLabel.translatesAutoresizingMaskIntoConstraints = false
        kickerLabel.lineBreakMode = .byTruncatingTail
        if style == .sheet {
            // Gotcha (13): a label resists compression at 750 by default,
            // over the 500 a window holds its size at, so a long kicker would
            // widen the sheet rather than truncate.
            kickerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        card.wantsLayer = true
        card.layer?.cornerRadius = HelmMetrics.rCard
        card.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.cardTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.font = .systemFont(ofSize: HelmType.scaled(9.5), weight: .heavy)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.wantsLayer = true
        badgeBox.layer?.cornerRadius = HelmMetrics.rChip
        badgeBox.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badgeLabel)
        badgeBox.setContentHuggingPriority(.required, for: .horizontal)
        badgeBox.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -5),
            badgeLabel.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeBox.bottomAnchor, constant: -1),
        ])
        let titleRow = NSStackView(views: [titleLabel, badgeBox])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = HelmMetrics.s1 + 2
        titleRow.distribution = .fill
        subtitleLabel.font = style == .sheet ? HelmType.caption() : HelmType.code()
        subtitleLabel.lineBreakMode = style == .sheet ? .byTruncatingTail : .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleGlyph.translatesAutoresizingMaskIntoConstraints = false
        subtitleGlyph.setContentHuggingPriority(.required, for: .horizontal)
        subtitleGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        subtitleGlyph.isHidden = true
        // The `.sheet` style's glyph sits before the subtitle, centred on the
        // label rather than on its baseline: it is hidden until a record has
        // a symbol, and a baseline constraint in a view a stack detaches
        // throws (gotcha (23)). The `.panel` style keeps its bare label.
        let subtitleView: NSView
        if style == .sheet {
            let row = NSStackView(views: [subtitleGlyph, subtitleLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = HelmMetrics.s1
            row.distribution = .fill
            row.setClippingResistancePriority(.defaultLow, for: .horizontal)
            subtitleView = row
        } else {
            subtitleView = subtitleLabel
        }
        extras.orientation = .vertical
        extras.alignment = .leading
        extras.spacing = HelmMetrics.s0
        extraViews.forEach { extras.addArrangedSubview($0) }
        let text = NSStackView(views: [titleRow, subtitleView, extras])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        tile.setContentHuggingPriority(.required, for: .horizontal)
        tile.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.addSubview(tile)
        card.addSubview(text)
        tile.translatesAutoresizingMaskIntoConstraints = false

        factsRow.orientation = .horizontal
        factsRow.alignment = .centerY
        factsRow.spacing = HelmMetrics.s1
        factsRow.translatesAutoresizingMaskIntoConstraints = false
        factsRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        factsFlow.horizontalSpacing = Self.factSpacing
        factsFlow.rowSpacing = Self.factSpacing

        let kickerView: NSView
        if style == .sheet {
            kickerTile.wantsLayer = true
            kickerTile.layer?.cornerRadius = HelmMetrics.rChip
            kickerTile.layer?.borderWidth = 1
            kickerTile.translatesAutoresizingMaskIntoConstraints = false
            kickerGlyph.translatesAutoresizingMaskIntoConstraints = false
            kickerTile.addSubview(kickerGlyph)
            NSLayoutConstraint.activate([
                kickerTile.widthAnchor.constraint(equalToConstant: Self.kickerTileSide),
                kickerTile.heightAnchor.constraint(equalToConstant: Self.kickerTileSide),
                kickerGlyph.centerXAnchor.constraint(equalTo: kickerTile.centerXAnchor),
                kickerGlyph.centerYAnchor.constraint(equalTo: kickerTile.centerYAnchor),
            ])
            kickerTile.setContentHuggingPriority(.required, for: .horizontal)
            kickerTile.setContentCompressionResistancePriority(.required, for: .horizontal)
            kickerTile.isHidden = self.kickerSymbol == nil
            let row = NSStackView(views: [kickerTile, kickerLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = HelmMetrics.s2 - 1
            row.setClippingResistancePriority(.defaultLow, for: .horizontal)
            kickerView = row
        } else {
            kickerView = kickerLabel
        }
        let facts: NSView = style == .sheet ? factsFlow : factsRow
        let column = NSStackView(views: [kickerView, card, facts])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        // The board's 10pt between the card and the wrapping facts.
        if style == .sheet { column.setCustomSpacing(HelmMetrics.s2 + 2, after: card) }
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let side = style == .sheet ? HelmFormSheet.gutter : HelmMetrics.s3
        let top = style == .sheet ? Self.sheetTopInset : HelmMetrics.s3
        let bottom = style == .sheet ? Self.sheetBottomInset : HelmMetrics.s3
        // The card's own inset: Host-1's 10pt all round, and the board's
        // 10pt by 12pt in the `.sheet` style.
        let cardSide: CGFloat = style == .sheet ? HelmMetrics.s3 : 10
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            hero.topAnchor.constraint(equalTo: topAnchor),
            hero.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            column.topAnchor.constraint(equalTo: topAnchor, constant: top),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottom),
            card.widthAnchor.constraint(equalTo: column.widthAnchor),
            tile.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: cardSide),
            tile.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -cardSide),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10),
            tile.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10),
        ])
        if style == .sheet {
            // The flow wraps against the width it is given, so it is given
            // the column's: a width it decided for itself would be the
            // circular derivation gotcha (22) describes.
            factsFlow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            kickerView.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        } else {
            factsRow.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    func update(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        applyTheme(ThemeManager.shared.theme)
    }

    /// The hero's colours in `theme`: the plain rule for `.panel`, and the
    /// quiet-ink rule for `.sheet`, whose kicker is the ink at 85%.
    func palette(in theme: HelmTheme) -> HelmHeroSurface.Palette {
        guard style == .sheet else { return HelmHeroSurface.palette(for: theme) }
        return HelmHeroSurface.palette(accent: HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex)),
                                       quietInk: Double(HelmHeroColumn.quietInkAlpha))
    }

    /// The kicker's share of the ink.
    static let kickerAlpha: CGFloat = 0.85

    func applyTheme(_ theme: HelmTheme) {
        let palette = palette(in: theme)
        hero.apply(palette)
        let heroInk = HelmContrast.color(palette.ink)
        kickerLabel.attributedStringValue = NSAttributedString(
            string: content.kicker.uppercased(),
            attributes: HelmType.kickerAttributes(color: heroInk.withAlphaComponent(Self.kickerAlpha)))
        if let kickerSymbol {
            kickerTile.layer?.backgroundColor = heroInk.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
            kickerTile.layer?.borderColor = heroInk.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
            kickerGlyph.image = HelmSymbol.image(kickerSymbol, pointSize: 11, weight: .semibold,
                                                 hierarchicalColor: heroInk)
        }
        card.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        if style == .sheet, let layer = card.layer {
            // The board lifts the card off the gradient with a shadow, and
            // the kit's raised elevation is that shadow, applied once.
            HelmCard.applyElevation(.raised, to: layer, theme: theme)
        }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        if content.title.isEmpty {
            let italic = NSFontManager.shared.convert(HelmType.cardTitle(), toHaveTrait: .italicFontMask)
            titleLabel.attributedStringValue = NSAttributedString(
                string: content.titlePlaceholder,
                attributes: [.font: italic, .foregroundColor: muted])
        } else {
            titleLabel.attributedStringValue = NSAttributedString(
                string: content.title, attributes: [.font: HelmType.cardTitle(), .foregroundColor: ink])
        }
        titleLabel.toolTip = content.title.isEmpty ? nil : content.title
        subtitleLabel.stringValue = content.subtitle
        subtitleLabel.textColor = muted
        subtitleLabel.toolTip = content.subtitle
        if style == .sheet, let symbol = content.subtitleSymbol {
            subtitleGlyph.isHidden = false
            subtitleGlyph.image = HelmSymbol.image(symbol, pointSize: 10, weight: .medium, hierarchicalColor: muted)
        } else {
            subtitleGlyph.isHidden = true
        }
        if let badge = content.badge, !badge.isEmpty {
            badgeBox.isHidden = false
            badgeLabel.stringValue = badge.uppercased()
            let resolved = HelmContrast.tintedSurface(tintHex: content.badgeTint.hex(in: theme), theme: theme,
                                                      target: HelmContrast.textTarget)
            badgeBox.layer?.backgroundColor = resolved.fill.cgColor
            badgeLabel.textColor = resolved.foreground
        } else {
            badgeBox.isHidden = true
        }
        tile.applyTheme(theme)
        if style == .sheet {
            renderFactCapsules(ink: heroInk)
        } else {
            renderFacts(ink: heroInk)
        }
        // The `.sheet` style reads its kicker too: it is the only place the
        // sheet still says whether this is a new task or which column it is in.
        let lead = style == .sheet && !content.kicker.isEmpty ? [content.kicker] : []
        setAccessibilityLabel((lead + [content.title.isEmpty ? content.titlePlaceholder : content.title, content.subtitle]
            + (content.badge.map { [$0] } ?? []) + content.facts).joined(separator: ", "))
    }

    private func renderFacts(ink: NSColor) {
        factLabels.forEach { $0.superview?.removeFromSuperview() }
        factLabels = []
        factsRow.isHidden = content.facts.isEmpty
        for fact in content.facts {
            let label = NSTextField(labelWithString: fact)
            label.font = .systemFont(ofSize: HelmType.scaled(10.5), weight: .semibold)
            label.textColor = ink
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            let chip = NSView()
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 6
            chip.layer?.backgroundColor = ink.withAlphaComponent(0.16).cgColor
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = ink.withAlphaComponent(0.28).cgColor
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
                label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
            ])
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            factsRow.addArrangedSubview(chip)
            factLabels.append(label)
        }
    }

    /// The `.sheet` style's facts: `HelmButton`'s hero ghost recipe (a shade
    /// of the ink's opposite under the words, with the glass hairline), as
    /// capsules that wrap onto a second line.
    private func renderFactCapsules(ink: NSColor) {
        let shade = HelmButton.heroShade(for: ink)
        factLabels = []
        factChips = content.facts.map { fact in
            let chip = FactCapsule(text: fact)
            chip.paint(ink: ink, fill: shade.withAlphaComponent(HelmButton.heroFillAlpha),
                       border: ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha))
            factLabels.append(chip.label)
            return chip
        }
        factsFlow.isHidden = factChips.isEmpty
        factsFlow.setChips(factChips)
    }

    /// One fact in the `.sheet` style: 11pt semibold in a capsule.
    private final class FactCapsule: NSView {
        let label: NSTextField

        init(text: String) {
            label = NSTextField(labelWithString: text)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            label.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2 + 1),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HelmMetrics.s2 + 1)),
                label.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s0),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s0),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func paint(ink: NSColor, fill: NSColor, border: NSColor) {
            label.textColor = ink
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border.cgColor
        }

        /// A capsule at whatever height the flow gives it.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            layer?.cornerRadius = newSize.height / 2
        }
    }

    #if FM_SELFTESTS
    var debugTitleText: String { titleLabel.stringValue }
    var debugSubtitleText: String { subtitleLabel.stringValue }
    var debugBadgeText: String? { badgeBox.isHidden ? nil : badgeLabel.stringValue }
    var debugFacts: [String] { factLabels.map(\.stringValue) }
    var debugGradientColors: [CGColor] { hero.debugGradientColors }
    var debugCardFill: NSColor? { card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    var debugKickerText: String { kickerLabel.stringValue }
    var debugKickerColor: NSColor? {
        kickerLabel.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    var debugKickerTileHidden: Bool { kickerTile.isHidden || kickerSymbol == nil }
    var debugSubtitleGlyphHidden: Bool { subtitleGlyph.isHidden }
    /// The `.sheet` style's fact capsules: their words' colour, fill and edge.
    var debugFactPaint: [(text: NSColor?, fill: NSColor?, border: NSColor?)] {
        factChips.compactMap { $0 as? FactCapsule }.map { chip in
            (chip.label.textColor,
             chip.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
             chip.layer?.borderColor.flatMap { NSColor(cgColor: $0) })
        }
    }
    var debugFactFrames: [NSRect] { factChips.map(\.frame) }
    var debugCardShadowAlpha: CGFloat { card.layer.map(HelmCard.debugEffectiveShadowAlpha(of:)) ?? 0 }
    var debugCornerRadius: CGFloat { layer?.cornerRadius ?? -1 }
    #endif
}

// MARK: - HostKeyPicker

/// Host-1's SSH key chooser: one row per choice, the chosen one ringed.
final class HostKeyPicker: NSView {
    struct Option: Equatable {
        /// `nil` is the system ssh agent.
        let id: UUID?
        let title: String
        let detail: String
        /// Whether the app's Touch ID gate stands in front of this key. True
        /// for every saved key on a Mac with biometry; never for the agent.
        let touchID: Bool
    }

    var onSelect: ((UUID?) -> Void)?
    var onNewKey: (() -> Void)?
    var onImport: (() -> Void)?

    private let rowsStack = NSStackView()
    private var rows: [(option: Option, view: HoverHighlightView, radio: NSImageView,
                        title: NSTextField, detail: NSTextField, chip: NSView?, chipLabel: NSTextField?)] = []
    private(set) var options: [Option] = []
    private(set) var selectedID: UUID?
    private lazy var newKeyButton = HelmButton(title: "New Key\u{2026}", variant: .secondary, size: .small,
                                               symbol: "plus", target: self, action: #selector(newKeyClicked))
    private lazy var importButton = HelmButton(title: "Import\u{2026}", variant: .secondary, size: .small,
                                               symbol: "square.and.arrow.down", target: self,
                                               action: #selector(importClicked))
    private var observation: ThemeObservation?
    private var actionsRow: NSStackView?
    /// Whether New Key and Import show under the list. The key form's
    /// "From ~/.ssh" list reuses this picker without them.
    var showsActions = true {
        didSet { actionsRow?.isHidden = !showsActions }
    }
    var wellSurface: HelmField.Surface = .raised {
        didSet { if wellSurface != oldValue { applyTheme(ThemeManager.shared.theme) } }
    }

    static let rowHeight: CGFloat = 46

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = HelmMetrics.s1 + 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        newKeyButton.toolTip = "Make a new key without leaving this form"
        importButton.toolTip = "Import an existing private key file"
        let actions = NSStackView(views: [newKeyButton, importButton, NSView()])
        actions.orientation = .horizontal
        actions.spacing = HelmMetrics.s2
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionsRow = actions
        let column = NSStackView(views: [rowsStack, actions])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            actions.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("SSH key")
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    func setOptions(_ options: [Option], selected: UUID?) {
        self.options = options
        selectedID = options.contains { $0.id == selected } ? selected : nil
        rows.forEach { $0.view.removeFromSuperview() }
        rows = []
        for (index, option) in options.enumerated() {
            let row = HoverHighlightView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            row.identifier = NSUserInterfaceItemIdentifier("key-option-\(index)")
            let radio = NSImageView()
            radio.translatesAutoresizingMaskIntoConstraints = false
            radio.setContentHuggingPriority(.required, for: .horizontal)
            let title = NSTextField(labelWithString: option.title)
            title.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField(labelWithString: option.detail)
            detail.font = HelmType.caption()
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            text.setClippingResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [radio, text]
            var chip: NSView?
            var chipLabel: NSTextField?
            if option.touchID {
                let label = NSTextField(labelWithString: "Touch ID")
                label.font = .systemFont(ofSize: HelmType.scaled(10), weight: .semibold)
                label.translatesAutoresizingMaskIntoConstraints = false
                let box = NSView()
                box.wantsLayer = true
                box.layer?.cornerRadius = 6
                box.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
                    label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
                    label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
                ])
                box.setContentHuggingPriority(.required, for: .horizontal)
                box.setContentCompressionResistancePriority(.required, for: .horizontal)
                box.toolTip = "Touch ID or your Mac password unlocks this key when a host connects with it"
                views.append(box)
                chip = box
                chipLabel = label
            }
            let line = NSStackView(views: views)
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = HelmMetrics.s2 + 1
            line.distribution = .fill
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            ])
            row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
            row.accessibilityRoleOverride = .radioButton
            row.accessibilityLabelOverride = [option.title, option.detail, option.touchID ? "Touch ID" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            rows.append((option, row, radio, title, detail, chip, chipLabel))
        }
        applyTheme(ThemeManager.shared.theme)
    }

    func select(_ id: UUID?) {
        selectedID = id
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view, let row = rows.first(where: { $0.view === view }) else { return }
        select(row.option.id)
        onSelect?(row.option.id)
    }

    @objc private func newKeyClicked() { onNewKey?() }
    @objc private func importClicked() { onImport?() }

    func applyTheme(_ theme: HelmTheme) {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let fill = HelmField.fill(theme, surface: wellSurface)
        let ink = HelmField.ink(theme, surface: wellSurface)
        let muted = HelmField.mutedInk(theme, surface: wellSurface)
        for row in rows {
            let chosen = row.option.id == selectedID
            row.view.normalColor = fill
            row.view.hoverColor = fill.hoverShifted(by: 0.06, forMode: theme.mode)
            row.view.cornerRadius = 10
            row.view.layer?.borderWidth = chosen ? 1.5 : 1
            row.view.layer?.borderColor = (chosen ? accent : HelmField.border(theme, surface: wellSurface)).cgColor
            row.view.accessibilityValueOverride = chosen ? "selected" : "not selected"
            row.radio.image = NSImage(systemSymbolName: chosen ? "largecircle.fill.circle" : "circle",
                                      accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: HelmType.scaled(13), weight: .regular))
            row.radio.contentTintColor = chosen ? accent : muted
            row.title.textColor = ink
            row.detail.textColor = muted
            if let chip = row.chip, let label = row.chipLabel {
                let resolved = HelmContrast.tintedSurface(tintHex: HelmTint.good.hex(in: theme), theme: theme,
                                                          target: HelmContrast.textTarget)
                chip.layer?.backgroundColor = resolved.fill.cgColor
                label.textColor = resolved.foreground
            }
        }
    }

    #if FM_SELFTESTS
    var debugRowTitles: [String] { rows.map(\.title.stringValue) }
    var debugTouchIDRows: [String] { rows.filter { $0.chip != nil }.map(\.title.stringValue) }
    func debugClickRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        _ = rows[index].view.performPrimaryAction()
    }
    var debugNewKeyButton: HelmButton { newKeyButton }
    var debugImportButton: HelmButton { importButton }
    #endif
}
