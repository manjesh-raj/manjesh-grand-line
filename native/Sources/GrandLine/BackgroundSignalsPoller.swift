// Grand Line - native macOS app.
//
// Background poll (`fm/grandline-notification-center`) for the four
// Notification Center signals that, before this task, only ever recomputed
// on an explicit page visit: tool updates (Updates page), fork drift
// (GitHub Sync page), Vault attention, and Bootstrap's own setup-drift
// check. Every one of these already has a real, non-duplicated check
// function (`UpdatesSource.check`, `GitHubSyncSource.check`,
// `VaultSource.loadSnapshot`, `SetupStepChecks.*`) - this file only owns
// *when* to call them for the purpose of keeping the in-app Notification
// Center current, never a second implementation of what "needs attention"
// means for any of them.
//
// Cadence tradeoff (the design doc flagged exactly this as worth a
// deliberate decision, not a default): these checks shell out to `brew`/
// `npm`/`gh api`/`av` once per catalog item/repo/tool - `FleetNotifier`'s
// 30s cadence would mean dozens of process spawns every half-minute even
// while the captain is looking at something else entirely, which is a real
// background cost for signals that change on the order of hours, not
// seconds (a tool doesn't get a new release, a fork doesn't fall behind,
// every 30 seconds). This poller runs every 15 minutes instead - "no dead/
// excessive polling" per this app's own standing bar, while still staying
// materially fresher than "only when you happen to open that page." Each
// of the four pages' own on-visit checks are unaffected and still run
// independently at their existing cadence (page visit / manual refresh) -
// this poller exists purely so the notification center doesn't go stale
// between visits, not to replace those pages' own logic. The tool-update
// sweep reads through the shared `DependencyCheckCache` those pages already
// use, so "independently" means "on its own cadence", not "at its own extra
// subprocess cost" - see `sharedCheckMaxAge`.
//
// All four checks run sequentially on one background queue, not
// concurrently - mirrors `BootstrapController.installAllMissing`'s own
// "never race two package-manager invocations against each other" caution,
// generalized here since `brew`/`npm`/`av` can all be invoked across the
// four checks.

import Foundation

final class BackgroundSignalsPoller {
    static let shared = BackgroundSignalsPoller()

    /// 15 minutes - see the file header for the reasoning.
    ///
    /// `static` so `sharedCheckMaxAge` below (and the self-test that guards
    /// the relationship between them) can be written in terms of it rather
    /// than repeating the literal.
    static let pollInterval: TimeInterval = 15 * 60

    /// How old a shared `DependencyCheckCache` entry may be and still satisfy
    /// **this poller's** sweep. Deliberately not `DependencyCheckCache.
    /// defaultTTL`, which is what the three Setup pages use.
    ///
    /// The fix this exists for is that the poller used to call
    /// `UpdatesSource.check` directly, so a captain who opened Updates and
    /// then sat still paid for the identical 13-item sweep twice within
    /// minutes. Reading through the shared cache closes that - but the window
    /// has to be short enough that **one poller pass can never be satisfied by
    /// the previous poller pass**, or this quietly becomes a staleness cache
    /// rather than a coalescer and the poller's effective cadence halves.
    ///
    /// The worst case is an entry written by the *last* item of a slow sweep:
    /// it is only `pollInterval - (sweep duration)` old when the next tick
    /// lands, and a sweep may legitimately run until `passWatchdog`. So this
    /// must stay below `pollInterval - passWatchdog` (10 minutes) with room to
    /// spare; 5 minutes is that, and is still comfortably wider than "the
    /// captain opened a Setup page moments ago", which is the whole scenario
    /// being deduplicated. `AuditEnergyFixesSelfTest`'s own
    /// `FleetTaskCache.ttl < FleetNotifier.pollInterval / 2` check is the same
    /// guard for the same class of mistake; ours lives in
    /// `DependencyCheckCacheSelfTest`.
    ///
    /// The price, stated rather than hidden: the poller's published counts can
    /// now be up to `pollInterval + sharedCheckMaxAge` (20 minutes) old rather
    /// than 15. That sits inside the envelope this file's own header already
    /// accepts for a backgrounded app ("your tools are 25 minutes out of date
    /// rather than 15 is not a cost anyone can perceive"), and the publish
    /// carries the honest `gatheredAt` either way - see `checkNow`.
    static let sharedCheckMaxAge: TimeInterval = 5 * 60

    /// E3: the heaviest pass in the report's table by a wide margin - tool
    /// checks (`npm`/`brew` per catalog item), fork drift (`gh api`/git x8),
    /// vault (`av`), setup drift (a `git fetch` on the dotfiles clone), i.e.
    /// ~60 subprocesses and real network. While the app has been backgrounded
    /// for >5 minutes, every other tick is skipped (an effective 30 minutes).
    /// Its consumers are the Notification Center's FYI signals and the two
    /// canvas modules that render `lastCounts` - "your tools are 25 minutes
    /// out of date rather than 15" is not a cost anyone can perceive.
    private var backgroundedGate = BackgroundedPollGate(skipsPerRun: 1)

