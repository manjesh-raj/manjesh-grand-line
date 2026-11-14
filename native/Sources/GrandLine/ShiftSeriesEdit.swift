// Grand Line - native macOS app.
//
// Exceptions to a repeating task (tasks-calendar plan PR 6): skipping one
// occurrence, moving only this one, and moving this one and every later one.
//
// **One live record, as before.** A repeating task is one record in
// `active.yaml` plus a rule, and the calendar draws the rule's later dates as
// projections (`ShiftStore.nextOccurrence`'s header says why). So an
// exception never means "edit the occurrence's record", because a projection
// has none. Each one is written as a change to the live record, plus, for
// the two rows that split something off, one new task. The plan's operations
// table, row by row:
//
//   | Operation                    | What is written                                    |
//   | ---------------------------- | -------------------------------------------------- |
//   | Skip a projection            | The date joins `EXDATE`.                           |
//   | Skip the live instance       | The record moves to the next slot, `COUNT` - 1.    |
//   | Only this (live)             | The record moves, `occurrence` keeps its slot.     |
//   | Only this (projection)       | The date joins `EXDATE`, a one-off takes its place.|
//   | This and following (proj.)   | The live rule ends before D, a new series starts.  |
//   | This and following (live)    | The record moves, as a drop always did.            |
//
// Completing the live instance is the seventh row and was already right:
// `nextOccurrence` walks from the instance's slot (`ShiftTask.ruleAnchor`).
//
// Pure: every function takes the live record and returns what to write, so
// the store, the calendar and a suite read one set of rules. The store
// writes a `Change` in one go (`ShiftStore.applySeriesEdit`).

import Foundation

/// Which occurrences of a repeating task a move reaches.
enum ShiftSeriesScope: Equatable {
    case onlyThis
    case thisAndFollowing
}

enum ShiftSeriesEdit {

    /// What an exception writes.
    struct Change: Equatable {
        enum Kind: Equatable {
            case skipped
            case restored
            case moved(ShiftSeriesScope)
        }

        var kind: Kind
        /// The live record as it should now be. Same id.
        var updated: ShiftTask
        /// The task split off: the one-off that takes a moved projection's
        /// place, or the new series a "this and following" starts.
        var added: ShiftTask?
    }

    enum Outcome: Equatable {
        case write(Change)
        /// Nothing to write: the date is already skipped, or the drop landed
        /// on the occurrence's own slot.
        case unchanged
        case refused(String)
    }

    // MARK: Skip

    /// "Skip this occurrence". `slot` is the projection's day, or `nil` for
    /// the live instance.
    ///
    /// A projection's date joins `EXDATE`. It still spends its slot of a
    /// `COUNT` (`ShiftRecurrence.exceptionDates`), so skipping one of ten
    /// leaves nine.
    ///
    /// The live instance is the same record moved to its next slot, exactly
    /// where completing it would have put the next one, with the `COUNT`
    /// budget spent the same way. Its checklist starts again, as a spawned
    /// instance's does. A last occurrence has no next slot, so skipping it
    /// would have to delete the task, and that is refused rather than done
    /// behind a menu item called "Skip".
    static func skip(_ live: ShiftTask, slot: String?, now: Date = Date()) -> Outcome {
        guard let rule = live.recurrence else { return .refused(notRepeating(live)) }
        guard live.status != .completed, live.status != .cancelled else { return .refused(finished) }
        guard let slot else {
            guard let next = ShiftStore.nextOccurrence(after: live, now: now) else {
                return .refused("This is the last \u{201C}\(live.title)\u{201D}. Complete it or delete it instead.")
            }
            var updated = live
            updated.dueDate = next.dueDate
            updated.dueTime = next.dueTime
            updated.recurrence = next.recurrence
            updated.occurrence = nil
            updated.occurrenceTime = nil
            updated.subtasks = live.subtasks.map { ShiftSubtask(id: $0.id, title: $0.title, done: false) }
            return .write(Change(kind: .skipped, updated: updated))
        }
        if rule.exceptionDates.contains(slot) { return .unchanged }
        guard isProjection(slot, of: live) else { return .refused(notADate) }
        var updated = live
        updated.recurrence?.exceptionDates.insert(slot)
        return .write(Change(kind: .skipped, updated: updated))
    }

    /// A skipped date, offered back: it leaves `EXDATE`, so the rule draws
    /// it again.
    static func restore(_ live: ShiftTask, slot: String) -> Outcome {
        guard let rule = live.recurrence, rule.exceptionDates.contains(slot) else { return .unchanged }
        var updated = live
        updated.recurrence?.exceptionDates.remove(slot)
        return .write(Change(kind: .restored, updated: updated))
    }

