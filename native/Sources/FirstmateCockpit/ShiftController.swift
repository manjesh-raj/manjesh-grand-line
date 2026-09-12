// Manjesh Grand Line - native macOS app.
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

final class ShiftController: NSViewController, DaylightDrillActions {

    private let store: ShiftStore

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    /// GL-16: see `UpdatesController.checkAllPill` - a clear-coloured
    /// `HoverHighlightView` renders identically to the plain `NSView` this
    /// was and inherits the shared press/focus/keyboard behaviour.
    private let syncPill = HoverHighlightView()
    private let syncPillLabel = NSTextField(labelWithString: "")
    private let statsRow = NSStackView()
    /// Live dashboard stat tiles. Each themes itself; this list only exists so
    /// `applyTheme` can reach the ones currently built (the row is rebuilt from
    /// scratch on every render).
    private var statTiles: [HelmStatTile] = []

    private let taskListView = ShiftTaskListView()
    private let taskListScroll = NSScrollView()
    private let tasksHeader = NSTextField(labelWithString: "")
    private let tasksCountBadge = NSTextField(labelWithString: "")
    private let taskPanel = HelmCard()

    private let followUpListView = ShiftFollowUpListView()
    private let followUpScroll = NSScrollView()
    private let followUpsHeader = NSTextField(labelWithString: "")
    private let followUpsCountBadge = NSTextField(labelWithString: "")
    private let followUpPanel = HelmCard()

    private let projectsHeader = NSTextField(labelWithString: "")
    private let projectsCountBadge = NSTextField(labelWithString: "")
    private let projectsPanel = HelmCard()
    private let projectsGridContainer = NSStackView()
    private let projectsDetailContainer = NSStackView()

    /// The neutral pill containers wrapping every `sectionHeaderRow` count
    /// badge (the prototype's `.count` - a muted mono pill, distinct from
    /// `ToolRowLayout.pill`'s tinted status chip). Built once per header
    /// row, restyled here since a plain `NSTextField` carries no background
    /// of its own to theme. See `countPillContainer(for:)`.
    private var countBadgeContainers: [NSView] = []

    /// Every `sectionHeaderRow`'s leading icon tile - a colored `IconTileView`
    /// (the prototype's `.tile.b.t-{tint}`, the same idiom `FleetController`'s
    /// "In flight" heading and every `HelmCard.setHeader(symbol:...)` caller
    /// already use), not a bare glyph. `IconTileView.applyTheme` needs a
    /// second call on every theme change (it only self-themes once, at
    /// `configure` time), so these are tracked the same way
    /// `countBadgeContainers` is.
    private var headerIconTiles: [IconTileView] = []

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
    private enum ShiftTopLevelView: String { case dashboard, weeklyReview }
    private var topLevelView: ShiftTopLevelView = .dashboard
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
    private enum ShiftTasksView: String { case board, list }
    private var tasksView: ShiftTasksView = .board
    private let tasksViewToggle = HelmSegmentedTabs(items: [
        .init(id: ShiftTasksView.board.rawValue, title: "Board"),
        .init(id: ShiftTasksView.list.rawValue, title: "List"),
    ], selected: ShiftTasksView.board.rawValue, size: .compact)

    private let boardSection = NSStackView()
    private let boardToolbar = NSStackView()
    private let boardView = ShiftBoardView()
    private let projectFilterBar = ShiftProjectFilterBar()
    /// `nil` = every project, matching `ShiftProjectFilterBar`'s own "All
    /// projects" chip. Held here rather than read back off the chip row so
    /// the board and the list filter identically.
    private var projectFilter: String?

    /// How far back the Done column looks.
    ///
    /// Completed tasks do not live in `active.yaml` - they are filed into
    /// `tasks/completed/<YYYY-MM>.yaml` by month (see
    /// `ShiftStore.setTaskCompleted`), so "Done" could mean every task ever
    /// finished. That is not a column, it is an archive: it would grow
    /// without bound and bury the two columns a board is actually for. A week
    /// matches the window Weekly Review already reasons in, and anything
    /// older is still reachable through a project's own detail page.
    private static let doneColumnLookbackDays = 7

