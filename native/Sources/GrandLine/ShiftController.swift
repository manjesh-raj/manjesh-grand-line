// Grand Line - native macOS app.
//
// The `.shift` rail destination: Tasks (cockpit-shift-foundation, phase 1 of
// a multi-phase build - `docs/history/08-tasks-and-shift.md`). The page is a
// `FlippedView`-backed scroll area holding the hero band (T-4, and since Tf-2
// the page's filters), then the chosen view - the board, the List tab's
// table or the calendar - with the Follow-ups and Projects cards under it,
// or Weekly review in its place. The tasks and follow-ups lists are
// `HelmDataTable`s rather than a plain `NSStackView` of permanent rows, per
// this app's own hard-learned Diff-tool lesson (see `DiffResultView.swift`'s
// header) about what happens to that pattern once a list grows into the
// hundreds.
//
// Subtasks never appear as rows in the List tab's table: a project's own
// detail is the one place they render (see the rule stated in
// ShiftModels.swift's header).

import AppKit

final class ShiftController: NSViewController, DaylightDrillActions {

    let store: ShiftStore

    /// Internal rather than private for `ShiftController+Calendar.swift`,
    /// the same family (GL-36).
    let scroll = NSScrollView()
    let contentStack = NSStackView()

    /// GL-16: see `UpdatesController.checkAllPill` - a clear-coloured
    /// `HoverHighlightView` renders identically to the plain `NSView` this
    /// was and inherits the shared press/focus/keyboard behaviour.
    private let syncPill = HoverHighlightView()
    /// UI-19: "Synced" is the default state, so it is a dot and a word; every
    /// other state is a pill. Both live in `syncPill`, exactly one showing.
    private let syncWord = HelmStatusPill(style: .dotWord)
    private let syncCapsule = HelmStatusPill(style: .pill)

    private let followUpsHeader = NSTextField(labelWithString: "")
    private let followUpsCountBadge = NSTextField(labelWithString: "")
    let followUpPanel = HelmCard()

    private let projectsHeader = NSTextField(labelWithString: "")
    private let projectsCountBadge = NSTextField(labelWithString: "")
    private let projectsPanel = HelmCard()
    /// R2-UX-07: the dashboard's sections a start-here state stands in for:
    /// the Follow-ups card and the Projects card.
    private var startHereReplaces: [NSView] { [followUpPanel, projectsPanel] }
    /// R4-UI-09: Follow-ups as a lane on the board while four lanes fit.
    let followUpLane = ShiftFollowUpLaneView()
    /// Whether four lanes fit the board at the page's width now
    /// (`followUpLaneMinimumBoardWidth`).
    private var boardFitsFollowUpLane = true
    /// The app's one page-level empty state, in the shape every module's
    /// takes: its own artwork, one sentence, and one example to start from.
    /// New task is the toolbar's far-right primary already.
    private lazy var startHereState: HelmEmptyState = {
        let example = HelmButton(title: "Add an example task", variant: .secondary, symbol: "plus")
        example.target = self
        example.action = #selector(addExampleTaskTapped)
        let state = HelmEmptyState(
            symbol: "checkmark.circle", title: "Start with a task",
            body: "A task is one thing to do, with a due date, a project and a priority if you want them. "
                + "Add your own with New task, or start from an example.",
            size: .standard, accessory: example, hue: RailDestination.shift.domainHue,
            artwork: RailDestination.shift.drillHeaderArtwork)
        state.translatesAutoresizingMaskIntoConstraints = false
        return state
    }()

    private let projectsGridContainer = NSStackView()
    private let projectsDetailContainer = NSStackView()

    /// Every panel header on the page, so `applyTheme` hands each one the
    /// theme - `HelmSectionHeader` is given its theme, like `HelmCard`.
    private var sectionHeaders: [HelmSectionHeader] = []
    /// UXP-02: the project grid's live cards (or its empty state), so the
    /// theme pass can repaint what the last data render built.
    private var projectCards: [ShiftProjectCardView] = []
    private weak var projectsGridEmptyState: HelmEmptyState?

    // MARK: Weekly Review (phase 5, cockpit-shift-power-features)

    /// The task views, or Weekly Review (a distinct summary view). This keeps
    /// Shift a single consolidated destination (the captain's phase-1
    /// decision, restated in AGENTS.md) while still giving Weekly Review "its
    /// own view" rather than squeezing it into the daily dashboard.
    enum ShiftTopLevelView: String { case dashboard, weeklyReview }
    var topLevelView: ShiftTopLevelView = .dashboard
    let dashboardContainer = NSStackView()
    private let weeklyReviewContainer = NSStackView()

    // MARK: The board (fm/grandline-tasks-kanban-devops-split)

    /// How the captain's tasks are laid out: a Kanban board of three status
    /// columns, every task as one table (the List tab), or the calendar.
    ///
    /// The board is the captain's own ask - a flat list never answered "what
    /// is actually in flight right now", which is the question he opens this
    /// page with. The list is not a legacy fallback either: it is the only
    /// view that shows *every* active task at once, sorted by due date, which
    /// is exactly what a board deliberately is not.
    ///
    /// `String`-backed: a view's raw value is the id `selectView(_:)` takes.
    ///
    /// The third is the calendar (`TaskCalendarController`, embedded by
    /// `ShiftController+Calendar.swift`). F5 put it here, the captain moved
    /// it to a sidebar row of its own, and the tasks-calendar plan's PR 4
    /// brought it back as this view with that row as its door, so it shares
    /// the page's filters, project picker and New task rather than having
    /// none (`docs/history/34-recurrence-and-calendar.md`).
    enum ShiftTasksView: String { case board, list, calendar }
    private(set) var tasksView: ShiftTasksView = .board
    /// UI-15: the page has **one** view switcher - Board, List, Calendar and
    /// Weekly review, which the window toolbar draws as Tasks' tabs
    /// (`ModuleTabHosting`, at the end of this file). Weekly Review keeps its
    /// Shift-menu item and its ⌘K entry, both of which call
    /// `showWeeklyReview()`. The calendar's Day, Week, Month and Agenda are
    /// its card's own pills, not a second switcher here.
    private static let reviewViewID = "review"
    var onModuleTabChanged: (() -> Void)?

    // MARK: The Calendar view (tasks-calendar plan PR 4)

    /// Tasks' Calendar view, built the first time it shows
    /// (`ShiftController+Calendar.swift`).
    lazy var calendar: TaskCalendarController = makeCalendar()
    /// The calendar's place in the page, under the board's slot. Arranged in
    /// the dashboard the first time the view shows.
    let calendarSection = NSView()
    /// The section's height: the visible height under the hero band
    /// (`applyCalendarHeight`).
    var calendarHeightTie: NSLayoutConstraint?

    /// Which slice of the captain's tasks the page is showing - the hero
    /// band's figures and Smart views pills, and the calendar head's scope
    /// menu (Tf-2, Cf-4).
    ///
    /// Deliberately **not** a project filter: that is its own orthogonal
    /// question with its own menu, which shows and sets the one
    /// `projectFilter`. What a scope carries is the slice a project cannot
    /// state - "what is due today", "what is late", "what did I mark high",
    /// "what have I touched lately".
    ///
    /// `String`-backed: a scope's raw value is the id the band and the scope
    /// menu hand back.
    enum ShiftTaskScope: String, CaseIterable {
        case all, dueToday = "due_today", overdue
        case myPriorities = "my_priorities", recentlyUpdated = "recently_updated"

        /// The Workspace group: the slices that carry a live count, each one
        /// a figure on the hero band.
        static let workspaceCases: [ShiftTaskScope] = [.all, .dueToday, .overdue]

        /// The Smart views group - derived slices with no figure of their own.
        ///
        /// Both are backed by fields `ShiftTask` genuinely carries
        /// (`priority`, `updatedAt`); neither invents a signal, which is why
        /// the reference's two smart views are the two that shipped and not a
        /// third that would have needed a new persisted field.
        static let smartViewCases: [ShiftTaskScope] = [.myPriorities, .recentlyUpdated]

        var title: String {
            switch self {
            case .all: return "All tasks"
            case .dueToday: return StateWord.dueToday.label
            case .overdue: return StateWord.overdue.label
            case .myPriorities: return "My priorities"
            case .recentlyUpdated: return "Recently updated"
            }
        }

