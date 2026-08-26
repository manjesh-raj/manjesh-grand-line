// Manjesh Grand Line - native macOS app.
//
// Permanent integration self-test for the trickiest of the nine
// Notification Center signals (`fm/grandline-notification-center`, #7): "SRE
// Lead answered a question on a page you're not looking at." Drives the
// *real* `ConsoleController.onSRELeadReplyWhileBackground`/`focusSession`/
// `markSessionAsRead`/`closeCurrentTab` machinery through its debug hooks
// (`debugStartSRELead`/`debugAskSRELead`/`debugCloseTab`), not a
// reimplementation - same fake-`claude` harness as `SRELeadSessionSelfTest.swift`.
//
// `fm/grandline-menubar-remove-items` rewrote this suite: the original
// signal fired when a reply landed on a *different tab* than the one
// currently selected (or the whole page was hidden); a console can hold at
// most one session now, so "a different tab selected" can no longer happen
// - the signal is exactly "the whole page (`ConsoleController.view`) is
// hidden" (`view.isHidden`, driven directly here since there's no window
// server in this headless test to make a real destination switch flip it).
//
// Run with:
//   swift build && FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum NotificationCenterSRELeadSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("replyWhileHiddenFiresNotification", test_replyWhileHiddenFiresNotification),
            ("replyWhileVisibleFiresNoNotification", test_replyWhileVisibleFiresNoNotification),
            ("focusingClearsTheNotification", test_focusingClearsTheNotification),
            ("closingTheSessionClearsTheNotification", test_closingTheSessionClearsTheNotification),
        ]
        var failures = 0
        for (name, testCase) in cases {
            SRELead.claudePathOverrideForTests = nil
            GrandLineNotificationCenter.shared.resetForTesting()
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        SRELead.claudePathOverrideForTests = nil
        GrandLineNotificationCenter.shared.resetForTesting()
        print(failures == 0 ? "NotificationCenterSRELeadSelfTest: all \(cases.count) cases passed" : "NotificationCenterSRELeadSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers (mirrors SRELeadSessionSelfTest.swift's own private helpers)

    private static func makeStartedTestConsole() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        controller.openSSH(
            label: "Notification Test Host",
            args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
            accentHex: nil, keyID: nil
        )
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func writeFakeClaude() -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-notification-center-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        printf '{"result": "reply-to: %s", "is_error": false, "session_id": "fake-session-%s"}' "$2" "$2"
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Wires the controller's own reporting callback into
    /// `NotificationSources`/`GrandLineNotificationCenter`, exactly the way
    /// `AppShellController.connectHost` does in production - this test does
    /// not reimplement the wiring, it exercises the same call.
    private static func wireNotificationCenter(_ controller: ConsoleController, hostLabel: String) {
        controller.onSRELeadReplyWhileBackground = { [weak controller] target in
            guard let controller else { return }
            NotificationSources.setSRELeadReply(tabID: target.id, tabName: target.name, hostLabel: hostLabel) {
                controller.focusSession()
                controller.markSessionAsRead()
            }
        }
    }

    // MARK: Cases

    private static func test_replyWhileHiddenFiresNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard let target = controller.session else { return "expected a session" }

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else { return "SRE Lead never reached .ready" }

        // The captain has navigated away from this host page entirely.
        controller.view.isHidden = true
        controller.debugAskSRELead(question: "what happened")
        guard waitUntil({
            GrandLineNotificationCenter.shared.entries.contains { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }
        }) else { return "no notification appeared for the reply while the page was hidden" }

        let entry = GrandLineNotificationCenter.shared.entries.first { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }
        guard entry?.kind == .actionNeeded else { return "SRE Lead reply notification should be .actionNeeded" }
        guard entry?.subtext.contains("Test Host") == true else { return "subtext should name the host" }
        return nil
    }

    private static func test_replyWhileVisibleFiresNoNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard let target = controller.session else { return "expected a session" }

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else {
            return "SRE Lead never reached .ready"
        }
        // `controller.view.isHidden` is `false` here - the page is on screen.
        controller.debugAskSRELead(question: "status check")
        guard waitUntil({ (controller.debugSRELeadChatTexts()?.count ?? 0) >= 2 }) else {
            return "reply never landed in the chat"
        }
        // Give any (incorrect) notification a moment to appear before asserting its absence.
        _ = waitUntil(timeout: 0.3) { false }
        guard !GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }) else {
            return "a reply on the currently-visible page must not create a notification"
        }
        return nil
    }

    private static func test_focusingClearsTheNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard let target = controller.session else { return "expected a session" }

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else { return "SRE Lead never reached .ready" }

        controller.view.isHidden = true
        controller.debugAskSRELead(question: "background question")
        guard waitUntil({
            GrandLineNotificationCenter.shared.entries.contains { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }
        }) else { return "notification never appeared" }

        // Simulates clicking the notification: the wired navigate closure
        // above calls `focusSession()` + `markSessionAsRead()`, exactly as
        // `AppShellController`'s own real closure does once it re-shows the
        // page - real production code also flips `view.isHidden` back to
        // `false` at that point, done here directly since there's no window
        // server in this headless test to drive it through a real
        // destination switch.
        controller.view.isHidden = false
        controller.focusSession()
        controller.markSessionAsRead()
        guard !GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }) else {
            return "focusing the session should clear its own notification"
        }
        return nil
    }

    private static func test_closingTheSessionClearsTheNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard let target = controller.session else { return "expected a session" }

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else { return "SRE Lead never reached .ready" }

        controller.view.isHidden = true
        controller.debugAskSRELead(question: "background question")
        guard waitUntil({
            GrandLineNotificationCenter.shared.entries.contains { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }
        }) else { return "notification never appeared" }

        controller.debugCloseTab()
        guard !GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == NotificationSources.sreLeadReplyID(tabID: target.id) }) else {
            return "closing the session should clear its own dangling notification"
        }
        return nil
    }
}

#endif
