// Manjesh Grand Line - native macOS app.
//
// Thin adapters (`fm/grandline-notification-center`) that turn each already-
// computed signal listed in the captain-approved design doc's inventory
// table into an `AppNotification` and hand it to
// `GrandLineNotificationCenter.shared.set(_:id:)`. No detection logic lives
// here - every function takes a count (or list) a page/poller already
// computed and only owns the id/title/subtext/tint/kind formatting, so
// there is exactly one place to read "what does each signal's notification
// actually say."
//
// Call sites (not owned by this file):
//   - Fleet decisions (#1) / PR ready (#2): `AppShellController.loadView()`,
//     piggybacking on the existing `onNeedsDecisionCountChanged`/
//     `onReadyToMergeCountChanged` callbacks that already drive the rail badges -
//     no new poll, updates exactly when those pages' own counts do.
//   - Tool updates (#3) / GitHub Sync (#4) / Vault (#5) / setup drift (#6):
//     `BackgroundSignalsPoller.swift`, a dedicated slow poll (see that
//     file's header for the cadence tradeoff) plus a feed from each page's
//     own on-visit check where wired.
//   - SRE Lead reply (#7): `ConsoleController`/`AppShellController.connectHost`.
//   - Shift due (#8): `ShiftNotificationScheduler.poll()`.
//   - Fleet finished (#9): `FleetNotifier.reconcile(_:)`.

import Foundation

enum NotificationSources {

    // MARK: #1 - Fleet task needs a decision / is blocked

    static let fleetDecisionsID = "fleet-decisions"

