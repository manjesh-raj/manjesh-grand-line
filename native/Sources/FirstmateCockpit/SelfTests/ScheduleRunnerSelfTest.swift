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
    // action must still be one of the five reviewed against F11's stated
    // ceiling ("git pushes and exports are the ceiling; `av harden`-class
    // interactive actions are excluded").

    private static func checkActionSafetyBar(_ ok: inout Bool) {
        print("\n-- the schedulable set is still the reviewed one --")
        let reviewed: Set<String> = ["driftCheck", "toolUpdateCheck", "forkSync", "vaultRecipeExport", "configBackupExport"]
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
            let expectWrites = ["forkSync", "vaultRecipeExport", "configBackupExport"].contains(action.rawValue)
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
