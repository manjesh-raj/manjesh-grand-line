// Grand Line - native macOS app.
//
// Exceptions to a repeating task (tasks-calendar plan PR 6): one case per row
// of the plan's operations table, each written through a real `ShiftStore`
// over a scratch directory and read back through a second store that has
// only the disk, plus the case the plan names on its own - move only this,
// then complete, and the next date is still on the rule.
//
// **Why this is not window-backed** (AGENTS.md's classification rule): every
// check is a value check on a `ShiftTask`, a rule or the calendar model's
// entries, and the files a store wrote. It builds no view and mounts no
// window, so it runs in CI's blocking lane. The drop dialog, the chip's menu
// and a real drag of a projection are `ShiftCalendarViewSelfTest`'s.
//
// The fixture is a weekly rule written `BYDAY=MO` on Monday 2026-09-14 at
// 09:00, with "now" the Thursday before, so the catch-up in
// `ShiftStore.nextOccurrence` never moves a date. Day strings resolve in the
// machine's own zone, as `ShiftStore` resolves them (AGENTS.md: a
// "YYYY-MM-DD" fixture needs `Calendar.current`).
//
// Run with `FM_RUN_SHIFT_SERIES_EDIT_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import Foundation

enum ShiftSeriesEditSelfTest {

    private static let monday = "2026-09-14"
    private static let now = localNoon("2026-09-10")

    static func run() -> Bool {
        var ok = true

        checkCompleteTheLiveInstance(&ok)
        checkSkipAProjection(&ok)
        checkSkipTheLiveInstance(&ok)
        checkOnlyThisLive(&ok)
        checkOnlyThisProjection(&ok)
        checkThisAndFollowingProjection(&ok)
        checkThisAndFollowingLive(&ok)
        checkMoveOnlyThisThenComplete(&ok)
        checkTheOccurrenceTimeRoundTrips(&ok)

        if ok { print("[ShiftSeriesEditSelfTest] all checks passed") }
        return ok
    }

    // MARK: Row 1 - complete the live instance

    /// As before, plus `series_id` and `occurrence` on the completed record,
    /// and the next instance walked from `occurrence`.
    private static func checkCompleteTheLiveInstance(_ ok: inout Bool) {
        withScratchStore { store in
            var task = weekly("Review the budget")
            task.seriesID = "series-1"
            task.occurrence = monday
            task.dueDate = "2026-09-16"
            store.addTask(task)
            store.setTaskCompleted(id: task.id, completed: true, now: localNoon("2026-09-16"))

            let disk = ShiftStore()
            let done = disk.allCompletedTasks().first { $0.id == task.id }
            check(done?.seriesID == "series-1" && done?.occurrence == monday,
                  "the completed record keeps its series id and its slot, got "
                  + "\(done?.seriesID ?? "nil") / \(done?.occurrence ?? "nil")", &ok)
            let next = disk.activeTasks.first { $0.title == "Review the budget" }
            check(next?.dueDate == "2026-09-21" && next?.dueTime == "09:00" && next?.seriesID == "series-1",
                  "the next instance is walked from the slot, got \(next?.dueDate ?? "nil") \(next?.dueTime ?? "nil")", &ok)
        }
    }

    // MARK: Row 2 - skip a projection

