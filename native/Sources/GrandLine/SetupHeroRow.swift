// Grand Line - native macOS app.
//
// Setup as Sup-1 on the second page-redesign board (`data/grand-line-page-
// redesign-mockups-2/`), the captain's pick: "Full hero in place of the five
// tiles, on all four sub-pages". Sidebar layout only; the floating bar's
// Setup pages draw no summary at all, as before.
//
// Each of Setup's four sub-pages (Updates, Setup steps, Automation and GitHub
// sync) used to open with `SetupSummaryRow`, five boxed tiles on the card
// surface. Now each opens with this hero: the kicker "Setup · This Mac", a
// verdict that is the sub-page's own, a line under it, the sub-page's actions
// as ghost pills, the same five figures as inset tiles on the gradient, and a
// ring of the setup steps done. One hero, four sets of words.
//
// **The figures are the summary's.** The tiles render `SetupSummaryFeed`'s
// cards, so the five figures read the same on all four sub-pages and agree
// with the sidebar's Setup badge, exactly as the summary row did. Unknown is
// never zero (GL-14): a figure not read this session is a dash with its
// reason as the tile's tooltip.
//
// **The words are the sub-page's.** `SetupHeroWords` is pure, so every verdict
// is asserted headless (`SetupHeroSelfTest`). Each sub-page hands the row a
// function that builds its words from the same readings the tiles take, plus
// the page's own facts (when it last checked, which forks carry commits of
// their own, which automations are on).
//
// **One colour rule.** The gradient is `HelmHeroSurface`'s quiet-ink palette
// on a tone: the theme's accent, the theme's amber while the sub-page's own
// subject needs attention, its red when something failed or diverged. The
// hero dims (`HelmHeroSurface.dimmed`) while the sub-page's own reading has
// not been taken, because its verdict cannot be stated yet; another sub-page's
// unread figure is only a dash on its tile.
//
// **The pills are the page's own actions.** Each one mirrors a control the
// page already has - its toolbar primary action, its Refresh - and runs that
// control's own target and action, so a pill can never do something the page
// does not. The page calls `render()` wherever it changes one of them.
//
// Three widths. At 1060pt and over the words, the tiles and the ring sit in
// one row, as the board draws them. Narrower, the tiles go under the words
// and the ring, and under 560pt the ring steps out: the verdict and the
// figures are what the hero always says.

import AppKit

// MARK: - The words

enum SetupHeroWords {

    /// Setup's four sub-pages.
    enum Page: String, CaseIterable {
        case updates, steps, automation, github
    }

    /// The hero's colour: the accent, or a state the verdict is about.
    enum Tone: Equatable {
        case accent, amber, red
    }

    struct Words: Equatable {
        var kicker = SetupHeroWords.kicker
        let headline: String
        let body: String
        let tone: Tone
        /// The sub-page's own reading has not been taken (GL-14).
        let isDimmed: Bool
    }

    static let kicker = "Setup \u{00B7} This Mac"

