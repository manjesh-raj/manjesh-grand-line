// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_STRAW_HAT_HANDOFF_TESTS=1` - Straw Hat Pirates **phase 3**,
// milestone M3.2: the two navigation handoffs' *resolution*, against a real
// `AppShellController`.
//
// ## Why this is its own suite
//
// `StrawHatViewSelfTest` mounts a `FleetController` and covers the handoff
// end the chat owns: that a navigation proposal renders as a link rather
// than a confirm card, that clicking it reaches the page's closure, and that
// it writes nothing. What it cannot cover is what happens *after* that
// closure, because the decisions live one level up in the shell - which host
// a hint resolves to, whether a session is live at all, and whether the
// Whiteboard's own composer is opened carrying the idea.
//
// So this suite mounts the real shell, the way `SessionSwitcherSelfTest` and
// `AppShellBodyWidthSelfTest` already do, and drives
// `openSRELeadForCrew(hostHint:)` / `openDestinationForCrew(_:hint:)`
// directly.
//
// ## The property this suite exists to protect
//
// A handoff link runs on a **single click with no confirm card**, and that is
// only defensible while it genuinely writes nothing and starts nothing. The
// load-bearing half of that is `openSRELeadForCrew`'s refusal to *connect* a
// host that is not already connected: forking a real `/usr/bin/ssh`, and
// possibly prompting for Touch ID to materialise a key, is not navigation,
// and a model-authored link row is not where the captain should be asked for
// it. Several cases below assert exactly that.
//
// The second property is that the **app** resolves which host, never the
// crew. They cannot see hosts at all, so a hint is only ever a name the
// captain themselves used - and two matches is a refusal rather than a guess,
// the same conservative shape `KubeContextParser` and `MultiHostSend` already
// take.
//
// Window-backed (it mounts a real shell), so it belongs in
// `run-all-tests.sh`'s `NEEDS_SESSION` list beside its Daylight peers.

#if FM_SELFTESTS

import AppKit


enum StrawHatHandoffSelfTest {

    static func run() -> Bool {
        _ = NSApplication.shared
        var failures: [String] = []
        let cases: [(String, () -> String?)] = [
            ("noLiveSessionRefusesAndLandsOnHosts", noLiveSessionRefusesAndLandsOnHosts),
            ("oneLiveSessionIsFollowedWithNoHint", oneLiveSessionIsFollowedWithNoHint),
            ("aHintPicksTheHostTheCaptainNamed", aHintPicksTheHostTheCaptainNamed),
            ("anAmbiguousHintRefusesRatherThanGuessing", anAmbiguousHintRefusesRatherThanGuessing),
            ("anUnknownHintRefusesRatherThanFallingBack", anUnknownHintRefusesRatherThanFallingBack),
            ("severalSessionsAndNoHintRefuses", severalSessionsAndNoHintRefuses),
            ("aPageWithNoTabSaysSoRatherThanLookingLikeItWorked",
             aPageWithNoTabSaysSoRatherThanLookingLikeItWorked),
            ("aHandoffNeverConnectsAHostThatIsNotConnected", aHandoffNeverConnectsAHostThatIsNotConnected),
            ("destinationHandoffSelectsThePage", destinationHandoffSelectsThePage),
            ("whiteboardHandoffOpensTheExistingComposerPrefilled", whiteboardHandoffOpensTheExistingComposerPrefilled),
            ("theAllowlistIsNarrowerThanRailDestination", theAllowlistIsNarrowerThanRailDestination),
            ("askingForTheComposerOffPageDoesNotThrow", askingForTheComposerOffPageDoesNotThrow),
        ]
        for (name, check) in cases {
            if let failure = check() { failures.append("\(name): \(failure)") }
        }
        for failure in failures { print("StrawHatHandoffSelfTest FAIL - \(failure)") }
        print(failures.isEmpty ? "StrawHatHandoffSelfTest: all \(cases.count) checks passed"
                               : "StrawHatHandoffSelfTest: FAILED (\(failures.count)/\(cases.count))")
        return failures.isEmpty
    }