    private static func checkSkipAProjection(_ ok: inout Bool) {
        withScratchStore { store in
            let task = weekly("Water the plants")
            store.addTask(task)
            guard case .write(let change) = ShiftSeriesEdit.skip(task, slot: "2026-09-21", now: now) else {
                fail("skipping a projection should write", &ok)
                return
            }
            store.applySeriesEdit(change, now: now)

            let disk = ShiftStore()
            let live = disk.activeTasks.first { $0.id == task.id }
            check(live?.recurrence?.exceptionDates == ["2026-09-21"],
                  "the date joins EXDATE, got \(live?.recurrence?.ruleText ?? "nil")", &ok)
            check(live?.dueDate == monday && live?.dueTime == "09:00", "the live instance stays where it was", &ok)
            check(disk.activeTasks.count == 1, "skipping a projection adds nothing", &ok)
            check(disk.recentActivity(reference: now).contains { $0.kind == "task_occurrence_skipped" },
                  "the skip is logged", &ok)

            // The calendar draws a marker where the projection was, and the
            // projection after it as before.
            let entries = ShiftCalendarModel.entries(tasks: disk.activeTasks, from: localNoon(monday),
                                                     through: localNoon("2026-09-30"))
            let on21 = entries.filter { $0.day == "2026-09-21" }
            check(on21.count == 1 && on21.first?.isSkipped == true && on21.first?.isProjected == false
                    && on21.first?.title == "Skipped: Water the plants" && on21.first?.isMovable == false
                    && on21.first?.offersMenu == true && on21.first?.time == nil,
                  "a skipped date draws one all-day marker, offering its menu and no drag, got \(on21)", &ok)
            check(entries.contains { $0.day == "2026-09-28" && $0.isProjected },
                  "the next projection is still drawn", &ok)

            // Completing the live instance steps over the skipped date.
            store.setTaskCompleted(id: task.id, completed: true, now: localNoon(monday))
            check(ShiftStore().activeTasks.first?.dueDate == "2026-09-28",
                  "the next instance skips the skipped date", &ok)

            // The discriminating halves: a date the rule never produces is
            // refused, and one already skipped writes nothing.
            check(isRefused(ShiftSeriesEdit.skip(task, slot: "2026-09-22", now: now)),
                  "a date the rule does not produce is refused", &ok)
            if let skipped = live {
                check(ShiftSeriesEdit.skip(skipped, slot: "2026-09-21", now: now) == .unchanged,
                      "an already-skipped date writes nothing", &ok)
            }
        }

        // A skipped date spends its slot of a COUNT, as RFC 5545 has it:
        // three times with one skipped is two instances, not three.
        withScratchStore { store in
            var task = weekly("Three sessions")
            task.recurrence?.count = 3
            store.addTask(task)
            if case .write(let change) = ShiftSeriesEdit.skip(task, slot: "2026-09-21", now: now) {
                store.applySeriesEdit(change, now: now)
            }
            store.setTaskCompleted(id: task.id, completed: true, now: localNoon(monday))
            let second = store.activeTasks.first
            check(second?.dueDate == "2026-09-28" && second?.recurrence?.count == 1,
                  "after the first and a skipped second, the third is the last, got "
                  + "\(second?.dueDate ?? "nil") COUNT=\(second?.recurrence?.count.map(String.init) ?? "nil")", &ok)
            if let second {
                store.setTaskCompleted(id: second.id, completed: true, now: localNoon("2026-09-28"))
            }
            check(store.activeTasks.isEmpty, "the series ends after the third slot, got \(store.activeTasks.map(\.dueDate))", &ok)
        }

        // Restore: the date leaves EXDATE.
        var skipped = weekly("Restore me")
        skipped.recurrence?.exceptionDates = ["2026-09-21"]
        if case .write(let change) = ShiftSeriesEdit.restore(skipped, slot: "2026-09-21") {
            check(change.updated.recurrence?.exceptionDates.isEmpty == true && change.kind == .restored,
                  "restoring takes the date out of EXDATE", &ok)
        } else {
            fail("restoring a skipped date should write", &ok)
        }
        check(ShiftSeriesEdit.restore(skipped, slot: "2026-09-28") == .unchanged,
              "restoring a date that is not skipped writes nothing", &ok)
    }

    // MARK: Row 3 - skip the live instance

