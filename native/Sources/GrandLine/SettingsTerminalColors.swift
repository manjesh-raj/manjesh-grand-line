// Grand Line - native macOS app.
//
// Settings > Terminal > Terminal colours, which owns its own rows and state
// the way `TerminalHighlightSettingsSections` does for keyword highlighting.
//
// `fm/grandline-theme-split-app-terminal`, from the captain's approved
// prototype: two choices ("Match app theme", "Choose a scheme"), a live
// preview of a terminal session in the effective scheme, and - while a scheme
// is chosen - an optional light and dark pair ("Change with appearance") and
// the 26 schemes as a grid with an All / Dark / Light filter. The model is
// `TerminalColorsSettings`, stored and resolved by `ThemeManager`.

import AppKit

final class TerminalColorsSettingsSections: NSObject {

    private enum Filter: String {
        case all, dark, light
    }

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var colors: TerminalColorsSettings { ThemeManager.shared.terminalColors }

    let matchCard = SettingsChoiceCard(title: "Match app theme", detail: "")
    let customCard = SettingsChoiceCard(title: "Choose a scheme",
                                        detail: "Any of the 26 schemes, independent of the app.")
    let preview = TerminalSessionPreview()
    let changeSwitch = HelmToggle()
    let lightCard = HelmFieldCard(label: "Light")
    let darkCard = HelmFieldCard(label: "Dark")
    private var changeRow: SettingsRow?
    private(set) var pairRow: SettingsRow?
    private var filterTabs: HelmSegmentedTabs?
    private var filter: Filter = .all
    private let grid = LayoutReportingStack()
    private(set) var schemeCards: [SettingsThemeCard] = []
    /// The two sections that only mean something while a scheme is chosen.
    private var customSections: [SettingsSection] = []
    private var lastGridWidth: CGFloat = 0

    /// The width one scheme card will not go below - the same measured floor
    /// as the Appearance grid's (`SettingsController.themeCardMinWidth`).
    private static let cardMinWidth: CGFloat = 152
    /// Wide enough for "Catppuccin Latte" in a field card.
    private static let pairCardWidth: CGFloat = 196

    // MARK: Building

    func sections() -> [SettingsSection] {
        matchCard.onSelect = { [weak self] in self?.update { $0.mode = .matchApp } }
        customCard.onSelect = { [weak self] in self?.chooseCustom() }
        let choices = NSStackView(views: [matchCard, customCard])
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        // Top-aligned and one height: the two descriptions wrap to different
        // line counts, and a centred shorter card reads as misaligned (seen
        // in the tour render).
        choices.alignment = .top
        choices.spacing = HelmMetrics.s3
        choices.translatesAutoresizingMaskIntoConstraints = false
        matchCard.heightAnchor.constraint(equalTo: customCard.heightAnchor).isActive = true

        let body = NSStackView(views: [choices, preview])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s3
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [choices, preview] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        changeSwitch.setAccessibilityLabel("Change with appearance")
        changeSwitch.onToggle = { [weak self] in self?.changeWithAppearanceToggled() }
        let change = SettingsRow(title: "Change with appearance",
                                 description: "Use a different scheme while the app is light.",
                                 control: changeSwitch)
        changeRow = change

        lightCard.setAccessibilityLabel("Light terminal scheme")
        darkCard.setAccessibilityLabel("Dark terminal scheme")
        for card in [lightCard, darkCard] {
            // gotcha (13): a preference, never required - the same reason
            // Appearance's old pair cards were.
            let width = card.widthAnchor.constraint(equalToConstant: Self.pairCardWidth)
            width.priority = HelmDaylightPriority.contentTie
            width.isActive = true
        }
        let pairControls = NSStackView(views: [lightCard, darkCard])
        pairControls.orientation = .horizontal
        pairControls.spacing = HelmMetrics.s2
        let pair = SettingsRow(title: "Light and dark schemes",
                               description: "Used only while Change with appearance is on.",
                               control: pairControls, isSubRow: true)
        pairRow = pair

        let tabs = HelmSegmentedTabs(items: [
            .init(id: Filter.all.rawValue, title: "All"),
            .init(id: Filter.dark.rawValue, title: "Dark"),
            .init(id: Filter.light.rawValue, title: "Light"),
        ], selected: filter.rawValue, size: .compact)
        tabs.setAccessibilityLabel("Terminal scheme filter")
        tabs.onSelect = { [weak self] id in
            guard let self, let next = Filter(rawValue: id), next != self.filter else { return }
            self.filter = next
            self.rebuildGrid()
        }
        filterTabs = tabs

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = HelmMetrics.s3
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.onLayout = { [weak self] in self?.gridWidthMayHaveChanged() }

        customSections = [
            SettingsSection(group: SettingsGroup(rows: [change, pair])),
            SettingsSection(heading: "Schemes", aside: tabs, group: SettingsGroup(custom: grid)),
        ]
        return [SettingsSection(heading: "Terminal colours", group: SettingsGroup(custom: body))]
            + customSections
    }

