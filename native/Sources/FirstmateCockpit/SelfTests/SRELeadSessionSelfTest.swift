// Manjesh Grand Line - native macOS app.
//
// Permanent integration self-test for SRE Lead's console-session shape.
//
// `fm/grandline-sre-lead-per-tab` originally gave each `.ssh` tab inside one
// dedicated host page its own independent SRE Lead investigation, and
// `SRELeadPerTabSelfTest.swift` proved several tabs' investigations never
// crossed talk with each other. `fm/grandline-menubar-remove-items`
// collapsed a console to one session per host/window - the captain's own
// words: "every host connection collapses to one session per host/window" -
// so a console can no longer hold two tabs' investigations to cross-talk
// between in the first place. This file is that suite's replacement: same
// driving-the-real-controller discipline, scoped to what a single session
// can actually exercise. The 5-concurrent-tab cap
// (`sreLeadMaxConcurrent`/`fifthTabStartsSixthIsRefused`) has no replacement
// case - a console holding at most one session can never reach a 6th, so
// there's nothing left for that cap to guard.
//
// This drives the *real* `ConsoleController` - the actual `startSRELead(for:)`/
// `handleSRELeadSubmit(_:in:)`/`tearDownSRELead(for:)`/`closeCurrentTab`
// methods, not reimplementations of them - exactly the way
// `BlockViewRestartIntegrationSelfTest.swift` drives the real restart
// machinery for the same reason. No live SSH bastion or kubectl cluster is
// needed: the ssh subprocess itself is allowed to fail (a `ConnectTimeout=1`
// dial to `127.0.0.1`, nothing listens there in this environment) since
// starting/using SRE Lead never depends on the session's ssh connection
// actually succeeding, only on its `Terminal`/chat existing. The `claude -p`
// calls are real `Process` invocations against a disposable fake script
// (`SRELead.claudePathOverrideForTests`), never the real `claude` CLI or a
// real network call - same convention as `SRELeadPostmortemSelfTest.swift`/
// `DictationCleanupSelfTest.swift`.
//
// Run with:
//   swift build && FM_RUN_SRE_LEAD_SESSION_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. See `Phase3PolishSelfTest`, which
// asserts every file in this directory carries this guard.
#if FM_SELFTESTS

import AppKit

