// Grand Line - native macOS app.
//
// Process issue P9: "crash reports and logs are invisible to the process".
// This is `DiagnosticsLog`'s regression coverage - the on-disk sink that
// exists because `log show` returned zero lines for five hours of the
// captain's real use, and because two SIGABRTs sat unread in
// `~/Library/Logs/DiagnosticReports`.
//
// Four things are worth guarding, and each has already been the wrong answer
// in some logger somewhere:
//
//   1. A line is actually written, and the level and category are in it.
//   2. It is **bounded** (GL-35). A diagnostic file nobody rotates is a
//      diagnostic file that eventually fills a disk, and the failure is
//      invisible until it is not.
//   3. "Since the previous launch" means a real timestamp comparison, not
//      "every crash report on the machine" - and answers **none** rather than
//      guessing when it cannot tell (GL-14: unknown is never rendered as
//      zero, and here the inverse would be worse - reporting a year-old crash
//      as if it just happened).
//   4. It honours `FM_DIAGNOSTICS_DIR`, so a suite and a probe never write the
//      file a real investigation would be reading.
//
// Pure logic and real file round trips - no window, no session. Deliberately
// NOT in `NEEDS_SESSION`, so it guards CI's blocking lane.
#if FM_SELFTESTS

import Foundation

enum DiagnosticsLogSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== DiagnosticsLogSelfTest ==")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-diagnostics-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        ok = checkItWrites(in: scratch.appendingPathComponent("write")) && ok
        ok = checkItRotates(in: scratch.appendingPathComponent("rotate")) && ok
        ok = checkCrashReportsAreScopedToTheLastLaunch(in: scratch.appendingPathComponent("crash")) && ok
        ok = checkItHonoursItsOverride(in: scratch.appendingPathComponent("override")) && ok
        print(ok ? "DiagnosticsLogSelfTest: OK" : "DiagnosticsLogSelfTest: FAILED")
        return ok
    }

    private static func checkItWrites(in dir: URL) -> Bool {
        var ok = true
        let log = DiagnosticsLog(directory: dir)
        log.error("store", "failed to save hosts")
        log.lifecycle("lifecycle", "launched, version 1.2.3")

        let lines = log.recentLines()
        check(lines.count == 2, "expected 2 lines, got \(lines.count)", &ok)
        check(lines.first?.contains("ERROR [store] failed to save hosts") == true,
              "the level and category must be in the line, got \(lines.first ?? "nothing")", &ok)
        check(lines.last?.contains("LIFE [lifecycle] launched") == true,
              "the lifecycle line must survive too, got \(lines.last ?? "nothing")", &ok)
        // A timestamp, not just text - this file's whole job is "an hour
        // later", and a line with no time in it cannot do that.
        check(lines.first?.hasPrefix("20") == true,
              "every line must start with an ISO-8601 stamp, got \(lines.first ?? "nothing")", &ok)
        return ok
    }

    private static func checkItRotates(in dir: URL) -> Bool {
        var ok = true
        let log = DiagnosticsLog(directory: dir)
        // 256KB at ~340 bytes a line is about 780 lines; 4,000 is comfortably
        // past two rotations.
        let filler = String(repeating: "x", count: 300)
        for i in 0..<4_000 { log.error("store", "line \(i) \(filler)") }

        let file = dir.appendingPathComponent("app.log")
        let rotated = dir.appendingPathComponent("app.log.1")
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? -1
        let rotatedSize = ((try? fm.attributesOfItem(atPath: rotated.path))?[.size] as? NSNumber)?.intValue ?? -1

        // The fixture's discriminating power: unless this wrote more than one
        // file's worth, "it stayed small" proves nothing at all.
        check(rotatedSize > 0, "the fixture must have written enough to rotate at least once", &ok)
        check(size > 0 && size <= 256 * 1024,
              "the live file must stay within its 256KB bound, got \(size)", &ok)
        check(rotatedSize <= 256 * 1024 + 1024,
              "the rotated generation must be bounded too, got \(rotatedSize)", &ok)
        // Exactly one rotated generation, never a growing pile.
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("app.log") } ?? []
        check(entries.count == 2,
              "expected app.log plus exactly one rotated generation, got \(entries.sorted())", &ok)
        // And the newest line has to still be there - a rotation that loses
        // the thing that just happened is worse than no rotation.
        check(log.recentLines(limit: 1).first?.contains("line 3999") == true,
              "the most recent line must survive the rotation", &ok)
        return ok
    }

    private static func checkCrashReportsAreScopedToTheLastLaunch(in dir: URL) -> Bool {
        var ok = true
        let fm = FileManager.default
        let reports = dir.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try? fm.createDirectory(at: reports, withIntermediateDirectories: true)

        let cutoff = Date()
        func write(_ name: String, modified: Date) {
            let url = reports.appendingPathComponent(name)
            try? Data("report".utf8).write(to: url)
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        write("GrandLine-2026-09-25-120000.ips", modified: cutoff.addingTimeInterval(60))
        write("FirstmateCockpit-2026-09-25-120100.ips", modified: cutoff.addingTimeInterval(120))
        // Before the cutoff: a real crash, but not one from this run.
        write("GrandLine-2026-01-01-000000.ips", modified: cutoff.addingTimeInterval(-86_400))
        // Another app's, and a file that is not a report at all.
        write("Safari-2026-09-25-120000.ips", modified: cutoff.addingTimeInterval(60))
        write("GrandLine-notes.txt", modified: cutoff.addingTimeInterval(60))

        let log = DiagnosticsLog(directory: dir)
        let found = log.crashReportsSinceLastLaunch(directory: reports, since: cutoff)
        check(found.count == 2, "expected the 2 reports after the cutoff, got \(found)", &ok)
        check(found.first == "FirstmateCockpit-2026-09-25-120100.ips",
              "newest first, got \(found.first ?? "nothing")", &ok)
        check(!found.contains("Safari-2026-09-25-120000.ips"), "another app's report must not count", &ok)
        check(!found.contains("GrandLine-notes.txt"), "a non-report file must not count", &ok)

        // GL-14's shape: with no previous launch recorded there is nothing to
        // compare against, and the honest answer is none rather than every
        // report on the machine.
        check(DiagnosticsLog(directory: dir.appendingPathComponent("empty"))
                .crashReportsSinceLastLaunch(directory: reports).isEmpty,
              "with no recorded previous launch the answer must be none, not everything", &ok)

        // ...and after a launch is noted, the stamp round-trips, so the *next*
        // run compares against this one.
        let stamped = DiagnosticsLog(directory: dir.appendingPathComponent("stamped"))
        stamped.noteLaunch(version: "test")
        let reopened = DiagnosticsLog(directory: dir.appendingPathComponent("stamped"))
        check(reopened.previousLaunch != nil, "noteLaunch must leave a stamp the next run can read", &ok)
        if let when = reopened.previousLaunch {
            check(abs(when.timeIntervalSinceNow) < 120,
                  "the stamp must be this run's, got \(when)", &ok)
        }
        return ok
    }

    private static func checkItHonoursItsOverride(in dir: URL) -> Bool {
        var ok = true
        let narrow = DiagnosticsLog.defaultDirectory(environment: ["FM_DIAGNOSTICS_DIR": dir.path])
        check(narrow.path == dir.path,
              "FM_DIAGNOSTICS_DIR must be honoured verbatim, got \(narrow.path)", &ok)

        let scratchRoot = "/tmp/gl-diagnostics-scratch-root"
        let underRoot = DiagnosticsLog.defaultDirectory(environment: ["FM_SCRATCH_ROOT": scratchRoot])
        check(underRoot.path.hasPrefix(scratchRoot),
              "the default must follow FM_SCRATCH_ROOT, got \(underRoot.path)", &ok)
        // The narrow override wins over the root, like every other store.
        let both = DiagnosticsLog.defaultDirectory(
            environment: ["FM_SCRATCH_ROOT": scratchRoot, "FM_DIAGNOSTICS_DIR": dir.path])
        check(both.path == dir.path, "the narrow override must win, got \(both.path)", &ok)

        let real = DiagnosticsLog.defaultDirectory(environment: [:])
        check(real.path != dir.path && !real.path.hasPrefix(scratchRoot),
              "the fixture is vacuous unless the real default differs", &ok)
        return ok
    }
}

#endif
