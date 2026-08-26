// Manjesh Grand Line - native macOS app.
//
// Coverage for the session switcher (`fm/grandline-session-switcher`): the
// persistent strip of live-SSH-session pills, the Hosts list's per-row live
// state, the ⌘K palette's pinned "Active sessions" group, and the ⌘⌃1…9 /
// ⌘] / ⌘[ shortcut arithmetic.
//
// **What this drives for real, and what it deliberately does not.** Everything
// here goes through the real production types - a real `AppShellController`
// mounted in a real `NSWindow`, its real `HostSessionRegistry`, the real
// `SessionStripView` it owns, a real `HostsController`, the real
// `UnifiedSearchIndex` with the real providers registered. The one thing it
// does not do is *open* a session by calling `AppShellController.connectHost`,
// because that forks a real `/usr/bin/ssh` at a real address - so a session is
// created by calling `sessions.register(...)`, which is the exact line
// `connectHost` itself calls and the only writer of that fact. That leaves one
// honest gap, stated rather than papered over: this suite proves the strip, the
// rows, the palette and the shortcuts all react correctly to a registered
// session, and does not prove `connectHost` registers one - which is a single
// unconditional line right after `connectSSHIfNeeded`, and is guarded instead
// by `checkConnectHostIsTheOnlyRegistrar`, a source check.
//
// Run with:
//   swift build && FM_RUN_SESSION_SWITCHER_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SessionSwitcherSelfTest {

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `AppShellBodyWidthSelfTest.withScratchEnv`'s own long note on why a
        // leaked `fm.themeID` poisons every later suite in the run.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var failures: [String] = []
        let cases: [(String, () -> String?)] = [
            ("registryOrderAndDuration", test_registryOrderAndDuration),
            ("registryStepAndShortcutIndex", test_registryStepAndShortcutIndex),
            ("registryActiveNeverClaimsADeadHost", test_registryActiveNeverClaimsADeadHost),
            ("stripAppearsAndReservesRealHeight", test_stripAppearsAndReservesRealHeight),
            ("stripPillsCarryHostColourOrderAndShortcuts", test_stripPillsCarryHostColourOrderAndShortcuts),
            ("activePillHasNoCloseButton", test_activePillHasNoCloseButton),
            ("stripPillsAreAccessibleRadioButtons", test_stripPillsAreAccessibleRadioButtons),
            ("hostRowReadsAsConnectedAndResumes", test_hostRowReadsAsConnectedAndResumes),
            ("hostRowWithNoSessionIsUnchanged", test_hostRowWithNoSessionIsUnchanged),
            ("paletteAddsPinnedLiveGroupAndDoesNotDuplicate", test_paletteAddsPinnedLiveGroupAndDoesNotDuplicate),
            ("switchToUnknownSessionIsSafe", test_switchToUnknownSessionIsSafe),
            ("connectHostIsTheOnlyRegistrar", test_connectHostIsTheOnlyRegistrar),
            ("sessionShortcutsDoNotCollide", test_sessionShortcutsDoNotCollide),
        ]
        for (name, check) in cases {
            if let failure = check() { failures.append("\(name): \(failure)") }
        }
        for failure in failures { print("SessionSwitcherSelfTest FAIL - \(failure)") }
        print(failures.isEmpty ? "SessionSwitcherSelfTest: all \(cases.count) checks passed"
                               : "SessionSwitcherSelfTest: FAILED (\(failures.count)/\(cases.count))")
        return failures.isEmpty
    }

    // MARK: Fixtures

    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-session-switcher-test-\(UUID().uuidString)")
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

    /// The exact production dependency shape `main.swift` builds, mounted in a
    /// real (never ordered-front) window - copied from
    /// `AppShellBodyWidthSelfTest.makeMountedShell` so both suites drive the
    /// same real object graph.
    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController, hosts: HostStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore),
            console: ConsoleController(keyStore: keyStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore,
            shiftStore: ShiftStore(), dictationStore: DictationStore(),
            commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        shell.view.layoutSubtreeIfNeeded()
        return (window, shell, hostStore)
    }

    private static func devHost() -> Host {
        Host(label: "DEV Bastion", address: "ec2-44-206-131-135.compute-1.amazonaws.com",
             username: "centos", accentHex: "#e8a23d", tags: ["DEV"])
    }

    private static func prodHost() -> Host {
        Host(label: "Prod Bastion", address: "ec2-3-208-58-234.compute-1.amazonaws.com",
             username: "ec2-user", accentHex: "#22b3a6", tags: ["PROD"])
    }

    // MARK: Registry

    private static func test_registryOrderAndDuration() -> String? {
        let registry = HostSessionRegistry()
        let a = UUID(), b = UUID()
        registry.register(hostID: a, label: "DEV Bastion", accentHex: "#e8a23d")
        registry.register(hostID: b, label: "Prod Bastion", accentHex: "#22b3a6")
        // Insertion order, never sorted - the shortcut numbers and the strip's
        // left-to-right order are the same list, so a rename must not move a
        // captain's ⌘⌃2 out from under them.
        guard registry.sessions.map(\.label) == ["DEV Bastion", "Prod Bastion"] else {
            return "expected insertion order, got \(registry.sessions.map(\.label))"
        }
        // Idempotent, and a re-register refreshes the label without restarting
        // the clock.
        let started = registry.session(for: a)!.startedAt
        registry.register(hostID: a, label: "DEV Bastion (renamed)", accentHex: "#e8a23d")
        guard registry.sessions.count == 2 else { return "re-register added a duplicate row" }
        guard registry.session(for: a)?.label == "DEV Bastion (renamed)" else {
            return "re-register did not refresh the label"
        }
        guard registry.session(for: a)?.startedAt == started else {
            return "re-register restarted the session clock - 'Connected · 14m' would reset on every reveal"
        }
        let now = Date()
        let table: [(TimeInterval, String)] = [(5, "just now"), (60, "1m"), (14 * 60, "14m"),
                                               (60 * 60, "1h 00m"), (125 * 60, "2h 05m")]
        for (seconds, expected) in table {
            let text = HostSession.durationText(since: now.addingTimeInterval(-seconds), now: now)
            guard text == expected else { return "duration for \(seconds)s: expected \(expected), got \(text)" }
        }
        registry.unregister(hostID: a)
        guard registry.sessions.map(\.label) == ["Prod Bastion"] else { return "unregister did not remove the session" }
        return nil
    }

    private static func test_registryStepAndShortcutIndex() -> String? {
        let registry = HostSessionRegistry()
        guard registry.session(steppedBy: 1) == nil else { return "stepping an empty registry answered something" }
        let ids = (0..<10).map { _ in UUID() }
        for (i, id) in ids.enumerated() { registry.register(hostID: id, label: "Host \(i)", accentHex: nil) }
        // Only the first nine get a hint, because only the first nine have a
        // shortcut - a hint on an unreachable pill would be a lie.
        guard registry.shortcutIndex(for: ids[0]) == 1, registry.shortcutIndex(for: ids[8]) == 9,
              registry.shortcutIndex(for: ids[9]) == nil else {
            return "shortcut indices wrong: \(ids.map { registry.shortcutIndex(for: $0) ?? -1 })"
        }
        // Nothing active: forward answers the first, backward the last, so
        // both shortcuts do something from an ordinary destination.
        guard registry.session(steppedBy: 1)?.hostID == ids[0],
              registry.session(steppedBy: -1)?.hostID == ids[9] else {
            return "stepping with no active session did not fall back to first/last"
        }
        registry.setActive(ids[0])
        guard registry.session(steppedBy: 1)?.hostID == ids[1] else { return "⌘] did not advance" }
        guard registry.session(steppedBy: -1)?.hostID == ids[9] else { return "⌘[ did not wrap backwards" }
        registry.setActive(ids[9])
        guard registry.session(steppedBy: 1)?.hostID == ids[0] else { return "⌘] did not wrap forwards" }
        return nil
    }

    private static func test_registryActiveNeverClaimsADeadHost() -> String? {
        let registry = HostSessionRegistry()
        let live = UUID(), never = UUID()
        registry.register(hostID: live, label: "Live", accentHex: nil)
        registry.setActive(never)
        guard registry.activeHostID == nil else {
            return "activated a host with no session - the strip would fill in a pill nothing can switch to"
        }
        registry.setActive(live)
        registry.unregister(hostID: live)
        guard registry.activeHostID == nil else { return "unregister left the ended session active" }
        return nil
    }

    // MARK: Strip

    private static func test_stripAppearsAndReservesRealHeight() -> String? {
        withScratchEnv {
            let (_, shell, _) = makeMountedShell()
            let collapsedInset = shell.bodyTopInsetForTests
            guard shell.sessionStripIsHiddenForTests, shell.sessionStripHeightForTests == 0 else {
                return "strip is showing with no live sessions"
            }
            guard abs(collapsedInset - DaylightBarController.reservedTopHeight) < 0.5 else {
                return "collapsed body inset \(collapsedInset), expected \(DaylightBarController.reservedTopHeight)"
            }
            shell.sessions.register(hostID: UUID(), label: "DEV Bastion", accentHex: "#e8a23d")
            shell.view.layoutSubtreeIfNeeded()
            guard !shell.sessionStripIsHiddenForTests else { return "strip stayed hidden with a live session" }
            // The height half matters as much as `isHidden`: an ordinary
            // hidden `NSView` still constrains layout (gotcha (11)), so a
            // strip that only toggled visibility would leave a permanent gap.
            guard shell.sessionStripHeightForTests == SessionStripView.height else {
                return "strip height \(shell.sessionStripHeightForTests), expected \(SessionStripView.height)"
            }
            let grown = shell.bodyTopInsetForTests
            guard abs(grown - (collapsedInset + SessionStripView.gapBelowBar + SessionStripView.height)) < 0.5 else {
                return "body inset \(grown) did not grow by the strip's own height (was \(collapsedInset))"
            }
            guard shell.sessionStripForTests.frame.height > 1 else {
                return "strip resolved a zero-height frame while visible"
            }
            return nil
        }
    }

    private static func test_stripPillsCarryHostColourOrderAndShortcuts() -> String? {
        withScratchEnv {
            let (_, shell, _) = makeMountedShell()
            let dev = UUID(), prod = UUID()
            shell.sessions.register(hostID: dev, label: "DEV Bastion", accentHex: "#e8a23d")
            shell.sessions.register(hostID: prod, label: "Prod Bastion", accentHex: "#22b3a6")
            shell.view.layoutSubtreeIfNeeded()
            let strip = shell.sessionStripForTests
            guard strip.debugPillHostIDs() == [dev, prod] else {
                return "pill order does not match the registry's own order"
            }
            guard strip.debugPillShortcutText(dev) == "\u{2318}\u{2303}1",
                  strip.debugPillShortcutText(prod) == "\u{2318}\u{2303}2" else {
                return "shortcut hints wrong: \(strip.debugPillShortcutText(dev) ?? "nil") / \(strip.debugPillShortcutText(prod) ?? "nil")"
            }
            // A pill's dot is the captain's own per-host colour - the same
            // literal hue the Hosts row's accent bar carries, which is what
            // makes recognition instant (mockup callout b). Compared
            // component-wise: `HelmContrast.ratio(a, b) < 1.01` is a
            // *luminance* comparison and two different hues of similar
            // brightness pass it (a trap two other suites in this repo have
            // already walked into).
            for (id, hex) in [(dev, "#e8a23d"), (prod, "#22b3a6")] {
                guard let pill = strip.debugPillView(id),
                      let dot = pill.subviews.first?.subviews.first(where: { $0.layer?.cornerRadius == 3.5 }),
                      let painted = dot.layer?.backgroundColor.map({ NSColor(cgColor: $0) }) ?? nil else {
                    return "could not find the accent dot for \(hex)"
                }
                let expected = HelmContrast.components(HelmTheme.nsColor(hex))
                let actual = HelmContrast.components(painted)
                guard abs(expected.0 - actual.0) < 0.02, abs(expected.1 - actual.1) < 0.02,
                      abs(expected.2 - actual.2) < 0.02 else {
                    return "pill dot for \(hex) painted \(actual), expected \(expected)"
                }
            }
            return nil
        }
    }

    private static func test_activePillHasNoCloseButton() -> String? {
        withScratchEnv {
            let (_, shell, _) = makeMountedShell()
            let dev = UUID(), prod = UUID()
            shell.sessions.register(hostID: dev, label: "DEV Bastion", accentHex: nil)
            shell.sessions.register(hostID: prod, label: "Prod Bastion", accentHex: nil)
            shell.sessions.setActive(dev)
            shell.view.layoutSubtreeIfNeeded()
            let strip = shell.sessionStripForTests
            guard strip.debugActiveHostID() == dev else { return "the active pill is not the active session" }
            // Mockup callout c: no ✕ on the active pill, so a mis-click cannot
            // close the session currently being read.
            guard strip.debugPillHasCloseButton(dev) == false else {
                return "the active pill offers a close button"
            }
            guard strip.debugPillHasCloseButton(prod) == true else {
                return "an inactive pill has no close button"
            }
            return nil
        }
    }

    private static func test_stripPillsAreAccessibleRadioButtons() -> String? {
        withScratchEnv {
            let (_, shell, _) = makeMountedShell()
            let dev = UUID()
            shell.sessions.register(hostID: dev, label: "DEV Bastion", accentHex: nil)
            shell.sessions.setActive(dev)
            shell.view.layoutSubtreeIfNeeded()
            let strip = shell.sessionStripForTests
            guard let pill = strip.debugPillView(dev) else { return "no pill built" }
            guard pill.isActivatable else { return "pill is invisible to VoiceOver and the key loop" }
            guard pill.accessibilityRoleOverride == .radioButton else {
                return "pill role is \(String(describing: pill.accessibilityRoleOverride)), expected radioButton"
            }
            guard pill.accessibilityValueOverride == "selected" else {
                return "active pill does not announce itself as selected"
            }
            guard let label = strip.debugPillAccessibilityLabel(dev),
                  label.contains("DEV Bastion"), label.contains("connected") else {
                return "pill label does not name the host and its state: \(strip.debugPillAccessibilityLabel(dev) ?? "nil")"
            }
            guard strip.debugAddButton().isActivatable,
                  strip.debugAddButton().accessibilityLabelOverride == "New session" else {
                return "the + affordance is not an accessible button"
            }
            // The strip sits between the bar and the body in the key loop.
            guard strip.keyViewChain.count >= 2 else { return "strip contributes nothing to the key view loop" }
            return nil
        }
    }

    // MARK: Hosts rows

    private static func test_hostRowReadsAsConnectedAndResumes() -> String? {
        withScratchEnv {
            let hostStore = HostStore()
            let host = devHost()
            hostStore.add(host)
            let panel = HostsController(hostStore: hostStore, keyStore: SSHKeyStore())
            let registry = HostSessionRegistry()
            registry.register(hostID: host.id, label: host.label, accentHex: host.accentHex)
            panel.liveSession = { registry.session(for: $0) }
            var switched: [UUID] = []
            var connected = false
            var ended: [UUID] = []
            panel.onSwitchToSession = { switched.append($0) }
            panel.onEndSession = { ended.append($0) }
            panel.onConnect = { _, _, _, _, _ in connected = true }
            _ = panel.view
            panel.refreshLiveSessionState()

            guard let row = panel.debugHostRowItem(labelled: host.label) else { return "no row for the host" }
            guard let chip = row.content.chipText, chip.hasPrefix("Connected") else {
                return "row chip does not read as connected: \(row.content.chipText ?? "nil")"
            }
            guard row.content.chipTint == .good else { return "connected chip is not the shared good tint" }
            guard row.primary?.title == "Switch to session" else {
                return "row action reads \(row.primary?.title ?? "nil") - a live host must not look like a fresh connect"
            }
            row.primary?.run()
            row.activate?()
            guard switched == [host.id, host.id], !connected else {
                return "the live row's action reconnected instead of resuming (switched=\(switched.count), connected=\(connected))"
            }
            guard row.overflow.first?.title == "End Session" else {
                return "a live row offers no way to end the session"
            }
            row.overflow.first?.run()
            guard ended == [host.id] else { return "End Session did not reach the shell" }
            return nil
        }
    }

    private static func test_hostRowWithNoSessionIsUnchanged() -> String? {
        withScratchEnv {
            let hostStore = HostStore()
            let host = prodHost()
            hostStore.add(host)
            let panel = HostsController(hostStore: hostStore, keyStore: SSHKeyStore())
            // No `liveSession` wired at all - the pre-switcher shape, which
            // must render exactly the pre-switcher row.
            _ = panel.view
            panel.refreshLiveSessionState()
            guard let row = panel.debugHostRowItem(labelled: host.label) else { return "no row for the host" }
            guard row.primary?.title == "Connect" else {
                return "an idle row's action is \(row.primary?.title ?? "nil"), expected Connect"
            }
            guard row.content.chipText == nil || !(row.content.chipText!.hasPrefix("Connected")) else {
                return "an idle row claims to be connected"
            }
            guard row.overflow.first?.title == "Edit…" else {
                return "an idle row gained an End Session item"
            }
            return nil
        }
    }

    // MARK: ⌘K palette

    private static func test_paletteAddsPinnedLiveGroupAndDoesNotDuplicate() -> String? {
        withScratchEnv {
            let hostStore = HostStore()
            let dev = devHost(), prod = prodHost()
            hostStore.add(dev)
            hostStore.add(prod)
            let registry = HostSessionRegistry()
            registry.register(hostID: prod.id, label: prod.label, accentHex: prod.accentHex)

            var switched: [UUID] = []
            var connected: [UUID] = []
            let index = UnifiedSearchIndex()
            index.register(UnifiedSearchSessionProvider(registry: registry, store: hostStore,
                                                        onSwitch: { switched.append($0) }))
            index.register(UnifiedSearchHostProvider(store: hostStore,
                                                     onConnect: { connected.append($0.id) },
                                                     isLive: { registry.isLive($0) }))

            let groups = index.groups(query: "prod")
            guard let first = groups.first, first.title == "Active sessions" else {
                return "live sessions are not the first group: \(groups.map(\.title))"
            }
            guard first.items.count == 1, first.items[0].id == prod.id.uuidString else {
                return "the pinned group does not hold the live session"
            }
            guard first.items[0].meta.hasPrefix("LIVE") else {
                return "a live row is not marked live: \(first.items[0].meta)"
            }
            // The same host must not appear twice, once as "Switch" and once
            // as "Connect" - that ambiguity is what the switcher removes.
            let hostGroup = groups.first { $0.title == "Hosts" }
            guard hostGroup?.items.contains(where: { $0.id == prod.id.uuidString }) != true else {
                return "the live host is listed in Hosts as well as Active sessions"
            }
            first.items[0].activate()
            guard switched == [prod.id], connected.isEmpty else {
                return "selecting a live session reconnected instead of switching"
            }
            // An idle host still connects, exactly as before.
            let devGroups = index.groups(query: "dev")
            guard let devRow = devGroups.first(where: { $0.title == "Hosts" })?.items.first else {
                return "an idle host no longer appears under Hosts"
            }
            devRow.activate()
            guard connected == [dev.id] else { return "an idle host's row stopped connecting" }
            // An empty query shows the live sessions (the one deliberate
            // exception, alongside the actions provider) and no hosts.
            let empty = index.groups(query: "")
            guard empty.contains(where: { $0.title == "Active sessions" }) else {
                return "⌘K with a live session open shows nothing until something is typed"
            }
            guard !empty.contains(where: { $0.title == "Hosts" }) else {
                return "the hosts provider started answering an empty query"
            }
            return nil
        }
    }

    // MARK: Shell behaviour

    private static func test_switchToUnknownSessionIsSafe() -> String? {
        withScratchEnv {
            let (_, shell, _) = makeMountedShell()
            // A stale id from a pill that was just closed, or a host deleted
            // out from under a ⌘K row: every caller fires against a possibly
            // stale id, so this must be a no-op rather than a crash or a blank
            // page.
            shell.switchToSession(hostID: UUID())
            guard shell.activeHostIDForTests == nil else { return "an unknown id became the active host page" }
            // Registered but with no console behind it (the registry's writer
            // is `connectHost`, which builds the console first) - still a
            // no-op, never a reveal of nothing.
            let orphan = UUID()
            shell.sessions.register(hostID: orphan, label: "Orphan", accentHex: nil)
            shell.switchToSession(hostID: orphan)
            guard shell.activeHostIDForTests == nil else { return "revealed a session with no console" }
            return nil
        }
    }

    // MARK: Source guards

    /// `connectHost` is the one place a session is registered and
    /// `removeHostConsole` the one place it is unregistered - the property
    /// that makes this registry a single source of truth rather than a fifth
    /// independent notion of liveness. A behavioural check cannot see a second
    /// writer added elsewhere, so this reads the source.
    private static func test_connectHostIsTheOnlyRegistrar() -> String? {
        let dir = SelfTestSources.appSourceDirectory()
        guard let dir else { return nil }
        var registrars: [String] = []
        var unregistrars: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where name.hasSuffix(".swift") && name != "HostSessionRegistry.swift" {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name)) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.contains(".register(hostID:") { registrars.append(name) }
                if line.contains(".unregister(hostID:") { unregistrars.append(name) }
            }
        }
        guard registrars == ["AppShellController.swift"] else {
            return "sessions are registered from \(registrars) - expected only AppShellController.connectHost"
        }
        guard unregistrars == ["AppShellController.swift"] else {
            return "sessions are unregistered from \(unregistrars) - expected only AppShellController.removeHostConsole"
        }
        return nil
    }

    /// The session shortcuts must not silently shadow a shipped one.
    ///
    /// ⌘1-⌘9 is already taken twice (the Tab menu's nil-target "Select Tab N"
    /// and the View menu's always-enabled space items), which is *why* the
    /// session shortcuts are ⌘⌃1-9 rather than the mockup's ⌘1/⌘2. A behavioural
    /// check is not available here: a suite exits before `AppDelegate` ever
    /// builds a menu bar (GL-05's note in `main.swift`), so `NSApp.mainMenu` is
    /// nil and a runtime walk would pass vacuously. This reads `main.swift`'s
    /// real declarations instead.
    private static func test_sessionShortcutsDoNotCollide() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("main.swift")) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Every declared key equivalent, paired with the modifier mask set on
        // the line(s) that follow it. Deliberately crude: it is looking for a
        // *second* claim on a shortcut this feature took, not parsing Swift.
        var bracketClaims = 0
        for line in lines where line.contains("keyEquivalent: \"]\"") || line.contains("keyEquivalent: \"[\"") {
            bracketClaims += 1
        }
        guard bracketClaims == 2 else {
            return "expected exactly 2 declarations of ⌘] / ⌘[ (Next/Previous Session), found \(bracketClaims)"
        }
        // A bare ⌘] / ⌘[ needs no explicit mask (command is the default), so
        // any *other* modifier being attached to those two would silently move
        // them - assert the two lines that follow each are not mask lines.
        for (i, line) in lines.enumerated()
        where line.contains("keyEquivalent: \"]\"") || line.contains("keyEquivalent: \"[\"") {
            let following = lines[(i + 1)..<min(i + 4, lines.count)].joined()
            guard !following.contains("keyEquivalentModifierMask") else {
                return "a session cycle shortcut declares a modifier mask - it is no longer plain ⌘] / ⌘["
            }
        }
        // The nine session items must be the only ⌘⌃ + digit claims. Every
        // other ⌘⌃ item in this menu bar is a letter (⌘⌃N, ⌘⌃S).
        var controlDigitClaims: [String] = []
        for (i, line) in lines.enumerated() where line.contains("keyEquivalentModifierMask = [.command, .control]") {
            // The key equivalent is declared on the item this mask belongs to,
            // a line or two above.
            let preceding = lines[max(0, i - 3)..<i].joined()
            if let range = preceding.range(of: "keyEquivalent: \"") {
                let rest = preceding[range.upperBound...]
                if let key = rest.first, key.isNumber || rest.hasPrefix("\\(n)") {
                    controlDigitClaims.append(String(rest.prefix(6)))
                }
            }
        }
        guard controlDigitClaims.count == 1 else {
            return "⌘⌃<digit> is claimed \(controlDigitClaims.count) times (\(controlDigitClaims)) - expected only the Session N loop"
        }
        // And the session items really are wired to the shell's own action.
        guard text.contains("AppShellController.selectSessionByShortcut"),
              text.contains("AppShellController.nextSession"),
              text.contains("AppShellController.previousSession") else {
            return "the session menu items are not wired to the shell's session actions"
        }
        return nil
    }
}

#endif