enum SRELeadSessionSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("startAskAndReplyRoundTrip", test_startAskAndReplyRoundTrip),
            ("emptyStateBeforeStartAndPaneAfter", test_emptyStateBeforeStartAndPaneAfter),
            ("closingSessionTearsDownSRELead", test_closingSessionTearsDownSRELead),
            ("scrollbackSurvivesSRELeadToggle", test_scrollbackSurvivesSRELeadToggle),
        ]
        var failures = 0
        for (name, testCase) in cases {
            SRELead.claudePathOverrideForTests = nil
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        SRELead.claudePathOverrideForTests = nil
        print(failures == 0 ? "SRELeadSessionSelfTest: all \(cases.count) cases passed" : "SRELeadSessionSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A real, non-Firstmate `ConsoleController` (a dedicated host page)
    /// mounted in a real `NSWindow`, with its one `.ssh` session opened and
    /// started via the real `openSSH`/`viewDidAppear` path - mirrors
    /// `BlockViewRestartIntegrationSelfTest.makeStartedTestConsole()`.
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
            label: "Session Test Host",
            args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
            accentHex: nil, keyID: nil
        )
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// A fake `claude -p ... --output-format json` stand-in: echoes the
    /// question it was asked (`-p <question>` is always argv[1]/argv[2])
    /// back inside `result`, so the reply is distinguishable from an
    /// arbitrary fixed string.
    private static func writeFakeClaude() -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-session-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        printf '{"result": "reply-to: %s", "is_error": false, "session_id": "fake-session-%s"}' "$2" "$2"
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// Pumps the main run loop (this self-test runs before `NSApplication.run()`
    /// starts, so a semaphore wait would deadlock against the very
    /// `DispatchQueue.main.async` callback being waited on - same rationale
    /// as `SRELeadPostmortemSelfTest.runGenerateSync`) until `condition` is
    /// true or `timeout` elapses.
    @discardableResult
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: Cases

    private static func test_startAskAndReplyRoundTrip() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else {
            return "expected the session to reach .ready, got \(String(describing: controller.debugSRELeadPhase()))"
        }

        controller.debugAskSRELead(question: "QUESTIONFROMSESSION")
        guard waitUntil({
            (controller.debugSRELeadChatTexts() ?? []).contains(where: { $0.contains("QUESTIONFROMSESSION") && $0.contains("reply-to") })
        }) else {
            return "the reply never arrived: \(controller.debugSRELeadChatTexts() ?? [])"
        }
        return nil
    }

    private static func test_emptyStateBeforeStartAndPaneAfter() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window

        guard controller.debugSRELeadShowingEmptyState() == true else {
            return "a fresh session with no SRE Lead state should show the empty state"
        }
        guard !controller.debugSRELeadPaneOpen() else {
            return "a fresh session has no SRE Lead state - the pane must be fully closed, not open showing the empty state"
        }

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else {
            return "the session never reached .ready"
        }
        guard controller.debugSRELeadShowingEmptyState() == false else { return "a started session incorrectly still shows the empty state" }
        guard controller.debugSRELeadPaneOpen() else { return "a started session has an active investigation - the pane must be open" }
        guard (controller.debugSRELeadChatTexts() ?? []).contains(where: { $0.contains("SRE Lead is ready") }) else {
            return "the session's own transcript should contain the ready status message"
        }
        return nil
    }

    private static func test_closingSessionTearsDownSRELead() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller) = makeStartedTestConsole()
        _ = window

        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else {
            return "the session should reach .ready before this test closes it"
        }
        guard controller.debugSRELeadPaneOpen() else { return "pane should be open with an active session" }

        controller.debugCloseTab()

        guard controller.debugSRELeadPhase() == nil else {
            return "the session no longer exists after being closed, so it should report no SRE Lead state"
        }
        guard !controller.debugSRELeadPaneOpen() else {
            return "the pane should close once the session with the active investigation is gone"
        }
        return nil
    }

    /// **The regression this task's own restyle risked, made permanent.**
    ///
    /// `fm/grandline-sre-lead-app-feel` gives the terminal a rounded, bordered
    /// card while SRE Lead is up. The tempting way to build that - wrap the
    /// terminal in a card and inset it when the pane opens - re-introduces the
    /// exact bug `fm/cockpit-sre-lead-ux-fixes` fixed: any frame change on a
    /// SwiftTerm `TerminalView` triggers `resize(cols:rows:)`, which reflows
    /// the buffer at the new column count and can truncate scrollback a
    /// captain had already built up logging into a bastion. So the card is
    /// drawn *over* a permanently-inset terminal (`ConsoleCardChrome.swift`).
    ///
    /// This proves that, end to end, through the real toggle path: fill the
    /// session's buffer with known content, then drive the real
    /// `startSRELead`/`tearDownSRELead` (which is what moves the pane and the
    /// card look), and diff the whole buffer - scrollback included, since
    /// `getBufferAsData` walks every line the circular buffer holds, not just
    /// the visible screen - plus the terminal's own `cols`/`rows`, which is
    /// the direct proof no resize happened rather than an inference from the
    /// text surviving.
    private static func test_scrollbackSurvivesSRELeadToggle() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        // The session's ssh process fails fast against 127.0.0.1 and exits,
        // which by default schedules an auto-reconnect 2s later - a second
        // process writing into the very buffer this test diffs. Turned off
        // for the duration and restored afterwards. (Restoring writes an
        // explicit value where the key may have been absent; the getter
        // defaults absent to `true`, so the effective setting is unchanged
        // either way.)
        let previousAutoReconnect = AppSettings.shared.autoReconnect
        AppSettings.shared.autoReconnect = false
        defer { AppSettings.shared.autoReconnect = previousAutoReconnect }

        let (window, controller) = makeStartedTestConsole()
        _ = window

        guard let terminal = controller.debugCurrentTerminal() else { return "no Terminal behind the session" }

        // Let the failing ssh process finish writing before establishing the
        // baseline, so its own async output can't land between two snapshots
        // and read as a corrupted buffer.
        var lastLength = -1
        _ = waitUntil(timeout: 8) {
            let length = controller.debugCurrentTerminalOutput()?.count ?? 0
            defer { lastLength = length }
            return length > 0 && length == lastLength
        }

        // The terminal's real geometry is resolved by AppKit a runloop turn or
        // two after the constraints are set, and this window is never ordered
        // front, so it can still be sitting at SwiftTerm's 80x25 default here.
        // Taking the baseline before it settles made this case fail
        // intermittently with "80x25 -> 97x32" - which is the first real layout
        // landing during the wait below, not the pane resizing anything. Wait
        // for a stable size, then measure.
        var lastSize = (cols: -1, rows: -1)
        _ = waitUntil(timeout: 8) {
            controller.view.layoutSubtreeIfNeeded()
            let size = (cols: terminal.cols, rows: terminal.rows)
            defer { lastSize = size }
            return size == lastSize
        }

        // Comfortably more than one screen, so real lines are pushed into
        // scrollback rather than all still being on the visible buffer -
        // scrollback is what a reflow truncates.
        for i in 1...300 {
            terminal.feed(text: "SCROLLBACK-LINE-\(i) the quick brown fox jumps over the lazy dog\r\n")
        }
        controller.view.layoutSubtreeIfNeeded()

        guard let before = controller.debugCurrentTerminalOutput() else { return "no buffer snapshot before the toggle" }
        let (colsBefore, rowsBefore) = (terminal.cols, terminal.rows)
        guard before.contains("SCROLLBACK-LINE-1 "), before.contains("SCROLLBACK-LINE-300 ") else {
            return "the baseline buffer is missing the seeded content, so this test would pass vacuously"
        }
        guard !controller.debugSRELeadPaneOpen() else { return "the pane should start closed" }

        // Open: the real path a captain takes, which is also what turns the
        // card look on (`setSRELeadPaneOpen` -> `updateTerminalCardStyle`).
        controller.debugStartSRELead()
        guard waitUntil({ controller.debugSRELeadPhase() == .ready }) else {
            return "the session never reached .ready, so the pane/card never actually toggled"
        }
        guard controller.debugSRELeadPaneOpen() else { return "the pane must be open after starting SRE Lead" }
        controller.view.layoutSubtreeIfNeeded()

        guard let afterOpen = controller.debugCurrentTerminalOutput() else { return "no buffer snapshot after opening" }
        guard terminal.cols == colsBefore, terminal.rows == rowsBefore else {
            return "opening SRE Lead resized the terminal: \(colsBefore)x\(rowsBefore) -> \(terminal.cols)x\(terminal.rows)"
        }
        guard afterOpen == before else {
            return "opening SRE Lead changed the buffer (\(before.count) -> \(afterOpen.count) chars)"
        }

        // Close again, the same real path.
        controller.debugTearDownSRELead()
        guard !controller.debugSRELeadPaneOpen() else { return "the pane must be closed after tearing SRE Lead down" }
        controller.view.layoutSubtreeIfNeeded()

        guard let afterClose = controller.debugCurrentTerminalOutput() else { return "no buffer snapshot after closing" }
        guard terminal.cols == colsBefore, terminal.rows == rowsBefore else {
            return "closing SRE Lead resized the terminal: \(colsBefore)x\(rowsBefore) -> \(terminal.cols)x\(terminal.rows)"
        }
        guard afterClose == before else {
            return "closing SRE Lead changed the buffer (\(before.count) -> \(afterClose.count) chars)"
        }
        return nil
    }
}

#endif
