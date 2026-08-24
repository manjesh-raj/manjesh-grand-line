// Manjesh Grand Line - native macOS app.
//
// F11 follow-up: seeds the "daily-github-sync" schedule the captain asked for
// - Setup > GitHub Sync's "Sync All" fast-forward, daily at 11:10 AM local
// device time - so it exists on the Schedules page without the captain
// having to build it by hand from "+ New Schedule".
//
// This adds no new schedulable action and no new safety behaviour: it seeds
// one `AutomationSchedule` whose action is the already-reviewed `.forkSync`
// case (`AutomationSchedule.swift`), which `ScheduleActions.forkSync()`
// already implements as exactly `GitHubSyncController.syncAll()`'s own
// per-repo `GitHubSyncSource.check`/`.sync` calls - fast-forward only, never
// `--force`, a diverged repo reported and left untouched. Nothing here
// re-implements or relaxes any of that; it only decides *when* the
// already-existing, already-safe action runs.
//
// **Seeded exactly once.** `AppSettings.didSeedDailyGitHubSyncSchedule` is the
// guard: once set, this function is a no-op forever, so a captain who later
// edits the time, disables it, or deletes it outright is never fought on the
// next launch - the same "seed once, never resurrect" contract
// `CommandLibraryStore.seedIfEmpty()` follows for its own starter catalog.
// Calling this on every launch (the real call site, in `main.swift`, right
// before `ScheduleRunner.shared.start(...)`) is therefore safe.
//
// **Timezone.** `ScheduleCadence` has no per-schedule timezone field - every
// cadence is matched against `Calendar.current`'s components (see
// `ScheduleDueCalculator`), i.e. the device's own local time. There is no
// other timezone mechanism this feature offers to plug into. "11:10 AM IST"
// is therefore expressed as `hour: 11, minute: 10` on the assumption the
// captain's own Mac is set to IST, exactly the same assumption any other
// `.daily(hour:minute:)` schedule on this page already makes.

import Foundation

enum ScheduleSeeding {

    /// Daily at 11:10 AM local device time - the one new schedule this task
    /// adds. Kept as a named constant (not inlined at the call site) so the
    /// self-test and the production call site cannot silently disagree about
    /// what "daily-github-sync" means.
    static let dailyGitHubSyncCadence = ScheduleCadence.daily(hour: 11, minute: 10)

    /// Idempotent by construction: `alreadySeeded()` is checked before doing
    /// anything else, so this can be called on every launch. `alreadySeeded`/
    /// `markSeeded` are closures (not a direct `AppSettings.shared` read)
    /// specifically so a self-test can drive this against a plain in-memory
    /// flag instead of the real, persistent `UserDefaults.standard` on a
    /// shared dev machine.
    static func seedDailyGitHubSyncIfNeeded(store: ScheduleStore,
                                            alreadySeeded: () -> Bool,
                                            markSeeded: () -> Void,
                                            now: Date = Date()) {
        guard !alreadySeeded() else { return }
        store.add(
            AutomationSchedule(action: .forkSync, cadence: dailyGitHubSyncCadence),
            now: now
        )
        markSeeded()
    }
}
