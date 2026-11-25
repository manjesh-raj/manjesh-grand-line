// Grand Line - native macOS app.
//
// Fix 1: the real Fleet dashboard for the Overview rail destination,
// replacing the "coming soon" `PlaceholderViewController`. Structure mirrors
// `backend/static/index.html`'s Fleet view: a greeting header, an answer
// banner that goes calm/loud depending on whether anything needs the
// captain, a row of quiet stat readouts, and an "In flight" section of
// working crew. All data comes from `FleetData.swift`, which reads this
// machine's real firstmate home - nothing here is fabricated.
//
// fm/grandline-overview-drop-duplicate-pr-list: this page used to also carry
// a full itemized "Ready to merge" list (one row per PR, its own Review/
// Merge actions) built from the exact same `OpenPRsSource.fetch()` +
// `FleetDataSource.mergedPRs` data `.review` (`ReviewController.swift`)
// already presents, grouped by forge - a captain-flagged triplication (stat
// tile + this list + Review's own list). That list is gone; the "ready to
// merge" stat tile is the one signal left here, and it's clickable straight
// through to `.review` via `onNavigateToReview`.

// F12 (`fm/grandline-feature-f12-morning-briefing`): this page also hosts the
// morning briefing card - see `MorningBriefingData.swift` for what it says and
// `MorningBriefingCard.swift` for how it looks. Everything the briefing knows
// comes from data this controller already fetched for its own banner and stat
// tiles, plus the shared `ShiftStore`, `BackgroundSignalsPoller.lastCounts`
// (counts that poller already computed) and one `QuotaSource.fetch()`.

// CR-1 Crew band (the hero restyle board, `data/grandline-hero-restyle-
// designs-scout/`): in the sidebar layout every Crew tab this page draws opens
// on one band, a `HelmHeroColumn` in `.band`, which says what the briefing
// card, the answer banner, the boxed figures and Needs you's summary line and
// empty state said. The words are `CrewHeroWords`. The floating bar's Fleet
// page builds no band and draws exactly what it drew before.

import AppKit

final class FleetController: NSViewController {

    // MARK: F12 - the morning briefing
    //
    // `shiftStore` is the *shared* store the app delegate builds and hands to
    // `AppShellController` - deliberately not a second `ShiftStore()`. That
    // one caches and writes, so a second instance would diverge in-session
    // and race the first's files (see AGENTS.md's `CommandLibraryStore` note
    // on exactly this lesson). Two consumers on this page now: F12's briefing
    // reads its due-task count from it, and F6's Log tab reads the task half
    // of its feed from the same store's activity YAML.
    private let shiftStore: ShiftStore
    private let briefingCard = MorningBriefingCard()
    /// The `.quota` clause opens `QuotaUsageController`'s own popover,
    /// anchored on the briefing paragraph - this page's own instance, not
    /// shared with anything else (`QuotaUsagePopover.swift`'s header: this
    /// used to also be reachable from a Console toolbar button on the
    /// herdr-attached "Mirror" tab, removed in
    /// `fm/grand-line-remove-firstmate-mirror`).
    private let quotaUsage = QuotaUsageController()
    private var isGeneratingBriefing = false

    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` took four
    /// dependencies back off this page: the command library's root and the
    /// three phase-3 write stores. Every one of them existed only for the
    /// Straw Hat crew - the command library's root for their read-only
    /// `command_search` tool, the other three for their proposal kinds - and
    /// they moved to `StrawHatController` with the chat. This page never
    /// listed, searched or wrote a command, a sticky note or a schedule.
    /// `logStore` is the Log tab's own file, `FleetLogStore.shared` in the
    /// app. A suite hands in one on a scratch folder, so the page reads a log
    /// it wrote (or broke) through the same read the app does.
    init(shiftStore: ShiftStore, logStore: FleetLogStore = .shared) {
        self.shiftStore = shiftStore
        self.logStore = logStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// S03: the page frame - scroll, flipped document, gutter and the
    /// first-content line.
    private let scaffold = HelmPageScaffold(spacing: HelmMetrics.s4, bottomInset: HelmMetrics.s5)
    private var scroll: NSScrollView { scaffold.scrollView }
    private var contentStack: NSStackView { scaffold.stack }

    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// The app's one Refresh (`HelmButton.refresh`, UXP-08): a labelled
    /// secondary button, because Refresh re-reads and is never what a page
    /// is for.
    private let refreshButton = HelmButton.refresh()
    /// R4-UX-08 of the fourth full review (WF-08 of the first): Stop, beside
    /// Refresh while a pass is in flight. The PR scan is a process per clone
    /// and can run for tens of seconds on a slow network; until now the only
    /// way out was to wait. Stop abandons the pass: the page is idle again at
    /// once, what the pass would have reported is dropped, and the PR reading
    /// says the scan was stopped rather than claiming a count (GL-14). The
    /// children already running finish under `Subprocess`'s own bound.
    private let stopButton = HelmButton(title: "Stop", variant: .secondary, symbol: "stop.fill")
    private var refreshGeneration = 0
    private var lastRenderedSnapshot: FleetSnapshot?
    static let stoppedScanSummary = "scan stopped"
    /// Review #3 §7's replacement for the dashboard's quick-ask composer -
    /// see `onOpenCrew`. `.secondary`, so the page still has exactly one
    /// primary action (Refresh) and this reads as the navigation it is.
    private let crewButton = HelmButton(title: "Ask your crew", variant: .secondary,
                                        symbol: StrawHatCrew.speaker.symbol)

    /// The answer banner is the app's shared `HelmAccentRow` now, not a
    /// hand-rolled tinted slab with a text glyph in it. The prototype renders
    /// it exactly like every other alert card in the app - a 3pt accent bar, a
    /// round badge, an uppercase kicker ("ALL CLEAR" / "NEEDS YOU"), the
    /// headline and a meta line - and the audit's whole point was that this
    /// page had its own private version of an idea the design system already
    /// owns.
    /// S17: the answer is a `HelmNotice`. Setup's prompt carries one action
    /// that opens Setup, where the whole row used to be the link.
    private lazy var bannerRow = HelmNotice()
    private lazy var openSetupButton = HelmButton(title: "Open \(PlaceName.of(.bootstrap))", variant: .secondary,
                                                  size: .small, target: self, action: #selector(openSetupTapped))

    /// S14: the six figures are a `.boxed` `HelmKPIStrip`, without the icons
    /// the old tiles carried (the caption says what each is). "ready to
    /// merge" is the one cell that is a button, into Review.
    private lazy var statsRow: HelmKPIStrip = {
        let strip = HelmKPIStrip(density: .boxed)
        strip.onActivate = { [weak self] index in
            guard let self, self.statItems.indices.contains(index), self.statItems[index].opensReview else { return }
            self.onNavigateToReview?()
        }
        return strip
    }()
    private var statItems: [StatTileItem] = []

    /// A plain section heading (round glyph + title + count chip), not a
    /// `HelmCard` wrapper. The prototype puts "In flight" rows straight on the
    /// page: they are `HelmAccentRow` cards already, so a card around a list
    /// of cards is a second border for nothing.
    private let inFlightHeader = NSTextField(labelWithString: "")
    private let inFlightCountChip = NSView()
    private let inFlightCountLabel = NSTextField(labelWithString: "")
    private let inFlightGlyph = IconTileView(size: 22, cornerRadius: 11)
    private let inFlightStack = NSStackView()

    /// Shown in place of the data sections above until the first
    /// `render(...)` lands - see the loading-state note on `buildLoadingState`.
    private let loadingContainer = NSView()
    /// D3: a layout-shaped placeholder, not a spinner. See `HelmSkeleton.swift`.
    private let loadingSkeleton = HelmSkeletonList()
    private let loadingLabel = NSTextField(labelWithString: "Loading fleet data\u{2026}")
    private var inFlightSectionView: NSView!
    private var hasLoadedOnce = false

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var isLoading = false

    // MARK: F6 - the "Log" tab (captain's log)

    /// F6: this page is two tabs - the live dashboard, and a durable,
    /// reverse-chronological record of what has already happened. Same
    /// `HelmSegmentedTabs` shape Shift/Docs/Hosts already use; the dashboard
    /// stays the default.
    ///
    /// **The first tab is labelled "Dashboard", not "Overview"** (review #3
    /// §7). This destination is called "Fleet" in the rail title, in its drill
    /// header and on its canvas card, so a tab repeating the page's own name
    /// says nothing - and "Overview" was the canvas's word, which is what made
    /// three names read as three places. "Dashboard" is what this tab already
    /// calls itself in every comment in this file.
    ///
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` removed a third tab
    /// ("Crew"). Phases 1-3 put the Straw Hat Pirates chat here; the captain's
    /// own correction moved it to its own Overview card and its own page
    /// (`StrawHatController`), so this page is back to the two tabs F6 gave
    /// it. Note the two "crews" that had collided: this page's Overview tab is
    /// Grand Line's own *dispatched crewmate* board, which is a different
    /// thing entirely from an AI persona chat.
    private enum OverviewTab: String, CaseIterable {
        case overview, log
        var title: String {
            switch self {
            case .overview: return "Dashboard"
            case .log: return "Log"
            }
        }
    }

    private var activeTab: OverviewTab = .overview
    /// The sidebar layout's toolbar draws the two tabs as Crew's In flight and
    /// Log, and this page's Needs you as Crew's first (`ModuleTabHosting`, at
    /// the end of this file).
    var onModuleTabChanged: (() -> Void)?

    // MARK: Crew › Needs you (the sidebar layout's, at the end of this file)

    /// Set once, by `adoptSidebarLayout()`: Crew's first tab, Needs you, is
    /// this page's. Never set in the floating bar, whose Dashboard still
    /// carries the Needs your call list.
    private(set) var drawsSidebarLayout = false
    /// Needs you is showing. Not an `OverviewTab`, whose cases are the
    /// floating bar's own two segments.
    private var needsYouShowing = false
    private let needsYouContainer = NSStackView()
    /// CR-1: Open Setup on the band's foot, on Needs you and In flight alike,
    /// when no firstmate home is set (GL-31).
    private let needsYouSetupButton = HelmButton(title: "Open \(PlaceName.of(.bootstrap))", variant: .secondary, size: .small,
                                                 symbol: "hammer")
    /// When the crew's state was last read, which the summary says - never a
    /// count without its age.
    private var needsYouCheckedAt: Date?
    /// When the crew's task list was last read successfully.
    private var needsYouReadAt: Date?
    /// The last read could not read the crew's task list at all.
    private var needsYouReadFailed = false
    /// Whether the last read found a firstmate home to read.
    private var needsYouHomeOk = true
    /// Each task last read as waiting on the captain, and when. A task whose
    /// state the next read cannot get stays listed from here, with its age.
    private var needsYouKnown: [String: (task: FleetTask, readAt: Date)] = [:]
    /// How many tasks the last read's Needs you list holds.
    private var needsYouListedCount = 0
    /// Two skeleton rows under Needs you's band until the first read lands.
    private let needsYouSkeleton = HelmCard()
    private let needsYouSkeletonRows = HelmSkeletonList(rows: 2)

    // MARK: CR-1 - the Crew band (the sidebar layout's, at the end of this file)

