// Grand Line - native macOS app.
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
    /// Why it did not finish, in three plain-English fields. Required for
    /// `.failed` and `.partial`; `nil` for the three successes.
    ///
    /// The two initialisers below are what make that a rule rather than a
    /// hope: there is no way to construct a failing result without supplying
    /// one, so a future failure path cannot quietly ship
    /// `error.localizedDescription` the way `configBackupExport` once did.
    let failure: ScheduleFailureExplanation?

    /// A successful result. Callable only with a verdict that succeeded.
    init(verdict: ScheduleRunVerdict, summary: String, log: String? = nil) {
        precondition(verdict.succeeded,
                     "a non-succeeding verdict needs ScheduleActionResult(failing:...) and an explanation")
        self.verdict = verdict
        self.summary = summary
        self.log = log ?? summary
        self.failure = nil
    }

    /// A `.failed` or `.partial` result, which cannot be built without saying
    /// what failed, why, and what the captain can do about it.
    init(failing verdict: ScheduleRunVerdict,
         summary: String,
         whatFailed: String,
         why: String,
         whatToDo: String,
         log: String? = nil) {
        precondition(!verdict.succeeded, "use the plain initializer for a succeeding verdict")
        self.verdict = verdict
        self.summary = summary
        self.log = log ?? summary
        self.failure = ScheduleFailureExplanation(whatFailed: whatFailed, why: why, whatToDo: whatToDo)
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
    private let queue = DispatchQueue(label: "com.manjesh.grandline.schedule-runner", qos: .utility)

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
               snippetStore: SnippetStore,
               dictationStore: DictationStore,
               historyStore: ScheduleRunHistoryStore = .shared) {
        self.store = store
        self.backupStores = (hostStore, keyStore, snippetStore, dictationStore)
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

                let record = ScheduleRunRecord(verdict: result.verdict, summary: result.summary,
                                               at: Date(), failure: result.failure)
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
                    log: result.log,
                    failure: result.failure))

                // `.partial` reports as a failure here, matching
                // `ScheduleHealthSeeding.seeds`: a run that could not
                // establish half its own result is not a healthy run, and
                // `verdict.succeeded` is the single place that judgement
                // lives.
                if result.verdict.succeeded {
                    ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations)
                } else {
                    ServiceHealthRegistry.shared.recordFailure(
                        .scheduledAutomations, "\(action.title): \(result.summary)")
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

    /// How a tool sweep's own counts become a verdict, as pure arithmetic.
    ///
    /// Extracted from `toolUpdateCheck`/`toolUpdateInstall` so the rule can be
    /// tested without a network, which is the only reason the defect it
    /// encodes survived as long as it did: both call sites reached it through
    /// a `UpdatesSource.check` per tool, so no suite could exercise the
    /// branch at all and the `.clean` arm was never once evaluated against a
    /// partly-failed sweep.
    ///
    /// **The rule.** All checks failed is a failure. *Some* checks failed is
    /// `.partial` - never `.clean`, which is what it used to be, and which
    /// made a run where 7 of 8 checks failed report "All 8 tracked tools up
    /// to date" (GL-14: "Unknown is never rendered as zero. A failed fetch
    /// and an empty result are different states"). Everything checked and
    /// nothing to do is `.clean`.
    static func toolSweepVerdict(total: Int, checkFailed: Int, actionable: Int) -> ScheduleRunVerdict {
        if total > 0 && checkFailed == total { return .failed }
        if checkFailed > 0 { return .partial }
        return actionable > 0 ? .foundSomething : .clean
    }

    static func run(_ action: ScheduledActionKind,
                    backupStores: (hosts: HostStore, keys: SSHKeyStore, snippets: SnippetStore, dictation: DictationStore)?) -> ScheduleActionResult {
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
            // `.partial`, not a finding: the check could not run at all, so it
            // established nothing about drift either way. Reporting this as
            // "found something" would claim a result it never had.
            return ScheduleActionResult(
                failing: .partial,
                summary: "~/.dotfiles was not found on this machine, so nothing could be checked.",
                whatFailed: "The drift check couldn\u{2019}t look at your dotfiles.",
                why: "There is no ~/.dotfiles folder on this Mac, so there was nothing to compare against.",
                whatToDo: "Open Bootstrap and use its dotfiles card to clone the repo, then run this schedule again.",
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
        return ScheduleActionResult(verdict: .foundSomething,
                                    summary: reasons.joined(separator: ", ") + ".", log: log)
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
        switch toolSweepVerdict(total: statuses.count, checkFailed: failed, actionable: available) {
        case .failed:
            return ScheduleActionResult(
                failing: .failed,
                summary: "Every tool check failed - is the network reachable?",
                whatFailed: "None of the \(statuses.count) tracked tools could be checked.",
                why: "Every single check failed, which almost always means this Mac had no working network connection when the schedule ran.",
                whatToDo: "Check your connection and run this schedule again from its row. Nothing was installed or changed.",
                log: log)
        case .partial:
            let checked = statuses.count - failed
            var summary = "\(failed) of \(statuses.count) tools couldn\u{2019}t be checked"
            summary += available > 0
                ? "; \(available) of the \(checked) that could have an update available."
                : "; the \(checked) that could are up to date."
            return ScheduleActionResult(
                failing: .partial,
                summary: summary,
                whatFailed: "\(failed) of the \(statuses.count) tracked tools couldn\u{2019}t be checked for updates.",
                why: "Those checks failed to return a version. The usual cause is no network, or the tool\u{2019}s own package manager being unavailable.",
                whatToDo: "Open Updates to see which tools are affected and check them by hand. The \(checked) that did report are accurate.",
                log: log)
        case .clean:
            return ScheduleActionResult(verdict: .clean, summary: "All \(statuses.count) tracked tools up to date.", log: log)
        case .foundSomething, .didWork:
            return ScheduleActionResult(
                verdict: .foundSomething,
                summary: "\(available) of \(statuses.count) tools have an update available.",
                log: log)
        }
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

        let summary = parts.joined(separator: "; ") + "."
        if !failed.isEmpty || (checkFailed == GitHubSyncCatalog.repos.count && checkFailed > 0) {
            return ScheduleActionResult(
                failing: .failed,
                summary: summary,
                whatFailed: failed.isEmpty
                    ? "None of the \(GitHubSyncCatalog.repos.count) forks could be checked."
                    : "\(failed.count) fork\(failed.count == 1 ? "" : "s") couldn\u{2019}t be brought up to date: \(failed.joined(separator: ", ")).",
                why: failed.isEmpty
                    ? "Every check failed to reach GitHub, which usually means no network or an expired gh login."
                    : "The fast-forward was refused by GitHub. The log below has what gh reported for each one.",
                whatToDo: "Open GitHub Sync and try those repos by hand. Nothing was force-pushed, so no history was rewritten.",
                log: log)
        }
        // Some forks were checked and some were not: honest partial rather
        // than a clean claim about repos nobody looked at.
        if checkFailed > 0 {
            return ScheduleActionResult(
                failing: .partial,
                summary: summary,
                whatFailed: "\(checkFailed) of the \(GitHubSyncCatalog.repos.count) forks couldn\u{2019}t be checked.",
                why: "Those checks did not get an answer from GitHub. The rest were checked normally.",
                whatToDo: "Open GitHub Sync to check the affected forks by hand. Whatever this run did report is accurate.",
                log: log)
        }
        if parts.isEmpty {
            return ScheduleActionResult(verdict: .clean, summary: "All \(GitHubSyncCatalog.repos.count) forks already in sync.", log: log)
        }
        // Real work happened and none of it is the captain's to follow up -
        // `.didWork`, not an FYI. A diverged fork is the one thing here that
        // genuinely wants a human, so it is what tips this to `.foundSomething`.
        return ScheduleActionResult(verdict: diverged.isEmpty ? .didWork : .foundSomething,
                                    summary: summary, log: log)
    }

    // MARK: Vault recipe export - a commit + push, secret names only
    //
    // This is the **one sanctioned unattended `av list`** in the app, and it is
    // an exception to the rule `VaultData.swift`'s "approval-prompt split"
    // block states, so it is written down here rather than left to be
    // rediscovered. `av list` can raise Automic Vault's own approval dialog,
    // which is why nothing on a timer may call it - but this action's entire
    // content *is* the list of secret names, so there is no approval-free read
    // that could produce it, and dropping the call would delete the feature
    // rather than fix anything. What makes it defensible where the poller's
    // was not: this runs only for a schedule the captain created and enabled
    // themselves, at a cadence they chose, and it is listed on the Schedules
    // page with its next run time - so a prompt from it is attributable, which
    // is exactly what the poller's was not.

    private static func vaultRecipeExport() -> ScheduleActionResult {
        guard let repoPath = VaultRecipeGit.resolveRepoPath() else {
            return ScheduleActionResult(
                failing: .failed,
                summary: "No local manjesh-config clone found - set it up from Bootstrap's dotfiles card first.",
                whatFailed: "The vault recipe couldn\u{2019}t be exported.",
                why: "There is no local clone of the manjesh-config repo on this Mac to write the recipe into.",
                whatToDo: "Open Bootstrap and set up the dotfiles card, which clones manjesh-config, then run this schedule again.")
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
                failing: .failed,
                summary: "Couldn\u{2019}t read Automic Vault, so nothing was exported - a recipe built from a failed read would claim this machine has no secrets.",
                whatFailed: "The vault recipe couldn\u{2019}t be exported.",
                why: "Automic Vault didn\u{2019}t answer, so the list of secret names came back empty. Exporting that would have published a recipe claiming this Mac holds no secrets at all.",
                whatToDo: "Nothing was written, so nothing is wrong in the repo. Open Poneglyph to check Automic Vault is responding, then run this schedule again.")
        }
        let recipe = VaultRecipe.build(from: snapshot, generatedAt: ISO8601DateFormatter().string(from: Date()))
        let result = VaultRecipeGit.export(recipe: recipe, repoPath: repoPath)
        // `VaultRecipeExportResult` has no deeper per-command log of its own
        // (unlike the Updates/GitHub-Sync outcomes) - `message` already *is*
        // the real evidence here, just with the repo/file path it was
        // evaluated against alongside it.
        let log = "Repo: \(repoPath)\nRecipe file: \(result.filePath ?? "n/a")\n\n\(result.message)"
        guard result.ok else {
            return ScheduleActionResult(
                failing: .failed,
                summary: result.message,
                whatFailed: "The vault recipe couldn\u{2019}t be committed and pushed to manjesh-config.",
                why: result.message,
                whatToDo: "Open Poneglyph and export the recipe by hand to see the full error. No secret value was ever read, stored or sent.",
                log: log)
        }
        // `export` short-circuits with its own "nothing to push" message when
        // the recipe on disk already matches, which is the ordinary clean case
        // for a weekly schedule - not something worth notifying about.
        let unchanged = result.message.localizedCaseInsensitiveContains("nothing to push")
        // An export that pushed did the job it exists for. Nothing here is the
        // captain's to act on, which is exactly the distinction `.didWork`
        // was added to carry.
        return ScheduleActionResult(verdict: unchanged ? .clean : .didWork, summary: result.message, log: log)
    }

    // MARK: Config backup export - a push of a .glbackup bundle

    private static func configBackupExport(stores: (hosts: HostStore, keys: SSHKeyStore, snippets: SnippetStore, dictation: DictationStore)?) -> ScheduleActionResult {
        guard let stores else {
            return ScheduleActionResult(
                failing: .failed,
                summary: "The app\u{2019}s data stores weren\u{2019}t ready, so there was nothing to back up.",
                whatFailed: "The config backup didn\u{2019}t run.",
                why: "Grand Line\u{2019}s hosts, snippets and preferences weren\u{2019}t loaded yet when the schedule fired, so there was nothing to package up.",
                whatToDo: "Run this schedule again from its row now that the app is up. If it keeps happening at the same time every night, move the schedule a few minutes later.")
        }
        guard GitHubBackupSource.isAvailable() else {
            return ScheduleActionResult(
                failing: .failed,
                summary: "GitHub is not authenticated - run `gh auth login` so the backup can be pushed.",
                whatFailed: "The backup couldn\u{2019}t be pushed to GitHub.",
                why: "This Mac isn\u{2019}t signed in to GitHub, so the push had nowhere to authenticate to.",
                whatToDo: "Run `gh auth login` in a Console tab, then run this schedule again from its row.")
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
            return ScheduleActionResult(
                failing: .failed,
                summary: "Couldn\u{2019}t read this Mac\u{2019}s hosts, snippets and preferences, so no backup was made.",
                whatFailed: "The config backup didn\u{2019}t run.",
                why: "Building the backup bundle from the local stores returned nothing.",
                whatToDo: "Open Settings and use the Backup card to export by hand, which reports the underlying error directly.")
        }
        do {
            try GitHubBackupSource.export(bundle)
        } catch {
            // This used to hand the captain `error.localizedDescription`
            // verbatim, which for `GitHubBackupError.notConfigured` reads
            // "Could not determine the GitHub repo from
            // DotfilesSource.cloneURL." - a Swift symbol name. The thrown
            // text is still the most accurate thing anyone knows about *why*,
            // so it stays as the `why`; what it may never be again is the
            // whole answer.
            return ScheduleActionResult(
                failing: .failed,
                summary: "The backup couldn\u{2019}t be pushed to GitHub.",
                whatFailed: "The backup couldn\u{2019}t be pushed to GitHub.",
                why: error.localizedDescription,
                whatToDo: "Open Settings and use the Backup card to export by hand - it runs the same push and shows the error in full. Nothing on GitHub was changed.")
        }
        let hostCount = bundle.hosts.count
        let snippetCount = bundle.snippets.count
        let summary = "Pushed \(hostCount) host\(hostCount == 1 ? "" : "s") and \(snippetCount) snippet\(snippetCount == 1 ? "" : "s") to manjesh-config."
        // Labels only - never a command body or a credential (`GitHubBackupSource
        // .export` already redacts private key bytes/passphrases from the
        // bundle itself; this log just names what was in it).
        let log = summary
            + "\nHosts: \(bundle.hosts.map { $0.label }.joined(separator: ", "))"
            + "\nSnippets: \(bundle.snippets.map { $0.label }.joined(separator: ", "))"
        // **Defect 1's fix.** This returned `.changed` on every successful
        // export and had no `.clean` path at all, so a nightly backup sat
        // under "Needs you" - counted in the attention tile, chipped "Needs
        // Attention" in Run History - every night, forever, for doing exactly
        // its job. A push is real work that is none of the captain's
        // business, which is `.didWork`.
        return ScheduleActionResult(verdict: .didWork, summary: summary, log: log)
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
            return ScheduleActionResult(
                failing: .failed,
                summary: "Every tool check failed - is the network reachable?",
                whatFailed: "None of the \(DependencyCatalog.items.count) tracked tools could be checked, so nothing was updated.",
                why: "Every single check failed, which almost always means this Mac had no working network connection when the schedule ran.",
                whatToDo: "Check your connection and run this schedule again from its row. Nothing was installed or changed.",
                log: log)
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

        let summary = parts.joined(separator: "; ") + "."
        if !updateFailed.isEmpty {
            return ScheduleActionResult(
                failing: .failed,
                summary: summary,
                whatFailed: "\(updateFailed.count) tool\(updateFailed.count == 1 ? "" : "s") couldn\u{2019}t be updated: \(updateFailed.joined(separator: ", ")).",
                why: "The update itself was attempted and did not succeed. The log below has exactly what each tool\u{2019}s installer reported.",
                whatToDo: "Open Updates and update those tools by hand. \(installed.isEmpty ? "Nothing else was changed." : "The \(installed.count) that did update are already done.")",
                log: log)
        }
        // Same GL-14 fix as the read-only check: some tools genuinely could
        // not be checked, so this run does not get to claim anything about
        // them either way.
        if checkFailed > 0 {
            return ScheduleActionResult(
                failing: .partial,
                summary: summary,
                whatFailed: "\(checkFailed) of the \(DependencyCatalog.items.count) tracked tools couldn\u{2019}t be checked.",
                why: "Those checks failed to return a version, so nothing was installed for them. The usual cause is no network, or the tool\u{2019}s own package manager being unavailable.",
                whatToDo: "Open Updates to see which tools are affected. Whatever this run did install is already done.",
                log: log)
        }
        if parts.isEmpty {
            return ScheduleActionResult(verdict: .clean, summary: "All \(DependencyCatalog.items.count) tracked tools up to date.", log: log)
        }
        // Installing an update is the job this action exists for. A tool that
        // needs a manual install in Bootstrap is the one thing here the
        // captain has to act on, so that is what makes it an FYI.
        return ScheduleActionResult(verdict: needsManualInstall > 0 ? .foundSomething : .didWork,
                                    summary: summary, log: log)
    }
}
