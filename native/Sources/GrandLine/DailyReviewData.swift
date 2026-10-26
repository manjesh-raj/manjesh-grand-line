// Grand Line - native macOS app.
//
// F20 (full review #3 §8): the daily review's digest - what is due today and
// who is waiting on the captain, composed from their own local records.
//
// It began as the body of a whole card on a page of its own, with a calendar
// column, the sticky board and the reading list beside the tasks. That page
// and its calendar integration were removed
// (`fm/grandline-remove-today-calendar-1792553365`), and what is left is the
// half the Home page's Needs Attention card reads: due tasks, pending
// follow-ups, and the stated gap when either could not be read.
// `NeedsAttentionData.swift`'s header says why that card composes from this
// digest rather than re-reading the stores.
//
// The conventions it keeps:
//
//   - **A pure composer, and a card that only renders.** No store, no window
//     and no clock lives here, so the numbers can be pinned by a suite.
//   - **One reading of "due" and "overdue".** `ShiftDateFormatting` resolves
//     a Shift date, and `ShiftDue.isOverdue` decides lateness (B22), the same
//     two every other surface uses.
//   - **No AI call.** This is an aggregation of the captain's own records,
//     cheap enough to recompute on every render.
//
// ## GL-14, which is the point of the feature
//
// Every section is a `DailyReviewAvailability`, never a plain array. "Nothing
// is due" and "your tasks could not be read" are different states, and an
// unavailable section becomes a `DailyReviewGap` with its reason stated rather
// than an empty list that reads as an all-clear.
//
// ## Caps are stated, never silent
//
// Each section holds a handful of rows. An overflow is reported as a count
// (`hiddenDueTaskCount`) and rendered as "+3 more in Tasks", the same rule
// `HomeCanvasController.fillBriefing` already follows for the clause list.

import Foundation

// MARK: - Availability

/// One section's worth of input: either the data, or the reason there is
/// none. There is deliberately no third "empty" case - an empty array is
/// `available([])`, and the card says "nothing due today" for it, which is a
/// different sentence from "we could not read your tasks".
enum DailyReviewAvailability<Value: Equatable>: Equatable {
    case available(Value)
    /// Short, captain-facing, and always a reason rather than a status word.
    case unavailable(String)

    /// The rows to render, or `nil` when the section could not be read.
    var value: Value? {
        switch self {
        case .available(let value): return value
        case .unavailable: return nil
        }
    }

    /// Why the section could not be read, or `nil` when it could.
    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - The rendered rows

/// One task due today (or before it). Already formatted: the composer owns
/// every word the card paints, so the card has no date maths in it and the
/// suite can assert the strings.
struct DailyReviewTaskRow: Equatable {
    let id: String
    let title: String
    /// "RaaS Migration \u{00B7} High", or just the priority when the task has
    /// no project.
    let meta: String
    let isOverdue: Bool
    /// Whole days between the due day and today, and `0` when the row is not
    /// overdue.
    ///
    /// Carried on the row rather than re-derived by a reader, so the Needs
    /// Attention card's "Overdue 5 days, since 16 Sep" does no date maths of
    /// its own. A second reader doing that would be a second definition of
    /// overdue, which is exactly what B22 spent a task collapsing into
    /// `ShiftDue.isOverdue`.
    let overdueDays: Int
    /// "16 Sep" - the due day on its own, for a reader that wants to put it
    /// in a different sentence.
    let dueDayText: String
}

/// One pending follow-up due today or earlier.
struct DailyReviewFollowUpRow: Equatable {
    let id: String
    let title: String
    /// "today 3:00 PM", "Wed", "overdue since 16 Sep".
    let whenText: String
    let isOverdue: Bool
    /// See `DailyReviewTaskRow.overdueDays`.
    let overdueDays: Int
    /// See `DailyReviewTaskRow.dueDayText`.
    let dueDayText: String
}

/// One stated gap: which section could not be read, and why.
struct DailyReviewGap: Equatable {
    let section: String
    let reason: String
}

// MARK: - The inputs

/// Everything the composer is allowed to know, one section at a time. The
/// caller (`HomeCanvasController.renderAttention`) does the reading; this
/// struct is the boundary that makes the composing testable with no store
/// and no window.
struct DailyReviewInputs: Equatable {
    var now: Date = Date()
    /// Active tasks - the store's own in-memory list, not a re-read.
    var tasks: DailyReviewAvailability<[ShiftTask]> = .available([])
    var followUps: DailyReviewAvailability<[ShiftFollowUp]> = .available([])
    /// Project id -> display name, for a task row's meta line. A missing id
    /// simply drops the project from the line; it never renders a raw id.
    var projectNames: [String: String] = [:]
}

// MARK: - The digest

/// One composed digest. Everything the Needs Attention card reads from it,
/// and nothing else - the card holds no store, no date formatter and no
/// branching on "was this section available", because all of that is
/// resolved here.
struct DailyReviewDigest: Equatable {
    var dueTasks: [DailyReviewTaskRow]
    var hiddenDueTaskCount: Int
    var followUps: [DailyReviewFollowUpRow]
    var hiddenFollowUpCount: Int
    var gaps: [DailyReviewGap]
}

// MARK: - The composer

/// The pure half of F20. No store and no `NSView` - hand it
/// `DailyReviewInputs` and it returns exactly what the card paints.
enum DailyReviewComposer {