    private var timer: Timer?
    private var isChecking = false

    // MARK: GL-03 - the `isChecking` latch must not be a one-way door
    //
    // Every check below is an unbounded subprocess spawn (Updates ~31,
    // GitHub Sync ~21 including `git fetch`/`git clone`, Vault's `av list`
    // which has a documented prior real hang, plus a dotfiles `git fetch`).
    // `isChecking` was set at the start of a pass and cleared only after all
    // four completed - so one hung child meant every future tick returned on
    // the `guard !isChecking` line and tool-update, fork-drift, vault and
    // setup-drift notifications went dark for the rest of the session, with
    // no UI or log signal at all.
    //
    // The real fix is per-check timeouts through the shared subprocess runner
    // (phase 2, GL-02/GL-15). Until that lands, this is the stopgap the review
    // asked for: a wall-clock watchdog that lets a *new* pass start once the
    // previous one has clearly wedged, plus a "last completed" timestamp so
    // the failure is at least observable instead of invisible.
    //
    // Note what this deliberately does NOT do: it does not kill the wedged
    // pass (there is no handle to its children yet - that is the phase-2
    // runner's job). A superseded pass may still be running and may still
    // publish its own results later; every one of those publishes is an
    // idempotent `NotificationSources.set*` call with a freshly-computed
    // count, so a late writer is stale-but-valid, never corrupting.

    /// How long a single pass may run before a new tick is allowed to start
    /// anyway. Generous on purpose: a genuinely slow (not hung) pass on a
    /// cold `brew`/`gh` cache can legitimately take minutes, and starting a
    /// second pass alongside it costs real process spawns.
    ///
    /// `static` for the same reason as `pollInterval`: `sharedCheckMaxAge`'s
    /// own bound is expressed against it.
    static let passWatchdog: TimeInterval = 5 * 60

    /// When the currently-running pass started, `nil` if none is running.
    private var passStartedAt: Date?

    /// Identifies the pass that currently "owns" the latch. A pass the
    /// watchdog superseded still finishes eventually and still reaches the
    /// completion block - without this it would clear the latch out from under
    /// the newer pass that replaced it, letting a third pass start alongside
    /// the second. Only the pass whose id still matches may clear it.
    private var currentPassID = 0

    /// When a pass last ran all four checks to completion. `nil` means no
    /// pass has ever finished - surfaced for diagnostics (F1/GL-11 will give
    /// this a real home; for now it is readable and logged).
    private(set) var lastCompletedPassAt: Date?

    /// How many passes were force-superseded by the watchdog. Non-zero means
    /// something in the check path is hanging and deserves attention.
    private(set) var supersededPassCount = 0

    // MARK: F12 - the counts this poller already computed
    //
    // The morning briefing (F12) needs "how many forks are behind", "how many
    // tools have an update", "how many setup items drifted". Those are the
    // exact three counts each check below already computes for the
    // Notification Center - and recomputing them from the briefing would mean
    // ~50 fresh `brew`/`npm`/`gh api` spawns on the first Overview visit of
    // the day, which is precisely the "no new collection" the review's F12
    // entry rules out. So each check records its result here as it publishes,
    // and the briefing reads it.
    //
    // Every field is `Int?`: `nil` means "this poller has not produced a
    // number yet this session" (the first pass runs ~10s after launch), which
    // the briefing renders as an absent clause rather than as a confident
    // zero. That distinction is GL-14's rule, applied to one more signal.

    struct SignalCounts: Equatable {
        var toolUpdates: Int?
        var forkDrift: Int?
        var vaultAttention: Int?
        var setupDrift: Int?
        /// How many hardened secrets Automic Vault reported on this poller's
        /// **last** pass.
        ///
        /// Daylight Phase 2's Vault module renders this rather than calling
        /// `VaultSource.loadSnapshot()` itself - the migration spec is explicit
        /// that the canvas "renders the LAST snapshot, it does not shell out on
        /// canvas load". `checkVault` below already loads that snapshot for the
        /// attention count, so recording one more number off it costs nothing
        /// and adds no `av` invocation anywhere.
        var vaultSecrets: Int?
    }

    /// When the data behind each published signal was gathered - see
    /// `acceptsReading`. Main thread only, like `lastCounts` itself.
    fileprivate var newestReading: [Signal: Date] = [:]

    /// Written on the main thread by each check's own completion block (the
    /// same block that calls `NotificationSources.set*`), read on the main
    /// thread by `FleetController` and `HomeCanvasController` - so no lock is
    /// needed and none is implied.
    private(set) var lastCounts = SignalCounts() {
        didSet {
            guard lastCounts != oldValue else { return }
            notifyCountsObservers()
        }
    }

