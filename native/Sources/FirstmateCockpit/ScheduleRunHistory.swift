// Manjesh Grand Line - native macOS app.
//
// F11's run history - the last 7 days of what a schedule actually did, and
// the durable half of `ServiceHealthRegistry`'s ".scheduledAutomations" state.
//
// Two gaps this closes, both reproduced against the running app before
// writing any code:
//
//  1. `AutomationSchedule.lastRun` (`ScheduleStore`) only ever remembers the
//     *single* most recent run per schedule - there was no way to see whether
//     a run two days ago succeeded, or browse a schedule's last few outcomes.
//     This file is the append-only log behind the Schedules card's "View
//     History..." affordance (`ScheduleHistoryController`).
//
//  2. `ServiceHealthRegistry` (`ServiceHealth.swift`) is deliberately pure
//     in-memory - see that file's own header: "a registry, not a monitor",
//     with no persistence of its own. That is the right shape for every
//     *other* health row (`.backgroundSignals`/`.fleetTasks`/`.shiftGitSync`/
//     `.docsSync`/`.shiftDueItems`/`.persistence`): each is driven by a
//     poller or a live process that re-reports within minutes of a fresh
//     launch regardless, so a brief "not run yet" blip at startup costs
//     nothing (confirmed by reading every `ServiceHealthRegistry.shared.*`
//     call site - none of the other five services has a durable, on-disk
//     record of its own prior outcomes the way a schedule does). It is the
//     wrong shape specifically for `.scheduledAutomations`: a schedule that
//     already ran hours earlier the same day has nothing to make it report
//     again until its *next* scheduled occurrence, which for a daily job can
//     be nearly 24 hours away - so a rebuild/relaunch shortly after a real
//     run left the Health card reading "Not run yet" for the rest of that
//     day, even though `schedules.json` on disk (and the Schedules card,
//     which reads it directly) correctly still showed the real result.
//     Reproduced live: run a schedule, `swift build`, relaunch - Health
//     reverts, Schedules does not.
//
// `ScheduleRunner.start()` seeds `.scheduledAutomations` from this file's own
// history the moment the app launches (`ScheduleHealthSeeding.seeds`, called
// once from `start()` right after `ServiceHealthRegistry.shared.register`),
// so the Health card is correct immediately with no manual re-trigger and no
// waiting for a new run. This is why the run history and the health-seed fix
// share one file and one persisted record rather than being two unrelated
// features bolted together: the history is what makes the seed possible.
//
// **Why a plain JSON file under Application Support, not a folder in the
// captain's `manjesh-config` git repo.** This app already has a precedent for
// writing operational state into `manjesh-config` -
// `VaultRecipeGit.export`'s `automatic-vault-details-backup/` folder - and it
// was checked before choosing a different location. That folder holds a
// deliberate, occasional *export* of portable configuration (secret names,
// hardened-tool metadata) meant to survive a wiped machine and be
// recoverable from a git remote; every write there is a real `git commit` +
// `git push` against a resolved `~/.dotfiles` clone, gated by
// `ConfigRepoPrivacy` and GitHub auth. A schedule's run history is the
// opposite shape: fast-changing, purely operational, machine-local state
// written every time a scheduled action completes - possibly several times
// an hour across several schedules. Committing and pushing to GitHub on every
// run would mean unattended commits at a cadence nobody asked for, real
// merge-conflict risk the moment two machines share the repo, and a network/
// GitHub-auth dependency for data whose only consumer is this one machine's
// own Health and Schedules pages. `FleetLogStore.swift` already made and
// documented this exact call for the exact same reason ("a machine-local
// audit trail of what happened *on this machine* ... syncing it would ...
// push a record of the captain's activity to GitHub that nothing asked
// for") - this file follows that precedent instead, and leaves
// `automatic-vault-details-backup/` completely untouched.
//
// **JSONL, not one JSON array** - the same reasoning `FleetLogStore` gives:
// the steady-state write is "append one entry", which a JSON array can only
// do by rewriting the whole file, and a rewrite is exactly the shape that
// loses history if interrupted. A malformed line costs only that entry
// (`decodeLines` skips it and keeps going), never the rest of the log.

import Foundation

