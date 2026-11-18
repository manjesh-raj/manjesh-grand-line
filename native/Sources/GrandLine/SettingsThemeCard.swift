// Grand Line - native macOS app.
//
// One cell of a theme grid: a miniature drawn in a theme's own tokens, its
// name, an optional second line, and a checkmark when it is the active one.
//
// `fm/grandline-settings-page-redesign` drew a small window instead of three
// swatches, because what a picker has to show is what the app *looks like*
// in a palette, not which colours it contains. The theme split
// (`fm/grandline-theme-split-app-terminal`) gave the card two kinds of
// preview, one per catalogue, both from the approved prototype:
//
//   `.app`       Settings > Appearance's family cards. The page ground, the
//                nav column in the theme's `side` value with an accent row
//                and three muted rows, an ink line and a muted line, and a
//                card on its hairline carrying the ok, warn and accent chips.
//   `.terminal`  Settings > Terminal's scheme cards. The scheme's own cells:
//                a prompt, an error and a warning line in its ANSI colours,
//                the cursor, and six swatches.
//
// Every value is read from the `HelmTheme` being previewed, so the miniature
// is the palette rather than a picture of one. It is a view rather than an
// image because the grid re-flows on a resize (`HelmResponsiveGrid`).

import AppKit

final class SettingsThemeCard: NSView {

    enum PreviewKind {
        /// An app theme: a miniature of the window.
        case app
        /// A terminal scheme: a miniature of a terminal session.
        case terminal
    }

    /// The preview's height. Enough for a sidebar column, two content lines
    /// and a card to read as three distinct things at this width - below
    /// about 56 the card and the second line merge.
    static let previewHeight: CGFloat = 68
    let theme: HelmTheme
    let kind: PreviewKind
    private(set) var isActive: Bool

    let nameLabel = NSTextField(labelWithString: "")
    /// The second line ("Dark: Dusk", "dark card"), when there is one.
    let detailLabel = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let preview = NSView()
    private let title: String
    private let detail: String?

    /// Fired on a real click, a keyboard press or a VoiceOver activation.
    /// The card's chrome is a `HoverHighlightView`, so the hover fill, the
    /// pressed state, the focus ring and the announced role all come from
    /// that one component (GL-16) rather than from a plain view wearing a
    /// gesture recognizer.
    var onSelect: (() -> Void)?

    /// S26: a family tile draws both registers side by side, light on the
    /// left and dark on the right, each in its own tokens, with the check on
    /// the half that is showing. `nil` for a single-theme card (Terminal's
    /// schemes).
    private(set) var pair: (light: HelmTheme, dark: HelmTheme)?
    /// Which register is showing, for the check on the active half.
    private var activeMode: HelmTheme.Mode = ThemeManager.shared.theme.mode
    private let halfCheck = NSImageView()
    private var halfCheckLeading: NSLayoutConstraint?

    let hoverView = HoverHighlightView()

