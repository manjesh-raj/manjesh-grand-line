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
    }

    /// §6.1's grid: minimum column width 255, gap 16.
    static let minModuleWidth: CGFloat = 255
    static let gridSpacing: CGFloat = 16
    /// §2.7's canvas gutter.
    static let gutter: CGFloat = 22

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

    private let sources: Sources
    private var space: DaylightSpace = .overview

    // MARK: Views

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let refreshButton = HelmButton(title: "Refresh", variant: .quiet, symbol: "arrow.clockwise")
    private let gridStack = NSStackView()

    private var cards: [HelmModuleCard] = []
    private var themeToken: ThemeObservation?
    private var signalCountsToken: BackgroundSignalsPoller.CountsObservation?
    private var windowResizeObserver: NSObjectProtocol?
    private var lastGridWidth: CGFloat = 0
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

        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let greetingRow = NSStackView(views: [textStack, refreshButton])
        greetingRow.orientation = .horizontal
        greetingRow.alignment = .centerY
        greetingRow.distribution = .fill
        greetingRow.spacing = HelmMetrics.s4
        greetingRow.translatesAutoresizingMaskIntoConstraints = false

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
        stack.addArrangedSubview(greetingRow)
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

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.gutter),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.gutter),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: HelmMetrics.s2),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -44),

            greetingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            gridStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

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
        guard space == .overview else {
            greetingLabel.stringValue = space.title
            subtitleLabel.stringValue = space.subtitle
            return
        }
        guard let snapshot = fleetSnapshot else {
            greetingLabel.stringValue = FleetGreeting.timeOfDay()
            subtitleLabel.stringValue = space.subtitle
            return
        }
        greetingLabel.stringValue = FleetGreeting.greeting(captain: snapshot.captain)
        let answer = FleetGreeting.answer(tasks: snapshot.tasks,
                                          readyCount: mergedPRs?.count ?? 0,
                                          prFetchFailure: prFetchFailure,
                                          homeOk: snapshot.homeOk)
        subtitleLabel.stringValue = answer.canvasLine
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

        let width = gridContainerWidth()
        lastGridWidth = width
        let modules = visibleModules()

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
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.font = HelmType.body()
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        for card in cards { card.applyTheme(theme) }
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
        case .vault: fillVault(&content)
        case .docs: fillDocs(&content)
        case .runbooks: fillRunbooks(&content)
        case .postmortems: fillPostmortems(&content)
        case .dictation: fillDictation(&content)
        case .tools: fillTools(&content)
        case .settings: fillSettings(&content)
        }
        return content
    }

    /// F12's record, read straight out of `AppSettings` - already generated,
    /// never regenerated here. A canvas that could trigger a `claude -p` call
    /// would be a new cost on every visit.
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
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        content.subtitle = "generated \(formatter.string(from: record.generatedAt))"
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

    private func fillConsole(_ content: inout HelmModuleCard.Content) {
        let rows = consoleTabsProvider?() ?? []
        content.subtitle = rows.isEmpty ? "no tabs open" : "\(rows.count) tab\(rows.count == 1 ? "" : "s") open"
        let connected = connectedHostIDs?() ?? []
        if !connected.isEmpty { content.chip = .mute("\(connected.count) host live") }
        content.body = rows.isEmpty
            ? .note("Open a shell, or connect a saved host.")
            : .peekRows(Array(rows.prefix(HelmModuleCard.maxPeekRows)))
    }

    private func fillHealth(_ content: inout HelmModuleCard.Content) {
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
            note = "No service has reported yet this session."
        } else if failing.isEmpty {
            note = "Everything that has reported is healthy."
        } else {
            note = "\(failing.map { $0.title }.joined(separator: ", ")) needs a look."
        }
        content.body = .ring(value: healthy.count, total: services.count, title: "Healthy", note: note)
    }

    private func fillHosts(_ content: inout HelmModuleCard.Content) {
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
        let schedules = sources.scheduleStore.schedules
        content.subtitle = "unattended"
        guard !schedules.isEmpty else {
            content.body = .note("Nothing scheduled. Add one to have it run on its own.")
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

    private func fillVault(_ content: inout HelmModuleCard.Content) {
        // The last snapshot the poller took, never a fresh `av` shell-out -
        // §6.1: "the module renders the LAST snapshot, it does not shell out
        // on canvas load".
        let counts = BackgroundSignalsPoller.shared.lastCounts
        content.subtitle = "names only"
        guard let secrets = counts.vaultSecrets else {
            // The same two states as the four Setup modules above, for the
            // same reason.
            fillPendingSetupSignal(&content,
                                   checking: "Checking Automic Vault\u{2026} this card fills itself in when the first pass lands.",
                                   stale: "Vault hasn't been checked yet this session.")
            return
        }
        if let attention = counts.vaultAttention, attention > 0 {
            content.chip = .warn("\(attention) need\(attention == 1 ? "s" : "") a look")
        }
        content.body = .metric(value: "\(secrets)",
                               unit: secrets == 1 ? "secret" : "secrets",
                               note: "Hardened in Automic Vault's Keychain. Values never leave it.")
    }

    /// `fm/grandline-docs-split-runbooks-postmortems` narrowed this card to
    /// the Playbook alone - Runbooks and Postmortems are `fillRunbooks`/
    /// `fillPostmortems` below now, each with its own module card. `DocsStore`
    /// is a plain static enum (no store to inject), so this reads exactly
    /// what `DocsController.drillHeaderSubtitle`'s own Playbook branch reads -
    /// the real sync state, never a fabricated "offline copy" claim.
    private func fillDocs(_ content: inout HelmModuleCard.Content) {
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
        content.subtitle = "\(ToolKind.allCases.count) utilities"
        content.body = .note(ToolKind.allCases.prefix(5).map { $0.shortName }.joined(separator: " \u{00B7} ") + " and more")
    }

    private func fillSettings(_ content: inout HelmModuleCard.Content) {
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
    var greetingForTests: (title: String, subtitle: String) {
        (greetingLabel.stringValue, subtitleLabel.stringValue)
    }
    var gridRowCountForTests: Int { gridStack.arrangedSubviews.count }
    /// Force one synchronous render, bypassing the coalescing hop - so a
    /// self-test can establish a known starting state before driving the
    /// signal it is actually testing.
    func debugRenderNow() { render() }
}
