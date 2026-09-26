// Grand Line - native macOS app.
//
// F20 (full review #3 §8): the daily review - a *general-user* briefing, next
// to F12's fleet-shaped Morning Briefing on Overview.
//
// ## Why this is a second briefing and not a change to the first one
//
// F12's briefing answers "what does the fleet need from me": crew tasks, the
// PR queue, fork drift, tool updates, the Claude quota. Every one of those is
// a supervision signal, and none of them is about the captain's own day. The
// report's F20 entry names the other half - tasks due, follow-ups, habits, the
// calendar, the reading list, the top stickies - and they share nothing but
// the shape of the card.
//
// So this file deliberately reuses F12's *conventions* and none of its data:
//
//   - the same "one persisted record per day, dismissible, regenerated on the
//     day key changing" lifecycle (`MorningBriefing.dayKey` is reused rather
//     than re-derived, so the two cards agree on when the day turns over);
//   - the same "a pure composer plus a card that only renders" split, so the
//     numbers can be pinned by a suite with no window;
//   - the same GL-14 discipline, made louder here because this feature reads
//     six sources and three of them can legitimately be absent.
//
// And it deliberately does *not* reuse the AI layer. There is no `claude -p`
// call here at all: this card is an aggregation of the captain's own local
// records, it is cheap enough to recompute on every appearance, and the
// mockup's own footer ("Generated locally at 08:30 - no data left this Mac")
// is a promise that only holds if nothing leaves.
//
// ## GL-14, which is the point of the feature
//
// Every section is a `DailyReviewAvailability`, never a plain array. "No
// habits are tracked" and "the habits feature has not shipped" are different
// states, and so are "nothing is on your calendar" and "we were never given
// permission to look". An unavailable section becomes a line in the card's own
// "Not available" block with its reason stated - the mockup draws that block,
// and the artifact's own note calls it the whole point: a briefing that
// quietly drops the section it could not read teaches you to distrust the
// whole card.
//
// ## Caps are stated, never silent
//
// Each column holds a handful of rows. An overflow is reported as a count
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
    /// Some of the data **and** a stated gap: one source answered and another
    /// could not be read.
    ///
    /// B16: before this case existed, `CompositeDailyReviewCalendar` said that
    /// by appending the reason as a **fake event row** - an untitled, timeless
    /// entry carrying the gap text as its title. The composer then counted it
    /// toward `maxEvents`, so a busy day truncated the gap away entirely and
    /// reported "+3 more" when two of them were real. A gap is not a row; it
    /// travels beside the value, and the composer files it under `gaps` where
    /// every other stated gap already goes.
    case partial(Value, reason: String)

    /// The rows to render - which a partial answer very much has.
    var value: Value? {
        switch self {
        case .available(let value), .partial(let value, _): return value
        case .unavailable: return nil
        }
    }

    /// Set only when there is *nothing* to show. A partial answer renders its
    /// rows, so it is not unavailable.
    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// The gap stated alongside a value that was rendered anyway.
    var partialReason: String? {
        if case .partial(_, let reason) = self { return reason }
        return nil
    }

    /// Either shape of stated gap, for a caller that only wants to say so.
    var gapReason: String? { unavailableReason ?? partialReason }
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
    /// "overdue since 16 Sep", only when `isOverdue`.
    let overdueText: String?
}

/// One pending follow-up due today or earlier.
struct DailyReviewFollowUpRow: Equatable {
    let id: String
    let title: String
    /// "today 3:00 PM", "Wed", "overdue since 16 Sep".
    let whenText: String
    let isOverdue: Bool
}

/// One of today's calendar events. Read-only, and deliberately carries only
/// what the card paints - there is no `EKEvent` here, so nothing downstream
/// can reach back into EventKit through a row.
struct DailyReviewEventRow: Equatable {
    let title: String
    /// "10:00", or "all day".
    ///
    /// Display only. **Never sort on it** - it is localised, so "1:00 PM"
    /// sorts before "9:00 AM" and a merged two-source column came out in an
    /// order nobody could explain (B16). `startsAt` is the sort key.
    let timeText: String
    /// "6 attendees \u{00B7} Meet", or the location, or empty.
    let detail: String
    /// The calendar's own colour, as a hex string - the one place a row's
    /// colour comes from outside the theme, because a calendar's colour is
    /// the captain's own identity for it. `nil` when the calendar has none,
    /// and the card falls back to a theme tint.
    let colorHex: String?
    let isAllDay: Bool
    /// When the event starts, for ordering. Optional because a source may not
    /// know (and because an all-day row has no meaningful time), and a row
    /// with none sorts after the rows that do rather than to the top.
    let startsAt: Date?