    // MARK: Daylight Phase 3 - publishing what this poller already computed
    //
    // The Setup and Vault modules on the Daylight hub render `lastCounts`
    // (§6.1 is explicit that neither may run a fresh check from the canvas).
    // Phase 2 wired both reads correctly, but nothing told the canvas when a
    // number arrived - and the canvas is the *launch landing*, so a captain
    // sitting on it watched both cards say "hasn't been checked yet this
    // session" for the rest of the session, however long the app stayed open.
    //
    // The tempting fix - riding `GrandLineNotificationCenter.observe`, which
    // this poller already publishes into on the same main-thread hop - is
    // wrong, and wrong in the worse direction: `NotificationSources.set*`
    // collapses a zero count into `set(nil, id:)`, which is a silent no-op
    // when nothing was there to remove. So a *clean* machine (no updates, no
    // drift, no vault attention - the common case) would notify nobody and
    // stay stuck on "unknown", while only a machine with a real problem
    // updated. Verified by reading `GrandLineNotificationCenter.set`'s own
    // `if changed` guard, not assumed.
    //
    // Hence this: the smallest possible fan-out over state this poller
    // already produced, on the main thread it already produced it on. It adds
    // no timer, no pass, and no subprocess - `notifyCountsObservers` cannot
    // start work, it can only hand out numbers that already exist.

    /// Token returned by `observeCounts` - mirrors `ThemeObservation`'s shape
    /// so a view controller can unregister in `deinit` rather than leaking a
    /// dead closure (this app's most-repeated bug class; see
    /// `ThemeManager.swift`'s checklist).
    final class CountsObservation {}

    private var countsObservers: [(token: CountsObservation, fn: (SignalCounts) -> Void)] = []

    /// Observe `lastCounts`. Fires on the main thread whenever a pass produces
    /// a value that differs from the last one, and **not** at registration -
    /// unlike `ThemeManager.observe`, a caller here is asking to be told about
    /// a *change*, and every caller already reads `lastCounts` directly when
    /// it renders.
    @discardableResult
    func observeCounts(_ fn: @escaping (SignalCounts) -> Void) -> CountsObservation {
        let token = CountsObservation()
        countsObservers.append((token, fn))
        return token
    }

    func unobserveCounts(_ token: CountsObservation) {
        countsObservers.removeAll { $0.token === token }
    }

    /// Always already on the main thread: every write to `lastCounts` happens
    /// inside a `DispatchQueue.main.async` block below.
    /// Only read by the self-test hook below.
    fileprivate var countsObserverCountForTests: Int { countsObservers.count }

    private func notifyCountsObservers() {
        // The claim above, enforced rather than only stated: every write to
        // `lastCounts` is inside a `DispatchQueue.main.async` block, and an
        // observer here rebuilds a view hierarchy. GL-25's convention.
        dispatchPrecondition(condition: .onQueue(.main))
        let counts = lastCounts
        for observer in countsObservers { observer.fn(counts) }
    }

    /// Forwarded navigation - set once at launch by whoever owns
    /// `AppShellController` (mirrors `ConsoleComposerController.
    /// onRunInTerminal`'s own forward-don't-own convention). `show(_:)` is
    /// already internal (not private) on `AppShellController`, so these are
    /// plain pass-throughs, not new navigation behavior.
    var onNavigateToUpdates: (() -> Void)?
    var onNavigateToGitHubSync: (() -> Void)?
    var onNavigateToVault: (() -> Void)?
    var onNavigateToBootstrap: (() -> Void)?

    /// `fm/grandline-notification-ambient-expand-fix`: the per-tool and
    /// per-repo halves of the two navigation hooks above, for the popover's
    /// expanded child rows.
    ///
    /// They take an id rather than doing the work here on purpose. An update
    /// and a sync are the pages' own mutating actions, and each page owns the
    /// per-row busy state that keeps two external-tool invocations from
    /// racing (`UpdatesController.update`'s `isBusy` guard, and the same in
    /// `GitHubSyncController.sync`). A poller that shelled out to `brew` on
    /// its own would run beside whatever that page was already doing, with no
    /// row to report into. So the shell shows the page - mounting it if this
    /// is its first visit - and hands it the id, and the page runs its real
    /// action with its real confirmation, log, toast and post-update re-check.
    var onUpdateTool: ((String) -> Void)?
    var onSyncFork: ((String) -> Void)?

    private init() {}