    // MARK: State

    /// Re-read the stored choice and show it.
    func refresh() {
        let colors = self.colors
        let scheme = ThemeManager.shared.terminalScheme
        let companion = theme.companionScheme
        matchCard.detail = "\(theme.name) uses \(companion.name). Changes when the app theme does."
        matchCard.isSelected = colors.mode == .matchApp
        customCard.isSelected = colors.mode == .custom
        for section in customSections { section.isHidden = colors.mode != .custom }
        changeSwitch.isOn = colors.changesWithAppearance
        pairRow?.isRowEnabled = colors.changesWithAppearance
        refreshPairCards()
        preview.render(scheme: scheme, appTheme: theme)
        rebuildGrid()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        changeSwitch.applyTheme(theme)
        lightCard.applyTheme(theme)
        darkCard.applyTheme(theme)
        filterTabs?.applyTheme(theme)
        matchCard.applyTheme(theme)
        customCard.applyTheme(theme)
        refresh()
    }

    private func update(_ change: (inout TerminalColorsSettings) -> Void) {
        var next = colors
        change(&next)
        guard next != colors else { return }
        ThemeManager.shared.setTerminalColors(next)
        refresh()
    }

    /// "Choose a scheme" starts on the scheme the terminal already shows, so
    /// picking the option alone changes nothing on screen.
    private func chooseCustom() {
        let showing = ThemeManager.shared.terminalScheme.id
        update { colors in
            colors.mode = .custom
            if colors.schemeID == nil { colors.schemeID = showing }
        }
    }

    /// Turning the pair on seeds both slots from what is showing, again so
    /// the switch alone changes nothing on screen.
    private func changeWithAppearanceToggled() {
        let on = changeSwitch.isOn
        let app = theme
        update { colors in
            colors.changesWithAppearance = on
            guard on else { return }
            let current = colors.scheme(for: app)
            let pair = colors.pair(for: app)
            if colors.lightSchemeID == nil {
                colors.lightSchemeID = current.mode == .light ? current.id : pair.light.id
            }
            if colors.darkSchemeID == nil {
                colors.darkSchemeID = current.mode == .dark ? current.id : pair.dark.id
            }
        }
    }

    private func pick(_ scheme: HelmTheme) {
        update { colors in
            if colors.changesWithAppearance {
                if scheme.mode == .light { colors.lightSchemeID = scheme.id } else { colors.darkSchemeID = scheme.id }
            } else {
                colors.schemeID = scheme.id
            }
        }
    }

    private func refreshPairCards() {
        let pair = colors.pair(for: theme)
        for (card, mode, current) in [(lightCard, HelmTheme.Mode.light, pair.light),
                                      (darkCard, HelmTheme.Mode.dark, pair.dark)] {
            let schemes = HelmTheme.allThemes.filter { $0.mode == mode }
            let index = schemes.firstIndex { $0.id == current.id } ?? 0
            card.configureChoices(schemes.map(\.name), selectedIndex: index) { [weak self] picked in
                guard schemes.indices.contains(picked) else { return }
                self?.update { colors in
                    if mode == .light {
                        colors.lightSchemeID = schemes[picked].id
                    } else {
                        colors.darkSchemeID = schemes[picked].id
                    }
                }
            }
        }
    }

