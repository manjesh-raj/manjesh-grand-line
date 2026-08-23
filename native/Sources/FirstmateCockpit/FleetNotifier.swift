// Manjesh Grand Line - native macOS app.
//
// Settings > Terminal's "Bell & notifications" toggle (Fix 3): a real
// background poll of the same task state `FleetController` reads, so a
// crewmate parking on a decision surfaces a macOS notification even while
// the captain is looking at a different rail destination - mirroring the
// web app's "Surface a desktop notification the moment a crewmate needs
// your decision." `FleetController`'s own on-appear refresh is not enough
// for that promise, since it only runs while Overview is on screen.
//
// `fm/grandline-notification-center` extended this poll two ways:
//   1. It also detects a task finishing (done/failed) while the captain
//      wasn't looking - the design doc's signal #9, which had no other
//      computed home anywhere in the app. `reconcile(_:)` tracks this
//      separately from the pre-existing needs-decision/blocked tracking.
//   2. The poll itself now ALWAYS runs from app launch (`start()`, called
//      unconditionally in `main.swift`), decoupled from the "Bell &
//      notifications" Settings toggle - `setEnabled` now only gates whether
//      a macOS banner is actually posted (`osBannersEnabled`), not whether
//      detection happens at all. This is a deliberate architectural choice
//      for the in-app Notification Center: it must stay current whether or
//      not the captain has opted into OS banners, since the design doc
//      frames it as an always-on core feature, not something you turn on.
//      The OS banner and the in-app entry are two independent presentations
//      of the same detected event now, not one gating the other.
//
// A finished task is acknowledged (and stops resurfacing in the in-app
// center) the moment the captain opens the aggregated notification - see
// `acknowledgeFinishedTasks(ids:)`, called from the notification's own
// `navigate` closure (`NotificationSources.setFleetFinished`). This is
// separate from `seenFinishedForBanner`, which only dedups the one-shot OS
// banner and has no "did the captain actually see it" concept.

import Foundation
import UserNotifications

final class FleetNotifier {
    static let shared = FleetNotifier()

    private var timer: Timer?
    private var seenNeedsDecision: Set<String> = []
    private var seenFinishedForBanner: Set<String> = []
    /// F4: PR URLs already banner-notified as ready to merge - see
    /// `reconcilePRs`. Not seeded at launch (unlike the two sets above): a PR
    /// sitting green when the app starts is genuinely news this app has not
    /// told the captain yet, and the system's own identifier dedup keeps a
    /// relaunch from stacking duplicates.
    private var seenReadyPRs: Set<String> = []
    private var acknowledgedFinishedIDs: Set<String> = []
    private var osBannersEnabled = false
    private let pollInterval: TimeInterval = 30

    /// Forwarded navigation for the in-app "N tasks finished" entry -
    /// mirrors `ConsoleComposerController.onRunInTerminal`'s own forward-
    /// don't-own convention. Set once at launch in `main.swift`.
    var onNavigateToOverview: (() -> Void)?

    private init() {}

