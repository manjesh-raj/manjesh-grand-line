// Grand Line - native macOS app.
//
// The When panel's model (tasks-calendar plan PR 5): the mapping from the
// panel's controls to a task's date, time, rule and reminder, and back.
//
//   - every Repeat preset, and every Custom state, maps to the rule it says
//     and reads back to the same rows;
//   - a rule the panel can show, opened and saved untouched, writes back
//     byte-identical (an empty weekly `BYDAY`, an explicit `BYMONTHDAY`,
//     `EXDATE` and both ends included), so opening the panel is never an
//     edit;
//   - a rule it cannot show is "Custom rule" and is written back unchanged;
//   - each control's edit rule: a repeat with no date starts today, "No
//     date" takes the rule and the reminder with it, the circles, the
//     stepper, the date that a rule only echoed, the ends;
//   - an all-day task is saved with no time (the sheet used to write one);
//   - a rule set for the first time mints the series id, and a new date or
//     rule clears `occurrence`;
//   - the preview strip, its sentence and its `recurrence:` line;
//   - the Remind wording for a date-only task names the time it fires at,
//     and agrees with `ShiftDue.reminderFireInstant`.
//
// **Pure logic** (AGENTS.md's classification rule): every check is a value
// check on a draft, a rule or a `ShiftTask`, so this runs in CI's blocking
// lane. The panel's real controls, the sheet and the calendar's popover are
// `ShiftCalendarViewSelfTest`'s.
//
// The dates are "YYYY-MM-DD" strings read through `ShiftDateFormatting`, so
// the calendar is `Calendar.current` (AGENTS.md's day-string fixture rule),
// and the instants are pinned at local noon. Nothing asserts a locale's own
// weekday order or month name; those come from the same formatter the
// panel uses.
//
// Run with `FM_RUN_SHIFT_SCHEDULE_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import Foundation

enum ShiftScheduleSelfTest {

    /// Wednesday 16 September 2026: the 3rd Wednesday of its month.
    private static let wednesday = "2026-09-16"
    /// Wednesday 30 September 2026: a 5th Wednesday, which is "the last".
    private static let lastWednesday = "2026-09-30"
    /// The panel's "today" in every case below: Monday 14 September 2026.
    private static let today = "2026-09-14"
    private static let calendar = Calendar.current

    static func run() -> Bool {
        var ok = true

        checkPresets(&ok)
        checkCustomStates(&ok)
        checkUnchangedRulesWriteBackIdentical(&ok)
        checkCustomRule(&ok)
        checkDateAndRepeatEdits(&ok)
        checkCirclesAndStepper(&ok)
        checkDateFollowsTheRule(&ok)
        checkEnds(&ok)
        checkApplied(&ok)
        checkPreview(&ok)
        checkReminderWording(&ok)
        checkToast(&ok)

        if ok { print("[ShiftScheduleSelfTest] all checks passed") }
        return ok
    }

    // MARK: Presets

    private static func checkPresets(_ ok: inout Bool) {
        let expected: [(ShiftScheduleDraft.Repeat, String?)] = [
            (.none, nil),
            (.daily, "FREQ=DAILY;INTERVAL=1"),
            (.weekdays, "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR"),
            (.weekly, "FREQ=WEEKLY;INTERVAL=1;BYDAY=WE"),
            (.monthly, "FREQ=MONTHLY;INTERVAL=1"),
            (.yearly, "FREQ=YEARLY;INTERVAL=1"),
        ]
        check(Set(expected.map(\.0) + [.custom]) == Set(ShiftScheduleDraft.Repeat.menu),
              "every Repeat menu item has a case here", &ok)
        for (kind, text) in expected {
            var draft = ShiftScheduleDraft(day: wednesday)
            draft.setRepeat(kind, today: today)
            check(draft.recurrence?.ruleText == text,
                  "\(kind.title) writes \(text ?? "no rule"), got \(draft.recurrence?.ruleText ?? "no rule")", &ok)
            let back = ShiftScheduleDraft(day: wednesday, recurrence: draft.recurrence)
            check(back.repeatKind == kind, "\(kind.title) reads back as itself, got \(back.repeatKind.title)", &ok)
            check(back.recurrence == draft.recurrence, "\(kind.title) round-trips to the same rule", &ok)
        }

        // Custom straight from "Does not repeat" is every week on the due
        // date's weekday, which reads back as the named preset it equals.
        var custom = ShiftScheduleDraft(day: wednesday)
        custom.setRepeat(.custom, today: today)
        check(custom.repeatKind == .custom && custom.unit == .week && custom.shownInterval == 1,
              "Custom opens on every 1 week", &ok)
        check(custom.recurrence?.ruleText == "FREQ=WEEKLY;INTERVAL=1;BYDAY=WE",
              "Custom at 1 week writes the weekly rule, got \(custom.recurrence?.ruleText ?? "none")", &ok)
        check(ShiftScheduleDraft(day: wednesday, recurrence: custom.recurrence).repeatKind == .weekly,
              "a Custom rule at interval 1 reads back as the preset it is", &ok)
    }