    // MARK: The grid

    private func gridWidthMayHaveChanged() {
        let width = grid.frame.width
        guard width > 0, abs(width - lastGridWidth) > 0.5 else { return }
        rebuildGrid()
    }

    private func rebuildGrid() {
        schemeCards.removeAll()
        for view in grid.arrangedSubviews {
            grid.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        lastGridWidth = grid.frame.width
        guard colors.mode == .custom else { return }
        let activeID = ThemeManager.shared.terminalScheme.id
        let schemes = HelmTheme.allThemes.filter { scheme in
            switch filter {
            case .all: return true
            case .dark: return scheme.mode == .dark
            case .light: return scheme.mode == .light
            }
        }
        let rows = HelmResponsiveGrid.rows(schemes, containerWidth: grid.frame.width,
                                           minItemWidth: Self.cardMinWidth,
                                           spacing: HelmMetrics.s3) { scheme, _ in
            let card = SettingsThemeCard(theme: scheme, isActive: scheme.id == activeID, kind: .terminal,
                                         detail: scheme.terminalCard != nil
                                            ? "dark card" : (scheme.mode == .dark ? "dark" : "light"))
            card.onSelect = { [weak self] in self?.pick(scheme) }
            card.applyTheme(self.theme)
            self.schemeCards.append(card)
            return card
        }
        for row in rows {
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
    }

    #if FM_SELFTESTS
    var debugCustomSections: [SettingsSection] { customSections }
    func debugSetFilter(_ id: String) {
        guard let next = Filter(rawValue: id) else { return }
        filter = next
        rebuildGrid()
    }
    #endif
}

// MARK: - One of two choices

/// A selectable card with a title and a line under it - the prototype's
/// `.opt`. Same chrome and the same press path as `SettingsThemeCard`: a
/// `HoverHighlightView` carries the hover, the pressed state, the focus ring
/// and the announced radio-button role (GL-16).
final class SettingsChoiceCard: NSView {
    let hoverView = HoverHighlightView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    var onSelect: (() -> Void)?
    private var current: HelmTheme = ThemeManager.shared.theme

    var isSelected = false {
        didSet {
            hoverView.setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            applyTheme(current)
        }
    }

    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue }
    }

    init(title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = HelmType.rowTitle()
        detailLabel.stringValue = detail
        detailLabel.font = HelmType.caption()
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hoverView.cornerRadius = HelmMetrics.rRow
        hoverView.translatesAutoresizingMaskIntoConstraints = false
        hoverView.accessibilityRoleOverride = .radioButton
        hoverView.accessibilityLabelOverride = title
        hoverView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        hoverView.onAccessibilityPress = { [weak self] in self?.onSelect?() }

        let column = NSStackView(views: [titleLabel, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s0
        column.translatesAutoresizingMaskIntoConstraints = false
        hoverView.addSubview(column)
        addSubview(hoverView)
        NSLayoutConstraint.activate([
            hoverView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverView.topAnchor.constraint(equalTo: topAnchor),
            hoverView.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor, constant: HelmMetrics.s3),
            column.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor, constant: -HelmMetrics.s3),
            column.topAnchor.constraint(equalTo: hoverView.topAnchor, constant: HelmMetrics.s2 + 2),
            column.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor, constant: -(HelmMetrics.s2 + 2)),
            detailLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onSelect?() }

    /// The prototype's `.opt.on`: a 2pt accent ring over an 8% accent wash.
    func applyTheme(_ theme: HelmTheme) {
        current = theme
        let accent = HelmTheme.nsColor(theme.accentHex)
        hoverView.layer?.masksToBounds = true
        hoverView.layer?.borderWidth = isSelected ? 2 : 1
        hoverView.layer?.borderColor = (isSelected
            ? accent
            : HelmTheme.nsColor(theme.isDaylight ? theme.daylightTokens.hair : theme.chromeLineHex)).cgColor
        hoverView.normalColor = isSelected ? accent.withAlphaComponent(0.08) : .clear
        hoverView.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.22)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
    }
}

