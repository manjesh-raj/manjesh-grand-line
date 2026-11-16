// Grand Line - native macOS app.
//
// GL-11 / F1 (production-readiness review sections 20 and 25): the registry
// behind the Health card. The review's framing is the point worth keeping -
// "a cockpit whose own gauges can silently die is not glanceable." Before
// this, `BackgroundSignalsPoller`, `FleetNotifier` and `ShiftGitSync` had zero
// log statements between them and no user-visible liveness signal at all, so a
// wedged poller (GL-03) meant notifications went stale forever with nothing
// anywhere saying so.
//
// This is deliberately a *registry*, not a monitor: it never polls anything and
// never decides that a service is unhealthy on its own. Each service reports
// its own outcomes (`recordSuccess`/`recordFailure`), and the registry only
// remembers the last of each plus a consecutive-failure count. That keeps the
// health of a service defined by the service, which is the only place that can
// know what "healthy" means for it.
//
// Two consumers:
//  - `HealthCardView` (its own `.health` rail destination,
//    `fm/grandline-health-sidebar-move` - previously the last card on
//    Settings) renders one row per service.
//  - After `failureThreshold` consecutive failures, `NotificationSources`
//    raises a `.actionNeeded` entry (GL-30). One failure is noise - a laptop
//    on a train fails a `gh` call constantly; repeated failure is a real
//    signal, and it is the one the review asks to surface.
//
// Everything here stays local: timestamps and error strings in memory, nothing
// persisted, nothing sent anywhere. Error strings come from the same sources
// the logs use, so the "don't log a secret value" rule covers this too - a
// failure detail is a tool's own message, never a credential.

import Foundation

/// The background services the Health card knows about. A case is added when a
/// service starts reporting, not speculatively - an always-"never run" row is
/// worse than no row.
enum HealthService: String, CaseIterable {

    case backgroundSignals
    case fleetTasks
    case shiftGitSync
    /// `fm/grandline-bootstrap-dotfiles-autocommit`: the dotfiles `home/` tree's
    /// own auto-commit. Reports separately from `shiftGitSync` because it is a
    /// different repository (the captain's own `~/.dotfiles` checkout), so a
    /// failure here has a different cause and a different fix.
    case dotfilesAutoSync
    case docsSync
    case shiftDueItems
    case persistence
    /// F11: the schedule runner. Reports one success/failure per completed
    /// scheduled run, so a scheduler that has silently stopped firing shows up
    /// here rather than only as "that nightly check has been quiet a while".
    case scheduledAutomations

    /// Row title on the Health card.
    var title: String {
        switch self {
        case .backgroundSignals: return "Tool & drift signals"
        case .fleetTasks: return "Fleet task watcher"
        case .shiftGitSync: return "Tasks git sync"
        case .dotfilesAutoSync: return "Dotfiles auto-sync"
        case .docsSync: return "Docs & runbooks sync"
        case .shiftDueItems: return "Due-item reminders"
        case .persistence: return "Saving to disk"
        case .scheduledAutomations: return "Scheduled automations"
        }
    }

    /// One line saying what this service actually does, so a failure row is
    /// actionable rather than a bare name.
    var detail: String {
        switch self {
        case .backgroundSignals:
            return "Checks tool updates, fork drift, Vault and setup drift every 15 minutes."
        case .fleetTasks:
            return "Watches the fleet's task state for decisions and finished work."
        case .shiftGitSync:
            return "Commits and pushes Tasks, runbooks and command library changes."
        case .dotfilesAutoSync:
            return "Commits and pushes dotfile edits under the config repo's home/ tree."
        case .docsSync:
            return "Pulls the DevOps Playbook and runbook content."
        case .shiftDueItems:
            return "Notifies when a task or follow-up comes due."
        case .persistence:
            // R4-UI-07: by the sidebar's module names (`ModuleTable`).
            return "Writes \(WorkspaceModule.connections.title) and \(WorkspaceModule.tasks.title) to disk: "
                + "hosts, keys, snippets, commands and tasks."
        case .scheduledAutomations:
            return "Runs the schedules set up in \(PlaceName.of(.schedules))."
        }
    }

    var symbol: String {
        switch self {
        case .backgroundSignals: return "antenna.radiowaves.left.and.right"
        case .fleetTasks: return "sailboat"
        case .shiftGitSync: return "arrow.triangle.2.circlepath"
        case .dotfilesAutoSync: return "gearshape.2"
        case .docsSync: return "book.closed"
        case .shiftDueItems: return "bell"
        case .persistence: return "internaldrive"
        case .scheduledAutomations: return "calendar"
        }
    }
}