        /// The scope menu's glyph for the slice.
        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .dueToday: return "sun.max"
            case .overdue: return "exclamationmark.triangle"
            case .myPriorities: return "bolt"
            case .recentlyUpdated: return "clock.arrow.circlepath"
            }
        }
    }

    /// How far back "Recently updated" looks. A week, the same window the Done
    /// column already uses - so "recent" means one thing on this page.
    private static let recentlyUpdatedWindowDays = 7

    var taskScope: ShiftTaskScope = .all

    /// The page's sort, remembered per machine: how the board's open lanes
    /// and the list are ordered. Due date is the default because it is what
    /// the page always sorted by. S09 of the 2026-11-17 UI/UX proposals
    /// moved the Done lane's window out of the sort's row; it is the Done
    /// lane's count now (`ShiftBoardColumnView`) and the List's Done group
    /// header.
    private var taskSort: ShiftTaskSort = AppDefaults.store.string(forKey: ShiftTaskSort.defaultsKey)
        .flatMap(ShiftTaskSort.init(rawValue:)) ?? .dueDate

    let boardSection = NSStackView()

    /// UI-31 / GL-14: a task file that failed to parse is a stated failure
    /// naming the file and the line, never "0 open tasks" over empty lanes.
    /// The store already refuses to write such a file (GL-01); this card is
    /// the page saying so.
    private let failedReadCard = HelmCard()
    private let failedReadHeader = HelmSectionHeader(size: .hero)
    private let failedReadOpenButton = HelmButton(title: "Open file", variant: .secondary, size: .small)
    private var failedReadURL: URL?
    private let boardView = ShiftBoardView()
    /// `nil` = every project. UI-17: one project menu sets it - the band's
    /// project pill and the calendar head's project menu open the same menu
    /// (`projectMenu()`). The chip row that once repeated the filter above
    /// the board is gone.
    var projectFilter: String?

    /// How far back the Done column looks.
    ///
    /// Completed tasks do not live in `active.yaml` - they are filed into
    /// `tasks/completed/<YYYY-MM>.yaml` by month (see
    /// `ShiftStore.setTaskCompleted`), so "Done" could mean every task ever
    /// finished. That is not a column, it is an archive: it would grow
    /// without bound and bury the two columns a board is actually for. A week
    /// matches the window Weekly Review already reasons in, and anything
    /// older is still reachable through a project's own detail page.
    static let doneColumnLookbackDays = 7

    /// The Done window as the lane count and the List's group header say it
    /// (S09): "last 7 days".
    static var doneWindowCaption: String { "last \(doneColumnLookbackDays) days" }

    private let reviewGreeting = NSTextField(labelWithString: "")
    /// The pushed-back list, as flat rows inside its card (Rule 1).
    private let reviewPushedBackList = HelmFlatList()
    private var reviewPushedBackListWidth: NSLayoutConstraint?
    private let reviewPushedBackPanel = HelmCard()
    private let reviewPushedBackHeader = NSTextField(labelWithString: "Pushed back repeatedly")
    private let reviewPushedBackStack = NSStackView()

    // MARK: F7's "time on tasks" tile

    /// Weekly Review's focus-time panel: today's total as a headline, and
    /// the last seven days as a bar chart.
    ///
    /// A `HelmCard` with a chart rather than a fourth `HelmStatTile`,
    /// because the three tiles above it are single counts and this is a
    /// duration with a shape - "2h 05m today" is the number, and "against a
    /// week that looks like this" is the thing the tile is actually for. The
    /// headline keeps the tiles' own typography so the two read as one page.
    private let reviewFocusPanel = HelmCard()
    /// R4-UI-09: next week's agenda, under Time on tasks and Pushed back
    /// repeatedly, where the page's lower half was blank at 1512x950.
    private let reviewAgendaPanel = HelmCard()
    private let reviewAgendaStack = NSStackView()
    private let reviewAgendaList = HelmFlatList()
    private let reviewAgendaHeader = NSTextField(labelWithString: "Coming up next week")
    private let reviewAgendaCount = HelmCountBadge()
    private var reviewAgendaListWidth: NSLayoutConstraint?
    private let reviewFocusHeader = NSTextField(labelWithString: "Time on tasks")
    private let reviewFocusHeadline = NSTextField(labelWithString: "")
    private let reviewFocusCaption = NSTextField(labelWithString: "")
    private let reviewFocusChart = FocusWeekBarView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var expandedTaskIDs: Set<String> = []
    /// `nil` until the sync has reported a real status - UI-19: the page used
    /// to say "Synced" before anything had synced.
    private var syncStatus: ShiftGitSync.Status?

    /// The Projects section's own navigation state - a grid of cards, or one
    /// project's detail (task list + edit form). Kept separate from the
    /// page's overall render() so switching between the two doesn't need to
    /// re-fetch tasks/follow-ups stats.
    private enum ShiftProjectsView: Equatable {
        case grid
        case detail(String)
    }
    private var projectsView: ShiftProjectsView = .grid

    private static let projectCardMinWidth: CGFloat = 260
    private static let projectCardSpacing: CGFloat = 12

    // MARK: The hero band and the tables (stage 7)

    /// T-4 on the page-redesign board: the page's hero as a slim band
    /// (`ShiftHeroBand.swift`). Board and List show it; Calendar (which fills
    /// the page), Weekly review and a project's own page do not.
    ///
    /// Tf-2 on the five-screen redesign board: the band is also the page's
    /// filters. Its figures pick the scope and its glass pills hold Smart
    /// views and the project and sort menus, so the page has no filter row
    /// and no grey count line above the band. Calendar's month
    /// head carries the same filters as menus (Cf-4,
    /// `ShiftCalendarHeroHead.setFilters`).
    private(set) lazy var heroBand = ShiftTasksHeroBand()
    /// Whether the band's Follow-ups figure jumps to the Follow-ups card: not
    /// while Follow-ups is a lane on the board, which is on screen already
    /// (R4-UI-09).
    private var followUpsJumpWanted = true
    /// The List tab: every task the filters keep, as one table.
    private lazy var tasksTable: HelmDataTable = {
        let table = HelmDataTable(columns: [
            .init(id: "done", title: "", width: 40),
            .init(id: "task", title: "Task", width: 320, minWidth: 220, flexible: true),
            .init(id: "project", title: "Project", width: 180),
            .init(id: "status", title: "Status", width: 120, hiddenBelow: 760),
            .init(id: "priority", title: "Priority", width: 100, hiddenBelow: 680),
            .init(id: "due", title: "Due", width: 130),
        ], actionsWidth: 120)
        table.sizesToFitRows = true
        table.accessibilityName = "Tasks"
        return table
    }()
    /// The Follow-ups card's rows, as the List tab's table draws a task: a
    /// check, the columns and a ⋯ menu that holds every action a follow-up
    /// has, Delete included. The flat list it replaced only offered those on
    /// a right click nobody could see, so a follow-up looked like it could
    /// be ticked off and nothing else. It draws in `followUpPanel` itself,
    /// under the card's own header and Add.
    private lazy var followUpsTable: HelmDataTable = {
        let table = HelmDataTable(columns: [
            .init(id: "done", title: "", width: 40),
            .init(id: "followUp", title: "Follow-up", width: 320, minWidth: 220, flexible: true),
            .init(id: "project", title: "Project", width: 180),
            .init(id: "status", title: "Status", width: 120, hiddenBelow: 760),
            .init(id: "priority", title: "Priority", width: 100, hiddenBelow: 680),
            .init(id: "due", title: "Due", width: 130),
        ], actionsWidth: 120, card: followUpPanel)
        table.sizesToFitRows = true
        table.accessibilityName = "Follow-ups"
        return table
    }()
    /// Weekly review's five figures: a `.boxed` `HelmKPIStrip` (S14), each
    /// with its detail line.
    private lazy var reviewCardsRow = HelmKPIStrip(density: .boxed)
    /// Time on tasks beside Pushed back repeatedly.
    private let reviewLowerRow = NSStackView()
    /// The strip's "pushed back 2+ times" figure, which the five cards do not
    /// carry: the Pushed back panel's own count.
    private let reviewPushedBackCount = HelmCountBadge()

    /// F7's timer. Optional so every existing construction site (and every
    /// self-test that mounts this page to ask about something else) keeps
    /// working unchanged - a page with no timer simply renders no focus
    /// affordance, rather than needing a stub one.
    private let focusTimer: FocusTimerController?
    private var focusTimerToken: UUID?
    /// B-01: the page's turn-over at midnight (`DayRollover`).
    private var dayRolloverToken: NSObjectProtocol?

    init(store: ShiftStore, focusTimer: FocusTimerController? = nil) {
        self.store = store
        self.focusTimer = focusTimer
        super.init(nibName: nil, bundle: nil)
    }


    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        // FlippedView, not a plain NSView - see FleetController.swift's
        // header for why a non-flipped document view leaves a blank gap
        // above the header while content is still shorter than the
        // viewport.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        configureSyncPill()
        let followUpSection = buildFollowUpSection()
        let projectsSection = buildProjectsSection()
        buildBoardSection()

        // The dashboard, top to bottom: the failed-read card, the board (or
        // the List tab's table, or the calendar, each in its place under it),
        // then Follow-ups and Projects, each full width.
        //
        // Follow-ups is a lane on the board while four lanes fit, so its card
        // shows on the List tab and under a board too narrow for the lane
        // (R4-UI-09). Projects is its own full-width section on the List tab
        // - it renders a multi-column card grid of its own, and reads better
        // spanning the page than confined to half of it (the captain's own
        // correction of Daylight §7's two-column reading).
        dashboardContainer.orientation = .vertical
        dashboardContainer.alignment = .leading
        dashboardContainer.spacing = HelmMetrics.s4
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        buildFailedReadCard()
        dashboardContainer.addArrangedSubview(failedReadCard)
        dashboardContainer.addArrangedSubview(boardSection)
        dashboardContainer.addArrangedSubview(followUpSection)
        dashboardContainer.addArrangedSubview(projectsSection)
        // The project *detail* is also a direct child of the dashboard: it
        // takes the whole page when open (`applyProjectDetailFullPage`), so
        // nesting it inside any column would cap it at that column's width.
        dashboardContainer.addArrangedSubview(projectsDetailContainer)

        let weeklyReviewSection = buildWeeklyReviewSection()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        // UI-33: the page's vertical rhythm is the scale's 16, with 24 at the
        // foot - the off-scale 20 and 28 it used to carry are gone.
        contentStack.spacing = HelmMetrics.s4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(dashboardContainer)
        contentStack.addArrangedSubview(weeklyReviewSection)

        content.addSubview(contentStack)
        // R2-UX-10: held so it is active only while Weekly review shows. A
        // hidden view keeps its constraints (gotcha (15)), and once rendered
        // the review's rows hold about 920pt - so this tie made the whole
        // page that wide on Board and List too, and the window grew when the
        // shell's sidebar came back.
        weeklyReviewWidthTie = weeklyReviewSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.contentTopInset),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -HelmMetrics.s5),
            dashboardContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            followUpSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectsDetailContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            boardSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            failedReadCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        // Whether Follow-ups fits on the board follows the column's width
        // (`contentColumnDidResize`).
        contentStack.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentColumnDidResize),
                                               name: NSView.frameDidChangeNotification, object: contentStack)

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
            // AGENTS.md gotcha #4: the document view is pinned to the *clip*
            // view, never the outer scroll view.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // F7. Weekly Review's tile moves when the timer does, and only while
        // the review is on screen (`focusStateChanged`).
        if let focusTimer {
            focusTimerToken = focusTimer.observe { [weak self] in self?.focusStateChanged() }
        }

        // The first paint shows the chosen view only - the List must not
        // sit mounted under the Board before the first render runs.
        applyTasksViewVisibility()

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil
        )

        store.gitSync?.observeStatus { [weak self] status in
            guard let self else { return }
            // The first delivery is the sync's *current* value, which before
            // any pull or push is only its initial default - not a status.
            self.syncStatus = (self.store.gitSync?.hasReportedStatus ?? false) ? status : nil
            self.applySyncPill()
        }

        // REL-02: a pull applied while this page is open repaints it. The
        // store fires its handlers for every local edit too, and this page
        // already renders synchronously after its own edits, so the repaint
        // is coalesced onto the next main-queue turn and skipped when a
        // render has happened since.
        store.observe { [weak self] in self?.scheduleRenderForStoreChange() }

        // Full review 2026-11-25, B-01: the kicker's date, every "Due today"
        // and the overdue count turn over at midnight with no store change.
        dayRolloverToken = DayRollover.observe { [weak self] previousDay, _ in
            self?.dayDidChange(from: previousDay)
        }

        // REL-01: the first paint is the store, not the pre-render state.
        // `ShiftStore.init` already read every file synchronously, but the
        // only path to a render was `viewWillAppear`'s background reload -
        // one main-queue turn after a four-file parse, and never at all in a
        // window that is not ordered front. Until then the lanes showed
        // their skeletons, the counts said 0 while the drill subtitle
        // (which reads the store directly) said 7, and the project detail
        // sat under the grid. The reload in `viewWillAppear` now only picks
        // up an edit made outside this page, the contract
        // `HelmBackgroundReload` states for the other pages.
        render()

        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the page builds its sidebar presentation as part of loading.
        buildSidebarPresentation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let dayRolloverToken { NotificationCenter.default.removeObserver(dayRolloverToken) }
        // F7: this page observes the timer for its row highlight and its
        // Weekly Review tile; an observation is unregistered where it was
        // made, this app's convention everywhere else.
        if let focusTimerToken { focusTimer?.unobserve(focusTimerToken) }
    }

    /// Mirrors `ToolsController`'s own resize-gating fix (fm/cockpit-tools-
    /// yaml-quotes-diff-perf's sibling perf fix): only re-flow the grid while
    /// it's actually the visible view, so a captain's resize elsewhere in the
    /// app never pays for laying out project cards nobody is looking at.
    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        guard !view.isHidden, projectsView == .grid else { return }
        view.layoutSubtreeIfNeeded()
        rebuildProjectsGrid()
    }

    private let scrollMemory = HelmScrollMemory()

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scrollMemory.remember(scroll)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        // P3: keep the captain's place unless the page changed (`HelmScrollMemory`).
        scrollMemory.restore(scroll) { scrollToTop() }
        // P3 (`data/grand-line-e2e-audit/report.md`): the four YAML files are
        // parsed off the main thread now, so a tab switch is not four
        // synchronous file parses before the page can draw (measured at 92ms
        // for a steady-state revisit - ~11 dropped frames at 120Hz). The page
        // keeps showing the data it already had until the new read lands,
        // which is the same data in every case except a genuine external edit.
        // Everything that mutates the store still happens on the main thread -
        // see `ShiftStore.reloadAllAsync`.
        store.reloadAllAsync { [weak self] in self?.render() }
    }

    func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Building chrome

    /// Daylight §6.4 takes this page's title: "the old in-page hero titles and
    /// the old top-bar title both disappear - the drill header IS the
    /// destination name". So the greeting and the date line are gone from the
    /// page, and the live counts they used to sit beside are what the drill
    /// header's own subtitle carries (`drillHeaderSubtitle`).
    ///
    /// What survives of this page's own header is the sync pill, which is now
    /// handed to the drill header's action cluster (`drillHeaderActions`) -
    /// so there is no in-page header row left at all, and this method only
    /// prepares the pill the shell will position.
    private func configureSyncPill() {
        guard store.gitSync != nil else { return }
        syncPill.translatesAutoresizingMaskIntoConstraints = false
        for pill in [syncWord, syncCapsule] {
            syncPill.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: syncPill.leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: syncPill.trailingAnchor),
                pill.topAnchor.constraint(equalTo: syncPill.topAnchor),
                pill.bottomAnchor.constraint(equalTo: syncPill.bottomAnchor),
            ])
        }
        let syncPillClick = NSClickGestureRecognizer(target: self, action: #selector(syncPillClicked))
        syncPill.addGestureRecognizer(syncPillClick)
        syncPill.accessibilityLabelOverride = "Sync status - open conflict resolution"
        applySyncPill()
    }

    // MARK: Drill header (Daylight §6.4)

    /// The sync pill, and only when `store.gitSync` is real.
    ///
    /// `store.gitSync` is a `let` fixed for this controller's whole lifetime
    /// (decided at store construction by whether `FM_SHIFT_DIR` was set), so
    /// this is decided once here rather than by toggling `isHidden` - the same
    /// call `buildHeader` made before Phase 4, for the same reason: a view
    /// never handed over cannot be shown by a later code path that forgets the
    /// rule, and cannot report a stale on-screen frame to anything walking the
    /// view tree.
    /// The page's own primary action, and the sync pill when there is real git
    /// sync behind it.
    ///
    /// **"New task" is genuinely page-level, not a hoisted copy.** The rule
    /// this cluster follows is that it carries a page's own actions and never
    /// duplicates a control sitting a few points below it - which is why
    /// Console and three of the four Setup pages leave it empty. Here the only
    /// other way to start a task is a lane's own "+ Add task", which presets
    /// that lane's status, so without it there is no plain "new task" at all,
    /// which is exactly the gap the captain asked for a primary button to
    /// fill.
    ///
    /// Built once and handed over on every read, never rebuilt per read - a
    /// fresh copy each time could not carry state (the property
    /// `DaylightDrillPageSlice4SelfTest` pins for Vault's own Refresh).
    var drillHeaderActions: [NSView] {
        // R5-UX-04: the Calendar's toolbar carries Today while it shows,
        // where the card leaves its own Today to it.
        let today: [NSView] = tasksView == .calendar ? [calendarTodayButton] : []
        return today + (store.gitSync == nil ? [newTaskButton] : [syncPill, newTaskButton])
    }

    /// R5-UX-04: the page's actions changed - the Calendar view brings its
    /// Today button and takes it away again.
    var onDrillActionsChanged: (() -> Void)?

    /// R5-UX-04: Today on the Calendar's toolbar, the card's own Today.
    private lazy var calendarTodayButton: HelmButton = {
        let button = HelmButton(title: "Today", variant: .secondary, size: .small,
                                target: self, action: #selector(calendarTodayClicked))
        button.toolTip = "Show today"
        return button
    }()

    @objc private func calendarTodayClicked() { calendar.showToday() }

    /// `.primary` - the accent-filled pill. At most one per cluster, and this
    /// is the page's one primary action.
    private lazy var newTaskButton: HelmButton = {
        let button = HelmButton(title: "New task", variant: .primary, size: .small,
                                symbol: "plus", target: self, action: #selector(newTaskClicked))
        button.toolTip = "New Task (\u{2318}N)"
        return button
    }()

    /// The page's numbers, from **one** counting pass (UI-18) - the store's
    /// own `summary`, which the Calendar view's header reads too
    /// (R5-BUG-04).
    ///
    /// The subtitle and the hero band both read this, so they cannot
    /// disagree, and both follow the project filter - picking "Ideas" in the
    /// project menu makes "11 open" become the number of open tasks in Ideas,
    /// and the follow-ups count the ones the board's follow-up lane lists.
    /// The stat tiles that used to say the same thing a third time are gone
    /// (UI-16).
    typealias Counts = ShiftStore.Summary

    func counts(now: Date = DayRollover.now()) -> Counts {
        store.summary(now: now, includingTask: matchesProjectFilter, includingFollowUp: matchesProjectFilter)
    }

    /// §6.4's live subtitle. UI-16: it carries all four counts now - it is
    /// where they live since the stat tiles went - and it names the project
    /// filter when one is on, so the numbers say what they count.
    ///
    /// GL-14: a store that failed to parse has no counts, and says so rather
    /// than "0 open".
    var drillHeaderSubtitle: String? {
        if store.isInFailedLoadState { return "Task list could not be read" }
        // R2-UX-07: four zeros said nothing a "start here" state does not say
        // better.
        if showsStartHere, !isShowingCalendar { return "No tasks yet" }
        // On the Calendar view the header states what the calendar shows: the
        // visible period's count, its repeats, and the unscheduled and
        // overdue work beside it (GL-14).
        if isShowingCalendar { return calendarSubtitle }
        let c = counts()
        let parts = [
            "\(c.open) open",
            StateWord.dueToday.counted(c.dueToday),
            "\(c.followUps) follow-up\(c.followUps == 1 ? "" : "s")",
            StateWord.overdue.counted(c.overdue),
        ]
        // R5-UX-10: for the first few tasks, the one way to add one that the
        // page itself does not show - capture from any app.
        let line = QuietHint.line(parts.joined(separator: " \u{00B7} "), count: store.activeTasks.count,
                                  hint: "\(AppSettings.shared.quickCaptureShortcut.displayString) adds one from any app")
        guard let filter = projectFilter,
              let name = store.projects.first(where: { $0.id == filter })?.name, !name.isEmpty else { return line }
        return "\(name) \u{00B7} " + line
    }

    /// Set by `AppShellController` - "my live numbers changed, re-read my
    /// subtitle". See `DaylightDrillActions`.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Reflects `ShiftGitSync`'s real status - never a timer or a fake cycle.
    /// `nil` `store.gitSync` (an explicit `FM_SHIFT_DIR` override with no git
    /// backing) means the pill was never added to the header at all (see
    /// `configureSyncPill()`) - nothing to style.
    ///
    /// UI-19, through `ShiftSyncPresentation`: nothing until the first real
    /// status; "Synced" as a dot and a word; every other state a
    /// `HelmStatusPill` in a `HelmTint` (never the terminal's ANSI slots, and
    /// never the 10.5pt mono face that bypassed the 11pt floor); and a failure
    /// that is a network one reads as "Offline · working locally" in a
    /// neutral pill rather than a red "Failed".
    private func applySyncPill() {
        guard store.gitSync != nil else { return }
        guard let status = syncStatus else {
            syncPill.isHidden = true
            return
        }
        let look = ShiftSyncPresentation.look(for: status)
        syncPill.isHidden = false
        syncPill.toolTip = look.toolTip
        syncWord.isHidden = look.style != .dotWord
        syncCapsule.isHidden = look.style != .pill
        let pill = look.style == .dotWord ? syncWord : syncCapsule
        pill.configure(text: look.text, tint: look.tint, theme: theme)
        syncPill.accessibilityLabelOverride = "Sync status: \(look.text)"
    }

    /// Only meaningful while the pill is in `.conflict` - opens the
    /// resolution sheet. A click in any other state is a harmless no-op
    /// (the gesture recognizer is unconditionally attached rather than
    /// added/removed per state, since that's simpler and there is nothing
    /// to do for any other status anyway).
    @objc private func syncPillClicked() {
        guard case .conflict = syncStatus, let gitSync = store.gitSync, let conflictSet = gitSync.pendingConflictSet else { return }
        let resolver = ShiftConflictController(conflictSet: conflictSet)
        resolver.onResolve = { [weak self] choices, completion in
            gitSync.resolveConflictsAsync(choices: choices) { ok in
                completion(ok)
                if ok { self?.render() }
            }
        }
        presentAsSheet(resolver)
    }

    /// A panel header: the kit's `HelmSectionHeader` (UI-32) - a tile, the
    /// title, the count as muted text beside it, and a quiet "Add".
    ///
    /// This used to be built by hand here, with the count in a hand-rolled
    /// pill of its own (one of three count-badge styles on this page alone).
    /// The labels stay caller-owned, so `render` keeps writing their text.
    private func sectionHeaderRow(
        iconSymbol: String, tint: HelmTint = .accent, label: NSTextField, countBadge: NSTextField? = nil,
        addAction: Selector? = nil, addTooltip: String? = nil
    ) -> HelmSectionHeader {
        let header = HelmSectionHeader(size: .section, titleLabel: label,
                                       countLabel: countBadge ?? NSTextField(labelWithString: ""))
        header.configure(leading: .tile(symbol: iconSymbol, tint: tint),
                         title: label.stringValue,
                         count: countBadge.map { $0.stringValue.isEmpty ? " " : $0.stringValue })
        if let addAction {
            let addButton = HelmButton(title: "Add", variant: .quiet, size: .small, symbol: "plus",
                                       target: self, action: addAction)
            addButton.toolTip = addTooltip
            header.setActions([addButton])
        }
        sectionHeaders.append(header)
        return header
    }

    /// The Follow-ups card: its header with Add, and `followUpsTable` as its
    /// body.
    private func buildFollowUpSection() -> NSView {
        let headerRow = sectionHeaderRow(
            iconSymbol: "bell", tint: .warn, label: followUpsHeader, countBadge: followUpsCountBadge,
            addAction: #selector(newFollowUpClicked), addTooltip: "New Follow-up (\u{2318}\u{21e7}F)"
        )
        followUpPanel.setHeader(headerRow)
        // The table takes over the card's body.
        _ = followUpsTable
        followUpPanel.translatesAutoresizingMaskIntoConstraints = false
        return followUpPanel
    }

    /// The Projects section (cockpit-shift-projects, phase 3): a real
    /// wrapping grid of project cards - see `ShiftProjectCardView` - or, once
    /// a card is clicked, that project's own detail (edit form + task list
    /// with nested subtasks). `NSStackView` rendering (not a table) is still
    /// fine here: a captain's project count is nowhere near the scale that
    /// justified a table view for tasks/follow-ups.
    ///
    /// The header row + grid are wrapped in `projectsPanel`, the same
    /// `HelmCard` `followUpPanel` uses
    /// (fm/grandline-shift-projects-panel-background) - previously this
    /// section sat directly on the page's plain background with no
    /// enclosing card, reading as a different kind of section next to
    /// Follow-ups. `projectsDetailContainer` (the full-page project
    /// detail) stays a sibling *outside* `projectsPanel`, not nested inside
    /// it - it already builds its own two `HelmCard`s
    /// (`detailFormPanel`/`detailTasksPanel`, see `buildDetailChrome`), so
    /// wrapping it in a third outer panel would double the border/background
    /// rather than match it.
    private func buildProjectsSection() -> NSView {
        let headerRow = sectionHeaderRow(
            iconSymbol: "shippingbox", tint: .violet, label: projectsHeader, countBadge: projectsCountBadge,
            addAction: #selector(newProjectClicked), addTooltip: "New Project"
        )

        projectsGridContainer.orientation = .vertical
        projectsGridContainer.alignment = .leading
        projectsGridContainer.spacing = Self.projectCardSpacing
        projectsGridContainer.translatesAutoresizingMaskIntoConstraints = false

        projectsPanel.setHeader(headerRow)
        projectsPanel.setBody(projectsGridContainer)
        projectsPanel.translatesAutoresizingMaskIntoConstraints = false

        projectsDetailContainer.orientation = .vertical
        projectsDetailContainer.alignment = .leading
        projectsDetailContainer.spacing = HelmMetrics.s4
        projectsDetailContainer.translatesAutoresizingMaskIntoConstraints = false
        // REL-01: hidden until `renderProjectsSection` opens a project. It
        // used to be visible from build to the first render, stacking the
        // "Back to Projects" detail under the grid on every first visit.
        projectsDetailContainer.isHidden = true
        buildDetailChrome()

        // Just the panel. Projects is its own full-width section below
        // Follow-ups (see `loadView`), and the project *detail* takes the
        // whole page too - so both the panel and the detail container are
        // added to the dashboard directly by `loadView` rather than being
        // wrapped in here together, which would have capped either at
        // whatever width this method returned.
        return projectsPanel
    }

    // MARK: The board (fm/grandline-tasks-kanban-devops-split)

    private func buildBoardSection() {
        // UI-20: the drag hint that sat above the board on every visit is
        // gone. The same help lives where it is needed - each card's tooltip
        // and its context menu (`ShiftBoardCardView`).
        boardView.onOpenTask = { [weak self] id in self?.openBoardTask(id: id) }
        boardView.onMoveTask = { [weak self] id, column in self?.moveTask(id: id, to: column) }
        boardView.onPushTaskDue = { [weak self] id, option in
            guard let self, let task = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.pushDueDate(task, by: option)
        }
        boardView.onStartFocusTask = { [weak self] id, minutes in
            guard let self, let task = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.startFocus(on: task, minutes: minutes)
        }
        boardView.onDeleteTask = { [weak self] id in self?.confirmDeleteTask(id: id) }
        boardView.onAddTask = { [weak self] column in self?.addTask(in: column) }
        boardView.onDropTask = { [weak self] id, column in self?.moveTask(id: id, to: column) ?? false }
        boardView.onClearFilter = { [weak self] in self?.clearFilters() }
        // UI-31: the lanes show the skeleton until the first render, which
        // REL-01 runs at the end of `loadView` from the already-loaded store.
        boardView.setLoading(true)

        boardSection.orientation = .vertical
        boardSection.alignment = .leading
        boardSection.spacing = HelmMetrics.s3
        boardSection.translatesAutoresizingMaskIntoConstraints = false
        boardSection.addArrangedSubview(boardView)
        boardView.widthAnchor.constraint(equalTo: boardSection.widthAnchor).isActive = true

        // R4-UI-09: Follow-ups is a lane on the board while four lanes fit,
        // rather than a full-width card stacked under it.
        boardView.adoptWorkspaceStyle()
        boardView.setTrailingLane(followUpLane)
        followUpLane.onOpen = { [weak self] id in
            guard let self, let item = self.store.followUps.first(where: { $0.id == id }) else { return }
            self.presentFollowUpEditor(for: item)
        }
        followUpLane.onAdd = { [weak self] in self?.newFollowUpClicked() }
        followUpLane.menuFor = { [weak self] id in self?.followUpLaneMenu(id: id) }
    }

    private func buildFailedReadCard() {
        failedReadOpenButton.target = self
        failedReadOpenButton.action = #selector(openFailedFile)
        failedReadHeader.setActions([failedReadOpenButton])
        failedReadCard.setHeader(failedReadHeader, insets: NSEdgeInsets(top: HelmMetrics.s4, left: HelmMetrics.s4,
                                                                         bottom: HelmMetrics.s4, right: HelmMetrics.s4))
        failedReadCard.setAttentionEdge(.critical)
        failedReadCard.translatesAutoresizingMaskIntoConstraints = false
        failedReadCard.isHidden = true
    }

    /// Shows or hides the failed-read card from the store's own state, and
    /// says which file and line.
    private func applyFailedReadState() {
        guard let failure = store.loadFailureSummary else {
            failedReadCard.isHidden = true
            failedReadURL = nil
            return
        }
        failedReadCard.isHidden = false
        failedReadURL = store.root.appendingPathComponent(failure.relativePath)
        var where_ = failure.relativePath
        if let line = failure.line { where_ += ", line \(line)" }
        failedReadHeader.configure(
            leading: .tile(symbol: "exclamationmark.triangle.fill", tint: .critical),
            title: "\(failure.what.prefix(1).uppercased())\(failure.what.dropFirst()) could not be read",
            subline: "\(where_) \u{00B7} the file was left as it is, and nothing will be written over it")
        failedReadCard.applyTheme(theme)
    }

    @objc private func openFailedFile() {
        guard let failedReadURL else { return }
        NSWorkspace.shared.open(failedReadURL)
    }

    /// UI-26: what the board is filtered by, phrased to follow a lane's name,
    /// and the one action that clears it.
    private func filterDescription() -> (text: String?, clearTitle: String) {
        var parts: [String] = []
        if let filter = projectFilter, let name = store.projects.first(where: { $0.id == filter })?.name {
            parts.append("in \(name)")
        }
        switch taskScope {
        case .all: break
        case .dueToday: parts.append(StateWord.dueToday.phrase)
        case .overdue: parts.append(StateWord.overdue.phrase)
        case .myPriorities: parts.append("marked high")
        case .recentlyUpdated: parts.append("updated this week")
        }
        return (parts.isEmpty ? nil : parts.joined(separator: " "),
                projectFilter != nil ? "Show all projects" : "Show all tasks")
    }

    private func clearFilters() {
        projectFilter = nil
        taskScope = .all
        render()
    }

    private func switchTasksView(_ view: ShiftTasksView) {
        let wasCalendar = tasksView == .calendar
        tasksView = view
        if view == .calendar {
            embedCalendarIfNeeded()
            // The calendar fills the page, so a board scrolled down would
            // otherwise open it part-way off screen.
            if !wasCalendar { scrollToTop() }
        }
        render()
        onModuleTabChanged?()
        if wasCalendar != (view == .calendar) { onDrillActionsChanged?() }
    }

    /// The sort menu's pick: remembered per machine, and the lanes and the
    /// list re-sorted.
    private func setTaskSort(_ sort: ShiftTaskSort) {
        taskSort = sort
        AppDefaults.store.set(taskSort.rawValue, forKey: ShiftTaskSort.defaultsKey)
        render()
    }

    /// Which tasks the board shows, grouped by column.
    ///
    /// Backlog and In Progress come from `activeTasks`; Done comes from the
    /// completed month files, cut off at `doneColumnLookbackDays` - see that
    /// constant for why an uncapped Done column is an archive rather than a
    /// column. Both halves run through the same project filter, so a chip
    /// filters the whole board rather than two thirds of it.
    private func boardTasks() -> [ShiftBoardColumn: [ShiftTask]] {
        var byColumn: [ShiftBoardColumn: [ShiftTask]] = [:]
        for task in store.activeTasks where matchesFilters(task) {
            guard let column = ShiftBoardColumn.column(for: task.status) else { continue }
            byColumn[column, default: []].append(task)
        }
        for column in [ShiftBoardColumn.backlog, .inProgress] {
            byColumn[column] = (byColumn[column] ?? []).sorted(by: taskSort.areInOrder)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.doneColumnLookbackDays, to: DayRollover.now())
        byColumn[.done] = store.allCompletedTasks()
            .filter(matchesFilters)
            .filter { task in
                guard let cutoff,
                      let completed = task.completedAt.flatMap(ShiftStore.date(fromISO8601:)) else { return false }
                return completed >= cutoff
            }
            // Newest first: the most recent thing finished is the one worth
            // seeing at the top of a Done pile.
            .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
        return byColumn
    }

    private func matchesProjectFilter(_ task: ShiftTask) -> Bool {
        guard let projectFilter else { return true }
        return task.projectID == projectFilter
    }

    private func matchesProjectFilter(_ item: ShiftFollowUp) -> Bool {
        guard let projectFilter else { return true }
        return item.projectID == projectFilter
    }

    /// The scope's slice.
    ///
    /// **A completed task is never "due today" or "overdue".** Both slices ask
    /// about work still outstanding, so they exclude anything finished or
    /// cancelled - which means the board's Done column empties under either,
    /// correctly: a task finished last week is not late. The predicates are
    /// deliberately the same ones the store's `summary` counts with, so a
    /// band figure and the board can never disagree.
    private func matchesScope(_ task: ShiftTask) -> Bool {
        switch taskScope {
        case .all:
            return true
        case .dueToday, .overdue:
            guard task.status != .completed, task.status != .cancelled,
                  let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            let cal = Calendar.current
            return taskScope == .dueToday
                ? cal.isDate(due, inSameDayAs: DayRollover.now())
                : due < cal.startOfDay(for: DayRollover.now())
        case .myPriorities:
            // Outstanding work the captain themselves marked high - not a
            // ranking this page invented.
            return task.status != .completed && task.status != .cancelled && task.priority == .high
        case .recentlyUpdated:
            // `updatedAt` is written by `ShiftStore` on every real edit, so
            // this is a fact about the record rather than a guess. A task
            // whose timestamp cannot be parsed is *excluded*: claiming it was
            // touched this week would be worse than leaving it out.
            guard let updated = ShiftStore.date(fromISO8601: task.updatedAt) else { return false }
            guard let cutoff = Calendar.current.date(byAdding: .day,
                                                     value: -Self.recentlyUpdatedWindowDays,
                                                     to: DayRollover.now()) else { return false }
            return updated >= cutoff
        }
    }

    /// Both filters at once - every surface that shows tasks runs through this
    /// one predicate rather than remembering to apply two.
    func matchesFilters(_ task: ShiftTask) -> Bool {
        matchesProjectFilter(task) && matchesScope(task)
    }

    // MARK: Scrolling

    /// Scrolls the page so a panel sits just under the top edge. The document
    /// view is a `FlippedView`, so y grows downward and `minY` is the panel's
    /// own top.
    func scrollToPanel(_ panel: NSView) {
        view.layoutSubtreeIfNeeded()
        guard let document = scroll.documentView, panel.superview != nil else { return }
        let top = panel.convert(panel.bounds, to: document).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, top - HelmMetrics.s3)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The page's due-date ordering, extracted so the board's two in-flight
    /// columns and the List tab's table cannot disagree about what "next"
    /// means.
    static func byDueDateThenCreated(_ lhs: ShiftTask, _ rhs: ShiftTask) -> Bool {
        let ld = lhs.dueDate.flatMap(ShiftDateFormatting.date(from:))
        let rd = rhs.dueDate.flatMap(ShiftDateFormatting.date(from:))
        switch (ld, rd) {
        case (.some(let l), .some(let r)): return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.createdAt < rhs.createdAt
        }
    }

    /// Applies a board move - a drop, a context-menu item or an
    /// accessibility action, all three of which land here so there is exactly
    /// one definition of what moving a card does.
    ///
    /// Completion is not a status flip: `setTaskCompleted` moves the task
    /// between `active.yaml` and a completed month file, so both directions
    /// across the Done boundary have to go through it rather than through
    /// `updateTask`, which only ever rewrites a task already in
    /// `active.yaml`.
    ///
    /// Returns whether anything actually changed, which is what a drop
    /// reports back to AppKit - dropping a card into the column it came from
    /// is a no-op, not a failure.
    @discardableResult
    private func moveTask(id: String, to column: ShiftBoardColumn) -> Bool {
        if let task = store.activeTasks.first(where: { $0.id == id }) {
            guard task.status != column.status else { return false }
            if column == .done {
                store.setTaskCompleted(id: id, completed: true)
            } else {
                var updated = task
                updated.status = column.status
                store.updateTask(updated)
            }
            render()
            return true
        }

        // Coming back out of Done: reopen first (which files it back into
        // `active.yaml` as `todo`), then apply the target status if it is not
        // already the one reopening gives.
        guard store.allCompletedTasks().contains(where: { $0.id == id }) else { return false }
        guard column != .done else { return false }
        store.setTaskCompleted(id: id, completed: false)
        if column.status != .todo, var reopened = store.activeTasks.first(where: { $0.id == id }) {
            reopened.status = column.status
            store.updateTask(reopened)
        }
        render()
        return true
    }

    /// A card click. A completed task is opened read-only-ish: `updateTask`
    /// deliberately only touches `active.yaml`, so editing one from the Done
    /// column would silently save nothing - reopening it is the honest path,
    /// and saying so beats a sheet whose Save does nothing.
    private func openBoardTask(id: String) {
        if let task = store.activeTasks.first(where: { $0.id == id }) {
            presentTaskEditor(for: task)
            return
        }
        guard let done = store.allCompletedTasks().first(where: { $0.id == id }) else { return }
        ShiftRecordSheets.showCompletedNotice(for: done)
    }

    /// A column's own "+ Add task". Opens the same New Task sheet the header
    /// "+" and the Shift menu's Cmd-N open, then applies that column's status
    /// to whatever the captain saved - so adding straight into In Progress
    /// works without the editor needing a status control it does not have.
    private func addTask(in column: ShiftBoardColumn) {
        presentTaskEditor(for: nil, defaultProjectID: projectFilter, defaultStatus: column.status)
    }

    // MARK: Deletion (fm/grandline-tasks-kanban-devops-split)

    /// The one delete path. Every affordance - a board card's context menu, a
    /// list row's context menu, and the task editor's own Delete button - ends
    /// up here, so there is exactly one confirmation and one store call.
    ///
    /// The confirmation is not optional: deleting a task is irreversible and
    /// there is no undo for it (`Toast.showUndo` restores a value the caller
    /// still holds, which a task's completed-month file and attachment do not
    /// survive cleanly). `DestructiveConfirm` is GL-06's shared prompt, with
    /// Cancel as the default so a reflexive Return cannot complete it.
    /// UX7's "Push to → Tomorrow / Next week", from either the board card's
    /// context menu or the List tab's row menu.
    ///
    /// Both entry points land here so there is exactly one definition of what
    /// pushing a task does - the same rule `moveTask` states for the three
    /// ways a card can change column.
    ///
    /// GL-33: a real Undo, because this one can genuinely be undone - the
    /// caller still holds the previous due date, which is the invariant that
    /// rule is actually about. (Contrast `confirmDeleteTask` immediately
    /// below, which deliberately offers none: a deleted task's
    /// completed-month file and attachment do not survive cleanly, and a
    /// pretend Undo is worse than no Undo.)
    func pushDueDate(_ task: ShiftTask, by option: ShiftDuePush) {
        guard let newDue = option.newDueDate(currentDueDate: task.dueDate) else { return }
        let previousDue = task.dueDate
        var updated = task
        updated.dueDate = newDue
        store.updateTask(updated)
        render()

        let phrase = ShiftDateFormatting.friendly(newDue)
        Toast.showUndo(in: view, message: "Due \(phrase)") { [weak self] in
            guard let self,
                  var current = self.store.activeTasks.first(where: { $0.id == task.id }) else { return }
            // Restores the value the caller had in hand (GL-33), and re-reads
            // the task first rather than writing back the stale copy - the
            // captain may have edited something else about it while the toast
            // was up, and an Undo of the *due date* must not revert that.
            current.dueDate = previousDue
            self.store.updateTask(current)
            self.render()
        }
    }

    func confirmDeleteTask(id: String) {
        guard ShiftRecordSheets.confirmDeleteTask(id: id, store: store, in: view) else { return }
        render()
    }

    /// The same, for a follow-up - see `ShiftStore.deleteFollowUp`'s header
    /// for why follow-ups got a delete alongside tasks and projects did not.
    func confirmDeleteFollowUp(id: String) {
        guard ShiftRecordSheets.confirmDeleteFollowUp(id: id, store: store, in: view) else { return }
        render()
    }

    /// Done to pending and back, from the Follow-ups table's check, that
    /// table's menu and the lane card's menu alike.
    private func toggleFollowUpDone(id: String) {
        guard let item = store.followUps.first(where: { $0.id == id }) else { return }
        store.setFollowUpStatus(id: id, done: item.status != .done)
        render()
    }

    // MARK: F7 - the focus timer

    /// Start a session on `task`, and say so.
    ///
    /// The store is not touched here: a *running* session is not data, it is
    /// runtime state, and only the finished session is written (by
    /// `FocusTimerController`, into the task's own activity log). That is
    /// also why nothing here re-renders the page - the timer's own observer
    /// does, through `focusStateChanged`.
    private func startFocus(on task: ShiftTask, minutes: Int) {
        guard let focusTimer else { return }
        focusTimer.start(task: task, minutes: minutes)
        Feedback.report("Focusing \(minutes) min on \(task.title)",
                        kind: .done, persistence: .transient, in: view)
    }

    private func stopFocus() {
        guard let focusTimer, focusTimer.isRunning else { return }
        let logged = focusTimer.stop()
        Feedback.report(logged.map { "Logged \(FocusTimerFormat.total($0)) to the task" }
                            ?? "Focus stopped \u{00B7} too short to log",
                        kind: logged == nil ? .warning : .done,
                        persistence: .transient, in: view)
    }

    /// The timer moved. Repaint only what depends on it.
    ///
    /// Called once a second while a session runs, so it must stay cheap:
    /// Weekly Review's tile is only re-rendered while that is the view
    /// actually on screen (AGENTS.md's "an observer must not rebuild a page
    /// that is not visible", for the same reason).
    private func focusStateChanged() {
        guard isViewLoaded else { return }
        if topLevelView == .weeklyReview, !view.isHiddenOrHasHiddenAncestor {
            renderFocusTile()
        }
    }

    // MARK: Weekly Review

    /// The page's one view switch (UI-15): a task view's id, or Weekly
    /// Review's. The window toolbar's tabs reach it through
    /// `selectModuleTab(named:)`.
    func selectView(_ id: String) {
        if id == Self.reviewViewID {
            switchTopLevelView(.weeklyReview)
        } else if let view = ShiftTasksView(rawValue: id) {
            if topLevelView != .dashboard { switchTopLevelView(.dashboard) }
            switchTasksView(view)
        }
    }

    /// The review's width tie to the page, active only while it shows.
    private var weeklyReviewWidthTie: NSLayoutConstraint?

    func switchTopLevelView(_ view: ShiftTopLevelView) {
        topLevelView = view
        // Tied before the review shows, released once it is hidden - and
        // before `onModuleTabChanged` below, which is where the shell settles
        // the column's floor for the new tab.
        if view == .weeklyReview { weeklyReviewWidthTie?.isActive = true }
        dashboardContainer.isHidden = view != .dashboard
        weeklyReviewContainer.isHidden = view != .weeklyReview
        if view != .weeklyReview { weeklyReviewWidthTie?.isActive = false }
        // Tf-2: the band is the board's and the list's filters, so it leaves
        // with them when Weekly review shows.
        heroBand.isHidden = view != .dashboard || isProjectDetailFullPage || tasksView == .calendar
        if view == .weeklyReview { renderWeeklyReview() }
        applyCalendarVisibility()
        applyTheme()
        onModuleTabChanged?()
    }

    /// The Shift menu / search palette's entry point into Weekly Review -
    /// selects the view exactly like the toolbar's tab would.
    func showWeeklyReview() { switchTopLevelView(.weeklyReview) }

    /// Back to the daily dashboard - used after navigating here to open a
    /// task/follow-up/project found via search or the menu bar popover.
    func showDashboard() { switchTopLevelView(.dashboard) }

    /// Weekly review, top to bottom: the "Week of …" header, the five
    /// figures, Time on tasks beside Pushed back repeatedly, and next week's
    /// agenda across the foot.
    private func buildWeeklyReviewSection() -> NSView {
        reviewGreeting.font = HelmType.sectionTitle()

        let headerRow = sectionHeaderRow(iconSymbol: "arrow.uturn.backward", tint: .warn, label: reviewPushedBackHeader)
        reviewPushedBackCount.toolTip = "Tasks pushed back two or more times"
        headerRow.setActions([reviewPushedBackCount])

        reviewPushedBackStack.orientation = .vertical
        reviewPushedBackStack.alignment = .leading
        reviewPushedBackStack.spacing = 0
        reviewPushedBackStack.translatesAutoresizingMaskIntoConstraints = false
        reviewPushedBackPanel.setHeader(headerRow)
        reviewPushedBackPanel.setBody(reviewPushedBackStack)
        reviewPushedBackPanel.translatesAutoresizingMaskIntoConstraints = false

        // Time on tasks beside Pushed back repeatedly, two to one, as the
        // prototype sets its chart beside its checklist.
        for panel in [buildFocusPanel(), reviewPushedBackPanel] { reviewLowerRow.addArrangedSubview(panel) }
        reviewLowerRow.orientation = .horizontal
        reviewLowerRow.alignment = .top
        reviewLowerRow.distribution = .fill
        reviewLowerRow.spacing = HelmMetrics.s4
        reviewLowerRow.translatesAutoresizingMaskIntoConstraints = false

        // R4-UI-09: the next-week agenda across the foot, which the
        // "Coming up next week" figure counts and nothing used to list.
        let agendaHeader = sectionHeaderRow(iconSymbol: "calendar", tint: .info, label: reviewAgendaHeader)
        agendaHeader.setActions([reviewAgendaCount])
        reviewAgendaCount.toolTip = "Open tasks and pending follow-ups due next week"
        reviewAgendaStack.orientation = .vertical
        reviewAgendaStack.alignment = .leading
        reviewAgendaStack.spacing = 0
        reviewAgendaStack.translatesAutoresizingMaskIntoConstraints = false
        reviewAgendaPanel.setHeader(agendaHeader)
        reviewAgendaPanel.setBody(reviewAgendaStack)
        reviewAgendaPanel.translatesAutoresizingMaskIntoConstraints = false

        weeklyReviewContainer.orientation = .vertical
        weeklyReviewContainer.alignment = .leading
        weeklyReviewContainer.spacing = HelmMetrics.s4
        weeklyReviewContainer.translatesAutoresizingMaskIntoConstraints = false
        weeklyReviewContainer.isHidden = true
        for section in [reviewGreeting, reviewCardsRow, reviewLowerRow, reviewAgendaPanel] {
            weeklyReviewContainer.addArrangedSubview(section)
        }
        NSLayoutConstraint.activate([
            reviewCardsRow.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor),
            reviewLowerRow.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor),
            reviewPushedBackPanel.widthAnchor.constraint(equalTo: reviewFocusPanel.widthAnchor, multiplier: 0.5),
            reviewAgendaPanel.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor),
        ])
        return weeklyReviewContainer
    }

    /// F7's panel. Built once; `renderFocusTile` only ever rewrites its two
    /// labels and re-points the chart, so a once-a-second tick costs no
    /// view construction at all.
    private func buildFocusPanel() -> NSView {
        reviewFocusHeadline.font = HelmType.rounded(HelmType.scaled(19), .heavy)
        reviewFocusCaption.font = HelmType.captionSmall()

        let textStack = NSStackView(views: [reviewFocusHeadline, reviewFocusCaption])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = HelmMetrics.s0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): `setContentHuggingPriority` is a **no-op**
        // on an `NSStackView` - it constrains a view against its intrinsic
        // content size and a stack has none. The stack-level pair is what
        // actually holds this column at its natural width beside the chart.
        textStack.setHuggingPriority(.required, for: .horizontal)
        textStack.setClippingResistancePriority(.required, for: .horizontal)

        let body = NSStackView(views: [textStack, reviewFocusChart])
        body.orientation = .horizontal
        body.alignment = .centerY
        body.spacing = HelmMetrics.s5
        // AGENTS.md gotcha (10): without `.fill` the chart never absorbs
        // the row's slack.
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false

        reviewFocusPanel.setHeader(symbol: "timer", tint: .accent, titleLabel: reviewFocusHeader)
        reviewFocusPanel.setBody(body, insets: HelmCard.contentInsets)
        reviewFocusPanel.translatesAutoresizingMaskIntoConstraints = false
        return reviewFocusPanel
    }

    /// Repaint the focus panel from the activity log.
    ///
    /// GL-14: a day with no sessions is a measured zero and is drawn as a
    /// hairline bar, never omitted - see `FocusWeekBarView`. The headline
    /// says "None yet today" rather than "0m" for the same reason: `0m` on
    /// its own reads as a broken counter.
    private func renderFocusTile() {
        let days = store.focusSecondsByDay(days: 7)
        let todaySeconds = days.last?.seconds ?? 0
        let taskCount = store.focusTaskCountToday()

        reviewFocusHeadline.stringValue = todaySeconds > 0
            ? FocusTimerFormat.total(todaySeconds) : "None yet today"
        reviewFocusCaption.stringValue = todaySeconds > 0
            ? "today \u{00B7} \(taskCount) task\(taskCount == 1 ? "" : "s")"
            : "start a focus session from any task"

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: DayRollover.now())
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        reviewFocusChart.configure(days.map { entry in
            let weekday = calendar.component(.weekday, from: entry.day)
            return FocusWeekBarView.Bar(
                label: letters.indices.contains(weekday - 1) ? letters[weekday - 1] : "",
                seconds: entry.seconds,
                isToday: entry.day == today)
        })
    }

    private func renderWeeklyReview() {
        let summary = store.weeklySummary()
        reviewGreeting.stringValue = summary.weekLabel

        renderFocusTile()

        for v in reviewPushedBackStack.arrangedSubviews {
            reviewPushedBackStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if summary.pushedBack.isEmpty {
            // UI-46: a card-level empty state is the quiet one.
            let empty = HelmEmptyState(symbol: "checkmark.seal", body: "Nothing's been pushed back more than once.",
                                       size: .quiet)
            empty.applyTheme(theme)
            reviewPushedBackStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: reviewPushedBackStack.widthAnchor).isActive = true
        } else {
            reviewPushedBackList.setRows(summary.pushedBack.map(reviewPushedBackRow), theme: theme)
            reviewPushedBackStack.addArrangedSubview(reviewPushedBackList)
            // The list is reused across renders, so its width tie is made
            // once rather than stacked up on every visit.
            if reviewPushedBackListWidth == nil {
                reviewPushedBackListWidth = reviewPushedBackList.widthAnchor
                    .constraint(equalTo: reviewPushedBackStack.widthAnchor)
            }
            reviewPushedBackListWidth?.isActive = true
        }
        renderWorkspaceReview(summary)
        applyTheme()
    }

    /// A pushed-back task as a flat row: the title, and how often it moved
    /// with its project. The kit's `.flat` row rather than the hand-built
    /// divider-and-labels stack this used to be.
    private func reviewPushedBackRow(_ item: ShiftPushedBackItem) -> NSView {
        var meta = "Pushed back \(item.count) times"
        if let projectName = item.projectName { meta += " \u{00B7} \(projectName)" }
        let row = HelmAccentRow(hover: false, style: .flat)
        row.configure(HelmAccentRow.Content(tint: .warn, kicker: "", title: item.title, meta: meta), theme: theme)
        return row
    }

    // MARK: Search / menu-bar navigation (phase 5)

    /// Opens the New/Edit Task sheet for a task found via ⌘⇧P search or the
    /// menu bar popover. Falls back silently if the id no longer resolves to
    /// an *active* task (a completed task isn't editable through this sheet -
    /// see `ShiftStore.updateTask`'s header) - the search index only offers
    /// active tasks in the first place, so this should always resolve.
    func openTask(id: String) {
        showDashboard()
        guard let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        presentTaskEditor(for: task)
    }

    func openFollowUp(id: String) {
        showDashboard()
        guard let item = store.followUps.first(where: { $0.id == id }) else { return }
        presentFollowUpEditor(for: item)
    }

    func openProject(id: String) {
        showDashboard()
        guard store.projects.contains(where: { $0.id == id }) else { return }
        projectsView = .detail(id)
        render()
    }

    // MARK: Rendering

    /// Set by a store change, cleared by any render - see `loadView`'s REL-02
    /// note.
    private var renderPendingForStoreChange = false

    /// B-01: the day moved on. Board, List, Weekly review and the calendar's
    /// head all come from `render()`, and the calendar's own today marker
    /// needs its cells redrawn. A page nobody can see renders on its next
    /// `viewWillAppear`, as it does for a store change.
    private func dayDidChange(from previousDay: String) {
        guard isViewLoaded, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        render()
        if isShowingCalendar { calendar.dayDidChange(from: previousDay) }
    }

    private func scheduleRenderForStoreChange() {
        guard !renderPendingForStoreChange else { return }
        renderPendingForStoreChange = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderPendingForStoreChange else { return }
            self.renderPendingForStoreChange = false
            // GL-24's spirit: a page nobody can see does not rebuild; its
            // next `viewWillAppear` renders anyway.
            guard self.isViewLoaded, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
            self.render()
        }
    }

    func render() {
        renderPendingForStoreChange = false
        // §6.4: the greeting and the date line this used to write are gone
        // with the in-page hero - the drill header carries the destination's
        // name, and its subtitle carries these counts.
        onDrillSubtitleChanged?()

        let pendingFollowUps = store.followUps.filter { $0.status == .pending }

        // A filter pinned to a project that has since gone away would hide
        // every task with no way to tell why.
        if let filter = projectFilter, !store.projects.contains(where: { $0.id == filter }) {
            projectFilter = nil
        }

        // The board and the List tab's table are two presentations of the
        // same filtered set, so both are refreshed on every render regardless
        // of which one is showing - a stale board behind a view toggle is the
        // exact "switch away and back to find yesterday's data" shape this
        // page has been corrected for before.
        boardView.setTasks(boardTasks(), projects: store.projects, theme: theme)
        boardView.setLoading(false)
        let filter = filterDescription()
        boardView.setFilterDescription(filter.text, clearTitle: filter.clearTitle)
        applyTasksViewVisibility()

        followUpsHeader.stringValue = "Follow-ups"
        followUpsCountBadge.stringValue = "\(pendingFollowUps.count) pending"

        renderProjectsSection()
        if topLevelView == .weeklyReview { renderWeeklyReview() }
        let projectsByID = Dictionary(store.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        followUpLane.setFollowUps(followUpLaneItems(), projects: projectsByID, theme: theme)
        renderWorkspaceChrome()
        // The calendar redraws only while it shows; switching to it renders it.
        if isShowingCalendar { calendar.render() }

        applyTheme()
    }

    /// Whether a project's detail is the whole page right now - the board,
    /// the List tab's table, the calendar and the Follow-ups card all hide
    /// entirely (not just scrolled past) while true, matching how
    /// `switchTopLevelView` hides `dashboardContainer` in favor of
    /// `weeklyReviewContainer` (fm/cockpit-fix-shift-project-detail-fullpage).
    /// The Projects card stays, titled with the project's name over its
    /// hidden grid (`renderProjectsSection`).
    private func applyProjectDetailFullPage(_ isDetail: Bool) {
        isProjectDetailFullPage = isDetail
        applyTasksViewVisibility()
    }

    /// Whether the project detail currently owns the whole page - the board
    /// and the table both have to stay hidden while it does, whichever view
    /// happens to be chosen.
    private(set) var isProjectDetailFullPage = false

    /// Shows the chosen view - the board, the List tab's table or the
    /// calendar - and the cards around it. A hidden arranged subview of an
    /// `NSStackView` drops out of layout entirely, so whatever shows closes
    /// up under the band.
    private func applyTasksViewVisibility() {
        // UI-31: a failed read hides every view of the task list - empty
        // lanes under a failure would read as "nothing to do".
        applyFailedReadState()
        let failed = store.isInFailedLoadState && !isProjectDetailFullPage
        let boardShowing = !isProjectDetailFullPage && !failed && tasksView == .board
        let calendarShowing = !isProjectDetailFullPage && !failed && tasksView == .calendar
        boardSection.isHidden = !boardShowing
        applyCalendarVisibility()
        tasksTable.card.isHidden = isProjectDetailFullPage || failed || tasksView != .list
        // The calendar fills the page, so it keeps the band's height; its
        // month head carries the filters instead (Cf-4).
        heroBand.isHidden = isProjectDetailFullPage || topLevelView != .dashboard || calendarShowing
        // R2-UX-07: an empty Tasks page was three empty states (the
        // board's lanes, Follow-ups and Projects) under a band of zeros. With nothing at all it is one invitation instead. The
        // calendar is the exception: an empty month is still the
        // calendar the captain opened, and a double-click on a day there
        // adds the first task.
        let startHere = showsStartHere && !failed && !isProjectDetailFullPage && !calendarShowing
        startHereState.isHidden = !startHere
        if startHere {
            for view in [boardSection, tasksTable.card, heroBand] + startHereReplaces {
                view.isHidden = true
            }
        } else {
            // R4-UI-09: on Board, Follow-ups is a lane on the board while
            // four lanes fit, and Projects is the band's project menu. The
            // List tab keeps both cards under its table.
            let laneOnBoard = boardShowing && boardFitsFollowUpLane
            boardView.trailingLaneShown = laneOnBoard
            // The calendar draws follow-ups on their day and fills the
            // page, so neither card sits under it.
            followUpPanel.isHidden = laneOnBoard || calendarShowing || isProjectDetailFullPage
            projectsPanel.isHidden = boardShowing || calendarShowing
            followUpsJumpWanted = !laneOnBoard && !calendarShowing
            refreshFilters()
        }
    }

    /// R4-UI-09: below this, four lanes are each under the ~200pt a card's
    /// title and its project, due date and priority need on one line, so
    /// Follow-ups goes back under the board rather than squeezing every lane.
    static let followUpLaneMinimumBoardWidth: CGFloat = 4 * 200 + 3 * HelmMetrics.s3

    /// The page's content column changed width: decide again whether
    /// Follow-ups fits on the board.
    ///
    /// From the column's own frame change, not `viewDidLayout`: this page's
    /// view lays out before the scroll document under it does, so its
    /// `viewDidLayout` read the width the column had *before* a resize -
    /// measured in the tour lab, 1512 to 1100 left Follow-ups on a 707pt board.
    @objc private func contentColumnDidResize() {
        guard contentStack.bounds.width > 0 else { return }
        let fits = contentStack.bounds.width >= Self.followUpLaneMinimumBoardWidth
        if fits != boardFitsFollowUpLane {
            boardFitsFollowUpLane = fits
            applyTasksViewVisibility()
        }
    }

    /// The lane's pending follow-ups: the board's project filter applies, and
    /// the soonest due comes first, then those with no date.
    private func followUpLaneItems() -> [ShiftFollowUp] {
        store.followUps.filter { $0.status == .pending && (projectFilter == nil || $0.projectID == projectFilter) }
            .sorted { a, b in
                switch (a.followUpAt, b.followUpAt) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
    }

    #if FM_SELFTESTS
    /// R4-UI-08 and R4-UI-09, as drawn.
    var debugFollowUpLaneOnBoard: Bool { boardView.trailingLaneShown && !boardSection.isHidden }
    var debugFollowUpsRowHidden: Bool { followUpPanel.isHidden }
    var debugProjectsSectionHidden: Bool { projectsPanel.isHidden }
    /// Tf-2: whether the band's Follow-ups figure jumps anywhere.
    var debugFollowUpsJumps: Bool { followUpsJumpWanted }
    var debugAgendaRowCount: Int { reviewAgendaList.superview == nil ? 0 : reviewAgendaList.rows.count }
    var debugAgendaPanelShown: Bool { reviewAgendaPanel.superview != nil && !reviewAgendaPanel.isHiddenOrHasHiddenAncestor }
    #endif

    /// The lane card's menu: the List tab's row verbs for a pending follow-up.
    private func followUpLaneMenu(id: String) -> NSMenu? {
        guard let item = store.followUps.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ShiftLaneMenuItem(title: title, action: action))
        }
        add("Open Follow-up\u{2026}") { [weak self] in self?.presentFollowUpEditor(for: item) }
        add("Mark Done") { [weak self] in self?.toggleFollowUpDone(id: id) }
        menu.addItem(.separator())
        for (title, option) in [("Snooze to Tomorrow", ShiftSnoozeOption.tomorrow),
                                ("Snooze to Next Week", .nextWeek),
                                ("Snooze Until\u{2026}", .custom)] {
            add(title) { [weak self] in self?.snoozeFollowUp(item, option: option) }
        }
        menu.addItem(.separator())
        add("Delete Follow-up\u{2026}") { [weak self] in self?.confirmDeleteFollowUp(id: id) }
        return menu
    }

    private func renderProjectsSection() {
        switch projectsView {
        case .grid:
            applyProjectDetailFullPage(false)
            projectsGridContainer.isHidden = false
            projectsDetailContainer.isHidden = true
            projectsHeader.stringValue = "Projects"
            projectsCountBadge.stringValue = "\(store.projects.count)"
            rebuildProjectsGrid()
        case .detail(let projectID):
            guard let project = store.projects.first(where: { $0.id == projectID }) else {
                // Deleted out from under the open detail view (not possible
                // in this phase - there's no delete action yet - but falling
                // back to the grid is the only sane thing to do if it ever
                // happens rather than showing a detail view for nothing).
                projectsView = .grid
                renderProjectsSection()
                return
            }
            applyProjectDetailFullPage(true)
            projectsGridContainer.isHidden = true
            projectsDetailContainer.isHidden = false
            projectsHeader.stringValue = "Project: \(project.name)"
            rebuildProjectDetail(project)
        }
    }

    // MARK: Projects - grid

    /// A real wrapping grid, columns computed from `projectsGridContainer`'s
    /// actual width - same `minCardWidth`/partial-row-padding shape
    /// `ToolsController.rebuildGrid` already settled on (see AGENTS.md's
    /// Tools section for the partial-row-stretch bug that padding avoids).
    private func rebuildProjectsGrid() {
        for v in projectsGridContainer.arrangedSubviews {
            projectsGridContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let projects = store.projects
        guard !projects.isEmpty else {
            projectCards.removeAll()
            // Built fresh each call (not the retained `projectsEmptyState`
            // property elsewhere) so its one-time width/height constraints
            // never accumulate across repeated rebuilds - `rebuildProjectsGrid`
            // removes the view from its superview each time but never tears
            // down constraints, which would otherwise pile up duplicates.
            let empty = HelmEmptyState(symbol: "shippingbox", body: "No projects yet.\nCreate one to start tracking tasks against it.")
            empty.applyTheme(theme)
            projectsGridEmptyState = empty
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 110).isActive = true
            projectsGridContainer.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: projectsGridContainer.widthAnchor).isActive = true
            return
        }

        let containerWidth = projectsGridContainer.frame.width > 0 ? projectsGridContainer.frame.width : 860
        let columnsPerRow = max(1, Int((containerWidth + Self.projectCardSpacing) / (Self.projectCardMinWidth + Self.projectCardSpacing)))

        projectCards.removeAll()
        let cards: [NSView] = projects.map { project in
            let (completed, total) = store.taskCounts(forProject: project.id)
            let card = ShiftProjectCardView()
            projectCards.append(card)
            card.configure(project: project, completed: completed, total: total, theme: theme)
            card.onOpenDetail = { [weak self] in
                self?.projectsView = .detail(project.id)
                self?.render()
            }
            card.onStatusChange = { [weak self] newStatus in
                var updated = project
                updated.status = newStatus
                self?.store.updateProject(updated)
                self?.render()
            }
            return card
        }

        for chunk in cards.chunked(into: columnsPerRow) {
            var rowViews = chunk
            while rowViews.count < columnsPerRow { rowViews.append(NSView()) }
            let row = NSStackView(views: rowViews)
            row.orientation = .horizontal
            row.spacing = Self.projectCardSpacing
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            projectsGridContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: projectsGridContainer.widthAnchor).isActive = true
        }
    }

    // MARK: Projects - detail
    //
    // Rebuilt to read like a real dedicated page (fm/cockpit-shift-project-
    // page-redesign) - "clicking a project should feel like clicking into a
    // Tool on the Tools page," per the captain's own comparison, not a form
    // squeezed into leftover space. Built once (in `buildProjectsSection`),
    // never torn down - the fixed chrome (back button, header, edit form,
    // task list) needs to survive a `render()` triggered by something
    // unrelated (a subtask toggle, an expand/collapse) without losing
    // whatever the captain has half-typed into the form. `detailTaskListView`
    // (an `NSTableView`, see `ShiftProjectDetailView.swift`) is refreshed on
    // every render; the edit form's field values only refresh the first time
    // a given project is shown - see `rebuildProjectDetail`.

    private let detailBackButton = NSButton(title: "\u{2039} Back to Projects", target: nil, action: nil)
    private let detailIconTile = IconTileView(size: 40, cornerRadius: 10)
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailStatusPill = HelmStatusPill()
    private let detailMetaLabel = NSTextField(labelWithString: "")
    private let detailDescriptionLabel = NSTextField(wrappingLabelWithString: "")

    private let detailFormPanel = HelmCard()
    // Phase 6 of the full-app UI audit: `HelmTextField` rather than four bare
    // `NSTextField`s plus a private `styleDetailFormField`/
    // `detailFieldFillColor` pair - the latter was one of the three
    // byte-identical copies of the sunken-field fill the audit counted
    // (§3.2). These theme themselves now, which is why `applyTheme` below has
    // no field loop left.
    private let detailNameField = HelmTextField()
    private let detailDescriptionField = HelmTextField()
    private let detailStatusPopup = HelmPopUpButton()
    /// S13: the open project's stored identity colour.
    private let detailHuePicker = ShiftProjectHuePicker(selected: ShiftProjectPalette.hues[0])
    private let detailStartDateField = HelmTextField(placeholder: "YYYY-MM-DD")
    private let detailDueDateField = HelmTextField(placeholder: "YYYY-MM-DD")
    private let detailSaveButton = HelmButton(title: "Save", variant: .primary, target: nil, action: nil)

    private let detailTasksPanel = HelmCard()
    private let detailTasksHeader = NSTextField(labelWithString: "Tasks")
    private let detailTasksCountBadge = NSTextField(labelWithString: "")
    private let detailTaskListView = ShiftProjectTaskListView()
    private let detailTaskListScroll = HelmNestedScrollView()

    private var lastDetailProjectID: String?
    /// The project the detail page currently shows - kept separate from
    /// `lastDetailProjectID` (which only tracks "should the form re-fill")
    /// so "+ Add Task" always knows which project to pre-select, even on a
    /// `render()` that doesn't touch the form.
    private var currentDetailProjectID: String?

    private func buildDetailChrome() {
        detailBackButton.isBordered = false
        detailBackButton.contentTintColor = nil
        detailBackButton.target = self
        detailBackButton.action = #selector(detailBackClicked)
        detailBackButton.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        detailBackButton.translatesAutoresizingMaskIntoConstraints = false

        let header = buildDetailHeader()
        let form = buildDetailForm()
        detailFormPanel.setHeader(sectionHeaderRow(iconSymbol: "pencil", label: NSTextField(labelWithString: "Details")))
        detailFormPanel.setBody(form)
        detailFormPanel.translatesAutoresizingMaskIntoConstraints = false

        let tasksHeaderRow = sectionHeaderRow(
            iconSymbol: "checklist", label: detailTasksHeader, countBadge: detailTasksCountBadge,
            addAction: #selector(addTaskToProjectClicked), addTooltip: "Add Task"
        )
        detailTaskListScroll.documentView = detailTaskListView.tableView
        detailTaskListScroll.hasVerticalScroller = true
        detailTaskListScroll.hasHorizontalScroller = false
        detailTaskListScroll.borderType = .noBorder
        detailTaskListScroll.drawsBackground = false
        detailTaskListScroll.translatesAutoresizingMaskIntoConstraints = false
        detailTaskListScroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        detailTasksPanel.setHeader(tasksHeaderRow)
        detailTasksPanel.setBody(detailTaskListScroll)
        detailTasksPanel.translatesAutoresizingMaskIntoConstraints = false

        detailTaskListView.onToggleExpand = { [weak self] taskID in
            guard let self else { return }
            if self.expandedTaskIDs.contains(taskID) { self.expandedTaskIDs.remove(taskID) } else { self.expandedTaskIDs.insert(taskID) }
            self.render()
        }
        detailTaskListView.onToggleTaskCompleted = { [weak self] task in
            self?.store.setTaskCompleted(id: task.id, completed: task.status != .completed)
            self?.render()
        }
        detailTaskListView.onToggleSubtask = { [weak self] taskID, subtaskID, done in
            self?.store.setSubtaskDone(taskID: taskID, subtaskID: subtaskID, done: done)
            self?.render()
        }
        detailTaskListView.onOpenTask = { [weak self] task in
            self?.presentTaskEditor(for: task)
        }

        projectsDetailContainer.addArrangedSubview(detailBackButton)
        projectsDetailContainer.addArrangedSubview(header)
        projectsDetailContainer.addArrangedSubview(detailFormPanel)
        projectsDetailContainer.addArrangedSubview(detailTasksPanel)
        header.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
        detailFormPanel.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
        detailTasksPanel.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
    }

    /// The page-header block: an icon tile, the project name as a real
    /// serif title, a read-only status pill + start/due date meta line, and
    /// the description as a wrapping paragraph - all presentation, no input
    /// fields. Editing lives entirely in the "Details" panel below, so there
    /// is exactly one place that changes a project's fields, not a header
    /// control and a form both claiming to own status.
    private func buildDetailHeader() -> NSView {
        detailIconTile.configure(symbol: "shippingbox", tint: .accent)

        detailNameLabel.font = HelmType.pageTitle(.display)
        detailNameLabel.lineBreakMode = .byTruncatingTail

        detailMetaLabel.font = .systemFont(ofSize: HelmType.scaled(11))

        let metaRow = NSStackView(views: [detailStatusPill, detailMetaLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = HelmMetrics.s2
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        detailDescriptionLabel.font = .systemFont(ofSize: HelmType.scaled(12.5))
        detailDescriptionLabel.preferredMaxLayoutWidth = 640
        detailDescriptionLabel.lineBreakMode = .byWordWrapping

        let textStack = NSStackView(views: [detailNameLabel, metaRow, detailDescriptionLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = HelmMetrics.s2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        detailDescriptionLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let row = NSStackView(views: [detailIconTile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s4
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The editable field set, laid out in an `NSGridView` (the same
    /// approach `ShiftTaskEditorController`'s sheet uses) rather than a
    /// hand-stacked column of rows - a fixed, right-aligned label column and
    /// a fill-width field column read as a real form, not a raw debug
    /// dump of controls.
    private func buildDetailForm() -> NSView {
        detailStatusPopup.removeAllItems()
        detailStatusPopup.addItems(withTitles: ShiftProjectStatus.allCases.map(\.displayName))
        detailStatusPopup.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [gridLabel("Name"), detailNameField],
            [gridLabel("Description"), detailDescriptionField],
            [gridLabel("Status"), detailStatusPopup],
            [gridLabel("Colour"), detailHuePicker],
            [gridLabel("Start date"), detailStartDateField],
            [gridLabel("Due date"), detailDueDateField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.column(at: 1).xPlacement = .fill

        detailSaveButton.target = self
        detailSaveButton.action = #selector(detailSaveClicked)
        detailSaveButton.translatesAutoresizingMaskIntoConstraints = false

        let saveRow = NSStackView(views: [NSView(), detailSaveButton])
        saveRow.orientation = .horizontal
        saveRow.distribution = .fill
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [grid, saveRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        saveRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.body()
        return label
    }

    /// Refreshes the header + task list unconditionally, and the edit form's
    /// field values only the first time this particular project is shown - a
    /// `render()` triggered by, say, a subtask toggle re-enters this with the
    /// same `project.id` and must not clobber an in-progress edit.
    private func rebuildProjectDetail(_ project: ShiftProject) {
        currentDetailProjectID = project.id
        if lastDetailProjectID != project.id {
            lastDetailProjectID = project.id
            detailNameField.stringValue = project.name
            detailDescriptionField.stringValue = project.description
            detailStartDateField.stringValue = project.startDate ?? ""
            detailDueDateField.stringValue = project.dueDate ?? ""
            if let idx = ShiftProjectStatus.allCases.firstIndex(of: project.status) {
                detailStatusPopup.selectItem(at: idx)
            }
            detailHuePicker.select(ShiftProjectPalette.hue(for: project) ?? ShiftProjectPalette.hues[0])
        }
        applyDetailHeader(project)
        rebuildDetailTasks(project)
    }

    private func applyDetailHeader(_ project: ShiftProject) {
        detailNameLabel.stringValue = project.name
        var meta: [String] = []
        if let start = project.startDate { meta.append("Starts \(ShiftDateFormatting.friendly(start))") }
        if let due = project.dueDate { meta.append("Due \(ShiftDateFormatting.friendly(due))") }
        detailMetaLabel.stringValue = meta.joined(separator: "  \u{00B7}  ")
        detailDescriptionLabel.stringValue = project.description
        detailDescriptionLabel.isHidden = project.description.isEmpty
        applyDetailStatusPill(project.status)
    }

    /// The project cell's rule (UI-32): "In progress" is the default state,
    /// so it is a dot and a word; every other status is a pill.
    private func applyDetailStatusPill(_ status: ShiftProjectStatus) {
        detailStatusPill.configure(text: status.displayName,
                                   tint: ShiftProjectCardView.tint(for: status),
                                   style: status == .inProgress ? .dotWord : .pill,
                                   theme: theme)
    }

    /// The one place subtasks render - nested under their parent task inside
    /// a project's detail, never as rows in the List tab's table (see
    /// ShiftModels.swift's header for why that boundary matters).
    /// Includes both active and completed tasks, since a project's real task
    /// breakdown includes finished work, not just what's still open.
    private func rebuildDetailTasks(_ project: ShiftProject) {
        let tasks = store.allTasks(forProject: project.id)
        detailTasksCountBadge.stringValue = "\(tasks.count)"
        detailTaskListView.setTasks(tasks, expandedTaskIDs: expandedTaskIDs)
        detailTaskListView.applyTheme(theme)
    }

    @objc private func detailBackClicked() {
        projectsView = .grid
        render()
    }

    /// "+ Add Task" (fm/cockpit-shift-project-page-redesign) - opens the
    /// same New Task sheet the toolbar's New task uses, pre-selecting
    /// the project currently open. `presentTaskEditor`'s existing `onSave`
    /// calls `render()`, which re-enters `rebuildProjectDetail` for this
    /// same project and re-reads `store.allTasks(forProject:)` - the new
    /// task appears immediately, no navigation required.
    @objc private func addTaskToProjectClicked() {
        presentTaskEditor(for: nil, defaultProjectID: currentDetailProjectID)
    }

    @objc private func detailSaveClicked() {
        guard case .detail(let projectID) = projectsView,
              var project = store.projects.first(where: { $0.id == projectID }) else { return }
        project.name = detailNameField.stringValue
        project.description = detailDescriptionField.stringValue
        let statusIdx = detailStatusPopup.indexOfSelectedItem
        if statusIdx >= 0, statusIdx < ShiftProjectStatus.allCases.count {
            project.status = ShiftProjectStatus.allCases[statusIdx]
        }
        project.startDate = detailStartDateField.stringValue.isEmpty ? nil : detailStartDateField.stringValue
        project.dueDate = detailDueDateField.stringValue.isEmpty ? nil : detailDueDateField.stringValue
        project.hue = detailHuePicker.selectedHue
        store.updateProject(project)
        Toast.show(in: view, message: "Project saved")
        render()
    }

    // MARK: Creation / editing (phase 2)

    /// The Shift menu's "New Task…" (⌘N) - also reachable from the toolbar's
    /// New task.
    func presentNewTaskEditor() { presentTaskEditor(for: nil) }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - also reachable from the
    /// Follow-ups header's "+" button.
    func presentNewFollowUpEditor() { presentFollowUpEditor(for: nil) }

    /// The Shift menu's "New Project…" - also reachable from the Projects
    /// header's "+" button (cockpit-fix-shift-new-project).
    func presentNewProjectEditor() { presentProjectEditor() }

    /// On the Calendar view, New task is dated to the day the calendar shows.
    @objc private func newTaskClicked() {
        if isShowingCalendar { newTaskOnCalendar() } else { presentTaskEditor(for: nil) }
    }
    @objc private func newFollowUpClicked() { presentFollowUpEditor(for: nil) }
    @objc private func newProjectClicked() { presentProjectEditor() }

    /// `defaultStatus` is how a board column's own "+ Add task" puts a brand
    /// new task straight into In Progress: the editor has no status control
    /// (a task's status is something the board moves, not something a form
    /// sets), so the column applies it to whatever comes back. Ignored when
    /// editing an existing task, whose status is already whatever it is.
    /// Review #3's UX10: open the New Task sheet already filled in from a
    /// sticky note.
    ///
    /// The sheet rather than a silent `addTask`, deliberately. The note's
    /// colour is a *guess* at priority (see `StickyNotePromotion`), and the
    /// title may have been borrowed from the note's first line - both are
    /// things the captain should see and be able to correct before a task
    /// exists, and neither is worth a second "undo that" toast.
    func presentTaskEditor(prefilledFrom note: StickyNote) {
        presentTaskEditor(for: nil, prefill: StickyNotePromotion.task(from: note))
    }

    /// `prefill` seeds a **new** task's fields; `task` edits an existing one.
    /// They are separate parameters rather than one, because which of the two
    /// it is decides whether saving calls `addTask` or `updateTask` - passing a
    /// prefilled task as `task` would silently make the promotion overwrite a
    /// task that does not exist yet.
    /// The sheet itself is `ShiftRecordSheets`', shared with the Calendar.
    private func presentTaskEditor(for task: ShiftTask?,
                                   prefill: ShiftTask? = nil,
                                   defaultProjectID: String? = nil,
                                   defaultStatus: ShiftTaskStatus? = nil) {
        ShiftRecordSheets.presentTaskEditor(
            from: self, store: store, task: task, prefill: prefill,
            defaultProjectID: defaultProjectID, defaultStatus: defaultStatus,
            onSaved: { [weak self] in self?.render() },
            onDelete: { [weak self] id in self?.confirmDeleteTask(id: id) })
    }

    private func presentFollowUpEditor(for followUp: ShiftFollowUp?) {
        ShiftRecordSheets.presentFollowUpEditor(from: self, store: store, followUp: followUp,
                                                onSaved: { [weak self] in self?.render() },
                                                onDelete: { [weak self] id in self?.confirmDeleteFollowUp(id: id) })
    }

    /// Presents the New Project sheet (cockpit-fix-shift-new-project) - the
    /// grid re-renders immediately on save so the new project shows up
    /// without navigating away and back, exactly like a new task/follow-up.
    private func presentProjectEditor() {
        let editor = ShiftProjectEditorController()
        editor.initialHue = ShiftProjectPalette.firstFreeHue(among: store.projects)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            self.store.addProject(saved)
            self.render()
        }
        presentAsSheet(editor)
    }

    /// Recomputes and persists a follow-up's `follow_up_at`/`follow_up_time`
    /// for one of the Snooze menu's presets, or opens the Custom picker
    /// sheet for the last option - the actual write happens in
    /// `ShiftStore.snoozeFollowUp`, this just does the relative-offset math.
    private func snoozeFollowUp(_ item: ShiftFollowUp, option: ShiftSnoozeOption) {
        let now = Date()
        let current = ShiftDateFormatting.dateTime(from: item.followUpAt, time: item.followUpTime) ?? now
        let cal = Calendar.current
        switch option {
        case .minutes30:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .minute, value: 30, to: now) ?? now)
            render()
        case .hour1:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .hour, value: 1, to: now) ?? now)
            render()
        case .tomorrow:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .day, value: 1, to: current) ?? now)
            render()
        case .nextWeek:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .day, value: 7, to: current) ?? now)
            render()
        case .custom:
            let picker = ShiftSnoozeCustomController(initial: current)
            picker.onPick = { [weak self] date in
                self?.store.snoozeFollowUp(id: item.id, to: date)
                self?.render()
            }
            presentAsSheet(picker)
        }
    }

    // MARK: Probe / self-test surface

    // GL-27: debug hooks compile into debug builds only. The older probes in
    // this app's pages predate that rule and are being guarded as each page is
    // touched; these are new, so they carry it from the start.
    #if FM_SELFTESTS

    /// `ReviewTourLab`'s `tasks <view>` verb: picks a view through the same
    /// switch the window toolbar's tabs reach, so a tour renders what a click
    /// would have shown rather than what a private setter would.
    func debugShowView(_ id: String) { selectView(id) }

    // fm/grandline-tasks-kanban-devops-split: the board's own probe surface.
    // Structure rather than appearance, deliberately - a column holding the
    // wrong cards, a toggle that hides nothing, and a card that never
    // receives a mouse event all render plausibly.

    /// The scope the page is filtering by right now.
    var debugTaskScope: String { taskScope.rawValue }
    var debugProjectFilter: String? { projectFilter }

    /// The task ids each board column is showing, after every filter.
    func debugVisibleTaskIDs(_ column: ShiftBoardColumn) -> [String] {
        boardView.debugColumn(column)?.debugCardViews.map(\.taskID) ?? []
    }

    /// UI-16: the page draws no stat tiles; the counts live in the drill
    /// subtitle and the hero band. Kept as a probe so a suite can assert none
    /// came back.
    var debugStatTileCount: Int {
        func walk(_ v: NSView) -> Int {
            (v is HelmKPIStrip.BoxedCell ? 1 : 0) + v.subviews.reduce(0) { $0 + walk($1) }
        }
        return walk(dashboardContainer)
    }

    var debugBoardView: ShiftBoardView? { boardView }

    /// UI-17: the chip row is gone; nothing on the page is a
    /// `ShiftProjectFilterBar` any more.
    var debugHasProjectChipRow: Bool {
        func walk(_ v: NSView) -> Bool { v is ShiftProjectFilterBar || v.subviews.contains(where: walk) }
        return walk(view)
    }

    /// UI-15: the window toolbar's tabs are the page's one view switcher, so
    /// nothing on the page outside the embedded calendar (whose periods are
    /// its own) is a `HelmSegmentedTabs`.
    var debugHasOwnViewSwitcher: Bool {
        func walk(_ v: NSView) -> Bool {
            v !== calendarSection && (v is HelmSegmentedTabs || v.subviews.contains(where: walk))
        }
        return walk(view)
    }
    var debugBoardIsVisible: Bool { !boardSection.isHidden }
    var debugFailedReadIsVisible: Bool { !failedReadCard.isHidden }
    var debugFailedReadSubline: String { failedReadHeader.sublineLabel.stringValue }
    var debugFailedReadTitle: String { failedReadHeader.titleLabel.stringValue }
    /// REL-01: whether the project detail is showing.
    var debugProjectDetailIsVisible: Bool { !projectsDetailContainer.isHidden }

    /// Picks a view through the page's one view switch, the one the window
    /// toolbar's tabs reach (`selectModuleTab(named:)`).
    func debugSelectTasksView(_ id: String) { selectView(id) }

    /// The page's one render pass, for a test that has just mutated the store
    /// behind its back.
    func debugRender() { render() }

    var debugBoardColumns: [ShiftBoardColumnView] { boardView.debugColumnViews }

    /// UXP-02: the project cards the last render built.
    var debugProjectCards: [ShiftProjectCardView] { projectCards }

    // MARK: F7's probe surface

    var debugFocusPanelIsVisible: Bool { !reviewFocusPanel.isHidden }
    var debugFocusChart: FocusWeekBarView { reviewFocusChart }
    var debugFocusHeadline: String { reviewFocusHeadline.stringValue }
    var debugFocusCaption: String { reviewFocusCaption.stringValue }

    /// Opens a project's detail through the same path a card click takes, on a
    /// project seeded for the test - or a fresh one when the scratch store is
    /// empty, since the detail state is what is under test, not the data.
    func debugOpenFirstProjectDetail() {
        if store.projects.isEmpty {
            var project = ShiftProject.fresh()
            project.name = "Probe project"
            store.addProject(project)
        }
        guard let first = store.projects.first else { return }
        projectsView = .detail(first.id)
        renderProjectsSection()
    }

    #endif

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)

        followUpsHeader.textColor = ink
        projectsHeader.textColor = ink
        detailTasksHeader.textColor = ink

        for header in sectionHeaders { header.applyTheme(theme) }
        followUpPanel.applyTheme(theme)
        projectsPanel.applyTheme(theme)
        followUpsCountBadge.textColor = muted
        projectsCountBadge.textColor = muted
        // UXP-02: the project grid is built per data render, so the cards on
        // screen are repainted here rather than left in the old palette.
        for card in projectCards { card.applyTheme(theme) }
        projectsGridEmptyState?.applyTheme(theme)
        applySyncPill()

        detailBackButton.contentTintColor = muted
        detailIconTile.applyTheme(theme)
        detailNameLabel.textColor = ink
        detailMetaLabel.textColor = muted
        detailDescriptionLabel.textColor = muted
        detailFormPanel.applyTheme(theme)
        detailStatusPopup.contentTintColor = ink
        detailTasksPanel.applyTheme(theme)
        detailTasksCountBadge.textColor = muted
        if case .detail(let projectID) = projectsView, let project = store.projects.first(where: { $0.id == projectID }) {
            applyDetailStatusPill(project.status)
        }
        detailTaskListView.applyTheme(theme)

        boardView.applyTheme(theme)
        followUpLane.applyTheme(theme)

        reviewGreeting.textColor = ink
        reviewPushedBackHeader.textColor = ink
        reviewPushedBackList.applyTheme(theme)
        reviewPushedBackPanel.applyTheme(theme)
        reviewAgendaPanel.applyTheme(theme)
        reviewFocusPanel.applyTheme(theme)
        reviewFocusHeader.textColor = ink
        reviewFocusHeadline.textColor = ink
        reviewFocusCaption.textColor = muted
        reviewFocusChart.applyTheme(theme)
        tasksTable.applyTheme(theme)
        followUpsTable.applyTheme(theme)
        reviewCardsRow.applyTheme(theme)
    }
}