    /// The band every tab this page draws opens on in the sidebar layout.
    /// Lazy, and only ever touched behind `drawsSidebarLayout`, so the
    /// floating bar never builds one.
    private lazy var crewBand = HelmHeroColumn()
    /// The band's strip: In flight's six figures, or Needs you's three.
    /// Ready to merge is its one button, into Review.
    private lazy var bandFigures: HelmKPIStrip = {
        // Packed at the band's leading edge (`CrewBand.figureStrip`).
        let strip = CrewBand.figureStrip()
        strip.onActivate = { [weak self] index in
            guard let self, self.bandFigureWords.indices.contains(index),
                  self.bandFigureWords[index].opensReview else { return }
            self.onNavigateToReview?()
        }
        return strip
    }()
    private var bandFigureWords: [CrewHeroWords.Figure] = []
    /// What In flight read last, so a tab switch re-draws the band with no
    /// fetch. `nil` until the first read lands.
    private var inFlightReading: CrewHeroWords.InFlightReading?
    /// The Morning briefing on the band: the record shown, whether one is
    /// being composed, its line with Regenerate and Dismiss until tomorrow as
    /// ghost icons, and its sentences as Home's Br-3 tiles.
    private var bandBriefing: MorningBriefingRecord?
    private var bandBriefingBusy = false
    private lazy var bandRegenerateButton: HelmButton = {
        let button = HelmPageToolbar.iconButton(
            symbol: "clock", tooltip: "Regenerate the briefing. "
                + AITransparency.willSendToClaude("today's counts, never a title or a note,"),
            target: self, action: #selector(bandRegenerateTapped))
        button.setAccessibilityLabel("Regenerate the briefing")
        return button
    }()
    private lazy var bandDismissButton: HelmButton = {
        let button = HelmPageToolbar.iconButton(symbol: "xmark", tooltip: "Dismiss until tomorrow",
                                                target: self, action: #selector(bandDismissTapped))
        button.setAccessibilityLabel("Dismiss until tomorrow")
        return button
    }()
    private lazy var bandBriefingRow: HelmHeroRow = {
        let actions = NSStackView(views: [bandRegenerateButton, bandDismissButton])
        actions.orientation = .horizontal
        actions.spacing = HelmMetrics.s1
        // Gotcha (12): a stack's own hugging, one step over the row's words
        // (250), so the words take the slack and the two icons sit at the
        // band's trailing edge as the board draws them. Under 500.
        actions.setHuggingPriority(HelmDaylightPriority.columnHug, for: .horizontal)
        // A placeholder second line: a row built without one hides its label.
        return HelmHeroRow(leading: .symbol("sun.max"), title: "Morning briefing", subtitle: " ", trailing: actions)
    }()
    private let bandTiles = HelmHeroTileGrid()
    /// The clauses the tiles were built for, so a render that changes nothing
    /// keeps the tiles it has (and their hover).
    private var bandTileClauses: [BriefingClause] = []
    /// The band's last configuration, so a refresh that changes nothing does
    /// not rebuild it.
    private var bandSignature = ""
    private let tabs = HelmSegmentedTabs(items: OverviewTab.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                         selected: OverviewTab.overview.rawValue)

    /// The dashboard's own sections, wrapped so the whole set can be hidden
    /// as one. Arranged subviews of an `NSStackView`, so hiding genuinely
    /// removes them from layout (AGENTS.md gotcha (11) is about an *ordinary*
    /// hidden `NSView`, which this is not).
    private let overviewContainer = NSStackView()

    private let logContainer = NSStackView()
    private let logFilters = HelmSegmentedTabs(items: FleetLogListView.filterItems,
                                               selected: FleetLogListView.allFilterID,
                                               size: .compact)
    private let logList = FleetLogListView()
    private var logFilterKind: FleetLogEventKind?
    private var logStore: FleetLogStore
    /// CR-1: what the Log tab last read, counted for its band. Read with the
    /// list, so the band counts exactly what the list shows.
    private var logReading = CrewHeroWords.LogReading()

    // MARK: Straw Hat Pirates - reaching the crew from here

    /// Opens the crew's own destination. No argument: this page has nothing
    /// to send.
    ///
    /// **Review #3 §7 removed the composer that used to be here.** M3.3 put a
    /// live "Ask your crew" text field on this dashboard, and
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` kept it when the
    /// chat moved to its own destination. Review #3's reading is that a
    /// dashboard is for reading state at a glance, and a second live text
    /// input for a feature whose real composer is one destination away is a
    /// duplicate however it is justified - it was the only text input on any
    /// dashboard page in the app, and it sat on a page that already carries a
    /// Refresh. So the field is gone and what is left is one quiet action in
    /// the page header, beside Refresh: the crew is still one click from here,
    /// and there is exactly one place in the app that composes a message to
    /// them.
    var onOpenCrew: (() -> Void)?

    /// fm/grandline-sidebar-badges: fires every time `render` recomputes the
    /// banner's "needs your call" set (`needs_decision`/`blocked` tasks) -
    /// the exact same signal the banner text above already surfaces, not a
    /// new count invented for the rail. `AppShellController` forwards this
    /// on to `NotificationSources.setFleetDecisions`. It used to also drive
    /// the rail's own badge, which Daylight Phase 2 removed along with the
    /// rail - the count itself is unchanged and still comes from this page's
    /// own refresh.
    var onNeedsDecisionCountChanged: ((Int) -> Void)?

    /// Daylight Phase 2: this page's own refresh result, pushed to whoever
    /// wants it (the home canvas's Fleet and Merge-queue modules).
    ///
    /// Fired from `render`, so it rides the refresh triggers this page
    /// already has - the launch `refreshIfNeeded()`, a page visit, the manual
    /// Refresh button, a merge action. **This is the whole reason the canvas
    /// needs no fetch of its own**: `snapshot()` plus `OpenPRsSource
    /// .fetchDetailed()` is seconds of real work, and doing it twice - once
    /// here, once on the hub the captain returns to constantly - would be a
    /// straight doubling of the app's own cost for numbers it already had.
    var onSnapshotChanged: ((FleetSnapshot, [MergedPR]?, String?) -> Void)?
    /// Fired when this controller's own briefing pass has a Claude quota
    /// reading - the Home canvas's `.claudeStatus` card is a second reader of
    /// the fetch the briefing already pays for, never a second caller of it
    /// (`HomeCanvasController`'s file header, rule 1).
    var onQuotaChanged: ((QuotaFetchResult) -> Void)?

    /// fm/grandline-overview-drop-duplicate-pr-list: fired when the captain
    /// clicks the "ready to merge" stat tile - `AppShellController` wires
    /// this to `show(.review)`, the same navigation call every other
    /// cross-page jump in this app already uses.
    var onNavigateToReview: (() -> Void)?

    /// GL-31: firstmate home not being configured is a *setup* state, not a
    /// fleet state - so Overview says so and offers the one action that fixes
    /// it, instead of printing a raw environment-variable name as UI copy and
    /// leaving the captain to find the Setup flyout on their own.
    var onNavigateToSetup: (() -> Void)?

    /// F12: where a briefing clause's deep link goes for the destinations this
    /// page has no dedicated callback for already. One closure over
    /// `RailDestination` rather than four more - `AppShellController.show(_:)`
    /// is the only thing on the other end, and this page has no business
    /// knowing more about navigation than "take me to that rail destination".
    var onNavigateToDestination: ((RailDestination) -> Void)?

    /// F12: a `.tasks` clause when the app itself resolved exactly one due
    /// Shift task - wired to `AppShellController.openShiftTask(id:)`, the same
    /// "open this task" behaviour every other entry point uses. The id is
    /// always the app's own (`BriefingInputs.singleDueTaskID`), never
    /// something a model wrote.
    var onOpenShiftTask: ((String) -> Void)?

    // MARK: F7 - answering the crew (see `FleetController+Reply.swift`)

    /// The "Needs your call" section: the needs-decision/blocked tasks the
    /// banner above only counts. Same plain-heading-over-`HelmAccentRow`-cards
    /// shape as "In flight" (see `buildSection`'s own note on why there is no
    /// `HelmCard` around a list of cards).
    let needsHeaderLabel = NSTextField(labelWithString: "Needs your call")
    let needsCountChip = NSView()
    let needsCountLabel = NSTextField(labelWithString: "")
    let needsGlyph = IconTileView(size: 22, cornerRadius: 11)
    let needsStack = NSStackView()
    var needsSectionView: NSView!

    /// Which row currently has its inline composer expanded, and the composer
    /// itself - kept across a re-render so a background refresh cannot throw
    /// away a half-typed answer. The floating bar's dashboard opens a
    /// `FleetMessageComposer` under the row, and the sidebar layout's Needs
    /// you a `FleetReplyCard` in the row's place (RP-2).
    var openReplyTaskID: String?
    var openReplyComposer: FleetReplyInput?
    /// Live composers, so a theme change re-tints them.
    var liveComposers: [FleetReplyInput] { [openReplyComposer].compactMap { $0 } }

    /// The needs-decision/blocked set the last `render` produced, so
    /// `FleetController+Reply` can re-lay its rows (open/close a composer)
    /// without a fetch.
    var currentNeedsTasks: [FleetTask] = []

    #if FM_SELFTESTS
    /// Set by `debugRender(snapshot:mergedPRs:)`: from then on only a debug
    /// render reaches `render`, so a fetch started by a page visit cannot
    /// replace a fixture. Stored here because an extension cannot hold one.
    var debugRendersPinned = false
    var debugRenderInProgress = false
    #endif

    // Narrow accessors for the F7 extension - `theme`, `accentRows` and
    // `refresh()` are private to this file, and widening them wholesale would
    // hand the extension more than it needs.
    var currentTheme: HelmTheme { theme }
    /// The needs-your-call rows keep their own list rather than joining
    /// `accentRows`: the two are reconciled by different keyed lists, and each
    /// array is reset from its own list's rows on every pass.
    var needsAccentRows: [HelmAccentRow] = []
    /// P2: the "needs you" list, keyed by task id (`rebuildNeedsRows`).
    lazy var needsRows = HelmKeyedRows(stack: needsStack)
    /// Each row's Reply button, by task id, so a reused row's button can be
    /// flipped between Reply and Cancel in place.
    var needsReplyButtons: [String: HelmButton] = [:]
    func applyThemeFromReply() { applyTheme() }
    /// F7: a reply the captain just sent may have resolved a decision, so
    /// this re-reads for real rather than from the coalescing window.
    func refreshAfterReply() { refresh(forceRefresh: true) }

    /// B-01: the band's turn-over at midnight (`DayRollover`).
    private var dayRolloverToken: NSObjectProtocol?

    deinit {
        if let dayRolloverToken { NotificationCenter.default.removeObserver(dayRolloverToken) }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root
        // Full review 2026-11-25, B-01: the In flight band's kicker names the
        // day, and nothing else redraws it after midnight until the next read.
        dayRolloverToken = DayRollover.observe { [weak self] _, _ in self?.dayDidChange() }

        let header = buildHeader()
        buildStatsRow()
        let loadingSection = buildLoadingState()
        let inFlightSection = buildSection(title: "In flight")
        inFlightSectionView = inFlightSection
        let needsSection = buildNeedsSection()
        needsSectionView = needsSection

        overviewContainer.orientation = .vertical
        overviewContainer.alignment = .leading
        overviewContainer.spacing = HelmMetrics.s4
        overviewContainer.translatesAutoresizingMaskIntoConstraints = false
        // F12 + F6: the briefing is the first thing read on the *Overview*
        // tab, directly under the tab strip rather than under the page header
        // - it is Overview content, so switching to Log takes it with the
        // rest of the dashboard. Hidden until there is a briefing to show,
        // and a hidden *arranged subview* of an `NSStackView` leaves layout
        // entirely (AGENTS.md gotcha (11)), so an off-by-default feature
        // costs this page nothing.
        buildBriefingCard()
        overviewContainer.addArrangedSubview(briefingCard)
        overviewContainer.addArrangedSubview(loadingSection)
        overviewContainer.addArrangedSubview(bannerRow)
        // F7: the "Needs your call" list sits directly under the banner that
        // counts them - the mockup's own grouping - rather than below the
        // stat tiles.
        overviewContainer.addArrangedSubview(needsSection)
        overviewContainer.addArrangedSubview(statsRow)
        overviewContainer.addArrangedSubview(inFlightSection)

        let logSection = buildLogSection()

        scaffold.install(in: root)
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(toolbarRow)
        contentStack.addArrangedSubview(overviewContainer)
        contentStack.addArrangedSubview(logSection)

        // The data sections stay hidden behind the loading skeleton until the
        // first successful `render(...)` - see `buildLoadingState`.
        bannerRow.isHidden = true
        statsRow.isHidden = true
        inFlightSection.isHidden = true
        needsSection.isHidden = true
        briefingCard.isHidden = true
        logSection.isHidden = true

        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            toolbarRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            overviewContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            logSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            briefingCard.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
            loadingSection.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
            bannerRow.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
            inFlightSection.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
            needsSection.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
        ])

        tabs.onSelect = { [weak self] id in
            guard let self, let tab = OverviewTab(rawValue: id) else { return }
            self.switchTab(tab)
        }
        logFilters.onSelect = { [weak self] id in
            guard let self else { return }
            self.logFilterKind = FleetLogListView.kind(forFilterID: id)
            self.renderLog()
        }

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            // Fix 8 (fixes4): this view never forced its appearance to the
            // active Helm theme, so every system-semantic color used below
            // (`.secondaryLabelColor` on PR/task subtitles) resolved against
            // the OS's actual light/dark setting instead - producing
            // near-invisible text whenever that setting disagreed with the
            // chosen Helm theme (e.g. system Light + a dark Helm theme gives
            // light-mode dark text on a dark background).
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    private let scrollMemory = HelmScrollMemory()

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scrollMemory.remember(scroll)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // cockpit-native-fixes5: force the pending Auto Layout pass to run
        // before reading/setting scroll position. On the very first
        // appearance this view's constraints resolve for the first time in
        // the same tick the automatic viewWillAppear fires (isHidden was
        // true, so AppKit had no reason to lay it out earlier) - without this,
        // `scrollToTop()` below could act on stale (pre-layout) geometry. On
        // every later appearance this is a cheap no-op (already resolved).
        view.layoutSubtreeIfNeeded()
        // P3: keep the captain's place unless the page changed (`HelmScrollMemory`).
        scrollMemory.restore(scroll) { scrollToTop() }
        // F12: a briefing already generated today renders immediately from the
        // persisted record - the AI call is not repeated on every visit, and
        // the card does not flicker in behind the fleet fetch.
        showCachedBriefingIfAvailable()
        refresh()
    }

