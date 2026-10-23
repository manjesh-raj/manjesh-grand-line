// Grand Line - native macOS app.
//
// The second full review's UX findings (R2-UX-01 to R2-UX-09) and the
// captain's three UI items (U-01 to U-03): the window-backed half.
//
// Everything here needs a real window - the real sidebar shell from
// `ReviewTourLab.makeOffScreenSplitShell()`, a real Settings page, real
// pixels - so it is in `NEEDS_SESSION`. The models and source guards are
// `ReviewTwoUXModelSelfTest`, which CI runs headless.
//
// It never runs `av`: the Settings lock switch's check is the page's seam.
// Every preference it changes is put back, and it seeds no store.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ReviewTwoUXSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedHidden = AppSettings.shared.hiddenModules
        defer { AppSettings.shared.hiddenModules = savedHidden }
        let savedLock = AppSettings.shared.appLockEnabled
        defer { AppSettings.shared.appLockEnabled = savedLock }
        let savedCheck = SettingsController.appPasswordCheck
        defer { SettingsController.appPasswordCheck = savedCheck }

        var allOK = true
        let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(shell)
        for check in [checkTheSidebarFollowsTheHiddenModules, checkSettingsShowsAndHidesModules,
                      checkTheLockSwitchNeedsAPassword, checkHomeSpeaksForTheVisibleModules] {
            var ok = true
            check(shell, window, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "ReviewTwoUXSelfTest: all checks passed" : "ReviewTwoUXSelfTest: FAILED")
        return allOK
    }

    // MARK: Shared

    static func settle(_ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    static func resize(_ window: NSWindow, width: CGFloat, _ shell: MainSplitShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    static func sidebarModules(_ shell: MainSplitShellController) -> [WorkspaceModule] {
        shell.sidebar.debugVisibleEntries.compactMap { entry -> WorkspaceModule? in
            if case .module(let module) = entry { return module }
            return nil
        }
    }

    /// The real Settings page, mounted in its own off-screen window.
    static func mountSettings(_ category: SettingsController.Category) -> (SettingsController, NSWindow) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review2-ux-settings-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
        let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                          snippetStore: SnippetStore(), dictationStore: DictationStore())
        let window = OffScreenProbe.window(width: 1400, height: 900)
        window.contentView = settings.view
        settings.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        settings.select(category)
        settings.view.layoutSubtreeIfNeeded()
        return (settings, window)
    }

    // MARK: R2-UX-01 (b) - the sidebar reads the hidden modules

    private static func checkTheSidebarFollowsTheHiddenModules(_ shell: MainSplitShellController,
                                                              _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.hiddenModules = []
        settle(shell)
        check(sidebarModules(shell) == WorkspaceSidebarModel.listedModules(),
              "with nothing hidden the sidebar lists \(sidebarModules(shell).map(\.rawValue))", &ok)
        let storedLayout = AppDefaults.store.data(forKey: "fm.homeCardLayout")
        defer {
            if let storedLayout { AppDefaults.store.set(storedLayout, forKey: "fm.homeCardLayout") } else {
                AppDefaults.store.removeObject(forKey: "fm.homeCardLayout")
            }
        }
        AppDefaults.store.removeObject(forKey: "fm.homeCardLayout")
        AppSettings.shared.setProfile(.personal)
        settle(shell)
        check(sidebarModules(shell) == ReviewTwoUXModelSelfTest.personalModules,
              "after choosing Personal the sidebar lists \(sidebarModules(shell).map(\.rawValue))", &ok)
        // Home's default cards follow the profile while nothing is arranged.
        check(shell.debugHomeCanvas.cardLayout == .standard(for: .personal),
              "a Personal Home still shows \(shell.debugHomeCanvas.cardLayout?.shown.map(\.rawValue) ?? [])", &ok)
        // A hidden module's page still opens from a link.
        shell.show(.kubernetes)
        settle(shell)
        check(shell.debugCurrentDestination == .kubernetes, "a hidden module's page no longer opens from a link", &ok)
        AppSettings.shared.setProfile(.operator)
        settle(shell)
        check(sidebarModules(shell) == WorkspaceSidebarModel.listedModules(),
              "after choosing Operator the sidebar lists \(sidebarModules(shell).map(\.rawValue))", &ok)
        check(shell.debugHomeCanvas.cardLayout == .standard, "an Operator Home does not show the hub's own cards", &ok)
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: R2-UX-01 (b) - Settings shows or hides any module

    private static func checkSettingsShowsAndHidesModules(_ shell: MainSplitShellController,
                                                         _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.hiddenModules = []
        let (settings, settingsWindow) = mountSettings(.appearance)
        defer { _ = settingsWindow }
        let switches = settings.debugModuleSwitches
        check(switches.map(\.module) == WorkspaceSidebarModel.listedModules().filter(\.canBeHidden),
              "Settings offers switches for \(switches.map(\.module.rawValue))", &ok)
        guard let logs = switches.first(where: { $0.module == .logs })?.toggle else {
            fail("Settings has no switch for Logs", &ok)
            return
        }
        check(logs.isOn, "Logs' switch is off with nothing hidden", &ok)
        _ = logs.accessibilityPerformPress()
        settle(shell)
        check(AppSettings.shared.hiddenModules == [.logs], "turning Logs off stored \(AppSettings.shared.hiddenModules.map(\.rawValue))", &ok)
        check(!sidebarModules(shell).contains(.logs), "turning Logs off in Settings left it in the sidebar", &ok)
        check(settings.debugProfileTabs?.selected == "custom", "an edited set does not read as Custom", &ok)
        settings.debugProfileTabs?.debugClickTab(id: WorkspaceProfile.personal.rawValue)
        settle(shell)
        check(AppSettings.shared.hiddenModules == WorkspaceProfile.personal.hiddenModules,
              "choosing Personal in Settings stored \(AppSettings.shared.hiddenModules.map(\.rawValue))", &ok)
        check(settings.debugModuleSwitches.first { $0.module == .crew }?.toggle.isOn == false,
              "choosing Personal left Crew's switch on", &ok)
        AppSettings.shared.hiddenModules = []
        settle(shell)
    }

    // MARK: R2-UX-01 (a) - the lock switch turns on only with a password

    private static func checkTheLockSwitchNeedsAPassword(_ shell: MainSplitShellController,
                                                        _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.appLockEnabled = false
        // Turning the lock off asks first; a confirmation here must never be
        // a real modal, which would hang the suite.
        var asked: [String] = []
        HelmConfirm.responderForTests = { request in asked.append(request.title); return .cancel }
        defer { HelmConfirm.responderForTests = nil }
        let (settings, settingsWindow) = mountSettings(.security)
        defer { _ = settingsWindow }
        let toggle = settings.debugAppLockSwitch
        check(!toggle.isOn, "the lock switch reads on with the lock off", &ok)
        func press(answer: VaultSource.AppPasswordAvailability) {
            SettingsController.appPasswordCheck = { answer }
            _ = toggle.accessibilityPerformPress()
            let deadline = Date().addingTimeInterval(3)
            while AppSettings.shared.appLockEnabled != true, toggle.isOn, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        press(answer: .notConfigured)
        check(!toggle.isOn && AppSettings.shared.appLockEnabled == false,
              "the lock turned on with no password saved - the next launch would be a window nobody can open", &ok)
        check(asked.isEmpty, "turning the lock on asked \(asked) - only turning it off should ask", &ok)
        press(answer: .configured)
        check(toggle.isOn && AppSettings.shared.appLockEnabled == true,
              "the lock did not turn on with the password saved", &ok)
        // Turning it off asks, and a cancel keeps it on.
        _ = toggle.accessibilityPerformPress()
        check(asked == ["Turn off the app lock?"] && toggle.isOn && AppSettings.shared.appLockEnabled == true,
              "turning the lock off did not ask, or a cancel still turned it off (asked \(asked))", &ok)
    }

    // MARK: R2-UX-01 (c) - Home speaks only for the modules in the sidebar

    private static func checkHomeSpeaksForTheVisibleModules(_ shell: MainSplitShellController,
                                                           _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.hiddenModules = []
        shell.show(.homeCanvas)
        settle(shell)
        let canvas = shell.debugHomeCanvas
        // The review's own first screen: no firstmate home, so the fleet's
        // reading is the "point Grand Line at your firstmate home" row - plus
        // the healthy services and comfortable Claude limits the seeded Home
        // closes on.
        ReviewTourLab.seedDemoHome(canvas)
        canvas.debugInputsPinned = false
        canvas.applyFleet(snapshot: FleetSnapshot(homeOk: false, captain: "", tasks: [], queuedCount: 0, doneCount: 0,
                                                  projectsCount: 0, watcher: WatcherHealth(status: "healthy")),
                          mergedPRs: [], prFetchFailure: nil)
        canvas.debugInputsPinned = true
        settle(shell)
        let operatorRows = canvas.debugSignalAttentionIDs
        // The fixture's own discriminating power: the operator's Home has a
        // fleet row or a fleet note to lose.
        guard operatorRows.contains("signal.fleet"), canvas.debugClearNotes.contains("Fleet idle") else {
            fail("the seeded Home reports nothing about the fleet, so the Personal check below is vacuous "
                 + "(rows \(operatorRows), notes \(canvas.debugClearNotes))", &ok)
            return
        }
        AppSettings.shared.setProfile(.personal)
        settle(shell)
        let personalRows = canvas.debugSignalAttentionIDs
        check(!personalRows.contains("signal.fleet") && !personalRows.contains("signal.claude")
                && !personalRows.contains("signal.checks"),
              "a Personal Home still reports \(personalRows)", &ok)
        check(!canvas.debugClearNotes.contains("Fleet idle") && !canvas.debugClearNotes.contains { $0.contains("services healthy") },
              "a Personal Home's closing notes still name the fleet or the services: \(canvas.debugClearNotes)", &ok)
        AppSettings.shared.setProfile(.operator)
        settle(shell)
        check(canvas.debugSignalAttentionIDs == operatorRows,
              "back on Operator, Home reports \(canvas.debugSignalAttentionIDs), want \(operatorRows)", &ok)
    }
}

#endif
