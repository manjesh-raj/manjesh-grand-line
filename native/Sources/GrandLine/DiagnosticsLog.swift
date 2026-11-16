// Grand Line - native macOS app.
//
// Process issue P9 of the 2026-09-25 review: "crash reports and logs are
// invisible to the process".
//
// GL-11 put every catch-and-degrade site behind `os.Logger` through `AppLog`,
// which was the right first move and is still where the detail goes. What the
// review measured is that it produces nothing a later investigation can read:
// `log show --predicate 'subsystem == "com.manjesh.grandline.native"'` returned
// **zero lines** for a 25-minute probe session and for the captain's own app
// over five hours, because `.info` and `.debug` are not persisted by default
// and an agent shell may not be able to read the store at all. Two SIGABRTs in
// 24 hours sat unnoticed in `~/Library/Logs/DiagnosticReports`, and bug B1's
// root cause could not be reconstructed for exactly this reason.
//
// So this is a second, deliberately small sink that is always on disk and
// always readable:
//
//   * **One file, under this app's own data root** (so `FM_SCRATCH_ROOT` moves
//     it like every other store - see `AppPaths.dataRoot()`), and a narrow
//     `FM_DIAGNOSTICS_DIR` of its own.
//   * **Errors and lifecycle only.** Not a second copy of every log line: the
//     unified log is still where detail belongs, and a file that records
//     everything is a file nobody reads and a store nobody bounds. What lands
//     here is what somebody would want an hour later - the app started, the
//     app is quitting, a save failed, a store would not decode.
//   * **Bounded** (GL-35): one 256KB file plus one rotated generation, so the
//     worst case on disk is half a megabyte, forever.
//   * **Locked** (GL-28): reached from background queues and from main.
//   * Nothing leaves the machine, and the secret rule is unchanged - log the
//     shape, never the value.
//
// The second half of P9 is the crash reports. macOS writes them next to every
// other app's, and nothing in this app ever looked: `crashReportsSinceLastLaunch()`
// compares the system's own reports for this executable against the timestamp
// of the previous launch, so a crash the captain did not notice becomes a row
// on Health rather than a file nobody opens.
//
// This is a *diagnostic* sink and not a durability mechanism: a write that
// fails is dropped, because a logger that can fail a caller is worse than a
// logger that misses a line. That is the one place in this app where a silent
// failure is the right call, and it is stated rather than implied.
//
// R5-PROC-01 of review #5 measured the same zero again: `log show` over the
// last 30 minutes of the captain's instance returned nothing, and `app.log`
// held only `launched`/`quitting`. The schedule re-fire in R5-BUG-01, the
// watchdog cancelling a hung background pass and the "waited 120 s on another
// check" events all happened with nothing on disk to say so, because they are
// `.info` events and the unified log does not keep those. So there is a second
// file here, `activity.log`, for the background timeline:
//
//   * **Four categories only** (`Activity`): the poller, git sync, subprocess
//     runs and lifecycle. These are the events that happen while nobody is
//     watching, which is the whole reason they need a file.
//   * **Written at choke points, not mirrored from every `AppLog` call.** A
//     subprocess line comes from `Subprocess`'s one completion hook and says
//     which tool ran, for how long and how it ended. It never carries argv or
//     output, which is where a prompt or a secret's name would be. Every
//     message also goes through `LogRedactor` before it reaches disk.
//   * **Bounded** like `app.log`, at 512KB plus one rotated generation, which
//     is many hours of a normal day.
//   * **Off the caller's thread.** An activity line is written on a private
//     serial queue, because the subprocess hook runs for every child and some
//     of those finish on main.
//
// "Copy diagnostics" on Health includes the last hour of it.

import Foundation

final class DiagnosticsLog {

    static let shared = DiagnosticsLog()

    enum Level: String {
        case error = "ERROR"
        case lifecycle = "LIFE"
    }

    /// One file plus one rotated generation. A crash investigation wants the
    /// last few hundred lines, not a week.
    private static let maxBytes = 256 * 1024

    /// R5-PROC-01: the categories that reach `activity.log`. Deliberately a
    /// closed set - see the header for why this is not every `AppLog` line.
    enum Activity: String {
        case poller
        case gitSync = "git-sync"
        case subprocess
        case lifecycle
    }

    /// The activity file's bound. Larger than `app.log`'s because it is a
    /// timeline: at about 80 bytes a line, one generation is several thousand
    /// events, and a busy hour is a few hundred.
    static let maxActivityBytes = 512 * 1024

    private let lock = NSLock()
    private let directory: URL
    private let fileURL: URL
    private let rotatedURL: URL
    private let activityURL: URL
    private let rotatedActivityURL: URL
    private let activityQueue = DispatchQueue(label: "com.manjesh.grandline.diagnostics.activity",
                                              qos: .utility)

    /// The moment the previous run of this app started, read once at init -
    /// before `noteLaunch()` overwrites it. `nil` on a machine that has never
    /// run a build carrying this file.
    private(set) var previousLaunch: Date?

