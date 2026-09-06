// Manjesh Grand Line - native macOS app.
//
// F2, session restoration (audit §2 item 1) - `SessionRestore.swift` plus the
// capture/restore methods on `AppShellController`, `ConsoleController` and
// `ToolsController`.
//
// Three halves, and the middle one is the reason this feature is safe.
//
// The **encoding** cases pin the persisted shape: a round trip through JSON,
// and - the part that matters more - that a state written by an *older* build
// still decodes. `SessionRestoreState` has hand-written decoders precisely
// because a synthesized `Decodable` requires every declared key to be present,
// which is how one added field once made every existing `hosts.json`
// undecodable and emptied the captain's saved hosts (AGENTS.md's
// `blockViewOptIn` incident). This asserts the lesson was applied rather than
// only written down.
//
// The **plan** cases are pure: `SessionRestorePlan.hosts` decides which hosts
// to reconnect hidden and which one to open, including a host deleted between
// runs and a showing host that no longer exists. Split out from the delegate
// exactly so it can be asserted without connecting anything.
//
// The **behaviour** cases drive real controllers. The load-bearing one is
// `hostPagesComeBackWithoutConnecting`: a restored host page must exist and
// must NOT fork `ssh` until the captain opens it, because otherwise this
// feature would open a fistful of SSH connections - and, for hosts with saved
// keys, a fistful of Touch ID prompts - at every launch. `ConsoleController.
// addTab`'s `if hasAppeared` guard is what provides that, and this is what
// stops a future refactor removing it silently.
//
// No case here ever appears a console with an `.ssh` tab, for the reason
// `TabForwardDragsToggleSelfTest`'s header gives: that would attempt a real
// `ssh` subprocess, which is not something a headless suite should do. The
// showing-host half is proven through the pure plan instead.
//
// Confirmed, per this project's convention, to catch a real regression rather
// than merely to pass - see this task's PR description for the injections and
// which case each one failed.
//
// Run with:
//   swift build && FM_RUN_SESSION_RESTORE_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SessionRestoreSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("theSavedStateRoundTripsThroughJSON", test_roundTrip),
            ("aStateFromAnOlderBuildStillDecodes", test_forwardCompatibleDecode),
            ("thePlanDropsHostsDeletedBetweenRuns", test_plan),
            ("consoleTabsComeBackWithTheirNames", test_consoleTabs),
            ("onlyShellTabsAreRecorded", test_onlyShellTabsRecorded),
            ("consoleTabsSurviveTheAutoOpenedShell", test_consoleTabsSurviveTheAutoOpenedShell),
            ("aConsoleTheCaptainWorkedInIsLeftAlone", test_consoleWithRealWorkIsLeftAlone),
            ("toolTabsComeBackByKindAndName", test_toolTabs),
            ("hostPagesComeBackWithoutConnecting", test_lazyHostPages),
            ("captureReadsWhateverIsActuallyOpen", test_capture),
            ("anEmptyOrAbsentStateChangesNothing", test_emptyState),
            ("aRestoredHostPageKnowsAboutItsActiveIncident", test_incidentReattachment),
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
            ? "SessionRestoreSelfTest: all \(cases.count) cases passed"
            : "SessionRestoreSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Encoding

    private static func test_roundTrip() -> String? {
        let state = SessionRestoreState(
            destination: RailDestination.vault.rawValue,
            activeHostID: nil,
            openHostIDs: ["a", "b"],
            consoleTabs: [.init(name: "build", hasUserChosenName: true),
                          .init(name: "Shell 2", hasUserChosenName: false)],
            toolTabs: [.init(kind: ToolKind.diff.rawValue, name: "Diff")]
        )
        guard let data = try? JSONEncoder().encode(state),
              let decoded = try? JSONDecoder().decode(SessionRestoreState.self, from: data) else {
            return "the state did not round trip through JSON"
        }
        guard decoded == state else { return "the decoded state differed: \(decoded)" }

        // A destination's raw value is its case name, and it has to keep
        // resolving back - a renamed case is a deliberate act, a silently
        // wrong one is not.
        guard RailDestination(rawValue: decoded.destination ?? "") == .vault else {
            return "the destination did not resolve back to its case"
        }
        return nil
    }

    private static func test_forwardCompatibleDecode() -> String? {
        // Exactly what an older build would have written: no `toolTabs`, no
        // `openHostIDs`, and a console tab with no `hasUserChosenName`.
        let legacy = """
        {"destination":"console","consoleTabs":[{"name":"Shell"}]}
        """
        guard let decoded = try? JSONDecoder().decode(SessionRestoreState.self,
                                                      from: Data(legacy.utf8)) else {
            return "a state written by an older build failed to decode entirely"
        }
        guard decoded.destination == "console" else { return "the destination was lost" }
        guard decoded.consoleTabs.count == 1, decoded.consoleTabs[0].name == "Shell" else {
            return "the console tab was lost: \(decoded.consoleTabs)"
        }
        guard decoded.consoleTabs[0].hasUserChosenName == false else {
            return "a missing hasUserChosenName should default to false"
        }
        guard decoded.toolTabs.isEmpty, decoded.openHostIDs.isEmpty else {
            return "missing arrays should default to empty, got \(decoded)"
        }

        // Total garbage is not a state - it must not decode into a partially
        // populated one that then clears real tabs.
        guard (try? JSONDecoder().decode(SessionRestoreState.self, from: Data("[]".utf8))) == nil else {
            return "a non-object decoded as a state"
        }
        return nil
    }

    // MARK: Plan

    private static func test_plan() -> String? {
        let state = SessionRestoreState(
            destination: nil, activeHostID: "showing",
            openHostIDs: ["showing", "still-there", "deleted-since"]
        )
        let plan = SessionRestorePlan.hosts(from: state, knownHostIDs: ["showing", "still-there"])
        guard plan.showing == "showing" else { return "the showing host was not picked, got \(String(describing: plan.showing))" }
        guard plan.background == ["still-there"] else {
            return "background should be the surviving non-showing hosts, got \(plan.background)"
        }

        // A host deleted between runs, including the showing one, is dropped
        // rather than surfacing an error the captain cannot act on.
        let orphaned = SessionRestorePlan.hosts(
            from: SessionRestoreState(activeHostID: "gone", openHostIDs: ["gone"]),
            knownHostIDs: ["other"]
        )
        guard orphaned.showing == nil, orphaned.background.isEmpty else {
            return "a deleted host should not be restored, got \(orphaned)"
        }

        // No showing host at all: everything is background.
        let noneShowing = SessionRestorePlan.hosts(
            from: SessionRestoreState(openHostIDs: ["a", "b"]),
            knownHostIDs: ["a", "b"]
        )
        guard noneShowing.showing == nil, noneShowing.background == ["a", "b"] else {
            return "with no showing host every page should be background, got \(noneShowing)"
        }
        return nil
    }

    // MARK: Console tabs

    private static func test_consoleTabs() -> String? {
        let (window, console) = makeConsole()
        defer { window.contentViewController = nil }

        // Audit 2 §4.1. The precondition this case exists to run against:
        // production always reaches `restoreConsoleTabs` with the console's
        // own auto-opened Shell already in place. Asserted rather than
        // assumed - if this ever goes back to zero, every assertion below
        // passes for the wrong reason and the real bug is invisible again.
        guard console.tabs.count == 1, !console.tabs[0].hasUserChosenName else {
            return "harness problem: the console should hold exactly its own auto-opened Shell "
                 + "before restore, got \(console.tabs.map(\.name))"
        }

        console.restoreConsoleTabs([
            .init(name: "deploys", hasUserChosenName: true),
            .init(name: "Shell 2", hasUserChosenName: false),
            .init(name: "logs", hasUserChosenName: true),
            .init(name: "Shell 5", hasUserChosenName: false),
        ])
        // Four saved tabs means four tabs - the auto-opened Shell is
        // *reused* as the first one, never left as a fifth alongside them.
        guard console.tabs.count == 4 else {
            return "expected 4 restored tabs, got \(console.tabs.count): \(console.tabs.map(\.name))"
        }

        // A name the captain typed comes back verbatim.
        guard console.tabs[0].name == "deploys", console.tabs[0].hasUserChosenName else {
            return "a user-chosen name was not restored: \(console.tabs[0].name)"
        }
        guard console.tabs[2].name == "logs", console.tabs[2].hasUserChosenName else {
            return "the third tab's user-chosen name was lost: \(console.tabs[2].name)"
        }

        // A name this app derived is re-derived rather than frozen: the two
        // derived tabs come back as the first two *free* numbers ("Shell",
        // "Shell 2"), NOT as the stale "Shell 2"/"Shell 5" a previous run
        // happened to give them. That is what keeps the numbering honest as
        // tabs come and go, and is `TabNaming.nextName`'s own contract.
        guard !console.tabs[1].hasUserChosenName, !console.tabs[3].hasUserChosenName else {
            return "a derived name came back marked user-chosen"
        }
        guard console.tabs[1].name == "Shell" else {
            return "the first derived tab should take the bare name, got \(console.tabs[1].name)"
        }
        guard console.tabs[3].name == "Shell 2" else {
            return "the second derived tab should take the next free number, got \(console.tabs[3].name)"
        }

        // The first restored tab is the selected one.
        guard console.currentTab === console.tabs.first else { return "the first restored tab was not selected" }

        // Restoring again is a no-op - this runs at launch, and appending to
        // an already-populated console would be a surprise, not a restore.
        console.restoreConsoleTabs([.init(name: "extra", hasUserChosenName: true)])
        guard console.tabs.count == 4 else { return "a second restore appended to an already-populated console" }
        return nil
    }

    private static func test_onlyShellTabsRecorded() -> String? {
        let (window, console) = makeConsole()
        defer { window.contentViewController = nil }

        console.newShellTab()
        console.newShellTab()
        // A one-shot provisioning tab must not come back - a finished
        // `rebuild.sh` is not something to re-run at launch, the same
        // distinction `processTerminated` already draws.
        let oneShot = console.addTab(launch: .shell(executable: "/bin/echo", args: ["hi"], cwd: "/"),
                                     name: "Setup", select: false, isOneShotCommand: true)
        guard oneShot.isOneShotCommand else { return "harness problem: the one-shot flag did not stick" }

        // Three, not two: the console's own auto-opened Shell (audit 2 §4.1's
        // harness alignment) is a perfectly ordinary interactive shell tab
        // and is recorded like any other. That is what production has always
        // saved, and what `restoreConsoleTabs` now reuses rather than
        // duplicating on the way back in.
        let recorded = console.restorableConsoleTabs()
        guard recorded.count == 3 else {
            return "expected the 3 real shell tabs, got \(recorded.count): \(recorded.map(\.name))"
        }
        guard !recorded.contains(where: { $0.name == "Setup" }) else {
            return "a one-shot command tab was recorded for restoration"
        }
        return nil
    }

    /// Audit 2 §4.1, end to end through the *real* launch path.
    ///
    /// `test_consoleTabs` drives `restoreConsoleTabs` directly; this one goes
    /// through `AppShellController.restoreTabs(from:)` - what
    /// `restoreSessionIfNeeded` actually calls - against a shell whose
    /// console auto-opens its Shell exactly like production's does. That
    /// combination is the bug: the console is an eager mount, its `loadView`
    /// had already added the Shell, and the old `tabs.isEmpty` guard turned
    /// the whole restore into a no-op on every real launch while the saved
    /// names went to the floor.
    private static func test_consoleTabsSurviveTheAutoOpenedShell() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            defer { window.contentViewController = nil }

            // The precondition, asserted: this is the state a real launch is
            // in by the time restoration runs.
            guard shell.debugConsole.tabs.count == 1 else {
                return "harness problem: the shared console should have auto-opened exactly one Shell, "
                     + "got \(shell.debugConsole.tabs.map(\.name))"
            }

            shell.restoreTabs(from: SessionRestoreState(consoleTabs: [
                .init(name: "prod tail", hasUserChosenName: true),
                .init(name: "Shell 3", hasUserChosenName: false),
            ]))

            let names = shell.debugConsole.tabs.map(\.name)
            guard names.count == 2 else {
                return "the saved shared-console tabs were dropped on the launch path (the §4.1 bug): got \(names)"
            }
            guard names[0] == "prod tail" else {
                return "the first saved tab's own name did not come back: \(names)"
            }
            guard shell.debugConsole.tabs[0].hasUserChosenName else {
                return "a name the captain typed came back unmarked, so the next launch would re-derive it"
            }
            // The derived one is re-derived against the tabs that now exist,
            // not frozen at whatever number a previous run gave it.
            guard names[1] == "Shell" else {
                return "the derived tab should take the first free number, got \(names)"
            }
            return nil
        }
    }

    /// The other half of §4.1's guard: reconciling against the *one pristine
    /// auto-opened Shell* must not become "append to whatever is open".
    ///
    /// A console the captain has genuinely worked in is left completely
    /// alone - which is the property the original `tabs.isEmpty` guard was
    /// protecting, and the reason the fix is a narrow match rather than a
    /// dropped guard.
    private static func test_consoleWithRealWorkIsLeftAlone() -> String? {
        // Two tabs: more than the single auto-opened Shell.
        do {
            let (window, console) = makeConsole()
            defer { window.contentViewController = nil }
            console.newShellTab()
            let before = console.tabs.map(\.name)
            console.restoreConsoleTabs([.init(name: "restored", hasUserChosenName: true)])
            guard console.tabs.map(\.name) == before else {
                return "restore reached into a console with two open tabs: \(before) -> \(console.tabs.map(\.name))"
            }
        }
        // One tab, but renamed by the captain - not pristine, so not ours to
        // reuse.
        do {
            let (window, console) = makeConsole()
            defer { window.contentViewController = nil }
            guard let only = console.tabs.first else { return "harness problem: no auto-opened tab" }
            console.renameTab(id: only.id, to: "my work")
            console.restoreConsoleTabs([.init(name: "restored", hasUserChosenName: true)])
            guard console.tabs.count == 1, console.tabs[0].name == "my work" else {
                return "restore overwrote a tab the captain had renamed: \(console.tabs.map(\.name))"
            }
        }
        // One tab, but a one-shot provisioning command - also not the
        // interactive Shell `loadView` opens, so also not ours to reuse.
        //
        // Built on a `isFirstmateConsole: false` console deliberately: the
        // shared one auto-opens a Shell *and* reopens one whenever its last
        // tab closes (so the window is never empty), which makes a lone
        // one-shot tab impossible to arrange there. What is under test is
        // `soleAutoOpenedShellTab`'s `!isOneShotCommand` condition, and this
        // is the shape that isolates it.
        do {
            let console = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                            isFirstmateConsole: false)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = console
            console.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil }

            console.addTab(launch: .shell(executable: "/bin/echo", args: ["hi"], cwd: "/"),
                           name: "Setup", select: false, isOneShotCommand: true)
            guard console.tabs.count == 1, console.tabs[0].isOneShotCommand else {
                return "harness problem: expected a lone one-shot tab, got \(console.tabs.map(\.name))"
            }
            console.restoreConsoleTabs([.init(name: "restored", hasUserChosenName: true)])
            guard console.tabs.count == 1, console.tabs[0].name == "Setup" else {
                return "restore reused a one-shot provisioning tab: \(console.tabs.map(\.name))"
            }
        }
        return nil
    }

    // MARK: Tool tabs

    private static func test_toolTabs() -> String? {
        let (window, tools) = makeTools()
        defer { window.contentViewController = nil }

        tools.restoreToolTabs([
            .init(kind: ToolKind.diff.rawValue, name: "Manifest diff"),
            .init(kind: "a-tool-that-no-longer-exists", name: "Ghost"),
            .init(kind: ToolKind.json.rawValue, name: "JSON"),
        ])
        let recorded = tools.restorableToolTabs()
        guard recorded.count == 2 else {
            return "an unrecognised kind should be dropped, got \(recorded.count): \(recorded)"
        }
        guard recorded[0].kind == ToolKind.diff.rawValue, recorded[0].name == "Manifest diff" else {
            return "the first tool tab did not come back: \(recorded[0])"
        }
        guard recorded[1].kind == ToolKind.json.rawValue else {
            return "the second tool tab came back as the wrong kind: \(recorded[1])"
        }
        guard !recorded.contains(where: { $0.name == "Ghost" }) else {
            return "an unrecognised kind resurrected as some other tool"
        }
        return nil
    }

    // MARK: Host pages - the safety property

    private static func test_lazyHostPages() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            defer { window.contentViewController = nil }

            let host = Host(label: "Bastion", address: "198.51.100.7")
            // The real connect path, with `navigate: false` - exactly what
            // restoration does for a host that was open but not showing.
            shell.connectHost(host, args: host.sshArguments(allHosts: [host]), navigate: false)

            guard let console = shell.debugHostConsole(id: host.id) else {
                return "the host page was not created"
            }
            guard console.tabs.count == 1 else {
                return "expected exactly one ssh tab, got \(console.tabs.count)"
            }
            // THE assertion. `addTab` starts a process only `if hasAppeared`,
            // and a restored page is mounted hidden - so no `ssh` runs until
            // the captain opens it. Without this, restoring six host pages
            // would open six SSH connections at launch.
            guard console.tabs[0].started == false else {
                return "a restored host page started its ssh at launch - restoration must stay lazy"
            }
            guard console.tabs[0].terminal.process.running == false else {
                return "a restored host page has a live child process"
            }

            // It is nonetheless a real page the captain can open, and the
            // shell counts it as open for the next capture.
            guard shell.isHostConnected(host) else { return "the restored page is not registered as open" }
            guard shell.captureSessionState().openHostIDs == [host.id.uuidString] else {
                return "the restored page was not captured as open"
            }
            return nil
        }
    }

    // MARK: Capture

    private static func test_capture() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            defer { window.contentViewController = nil }

            shell.show(.vault)
            let captured = shell.captureSessionState()
            guard captured.destination == RailDestination.vault.rawValue else {
                return "capture did not record the showing destination, got \(String(describing: captured.destination))"
            }
            guard captured.activeHostID == nil else { return "no host page was showing" }

            // A different destination is picked up on the next capture - i.e.
            // capture reads live state rather than a stale cache.
            shell.show(.dictation)
            guard shell.captureSessionState().destination == RailDestination.dictation.rawValue else {
                return "capture did not follow a second navigation"
            }
            return nil
        }
    }

    private static func test_emptyState() -> String? {
        guard SessionRestoreState().isEmpty else { return "a blank state should report empty" }
        guard !SessionRestoreState(destination: "console").isEmpty else {
            return "a state naming a destination is not empty"
        }
        guard !SessionRestoreState(consoleTabs: [.init(name: "Shell", hasUserChosenName: false)]).isEmpty else {
            return "a state carrying tabs is not empty"
        }

        // An empty restore must not disturb a console the app already opened
        // for itself - which, since audit 2 §4.1's harness alignment, is
        // exactly the auto-opened Shell this console starts with, no extra
        // tab needed to set the condition up.
        let (window, console) = makeConsole()
        defer { window.contentViewController = nil }
        let opened = console.tabs.map(\.name)
        console.restoreConsoleTabs([])
        guard console.tabs.map(\.name) == opened else {
            return "an empty restore changed the open tabs: \(opened) -> \(console.tabs.map(\.name))"
        }
        return nil
    }

    // MARK: Incidents (F2's stated reason for existing)

    /// F8's own entry says an active incident is not re-attached to its host
    /// page after a relaunch, and that "F2 is the only thing that will" fix
    /// it. Audit §6.2 then built the announcement half
    /// (`ConsoleController.resumeActiveIncidentIfNeeded`, fired from
    /// `viewDidAppear`) and stated its remaining limit in as many words: "the
    /// app still will not *reopen* the host page on its own."
    ///
    /// This is the join. Restoring the page is what supplies the missing
    /// half, and nothing new sits between them - so what is asserted here is
    /// that the two genuinely meet: a restored page carries the
    /// `hostIdentity` the resume hook needs, and already resolves the real
    /// persisted incident through it.
    ///
    /// Deliberately stops short of calling `viewDidAppear`. That is what the
    /// announcement itself needs, and on a host page it would start a real
    /// `ssh` - `IncidentResumeSelfTest` already drives that hook directly, on
    /// a console with no ssh tab, which is the safe place for it.
    private static func test_incidentReattachment() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            defer { window.contentViewController = nil }

            let host = Host(label: "Prod Bastion", address: "198.51.100.9")
            shell.connectHost(host, args: host.sshArguments(allHosts: [host]), navigate: false)
            guard let console = shell.debugHostConsole(id: host.id) else {
                return "the host page was not restored"
            }

            // `connectHost` is what sets this, and `activeIncident()` is
            // useless without it.
            guard console.hostIdentity?.id == host.id.uuidString else {
                return "a restored host page did not carry its host identity"
            }

            // A real incident, written by the real store the page reads.
            let store = console.incidentStore
            guard case .success(let started) = store.start(title: "Latency spike",
                                                           hostID: host.id.uuidString,
                                                           hostLabel: host.label) else {
                return "could not start a real incident"
            }

            guard console.activeIncident()?.id == started.id else {
                return "the restored page did not resolve its own active incident, got \(String(describing: console.activeIncident()?.id))"
            }
            // And the record genuinely outlived any in-memory flag: a fresh
            // store over the same directory reports the same incident, which
            // is what makes this survive a relaunch at all.
            guard IncidentStore().activeIncident(hostID: host.id.uuidString)?.id == started.id else {
                return "the incident was not persisted where a relaunch would find it"
            }
            return nil
        }
    }

    // MARK: Harness

    /// **`isFirstmateConsole: true` - the shape production actually has**
    /// (audit 2 §4.1). This harness used to pass `false`, which skips
    /// `loadView`'s own `openFirstmateHost(focus: false)`, so every console
    /// test here ran against an *empty* tab list that no real launch ever
    /// sees. That is what let `restoreConsoleTabs`' `tabs.isEmpty` guard be
    /// dead code in production while this suite reported PASS. The shared
    /// Firstmate console is an eager mount whose auto-opened Shell is
    /// therefore always present by restore time; every case below now starts
    /// from that.
    ///
    /// This still forks no shell: the window is deliberately never ordered
    /// in, so `viewDidAppear` does not fire and `addTab`'s `if hasAppeared`
    /// guard keeps every tab process-free.
    private static func makeConsole() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                           isFirstmateConsole: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func makeTools() -> (window: NSWindow, controller: ToolsController) {
        let controller = ToolsController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// Mirrors `DestinationMountingSelfTest.makeMountedShell`.
    private static func makeShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            // Production's own value (audit 2 §4.1) - see `makeConsole`'s note.
            // `test_consoleTabsSurviveTheAutoOpenedShell` drives the real
            // `AppShellController.restoreTabs(from:)` through this, and that
            // is only a reproduction of the launch path if this console
            // auto-opens its Shell exactly like the real one does.
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: true),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                                         dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: ShiftStore(),
            dictationStore: DictationStore(), commandLibraryStore: CommandLibraryStore(),
            scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        return (window, shell)
    }

    /// Every store this test touches reads and writes disposable files -
    /// never the captain's real saved hosts/keys/snippets/tasks. Same shape
    /// as `DestinationMountingSelfTest.withScratchEnv`.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-session-restore-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_DIR": dir.appendingPathComponent("docs").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
            "FM_LOG_ANALYZER_DIR": dir.appendingPathComponent("loganalyzer").path,
            "FM_INCIDENTS_DIR": dir.appendingPathComponent("incidents").path,
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
        return body()
    }
}

#endif