/// One completed run, kept for `ScheduleRunHistoryStore.retentionWindow`.
struct ScheduleRunHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let scheduleID: UUID
    let at: Date
    let verdict: ScheduleRunVerdict
    /// The action's own composed outcome sentence - identical to
    /// `ScheduleRunRecord.summary` (e.g. "4 forks fast-forwarded."). Never
    /// re-derived here; always exactly what the action itself produced.
    let summary: String
    /// `schedule.action.title` snapshotted at the moment this ran, so a
    /// failure's health-service detail can be reconstructed byte-for-byte
    /// later (see `ScheduleHealthSeeding.seeds`) - an action's title can
    /// carry a live count (tracked-tool totals, fork counts) that may have
    /// moved on by the time this entry is read back.
    let actionTitle: String

    init(id: String = UUID().uuidString, scheduleID: UUID, at: Date, verdict: ScheduleRunVerdict,
         summary: String, actionTitle: String) {
        self.id = id
        self.scheduleID = scheduleID
        self.at = at
        self.verdict = verdict
        self.summary = summary
        self.actionTitle = actionTitle
    }
}

/// Append-only JSONL log of every completed schedule run, pruned to the last
/// `retentionWindow`. Not thread-confined: `append` is only ever reached from
/// `ScheduleRunner`'s main-thread completion handler today, but the lock
/// costs nothing and matches `FleetLogStore`'s own posture for a sink more
/// than one queue could plausibly reach in the future.
final class ScheduleRunHistoryStore {

    /// The app-wide sink, pointed at the real on-disk history unless
    /// `FM_SCHEDULE_HISTORY_DIR` says otherwise - the same convention
    /// `FleetLogStore.shared` already uses. A self-test that only needs the
    /// type constructs its own instance via `init(directory:)` instead, never
    /// touching the captain's real file.
    static let shared = ScheduleRunHistoryStore(directory: ScheduleRunHistoryStore.defaultDirectory())

    /// F11's stated window: "last 7 days".
    static let retentionWindow: TimeInterval = 7 * 24 * 3600

    private let fileURL: URL
    private let lock = NSLock()
    /// Loaded lazily on first read/append, file order (oldest-first).
    private var cache: [ScheduleRunHistoryEntry]?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("runs.jsonl")
    }

    /// `~/Library/Application Support/FirstmateCockpit/schedule-history/`,
    /// overridable via `FM_SCHEDULE_HISTORY_DIR` - see this file's header for
    /// why this lives here rather than in `manjesh-config`.
    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SCHEDULE_HISTORY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("schedule-history", isDirectory: true)
    }

    // MARK: Reading

    /// Every recorded run for one schedule, newest first, with anything past
    /// `retentionWindow` (relative to `now`) already dropped - so a browsing
    /// sheet never has to prune on its own, whether or not a new run has
    /// happened recently enough to have triggered a prune-on-write.
    func entries(for scheduleID: UUID, now: Date = Date()) -> [ScheduleRunHistoryEntry] {
        allEntries(now: now).filter { $0.scheduleID == scheduleID }
    }

    /// Every recorded run across every schedule, newest first, pruned the
    /// same way. Used by `ScheduleHealthSeeding` to reconstruct
    /// `.scheduledAutomations`'s last-known state at launch.
    func allEntries(now: Date = Date()) -> [ScheduleRunHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        return loadedLocked().filter { $0.at >= cutoff }.sorted { $0.at > $1.at }
    }

    // MARK: Appending

    /// Appends one entry and prunes anything now past `retentionWindow`.
    /// Called synchronously by `ScheduleRunner.execute()` right after a run
    /// completes - never batched, never scheduled.
    func append(_ entry: ScheduleRunHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadedLocked()
        entries.append(entry)
        let cutoff = entry.at.addingTimeInterval(-Self.retentionWindow)
        let pruned = entries.filter { $0.at >= cutoff }
        cache = pruned
        if pruned.count != entries.count {
            // Something aged out - a full rewrite is the only way to drop a
            // line from the middle of the file. Cheap in practice: a schedule
            // fires at most a handful of times a day, so this happens at most
            // once every several days per schedule, not on every append.
            rewriteLocked(pruned)
        } else {
            appendLineLocked(entry)
        }
    }

    // MARK: Disk

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // One line per entry: pretty-printing would break the format outright.
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func loadedLocked() -> [ScheduleRunHistoryEntry] {
        if let cache { return cache }
        let loaded = readFromDisk()
        cache = loaded
        return loaded
    }

    private func readFromDisk() -> [ScheduleRunHistoryEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Self.decodeLines(text)
    }

    /// Skips a line that will not decode rather than failing the whole read -
    /// deliberately different from the JSON stores' `StoreLoadFailure`
    /// treatment (GL-01), for the same reason `FleetLogStore.decodeLines`
    /// gives: the very next write is an append that touches no existing line,
    /// so one bad line can only ever cost itself.
    static func decodeLines(_ text: String) -> [ScheduleRunHistoryEntry] {
        var out: [ScheduleRunHistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let entry = try? decoder.decode(ScheduleRunHistoryEntry.self, from: Data(trimmed.utf8)) else {
                continue
            }
            out.append(entry)
        }
        return out
    }

    private func line(for entry: ScheduleRunHistoryEntry) -> Data? {
        guard var data = try? Self.encoder.encode(entry) else { return nil }
        data.append(0x0A)
        return data
    }

    private func appendLineLocked(_ entry: ScheduleRunHistoryEntry) {
        guard let data = line(for: entry) else { return }
        do {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                try AtomicWrite.data(data, to: fileURL)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            PersistenceFailureReporter.report(what: "schedule run history", path: fileURL.path, error: error)
        }
    }

    private func rewriteLocked(_ entries: [ScheduleRunHistoryEntry]) {
        var out = Data()
        for entry in entries {
            guard let data = line(for: entry) else { continue }
            out.append(data)
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicWrite.data(out, to: fileURL)
        } catch {
            PersistenceFailureReporter.report(what: "schedule run history (prune)", path: fileURL.path, error: error)
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// The raw file, for a test that needs to assert the on-disk shape (one
    /// JSON object per line) rather than what `allEntries()` hands back.
    var debugFileURL: URL { fileURL }
    /// Drops the in-memory cache so the next read comes from disk - lets a
    /// test prove the file, not the cache, is what carries the history
    /// (exactly the property that makes it survive an app rebuild).
    func debugForgetCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }
    #endif
}