// MARK: - Sort

/// How the board's open lanes and the list are ordered - the toolbar's quiet
/// sort popup (the UI/UX revamp's Tasks toolbar). The Done lane keeps its
/// own newest-first order whatever this says: a pile of finished work is
/// read from the top.
enum ShiftTaskSort: String, CaseIterable {
    case dueDate
    case priority
    case recentlyUpdated

    static let defaultsKey = "fm.shift.taskSort"

    var title: String {
        switch self {
        case .dueDate: return "Due date"
        case .priority: return "Priority"
        case .recentlyUpdated: return "Recently updated"
        }
    }

    func areInOrder(_ lhs: ShiftTask, _ rhs: ShiftTask) -> Bool {
        switch self {
        case .dueDate:
            return ShiftController.byDueDateThenCreated(lhs, rhs)
        case .priority:
            let rank: (ShiftPriority) -> Int = { $0 == .high ? 0 : ($0 == .normal ? 1 : 2) }
            if rank(lhs.priority) != rank(rhs.priority) { return rank(lhs.priority) < rank(rhs.priority) }
            return ShiftController.byDueDateThenCreated(lhs, rhs)
        case .recentlyUpdated:
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return ShiftController.byDueDateThenCreated(lhs, rhs)
        }
    }
}

// MARK: - Sync status presentation

