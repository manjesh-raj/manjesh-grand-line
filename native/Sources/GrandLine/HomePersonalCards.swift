// Grand Line - native macOS app.
//
// R5-UX-07 of review #5: Home should start with what a person can act on.
// The Personal profile's default cards are Today's tasks, Calendar next-up,
// Recent notes, Sticky board, Reading list unread and Focus timer. Four of
// those were already cards; this file is what the other two say.
//
// Pure, so a suite can state every case without a window or a store: the
// canvas hands over the records it already holds and draws what comes back
// (`HomeCanvasController.fillCalendar` / `fillFocusTimer`).

import Foundation

/// The Calendar card: what is coming up next, from the same entries the
/// calendar itself draws (`ShiftCalendarModel.entries`), so the card and the
/// grid cannot disagree about what is on a day.
enum HomeNextUpCard {

    struct Row: Equatable {
        let title: String
        /// "Today 15:00", "Tomorrow", "Thu", "20 Nov".
        let when: String
        let isFollowUp: Bool
    }

    /// How far ahead the card looks. Two weeks is the furthest a "next up"
    /// still reads as next.
    static let horizonDays = 14

    /// The open tasks and follow-ups dated from now to `horizonDays` ahead,
    /// soonest first. A timed one earlier today has passed and is left out.
    /// Overdue work is the Tasks card's, which leads with it.
    static func rows(tasks: [ShiftTask], followUps: [ShiftFollowUp], now: Date = Date(),
                     calendar: Calendar = .current) -> [Row] {
        let today = calendar.startOfDay(for: now)
        guard let through = calendar.date(byAdding: .day, value: horizonDays, to: today) else { return [] }
        let nowParts = ShiftDateFormatting.components(from: now)
        return ShiftCalendarModel.entries(tasks: tasks, followUps: followUps, from: today, through: through,
                                          calendar: calendar)
            .filter { !$0.isCompleted && !$0.isCancelled && !$0.isSkipped }
            .filter { entry in
                guard entry.day == nowParts.dateStr, let time = entry.time else { return true }
                return time >= nowParts.timeStr
            }
            .map { Row(title: $0.title, when: when(day: $0.day, time: $0.time, now: now, calendar: calendar),
                       isFollowUp: $0.kind == .followUp) }
    }

    /// A day as a person reads it from today: "Today", "Tomorrow", a weekday
    /// inside the coming week, and a date past it, with the time after.
    static func when(day: String, time: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = ShiftDateFormatting.date(from: day) else { return day }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        let label: String
        switch days {
        case 0: label = "Today"
        case 1: label = "Tomorrow"
        case 2..<7:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            label = formatter.string(from: date)
        default:
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            label = formatter.string(from: date)
        }
        return time.map { "\(label) \($0)" } ?? label
    }
}

/// The Focus timer card: the session running now, or today's focused time
/// and how to start one. It is drawn from the timer's state when Home
/// renders, so it says when a session ends rather than counting down - the
/// toolbar's chip is the live countdown, and Home does not re-render every
/// second for it.
enum HomeFocusCard {

    enum State: Equatable {
        /// A session is running and ends at `endsAt`.
        case running(task: String, endsAt: Date)
        /// A session is paused with `minutesLeft` to go.
        case paused(task: String, minutesLeft: Int)
        /// No session: the minutes focused today.
        case idle(minutesToday: Int)
    }

    static func state(session: FocusSession?, focusedSecondsToday: Int, now: Date = Date()) -> State {
        guard let session else { return .idle(minutesToday: focusedSecondsToday / 60) }
        let left = max(0, session.plannedSeconds - session.elapsed(at: now))
        if session.isPaused {
            return .paused(task: session.taskTitle, minutesLeft: Int((Double(left) / 60).rounded(.up)))
        }
        return .running(task: session.taskTitle, endsAt: now.addingTimeInterval(TimeInterval(left)))
    }

    /// What the card's body says.
    static func note(for state: State, calendar: Calendar = .current) -> String {
        switch state {
        case .running(let task, let endsAt):
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Focusing on \u{201C}\(task)\u{201D} until \(formatter.string(from: endsAt))."
        case .paused(let task, let minutesLeft):
            return "Paused on \u{201C}\(task)\u{201D} with \(minutesLeft) min left."
        case .idle(let minutes):
            return minutes == 0
                ? "No focus time yet today. Start a session from a task's Focus for menu."
                : "Focused today. Start another from a task's Focus for menu."
        }
    }
}