    /// "Checked 27 min ago." - or nothing when nothing says when.
    static func checked(_ at: Date?, now: Date) -> String {
        guard let at else { return "" }
        return "Checked \(HelmRelativeTime.phrase(since: at, now: now))."
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Updates

    /// From the same counts the Tools and Updates tiles read.
    static func updates(_ counts: BackgroundSignalsPoller.SignalCounts, checkedAt: Date?,
                        now: Date = Date()) -> Words {
        guard let total = counts.toolsTotal, let upToDate = counts.toolsUpToDate else {
            return Words(headline: "Your tools have not been checked yet.",
                         body: "Check for updates reads each tool's installed and latest version.",
                         tone: .accent, isDimmed: true)
        }
        let updates = counts.toolsWithUpdate ?? 0
        let when = checked(checkedAt, now: now)
        if updates > 0 {
            return Words(headline: updates == 1 ? "1 tool has an update." : "\(updates) tools have an update.",
                         body: joined(["\(upToDate) of \(total) are up to date.", when]),
                         tone: .amber, isDimmed: false)
        }
        if upToDate >= total {
            return Words(headline: total == 1 ? "The one tool is up to date." : "All \(total) tools are up to date.",
                         body: joined([when, "Nothing needs attention."]), tone: .accent, isDimmed: false)
        }
        let rest = total - upToDate
        return Words(headline: "\(upToDate) of \(total) tools are up to date.",
                     body: joined(["\(plural(rest, "tool", "tools")) could not be checked or \(rest == 1 ? "is" : "are") "
                                    + "not installed. Needs Attention lists \(rest == 1 ? "it" : "them").", when]),
                     tone: .amber, isDimmed: false)
    }

    // MARK: Setup steps

    /// From the module's one reading of its steps (`SetupStepsReading`), the
    /// one the Setup steps tile and the ring render. `nextStep` is the first
    /// step that is not done, by its title.
    static func steps(_ progress: SetupPipelineProgress, nextStep: String?) -> Words {
        if progress.failed > 0 {
            return Words(headline: progress.failed == 1 ? "A setup step failed." : "\(progress.failed) setup steps failed.",
                         body: "\(progress.done) of \(progress.total) are done. Open the step's Details to see why, "
                            + "or run full setup again.",
                         tone: .red, isDimmed: false)
        }
        if progress.total > 0, progress.checking == progress.total {
            return Words(headline: "Checking the setup steps\u{2026}",
                         body: "Each step runs its own check against this Mac.", tone: .accent, isDimmed: true)
        }
        if progress.checking > 0 {
            return Words(headline: "\(progress.done) of \(progress.total) setup steps are done so far.",
                         body: "\(plural(progress.checking, "step is", "steps are")) still being checked.",
                         tone: .accent, isDimmed: true)
        }
        if progress.done >= progress.total {
            return Words(headline: "Every setup step is done.",
                         body: "Each step's own check passes on this Mac. The drift check re-runs them.",
                         tone: .accent, isDimmed: false)
        }
        return Words(headline: "\(progress.done) of \(progress.total) setup steps are done.",
                     body: nextStep.map { "Next: \($0). Run full setup works through the rest in order." }
                        ?? "Run full setup works through the rest in order.",
                     tone: .accent, isDimmed: false)
    }

    // MARK: Automation

    /// One automation: its name, and when it runs if it runs on a schedule.
    struct Automation: Equatable {
        let name: String
        var cadence: String? = nil
        let isOn: Bool
    }

    /// From the same rows the Automation card switches.
    static func automation(_ automations: [Automation]) -> Words {
        let on = automations.filter(\.isOn)
        let off = automations.filter { !$0.isOn }
        let headline: String
        if automations.isEmpty {
            headline = "Nothing runs on its own yet."
        } else if on.isEmpty {
            headline = "Every automation is off."
        } else if off.isEmpty {
            headline = automations.count == 1 ? "The one automation is on." : "All \(automations.count) automations are on."
        } else {
            headline = "\(plural(on.count, "automation", "automations")) on, \(off.count) off."
        }
        var parts: [String] = []
        if let scheduled = on.first(where: { $0.cadence != nil }), let cadence = scheduled.cadence {
            parts.append("\(scheduled.name) runs \(cadence.prefix(1).lowercased() + cadence.dropFirst()).")
        }
        if !off.isEmpty, !on.isEmpty {
            let names = off.prefix(2).map(\.name) + (off.count > 2 ? ["\(off.count - 2) more"] : [])
            parts.append("\(list(names)) \(off.count == 1 ? "is" : "are") off.")
        }
        if parts.isEmpty {
            parts.append(automations.isEmpty
                ? "Schedules and the switches below run work on this Mac without you."
                : "Turn one on below, or set a schedule in Schedules.")
        }
        return Words(headline: headline, body: parts.joined(separator: " "), tone: .accent, isDimmed: false)
    }

    // MARK: GitHub sync

    /// From the same counts the GitHub sync tile reads, the config repo's
    /// last answer, when the forks were last checked and which forks carry
    /// commits of their own (by name, with how many).
    static func github(_ counts: BackgroundSignalsPoller.SignalCounts, configRepo: ConfigRepoPrivacy.Reading?,
                       checkedAt: Date?, ownCommits: [(name: String, count: Int)] = [],
                       now: Date = Date()) -> Words {
        if configRepo?.visibility == .publicRepo {
            return Words(headline: "Pushing to the config repo is paused.",
                         body: "It is public on GitHub, so nothing is pushed to it until it is private again.",
                         tone: .red, isDimmed: false)
        }
        let when = checked(checkedAt, now: now)
        switch SetupSummary.ForksFigure(counts) {
        case .unread:
            return Words(headline: "The forks have not been checked yet.",
                         body: "Refresh compares each fork with its upstream.", tone: .accent, isDimmed: true)
        case .couldNotCheck:
            return Words(headline: "The forks could not be checked.",
                         body: joined(["Every check failed. Each fork's row says why.", when]), tone: .red, isDimmed: false)
        case let .partlyRead(checkedCount, total):
            return Words(headline: "\(checkedCount) of \(plural(total, "fork", "forks")) could be checked.",
                         body: joined(["The rest failed, and each of their rows says why.", when]),
                         tone: .amber, isDimmed: false)
        case let .toSync(behind, diverged):
            let total = counts.forksTotal ?? behind
            if diverged == 0 {
                return Words(headline: behind == 1 ? "1 fork is behind upstream." : "\(behind) of \(total) forks are behind upstream.",
                             body: joined(["Sync All fast-forwards \(behind == 1 ? "it" : "them").", when]),
                             tone: .amber, isDimmed: false)
            }
            let headline = diverged == behind
                ? (diverged == 1 ? "1 fork has diverged from upstream." : "\(diverged) forks have diverged from upstream.")
                : "\(behind) forks need syncing, \(diverged) diverged."
            return Words(headline: headline,
                         body: joined(["A diverged fork is merged from its own row, one at a time.", when]),
                         tone: .red, isDimmed: false)
        case let .inSync(total):
            var own = ""
            if ownCommits.count == 1, let fork = ownCommits.first {
                own = "\(fork.name) carries \(plural(fork.count, "commit", "commits")) of its own on top of upstream."
            } else if ownCommits.count > 1 {
                own = "\(list(ownCommits.map(\.name))) carry commits of their own on top of upstream."
            }
            return Words(headline: total == 1 ? "1 fork, in sync." : "\(total) forks, all in sync.",
                         body: joined([when, own]), tone: .accent, isDimmed: false)
        }
    }

    // MARK: The ring

    struct Ring: Equatable {
        let fraction: Double
        let label: String
        let spoken: String
        let failed: Bool
    }

    /// The setup steps done, as the ring draws them. A step still being
    /// checked makes the label a dash (GL-14), as the tile's figure is.
    /// VoiceOver reads the module's one progress sentence
    /// (`SetupPipelineProgress.summary`, review U7/X4), never a second
    /// spelling of it.
    static func ring(_ progress: SetupPipelineProgress) -> Ring {
        guard progress.total > 0, progress.checking == 0 else {
            return Ring(fraction: 0, label: HelmReading<String>.dash,
                        spoken: "Setup steps not checked yet", failed: false)
        }
        return Ring(fraction: Double(progress.done) / Double(progress.total),
                    label: "\(progress.done)/\(progress.total)",
                    spoken: "Setup steps, \(progress.summary)", failed: progress.failed > 0)
    }

    /// The tiles, from the summary's cards. A word figure that only says a
    /// feature is not in use ("Off", "Not set up") is quiet, as the board
    /// draws it, so the figures that mean something carry the weight.
    static func items(_ cards: [SetupSummary.Card]) -> [HelmKPIStrip.Item] {
        zip(SetupSummary.captions, cards).map { caption, card in
            let item = HelmKPIStrip.Item.figure(card.text, caption: caption, tint: card.tint, signals: card.signals,
                                                unknownReason: card.unknownReason)
            guard card.isIdle else { return item }
            return HelmKPIStrip.Item(item.reading, caption: caption, emphasis: .quiet, toolTip: item.toolTip)
        }
    }
}

// MARK: - The hero

final class SetupHeroRow: NSView {

