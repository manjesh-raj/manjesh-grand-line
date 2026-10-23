// Grand Line - native macOS app.
//
// Setup's summary cards (stage 7 of the modular-shell migration): the row of
// five figures the prototype draws above each of Setup's four tabs - tools up
// to date, updates, setup steps, dotfiles and GitHub sync.
//
// **Nothing here checks anything.** Each figure is a reading something else
// already takes and publishes:
//
//   - the tools, the steps and the forks are `BackgroundSignalsPoller`'s
//     counts, which the poller's own pass writes and which Updates, Setup
//     steps, Automation and GitHub sync overwrite with fresher statuses
//     while they are on screen - the same numbers the sidebar's Setup badge
//     reads, so the badge and the cards can never disagree;
//   - the dotfiles are `DotfilesAutoSync`'s own status;
//   - "Paused" is the last answer `ConfigRepoPrivacy` reached, which refuses
//     every push to a config repo it has confirmed public (GL-22).
//
// **Unknown is never zero (GL-14).** A figure whose reading has not been taken
// this session is a dash, and the card's tooltip says why.
//
// Two halves: `SetupSummary` is the pure model (asserted headless by
// `SidebarRedesignsModelSelfTest`), and `SetupSummaryRow` is the view each of
// the four pages shows in the sidebar layout. The floating bar's pages draw
// no summary row.

import AppKit

enum SetupSummary {

    /// One card's figure.
    struct Card: Equatable {
        let caption: String
        /// `nil` draws a dash.
        let text: String?
        /// The hue the figure takes when it is the signal.
        let tint: HelmTint?
        let signals: Bool
        /// Why the figure is a dash, for its tooltip.
        let unknownReason: String?
    }

    static let captions = ["Tools up to date", "Updates", "Setup steps", "Dotfiles", "GitHub sync"]

    static func cards(counts: BackgroundSignalsPoller.SignalCounts,
                      dotfiles: DotfilesAutoSync.Status?,
                      configRepo: ConfigRepoPrivacy.Reading?) -> [Card] {
        [toolsCard(counts), updatesCard(counts), stepsCard(counts), dotfilesCard(dotfiles),
         githubCard(counts, configRepo: configRepo)]
    }

    static func toolsCard(_ counts: BackgroundSignalsPoller.SignalCounts) -> Card {
        guard let upToDate = counts.toolsUpToDate, let total = counts.toolsTotal else {
            return Card(caption: captions[0], text: nil, tint: nil, signals: false,
                        unknownReason: "No tool has been checked yet this session.")
        }
        return Card(caption: captions[0], text: "\(upToDate) / \(total)", tint: nil, signals: false,
                    unknownReason: nil)
    }

    static func updatesCard(_ counts: BackgroundSignalsPoller.SignalCounts) -> Card {
        guard let updates = counts.toolsWithUpdate else {
            return Card(caption: captions[1], text: nil, tint: .warn, signals: false,
                        unknownReason: "No tool has been checked yet this session.")
        }
        return Card(caption: captions[1], text: "\(updates)", tint: .warn, signals: updates > 0, unknownReason: nil)
    }

    static func stepsCard(_ counts: BackgroundSignalsPoller.SignalCounts) -> Card {
        guard let done = counts.setupStepsDone, let total = counts.setupStepsTotal else {
            return Card(caption: captions[2], text: nil, tint: nil, signals: false,
                        unknownReason: "The setup steps have not been checked yet this session.")
        }
        return Card(caption: captions[2], text: "\(done) / \(total)", tint: nil, signals: false, unknownReason: nil)
    }

    static func dotfilesCard(_ status: DotfilesAutoSync.Status?) -> Card {
        let caption = captions[3]
        guard let status else {
            return Card(caption: caption, text: nil, tint: nil, signals: false,
                        unknownReason: "The dotfiles sync has not run yet this session.")
        }
        switch status {
        case .synced: return Card(caption: caption, text: "Synced", tint: nil, signals: false, unknownReason: nil)
        case .syncing: return Card(caption: caption, text: "Syncing\u{2026}", tint: nil, signals: false, unknownReason: nil)
        case .localChanges:
            return Card(caption: caption, text: "Local changes", tint: .warn, signals: true, unknownReason: nil)
        case .diverged: return Card(caption: caption, text: "Diverged", tint: .critical, signals: true, unknownReason: nil)
        case .failed: return Card(caption: caption, text: "Failed", tint: .critical, signals: true, unknownReason: nil)
        case .off: return Card(caption: caption, text: "Off", tint: nil, signals: false, unknownReason: nil)
        case .noRepo: return Card(caption: caption, text: "Not set up", tint: nil, signals: false, unknownReason: nil)
        }
    }