    init(title: String,
         timeText: String,
         detail: String,
         colorHex: String?,
         isAllDay: Bool,
         startsAt: Date? = nil) {
        self.title = title
        self.timeText = timeText
        self.detail = detail
        self.colorHex = colorHex
        self.isAllDay = isAllDay
        self.startsAt = startsAt
    }

    /// All-day first, then by real start time, then by title so the order is
    /// total and a merge is reproducible.
    static func isOrderedBefore(_ lhs: DailyReviewEventRow, _ rhs: DailyReviewEventRow) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        switch (lhs.startsAt, rhs.startsAt) {
        case (let l?, let r?) where l != r: return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.title < rhs.title
        }
    }
}

/// One habit, for the day F8 lands. Defined here rather than waiting for it,
/// so the section is a real shape rather than a placeholder - see
/// `DailyReviewHabits`.
struct DailyReviewHabitRow: Equatable {
    let title: String
    let doneToday: Bool
    /// The current streak, when the source knows one.
    let streak: Int?
}

/// One sticky note worth naming.
struct DailyReviewStickyRow: Equatable {
    let id: String
    let title: String
    /// "up for 3 days", or "2 of 4 done" for a checklist.
    let detail: String
}

/// The reading list, as one line rather than a list - the mockup's own shape
/// ("11 unread \u{00B7} oldest saved 2 weeks ago", then one title).
struct DailyReviewReadingSummary: Equatable {
    let unreadCount: Int
    /// "oldest saved 2 weeks ago", empty when nothing is unread.
    let oldestText: String
    /// The oldest unread link's title, which is the one most likely to be
    /// rotting.
    let topTitle: String?
}

/// One line of the "Not available" block: which section, and why.
struct DailyReviewGap: Equatable {
    let section: String
    let reason: String
}

// MARK: - The inputs

/// Everything the composer is allowed to know, one section at a time. The
/// caller (`FleetController`) does the reading; this struct is the boundary
/// that makes the composing testable with no store, no window and no EventKit.
struct DailyReviewInputs: Equatable {
    var now: Date = Date()
    /// Active tasks - the store's own in-memory list, not a re-read.
    var tasks: DailyReviewAvailability<[ShiftTask]> = .available([])
    var followUps: DailyReviewAvailability<[ShiftFollowUp]> = .available([])
    /// Project id -> display name, for a task row's meta line. A missing id
    /// simply drops the project from the line; it never renders a raw id.
    var projectNames: [String: String] = [:]
    var calendar: DailyReviewAvailability<[DailyReviewEventRow]> = .available([])
    var habits: DailyReviewAvailability<[DailyReviewHabitRow]> = .available([])
    var reading: DailyReviewAvailability<[ReadingLink]> = .available([])
    var stickies: DailyReviewAvailability<[StickyNote]> = .available([])
}

// MARK: - The digest

/// One composed daily review. Everything the card paints, and nothing else -
/// the card holds no store, no date formatter and no branching on "was this
/// section available", because all of that is resolved here.
struct DailyReviewDigest: Equatable {
    /// `"yyyy-MM-dd"`, from `MorningBriefing.dayKey` - the same day key F12
    /// uses, so the two cards turn over together.
    var day: String
    var generatedAt: Date
    /// "Monday 21 September \u{00B7} 08:30" - the card's kicker.
    var kicker: String
    /// "Two things are due, and one is already late." - one sentence, derived
    /// from the counts below and never from a model.
    var headline: String

    var dueTasks: [DailyReviewTaskRow]
    var hiddenDueTaskCount: Int
    var followUps: [DailyReviewFollowUpRow]
    var hiddenFollowUpCount: Int
    var events: [DailyReviewEventRow]
    var hiddenEventCount: Int
    var habits: [DailyReviewHabitRow]
    var stickies: [DailyReviewStickyRow]
    var reading: DailyReviewReadingSummary?
    var gaps: [DailyReviewGap]