    /// The My Tasks / Weekly Review switcher, built from the app's shared
    /// `HelmSegmentedTabs` (`HelmDesignSystem.swift`, audit section 6.3
    /// component 6). This page's own capsule was the model the component
    /// adopted.
    ///
    /// `fm/grandline-tasks-kanban-devops-split` took the third pill - "DevOps
    /// Commands" - off this row: the Command Library is its own top-level
    /// destination now (`CommandLibraryController`), so reaching a saved
    /// command no longer means first opening a page about something else.
    ///
    /// Weekly Review stays a pill rather than folding into the board as a
    /// filter: it answers a different question (what happened across a week)
    /// with entirely different content (stat tiles and a pushed-back list, no
    /// task cards at all), and it is already the target of a menu item and a
    /// search-palette entry that both expect a view to switch to.
    private let tabs = HelmSegmentedTabs(items: [
        .init(id: ShiftTopLevelView.dashboard.rawValue, title: "My Tasks"),
        .init(id: ShiftTopLevelView.weeklyReview.rawValue, title: "Weekly Review"),
    ], selected: ShiftTopLevelView.dashboard.rawValue)

    private let reviewGreeting = NSTextField(labelWithString: "")
    private let reviewSubtitle = NSTextField(labelWithString: "What got done, what got pushed back, what's coming.")
    private let reviewStatsRow = NSStackView()
    /// The same, for Weekly Review's own independently-rebuilt row.
    private var reviewStatTiles: [HelmStatTile] = []
    private let reviewPushedBackPanel = HelmCard()
    private let reviewPushedBackHeader = NSTextField(labelWithString: "Pushed back repeatedly")
    private let reviewPushedBackStack = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var expandedTaskIDs: Set<String> = []
    private var syncStatus: ShiftGitSync.Status = .synced

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
    private static let taskFollowUpPanelBodyHeight: CGFloat = 280

    init(store: ShiftStore) {
        self.store = store
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
        let tabRow = buildTabRow()
        buildStatsRow()
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
        leftColumn.spacing = 20
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        let rightColumn = NSStackView(views: [followUpSection])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 20
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        tasksLeftColumn = leftColumn
        let tasksRow = NSStackView(views: [leftColumn, rightColumn])
        tasksRow.orientation = .horizontal
        tasksRow.distribution = .fillEqually
        tasksRow.alignment = .top
        tasksRow.spacing = 20
        tasksRow.translatesAutoresizingMaskIntoConstraints = false

        dashboardContainer.orientation = .vertical
        dashboardContainer.alignment = .leading
        dashboardContainer.spacing = 20
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.addArrangedSubview(statsRow)
        // The board's own toolbar (Board/List + the project chips) and the
        // board itself sit above the Today/Follow-ups row, full width - three
        // columns squeezed into half a page is the one layout a Kanban must
        // not have. In Board mode `taskPanel` hides, and because a *hidden
        // arranged subview of an `NSStackView`* leaves layout entirely
        // (AGENTS.md gotcha (11)'s one exception), Follow-ups takes the row
        // on its own rather than sitting beside an empty half.
        dashboardContainer.addArrangedSubview(boardSection)
        dashboardContainer.addArrangedSubview(tasksRow)
        // Projects is its own full-width section, a direct child of the
        // dashboard rather than nested in either column - it renders a
        // multi-column card grid of its own and reads better spanning the
        // page than confined to half of it.
        dashboardContainer.addArrangedSubview(projectsSection)
        // The project *detail* is also a direct child of the dashboard: it
        // takes the whole page when open (`applyProjectDetailFullPage`), so
        // nesting it inside any column would cap it at that column's width.
        dashboardContainer.addArrangedSubview(projectsDetailContainer)

        let weeklyReviewSection = buildWeeklyReviewSection()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(tabRow)

        contentStack.addArrangedSubview(dashboardContainer)
        contentStack.addArrangedSubview(weeklyReviewSection)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            dashboardContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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
            weeklyReviewSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            boardSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            // The toolbar spans the page so its trailing-pinned Board/List
            // switch actually lands at the page's own trailing edge.
            tabRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

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

        followUpListView.onEdit = { [weak self] item in
            self?.presentFollowUpEditor(for: item)
        }
        followUpListView.onToggleDone = { [weak self] item in
            self?.store.setFollowUpStatus(id: item.id, done: item.status != .done)
            self?.render()
        }
        followUpListView.onSnooze = { [weak self] item, option in
            self?.snoozeFollowUp(item, option: option)
        }
        followUpListView.onDelete = { [weak self] item in
            self?.confirmDeleteFollowUp(id: item.id)
        }

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil
        )