extension HealthService {
    /// Which `activity.log` category a reading belongs to (R5-PROC-01). The
    /// two sync services are git sync; everything else here is a poller.
    var activityCategory: DiagnosticsLog.Activity {
        switch self {
        case .shiftGitSync, .dotfilesAutoSync, .docsSync: return .gitSync
        default: return .poller
        }
    }
}

struct ServiceHealthState: Equatable {
    var lastSuccess: Date?
    var lastFailure: Date?
    var lastFailureDetail: String?
    /// Reset to zero by any success. This is what makes the notification
    /// threshold mean "still broken" rather than "was broken once".
    var consecutiveFailures: Int = 0
    /// Set while a pass is in flight, so the card can say "checking…" rather
    /// than showing a stale timestamp as if it were current.
    var isRunning: Bool = false

    /// Never reported anything yet - rendered as "not run yet", which is a
    /// true and useful statement at launch.
    var hasReported: Bool { lastSuccess != nil || lastFailure != nil }

    enum Verdict { case unknown, running, healthy, degraded, failing }

    var verdict: Verdict {
        if isRunning { return .running }
        if !hasReported { return .unknown }
        if consecutiveFailures >= ServiceHealthRegistry.failureThreshold { return .failing }
        if consecutiveFailures > 0 { return .degraded }
        return .healthy
    }

    /// The bucket a summary counts this service in: its last *finished*
    /// pass, so a pass in flight neither hides a failure nor un-counts a
    /// healthy service for the second it takes. The row itself still says
    /// "Checking…" (`Verdict.label`).
    var bucket: ServiceHealthSummary.Bucket {
        guard hasReported else { return .notRun }
        if consecutiveFailures >= ServiceHealthRegistry.failureThreshold { return .failing }
        if consecutiveFailures > 0 { return .degraded }
        return .healthy
    }
}

/// R5-UI-04: one word per state, on every surface that names one. Home's list
/// said "Degraded" and "Not read" where the Health page said "1 recent
/// failure" and "Not run yet" about the same two services.
extension ServiceHealthState.Verdict {
    var label: String {
        switch self {
        case .unknown: return ServiceHealthSummary.Bucket.notRun.label
        case .running: return "Checking\u{2026}"
        case .healthy: return ServiceHealthSummary.Bucket.healthy.label
        case .degraded: return ServiceHealthSummary.Bucket.degraded.label
        case .failing: return ServiceHealthSummary.Bucket.failing.label
        }
    }
}

/// R5-BUG-02: the one count of how the background services are doing.
///
/// Home's Needs Attention footer, Home's Health card and the Health page each
/// used to count the registry for themselves, at their own moment and with
/// their own filter, and one render read "7/7 services healthy", "7/8" beside
/// "1 failing", and "Healthy 5/8". This is taken in one pass under the
/// registry's lock (`ServiceHealthRegistry.summary()`), and every surface that
/// states a count reads it, so they can only disagree by being stale - which
/// is why Home keeps the last one it was told about rather than sampling.
struct ServiceHealthSummary: Equatable {

    enum Bucket: CaseIterable {
        case healthy, degraded, failing, notRun

        /// The state's name, capitalised for a chip or a caption.
        var label: String {
            switch self {
            case .healthy: return "Healthy"
            case .degraded: return "Recent failure"
            case .failing: return "Failing"
            case .notRun: return "Not run yet"
            }
        }

        /// The same word inside a sentence ("2 healthy, 1 recent failure").
        var phrase: String { label.lowercased() }
    }

    struct Entry: Equatable {
        let service: HealthService
        let state: ServiceHealthState
    }

    /// Every known service, in `HealthService`'s declaration order.
    let entries: [Entry]

    init(_ entries: [Entry] = []) { self.entries = entries }

    var total: Int { entries.count }
    var healthy: Int { count(.healthy) }
    var degraded: Int { count(.degraded) }
    var failing: Int { count(.failing) }
    var notRun: Int { count(.notRun) }

    func count(_ bucket: Bucket) -> Int { entries.filter { $0.state.bucket == bucket }.count }

    func services(in bucket: Bucket) -> [HealthService] {
        entries.filter { $0.state.bucket == bucket }.map(\.service)
    }

    /// "5 healthy, 1 failing, 1 recent failure, 1 not run yet" - one figure
    /// per non-empty bucket, worst news after the good, the order the Health
    /// page's summary lists them.
    var spoken: String {
        guard total > 0 else { return "No background service has reported yet" }
        return [Bucket.healthy, .failing, .degraded, .notRun].compactMap { bucket -> String? in
            let n = count(bucket)
            return n > 0 ? "\(n) \(bucket.phrase)" : nil
        }.joined(separator: ", ")
    }

    /// Home's closing note, only when it is the whole truth: every known
    /// service healthy as of its last pass.
    var allHealthyNote: String? {
        guard total > 0, healthy == total else { return nil }
        return "\(healthy)/\(total) services healthy"
    }
}

