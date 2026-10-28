// Grand Line - native macOS app.
//
// The `.shift` rail destination: "My Tasks" (cockpit-shift-foundation, phase
// 1 of a multi-phase build - see AGENTS.md's "Shift" section). Structure
// mirrors `FleetController.swift`'s established page shape (greeting header,
// stat tiles, list sections in a `FlippedView`-backed scroll area) but the
// two real lists - tasks and follow-ups - render via `ShiftListViews.swift`'s
// `NSTableView`-based views rather than a plain `NSStackView` of permanent
// rows, per this app's own hard-learned Diff-tool lesson (see
// `DiffResultView.swift`'s header) about what happens to that pattern once a
// list grows into the hundreds.
//
// Creation/editing, Git sync, search, and the full Projects page are all
// out of scope for this phase - see the brief's "explicitly out of scope"
// list, restated in AGENTS.md. The Projects section here is the minimal
// placeholder the brief allowed, included mainly to prove out project-scoped
// subtask rendering (subtasks never appear as flat rows in the main task
// list - see the rule stated in ShiftModels.swift's header).

import AppKit

final class ShiftController: NSViewController, DaylightDrillActions, HelmSplitPageHosting {

    let store: ShiftStore

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    /// GL-16: see `UpdatesController.checkAllPill` - a clear-coloured
    /// `HoverHighlightView` renders identically to the plain `NSView` this
    /// was and inherits the shared press/focus/keyboard behaviour.
    private let syncPill = HoverHighlightView()
    /// UI-19: "Synced" is the default state, so it is a dot and a word; every
    /// other state is a pill. Both live in `syncPill`, exactly one showing.
    private let syncWord = HelmStatusPill(style: .dotWord)
    private let syncCapsule = HelmStatusPill(style: .pill)
    /// Live dashboard stat tiles. Each themes itself; this list only exists so
    /// `applyTheme` can reach the ones currently built (the row is rebuilt from
    /// scratch on every render).

    private let taskListView = ShiftTaskListView()
    private let taskListScroll = NSScrollView()
    private let tasksHeader = NSTextField(labelWithString: "")
    private let tasksCountBadge = NSTextField(labelWithString: "")
    private let taskPanel = HelmCard()

    private let followUpListView = ShiftFollowUpListView()
    private let followUpScroll = NSScrollView()
    private let followUpsHeader = NSTextField(labelWithString: "")
    private let followUpsCountBadge = NSTextField(labelWithString: "")
    let followUpPanel = HelmCard()

    private let projectsHeader = NSTextField(labelWithString: "")
    private let projectsCountBadge = NSTextField(labelWithString: "")
    private let projectsPanel = HelmCard()
    /// R2-UX-07: the dashboard's sections a start-here state stands in for.
    private var startHereReplaces: [NSView] = []
    /// The row Follow-ups sits in under the board, and the Projects section.
    private var followUpsRow: NSView?
    private var projectsSectionView: NSView?
    /// R4-UI-09: the sidebar layout's Follow-ups lane on the board.
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

    /// The two-tab switcher living just below the header - "My Tasks" (the
    /// existing stats/task/follow-up/projects content, unchanged) and
    /// "Weekly Review" (a distinct summary view). This keeps Shift a single
    /// consolidated destination (the captain's phase-1 decision, restated in
    /// AGENTS.md) while still giving Weekly Review "its own view" rather than
    /// squeezing it into the daily dashboard.
    /// `String`-backed so it can be the id `HelmSegmentedTabs` hands back -
    /// the shared component deals in caller-owned ids rather than indices, so a
    /// page keeps its own enum.
    enum ShiftTopLevelView: String { case dashboard, weeklyReview }
    var topLevelView: ShiftTopLevelView = .dashboard
    private let dashboardContainer = NSStackView()
    private let weeklyReviewContainer = NSStackView()

    // MARK: The board (fm/grandline-tasks-kanban-devops-split)

    /// How the captain's tasks are laid out: a Kanban board of three status
    /// columns, or the flat list this page has always had.
    ///
    /// The board is the captain's own ask - a flat list never answered "what
    /// is actually in flight right now", which is the question he opens this
    /// page with. The list is not a legacy fallback either: it is the only
    /// view that shows *every* active task at once, sorted by due date, which
    /// is exactly what a board deliberately is not.
    ///
    /// `String`-backed for the same reason `ShiftTopLevelView` is:
    /// `HelmSegmentedTabs` deals in caller-owned ids.
    ///
    /// F5 added a third, a calendar, and the captain later moved it out to a
    /// sidebar row of its own (`TaskCalendarController`), so it answers "when
    /// does this land" from one place rather than from a tab here and a page
    /// there.
    private enum ShiftTasksView: String { case board, list }
    private var tasksView: ShiftTasksView = .board
    /// UI-15: the page's **one** view switcher - Board, List and Review. There used to be two on one row (My Tasks / Weekly Review on
    /// the left, Board / List / Calendar on the right), which is two answers
    /// to "what am I looking at". Weekly Review is the fourth view now; it
    /// keeps its Shift-menu item and its ⌘K entry, both of which call
    /// `showWeeklyReview()`.
    private static let reviewViewID = "review"
    /// The sidebar layout's toolbar draws these four views as Tasks' tabs
    /// (`ModuleTabHosting`, at the end of this file).
    var onModuleTabChanged: (() -> Void)?
    private let viewTabs = HelmSegmentedTabs(items: [
        .init(id: ShiftTasksView.board.rawValue, title: "Board"),
        .init(id: ShiftTasksView.list.rawValue, title: "List"),
        .init(id: ShiftController.reviewViewID, title: "Review"),
    ], selected: ShiftTasksView.board.rawValue)

    /// The toolbar's quiet right-hand pair: how lanes and the list are
    /// sorted, and the Done lane's window stated once (UI-29).
    private let sortPopup = HelmPopUpButton()
    private let doneWindowNote = NSTextField(labelWithString: "Done \u{00B7} last 7 days")

    /// Which slice of the captain's tasks the page is showing - the sidebar's
    /// Workspace and Smart views rows.
    ///
    /// Deliberately **not** a project filter: that is its own orthogonal
    /// question and lives in its own sidebar group (and in the chip row above
    /// the board, which shows and sets the same one `projectFilter` - one
    /// filter reachable from two controls, never two filters). What a scope
    /// carries is the slice neither of those can state - "what is due today",
    /// "what is late", "what did I mark high", "what have I touched lately".
    ///
    /// `String`-backed because `HelmPageSidebar` deals in caller-owned row ids,
    /// the same reason `ShiftTasksView` and `ShiftTopLevelView` are.
    enum ShiftTaskScope: String, CaseIterable {
        case all, dueToday = "due_today", overdue
        case myPriorities = "my_priorities", recentlyUpdated = "recently_updated"

        /// The Workspace group: the slices that carry a live count, each one
        /// also stated by a stat tile at the top of the page.
        static let workspaceCases: [ShiftTaskScope] = [.all, .dueToday, .overdue]

        /// The Smart views group - derived slices with no tile of their own.
        ///
        /// Both are backed by fields `ShiftTask` genuinely carries
        /// (`priority`, `updatedAt`); neither invents a signal, which is why
        /// the reference's two smart views are the two that shipped and not a
        /// third that would have needed a new persisted field.
        static let smartViewCases: [ShiftTaskScope] = [.myPriorities, .recentlyUpdated]

        var title: String {
            switch self {
            case .all: return "All tasks"
            case .dueToday: return "Due today"
            case .overdue: return "Overdue"
            case .myPriorities: return "My priorities"
            case .recentlyUpdated: return "Recently updated"
            }
        }

        /// The same glyph the matching stat tile and panel header already use,
        /// so one idea is one icon everywhere on this page.
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

    /// The toolbar's sort, remembered per machine. Due date is the default
    /// because it is what the page always sorted by.
    private var taskSort: ShiftTaskSort = AppDefaults.store.string(forKey: ShiftTaskSort.defaultsKey)
        .flatMap(ShiftTaskSort.init(rawValue:)) ?? .dueDate

    /// The page's own left nav column - `HelmPageSidebar`, the component
    /// Schedules and Poneglyph already share (see its header for why a
    /// page-scoped column is not the deleted app-wide rail coming back).
    let sidebar = HelmPageSidebar()

    /// The hairline between the nav column and the page - the reference's own
    /// `border-right` on its `aside`, and the one thing that makes the column
    /// read as a column rather than as rows floating on the page. Hidden with
    /// the column itself on Weekly Review.
    /// P9: the page's split view, which holds `sidebar` as a real sidebar.
    private(set) var splitPage: HelmSplitPage?
    /// The content column's leading inset - see `applyContentLeadingInset`.
    private var contentStackLeading: NSLayoutConstraint?

    /// The content's distance from whatever is to its left.
    ///
    /// Beside the open column, the column's own trailing gap and the divider
    /// already separate the two, so the content sits `pageGutter` from the
    /// column's *content* rather than from the divider - where it has always
    /// been. With the column collapsed there is nothing to its left but the
    /// window edge, so the content keeps the whole `pageGutter`.
    ///
    /// UXP-03: this used to be a fixed negative inset on the scroll view,
    /// which was right only while the column showed. Weekly Review collapses
    /// the column, and its "Week of …" header sat about 7pt from the window
    /// edge - the one view in the app whose content touched it.
    private func applyContentLeadingInset() {
        let collapsed = splitPage?.isSidebarCollapsed ?? true
        contentStackLeading?.constant = collapsed
            ? HelmMetrics.pageGutter
            : HelmMetrics.pageGutter - (HelmMetrics.s4 + HelmSplitPage.dividerThickness)
    }

    /// Action rows: these scroll to a panel rather than filtering anything, so
    /// they are `.action` rows and never take the selection.
    static let followUpsRowID = "jump.followUps"

    /// The sidebar's Projects group. A row there selects independently of the
    /// Workspace/Smart-views rows, because "which slice" and "which project"
    /// are two orthogonal questions - picking a project must not un-pick
    /// "All tasks".
    static let projectGroup = "projects"
    static let projectRowPrefix = "project."
    static func projectRowID(_ id: String) -> String { projectRowPrefix + id }

