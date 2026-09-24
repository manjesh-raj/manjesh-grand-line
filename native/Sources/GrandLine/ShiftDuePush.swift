// Grand Line - native macOS app.
//
// `ShiftDuePush` - the "Push to → Tomorrow / Next week" reschedule gesture.
//
// Review #3's UX7: "Board, List, and the sidebar's Due today/Overdue - but a
// task with a due date is never shown on a *time* axis, and there is no
// recurring task, no reminder before due, no 'reschedule to next Monday'
// gesture on a card." The calendar view, recurrence and reminders are that
// finding's own F5 (a separate, larger build); this is the short-term slice it
// names, and it is the half a captain reaches for daily - pushing something
// out is what you do to a list of things due today when the day gets away from
// you.
//
// Pure date arithmetic with an injectable `today`, deliberately separated from
// both menus that offer it and from the store that persists it. That is what
// lets `ShiftDuePushSelfTest` assert the two cases that actually bite - a
// task with no due date, and a push that crosses a month or year boundary -
// without a window, a store or a clock.

import Foundation

/// How far out to push a task's due date.
enum ShiftDuePush: String, CaseIterable {
    case tomorrow
    case nextWeek

    /// What the menu item says.
    var menuTitle: String {
        switch self {
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    /// Days added to the base date.
    private var days: Int {
        switch self {
        case .tomorrow: return 1
        case .nextWeek: return 7
        }
    }

    /// The task's new `dueDate`, in the `"yyyy-MM-dd"` shape `ShiftTask`
    /// persists, or `nil` if the arithmetic cannot be done.
    ///
    /// **The base is the later of the task's own due date and today**, and
    /// that choice is the whole design of this gesture:
    ///
    ///   - A task due *tomorrow* pushed to "Tomorrow" should move to the day
    ///     after, not stay where it is. Basing off the due date gives that.
    ///   - A task that was due *last Tuesday* pushed to "Tomorrow" should land
    ///     tomorrow, not the Wednesday that has already gone. Basing off today
    ///     gives that.
    ///
    /// Taking the later of the two is the one rule that satisfies both, and it
    /// is why this is not a one-line `date(byAdding:)` at the call site. An
    /// overdue task is the *most* common thing to push, so getting that
    /// direction wrong would make the gesture useless exactly when it is
    /// wanted.
    ///
    /// A task with no due date at all is scheduled from today, which turns
    /// this into "give this a date" - a reasonable reading of "push to
    /// tomorrow" on something undated, and better than silently doing nothing.
    func newDueDate(currentDueDate: String?, today: Date = Date(),
                    calendar: Calendar = .current) -> String? {
        let todayStart = calendar.startOfDay(for: today)
        let current = currentDueDate.flatMap(ShiftDateFormatting.date(from:))
        let base = max(current.map { calendar.startOfDay(for: $0) } ?? todayStart, todayStart)
        guard let pushed = calendar.date(byAdding: .day, value: days, to: base) else { return nil }
        return ShiftDuePush.isoString(pushed, calendar: calendar)
    }

    /// The `"yyyy-MM-dd"` shape `ShiftTask.dueDate` is persisted in.
    ///
    /// Built from date *components* rather than a `DateFormatter` with a
    /// locale: this string is a storage format, and a formatter that picked up
    /// a non-Gregorian calendar or a localised numbering system would write a
    /// due date the reader cannot parse back. `ShiftDateFormatting.date(from:)`
    /// pins a Gregorian calendar for exactly this reason.
    static func isoString(_ date: Date, calendar: Calendar = .current) -> String? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
