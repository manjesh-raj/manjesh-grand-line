// Manjesh Grand Line - native macOS app.
//
// F4 (production-readiness review, section 25): actionable notifications.
//
// Before this file, a macOS banner from `FleetNotifier`/`ShiftNotificationScheduler`
// was a dead end: it said "a task needs your decision" or "follow-up due now"
// and acting on it meant activating the app and navigating there by hand -
// which is the one thing PRODUCT.md's "glanceable, one click to act" principle
// exists to remove. This file adds `UNNotificationCategory` action buttons to
// those posts, plus a new "PR is green and ready to merge" post that carries a
// real Merge button (unblocked by GL-38, which fixed `mergePR`'s argv).
//
// ## The shape, and why it is split this way
//
// `NotificationActionRouting.resolve(...)` is a **pure function**: notification
// action identifier + the post's own `userInfo` payload in, a list of
// `NotificationRoutedAction` values out. It performs nothing. Every policy
// decision - including the merge gate - lives there, which is what makes the
// gate assertable without running a merge (`NotificationActionsSelfTest`).
//
// `NotificationActionRouter` is the `UNUserNotificationCenterDelegate` that
// performs those values, and it owns no logic of its own beyond dispatch: each
// case calls straight through to the code path the in-app UI already uses -
// `FleetDataSource.mergePR` (the same function Review's own Merge button
// calls post-GL-38), `AppShellController.show(_:)`/`openShiftTask(id:)`/
// `openShiftFollowUp(id:)`, and `ShiftStore.snoozeFollowUp(id:to:)`. There is
// deliberately no second merge implementation, no second navigation path and
// no second snooze path here; the router holds closures that are wired to the
// real ones in `main.swift`, the same forward-don't-own convention every other
// out-of-window surface in this app uses (see `NotificationSources`' header).
//
// ## The merge gate (the review's own security constraint)
//
// "Merge-from-notification should respect the same green-checks gate as the
// Review page." It is enforced twice, on purpose, and the two halves fail
// differently:
//
//   1. The button is not offered at all. `FleetNotifier.reconcilePRs` only
//      posts a PR notification for a PR that `FleetDataSource.canMerge`
//      already accepts, so a red/pending PR never carries a Merge action.
//   2. Invoking it is a genuine rejection. `resolve` re-checks the payload's
//      own `checks`/`taskID` through the *same* `FleetDataSource.canMerge`
//      definition the Review row uses and returns `.refused` rather than
//      `.merge` when it does not pass - so a stale notification sitting in
//      Notification Center from before a check turned red cannot merge, and
//      neither can a hand-crafted payload.
//
// ## Lock coverage (GL-09)
//
// A notification action runs while the main window is not frontmost and both
// discloses (navigates) and writes (merge, snooze) - exactly the rule
// `AppLockGate`'s header states - so every action consults
// `AppLockGate.shared.allows(.notificationAction)` before anything happens.
// A locked app therefore does what it did before this file: activating shows
// the lock screen and nothing else moves.

import AppKit
import UserNotifications

// MARK: - Identifiers

/// Category ids are stable strings written into posted notifications, so
/// renaming one silently strips the buttons off any notification already
/// sitting in Notification Center. Treat them as a wire format.
enum NotificationCategory {
    /// A PR is green and ready to merge: Merge / Open PR / Show in app.
    static let prReady = "fm.category.pr-ready"
    /// A fleet task needs a decision, is blocked, or just finished:
    /// Open task / Show in app.
    static let fleetTask = "fm.category.fleet-task"
    /// A Shift task is due or overdue: Open task / Show in app.
    static let shiftTask = "fm.category.shift-task"
    /// A Shift follow-up is due or overdue: Snooze 1h / Open follow-up.
    static let shiftFollowUp = "fm.category.shift-follow-up"
}

enum NotificationAction {
    static let merge = "fm.action.merge"
    static let openPR = "fm.action.open-pr"
    static let openFleetTask = "fm.action.open-fleet-task"
    static let openShiftTask = "fm.action.open-shift-task"
    static let openShiftFollowUp = "fm.action.open-shift-follow-up"
    static let snoozeFollowUpOneHour = "fm.action.snooze-follow-up-1h"
    /// The spec's generic fallback, offered on the categories where no more
    /// specific second action applies.
    static let showInApp = "fm.action.show-in-app"
}

