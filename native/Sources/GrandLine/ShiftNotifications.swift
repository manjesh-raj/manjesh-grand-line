// Grand Line - native macOS app.
//
// Local notifications for due tasks and follow-ups (phase 5, cockpit-shift-
// power-features). Follows `FleetNotifier.swift`'s established shape
// (background poll + "already notified" set + an immediate, trigger-less
// `UNNotificationRequest`) rather than `UNCalendarNotificationTrigger`
// scheduling - simpler to reason about and verify, and consistent with the
// one other place this app already does due-item alerting.
//
// Authorization is requested once at `start()` (safe to call every launch -
// a no-op once already determined, same as `FleetNotifier.start()`) and
// every call site here tolerates a denial gracefully: `requestAuthorization`'s
// `granted` flag is only logged, never asserted on, and `poll()` still runs
// on schedule regardless - `UNUserNotificationCenter.add` simply drops a
// request silently if the user never granted permission, so there is
// nothing to special-case in the scheduling logic itself.

import Foundation
import UserNotifications

final class ShiftNotificationScheduler {
    private let store: ShiftStore
    private var timer: Timer?

    /// `fm/grandline-notification-center`: fired on every poll with the
    /// current due-or-overdue counts (signal #8) - feeds the in-app
    /// Notification Center the same due-detection this scheduler already
    /// runs for the OS banner below, rather than a second implementation of
    /// "is this due." Unlike the banner's own once-per-distinct-due-Date
    /// dedup, this reflects the live count every poll (`nil`/0 clears it),
    /// since the in-app entry's own clear rule is "clears when completed,"
    /// not "clears once you've been told."
    /// `(due tasks, due follow-ups, how many of those are already overdue)`.
    ///
    /// The third is what puts the Notification Center row in "Needs action"
    /// rather than "Available" (`fm/grandline-notification-center-redesign`):
    /// something due in the next hour is an FYI, something that was due
    /// yesterday is not. `due <= now` is the same comparison this poll already
    /// makes to choose between "due now" and "due soon" in the banner's own
    /// title, so there is one definition of overdue rather than two.
    var onDueCountsChanged: ((Int, Int, Int) -> Void)?

    /// Each due item is notified once per distinct due `Date` - if a task's
    /// due date/time changes (edited, or pushed back), the new value is a
    /// fresh key and can notify again; snoozing/editing to the *same* value
    /// twice does not double-notify.
    private var notifiedTaskDueAt: [String: Date] = [:]
    private var notifiedFollowUpDueAt: [String: Date] = [:]

    private let pollInterval: TimeInterval = 60
    /// How far ahead of a due date/time to fire the reminder - matches the
    /// brief's "due tasks and follow-ups coming up" (not just exactly-on-time
    /// alerts, which a 60s poll could easily miss by a few seconds).
    private let lookahead: TimeInterval = 30 * 60

    init(store: ShiftStore) {
        self.store = store
    }