/// How the Tasks page draws a `ShiftGitSync.Status` (UI-19). Pure, so the
/// whole mapping - including which failures are "offline" - is assertable
/// with no window.
enum ShiftSyncPresentation {
    struct Look: Equatable {
        let text: String
        let tint: HelmTint
        let style: HelmStatusPill.Style
        let toolTip: String?
    }

    static func look(for status: ShiftGitSync.Status) -> Look {
        switch status {
        case .synced:
            return Look(text: "Synced", tint: .good, style: .dotWord, toolTip: nil)
        case .localChanges:
            return Look(text: "Local changes", tint: .warn, style: .pill,
                        toolTip: "Edits here have not been pushed yet.")
        case .syncing:
            return Look(text: "Syncing\u{2026}", tint: .info, style: .pill, toolTip: nil)
        case .failed(let reason):
            if isOffline(reason) {
                return Look(text: "Offline \u{00B7} working locally", tint: .neutral, style: .pill,
                            toolTip: "Could not reach the sync remote. Edits are saved here and "
                                + "will sync when it is reachable.\n\n\(reason)")
            }
            return Look(text: "Sync failed", tint: .critical, style: .pill, toolTip: reason)
        case .conflict(let fileCount):
            return Look(text: "Conflict \u{00B7} resolve", tint: .critical, style: .pill,
                        toolTip: "\(fileCount) file\(fileCount == 1 ? "" : "s") need a decision - click to resolve.")
        }
    }

