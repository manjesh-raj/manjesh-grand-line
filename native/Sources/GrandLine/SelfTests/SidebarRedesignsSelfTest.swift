// Grand Line - native macOS app.
//
// Stage 7 of the modular-shell migration, on the real off-screen shells: the
// captain's six items, as the pages draw and drive them.
//
//   1. **The sidebar** draws every module at the Large source-list size, and
//      every name and badge fits the column with nothing truncated, in Dusk
//      and Daylight; the whole list fits a 950pt window.
//   2. **Quick Connect** on Console is its caption and two icons: Hosts opens
//      Connections' quick-connect field, Console focuses Console's session and
//      opens one only when there is none (the captain's Option B), and the
//      caption's menu form does what Quick Connect did.
//   3. **Tasks**: no page column, the filter row in its place (every scope,
//      the project filter, Follow-ups, the sort and the Done window), New
//      task at the toolbar's far right, the prototype's board lanes and cards,
//      the List tab as one table that completes and reopens a task through
//      its check, Follow-ups as the same table with the same ⋯ menu (Delete
//      included) and an editor sheet with the task editor's Delete, the
//      calendar's month card, and Weekly review's five cards.
//   4. **Setup**: the summary row on all four tabs; Updates as one table of
//      tools grouped by source, with Update only where there is one and
//      Check for updates at the far right; Setup steps as a list with Details
//      and the current step's own action; Automation's switches; GitHub
//      sync's paused-push card (only for a confirmed public repo) over the
//      forks table, and a subtitle that never says "all in sync" over checks
//      that failed.
//   5. **The floating bar is unchanged** on every one of those pages, except
//      the GitHub sync subtitle's fix, which is the same in both.
//
// Knowledge with no tree is `PageRedesignsSelfTest`'s, beside the rest of
// Knowledge.
//
// It runs no real check: tool checks come from a fixture through
// `DependencyCheckCache.checkOverrideForTests`, `gh` and `av` are refused in a
// self-test process (`ExternalToolGuard`), every Console session it starts
// is `/usr/bin/true`, and every store a page it mounts can write is the
// suite's own, fingerprinted either side.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_SIDEBAR_REDESIGNS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SidebarRedesignsSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        DependencyCheckCache.checkOverrideForTests = fixtureCheck
        defer { DependencyCheckCache.checkOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let savedCounts = BackgroundSignalsPoller.shared.lastCounts
        defer { BackgroundSignalsPoller.shared.debugSetCounts(savedCounts) }
        defer { ConfigRepoPrivacy.debugReset() }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-redesigns-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Every shell a Console starts in this run is `/usr/bin/true` in the
        // scratch directory, the shared console's own first tab included, so
        // not even a login shell's rc files of the captain's run.
        let savedEnvironment = ["SHELL", "FM_SHELL_CWD"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("SHELL", "/usr/bin/true", 1)
        setenv("FM_SHELL_CWD", scratch.path, 1)
        defer {
            for (name, value) in savedEnvironment {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            do {
                let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                resize(window, width: 1512, shell)
                ReviewTourLab.seedDemoTasks(shell.workspace.shiftStore)
                settle(shell)
                for check in [checkTheSidebar, checkQuickConnect, checkTasksBoard, checkTasksList, checkTasksFollowUps,
                              checkTasksReview,
                              checkUpdates, checkGitHubSync, checkSetupSteps, checkAutomation, checkTheSummaryRow] {
                    var ok = true
                    check(shell, window, &ok)
                    allOK = allOK && ok
                }
            }
            do {
                var ok = true
                checkTheFloatingBarIsUnchanged(&ok)
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "SidebarRedesignsSelfTest: all checks passed" : "SidebarRedesignsSelfTest: FAILED")
        return allOK
    }

    /// Every tool's check, from a fixture: three of them say something other
    /// than "up to date".
    private static func fixtureCheck(_ item: DependencyItem) -> CheckOutcome {
        switch item.id {
        case "quota-axi":
            return CheckOutcome(installedLabel: "0.1.65", latestLabel: "0.1.66", status: .updateAvailable,
                                detail: "0.1.65 \u{2192} 0.1.66", log: "fixture")
        case "gh":
            return CheckOutcome(installedLabel: "not installed", latestLabel: "2.78.0", status: .notInstalled,
                                detail: "Not installed - 2.78.0 available", log: "fixture")
        case "claude-code":
            return CheckOutcome(installedLabel: "2.1.308", latestLabel: nil, status: .checkFailed,
                                detail: "Installed 2.1.308 - Homebrew could not read the latest version", log: "fixture")
        default:
            return CheckOutcome(installedLabel: "1.0.0", latestLabel: "1.0.0", status: .upToDate,
                                detail: "1.0.0 - up to date", log: "fixture")
        }
    }

    // MARK: 1 - The sidebar

    private static func checkTheSidebar(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        // The column's width is its own, not the window's: 236pt unless the
        // captain drags it, down to 200pt at the least. (A window too narrow
        // for the column and the page's 940pt floor - 1100pt is one - puts
        // the sidebar away rather than squeezing it.) So the rows have to fit
        // at both widths, in both themes.
        guard let split = shell.debugSidebarPane?.superview as? NSSplitView, let pane = shell.debugSidebarPane else {
            fail("the shell has no split view to size the sidebar in", &ok)
            return
        }
        // The divider sits at the pane's edge, and the pane is the sidebar
        // plus its inset (measured 244pt for the 236pt sidebar).
        let inset = pane.frame.width - shell.debugSidebarWidth
        defer {
            split.setPosition(MainSplitShellController.sidebarWidth + inset, ofDividerAt: 0)
            settle(shell)
        }
        for column in [MainSplitShellController.sidebarWidth, MainSplitShellController.sidebarMinimum] {
            split.setPosition(column + inset, ofDividerAt: 0)
            settle(shell)
            check(abs(shell.debugSidebarWidth - column) < 0.5,
                  "the sidebar is \(shell.debugSidebarWidth)pt, the check wants it at \(column)pt", &ok)
            for themeID in ["dusk", "daylight"] {
                guard let theme = HelmTheme.theme(id: themeID) else {
                    fail("no \(themeID) theme", &ok)
                    continue
                }
                ThemeManager.shared.setTheme(theme)
                settle(shell)
                let tag = "[\(themeID), \(Int(column))pt]"
                for module in WorkspaceSidebarModel.listedModules() {
                    guard let cell = shell.sidebar.debugCell(for: .module(module)) as? WorkspaceSidebarPageCell else {
                        fail("\(tag) the sidebar draws no row for \(module.title)", &ok)
                        continue
                    }
                    cell.layoutSubtreeIfNeeded()
                    let row = cell.frame.height
                    check(abs(row - HelmType.scaledRowHeight(WorkspaceSidebarMetrics.moduleRowHeight)) < 0.5,
                          "\(tag) \(module.title)'s row is \(row)pt, want the Large size's 32", &ok)
                    check(cell.debugLabel.font?.pointSize == HelmType.scaled(WorkspaceSidebarMetrics.moduleTextSize),
                          "\(tag) \(module.title) is set at \(cell.debugLabel.font?.pointSize ?? 0)pt", &ok)
                    // The layout box, not the frame: an image view showing a
                    // symbol takes its alignment insets from the symbol's own
                    // alignment rect, so its frame is wider and taller than
                    // the 24pt square Auto Layout gives it (measured 24.5 x
                    // 37.5 for Home's house).
                    let icon = cell.debugIcon.alignmentRect(forFrame: cell.debugIcon.frame)
                    let side = HelmType.scaled(WorkspaceSidebarMetrics.iconSide)
                    check(abs(icon.width - side) < 0.5 && abs(icon.height - side) < 0.5,
                          "\(tag) \(module.title)'s icon is \(icon.size), want \(side)pt square", &ok)
                    // Nothing truncated: the name's own width fits its frame.
                    let label = cell.debugLabel
                    check(label.intrinsicContentSize.width <= label.frame.width + 0.5,
                          "\(tag) \(module.title) is truncated (\(label.intrinsicContentSize.width) in "
                              + "\(label.frame.width))", &ok)
                    let badge = cell.badgeView
                    if !badge.isHidden {
                        let frame = badge.convert(badge.bounds, to: cell)
                        check(frame.maxX <= cell.bounds.maxX + 0.5 && frame.minX >= label.frame.maxX - 0.5,
                              "\(tag) \(module.title)'s badge sits outside its row or over its name", &ok)
                    }
                }
            }
        }
        // What a window's height changes is whether the list scrolls: at
        // 950pt the whole list is in sight, Settings included.
        let outline = shell.sidebar.outlineView
        let lastRow = outline.rect(ofRow: outline.numberOfRows - 1)
        let visible = outline.visibleRect
        check(visible.contains(NSPoint(x: lastRow.midX, y: lastRow.maxY - 1)),
              "at 950pt the sidebar's last row is below the fold (\(lastRow.maxY) of \(visible.maxY))", &ok)
    }

    // MARK: 2 - Quick Connect

    private static func checkQuickConnect(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let ids = WorkspaceToolbar.ItemID.quickConnect
        shell.workspace.navigator.show(.console)
        settle(shell)
        let toolbarIDs = shell.toolbar.debugItemIdentifiers
        let positions = ids.compactMap { toolbarIDs.firstIndex(of: $0) }
        check(positions.count == 2 && positions[1] - positions[0] == 1,
              "Console's toolbar does not show Console, then Hosts: \(toolbarIDs.map(\.rawValue))", &ok)
        // Adjacent icons share one capsule, so a space keeps the two icons
        // their own group rather than the first two of the trailing cluster.
        check(positions.count == 2 && positions[1] + 2 < toolbarIDs.count && toolbarIDs[positions[1] + 1] == .space
                && toolbarIDs[positions[1] + 2] == WorkspaceToolbar.ItemID.theme,
              "Quick Connect's icons are not their own group at the head of the trailing cluster: \(toolbarIDs.map(\.rawValue))", &ok)
        check(shell.toolbar.debugModuleActionButton == nil, "Console still draws a one-button Quick Connect", &ok)

        // Hosts: the quick-connect host picker, as Quick Connect always was.
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectHosts), "the Hosts icon has no action", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .hosts && shell.currentModule == .connections,
              "the Hosts icon opened \(String(describing: shell.debugCurrentDestination))", &ok)

        // Console (the captain's Option B): a session only when Console has
        // none, and after that the one it has, with the keyboard in it. The
        // tour lab's console opens nothing of its own as it loads (the real
        // app's shared console always has its Firstmate shell), so the first
        // click is the open half and the second the focus half.
        shell.workspace.navigator.show(.console)
        settle(shell)
        let console = shell.workspace.console
        check(console.tabs.isEmpty, "Console starts with a session - the open half would pass vacuously", &ok)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectConsole), "the Console icon has no action", &ok)
        settle(shell)
        let opened = console.tabs.map(\.id)
        if opened.count == 1, case .shell(let executable, _, _)? = console.tabs.first?.launch {
            check(executable == "/usr/bin/true", "the suite's session runs \(executable), not /usr/bin/true", &ok)
        } else {
            fail("with no session the Console icon opened \(opened.count)", &ok)
        }
        guard let session = console.currentTab else {
            fail("the Console icon left Console with no current session", &ok)
            return
        }
        // The keyboard goes into the session only while the app is unlocked:
        // the icon's path is Console's own gated focus (GL-09), and a
        // self-test process starts locked, as the app does.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        for locked in [true, false] {
            AppLockGate.shared.setLocked(locked)
            window.makeFirstResponder(nil)
            check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectConsole), "the Console icon has no action", &ok)
            settle(shell)
            check(shell.debugCurrentDestination == .console && console.tabs.map(\.id) == opened
                    && console.currentTab === session,
                  "with a session the Console icon opened another (\(console.tabs.count) tabs)", &ok)
            let focused = window.firstResponder === console.focusedTerminal(of: session)
            check(focused != locked,
                  locked ? "the Console icon put the keyboard into a terminal behind the lock"
                         : "the Console icon left the keyboard in \(String(describing: window.firstResponder))", &ok)
        }

        // U-02: Quick Connect is on every module now, the same two icons in
        // the same place - `ReviewTwoUXSelfTest` walks every module.
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        check(ids.allSatisfy(shell.toolbar.debugItemIdentifiers.contains),
              "Quick Connect is missing on Home: \(shell.toolbar.debugItemIdentifiers.map(\.rawValue))", &ok)
    }

    // MARK: 3 - Tasks

    private static func checkTasksBoard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        shell.workspace.navigator.show(.shift)
        settle(shell)
        clickTab("Board", shell)
        check(tasks.drawsSidebarLayout, "Tasks did not adopt its sidebar presentation", &ok)
        check(!tasks.debugSidebarIsVisible, "Tasks still draws its own page column beside the board", &ok)
        let row = tasks.debugWorkspaceFilterRow
        check(!row.isHidden && row.window != nil, "Tasks has no filter row", &ok)

        // New task at the toolbar's far right, after Search.
        let ids = shell.toolbar.debugItemIdentifiers
        check(shell.toolbar.debugPrimaryAction === tasks.debugNewTaskButton && ids.last == WorkspaceToolbar.ItemID.primaryAction
                && ids.firstIndex(of: WorkspaceToolbar.ItemID.primaryAction) == ids.firstIndex(of: WorkspaceToolbar.ItemID.search).map { $0 + 1 },
              "New task is not the toolbar's last item, after Search: \(ids.map(\.rawValue))", &ok)
        check(!shell.toolbar.debugPageActions.contains { $0 === tasks.debugNewTaskButton }, "New task is drawn twice", &ok)

        // The column's scopes, through the filter row's own control.
        let counts = tasks.counts()
        check(tasks.debugScopeFilter.selected == "all", "the filter row does not start on All tasks", &ok)
        tasks.debugScopeFilter.debugClickTab(id: "due_today")
        settle(shell)
        check(tasks.debugTaskScope == "due_today", "the Due today filter did not filter", &ok)
        let dueToday = tasks.debugVisibleTaskIDs(.backlog) + tasks.debugVisibleTaskIDs(.inProgress)
        check(dueToday.count == counts.dueToday && counts.dueToday > 0,
              "Due today shows \(dueToday.count) cards, the count says \(counts.dueToday)", &ok)
        tasks.debugScopeFilter.debugClickTab(id: "all")
        settle(shell)

        // The project filter, through the popup's own action.
        guard let project = shell.workspace.shiftStore.projects.first else {
            fail("the demo tasks have no project", &ok)
            return
        }
        tasks.debugPickProject(id: project.id)
        settle(shell)
        let inProject = tasks.debugVisibleTaskIDs(.backlog) + tasks.debugVisibleTaskIDs(.inProgress)
        let projectOf = Dictionary(shell.workspace.shiftStore.activeTasks.map { ($0.id, $0.projectID) }, uniquingKeysWith: { a, _ in a })
        check(tasks.debugProjectFilter == project.id && !inProject.isEmpty && inProject.allSatisfy { projectOf[$0] == project.id },
              "picking \(project.name) did not filter the board to it", &ok)
        tasks.debugPickProject(id: nil)
        settle(shell)
        check(tasks.debugProjectFilter == nil, "All projects did not clear the filter", &ok)

        // Follow-ups: the column's jump, now the row's.
        check(tasks.debugFollowUpsJump.title.hasPrefix("Follow-ups"), "the Follow-ups jump is missing", &ok)

        // The prototype's lanes: each a tint hugging its own cards.
        guard let lanes = tasks.debugBoardView?.debugColumnViews, lanes.count == 3 else {
            fail("the board has no lanes", &ok)
            return
        }
        check(lanes.allSatisfy(\.usesWorkspaceStyle) && lanes.flatMap(\.debugCardViews).allSatisfy(\.usesWorkspaceStyle),
              "the board's lanes or cards are the floating bar's", &ok)
        let heights = lanes.map { $0.debugLaneBackground.frame.height }
        let fullest = lanes.map { $0.debugCardViews.count }
        if let most = fullest.max(), let least = fullest.min(), most > least,
           let tall = fullest.firstIndex(of: most), let short = fullest.firstIndex(of: least) {
            check(heights[short] < heights[tall] - 20,
                  "every lane is as tall as the fullest (\(heights)) - a lane should hug its cards", &ok)
        }
    }

    private static func checkTasksList(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        clickTab("List", shell)
        let table = tasks.debugTasksTable
        check(!table.card.isHidden && table.card.window != nil, "the List tab draws no table", &ok)
        let records = table.debugRows.filter(\.isRecord)
        let store = shell.workspace.shiftStore
        check(records.count >= store.activeTasks.count, "the table lists \(records.count) tasks of \(store.activeTasks.count)", &ok)
        check(table.debugHeaderTitles.contains("Task") && table.debugHeaderTitles.contains("Due"),
              "the table's columns are \(table.debugHeaderTitles)", &ok)
        guard let first = records.first, let key = first.key, case .view(let view)? = first.cells["done"],
              let badge = view as? ShiftTaskCheckBadge else {
            fail("a task row has no check", &ok)
            return
        }
        let menu = table.debugMenuTitles(key: key)
        for title in ["Open Task\u{2026}", "Mark Done", "Push to Tomorrow", "Delete Task\u{2026}"] {
            check(menu.contains(title), "a task row's menu lacks \(title): \(menu)", &ok)
        }
        // The check completes a task and reopens it, through its own button.
        badge.performClick(nil)
        settle(shell)
        check(!store.activeTasks.contains { $0.id == key }, "the check did not complete the task", &ok)
        let reopened = tasks.debugTasksTable.debugRows.first { $0.key == key }
        if case .view(let view)? = reopened?.cells["done"], let badge = view as? ShiftTaskCheckBadge {
            badge.performClick(nil)
            settle(shell)
            check(store.activeTasks.contains { $0.id == key }, "the check did not reopen the task", &ok)
        } else {
            fail("the completed task left the table", &ok)
        }
        check(tasks.debugWorkspaceFilterRow.arrangedSubviews.contains { $0 === tasks.debugSortPopup },
              "the sort left the filter row", &ok)
    }

    /// Follow-ups are the List tab's table too: a check, the columns and a ⋯
    /// on hover whose menu deletes, through GL-06's confirm. The flat list
    /// they used to be offered Delete only on a right click, so a captain saw
    /// a follow-up they could tick off and nothing else. The editor sheet
    /// carries the task editor's Delete as well.
    private static func checkTasksFollowUps(_ shell: MainSplitShellController, _ window: NSWindow,
                                            _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        let store = shell.workspace.shiftStore
        // A follow-up of the suite's own, so deleting it leaves the seeded two
        // for every check after this one.
        var mine = ShiftFollowUp.fresh()
        mine.title = "Chase the vendor about the renewal quote"
        mine.followUpAt = ShiftDateFormatting.components(from: Date()).dateStr
        store.addFollowUp(mine)
        clickTab("Board", shell)
        tasks.render()
        settle(shell)

        let table = tasks.debugFollowUpsTable
        check(!table.card.isHidden && table.card.window != nil, "the Follow-ups card is not on the Board page", &ok)
        check(table.debugHeaderTitles.contains("Follow-up") && table.debugHeaderTitles.contains("Due"),
              "the Follow-ups table's columns are \(table.debugHeaderTitles)", &ok)
        let keys = table.debugRows.compactMap(\.key)
        check(Set(keys) == Set(store.followUps.map(\.id)),
              "the Follow-ups table lists \(keys.count) of \(store.followUps.count) follow-ups", &ok)
        guard let row = table.debugRows.first(where: { $0.key == mine.id }) else {
            fail("the new follow-up has no row", &ok)
            return
        }
        guard case .view(let view)? = row.cells["done"], view is ShiftTaskCheckBadge else {
            fail("a follow-up row has no check", &ok)
            return
        }
        let menu = table.debugMenuTitles(key: mine.id)
        for title in ["Open Follow-up\u{2026}", "Mark Done", "Snooze to Tomorrow", "Delete Follow-up\u{2026}"] {
            check(menu.contains(title), "a follow-up row's menu lacks \(title): \(menu)", &ok)
        }
        // The ⋯ a task row shows on hover, and so where Delete can be seen.
        table.debugHover(key: mine.id)
        settle(shell)
        check(table.debugActionsCell(key: mine.id)?.debugRevealed == true,
              "hovering a follow-up shows no \u{22EF} for its actions", &ok)
        table.debugHover(key: nil)

        // Delete asks first (GL-06), and Cancel keeps it.
        var asked: [String] = []
        var answer = HelmConfirm.Response.cancel
        HelmConfirm.responderForTests = { request in
            asked.append(request.title)
            return answer
        }
        defer { HelmConfirm.responderForTests = nil }
        check(table.debugPickMenuItem(key: mine.id, title: "Delete Follow-up\u{2026}"),
              "the menu's Delete Follow-up did not run", &ok)
        settle(shell)
        check(asked == ["Delete \u{201C}\(mine.title)\u{201D}?"], "Delete asked \(asked), not the follow-up's confirm", &ok)
        check(store.followUps.contains { $0.id == mine.id }, "Cancel deleted the follow-up", &ok)
        answer = .confirm
        _ = table.debugPickMenuItem(key: mine.id, title: "Delete Follow-up\u{2026}")
        settle(shell)
        check(!store.followUps.contains { $0.id == mine.id }, "confirming Delete Follow-up did not delete it", &ok)
        check(!tasks.debugFollowUpsTable.debugRows.contains { $0.key == mine.id },
              "the deleted follow-up is still in the table", &ok)

        // The check marks a follow-up done, and back, through its own button.
        if let first = store.followUps.first,
           case .view(let view)? = tasks.debugFollowUpsTable.debugRows.first(where: { $0.key == first.id })?.cells["done"],
           let badge = view as? ShiftTaskCheckBadge {
            let wasDone = first.status == .done
            badge.performClick(nil)
            settle(shell)
            check(store.followUps.first { $0.id == first.id }.map { ($0.status == .done) != wasDone } == true,
                  "the check did not change the follow-up's status", &ok)
            if case .view(let view)? = tasks.debugFollowUpsTable.debugRows.first(where: { $0.key == first.id })?.cells["done"],
               let badge = view as? ShiftTaskCheckBadge {
                badge.performClick(nil)
                settle(shell)
            }
            check(store.followUps.first { $0.id == first.id }.map { ($0.status == .done) == wasDone } == true,
                  "the check did not put the follow-up back", &ok)
        } else {
            fail("the seeded follow-ups have no check", &ok)
        }

        // The editor sheet: an existing follow-up's has the task editor's
        // Delete, which hands its owner the id; a new one's has none.
        guard let existing = store.followUps.first else {
            fail("the seeded follow-ups are gone", &ok)
            return
        }
        let editor = ShiftFollowUpEditorController(followUp: existing, tasks: [], projects: [])
        var deletedID: String?
        editor.onDelete = { deletedID = $0 }
        let delete = descendants(HelmButton.self, in: editor.view).first { $0.title == "Delete" }
        check(delete != nil, "the Edit Follow-up sheet has no Delete button", &ok)
        delete?.performClick(nil)
        check(deletedID == existing.id, "the sheet's Delete handed over \(deletedID ?? "nothing")", &ok)
        let fresh = ShiftFollowUpEditorController(followUp: nil, tasks: [], projects: [])
        check(!descendants(HelmButton.self, in: fresh.view).contains { $0.title == "Delete" },
              "the New Follow-up sheet offers Delete for a follow-up that does not exist", &ok)
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// The Calendar is its own sidebar row now (`TaskCalendarSelfTest`), so
    /// Tasks' tabs are three.
    private static func checkTasksReview(_ shell: MainSplitShellController, _ window: NSWindow,
                                         _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        check(tasks.moduleTabNames == ["Board", "List", "Weekly review"],
              "Tasks' tabs are \(tasks.moduleTabNames)", &ok)
        clickTab("Weekly review", shell)
        check(tasks.debugWorkspaceFilterRow.isHidden, "the filter row shows over Weekly review", &ok)
        let cards = tasks.debugReviewCards
        check(cards.map(\.debugCaption) == ["Completed this week", "Focus time", "Overdue", "Follow-ups open",
                                            "Coming up next week"],
              "Weekly review's cards are \(cards.map(\.debugCaption))", &ok)
        let summary = shell.workspace.shiftStore.weeklySummary()
        check(cards[0].debugValue == "\(summary.completedCount)" && cards[0].debugDetail?.isEmpty == false,
              "Completed this week reads \(cards[0].debugValue), want \(summary.completedCount) and a comparison", &ok)
        check(cards[2].debugValue == "\(tasks.counts().overdue)", "Overdue reads \(cards[2].debugValue)", &ok)
        // The floating bar's strip counts the tasks pushed back 2+ times; here
        // that figure is the Pushed back panel's own count.
        check(tasks.debugPushedBackCount == "\(summary.pushedBack.count)",
              "Pushed back repeatedly counts \(tasks.debugPushedBackCount ?? "nothing"), "
                  + "want \(summary.pushedBack.count)", &ok)
        // Focus time is the focus log's: none, then what was logged.
        check(cards[1].debugValue == "None yet", "Focus time with no sessions reads \(cards[1].debugValue)", &ok)
        if let task = shell.workspace.shiftStore.activeTasks.first {
            shell.workspace.shiftStore.logFocusSession(taskID: task.id, taskTitle: task.title, seconds: 3000)
            clickTab("Board", shell)
            clickTab("Weekly review", shell)
            check(cards[1].debugValue == FocusTimerFormat.total(3000) && cards[1].debugDetail?.contains("1 task") == true,
                  "Focus time reads \(cards[1].debugValue) / \(cards[1].debugDetail ?? "-") after a 50 minute session", &ok)
        }
        // Back from Weekly review is where the floating bar's column returns
        // (the review puts it away), so it is where it would come back here.
        clickTab("Board", shell)
        check(!tasks.debugSidebarIsVisible, "back on Board from Weekly review, Tasks draws its page column again", &ok)
    }

    // MARK: 4 - Setup

    private static func checkUpdates(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let updates = shell.workspace.updates
        shell.workspace.navigator.show(.updates)
        settle(shell)
        _ = waitUntil(timeout: 10) {
            updates.debugToolsTable.debugRows.filter(\.isRecord).count == DependencyCatalog.items.count
                && !updates.debugToolsTable.debugRows.contains { row in
                    if case .muted(let text)? = row.cells["available"] { return text.hasPrefix("Checking") }
                    return false
                }
        }
        check(updates.debugDrawsSidebarLayout && !updates.debugCategoryCardsShown && !updates.debugStatsStripShown,
              "Updates still draws its category cards or its stat strip", &ok)
        check(updates.debugSetupSummary.window != nil, "Updates has no summary row", &ok)
        let rows = updates.debugToolsTable.debugRows
        let groups = rows.compactMap { row -> String? in
            if case .group(let name) = row.kind { return name }
            return nil
        }
        check(groups == DependencyCatalog.categoryOrder.filter { category in
            DependencyCatalog.items.contains { $0.category == category } },
              "the table's groups are \(groups)", &ok)
        func row(_ id: String) -> HelmDataTable.Row? { rows.first { $0.key == id } }
        if let quota = row("quota-axi") {
            if case .status(let text, let tint)? = quota.cells["available"] {
                check(text.contains("0.1.66") && tint == .warn, "quota-axi's update reads \(text)", &ok)
            } else {
                fail("quota-axi's available version is not drawn", &ok)
            }
            check(quota.primary?.title == "Update" && quota.pinsPrimary, "quota-axi offers \(quota.primary?.title ?? "nothing")", &ok)
        } else {
            fail("the table has no quota-axi", &ok)
        }
        check(row("gh")?.primary?.title == "Install in \(PlaceName.short(.bootstrap))", "gh offers \(row("gh")?.primary?.title ?? "nothing")", &ok)
        if let up = row("tasks-axi") {
            check(up.primary == nil, "an up-to-date tool offers \(up.primary?.title ?? "")", &ok)
            if case .muted(let text)? = up.cells["available"] { check(text == "Up to date", "tasks-axi reads \(text)", &ok) }
            if case .code(let text)? = up.cells["installed"] { check(text == "1.0.0", "tasks-axi's version reads \(text)", &ok) }
        }

        // The filter row: Needs Attention, then the tool filter.
        updates.debugSetFilter(needsAttention: true)
        settle(shell)
        let attention = updates.debugToolsTable.debugRows.compactMap(\.key)
        check(Set(attention) == ["quota-axi", "gh", "claude-code"], "Needs Attention lists \(attention)", &ok)
        updates.debugSetFilter(needsAttention: false)
        updates.debugSetQuery("axi")
        settle(shell)
        let axi = updates.debugToolsTable.debugRows.compactMap(\.key)
        check(!axi.isEmpty && axi.allSatisfy { $0.hasSuffix("axi") }, "filtering \"axi\" lists \(axi)", &ok)
        updates.debugSetQuery("")
        settle(shell)

        // Check for updates is the toolbar's primary action, and it is Check all.
        let primary = shell.toolbar.debugPrimaryAction as? HelmButton
        check(primary === updates.debugCheckForUpdatesButton && primary?.title == "Check for updates"
                && primary?.action == NSSelectorFromString("checkAllTapped"),
              "the far-right button is \(primary?.title ?? "missing")", &ok)

        // A tool's detail and its output are the inspector's.
        updates.debugToolsTable.debugSelect(key: "quota-axi")
        settle(shell)
        check(updates.inspectorContent?.title == "quota-axi", "selecting a tool does not fill the inspector", &ok)
        updates.debugToolsTable.debugSelect(key: nil)
    }

    private static func checkGitHubSync(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let github = shell.workspace.githubSync
        ConfigRepoPrivacy.debugReset()
        shell.workspace.navigator.show(.githubSync)
        settle(shell)
        _ = waitUntil(timeout: 15) { !github.debugIsCheckingAll }
        check(github.debugDrawsSidebarLayout && !github.debugReposCardShown, "GitHub sync still draws its Repos card", &ok)
        // GL-14: a test process refuses `gh`, so every check failed - which
        // the subtitle used to report as "all in sync".
        let subtitle = github.drillHeaderSubtitle ?? ""
        check(!subtitle.contains("all in sync") && subtitle.contains("could not be checked"),
              "with every check failed the subtitle reads \"\(subtitle)\"", &ok)
        check(!github.debugPausedCardIsShown, "the paused card shows with no confirmed public repo", &ok)
        ConfigRepoPrivacy.debugRecord(.unknown("offline"))
        settle(shell)
        check(!github.debugPausedCardIsShown, "an unanswered visibility check shows the paused card", &ok)
        ConfigRepoPrivacy.debugRecord(.publicRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        settle(shell)
        check(github.debugPausedCardIsShown && github.debugPausedTitle == "Pushing is paused"
                && github.debugPausedActions.map(\.title) == ["Open on GitHub", "Check again"],
              "a public config repo does not show the paused card with its two actions", &ok)
        let notice = github.debugPausedNotice
        let card = notice.convert(notice.bounds, to: nil)
        for button in github.debugPausedActions {
            let frame = button.convert(button.bounds, to: nil)
            check(card.contains(frame), "\(button.title) is drawn outside the paused card", &ok)
        }
        ConfigRepoPrivacy.debugRecord(.privateRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        settle(shell)
        check(!github.debugPausedCardIsShown, "the paused card stayed after the repo was private", &ok)

        // The forks table: one row each, Sync only on one behind.
        let records = github.debugForksTable.debugRows.filter(\.isRecord)
        check(records.count == GitHubSyncCatalog.repos.count, "the table lists \(records.count) forks", &ok)
        github.debugApplyCheck(index: 0, status: .behind(3), upstream: "kunchenguid/x")
        settle(shell)
        let behind = github.debugForksTable.debugRows.first { $0.key == GitHubSyncCatalog.repos[0].fullName }
        if case .status(let text, _)? = behind?.cells["behind"] {
            check(text == "3 commits", "a fork 3 behind reads \(text)", &ok)
        } else {
            fail("a fork behind draws no count", &ok)
        }
        check(behind?.primary?.title == "Sync" && behind?.pinsPrimary == true, "a fork behind offers no Sync", &ok)
        check(shell.toolbar.debugPrimaryAction === github.debugSyncAllButton, "Sync all is not the far-right button", &ok)
        check(shell.toolbar.debugPageActions.contains { $0 === github.debugRefreshButton }, "Refresh left the toolbar", &ok)
    }

    private static func checkSetupSteps(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let steps = shell.workspace.bootstrap
        shell.workspace.navigator.show(.bootstrap)
        settle(shell)
        check(steps.debugDrawsSidebarLayout && !steps.debugFullSetupCardShown, "Setup steps still draws its own run card", &ok)
        check(shell.toolbar.debugPrimaryAction === steps.debugRunFullSetupButton, "Run full setup is not the far-right button", &ok)
        for kind in SetupStepKind.allCases {
            guard let details = steps.debugDetailsButton(kind) else {
                fail("\(kind.title) has no Details", &ok)
                continue
            }
            check(!steps.debugStepContentIsShown(kind), "\(kind.title)'s controls are open by default", &ok)
            details.performClick(nil)
            settle(shell)
            check(steps.debugStepContentIsShown(kind) && details.title == "Hide details",
                  "Details did not open \(kind.title)'s controls", &ok)
            details.performClick(nil)
            settle(shell)
            check(!steps.debugStepContentIsShown(kind), "Hide details did not close \(kind.title)'s controls", &ok)
            // The step's own action shows on the current step and nowhere else.
            if let action = steps.debugStepActionButton(kind), !action.isHidden {
                check(steps.debugStepIsCurrent(kind), "\(kind.title) offers \(action.title) but is not the current step", &ok)
            }
        }
    }

    private static func checkAutomation(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let store = shell.workspace.scheduleStore
        let schedule = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10))
        store.add(schedule)
        defer { store.delete(id: schedule.id) }
        let automation = shell.workspace.automation
        shell.workspace.navigator.show(.automation)
        settle(shell)
        check(automation.debugDrawsSidebarLayout && !automation.debugRunCardShown, "Automation still draws its run card", &ok)
        check(shell.toolbar.debugPrimaryAction === automation.debugRunButton, "Run Automation is not the far-right button", &ok)
        let rows = automation.debugAutomationRows
        let titles = rows.map(\.titleLabel.stringValue)
        for title in [ScheduledActionKind.forkSync.title, "Commit and push dotfiles changes automatically",
                      "Reconnect dropped terminal sessions"] {
            check(titles.contains(title), "the Automation card lacks \(title): \(titles)", &ok)
        }
        // A schedule's switch writes the store the Schedules page reads.
        guard let row = rows.first(where: { $0.titleLabel.stringValue == ScheduledActionKind.forkSync.title }),
              let toggle = row.control as? HelmToggle else {
            fail("the schedule's row has no switch", &ok)
            return
        }
        check(toggle.isOn, "an enabled schedule's switch is off", &ok)
        toggle.isOn = false
        toggle.onToggle?()
        settle(shell)
        check(store.schedule(id: schedule.id)?.isEnabled == false, "the switch did not pause the schedule", &ok)
    }

    /// The same five figures on all four tabs, from the same readings.
    private static func checkTheSummaryRow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        var counts = BackgroundSignalsPoller.SignalCounts()
        counts.toolsTotal = 8
        counts.toolsUpToDate = 6
        counts.toolsWithUpdate = 2
        counts.toolUpdates = 2
        counts.setupDrift = 1
        counts.forksTotal = 8
        counts.forksChecked = 8
        counts.forkDrift = 0
        BackgroundSignalsPoller.shared.debugSetCounts(counts)
        // Newer than anything the scratch pages answer for themselves, so
        // the fixture is what every tab reads.
        var steps: [SetupStepKind: Bool?] = [:]
        for (index, kind) in SetupStepKind.allCases.enumerated() { steps[kind] = index != 1 }
        SetupStepsReading.shared.record(steps, gatheredAt: Date().addingTimeInterval(3600))
        defer { SetupStepsReading.shared.resetForTests() }
        DotfilesAutoSync.shared.debugSetStatus(.synced)
        ConfigRepoPrivacy.debugRecord(.publicRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let want = ["6 / 8", "2", "4 / 5", "Synced", "Paused"]
        let rows: [(String, SetupSummaryRow)] = [
            ("Updates", shell.workspace.updates.debugSetupSummary),
            ("Setup steps", shell.workspace.bootstrap.debugSetupSummary),
            ("Automation", shell.workspace.automation.debugSetupSummary),
            ("GitHub sync", shell.workspace.githubSync.debugSetupSummary),
        ]
        for (name, row) in rows {
            check(row.debugValues == want, "\(name)'s summary reads \(row.debugValues), want \(want)", &ok)
        }
        // R2-BUG-05: both step tabs' subtitles state the reading the card
        // renders, whichever tab computed last.
        let subtitles = [shell.workspace.bootstrap.drillHeaderSubtitle, shell.workspace.automation.drillHeaderSubtitle]
        check(subtitles.allSatisfy { $0 == "4 of 5 steps done" },
              "the Setup tabs' subtitles read \(subtitles) beside a \"4 / 5\" card", &ok)
    }

    // MARK: 5 - The floating bar

    private static func checkTheFloatingBarIsUnchanged(_ ok: inout Bool) {
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        ReviewTourLab.seedDemoTasks(shell.workspace.shiftStore)
        settle(shell)
        let tasks = shell.workspace.shift
        shell.workspace.navigator.show(.shift)
        settle(shell)
        check(!tasks.drawsSidebarLayout && tasks.debugSidebarIsVisible && !tasks.debugViewTabs.isHidden
                && tasks.workspacePrimaryAction == nil,
              "the floating bar's Tasks lost its column or its view switch", &ok)
        check(tasks.debugBoardView?.debugColumnViews.allSatisfy { !$0.usesWorkspaceStyle } == true,
              "the floating bar's board takes the sidebar layout's lanes", &ok)
        check(tasks.debugPushedBackCount == nil, "the floating bar's review draws the sidebar layout's count", &ok)
        for route in [RailDestination.updates, .bootstrap, .automation, .githubSync] {
            shell.workspace.navigator.show(route)
            settle(shell)
        }
        let updates = shell.workspace.updates
        check(!updates.debugDrawsSidebarLayout && updates.debugCategoryCardsShown && updates.workspacePrimaryAction == nil,
              "the floating bar's Updates changed", &ok)
        check(!shell.workspace.bootstrap.debugDrawsSidebarLayout && shell.workspace.bootstrap.debugFullSetupCardShown,
              "the floating bar's Bootstrap changed", &ok)
        check(!shell.workspace.automation.debugDrawsSidebarLayout && shell.workspace.automation.debugRunCardShown,
              "the floating bar's Automation changed", &ok)
        let github = shell.workspace.githubSync
        _ = waitUntil(timeout: 15) { !github.debugIsCheckingAll }
        check(!github.debugDrawsSidebarLayout && github.debugReposCardShown && !github.debugPausedCardIsShown,
              "the floating bar's GitHub sync changed", &ok)
        check(!(github.drillHeaderSubtitle ?? "").contains("all in sync"),
              "the floating bar's GitHub sync still says all in sync over failed checks", &ok)
        let notebook = shell.workspace.notebook
        shell.workspace.navigator.show(.notebook)
        settle(shell)
        check(notebook.splitPage?.pageForcesCollapse == false, "the floating bar's Notebook lost its page column", &ok)
    }

    // MARK: Helpers

    private static func clickTab(_ name: String, _ shell: MainSplitShellController) {
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return }
        shell.debugClickTab(index)
        settle(shell)
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size = NSSize(width: width, height: 950)
        window.setFrame(frame, display: false)
        settle(shell)
    }

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    /// Pumps the main run loop until `condition()` is true or `timeout`
    /// elapses (`HerdrRestartButtonSelfTest.waitUntil`'s convention).
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

#endif