    /// How many rows a section carries before the overflow line. Small on
    /// purpose: this is a glance. An overflow is *stated*, never dropped.
    static let maxDueTasks = 5
    static let maxFollowUps = 3

    /// R2-PERF-06: the first moment after `inputs.now` at which the digest of
    /// these same inputs could read differently - an open item due today
    /// turning overdue, or the day ending (which moves "due today" and every
    /// "N days late"). Until then the same inputs compose the same digest, so
    /// a caller may keep the one it has.
    static func nextChange(for inputs: DailyReviewInputs) -> Date {
        let now = inputs.now
        var next = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        func consider(_ date: String?, _ time: String?) {
            guard let at = ShiftDue.overdueInstant(date: date, time: time), at > now, at < next else { return }
            next = at
        }
        for task in inputs.tasks.value ?? [] where task.status == .todo || task.status == .inProgress {
            consider(task.dueDate, task.dueTime)
        }
        for item in inputs.followUps.value ?? [] where item.status == .pending {
            consider(item.followUpAt, item.followUpTime)
        }
        return next
    }

    static func digest(from inputs: DailyReviewInputs) -> DailyReviewDigest {
        let now = inputs.now
        let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)

        var gaps: [DailyReviewGap] = []

        // MARK: Tasks

        var dueTasks: [DailyReviewTaskRow] = []
        var hiddenDueTasks = 0
        if let tasks = inputs.tasks.value {
            // Due today or earlier, and still open. `ShiftDateFormatting` is
            // the app's one reading of a Shift due date - deliberately the
            // same one `MorningBriefing.shiftDue` and
            // `ShiftNotificationScheduler.poll` use, rather than a second
            // definition of "due".
            var due: [(task: ShiftTask, at: Date)] = []
            for task in tasks {
                guard task.status == .todo || task.status == .inProgress else { continue }
                guard let at = ShiftDateFormatting.dateTime(from: task.dueDate, time: task.dueTime) else { continue }
                guard at < endOfToday else { continue }
                due.append((task, at))
            }
            due.sort { $0.at < $1.at }
            // B22: one definition of overdue, shared with the task list, the
            // notifier and the crew's context - `at < startOfToday` was time
            // blind, so a task due at 09:00 today still read as "due" at 17:00.
            func taskIsOverdue(_ task: ShiftTask) -> Bool {
                ShiftDue.isOverdue(date: task.dueDate, time: task.dueTime, now: now)
            }
            for entry in due.prefix(maxDueTasks) {
                let isOverdue = taskIsOverdue(entry.task)
                dueTasks.append(DailyReviewTaskRow(
                    id: entry.task.id,
                    title: entry.task.title,
                    meta: taskMeta(entry.task, projectNames: inputs.projectNames),
                    isOverdue: isOverdue,
                    overdueDays: isOverdue ? daysLate(entry.at, now: now) : 0,
                    dueDayText: dayMonth(entry.at)))
            }
            hiddenDueTasks = max(0, due.count - dueTasks.count)
        } else if let reason = inputs.tasks.unavailableReason {
            gaps.append(DailyReviewGap(section: "Tasks", reason: reason))
        }

        // MARK: Follow-ups