    /// Safe to call every launch. Runs one check shortly after starting (so
    /// the center has real data soon after launch, not just after the first
    /// 15-minute interval elapses) and then on the fixed cadence.
    func start() {
        guard timer == nil else { return }
        // F1: declare the row before the first pass, so the Health card shows
        // "Not run yet" rather than omitting a service that exists.
        ServiceHealthRegistry.shared.register(.backgroundSignals)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkNow() }
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // E3. Deliberately gated on the *timer* rather than inside
            // `checkNow()`: that method is also the manual/deep-link entry
            // point ("Check now"), and a captain asking for a check must
            // always get one.
            guard self.backgroundedGate.shouldRun(backgrounded: AppActivityState.shared.isBackgrounded) else { return }
            self.checkNow()
        }
        t.tolerance = 30
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether a new pass may start (GL-03), extracted so it can be tested
    /// without shelling out to `brew`/`npm`/`gh`/`av` - which is what made the
    /// original latch bug invisible: the *decision* is three lines and the
    /// *work* is 60 subprocesses, so nothing could reach the decision.
    enum PassAdmission: Equatable {
        /// Nothing is running - go.
        case start
        /// Something is running and has not exceeded the watchdog. This is the
        /// normal skip, and the one that used to be permanent.
        case refused
        /// Something has been running longer than the watchdog: start anyway,
        /// and say so. `ageSeconds` is what the log/health message reports.
        case supersede(ageSeconds: Int)
    }

    static func admit(isChecking: Bool, passStartedAt: Date?,
                      now: Date, watchdog: TimeInterval) -> PassAdmission {
        guard isChecking else { return .start }
        // No start time recorded while the latch is held is itself a broken
        // state (the two are set together) - treat it as refused rather than
        // as licence to pile on another pass.
        guard let passStartedAt else { return .refused }
        let age = now.timeIntervalSince(passStartedAt)
        guard age > watchdog else { return .refused }
        return .supersede(ageSeconds: Int(age))
    }

    /// Only the pass that still owns the latch may release it. A superseded
    /// pass finishes eventually and reaches the same completion block; if it
    /// cleared the latch there, it would clear it out from under its own
    /// replacement and a third pass would start alongside the second.
    static func mayReleaseLatch(finishingPassID: Int, currentPassID: Int) -> Bool {
        finishingPassID == currentPassID
    }

    /// Exposed (not `private`) so a debug probe / self-test can force one
    /// pass without waiting on the timer, matching
    /// `ShiftNotificationScheduler.poll()`'s own convention.
    func checkNow() {
        switch Self.admit(isChecking: isChecking, passStartedAt: passStartedAt,
                          now: Date(), watchdog: Self.passWatchdog) {
        case .refused:
            return
        case .start:
            break
        case .supersede(let age):
            supersededPassCount += 1
            AppLog.poller.error("""
                background signals: pass started \(age)s ago has not finished - starting a new one \
                anyway (GL-03 watchdog, \(self.supersededPassCount) so far this session).
                """)
            // A superseded pass is exactly the invisible failure F1 exists to
            // surface: something in the check path is hanging, and until now
            // nothing anywhere said so.
            ServiceHealthRegistry.shared.recordFailure(
                .backgroundSignals,
                "A check pass has been running for \(age)s without finishing (watchdog fired \(supersededPassCount)x).")
        }
        isChecking = true
        passStartedAt = Date()
        ServiceHealthRegistry.shared.markRunning(.backgroundSignals)
        currentPassID += 1
        let passID = currentPassID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Computed once and shared with `checkSetupDrift` below (the
            // Software checklist step reads the exact same per-item outcomes)
            // rather than shelling out to `brew`/`npm` twice for the same
            // catalog in one poll pass. See `sweepSoftware`.
            let (softwareSamples, softwareGatheredAt) = Self.sweepSoftware()
            let softwareStatuses = softwareSamples.map { $0.outcome.status }
            self.checkToolUpdates(samples: softwareSamples, gatheredAt: softwareGatheredAt)
            self.checkGitHubSync()
            self.checkVault()
            // The software half of setup drift is the sweep above, so this
            // reading is only as new as that sweep was.
            self.checkSetupDrift(softwareStatuses: softwareStatuses, gatheredAt: softwareGatheredAt)
            DispatchQueue.main.async {
                // Every completed pass counts as a real completion for
                // diagnostics, even a superseded one - it did finish.
                self.lastCompletedPassAt = Date()
                ServiceHealthRegistry.shared.recordSuccess(.backgroundSignals)
                // ...but only the pass that still owns the latch may release
                // it. See `currentPassID`.
                guard Self.mayReleaseLatch(finishingPassID: passID, currentPassID: self.currentPassID) else { return }
                self.isChecking = false
                self.passStartedAt = nil
            }
        }
    }

    /// The 13-item `DependencyCatalog` sweep, and the one piece of this
    /// poller's pass that is worth testing on its own - so it takes both of
    /// its collaborators as defaulted parameters and a self-test can drive
    /// the **real** function against a disposable cache and a counting fake,
    /// rather than re-implementing the policy it is meant to be checking.
    /// The other three checks (`gh`, `av`, a dotfiles `git fetch`) have no
    /// such seam and are deliberately never driven from a suite.
    ///
    /// Two decisions live here, both load-bearing:
    ///
    /// 1. It reads through the shared `DependencyCheckCache` rather than
    ///    calling `UpdatesSource.check` directly, so a sweep the captain's own
    ///    visit to Updates/Bootstrap/Automation already paid for moments ago
    ///    is not paid for again - and the entries it writes are what those
    ///    pages' next unforced mount reads. `sharedCheckMaxAge`, never the
    ///    pages' default TTL: see that constant for why a longer window would
    ///    quietly halve this poller's own cadence.
    ///
    /// 2. The returned `gatheredAt` is the **oldest** sample that contributed,
    ///    not `Date()`. A partly-cached sweep is a mixture of vintages, and
    ///    `acceptsReading` compares gather times to decide whether this
    ///    reading may displace a page's own - so claiming the whole set is as
    ///    new as its newest half would be the exact overwrite-a-fresher-number
    ///    bug PR #395 closed, reintroduced through this cache.
    /// 3. It returns the **whole** `CheckOutcome` per item, paired with the
    ///    item it came from, rather than only `.status`
    ///    (`fm/grandline-notification-ambient-expand-fix`). The name and the
    ///    version-pair detail are what the notification popover's expanded
    ///    row is made of, and this sweep already had both in hand - throwing
    ///    them away here is what made the ambient row unexpandable while the
    ///    Updates page's own publish of the identical data expanded fine.
    static func sweepSoftware(cache: DependencyCheckCache = .shared,
                              items: [DependencyItem] = DependencyCatalog.items)
        -> (samples: [SoftwareSample], gatheredAt: Date) {
        let sampled = items.map {
            ($0, cache.checkDated($0, forceRefresh: false, maxAge: sharedCheckMaxAge))
        }
        // `min()` is nil only for an empty catalog, which never happens;
        // `Date()` is the honest answer for "nothing contributed" anyway.
        return (sampled.map { SoftwareSample(item: $0.0, outcome: $0.1.outcome) },
                sampled.map { $0.1.gatheredAt }.min() ?? Date())
    }

    /// One catalog item and what the sweep above learned about it.
    struct SoftwareSample {
        let item: DependencyItem
        let outcome: CheckOutcome
    }

    // MARK: #3 - tool updates

    private func checkToolUpdates(samples: [SoftwareSample], gatheredAt: Date) {
        DispatchQueue.main.async { [weak self] in
            self?.applyToolSweep(samples: samples, gatheredAt: gatheredAt)
        }
    }

    /// The main-thread half of the tool pass, split out so a suite can drive
    /// the real composition (children included) without a run loop - see
    /// `debugRunAmbientToolPass`.
    private func applyToolSweep(samples: [SoftwareSample], gatheredAt: Date) {
        publishToolStatuses(samples.map { $0.outcome.status },
                            children: toolChildren(from: samples),
                            gatheredAt: gatheredAt)
    }

    /// The ambient pass's own expandable children, built through the one
    /// shared mapping the Updates page also uses.
    private func toolChildren(from samples: [SoftwareSample]) -> [AppNotificationChild] {
        NotificationSignalChildren.tools(
            samples.map {
                .init(id: $0.item.id, name: $0.item.name,
                      status: $0.outcome.status, detail: $0.outcome.detail)
            },
            perform: { [weak self] id in self?.onUpdateTool?(id) })
    }

    // MARK: #4 - GitHub Sync

    private func checkGitHubSync() {
        let gatheredAt = Date()
        let repos = GitHubSyncCatalog.repos
        // The whole outcome, not just `.status` - same reason as the software
        // sweep above: `.detail` is the "12 commits behind kunchenguid/gh-axi"
        // line the expanded row shows, and this is the only place that ran the
        // check before the GitHub Sync page has ever been opened.
        let outcomes = repos.map { GitHubSyncSource.check($0) }
        DispatchQueue.main.async { [weak self] in
            self?.applyForkSweep(repos: repos, outcomes: outcomes, gatheredAt: gatheredAt)
        }
    }

    /// The main-thread half of the fork pass - see `applyToolSweep`.
    private func applyForkSweep(repos: [GitHubSyncRepoConfig],
                                outcomes: [GitHubSyncCheckOutcome],
                                gatheredAt: Date) {
        publishForkStatuses(outcomes.map { $0.status },
                            children: forkChildren(repos: repos, outcomes: outcomes),
                            gatheredAt: gatheredAt)
    }

    private func forkChildren(repos: [GitHubSyncRepoConfig],
                              outcomes: [GitHubSyncCheckOutcome]) -> [AppNotificationChild] {
        NotificationSignalChildren.forks(
            zip(repos, outcomes).map {
                .init(id: $0.fullName, name: $0.name, status: $1.status, detail: $1.detail)
            },
            perform: { [weak self] id in self?.onSyncFork?(id) })
    }

    // MARK: #5 - Vault attention

    private func checkVault() {
        let gatheredAt = Date()
        let snapshot = VaultSource.loadSnapshot()
        // B1: an `av` read that failed is not "nothing needs attention" and
        // not "no secrets". `publishVaultRead` leaves both counts as they
        // were in that case - `SignalCounts`' own `Int?` fields already mean
        // "not established", which is what the Vault canvas card renders
        // honestly. Logged here rather than there because only this caller
        // knows the read was a scheduled pass rather than a page's own load.
        if snapshot.isDegraded {
            AppLog.poller.info("vault check skipped: av read failed, leaving counts unchanged")
        }
        DispatchQueue.main.async { [weak self] in
            self?.publishVaultRead(secrets: snapshot.secrets, tools: snapshot.tools, gatheredAt: gatheredAt)
        }
    }

    // MARK: #6 - Bootstrap setup drift

    /// Mirrors `BootstrapController`/`AutomationController`'s own
    /// independently-fetched-state pattern (see `SetupStepChecks.swift`'s
    /// header) rather than reaching into either controller's private
    /// fields - this poller keeps its own throwaway copy of the same inputs
    /// those pages already gather, purely to call the identical
    /// `SetupStepChecks` predicates.
    private func checkSetupDrift(softwareStatuses: [DependencyStatus], gatheredAt: Date) {
        let firstmateHome = SetupStepChecks.firstmateHomeDone()

        var dotfilesState: DotfilesRepoState?
        var agentItems: [AgentInstructionsItem] = []
        let repoPath = DotfilesSource.resolvedDotfilesPath()
        if let repoPath {
            dotfilesState = DotfilesSource.repoState(at: repoPath)
            agentItems = DotfilesSource.agentInstructionItems(repoPath: repoPath)
        } else {
            agentItems = DotfilesSource.agentInstructionPaths.map {
                AgentInstructionsItem(label: $0.label, path: $0.path, status: .notLinked)
            }
        }
        let dotfilesDone = SetupStepChecks.dotfilesDone(isLoading: false, repoPath: repoPath, state: dotfilesState)
        let agentDone = SetupStepChecks.agentInstructionsDone(isLoading: false, items: agentItems)
        let softwareDone = SetupStepChecks.softwareDone(isLoading: false, statuses: softwareStatuses)

        let hostCount = HostStore().hosts.count
        let snippetCount = SnippetStore().snippets.count
        let restoreConfigDone = SetupStepChecks.restoreConfigDone(hostCount: hostCount, snippetCount: snippetCount)

        // Keyed by step exactly as both setup pages hold it, so the shared
        // derivation below counts the same five things whichever producer
        // supplied them. `restoreConfigDone` has no "not yet checked" state
        // (it's a pure synchronous read) and `firstmateHomeDone` is likewise
        // always a definite bool - only dotfiles/agent/software can be `nil`
        // ("still checking" in a live controller's async flow), which can't
        // happen here since every call above is already synchronous.
        let results: [SetupStepKind: Bool?] = [
            .firstmateHome: firstmateHome,
            .dotfiles: dotfilesDone,
            .agentInstructions: agentDone,
            .software: softwareDone,
            .restoreConfig: restoreConfigDone,
        ]

        DispatchQueue.main.async { [weak self] in
            self?.publishSetupStepResults(results, gatheredAt: gatheredAt)
        }
    }
}