    /// The document view (`content`, a `FlippedView`) puts y=0 at its top,
    /// but a freshly laid-out `NSScrollView` can still leave the clip view's
    /// bounds wherever the last layout pass settled - so force it back
    /// explicitly on every appearance rather than trusting the default.
    /// Mirrors `SettingsController.scrollToTop`.
    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Building the static chrome

    private func buildHeader() -> NSView {
        // UI-63: the greeting is there from the first frame - the time of day
        // needs no fetch, and the captain's name joins it when the snapshot
        // lands. A blank hero line left a 60pt hole above the toolbar for as
        // long as the fleet took to read.
        greetingLabel.stringValue = FleetGreeting.timeOfDay(at: Date())
        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.setScaledFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh fleet data"
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        crewButton.target = self
        crewButton.action = #selector(crewTapped)
        crewButton.toolTip = "Open \(PlaceName.of(.strawHat))"
        crewButton.setContentHuggingPriority(.required, for: .horizontal)
        crewButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        crewButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        headerRow = NSStackView(views: [textStack])
        headerRow.orientation = .horizontal
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // UI-63: the page's controls are one toolbar row - the view switcher
        // leading, the two actions trailing - rather than a switcher alone on
        // its own row and two buttons floating beside the greeting. A plain
        // row on the page ground, not `HelmPageToolbar`: that strip is a
        // filled band for a page that sits directly under the bar with no
        // greeting above it (Console, Tools), and here it would be a second
        // surface between the greeting and the cards.
        let actionsSpacer = NSView()
        actionsSpacer.translatesAutoresizingMaskIntoConstraints = false
        actionsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.toolTip = "Stop this refresh"
        stopButton.isHidden = true
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.setViews([tabs, actionsSpacer, crewButton, stopButton, refreshButton], in: .leading)
        toolbarRow.orientation = .horizontal
        toolbarRow.alignment = .centerY
        toolbarRow.distribution = .fill
        toolbarRow.spacing = HelmMetrics.s3
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12)+(13): the stack-level APIs, both yielding, so this row
        // is never a width floor or ceiling on the window.
        toolbarRow.setHuggingPriority(.defaultLow, for: .horizontal)
        toolbarRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        return headerRow
    }

    /// UI-63: the view switcher and the page's actions, one row.
    private let toolbarRow = NSStackView()

    /// Kept so `loadView` can pin it to the content column's full width -
    /// without that the row shrinks to its content and Refresh stops being at
    /// the page's trailing edge.
    private var headerRow: NSStackView!
    /// R2-UX-05: the sidebar layout's module line, from the last read.
    private var liveSubtitle: String?
    var onDrillSubtitleChanged: (() -> Void)?

    private func buildStatsRow() {
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A skeleton that occupies the content area under the header from the
    /// very first frame - the banner/stats/In flight/Ready to merge sections
    /// stay hidden (and animation-free) until the first `render(...)` lands,
    /// so there is never an interval where the page shows nothing but a
    /// collapsed, empty-looking stack of cards while `refresh()`'s
    /// background fetch (real `gh`/Bitbucket network calls) is in flight.
    private func buildLoadingState() -> NSView {
        // D3: the page arrives in the shape of the content that is coming.
        // UI-63: in the *real* shapes - the banner card, the six stat tiles
        // and the In flight card - rather than one generic list in a box, so
        // nothing moves when the data lands.
        loadingLabel.font = HelmType.caption()
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        bannerSkeletonCard.setBody(HelmSkeletonList(rows: 1), insets: HelmCard.contentInsets)
        let tiles = NSStackView()
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = HelmMetrics.s3
        tiles.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<6 {
            let tile = HelmCard()
            // The pill is a fixed width, so it is pinned on its leading edge
            // only. Pinned edge to edge, six equal tiles tied to the page's
            // width became a required *width* for the whole window - measured,
            // showing Fleet shrank a 1512pt window to 744pt (gotcha (13)).
            let pill = HelmSkeletonRow(shape: .pill)
            pill.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                pill.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
                pill.topAnchor.constraint(equalTo: holder.topAnchor),
                pill.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
            tile.setBody(holder, insets: HelmCard.contentInsets)
            tileSkeletonCards.append(tile)
            tiles.addArrangedSubview(tile)
        }
        listSkeletonCard.setBody(loadingSkeleton, insets: HelmCard.contentInsets)

        loadingTilesRow = tiles
        let stack = NSStackView(views: [loadingLabel, bannerSkeletonCard, tiles, listSkeletonCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [bannerSkeletonCard, tiles, listSkeletonCard] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: loadingContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: loadingContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: loadingContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: loadingContainer.bottomAnchor),
        ])
        return loadingContainer
    }

    private let bannerSkeletonCard = HelmCard()
    private var tileSkeletonCards: [HelmCard] = []
    /// The six tile skeletons' row, which the sidebar layout's band replaces.
    private var loadingTilesRow: NSView?
    private let listSkeletonCard = HelmCard()

    /// The "In flight" section: a plain heading (round glyph + title + count
    /// chip) over the rows, exactly as the prototype's `h2.sect` renders it -
    /// **not** a `HelmCard`.
    ///
    /// The rows below are `HelmAccentRow` cards, each with its own fill and
    /// border, so wrapping them in a second card put a border around a list of
    /// borders and made Overview read as one uniform slab. Review keeps its
    /// cards because those group PRs *by forge*; there is one group here.
    private func buildSection(title: String) -> NSView {
        inFlightHeader.stringValue = title
        inFlightHeader.font = HelmType.sectionTitle()
        inFlightHeader.translatesAutoresizingMaskIntoConstraints = false

        inFlightGlyph.configure(symbol: "clock", tint: .accent, pointSize: 11)
        inFlightGlyph.setContentHuggingPriority(.required, for: .horizontal)

        inFlightCountLabel.font = HelmType.metric(11, weight: .medium)
        inFlightCountLabel.translatesAutoresizingMaskIntoConstraints = false
        inFlightCountChip.wantsLayer = true
        inFlightCountChip.layer?.cornerRadius = 5
        inFlightCountChip.translatesAutoresizingMaskIntoConstraints = false
        inFlightCountChip.addSubview(inFlightCountLabel)
        NSLayoutConstraint.activate([
            inFlightCountLabel.leadingAnchor.constraint(equalTo: inFlightCountChip.leadingAnchor, constant: 6),
            inFlightCountLabel.trailingAnchor.constraint(equalTo: inFlightCountChip.trailingAnchor, constant: -6),
            inFlightCountLabel.topAnchor.constraint(equalTo: inFlightCountChip.topAnchor, constant: 1),
            inFlightCountLabel.bottomAnchor.constraint(equalTo: inFlightCountChip.bottomAnchor, constant: -1),
        ])
        inFlightCountChip.setContentHuggingPriority(.required, for: .horizontal)

        let headingSpacer = NSView()
        headingSpacer.translatesAutoresizingMaskIntoConstraints = false
        headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [inFlightGlyph, inFlightHeader, inFlightCountChip, headingSpacer])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.distribution = .fill
        heading.spacing = HelmMetrics.s2
        heading.translatesAutoresizingMaskIntoConstraints = false

        inFlightStack.orientation = .vertical
        inFlightStack.alignment = .leading
        inFlightStack.spacing = HelmMetrics.s2
        inFlightStack.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [heading, inFlightStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = HelmMetrics.s3
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: section.widthAnchor),
            inFlightStack.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        return section
    }

    // MARK: F6 - the Log tab

    /// The mockup's "Log" tab: the filter-pill row over the event feed.
    /// Deliberately not wrapped in a `HelmCard` - the rows below are
    /// `HelmAccentRow` cards already, the same reason "In flight" above is a
    /// plain heading rather than a card.
    private func buildLogSection() -> NSView {
        logList.translatesAutoresizingMaskIntoConstraints = false

        logContainer.orientation = .vertical
        logContainer.alignment = .leading
        logContainer.spacing = HelmMetrics.s3
        logContainer.translatesAutoresizingMaskIntoConstraints = false
        logContainer.addArrangedSubview(logFilters)
        logContainer.addArrangedSubview(logList)
        NSLayoutConstraint.activate([
            logList.widthAnchor.constraint(equalTo: logContainer.widthAnchor),
        ])
        return logContainer
    }

    /// Show the captain's log.
    ///
    /// A deep link, for a caller that wants the app's activity feed rather
    /// than this page's dashboard - today the Hosts sidebar's TOOLS > Activity
    /// row. Goes through `switchTab` rather than re-deriving anything, so the
    /// pill, the two containers and the feed's own re-render all happen
    /// exactly as they do for a click.
    func showLogTab() {
        guard isViewLoaded else { return }
        switchTab(.log)
    }

    private func switchTab(_ tab: OverviewTab) {
        activeTab = tab
        // Keeps the pill right when the tab was changed from somewhere other
        // than a click; a no-op on a real click, which already moved it.
        tabs.select(tab.rawValue)
        needsYouShowing = false
        needsYouContainer.isHidden = true
        overviewContainer.isHidden = tab != .overview
        logContainer.isHidden = tab != .log
        if tab == .log { renderLog() }
        renderCrewBand()
        applyTheme()
        onModuleTabChanged?()
    }

    /// Re-reads the feed and re-renders it. Called when the Log tab is shown,
    /// on `viewWillAppear` while it is showing, and by Refresh - never on a
    /// timer (F6 adds no polling).
    private func renderLog() {
        let read = FleetLogFeed.read(store: logStore, shift: shiftStore)
        let all = read.events
        let shown = FleetLogFeed.filtered(all, kind: logFilterKind)
        var emptyTitle: String
        var emptyBody: String
        if all.isEmpty {
            emptyTitle = "Nothing logged yet"
            emptyBody = CrewHeroWords.emptyLogBody
        } else {
            emptyTitle = "Nothing here"
            emptyBody = "No \(logFilterKind?.pluralTitle.lowercased() ?? "events") in the recent history."
        }
        logReading = CrewHeroWords.LogReading(read)
        // CR-1, the sidebar layout's band: an empty list under a kind that
        // could not be read is unknown, not "Nothing here" (GL-14).
        if drawsSidebarLayout,
           let unknown = CrewHeroWords.logListUnknown(logReading, kind: logFilterKind, time: CrewBand.time) {
            emptyTitle = unknown.title
            emptyBody = unknown.body
        }
        logList.setRows(FleetLogFeed.rows(for: shown), theme: theme,
                        emptyTitle: emptyTitle, emptyBody: emptyBody)
        guard drawsSidebarLayout else { return }
        // The band is the empty state of a log with nothing in it, and of
        // one that could not be read at all, so the list goes as the board
        // draws it rather than saying the same thing again under it.
        logContainer.isHidden = needsYouShowing || activeTab != .log || logReading.total == 0
        renderCrewBand()
    }

    // MARK: Refresh

    /// The captain's own Refresh click always runs a real sweep - never
    /// answered from `FleetTaskCache`'s coalescing window (3.5).
    @objc private func refreshTapped() { refresh(forceRefresh: true) }

    @objc private func stopTapped() {
        guard isLoading else { return }
        refreshGeneration += 1
        setLoading(false)
        setBriefingBusy(false)
        if let lastRenderedSnapshot {
            render(snapshot: lastRenderedSnapshot, mergedPRs: [], prFetchFailure: Self.stoppedScanSummary)
        }
    }

    private func setLoading(_ loading: Bool) {
        isLoading = loading
        refreshButton.isEnabled = !loading
        refreshButton.isHidden = loading
        stopButton.isHidden = !loading
        onDrillActionsChanged?()
    }

    /// The window toolbar re-reads `drillHeaderActions` when this fires.
    var onDrillActionsChanged: (() -> Void)?

    /// Review #3 §7: navigation, and nothing else - this page holds no
    /// part of the crew's turn cycle and no longer composes for it.
    @objc private func crewTapped() { onOpenCrew?() }

    /// fm/grandline-sidebar-badges: lets `AppShellController` trigger this
    /// page's own existing refresh at app launch, so the rail's Overview
    /// badge has a real count before the captain ever visits this
    /// destination - not a new poll loop, just an earlier call to the one
    /// that already exists (also fired again by every `viewWillAppear` visit
    /// and the manual refresh button, unchanged).
    func refreshIfNeeded() { refresh() }

    private func refresh(forceRefresh: Bool = false) {
        refresh(forceBriefing: false, forceRefresh: forceRefresh)
    }

    // MARK: The shared Claude quota reading

    /// The last `quota-axi` reading, and when it was taken.
    ///
    /// **Why this is cached here rather than fetched per reader.** There are
    /// two readers now - the Morning briefing's `.quota` clause and the Home
    /// canvas's `.claudeStatus` card - and `QuotaSource.fetch()` is a 1-2s
    /// subprocess. This controller refreshes on every `viewWillAppear`, so an
    /// uncached fetch would spawn `quota-axi` on every visit to Overview
    /// (GL-12/GL-13), and two uncoordinated fetches would spawn it twice.
    private var lastQuota: QuotaFetchResult?
    private var lastQuotaAt: Date?

    /// How long a reading is reused before another is taken. A quota window
    /// moves over hours, and the five-hour window's own percentage is the
    /// fastest-moving figure on the card, so minutes of staleness costs the
    /// captain nothing and a fetch per navigation costs a subprocess.
    private static let quotaFreshness: TimeInterval = 5 * 60

    /// Serialises quota work so two overlapping refreshes cannot both fetch.
    ///
    /// GL-03's latch problem is avoided rather than guarded: there is no
    /// boolean to wedge. A second call queued behind a first simply finds the
    /// reading fresh and returns it, and `Subprocess`'s own bound (GL-02)
    /// means a hung `quota-axi` cannot hold the queue indefinitely.
    private static let quotaQueue = DispatchQueue(label: "com.manjesh.grandline.quota")

    /// The Home canvas's Claude card Refresh: take a reading now, whatever the
    /// cached one's age.
    ///
    /// The freshness window exists so a *navigation* does not spawn
    /// `quota-axi` (GL-12/GL-13); a captain pressing Refresh on the card is
    /// the opposite case, and skipping the fetch because a four-minute-old
    /// reading is on file is exactly the stale first paint that made the card
    /// look wrong. Publishes through `onQuotaChanged` like every other
    /// reading, so the card clears its own in-flight state on failure too.
    func refreshQuotaNow() { refreshQuota(force: true) }

    /// Takes a reading if the cached one has aged out, then publishes it.
    ///
    /// **This is why the card works at all when the briefing does not.** The
    /// briefing fetches quota only when it actually generates - which is once
    /// a day, and only when Morning briefing is enabled (it is off by
    /// default). Riding that pass alone left the status card showing its
    /// loading skeleton forever on a machine with the briefing off, and on
    /// every launch after the day's first briefing. The reading is this
    /// controller's now, and the briefing is one of its two readers.
    private func refreshQuota(force: Bool = false) {
        if !force, let taken = lastQuotaAt, let cached = lastQuota,
           Date().timeIntervalSince(taken) < Self.quotaFreshness {
            onQuotaChanged?(cached)
            return
        }
        Self.quotaQueue.async { [weak self] in
            let result = MorningBriefing.fetchQuota()
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastQuota = result
                self.lastQuotaAt = Date()
                // Published on failure too, or the card keeps its skeleton
                // where it should be stating the gap (GL-14).
                self.onQuotaChanged?(result)
            }
        }
    }

    /// `forceBriefing` is the briefing card's own clock affordance: regenerate
    /// from a fresh scan rather than waiting for tomorrow's first activation.
    ///
    /// `forceRefresh` bypasses `FleetTaskCache`'s coalescing window (3.5) -
    /// set for the captain's own Refresh click and the post-reply re-read,
    /// left `false` for an ordinary automatic refresh (a page visit), which is
    /// exactly the case the window exists to collapse.
    private func refresh(forceBriefing: Bool, forceRefresh: Bool = false) {
        // F6: the log is a cheap local read (a JSONL file plus a bounded
        // window of Shift's activity YAML), so Refresh re-reads it too rather
        // than the Log tab having a refresh action of its own.
        if activeTab == .log { renderLog() }
        guard !isLoading else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        setLoading(true)
        if forceBriefing { setBriefingBusy(true) }
        // snapshot() (~0.5s: task/backlog counts, watcher health) and
        // OpenPRsSource.fetch() (the slow, network-bound per-clone PR scan)
        // are independent - render the fast fields the moment snapshot()
        // finishes instead of blocking that on the PR fetch too, then
        // re-render once the PR list itself lands. The "Ready to merge"
        // stat tile and the banner show their scanning state in between
        // (REL-25 - they used to show "0 ready to merge").
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = FleetDataSource.snapshot(forceRefresh: forceRefresh)
            DispatchQueue.main.async {
                // R4-UX-08: a stopped pass reports nothing.
                guard let self, self.refreshGeneration == generation else { return }
                self.render(snapshot: snapshot, mergedPRs: nil)
            }
            // P11: one scan shared with Review (`OpenPRsSource.fetchShared`).
            let fetched = OpenPRsSource.fetchShared(forceRefresh: forceRefresh)
            let merged = FleetDataSource.mergedPRs(openPRs: fetched.prs, tasks: snapshot.tasks)
            DispatchQueue.main.async {
                guard let self, self.refreshGeneration == generation else { return }
                self.setLoading(false)
                self.render(snapshot: snapshot, mergedPRs: merged, prFetchFailure: fetched.failureSummary)
                // F12: only from here, never from the first (PR-less) render -
                // a briefing built while the PR scan is still in flight would
                // report "0 PRs ready" as a fact.
                // Independent of the briefing's own once-a-day gate and of
                // whether it is enabled at all - see `refreshQuota`.
                self.refreshQuota()
                self.considerMorningBriefing(snapshot: snapshot,
                                             prReadyCount: fetched.failureSummary == nil
                                                 ? FleetDataSource.readyToMergeCount(merged) : nil,
                                             force: forceBriefing)
            }
        }
    }

    // MARK: Rendering

    /// `mergedPRs == nil` means the (slow) PR fetch hasn't finished yet -
    /// every other field from `snapshot` still renders immediately, and the
    /// "ready to merge" tile and the banner say they are still scanning
    /// until this method is called again once the fetch completes (REL-25:
    /// they used to render that as a confident 0).
    /// `prFetchFailure` (GL-14) is a short reason string when the PR scan did
    /// not fully succeed. Overview's "ready to merge" tile is a
    /// should-I-act-on-something instrument, so a failed scan must read as
    /// "unknown", not as a confident `0`.
    /// GL-P3: `render` runs on every Overview refresh, and building a
    /// localized weekday formatter per render is pure allocation.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    // Not `private` only so this family's debug surface in
    // `FleetController+Reply.swift` can reach it (GL-36: treat it as private).
    func render(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?, prFetchFailure: String? = nil) {
        #if FM_SELFTESTS
        // `ReviewTourLab`'s `demo decision`: a live refresh landing after the
        // fixture would replace it, so only the debug render gets through.
        if debugRendersPinned && !debugRenderInProgress { return }
        #endif
        lastRenderedSnapshot = snapshot
        if !hasLoadedOnce {
            hasLoadedOnce = true
            loadingContainer.isHidden = true
            // CR-1: the sidebar layout's band says what these two said.
            bannerRow.isHidden = drawsSidebarLayout
            statsRow.isHidden = drawsSidebarLayout
            inFlightSectionView.isHidden = false
        }

        let working = snapshot.tasks.filter { $0.status == "working" }
        let needs = snapshot.tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }
        onNeedsDecisionCountChanged?(needs.count)

        // Daylight §5.4: one definition of the greeting, shared with the home
        // canvas - see `FleetGreeting`'s own header for why that matters.
        greetingLabel.stringValue = FleetGreeting.greeting(captain: snapshot.captain)
        subtitleLabel.stringValue = snapshot.homeOk
            ? "\(Self.weekdayFormatter.string(from: Date())) \u{00B7} the fleet is yours"
            : "Setup isn't finished yet"
        // R2-UX-05: in the sidebar layout the greeting is gone and what it
        // said about the fleet is the module's live line.
        liveSubtitle = snapshot.homeOk
            ? "\(working.count) working \u{00B7} \(needs.count) waiting on you \u{00B7} \(snapshot.queuedCount) queued \u{00B7} \(snapshot.doneCount) done today"
            : "Setup isn't finished yet"
        onDrillSubtitleChanged?()

        // One definition of "ready to merge" for the banner and the tile
        // alike - see `FleetDataSource.readyToMerge`. Both used to render the
        // raw *open* count under that label, which is how this page could say
        // "50 PRs ready to merge" while the merge-queue card one click away
        // said "none ready" off the identical array.
        let ready = FleetDataSource.PRReadyReading(mergedPRs: mergedPRs, failure: prFetchFailure)
        renderBanner(needs: needs, working: working, ready: ready, homeOk: snapshot.homeOk)
        rebuildStats(working: working.count, ready: ready, snapshot: snapshot)
        noteInFlightRead(snapshot, needs: needs, working: working, ready: ready)
        // Needs you keeps a task it cannot read this time (see
        // `noteNeedsYouRead`). The floating bar lists this read as it is. The
        // bookkeeping runs in both layouts, because the sidebar layout's
        // Crew badge reads it before Crew is ever opened; only
        // the sidebar layout lists its result.
        let carried = noteNeedsYouRead(snapshot, needs: needs)
        needsYouListedCount = carried.count
        currentNeedsTasks = drawsSidebarLayout ? carried : needs
        rebuildNeedsRows(currentNeedsTasks)
        if drawsSidebarLayout { renderNeedsYou(currentNeedsTasks) }
        rebuildTaskRows(into: inFlightStack, tasks: working, emptyTitle: "All hands idle", emptyBody: "No crew are working right now. Send your first mate a task from the console and this board lights up.")
        inFlightHeader.stringValue = "In flight"
        inFlightCountLabel.stringValue = "\(working.count)"
        renderCrewBand()

        applyTheme()
        onSnapshotChanged?(snapshot, mergedPRs, prFetchFailure)

        // cockpit-native-fixes5: the loading skeleton's content is much
        // shorter than the real data (header + spinner only), so the first
        // successful render() here can grow the document's height by several
        // hundred points while the view is already visible - nothing else
        // re-pins the scroll position after that resize. Re-run scrollToTop()
        // defensively so a first-appearance visit that's still showing the
        // skeleton when this lands can't end up scrolled anywhere but the top
        // once the real content replaces it.
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    /// The answer banner, as the shared `HelmAccentRow`.
    ///
    /// Daylight §5.4 moved the *decision* half of this - which of the three
    /// states applies, and the exact copy for each - into `FleetGreeting.answer`
    /// so the home canvas's one-line summary is the same computation rather
    /// than a second one that could drift. This method is now purely the
    /// rendering half: values in, one `HelmAccentRow.Content` out.
    private func renderBanner(needs: [FleetTask], working: [FleetTask],
                              ready: FleetDataSource.PRReadyReading, homeOk: Bool = true) {
        let answer = FleetGreeting.answer(tasks: needs + working, prs: ready, homeOk: homeOk)
        bannerRow.configure(HelmNotice.Content(
            tint: answer.tint,
            symbol: answer.badgeSymbol,
            kicker: answer.kicker,
            title: answer.title,
            body: answer.meta), theme: theme)
        // GL-31: only the not-configured answer has an action, and it leads
        // straight into the Bootstrap stepper where firstmate home is set.
        bannerRow.setActions(answer.isSetupPrompt ? [openSetupButton] : [])
    }

    @objc private func openSetupTapped() { onNavigateToSetup?() }

    /// The "ready to merge" tile for each state of the reading. GL-14: an em
    /// dash, never "0", whenever the number is not known - while the scan is
    /// running (REL-25) as well as when it failed. The tile stays clickable
    /// in every state so the captain can go to Review and see why.
    private static func readyTile(_ ready: FleetDataSource.PRReadyReading) -> StatTileItem {
        switch ready {
        case .value(let count):
            return StatTileItem(key: "ready", value: "\(count)",
                                label: "ready to merge", tint: .accent, opensReview: true)
        case .scanning:
            return StatTileItem(key: "ready", value: "\u{2014}",
                                label: "scanning PRs", opensReview: true)
        case .failed:
            return StatTileItem(key: "ready", value: "\u{2014}",
                                label: "PRs unavailable", tint: .warn, opensReview: true)
        }
    }

    private func rebuildStats(working: Int, ready: FleetDataSource.PRReadyReading, snapshot: FleetSnapshot) {
        let watcherLabel: String
        switch snapshot.watcher.status {
        case "healthy": watcherLabel = "watcher healthy"
        case "stale": watcherLabel = "watcher stale"
        default: watcherLabel = "watcher off"
        }

        // Tinted by meaning, not uniformly ink - the prototype's own stat row.
        // A tint only ever means "this number is itself a signal": ready-to-
        // merge is the one actionable count and the only clickable tile, done-
        // today is a good outcome, and the watcher's own health decides its
        // own colour. Working / queued / projects stay plain, because a
        // coloured number there would be colour with nothing to say.
        // `HelmStatTile` runs every tint through `HelmContrast` (§5.7), so
        // none of these is the raw hue as text.
        let watcherTint: HelmTint
        switch snapshot.watcher.status {
        case "healthy": watcherTint = .good
        case "stale": watcherTint = .warn
        default: watcherTint = .neutral
        }
        let items: [StatTileItem] = [
            StatTileItem(key: "working", value: "\(working)", label: "working"),
            Self.readyTile(ready),
            StatTileItem(key: "queued", value: "\(snapshot.queuedCount)", label: "queued"),
            StatTileItem(key: "done", value: "\(snapshot.doneCount)", label: "done today", tint: .good),
            StatTileItem(key: "projects", value: "\(snapshot.projectsCount)", label: "projects"),
            StatTileItem(key: "watcher",
                         value: snapshot.watcher.status == "healthy" ? "OK" : "\u{2014}",
                         label: watcherLabel, tint: watcherTint),
        ]
        // P2: the six cells are built once and updated in place on every
        // refresh (`HelmKPIStrip` reuses its cells while the count holds).
        statItems = items
        statsRow.configure(items.map { item in
            let known = item.value != "\u{2014}"
            // S14's tint rule: colour only when the state is not the default.
            let signals = known && item.value != "0" && item.tint != nil && item.tint != .neutral
            // A boxed caption sits above its figure, so it reads as a heading:
            // sentence case, like every other summary row.
            let caption = item.label.prefix(1).uppercased() + item.label.dropFirst()
            return HelmKPIStrip.Item(known ? .value(item.value) : .unread, caption: caption,
                                     emphasis: signals ? .tinted(item.tint ?? .neutral) : .normal,
                                     isAction: item.opensReview,
                                     toolTip: item.opensReview ? "View in \(PlaceName.short(.review))" : nil)
        }, theme: theme)
    }

    private struct StatTileItem {
        let key: String
        let value: String
        let label: String
        var tint: HelmTint? = nil
        var opensReview = false
    }

    private lazy var inFlightRows = HelmKeyedRows(stack: inFlightStack)

    private func rebuildTaskRows(into stack: NSStackView, tasks: [FleetTask], emptyTitle: String, emptyBody: String) {
        // P2: keyed by task id - a task still in flight keeps its row and is
        // updated in place; only a task that started builds one, and only one
        // that stopped loses it (`HelmKeyedRows`).
        inFlightRows.reconcile(tasks, key: \.id, make: { _ in
            HelmAccentRow(hover: false)
        }, update: { [weak self] view, task in
            guard let self, let row = view as? HelmAccentRow else { return }
            self.configureTaskRow(row, task)
        }, placeholder: { [weak self] in
            self?.emptyStateView(icon: "tray", title: emptyTitle, body: emptyBody) ?? NSView()
        })
        accentRows = inFlightRows.orderedRows.compactMap { $0 as? HelmAccentRow }
    }

    /// One `HelmEmptyState` - the app's shared empty state
    /// (`HelmDesignSystem.swift`, audit §6.3 component 5). `boxed: true` because
    /// this page's list sits directly on the page background with no card around
    /// it, so the empty state needs a container of its own to read as an object;
    /// that container is now `HelmCard`'s own fill and border rather than this
    /// page's third border alpha (§4.2 measured two on one page).
    private func emptyStateView(icon: String, title: String, body: String) -> NSView {
        let empty = HelmEmptyState(symbol: icon, title: title, body: body, size: .standard, boxed: true)
        emptyStates.append(empty)
        return empty
    }

    /// Each empty state is built once (a list's placeholder) and themes
    /// itself; this only exists to reach the live ones from `applyTheme`.
    private var emptyStates: [HelmEmptyState] = []

    /// One "In flight" row, built from the app's shared `HelmAccentRow`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 2). The audit (§4.2)
    /// found this row already had the badge and the status pill but neither
    /// the accent bar nor the kicker, so it read as almost - but not quite -
    /// the same object as a notification card or a Shift task; converging it
    /// was called "nearly free". The tint, glyph and pill text still come
    /// from `taskVisuals` below, i.e. from the crew state, unchanged.
    ///
    /// `hover: false` and no `onClick`: these rows are a read-only readout,
    /// exactly as before this migration.
    private func configureTaskRow(_ row: HelmAccentRow, _ task: FleetTask) {
        let visuals = taskVisuals(task)
        let detail = task.detail.isEmpty ? "source: \(task.source)" : task.detail
        row.configure(HelmAccentRow.Content(
            tint: visuals.tint,
            // The repo is this row's "which thing is this about" line, the
            // same job the project name does on a Shift task row.
            kicker: task.repo ?? task.kind,
            title: task.id,
            meta: detail,
            badgeSymbol: visuals.symbol,
            chipText: visuals.label
        ), theme: theme)
    }

    /// Live `HelmAccentRow`s, so a theme change re-tints them. Kept in step
    /// with `inFlightRows` on every render.
    private var accentRows: [HelmAccentRow] = []

    /// Returns a `HelmTint` rather than a raw hex: the row's accent bar,
    /// badge and chip are all resolved from it by `HelmAccentRow`, and the
    /// chip in particular now goes through `ToolRowLayout.pill`'s
    /// contrast-corrected path (audit §5.7) instead of this file's own
    /// hue-on-a-wash-of-itself pill, which was another instance of that bug.
    private func taskVisuals(_ task: FleetTask) -> (symbol: String, tint: HelmTint, label: String) {
        switch task.status {
        case "needs_decision": return ("exclamationmark.triangle.fill", .warn, "needs you")
        case "blocked": return ("xmark.octagon.fill", .critical, "blocked")
        case "failed": return ("xmark.octagon.fill", .critical, "failed")
        case "done": return ("checkmark.circle.fill", .good, "done")
        case "working": return ("clock.fill", .accent, "working")
        default: return ("circle.dashed", .neutral, "idle")
        }
    }

    // MARK: Actions

    // MARK: F12 - the morning briefing

    private func buildBriefingCard() {
        briefingCard.onRefresh = { [weak self] in self?.refresh(forceBriefing: true) }
        briefingCard.onDismiss = { [weak self] in self?.dismissBriefing() }
        briefingCard.onActivate = { [weak self] target in self?.activateBriefingClause(target) }
    }

    /// Renders a briefing already generated today, straight from the persisted
    /// record - no fetch, no AI call. Called on every appearance, so navigating
    /// away and back does not re-run anything.
    private func showCachedBriefingIfAvailable() {
        guard AppSettings.shared.morningBriefingEnabled,
              let record = AppSettings.shared.morningBriefingRecord,
              record.day == MorningBriefing.dayKey(),
              !record.dismissed else {
            hideBriefing()
            return
        }
        show(record)
    }

    /// The once-per-day gate. `force` is the clock affordance, which ignores
    /// both the day check and a dismissal.
    private func considerMorningBriefing(snapshot: FleetSnapshot, prReadyCount: Int?, force: Bool) {
        guard AppSettings.shared.morningBriefingEnabled else {
            // Off by default, and off means nothing happens: no inputs are
            // read, no quota fetch, no `claude` call.
            hideBriefing()
            setBriefingBusy(false)
            return
        }
        if !force, let record = AppSettings.shared.morningBriefingRecord,
           record.day == MorningBriefing.dayKey() {
            // Already briefed today - render it (or stay hidden if the captain
            // dismissed it) rather than spending a second `claude` call.
            if record.dismissed { hideBriefing() } else { show(record) }
            return
        }
        guard !isGeneratingBriefing else { return }
        generateBriefing(snapshot: snapshot, prReadyCount: prReadyCount)
    }

    private func generateBriefing(snapshot: FleetSnapshot, prReadyCount: Int?) {
        isGeneratingBriefing = true
        setBriefingCardShown(true)
        setBriefingBusy(true)

        var inputs = BriefingInputs()
        inputs.homeOk = snapshot.homeOk
        inputs.workingCount = snapshot.tasks.filter { $0.status == "working" }.count
        inputs.needsDecisionCount = snapshot.tasks.filter { $0.status == "needs_decision" }.count
        inputs.blockedCount = snapshot.tasks.filter { $0.status == "blocked" }.count
        inputs.doneTodayCount = snapshot.doneCount
        inputs.queuedCount = snapshot.queuedCount
        inputs.watcherStatus = snapshot.watcher.status
        inputs.prReadyCount = prReadyCount

        // Main thread on purpose: `ShiftStore` is not thread-safe, and this is
        // a cheap scan of arrays it already has in memory.
        let due = MorningBriefing.shiftDue(store: shiftStore)
        inputs.dueTaskCount = due.tasks
        inputs.dueFollowUpCount = due.followUps
        inputs.singleDueTaskID = due.singleTaskID

        // Read, not recomputed - see `BackgroundSignalsPoller.lastCounts`.
        let counts = BackgroundSignalsPoller.shared.lastCounts
        // Every fork upstream is ahead of, a diverged one included - the same
        // number Setup's and Home's GitHub sync cards state.
        inputs.forkDriftCount = counts.forksToSync
        inputs.toolUpdateCount = counts.toolUpdates
        inputs.toolsWithUpdateCount = counts.toolsWithUpdate
        inputs.setupDriftCount = counts.setupDrift

        // No quota read here any more: the briefing's Claude-quota clause was
        // removed when the Home canvas's Claude card took that reading over
        // (see `MorningBriefingData.swift`'s header). `refreshQuota` still
        // runs on every refresh pass for that card - this path simply stopped
        // being one of its readers, which also means the briefing no longer
        // waits on a 1-2s subprocess before it can be composed.
        finishBriefing(inputs: inputs)
    }

    /// The local/AI split, at the one point it matters: the local clause list
    /// is built first and is what ships whenever the AI half cannot answer.
    private func finishBriefing(inputs: BriefingInputs) {
        let localClauses = MorningBriefingLocal.clauses(from: inputs)
        func commit(_ clauses: [BriefingClause], headline: String? = nil, degradedReason: String?) {
            let record = MorningBriefing.record(inputs: inputs, clauses: clauses, headline: headline,
                                                isDegraded: degradedReason != nil,
                                                degradedReason: degradedReason)
            AppSettings.shared.morningBriefingRecord = record
            self.isGeneratingBriefing = false
            self.setBriefingBusy(false)
            self.show(record)
        }

        guard MorningBriefingAI.isAvailable else {
            commit(localClauses, degradedReason: "claude isn\u{2019}t installed or on PATH")
            return
        }
        MorningBriefingAI.generate(inputs: inputs) { result in
            switch result {
            case .success(let reply):
                commit(reply.clauses, headline: reply.headline, degradedReason: nil)
            case .failure(let error):
                // Never fatal: the deterministic clauses are already built.
                AppLog.ai.info("morning briefing fell back to the local summary: \(error.message, privacy: .public)")
                commit(localClauses, degradedReason: error.message)
            }
        }
    }

    private func show(_ record: MorningBriefingRecord) {
        briefingCard.render(record, theme: theme)
        setBriefingCardShown(true)
        bandBriefing = record
        renderCrewBand()
    }

    /// CR-1: the card is the floating bar's. In the sidebar layout the
    /// briefing is the band's line and tiles, and the card stays hidden.
    private func setBriefingCardShown(_ shown: Bool) {
        briefingCard.isHidden = !shown || drawsSidebarLayout
    }

    private func hideBriefing() {
        setBriefingCardShown(false)
        bandBriefing = nil
        renderCrewBand()
    }

    /// A briefing being composed: the card's busy row, and the band's line
    /// saying so with Regenerate off, over the tiles it already has.
    private func setBriefingBusy(_ busy: Bool) {
        briefingCard.setBusy(busy)
        bandBriefingBusy = busy
        renderCrewBand()
    }

    private func dismissBriefing() {
        hideBriefing()
        setBriefingBusy(false)
        guard var record = AppSettings.shared.morningBriefingRecord else { return }
        record.dismissed = true
        AppSettings.shared.morningBriefingRecord = record
    }

    /// The deep links. Every branch is a real destination - `.none` clauses are
    /// never rendered as links in the first place, so there is no case here
    /// that silently does nothing.
    private func activateBriefingClause(_ target: BriefingTarget, anchor: NSView? = nil) {
        switch target {
        case .none:
            break
        case .review:
            onNavigateToReview?()
        case .tasks:
            if let id = AppSettings.shared.morningBriefingRecord?.shiftTaskID {
                onOpenShiftTask?(id)
            } else {
                onNavigateToDestination?(.shift)
            }
        case .githubSync:
            onNavigateToDestination?(.githubSync)
        case .updates:
            onNavigateToDestination?(.updates)
        case .setup:
            onNavigateToSetup?()
        case .quota:
            quotaUsage.toggle(relativeTo: anchor ?? briefingCard.quotaAnchor)
        case .fleet:
            // The tasks this clause is about are rows on this very page.
            if let section = inFlightSectionView { section.scrollToVisible(section.bounds) }
        }
    }

    // MARK: Theme

    private func applyTheme() {
        applyNeedsYouTheme()
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        // Fix 8 (fixes4): every "muted" text style below now routes through
        // `HelmTheme.mutedInk`, not its own ad hoc alpha - `0.55`/`0.6` looked
        // fine in the dark palettes but measured below WCAG AA (as low as
        // 3.33:1) in all four light ones. See `mutedInk`'s doc comment for
        // the measured numbers.
        let muted = HelmTheme.mutedInk(theme)
        greetingLabel.textColor = ink
        subtitleLabel.textColor = muted
        // `refreshButton` is a `HelmButton` and themes itself - never set
        // `contentTintColor` on one, `restyle()` owns that property.

        loadingLabel.textColor = muted
        loadingSkeleton.applyTheme(theme)
        for card in [bannerSkeletonCard, listSkeletonCard] + tileSkeletonCards { card.applyTheme(theme) }

        bannerRow.applyTheme(theme)
        briefingCard.applyTheme(theme)
        inFlightHeader.textColor = ink
        inFlightGlyph.applyTheme(theme)
        inFlightCountChip.layer?.backgroundColor = ink.withAlphaComponent(0.08).cgColor
        inFlightCountLabel.textColor = muted

        // F7
        needsHeaderLabel.textColor = ink
        needsGlyph.applyTheme(theme)
        needsCountChip.layer?.backgroundColor = ink.withAlphaComponent(0.08).cgColor
        needsCountLabel.textColor = muted
        for row in needsAccentRows { row.applyTheme(theme) }
        for composer in liveComposers { composer.applyTheme(theme) }

        // Both tab strips theme themselves at init and on `select`, but not
        // on a live theme change - every page owning a `HelmSegmentedTabs`
        // re-hands it the theme from its own `applyTheme`.
        tabs.applyTheme(theme)
        logFilters.applyTheme(theme)
        logList.applyTheme(theme)

        statsRow.applyTheme(theme)
        for empty in emptyStates { empty.applyTheme(theme) }
        // Each row owns its own tint-derived chrome; it only needs the new
        // theme handed to it.
        for row in accentRows { row.applyTheme(theme) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Switch tabs through the exact method a real pill click reaches -
    /// `switchTab` and `OverviewTab` are both `private` to this file.
    func debugSwitchTab(_ id: String) {
        guard let tab = OverviewTab(rawValue: id) else { return }
        switchTab(tab)
    }

    /// Every tab id the strip offers, in order - so a suite can assert which
    /// tabs exist at all rather than only that selecting one works. The
    /// captain's own correction removed a third ("Crew"); this is what makes
    /// re-adding it a deliberate act.
    var debugTabIDs: [String] { OverviewTab.allCases.map { $0.rawValue } }

    var debugActiveTabID: String { activeTab.rawValue }
    var debugTabsAreHidden: Bool { tabs.isHidden }
    /// Review #3 §7's header action - the dashboard's one way to the crew,
    /// now that the composer that used to be here is gone.
    var debugCrewButton: HelmButton { crewButton }

    /// Every tab's user-facing label, so a naming check can assert what this
    /// page actually calls its own tabs rather than what a comment says.
    ///
    /// `static`, because `OverviewTab` is file-private and the labels are a
    /// property of the type - which lets the naming guard read them without
    /// building a controller (and therefore without a store or a window),
    /// keeping that guard in CI's blocking lane.
    static var debugTabTitles: [String] { OverviewTab.allCases.map { $0.title } }

    /// Drive the real `render` with caller-supplied data, bypassing
    /// `refresh()`'s background fetch and its real `gh`/`git` calls.
    func debugRender(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?, prFetchFailure: String? = nil) {
        // Gets through a pinned page too (`debugRendersPinned`), so a suite
        // that seeded a fixture can still render a failed scan over it.
        let wasInProgress = debugRenderInProgress
        debugRenderInProgress = true
        render(snapshot: snapshot, mergedPRs: mergedPRs, prFetchFailure: prFetchFailure)
        debugRenderInProgress = wasInProgress
    }

    /// R4-UX-08: the toolbar's Stop, and the in-flight state it ends. A
    /// suite marks a pass in flight without starting the real fetch.
    var debugStopButton: HelmButton { stopButton }
    var debugRefreshButton: HelmButton { refreshButton }
    var debugIsLoading: Bool { isLoading }
    func debugBeginPassWithoutFetching() {
        refreshGeneration += 1
        setLoading(true)
    }

    /// The answer banner's own body line, as rendered - this is where
    /// "N PRs ready to merge" is actually spoken to the captain.
    var debugBannerMeta: String { bannerRow.debugBody }
    var debugBannerNotice: HelmNotice { bannerRow }

    /// Every stat tile as rendered. See `ReviewController.debugStatTiles`.
    var debugStatTiles: [(value: String, caption: String)] {
        statsRow.debugCells.map { ($0.debugValue, $0.debugCaption) }
    }

    /// The live views themselves, for `KeyedRefreshSelfTest` - which asks
    /// whether a refresh kept the same objects rather than what they say.
    var debugStatTileViews: [NSView] { statsRow.debugCells }
    var debugInFlightRowViews: [NSView] { inFlightStack.arrangedSubviews }
    var debugNeedsRowViews: [NSView] { needsStack.arrangedSubviews }
    #endif
}

// MARK: - Crew's In flight and Log in the sidebar layout

extension FleetController: ModuleTabHosting {
    /// Needs you is Crew's first tab in the sidebar layout only.
    var moduleTabNames: [String] { drawsSidebarLayout ? ["Needs you", "In flight", "Log"] : ["In flight", "Log"] }

    var selectedModuleTabName: String {
        if needsYouShowing { return "Needs you" }
        return activeTab == .log ? "Log" : "In flight"
    }

    func selectModuleTab(named name: String) {
        guard isViewLoaded else { return }
        if name == "Needs you", drawsSidebarLayout {
            showNeedsYou()
            return
        }
        switchTab(name == "Log" ? .log : .overview)
    }

    func setModuleTabControlHidden(_ hidden: Bool) { tabs.isHidden = hidden }
}

// MARK: - Crew › Needs you

// The prototype's Crew › Needs you: one list of everything waiting on the
// captain. It is built only from what this page already holds - the parked
// tasks its own refresh found (`needs_decision` and `blocked`), each with the
// still-open decisions its status file records (`FleetActions.openDecisions`)
// - and it answers them with the same rows and the same Reply composer the
// floating bar's dashboard uses. Nothing is fetched for it and nothing is
// made up: a task with no decision note shows the crew's own detail line.
//
// In the sidebar layout the list moves here from In flight, so it is in one
// place; the dashboard's banner still counts it. The floating bar keeps the
// list on its dashboard, unchanged.

extension FleetController: SidebarLayoutAdopting {

    func adoptSidebarLayout() {
        guard !drawsSidebarLayout else { return }
        _ = view
        drawsSidebarLayout = true
        // R2-UX-05: the greeting was a fourth name for this place, under the
        // crumb, the sidebar row and the module header. Its live half is the
        // header's subtitle now (`drillHeaderSubtitle`).
        headerRow.isHidden = true
        // R2-UX-04: its two buttons are the toolbar's now, and its tabs were
        // already the toolbar's (`ModuleTabHosting`), so the row is empty.
        toolbarRow.isHidden = true

        needsYouSetupButton.target = self
        needsYouSetupButton.action = #selector(needsYouSetupTapped)
        needsYouSkeleton.setBody(needsYouSkeletonRows, insets: HelmCard.contentInsets)
        needsYouSkeleton.translatesAutoresizingMaskIntoConstraints = false

        needsYouContainer.orientation = .vertical
        needsYouContainer.alignment = .leading
        needsYouContainer.spacing = HelmMetrics.s4
        needsYouContainer.translatesAutoresizingMaskIntoConstraints = false
        // The Needs your call section leaves the dashboard for this tab. CR-1:
        // the band counts it, so its heading goes and the rows sit straight
        // under the band, as the board draws them.
        overviewContainer.removeArrangedSubview(needsSectionView)
        needsSectionView.removeFromSuperview()
        needsGlyph.superview?.isHidden = true
        for view in [needsYouSkeleton, needsSectionView!] as [NSView] {
            needsYouContainer.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: needsYouContainer.widthAnchor).isActive = true
        }
        contentStack.addArrangedSubview(needsYouContainer)
        needsYouContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        needsYouContainer.isHidden = true
        adoptCrewBand()
        renderNeedsYou(currentNeedsTasks)
        applyNeedsYouTheme()
    }

    /// Show Needs you, by any route: the toolbar tab, the bell's decision
    /// entry, or Home's attention row.
    private func showNeedsYou() {
        needsYouShowing = true
        overviewContainer.isHidden = true
        logContainer.isHidden = true
        needsYouContainer.isHidden = false
        renderCrewBand()
        applyTheme()
        onModuleTabChanged?()
    }

    /// Land on Needs you when the sidebar layout draws it. The floating bar
    /// has no such tab, so there this does nothing and the dashboard - where
    /// its list is - stays.
    func revealNeedsYou() {
        guard isViewLoaded, drawsSidebarLayout else { return }
        showNeedsYou()
    }

    @objc private func needsYouSetupTapped() { onNavigateToSetup?() }

    /// Needs you's own reading of the crew, for the sidebar layout's Crew
    /// badge: the same count Needs you lists, and the same
    /// honest states its summary states. Read after `onSnapshotChanged`,
    /// which every read fires.
    var needsYouReading: FleetNeedsYouReading {
        FleetNeedsYouReading(hasRead: hasLoadedOnce && needsYouCheckedAt != nil, homeOk: needsYouHomeOk,
                             waiting: needsYouListedCount, readAt: needsYouReadAt,
                             checkedAt: needsYouCheckedAt, readFailed: needsYouReadFailed)
    }

    /// Fold one read into Needs you and return what it lists: this read's
    /// tasks waiting on the captain, plus any task it could not read that
    /// was last read as waiting. When the task list itself could not be
    /// read, everything known stays. A failed read keeps the last good value
    /// and says when it was read (GL-14) - it never empties the list.
    private func noteNeedsYouRead(_ snapshot: FleetSnapshot, needs: [FleetTask]) -> [FleetTask] {
        let now = Date()
        needsYouCheckedAt = now
        needsYouHomeOk = snapshot.homeOk
        guard snapshot.homeOk else {
            needsYouReadFailed = false
            needsYouKnown = [:]
            return []
        }
        guard snapshot.tasksRead else {
            needsYouReadFailed = true
            return needsYouKnown.values.map(\.task).sorted { $0.id < $1.id }
        }
        needsYouReadFailed = false
        needsYouReadAt = now
        let unread = Set(snapshot.tasks.filter { $0.status == "unknown" }.map(\.id))
        needsYouKnown = needsYouKnown.filter { unread.contains($0.key) }
        for task in needs { needsYouKnown[task.id] = (task, now) }
        return snapshot.tasks.compactMap { needsYouKnown[$0.id]?.task }
    }

    /// The skeleton, from the same read the rows were just built from. The
    /// band itself is drawn by `renderCrewBand()`, which `render` and the tab
    /// switches call: before the first read lands it says it is reading over
    /// these two skeleton rows - never "nothing needs you" for a state it has
    /// not seen, and never after a read that failed.
    fileprivate func renderNeedsYou(_ shown: [FleetTask]) {
        guard drawsSidebarLayout else { return }
        needsYouSkeleton.isHidden = hasLoadedOnce && needsYouCheckedAt != nil
    }

    /// Needs you's reading as `CrewHeroWords` counts it: the listed tasks,
    /// their open decisions, and any carried from an earlier read.
    fileprivate func needsYouWordsReading() -> CrewHeroWords.NeedsYouReading {
        let shown = currentNeedsTasks
        var reading = CrewHeroWords.NeedsYouReading(
            hasRead: hasLoadedOnce && needsYouCheckedAt != nil, homeOk: needsYouHomeOk,
            readFailed: needsYouReadFailed, checkedAt: needsYouCheckedAt, readAt: needsYouReadAt,
            waiting: shown.count,
            openDecisions: shown.reduce(0) { $0 + FleetActions.openDecisions(taskID: $1.id).count },
            needDecision: shown.filter { $0.status == "needs_decision" }.count,
            blocked: shown.filter { $0.status == "blocked" }.count)
        if !needsYouReadFailed, let checkedAt = needsYouCheckedAt {
            let readAt = needsYouReadAt ?? checkedAt
            let carried = shown.compactMap { needsYouKnown[$0.id]?.readAt }.filter { $0 < readAt }
            reading.carried = carried.count
            reading.carriedSince = carried.min()
        }
        return reading
    }

    static let needsYouTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    fileprivate func applyNeedsYouTheme() {
        guard drawsSidebarLayout else { return }
        needsYouSkeleton.applyTheme(theme)
        needsYouSkeletonRows.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugNeedsYouShowing: Bool { needsYouShowing && !needsYouContainer.isHidden }
    var debugNeedsSectionIsOnNeedsYou: Bool { needsSectionView.superview === needsYouContainer }
    /// CR-1: the two skeleton rows under the band before the first read.
    var debugNeedsYouSkeletonShowing: Bool { !needsYouSkeleton.isHidden && !needsYouContainer.isHidden }
    var debugNeedsHeadingShown: Bool { !(needsGlyph.superview?.isHiddenOrHasHiddenAncestor ?? true) }
    #endif
}

// MARK: - CR-1 - the Crew band

// The board's CR-1 for the three tabs this page draws: Needs you, In flight
// and Log. One `HelmHeroColumn` in `.band` at the top of the page,
// reconfigured for whichever tab is showing from what the page already read -
// nothing is fetched for it. Log's filter moves onto the band's foot, the same
// `HelmSegmentedTabs` in the hero ink with its counts. Review's band is
// `ReviewController`'s own, drawn through the same `CrewBand` helpers.

extension FleetController {

    /// Mount the band at the top of the page, once, when the page adopts the
    /// sidebar layout. The band says what the answer banner, the boxed
    /// figures, the briefing card and their loading stand-ins said, so those
    /// stay hidden in this layout.
    fileprivate func adoptCrewBand() {
        crewBand.setArrangement(.band)
        contentStack.insertArrangedSubview(crewBand, at: 0)
        crewBand.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        for view in [loadingLabel, bannerSkeletonCard, bannerRow, statsRow, briefingCard] as [NSView] {
            view.isHidden = true
        }
        loadingTilesRow?.isHidden = true
        bandTiles.translatesAutoresizingMaskIntoConstraints = false
        // Log's filter leaves the list's column for the band's foot
        // (`renderCrewBand`), so the feed sits straight under the band.
        logContainer.removeArrangedSubview(logFilters)
        logFilters.removeFromSuperview()
        if activeTab == .log { renderLog() }
        renderCrewBand()
    }

    /// Every tab this page draws opens on the band in the sidebar layout:
    /// Needs you, In flight and Log.
    fileprivate var crewBandShows: Bool { drawsSidebarLayout }

    /// Fold one read into In flight's band: the verdict `FleetGreeting` has
    /// always said, and the counts the boxed figures showed.
    fileprivate func noteInFlightRead(_ snapshot: FleetSnapshot, needs: [FleetTask], working: [FleetTask],
                                      ready: FleetDataSource.PRReadyReading) {
        let answer = FleetGreeting.answer(tasks: needs + working, prs: ready, homeOk: snapshot.homeOk)
        let readyWords: CrewHeroWords.Ready
        switch ready {
        case .value(let count): readyWords = .count(count)
        case .scanning: readyWords = .scanning
        case .failed: readyWords = .failed
        }
        inFlightReading = CrewHeroWords.InFlightReading(
            hasRead: true, homeOk: snapshot.homeOk, verdictHeadline: answer.title, verdictBody: answer.meta,
            working: working.count, queued: snapshot.queuedCount, doneToday: snapshot.doneCount,
            projects: snapshot.projectsCount, ready: readyWords, watcher: snapshot.watcher.status,
            tasksRead: snapshot.tasksRead, checkedAt: Date())
    }

    /// Draw the band for the tab that is showing. Cheap when nothing changed:
    /// the band is only rebuilt when its words, its briefing or its foot do.
    /// B-01: redraw the band's day while the page can be seen. Its own
    /// signature skips the redraw when nothing it prints changed.
    private func dayDidChange() {
        guard isViewLoaded, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        renderCrewBand()
    }

    func renderCrewBand() {
        guard drawsSidebarLayout else { return }
        crewBand.isHidden = !crewBandShows
        guard crewBandShows else { return }
        // Log's feed opens on its first day header, whose row already holds
        // its own space above the day's name, so it sits closer under the
        // band than the other tabs' rows do, as the board draws it.
        contentStack.setCustomSpacing(activeTab == .log && !needsYouShowing ? 0 : NSStackView.useDefaultSpacing,
                                      after: crewBand)
        let words: CrewHeroWords.Band
        var bandViews: [NSView] = []
        var briefingKey = ""
        if needsYouShowing {
            words = CrewHeroWords.needsYou(needsYouWordsReading(), time: CrewBand.time)
        } else if activeTab == .log {
            words = CrewHeroWords.log(logReading, day: CrewHeroWords.dayFormatter.string(from: logReading.readAt ?? Date()),
                                      time: CrewBand.time)
        } else {
            let reading = inFlightReading ?? CrewHeroWords.InFlightReading(
                hasRead: false, homeOk: true, verdictHeadline: "", verdictBody: "", working: 0, queued: 0,
                doneToday: 0, projects: 0, ready: .scanning, watcher: "")
            words = CrewHeroWords.inFlight(reading, day: CrewHeroWords.dayFormatter.string(from: DayRollover.now()),
                                           time: CrewBand.time)
            // The board shows the briefing once the crew has been read, and
            // never over the setup prompt.
            if reading.hasRead, reading.homeOk, reading.tasksRead, bandBriefing != nil || bandBriefingBusy {
                bandViews = briefingBandViews()
                briefingKey = "\(bandBriefingBusy)|\(bandBriefing?.generatedAt.timeIntervalSince1970 ?? 0)|\(bandTileClauses.count)"
            }
        }
        let signature = "\(words)|\(bandViews.count)|\(briefingKey)"
        guard signature != bandSignature else { return }
        bandSignature = signature
        var foot: [NSView] = []
        if words.offersSetup {
            foot = [needsYouSetupButton]
        } else if !words.filter.isEmpty {
            // Log's filter, its counts in its titles. The band hands it the
            // hero ink and the chosen segment's words (`HelmHeroColumn`
            // 1.6.0). Its radio roles, ← → and what it filters are the
            // strip's own and unchanged.
            for segment in words.filter {
                logFilters.setTitle(segment.label, forID: segment.kind?.rawValue ?? FleetLogListView.allFilterID)
            }
            foot = [logFilters]
        } else if !words.figures.isEmpty {
            bandFigureWords = words.figures
            bandFigures.configure(CrewBand.items(words.figures), theme: theme)
            foot = [bandFigures]
        }
        CrewBand.configure(crewBand, words: words, foot: foot, bandViews: bandViews)
    }

    /// The briefing's line and its tiles: "Generated 6:58 AM from ..." (or
    /// that a new one is being composed), Regenerate and Dismiss until
    /// tomorrow, and one Br-3 tile per sentence, labelled with its page.
    private func briefingBandViews() -> [NSView] {
        let record = bandBriefing
        var line = ""
        if bandBriefingBusy {
            line = "Composing your briefing\u{2026}"
        } else if let record {
            line = MorningBriefing.subtitle(for: record) + (record.isDegraded ? " \u{00B7} offline" : "")
        }
        bandBriefingRow.subtitleLabel.stringValue = line
        // The card's footnote, for a briefing made without the AI half.
        let reason = record?.degradedReason.map { " (\($0))" } ?? ""
        bandBriefingRow.subtitleLabel.toolTip = record?.isDegraded == true
            ? "Plain summary - no AI call was made\(reason). Every number in it came from this machine." : line
        bandBriefingRow.setAccessibilityLabel("Morning briefing, \(line)")
        bandRegenerateButton.isEnabled = !bandBriefingBusy
        let clauses = record?.clauses ?? []
        if clauses != bandTileClauses { rebuildBandTiles(clauses) }
        return clauses.isEmpty ? [bandBriefingRow] : [bandBriefingRow, bandTiles]
    }

    /// One tile per clause, as Home draws them (`HomeBriefingHero.tile`):
    /// the page it came from as its label, its hue as the dot. A tile that
    /// points somewhere opens it through this page's own deep links, the ones
    /// the paragraph's clauses used.
    private func rebuildBandTiles(_ clauses: [BriefingClause]) {
        bandTileClauses = clauses
        bandTiles.tiles = clauses.map { clause in
            let words = HomeBriefingHero.tile(clause, pageName: PlaceName.short)
            let tile = HelmHeroTile(ringSide: nil)
            tile.tint = words.tint
            if words.isLink {
                tile.setAction { [weak self, weak tile] in self?.activateBriefingClause(clause.target, anchor: tile) }
            }
            tile.configure(label: words.label, text: words.text)
            return tile
        }
    }

    @objc fileprivate func bandRegenerateTapped() { refresh(forceBriefing: true) }
    @objc fileprivate func bandDismissTapped() { dismissBriefing() }

    #if FM_SELFTESTS
    /// The band as drawn, or `nil` with none showing (the floating bar).
    var debugCrewBand: HelmHeroColumn? { crewBandShows && !crewBand.isHidden ? crewBand : nil }
    /// CR-1 on Log: the filter (on the band's foot in the sidebar layout, in
    /// the list's column in the floating bar), the list, and what was read.
    var debugLogFilters: HelmSegmentedTabs { logFilters }
    var debugLogList: FleetLogListView { logList }
    var debugLogListShowing: Bool { !logList.isHiddenOrHasHiddenAncestor }
    var debugLogReading: CrewHeroWords.LogReading { logReading }
    /// A suite in a real shell, whose page the workspace built, points the
    /// Log tab at a log it wrote (or broke). The page still reads it through
    /// `renderLog`, the same read the app does.
    func debugUseLogStore(_ store: FleetLogStore) {
        logStore = store
        if activeTab == .log { renderLog() }
    }
    var debugBandFigures: HelmKPIStrip { bandFigures }
    var debugBandTiles: [HelmHeroTile] { bandTiles.tiles }
    var debugBandBriefingRow: HelmHeroRow? {
        debugCrewBand?.debugBandViews.contains(bandBriefingRow) == true ? bandBriefingRow : nil
    }
    var debugBandRegenerateButton: HelmButton { bandRegenerateButton }
    var debugBandDismissButton: HelmButton { bandDismissButton }
    var debugBandSetupButton: HelmButton { needsYouSetupButton }
    /// The views the floating bar draws and the sidebar layout's band
    /// replaces: the answer banner, the boxed figures, the briefing card.
    var debugDashboardChromeShown: (banner: Bool, stats: Bool, briefing: Bool) {
        (!bannerRow.isHiddenOrHasHiddenAncestor, !statsRow.isHiddenOrHasHiddenAncestor,
         !briefingCard.isHiddenOrHasHiddenAncestor)
    }
    var debugBriefingCard: MorningBriefingCard { briefingCard }
    #endif
}

/// CR-1: the band says what the grey line under the toolbar said, so in the
/// sidebar layout Needs you, In flight and Log give up that line as Tasks
/// does (`WorkspaceHeaderLineCollapsing`). The live subtitle is still the
/// page's summary for the crew panel.
extension FleetController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { crewBandShows }
    var drawsSubtitleOnHeaderLine: Bool { !crewBandShows }
}