    private static func checkCustomStates(_ ok: inout Bool) {
        struct Case {
            let name: String
            let build: (inout ShiftScheduleDraft) -> Void
            let rule: String
        }
        let cases: [Case] = [
            Case(name: "every 3 days", build: { d in
                d.setRepeat(.custom, today: today); d.setUnit(.day); d.stepInterval(by: 2)
            }, rule: "FREQ=DAILY;INTERVAL=3"),
            Case(name: "every 2 weeks on Mon and Thu", build: { d in
                d.setRepeat(.custom, today: today); d.stepInterval(by: 1)
                d.toggleWeekday(2); d.toggleWeekday(5); d.toggleWeekday(4)
            }, rule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"),
            Case(name: "every 2 months on the last day", build: { d in
                d.setRepeat(.custom, today: today); d.setUnit(.month); d.stepInterval(by: 1)
                d.setMonthlyMode(.lastDay)
            }, rule: "FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=-1"),
            Case(name: "every 3 months on the 3rd Wednesday", build: { d in
                d.setRepeat(.custom, today: today); d.setUnit(.month); d.stepInterval(by: 2)
                d.setMonthlyMode(.weekdayOfMonth)
            }, rule: "FREQ=MONTHLY;INTERVAL=3;BYDAY=3WE"),
            Case(name: "every 2 years", build: { d in
                d.setRepeat(.custom, today: today); d.setUnit(.year); d.stepInterval(by: 1)
            }, rule: "FREQ=YEARLY;INTERVAL=2"),
            Case(name: "monthly on the 3rd Wednesday", build: { d in
                d.setRepeat(.monthly, today: today); d.setMonthlyMode(.weekdayOfMonth)
            }, rule: "FREQ=MONTHLY;INTERVAL=1;BYDAY=3WE"),
            Case(name: "monthly on the last day, 6 times", build: { d in
                d.setRepeat(.monthly, today: today); d.setMonthlyMode(.lastDay)
                d.setEnd(.afterCount); d.stepCount(by: -4)
            }, rule: "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=-1;COUNT=6"),
            Case(name: "every day until 31 Oct", build: { d in
                d.setRepeat(.daily, today: today); d.setEnd(.onDate)
            }, rule: "FREQ=DAILY;INTERVAL=1;UNTIL=2026-10-31"),
            Case(name: "weekly on Mon, Wed, Fri until 1 Dec", build: { d in
                d.setRepeat(.weekly, today: today); d.toggleWeekday(2); d.toggleWeekday(6)
                d.setEnd(.onDate); d.setUntil("2026-12-01")
            }, rule: "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;UNTIL=2026-12-01"),
        ]
        for c in cases {
            var draft = ShiftScheduleDraft(day: wednesday)
            c.build(&draft)
            let text = draft.recurrence?.ruleText
            check(text == c.rule, "\(c.name) writes \(c.rule), got \(text ?? "no rule")", &ok)
            let back = ShiftScheduleDraft(day: wednesday, recurrence: draft.recurrence)
            check(back.recurrence?.ruleText == c.rule, "\(c.name) reads back to the same rule", &ok)
            check(back.repeatKind == draft.repeatKind && back.shownInterval == draft.shownInterval
                  && back.effectiveUnit == draft.effectiveUnit && back.end == draft.end,
                  "\(c.name) reads back to the same rows, got \(back.repeatKind.title) every "
                  + "\(back.shownInterval) \(back.effectiveUnit?.rawValue ?? "-") ending \(back.end)", &ok)
        }

        // The 5th Wednesday is "the last", which every month has.
        var last = ShiftScheduleDraft(day: lastWednesday)
        last.setRepeat(.monthly, today: today)
        last.setMonthlyMode(.weekdayOfMonth)
        check(last.recurrence?.ruleText == "FREQ=MONTHLY;INTERVAL=1;BYDAY=-1WE",
              "a 5th weekday is written as the last one, got \(last.recurrence?.ruleText ?? "none")", &ok)
        check(last.monthlyTitle(.weekdayOfMonth) == "The last \(ShiftRecurrence.longWeekdayName(4))",
              "...and named so, got \(last.monthlyTitle(.weekdayOfMonth))", &ok)
        check(last.monthlyTitle(.dayOfMonth) == "Day 30 of the month", "the day row names the date's day", &ok)
    }

    // MARK: Opening is not an edit

    private static func checkUnchangedRulesWriteBackIdentical(_ ok: inout Bool) {
        let texts = [
            "FREQ=WEEKLY;INTERVAL=1",
            "FREQ=WEEKLY;INTERVAL=2",
            "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=13",
            "FREQ=MONTHLY;INTERVAL=1;BYDAY=2FR;UNTIL=2026-12-31",
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;EXDATE=2026-09-21,2026-10-05",
            "FREQ=DAILY;INTERVAL=1;COUNT=5",
            "FREQ=YEARLY;INTERVAL=1",
        ]
        for text in texts {
            guard let rule = ShiftRecurrence.parse(text) else {
                fail("the fixture \(text) no longer parses, so this case measures nothing", &ok)
                continue
            }
            check(rule.ruleText == text, "the fixture \(text) is already in written form", &ok)
            var task = ShiftTask.fresh()
            task.dueDate = wednesday
            task.dueTime = "09:30"
            task.recurrence = rule
            task.reminderMinutesBefore = 15
            task.seriesID = "series-1"
            task.occurrence = "2026-09-14"
            let draft = ShiftScheduleDraft(task: task)
            check(draft.repeatKind != .customRule, "\(text) is a rule the panel can show", &ok)
            check(!draft.changes(task), "opening and closing the panel on \(text) changes nothing", &ok)
            let saved = draft.applied(to: task)
            check(saved.recurrence?.ruleText == text,
                  "\(text) writes back byte-identical, got \(saved.recurrence?.ruleText ?? "no rule")", &ok)
            check(saved.occurrence == "2026-09-14" && saved.seriesID == "series-1",
                  "an untouched rule keeps the instance's slot and series", &ok)
        }
    }

    private static func checkCustomRule(_ ok: inout Bool) {
        let texts = [
            "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO;BYSETPOS=2",
            "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=1,15",
            "FREQ=DAILY;INTERVAL=1;UNTIL=2026-12-31;COUNT=4",
            "FREQ=MONTHLY;INTERVAL=1;BYDAY=2FR;BYMONTHDAY=13",
        ]
        for text in texts {
            guard let rule = ShiftRecurrence.parse(text) else {
                fail("the fixture \(text) no longer parses", &ok)
                continue
            }
            var task = ShiftTask.fresh()
            task.dueDate = wednesday
            task.recurrence = rule
            var draft = ShiftScheduleDraft(task: task)
            check(draft.repeatKind == .customRule, "\(text) is shown as \"Custom rule\", got \(draft.repeatKind.title)", &ok)
            check(draft.applied(to: task).recurrence?.ruleText == rule.ruleText,
                  "\(text) is written back unchanged", &ok)
            check(!draft.changes(task), "opening a custom rule is not an edit", &ok)
            draft.setRepeat(.daily, today: today)
            check(draft.recurrence?.ruleText == "FREQ=DAILY;INTERVAL=1", "picking a preset replaces it", &ok)
            draft.setRepeat(.customRule, today: today)
            check(draft.recurrence?.ruleText == rule.ruleText, "...and Custom rule brings it back", &ok)
        }
        var plain = ShiftScheduleDraft(day: wednesday)
        plain.setRepeat(.customRule, today: today)
        check(plain.repeatKind == .none, "Custom rule cannot be picked when there is no such rule", &ok)
    }

    // MARK: Edits

    private static func checkDateAndRepeatEdits(_ ok: inout Bool) {
        var undated = ShiftScheduleDraft()
        check(undated.recurrence == nil && ShiftSchedulePreview(draft: undated) == nil,
              "no date: no rule and nothing to preview", &ok)
        undated.setRepeat(.weekly, today: today)
        check(undated.day == today, "a repeat chosen with no date starts today, got \(undated.day ?? "nil")", &ok)
        check(undated.recurrence?.ruleText == "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO",
              "...on today's weekday, got \(undated.recurrence?.ruleText ?? "none")", &ok)

        var dated = ShiftScheduleDraft(day: wednesday, time: "09:30",
                                       recurrence: ShiftRecurrence(frequency: .daily), reminderMinutes: 15)
        dated.setDay(nil)
        check(dated.day == nil && dated.repeatKind == .none && dated.reminderMinutes == nil,
              "No date takes the rule and the reminder with it", &ok)
        check(dated.applied(to: ShiftTask.fresh()).dueTime == nil, "...and no time is written without a date", &ok)

        let quick = ShiftScheduleDraft.quickDays(today: today)
        check(quick.map(\.day) == [today, "2026-09-15", "2026-09-21"],
              "Today, Tomorrow and the next Monday from a Monday, got \(quick.map(\.day))", &ok)
        let fromSunday = ShiftScheduleDraft.quickDays(today: "2026-09-20")
        check(fromSunday.last?.day == "2026-09-21", "from a Sunday the next Monday is the day after", &ok)
    }

    private static func checkCirclesAndStepper(_ ok: inout Bool) {
        var draft = ShiftScheduleDraft(day: wednesday)
        draft.setRepeat(.weekdays, today: today)
        draft.toggleWeekday(6)
        check(draft.repeatKind == .weekly, "a circle under Every weekday makes it Weekly on chosen days", &ok)
        check(draft.recurrence?.ruleText == "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH",
              "...without the day clicked, got \(draft.recurrence?.ruleText ?? "none")", &ok)
        draft.toggleWeekday(6)
        check(draft.repeatKind == .weekdays, "picking the fifth weekday back names the rule again", &ok)

        var single = ShiftScheduleDraft(day: wednesday)
        single.setRepeat(.weekly, today: today)
        single.toggleWeekday(4)
        check(single.recurrence?.weekdays == [4], "the last lit circle cannot be cleared", &ok)
        single.toggleWeekday(9)
        check(single.recurrence?.weekdays == [4], "a weekday outside 1...7 is ignored", &ok)

        var stepped = ShiftScheduleDraft(day: wednesday)
        stepped.setRepeat(.weekly, today: today)
        stepped.stepInterval(by: -1)
        check(stepped.repeatKind == .weekly, "stepping a preset below 1 changes nothing", &ok)
        stepped.stepInterval(by: 1)
        check(stepped.repeatKind == .custom && stepped.unit == .week && stepped.shownInterval == 2,
              "stepping a preset up makes it Custom in the same unit", &ok)
        stepped.stepInterval(by: -1)
        check(stepped.repeatKind == .custom && stepped.shownInterval == 1, "stepping back stays Custom", &ok)
        for _ in 0..<200 { stepped.stepInterval(by: 1) }
        check(stepped.shownInterval == ShiftScheduleDraft.intervalRange.upperBound, "the interval has a ceiling", &ok)

        var weekdays = ShiftScheduleDraft(day: wednesday)
        weekdays.setRepeat(.weekdays, today: today)
        weekdays.stepInterval(by: 1)
        check(weekdays.repeatKind == .weekdays, "Every weekday has no Every row to step", &ok)

        var switched = ShiftScheduleDraft(day: wednesday)
        switched.setRepeat(.custom, today: today)
        switched.toggleWeekday(2)
        switched.setUnit(.day)
        switched.setUnit(.week)
        check(switched.recurrence?.weekdays == [2, 4], "Custom's days survive a trip through another unit", &ok)
        check(switched.showsUnitPicker, "Custom shows its unit picker", &ok)
        switched.setRepeat(.weekly, today: today)
        check(!switched.showsUnitPicker, "a named preset does not", &ok)

        var rows = ShiftScheduleDraft(day: wednesday)
        rows.setRepeat(.yearly, today: today)
        check(!rows.showsEvery && !rows.showsWeekdays && !rows.showsMonthly && rows.showsEnds,
              "Every year shows only Ends", &ok)
        rows.setRepeat(.monthly, today: today)
        check(rows.showsEvery && rows.showsMonthly && !rows.showsWeekdays, "Monthly shows the monthly row", &ok)
    }

    private static func checkDateFollowsTheRule(_ ok: inout Bool) {
        var weekly = ShiftScheduleDraft(day: wednesday)
        weekly.setRepeat(.weekly, today: today)
        weekly.setDay("2026-09-18")
        check(weekly.recurrence?.weekdays == [6], "a rule on the old date's weekday alone follows a new date", &ok)
        weekly.toggleWeekday(2)
        weekly.setDay("2026-09-22")
        check(weekly.recurrence?.weekdays == [2, 6], "days picked apart from the date stay", &ok)

        guard let explicit = ShiftRecurrence.parse("FREQ=MONTHLY;INTERVAL=1;BYDAY=3WE") else {
            fail("the fixture no longer parses", &ok)
            return
        }
        var monthly = ShiftScheduleDraft(day: wednesday, recurrence: explicit)
        monthly.setDay("2026-09-25")
        check(monthly.recurrence?.ruleText == "FREQ=MONTHLY;INTERVAL=1;BYDAY=4FR",
              "the date's own 3rd Wednesday follows it to the 4th Friday, got "
              + "\(monthly.recurrence?.ruleText ?? "none")", &ok)

        var until = ShiftScheduleDraft(day: wednesday)
        until.setRepeat(.daily, today: today)
        until.setEnd(.onDate)
        until.setUntil("2026-09-01")
        check(until.until == wednesday, "an end before the date is the date itself", &ok)
        until.setDay("2026-11-30")
        check(until.recurrence?.until == "2026-11-30", "a date moved past the end pulls the end along", &ok)
    }

    private static func checkEnds(_ ok: inout Bool) {
        var draft = ShiftScheduleDraft(day: wednesday)
        draft.setRepeat(.daily, today: today)
        draft.setEnd(.afterCount)
        check(draft.recurrence?.count == 10, "After starts at 10 times", &ok)
        for _ in 0..<20 { draft.stepCount(by: -1) }
        check(draft.recurrence?.count == 1, "the count stops at 1", &ok)
        draft.setEnd(.onDate)
        check(draft.recurrence?.until == "2026-10-31" && draft.recurrence?.count == nil,
              "On a date starts on the last day of the next month, and drops the count", &ok)
        draft.setEnd(.never)
        check(draft.recurrence?.until == nil && draft.recurrence?.count == nil, "Never has no end", &ok)
    }

    // MARK: What is written

    private static func checkApplied(_ ok: inout Bool) {
        var task = ShiftTask.fresh()
        task.title = "Pay the invoice"
        var draft = ShiftScheduleDraft(task: task)
        draft.setDay(wednesday)
        let allDay = draft.applied(to: task)
        check(allDay.dueDate == wednesday && allDay.dueTime == nil,
              "an all-day date is saved with no time, got \(allDay.dueTime ?? "nil")", &ok)
        check(allDay.seriesID == nil, "a one-off task gets no series id", &ok)

        draft.setRepeat(.weekly, today: today)
        let repeating = draft.applied(to: allDay)
        check(repeating.seriesID != nil, "a rule set for the first time mints the series id", &ok)
        var again = ShiftScheduleDraft(task: repeating)
        again.setRepeat(.daily, today: today)
        check(again.applied(to: repeating).seriesID == repeating.seriesID, "a later rule keeps the series id", &ok)

        var moved = repeating
        moved.occurrence = "2026-09-14"
        var reminded = ShiftScheduleDraft(task: moved)
        reminded.reminderMinutes = 0
        check(reminded.applied(to: moved).occurrence == "2026-09-14", "a reminder change keeps the rule slot", &ok)
        var redated = ShiftScheduleDraft(task: moved)
        redated.setDay("2026-09-23")
        check(redated.applied(to: moved).occurrence == nil, "a new date clears the old rule slot", &ok)
        var reruled = ShiftScheduleDraft(task: moved)
        reruled.setRepeat(.daily, today: today)
        check(reruled.applied(to: moved).occurrence == nil, "a new rule clears the old rule slot", &ok)
        check(reruled.changes(moved) && !ShiftScheduleDraft(task: moved).changes(moved),
              "changes(_:) tells an edit from no edit", &ok)
    }

    // MARK: The preview

    private static func checkPreview(_ ok: inout Bool) {
        let noon = ShiftDateFormatting.dateTime(from: today, time: "12:00") ?? Date()
        var draft = ShiftScheduleDraft(day: wednesday, time: "09:30")
        guard let once = ShiftSchedulePreview(draft: draft, today: noon, calendar: calendar) else {
            fail("a dated task has no preview", &ok)
            return
        }
        check(once.ruleLine == nil && once.countText.isEmpty, "a task that happens once has no rule line", &ok)
        check(once.summary == "Happens once at \(ShiftDateFormatting.clock("09:30"))",
              "...and says so, got \(once.summary)", &ok)
        check(once.cells.filter(\.isOccurrence).isEmpty && once.cells.filter(\.isDue).count == 1,
              "...with only its own date marked", &ok)

        draft.setRepeat(.weekly, today: today)
        draft.toggleWeekday(2)
        draft.toggleWeekday(6)
        draft.setEnd(.afterCount)
        guard var rule = draft.recurrence else {
            fail("the weekly draft has no rule", &ok)
            return
        }
        rule.exceptionDates = ["2026-09-21"]
        let skipped = ShiftScheduleDraft(day: wednesday, time: "09:30", recurrence: rule)
        guard let preview = ShiftSchedulePreview(draft: skipped, today: noon, calendar: calendar) else {
            fail("the weekly draft has no preview", &ok)
            return
        }
        check(preview.cells.count == 7 * ShiftSchedulePreview.weeks, "the strip is five weeks", &ok)
        let first = preview.cells.first.flatMap { ShiftScheduleDraft.weekday(of: $0.day, calendar: calendar) }
        check(first == calendar.firstWeekday, "the strip starts on the calendar's first weekday", &ok)
        check(preview.cells.prefix(7).contains { $0.isDue }, "the due date is in the strip's first week", &ok)
        check(preview.weekdayHeads.count == 7, "seven weekday heads", &ok)

        let occurring = preview.cells.filter(\.isOccurrence).map(\.day)
        let expected = (0..<35).compactMap { offset -> String? in
            guard let day = ShiftScheduleDraft.adding(days: offset, to: preview.cells[0].day, calendar: calendar),
                  day >= wednesday, day != "2026-09-21",
                  let weekday = ShiftScheduleDraft.weekday(of: day, calendar: calendar),
                  [2, 4, 6].contains(weekday) else { return nil }
            return day
        }
        // COUNT=10 includes the skipped Monday, so nine dates show.
        check(occurring == Array(expected.prefix(9)),
              "the strip fills Mon, Wed and Fri from the due date, less the skipped one, ten in all: "
              + "got \(occurring)", &ok)
        check(preview.cells.first { $0.day == "2026-09-21" }?.isSkipped == true, "the skipped date is struck", &ok)
        check(preview.cells.first { $0.day == today }?.isToday == true, "today is marked", &ok)
        check(preview.cells.first { $0.day == "2026-09-13" }.map { $0.isPast } ?? true,
              "a day before today is past", &ok)
        check(preview.countText == "\(occurring.count) dates in view", "the count says \(occurring.count), got \(preview.countText)", &ok)

        let next = ["2026-09-18", "2026-09-23", "2026-09-25"].compactMap { day -> String? in
            ShiftDateFormatting.dateTime(from: day, time: "09:30").map(ShiftSchedulePreview.shortDay)
        }
        check(preview.detail == "Next: \(next.joined(separator: ", ")). 10 times in total.",
              "the sentence names the next three dates, past the skipped one, and the end: got \(preview.detail)", &ok)
        check(preview.summary == "\(rule.patternName) at \(ShiftDateFormatting.clock("09:30"))",
              "the summary is the rule's own name and the time, got \(preview.summary)", &ok)
        check(preview.ruleLine == "recurrence: \(rule.ruleText)",
              "the rule line is exactly what the YAML holds, got \(preview.ruleLine ?? "nil")", &ok)
    }

    // MARK: Remind

    private static func checkReminderWording(_ ok: inout Bool) {
        check(ShiftReminderOffset.label(for: 15, allDayAt: nil) == ShiftReminderOffset.label(for: 15),
              "a timed task keeps the plain wording", &ok)
        check(ShiftReminderOffset.label(for: 0, allDayAt: "09:00") == "On the day at \(ShiftDateFormatting.clock("09:00"))",
              "an all-day task's \"at the time\" names the morning time", &ok)
        check(ShiftReminderOffset.label(for: 120, allDayAt: "garbage")
              == "2 hours before, at \(ShiftDateFormatting.clock("07:00"))",
              "an unreadable setting is 09:00, as the scheduler reads it", &ok)
        // The wording and the scheduler agree on the minute.
        for minutes in ShiftReminderOffset.choices where minutes > 0 {
            guard let fires = ShiftDue.reminderFireInstant(date: wednesday, time: nil, minutesBefore: minutes,
                                                           allDayAt: "08:30", defaultLookahead: 1800) else {
                fail("no fire instant for \(minutes)", &ok)
                continue
            }
            let clock = ShiftDateFormatting.clock(ShiftDateFormatting.components(from: fires).timeStr)
            check(ShiftReminderOffset.label(for: minutes, allDayAt: "08:30").hasSuffix(", at \(clock)"),
                  "\(minutes) minutes before an 08:30 day fires at \(clock), and says so: "
                  + ShiftReminderOffset.label(for: minutes, allDayAt: "08:30"), &ok)
        }
    }

    private static func checkToast(_ ok: inout Bool) {
        var old = ShiftTask.fresh()
        old.title = "Rotate keys"
        var new = old
        new.dueDate = wednesday
        check(TaskCalendarController.scheduleToast(from: old, to: new).contains("scheduled for"),
              "a first date is scheduled", &ok)
        old.dueDate = today
        check(TaskCalendarController.scheduleToast(from: old, to: new).contains("moved to"), "a new date is a move", &ok)
        old.dueDate = wednesday
        new.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet)
        check(TaskCalendarController.scheduleToast(from: old, to: new) == "\u{201C}Rotate keys\u{201D} repeats every weekday",
              "a new rule says what it is, got \(TaskCalendarController.scheduleToast(from: old, to: new))", &ok)
        new.dueDate = nil
        check(TaskCalendarController.scheduleToast(from: old, to: new).hasSuffix("has no date now"), "No date says so", &ok)
    }
}

#endif
