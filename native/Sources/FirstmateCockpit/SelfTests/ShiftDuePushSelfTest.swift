// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_SHIFT_DUE_PUSH_TESTS` - review #3's UX7 reschedule gesture.
//
// Pure date arithmetic against an injected `today`, so nothing here depends on
// what day the suite runs or how fast the machine is. That matters more than
// usual for this one: a date test that reads the real clock passes every day
// except the ones that cross a month, a year or a DST boundary, which is
// exactly the shape of bug it is meant to catch.
//
// Not in `NEEDS_SESSION`: no window, no view, no store.
//
// GL-27: debug builds only.
#if FM_SELFTESTS

import Foundation

enum ShiftDuePushSelfTest {
    static func run() -> Bool {
        var ok = true
        ok = checkBasics() && ok
        ok = checkOverdueLandsInTheFuture() && ok
        ok = checkBoundaries() && ok
        return ok
    }

    /// A fixed "today", so every expectation below is a literal date rather
    /// than a re-derivation of the function under test - AGENTS.md:
    /// "re-deriving an expected value from the function under test asserts
    /// nothing at all".
    ///
    /// **Gregorian, but the machine's own time zone**, which is not a detail:
    /// `ShiftDuePush.newDueDate` reads the stored due date back through
    /// `ShiftDateFormatting.date(from:)`, whose formatter pins a Gregorian
    /// calendar but inherits the default time zone - so it resolves
    /// `"2026-03-10"` to *local* midnight. Computing `startOfDay` against a
    /// UTC calendar over that date lands on the previous day west of
    /// Greenwich, and this suite caught exactly that on the first run (seven
    /// failures, all off by one).
    ///
    /// Pinning the calendar to the parser's own zone is what makes these
    /// literals deterministic on any machine, and it is what the app does in
    /// production - every date in this feature is a local calendar day, which
    /// is the right model for "due Tuesday".
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    private static func day(_ iso: String) -> Date {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return calendar.date(from: components) ?? Date()
    }

    private static func push(_ option: ShiftDuePush, due: String?, today: String) -> String? {
        option.newDueDate(currentDueDate: due, today: day(today), calendar: calendar)
    }

    private static func checkBasics() -> Bool {
        var ok = true
        // A task due in the future pushes off its own due date, not off today
        // - otherwise "push to tomorrow" on something due next month would
        // drag it *forward* by three weeks, which is the opposite of what the
        // gesture says.
        check(push(.tomorrow, due: "2026-03-10", today: "2026-03-01") == "2026-03-11",
              "UX7: a future task pushed to Tomorrow should move one day past its own due date", &ok)
        check(push(.nextWeek, due: "2026-03-10", today: "2026-03-01") == "2026-03-17",
              "UX7: Next week should be seven days past the due date", &ok)

        // An undated task is scheduled from today - "push to tomorrow" on
        // something with no date is a reasonable way to give it one.
        check(push(.tomorrow, due: nil, today: "2026-03-01") == "2026-03-02",
              "UX7: an undated task pushed to Tomorrow should land tomorrow", &ok)
        check(push(.nextWeek, due: nil, today: "2026-03-01") == "2026-03-08",
              "UX7: an undated task pushed to Next week should land in seven days", &ok)

        // An unparseable stored value behaves like no value rather than
        // producing nothing - a task whose `dueDate` went strange must still
        // be reschedulable.
        check(push(.tomorrow, due: "not-a-date", today: "2026-03-01") == "2026-03-02",
              "UX7: an unparseable due date should reschedule from today, not refuse", &ok)
        return ok
    }

    /// **The case the gesture exists for.** An overdue task is the most common
    /// thing a captain pushes, and basing the arithmetic off the task's own
    /// due date would land it in the past - a "push" that leaves the task
    /// still overdue is worse than useless.
    private static func checkOverdueLandsInTheFuture() -> Bool {
        var ok = true
        let today = "2026-03-01"
        for option in ShiftDuePush.allCases {
            guard let result = push(option, due: "2026-02-10", today: today) else {
                fail("UX7: pushing an overdue task by \(option.rawValue) produced nothing", &ok)
                continue
            }
            check(result > today,
                  "UX7: an overdue task pushed to \(option.menuTitle) landed on \(result), which is not after \(today)", &ok)
        }
        // Exactly, not just "in the future": three weeks overdue pushed to
        // Tomorrow is tomorrow, not three weeks ago plus a day.
        check(push(.tomorrow, due: "2026-02-10", today: today) == "2026-03-02",
              "UX7: an overdue task pushed to Tomorrow should land tomorrow", &ok)
        check(push(.nextWeek, due: "2026-02-10", today: today) == "2026-03-08",
              "UX7: an overdue task pushed to Next week should land seven days from today", &ok)

        // A task due *today* is not overdue, and both readings agree, so this
        // is the one case where the max() cannot be got wrong - asserted so a
        // future change to the base rule has to keep it true.
        check(push(.tomorrow, due: today, today: today) == "2026-03-02",
              "UX7: a task due today pushed to Tomorrow should land tomorrow", &ok)
        return ok
    }

    /// Month, year and leap-day rollover - the three places a hand-rolled
    /// "+1 day" is wrong, and the reason this goes through `Calendar`.
    private static func checkBoundaries() -> Bool {
        var ok = true
        check(push(.tomorrow, due: "2026-03-31", today: "2026-03-01") == "2026-04-01",
              "UX7: a push across a month boundary was wrong", &ok)
        check(push(.tomorrow, due: "2026-12-31", today: "2026-12-01") == "2027-01-01",
              "UX7: a push across a year boundary was wrong", &ok)
        check(push(.nextWeek, due: "2026-12-28", today: "2026-12-01") == "2027-01-04",
              "UX7: a seven-day push across a year boundary was wrong", &ok)
        // 2028 is a leap year; 2027 is not.
        check(push(.tomorrow, due: "2028-02-28", today: "2028-02-01") == "2028-02-29",
              "UX7: a push into a leap day was wrong", &ok)
        check(push(.tomorrow, due: "2027-02-28", today: "2027-02-01") == "2027-03-01",
              "UX7: a push out of a non-leap February was wrong", &ok)

        // The stored shape is what `ShiftDateFormatting` can read back. A
        // round-trip, because a due date this app writes and cannot parse is
        // the same bug as writing the wrong day.
        guard let pushed = push(.tomorrow, due: "2026-03-31", today: "2026-03-01") else {
            fail("UX7: no date to round-trip", &ok)
            return ok
        }
        check(pushed.count == 10 && ShiftDateFormatting.date(from: pushed) != nil,
              "UX7: the pushed due date \"\(pushed)\" is not in the shape ShiftTask persists and reads back", &ok)

        // Every option has a menu title, since that is what the gesture is.
        for option in ShiftDuePush.allCases {
            check(!option.menuTitle.isEmpty, "UX7: \(option.rawValue) has no menu title", &ok)
        }
        return ok
    }
}

#endif
