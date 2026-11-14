// Grand Line - native macOS app.
//
// The Calendar's page half: a real `TaskCalendarController` (Tasks' Calendar
// view, mounted on its own here) over a scratch store, in a real window, with
// the real vendored Schedule-X page loaded in a real `WKWebView`.
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
//   - a pill in the card and `show(scale:)` are one path: either moves the
//     other, and Agenda is the open-source list view;
//   - the Tasks page's filters reach the calendar (`taskFilter`), and
//     colouring by project paints each chip in its project's calendar;
//   - the card's own Next button pages, and paging re-reads the store;
//   - the page's CSS variables follow a live theme change, light and dark;
//   - hiding the page suspends it, and hiding it at zero width then showing
//     it again keeps the month on both sides (R4-BUG-01): a range report
//     moves the period and never the scale, and "+N more" opens its day
//     through the page's own view handler;
//   - **every open task has a place**: an undated-only store draws its tasks
//     in the Unscheduled tray and the first-run state over the grid rather
//     than "Nothing scheduled", a row's real Today button writes the date to
//     the store (read back from the store), the fold is remembered, and a
//     past month shows the task finished in it, read from `completed/`;
//   - **a check completes from the calendar** (the captain's decision 4A):
//     every real, open chip and Agenda row has one and no projection does,
//     a real press on a repeating task's check completes it and spawns the
//     next instance - read back from `active.yaml` and `completed/` through a
//     fresh store - without opening it or starting a drag, the toast's real
//     Undo puts the series back as it was, and a follow-up's check marks it
//     done.
//   - **drag and quick add** (tasks-calendar plan PR 7), each read back from
//     the store: a tray row dragged onto a month day is dated to it, and onto
//     a week view time slot is dated and timed to it; a chip dragged onto the
//     tray loses its date, in the month grid (HTML5, through the drag plugin)
//     and in the week view (mouse events), and is not also moved to the day
//     it crossed on the way; a repeating chip is refused; and a day's + opens
//     its quick add, the native parser's pills appear under it, and Return
//     adds the task with its time and repeat rule.
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
            check(view.debugCaption.contains("repeat dates not yet created"),
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

            // The card's own Week pill: the native side follows it.
            _ = js(web, "document.querySelector('#gl-views [data-view=\"week\"]').click()")
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "week" && view.scale == .week }
            check(view.scale == .week, "the native side should follow the Week pill, got \(view.scale)")
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

            // MARK: Agenda from the native side

            view.show(scale: .agenda)
            _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "list" }
            check(state(web)["view"] as? String == "list" && state(web)["activePill"] as? String == "list",
                  "Agenda should show Schedule-X's list view with its pill filled")
            _ = js(web, "document.getElementById('gl-today').click()")
            _ = waitFor(timeout: 3) {
                (js(web, "document.querySelectorAll('.sx__list-event').length") as? Int ?? 0) > 0
            }
            check((js(web, "document.querySelectorAll('.sx__list-event').length") as? Int ?? 0) > 0,
                  "the agenda should list this month's records")
            view.show(scale: .month)
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
            check(view.scale == .month,
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

            // Two tabs in quick succession: the page's `view` report for the
            // earlier one can land after the later request. Delivered through
            // the page's real message entry before the page has answered
            // the Agenda request, it must not pull the scale back to Week.
            // (Reached CI once as "Calendar > Agenda left the page on Week".)
            view.show(scale: .week)
            _ = waitFor(timeout: 5) { state(web)["view"] as? String == "week" }
            let staleBefore = view.debugDroppedViewReports
            view.show(scale: .agenda)
            web.debugHandle(message: ["type": "view", "view": "week"])
            // Read before the page's own confirmation arrives: that is the
            // window the toolbar check fell into, and the confirmation would
            // otherwise put the scale right again and hide the defect.
            check(view.scale == .agenda,
                  "a stale view report pulled the scale back to \(view.scale)")
            _ = waitFor(timeout: 5) { state(web)["view"] as? String == "list" }
            check(view.scale == .agenda, "after the page confirmed, the scale is \(view.scale)")
            check(state(web)["view"] as? String == "list",
                  "the page should show the agenda list, it shows \(state(web)["view"] ?? "nil")")
            check(view.debugDroppedViewReports == staleBefore + 1,
                  "the stale report should be logged and dropped once, counted "
                  + "\(view.debugDroppedViewReports - staleBefore)")
            view.show(scale: .month)
            _ = waitFor(timeout: 5) { state(web)["view"] as? String == "month-grid" }

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
            check(state(web)["view"] as? String == "day" && view.scale == .day,
                  "\"+N more\" should open the day on both sides, got \(state(web)["view"] ?? "nil") / \(view.scale)")

            _ = waitFor(timeout: 3) { web.debugPendingCallCount == 0 }
            check(web.debugPendingCallCount == 0, "\(web.debugPendingCallCount) bridge call(s) never got a reply")
        }

        withScratchStore { store in checkTray(store: store, check: check) }
        withScratchStore { store in checkComplete(store: store, check: check) }
        withScratchStore { store in checkDragAndQuickAdd(store: store, check: check) }

        return report(failures)
    }

    // MARK: The Unscheduled tray

    /// The captain's report, reproduced: open tasks, none dated. Before the
    /// tray the grid was empty and the caption said "Nothing scheduled".
    private static func checkTray(store: ShiftStore, check: (Bool, String) -> Void) {
        let defaults = AppDefaults.store
        let foldBefore = defaults.object(forKey: ShiftCalendarView.trayCollapsedDefaultsKey)
        defer {
            if let foldBefore { defaults.set(foldBefore, forKey: ShiftCalendarView.trayCollapsedDefaultsKey) }
            else { defaults.removeObject(forKey: ShiftCalendarView.trayCollapsedDefaultsKey) }
        }
        defaults.set(false, forKey: ShiftCalendarView.trayCollapsedDefaultsKey)

        var infra = ShiftProject.fresh()
        infra.name = "Infra"
        store.addProject(infra)
        let audit = seed(store, title: "Audit IAM keys", due: nil, time: nil, rule: nil, priority: .high)
        if var task = store.activeTasks.first(where: { $0.id == audit }) {
            task.projectID = infra.id
            store.updateTask(task)
        }
        let runbook = seed(store, title: "Review the on-call runbook", due: nil, time: nil, rule: nil)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayDay = ShiftDateFormatting.components(from: today).0

        let (controller, window) = mount(store: store)
        defer { window.orderOut(nil) }
        let view = controller.debugCalendarView
        let web = view.debugWebView
        controller.view.isHidden = false
        controller.view.layoutSubtreeIfNeeded()
        guard waitFor(timeout: 30, until: { web.isReady && view.debugIsConfigured }) else {
            check(false, "the tray case's page never reported ready and configured")
            return
        }
        _ = waitFor(timeout: 5) { (state(web)["trayRows"] as? [String] ?? []).count == 2 }

        // MARK: Undated only: the tray and the first-run state

        let first = state(web)
        check(first["trayVisible"] as? Bool == true, "the Unscheduled tray should be drawn beside the card, got \(first)")
        check(first["trayRows"] as? [String] == [audit, runbook],
              "the tray should list the store's undated tasks, grouped (Infra first), got \(first["trayRows"] ?? "nothing")")
        check(first["trayGroups"] as? [String] == ["Infra · 1", "No project · 1"],
              "the tray's groups should be read from the store's projects, got \(first["trayGroups"] ?? "nothing")")
        check(first["trayCount"] as? String == "2", "the tray's count should be 2, got \(first["trayCount"] ?? "nil")")
        check(first["emptyVisible"] as? Bool == true && first["emptyTitle"] as? String == "Nothing has a date yet",
              "an undated-only store should show the first-run state over the grid, got \(first)")
        check(!view.debugCaption.contains("Nothing scheduled") && view.debugCaption.contains("2 open tasks"),
              "the caption should count the open tasks, not say nothing is scheduled, got \"\(view.debugCaption)\"")
        check(controller.caption == view.debugCaption, "the controller states the same caption the Tasks header carries")
        // The tray takes room from the card rather than covering it.
        let geometry = js(web, "(() => { const c = document.getElementById('gl-card').getBoundingClientRect();"
                          + " const t = document.getElementById('gl-tray').getBoundingClientRect();"
                          + " return [c.right, t.left, t.width, t.right, window.innerWidth] })()") as? [Double] ?? []
        check(geometry.count == 5 && geometry[0] <= geometry[1] && geometry[2] > 200 && geometry[3] <= geometry[4],
              "the tray should sit beside the card, inside the page, got \(geometry)")

        // MARK: Today writes the date

        // The real button, through the page's real listener and the bridge.
        _ = js(web, "document.querySelector('.gl-tray-item[data-task-id=\"\(runbook)\"] .gl-quick[data-when=\"today\"]').click()")
        _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == runbook }?.dueDate == todayDay }
        let scheduled = store.activeTasks.first { $0.id == runbook }
        check(scheduled?.dueDate == todayDay && scheduled?.dueTime == nil,
              "Today on a tray row should date the task today in the store, got \(scheduled?.dueDate ?? "nil")")
        _ = waitFor(timeout: 5) { (state(web)["trayRows"] as? [String] ?? []) == [audit] }
        let after = state(web)
        check(after["trayRows"] as? [String] == [audit], "a dated task should leave the tray, got \(after["trayRows"] ?? "nil")")
        check(after["emptyVisible"] as? Bool == false, "with a dated task the first-run state should give way to the grid")
        _ = waitFor(timeout: 3) { eventIn(web, id: runbook, day: todayDay) }
        check(eventIn(web, id: runbook, day: todayDay), "the scheduled task should be drawn on today")
        check(view.debugCaption.hasPrefix("1 task this month") && view.debugCaption.contains("1 unscheduled"),
              "the caption should count the dated task and the one still unscheduled, got \"\(view.debugCaption)\"")

        // Tomorrow on a follow-up row that is overdue writes the follow-up.
        var lateFollowUp = ShiftFollowUp.fresh()
        lateFollowUp.title = "Ping the registrar"
        lateFollowUp.followUpAt = ShiftDateFormatting.components(
            from: calendar.date(byAdding: .day, value: -3, to: today) ?? today).0
        store.addFollowUp(lateFollowUp)
        controller.render()
        _ = waitFor(timeout: 5) { (state(web)["trayOverdueRows"] as? [String] ?? []) == [lateFollowUp.id] }
        check(state(web)["trayOverdueRows"] as? [String] == [lateFollowUp.id],
              "an overdue follow-up should be pinned in the tray, got \(state(web)["trayOverdueRows"] ?? "nil")")
        let tomorrowDay = ShiftDateFormatting.components(
            from: calendar.date(byAdding: .day, value: 1, to: today) ?? today).0
        _ = js(web, "document.querySelector('.gl-tray-item[data-task-id=\"\(lateFollowUp.id)\"] .gl-quick[data-when=\"tomorrow\"]').click()")
        _ = waitFor(timeout: 5) { store.followUps.first { $0.id == lateFollowUp.id }?.followUpAt == tomorrowDay }
        check(store.followUps.first { $0.id == lateFollowUp.id }?.followUpAt == tomorrowDay,
              "Tomorrow on an overdue follow-up should move its date to tomorrow in the store")

        // MARK: The fold is remembered

        _ = js(web, "document.getElementById('gl-tray-toggle').click()")
        _ = waitFor(timeout: 5) { state(web)["trayCollapsed"] as? Bool == true }
        check(state(web)["trayCollapsed"] as? Bool == true && view.trayCollapsed,
              "the fold button should fold the tray on both sides")
        check(AppDefaults.store.bool(forKey: ShiftCalendarView.trayCollapsedDefaultsKey),
              "the fold should be remembered across launches")
        let folded = js(web, "document.getElementById('gl-tray').getBoundingClientRect().width") as? Double ?? 0
        check(folded > 0 && folded < 60, "a folded tray is a strip, got \(folded)pt wide")
        _ = js(web, "document.getElementById('gl-tray-toggle').click()")
        _ = waitFor(timeout: 5) { state(web)["trayCollapsed"] as? Bool == false }
        check(state(web)["trayCollapsed"] as? Bool == false, "the fold button should open the tray again")

        // MARK: A past month shows what got done in it

        // Due and finished two months ago: outside the board's 7-day Done
        // window, so only the month's own `completed/` file can draw it.
        let pastDue = calendar.date(byAdding: .month, value: -2, to: today) ?? today
        let pastDay = ShiftDateFormatting.components(from: pastDue).0
        let done = seed(store, title: "Patch Tuesday review", due: pastDay, time: nil, rule: nil)
        store.setTaskCompleted(id: done, completed: true,
                               now: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: pastDue) ?? pastDue)
        controller.render()
        _ = call(web, "showDate", ["date": pastDay])
        _ = waitFor(timeout: 5) { eventIn(web, id: done, day: pastDay) }
        check(eventIn(web, id: done, day: pastDay),
              "a task finished two months ago should be drawn on its day when that month is shown")
        let struck = js(web, "(() => { const el = document.querySelector('[data-event-id=\"\(done)\"]');"
                        + " return el ? el.classList.contains('gl-completed') : null })()") as? Bool
        check(struck == true, "a finished task is drawn as finished")
        _ = call(web, "showDate", ["date": todayDay])

        // MARK: Colour by project

        // The Tasks page's Colour by: the legend becomes the store's
        // projects, No project and Follow-up, and a chip with no project is
        // drawn in the neutral calendar rather than its priority's.
        let colouringBefore = defaults.object(forKey: ShiftCalendarColouring.defaultsKey)
        defer {
            if let colouringBefore { defaults.set(colouringBefore, forKey: ShiftCalendarColouring.defaultsKey) }
            else { defaults.removeObject(forKey: ShiftCalendarColouring.defaultsKey) }
        }
        let byProject = [ShiftCalendarPalette.projectCalendarID(infra.id), ShiftCalendarPalette.projectCalendarID(nil),
                         ShiftCalendarCategory.followUp.rawValue]
        controller.setColouring(.project)
        _ = waitFor(timeout: 5) { state(web)["legend"] as? [String] == byProject }
        check(state(web)["legend"] as? [String] == byProject,
              "coloured by project, the legend should name the projects, got \(state(web)["legend"] ?? "nothing")")
        _ = waitFor(timeout: 5) {
            (state(web)["chipEdges"] as? [String] ?? []).contains { $0.contains(ShiftCalendarPalette.projectCalendarID(nil)) }
        }
        let projectEdges = state(web)["chipEdges"] as? [String] ?? []
        check(projectEdges.contains { $0.contains(ShiftCalendarPalette.projectCalendarID(nil)) }
                && !projectEdges.contains { $0.contains(ShiftCalendarCategory.normal.rawValue) },
              "a task with no project should be drawn in the No project colour, got \(projectEdges)")
        check(ShiftCalendarColouring.saved == .project, "the colouring should be remembered across launches")
        controller.setColouring(.priority)
        _ = waitFor(timeout: 5) { state(web)["legend"] as? [String] == ShiftCalendarCategory.allCases.map(\.rawValue) }
        check(state(web)["legend"] as? [String] == ShiftCalendarCategory.allCases.map(\.rawValue),
              "back to priority, the legend names the categories again, got \(state(web)["legend"] ?? "nothing")")

        // MARK: The Tasks page's filters

        // `taskFilter` is how the page's scope and project reach the
        // calendar: a filter that keeps only Infra's tasks takes the dated
        // runbook off today and leaves Infra's undated task in the tray.
        controller.taskFilter = { $0.projectID == infra.id }
        controller.render()
        _ = waitFor(timeout: 5) { !eventIn(web, id: runbook, day: todayDay) }
        check(!eventIn(web, id: runbook, day: todayDay), "a task the filter drops should leave the grid")
        check(state(web)["trayRows"] as? [String] == [audit],
              "the tray should keep only what the filter keeps, got \(state(web)["trayRows"] ?? "nothing")")
        controller.taskFilter = { _ in true }
        controller.render()
        _ = waitFor(timeout: 5) { eventIn(web, id: runbook, day: todayDay) }

        _ = waitFor(timeout: 3) { web.debugPendingCallCount == 0 }
        check(web.debugPendingCallCount == 0, "\(web.debugPendingCallCount) tray bridge call(s) never got a reply")
    }

    // MARK: Completing from the calendar

    private static func checkComplete(store: ShiftStore, check: (Bool, String) -> Void) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayDay = ShiftDateFormatting.components(from: today).0
        let tomorrowDay = ShiftDateFormatting.components(
            from: calendar.date(byAdding: .day, value: 1, to: today) ?? today).0
        let repeating = seed(store, title: "Rotate the on-call pager", due: todayDay, time: "09:30",
                             rule: ShiftRecurrence(frequency: .daily))
        let single = seed(store, title: "Renew wildcard TLS", due: todayDay, time: nil, rule: nil)
        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Ping the registrar"
        followUp.followUpAt = todayDay
        store.addFollowUp(followUp)

        let (controller, window) = mount(store: store)
        defer { window.orderOut(nil) }
        let view = controller.debugCalendarView
        let web = view.debugWebView
        controller.view.isHidden = false
        controller.view.layoutSubtreeIfNeeded()
        guard waitFor(timeout: 30, until: { web.isReady && view.debugIsConfigured }) else {
            check(false, "the completion case's page never reported ready and configured")
            return
        }
        func checks() -> Set<String> { Set((state(web)["checks"] as? [Any] ?? []).compactMap { $0 as? String }) }
        _ = waitFor(timeout: 5) { checks().count >= 3 }

        // MARK: A check on every real chip, none on a projection

        check(checks() == [repeating, single, followUp.id],
              "every real, open chip should carry a check, got \(checks())")
        check(state(web)["projectedChecks"] as? Int == 0, "no projection may carry a check")
        let monthEnd = state(web)["end"] as? String ?? ""
        let projectionID = "\(repeating)@\(tomorrowDay)"
        if tomorrowDay <= monthEnd {
            // The fixture's own discriminating power: the projection really is
            // on the page, so "it has no check" is not vacuous.
            check(js(web, "!!document.querySelector('[data-event-id=\"\(projectionID)\"]')") as? Bool == true,
                  "a daily rule should draw tomorrow's projection")
            check(js(web, "!!document.querySelector('[data-event-id=\"\(projectionID)\"] .gl-check')") as? Bool == false,
                  "a projection must expose no check")
        }
        // A chip's check waits for the pointer; it is not a column of circles.
        let resting = js(web, "getComputedStyle(document.querySelector('[data-event-id=\"\(single)\"] > .gl-check')).opacity")
            as? String
        check(resting == "0", "a chip's check should be hidden until hover, got opacity \(resting ?? "nil")")

        // MARK: The check completes a repeating task, and does nothing else

        let openTask = view.onOpenTask
        let addTask = view.onAddTask
        var opened: String?
        var added: String?
        view.onOpenTask = { opened = $0 }
        view.onAddTask = { day, _ in added = day }
        // A real press, held past the core's 150ms drag timer, then a click.
        press(web, "[data-event-id=\"\(repeating)\"] > .gl-check")
        _ = waitFor(timeout: 5) { !store.activeTasks.contains { $0.id == repeating } }
        drain(turns: 20)
        check(opened == nil, "the check must not also open the task, it opened \(opened ?? "")")
        check(added == nil, "the check must not reach the day's new task, it added on \(added ?? "")")

        // Read back from both files, through a store that has only the disk.
        let disk = ShiftStore()
        let spawned = disk.activeTasks.first { $0.title == "Rotate the on-call pager" }
        check(!disk.activeTasks.contains { $0.id == repeating }, "the completed instance should leave active.yaml")
        check(disk.allCompletedTasks().first { $0.id == repeating }?.status == .completed,
              "the completed instance should be filed in completed/")
        check(spawned != nil && spawned?.id != repeating && spawned?.dueDate == tomorrowDay
                && spawned?.dueTime == "09:30" && spawned?.recurrence != nil,
              "the next instance should be in active.yaml for \(tomorrowDay) 09:30, got "
              + "\(spawned?.dueDate ?? "nil") \(spawned?.dueTime ?? "nil")")

        // The page is redrawn from the store: today's chip finished, with no
        // check, and tomorrow's date the real chip, with one.
        _ = waitFor(timeout: 5) {
            js(web, "(() => { const el = document.querySelector('[data-event-id=\"\(repeating)\"]');"
               + " return !!el && el.classList.contains('gl-completed') })()") as? Bool == true
        }
        check(eventIn(web, id: repeating, day: todayDay), "the finished instance should stay on its day")
        check(js(web, "(() => { const el = document.querySelector('[data-event-id=\"\(repeating)\"]');"
                 + " return !!el && el.classList.contains('gl-completed') && !el.querySelector('.gl-check') })()")
                as? Bool == true,
              "the finished instance should be drawn finished, with no check")
        if let spawned, tomorrowDay <= monthEnd {
            _ = waitFor(timeout: 5) { checks().contains(spawned.id) }
            check(eventIn(web, id: spawned.id, day: tomorrowDay) && checks().contains(spawned.id),
                  "the next instance should be a real chip with a check on \(tomorrowDay)")
        }

        // MARK: Undo puts the series back

        let undo = undoButton(in: controller.view)
        check(undo != nil, "completing from the calendar should offer Undo")
        undo?.performClick(nil)
        drain(turns: 10)
        let restored = ShiftStore()
        check(restored.activeTasks.first { $0.id == repeating }?.status == .todo,
              "Undo should reopen the instance in active.yaml")
        check(!restored.allCompletedTasks().contains { $0.id == repeating },
              "Undo should take the instance out of completed/")
        if let spawned {
            check(!restored.activeTasks.contains { $0.id == spawned.id },
                  "Undo should withdraw the untouched next instance, or the series has two live dates")
        }
        _ = waitFor(timeout: 5) { checks().contains(repeating) }
        check(checks().contains(repeating), "the reopened instance should carry its check again")

        // MARK: Agenda rows

        view.show(scale: .agenda)
        _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "list" }
        _ = waitFor(timeout: 5) {
            (js(web, "document.querySelectorAll('.sx__list-event > .gl-check').length") as? Int ?? 0) >= 3
        }
        check((js(web, "document.querySelectorAll('.sx__list-event > .gl-check').length") as? Int ?? 0) == 3,
              "every real, open Agenda row should carry a check")
        let projectedRows = js(web, "document.querySelectorAll('.sx__list-event.gl-projected').length") as? Int ?? 0
        if projectedRows > 0 {
            check(js(web, "document.querySelectorAll('.sx__list-event.gl-projected .gl-check').length") as? Int == 0,
                  "a projected Agenda row must expose no check")
        }
        let row = "Array.from(document.querySelectorAll('.sx__list-event'))"
            + ".find(r => r.querySelector('.sx__list-event-title').textContent === 'Renew wildcard TLS')"
        let rowOpacity = js(web, "getComputedStyle(\(row).querySelector('.gl-check')).opacity") as? String
        check(rowOpacity == "1", "an Agenda row's check is always shown, got opacity \(rowOpacity ?? "nil")")
        _ = js(web, "\(row).querySelector('.gl-check').click()")
        _ = waitFor(timeout: 5) { !store.activeTasks.contains { $0.id == single } }
        check(ShiftStore().allCompletedTasks().first { $0.id == single }?.status == .completed,
              "an Agenda row's check should complete the task into completed/")
        check(opened == nil, "an Agenda row's check must not also open the task")
        view.onOpenTask = openTask
        view.onAddTask = addTask
        view.show(scale: .month)
        _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "month-grid" }

        // MARK: A follow-up's check

        // The month grid's own chip, not a leftover Agenda row: those carry
        // no event id, so the press would find nothing.
        let followUpCheck = "[data-event-id=\"followup:\(followUp.id)\"] > .gl-check"
        _ = waitFor(timeout: 5) { js(web, "!!document.querySelector('\(followUpCheck)')") as? Bool == true }
        press(web, followUpCheck)
        _ = waitFor(timeout: 5) { store.followUps.first { $0.id == followUp.id }?.status == .done }
        check(ShiftStore().followUps.first { $0.id == followUp.id }?.status == .done,
              "a follow-up's check should mark it done in follow-ups.yaml")

        _ = waitFor(timeout: 3) { web.debugPendingCallCount == 0 }
        check(web.debugPendingCallCount == 0, "\(web.debugPendingCallCount) completion bridge call(s) never got a reply")
    }

    /// The toast's Undo, found in the view it was presented in.
    private static func undoButton(in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.title == "Undo" { return button }
        for sub in root.subviews {
            if let found = undoButton(in: sub) { return found }
        }
        return nil
    }

    // MARK: Drag and quick add

    private static func checkDragAndQuickAdd(store: ShiftStore, check: (Bool, String) -> Void) {
        let defaults = AppDefaults.store
        let foldBefore = defaults.object(forKey: ShiftCalendarView.trayCollapsedDefaultsKey)
        defer {
            if let foldBefore { defaults.set(foldBefore, forKey: ShiftCalendarView.trayCollapsedDefaultsKey) }
            else { defaults.removeObject(forKey: ShiftCalendarView.trayCollapsedDefaultsKey) }
        }
        defaults.set(false, forKey: ShiftCalendarView.trayCollapsedDefaultsKey)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayDay = ShiftDateFormatting.components(from: today).0
        // A day in the month on screen other than today: two days on, or two
        // back when that would leave the month.
        func dayInMonth(_ offset: Int) -> String {
            let forward = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            if calendar.component(.month, from: forward) == calendar.component(.month, from: today) {
                return ShiftDateFormatting.components(from: forward).0
            }
            return ShiftDateFormatting.components(from: calendar.date(byAdding: .day, value: -offset, to: today) ?? today).0
        }
        let targetDay = dayInMonth(2)
        let crossedDay = dayInMonth(3)

        let rfc = seed(store, title: "Draft the RFC", due: nil, time: nil, rule: nil)
        let venue = seed(store, title: "Book the venue", due: nil, time: nil, rule: nil)
        let cert = seed(store, title: "Renew the cert", due: todayDay, time: nil, rule: nil)
        let standup = seed(store, title: "Standup", due: todayDay, time: nil, rule: ShiftRecurrence(frequency: .weekly))
        let deploy = seed(store, title: "Deploy window", due: todayDay, time: "14:00", rule: nil)

        let (controller, window) = mount(store: store)
        defer { window.orderOut(nil) }
        let view = controller.debugCalendarView
        let web = view.debugWebView
        controller.view.isHidden = false
        controller.view.layoutSubtreeIfNeeded()
        guard waitFor(timeout: 30, until: { web.isReady && view.debugIsConfigured }) else {
            check(false, "the drag case's page never reported ready and configured")
            return
        }
        _ = waitFor(timeout: 5) { (state(web)["trayRows"] as? [String] ?? []).count == 2 }
        let first = state(web)
        check(first["trayDraggableRows"] as? Int == 2, "every tray row should be draggable, got \(first["trayDraggableRows"] ?? "nil")")
        check(first["trayDropHint"] as? String == ShiftCalendarPayload.trayDropHint,
              "the tray should say a chip can be dropped on it, got \(first["trayDropHint"] ?? "nil")")

        // MARK: A tray row onto a month day

        _ = waitFor(timeout: 5) {
            (js(web, "!!document.querySelector('.sx__month-grid-day[data-date=\"\(targetDay)\"]')") as? Bool) == true
                && eventIn(web, id: cert, day: todayDay)
        }
        let monthDrop = trayRowDrag(web, taskID: rfc, toDay: targetDay, minutes: nil)
        check(monthDrop["shown"] as? Bool == true && (monthDrop["label"] as? String ?? "").hasPrefix("Drop to schedule"),
              "dragging a tray row over a day should draw the drop target with its day, got \(monthDrop)")
        _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == rfc }?.dueDate == targetDay }
        let placed = store.activeTasks.first { $0.id == rfc }
        check(placed?.dueDate == targetDay && placed?.dueTime == nil,
              "a tray row dropped on \(targetDay) should be due that day, all day, got "
              + "\(placed?.dueDate ?? "nil") \(placed?.dueTime ?? "nil")")
        _ = waitFor(timeout: 5) { !((state(web)["trayRows"] as? [String] ?? []).contains(rfc)) }
        let afterPlace = state(web)
        check(!(afterPlace["trayRows"] as? [String] ?? []).contains(rfc), "the dated row should leave the tray")
        check(afterPlace["dropVisible"] as? Bool == false, "the drop target should go away with the drag")
        _ = waitFor(timeout: 3) { eventIn(web, id: rfc, day: targetDay) }
        check(eventIn(web, id: rfc, day: targetDay), "the placed task should be drawn on its day")

        // MARK: A chip onto the tray, in the month grid

        // Over a day first, so the drag plugin has somewhere it would move
        // the chip to: the tray must win, and the day must not.
        let monthBack = monthChipToTray(web, eventID: cert, overDay: crossedDay)
        check(monthBack["highlighted"] as? Bool == true,
              "a chip held over the tray should light the tray as the target, got \(monthBack)")
        _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == cert }?.dueDate == nil }
        drain(turns: 30)
        let cleared = store.activeTasks.first { $0.id == cert }
        check(cleared != nil && cleared?.dueDate == nil && cleared?.dueTime == nil,
              "a chip dropped on the tray should lose its date in the store, got \(cleared?.dueDate ?? "nil")")
        _ = waitFor(timeout: 5) { (state(web)["trayRows"] as? [String] ?? []).contains(cert) }
        check((state(web)["trayRows"] as? [String] ?? []).contains(cert), "the chip should come back as a tray row")
        check(!eventIn(web, id: cert, day: crossedDay) && !eventIn(web, id: cert, day: todayDay),
              "the chip must not also be moved to the day it crossed")

        // A repeating chip keeps its date: its rule is anchored on it.
        _ = monthChipToTray(web, eventID: standup, overDay: crossedDay)
        drain(turns: 40)
        let kept = store.activeTasks.first { $0.id == standup }
        check(kept?.dueDate == todayDay && kept?.recurrence != nil,
              "a repeating chip dropped on the tray must keep its date and rule, got \(kept?.dueDate ?? "nil")")

        // MARK: The week view: a tray row onto a time, and a timed chip back

        _ = js(web, "document.querySelector('#gl-views [data-view=\"week\"]').click()")
        _ = waitFor(timeout: 5) { (state(web)["view"] as? String) == "week" && view.scale == .week }
        let weekStart = state(web)["start"] as? String ?? todayDay
        let slotDay = todayDay >= weekStart ? todayDay : weekStart
        // The view's pill answers before Schedule-X has drawn the new grid.
        _ = waitFor(timeout: 5) {
            (js(web, "!!document.querySelector('.sx__time-grid-day[data-time-grid-date=\"\(slotDay)\"]')") as? Bool) == true
        }
        let slot = trayRowDrag(web, taskID: venue, toDay: slotDay, minutes: 15 * 60)
        check(slot["shown"] as? Bool == true && (slot["label"] as? String ?? "").hasPrefix("15:00"),
              "dragging a tray row over 15:00 should draw the slot it lands on, got \(slot)")
        _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == venue }?.dueTime == "15:00" }
        let timed = store.activeTasks.first { $0.id == venue }
        check(timed?.dueDate == slotDay && timed?.dueTime == "15:00",
              "a tray row dropped on \(slotDay) at 15:00 should be due then, got "
              + "\(timed?.dueDate ?? "nil") \(timed?.dueTime ?? "nil")")

        _ = waitFor(timeout: 3) {
            (js(web, "!!document.querySelector('.sx__time-grid-event[data-event-id=\"\(deploy)\"]')") as? Bool) == true
        }
        let weekBack = timeGridChipToTray(web, eventID: deploy)
        check(weekBack["highlighted"] as? Bool == true,
              "a time grid chip held over the tray should light the tray, got \(weekBack)")
        _ = waitFor(timeout: 5) { store.activeTasks.first { $0.id == deploy }?.dueDate == nil }
        let unscheduled = store.activeTasks.first { $0.id == deploy }
        check(unscheduled?.dueDate == nil && unscheduled?.dueTime == nil,
              "a timed chip dragged onto the tray should lose its date and time, got "
              + "\(unscheduled?.dueDate ?? "nil") \(unscheduled?.dueTime ?? "nil")")

        // MARK: Quick add in a day

        view.show(scale: .month)
        _ = waitFor(timeout: 5) { state(web)["view"] as? String == "month-grid" }
        _ = waitFor(timeout: 5) {
            (js(web, "!!document.querySelector('.sx__month-grid-day[data-date=\"\(todayDay)\"]')") as? Bool) == true
        }
        let hover = """
        const cell = document.querySelector(`.sx__month-grid-day[data-date="${day}"]`);
        if (!cell) return 'missing';
        const r = cell.getBoundingClientRect();
        cell.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, clientX: r.x + 20, clientY: r.y + 40}));
        return 'ok';
        """
        _ = asyncJS(web, hover, ["day": todayDay])
        let hovered = state(web)
        check(hovered["cellAddVisible"] as? Bool == true && hovered["cellAddDay"] as? String == todayDay,
              "hovering a day should show its + button, got \(hovered["cellAddVisible"] ?? "nil") / \(hovered["cellAddDay"] ?? "nil")")
        _ = js(web, "document.getElementById('gl-cell-add').click()")
        let opened = state(web)
        check(opened["quickAddOpen"] as? Bool == true && opened["quickAddDay"] as? String == todayDay
              && opened["quickAddFocused"] as? Bool == true,
              "the + should open a focused title field on its day, got \(opened)")

        let type = """
        const input = document.getElementById('gl-quick-add-input');
        input.value = text;
        input.dispatchEvent(new Event('input', {bubbles: true}));
        return 'ok';
        """
        _ = asyncJS(web, type, ["text": "Patch notes every tue 10am"])
        _ = waitFor(timeout: 5) { (state(web)["quickAddPills"] as? [String] ?? []).count == 3 }
        let pills = state(web)["quickAddPills"] as? [String] ?? []
        check(pills.count == 3 && pills.last?.contains("Every Tue") == true
              && pills.contains(ShiftDateFormatting.clock("10:00")),
              "the field should show the parsed day, time and rule as pills, got \(pills)")

        _ = js(web, "document.getElementById('gl-quick-add-input').dispatchEvent("
               + "new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}))")
        _ = waitFor(timeout: 5) { store.activeTasks.contains { $0.title == "Patch notes" } }
        let added = store.activeTasks.first { $0.title == "Patch notes" }
        var firstTuesday = today
        while calendar.component(.weekday, from: firstTuesday) != 3 {
            firstTuesday = calendar.date(byAdding: .day, value: 1, to: firstTuesday) ?? firstTuesday
        }
        check(added?.dueDate == ShiftDateFormatting.components(from: firstTuesday).0 && added?.dueTime == "10:00"
              && added?.recurrence == ShiftRecurrence(frequency: .weekly, weekdays: [3]),
              "Return should add \"Patch notes\" on the first Tuesday from today at 10:00, every Tuesday, got "
              + "\(added?.dueDate ?? "nil") \(added?.dueTime ?? "nil") \(added?.recurrence?.ruleText ?? "no rule")")
        check(state(web)["quickAddOpen"] as? Bool == false, "Return should put the field away")

        // Escape puts it away and adds nothing.
        let countBefore = store.activeTasks.count
        _ = asyncJS(web, hover, ["day": targetDay])
        _ = js(web, "document.getElementById('gl-cell-add').click()")
        _ = asyncJS(web, type, ["text": "Never mind"])
        _ = js(web, "document.getElementById('gl-quick-add-input').dispatchEvent("
               + "new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")
        drain(turns: 20)
        check(state(web)["quickAddOpen"] as? Bool == false && store.activeTasks.count == countBefore,
              "Escape should close the field and add nothing")

        _ = waitFor(timeout: 3) { web.debugPendingCallCount == 0 }
        check(web.debugPendingCallCount == 0, "\(web.debugPendingCallCount) drag bridge call(s) never got a reply")
    }

    // MARK: Driving the page

    /// A pointer's press on one element: down, held past the core's 150ms
    /// drag timer, up, then the click the browser would send.
    private static func press(_ web: WKWebView, _ selector: String) {
        let script = """
        const el = document.querySelector(selector);
        if (!el) return 'missing';
        const r = el.getBoundingClientRect();
        const at = {bubbles: true, cancelable: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2};
        el.dispatchEvent(new MouseEvent('mousedown', at));
        await new Promise(resolve => setTimeout(resolve, 220));
        el.dispatchEvent(new MouseEvent('mouseup', at));
        el.dispatchEvent(new MouseEvent('click', at));
        return 'ok';
        """
        _ = asyncJS(web, script, ["selector": selector])
    }

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

    /// A tray row dragged onto a month day, or onto a time slot in the week
    /// or day view (`minutes` after midnight). HTML5, as a pointer drives it:
    /// `dragstart` on the row, `dragover` and `drop` on the target, `dragend`
    /// on the row. Returns whether the drop target was drawn, and its label.
    private static func trayRowDrag(_ web: WKWebView, taskID: String, toDay day: String,
                                    minutes: Int?) -> [String: Any] {
        let script = """
        const row = document.querySelector(`.gl-tray-item[data-task-id="${taskID}"]`);
        const target = minutes === null
          ? document.querySelector(`.sx__month-grid-day[data-date="${day}"]`)
          : document.querySelector(`.sx__time-grid-day[data-time-grid-date="${day}"]`);
        if (!row || !target) return {missing: !row ? 'row' : 'target'};
        const t = target.getBoundingClientRect();
        const x = t.x + 10;
        const y = minutes === null ? t.y + 30 : t.y + (minutes + 5) / (24 * 60) * t.height;
        row.dispatchEvent(new DragEvent('dragstart', {bubbles: true}));
        target.dispatchEvent(new DragEvent('dragover', {bubbles: true, cancelable: true, clientX: x, clientY: y}));
        const shown = !document.getElementById('gl-drop').hidden;
        const label = document.getElementById('gl-drop-label').textContent;
        target.dispatchEvent(new DragEvent('drop', {bubbles: true, cancelable: true, clientX: x, clientY: y}));
        row.dispatchEvent(new DragEvent('dragend', {bubbles: true}));
        return {shown, label};
        """
        // `null` is how "a month day, no time" reaches the script.
        let minutesArgument: Any = minutes.map { $0 as Any } ?? NSNull()
        return asyncJS(web, script, ["taskID": taskID, "day": day, "minutes": minutesArgument]) as? [String: Any] ?? [:]
    }

    /// A month-grid chip dragged over `overDay` and then onto the tray: the
    /// plugin's own HTML5 drag, so the tray gets `dragover` and `drop` and the
    /// plugin its `dragend` after them, in the order WebKit sends them.
    private static func monthChipToTray(_ web: WKWebView, eventID: String, overDay: String) -> [String: Any] {
        let script = """
        const el = document.querySelector(`.sx__month-grid-event[data-event-id="${eventID}"]`);
        const day = document.querySelector(`.sx__month-grid-day[data-date="${overDay}"]`);
        const tray = document.getElementById('gl-tray');
        if (!el || !day) return {missing: !el ? 'chip' : 'day'};
        const r = el.getBoundingClientRect();
        el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: r.x + 4, clientY: r.y + 4}));
        await new Promise(resolve => setTimeout(resolve, 220));
        const d = day.getBoundingClientRect();
        day.dispatchEvent(new DragEvent('dragover', {bubbles: true, cancelable: true, clientX: d.x + 10, clientY: d.y + 30}));
        const t = tray.getBoundingClientRect();
        const at = {bubbles: true, cancelable: true, clientX: t.x + t.width / 2, clientY: t.y + t.height / 2};
        tray.dispatchEvent(new DragEvent('dragover', at));
        const highlighted = tray.classList.contains('is-drop-target');
        tray.dispatchEvent(new DragEvent('drop', at));
        document.dispatchEvent(new DragEvent('dragend', {bubbles: true}));
        document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
        return {highlighted};
        """
        return asyncJS(web, script, ["eventID": eventID, "overDay": overDay]) as? [String: Any] ?? [:]
    }

    /// A time grid chip dragged onto the tray: the plugin's mouse-driven
    /// drag, down on the chip and move and up on the document, with the
    /// button held through the move.
    private static func timeGridChipToTray(_ web: WKWebView, eventID: String) -> [String: Any] {
        let script = """
        const el = document.querySelector(`.sx__time-grid-event[data-event-id="${eventID}"]`);
        const tray = document.getElementById('gl-tray');
        if (!el) return {missing: 'chip'};
        el.scrollIntoView();
        const r = el.getBoundingClientRect();
        const t = tray.getBoundingClientRect();
        const x = t.x + t.width / 2, y = t.y + t.height / 2;
        el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, buttons: 1, clientX: r.x + 4, clientY: r.y + 4}));
        await new Promise(resolve => setTimeout(resolve, 220));
        document.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, buttons: 1, clientX: x, clientY: y}));
        await new Promise(resolve => setTimeout(resolve, 50));
        const highlighted = tray.classList.contains('is-drop-target');
        document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, clientX: x, clientY: y}));
        return {highlighted};
        """
        return asyncJS(web, script, ["eventID": eventID]) as? [String: Any] ?? [:]
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