        var followUps: [DailyReviewFollowUpRow] = []
        var hiddenFollowUps = 0
        if let all = inputs.followUps.value {
            var pending: [(item: ShiftFollowUp, at: Date)] = []
            for item in all where item.status == .pending {
                guard let at = ShiftDateFormatting.dateTime(from: item.followUpAt, time: item.followUpTime) else { continue }
                guard at < endOfToday else { continue }
                pending.append((item, at))
            }
            pending.sort { $0.at < $1.at }
            func followUpIsOverdue(_ item: ShiftFollowUp) -> Bool {
                ShiftDue.isOverdue(date: item.followUpAt, time: item.followUpTime, now: now)
            }
            for entry in pending.prefix(maxFollowUps) {
                let isOverdue = followUpIsOverdue(entry.item)
                followUps.append(DailyReviewFollowUpRow(
                    id: entry.item.id,
                    title: entry.item.title,
                    whenText: isOverdue ? "overdue since \(dayMonth(entry.at))" : todayTime(entry.at, hasTime: entry.item.followUpTime != nil),
                    isOverdue: isOverdue,
                    overdueDays: isOverdue ? daysLate(entry.at, now: now) : 0,
                    dueDayText: dayMonth(entry.at)))
            }
            hiddenFollowUps = max(0, pending.count - followUps.count)
        } else if let reason = inputs.followUps.unavailableReason {
            gaps.append(DailyReviewGap(section: "Follow-ups", reason: reason))
        }

        return DailyReviewDigest(
            dueTasks: dueTasks,
            hiddenDueTaskCount: hiddenDueTasks,
            followUps: followUps,
            hiddenFollowUpCount: hiddenFollowUps,
            gaps: gaps)
    }

    // MARK: Number words

    /// "Nothing", "one", ... "ten", then digits. Small numbers read as words
    /// in a sentence ("Two things are late."); a count of 23 does not. The
    /// Needs Attention card's sentence reads this table rather than keeping
    /// a second one.
    static func spelled(_ n: Int) -> String {
        let words = ["nothing", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }

    static func spelledCapitalised(_ n: Int) -> String {
        let word = spelled(n)
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }

    // MARK: Formatting

    /// "16 Sep".
    static func dayMonth(_ date: Date) -> String { dayMonthFormatter.string(from: date) }

    /// Whole days between the day something was due and today, floored at
    /// zero.
    ///
    /// Days rather than elapsed hours, because that is the unit the captain
    /// reads lateness in: a task due at 17:00 yesterday is "overdue 1 day" at
    /// 09:00 this morning, not "overdue 16 hours". `Calendar.current`
    /// deliberately, for the same reason `ShiftDateFormatting` resolves a bare
    /// day string to *local* midnight - "due today" means today where the
    /// captain is.
    static func daysLate(_ due: Date, now: Date) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: due),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, days)
    }

    /// A follow-up due today: "today 3:00 PM" when it carries a time, plain
    /// "today" when it does not - rather than inventing a midnight.
    static func todayTime(_ date: Date, hasTime: Bool) -> String {
        hasTime ? "today \(timeFormatter.string(from: date))" : "today"
    }

    /// "RaaS Migration \u{00B7} High", "High", or "" - never a raw project id.
    static func taskMeta(_ task: ShiftTask, projectNames: [String: String]) -> String {
        let priority = task.priority.rawValue.prefix(1).uppercased() + task.priority.rawValue.dropFirst()
        guard let id = task.projectID, let name = projectNames[id], !name.isEmpty else {
            return priority
        }
        return "\(name) \u{00B7} \(priority)"
    }

    // GL-P3: built once. `DateFormatter` construction is measurably expensive
    // and none of these carries per-call state.
    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()
}

// MARK: - Habits: deliberately absent
//
// **UX issue X7 of the 2026-09-27 review.** This file used to carry a habits
// source that always answered "unavailable", a habit-row shape nothing ever
// produced, and a habits section in the digest - so every daily review,
// every day, rendered a warning-styled line under its "Not available" block
// saying that habit streaks were not part of this build.
//
// (The removed symbols are deliberately not named here. `DailyReviewSelfTest.
// checkNoHabitsSection` scans this app's sources for them, and a comment
// that spelled them out would be indistinguishable from the code coming
// back.)
//
// GL-14's stated-gap rule is about a section this app *can* read and did
// not (a task store that failed to parse, a scan that failed). A
// feature that was never built is not a gap in today's data; it is an
// advertisement for something that does not exist, and repeating it daily
// under a warning icon trains the captain to ignore the block that exists
// to be trusted.
//
// The habit tracker itself is still a good idea and is §7.2 of the same
// review. When it ships it reintroduces its own row, its own source and its
// own tests deliberately - which is cheaper than carrying a placeholder that
// has to be kept compiling in the meantime.

