// Grand Line - native macOS app.
//
// The app's one day-change signal (`DayRollover`, full review 2026-11-25,
// B-01), headless, in CI's blocking lane.
//
//   1. **When it fires.** The system's midnight and a time zone change always
//      do. A clock change and a wake do only when the date moved, so a Mac
//      asleep at midnight turns over when it wakes and a clock correction on
//      an ordinary afternoon redraws nothing.
//   2. **The real notifications reach it**, each from the centre macOS posts
//      it on, and what it posts names the day it left and the day it found.
//   3. **The calendar's date after midnight**: a calendar on the old today
//      follows the day, one the captain moved elsewhere stays there.
//   4. **Every page that prints a date listens to it, and nothing else
//      listens to the system's midnight on its own.** A source guard, because
//      a page whose observer is deleted still passes every check above. The
//      Tasks page's own turn-over is driven through a real window in
//      `TasksSecretsHeroViewSelfTest`.
//
// Run with:
//   swift build && FM_RUN_DAY_ROLLOVER_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DayRolloverSelfTest {

    static func run() -> Bool {
        var ok = true
        defer { DayRollover.nowOverrideForTests = nil }
        checkWhenItFires(&ok)
        checkTheRealNotificationsReachIt(&ok)
        checkTheCalendarsDateAfterMidnight(&ok)
        checkEveryDatedPageListens(&ok)
        print(ok ? "DayRolloverSelfTest: all checks passed" : "DayRolloverSelfTest: FAILED")
        return ok
    }

    private static func checkWhenItFires(_ ok: inout Bool) {
        print("\n-- when the day turns over --")
        let day = "2031-03-14", next = "2031-03-15"
        for trigger in [DayRollover.Trigger.calendarDayChanged, .timeZoneChanged] {
            check(DayRollover.fires(trigger, lastDay: day, today: day) && DayRollover.fires(trigger, lastDay: day, today: next),
                  "\(trigger.rawValue) did not always fire", &ok)
        }
        for trigger in [DayRollover.Trigger.clockChanged, .wokeFromSleep] {
            check(!DayRollover.fires(trigger, lastDay: day, today: day),
                  "\(trigger.rawValue) fired on a day that had not moved", &ok)
            check(DayRollover.fires(trigger, lastDay: day, today: next),
                  "\(trigger.rawValue) did not fire once the day moved", &ok)
        }
    }

    /// What the signal posts while `body` runs. No run-loop pump: an
    /// observer registered on the main queue is called before `post` returns
    /// when the post is made on the main thread, so what was seen when `body`
    /// returns is everything that will be seen, and "nothing posted" is a
    /// fact rather than a guess about timing.
    private static func posts(during body: () -> Void) -> [(previous: String, today: String)] {
        var seen: [(String, String)] = []
        let token = DayRollover.observe { previous, today in seen.append((previous, today)) }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return seen
    }

    private static func checkTheRealNotificationsReachIt(_ ok: inout Bool) {
        print("\n-- the system's notifications reach it --")
        let calendar = Calendar.current
        guard let noon = calendar.date(from: DateComponents(year: 2031, month: 3, day: 14, hour: 12)),
              let nextNoon = calendar.date(byAdding: .day, value: 1, to: noon),
              let laterNoon = calendar.date(byAdding: .day, value: 2, to: noon) else {
            return fail("fixture: the calendar could not build the fixture's days", &ok)
        }
        let rollover = DayRollover.shared
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        // Settle on the fixture's first day, whatever the real one is.
        DayRollover.nowOverrideForTests = noon
        _ = posts { center.post(name: .NSCalendarDayChanged, object: nil) }
        check(rollover.day == "2031-03-14", "fixture: the signal is on \(rollover.day), not the fixture's day", &ok)

        let quietWake = posts { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
        let quietClock = posts { center.post(name: .NSSystemClockDidChange, object: nil) }
        check(quietWake.isEmpty && quietClock.isEmpty,
              "a wake and a clock change on the same day posted \(quietWake.count + quietClock.count) times", &ok)

        // Asleep over midnight: the wake is what turns the day.
        DayRollover.nowOverrideForTests = nextNoon
        let wake = posts { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
        check(wake.count == 1 && wake.first?.previous == "2031-03-14" && wake.first?.today == "2031-03-15",
              "a wake past midnight posted \(wake)", &ok)
        let again = posts { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
        check(again.isEmpty, "a second wake on the new day posted again", &ok)

        DayRollover.nowOverrideForTests = laterNoon
        let clock = posts { center.post(name: .NSSystemClockDidChange, object: nil) }
        check(clock.count == 1 && clock.first?.today == "2031-03-16", "a clock change past a day posted \(clock)", &ok)
        let zone = posts { center.post(name: .NSSystemTimeZoneDidChange, object: nil) }
        check(zone.count == 1 && zone.first?.previous == "2031-03-16",
              "a time zone change on the same date posted \(zone)", &ok)
        let midnight = posts { center.post(name: .NSCalendarDayChanged, object: nil) }
        check(midnight.count == 1, "the system's midnight posted \(midnight.count) times", &ok)
        DayRollover.nowOverrideForTests = nil
    }

    private static func checkTheCalendarsDateAfterMidnight(_ ok: inout Bool) {
        print("\n-- the calendar's date after midnight --")
        let follow = ShiftCalendarView.dateAfterDayChange(focusedDay: "2031-03-14", previousDay: "2031-03-14",
                                                          today: "2031-03-15")
        let unknown = ShiftCalendarView.dateAfterDayChange(focusedDay: nil, previousDay: "2031-03-14",
                                                           today: "2031-03-15")
        let stays = ShiftCalendarView.dateAfterDayChange(focusedDay: "2031-04-02", previousDay: "2031-03-14",
                                                         today: "2031-03-15")
        check(follow == "2031-03-15" && unknown == "2031-03-15",
              "a calendar on the old today showed \(follow) / \(unknown), not the new today", &ok)
        check(stays == "2031-04-02", "a calendar the captain moved to April showed \(stays)", &ok)
    }

    /// Each file that prints a date or a due verdict, and the observation it
    /// owes. Comments are stripped before matching.
    static let listeners: [(file: String, needle: String, what: String)] = [
        ("ShiftController.swift", "DayRollover.observe", "Tasks (Board, List, Weekly review, Calendar)"),
        ("ShiftController.swift", "calendar.dayDidChange(from:", "the calendar's today marker"),
        ("FleetController.swift", "DayRollover.observe", "the Crew band"),
        ("HomeCanvasController.swift", "DayRollover.observe", "Home's greeting"),
        ("MainSplitShellController.swift", "DayRollover.observe", "Home's subtitle in the shell header"),
        ("NotificationBridgePanel.swift", "DayRollover.observe", "the notifications panel's head"),
        ("WorkspaceSignalsMonitor.swift", "DayRollover.observe", "the sidebar's Tasks badge"),
        ("CompactMode.swift", "DayRollover.observe", "the menu bar's overdue count"),
    ]

    private static func checkEveryDatedPageListens(_ ok: inout Bool) {
        print("\n-- every dated page listens, and only DayRollover hears midnight --")
        guard let dir = SelfTestSources.appSourceDirectory(),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("DayRollover.swift").path) else {
            print("  SKIP the app's sources are not next to this binary - the source guard did not run")
            return
        }
        func code(_ name: String) -> String {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        for listener in listeners {
            check(code(listener.file).contains(listener.needle),
                  "B-01: \(listener.what) no longer turns over at midnight (\(listener.file) lost \(listener.needle))",
                  &ok)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(!files.isEmpty, "fixture: the source directory listed no files", &ok)
        for file in files where file.hasSuffix(".swift") && file != "DayRollover.swift" {
            check(!code(file).contains(".NSCalendarDayChanged"),
                  "B-01: \(file) listens to the system's midnight on its own; observe DayRollover instead, "
                    + "which also turns over on a wake past midnight", &ok)
        }
    }
}

#endif