    static let settingsRowID = "footer.settings"
    static let shortcutsRowID = "footer.shortcuts"

    /// What the Projects section was last built from, so a re-render only
    /// rebuilds the column when the project set genuinely changed - a rebuild
    /// on every render would churn the column on every keystroke elsewhere on
    /// the page (the same guard `KubernetesController.renderPodPicker` keeps).
    var sidebarProjectSignature: String?

    /// Forwarded rather than owned - this controller knows nothing about the
    /// shell (`AppShellController.onSearchTapped`'s own convention).
    var onNavigateToDestination: ((RailDestination) -> Void)?
    var onOpenCommandPalette: (() -> Void)?

    /// Two constraints, one active at a time: the content starts after the
    /// column while it is showing, and at the page edge while it is not (Weekly
    /// Review, which the column's task filters say nothing about). A plain
    /// `isHidden` is not enough on its own - an ordinary hidden `NSView` still
    /// carries its constraints (AGENTS.md gotcha (11)), so the gap it leaves
    /// would stay behind it.

    private let boardSection = NSStackView()

    /// UI-31 / GL-14: a task file that failed to parse is a stated failure
    /// naming the file and the line, never "0 open tasks" over empty lanes.
    /// The store already refuses to write such a file (GL-01); this card is
    /// the page saying so.
    private let failedReadCard = HelmCard()
    private let failedReadHeader = HelmSectionHeader(size: .hero)
    private let failedReadOpenButton = HelmButton(title: "Open file", variant: .secondary, size: .small)
    private var failedReadURL: URL?
    private let boardView = ShiftBoardView()
    /// `nil` = every project. UI-17: the sidebar's Projects group is the one
    /// control that sets it - the chip row that repeated the sidebar above the
    /// board is gone, which also fixes the List and Calendar views applying a
    /// filter no control on screen showed.
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

    private let reviewGreeting = NSTextField(labelWithString: "")
    private let reviewSubtitle = NSTextField(labelWithString: "What got done, what got pushed back, what's coming.")
    /// UI-44: Weekly Review's three numbers as a `HelmKPIStrip` on a card,
    /// not three boxed tiles.
    private let reviewStats = HelmKPIStrip()
    private let reviewStatsCard = HelmCard()
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
    /// repeatedly in the sidebar layout, where the page's lower half was
    /// blank at 1512x950.
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

    /// Shared fixed body height for the side-by-side My Tasks/Follow-ups
    /// panels (fm/grandline-shift-panel-height-scroll-fix). Both panels must
    /// always be the same height as each other regardless of how much - or
    /// how little - content either list holds; previously each scroll view
    /// had its own independent constant (300 for tasks, 220 for follow-ups),
    /// so the two cards never lined up once they sat side by side. A single
    /// shared constant on both `NSScrollView`s is what makes each list
    /// scroll internally once its content overflows, rather than the
    /// enclosing card growing to fit - see `buildTaskSection`/
    /// `buildFollowUpSection`.
    ///
    /// **A whole number of rows, derived rather than written down** - review
    /// #3's B11. The shared constant was a flat 280 against a 78pt row, which
    /// is 3.59 rows: the fourth row rendered with its kicker sliced off at the
    /// bottom edge, which reads as clipped rather than as "there is more,
    /// scroll". Both lists are `NSTableView`s with a fixed `rowHeight`, so
    /// snapping the box to `visibleRows * rowHeight` makes the cut land
    /// exactly on a row boundary and the next row is simply below the fold.
    /// `rowHeight` itself is `HelmType.scaledRowHeight`-driven, so a literal
    /// could not have stayed whole across the captain's chrome text sizes
    /// either.
    private static let taskFollowUpVisibleRows = 4
    private static var taskFollowUpPanelBodyHeight: CGFloat {
        ShiftTaskListView.rowHeight * CGFloat(taskFollowUpVisibleRows)
    }

    /// **Review defect U15.** The constant above is a *ceiling*, and it was
    /// being used as a fixed height - so on a new install the Follow-ups
    /// card stood four rows tall (about 480pt with its chrome) around a
    /// single "No follow-ups pending." line, and My Tasks did the same
    /// beside it. Two empty cards taking half the page is what the review
    /// rendered.
    ///
    /// The shared height is now the *content's* height, clamped to that
    /// ceiling - so a short list hugs, a long one scrolls at exactly the
    /// same place it did before, and an empty one is the height of the one
    /// placeholder row it actually draws.
    ///
    /// Still **one** number for both panels, which is the property the
    /// original constant existed for: two cards side by side that are
    /// different heights is the defect that constant fixed, and taking the
    /// larger of the two contents keeps them level without pinning either to
    /// four rows.
    private func sharedTaskFollowUpBodyHeight() -> CGFloat {
        // UI-30: when the task panel is hidden (Board), the
        // follow-ups panel stands alone and takes its height from its own
        // rows - it used to be sized by the hidden task list beside it, so a
        // long task list made a two-row follow-up panel scroll in a tall box.
        let wanted = taskPanel.isHidden
            ? followUpListView.contentHeight
            : max(taskListView.contentHeight, followUpListView.contentHeight)
        return min(wanted, Self.taskFollowUpPanelBodyHeight)
    }

    private var taskListHeightConstraint: NSLayoutConstraint?
    private var followUpHeightConstraint: NSLayoutConstraint?

    private func updateTaskFollowUpPanelHeights() {
        let height = sharedTaskFollowUpBodyHeight()
        taskListHeightConstraint?.constant = height
        followUpHeightConstraint?.constant = height
        taskOverflowHint.recount()
        followUpOverflowHint.recount()
    }

    /// UXP-18: "3 more below" under a panel that scrolls. The two panels sit
    /// side by side at one shared height (U15), so the hint row is shown on
    /// both or on neither - otherwise the panel with more rows would be a
    /// line taller than its neighbour.
    private let taskOverflowHint = HelmOverflowHint(leadingInset: HelmMetrics.s4, bottomInset: HelmMetrics.s3)
    private let followUpOverflowHint = HelmOverflowHint(leadingInset: HelmMetrics.s4, bottomInset: HelmMetrics.s3)

    private func applyPanelOverflowHints() {
        let taskCount = taskPanel.isHidden ? 0 : taskOverflowHint.countBelow
        let needed = taskCount > 0 || followUpOverflowHint.countBelow > 0
        taskOverflowHint.isHidden = !needed
        followUpOverflowHint.isHidden = !needed
    }

