// Grand Line - native macOS app.
//
// The app's one "the date may have changed" signal (full review 2026-11-25,
// B-01).
//
// Grand Line is an app people leave open for days. A page that prints a date
// or a due verdict draws it when it renders, and most pages render only when
// their store changes or when they are navigated to. So a Tasks page left
// open overnight kept yesterday's date in its kicker, kept "Due today" on
// yesterday's tasks and moved nothing to Overdue, while the sidebar's badge
// beside it (one of the three pages that listened for `NSCalendarDayChanged`)
// had already turned over.
//
// `DayRollover` is the one place that decides the day moved on. It fires on:
//
//   - `NSCalendarDayChanged`, the system's own midnight;
//   - `NSSystemTimeZoneDidChange`, because "today" is a different stretch of
//     time in the new zone even when the date reads the same;
//   - `NSSystemClockDidChange` and wake from sleep, but only when the date
//     they leave behind is not the one last seen. A Mac asleep at midnight
//     gets no day-change notification of its own, and a clock correction
//     happens many times a day without moving the date.
//
// Every page that prints a date observes it and re-renders while it can be
// seen. A hidden page renders on its next appearance anyway (GL-24's spirit).
//
// `now()` is the clock those pages read "today" from. It is `Date()` in the
// app. A suite pins it, moves it past midnight, and posts the system's own
// notification, so the page under test turns over on the same path the
// captain's does.

import AppKit

final class DayRollover {

    static let shared = DayRollover()

    /// Posted on the main queue when the day may have changed, with
    /// `previousDayKey` and `todayKey` (both `yyyy-MM-dd`) in its user info.
    static let didChange = Notification.Name("com.manjesh.grandline.dayRollover")
    static let previousDayKey = "previousDay"
    static let todayKey = "today"

    /// What turned the day over. Logged, and asserted by
    /// `DayRolloverSelfTest`.
    enum Trigger: String {
        case calendarDayChanged, timeZoneChanged, clockChanged, wokeFromSleep
    }

    /// The instant pages read "today" from.
    static func now() -> Date {
        #if FM_SELFTESTS
        if let nowOverrideForTests { return nowOverrideForTests }
        #endif
        return Date()
    }

    #if FM_SELFTESTS
    /// Pins `now()`. Put back to `nil` when done.
    static var nowOverrideForTests: Date?
    #endif

    /// The day the last check saw, as `yyyy-MM-dd`.
    private(set) var day: String
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {
        day = Self.dayKey(Self.now())
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let triggers: [(NotificationCenter, Notification.Name, Trigger)] = [
            (center, .NSCalendarDayChanged, .calendarDayChanged),
            (center, .NSSystemTimeZoneDidChange, .timeZoneChanged),
            (center, .NSSystemClockDidChange, .clockChanged),
            (workspace, NSWorkspace.didWakeNotification, .wokeFromSleep),
        ]
        for (source, name, trigger) in triggers {
            let token = source.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.check(trigger)
            }
            tokens.append((source, token))
        }
    }

    deinit {
        for entry in tokens { entry.center.removeObserver(entry.token) }
    }

    /// Observe the signal. The token is an ordinary `NotificationCenter`
    /// one: remove it with `NotificationCenter.default.removeObserver`.
    /// Touching `shared` here is what starts the listening, so a page that
    /// observes never depends on something else having started it.
    static func observe(_ handler: @escaping (_ previousDay: String, _ today: String) -> Void) -> NSObjectProtocol {
        _ = shared
        return NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { note in
            let previous = note.userInfo?[previousDayKey] as? String ?? ""
            let today = note.userInfo?[todayKey] as? String ?? dayKey(now())
            handler(previous, today)
        }
    }

    /// Whether `trigger` turns the day over from `lastDay` to `today`: always
    /// for the system's own midnight and a zone change, and only when the
    /// date moved for a clock change or a wake.
    static func fires(_ trigger: Trigger, lastDay: String, today: String) -> Bool {
        switch trigger {
        case .calendarDayChanged, .timeZoneChanged: return true
        case .clockChanged, .wokeFromSleep: return today != lastDay
        }
    }

    /// Decide, and post when the day moved.
    func check(_ trigger: Trigger) {
        let today = Self.dayKey(Self.now())
        let previous = day
        guard Self.fires(trigger, lastDay: previous, today: today) else { return }
        day = today
        AppLog.lifecycle.info("day rollover (\(trigger.rawValue, privacy: .public)): \(previous, privacy: .public) to \(today, privacy: .public)")
        NotificationCenter.default.post(name: Self.didChange, object: self,
                                        userInfo: [Self.previousDayKey: previous, Self.todayKey: today])
    }

    /// `yyyy-MM-dd` in the captain's own calendar and zone, the form every
    /// due date in the task store takes.
    static func dayKey(_ date: Date) -> String {
        ShiftDateFormatting.components(from: date).dateStr
    }
}
