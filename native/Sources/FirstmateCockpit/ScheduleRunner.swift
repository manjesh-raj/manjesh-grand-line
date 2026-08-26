// Manjesh Grand Line - native macOS app.
//
// F11: the scheduler. One timer, one serial queue, and a small `switch` that
// calls actions this app already had.
//
// **What this file is not.** It does not re-implement a single check. The drift
// check is `DotfilesSource` + the same `SetupStepChecks` predicates Bootstrap's
// drift card and Automation's stepper use; the tool check is `UpdatesSource.
// check`; fork sync is `GitHubSyncSource.check`/`.sync`; the recipe export is
// `VaultRecipeGit.export`; the config backup is `GitHubBackupSource.export`;
// the tool update+install (`grandline-schedule-daily-updates`, a deliberate,
// captain-approved exception to F11's original ceiling - see
// `AutomationSchedule.swift`'s header) is `UpdatesSource.check` followed by
// `UpdatesSource.update`, the exact calls the Updates page's own Check/Update
// buttons make. Every one of those already routes through the shared
// `Subprocess` runner (GL-02/GL-15), which is what F11 lists as its own
// dependency - "GL-02's bounded runner so a scheduled job can never wedge".
// Nothing here needs its own timeout because nothing here spawns its own
// process.
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
// **History.** Every run is also appended to `ScheduleRunHistoryStore`
// (`ScheduleRunHistory.swift`), a durable last-7-days log on disk - the
// browsable history behind the Schedules card's "View History..." action, and
// what `start()` replays into `ServiceHealthRegistry` at launch so a
// rebuild/relaunch does not read as "Not run yet" when a real run happened
// earlier the same session. See that file's header for why this exists at
// all (`ServiceHealthRegistry` itself has no persistence, deliberately, for
// every service except this one).
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
    /// The run's real output, for the Run History sheet's "View Log" action -
    /// composed from whichever real command output the action already had at
    /// hand (`CheckOutcome.log`/`GitHubSyncCheckOutcome.log`/
    /// `GitHubSyncSyncOutcome.log`, all of which already carry a subprocess's
    /// raw stdout/stderr for the Updates/GitHub-Sync pages' own expandable
    /// logs - see those types' own doc comments). Never fabricated: an action
    /// with nothing deeper to say (the git-plumbing actions, whose real
    /// evidence already lives in `summary`) falls back to `summary` itself
    /// rather than inventing a transcript, via the memberwise initializer
    /// below.
    let log: String

    init(verdict: ScheduleRunVerdict, summary: String, log: String? = nil) {
        self.verdict = verdict
        self.summary = summary
        self.log = log ?? summary
    }
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
    /// The stores the config-backup action needs. Injected rather than
    /// constructed here: a second `HostStore` would be a second writer to the
    /// same JSON file, which is exactly what GL-05 exists to prevent.
    private var backupStores: (hosts: HostStore, keys: SSHKeyStore, dictation: DictationStore)?
    /// The run-history sink (`ScheduleRunHistory.swift`) - injected the same
    /// way, defaulting to the real on-disk log so existing `start(...)`
    /// callers need no change.
    private var historyStore: ScheduleRunHistoryStore?

    private var calendar: Calendar = .current

    private init() {}

    // MARK: Lifecycle

    /// Safe to call once per launch.
    func start(store: ScheduleStore,
               hostStore: HostStore,
               keyStore: SSHKeyStore,
               dictationStore: DictationStore,
               historyStore: ScheduleRunHistoryStore = .shared) {
        self.store = store
        self.backupStores = (hostStore, keyStore, dictationStore)
        self.historyStore = historyStore
        guard timer == nil else { return }
        // F1: declare the row so the Health card says "not run yet" rather than
        // omitting a service that exists.
        ServiceHealthRegistry.shared.register(.scheduledAutomations)
        // Then immediately correct that default from the persisted run
        // history (`ScheduleRunHistory.swift`): a schedule that already ran
        // earlier today has nothing to make it report again until its *next*
        // occurrence, which can be nearly 24h away - so without this, a
        // rebuild/relaunch shortly after a real run left the Health card
        // reading "Not run yet" for the rest of that day even though a real
        // run had completed. `seeds(from:)` is pure and reads no clock of its
        // own, so this is a one-time replay of history, not a poll.
        for seed in ScheduleHealthSeeding.seeds(from: historyStore.allEntries()) {
            switch seed {
            case .success(let at):
                ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations, at: at)
            case .failure(let detail, let at):
                ServiceHealthRegistry.shared.recordFailure(.scheduledAutomations, detail, at: at)
            }
        }
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
                // F11's run history: kept separately from `record` above
                // (which `ScheduleStore` only ever remembers the latest one
                // of) so a schedule's last 7 days are browsable and so a
                // fresh launch can reconstruct `.scheduledAutomations`'s true
                // state - see `ScheduleRunHistory.swift`'s header.
                self.historyStore?.append(ScheduleRunHistoryEntry(
                    scheduleID: schedule.id,
                    at: record.at,
                    verdict: result.verdict,
                    summary: result.summary,
                    actionTitle: action.title,
                    log: result.log))

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
                    backupStores: (hosts: HostStore, keys: SSHKeyStore, dictation: DictationStore)?) -> ScheduleActionResult {
        switch action {
        case .driftCheck: return driftCheck()
        case .toolUpdateCheck: return toolUpdateCheck()
        case .forkSync: return forkSync()
        case .vaultRecipeExport: return vaultRecipeExport()
        case .configBackupExport: return configBackupExport(stores: backupStores)
        case .toolUpdateInstall: return toolUpdateInstall()
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
        let log = driftCheckLog(repoPath: repoPath, state: state, agentItems: agentItems)

        guard repoPath != nil else {
            return ScheduleActionResult(
                verdict: .changed,
                summary: "~/.dotfiles was not found on this machine.",
                log: log)
        }
        if dotfilesDone && agentDone {
            return ScheduleActionResult(verdict: .clean, summary: "Dotfiles clean, agent instructions linked.", log: log)
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
        return ScheduleActionResult(verdict: .changed, summary: reasons.joined(separator: ", ") + ".", log: log)
    }

    /// A readable transcript of exactly what the drift check looked at, for
    /// the Run History sheet's "View Log" action. Not raw `git` stdout - this
    /// check is composed from `DotfilesSource`'s own already-structured
    /// state, the same real repo/agent-item data the Bootstrap drift card
    /// renders, rather than a subprocess this file calls directly.
    private static func driftCheckLog(repoPath: String?, state: DotfilesRepoState?,
                                       agentItems: [AgentInstructionsItem]) -> String {
        var lines: [String] = ["Dotfiles repo: \(repoPath ?? "not found on this machine")"]
        if let state {
            lines.append("Remote: \(state.remoteURL ?? "unknown")")
            lines.append("Branch: \(state.branch ?? "unknown")")
            if state.dirtyFiles.isEmpty {
                lines.append("Working tree: clean")
            } else {
                lines.append("Uncommitted files (\(state.dirtyFiles.count)):")
                lines.append(contentsOf: state.dirtyFiles.map { "  \($0)" })
            }
            if let behind = state.commitsBehindOrigin {
                lines.append("Commits behind origin: \(behind)")
                if let commits = state.commitsBehindOriginList {
                    lines.append(contentsOf: commits.map { "  \($0.shortHash) \($0.subject)" })
                }
            } else {
                lines.append("Commits behind origin: unknown (no network, no remote, or the fetch failed)")
            }
        }
        lines.append("")
        lines.append("Agent instruction links:")
        for item in agentItems {
            let status: String
            switch item.status {
            case .linked: status = "linked"
            case .notLinked: status = "not linked"
            case .wrongTarget(let target): status = "wrong target (\(target))"
            }
            lines.append("  \(item.label) (\(item.path)): \(status)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tool update check - read-only

    private static func toolUpdateCheck() -> ScheduleActionResult {
        let outcomes = DependencyCatalog.items.map { (item: $0, outcome: UpdatesSource.check($0)) }
        let statuses = outcomes.map { $0.outcome.status }
        let failed = statuses.filter { $0 == .checkFailed }.count
        let available = statuses.filter { $0.showsUpdateButton }.count
        let log = perToolLog(outcomes)
        if failed == statuses.count && !statuses.isEmpty {
            return ScheduleActionResult(verdict: .failed, summary: "Every tool check failed - is the network reachable?", log: log)
        }
        if available == 0 {
            return ScheduleActionResult(verdict: .clean, summary: "All \(statuses.count) tracked tools up to date.", log: log)
        }
        return ScheduleActionResult(
            verdict: .changed,
            summary: "\(available) of \(statuses.count) tools have an update available.",
            log: log)
    }

    /// One block per tool - name, the same one-line detail the Updates page's
    /// own row subtitle shows, and `CheckOutcome.log`'s real command output
    /// (npm/brew/herdr/etc. stdout+stderr) when there is any. This is the
    /// exact evidence `CheckOutcome.log`'s own doc comment says every action
    /// should surface, just persisted here instead of shown only in a
    /// session-only expandable row.
    private static func perToolLog(_ outcomes: [(item: DependencyItem, outcome: CheckOutcome)]) -> String {
        outcomes.map { entry in
            var block = "\(entry.item.name): \(entry.outcome.detail)"
            if !entry.outcome.log.isEmpty { block += "\n\(entry.outcome.log)" }
            return block
        }.joined(separator: "\n\n")
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
        var logBlocks: [String] = []

        for repo in GitHubSyncCatalog.repos {
            let outcome = GitHubSyncSource.check(repo)
            // One block per repo, appended once below regardless of which
            // branch runs - the check's own detail/log, plus the sync's when
            // one was attempted, so a captain reading "View Log" sees exactly
            // what `gh api`/`gh repo sync` reported for every repo, not only
            // the ones that ended up in `failed`/`diverged`.
            var block = "\(repo.name): \(outcome.detail)"
            if !outcome.log.isEmpty { block += "\n\(outcome.log)" }
            switch outcome.status {
            case .checkFailed:
                checkFailed += 1
            case .diverged:
                diverged.append(repo.name)
            default:
                if outcome.status.showsSyncButton {
                    let sync = GitHubSyncSource.sync(repo)
                    block += "\n\u{2192} sync: \(sync.detail)"
                    if !sync.log.isEmpty { block += "\n\(sync.log)" }
                    if sync.ok {
                        synced += 1
                    } else if sync.refusedDiverged {
                        diverged.append(repo.name)
                    } else {
                        failed.append(repo.name)
                    }
                }
            }
            logBlocks.append(block)
        }

        var parts: [String] = []
        if synced > 0 { parts.append("\(synced) fork\(synced == 1 ? "" : "s") fast-forwarded") }
        if !diverged.isEmpty { parts.append("\(diverged.count) diverged, left alone (\(diverged.joined(separator: ", ")))") }
        if !failed.isEmpty { parts.append("\(failed.count) failed (\(failed.joined(separator: ", ")))") }
        if checkFailed > 0 { parts.append("\(checkFailed) could not be checked") }
        let log = logBlocks.joined(separator: "\n\n")

        if !failed.isEmpty || (checkFailed == GitHubSyncCatalog.repos.count && checkFailed > 0) {
            return ScheduleActionResult(verdict: .failed, summary: parts.joined(separator: "; ") + ".", log: log)
        }
        if parts.isEmpty {
            return ScheduleActionResult(verdict: .clean, summary: "All \(GitHubSyncCatalog.repos.count) forks already in sync.", log: log)
        }
        return ScheduleActionResult(verdict: .changed, summary: parts.joined(separator: "; ") + ".", log: log)
    }

    // MARK: Vault recipe export - a commit + push, secret names only

    private static func vaultRecipeExport() -> ScheduleActionResult {
        guard let repoPath = VaultRecipeGit.resolveRepoPath() else {
            return ScheduleActionResult(
                verdict: .failed,
                summary: "No local manjesh-config clone found - set it up from Bootstrap's dotfiles card first.")
        }
        let snapshot = VaultSource.loadSnapshot()
        // H1/B1: the same guard the two manual export paths carry
        // (`VaultController.exportRecipeTapped`). A degraded snapshot means the
        // `av` read failed, and `VaultRecipe.build`'s `?? []` would turn that
        // into a recipe asserting this machine has zero secrets and zero
        // hardened launchers - which this action then commits and pushes to the
        // private config repo, unattended. A weekly schedule is exactly when the
        // approval helper is most likely wedged (after sleep), so this guard
        // matters more here than on the button the captain is watching.
        guard !snapshot.isDegraded else {
            return ScheduleActionResult(
                verdict: .failed,
                summary: "Couldn\u{2019}t read Automic Vault, so nothing was exported - a recipe built from a failed read would claim this machine has no secrets.")
        }
        let recipe = VaultRecipe.build(from: snapshot, generatedAt: ISO8601DateFormatter().string(from: Date()))
        let result = VaultRecipeGit.export(recipe: recipe, repoPath: repoPath)
        // `VaultRecipeExportResult` has no deeper per-command log of its own
        // (unlike the Updates/GitHub-Sync outcomes) - `message` already *is*
        // the real evidence here, just with the repo/file path it was
        // evaluated against alongside it.
        let log = "Repo: \(repoPath)\nRecipe file: \(result.filePath ?? "n/a")\n\n\(result.message)"
        guard result.ok else {
            return ScheduleActionResult(verdict: .failed, summary: result.message, log: log)
        }
        // `export` short-circuits with its own "nothing to push" message when
        // the recipe on disk already matches, which is the ordinary clean case
        // for a weekly schedule - not something worth notifying about.
        let unchanged = result.message.localizedCaseInsensitiveContains("nothing to push")
        return ScheduleActionResult(verdict: unchanged ? .clean : .changed, summary: result.message, log: log)
    }

    // MARK: Config backup export - a push of a .glbackup bundle

    private static func configBackupExport(stores: (hosts: HostStore, keys: SSHKeyStore, dictation: DictationStore)?) -> ScheduleActionResult {
        guard let stores else {
            return ScheduleActionResult(verdict: .failed, summary: "Backup stores are not available in this process.")
        }
        guard GitHubBackupSource.isAvailable() else {
            return ScheduleActionResult(
                verdict: .failed,
                summary: "GitHub is not authenticated - run `gh auth login` so the backup can be pushed.")
        }
        // Reading the stores has to happen on the main thread: they are
        // main-thread-only by design, and this
        // runs on a background queue. The `sync` back to main is only safe
        // because nothing on main ever waits on the runner's queue - this
        // asserts that rather than relying on it, the same way
        // `KeychainKeyStore.authenticate` guards its own thread requirement.
        dispatchPrecondition(condition: .notOnQueue(.main))
        var bundle: GrandLineBackup?
        DispatchQueue.main.sync {
            bundle = GrandLineBackupBuilder.build(
                hosts: stores.hosts.hosts,
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
        return ScheduleActionResult(
            verdict: .changed,
            summary: "Pushed \(hostCount) host\(hostCount == 1 ? "" : "s") to manjesh-config.")
    }

    // MARK: Tool update check + install - captain-approved, no confirmation

    /// The captain's explicit override of F11's original exclusion of
    /// `UpdatesSource.update` - see `AutomationSchedule.swift`'s header and
    /// `ScheduledActionKind.toolUpdateInstall`'s doc comment for the decision
    /// record. Calls the exact same `UpdatesSource.check`/`.update` the
    /// Updates page's own Check/Update buttons call, for every
    /// `DependencyCatalog` item - never a reimplementation, and never
    /// relaxing what those calls themselves do (every update remains
    /// whatever `UpdatesSource.update` already does for that tool: `brew
    /// upgrade`/`npm -g install`/herdr's own updater/no-mistakes' own
    /// updater/firstmate's fetch-merge-push script).
    ///
    /// **The one distinction this keeps from before the override.** A
    /// `.notInstalled` tool is never touched here, matching Updates' own
    /// "Install in Bootstrap \u{2192}" routing for that exact status (see
    /// `UpdatesController`'s history in AGENTS.md) - installing something
    /// that was never there is a materially different action from updating
    /// something already present, and this app already treats a fresh
    /// install as needing a human everywhere else. A `.checkFailed` tool is
    /// left alone too: its check never established there was an update to
    /// install, so calling `update()` on it would be a guess, not a response
    /// to something found. Only `.updateAvailable` is acted on.
    private static func toolUpdateInstall() -> ScheduleActionResult {
        var installed: [String] = []
        var updateFailed: [String] = []
        var needsManualInstall = 0
        var checkFailed = 0
        var logBlocks: [String] = []

        for item in DependencyCatalog.items {
            let outcome = UpdatesSource.check(item)
            var block = "\(item.name): \(outcome.detail)"
            if !outcome.log.isEmpty { block += "\n\(outcome.log)" }
            switch outcome.status {
            case .updateAvailable:
                let update = UpdatesSource.update(item)
                block += "\n\u{2192} update: \(update.detail)"
                if !update.log.isEmpty { block += "\n\(update.log)" }
                if update.ok {
                    installed.append(item.name)
                } else {
                    updateFailed.append(item.name)
                }
            case .notInstalled:
                needsManualInstall += 1
            case .checkFailed:
                checkFailed += 1
            case .upToDate:
                break
            case .checking, .updating, .unknown, .updateFailed:
                // `UpdatesSource.check` never actually returns these - they
                // are UI-only session states `UpdatesController` tracks on
                // top of a `CheckOutcome` - but the switch stays exhaustive
                // rather than a `default:` so a status this call *could*
                // someday return has to be deliberately placed here too.
                break
            }
            logBlocks.append(block)
        }
        let log = logBlocks.joined(separator: "\n\n")

        if checkFailed == DependencyCatalog.items.count && !DependencyCatalog.items.isEmpty {
            return ScheduleActionResult(verdict: .failed, summary: "Every tool check failed - is the network reachable?", log: log)
        }

        var parts: [String] = []
        if !installed.isEmpty {
            parts.append("\(installed.count) tool\(installed.count == 1 ? "" : "s") updated (\(installed.joined(separator: ", ")))")
        }
        if !updateFailed.isEmpty {
            parts.append("\(updateFailed.count) update\(updateFailed.count == 1 ? "" : "s") failed (\(updateFailed.joined(separator: ", ")))")
        }
        if needsManualInstall > 0 {
            parts.append("\(needsManualInstall) tool\(needsManualInstall == 1 ? "" : "s") not installed - see Bootstrap")
        }
        if checkFailed > 0 {
            parts.append("\(checkFailed) could not be checked")
        }

        if !updateFailed.isEmpty {
            return ScheduleActionResult(verdict: .failed, summary: parts.joined(separator: "; ") + ".", log: log)
        }
        if parts.isEmpty {
            return ScheduleActionResult(verdict: .clean, summary: "All \(DependencyCatalog.items.count) tracked tools up to date.", log: log)
        }
        return ScheduleActionResult(verdict: .changed, summary: parts.joined(separator: "; ") + ".", log: log)
    }
}