    // MARK: Move

    /// The live instance (`slot == nil`) or the projection on `slot`, dropped
    /// on `day` at `time`.
    ///
    /// The day and the time follow the drop rule every chip follows
    /// (`ShiftCalendarReschedule.apply`): an all-day series stays all-day,
    /// and `adoptsTime` is a tray row landing on a time slot.
    ///
    /// "This and following" from a projection re-anchors the rule on the new
    /// day the way the When panel does (`ShiftScheduleDraft.setDay`): a weekly
    /// rule on the old weekday alone moves to the new one, so "every Monday"
    /// dragged to a Tuesday from here on is every Tuesday from here on.
    static func move(_ live: ShiftTask, slot: String?, to day: String, time: String?,
                     scope: ShiftSeriesScope, adoptsTime: Bool = false, now: Date = Date(),
                     newID: () -> String = { UUID().uuidString }) -> Outcome {
        guard live.recurrence != nil else { return .refused(notRepeating(live)) }
        guard let slot else {
            return moveLive(live, to: day, time: time, scope: scope, adoptsTime: adoptsTime)
        }
        guard live.status != .completed, live.status != .cancelled else { return .refused(finished) }
        guard isProjection(slot, of: live) else { return .refused(notADate) }
        // The projection as a task of its own, so the drop rule decides its
        // new day and time exactly as it would for a chip.
        var occurrence = live
        occurrence.dueDate = slot
        occurrence.dueTime = live.dueTime == nil ? nil : live.slotTime
        let moved: ShiftTask
        switch ShiftCalendarReschedule.apply(task: occurrence, day: day, time: time, adoptsTime: adoptsTime) {
        case .unchanged: return .unchanged
        case .refused(let reason): return .refused(reason)
        case .moved(let task): moved = task
        }
        let iso = ShiftStore.iso8601(now)
        switch scope {
        case .onlyThis:
            var updated = live
            updated.recurrence?.exceptionDates.insert(slot)
            if updated.seriesID == nil { updated.seriesID = newID() }
            var oneOff = splitOff(from: live, id: newID(), iso: iso)
            oneOff.dueDate = moved.dueDate
            oneOff.dueTime = moved.dueTime
            oneOff.recurrence = nil
            oneOff.seriesID = updated.seriesID
            // The slot it fills, so its completed record says which date of
            // the series it was.
            oneOff.occurrence = slot
            return .write(Change(kind: .moved(.onlyThis), updated: updated, added: oneOff))
        case .thisAndFollowing:
            guard let movedDay = moved.dueDate,
                  let (ended, rest) = split(live, at: slot) else { return .refused(notADate) }
            var updated = live
            updated.recurrence = ended
            var series = splitOff(from: live, id: newID(), iso: iso)
            series.dueDate = movedDay
            series.dueTime = moved.dueTime
            series.recurrence = reanchored(rest, from: slot, to: movedDay)
            series.seriesID = newID()
            return .write(Change(kind: .moved(.thisAndFollowing), updated: updated, added: series))
        }
    }

    /// The live instance moved. "Only this" pins its slot (`occurrence`, and
    /// `occurrenceTime` when the time moved too), so the series stays where
    /// it was; a move back onto the slot unpins it. "This and following" is
    /// the drop as it always was: the due date is the series' anchor, so the
    /// series moves with it, nothing is pinned any more, and the rule follows
    /// the new day the way a projection's does.
    private static func moveLive(_ live: ShiftTask, to day: String, time: String?,
                                 scope: ShiftSeriesScope, adoptsTime: Bool) -> Outcome {
        var moved: ShiftTask
        switch ShiftCalendarReschedule.apply(task: live, day: day, time: time, adoptsTime: adoptsTime) {
        case .unchanged: return .unchanged
        case .refused(let reason): return .refused(reason)
        case .moved(let task): moved = task
        }
        switch scope {
        case .onlyThis:
            let (slotDay, slotTime) = (live.slotDay, live.slotTime)
            if moved.dueDate == slotDay && moved.dueTime == slotTime {
                moved.occurrence = nil
                moved.occurrenceTime = nil
            } else {
                moved.occurrence = slotDay
                moved.occurrenceTime = moved.dueTime == slotTime ? nil : slotTime
            }
        case .thisAndFollowing:
            if let rule = live.recurrence, let slotDay = live.slotDay, let movedDay = moved.dueDate {
                moved.recurrence = reanchored(rule, from: slotDay, to: movedDay)
            }
            moved.occurrence = nil
            moved.occurrenceTime = nil
        }
        return .write(Change(kind: .moved(scope), updated: moved))
    }

