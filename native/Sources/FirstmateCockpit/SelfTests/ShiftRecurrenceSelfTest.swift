// Manjesh Grand Line - native macOS app.
//
// F5's pure logic: the RRULE-lite parser, the occurrence generator, the
// completion advance, and the reminder offset's own comparison.
//
// **Why this is not window-backed** (AGENTS.md's classification rule): every
// check here is a value check on a rule, a date list or a `ShiftTask`. It
// builds no view, mounts no window and reads no rendered geometry, so it runs
// in CI's *blocking* lane. The calendar's grid - cells, chips, the projected
// chip's alpha, the switch between three views - is a real render and lives
// in `ShiftCalendarViewSelfTest` instead.
//
// The generator is tested against a **fixed** calendar (Gregorian, UTC,
// Monday-first) rather than `Calendar.current`, so a run on a machine whose
// week starts on Sunday asserts the same dates as one whose week starts on
// Monday. The locale-dependent parts (the weekday chip order, the column
// order) are the view's, and are asserted there.
//
// Run with `FM_RUN_SHIFT_RECURRENCE_TESTS=1 .build/debug/FirstmateCockpit`.

#if FM_SELFTESTS

import Foundation

enum ShiftRecurrenceSelfTest {

    /// Monday 2026-09-14, 09:00 UTC - the anchor every case below expands
    /// from. A Monday on purpose: a weekly rule anchored mid-week is the case
    /// that catches a generator walking from the anchor rather than from the
    /// week's own first day, so the *other* cases use a Wednesday anchor for
    /// exactly that.
    private static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }()

    static func run() -> Bool {
        var ok = true

        checkParsing(&ok)
        checkDailyAndInterval(&ok)
        checkWeeklyWeekdays(&ok)
        checkMonthlyClamping(&ok)
        checkTermination(&ok)
        checkCompletionAdvances(&ok)
        checkReminderHorizon(&ok)
        checkDisplayNames(&ok)

        if ok { print("[ShiftRecurrenceSelfTest] all checks passed") }
        return ok
    }

    // MARK: Parsing

    private static func checkParsing(_ ok: inout Bool) {
        let rule = ShiftRecurrence(frequency: .weekly, interval: 2,
                                   weekdays: ShiftRecurrence.weekdaySet, until: "2026-12-31")
        let text = rule.ruleText
        check(text == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU,WE,TH,FR;UNTIL=2026-12-31",
              "the serialized rule should be RRULE-shaped, got \(text)", &ok)

        // The discriminating half: the string genuinely round-trips, rather
        // than `parse` merely returning something non-nil.
        guard let back = ShiftRecurrence.parse(text) else {
            fail("a rule this app wrote should parse back", &ok)
            return
        }
        check(back == rule.normalized, "round-trip should be lossless, got \(back.ruleText)", &ok)

        check(ShiftRecurrence.parse("") == nil, "an empty string is not a rule", &ok)
        check(ShiftRecurrence.parse("INTERVAL=2") == nil, "a rule with no FREQ is not a rule", &ok)
        // The one that matters: a frequency this app does not implement must
        // not silently become a daily task.
        check(ShiftRecurrence.parse("FREQ=YEARLY;INTERVAL=1") == nil,
              "an unsupported FREQ must be rejected, not downgraded", &ok)
        check(ShiftRecurrence.parse("FREQ=DAILY;WKST=SU;BYSETPOS=2")?.frequency == .daily,
              "unknown components should be ignored rather than failing the parse", &ok)
        // A hand-edited file is a real input: `INTERVAL=0` would make the
        // generator produce the anchor forever.
        check(ShiftRecurrence.parse("FREQ=DAILY;INTERVAL=0")?.interval == 1,
              "INTERVAL=0 must be clamped to 1", &ok)
    }

    // MARK: Generation

    private static func checkDailyAndInterval(_ ok: inout Bool) {
        let anchor = date("2026-09-16 09:00")
        let daily = ShiftRecurrence(frequency: .daily)
        let firstThree = days(daily.occurrences(anchor: anchor, from: anchor,
                                                through: date("2026-09-30 23:59"),
                                                calendar: calendar, limit: 3))
        check(firstThree == ["2026-09-16", "2026-09-17", "2026-09-18"],
              "a daily rule should start at its anchor, got \(firstThree)", &ok)

        let everyThird = ShiftRecurrence(frequency: .daily, interval: 3)
        let stepped = days(everyThird.occurrences(anchor: anchor, from: anchor,
                                                  through: date("2026-09-30 23:59"),
                                                  calendar: calendar, limit: 4))
        check(stepped == ["2026-09-16", "2026-09-19", "2026-09-22", "2026-09-25"],
              "INTERVAL=3 should step three days, got \(stepped)", &ok)

        // The time of day survives: a task due at 09:00 recurs at 09:00, not
        // at midnight - which is what the reminder offset then subtracts from.
        let next = daily.next(after: anchor, anchor: anchor, calendar: calendar)
        check(calendar.component(.hour, from: next ?? .distantPast) == 9,
              "an occurrence should keep the anchor's time of day", &ok)
    }

    private static func checkWeeklyWeekdays(_ ok: inout Bool) {
        // Anchored on a **Wednesday**, so the first week must still produce
        // that week's Thursday and Friday but not its already-passed Monday.
        let anchor = date("2026-09-16 09:00")
        let weekdays = ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet)
        let produced = days(weekdays.occurrences(anchor: anchor, from: anchor,
                                                 through: date("2026-09-25 23:59"),
                                                 calendar: calendar, limit: 20))
        check(produced == ["2026-09-16", "2026-09-17", "2026-09-18",
                           "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25"],
              "every weekday from a Wednesday anchor should skip the weekend and the passed Monday, got \(produced)",
              &ok)

        // Fortnightly on Monday and Thursday: the skipped week is the check.
        let fortnightly = ShiftRecurrence(frequency: .weekly, interval: 2, weekdays: [2, 5])
        let mondayAnchor = date("2026-09-14 09:00")
        let biweekly = days(fortnightly.occurrences(anchor: mondayAnchor, from: mondayAnchor,
                                                    through: date("2026-10-12 23:59"),
                                                    calendar: calendar, limit: 20))
        check(biweekly == ["2026-09-14", "2026-09-17", "2026-09-28", "2026-10-01", "2026-10-12"],
              "a fortnightly rule should skip the alternate week entirely, got \(biweekly)", &ok)

        // An empty BYDAY is "the anchor's own weekday", never "no days".
        let plain = ShiftRecurrence(frequency: .weekly)
        let weekly = days(plain.occurrences(anchor: mondayAnchor, from: mondayAnchor,
                                            through: date("2026-10-05 23:59"),
                                            calendar: calendar, limit: 10))
        check(weekly == ["2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05"],
              "an empty BYDAY should repeat on the anchor's weekday, got \(weekly)", &ok)
    }

    private static func checkMonthlyClamping(_ ok: inout Bool) {
        // The 31st through a 30-day month and February: the documented
        // clamping, asserted rather than assumed.
        let anchor = date("2026-01-31 09:00")
        let monthly = ShiftRecurrence(frequency: .monthly)
        let produced = days(monthly.occurrences(anchor: anchor, from: anchor,
                                                through: date("2026-05-01 00:00"),
                                                calendar: calendar, limit: 5))
        check(produced == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"],
              "a monthly rule on the 31st should clamp, not skip, got \(produced)", &ok)
    }

    private static func checkTermination(_ ok: inout Bool) {
        let anchor = date("2026-09-14 09:00")

        // COUNT includes the anchor, so COUNT=3 is the anchor plus two.
        let counted = ShiftRecurrence(frequency: .daily, count: 3)
        let produced = days(counted.occurrences(anchor: anchor, from: anchor,
                                                through: date("2026-10-30 00:00"),
                                                calendar: calendar, limit: 50))
        check(produced == ["2026-09-14", "2026-09-15", "2026-09-16"],
              "COUNT should include the anchor, got \(produced)", &ok)
        check(counted.next(after: date("2026-09-16 09:00"), anchor: anchor, calendar: calendar) == nil,
              "an exhausted COUNT should produce no further occurrence", &ok)

        // UNTIL is inclusive of its own day.
        let bounded = ShiftRecurrence(frequency: .daily, until: "2026-09-16")
        let untilDays = days(bounded.occurrences(anchor: anchor, from: anchor,
                                                 through: date("2026-10-30 00:00"),
                                                 calendar: calendar, limit: 50))
        check(untilDays == ["2026-09-14", "2026-09-15", "2026-09-16"],
              "UNTIL should include its own day, got \(untilDays)", &ok)

        // An unbounded rule asked for a window far from its anchor still
        // terminates, and returns the window's own dates rather than the
        // anchor's - the property `limit` plus the step ceiling exist for.
        let open = ShiftRecurrence(frequency: .daily)
        let far = days(open.occurrences(anchor: anchor, from: date("2027-01-01 00:00"),
                                        through: date("2027-01-03 23:59"),
                                        calendar: calendar, limit: 10))
        check(far == ["2027-01-01", "2027-01-02", "2027-01-03"],
              "a window far ahead of the anchor should still resolve, got \(far)", &ok)
    }

    // MARK: Completion advances the series

    private static func checkCompletionAdvances(_ ok: inout Bool) {
        var task = ShiftTask.fresh()
        task.title = "Standup notes"
        task.dueDate = "2026-09-16"
        task.dueTime = "09:30"
        task.subtasks = [ShiftSubtask(id: "s1", title: "Read the board", done: true)]
        task.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet)

        guard let spawned = ShiftStore.nextOccurrence(after: task) else {
            fail("completing a recurring task should produce the next occurrence", &ok)
            return
        }
        check(spawned.id != task.id, "the next occurrence must be its own record, not the same id", &ok)
        check(spawned.dueDate == "2026-09-17", "the next weekday after Wed 16th is Thu 17th, got \(spawned.dueDate ?? "nil")", &ok)
        check(spawned.dueTime == "09:30", "the next occurrence should keep the due time", &ok)
        check(spawned.status == .todo && spawned.completedAt == nil,
              "the next occurrence starts undone", &ok)
        check(spawned.recurrence == task.recurrence, "the rule should carry forward", &ok)
        check(spawned.subtasks.first?.done == false,
              "a repeated task's checklist should reset for the new occurrence", &ok)
        check(spawned.subtasks.first?.id != "s1",
              "the new occurrence's subtasks need their own ids", &ok)
        check(spawned.hasAttachment == false,
              "an attachment is keyed by task id and is deliberately not copied", &ok)

        // The negative cases, so the check above cannot pass vacuously.
        var once = task
        once.recurrence = nil
        check(ShiftStore.nextOccurrence(after: once) == nil,
              "a task with no rule must not spawn anything", &ok)
        var undated = task
        undated.dueDate = nil
        undated.dueTime = nil
        check(ShiftStore.nextOccurrence(after: undated) == nil,
              "a rule with no due date to anchor on must not spawn anything", &ok)
        var finished = task
        finished.recurrence = ShiftRecurrence(frequency: .daily, count: 1)
        check(ShiftStore.nextOccurrence(after: finished) == nil,
              "an exhausted rule must not spawn anything", &ok)
    }

    // MARK: The reminder offset

    private static func checkReminderHorizon(_ ok: inout Bool) {
        let now = date("2026-09-16 09:00")
        let fallback = now.addingTimeInterval(30 * 60)

        var plain = ShiftTask.fresh()
        plain.reminderMinutesBefore = nil
        check(ShiftNotificationScheduler.horizon(for: plain, now: now, default: fallback) == fallback,
              "a task with no offset keeps the scheduler's own lookahead", &ok)

        var early = ShiftTask.fresh()
        early.reminderMinutesBefore = 15
        let horizon = ShiftNotificationScheduler.horizon(for: early, now: now, default: fallback)
        check(horizon == now.addingTimeInterval(15 * 60),
              "a 15-minute offset should fire 15 minutes ahead, not 30", &ok)
        // The discriminating half: the offset genuinely *narrows* the default
        // window rather than being ignored, which an equality against the
        // fallback alone would not catch.
        check(horizon < fallback, "a 15-minute offset must be tighter than the 30-minute default", &ok)

        var atDue = ShiftTask.fresh()
        atDue.reminderMinutesBefore = 0
        check(ShiftNotificationScheduler.horizon(for: atDue, now: now, default: fallback) == now,
              "0 means \"at the due time\" and is not the same as no offset", &ok)

        var late = ShiftTask.fresh()
        late.reminderMinutesBefore = 1440
        check(ShiftNotificationScheduler.horizon(for: late, now: now, default: fallback)
              == now.addingTimeInterval(24 * 60 * 60),
              "a day-ahead offset should widen the window past the default", &ok)

        check(ShiftReminderOffset.label(for: 15) == "15 minutes before",
              "the offset label should read as the menu does", &ok)
        check(ShiftReminderOffset.label(for: 1440) == "1 day before", "1440 minutes is a day", &ok)
        check(ShiftReminderOffset.label(for: 0) == "At the due time", "0 has its own wording", &ok)
        // A hand-edited value nothing in the menu offers is named, not dropped.
        check(ShiftReminderOffset.label(for: 45) == "45 minutes before",
              "an unlisted offset should still be named", &ok)
    }

    private static func checkDisplayNames(_ ok: inout Bool) {
        check(ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet).displayName
              == "Every weekday",
              "Mon-Fri weekly is named as the preset the editor offers", &ok)
        check(ShiftRecurrence(frequency: .daily).displayName == "Every day", "daily reads plainly", &ok)
        check(ShiftRecurrence(frequency: .weekly, interval: 2).displayName == "Every 2 weeks",
              "an interval is stated", &ok)
        check(ShiftRecurrence(frequency: .daily, count: 5).displayName == "Every day, 5 times",
              "a bounded rule says how many times", &ok)
    }

    // MARK: Helpers

    private static func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = f.date(from: text) else {
            fatalError("ShiftRecurrenceSelfTest: bad fixture date \(text)")
        }
        return date
    }

    private static func days(_ dates: [Date]) -> [String] {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return dates.map(f.string(from:))
    }
}

#endif
