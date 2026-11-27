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
// 2. **It draws the captain's arranged cards and nothing else.** Which cards
//    show, how wide and how tall is `HomeCardLayout`, which the sidebar
//    shell hands in (`cardLayout`) and Customize edits. P-03 of the
//    2026-11-25 full review removed the floating bar, and with it the two
//    things this page kept only for that layout: Overview's hand-placed
//    dashboard and the space pills' filter over the module grid.
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
//   - gotcha (13): every card width in the grid is
//     `HelmDaylightPriority.contentTie` (499) - below
//     `NSLayoutPriorityWindowSizeStayPut` - so no card can cap the window.
//     The grid is `HelmResponsiveGrid.spanningRows(_:)` at
//     `HomeCardGrid.columns`, with the rows `HomeCardGrid.rows` packs from
//     the captain's widths (`buildArrangedGrid`).
//
// **P-05 of the 2026-11-25 full review split this file by card family**
// (GL-36), the way `ConsoleController` was split. It had reached 5,229 lines.
// This file keeps the class, its stored state, build, data in, render,
// layout and the self-test surface. The rest is in `HomeCanvasController+*.swift`:
// `+Briefing`, `+Arrangement`, `+Customize`, `+Claude`, `+Fleet`,
// `+MergeQueue`, `+Health`, `+Hosts` and `+ModuleCards`. The move changed no
// statement. `private` was dropped from the class's members so the family can
// reach them across files, so treat the whole family as private to itself.

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
        /// R5-UX-07: the Focus timer card's session. The shell's one timer,
        /// which the Tasks page and the toolbar's chip also read; `nil` where
        /// no shell built one, and the card then says what a session is.
        var focusTimer: FocusTimerController? = nil
    }

    /// §6.1's grid: minimum column width 255, gap 16.
    nonisolated static let minModuleWidth: CGFloat = 255
    nonisolated static let gridSpacing: CGFloat = 16

    /// Whether a card `width` wide is narrower than a span-2 card: two
    /// minimum columns and the gap between them. A card's narrow-form
    /// decisions (the briefing's clause cap, the Claude report's stacked
    /// reflow) are made from this.
    static func isNarrowerThanTwoColumns(_ width: CGFloat) -> Bool {
        width + 0.5 < minModuleWidth * 2 + gridSpacing
    }
    /// The canvas gutter - the scale's 24 (UI-14), which is also the bar's
    /// own side margin, so the cards' edges line up under the bar's.
    static let gutter: CGFloat = HelmMetrics.pageGutter
    /// How far the top-anchored content sits below the page's own top edge.
    ///
    /// The bar already reserves its own height above this page
    /// (`DaylightBarController.reservedTopHeight`), so this is only the gap
    /// between that chrome and the first card. S03: the page frame's
    /// first-content line, the same as every other page's - it was 8pt here
    /// and 24pt on half the others.
    static let contentTopMargin: CGFloat = HelmMetrics.pageContentInset
    /// Below the last row. When S03 moved the top from 8pt to 12pt the foot
    /// gave back the same 4pt, so the page's content area is what it was.
    static let contentBottomMargin: CGFloat = HelmMetrics.s5 - (HelmMetrics.pageContentInset - HelmMetrics.s2)

    // MARK: Forwarded actions (never owned)

    var onOpenDestination: ((RailDestination) -> Void)?
    /// The briefing hero's "Open Needs you": the decisions waiting on the
    /// captain. Wired to Crew › Needs you; with nothing wired it opens the
    /// Fleet page, as it always has.
    var onOpenCrewDecisions: (() -> Void)?
    var onOpenShiftTask: ((String) -> Void)?
    /// The Claude status card's own Refresh - wired to `FleetController`'s
    /// existing quota reading, forced past its freshness window.
    ///
    /// Overview's own refresh pass takes the *cached* quota reading when it
    /// is under five minutes old (`FleetController.quotaFreshness`). That is
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
    /// The Hosts hero card's live sessions, for how long each has been open.
    /// A closure for `connectedHostIDs`' reason: this page never holds the
    /// session registry.
    var hostSession: ((UUID) -> HostSession?)?
    /// The Hosts hero card's pills: Switch to a live session, or connect to a
    /// saved host through the app's one `connectToHost` path.
    var onSwitchToHostSession: ((UUID) -> Void)?
    var onConnectHost: ((UUID) -> Void)?
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

    var fleetSnapshot: FleetSnapshot?
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
    var quotaSnapshot: QuotaSnapshot?
    var quotaFailure: String?
    /// When `quotaSnapshot` arrived - see `applyQuota`. `nil` until the first
    /// successful reading, which is exactly when the card has no freshness to
    /// state and so shows no caption at all rather than "Updated just now"
    /// about nothing.
    var quotaFetchedAt: Date?
    /// `true` between the card's Refresh being pressed and the reading (or
    /// the stated reason there is none) coming back. Drives the header
    /// button's disabled in-flight state, and stops a second press stacking
    /// another forced subprocess on top of the first.
    ///
    /// Cleared in `applyQuota`, which `FleetController.refreshQuota` publishes
    /// on failure as well as on success - so this cannot wedge on a
    /// `quota-axi` that is offline or unauthenticated.
    var isRefreshingQuota = false
    var mergedPRs: [MergedPR]?
    var prFetchFailure: String?
    /// UI-12's error state for the merge queue: the last list that was read,
    /// and when. A failed scan keeps showing it and says how old it is,
    /// rather than blanking a card that was right a minute ago.
    var lastGoodPRs: [MergedPR]?
    var lastGoodPRsAt: Date?
    /// `nil` until the engine has pushed one. The Dictation module then falls
    /// back to `DictationPermissions.currentStatus()` rather than assuming
    /// `.ready`: the engine only pushes on a *change*, so a hub rendered at
    /// launch on a machine that has never granted microphone access would
    /// otherwise show a confident "Ready" chip until the captain tried to
    /// dictate. That read is three synchronous authorization-status calls -
    /// no subprocess, no network - and is what `DictationController` seeds
    /// its own state from.
    var pushedDictationStatus: DictationStatus?
    /// `nil` until the crew page has pushed one - i.e. until a conversation
    /// has actually moved. The card then reads as "no conversation yet",
    /// which is the honest state at launch rather than a fabricated summary.
    var strawHatState: StrawHatCanvasState?

    // P-02: `nonisolated(unsafe)` because `deinit` reads `focusTimer` from it.
    // Assigned once in `init` and never written again.
    nonisolated(unsafe) let sources: Sources

    // MARK: Views

    let scroll = NSScrollView()
    let document = FlippedView()
    let stack = NSStackView()
    let gridStack = NSStackView()

    // MARK: The feel pass (the sidebar layout's Home)
    //
    // The Fable second-opinion review's Stage 1, cut to the feasibility
    // audit's items 1 to 3: the prototype's Home, drawn natively, in the
    // sidebar layout. Top to bottom: a greeting as the page
    // title with a one-line summary, the Morning briefing as a gradient hero
    // with the services ring inside it, then the captain's cards.
    //
    // The band the feel pass drew between the hero and the cards - four KPI
    // tiles (tasks due today, PRs ready to merge, services healthy, Claude's
    // week) and the Needs attention card with its Refresh - is gone from this
    // page: the captain removed it. The hero and the cards below already carry
    // each of those figures, so the band repeated them. P-03 of the
    // 2026-11-25 full review removed the floating bar's hub, the last page
    // that drew the attention card, and the card's wiring here went with it.
    //
    // Rule 1 holds: every figure here is one this page already reads for a
    // card (the injected `ShiftStore`, the pushed fleet and quota, the health
    // registry's summary). There are no sparklines: nothing records a series
    // of any of these figures, and a trend line needs one.

    let greetingTitle = NSTextField(labelWithString: "")
    let greetingSummary = NSTextField(labelWithString: "")
    let greetingHeader = NSStackView()
    /// F-02: Plan my day and Start focus under the greeting, for when the
    /// briefing is not drawn as the hero and so has no actions row of its own.
    let greetingActions = NSStackView()
    var greetingActionTitles: [String] = []
    let briefingHero = HelmHeroCard()
    /// The content's top edge: S03's first-content line, lifted by the
    /// greeting's own ink inset while the greeting is the first thing drawn
    /// (`greetingInkInset`).
    var stackTop: NSLayoutConstraint?

    /// How far a display title's capitals sit below its frame's top: the
    /// font's ascender less its cap height. S03 puts every page's first ink
    /// on one line, and a card's ink starts at its frame while a 30pt title's
    /// starts this far inside it, so the greeting is lifted by this much.
    static var greetingInkInset: CGFloat {
        let font = HelmType.displayTitle()
        return max(0, floor(font.ascender - font.capHeight))
    }

    var cards: [HelmModuleCard] = []
    /// P2: the page's cards by module, the width each was built for, and
    /// the layout they were built into - so a render that changes only data
    /// reconfigures these cards in place instead of rebuilding the grid.
    var cardsByModule: [DaylightModule: HelmModuleCard] = [:]
    var cardWidths: [DaylightModule: CGFloat] = [:]
    var gridLayoutKey: GridLayoutKey?

    // MARK: Home's arranged cards (the sidebar layout, modular-shell stage 4)

    /// The cards Home shows, which the sidebar layout sets from the
    /// captain's saved arrangement (`HomeCardLayout`). A canvas nobody has
    /// handed one shows the standard set, the same cards a new captain sees.
    var cardLayout: HomeCardLayout = .standard {
        didSet {
            guard cardLayout != oldValue, isViewLoaded else { return }
            // Mid-drag only the grid moves: the greeting and the hero cannot
            // have changed, and the drag's own card is kept.
            if cardResize != nil {
                resizeArrangedGrid()
            } else {
                render()
            }
        }
    }
    /// Every arrangement the captain makes in Customize, for the shell to keep.
    var onCardLayoutChanged: ((HomeCardLayout) -> Void)?
    /// What Reset brings back: Home's own cards for the captain's profile
    /// (R2-UX-01 (b)). The sidebar layout sets it; the standard set
    /// otherwise.
    var standardCardLayout: HomeCardLayout = .standard

    /// R2-UX-01 (c): the modules the captain's profile hides. The greeting
    /// and the briefing hero speak only for modules in the sidebar: a
    /// Personal Home does not tell a writer that the fleet needs them or
    /// that services are failing. Empty - Operator - reports everything.
    var hiddenModules: Set<WorkspaceModule> = [] {
        didSet {
            guard hiddenModules != oldValue, isViewLoaded else { return }
            render()
        }
    }
    /// Customize: the tray above the grid and the controls on every card.
    var isCustomizing = false
    lazy var customizeTray: HomeCustomizeTray = {
        let tray = HomeCustomizeTray()
        tray.translatesAutoresizingMaskIntoConstraints = false
        tray.onAdd = { [weak self] module in self?.arrange { $0.show(module) } }
        tray.onReset = { [weak self] in
            guard let self else { return }
            let standard = self.standardCardLayout
            self.arrange { $0 = standard }
        }
        tray.onDone = { [weak self] in self?.endCustomizing() }
        return tray
    }()
    /// Set by the shell, which owns Customize's toolbar button.
    var onCustomizingChanged: ((Bool) -> Void)?
    var cardStrips: [DaylightModule: HomeCardCustomizeStrip] = [:]
    /// The grips on every card while Customize is on.
    var resizeHandles: [DaylightModule: [HomeCardResizeHandle]] = [:]
    /// The size a card is being dragged to, on that card.
    let sizeBadge = HomeCardSizeBadge()
    // P-02: `nonisolated(unsafe)` because `deinit` is nonisolated and removes
    // this observation. Written on main only, and read once more in `deinit`.
    nonisolated(unsafe) var themeToken: ThemeObservation?
    nonisolated(unsafe) var signalCountsToken: BackgroundSignalsPoller.CountsObservation?
    nonisolated(unsafe) var windowResizeObserver: NSObjectProtocol?
    nonisolated(unsafe) var clipResizeObserver: NSObjectProtocol?

    // MARK: Live resize (PERF-03)
    //
    // **The 2026-10 end-to-end review's PERF-03.** AppKit posts
    // `didResizeNotification` on every frame of a live resize, and every one
    // of them reached `rebuildGrid()`. A width change defeats the in-place
    // refresh, so each frame tore the grid down.
    //
    // Between `willStartLiveResize` and `didEndLiveResize` the grid keeps its
    // cards and only its constants move: the content width and each card's
    // width pin. One `rebuildGrid()` runs when the drag ends. A drag that
    // moves a card between rows still rebuilds, because that is a different
    // grid.

    // P-02: `nonisolated(unsafe)` because `deinit` is nonisolated and removes
    // this observation. Written on main only, and read once more in `deinit`.
    nonisolated(unsafe) var liveResizeObservers: [NSObjectProtocol] = []
    private(set) var isInLiveResize = false

    /// Each width pin the current grid was built with, and the span it
    /// covers, so a live resize can move them without rebuilding: every
    /// card's and spacer's.
    var gridWidthPins: [(constraint: NSLayoutConstraint, span: Int)] = []

    #if FM_SELFTESTS
    /// PERF-03's counter: full grid rebuilds (the teardown path).
    var debugGridRebuilds = 0
    private(set) var debugApplyThemeCount = 0
    #endif
    var lastGridWidth: CGFloat = 0
    /// The background services as this render sees them - see
    /// `ServiceHealthSummary`. Taken once at the top of `render()`, which the
    /// registry's observer schedules on every report, and read by the
    /// greeting, the briefing hero's ring and the Health card alike:
    /// R5-BUG-02's footer said "7/7 services healthy" beside a card reading
    /// "7/8" because each asked the registry for itself.
    var healthSummary = ServiceHealthSummary()
    /// UX-02: the services the Health card's rows can run again, the same
    /// entry points Health's own Retry uses (`Workspace.healthRetryActions`).
    var healthRetryActions: [HealthService: () -> Void] = [:]
    /// C1: the content column's preferred width, retuned to the available
    /// width on every grid rebuild.
    var contentWidthConstraint: NSLayoutConstraint?
    /// Coalesces the render requests that arrive in bursts.
    ///
    /// Three of this page's inputs fire several times in quick succession by
    /// nature: `ServiceHealthRegistry` reports `markRunning` and then a
    /// verdict for each service in a poller pass, and a single dictation goes
    /// recording -> transcribing -> cleaning up -> ready in a few seconds.
    /// A render reconfigures every card (and rebuilds them when the layout
    /// changed), so answering every one of those individually would be real,
    /// visible work for a page whose content only changes once. One flag plus
    /// a main-queue hop collapses a burst into a single render.
    var renderPending = false

    init(sources: Sources) {
        self.sources = sources
        super.init(nibName: nil, bundle: nil)
        // R5-UX-07: the Focus timer card follows a session starting, pausing
        // and stopping. The timer's observers fire every second while one
        // runs; the card says when it ends rather than counting down, so it
        // re-renders only when that answer changes.
        focusTimerToken = sources.focusTimer?.observe { [weak self] in self?.focusTimerDidChange() }
        // Full review 2026-11-25, B-01: the greeting's date and the day's
        // due counts turn over at midnight with no store change.
        dayRolloverToken = DayRollover.observe { [weak self] _, _ in self?.dayDidChange() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// What the Focus timer card last said about the session, so a tick
    /// that changes nothing it shows asks for no render.
    var focusCardKey: String?
    // P-02: `nonisolated(unsafe)` because `deinit` is nonisolated and removes
    // this observation. Written on main only, and read once more in `deinit`.
    nonisolated(unsafe) var focusTimerToken: UUID?
    nonisolated(unsafe) var dayRolloverToken: NSObjectProtocol?

    /// B-01: one render while Home can be seen; a hidden Home renders when
    /// it is shown again.
    func dayDidChange() {
        guard isViewLoaded, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        setNeedsRender()
    }

    func focusTimerDidChange() {
        let session = sources.focusTimer?.session
        let key = session.map { "\($0.taskID)|\($0.isPaused)|\($0.plannedSeconds)" }
        guard key != focusCardKey else { return }
        focusCardKey = key
        guard isViewLoaded else { return }
        setNeedsRender()
    }

    deinit {
        if let focusTimerToken { sources.focusTimer?.unobserve(focusTimerToken) }
        if let dayRolloverToken { NotificationCenter.default.removeObserver(dayRolloverToken) }
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let signalCountsToken { BackgroundSignalsPoller.shared.unobserveCounts(signalCountsToken) }
        if let windowResizeObserver { NotificationCenter.default.removeObserver(windowResizeObserver) }
        if let clipResizeObserver { NotificationCenter.default.removeObserver(clipResizeObserver) }
        liveResizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        root.wantsLayer = true
        view = root

        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = Self.gridSpacing
        gridStack.distribution = .fill
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        // UI-14: 16 between the page's rows, the same gap the grid's own
        // rows use.
        stack.spacing = Self.gridSpacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        buildFeelPass()
        stack.addArrangedSubview(greetingHeader)
        stack.addArrangedSubview(briefingHero)
        stack.addArrangedSubview(tipRow)
        stack.addArrangedSubview(gridStack)
        // The prototype's 22pt under the page title, before the hero.
        stack.setCustomSpacing(HelmMetrics.s5, after: greetingHeader)
        tipRow.isHidden = true

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

            // C1's horizontal half: the content column is centred between
            // the gutters, at the width `rebuildGrid` gives it.
            //
            // Inequalities plus a 499 preferred width, never a required `==`
            // tie (gotcha (3)): a required equality here is a window-size
            // trap, and 499 keeps it under `NSLayoutPriorityWindowSizeStayPut`
            // (gotcha (13)).
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: Self.gutter),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -Self.gutter),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),

            // Plan B's vertical half: the content is **top-anchored**, and
            // whatever the page cannot fill trails below it.
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
            // turn what makes a page taller than the viewport scroll - so it
            // is load-bearing, not symmetry for its own sake, and dropping
            // back to a `<=` here would leave the document's height undriven.
            //
            // `document.heightAnchor >= scroll.contentView.heightAnchor` is
            // gone with the centring it existed for, and must NOT come back
            // alongside these two: a document forced to fill a viewport it is
            // shorter than, while also being exactly its content's height, is
            // two required constraints in direct conflict.
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.contentBottomMargin),

            gridStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            greetingHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            briefingHero.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        tipRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let top = stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.contentTopMargin)
        top.isActive = true
        stackTop = top

        let contentWidth = stack.widthAnchor.constraint(equalToConstant: HelmResponsiveGrid.fallbackContainerWidth)
        contentWidth.priority = HelmDaylightPriority.contentTie
        contentWidth.isActive = true
        contentWidthConstraint = contentWidth

        // GL-20: registered globally (`object: nil`) the same way
        // `ToolsController.containerWidthMayHaveChanged` is, and gated on
        // visibility inside the handler for the same measured reason - a
        // resize while another destination is showing must not pay for this
        // page's relayout. Only this page's own window counts: a bar panel
        // or popover resizing cannot change this grid's width, and letting
        // one through is how a stale grid got corrected by luck on one
        // machine and not on another (P2, `KeyedRefreshSelfTest`).
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            // P-02: `queue: .main` delivers on main; this says so to the compiler.
            // `Notification` is not `Sendable`, so the closure carries the
            // sender's identity, which `===` compared before.
            let sender = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender == self.view.window.map(ObjectIdentifier.init) else { return }
                self.containerWidthMayHaveChanged()
            }
        }
        // The clip view can narrow without the window resizing: a legacy
        // scroller appears when the content first overflows on a Mac set to
        // always show scroll bars, or the system's scroller style changes
        // after launch (measured on a CI runner - the grid stayed 15pt too
        // wide, under the scroller track, until the next render). On the next
        // main-queue turn rather than inside the layout pass that moved the
        // clip, and through the same staleness check, so it converges: a
        // narrower grid is never shorter, so it cannot hide the scroller
        // that narrowed it.
        // PERF-03: bracket a live resize, so the frames inside it move the
        // grid's constants and the end of it rebuilds once. This window only,
        // for the reason the resize observer above gives.
        liveResizeObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                // `Notification` is not `Sendable`, so the closure carries the
                // sender's identity, which `===` compared before.
                let sender = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, sender == self.view.window.map(ObjectIdentifier.init) else { return }
                    self.isInLiveResize = true
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                // `Notification` is not `Sendable`, so the closure carries the
                // sender's identity, which `===` compared before.
                let sender = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, sender == self.view.window.map(ObjectIdentifier.init) else { return }
                    self.liveResizeDidEnd()
                }
            },
        ]
        scroll.contentView.postsFrameChangedNotifications = true
        clipResizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            // The hop is the point here (the next main-queue turn, not inside
            // the layout pass that moved the clip), so it stays.
            DispatchQueue.main.async { [weak self] in self?.containerWidthMayHaveChanged() }
        }

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

    let scrollMemory = HelmScrollMemory()

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scrollMemory.remember(scroll)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
        view.layoutSubtreeIfNeeded()
        // P3: keep the captain's place unless the page changed (`HelmScrollMemory`).
        scrollMemory.restore(scroll) { scrollToTop() }
    }

    // MARK: Data in (pushed, never fetched)

    /// Called by `AppShellController` whenever `FleetController`'s own refresh
    /// completes. That refresh already runs at launch and on every Overview
    /// visit, so the canvas gets real fleet numbers without asking for them.
    func applyFleet(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?, prFetchFailure: String?) {
        #if FM_SELFTESTS
        if debugInputsPinned { return }
        #endif
        self.fleetSnapshot = snapshot
        self.mergedPRs = mergedPRs
        self.prFetchFailure = prFetchFailure
        if let mergedPRs {
            lastGoodPRs = mergedPRs
            lastGoodPRsAt = Date()
        }
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
        #if FM_SELFTESTS
        if debugInputsPinned { return }
        #endif
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

    /// PERF-01: the reading list or the sticky board finished its first,
    /// off-main read. Their cards said "reading" until now; this puts the
    /// contents there. Not gated on visibility, like `applyStrawHat`: the
    /// render itself is what waits.
    func storeDidLoad() {
        guard isViewLoaded else { return }
        setNeedsRender()
    }

    func applyDictationStatus(_ status: DictationStatus) {
        pushedDictationStatus = status
        guard isViewLoaded, !view.isHidden else { return }
        setNeedsRender()
    }

    // MARK: State the split files keep here

    // Stored properties of the + files (GL-36): an extension cannot
    // hold one, so they stay with the class.

    /// The titles the hero's buttons were last built with, so a render that
    /// changes nothing keeps the buttons it has (and their hover state).
    var heroActionTitles: [String] = []

    /// Home's "Things you can do" strip: one tip a day for the first week,
    /// above the cards, until the captain hides it.
    /// S17: the tip is a `HelmNotice` - an informational notice, so a tinted
    /// tile and no edge (UI-4). "Hide tips" is its dismiss, remembered in
    /// `AppSettings.homeTipsDismissed`.
    lazy var tipRow: HelmNotice = {
        let notice = HelmNotice(dismissTitle: "Hide tips")
        notice.onDismiss = { [weak self] in self?.dismissTips() }
        return notice
    }()
    var shownTip: HomeTips.Tip?
    var shownTipDay = 0

    /// A drag in progress: which card and grip, and where it started.
    struct CardResize {
        let module: DaylightModule
        let edge: HomeCardResizeHandle.Edge
        /// The pointer, in the document's (flipped) coordinates, so a scroll
        /// during the drag does not read as a resize.
        let start: NSPoint
        let startWidth: CGFloat
        let startHeight: CGFloat
        /// The arrangement before the drag, to tell whether it changed.
        let startLayout: HomeCardLayout
        /// What each step sizes the card from: the arrangement with the
        /// card's row stored as it is drawn (`keepDrawnRow`).
        let base: HomeCardLayout
    }

    var cardResize: CardResize?

    // MARK: Render

    /// Ask for one render on the next main-queue turn, however many callers
    /// ask before it runs. See `renderPending`.
    func setNeedsRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            guard self.isViewLoaded else { return }
            self.render()
        }
    }

    func render() {
        healthSummary = ServiceHealthRegistry.shared.summary()
        renderFeelPass()
        renderTip()
        rebuildGrid()
        applyTheme(ThemeManager.shared.theme)
    }

    // MARK: Layout

    func gridContainerWidth() -> CGFloat {
        let clip = scroll.contentView.bounds.width
        let usable = clip - Self.gutter * 2
        return usable > 0 ? usable : HelmResponsiveGrid.fallbackContainerWidth
    }

    /// GL-20's gate: only relay out when this page is actually on screen, and
    /// only when the width genuinely changed. A resize fires many times per
    /// drag; rebuilding fifteen cards on every frame of one is the exact
    /// regression `ToolsController` measured (~3.6ms -> ~20ms per frame).
    func containerWidthMayHaveChanged() {
        guard isViewLoaded, !view.isHidden else { return }
        let width = gridContainerWidth()
        guard abs(width - lastGridWidth) > 0.5 else { return }
        // PERF-03: inside a drag, move the grid's constants and leave its
        // cards; `liveResizeDidEnd` rebuilds once. A rebuild needs no
        // `applyTheme` after it - every new card themes itself as it is
        // built - so the one this used to make is gone too.
        if isInLiveResize, resizeGridInPlace(available: width) { return }
        rebuildGrid()
    }

    /// The end of a drag: the one rebuild the frames inside it deferred.
    func liveResizeDidEnd() {
        guard isInLiveResize else { return }
        isInLiveResize = false
        guard isViewLoaded, !view.isHidden else { return }
        rebuildGrid()
    }

    /// One live-resize frame, constants only. `false` when the new width
    /// needs a different grid - a card crossed the width it is widened at,
    /// which moves it between rows - and the caller rebuilds instead.
    func resizeGridInPlace(available: CGFloat) -> Bool {
        guard let built = gridLayoutKey, !gridWidthPins.isEmpty else { return false }
        let modules = visibleModules()
        // The grid keeps its `HomeCardGrid.columns` at every width, so a
        // frame can only move the constants.
        guard built.modules == modules, built.spans == modules.map(cardSpan) else { return false }
        let unit = HomeCardGrid.unitWidth(containerWidth: available, spacing: Self.gridSpacing)
        for (pin, span) in gridWidthPins {
            pin.constant = unit * CGFloat(span) + Self.gridSpacing * CGFloat(span - 1)
        }
        contentWidthConstraint?.constant = available
        lastGridWidth = available
        return true
    }

    func scrollToTop() {
        guard let clip = scroll.contentView as NSClipView? else { return }
        clip.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    /// The Claude card's Refresh. The subprocess itself runs on
    /// `FleetController`'s own quota queue (GL-04/GL-12) - nothing here
    /// blocks, and this page still starts no work it owns.
    func refreshQuotaTapped() {
        guard !isRefreshingQuota else { return }
        isRefreshingQuota = true
        // `setNeedsRender`, not `render()`: a render can rebuild every card
        // (it does whenever the layout changed), and
        // this is running *inside* the button's own target/action - tearing
        // the button out of the view hierarchy from its own action is the
        // shape of bug this codebase has already paid for once
        // (`TabChipView.beginRename`, AppKit gotcha (1)). Coalesced to the
        // next main-thread turn, which is still before the subprocess can
        // answer, so the button is visibly disabled either way.
        setNeedsRender()
        onRefreshQuota?()
    }

    func applyTheme(_ theme: HelmTheme) {
        #if FM_SELFTESTS
        debugApplyThemeCount += 1
        #endif
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
        paintTip(theme)
        greetingTitle.attributedStringValue = NSAttributedString(
            string: greetingTitle.stringValue,
            attributes: HelmType.displayTitleAttributes(color: HelmTheme.nsColor(theme.chromeInkHex)))
        greetingSummary.font = .systemFont(ofSize: HelmType.scaled(Self.greetingSummarySize))
        greetingSummary.textColor = HelmTheme.mutedInk(theme)
        for card in cards { card.applyTheme(theme) }
    }

    // MARK: Probe / self-test surface
    //
    // R2-ARCH-09: compiled into debug builds only (GL-27). Until this guard
    // covered the whole surface, `debugInputsPinned` - a stored property, so
    // dead-stripping could not remove its field - shipped in the release
    // binary, and any production caller of the rest would have shipped it too.

    #if FM_SELFTESTS
    var moduleCardsForTests: [HelmModuleCard] { cards }
    /// The grid's rows as built, so a suite can assert the *placement* and
    /// not merely that the cards exist: which card sits where and how wide,
    /// which `cards`, a flat list, cannot see.
    var gridRowsForTests: [NSStackView] { gridStack.arrangedSubviews.compactMap { $0 as? NSStackView } }
    /// Whether the grid was last laid out for the width the page has now.
    /// False from the moment the clip view changes width (the sidebar
    /// opening, a scroller appearing) until the main-queue turn on which
    /// `containerWidthMayHaveChanged` reflows the cards - the window a suite
    /// must wait out rather than guess at with a delay (R4-PROC-01).
    var gridIsCurrentForTests: Bool { abs(gridContainerWidth() - lastGridWidth) <= 0.5 }
    var visibleModulesForTests: [DaylightModule] { visibleModules() }
    /// Customize's tray while it is in the page, or nil.
    var customizeTrayForTests: HomeCustomizeTray? { customizeTray.superview == nil ? nil : customizeTray }
    /// The controls each card wears while Customize is on.
    var cardStripsForTests: [DaylightModule: HomeCardCustomizeStrip] { cardStrips }
    /// The grips each card wears while Customize is on.
    var resizeHandlesForTests: [DaylightModule: [HomeCardResizeHandle]] { resizeHandles }
    /// The size badge, which is in the page only while a card is dragged.
    var sizeBadgeForTests: HomeCardSizeBadge { sizeBadge }
    func cardForTests(_ module: DaylightModule) -> HelmModuleCard? { cardsByModule[module] }
    /// REL-04: the fleet verdict the greeting and the briefing hero read.
    var overviewAnswerForTests: FleetGreeting.Answer? { overviewAnswer() }
    /// Plan B's layout: where the top-anchored content column actually sits
    /// inside the document.
    var contentFrameForTests: CGRect { stack.frame }
    var documentHeightForTests: CGFloat { document.frame.height }
    var viewportHeightForTests: CGFloat { scroll.contentView.bounds.height }
    /// Force one synchronous render, bypassing the coalescing hop - so a
    /// self-test can establish a known starting state before driving the
    /// signal it is actually testing.
    func debugRenderNow() { render() }
    /// P2: render with the in-place path closed, so a suite can compare a
    /// grid refreshed in place with one built fresh from the same data.
    func debugRebuildGridFromScratch() {
        gridLayoutKey = nil
        render()
    }
    /// The scroller style a runner may switch to after launch, which narrows
    /// the clip view without resizing the window.
    func debugSetScrollerStyle(_ style: NSScroller.Style) { scroll.scrollerStyle = style }
    /// The width the grid was last built for, and the width it has now.
    var debugGridWidths: (built: CGFloat, container: CGFloat) { (lastGridWidth, gridContainerWidth()) }
    /// `ReviewTourLab`'s `demo home`: once its fixture is applied, later live
    /// fleet and quota readings are ignored, so a render is deterministic.
    var debugInputsPinned = false
    /// Repaint against a given theme without going near
    /// `ThemeManager.setTheme`, which writes through to the real preference -
    /// the hermeticity hazard that has poisoned whole suite runs before.
    func debugApplyTheme(_ theme: HelmTheme) { applyTheme(theme) }

    /// Put one card's reading back to "not read yet", the state a first
    /// launch paints before that reading lands - `claude`, `fleet` or `merge`
    /// (which also forgets the last good PR list, as on a first launch).
    /// Renders synchronously, like `debugRenderNow`.
    func debugForgetReading(_ card: String) {
        switch card {
        case "claude": quotaSnapshot = nil; quotaFailure = nil
        case "fleet": fleetSnapshot = nil
        case "merge": mergedPRs = nil; prFetchFailure = nil; lastGoodPRs = nil; lastGoodPRsAt = nil
        default: return
        }
        render()
    }
    /// The fleet snapshot the page last applied, so the tour lab's
    /// `demo refresh` can replay the interim push a real refresh makes.
    var debugFleetSnapshot: FleetSnapshot? { fleetSnapshot }
    /// The Claude reading the card draws, and the failure it would show
    /// with no reading to keep.
    var debugQuota: (snapshot: QuotaSnapshot?, failure: String?) { (quotaSnapshot, quotaFailure) }

    /// The scroll view's document, for a render of the whole page rather
    /// than the part that fits the window.
    var debugDocumentView: NSView { document }

    /// The page's geometry as text: the viewport, the document, the overflow
    /// between them and every module card's resolved and fitting heights. The tour lab's `measure` verb prints it; the numbers
    /// in the Home fit history entry came from it.
    func debugMeasureLines() -> [String] {
        view.layoutSubtreeIfNeeded()
        func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        var out: [String] = []
        out.append("viewport \(f(scroll.contentView.bounds.width))x\(f(scroll.contentView.bounds.height))")
        out.append("document height \(f(document.frame.height))")
        out.append("overflow \(f(document.frame.height - scroll.contentView.bounds.height))")
        out.append("grid width \(f(lastGridWidth))")
        for card in cards {
            out.append("card \(card.debugHeaderText.title) \(f(card.frame.width))x\(f(card.frame.height))"
                       + " fit \(f(card.fittingSize.height))")
        }
        return out
    }
    #endif
}
