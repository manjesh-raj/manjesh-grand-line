// Manjesh Grand Line - native macOS app.
//
// F4 (production-readiness review, section 25): permanent coverage for
// notification action routing - which action button maps to which real
// function call, and whether the merge gate genuinely blocks a non-green PR.
//
// Why these are the two things worth pinning:
//
//   - **The gate is a security constraint the review states explicitly**
//     ("merge-from-notification should respect the same green-checks gate as
//     the Review page"). A notification payload is archived by the system and
//     handed back later, possibly after the checks that made it green have
//     gone red, so the gate has to hold against a *stale* payload and not
//     merely against the state at post time. That is exactly what is asserted
//     here, including the case where the payload carries no task id at all
//     (which `bin/fm-pr-merge.sh` would reject anyway - GL-38's own lesson is
//     that nothing was asserting the argv shape).
//   - **The routing table is otherwise invisible.** Every action is one string
//     matched in one switch; a typo, a copied case, or a category losing an
//     action fails silently at the only moment it matters - on a real banner,
//     on the captain's machine, which is precisely what cannot be exercised
//     from here.
//
// What is deliberately NOT covered, and why: real interactive delivery. There
// is no way to raise a live macOS banner and click its buttons from this
// sandbox (no interactive login session; the same class of limitation
// AGENTS.md's "Verifying native UI bugs" convention already documents). So the
// suite drives `NotificationActionRouter.handle(actionIdentifier:userInfo:)` -
// the exact method the `UNUserNotificationCenterDelegate` callback calls, with
// the exact `userInfo` dictionary the real posting sites build - and asserts on
// the calls it makes. `UNNotificationResponse` cannot be constructed outside
// the system, which is why that one thin delegate hop is the seam.
//
// The snooze case uses a **real `ShiftStore`** against a scratch `FM_SHIFT_DIR`
// and asserts the follow-up's own persisted fields moved, rather than that a
// closure fired - that is what proves it goes through the existing snooze
// mechanism rather than a new one.
//
// Run: `FM_RUN_NOTIFICATION_ACTIONS_TESTS=1 .build/debug/FirstmateCockpit`
//
// No network, no `gh`, no real merge, no notification posted, and no read of
// the captain's real Shift data.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing this suite - `Phase3PolishSelfTest` asserts every file here has it.
#if FM_SELFTESTS

import Foundation
import UserNotifications

