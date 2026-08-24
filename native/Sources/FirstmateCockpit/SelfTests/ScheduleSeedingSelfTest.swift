// Manjesh Grand Line - native macOS app.
//
// Permanent coverage for `ScheduleSeeding.swift`: the "daily-github-sync"
// schedule seeds exactly once, at the right cadence, using the already-
// reviewed `.forkSync` action - never a new action, never a re-seed after
// the captain edits or deletes it.
//
// Every case here runs against a scratch `FM_SCHEDULES_FILE` (never the
// captain's real `schedules.json`) and a plain in-memory `Bool` for the
// "already seeded" flag (never real `UserDefaults`/`AppSettings.shared`) -
// so this suite touches no real captain data anywhere.
//
// Run: `FM_RUN_SCHEDULE_SEEDING_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum ScheduleSeedingSelfTest {

    static func run() -> Bool {
        var ok = true
        checkSeedsOnce(&ok)
        checkExactCadenceAndAction(&ok)
        checkDoesNotResurrectAfterDelete(&ok)
        checkDoesNotResurrectAfterEdit(&ok)
        checkNeverAddsANewActionKind(&ok)
        print(ok ? "ScheduleSeedingSelfTest: all checks passed" : "ScheduleSeedingSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: Scratch helpers - same convention as `ScheduleRunnerSelfTest`

    private static func scratchStore() -> ScheduleStore? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-schedule-seeding-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        setenv("FM_SCHEDULES_FILE", dir.appendingPathComponent("schedules.json").path, 1)
        return ScheduleStore()
    }

    /// A plain in-memory stand-in for `AppSettings.didSeedDailyGitHubSyncSchedule`,
    /// so this suite never touches the real, persistent `UserDefaults.standard`
    /// on a shared dev machine.
    private final class FakeFlag {
        var seeded = false
    }

    // MARK: Seeds exactly once

    private static func checkSeedsOnce(_ ok: inout Bool) {
        print("\n-- seeds exactly once --")
        guard let store = scratchStore() else {
            fail("could not create a scratch schedule store", &ok)
            return
        }
        let flag = FakeFlag()

        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        if store.schedules.count != 1 {
            fail("first call should add exactly one schedule, got \(store.schedules.count)", &ok)
        }
        if !flag.seeded {
            fail("first call should mark the flag seeded", &ok)
        }

        // A second call (the real launch-time call site runs this on every
        // launch) must not add a duplicate.
        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        if store.schedules.count != 1 {
            fail("a second call must be a no-op once seeded, got \(store.schedules.count) schedules", &ok)
        }
    }

    // MARK: The exact cadence and action the task asked for

    private static func checkExactCadenceAndAction(_ ok: inout Bool) {
        print("\n-- 11:10 AM, fork sync --")
        guard let store = scratchStore() else {
            fail("could not create a scratch schedule store", &ok)
            return
        }
        let flag = FakeFlag()
        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        guard let seeded = store.schedules.first else {
            fail("nothing was seeded", &ok)
            return
        }
        if seeded.action != .forkSync {
            fail("""
                the seeded schedule must call the already-reviewed .forkSync action - the exact call \
                GitHubSyncController.syncAll()'s own per-repo check/sync makes - got \(seeded.action.rawValue)
                """, &ok)
        }
        if seeded.cadence.normalized != .daily(hour: 11, minute: 10) {
            fail("expected daily at 11:10, got \(seeded.cadence.normalized)", &ok)
        }
        // A fresh schedule should not fire the instant it is seeded - it is
        // anchored to the occurrence current at seed time, the same rule
        // `ScheduleStore.add` already applies to a captain-created schedule.
        if ScheduleDueCalculator.verdict(for: seeded, now: Date()).isDue {
            fail("a freshly-seeded schedule must not be immediately due", &ok)
        }
    }

    // MARK: A deleted schedule is never resurrected

    private static func checkDoesNotResurrectAfterDelete(_ ok: inout Bool) {
        print("\n-- deleting it is a real decision, not fought on next launch --")
        guard let store = scratchStore() else {
            fail("could not create a scratch schedule store", &ok)
            return
        }
        let flag = FakeFlag()
        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        guard let id = store.schedules.first?.id else {
            fail("nothing was seeded", &ok)
            return
        }
        store.delete(id: id)
        if !store.schedules.isEmpty {
            fail("delete() should have removed it", &ok)
        }

        // Simulate the next launch: the flag is already `true` (persisted
        // from the first launch), so calling the seed function again must
        // not bring it back.
        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        if !store.schedules.isEmpty {
            fail("a captain-deleted schedule must not be resurrected on a later launch", &ok)
        }
    }

    // MARK: An edited schedule is never overwritten

    private static func checkDoesNotResurrectAfterEdit(_ ok: inout Bool) {
        print("\n-- editing the time/notify setting sticks across a later launch --")
        guard let store = scratchStore() else {
            fail("could not create a scratch schedule store", &ok)
            return
        }
        let flag = FakeFlag()
        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        guard var edited = store.schedules.first else {
            fail("nothing was seeded", &ok)
            return
        }
        edited.cadence = .daily(hour: 23, minute: 0)
        edited.notifyOn = .always
        store.update(edited)

        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: store, alreadySeeded: { flag.seeded }, markSeeded: { flag.seeded = true })
        if store.schedules.count != 1 {
            fail("a later call must not add a second schedule alongside the edited one, got \(store.schedules.count)", &ok)
        }
        guard let stillEdited = store.schedules.first else {
            fail("the edited schedule disappeared", &ok)
            return
        }
        if stillEdited.cadence.normalized != .daily(hour: 23, minute: 0) || stillEdited.notifyOn != .always {
            fail("the captain's own edit must survive a later seed attempt", &ok)
        }
    }

    // MARK: The safety bar this task must not touch

    /// The task's own explicit constraint: reuse the existing "Sync All" call
    /// exactly, never a new or widened schedulable action. `.forkSync` already
    /// existed before this task, so seeding it must not have required, and
    /// must not have come bundled with, a new `ScheduledActionKind` case.
    private static func checkNeverAddsANewActionKind(_ ok: inout Bool) {
        print("\n-- no new schedulable action was introduced --")
        let reviewed: Set<String> = ["driftCheck", "toolUpdateCheck", "forkSync", "vaultRecipeExport", "configBackupExport"]
        let actual = Set(ScheduledActionKind.allCases.map { $0.rawValue })
        if actual != reviewed {
            fail("""
                the schedulable action set changed to \(actual.sorted()) - this task must only seed a \
                schedule using the pre-existing, already-reviewed .forkSync action
                """, &ok)
        }
        if !ScheduledActionKind.forkSync.writesRemotely {
            fail("fork sync genuinely pushes to GitHub and must still be flagged as writing remotely", &ok)
        }
    }
}

#endif