    // MARK: The rule, split

    /// The live rule ended before `day`, and the rule the series continues
    /// with from `day`, or `nil` when the walk cannot place `day`.
    ///
    /// A `COUNT` budget is shared out rather than duplicated: the live rule
    /// keeps the slots before `day` (counted with the skipped ones, which
    /// spend theirs) and the new series the rest. A rule with no `COUNT`
    /// ends with `UNTIL`, the day before. Ending a counted rule with `UNTIL`
    /// as well would give it two ends, which the When panel can only show as
    /// "Custom rule". Skipped dates go with whichever half they fall in.
    static func split(_ live: ShiftTask, at day: String,
                      calendar: Calendar = .current) -> (ended: ShiftRecurrence, rest: ShiftRecurrence)? {
        guard let rule = live.recurrence?.normalized, let anchor = live.ruleAnchor,
              let dayStart = ShiftDateFormatting.date(from: day),
              let lastDay = ShiftScheduleDraft.adding(days: -1, to: day, calendar: calendar) else { return nil }
        var ended = rule
        var rest = rule
        ended.exceptionDates = rule.exceptionDates.filter { $0 < day }
        rest.exceptionDates = rule.exceptionDates.filter { $0 >= day }
        if let count = rule.count {
            var bare = rule
            bare.exceptionDates = []
            bare.count = nil
            let before = bare.occurrences(anchor: anchor, from: anchor, through: dayStart.addingTimeInterval(-1),
                                          calendar: calendar, limit: count).count
            guard before >= 1, before < count else { return nil }
            ended.count = before
            rest.count = count - before
        } else {
            ended.until = lastDay
        }
        return (ended, rest)
    }

    /// `rule` re-anchored from `oldDay` to `newDay` through the When panel's
    /// own date edit, so the two agree on which parts of a rule only echoed
    /// its date. A rule the panel cannot show comes back unchanged.
    static func reanchored(_ rule: ShiftRecurrence, from oldDay: String, to newDay: String) -> ShiftRecurrence {
        guard oldDay != newDay else { return rule }
        var task = ShiftTask.fresh()
        task.dueDate = oldDay
        task.recurrence = rule
        var draft = ShiftScheduleDraft(task: task)
        draft.setDay(newDay)
        return draft.recurrence ?? rule
    }

    // MARK: Helpers

    /// One occurrence, named the way the dialog and the toasts name it:
    /// "Mon, Nov 16", or "Mon, Nov 16 at 9:30 AM". Always the date itself,
    /// never "Today", because the sentences around it say "the occurrence on".
    static func phrase(_ day: String, time: String?) -> String {
        guard let date = ShiftDateFormatting.dateTime(from: day, time: time) else { return day }
        let dayPart = dayFormatter.string(from: date)
        return time == nil ? dayPart : "\(dayPart) at \(timeFormatter.string(from: date))"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    /// Whether `day` is one of the dates the rule still draws after the live
    /// instance: after its slot, inside `UNTIL` and `COUNT`, and not skipped.
    static func isProjection(_ day: String, of live: ShiftTask, calendar: Calendar = .current) -> Bool {
        guard let rule = live.recurrence, let anchor = live.ruleAnchor, let slotDay = live.slotDay,
              day > slotDay, let start = ShiftDateFormatting.date(from: day),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return !rule.occurrences(anchor: anchor, from: start, through: end.addingTimeInterval(-1),
                                 calendar: calendar, limit: 1).isEmpty
    }

    /// A new open task copied from the live one: its words, project,
    /// priority, tags and reminder. Not its attachment (keyed by the old id)
    /// or its checklist's ticks, the same three things a spawned instance
    /// leaves behind (`ShiftStore.nextOccurrence`).
    private static func splitOff(from live: ShiftTask, id: String, iso: String) -> ShiftTask {
        var task = live
        task.id = id
        task.status = .todo
        task.createdAt = iso
        task.updatedAt = iso
        task.completedAt = nil
        task.subtasks = live.subtasks.map { ShiftSubtask(id: UUID().uuidString, title: $0.title, done: false) }
        task.hasAttachment = false
        task.occurrence = nil
        task.occurrenceTime = nil
        return task
    }

    private static func notRepeating(_ task: ShiftTask) -> String {
        "\u{201C}\(task.title)\u{201D} doesn\u{2019}t repeat."
    }

    private static let finished = "A finished task can\u{2019}t be moved."
    private static let notADate = "That date isn\u{2019}t one of this task\u{2019}s repeats any more."
}