    // MARK: Fixtures

    /// Copied from `SessionSwitcherSelfTest.withScratchEnv` so both suites
    /// isolate the same set - plus `ThemeManager`/`AppSettings`, which
    /// mounting a real shell writes through to real `UserDefaults` and which
    /// a suite that leaves them flipped poisons for whatever runs next
    /// (`Phase3PolishSelfTest.checkSuitesRestoreTheTheme` is the guard).
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-handoff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
            "FM_COMMAND_LIBRARY_DIR": dir.appendingPathComponent("commands").path,
            "FM_STICKY_BOARD_DIR": dir.appendingPathComponent("sticky").path,
            "FM_SCHEDULES_FILE": dir.appendingPathComponent("schedules.json").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }

    /// The production dependency shape, in a real (never ordered-front)
    /// window - `AppShellBodyWidthSelfTest.makeMountedShell`'s own copy, so
    /// every shell-mounting suite drives the same real object graph.
    private static func makeMountedShell()
        -> (window: NSWindow, shell: AppShellController, keys: SSHKeyStore, snippets: SnippetStore) {
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
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        shell.view.layoutSubtreeIfNeeded()
        return (window, shell, keyStore, snippetStore)
    }

    /// A session created the way `SessionSwitcherSelfTest` creates one -
    /// `sessions.register(...)`, the exact line `connectHost` calls - rather
    /// than by calling `connectHost`, which forks a real `/usr/bin/ssh`.
    ///
    /// This suite's honest limit, stated the way that one states its own: it
    /// proves the resolution reacts correctly to a registered session, and
    /// deliberately does not prove `connectHost` registers one.
    private static func register(_ shell: AppShellController, label: String,
                                 keyStore: SSHKeyStore, snippetStore: SnippetStore,
                                 withTab: Bool = true) -> UUID {
        let id = UUID()
        shell.sessions.register(hostID: id, label: label, accentHex: nil, state: .connected)
        // `switchToSession` needs a real entry in `hostConsoles` as well as a
        // registered session - `debugSeedHostConsole` is the same bypass the
        // Recents suite uses, and the reason it exists: `connectHost` would
        // fork a real `/usr/bin/ssh`.
        let console = ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                        isFirstmateConsole: false)
        shell.debugSeedHostConsole(console, hostID: id)
        if withTab {
            // A real `.ssh` tab, and deliberately **no process**: the seeded
            // console's view never appears, so `addTab`'s own `hasAppeared`
            // guard means nothing is forked - which is exactly the state this
            // suite wants, a real `TabModel` for the handoff to land on with
            // no `ssh` anywhere near it.
            console.debugOpenTestSSHTab(label: label)
        }
        return id
    }

    /// Lets a `startSRELead` that the handoff kicked off actually land, then
    /// tears it down.
    ///
    /// `SRELead.setUp()` runs on a background queue and calls back on main;
    /// it creates a scratch directory and an MCP config and spawns **no**
    /// process (nothing runs until a question is asked). Tearing it down
    /// stops the bridge's own poll timer rather than leaving one running for
    /// the rest of the suite.
    private static func settleAndTearDownSRELead(_ shell: AppShellController, hostID: UUID) {
        guard let console = shell.debugHostConsole(id: hostID),
              let tabID = console.debugAllTabIDs().first else { return }
        let deadline = Date().addingTimeInterval(10)
        while console.debugSRELeadPhase(forTabID: tabID) == .starting && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        console.debugTearDownSRELead(forTabID: tabID)
    }

    // MARK: SRE Lead resolution

    private static func noLiveSessionRefusesAndLandsOnHosts() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            guard let message = m.shell.openSRELeadForCrew(hostHint: nil) else {
                return "with no live session the handoff must refuse, not report success"
            }
            guard message.lowercased().contains("live host session") else {
                return "and the refusal must say why, got \(message)"
            }
            // Landing on Hosts is the useful next step - Connect there is the
            // captain's own deliberate click, which is exactly what a handoff
            // must not make for them.
            guard m.shell.debugCurrentDestination == .hosts else {
                return "...and land on Hosts, got \(String(describing: m.shell.debugCurrentDestination))"
            }
            return nil
        }
    }

    private static func oneLiveSessionIsFollowedWithNoHint() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            let id = register(m.shell, label: "Prod Bastion", keyStore: m.keys, snippetStore: m.snippets)
            guard m.shell.openSRELeadForCrew(hostHint: nil) == nil else {
                return "one live session and no hint is unambiguous - it must be followed"
            }
            guard m.shell.debugActiveHostID == id else {
                return "and the app must switch to it, got \(String(describing: m.shell.debugActiveHostID))"
            }
            // ...and the pane really opened on that page, which is what makes
            // this the whole path rather than only the resolution half.
            guard let console = m.shell.debugHostConsole(id: id),
                  let tabID = console.debugAllTabIDs().first,
                  console.debugSRELeadPhase(forTabID: tabID) != SRELeadPhase.notStarted else {
                return "the handoff must actually start SRE Lead on that page"
            }
            settleAndTearDownSRELead(m.shell, hostID: id)
            return nil
        }
    }

    private static func aHintPicksTheHostTheCaptainNamed() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            let dev = register(m.shell, label: "DEV Bastion", keyStore: m.keys, snippetStore: m.snippets)
            let prod = register(m.shell, label: "Prod Bastion", keyStore: m.keys, snippetStore: m.snippets)
            guard m.shell.openSRELeadForCrew(hostHint: "prod") == nil else {
                return "a hint that matches exactly one live session must be followed"
            }
            guard m.shell.debugActiveHostID == prod else {
                return "...and pick that one, got \(String(describing: m.shell.debugActiveHostID))"
            }
            settleAndTearDownSRELead(m.shell, hostID: prod)
            // Case-insensitive: the captain wrote whatever they wrote.
            guard m.shell.openSRELeadForCrew(hostHint: "DEV BASTION") == nil,
                  m.shell.debugActiveHostID == dev else {
                return "an exact label match must be case-insensitive"
            }
            settleAndTearDownSRELead(m.shell, hostID: dev)
            return nil
        }
    }

    private static func anAmbiguousHintRefusesRatherThanGuessing() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            _ = register(m.shell, label: "Prod Bastion EU", keyStore: m.keys, snippetStore: m.snippets)
            _ = register(m.shell, label: "Prod Bastion US", keyStore: m.keys, snippetStore: m.snippets)
            guard let message = m.shell.openSRELeadForCrew(hostHint: "prod") else {
                return "two matches is genuinely ambiguous - opening one would be a guess"
            }
            guard message.lowercased().contains("more than one") else {
                return "and the refusal must say so, got \(message)"
            }
            guard m.shell.debugActiveHostID == nil else {
                return "...without having switched to either, got \(String(describing: m.shell.debugActiveHostID))"
            }
            return nil
        }
    }

    private static func anUnknownHintRefusesRatherThanFallingBack() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            _ = register(m.shell, label: "DEV Bastion", keyStore: m.keys, snippetStore: m.snippets)
            // The interesting shape: there IS exactly one live session, so a
            // lazier resolution would just use it. But the captain named a
            // different host, and opening the wrong one is worse than saying
            // it is not there.
            guard let message = m.shell.openSRELeadForCrew(hostHint: "prod-bastion") else {
                return "a hint naming a host with no live session must not silently use another one"
            }
            guard message.contains("prod-bastion") else {
                return "and the refusal must name what was asked for, got \(message)"
            }
            guard m.shell.debugActiveHostID == nil else {
                return "...without switching to the one that happened to be live"
            }
            return nil
        }
    }

    private static func severalSessionsAndNoHintRefuses() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            _ = register(m.shell, label: "DEV Bastion", keyStore: m.keys, snippetStore: m.snippets)
            _ = register(m.shell, label: "Prod Bastion", keyStore: m.keys, snippetStore: m.snippets)
            guard let message = m.shell.openSRELeadForCrew(hostHint: nil) else {
                return "two live sessions and no hint must not pick one"
            }
            guard message.contains("2 live sessions") else {
                return "and the refusal must count them, got \(message)"
            }
            return nil
        }
    }

    /// A live session whose page has no tab yet is a real "nothing happened",
    /// and the link row says so rather than looking like it worked.
    ///
    /// Reachable in production: `connectHost(navigate: false)` builds a page
    /// without appearing it, so `addTab`'s `hasAppeared` guard leaves it
    /// tabless until the captain opens it.
    private static func aPageWithNoTabSaysSoRatherThanLookingLikeItWorked() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            let id = register(m.shell, label: "Prod Bastion", keyStore: m.keys,
                              snippetStore: m.snippets, withTab: false)
            guard let message = m.shell.openSRELeadForCrew(hostHint: nil) else {
                return "a page with no tab must not report success"
            }
            guard message.lowercased().contains("no tab") else {
                return "and must say what was missing, got \(message)"
            }
            // It still took the captain there - that half of the handoff did
            // work, and saying otherwise would be the opposite dishonesty.
            guard m.shell.debugActiveHostID == id else {
                return "...having still switched to the page, got \(String(describing: m.shell.debugActiveHostID))"
            }
            return nil
        }
    }

    /// **The property that makes a no-confirm link defensible.**
    ///
    /// A saved host with no live session must not be connected by a handoff -
    /// that forks a real `ssh` and can prompt for Touch ID, neither of which
    /// is navigation. Asserted by there being no console for it afterwards:
    /// `connectHost` is the only thing that creates one.
    private static func aHandoffNeverConnectsAHostThatIsNotConnected() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            // A registered-but-restored session, i.e. an F2-restored page the
            // captain has not opened - and no console seeded for it, so
            // "nothing was started" is observable.
            let id = UUID()
            m.shell.sessions.register(hostID: id, label: "Prod Bastion", accentHex: nil, state: .restored)
            let message = m.shell.openSRELeadForCrew(hostHint: "Prod Bastion")
            guard m.shell.debugHostConsole(id: id) == nil else {
                return "a handoff must never fork a session - a real ssh and a Touch ID prompt are not navigation"
            }
            // It says so rather than looking like it worked - and does not
            // claim to have *opened* a page that never appeared, which is the
            // same overclaim the crew's own honesty rules forbid.
            guard let message, !message.isEmpty else {
                return "...and it must report that nothing happened, not return success"
            }
            guard !message.lowercased().contains("i opened") else {
                return "...without claiming to have opened it, got \(message)"
            }
            guard m.shell.debugCurrentDestination == .hosts else {
                return "...landing on Hosts instead, got \(String(describing: m.shell.debugCurrentDestination))"
            }
            return nil
        }
    }

    // MARK: Destination resolution

    private static func destinationHandoffSelectsThePage() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            for dest in [RailDestination.logAnalyzer, .stickyBoard, .runbooks, .console] {
                m.shell.openDestinationForCrew(dest, hint: nil)
                guard m.shell.debugCurrentDestination == dest else {
                    return "a destination handoff must select \(dest.rawValue), got \(String(describing: m.shell.debugCurrentDestination))"
                }
            }
            return nil
        }
    }

    /// Usopp's "draw it out": the handoff lands on the Whiteboard's **own**
    /// "Generate diagram" composer, carrying the idea.
    ///
    /// Not a second generator - the same popover, the same Generate button,
    /// the same `WhiteboardDiagram.run`. Arriving with the description already
    /// typed in is this app's own deep-link convention (every `open*(id:)`
    /// wrapper reveals the record rather than only selecting its page), and
    /// is what stops the handoff discarding the idea it was about.
    ///
    /// **Nothing is generated**: the prefill is text in a field the captain
    /// reads and edits, and Generate is still their own press. Asserted here
    /// by the composer's status line staying empty - a generation in flight
    /// sets it.
    private static func whiteboardHandoffOpensTheExistingComposerPrefilled() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            m.shell.openDestinationForCrew(.whiteboard, hint: "three boxes and an arrow")
            guard m.shell.debugCurrentDestination == .whiteboard else {
                return "the handoff must select the Whiteboard first"
            }
            // The composer is opened one runloop turn later, because the
            // button it anchors on has only just been put into the drill
            // header.
            let deadline = Date().addingTimeInterval(5)
            while m.shell.debugWhiteboard.debugComposer.debugPrompt != "three boxes and an arrow"
                    && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            guard m.shell.debugWhiteboard.debugComposer.debugPrompt == "three boxes and an arrow" else {
                return "the idea must be typed into the existing composer, got \(m.shell.debugWhiteboard.debugComposer.debugPrompt)"
            }
            guard m.shell.debugWhiteboard.debugComposer.debugStatus.isEmpty else {
                return "...and nothing generated - Generate is the captain's own press, got \(m.shell.debugWhiteboard.debugComposer.debugStatus)"
            }
            // A handoff with no hint opens nothing extra rather than clearing
            // whatever the captain had typed.
            m.shell.openDestinationForCrew(.whiteboard, hint: nil)
            let settle = Date().addingTimeInterval(0.4)
            while Date() < settle { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            guard m.shell.debugWhiteboard.debugComposer.debugPrompt == "three boxes and an arrow" else {
                return "a hintless handoff must not clear the field, got \(m.shell.debugWhiteboard.debugComposer.debugPrompt)"
            }
            return nil
        }
    }

    /// Asking for the diagram composer while the Whiteboard is **not** the
    /// destination on screen must not throw.
    ///
    /// `NSPopover.show(relativeTo:of:preferredEdge:)` raises
    /// `NSInvalidArgumentException` ("view has no window") rather than
    /// no-opping, and the button it anchors on lives in the shell's drill
    /// header - which carries whichever destination is showing. So off-page
    /// it genuinely has no window.
    ///
    /// **This case exists because an injected regression found it**: a
    /// deliberately broken `openDestinationForCrew` (its `dest == .whiteboard`
    /// guard removed) reached the composer for an ordinary handoff and took
    /// the whole process down. The production guard makes that unreachable
    /// today, but handing an API that *throws* an unchecked assumption is the
    /// class this app has crashed on before, so the check moved into
    /// `openDiagramComposer` itself and this pins it.
    private static func askingForTheComposerOffPageDoesNotThrow() -> String? {
        withScratchEnv {
            let m = makeMountedShell()
            // Somewhere that is definitely not the Whiteboard.
            m.shell.show(.logAnalyzer)
            m.shell.view.layoutSubtreeIfNeeded()
            // Reaching past the production guard on purpose - the point is
            // that this call is survivable, not that the guard exists.
            let opened = m.shell.debugWhiteboard.openDiagramComposer(prefill: "off-page idea")
            guard opened == false else {
                return "the composer must not claim to have opened with no window to anchor to"
            }
            // The idea is still landed, so a captain who navigates there
            // themselves finds it typed in rather than lost.
            guard m.shell.debugWhiteboard.debugComposer.debugPrompt == "off-page idea" else {
                return "...and the prefill must still land, got \(m.shell.debugWhiteboard.debugComposer.debugPrompt)"
            }
            return nil
        }
    }

    /// The allowlist, asserted against the real enum rather than against a
    /// copy of itself - so a destination added to `RailDestination` is not
    /// silently reachable by a model-authored one-click link.
    private static func theAllowlistIsNarrowerThanRailDestination() -> String? {
        guard StrawHatHandoff.allowedDestinations.count < RailDestination.allCases.count else {
            return "the handoff allowlist must be narrower than every destination in the app"
        }
        for dest in [RailDestination.poneglyph, .vault, .settings, .bootstrap,
                     .updates, .automation, .githubSync, .dictation, .overview, .homeCanvas] {
            guard !StrawHatHandoff.allowedDestinations.contains(dest) else {
                return "\(dest.rawValue) must not be reachable by a crew handoff"
            }
        }
        return nil
    }
}

#endif
