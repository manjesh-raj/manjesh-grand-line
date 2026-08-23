// Manjesh Grand Line - native macOS app.
//
// F11: the scheduler. One timer, one serial queue, and a small `switch` that
// calls actions this app already had.
//
// **What this file is not.** It does not re-implement a single check. The drift
// check is `DotfilesSource` + the same `SetupStepChecks` predicates Bootstrap's
// drift card and Automation's stepper use; the tool check is `UpdatesSource.
// check`; fork sync is `GitHubSyncSource.check`/`.sync`; the recipe export is
// `VaultRecipeGit.export`; the config backup is `GitHubBackupSource.export`.
// Every one of those already routes through the shared `Subprocess` runner
// (GL-02/GL-15), which is what F11 lists as its own dependency - "GL-02's
// bounded runner so a scheduled job can never wedge". Nothing here needs its
// own timeout because nothing here spawns its own process.
//
// **Serial, never concurrent.** Two schedules due in the same minute run one
// after the other on one queue. Same reasoning as `BootstrapController.
// installAllMissing` and `BackgroundSignalsPoller`: these actions shell out to
// `brew`/`npm`/`gh`/`git`/`av`, and racing two of those against the same
// lockfile or the same scratch clone is a real hazard rather than a theoretical
// one.
//
// **Reporting.** Every run reports to `ServiceHealthRegistry` (F11: "runs log to
// the Health surface (F1)") whether or not it is worth notifying about, so a
// scheduler that has silently stopped working is visible on the same Settings
// card every other background service reports to. The louder half - an entry in
// the in-app Notification Center - is governed per schedule by
// `ScheduleNotifyOn`. Deliberately no macOS banner: F11 asks for Health plus a
// notify-on setting, and this app's own bar is that an OS banner is reserved
// for the two things that already have one (a task needing a decision, a due
// item) behind an explicit opt-in.
//
// **While the app is locked.** Runs continue, matching `FleetNotifier` and
// `BackgroundSignalsPoller`, which also keep running behind the lock screen.
// The point of a schedule is that it is unattended, and nothing a run produces
// is visible while locked anyway: Health lives on the Settings page and the
// notification entry behind the top bar's bell, both of which the lock overlay
// covers. `AppLockGate` exists for surfaces that show or write the captain's
// data *while nobody is meant to be at the keyboard*; a background push the
// captain explicitly scheduled is not that.

import Foundation

/// What one action run amounted to, before the notify decision is applied.
struct ScheduleActionResult {
    let verdict: ScheduleRunVerdict
    /// Composed by the action itself. Never re-derived generically here.
    let summary: String
}

final class ScheduleRunner {

    static let shared = ScheduleRunner()

    /// Cheap on purpose: a tick is pure date math over a handful of schedules
    /// (`ScheduleDueCalculator.verdict`), with no process spawned unless
    /// something is actually due. So the interval can be short enough that a
    /// 02:00 schedule runs at 02:00 rather than up to 15 minutes later, which
    /// is what a cadence with a stated time-of-day implies.
    private let tickInterval: TimeInterval = 60

    /// How long after launch the first tick happens. Long enough that a
    /// catch-up run does not compete with the launch path's own work (GL-12's
    /// whole point), short enough that a missed overnight run happens while the
    /// captain is still sitting down.
    private let launchDelay: TimeInterval = 45

    /// Matches `BackgroundSignalsPoller.passWatchdog`'s reasoning: a genuinely
    /// slow run (a cold `brew` cache, a big fetch) can legitimately take
    /// minutes, and a wedged one must not silence the scheduler for the rest of
    /// the session. Every subprocess underneath is individually bounded by the
    /// shared runner, so this is a backstop rather than the only defence.
    private let runWatchdog: TimeInterval = 10 * 60

    private var timer: Timer?
    private var isRunning = false
    private var runStartedAt: Date?
    private let queue = DispatchQueue(label: "com.firstmate.cockpit.schedule-runner", qos: .utility)

    /// Set by whoever owns the shell at launch, so the notification entry a run
    /// raises can deep-link to the Schedules page - the same
    /// forward-don't-own convention `BackgroundSignalsPoller.onNavigateToUpdates`
    /// uses. Renamed from `onNavigateToAutomation` when
    /// `fm/grandline-schedules-sidebar-move` gave the Schedules card its own
    /// rail destination, separate from `.automation`'s own pipeline page.
    var onNavigateToSchedules: (() -> Void)?

    /// Fired on the main queue when a run starts and again when it finishes,
    /// so the Schedules card can show "Running…" and then the real result
    /// without polling for either.
    var onRunStateChanged: ((UUID) -> Void)?

