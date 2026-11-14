// Grand Line - native macOS app.
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
// Run with `FM_RUN_SHIFT_RECURRENCE_TESTS=1 .build/debug/GrandLine`.

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
        checkCarriedComponents(&ok)
        checkExceptionDates(&ok)
        checkMonthDaysAndOrdinals(&ok)
        checkYearly(&ok)
        checkSeriesAndOccurrence(&ok)

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
        check(ShiftRecurrence.parse("FREQ=HOURLY;INTERVAL=1") == nil,
              "an unsupported FREQ must be rejected, not downgraded", &ok)
        check(ShiftRecurrence.parse("FREQ=DAILY;WKST=SU;BYSETPOS=2")?.frequency == .daily,
              "unknown components should not fail the parse", &ok)
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
        // Pinned, never the real clock. B24 made `nextOccurrence` catch up to
        // "now" rather than scheduling into the past, so a fixture that let
        // `now` default to `Date()` would pass today and drift tomorrow -
        // which is exactly the shape of bug this suite exists to catch.
        let completedAt = date("2026-09-16 10:00")
        var task = ShiftTask.fresh()
        task.title = "Standup notes"
        task.dueDate = "2026-09-16"
        task.dueTime = "09:30"
        task.subtasks = [ShiftSubtask(id: "s1", title: "Read the board", done: true)]
        task.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet)

        guard let spawned = ShiftStore.nextOccurrence(after: task, now: completedAt) else {
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
        check(ShiftStore.nextOccurrence(after: once, now: completedAt) == nil,
              "a task with no rule must not spawn anything", &ok)
        var undated = task
        undated.dueDate = nil
        undated.dueTime = nil
        check(ShiftStore.nextOccurrence(after: undated, now: completedAt) == nil,
              "a rule with no due date to anchor on must not spawn anything", &ok)
        var finished = task
        finished.recurrence = ShiftRecurrence(frequency: .daily, count: 1)
        check(ShiftStore.nextOccurrence(after: finished, now: completedAt) == nil,
              "an exhausted rule must not spawn anything", &ok)

        checkCountRunsOut(&ok)
        checkAnOverdueSeriesCatchesUp(&ok)
    }

    // MARK: B24 - COUNT really runs out

    /// A `COUNT=3` series repeated for ever.
    ///
    /// Every spawned instance has its own due date, and that date was handed
    /// to the rule as the series anchor - so the walk's "this is occurrence N"
    /// restarted at 1 on every completion and the budget was never spent. The
    /// remaining count travels on the instance now.
    private static func checkCountRunsOut(_ ok: inout Bool) {
        var task = ShiftTask.fresh()
        task.title = "Onboarding check-in"
        task.dueDate = "2026-09-01"
        task.recurrence = ShiftRecurrence(frequency: .daily, count: 3)

        var dates: [String] = []
        var current: ShiftTask? = task
        // Bounded, so the *failure* is a wrong count rather than a hung suite
        // - which is what the bug would otherwise produce.
        for _ in 0..<12 {
            guard let live = current else { break }
            // Completed on the day it was due, so nothing here depends on the
            // catch-up rule below.
            let completedAt = ShiftDateFormatting.dateTime(from: live.dueDate, time: nil)
                .map { $0.addingTimeInterval(600) } ?? Date()
            current = ShiftStore.nextOccurrence(after: live, now: completedAt)
            if let spawned = current { dates.append(spawned.dueDate ?? "nil") }
        }
        check(dates == ["2026-09-02", "2026-09-03"],
              "COUNT=3 means the anchor plus two more, and then it stops (B24) - got \(dates)", &ok)

        // COUNT=1 is "this once", and the remaining budget is visible on the
        // instance rather than only implied.
        var twice = task
        twice.recurrence = ShiftRecurrence(frequency: .daily, count: 2)
        let after = ShiftStore.nextOccurrence(after: twice, now: date("2026-09-01 10:00"))
        check(after?.recurrence?.count == 1,
              "the spawned instance carries the REMAINING count, got "
              + "\(after?.recurrence?.count.map(String.init) ?? "nil")", &ok)
        check(after.flatMap { ShiftStore.nextOccurrence(after: $0, now: date("2026-09-02 10:00")) } == nil,
              "and that last instance spawns nothing", &ok)

        // An unbounded rule is untouched, so an ordinary repeating task's YAML
        // line is byte-identical to what it always was.
        var forever = task
        forever.recurrence = ShiftRecurrence(frequency: .daily)
        let next = ShiftStore.nextOccurrence(after: forever, now: date("2026-09-01 10:00"))
        check(next?.recurrence == forever.recurrence,
              "an unbounded rule carries forward unchanged", &ok)

        // UNTIL still terminates, and it is a calendar edge rather than a
        // budget - so it must not be affected by the catch-up walk.
        var bounded = task
        bounded.recurrence = ShiftRecurrence(frequency: .daily, until: "2026-09-02")
        check(ShiftStore.nextOccurrence(after: bounded, now: date("2026-09-01 10:00"))?.dueDate
                == "2026-09-02",
              "UNTIL's own last day is still produced", &ok)
        var atUntil = bounded
        atUntil.dueDate = "2026-09-02"
        check(ShiftStore.nextOccurrence(after: atUntil, now: date("2026-09-02 10:00")) == nil,
              "and nothing past it", &ok)
    }

    // MARK: B24 - an overdue series catches up instead of scheduling into the past

    private static func checkAnOverdueSeriesCatchesUp(_ ok: inout Bool) {
        var task = ShiftTask.fresh()
        task.title = "Water the plants"
        task.dueDate = "2026-09-16"
        task.recurrence = ShiftRecurrence(frequency: .daily)

        // Ticked off ten days late. The next instance used to be 2026-09-17 -
        // overdue the moment it was written, and still overdue after the
        // captain ticked it off again, which is a loop with no way out but
        // editing the date by hand.
        let spawned = ShiftStore.nextOccurrence(after: task, now: date("2026-09-26 11:00"))
        check(spawned?.dueDate == "2026-09-27",
              "an overdue daily task schedules its next instance in the FUTURE (B24), got "
              + "\(spawned?.dueDate ?? "nil")", &ok)

        // The discriminating half: a task completed *early* is not pushed
        // forward, so this is a catch-up and not a "always tomorrow" rule.
        let early = ShiftStore.nextOccurrence(after: task, now: date("2026-09-14 11:00"))
        check(early?.dueDate == "2026-09-17",
              "a task completed early still follows the rule from its own due date, got "
              + "\(early?.dueDate ?? "nil")", &ok)

        // And a weekly series keeps its weekday rather than landing on
        // whatever day the catch-up happened to be.
        var weekly = task
        weekly.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: [4])  // Wednesday
        let caught = ShiftStore.nextOccurrence(after: weekly, now: date("2026-09-26 11:00"))
        check(caught?.dueDate == "2026-09-30",
              "a caught-up weekly series lands on its own weekday, got "
              + "\(caught?.dueDate ?? "nil")", &ok)

        // Catching up must not spend the budget: a COUNT series that went
        // unnoticed still owes the captain its remaining occurrences.
        var counted = task
        counted.recurrence = ShiftRecurrence(frequency: .daily, count: 3)
        let caughtCounted = ShiftStore.nextOccurrence(after: counted, now: date("2026-09-26 11:00"))
        check(caughtCounted?.dueDate == "2026-09-27",
              "a COUNT series catches up too, got \(caughtCounted?.dueDate ?? "nil")", &ok)
        check(caughtCounted?.recurrence?.count == 2,
              "and the days it was missed do not eat its remaining occurrences, got "
              + "\(caughtCounted?.recurrence?.count.map(String.init) ?? "nil")", &ok)
    }

    // MARK: The reminder offset

    private static func checkReminderHorizon(_ ok: inout Bool) {
        // A timed task: the reminder fires `minutesBefore` ahead of its due
        // moment, or the scheduler's own lookahead ahead when it has none.
        // The date-only half of this rule is `ShiftDueSelfTest`'s, because
        // its fixture has to be in the local calendar.
        let lookahead: TimeInterval = 30 * 60
        let day = "2026-09-16"
        guard let due = ShiftDateFormatting.dateTime(from: day, time: "09:00") else {
            fail("fixture: a due date and time should resolve", &ok)
            return
        }
        func fire(_ minutes: Int?) -> Date? {
            ShiftDue.reminderFireInstant(date: day, time: "09:00", minutesBefore: minutes,
                                         defaultLookahead: lookahead)
        }

        check(fire(nil) == due.addingTimeInterval(-lookahead),
              "a task with no offset keeps the scheduler's own lookahead", &ok)
        check(fire(15) == due.addingTimeInterval(-15 * 60),
              "a 15-minute offset should fire 15 minutes ahead, not 30", &ok)
        // The discriminating half: the offset genuinely *narrows* the default
        // window rather than being ignored, which an equality against the
        // fallback alone would not catch.
        if let narrow = fire(15), let wide = fire(nil) {
            check(narrow > wide, "a 15-minute offset must be later than the 30-minute default", &ok)
        }
        check(fire(0) == due, "0 means \"at the due time\" and is not the same as no offset", &ok)
        check(fire(1440) == due.addingTimeInterval(-24 * 60 * 60),
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

    // MARK: PR 1 - the rule line round-trips

    /// A component this build does not model must survive this build
    /// rewriting the line. The whole rule is one YAML value, so the task-level
    /// passthrough cannot carry it - this is the only thing that does.
    private static func checkCarriedComponents(_ ok: inout Bool) {
        let foreign = "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO;X-SNOOZE=PT1H;BYSETPOS=2"
        guard var rule = ShiftRecurrence.parse(foreign) else {
            fail("a rule with foreign components should still parse", &ok)
            return
        }
        // The fixture's discriminating power: the components really are ones
        // this build does not model, so they are carried rather than applied.
        check(rule.carried == ["X-SNOOZE=PT1H", "BYSETPOS=2"],
              "fixture: both foreign components should be carried in file order, got \(rule.carried)", &ok)
        check(rule.ruleText == foreign,
              "a rule this build did not write should come back byte-identical, got \(rule.ruleText)", &ok)

        // An edit to a part this build owns keeps what it does not own.
        rule.weekdays.insert(4)
        check(rule.ruleText == "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE;X-SNOOZE=PT1H;BYSETPOS=2",
              "editing the days must keep the foreign components, got \(rule.ruleText)", &ok)

        // A known key whose value does not apply to the frequency is carried
        // whole, not half-applied and not dropped.
        let monthlyPlain = ShiftRecurrence.parse("FREQ=MONTHLY;INTERVAL=1;BYDAY=MO")
        check(monthlyPlain?.carried == ["BYDAY=MO"] && monthlyPlain?.monthWeekdays.isEmpty == true,
              "a plain BYDAY on a monthly rule is carried, got \(monthlyPlain?.ruleText ?? "nil")", &ok)
        let weeklyOrdinal = ShiftRecurrence.parse("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,2FR")
        check(weeklyOrdinal?.carried == ["BYDAY=MO,2FR"] && weeklyOrdinal?.weekdays.isEmpty == true,
              "a BYDAY this build cannot read whole is carried whole, got \(weeklyOrdinal?.ruleText ?? "nil")",
              &ok)
        let dailyMonthDay = ShiftRecurrence.parse("FREQ=DAILY;BYMONTHDAY=1")
        check(dailyMonthDay?.ruleText == "FREQ=DAILY;INTERVAL=1;BYMONTHDAY=1",
              "BYMONTHDAY on a daily rule is carried, got \(dailyMonthDay?.ruleText ?? "nil")", &ok)

        // And a line this build wrote itself carries nothing, so its own
        // output is never mistaken for foreign.
        let own = ShiftRecurrence(frequency: .monthly, monthDays: [-1], exceptionDates: ["2026-10-31"])
        check(ShiftRecurrence.parse(own.ruleText)?.carried == [],
              "this build's own line should carry nothing, got \(ShiftRecurrence.parse(own.ruleText)?.carried ?? [])",
              &ok)
        check(ShiftRecurrence.parse(own.ruleText) == own.normalized,
              "this build's own line should round-trip to an equal rule", &ok)
    }

    private static func checkExceptionDates(_ ok: inout Bool) {
        let anchor = date("2026-09-14 09:00")   // Monday
        let text = "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;EXDATE=2026-09-18,2026-09-16"
        guard let rule = ShiftRecurrence.parse(text) else {
            fail("a rule with EXDATE should parse", &ok)
            return
        }
        check(rule.exceptionDates == ["2026-09-16", "2026-09-18"],
              "EXDATE should parse into its dates, got \(rule.exceptionDates)", &ok)
        check(rule.carried.isEmpty, "EXDATE is modelled, not carried", &ok)
        check(rule.ruleText == "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;EXDATE=2026-09-16,2026-09-18",
              "EXDATE is written sorted, last of this build's own, got \(rule.ruleText)", &ok)

        let produced = days(rule.occurrences(anchor: anchor, from: anchor, through: date("2026-09-25 23:59"),
                                             calendar: calendar, limit: 20))
        check(produced == ["2026-09-14", "2026-09-21", "2026-09-23", "2026-09-25"],
              "skipped dates must not be produced, got \(produced)", &ok)

        // RFC 5545: COUNT is spent before EXDATE removes, so a skipped date
        // still uses up its slot.
        var counted = rule
        counted.count = 4
        let countedDays = days(counted.occurrences(anchor: anchor, from: anchor, through: nil,
                                                   calendar: calendar, limit: 20))
        check(countedDays == ["2026-09-14", "2026-09-21"],
              "a skipped date still counts toward COUNT, got \(countedDays)", &ok)

        check(days([rule.next(after: anchor, anchor: anchor, calendar: calendar)].compactMap { $0 })
                == ["2026-09-21"],
              "next(after:) steps over skipped dates", &ok)

        // GL-35: the spawned instance drops the skipped dates its walk passed,
        // and keeps the ones still ahead of it. Local calendar here, because
        // `nextOccurrence` resolves due dates the way the store does.
        var task = ShiftTask.fresh()
        task.title = "Gym"
        task.dueDate = "2026-09-14"
        task.recurrence = ShiftRecurrence(frequency: .daily,
                                          exceptionDates: ["2026-09-01", "2026-09-15", "2026-09-20", "garbage"])
        let spawned = ShiftStore.nextOccurrence(after: task, now: localNoon("2026-09-14"))
        check(spawned?.dueDate == "2026-09-16",
              "the spawned instance skips an excluded next day, got \(spawned?.dueDate ?? "nil")", &ok)
        check(spawned?.recurrence?.exceptionDates == ["2026-09-20", "garbage"],
              "and drops only the skipped dates before it, got \(spawned?.recurrence?.exceptionDates ?? [])", &ok)
    }

    private static func checkMonthDaysAndOrdinals(_ ok: inout Bool) {
        let anchor = date("2026-01-13 09:00")

        let thirteenth = ShiftRecurrence.parse("FREQ=MONTHLY;BYMONTHDAY=13")
        check(thirteenth?.monthDays == [13], "BYMONTHDAY should parse", &ok)
        let thirteenths = days(thirteenth?.occurrences(anchor: anchor, from: anchor, through: date("2026-04-30 00:00"),
                                                       calendar: calendar, limit: 10) ?? [])
        check(thirteenths == ["2026-01-13", "2026-02-13", "2026-03-13", "2026-04-13"],
              "BYMONTHDAY=13 lands on the 13th, got \(thirteenths)", &ok)

        let last = ShiftRecurrence(frequency: .monthly, monthDays: [-1])
        let lastDays = days(last.occurrences(anchor: anchor, from: anchor, through: date("2026-04-30 23:59"),
                                             calendar: calendar, limit: 10))
        check(lastDays == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"],
              "BYMONTHDAY=-1 is every month's last day, got \(lastDays)", &ok)
        check(calendar.component(.hour, from: last.next(after: anchor, anchor: anchor, calendar: calendar)
                                    ?? .distantPast) == 9,
              "a by-day monthly rule keeps the anchor's time of day", &ok)

        // A day the month does not have is skipped, as RFC 5545 has it - the
        // contrast with the plain monthly rule's clamping is deliberate.
        let thirtyFirst = ShiftRecurrence(frequency: .monthly, monthDays: [31])
        let skipped = days(thirtyFirst.occurrences(anchor: anchor, from: anchor, through: date("2026-05-31 23:59"),
                                                   calendar: calendar, limit: 10))
        check(skipped == ["2026-01-31", "2026-03-31", "2026-05-31"],
              "BYMONTHDAY=31 skips the short months, got \(skipped)", &ok)

        let secondFriday = ShiftRecurrence.parse("FREQ=MONTHLY;BYDAY=2FR")
        check(secondFriday?.monthWeekdays == [ShiftRecurrenceMonthWeekday(ordinal: 2, weekday: 6)],
              "an ordinal BYDAY should parse, got \(secondFriday?.ruleText ?? "nil")", &ok)
        let fridays = days(secondFriday?.occurrences(anchor: anchor, from: anchor, through: date("2026-04-30 00:00"),
                                                     calendar: calendar, limit: 10) ?? [])
        check(fridays == ["2026-02-13", "2026-03-13", "2026-04-10"],
              "2FR is each month's second Friday (January's fell before the anchor), got \(fridays)", &ok)

        let lastMonday = ShiftRecurrence.parse("FREQ=MONTHLY;BYDAY=-1MO")
        let mondays = days(lastMonday?.occurrences(anchor: anchor, from: anchor, through: date("2026-03-31 00:00"),
                                                   calendar: calendar, limit: 10) ?? [])
        check(mondays == ["2026-01-26", "2026-02-23", "2026-03-30"],
              "-1MO is each month's last Monday, got \(mondays)", &ok)

        // Both together intersect: Friday the 13th.
        let unlucky = ShiftRecurrence.parse("FREQ=MONTHLY;BYDAY=1FR,2FR;BYMONTHDAY=13")
        let unluckyDays = days(unlucky?.occurrences(anchor: anchor, from: anchor, through: date("2026-12-31 00:00"),
                                                    calendar: calendar, limit: 10) ?? [])
        check(unluckyDays == ["2026-02-13", "2026-03-13", "2026-11-13"],
              "BYMONTHDAY with BYDAY is their intersection, got \(unluckyDays)", &ok)

        check(ShiftRecurrence(frequency: .monthly, monthWeekdays: [ShiftRecurrenceMonthWeekday(ordinal: -1, weekday: 6),
                                                                   ShiftRecurrenceMonthWeekday(ordinal: 2, weekday: 2)])
                .ruleText == "FREQ=MONTHLY;INTERVAL=1;BYDAY=2MO,-1FR",
              "ordinal entries are written in rule order, 'last' after the counted ones", &ok)
        check(ShiftRecurrence.parse("FREQ=MONTHLY;BYDAY=6FR")?.carried == ["BYDAY=6FR"],
              "an ordinal no month can have is carried rather than applied", &ok)

        check(last.displayName == "Every month on the last day", "got \(last.displayName)", &ok)
        check(thirteenth?.displayName == "Every month on day 13", "got \(thirteenth?.displayName ?? "nil")", &ok)
        let english = ShiftRecurrence.longWeekdayName(6)
        check(secondFriday?.displayName == "Every month on the 2nd \(english)",
              "got \(secondFriday?.displayName ?? "nil")", &ok)
    }

    private static func checkYearly(_ ok: inout Bool) {
        let leap = date("2028-02-29 09:00")
        guard let yearly = ShiftRecurrence.parse("FREQ=YEARLY;INTERVAL=1") else {
            fail("FREQ=YEARLY should parse now", &ok)
            return
        }
        let produced = days(yearly.occurrences(anchor: leap, from: leap, through: date("2032-03-01 00:00"),
                                               calendar: calendar, limit: 10))
        check(produced == ["2028-02-29", "2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"],
              "a 29 February anchor clamps in common years, got \(produced)", &ok)
        let everyOther = ShiftRecurrence(frequency: .yearly, interval: 2)
        check(everyOther.ruleText == "FREQ=YEARLY;INTERVAL=2", "got \(everyOther.ruleText)", &ok)
        check(everyOther.displayName == "Every 2 years", "got \(everyOther.displayName)", &ok)
        check(yearly.displayName == "Every year", "got \(yearly.displayName)", &ok)
    }

    private static func checkSeriesAndOccurrence(_ ok: inout Bool) {
        var task = ShiftTask.fresh()
        task.title = "Review the budget"
        task.recurrence = ShiftRecurrence(frequency: .weekly)
        task.seriesID = "series-1"
        // Monday's slot, moved to Wednesday for this occurrence only.
        task.occurrence = "2026-09-14"
        task.dueDate = "2026-09-16"

        let spawned = ShiftStore.nextOccurrence(after: task, now: localNoon("2026-09-16"))
        check(spawned?.dueDate == "2026-09-21",
              "the series walks from its slot, not the moved date, got \(spawned?.dueDate ?? "nil")", &ok)
        check(spawned?.seriesID == "series-1", "the spawned instance keeps the series id", &ok)
        check(spawned?.occurrence == nil, "and fills its own slot, so it carries no occurrence", &ok)

        // The discriminating half: without a slot the same task walks from
        // its due date, so the check above is really about `occurrence`.
        var plain = task
        plain.occurrence = nil
        check(ShiftStore.nextOccurrence(after: plain, now: localNoon("2026-09-16"))?.dueDate == "2026-09-23",
              "with no occurrence the walk starts from the due date", &ok)
    }

    // MARK: Helpers

    /// Noon on `day` in the machine's own zone, where `ShiftStore` resolves
    /// due dates (AGENTS.md: a day-string fixture needs `Calendar.current`).
    private static func localNoon(_ day: String) -> Date {
        ShiftDateFormatting.dateTime(from: day, time: "12:00") ?? Date()
    }

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
