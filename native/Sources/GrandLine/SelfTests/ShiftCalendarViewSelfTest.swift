// Grand Line - native macOS app.
//
// The Tasks calendar's page half: a real `ShiftController` over a scratch
// store, in a real window, with the Calendar tab genuinely selected and the
// real vendored Schedule-X page loaded in a real `WKWebView`.
//
// Everything here is read back from the page's own DOM, never from what the
// native side believes it sent:
//
//   - the page is not loaded until the tab is first shown (a session that
//     never opens the calendar pays nothing);
//   - the store's tasks render as Schedule-X events, a projection is drawn
//     faint and a real task is not, and today is highlighted;
//   - **a real drag writes the real store**. The suite dispatches the same
//     mouse and drag events a pointer produces, on the event's own element,
//     so the drop goes through the vendored drag plugin, the 4.0.1 adapter,
//     `onEventUpdate`, the bridge, `ShiftController.rescheduleTask`, the
//     reschedule rule and `ShiftStore` - and then the task is read back from
//     the store. Done in the month grid and in the week view's time grid;
//   - a projection cannot be dragged, whatever the DOM is persuaded to do;
//   - a click on an event reaches `onOpenTask` with the task's id;
//   - paging the calendar re-reads the store for the new period;
//   - the page's CSS variables follow a live theme change, light and dark;
//   - hiding the tab suspends the page.
//
// The rule maths, the payload, the palette's contrast and the bundle's
// integrity are `ShiftCalendarSelfTest`, in CI's blocking lane.
//
// Run with `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import AppKit
import WebKit

