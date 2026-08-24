// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-mirror-herdr-boot-race`: a captain-reported real-world case
// `fm/grandline-mirror-resolve-race-fix` didn't cover, seen live right after
// a laptop restart - the Console's built-in tab pair showed "Mirror" (the
// tmux-era name) instead of "Herdr", and the tab's own terminal read
// `[mirror] Cannot mirror 'firstmate': error connecting to
// /private/tmp/tmux-503/default (No such file or directory)` with the app's
// own hint underneath it: `Set FM_MIRROR_TARGET to a live tmux target, then
// press ⌘R to reconnect.`
//
// The prior fix made `FirstmateBackend.resolveMirrorTarget()` decide kind and
// target from one atomic call, frozen into `TabLaunch.mirror` at tab-
// creation time - correctly closing the two-different-calls-disagree race
// that fix targeted. But it left a second, distinct gap: right after a
// machine restart, herdr's own background server/LaunchAgent can genuinely
// still be down at the ONE moment that one atomic call runs, so `.tmux` was
// the correct answer *at that instant* - and then herdr came up moments
// later, with the tab permanently stuck on the now-stale `.tmux`/"firstmate"
// answer for the rest of the session. `reconnectActive` (⌘R) and the auto-
// reconnect timer (`processTerminated` -> `startTab`) both replayed that same
// frozen pair verbatim by design, so the app's own on-screen recovery
// instruction - press ⌘R - could never actually recover, because neither
// path ever asked the live-evidence question again.
//
// The fix: `ConsoleController.reresolveMirrorTab` makes one FRESH atomic
// `resolveMirrorTarget()` call and re-freezes `tab.launch` before any restart
// (manual ⌘R via `reconnectActive`, or the auto-reconnect-timer-shaped
// restart via `startTab` when `tab.started` is already `true`) - the tab's
// very first start is untouched, still using the one resolution
// `openFirstmateHost` already got it. This does not reintroduce the original
// race: each restart still makes exactly one atomic call deciding kind and
// target together for *that* attempt.
//
// This test drives the real `ConsoleController`/`FirstmateBackend`/
// `HerdrMirror` production code (not a reimplementation), using the same
// fake-`herdr`-executable-on-a-shadowed-`PATH` technique
// `MirrorResolveRaceSelfTest` already established, deterministically forcing
// the down-then-up flip a real reboot creates by chance - and forcing it to
// happen *between* the tab's first start and its first reconnect, rather
// than within one connection attempt, which is the shape this specific bug
// needs.
//
// Run with:
//   swift build && FM_RUN_MIRROR_RECONNECT_BOOT_RACE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only - `Phase3PolishSelfTest` asserts
// every file in this directory carries this guard.
#if FM_SELFTESTS

import AppKit
import Foundation

enum MirrorReconnectBootRaceSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("manualReconnectPicksUpHerdrOnceItComesUp", test_manualReconnectPicksUpHerdrOnceItComesUp),
            ("autoReconnectShapedRestartAlsoReresolves", test_autoReconnectShapedRestartAlsoReresolves),
            ("veryFirstStartIsNotReresolvedRedundantly", test_veryFirstStartIsNotReresolvedRedundantly),
        ]
        var failures = 0
        for (name, testCase) in cases {
            let originalPath = ProcessInfo.processInfo.environment["PATH"]
            let originalBackend = ProcessInfo.processInfo.environment["FM_BACKEND"]
            defer {
                if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") }
                if let originalBackend { setenv("FM_BACKEND", originalBackend, 1) } else { unsetenv("FM_BACKEND") }
            }
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "MirrorReconnectBootRaceSelfTest: all \(cases.count) cases passed"
            : "MirrorReconnectBootRaceSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fake herdr fixtures (same shape as `MirrorResolveRaceSelfTest`)

    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-mirror-reconnect-boot-race-selftest-\(ProcessInfo.processInfo.processIdentifier)")

    @discardableResult
    private static func writeFakeHerdr(name: String, sessionsJSON: String) -> String {
        let dir = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("herdr")
        let contents = """
        #!/bin/bash
        echo '{"sessions": \(sessionsJSON)}'
        exit 0
        """
        try? contents.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return dir.path
    }

    private static func setPath(fakeHerdrDir: String) {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        setenv("PATH", "\(fakeHerdrDir):\(base)", 1)
    }

    // MARK: Harness

    private static func makeMountedController() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
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

    private static func waitForResolution(_ controller: ConsoleController, tabID: UUID, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.debugIsAwaitingMirrorResolution(tabID), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return !controller.debugIsAwaitingMirrorResolution(tabID)
    }

    // MARK: Cases

    /// The exact captain-reported shape: a Mirror tab is created while
    /// herdr is genuinely down (so `.tmux`/"firstmate" is the correct answer
    /// at that moment), herdr's server then comes up, and a manual ⌘R -
    /// `reconnectActive()`, the real production method, not a stand-in -
    /// re-resolves and reconnects on herdr instead of replaying the stale
    /// tmux guess forever.
    private static func test_manualReconnectPicksUpHerdrOnceItComesUp() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let downDir = writeFakeHerdr(name: "down", sessionsJSON: "[]")
        let upDir = writeFakeHerdr(name: "up", sessionsJSON: #"[{"name": "default", "running": true}]"#)
        unsetenv("FM_BACKEND")

        setPath(fakeHerdrDir: downDir)
        let (window, controller) = makeMountedController()
        _ = controller.openFirstmateHost(focus: false)
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()

        guard let mirrorTabID = controller.debugAllTabIDs().first else { return "no tabs created" }
        controller.debugSelectTab(mirrorTabID)
        guard waitForResolution(controller, tabID: mirrorTabID) else {
            return "the mirror tab never finished its first resolution"
        }
        guard controller.debugMirrorLaunch()?.kind == .tmux else {
            return "expected the tab to freeze on .tmux while herdr was down, got \(String(describing: controller.debugMirrorLaunch()?.kind))"
        }

        // herdr's server comes up, moments after the tab was created and
        // frozen - exactly the gap a real reboot creates.
        setPath(fakeHerdrDir: upDir)

        controller.debugSimulateManualReconnectRestart()
        guard waitForResolution(controller, tabID: mirrorTabID) else {
            return "the manual reconnect's re-resolution never finished"
        }

        guard let launch = controller.debugMirrorLaunch() else { return "current tab is no longer a .mirror launch" }
        guard launch.kind == .herdr else {
            return "expected ⌘R to re-resolve to .herdr once live, got \(launch.kind) - the tab is still frozen on the stale answer"
        }
        guard launch.target == "default" else {
            return "expected the re-resolved target to be 'default', got '\(launch.target)'"
        }
        _ = window
        return nil
    }

    /// The other restart path: `processTerminated`'s auto-reconnect timer
    /// calls `startTab` directly on a tab whose `started` flag is already
    /// `true`, never `reconnectActive`. `debugSimulateAutoReconnectRestart()`
    /// drives that exact real path, confirming the fix covers automatic
    /// reconnects too, not only the manual ⌘R the captain happened to try.
    private static func test_autoReconnectShapedRestartAlsoReresolves() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let downDir = writeFakeHerdr(name: "down2", sessionsJSON: "[]")
        let upDir = writeFakeHerdr(name: "up2", sessionsJSON: #"[{"name": "default", "running": true}]"#)
        unsetenv("FM_BACKEND")

        setPath(fakeHerdrDir: downDir)
        let (window, controller) = makeMountedController()
        _ = controller.openFirstmateHost(focus: false)
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()

        guard let mirrorTabID = controller.debugAllTabIDs().first else { return "no tabs created" }
        controller.debugSelectTab(mirrorTabID)
        guard waitForResolution(controller, tabID: mirrorTabID) else {
            return "the mirror tab never finished its first resolution"
        }
        guard controller.debugMirrorLaunch()?.kind == .tmux else {
            return "expected the tab to freeze on .tmux while herdr was down, got \(String(describing: controller.debugMirrorLaunch()?.kind))"
        }

        setPath(fakeHerdrDir: upDir)

        controller.debugSimulateAutoReconnectRestart()
        guard waitForResolution(controller, tabID: mirrorTabID) else {
            return "the auto-reconnect-shaped restart's re-resolution never finished"
        }

        guard let launch = controller.debugMirrorLaunch() else { return "current tab is no longer a .mirror launch" }
        guard launch.kind == .herdr else {
            return "expected the auto-reconnect-shaped restart to re-resolve to .herdr once live, got \(launch.kind)"
        }
        guard launch.target == "default" else {
            return "expected the re-resolved target to be 'default', got '\(launch.target)'"
        }
        _ = window
        return nil
    }

    /// The very first start of a Mirror tab must keep using the one
    /// resolution `openFirstmateHost` already got it - `startTab`'s own
    /// `.mirror` branch only re-resolves when `tab.started` is already
    /// `true` (a restart), never on the tab's genuine first start. Proven by
    /// making herdr's live evidence available from the very beginning and
    /// confirming the frozen kind still agrees with the target that same one
    /// resolution produced - `fm/grandline-mirror-resolve-race-fix`'s own
    /// invariant, still intact under this task's change.
    private static func test_veryFirstStartIsNotReresolvedRedundantly() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let upDir = writeFakeHerdr(name: "up3", sessionsJSON: #"[{"name": "default", "running": true}]"#)
        unsetenv("FM_BACKEND")
        setPath(fakeHerdrDir: upDir)

        let (window, controller) = makeMountedController()
        _ = controller.openFirstmateHost(focus: false)
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()

        guard let mirrorTabID = controller.debugAllTabIDs().first else { return "no tabs created" }
        controller.debugSelectTab(mirrorTabID)
        guard waitForResolution(controller, tabID: mirrorTabID) else {
            return "the mirror tab never finished its first resolution"
        }
        guard let launch = controller.debugMirrorLaunch() else { return "current tab is not a .mirror launch" }
        guard launch.kind == .herdr, launch.target == "default" else {
            return "expected the tab's first-ever start to resolve .herdr/'default' directly, got \(launch.kind)/'\(launch.target)'"
        }
        let output = controller.debugCurrentTerminalOutput() ?? ""
        guard !output.contains("Cannot mirror") else {
            return "the tab's very first start shows a connect failure: \(output)"
        }
        _ = window
        return nil
    }
}

#endif
