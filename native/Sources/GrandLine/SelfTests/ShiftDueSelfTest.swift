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
// The tasks-calendar plan's PR 3 added three more, all about *when* a
// reminder fires rather than whether a banner is right:
//
//   - A date-only task's reminder moment was local midnight, so with the
//     poll's 30-minute lookahead a task due Friday posted "Task due today"
//     at 23:30 on Thursday. It is `settings.yaml`'s `all_day_reminder_at`
//     (09:00 by default) on the day now.
//   - The scheduler only looked at live records, so a missed occurrence of a
//     repeating task silenced the rest of the series. The next date reminds
//     now, once, under its own `shift.task.<id>@<date>` identifier.
//   - Follow-ups gained the task editor's "Remind me".
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
        checkDateOnlyRemindersFireOnTheDay(check)
        checkTheReminderTimeComesFromSettings(check)
        checkMissedRepeatRemindsForTheNextDate(check)
        checkTheMissedRepeatThroughThePoll(check)
        checkFollowUpsHaveRemindMe(check)

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

    /// A scratch Shift tree for a suite case that needs a real store, removed
    /// when `body` returns.
    private static func withScratchStore(_ body: (ShiftStore, URL) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-due-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore(), root)
    }

    /// The scheduler's own default lookahead, restated because it is private
    /// to the scheduler. Only the timed cases depend on it.
    private static let lookahead: TimeInterval = 30 * 60

    private static func fires(_ date: String?, _ time: String?, minutesBefore: Int? = nil,
                              allDayAt: String = ShiftDue.defaultAllDayReminderAt,
                              at now: Date) -> Bool {
        guard let fire = ShiftDue.reminderFireInstant(date: date, time: time, minutesBefore: minutesBefore,
                                                      allDayAt: allDayAt, defaultLookahead: lookahead)
        else { return false }
        return fire <= now
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

    // MARK: 4 - a date-only task reminds on its own day

    private static func checkDateOnlyRemindersFireOnTheDay(_ check: (Bool, String) -> Void) {
        let friday = "2026-11-20"
        let thursdayNight = instant("2026-11-19", 23, 30)

        // The fixture's discriminating power: under the old rule (midnight,
        // less the 30-minute lookahead) this exact instant *was* inside the
        // window. Without that, "does not fire at 23:30" proves nothing.
        check(ShiftDateFormatting.dateTime(from: friday, time: nil)!.addingTimeInterval(-lookahead)
                <= thursdayNight,
              "fixture: midnight less the lookahead really is 23:30 the evening before")

        check(!fires(friday, nil, at: thursdayNight),
              "a task due Friday with no time must not remind at 23:30 on Thursday")
        check(!fires(friday, nil, at: instant(friday, 8, 59)),
              "nor at 08:59 on the day - a date-only reminder takes no lookahead")
        check(fires(friday, nil, at: instant(friday, 9)),
              "it reminds at 09:00 on its own day")
        check(ShiftDue.reminderInstant(date: friday, time: nil) == instant(friday, 9),
              "and 09:00 is the moment the reminder is about, got "
              + "\(String(describing: ShiftDue.reminderInstant(date: friday, time: nil)))")

        // "1 day before" is the reminder time on the day before, not midnight
        // two days early.
        check(!fires(friday, nil, minutesBefore: 1440, at: instant("2026-11-19", 8, 59)),
              "\"1 day before\" does not fire before 09:00 on Thursday")
        check(fires(friday, nil, minutesBefore: 1440, at: instant("2026-11-19", 9)),
              "\"1 day before\" fires at 09:00 on Thursday")

        // A timed task keeps exactly the rule it had.
        check(!fires(friday, "15:00", at: instant(friday, 14, 29))
                && fires(friday, "15:00", at: instant(friday, 14, 30)),
              "a timed task with no offset still fires 30 minutes ahead")
        check(!fires(friday, "15:00", minutesBefore: 0, at: instant(friday, 14, 59))
                && fires(friday, "15:00", minutesBefore: 0, at: instant(friday, 15)),
              "0 still means at the due time, and is not the same as no offset")
        check(fires(friday, "15:00", minutesBefore: 120, at: instant(friday, 13))
                && !fires(friday, "15:00", minutesBefore: 120, at: instant(friday, 12, 59)),
              "a 2-hour offset fires at 13:00")
        check(!fires(nil, nil, at: instant(friday, 9)), "no date, no reminder")

        // The same through the real poll, so the fix is the scheduler's
        // behaviour and not only a helper's.
        withScratchStore { store, _ in
            store.addTask(task("friday", due: friday))
            let scheduler = ShiftNotificationScheduler(store: store)
            scheduler.poll(now: thursdayNight)
            check(scheduler.debugNotifiedTaskIDs.isEmpty,
                  "the poll at 23:30 on Thursday must not post for Friday's task, posted for "
                  + scheduler.debugNotifiedTaskIDs.joined(separator: ","))
            scheduler.poll(now: instant(friday, 9))
            check(scheduler.debugNotifiedTaskIDs == ["friday"],
                  "the poll at 09:00 on Friday posts for it, got "
                  + scheduler.debugNotifiedTaskIDs.joined(separator: ","))
        }
    }

    // MARK: 5 - `all_day_reminder_at`

    private static func checkTheReminderTimeComesFromSettings(_ check: (Bool, String) -> Void) {
        let friday = "2026-11-20"
        check(ShiftDue.reminderInstant(date: friday, time: nil, allDayAt: "07:30") == instant(friday, 7, 30),
              "a custom all-day time moves the reminder")
        check(ShiftDue.reminderInstant(date: friday, time: nil, allDayAt: "9:00") == instant(friday, 9),
              "a hand-typed one-digit hour is read")
        for garbage in ["9am", "25:00", "", "09:60", "noon"] {
            check(ShiftDue.reminderInstant(date: friday, time: nil, allDayAt: garbage) == instant(friday, 9),
                  "an unreadable all-day time (\"\(garbage)\") falls back to 09:00, never to midnight")
        }
        check(ShiftDue.reminderInstant(date: friday, time: "15:00", allDayAt: "07:30") == instant(friday, 15),
              "the all-day time never moves a timed task")

        withScratchStore { store, root in
            check(store.settings.allDayReminderAt == "09:00",
                  "a fresh tree defaults to 09:00, got " + store.settings.allDayReminderAt)
            let scaffold = (try? String(contentsOf: root.appendingPathComponent("settings.yaml"),
                                        encoding: .utf8)) ?? ""
            check(scaffold.contains("all_day_reminder_at"),
                  "the scaffolded settings.yaml names the key, so the captain can find it, got:\n" + scaffold)

            // Hand-edited, unquoted - the way a person writes it.
            try? "sync_status: Synced\nall_day_reminder_at: 07:30\n"
                .write(to: root.appendingPathComponent("settings.yaml"), atomically: true, encoding: .utf8)
            let reloaded = ShiftStore()
            check(reloaded.settings.allDayReminderAt == "07:30",
                  "an unquoted 07:30 in settings.yaml reads back as 07:30, got "
                  + reloaded.settings.allDayReminderAt)
            reloaded.addTask(task("early", due: friday))
            let scheduler = ShiftNotificationScheduler(store: reloaded)
            scheduler.poll(now: instant(friday, 7, 29))
            check(scheduler.debugNotifiedTaskIDs.isEmpty, "the poll honours the setting: nothing at 07:29")
            scheduler.poll(now: instant(friday, 7, 30))
            check(scheduler.debugNotifiedTaskIDs == ["early"], "and the reminder at 07:30")
        }
    }

    // MARK: 6 - a missed repeat reminds for its next date

    private static func repeating(_ id: String, due: String, time: String? = nil,
                                  _ rule: ShiftRecurrence) -> ShiftTask {
        var t = task(id, due: due, time: time)
        t.recurrence = rule
        return t
    }

    private static func checkMissedRepeatRemindsForTheNextDate(_ check: (Bool, String) -> Void) {
        // Monday 2026-11-16, repeating Mon/Wed/Fri, left undone.
        let monWedFri = ShiftRecurrence(frequency: .weekly, weekdays: [2, 4, 6])
        let missed = repeating("mwf", due: "2026-11-16", monWedFri)

        check(ShiftNotificationScheduler.occurrenceIdentifier(taskID: "mwf", date: "2026-11-18")
                == "shift.task.mwf@2026-11-18",
              "one identifier per date, distinct from the live record's own shift.task.mwf")

        check(ShiftNotificationScheduler.nextDateToRemind(for: missed, now: instant("2026-11-16", 10)) == nil,
              "while Monday's occurrence is not overdue, its own reminder is the reminder")
        check(ShiftNotificationScheduler.nextDateToRemind(for: missed, now: instant("2026-11-18", 10))
                == "2026-11-18",
              "with Monday missed, Wednesday is the next date, got "
              + (ShiftNotificationScheduler.nextDateToRemind(for: missed, now: instant("2026-11-18", 10)) ?? "nil"))
        check(ShiftNotificationScheduler.nextDateToRemind(for: missed, now: instant("2026-11-19", 10))
                == "2026-11-20",
              "once Wednesday has gone by too, Friday is")

        // A series left for most of a year reminds for today, not for the
        // first date it missed.
        let daily = repeating("daily", due: "2026-01-05", ShiftRecurrence(frequency: .daily))
        check(ShiftNotificationScheduler.nextDateToRemind(for: daily, now: instant("2026-11-18", 10))
                == "2026-11-18",
              "a daily task missed for months reminds for today")

        // A timed series moves on once today's time has passed.
        let timed = repeating("timed", due: "2026-11-16", time: "09:00", monWedFri)
        check(ShiftNotificationScheduler.nextDateToRemind(for: timed, now: instant("2026-11-18", 8))
                == "2026-11-18",
              "a timed repeat reminds for today's slot before it")
        check(ShiftNotificationScheduler.nextDateToRemind(for: timed, now: instant("2026-11-18", 10))
                == "2026-11-20",
              "and for the next one after it")

        // A skipped date is not reminded for: with Wednesday skipped, the
        // date after a missed Monday is Friday.
        var skipping = missed
        skipping.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: [2, 4, 6],
                                              exceptionDates: ["2026-11-18"])
        check(ShiftNotificationScheduler.nextDateToRemind(for: skipping, now: instant("2026-11-18", 10))
                == "2026-11-20",
              "a skipped Wednesday is not reminded for, got "
              + (ShiftNotificationScheduler.nextDateToRemind(for: skipping, now: instant("2026-11-18", 10)) ?? "nil"))

        // An occurrence moved "only this" keeps the series' own cadence: a
        // weekly task whose Monday the 16th was moved to Tuesday the 17th and
        // then missed reminds for the next Monday, not the next Tuesday. A
        // plain weekly rule takes its weekday from the anchor, which is what
        // makes the two anchors disagree.
        var moved = task("moved", due: "2026-11-17")
        moved.recurrence = ShiftRecurrence(frequency: .weekly)
        let unanchored = moved
        moved.occurrence = "2026-11-16"
        check(ShiftNotificationScheduler.nextDateToRemind(for: unanchored, now: instant("2026-11-20", 10))
                == "2026-11-24",
              "fixture: walked from the due date, the next date would be the next Tuesday")
        check(ShiftNotificationScheduler.nextDateToRemind(for: moved, now: instant("2026-11-20", 10))
                == "2026-11-23",
              "a moved occurrence's next date follows the rule slot, got "
              + (ShiftNotificationScheduler.nextDateToRemind(for: moved, now: instant("2026-11-20", 10)) ?? "nil"))

        // The ends of a series.
        var last = missed
        last.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: [2, 4, 6], count: 1)
        check(ShiftNotificationScheduler.nextDateToRemind(for: last, now: instant("2026-11-18", 10)) == nil,
              "the last occurrence of a COUNT series has no next date")
        var ended = missed
        ended.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: [2, 4, 6], until: "2026-11-17")
        check(ShiftNotificationScheduler.nextDateToRemind(for: ended, now: instant("2026-11-18", 10)) == nil,
              "nor does a series whose UNTIL has passed")
        check(ShiftNotificationScheduler.nextDateToRemind(for: task("once", due: "2026-11-16"),
                                                          now: instant("2026-11-18", 10)) == nil,
              "nor a task that does not repeat")
    }

    private static func checkTheMissedRepeatThroughThePoll(_ check: (Bool, String) -> Void) {
        withScratchStore { store, _ in
            var withdrawn: [String] = []
            ShiftNotificationScheduler.withdrawSinkForTests = { withdrawn.append(contentsOf: $0) }
            defer { ShiftNotificationScheduler.withdrawSinkForTests = nil }

            store.addTask(repeating("mwf", due: "2026-11-16",
                                    ShiftRecurrence(frequency: .weekly, weekdays: [2, 4, 6])))
            let scheduler = ShiftNotificationScheduler(store: store)

            scheduler.poll(now: instant("2026-11-18", 8, 59))
            check(scheduler.debugNotifiedOccurrenceIDs.isEmpty,
                  "Wednesday's date reminds at the all-day time, not before it")
            scheduler.poll(now: instant("2026-11-18", 9))
            check(scheduler.debugNotifiedOccurrenceIDs == ["shift.task.mwf@2026-11-18"],
                  "with Monday missed, the poll reminds for Wednesday, got "
                  + scheduler.debugNotifiedOccurrenceIDs.joined(separator: ","))
            check(store.activeTasks.first { $0.id == "mwf" }?.dueDate == "2026-11-16",
                  "and the live record is not rolled forward: Monday stays overdue")
            check(scheduler.debugNotifiedTaskIDs == ["mwf"],
                  "the live record keeps its own overdue banner beside it")

            scheduler.poll(now: instant("2026-11-18", 15))
            check(scheduler.debugNotifiedOccurrenceIDs == ["shift.task.mwf@2026-11-18"] && withdrawn.isEmpty,
                  "once per date: a later poll the same day neither re-posts nor withdraws")

            scheduler.poll(now: instant("2026-11-19", 10))
            check(withdrawn == ["shift.task.mwf@2026-11-18"],
                  "Wednesday's banner is taken back once Wednesday is over, got "
                  + withdrawn.joined(separator: ","))
            check(scheduler.debugNotifiedOccurrenceIDs.isEmpty,
                  "and nothing is posted for Friday on Thursday")

            scheduler.poll(now: instant("2026-11-20", 9))
            check(scheduler.debugNotifiedOccurrenceIDs == ["shift.task.mwf@2026-11-20"],
                  "Friday's date reminds on Friday")

            withdrawn.removeAll()
            store.setTaskCompleted(id: "mwf", completed: true, now: instant("2026-11-20", 10))
            scheduler.poll(now: instant("2026-11-20", 10))
            check(withdrawn.contains("shift.task.mwf@2026-11-20") && withdrawn.contains("shift.task.mwf"),
                  "completing the missed occurrence takes back both its banner and the next date's, got "
                  + withdrawn.joined(separator: ","))
        }
    }

    // MARK: 7 - follow-ups have "Remind me"

    private static func checkFollowUpsHaveRemindMe(_ check: (Bool, String) -> Void) {
        withScratchStore { store, _ in
            var early = ShiftFollowUp.fresh()
            early.id = "early"
            early.title = "Check on the deploy"
            early.followUpAt = "2026-11-20"
            early.followUpTime = "15:00"
            early.reminderMinutesBefore = 120
            store.addFollowUp(early)

            let scheduler = ShiftNotificationScheduler(store: store)
            scheduler.poll(now: instant("2026-11-20", 12, 59))
            check(scheduler.debugNotifiedFollowUpIDs.isEmpty,
                  "a follow-up 2 hours ahead does not fire at 12:59")
            scheduler.poll(now: instant("2026-11-20", 13))
            check(scheduler.debugNotifiedFollowUpIDs == ["early"],
                  "a follow-up's own \"2 hours before\" fires at 13:00 - the default lookahead would "
                  + "have waited until 14:30")

            let reloaded = ShiftStore()
            check(reloaded.followUps.first { $0.id == "early" }?.reminderMinutesBefore == 120,
                  "the offset round-trips through follow-ups.yaml")

            // Snoozing from the banner names the next reminder outright. A
            // "1 day before" offset left in place would put the snoozed
            // follow-up a day in the past and remind again at once.
            var dayAhead = ShiftFollowUp.fresh()
            dayAhead.id = "day-ahead"
            dayAhead.title = "Chase the invoice"
            dayAhead.followUpAt = "2026-11-21"
            dayAhead.followUpTime = "15:00"
            dayAhead.reminderMinutesBefore = 1440
            store.addFollowUp(dayAhead)
            scheduler.poll(now: instant("2026-11-20", 15))
            check(scheduler.debugNotifiedFollowUpDueAt["day-ahead"] == instant("2026-11-21", 15),
                  "fixture: \"1 day before\" fired the day before")
            check(ShiftDue.reminderFireInstant(date: "2026-11-20", time: "16:00", minutesBefore: 1440,
                                               defaultLookahead: lookahead)! <= instant("2026-11-20", 15, 1),
                  "fixture: with the offset kept, the snoozed time would already be due")

            store.snoozeFollowUp(id: "day-ahead", to: instant("2026-11-20", 16), now: instant("2026-11-20", 15))
            check(store.followUps.first { $0.id == "day-ahead" }?.reminderMinutesBefore == 0,
                  "a snooze resets an explicit offset to \"at the time\"")
            scheduler.poll(now: instant("2026-11-20", 15, 1))
            check(scheduler.debugNotifiedFollowUpDueAt["day-ahead"] == instant("2026-11-21", 15),
                  "a follow-up snoozed by an hour must not remind again a minute later")
            scheduler.poll(now: instant("2026-11-20", 16))
            check(scheduler.debugNotifiedFollowUpDueAt["day-ahead"] == instant("2026-11-20", 16),
                  "it reminds at the snoozed time")
        }

        // An editor round trip: the sheet shows the stored offset and Save
        // keeps it. Built without a window - nothing here is rendered.
        var existing = ShiftFollowUp.fresh()
        existing.title = "Ping the vendor"
        existing.followUpAt = "2026-11-20"
        existing.followUpTime = "15:00"
        existing.reminderMinutesBefore = 1440
        let editor = ShiftFollowUpEditorController(followUp: existing, tasks: [], projects: [])
        var saved: ShiftFollowUp?
        editor.onSave = { saved = $0 }
        _ = editor.view
        check(editor.debugReminderTitle == "1 day before",
              "the follow-up sheet shows the stored offset, got " + editor.debugReminderTitle)
        editor.debugTriggerSave()
        check(saved?.reminderMinutesBefore == 1440,
              "and Save keeps it, got \(saved?.reminderMinutesBefore.map(String.init) ?? "nil")")
    }
}

#endif
