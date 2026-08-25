// Manjesh Grand Line - native macOS app.
//
// F11: permanent coverage for the scheduler's due / missed / catch-up decision,
// the store's own anchoring rules, and the notify-on gate.
//
// **Why this decision specifically.** F11 names one behaviour by name -
// "missed-while-asleep runs fire on next wake" - and it is the one thing about
// a scheduler that is genuinely easy to get wrong in a way nobody notices:
// every visible symptom of getting it wrong is a run that *did not happen*,
// which looks exactly like a quiet night. The obvious implementation (store a
// `nextRun` date, compare it to `now`, advance it after each run) silently
// drops a missed occurrence, or fires seven catch-up runs after a week away,
// depending on how the advance is written. `ScheduleDueCalculator` compares the
// most recent *occurrence* against what was last run instead, which is what
// makes all three cases fall out of one comparison - and this suite is what
// pins that.
//
// Every case here is pure date math against an injected `Calendar` and an
// injected `now`, plus a scratch `FM_SCHEDULES_FILE`. Nothing spawns a
// subprocess, touches the network, reads the captain's real schedules, or runs
// a real action - `ScheduleActions` calls real `brew`/`gh`/`git` paths and is
// deliberately not driven here (its arms are thin adapters over code those
// tools' own suites already cover).
//
// Run: `FM_RUN_SCHEDULE_RUNNER_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum ScheduleRunnerSelfTest {

    static func run() -> Bool {
        var ok = true
        checkOccurrenceMath(&ok)
        checkDueOnTime(&ok)
        checkNotDueTwice(&ok)
        checkMissedWhileAsleepFires(&ok)
        checkLongGapFiresExactlyOnce(&ok)
        checkDisabledNeverFires(&ok)
        checkWeeklyCadence(&ok)
        checkStoreAnchoring(&ok)
        checkNotifyGate(&ok)
        checkActionSafetyBar(&ok)
        checkPersistenceRoundTrip(&ok)
        checkDailyUpdatesSeeding(&ok)
        checkRunHistoryPersistsAndFilters(&ok)
        checkHealthSeedingFromHistory(&ok)
        print(ok ? "ScheduleRunnerSelfTest: all checks passed" : "ScheduleRunnerSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: Fixtures
    //
    // A fixed UTC calendar, so a run of this suite means the same thing in
    // every timezone and the assertions can be written as literal wall-clock
    // times. `ScheduleDueCalculator` takes its calendar as a parameter for
    // exactly this reason.
    private static var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0))!
    }

    /// A nightly-at-02:00 schedule, the mockup's own example.
    private static func nightly(firedFor: Date?) -> AutomationSchedule {
        AutomationSchedule(action: .driftCheck,
                           cadence: .daily(hour: 2, minute: 0),
                           lastFiredOccurrence: firedFor)
    }

    // MARK: Occurrence math

    private static func checkOccurrenceMath(_ ok: inout Bool) {
        print("\n-- occurrence math --")

        // Mid-afternoon: the most recent 02:00 is this morning's.
        let afternoon = at(2026, 3, 10, 15, 30)
        let recent = ScheduleDueCalculator.mostRecentOccurrence(
            of: .daily(hour: 2, minute: 0), atOrBefore: afternoon, calendar: utc)
        if recent != at(2026, 3, 10, 2, 0) {
            fail("most recent 02:00 before 15:30 should be the same morning, got \(String(describing: recent))", &ok)
        }

        // Just before it: yesterday's.
        let earlyMorning = at(2026, 3, 10, 1, 59)
        let before = ScheduleDueCalculator.mostRecentOccurrence(
            of: .daily(hour: 2, minute: 0), atOrBefore: earlyMorning, calendar: utc)
        if before != at(2026, 3, 9, 2, 0) {
            fail("most recent 02:00 before 01:59 should be the previous day, got \(String(describing: before))", &ok)
        }

        // Exactly on it counts as *that* occurrence, not the previous one. This
        // is why the search starts a second past `now` - `Calendar`'s backward
        // search is strictly-before, so searching from `now` itself would put a
        // tick landing exactly on 02:00:00 one whole day behind.
        let onTheDot = at(2026, 3, 10, 2, 0)
        let exact = ScheduleDueCalculator.mostRecentOccurrence(
            of: .daily(hour: 2, minute: 0), atOrBefore: onTheDot, calendar: utc)
        if exact != onTheDot {
            fail("02:00 exactly should resolve to itself, got \(String(describing: exact))", &ok)
        }

        let next = ScheduleDueCalculator.nextOccurrence(
            of: .daily(hour: 2, minute: 0), after: afternoon, calendar: utc)
        if next != at(2026, 3, 11, 2, 0) {
            fail("next 02:00 after 15:30 should be the following morning, got \(String(describing: next))", &ok)
        }
    }

    // MARK: The three cases F11 cares about

    private static func checkDueOnTime(_ ok: inout Bool) {
        print("\n-- due on time --")
        // Last night's run recorded; the tick a minute after tonight's 02:00.
        let schedule = nightly(firedFor: at(2026, 3, 9, 2, 0))
        let verdict = ScheduleDueCalculator.verdict(for: schedule, now: at(2026, 3, 10, 2, 1), calendar: utc)
        guard case .due(let occurrence, let lateBy) = verdict else {
            fail("a schedule whose 02:00 has just passed should be due, got \(verdict)", &ok)
            return
        }
        if occurrence != at(2026, 3, 10, 2, 0) {
            fail("the run should belong to today's 02:00, got \(occurrence)", &ok)
        }
        if lateBy != 60 {
            fail("a tick one minute after should report 60s late, got \(lateBy)", &ok)
        }
    }

    private static func checkNotDueTwice(_ ok: inout Bool) {
        print("\n-- does not fire twice for one occurrence --")
        // Already ran for today's 02:00; every later tick that day must decline.
        let schedule = nightly(firedFor: at(2026, 3, 10, 2, 0))
        for (h, m) in [(2, 1), (2, 30), (9, 0), (23, 59)] {
            let verdict = ScheduleDueCalculator.verdict(for: schedule, now: at(2026, 3, 10, h, m), calendar: utc)
            if verdict != .notDue {
                fail("already ran for today's 02:00 but \(h):\(m) reported \(verdict)", &ok)
            }
        }
        // ...and the next day's 02:00 is a new occurrence, so it is due again.
        let tomorrow = ScheduleDueCalculator.verdict(for: schedule, now: at(2026, 3, 11, 2, 1), calendar: utc)
        if !tomorrow.isDue {
            fail("the next day's 02:00 is a fresh occurrence and should be due, got \(tomorrow)", &ok)
        }
    }

    /// F11's own named requirement.
    private static func checkMissedWhileAsleepFires(_ ok: inout Bool) {
        print("\n-- missed while asleep fires on next wake --")
        // The Mac slept from 01:00 to 09:00. 02:00 came and went with no tick.
        let schedule = nightly(firedFor: at(2026, 3, 9, 2, 0))
        let onWake = at(2026, 3, 10, 9, 0)
        let verdict = ScheduleDueCalculator.verdict(for: schedule, now: onWake, calendar: utc)
        guard case .due(let occurrence, let lateBy) = verdict else {
            fail("a 02:00 run missed while asleep must fire on wake, got \(verdict)", &ok)
            return
        }
        if occurrence != at(2026, 3, 10, 2, 0) {
            fail("the catch-up run should be attributed to the missed 02:00, got \(occurrence)", &ok)
        }
        if lateBy != 7 * 3600 {
            fail("waking at 09:00 after a 02:00 run should report 7h late, got \(lateBy)", &ok)
        }
    }

    /// The other half of the same design: one catch-up run, not one per missed
    /// day. Re-running a drift check seven times to "catch up" on a week away
    /// would be noise, and it is the natural failure mode of a stored-nextRun
    /// implementation that advances in a loop.
    private static func checkLongGapFiresExactlyOnce(_ ok: inout Bool) {
        print("\n-- a long gap produces exactly one catch-up run --")
        var schedule = nightly(firedFor: at(2026, 3, 1, 2, 0))
        let backAfterAWeek = at(2026, 3, 9, 11, 0)

        var fired = 0
        // Simulate the runner: while due, run it and record the occurrence,
        // exactly as `ScheduleStore.recordRun` does. A correct calculator
        // settles after one run; a looping-advance one would fire eight times.
        while case .due(let occurrence, _) = ScheduleDueCalculator.verdict(
            for: schedule, now: backAfterAWeek, calendar: utc) {
            fired += 1
            schedule.lastFiredOccurrence = occurrence
            if fired > 3 { break }
        }
        if fired != 1 {
            fail("eight missed nights should produce one catch-up run, got \(fired)", &ok)
        }
    }

    private static func checkDisabledNeverFires(_ ok: inout Bool) {
        print("\n-- a paused schedule never fires --")
        var schedule = nightly(firedFor: at(2026, 3, 1, 2, 0))
        schedule.isEnabled = false
        let verdict = ScheduleDueCalculator.verdict(for: schedule, now: at(2026, 3, 10, 9, 0), calendar: utc)
        if verdict != .disabled {
            fail("a disabled schedule with a long backlog should report .disabled, got \(verdict)", &ok)
        }
    }

    private static func checkWeeklyCadence(_ ok: inout Bool) {
        print("\n-- weekly cadence --")
        // 2026-03-08 is a Sunday. `Calendar` weekday 1 = Sunday.
        let sunday = at(2026, 3, 8, 6, 0)
        if utc.component(.weekday, from: sunday) != 1 {
            fail("fixture assumption wrong: 2026-03-08 should be a Sunday", &ok)
        }
        let cadence = ScheduleCadence.weekly(weekday: 1, hour: 6, minute: 0)

        // Wednesday afternoon: the most recent Sunday-06:00 is that Sunday.
        let wednesday = at(2026, 3, 11, 14, 0)
        let recent = ScheduleDueCalculator.mostRecentOccurrence(of: cadence, atOrBefore: wednesday, calendar: utc)
        if recent != sunday {
            fail("most recent Sunday 06:00 before Wed should be 2026-03-08 06:00, got \(String(describing: recent))", &ok)
        }

        // Ran last Sunday; Wednesday is not due; next Sunday is.
        var schedule = AutomationSchedule(action: .forkSync, cadence: cadence,
                                          lastFiredOccurrence: sunday)
        if ScheduleDueCalculator.verdict(for: schedule, now: wednesday, calendar: utc) != .notDue {
            fail("a weekly schedule already run this week should not be due mid-week", &ok)
        }
        schedule.lastFiredOccurrence = at(2026, 3, 1, 6, 0)
        if !ScheduleDueCalculator.verdict(for: schedule, now: wednesday, calendar: utc).isDue {
            fail("a weekly schedule that missed this Sunday should be due", &ok)
        }

        if cadence.displayString != "Weekly, Sunday 6:00 AM" {
            fail("weekly display string should match the mockup, got \(cadence.displayString)", &ok)
        }
        if ScheduleCadence.daily(hour: 2, minute: 0).displayString != "Nightly at 2:00 AM" {
            fail("nightly display string should match the mockup, got \(ScheduleCadence.daily(hour: 2, minute: 0).displayString)", &ok)
        }
    }

    // MARK: Store anchoring

    private static func checkStoreAnchoring(_ ok: inout Bool) {
        print("\n-- store anchoring (new / re-enabled / manual run) --")
        guard let store = scratchStore() else {
            fail("could not create a scratch schedule store", &ok)
            return
        }

        // A schedule created at 15:00 must not fire the instant it is saved.
        let creation = at(2026, 3, 10, 15, 0)
        store.add(AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0)), now: creation)
        guard let created = store.schedules.first else {
            fail("add() did not persist a schedule", &ok)
            return
        }
        if ScheduleDueCalculator.verdict(for: created, now: creation, calendar: utc).isDue {
            fail("a schedule created at 15:00 should not be immediately due for today's 02:00", &ok)
        }
        // ...and it does fire the next morning.
        if !ScheduleDueCalculator.verdict(for: created, now: at(2026, 3, 11, 2, 1), calendar: utc).isDue {
            fail("a schedule created yesterday afternoon should fire at tonight's 02:00", &ok)
        }

        // Re-enabling anchors to now rather than firing for what was missed
        // while paused: a deliberately-paused schedule has no backlog, which is
        // the difference between "paused" and "the Mac was asleep".
        store.setEnabled(false, id: created.id)
        store.setEnabled(true, id: created.id, now: at(2026, 3, 20, 9, 0))
        guard let resumed = store.schedule(id: created.id) else {
            fail("schedule vanished across a disable/enable cycle", &ok)
            return
        }
        if ScheduleDueCalculator.verdict(for: resumed, now: at(2026, 3, 20, 9, 0), calendar: utc).isDue {
            fail("re-enabling should anchor to the current occurrence, not fire for the paused days", &ok)
        }

        // A manual "Run now" records a result but satisfies nothing on the
        // calendar - tonight's scheduled run still happens.
        let beforeManual = store.schedule(id: created.id)?.lastFiredOccurrence
        store.recordRun(id: created.id, occurrence: nil,
                        record: ScheduleRunRecord(verdict: .clean, summary: "manual", at: Date()))
        guard let afterManual = store.schedule(id: created.id) else {
            fail("schedule vanished after recordRun", &ok)
            return
        }
        if afterManual.lastFiredOccurrence != beforeManual {
            fail("a manual run must not consume the scheduled occurrence", &ok)
        }
        if afterManual.lastRun?.summary != "manual" {
            fail("a manual run should still be recorded as the last run", &ok)
        }
    }

    // MARK: Notify gate

    private static func checkNotifyGate(_ ok: inout Bool) {
        print("\n-- notify-on gate --")
        let cases: [(ScheduleNotifyOn, ScheduleRunVerdict, Bool)] = [
            (.always, .clean, true), (.always, .changed, true), (.always, .failed, true),
            (.failureOnly, .clean, false), (.failureOnly, .changed, false), (.failureOnly, .failed, true),
            (.changeOnly, .clean, false), (.changeOnly, .changed, true), (.changeOnly, .failed, true),
        ]
        for (notifyOn, verdict, expected) in cases {
            let got = NotificationSources.shouldNotify(verdict: verdict, notifyOn: notifyOn)
            if got != expected {
                fail("notifyOn \(notifyOn.rawValue) + \(verdict.rawValue) should be \(expected), got \(got)", &ok)
            }
        }
        // `.failureOnly` deliberately stays quiet for a run that found drift -
        // that is what the captain asked for, and reporting anyway would make
        // the setting a lie.
        if NotificationSources.shouldNotify(verdict: .changed, notifyOn: .failureOnly) {
            fail("failure-only must not notify for a non-failing run", &ok)
        }
    }

    // MARK: F11's security bar
    //
    // The whole point of `ScheduledActionKind` being a closed enum is that
    // nothing destructive or interactive can become unattended. This case is a
    // guard against a future edit quietly widening that: every schedulable
    // action must still be one of the six reviewed against F11's stated
    // ceiling ("git pushes and exports are the ceiling; `av harden`-class
    // interactive actions are excluded") -
    // OR the one deliberate, captain-approved exception to that ceiling
    // (`toolUpdateInstall`, `grandline-schedule-daily-updates`): the captain
    // was shown the exact tradeoff - unattended `brew`/`npm` installs,
    // including firstmate's own self-update and the Automic Vault security
    // cask, with zero exceptions - and asked for it anyway. Widening
    // `reviewed` for a *seventh* action still needs the same deliberate
    // review this comment describes, not a copy-paste of this exception.

    private static func checkActionSafetyBar(_ ok: inout Bool) {
        print("\n-- the schedulable set is still the reviewed one --")
        let reviewed: Set<String> = [
            "driftCheck", "toolUpdateCheck", "forkSync", "vaultRecipeExport", "configBackupExport",
            "toolUpdateInstall",
        ]
        let actual = Set(ScheduledActionKind.allCases.map { $0.rawValue })
        let added = actual.subtracting(reviewed)
        if !added.isEmpty {
            fail("""
                new schedulable action(s) \(added.sorted().joined(separator: ", ")) - check them against F11's \
                bar (already exists, needs no human present, no worse than a fast-forward push) and add them \
                to `reviewed` here deliberately, not to make this test pass.
                """, &ok)
        }
        if !reviewed.subtracting(actual).isEmpty {
            fail("a reviewed action disappeared: \(reviewed.subtracting(actual).sorted().joined(separator: ", "))", &ok)
        }
        // A read-only action must not be advertised as writing remotely and
        // vice versa - the editor's "this pushes to GitHub on its own" note
        // keys off this, so a wrong value there is a misleading claim about an
        // unattended action.
        for action in ScheduledActionKind.allCases {
            let expectWrites = ["forkSync", "vaultRecipeExport", "configBackupExport", "toolUpdateInstall"]
                .contains(action.rawValue)
            if action.writesRemotely != expectWrites {
                fail("\(action.rawValue).writesRemotely should be \(expectWrites)", &ok)
            }
            if action.title.isEmpty || action.explanation.isEmpty {
                fail("\(action.rawValue) needs a title and an explanation - both are shown to the captain", &ok)
            }
        }
    }

    // MARK: Persistence

    private static func checkPersistenceRoundTrip(_ ok: inout Bool) {
        print("\n-- persistence round trip --")
        guard let dir = scratchDir() else {
            fail("could not create a scratch directory", &ok)
            return
        }
        let path = dir.appendingPathComponent("schedules.json").path
        setenv("FM_SCHEDULES_FILE", path, 1)

        let first = ScheduleStore(calendar: utc)
        first.add(AutomationSchedule(action: .vaultRecipeExport,
                                     cadence: .weekly(weekday: 6, hour: 17, minute: 0),
                                     notifyOn: .failureOnly,
                                     isEnabled: false),
                  now: at(2026, 3, 10, 12, 0))
        let id = first.schedules.first?.id
        first.recordRun(id: id ?? UUID(), occurrence: at(2026, 3, 6, 17, 0),
                        record: ScheduleRunRecord(verdict: .changed, summary: "pushed", at: at(2026, 3, 6, 17, 1)))

        // A fresh instance, so this is a real disk round trip rather than an
        // in-memory read-back.
        let second = ScheduleStore(calendar: utc)
        guard let reloaded = second.schedules.first else {
            fail("nothing survived the reload", &ok)
            return
        }
        if reloaded.action != .vaultRecipeExport { fail("action did not survive the reload", &ok) }
        if reloaded.cadence != .weekly(weekday: 6, hour: 17, minute: 0) { fail("cadence did not survive the reload", &ok) }
        if reloaded.notifyOn != .failureOnly { fail("notifyOn did not survive the reload", &ok) }
        if reloaded.isEnabled { fail("the paused flag did not survive the reload", &ok) }
        if reloaded.lastRun?.verdict != .changed { fail("last-run verdict did not survive the reload", &ok) }
        if reloaded.lastFiredOccurrence != at(2026, 3, 6, 17, 0) {
            fail("lastFiredOccurrence did not survive the reload - which would re-fire every launch", &ok)
        }
        if second.loadFailureBackupPath != nil {
            fail("a valid file must not be treated as corrupt", &ok)
        }

        // Old-format tolerance: a file written before a field existed must load
        // rather than being backed up as corrupt (the `Host.init(from:)`
        // lesson - a Swift-side default does not protect on-disk JSON).
        let minimal = """
            [{"id":"\(UUID().uuidString)","action":"driftCheck","cadence":{"daily":{"hour":2,"minute":0}}}]
            """
        try? minimal.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        let third = ScheduleStore(calendar: utc)
        if third.schedules.count != 1 {
            fail("a minimal (old-format) schedules.json should decode, got \(third.schedules.count) schedules", &ok)
        }
        if third.loadFailureBackupPath != nil {
            fail("a minimal but valid file was wrongly treated as corrupt", &ok)
        }
        if third.schedules.first?.isEnabled != true || third.schedules.first?.notifyOn != .changeOnly {
            fail("missing optional fields should fall back to the documented defaults", &ok)
        }

        unsetenv("FM_SCHEDULES_FILE")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: grandline-schedule-daily-updates
    //
    // `ScheduleActions.toolUpdateInstall` itself is deliberately not driven
    // here - see this file's header: it calls real `brew`/`npm`/`git` paths,
    // same as every other arm in `ScheduleActions`, and this suite never
    // spawns a subprocess. What *is* tested here, all pure logic against a
    // scratch file: the seed-once persistence contract
    // (`ScheduleStore.seedDailyUpdatesScheduleIfNeeded`) and that the seeded
    // cadence is genuinely a daily-at-11:00 schedule under
    // `ScheduleDueCalculator` - the same machinery every other cadence in
    // this file is proven against, exercised here specifically for the
    // config this task seeds.

    private static func checkDailyUpdatesSeeding(_ ok: inout Bool) {
        print("\n-- daily-updates: seed once, respect deletion, fires at 11:00 --")
        var scratchDirs: [URL] = []
        defer {
            unsetenv("FM_SCHEDULES_FILE")
            for dir in scratchDirs { try? FileManager.default.removeItem(at: dir) }
        }
        /// A brand-new scratch `schedules.json` path, distinct from every
        /// other call - each phase of this test needs its own "has this file
        /// ever existed" starting point, since that is exactly what
        /// `seedDailyUpdatesScheduleIfNeeded` gates on.
        func freshScratchPath() -> String? {
            guard let dir = scratchDir() else { return nil }
            scratchDirs.append(dir)
            let path = dir.appendingPathComponent("schedules.json").path
            setenv("FM_SCHEDULES_FILE", path, 1)
            return path
        }
        guard freshScratchPath() != nil else {
            fail("could not create a scratch directory", &ok)
            return
        }

        // A brand-new file: seeding should create exactly one schedule with
        // the requested action and cadence.
        let first = ScheduleStore(calendar: utc)
        first.seedDailyUpdatesScheduleIfNeeded(now: at(2026, 3, 10, 8, 0))
        guard first.schedules.count == 1, let seeded = first.schedules.first else {
            fail("seeding a fresh schedules.json should create exactly one schedule, got \(first.schedules.count)", &ok)
            return
        }
        if seeded.action != .toolUpdateInstall {
            fail("the seeded schedule's action should be .toolUpdateInstall, got \(seeded.action)", &ok)
        }
        if seeded.cadence != .daily(hour: 11, minute: 0) {
            fail("the seeded schedule's cadence should be daily at 11:00, got \(seeded.cadence)", &ok)
        }
        if !seeded.isEnabled {
            fail("the seeded schedule should start enabled", &ok)
        }
        if seeded.notifyOn != .changeOnly {
            fail("the seeded schedule should default to notifyOn = .changeOnly", &ok)
        }

        // A second launch against the same (now-existing) file must not
        // duplicate it - the schedule already having been fired for or not
        // is irrelevant, only the file's prior existence gates this.
        let second = ScheduleStore(calendar: utc)
        second.seedDailyUpdatesScheduleIfNeeded(now: at(2026, 3, 11, 8, 0))
        if second.schedules.count != 1 {
            fail("re-seeding an already-existing schedules.json should not duplicate the schedule, got \(second.schedules.count)", &ok)
        }

        // Simulate the captain deleting it, then a later launch: deletion
        // must stick, never silently resurrected. This matters specifically
        // because the seeded action auto-installs software with zero
        // confirmation - a captain who removes it must be able to trust it
        // stays gone.
        guard let idToDelete = second.schedules.first?.id else {
            fail("expected a schedule to delete", &ok)
            return
        }
        second.delete(id: idToDelete)
        if !second.schedules.isEmpty {
            fail("delete() should leave zero schedules", &ok)
        }
        let third = ScheduleStore(calendar: utc)
        third.seedDailyUpdatesScheduleIfNeeded(now: at(2026, 3, 12, 8, 0))
        if !third.schedules.isEmpty {
            fail("a deliberately deleted daily-updates schedule must not be resurrected on a later launch, got \(third.schedules.count)", &ok)
        }

        // The cadence itself, exercised on the *actually seeded* schedule -
        // seeded at 08:00 (before 11:00), so `add(_:)`'s own "anchor to the
        // current occurrence" behaviour (see `ScheduleStore.add`'s doc
        // comment) points `lastFiredOccurrence` at yesterday's 11:00, not
        // today's - which is what makes "not due yet today" a real assertion
        // here rather than true of any brand-new, unseeded schedule
        // regardless of cadence (a schedule with no `lastFiredOccurrence` at
        // all is unconditionally due the moment anyone asks, by design - see
        // `ScheduleDueCalculator.verdict`'s own doc comment - so testing that
        // shape would prove nothing about 11:00 specifically). A fresh
        // scratch path, since the one above now has zero schedules on disk
        // (the simulated deletion) and would no longer seed.
        guard freshScratchPath() != nil else {
            fail("could not create a second scratch directory", &ok)
            return
        }
        let fresh = ScheduleStore(calendar: utc)
        fresh.seedDailyUpdatesScheduleIfNeeded(now: at(2026, 3, 10, 8, 0))
        guard let seededForCadence = fresh.schedules.first else {
            fail("expected the seed to have produced a schedule to check cadence against", &ok)
            return
        }
        let beforeEleven = ScheduleDueCalculator.verdict(for: seededForCadence, now: at(2026, 3, 10, 10, 59), calendar: utc)
        if beforeEleven.isDue {
            fail("a schedule seeded this morning at 08:00 should not read as due again at 10:59 the same day", &ok)
        }
        let atEleven = ScheduleDueCalculator.verdict(for: seededForCadence, now: at(2026, 3, 10, 11, 1), calendar: utc)
        guard case .due(let occurrence, _) = atEleven else {
            fail("an 11:00 daily schedule should be due shortly after 11:00", &ok)
            return
        }
        var firedToday = seededForCadence
        firedToday.lastFiredOccurrence = occurrence
        let laterSameDay = ScheduleDueCalculator.verdict(for: firedToday, now: at(2026, 3, 10, 15, 0), calendar: utc)
        if laterSameDay.isDue {
            fail("an 11:00 daily schedule already fired for today's occurrence must not fire again the same day", &ok)
        }
        let nextDay = ScheduleDueCalculator.verdict(for: firedToday, now: at(2026, 3, 11, 11, 5), calendar: utc)
        if !nextDay.isDue {
            fail("an 11:00 daily schedule should be due again the next day at 11:05", &ok)
        }
    }

    // MARK: Run history (browsable last-7-days log + Health-seed source)
    //
    // `ScheduleRunHistoryStore` is a real, isolated JSONL store pointed at a
    // scratch directory (`init(directory:)`), never `.shared` - the same
    // convention `FleetLogStore`'s own suite uses, and the reason this can
    // exercise real-disk persistence with no risk to the captain's real
    // history.

    private static func historyEntry(scheduleID: UUID, at date: Date, verdict: ScheduleRunVerdict,
                                      summary: String, actionTitle: String = "Drift check") -> ScheduleRunHistoryEntry {
        ScheduleRunHistoryEntry(scheduleID: scheduleID, at: date, verdict: verdict,
                                summary: summary, actionTitle: actionTitle)
    }

    private static func checkRunHistoryPersistsAndFilters(_ ok: inout Bool) {
        print("\n-- run history: persists, filters per schedule, prunes past 7 days --")
        guard let dir = scratchDir() else {
            fail("could not create a scratch directory", &ok)
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let scheduleA = UUID()
        let scheduleB = UUID()
        // "now" for this whole case, so "older than 7 days" is unambiguous
        // regardless of when the suite actually runs.
        let now = at(2026, 3, 10, 12, 0)
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 3600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)
        let oneHourAgo = now.addingTimeInterval(-3600)

        let first = ScheduleRunHistoryStore(directory: dir)
        // A's entries: one past the retention window, two within it.
        first.append(historyEntry(scheduleID: scheduleA, at: eightDaysAgo, verdict: .clean,
                                  summary: "too old to keep", actionTitle: "Drift check"))
        first.append(historyEntry(scheduleID: scheduleA, at: twoDaysAgo, verdict: .failed,
                                  summary: "network unreachable", actionTitle: "Drift check"))
        first.append(historyEntry(scheduleID: scheduleA, at: oneHourAgo, verdict: .clean,
                                  summary: "Dotfiles clean, agent instructions linked.", actionTitle: "Drift check"))
        // B's own single entry - must never leak into A's filtered view.
        first.append(historyEntry(scheduleID: scheduleB, at: oneHourAgo, verdict: .changed,
                                  summary: "4 forks fast-forwarded.", actionTitle: "Fork sync"))

        let aEntries = first.entries(for: scheduleA, now: now)
        if aEntries.count != 2 {
            fail("schedule A should show 2 entries within the last 7 days, got \(aEntries.count)", &ok)
        }
        if aEntries.contains(where: { $0.summary == "too old to keep" }) {
            fail("an entry older than 7 days must be pruned from a filtered read", &ok)
        }
        if aEntries.first?.summary != "Dotfiles clean, agent instructions linked." {
            fail("entries(for:) should be newest first, got \(aEntries.map { $0.summary })", &ok)
        }
        if aEntries.contains(where: { $0.scheduleID != scheduleA }) {
            fail("schedule A's filtered history leaked another schedule's entry", &ok)
        }

        let bEntries = first.entries(for: scheduleB, now: now)
        if bEntries.count != 1 || bEntries.first?.actionTitle != "Fork sync" {
            fail("schedule B's own entry did not come back correctly, got \(bEntries)", &ok)
        }

        let allEntries = first.allEntries(now: now)
        if allEntries.count != 3 {
            fail("allEntries() should have pruned the 8-day-old entry, leaving 3, got \(allEntries.count)", &ok)
        }

        // A real disk round trip: a fresh instance over the same directory -
        // the same shape as an app rebuild/relaunch - must see the same data,
        // and the too-old entry must genuinely be gone from the file (the
        // append-time prune), not merely filtered on read.
        let second = ScheduleRunHistoryStore(directory: dir)
        if second.allEntries(now: now).count != 3 {
            fail("a fresh store instance over the same directory did not see the persisted entries", &ok)
        }
        guard let raw = try? String(contentsOf: second.debugFileURL, encoding: .utf8) else {
            fail("expected a real runs.jsonl file on disk", &ok)
            return
        }
        if raw.contains("too old to keep") {
            fail("an entry past the retention window should have been rewritten out of the file, not just hidden on read", &ok)
        }
        let lineCount = raw.split(separator: "\n", omittingEmptySubsequences: true).count
        if lineCount != 3 {
            fail("runs.jsonl should hold exactly one line per surviving entry, got \(lineCount)", &ok)
        }

        // Forgetting the in-memory cache and reading again proves the *file*
        // carries the history, not just this process's own cache - which is
        // the property that actually matters for surviving a rebuild.
        second.debugForgetCache()
        if second.entries(for: scheduleA, now: now).count != 2 {
            fail("re-reading from disk after forgetting the cache lost schedule A's history", &ok)
        }
    }

    // MARK: Health-seeding from history (pure logic, no registry, no store)

    private static func checkHealthSeedingFromHistory(_ ok: inout Bool) {
        print("\n-- ServiceHealthRegistry seeds correctly from persisted run history --")
        let scheduleID = UUID()

        // Nothing recorded at all: no seed, leaving the registry's own honest
        // "not run yet" alone rather than fabricating anything.
        if !ScheduleHealthSeeding.seeds(from: []).isEmpty {
            fail("an empty history should produce no seed instructions", &ok)
        }

        // A clean latest run seeds one success at its own timestamp - this is
        // the exact case that used to read as "Not run yet" after a rebuild
        // even though a real run had completed hours earlier the same day.
        let cleanAt = at(2026, 3, 10, 11, 0)
        let cleanSeeds = ScheduleHealthSeeding.seeds(from: [
            historyEntry(scheduleID: scheduleID, at: cleanAt, verdict: .clean, summary: "All good."),
        ])
        if cleanSeeds != [.success(at: cleanAt)] {
            fail("a clean latest run should seed exactly one success at its own time, got \(cleanSeeds)", &ok)
        }

        // `.changed` is still a *successful* run (it found something, it did
        // not fail) - `ScheduleRunner.execute()` itself calls `recordSuccess`
        // for it, and the seed must match that, not be mistaken for a failure.
        let changedAt = at(2026, 3, 10, 11, 0)
        let changedSeeds = ScheduleHealthSeeding.seeds(from: [
            historyEntry(scheduleID: scheduleID, at: changedAt, verdict: .changed, summary: "3 tools have an update available."),
        ])
        if changedSeeds != [.success(at: changedAt)] {
            fail("a 'needs you' (.changed) latest run should still seed a success, got \(changedSeeds)", &ok)
        }

        // Newest-first input (what every real read from the store returns): a
        // trailing streak of 3 failures ending at the latest entry, then an
        // older success that must NOT be replayed - the streak stops there,
        // exactly like `ServiceHealthRegistry`'s own `consecutiveFailures`
        // would reset to 0 at that success if this had happened live.
        let oldSuccessAt = at(2026, 3, 6, 11, 0)
        let fail1At = at(2026, 3, 7, 11, 0)
        let fail2At = at(2026, 3, 8, 11, 0)
        let fail3At = at(2026, 3, 9, 11, 0)
        let entriesNewestFirst: [ScheduleRunHistoryEntry] = [
            historyEntry(scheduleID: scheduleID, at: fail3At, verdict: .failed,
                        summary: "gh not authenticated.", actionTitle: "Grand Line config backup to GitHub"),
            historyEntry(scheduleID: scheduleID, at: fail2At, verdict: .failed,
                        summary: "network unreachable.", actionTitle: "Grand Line config backup to GitHub"),
            historyEntry(scheduleID: scheduleID, at: fail1At, verdict: .failed,
                        summary: "no local manjesh-config clone.", actionTitle: "Grand Line config backup to GitHub"),
            historyEntry(scheduleID: scheduleID, at: oldSuccessAt, verdict: .clean, summary: "Pushed."),
        ]
        let streakSeeds = ScheduleHealthSeeding.seeds(from: entriesNewestFirst)
        let expectedStreak: [ScheduleHealthSeed] = [
            .failure(detail: "Grand Line config backup to GitHub: no local manjesh-config clone.", at: fail1At),
            .failure(detail: "Grand Line config backup to GitHub: network unreachable.", at: fail2At),
            .failure(detail: "Grand Line config backup to GitHub: gh not authenticated.", at: fail3At),
        ]
        if streakSeeds != expectedStreak {
            fail("a trailing failure streak should replay oldest-first, stopping before the older success, got \(streakSeeds)", &ok)
        }

        // Every entry in the window failed (no success anywhere to stop at):
        // the whole history replays, oldest first.
        let allFailedSeeds = ScheduleHealthSeeding.seeds(from: [
            historyEntry(scheduleID: scheduleID, at: fail3At, verdict: .failed, summary: "third", actionTitle: "X"),
            historyEntry(scheduleID: scheduleID, at: fail2At, verdict: .failed, summary: "second", actionTitle: "X"),
            historyEntry(scheduleID: scheduleID, at: fail1At, verdict: .failed, summary: "first", actionTitle: "X"),
        ])
        let expectedAllFailed: [ScheduleHealthSeed] = [
            .failure(detail: "X: first", at: fail1At),
            .failure(detail: "X: second", at: fail2At),
            .failure(detail: "X: third", at: fail3At),
        ]
        if allFailedSeeds != expectedAllFailed {
            fail("a history with no success at all should replay every entry, oldest first, got \(allFailedSeeds)", &ok)
        }
    }

    // MARK: Scratch helpers

    private static func scratchDir() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-schedule-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// A store pointed at a scratch file, never the captain's real
    /// `schedules.json` - the same `FM_*_FILE` override every other store's
    /// suite uses.
    private static func scratchStore() -> ScheduleStore? {
        guard let dir = scratchDir() else { return nil }
        setenv("FM_SCHEDULES_FILE", dir.appendingPathComponent("schedules.json").path, 1)
        let store = ScheduleStore(calendar: utc)
        return store
    }
}

#endif
