// Manjesh Grand Line - native macOS app.
//
// F11: persistence for the Automation page's schedules, plus the pure
// occurrence math the scheduler runs on.
//
// **Why a JSON file rather than `AppSettings`.** F11 offers either ("persistence
// in `AppSettings` or a small JSON"). `AppSettings` is the right home for a
// single scalar preference, and every one of its properties is exactly that.
// A schedule is a record with an identity, and there is a list of them that the
// captain adds to and deletes from - which is what every other record-shaped
// thing in this app (`HostStore`, `SSHKeyStore`, `SnippetStore`,
// `DictationStore`) already uses a JSON file for, with the GL-01 corrupt-file
// durability behaviour and the GL-10 persistence-failure reporting that come
// with it. Squeezing a growable list into one `UserDefaults` blob would get
// neither.
//
// `ScheduleDueCalculator` lives here rather than in the runner because it is
// the part worth testing on its own: it is pure (a schedule, a `Date`, a
// `Calendar` in, a verdict out) and it decides the one behaviour F11 calls out
// by name - "missed-while-asleep runs fire on next wake".

import Foundation

// MARK: - Due / missed-while-asleep math

enum ScheduleDueVerdict: Equatable {
    case disabled
    case notDue
    /// Run it. `occurrence` is the scheduled time this run belongs to and is
    /// what gets written back to `lastFiredOccurrence`; `lateBy` is how far
    /// past that the app actually got round to it, which is what makes a
    /// catch-up run distinguishable from an on-time one in the log.
    case due(occurrence: Date, lateBy: TimeInterval)

    var isDue: Bool { if case .due = self { return true }; return false }
}

/// Pure occurrence math. Every function takes its `Calendar` and its `now`,
/// so a self-test can drive a year of wall-clock in milliseconds without
/// touching the machine clock.
enum ScheduleDueCalculator {

    /// The most recent time this cadence was scheduled to fire, at or before
    /// `now`. `nil` only if the calendar cannot find one at all, which for the
    /// two cadence shapes here means a corrupt cadence that `normalized`
    /// already guards against.
    ///
    /// Uses `Calendar.nextDate(… direction: .backward)` rather than hand-rolled
    /// date arithmetic on purpose: it is DST-correct for free. A daily 02:00
    /// schedule on a spring-forward day where 02:00 does not exist locally
    /// resolves through `matchingPolicy` instead of silently never matching.
    static func mostRecentOccurrence(of cadence: ScheduleCadence,
                                     atOrBefore now: Date,
                                     calendar: Calendar) -> Date? {
        // Search backward from an instant just after `now` so that a `now`
        // landing exactly on an occurrence counts as that occurrence, rather
        // than as the previous one. `.backward` is strictly-before.
        calendar.nextDate(after: now.addingTimeInterval(1),
                          matching: cadence.normalized.matchingComponents,
                          matchingPolicy: .nextTime,
                          direction: .backward)
    }

    /// The next time this cadence fires after `now` - shown in the row's
    /// tooltip, never used to decide whether to run (see
    /// `AutomationSchedule.lastFiredOccurrence` for why).
    static func nextOccurrence(of cadence: ScheduleCadence,
                               after now: Date,
                               calendar: Calendar) -> Date? {
        calendar.nextDate(after: now,
                          matching: cadence.normalized.matchingComponents,
                          matchingPolicy: .nextTime,
                          direction: .forward)
    }

