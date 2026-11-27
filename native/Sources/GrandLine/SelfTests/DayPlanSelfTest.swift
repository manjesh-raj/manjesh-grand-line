// Grand Line - native macOS app.
//
// F-02 of full review 4: plan my day, and close it.
// Run with `FM_RUN_DAY_PLAN_TESTS=1 .build/debug/GrandLine`.
//
// Headless. Real `ShiftStore`, `DayPlanStore` and `FocusTimerController`
// over scratch folders; the sheets are built and driven through their real
// buttons, never presented.
//
// What it pins:
//
//  - **Step 1's groups**: overdue, due today, carried over, backlog, in that
//    order, with their "when" words; the default ticks are the first three
//    dated or carried tasks and never the backlog.
//  - **Three is the cap**, through the rows' own check badges.
//  - **Placing around meetings**, and what happens on a full day.
//  - **Dragging and resizing** snap to the quarter hour and stay in the day,
//    through the timeline's own drag path.
//  - **Saving starts the first focus session**, and a second save while one
//    runs does not restart it.
//  - **Home's hero**: the plan's words and the actions for each part of the
//    day.
//  - **Close the day** completes the ticked, moves the rest, keeps the note.
//  - **The bell's nudges**, once a day each.
//  - **The store**: round trip, the month cap, an older file, an unreadable
//    file kept aside (GL-01).
//  - **Source guards** on Home's hero and the nudger's start.

#if FM_SELFTESTS

import AppKit

