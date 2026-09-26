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

    // MARK: F20 - the daily review
    //
    // The general-user briefing, directly under F12's fleet-shaped one - see
    // `DailyReviewData.swift`'s header for why they are two cards rather than
    // one longer one. It reads the same shared `ShiftStore` above plus the
    // shell's own sticky-board and reading-list stores, handed over by
    // `attachDailyReviewSources` (they are built after this controller is, so
    // they cannot come through `init`). Nothing here fetches: every store is
    // read from the arrays it already has in memory, and the one genuinely
    // external read - today's calendar events - happens only after the
    // captain has turned the column on.
    private let dailyReviewCard = DailyReviewCard()
    private var stickyBoardStore: StickyBoardStore?
    private var readingListStore: ReadingListStore?
    /// Replaced by a stub in `DailyReviewViewSelfTest`, which is what lets the
    /// calendar column be rendered and asserted with no EventKit call, no
    /// permission prompt and no reading of the captain's real calendar.
    var dailyReviewCalendar: DailyReviewCalendarReading = EventKitDailyReviewCalendar()

    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` took four
    /// dependencies back off this page: the command library's root and the
    /// three phase-3 write stores. Every one of them existed only for the
    /// Straw Hat crew - the command library's root for their read-only
    /// `command_search` tool, the other three for their proposal kinds - and
    /// they moved to `StrawHatController` with the chat. This page never
    /// listed, searched or wrote a command, a sticky note or a schedule.
    init(shiftStore: ShiftStore) {
        self.shiftStore = shiftStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// A labeled `HelmButton(.primary)` - a filled accent pill matching Setup
    /// > Updates' own "Refresh" action, so every refresh-style button in the
    /// app now shares one real, theme-aware definition rather than each page
    /// picking its own muted `.quiet` look.
    private let refreshButton = HelmButton(title: "Refresh", variant: .primary, symbol: "arrow.clockwise")
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
    private let bannerRow = HelmAccentRow(hover: false)

    private let statsRow = NSStackView()

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
    /// away a half-typed answer.
    var openReplyTaskID: String?
    var openReplyComposer: FleetMessageComposer?
    /// Live composers, so a theme change re-tints them.
    var liveComposers: [FleetMessageComposer] { [openReplyComposer].compactMap { $0 } }

    /// The needs-decision/blocked set the last `render` produced, so
    /// `FleetController+Reply` can re-lay its rows (open/close a composer)
    /// without a fetch.
    var currentNeedsTasks: [FleetTask] = []

    // Narrow accessors for the F7 extension - `theme`, `accentRows` and
    // `refresh()` are private to this file, and widening them wholesale would
    // hand the extension more than it needs.
    var currentTheme: HelmTheme { theme }
    /// The needs-your-call rows keep their own list rather than joining
    /// `accentRows`: that one is cleared by `render`, while these are also
    /// rebuilt whenever a composer opens or closes, and a shared array would
    /// accumulate orphaned rows across those re-lays.
    var needsAccentRows: [HelmAccentRow] = []
    func applyThemeFromReply() { applyTheme() }
    /// F7: a reply the captain just sent may have resolved a decision, so
    /// this re-reads for real rather than from the coalescing window.
    func refreshAfterReply() { refresh(forceRefresh: true) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        // `FlippedView` (not a plain `NSView`), matching `SettingsController`'s
        // established Fix 4 pattern: a non-flipped document view puts y=0 at
        // its *bottom*, so before data arrives - while the content is still
        // shorter than the viewport, since `inFlightStack` starts with zero
        // arranged subviews - AppKit rests it against the bottom of
        // the clip view, leaving a blank gap the size of the shortfall sitting
        // above it, with the header pushed down into (or past) that gap. Once
        // rows are added and the content grows, it snaps back up - exactly the
        // "empty area above the header for several seconds" bug. A flipped
        // document view pins y=0 to the top always, so the header never moves.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        buildStatsRow()
        let loadingSection = buildLoadingState()
        let inFlightSection = buildSection(title: "In flight")
        inFlightSectionView = inFlightSection
        let needsSection = buildNeedsSection()
        needsSectionView = needsSection

        overviewContainer.orientation = .vertical
        overviewContainer.alignment = .leading
        overviewContainer.spacing = 20
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
        // F20 sits directly under F12: the fleet's briefing first (it is the
        // one that can be holding the crew up), then the captain's own day.
        buildDailyReviewCard()
        overviewContainer.addArrangedSubview(dailyReviewCard)
        overviewContainer.addArrangedSubview(loadingSection)
        overviewContainer.addArrangedSubview(bannerRow)
        // F7: the "Needs your call" list sits directly under the banner that
        // counts them - the mockup's own grouping - rather than below the
        // stat tiles.
        overviewContainer.addArrangedSubview(needsSection)
        overviewContainer.addArrangedSubview(statsRow)
        overviewContainer.addArrangedSubview(inFlightSection)

        let logSection = buildLogSection()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(tabs)
        contentStack.addArrangedSubview(overviewContainer)
        contentStack.addArrangedSubview(logSection)

        // The data sections stay hidden behind the loading skeleton until the
        // first successful `render(...)` - see `buildLoadingState`.
        bannerRow.isHidden = true
        statsRow.isHidden = true
        inFlightSection.isHidden = true
        needsSection.isHidden = true
        briefingCard.isHidden = true
        dailyReviewCard.isHidden = true
        logSection.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            overviewContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            logSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            briefingCard.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
            dailyReviewCard.widthAnchor.constraint(equalTo: overviewContainer.widthAnchor),
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

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

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
        scrollToTop()
        // F12: a briefing already generated today renders immediately from the
        // persisted record - the AI call is not repeated on every visit, and
        // the card does not flicker in behind the fleet fetch.
        showCachedBriefingIfAvailable()
        // F20 is recomputed on every appearance rather than cached for the
        // day: it is an in-memory scan of stores the app already holds, and
        // a briefing that still said "2 due" after both were ticked off
        // would be worse than no card.
        renderDailyReview()
        // B16: the one daily-review source that is not already in memory is a
        // connected Google account's calendar, and `events(on:)` only ever
        // reads its cached snapshot (it is synchronous and on the main
        // thread - GL-04/GL-12). Without this, Fleet's copy of the card
        // rendered whatever snapshot some *other* page had last fetched, and
        // showed a stated gap forever on a machine where Fleet is the only
        // page the captain opens. The same call Overview already makes, with
        // the same re-render-only-if-changed rule.
        DailyReviewCalendarSources.shared.refreshGoogle(for: Date()) { [weak self] changed in
            guard changed, let self, self.isViewLoaded, !self.view.isHidden else { return }
            self.renderDailyReview()
        }
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
        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh fleet data"
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        crewButton.target = self
        crewButton.action = #selector(crewTapped)
        crewButton.toolTip = "Open the Straw Hat Pirates page"
        crewButton.setContentHuggingPriority(.required, for: .horizontal)
        crewButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        crewButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // `.fill` plus a flexible spacer, so Refresh sits at the page's own
        // trailing edge (prototype `.phead .row`) instead of hugging the
        // greeting. See AGENTS.md gotcha (10)/(12): a nested stack has no
        // intrinsic size, so the spacer - not the text stack - is what carries
        // the low hugging priority the distribution actually stretches.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, crewButton, refreshButton])
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        headerRow = row
        return row
    }

    /// Kept so `loadView` can pin it to the content column's full width -
    /// without that the row shrinks to its content and Refresh stops being at
    /// the page's trailing edge.
    private var headerRow: NSStackView!

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A skeleton that occupies the content area under the header from the
    /// very first frame - the banner/stats/In flight/Ready to merge sections
    /// stay hidden (and animation-free) until the first `render(...)` lands,
    /// so there is never an interval where the page shows nothing but a
    /// collapsed, empty-looking stack of cards while `refresh()`'s
    /// background fetch (real `gh`/Bitbucket network calls) is in flight.
    private func buildLoadingState() -> NSView {
        // D3: the page arrives in the shape of the content that is coming,
        // rather than as a grey system spinner over a sentence.
        loadingLabel.font = HelmType.caption()
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [loadingLabel, loadingSkeleton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false

        loadingContainer.wantsLayer = true
        loadingContainer.layer?.cornerRadius = 10
        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: loadingContainer.leadingAnchor, constant: HelmMetrics.s3),
            stack.trailingAnchor.constraint(equalTo: loadingContainer.trailingAnchor, constant: -HelmMetrics.s3),
            stack.topAnchor.constraint(equalTo: loadingContainer.topAnchor, constant: HelmMetrics.s4),
            stack.bottomAnchor.constraint(equalTo: loadingContainer.bottomAnchor, constant: -HelmMetrics.s4),
        ])
        return loadingContainer
    }

    /// One `HelmStatTile` - the app's shared stat tile
    /// (`HelmDesignSystem.swift`, audit §6.3 component 4). This page's own copy
    /// was one of three (four, counting Shift's duplicate) differing in metric
    /// size, padding, fill opacity and height for the same "one big number and
    /// a caption" job; its click support is what the shared component adopted.
    ///
    /// `onClick` is a plain closure on the tile - no nested real control, so no
    /// hit-testing hazard (matching `SettingsController`'s theme/session cards
    /// and `ShiftProjectViews`' project cards, the same clickable-plain-view
    /// pattern used throughout this app). fm/grandline-overview-drop-duplicate-
    /// pr-list: this is how the "ready to merge" tile jumps straight to
    /// `.review`'s full list, after removing this page's own duplicate
    /// itemized copy of it.
    private func statTile(icon: String, value: String, label: String, tint: HelmTint? = nil, onClick: (() -> Void)? = nil) -> NSView {
        let tile = HelmStatTile(symbol: icon, value: value, caption: label, tint: tint)
        if let onClick {
            tile.onClick = onClick
            tile.toolTip = "View in Review"
        }
        statTiles.append(tile)
        return tile
    }

    /// Rebuilt from scratch on every refresh, so this list is cleared and
    /// repopulated in `rebuildStats`. Each tile themes itself; this only exists
    /// so `applyTheme` can hand every live tile the new theme.
    private var statTiles: [HelmStatTile] = []

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
        overviewContainer.isHidden = tab != .overview
        logContainer.isHidden = tab != .log
        if tab == .log { renderLog() }
        applyTheme()
    }

    /// Re-reads the feed and re-renders it. Called when the Log tab is shown,
    /// on `viewWillAppear` while it is showing, and by Refresh - never on a
    /// timer (F6 adds no polling).
    private func renderLog() {
        let all = FleetLogFeed.events(store: FleetLogStore.shared, shift: shiftStore)
        let shown = FleetLogFeed.filtered(all, kind: logFilterKind)
        let emptyTitle: String
        let emptyBody: String
        if all.isEmpty {
            emptyTitle = "Nothing logged yet"
            emptyBody = "Merges, completed tasks, resolved sync conflicts and saved investigations land here as they happen."
        } else {
            emptyTitle = "Nothing here"
            emptyBody = "No \(logFilterKind?.pluralTitle.lowercased() ?? "events") in the recent history."
        }
        logList.setRows(FleetLogFeed.rows(for: shown), theme: theme,
                        emptyTitle: emptyTitle, emptyBody: emptyBody)
    }

    // MARK: Refresh

    /// The captain's own Refresh click always runs a real sweep - never
    /// answered from `FleetTaskCache`'s coalescing window (3.5).
    @objc private func refreshTapped() { refresh(forceRefresh: true) }

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
        isLoading = true
        refreshButton.isEnabled = false
        if forceBriefing { briefingCard.setBusy(true) }
        // snapshot() (~0.5s: task/backlog counts, watcher health) and
        // OpenPRsSource.fetch() (the slow, network-bound per-clone PR scan)
        // are independent - render the fast fields the moment snapshot()
        // finishes instead of blocking that on the PR fetch too, then
        // re-render once the PR list itself lands. The "Ready to merge"
        // section/stat tile shows its own loading state in between.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = FleetDataSource.snapshot(forceRefresh: forceRefresh)
            DispatchQueue.main.async {
                guard let self else { return }
                self.render(snapshot: snapshot, mergedPRs: nil)
            }
            let fetched = OpenPRsSource.fetchDetailed()
            let merged = FleetDataSource.mergedPRs(openPRs: fetched.prs, tasks: snapshot.tasks)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.refreshButton.isEnabled = true
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
    /// "ready to merge" stat tile shows 0 until this method is called again
    /// once the fetch completes.
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

    private func render(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?, prFetchFailure: String? = nil) {
        if !hasLoadedOnce {
            hasLoadedOnce = true
            loadingContainer.isHidden = true
            bannerRow.isHidden = false
            statsRow.isHidden = false
            inFlightSectionView.isHidden = false
        }

        accentRows.removeAll()
        emptyStates.removeAll()

        let working = snapshot.tasks.filter { $0.status == "working" }
        let needs = snapshot.tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }
        onNeedsDecisionCountChanged?(needs.count)

        // Daylight §5.4: one definition of the greeting, shared with the home
        // canvas - see `FleetGreeting`'s own header for why that matters.
        greetingLabel.stringValue = FleetGreeting.greeting(captain: snapshot.captain)
        subtitleLabel.stringValue = snapshot.homeOk
            ? "\(Self.weekdayFormatter.string(from: Date())) \u{00B7} the fleet is yours"
            : "Setup isn't finished yet"

        // One definition of "ready to merge" for the banner and the tile
        // alike - see `FleetDataSource.readyToMerge`. Both used to render the
        // raw *open* count under that label, which is how this page could say
        // "50 PRs ready to merge" while the merge-queue card one click away
        // said "none ready" off the identical array.
        let readyToMerge = mergedPRs.map(FleetDataSource.readyToMergeCount) ?? 0
        renderBanner(needs: needs, working: working, readyCount: readyToMerge,
                     prFetchFailure: prFetchFailure, homeOk: snapshot.homeOk)
        rebuildStats(working: working.count, ready: readyToMerge, snapshot: snapshot,
                     prFetchFailure: prFetchFailure)
        currentNeedsTasks = needs
        rebuildNeedsRows(needs)
        rebuildTaskRows(into: inFlightStack, tasks: working, emptyTitle: "All hands idle", emptyBody: "No crew are working right now. Send your first mate a task from the console and this board lights up.")
        inFlightHeader.stringValue = "In flight"
        inFlightCountLabel.stringValue = "\(working.count)"

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
    private func renderBanner(needs: [FleetTask], working: [FleetTask], readyCount: Int,
                              prFetchFailure: String? = nil, homeOk: Bool = true) {
        let answer = FleetGreeting.answer(tasks: needs + working,
                                          readyCount: readyCount,
                                          prFetchFailure: prFetchFailure,
                                          homeOk: homeOk)
        let content = HelmAccentRow.Content(
            tint: answer.tint,
            kicker: answer.kicker,
            title: answer.title,
            meta: answer.meta,
            badgeSymbol: answer.badgeSymbol,
            chipText: answer.isSetupPrompt ? "Open Setup" : nil)
        bannerRow.configure(content, theme: theme)
        // GL-31: only the not-configured banner is clickable, and it leads
        // straight into the Bootstrap stepper where firstmate home is set.
        bannerRow.onClick = answer.isSetupPrompt ? { [weak self] in self?.onNavigateToSetup?() } : nil
    }

    private func rebuildStats(working: Int, ready: Int, snapshot: FleetSnapshot,
                              prFetchFailure: String? = nil) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statTiles.removeAll()

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
        statsRow.addArrangedSubview(statTile(icon: "clock", value: "\(working)", label: "working"))
        // GL-14: "\u{2014}" (an em dash), not "0", when the scan failed - the
        // tile is still clickable so the captain can go to Review and see the
        // real reason there.
        statsRow.addArrangedSubview(statTile(
            icon: prFetchFailure == nil ? "arrow.triangle.pull" : "wifi.exclamationmark",
            value: prFetchFailure == nil ? "\(ready)" : "\u{2014}",
            label: prFetchFailure == nil ? "ready to merge" : "PRs unavailable",
            tint: prFetchFailure == nil ? .accent : .warn,
            onClick: { [weak self] in self?.onNavigateToReview?() }))
        statsRow.addArrangedSubview(statTile(icon: "line.3.horizontal", value: "\(snapshot.queuedCount)", label: "queued"))
        statsRow.addArrangedSubview(statTile(icon: "checkmark.circle", value: "\(snapshot.doneCount)", label: "done today", tint: .good))
        statsRow.addArrangedSubview(statTile(icon: "shippingbox", value: "\(snapshot.projectsCount)", label: "projects"))
        statsRow.addArrangedSubview(statTile(icon: "waveform.path.ecg", value: snapshot.watcher.status == "healthy" ? "OK" : "\u{2014}", label: watcherLabel, tint: watcherTint))
    }

    private func rebuildTaskRows(into stack: NSStackView, tasks: [FleetTask], emptyTitle: String, emptyBody: String) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if tasks.isEmpty {
            stack.addArrangedSubview(emptyStateView(icon: "tray", title: emptyTitle, body: emptyBody))
            return
        }
        for task in tasks {
            let row = taskRowView(task)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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

    /// Rebuilt with the lists on every render; each state themes itself, so this
    /// only exists to reach the live ones from `applyTheme`.
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
    private func taskRowView(_ task: FleetTask) -> NSView {
        let visuals = taskVisuals(task)
        let row = HelmAccentRow(hover: false)
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
        accentRows.append(row)
        return row
    }

    /// Live `HelmAccentRow`s, so a theme change re-tints them. They are
    /// rebuilt on every `render()`, so this is cleared alongside the stack.
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
            briefingCard.isHidden = true
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
            briefingCard.isHidden = true
            briefingCard.setBusy(false)
            return
        }
        if !force, let record = AppSettings.shared.morningBriefingRecord,
           record.day == MorningBriefing.dayKey() {
            // Already briefed today - render it (or stay hidden if the captain
            // dismissed it) rather than spending a second `claude` call.
            if record.dismissed { briefingCard.isHidden = true } else { show(record) }
            return
        }
        guard !isGeneratingBriefing else { return }
        generateBriefing(snapshot: snapshot, prReadyCount: prReadyCount)
    }

    private func generateBriefing(snapshot: FleetSnapshot, prReadyCount: Int?) {
        isGeneratingBriefing = true
        briefingCard.isHidden = false
        briefingCard.setBusy(true)

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
        inputs.forkDriftCount = counts.forkDrift
        inputs.toolUpdateCount = counts.toolUpdates
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
        func commit(_ clauses: [BriefingClause], degradedReason: String?) {
            let record = MorningBriefing.record(inputs: inputs, clauses: clauses,
                                                isDegraded: degradedReason != nil,
                                                degradedReason: degradedReason)
            AppSettings.shared.morningBriefingRecord = record
            self.isGeneratingBriefing = false
            self.briefingCard.setBusy(false)
            self.show(record)
        }

        guard MorningBriefingAI.isAvailable else {
            commit(localClauses, degradedReason: "claude isn\u{2019}t installed or on PATH")
            return
        }
        MorningBriefingAI.generate(inputs: inputs) { result in
            switch result {
            case .success(let clauses):
                commit(clauses, degradedReason: nil)
            case .failure(let error):
                // Never fatal: the deterministic clauses are already built.
                AppLog.ai.info("morning briefing fell back to the local summary: \(error.message, privacy: .public)")
                commit(localClauses, degradedReason: error.message)
            }
        }
    }

    private func show(_ record: MorningBriefingRecord) {
        briefingCard.render(record, theme: theme)
        briefingCard.isHidden = false
    }

    private func dismissBriefing() {
        briefingCard.isHidden = true
        briefingCard.setBusy(false)
        guard var record = AppSettings.shared.morningBriefingRecord else { return }
        record.dismissed = true
        AppSettings.shared.morningBriefingRecord = record
    }

    /// The deep links. Every branch is a real destination - `.none` clauses are
    /// never rendered as links in the first place, so there is no case here
    /// that silently does nothing.
    private func activateBriefingClause(_ target: BriefingTarget) {
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
            quotaUsage.toggle(relativeTo: briefingCard.quotaAnchor)
        case .fleet:
            // The tasks this clause is about are rows on this very page.
            if let section = inFlightSectionView { section.scrollToVisible(section.bounds) }
        }
    }

    // MARK: F20 - the daily review

    /// Hands over the two stores this controller does not own. Called once by
    /// `AppShellController` after it has built them - GL-23's rule: these are
    /// the *shared* instances, never a second copy, because both cache their
    /// records and a second writer would race the first.
    func attachDailyReviewSources(stickyBoardStore: StickyBoardStore,
                                  readingListStore: ReadingListStore) {
        self.stickyBoardStore = stickyBoardStore
        self.readingListStore = readingListStore
    }

    private func buildDailyReviewCard() {
        dailyReviewCard.onDismiss = { [weak self] in self?.dismissDailyReview() }
        dailyReviewCard.onOpenSettings = { [weak self] in self?.onNavigateToDestination?(.settings) }
        dailyReviewCard.onPlanDay = { [weak self] in self?.onNavigateToDestination?(.shift) }
        dailyReviewCard.onStartTask = { [weak self] id in self?.onOpenShiftTask?(id) }
        dailyReviewCard.onConnectCalendar = { [weak self] in self?.connectDailyReviewCalendar() }
    }

    /// Reads the six sources and renders. Cheap by construction: every store
    /// below is asked for an array it already holds, so this is a handful of
    /// filters over a few hundred records at worst.
    ///
    /// GL-14 runs through the whole function: a store in its failed-load state
    /// yields `.unavailable(reason)`, never an empty array, and the card
    /// states the gap instead of drawing a zero.
    /// Re-render, but only if this page has ever been built.
    ///
    /// The shell calls this on an event that happened somewhere else (a
    /// Google account connecting), and touching `view` on a page that has
    /// never been visited would mount it - exactly what GL-37's laziness
    /// exists to avoid.
    func renderDailyReviewIfMounted() {
        guard isViewLoaded else { return }
        renderDailyReview()
    }

    private func renderDailyReview() {
        guard AppSettings.shared.dailyReviewEnabled else {
            dailyReviewCard.isHidden = true
            return
        }
        let now = Date()
        guard AppSettings.shared.dailyReviewDismissedDay != MorningBriefing.dayKey(for: now) else {
            dailyReviewCard.isHidden = true
            return
        }

        var inputs = DailyReviewInputs()
        inputs.now = now

        // Tasks and follow-ups - the shared store's own in-memory lists, the
        // same ones the Tasks page is showing.
        if shiftStore.isInFailedLoadState {
            let reason = "your tasks could not be read - a file in the Tasks store failed to parse"
            inputs.tasks = .unavailable(reason)
            inputs.followUps = .unavailable(reason)
        } else {
            inputs.tasks = .available(shiftStore.activeTasks)
            inputs.followUps = .available(shiftStore.followUps)
            var names: [String: String] = [:]
            for project in shiftStore.projects { names[project.id] = project.name }
            inputs.projectNames = names
        }

        // The sticky board and the reading list. A store that was never
        // attached is a wiring mistake rather than a captain-facing state, so
        // it says so plainly rather than pretending the board is empty.
        if let store = stickyBoardStore {
            inputs.stickies = store.isInFailedLoadState
                ? .unavailable("your sticky board could not be read - its file failed to parse")
                : .available(store.activeNotes)
        } else {
            inputs.stickies = .unavailable("the sticky board is not connected to this page")
        }
        if let store = readingListStore {
            inputs.reading = store.isInFailedLoadState
                ? .unavailable("your reading list could not be read - its file failed to parse")
                : .available(store.links)
        } else {
            inputs.reading = .unavailable("the reading list is not connected to this page")
        }

        // Habits: F8 has not shipped. A stated gap, not a hidden section -
        // see `DailyReviewHabits`.
        inputs.habits = DailyReviewHabits.read()

        // The calendar. Two sources now - this Mac's own through EventKit,
        // and any connected Google account - each behind its own switch, and
        // `DailyReviewCalendarSources` owns which of them are on. Both are
        // read-only; `nil` means every source is off, which is a state rather
        // than an absence.
        if let calendar = DailyReviewCalendarSources.shared.source(local: dailyReviewCalendar) {
            inputs.calendar = calendar.events(on: now)
        } else {
            inputs.calendar = .unavailable(DisabledDailyReviewCalendar.offReason)
        }
        dailyReviewCard.setCalendarConnectable(dailyReviewCalendarIsConnectable())

        dailyReviewCard.render(DailyReviewComposer.digest(from: inputs), theme: theme)
        dailyReviewCard.isHidden = false
    }

    /// Whether offering "Show today's calendar" can actually lead anywhere.
    /// A denied or restricted grant cannot be changed from inside this app
    /// (only System Settings can), and an unbundled build must not ask at all
    /// - see `EventKitDailyReviewCalendar.canPrompt`.
    private func dailyReviewCalendarIsConnectable() -> Bool {
        guard dailyReviewCalendar.canPrompt else { return false }
        switch dailyReviewCalendar.access {
        case .denied, .restricted, .writeOnly: return false
        case .readable: return !AppSettings.shared.dailyReviewCalendarEnabled
        case .notDetermined: return true
        }
    }

    private func connectDailyReviewCalendar() {
        dailyReviewCalendar.requestAccess { [weak self] access in
            guard let self else { return }
            switch access {
            case .readable:
                AppSettings.shared.dailyReviewCalendarEnabled = true
            case .denied, .restricted, .writeOnly, .notDetermined:
                // Not silently swallowed: the captain pressed a button and is
                // owed an answer, and the card's own gap line will now carry
                // the specific reason.
                Feedback.report("Grand Line could not read your calendar.", kind: .warning,
                                persistence: .transient, in: self.view)
            }
            self.renderDailyReview()
        }
    }

    private func dismissDailyReview() {
        AppSettings.shared.dailyReviewDismissedDay = MorningBriefing.dayKey()
        dailyReviewCard.isHidden = true
    }

    #if FM_SELFTESTS
    /// GL-27: debug builds only. The suite drives the real page rather than
    /// the card alone, which is what proves the wiring as well as the render.
    var debugDailyReviewCard: DailyReviewCard { dailyReviewCard }
    func debugRenderDailyReview() { renderDailyReview() }
    func debugAttachDailyReviewStores(sticky: StickyBoardStore, reading: ReadingListStore) {
        attachDailyReviewSources(stickyBoardStore: sticky, readingListStore: reading)
    }
    #endif

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

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

        loadingContainer.layer?.backgroundColor = surface.cgColor
        loadingContainer.layer?.borderWidth = 1
        loadingContainer.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        loadingLabel.textColor = muted
        loadingSkeleton.applyTheme(theme)

        bannerRow.applyTheme(theme)
        briefingCard.applyTheme(theme)
        dailyReviewCard.applyTheme(theme)
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

        for tile in statTiles { tile.applyTheme(theme) }
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
        render(snapshot: snapshot, mergedPRs: mergedPRs, prFetchFailure: prFetchFailure)
    }

    /// The answer banner's own body line, as rendered - this is where
    /// "N PRs ready to merge" is actually spoken to the captain.
    var debugBannerMeta: String { bannerRow.debugMetaText }

    /// Every stat tile as rendered. See `ReviewController.debugStatTiles`.
    var debugStatTiles: [(value: String, caption: String)] { statTiles.map { $0.debugMetric } }
    #endif
}
