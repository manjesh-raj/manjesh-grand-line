// Grand Line - native macOS app.
//
// The Tasks page's redesign (`fm/grand-line-tasks-page-redesign`): the slice
// the page filters by and the project it narrows to, both driven through the
// hero band and its menus (Tf-2), the counts one pass feeds, the page-level
// primary action, and the board column sized so a card is never sliced. The
// page's own nav column that first carried the filters went with the
// floating-bar layout in P-03 of the 2026-11-25 review.
//
// **Why window-backed.** Every check here needs real geometry: a column body's
// height against what its cards really occupy, and a hero band that only
// shows on a mounted page. It sits in `run-all-tests.sh`'s
// `NEEDS_SESSION` list beside its Shift peers.
//
// **What it spends assertions on.** Behaviour a render cannot show and a value
// check cannot re-derive: a filter that filters, a count that comes off the
// same array the tiles were built from, and a completed task that is never
// called overdue. Never on a colour or a spacing - those are taste, and they
// fail for the wrong reason.
//
// Run with `FM_RUN_SHIFT_TASKS_PAGE_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import AppKit

enum ShiftTasksPageSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkDuplicateProjectIDsDoNotCrash(check)

        // MARK: The band's scopes filter the board, and say so honestly

        withScratchStore { store in
            let today = dateString(daysFromNow: 0)
            let past = dateString(daysFromNow: -3)

            let dueToday = seed(store, title: "Due today", status: .todo, due: today)
            let late = seed(store, title: "Late", status: .todo, due: past)
            let undated = seed(store, title: "No date", status: .todo, due: nil)
            let running = seed(store, title: "Running", status: .inProgress, due: today)
            // A finished task whose due date is in the past. It is *not*
            // overdue - it is done - and this is the one case a naive
            // date-only predicate gets wrong.
            let finishedLate = seed(store, title: "Finished late", status: .todo, due: past)
            store.setTaskCompleted(id: finishedLate, completed: true)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            func visible() -> Set<String> {
                var ids: Set<String> = []
                for column in [ShiftBoardColumn.backlog, .inProgress, .done] {
                    ids.formUnion(controller.debugVisibleTaskIDs(column))
                }
                return ids
            }

            check(controller.debugTaskScope == "all",
                  "the page should open on All tasks, got \(controller.debugTaskScope)")
            check(visible() == [dueToday, late, undated, running, finishedLate],
                  "All tasks should show every task, got \(visible().count)")

            pickScope(controller, "due_today", check)
            check(controller.debugTaskScope == "due_today",
                  "clicking Due today should move the scope, got \(controller.debugTaskScope)")
            check(visible() == [dueToday, running],
                  "Due today should show only today's open tasks, got \(visible().count)")

            pickScope(controller, "overdue", check)
            check(visible() == [late],
                  "Overdue should show only the late open task, got \(visible().count)")
            check(!visible().contains(finishedLate),
                  "a completed task is never overdue - it is done")

            pickScope(controller, "all", check)
            check(visible().count == 5,
                  "All tasks should restore the full board, got \(visible().count)")

            // MARK: One counting pass feeds the subtitle and the band (UI-16, UI-18)

            check(controller.debugStatTileCount == 0,
                  "the page should carry no stat tiles (UI-16), found \(controller.debugStatTileCount)")
            let c = controller.counts()
            check(c.open == 4, "open should count the four active tasks, got \(c.open)")
            check(c.dueToday == 2, "due today should be 2, got \(c.dueToday)")
            check(c.overdue == 1, "overdue should be 1, got \(c.overdue)")
            let subtitle = controller.drillHeaderSubtitle ?? ""
            // R5-UX-10: four tasks are "the first few", so the line keeps
            // the empty state's hint after the counts.
            let countsLine = "4 open \u{00B7} 2 due today \u{00B7} \(c.followUps) follow-up\(c.followUps == 1 ? "" : "s") \u{00B7} 1 overdue"
            check(subtitle == "\(countsLine) \u{00B7} \(AppSettings.shared.quickCaptureShortcut.displayString) adds one from any app",
                  "the subtitle should carry all four counts, then the hint, got \"\(subtitle)\"")

            let figures = figureCounts(controller)
            check(figures.count == 4, "the band should draw four figures, got \(figures.count)")
            check(figures.first == "\(c.open)",
                  "the band's All tasks figure must equal the subtitle's, got \(figures.first ?? "nil")")
            check(figures.dropFirst().first == "\(c.dueToday)",
                  "the band's Due today figure must equal the subtitle's, got \(figures.dropFirst().first ?? "nil")")
            check(figures.dropFirst(2).first == "\(c.overdue)",
                  "the band's Overdue figure must equal the subtitle's, got \(figures.dropFirst(2).first ?? "nil")")
        }

        // MARK: Board and Calendar headers agree on overdue (R5-BUG-04)

        // The review's render: one late task and one late follow-up. The
        // Board header said "1 overdue" and the Calendar header "2 overdue",
        // each counting in its own loop.
        withScratchStore { store in
            _ = seed(store, title: "Late task", status: .todo, due: dateString(daysFromNow: -2))
            _ = seed(store, title: "Later task", status: .todo, due: dateString(daysFromNow: 4))
            var lateFollowUp = ShiftFollowUp.fresh()
            lateFollowUp.title = "Late follow-up"
            lateFollowUp.followUpAt = dateString(daysFromNow: -1)
            store.addFollowUp(lateFollowUp)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            let c = controller.counts()
            check(c.overdue == 1 && c.overdueFollowUps == 1,
                  "fixture: one late task and one late follow-up, got \(c.overdue) and \(c.overdueFollowUps)")
            let board = controller.drillHeaderSubtitle ?? ""
            controller.debugSelectTasksView(ShiftController.ShiftTasksView.calendar.rawValue)
            drainMainQueue(turns: 5)
            check(controller.isShowingCalendar, "fixture: the Calendar view did not open")
            let calendar = controller.drillHeaderSubtitle ?? ""
            check(board.contains("\u{00B7} 1 overdue"), "the Board header reads \"\(board)\"")
            check(calendar.contains("\u{00B7} 1 overdue") && !calendar.contains("2 overdue"),
                  "the Calendar header counts overdue differently from the Board's \"\(board)\": \"\(calendar)\"")
            check(calendar.hasSuffix("\u{00B7} 1 follow-up overdue"),
                  "the Calendar header no longer names the late follow-up its tray lists: \"\(calendar)\"")
        }

        // MARK: The counts follow the project filter (UI-18)

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            _ = seed(store, title: "In alpha", status: .todo, due: nil, project: alpha)
            _ = seed(store, title: "Loose", status: .todo, due: nil)
            _ = seed(store, title: "Loose too", status: .todo, due: nil)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            check(controller.counts().open == 3, "unfiltered, all three tasks count")
            controller.debugPickProject(id: alpha)
            drainMainQueue(turns: 5)
            check(controller.counts().open == 1,
                  "filtered to Alpha, only Alpha's task counts, got \(controller.counts().open)")
            check(figureCounts(controller).first == "1",
                  "and the band's All tasks figure follows, got \(figureCounts(controller).first ?? "nil")")
            check((controller.drillHeaderSubtitle ?? "").hasPrefix("Alpha \u{00B7} 1 open"),
                  "and the subtitle names the filter, got \(controller.drillHeaderSubtitle ?? "nil")")
        }

        // MARK: The Follow-ups jump never takes the scope
        //
        // The band's Follow-ups figure scrolls to the Follow-ups card rather
        // than filtering, so it must leave the scope where it was.

        withScratchStore { store in
            _ = seed(store, title: "Anything", status: .todo, due: nil)
            var waiting = ShiftFollowUp.fresh()
            waiting.title = "Waiting on someone"
            store.addFollowUp(waiting)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            // The jump has somewhere to go only while Follow-ups is a card,
            // which the List tab always draws.
            controller.debugSelectTasksView(ShiftController.ShiftTasksView.list.rawValue)
            drainMainQueue(turns: 5)

            pickScope(controller, "due_today", check)
            guard let jump = controller.debugHeroBand?.debugFigureButtons.last else {
                check(false, "the band has no Follow-ups figure")
                return
            }
            check(controller.debugFollowUpsJumps && jump.debugIsActivatable,
                  "fixture: on List the Follow-ups figure should jump to the card")
            check(jump.performPrimaryAction(), "the Follow-ups figure has no click")
            check(controller.debugTaskScope == "due_today",
                  "the jump must leave the scope alone, got \(controller.debugTaskScope)")
            check(controller.debugHeroBand?.debugSelectedFigure == "Due today",
                  "the jump must not become the selected figure, got "
                  + "\(controller.debugHeroBand?.debugSelectedFigure ?? "nil")")
        }

        // MARK: One page-level primary action, the same instance every read

        withScratchStore { store in
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            let buttons = controller.drillHeaderActions.compactMap { $0 as? HelmButton }
            let newTask = buttons.filter { $0.title == "New task" }
            check(newTask.count == 1,
                  "the header should carry exactly one New task action, got \(newTask.count)")
            check(newTask.first?.variant == .primary,
                  "New task is the page's primary action")
            check(newTask.first === (controller.drillHeaderActions.compactMap { $0 as? HelmButton }
                                        .first { $0.title == "New task" }),
                  "the action must be the same instance on every read, never rebuilt per read")
            check(newTask.first?.action != nil && newTask.first?.target != nil,
                  "a button wired to nothing renders perfectly and does nothing")

            // ...and it is not also sitting in the page body.
            var bodyTitles: [String] = []
            walk(controller.view) { if let b = $0 as? HelmButton { bodyTitles.append(b.title) } }
            check(!bodyTitles.contains("New task"),
                  "the primary action belongs to the header cluster, not to both")
        }

        // MARK: Four cards fit without one being sliced

        withScratchStore { store in
            let today = dateString(daysFromNow: 0)
            // Four backlog cards, one of them carrying a meta line - the shape
            // that under-counted the column by a card's worth of pill before
            // the plan became content-aware.
            _ = seed(store, title: "With a due date", status: .todo, due: today)
            for i in 1...3 { _ = seed(store, title: "Plain \(i)", status: .todo, due: nil) }

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            guard let column = controller.debugBoardView?.debugColumn(.backlog) else {
                failures.append("the board has no Backlog column")
                return
            }
            let cards = column.debugCardViews
            check(cards.count == 4, "expected four cards, got \(cards.count)")
            let content = cards.reduce(CGFloat(0)) { $0 + $1.frame.height }
                + HelmMetrics.s2 * CGFloat(max(0, cards.count - 1))
            check(column.debugScrollHeight + 0.5 >= content,
                  "the column body is \(fmt(column.debugScrollHeight))pt for \(fmt(content))pt of cards - "
                  + "the last card is sliced by \(fmt(content - column.debugScrollHeight))pt")

        }

        // MARK: The project menu lists every project, in its own colour
        //
        // The defect this closes: the page once collapsed the whole project
        // set into one "Projects 5" count, so the one place a captain would
        // look to see *which* projects exist showed a number. The band's
        // project menu lists each one, led by its board colour's dot, and
        // "All projects" carries none.

        withScratchStore { store in
            let names = ["Grand Line", "Deploy engine", "Pramata Platform"]
            let ids = names.map { seedProject(store, name: $0) }

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            let menu = controller.projectMenu()
            let picks = menu.items.filter { $0.action != nil }

            check(picks.map(\.title) == ["All projects"] + names,
                  "the menu should list All projects, then every project, got \(picks.map(\.title))")
            check(picks.first?.image == nil, "All projects is not a project and wears no dot")
            for (index, name) in names.enumerated() {
                guard let item = picks.first(where: { ($0.representedObject as? String) == ids[index] }) else {
                    check(false, "the menu has no item for \"\(name)\"")
                    continue
                }
                check(item.image != nil, "\(name) should be led by its colour's dot")
            }
        }

        withScratchStore { store in
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            let picks = controller.projectMenu().items.filter { $0.action != nil }
            check(picks.map(\.title) == ["All projects"],
                  "an empty project set lists only All projects, got \(picks.map(\.title))")
        }

        // MARK: Picking a project filters the board, and All projects clears it
        //
        // One filter, one control - never two filters. The chip row that once
        // repeated the project filter above the board is gone (UI-17).

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            let beta = seedProject(store, name: "Beta")
            let inAlpha = seed(store, title: "In alpha", status: .todo, due: nil, project: alpha)
            let inBeta = seed(store, title: "In beta", status: .todo, due: nil, project: beta)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugPickProject(id: alpha)
            drainMainQueue(turns: 5)
            check(controller.debugProjectFilter == alpha,
                  "picking a project filters by it, got \(controller.debugProjectFilter ?? "nil")")
            check(controller.debugVisibleTaskIDs(.backlog) == [inAlpha],
                  "the board should show only Alpha's task, got \(controller.debugVisibleTaskIDs(.backlog))")
            check(!controller.debugHasProjectChipRow,
                  "the project menu is the one project filter - no chip row repeats it (UI-17)")
            check(checkedProject(controller) == alpha,
                  "the picked project is the one the menu checks, got \(checkedProject(controller) ?? "All projects")")

            controller.debugPickProject(id: nil)
            drainMainQueue(turns: 5)
            check(controller.debugProjectFilter == nil,
                  "All projects clears the filter")
            check(Set(controller.debugVisibleTaskIDs(.backlog)) == Set([inAlpha, inBeta]),
                  "clearing it shows every project again")
        }

        // MARK: A project and a slice are orthogonal
        //
        // They are two one-of-many questions with two controls: picking a
        // project must not un-pick the slice.

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            _ = seed(store, title: "Due today, alpha", status: .todo,
                     due: dateString(daysFromNow: 0), project: alpha)
            _ = seed(store, title: "Undated, alpha", status: .todo, due: nil, project: alpha)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            pickScope(controller, "due_today", check)
            controller.debugPickProject(id: alpha)
            drainMainQueue(turns: 5)
            check(controller.debugTaskScope == "due_today",
                  "picking a project must leave the slice alone, got \(controller.debugTaskScope)")
            // Read off what the controls really draw as chosen.
            check(controller.debugHeroBand?.debugSelectedFigure == "Due today"
                    && checkedProject(controller) == alpha,
                  "the slice and the project must both render chosen, got "
                  + "\(controller.debugHeroBand?.debugSelectedFigure ?? "nil") and "
                  + "\(checkedProject(controller) ?? "All projects")")
            check(controller.debugVisibleTaskIDs(.backlog).count == 1,
                  "both filters apply at once, got \(controller.debugVisibleTaskIDs(.backlog).count) task(s)")
        }

        // MARK: Smart views are backed by fields the record really carries

        withScratchStore { store in
            let hot = seedPriority(store, title: "Hot", priority: .high)
            _ = seedPriority(store, title: "Ordinary", priority: .normal)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            pickScope(controller, "my_priorities", check)
            check(controller.debugVisibleTaskIDs(.backlog) == [hot],
                  "My priorities is the captain's own high-priority mark, got "
                  + "\(controller.debugVisibleTaskIDs(.backlog))")

            // Everything seeded here was written moments ago, so the window is
            // exercised by what it *keeps*, and the assertion that matters is
            // that the slice is a real filter rather than a relabelled "all".
            pickScope(controller, "recently_updated", check)
            check(controller.debugVisibleTaskIDs(.backlog).count == 2,
                  "a task written seconds ago is recently updated, got "
                  + "\(controller.debugVisibleTaskIDs(.backlog).count)")
        }

        // MARK: The filter survives leaving the page and coming back

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugPickProject(id: alpha)
            drainMainQueue(turns: 5)
            controller.showWeeklyReview()
            drainMainQueue(turns: 5)
            controller.debugRender()
            controller.showDashboard()
            drainMainQueue(turns: 5)
            check(controller.debugProjectFilter == alpha,
                  "a re-render must not silently drop the captain's project filter")
            check(checkedProject(controller) == alpha,
                  "...and the project menu must still check it, got \(checkedProject(controller) ?? "All projects")")
        }

        checkTheTasksStates(check)

        if failures.isEmpty {
            print("ShiftTasksPageSelfTest: PASS")
            return true
        }
        print("ShiftTasksPageSelfTest: FAIL")
        for failure in failures { print("  - \(failure)") }
        return false
    }

    // MARK: Harness

    /// Picks a scope the way the captain does: a figure on the hero band for
    /// All tasks, Due today and Overdue, a Smart views pill for the other two.
    private static func pickScope(_ controller: ShiftController, _ id: String, _ check: (Bool, String) -> Void) {
        guard let band = controller.debugHeroBand else {
            check(false, "the hero band is not showing, so \(id) cannot be picked")
            return
        }
        switch id {
        case "all": check(band.debugFigureButtons[0].performPrimaryAction(), "the All tasks figure has no click")
        case "due_today": check(band.debugFigureButtons[1].performPrimaryAction(), "the Due today figure has no click")
        case "overdue": check(band.debugFigureButtons[2].performPrimaryAction(), "the Overdue figure has no click")
        case "my_priorities": band.debugPills.priorities.performClick(nil)
        case "recently_updated": band.debugPills.recent.performClick(nil)
        default: check(false, "no control picks the scope \(id)")
        }
        drainMainQueue(turns: 5)
    }

    /// The band's figures, All tasks first.
    private static func figureCounts(_ controller: ShiftController) -> [String] {
        controller.debugHeroBand?.debugFigureButtons.map(\.debugCount) ?? []
    }

    /// The project the project menu checks, `nil` for All projects.
    private static func checkedProject(_ controller: ShiftController) -> String? {
        controller.projectMenu().items.first { $0.state == .on }?.representedObject as? String
    }

    private static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }

    private static func walk(_ view: NSView, _ body: (NSView) -> Void) {
        body(view)
        for sub in view.subviews { walk(sub, body) }
    }

    private static func dateString(daysFromNow days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date())
    }

    @discardableResult
    private static func seed(_ store: ShiftStore, title: String,
                             status: ShiftTaskStatus, due: String?,
                             project: String? = nil) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.status = status
        task.dueDate = due
        task.projectID = project
        store.addTask(task)
        return task.id
    }

    @discardableResult
    private static func seedProject(_ store: ShiftStore, name: String) -> String {
        var project = ShiftProject.fresh()
        project.name = name
        store.addProject(project)
        return project.id
    }

    @discardableResult
    private static func seedPriority(_ store: ShiftStore, title: String,
                                     priority: ShiftPriority) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.priority = priority
        store.addTask(task)
        return task.id
    }

    private static func mount(store: ShiftStore) -> (ShiftController, NSWindow) {
        let controller = ShiftController(store: store)
        // `OffScreenProbe.window(...)` and `orderFront`, never
        // `makeKeyAndOrderFront`: this machine may be running the captain's
        // own instance.
        let window = OffScreenProbe.window(width: 1440, height: 940, styleMask: [.titled, .resizable])
        window.contentView = controller.view
        window.orderFront(nil)
        controller.viewWillAppear()
        drainMainQueue()
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private static func drainMainQueue(turns: Int = 40) {
        for _ in 0..<turns {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// B19: a hand-edited or badly-merged `projects.yaml` carrying two
    /// entries with one id **killed the app**.
    ///
    /// `Dictionary(uniqueKeysWithValues:)` traps rather than throwing, and
    /// this is the real path a synced file reaches it by - the store reads
    /// the YAML, the page hands the projects to the board, its Follow-ups
    /// lane and the List tab's table. Driven through a disposable
    /// `FM_SHIFT_DIR` and a file written by hand, because the store's own
    /// API cannot produce the duplicate that a merge can.
    private static func checkDuplicateProjectIDsDoNotCrash(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-dup-project-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try? """
        projects:
          - id: raas-migration
            name: RaaS Migration
            description: the real one
            status: active
            created_at: "2026-09-01"
          - id: raas-migration
            name: RaaS Migration (what a bad merge leaves behind)
            description: ""
            status: active
            created_at: "2026-09-02"
        """.write(to: projects.appendingPathComponent("projects.yaml"),
                  atomically: true, encoding: .utf8)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        let store = ShiftStore()
        // The fixture's own discriminating power: the store really did read
        // two projects sharing an id, so a parser change that silently
        // de-duplicated would fail here rather than make the check vacuous.
        check(store.projects.filter { $0.id == "raas-migration" }.count == 2,
              "fixture: the store must actually hold two projects with one id, got "
              + store.projects.map { $0.id }.joined(separator: ","))
        // The page's render, on Board and on List. Reaching the next
        // statement at all is the assertion; the check below is so a passing
        // run says so out loud.
        var task = ShiftTask.fresh()
        task.title = "In the duplicated project"
        task.projectID = "raas-migration"
        store.addTask(task)
        let (controller, window) = mount(store: store)
        defer { window.orderOut(nil) }
        controller.debugSelectTasksView(ShiftController.ShiftTasksView.list.rawValue)
        controller.debugRender()
        check(controller.debugTasksTable.debugRows.count == 1,
              "the List tab should draw the one task, got \(controller.debugTasksTable.debugRows.count) rows")
        check(true, "a duplicated project id must not kill the app (B19)")
    }

    // MARK: The UI/UX revamp's Tasks states (UI-26, UI-31)

    /// - UI-31: the lanes draw the skeleton until the first render, and only
    ///   the chosen view is mounted on first paint (REL-01: the first render
    ///   now runs at the end of `loadView`, from the store `init` already
    ///   read, so building the view is enough to clear the skeleton);
    /// - UI-31 / GL-14: a task file that will not parse is a failed-read card
    ///   naming the file and the line - the board is hidden and the subtitle
    ///   never says "0 open";
    /// - UI-26: a lane empty because of a filter says which, and its action
    ///   clears it.
    private static func checkTheTasksStates(_ check: (Bool, String) -> Void) {
        withScratchStore { store in
            _ = seed(store, title: "Anything", status: .todo, due: nil)
            let controller = ShiftController(store: store)
            _ = controller.view
            check(controller.debugTasksViewID == "board",
                  "UI-31: the first paint shows the Board, got \(controller.debugTasksViewID)")
            controller.debugRender()
            check(controller.debugBoardView?.debugColumn(.backlog)?.debugSkeletonVisible == false,
                  "UI-31: the skeleton goes once the board has rendered")
        }

        // REL-02: a pull that rewrote the task file repaints the open page.
        // The store reloaded on a remote change, but nothing told the page,
        // so the board and the counts stayed stale until the next visit.
        withScratchStore { store in
            _ = seed(store, title: "Already here", status: .todo, due: nil)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            check(controller.debugVisibleTaskIDs(.backlog).count == 1, "REL-02: the fixture starts with one backlog task")

            var fired = 0
            store.observe { fired += 1 }
            store.remoteFilesChanged()
            drainMainQueue()
            check(fired == 0, "REL-02: a reread that changed nothing does not notify, got \(fired)")

            // What a fast-forward does: the file changes underneath the store.
            var arrived = ShiftTask.fresh()
            arrived.id = "pulled-from-the-other-machine"
            arrived.title = "Added on the other machine"
            let path = store.root.appendingPathComponent("tasks/active.yaml").path
            let items = ShiftYaml.readList(path: path, key: "tasks") + [ShiftYaml.toYaml(arrived)]
            try? ShiftYaml.writeList(path: path, key: "tasks", items: items)
            store.remoteFilesChanged()
            drainMainQueue()
            check(fired == 1, "REL-02: a reread that changed the tasks notifies once, got \(fired)")
            check(controller.debugVisibleTaskIDs(.backlog).contains("pulled-from-the-other-machine"),
                  "REL-02: the open board shows the pulled task without a revisit")
            check(figureCounts(controller).first == "2",
                  "REL-02: the open page's count follows the pull, got \(figureCounts(controller).first ?? "nil")")
        }

        // REL-01: the first paint is the loaded store. Mounted in a window
        // that is ordered front, and checked before the run loop turns even
        // once - so the only render that can have happened is the one the
        // view ran for itself, not `viewWillAppear`'s background reload.
        withScratchStore { store in
            _ = seed(store, title: "First", status: .todo, due: nil)
            _ = seed(store, title: "Second", status: .todo, due: nil)
            _ = seedProject(store, name: "Alpha")
            let controller = ShiftController(store: store)
            let window = OffScreenProbe.window(width: 1440, height: 940, styleMask: [.titled, .resizable])
            defer { window.orderOut(nil) }
            window.contentView = controller.view
            window.orderFront(nil)
            check(controller.debugBoardView?.debugColumn(.backlog)?.debugSkeletonVisible == false,
                  "REL-01: the first paint shows the loaded board, not the lane skeletons")
            check(!controller.debugProjectDetailIsVisible,
                  "REL-01: the project detail is not visible under the grid before anything opened it")
            check(figureCounts(controller).first == "2",
                  "REL-01: the task count on first paint is the store's, got \(figureCounts(controller).first ?? "nil")")
            check(Set(controller.debugVisibleTaskIDs(.backlog)).count == 2,
                  "REL-01: the backlog lane holds the store's two tasks on first paint")
        }

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            _ = seed(store, title: "In alpha", status: .todo, due: nil, project: alpha)
            _ = seed(store, title: "Loose", status: .inProgress, due: nil)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            controller.debugPickProject(id: alpha)
            drainMainQueue(turns: 5)
            guard let lane = controller.debugBoardView?.debugColumn(.inProgress) else {
                check(false, "the In Progress lane should be mounted")
                return
            }
            check(lane.debugFilteredEmptyText == "No In Progress tasks in Alpha",
                  "UI-26: a filtered-empty lane names the filter, got \(lane.debugFilteredEmptyText ?? "nil")")
            lane.debugPressClearFilter()
            drainMainQueue(turns: 5)
            check(controller.debugProjectFilter == nil, "UI-26: its action clears the filter")
            check(lane.debugFilteredEmptyText == nil, "and the lane stops claiming a filter")
        }

        withScratchStore { store in
            _ = seed(store, title: "Real task", status: .todo, due: nil)
            let path = store.root.appendingPathComponent("tasks/active.yaml")
            try? "tasks:\n  - id: t1\n    title: [unclosed\n    status: todo\n".write(to: path, atomically: true, encoding: .utf8)
            store.reloadAll()
            check(store.isInFailedLoadState, "the fixture should leave the store in its failed state")
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            check(controller.debugFailedReadIsVisible, "UI-31: a failed read shows the failed-read card")
            check(!controller.debugBoardIsVisible, "UI-31: and hides the board, whose lanes would read as empty")
            check(controller.debugFailedReadSubline.hasPrefix("tasks/active.yaml"),
                  "UI-31: the card names the file, got \"\(controller.debugFailedReadSubline)\"")
            check(!(controller.drillHeaderSubtitle ?? "").contains("0 open"),
                  "GL-14: the subtitle never says 0 open over a failed read")
        }
    }

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-tasks-page-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }
}
#endif
