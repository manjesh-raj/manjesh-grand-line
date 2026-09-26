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

    /// When a reminder for this item should be considered "reached".
    ///
    /// Deliberately **not** `overdueInstant`: a task due today should be
    /// reminded about in the morning, not at 23:59. So a date-only item's
    /// reminder moment is the start of its day and its *overdue* moment is the
    /// end of it - which is exactly the gap the banner's wording has to
    /// respect rather than collapse (B22).
    static func reminderInstant(date yyyyMMdd: String?,
                                time hhmm: String?) -> Date? {
        ShiftDateFormatting.dateTime(from: yyyyMMdd, time: hhmm)
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
