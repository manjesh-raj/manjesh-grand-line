// Grand Line - native macOS app.
//
// `HomeCanvasController` - the Daylight hub (migration §5.2, §5.3, §5.4,
// §6.1). The launch landing, and the app's navigation: a greeting, then a
// wrapping grid of live module cards, each opening its own destination.
//
// **The two rules this file is built around.**
//
// 1. **It never constructs a store or fires a fetch.** Every number on this
//    page is something the app had already computed for another reason - a
//    page's own refresh, a poller's own pass, a registry's own state, or a
//    plain in-memory read of a store someone else owns. That is §6.1's
//    "NO new detection, NO new polling", and it is not a nicety: the canvas
//    is the first thing shown at launch and is re-rendered on every return
//    from a drill page, so a single `snapshot()` or `fetchDetailed()` in here
//    would turn every back-navigation into a multi-second stall and would
//    double the fleet's real workload. `DaylightModuleSelfTest.
//    checkCanvasConstructsNoStores` is a source guard that fails the build if
//    a `Store()`/`Source(` construction ever appears here.
//
//    Concretely: `FleetController` pushes its snapshot and merged PRs here
//    when its *own* refresh completes (`onSnapshotChanged`), the health
//    registry and notification-signal poller are read as already-published
//    state, and the injected stores are read from memory. The one genuinely
//    on-disk read is the Docs runbook list, which is a small directory scan.
//
// 2. **Spaces are presentation state and live only here** (§5.3). The bar
//    draws pills and reports clicks; this controller holds the selection and
//    consults `DaylightModule.space`. Nothing else in the app - no store, no
//    poller, no registry, no notification source - knows spaces exist.
//
// **Landmines this page is specifically shaped around** (AGENTS.md):
//   - gotcha (9): a plain `NSView` document view is *not* flipped, so short
//     content rests at the bottom of the clip view with a gap above it. This
//     uses `FlippedView` + `scrollToTop()`, like every other scroll-backed
//     page here.
//   - gotcha (4): the document's width pins to `scroll.contentView`, never to
//     `scroll` - a non-overlay scroller reserves a real ~15pt track.
//   - GL-20: the window-resize handler is gated on this page actually being
//     visible, or a resize while the captain is on Console pays for the
//     canvas's whole relayout.
//   - gotcha (13): **there are two grids here**, and every card width in
//     either is `HelmDaylightPriority.contentTie` (499) - below
//     `NSLayoutPriorityWindowSizeStayPut` - so no card can cap the window.
//     Off Overview it is `HelmResponsiveGrid.spanningRows(_:)`, a wrapping
//     shelf whose column count comes from the container's real width,
//     because the Morning briefing is two columns wide (§6.1,
//     `DaylightModule.gridSpan` - see that enum's own note for the three
//     passes it took to land there). On Overview it is
//     `HelmResponsiveGrid.proportionalRow(...)`, a hand-placed twelve-track
//     dashboard: those five widgets have relative sizes that are the design
//     rather than a consequence of the window, and deriving the count from
//     the width is what produced the ragged masonry the captain rejected.
//     See `dashboardRowViews` for the placement and the two conditions
//     under which it hands back to the wrapping grid.
//   - The hub has **no hero band**. `fm/grandline-home-page-visual-overhaul`
//     merged it into `NeedsAttentionCard`, because the captain's reference
//     draws one card at the top of Home and this page drew two. `heroCard`
//     is still built and still heads the four other spaces as the plain row
//     it always was there; `hubHeader` is where Overview's two header
//     strings come from now.

import AppKit

final class HomeCanvasController: NSViewController {

    /// The already-owned stores this page reads. Injected rather than
    /// constructed - see rule 1 in the file header, and the source guard that
    /// enforces it.
    struct Sources {
        let shiftStore: ShiftStore
        let hostStore: HostStore
        let scheduleStore: ScheduleStore
        let logAnalyzerStore: LogAnalyzerStore
        let docsRunbookStore: DocsRunbookStore
        let codePreviewStore: CodePreviewStore
        /// F1's notebook - the shell's own shared instance, injected like
        /// every other store here (`checkCanvasConstructsNoStores` forbids
        /// the canvas building one).
        let notebookStore: NotebookStore
        /// F4's reading list - the shell's own shared instance, injected like
        /// every other store here (`checkCanvasConstructsNoStores` forbids the
        /// canvas building one).
        let readingListStore: ReadingListStore
        /// `fm/grandline-tasks-kanban-devops-split`: the shell's own shared
        /// instance, injected like every other store here - the canvas never
        /// *constructs* one (`checkCanvasConstructsNoStores` forbids exactly
        /// that), and this one caches its records in memory, so the card's
        /// count is a field read rather than a directory scan.
        let commandLibraryStore: CommandLibraryStore
        /// UX5's sticky-note peek. GL-23: the **`StickyBoardController`'s own
        /// instance**, injected like every other store here rather than
        /// constructed - this store caches its notes in memory, so a second
        /// copy would diverge from the board's within a session and race its
        /// writes.
        let stickyBoardStore: StickyBoardStore
    }

    /// §6.1's grid: minimum column width 255, gap 16.
    static let minModuleWidth: CGFloat = 255
    static let gridSpacing: CGFloat = 16
    /// §2.7's canvas gutter.
    static let gutter: CGFloat = 22
    /// How far the top-anchored content sits below the page's own top edge.
    ///
    /// The bar already reserves its own height above this page
    /// (`DaylightBarController.reservedTopHeight`), so this is only the gap
    /// between that chrome and the hero - the pre-C1 value, which is what
    /// "sits directly under the page chrome" means here.
    static let contentTopMargin: CGFloat = HelmMetrics.s2

    // MARK: Forwarded actions (never owned)

    var onOpenDestination: ((RailDestination) -> Void)?
    var onOpenShiftTask: ((String) -> Void)?
    /// The greeting row's Refresh - wired to the *existing* refresh triggers
    /// (`FleetController.refreshIfNeeded()` and `ReviewController`'s own), so
    /// this page still starts no work of its own.
    var onRefresh: (() -> Void)?
    /// The Claude status card's own Refresh - wired to `FleetController`'s
    /// existing quota reading, forced past its freshness window.
    ///
    /// Separate from `onRefresh` because the hero's Refresh re-runs Overview's
    /// whole pass, and that pass takes the *cached* quota reading when it is
    /// under five minutes old (`FleetController.quotaFreshness`). That is
    /// right for a page visit and wrong for a captain pointing at this card
    /// and asking for the number again, so this one forces a fresh
    /// `quota-axi` run. Still not a fetch of this page's own (rule 1 in this
    /// file's header): it is a request to the controller that already owns
    /// the reading.
    var onRefreshQuota: (() -> Void)?
    /// The Console module's peek rows. A closure rather than a stored
    /// reference so this page never retains a console or learns about tabs.
    var consoleTabsProvider: (() -> [HelmModulePeekRow])?
    /// Which saved hosts have a live dedicated page, for the Hosts module.
    var connectedHostIDs: (() -> Set<UUID>)?
    /// The credential vault's state for its module card, as a closure for
    /// `connectedHostIDs`' own reason: this page must never construct a
    /// `CredentialVaultStore` (whose `init` reaches the production git sync -
    /// see `checkCanvasConstructsNoStores`), and it has no business holding a
    /// reference to one either. The shell owns the vault and answers with what
    /// it already knows.
    ///
    /// `count` is `nil` while the vault is locked, which is the honest answer:
    /// the number of credentials is inside the ciphertext, and a canvas card
    /// has no key. It is never guessed at and never rendered as zero.
    var credentialVaultState: (() -> (state: VaultLoadState, isUnlocked: Bool, count: Int?))?

    // MARK: State pushed in from elsewhere

    private var fleetSnapshot: FleetSnapshot?
    /// The Claude quota reading behind the `.claudeStatus` card.
    ///
    /// Pushed in, never fetched (rule 1 in this file's header):
    /// `QuotaSource.fetch()` shells out to `quota-axi` for 1-2s, and this
    /// page is re-rendered on every return from a drill page. `FleetController`
    /// already runs that fetch once per refresh cycle for the Morning
    /// briefing's `.quota` clause, so this card rides that same pass rather
    /// than adding a second one.
    ///
    /// `nil` means no reading has arrived yet; `quotaFailure` non-nil means
    /// one was attempted and could not be taken. GL-14: those are different
    /// states and the card says so differently - neither is drawn as a zero.
    private var quotaSnapshot: QuotaSnapshot?
    private var quotaFailure: String?
    /// When `quotaSnapshot` arrived - see `applyQuota`. `nil` until the first
    /// successful reading, which is exactly when the card has no freshness to
    /// state and so shows no caption at all rather than "Updated just now"
    /// about nothing.
    private var quotaFetchedAt: Date?
    /// `true` between the card's Refresh being pressed and the reading (or
    /// the stated reason there is none) coming back. Drives the header
    /// button's disabled in-flight state, and stops a second press stacking
    /// another forced subprocess on top of the first.
    ///
    /// Cleared in `applyQuota`, which `FleetController.refreshQuota` publishes
    /// on failure as well as on success - so this cannot wedge on a
    /// `quota-axi` that is offline or unauthenticated.
    private var isRefreshingQuota = false
    /// When `applyFleet` last delivered a reading - UX5's hero detail line.
    /// `nil` until the first one lands, which is the "reading now" state.
    private var fleetReadAt: Date?
    private var mergedPRs: [MergedPR]?
    private var prFetchFailure: String?
    /// `nil` until the engine has pushed one. The Dictation module then falls
    /// back to `DictationPermissions.currentStatus()` rather than assuming
    /// `.ready`: the engine only pushes on a *change*, so a hub rendered at
    /// launch on a machine that has never granted microphone access would
    /// otherwise show a confident "Ready" chip until the captain tried to
    /// dictate. That read is three synchronous authorization-status calls -
    /// no subprocess, no network - and is what `DictationController` seeds
    /// its own state from.
    private var pushedDictationStatus: DictationStatus?
    /// `nil` until the crew page has pushed one - i.e. until a conversation
    /// has actually moved. The card then reads as "no conversation yet",
    /// which is the honest state at launch rather than a fabricated summary.
    private var strawHatState: StrawHatCanvasState?

    private let sources: Sources
    private var space: DaylightSpace = .overview

    // MARK: Views

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// C1's hero: the state badge and its uppercase kicker.
    ///
    /// The audit's fix for "one top-left row and then 80% empty paper" is to
    /// give the hub a focal point - "the briefing/answer banner spanning full
    /// width with real presence (bigger type, the boat mark, weather-report
    /// energy) above the uniform card grid". The captain's approved visual
    /// shows exactly that: a mark, "Nothing needs you right now", the crew/PR
    /// detail line, and Refresh.
    ///
    /// It renders `FleetGreeting.Answer`, which Overview's own banner already
    /// computes - the same three-state decision and the same copy, not a
    /// second one - so the hero and the page it links to can never disagree.
    private let heroBadge = IconTileView(size: 40, cornerRadius: 12)
    private let kickerLabel = NSTextField(labelWithString: "")
    private var heroTint: HelmTint = .accent
    /// A filled accent pill, matching Setup > Updates' own "Refresh" - one
    /// real, shared, theme-aware definition rather than a page-local muted
    /// `.quiet` look.
    private let refreshButton = HelmButton(title: "Refresh", variant: .primary, symbol: "arrow.clockwise")
    /// Plan B's hero *band*: the surface the greeting row sits on.
    ///
    /// The captain reviewed C1's shipped vertical centring live and rejected
    /// it - content floating with an empty margin above *and* below reads as
    /// uncommitted rather than composed - and picked the finding's option (b)
    /// instead: "give the hub one full-width hero row ... above the uniform
    /// card grid", top-anchored, with leftover space trailing at the bottom.
    ///
    /// Only Overview has a verdict worth featuring. The other four spaces
    /// name themselves and nothing more, so there the band is transparent
    /// with no insets and the header renders as the plain row it already was
    /// - the change there is purely that it now sits at the top of the page.
    private let heroCard = NSView()
    private var heroCardInsets: [NSLayoutConstraint] = []
    /// The captain's "Needs Attention" card - the Today page's Due Today and
    /// Follow-ups sections, moved here and merged into one flat list.
    ///
    /// It sits between the hero and the module grid because that is where the
    /// mockup puts it and because it is the one thing on this page that is
    /// about the captain's own day rather than about the fleet - the grid
    /// below it is a navigation surface, and burying an overdue task in it
    /// would be exactly the "80% empty paper" problem C1's hero already
    /// answered once.
    ///
    /// Rule 1 of this file still holds: its rows come from
    /// `DailyReviewComposer` reading the **injected** `ShiftStore`'s
    /// already-loaded in-memory lists, which is the same read `fillTasks`
    /// makes two screens down. No store is constructed and nothing is
    /// fetched.
    private let attentionCard = NeedsAttentionCard()
    private let gridStack = NSStackView()

    private var cards: [HelmModuleCard] = []
    private var themeToken: ThemeObservation?
    private var signalCountsToken: BackgroundSignalsPoller.CountsObservation?
    private var windowResizeObserver: NSObjectProtocol?
    private var lastGridWidth: CGFloat = 0
    /// C1: the content column's preferred width, retuned on every grid
    /// rebuild from the column count the grid actually used.
    private var contentWidthConstraint: NSLayoutConstraint?
    /// Coalesces the render requests that arrive in bursts.
    ///
    /// Three of this page's inputs fire several times in quick succession by
    /// nature: `ServiceHealthRegistry` reports `markRunning` and then a
    /// verdict for each service in a poller pass, and a single dictation goes
    /// recording -> transcribing -> cleaning up -> ready in a few seconds.
    /// A render rebuilds fifteen cards, so answering every one of those
    /// individually would be real, visible work for a page whose content only
    /// changes once. One flag plus a main-queue hop collapses a burst into a
    /// single rebuild.
    private var renderPending = false

    init(sources: Sources) {
        self.sources = sources
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let signalCountsToken { BackgroundSignalsPoller.shared.unobserveCounts(signalCountsToken) }
        if let windowResizeObserver { NotificationCenter.default.removeObserver(windowResizeObserver) }
    }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        root.wantsLayer = true
        view = root

        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.lineBreakMode = .byTruncatingTail
        greetingLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.body()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (13): the hero is the largest type on the page and would be a
        // very effective window-width floor if left at the default.
        for label in [greetingLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        kickerLabel.font = HelmType.kicker()
        kickerLabel.lineBreakMode = .byTruncatingTail
        kickerLabel.translatesAutoresizingMaskIntoConstraints = false
        kickerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kickerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [kickerLabel, greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setCustomSpacing(4, after: kickerLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let greetingRow = NSStackView(views: [heroBadge, textStack, refreshButton])
        greetingRow.orientation = .horizontal
        greetingRow.alignment = .centerY
        greetingRow.distribution = .fill
        greetingRow.spacing = HelmMetrics.s4
        greetingRow.translatesAutoresizingMaskIntoConstraints = false

        heroCard.translatesAutoresizingMaskIntoConstraints = false
        heroCard.wantsLayer = true
        heroCard.addSubview(greetingRow)
        // Mutable, because the band's padding *is* the difference between a
        // hero and a plain page header: Overview's verdict gets a real card's
        // breathing room, and the four spaces with nothing to report get
        // zero, which puts their row back exactly where it renders today.
        heroCardInsets = [
            greetingRow.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor),
            greetingRow.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor),
            greetingRow.topAnchor.constraint(equalTo: heroCard.topAnchor),
            greetingRow.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor),
        ]
        NSLayoutConstraint.activate(heroCardInsets)

        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = Self.gridSpacing
        gridStack.distribution = .fill
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(heroCard)
        stack.addArrangedSubview(attentionCard)
        stack.addArrangedSubview(gridStack)