    /// Whether a failure is the network rather than the repository - the
    /// remote could not be reached, so the honest state is "working
    /// locally", not an alarm.
    static func isOffline(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return [
            "could not resolve host", "network is unreachable", "unable to access",
            "operation timed out", "connection timed out", "connection refused",
            "could not read from remote repository", "working locally offline",
            "no route to host", "the internet connection appears to be offline",
        ].contains { lowered.contains($0) }
    }
}

// MARK: - Tasks' tabs in the window toolbar

extension ShiftController: ModuleTabHosting {
    var moduleTabNames: [String] { ["Board", "List", "Calendar", "Weekly review"] }

    var selectedModuleTabName: String {
        guard topLevelView == .dashboard else { return "Weekly review" }
        switch tasksView {
        case .board: return "Board"
        case .list: return "List"
        case .calendar: return "Calendar"
        }
    }

    /// Through the page's one view switch (`selectView(_:)`). "Calendar" is
    /// also where the Calendar sidebar row and the toolbar's calendar button
    /// land (`ModuleTable.landing(for:)`).
    func selectModuleTab(named name: String) {
        switch name {
        case "Weekly review": selectView(Self.reviewViewID)
        case "List": selectView(ShiftTasksView.list.rawValue)
        case "Calendar": selectView(ShiftTasksView.calendar.rawValue)
        default: selectView(ShiftTasksView.board.rawValue)
        }
    }