    init(directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.directory = directory ?? Self.defaultDirectory(environment: environment)
        self.fileURL = self.directory.appendingPathComponent("app.log")
        self.rotatedURL = self.directory.appendingPathComponent("app.log.1")
        self.activityURL = self.directory.appendingPathComponent("activity.log")
        self.rotatedActivityURL = self.directory.appendingPathComponent("activity.log.1")
        self.previousLaunch = Self.readLaunchStamp(in: self.directory)
    }

    /// The narrow override wins over `FM_SCRATCH_ROOT`, like every other store
    /// (see the README's env-var index).
    static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["FM_DIAGNOSTICS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AppPaths.dataRoot(environment: environment)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    // MARK: - Writing

    func error(_ category: String, _ message: String) { record(.error, category, message) }
    func lifecycle(_ category: String, _ message: String) {
        record(.lifecycle, category, message)
        activity(.lifecycle, message)
    }

    func record(_ level: Level, _ category: String, _ message: String) {
        let line = "\(Self.stamp(Date())) \(level.rawValue) [\(category)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        append(line)
    }

    /// Called once from `main.swift`, after the previous stamp has been read.
    func noteLaunch(version: String) {
        lifecycle("lifecycle", "launched, version \(version)")
        lock.lock()
        defer { lock.unlock() }
        ensureDirectory()
        try? Self.stamp(Date()).write(to: directory.appendingPathComponent("last-launch"),
                                      atomically: true, encoding: .utf8)
    }

    /// The tail of the log, newest last, for "Copy diagnostics".
    func recentLines(limit: Int = 40) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(limit))
    }

    // MARK: - Activity (R5-PROC-01)

    /// One background event. `failed` marks the line `ERROR` rather than
    /// `INFO`, so a failure is findable in a timeline of successes.
    func activity(_ category: Activity, _ message: String, failed: Bool = false, at date: Date = Date()) {
        let level = failed ? "ERROR" : "INFO"
        let text = LogRedactor.redact(message).text.replacingOccurrences(of: "\n", with: " ")
        let line = "\(Self.stamp(date)) \(level) [\(category.rawValue)] \(text)\n"
        activityQueue.async { [self] in
            append(line, to: activityURL, rotatingTo: rotatedActivityURL, maxBytes: Self.maxActivityBytes)
        }
    }

    /// The activity lines from the last `window` seconds, oldest first, at
    /// most `limit` of them (the newest win). Reads both generations, so an
    /// hour that straddles a rotation is still a whole hour.
    func recentActivity(within window: TimeInterval = 3_600, now: Date = Date(), limit: Int = 400) -> [String] {
        activityQueue.sync {
            let cutoff = now.addingTimeInterval(-window)
            var lines: [String] = []
            for url in [rotatedActivityURL, activityURL] {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let space = line.firstIndex(of: " "),
                          let when = Self.stampFormatter.date(from: String(line[..<space])),
                          when >= cutoff else { continue }
                    lines.append(String(line))
                }
            }
            return Array(lines.suffix(limit))
        }
    }

    private func append(_ line: String) {
        append(line, to: fileURL, rotatingTo: rotatedURL, maxBytes: Self.maxBytes)
    }

    private func append(_ line: String, to fileURL: URL, rotatingTo rotatedURL: URL, maxBytes: Int) {
        ensureDirectory()
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber, size.intValue + data.count > maxBytes {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            // A diagnostic sink must never fail its caller (see the header),
            // so every write here is best-effort.
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Crash reports

    /// The system's own crash reports for this executable that are newer than
    /// the previous launch, newest first.
    ///
    /// Read-only and best-effort by construction: the directory may not exist,
    /// may not be readable, and on a machine that has never run a build
    /// carrying this file there is no previous launch to compare against - all
    /// three answer "none" rather than guessing.
    func crashReportsSinceLastLaunch(
        directory reportsDirectory: URL? = nil,
        since: Date? = nil
    ) -> [String] {
        guard let cutoff = since ?? previousLaunch else { return [] }
        let dir = reportsDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        var found: [(Date, String)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard Self.namesThisApp(name) else { continue }
            guard let when = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, when > cutoff else { continue }
            found.append((when, name))
        }
        return found.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    /// A report is named `<executable>-<date>-<pid>.ips`. The pre-rename
    /// executable is matched too: a machine that crashed before
    /// `fm/grandline-rename-firstmate-cockpit-to-grand-line` still has those,
    /// and they are this app's (see `LegacyNameMigration`).
    static func namesThisApp(_ fileName: String) -> Bool {
        (fileName.hasPrefix("GrandLine-") || fileName.hasPrefix("FirstmateCockpit-"))
            && (fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash"))
    }

    // MARK: - Stamps

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static func readLaunchStamp(in directory: URL) -> Date? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("last-launch"),
                                     encoding: .utf8) else { return nil }
        return stampFormatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