    /// "Paused" while the config repo is confirmed public - every push to it
    /// is refused until it is private again - and otherwise the forks.
    static func githubCard(_ counts: BackgroundSignalsPoller.SignalCounts,
                           configRepo: ConfigRepoPrivacy.Reading?) -> Card {
        let caption = captions[4]
        if configRepo?.visibility == .publicRepo {
            return Card(caption: caption, text: "Paused", tint: .critical, signals: true, unknownReason: nil)
        }
        guard let behind = counts.forkDrift, let total = counts.forksTotal, let checked = counts.forksChecked else {
            return Card(caption: caption, text: nil, tint: nil, signals: false,
                        unknownReason: "The forks have not been checked yet this session.")
        }
        if behind > 0 {
            return Card(caption: caption, text: "\(behind) behind", tint: .warn, signals: true, unknownReason: nil)
        }
        if checked == 0 {
            return Card(caption: caption, text: "Couldn\u{2019}t check", tint: .critical, signals: true,
                        unknownReason: nil)
        }
        if checked < total {
            return Card(caption: caption, text: "\(checked) / \(total) read", tint: .warn, signals: true,
                        unknownReason: nil)
        }
        return Card(caption: caption, text: "In sync", tint: nil, signals: false, unknownReason: nil)
    }
}

/// The five cards, kept current from the three readings. One per Setup page
/// in the sidebar layout; each observes on its own and only repaints (GL-24).
final class SetupSummaryRow: NSView {
    private let cards = SetupSummary.captions.map { HelmMetricCard(caption: $0, tint: nil) }
    private var countsToken: BackgroundSignalsPoller.CountsObservation?
    private var configRepoToken: UUID?
    private var dotfiles: DotfilesAutoSync.Status?
    private var configRepo: ConfigRepoPrivacy.Reading?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private(set) var shown: [SetupSummary.Card] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = HelmMetricRow(cards)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
        countsToken = BackgroundSignalsPoller.shared.observeCounts { [weak self] _ in self?.render() }
        DotfilesAutoSync.shared.observeStatus { [weak self] _ in
            self?.dotfiles = DotfilesAutoSync.shared.reportedStatus
            self?.render()
        }
        configRepoToken = ConfigRepoPrivacy.observe { [weak self] reading in
            self?.configRepo = reading
            self?.render()
        }
        dotfiles = DotfilesAutoSync.shared.reportedStatus
        configRepo = ConfigRepoPrivacy.lastReading
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let countsToken { BackgroundSignalsPoller.shared.unobserveCounts(countsToken) }
        if let configRepoToken { ConfigRepoPrivacy.unobserve(configRepoToken) }
    }

    /// Re-read the three readings and repaint the cards.
    func render() {
        shown = SetupSummary.cards(counts: BackgroundSignalsPoller.shared.lastCounts, dotfiles: dotfiles,
                                   configRepo: configRepo)
        for (card, figure) in zip(cards, shown) {
            card.setTint(figure.tint)
            card.configure(text: figure.text, signals: figure.signals, unknownReason: figure.unknownReason)
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        for card in cards { card.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugValues: [String] { cards.map(\.debugValue) }
    var debugCards: [HelmMetricCard] { cards }
    #endif
}

/// GitHub sync's "Pushing is paused" notice (stage 7): a critical-edged card
/// - the shape Tasks' failed-read card uses for a stated failure - with the
/// sentence wrapping under its title and the two actions under it, as the
/// prototype draws it. Shown only while the config repo is confirmed public.
final class SetupPausedPushNotice: NSView {
    static let tileSide: CGFloat = 30

    let card = HelmCard()
    private let tile = IconTileView(size: SetupPausedPushNotice.tileSide, cornerRadius: 8)
    let titleLabel = NSTextField(labelWithString: "Pushing is paused")
    let bodyLabel = NSTextField(wrappingLabelWithString: "")
    let actions = NSStackView()
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(actionButtons: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tile.configure(symbol: "exclamationmark.triangle.fill", tint: .critical)
        tile.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = HelmType.cardTitle()
        bodyLabel.font = HelmType.body()
        bodyLabel.maximumNumberOfLines = 0
        actions.orientation = .horizontal
        actions.spacing = HelmMetrics.s2
        actions.alignment = .centerY
        for button in actionButtons { actions.addArrangedSubview(button) }
        let text = NSStackView(views: [titleLabel, bodyLabel, actions])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s1
        text.setCustomSpacing(HelmMetrics.s3, after: bodyLabel)
        text.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [tile, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        card.setBody(row, insets: HelmCard.contentInsets)
        card.setAttentionEdge(.critical)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Gotcha (22): the sentence wraps at the card's own width less the tile
    /// and the insets - widths this label does not decide - never at its own.
    override func layout() {
        super.layout()
        let insets = HelmCard.contentInsets
        let width = max(160, floor(bounds.width - insets.left - insets.right - Self.tileSide - HelmMetrics.s3))
        if abs(bodyLabel.preferredMaxLayoutWidth - width) > 0.5 {
            bodyLabel.preferredMaxLayoutWidth = width
            bodyLabel.invalidateIntrinsicContentSize()
        }
    }

    func setBody(_ text: String) {
        bodyLabel.stringValue = text
        needsLayout = true
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        tile.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
    }
}