    private static func checkSkipTheLiveInstance(_ ok: inout Bool) {
        withScratchStore { store in
            var task = weekly("Rotate the keys")
            task.recurrence?.count = 5
            task.subtasks = [ShiftSubtask(id: "s1", title: "Revoke", done: true)]
            store.addTask(task)
            guard case .write(let change) = ShiftSeriesEdit.skip(task, slot: nil, now: now) else {
                fail("skipping the live instance should write", &ok)
                return
            }
            check(change.added == nil, "skipping the live instance adds nothing", &ok)
            store.applySeriesEdit(change, now: now)

            let disk = ShiftStore()
            let live = disk.activeTasks.first
            check(disk.activeTasks.count == 1 && live?.id == task.id,
                  "the same record stays live, got \(disk.activeTasks.map(\.id))", &ok)
            check(live?.dueDate == "2026-09-21" && live?.dueTime == "09:00",
                  "it moves to the next slot, got \(live?.dueDate ?? "nil") \(live?.dueTime ?? "nil")", &ok)
            check(live?.recurrence?.count == 4, "COUNT is decremented, got \(live?.recurrence?.ruleText ?? "nil")", &ok)
            check(live?.subtasks.map(\.done) == [false], "its checklist starts again", &ok)
            check(disk.allCompletedTasks().isEmpty, "a skip completes nothing", &ok)
            check(disk.recentActivity(reference: now).contains { $0.kind == "task_occurrence_skipped" && $0.targetID == task.id },
                  "a task_occurrence_skipped entry is logged", &ok)
        }

        var last = weekly("The last one")
        last.recurrence?.count = 1
        check(isRefused(ShiftSeriesEdit.skip(last, slot: nil, now: now)),
              "skipping the last occurrence is refused rather than deleting the task", &ok)
    }

    // MARK: Row 4 - only this (live)

    private static func checkOnlyThisLive(_ ok: inout Bool) {
        withScratchStore { store in
            let task = weekly("Standup")
            store.addTask(task)
            guard case .write(let change) = ShiftSeriesEdit.move(task, slot: nil, to: "2026-09-16", time: "14:00",
                                                                 scope: .onlyThis, now: now) else {
                fail("moving the live instance only this time should write", &ok)
                return
            }
            store.applySeriesEdit(change, now: now)
            let live = ShiftStore().activeTasks.first
            check(live?.dueDate == "2026-09-16" && live?.dueTime == "14:00", "the record moves", &ok)
            check(live?.occurrence == monday && live?.occurrenceTime == "09:00",
                  "and keeps its slot, day and time, got \(live?.occurrence ?? "nil") \(live?.occurrenceTime ?? "nil")", &ok)
            check(live?.recurrence == task.recurrence, "the rule is untouched", &ok)

            // The calendar's projections stay on the rule.
            let entries = ShiftCalendarModel.entries(tasks: ShiftStore().activeTasks, from: localNoon(monday),
                                                     through: localNoon("2026-09-30"))
            check(entries.filter(\.isProjected).map(\.day) == ["2026-09-21", "2026-09-28"]
                    && entries.filter(\.isProjected).allSatisfy { $0.time == "09:00" },
                  "the projections stay on Mondays at 09:00, got \(entries.map { "\($0.day) \($0.time ?? "-")" })", &ok)

            // Back onto its slot, it is pinned no more.
            if let live, case .write(let back) = ShiftSeriesEdit.move(live, slot: nil, to: monday, time: "09:00",
                                                                      scope: .onlyThis, now: now) {
                check(back.updated.occurrence == nil && back.updated.occurrenceTime == nil,
                      "an occurrence moved back onto its slot drops the pin", &ok)
            } else {
                fail("moving the instance back should write", &ok)
            }
        }
    }

    // MARK: Row 5 - only this (projection)

    private static func checkOnlyThisProjection(_ ok: inout Bool) {
        withScratchStore { store in
            let task = weekly("Deploy window")
            store.addTask(task)
            guard case .write(let change) = ShiftSeriesEdit.move(task, slot: "2026-09-21", to: "2026-09-23", time: nil,
                                                                 scope: .onlyThis, now: now) else {
                fail("moving a projection only this time should write", &ok)
                return
            }
            store.applySeriesEdit(change, now: now)

            let disk = ShiftStore()
            let live = disk.activeTasks.first { $0.id == task.id }
            let oneOff = disk.activeTasks.first { $0.id != task.id }
            check(live?.recurrence?.exceptionDates == ["2026-09-21"] && live?.dueDate == monday,
                  "the projection's date joins EXDATE and the live instance stays, got \(live?.recurrence?.ruleText ?? "nil")", &ok)
            check(live?.seriesID != nil, "the series gets an id to share", &ok)
            check(oneOff?.dueDate == "2026-09-23" && oneOff?.dueTime == "09:00" && oneOff?.recurrence == nil,
                  "a one-off takes the new date at the slot's time, got "
                  + "\(oneOff?.dueDate ?? "nil") \(oneOff?.dueTime ?? "nil") \(oneOff?.recurrence?.ruleText ?? "no rule")", &ok)
            check(oneOff?.seriesID == live?.seriesID && oneOff?.occurrence == "2026-09-21" && oneOff?.title == "Deploy window",
                  "the one-off shares the series id and names the slot it fills", &ok)

            store.setTaskCompleted(id: task.id, completed: true, now: localNoon(monday))
            check(ShiftStore().activeTasks.contains { $0.id != oneOff?.id && $0.dueDate == "2026-09-28" },
                  "the series' next instance is the slot after the moved one", &ok)
        }
    }

