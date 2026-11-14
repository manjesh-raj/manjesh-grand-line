// Grand Line - native macOS app.
//
// One definition of "overdue", shared by every subsystem that renders or
// signals it.
//
// B22: there were two. `ShiftTaskRow` called a task overdue only once the day
// *after* its due day had started (`due < startOfDay(now)`), which is how a
// to-do list reads; `ShiftNotifications` called it overdue the instant its due
// moment passed, and a date-only task's due moment resolves to **local
// midnight** - so a task due today fired a "Task due now" banner at 00:00 and
// counted as overdue in the Notification Center all day, while the task list
// beside it still showed the task as simply due today.
//
// The list's rule is the one a captain means, so it is the one here.

import Foundation

enum ShiftDue {

    /// The moment a date-only item stops being "due today" and starts being
    /// overdue: the start of the day *after* its due day.
    ///
    /// A timed item's is its own due moment, because "3pm" that has passed is
    /// past whatever the day is.
    static func overdueInstant(date yyyyMMdd: String?,
                               time hhmm: String?,
                               calendar: Calendar = .current) -> Date? {
        guard let yyyyMMdd, let day = ShiftDateFormatting.date(from: yyyyMMdd) else { return nil }
        if hhmm != nil, let exact = ShiftDateFormatting.dateTime(from: yyyyMMdd, time: hhmm) {
            return exact
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
    }

    /// The app's one answer to "is this past due?".
    ///
    /// `ShiftDateFormatting.date(from:)` resolves a bare `"YYYY-MM-DD"` in the
    /// **local** calendar, which is the whole reason this cannot be a UTC
    /// comparison - "due today" means today where the captain is (AGENTS.md's
    /// `"YYYY-MM-DD"` fixture rule).
    static func isOverdue(date yyyyMMdd: String?,
                          time hhmm: String?,
                          now: Date,
                          calendar: Calendar = .current) -> Bool {
        guard let instant = overdueInstant(date: yyyyMMdd, time: hhmm, calendar: calendar) else {
            return false
        }
        return instant <= now
    }

    /// The time of day a date-only item is reminded about when
    /// `settings.yaml` does not say (`ShiftSettings.allDayReminderAt`).
    static let defaultAllDayReminderAt = "09:00"

    /// The moment a reminder is *about*: the item's own time, or for a
    /// date-only item `allDayAt` on its day.
    ///
    /// Deliberately **not** `overdueInstant`: a task due today should be
    /// reminded about in the morning, not at 23:59. It used to be the start
    /// of the day, which with the poll's 30-minute lookahead posted "Task
    /// due today" at 23:30 on the evening *before* - so a task due Friday
    /// reminded on Thursday night. `allDayAt` is what fixes that, and it
    /// falls back to `defaultAllDayReminderAt` for a value that is not a
    /// real `HH:MM` rather than to midnight.
    static func reminderInstant(date yyyyMMdd: String?,
                                time hhmm: String?,
                                allDayAt: String = defaultAllDayReminderAt) -> Date? {
        if hhmm != nil { return ShiftDateFormatting.dateTime(from: yyyyMMdd, time: hhmm) }
        return ShiftDateFormatting.dateTime(from: yyyyMMdd,
                                            time: clockTime(allDayAt) ?? defaultAllDayReminderAt)
    }

    /// When the reminder for an item **fires**: `reminderInstant` less the
    /// item's own "remind me N minutes before", or less `defaultLookahead`
    /// when it has none.
    ///
    /// The one rule for tasks, follow-ups and the next date of a missed
    /// repeat, so the three cannot drift apart. Two details:
    ///
    ///   - `0` is a real offset ("at the due time") and is not the same as
    ///     `nil`, which is why the optional is unwrapped rather than
    ///     defaulted.
    ///   - A **date-only** item with no offset takes no lookahead. Its
    ///     reminder moment is already a time the captain chose for "the
    ///     day"; firing half an hour before it would just make 09:00 read
    ///     as 08:30. An explicit offset still applies, so "1 day before" is
    ///     that time on the day before.
    static func reminderFireInstant(date yyyyMMdd: String?,
                                    time hhmm: String?,
                                    minutesBefore: Int?,
                                    allDayAt: String = defaultAllDayReminderAt,
                                    defaultLookahead: TimeInterval) -> Date? {
        guard let anchor = reminderInstant(date: yyyyMMdd, time: hhmm, allDayAt: allDayAt) else {
            return nil
        }
        let lead: TimeInterval
        if let minutesBefore {
            lead = TimeInterval(max(0, minutesBefore) * 60)
        } else {
            lead = hhmm == nil ? 0 : defaultLookahead
        }
        return anchor.addingTimeInterval(-lead)
    }

    /// `text` as a 24-hour `"HH:MM"`, or `nil` when it is not one. A
    /// one-digit hour is accepted and padded, because `9:00` is what a person
    /// types into `settings.yaml` by hand.
    static func clockTime(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// The banner's own title for a task, given both instants above.
    static func taskTitle(date yyyyMMdd: String?, time hhmm: String?, now: Date,
                          calendar: Calendar = .current) -> String {
        if isOverdue(date: yyyyMMdd, time: hhmm, now: now, calendar: calendar) { return "Task due now" }
        return hhmm == nil ? "Task due today" : "Task due soon"
    }

    /// The same for a follow-up, whose vocabulary the app already differs on.
    static func followUpTitle(date yyyyMMdd: String?, time hhmm: String?, now: Date,
                              calendar: Calendar = .current) -> String {
        if isOverdue(date: yyyyMMdd, time: hhmm, now: now, calendar: calendar) { return "Follow-up due now" }
        return hhmm == nil ? "Follow-up due today" : "Follow-up coming up"
    }
}

// MARK: - How a task's priority and due date are shown

/// The Tasks page's **one** rule for what a task's priority and due date look
/// like on a card or a row (the UI/UX revamp's UI-23, UI-24 and UI-32).
///
/// There were four priority-to-colour maps (the board card, the list row,
/// the follow-up row, the project detail), and they disagreed: the board put
/// a "Normal" chip on every card, and the bar colour meant priority in the
/// list but project on the board. This is the one answer:
///
///   - **Priority is an exception, not a field.** High is a red pill, Low is
///     muted text, Normal says nothing - a chip on every card is wallpaper
///     (Q3, the captain's call).
///   - **A due date is a caption** that takes colour only when it matters:
///     amber when it is today, red when it is late, muted otherwise. The
///     same rule on the board, in the list and on a follow-up.
enum ShiftTaskSignals {

    /// The chip a priority earns, or `nil` for Normal (Q3: a chip only for
    /// High and Low). High is red because it is the signal; Low is neutral,
    /// because it says "this can wait" rather than "look here".
    static func priorityPill(_ priority: ShiftPriority) -> (text: String, tint: HelmTint)? {
        switch priority {
        case .high: return ("High", .critical)
        case .low: return ("Low", .neutral)
        default: return nil
        }
    }

    struct DueCaption: Equatable {
        let text: String
        /// `nil` = muted.
        let tint: HelmTint?
    }

    /// "Overdue 3 days" (red), "Due today" (amber), or the friendly date
    /// (muted). `nil` for no date.
    static func dueCaption(date yyyyMMdd: String?, time hhmm: String?, now: Date = Date(),
                           calendar: Calendar = .current) -> DueCaption? {
        guard let yyyyMMdd, let day = ShiftDateFormatting.date(from: yyyyMMdd) else { return nil }
        if ShiftDue.isOverdue(date: yyyyMMdd, time: hhmm, now: now, calendar: calendar) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            let text = days <= 0 ? "Overdue" : "Overdue \(days) \(days == 1 ? "day" : "days")"
            return DueCaption(text: text, tint: .critical)
        }
        if calendar.isDate(day, inSameDayAs: now) { return DueCaption(text: "Due today", tint: .warn) }
        return DueCaption(text: ShiftDateFormatting.friendly(yyyyMMdd), tint: nil)
    }
}