    /// One pill: a control the page already has, read each time the row
    /// renders so its words and its enabled state follow the page's.
    struct Action {
        let title: () -> String
        let isEnabled: () -> Bool
        let toolTip: () -> String?
        let run: () -> Void

        /// A pill for one of the page's own buttons: its title, its enabled
        /// state and its tooltip, and a press runs its own target and action.
        static func mirroring(_ button: NSButton) -> Action {
            Action(title: { button.title }, isEnabled: { button.isEnabled }, toolTip: { button.toolTip },
                   run: { [weak button] in
                       guard let button, button.isEnabled, let action = button.action else { return }
                       _ = (button.target as AnyObject?)?.perform(action, with: button)
                   })
        }
    }

    enum Arrangement: Equatable { case wide, stacked, narrow }

    static let cornerRadius: CGFloat = 14
    static let insets = HelmHeroCard.insets
    static let headlineSize: CGFloat = HelmHeroCard.titleSize
    static let bodySize: CGFloat = 12.5
    static let wordsWidth: CGFloat = 380
    /// At and over this width the words, tiles and ring share one row.
    static let wideWidth: CGFloat = 1060
    /// Under this width the ring steps out.
    static let ringMinimumWidth: CGFloat = 560
    /// The words' ink for the kicker and the tiles' captions; the palette is
    /// deepened until it clears the text floor (`palette(accent:quietInk:)`).
    static let quietInkAlpha: CGFloat = HelmKPIStrip.heroCaptionAlpha

