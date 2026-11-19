// Grand Line - native macOS app.
//
// Secrets › Automic Vault's split card: S-1 on the page-redesign board, which
// the captain kept for this tab when Secrets took S-3's hero column. Sidebar
// layout only; the floating bar's page is unchanged.
//
// One card, two halves. On the left, a `HelmHeroColumn` in its band layout:
// the launchers' verdict, a ring of how many are hardened, and View Fix when
// one launcher is the problem - the accent while all is well and amber while
// a launcher needs attention, the board's one second tone. On the right, on
// the card's own surface, the verified launchers as rows with their state and
// their own View Fix. Below a 900pt card the gradient sits across the top and
// the rows under it. The card's frame - the two halves, the stacking and the
// surface - is the kit's `HelmHeroSplitCard` (7.1.0), which Dictation's Dic-1
// fills too; this file fills it with the launchers.
//
// It replaces the page's attention banner and its Verified Launchers table in
// this layout: both said what the card says now. Every action is the page's
// own (`presentIssueSheet`), and B1's three states stay three - still reading,
// could not read, and read - so a read that did not happen never draws an
// all-clear (GL-14).

import AppKit

// MARK: - The words

/// What the split card says, from the page's read. Pure, so the suite can
/// assert every state headless.
struct VaultHeroWords: Equatable {
    enum Tone: Equatable { case accent, amber, dimmed }

    let kicker: String
    let headline: String
    let body: String?
    /// Hardened launchers over all of them, or `nil` before a read.
    let ring: (hardened: Int, total: Int)?
    let tone: Tone
    /// The one launcher View Fix opens from the gradient, when it is one.
    let fixTool: String?

    static func == (a: VaultHeroWords, b: VaultHeroWords) -> Bool {
        a.kicker == b.kicker && a.headline == b.headline && a.body == b.body && a.tone == b.tone
            && a.fixTool == b.fixTool && a.ring?.hardened == b.ring?.hardened && a.ring?.total == b.ring?.total
    }

    static func make(secrets: [VaultSecret]?, tools: [VaultTool]?, hasLoadedOnce: Bool,
                     notInstalled: Bool, refusedHere: Bool) -> VaultHeroWords {
        if notInstalled {
            return VaultHeroWords(kicker: "Automic Vault \u{00B7} Not installed",
                                  headline: "Automic Vault isn\u{2019}t installed.",
                                  body: "Install it from \(PlaceName.of(.bootstrap)) to keep secrets out of files.",
                                  ring: nil, tone: .dimmed, fixTool: nil)
        }
        guard let tools else {
            if !hasLoadedOnce {
                return VaultHeroWords(kicker: "Automic Vault \u{00B7} Checking", headline: "Checking Automic Vault\u{2026}",
                                      body: "The launchers appear here once av answers.", ring: nil, tone: .dimmed,
                                      fixTool: nil)
            }
            return VaultHeroWords(kicker: "Automic Vault \u{00B7} Not read", headline: "Couldn\u{2019}t read Automic Vault.",
                                  body: refusedHere ? "\(VaultSource.isolationNote)."
                                      : "Its approval helper may not be running. Check the menu bar app, then Refresh.",
                                  ring: nil, tone: .dimmed, fixTool: nil)
        }
        let needing = tools.filter { if case .needsAttention = $0.status { return true } else { return false } }
        let hardened = tools.count - needing.count
        let ring = tools.isEmpty ? nil : (hardened, tools.count)
        let secretsLine: String? = secrets.map { secrets in
            switch secrets.count {
            case 0: return "No secrets saved yet."
            case 1: return "1 secret is in Automic Vault\u{2019}s Keychain."
            default: return "All \(secrets.count) secrets are in Automic Vault\u{2019}s Keychain."
            }
        }
        if let notice = VaultSource.attentionNotice(for: tools) {
            let headline = needing.count == 1 ? "\(notice.title)." : "\(needing.count) launchers need attention."
            let body = [notice.body, secretsLine].compactMap { $0 }.joined(separator: " ")
            return VaultHeroWords(kicker: "Automic Vault \u{00B7} \(needing.count) to fix",
                                  headline: headline, body: body, ring: ring, tone: .amber,
                                  fixTool: notice.tool?.name)
        }
        if tools.isEmpty {
            return VaultHeroWords(kicker: "Automic Vault \u{00B7} No launchers",
                                  headline: "No verified launchers yet.", body: secretsLine, ring: nil,
                                  tone: .accent, fixTool: nil)
        }
        return VaultHeroWords(kicker: "Automic Vault \u{00B7} All clear",
                              headline: tools.count == 1 ? "The launcher is hardened." : "Every launcher is hardened.",
                              body: [secretsLine, "Names and metadata only, never a value."].compactMap { $0 }
                                  .joined(separator: " "),
                              ring: ring, tone: .accent, fixTool: nil)
    }

