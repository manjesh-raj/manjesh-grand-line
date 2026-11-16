// Grand Line - native macOS app.
//
// R5-PROC-06: `ManualChecksRegister`, which reads `native/MANUAL-CHECKS.md`
// for the `.manualChecksDue` schedule action.
//
// Four things are worth guarding:
//
//   1. A `Cadence:` line is attributed to the section it sits in, and a
//      section without one is not tracked.
//   2. "Due" is a real date comparison, with "never done" due at once, and a
//      malformed date is skipped rather than read as "never done".
//   3. A missing register is `.partial`, never "nothing due" (GL-14).
//   4. The real register still carries at least one line this parser reads.
//      A reworded marker would otherwise turn the schedule into a weekly
//      "nothing due" forever.
//
// Pure logic and real file round trips - no window, no session. Deliberately
// NOT in `NEEDS_SESSION`, so it guards CI's blocking lane.
#if FM_SELFTESTS

import Foundation

enum ManualChecksRegisterSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== ManualChecksRegisterSelfTest ==")
        checkParsing(&ok)
        checkTheActionVerdicts(&ok)
        checkTheRealRegisterIsReadable(&ok)
        print(ok ? "ManualChecksRegisterSelfTest: OK" : "ManualChecksRegisterSelfTest: FAILED")
        return ok
    }

    private static var calendar: Calendar { .current }

    /// A day pinned at local noon, the same way the parser resolves one.
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private static let fixture = """
        # Manual checks

        ## 1. Energy

        - [ ] Something checked before a release.

        ## 15. Scheduled: the vendored SwiftTerm pin

        Cadence: every 183 days, last done 2026-09-19.

        ## 20. Never done yet

        cadence: Every 30 days, never done

        ## 21. A typo

        Cadence: every 30 days, last done 2026-13-40.
        """

    private static func checkParsing(_ ok: inout Bool) {
        let entries = ManualChecksRegister.parse(fixture, calendar: calendar)
        check(entries.count == 2,
              "expected the two well-formed cadence lines, got \(entries.map(\.section))", &ok)
        check(entries.first == ManualChecksRegister.Entry(
                section: "15. Scheduled: the vendored SwiftTerm pin", everyDays: 183, lastDone: day(2026, 9, 19)),
              "the SwiftTerm line must parse with its own section and date, got \(String(describing: entries.first))", &ok)
        check(entries.last?.section == "20. Never done yet" && entries.last?.lastDone == nil,
              "\"never done\" must parse, case-insensitively, as no date, got \(String(describing: entries.last))", &ok)
        check(!entries.contains { $0.section == "1. Energy" },
              "a section without a Cadence line must not be tracked", &ok)
        check(!entries.contains { $0.section == "21. A typo" },
              "a malformed date must be skipped, not read as never done", &ok)

        guard let pin = entries.first else { return }
        // 2026-09-19 + 183 days is 2027-03-21.
        check(!pin.isDue(now: day(2027, 3, 20), calendar: calendar), "one day early must not be due", &ok)
        check(pin.isDue(now: day(2027, 3, 21), calendar: calendar), "the due day itself must be due", &ok)
        check(entries.last?.isDue(now: day(2026, 1, 1), calendar: calendar) == true,
              "a check that was never done is due at once", &ok)
    }

    private static func checkTheActionVerdicts(_ ok: inout Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-manual-checks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let notDue = dir.appendingPathComponent("not-due.md")
        try? """
            ## 15. Pin
            Cadence: every 183 days, last done 2026-09-19.
            """.write(to: notDue, atomically: true, encoding: .utf8)
        let quiet = ManualChecksRegister.check(file: notDue, now: day(2026, 11, 16), calendar: calendar)
        check(quiet.verdict == .clean, "nothing due must be clean, got \(quiet.verdict)", &ok)
        check(quiet.summary.contains("2027-03-21"), "a quiet run must say when the next check is due, got \(quiet.summary)", &ok)

        let due = ManualChecksRegister.check(file: notDue, now: day(2027, 4, 1), calendar: calendar)
        check(due.verdict == .foundSomething,
              "a due check must be foundSomething, so a change-only schedule rings the bell, got \(due.verdict)", &ok)
        check(due.summary.contains("15. Pin"), "the summary must name the due section, got \(due.summary)", &ok)

        let missing = ManualChecksRegister.check(file: dir.appendingPathComponent("absent.md"), now: day(2027, 4, 1))
        check(missing.verdict == .partial && missing.failure != nil,
              "a missing register must be partial with an explanation, never \"nothing due\", got \(missing.verdict)", &ok)
    }

    private static func checkTheRealRegisterIsReadable(_ ok: inout Bool) {
        guard let sources = SelfTestSources.appSourceDirectory() else {
            print("  SKIP - sources not present next to this binary, so the real register was not read")
            return
        }
        let register = sources.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MANUAL-CHECKS.md")
        guard let text = try? String(contentsOf: register, encoding: .utf8) else {
            fail("native/MANUAL-CHECKS.md is unreadable at \(register.path)", &ok)
            return
        }
        // Discriminating power: this has to be the real register.
        check(text.contains("# Manual checks"), "\(register.path) does not look like the manual-check register", &ok)
        let entries = ManualChecksRegister.parse(text)
        check(entries.contains { $0.section.contains("SwiftTerm pin") && $0.everyDays == 183 },
              "the register's SwiftTerm pin section no longer carries a Cadence line this parser reads, "
                + "so the weekly schedule would report nothing due forever; got \(entries.map(\.section))", &ok)
    }
}

#endif