enum DayPlanSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("step 1's groups and default ticks", test_groups),
            ("three is the cap", test_cap),
            ("placing around meetings", test_place),
            ("dragging and resizing snap and stay in the day", test_drag),
            ("free time and clashes", test_free),
            ("saving starts the first focus session", test_saveStartsFocus),
            ("Home's hero words and actions", test_hero),
            ("close the day", test_close),
            ("the bell's nudges", test_nudges),
            ("the store", test_store),
            ("Home and the nudger are wired", test_wiring),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[day-plan] \(name): \(failure)", &ok) } else { print("[day-plan] PASS \(name)") }
        }
        print(ok ? "[day-plan] ALL PASS" : "[day-plan] FAILED")
        return ok
    }

    // MARK: Fixtures

    /// Wednesday 25 November 2026, local; times are set per case.
    static func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25 + dayOffset, hour: 12))!
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func day(_ offset: Int) -> String { DayPlanRules.dayString(at(12, dayOffset: offset)) }

    static func task(_ id: String, due: String? = nil, time: String? = nil, status: ShiftTaskStatus = .todo,
                     priority: ShiftPriority = .normal) -> ShiftTask {
        ShiftTask(id: id, title: id, description: "", status: status, priority: priority, dueDate: due,
                  dueTime: time, projectID: nil, tags: [], createdAt: "2026-11-01T00:00:00Z",
                  updatedAt: "2026-11-01T00:00:00Z", completedAt: nil, notes: nil, subtasks: [], hasAttachment: false)
    }

    static func meeting(_ title: String, _ start: Date, _ end: Date) -> MacMeeting {
        MacMeeting(id: title, title: title, start: start, end: end, isAllDay: false, calendarID: "work",
                   calendarTitle: "Work", calendarSource: "Exchange", colorHex: "3D6BE8", location: nil,
                   organizer: nil, attendeeCount: 4)
    }

    static var wednesday: [MacMeeting] {
        [meeting("Platform stand-up", at(9, 30), at(9, 45)), meeting("4.20 release review", at(11), at(11, 45)),
         meeting("Lunch with Arjun", at(12, 30), at(13, 30)), meeting("Vendor call", at(15, 30), at(16, 30))]
    }

    static var fixtureTasks: [ShiftTask] {
        [task("Renew the staging TLS certificate", due: day(-2), priority: .high),
         task("Rotate the CI deploy key", due: day(0), priority: .high),
         task("Check the backup failure", due: day(0), time: "15:00"),
         task("Write the 4.20 release notes", status: .inProgress),
         task("Tidy the alert routes"),
         task("Cut the 4.20 release branch", due: day(3)),
         task("Draft the SRE job description", due: day(7)),
         task("Book the DR drill", due: day(14)),
         task("Review the on-call runbook", priority: .low),
         task("Already done", due: day(0), status: .completed)]
    }

    /// A scratch Shift store holding `tasks`, a scratch plan store, and a
    /// timer over that store. `body` runs with the shift folder in place.
    static func withStores<T>(_ tasks: [ShiftTask], _ body: (ShiftStore, DayPlanStore, FocusTimerController) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("day-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", dir.appendingPathComponent("shift").path, 1)
        defer { if let saved { setenv("FM_SHIFT_DIR", saved, 1) } else { unsetenv("FM_SHIFT_DIR") } }
        let store = ShiftStore()
        for t in tasks { store.addTask(t) }
        let plans = DayPlanStore(directory: dir.appendingPathComponent("plans"))
        let timer = FocusTimerController(store: store)
        defer { _ = timer.stop() }
        return body(store, plans, timer)
    }

    // MARK: Cases

    static func test_groups() -> String? {
        let groups = DayPlanRules.candidates(tasks: fixtureTasks, carried: ["Tidy the alert routes"], now: at(9, 41))
        guard groups.map(\.group) == [.overdue, .dueToday, .carriedOver, .backlog] else { return "groups \(groups.map(\.group))" }
        let words = groups.flatMap { $0.items.map { "\($0.task.id)|\($0.when)" } }
        let expected = ["Renew the staging TLS certificate|Overdue 2 days",
                        "Rotate the CI deploy key|Today",
                        "Check the backup failure|Today at \(ShiftDateFormatting.clock("15:00"))",
                        "Tidy the alert routes|Not done yesterday",
                        "Write the 4.20 release notes|In progress",
                        "Cut the 4.20 release branch|\(ShiftDateFormatting.monthDay(at(12, dayOffset: 3)))",
                        "Draft the SRE job description|\(ShiftDateFormatting.monthDay(at(12, dayOffset: 7)))",
                        "Book the DR drill|\(ShiftDateFormatting.monthDay(at(12, dayOffset: 14)))",
                        "Review the on-call runbook|No date"]
        guard words == expected else { return "words \(words)" }
        guard !words.contains(where: { $0.hasPrefix("Already done") }) else { return "a completed task was offered" }
        guard DayPlanRules.defaultPicks(groups) == ["Renew the staging TLS certificate", "Rotate the CI deploy key",
                                                    "Check the backup failure"] else {
            return "default ticks \(DayPlanRules.defaultPicks(groups))"
        }
        let quiet = DayPlanRules.candidates(tasks: [task("Book the DR drill", due: day(14)), task("Read the RFC")], carried: [], now: at(9))
        guard quiet.map(\.group) == [.backlog], DayPlanRules.defaultPicks(quiet).isEmpty else {
            return "a day with nothing due pre-ticked the backlog"
        }
        return nil
    }

    static func test_cap() -> String? {
        withStores(fixtureTasks) { store, plans, timer in
            let sheet = PlanMyDaySheet(store: store, plans: plans, meetings: [], timer: timer, clock: { at(9, 41) })
            sheet.loadView()
            guard sheet.debugTitle == "Pick up to three for today" else { return "title \(sheet.debugTitle)" }
            guard sheet.picked.count == 3, sheet.debugCount == "3 of 3 picked. Untick one to choose another." else {
                return "opened with \(sheet.picked) / \(sheet.debugCount)"
            }
            guard let fourth = sheet.debugRows.first(where: { !sheet.picked.contains($0.taskID) }) else { return "no fourth row" }
            fourth.debugClickBadge()
            guard sheet.picked.count == 3, !sheet.picked.contains(fourth.taskID) else { return "a fourth task was picked" }
            guard fourth.alphaValue < 1 else { return "an unpickable row is not dimmed" }
            let first = sheet.debugRows[0]
            first.debugClickBadge()
            guard sheet.picked.count == 2, sheet.debugCount == "2 of 3 picked." else { return "untick: \(sheet.debugCount)" }
            fourth.debugClickBadge()
            return sheet.picked.contains(fourth.taskID) ? nil : "a freed slot could not be used"
        }
    }

    static func test_place() -> String? {
        let picks = [task("A"), task("B"), task("C")]
        let items = DayPlanRules.place(picks, meetings: wednesday, now: at(9, 41))
        let starts = items.map { DayPlanRules.clock(minute: $0.startMinute) }
        guard starts == ["9:45", "11:45", "13:30"], items.allSatisfy({ $0.minutes == 45 }) else { return "placed at \(starts)" }
        guard items.allSatisfy({ DayPlanRules.clash($0, meetings: wednesday, on: at(9)) == nil }) else { return "a pick overlaps a meeting" }
        // Before the day starts, the first slot is 9:00.
        guard DayPlanRules.place([task("A")], meetings: [], now: at(7)).first?.startMinute == 9 * 60 else { return "an early plan did not start at 9:00" }
        // A booked day still keeps the pick, at the end of the day.
        let booked = [meeting("All day workshop", at(9), at(18))]
        guard let late = DayPlanRules.place([task("A")], meetings: booked, now: at(9)).first,
              late.startMinute == 17 * 60 + 15 else { return "a booked day lost the pick" }
        return nil
    }

    static func test_drag() -> String? {
        let item = DayPlan.Item(taskID: "A", title: "A", startMinute: 10 * 60, minutes: 45)
        guard DayPlanRules.moved(item, toStart: 9 * 60 + 52).startMinute == 9 * 60 + 45 else { return "a move did not snap" }
        guard DayPlanRules.moved(item, toStart: 7 * 60).startMinute == 9 * 60 else { return "a move left the morning" }
        guard DayPlanRules.moved(item, toStart: 19 * 60).startMinute == 17 * 60 + 15 else { return "a move left the evening" }
        guard DayPlanRules.resized(item, toEnd: 10 * 60 + 5).minutes == 15 else { return "a resize went below a quarter hour" }
        guard DayPlanRules.resized(item, toEnd: 11 * 60 + 35).minutes == 90 else { return "a resize did not snap" }
        guard DayPlanRules.resized(item, toEnd: 20 * 60).endMinute == 18 * 60 else { return "a resize left the day" }

        // The timeline's own drag path: grab the block's middle, pull down an hour.
        let view = DayPlanTimelineView(items: [item], meetings: [], day: at(9))
        view.frame.size.width = 440
        var changed: [DayPlan.Item]?
        view.onChange = { changed = $0 }
        let r = view.rect(for: item)
        view.beginDrag(at: NSPoint(x: r.midX, y: r.midY))
        view.continueDrag(to: NSPoint(x: r.midX, y: r.midY + DayPlanTimelineView.hourHeight))
        view.endDrag()
        guard changed?.first?.startMinute == 11 * 60, changed?.first?.minutes == 45 else { return "drag gave \(String(describing: changed))" }
        // And the bottom edge resizes.
        let moved = view.rect(for: view.items[0])
        view.beginDrag(at: NSPoint(x: moved.midX, y: moved.maxY - 2))
        view.continueDrag(to: NSPoint(x: moved.midX, y: moved.maxY - 2 + DayPlanTimelineView.hourHeight / 2))
        view.endDrag()
        return changed?.first?.minutes == 75 && changed?.first?.startMinute == 11 * 60
            ? nil : "edge drag gave \(String(describing: changed))"
    }

    static func test_free() -> String? {
        let items = DayPlanRules.place([task("A"), task("B"), task("C")], meetings: wednesday, now: at(9, 41))
        // 9:45 to 18:00 is 495 minutes; meetings take 45 + 60 + 60, picks 135.
        let free = DayPlanRules.freeMinutes(items: items, meetings: wednesday, now: at(9, 45))
        guard free == 495 - 165 - 135 else { return "free \(free)" }
        guard DayPlanRules.freeSentence(free) == "3h 15m still free" else { return DayPlanRules.freeSentence(free) }
        guard DayPlanRules.freeMinutes(items: [], meetings: [], now: at(19)) == 0,
              DayPlanRules.freeSentence(0) == "The rest of the day is full." else { return "after hours" }
        let clashing = DayPlan.Item(taskID: "A", title: "A", startMinute: 11 * 60 + 30, minutes: 30)
        return DayPlanRules.clash(clashing, meetings: wednesday, on: at(9))?.title == "4.20 release review"
            ? nil : "an overlap was not found"
    }

    static func test_saveStartsFocus() -> String? {
        withStores(fixtureTasks) { store, plans, timer in
            let sheet = PlanMyDaySheet(store: store, plans: plans, meetings: wednesday, timer: timer, clock: { at(9, 41) })
            sheet.loadView()
            sheet.debugNext()
            guard sheet.step == 2, sheet.debugTitle == "Place them on today" else { return "step 2 did not open" }
            guard sheet.debugNextButton?.title == "Start focus" else { return "step 2's button: \(sheet.debugNextButton?.title ?? "nil")" }
            guard sheet.debugFree.hasSuffix("still free.") else { return "free line \(sheet.debugFree)" }
            sheet.debugSave()
            guard let plan = plans.plan(on: at(9, 41)), plan.items.count == 3 else { return "the plan was not saved" }
            guard plan.items.map({ DayPlanRules.clock(minute: $0.startMinute) }) == ["9:45", "11:45", "13:30"] else {
                return "saved at \(plan.items.map(\.startMinute))"
            }
            guard timer.session?.taskID == plan.items[0].taskID else { return "the first focus session did not start" }
            // Changing the plan while focusing keeps the session and saves.
            let again = PlanMyDaySheet(store: store, plans: plans, meetings: wednesday, timer: timer, clock: { at(10) })
            again.loadView()
            guard again.picked == plan.items.map(\.taskID) else { return "Change the plan did not start from the plan" }
            again.debugNext()
            guard again.debugNextButton?.title == "Save the plan" else { return "a running session was offered a restart" }
            let started = timer.session?.startedAt
            again.debugSave()
            return timer.session?.startedAt == started ? nil : "saving restarted the running session"
        }
    }

    static func test_hero() -> String? {
        let plan = DayPlan(day: day(0), setAt: at(9, 41), items: [
            .init(taskID: "b", title: "Renew the staging TLS certificate", startMinute: 14 * 60, minutes: 90),
            .init(taskID: "a", title: "Rotate the CI deploy key", startMinute: 9 * 60 + 45, minutes: 45),
        ])
        let words = DayPlanRules.heroWords(plan, completed: [], date: "Wednesday, 25 November")
        guard words.kicker == "Wednesday, 25 November \u{00B7} Today\u{2019}s plan \u{00B7} 0 of 2 done \u{00B7} set at 9:41" else { return words.kicker }
        guard words.title == "First up: Rotate the CI deploy key" else { return words.title }
        guard words.tiles.map({ $0.label ?? "" }) == ["9:45 \u{00B7} 45 min", "14:00 \u{00B7} 1h 30m"] else { return "tiles \(words.tiles)" }
        let half = DayPlanRules.heroWords(plan, completed: ["a"], date: "")
        guard half.title == "First up: Renew the staging TLS certificate", half.tiles[0].tint == .good else { return "a done item" }
        guard DayPlanRules.heroWords(plan, completed: ["a", "b"], date: "").title.hasPrefix("All 2 done") else { return "all done" }

        func actions(_ p: DayPlan?, focusing: Bool = false, hour: Int = 10, completed: Set<String> = []) -> [DayPlanRules.Action] {
            DayPlanRules.heroActions(plan: p, hasCandidates: true, focusing: focusing, completed: completed, now: at(hour))
        }
        guard actions(nil) == [.startFocus, .planMyDay], actions(nil, focusing: true) == [.planMyDay] else { return "no plan" }
        guard actions(plan) == [.startFocus, .changePlan], actions(plan, focusing: true) == [.changePlan] else { return "morning plan" }
        guard actions(plan, hour: 18) == [.startFocus, .closeDay], actions(plan, hour: 18, completed: ["a", "b"]) == [.closeDay] else {
            return "evening plan"
        }
        var closed = plan
        closed.closedAt = at(18)
        guard actions(closed).isEmpty else { return "a closed day still offered actions" }
        return DayPlanRules.focusStatus(endsAt: at(10, 6)) == "Focusing until 10:06" ? nil : "focus status"
    }

    static func test_close() -> String? {
        let tasks = [task("Rotate the CI deploy key", due: day(0)), task("Write the release notes"),
                     task("Renew the staging TLS certificate", due: day(-2))]
        return withStores(tasks) { store, plans, _ in
            let plan = DayPlan(day: day(0), setAt: at(9, 41), items: tasks.enumerated().map {
                .init(taskID: $0.element.id, title: $0.element.title, startMinute: 10 * 60 + $0.offset * 60, minutes: 45)
            })
            plans.save(plan)
            store.logFocusSession(taskID: tasks[0].id, taskTitle: tasks[0].title, seconds: 52 * 60, now: at(10, 40))
            let sheet = CloseTheDaySheet(plan: plan, store: store, plans: plans, meetingCount: 3, clock: { at(18, 5) })
            sheet.loadView()
            guard sheet.debugRows.count == 3, sheet.debugRows[0].debugDetail == "focus 52 min" else {
                return "rows \(sheet.debugRows.map(\.debugDetail))"
            }
            guard sheet.debugHeadline == "None of 3 done. Tomorrow is another go." else { return sheet.debugHeadline }
            sheet.debugRows[0].debugClickBadge()
            sheet.debugRows[1].debugClickBadge()
            guard sheet.debugHeadline == "2 of 3 done. Nice work.",
                  sheet.debugDetail == "Focus 52 min \u{00B7} 3 meetings \u{00B7} 1 task to move" else {
                return "\(sheet.debugHeadline) / \(sheet.debugDetail)"
            }
            sheet.debugChoose("backlog", for: tasks[2].id)
            sheet.debugSetNote("  Waiting on the CA. Chase at 10.  ")
            sheet.debugClose()
            let open = store.activeTasks.filter(DayPlanRules.isOpen).map(\.id)
            guard open == [tasks[2].id] else { return "still open: \(open)" }
            guard let moved = store.activeTasks.first(where: { $0.id == tasks[2].id }), moved.dueDate == nil else {
                return "Back to backlog kept the due date"
            }
            guard let closed = plans.plan(on: at(18)), closed.closedAt != nil,
                  closed.tomorrowNote == "Waiting on the CA. Chase at 10." else { return "the plan was not closed with its note" }
            let tomorrow = DayPlanRules.applying(.tomorrow, to: task("x", due: day(0), time: "09:00"), now: at(18))
            guard tomorrow.dueDate == day(1), tomorrow.dueTime == nil else { return "Tomorrow moved to \(tomorrow.dueDate ?? "nil")" }
            // Tomorrow's sheet shows the note and offers the undone task as carried.
            let next = PlanMyDaySheet(store: store, plans: plans, meetings: [], timer: nil, clock: { at(9, 5, dayOffset: 1) })
            next.loadView()
            return next.debugRows.contains { $0.taskID == tasks[2].id && $0.debugDetail == "Not done yesterday" }
                ? nil : "tomorrow did not carry the task over"
        }
    }

    static func test_nudges() -> String? {
        let open = DayPlan(day: day(0), setAt: at(9), items: [.init(taskID: "a", title: "a", startMinute: 600, minutes: 45)])
        func nudge(_ hour: Int, _ minute: Int = 0, _ plan: DayPlan?, nudged: [String: String] = [:], candidates: Bool = true) -> DayPlanRules.Nudge? {
            DayPlanRules.nudge(now: at(hour, minute), plan: plan, hasCandidates: candidates, nudged: nudged)
        }
        guard nudge(8, 59, nil) == nil, nudge(9, 5, nil) == .morning, nudge(12, 1, nil) == nil else { return "the morning window" }
        guard nudge(9, 5, nil, candidates: false) == nil else { return "a nudge with nothing to plan" }
        guard nudge(9, 5, nil, nudged: ["morning": day(0)]) == nil, nudge(9, 5, nil, nudged: ["morning": day(-1)]) == .morning else {
            return "once a day"
        }
        guard nudge(9, 5, open) == nil, nudge(17, 59, open) == nil, nudge(18, 5, open) == .evening else { return "the evening window" }
        var closed = open
        closed.closedAt = at(18)
        guard nudge(18, 5, closed) == nil, nudge(18, 5, nil) == nil else { return "an evening nudge with nothing to close" }
        return withStores([task("a", due: day(0))]) { store, plans, _ in
            let nudger = DayPlanNudger(store: store, plans: plans, now: { at(9, 5) })
            guard nudger.check() == .morning else { return "the nudger did not post" }
            guard GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == DayPlanRules.Nudge.morning.id }) else {
                return "the bell has no entry"
            }
            guard nudger.check() == nil else { return "the nudger posted twice in a day" }
            plans.save(open)
            _ = nudger.check()
            return GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == DayPlanRules.Nudge.morning.id })
                ? "a plan did not clear the morning entry" : nil
        }
    }

    static func test_store() -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("day-plan-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DayPlanStore(directory: dir)
        for offset in 0..<40 {
            store.save(DayPlan(day: day(-offset), setAt: at(9, dayOffset: -offset), items: []))
        }
        guard store.state.plans.count == DayPlanStore.keptPlans, store.state.plans.last?.day == day(0),
              store.state.plans.first?.day == day(-(DayPlanStore.keptPlans - 1)) else { return "kept \(store.state.plans.count)" }
        store.markNudged("morning", day: day(0))
        let reread = DayPlanStore(directory: dir)
        guard reread.state == store.state else { return "the round trip changed the state" }
        // An older file with no `nudged` key reads.
        try? #"{"plans":[{"day":"2026-11-25","setAt":"2026-11-25T09:41:00Z","items":[]}]}"#
            .write(to: dir.appendingPathComponent("plans.json"), atomically: true, encoding: .utf8)
        guard DayPlanStore(directory: dir).state.plans.count == 1 else { return "an older file did not read" }
        // An unreadable file is kept aside, not read as empty and overwritten.
        try? "not json".write(to: dir.appendingPathComponent("plans.json"), atomically: true, encoding: .utf8)
        _ = DayPlanStore(directory: dir)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("plans.unreadable-") } ?? []
        return aside.count == 1 ? nil : "the unreadable file was not kept aside"
    }

    static func test_wiring() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[day-plan] SKIP guard"); return nil }
        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        guard read("HomeCanvasController+Briefing.swift").contains("var actions: [(String, Selector)] = dayPlanActions(now: now)") else {
            return "Home's hero lost the plan's actions"
        }
        guard read("HomeCanvasController+Briefing.swift").contains("if let planned = dayPlanHero(now: now)") else {
            return "Home's hero no longer draws the plan"
        }
        return read("Workspace.swift").contains("dayPlanNudger.start()") ? nil : "the bell's nudges are never armed"
    }
}

#endif