        store.gitSync?.observeStatus { [weak self] status in
            self?.syncStatus = status
            self?.applySyncPill()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Mirrors `ToolsController`'s own resize-gating fix (fm/cockpit-tools-
    /// yaml-quotes-diff-perf's sibling perf fix): only re-flow the grid while
    /// it's actually the visible view, so a captain's resize elsewhere in the
    /// app never pays for laying out project cards nobody is looking at.
    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        guard !view.isHidden, projectsView == .grid else { return }
        view.layoutSubtreeIfNeeded()
        rebuildProjectsGrid()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
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
    var drillHeaderActions: [NSView] {
        store.gitSync == nil ? [] : [syncPill]
    }

    /// §6.4's live subtitle, from the same counts the page's own stat tiles
    /// render - so the header and the tiles cannot disagree.
    var drillHeaderSubtitle: String? {
        let tasks = store.activeTasks
        let pending = store.followUps.filter { $0.status == .pending }.count
        let cal = Calendar.current
        let overdue = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < cal.startOfDay(for: Date())
        }.count
        var parts = ["\(tasks.count) open"]
        if pending > 0 { parts.append("\(pending) follow-up\(pending == 1 ? "" : "s")") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Set by `AppShellController` - "my live numbers changed, re-read my
    /// subtitle". See `DaylightDrillActions`.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Reflects `ShiftGitSync`'s real status - never a timer or a fake cycle.
    /// `nil` `store.gitSync` (an explicit `FM_SHIFT_DIR` override with no git
    /// backing) means the pill was never added to the header at all (see
    /// `configureSyncPill()`) - nothing to style.
    private func applySyncPill() {
        guard store.gitSync != nil else { return }
        syncPill.isHidden = false
        let (text, colorHex): (String, String)
        switch syncStatus {
        case .synced: (text, colorHex) = ("Synced", theme.ansiHex[2])
        case .localChanges: (text, colorHex) = ("Local changes", theme.ansiHex[3])
        case .syncing: (text, colorHex) = ("Syncing\u{2026}", theme.accentHex)
        case .failed(let reason):
            (text, colorHex) = ("Failed", theme.ansiHex[1])
            syncPill.toolTip = reason
        case .conflict(let fileCount):
            (text, colorHex) = ("Conflict \u{2013} click to resolve", theme.ansiHex[1])
            syncPill.toolTip = "\(fileCount) file\(fileCount == 1 ? "" : "s") need a decision - click to resolve."
        }
        switch syncStatus {
        case .failed, .conflict: break
        default: syncPill.toolTip = nil
        }
        ToolRowLayout.pill(text: text, colorHex: colorHex, into: syncPill, label: syncPillLabel)
        // Mono pill text, per the mockup's `--mono` role for pill labels -
        // `ToolRowLayout.pill` is shared app-wide and stays sans for its
        // other callers (Updates/Bootstrap rows), so the override happens
        // here rather than in the shared helper.
        syncPillLabel.font = ShiftFont.mono(10.5, weight: .semibold)
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

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// One `HelmStatTile` - the app's shared stat tile
    /// (`HelmDesignSystem.swift`, audit §6.3 component 4). This page's own copy
    /// was the model the component adopted (12/10 padding, a 19pt metric, a
    /// 56pt tile); what changed in the migration is that the tint now reaches
    /// the metric through `HelmContrast.legibleTintedText` rather than as the
    /// raw hue, which measured below the text floor in several palettes
    /// (audit §5.7).
    private func statTile(icon: String, value: String, label: String, tint: HelmTint? = nil) -> NSView {
        let tile = HelmStatTile(symbol: icon, value: value, caption: label, tint: tint)
        statTiles.append(tile)
        return tile
    }

    /// A panel header row: a tinted `IconTileView` + serif title + a small
    /// muted monospace count badge (the prototype's `.cnt` - "My Tasks 12",
    /// not text baked into the title itself) + an optional "+" add action.
    /// `countBadge` is `nil` for sections (Weekly Review's "Pushed back", the
    /// detail form) that don't need a live count.
    ///
    /// The icon tile, count badge, and "+" button all come from tokens
    /// already shared across this app (`IconTileView`, `countPillContainer`,
    /// `HelmButton(.quiet)`) rather than a bare glyph, a hand-rolled label,
    /// and a plain `NSButton` - the tile mirrors `FleetController`'s "In
    /// flight" heading and every `HelmCard.setHeader(symbol:...)` caller, so
    /// this hand-built header (needed for the count badge + "+" pair, per
    /// `HelmCard`'s own "arbitrary header view" escape hatch) still matches
    /// the app's one icon-tile convention rather than inventing a bare-glyph
    /// second one. See `fm/grandline-tasks-projects-redesign`.
    private func sectionHeaderRow(
        iconSymbol: String, tint: HelmTint = .accent, label: NSTextField, countBadge: NSTextField? = nil,
        addAction: Selector? = nil, addTooltip: String? = nil
    ) -> NSStackView {
        let icon = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
        icon.configure(symbol: iconSymbol, tint: tint, pointSize: 13)
        headerIconTiles.append(icon)
        label.font = HelmType.sectionTitle()
        var views: [NSView] = [icon, label]
        if let countBadge {
            views.append(countPillContainer(for: countBadge))
        }
        if let addAction {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let addButton = HelmButton(symbol: "plus", variant: .quiet, size: .small, target: self, action: addAction)
            addButton.toolTip = addTooltip
            views += [spacer, addButton]
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        // `.centerY`, not `.firstBaseline` - the count-badge pill and the
        // `HelmButton` are plain views with no text baseline of their own,
        // and `.firstBaseline` alignment against them dropped the badge
        // onto its own line below the title (live-caught rendering the
        // fix). `VaultController.sectionHeaderRow` uses the same `.centerY`
        // for the identical icon+title+badge+button shape.
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Wraps a count-badge label in the prototype's `.count` pill: a small,
    /// neutral, monospace-digit chip (`background: rgba(ink,.08)`) - not
    /// `ToolRowLayout.pill`, which always carries a semantic tint and would
    /// make an ordinary item count read as a status. Built once per header
    /// (see `countBadgeContainers`), restyled from `applyTheme()`.
    private func countPillContainer(for label: NSTextField) -> NSView {
        label.font = HelmType.metric(11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = HelmMetrics.rChip
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        container.setContentHuggingPriority(.required, for: .horizontal)
        countBadgeContainers.append(container)
        return container
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
        taskListScroll.translatesAutoresizingMaskIntoConstraints = false
        taskListScroll.heightAnchor.constraint(equalToConstant: Self.taskFollowUpPanelBodyHeight).isActive = true

        taskPanel.setHeader(headerRow)
        taskPanel.setBody(taskListScroll)
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
        followUpScroll.translatesAutoresizingMaskIntoConstraints = false
        followUpScroll.heightAnchor.constraint(equalToConstant: Self.taskFollowUpPanelBodyHeight).isActive = true

        followUpPanel.setHeader(headerRow)
        followUpPanel.setBody(followUpScroll)
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
        projectsDetailContainer.spacing = 14
        projectsDetailContainer.translatesAutoresizingMaskIntoConstraints = false
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

    /// Sits above the board: the Board/List toggle on the left, the project
    /// filter chips beside it, and a short hint about how a card moves.
    private let boardHint = NSTextField(labelWithString: "Drag a card between columns, or right-click it to move.")

    private func buildBoardSection() {
        projectFilterBar.onSelect = { [weak self] projectID in
            guard let self else { return }
            self.projectFilter = projectID
            self.render()
        }

        boardHint.font = HelmType.captionSmall()
        boardHint.lineBreakMode = .byTruncatingTail
        // The hint is the one thing in this row allowed to shrink - a filter
        // chip that truncated to "Pra..." would defeat the point of the chip.
        boardHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        boardToolbar.orientation = .horizontal
        boardToolbar.alignment = .centerY
        boardToolbar.spacing = HelmMetrics.s3
        // AGENTS.md gotcha (10): a horizontal stack left at the default
        // `.gravityAreas` honours no hugging priority at all, so the row's
        // slack lands wherever Auto Layout's own tie-breaking puts it.
        boardToolbar.distribution = .fill
        boardToolbar.translatesAutoresizingMaskIntoConstraints = false
        boardToolbar.addArrangedSubview(projectFilterBar)
        boardToolbar.addArrangedSubview(spacer)
        boardToolbar.addArrangedSubview(boardHint)

        boardView.onOpenTask = { [weak self] id in self?.openBoardTask(id: id) }
        boardView.onMoveTask = { [weak self] id, column in self?.moveTask(id: id, to: column) }
        boardView.onDeleteTask = { [weak self] id in self?.confirmDeleteTask(id: id) }
        boardView.onAddTask = { [weak self] column in self?.addTask(in: column) }
        boardView.onDropTask = { [weak self] id, column in self?.moveTask(id: id, to: column) ?? false }

        boardSection.orientation = .vertical
        boardSection.alignment = .leading
        boardSection.spacing = HelmMetrics.s3
        boardSection.translatesAutoresizingMaskIntoConstraints = false
        boardSection.addArrangedSubview(boardToolbar)
        boardSection.addArrangedSubview(boardView)
        boardToolbar.widthAnchor.constraint(equalTo: boardSection.widthAnchor).isActive = true
        boardView.widthAnchor.constraint(equalTo: boardSection.widthAnchor).isActive = true
    }

    private func switchTasksView(_ view: ShiftTasksView) {
        tasksView = view
        tasksViewToggle.select(view.rawValue)
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
        for task in store.activeTasks where matchesProjectFilter(task) {
            guard let column = ShiftBoardColumn.column(for: task.status) else { continue }
            byColumn[column, default: []].append(task)
        }
        for column in [ShiftBoardColumn.backlog, .inProgress] {
            byColumn[column] = (byColumn[column] ?? []).sorted(by: Self.byDueDateThenCreated)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.doneColumnLookbackDays, to: Date())
        byColumn[.done] = store.allCompletedTasks()
            .filter(matchesProjectFilter)
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

    /// The list's own ordering, extracted so the board's two in-flight
    /// columns and the flat list cannot disagree about what "next" means.
    private static func byDueDateThenCreated(_ lhs: ShiftTask, _ rhs: ShiftTask) -> Bool {
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
        HelmConfirm.notice(
            title: "\u{201C}\(done.title)\u{201D} is done",
            body: "Completed tasks are filed away and can't be edited in place. "
                + "Move it back to Backlog or In Progress to edit it.",
            symbol: "checkmark.circle.fill",
            hue: RailDestination.shift.domainHue)
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
    func confirmDeleteTask(id: String) {
        let task = store.activeTasks.first(where: { $0.id == id })
            ?? store.allCompletedTasks().first(where: { $0.id == id })
        guard let task else { return }

        var detail = "This can't be undone."
        if task.hasAttachment { detail += " Its attached image is deleted too." }
        if !task.subtasks.isEmpty {
            detail += " Its \(task.subtasks.count) subtask\(task.subtasks.count == 1 ? "" : "s") go with it."
        }
        guard DestructiveConfirm.confirm(message: "Delete \u{201C}\(task.title)\u{201D}?",
                                         detail: detail,
                                         confirmTitle: "Delete Task",
                                         window: view.window) else { return }
        store.deleteTask(id: id)
        Toast.show(in: view, message: "\u{201C}\(task.title)\u{201D} deleted")
        render()
    }

    /// The same, for a follow-up - see `ShiftStore.deleteFollowUp`'s header
    /// for why follow-ups got a delete alongside tasks and projects did not.
    func confirmDeleteFollowUp(id: String) {
        guard let item = store.followUps.first(where: { $0.id == id }) else { return }
        guard DestructiveConfirm.confirm(message: "Delete \u{201C}\(item.title)\u{201D}?",
                                         detail: "This follow-up is removed for good. This can't be undone.",
                                         confirmTitle: "Delete Follow-up",
                                         window: view.window) else { return }
        store.deleteFollowUp(id: id)
        Toast.show(in: view, message: "\u{201C}\(item.title)\u{201D} deleted")
        render()
    }

    // MARK: Weekly Review

    /// The page's top toolbar, laid out the way the captain's reference draws
    /// it: the view tabs pinned left, the Board/List switch pinned right,
    /// with the space between them empty.
    ///
    /// The switch hides on Weekly Review, because there is no task list there
    /// for it to switch - the reference hides it on its own non-task tabs for
    /// the same reason.
    private func buildTabRow() -> NSView {
        tabs.onSelect = { [weak self] id in
            guard let self, let view = ShiftTopLevelView(rawValue: id) else { return }
            self.switchTopLevelView(view)
        }
        tasksViewToggle.onSelect = { [weak self] id in
            guard let self, let view = ShiftTasksView(rawValue: id) else { return }
            self.switchTasksView(view)
        }
        tasksViewToggle.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [tabs, spacer, tasksViewToggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        // AGENTS.md gotcha (10): without `.fill` a horizontal stack honours no
        // hugging priority at all and the spacer never absorbs the slack, so
        // the switch would sit next to the tabs instead of at the far edge.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        topToolbar = row
        return row
    }

    /// Held so `switchTopLevelView` can size it and hide the view switch.
    private var topToolbar: NSStackView?

    private func switchTopLevelView(_ view: ShiftTopLevelView) {
        topLevelView = view
        // Keeps the active pill right when the view was changed from somewhere
        // other than a pill click - the Shift menu, the search palette,
        // `showWeeklyReview()`/`showDashboard()`. A no-op on a real pill click,
        // which has already moved it.
        tabs.select(view.rawValue)
        dashboardContainer.isHidden = view != .dashboard
        weeklyReviewContainer.isHidden = view != .weeklyReview
        tasksViewToggle.isHidden = view != .dashboard
        if view == .weeklyReview { renderWeeklyReview() }
        applyTheme()
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
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        reviewStatsRow.orientation = .horizontal
        reviewStatsRow.distribution = .fillEqually
        reviewStatsRow.spacing = 10
        reviewStatsRow.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = sectionHeaderRow(iconSymbol: "arrow.uturn.backward", tint: .warn, label: reviewPushedBackHeader)

        reviewPushedBackStack.orientation = .vertical
        reviewPushedBackStack.alignment = .leading
        reviewPushedBackStack.spacing = 0
        reviewPushedBackStack.translatesAutoresizingMaskIntoConstraints = false
        reviewPushedBackPanel.setHeader(headerRow)
        reviewPushedBackPanel.setBody(reviewPushedBackStack)
        reviewPushedBackPanel.translatesAutoresizingMaskIntoConstraints = false

        weeklyReviewContainer.orientation = .vertical
        weeklyReviewContainer.alignment = .leading
        weeklyReviewContainer.spacing = 20
        weeklyReviewContainer.translatesAutoresizingMaskIntoConstraints = false
        weeklyReviewContainer.isHidden = true
        weeklyReviewContainer.addArrangedSubview(textStack)
        weeklyReviewContainer.addArrangedSubview(reviewStatsRow)
        weeklyReviewContainer.addArrangedSubview(reviewPushedBackPanel)
        textStack.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewStatsRow.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewPushedBackPanel.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        return weeklyReviewContainer
    }

    private func renderWeeklyReview() {
        let summary = store.weeklySummary()
        reviewGreeting.stringValue = summary.weekLabel

        for v in reviewStatsRow.arrangedSubviews {
            reviewStatsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        reviewStatTiles.removeAll()
        reviewStatsRow.addArrangedSubview(reviewStatTile(icon: "checkmark.circle", value: "\(summary.completedCount)", label: "completed this week"))
        reviewStatsRow.addArrangedSubview(reviewStatTile(icon: "arrow.uturn.backward", value: "\(summary.pushedBack.count)", label: "pushed back 2+ times", tint: .warn))
        reviewStatsRow.addArrangedSubview(reviewStatTile(icon: "calendar", value: "\(summary.upcomingCount)", label: "coming up next week"))

        for v in reviewPushedBackStack.arrangedSubviews {
            reviewPushedBackStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if summary.pushedBack.isEmpty {
            let empty = HelmEmptyState(symbol: "checkmark.seal", body: "Nothing's been pushed back more than once.")
            empty.applyTheme(theme)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 90).isActive = true
            reviewPushedBackStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: reviewPushedBackStack.widthAnchor).isActive = true
        } else {
            for item in summary.pushedBack {
                let row = reviewPushedBackRow(item)
                reviewPushedBackStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: reviewPushedBackStack.widthAnchor).isActive = true
            }
        }
        applyTheme()
    }

    /// The Weekly Review stat row. This used to be `reviewStatTile`, a
    /// byte-for-byte duplicate of `statTile` above whose own doc comment
    /// explained that it existed only because the two rows shared one theming
    /// array, so "whichever rebuilds last wins the next `applyTheme()` pass for
    /// both". A `HelmStatTile` themes itself, so that reason is gone and both
    /// rows now build the same tile - the only thing they still keep apart is
    /// which list of live tiles `applyTheme` hands the theme to, since the two
    /// rows are rebuilt independently.
    private func reviewStatTile(icon: String, value: String, label: String, tint: HelmTint? = nil) -> NSView {
        let tile = HelmStatTile(symbol: icon, value: value, caption: label, tint: tint)
        reviewStatTiles.append(tile)
        return tile
    }

    private func reviewPushedBackRow(_ item: ShiftPushedBackItem) -> NSView {
        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .medium)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.lineBreakMode = .byTruncatingTail

        var metaText = "Pushed back \(item.count) times"
        if let projectName = item.projectName { metaText += " \u{00B7} \(projectName)" }
        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.font = HelmType.captionSmall()
        metaLabel.textColor = HelmTheme.mutedInk(theme)

        let textStack = NSStackView(views: [titleLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let row = NSStackView(views: [divider, textStack])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: padded.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: padded.trailingAnchor),
            row.topAnchor.constraint(equalTo: padded.topAnchor),
            row.bottomAnchor.constraint(equalTo: padded.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: row.widthAnchor),
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
        ])
        return padded
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

    private func render() {
        // §6.4: the greeting and the date line this used to write are gone
        // with the in-page hero - the drill header carries the destination's
        // name, and its subtitle carries these counts.
        onDrillSubtitleChanged?()

        let tasks = store.activeTasks
        let followUps = store.followUps
        let today = Date()
        let cal = Calendar.current

        let dueToday = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return cal.isDate(due, inSameDayAs: today)
        }
        let overdue = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < cal.startOfDay(for: today)
        }
        let pendingFollowUps = followUps.filter { $0.status == .pending }

        rebuildStats(tasksToday: dueToday.count, followUps: pendingFollowUps.count, overdue: overdue.count)

        let sortedTasks = tasks.sorted(by: Self.byDueDateThenCreated)
        taskListView.setTasks(sortedTasks.filter(matchesProjectFilter), projects: store.projects)
        tasksHeader.stringValue = "My Tasks"
        tasksCountBadge.stringValue = "\(tasks.count)"

        // The board and the flat list are two presentations of the same
        // filtered set, so both are refreshed on every render regardless of
        // which one is showing - a stale board behind a view toggle is the
        // exact "switch away and back to find yesterday's data" shape this
        // page has been corrected for before.
        projectFilterBar.setProjects(store.projects, theme: theme)
        boardView.setTasks(boardTasks(), projects: store.projects, theme: theme)
        applyTasksViewVisibility()

        followUpListView.setItems(followUps)
        followUpsHeader.stringValue = "Follow-ups"
        followUpsCountBadge.stringValue = "\(pendingFollowUps.count) pending"

        renderProjectsSection()
        if topLevelView == .weeklyReview { renderWeeklyReview() }

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
        statsRow.isHidden = isDetail
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
        let boardShowing = !isProjectDetailFullPage && tasksView == .board
        boardSection.isHidden = !boardShowing
        let hideTasks = isProjectDetailFullPage || boardShowing
        taskPanel.isHidden = hideTasks
        // The *column wrapper*, not just the panel inside it. `tasksRow` is
        // `.fillEqually`, and a visible-but-empty column still claims its
        // half of the row - which left Follow-ups rendering at half width
        // against a blank left half in board mode (caught in a real render,
        // not by reading the constraints).
        tasksLeftColumn?.isHidden = hideTasks
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

    private func rebuildStats(tasksToday: Int, followUps: Int, overdue: Int) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statTiles.removeAll()
        statsRow.addArrangedSubview(statTile(icon: "sun.max", value: "\(tasksToday)", label: "tasks today"))
        statsRow.addArrangedSubview(statTile(icon: "bell", value: "\(followUps)", label: "follow-ups"))
        statsRow.addArrangedSubview(statTile(icon: "exclamationmark.triangle", value: "\(overdue)", label: "overdue", tint: .critical))
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
            // Built fresh each call (not the retained `projectsEmptyState`
            // property elsewhere) so its one-time width/height constraints
            // never accumulate across repeated rebuilds - `rebuildProjectsGrid`
            // removes the view from its superview each time but never tears
            // down constraints, which would otherwise pile up duplicates.
            let empty = HelmEmptyState(symbol: "shippingbox", body: "No projects yet.\nCreate one to start tracking tasks against it.")
            empty.applyTheme(theme)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 110).isActive = true
            projectsGridContainer.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: projectsGridContainer.widthAnchor).isActive = true
            return
        }

        let containerWidth = projectsGridContainer.frame.width > 0 ? projectsGridContainer.frame.width : 860
        let columnsPerRow = max(1, Int((containerWidth + Self.projectCardSpacing) / (Self.projectCardMinWidth + Self.projectCardSpacing)))

        let cards: [NSView] = projects.map { project in
            let (completed, total) = store.taskCounts(forProject: project.id)
            let card = ShiftProjectCardView()
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
    private let detailStatusPill = NSView()
    private let detailStatusPillLabel = NSTextField(labelWithString: "")
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

        detailStatusPillLabel.font = ShiftFont.mono(10.5, weight: .semibold)
        detailStatusPillLabel.translatesAutoresizingMaskIntoConstraints = false
        detailStatusPill.wantsLayer = true
        detailStatusPill.layer?.cornerRadius = 8
        detailStatusPill.translatesAutoresizingMaskIntoConstraints = false
        detailStatusPill.addSubview(detailStatusPillLabel)
        NSLayoutConstraint.activate([
            detailStatusPillLabel.leadingAnchor.constraint(equalTo: detailStatusPill.leadingAnchor, constant: 8),
            detailStatusPillLabel.trailingAnchor.constraint(equalTo: detailStatusPill.trailingAnchor, constant: -8),
            detailStatusPillLabel.topAnchor.constraint(equalTo: detailStatusPill.topAnchor, constant: 3),
            detailStatusPillLabel.bottomAnchor.constraint(equalTo: detailStatusPill.bottomAnchor, constant: -3),
        ])
        detailStatusPill.setContentHuggingPriority(.required, for: .horizontal)

        detailMetaLabel.font = .systemFont(ofSize: HelmType.scaled(11))

        let metaRow = NSStackView(views: [detailStatusPill, detailMetaLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 10
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        detailDescriptionLabel.font = .systemFont(ofSize: HelmType.scaled(12.5))
        detailDescriptionLabel.preferredMaxLayoutWidth = 640
        detailDescriptionLabel.lineBreakMode = .byWordWrapping

        let textStack = NSStackView(views: [detailNameLabel, metaRow, detailDescriptionLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8
        textStack.translatesAutoresizingMaskIntoConstraints = false
        detailDescriptionLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let row = NSStackView(views: [detailIconTile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
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
        stack.spacing = 18
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

    private func applyDetailStatusPill(_ status: ShiftProjectStatus) {
        let tint: HelmTint = {
            switch status {
            case .notStarted: return .neutral
            case .inProgress: return .info
            case .onHold: return .warn
            case .completed: return .good
            case .archived: return .critical
            }
        }()
        let color = HelmTheme.nsColor(tint.hex(in: theme))
        detailStatusPill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        detailStatusPillLabel.stringValue = status.displayName
        detailStatusPillLabel.textColor = color
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
    private func presentTaskEditor(for task: ShiftTask?,
                                   defaultProjectID: String? = nil,
                                   defaultStatus: ShiftTaskStatus? = nil) {
        let existingAttachmentData = (task?.hasAttachment ?? false) ? store.attachmentData(forTaskID: task!.id) : nil
        let editor = ShiftTaskEditorController(
            task: task, projects: store.projects, defaultProjectID: defaultProjectID,
            existingAttachmentData: existingAttachmentData
        )
        editor.onSave = { [weak self] saved, attachmentChange in
            guard let self else { return }
            if task != nil {
                self.store.updateTask(saved, attachment: attachmentChange)
            } else {
                var created = saved
                if let defaultStatus { created.status = defaultStatus }
                self.store.addTask(created, attachment: attachmentChange)
            }
            self.render()
        }
        // GL-06: the editor's own Delete button confirms through the exact
        // same path every other delete affordance on this page uses. Deferred
        // a runloop turn because the sheet dismisses itself the moment this
        // closure returns, and running a modal alert on a sheet that is
        // mid-teardown stacks one window on another - the same fix
        // `HostsController`'s own key editor carries.
        editor.onDelete = { [weak self] id in
            DispatchQueue.main.async { self?.confirmDeleteTask(id: id) }
        }
        presentAsSheet(editor)
    }

    private func presentFollowUpEditor(for followUp: ShiftFollowUp?) {
        let editor = ShiftFollowUpEditorController(followUp: followUp, tasks: store.activeTasks, projects: store.projects)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if followUp != nil {
                self.store.updateFollowUp(saved)
            } else {
                self.store.addFollowUp(saved)
            }
            self.render()
        }
        presentAsSheet(editor)
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

    var debugBoardView: ShiftBoardView? { boardView }
    var debugProjectFilterBar: ShiftProjectFilterBar? { projectFilterBar }
    var debugBoardIsVisible: Bool { !boardSection.isHidden }
    var debugTaskPanelIsVisible: Bool { !taskPanel.isHidden }

    /// Drives the real toggle's own handler, so a test cannot pass against a
    /// pill wired to nothing.
    func debugSelectTasksView(_ id: String) {
        guard let view = ShiftTasksView(rawValue: id) else { return }
        switchTasksView(view)
    }

    /// The page's one render pass, for a test that has just mutated the store
    /// behind its back.
    func debugRender() { render() }

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

        for tile in statTiles { tile.applyTheme(theme) }
        for tile in headerIconTiles { tile.applyTheme(theme) }
        taskPanel.applyTheme(theme)
        followUpPanel.applyTheme(theme)
        projectsPanel.applyTheme(theme)
        tasksCountBadge.textColor = muted
        followUpsCountBadge.textColor = muted
        projectsCountBadge.textColor = muted
        let badgeFill = ink.withAlphaComponent(0.08)
        for container in countBadgeContainers { container.layer?.backgroundColor = badgeFill.cgColor }
        taskListView.applyTheme(theme)
        followUpListView.applyTheme(theme)
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

        tabs.applyTheme(theme)
        tasksViewToggle.applyTheme(theme)
        projectFilterBar.applyTheme(theme)
        boardView.applyTheme(theme)
        boardHint.textColor = muted

        reviewGreeting.textColor = ink
        reviewSubtitle.textColor = muted
        reviewPushedBackHeader.textColor = ink
        for tile in reviewStatTiles { tile.applyTheme(theme) }
        reviewPushedBackPanel.applyTheme(theme)
    }
}
