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
                             status: ShiftTaskStatus, due: String?) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.status = status
        task.dueDate = due
        store.addTask(task)
        return task.id
    }

    private static func mount(store: ShiftStore) -> (ShiftController, NSWindow) {
        let controller = ShiftController(store: store)
        // Far off-screen and `orderFront`, never `makeKeyAndOrderFront`: this
        // machine may be running the captain's own instance.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 1440, height: 940),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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
