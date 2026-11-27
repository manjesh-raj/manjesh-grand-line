// Grand Line - native macOS app.
//
// F-01 of full review 4: the Mac's own calendars beside the tasks.
// Run with `FM_RUN_MAC_CALENDAR_TESTS=1 .build/debug/GrandLine`.
//
// Headless, and EventKit is never asked: meetings are built here.
//
// What it pins:
//
//  - **Free time**: the gaps between meetings in the working day, counted
//    from now; a fully booked day offers the next free hour, on a later day.
//  - **A meeting reaches the page read-only**: never movable, never
//    completable, marked `meeting`, in its calendar's nearest hue's slot.
//  - **A meeting's click opens its card, not a task**, through the bridge's
//    real message handler.
//  - **Words**: Home's first-meeting sentence, the calendar head's Meetings
//    and Free today tiles, a masked meeting link.
//  - **The committed web bundle carries the meeting class** - so the source
//    change was rebuilt, not only edited.
//  - **Nothing is shown before it is asked for** (GL-14): a test process
//    never reports access.

#if FM_SELFTESTS

import AppKit

enum MacCalendarSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("free gaps between meetings", test_freeGaps),
            ("a booked day offers the next free hour", test_nextGap),
            ("a meeting reaches the page read-only", test_payload),
            ("a meeting's click opens its card", test_bridge),
            ("the words", test_words),
            ("the committed bundle carries the meeting class", test_bundle),
            ("nothing before it is asked", test_notAsked),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[mac-calendar] \(name): \(failure)", &ok) } else { print("[mac-calendar] PASS \(name)") }
        }
        print(ok ? "[mac-calendar] ALL PASS" : "[mac-calendar] FAILED")
        return ok
    }

    static let day: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!

    static func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = Calendar.current.date(byAdding: .day, value: dayOffset, to: day)!
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    static func meeting(_ title: String, _ start: Date, _ end: Date, hex: String = "3D6BE8") -> MacMeeting {
        MacMeeting(id: UUID().uuidString, title: title, start: start, end: end, isAllDay: false,
                   calendarID: "work", calendarTitle: "Work", calendarSource: "Exchange", colorHex: hex,
                   location: "https://zoom.us/j/9988774471", organizer: "Priya Raman", attendeeCount: 6)
    }

    static var wednesday: [MacMeeting] {
        [meeting("Platform stand-up", at(9, 30), at(9, 45)),
         meeting("4.20 release review", at(11), at(11, 45)),
         meeting("Lunch with Arjun", at(12, 30), at(13, 30), hex: "189A6E"),
         meeting("Vendor call: PagerDuty", at(15, 30), at(16, 30))]
    }

    static func test_freeGaps() -> String? {
        let gaps = MacCalendarRules.freeGaps(on: day, meetings: wednesday)
        let starts = gaps.map { MacCalendarRules.clock($0.start) }
        guard starts == ["9:00", "9:45", "11:45", "13:30", "16:30"] else { return "gaps start at \(starts)" }
        let fromNoon = MacCalendarRules.freeGaps(on: day, meetings: wednesday, from: at(14))
        guard fromNoon.map({ MacCalendarRules.clock($0.start) }) == ["14:00", "16:30"],
              fromNoon.reduce(0, { $0 + $1.duration }) == 3 * 3600 else {
            return "free from 14:00: \(fromNoon)"
        }
        return MacCalendarRules.duration(fromNoon.reduce(0) { $0 + $1.duration }) == "3h" ? nil : "duration words"
    }

    static func test_nextGap() -> String? {
        let booked = [meeting("Quarterly planning", at(9), at(12)), meeting("Lunch", at(12), at(13)),
                      meeting("Interview loop", at(13), at(17)),
                      meeting("Stand-up", at(9, 0, dayOffset: 1), at(10, 0, dayOffset: 1))]
        guard MacCalendarRules.overlaps(start: at(14), length: 1800, meetings: booked)?.title == "Interview loop" else {
            return "a drop on the interview did not clash"
        }
        guard MacCalendarRules.overlaps(start: at(17, 15), length: 1800, meetings: booked) == nil else {
            return "a drop after the last meeting clashed"
        }
        // Wednesday has only 17:00-18:00 left, then Thursday is free from 10:00.
        guard let wednesday = MacCalendarRules.nextGap(after: at(14), length: 3600, meetings: booked),
              MacCalendarRules.clock(wednesday) == "17:00" else { return "the same day's last hour was missed" }
        guard let thursday = MacCalendarRules.nextGap(after: at(17, 30), length: 3600, meetings: booked),
              Calendar.current.isDate(thursday, inSameDayAs: at(9, dayOffset: 1)), MacCalendarRules.clock(thursday) == "10:00" else {
            return "the next day's free hour was not offered"
        }
        return nil
    }

    static func test_payload() -> String? {
        let m = wednesday[1]
        let event = ShiftCalendarPayload.meeting(m)
        guard event["movable"] as? Bool == false, event["completable"] as? Bool == false,
              event["meeting"] as? Bool == true, event["kind"] as? String == "meeting" else { return "flags \(event)" }
        guard event["calendarId"] as? String == "meeting-blue" else { return "slot \(event["calendarId"] ?? "nil")" }
        guard event["start"] as? String == "2026-11-25 11:00", event["end"] as? String == "2026-11-25 11:45" else {
            return "times \(event["start"] ?? "") \(event["end"] ?? "")"
        }
        guard MacCalendarRules.calendarID(for: wednesday[2]) == "meeting-green" else { return "a green calendar is not green" }
        let calendars = ShiftCalendarPalette.calendars(for: ThemeManager.shared.theme)
        return HelmDomainHue.allCases.allSatisfy({ calendars["meeting-\($0.rawValue)"] != nil })
            ? nil : "the page has no slot for every meeting hue"
    }

    static func test_bridge() -> String? {
        let web = ShiftCalendarWebView()
        var meetingOpened: String?
        var taskOpened: String?
        web.onOpenMeeting = { id, _ in meetingOpened = id }
        web.onOpenTask = { taskOpened = $0 }
        web.debugHandle(message: ["type": "open", "taskID": "evt-1", "kind": "meeting"])
        guard meetingOpened == "evt-1", taskOpened == nil else { return "meeting \(String(describing: meetingOpened)), task \(String(describing: taskOpened))" }
        web.debugHandle(message: ["type": "open", "taskID": "t-1", "kind": "task", "projected": true])
        return taskOpened == "t-1" ? nil : "a task click no longer opens the task"
    }

    static func test_words() -> String? {
        guard let first = MacCalendarRules.firstMeeting(after: at(9, 12), meetings: wednesday) else { return "no first meeting" }
        let sentence = MacCalendarRules.firstMeetingSentence(first, now: at(9, 12))
        guard sentence == "Your first meeting is Platform stand-up at 9:30, in 18 minutes." else { return sentence }
        var facts = HomeGreeting.Facts(dueToday: 2, overdue: 0, prsReady: nil, servicesFailing: nil)
        facts.firstMeeting = sentence
        let summary = HomeGreeting.summary(facts, now: at(9, 12))
        guard summary.hasSuffix("2 tasks are due today. Your first meeting is Platform stand-up at 9:30, in 18 minutes.") else {
            return "Home says \(summary)"
        }
        guard !HomeGreeting.verdict(facts).text.contains("meeting") else { return "the short verdict carries the meeting" }
        guard MacCalendarRules.maskedLocation("https://zoom.us/j/9988774471") == "zoom.us/j/\u{2022}\u{2022}\u{2022}\u{2022}4471" else {
            return "masked \(MacCalendarRules.maskedLocation("https://zoom.us/j/9988774471") ?? "nil")"
        }
        let head = ShiftCalendarHeroWords.head(scale: .week, focusedDay: nil, range: nil, tasks: [], followUps: [],
                                               tray: ShiftCalendarTray(), summary: nil, now: day,
                                               meetings: .init(thisWeek: 9, freeToday: 9000))
        return head.meetings == .init(thisWeek: 9, freeToday: 9000) ? nil : "the head lost its meetings"
    }

    static func test_bundle() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[mac-calendar] SKIP bundle"); return nil }
        let vendor = dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/ScheduleX")
        guard let src = try? String(contentsOf: vendor.appendingPathComponent("src/task-calendar.js"), encoding: .utf8),
              let web = try? String(contentsOf: vendor.appendingPathComponent("web/task-calendar.js"), encoding: .utf8),
              let css = try? String(contentsOf: vendor.appendingPathComponent("web/task-calendar.css"), encoding: .utf8) else {
            return "could not read the bundle"
        }
        guard src.contains("if (item.meeting) classes.push('gl-meeting')") else { return "the source lost the meeting class" }
        guard web.contains("gl-meeting"), css.contains(".sx__event.gl-meeting") else {
            return "the committed bundle was not rebuilt after the source change"
        }
        return nil
    }

    static func test_notAsked() -> String? {
        let source = MacCalendarSource()
        guard source.access == .notAsked, !source.isShowing else { return "a test process reported calendar access" }
        return source.meetings(on: day).isEmpty ? nil : "meetings without access"
    }
}

#endif
