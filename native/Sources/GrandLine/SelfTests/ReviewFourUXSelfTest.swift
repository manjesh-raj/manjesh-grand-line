// Grand Line - native macOS app.
//
// Full review #4, section 8 (UX improvements): the fixes a check can assert
// without a window, beyond the ones that live in their page's own suite.
//
//   - R4-UX-01: the Calendar takes ⌘0 in the sidebar layout's Go menu, every
//     other digit stays where it was, and the shortcut catalog lists it.
//   - R4-UX-04: the host Test's argv (BatchMode, a 5 second connect timeout,
//     only validated fields, `--` before the destination), its refusals, its
//     reading of ssh's answers, and the session strip's key-fallback line.
//   - R4-UX-05: a Home card takes the keyboard, and Return or Space opens it.
//   - R4-UX-06: the merge confirm names the PR, its repo, branch and checks,
//     with the URL last.
//   - R4-UX-07: the Kubernetes scope wall is three steps, and the
//     Whiteboard's example diagram builds.
//   - R4-UX-08: a finished backup is a lasting report naming where it went.
//
// Elsewhere: R4-UX-02 is `CredentialVaultViewSelfTest`, R4-UX-03 is
// `NotificationBridgePanelSelfTest` and `GrandLineNotificationCenterSelfTest`,
// R4-UX-05's inspector half is `MainSplitShellSelfTest.checkTheInspector`,
// R4-UX-07's Whiteboard overlay is `WhiteboardViewSelfTest`, and R4-UX-08's
// schedule Stop is `ScheduleRunnerSelfTest`. R4-UX-09 and R4-UX-10 shipped
// with R4-UI-09 and are `MainSplitShellSelfTest.checkTasksBoardAndFilterRow`.
//
// Pure logic: no window. The menus are built without installing them, and
// every view here is laid out on its own.
//
// Run with:
//   swift build && FM_RUN_REVIEW4_UX_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ReviewFourUXSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }

        var allOK = true
        for check in [checkCalendarDigit, checkConnectionTestArguments, checkConnectionTestReadings,
                      checkKeyFallbackNotice, checkHomeCardKeyboard, checkMergeConfirmBody,
                      checkEmptyStateCopy, checkBackupReport, checkFleetStop] {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "ReviewFourUXSelfTest: all checks passed" : "ReviewFourUXSelfTest: FAILED")
        return allOK
    }

    // MARK: R4-UX-01

    private static func checkCalendarDigit(_ ok: inout Bool) {
        check(WorkspaceGoMenu.chord(for: .calendar) == 0, "R4-UX-01: the Calendar has no ⌘0", &ok)
        check(WorkspaceGoMenu.chordText(for: .calendar) == "\u{2318}0",
              "R4-UX-01: the Calendar's chord reads \(WorkspaceGoMenu.chordText(for: .calendar) ?? "nothing")", &ok)
        check(WorkspaceGoMenu.chord(for: .calendar, hidden: [.calendar]) == nil,
              "R4-UX-01: a hidden Calendar still claims ⌘0", &ok)
        // The digits the captain already knows stay put.
        check(WorkspaceGoMenu.chord(for: .home) == 1 && WorkspaceGoMenu.chord(for: .tasks) == 2
                && WorkspaceGoMenu.chord(for: .crew) == 3 && WorkspaceGoMenu.chord(for: .logs) == 9,
              "R4-UX-01: an existing digit moved", &ok)

        let menu = ReviewTwoUXModelSelfTest.mainMenu(for: .sidebar)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let zero = items(menu).filter { $0.keyEquivalent == "0" && $0.keyEquivalentModifierMask == [.command] }
        check(zero.count == 1 && zero.first?.representedObject as? String == WorkspaceModule.calendar.rawValue,
              "R4-UX-01: ⌘0 in the sidebar menu bar is \(zero.map(\.title)), want the Go menu's Calendar alone", &ok)
        let catalog = KeyboardShortcutCatalog.sections(from: menu).flatMap(\.entries)
        check(catalog.contains { $0.chord == "\u{2318}0" && $0.title == WorkspaceModule.calendar.title },
              "R4-UX-01: the shortcut sheet does not list ⌘0 for the Calendar", &ok)
    }

    // MARK: R4-UX-04

    private static func host(_ address: String = "edge-01.example.test", user: String = "ops", port: Int = 22) -> Host {
        var host = Host(label: "edge", address: address)
        host.username = user
        host.port = port
        return host
    }

    private static func checkConnectionTestArguments(_ ok: inout Bool) {
        var plain = host(port: 2222)
        // Neither of these may reach a test: forwards would bind ports a live
        // session of the same host holds, and the test needs no agent.
        plain.agentForward = true
        plain.portForwards = [PortForwardRule()]
        guard case .success(let args) = HostConnectionTest.arguments(for: plain, allHosts: []) else {
            fail("R4-UX-04: a plain host could not be tested", &ok)
            return
        }
        check(args.prefix(4) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"],
              "R4-UX-04: the test argv starts \(args.prefix(4))", &ok)
        check(args.suffix(3) == ["--", "ops@edge-01.example.test", "true"],
              "R4-UX-04: the test argv ends \(args.suffix(3))", &ok)
        check(args.contains("-p") && args.contains("2222"), "R4-UX-04: the port did not reach the test", &ok)
        check(!args.contains("-A") && !args.contains("-L"),
              "R4-UX-04: agent forwarding or a port forward reached the test: \(args)", &ok)

        // A jump host resolves through the saved hosts.
        var bastion = host("bastion.example.test", user: "jump")
        bastion.label = "bastion"
        var behind = host()
        behind.jumpVia = "bastion"
        if case .success(let jumped) = HostConnectionTest.arguments(for: behind, allHosts: [bastion, behind]) {
            check(jumped.contains("-J") && jumped.contains("jump@bastion.example.test"),
                  "R4-UX-04: the jump chain did not reach the test: \(jumped)", &ok)
        } else {
            fail("R4-UX-04: a host behind a jump host could not be tested", &ok)
        }

        // GL-08: a field starting with a dash is refused before anything runs.
        for unsafe in [host("-oProxyCommand=touch /tmp/pwned"), host(user: "-oProxyCommand=x")] {
            if case .success(let leaked) = HostConnectionTest.arguments(for: unsafe, allHosts: []) {
                fail("R4-UX-04: an unsafe host was handed to ssh as \(leaked)", &ok)
            }
        }
        var unsafeJump = host()
        unsafeJump.jumpVia = "-oProxyCommand=x"
        if case .success = HostConnectionTest.arguments(for: unsafeJump, allHosts: []) {
            fail("R4-UX-04: an unsafe jump host was tested", &ok)
        }
        // A hop that resolves from another saved host is checked at run time too.
        var dashed = Host(label: "dashed", address: "-oProxyCommand=x")
        dashed.username = ""
        var viaDashed = host()
        viaDashed.jumpVia = "dashed"
        if case .success = HostConnectionTest.arguments(for: viaDashed, allHosts: [dashed, viaDashed]) {
            fail("R4-UX-04: a jump chain through an unsafe saved host was tested", &ok)
        }
        if case .success = HostConnectionTest.arguments(for: host("  "), allHosts: []) {
            fail("R4-UX-04: a host with no address was tested", &ok)
        }

        // Through `run`: a refused host never reaches the runner.
        var ranWith: [String]?
        var outcome: HostConnectionTest.Outcome?
        HostConnectionTest.run(host("-bad"), allHosts: [], runner: { args, _ in ranWith = args }) { outcome = $0 }
        check(ranWith == nil, "R4-UX-04: a refused host reached ssh", &ok)
        if case .refused? = outcome {} else { fail("R4-UX-04: a refused host read \(String(describing: outcome))", &ok) }
    }

    private static func result(_ status: Int32, stderr: String = "",
                               outcome: SubprocessResult.Outcome = .exited) -> SubprocessResult {
        SubprocessResult(outcome: outcome, status: status, stdoutData: Data(),
                         stderrData: Data(stderr.utf8), duration: 0.1)
    }

    private static func checkConnectionTestReadings(_ ok: inout Bool) {
        let cases: [(SubprocessResult, Bool, HostConnectionTest.Outcome)] = [
            (result(0), false, .signedIn),
            (result(255, stderr: "ops@edge: Permission denied (publickey,password)."), false,
             .needsCredentials(savedKey: false)),
            (result(255, stderr: "ops@edge: Permission denied (publickey)."), true, .needsCredentials(savedKey: true)),
            (result(255, stderr: "Host key verification failed."), false, .hostKeyUnknown),
            (result(255, stderr: "ssh: Could not resolve hostname edgy: nodename nor servname provided"), false,
             .unreachable("the address does not resolve")),
            (result(255, stderr: "ssh: connect to host edge port 22: Connection refused"), false,
             .unreachable("connection refused")),
            (result(255, stderr: "ssh: connect to host edge port 22: Operation timed out"), false,
             .unreachable("no answer in 5 seconds")),
            (result(-2, outcome: .timedOut), false, .unreachable("no answer in 20 seconds")),
        ]
        for (answer, savedKey, want) in cases {
            let got = HostConnectionTest.classify(answer, savedKey: savedKey)
            check(got == want, "R4-UX-04: \"\(answer.stderr)\" read as \(got.text), want \(want.text)", &ok)
        }
        check(HostConnectionTest.Outcome.signedIn.tint == .good
                && HostConnectionTest.Outcome.hostKeyUnknown.tint == .warn
                && HostConnectionTest.Outcome.unreachable("x").tint == .critical,
              "R4-UX-04: the outcomes' tints do not say good, warn and critical", &ok)
        // The runner's answer reaches the completion.
        var outcome: HostConnectionTest.Outcome?
        HostConnectionTest.run(host(), allHosts: [], runner: { _, done in done(result(0)) }) { outcome = $0 }
        check(outcome == .signedIn, "R4-UX-04: run reported \(String(describing: outcome))", &ok)
    }

    private static func checkKeyFallbackNotice(_ ok: inout Bool) {
        let registry = HostSessionRegistry()
        let id = UUID()
        registry.register(hostID: id, label: "edge", accentHex: nil, state: .connected)
        let strip = SessionStripView()
        strip.render(registry)
        check(strip.debugNoticeText == nil, "R4-UX-04: the strip shows a notice nobody set", &ok)
        registry.setNotice(hostID: id, ConsoleController.savedKeyFallbackNotice)
        strip.render(registry)
        check(strip.debugNoticeText == "edge: Key refused, asking for a password",
              "R4-UX-04: the strip's key-fallback line reads \(strip.debugNoticeText ?? "nothing")", &ok)
        registry.setNotice(hostID: id, nil)
        strip.render(registry)
        check(strip.debugNoticeText == nil, "R4-UX-04: a cleared notice stayed on the strip", &ok)

        // The wiring a behavioural check cannot reach without a failing
        // Keychain read: the fallback branch reports, the success branch
        // clears, and the coordinator routes it to the registry.
        if let sessions = source("ConsoleController+Sessions.swift"),
           let coordinator = source("HostSessionCoordinator.swift") {
            check(sessions.contains("self.onSavedKeyFallback?(Self.savedKeyFallbackNotice)")
                    && sessions.contains("self.onSavedKeyFallback?(nil)"),
                  "R4-UX-04: connectSSH no longer reports a saved key's fallback", &ok)
            check(coordinator.contains("self?.sessions.setNotice(hostID: sessionHostID, notice)"),
                  "R4-UX-04: the host page's key fallback no longer reaches the session strip", &ok)
        }
    }

    // MARK: R4-UX-05

    private static func checkHomeCardKeyboard(_ ok: inout Bool) {
        let card = HelmModuleCard()
        check(!card.acceptsFirstResponder, "R4-UX-05: a card that opens nothing takes the keyboard", &ok)
        var opened = 0
        card.onOpen = { opened += 1 }
        check(card.acceptsFirstResponder && card.focusRingType == .exterior,
              "R4-UX-05: a Home card cannot take the keyboard, or draws no ring", &ok)
        card.debugKey(49, characters: " ")
        check(opened == 1, "R4-UX-05: Space on a Home card opened it \(opened) times", &ok)
        card.debugKey(36, characters: "\r")
        check(opened == 2, "R4-UX-05: Return on a Home card did not open it", &ok)
        card.debugKey(0, characters: "a")
        check(opened == 2, "R4-UX-05: another key opened the card", &ok)
        if let home = source("HomeCanvasController.swift") {
            check(home.contains("card.onOpen = {"), "R4-UX-05: Home's cards no longer open their module", &ok)
        }
    }

    // MARK: R4-UX-06

    private static func checkMergeConfirmBody(_ ok: inout Bool) {
        let url = "https://github.com/manjesh-raj/demo/pull/42"
        let task = FleetTask(id: "demo-task", repo: "manjesh-raj/demo", kind: "ship", pr: url, branch: "fm/demo-task")
        let open = OpenPRInfo(repo: "manjesh-raj/demo", number: 42, title: "Fix the snooze timer", url: url,
                              forge: "github", checks: "green")
        guard let pr = FleetDataSource.mergedPRs(openPRs: [open], tasks: [task]).first else {
            fail("R4-UX-06: the fixture merged into no PR", &ok)
            return
        }
        check(pr.branch == "fm/demo-task", "R4-UX-06: the task's branch did not reach the PR row", &ok)
        let lines = ReviewController.mergeConfirmBody(pr, url: url).components(separatedBy: "\n")
        check(lines == ["#42 Fix the snooze timer", "manjesh-raj/demo \u{00B7} branch fm/demo-task", "Checks passing", url],
              "R4-UX-06: the merge confirm reads \(lines)", &ok)
        check(ReviewController.checksSentence("red") == "Checks failing"
                && ReviewController.checksSentence("pending") == "Checks still running"
                && ReviewController.checksSentence("none") == "No checks reported",
              "R4-UX-06: a check state reads wrong", &ok)
        check(ReviewController.mergeConfirmBody(nil, url: url) == url,
              "R4-UX-06: a PR with no row lost its URL", &ok)
        if let review = source("ReviewController.swift") {
            check(review.contains("body: Self.mergeConfirmBody(pr, url: prURL)"),
                  "R4-UX-06: the merge confirm no longer uses the full body", &ok)
        }
    }

    // MARK: R4-UX-07

    private static func checkEmptyStateCopy(_ ok: inout Bool) {
        let steps = KubernetesController.scopeSteps.components(separatedBy: "\n")
        check(steps.count == 3 && steps.enumerated().allSatisfy { $0.element.hasPrefix("\($0.offset + 1). ") },
              "R4-UX-07: the Kubernetes scope wall is not three numbered steps: \(steps)", &ok)
        if case .success(let diagram) = DiagramDSL.build(WhiteboardController.exampleDiagram, mode: .flowchart) {
            check(!diagram.elements.isEmpty, "R4-UX-07: the Whiteboard's example diagram is empty", &ok)
        } else {
            fail("R4-UX-07: the Whiteboard's example diagram does not build", &ok)
        }
    }

    // MARK: R4-UX-08

    private static func checkBackupReport(_ ok: inout Bool) {
        let center = GrandLineNotificationCenter.shared
        let id = BackupUI.exportReportID
        defer { Feedback.clear(id: id) }
        let bundle = GrandLineBackup(hosts: [host()], snippets: [], keys: [], settings: BackupSettings())
        BackupUI.reportExported(bundle, to: "/tmp/grand-line-backup.glbackup",
                                file: URL(fileURLWithPath: "/tmp/grand-line-backup.glbackup"), in: nil)
        guard let entry = center.entries.first(where: { $0.id == id }) else {
            fail("R4-UX-08: a finished backup left nothing in the bell", &ok)
            return
        }
        check(entry.title == "Backup exported: 1 host(s), 0 snippet(s)",
              "R4-UX-08: the backup report reads \(entry.title)", &ok)
        check(entry.subtext == "Saved to /tmp/grand-line-backup.glbackup",
              "R4-UX-08: the backup report does not name the file: \(entry.subtext)", &ok)
        check(NotificationRowPresentation(for: entry).kicker == "Backup Saved",
              "R4-UX-08: the backup report reads as \(NotificationRowPresentation(for: entry).kicker)", &ok)
        // A second export replaces the entry rather than stacking another.
        BackupUI.reportExported(bundle, to: "a GitHub repo", file: nil, in: nil)
        check(center.entries.filter { $0.id == id }.count == 1,
              "R4-UX-08: a second backup stacked a second report", &ok)
    }

    /// The Fleet page's Stop: shown only while a pass is in flight, and
    /// pressing it ends the pass at once.
    private static func checkFleetStop(_ ok: inout Bool) {
        let fleet = FleetController(shiftStore: ShiftStore())
        _ = fleet.view
        check(fleet.debugStopButton.isHidden, "R4-UX-08: the Fleet page shows Stop with nothing in flight", &ok)
        fleet.debugBeginPassWithoutFetching()
        check(!fleet.debugStopButton.isHidden && !fleet.debugRefreshButton.isEnabled,
              "R4-UX-08: a pass in flight shows no Stop", &ok)
        var actionChanges = 0
        fleet.onDrillActionsChanged = { actionChanges += 1 }
        fleet.adoptSidebarLayout()
        fleet.debugBeginPassWithoutFetching()
        // Stop takes Refresh's place rather than joining it: one more item
        // pushed the breadcrumb into the overflow at Larger text and 1512pt.
        check(fleet.drillHeaderActions.count == 1 && fleet.drillHeaderActions.first === fleet.debugStopButton
                && actionChanges > 0,
              "R4-UX-08: during a pass the sidebar layout's toolbar carries \(fleet.drillHeaderActions.count) "
              + "items, want Stop alone in Refresh's place", &ok)
        fleet.debugStopButton.performClick(nil)
        check(fleet.drillHeaderActions.count == 1 && fleet.drillHeaderActions.first === fleet.debugRefreshButton,
              "R4-UX-08: Refresh did not come back after the pass ended", &ok)
        check(!fleet.debugIsLoading && fleet.debugStopButton.isHidden && fleet.debugRefreshButton.isEnabled,
              "R4-UX-08: Stop did not end the pass", &ok)
        if let source = source("FleetController.swift") {
            check(source.components(separatedBy: "self.refreshGeneration == generation").count == 3,
                  "R4-UX-08: a stopped pass can still report its results", &ok)
        }
    }

    // MARK: Helpers

    private static func source(_ file: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: the app's sources were not found - the source guards did not run")
            return nil
        }
        return try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }
}

#endif