// MARK: - Payload

/// The identifying information a posted notification carries so its action
/// handler knows what to act on. Deliberately a small flat string dictionary:
/// `userInfo` is archived by the system and may be handed back to a *later*
/// launch of the app, so it holds ids and a checks string - never a live
/// object, an index into an in-memory list, or anything that could go stale
/// into something that still looks valid.
struct NotificationPayload: Equatable {
    enum Subject: String {
        case prReady = "pr-ready"
        case fleetTask = "fleet-task"
        case shiftTask = "shift-task"
        case shiftFollowUp = "shift-follow-up"
    }

    var subject: Subject
    /// The firstmate task id behind a PR (`MergedPR.taskID`) or the fleet
    /// task's own id.
    var taskID: String?
    var prURL: String?
    /// `MergedPR.checks` verbatim ("green"/"red"/"pending"/"none"), so the
    /// gate below compares exactly what the Review page compares.
    var prChecks: String?
    var followUpID: String?
    /// A Shift task id (`ShiftTask.id`), distinct from `taskID`'s fleet id.
    var shiftTaskID: String?

    private enum Key {
        static let subject = "fm.subject"
        static let taskID = "fm.taskID"
        static let prURL = "fm.prURL"
        static let prChecks = "fm.prChecks"
        static let followUpID = "fm.followUpID"
        static let shiftTaskID = "fm.shiftTaskID"
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = [Key.subject: subject.rawValue]
        if let taskID { info[Key.taskID] = taskID }
        if let prURL { info[Key.prURL] = prURL }
        if let prChecks { info[Key.prChecks] = prChecks }
        if let followUpID { info[Key.followUpID] = followUpID }
        if let shiftTaskID { info[Key.shiftTaskID] = shiftTaskID }
        return info
    }

    init(subject: Subject, taskID: String? = nil, prURL: String? = nil, prChecks: String? = nil,
         followUpID: String? = nil, shiftTaskID: String? = nil) {
        self.subject = subject
        self.taskID = taskID
        self.prURL = prURL
        self.prChecks = prChecks
        self.followUpID = followUpID
        self.shiftTaskID = shiftTaskID
    }

    /// `nil` for anything that is not one of this app's own posts - including
    /// a notification from an older build, which had no payload at all. That
    /// case must route to nothing rather than to a guessed default.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Key.subject] as? String, let subject = Subject(rawValue: raw) else { return nil }
        self.init(
            subject: subject,
            taskID: userInfo[Key.taskID] as? String,
            prURL: userInfo[Key.prURL] as? String,
            prChecks: userInfo[Key.prChecks] as? String,
            followUpID: userInfo[Key.followUpID] as? String,
            shiftTaskID: userInfo[Key.shiftTaskID] as? String
        )
    }
}

// MARK: - Routing (pure)

/// What a tapped action resolves to. One action can resolve to more than one
/// of these (Open PR both leaves the app on Review and opens the URL), which
/// is why `resolve` returns an array.
enum NotificationRoutedAction: Equatable {
    case merge(taskID: String, url: String)
    case openURL(String)
    case show(RailDestination)
    case openShiftTask(id: String)
    case openShiftFollowUp(id: String)
    case snoozeFollowUp(id: String, seconds: TimeInterval)
    /// A deliberate refusal that the captain asked for and must not silently
    /// look like it worked - currently only a merge that fails the gate. The
    /// reason is surfaced as a notification by the router.
    case refused(reason: String)
}

enum NotificationActionRouting {

    /// The one snooze offset this feature offers, matching the spec's
    /// "Snooze follow-up 1h" and `ShiftSnoozeOption.hour1`'s own arithmetic.
    static let snoozeOneHour: TimeInterval = 60 * 60

