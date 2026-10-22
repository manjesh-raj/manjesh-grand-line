// Grand Line - native macOS app.
//
// The sidebar layout's subscription to the signals its badges draw
// (`WorkspaceSignals`). One per sidebar shell; the floating bar never
// builds one, so nothing here runs in the default layout.
//
// **It only listens.** Every source below already reads what it reads, on its
// own cadence, for its own page: the Fleet page's refresh, the Shift store,
// the vault store, the background signals poller and the Health registry.
// This subscribes to what they publish and adds no timer, no
// pass and no subprocess - the same rule `BackgroundSignalsPoller.observeCounts`
// states for the Home canvas (GL-13, GL-24).
//
// The Fleet page's crew reading is a single closure Home already holds, so it
// arrives through the workspace's chrome hook (`workspaceCrewDidRead`) rather
// than a second subscription. The vault's lock comes from the store's own lock observers,
// never from `onChange`, which is Poneglyph's (ARCH-04).

import Foundation

final class WorkspaceSignalsMonitor {

    private(set) var signals = WorkspaceSignals()
    /// Fires on the main thread whenever what the signals say changes.
    var onChange: ((WorkspaceSignals) -> Void)?

    private weak var workspace: Workspace?
    private var countsToken: BackgroundSignalsPoller.CountsObservation?
    private var lockToken: CredentialVaultStore.LockObservation?
    private weak var lockStore: CredentialVaultStore?
    private var dayObserver: NSObjectProtocol?
    private var started = false

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    deinit {
        if let countsToken { BackgroundSignalsPoller.shared.unobserveCounts(countsToken) }
        if let lockToken { lockStore?.unobserveLock(lockToken) }
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
    }