    init(theme: HelmTheme, isActive: Bool, kind: PreviewKind = .app,
         title: String? = nil, detail: String? = nil, pair: (light: HelmTheme, dark: HelmTheme)? = nil) {
        self.theme = theme
        self.isActive = isActive
        self.kind = kind
        self.title = title ?? theme.name
        self.detail = detail
        self.pair = pair
        self.activeMode = theme.mode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// S25: one app-theme family as a tile, the one construction Settings ›
    /// Appearance and the welcome sheet's look step both use, so the tile is
    /// hostable outside Settings rather than a Settings-only private shape.
    ///
    /// S26: the tile shows the pair it stands for - both registers drawn side
    /// by side, the caption naming them once ("Daylight · Dusk"), the check
    /// on the half that is showing. The "Light:" prefix, which repeated the
    /// mode the segmented control above already states, is gone.
    static func family(_ family: AppThemeFamily, mode: HelmTheme.Mode, isActive: Bool) -> SettingsThemeCard {
        let light = family.register(.light), dark = family.register(.dark)
        let caption = pairCaption(light: light.name, dark: dark.name)
        let card = SettingsThemeCard(theme: family.register(mode), isActive: isActive, kind: .app, title: caption,
                                     detail: nil, pair: (light, dark))
        card.hoverView.accessibilityLabelOverride = "\(family.title): light \(light.name), dark \(dark.name)"
        return card
    }

    /// "Daylight · Dusk"; a dark register that only adds "Dark" to the light
    /// one's name says so without repeating it ("High Contrast · Dark"), so
    /// the caption fits a tile.
    static func pairCaption(light: String, dark: String) -> String {
        if light == dark { return light }
        if dark.hasPrefix(light + " ") { return "\(light) \u{00B7} \(dark.dropFirst(light.count + 1))" }
        return "\(light) \u{00B7} \(dark)"
    }

    /// The register that is showing changed (a light/dark switch): the check
    /// moves to the other half.
    func setActiveMode(_ mode: HelmTheme.Mode) {
        activeMode = mode
        placeHalfCheck()
    }

    /// Marks this tile as the active one, or not, without rebuilding it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        check.isHidden = !active || pair != nil
        placeHalfCheck()
        nameLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: active ? .semibold : .regular)
        applyTheme(ThemeManager.shared.theme)
    }

    private func build() {
        preview.wantsLayer = true
        preview.layer?.cornerRadius = HelmMetrics.rControl
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .app:
            if let pair {
                // S26: two halves, each a whole preview in its register.
                let halves = [pair.light, pair.dark].map { register -> NSView in
                    let half = NSView()
                    half.wantsLayer = true
                    half.translatesAutoresizingMaskIntoConstraints = false
                    preview.addSubview(half)
                    buildAppPreview(in: half, theme: register, compact: true)
                    return half
                }
                NSLayoutConstraint.activate([
                    halves[0].leadingAnchor.constraint(equalTo: preview.leadingAnchor),
                    halves[0].topAnchor.constraint(equalTo: preview.topAnchor),
                    halves[0].bottomAnchor.constraint(equalTo: preview.bottomAnchor),
                    halves[1].leadingAnchor.constraint(equalTo: halves[0].trailingAnchor),
                    halves[1].trailingAnchor.constraint(equalTo: preview.trailingAnchor),
                    halves[1].topAnchor.constraint(equalTo: preview.topAnchor),
                    halves[1].bottomAnchor.constraint(equalTo: preview.bottomAnchor),
                    halves[1].widthAnchor.constraint(equalTo: halves[0].widthAnchor),
                ])
                halfCheck.image = HelmSymbol.image("checkmark.circle.fill", pointSize: 12, weight: .semibold)
                halfCheck.translatesAutoresizingMaskIntoConstraints = false
                preview.addSubview(halfCheck)
                halfCheck.topAnchor.constraint(equalTo: preview.topAnchor, constant: 4).isActive = true
                placeHalfCheck()
            } else {
                buildAppPreview(in: preview, theme: theme, compact: false)
            }
        case .terminal: buildTerminalPreview()
        }
        preview.heightAnchor.constraint(equalToConstant: Self.previewHeight).isActive = true

        nameLabel.stringValue = title
        nameLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: isActive ? .semibold : .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        // Otherwise the longest name's own compression resistance beats the
        // grid row's `.fillEqually` distribution and that one card comes out
        // wider than its siblings - measured at 130pt against 107 before the
        // card this replaces was fixed the same way.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        check.image = HelmSymbol.image("checkmark.circle.fill", pointSize: 11, weight: .regular)
        check.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        check.isHidden = !isActive || pair != nil
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = NSStackView(views: [nameLabel, check])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = HelmMetrics.s1
        // Gotcha (10): the checkmark belongs at the row's trailing edge, not
        // wherever the name happens to end.
        nameRow.distribution = .fill
        nameRow.translatesAutoresizingMaskIntoConstraints = false

        hoverView.cornerRadius = HelmMetrics.rControl
        hoverView.translatesAutoresizingMaskIntoConstraints = false
        hoverView.accessibilityRoleOverride = .radioButton
        hoverView.accessibilityLabelOverride = detail.map { "\(title), \($0)" } ?? title
        // A real click recognizer plus the accessibility press hook, which is
        // this app's established shape for a clickable `HoverHighlightView` -
        // the recognizer covers the mouse, `onAccessibilityPress` covers
        // VoiceOver and the keyboard, and both land on the same closure.
        hoverView.addGestureRecognizer(NSClickGestureRecognizer(target: self,
                                                                action: #selector(cardClicked)))
        hoverView.onAccessibilityPress = { [weak self] in self?.onSelect?() }

        detailLabel.stringValue = detail ?? ""
        detailLabel.font = HelmType.caption()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.isHidden = detail == nil

        let column = NSStackView(views: [preview, nameRow, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1 + 1
        column.translatesAutoresizingMaskIntoConstraints = false
        hoverView.addSubview(column)
        addSubview(hoverView)

        NSLayoutConstraint.activate([
            hoverView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverView.topAnchor.constraint(equalTo: topAnchor),
            hoverView.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: hoverView.topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor, constant: -4),
            preview.widthAnchor.constraint(equalTo: column.widthAnchor),
            nameRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    // MARK: The two previews

    /// The prototype's `.mini`: ground, a nav column in the theme's `side`,
    /// two text lines, and a card with the ok, warn and accent chips.
    /// On the active half's top-trailing corner, visible only on the active
    /// family's tile.
    private func placeHalfCheck() {
        guard let pair, halfCheck.superview != nil else { return }
        halfCheckLeading?.isActive = false
        let lightShowing = activeMode == .light
        halfCheckLeading = lightShowing
            ? halfCheck.trailingAnchor.constraint(equalTo: preview.centerXAnchor, constant: -4)
            : halfCheck.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -4)
        halfCheckLeading?.isActive = true
        halfCheck.isHidden = !isActive
        halfCheck.contentTintColor = HelmTheme.nsColor((lightShowing ? pair.light : pair.dark).accentHex)
    }

    /// `compact`: half of a pair tile, so the status chips are narrower and
    /// all three fit the half's mini card.
    private func buildAppPreview(in preview: NSView, theme: HelmTheme, compact: Bool) {
        let tokens = theme.isDaylight ? theme.daylightTokens : nil
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let accent = HelmTheme.nsColor(theme.accentHex)
        preview.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = HelmTheme.sidePanelFill(theme).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(sidebar)

        let sidebarRows = NSStackView(views: (0..<4).map { index in
            Self.bar(color: index == 0 ? accent : muted, height: 3)
        })
        sidebarRows.orientation = .vertical
        sidebarRows.alignment = .leading
        sidebarRows.distribution = .fillEqually
        sidebarRows.spacing = HelmMetrics.s1
        sidebarRows.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarRows)

        let line1 = Self.bar(color: ink, height: 3)
        let line2 = Self.bar(color: muted, height: 3)

        let miniCard = NSView()
        miniCard.wantsLayer = true
        miniCard.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        miniCard.layer?.cornerRadius = HelmMetrics.s1
        miniCard.layer?.borderWidth = 1
        miniCard.layer?.borderColor = HelmTheme.nsColor(tokens?.hair ?? theme.chromeLineHex).cgColor
        miniCard.translatesAutoresizingMaskIntoConstraints = false

        let chips = NSStackView(views: [HelmTint.good, HelmTint.warn, HelmTint.accent].map { tint in
            let chip = Self.bar(color: HelmTheme.nsColor(tint.hex(in: theme)), height: 6)
            chip.widthAnchor.constraint(equalToConstant: compact ? 7 : 12).isActive = true
            return chip
        })
        chips.orientation = .horizontal
        chips.spacing = HelmMetrics.s1
        chips.translatesAutoresizingMaskIntoConstraints = false
        miniCard.addSubview(chips)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(line1)
        content.addSubview(line2)
        content.addSubview(miniCard)
        preview.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: preview.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            sidebar.widthAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.3),

            sidebarRows.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 5),
            sidebarRows.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -5),
            sidebarRows.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            content.topAnchor.constraint(equalTo: preview.topAnchor),
            content.bottomAnchor.constraint(equalTo: preview.bottomAnchor),

            line1.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 7),
            line1.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            line1.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.66),

            line2.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 5),
            line2.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.42),

            miniCard.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            miniCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -7),
            miniCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
            miniCard.heightAnchor.constraint(equalToConstant: 18),

            chips.trailingAnchor.constraint(equalTo: miniCard.trailingAnchor, constant: -5),
            chips.centerYAnchor.constraint(equalTo: miniCard.centerYAnchor),
        ])
    }

    /// The prototype's `.tmini`: the scheme's own cells, never the page's.
    private func buildTerminalPreview() {
        let cells = theme.terminalCells
        preview.layer?.backgroundColor = HelmTheme.nsColor(cells.backgroundHex).cgColor

        let sample = NSTextField(labelWithAttributedString: TerminalSessionSample.miniature(cells))
        sample.maximumNumberOfLines = 3
        sample.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(sample)

        let swatches = NSStackView(views: (1...6).map { index in
            Self.swatch(HelmTheme.nsColor(cells.ansiHex[index]))
        })
        swatches.orientation = .horizontal
        swatches.spacing = HelmMetrics.s0
        swatches.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(swatches)

        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 8),
            sample.trailingAnchor.constraint(lessThanOrEqualTo: preview.trailingAnchor, constant: -4),
            sample.topAnchor.constraint(equalTo: preview.topAnchor, constant: 6),
            swatches.leadingAnchor.constraint(equalTo: sample.leadingAnchor),
            swatches.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -7),
        ])
    }

    private static func swatch(_ color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = HelmMetrics.s0
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 12),
            view.heightAnchor.constraint(equalToConstant: 7),
        ])
        return view
    }

    @objc private func cardClicked() { onSelect?() }

    private static func bar(color: NSColor, height: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = height / 2
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// The selected ring, the name's weight and the checkmark, in the colours
    /// of the theme the grid is currently *in* - which is not the theme this
    /// card previews.
    ///
    /// The distinction is the whole reason this takes a parameter: the ring
    /// and the resting fill have to read against the card the grid sits on
    /// (the active palette's surface), while everything inside the preview is
    /// drawn in the previewed palette's own tokens and never moves.
    func applyTheme(_ current: HelmTheme) {
        hoverView.layer?.masksToBounds = true
        hoverView.layer?.borderWidth = isActive ? 2 : 1
        hoverView.layer?.borderColor = (isActive
            ? HelmTheme.nsColor(current.accentHex)
            : HelmTheme.nsColor(current.chromeLineHex).withAlphaComponent(0.6)).cgColor
        hoverView.normalColor = isActive
            ? HelmTheme.nsColor(current.accentHex).withAlphaComponent(0.08)
            : (current.isDaylight ? HelmField.fill(current) : .clear)
        hoverView.hoverColor = current.isDaylight
            ? HelmTheme.nsColor(current.daylightTokens.rowHover)
            : HelmTheme.nsColor(current.chromeLineHex).withAlphaComponent(0.22)
        nameLabel.textColor = HelmTheme.nsColor(current.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(current)
    }
}
