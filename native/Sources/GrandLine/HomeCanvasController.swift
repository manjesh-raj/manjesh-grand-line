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
//
// **P-05 of the 2026-11-25 full review split this file by card family**
// (GL-36), the way `ConsoleController` was split. It had reached 5,229 lines.
// This file keeps the class, its stored state, build, data in, render,
// layout and the self-test surface. The rest is in `HomeCanvasController+*.swift`:
// `+Briefing`, `+Attention`, `+Customize`, `+Dashboard`, `+Claude`, `+Fleet`,
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
    static let minModuleWidth: CGFloat = 255
    static let gridSpacing: CGFloat = 16

    /// Which grid a card was placed by, and how much of it the card owns.
    ///
    /// A card's narrow-form decisions (the Claude report's stacked reflow,
    /// the briefing's clause cap) are made from this rather than from a bare
    /// width. The two grids answer "is this card degraded?" differently: on
    /// the wrapping shelf a card is narrow exactly when `packRows` has put a
    /// span-2 card into one column, which a width compared against the
    /// shelf's two-column arithmetic tells correctly. On the hub's
    /// proportional dashboard that same comparison is wrong by construction -
    /// at the 960pt minimum window a 7-of-12-track card resolves to 525.33pt,
    /// under the shelf's 526pt, and was being built as a degraded card it was
    /// not (the scout's finding M3, 88pt of page height).
    enum CardPlacement: Equatable {
        /// The wrapping shelf, building this card `width` wide.
        case shelf(width: CGFloat)
        /// The hub's hand-placed dashboard, `span` of
        /// `HelmResponsiveGrid.dashboardColumns` tracks, `width` wide.
        case dashboard(span: Int, width: CGFloat)

        /// The width the grid built this card for.
        var width: CGFloat {
            switch self {
            case .shelf(let width), .dashboard(_, let width): return width
            }
        }

        /// Whether this card is narrower than a span-2 card on the grid that
        /// placed it.
        var isNarrowerThanTwoColumns: Bool {
            let spanTwo = HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing
            switch self {
            case .shelf(let width):
                return width + 0.5 < spanTwo
            case .dashboard(let span, let width):
                // Narrow only when the track share *and* the width both say
                // so. Half the track grid is the dashboard's analogue of the
                // shelf's two columns, which is what keeps a 7-track card at
                // 525.33pt out of the narrow form (M3); the width half keeps
                // a 5-track briefing that resolves 600pt wide at the
                // captain's window in the wide one, as it always was.
                return span * 2 < HelmResponsiveGrid.dashboardColumns && width + 0.5 < spanTwo
            }
        }
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
    /// Below the last row. The hub sizes its rows to fill the viewport less
    /// these two margins, so when S03 moved the top from 8pt to 12pt the
    /// foot gave back the same 4pt: the rows' share of the viewport is what
    /// it was, and at the shortest window a loading card's skeleton still
    /// fits its row (`LayoutStabilitySelfTest`, 960x620, measured 4pt over
    /// with the foot left at 24).
    static let contentBottomMargin: CGFloat = HelmMetrics.s5 - (HelmMetrics.pageContentInset - HelmMetrics.s2)

    // MARK: Forwarded actions (never owned)

    var onOpenDestination: ((RailDestination) -> Void)?
    /// The fleet's attention row: the decisions waiting on the captain. Wired
    /// to Crew › Needs you, which the sidebar layout draws; with nothing wired
    /// it opens the Fleet page, as it always has.
    var onOpenCrewDecisions: (() -> Void)?
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
    /// When `applyFleet` last delivered a reading - UX5's hero detail line.
    /// `nil` until the first one lands, which is the "reading now" state.
    var fleetReadAt: Date?
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

    let sources: Sources
    var space: DaylightSpace = .overview

    // MARK: Views

    let scroll = NSScrollView()
    let document = FlippedView()
    let stack = NSStackView()
    let greetingLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
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
    let heroBadge = IconTileView(size: 40, cornerRadius: 12)
    let kickerLabel = NSTextField(labelWithString: "")
    var heroTint: HelmTint = .accent
    /// The app's one Refresh (`HelmButton.refresh`, UXP-08): a labelled
    /// secondary button, because Refresh re-reads and is never what a page
    /// is for.
    let refreshButton = HelmButton.refresh()
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
    let heroCard = NSView()
    var heroCardInsets: [NSLayoutConstraint] = []
    /// The captain's "Needs Attention" card - what is due today and which
    /// follow-ups are waiting, merged into one flat list.
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
    let attentionCard = NeedsAttentionCard()
    let gridStack = NSStackView()

    // MARK: The feel pass (the sidebar layout's Home)
    //
    // The Fable second-opinion review's Stage 1, cut to the feasibility
    // audit's items 1 to 3: the prototype's Home, drawn natively, on Home's
    // own space in the sidebar layout. Top to bottom: a greeting as the page
    // title with a one-line summary, the Morning briefing as a gradient hero
    // with the services ring inside it, then the captain's cards. The floating
    // bar's hand-placed hub is left exactly as it is (`showsArrangedCards` is
    // false there).
    //
    // The band the feel pass drew between the hero and the cards - four KPI
    // tiles (tasks due today, PRs ready to merge, services healthy, Claude's
    // week) and the Needs attention card with its Refresh - is gone from this
    // page: the captain removed it. The hero and the cards below already carry
    // each of those figures, so the band repeated them. The attention card
    // stays on the floating bar's hub, where it is column 1.
    //
    // Rule 1 holds: every figure here is one this page already reads for a
    // card (the injected `ShiftStore`, the pushed fleet and quota, the health
    // registry's summary). There are no sparklines: nothing records a series
    // of any of these figures, and a trend line needs one.

    let greetingTitle = NSTextField(labelWithString: "")
    let greetingSummary = NSTextField(labelWithString: "")
    let greetingHeader = NSStackView()
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
    /// P2: the page's cards by module, the placement each was built for, and
    /// the layout they were built into - so a render that changes only data
    /// reconfigures these cards in place instead of rebuilding the grid.
    var cardsByModule: [DaylightModule: HelmModuleCard] = [:]
    var cardPlacements: [DaylightModule: CardPlacement] = [:]
    var gridLayoutKey: GridLayoutKey?
    /// The hub's own-height preferences (`dashboardColumn`), by module, so
    /// an in-place refresh can move them with the content.
    var dashboardOwnHeights: [DaylightModule: NSLayoutConstraint] = [:]

    // MARK: Home's arranged cards (the sidebar layout, modular-shell stage 4)

    /// The cards Home's own space shows, which the sidebar layout sets
    /// (`HomeCardLayout`). Nil - the floating bar - keeps the hub's
    /// hand-placed dashboard exactly as it is.
    var cardLayout: HomeCardLayout? {
        didSet {
            guard cardLayout != oldValue, isViewLoaded else { return }
            // Mid-drag only the grid moves: the greeting and the attention
            // card cannot have changed, and the drag's own card is kept.
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
    /// (R2-UX-01 (b)). The sidebar layout sets it; the hub's own five
    /// otherwise.
    var standardCardLayout: HomeCardLayout = .standard

    /// R2-UX-01 (c): the modules the captain's profile hides. The attention
    /// card speaks only for modules in the sidebar: a Personal Home does not
    /// tell a writer that their "firstmate home" is missing, that the fleet
    /// is idle or that setup checks have not run. Empty - the floating bar,
    /// and Operator - reports everything, exactly as before.
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
    var themeToken: ThemeObservation?
    var signalCountsToken: BackgroundSignalsPoller.CountsObservation?
    var windowResizeObserver: NSObjectProtocol?
    var clipResizeObserver: NSObjectProtocol?

    // MARK: Live resize (PERF-03)
    //
    // **The 2026-10 end-to-end review's PERF-03.** AppKit posts
    // `didResizeNotification` on every frame of a live resize, and every one
    // of them reached `rebuildGrid()`. A width change defeats the in-place
    // refresh, so each frame tore the grid down - and on the hub, before
    // that, built six to eight throwaway probe cards and gave each a full
    // layout pass (`fittingHeight`) to budget the columns.
    //
    // Two changes, both from the review:
    //
    //   - Probe heights are memoised by (content, width) - see
    //     `probeHeight(_:width:)`. A probe is only re-measured when what it
    //     shows or the width it is shown at has changed.
    //   - Between `willStartLiveResize` and `didEndLiveResize` the grid keeps
    //     its cards and only its constants move: the content width, each
    //     card's (or hub column's) width pin, and the hub's own-height
    //     preferences. One `rebuildGrid()` runs when the drag ends. A drag
    //     that changes the shelf's column count, or crosses the hub's
    //     fall-back width, still rebuilds, because that is a different grid.

    var liveResizeObservers: [NSObjectProtocol] = []
    private(set) var isInLiveResize = false

    /// Each width pin the current grid was built with, and the span it
    /// covers, so a live resize can move them without rebuilding. On the hub
    /// these are the three columns' pins; on a shelf, every card's and
    /// spacer's.
    var gridWidthPins: [(constraint: NSLayoutConstraint, span: Int)] = []
    /// The shelf's column count at build time - the live-resize path's test
    /// for "same grid, new width".
    var builtShelfColumns = 0

    struct ProbeKey: Hashable {
        let signature: String
        let width: CGFloat
    }
    /// See `probeHeight(_:width:)`.
    var probeHeights: [ProbeKey: CGFloat] = [:]
    /// The keys the plan being computed has read, so the memo can drop
    /// everything else once it is done - what keeps it "cleared when the
    /// content changes" without a per-module bookkeeping of its own.
    var probeKeysInUse: Set<ProbeKey>?

    #if FM_SELFTESTS
    /// PERF-03's counters: real probe layouts, memo hits, and full grid
    /// rebuilds (the teardown path).
    var debugProbeMeasurements = 0
    var debugProbeMemoHits = 0
    var debugGridRebuilds = 0
    private(set) var debugApplyThemeCount = 0
    #endif
    var lastGridWidth: CGFloat = 0
    /// The height the hub's columns were last budgeted for - see
    /// `containerWidthMayHaveChanged`.
    var lastGridHeight: CGFloat = 0
    /// `fm/grandline-home-fit-implement`: on the hub the document is held as
    /// tall as the viewport, at 499 - so the page fits the window and its
    /// columns' lists absorb the room, while content that genuinely cannot
    /// fit (the minimum window with Larger text) still wins and the page
    /// scrolls as a fallback rather than clipping. Off the hub it is
    /// inactive, and the other spaces stay top-anchored with the leftover
    /// trailing below. Under `NSLayoutPriorityWindowSizeStayPut`, and inside
    /// a scroll view, so it can never become a floor on the window (gotchas
    /// (13) and (15)).
    var documentFillsViewport: NSLayoutConstraint?
    /// The attention card's full-width tie while it sits above the grid
    /// (every space but the hub's three-column page, where it is column 1).
    var attentionWidthTie: NSLayoutConstraint?
    /// The Merge queue's peek rows on the hub's page, chosen from the height
    /// its column has left (`dashboardRowViews`). The shelf keeps
    /// `maxPeekRows`.
    var mergeQueueRowLimit = HelmModuleCard.maxPeekRows
    /// The background services as this render sees them - see
    /// `ServiceHealthSummary`. Taken once at the top of `render()`, which the
    /// registry's observer schedules on every report, and read by the
    /// attention card's closing note and the Health card alike: R5-BUG-02's
    /// footer said "7/7 services healthy" beside a card reading "7/8" because
    /// each asked the registry for itself.
    var healthSummary = ServiceHealthSummary()
    /// Whether the hub's Health card lists its services under the ring -
    /// set by `dashboardRowViews` when its column has the room, never on the
    /// shelf.
    var healthListsServices = false
    /// C1: the content column's preferred width, retuned on every grid
    /// rebuild from the column count the grid actually used.
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
    var focusTimerToken: UUID?
    var dayRolloverToken: NSObjectProtocol?

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
        textStack.spacing = HelmMetrics.s0
        textStack.setCustomSpacing(HelmMetrics.s1, after: kickerLabel)
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
        // UI-14: 16 between the attention card and the dashboard, the same
        // gap the dashboard's own rows use.
        stack.spacing = Self.gridSpacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        buildFeelPass()
        stack.addArrangedSubview(greetingHeader)
        stack.addArrangedSubview(briefingHero)
        stack.addArrangedSubview(heroCard)
        stack.addArrangedSubview(attentionCard)
        stack.addArrangedSubview(tipRow)
        stack.addArrangedSubview(gridStack)
        // The prototype's 22pt under the page title, before the hero.
        stack.setCustomSpacing(HelmMetrics.s5, after: greetingHeader)
        tipRow.isHidden = true

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
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.contentBottomMargin),

            heroCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            gridStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            greetingHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            briefingHero.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        tipRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let top = stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.contentTopMargin)
        top.isActive = true
        stackTop = top
        let attentionTie = attentionCard.widthAnchor.constraint(equalTo: stack.widthAnchor)
        attentionTie.isActive = true
        attentionWidthTie = attentionTie
        let fills = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        fills.priority = HelmDaylightPriority.contentTie
        documentFillsViewport = fills

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
            guard let self, (note.object as? NSWindow) === self.view.window else { return }
            self.containerWidthMayHaveChanged()
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
                guard let self, (note.object as? NSWindow) === self.view.window else { return }
                self.isInLiveResize = true
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, (note.object as? NSWindow) === self.view.window else { return }
                self.liveResizeDidEnd()
            },
        ]
        scroll.contentView.postsFrameChangedNotifications = true
        clipResizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.containerWidthMayHaveChanged() }
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



    // MARK: Space filter (§5.3)

    var selectedSpace: DaylightSpace { space }

    /// Switch the visible module set. Rebuilds rather than toggling
    /// `isHidden`: the row packing genuinely changes with the module count,
    /// and an `isHidden` card left in a row would still occupy its column
    /// (AGENTS.md gotcha (11) - only an `NSStackView`'s *arranged* subviews
    /// leave layout when hidden, and these live inside packed rows).
    func select(space newSpace: DaylightSpace) {
        guard newSpace != space else { return }
        // Only Home's own space is arranged, so leaving it ends Customize.
        if isCustomizing, newSpace != .overview {
            endCardResize()
            isCustomizing = false
            onCustomizingChanged?(false)
        }
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
        #if FM_SELFTESTS
        if debugInputsPinned { return }
        #endif
        self.fleetSnapshot = snapshot
        // UX5: the hero's all-clear detail line is freshness now rather than a
        // restatement of the two cards below it - see `heroDetail`. This is
        // the moment the reading was taken.
        self.fleetReadAt = Date()
        self.mergedPRs = mergedPRs
        self.prFetchFailure = prFetchFailure
        if let mergedPRs {
            lastGoodPRs = mergedPRs
            lastGoodPRsAt = fleetReadAt
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
    /// under the attention card, until the captain hides it.
    /// S17: the tip is a `HelmNotice` - an informational notice, so a tinted
    /// tile and no edge, which keeps UI-4's rule that only the attention card
    /// carries one on Home. "Hide tips" is its dismiss, remembered in
    /// `AppSettings.homeTipsDismissed`.
    lazy var tipRow: HelmNotice = {
        let notice = HelmNotice(dismissTitle: "Hide tips")
        notice.onDismiss = { [weak self] in self?.dismissTips() }
        return notice
    }()
    var shownTip: HomeTips.Tip?
    var shownTipDay = 0

    /// What the attention card was last composed from, and until when that
    /// composition holds (R2-PERF-06). The inputs carry no clock: the clock
    /// is `validUntil`.
    struct AttentionComposed {
        let inputs: DailyReviewInputs
        let extra: [NeedsAttentionItem]
        let clear: [String]
        let hasItems: Bool
        let headerTitle: String
        let validUntil: Date
    }
    var lastAttention: AttentionComposed?

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
        renderGreeting()
        renderFeelPass()
        renderAttention()
        renderTip()
        rebuildGrid()
        applyTheme(ThemeManager.shared.theme)
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
    static func composedContentWidth(available: CGFloat, modules: [DaylightModule],
                                     spans: (DaylightModule) -> Int = { $0.gridSpan }) -> CGFloat {
        guard available > 0, !modules.isEmpty else { return max(available, 0) }
        let maxColumns = HelmResponsiveGrid.columns(containerWidth: available,
                                                    minItemWidth: minModuleWidth,
                                                    spacing: gridSpacing)
        let spansNeeded = modules.reduce(0) { $0 + max(1, min(spans($1), maxColumns)) }
        let used = min(maxColumns, spansNeeded)
        guard used < maxColumns else { return available }
        let unit = HelmResponsiveGrid.itemWidth(containerWidth: available,
                                                columns: maxColumns,
                                                spacing: gridSpacing)
        return unit * CGFloat(used) + gridSpacing * CGFloat(used - 1)
    }

    func gridContainerWidth() -> CGFloat {
        let clip = scroll.contentView.bounds.width
        let usable = clip - Self.gutter * 2
        return usable > 0 ? usable : HelmResponsiveGrid.fallbackContainerWidth
    }

    /// The height the hub's columns share: the viewport less the page's own
    /// top and bottom margins.
    func gridContainerHeight() -> CGFloat {
        let usable = scroll.contentView.bounds.height - Self.contentTopMargin - Self.contentBottomMargin
        return usable > 0 ? usable : 600
    }

    /// GL-20's gate: only relay out when this page is actually on screen, and
    /// only when the width (or, on the hub, the height) genuinely changed. A resize fires many times per
    /// drag; rebuilding fifteen cards on every frame of one is the exact
    /// regression `ToolsController` measured (~3.6ms -> ~20ms per frame).
    func containerWidthMayHaveChanged() {
        guard isViewLoaded, !view.isHidden else { return }
        let width = gridContainerWidth()
        // The hub's row counts come from its height as well, so there a
        // height change rebuilds too; every other space is width-only.
        let heightChanged = usesDashboardLayout && abs(gridContainerHeight() - lastGridHeight) > 0.5
        guard abs(width - lastGridWidth) > 0.5 || heightChanged else { return }
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
    /// needs a different grid - the shelf's column count changed, or the hub
    /// crossed the width it falls back to the shelf at - and the caller
    /// rebuilds instead.
    func resizeGridInPlace(available: CGFloat) -> Bool {
        guard let built = gridLayoutKey, built.space == space, !gridWidthPins.isEmpty else { return false }
        let modules = visibleModules()
        guard built.modules == modules else { return false }
        let height = gridContainerHeight()
        if built.dashboard {
            guard dashboardRowViewsWouldApply(available: available, modules: modules) else { return false }
            let plan = dashboardPlan(available: available)
            for (pin, span) in gridWidthPins {
                pin.constant = HelmResponsiveGrid.proportionalWidth(containerWidth: available, span: span,
                                                                   spacing: Self.gridSpacing)
            }
            contentWidthConstraint?.constant = available
            attentionCard.setLayoutWidth(plan.width)
            for module in modules {
                guard let content = plan.contents[module] else { return false }
                cardsByModule[module]?.configureIfChanged(content)
            }
            for (module, ownHeight) in plan.ownHeights {
                dashboardOwnHeights[module]?.constant = ownHeight
            }
        } else if showsArrangedCards {
            // Home's arranged grid keeps its 24 columns at every width, so a
            // frame can only move the constants - unless a card crossed the
            // width it is widened at, which moves it between rows.
            guard built.spans == modules.map(cardSpan) else { return false }
            let unit = HomeCardGrid.unitWidth(containerWidth: available, spacing: Self.gridSpacing)
            for (pin, span) in gridWidthPins {
                pin.constant = unit * CGFloat(span) + Self.gridSpacing * CGFloat(span - 1)
            }
            contentWidthConstraint?.constant = available
            attentionCard.setLayoutWidth(available)
        } else {
            let width = Self.composedContentWidth(available: available, modules: modules, spans: cardSpan)
            let columns = HelmResponsiveGrid.columns(containerWidth: width, minItemWidth: Self.minModuleWidth,
                                                     spacing: Self.gridSpacing)
            guard columns == builtShelfColumns else { return false }
            let unit = HelmResponsiveGrid.itemWidth(containerWidth: width, columns: columns, spacing: Self.gridSpacing)
            for (pin, span) in gridWidthPins {
                pin.constant = unit * CGFloat(span) + Self.gridSpacing * CGFloat(span - 1)
            }
            contentWidthConstraint?.constant = width
            attentionCard.setLayoutWidth(width)
        }
        lastGridWidth = available
        lastGridHeight = height
        return true
    }

    func scrollToTop() {
        guard let clip = scroll.contentView as NSClipView? else { return }
        clip.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    @objc func refreshTapped() {
        onRefresh?()
        render()
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
        paintHeroBand(theme)
        paintTip(theme)
        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        greetingTitle.attributedStringValue = NSAttributedString(
            string: greetingTitle.stringValue,
            attributes: HelmType.displayTitleAttributes(color: HelmTheme.nsColor(theme.chromeInkHex)))
        greetingSummary.font = .systemFont(ofSize: HelmType.scaled(Self.greetingSummarySize))
        greetingSummary.textColor = HelmTheme.mutedInk(theme)
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
    func paintHeroBand(_ theme: HelmTheme) {
        for constraint in heroCardInsets { constraint.constant = 0 }
        heroCard.layer?.backgroundColor = NSColor.clear.cgColor
        heroCard.layer?.borderWidth = 0
        heroCard.layer?.cornerRadius = 0
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
    /// not merely that five cards exist. The dashboard's whole subject is
    /// which card sits where and how wide, and `cards` is a flat list that
    /// cannot see any of it.
    var gridRowsForTests: [NSStackView] { gridStack.arrangedSubviews.compactMap { $0 as? NSStackView } }
    /// Whether the grid was last laid out for the width the page has now.
    /// False from the moment the clip view changes width (the sidebar
    /// opening, a scroller appearing) until the main-queue turn on which
    /// `containerWidthMayHaveChanged` reflows the cards - the window a suite
    /// must wait out rather than guess at with a delay (R4-PROC-01).
    var gridIsCurrentForTests: Bool { abs(gridContainerWidth() - lastGridWidth) <= 0.5 }
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
    /// Customize's tray while it is in the page, or nil.
    var customizeTrayForTests: HomeCustomizeTray? { customizeTray.superview == nil ? nil : customizeTray }
    /// The controls each card wears while Customize is on.
    var cardStripsForTests: [DaylightModule: HomeCardCustomizeStrip] { cardStrips }
    /// The grips each card wears while Customize is on.
    var resizeHandlesForTests: [DaylightModule: [HomeCardResizeHandle]] { resizeHandles }
    /// The size badge, which is in the page only while a card is dragged.
    var sizeBadgeForTests: HomeCardSizeBadge { sizeBadge }
    func cardForTests(_ module: DaylightModule) -> HelmModuleCard? { cardsByModule[module] }
    /// The captain's Needs Attention card, so a suite can drive the real card
    /// on the real page rather than a card it built itself - which is what
    /// proves the wiring as well as the render.
    var attentionCardForTests: NeedsAttentionCard { attentionCard }
    /// REL-04: the verdict the hub's header and attention row are built from.
    var overviewAnswerForTests: FleetGreeting.Answer? { overviewAnswer() }
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

    /// A fabricated attention summary, rendered in place of the one the
    /// digest would compose. The tour lab's `demo attention N` and
    /// `HomeFitSelfTest` use it to put an exact number of rows on the page
    /// without seeding a Tasks store with dated tasks.
    /// P5: the attention card's rows, as its list holds them.
    var debugAttentionRows: [NSView] { attentionCard.debugRows }
    /// How many times the attention card's digest has been composed.
    var debugDigestCount = 0
    var debugAttentionCard: NeedsAttentionCard { attentionCard }
    /// R2-UX-01 (c): the attention card's signal rows and closing notes, as
    /// this page composes them now.
    var debugSignalAttentionIDs: [String] { signalAttentionItems().map(\.id) }
    var debugClearNotes: [String] { clearNotes() }
    var debugAttentionOverride: NeedsAttentionSummary?
    var debugAttentionSubline = "1 decision waiting - the crew is holding for you."
    /// The scroll view's document, for a render of the whole page rather
    /// than the part that fits the window.
    var debugDocumentView: NSView { document }

    /// The page's geometry as text: the viewport, the document, the overflow
    /// between them, the attention card and every module card's resolved and
    /// fitting heights. The tour lab's `measure` verb prints it; the numbers
    /// in the Home fit history entry came from it.
    func debugMeasureLines() -> [String] {
        view.layoutSubtreeIfNeeded()
        func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        var out: [String] = []
        out.append("viewport \(f(scroll.contentView.bounds.width))x\(f(scroll.contentView.bounds.height))")
        out.append("document height \(f(document.frame.height))")
        out.append("overflow \(f(document.frame.height - scroll.contentView.bounds.height))")
        out.append("grid width \(f(lastGridWidth))")
        out.append("attention card \(f(attentionCard.frame.width))x\(f(attentionCard.frame.height))"
                   + " fit \(f(attentionCard.fittingSize.height))")
        for (index, row) in attentionCard.debugRows.enumerated() {
            out.append("  attention row \(index) h \(f(row.frame.height))")
        }
        for card in cards {
            out.append("card \(card.debugHeaderText.title) \(f(card.frame.width))x\(f(card.frame.height))"
                       + " fit \(f(card.fittingSize.height))")
        }
        return out
    }
    #endif
}
