// Grand Line - native macOS app.
//
// `FM_RUN_SHIFT_DUE_TESTS` - B22: one definition of "overdue", and banners
// that are taken back.
//
// Two defects, both about two subsystems disagreeing about one task.
//
//   - `ShiftTaskRow` called a task overdue only once the day *after* its due
//     day had started; `ShiftNotifications` called it overdue the moment its
//     due instant passed, and a date-only task's due instant resolves to
//     **local midnight**. So a task due today fired "Task due now" at 00:00
//     and sat in the Notification Center as overdue all day, next to a task
//     list that showed it as simply due today.
//   - Nothing ever called `removeDeliveredNotifications`, so completing or
//     deleting a task left its banner behind.
//
// **Pure logic, no window** - and that classification is operative, not a
// style note (AGENTS.md's "Writing a self-test"): this is not in
// `NEEDS_SESSION`, so it guards CI's blocking lane. `UNUserNotificationCenter`
// is unreachable from an unbundled binary, so the withdrawal is asserted
// through `ShiftNotificationScheduler.withdrawSinkForTests` - what a suite can
// prove is exactly which identifiers would have been taken back.
//
// The fixture pins the **day** at local noon and uses `Calendar.current`,
// never a UTC one: a bare `"YYYY-MM-DD"` resolves to local midnight, so a
// pinned UTC calendar would measure two calendars rather than this rule
// (AGENTS.md, and `ShiftDuePushSelfTest`'s own seven off-by-one failures).

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum ShiftDueSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkTheTwoSubsystemsAgree(check)
        checkBannerTitles(check)
        checkStaleBannersAreWithdrawn(check)

        print(ok ? "ShiftDueSelfTest: all checks passed" : "ShiftDueSelfTest: FAILED")
        return ok
    }

    // MARK: Fixture

    private static let calendar = Calendar.current

    /// Local noon on a pinned day, so no runner's time zone lands the fixture
    /// on a midnight boundary.
    private static func noon(_ day: String) -> Date {
        guard let midnight = ShiftDateFormatting.date(from: day) else {
            return Date(timeIntervalSince1970: 0)
        }
        return calendar.startOfDay(for: midnight).addingTimeInterval(12 * 3600)
    }

    private static func instant(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
        guard let midnight = ShiftDateFormatting.date(from: day) else {
            return Date(timeIntervalSince1970: 0)
        }
        return calendar.startOfDay(for: midnight)
            .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    private static func task(_ id: String, due: String?, time: String? = nil) -> ShiftTask {
        var t = ShiftTask.fresh()
        t.id = id
        t.title = "Task \(id)"
        t.dueDate = due
        t.dueTime = time
        return t
    }

    // MARK: 1 - one definition

    private static func checkTheTwoSubsystemsAgree(_ check: (Bool, String) -> Void) {
        let today = "2026-09-16"

        // The fixture's own discriminating power: local midnight on the due
        // day really is in the past by the time the day is under way, which is
        // the whole reason the old comparison fired.
        check(ShiftDateFormatting.dateTime(from: today, time: nil)! < noon(today),
              "fixture: a date-only due date really does resolve to local midnight, "
              + "which is already past by noon - that is what made `due <= now` fire")

        // A date-only task, through its own day.
        check(!ShiftDue.isOverdue(date: today, time: nil, now: instant(today, 0)),
              "a task due today is NOT overdue at local midnight (B22)")
        check(!ShiftDue.isOverdue(date: today, time: nil, now: instant(today, 23, 59)),
              "nor a minute before the day ends")
        check(ShiftDue.isOverdue(date: today, time: nil, now: instant("2026-09-17", 0)),
              "it becomes overdue when the next day starts - the task list's own rule")

        // A timed task is past due when its time is.
        check(!ShiftDue.isOverdue(date: today, time: "15:00", now: instant(today, 14, 59)),
              "a task due at 15:00 is not overdue at 14:59")
        check(ShiftDue.isOverdue(date: today, time: "15:00", now: instant(today, 15, 1)),
              "and is at 15:01 - a time that has passed is past whatever the day is")

        check(!ShiftDue.isOverdue(date: nil, time: nil, now: noon(today)),
              "a task with no due date is never overdue")
        check(!ShiftDue.isOverdue(date: "not-a-date", time: nil, now: noon(today)),
              "nor one whose due date cannot be read - unknown is not overdue (GL-14)")
    }

    // MARK: 2 - what the banner says

    private static func checkBannerTitles(_ check: (Bool, String) -> Void) {
        let today = "2026-09-16"
        check(ShiftDue.taskTitle(date: today, time: nil, now: instant(today, 0)) == "Task due today",
              "at local midnight a date-only task is due today, not \"due now\" (B22), got "
              + ShiftDue.taskTitle(date: today, time: nil, now: instant(today, 0)))
        check(ShiftDue.taskTitle(date: today, time: nil, now: instant("2026-09-17", 9))
                == "Task due now",
              "and \"due now\" once it genuinely is")
        check(ShiftDue.taskTitle(date: today, time: "15:00", now: instant(today, 14, 45))
                == "Task due soon",
              "a timed task inside the lookahead is due soon")
        check(ShiftDue.followUpTitle(date: today, time: nil, now: instant(today, 0))
                == "Follow-up due today",
              "the same rule for a follow-up, in its own vocabulary")
        // The three must genuinely differ, or the checks above are vacuous.
        check(Set([ShiftDue.taskTitle(date: today, time: nil, now: instant(today, 0)),
                   ShiftDue.taskTitle(date: today, time: nil, now: instant("2026-09-17", 9)),
                   ShiftDue.taskTitle(date: today, time: "15:00", now: instant(today, 14, 45))]).count == 3,
              "the three titles must be three different sentences")
    }

    // MARK: 3 - a banner is taken back

    private static func checkStaleBannersAreWithdrawn(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-due-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        let store = ShiftStore()
        // Due yesterday, so it is unambiguously inside the poll's horizon
        // whatever day this suite runs.
        let yesterday = ShiftDateFormatting.components(
            from: Date().addingTimeInterval(-24 * 3600)).dateStr
        var withdrawn: [String] = []
        ShiftNotificationScheduler.withdrawSinkForTests = { withdrawn.append(contentsOf: $0) }
        defer { ShiftNotificationScheduler.withdrawSinkForTests = nil }

        let doomed = task("doomed", due: yesterday)
        store.addTask(doomed)
        let scheduler = ShiftNotificationScheduler(store: store)
        scheduler.poll()
        // Fixture: the poll really did take an interest in this task, or
        // withdrawing it afterwards would prove nothing.
        check(scheduler.debugNotifiedTaskIDs == ["doomed"],
              "fixture: the poll must have posted for the task, got "
              + scheduler.debugNotifiedTaskIDs.sorted().joined(separator: ","))
        check(withdrawn.isEmpty, "and must not withdraw a banner for a task that is still due")

        store.setTaskCompleted(id: "doomed", completed: true)
        scheduler.poll()
        check(withdrawn == ["shift.task.doomed"],
              "deleting (or completing) a task takes its banner back (B22) - it used to sit in "
              + "Notification Center saying \"Task due now\" for the rest of the day, got "
              + withdrawn.joined(separator: ","))
        check(scheduler.debugNotifiedTaskIDs.isEmpty,
              "and the memo goes with it, so re-adding the same due date notifies again "
              + "rather than being deduped against a banner that no longer exists")

        // Deletion is the other half, and it is a different store path.
        withdrawn.removeAll()
        store.addTask(task("deleted", due: yesterday))
        scheduler.poll()
        check(scheduler.debugNotifiedTaskIDs == ["deleted"],
              "fixture: the second task really was posted for, got "
              + scheduler.debugNotifiedTaskIDs.sorted().joined(separator: ","))
        _ = store.deleteTask(id: "deleted")
        scheduler.poll()
        check(withdrawn == ["shift.task.deleted"],
              "deleting a task takes its banner back too, got " + withdrawn.joined(separator: ","))
    }
}

#endif