    let page: SetupHeroWords.Page
    /// The sub-page's words, built from its readings each time the row
    /// renders.
    var words: () -> SetupHeroWords.Words
    private var actions: [Action] = []
    private(set) var shown: [SetupSummary.Card] = []
    private(set) var current: SetupHeroWords.Words
    private(set) var arrangement: Arrangement = .wide

    private let feed: SetupSummaryFeed
    private var feedToken: UUID?
    private var themeToken: ThemeObservation?
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let surface = HelmHeroSurface()
    private let tile = NSView()
    private let glyph = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let pillsRow = NSStackView()
    private var pills: [HelmButton] = []
    private let wordsColumn = NSStackView()
    private let tiles = HelmKPIStrip(density: .boxed)
    private let ring = HelmRingGauge(side: HelmRingGauge.heroSide)
    private let ringCaption = NSTextField(labelWithString: "setup steps")
    private let ringColumn = NSStackView()

    private var wideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var wordsToRing: NSLayoutConstraint!
    private var wordsToEdge: NSLayoutConstraint!
    private var stackedToRing: [NSLayoutConstraint] = []
    private var stackedToEdge: [NSLayoutConstraint] = []

    init(page: SetupHeroWords.Page, feed: SetupSummaryFeed = .shared,
         words: @escaping () -> SetupHeroWords.Words) {
        self.page = page
        self.feed = feed
        self.words = words
        self.current = words()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addSubview(surface)
        buildWords()
        buildRing()
        tiles.setAccessibilityLabel("Setup at a glance")
        for view in [wordsColumn, tiles, ringColumn] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        buildConstraints()
        feedToken = feed.observe { [weak self] in self?.render() }
        render()
        // After `render`, so the first synchronous firing paints a hero that
        // already holds its words (ThemeManager's checklist, item 4).
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let feedToken { feed.unobserve(feedToken) }
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: Building

    private func buildWords() {
        tile.wantsLayer = true
        tile.layer?.cornerRadius = HelmMetrics.rChip
        tile.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = HelmSymbol.image("wrench.and.screwdriver", pointSize: 11, weight: .semibold)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 20),
            tile.heightAnchor.constraint(equalToConstant: 20),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        kickerLabel.lineBreakMode = .byTruncatingTail
        kickerLabel.maximumNumberOfLines = 1
        kickerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (label, lines) in [(headlineLabel, 2), (bodyLabel, 3)] {
            label.isSelectable = false
            label.maximumNumberOfLines = lines
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        for label in [kickerLabel, headlineLabel, bodyLabel] { label.setAccessibilityElement(false) }

        let kickerRow = NSStackView(views: [tile, kickerLabel])
        kickerRow.orientation = .horizontal
        kickerRow.alignment = .centerY
        kickerRow.spacing = HelmMetrics.s2
        pillsRow.orientation = .horizontal
        pillsRow.alignment = .centerY
        pillsRow.spacing = HelmMetrics.s2
        pillsRow.detachesHiddenViews = true
        // A lone pill in a leading-aligned column stretches unless its row
        // hugs at stack level (gotcha (12)).
        pillsRow.setHuggingPriority(.required, for: .horizontal)
        wordsColumn.setViews([kickerRow, headlineLabel, bodyLabel, pillsRow], in: .top)
        wordsColumn.orientation = .vertical
        wordsColumn.alignment = .leading
        wordsColumn.spacing = HelmMetrics.s1
        wordsColumn.setCustomSpacing(HelmMetrics.s2, after: kickerRow)
        wordsColumn.setCustomSpacing(HelmMetrics.s3, after: bodyLabel)
        wordsColumn.detachesHiddenViews = true
        for stack in [kickerRow, wordsColumn] {
            stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
            stack.setHuggingPriority(.defaultLow, for: .horizontal)
        }
    }

    private func buildRing() {
        ringCaption.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .medium)
        ringCaption.alignment = .center
        ringCaption.setAccessibilityElement(false)
        ringColumn.setViews([ring, ringCaption], in: .top)
        ringColumn.orientation = .vertical
        ringColumn.alignment = .centerX
        ringColumn.spacing = HelmMetrics.s1
        ringColumn.setHuggingPriority(.required, for: .horizontal)
        ringColumn.setClippingResistancePriority(.required, for: .horizontal)
    }