enum ShiftCalendarViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        guard ShiftCalendarAssets.webDirectory() != nil else {
            print("[ShiftCalendarViewSelfTest] no Schedule-X bundle - run native/Scripts/build-schedule-x-web.sh")
            return false
        }

        let themeBefore = ThemeManager.shared.theme
        // AGENTS.md's hermeticity rule: this suite changes the theme, so it
        // captures and restores it.
        defer { ThemeManager.shared.setTheme(themeBefore) }
        ThemeManager.shared.setTheme(HelmTheme.daylight)

        withScratchStore { store in
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let todayDay = ShiftDateFormatting.components(from: today).0
            let repeating = seed(store, title: "Standup notes", due: todayDay, time: "09:30",
                                 rule: ShiftRecurrence(frequency: .daily))
            let single = seed(store, title: "Renew wildcard TLS", due: todayDay, time: nil, rule: nil)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            let view = controller.debugCalendarView
            let web = view.debugWebView

            // MARK: Lazy until shown

            check(!controller.debugCalendarIsVisible, "the calendar must not be showing before it is selected")
            check(!web.hasLoaded, "the calendar page must not load until the tab is first shown")

            controller.debugSelectTasksView("calendar")
            controller.view.layoutSubtreeIfNeeded()
            check(controller.debugCalendarIsVisible, "selecting Calendar should show the calendar")
            check(!controller.debugBoardIsVisible, "the board should hide when the calendar is showing")
            check(web.hasLoaded, "showing the tab should load the page")

            guard waitFor(timeout: 30, until: { web.isReady && view.debugIsConfigured }) else {
                failures.append("the Schedule-X page never reported ready and configured")
                return
            }
            check(web.frame.height > 600 && web.frame.width > 600,
                  "the calendar should have a real frame, got \(web.frame.size)")

            // MARK: The store's tasks render

            _ = waitFor(timeout: 5) { (state(web)["renderedEvents"] as? Int ?? 0) >= 2 }
            let month = state(web)
            check(month["view"] as? String == "month-grid", "the calendar opens on the month, got \(month)")
            check((month["renderedEvents"] as? Int ?? 0) >= 2,
                  "both seeded tasks should render as events, got \(month["renderedEvents"] ?? "nothing")")
            check(month["todayCells"] as? Int == 1, "exactly one day is highlighted as today, got \(month)")
            check(month["dark"] as? Bool == false, "Daylight is a light register")

            check(eventIn(web, id: single, day: todayDay), "a one-off task should render on its own due day")
            check(eventIn(web, id: repeating, day: todayDay), "a repeating task's own instance renders on its day")

            // A projection is drawn as one: faint, and not draggable.
            let tomorrowDay = ShiftDateFormatting.components(
                from: calendar.date(byAdding: .day, value: 1, to: today) ?? today).0
            let projectionID = "\(repeating)@\(tomorrowDay)"
            if let end = month["end"] as? String, tomorrowDay <= end {
                check(view.debugEventIDs.contains(projectionID), "a daily rule should project onto tomorrow")
                let projected = js(web, "(() => { const el = document.querySelector('[data-event-id=\"\(projectionID)\"]');"
                                   + " return el ? getComputedStyle(el).opacity : 'missing' })()") as? String
                let real = js(web, "getComputedStyle(document.querySelector('[data-event-id=\"\(single)\"]')).opacity")
                    as? String
                check(Double(projected ?? "") ?? 1 < 1, "a projection should be drawn faint, got \(projected ?? "nil")")
                check(real == "1", "a real task is fully opaque, got \(real ?? "nil")")
            }
            check(view.debugCaption.contains("projected"),
                  "a period carrying projections should say so, got \"\(view.debugCaption)\"")

            // MARK: A click opens the task

            let openTask = view.onOpenTask
            var opened: String?
            view.onOpenTask = { opened = $0 }
            _ = js(web, "document.querySelector('[data-event-id=\"\(single)\"]').click()")
            _ = waitFor(timeout: 2) { opened != nil }
            check(opened == single, "clicking an event should open its task, got \(opened ?? "nothing")")
            view.onOpenTask = openTask

            // MARK: A real month-grid drag writes the store

            let target = calendar.date(byAdding: .day, value: 2, to: today) ?? today
            var targetDay = ShiftDateFormatting.components(from: target).0
            if let end = month["end"] as? String, targetDay > end {
                targetDay = ShiftDateFormatting.components(
                    from: calendar.date(byAdding: .day, value: -2, to: today) ?? today).0
            }
            monthDrag(web, eventID: single, toDay: targetDay)
            _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == single }?.dueDate == targetDay }
            let moved = store.activeTasks.first { $0.id == single }
            check(moved?.dueDate == targetDay,
                  "dragging a task to \(targetDay) should move its due date in the store, got \(moved?.dueDate ?? "nil")")
            check(moved?.dueTime == nil, "an all-day task must stay all-day after a drag")
            _ = waitFor(timeout: 3) { eventIn(web, id: single, day: targetDay) }
            check(eventIn(web, id: single, day: targetDay), "the page should redraw the task on its new day")

            // MARK: A projection cannot be dragged

            if view.debugEventIDs.contains(projectionID) {
                let before = store.activeTasks.first { $0.id == repeating }
                monthDrag(web, eventID: projectionID, toDay: targetDay)
                drain(turns: 30)
                let after = store.activeTasks.first { $0.id == repeating }
                check(after?.dueDate == before?.dueDate && after?.dueTime == before?.dueTime,
                      "dragging a projection must not move the real task")
            }

            // MARK: A real week-view drag moves the time

            _ = call(web, "setView", ["view": "week"])
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "week" && view.scale == .week }
            check(view.scale == .week, "the native side should follow the page into the week view")
            _ = waitFor(timeout: 3) {
                (js(web, "!!document.querySelector('.sx__time-grid-event[data-event-id=\"\(repeating)\"]')") as? Bool) == true
            }
            timeGridDrag(web, eventID: repeating, minutesLater: 60)
            _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == repeating }?.dueTime == "10:30" }
            let retimed = store.activeTasks.first { $0.id == repeating }
            check(retimed?.dueTime == "10:30" && retimed?.dueDate == todayDay,
                  "dragging a timed task an hour down should make it 10:30 on the same day, got "
                  + "\(retimed?.dueDate ?? "nil") \(retimed?.dueTime ?? "nil")")

            // MARK: Paging re-reads the store

            let weekStart = state(web)["start"] as? String
            // Schedule-X's own header button. Its chevrons act on `mouseup`
            // rather than `click`, so that is what is sent.
            _ = js(web, "document.querySelector('.sx__forward-backward-navigation button:last-of-type')"
                   + ".dispatchEvent(new MouseEvent('mouseup', {bubbles: true}))")
            _ = waitFor(timeout: 5) { (state(web)["start"] as? String) != weekStart }
            check(state(web)["start"] as? String != weekStart, "Next period should move the visible week")
            _ = waitFor(timeout: 3) { !view.debugEventIDs.contains(repeating) }
            check(!view.debugEventIDs.contains(repeating),
                  "next week's events should not include this week's real instance")
            check(view.debugEventIDs.contains { $0.hasPrefix("\(repeating)@") },
                  "next week should carry the daily rule's projections")
            _ = call(web, "setView", ["view": "month-grid"])
            _ = call(web, "showDate", ["date": todayDay])

            // MARK: The theme follows live

            let lightBackground = cssVariable(web, "--sx-color-background")
            ThemeManager.shared.setTheme(HelmTheme.dusk)
            let expectedDark = ShiftCalendarPalette.variables(for: HelmTheme.dusk)["--sx-color-background"]
            _ = waitFor(timeout: 3) { cssVariable(web, "--sx-color-background") == expectedDark }
            check(lightBackground == ShiftCalendarPalette.variables(for: HelmTheme.daylight)["--sx-color-background"],
                  "the page should have painted Daylight's surface first, got \(lightBackground ?? "nil")")
            check(cssVariable(web, "--sx-color-background") == expectedDark,
                  "a theme change should repaint the page, got \(cssVariable(web, "--sx-color-background") ?? "nil")")
            check(state(web)["dark"] as? Bool == true, "Dusk should put the page in its dark register")
            // Schedule-X re-renders its wrapper's class on its own schedule,
            // after the variables (which are written synchronously) land.
            _ = waitFor(timeout: 3) {
                js(web, "document.querySelector('.sx__calendar-wrapper').classList.contains('is-dark')") as? Bool == true
            }
            check(js(web, "document.querySelector('.sx__calendar-wrapper').classList.contains('is-dark')") as? Bool == true,
                  "Schedule-X's own dark class should follow the theme")

            // MARK: Hidden means suspended

            controller.debugSelectTasksView("board")
            controller.view.layoutSubtreeIfNeeded()
            _ = waitFor(timeout: 3) {
                (js(web, "document.documentElement.classList.contains('gl-suspended')") as? Bool) == true
            }
            check(web.isSuspended, "hiding the calendar should suspend it")
            check(js(web, "document.documentElement.classList.contains('gl-suspended')") as? Bool == true,
                  "the suspend should reach the page")

            _ = waitFor(timeout: 3) { web.debugPendingCallCount == 0 }
            check(web.debugPendingCallCount == 0, "\(web.debugPendingCallCount) bridge call(s) never got a reply")
        }

        return report(failures)
    }

    // MARK: Driving the page

    /// The month grid's drag is HTML5 drag and drop: a mouse-down starts the
    /// core's drag timer (150ms), the plugin then listens for `dragover` on the
    /// day cells and `dragend` on the document. Synthesised in that order.
    private static func monthDrag(_ web: WKWebView, eventID: String, toDay day: String) {
        let script = """
        const el = document.querySelector(`.sx__month-grid-event[data-event-id="${eventID}"]`);
        const target = document.querySelector(`.sx__month-grid-day[data-date="${day}"]`);
        if (!el || !target) return 'missing';
        const r = el.getBoundingClientRect();
        el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: r.x + 4, clientY: r.y + 4}));
        await new Promise(resolve => setTimeout(resolve, 220));
        const t = target.getBoundingClientRect();
        target.dispatchEvent(new DragEvent('dragover', {bubbles: true, cancelable: true,
                                                        clientX: t.x + 10, clientY: t.y + 30}));
        document.dispatchEvent(new DragEvent('dragend', {bubbles: true}));
        document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
        return 'ok';
        """
        _ = asyncJS(web, script, ["eventID": eventID, "day": day])
    }

    /// The week view's time grid drag is mouse-driven: down on the event,
    /// move on the document, up on the document. 1200px per day here
    /// (`weekOptions.gridHeight`), so an hour is 50px.
    private static func timeGridDrag(_ web: WKWebView, eventID: String, minutesLater: Int) {
        let script = """
        const el = document.querySelector(`.sx__time-grid-event[data-event-id="${eventID}"]`);
        if (!el) return 'missing';
        el.scrollIntoView();
        const r = el.getBoundingClientRect();
        const x = r.x + 4, y = r.y + 4, dy = minutes * 1200 / (24 * 60);
        el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: x, clientY: y}));
        await new Promise(resolve => setTimeout(resolve, 220));
        document.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: x, clientY: y + dy}));
        await new Promise(resolve => setTimeout(resolve, 50));
        document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, clientX: x, clientY: y + dy}));
        return 'ok';
        """
        _ = asyncJS(web, script, ["eventID": eventID, "minutes": minutesLater])
    }

    private static func eventIn(_ web: WKWebView, id: String, day: String) -> Bool {
        let script = "!!document.querySelector('.sx__month-grid-day[data-date=\"\(day)\"] [data-event-id=\"\(id)\"]')"
        return js(web, script) as? Bool == true
    }

    private static func cssVariable(_ web: WKWebView, _ name: String) -> String? {
        let value = js(web, "getComputedStyle(document.querySelector('.sx__calendar-wrapper'))"
                       + ".getPropertyValue('\(name)').trim()") as? String
        return value?.uppercased()
    }

    /// The page's own `state()` reply - read from the DOM, not the model.
    private static func state(_ web: ShiftCalendarWebView) -> [String: Any] {
        call(web, "state", [:]) ?? [:]
    }

    @discardableResult
    private static func call(_ web: ShiftCalendarWebView, _ name: String, _ payload: [String: Any]) -> [String: Any]? {
        var reply: [String: Any]?
        var done = false
        web.call(name, payload: payload) { result in
            if case .success(let body) = result { reply = body }
            done = true
        }
        _ = waitFor(timeout: 5) { done }
        return reply
    }

    private static func js(_ web: WKWebView, _ script: String) -> Any? {
        var value: Any?
        var done = false
        web.evaluateJavaScript(script) { result, _ in
            value = result
            done = true
        }
        _ = waitFor(timeout: 5) { done }
        return value
    }

    private static func asyncJS(_ web: WKWebView, _ body: String, _ arguments: [String: Any]) -> Any? {
        var value: Any?
        var done = false
        web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .success(let v) = result { value = v }
            done = true
        }
        _ = waitFor(timeout: 5) { done }
        return value
    }

    // MARK: Harness

    @discardableResult
    private static func seed(_ store: ShiftStore, title: String, due: String?, time: String?,
                             rule: ShiftRecurrence?) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.dueDate = due
        task.dueTime = time
        task.recurrence = rule
        store.addTask(task)
        return task.id
    }

    private static func mount(store: ShiftStore) -> (ShiftController, NSWindow) {
        let controller = ShiftController(store: store)
        let window = OffScreenProbe.window(width: 1300, height: 950, styleMask: [.titled, .resizable])
        window.contentView = controller.view
        window.orderFront(nil)
        controller.viewWillAppear()
        drain()
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// `reloadAllAsync` renders on completion, so the queue is drained
    /// before anything reads the page.
    private static func drain(turns: Int = 40) {
        for _ in 0..<turns {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-calendar-view-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftCalendarViewSelfTest] all checks passed")
            return true
        }
        print("[ShiftCalendarViewSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
