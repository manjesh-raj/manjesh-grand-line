// Manjesh Grand Line - native macOS app.
//
// The Tasks page's redesign (`fm/grand-line-tasks-page-redesign`): the page's
// own nav column, the slice it filters by, the fourth stat tile, the page-level
// primary action, and the board column sized so a card is never sliced.
//
// **Why window-backed.** Every check here needs real geometry: a column body's
// height against what its cards really occupy, and a constraint that is only
// active while the column is showing. It sits in `run-all-tests.sh`'s
// `NEEDS_SESSION` list beside its Shift peers.
//
// **What it spends assertions on.** Behaviour a render cannot show and a value
// check cannot re-derive: a filter that filters, a count that comes off the
// same array the tiles were built from, and a completed task that is never
// called overdue. Never on a colour or a spacing - those are taste, and they
// fail for the wrong reason.
//
// Run with `FM_RUN_SHIFT_TASKS_PAGE_TESTS=1 .build/debug/FirstmateCockpit`.

#if FM_SELFTESTS

import AppKit

enum ShiftTasksPageSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // MARK: The column filters the board, and says so honestly

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

            controller.debugSelectSidebarRow("due_today")
            check(controller.debugTaskScope == "due_today",
                  "clicking Due today should move the scope, got \(controller.debugTaskScope)")
            check(visible() == [dueToday, running],
                  "Due today should show only today's open tasks, got \(visible().count)")

            controller.debugSelectSidebarRow("overdue")
            check(visible() == [late],
                  "Overdue should show only the late open task, got \(visible().count)")
            check(!visible().contains(finishedLate),
                  "a completed task is never overdue - it is done")

            controller.debugSelectSidebarRow("all")
            check(visible().count == 5,
                  "All tasks should restore the full board, got \(visible().count)")

            // MARK: The counts come off the same arrays the tiles were built from

            let tiles = controller.debugStatTiles
            check(tiles.count == 4, "the page should carry four stat tiles, got \(tiles.count)")
            let byCaption = Dictionary(tiles.map { ($0.caption, $0.value) }, uniquingKeysWith: { a, _ in a })
            check(byCaption["open tasks"] == "4",
                  "open tasks should count the four active tasks, got \(byCaption["open tasks"] ?? "nil")")
            check(byCaption["tasks today"] == "2",
                  "tasks today should be 2, got \(byCaption["tasks today"] ?? "nil")")
            check(byCaption["overdue"] == "1",
                  "overdue should be 1, got \(byCaption["overdue"] ?? "nil")")

            let counts = controller.debugSidebar.debugCounts
            check(counts["all"] == byCaption["open tasks"],
                  "the column's All tasks count must equal the open-tasks tile, got \(counts["all"] ?? "nil")")
            check(counts["due_today"] == byCaption["tasks today"],
                  "the column's Due today count must equal the tile, got \(counts["due_today"] ?? "nil")")
            check(counts["overdue"] == byCaption["overdue"],
                  "the column's Overdue count must equal the tile, got \(counts["overdue"] ?? "nil")")
        }

        // MARK: An action row never takes the selection

        withScratchStore { store in
            _ = seed(store, title: "Anything", status: .todo, due: nil)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugSelectSidebarRow("due_today")
            controller.debugSelectSidebarRow("jump.followUps")
            check(controller.debugTaskScope == "due_today",
                  "a jump row must leave the scope alone, got \(controller.debugTaskScope)")
            check(controller.debugSidebar.selection == "due_today",
                  "a jump row must not become the selection, got \(controller.debugSidebar.selection ?? "nil")")
        }

        // MARK: Weekly Review takes the column with it, gap and all

        withScratchStore { store in
            _ = seed(store, title: "Anything", status: .todo, due: nil)
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            check(controller.debugSidebarIsVisible, "the column should show on My Tasks")
            check(controller.debugContentStartsAfterSidebar,
                  "the content should start after the column on My Tasks")

            controller.showWeeklyReview()
            controller.view.layoutSubtreeIfNeeded()
            check(!controller.debugSidebarIsVisible,
                  "the column's rows are all about the board, so it goes with it")
            check(!controller.debugContentStartsAfterSidebar,
                  "hiding the column must also close the gap it left - an ordinary hidden view keeps its constraints")

            controller.showDashboard()
            controller.view.layoutSubtreeIfNeeded()
            check(controller.debugSidebarIsVisible && controller.debugContentStartsAfterSidebar,
                  "coming back to My Tasks should restore the column and its gap")
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

            // ...and all three columns stay level with each other.
            let heights = [ShiftBoardColumn.backlog, .inProgress, .done]
                .compactMap { controller.debugBoardView?.debugColumn($0)?.debugScrollHeight }
            check(Set(heights.map { fmt($0) }).count == 1,
                  "the three columns must never be ragged, got \(heights.map(fmt))")
        }


        // MARK: The column lists every project, in that project's own colour
        //
        // The defect this closes: the column collapsed the whole project set
        // into one "Projects 5" count row, so the one place a captain would
        // look to see *which* projects exist showed a number. The data was
        // already there and already listed individually by the board's own
        // filter chips - nothing iterated it into nav rows.

        withScratchStore { store in
            let names = ["Manjesh Grand Line", "Deploy engine", "Pramata Platform"]
            let ids = names.map { seedProject(store, name: $0) }

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            let column = controller.debugSidebar

            check(column.debugHeaders == ["Workspace", "Projects", "Smart views"],
                  "the column's three groups, got \(column.debugHeaders)")

            for (index, name) in names.enumerated() {
                let id = ShiftController.debugProjectRowID(ids[index])
                check(column.debugRowTitles.contains(name),
                      "the column should list the project \"\(name)\", got \(column.debugRowTitles)")
                // The dot is the same stable hue this project's board cards and
                // filter chip already paint. Compared **component-wise**:
                // `HelmContrast.ratio` is a luminance comparison, so two
                // different hues of similar brightness pass it.
                let expected = HelmTheme.nsColor(
                    ShiftProjectPalette.tint(forProjectID: ids[index]).hex(in: ThemeManager.shared.theme))
                guard let painted = column.debugDotColor(id: id) else {
                    check(false, "\(name) should be led by a dot, not a symbol")
                    continue
                }
                check(sameColour(painted, expected),
                      "\(name)'s dot must be its board colour, got \(painted) want \(expected)")
            }

            // A project row is an identity, not an action: it must never wear
            // an SF Symbol where a colour dot belongs, and the workspace rows
            // must never wear a dot.
            let dotted = zip(column.debugRowTitles, column.debugRowUsesDot)
                .filter { $0.1 }.map { $0.0 }
            check(Set(dotted) == Set(names),
                  "exactly the project rows carry a dot, got \(dotted)")
        }

        // MARK: Picking a project filters the board and moves the chip row
        //
        // One filter, two controls - never two filters. A sidebar that set a
        // second, independent project filter would leave the chip row above
        // the board showing a different answer to the same question.

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            let beta = seedProject(store, name: "Beta")
            let inAlpha = seed(store, title: "In alpha", status: .todo, due: nil, project: alpha)
            let inBeta = seed(store, title: "In beta", status: .todo, due: nil, project: beta)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugSelectSidebarRow(ShiftController.debugProjectRowID(alpha))
            drainMainQueue(turns: 5)
            check(controller.debugProjectFilter == alpha,
                  "clicking a project row filters by it, got \(controller.debugProjectFilter ?? "nil")")
            check(controller.debugVisibleTaskIDs(.backlog) == [inAlpha],
                  "the board should show only Alpha's task, got \(controller.debugVisibleTaskIDs(.backlog))")
            check(controller.debugProjectFilterBar?.selectedProjectID == alpha,
                  "the chip row must move with it, got "
                  + "\(controller.debugProjectFilterBar?.selectedProjectID ?? "nil")")
            check(controller.debugSidebar.debugSelectedRowIDs
                    .contains(ShiftController.debugProjectRowID(alpha)),
                  "the picked project row is the one rendering selected, got "
                  + "\(controller.debugSidebar.debugSelectedRowIDs)")

            // Clicking the selected project clears it, matching the chip row's
            // own toggle rather than inventing a second gesture.
            controller.debugSelectSidebarRow(ShiftController.debugProjectRowID(alpha))
            drainMainQueue(turns: 5)
            check(controller.debugProjectFilter == nil,
                  "clicking the selected project clears the filter")
            check(Set(controller.debugVisibleTaskIDs(.backlog)) == Set([inAlpha, inBeta]),
                  "clearing it shows every project again")
        }

        // MARK: A project and a slice are orthogonal
        //
        // They are two one-of-many questions, so they live in two selection
        // groups: picking a project must not un-pick "All tasks".

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            _ = seed(store, title: "Due today, alpha", status: .todo,
                     due: dateString(daysFromNow: 0), project: alpha)
            _ = seed(store, title: "Undated, alpha", status: .todo, due: nil, project: alpha)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugSelectSidebarRow("due_today")
            controller.debugSelectSidebarRow(ShiftController.debugProjectRowID(alpha))
            drainMainQueue(turns: 5)
            check(controller.debugTaskScope == "due_today",
                  "picking a project must leave the slice alone, got \(controller.debugTaskScope)")
            // Read off the rows that are really rendering selected: a project
            // row sharing the Workspace group would take the highlight away
            // from the slice, which is exactly what two groups prevent.
            check(controller.debugSidebar.debugSelectedRowIDs
                    == ["due_today", ShiftController.debugProjectRowID(alpha)],
                  "the slice and the project must both render selected, got "
                  + "\(controller.debugSidebar.debugSelectedRowIDs)")
            check(controller.debugVisibleTaskIDs(.backlog).count == 1,
                  "both filters apply at once, got \(controller.debugVisibleTaskIDs(.backlog).count) task(s)")
        }

        // MARK: Smart views are backed by fields the record really carries

        withScratchStore { store in
            let hot = seedPriority(store, title: "Hot", priority: .high)
            _ = seedPriority(store, title: "Ordinary", priority: .normal)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugSelectSidebarRow("my_priorities")
            drainMainQueue(turns: 5)
            check(controller.debugVisibleTaskIDs(.backlog) == [hot],
                  "My priorities is the captain's own high-priority mark, got "
                  + "\(controller.debugVisibleTaskIDs(.backlog))")

            // Everything seeded here was written moments ago, so the window is
            // exercised by what it *keeps*, and the assertion that matters is
            // that the slice is a real filter rather than a relabelled "all".
            controller.debugSelectSidebarRow("recently_updated")
            drainMainQueue(turns: 5)
            check(controller.debugVisibleTaskIDs(.backlog).count == 2,
                  "a task written seconds ago is recently updated, got "
                  + "\(controller.debugVisibleTaskIDs(.backlog).count)")
        }

        // MARK: The footer links are wired to something real

        withScratchStore { store in
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            check(controller.debugSidebar.debugFooterLinkTitles == ["Settings", "Shortcuts"],
                  "the footer's two links, got \(controller.debugSidebar.debugFooterLinkTitles)")

            var navigated: RailDestination?
            var openedPalette = false
            controller.onNavigateToDestination = { navigated = $0 }
            controller.onOpenCommandPalette = { openedPalette = true }
            controller.debugSidebar.debugClickFooterLink("footer.settings")
            controller.debugSidebar.debugClickFooterLink("footer.shortcuts")
            check(navigated == .settings, "Settings opens the Settings destination, got \(String(describing: navigated))")
            check(openedPalette, "Shortcuts opens the command palette")

            // ...and it sits on the column's own bottom edge, which is the
            // whole reason this page pins its column's bottom rather than
            // letting it hug its content the way its two sibling pages do.
            check(abs(controller.debugSidebar.debugFooterBottomGap) < 1,
                  "the footer belongs on the column's bottom edge, sitting "
                  + "\(fmt(controller.debugSidebar.debugFooterBottomGap))pt above it")
            // ...and the column itself reaches the page's bottom, which is the
            // other half: a column left to hug its content puts a correctly
            // bottom-pinned footer halfway up an empty page.
            let pageBottomGap = controller.debugSidebar.frame.minY - controller.view.bounds.minY
            check(abs(pageBottomGap - HelmMetrics.pageGutter) < 1,
                  "the column runs to the page's bottom inset, stopping "
                  + "\(fmt(pageBottomGap))pt up instead of \(fmt(HelmMetrics.pageGutter))pt")
        }

        // MARK: More projects than fit, and none at all
        //
        // The column has to survive both ends: a fresh profile with no
        // projects, and a captain with far more than the page was drawn with.
        // A column that grew past the window would draw its rows over the
        // footer, so the nav content scrolls instead - and neither end may
        // change the column's own width, which reaches `bodyContainer` and so
        // the window (gotcha (13)).

        withScratchStore { store in
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            check(controller.debugSidebar.debugRowUsesDot.allSatisfy { !$0 },
                  "an empty project set lists no project rows")
            check(controller.debugSidebar.debugHeaders.contains("Projects"),
                  "...and the group header still says where projects go")
        }

        withScratchStore { store in
            for index in 1...25 { _ = seedProject(store, name: "Project \(index)") }
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            check(controller.debugSidebar.debugRowUsesDot.filter { $0 }.count == 25,
                  "every project gets a row, got "
                  + "\(controller.debugSidebar.debugRowUsesDot.filter { $0 }.count)")

            for height in [940.0, 700.0, 1200.0] as [CGFloat] {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY,
                                       width: 1440, height: height), display: true)
                controller.view.layoutSubtreeIfNeeded()
                let column = controller.debugSidebar
                check(fmt(column.frame.width) == fmt(HelmPageSidebar.width),
                      "the column stays \(fmt(HelmPageSidebar.width))pt wide at height \(fmt(height)), "
                      + "got \(fmt(column.frame.width))")
                check(column.frame.maxY <= controller.view.bounds.height + 0.5,
                      "and never grows past the page at height \(fmt(height))")
            }
        }

        // MARK: The column survives leaving the page and coming back

        withScratchStore { store in
            let alpha = seedProject(store, name: "Alpha")
            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            controller.debugSelectSidebarRow(ShiftController.debugProjectRowID(alpha))
            drainMainQueue(turns: 5)
            controller.showWeeklyReview()
            drainMainQueue(turns: 5)
            check(!controller.debugSidebarIsVisible, "the column hides on Weekly Review")
            controller.debugRender()
            controller.showDashboard()
            drainMainQueue(turns: 5)
            check(controller.debugSidebarIsVisible, "and comes back on My Tasks")
            check(controller.debugProjectFilter == alpha,
                  "a re-render must not silently drop the captain's project filter")
            check(controller.debugSidebar.debugSelectedRowIDs
                    .contains(ShiftController.debugProjectRowID(alpha)),
                  "...and the column must still render it selected, got "
                  + "\(controller.debugSidebar.debugSelectedRowIDs)")
        }

        if failures.isEmpty {
            print("ShiftTasksPageSelfTest: PASS")
            return true
        }
        print("ShiftTasksPageSelfTest: FAIL")
        for failure in failures { print("  - \(failure)") }
        return false
    }

    // MARK: Harness

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

    /// Component-wise, never `HelmContrast.ratio`: that compares relative
    /// *luminance*, so two entirely different hues of similar brightness pass
    /// it - a trap this codebase has walked into twice.
    private static func sameColour(_ a: NSColor, _ b: NSColor) -> Bool {
        let lhs = HelmContrast.components(a), rhs = HelmContrast.components(b)
        return abs(lhs.0 - rhs.0) < 0.01 && abs(lhs.1 - rhs.1) < 0.01 && abs(lhs.2 - rhs.2) < 0.01
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