    /// Always safe to call once at launch, regardless of the "Bell &
    /// notifications" setting - see the file header. Seeds both "already
    /// seen" sets with whatever is true right now, so turning this on for
    /// the first time (every launch) never treats pre-existing state as a
    /// fresh transition.
    func start() {
        guard timer == nil else { return }
        ServiceHealthRegistry.shared.register(.fleetTasks)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = FleetDataSource.parseTasks()
            let decisionIDs = Set(tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }.map(\.id))
            let finishedIDs = Set(tasks.filter { $0.status == "done" || $0.status == "failed" }.map(\.id))
            DispatchQueue.main.async {
                guard let self else { return }
                self.seenNeedsDecision = decisionIDs
                self.seenFinishedForBanner = finishedIDs
                // A task already done/failed before this launch is not
                // "finished while you weren't looking" for the in-app
                // center either - primed as already-acknowledged.
                self.acknowledgedFinishedIDs = finishedIDs
            }
        }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 5
        timer = t
    }

    /// The "Bell & notifications" Settings toggle - gates whether a macOS
    /// banner is posted (and requests notification permission the first
    /// time it's turned on). Does NOT start/stop the poll itself; `start()`
    /// (always called once at launch) owns that, so the in-app Notification
    /// Center stays current either way.
    func setEnabled(_ enabled: Bool) {
        osBannersEnabled = enabled
        guard enabled, Bundle.main.bundleIdentifier != nil else { return }
        // UNUserNotificationCenter.current() throws an uncaught NSInternalInconsistencyException
        // ("bundleProxyForCurrentProcess is nil") on a process with no real bundle identifier -
        // true for the bare `.build/debug/FirstmateCockpit`/`swift run` dev binary. See
        // UpdatesController.notify/ShiftNotifications' identical guard for the same reason.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        ServiceHealthRegistry.shared.markRunning(.fleetTasks)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = FleetDataSource.parseTasks()
            DispatchQueue.main.async {
                // F1: "reachable, and this is what it said." An unreadable
                // FM_HOME or a wedged `fm-crew-state.sh` yields no tasks, which
                // used to be indistinguishable from a genuinely idle fleet -
                // exactly the failure shape GL-14 names for the PR list.
                if FirstmateHome.homeOk(at: FirstmateHome.root) {
                    ServiceHealthRegistry.shared.recordSuccess(.fleetTasks)
                } else {
                    ServiceHealthRegistry.shared.recordFailure(
                        .fleetTasks,
                        "Firstmate home is not readable at \(FirstmateHome.root.path) - set it in Setup > Bootstrap.")
                }
                self?.reconcile(tasks)
            }
        }
    }

    private func reconcile(_ tasks: [FleetTask]) {
        let decisionTasks = tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }
        let currentDecisionIDs = Set(decisionTasks.map(\.id))
        let freshDecisions = decisionTasks.filter { !seenNeedsDecision.contains($0.id) }
        seenNeedsDecision = currentDecisionIDs
        if osBannersEnabled {
            for task in freshDecisions { notify(task) }
        }

        let finishedTasks = tasks.filter { $0.status == "done" || $0.status == "failed" }
        let currentFinishedIDs = Set(finishedTasks.map(\.id))
        let freshFinished = finishedTasks.filter { !seenFinishedForBanner.contains($0.id) }
        seenFinishedForBanner = currentFinishedIDs
        if osBannersEnabled {
            for task in freshFinished { notifyFinished(task) }
        }

        // In-app Notification Center: signal #1 (needs-decision/blocked) is
        // fed from `FleetController.onNeedsDecisionCountChanged` instead
        // (already computed for the rail badge - see `AppShellController.
        // loadView()`) - not duplicated here. Signal #9 (finished tasks) has
        // no other computed home, so this poll is its one source.
        let unacknowledged = finishedTasks.filter { !acknowledgedFinishedIDs.contains($0.id) }
        NotificationSources.setFleetFinished(unacknowledged) { [weak self] in
            self?.acknowledgeFinishedTasks(ids: unacknowledged.map(\.id))
            self?.onNavigateToOverview?()
        }
    }

    /// Marks every task id in `ids` as already-seen by the in-app center, so
    /// it never resurfaces on a later poll purely because its `.meta` file
    /// is still sitting there marked done/failed (state files are not
    /// deleted by this poll). Not `private` so a debug probe / self-test can
    /// exercise this directly.
    func acknowledgeFinishedTasks(ids: [String]) {
        acknowledgedFinishedIDs.formUnion(ids)
    }

    private func notify(_ task: FleetTask) {
        let content = UNMutableNotificationContent()
        content.title = task.status == "blocked" ? "Task blocked" : "Task needs your decision"
        content.body = task.repo != nil ? "\(task.id) (\(task.repo!))" : task.id
        content.sound = .default
        // F4: an "Open task" button, so the captain does not have to activate
        // the app and find Overview by hand. Title/body/identifier/sound are
        // deliberately unchanged - a captain who never touches a button sees
        // exactly the notification this posted before F4.
        content.categoryIdentifier = NotificationCategory.fleetTask
        content.userInfo = NotificationPayload(subject: .fleetTask, taskID: task.id).userInfo
        let request = UNNotificationRequest(identifier: "fm.needs-decision.\(task.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyFinished(_ task: FleetTask) {
        let content = UNMutableNotificationContent()
        content.title = task.status == "failed" ? "Task failed" : "Task finished"
        content.body = task.repo != nil ? "\(task.id) (\(task.repo!))" : task.id
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.fleetTask
        content.userInfo = NotificationPayload(subject: .fleetTask, taskID: task.id).userInfo
        let request = UNNotificationRequest(identifier: "fm.finished.\(task.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: F4 - "a PR is green and ready to merge"

    /// The one post in this app that carries a real Merge button, and the
    /// reason F4 waited on GL-38.
    ///
    /// There was no OS banner for this signal at all before F4 - the in-app
    /// Notification Center had `NotificationSources.setPRReady` (a count, fed
    /// from Review's own `onOpenPRCountChanged`), but nothing ever reached the
    /// captain while they were looking at something else. This lives here
    /// rather than in `ReviewController` for the same reason the two posts
    /// above do: this class already owns the "seen since launch" bookkeeping
    /// and the `osBannersEnabled` gate, and duplicating either in a view
    /// controller is how a signal starts double-firing.
    ///
    /// **The first half of the merge gate.** Only a PR that
    /// `FleetDataSource.canMerge` already accepts is posted at all, so a
    /// red/pending PR never carries a Merge action to begin with; the second
    /// half (a re-check when the button is actually tapped) lives in
    /// `NotificationActionRouting.resolve`. See `NotificationActions.swift`'s
    /// header for why both exist.
    ///
    /// Called from `ReviewController.render` via `AppShellController` - i.e.
    /// exactly when Review already recomputed its own list, with no new poll.
    func reconcilePRs(_ prs: [MergedPR]) {
        let mergeable = prs.filter { FleetDataSource.canMerge($0) }
        let currentURLs = Set(mergeable.map(\.url))
        let fresh = mergeable.filter { !seenReadyPRs.contains($0.url) }
        // Assigned, not unioned: a PR whose checks go back to red (or that
        // gets merged) drops out and can legitimately notify again if it
        // later becomes ready once more.
        seenReadyPRs = currentURLs
        guard osBannersEnabled else { return }
        for pr in fresh { notifyPRReady(pr) }
    }

    private func notifyPRReady(_ pr: MergedPR) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "PR ready to merge"
        let label = pr.number != nil ? "PR #\(pr.number!)" : "A pull request"
        let named = pr.title.isEmpty ? label : "\(label) \u{201C}\(pr.title)\u{201D}"
        content.body = pr.repo.isEmpty
            ? "\(named) is green and ready to merge."
            : "\(named) in \(pr.repo) is green and ready to merge."
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.prReady
        content.userInfo = NotificationPayload(
            subject: .prReady, taskID: pr.taskID, prURL: pr.url, prChecks: pr.checks
        ).userInfo
        // Keyed on the URL so re-posting for the same PR replaces rather than
        // stacks - an `identifier` collision is the system's own dedup.
        let request = UNNotificationRequest(
            identifier: "fm.pr-ready.\(pr.url)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