    /// The core decision.
    ///
    /// Due when the most recent scheduled occurrence is one this schedule has
    /// not been run for yet. That single comparison covers all three cases F11
    /// cares about:
    ///  - on time: the tick a minute after 02:00 sees today's 02:00 as most
    ///    recent, `lastFiredOccurrence` is yesterday's, so it runs.
    ///  - already ran: the next tick sees the same 02:00, now equal to
    ///    `lastFiredOccurrence`, so it does not run again.
    ///  - missed while asleep: a Mac asleep 01:00-09:00 wakes and still sees
    ///    today's 02:00 as most recent with `lastFiredOccurrence` at
    ///    yesterday's, so it runs on wake instead of being skipped.
    ///
    /// And it deliberately produces exactly *one* catch-up run after a long
    /// gap, not one per missed occurrence - re-running a drift check seven
    /// times to "catch up" on a week away would be noise, not diligence.
    static func verdict(for schedule: AutomationSchedule,
                        now: Date,
                        calendar: Calendar = .current) -> ScheduleDueVerdict {
        guard schedule.isEnabled else { return .disabled }
        guard let occurrence = mostRecentOccurrence(of: schedule.cadence, atOrBefore: now, calendar: calendar) else {
            return .notDue
        }
        if let fired = schedule.lastFiredOccurrence, fired >= occurrence {
            return .notDue
        }
        return .due(occurrence: occurrence, lateBy: max(0, now.timeIntervalSince(occurrence)))
    }
}

// MARK: - Store

final class ScheduleStore {

    private(set) var schedules: [AutomationSchedule] = []

    /// Set when `load()` backed up an undecodable `schedules.json` (GL-01).
    private(set) var loadFailureBackupPath: String?

    /// Fired after any mutation, so the Automation card can re-render.
    var onChange: (() -> Void)?

    private let fileURL: URL
    private let calendar: Calendar