    // MARK: Row 6 - this and following (projection)

    private static func checkThisAndFollowingProjection(_ ok: inout Bool) {
        withScratchStore { store in
            var task = weekly("Office hours")
            task.seriesID = "series-a"
            task.recurrence?.exceptionDates = ["2026-09-21", "2026-10-05"]
            store.addTask(task)
            // Monday the 28th, dragged to Tuesday the 29th from here on.
            guard case .write(let change) = ShiftSeriesEdit.move(task, slot: "2026-09-28", to: "2026-09-29", time: nil,
                                                                 scope: .thisAndFollowing, now: now) else {
                fail("moving a projection and the ones after it should write", &ok)
                return
            }
            store.applySeriesEdit(change, now: now)

            let disk = ShiftStore()
            let live = disk.activeTasks.first { $0.id == task.id }
            let series = disk.activeTasks.first { $0.id != task.id }
            check(live?.recurrence?.until == "2026-09-27" && live?.recurrence?.exceptionDates == ["2026-09-21"],
                  "the live rule ends the day before, keeping its own skips, got \(live?.recurrence?.ruleText ?? "nil")", &ok)
            check(series?.dueDate == "2026-09-29" && series?.dueTime == "09:00",
                  "the new series starts on the drop, got \(series?.dueDate ?? "nil") \(series?.dueTime ?? "nil")", &ok)
            check(series?.recurrence?.weekdays == [3] && series?.recurrence?.until == nil
                    && series?.recurrence?.exceptionDates == ["2026-10-05"],
                  "its rule follows the new weekday and takes the later skips, got \(series?.recurrence?.ruleText ?? "nil")", &ok)
            check(series?.seriesID != nil && series?.seriesID != "series-a", "the new series has an id of its own", &ok)

            let entries = ShiftCalendarModel.entries(tasks: disk.activeTasks, from: localNoon(monday),
                                                     through: localNoon("2026-10-14"))
            let liveDays = entries.filter { $0.taskID == task.id && !$0.isSkipped }.map(\.day)
            check(liveDays == [monday], "the old series draws nothing from the 28th on, got \(liveDays)", &ok)
            let newDays = entries.filter { $0.taskID == series?.id && !$0.isSkipped }.map(\.day)
            check(newDays == ["2026-09-29", "2026-10-06", "2026-10-13"],
                  "the new series draws its Tuesdays, got \(newDays)", &ok)
        }

        // A COUNT is shared out rather than duplicated.
        var counted = weekly("Five lessons")
        counted.recurrence?.count = 5
        counted.recurrence?.exceptionDates = ["2026-09-21"]
        if case .write(let change) = ShiftSeriesEdit.move(counted, slot: "2026-09-28", to: "2026-09-28", time: "10:00",
                                                         scope: .thisAndFollowing, now: now) {
            check(change.updated.recurrence?.count == 2 && change.updated.recurrence?.until == nil,
                  "the live rule keeps the two slots before (one skipped), got \(change.updated.recurrence?.ruleText ?? "nil")", &ok)
            check(change.added?.recurrence?.count == 3 && change.added?.dueTime == "10:00",
                  "the new series takes the other three, got \(change.added?.recurrence?.ruleText ?? "nil")", &ok)
        } else {
            fail("a counted series should split", &ok)
        }
    }

    // MARK: Row 7 - this and following (live)