/// What Crew › Needs you last read, without its rows - the sidebar layout's
/// Crew badge (`WorkspaceSignals`).
struct FleetNeedsYouReading: Equatable {
    /// A read has landed. Until then the launch refresh is still reading.
    let hasRead: Bool
    /// The last read found a firstmate home to read.
    let homeOk: Bool
    /// The tasks waiting on the captain, including any carried from an
    /// earlier read because this one could not read them.
    let waiting: Int
    /// When the task list was last read successfully.
    let readAt: Date?
    /// When the crew's state was last checked, successfully or not.
    let checkedAt: Date?
    /// The last read could not read the task list at all.
    let readFailed: Bool
}

#if FM_SELFTESTS
extension FleetController {
    /// R2-UX-05: whether the greeting draws on the page.
    var debugGreetingIsShown: Bool { !(headerRow?.isHiddenOrHasHiddenAncestor ?? true) }
}
#endif

// R2-UX-05: the module line the sidebar layout's header draws for Crew's
// In flight tab. The floating bar keeps its greeting, so it gets no actions
// and the static subtitle from here.
extension FleetController: DaylightDrillActions {
    /// R2-UX-04: Refresh is an outlined page action in the toolbar, where
    /// every other module's is, rather than a button floating in the page.
    /// R4-UX-08: Stop takes Refresh's place while a pass is in flight. A
    /// second item there pushed the breadcrumb into the overflow at Larger
    /// text on a 1512pt window (`WorkspaceToolbarSelfTest`), and Refresh does
    /// nothing until the pass ends anyway.
    var drillHeaderActions: [NSView] {
        guard drawsSidebarLayout else { return [] }
        return isLoading ? [stopButton] : [refreshButton]
    }
    var drillHeaderSubtitle: String? { drawsSidebarLayout ? liveSubtitle : nil }
}

// R2-UX-04: Ask your crew is the page's verb, the far-right filled button in
// the sidebar layout.
extension FleetController: WorkspacePrimaryActionProviding {
    var workspacePrimaryAction: NSView? { drawsSidebarLayout ? crewButton : nil }
}