    /// The task the footer's primary action offers to start on - the most
    /// urgent thing due, which is the oldest overdue task when there is one.
    /// `nil` leaves the footer with only "Plan the day in Tasks", rather than
    /// a button that starts on nothing.
    var primaryTaskID: String?
    var primaryTaskTitle: String?

    /// Whether the card has anything at all to say. A review with no rows and
    /// no gaps is a quiet day, and still renders (with its headline) rather
    /// than vanishing - but the caller may use this to decide ordering.
    var isEmpty: Bool {
        dueTasks.isEmpty && followUps.isEmpty && events.isEmpty
            && habits.isEmpty && stickies.isEmpty && reading == nil
    }
}

// MARK: - The composer

/// The pure half of F20. No store, no `EKEventStore`, no `NSView` - hand it
/// `DailyReviewInputs` and it returns exactly what the card paints.
enum DailyReviewComposer {

    /// How many rows a column carries before the overflow line. Small on
    /// purpose: this is a glance, and the mockup's three columns are each a
    /// few lines tall. An overflow is *stated*, never dropped.
    static let maxDueTasks = 5
    static let maxFollowUps = 3
    static let maxEvents = 4
    static let maxStickies = 3
    static let maxHabits = 5

    static func digest(from inputs: DailyReviewInputs) -> DailyReviewDigest {
        let now = inputs.now
        let calendar = Calendar.current
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        let startOfToday = calendar.startOfDay(for: now)

        var gaps: [DailyReviewGap] = []

        // MARK: Tasks

        var dueTasks: [DailyReviewTaskRow] = []
        var hiddenDueTasks = 0
        var totalDue = 0
        var overdueCount = 0
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
            overdueCount = due.filter { taskIsOverdue($0.task) }.count
            for entry in due.prefix(maxDueTasks) {
                let isOverdue = taskIsOverdue(entry.task)
                dueTasks.append(DailyReviewTaskRow(
                    id: entry.task.id,
                    title: entry.task.title,
                    meta: taskMeta(entry.task, projectNames: inputs.projectNames),
                    isOverdue: isOverdue,
                    overdueText: isOverdue ? "overdue since \(dayMonth(entry.at))" : nil))
            }
            totalDue = due.count
            hiddenDueTasks = max(0, due.count - dueTasks.count)
        } else if let reason = inputs.tasks.unavailableReason {
            gaps.append(DailyReviewGap(section: "Tasks", reason: reason))
        }

