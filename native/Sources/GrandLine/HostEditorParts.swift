// Grand Line - native macOS app.
//
// The pieces Host-1 of the Console / Add Host / Add Key board added to the
// host form (`HostEditorController`), and Key-1 reuses for the key form:
//
//   - `RecordPreviewHeader`: the hero at the top of the side panel. It draws
//     the record as its card will look on the Connections page - tile, name,
//     address, environment, key and tags - and the form updates it on every
//     change, so a host is visibly being built rather than described.
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
    }

    private let hero = HelmHeroSurface()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let card = NSView()
    let tile: IconTileView
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let extras = NSStackView()
    private let factsRow = NSStackView()
    private var factLabels: [NSTextField] = []
    private(set) var content = Content(kicker: "", title: "", titlePlaceholder: "", subtitle: "")
    private var observation: ThemeObservation?

    static let cornerRadius: CGFloat = 14

    /// `extraViews` sit under the subtitle inside the card - a live status
    /// pill, a connection-test pill - and keep their own theming.
    init(tileSize: CGFloat = 40, extraViews: [NSView] = []) {
        tile = IconTileView(size: tileSize, cornerRadius: 10)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        addSubview(hero)

        kickerLabel.translatesAutoresizingMaskIntoConstraints = false
        kickerLabel.lineBreakMode = .byTruncatingTail
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
        subtitleLabel.font = HelmType.code()
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        extras.orientation = .vertical
        extras.alignment = .leading
        extras.spacing = HelmMetrics.s0
        extraViews.forEach { extras.addArrangedSubview($0) }
        let text = NSStackView(views: [titleRow, subtitleLabel, extras])
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

        let column = NSStackView(views: [kickerLabel, card, factsRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let pad = HelmMetrics.s3
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            hero.topAnchor.constraint(equalTo: topAnchor),
            hero.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            column.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            card.widthAnchor.constraint(equalTo: column.widthAnchor),
            tile.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            tile.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10),
            tile.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10),
            factsRow.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
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

    func applyTheme(_ theme: HelmTheme) {
        let palette = HelmHeroSurface.palette(for: theme)
        hero.apply(palette)
        let heroInk = HelmContrast.color(palette.ink)
        kickerLabel.attributedStringValue = NSAttributedString(
            string: content.kicker.uppercased(),
            attributes: HelmType.kickerAttributes(color: heroInk.withAlphaComponent(0.85)))
        card.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
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
        renderFacts(ink: heroInk)
        setAccessibilityLabel(([content.title.isEmpty ? content.titlePlaceholder : content.title, content.subtitle]
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

    #if FM_SELFTESTS
    var debugTitleText: String { titleLabel.stringValue }
    var debugSubtitleText: String { subtitleLabel.stringValue }
    var debugBadgeText: String? { badgeBox.isHidden ? nil : badgeLabel.stringValue }
    var debugFacts: [String] { factLabels.map(\.stringValue) }
    var debugGradientColors: [CGColor] { hero.debugGradientColors }
    var debugCardFill: NSColor? { card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
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