    static func setFleetDecisions(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: fleetDecisionsID)
            return
        }
        let title = count == 1 ? "1 task needs your decision" : "\(count) tasks need your decision"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: fleetDecisionsID, title: title,
                subtext: count == 1 ? "Waiting on your answer" : "Waiting on your answers",
                source: "Fleet",
                clearCondition: "Clears when you answer.",
                kind: .actionNeeded, tint: .warn,
                primaryAction: AppNotificationAction(label: "Answer", doneMessage: "Opened Fleet",
                                                     perform: navigate),
                navigate: navigate
            ),
            id: fleetDecisionsID
        )
    }

    // MARK: #2 - PR ready to merge

    static let prReadyID = "pr-ready"

    static func setPRReady(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: prReadyID)
            return
        }
        let title = count == 1 ? "1 PR ready to merge" : "\(count) PRs ready to merge"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: prReadyID, title: title,
                subtext: "Checks are green",
                source: "Review",
                clearCondition: "Clears when merged.",
                kind: .actionNeeded, tint: .good,
                primaryAction: AppNotificationAction(label: "Review", doneMessage: "Opened Review",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: prReadyID
        )
    }

    // MARK: #3 - A tool has an update available

    static let toolUpdatesID = "tool-updates"

    /// `children` are the tools themselves - name plus the version pair - each
    /// carrying the Updates page's own per-row update as its `perform`, so the
    /// redesigned popover can install one tool without navigating anywhere.
    /// They default to empty, which is what every caller that only knows a
    /// count (the poller's own cached reading, a suite) passes: the row then
    /// renders without a disclosure triangle rather than with an empty one.
    static func setToolUpdates(count: Int,
                               children: [AppNotificationChild] = [],
                               updateAll: (() -> Void)? = nil,
                               navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: toolUpdatesID)
            return
        }
        let title = count == 1 ? "1 tool has an update" : "\(count) tools have updates"
        // The reference's own detail line for this row: the tools themselves,
        // which is the only part a captain reads before deciding. With no
        // names to hand, say so plainly rather than inventing a count again -
        // the title already carries the count.
        let detail = children.isEmpty
            ? "Ready to install"
            : children.map(\.name).joined(separator: ", ")
        let action = updateAll.map {
            AppNotificationAction(label: count == 1 ? "Update" : "Update all",
                                  doneMessage: count == 1 ? "Updating the tool" : "Updating every tool",
                                  perform: $0)
        } ?? AppNotificationAction(label: "Open Updates", doneMessage: "Opened Updates", perform: navigate)
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: toolUpdatesID, title: title,
                subtext: detail,
                source: "Updates",
                clearCondition: "Clears when every update is installed.",
                kind: .informational, tint: .info,
                children: children,
                primaryAction: action,
                navigate: navigate
            ),
            id: toolUpdatesID
        )
    }

    // MARK: #4 - A personal fork is behind/diverged from upstream

    static let githubSyncID = "github-sync"

    /// Same shape as `setToolUpdates` - `children` are the forks, furthest
    /// behind first, each carrying the GitHub Sync page's own per-row sync.
    static func setGitHubSync(count: Int,
                              children: [AppNotificationChild] = [],
                              syncAll: (() -> Void)? = nil,
                              navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: githubSyncID)
            return
        }
        let title = count == 1 ? "1 fork is behind upstream" : "\(count) forks are behind upstream"
        // The reference names the worst offender rather than listing six repo
        // names into a truncation - that is the fact that decides whether this
        // is worth opening now.
        let detail = children.first.map { "Furthest behind: \($0.name)" } ?? "Ready to fast-forward"
        let action = syncAll.map {
            AppNotificationAction(label: count == 1 ? "Sync" : "Sync all",
                                  doneMessage: count == 1 ? "Syncing the fork" : "Syncing every fork",
                                  perform: $0)
        } ?? AppNotificationAction(label: "Open GitHub Sync", doneMessage: "Opened GitHub Sync", perform: navigate)
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: githubSyncID, title: title,
                subtext: detail,
                source: "GitHub Sync",
                clearCondition: "Clears when each fork is synced.",
                kind: .informational, tint: .violet,
                children: children,
                primaryAction: action,
                navigate: navigate
            ),
            id: githubSyncID
        )
    }

    // MARK: #5 - A security/hardener tool needs attention

    static let vaultAttentionID = "vault-attention"

    static func setVaultAttention(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: vaultAttentionID)
            return
        }
        let title = count == 1 ? "1 security tool needs attention" : "\(count) security tools need attention"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: vaultAttentionID, title: title,
                subtext: count == 1 ? "One launcher is unhardened" : "\(count) launchers are unhardened",
                source: "Vault",
                clearCondition: "Clears when each tool is hardened.",
                kind: .informational, tint: .violet,
                primaryAction: AppNotificationAction(label: "Open Vault", doneMessage: "Opened Vault",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: vaultAttentionID
        )
    }

    // MARK: #6 - Machine setup has drifted

    static let setupDriftID = "setup-drift"

    static func setSetupDrift(count: Int,
                              children: [AppNotificationChild] = [],
                              navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: setupDriftID)
            return
        }
        let title = count == 1 ? "1 setup item has drifted" : "\(count) setup items have drifted"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: setupDriftID, title: title,
                subtext: children.isEmpty
                    ? "Setup check drifted"
                    : children.map(\.name).joined(separator: ", "),
                source: "Bootstrap",
                clearCondition: "Clears when the check passes again.",
                kind: .informational, tint: .warn,
                children: children,
                primaryAction: AppNotificationAction(label: "Fix", doneMessage: "Opened Bootstrap",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: setupDriftID
        )
    }

    // MARK: #7 - SRE Lead answered a question on a tab you're not looking at (per tab)

    static func sreLeadReplyID(tabID: UUID) -> String { "sre-lead.\(tabID.uuidString)" }

    static func setSRELeadReply(tabID: UUID, tabName: String, hostLabel: String, navigate: @escaping () -> Void) {
        let id = sreLeadReplyID(tabID: tabID)
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: id, title: "SRE Lead replied on \u{201c}\(tabName)\u{201d}",
                subtext: hostLabel,
                source: "Console",
                clearCondition: "Clears when you open the tab.",
                kind: .actionNeeded, tint: .good,
                primaryAction: AppNotificationAction(label: "Read", doneMessage: "Opened \(tabName)",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: id
        )
    }

    static func clearSRELeadReply(tabID: UUID) {
        GrandLineNotificationCenter.shared.remove(id: sreLeadReplyID(tabID: tabID))
    }

    // MARK: #8 - A Shift task/follow-up is due or overdue

    static let shiftDueID = "shift-due"

    static func setShiftDue(taskCount: Int, followUpCount: Int, overdueCount: Int = 0,
                            navigate: @escaping () -> Void) {
        let total = taskCount + followUpCount
        guard total > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: shiftDueID)
            return
        }
        let title: String
        if taskCount > 0 && followUpCount > 0 {
            title = "\(total) tasks/follow-ups due or overdue"
        } else if taskCount > 0 {
            title = taskCount == 1 ? "1 task due or overdue" : "\(taskCount) tasks due or overdue"
        } else {
            title = followUpCount == 1 ? "1 follow-up due or overdue" : "\(followUpCount) follow-ups due or overdue"
        }
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: shiftDueID, title: title,
                subtext: overdueCount > 0
                    ? (overdueCount == 1 ? "1 is overdue" : "\(overdueCount) are overdue")
                    : "Due today",
                source: "Tasks",
                clearCondition: "Clears when you mark them complete.",
                // Overdue work is not an FYI. The panel's own two-tier
                // grouping is what makes this distinction visible, so a source
                // that knows something is late has to say so here.
                kind: overdueCount > 0 ? .actionNeeded : .informational,
                tint: .warn,
                timeText: overdueCount > 0 ? "overdue" : nil,
                isWarning: overdueCount > 0,
                primaryAction: AppNotificationAction(label: "Open Tasks", doneMessage: "Opened Tasks",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: shiftDueID
        )
    }

    // MARK: #9 - A fleet task finished (done/failed) while you weren't looking

    static let fleetFinishedID = "fleet-finished"

    static func setFleetFinished(_ tasks: [FleetTask], navigate: @escaping () -> Void) {
        guard !tasks.isEmpty else {
            GrandLineNotificationCenter.shared.set(nil, id: fleetFinishedID)
            return
        }
        let anyFailed = tasks.contains { $0.status == "failed" }
        let title = tasks.count == 1 ? "1 task finished" : "\(tasks.count) tasks finished"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: fleetFinishedID, title: title,
                subtext: anyFailed ? "At least one failed" : "All finished cleanly",
                source: "Fleet",
                clearCondition: "Clears when you read the result.",
                kind: .actionNeeded, tint: anyFailed ? .critical : .good,
                isWarning: anyFailed,
                children: tasks.prefix(8).map { task in
                    AppNotificationChild(id: task.id, name: task.id, meta: task.status)
                },
                primaryAction: AppNotificationAction(label: "Open", doneMessage: "Opened Fleet",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: fleetFinishedID
        )
    }

    // MARK: #10 - A background service has failed repeatedly (GL-11 / GL-30)

    /// Where "show me" goes for the two entries below. Set once, from
    /// `AppShellController.loadView()`, to "select Settings and scroll to the
    /// Health card" - the entries themselves are raised from background queues
    /// that know nothing about destinations, which is the same
    /// forward-don't-own split every other signal here uses.
    static var navigateToHealth: (() -> Void)?

    static func serviceFailingID(_ service: HealthService) -> String {
        "service-failing.\(service.rawValue)"
    }

    /// Raised by `ServiceHealthRegistry` once a service has failed
    /// `failureThreshold` times in a row - not on the first failure, which for
    /// a laptop off the network is ordinary noise rather than news.
    /// `.informational`, so it can be dismissed: the captain who already knows
    /// they are offline should not have to keep being told.
    static func setServiceFailing(_ service: HealthService, failures: Int, detail: String) {
        let id = serviceFailingID(service)
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: id,
                title: "\(service.title) keeps failing",
                subtext: "\(failures) failures in a row \u{00B7} \(shortDetail(detail))",
                source: "Settings",
                clearCondition: "Clears when the service answers again.",
                kind: .informational, tint: .warn,
                primaryAction: AppNotificationAction(label: "Open Health", doneMessage: "Opened Settings",
                                                    perform: { navigateToHealth?() }),
                navigate: { navigateToHealth?() }
            ),
            id: id
        )
    }

    static func clearServiceFailing(_ service: HealthService) {
        GrandLineNotificationCenter.shared.set(nil, id: serviceFailingID(service))
    }

    // MARK: #11 - A save did not reach disk (GL-10 / GL-30)

    static let persistenceFailureID = "persistence-failure"

    /// The user-facing half of GL-10. A failed write used to be swallowed by
    /// `try?`, so the UI confirmed a save that never reached disk and the data
    /// was simply gone at next launch. `.actionNeeded`: unlike being offline,
    /// this will not resolve itself.
    static func setPersistenceFailure(count: Int, detail: String) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: persistenceFailureID)
            return
        }
        let title = count == 1 ? "A change could not be saved" : "\(count) changes could not be saved"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: persistenceFailureID, title: title,
                subtext: shortDetail(detail),
                source: "Settings",
                clearCondition: "Clears when the write succeeds.",
                kind: .actionNeeded, tint: .critical, isWarning: true,
                primaryAction: AppNotificationAction(label: "Open Health", doneMessage: "Opened Settings",
                                                    perform: { navigateToHealth?() }),
                navigate: { navigateToHealth?() }
            ),
            id: persistenceFailureID
        )
    }

    // MARK: #12 - A scheduled automation ran (F11)

    static func scheduleResultID(_ scheduleID: UUID) -> String { "schedule-result.\(scheduleID.uuidString)" }

    /// One entry per schedule, replaced by that schedule's next run.
    ///
    /// A run *result* looks like a point-in-time event rather than a standing
    /// condition, which is what this center's entries normally are - but the
    /// thing being reported is standing: "the nightly drift check found drift"
    /// and "the weekly export failed" both stay true until a later run says
    /// otherwise, which is exactly when this entry is replaced or cleared.
    ///
    /// `.changed` is `.actionNeeded` and a failure is too; a `.clean` run
    /// reported only because the captain asked for `notifyOn == .always` is
    /// `.informational`, so it can be dismissed and does not sit in the
    /// "waiting for you" half of the panel.
    static func setScheduleResult(scheduleID: UUID,
                                 action: ScheduledActionKind,
                                 verdict: ScheduleRunVerdict,
                                 summary: String,
                                 notifyOn: ScheduleNotifyOn,
                                 navigate: @escaping () -> Void) {
        let id = scheduleResultID(scheduleID)
        guard shouldNotify(verdict: verdict, notifyOn: notifyOn) else {
            // Not worth surfacing - and clearing is the point, not an
            // afterthought: a clean run is how last night's "found drift"
            // entry goes away.
            GrandLineNotificationCenter.shared.set(nil, id: id)
            return
        }
        let title: String
        let kind: AppNotificationKind
        let tint: HelmTint
        switch verdict {
        case .failed:
            title = "\(action.title) failed"
            kind = .actionNeeded
            tint = .critical
        case .changed:
            title = action.title
            kind = .actionNeeded
            tint = .warn
        case .clean:
            title = "\(action.title): clean"
            kind = .informational
            tint = .good
        }
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: id, title: title,
                subtext: shortDetail(summary),
                source: "Schedules",
                clearCondition: "Clears when this schedule next runs.",
                kind: kind, tint: tint, isWarning: verdict == .failed,
                primaryAction: AppNotificationAction(label: "Open", doneMessage: "Opened Schedules",
                                                    perform: navigate),
                navigate: navigate
            ),
            id: id
        )
    }

    /// The notify-on decision, split out so it is testable without a run.
    static func shouldNotify(verdict: ScheduleRunVerdict, notifyOn: ScheduleNotifyOn) -> Bool {
        switch notifyOn {
        case .always: return true
        case .failureOnly: return verdict == .failed
        case .changeOnly: return verdict != .clean
        }
    }

    static func clearScheduleResult(scheduleID: UUID) {
        GrandLineNotificationCenter.shared.set(nil, id: scheduleResultID(scheduleID))
    }

    /// One line, bounded - a notification subtext is a headline; the full text
    /// lives on the Health card.
    private static func shortDetail(_ detail: String, limit: Int = 90) -> String {
        let firstLine = detail.split(separator: "\n").first.map(String.init) ?? detail
        return firstLine.count <= limit ? firstLine : String(firstLine.prefix(limit)) + "\u{2026}"
    }
}