    private var store: ScheduleStore?
    /// The four stores the config-backup action needs. Injected rather than
    /// constructed here: a second `HostStore` would be a second writer to the
    /// same JSON file, which is exactly what GL-05 exists to prevent.
    private var backupStores: (hosts: HostStore, keys: SSHKeyStore, snippets: SnippetStore, dictation: DictationStore)?

    private var calendar: Calendar = .current

    private init() {}

    // MARK: Lifecycle

    /// Safe to call once per launch.
    func start(store: ScheduleStore,
               hostStore: HostStore,
               keyStore: SSHKeyStore,
               snippetStore: SnippetStore,
               dictationStore: DictationStore) {
        self.store = store
        self.backupStores = (hostStore, keyStore, snippetStore, dictationStore)
        guard timer == nil else { return }
        // F1: declare the row so the Health card says "not run yet" rather than
        // omitting a service that exists.
        ServiceHealthRegistry.shared.register(.scheduledAutomations)
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) { [weak self] in self?.tick() }
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        // A schedule with a stated minute should not drift by much, but it does
        // not need second precision either - a little tolerance lets the system
        // coalesce this timer with others.
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Ticking

    /// One pass. Internal rather than private so the self-test can drive it
    /// without waiting on a real timer - the same convention
    /// `BackgroundSignalsPoller.checkNow()` and `ShiftNotificationScheduler.
    /// poll()` already follow.
    func tick(now: Date = Date()) {
        guard let store else { return }

        // The same "the latch must not be a one-way door" shape as GL-03: a run
        // that wedges past the watchdog must not silence every later tick for
        // the rest of the session.
        if isRunning {
            guard let startedAt = runStartedAt, now.timeIntervalSince(startedAt) > runWatchdog else { return }
            let age = Int(now.timeIntervalSince(startedAt))
            AppLog.poller.error("""
                schedules: a run started \(age)s ago has not finished - allowing a new one \
                (watchdog).
                """)
            ServiceHealthRegistry.shared.recordFailure(
                .scheduledAutomations,
                "A scheduled run has been going for \(age)s without finishing.")
            isRunning = false
            runStartedAt = nil
        }

        // Only the first due schedule per tick. The next tick picks up the
        // next one, which keeps the "one at a time" guarantee without a queue
        // of its own to get wrong - and two schedules genuinely due in the same
        // minute are a minute apart in practice, which for a nightly job is
        // indistinguishable from simultaneous.
        let due = store.schedules.compactMap { schedule -> (AutomationSchedule, Date, TimeInterval)? in
            guard case .due(let occurrence, let lateBy) = ScheduleDueCalculator.verdict(
                for: schedule, now: now, calendar: calendar) else { return nil }
            return (schedule, occurrence, lateBy)
        }
        guard let (schedule, occurrence, lateBy) = due.first else { return }
        // A catch-up run is worth saying out loud: it is the difference between
        // "this fired on time" and "the Mac was asleep and this is F11's
        // missed-run behaviour working", which is otherwise indistinguishable
        // from the outside.
        if lateBy > tickInterval * 2 {
            AppLog.poller.info("""
                schedules: \(schedule.action.rawValue, privacy: .public) is \(Int(lateBy))s late \
                for a scheduled run - catching up now.
                """)
        }
        execute(schedule, occurrence: occurrence)
    }

    /// The row's "Run now" action. Passes no occurrence, so a manual run never
    /// satisfies a scheduled one - tonight's 02:00 still happens.
    func runNow(_ schedule: AutomationSchedule) {
        guard !isRunning else { return }
        execute(schedule, occurrence: nil)
    }

    var isBusy: Bool { isRunning }

    /// The schedule currently running, for the card's "Running…" row state.
    private(set) var runningScheduleID: UUID?

    private func execute(_ schedule: AutomationSchedule, occurrence: Date?) {
        isRunning = true
        runStartedAt = Date()
        runningScheduleID = schedule.id
        ServiceHealthRegistry.shared.markRunning(.scheduledAutomations)
        onRunStateChanged?(schedule.id)
        AppLog.poller.info("schedules: running \(schedule.action.rawValue, privacy: .public)")

        let action = schedule.action
        let stores = backupStores
        queue.async { [weak self] in
            let result = ScheduleActions.run(action, backupStores: stores)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.runStartedAt = nil
                self.runningScheduleID = nil

                let record = ScheduleRunRecord(verdict: result.verdict, summary: result.summary, at: Date())
                self.store?.recordRun(id: schedule.id, occurrence: occurrence, record: record)

                switch result.verdict {
                case .failed:
                    ServiceHealthRegistry.shared.recordFailure(
                        .scheduledAutomations, "\(action.title): \(result.summary)")
                case .clean, .changed:
                    ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations)
                }

                NotificationSources.setScheduleResult(
                    scheduleID: schedule.id,
                    action: action,
                    verdict: result.verdict,
                    summary: result.summary,
                    notifyOn: schedule.notifyOn
                ) { [weak self] in self?.onNavigateToSchedules?() }

                self.onRunStateChanged?(schedule.id)
            }
        }
    }
}

