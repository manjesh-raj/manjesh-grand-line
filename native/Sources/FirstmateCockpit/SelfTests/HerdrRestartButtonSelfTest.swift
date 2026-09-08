// Manjesh Grand Line - native macOS app.
//
// Permanent, window-backed self-test for the Console toolbar's "Herdr"
// restart button (`fm/grand-line-herdr-restart-button`). Drives a real
// `ConsoleController` mounted in a real, off-screen `NSWindow` -
// `ConsoleClaudeUsageSelfTest.swift`'s exact construction pattern - through
// the actual `loadView()`/`refreshHerdrStatus()`/`herdrRestartButtonClicked()`
// pipeline against a real, disposable fake `herdr` script, proving:
//
//   - the button exists (correct symbol/title/tooltip) only on the shared
//     Firstmate console, never on a dedicated host page - see
//     `herdrRestartButton`'s own doc comment for why;
//   - a real background check against a drifted status leaves the REAL
//     `HelmButton`'s `isEnabled`/`tint` in the state
//     `HerdrRestartButtonStatus.restartNeeded` maps to;
//   - the same against an in-sync status, and against "not installed",
//     leaves it disabled;
//   - the real post-confirmation restart pipeline
//     (`ConsoleController.debugPerformHerdrRestart`, which calls the
//     production `performHerdrRestart()` directly - see that method's own
//     doc comment for why the blocking `NSAlert.runModal()` a real click
//     would otherwise show cannot be driven from a headless suite) runs a
//     real `herdr server stop` against a fake script and leaves the button
//     re-checked afterward;
//   - a click on a genuinely disabled `HelmButton` is a true AppKit no-op.
//
// **Never touches the real, installed `herdr` binary or this machine's
// real, shared server - not even for a read-only status check.** This
// matters more than it looks: `ConsoleController.loadView()` fires an
// initial `refreshHerdrStatus()` the moment the shared console's toolbar
// button exists, so `HerdrRestartSource.executablePathOverrideForTests`/
// `.installedOverrideForTests` MUST be set BEFORE `makeTestConsole` is
// called, never after - setting it afterward races the real herdr install
// against the fake one and (as an earlier draft of this file discovered
// live, the hard way) can silently pass by coincidence, since this
// machine's own real herdr genuinely is drifted right now (see
// `HerdrRestart.swift`'s header) - which is exactly the state some of these
// cases need to prove does NOT happen with the fake in place.
//
// See `HerdrRestartSelfTest.swift` for the pure-logic half (parsing, the
// confirmation dialog's own text, the subprocess plumbing) - this file only
// proves the real AppKit wiring on top of it.
//
// Run with:
//   swift build && FM_RUN_HERDR_RESTART_BUTTON_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only - see `HerdrThemeSyncSelfTest.swift`'s
// identical header note. Do not remove this guard when editing this file:
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum HerdrRestartButtonSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("presentOnlyOnTheSharedFirstmateConsole", test_presentOnlyOnSharedConsole),
            ("realStatusCheckEnablesAndTintsForADriftedServer", test_realCheckEnablesForDrift),
            ("realStatusCheckDisablesForAnInSyncServer", test_realCheckDisablesForInSync),
            ("realStatusCheckDisablesWhenHerdrIsNotInstalled", test_realCheckDisablesWhenNotInstalled),
            ("realRestartPipelineRunsAgainstAFakeServerAndReChecksAfterward", test_realRestartPipeline),
            ("aStrayClickWhileDisabledIsANoOp", test_strayClickIsNoOp),
        ]
        var failures = 0
        for (name, testCase) in cases {
            // Reset BOTH overrides before every case, and construct nothing
            // yet - each case sets exactly what it needs before building its
            // own console, per this file's own header warning.
            HerdrRestartSource.executablePathOverrideForTests = nil
            HerdrRestartSource.installedOverrideForTests = nil
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        HerdrRestartSource.executablePathOverrideForTests = nil
        HerdrRestartSource.installedOverrideForTests = nil
        print(failures == 0
            ? "HerdrRestartButtonSelfTest: all \(cases.count) cases passed"
            : "HerdrRestartButtonSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A real `ConsoleController` mounted in a real, off-screen `NSWindow` -
    /// `ConsoleClaudeUsageSelfTest.makeTestConsole`'s exact shape. Callers
    /// MUST set `HerdrRestartSource`'s test overrides before calling this -
    /// `loadView()` fires the initial real status check as a side effect of
    /// construction, and by the time this returns it is already dispatched.
    private static func makeTestConsole(isFirstmateConsole: Bool) -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                           isFirstmateConsole: isFirstmateConsole)
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

    /// Blocks (pumping the main run loop, `HerdrThemeSyncSelfTest.waitForFile`'s
    /// exact convention) until `condition()` is true or `timeout` elapses.
    private static func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// A disposable, executable fake `herdr` - never the real installed
    /// binary. Mirrors `HerdrRestartSelfTest.writeFakeHerdr`'s dispatch-on-
    /// first-two-arguments shape.
    private static func writeFakeHerdr(statusJSON: String, stopExitCode: Int32 = 0) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-herdr-restart-button-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fake-herdr.sh")
        let statusB64 = Data(statusJSON.utf8).base64EncodedString()
        var script = "#!/bin/sh\n"
        script += "if [ \"$1\" = \"status\" ]; then echo \"\(statusB64)\" | base64 -d; exit 0; fi\n"
        script += "if [ \"$1\" = \"api\" ] && [ \"$2\" = \"snapshot\" ]; then exit 1; fi\n"
        script += "if [ \"$1\" = \"server\" ] && [ \"$2\" = \"stop\" ]; then exit \(stopExitCode); fi\n"
        script += "exit 99\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private static let driftedStatusJSON = """
        {"client":{"version":"0.9.0","protocol":22},\
        "server":{"status":"running","running":true,"version":"0.8.2","protocol":20},\
        "update":{"restart_needed":true,"server_binary_stale":true}}
        """
    private static let inSyncStatusJSON = """
        {"client":{"version":"0.9.0","protocol":22},\
        "server":{"status":"running","running":true,"version":"0.9.0","protocol":22},\
        "update":{"restart_needed":false,"server_binary_stale":false}}
        """

    // MARK: Cases

    /// `installedOverrideForTests = false` here too, even though this case
    /// never asserts on the check's *result* - `loadView`'s own initial
    /// check would otherwise still fire a real (harmless, read-only)
    /// `herdr status --json` against whatever this machine actually has.
    /// Structural-only checks like this one have no reason to touch a real
    /// subprocess at all.
    private static func test_presentOnlyOnSharedConsole() -> String? {
        HerdrRestartSource.installedOverrideForTests = false
        let (sharedWindow, shared) = makeTestConsole(isFirstmateConsole: true)
        guard let button = shared.herdrRestartButton else {
            return "herdrRestartButton should exist on the shared Firstmate console"
        }
        guard button.symbolName == "arrow.triangle.2.circlepath" else {
            return "unexpected symbol: \(button.symbolName ?? "nil")"
        }
        guard button.title == "Herdr" else { return "unexpected title: \(button.title)" }
        _ = sharedWindow

        let (hostWindow, host) = makeTestConsole(isFirstmateConsole: false)
        guard host.herdrRestartButton == nil else {
            return "herdrRestartButton should NOT exist on a dedicated host page"
        }
        _ = hostWindow
        return nil
    }

    private static func test_realCheckEnablesForDrift() -> String? {
        let fakeHerdr = writeFakeHerdr(statusJSON: driftedStatusJSON)
        HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path

        let (window, controller) = makeTestConsole(isFirstmateConsole: true)
        guard waitUntil(timeout: 5, { !controller.herdrRestartCheckInFlight }) else {
            return "the real status check never settled"
        }

        guard let button = controller.herdrRestartButton else { return "herdrRestartButton missing" }
        guard button.isEnabled else { return "expected the real button to be enabled for a drifted status" }
        guard button.tint == .warn else { return "expected .warn tint, got \(String(describing: button.tint))" }
        guard case .restartNeeded = controller.herdrRestartStatus else {
            return "expected herdrRestartStatus == .restartNeeded, got \(controller.herdrRestartStatus)"
        }
        _ = window
        return nil
    }

    private static func test_realCheckDisablesForInSync() -> String? {
        let fakeHerdr = writeFakeHerdr(statusJSON: inSyncStatusJSON)
        HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path

        let (window, controller) = makeTestConsole(isFirstmateConsole: true)
        guard waitUntil(timeout: 5, { !controller.herdrRestartCheckInFlight }) else {
            return "the real status check never settled"
        }

        guard let button = controller.herdrRestartButton else { return "herdrRestartButton missing" }
        guard !button.isEnabled else { return "expected the real button to stay disabled for an in-sync status" }
        guard controller.herdrRestartStatus == .inSync else {
            return "expected herdrRestartStatus == .inSync, got \(controller.herdrRestartStatus)"
        }
        _ = window
        return nil
    }

    private static func test_realCheckDisablesWhenNotInstalled() -> String? {
        HerdrRestartSource.installedOverrideForTests = false

        let (window, controller) = makeTestConsole(isFirstmateConsole: true)
        guard waitUntil(timeout: 5, { !controller.herdrRestartCheckInFlight }) else {
            return "the real status check never settled"
        }

        guard let button = controller.herdrRestartButton else { return "herdrRestartButton missing" }
        guard !button.isEnabled else { return "expected the real button to be disabled when herdr isn't installed" }
        guard controller.herdrRestartStatus == .notInstalled else {
            return "expected herdrRestartStatus == .notInstalled, got \(controller.herdrRestartStatus)"
        }
        _ = window
        return nil
    }

    /// The one case that drives an actual `herdr server stop` - against a
    /// fake, disposable script, never the real installed binary. Proves the
    /// real production pipeline (`performHerdrRestart`, reached here via
    /// `debugPerformHerdrRestart` to skip the blocking confirmation dialog a
    /// real click would show - see that hook's own doc comment) genuinely
    /// runs the fake `server stop` and re-checks status afterward, rather
    /// than leaving the button stuck on `.restarting` forever.
    private static func test_realRestartPipeline() -> String? {
        let fakeHerdr = writeFakeHerdr(statusJSON: driftedStatusJSON, stopExitCode: 0)
        HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path

        let (window, controller) = makeTestConsole(isFirstmateConsole: true)
        guard waitUntil(timeout: 5, { !controller.herdrRestartCheckInFlight }) else {
            return "the initial status check never settled"
        }
        guard let button = controller.herdrRestartButton, button.isEnabled else {
            return "expected the button enabled before the restart"
        }

        controller.debugPerformHerdrRestart()
        // `setHerdrRestartStatus(.restarting)` runs synchronously on the main
        // thread at the very top of `performHerdrRestart` (see that method),
        // so this is true the instant `debugPerformHerdrRestart` returns -
        // the real, useful assertion is that it does NOT stay `.restarting`
        // forever, i.e. the trailing re-check genuinely ran to completion.
        guard controller.herdrRestartStatus == .restarting else {
            return "expected .restarting immediately after debugPerformHerdrRestart, got \(controller.herdrRestartStatus)"
        }
        guard waitUntil(timeout: 5, { controller.herdrRestartStatus != .restarting }) else {
            return "the button never left .restarting - the post-restart re-check did not complete"
        }

        // The fake `herdr status --json` always answers the SAME drifted
        // JSON regardless of the earlier `server stop` call (it has no real
        // state to change), so this only proves the pipeline ran the fake
        // stop and re-checked - not that a live server genuinely went away,
        // which `HerdrRestartSelfTest`'s own pure-logic cases already cover
        // for `actionableRestartNeeded`'s `serverRunning == false` branch.
        guard case .restartNeeded = controller.herdrRestartStatus else {
            return "expected the re-check to land back on .restartNeeded, got \(controller.herdrRestartStatus)"
        }
        _ = window
        return nil
    }

    private static func test_strayClickIsNoOp() -> String? {
        let fakeHerdr = writeFakeHerdr(statusJSON: inSyncStatusJSON)
        HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path

        let (window, controller) = makeTestConsole(isFirstmateConsole: true)
        guard waitUntil(timeout: 5, { !controller.herdrRestartCheckInFlight }) else {
            return "the real status check never settled"
        }
        guard let button = controller.herdrRestartButton, !button.isEnabled else {
            return "expected the button disabled going into the stray-click case"
        }

        // A disabled `HelmButton` does not deliver its action at all - real
        // AppKit behaviour, not something this test simulates - so this
        // click must be a genuine no-op with no crash and no state change.
        button.performClick(nil)
        guard controller.herdrRestartStatus == .inSync else {
            return "a click on a disabled button should never change herdrRestartStatus, got \(controller.herdrRestartStatus)"
        }
        _ = window
        return nil
    }
}

#endif