    /// Whether `fileURL` already existed the moment this instance was
    /// constructed, checked *before* `load()`/`persist()` ever touch it. This
    /// is what `seedDailyUpdatesScheduleIfNeeded()` uses to seed exactly once
    /// ever, rather than resurrecting a schedule the captain deliberately
    /// deleted - see that method's own doc comment.
    private let hadExistingFileBeforeInit: Bool

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        fileURL = ScheduleStore.storeURL()
        hadExistingFileBeforeInit = FileManager.default.fileExists(atPath: fileURL.path)
        load()
    }

    // MARK: Location

    /// `~/Library/Application Support/FirstmateCockpit/schedules.json`,
    /// overridable via `FM_SCHEDULES_FILE` - the same convention
    /// `HostStore`/`SSHKeyStore`/`SnippetStore` already use, and what lets the
    /// self-test run against a scratch file rather than the captain's real
    /// schedules.
    static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SCHEDULES_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("schedules.json")
    }

    // MARK: CRUD

    /// Seeds `lastFiredOccurrence` to the occurrence current at `now` so a
    /// brand-new schedule does not fire the instant it is saved. Creating a
    /// nightly-02:00 schedule at 15:00 should mean "starting tonight", not
    /// "and also run right now" - see `AutomationSchedule.lastFiredOccurrence`.
    func add(_ schedule: AutomationSchedule, now: Date = Date()) {
        var seeded = schedule
        if seeded.lastFiredOccurrence == nil {
            seeded.lastFiredOccurrence = ScheduleDueCalculator.mostRecentOccurrence(
                of: seeded.cadence, atOrBefore: now, calendar: calendar)
        }
        schedules.append(seeded)
        persist()
    }

    /// Replace in place, keeping ordering. A cadence edit deliberately keeps
    /// the existing `lastFiredOccurrence`: moving a nightly run from 02:00 to
    /// 03:00 at 09:00 should not fire immediately just because 03:00 today is
    /// now the most recent occurrence and has never been "fired".
    func update(_ schedule: AutomationSchedule) {
        guard let idx = schedules.firstIndex(where: { $0.id == schedule.id }) else {
            add(schedule)
            return
        }
        schedules[idx] = schedule
        persist()
    }

    func delete(id: UUID) {
        schedules.removeAll { $0.id == id }
        persist()
    }

    func schedule(id: UUID) -> AutomationSchedule? {
        schedules.first { $0.id == id }
    }

    /// Seeds the captain-requested "daily-updates" schedule
    /// (`grandline-schedule-daily-updates`) exactly once - the first time this
    /// runs against a `schedules.json` that had never existed before this
    /// instance was constructed. Uses `add(_:)`, the exact call the Schedule
    /// Editor's Save button makes, so the seeded row is byte-for-byte
    /// indistinguishable from one the captain created by hand: editable,
    /// pausable, deletable, and never specially cased anywhere in the UI.
    ///
    /// **Gated on file existence at construction, not on "does this action
    /// already exist" or "is the list empty".** `ScheduledActionKind.
    /// toolUpdateInstall` auto-installs software with zero confirmation - if
    /// the captain later edits, pauses, or (most importantly) deletes this
    /// schedule, that decision must stick across every future launch, not
    /// silently reappear the next time the app starts. A presence check
    /// keyed on the action alone would resurrect it the instant the captain
    /// deletes it (zero schedules would then have that action, which reads
    /// exactly like "never seeded"); keying on the file's own prior existence
    /// means "this schedule was already created here at least once" survives
    /// a captain deleting every schedule down to zero.
    ///
    /// **Called only from `main.swift`'s real app-launch wiring - never from
    /// `init()`, and never automatically.** Several existing self-tests
    /// construct a bare `ScheduleStore()` with no `FM_SCHEDULES_FILE`
    /// override (they only need the type to satisfy an initializer's
    /// parameter list, not its seeding behaviour), which resolves to this
    /// machine's *real* production file. Auto-seeding at construction time
    /// would make running the test suite silently create a live,
    /// auto-installing schedule on the captain's own machine the first time
    /// any of those tests ran on a fresh profile. Keeping this a separate,
    /// explicit, production-only call - `AppDelegate` (and therefore this
    /// property) is never constructed while a self-test runs, see GL-05's
    /// note in `main.swift` - closes that off entirely.
    func seedDailyUpdatesScheduleIfNeeded(now: Date = Date()) {
        guard !hadExistingFileBeforeInit else { return }
        add(AutomationSchedule(
            action: .toolUpdateInstall,
            cadence: .daily(hour: 11, minute: 0),
            notifyOn: .changeOnly,
            isEnabled: true
        ), now: now)
    }

    func setEnabled(_ enabled: Bool, id: UUID, now: Date = Date()) {
        guard let idx = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[idx].isEnabled = enabled
        // Re-enabling anchors to the current occurrence rather than firing at
        // once for whatever was missed while paused. A schedule the captain
        // deliberately switched off has no backlog worth catching up on - that
        // is what "paused" means, as distinct from "the Mac was asleep".
        if enabled {
            schedules[idx].lastFiredOccurrence = ScheduleDueCalculator.mostRecentOccurrence(
                of: schedules[idx].cadence, atOrBefore: now, calendar: calendar)
        }
        persist()
    }

    /// Records a completed run. Called by `ScheduleRunner` only.
    func recordRun(id: UUID, occurrence: Date?, record: ScheduleRunRecord) {
        guard let idx = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[idx].lastRun = record
        // A manual "Run now" passes `nil` - it satisfies nothing on the
        // calendar, so tonight's scheduled run still happens.
        if let occurrence {
            schedules[idx].lastFiredOccurrence = occurrence
        }
        persist()
    }

    // MARK: Disk

    /// Dates are ISO-8601 in this file rather than the `JSONDecoder` default
    /// (a bare `timeIntervalSinceReferenceDate` double), because a schedule's
    /// stored times are exactly the thing a captain diagnosing "why did this
    /// not run" would open the file to read. The encoder and decoder are
    /// configured together here so the two can never disagree.
    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func load() {
        var backup: String?
        schedules = StoreLoadFailure.decodeJSON(
            [AutomationSchedule].self, at: fileURL, decoder: Self.jsonDecoder(),
            label: "schedules.json", didBackUp: &backup
        ) ?? []
        loadFailureBackupPath = backup
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(schedules)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            PersistenceFailureReporter.report(what: "schedules", path: fileURL.path, error: error)
        }
        onChange?()
    }
}