// MARK: - The actions themselves

/// The `switch` from a schedulable action to the real, already-existing call.
///
/// Kept separate from the runner (and from any view) so a self-test can reason
/// about the mapping without a timer, and so it is obvious at a glance that
/// every arm here is a call into existing code rather than new behaviour.
///
/// Every function here runs on a background queue - none of them touch AppKit.
enum ScheduleActions {

    static func run(_ action: ScheduledActionKind,
                    backupStores: (hosts: HostStore, keys: SSHKeyStore, snippets: SnippetStore, dictation: DictationStore)?) -> ScheduleActionResult {
        switch action {
        case .driftCheck: return driftCheck()
        case .toolUpdateCheck: return toolUpdateCheck()
        case .forkSync: return forkSync()
        case .vaultRecipeExport: return vaultRecipeExport()
        case .configBackupExport: return configBackupExport(stores: backupStores)
        }
    }

    // MARK: Drift check - read-only

    /// The same inputs and the same `SetupStepChecks` predicates Bootstrap's
    /// drift card and `BackgroundSignalsPoller.checkSetupDrift` use, against a
    /// throwaway copy of the state (the convention `SetupStepChecks.swift`'s
    /// header records - never reaching into a controller's private fields).
    private static func driftCheck() -> ScheduleActionResult {
        let repoPath = DotfilesSource.resolvedDotfilesPath()
        var state: DotfilesRepoState?
        var agentItems: [AgentInstructionsItem] = []
        if let repoPath {
            state = DotfilesSource.repoState(at: repoPath)
            agentItems = DotfilesSource.agentInstructionItems(repoPath: repoPath)
        } else {
            agentItems = DotfilesSource.agentInstructionPaths.map {
                AgentInstructionsItem(label: $0.label, path: $0.path, status: .notLinked)
            }
        }
        let dotfilesDone = SetupStepChecks.dotfilesDone(isLoading: false, repoPath: repoPath, state: state) ?? false
        let agentDone = SetupStepChecks.agentInstructionsDone(isLoading: false, items: agentItems) ?? false

        guard repoPath != nil else {
            return ScheduleActionResult(
                verdict: .changed,
                summary: "~/.dotfiles was not found on this machine.")
        }
        if dotfilesDone && agentDone {
            return ScheduleActionResult(verdict: .clean, summary: "Dotfiles clean, agent instructions linked.")
        }

        var reasons: [String] = []
        if let state {
            if !state.dirtyFiles.isEmpty {
                reasons.append("\(state.dirtyFiles.count) uncommitted file\(state.dirtyFiles.count == 1 ? "" : "s")")
            }
            if let behind = state.commitsBehindOrigin, behind > 0 {
                reasons.append("\(behind) commit\(behind == 1 ? "" : "s") behind origin")
            }
        }
        if !agentDone {
            let unlinked = agentItems.filter { $0.status != .linked }.count
            reasons.append("\(unlinked) agent instruction link\(unlinked == 1 ? "" : "s") not resolving")
        }
        if reasons.isEmpty { reasons.append("drift detected") }
        return ScheduleActionResult(verdict: .changed, summary: reasons.joined(separator: ", ") + ".")
    }

    // MARK: Tool update check - read-only

    private static func toolUpdateCheck() -> ScheduleActionResult {
        let statuses = DependencyCatalog.items.map { UpdatesSource.check($0).status }
        let failed = statuses.filter { $0 == .checkFailed }.count
        let available = statuses.filter { $0.showsUpdateButton }.count
        if failed == statuses.count && !statuses.isEmpty {
            return ScheduleActionResult(verdict: .failed, summary: "Every tool check failed - is the network reachable?")
        }
        if available == 0 {
            return ScheduleActionResult(verdict: .clean, summary: "All \(statuses.count) tracked tools up to date.")
        }
        return ScheduleActionResult(
            verdict: .changed,
            summary: "\(available) of \(statuses.count) tools have an update available.")
    }

    // MARK: Fork sync - a fast-forward push, F11's stated ceiling