    /// The tone as the hero's colour in `theme`: the accent, the theme's own
    /// amber, or the accent dimmed for a reading that did not happen.
    func heroTone(in theme: HelmTheme) -> HelmModuleCard.HeroTone {
        switch tone {
        case .accent: return HelmModuleCard.HeroTone(colour: .themeAccent)
        case .dimmed: return HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: true)
        case .amber:
            let rgb = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3]))
            return HelmModuleCard.HeroTone(colour: .fixed(red: rgb.0, green: rgb.1, blue: rgb.2))
        }
    }
}

// MARK: - The card

final class VaultHeroSplitView: NSView {

    /// Below this card width the panel goes across the top.
    static let stackedBelow: CGFloat = HelmHeroSplitCard.defaultStackedBelow

    /// The frame: a band panel, so the card reads as it did before the kit
    /// took it over.
    private let card = HelmHeroSplitCard(arrangement: .band)
    var panel: HelmHeroColumn { card.panel }
    var isStacked: Bool { card.isStacked }
    private var native: NSView { card.detail }
    private let headerLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "from av doctor --json")
    private let rowsStack = NSStackView()
    private var rowViews: [VaultLauncherRowView] = []
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?
    /// View Fix on the gradient: the one launcher's issue sheet.
    private var panelFix: (() -> Void)?

    @objc private func panelFixTapped() { panelFix?() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityLabel("Automic Vault summary")
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        headerLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.font = HelmType.captionSmall()
        sourceLabel.setContentHuggingPriority(.required, for: .horizontal)
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headerLabel, spacer, sourceLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = HelmMetrics.s2
        header.setClippingResistancePriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = HelmType.body()
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        native.addSubview(header)
        native.addSubview(rowsStack)
        native.addSubview(emptyLabel)
        let inset = HelmMetrics.s4
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: native.topAnchor, constant: inset),
            header.leadingAnchor.constraint(equalTo: native.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: native.trailingAnchor, constant: -inset),
            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),
            rowsStack.leadingAnchor.constraint(equalTo: native.leadingAnchor, constant: inset - HelmMetrics.s2),
            rowsStack.trailingAnchor.constraint(equalTo: native.trailingAnchor, constant: -(inset - HelmMetrics.s2)),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: native.bottomAnchor, constant: -inset),
            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s3),
            emptyLabel.leadingAnchor.constraint(equalTo: native.leadingAnchor, constant: inset),
            emptyLabel.trailingAnchor.constraint(equalTo: native.trailingAnchor, constant: -inset),
            emptyLabel.bottomAnchor.constraint(lessThanOrEqualTo: native.bottomAnchor, constant: -inset),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// The card for one read. `fix` opens a launcher's issue sheet - the
    /// page's own.
    func configure(_ words: VaultHeroWords, tools: [VaultTool]?, fix: @escaping (VaultTool) -> Void,
                   theme: HelmTheme) {
        self.theme = theme
        var foot: [NSView] = []
        if let name = words.fixTool, let tool = tools?.first(where: { $0.name == name }) {
            let button = HelmButton(title: "View Fix\u{2026}", variant: .secondary, size: .small,
                                    symbol: "wrench.and.screwdriver", target: self, action: #selector(panelFixTapped))
            panelFix = { fix(tool) }
            foot.append(button)
        } else {
            panelFix = nil
        }
        let ring = words.ring.map { ring in
            HelmHeroColumn.Ring(fraction: Double(ring.hardened) / Double(max(1, ring.total)),
                                label: "\(ring.hardened)/\(ring.total)", caption: "launchers hardened",
                                spoken: "\(ring.hardened) of \(ring.total) launchers hardened",
                                state: words.tone == .amber ? .warn : .ok)
        }
        panel.configure(header: .init(symbol: "shield.lefthalf.filled", kicker: words.kicker, headline: words.headline,
                                      body: words.body, ring: ring),
                        sections: [], foot: foot, tone: words.heroTone(in: theme))

        for row in rowViews { rowsStack.removeArrangedSubview(row); row.removeFromSuperview() }
        rowViews = (tools ?? []).map { tool in
            let row = VaultLauncherRowView(tool: tool)
            row.onFix = { fix(tool) }
            return row
        }
        for (index, row) in rowViews.enumerated() {
            row.showsTopRule = index > 0
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        headerLabel.stringValue = "VERIFIED LAUNCHERS" + (tools.map { " \u{00B7} \($0.count)" } ?? "")
        emptyLabel.isHidden = !(tools?.isEmpty ?? true)
        emptyLabel.stringValue = tools == nil
            ? "The launchers appear here once Automic Vault answers."
            : "No verified launchers registered with Automic Vault yet."
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Automic Vault. \(words.headline)")
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        headerLabel.attributedStringValue = NSAttributedString(
            string: headerLabel.stringValue, attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        sourceLabel.textColor = HelmTheme.mutedInk(theme)
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
        for row in rowViews { row.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugRows: [VaultLauncherRowView] { rowViews }
    var debugFootButtons: [HelmButton] { panel.debugFootButtons }
    #endif
}

// MARK: - A launcher row

/// One verified launcher on the card's own surface: a state tile, the name
/// and the doctor's own detail, the state as a dot and a word, and View Fix
/// for a launcher that needs attention.
final class VaultLauncherRowView: NSView {

    static let height: CGFloat = 52
    /// The state dot, a circle.
    static let dotSide: CGFloat = 7

    let tool: VaultTool
    var onFix: (() -> Void)?
    var showsTopRule = false { didSet { rule.isHidden = !showsTopRule } }

    private let rule = NSView()
    private let tile = IconTileView(size: 28, cornerRadius: 8)
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private(set) var fixButton: HelmButton?

    var isHardened: Bool {
        if case .hardened = tool.status { return true }
        return false
    }

    init(tool: VaultTool) {
        self.tool = tool
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.isHidden = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        nameLabel.stringValue = tool.name
        nameLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        detailLabel.stringValue = isHardened ? "Hardened, 0 issues" : (tool.issueSummary ?? tool.status.label + " found")
        detailLabel.toolTip = detailLabel.stringValue
        detailLabel.font = HelmType.caption()
        for label in [nameLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let words = NSStackView(views: [nameLabel, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = HelmMetrics.s0
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)
        words.setHuggingPriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.stringValue = isHardened ? "Hardened" : tool.status.label
        stateLabel.font = HelmType.chip()
        let state = NSStackView(views: [dot, stateLabel])
        state.orientation = .horizontal
        state.spacing = HelmMetrics.s1 + 2
        state.alignment = .centerY
        var views: [NSView] = [tile, words, state]
        if !isHardened {
            let button = HelmButton(title: "View Fix\u{2026}", variant: .secondary, size: .small,
                                    symbol: "wrench.and.screwdriver", target: nil, action: #selector(fixTapped))
            fixButton = button
            views.append(button)
        }
        for view in views where view !== words {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: HelmType.scaled(Self.height)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(tool.name), \(stateLabel.stringValue). \(detailLabel.stringValue)")
        fixButton?.target = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func fixTapped() { onFix?() }

    override func accessibilityChildren() -> [Any]? { fixButton.map { [$0] } }

    func applyTheme(_ theme: HelmTheme) {
        let tint: HelmTint = isHardened ? .good : .warn
        tile.configure(symbol: "checkmark.shield.fill", tint: tint, pointSize: 13)
        tile.applyTheme(theme)
        nameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        dot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        stateLabel.textColor = HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme), over: surface, theme: theme)
        rule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 1 : 0.5).cgColor
    }

    #if FM_SELFTESTS
    var debugState: String { stateLabel.stringValue }
    #endif
}