/// App-lifetime singleton, `ThemeManager`-shaped: an `observe` list of
/// closures plus a synchronous notify, since every consumer is a view.
///
/// Thread-safety matters here in a way it does not for `ThemeManager`: the
/// reporters are background queues (pollers, the git-sync serial queue) while
/// every observer is a view on the main thread. State is guarded by a lock and
/// observers are always notified on the main queue.
final class ServiceHealthRegistry {

    static let shared = ServiceHealthRegistry()

    /// Consecutive failures before this is worth interrupting the captain over.
    /// Two 15-minute poller passes is half an hour of a signal being wrong,
    /// which is the point at which "the gauge is broken" beats "the network
    /// blipped".
    static let failureThreshold = 3

    private let lock = NSLock()
    private var states: [HealthService: ServiceHealthState] = [:]
    private var observers: [(HealthService) -> Void] = []

    private init() {}

    // MARK: Reporting (any thread)

    func markRunning(_ service: HealthService) {
        mutate(service) { $0.isRunning = true }
    }

    func recordSuccess(_ service: HealthService, at date: Date = Date()) {
        AppLog.poller.debug("\(service.rawValue, privacy: .public) ok")
        DiagnosticsLog.shared.activity(service.activityCategory, "\(service.rawValue) ok", at: date)
        mutate(service) {
            $0.isRunning = false
            $0.lastSuccess = date
            $0.consecutiveFailures = 0
            $0.lastFailureDetail = nil
        }
    }

    func recordFailure(_ service: HealthService, _ detail: String, at date: Date = Date()) {
        AppLog.poller.error("\(service.rawValue, privacy: .public) failed: \(detail, privacy: .public)")
        DiagnosticsLog.shared.activity(service.activityCategory, "\(service.rawValue) failed: \(detail)",
                                       failed: true, at: date)
        var crossedThreshold = false
        var count = 0
        mutate(service) {
            $0.isRunning = false
            $0.lastFailure = date
            $0.lastFailureDetail = detail
            $0.consecutiveFailures += 1
            count = $0.consecutiveFailures
            crossedThreshold = $0.consecutiveFailures >= Self.failureThreshold
        }
        if crossedThreshold {
            // The Notification Center store is main-thread-only, like every
            // other UI-facing singleton here.
            DispatchQueue.main.async {
                NotificationSources.setServiceFailing(service, failures: count, detail: detail)
            }
        }
    }

    // MARK: Reading

    func state(_ service: HealthService) -> ServiceHealthState {
        lock.lock(); defer { lock.unlock() }
        return states[service] ?? ServiceHealthState()
    }

    /// Only services that have something to say, in `HealthService`'s own
    /// declaration order. A service that has never reported is included once
    /// the app knows it exists - see `register(_:)`.
    func knownServices() -> [HealthService] {
        lock.lock(); defer { lock.unlock() }
        return HealthService.allCases.filter { states[$0] != nil }
    }

    /// Every known service and its state, read under one lock, so a count
    /// and the rows beside it describe the same instant (R5-BUG-02).
    func summary() -> ServiceHealthSummary {
        lock.lock(); defer { lock.unlock() }
        return ServiceHealthSummary(HealthService.allCases.compactMap { service in
            states[service].map { ServiceHealthSummary.Entry(service: service, state: $0) }
        })
    }

    /// Declare a service so its row appears (as "not run yet") before its
    /// first pass finishes. Called from the service's own `start()`.
    func register(_ service: HealthService) {
        mutate(service) { _ in }
    }

    /// Take a service's row away again, for one the captain has switched off.
    /// A switched-off service is not "not run yet", and it is not a failure
    /// either, so it has nothing to say on the Health card. Dotfiles
    /// auto-sync is the one caller (it is off by default since R5-SEC-03).
    func unregister(_ service: HealthService) {
        lock.lock()
        let removed = states.removeValue(forKey: service) != nil
        let handlers = observers
        lock.unlock()
        guard removed, !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler(service) }
        }
    }

    // MARK: Observation

    /// Fires on the main queue whenever any service's state changes. No
    /// removal token: every observer here is an app-lifetime view, the same
    /// tradeoff `ThemeManager` documents.
    func observe(_ handler: @escaping (HealthService) -> Void) {
        lock.lock()
        observers.append(handler)
        lock.unlock()
    }

    private func mutate(_ service: HealthService, _ body: (inout ServiceHealthState) -> Void) {
        lock.lock()
        var state = states[service] ?? ServiceHealthState()
        body(&state)
        states[service] = state
        let handlers = observers
        lock.unlock()
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler(service) }
        }
    }
}