    /// `GitHubSyncSource.sync` only for a repo `showsSyncButton` already says is
    /// safe to fast-forward - exactly the filter `GitHubSyncController.syncAll()`
    /// applies to its own button. A diverged repo is never touched, `--force` is
    /// never passed, and none of that is relaxed here: this calls that action
    /// unchanged.
    private static func forkSync() -> ScheduleActionResult {
        var synced = 0
        var failed: [String] = []
        var diverged: [String] = []
        var checkFailed = 0

        for repo in GitHubSyncCatalog.repos {
            let outcome = GitHubSyncSource.check(repo)
            switch outcome.status {
            case .checkFailed:
                checkFailed += 1
            case .diverged:
                diverged.append(repo.name)
            default:
                guard outcome.status.showsSyncButton else { continue }
                let sync = GitHubSyncSource.sync(repo)
                if sync.ok {
                    synced += 1
                } else if sync.refusedDiverged {
                    diverged.append(repo.name)
                } else {
                    failed.append(repo.name)
                }
            }
        }

        var parts: [String] = []
        if synced > 0 { parts.append("\(synced) fork\(synced == 1 ? "" : "s") fast-forwarded") }
        if !diverged.isEmpty { parts.append("\(diverged.count) diverged, left alone (\(diverged.joined(separator: ", ")))") }
        if !failed.isEmpty { parts.append("\(failed.count) failed (\(failed.joined(separator: ", ")))") }
        if checkFailed > 0 { parts.append("\(checkFailed) could not be checked") }

        if !failed.isEmpty || (checkFailed == GitHubSyncCatalog.repos.count && checkFailed > 0) {
            return ScheduleActionResult(verdict: .failed, summary: parts.joined(separator: "; ") + ".")
        }
        if parts.isEmpty {
            return ScheduleActionResult(verdict: .clean, summary: "All \(GitHubSyncCatalog.repos.count) forks already in sync.")
        }
        return ScheduleActionResult(verdict: .changed, summary: parts.joined(separator: "; ") + ".")
    }

    // MARK: Vault recipe export - a commit + push, secret names only

    private static func vaultRecipeExport() -> ScheduleActionResult {
        guard let repoPath = VaultRecipeGit.resolveRepoPath() else {
            return ScheduleActionResult(
                verdict: .failed,
                summary: "No local manjesh-config clone found - set it up from Bootstrap's dotfiles card first.")
        }
        let snapshot = VaultSource.loadSnapshot()
        let recipe = VaultRecipe.build(from: snapshot, generatedAt: ISO8601DateFormatter().string(from: Date()))
        let result = VaultRecipeGit.export(recipe: recipe, repoPath: repoPath)
        guard result.ok else {
            return ScheduleActionResult(verdict: .failed, summary: result.message)
        }
        // `export` short-circuits with its own "nothing to push" message when
        // the recipe on disk already matches, which is the ordinary clean case
        // for a weekly schedule - not something worth notifying about.
        let unchanged = result.message.localizedCaseInsensitiveContains("nothing to push")
        return ScheduleActionResult(verdict: unchanged ? .clean : .changed, summary: result.message)
    }

    // MARK: Config backup export - a push of a .glbackup bundle

    private static func configBackupExport(stores: (hosts: HostStore, keys: SSHKeyStore, snippets: SnippetStore, dictation: DictationStore)?) -> ScheduleActionResult {
        guard let stores else {
            return ScheduleActionResult(verdict: .failed, summary: "Backup stores are not available in this process.")
        }
        guard GitHubBackupSource.isAvailable() else {
            return ScheduleActionResult(
                verdict: .failed,
                summary: "GitHub is not authenticated - run `gh auth login` so the backup can be pushed.")
        }
        // Reading the stores has to happen on the main thread: they are
        // main-thread-only by design (see `SnippetStore`'s header), and this
        // runs on a background queue. The `sync` back to main is only safe
        // because nothing on main ever waits on the runner's queue - this
        // asserts that rather than relying on it, the same way
        // `KeychainKeyStore.authenticate` guards its own thread requirement.
        dispatchPrecondition(condition: .notOnQueue(.main))
        var bundle: GrandLineBackup?
        DispatchQueue.main.sync {
            bundle = GrandLineBackupBuilder.build(
                hosts: stores.hosts.hosts,
                snippets: stores.snippets.snippets,
                allKeys: stores.keys.keys,
                dictationStore: stores.dictation)
        }
        guard let bundle else {
            return ScheduleActionResult(verdict: .failed, summary: "Could not read the local stores.")
        }
        do {
            try GitHubBackupSource.export(bundle)
        } catch {
            return ScheduleActionResult(verdict: .failed, summary: error.localizedDescription)
        }
        let hostCount = bundle.hosts.count
        let snippetCount = bundle.snippets.count
        return ScheduleActionResult(
            verdict: .changed,
            summary: "Pushed \(hostCount) host\(hostCount == 1 ? "" : "s") and \(snippetCount) snippet\(snippetCount == 1 ? "" : "s") to manjesh-config.")
    }
}