    /// A scrolling list's body: the list, then the hint row under it.
    private func panelBody(_ scroll: NSScrollView, hint: HelmOverflowHint, table: NSTableView) -> NSView {
        hint.watch(scroll) { (0..<table.numberOfRows).map { table.rect(ofRow: $0) } }
        hint.onCountChanged = { [weak self] _ in self?.applyPanelOverflowHints() }
        let stack = NSStackView(views: [scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    #if FM_SELFTESTS
    static var debugTaskFollowUpPanelBodyHeight: CGFloat { taskFollowUpPanelBodyHeight }

    /// Review defect U15: what the two panels are *actually* given, which is
    /// the number the card's own height follows.
    var debugTaskFollowUpBodyHeight: CGFloat { taskListHeightConstraint?.constant ?? -1 }
    #endif

    // MARK: The sidebar layout's state (stage 7)

    /// Set once, the first time the sidebar shell shows this page
    /// (`adoptSidebarLayout`). The floating bar never sets it.
    private(set) var drawsSidebarLayout = false
    /// The page column's filters, as one row under the header.
    private let workspaceFilterRow = NSStackView()
    private lazy var scopeFilter: HelmSegmentedTabs = {
        let tabs = HelmSegmentedTabs(items: ShiftTaskScope.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                     selected: ShiftTaskScope.all.rawValue, size: .compact)
        tabs.setAccessibilityLabel("Which tasks to show")
        tabs.onSelect = { [weak self] id in
            guard let self, let scope = ShiftTaskScope(rawValue: id) else { return }
            self.taskScope = scope
            self.render()
        }
        return tabs
    }()
    private lazy var followUpsJump: HelmButton = {
        let button = HelmButton(title: "Follow-ups", variant: .quiet, size: .small, symbol: "bell",
                                target: self, action: #selector(followUpsJumpClicked))
        button.toolTip = "Go to the Follow-ups card"
        return button
    }()
    private let projectPopup = HelmPopUpButton()
    /// R4-UI-08: the project and sort pop-ups as one button, while the filter
    /// row is too narrow for both (`fitFilterRow`). Its menu drives the two
    /// pop-ups' own selection and handlers, so the choice has one path.
    private lazy var filterMenuButton = HelmButton(title: "Filter", variant: .secondary, size: .small,
                                                   symbol: "line.3.horizontal.decrease", target: self,
                                                   action: #selector(filterMenuClicked))
    private var filterRowCollapsed = false
    /// Whether the Follow-ups jump belongs in the row: not while Follow-ups
    /// is a lane on the board, which is on screen already (R4-UI-09).
    private var followUpsJumpWanted = true
    private var projectPopupSignature: String?
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
    /// has, Delete included. The flat list only offered those on a right
    /// click nobody could see, so a follow-up looked like it could be ticked
    /// off and nothing else. It draws in `followUpPanel` itself, so the
    /// card's header, its Add and everything that hides or scrolls to it are
    /// unchanged.
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
    /// Weekly review's five figures, as the prototype's summary cards.
    private lazy var reviewCards: [HelmMetricCard] = [
        HelmMetricCard(caption: "Completed this week", tint: nil, showsDetail: true),
        HelmMetricCard(caption: "Focus time", tint: nil, showsDetail: true),
        HelmMetricCard(caption: "Overdue", tint: .critical, showsDetail: true),
        HelmMetricCard(caption: "Follow-ups open", tint: nil, showsDetail: true),
        HelmMetricCard(caption: "Coming up next week", tint: nil, showsDetail: true),
    ]
    private lazy var reviewCardsRow = HelmMetricRow(reviewCards)
    /// Time on tasks beside Pushed back repeatedly.
    private let reviewLowerRow = NSStackView()
    /// The strip's "pushed back 2+ times" figure, which the five cards do not
    /// carry: the Pushed back panel's own count.
    private let reviewPushedBackCount = HelmCountBadge()
    private var reviewPushedBackHeaderRow: HelmSectionHeader?

    /// F7's timer. Optional so every existing construction site (and every
    /// self-test that mounts this page to ask about something else) keeps
    /// working unchanged - a page with no timer simply renders no focus
    /// affordance, rather than needing a stub one.
    private let focusTimer: FocusTimerController?
    private var focusTimerToken: UUID?

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
        buildSidebar()
        let tabRow = buildTabRow()
        let taskSection = buildTaskSection()
        let followUpSection = buildFollowUpSection()
        let projectsSection = buildProjectsSection()
        buildBoardSection()

        // Daylight §7's board, as the captain has asked it to actually render:
        // **Today | Follow-ups as a two-column row, Projects full-width below
        // it.**
        //
        // §7's own written text groups Follow-ups and Projects into one
        // right-hand column (`fm/grandline-daylight-migration-phase4-slice1`,
        // PR #264, built it exactly that way), but a live captain screenshot
        // showed that reading squeezes Projects' own multi-card grid into half
        // the page width with the left column sitting empty beside it - not
        // the "more comfortable, full-width" board the captain wants and
        // recalls from before that slice. Per AGENTS.md's own instruction to
        // treat an explicit captain description of desired behaviour as
        // authoritative over the literal spec wording when the two conflict,
        // Projects goes back to being its own full-width section under the
        // Today/Follow-ups row - the shape the board had *before* PR #264,
        // just with Today/Follow-ups still side by side above it.
        //
        // `.fillEqually` on `tasksRow` keeps Today and Follow-ups the same
        // width; each column is a plain vertical stack holding just its one
        // section, so neither one grows a second row of its own. `.top`
        // alignment keeps the two columns flush at the top rather than
        // centred against each other - note this is AppKit's *unflipped*
        // space, so "top-aligned" means equal `maxY`, not equal `minY`.
        let leftColumn = NSStackView(views: [taskSection])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = HelmMetrics.s4
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        let rightColumn = NSStackView(views: [followUpSection])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = HelmMetrics.s4
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        tasksLeftColumn = leftColumn
        let tasksRow = NSStackView(views: [leftColumn, rightColumn])
        tasksRow.orientation = .horizontal
        tasksRow.distribution = .fillEqually
        tasksRow.alignment = .top
        tasksRow.spacing = HelmMetrics.s4
        tasksRow.translatesAutoresizingMaskIntoConstraints = false

        dashboardContainer.orientation = .vertical
        dashboardContainer.alignment = .leading
        dashboardContainer.spacing = HelmMetrics.s4
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        // The board's own toolbar (Board/List + the project chips) and the
        // board itself sit above the Today/Follow-ups row, full width - three
        // columns squeezed into half a page is the one layout a Kanban must
        // not have. In Board mode `taskPanel` hides, and because a *hidden
        // arranged subview of an `NSStackView`* leaves layout entirely
        // (AGENTS.md gotcha (11)'s one exception), Follow-ups takes the row
        // on its own rather than sitting beside an empty half.
        buildFailedReadCard()
        dashboardContainer.addArrangedSubview(failedReadCard)
        dashboardContainer.addArrangedSubview(boardSection)
        dashboardContainer.addArrangedSubview(tasksRow)
        // Projects is its own full-width section, a direct child of the
        // dashboard rather than nested in either column - it renders a
        // multi-column card grid of its own and reads better spanning the
        // page than confined to half of it.
        dashboardContainer.addArrangedSubview(projectsSection)
        startHereReplaces = [tasksRow, projectsSection]
        followUpsRow = tasksRow
        projectsSectionView = projectsSection
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
        contentStack.addArrangedSubview(tabRow)

        contentStack.addArrangedSubview(dashboardContainer)
        contentStack.addArrangedSubview(weeklyReviewSection)

        content.addSubview(contentStack)
        // R2-UX-10: held so it is active only while Weekly review shows. A
        // hidden view keeps its constraints (gotcha (15)), and once rendered
        // the review's rows hold about 920pt - so this tie made the whole
        // page that wide on Board and List too, and in the sidebar
        // layout the window grew when the sidebar came back.
        weeklyReviewWidthTie = weeklyReviewSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        let contentLeading = contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                                   constant: HelmMetrics.pageGutter)
        contentStackLeading = contentLeading
        NSLayoutConstraint.activate([
            contentLeading,
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -HelmMetrics.s5),
            dashboardContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tasksRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectsDetailContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            // Each panel fills its own column - without these a `HelmCard`
            // hugs its content and the two columns render ragged.
            taskSection.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            followUpSection.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            // Projects is a full-width section, not a column member - it
            // fills the whole page content width, matching `dashboardContainer`/
            // `statsRow`/`tasksRow` above it.
            projectsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            boardSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            failedReadCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            // The toolbar spans the page so its trailing-pinned Board/List
            // switch actually lands at the page's own trailing edge.
            tabRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // P9: the column is a real split-view sidebar - draggable,
        // collapsible and answering Toggle Sidebar - and the split's divider
        // is the hairline the page used to draw beside it.
        //
        // **The column sits outside the scroll view**, the same call
        // `SchedulesController` and `CredentialVaultController` make: it is
        // navigation, so it has to stay reachable, and its own "jump to
        // Follow-ups" row scrolls the content - which with the column inside
        // the document would scroll the column itself off the top.
        let split = HelmSplitPage(sidebarWidth: HelmMetrics.pageGutter + HelmPageSidebar.width + HelmMetrics.s4,
                                  minimum: HelmPageSidebar.width * 0.8,
                                  maximum: HelmPageSidebar.width * 1.6,
                                  surface: .pageGroundWithEdge)
        addChild(split)
        root.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // The bottom is an equality, not `<=` as the other two
        // `HelmPageSidebar` pages use: this column has a footer, and a footer
        // floating halfway up an otherwise empty column is not what a footer
        // is. The column's own content-height constraint is optional (499),
        // so this simply wins and the nav scrolls if it ever outgrows the
        // page - which is exactly what a captain with twenty projects needs.
        HelmSplitPage.pin(sidebar, in: split.sidebarPane,
                          insets: NSEdgeInsets(top: 24, left: HelmMetrics.pageGutter,
                                               bottom: HelmMetrics.pageGutter, right: HelmMetrics.s4))
        // The scroll fills the content pane, and `contentStack` carries the
        // page's own leading inset inside it - see `applyContentLeadingInset`.
        HelmSplitPage.pin(scroll, in: split.contentPane, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        splitPage = split
        split.onSidebarCollapseChanged = { [weak self] _ in self?.applyContentLeadingInset() }
        applyContentLeadingInset()
        NSLayoutConstraint.activate([
            // AGENTS.md gotcha #4: the document view is pinned to the *clip*
            // view, never the outer scroll view.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        taskListView.onToggleCompleted = { [weak self] task in
            self?.store.setTaskCompleted(id: task.id, completed: task.status != .completed)
            self?.render()
        }
        taskListView.onOpen = { [weak self] task in
            self?.presentTaskEditor(for: task)
        }
        taskListView.onDelete = { [weak self] task in
            self?.confirmDeleteTask(id: task.id)
        }
        taskListView.onPushDue = { [weak self] task, option in
            self?.pushDueDate(task, by: option)
        }
        taskListView.onStartFocus = { [weak self] task, minutes in
            self?.startFocus(on: task, minutes: minutes)
        }
        taskListView.onStopFocus = { [weak self] _ in
            self?.stopFocus()
        }

        // F7. The list's focus highlight and Weekly Review's tile both move
        // when the timer does, and `setFocusedTask` is a no-op unless the
        // *task* changed - so this fires once a second and reloads nothing
        // until there is something to reload.
        if let focusTimer {
            focusTimerToken = focusTimer.observe { [weak self] in self?.focusStateChanged() }
            taskListView.setFocusedTask(id: focusTimer.session?.taskID)
        }

        followUpListView.onEdit = { [weak self] item in
            self?.presentFollowUpEditor(for: item)
        }
        followUpListView.onToggleDone = { [weak self] item in
            self?.toggleFollowUpDone(id: item.id)
        }
        followUpListView.onSnooze = { [weak self] item, option in
            self?.snoozeFollowUp(item, option: option)
        }
        followUpListView.onDelete = { [weak self] item in
            self?.confirmDeleteFollowUp(id: item.id)
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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    private func scrollToTop() {
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
    /// other ways to start a task are the "+" on the My Tasks card header,
    /// which is *hidden in board mode*, and a column's own "+ Add task", which
    /// presets that column's status. In the mode this page opens in there is
    /// no plain "new task" at all, which is exactly the gap the captain asked
    /// for a primary button to fill.
    ///
    /// Built once and handed over on every read, never rebuilt per read - a
    /// fresh copy each time could not carry state (the property
    /// `DaylightDrillPageSlice4SelfTest` pins for Vault's own Refresh).
    var drillHeaderActions: [NSView] {
        store.gitSync == nil ? [newTaskButton] : [syncPill, newTaskButton]
    }

    /// `.primary` - the accent-filled pill. At most one per cluster, and this
    /// is the page's one primary action.
    private lazy var newTaskButton: HelmButton = {
        let button = HelmButton(title: "New task", variant: .primary, size: .small,
                                symbol: "plus", target: self, action: #selector(newTaskClicked))
        button.toolTip = "New Task (\u{2318}N)"
        return button
    }()

    /// The page's four numbers, from **one** counting pass (UI-18).
    ///
    /// The subtitle and the sidebar both read this, so they cannot disagree,
    /// and both follow the project filter - picking "Ideas" in the sidebar
    /// makes "11 open" become the number of open tasks in Ideas. The stat
    /// tiles that used to say the same thing a third time are gone (UI-16).
    struct Counts: Equatable {
        let open: Int
        let dueToday: Int
        let followUps: Int
        let overdue: Int
    }

    func counts(now: Date = Date()) -> Counts {
        let tasks = store.activeTasks.filter(matchesProjectFilter)
        let cal = Calendar.current
        let dueToday = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return cal.isDate(due, inSameDayAs: now)
        }.count
        let overdue = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < cal.startOfDay(for: now)
        }.count
        let followUps = store.followUps.filter { $0.status == .pending }.count
        return Counts(open: tasks.count, dueToday: dueToday, followUps: followUps, overdue: overdue)
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
        if showsStartHere { return "No tasks yet" }
        let c = counts()
        let parts = [
            "\(c.open) open",
            "\(c.dueToday) due today",
            "\(c.followUps) follow-up\(c.followUps == 1 ? "" : "s")",
            "\(c.overdue) overdue",
        ]
        let line = parts.joined(separator: " \u{00B7} ")
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

    private func buildTaskSection() -> NSView {
        let headerRow = sectionHeaderRow(
            iconSymbol: "checklist", tint: .accent, label: tasksHeader, countBadge: tasksCountBadge,
            addAction: #selector(newTaskClicked), addTooltip: "New Task (\u{2318}N)"
        )

        taskListScroll.documentView = taskListView.tableView
        taskListScroll.hasVerticalScroller = true
        taskListScroll.hasHorizontalScroller = false
        taskListScroll.borderType = .noBorder
        taskListScroll.drawsBackground = false
        // A nested list owns its whole frame; an automatic top inset (the
        // window's own chrome) pushed its rows down and sliced the last one.
        taskListScroll.automaticallyAdjustsContentInsets = false
        taskListScroll.contentInsets = NSEdgeInsetsZero
        taskListScroll.translatesAutoresizingMaskIntoConstraints = false
        // U15: a stored constraint, re-derived from the live content on
        // every render - see `sharedTaskFollowUpBodyHeight()`.
        let taskHeight = taskListScroll.heightAnchor
            .constraint(equalToConstant: Self.taskFollowUpPanelBodyHeight)
        taskHeight.isActive = true
        taskListHeightConstraint = taskHeight

        taskPanel.setHeader(headerRow)
        taskPanel.setBody(panelBody(taskListScroll, hint: taskOverflowHint, table: taskListView.tableView))
        taskPanel.translatesAutoresizingMaskIntoConstraints = false
        return taskPanel
    }

    private func buildFollowUpSection() -> NSView {
        let headerRow = sectionHeaderRow(
            iconSymbol: "bell", tint: .warn, label: followUpsHeader, countBadge: followUpsCountBadge,
            addAction: #selector(newFollowUpClicked), addTooltip: "New Follow-up (\u{2318}\u{21e7}F)"
        )

        followUpScroll.documentView = followUpListView.tableView
        followUpScroll.hasVerticalScroller = true
        followUpScroll.hasHorizontalScroller = false
        followUpScroll.borderType = .noBorder
        followUpScroll.drawsBackground = false
        // A nested list owns its whole frame; an automatic top inset (the
        // window's own chrome) pushed its rows down and sliced the last one.
        followUpScroll.automaticallyAdjustsContentInsets = false
        followUpScroll.contentInsets = NSEdgeInsetsZero
        followUpScroll.translatesAutoresizingMaskIntoConstraints = false
        let followUpHeight = followUpScroll.heightAnchor
            .constraint(equalToConstant: Self.taskFollowUpPanelBodyHeight)
        followUpHeight.isActive = true
        followUpHeightConstraint = followUpHeight

        followUpPanel.setHeader(headerRow)
        followUpPanel.setBody(panelBody(followUpScroll, hint: followUpOverflowHint, table: followUpListView.tableView))
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
    /// `HelmCard` `taskPanel`/`followUpPanel` already use
    /// (fm/grandline-shift-projects-panel-background) - previously this
    /// section sat directly on the page's plain background with no
    /// enclosing card, reading as a different kind of section next to My
    /// Tasks/Follow-ups. `projectsDetailContainer` (the full-page project
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

        // Just the panel now. The board renders Projects as its own
        // full-width section below the Today/Follow-ups row (per the
        // captain's own correction of §7's literal two-column reading - see
        // `loadView`'s board comment), and the project *detail* takes the
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
        case .dueToday: parts.append("due today")
        case .overdue: parts.append("overdue")
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
        tasksView = view
        viewTabs.select(view.rawValue)
        render()
        onModuleTabChanged?()
    }

    @objc private func sortChanged() {
        let index = sortPopup.indexOfSelectedItem
        guard ShiftTaskSort.allCases.indices.contains(index) else { return }
        taskSort = ShiftTaskSort.allCases[index]
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

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.doneColumnLookbackDays, to: Date())
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

    /// The sidebar's Workspace slice.
    ///
    /// **A completed task is never "due today" or "overdue".** Both slices ask
    /// about work still outstanding, so they exclude anything finished or
    /// cancelled - which means the board's Done column empties under either,
    /// correctly: a task finished last week is not late. The predicates are
    /// deliberately the same ones `render` counts the stat tiles with, so a
    /// sidebar count, a tile and the board can never disagree.
    private func matchesScope(_ task: ShiftTask) -> Bool {
        switch taskScope {
        case .all:
            return true
        case .dueToday, .overdue:
            guard task.status != .completed, task.status != .cancelled,
                  let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            let cal = Calendar.current
            return taskScope == .dueToday
                ? cal.isDate(due, inSameDayAs: Date())
                : due < cal.startOfDay(for: Date())
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
                                                     to: Date()) else { return false }
            return updated >= cutoff
        }
    }

    /// Both filters at once - every surface that shows tasks runs through this
    /// one predicate rather than remembering to apply two.
    private func matchesFilters(_ task: ShiftTask) -> Bool {
        matchesProjectFilter(task) && matchesScope(task)
    }

    // MARK: The sidebar

    static func projectSignature(_ projects: [ShiftProject]) -> String {
        projects.map { "\($0.id)\u{1}\($0.name)" }.joined(separator: "\u{2}")
    }

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

    /// The list's own ordering, extracted so the board's two in-flight
    /// columns and the flat list cannot disagree about what "next" means.
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
    /// context menu or the flat list's row menu.
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

    /// Done to pending and back, from the flat list's check, the Follow-ups
    /// table's check and that table's menu alike.
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
    /// `setFocusedTask` returns immediately unless the focused *task*
    /// changed, and Weekly Review's own tile is only re-rendered while that
    /// is the view actually on screen (AGENTS.md's "an observer must not
    /// rebuild a page that is not visible", for the same reason).
    private func focusStateChanged() {
        guard isViewLoaded else { return }
        taskListView.setFocusedTask(id: focusTimer?.session?.taskID)
        if topLevelView == .weeklyReview, !view.isHiddenOrHasHiddenAncestor {
            renderFocusTile()
        }
    }

    // MARK: Weekly Review

    /// The page's toolbar (UI-15): the one view switcher on the left, the
    /// sort and the Done window on the right. The right-hand pair hides on
    /// Review, which has no lanes to sort.
    private func buildTabRow() -> NSView {
        viewTabs.onSelect = { [weak self] id in
            guard let self else { return }
            if id == Self.reviewViewID {
                self.switchTopLevelView(.weeklyReview)
            } else if let view = ShiftTasksView(rawValue: id) {
                if self.topLevelView != .dashboard { self.switchTopLevelView(.dashboard) }
                self.switchTasksView(view)
            }
        }
        viewTabs.translatesAutoresizingMaskIntoConstraints = false

        sortPopup.removeAllItems()
        for order in ShiftTaskSort.allCases { sortPopup.addItem(withTitle: order.title) }
        sortPopup.selectItem(at: ShiftTaskSort.allCases.firstIndex(of: taskSort) ?? 0)
        sortPopup.controlSize = .small
        sortPopup.toolTip = "Sort the lanes and the list"
        sortPopup.setAccessibilityLabel("Sort tasks by")
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortPopup.setContentHuggingPriority(.required, for: .horizontal)

        doneWindowNote.font = HelmType.chip()
        doneWindowNote.toolTip = "The Done lane shows tasks completed in the last \(Self.doneColumnLookbackDays) days. "
            + "Older ones stay on their project's own page."
        doneWindowNote.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [viewTabs, spacer, sortPopup, doneWindowNote])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s4
        // AGENTS.md gotcha (10): without `.fill` a horizontal stack honours no
        // hugging priority at all and the spacer never absorbs the slack.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        topToolbar = row
        return row
    }

    /// Held so `switchTopLevelView` can size it.
    private var topToolbar: NSStackView?
    /// The review's width tie to the page, active only while it shows.
    private var weeklyReviewWidthTie: NSLayoutConstraint?

    func switchTopLevelView(_ view: ShiftTopLevelView) {
        topLevelView = view
        // Tied before the review shows, released once it is hidden - and
        // before `onModuleTabChanged` below, which is where the sidebar
        // layout settles the column's floor for the new tab.
        if view == .weeklyReview { weeklyReviewWidthTie?.isActive = true }
        // Keeps the active pill right when the view was changed from somewhere
        // other than a pill click - the Shift menu, the search palette,
        // `showWeeklyReview()`/`showDashboard()`. A no-op on a real pill click,
        // which has already moved it.
        viewTabs.select(view == .weeklyReview ? Self.reviewViewID : tasksView.rawValue)
        dashboardContainer.isHidden = view != .dashboard
        weeklyReviewContainer.isHidden = view != .weeklyReview
        if view != .weeklyReview { weeklyReviewWidthTie?.isActive = false }
        sortPopup.isHidden = view != .dashboard
        doneWindowNote.isHidden = view != .dashboard
        // The column's rows are all about the task board, so it goes with it.
        // Both halves are needed: hiding the view alone would leave its gap
        // behind, since an ordinary hidden `NSView` keeps its constraints.
        // P9: the split collapses the column, which takes its gap and its
        // hairline with it, and restores the captain's own choice on return.
        splitPage?.pageForcesCollapse = drawsSidebarLayout || view != .dashboard
        applyContentLeadingInset()
        if drawsSidebarLayout { workspaceFilterRow.isHidden = view != .dashboard || isProjectDetailFullPage }
        if view == .weeklyReview { renderWeeklyReview() }
        applyTheme()
        onModuleTabChanged?()
    }

    /// The Shift menu / search palette's entry point into Weekly Review -
    /// selects the tab exactly like clicking it would.
    func showWeeklyReview() { switchTopLevelView(.weeklyReview) }

    /// Back to the daily dashboard - used after navigating here to open a
    /// task/follow-up/project found via search or the menu bar popover.
    func showDashboard() { switchTopLevelView(.dashboard) }

    private func buildWeeklyReviewSection() -> NSView {
        reviewGreeting.font = HelmType.pageTitle(.display)
        reviewSubtitle.font = HelmType.body()
        let textStack = NSStackView(views: [reviewGreeting, reviewSubtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = HelmMetrics.s1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        reviewStatsCard.setBody(reviewStats, insets: HelmCard.contentInsets)
        reviewStatsCard.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = sectionHeaderRow(iconSymbol: "arrow.uturn.backward", tint: .warn, label: reviewPushedBackHeader)
        reviewPushedBackHeaderRow = headerRow

        reviewPushedBackStack.orientation = .vertical
        reviewPushedBackStack.alignment = .leading
        reviewPushedBackStack.spacing = 0
        reviewPushedBackStack.translatesAutoresizingMaskIntoConstraints = false
        reviewPushedBackPanel.setHeader(headerRow)
        reviewPushedBackPanel.setBody(reviewPushedBackStack)
        reviewPushedBackPanel.translatesAutoresizingMaskIntoConstraints = false

        weeklyReviewContainer.orientation = .vertical
        weeklyReviewContainer.alignment = .leading
        weeklyReviewContainer.spacing = HelmMetrics.s4
        weeklyReviewContainer.translatesAutoresizingMaskIntoConstraints = false
        weeklyReviewContainer.isHidden = true
        weeklyReviewContainer.addArrangedSubview(textStack)
        weeklyReviewContainer.addArrangedSubview(reviewStatsCard)
        weeklyReviewContainer.addArrangedSubview(buildFocusPanel())
        weeklyReviewContainer.addArrangedSubview(reviewPushedBackPanel)
        textStack.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewStatsCard.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewFocusPanel.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewPushedBackPanel.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
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
        let today = calendar.startOfDay(for: Date())
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

        reviewStats.configure([
            .count(summary.completedCount, caption: "completed this week"),
            .count(summary.pushedBack.count, caption: "pushed back 2+ times", tintWhenNonZero: .warn),
            .count(summary.upcomingCount, caption: "coming up next week"),
        ], theme: theme)

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
        if drawsSidebarLayout { renderWorkspaceReview(summary) }
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

        let tasks = store.activeTasks
        let followUps = store.followUps
        let pendingFollowUps = followUps.filter { $0.status == .pending }

        // The Projects group is rebuilt only when the project set genuinely
        // changed - a rebuild tears every row down, and doing that on every
        // render would churn the column (and drop its hover state) on every
        // unrelated edit elsewhere on the page.
        if Self.projectSignature(store.projects) != sidebarProjectSignature {
            rebuildSidebarSections(projects: store.projects)
        }
        // A filter pinned to a project that has since gone away would hide
        // every task with no way to tell why.
        if let filter = projectFilter, !store.projects.contains(where: { $0.id == filter }) {
            projectFilter = nil
        }
        // UI-18: the same counting pass the subtitle reads, following the
        // project filter.
        let c = counts()
        sidebar.setCounts([
            ShiftTaskScope.all.rawValue: c.open,
            ShiftTaskScope.dueToday.rawValue: c.dueToday,
            ShiftTaskScope.overdue.rawValue: c.overdue,
            Self.followUpsRowID: c.followUps,
        ])
        sidebar.select(taskScope.rawValue)
        sidebar.select(projectFilter.map(Self.projectRowID), inGroup: Self.projectGroup)

        let sortedTasks = tasks.sorted(by: taskSort.areInOrder)
        taskListView.setTasks(sortedTasks.filter(matchesFilters), projects: store.projects)
        tasksHeader.stringValue = "My Tasks"
        tasksCountBadge.stringValue = "\(tasks.count)"

        // The board and the flat list are two presentations of the same
        // filtered set, so both are refreshed on every render regardless of
        // which one is showing - a stale board behind a view toggle is the
        // exact "switch away and back to find yesterday's data" shape this
        // page has been corrected for before.
        boardView.setTasks(boardTasks(), projects: store.projects, theme: theme)
        boardView.setLoading(false)
        let filter = filterDescription()
        boardView.setFilterDescription(filter.text, clearTitle: filter.clearTitle)
        applyTasksViewVisibility()

        followUpListView.setItems(followUps)
        followUpsHeader.stringValue = "Follow-ups"
        followUpsCountBadge.stringValue = "\(pendingFollowUps.count) pending"

        // U15: both lists have their live contents now, so this is the one
        // place the shared panel height can be re-derived from them.
        updateTaskFollowUpPanelHeights()

        renderProjectsSection()
        if topLevelView == .weeklyReview { renderWeeklyReview() }
        if drawsSidebarLayout { renderWorkspaceChrome() }

        applyTheme()
    }

    /// Whether a project's detail is the whole page right now - `statsRow`/
    /// `taskPanel`/`followUpPanel` and the Projects section's own panel
    /// (header + grid) all hide entirely (not just scrolled past) while
    /// true, matching how `switchTopLevelView` already hides
    /// `dashboardContainer` in favor of `weeklyReviewContainer`
    /// (fm/cockpit-fix-shift-project-detail-fullpage). The top-level
    /// greeting header and the My Tasks/Weekly Review tab row are
    /// deliberately left alone - they're app-level navigation chrome, not
    /// dashboard content, exactly as Weekly Review's own toggle already
    /// treats them.
    private func applyProjectDetailFullPage(_ isDetail: Bool) {
        taskPanel.isHidden = isDetail
        followUpPanel.isHidden = isDetail
        projectsPanel.isHidden = isDetail
        isProjectDetailFullPage = isDetail
        applyTasksViewVisibility()
    }

    /// Whether the project detail currently owns the whole page - the board
    /// and the task panel both have to stay hidden while it does, whichever
    /// way the Board/List toggle happens to be set.
    private var isProjectDetailFullPage = false

    /// Board mode hides the flat task panel and shows the board; list mode is
    /// this page's original layout exactly. `taskPanel` is a *hidden arranged
    /// subview of an `NSStackView`*, which AppKit drops out of layout
    /// entirely - so Follow-ups fills the row on its own in board mode
    /// instead of sitting beside a gap.
    private func applyTasksViewVisibility() {
        // UI-31: a failed read hides every view of the task list - empty
        // lanes under a failure would read as "nothing to do".
        applyFailedReadState()
        let failed = store.isInFailedLoadState && !isProjectDetailFullPage
        let boardShowing = !isProjectDetailFullPage && !failed && tasksView == .board
        boardSection.isHidden = !boardShowing
        let hideTasks = isProjectDetailFullPage || failed || boardShowing
        taskPanel.isHidden = hideTasks
        // The *column wrapper*, not just the panel inside it. `tasksRow` is
        // `.fillEqually`, and a visible-but-empty column still claims its
        // half of the row - which left Follow-ups rendering at half width
        // against a blank left half in board mode (caught in a real render,
        // not by reading the constraints).
        tasksLeftColumn?.isHidden = hideTasks
        if drawsSidebarLayout {
            // The table is the List tab; the floating bar's My Tasks card
            // and its column are not drawn, so Follow-ups spans the row.
            taskPanel.isHidden = true
            tasksLeftColumn?.isHidden = true
            tasksTable.card.isHidden = isProjectDetailFullPage || failed || tasksView != .list
            workspaceFilterRow.isHidden = isProjectDetailFullPage || topLevelView != .dashboard
            // R2-UX-07: an empty Tasks page was three empty states (the
            // board's lanes, Follow-ups and Projects) under a filter row of
            // zeros. With nothing at all it is one invitation instead.
            let startHere = showsStartHere && !failed && !isProjectDetailFullPage
            startHereState.isHidden = !startHere
            if startHere {
                for view in [boardSection, tasksTable.card, workspaceFilterRow] + startHereReplaces {
                    view.isHidden = true
                }
            } else {
                for view in startHereReplaces { view.isHidden = false }
                // R4-UI-09: on Board, Follow-ups is a lane on the board while
                // four lanes fit, and Projects is the filter row's pop-up. The
                // List tab keeps both under its table.
                let board = tasksView == .board && !isProjectDetailFullPage && !failed
                let laneOnBoard = board && boardFitsFollowUpLane
                boardView.trailingLaneShown = laneOnBoard
                followUpsRow?.isHidden = laneOnBoard
                projectsSectionView?.isHidden = board
                followUpsJumpWanted = !laneOnBoard
                fitFilterRow()
            }
        }
    }

    /// R4-UI-09: below this, four lanes are each under the ~200pt a card's
    /// title and its project, due date and priority need on one line, so
    /// Follow-ups goes back under the board rather than squeezing every lane.
    static let followUpLaneMinimumBoardWidth: CGFloat = 4 * 200 + 3 * HelmMetrics.s3

    /// The page's content column changed width: decide again whether
    /// Follow-ups fits on the board and whether the filter row collapses.
    ///
    /// From the column's own frame change, not `viewDidLayout`: this page's
    /// view lays out before the scroll document under it does, so its
    /// `viewDidLayout` read the width the column had *before* a resize -
    /// measured in the tour lab, 1512 to 1100 left Follow-ups on a 707pt board.
    @objc private func contentColumnDidResize() {
        guard drawsSidebarLayout, contentStack.bounds.width > 0 else { return }
        let fits = contentStack.bounds.width >= Self.followUpLaneMinimumBoardWidth
        if fits != boardFitsFollowUpLane {
            boardFitsFollowUpLane = fits
            applyTasksViewVisibility()
        }
        fitFilterRow()
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
    var debugFollowUpsRowHidden: Bool { followUpsRow?.isHidden ?? true }
    var debugProjectsSectionHidden: Bool { projectsSectionView?.isHidden ?? true }
    var debugFollowUpsJumpHidden: Bool { followUpsJump.isHidden }
    var debugFilterRowCollapsed: Bool { !filterMenuButton.isHidden }
    var debugFilterRow: NSStackView { workspaceFilterRow }
    var debugFilterMenuTitles: [String] { filterMenu().items.map(\.title) }
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

    /// The `tasksRow` column holding the flat task panel - see
    /// `applyTasksViewVisibility`.
    private var tasksLeftColumn: NSStackView?

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
    private let detailStartDateField = HelmTextField(placeholder: "YYYY-MM-DD")
    private let detailDueDateField = HelmTextField(placeholder: "YYYY-MM-DD")
    private let detailSaveButton = HelmButton(title: "Save", variant: .primary, target: nil, action: nil)

    private let detailTasksPanel = HelmCard()
    private let detailTasksHeader = NSTextField(labelWithString: "Tasks")
    private let detailTasksCountBadge = NSTextField(labelWithString: "")
    private let detailTaskListView = ShiftProjectTaskListView()
    private let detailTaskListScroll = NSScrollView()

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
    /// serif title (matching My Tasks' own greeting treatment), a read-only
    /// status pill + start/due date meta line, and the description as a
    /// wrapping paragraph - all presentation, no input fields. Editing lives
    /// entirely in the "Details" panel below, so there is exactly one place
    /// that changes a project's fields, not a header control and a form both
    /// claiming to own status.
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
    /// a project's detail, never as flat rows in the main My Tasks list
    /// above (see ShiftModels.swift's header for why that boundary matters).
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
    /// same New Task sheet the My Tasks header's "+" uses, pre-selecting
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
        store.updateProject(project)
        Toast.show(in: view, message: "Project saved")
        render()
    }

    // MARK: Creation / editing (phase 2)

    /// The Shift menu's "New Task…" (⌘N) - also reachable from the My Tasks
    /// header's "+" button.
    func presentNewTaskEditor() { presentTaskEditor(for: nil) }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - also reachable from the
    /// Follow-ups header's "+" button.
    func presentNewFollowUpEditor() { presentFollowUpEditor(for: nil) }

    /// The Shift menu's "New Project…" - also reachable from the Projects
    /// header's "+" button (cockpit-fix-shift-new-project).
    func presentNewProjectEditor() { presentProjectEditor() }

    @objc private func newTaskClicked() { presentTaskEditor(for: nil) }
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
    /// segmented control a captain clicks, so a tour renders what a click
    /// would have shown rather than what a private setter would.
    func debugShowView(_ id: String) {
        if id == "review" {
            viewTabs.debugClickTab(id: Self.reviewViewID)
        } else {
            viewTabs.debugClickTab(id: id)
        }
    }

    /// Where the three board panels and the project detail actually landed,
    /// read from real frames after a real layout pass - so a check of §7's
    /// "Today left, Follow-ups + Projects right" cannot pass by re-deriving
    /// the same constraint math the layout used.
    ///
    /// A hidden panel reports `nil` rather than a stale frame, which is what
    /// lets one probe cover both the board and the full-page detail state.
    struct BoardGeometry {
        let tasks: NSRect?
        let followUps: NSRect?
        let projects: NSRect?
        let detail: NSRect?
        let contentWidth: CGFloat
    }

    func debugBoardGeometry() -> BoardGeometry {
        func frame(_ view: NSView) -> NSRect? {
            view.isHidden ? nil : view.convert(view.bounds, to: view.window?.contentView ?? view)
        }
        return BoardGeometry(tasks: frame(taskPanel),
                             followUps: frame(followUpPanel),
                             projects: frame(projectsPanel),
                             detail: projectsDetailContainer.isHidden
                                 ? nil
                                 : projectsDetailContainer.convert(projectsDetailContainer.bounds,
                                                                   to: projectsDetailContainer.window?.contentView
                                                                       ?? projectsDetailContainer),
                             contentWidth: contentStack.bounds.width)
    }

    // fm/grandline-tasks-kanban-devops-split: the board's own probe surface.
    // Structure rather than appearance, deliberately - a column holding the
    // wrong cards, a toggle that hides nothing, and a card that never
    // receives a mouse event all render plausibly.

    // The page's nav column (fm/grand-line-tasks-page-redesign). Structure
    // and behaviour, never appearance: a column that renders perfectly and
    // filters nothing looks exactly right.

    var debugSidebar: HelmPageSidebar { sidebar }
    var debugSidebarIsVisible: Bool { !(splitPage?.isSidebarCollapsed ?? true) && !sidebar.isHiddenOrHasHiddenAncestor }

    /// Whether the content currently starts after the column or at the page
    /// edge - the half a plain `isHidden` check cannot see.
    var debugContentStartsAfterSidebar: Bool { !(splitPage?.isSidebarCollapsed ?? true) }

    /// The scope the page is filtering by right now.
    var debugTaskScope: String { taskScope.rawValue }

    /// Drives the real column's own handler, so a test cannot pass against a
    /// row wired to nothing.
    func debugSelectSidebarRow(_ id: String) { sidebar.debugClickRow(id: id) }

    /// The sidebar row id for a project, so a check can drive the real row
    /// rather than reaching into `projectFilter` directly.
    static func debugProjectRowID(_ projectID: String) -> String { projectRowID(projectID) }
    static var debugProjectGroup: String { projectGroup }
    var debugProjectFilter: String? { projectFilter }

    /// The task ids each board column is showing, after every filter.
    func debugVisibleTaskIDs(_ column: ShiftBoardColumn) -> [String] {
        boardView.debugColumn(column)?.debugCardViews.map(\.taskID) ?? []
    }

    /// UI-16: the page draws no stat tiles; the counts live in the drill
    /// subtitle and the sidebar. Kept as a probe so a suite can assert none
    /// came back.
    var debugStatTileCount: Int {
        func walk(_ v: NSView) -> Int { (v is HelmStatTile ? 1 : 0) + v.subviews.reduce(0) { $0 + walk($1) } }
        return walk(dashboardContainer)
    }

    var debugBoardView: ShiftBoardView? { boardView }

    /// UI-17: the chip row is gone; nothing on the page is a
    /// `ShiftProjectFilterBar` any more.
    var debugHasProjectChipRow: Bool {
        func walk(_ v: NSView) -> Bool { v is ShiftProjectFilterBar || v.subviews.contains(where: walk) }
        return walk(view)
    }
    var debugViewTabs: HelmSegmentedTabs { viewTabs }
    var debugSortPopup: HelmPopUpButton { sortPopup }
    var debugBoardIsVisible: Bool { !boardSection.isHidden }
    var debugFailedReadIsVisible: Bool { !failedReadCard.isHidden }
    var debugFailedReadSubline: String { failedReadHeader.sublineLabel.stringValue }
    var debugFailedReadTitle: String { failedReadHeader.titleLabel.stringValue }
    var debugTaskPanelIsVisible: Bool { !taskPanel.isHidden }
    /// REL-01: whether the project detail is showing.
    var debugProjectDetailIsVisible: Bool { !projectsDetailContainer.isHidden }
    var debugTasksCountBadge: String { tasksCountBadge.stringValue }

    /// Drives the real toggle's own handler, so a test cannot pass against a
    /// pill wired to nothing.
    ///
    /// F5 routed this through `HelmSegmentedTabs.debugClickTab` rather than
    /// calling `switchTasksView` directly: the previous version proved the
    /// page's switch function worked and said nothing about whether the pill
    /// reaches it, which is the half that breaks when a third pill is added.
    func debugSelectTasksView(_ id: String) { viewTabs.debugClickTab(id: id) }

    /// The page's one render pass, for a test that has just mutated the store
    /// behind its back.
    func debugRender() { render() }

    /// UXP-18: the two list panels' hints as drawn.
    var debugPanelOverflowHints: (tasks: String, followUps: String) {
        (taskOverflowHint.debugText, followUpOverflowHint.debugText)
    }
    var debugBoardColumns: [ShiftBoardColumnView] { boardView.debugColumnViews }

    /// UXP-02: the project cards the last render built.
    var debugProjectCards: [ShiftProjectCardView] { projectCards }

    /// UXP-03: the leading edges, in window coordinates, of the Weekly
    /// Review's header and of the view switcher, after a real layout pass.
    var debugContentLeadingInWindow: (reviewHeader: CGFloat, tabs: CGFloat) {
        view.layoutSubtreeIfNeeded()
        // The alignment rect, not the frame: a label's frame carries 2pt of
        // cell padding outside the text, and the stack aligns the rect.
        func leading(_ v: NSView) -> CGFloat {
            guard let parent = v.superview else { return 0 }
            return parent.convert(v.alignmentRect(forFrame: v.frame), to: nil).minX
        }
        return (leading(reviewGreeting), leading(viewTabs))
    }
    func debugToggleSidebar() { splitPage?.toggleSidebar(nil) }

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

        tasksHeader.textColor = ink
        followUpsHeader.textColor = ink
        projectsHeader.textColor = ink
        detailTasksHeader.textColor = ink

        for header in sectionHeaders { header.applyTheme(theme) }
        taskPanel.applyTheme(theme)
        followUpPanel.applyTheme(theme)
        projectsPanel.applyTheme(theme)
        tasksCountBadge.textColor = muted
        followUpsCountBadge.textColor = muted
        projectsCountBadge.textColor = muted
        taskListView.applyTheme(theme)
        followUpListView.applyTheme(theme)
        taskOverflowHint.applyTheme(theme)
        followUpOverflowHint.applyTheme(theme)
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

        viewTabs.applyTheme(theme)
        doneWindowNote.textColor = muted
        sidebar.applyTheme(theme)
        boardView.applyTheme(theme)
        followUpLane.applyTheme(theme)

        reviewGreeting.textColor = ink
        reviewSubtitle.textColor = muted
        reviewPushedBackHeader.textColor = ink
        reviewStats.applyTheme(theme)
        reviewStatsCard.applyTheme(theme)
        reviewPushedBackList.applyTheme(theme)
        reviewPushedBackPanel.applyTheme(theme)
        reviewAgendaPanel.applyTheme(theme)
        reviewFocusPanel.applyTheme(theme)
        reviewFocusHeader.textColor = ink
        reviewFocusHeadline.textColor = ink
        reviewFocusCaption.textColor = muted
        reviewFocusChart.applyTheme(theme)
        if drawsSidebarLayout {
            scopeFilter.applyTheme(theme)
            projectPopup.contentTintColor = ink
            tasksTable.applyTheme(theme)
            followUpsTable.applyTheme(theme)
            for card in reviewCards { card.applyTheme(theme) }
        }
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

// MARK: - Tasks' tabs in the sidebar layout

extension ShiftController: ModuleTabHosting {
    var moduleTabNames: [String] { ["Board", "List", "Weekly review"] }

    var selectedModuleTabName: String {
        guard topLevelView == .dashboard else { return "Weekly review" }
        switch tasksView {
        case .board: return "Board"
        case .list: return "List"
        }
    }

    /// Through the view switcher's own handler, so a toolbar click and a click
    /// on the page's pill are one path.
    func selectModuleTab(named name: String) {
        switch name {
        case "Weekly review": viewTabs.onSelect?(Self.reviewViewID)
        case "List": viewTabs.onSelect?(ShiftTasksView.list.rawValue)
        default: viewTabs.onSelect?(ShiftTasksView.board.rawValue)
        }
    }

    /// Only the switcher: the sort and the Done window beside it stay, since
    /// the toolbar does not carry them.
    func setModuleTabControlHidden(_ hidden: Bool) { viewTabs.isHidden = hidden }
}

// MARK: - The sidebar layout (stage 7)

// The prototype's Tasks: Board, List and Weekly review as the
// toolbar's tabs, New task at the toolbar's far right, and no second column
// inside the page. What that column held has a place on the page itself -
// the filter row under the header carries its Workspace and Smart views
// (with their counts), its Follow-ups jump and its Projects filter, beside
// the sort and the Done window; Settings is the sidebar's own row and
// Shortcuts is the toolbar's Search (⌘K). Every task view, card and action
// is the page's own: the board is the same board with the prototype's lanes
// and cards, the List tab is the same tasks as one table, and Follow-ups and
// Projects stay where they always were, under the view.

extension ShiftController: SidebarLayoutAdopting, WorkspacePrimaryActionProviding {

    func adoptSidebarLayout() {
        guard !drawsSidebarLayout else { return }
        _ = view
        drawsSidebarLayout = true
        splitPage?.pageForcesCollapse = true
        applyContentLeadingInset()
        topToolbar?.isHidden = true
        buildWorkspaceFilterRow()
        contentStack.insertArrangedSubview(workspaceFilterRow, at: 0)
        workspaceFilterRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        boardView.adoptWorkspaceStyle()
        boardView.setTrailingLane(followUpLane)
        contentStack.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentColumnDidResize),
                                               name: NSView.frameDidChangeNotification, object: contentStack)
        followUpLane.onOpen = { [weak self] id in
            guard let self, let item = self.store.followUps.first(where: { $0.id == id }) else { return }
            self.presentFollowUpEditor(for: item)
        }
        followUpLane.onAdd = { [weak self] in self?.newFollowUpClicked() }
        followUpLane.menuFor = { [weak self] id in self?.followUpLaneMenu(id: id) }
        if let index = dashboardContainer.arrangedSubviews.firstIndex(of: boardSection) {
            dashboardContainer.insertArrangedSubview(tasksTable.card, at: index + 1)
        } else {
            dashboardContainer.addArrangedSubview(tasksTable.card)
        }
        tasksTable.card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        // Takes over the Follow-ups card's body; the flat list leaves it.
        _ = followUpsTable
        adoptWorkspaceWeeklyReview()
        // Centred in the content pane like every page-level empty state
        // (UXP-13), not resting at the top of the scroll document.
        if let pane = splitPage?.contentPane {
            startHereState.placeAsPageEmptyState(in: pane)
        } else {
            dashboardContainer.insertArrangedSubview(startHereState, at: 0)
            startHereState.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        startHereState.isHidden = true
        render()
    }

    // MARK: R2-UX-07 - an empty Tasks page that invites

    /// Nothing open, nothing completed lately, no follow-up and no project:
    /// a store a captain has never used.
    private var showsStartHere: Bool {
        drawsSidebarLayout && !store.isInFailedLoadState && store.activeTasks.isEmpty && store.followUps.isEmpty
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
    var workspacePrimaryAction: NSView? { drawsSidebarLayout ? newTaskButton : nil }

    private func buildWorkspaceFilterRow() {
        projectPopup.controlSize = .small
        projectPopup.target = self
        projectPopup.action = #selector(projectPopupChanged)
        projectPopup.toolTip = "Show one project's tasks"
        projectPopup.setAccessibilityLabel("Project")
        projectPopup.setContentHuggingPriority(.required, for: .horizontal)
        followUpsJump.setContentHuggingPriority(.required, for: .horizontal)
        // The sort and the Done window move here from the tab row the
        // toolbar's tabs replaced.
        for view in [sortPopup, doneWindowNote] as [NSView] {
            view.removeFromSuperview()
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let spacerWidth = spacer.widthAnchor.constraint(equalToConstant: 0)
        spacerWidth.priority = .defaultLow
        spacerWidth.isActive = true
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // R4-UI-08: the scope tabs sit at their own width, and the spacer -
        // not the tabs - takes the row's slack (gotcha (10)). Both were at
        // 250 and AppKit gave the slack to the tabs, measured at 1512
        // stretching them from 487pt to 836pt of mostly empty strip. A real
        // `width == 0` preference one step above the spacer's, since the tabs
        // are a stack-backed view and a hugging priority is a no-op on one
        // (gotcha (12)).
        let tabsNarrow = scopeFilter.widthAnchor.constraint(equalToConstant: 0)
        tabsNarrow.priority = HelmDaylightPriority.columnHug
        tabsNarrow.isActive = true
        filterMenuButton.toolTip = "Show one project's tasks, or change the sort"
        filterMenuButton.setContentHuggingPriority(.required, for: .horizontal)
        filterMenuButton.isHidden = true
        for view in [scopeFilter, followUpsJump, projectPopup, filterMenuButton, spacer, sortPopup, doneWindowNote] as [NSView] {
            workspaceFilterRow.addArrangedSubview(view)
        }
        workspaceFilterRow.orientation = .horizontal
        workspaceFilterRow.alignment = .centerY
        workspaceFilterRow.spacing = HelmMetrics.s3
        // Gotcha (10): `.fill`, so the spacer and not a control takes the slack.
        workspaceFilterRow.distribution = .fill
        workspaceFilterRow.translatesAutoresizingMaskIntoConstraints = false
        workspaceFilterRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The filter row's counts and selection, the project list, and the
    /// List tab's rows - from the same pass `render` just made.
    fileprivate func renderWorkspaceChrome() {
        let c = counts()
        scopeFilter.setTitle(WorkspaceToolbar.tabLabel(ShiftTaskScope.all.title, count: c.open),
                             forID: ShiftTaskScope.all.rawValue)
        scopeFilter.setTitle(WorkspaceToolbar.tabLabel(ShiftTaskScope.dueToday.title, count: c.dueToday),
                             forID: ShiftTaskScope.dueToday.rawValue)
        scopeFilter.setTitle(WorkspaceToolbar.tabLabel(ShiftTaskScope.overdue.title, count: c.overdue),
                             forID: ShiftTaskScope.overdue.rawValue)
        scopeFilter.select(taskScope.rawValue)
        followUpsJump.title = c.followUps > 0 ? "Follow-ups \u{2002}\(c.followUps)" : "Follow-ups"
        followUpsJump.setAccessibilityLabel(c.followUps > 0 ? "Follow-ups, \(c.followUps) pending" : "Follow-ups")
        let signature = Self.projectSignature(store.projects)
        if signature != projectPopupSignature {
            projectPopupSignature = signature
            projectPopup.removeAllItems()
            projectPopup.addItem(withTitle: "All projects")
            for project in store.projects {
                projectPopup.addItem(withTitle: project.name.isEmpty ? "Untitled project" : project.name)
                projectPopup.lastItem?.representedObject = project.id
                projectPopup.lastItem?.image = Self.projectDot(ShiftProjectPalette.tint(forProjectID: project.id),
                                                              theme: theme)
            }
        }
        let selected = projectFilter.flatMap { id in store.projects.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        projectPopup.selectItem(at: selected)
        doneWindowNote.isHidden = tasksView != .board || filterRowCollapsed
        refreshFilterMenuTitle()
        let projectsByID = Dictionary(store.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        followUpLane.setFollowUps(followUpLaneItems(), projects: projectsByID, theme: theme)
        tasksTable.setRows(taskTableRows())
        followUpsTable.setRows(followUpTableRows())
    }

    /// R4-UI-08: at 960pt the filter row ran past the page's right edge and
    /// cut "Due date" in half with nothing to say there was more. When the
    /// row's controls at their own widths do not fit, the project and sort
    /// pop-ups collapse into one Filter button, and the Follow-ups jump and
    /// the Done window's note move into its menu. Measured from the expanded controls' fitting
    /// widths whichever form shows, so it cannot flip back and forth.
    fileprivate func fitFilterRow() {
        let available = workspaceFilterRow.bounds.width
        guard drawsSidebarLayout, available > 0 else { return }
        let expanded: [NSView] = [scopeFilter, followUpsJump, projectPopup, sortPopup, doneWindowNote]
            .filter { view in
                view === projectPopup || view === sortPopup || view === scopeFilter
                    || (view === followUpsJump && followUpsJumpWanted)
                    || (view === doneWindowNote && tasksView == .board)
            }
        let needed = expanded.reduce(0) { $0 + $1.fittingSize.width }
            + workspaceFilterRow.spacing * CGFloat(max(0, expanded.count - 1))
        let collapse = needed > available
        filterRowCollapsed = collapse
        // Only a real change is written: a visibility change schedules
        // another layout pass, and this runs from `viewDidLayout`.
        let wanted: [(NSView, Bool)] = [
            (projectPopup, collapse),
            (sortPopup, collapse || topLevelView != .dashboard),
            (filterMenuButton, !collapse),
            (followUpsJump, collapse || !followUpsJumpWanted),
            (doneWindowNote, collapse || tasksView != .board || topLevelView != .dashboard),
        ]
        for (view, hidden) in wanted where view.isHidden != hidden { view.isHidden = hidden }
    }

    private func refreshFilterMenuTitle() {
        filterMenuButton.title = projectFilter == nil ? "Filter" : "Filter \u{2002}1"
        filterMenuButton.setAccessibilityLabel(projectFilter == nil ? "Filter" : "Filter, one project")
    }

    /// The collapsed row's menu: Project and Sort by, each item ticked as its
    /// pop-up is, and the Done window's note when the board shows.
    func filterMenu() -> NSMenu {
        let menu = NSMenu()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if followUpsJumpWanted {
            menu.addItem(ShiftLaneMenuItem(title: followUpsJump.title.replacingOccurrences(of: "\u{2002}", with: " ")) {
                [weak self] in self?.followUpsJumpClicked()
            })
            menu.addItem(.separator())
        }
        header("Project")
        for index in 0..<projectPopup.numberOfItems {
            guard let source = projectPopup.item(at: index) else { continue }
            let item = ShiftLaneMenuItem(title: source.title) { [weak self] in
                self?.projectPopup.selectItem(at: index)
                self?.projectPopupChanged()
            }
            item.image = source.image
            item.state = index == projectPopup.indexOfSelectedItem ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        header("Sort by")
        for index in 0..<sortPopup.numberOfItems {
            guard let source = sortPopup.item(at: index) else { continue }
            let item = ShiftLaneMenuItem(title: source.title) { [weak self] in
                self?.sortPopup.selectItem(at: index)
                self?.sortChanged()
            }
            item.state = index == sortPopup.indexOfSelectedItem ? .on : .off
            menu.addItem(item)
        }
        if tasksView == .board {
            menu.addItem(.separator())
            header(doneWindowNote.stringValue)
        }
        return menu
    }

    @objc private func filterMenuClicked() {
        filterMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: filterMenuButton.bounds.height + 4),
                           in: filterMenuButton)
    }

    @objc fileprivate func projectPopupChanged() {
        let id = projectPopup.selectedItem?.representedObject as? String
        projectFilter = id
        render()
    }

    @objc fileprivate func followUpsJumpClicked() {
        scrollToPanel(followUpPanel)
    }

    /// A project's dot for its popup item, in the hue its cards and lanes use.
    private static func projectDot(_ tint: HelmTint, theme: HelmTheme) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            HelmTheme.nsColor(tint.hex(in: theme)).setFill()
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
        let rows = open.map { taskRow($0, column: ShiftBoardColumn.column(for: $0.status) ?? .backlog) }
            + done.map { taskRow($0, column: .done) }
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
        row.cells["project"] = .view(ShiftProjectTag(name: project?.name ?? "No project",
                                                     tint: ShiftProjectPalette.tint(forProjectID: task.projectID),
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
        row.cells["project"] = .view(ShiftProjectTag(name: project?.name ?? "No project",
                                                     tint: ShiftProjectPalette.tint(forProjectID: item.projectID),
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

    private func adoptWorkspaceWeeklyReview() {
        reviewGreeting.font = HelmType.sectionTitle()
        reviewSubtitle.isHidden = true
        reviewStatsCard.isHidden = true
        reviewPushedBackCount.toolTip = "Tasks pushed back two or more times"
        reviewPushedBackHeaderRow?.setActions([reviewPushedBackCount])
        guard let statsIndex = weeklyReviewContainer.arrangedSubviews.firstIndex(of: reviewStatsCard) else { return }
        weeklyReviewContainer.insertArrangedSubview(reviewCardsRow, at: statsIndex + 1)
        reviewCardsRow.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        // Time on tasks beside Pushed back repeatedly, two to one, as the
        // prototype sets its chart beside its checklist.
        for panel in [reviewFocusPanel, reviewPushedBackPanel] {
            weeklyReviewContainer.removeArrangedSubview(panel)
            panel.removeFromSuperview()
            reviewLowerRow.addArrangedSubview(panel)
        }
        reviewLowerRow.orientation = .horizontal
        reviewLowerRow.alignment = .top
        reviewLowerRow.distribution = .fill
        reviewLowerRow.spacing = HelmMetrics.s4
        reviewLowerRow.translatesAutoresizingMaskIntoConstraints = false
        weeklyReviewContainer.addArrangedSubview(reviewLowerRow)
        // R4-UI-09: the next-week agenda across the foot, which the
        // "Coming up next week" tile counts and nothing used to list.
        let headerRow = sectionHeaderRow(iconSymbol: "calendar", tint: .info, label: reviewAgendaHeader)
        headerRow.setActions([reviewAgendaCount])
        reviewAgendaCount.toolTip = "Open tasks and pending follow-ups due next week"
        reviewAgendaStack.orientation = .vertical
        reviewAgendaStack.alignment = .leading
        reviewAgendaStack.spacing = 0
        reviewAgendaStack.translatesAutoresizingMaskIntoConstraints = false
        reviewAgendaPanel.setHeader(headerRow)
        reviewAgendaPanel.setBody(reviewAgendaStack)
        reviewAgendaPanel.translatesAutoresizingMaskIntoConstraints = false
        weeklyReviewContainer.addArrangedSubview(reviewAgendaPanel)
        NSLayoutConstraint.activate([
            reviewLowerRow.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor),
            reviewPushedBackPanel.widthAnchor.constraint(equalTo: reviewFocusPanel.widthAnchor, multiplier: 0.5),
            reviewAgendaPanel.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor),
        ])
    }

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
        let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            .map { store.weeklySummary(reference: $0).completedCount }
        reviewCards[0].configure(count: summary.completedCount)
        if let lastWeek {
            let delta = summary.completedCount - lastWeek
            let text = delta == 0 ? "Same as last week" : "\(delta > 0 ? "+" : "\u{2212}")\(abs(delta)) vs last week"
            reviewCards[0].setDetail(text, tint: delta > 0 ? .good : nil)
        } else {
            reviewCards[0].setDetail(nil)
        }
        let focusDays = store.focusSecondsByDay(days: 7)
        let focusSeconds = focusDays.reduce(0) { $0 + $1.seconds }
        let focusTasks = store.focusTaskCount(days: 7)
        reviewCards[1].configure(text: focusSeconds > 0 ? FocusTimerFormat.total(focusSeconds) : "None yet",
                                 signals: false)
        reviewCards[1].setDetail(focusSeconds > 0
            ? "last 7 days \u{00B7} \(focusTasks) task\(focusTasks == 1 ? "" : "s") with a timer"
            : "Start a focus session from any task")
        let c = counts()
        reviewCards[2].configure(count: c.overdue)
        let today = Calendar.current.startOfDay(for: Date())
        let overdueTasks = store.activeTasks.filter(matchesProjectFilter).filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < today
        }.sorted(by: Self.byDueDateThenCreated)
        reviewCards[2].setDetail(overdueTasks.first?.title ?? "Nothing late")
        let pending = store.followUps.filter { $0.status == .pending }
        let dueToday = pending.filter { fu in
            fu.followUpAt.flatMap(ShiftDateFormatting.date(from:)).map { Calendar.current.isDate($0, inSameDayAs: Date()) }
                ?? false
        }.count
        reviewCards[3].configure(text: "\(pending.count)", signals: false)
        reviewCards[3].setDetail(dueToday > 0 ? "\(dueToday) due today" : "None due today")
        reviewCards[4].configure(text: "\(summary.upcomingCount)", signals: false)
        reviewCards[4].setDetail("tasks and follow-ups due")
        reviewPushedBackHeader.stringValue = "Pushed back repeatedly"
        reviewPushedBackCount.text = "\(summary.pushedBack.count)"
        reviewPushedBackCount.applyTheme(theme)
        renderReviewAgenda()
        for card in reviewCards { card.applyTheme(theme) }
    }
}

/// A project's dot and name, as the List tab's Project column and the
/// prototype's table draw it - the hue its board cards use.
final class ShiftProjectTag: NSView {
    static let dotSide = HelmMetrics.s2

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(name: String, tint: HelmTint, theme: HelmTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = name
        label.font = HelmType.body()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

#if FM_SELFTESTS
extension ShiftController {
    var debugWorkspaceFilterRow: NSStackView { workspaceFilterRow }
    var debugScopeFilter: HelmSegmentedTabs { scopeFilter }
    var debugProjectPopup: HelmPopUpButton { projectPopup }
    var debugFollowUpsJump: HelmButton { followUpsJump }
    var debugTasksTable: HelmDataTable { tasksTable }
    var debugFollowUpsTable: HelmDataTable { followUpsTable }
    var debugReviewCards: [HelmMetricCard] { reviewCards }
    /// The Pushed back panel's count, when it is mounted and showing.
    var debugPushedBackCount: String? {
        reviewPushedBackCount.superview != nil && !reviewPushedBackCount.isHidden ? reviewPushedBackCount.text : nil
    }
    var debugNewTaskButton: HelmButton { newTaskButton }
    var debugTasksViewID: String { topLevelView == .weeklyReview ? "review" : tasksView.rawValue }
    /// Pick a project through the popup's own action, as a click does.
    func debugPickProject(id: String?) {
        let index = id.flatMap { pid in store.projects.firstIndex { $0.id == pid }.map { $0 + 1 } } ?? 0
        projectPopup.selectItem(at: index)
        _ = projectPopup.sendAction(projectPopup.action, to: projectPopup.target)
    }
}
#endif