// MARK: - The one published count per signal
//
// `fm/grandline-engineering-cards-stale-counts`. The captain updated every
// tool and synced every fork by hand, then watched the Engineering hub go on
// claiming "3 updates" and "6 behind" while the Updates and GitHub Sync pages
// - one click away - correctly read "0 Updates Available" and "all in sync".
//
// The cause was duplication, not a missing refresh: `lastCounts` was a
// private snapshot only this poller's own 15-minute pass could ever write,
// while each detail page independently recomputed the very same fact from a
// real check and kept the answer to itself. Two computations of one number,
// with no way for the fresher one to win - so the hub (and the notification
// bell, which reads the same published signal) stayed wrong for up to 15
// minutes after the captain had already fixed the thing being reported.
//
// The fix is *not* a second mechanism reconciling two counts. There is one
// count per signal, it lives here, and it is derived in exactly one place:
// the `static` functions below. Every producer of fresh truth - this poller's
// own pass, and each detail page at the single choke point its own status
// changes already funnel through - hands over the **raw outcomes it just
// learned** and lets this file do the counting. A page never computes a
// count, so a page can never disagree with the hub about how to count.
//
// Two rules the derivations share, both of them GL-14's:
//
//  - A pending sweep publishes nothing. Mid-check statuses are not an answer,
//    and "0 updates" while 13 checks are still running is a confident claim
//    about an answer nobody has yet. `nil` means "no publishable count",
//    which leaves the previous one standing rather than overwriting it with a
//    guess - the same call `UpdatesController.drillHeaderSubtitle` and
//    `GitHubSyncController.drillHeaderSubtitle` already make for their own
//    one-line summaries.
//  - A never-checked set publishes nothing either, for the same reason: a
//    freshly built page whose rows are all `.unknown` must not stamp a zero
//    over a real number this poller established at launch.