    /// Read every source once, then follow each one. Idempotent.
    func start() {
        guard !started, let workspace else { return }
        started = true

        crewDidRead()
        readTasks()
        readVault()
        readRegistry()

        // Neither the store's nor the registry's observation has a token;
        // both are app-lifetime lists, and a dead monitor's closure is a
        // weak no-op.
        workspace.shiftStore.observe { [weak self] in self?.readTasks() }
        ServiceHealthRegistry.shared.observe { [weak self] _ in self?.readRegistry() }
        countsToken = BackgroundSignalsPoller.shared.observeCounts { [weak self] _ in self?.readRegistry() }
        // Followed once something has built the store - Poneglyph, Home's
        // card, an App Intent - and never built from here, because building
        // it starts the vault's git sync. Until then a vault on disk is
        // locked, as nothing could have unlocked it.
        GrandLineServices.shared.whenVaultIsBuilt { [weak self] store in self?.follow(store) }
        // "Due today" turns over at midnight with no store change.
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.readTasks() }
    }

    // MARK: Readings

    /// The Fleet page finished a read: take Needs you's own reading of it.
    func crewDidRead() {
        guard let reading = workspace?.overview.needsYouReading else { return }
        update { $0.crew = Self.crewReading(from: reading) }
    }

    /// Needs you's reading in the signals' states.
    static func crewReading(from reading: FleetNeedsYouReading) -> WorkspaceReading<Int> {
        guard reading.hasRead else { return .reading }
        // No firstmate home: there is no crew to read, which Crew's own page
        // says in words. Nothing to badge.
        guard reading.homeOk else { return .unknown }
        guard reading.readFailed else {
            return .read(reading.waiting, at: reading.readAt ?? reading.checkedAt ?? Date())
        }
        let failedAt = reading.checkedAt ?? Date()
        guard let readAt = reading.readAt else { return .failed(last: nil, lastReadAt: nil, failedAt: failedAt) }
        return .failed(last: reading.waiting, lastReadAt: readAt, failedAt: failedAt)
    }

    func sessionsDidChange(_ sessions: [HostSession]) {
        let live = sessions.filter(\.isConnected).count
        update { $0.liveSessions = live }
    }

    private func readTasks(now: Date = Date()) {
        guard let store = workspace?.shiftStore else { return }
        // A store with a file it could not read keeps what it last read in
        // full, and says when (GL-01, GL-14) - a partial list would undercount.
        if store.isInFailedLoadState {
            update { $0.tasksDue = $0.tasksDue.failing(at: now) }
            return
        }
        let counts = CompactModeDigest.dueCounts(tasks: store.activeTasks, now: now)
        update { $0.tasksDue = .read(.init(today: counts.today, overdue: counts.overdue), at: now) }
    }

    private func follow(_ store: CredentialVaultStore) {
        guard lockStore !== store else { return }
        if let lockToken { lockStore?.unobserveLock(lockToken) }
        lockStore = store
        lockToken = store.observeLock { [weak self] _ in self?.readVault() }
        readVault()
    }

    private func readVault() {
        guard let store = lockStore else {
            let onDisk = GrandLineServices.shared.vaultFileExistsWithoutBuildingTheStore
            update { $0.vault = onDisk ? .locked : .none }
            return
        }
        let state: WorkspaceSignals.VaultState
        if store.isUnlocked {
            state = .unlocked
        } else {
            // A `stat`, memoised by the store - not a decrypt and not a parse
            // of an unchanged file.
            switch store.loadState() {
            case .absent: state = .none
            case .present: state = .locked
            case .unreadable: state = .unreadable
            }
        }
        update { $0.vault = state }
    }

    /// The Health registry's services, and Setup's counts, whose times it
    /// keeps.
    private func readRegistry() {
        let registry = ServiceHealthRegistry.shared
        var failing: [WorkspaceSignals.ServiceIssue] = []
        var degraded: [WorkspaceSignals.ServiceIssue] = []
        for service in registry.knownServices() {
            let state = registry.state(service)
            guard state.consecutiveFailures > 0 else { continue }
            let issue = WorkspaceSignals.ServiceIssue(title: service.title, failures: state.consecutiveFailures,
                                                      lastFailure: state.lastFailure)
            if state.consecutiveFailures >= ServiceHealthRegistry.failureThreshold {
                failing.append(issue)
            } else {
                degraded.append(issue)
            }
        }

        let poller = BackgroundSignalsPoller.shared
        let counts = poller.lastCounts
        let setupCounts = WorkspaceSignals.SetupCounts(toolUpdates: counts.toolUpdates, setupDrift: counts.setupDrift,
                                                       forkDrift: counts.forkDrift)
        let pass = registry.state(.backgroundSignals)
        let setup: WorkspaceReading<WorkspaceSignals.SetupCounts>
        if setupCounts.isEmpty {
            if pass.isRunning {
                setup = .reading
            } else if let failedAt = pass.lastFailure, pass.lastSuccess == nil {
                setup = .failed(last: nil, lastReadAt: nil, failedAt: failedAt)
            } else {
                setup = .unknown
            }
        } else {
            let readAt = poller.lastCompletedPassAt ?? pass.lastSuccess ?? Date()
            if let failedAt = pass.lastFailure, failedAt > (pass.lastSuccess ?? .distantPast) {
                setup = .failed(last: setupCounts, lastReadAt: readAt, failedAt: failedAt)
            } else {
                setup = .read(setupCounts, at: readAt)
            }
        }

        update {
            $0.failingServices = failing
            $0.degradedServices = degraded
            $0.setup = setup
        }
    }

    private func update(_ body: (inout WorkspaceSignals) -> Void) {
        var next = signals
        body(&next)
        guard next != signals else { return }
        signals = next
        onChange?(next)
    }

    #if FM_SELFTESTS
    /// Re-read the sources the suite changed through their own APIs, as
    /// their observers would on the next main-queue turn.
    func debugReadAll() {
        crewDidRead()
        readTasks()
        readVault()
        readRegistry()
    }
    #endif
}
