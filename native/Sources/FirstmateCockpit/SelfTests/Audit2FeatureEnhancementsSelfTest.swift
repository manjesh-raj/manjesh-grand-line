// Manifest: the second full-app audit's §6 items that were still genuinely
// open after #337/#338/#339/#340 - §6.3 (session-strip honesty for restored
// pages, i.e. §4.6 + §4.5) and §6.8's Code Preview half (§2.8). Built in
// `fm/grandline-audit2-feature-enhancements`. Run with:
//
//   swift build && FM_RUN_AUDIT2_FEATURE_ENHANCEMENTS_TESTS=1 .build/debug/FirstmateCockpit
//
// §6.2's structural lock-gate guard is `LockGateCoverageSelfTest` - source
// greps, so it runs in CI. This one mounts real `ConsoleController`s in real
// windows to drive `startTab`, so it belongs in `run-all-tests.sh`'s
// `NEEDS_SESSION` list.
//
// ## What the §6.3 cases are actually pinning
//
// The bug was never that a restored page had a registry entry - switching
// into one is correct, and revealing it is what connects it. It was that every
// surface reading the registry *claimed a connection*: the strip said
// "connected · Nm" with a clock started at launch, the Hosts row showed a live
// chip, and F9's picker reported the host connected and therefore took its
// immediate-send branch, typing into a terminal with no process behind it.
//
// So these cases assert the *distinction*, not merely that entries exist:
// a page with no started tab reads `.restored`, a real `startTab` moves it to
// `.connected`, and `isHostConnected` follows the process rather than the
// dictionary. A check that only asserted "the host is registered" would pass
// just as happily against the pre-fix code.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum Audit2FeatureEnhancementsSelfTest {
    @discardableResult
    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("§6.3 a page with nothing started reads restored, not connected",
             test_unstartedPageIsNotConnected),
            ("§6.3 a real startTab moves the entry to connected",
             test_startingATabConnectsTheEntry),
            ("§6.3 a re-register never downgrades a live session",
             test_reRegisterDoesNotDowngrade),
            ("§6.3 the connect clock starts at the connection, not at launch",
             test_connectRestampsTheClock),
            ("§6.3 every surface's wording follows the real state",
             test_surfaceWordingFollowsState),
            ("§4.5 isHostConnected follows the process, not the dictionary",
             test_isHostConnectedFollowsTheProcess),
            ("§6.8 Code Preview's quit flush is on the shared queue, bounded",
             test_codePreviewTerminateFlushIsQueued),
            ("§6.8 the quit path actually calls Code Preview's shutdown",
             test_codePreviewShutdownIsWired),
        ]

        var ok = true
        for (name, body) in cases {
            if let failure = body() {
                ok = false
                print("FAIL \(name): \(failure)")
            } else {
                print("PASS \(name)")
            }
        }
        print(ok ? "AUDIT2 FEATURE ENHANCEMENTS: OK" : "AUDIT2 FEATURE ENHANCEMENTS: FAILURES")
        return ok
    }

    // MARK: §6.3 - session honesty

    private static func test_unstartedPageIsNotConnected() -> String? {
        withScratchEnv {
            let (window, controller) = makeConsole()
            defer { window.close() }
            // A shell tab exists but has never been started - exactly the
            // shape F2 leaves behind for a restored page the captain has not
            // opened, and the shape `connectHost(navigate: false)` leaves for
            // a page that never appears. No test hook needed: `addTab` starts
            // a tab only `if hasAppeared`, and this window was never ordered
            // in, so the real production path leaves it unstarted.
            controller.newShellTab()
            guard !controller.debugAllTabIDs().isEmpty else {
                return "the harness failed to add a tab, so this case would pass vacuously"
            }
            guard !controller.hasLiveSession else {
                return "a page whose only tab was never started reports a live session"
            }

            let registry = HostSessionRegistry()
            let host = UUID()
            registry.register(hostID: host, label: "Prod Bastion", accentHex: nil,
                              state: controller.hasLiveSession ? .connected : .restored)
            guard let session = registry.session(for: host) else {
                return "the host was not registered at all - switching into a restored page "
                    + "must still work, that is the affordance F2 exists to provide"
            }
            guard session.state == .restored else {
                return "an unstarted page registered as \(session.state) - this is §4.6's "
                    + "overclaim: the strip, the Hosts chip and F9's picker all read this"
            }
            guard !registry.isConnected(host) else {
                return "isConnected(_:) is true for a page with no process"
            }
            // `isLive` must stay true: it is what keeps the entry switchable
            // and out of ⌘K's duplicate Hosts row.
            guard registry.isLive(host) else {
                return "isLive(_:) went false for a restored page, which would drop it from "
                    + "the strip and the ⌘⌃ shortcuts"
            }
            return nil
        }
    }

    private static func test_startingATabConnectsTheEntry() -> String? {
        withScratchEnv {
            let (window, controller) = makeConsole()
            defer { window.close() }
            let registry = HostSessionRegistry()
            let host = UUID()
            registry.register(hostID: host, label: "Prod Bastion", accentHex: nil, state: .restored)
            // The real production wiring from `AppShellController.connectHost`.
            controller.onLiveSessionMayHaveChanged = {
                registry.setState(hostID: host, controller.hasLiveSession ? .connected : .restored)
            }
            guard registry.session(for: host)?.state == .restored else {
                return "precondition failed: the entry did not start out restored"
            }
            controller.newShellTab()
            guard !controller.hasLiveSession else {
                return "the tab started before the page ever appeared, so the restored->"
                    + "connected transition this case exists to measure never happens"
            }
            // A real login shell through the real, lock-gated appearance path,
            // which is the only thing that calls `startTab` - and `startTab`
            // is the one place `TabModel.started` is ever set.
            controller.runAppearanceWorkIfUnlocked()
            guard controller.hasLiveSession else {
                return "the harness's tab never started, so this case would pass vacuously"
            }
            guard registry.session(for: host)?.state == .connected else {
                return "starting a real tab left the entry at "
                    + "\(String(describing: registry.session(for: host)?.state)) - the strip "
                    + "would keep saying \"not connected\" for a live session"
            }
            return nil
        }
    }

    private static func test_reRegisterDoesNotDowngrade() -> String? {
        let registry = HostSessionRegistry()
        let host = UUID()
        registry.register(hostID: host, label: "Prod", accentHex: nil, state: .connected)
        // `connectHost` runs before the page appears, so it reports
        // `.restored` on every re-reveal of an already-connected host. Taking
        // that at face value would blank a live pill each time.
        registry.register(hostID: host, label: "Prod", accentHex: nil, state: .restored)
        guard registry.session(for: host)?.state == .connected else {
            return "a re-register downgraded a live session to restored - every re-reveal of a "
                + "connected host would flicker the strip to \"not connected\""
        }
        // The genuine teardown direction still has to work.
        registry.setState(hostID: host, .restored)
        guard registry.session(for: host)?.state == .restored else {
            return "setState could not move a live entry back to restored, so a page that lost "
                + "its last tab would keep claiming a connection"
        }
        return nil
    }

    private static func test_connectRestampsTheClock() -> String? {
        let registry = HostSessionRegistry()
        let host = UUID()
        registry.register(hostID: host, label: "Prod", accentHex: nil, state: .restored)
        guard let before = registry.session(for: host)?.startedAt else {
            return "no entry to measure"
        }
        // A restored page's `startedAt` is launch time; "Connected · 14m" has
        // to measure the connection, not how long the page sat unopened.
        Thread.sleep(forTimeInterval: 0.05)
        registry.setState(hostID: host, .connected)
        guard let after = registry.session(for: host)?.startedAt else { return "entry vanished" }
        guard after > before else {
            return "the connect clock was not restamped, so a page restored at launch and "
                + "opened hours later would immediately claim to have been connected for hours"
        }
        // ...and an ordinary re-notification must not keep resetting it.
        registry.setState(hostID: host, .connected)
        guard registry.session(for: host)?.startedAt == after else {
            return "a repeat .connected report restamped the clock again, so the duration "
                + "would reset on every tab open"
        }
        return nil
    }

    private static func test_surfaceWordingFollowsState() -> String? {
        let restored = HostSession(hostID: UUID(), label: "Prod", accentHex: nil,
                                   startedAt: Date(), state: .restored)
        let connected = HostSession(hostID: UUID(), label: "Prod", accentHex: nil,
                                    startedAt: Date(), state: .connected)
        guard connected.stateText.lowercased().contains("connected") else {
            return "a live session no longer says it is connected"
        }
        // The specific overclaim: a restored page must not use the word at all
        // - it is what the strip's accessibility label, the Hosts row's chip
        // and ⌘K's session row all render.
        guard !restored.stateText.lowercased().contains("connected")
            || restored.stateText.lowercased().contains("not connected") else {
            return "a restored page's wording still claims a connection: "
                + "\"\(restored.stateText)\""
        }
        guard restored.stateText != connected.stateText else {
            return "both states render the same string, so no surface can tell them apart"
        }
        guard !restored.isConnected, connected.isConnected else {
            return "isConnected does not follow state"
        }
        return nil
    }

    /// §4.5, which item §6.3 says its honesty work fixes "for free" - and the
    /// half no other suite can see, because `MultiHostSendSelfTest` injects
    /// its delivery closure and therefore never reaches this predicate.
    ///
    /// The harm was silent by construction: F9's picker showed a restored page
    /// as "Connected", `sendCommandToHost` took its immediate-send branch, and
    /// the text went into a terminal with no process on the other end with
    /// nothing reporting the drop.
    private static func test_isHostConnectedFollowsTheProcess() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            defer { window.close() }
            let host = Host(label: "Prod Bastion", address: "bastion.invalid",
                            username: "ec2-user", accentHex: "#22b3a6", tags: ["PROD"])
            let page = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                         isFirstmateConsole: false)
            // Seeded rather than reached through `connectHost`, which forks a
            // real `/usr/bin/ssh` - the same bypass `SessionSwitcherSelfTest`
            // uses, and for the same reason.
            shell.debugSeedHostConsole(page, hostID: host.id)
            page.view.layoutSubtreeIfNeeded()
            page.newShellTab()
            guard !page.debugAllTabIDs().isEmpty else {
                return "the harness failed to add a tab, so this case would pass vacuously"
            }
            guard !page.hasLiveSession else {
                return "the seeded page started its tab, so the not-connected state this case "
                    + "exists to measure never happens"
            }
            guard !shell.isHostConnected(host) else {
                return "isHostConnected reported a restored page as connected - F9 would take "
                    + "its immediate-send branch and type into a terminal with no process"
            }
            // Same overclaim, same fix: every reader of this set phrases its
            // count as *live* (the canvas's "N live sessions" subtitle, the
            // Console module's "N host live" chip, an `.ok` peek row per
            // host), so it must follow the process too.
            guard shell.debugConnectedHostIDs().isEmpty else {
                return "the canvas's connected-host set counts a restored page, so the hub "
                    + "would report a live session with no process behind it"
            }
            // And it has to flip once something genuinely starts, or F9 would
            // pointlessly delay every send to an already-open host.
            page.runAppearanceWorkIfUnlocked()
            guard page.hasLiveSession else { return "the page's tab never started" }
            guard shell.isHostConnected(host) else {
                return "isHostConnected stayed false for a page with a live process"
            }
            guard shell.debugConnectedHostIDs() == [host.id] else {
                return "the canvas's connected-host set did not pick up a genuinely live page"
            }
            return nil
        }
    }

    // MARK: §6.8 - the quit path

    /// Audit 2 §4.3 fixed this exact shape for the Sticky Board and left Code
    /// Preview's alone because `shutdown()` had no callers. Wiring it up
    /// without this would have *activated* that bug here rather than fixing
    /// it, so the two land together - and a source guard is what pins it,
    /// because a direct `commitAndPushNow()` and a queued flush commit the
    /// same work when the queue happens to be free. Nothing observable
    /// distinguishes them; only the source does.
    private static func test_codePreviewTerminateFlushIsQueued() -> String? {
        guard let store = readCode(named: "CodePreviewStore.swift") else {
            return "could not read CodePreviewStore.swift"
        }
        guard store.contains("func flushForTerminationNow()") else {
            return "CodePreviewGitSync has no bounded terminate flush - `shutdown()` would be "
                + "running git on the main thread, off the shared serial queue"
        }
        guard store.contains("terminateFlushBudget") else {
            return "the terminate flush has no bound, so quitting can block on a real network push"
        }
        guard store.contains("pendingCommit?.cancel()") else {
            return "the terminate flush does not cancel the pending debounced commit, so it can "
                + "fire during or after the flush and commit the same work twice"
        }
        guard let controller = readCode(named: "CodePreviewController.swift") else {
            return "could not read CodePreviewController.swift"
        }
        guard controller.contains("flushForTerminationNow") else {
            return "CodePreviewController.shutdown() does not use the queued flush"
        }
        guard !controller.contains("gitSync?.commitAndPushNow()") else {
            return "CodePreviewController still calls commitAndPushNow() directly - that is the "
                + "off-queue, unbounded, main-thread shape §4.3 fixed one store over"
        }
        // The ordering that makes the flush worth doing at all: the page's own
        // debounced edit has to come back over the bridge before git runs, or
        // the commit misses the very keystrokes this exists to save.
        guard let flushIdx = controller.range(of: "flushPendingEdits(waitingUpTo:"),
              let gitIdx = controller.range(of: "flushForTerminationNow") else {
            return "shutdown() no longer both flushes the page and flushes git"
        }
        guard flushIdx.lowerBound < gitIdx.lowerBound else {
            return "the git flush runs before the page's edit flush, so it commits a working "
                + "tree that does not yet contain the last keystrokes"
        }
        return nil
    }

    private static func test_codePreviewShutdownIsWired() -> String? {
        guard let main = readCode(named: "main.swift") else { return "could not read main.swift" }
        guard let shell = readCode(named: "AppShellController.swift") else {
            return "could not read AppShellController.swift"
        }
        guard shell.contains("func shutdownCodePreview()") else {
            return "AppShellController has no shutdownCodePreview() forward, so the app delegate "
                + "cannot reach the (private) destination"
        }
        guard main.contains("shutdownCodePreview()") else {
            return "nothing calls Code Preview's shutdown - it had zero callers for its whole "
                + "life (§2.8), so ⌘Q inside the page's 500ms edit debounce loses those "
                + "keystrokes and the final commit+push never runs"
        }
        // It has to be on the quit path specifically, not merely called
        // somewhere.
        guard let terminate = main.range(of: "func applicationWillTerminate") else {
            return "applicationWillTerminate is gone"
        }
        let tail = main[terminate.lowerBound...]
        guard tail.contains("shutdownCodePreview()") else {
            return "shutdownCodePreview() is called somewhere other than applicationWillTerminate"
        }
        return nil
    }

    // MARK: Helpers

    /// Mirrors `SessionSwitcherSelfTest.makeMountedShell`.
    private static func makeShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         snippetStore: snippetStore, dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
            shiftStore: ShiftStore(), dictationStore: DictationStore(),
            commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        shell.view.layoutSubtreeIfNeeded()
        return (window, shell)
    }

    private static func makeConsole() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                           isFirstmateConsole: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// Every store this touches points at a scratch directory. `ConsoleController`
    /// builds a bare `SSHKeyStore()`/`SnippetStore()`, which without these read
    /// the captain's real files (§7.3) - `main.swift`'s own redirect block
    /// covers a real run, and this is the belt for a suite invoked by hand.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit2-feature-enh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_KEYS_FILE", scratch.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", scratch.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_HOSTS_FILE", scratch.appendingPathComponent("hosts.json").path, 1)
        // A locked gate defers every privileged thing a console does on
        // appearing (#340 / §5.1), including `startTab` - and a self-test
        // process never runs the real unlock, so a case driving a real tab
        // start has to unlock first. Restored afterwards.
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }
        return body()
    }

    private static func readCode(named name: String) -> String? {
        guard let files = SelfTestSources.appSourceFiles() else { return nil }
        guard let file = files.first(where: { $0.lastPathComponent == name }) else { return nil }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

#endif