enum NotificationActionsSelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        checkMergeGate(check)
        checkRoutingTable(check)
        checkPayloadRoundTrip(check)
        checkCategories(check)
        checkMergeReachesTheRealExecutor(check)
        checkLockGate(check)
        checkSnoozeUsesTheRealStore(check)

        for message in failures { print("  FAIL \(message)") }
        let ok = failures.isEmpty
        print(ok ? "NotificationActionsSelfTest: all checks passed"
                 : "NotificationActionsSelfTest: FAILED (\(failures.count))")
        return ok
    }

    // MARK: The merge gate

    private static func checkMergeGate(_ check: (Bool, String) -> Void) {
        let green = NotificationPayload(
            subject: .prReady, taskID: "grandline-feature-f4", prURL: "https://github.com/o/r/pull/9",
            prChecks: "green")

        let allowed = NotificationActionRouting.resolve(
            actionIdentifier: NotificationAction.merge, payload: green)
        check(allowed == [.merge(taskID: "grandline-feature-f4", url: "https://github.com/o/r/pull/9")],
              "a green PR with a tracked task should resolve to a merge, got \(allowed)")

        // Every non-green checks value the Review page knows about. This is the
        // stale-notification case: the payload was posted while green.
        for checks in ["red", "pending", "none", "", "GREEN"] {
            var stale = green
            stale.prChecks = checks
            let resolved = NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.merge, payload: stale)
            check(!resolved.contains(where: isMerge),
                  "checks=\"\(checks)\" must not resolve to a merge, got \(resolved)")
            check(resolved.contains(where: isRefusal),
                  "checks=\"\(checks)\" must be an explicit refusal, not a silent no-op")
        }

        // The technical half of the gate: `bin/fm-pr-merge.sh` takes
        // `<task-id> <pr-url>` and validates the id, so a PR with no tracked
        // task has no working merge path at all (GL-38).
        for taskID in [nil, "", " "] as [String?] {
            var untracked = green
            untracked.taskID = taskID
            let resolved = NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.merge, payload: untracked)
            let described = taskID.map { "\"\($0)\"" } ?? "nil"
            check(!resolved.contains(where: isMerge),
                  "taskID=\(described) must not resolve to a merge, got \(resolved)")
        }

        // Same gate, same definition, as the Review row's own button.
        check(FleetDataSource.canMerge(checks: "green", taskID: "t-1"),
              "canMerge(checks:taskID:) should accept the green + tracked case")
        check(!FleetDataSource.canMerge(checks: "pending", taskID: "t-1"),
              "canMerge(checks:taskID:) should reject pending checks")
        check(!FleetDataSource.canMerge(checks: "green", taskID: nil),
              "canMerge(checks:taskID:) should reject a PR with no tracked task")
        let row = MergedPR(source: "work", taskID: "t-1", repo: "o/r", url: "u",
                           number: 1, title: "t", checks: "green", forge: "github")
        check(FleetDataSource.canMerge(row) == FleetDataSource.canMerge(checks: row.checks, taskID: row.taskID),
              "the MergedPR and the (checks:taskID:) form of canMerge must agree")

        // A Merge action on a payload that is not a PR at all.
        let notAPR = NotificationPayload(subject: .fleetTask, taskID: "t-1")
        let resolvedNonPR = NotificationActionRouting.resolve(
            actionIdentifier: NotificationAction.merge, payload: notAPR)
        check(!resolvedNonPR.contains(where: isMerge), "a non-PR payload must never resolve to a merge")
    }

    private static func isMerge(_ action: NotificationRoutedAction) -> Bool {
        if case .merge = action { return true }
        return false
    }

    private static func isRefusal(_ action: NotificationRoutedAction) -> Bool {
        if case .refused = action { return true }
        return false
    }

    // MARK: Which action maps to which real call

    private static func checkRoutingTable(_ check: (Bool, String) -> Void) {
        let pr = NotificationPayload(subject: .prReady, taskID: "t-1",
                                     prURL: "https://github.com/o/r/pull/9", prChecks: "green")
        check(NotificationActionRouting.resolve(actionIdentifier: NotificationAction.openPR, payload: pr)
                == [.show(.review), .openURL("https://github.com/o/r/pull/9")],
              "Open PR should leave the app on Review and then open the PR URL")
        check(NotificationActionRouting.resolve(actionIdentifier: NotificationAction.showInApp, payload: pr)
                == [.show(.review)],
              "Show in app on a PR notification should select Review")

        let fleet = NotificationPayload(subject: .fleetTask, taskID: "grandline-thing")
        check(NotificationActionRouting.resolve(actionIdentifier: NotificationAction.openFleetTask, payload: fleet)
                == [.show(.overview)],
              "Open task on a fleet notification should select Overview")
        check(NotificationActionRouting.resolve(actionIdentifier: NotificationAction.showInApp, payload: fleet)
                == [.show(.overview)],
              "Show in app on a fleet notification should select Overview")

        let shiftTask = NotificationPayload(subject: .shiftTask, shiftTaskID: "st-1")
        check(NotificationActionRouting.resolve(actionIdentifier: NotificationAction.openShiftTask, payload: shiftTask)
                == [.openShiftTask(id: "st-1")],
              "Open task on a Shift task notification should open that task")

        let followUp = NotificationPayload(subject: .shiftFollowUp, followUpID: "fu-1")
        check(NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.openShiftFollowUp, payload: followUp)
                == [.openShiftFollowUp(id: "fu-1")],
              "Open follow-up should open that follow-up")
        check(NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.snoozeFollowUpOneHour, payload: followUp)
                == [.snoozeFollowUp(id: "fu-1", seconds: 3600)],
              "Snooze 1h should snooze that follow-up by exactly one hour")

        // A snooze is only meaningful for a follow-up - the only record type
        // `ShiftStore.snoozeFollowUp` can write.
        check(NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.snoozeFollowUpOneHour, payload: shiftTask).isEmpty,
              "Snooze must not act on a Shift task payload")

        // Clicking the banner body is the system's default action.
        check(NotificationActionRouting.resolve(
                actionIdentifier: UNNotificationDefaultActionIdentifier, payload: fleet)
                == [.show(.overview)],
              "clicking the banner body should behave like Show in app")
        // Swiping a notification away is not an action.
        check(NotificationActionRouting.resolve(
                actionIdentifier: UNNotificationDismissActionIdentifier, payload: fleet).isEmpty,
              "dismissing a notification must do nothing")
        // A notification posted by an older build carries no payload at all.
        check(NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.merge, payload: nil).isEmpty,
              "a payload-less notification must route to nothing, not to a guessed default")
        check(NotificationActionRouting.resolve(
                actionIdentifier: "fm.action.does-not-exist", payload: fleet).isEmpty,
              "an unknown action identifier must route to nothing")

        // An id that went missing between posting and tapping falls back to
        // the destination rather than acting on an empty id.
        let idless = NotificationPayload(subject: .shiftFollowUp, followUpID: nil)
        check(NotificationActionRouting.resolve(
                actionIdentifier: NotificationAction.openShiftFollowUp, payload: idless) == [.show(.shift)],
              "a follow-up notification with no id should just select the Tasks page")
    }

    // MARK: The payload is a wire format

    private static func checkPayloadRoundTrip(_ check: (Bool, String) -> Void) {
        let original = NotificationPayload(
            subject: .prReady, taskID: "t-1", prURL: "https://github.com/o/r/pull/9",
            prChecks: "green", followUpID: "fu-1", shiftTaskID: "st-1")
        let decoded = NotificationPayload(userInfo: original.userInfo)
        check(decoded == original, "a payload must survive the userInfo round trip verbatim")

        check(NotificationPayload(userInfo: [:]) == nil,
              "an empty userInfo is not one of this app's posts")
        check(NotificationPayload(userInfo: ["fm.subject": "something-else"]) == nil,
              "an unknown subject must not decode")

        // The two posting sites' real payloads, decoded back the way the
        // delegate will see them.
        let fleet = NotificationPayload(subject: .fleetTask, taskID: "grandline-thing")
        check(NotificationPayload(userInfo: fleet.userInfo)?.taskID == "grandline-thing",
              "a fleet payload must carry the task id")
        let followUp = NotificationPayload(subject: .shiftFollowUp, followUpID: "fu-1")
        check(NotificationPayload(userInfo: followUp.userInfo)?.followUpID == "fu-1",
              "a follow-up payload must carry the follow-up id")
    }

    // MARK: Categories actually carry the buttons the spec describes

    private static func checkCategories(_ check: (Bool, String) -> Void) {
        let categories = NotificationActionRouting.categories()
        func actions(_ id: String) -> [String] {
            categories.first { $0.identifier == id }?.actions.map(\.identifier) ?? []
        }

        check(actions(NotificationCategory.prReady)
                == [NotificationAction.merge, NotificationAction.openPR, NotificationAction.showInApp],
              "the PR category must offer Merge, Open PR and Show in app, in that order")
        check(actions(NotificationCategory.fleetTask)
                == [NotificationAction.openFleetTask, NotificationAction.showInApp],
              "the fleet-task category must offer Open task and Show in app")
        check(actions(NotificationCategory.shiftTask)
                == [NotificationAction.openShiftTask, NotificationAction.showInApp],
              "the Shift-task category must offer Open task and Show in app")
        check(actions(NotificationCategory.shiftFollowUp)
                == [NotificationAction.snoozeFollowUpOneHour, NotificationAction.openShiftFollowUp],
              "the follow-up category must offer Snooze 1h and Open follow-up")

        // Every action a category offers has to be one `resolve` knows about,
        // or it is a button that silently does nothing.
        let anyPayload: [NotificationPayload.Subject: NotificationPayload] = [
            .prReady: NotificationPayload(subject: .prReady, taskID: "t", prURL: "u", prChecks: "green"),
            .fleetTask: NotificationPayload(subject: .fleetTask, taskID: "t"),
            .shiftTask: NotificationPayload(subject: .shiftTask, shiftTaskID: "st"),
            .shiftFollowUp: NotificationPayload(subject: .shiftFollowUp, followUpID: "fu"),
        ]
        let subjectForCategory: [String: NotificationPayload.Subject] = [
            NotificationCategory.prReady: .prReady,
            NotificationCategory.fleetTask: .fleetTask,
            NotificationCategory.shiftTask: .shiftTask,
            NotificationCategory.shiftFollowUp: .shiftFollowUp,
        ]
        for category in categories {
            guard let subject = subjectForCategory[category.identifier],
                  let payload = anyPayload[subject] else {
                check(false, "category \(category.identifier) has no known subject")
                continue
            }
            for action in category.actions {
                let resolved = NotificationActionRouting.resolve(
                    actionIdentifier: action.identifier, payload: payload)
                check(!resolved.isEmpty,
                      "\(category.identifier)'s \"\(action.title)\" button resolves to nothing")
            }
        }
    }

    // MARK: Performing reaches the real merge function

    private static func checkMergeReachesTheRealExecutor(_ check: (Bool, String) -> Void) {
        let router = NotificationActionRouter()
        var mergedWith: [(String, String)] = []
        var feedback: [(String, String)] = []
        router.isAllowed = { true }
        // Synchronous, so the assertions below do not race the merge queue.
        router.mergeQueue = { work in work() }
        router.mergeExecutor = { taskID, url in
            mergedWith.append((taskID, url))
            return (true, "Merged.")
        }
        router.postFeedback = { title, body in feedback.append((title, body)) }

        let green = NotificationPayload(
            subject: .prReady, taskID: "grandline-feature-f4",
            prURL: "https://github.com/o/r/pull/9", prChecks: "green")
        router.handle(actionIdentifier: NotificationAction.merge, userInfo: green.userInfo)
        check(mergedWith.count == 1, "a green Merge tap should reach the merge executor exactly once")
        check(mergedWith.first?.0 == "grandline-feature-f4",
              "the merge must carry the task id (GL-38), got \(mergedWith.first?.0 ?? "nil")")
        check(mergedWith.first?.1 == "https://github.com/o/r/pull/9", "and the PR URL")
        check(feedback.count == 1 && feedback.first?.0 == "Merged",
              "a merge outcome must be reported back - a non-foreground action has no window for an alert")

        // The gate again, this time through the whole real handle -> resolve ->
        // perform path rather than `resolve` alone.
        var red = green
        red.prChecks = "red"
        mergedWith.removeAll(); feedback.removeAll()
        router.handle(actionIdentifier: NotificationAction.merge, userInfo: red.userInfo)
        check(mergedWith.isEmpty, "a non-green Merge tap must never reach the merge executor")
        check(feedback.count == 1 && feedback.first?.0 == "Merge refused",
              "and the captain must be told it was refused, not left thinking it merged")

        // A failed merge reports the reason rather than claiming success.
        mergedWith.removeAll(); feedback.removeAll()
        router.mergeExecutor = { _, _ in (false, "fm-pr-merge.sh: checks are not green") }
        router.handle(actionIdentifier: NotificationAction.merge, userInfo: green.userInfo)
        check(feedback.first?.0 == "Merge failed" && feedback.first?.1.contains("not green") == true,
              "a merge failure must surface the underlying message")

        // Navigation goes through the injected closures - i.e. through
        // `AppShellController` in the real app, never a second nav path.
        var shown: [RailDestination] = []
        var openedURLs: [String] = []
        var openedShiftTasks: [String] = []
        router.onShow = { shown.append($0) }
        router.onOpenURL = { openedURLs.append($0) }
        router.onOpenShiftTask = { openedShiftTasks.append($0) }
        router.handle(actionIdentifier: NotificationAction.openPR, userInfo: green.userInfo)
        check(shown == [.review] && openedURLs == ["https://github.com/o/r/pull/9"],
              "Open PR should select Review and open the URL, got \(shown)/\(openedURLs)")
        shown.removeAll()
        router.handle(actionIdentifier: NotificationAction.openFleetTask,
                      userInfo: NotificationPayload(subject: .fleetTask, taskID: "t").userInfo)
        check(shown == [.overview], "Open task on a fleet notification should select Overview")
        router.handle(actionIdentifier: NotificationAction.openShiftTask,
                      userInfo: NotificationPayload(subject: .shiftTask, shiftTaskID: "st-9").userInfo)
        check(openedShiftTasks == ["st-9"], "Open task on a Shift notification should open that task")
    }

    // MARK: GL-09 - a locked app does nothing

    private static func checkLockGate(_ check: (Bool, String) -> Void) {
        let router = NotificationActionRouter()
        var merged = 0
        var shown = 0
        router.isAllowed = { false }
        router.mergeQueue = { work in work() }
        router.mergeExecutor = { _, _ in merged += 1; return (true, "") }
        router.postFeedback = { _, _ in }
        router.onShow = { _ in shown += 1 }

        let green = NotificationPayload(subject: .prReady, taskID: "t-1", prURL: "u", prChecks: "green")
        router.handle(actionIdentifier: NotificationAction.merge, userInfo: green.userInfo)
        router.handle(actionIdentifier: NotificationAction.openPR, userInfo: green.userInfo)
        check(merged == 0, "a locked app must not merge from a notification")
        check(shown == 0, "a locked app must not navigate from a notification either")

        // And the gate is really the shared one, not a local flag.
        check(!AppLockGate.shared.allows(.notificationAction) == AppLockGate.shared.isLocked,
              "notification actions must be gated by the shared AppLockGate")
    }

    // MARK: Snooze goes through the existing ShiftStore mechanism

    private static func checkSnoozeUsesTheRealStore(_ check: (Bool, String) -> Void) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-actions-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }

        let store = ShiftStore()
        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Check the migration finished"
        // Deliberately in the past, so a successful snooze has to move it.
        followUp.followUpAt = "2001-01-01"
        followUp.followUpTime = "09:00"
        store.addFollowUp(followUp)

        let router = NotificationActionRouter()
        router.isAllowed = { true }
        // The real wiring from `main.swift`, verbatim.
        router.onSnoozeFollowUp = { id, date in store.snoozeFollowUp(id: id, to: date) }

        let before = Date()
        router.handle(
            actionIdentifier: NotificationAction.snoozeFollowUpOneHour,
            userInfo: NotificationPayload(subject: .shiftFollowUp, followUpID: followUp.id).userInfo)

        guard let snoozed = store.followUps.first(where: { $0.id == followUp.id }) else {
            check(false, "the follow-up disappeared from the store")
            return
        }
        check(snoozed.followUpAt != "2001-01-01" || snoozed.followUpTime != "09:00",
              "Snooze 1h must actually move the follow-up's own persisted due fields")
        guard let newDue = ShiftDateFormatting.dateTime(from: snoozed.followUpAt, time: snoozed.followUpTime) else {
            check(false, "the snoozed follow-up has no parseable due date/time")
            return
        }
        // ShiftStore persists to minute precision, so allow a minute of slack
        // either side of "one hour from now".
        let expected = before.addingTimeInterval(NotificationActionRouting.snoozeOneHour)
        check(abs(newDue.timeIntervalSince(expected)) <= 60,
              "snoozed to \(newDue), expected within a minute of \(expected)")
        check(snoozed.status == .pending, "a snoozed follow-up stays pending")

        // And it reached disk through the store's own persistence, not just
        // in-memory state - the same thing the row's Snooze menu guarantees.
        let reloaded = ShiftStore()
        let persisted = reloaded.followUps.first { $0.id == followUp.id }
        check(persisted?.followUpAt == snoozed.followUpAt && persisted?.followUpTime == snoozed.followUpTime,
              "the snooze must survive a reload from disk")
    }
}

#endif
