// Grand Line - native macOS app.
//
// The Calendar's page half: a real `TaskCalendarController` over a scratch
// store, in a real window, with the real vendored Schedule-X page loaded in a
// real `WKWebView`.
//
// Everything here is read back from the page's own DOM, never from what the
// native side believes it sent:
//
//   - the page is not loaded until the calendar is first shown (a session
//     that never opens the calendar pays nothing);
//   - the captain's card is what is drawn: the period's title, the filled
//     pill for the showing view, the weekday row, the legend, dimmed days
//     outside the month, raised day cells and today as a pill;
//   - the store's tasks render as Schedule-X events, a projection is drawn
//     faint and a real task is not, and today is highlighted;
//   - **a real drag writes the real store**. The suite dispatches the same
//     mouse and drag events a pointer produces, on the event's own element,
//     so the drop goes through the vendored drag plugin, the 4.0.1 adapter,
//     `onEventUpdate`, the bridge, `ShiftController.rescheduleTask`, the
//     reschedule rule and `ShiftStore` - and then the task is read back from
//     the store. Done in the month grid and in the week view's time grid;
//   - a projection cannot be dragged, whatever the DOM is persuaded to do;
//   - a click on an event reaches `onOpenTask` with the task's id, and a
//     follow-up's reaches `onOpenFollowUp`, and a drag moves its own date;
//   - a pill in the card and the toolbar's tab are one path: either moves
//     the other, and Agenda is the open-source list view;
//   - the card's own Next button pages, and paging re-reads the store;
//   - the page's CSS variables follow a live theme change, light and dark;
//   - hiding the page suspends it, and hiding it at zero width then showing
//     it again keeps the month on both sides (R4-BUG-01): a range report
//     moves the period and never the scale, and "+N more" opens its day
//     through the page's own view handler.
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
            let single = seed(store, title: "Renew wildcard TLS", due: todayDay, time: nil, rule: nil,
                              priority: .high)
            var followUp = ShiftFollowUp.fresh()
            followUp.title = "Ping the registrar"
            followUp.followUpAt = todayDay
            store.addFollowUp(followUp)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            let view = controller.debugCalendarView
            let web = view.debugWebView
            var tabChanges = 0
            controller.onModuleTabChanged = { tabChanges += 1 }

            // MARK: Lazy until shown

            check(!web.hasLoaded, "the calendar page must not load until the page is first shown")

            controller.view.isHidden = false
            controller.view.layoutSubtreeIfNeeded()
            check(web.hasLoaded, "showing the page should load it")

            guard waitFor(timeout: 30, until: { web.isReady && view.debugIsConfigured }) else {
                failures.append("the Schedule-X page never reported ready and configured")
                return
            }
            check(web.frame.height > 600 && web.frame.width > 600,
                  "the calendar should fill its page, got \(web.frame.size)")

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
            let followUpEventID = "followup:\(followUp.id)"
            check(eventIn(web, id: followUpEventID, day: todayDay), "a pending follow-up renders on its day")

            // MARK: The captain's card

            let monthTitle = month["title"] as? String ?? ""
            let expectedMonth = DateFormatter.localizedString(from: today, dateStyle: .long, timeStyle: .none)
            check(!monthTitle.isEmpty && monthTitle.contains(String(calendar.component(.year, from: today))),
                  "the card's title should name the month and year, got \"\(monthTitle)\" (today is \(expectedMonth))")
            check(month["activePill"] as? String == "month-grid", "the Month pill is the filled one, got \(month)")
            check((month["weekdays"] as? [String])?.count == 7, "the weekday row has seven names, got \(month)")
            check(month["legend"] as? [String] == ShiftCalendarCategory.allCases.map(\.rawValue),
                  "the legend names every category, got \(month["legend"] ?? "nothing")")
            check(js(web, "getComputedStyle(document.querySelector('.sx__calendar-header')).display") as? String == "none",
                  "Schedule-X's own header must give way to the card's")
            if let start = month["start"] as? String,
               start < ShiftDateFormatting.components(from: calendar.date(from: calendar.dateComponents(
                   [.year, .month], from: today)) ?? today).0 {
                // Schedule-X sets the class in an effect, after its first paint.
                _ = waitFor(timeout: 3) { (state(web)["dimmedCells"] as? Int ?? 0) > 0 }
                let dimmed = state(web)["dimmedCells"] as? Int ?? 0
                check(dimmed > 0, "days outside the month should be dimmed, got \(dimmed) from \(month["start"] ?? "")")
            }
            let cellFill = js(web, "getComputedStyle(document.querySelector('.sx__month-grid-day:not(.is-leading-or-trailing)'),"
                              + " '::before').backgroundColor") as? String
            let dimFill = js(web, "(() => { const el = document.querySelector('.sx__month-grid-day.is-leading-or-trailing');"
                             + " return el ? getComputedStyle(el, '::before').backgroundColor : null })()") as? String
            check(cellFill != nil && cellFill != "rgba(0, 0, 0, 0)",
                  "each day should be its own filled cell, got \(cellFill ?? "nil")")
            if let dimFill { check(dimFill != cellFill, "a dimmed day should not look like a day of the month") }
            let todayPill = js(web, "(() => { const r = document.querySelector('.sx__month-grid-day__header-date.sx__is-today')"
                               + ".getBoundingClientRect(); return [r.width, r.height] })()") as? [Double] ?? []
            check(todayPill.count == 2 && todayPill[0] > todayPill[1],
                  "today should be a pill, wider than it is tall, got \(todayPill)")
            let edges = month["chipEdges"] as? [String] ?? []
            check(edges.contains { $0.contains(ShiftCalendarCategory.high.rawValue) }
                  && edges.contains { $0.contains(ShiftCalendarCategory.followUp.rawValue) },
                  "a high-priority task and a follow-up should be drawn in their own colours, got \(edges)")
            check(controller.newTaskDay == todayDay, "New task on this month is dated today, got \(controller.newTaskDay)")

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

            let openFollowUp = view.onOpenFollowUp
            var openedFollowUp: String?
            view.onOpenFollowUp = { openedFollowUp = $0 }
            _ = js(web, "document.querySelector('[data-event-id=\"\(followUpEventID)\"]').click()")
            _ = waitFor(timeout: 2) { openedFollowUp != nil }
            check(openedFollowUp == followUp.id, "clicking a follow-up should open the follow-up, got \(openedFollowUp ?? "nothing")")
            view.onOpenFollowUp = openFollowUp

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

            monthDrag(web, eventID: followUpEventID, toDay: targetDay)
            _ = waitFor(timeout: 5) { store.followUps.first { $0.id == followUp.id }?.followUpAt == targetDay }
            check(store.followUps.first { $0.id == followUp.id }?.followUpAt == targetDay,
                  "dragging a follow-up should move its date in the store")

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

            // The card's own Week pill: the native side, and so the toolbar,
            // follow it.
            let changesBefore = tabChanges
            _ = js(web, "document.querySelector('#gl-views [data-view=\"week\"]').click()")
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "week" && view.scale == .week }
            check(view.scale == .week && controller.selectedModuleTabName == "Week",
                  "the native side should follow the Week pill, got \(view.scale)")
            check(tabChanges > changesBefore, "the toolbar should hear the page switched view")
            check(state(web)["activePill"] as? String == "week", "the Week pill should be the filled one")
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
            let weekTitle = state(web)["title"] as? String
            _ = js(web, "document.getElementById('gl-next').click()")
            _ = waitFor(timeout: 5) { (state(web)["start"] as? String) != weekStart }
            check(state(web)["start"] as? String != weekStart, "Next period should move the visible week")
            _ = waitFor(timeout: 3) { !view.debugEventIDs.contains(repeating) }
            check(!view.debugEventIDs.contains(repeating),
                  "next week's events should not include this week's real instance")
            check(view.debugEventIDs.contains { $0.hasPrefix("\(repeating)@") },
                  "next week should carry the daily rule's projections")
            check(state(web)["title"] as? String != weekTitle, "the card's title should follow the new week")

            // MARK: The toolbar's Agenda tab

            controller.selectModuleTab(named: "Agenda")
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "list" }
            check(state(web)["view"] as? String == "list" && state(web)["activePill"] as? String == "list",
                  "the Agenda tab should show Schedule-X's list view with its pill filled")
            _ = js(web, "document.getElementById('gl-today').click()")
            _ = waitFor(timeout: 3) {
                (js(web, "document.querySelectorAll('.sx__list-event').length") as? Int ?? 0) > 0
            }
            check((js(web, "document.querySelectorAll('.sx__list-event').length") as? Int ?? 0) > 0,
                  "the agenda should list this month's records")
            controller.selectModuleTab(named: "Month")
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "month-grid" }
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

            controller.view.isHidden = true
            controller.view.layoutSubtreeIfNeeded()
            _ = waitFor(timeout: 3) {
                (js(web, "document.documentElement.classList.contains('gl-suspended')") as? Bool) == true
            }
            check(web.isSuspended, "hiding the calendar should suspend it")
            check(js(web, "document.documentElement.classList.contains('gl-suspended')") as? Bool == true,
                  "the suspend should reach the page")

            // MARK: Hidden and shown again, the view survives (R4-BUG-01)

            // The shell hides a page by deactivating its pins
            // (`WorkspaceContent.setDestinationVisible`, gotcha (15)), so a
            // hidden calendar collapses and the page sees a resize at a tiny
            // width. Schedule-X's `isResponsive` used to answer that by
            // switching to Day, and the native side adopted the Day the
            // page reported. Leave Home, come back: Day, for good.
            let month950 = state(web)
            check(month950["view"] as? String == "month-grid" && view.scale == .month,
                  "the hide-and-show case should start on the month, got \(month950["view"] ?? "nil") / \(view.scale)")
            let pins = (controller.view.superview?.constraints ?? []).filter {
                $0.firstItem === controller.view || $0.secondItem === controller.view
            }
            NSLayoutConstraint.deactivate(pins)
            controller.view.superview?.layoutSubtreeIfNeeded()
            // The fixture's own discriminating power: the page really did see
            // a width under Schedule-X's 700pt small-screen breakpoint.
            let narrowed = waitFor(timeout: 5) { (js(web, "window.innerWidth") as? Double ?? 9999) < 700 }
            check(narrowed, "a hidden calendar should collapse below 700pt, the page saw "
                  + "\(js(web, "window.innerWidth") ?? "nothing")")
            drain(turns: 50)
            NSLayoutConstraint.activate(pins)
            controller.view.superview?.layoutSubtreeIfNeeded()
            controller.view.isHidden = false
            controller.view.layoutSubtreeIfNeeded()
            _ = waitFor(timeout: 5) { (js(web, "window.innerWidth") as? Double ?? 0) >= 700 && !web.isSuspended }
            // A range report after the round trip: the page pages on its own.
            let shownRange = view.visibleDays?.start
            _ = js(web, "document.getElementById('gl-next').click()")
            _ = waitFor(timeout: 5) { view.visibleDays?.start != shownRange }
            check(view.visibleDays?.start != shownRange, "paging after the round trip should report a range")
            let back = state(web)
            check(back["view"] as? String == "month-grid",
                  "hiding and showing the calendar should keep the month, the page shows \(back["view"] ?? "nil")")
            check(view.scale == .month && controller.selectedModuleTabName == "Month",
                  "hiding and showing the calendar should keep the native scale on the month, got \(view.scale)")

            // The page reports, the native side decides: a range report naming
            // another view, through the page's real message handler, changes
            // the period and never the scale.
            let reportedDay = ShiftDateFormatting.components(
                from: calendar.date(byAdding: .day, value: 3, to: today) ?? today).0
            let droppedBefore = view.debugDroppedViewReports
            _ = js(web, "window.webkit.messageHandlers.\(ShiftCalendarWebView.messageHandlerName).postMessage("
                   + "{ type: 'range', view: 'day', date: '\(reportedDay)', start: '\(reportedDay)', end: '\(reportedDay)' })")
            _ = waitFor(timeout: 3) { view.visibleDays?.start == reportedDay }
            check(view.visibleDays?.start == reportedDay, "a range report should still move the period")
            check(view.scale == .month, "a range report must not change the native scale, got \(view.scale)")
            // R4-ARCH-01: and the view it named is logged as dropped, once.
            check(view.debugDroppedViewReports == droppedBefore + 1,
                  "the range report's own view should be logged and dropped once, counted "
                  + "\(view.debugDroppedViewReports - droppedBefore)")
            _ = call(web, "showDate", ["date": todayDay])
            _ = waitFor(timeout: 3) { view.visibleDays?.start != reportedDay }

            // The one view change Schedule-X makes inside the month grid on
            // the captain's click - "+N more" opens that day - goes through
            // the page's own pill handler, so the native side still follows.
            for index in 0..<5 {
                _ = seed(store, title: "Busy day \(index)", due: todayDay, time: nil, rule: nil)
            }
            controller.render()
            let moreButton = "document.querySelector('.sx__month-grid-day__events-more')"
            _ = waitFor(timeout: 5) { (js(web, "!!\(moreButton)") as? Bool) == true }
            check((js(web, "!!\(moreButton)") as? Bool) == true, "five tasks on one day should draw a \"+N more\" button")
            _ = js(web, "\(moreButton).click()")
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "day" && view.scale == .day }
            check(state(web)["view"] as? String == "day" && view.scale == .day
                    && controller.selectedModuleTabName == "Day",
                  "\"+N more\" should open the day on both sides, got \(state(web)["view"] ?? "nil") / \(view.scale)")

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
                             rule: ShiftRecurrence?, priority: ShiftPriority = .normal) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.priority = priority
        task.dueDate = due
        task.dueTime = time
        task.recurrence = rule
        store.addTask(task)
        return task.id
    }

    /// Mounted hidden, the way the shell mounts a lazy page before it shows
    /// it, so the suite can see the page wait to load.
    private static func mount(store: ShiftStore) -> (TaskCalendarController, NSWindow) {
        let controller = TaskCalendarController(store: store)
        let window = OffScreenProbe.window(width: 1300, height: 950, styleMask: [.titled, .resizable])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 950))
        window.contentView = container
        controller.view.isHidden = true
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.orderFront(nil)
        controller.viewWillAppear()
        drain()
        controller.render()
        container.layoutSubtreeIfNeeded()
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