extension BackgroundSignalsPoller {

    // MARK: Later-gathered data wins
    //
    // A pass spends tens of seconds gathering (13 `brew`/`npm` checks, then 8
    // `gh` checks, then `av`, then a `git fetch`) and only publishes at the
    // end - so the statuses it publishes can already be a minute old. A
    // captain who resolves something on a detail page during that window would
    // otherwise watch the hub go correct and then, seconds later, go stale
    // again as the pass landed its pre-fix reading on top. That is the very
    // bug this task exists to remove, reintroduced through the back door.
    //
    // Each publish therefore carries **when its data was gathered**, not when
    // it was published, and an older reading never displaces a newer one. A
    // page defaults to `Date()` because its rows are current as it renders
    // them; the poller stamps each check as it runs.

    /// Signals whose freshness is tracked independently - a pass's fork check
    /// being outrun by the GitHub Sync page says nothing about its tool check.
    enum Signal: Hashable { case tools, forks, setup, vault }

    /// `true` when this reading is at least as new as whatever is published,
    /// recording it as the new high-water mark. Main thread, like every other
    /// access to `lastCounts`.
    func acceptsReading(_ signal: Signal, gatheredAt: Date) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let newest = newestReading[signal], gatheredAt < newest { return false }
        newestReading[signal] = gatheredAt
        return true
    }

    /// How many catalog tools have an update to install.
    ///
    /// `showsUpdateButton` is the predicate `UpdatesController`'s own rows,
    /// its "Updates Available" tile and its drill subtitle already use - this
    /// is the same question, asked once.
    static func toolUpdateCount(from statuses: [DependencyStatus]) -> Int? {
        guard !statuses.isEmpty else { return nil }
        guard !statuses.contains(where: { $0 == .checking || $0 == .updating }) else { return nil }
        guard !statuses.allSatisfy({ $0 == .unknown }) else { return nil }
        return statuses.filter { $0.showsUpdateButton }.count
    }

    /// How many tracked forks are behind their upstream.
    ///
    /// `showsSyncButton` is what `GitHubSyncController`'s rows offer a Sync
    /// button for and what its own "Sync All" filters on - a repo that is
    /// diverged or not a fork is deliberately not counted here, because there
    /// is nothing to pull.
    static func forkDriftCount(from statuses: [GitHubSyncStatus]) -> Int? {
        guard !statuses.isEmpty else { return nil }
        guard !statuses.contains(where: { $0 == .checking || $0 == .syncing }) else { return nil }
        guard !statuses.allSatisfy({ $0 == .unknown }) else { return nil }
        return statuses.filter { $0.showsSyncButton }.count
    }

    /// How many of the five setup steps have drifted.
    ///
    /// Takes the same `[SetupStepKind: Bool?]` shape both setup pages already
    /// hold (`BootstrapController.stepIsDone`/`AutomationController.stepIsDone`,
    /// each delegating to `SetupStepChecks`), where the inner `nil` is "this
    /// step's own check has not answered yet". A single unanswered step makes
    /// the whole count unpublishable - four of five known is not four-fifths
    /// of an answer, it is an answer that could still move.
    static func setupDriftCount(from results: [SetupStepKind: Bool?]) -> Int? {
        var drifted = 0
        for kind in SetupStepKind.allCases {
            guard let answer = results[kind], let done = answer else { return nil }
            if !done { drifted += 1 }
        }
        return drifted
    }

    /// Publish freshly-learned tool statuses. Safe to call from any producer;
    /// a set that is still settling is ignored rather than published.
    ///
    /// `children`/`updateAll` are the redesigned popover's expandable half -
    /// the tools by name with their version pairs, and the page's own serial
    /// bulk update.
    ///
    /// **Both producers supply `children`**
    /// (`fm/grandline-notification-ambient-expand-fix`). They used to default
    /// to nothing for this poller's own pass, on the reasoning that the pass
    /// "reads cached statuses, not names" - which was simply wrong: the sweep
    /// holds a full `CheckOutcome` per catalog item and was discarding
    /// everything but `.status`. The captain saw the consequence and reported
    /// it as a bug: at launch, before Updates has ever been opened, the only
    /// producer is this one and "2 tools have updates" had no chevron at all.
    /// `sweepSoftware` now returns the outcomes and `toolChildren` builds the
    /// same children the page builds.
    ///
    /// `updateAll` is still the page's alone, and that one *is* honest: the
    /// bulk update is a serial loop over the page's own rows and their busy
    /// state (`UpdatesController.updateAllPending`), so with no page mounted
    /// the row's primary action stays "Open Updates" rather than claiming a
    /// bulk run nothing is driving. Each child's own Update is live either
    /// way - see `onUpdateTool`.
    func publishToolStatuses(_ statuses: [DependencyStatus],
                             children: [AppNotificationChild] = [],
                             updateAll: (() -> Void)? = nil,
                             gatheredAt: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let count = Self.toolUpdateCount(from: statuses) else { return }
        guard acceptsReading(.tools, gatheredAt: gatheredAt) else { return }
        lastCounts.toolUpdates = count
        NotificationSources.setToolUpdates(count: count, children: children, updateAll: updateAll) {
            [weak self] in self?.onNavigateToUpdates?()
        }
    }

    /// Publish freshly-learned fork statuses. `children`/`syncAll` divide the
    /// same way `publishToolStatuses`' do, and for the same reasons.
    func publishForkStatuses(_ statuses: [GitHubSyncStatus],
                             children: [AppNotificationChild] = [],
                             syncAll: (() -> Void)? = nil,
                             gatheredAt: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let count = Self.forkDriftCount(from: statuses) else { return }
        guard acceptsReading(.forks, gatheredAt: gatheredAt) else { return }
        lastCounts.forkDrift = count
        NotificationSources.setGitHubSync(count: count, children: children, syncAll: syncAll) {
            [weak self] in self?.onNavigateToGitHubSync?()
        }
    }

    /// Publish freshly-learned setup-step results.
    func publishSetupStepResults(_ results: [SetupStepKind: Bool?], gatheredAt: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let count = Self.setupDriftCount(from: results) else { return }
        guard acceptsReading(.setup, gatheredAt: gatheredAt) else { return }
        lastCounts.setupDrift = count
        // The drifted steps name themselves - `results` is keyed by
        // `SetupStepKind`, so no page has to hand them over separately.
        let children = SetupStepKind.allCases
            .filter { results[$0] == .some(false) }
            .map { AppNotificationChild(id: "\($0)", name: $0.title, meta: "Not satisfied") }
        NotificationSources.setSetupDrift(count: count, children: children) {
            [weak self] in self?.onNavigateToBootstrap?()
        }
    }

    /// Publish a freshly-loaded Automic Vault read.
    ///
    /// Takes the two lists rather than a whole `VaultSnapshot` because they
    /// are the only parts counted here, and because the Vault page holds them
    /// as its own two members rather than keeping the snapshot around.
    ///
    /// B1's rule crosses the boundary intact: a read that failed says nothing
    /// about how many secrets exist or how many launchers need attention, so
    /// `nil` on either side leaves both counts exactly as they were.
    func publishVaultRead(secrets: [VaultSecret]?, tools: [VaultTool]?, gatheredAt: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let tools, let secrets else { return }
        guard acceptsReading(.vault, gatheredAt: gatheredAt) else { return }
        let attention = tools.filter {
            if case .needsAttention = $0.status { return true }
            return false
        }.count
        // One assignment, not two - `lastCounts`'s `didSet` fires per write,
        // and two writes would rebuild the canvas twice for one snapshot.
        var counts = lastCounts
        counts.vaultAttention = attention
        counts.vaultSecrets = secrets.count
        lastCounts = counts
        NotificationSources.setVaultAttention(count: attention) { [weak self] in self?.onNavigateToVault?() }
    }
}