    /// Nothing to put away: the page draws no view switcher of its own, so
    /// the toolbar's tabs are its only ones.
    func setModuleTabControlHidden(_ hidden: Bool) {
        _ = hidden
    }
}

// MARK: - The page's presentation (stage 7)

// The prototype's Tasks: Board, List, Calendar and Weekly review as the
// toolbar's tabs, New task at the toolbar's far right, and no second column
// inside the page. The hero band carries the scope, the Smart views, the
// Follow-ups jump and the project and sort menus (Tf-2), and the calendar's
// month head carries the same as menus (Cf-4). Settings is the sidebar's own
// row and Shortcuts is the toolbar's Search (⌘K). The board is the
// prototype's lanes and cards, the List tab is the same tasks as one table,
// and Follow-ups and Projects sit under the view.

/// Tf-2 and Cf-4: the grey count line above the band said what the band's
/// figures and the calendar head already say, so the shell's header line
/// draws nothing here and gives up its slot. The subtitle itself stays the
/// page's summary (the crew panel reads it).
extension ShiftController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension ShiftController: WorkspacePrimaryActionProviding {

    func buildSidebarPresentation() {
        // T-4: the page's hero as a slim band, and since Tf-2 its filters.
        contentStack.insertArrangedSubview(heroBand, at: 0)
        heroBand.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        wireFilters()
        // The List tab's table, under the board.
        if let index = dashboardContainer.arrangedSubviews.firstIndex(of: boardSection) {
            dashboardContainer.insertArrangedSubview(tasksTable.card, at: index + 1)
        }
        tasksTable.card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        // Centred in the page like every page-level empty state (UXP-13),
        // not resting at the top of the scroll document.
        startHereState.placeAsPageEmptyState(in: view)
        startHereState.isHidden = true
        render()
    }