        attentionCard.onToggleDone = { [weak self] item in self?.markAttentionItemDone(item) }
        attentionCard.onOpenItem = { [weak self] item in self?.openAttentionItem(item) }
        // The hero band's Refresh, moved into the card that replaced the band
        // on this page - the same `refreshTapped`, so it still re-runs the
        // existing triggers rather than starting work of its own.
        attentionCard.onRefresh = { [weak self] in self?.refreshTapped() }

        // gotcha (9): `FlippedView`, never a plain `NSView` - y=0 must be the
        // top or short content rests against the bottom of the clip view.
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // gotcha (4): the *clip* view's width, never the scroll view's.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            // C1's horizontal half: the content column is centred and capped
            // to the width the grid actually needs, so a space with four
            // cards reads composed instead of left-flushed against a
            // one-sided void.
            //
            // Inequalities plus a 499 preferred width, never a required `==`
            // tie (gotcha (3)): a required equality here is a window-size
            // trap, and 499 keeps it under `NSLayoutPriorityWindowSizeStayPut`
            // (gotcha (13)). The cap is derived from the grid's own column
            // arithmetic rather than being a literal, so card size never
            // changes - only how much empty column is left over.
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: Self.gutter),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -Self.gutter),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),

            // Plan B's vertical half: the content is **top-anchored**, and
            // whatever the space cannot fill trails below it.
            //
            // C1 shipped the finding's option (a) here - the document held at
            // least as tall as the viewport, the content floating inside it
            // on a 499 centring tie. The captain used it and rejected it: a
            // page whose content has an empty margin above *and* below reads
            // as floating rather than composed. He picked option (b) instead,
            // which anchors the content to the top and answers the dead space
            // with a hero band rather than with symmetry.
            //
            // So this is deliberately back to the pre-C1 shape, and both of
            // these are **required equalities** rather than the inequalities
            // C1 needed to leave room to centre in. The bottom one is what
            // makes the document exactly as tall as its content, which is in
            // turn what makes a space taller than the viewport scroll - so it
            // is load-bearing, not symmetry for its own sake, and dropping
            // back to a `<=` here would leave the document's height undriven.
            //
            // `document.heightAnchor >= scroll.contentView.heightAnchor` is
            // gone with the centring it existed for, and must NOT come back
            // alongside these two: a document forced to fill a viewport it is
            // shorter than, while also being exactly its content's height, is
            // two required constraints in direct conflict.
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.contentTopMargin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -44),

            heroCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            attentionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            gridStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let contentWidth = stack.widthAnchor.constraint(equalToConstant: HelmResponsiveGrid.fallbackContainerWidth)
        contentWidth.priority = HelmDaylightPriority.contentTie
        contentWidth.isActive = true
        contentWidthConstraint = contentWidth

        // GL-20: registered globally (`object: nil`) the same way
        // `ToolsController.containerWidthMayHaveChanged` is, and gated on
        // visibility inside the handler for the same measured reason - a
        // resize while another destination is showing must not pay for this
        // page's relayout.
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.containerWidthMayHaveChanged() }

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }

        // `ServiceHealthRegistry.observe` is already an app-wide fan-out that
        // fires on the main queue - the Health module rides it rather than
        // asking the registry anything on a timer.
        ServiceHealthRegistry.shared.observe { [weak self] _ in
            guard let self, self.isViewLoaded, !self.view.isHidden else { return }
            self.setNeedsRender()
        }

        // Phase 3: the Setup and Vault modules render
        // `BackgroundSignalsPoller.lastCounts`, whose first pass lands ~10s
        // after launch - while the captain is looking at *this* page, since it
        // is the launch landing. Without this, both cards said "hasn't been
        // checked yet this session" for the whole session: no `viewWillAppear`
        // fires for a page already on screen, and nothing else this page
        // observes changes when a poll pass completes.
        //
        // This is a subscription to already-computed numbers, not a new poll.
        // The poller's cadence, its passes and its subprocesses are untouched -
        // see `observeCounts`'s own doc comment for why the notification-center
        // fan-out could not be reused here (a clean machine publishes nothing).
        //
        // Deliberately NOT gated on visibility, unlike the health observer
        // above: a first pass that lands while the captain is on a drill page
        // must still reach this page's cards, or returning to the hub would
        // show a stale "not checked yet" until something else forced a render.
        // The cost is one coalesced rebuild per poll pass - at most one per
        // 15 minutes.
        signalCountsToken = BackgroundSignalsPoller.shared.observeCounts { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            self.setNeedsRender()
        }

        render()
        // `ThemeManager.observe` fired synchronously above, before a single
        // card existed - the `refreshTheme()` convention (AGENTS.md's
        // ThemeManager checklist item 8).
        applyTheme(ThemeManager.shared.theme)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    // MARK: Space filter (§5.3)

    var selectedSpace: DaylightSpace { space }

    /// Switch the visible module set. Rebuilds rather than toggling
    /// `isHidden`: the row packing genuinely changes with the module count,
    /// and an `isHidden` card left in a row would still occupy its column
    /// (AGENTS.md gotcha (11) - only an `NSStackView`'s *arranged* subviews
    /// leave layout when hidden, and these live inside packed rows).
    func select(space newSpace: DaylightSpace) {
        // `fm/grandline-overview-page-daily-review`: a space that owns a
        // destination (`DaylightSpace.destination`) is a page, not a filter -
        // it has no modules and no greeting of its own, and the shell routes
        // it through `show(_:)` instead. Ignored here rather than rendered as
        // an empty grid, and ignored rather than trapped because a canvas is
        // presentation: the honest behaviour for "filter to a space that is
        // not a filter" is to keep the filter the captain last chose.
        guard newSpace.filtersCanvas else { return }
        guard newSpace != space else { return }
        space = newSpace
        render()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    // MARK: Data in (pushed, never fetched)

    /// Called by `AppShellController` whenever `FleetController`'s own refresh
    /// completes. That refresh already runs at launch and on every Overview
    /// visit, so the canvas gets real fleet numbers without asking for them.
    func applyFleet(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?, prFetchFailure: String?) {
        self.fleetSnapshot = snapshot
        // UX5: the hero's all-clear detail line is freshness now rather than a
        // restatement of the two cards below it - see `heroDetail`. This is
        // the moment the reading was taken.
        self.fleetReadAt = Date()
        self.mergedPRs = mergedPRs
        self.prFetchFailure = prFetchFailure
        guard isViewLoaded else { return }
        // Synchronous, unlike the two burst sources below: Overview's refresh
        // completes at most once per refresh cycle, so there is nothing to
        // coalesce, and rendering immediately keeps this page's numbers
        // observably in step with the page that produced them.
        render()
    }

    /// Called by `AppShellController` when `FleetController`'s refresh has a
    /// Claude quota reading (or a stated reason it has none). Same contract as
    /// `applyFleet`: the work was already done for another surface, and this
    /// page is a second reader of it rather than a second caller.
    func applyQuota(_ result: QuotaFetchResult) {
        isRefreshingQuota = false
        switch result {
        case .success(let snapshot):
            quotaSnapshot = snapshot
            quotaFailure = nil
            // When this reading actually landed, for the card's "Updated N
            // ago". `QuotaSnapshot` carries the call's *latency* but not the
            // instant, and the instant is the thing a captain needs to judge
            // whether the figures are worth acting on - a card that silently
            // shows a reading from two hours ago is the same class of
            // dishonesty GL-14 is about.
            quotaFetchedAt = Date()
        case .failure(let reason):
            // The last good reading is deliberately *not* cleared - a
            // transient failure should not blank a card that was correct a
            // minute ago. `fillClaudeStatus` prefers the snapshot and uses
            // the failure only when there has never been one, which is the
            // honest ordering: stale-but-real beats nothing, and nothing
            // beats a fabricated zero.
            quotaFailure = reason
        }
        guard isViewLoaded else { return }
        render()
    }

    /// The dictation engine already fans its status out to the Dictation page
    /// and the floating HUD; this is a third subscriber, not a new signal.
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3`: the Straw Hat
    /// Pirates card's summary, pushed from `StrawHatController`.
    ///
    /// Deliberately **not** gated on this page being visible, unlike
    /// `applyDictationStatus` below. Every state change here happens while the
    /// captain is on the crew page - i.e. while this canvas is hidden - so a
    /// visibility gate would mean the card still showed the previous
    /// conversation's summary when they came back. Phase 3 learned the same
    /// thing about the background-signals observer for the same reason. The
    /// stored value is always current; only the *render* waits.
    func applyStrawHat(_ state: StrawHatCanvasState) {
        strawHatState = state
        guard isViewLoaded else { return }
        setNeedsRender()
    }

    func applyDictationStatus(_ status: DictationStatus) {
        pushedDictationStatus = status
        guard isViewLoaded, !view.isHidden else { return }
        setNeedsRender()
    }

    // MARK: Render

    /// Ask for one render on the next main-queue turn, however many callers
    /// ask before it runs. See `renderPending`.
    private func setNeedsRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            guard self.isViewLoaded else { return }
            self.render()
        }
    }

    private func render() {
        renderGreeting()
        renderAttention()
        rebuildGrid()
        applyTheme(ThemeManager.shared.theme)
    }

    /// §5.4's copy. Overview reuses `FleetGreeting`'s time-of-day logic and
    /// the answer-banner summary Overview itself renders - the same two
    /// functions, not a second implementation - and every other space shows
    /// its own fixed pair.
    private func renderGreeting() {
        // C1: on every space the hero is badge + kicker + headline + detail.
        // Off Overview there is no fleet answer to report, so the space names
        // itself and the badge carries that space's own identity hue - never
        // a semantic tint, which would be claiming a state this page has not
        // measured.
        guard space == .overview else {
            heroCard.isHidden = false
            setHero(tint: nil,
                    symbol: space.heroSymbol,
                    kicker: "",
                    title: space.title,
                    detail: space.subtitle)
            return
        }
        // **The hub has no hero band any more.**
        //
        // `fm/grandline-home-page-visual-overhaul`: the captain's reference
        // draws one card at the top of Home - tile, eyebrow, headline,
        // freshness subline, Refresh - and the app drew two, a hero band
        // saying "Nothing needs you right now / Fleet read just now" over a
        // Needs Attention card saying "All clear / Nothing is due". Two cards
        // one above the other, each reporting a different half of the same
        // question, is exactly the duplication review #3's UX5 objected to on
        // this very page, and the reference resolves it by merging them.
        //
        // So on Overview the band is hidden - which for an *arranged* subview
        // really does take it out of the layout (gotcha (15)'s one such case)
        // - and `renderAttention` below builds the whole header from the same
        // `FleetGreeting.Answer` this function used to. Nothing was deleted:
        // every branch that used to `setHero` here now decides a field of
        // that card instead, and the four other spaces are untouched.
        heroCard.isHidden = true
    }

    /// The four header fields the merged attention card takes over from the
    /// hero band, for **Overview only**.
    ///
    /// Every branch below was a `setHero` call in `renderGreeting` before the
    /// merge, in the same order and with the same copy. What changed is only
    /// where the strings land: `title` becomes the card's all-clear headline
    /// (used when the list is empty, which is exactly when the old hero's
    /// title was the only thing on screen) and `detail` becomes its subline.
    ///
    /// A card with rows writes its own headline from those rows, so `title`
    /// is deliberately *not* forced on it - the reference's card says "Two
    /// things are late." over its list rather than repeating a fleet
    /// all-clear above rows that contradict it. The one verdict that must not
    /// be lost that way is a fleet that needs the captain, and that is not
    /// dropped either: it becomes a row of its own (see `fleetAttentionItem`),
    /// so it is counted, named in the headline and given a button.
    private func hubHeader(hasItems: Bool) -> (title: String, detail: String) {
        // Review #3's UX13: "a guided 'your first host / your first task'
        // empty state on the canvas" for a genuinely first-run state.
        //
        // **It must never hide a verdict that needs the captain**, which is
        // why this is not simply "no local data -> show the invitation". The
        // three stores it counts are *local* - saved hosts, tasks, sticky
        // notes - and none of them is what `FleetGreeting` reports on: a
        // crewmate can be parked on a decision while this machine has nothing
        // saved on it at all (a new Mac, a second user, a fresh clone), and a
        // cheerful "Welcome aboard" over a task that is blocked waiting for an
        // answer would be strictly worse than the all-clear this finding
        // already objects to.
        //
        // So a needs-you answer wins, and the invitation is shown only where
        // the header would otherwise be reporting nothing worth reading:
        // before the first fetch lands, or over a genuine all-clear. Caught
        // by `CanvasListsControlsSelfTest`'s C1 case, which mounts exactly
        // that combination - a parked fleet task over empty local stores.
        //
        // It is additionally safe under the merge for a second reason worth
        // stating: this title is only ever *shown* when the list is empty, so
        // an invitation cannot appear over rows that need doing even if the
        // guard above were ever weakened.
        let answerIfAny = overviewAnswer()
        let nothingUrgent = answerIfAny.map { $0.metaRestatesCards } ?? true
        // `hasItems` is the other half of the guard, and it is the one the
        // merge added. The invitation replaces **both** header strings, so
        // showing it over a list would put "Nothing is saved here yet" under
        // a headline counting rows - measured in an off-screen render, where
        // it read as two cards' worth of copy disagreeing with each other.
        if !hasItems, nothingUrgent,
           let firstRun = Self.firstRunHeroCopy(hosts: sources.hostStore.hosts.count,
                                                tasks: sources.shiftStore.activeTasks.count,
                                                notes: sources.stickyBoardStore.activeNotes.count) {
            return (firstRun.title, firstRun.detail)
        }
        guard let answer = answerIfAny else {
            // GL-14: nothing has been measured yet, so the header says so
            // rather than rendering an all-clear it cannot stand behind -
            // and the subline states the gap rather than claiming a
            // freshness for a reading that has not happened.
            return (FleetGreeting.timeOfDay(), "The fleet hasn\u{2019}t been read yet.")
        }
        return (answer.title, heroDetail(for: answer))
    }

    /// `FleetGreeting`'s verdict over the snapshot this page was handed, or
    /// `nil` before the first one arrives.
    ///
    /// One definition, called by both `hubHeader` and `fleetAttentionItem` -
    /// the headline and the row that backs it must be derived from the same
    /// answer or the card can count a verdict it is not showing.
    private func overviewAnswer() -> FleetGreeting.Answer? {
        fleetSnapshot.map {
            FleetGreeting.answer(tasks: $0.tasks,
                                 readyCount: mergedPRs.map(FleetDataSource.readyToMergeCount) ?? 0,
                                 prFetchFailure: prFetchFailure,
                                 homeOk: $0.homeOk)
        }
    }

    // MARK: Needs Attention (the captain's move of Today's Due Today)

    /// Build the card's rows from the **same digest** the Today page renders.
    ///
    /// The composer is `DailyReviewComposer`, unchanged and uncopied, so
    /// "due", "overdue", the ordering and the caps are one definition rather
    /// than two - which is the whole point of routing this through a digest
    /// instead of filtering `activeTasks` here. Only the sections this card
    /// owns are filled in; the calendar, the board and the reading list are
    /// left at their empty defaults because this card does not draw them and
    /// asking for them would mean this page reading three more sources.
    ///
    /// **Deliberately not gated on `AppSettings.dailyReviewEnabled` or the
    /// day's dismissal.** Those two switches are about the Today page's daily
    /// *review* - a briefing the captain may not want each morning. What is
    /// due and who is waiting is not a briefing; it is the app's only
    /// remaining home for that information now that the Today page's own
    /// columns are gone, and hiding it behind a review toggle would make
    /// turning the review off silently lose an overdue task.
    private func renderAttention() {
        // Only the hub itself. The other spaces are filters over the module
        // grid and have no day of their own to report on.
        guard space == .overview else {
            attentionCard.isHidden = true
            return
        }
        attentionCard.isHidden = false

        var inputs = DailyReviewInputs()
        inputs.now = Date()
        if sources.shiftStore.isInFailedLoadState {
            // GL-14/GL-01: "the store failed to parse" is not "nothing is
            // due", and the card renders it as a stated gap rather than as an
            // all-clear.
            let reason = "your tasks could not be read - a file in the Tasks store failed to parse"
            inputs.tasks = .unavailable(reason)
            inputs.followUps = .unavailable(reason)
        } else {
            inputs.tasks = .available(sources.shiftStore.activeTasks)
            inputs.followUps = .available(sources.shiftStore.followUps)
            var names: [String: String] = [:]
            for project in sources.shiftStore.projects { names[project.id] = project.name }
            inputs.projectNames = names
        }

        let digest = DailyReviewComposer.digest(from: inputs)
        let extra = signalAttentionItems()
        // Whether the card will draw a list, which is what decides both of
        // the header's strings - see `hubHeader`. Derived from the digest
        // rather than from the built summary so the header can be handed to
        // the composer in the same call that builds it.
        let hasItems = !digest.dueTasks.isEmpty || !digest.followUps.isEmpty || !extra.isEmpty
        let header = hubHeader(hasItems: hasItems)
        attentionCard.render(NeedsAttentionComposer.summary(from: digest,
                                                            extra: extra,
                                                            clear: clearNotes(),
                                                            allClearHeadline: header.title),
                             // The **fleet freshness** line now, not the
                             // digest's own "as of".
                             //
                             // Before the merge this card sat under a hero
                             // band that carried the freshness line, and its
                             // own subline said when the digest was composed
                             // - a defensible answer for a card about tasks,
                             // and a useless one for a card that is now the
                             // page's whole verdict: the digest is re-derived
                             // on every render, so that line could only ever
                             // say "a moment ago". The fleet is the one
                             // source here whose age the captain cannot
                             // otherwise tell, which is the same argument
                             // review #3's UX5 made for putting it in the
                             // hero in the first place.
                             subline: header.detail,
                             theme: ThemeManager.shared.theme)
    }

    // MARK: The three non-to-do attention rows

    /// The reference's other attention sources, in its own order.
    ///
    /// **Rule 1 of this file holds.** Not one of these reads a store, starts
    /// a poll or shells out: the fleet snapshot, the quota reading and
    /// `BackgroundSignalsPoller.lastCounts` are all state that was pushed
    /// into this page for cards it already draws. What is new is that the
    /// card at the top of the page now says so in words as well.
    private func signalAttentionItems() -> [NeedsAttentionItem] {
        [fleetAttentionItem(), claudeAttentionItem(), sessionChecksAttentionItem()]
            .compactMap { $0 }
    }

    /// The fleet, when it needs the captain.
    ///
    /// This is the row that keeps the hero band's strongest verdict alive
    /// through the merge.
    ///
    /// **The test is the answer's own tint, and `metaRestatesCards` is the
    /// wrong one.** That flag means "this answer's `meta` repeats the cards
    /// below it", which is a statement about the *detail line* and not about
    /// whether anything is wrong - and it is `true` on the partly-unknown
    /// branch, where the PR scan failed. Using it dropped that branch's row
    /// entirely, so a hub that could not reach the forge fell back to
    /// "All clear" over a reading it had not taken. That is GL-14's exact
    /// rule, and `DaylightModuleSelfTest` caught it.
    ///
    /// `tint == .good` is the one branch `FleetGreeting` paints green, and
    /// it is the only one that is genuinely an all-clear. The other three -
    /// crew parked on a decision, a PR scan that failed, a firstmate home
    /// that could not be found - are each a thing the captain should see.
    private func fleetAttentionItem() -> NeedsAttentionItem? {
        guard let answer = overviewAnswer(), answer.tint != .good else { return nil }
        return NeedsAttentionItem(
            id: "signal.fleet",
            kind: .signal(.fleet),
            source: answer.isSetupPrompt ? "Setup" : "Fleet",
            text: answer.title,
            meta: answer.meta,
            chipText: answer.kicker,
            // `.warn` rather than `.critical`: the crew is *holding*, which
            // is a state that wants the captain today and is not the same as
            // a task that is already five days late. The reference reserves
            // its red for what is genuinely overdue.
            tone: .risk,
            actionTitle: "Open",
            headlineClause: answer.title.prefix(1).lowercased() + answer.title.dropFirst())
    }

    /// Claude's extra usage, when it is at or near the spend cap.
    ///
    /// The threshold is `claudeSpendStatus`', not a second one: the card
    /// below already decides what "near cap" means, and a top-of-page row
    /// that disagreed with the card it points at would be worse than no row.
    private func claudeAttentionItem() -> NeedsAttentionItem? {
        guard let snapshot = quotaSnapshot,
              let status = Self.claudeSpendStatus(for: snapshot),
              status.state != .ok else { return nil }
        let fraction = Self.claudeSpendFraction(for: snapshot)
        let atCap = (fraction ?? 0) >= 1
        return NeedsAttentionItem(
            id: "signal.claude",
            kind: .signal(.claudeUsage),
            source: "Claude usage",
            text: atCap ? "Extra usage hit the spend cap" : "Extra usage is near the spend cap",
            meta: Self.claudeSubtitle(for: snapshot),
            // `claudeSpendFraction` is 0...1 and `percentText` takes a
            // *percentage*, which is the one unit mismatch on this path -
            // measured in an off-screen render, where a 94% cap reported
            // "1%" on the row beside a card correctly reading "94%".
            chipText: fraction.map { Self.percentText($0 * 100) } ?? status.text,
            tone: .risk,
            actionTitle: "View usage",
            headlineClause: atCap ? "Claude has hit its spend cap" : "Claude is near its spend cap")
    }

    /// The background checks that have not run yet this session.
    ///
    /// The three counts named are the three the Setup cards render, and the
    /// sentence is built from whichever of them is still `nil` rather than
    /// from a fixed list - so a pass that produced two of three says two,
    /// which is the honest reading and the one GL-14 asks for.
    private func sessionChecksAttentionItem() -> NeedsAttentionItem? {
        // **Not while the poller is warming up.** Its first pass lands about
        // ten seconds after launch, and this page is the launch landing - so
        // without this guard the hub would open on "Needs attention, 1: one
        // check is waiting" every single time, for ten seconds, about
        // nothing. That is a false alarm on the one card whose whole job is
        // to be believed.
        //
        // It is the same distinction `applyPendingSetupSignal` already draws
        // for the four Setup cards, which render a skeleton while a pass is
        // in flight and say so in words only once one has finished and
        // produced nothing: ordinary startup is not a fault, and a pass that
        // completed without a number is.
        guard !Self.pollerIsStillWarmingUp else { return nil }
        let counts = BackgroundSignalsPoller.shared.lastCounts
        var pending: [String] = []
        if counts.forkDrift == nil { pending.append("forks behind upstream") }
        if counts.toolUpdates == nil { pending.append("tool updates") }
        if counts.setupDrift == nil { pending.append("setup drift") }
        guard !pending.isEmpty else { return nil }
        return NeedsAttentionItem(
            id: "signal.checks",
            kind: .signal(.sessionChecks),
            source: "Session checks",
            text: Self.sentenceList(pending).prefix(1).uppercased()
                + Self.sentenceList(pending).dropFirst()
                + " haven\u{2019}t been checked yet this session",
            chipText: "\(pending.count) \(pending.count == 1 ? "check" : "checks") not run",
            tone: .info,
            actionTitle: "Open Setup")
    }

    /// "a", "a and b", "a, b, and c" - the reference's own joining.
    ///
    /// `static` and pure so the three-clause case can be asserted without a
    /// poller: it is the only one with a serial comma, and the only one a
    /// hand-rolled `joined(separator:)` gets wrong.
    static func sentenceList(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        }
    }

    /// The reference's closing strip: one phrase per source that was read and
    /// is fine.
    ///
    /// **A source that has not reported contributes nothing**, which is the
    /// whole discipline of this list: "Fleet idle" over a fleet that has
    /// never been read is a cheerful lie of exactly the kind GL-14 forbids,
    /// so every entry below is behind a `guard let` on the reading itself
    /// rather than behind a count being zero.
    private func clearNotes() -> [String] {
        var notes: [String] = []
        if let snapshot = fleetSnapshot,
           snapshot.tasks.allSatisfy({ $0.status != "working" }),
           snapshot.tasks.allSatisfy({ $0.status != "needs_decision" && $0.status != "blocked" }) {
            notes.append("Fleet idle")
        }
        let readings = ServiceHealthRegistry.shared.knownServices().map { service -> HealthServiceReading in
            let state = ServiceHealthRegistry.shared.state(service)
            return HealthServiceReading(title: service.title,
                                        verdict: state.verdict,
                                        hasReported: state.hasReported)
        }
        let health = Self.healthRingSummary(readings)
        if health.total > 0, health.value == health.total {
            notes.append("\(health.value)/\(health.total) services healthy")
        }
        if let snapshot = quotaSnapshot,
           let plan = Self.claudePlanLimitsStatus(for: snapshot), plan.state == .ok {
            notes.append("Claude plan limits comfortable")
        }
        return notes
    }

    /// The row checkbox. Writes through the **shared** store this page was
    /// given (GL-23) - a second `ShiftStore` would diverge from the Tasks
    /// page's within the session and race its writes.
    private func markAttentionItemDone(_ item: NeedsAttentionItem) {
        switch item.kind {
        case .task: sources.shiftStore.setTaskCompleted(id: item.id, completed: true)
        case .followUp: sources.shiftStore.setFollowUpStatus(id: item.id, done: true)
        // A signal row draws no checkbox at all (see `NeedsAttentionItem.
        // Kind.signal`), so nothing can reach this - and it is deliberately
        // a no-op rather than a `fatalError`: the honest behaviour for
        // "complete something that is not a to-do" is to do nothing, not to
        // crash the hub.
        case .signal: return
        }
        // The row has just left the list, so the card has to be re-derived
        // rather than left showing what it was handed.
        render()
    }

    /// The row's trailing "Start" / "Open". A task opens itself; a follow-up
    /// has no deep link of its own, so it opens the page that owns it; a
    /// signal opens the page that owns the thing it is reporting.
    private func openAttentionItem(_ item: NeedsAttentionItem) {
        switch item.kind {
        case .task: onOpenShiftTask?(item.id)
        case .followUp: onOpenDestination?(.shift)
        case .signal(let signal):
            switch signal {
            case .fleet: onOpenDestination?(.overview)
            // The same destination `follow(.quota)` already resolves to, and
            // the same one `DaylightModule.claudeStatus.opens` names: the
            // Claude-usage control lives on Console. Two callers, one answer.
            case .claudeUsage: onOpenDestination?(.console)
            case .sessionChecks: onOpenDestination?(.bootstrap)
            }
        }
    }

    /// The hero's detail line on **the hub**, which is the one surface that
    /// draws cards under it - review #3's UX5.
    ///
    /// The all-clear `meta` enumerates exactly the two cards immediately
    /// below the hero ("N crew working" is the Fleet card's subtitle, the PR
    /// clause is the Merge queue card, "nobody is parked" is the absence of
    /// the Fleet card's warn chip), so on this page it is the third statement
    /// of one fact. It is replaced with the one thing none of those cards can
    /// say: **how fresh the all-clear is**. "Nothing needs you" read four
    /// seconds ago and "nothing needs you" read forty minutes ago are
    /// genuinely different claims, and until now the hub gave a captain no way
    /// to tell them apart - the same shape of gap GL-14 is about.
    ///
    /// Every other branch keeps `meta` verbatim, and `FleetController`'s own
    /// banner is untouched - see `Answer.metaRestatesCards`.
    private func heroDetail(for answer: FleetGreeting.Answer) -> String {
        guard answer.metaRestatesCards else { return answer.meta }
        return "Fleet read \(Self.freshnessPhrase(since: fleetReadAt))."
    }

    /// "just now" / "4 minutes ago" / "at 09:14" - deliberately coarse.
    ///
    /// A ticking seconds counter on a hub a captain leaves open all day would
    /// be motion for its own sake (and `HelmMotion`'s whole point is that this
    /// app does not do that); this line is re-derived when the fleet is read
    /// and when the canvas re-renders, which is exactly when the answer
    /// changes in a way worth reading.
    static func freshnessPhrase(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "just now" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) minutes ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "at \(formatter.string(from: date))"
    }

    /// What the hub says to a captain who has not put anything in yet -
    /// review #3's UX13. `nil` once they have, which is the overwhelmingly
    /// common case and the reason this is a guard rather than a mode.
    ///
    /// **Three stores, all empty**, deliberately - not one. A captain with
    /// tasks but no hosts is not new, they just do not use hosts; showing
    /// them "add your first host" would be the app misreading its own user.
    /// The condition is "this app has never been used", and the honest test
    /// for that is that nothing at all has been put into it.
    ///
    /// Pure and `static` so `DaylightModuleSelfTest` can assert both
    /// directions without a canvas - and the second direction is the one that
    /// matters, since a first-run banner that outstayed its welcome would be
    /// a permanent fixture on a working captain's hub.
    ///
    /// A `nil` tint at the call site is load-bearing: this is an invitation,
    /// not a verdict, and `setHero` drops the surface and the kicker for a
    /// `nil` tint precisely so a hero that has measured nothing cannot look
    /// like one reporting good news.
    static func firstRunHeroCopy(hosts: Int, tasks: Int, notes: Int) -> (title: String, detail: String)? {
        guard hosts == 0, tasks == 0, notes == 0 else { return nil }
        return (title: "Welcome aboard",
                detail: "Nothing is saved here yet. Add your first host (\u{2318}\u{2303}N) to keep a "
                    + "connection, or your first task (\u{2318}N) to keep a to-do. "
                    + "\u{2318}\u{21E7}D shows every page this app has.")
    }

    /// The hero's four strings and its badge, from one place.
    ///
    /// A `nil` tint means "this is an identity, not a verdict": the badge
    /// takes the space's own domain hue and the kicker is dropped, so a space
    /// that has measured nothing cannot look like it is reporting good news.
    private func setHero(tint: HelmTint?,
                         symbol: String,
                         kicker: String,
                         title: String,
                         detail: String) {
        // `.neutral` is the one slot that claims nothing - deliberately not
        // a domain hue's `fallbackTint`, which resolves rose to `.critical`
        // and would paint an alert bar on a space that has reported nothing.
        heroTint = tint ?? .neutral
        heroBadge.configure(symbol: symbol, tint: heroTint, pointSize: 17)
        kickerLabel.stringValue = kicker.uppercased()
        kickerLabel.isHidden = kicker.isEmpty
        greetingLabel.stringValue = title
        subtitleLabel.stringValue = detail
        heroBadge.applyTheme(ThemeManager.shared.theme)
    }

    private func visibleModules() -> [DaylightModule] {
        DaylightModule.canvasOrder.filter { $0.isVisible(in: space) }
    }

    private func rebuildGrid() {
        for row in gridStack.arrangedSubviews {
            gridStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        cards.removeAll()

        let available = gridContainerWidth()
        lastGridWidth = available
        let modules = visibleModules()

        // Overview is hand-placed - see `dashboardRowViews` for why, and for
        // the two conditions under which it declines and this falls through
        // to the wrapping grid below.
        if usesDashboardLayout,
           let rows = dashboardRowViews(available: available, modules: modules) {
            // The dashboard uses the full width by construction: its spans
            // sum to the whole track grid, so there is no leftover column to
            // turn into margin the way `composedContentWidth` does for a
            // space with fewer cards than columns.
            contentWidthConstraint?.constant = available
            for row in rows {
                gridStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
            }
            return
        }

        // C1: use only as many columns as this space has cards to fill, and
        // let the column that is left over become margin on both sides
        // instead of a one-sided void on the right.
        //
        // The card *size* is unchanged - `unit` is still derived from the
        // full available width and the full column count, which is what the
        // captain's uniform-height decision (and the uniform-width rule that
        // came with it) rests on. Only how many of those columns the content
        // occupies changes.
        let width = Self.composedContentWidth(available: available, modules: modules)
        contentWidthConstraint?.constant = width

        // `spanningRows(_:)`, not `rows(_:)`: the Morning briefing spans two
        // columns and every other module spans one (`DaylightModule.gridSpan`).
        // Uniform *width* still comes from the layout rather than from
        // anything a card asks for - a span-1 card is exactly one column in
        // every row - and this path carries the same partial-row padding that
        // stops a lone leftover card stretching, expressed in columns rather
        // than cells. Uniform *height* is per row (`equalHeights` below):
        // full review #3's PF2 turned `HelmModuleCard`'s fixed height into a
        // floor, so a row of one-line cards is now as short as its content.
        let rows = HelmResponsiveGrid.spanningRows(
            modules,
            spans: { $0.gridSpan },
            containerWidth: width,
            minItemWidth: Self.minModuleWidth,
            spacing: Self.gridSpacing,
            // PF2: a card is content-sized now, so uniformity is per row.
            equalHeights: true,
            // ...with one exception per `DaylightModule.sizesToOwnContent`:
            // the Claude usage card renders at its own taller height rather
            // than dragging the cards beside it up to match it.
            exemptsHeightTie: { $0.sizesToOwnContent }
        ) { [weak self] module, cardWidth in
            guard let self else { return NSView() }
            return self.makeCard(for: module, cardWidth: cardWidth)
        }

        for row in rows {
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
        }
    }

    // MARK: Overview's dashboard layout

    /// The hub's five widgets, in the reference's own order and with its own
    /// track spans.
    ///
    /// **Why Overview has a hand-placed layout and the other four spaces do
    /// not.** The wrapping grid is right for a shelf of interchangeable
    /// navigation cards, which is what Command, Operations, Stores and
    /// Engineering are: a card there is one of N equivalent doors, and the
    /// window's width should decide how many fit on a line. Overview is not
    /// that. It is five specific readouts whose relative sizes are the
    /// design - the Claude card carries a six-row usage report and earns the
    /// wide column, the Fleet and Health cards carry one figure each and do
    /// not - and letting the window decide is what produced the ragged
    /// masonry the captain rejected (at 1512pt the wrapping grid resolved to
    /// five 255pt columns and packed the same five cards 2+2+1 / 1+1, with
    /// most of the third row empty).
    ///
    /// Two rows of two, at the reference's 7:5. The reference expresses the
    /// same thing as a twelve-track CSS grid with the Claude card spanning
    /// two rows; a card spanning two rows *beside a column holding exactly
    /// those two rows' cards* is the same layout, and this shape is the one
    /// Auto Layout can state without a second axis of placement.
    private static let dashboardRows: [[DaylightModule]] = [
        [.claudeStatus, .briefing],
        [.mergeQueue, .health],
    ]
    /// The right column of row 1: the two cards the reference stacks beside
    /// the tall Claude card.
    private static let dashboardStacked: [DaylightModule] = [.briefing, .fleet]
    /// Track spans out of `HelmResponsiveGrid.dashboardColumns`, per row.
    private static let dashboardSpans = [7, 5]

    /// Is this space laid out by hand? Only the hub.
    private var usesDashboardLayout: Bool { space == .overview }

    /// Overview's five cards, in the reference's placement.
    ///
    /// Returns `nil` when the modules on screen are not the five this layout
    /// was written for - which is not a defensive flourish: `DaylightModule.
    /// appearsOnOverview` is a captain-editable list, and a sixth card added
    /// there must render *somewhere* rather than silently vanish. The caller
    /// falls back to the wrapping grid, which is what every other space uses
    /// and what Overview used before.
    /// The two conditions `dashboardRowViews` takes, as a predicate.
    ///
    /// Split out so the layout and anything asking "is the dashboard on"
    /// cannot answer differently - a `usesDashboard` flag set beside the
    /// build is exactly the shape that drifts.
    func dashboardRowViewsWouldApply(available: CGFloat, modules: [DaylightModule]) -> Bool {
        let expected = Set(Self.dashboardRows.flatMap { $0 } + Self.dashboardStacked)
        guard Set(modules) == expected else { return false }
        // Under this width a 5-track card is narrower than one wrapping
        // column, which is the point at which the reference collapses every
        // widget to full width - so hand back to the wrapping grid, which
        // already does exactly that.
        return HelmResponsiveGrid.fitsProportionally(containerWidth: available,
                                                     spans: Self.dashboardSpans,
                                                     minItemWidth: Self.minModuleWidth,
                                                     spacing: Self.gridSpacing)
    }

    private func dashboardRowViews(available: CGFloat, modules: [DaylightModule]) -> [NSStackView]? {
        guard dashboardRowViewsWouldApply(available: available, modules: modules) else { return nil }

        func card(_ module: DaylightModule, span: Int) -> HelmModuleCard {
            makeCard(for: module,
                     cardWidth: HelmResponsiveGrid.proportionalWidth(containerWidth: available,
                                                                     span: span,
                                                                     spacing: Self.gridSpacing))
        }

        var rows: [NSStackView] = []
        for (index, modulesInRow) in Self.dashboardRows.enumerated() {
            var views: [NSView] = []
            for (column, module) in modulesInRow.enumerated() {
                let span = Self.dashboardSpans[column]
                guard index == 0, column == 1 else {
                    views.append(card(module, span: span))
                    continue
                }
                // The reference's right-hand column of row 1: two cards
                // stacked in the space the tall Claude card occupies beside
                // them. A vertical stack rather than two grid rows, because
                // that is what makes the stack's *total* height the thing
                // tied to the Claude card - which is what puts the bottom of
                // the Fleet card and the bottom of the Claude card on one
                // line, exactly as the reference draws it.
                let column = NSStackView(views: Self.dashboardStacked.map { card($0, span: span) })
                column.orientation = .vertical
                column.alignment = .leading
                column.distribution = .fillEqually
                column.spacing = Self.gridSpacing
                column.translatesAutoresizingMaskIntoConstraints = false
                // gotcha (12)+(13): the stack-level APIs, both yielding, or
                // this column is a window-width floor.
                column.setHuggingPriority(.defaultLow, for: .horizontal)
                column.setClippingResistancePriority(.defaultLow, for: .horizontal)
                for card in column.arrangedSubviews {
                    let tie = card.widthAnchor.constraint(equalTo: column.widthAnchor)
                    tie.priority = HelmDaylightPriority.contentTie
                    tie.isActive = true
                }
                views.append(column)
            }
            rows.append(HelmResponsiveGrid.proportionalRow(views: views,
                                                           spans: Self.dashboardSpans,
                                                           containerWidth: available,
                                                           spacing: Self.gridSpacing))
        }
        return rows
    }

    private func makeCard(for module: DaylightModule, cardWidth: CGFloat) -> HelmModuleCard {
        let card = HelmModuleCard()
        card.configure(content(for: module, cardWidth: cardWidth))
        card.onOpen = { [weak self] in self?.onOpenDestination?(module.opens) }
        card.onFollowLink = { [weak self] target in self?.follow(target) }
        cards.append(card)
        return card
    }

    /// The briefing's clause links.
    ///
    /// The same targets `FleetController.activateBriefingClause` resolves, with
    /// two honest differences the canvas cannot avoid: `.fleet` scrolls
    /// Overview's own "In flight" section into view there, and here it simply
    /// opens Overview; `.quota` anchors its popover on Overview's briefing
    /// card, and here the nearest true equivalent is the Console page, where
    /// the Claude-usage control actually lives. Neither invents a
    /// destination - both open the page that owns the thing the clause is
    /// about.
    private func follow(_ target: BriefingTarget) {
        switch target {
        case .none: return
        case .fleet: onOpenDestination?(.overview)
        case .review: onOpenDestination?(.review)
        case .tasks:
            if let id = AppSettings.shared.morningBriefingRecord?.shiftTaskID {
                onOpenShiftTask?(id)
            } else {
                onOpenDestination?(.shift)
            }
        case .setup: onOpenDestination?(.bootstrap)
        case .updates: onOpenDestination?(.updates)
        case .githubSync: onOpenDestination?(.githubSync)
        case .quota: onOpenDestination?(.console)
        }
    }

    // MARK: Layout

    /// The width C1's content column should occupy: the grid's own column
    /// arithmetic, capped at the number of columns this space's cards can
    /// actually fill.
    ///
    /// Pure and `static` so the self-test can assert the arithmetic without
    /// mounting a page - the interesting cases are "fewer cards than columns"
    /// (Command: compose) and "more cards than columns" (Overview: unchanged,
    /// full width), and neither needs a window to check.
    static func composedContentWidth(available: CGFloat, modules: [DaylightModule]) -> CGFloat {
        guard available > 0, !modules.isEmpty else { return max(available, 0) }
        let maxColumns = HelmResponsiveGrid.columns(containerWidth: available,
                                                    minItemWidth: minModuleWidth,
                                                    spacing: gridSpacing)
        let spansNeeded = modules.reduce(0) { $0 + max(1, $1.gridSpan) }
        let used = min(maxColumns, spansNeeded)
        guard used < maxColumns else { return available }
        let unit = HelmResponsiveGrid.itemWidth(containerWidth: available,
                                                columns: maxColumns,
                                                spacing: gridSpacing)
        return unit * CGFloat(used) + gridSpacing * CGFloat(used - 1)
    }

    private func gridContainerWidth() -> CGFloat {
        let clip = scroll.contentView.bounds.width
        let usable = clip - Self.gutter * 2
        return usable > 0 ? usable : HelmResponsiveGrid.fallbackContainerWidth
    }

    /// GL-20's gate: only relay out when this page is actually on screen, and
    /// only when the width genuinely changed. A resize fires many times per
    /// drag; rebuilding fifteen cards on every frame of one is the exact
    /// regression `ToolsController` measured (~3.6ms -> ~20ms per frame).
    private func containerWidthMayHaveChanged() {
        guard isViewLoaded, !view.isHidden else { return }
        let width = gridContainerWidth()
        guard abs(width - lastGridWidth) > 0.5 else { return }
        rebuildGrid()
        applyTheme(ThemeManager.shared.theme)
    }

    private func scrollToTop() {
        guard let clip = scroll.contentView as NSClipView? else { return }
        clip.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func refreshTapped() {
        onRefresh?()
        render()
    }

    /// The Claude card's Refresh. The subprocess itself runs on
    /// `FleetController`'s own quota queue (GL-04/GL-12) - nothing here
    /// blocks, and this page still starts no work it owns.
    private func refreshQuotaTapped() {
        guard !isRefreshingQuota else { return }
        isRefreshingQuota = true
        // `setNeedsRender`, not `render()`: a render rebuilds every card, and
        // this is running *inside* the button's own target/action - tearing
        // the button out of the view hierarchy from its own action is the
        // shape of bug this codebase has already paid for once
        // (`TabChipView.beginRename`, AppKit gotcha (1)). Coalesced to the
        // next main-thread turn, which is still before the subprocess can
        // answer, so the button is visibly disabled either way.
        setNeedsRender()
        onRefreshQuota?()
    }

    private func applyTheme(_ theme: HelmTheme) {
        // `ThemeManager.swift`'s checklist item 2. Every layer fill below
        // tracks the theme on its own; this is what makes the *system-
        // semantic* colours in this subtree (a scroller's track and knob, an
        // `NSMenu` popped from a card, a focus ring) resolve against the Helm
        // theme instead of the OS's own light/dark setting. Asserted for every
        // destination by `DestinationMountingSelfTest.everyDestinationForces
        // ItsOwnAppearance`, which hosts each page in a deliberately
        // opposite-appearance window so inheriting from the themed main
        // window cannot make the check pass vacuously.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        paintHeroBand(theme)
        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        // Plain `body()` on every space now. The step up to `sectionTitle()`
        // belonged to the hub's hero band, whose detail line carried real
        // numbers; the four spaces that still draw this row only name
        // themselves, and the verdict's own detail line moved to the merged
        // attention card (`hubHeader`).
        subtitleLabel.font = HelmType.body()
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        // C1's hero. The kicker is `mutedInk`, never the hero's own tint:
        // a `HelmTint` is safe as a fill or a bar and is *not* automatically
        // safe as text (`HelmContrast`'s own rule, and the §5.7 defect this
        // app has fixed three times). The tint reaches the badge, which is
        // contrast-guarded by `IconTileView`, and stops there.
        kickerLabel.font = HelmType.kicker()
        kickerLabel.textColor = HelmTheme.mutedInk(theme)
        heroBadge.applyTheme(theme)
        attentionCard.applyTheme(theme)
        for card in cards { card.applyTheme(theme) }
    }

    /// Plan B's band: a real card surface, washed with the verdict's own hue.
    ///
    /// The captain's approved mockup draws the hero as a tinted band with its
    /// own border sitting directly under the page chrome, with the card grid
    /// immediately below - so the hue reaches a *fill* and a *border* and
    /// stops there. It never reaches the copy: a `HelmTint` is safe as a fill
    /// and is not automatically safe as text (`HelmContrast`'s own rule, and
    /// the §5.7 defect this app has fixed four times).
    ///
    /// The border alpha and the flattening are `HelmAccentRow`'s, not a
    /// second recipe - the band is the same idiom that class already uses for
    /// a row carrying a signal, one level up. `HelmContrast.mix`, never
    /// `NSColor.blended`: that method converts into a *calibrated* space
    /// first, so its result drifts from the straight-sRGB composite alpha
    /// compositing actually performs (Phase 4's segmented-tabs lesson).
    /// The hero row's chrome, on the four spaces that still have one.
    ///
    /// **It is a plain row, not a band, and no longer has a second mode.**
    /// C1 gave the hub a hero *band* - a washed surface in the verdict's own
    /// hue, with a border, a corner radius and `heroBandPadding` of room -
    /// and the hub is the only space that ever raised one, because it was
    /// the only one with a verdict to feature.
    /// `fm/grandline-home-page-visual-overhaul` moved that verdict into the
    /// merged attention card (see `hubHeader`), so the band had no remaining
    /// caller and its whole derivation - the wash ladder, the per-theme
    /// contrast search that picked a step, and the padding that made a row
    /// into a card - was unreachable code that no case could have failed
    /// against. It is deleted rather than left behind a flag that is now
    /// always false.
    ///
    /// What is left is what the other four spaces always rendered.
    private func paintHeroBand(_ theme: HelmTheme) {
        for constraint in heroCardInsets { constraint.constant = 0 }
        heroCard.layer?.backgroundColor = NSColor.clear.cgColor
        heroCard.layer?.borderWidth = 0
        heroCard.layer?.cornerRadius = 0
    }

    // MARK: Module content (§6.1's table)

    /// `cardWidth` is the width the grid built this card for. Only the
    /// briefing reads it, and only to size its paragraph - see `fillBriefing`.
    private func content(for module: DaylightModule, cardWidth: CGFloat) -> HelmModuleCard.Content {
        var content = HelmModuleCard.Content(
            title: module.title,
            subtitle: "",
            symbol: module.symbol,
            hue: module.hue,
            chip: nil,
            body: .note(""))

        switch module {
        case .briefing: fillBriefing(&content, cardWidth: cardWidth)
        case .claudeStatus: fillClaudeStatus(&content, cardWidth: cardWidth)
        case .fleet: fillFleet(&content)
        case .strawHat: fillStrawHat(&content)
        case .tasks: fillTasks(&content)
        case .mergeQueue: fillMergeQueue(&content)
        case .console: fillConsole(&content)
        case .health: fillHealth(&content)
        case .hosts: fillHosts(&content)
        case .updates: fillUpdates(&content)
        case .bootstrap: fillBootstrap(&content)
        case .automation: fillAutomation(&content)
        case .githubSync: fillGitHubSync(&content)
        case .schedules: fillSchedules(&content)
        case .logAnalyzer: fillLogAnalyzer(&content)
        case .kubernetes: fillKubernetes(&content)
        case .vault: fillVault(&content)
        case .poneglyph: fillPoneglyph(&content)
        case .docs: fillDocs(&content)
        case .notebook: fillNotebook(&content)
        case .readingList: fillReadingList(&content)
        case .runbooks: fillRunbooks(&content)
        case .postmortems: fillPostmortems(&content)
        case .dictation: fillDictation(&content)
        case .tools: fillTools(&content)
        case .whiteboard: fillWhiteboard(&content)
        case .stickyBoard: fillStickyBoard(&content)
        case .codePreview: fillCodePreview(&content)
        case .commandLibrary: fillCommandLibrary(&content)
        case .settings: fillSettings(&content)
        }
        return content
    }

    /// F12's record, read straight out of `AppSettings` - already generated,
    /// never regenerated here. A canvas that could trigger a `claude -p` call
    /// would be a new cost on every visit.
    // GL-P3: built once. `DateFormatter` construction is measurably
    // expensive and this carries no per-call state - the same treatment
    // `FleetLogFeed`/`HealthCardView` already give theirs.
    private static let briefingTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private func fillBriefing(_ content: inout HelmModuleCard.Content, cardWidth: CGFloat) {
        guard let record = AppSettings.shared.morningBriefingRecord, !record.clauses.isEmpty else {
            content.subtitle = AppSettings.shared.morningBriefingEnabled
                ? "not generated yet today"
                : "off in Settings"
            content.body = .note(AppSettings.shared.morningBriefingEnabled
                ? "Your first briefing of the day appears here."
                : "Turn on Morning briefing in Settings to get one short summary each morning.")
            return
        }
        content.subtitle = "generated \(Self.briefingTimeFormatter.string(from: record.generatedAt))"
        content.chip = record.isDegraded ? .warn("offline") : .mute("\(record.sources.count) sources")

        // Two columns wide again, and still bounded - see
        // `HelmModuleCard.maxBriefingClauses` for why the cap survives the
        // extra width (the card's height is fixed now) and why the number went
        // from three to five. An overflow is stated rather than dropped in
        // silence - a card that quietly showed five of eight clauses would
        // read as "that is the whole briefing", which is exactly the "no
        // silent caps" failure. The trailing line is a plain `.none`-target
        // clause, so it renders as text inside the same paragraph and needs no
        // new mechanism.
        var clauses = Array(record.clauses.prefix(Self.briefingClauseCap(forCardWidth: cardWidth)))
        let hidden = record.clauses.count - clauses.count
        if hidden > 0 {
            clauses.append(BriefingClause(text: "+\(hidden) more on Fleet.", target: .none))
        }
        content.body = .paragraph(clauses)
    }

    /// How many clauses the briefing's paragraph may carry on a card of this
    /// width.
    ///
    /// A span-2 card is at least two minimum columns plus the gap between
    /// them, so anything narrower than that is a briefing `packRows` degraded
    /// to one column in a single-column grid - and its paragraph has to shrink
    /// with it or it overflows the fixed card height and is clipped.
    static func briefingClauseCap(forCardWidth width: CGFloat) -> Int {
        let spanTwo = minModuleWidth * 2 + gridSpacing
        return width + 0.5 >= spanTwo
            ? HelmModuleCard.maxBriefingClauses
            : HelmModuleCard.maxNarrowBriefingClauses
    }

    // MARK: The Claude usage report

    /// The captain's picked usage report: a header carrying the plan, one
    /// overall verdict and the reading's age, then a "Plan limits" section
    /// with one full-width bar per window, then an "Extra usage" section
    /// showing the spend against its cap.
    ///
    /// It replaced a five-column "Status strip"
    /// (`docs/history/07-fleet-and-notifications.md` has that shape's own
    /// history). The card is taller than the strip was, deliberately and on
    /// the captain's own instruction - `HelmModuleCard.minimumHeight` is a
    /// floor rather than a fixed height, so it simply grows.
    ///
    /// **The two labelling decisions this card is built on**, both carried
    /// forward from the design exploration the captain picked a mockup from
    /// (`docs/history/07-fleet-and-notifications.md` records the reasoning):
    ///
    ///  - The five-hour window is **"Session (5h)"**, never "Daily". Claude's
    ///    quota has no daily window and `quota-axi` reports none - the window
    ///    is `five_hour`, which the tool itself labels `session`. Naming it
    ///    "Daily" would be a claim about a reset cadence that does not exist.
    ///  - The credit pool is **"Extra usage"** against a **"Spend cap"**,
    ///    never "MTD spend". Its window id is `extra_usage` and its kind is
    ///    `credits`; `quota-axi` returns `pace: {status: "unknown", reason:
    ///    "missing_cycle"}` for it, so it does not know the billing cycle's
    ///    boundaries and nothing derived from it may honestly say "month to
    ///    date". True organisation month-to-date spend would need Anthropic's
    ///    Admin/Usage API and an Admin key, which this app does not have.
    ///
    /// GL-14 runs through the whole card: every window is independently
    /// optional, and one this account's response does not carry renders
    /// "Not reported" in the muted face with no bar at all - never a `0%` or
    /// a `$0`, which on a quota readout are real and alarming values rather
    /// than synonyms for "unknown".
    private func fillClaudeStatus(_ content: inout HelmModuleCard.Content, cardWidth: CGFloat) {
        // On every state, including the two below: the one moment a captain
        // most wants to re-take a reading is when the card is stating a gap.
        content.headerAction = HelmModuleCard.HeaderAction(
            symbol: "arrow.clockwise",
            tooltip: isRefreshingQuota
                ? "Reading the Claude quota\u{2026}"
                : "Refresh the Claude quota",
            isBusy: isRefreshingQuota,
            handler: { [weak self] in self?.refreshQuotaTapped() })

        guard let snapshot = quotaSnapshot else {
            // Two genuinely different states, and they read differently.
            if let failure = quotaFailure {
                content.subtitle = "no reading"
                content.chip = .warn("unavailable")
                content.body = .note(failure)
            } else {
                content.subtitle = "reading"
                content.body = .skeleton(rows: 2)
            }
            return
        }

        let compact = Self.claudeUsageIsCompact(forCardWidth: cardWidth)
        content.subtitle = Self.claudeSubtitle(for: snapshot)
        // **A compact card's header is identity and Refresh, nothing else**,
        // and that is a design call rather than a shrug at a layout problem.
        // Measured at a one-column card's 255pt: the tile, a "Near spend
        // cap" pill, the freshness caption and the Refresh leave the
        // identity column about 60pt, which renders the plan as "Team p...".
        // Two things have to go, and these are the two that are said twice:
        // both section verdicts ("Comfortable", "Near cap") are painted in
        // full a few points below the pill, and the freshness moves to the
        // card's own hover text, which AppKit also serves to VoiceOver as
        // the card's accessibility help (GL-16). The plan name is said
        // nowhere else at all, which is why it is what survives.
        let updated = quotaFetchedAt.map { Self.claudeUpdatedText(fetchedAt: $0) }
        content.chip = compact ? nil : Self.claudeChip(for: snapshot)
        content.headerCaption = compact ? nil : updated
        if compact { content.toolTip = updated }
        content.body = .usageReport(Self.claudeUsageSections(for: snapshot), compact: compact)
    }

    /// Whether this card is narrow enough to need the report's stacked
    /// reflow rather than its aligned four-column grid.
    ///
    /// The same threshold `claudeStripColumnsPerRow` used, and for the same
    /// reason: `HelmResponsiveGrid.packRows` degrades a span-2 card to one
    /// column in a single-column grid, and at that width the grid's three
    /// content columns leave the bar a stub. This is the direct analogue of
    /// the mockup's own `@media (max-width: 560px)` rule, which reflows the
    /// same four fields the same way - title and figure on one line, the bar
    /// full width beneath, the reset caption under that.
    ///
    /// The card pays height, never a reading. Nothing is dropped in either
    /// layout, which is the property the strip already had when it wrapped.
    static func claudeUsageIsCompact(forCardWidth width: CGFloat) -> Bool {
        let spanTwo = minModuleWidth * 2 + gridSpacing
        return width + 0.5 < spanTwo
    }

    /// The report's two sections, in the mockup's order. `static` so a suite
    /// can assert the mapping from a fabricated snapshot without mounting a
    /// canvas.
    ///
    /// GL-14 runs through the whole function exactly as it ran through
    /// `claudeStripColumns` before it: every window is independently
    /// optional, and one this account's response does not carry renders
    /// "Not reported" in the muted caption face with no bar at all - never a
    /// `0%` or a `$0`, which on a quota readout are real and alarming values
    /// rather than synonyms for "unknown".
    static func claudeUsageSections(for snapshot: QuotaSnapshot,
                                    now: Date = Date()) -> [HelmModuleUsageSection] {
        func row(_ title: String, _ window: QuotaWindow?) -> HelmModuleUsageRow {
            guard let window else {
                return HelmModuleUsageRow(title: title, value: "Not reported",
                                          fill: nil, state: .idle, isGap: true)
            }
            return HelmModuleUsageRow(
                title: title,
                value: percentText(window.percentUsed),
                fill: max(0, min(1, window.percentUsed / 100)),
                state: QuotaSeverity(percentUsed: window.percentUsed).moduleRowState,
                // Both forms, deliberately: the short one is painted beside
                // the bar and the long one stays on the hover and the
                // accessibility label, so the full date is still one hover
                // away. Both are `nil` for a window carrying no reset
                // instant, which passes through as no caption and no
                // affordance rather than a fabricated one.
                //
                // **The `Resets` prefix is the redesign's own addition**, and
                // it is the mockup's wording. In the strip the compact time
                // sat directly under a column headed SESSION (5H), which
                // said what it was; here it sits at the card's right edge
                // with a bar between it and its row's title, and a bare
                // "10:30 PM" out there could be anything. The mockup also
                // carries a live countdown ("in 2h 14m") which this card
                // deliberately does not: a counting figure needs one
                // injectable clock on a controller that ticks it (AGENTS.md),
                // and nothing on this canvas ticks - a countdown rendered
                // once at build time and then left to go stale would be
                // worse than the instant it replaced.
                caption: window.resetsCompact(now: now).map { "Resets \($0)" },
                detail: window.resetsSentence)
        }

        let rows = [
            row("Session (5h)", snapshot.session),
            row("Week", snapshot.weekly),
            row("Fable week", snapshot.fable),
        ]

        var sections: [HelmModuleUsageSection] = [
            HelmModuleUsageSection(title: "Plan limits",
                                   status: claudePlanLimitsStatus(for: snapshot),
                                   content: .limits(rows)),
        ]
        sections.append(HelmModuleUsageSection(title: "Extra usage",
                                               status: claudeSpendStatus(for: snapshot),
                                               content: claudeSpendContent(for: snapshot)))
        // U4: one alarm colour per card. The thresholds above are untouched -
        // this only stops a card spending two hues on one situation. See
        // `keepingOnlyTheWorstAlarm`.
        return sections.keepingOnlyTheWorstAlarm()
    }

    /// The extra-usage section's body. Three genuinely different states, and
    /// they read differently (GL-14): no window at all, a window carrying
    /// dollars but no cap, and the full reading.
    static func claudeSpendContent(for snapshot: QuotaSnapshot) -> HelmModuleUsageSection.Content {
        guard let credits = snapshot.extraUsage, let spent = credits.spentUsd else {
            return .note("Not reported.")
        }
        guard let limit = credits.limitUsd, limit > 0 else {
            // No ceiling, so no bar and no percentage: a track drawn against
            // a cap nobody sent would be a picture of a number that does not
            // exist.
            return .spend(HelmModuleUsageSpend(
                amount: dollarText(spent), against: "spent, no cap set",
                value: nil, fill: nil, state: .idle, footnote: nil))
        }
        let fraction = max(0, min(1, spent / limit))
        // The percentage the *card* states is derived from the two dollar
        // figures it is already showing, rather than from `percentUsed` -
        // which is independently optional on this window and, when both are
        // present, is the same quantity. A figure the captain can check
        // against the two numbers beside it is worth more than one they
        // cannot.
        let state = QuotaSeverity(percentUsed: fraction * 100).moduleRowState
        let remaining = max(0, limit - spent)
        return .spend(HelmModuleUsageSpend(
            amount: dollarText(spent),
            against: "of \(dollarText(limit)) cap",
            value: percentText(fraction * 100),
            fill: fraction,
            state: state,
            footnote: remaining > 0
                ? "\(dollarText(remaining)) left before the cap"
                : "Cap reached, extra usage is paused"))
    }

    /// The Plan limits section's verdict - the binding window, named.
    static func claudePlanLimitsStatus(for snapshot: QuotaSnapshot) -> HelmModuleUsageStatus? {
        guard let worst = claudeWorstWindow(for: snapshot) else {
            return HelmModuleUsageStatus(text: "No limits reported", state: .idle)
        }
        if worst.window.percentUsed >= 100 {
            return HelmModuleUsageStatus(text: "\(worst.name) limit reached", state: .bad)
        }
        switch QuotaSeverity(percentUsed: worst.window.percentUsed) {
        case .critical: return HelmModuleUsageStatus(text: "\(worst.name) nearly used", state: .bad)
        case .warning: return HelmModuleUsageStatus(text: "\(worst.name) getting close", state: .warn)
        case .comfortable: return HelmModuleUsageStatus(text: "Comfortable", state: .ok)
        }
    }

    /// The Extra usage section's verdict.
    static func claudeSpendStatus(for snapshot: QuotaSnapshot) -> HelmModuleUsageStatus? {
        guard let fraction = claudeSpendFraction(for: snapshot) else {
            return HelmModuleUsageStatus(text: "No cap", state: .idle)
        }
        if fraction >= 1 { return HelmModuleUsageStatus(text: "Cap reached", state: .bad) }
        switch QuotaSeverity(percentUsed: fraction * 100) {
        case .critical: return HelmModuleUsageStatus(text: "Near cap", state: .bad)
        case .warning: return HelmModuleUsageStatus(text: "Approaching cap", state: .warn)
        case .comfortable: return HelmModuleUsageStatus(text: "Within cap", state: .ok)
        }
    }

    /// `spent / limit`, or `nil` when the response did not carry both - the
    /// one place the card decides whether it has a spend reading at all.
    static func claudeSpendFraction(for snapshot: QuotaSnapshot) -> Double? {
        guard let credits = snapshot.extraUsage,
              let spent = credits.spentUsd,
              let limit = credits.limitUsd, limit > 0 else { return nil }
        return max(0, spent / limit)
    }

    /// The window that runs out first, with the name the header pill uses
    /// for it. `nil` when the response carried no resetting window at all.
    static func claudeWorstWindow(for snapshot: QuotaSnapshot) -> (name: String, window: QuotaWindow)? {
        let windows: [(String, QuotaWindow)] = [
            ("Session", snapshot.session), ("Week", snapshot.weekly), ("Fable", snapshot.fable),
        ].compactMap { name, window in window.map { (name, $0) } }
        return windows.max(by: { $0.1.percentUsed < $1.1.percentUsed }).map { ($0.0, $0.1) }
    }

    /// `Updated 2 min ago`. Relative, not absolute, because the question the
    /// caption answers is "are these figures worth acting on" rather than
    /// "what time was it" - and a wall-clock stamp makes the captain do the
    /// subtraction themselves.
    ///
    /// `now` is injectable for the same reason every other date helper here
    /// is: a suite that drove a fabricated instant and then measured the real
    /// elapsed time would be testing two clocks rather than the feature
    /// (AGENTS.md's one-injectable-clock rule).
    static func claudeUpdatedText(fetchedAt: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(fetchedAt)
        if seconds < 60 { return "Updated just now" }
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = Int((seconds / 3600).rounded(.down))
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(Int((seconds / 86400).rounded(.down)))d ago"
    }

    /// `96%`. No decimal: `quota-axi` reports whole `percentRemaining`
    /// integers, so a `.1f` here would invent precision the source does not
    /// have.
    static func percentText(_ percentUsed: Double) -> String {
        "\(Int(percentUsed.rounded()))%"
    }

    /// `$140` for a whole number of dollars, `$137.62` otherwise - the cap is
    /// always round and the spend rarely is, and `$140.00` beside `$137.62`
    /// reads as false precision on a card this dense.
    static func dollarText(_ amount: Double) -> String {
        amount == amount.rounded()
            ? String(format: "$%.0f", amount)
            : String(format: "$%.2f", amount)
    }

    /// The plan, named as a plan - the mockup's `Team plan` rather than the
    /// bare `Team` the strip carried.
    ///
    /// The extra word is worth its width: "Team" beside a gauge tile reads as
    /// a label for something on the card, where "Team plan" is unambiguously
    /// the account's own tier, which is what the header is for. Falls back to
    /// naming the *source* when the response carried no plan at all, which is
    /// a stated gap rather than a guess (GL-14).
    static func claudeSubtitle(for snapshot: QuotaSnapshot) -> String {
        guard let plan = snapshot.plan, !plan.isEmpty else { return "quota-axi" }
        return "\(plan.capitalized) plan"
    }

    /// The header pill: **one** verdict for the whole card.
    ///
    /// It has to weigh two independent things now, which is what the
    /// redesign changed. The strip's chip only ever looked at the three
    /// resetting windows, so a card whose spend was a dollar off its cap
    /// could read "Comfortable" - the captain's own mockup names that case
    /// ("Near spend cap") and shows it winning over three comfortable
    /// windows, which is the right call: the windows refill on a clock and
    /// the cap does not.
    ///
    /// The tie-break is the mockup's: spend wins when it is at least as
    /// alarming as the worst window. Below the warning threshold on both,
    /// the card says so in one word rather than restating a row.
    static func claudeChip(for snapshot: QuotaSnapshot) -> HelmModuleChip? {
        let worst = claudeWorstWindow(for: snapshot)
        let windowSeverity = worst.map { QuotaSeverity(percentUsed: $0.window.percentUsed) }
        let spendFraction = claudeSpendFraction(for: snapshot)
        let spendSeverity = spendFraction.map { QuotaSeverity(percentUsed: $0 * 100) }

        if let spendSeverity, spendSeverity != .comfortable,
           claudeSeverityRank(spendSeverity) >= claudeSeverityRank(windowSeverity ?? .comfortable) {
            if (spendFraction ?? 0) >= 1 { return .bad("Spend cap reached") }
            return spendSeverity == .critical
                ? .bad("Near spend cap")
                : .warn("Extra usage climbing")
        }

        guard let worst, let windowSeverity else { return nil }
        switch windowSeverity {
        case .critical, .warning:
            let text = worst.window.percentUsed >= 100
                ? "\(worst.name) limit reached"
                : "\(worst.name) limit close"
            return windowSeverity == .critical ? .bad(text) : .warn(text)
        case .comfortable:
            return .ok("Comfortable")
        }
    }

    /// How alarming one severity is against another. `QuotaSeverity` is
    /// deliberately not `Comparable` - it is a verdict, not a scale, and the
    /// only place this app needs to order two of them is the pill above.
    private static func claudeSeverityRank(_ severity: QuotaSeverity) -> Int {
        switch severity {
        case .comfortable: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    private func fillFleet(_ content: inout HelmModuleCard.Content) {
        guard let snapshot = fleetSnapshot else {
            content.subtitle = "loading"
            content.body = .note("Reading the fleet's state\u{2026}")
            return
        }
        let working = snapshot.tasks.filter { $0.status == "working" }
        let needs = snapshot.tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }
        content.subtitle = "\(working.count) crew working"
        content.chip = needs.isEmpty ? .ok("All clear") : .warn("\(needs.count) need you")

        // The reference's Fleet widget: one sentence, then the three numbers
        // under it as tiles.
        //
        // **The three counts are the snapshot's own**, not a second
        // definition: `working` is the same predicate this card's subtitle is
        // already built from, and `doneCount`/`queuedCount` are the very
        // fields Overview's own stat row reads (`FleetController`'s
        // `statsRow`). A second arithmetic for the same three numbers on the
        // hub is exactly what the component index exists to stop - and the
        // tile they are drawn in is that row's `HelmStatTile` too.
        let tiles = [
            HelmModuleTile(value: "\(working.count)", caption: "Working"),
            HelmModuleTile(value: "\(snapshot.doneCount)", caption: "Done today", tint: .good),
            HelmModuleTile(value: "\(snapshot.queuedCount)", caption: "Queued"),
        ]

        if working.isEmpty && needs.isEmpty {
            content.body = .tiles(note: "All hands idle. Nothing is running and nothing is waiting on you.",
                                  tiles: tiles)
            return
        }
        // With something actually in flight the sentence names it, because a
        // parked crewmate's id is the one thing the three counts cannot say.
        let lead = needs.isEmpty
            ? "\(working.count) crew working."
            : "\(needs.count) waiting on you: \(needs.prefix(2).map(\.id).joined(separator: ", "))."
        content.body = .tiles(note: lead, tiles: tiles)
    }

    private func fillTasks(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own checklist
        // artwork, replacing the plain `checkmark.circle` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.shift` case, so the card
        // and the floating-bar shortcut/drill header agree.
        content.artwork = TasksIcon.image
        // Exactly the two predicates the Tasks page's own stat tiles use.
        let tasks = sources.shiftStore.activeTasks
        let calendar = Calendar.current
        let today = Date()
        let due = tasks.filter { task in
            guard let date = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return calendar.isDate(date, inSameDayAs: today)
        }
        let overdue = tasks.filter { task in
            guard let date = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return date < calendar.startOfDay(for: today)
        }
        content.subtitle = "today"
        content.chip = overdue.isEmpty
            ? .mute("\(due.count) due")
            : .bad("\(overdue.count) overdue")
        let note: String
        if let urgent = (overdue.first ?? due.first) {
            note = overdue.isEmpty ? "Next up: \(urgent.title)" : "Overdue: \(urgent.title)"
        } else {
            note = tasks.isEmpty ? "No active tasks." : "\(tasks.count) active, none due today."
        }
        content.body = .metric(value: "\(due.count)", unit: due.count == 1 ? "task" : "tasks", note: note)
    }

    private func fillMergeQueue(_ content: inout HelmModuleCard.Content) {
        guard let prs = mergedPRs else {
            content.subtitle = prFetchFailure == nil ? "loading" : "unavailable"
            content.chip = prFetchFailure == nil ? nil : .warn("Can't reach")
            // GL-14: a failed scan must never render as a confident zero.
            content.body = .note(prFetchFailure.map { "PR status unavailable - \($0)" }
                ?? "Reading open pull requests\u{2026}")
            return
        }
        let ready = FleetDataSource.readyToMerge(prs)
        content.subtitle = "\(prs.count) open"
        content.chip = ready.isEmpty ? .mute("none ready") : .ok("\(ready.count) ready")
        if prs.isEmpty {
            content.body = .note("Nothing open. The queue is clear.")
            return
        }
        let rows = prs.prefix(HelmModuleCard.maxPeekRows).map { pr -> HelmModulePeekRow in
            let state: HelmModuleRowState
            switch pr.checks {
            case "green": state = .ok
            case "red": state = .bad
            case "pending": state = .warn
            default: state = .idle
            }
            return HelmModulePeekRow(state: state, text: pr.title,
                                     value: pr.checks == "none" ? "No checks" : "Checks \(pr.checks)")
        }
        content.body = .peekRows(Array(rows))
        // The reference's footer, and the reason it is worth having: this
        // card shows at most `maxPeekRows` of however many are open, and
        // until now it said so nowhere. "Showing 3 of 33" is the difference
        // between a queue with three PRs in it and a queue whose first three
        // are on screen, which a captain glancing at the hub cannot
        // otherwise tell.
        //
        // Only when there is genuinely more than the card is showing - a
        // footer reading "Showing 2 of 2" is furniture.
        if prs.count > rows.count {
            content.footer = HelmModuleCard.Footer(
                caption: "Showing \(rows.count) of \(prs.count)",
                actionTitle: "View all \(prs.count) open",
                handler: { [weak self] in self?.onOpenDestination?(.review) })
        }
    }

    /// The Straw Hat Pirates card.
    ///
    /// The crew's own Jolly Roger rather than an SF Symbol, which is the
    /// captain's own ask: this card's job is to be recognisable as *the crew*
    /// among a grid of otherwise-uniform hue tiles. `module.symbol` stays the
    /// fallback if the payload ever stops decoding - see
    /// `HelmGradientTile.configure(artwork:symbol:hue:)`.
    ///
    /// The subtitle is a fixed line, not a status readout - the captain's own
    /// call (`fm/straw-hat-menubar-quick-chat-popover`), replacing the
    /// earlier "Nami \u{00B7} 3 exchanges" derived-from-state text. Luffy's
    /// signature line ("I'm gonna be King of the Pirates!"), always, in
    /// every state - not a rotating pool, and not swapped out while a turn
    /// is in flight either. It reads as the crew's own voice on their own
    /// card rather than as a summary of the conversation.
    ///
    /// The body is still the real activity line: a preview of what was last
    /// said, with no "unread" concept (the captain is the only other
    /// participant, and a reply they have not read is one they asked for
    /// seconds ago). Nothing is invented - with no conversation yet it says
    /// so and names what the crew can be asked for; while thinking, it says
    /// that instead of a stale preview from the previous reply (the one
    /// piece of the removed "thinking\u{2026}" subtitle worth keeping - see
    /// below).
    private func fillStrawHat(_ content: inout HelmModuleCard.Content) {
        content.artwork = StrawHatFlag.image
        content.subtitle = "I'm gonna be King of the Pirates!"

        guard let state = strawHatState, state.exchanges > 0 || state.isThinking else {
            // Short on purpose: a module note is one or two lines at a card's
            // real width, so the invitation is the half that has to survive -
            // "every write is yours to confirm" is already on this page's own
            // drill subtitle and on the chat's empty state.
            content.body = .note("Ask for a task, runbook or command.")
            return
        }

        if state.isThinking {
            // The "thinking" signal used to live in the subtitle
            // ("thinking\u{2026}"); with the subtitle now fixed, the body
            // carries it instead - still real, current activity, which is
            // exactly what this line is for.
            content.body = .note("The crew is thinking\u{2026}")
        } else {
            content.body = .note(state.lastLine ?? "The crew is on it.")
        }
    }

    private func fillConsole(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own console
        // artwork, replacing the plain `terminal` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.console` case.
        content.artwork = ConsoleIcon.image
        let rows = consoleTabsProvider?() ?? []
        content.subtitle = rows.isEmpty ? "no tabs open" : "\(rows.count) tab\(rows.count == 1 ? "" : "s") open"
        let connected = connectedHostIDs?() ?? []
        if !connected.isEmpty { content.chip = .mute("\(connected.count) host live") }
        content.body = rows.isEmpty
            ? .note("Open a shell, or connect a saved host.")
            : .peekRows(Array(rows.prefix(HelmModuleCard.maxPeekRows)))
    }

    /// One service as the Health ring's summary needs to see it.
    struct HealthServiceReading {
        let title: String
        let verdict: ServiceHealthState.Verdict
        let hasReported: Bool
    }

    /// What the Health card's ring and its sentence both say.
    struct HealthRingSummary: Equatable {
        let value: Int
        let total: Int
        let title: String
        let note: String
    }

    /// **Review defect U5.** The ring counted healthy-or-running services over
    /// *every* known service while the sentence beside it described only the
    /// ones that had reported, so the card rendered "2/6" next to "Healthy -
    /// All reporting services healthy." and later "4/6" next to the same
    /// words. The numbers and the words disagreed about which set they were
    /// talking about, and neither said what the other four were doing.
    ///
    /// Two things are wrong there and both are fixed here. The fraction and
    /// the sentence now count the *same* set; and a service that is mid-pass
    /// but has never reported anything is no longer counted as healthy, which
    /// is GL-14's "unknown is never rendered as good" in its usual disguise -
    /// `.running` was in the healthy bucket regardless of whether the service
    /// had ever finished a pass.
    ///
    /// While anything is still outstanding the ring counts *reporting* over
    /// total and says so ("4 of 6 reporting"), which is the finding's own
    /// first suggestion. Once every service has reported it goes back to
    /// counting healthy over total, where the fraction and the word "Healthy"
    /// genuinely agree.
    ///
    /// Pure, and separate from the registry, so it can be asserted against
    /// fabricated readings rather than against whatever this Mac's own
    /// services happen to be doing.
    static func healthRingSummary(_ services: [HealthServiceReading]) -> HealthRingSummary {
        guard !services.isEmpty else {
            // B9: shorter copy as well as a third line - the note column
            // beside a 66pt gauge is genuinely narrow, and a summary that
            // needs three lines to say "fine" is not a summary.
            return HealthRingSummary(value: 0, total: 0, title: "Healthy",
                                     note: "Nothing has reported yet.")
        }
        let total = services.count
        let reported = services.filter(\.hasReported)
        let failing = services.filter { $0.verdict == .failing }
        let degraded = services.filter { $0.verdict == .degraded }
        let names = { (list: [HealthServiceReading]) in
            list.map(\.title).joined(separator: ", ")
        }
        guard reported.count == total else {
            let note = failing.isEmpty
                ? "\(reported.count) of \(total) reporting so far."
                : "\(names(failing)) needs a look."
            return HealthRingSummary(value: reported.count, total: total,
                                     title: "Reporting", note: note)
        }
        let healthy = services.filter { $0.verdict == .healthy }
        let note: String
        if !failing.isEmpty {
            note = "\(names(failing)) needs a look."
        } else if !degraded.isEmpty {
            note = "\(names(degraded)) degraded."
        } else {
            // "All 1 services healthy." is what a bare count reads as on a
            // machine where only one service has registered - measured in
            // the probe.
            note = total == 1 ? "The only service is healthy." : "All \(total) services healthy."
        }
        return HealthRingSummary(value: healthy.count, total: total, title: "Healthy", note: note)
    }

    private func fillHealth(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own health
        // artwork, replacing the plain `waveform.path.ecg` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.health` case.
        content.artwork = HealthIcon.image
        let readings = ServiceHealthRegistry.shared.knownServices().map { service -> HealthServiceReading in
            let state = ServiceHealthRegistry.shared.state(service)
            return HealthServiceReading(title: service.title,
                                        verdict: state.verdict,
                                        hasReported: state.hasReported)
        }
        content.subtitle = "background services"
        let failingCount = readings.filter { $0.verdict == .failing }.count
        if failingCount > 0 { content.chip = .bad("\(failingCount) failing") }
        let summary = Self.healthRingSummary(readings)
        content.body = .ring(value: summary.value, total: summary.total,
                             title: summary.title, note: summary.note)
    }

    private func fillHosts(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own hosts
        // artwork, replacing the plain `server.rack` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.hosts` case.
        content.artwork = HostsIcon.image
        let hosts = sources.hostStore.hosts
        let connected = connectedHostIDs?() ?? []
        content.subtitle = "\(hosts.count) saved"
        if !connected.isEmpty { content.chip = .ok("\(connected.count) live") }
        guard !hosts.isEmpty else {
            content.body = .note("No saved hosts yet. Add one to connect in a click.")
            return
        }
        let rows = hosts.prefix(HelmModuleCard.maxPeekRows).map { host in
            HelmModulePeekRow(state: connected.contains(host.id) ? .ok : .idle,
                              text: host.label,
                              value: connected.contains(host.id) ? "live" : "idle")
        }
        content.body = .peekRows(Array(rows))
    }

    // MARK: The four Setup sub-pages
    //
    // Each of these reads the one number its own page owns out of
    // `BackgroundSignalsPoller.lastCounts` - already computed for the
    // Notification Center, and §6.1 is explicit that the canvas takes the last
    // published value and "never a fresh check". Splitting the old aggregate
    // Setup card into four was the captain's call after seeing the hub live.
    //
    // Every one of them shares the same two-state "no number yet" handling
    // (`fillPendingSetupSignal`): the poller's first pass is genuinely in
    // flight, or a pass completed without producing a count, which is a real
    // fault rather than ordinary startup. Neither ever renders a confident
    // zero or an "all current" verdict - GL-14's rule.

    /// The honest loading state shared by all four Setup modules and Vault.
    private func fillPendingSetupSignal(_ content: inout HelmModuleCard.Content,
                                        checking: String,
                                        stale: String) {
        Self.applyPendingSetupSignal(&content,
                                     warmingUp: Self.pollerIsStillWarmingUp,
                                     checking: checking,
                                     stale: stale)
    }

    /// The two honest "no number yet" states, as a pure function of which one
    /// it is.
    ///
    /// **Review #3's UI10.** The warming half used to be a
    /// `Checking\u{2026}` chip over a sentence, on all five cards at once -
    /// see `HelmModuleCard.Body`'s `.skeleton` case for why that read as a
    /// wall rather than as five loading cards. The chip and the sentence are
    /// both gone from the body; the sentence survives as the card's tooltip,
    /// so the detail is still a hover away.
    ///
    /// A static taking `warmingUp` rather than reading the poller, so the two
    /// states can be asserted without waiting fifteen minutes for a real pass
    /// (`Audit3UIFixesSelfTest`).
    static func applyPendingSetupSignal(_ content: inout HelmModuleCard.Content,
                                        warmingUp: Bool,
                                        checking: String,
                                        stale: String) {
        guard warmingUp else {
            // A pass finished and produced nothing. That is a real fault, not
            // ordinary startup, and it says so in words - a skeleton here
            // would promise an answer that is not coming.
            content.chip = nil
            content.body = .note(stale)
            return
        }
        content.chip = nil
        content.body = .skeleton()
        content.toolTip = checking
    }

    /// Updates: how many catalog tools have a newer version available. The
    /// exact count `UpdatesController`'s own "Updates Available" tile shows.
    private func fillUpdates(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own updates
        // artwork, replacing the plain `steeringwheel` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.updates` case.
        content.artwork = UpdatesIcon.image
        content.subtitle = "tools & packages"
        guard let updates = BackgroundSignalsPoller.shared.lastCounts.toolUpdates else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking every tool for a newer version\u{2026}",
                                   stale: "Tool versions haven't been checked yet this session.")
            return
        }
        guard updates > 0 else {
            content.chip = .ok("Current")
            content.body = .note("Every tool in the catalog is on its latest version.")
            return
        }
        content.chip = .warn("\(updates) update\(updates == 1 ? "" : "s")")
        content.body = .metric(value: "\(updates)",
                               unit: updates == 1 ? "update" : "updates",
                               note: "Ready to install from the Updates page.")
    }

    /// Bootstrap: how many of the five setup steps have drifted. This is the
    /// progress body the aggregate Setup card used to carry, and it belongs
    /// here because `SetupStepKind` *is* Bootstrap's own stepper.
    private func fillBootstrap(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "machine setup"
        guard let drift = BackgroundSignalsPoller.shared.lastCounts.setupDrift else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking the setup steps\u{2026} this card fills itself in when the first pass lands.",
                                   stale: "Setup status hasn't been checked yet this session.")
            return
        }
        let total = SetupStepKind.allCases.count
        let done = max(0, total - drift)
        content.chip = drift == 0 ? .ok("Current") : .warn("\(drift) drifted")
        content.body = .progress(value: done, total: total,
                                 note: drift == 0
                                    ? "Every setup step matches."
                                    : "\(drift) step\(drift == 1 ? "" : "s") drifted.")
    }

    /// Automation: what a one-click "Run Automation" would actually do.
    ///
    /// Deliberately the same published `setupDrift` Bootstrap reads - that page
    /// is the sequencer over the very same `SetupStepChecks` predicates, so a
    /// second number would be a second opinion about one fact. What differs is
    /// the question each card answers: Bootstrap's is "does my machine match?",
    /// this one's is "is there anything for a run to do?".
    private func fillAutomation(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own automation
        // artwork, replacing the plain `bolt.fill` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.automation` case.
        content.artwork = AutomationIcon.image
        content.subtitle = "one-click setup"
        guard let drift = BackgroundSignalsPoller.shared.lastCounts.setupDrift else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking what a full run would need to do\u{2026}",
                                   stale: "Setup status hasn't been checked yet this session.")
            return
        }
        let total = SetupStepKind.allCases.count
        guard drift > 0 else {
            content.chip = .ok("Nothing to run")
            content.body = .note("All \(total) steps are already satisfied - a full run would skip every one.")
            return
        }
        content.chip = .warn("\(drift) to run")
        content.body = .note("A full run would work through \(drift) drifted step\(drift == 1 ? "" : "s") in order, stopping at the first failure.")
    }

    /// GitHub Sync: how many of the captain's forks are behind upstream. The
    /// same count `GitHubSyncController`'s own rows show a Sync button for.
    private func fillGitHubSync(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own GitHub Sync
        // artwork, replacing the plain `arrow.2.squarepath` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.githubSync` case.
        content.artwork = GithubSyncIcon.image
        content.subtitle = "forks"
        guard let drift = BackgroundSignalsPoller.shared.lastCounts.forkDrift else {
            fillPendingSetupSignal(&content,
                                   checking: "Checking each fork against its upstream\u{2026}",
                                   stale: "Fork drift hasn't been checked yet this session.")
            return
        }
        let total = GitHubSyncCatalog.repos.count
        guard drift > 0 else {
            content.chip = .ok("In sync")
            content.body = .note("All \(total) forks match their upstream.")
            return
        }
        content.chip = .warn("\(drift) behind")
        content.body = .metric(value: "\(drift)",
                               unit: drift == 1 ? "fork" : "forks",
                               note: "Behind upstream, of \(total) tracked.")
    }

    private func fillSchedules(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own schedules
        // artwork, replacing the plain `calendar` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.schedules` case.
        content.artwork = SchedulesIcon.image
        let schedules = sources.scheduleStore.schedules
        content.subtitle = "unattended"
        guard !schedules.isEmpty else {
            // L3: the old copy ("Nothing scheduled. Add one to have it run on
            // its own.") ran past the two-line note cap at a narrow column and
            // truncated mid-word - the same class as B9's Health note. Short
            // enough to fit, and the card's title already says what "one" is.
            content.body = .note("Nothing scheduled yet. Add one here.")
            return
        }
        let failed = schedules.filter { $0.lastRun?.verdict == .failed }
        content.chip = failed.isEmpty ? .ok("Clean") : .warn("\(failed.count) failed")
        let rows = schedules.prefix(HelmModuleCard.maxPeekRows).map { schedule -> HelmModulePeekRow in
            let state: HelmModuleRowState
            switch schedule.lastRun?.verdict {
            case .some(.failed): state = .bad
            case .some: state = .ok
            case .none: state = .idle
            }
            return HelmModulePeekRow(state: schedule.isEnabled ? state : .idle,
                                     text: schedule.action.title,
                                     value: schedule.isEnabled ? schedule.cadence.displayString : "paused")
        }
        content.body = .peekRows(Array(rows))
    }

    private func fillLogAnalyzer(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own log-analyzer
        // artwork, replacing the plain `text.magnifyingglass` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.logAnalyzer` case.
        content.artwork = LogAnalyzerIcon.image
        // Memoised inside the store (GL-35) - this is not a fresh disk walk
        // on every canvas render.
        let history = sources.logAnalyzerStore.history()
        content.subtitle = history.first.map { "last: \($0.sourceKind.displayName)" } ?? "nothing saved"
        guard let latest = history.first else {
            content.body = .note("Paste output or capture a terminal block to start an investigation.")
            return
        }
        content.body = .metric(value: "\(history.count)",
                               unit: history.count == 1 ? "saved" : "saved",
                               note: "Latest: \(latest.title)")
    }

    /// `fm/grandline-k8s-cluster-tail`. Reads the same `connectedHostIDs`
    /// closure the Hosts module already uses - `HostSessionRegistry`'s own
    /// live set, in memory, one hop away - and nothing else. The canvas constructs no store and fires no fetch
    /// (`DaylightModuleSelfTest.checkCanvasConstructsNoStores` is a source
    /// guard on exactly that), and this page's own data needs a feed tab the
    /// canvas has no business creating.
    private func fillKubernetes(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own kubernetes
        // artwork, replacing the plain `cube.transparent` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.kubernetes` case.
        content.artwork = KubernetesIcon.image
        let live = connectedHostIDs?().count ?? 0
        content.subtitle = live == 0 ? "no live session" : (live == 1 ? "1 live session" : "\(live) live sessions")
        guard live > 0 else {
            content.body = .note("Cluster browsing and log tailing run inside a bastion session you're already logged into. Connect a host first.")
            return
        }
        content.body = .note("Browse pods, deployments and events read-only, or tail several pods at once - through a session you've already authenticated.")
    }

    /// Automic Vault's hardening panel, back at this app's `.vault`
    /// destination by the captain's own later correction
    /// (`fm/swap-vault-poneglyph-naming-in-grand-lin-1f` - see
    /// `VaultController.swift`'s header for the full history). The number is
    /// unchanged either way - the last snapshot `BackgroundSignalsPoller`
    /// took, never a fresh `av` shell-out (§6.1) - because what it counts did
    /// not change, only where the page lives and what it is called.
    private func fillVault(_ content: inout HelmModuleCard.Content) {
        let counts = BackgroundSignalsPoller.shared.lastCounts
        content.subtitle = "names only"
        guard let secrets = counts.vaultSecrets else {
            // The same two honest loading states as the four Setup modules, for
            // the same reason.
            fillPendingSetupSignal(&content,
                                   checking: "Checking Automic Vault\u{2026} this card fills itself in when the first pass lands.",
                                   stale: "Automic Vault hasn't been checked yet this session.")
            return
        }
        if let attention = counts.vaultAttention, attention > 0 {
            content.chip = .warn("\(attention) need\(attention == 1 ? "s" : "") a look")
        }
        content.body = .metric(value: "\(secrets)",
                               unit: secrets == 1 ? "secret" : "secrets",
                               note: "Hardened in Automic Vault's Keychain. Values never leave it.")
    }

    /// `fm/implement-grand-line-secrets-vault-poneg-ad`: the captain's own
    /// credential vault, named Poneglyph (`fm/swap-vault-poneglyph-naming-in-
    /// grand-lin-1f` gave `.vault`/Stores back to Automic Vault's hardening
    /// panel above). It is its own standalone destination now rather than a
    /// Setup tab (`fm/poneglyph-own-destination-and-strawhat-toolbar-
    /// shortcut`) - this card still just opens `RailDestination.poneglyph`,
    /// unaffected by which slot that destination shows.
    ///
    /// It reads injected state and shells out to nothing - §6.1's rule, and
    /// here it is also a security property: a canvas card must not decrypt
    /// anything, and while the vault is locked there is genuinely nothing to
    /// count.
    private func fillPoneglyph(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own poneglyph
        // tablet artwork, replacing the plain `doc.text.image` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.poneglyph` case.
        content.artwork = PoneglyphIcon.image
        guard let vault = credentialVaultState?() else {
            content.subtitle = "encrypted credentials"
            content.body = .note("Open Poneglyph to unlock it.")
            return
        }
        switch vault.state {
        case .absent:
            content.subtitle = "not set up yet"
            content.chip = .warn("Set up")
            content.body = .note("Store your tokens and passwords here, encrypted, and get them back on any machine.")
        case .unreadable:
            content.subtitle = "unavailable"
            content.chip = .bad("Unreadable")
            content.body = .note("The vault file could not be read. Nothing has been overwritten - open Poneglyph for details.")
        case .present:
            content.subtitle = "encrypted credentials"
            guard vault.isUnlocked, let count = vault.count else {
                content.chip = .mute("Locked")
                content.body = .note("Unlock with your master password to reach your credentials.")
                return
            }
            content.chip = .ok("Unlocked")
            content.body = .metric(value: "\(count)",
                                   unit: count == 1 ? "credential" : "credentials",
                                   note: "Reveal or copy any of them in one click.")
        }
    }

    /// `fm/grandline-docs-split-runbooks-postmortems` narrowed this card to
    /// the Playbook alone - Runbooks and Postmortems are `fillRunbooks`/
    /// `fillPostmortems` below now, each with its own module card. `DocsStore`
    /// is a plain static enum (no store to inject), so this reads exactly
    /// what `DocsController.drillHeaderSubtitle`'s own Playbook branch reads -
    /// the real sync state, never a fabricated "offline copy" claim.
    private func fillDocs(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own docs
        // artwork, replacing the plain `book.closed` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.docs` case.
        content.artwork = DocsAppIcon.image
        content.subtitle = "DevOps Playbook"
        if DocsStore.isSynced {
            content.chip = .ok("Synced")
            content.body = .note("Browsable offline - the captain's playbook, kept locally.")
        } else {
            content.chip = .warn("Not synced")
            content.body = .note("Sync it once from the Docs page to browse it here, fully offline afterward.")
        }
    }

    /// F1's notebook card: the two most recently touched pages, and how many
    /// there are.
    ///
    /// GL-14: an empty notebook says so in its own words rather than showing
    /// "0 pages", and the card never claims a sync state it has not read.
    private func fillNotebook(_ content: inout HelmModuleCard.Content) {
        let pages = sources.notebookStore.listPages()
        content.subtitle = "linked markdown pages"
        guard !pages.isEmpty else {
            content.body = .note("No pages yet. Start with today's note - everything you write "
                                 + "lands in your own config repo as markdown.")
            return
        }
        content.chip = .ok(pages.count == 1 ? "1 page" : "\(pages.count) pages")
        let rows = pages
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(2)
            .map { page in
                HelmModulePeekRow(state: .idle,
                                  text: page.title,
                                  value: page.isDailyNote ? "daily note" : page.folder)
            }
        content.body = .peekRows(Array(rows))
    }

    /// F4's reading list card: what is still waiting, and the two most
    /// recently saved.
    ///
    /// GL-14 twice over: an empty list says so in its own words rather than
    /// showing "0 unread", and a link whose title has not been fetched yet
    /// shows its host rather than a blank row pretending to be a headline.
    private func fillReadingList(_ content: inout HelmModuleCard.Content) {
        let links = sources.readingListStore.links
        content.subtitle = "links saved to read"
        guard !links.isEmpty else {
            content.body = .note("Nothing saved yet. Paste a URL here, or press \u{2318}6 in the "
                                 + "\u{2325}Space capture panel, and it lands here as a card.")
            return
        }
        let unread = links.filter { !$0.isRead }
        content.chip = unread.isEmpty
            ? .ok("all read")
            : .warn(unread.count == 1 ? "1 unread" : "\(unread.count) unread")
        // Unread first, newest first - the grid's own order, so the card and
        // the page agree about what is at the top of the pile.
        let rows = links
            .sorted(by: ReadingListQuery.order)
            .prefix(2)
            .map { link in
                HelmModulePeekRow(state: link.isRead ? .idle : .warn,
                                  text: link.displayTitle,
                                  value: link.host)
            }
        content.body = .peekRows(Array(rows))
    }

    /// The runbook peek rows this card used to show under `.docs` before the
    /// split above - moved verbatim, since Runbooks is now its own module
    /// with its own destination.
    private func fillRunbooks(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own runbooks
        // artwork, replacing the plain `list.bullet.rectangle` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.runbooks` case.
        content.artwork = RunbooksIcon.image
        let runbooks = sources.docsRunbookStore.listRunbooks()
        content.subtitle = "step-by-step procedures"
        guard !runbooks.isEmpty else {
            content.body = .note("No runbooks yet. Write one, or let SRE Lead generate one from an investigation.")
            return
        }
        let rows = runbooks.prefix(2).map { runbook in
            HelmModulePeekRow(state: .idle,
                              text: runbook.title,
                              value: DocsRunbookMetadata.runbookSubtitle(runbook) ?? "")
        }
        content.body = .peekRows(Array(rows))
    }

    /// The Postmortems sibling of `fillRunbooks` above - same shape, reading
    /// `listPostmortems()` instead.
    private func fillPostmortems(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own postmortems
        // artwork, replacing the plain `doc.text.magnifyingglass` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.postmortems` case.
        content.artwork = PostmortemsIcon.image
        let postmortems = sources.docsRunbookStore.listPostmortems()
        content.subtitle = "incident write-ups"
        guard !postmortems.isEmpty else {
            content.body = .note("No postmortems yet. Generate one from an SRE Lead investigation.")
            return
        }
        let rows = postmortems.prefix(2).map { postmortem in
            HelmModulePeekRow(state: .idle,
                              text: postmortem.title,
                              value: DocsRunbookMetadata.postmortemSubtitle(postmortem) ?? "")
        }
        content.body = .peekRows(Array(rows))
    }

    private func fillDictation(_ content: inout HelmModuleCard.Content) {
        content.subtitle = "hold Right \u{2325}"
        let dictationStatus = pushedDictationStatus ?? DictationPermissions.currentStatus()
        switch dictationStatus {
        case .ready: content.chip = .ok("Ready")
        case .recording, .transcribing, .cleaningUp: content.chip = .mute(dictationStatus.title)
        case .didNotCatchThat: content.chip = .warn(dictationStatus.title)
        default: content.chip = .warn("Needs access")
        }
        content.body = .note(dictationStatus.detail(shortcutDisplay: AppSettings.shared.dictationShortcut.displayString))
    }

    private func fillTools(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own tools
        // artwork, replacing the plain `wrench.and.screwdriver` glyph -
        // matches `RailDestination.drillHeaderArtwork`'s `.tools` case.
        content.artwork = ToolsAppIcon.image
        content.subtitle = "\(ToolKind.allCases.count) utilities"
        content.body = .note(ToolKind.allCases.prefix(5).map { $0.shortName }.joined(separator: " \u{00B7} ") + " and more")
    }

    /// Static, like Tools' and Settings' cards (§6.1's table says "static" for
    /// both, and this is the same kind of card): a whiteboard has no count the
    /// canvas could read without reaching into a live web view, and this card
    /// must never do that - the whole point of the destination being lazy is
    /// that the canvas can be on screen with no canvas process running.
    private func fillWhiteboard(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own whiteboard
        // artwork, replacing the plain `scribble.variable` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.whiteboard` case.
        content.artwork = WhiteboardAppIcon.image
        content.subtitle = "Excalidraw, offline"
        content.body = .note("Sketch by hand, or describe a diagram and have Claude draw it.")
    }

    /// Static, like Whiteboard's card right above and for the exact same
    /// reason: a live note count would mean constructing a `StickyBoardStore`
    /// from the canvas, which `checkCanvasConstructsNoStores` exists to
    /// forbid - the canvas never fires a fetch, and a store construction here
    /// is one, not just a read.
    private func fillStickyBoard(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own sticky-note
        // artwork, replacing the plain `note.text` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.stickyBoard` case.
        content.artwork = StickyNotesIcon.image
        content.subtitle = "quick notes"
        // UX5: "give each module card a genuinely useful peek (Tasks: due
        // today; Console: last command; Sticky: newest note) rather than a
        // static summary." Tasks and Console already had theirs; this card was
        // one of the static ones the finding is about - the same sentence on
        // every visit whether the board held nothing or forty notes.
        //
        // Newest first, which is the opposite of the store's own order
        // (`notes` is sorted oldest-first, because that is the board's
        // stacking order) - a peek of three answers "what was I just
        // thinking", not "what did I think first".
        // `activeNotes`, not every note: UX10 gave the board an archive, and a
        // hub peek that counted archived notes would report a board fuller
        // than the one the captain sees.
        let newest = sources.stickyBoardStore.activeNotes.sorted { $0.createdAt > $1.createdAt }
        guard !newest.isEmpty else {
            content.body = .note("Jot down a thought on a colored sticky note, anywhere on the board.")
            return
        }
        content.chip = .mute(newest.count == 1 ? "1 note" : "\(newest.count) notes")
        content.body = .peekRows(newest.prefix(HelmModuleCard.maxPeekRows).map { note in
            HelmModulePeekRow(state: .idle,
                              // The same title-or-first-line fallback ⌘K's own
                              // sticky rows use, so one note reads the same way
                              // wherever it is listed.
                              text: UnifiedSearchStickyNoteProvider.displayTitle(for: note),
                              // The colour is the one thing a captain
                              // actually sorts these by on the board itself.
                              value: note.color.rawValue.capitalized)
        })
    }

    /// `names()` rather than `list()`: this needs "how many, and what are they
    /// called", and a snippet's content can be large - reading every one of
    /// them on every return to the hub would be a real cost for a subtitle.
    private func fillCodePreview(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-card-shortcut-icons`: the captain's own code-preview
        // artwork, replacing the plain `chevron.left.forwardslash.chevron.right`
        // glyph - matches `RailDestination.drillHeaderArtwork`'s
        // `.codePreview` case.
        content.artwork = CodePreviewIcon.image
        let names = sources.codePreviewStore.names()
        content.subtitle = "Monaco, offline"
        guard !names.isEmpty else {
            content.body = .note("Paste code here to read it with real syntax highlighting.")
            return
        }
        content.chip = .mute(names.count == 1 ? "1 snippet" : "\(names.count) snippets")
        content.body = .peekRows(names.prefix(HelmModuleCard.maxPeekRows).map {
            HelmModulePeekRow(state: .idle,
                              text: $0,
                              value: CodePreviewLanguage.forFilename($0).displayName)
        })
    }

    /// Reads the store's already-loaded `commands` array and its favourites -
    /// both in-memory field reads on a store the shell already owns, so this
    /// costs nothing per canvas render. The peek rows are the captain's own
    /// recently-used commands, which is the one thing about this library that
    /// changes between visits.
    private func fillCommandLibrary(_ content: inout HelmModuleCard.Content) {
        let total = commandLibrarySources.commands.count
        content.subtitle = "saved commands"
        guard total > 0 else {
            content.body = .note("Your DevOps command library - searchable, parameterised, one click from a terminal.")
            return
        }
        content.chip = .mute("\(total)")
        let recent = commandLibrarySources.recentlyUsedCommands(limit: HelmModuleCard.maxPeekRows)
        guard !recent.isEmpty else {
            content.body = .metric(value: "\(total)",
                                   unit: total == 1 ? "command" : "commands",
                                   note: "Nothing run yet - open the library to find one.")
            return
        }
        content.body = .peekRows(recent.map {
            HelmModulePeekRow(state: .idle, text: $0.name, value: $0.category)
        })
    }

    /// Spelled out rather than reaching through `sources` inline, purely so
    /// the store's role in this one card is obvious at its use site.
    private var commandLibrarySources: CommandLibraryStore { sources.commandLibraryStore }

    private func fillSettings(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own settings
        // artwork, replacing the plain `gearshape` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.settings` case.
        content.artwork = SettingsAppIcon.image
        content.subtitle = "this machine"
        content.body = .note("Connection \u{00B7} Appearance \u{00B7} Terminal \u{00B7} Security \u{00B7} Backup")
    }

    /// Whether the background-signals poller has yet completed a pass.
    ///
    /// Read from the poller rather than tracked here: `lastCompletedPassAt` is
    /// its own already-published state, so this cannot drift out of step with
    /// it and adds nothing new to observe.
    private static var pollerIsStillWarmingUp: Bool {
        BackgroundSignalsPoller.shared.lastCompletedPassAt == nil
    }

    // MARK: Probe / self-test surface

    var moduleCardsForTests: [HelmModuleCard] { cards }
    /// The grid's rows as built, so a suite can assert the *placement* and
    /// not merely that five cards exist. The dashboard's whole subject is
    /// which card sits where and how wide, and `cards` is a flat list that
    /// cannot see any of it.
    var gridRowsForTests: [NSStackView] { gridStack.arrangedSubviews.compactMap { $0 as? NSStackView } }
    /// Whether the hub is using the hand-placed dashboard rather than the
    /// wrapping grid. Read from the same two conditions the layout itself
    /// takes, via the row shape it produces - never a flag set alongside it,
    /// which could say yes while the grid said otherwise.
    var usesDashboardLayoutForTests: Bool {
        usesDashboardLayout
            && dashboardRowViewsWouldApply(available: gridContainerWidth(),
                                           modules: visibleModules())
    }
    var heroCardHiddenForTests: Bool { heroCard.isHidden }
    var visibleModulesForTests: [DaylightModule] { visibleModules() }
    /// The captain's Needs Attention card, so a suite can drive the real card
    /// on the real page rather than a card it built itself - which is what
    /// proves the wiring as well as the render.
    var attentionCardForTests: NeedsAttentionCard { attentionCard }
    var attentionCardHiddenForTests: Bool { attentionCard.isHidden }
    var greetingForTests: (title: String, subtitle: String, kicker: String) {
        (greetingLabel.stringValue, subtitleLabel.stringValue, kickerLabel.stringValue)
    }
    /// C1's hero badge, for the suite that asserts it reports a verdict on
    /// Overview and only an identity elsewhere.
    var heroTintForTests: HelmTint { heroTint }
    var heroBadgeHiddenForTests: Bool { heroBadge.isHidden }
    /// Plan B's layout: where the top-anchored content column actually sits
    /// inside the document.
    var contentFrameForTests: CGRect { stack.frame }
    /// The hero row's resolved chrome - a paint this app cannot see any
    /// other way, since `cacheDisplay` renders a surface and a bare row
    /// equally happily.
    ///
    /// There is no `isBanner` any more: the banner had exactly one caller,
    /// the hub, and the hub has no hero row at all now (`heroCardHiddenForTests`).
    var heroBandForTests: (fill: NSColor?, borderWidth: CGFloat, radius: CGFloat, inset: CGFloat) {
        (heroCard.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
         heroCard.layer?.borderWidth ?? 0,
         heroCard.layer?.cornerRadius ?? 0,
         heroCardInsets.first(where: { $0.firstAttribute == .leading })?.constant ?? 0)
    }
    var documentHeightForTests: CGFloat { document.frame.height }
    var viewportHeightForTests: CGFloat { scroll.contentView.bounds.height }
    var gridRowCountForTests: Int { gridStack.arrangedSubviews.count }
    /// Force one synchronous render, bypassing the coalescing hop - so a
    /// self-test can establish a known starting state before driving the
    /// signal it is actually testing.
    func debugRenderNow() { render() }
    /// Repaint against a given theme without going near
    /// `ThemeManager.setTheme`, which writes through to the real preference -
    /// the hermeticity hazard that has poisoned whole suite runs before.
    func debugApplyTheme(_ theme: HelmTheme) { applyTheme(theme) }
}