    private static func checkThisAndFollowingLive(_ ok: inout Bool) {
        withScratchStore { store in
            var task = weekly("Plan the week")
            task.occurrence = "2026-09-07"
            task.occurrenceTime = "08:00"
            store.addTask(task)
            guard case .write(let change) = ShiftSeriesEdit.move(task, slot: nil, to: "2026-09-15", time: nil,
                                                                 scope: .thisAndFollowing, now: now) else {
                fail("moving the live instance and the ones after it should write", &ok)
                return
            }
            check(change.added == nil, "nothing is split off", &ok)
            store.applySeriesEdit(change, now: now)
            let live = ShiftStore().activeTasks.first
            check(live?.dueDate == "2026-09-15" && live?.dueTime == "09:00", "the record moves", &ok)
            check(live?.occurrence == nil && live?.occurrenceTime == nil, "and is pinned to no slot any more", &ok)
            check(live?.recurrence?.weekdays == [3], "its rule follows the new weekday, got \(live?.recurrence?.ruleText ?? "nil")", &ok)
            if let live {
                check(ShiftStore.nextOccurrence(after: live, now: localNoon("2026-09-15"))?.dueDate == "2026-09-22",
                      "the series moves with it", &ok)
            }
        }
    }

    // MARK: The plan's own case

    /// Move only this, then complete: the next date is still on the rule.
    private static func checkMoveOnlyThisThenComplete(_ ok: inout Bool) {
        withScratchStore { store in
            let task = weekly("Weekly report")
            store.addTask(task)
            guard case .write(let change) = ShiftSeriesEdit.move(task, slot: nil, to: "2026-09-17", time: "16:30",
                                                                 scope: .onlyThis, now: now) else {
                fail("moving only this should write", &ok)
                return
            }
            store.applySeriesEdit(change, now: now)
            store.setTaskCompleted(id: task.id, completed: true, now: localNoon("2026-09-17"))

            let disk = ShiftStore()
            let next = disk.activeTasks.first
            check(next?.dueDate == "2026-09-21" && next?.dueTime == "09:00",
                  "the next date is still Monday at 09:00, got \(next?.dueDate ?? "nil") \(next?.dueTime ?? "nil")", &ok)
            check(next?.occurrence == nil && next?.occurrenceTime == nil, "and fills its own slot", &ok)
            check(next?.recurrence == task.recurrence, "the rule is the same rule", &ok)
            let done = disk.allCompletedTasks().first { $0.id == task.id }
            check(done?.dueDate == "2026-09-17" && done?.occurrence == monday,
                  "the finished one is filed on the day it was moved to, naming its slot", &ok)

            // The discriminating half: the pin is what kept the time. Without
            // `occurrenceTime` the series would have taken 16:30.
            var unpinned = change.updated
            unpinned.occurrenceTime = nil
            check(ShiftStore.nextOccurrence(after: unpinned, now: localNoon("2026-09-17"))?.dueTime == "16:30",
                  "without the slot's time the series would drift to the moved time", &ok)
        }
    }

    /// `occurrence_time` is a known key: written, read back, and not carried
    /// a second time by the passthrough.
    private static func checkTheOccurrenceTimeRoundTrips(_ ok: inout Bool) {
        var task = weekly("Round trip")
        task.occurrence = monday
        task.occurrenceTime = "09:00"
        let yaml = ShiftYaml.toYaml(task)
        let back = ShiftYaml.task(from: yaml)
        check(back?.occurrenceTime == "09:00" && back?.occurrence == monday,
              "occurrence_time survives a write and a read, got \(back?.occurrenceTime ?? "nil")", &ok)
        check(ShiftYaml.taskKnownKeys.contains("occurrence_time"), "occurrence_time is a known task key", &ok)
    }

    // MARK: Helpers

    /// Weekly on Mondays from Monday 2026-09-14 at 09:00.
    private static func weekly(_ title: String) -> ShiftTask {
        var task = ShiftTask.fresh(now: now)
        task.title = title
        task.dueDate = monday
        task.dueTime = "09:00"
        task.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: [2])
        return task
    }

    private static func isRefused(_ outcome: ShiftSeriesEdit.Outcome) -> Bool {
        if case .refused = outcome { return true }
        return false
    }

    private static func localNoon(_ day: String) -> Date {
        ShiftDateFormatting.dateTime(from: day, time: "12:00") ?? Date()
    }

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-series-edit-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }
}

#endif