        return finish(inputs: inputs, now: now, startOfToday: startOfToday, endOfToday: endOfToday,
                      dueTasks: dueTasks, hiddenDueTaskCount: hiddenDueTasks,
                      totalDueTaskCount: totalDue, overdueCount: overdueCount,
                      gaps: &gaps)
    }

    /// The rest of the composition, once the task column is resolved. Split
    /// out only because the task column is the one section that also feeds
    /// the headline and the footer's primary action.
    private static func finish(inputs: DailyReviewInputs,
                               now: Date,
                               startOfToday: Date,
                               endOfToday: Date,
                               dueTasks: [DailyReviewTaskRow],
                               hiddenDueTaskCount: Int,
                               totalDueTaskCount: Int,
                               overdueCount: Int,
                               gaps: inout [DailyReviewGap]) -> DailyReviewDigest {

        // MARK: Follow-ups

        var followUps: [DailyReviewFollowUpRow] = []
        var hiddenFollowUps = 0
        // Counted across *everything* pending and late, not only the rows
        // that fit the column - the sentence at the top of the card is about
        // the day, not about what the card had room for.
        var overdueFollowUps = 0
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
            overdueFollowUps = pending.filter { followUpIsOverdue($0.item) }.count
            for entry in pending.prefix(maxFollowUps) {
                let isOverdue = followUpIsOverdue(entry.item)
                followUps.append(DailyReviewFollowUpRow(
                    id: entry.item.id,
                    title: entry.item.title,
                    whenText: isOverdue ? "overdue since \(dayMonth(entry.at))" : todayTime(entry.at, hasTime: entry.item.followUpTime != nil),
                    isOverdue: isOverdue))
            }
            hiddenFollowUps = max(0, pending.count - followUps.count)
        } else if let reason = inputs.followUps.unavailableReason {
            gaps.append(DailyReviewGap(section: "Follow-ups", reason: reason))
        }

        // MARK: Calendar

        var events: [DailyReviewEventRow] = []
        var hiddenEvents = 0
        if let all = inputs.calendar.value {
            events = Array(all.prefix(maxEvents))
            hiddenEvents = max(0, all.count - events.count)
        }
        // Either shape of gap, and a *partial* one is filed here rather than
        // smuggled into `events` as a row (B16).
        if let reason = inputs.calendar.gapReason {
            gaps.append(DailyReviewGap(section: "Calendar", reason: reason))
        }

        // MARK: Habits

        var habits: [DailyReviewHabitRow] = []
        if let all = inputs.habits.value {
            habits = Array(all.prefix(maxHabits))
        } else if let reason = inputs.habits.unavailableReason {
            gaps.append(DailyReviewGap(section: "Habits", reason: reason))
        }

        // MARK: Stickies

        var stickies: [DailyReviewStickyRow] = []
        if let notes = inputs.stickies.value {
            // Oldest first: a note that has been on the board longest is the
            // one the board has stopped saying anything about, which is the
            // one worth naming in a daily review. A checklist that is part
            // done outranks it, because it is work already started.
            let active = notes.filter { !$0.isArchived }
            let started = active.filter { note in
                guard let items = note.checklist, !items.isEmpty else { return false }
                return items.contains(where: { $0.isDone }) && items.contains(where: { !$0.isDone })
            }
            let rest = active.filter { note in !started.contains(where: { $0.id == note.id }) }
            let ordered = started.sorted { $0.createdAt < $1.createdAt }
                + rest.sorted { $0.createdAt < $1.createdAt }
            for note in ordered.prefix(maxStickies) {
                stickies.append(DailyReviewStickyRow(
                    id: note.id,
                    title: stickyTitle(note),
                    detail: stickyDetail(note, now: now)))
            }
        } else if let reason = inputs.stickies.unavailableReason {
            gaps.append(DailyReviewGap(section: "Sticky board", reason: reason))
        }

        // MARK: Reading list

        var reading: DailyReviewReadingSummary?
        if let links = inputs.reading.value {
            let unread = links.filter { !$0.isRead }
            let oldest = unread.min(by: { $0.addedAt < $1.addedAt })
            reading = DailyReviewReadingSummary(
                unreadCount: unread.count,
                oldestText: oldest.map { "oldest saved \(relativeAge(from: $0.addedAt, to: now))" } ?? "",
                topTitle: oldest?.displayTitle)
        } else if let reason = inputs.reading.unavailableReason {
            gaps.append(DailyReviewGap(section: "Reading list", reason: reason))
        }

        // MARK: The sentence, and the footer's action

        let dueTotal = totalDueTaskCount + followUps.count + hiddenFollowUps
        let headline = Self.headline(dueCount: dueTotal,
                                     overdueCount: overdueCount + overdueFollowUps,
                                     eventCount: events.count + hiddenEvents)

        // The oldest overdue task if there is one, otherwise the next thing
        // due. `dueTasks` is already sorted by when, so this is its head.
        let primary = dueTasks.first

        return DailyReviewDigest(
            day: MorningBriefing.dayKey(for: now),
            generatedAt: now,
            kicker: kicker(for: now),
            headline: headline,
            dueTasks: dueTasks,
            hiddenDueTaskCount: hiddenDueTaskCount,
            followUps: followUps,
            hiddenFollowUpCount: hiddenFollowUps,
            events: events,
            hiddenEventCount: hiddenEvents,
            habits: habits,
            stickies: stickies,
            reading: reading,
            gaps: gaps,
            primaryTaskID: primary?.id,
            primaryTaskTitle: primary?.title)
    }

    // MARK: The sentence

    /// The one sentence at the top of the card. Deterministic, derived from
    /// three counts, and written in words rather than digits for small
    /// numbers because it is prose - the mockup's own "Two things are due, and
    /// one is already late."
    static func headline(dueCount: Int, overdueCount: Int, eventCount: Int) -> String {
        if dueCount == 0 && eventCount == 0 {
            return "Nothing is due today."
        }
        if dueCount == 0 {
            return "Nothing is due - \(spelled(eventCount)) \(plural(eventCount, "event")) on your calendar."
        }
        let due = "\(spelledCapitalised(dueCount)) \(plural(dueCount, "thing")) \(dueCount == 1 ? "is" : "are") due"
        if overdueCount > 0 {
            return "\(due), and \(spelled(overdueCount)) \(overdueCount == 1 ? "is" : "are") already late."
        }
        if eventCount > 0 {
            return "\(due), and \(spelled(eventCount)) \(plural(eventCount, "event")) \(eventCount == 1 ? "is" : "are") on your calendar."
        }
        return "\(due) today."
    }

    /// "Nothing", "one", ... "ten", then digits. Small numbers read as words
    /// in a sentence; a count of 23 does not.
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

    /// "Monday 21 September \u{00B7} 08:30".
    static func kicker(for date: Date) -> String {
        "\(kickerDateFormatter.string(from: date)) \u{00B7} \(timeFormatter.string(from: date))"
    }

    /// "16 Sep".
    static func dayMonth(_ date: Date) -> String { dayMonthFormatter.string(from: date) }

    /// A follow-up due today: "today 3:00 PM" when it carries a time, plain
    /// "today" when it does not - rather than inventing a midnight.
    static func todayTime(_ date: Date, hasTime: Bool) -> String {
        hasTime ? "today \(timeFormatter.string(from: date))" : "today"
    }

    /// "2 weeks ago", "3 days ago", "today". Whole units only: a reading list
    /// is a glance, and "13 days, 4 hours" is not one.
    static func relativeAge(from date: Date, to now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2...13: return "\(days) days ago"
        case 14...60: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }

    /// "RaaS Migration \u{00B7} High", "High", or "" - never a raw project id.
    static func taskMeta(_ task: ShiftTask, projectNames: [String: String]) -> String {
        let priority = task.priority.rawValue.prefix(1).uppercased() + task.priority.rawValue.dropFirst()
        guard let id = task.projectID, let name = projectNames[id], !name.isEmpty else {
            return priority
        }
        return "\(name) \u{00B7} \(priority)"
    }

    /// A sticky's own title, or its first line of text when it has none - the
    /// same fallback the board itself draws.
    static func stickyTitle(_ note: StickyNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let firstLine = note.text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }

    /// "2 of 4 done" for a checklist, "up for 3 days" otherwise.
    static func stickyDetail(_ note: StickyNote, now: Date) -> String {
        if let items = note.checklist, !items.isEmpty {
            let done = items.filter { $0.isDone }.count
            return "\(done) of \(items.count) done"
        }
        let days = Calendar.current.dateComponents([.day], from: note.createdAt, to: now).day ?? 0
        switch days {
        case ..<1: return "added today"
        case 1: return "up for a day"
        default: return "up for \(days) days"
        }
    }

    // GL-P3: built once. `DateFormatter` construction is measurably expensive
    // and none of these carries per-call state.
    private static let kickerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

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

// MARK: - Habits (F8 has not shipped)

/// The habits section, as it stands today.
///
/// F8 ("habits and streaks, on the Tasks sidebar") is in the same §8 list this
/// feature came from and has not been built. The honest rendering of that is
/// **not** an empty section and **not** a hidden one: it is a stated gap, the
/// same treatment a calendar this app was never given permission to read gets.
///
/// When F8 lands, this is the one function to change: return
/// `.available(rows)` from whatever store it introduces, and the card, the
/// composer and both suites already handle it - `DailyReviewSelfTest` asserts
/// the available path with fabricated rows for exactly that reason.
enum DailyReviewHabits {
    /// Stated in the captain's terms, not the backlog's: "F8 has not shipped"
    /// means nothing to someone reading a briefing.
    static let notTrackedReason = "no habits are tracked yet - habit streaks aren\u{2019}t part of this build"

    static func read() -> DailyReviewAvailability<[DailyReviewHabitRow]> {
        .unavailable(notTrackedReason)
    }
}