    private func buildConstraints() {
        let i = Self.insets
        let gap = HelmMetrics.s5
        // The hero is as tall as its tallest part, each a required floor, and
        // no taller (gotcha (16)). Under the labels' own compression (250):
        // at `.defaultLow` the two tied, and the body gave up its width to
        // save a line - "on this Ma..." at 1100pt.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeCompression
        // The words' preferred width in the wide row sits under the window's
        // stay-put priority, so it can never hold the window open (gotcha
        // (13)); the inequalities beside it are what keep the row inside.
        let wordsWidth = wordsColumn.widthAnchor.constraint(equalToConstant: Self.wordsWidth)
        wordsWidth.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            hug,
            wordsColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
            wordsColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: i.top),
            wordsColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -i.bottom),
            ringColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right),
            ringColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: i.top),
            ringColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -i.bottom),
            tiles.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -i.bottom),
        ])
        wideConstraints = [
            wordsWidth,
            wordsColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            tiles.leadingAnchor.constraint(equalTo: wordsColumn.trailingAnchor, constant: gap),
            tiles.trailingAnchor.constraint(equalTo: ringColumn.leadingAnchor, constant: -gap),
            tiles.centerYAnchor.constraint(equalTo: centerYAnchor),
            tiles.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: i.top),
            ringColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        let tilesUnderWords = tiles.topAnchor.constraint(equalTo: wordsColumn.bottomAnchor, constant: HelmMetrics.s4)
        tilesUnderWords.priority = .defaultLow
        stackedConstraints = [
            wordsColumn.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
            ringColumn.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
            tiles.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
            tiles.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right),
            tiles.topAnchor.constraint(greaterThanOrEqualTo: wordsColumn.bottomAnchor, constant: HelmMetrics.s4),
            tiles.topAnchor.constraint(greaterThanOrEqualTo: ringColumn.bottomAnchor, constant: HelmMetrics.s4),
            tilesUnderWords,
            tiles.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -i.bottom),
        ]
        wordsToRing = wordsColumn.trailingAnchor.constraint(lessThanOrEqualTo: ringColumn.leadingAnchor, constant: -gap)
        wordsToEdge = wordsColumn.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -i.right)
        // Stacked, the words take the row beside the ring (or the whole row
        // with no ring), under the window's stay-put priority as in the wide
        // row, so their wrap width is the room they really have.
        let fillsToRing = wordsColumn.trailingAnchor.constraint(equalTo: ringColumn.leadingAnchor, constant: -gap)
        fillsToRing.priority = HelmDaylightPriority.contentTie
        let fillsToEdge = wordsColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right)
        fillsToEdge.priority = HelmDaylightPriority.contentTie
        stackedToRing = [wordsToRing, fillsToRing]
        stackedToEdge = [wordsToEdge, fillsToEdge]
        NSLayoutConstraint.activate(wideConstraints)
    }

    // MARK: Content

    /// The pills, in order. Each mirrors one of the page's own controls.
    func setActions(_ actions: [Action]) {
        self.actions = actions
        for pill in pills {
            pillsRow.removeArrangedSubview(pill)
            pill.removeFromSuperview()
        }
        pills = actions.indices.map { index in
            let pill = HelmButton(title: "", variant: .secondary, size: .small, target: self,
                                  action: #selector(pillPressed(_:)))
            pill.tag = index
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            pillsRow.addArrangedSubview(pill)
            return pill
        }
        render()
    }

    @objc private func pillPressed(_ sender: HelmButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].run()
        render()
    }

    /// Re-read the feed, the sub-page's words and its controls, and repaint.
    /// Cheap: the tiles update in place and nothing is rebuilt.
    func render() {
        shown = feed.cards
        current = words()
        kickerLabel.stringValue = current.kicker.uppercased()
        headlineLabel.stringValue = current.headline
        bodyLabel.stringValue = current.body
        bodyLabel.isHidden = current.body.isEmpty
        tiles.configure(SetupHeroWords.items(shown), theme: theme)
        let reading = SetupHeroWords.ring(feed.steps)
        ring.configure(fraction: reading.fraction, text: reading.label)
        ring.setSpokenLabel(reading.spoken)
        for (pill, action) in zip(pills, actions) {
            let title = action.title()
            if pill.title != title { pill.title = title }
            if pill.isEnabled != action.isEnabled() { pill.isEnabled = action.isEnabled() }
            pill.toolTip = action.toolTip()
        }
        pillsRow.isHidden = pills.isEmpty
        setAccessibilityLabel([current.kicker, current.headline, current.body].filter { !$0.isEmpty }
            .joined(separator: ". "))
        applyTheme(theme)
        needsLayout = true
    }

    // MARK: Theme and layout

    /// The hero's colours for `words` in `theme`.
    static func palette(for words: SetupHeroWords.Words, in theme: HelmTheme) -> HelmHeroSurface.Palette {
        let hex: String
        switch words.tone {
        case .accent: hex = theme.heroAccentHex
        case .amber: hex = theme.ansiHex[3]
        case .red: hex = theme.ansiHex[1]
        }
        let accent = HelmContrast.components(HelmTheme.nsColor(hex))
        return HelmHeroSurface.palette(accent: words.isDimmed ? HelmHeroSurface.dimmed(accent) : accent,
                                       quietInk: Double(quietInkAlpha))
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = Self.palette(for: current, in: theme)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        // A white-ink hero is a dark surface: the pills on it take the dark
        // appearance (ThemeManager's checklist, item 2).
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        tile.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.tileFillAlpha).cgColor
        glyph.contentTintColor = ink
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue,
            attributes: HelmType.kickerAttributes(color: ink.withAlphaComponent(Self.quietInkAlpha)))
        headlineLabel.font = .systemFont(ofSize: HelmType.scaled(Self.headlineSize), weight: .bold)
        bodyLabel.font = .systemFont(ofSize: HelmType.scaled(Self.bodySize))
        headlineLabel.textColor = ink
        bodyLabel.textColor = ink
        for pill in pills { pill.heroInk = ink }
        tiles.heroPalette = palette
        tiles.heroInk = ink
        tiles.applyTheme(theme)
        ringCaption.textColor = ink.withAlphaComponent(Self.quietInkAlpha)
        ring.trackColorOverride = ink.withAlphaComponent(0.25)
        ring.labelColorOverride = ink
        ring.valueColorOverride = SetupHeroWords.ring(feed.steps).failed
            ? HelmHeroSurface.signalColor(tintHex: theme.ansiHex[1], on: palette) : ink
        ring.applyTheme(theme, hue: .blue)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        let next: Arrangement = width >= Self.wideWidth ? .wide : (width >= Self.ringMinimumWidth ? .stacked : .narrow)
        if next != arrangement { setArrangement(next) }
        // Gotcha (22): the words wrap at a width they do not decide - the
        // hero's own, less its insets and whatever shares their row.
        let i = Self.insets
        let ringRoom = ringColumn.isHidden ? 0 : ringColumn.fittingSize.width + HelmMetrics.s5
        let room = arrangement == .wide ? Self.wordsWidth : width - i.left - i.right - ringRoom
        let wrap = max(120, floor(room))
        for label in [headlineLabel, bodyLabel] where abs(label.preferredMaxLayoutWidth - wrap) > 0.5 {
            label.preferredMaxLayoutWidth = wrap
            label.invalidateIntrinsicContentSize()
        }
    }

    private func setArrangement(_ next: Arrangement) {
        arrangement = next
        NSLayoutConstraint.deactivate(wideConstraints + stackedConstraints + stackedToRing + stackedToEdge)
        ringColumn.isHidden = next == .narrow
        switch next {
        case .wide:
            NSLayoutConstraint.activate(wideConstraints)
        case .stacked:
            NSLayoutConstraint.activate(stackedConstraints + stackedToRing)
        case .narrow:
            NSLayoutConstraint.activate(stackedConstraints + stackedToEdge)
        }
        needsLayout = true
    }

    #if FM_SELFTESTS
    var debugValues: [String] { tiles.debugCells.map(\.debugValue) }
    var debugCards: [HelmKPIStrip.BoxedCell] { tiles.debugCells }
    var debugHeadline: String { headlineLabel.stringValue }
    var debugBody: String { bodyLabel.stringValue }
    var debugKicker: String { kickerLabel.stringValue }
    var debugPills: [HelmButton] { pills }
    var debugRing: HelmRingGauge { ring }
    var debugRingShown: Bool { !ringColumn.isHidden }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugHeadlineLabel: NSTextField { headlineLabel }
    var debugBodyLabel: NSTextField { bodyLabel }
    var debugTiles: HelmKPIStrip { tiles }
    var debugWordsColumn: NSView { wordsColumn }
    var debugRingColumn: NSView { ringColumn }
    #endif
}