// MARK: - The sample session

/// The text a scheme preview shows, coloured exactly as a terminal in that
/// scheme would colour it: its own ink, ANSI slots, selection and cursor.
enum TerminalSessionSample {

    /// The prototype's live preview, eight lines.
    static func session(_ scheme: HelmTheme) -> NSAttributedString {
        let cells = scheme.terminalCells
        let font = HelmType.code()
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let out = NSMutableAttributedString()
        func add(_ text: String, _ slot: Int? = nil, bold isBold: Bool = false) {
            let color = slot.map { HelmTheme.nsColor(cells.ansiHex[$0]) } ?? HelmTheme.nsColor(cells.inkHex)
            out.append(NSAttributedString(string: text, attributes: [
                .font: isBold ? bold : font, .foregroundColor: color]))
        }
        func prompt(_ command: String) {
            add("manjesh@grandline", 2, bold: true)
            add(" ")
            add("~/grand-line", 4, bold: true)
            add(" ")
            add("(main)", 5)
            add(" ")
            add("$", 8)
            add(" \(command)")
        }
        prompt("kubectl get pods -n payments")
        add("\napi-7d9f8c6b5-x2kq9    1/1   ")
        add("Running", 2)
        add("            0    3d\nworker-5c7b9d-8hj2l    0/1   ")
        add("CrashLoopBackOff", 1, bold: true)
        add("   14   2h\n")
        add("warning:", 3, bold: true)
        add(" 'selectText' is ")
        add("deprecated", 3)
        add("\n")
        add("error:", 1, bold: true)
        add(" cannot convert value of type 'Substring' to 'String'\n")
        add("Build complete!", 2)
        add(" ")
        add("(25.27s)", 8)
        add("\n")
        out.append(NSAttributedString(string: "selected text uses the scheme's own selection colour", attributes: [
            .font: font,
            .foregroundColor: HelmTheme.nsColor(scheme.selectionTextHex),
            .backgroundColor: HelmTheme.nsColor(scheme.selectionHex),
        ]))
        add("\n")
        prompt("")
        out.append(NSAttributedString(string: " ", attributes: [
            .font: font, .backgroundColor: HelmTheme.nsColor(cells.cursorHex)]))
        return out
    }

    /// The scheme card's three lines.
    static func miniature(_ cells: HelmTerminalCard) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: HelmType.scaled(9), weight: .regular)
        let out = NSMutableAttributedString()
        func add(_ text: String, _ slot: Int? = nil) {
            let color = slot.map { HelmTheme.nsColor(cells.ansiHex[$0]) } ?? HelmTheme.nsColor(cells.inkHex)
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        add("\u{276F}", 2); add(" "); add("~/grand-line", 4); add(" "); add("main", 5)
        add("\n"); add("error:", 1); add(" build failed")
        add("\n"); add("warn:", 3); add(" deprecated ")
        out.append(NSAttributedString(string: " ", attributes: [
            .font: font, .backgroundColor: HelmTheme.nsColor(cells.cursorHex)]))
        return out
    }
}

/// The live preview on Settings > Terminal: a terminal session drawn in the
/// effective scheme's own cells, on its own background, inside the app
/// theme's hairline.
final class TerminalSessionPreview: NSView {
    let text = NSTextField(labelWithString: "")
    private(set) var schemeID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rRow
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byClipping
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s3),
            text.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func render(scheme: HelmTheme, appTheme: HelmTheme) {
        schemeID = scheme.id
        layer?.backgroundColor = HelmTheme.nsColor(scheme.terminalCells.backgroundHex).cgColor
        layer?.borderColor = HelmTheme.nsColor(appTheme.isDaylight
            ? appTheme.daylightTokens.hair : appTheme.chromeLineHex).cgColor
        text.attributedStringValue = TerminalSessionSample.session(scheme)
        setAccessibilityLabel("Terminal preview in \(scheme.name)")
    }
}