    static func resolve(actionIdentifier: String, payload: NotificationPayload?) -> [NotificationRoutedAction] {
        guard let payload else { return [] }

        // Clicking the banner body (rather than an action button) is the
        // system's default action. Before this file it only activated the app;
        // treating it as "show in app" is what makes the body clickable in the
        // same sense the buttons are.
        let action = actionIdentifier == UNNotificationDefaultActionIdentifier
            ? NotificationAction.showInApp
            : actionIdentifier

        // Dismissing a notification is explicitly not an action.
        if action == UNNotificationDismissActionIdentifier { return [] }

        switch action {
        case NotificationAction.merge:
            // The gate. `FleetDataSource.canMerge` is the definition the
            // Review row's own button uses; this calls it rather than
            // restating "checks == green && taskID non-empty" a second time.
            guard payload.subject == .prReady, let url = payload.prURL, !url.isEmpty else {
                return [.refused(reason: "This notification carries no pull request to merge.")]
            }
            guard FleetDataSource.canMerge(checks: payload.prChecks ?? "", taskID: payload.taskID) else {
                return [.refused(reason: "Checks are not green for \(url) - merge refused.")]
            }
            return [.merge(taskID: payload.taskID ?? "", url: url)]

        case NotificationAction.openPR:
            guard let url = payload.prURL, !url.isEmpty else { return [.show(.review)] }
            // Review first, then the browser: the browser takes focus, so
            // doing it last leaves the app sitting on Review for when the
            // captain comes back - which is the "opens the Review page to
            // that PR" half of the spec. Review has no scroll-to-one-PR API,
            // so the PR itself is shown the way Review's own per-row button
            // shows it (`NSWorkspace.shared.open`).
            return [.show(.review), .openURL(url)]

        case NotificationAction.openFleetTask:
            // A fleet task has no page of its own; Overview is where its row,
            // its status and the decision banner live.
            return [.show(.overview)]

        case NotificationAction.openShiftTask:
            guard let id = payload.shiftTaskID, !id.isEmpty else { return [.show(.shift)] }
            return [.openShiftTask(id: id)]

        case NotificationAction.openShiftFollowUp:
            guard let id = payload.followUpID, !id.isEmpty else { return [.show(.shift)] }
            return [.openShiftFollowUp(id: id)]

        case NotificationAction.snoozeFollowUpOneHour:
            guard payload.subject == .shiftFollowUp, let id = payload.followUpID, !id.isEmpty else { return [] }
            return [.snoozeFollowUp(id: id, seconds: snoozeOneHour)]

        case NotificationAction.showInApp:
            switch payload.subject {
            case .prReady: return [.show(.review)]
            case .fleetTask: return [.show(.overview)]
            case .shiftTask:
                guard let id = payload.shiftTaskID, !id.isEmpty else { return [.show(.shift)] }
                return [.openShiftTask(id: id)]
            case .shiftFollowUp:
                guard let id = payload.followUpID, !id.isEmpty else { return [.show(.shift)] }
                return [.openShiftFollowUp(id: id)]
            }

        default:
            return []
        }
    }

    /// The action buttons per category, in the order the captain-approved
    /// mockup shows them (primary first).
    static func categories() -> Set<UNNotificationCategory> {
        let merge = UNNotificationAction(
            identifier: NotificationAction.merge, title: "Merge",
            // No `.foreground`: merging does not need the app brought to the
            // front, and yanking focus off whatever the captain is doing to
            // show them a page they did not ask for is the opposite of the
            // one-click principle. The outcome comes back as its own
            // notification (see `NotificationActionRouter.performMerge`).
            options: [.authenticationRequired])
        let openPR = UNNotificationAction(
            identifier: NotificationAction.openPR, title: "Open PR", options: [.foreground])
        let openFleetTask = UNNotificationAction(
            identifier: NotificationAction.openFleetTask, title: "Open task", options: [.foreground])
        let openShiftTask = UNNotificationAction(
            identifier: NotificationAction.openShiftTask, title: "Open task", options: [.foreground])
        let openFollowUp = UNNotificationAction(
            identifier: NotificationAction.openShiftFollowUp, title: "Open follow-up", options: [.foreground])
        let snooze = UNNotificationAction(
            identifier: NotificationAction.snoozeFollowUpOneHour, title: "Snooze 1h", options: [])
        let showInApp = UNNotificationAction(
            identifier: NotificationAction.showInApp, title: "Show in app", options: [.foreground])

        return [
            UNNotificationCategory(
                identifier: NotificationCategory.prReady,
                actions: [merge, openPR, showInApp], intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: NotificationCategory.fleetTask,
                actions: [openFleetTask, showInApp], intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: NotificationCategory.shiftTask,
                actions: [openShiftTask, showInApp], intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: NotificationCategory.shiftFollowUp,
                actions: [snooze, openFollowUp], intentIdentifiers: [], options: []),
        ]
    }
}

