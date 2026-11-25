// Grand Line - native macOS app.
//
// Regression coverage for a real, captain-reported bug on the Tasks page: on
// the Board, with the pointer over a lane or its task cards, the page would
// not scroll, though the Backlog lane's last cards were below the window's
// foot. It scrolled over the gaps between the lanes and stopped the moment
// the pointer crossed into one.
//
// **Root cause.** The sidebar layout grows each lane to its cards and lets
// the page do the scrolling, but the cards still live in the lane's own
// `NSScrollView`, nested inside the page's. AppKit has no scroll chaining: a
// wheel or trackpad event goes to the innermost scroll view under the
// pointer, and a plain `NSScrollView` keeps it even when its document fits
// and it has nothing to scroll. The same trap `HelmDataTableWheelSelfTest`
// records for Setup's tables, and the same fix: the lane's scroll view is a
// `HelmNestedScrollView`, which hands the wheel to the page whenever its
// cards all fit. List's two panels (My Tasks, Follow-ups) and a project's
// task list had the same plain scroll view and the same dead zone whenever
// their rows fit, so they take the same component.
//
// **What it asserts.** Each view is sampled on a grid over the part of the
// page that is on screen. Wherever the pointer sits in a scroll view nested
// inside the page's, a wheel event there must reach the page - unless that
// inner scroll view really has rows below its fold, which is the other half
// of `HelmNestedScrollView`'s rule. A point over the page alone is the
// control that this dispatch reaches the page at all. Calendar is a web
// view that fills the page and scrolls itself, so it is not sampled.
//
// **How the event is delivered**, for the reasons
// `HelmDataTableWheelSelfTest`'s header measured: a synthetic wheel event
// does not move an off-screen window's scroll view, so the suite records
// which scroll view's `scrollWheel(with:)` the event reaches rather than an
// offset, and it enters at the view the page hit-tests under the pointer,
// from where the real responder chain carries it.
//
// The page is the real Tasks page in the sidebar layout, at the window size
// `main.swift` opens, with the tour lab's demo tasks and enough Backlog cards
// to overflow it. Hit-testing and the responder chain are the view tree's own
// and need no window server, so this suite builds no window and runs in CI's
// blocking headless lane.
//
// Run with:
//   swift build && FM_RUN_TASKS_PAGE_WHEEL_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TasksPageWheelSelfTest {

    /// The captain's board: thirteen cards in Backlog.
    static let backlogCount = 13

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-page-wheel-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        let store = ShiftStore()
        seedBacklog(store)
        let controller = ShiftController(store: store)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1512, height: 950)

        var allOK = true
        let checks: [(ShiftController, inout Bool) -> Void] = [
            checkTheBoardScrollsOverItsLanes, checkTheListScrollsOverItsPanels, checkWeeklyReviewScrolls,
        ]
        for check in checks {
            var ok = true
            autoreleasepool { check(controller, &ok) }
            allOK = allOK && ok
        }
        print(allOK ? "TasksPageWheelSelfTest: all checks passed" : "TasksPageWheelSelfTest: FAILED")
        return allOK
    }

    /// Shows one of the page's views, rendered and laid out.
    private static func show(_ controller: ShiftController, tab: String) {
        controller.selectModuleTab(named: tab)
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
    }

    /// The tour lab's demo tasks, topped up to `backlogCount` in Backlog.
    private static func seedBacklog(_ store: ShiftStore) {
        ReviewTourLab.seedDemoTasks(store)
        let existing = store.activeTasks.filter { ShiftBoardColumn.column(for: $0.status) == .backlog }.count
        for index in 0..<max(0, backlogCount - existing) {
            var task = ShiftTask.fresh()
            task.title = "Backlog item \(index + 1)"
            task.status = .todo
            store.addTask(task)
        }
    }

    // MARK: - Recording which scroll view takes the wheel

    private static var received: [ObjectIdentifier] = []

    fileprivate static func record(_ scroll: NSScrollView) { received.append(ObjectIdentifier(scroll)) }

    private static func recordingWheel(_ ok: inout Bool, _ body: () -> Void) {
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.scrollWheel(with:))),
              let recorder = class_getInstanceMethod(NSScrollView.self,
                                                     #selector(NSScrollView.fm_recordTasksPageWheel(with:))) else {
            return fail("TasksPageWheel: could not install the wheel recorder", &ok)
        }
        method_exchangeImplementations(original, recorder)
        defer { method_exchangeImplementations(original, recorder) }
        body()
    }

    /// The view a wheel at `point` would go to. `point` is in `root`'s own
    /// coordinates.
    private static func hitView(at point: NSPoint, in root: NSView) -> NSView? {
        let inParent = root.superview.map { root.convert(point, to: $0) } ?? point
        return root.hitTest(inParent)
    }

    /// The scroll views from the hit view out, innermost first.
    private static func scrollViews(at point: NSPoint, in root: NSView) -> [NSScrollView] {
        var view = hitView(at: point, in: root)
        var chain: [NSScrollView] = []
        while let current = view {
            if let scroll = current as? NSScrollView { chain.append(scroll) }
            view = current.superview
        }
        return chain
    }

    /// One wheel event at `point`, and the scroll views that handled it.
    private static func dispatchWheel(at point: NSPoint, in root: NSView, _ ok: inout Bool) -> [ObjectIdentifier] {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: -40, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg), let hit = hitView(at: point, in: root) else {
            fail("TasksPageWheel: could not deliver a wheel at \(point)", &ok)
            return []
        }
        received = []
        recordingWheel(&ok) { hit.scrollWheel(with: event) }
        return received
    }

    /// Whether `scroll` really has more document than it shows. Read from the
    /// geometry rather than `HelmNestedScrollView.forwardsWheelToPage`, which
    /// is the thing under test.
    private static func overflows(_ scroll: NSScrollView) -> Bool {
        (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 0.5
    }

    // MARK: - The shared sweep

    /// What one sweep found, for the fixture checks.
    private struct Sweep {
        /// Points over a nested scroll view whose document fits.
        var nested = 0
        /// Of those, how many were over `focus` (a lane's cards, say).
        var overFocus = 0
        /// Points over the page alone.
        var pageOnly = 0
    }

    /// Samples the on-screen part of `page` and checks every point's wheel.
    @discardableResult
    private static func sweep(_ name: String, page: NSScrollView, root: NSView, focus: [NSView] = [],
                              _ ok: inout Bool) -> Sweep {
        var result = Sweep()
        let area = page.convert(page.bounds, to: root).insetBy(dx: 6, dy: 6)
        let columns = 14
        let rows = 16
        var failures: [String] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let point = NSPoint(x: area.minX + area.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                                    y: area.minY + area.height * (CGFloat(row) + 0.5) / CGFloat(rows))
                let chain = scrollViews(at: point, in: root)
                guard let pageIndex = chain.firstIndex(where: { $0 === page }) else { continue }
                if pageIndex == 0 {
                    result.pageOnly += 1
                    continue
                }
                let inner = chain[0]
                // A scroll view with rows below its fold keeps its wheel by
                // design; anything else nested in the page must let it go.
                guard !overflows(inner) else { continue }
                result.nested += 1
                if focus.contains(where: { inner.isDescendant(of: $0) }) { result.overFocus += 1 }
                let receivers = dispatchWheel(at: point, in: root, &ok)
                if receivers.contains(ObjectIdentifier(inner)) || !receivers.contains(ObjectIdentifier(page)) {
                    let owner = String(describing: type(of: inner.superview ?? inner))
                    failures.append("\(owner) at (\(Int(point.x)), \(Int(point.y)))")
                }
            }
        }
        check(failures.isEmpty,
              "\(name): \(failures.count) point(s) over a scroll view with nothing to scroll kept the wheel from the "
              + "page - \(failures.prefix(4).joined(separator: "; "))", &ok)
        return result
    }

    /// The control: a wheel over the page alone reaches it.
    private static func checkThePageAloneReceives(_ name: String, page: NSScrollView, root: NSView, _ ok: inout Bool) {
        let visible = page.convert(page.bounds, to: root)
        let point = NSPoint(x: visible.maxX - 4, y: visible.midY)
        guard scrollViews(at: point, in: root).first === page else {
            return fail("\(name): fixture - the page's trailing edge should be over the page alone", &ok)
        }
        let receivers = dispatchWheel(at: point, in: root, &ok)
        check(receivers == [ObjectIdentifier(page)],
              "\(name): a wheel over the page alone should reach it - \(receivers.count) receiver(s)", &ok)
    }

    // MARK: - Cases

    /// The captain's report: Board, thirteen cards in Backlog, the pointer
    /// over the cards.
    private static func checkTheBoardScrollsOverItsLanes(_ shift: ShiftController, _ ok: inout Bool) {
        show(shift, tab: "Board")
        let root = shift.view
        guard let document = shift.scroll.documentView else { return fail("Board: no page document", &ok) }
        let page = shift.scroll
        let backlog = shift.debugBoardColumns.first { $0.column == .backlog }
        check(backlog?.debugCardViews.count == backlogCount,
              "Board: fixture - Backlog shows \(backlog?.debugCardViews.count ?? -1) cards, want \(backlogCount)", &ok)
        // The page really does scroll here, so the trap is the one reported.
        check(document.frame.height > page.contentView.bounds.height + 100,
              "Board: fixture - the page should be taller than its viewport, "
              + "\(document.frame.height) in \(page.contentView.bounds.height)", &ok)
        if let lastCard = backlog?.debugCardViews.last {
            let card = lastCard.convert(lastCard.bounds, to: page.contentView)
            check(!page.contentView.bounds.contains(card),
                  "Board: fixture - Backlog's last card should start below the fold, at \(card)", &ok)
        }
        checkThePageAloneReceives("Board", page: page, root: root, &ok)
        let lanes: [NSView] = shift.debugBoardColumns
        let found = sweep("Board", page: page, root: root, focus: lanes, &ok)
        // Discriminating power: the sweep really landed on the lanes' own
        // scroll views, so a pass is not a sweep that only hit the gaps.
        check(found.overFocus >= 6, "Board: fixture - only \(found.overFocus) sampled point(s) were over a lane", &ok)
        check(found.pageOnly > 0, "Board: fixture - no sampled point was over the page alone", &ok)
    }

    /// List: My Tasks and Follow-ups are panels whose rows sit in scroll views
    /// of their own.
    private static func checkTheListScrollsOverItsPanels(_ shift: ShiftController, _ ok: inout Bool) {
        show(shift, tab: "List")
        checkThePageAloneReceives("List", page: shift.scroll, root: shift.view, &ok)
        let found = sweep("List", page: shift.scroll, root: shift.view, &ok)
        check(found.nested > 0, "List: fixture - no sampled point was over a panel's own scroll view", &ok)
    }

    /// Weekly review draws no nested scroll view today. The sweep is here so
    /// one added later is held to the same rule.

    private static func checkWeeklyReviewScrolls(_ shift: ShiftController, _ ok: inout Bool) {
        show(shift, tab: "Weekly review")
        checkThePageAloneReceives("Weekly review", page: shift.scroll, root: shift.view, &ok)
        sweep("Weekly review", page: shift.scroll, root: shift.view, &ok)
    }
}

extension NSScrollView {
    /// The recorder `TasksPageWheelSelfTest` swaps in. After the exchange,
    /// calling this selector runs the original `scrollWheel(with:)`.
    @objc fileprivate func fm_recordTasksPageWheel(with event: NSEvent) {
        TasksPageWheelSelfTest.record(self)
        fm_recordTasksPageWheel(with: event)
    }
}

#endif
