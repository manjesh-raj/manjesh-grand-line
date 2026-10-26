// Grand Line - native macOS app.
//
// What the Tasks popover says in the Bridge shape, derived from the tasks
// Grand Line already stores.
//
// The captain picked the notification redesign's style A, "Bridge", and asked
// for the Tasks popover to take the same shape: the Tootask-style menu-bar
// popover with a hero Now card, an Up next list, a backlog to claim from and
// a "2 of 6 done today" count. Everything here comes from data `ShiftStore`
// already has - due date and time, status, subtasks, projects and
// `completedAt`. The streak is the one new number, and it is a derivation
// over completed tasks rather than a stored field.
//
// **Separate from the views, and clock-injectable, for the reason
// `CompactModeDigest` is.** Every string here is a function of "now" ("25m
// late", "Tmrw", "done today"), so the whole derivation takes `now` and a
// calendar as parameters, returns value types, and is asserted by
// `FM_RUN_COMPACT_MODE_TESTS` in CI's blocking lane. The views render what
// they are handed and compute nothing.
//
// The day rule is `CompactModeDigest.dueDay`, shared rather than copied, so
// "overdue" means the same thing here, on the Today tab's badge and on the
// right-click menu.

import Foundation

// MARK: - The digest

/// Everything the Bridge-shaped Tasks popover shows.
struct TasksBridgeDigest: Equatable {

    /// "2 of 6 done today".
    ///
    /// `done` is the tasks whose `completedAt` falls today. `total` adds every
    /// open task due today or earlier, which is what was on the captain's
    /// plate this morning.
    struct Progress: Equatable {
        let done: Int
        let total: Int

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        /// The compact chip text, "2/6".
        var shortText: String { "\(done)/\(total)" }
        /// What VoiceOver reads for the chip and the bar.
        var spokenText: String { "\(done) of \(total) done today" }
    }

    /// The hero card: the one task due now, or the next one due today.
    struct NowCard: Equatable {
        let id: String
        let title: String
        /// The time pill: "11:00 \u{00B7} 25m late", "15:30", "Today" or
        /// "16 Sep \u{00B7} overdue".
        let whenText: String
        /// Whether the pill reads as late. Painted, and also said in words.
        let isLate: Bool
        /// "3 of 5 checked", or nil for a task with no subtasks.
        let checklistText: String?
        /// The caption under the title: the checklist, the project and a
        /// high priority, whichever exist.
        let detail: String
    }

    /// One row of Up next: a task or a follow-up, with its time.
    struct TimelineRow: Equatable {
        enum Kind: Equatable {
            case task
            case followUp
        }

        let id: String
        let kind: Kind
        /// The leading time column: "13:00", "Today", "Tmrw", "Thu" or "16 Sep".
        let timeText: String
        let title: String
        let detail: String
        let urgency: CompactTaskRow.Urgency
    }

    /// One row of "Backlog \u{00B7} claim to start": an open task with no due
    /// date.
    struct BacklogRow: Equatable {
        let id: String
        let title: String
        let detail: String
        /// Already In progress, so the row says so instead of offering Claim.
        let isClaimed: Bool
    }

    /// "Mon 26 Oct", in the captain's own locale.
    let dateText: String
    /// Nil when nothing was due today and nothing was finished today. That is
    /// a different state from "0/0" and reads differently (GL-14).
    let progress: Progress?
    /// Consecutive days with at least one completed task. Zero hides the chip.
    let streakDays: Int
    let now: NowCard?
    /// What the Now card says when `now` is nil, so it is never a blank card.
    let nothingDueCaption: String
    let upNext: [TimelineRow]
    let backlog: [BacklogRow]
    /// "17:24 focus", nil when no focus time was logged today (GL-14).
    let focusChip: String?
    /// "2 follow-ups", nil when none is pending.
    let followUpChip: String?

    var isEmpty: Bool { now == nil && upNext.isEmpty && backlog.isEmpty }

    static let empty = TasksBridgeDigest(
        dateText: "", progress: nil, streakDays: 0, now: nil,
        nothingDueCaption: TasksBridge.nothingScheduledCaption,
        upNext: [], backlog: [], focusChip: nil, followUpChip: nil)
}

