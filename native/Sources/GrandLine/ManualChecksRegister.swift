// Grand Line - native macOS app.
//
// R5-PROC-06 of review #5: `native/MANUAL-CHECKS.md` is the honest boundary of
// what the suites cannot verify, and some of its sections are meant to be
// re-done on a schedule (the SwiftTerm pin every 183 days is the one that says
// so today). Nothing fired when such a date passed, so the register depended
// on somebody remembering to read it.
//
// This reads the register and answers "which scheduled checks are due". The
// `.manualChecksDue` schedule action calls it and reports through the same
// bell path every other schedule uses.
//
// **The marker.** A section opts in with one line of its own, in plain sight:
//
//     Cadence: every 183 days, last done 2026-09-19.
//     Cadence: every 30 days, never done.
//
// A section without that line is a "before a release" checklist and is not
// tracked. A deliberately explicit line rather than parsing the prose around
// it: prose like "**Every 183 days** (six months) ... Last done 2026-09-19"
// wraps across lines and carries markdown, and a parser that guesses at it
// would one day read the wrong date out of a sentence about something else.
//
// Read-only by construction: it reads one file and never writes it. The
// captain records a check by editing the `last done` date in the register.

import Foundation

enum ManualChecksRegister {

    /// One section that carries a `Cadence:` line.
    struct Entry: Equatable {
        /// The section's `## ` heading, without the hashes.
        let section: String
        let everyDays: Int
        /// `nil` for "never done", which is due at once.
        let lastDone: Date?

        func dueAt(calendar: Calendar) -> Date? {
            guard let lastDone else { return nil }
            return calendar.date(byAdding: .day, value: everyDays, to: lastDone)
        }

        func isDue(now: Date, calendar: Calendar) -> Bool {
            guard let due = dueAt(calendar: calendar) else { return true }
            return now >= due
        }
    }

    /// The register in the firstmate home's own grand-line checkout, which is
    /// where the captain edits it. `FM_MANUAL_CHECKS_FILE` overrides it.
    static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["FM_MANUAL_CHECKS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FirstmateHome.projects
            .appendingPathComponent("grand-line/native/MANUAL-CHECKS.md")
    }

    private static let cadencePattern = try! NSRegularExpression(
        pattern: #"^Cadence: every (\d+) days?, (?:last done (\d{4}-\d{2}-\d{2})|never done)\.?\s*$"#,
        options: [.caseInsensitive])

    /// Every section with a cadence line, in file order. A malformed date
    /// leaves the line out rather than treating it as "never done", which
    /// would cry wolf about a check that was in fact recorded.
    static func parse(_ text: String, calendar: Calendar = .current) -> [Entry] {
        var entries: [Entry] = []
        var section: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let section else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = cadencePattern.firstMatch(in: line, range: range),
                  let daysRange = Range(match.range(at: 1), in: line),
                  let days = Int(line[daysRange]), days > 0 else { continue }
            var lastDone: Date?
            if let dateRange = Range(match.range(at: 2), in: line) {
                guard let date = localNoon(String(line[dateRange]), calendar: calendar) else { continue }
                lastDone = date
            }
            entries.append(Entry(section: section, everyDays: days, lastDone: lastDone))
        }
        return entries
    }

    /// A bare day resolved to local noon, so no time zone lands it on the
    /// wrong side of a day boundary (AGENTS.md's `YYYY-MM-DD` rule).
    private static func localNoon(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    // MARK: - The schedule action

    /// What a `.manualChecksDue` run reports. A missing register is
    /// `.partial`, never "nothing due" (GL-14).
    static func check(file: URL = defaultFile(), now: Date = Date(),
                      calendar: Calendar = .current) -> ScheduleActionResult {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return ScheduleActionResult(
                failing: .partial,
                summary: "The manual-check register was not found, so nothing could be checked.",
                whatFailed: "The manual-checks schedule couldn\u{2019}t read its register.",
                why: "There is no readable file at \(file.path).",
                whatToDo: "Check that the grand-line checkout is under the firstmate home's projects folder, "
                    + "or point FM_MANUAL_CHECKS_FILE at native/MANUAL-CHECKS.md.")
        }
        let entries = parse(text, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        func when(_ entry: Entry) -> String {
            entry.dueAt(calendar: calendar).map { formatter.string(from: $0) } ?? "now (never done)"
        }
        let log = (["Register: \(file.path)"] + entries.map {
            "\($0.isDue(now: now, calendar: calendar) ? "DUE " : "ok  ") \($0.section) - every \($0.everyDays) days, due \(when($0))"
        }).joined(separator: "\n")

        guard !entries.isEmpty else {
            return ScheduleActionResult(
                verdict: .clean,
                summary: "No section of the register has a Cadence line, so no check is tracked.",
                log: log)
        }
        let due = entries.filter { $0.isDue(now: now, calendar: calendar) }
        if due.isEmpty {
            let next = entries.min { ($0.dueAt(calendar: calendar) ?? now) < ($1.dueAt(calendar: calendar) ?? now) }
            let nextText = next.map { " Next: \($0.section), due \(when($0))." } ?? ""
            return ScheduleActionResult(verdict: .clean, summary: "No manual check is due.\(nextText)", log: log)
        }
        let names = due.map(\.section).joined(separator: "; ")
        let count = due.count == 1 ? "1 manual check is due" : "\(due.count) manual checks are due"
        return ScheduleActionResult(verdict: .foundSomething, summary: "\(count): \(names).", log: log)
    }
}