    // MARK: R2-UX-07 - an empty Tasks page that invites

    /// Nothing open, nothing completed lately, no follow-up and no project:
    /// a store a captain has never used.
    private var showsStartHere: Bool {
        !store.isInFailedLoadState && store.activeTasks.isEmpty && store.followUps.isEmpty
            && store.projects.isEmpty && boardTasks().values.allSatisfy(\.isEmpty)
    }

    #if FM_SELFTESTS
    var debugStartHereState: HelmEmptyState { startHereState }
    var debugStoreIsEmpty: Bool { store.activeTasks.isEmpty && store.followUps.isEmpty && store.projects.isEmpty }
    var debugStartHereReplacesHidden: [Bool] { startHereReplaces.map(\.isHidden) }
    #endif

    /// One example, due today, that explains itself and is gone when ticked.
    @objc func addExampleTaskTapped() {
        var task = ShiftTask.fresh()
        task.title = "Tick this task when you have read it - that is how a task is done"
        task.dueDate = ShiftDateFormatting.components(from: Date()).dateStr
        store.addTask(task)
    }

    /// New task, at the toolbar's far right after Search.
    var workspacePrimaryAction: NSView? { newTaskButton }

    /// T-4's slim band: the day's verdict and figures from the same counting
    /// pass the subtitle reads, and the Done lane's own seven-day window for
    /// the ring.
    fileprivate func renderHeroBand() {
        let summary = store.isInFailedLoadState ? nil : counts()
        let done = boardTasks()[.done]?.count ?? 0
        heroBand.configure(ShiftHeroWords.band(summary: summary, doneLastWeek: done))
    }

    #if FM_SELFTESTS
    var debugHeroBand: ShiftTasksHeroBand? { !heroBand.isHidden ? heroBand : nil }
    #endif

    /// The band's and the calendar head's filters call back here, so the
    /// scope, the project, the sort and the colouring each have one owner.
    /// The calendar's are wired when it is embedded (`wireCalendarFilters`).
    private func wireFilters() {
        heroBand.onSelectScope = { [weak self] id in self?.selectScope(id) }
        heroBand.onFollowUps = { [weak self] in self?.followUpsJumpClicked() }
        heroBand.onShowProjectMenu = { [weak self] view in self?.popUp(self?.projectMenu(), from: view) }
        heroBand.onShowSortMenu = { [weak self] view in self?.popUp(self?.sortMenu(), from: view) }
    }

    /// Cf-4: the calendar's month head draws the same filters as menus. Run
    /// when the calendar is embedded, which can be before or after the shell
    /// adopts the page.
    func wireCalendarFilters() {
        calendar.setHeroFilterHandlers(
            scope: { [weak self] view in self?.popUp(self?.scopeMenu(), from: view) },
            project: { [weak self] view in self?.popUp(self?.projectMenu(), from: view) },
            colour: { [weak self] view in self?.popUp(self?.colourMenu(), from: view) })
        refreshFilters()
    }

    private func selectScope(_ id: String) {
        guard let scope = ShiftTaskScope(rawValue: id) else { return }
        taskScope = scope
        render()
    }

    /// The counts, the List tab's rows and what every filter says - from the
    /// same pass `render` just made.
    fileprivate func renderWorkspaceChrome() {
        renderHeroBand()
        refreshFilters()
        tasksTable.setRows(taskTableRows())
        followUpsTable.setRows(followUpTableRows())
    }

    /// What the band's figures and pills, and the calendar head's menus, say.
    func refreshFilters() {
        let project = projectFilter.flatMap { id in store.projects.first { $0.id == id } }
        let projectTitle = project.map { $0.name.isEmpty ? "Untitled project" : $0.name } ?? "All projects"
        heroBand.setFilters(scope: taskScope.rawValue, projectTitle: projectTitle,
                            projectFiltered: project != nil, sortTitle: taskSort.title,
                            followUpsJumps: followUpsJumpWanted)
        guard calendarSection.superview != nil else { return }
        calendar.setHeroFilters(.init(scope: Self.scopeMenuTitle(taskScope, counts: counts()),
                                      scopeNarrows: taskScope != .all,
                                      project: projectTitle, projectNarrows: project != nil,
                                      colour: calendarColouring.title))
    }

    /// "All tasks · 16", "Overdue · 2", "My priorities": the scope with its
    /// count where the page has one, as the calendar's scope menu reads it.
    static func scopeMenuTitle(_ scope: ShiftTaskScope, counts c: Counts) -> String {
        switch scope {
        case .all: return "\(scope.title) \u{00B7} \(c.open)"
        case .dueToday: return "\(scope.title) \u{00B7} \(c.dueToday)"
        case .overdue: return "\(scope.title) \u{00B7} \(c.overdue)"
        case .myPriorities, .recentlyUpdated: return scope.title
        }
    }

    // MARK: The filter menus (Tf-2, Cf-4)

