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
                      checkTheLockSwitchNeedsAPassword, checkHomeSpeaksForTheVisibleModules,
                      checkAChordReachesAModule, checkTheTabChords, checkTheSidebarShowsKeyboardFocus,
                      checkTheSidebarIsWiderAndRemembered, checkQuickConnectIsOnEveryModule,
                      checkTheToolbarTakesThePalette] {
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

    // MARK: R2-UX-03 - chords

    /// ⌘3 through a real key event, the way the menu bar resolves it.
    private static func checkAChordReachesAModule(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.hiddenModules = []
        shell.show(.homeCanvas)
        settle(shell)
        let menu = NSMenu(title: "Go")
        WorkspaceGoMenu.populate(menu, target: shell)
        func press(_ digit: Int) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "\(digit)", charactersIgnoringModifiers: "\(digit)",
                                               isARepeat: false, keyCode: 0) else { return false }
            let handled = menu.performKeyEquivalent(with: event)
            settle(shell)
            return handled
        }
        check(press(3) && shell.currentModule == .crew, "\u{2318}3 opened \(shell.currentModule.title), want Crew", &ok)
        check(press(2) && shell.currentModule == .tasks, "\u{2318}2 opened \(shell.currentModule.title), want Tasks", &ok)
        // The sidebar's tooltip says it.
        let tasks = shell.sidebar.debugCell(for: .module(.tasks))
        check(tasks?.toolTip == "Tasks (\u{2318}2)", "the Tasks row's tooltip is \(tasks?.toolTip ?? "nothing")", &ok)
        // A hidden module gives its number away.
        AppSettings.shared.setProfile(.personal)
        settle(shell)
        WorkspaceGoMenu.populate(menu, target: shell, hidden: AppSettings.shared.hiddenModules)
        check(press(3) && shell.currentModule == .knowledge, "with Crew hidden \u{2318}3 opened \(shell.currentModule.title), want Knowledge", &ok)
        AppSettings.shared.hiddenModules = []
        settle(shell)
        shell.show(.homeCanvas)
        settle(shell)
    }

    private static func checkTheTabChords(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        shell.show(.notebook)
        settle(shell)
        shell.selectNextModuleTab(nil)
        settle(shell)
        check(shell.debugCurrentTab?.name == "Runbooks", "\u{2318}\u{21E7}] on Notebook showed \(shell.debugCurrentTab?.name ?? "nothing")", &ok)
        shell.selectPreviousModuleTab(nil)
        shell.selectPreviousModuleTab(nil)
        settle(shell)
        check(shell.debugCurrentTab?.name == "Reading list",
              "\u{2318}\u{21E7}[ from Notebook did not wrap to the last tab (\(shell.debugCurrentTab?.name ?? "nothing"))", &ok)
        // A page's own tab, through the page: Tasks' board to its list.
        shell.show(.shift)
        settle(shell)
        let before = shell.debugCurrentTab?.name
        shell.selectNextModuleTab(nil)
        settle(shell)
        check(before == "Board" && shell.debugCurrentTab?.name == "List",
              "\u{2318}\u{21E7}] on Tasks went from \(before ?? "nothing") to \(shell.debugCurrentTab?.name ?? "nothing")", &ok)
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: R2-A11Y-01 - the sidebar's keyboard focus

    private static func checkTheSidebarShowsKeyboardFocus(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        defer { HelmFocusVisibility.overrideForTests = nil }
        shell.show(.shift)
        settle(shell)
        let outline = shell.sidebar.outlineView
        guard let row = shell.sidebar.debugRowView(for: .module(.tasks)) else {
            fail("the Tasks row is not on screen, so the focus check measures nothing", &ok)
            return
        }
        func sample() -> NSColor? {
            row.layoutSubtreeIfNeeded()
            guard let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return nil }
            row.cacheDisplay(in: row.bounds, to: rep)
            let fill = row.debugFill.frame
            let scale = CGFloat(rep.pixelsWide) / row.bounds.width
            // One point inside the wash's leading edge, half way down.
            let x = Int((fill.minX + 1) * scale)
            let yPoints = row.isFlipped ? fill.midY : row.bounds.height - fill.midY
            return rep.colorAt(x: x, y: Int(yPoints * scale))
        }
        window.makeFirstResponder(nil)
        settle(shell)
        let resting = sample()
        // A mouse click puts the keyboard in the list without a ring.
        HelmFocusVisibility.overrideForTests = false
        window.makeFirstResponder(outline)
        settle(shell)
        check(!row.showsFocusRing, "a click into the sidebar lit the keyboard ring", &ok)
        window.makeFirstResponder(nil)
        // A key does.
        HelmFocusVisibility.overrideForTests = true
        window.makeFirstResponder(outline)
        settle(shell)
        check(row.showsFocusRing && row.debugFill.layer?.borderWidth == WorkspaceSidebarRowView.focusRingWidth,
              "with the keyboard in the sidebar the lit row shows no focus ring", &ok)
        let focused = sample()
        if let resting, let focused {
            let a = resting.usingColorSpace(.deviceRGB) ?? resting, b = focused.usingColorSpace(.deviceRGB) ?? focused
            let delta = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
            check(delta > 0.1, "the lit row's edge reads the same with and without keyboard focus (delta \(delta))", &ok)
        } else {
            fail("the lit row could not be sampled", &ok)
        }
        // Another row lit does not take the ring with it, and leaving the
        // list takes it away.
        if let other = shell.sidebar.debugRowView(for: .module(.home)) {
            check(!other.showsFocusRing, "an unlit row shows the focus ring", &ok)
        }
        window.makeFirstResponder(nil)
        settle(shell)
        check(!row.showsFocusRing, "the ring stayed after the keyboard left the sidebar", &ok)
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: U-03 - a wider sidebar, remembered, that narrows before it steps aside

    private static func checkTheSidebarIsWiderAndRemembered(_ shell: MainSplitShellController,
                                                           _ window: NSWindow, _ ok: inout Bool) {
        let height = window.frame.height
        resize(window, width: 1512, shell)
        check(MainSplitShellController.sidebarWidth == 264 && MainSplitShellController.sidebarMaximum == 360,
              "the sidebar opens at \(MainSplitShellController.sidebarWidth) and drags to \(MainSplitShellController.sidebarMaximum)", &ok)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - 264) < 0.5,
              "at 1512 the sidebar is \(shell.debugSidebarWidth)pt, want 264", &ok)
        let inset = (shell.debugSidebarPane?.frame.width ?? 272) - shell.debugSidebarWidth
        // Short of room for 264 but not for 236: it narrows, and the window
        // keeps its width - the sidebar shows at every width it used to.
        let narrow = (MainSplitShellController.contentMinimum + 236 + inset + 12).rounded()
        resize(window, width: narrow, shell)
        check(abs(window.frame.width - narrow) < 0.5, "at \(Int(narrow))pt the window grew to \(Int(window.frame.width))pt", &ok)
        check(!shell.debugSidebarIsCollapsed && shell.debugSidebarWidth < 263 && shell.debugSidebarWidth >= 236,
              "at \(Int(narrow))pt the sidebar is \(shell.debugSidebarIsCollapsed ? "collapsed" : "\(shell.debugSidebarWidth)pt"), want it narrowed between 236 and 264", &ok)
        // Below the old threshold it steps aside, as it always did.
        resize(window, width: 1100, shell)
        check(shell.debugSidebarIsCollapsed, "at 1100 the sidebar is still showing", &ok)
        // And it comes back out at its own width.
        resize(window, width: 1512, shell)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - 264) < 0.5,
              "back at 1512 the sidebar is \(shell.debugSidebarWidth)pt, want 264", &ok)
        resize(window, width: narrow, shell)
        resize(window, width: 1512, shell)
        check(abs(shell.debugSidebarWidth - 264) < 0.5,
              "a narrowed sidebar did not grow back to 264 with the window (\(shell.debugSidebarWidth)pt)", &ok)
        var frame = window.frame
        frame.size.height = height
        window.setFrame(frame, display: true)

        // The width the captain drags to is kept, inside the range.
        ReviewTwoUXModelSelfTest.withScratchSettings("sidebarwidth") { settings in
            check(MainSplitShellController.rememberedSidebarWidth(settings) == 264, "with nothing stored the sidebar does not open at 264", &ok)
            settings.sidebarWidth = 300
            check(MainSplitShellController.rememberedSidebarWidth(settings) == 300, "a stored 300pt sidebar does not open at 300", &ok)
            settings.sidebarWidth = 900
            check(MainSplitShellController.rememberedSidebarWidth(settings) == 360, "a stored 900pt sidebar is not held to 360", &ok)
            settings.sidebarWidth = 20
            check(MainSplitShellController.rememberedSidebarWidth(settings) == 200, "a stored 20pt sidebar is not held to 200", &ok)
        }
        if let source = ReviewTwoUXModelSelfTest.source("MainSplitShellController.swift") {
            check(source.contains("AppSettings.shared.sidebarWidth = self.sidebarThickness")
                    && source.contains("private var sidebarThickness: CGFloat = MainSplitShellController.rememberedSidebarWidth()"),
                  "a divider drag no longer stores the sidebar's width, or the shell no longer opens at it", &ok)
        }
    }

    // MARK: U-02 - Quick Connect on every module

    private static func checkQuickConnectIsOnEveryModule(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.hiddenModules = []
        resize(window, width: 1512, shell)
        let ids = WorkspaceToolbar.ItemID.quickConnect
        for module in WorkspaceModule.allCases {
            shell.debugOpenModule(module)
            settle(shell)
            let toolbar = shell.toolbar.debugItemIdentifiers
            let positions = ids.compactMap { toolbar.firstIndex(of: $0) }
            check(positions.count == 2 && positions[1] == positions[0] + 1
                    && positions[1] + 2 < toolbar.count && toolbar[positions[1] + 1] == .space
                    && toolbar[positions[1] + 2] == WorkspaceToolbar.ItemID.theme,
                  "\(module.title)'s toolbar has no Quick Connect group before the trailing cluster: \(toolbar.map(\.rawValue))", &ok)
            check(!toolbar.contains(NSToolbarItem.Identifier("workspace.quickConnect.caption")),
                  "\(module.title)'s toolbar still carries Quick Connect's caption", &ok)
        }
        // Both icons do what they did, from any module.
        shell.show(.notebook)
        settle(shell)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectHosts), "Quick Connect's Hosts icon has no action on Notebook", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .hosts, "the Hosts icon on Notebook opened \(String(describing: shell.debugCurrentDestination))", &ok)
        shell.show(.notebook)
        settle(shell)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectConsole), "Quick Connect's Console icon has no action on Notebook", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .console, "the Console icon on Notebook opened \(String(describing: shell.debugCurrentDestination))", &ok)
        // A profile that hides the module an icon opens leaves that icon out.
        AppSettings.shared.setProfile(.personal)
        settle(shell)
        shell.show(.notebook)
        settle(shell)
        check(!shell.toolbar.debugItemIdentifiers.contains { ids.contains($0) || $0 == .space },
              "a Personal toolbar still offers Quick Connect to modules it hides: \(shell.toolbar.debugItemIdentifiers.map(\.rawValue))", &ok)
        AppSettings.shared.hiddenModules = [.console]
        settle(shell)
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.quickConnectHosts)
                && !shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.quickConnectConsole),
              "with only Console hidden Quick Connect shows \(shell.toolbar.debugItemIdentifiers.map(\.rawValue))", &ok)
        AppSettings.shared.hiddenModules = []
        settle(shell)
        // At 1100 on the most crowded module the icons still do something:
        // either they are on the toolbar, or in its overflow menu, which
        // lists an image item by its label and runs its action.
        resize(window, width: 1100, shell)
        shell.show(.notebook)
        settle(shell)
        for id in ids {
            let item = window.toolbar?.items.first { $0.itemIdentifier == id }
            check(item?.action != nil && item?.label.hasPrefix("Quick Connect") == true,
                  "at 1100 on Notebook \(id.rawValue) has no working overflow form", &ok)
        }
        resize(window, width: 1512, shell)
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: U-01 - the toolbar and title bar take the palette's ground

    /// A pixel of the toolbar band where no item is drawn, against the
    /// palette's ground, in every palette - the render check the captain's
    /// screenshot asked for. Compared in the bitmap's own colour space
    /// (AGENTS.md's probe rule): the expected colour is converted into it,
    /// and the sample is read raw.
    private static func checkTheToolbarTakesThePalette(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        resize(window, width: 1512, shell)
        shell.show(.homeCanvas)
        settle(shell)
        check(window.titlebarAppearsTransparent, "the title bar is opaque, so macOS draws its own material under the toolbar", &ok)
        var worst: (theme: String, delta: CGFloat) = ("", 0)
        for theme in HelmTheme.allThemes {
            ThemeManager.shared.setTheme(theme)
            settle(shell)
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
                fail("the window could not be rendered", &ok)
                return
            }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            // Half way along the content column, half way down the toolbar:
            // Home's toolbar has nothing between its crumb and its trailing
            // cluster there, only flexible space.
            let pane = shell.debugContentPane.convert(shell.debugContentPane.bounds, to: nil)
            let barHeight = frameView.bounds.height - window.contentLayoutRect.maxY
            let point = NSPoint(x: pane.midX - 120, y: frameView.bounds.height - barHeight / 2)
            let scale = CGFloat(rep.pixelsWide) / frameView.bounds.width
            let x = Int(point.x * scale)
            let y = Int((frameView.bounds.height - point.y) * scale)
            guard let sample = rep.colorAt(x: x, y: y),
                  let expected = HelmTheme.nsColor(theme.backgroundHex).usingColorSpace(rep.colorSpace) else {
                fail("the toolbar band could not be sampled in \(theme.id)", &ok)
                continue
            }
            let delta = max(abs(sample.redComponent - expected.redComponent),
                            abs(sample.greenComponent - expected.greenComponent),
                            abs(sample.blueComponent - expected.blueComponent))
            if delta > worst.delta { worst = (theme.id, delta) }
            check(delta < 0.012,
                  "in \(theme.id) the toolbar band is \(sample) against the palette's ground \(expected) (delta \(delta))", &ok)
            let window3 = HelmContrast.components(window.backgroundColor)
            let ground3 = HelmContrast.components(HelmTheme.nsColor(theme.backgroundHex))
            check(abs(window3.0 - ground3.0) < 0.01 && abs(window3.1 - ground3.1) < 0.01 && abs(window3.2 - ground3.2) < 0.01,
                  "in \(theme.id) the window's own background is not the palette's ground", &ok)
        }
        print("  ok   the toolbar band matched the palette's ground in \(HelmTheme.allThemes.count) palettes, worst \(worst.theme) at \(worst.delta)")
    }
}

#endif