// MARK: - The derivation

enum TasksBridge {

    /// Up next stops where the Today tab always stopped: the next few, and
    /// a way into the real page for the rest.
    static let upNextMaxRows = CompactModeDigest.maxRows

    /// The backlog is a nudge, not a second task list.
    static let backlogMaxRows = 3

    static let nothingScheduledCaption = "Nothing else is scheduled."
    static let claimFromBacklogCaption = "Claim one from the backlog to start."

    /// The whole popover from a store's contents.
    ///
    /// - Parameters:
    ///   - tasks: the open tasks (`ShiftStore.activeTasks`).
    ///   - completed: every completed task (`ShiftStore.allCompletedTasks()`),
    ///     for the progress count and the streak.
    static func digest(tasks: [ShiftTask],
                       completed: [ShiftTask],
                       followUps: [ShiftFollowUp],
                       projects: [ShiftProject],
                       focusSecondsToday: Int,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> TasksBridgeDigest {
        let startOfToday = calendar.startOfDay(for: now)
        let projectNames = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        let timeline = timelineEntries(tasks: tasks, followUps: followUps,
                                       startOfToday: startOfToday, calendar: calendar)

        // Now is a task, never a follow-up: its buttons are Check off and
        // Start focus, and a follow-up has neither.
        let nowEntry = timeline.first { $0.kind == .task && $0.urgency != .later }
        var nowCard: TasksBridgeDigest.NowCard?
        if let nowEntry, let task = tasks.first(where: { $0.id == nowEntry.id }) {
            nowCard = Self.nowCard(for: task, entry: nowEntry, projectNames: projectNames, now: now)
        }

        let upNext = timeline
            .filter { $0.id != nowCard?.id || $0.kind != .task }
            .prefix(upNextMaxRows)
            .map { row(for: $0, projectNames: projectNames, now: now, calendar: calendar) }

        let backlog = backlogRows(tasks: tasks, projectNames: projectNames)

        let nothingDue: String
        if let next = upNext.first {
            nothingDue = "Next: \(next.title) \u{00B7} \(next.timeText)"
        } else if !backlog.isEmpty {
            nothingDue = claimFromBacklogCaption
        } else {
            nothingDue = nothingScheduledCaption
        }

        let pendingFollowUps = followUps.filter { $0.status == .pending }.count

        return TasksBridgeDigest(
            dateText: dateFormatter.string(from: now),
            progress: progress(tasks: tasks, completed: completed, now: now, calendar: calendar),
            streakDays: streak(completed: completed, now: now, calendar: calendar),
            now: nowCard,
            nothingDueCaption: nothingDue,
            upNext: Array(upNext),
            backlog: backlog,
            focusChip: focusSecondsToday > 0
                ? "\(CompactModeDigest.focusText(seconds: focusSecondsToday)) focus" : nil,
            followUpChip: pendingFollowUps > 0
                ? "\(pendingFollowUps) follow-up\(pendingFollowUps == 1 ? "" : "s")" : nil)
    }

    // MARK: Progress and streak

    /// "2 of 6 done today", or nil when there is nothing to count.
    static func progress(tasks: [ShiftTask], completed: [ShiftTask],
                         now: Date = Date(), calendar: Calendar = .current) -> TasksBridgeDigest.Progress? {
        let startOfToday = calendar.startOfDay(for: now)
        let done = completed.filter { task in
            guard let day = completedDay(of: task, calendar: calendar) else { return false }
            return day == startOfToday
        }.count
        let planned = tasks.filter { task in
            guard let urgency = CompactModeDigest.dueDay(of: task, startOfToday: startOfToday,
                                                         calendar: calendar)?.urgency else { return false }
            return urgency != .later
        }.count
        let total = done + planned
        return total > 0 ? .init(done: done, total: total) : nil
    }

    /// How many days in a row the captain has finished at least one task.
    ///
    /// The run ends today when something was finished today. When nothing has
    /// been finished yet today it ends yesterday instead, because the day is
    /// not over: a streak that dropped to zero at midnight would punish the
    /// captain for opening the popover before their first task of the day.
    /// A day with nothing finished breaks it.
    ///
    /// A derivation over `completedAt` and nothing else - no new stored field.
    static func streak(completed: [ShiftTask], now: Date = Date(),
                       calendar: Calendar = .current) -> Int {
        let days = Set(completed.compactMap { completedDay(of: $0, calendar: calendar) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                  days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// The local day a task was finished on, or nil for one that is not
    /// finished (a reopened task has its `completedAt` cleared).
    private static func completedDay(of task: ShiftTask, calendar: Calendar) -> Date? {
        guard task.status != .cancelled,
              let stamp = task.completedAt,
              let date = ShiftStore.date(fromISO8601: stamp) else { return nil }
        return calendar.startOfDay(for: date)
    }

    // MARK: The timeline

    /// A task or a follow-up with a due day, before it becomes a row.
    private struct Entry {
        let id: String
        let kind: TasksBridgeDigest.TimelineRow.Kind
        let title: String
        let dueDay: Date
        /// The due instant, only when a time was set.
        let dueAt: Date?
        let dueTime: String?
        let urgency: CompactTaskRow.Urgency
        let priority: ShiftPriority
        let projectID: String?
    }

    /// Every dated open task and pending follow-up, in the order the captain
    /// should meet them.
    ///
    /// Overdue first (oldest first, as the Today tab always did), then today,
    /// then later. Within one day a task with a time comes before one without
    /// (the time is a commitment, "today" is not), times run in order, and a
    /// high priority breaks a tie. The id is the last resort, so two equal
    /// rows never swap places between two opens.
    private static func timelineEntries(tasks: [ShiftTask], followUps: [ShiftFollowUp],
                                        startOfToday: Date, calendar: Calendar) -> [Entry] {
        var entries: [Entry] = tasks.compactMap { task in
            guard let (day, urgency) = CompactModeDigest.dueDay(of: task, startOfToday: startOfToday,
                                                                calendar: calendar) else { return nil }
            return Entry(id: task.id, kind: .task, title: task.title, dueDay: day,
                         dueAt: task.dueTime == nil ? nil
                            : ShiftDateFormatting.dateTime(from: task.dueDate, time: task.dueTime),
                         dueTime: task.dueTime, urgency: urgency, priority: task.priority,
                         projectID: task.projectID)
        }
        for followUp in followUps where followUp.status == .pending {
            guard let date = followUp.followUpAt.flatMap(ShiftDateFormatting.date(from:)) else { continue }
            let day = calendar.startOfDay(for: date)
            let urgency: CompactTaskRow.Urgency = day < startOfToday ? .overdue
                : calendar.isDate(day, inSameDayAs: startOfToday) ? .today : .later
            entries.append(Entry(
                id: followUp.id, kind: .followUp, title: followUp.title, dueDay: day,
                dueAt: followUp.followUpTime == nil ? nil
                    : ShiftDateFormatting.dateTime(from: followUp.followUpAt, time: followUp.followUpTime),
                dueTime: followUp.followUpTime, urgency: urgency, priority: followUp.priority,
                projectID: followUp.projectID))
        }

        func rank(_ urgency: CompactTaskRow.Urgency) -> Int {
            switch urgency {
            case .overdue: return 0
            case .today: return 1
            case .later: return 2
            }
        }
        return entries.sorted { a, b in
            if rank(a.urgency) != rank(b.urgency) { return rank(a.urgency) < rank(b.urgency) }
            if a.dueDay != b.dueDay { return a.dueDay < b.dueDay }
            switch (a.dueAt, b.dueAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if (a.priority == .high) != (b.priority == .high) { return a.priority == .high }
            return a.id < b.id
        }
    }

    private static func nowCard(for task: ShiftTask, entry: Entry,
                                projectNames: [String: String], now: Date) -> TasksBridgeDigest.NowCard {
        let whenText: String
        let isLate: Bool
        switch entry.urgency {
        case .overdue:
            whenText = "\(ShiftDateFormatting.monthDay(entry.dueDay)) \u{00B7} overdue"
            isLate = true
        case .today, .later:
            if let dueAt = entry.dueAt, let time = entry.dueTime {
                let clock = ShiftDateFormatting.clock(time)
                if dueAt < now {
                    whenText = "\(clock) \u{00B7} \(lateness(from: dueAt, to: now)) late"
                    isLate = true
                } else {
                    whenText = clock
                    isLate = false
                }
            } else {
                whenText = "Today"
                isLate = false
            }
        }

        let checklist: String? = task.subtasks.isEmpty ? nil
            : "\(task.subtasks.filter { $0.done }.count) of \(task.subtasks.count) checked"
        var parts: [String] = []
        if let checklist { parts.append(checklist) }
        if let name = task.projectID.flatMap({ projectNames[$0] }), !name.isEmpty { parts.append(name) }
        if task.priority == .high { parts.append("High") }

        return .init(id: task.id, title: task.title, whenText: whenText, isLate: isLate,
                     checklistText: checklist, detail: parts.joined(separator: " \u{00B7} "))
    }

    /// "25m", "2h" - how late a timed task is, read off the injected clock.
    static func lateness(from due: Date, to now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(due) / 60))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private static func row(for entry: Entry, projectNames: [String: String],
                            now: Date, calendar: Calendar) -> TasksBridgeDigest.TimelineRow {
        let clock = entry.dueTime.map(ShiftDateFormatting.clock)
        let timeText: String
        var parts: [String] = []
        switch entry.urgency {
        case .overdue:
            timeText = ShiftDateFormatting.monthDay(entry.dueDay)
            parts.append("Overdue")
            if let clock { parts.append(clock) }
        case .today:
            timeText = clock ?? "Today"
        case .later:
            timeText = laterDayText(entry.dueDay, now: now, calendar: calendar)
            if let clock { parts.append(clock) }
        }
        if entry.kind == .followUp { parts.append("Follow-up") }
        if let name = entry.projectID.flatMap({ projectNames[$0] }), !name.isEmpty { parts.append(name) }
        // Only `high` earns a word, as on the Today tab: `normal` is on every
        // task `ShiftTask.fresh()` makes, so printing it says nothing.
        if entry.priority == .high { parts.append("High") }
        return .init(id: entry.id, kind: entry.kind, timeText: timeText, title: entry.title,
                     detail: parts.joined(separator: " \u{00B7} "), urgency: entry.urgency)
    }

    /// "Tmrw", a weekday for the rest of this week, and a date beyond it.
    /// Short, because it sits in the row's fixed time column.
    private static func laterDayText(_ day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if days == 1 { return "Tmrw" }
        if days > 1 && days < 7 { return weekdayFormatter.string(from: day) }
        return ShiftDateFormatting.monthDay(day)
    }

    // MARK: The backlog

    /// Open tasks with no due date: what is waiting to be claimed.
    ///
    /// Already-claimed (In progress) first, so the work in hand stays in
    /// view, then high priority, then the oldest - the one that has waited
    /// longest is the one most worth a nudge.
    private static func backlogRows(tasks: [ShiftTask],
                                    projectNames: [String: String]) -> [TasksBridgeDigest.BacklogRow] {
        tasks
            .filter { ($0.status == .todo || $0.status == .inProgress) && ($0.dueDate ?? "").isEmpty }
            .sorted { a, b in
                if (a.status == .inProgress) != (b.status == .inProgress) { return a.status == .inProgress }
                if (a.priority == .high) != (b.priority == .high) { return a.priority == .high }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            }
            .prefix(backlogMaxRows)
            .map { task in
                var parts = ["No due date"]
                if let name = task.projectID.flatMap({ projectNames[$0] }), !name.isEmpty { parts.append(name) }
                if task.priority == .high { parts.append("High") }
                return .init(id: task.id, title: task.title,
                             detail: parts.joined(separator: " \u{00B7} "),
                             isClaimed: task.status == .inProgress)
            }
    }

    // MARK: Formatters

    // GL-P3: built once.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}
