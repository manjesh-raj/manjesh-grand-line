// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the "Claude usage" toolbar button restored beside
// Compose (`fm/grand-line-console-claude-usage-button`).
//
// `QuotaUsagePopover.swift`'s own header has the full history: the button
// used to sit on Console's herdr-attached "Mirror" tab, was removed along
// with that tab (`fm/grand-line-remove-firstmate-mirror`), and this task
// restored it - per captain request - beside Compose on the plain Shell tab,
// wired to the same `QuotaUsageController` `FleetController`'s Morning
// Briefing card already uses (`fm/grandline-herdr-utilization-panel`).
//
// This drives the *real* `ConsoleController.openFirstmateHost`/`newShellSession` -
// not reimplementations - following `BlockViewRestartIntegrationSelfTest.swift`'s
// construction pattern (a real `ConsoleController` mounted in a real,
// off-screen `NSWindow`). What it does NOT do: call
// `QuotaUsageController.toggle`/`NSPopover.show` - no self-test in this
// codebase exercises a real `NSPopover.show(relativeTo:of:preferredEdge:)`
// headlessly (checked before writing this), and that popover's own
// open/close/refresh/theme mechanics are pre-existing, already-shipped code
// this task didn't touch (`FleetController` already relies on it in
// production). What genuinely IS new here, and what this test covers, is
// `updateQuotaUsageControls()`'s availability rule - that it mirrors
// `updateComposeControls()` byte-for-byte, on both the shared Firstmate
// console and a dedicated host page.
//
// `fm/grandline-menubar-remove-items` rewrote this suite: the original
// "hidden on a one-shot command tab" case (and the tab-selection-transition
// case built around it) no longer has anything to test - one-shot
// provisioning commands moved out of `ConsoleController` entirely into
// their own floating window (`ConsoleCommandRunnerWindowController.swift`),
// which has no Compose/Claude-usage buttons at all. What's left is the
// simpler, still-real question: are the buttons visible with a session and
// hidden with none, agreeing with Compose either way.
//
// Run with:
//   swift build && FM_RUN_CONSOLE_CLAUDE_USAGE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only.
//
// The self-test suites are test code, fault-injection seams and fixture data
// that used to be linked into the binary the captain actually runs.
// `FM_SELFTESTS` is defined by `Package.swift` for the debug configuration
// only, so `swift build` (and therefore CI and `Scripts/run-all-tests.sh`)
// still has every suite, while `swift build -c release` - what
// `native/build_native_app.sh` assembles the shipped `.app` from - has none
// of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ConsoleClaudeUsageSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("visibleAndMatchesComposeOnTheSharedConsoleShellSession", test_visibleOnFirstmateShellSession),
            ("visibleAndMatchesComposeOnAHostPageShellSession", test_visibleOnHostShellSession),
            ("hiddenAndMatchesComposeWithNoSession", test_hiddenWithNoSession),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "ConsoleClaudeUsageSelfTest: all \(cases.count) cases passed"
            : "ConsoleClaudeUsageSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A real `ConsoleController` mounted in a real `NSWindow`, with no
    /// session open yet - `isFirstmateConsole` picks the shared-console
    /// shape (matching the task's own "the plain Shell tab" framing) or a
    /// dedicated-host-page shape.
    private static func makeTestConsole(isFirstmateConsole: Bool) -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), isFirstmateConsole: isFirstmateConsole)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// Both buttons exist and their `isHidden` states agree - the property
    /// this task's own acceptance criteria hinges on ("matching Compose's
    /// own availability rule").
    private static func checkButtonsAgree(_ controller: ConsoleController, expectedHidden: Bool) -> String? {
        guard let quotaButton = controller.quotaUsageButton else { return "quotaUsageButton was never built" }
        guard let composeButton = controller.composeButton else { return "composeButton was never built" }
        guard quotaButton.isHidden == expectedHidden else {
            return "expected Claude usage's isHidden to be \(expectedHidden), got \(quotaButton.isHidden)"
        }
        guard quotaButton.isHidden == composeButton.isHidden else {
            return "Claude usage's visibility (\(quotaButton.isHidden)) disagrees with Compose's " +
                "(\(composeButton.isHidden)) on the same session - they must share the exact same availability rule"
        }
        return nil
    }

    // MARK: Cases

    private static func test_visibleOnFirstmateShellSession() -> String? {
        // `ConsoleController.loadView()` already opens the Firstmate host's
        // Shell session for an `isFirstmateConsole: true` controller.
        let (window, controller) = makeTestConsole(isFirstmateConsole: true)
        controller.view.layoutSubtreeIfNeeded()
        let failure = checkButtonsAgree(controller, expectedHidden: false)
        _ = window
        return failure
    }

    private static func test_visibleOnHostShellSession() -> String? {
        let (window, controller) = makeTestConsole(isFirstmateConsole: false)
        controller.newShellSession()
        controller.view.layoutSubtreeIfNeeded()
        let failure = checkButtonsAgree(controller, expectedHidden: false)
        _ = window
        return failure
    }

    private static func test_hiddenWithNoSession() -> String? {
        // A dedicated host page before its own `connectSSHIfNeeded` has ever
        // run - `session == nil`, matching real production state the moment
        // a host page is first mounted.
        let (window, controller) = makeTestConsole(isFirstmateConsole: false)
        controller.view.layoutSubtreeIfNeeded()
        let failure = checkButtonsAgree(controller, expectedHidden: true)
        _ = window
        return failure
    }
}

#endif