    /// Safe to call every launch. Requests notification permission
    /// (gracefully - see this file's header) and starts the poll if it
    /// isn't already running.
    ///
    /// `UNUserNotificationCenter.current()` throws an uncaught
    /// `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is
    /// nil") when the running process has no real Info.plist/bundle
    /// identifier - true for the bare `swift run`/`.build/debug/
    /// GrandLine` dev workflow this project's own README documents as
    /// normal (confirmed live: this crashed on every launch under that
    /// workflow until this guard was added, exactly the same class of crash
    /// `UpdatesController.notify`'s own header already documents and guards
    /// against). The packaged app (`build_native_app.sh`'s output, a real
    /// bundle) is unaffected either way - the poll timer still runs
    /// regardless, it just can't touch `UNUserNotificationCenter` from a
    /// bare binary.
    func start() {
        guard timer == nil else { return }
        ServiceHealthRegistry.shared.register(.shiftDueItems)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if !granted {
                    let reason = error?.localizedDescription ?? "denied"
                    AppLog.poller.error("""
                        Tasks: notification permission not granted (\(reason, privacy: .public)) - \
                        due-item reminders will not appear until it is.
                        """)
                    // A permission the captain declined is a real, permanent
                    // reason this service cannot do its job, and it is
                    // invisible everywhere else.
                    ServiceHealthRegistry.shared.recordFailure(
                        .shiftDueItems,
                        "Notification permission not granted (\(reason)). Enable it in System Settings > Notifications.")
                }
            }
        }
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 10
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Exposed (not `private`) so a self-test / debug probe can force one
    /// check without waiting for the timer - mirrors how `FleetNotifier`'s
    /// own poll cycle is exercised in this codebase (a temporary env-gated
    /// probe, per AGENTS.md's "Verifying native UI bugs" convention).
    func poll() {
        ServiceHealthRegistry.shared.recordSuccess(.shiftDueItems)
        let now = Date()
        let horizon = now.addingTimeInterval(lookahead)

        var dueTaskCount = 0
        var overdueCount = 0
        // B22: nothing ever withdrew a delivered banner, so completing or
        // deleting a task left "Task due now" sitting in Notification Center
        // for the rest of the day. Collected as the live items are walked and
        // reconciled against what this poller believes it has posted.
        var liveTaskIDs: Set<String> = []
        var liveFollowUpIDs: Set<String> = []
        for task in store.activeTasks {
            guard let due = ShiftDue.reminderInstant(date: task.dueDate, time: task.dueTime) else { continue }
            liveTaskIDs.insert(task.id)
            // F5's "remind me N minutes before": the per-task offset replaces
            // this scheduler's own `lookahead` for the task that carries one,
            // rather than adding a second mechanism beside it. A task with no
            // offset keeps the exact behaviour it had.
            guard due <= Self.horizon(for: task, now: now, default: horizon) else { continue }
            dueTaskCount += 1
            // B22: `due <= now` called a date-only task overdue at local
            // midnight, while the task list beside it did not until the next
            // day. One definition now, and it is the list's.
            if ShiftDue.isOverdue(date: task.dueDate, time: task.dueTime, now: now) { overdueCount += 1 }
            guard notifiedTaskDueAt[task.id] != due else { continue }
            notifiedTaskDueAt[task.id] = due
            notify(
                title: ShiftDue.taskTitle(date: task.dueDate, time: task.dueTime, now: now),
                body: task.title,
                identifier: "shift.task.\(task.id)",
                // F4: an "Open task" button routing through the same
                // `AppShellController.openShiftTask(id:)` a search-palette hit
                // uses. Everything else about this post is unchanged.
                category: NotificationCategory.shiftTask,
                payload: NotificationPayload(subject: .shiftTask, shiftTaskID: task.id)
            )
        }

        var dueFollowUpCount = 0
        for followUp in store.followUps where followUp.status == .pending {
            guard let due = ShiftDue.reminderInstant(date: followUp.followUpAt,
                                                     time: followUp.followUpTime) else { continue }
            liveFollowUpIDs.insert(followUp.id)
            guard due <= horizon else { continue }
            dueFollowUpCount += 1
            if ShiftDue.isOverdue(date: followUp.followUpAt, time: followUp.followUpTime,
                                  now: now) { overdueCount += 1 }
            guard notifiedFollowUpDueAt[followUp.id] != due else { continue }
            notifiedFollowUpDueAt[followUp.id] = due
            notify(
                title: ShiftDue.followUpTitle(date: followUp.followUpAt,
                                              time: followUp.followUpTime, now: now),
                body: followUp.title,
                identifier: "shift.followup.\(followUp.id)",
                // F4: "Snooze 1h" (the real `ShiftStore.snoozeFollowUp`, the
                // same write the row's own Snooze menu performs) plus "Open
                // follow-up". A follow-up is the one signal in this app whose
                // most common answer is "not now", which is why it gets the
                // snooze rather than a generic "Show in app".
                category: NotificationCategory.shiftFollowUp,
                payload: NotificationPayload(subject: .shiftFollowUp, followUpID: followUp.id)
            )
        }

        withdrawStaleNotifications(liveTaskIDs: liveTaskIDs, liveFollowUpIDs: liveFollowUpIDs)

        onDueCountsChanged?(dueTaskCount, dueFollowUpCount, overdueCount)
    }

    /// B22: takes back every banner whose item is gone.
    ///
    /// "Gone" is deliberately broad: completed, deleted, a follow-up answered,
    /// or a due date simply cleared - none of those items is in the live set,
    /// and in every one of them a banner that still says "Task due now" is a
    /// lie the captain has to dismiss by hand. The memo is dropped with it, so
    /// re-adding the same due date later notifies again rather than being
    /// silently deduped against a banner that no longer exists.
    private func withdrawStaleNotifications(liveTaskIDs: Set<String>,
                                            liveFollowUpIDs: Set<String>) {
        var stale: [String] = []
        for id in notifiedTaskDueAt.keys where !liveTaskIDs.contains(id) {
            stale.append("shift.task.\(id)")
            notifiedTaskDueAt[id] = nil
        }
        for id in notifiedFollowUpDueAt.keys where !liveFollowUpIDs.contains(id) {
            stale.append("shift.followup.\(id)")
            notifiedFollowUpDueAt[id] = nil
        }
        guard !stale.isEmpty else { return }
        withdraw(stale)
    }

    /// The one place a banner is taken back. Both the delivered copy and any
    /// still-pending request: a request that has not fired yet would otherwise
    /// arrive after the task was completed.
    private func withdraw(_ identifiers: [String]) {
        #if FM_SELFTESTS
        if let sink = Self.withdrawSinkForTests {
            sink(identifiers)
            return
        }
        #endif
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    #if FM_SELFTESTS
    /// GL-27. The same seam shape `SnippetExpander.injectionSinkForTests` uses,
    /// and for the same reason: `UNUserNotificationCenter` cannot be reached
    /// at all from the unbundled test binary, so what a suite can assert is
    /// exactly *which identifiers* would have been withdrawn.
    static var withdrawSinkForTests: (([String]) -> Void)?

    /// Which items this poller currently believes it has a live banner for.
    var debugNotifiedTaskIDs: [String] { Array(notifiedTaskDueAt.keys) }
    var debugNotifiedFollowUpIDs: [String] { Array(notifiedFollowUpDueAt.keys) }
    #endif

    /// How far ahead of `task`'s due time this poll is willing to fire.
    ///
    /// `static` and parameterised so the pure-logic suite can assert the rule
    /// without a timer, a store or a notification centre - the whole of what
    /// "remind me N minutes before" means is this one comparison.
    ///
    /// `0` is a real offset ("at the due time") and is deliberately not the
    /// same as `nil` ("this app's default lookahead"), which is why the
    /// optional is unwrapped rather than defaulted.
    static func horizon(for task: ShiftTask, now: Date, default fallback: Date) -> Date {
        guard let minutes = task.reminderMinutesBefore else { return fallback }
        return now.addingTimeInterval(TimeInterval(max(0, minutes) * 60))
    }

    private func notify(title: String, body: String, identifier: String,
                        category: String, payload: NotificationPayload) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // F4: which buttons this post carries, and what they act on. The
        // handler is `NotificationActionRouter` - see NotificationActions.swift.
        content.categoryIdentifier = category
        content.userInfo = payload.userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