// MARK: - Probe / self-test surface
//
// `lastCounts` and `lastCompletedPassAt` are `private(set)`, so a hook that
// sets them has to live in this file rather than in a `+TestSupport`
// extension. Behind `FM_SELFTESTS` (GL-27) so the shipped binary carries
// neither - verified the same way as `ConsoleController`'s hooks.
//
// These exist so `DaylightModuleSelfTest` can drive the warming-up -> real
// -data transition of the Setup and Vault modules without waiting on a real
// 15-minute poll pass, and without spawning the ~50 `brew`/`npm`/`gh`/`av`
// subprocesses a real pass runs.
#if FM_SELFTESTS
extension BackgroundSignalsPoller {

    /// Publish a set of counts as if a pass had produced them - fires the
    /// same `didSet` fan-out a real pass does.
    func debugSetCounts(_ counts: SignalCounts) { lastCounts = counts }

    /// Move the "a pass has completed" clock, which is what decides between
    /// the two honest no-number-yet states on the hub.
    func debugSetLastCompletedPassAt(_ date: Date?) { lastCompletedPassAt = date }

    var debugCountsObserverCount: Int { countsObserverCountForTests }

    /// Clear the per-signal freshness high-water marks. A suite that seeds a
    /// count with `debugSetCounts` has published nothing, so without this the
    /// marks left by an earlier case would make a later one's publish look
    /// stale and be refused.
    func debugResetReadingClock() { newestReading = [:] }

    /// Run the ambient pass's tool half synchronously: the **real**
    /// `sweepSoftware` against an injected cache and item list, then the real
    /// main-thread apply - so a suite sees the real children composition
    /// rather than a re-implementation of it. Only the subprocess is faked,
    /// through `DependencyCheckCache.checkOverrideForTests`.
    func debugRunAmbientToolPass(cache: DependencyCheckCache, items: [DependencyItem]) {
        let sweep = Self.sweepSoftware(cache: cache, items: items)
        applyToolSweep(samples: sweep.samples, gatheredAt: sweep.gatheredAt)
    }

    /// The same for the fork half, one seam further in: `GitHubSyncSource.check`
    /// is a live `gh api` call with no override of its own, so the outcomes are
    /// the fixture and everything downstream of them is real.
    func debugRunAmbientForkPass(repos: [GitHubSyncRepoConfig],
                                 outcomes: [GitHubSyncCheckOutcome]) {
        applyForkSweep(repos: repos, outcomes: outcomes, gatheredAt: Date())
    }
}
#endif