// MARK: - Seeding ServiceHealthRegistry from history

/// One instruction to apply to `ServiceHealthRegistry`, in the order it
/// should be applied.
enum ScheduleHealthSeed: Equatable {
    case success(at: Date)
    case failure(detail: String, at: Date)
}

/// Reconstructs `.scheduledAutomations`'s true last-run state from a
/// persisted run history, so a fresh process (a rebuild, a relaunch) reflects
/// reality immediately - see this file's header for why
/// `ServiceHealthRegistry` cannot know this on its own.
///
/// Pure: entries in, seed instructions out, nothing touched - the same
/// separation `ScheduleDueCalculator` keeps from `ScheduleRunner`, so this can
/// be tested with no registry, no timer, and no store.
enum ScheduleHealthSeeding {

    /// `entries` must already be newest-first (what every read from
    /// `ScheduleRunHistoryStore` returns). Reconstructs the exact
    /// `consecutiveFailures` count `ServiceHealthRegistry` would already show
    /// live: only a trailing run of `.failed` entries ending at the very
    /// latest one counts, replayed oldest-of-that-run first (each
    /// `recordFailure` call increments the registry's counter by one, so the
    /// replay order has to match the order the failures actually happened
    /// in). A `.clean` or `.changed` latest entry resets the streak to zero,
    /// exactly like a live `recordSuccess` call does - `.changed` is still a
    /// *successful* run, just one that found something worth surfacing, and
    /// `ScheduleRunner.execute()` itself calls `recordSuccess` for it.
    ///
    /// An empty `entries` (nothing recorded yet, or nothing within the
    /// retention window) produces no seeds at all, leaving the registry's own
    /// honest "not run yet" state alone.
    static func seeds(from entries: [ScheduleRunHistoryEntry]) -> [ScheduleHealthSeed] {
        guard let latest = entries.first else { return [] }
        guard latest.verdict == .failed else {
            return [.success(at: latest.at)]
        }
        var streak: [ScheduleRunHistoryEntry] = []
        for entry in entries {
            guard entry.verdict == .failed else { break }
            streak.append(entry)
        }
        return streak.reversed().map {
            .failure(detail: "\($0.actionTitle): \($0.summary)", at: $0.at)
        }
    }
}