    /// Every scope, in the two groups the old row drew, with the counts the
    /// page has and a check on the one that is on.
    func scopeMenu() -> NSMenu {
        let menu = NSMenu()
        let c = counts()
        for (index, group) in [ShiftTaskScope.workspaceCases, ShiftTaskScope.smartViewCases].enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for scope in group {
                let item = NSMenuItem(title: Self.scopeMenuTitle(scope, counts: c),
                                      action: #selector(scopeMenuPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = scope.rawValue
                item.state = scope == taskScope ? .on : .off
                item.image = HelmSymbol.image(scope.symbol, pointSize: 12, weight: .regular)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// All projects, then each project with its hue's dot.
    func projectMenu() -> NSMenu {
        let menu = NSMenu()
        let all = NSMenuItem(title: "All projects", action: #selector(projectMenuPicked(_:)), keyEquivalent: "")
        all.target = self
        all.state = projectFilter == nil ? .on : .off
        menu.addItem(all)
        if !store.projects.isEmpty { menu.addItem(.separator()) }
        for project in store.projects {
            let item = NSMenuItem(title: project.name.isEmpty ? "Untitled project" : project.name,
                                  action: #selector(projectMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
            item.state = project.id == projectFilter ? .on : .off
            item.image = Self.projectDot(ShiftProjectPalette.hex(for: ShiftProjectPalette.hue(for: project), in: theme))
            menu.addItem(item)
        }
        return menu
    }

    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, order) in ShiftTaskSort.allCases.enumerated() {
            let item = NSMenuItem(title: order.title, action: #selector(sortMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = order == taskSort ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    func colourMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, colouring) in ShiftCalendarColouring.allCases.enumerated() {
            let item = NSMenuItem(title: colouring.title, action: #selector(colourMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = colouring == calendarColouring ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc fileprivate func scopeMenuPicked(_ sender: NSMenuItem) {
        selectScope(sender.representedObject as? String ?? ShiftTaskScope.all.rawValue)
    }

    @objc fileprivate func projectMenuPicked(_ sender: NSMenuItem) {
        projectFilter = sender.representedObject as? String
        render()
    }

    @objc fileprivate func sortMenuPicked(_ sender: NSMenuItem) {
        guard ShiftTaskSort.allCases.indices.contains(sender.tag) else { return }
        setTaskSort(ShiftTaskSort.allCases[sender.tag])
    }

    @objc fileprivate func colourMenuPicked(_ sender: NSMenuItem) {
        let all = ShiftCalendarColouring.allCases
        guard all.indices.contains(sender.tag) else { return }
        setCalendarColouring(all[sender.tag])
        refreshFilters()
    }

    /// Opens `menu` under `view`, in the page's own appearance
    /// (`ThemeManager`'s checklist item 2: an `NSMenu` resolves system colours).
    private func popUp(_ menu: NSMenu?, from view: NSView) {
        guard let menu else { return }
        menu.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        let below = view.isFlipped ? view.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
    }

    #if FM_SELFTESTS
    /// Picks a menu item through its own target and action, as a click on it
    /// does, without opening the menu (which would run a modal loop).
    static func debugPick(_ menu: NSMenu, where matches: (NSMenuItem) -> Bool) {
        guard let item = menu.items.first(where: matches), let action = item.action,
              let target = item.target as? NSObject else { return }
        target.perform(action, with: item)
    }
    #endif

    @objc fileprivate func followUpsJumpClicked() {
        scrollToPanel(followUpPanel)
    }

    /// A project's dot for its popup item, in the hue its cards and lanes use.
    private static func projectDot(_ hex: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            HelmTheme.nsColor(hex).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    // MARK: The List tab

    /// The filtered open tasks in the page's sort, then the ones finished in
    /// the Done window - the board's three lanes as one list.
    fileprivate func taskTableRows() -> [HelmDataTable.Row] {
        let board = boardTasks()
        let tasks = (board[.backlog] ?? []) + (board[.inProgress] ?? [])
        let open = tasks.sorted(by: taskSort.areInOrder)
        let done = board[.done] ?? []
        // S09: the Done window is said where it applies, as the Done group's
        // header, rather than as a label beside the sort.
        let doneGroup: [HelmDataTable.Row] = done.isEmpty
            ? []
            : [.group("\(ShiftBoardColumn.done.title) \u{00B7} \(Self.doneWindowCaption)")]
        let rows = open.map { taskRow($0, column: ShiftBoardColumn.column(for: $0.status) ?? .backlog) }
            + doneGroup + done.map { taskRow($0, column: .done) }
        guard rows.isEmpty else { return rows }
        let filter = filterDescription()
        return [.empty(symbol: "checklist", title: filter.text == nil ? "No tasks yet" : "No tasks match",
                       body: filter.text.map { "Nothing \($0)." } ?? "New task adds one.",
                       action: filter.text == nil
                           ? .init(title: "New task", symbol: "plus") { [weak self] in self?.newTaskClicked() }
                           : .init(title: filter.clearTitle, symbol: "line.3.horizontal.decrease.circle") {
                               [weak self] in self?.clearFilters() })]
    }

    private func taskRow(_ task: ShiftTask, column: ShiftBoardColumn) -> HelmDataTable.Row {
        var row = HelmDataTable.Row.record(task.id)
        let isDone = column == .done
        let check = ShiftTaskCheckBadge(size: 18)
        check.setChecked(isDone, tint: HelmTheme.nsColor(isDone ? HelmTint.good.hex(in: theme) : theme.chromeLineHex))
        check.setAccessibilityLabel(isDone ? "Reopen \(task.title)" : "Complete \(task.title)")
        let id = task.id
        check.target = self
        check.action = #selector(tableCheckClicked(_:))
        check.identifier = NSUserInterfaceItemIdentifier(id)
        row.cells["done"] = .view(check)
        var subtitle: String?
        if !task.subtasks.isEmpty {
            subtitle = "\(task.subtasks.filter(\.done).count) of \(task.subtasks.count) subtasks"
        }
        row.cells["task"] = .title(task.title, subtitle: subtitle, subtitleIsCode: false, symbol: nil,
                                   tint: .neutral, tintHex: nil)
        let project = task.projectID.flatMap { pid in store.projects.first { $0.id == pid } }
        row.cells["project"] = .view(ShiftProjectTag(
            name: project?.name ?? "No project",
            hex: ShiftProjectPalette.hex(for: ShiftProjectPalette.hue(for: project, projectID: task.projectID), in: theme),
            theme: theme))
        row.cells["status"] = .muted(column.title)
        if let pill = ShiftTaskSignals.priorityPill(task.priority) {
            let chip = HelmStatusPill(style: .pill)
            chip.configure(text: pill.text, tint: pill.tint, theme: theme)
            row.cells["priority"] = .view(chip)
        } else {
            row.cells["priority"] = HelmDataTable.Cell.none
        }
        if isDone {
            let done = task.completedAt.flatMap(ShiftStore.date(fromISO8601:))
            row.cells["due"] = done.map { .muted("Done \(ShiftBoardCardView.doneDateFormatter.string(from: $0))") }
                ?? HelmDataTable.Cell.none
        } else if let due = ShiftTaskSignals.dueCaption(date: task.dueDate, time: task.dueTime) {
            row.cells["due"] = due.tint.map { .status(due.text, tint: $0) } ?? .muted(due.text)
        } else {
            row.cells["due"] = HelmDataTable.Cell.none
        }
        row.activate = { [weak self] in self?.openBoardTask(id: id) }
        var menu: [HelmDataTable.Action] = [
            .init(title: "Open Task\u{2026}", symbol: "arrow.up.forward.square") { [weak self] in
                self?.openBoardTask(id: id)
            },
            isDone
                ? .init(title: "Reopen", symbol: "arrow.uturn.backward") { [weak self] in
                    self?.moveTask(id: id, to: .backlog) }
                : .init(title: "Mark Done", symbol: "checkmark.circle") { [weak self] in
                    self?.moveTask(id: id, to: .done) },
        ]
        if !isDone {
            for option in ShiftDuePush.allCases {
                menu.append(.init(title: "Push to \(option.menuTitle)", symbol: "calendar.badge.clock") {
                    [weak self] in self?.pushDueDate(task, by: option)
                })
            }
            let focusing = focusTimer?.session?.taskID == id
            if focusing {
                row.primary = .init(title: "Stop", symbol: "stop.circle") { [weak self] in self?.stopFocus() }
                row.pinsPrimary = true
                menu.append(.init(title: "Stop Focus", symbol: "stop.circle") { [weak self] in self?.stopFocus() })
            } else if focusTimer != nil {
                let first = FocusTimerEngine.durationChoices.first ?? 25
                row.primary = .init(title: "Focus \(first) min", symbol: "timer") { [weak self] in
                    self?.startFocus(on: task, minutes: first)
                }
                for minutes in FocusTimerEngine.durationChoices {
                    menu.append(.init(title: "Focus for \(minutes) minutes", symbol: "timer") { [weak self] in
                        self?.startFocus(on: task, minutes: minutes)
                    })
                }
            }
        }
        menu.append(.init(title: "Delete Task\u{2026}", symbol: "trash") { [weak self] in
            self?.confirmDeleteTask(id: id)
        })
        row.menu = menu
        return row
    }

    @objc fileprivate func tableCheckClicked(_ sender: ShiftTaskCheckBadge) {
        guard let id = sender.identifier?.rawValue else { return }
        if store.activeTasks.contains(where: { $0.id == id }) {
            moveTask(id: id, to: .done)
        } else {
            moveTask(id: id, to: .backlog)
        }
    }

    // MARK: The Follow-ups table

    /// Pending follow-ups in the store's order, then the ones already done -
    /// the List tab's shape, open work above finished work.
    fileprivate func followUpTableRows() -> [HelmDataTable.Row] {
        let items = store.followUps
        let rows = (items.filter { $0.status != .done } + items.filter { $0.status == .done }).map(followUpRow)
        guard rows.isEmpty else { return rows }
        return [.empty(symbol: "bell", title: "No follow-ups yet", body: "New follow-up adds one.",
                       action: .init(title: "New follow-up", symbol: "plus") { [weak self] in
                           self?.newFollowUpClicked() })]
    }

    /// One follow-up, in `taskRow`'s columns and with its menu's shape:
    /// open, done or reopen, the follow-up's own reschedule (Snooze, where a
    /// task has Push to), and Delete last.
    private func followUpRow(_ item: ShiftFollowUp) -> HelmDataTable.Row {
        var row = HelmDataTable.Row.record(item.id)
        let isDone = item.status == .done
        let id = item.id
        let check = ShiftTaskCheckBadge(size: 18)
        check.setChecked(isDone, tint: HelmTheme.nsColor(isDone ? HelmTint.good.hex(in: theme) : theme.chromeLineHex))
        check.setAccessibilityLabel(isDone ? "Reopen \(item.title)" : "Mark \(item.title) as done")
        check.target = self
        check.action = #selector(followUpTableCheckClicked(_:))
        check.identifier = NSUserInterfaceItemIdentifier(id)
        row.cells["done"] = .view(check)
        row.cells["followUp"] = .title(item.title, subtitle: nil, subtitleIsCode: false, symbol: nil,
                                       tint: .neutral, tintHex: nil)
        let project = item.projectID.flatMap { pid in store.projects.first { $0.id == pid } }
        row.cells["project"] = .view(ShiftProjectTag(
            name: project?.name ?? "No project",
            hex: ShiftProjectPalette.hex(for: ShiftProjectPalette.hue(for: project, projectID: item.projectID), in: theme),
            theme: theme))
        row.cells["status"] = .muted(isDone ? "Done" : "Pending")
        if let pill = ShiftTaskSignals.priorityPill(item.priority) {
            let chip = HelmStatusPill(style: .pill)
            chip.configure(text: pill.text, tint: pill.tint, theme: theme)
            row.cells["priority"] = .view(chip)
        } else {
            row.cells["priority"] = HelmDataTable.Cell.none
        }
        if isDone {
            row.cells["due"] = item.followUpAt.map { .muted(ShiftDateFormatting.friendly($0)) }
                ?? HelmDataTable.Cell.none
        } else if let due = ShiftTaskSignals.dueCaption(date: item.followUpAt, time: item.followUpTime) {
            row.cells["due"] = due.tint.map { .status(due.text, tint: $0) } ?? .muted(due.text)
        } else {
            row.cells["due"] = HelmDataTable.Cell.none
        }
        row.activate = { [weak self] in self?.openFollowUp(id: id) }
        var menu: [HelmDataTable.Action] = [
            .init(title: "Open Follow-up\u{2026}", symbol: "arrow.up.forward.square") { [weak self] in
                self?.openFollowUp(id: id)
            },
            isDone
                ? .init(title: "Reopen", symbol: "arrow.uturn.backward") { [weak self] in
                    self?.toggleFollowUpDone(id: id) }
                : .init(title: "Mark Done", symbol: "checkmark.circle") { [weak self] in
                    self?.toggleFollowUpDone(id: id) },
        ]
        if !isDone {
            let snoozes: [(String, String, ShiftSnoozeOption)] = [
                ("Snooze 30 Minutes", "clock", .minutes30),
                ("Snooze 1 Hour", "clock", .hour1),
                ("Snooze to Tomorrow", "sun.max", .tomorrow),
                ("Snooze to Next Week", "calendar", .nextWeek),
                ("Snooze Until\u{2026}", "slider.horizontal.3", .custom),
            ]
            for (title, symbol, option) in snoozes {
                menu.append(.init(title: title, symbol: symbol) { [weak self] in
                    self?.snoozeFollowUp(item, option: option)
                })
            }
        }
        menu.append(.init(title: "Delete Follow-up\u{2026}", symbol: "trash") { [weak self] in
            self?.confirmDeleteFollowUp(id: id)
        })
        row.menu = menu
        return row
    }

    @objc fileprivate func followUpTableCheckClicked(_ sender: ShiftTaskCheckBadge) {
        guard let id = sender.identifier?.rawValue else { return }
        toggleFollowUpDone(id: id)
    }

    // MARK: Weekly review

    /// The agenda's rows: one per task or follow-up, the day it is due as
    /// the kicker, and a click opens it, as a search result does.
    private func renderReviewAgenda() {
        let items = store.nextWeekAgenda()
        reviewAgendaCount.text = "\(items.count)"
        reviewAgendaCount.applyTheme(theme)
        for v in reviewAgendaStack.arrangedSubviews {
            reviewAgendaStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard !items.isEmpty else {
            let empty = HelmEmptyState(symbol: "calendar", body: "Nothing is due next week.", size: .quiet)
            empty.applyTheme(theme)
            reviewAgendaStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: reviewAgendaStack.widthAnchor).isActive = true
            return
        }
        reviewAgendaList.setRows(items.map(reviewAgendaRow), theme: theme)
        reviewAgendaStack.addArrangedSubview(reviewAgendaList)
        if reviewAgendaListWidth == nil {
            reviewAgendaListWidth = reviewAgendaList.widthAnchor.constraint(equalTo: reviewAgendaStack.widthAnchor)
        }
        reviewAgendaListWidth?.isActive = true
    }

    static let agendaDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private func reviewAgendaRow(_ item: ShiftAgendaItem) -> NSView {
        let project = item.projectID.flatMap { id in store.projects.first { $0.id == id }?.name }
        var meta = item.kind == .task ? "Task" : "Follow-up"
        if let project { meta += " \u{00B7} \(project)" }
        let row = HelmAccentRow(hover: true, style: .flat)
        row.configure(HelmAccentRow.Content(tint: item.kind == .task ? .info : .warn,
                                            kicker: Self.agendaDayFormatter.string(from: item.due),
                                            title: item.title, meta: meta), theme: theme)
        row.onClick = { [weak self] in
            switch item.kind {
            case .task: self?.openTask(id: item.id)
            case .followUp: self?.openFollowUp(id: item.id)
            }
        }
        return row
    }

    /// The five figures, each from the store's own records.
    fileprivate func renderWorkspaceReview(_ summary: ShiftWeeklySummary) {
        let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: DayRollover.now())
            .map { store.weeklySummary(reference: $0).completedCount }
        typealias Item = HelmKPIStrip.Item
        var completedDetail: Item.Detail?
        if let lastWeek {
            let delta = summary.completedCount - lastWeek
            let text = delta == 0 ? "Same as last week" : "\(delta > 0 ? "+" : "\u{2212}")\(abs(delta)) vs last week"
            completedDetail = .init(text: text, tint: delta > 0 ? .good : nil)
        }
        let focusDays = store.focusSecondsByDay(days: 7)
        let focusSeconds = focusDays.reduce(0) { $0 + $1.seconds }
        let focusTasks = store.focusTaskCount(days: 7)
        let c = counts()
        let today = Calendar.current.startOfDay(for: DayRollover.now())
        let overdueTasks = store.activeTasks.filter(matchesProjectFilter).filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < today
        }.sorted(by: Self.byDueDateThenCreated)
        let pending = store.followUps.filter { $0.status == .pending }
        let dueToday = pending.filter { fu in
            fu.followUpAt.flatMap(ShiftDateFormatting.date(from:)).map { Calendar.current.isDate($0, inSameDayAs: DayRollover.now()) }
                ?? false
        }.count
        reviewCardsRow.configure([
            .figure("\(summary.completedCount)", caption: "Completed this week", detail: completedDetail),
            .figure(focusSeconds > 0 ? FocusTimerFormat.total(focusSeconds) : "None yet", caption: "Focus time",
                    detail: .init(text: focusSeconds > 0
                        ? "last 7 days \u{00B7} \(focusTasks) task\(focusTasks == 1 ? "" : "s") with a timer"
                        : "Start a focus session from any task")),
            .figure("\(c.overdue)", caption: "Overdue", tint: .critical, signals: c.overdue > 0,
                    detail: .init(text: overdueTasks.first?.title ?? "Nothing late")),
            .figure("\(pending.count)", caption: "Follow-ups open",
                    detail: .init(text: dueToday > 0 ? "\(dueToday) due today" : "None due today")),
            .figure("\(summary.upcomingCount)", caption: "Coming up next week",
                    detail: .init(text: "tasks and follow-ups due")),
        ], theme: theme)
        reviewPushedBackHeader.stringValue = "Pushed back repeatedly"
        reviewPushedBackCount.text = "\(summary.pushedBack.count)"
        reviewPushedBackCount.applyTheme(theme)
        renderReviewAgenda()
    }
}

#if FM_SELFTESTS
extension ShiftController {
    var debugTasksTable: HelmDataTable { tasksTable }
    var debugFollowUpsTable: HelmDataTable { followUpsTable }
    var debugReviewCards: [HelmKPIStrip.BoxedCell] { reviewCardsRow.debugCells }
    /// The Pushed back panel's count, when it is mounted and showing.
    var debugPushedBackCount: String? {
        reviewPushedBackCount.superview != nil && !reviewPushedBackCount.isHidden ? reviewPushedBackCount.text : nil
    }
    var debugNewTaskButton: HelmButton { newTaskButton }
    var debugTasksViewID: String { topLevelView == .weeklyReview ? "review" : tasksView.rawValue }
    /// Pick a project through the project menu's own item, as a click on it
    /// does (the band's and the calendar's menus are the same menu).
    func debugPickProject(id: String?) {
        Self.debugPick(projectMenu()) { ($0.representedObject as? String) == id && ($0.action != nil) }
    }
    /// Pick a scope through the calendar's scope menu, as a click on it does.
    func debugPickScopeFromMenu(_ id: String) {
        Self.debugPick(scopeMenu()) { ($0.representedObject as? String) == id }
    }
    func debugPickSort(_ sort: ShiftTaskSort) {
        Self.debugPick(sortMenu()) { $0.title == sort.title }
    }
    func debugPickColouring(_ colouring: ShiftCalendarColouring) {
        Self.debugPick(colourMenu()) { $0.title == colouring.title }
    }
}
#endif