// MARK: - Router (performs)

/// Set as `UNUserNotificationCenter.current().delegate` once at launch, from
/// `AppDelegate.applicationDidFinishLaunching` - it has to be assigned before
/// that method returns or a cold-launch action tap is dropped by the system.
final class NotificationActionRouter: NSObject, UNUserNotificationCenterDelegate {

    /// Wired to the real `AppShellController`/`ShiftStore` methods in
    /// `main.swift`. Optional because this object is constructed before the
    /// shell exists, and injectable because that is what lets
    /// `NotificationActionsSelfTest` assert which real call each action maps
    /// to without a window, a store or a notification.
    var onShow: ((RailDestination) -> Void)?
    var onOpenShiftTask: ((String) -> Void)?
    var onOpenShiftFollowUp: ((String) -> Void)?
    var onSnoozeFollowUp: ((String, Date) -> Void)?
    var onOpenURL: ((String) -> Void)?

    /// Defaults to the exact function Review's own Merge button calls
    /// post-GL-38. Overridable only so the self-test can prove the routing
    /// reaches it (with the right arguments) without running a real merge.
    var mergeExecutor: (String, String) -> (ok: Bool, message: String) = { taskID, url in
        FleetDataSource.mergePR(taskID: taskID, url: url)
    }

    /// How a merge outcome and a refusal get back to the captain. A
    /// non-foreground action has no window to put an alert in, so the answer
    /// is another notification - overridable for the same test reason.
    var postFeedback: (String, String) -> Void = NotificationActionRouter.postFeedbackNotification

    /// Where a merge runs. `Subprocess`-backed and minutes-long, so never on
    /// the main thread; overridable so a self-test stays synchronous.
    var mergeQueue: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Whether actions are allowed to do anything at all (GL-09). Injected
    /// rather than read inline so the locked case is testable.
    var isAllowed: () -> Bool = { AppLockGate.shared.allows(.notificationAction) }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        handle(actionIdentifier: response.actionIdentifier,
               userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }

    /// Also shows a banner while the app is frontmost. Without this the system
    /// suppresses it entirely, which for an app whose whole notification story
    /// is "act from the banner" means the action buttons are unreachable
    /// exactly when the captain is already at the keyboard.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Performing

    /// Split out from the delegate method so the self-test can drive the real
    /// routing/performing path with a plain dictionary - `UNNotificationResponse`
    /// cannot be constructed outside the system.
    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard isAllowed() else {
            AppLog.lifecycle.info("notification action refused - app is locked (GL-09)")
            return
        }
        let payload = NotificationPayload(userInfo: userInfo)
        for action in NotificationActionRouting.resolve(actionIdentifier: actionIdentifier, payload: payload) {
            perform(action)
        }
    }

    func perform(_ action: NotificationRoutedAction) {
        switch action {
        case let .merge(taskID, url):
            performMerge(taskID: taskID, url: url)
        case let .openURL(raw):
            if let handler = onOpenURL {
                handler(raw)
            } else if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case let .show(destination):
            onShow?(destination)
        case let .openShiftTask(id):
            onOpenShiftTask?(id)
        case let .openShiftFollowUp(id):
            onOpenShiftFollowUp?(id)
        case let .snoozeFollowUp(id, seconds):
            onSnoozeFollowUp?(id, Date().addingTimeInterval(seconds))
        case let .refused(reason):
            AppLog.ui.error("notification action refused: \(reason, privacy: .public)")
            postFeedback("Merge refused", reason)
        }
    }

    private func performMerge(taskID: String, url: String) {
        let executor = mergeExecutor
        let feedback = postFeedback
        mergeQueue {
            let result = executor(taskID, url)
            feedback(result.ok ? "Merged" : "Merge failed", result.ok ? url : result.message)
        }
    }

    private static func postFeedbackNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "fm.action-result.\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: Registration

    /// Registers the categories above, so a posted notification's
    /// `categoryIdentifier` actually resolves to buttons, and installs `self`
    /// as the delegate. Guarded on a real bundle identifier for the same
    /// reason every other `UNUserNotificationCenter` call site in this app is:
    /// `current()` throws an uncaught exception on the bare `swift build`
    /// binary (see `ShiftNotificationScheduler.start`'s header).
    func register() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationActionRouting.categories())
    }
}
