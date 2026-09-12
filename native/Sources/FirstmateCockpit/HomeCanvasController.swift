// Manjesh Grand Line - native macOS app.
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
//   - gotcha (13): the grid is `HelmResponsiveGrid.spanningRows(_:)`, because
//     the Morning briefing is two columns wide (§6.1, `DaylightModule.
//     gridSpan` - see that enum's own note for the three passes it took to
//     land there). That path creates a real per-card width constraint, unlike
//     `rows(_:)`, so every one of them is `HelmDaylightPriority.contentTie`
//     (499) - below `NSLayoutPriorityWindowSizeStayPut` - and no card can cap
//     the window.

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
        /// `fm/grandline-tasks-kanban-devops-split`: the shell's own shared
        /// instance, injected like every other store here - the canvas never
        /// *constructs* one (`checkCanvasConstructsNoStores` forbids exactly
        /// that), and this one caches its records in memory, so the card's
        /// count is a field read rather than a directory scan.
        let commandLibraryStore: CommandLibraryStore
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
    /// The hero band's own padding, on the one space that has a verdict to
    /// feature. `s5` horizontally and vertically gives the 40pt badge and the
    /// 30pt headline a card's worth of room without the band becoming a
    /// second page of its own.
    static let heroBandPadding: CGFloat = HelmMetrics.s5
    /// The strongest-to-faintest washes of the verdict's hue the band will
    /// try for its fill. Measured per theme rather than picked - see
    /// `heroWashFraction`.
    static let heroWashSteps: [CGFloat] = [0.22, 0.18, 0.14, 0.10, HelmAccentRow.signalWash]

    // MARK: Forwarded actions (never owned)

    var onOpenDestination: ((RailDestination) -> Void)?
    var onOpenShiftTask: ((String) -> Void)?
    /// The greeting row's Refresh - wired to the *existing* refresh triggers
    /// (`FleetController.refreshIfNeeded()` and `ReviewController`'s own), so
    /// this page still starts no work of its own.
    var onRefresh: (() -> Void)?
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
    /// `true` only while the hero is reporting a real fleet verdict, which
    /// is what earns the band its surface. Kept as state rather than
    /// re-derived in `applyTheme`, so the paint and the copy can never
    /// disagree about which hero is on screen.
    private var heroIsBanner = false
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
        stack.addArrangedSubview(gridStack)

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
        self.mergedPRs = mergedPRs
        self.prFetchFailure = prFetchFailure
        guard isViewLoaded else { return }
        // Synchronous, unlike the two burst sources below: Overview's refresh
        // completes at most once per refresh cycle, so there is nothing to
        // coalesce, and rendering immediately keeps this page's numbers
        // observably in step with the page that produced them.
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
            setHero(tint: nil,
                    symbol: space.heroSymbol,
                    kicker: "",
                    title: space.title,
                    detail: space.subtitle)
            return
        }
        guard let snapshot = fleetSnapshot else {
            // GL-14: nothing has been measured yet, so the hero says so
            // rather than rendering an all-clear it cannot stand behind.
            setHero(tint: nil,
                    symbol: space.heroSymbol,
                    kicker: "",
                    title: FleetGreeting.timeOfDay(),
                    detail: space.subtitle)
            return
        }
        let answer = FleetGreeting.answer(tasks: snapshot.tasks,
                                          readyCount: mergedPRs?.count ?? 0,
                                          prFetchFailure: prFetchFailure,
                                          homeOk: snapshot.homeOk)
        setHero(tint: answer.tint,
                symbol: answer.badgeSymbol,
                kicker: answer.kicker,
                title: answer.title,
                detail: answer.meta)
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
        // A `nil` tint is exactly "this hero has no verdict", which is also
        // exactly when the band must not put a surface under it: a space that
        // has measured nothing would otherwise wear the same card as an
        // all-clear and look like it were reporting one.
        heroIsBanner = tint != nil
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
        // than cells. Uniform *height* is the card's own
        // `HelmModuleCard.standardHeight`.
        let rows = HelmResponsiveGrid.spanningRows(
            modules,
            spans: { $0.gridSpan },
            containerWidth: width,
            minItemWidth: Self.minModuleWidth,
            spacing: Self.gridSpacing
        ) { [weak self] module, cardWidth in
            guard let self else { return NSView() }
            return self.makeCard(for: module, cardWidth: cardWidth)
        }

        for row in rows {
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
        }
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
        // The band's detail line is the one piece of hero copy carrying real
        // numbers ("0 crew working - 50 PRs ready to merge"), so on the space
        // that has a verdict it steps up a role. `sectionTitle()`, never a new
        // size: `HelmContrastSelfTest`'s type-scale table is a fixed list of
        // roles on purpose, and a hero-only literal would be a fifth size in a
        // scale this app spent a whole phase reducing to four.
        subtitleLabel.font = heroIsBanner ? HelmType.sectionTitle() : HelmType.body()
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        // C1's hero. The kicker is `mutedInk`, never the hero's own tint:
        // a `HelmTint` is safe as a fill or a bar and is *not* automatically
        // safe as text (`HelmContrast`'s own rule, and the §5.7 defect this
        // app has fixed three times). The tint reaches the badge, which is
        // contrast-guarded by `IconTileView`, and stops there.
        kickerLabel.font = HelmType.kicker()
        kickerLabel.textColor = HelmTheme.mutedInk(theme)
        heroBadge.applyTheme(theme)
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
    private func paintHeroBand(_ theme: HelmTheme) {
        // The padding *is* the difference between a hero and a plain page
        // header, so it moves with the paint rather than in `setHero`: that
        // runs before `loadView` on the very first `select(space:)`, when
        // there are no constraints to set yet.
        for constraint in heroCardInsets {
            let inset = heroIsBanner ? Self.heroBandPadding : 0
            // The trailing and bottom pins are negative offsets from their
            // own edge, so the sign follows the anchor rather than the value.
            let negative = constraint.firstAttribute == .trailing || constraint.firstAttribute == .bottom
            constraint.constant = negative ? -inset : inset
        }
        guard heroIsBanner else {
            // Off Overview the band is not a surface at all, so the header
            // renders as the plain row it has always been.
            heroCard.layer?.backgroundColor = NSColor.clear.cgColor
            heroCard.layer?.borderWidth = 0
            heroCard.layer?.cornerRadius = 0
            return
        }
        let tint = HelmTheme.nsColor(heroTint.hex(in: theme))
        heroCard.layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dModule : HelmMetrics.rCard
        heroCard.layer?.backgroundColor = Self.heroFill(tint: tint, theme: theme).cgColor
        heroCard.layer?.borderWidth = 1
        heroCard.layer?.borderColor = tint.withAlphaComponent(HelmAccentRow.borderAlpha).cgColor
    }

    /// The band's fill: the strongest wash of the verdict's hue that still
    /// leaves *both* lines of hero copy above the 4.5:1 text floor.
    ///
    /// Derived, never a literal, for the reason `HelmSelection.alphaLadder`
    /// and `HelmContrast.tintedSurface` derive theirs: this band has to read
    /// as a band on fourteen palettes whose `chromeBackgroundHex` runs from
    /// near-black to warm cream, and one alpha tuned on Daylight is either
    /// invisible or illegible on several of the others. Both lines are scored
    /// because they fail at different strengths - the muted detail line is
    /// the theme's ink at its own muted alpha, so it runs out of headroom
    /// well before the headline does.
    static func heroFill(tint: NSColor, theme: HelmTheme) -> NSColor {
        HelmContrast.color(HelmContrast.mix(HelmContrast.components(tint),
                                            HelmContrast.components(HelmTheme.nsColor(theme.chromeBackgroundHex)),
                                            Double(heroWashFraction(tint: tint, theme: theme))))
    }

    static func heroWashFraction(tint: NSColor, theme: HelmTheme) -> CGFloat {
        let base = HelmContrast.components(HelmTheme.nsColor(theme.chromeBackgroundHex))
        let hue = HelmContrast.components(tint)
        let ink = HelmContrast.components(HelmTheme.nsColor(theme.chromeInkHex))
        let mutedAlpha = Double(HelmTheme.mutedAlpha(for: theme))
        for step in heroWashSteps {
            let fill = HelmContrast.mix(hue, base, Double(step))
            // `mutedInk` is the ink at the theme's own alpha, so what it
            // resolves to depends on the surface under it - it has to be
            // flattened against *this* fill, never against the page.
            let muted = HelmContrast.mix(ink, fill, mutedAlpha)
            if HelmContrast.ratio(ink, fill) >= HelmContrast.textTarget,
               HelmContrast.ratio(muted, fill) >= HelmContrast.textTarget {
                return step
            }
        }
        // No wash at all, rather than the faintest one anyway.
        //
        // Measured: `solarized-dark`'s ink on a 7% wash of its own green
        // reaches 4.47:1, so even `HelmAccentRow`'s own signal-wash value -
        // the floor this ladder started with - is unaffordable there. (That
        // row never renders it on this palette: its wash is Daylight-only.)
        //
        // Zero leaves the band on the plain card surface, which is the one
        // pairing `HelmCard` already guarantees is legible, and the hue still
        // reaches the border - which is what separates the band from the page
        // in the three themes where `chromeBackgroundHex == backgroundHex`
        // anyway. A hero that is slightly less tinted beats a hero whose own
        // numbers cannot be read.
        return 0
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
            clauses.append(BriefingClause(text: "+\(hidden) more on Overview.", target: .none))
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
        if working.isEmpty && needs.isEmpty {
            content.body = .note("All hands idle. Nothing is running and nothing is waiting on you.")
            return
        }
        let rows = (needs + working).prefix(HelmModuleCard.maxPeekRows).map { task in
            HelmModulePeekRow(
                state: task.status == "working" ? .ok : .warn,
                text: task.id,
                value: task.status == "working" ? "working" : task.status.replacingOccurrences(of: "_", with: " "))
        }
        content.body = .peekRows(Array(rows))
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
        let ready = prs.filter { FleetDataSource.canMerge($0) }
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
                                     value: pr.checks == "none" ? "no checks" : pr.checks)
        }
        content.body = .peekRows(Array(rows))
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

    private func fillHealth(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own health
        // artwork, replacing the plain `waveform.path.ecg` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.health` case.
        content.artwork = HealthIcon.image
        let services = ServiceHealthRegistry.shared.knownServices()
        let healthy = services.filter { service in
            switch ServiceHealthRegistry.shared.state(service).verdict {
            case .healthy, .running: return true
            case .unknown, .degraded, .failing: return false
            }
        }
        content.subtitle = "background services"
        let failing = services.filter { ServiceHealthRegistry.shared.state($0).verdict == .failing }
        if !failing.isEmpty { content.chip = .bad("\(failing.count) failing") }
        let note: String
        if services.isEmpty {
            // B9: shorter copy as well as a third line - the note column
            // beside a 66pt gauge is genuinely narrow, and a summary that
            // needs three lines to say "fine" is not a summary.
            note = "Nothing has reported yet."
        } else if failing.isEmpty {
            note = "All reporting services healthy."
        } else {
            note = "\(failing.map { $0.title }.joined(separator: ", ")) needs a look."
        }
        content.body = .ring(value: healthy.count, total: services.count, title: "Healthy", note: note)
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
        content.chip = Self.pollerIsStillWarmingUp ? .mute("Checking\u{2026}") : nil
        content.body = .note(Self.pollerIsStillWarmingUp ? checking : stale)
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
        content.body = .note("Jot down a thought on a colored sticky note, anywhere on the board.")
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
    var visibleModulesForTests: [DaylightModule] { visibleModules() }
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
    /// Plan B's hero band, as the surface it really resolved to - a paint
    /// this app cannot see any other way, since `cacheDisplay` renders a
    /// band and a bare row equally happily.
    var heroBandForTests: (isBanner: Bool, fill: NSColor?, borderWidth: CGFloat, radius: CGFloat, inset: CGFloat) {
        (heroIsBanner,
         heroCard.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
         heroCard.layer?.borderWidth ?? 0,
         heroCard.layer?.cornerRadius ?? 0,
         heroCardInsets.first(where: { $0.firstAttribute == .leading })?.constant ?? 0)
    }
    /// The detail line's resolved size, so "the hero's copy steps up on the
    /// space with a verdict" is asserted rather than assumed.
    var heroDetailPointSizeForTests: CGFloat { subtitleLabel.font?.pointSize ?? 0 }
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
