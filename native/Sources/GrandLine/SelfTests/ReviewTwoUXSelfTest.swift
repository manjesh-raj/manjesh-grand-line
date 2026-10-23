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
                      checkTheToolbarTakesThePalette, checkOneNamePerLevel, checkOnePrimaryActionRule,
                      checkThePageToolbarsAreTheWindowToolbar, checkEmptyStatesInvite,
                      checkSettingsHousekeeping] {
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

    // MARK: R2-UX-05 - one name per level

    private static func checkOneNamePerLevel(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for destination in [RailDestination.homeCanvas, .shift, .overview, .notebook, .health, .settings] {
            shell.show(destination)
            settle(shell)
            let module = ModuleTable.module(for: destination)
            check(shell.toolbar.debugCrumb.contains(module.title), "\(module.title)'s crumb does not name it: \(shell.toolbar.debugCrumb)", &ok)
            check(!shell.debugContentPaneHeader.debugDrawsTitle,
                  "\(module.title)'s content header still draws its name under the crumb", &ok)
        }
        // Crew: no greeting, and its live line is the module line.
        shell.show(.overview)
        settle(shell)
        let fleet = shell.workspace.overview
        check(!fleet.debugGreetingIsShown, "Crew still opens with its greeting", &ok)
        check(shell.debugHeader?.subtitle == fleet.drillHeaderSubtitle && !(fleet.drillHeaderSubtitle ?? "").isEmpty,
              "Crew's module line is \(shell.debugHeader?.subtitle ?? "nothing"), not its live line \(fleet.drillHeaderSubtitle ?? "nothing")", &ok)
        // Settings: no hero, and the category's description is the line.
        shell.show(.settings)
        settle(shell)
        if let settings = shell.debugSlotController(.settings) as? SettingsController {
            check(!settings.debugAnyHeroIsShown, "Settings still draws a hero in the sidebar layout", &ok)
            check(shell.debugHeader?.subtitle == SettingsController.Category.appearance.heroDescription
                    || SettingsController.Category.allCases.map(\.heroDescription).contains(shell.debugHeader?.subtitle ?? ""),
                  "Settings' module line is \(shell.debugHeader?.subtitle ?? "nothing"), not its category's description", &ok)
        } else {
            fail("Settings did not mount", &ok)
        }
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: R2-UX-04 and R2-UI-02 - one primary-action rule, one Refresh

    private static func checkOnePrimaryActionRule(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for destination in RailDestination.allCases {
            shell.show(destination)
            settle(shell)
            let actions = shell.toolbar.debugPageActions.compactMap { $0 as? HelmButton }
            let filled = actions.filter { $0.variant == .primary }
            check(filled.isEmpty, "\(destination.rawValue) draws a filled page action before the cluster: \(filled.map(\.title))", &ok)
            if let primary = shell.toolbar.debugPrimaryAction as? HelmButton {
                check(primary.variant == .primary, "\(destination.rawValue)'s far-right primary \(primary.title) is not filled", &ok)
            }
            // One Refresh: the shared component, labelled, in the page's
            // actions - never a bare glyph.
            for button in actions where button.accessibilityLabel() == "Refresh" || button.title == "Refresh" {
                check(button.title == "Refresh" && button.variant == .secondary,
                      "\(destination.rawValue)'s Refresh is \"\(button.title)\" (\(button.variant)), not the labelled outlined one", &ok)
            }
            // The far-right primary is after Search.
            let ids = shell.toolbar.debugItemIdentifiers
            if let primaryIndex = ids.firstIndex(of: WorkspaceToolbar.ItemID.primaryAction) {
                check(ids.firstIndex(of: WorkspaceToolbar.ItemID.search).map { $0 < primaryIndex } == true,
                      "\(destination.rawValue)'s primary is not at the far right: \(ids.map(\.rawValue))", &ok)
            }
        }
        // The pages whose verb was a filled button before the cluster, an
        // outlined one, or a button inside the page.
        let wanted: [RailDestination: String] = [
            .notebook: "New page", .readingList: "Paste link", .runbooks: "New Runbook", .stickyBoard: "New Note",
            .schedules: "+ New Schedule", .overview: "Ask your crew", .vault: "+ Add Secret",
            .health: "Copy diagnostics", .updates: "Check for updates",
        ]
        for (destination, title) in wanted {
            shell.show(destination)
            settle(shell)
            let primary = shell.toolbar.debugPrimaryAction as? HelmButton
            // Notebook's draws as its icon below 1600pt (R2-BUG-07, U-02), so
            // it is matched by the page's own button rather than its title.
            let isThePagesOwn = destination == .notebook && primary != nil
                && primary === shell.workspace.notebook.workspacePrimaryAction
            check(primary?.title == title || isThePagesOwn,
                  "\(destination.rawValue)'s primary is \(primary?.title ?? "nothing"), want \(title)", &ok)
        }
        // Crew's two buttons left the page: Refresh is a page action.
        shell.show(.overview)
        settle(shell)
        check(shell.toolbar.debugPageActions.contains { ($0 as? HelmButton)?.title == "Refresh" },
              "Crew's Refresh is not in the toolbar", &ok)
        // Nothing lives in a card header: Add Secret is not in the Secrets card.
        shell.show(.vault)
        settle(shell)
        if let add = shell.toolbar.debugPrimaryAction {
            check(add.isDescendant(of: shell.debugContentPane) == false,
                  "Add Secret is still inside the page", &ok)
        }
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: R2-UX-06 - one toolbar on Console, Code and Notebook

    private static func checkThePageToolbarsAreTheWindowToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                               _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        func inPage(_ view: NSView) -> Bool { view.isDescendant(of: shell.debugContentPane) }
        // Console: its whole action cluster is the window toolbar's; its tab
        // strip stays in the page.
        shell.show(.console)
        settle(shell)
        let console = shell.workspace.console
        let consoleActions = shell.toolbar.debugPageActions
        check(!consoleActions.isEmpty && consoleActions.map(ObjectIdentifier.init) == console.pageToolViews.map(ObjectIdentifier.init),
              "Console's toolbar actions are not its page cluster", &ok)
        check(!console.pageToolViews.contains(where: inPage), "a Console action is still in the page's own row", &ok)
        check(console.pageToolViews.contains { $0 === console.findButton } && console.pageToolViews.contains { $0 === console.zoomStepper },
              "Console's Find or text-size stepper is missing from the toolbar", &ok)
        // Code: the same, with its snippet tabs left in the page.
        shell.show(.codePreview)
        settle(shell)
        let codeActions = shell.toolbar.debugPageActions
        check(codeActions.count == 8 && !codeActions.contains(where: inPage),
              "Code's toolbar carries \(codeActions.count) of its 8 actions, or some are still in the page", &ok)
        // Notebook: no page row at all; its controls are up here.
        shell.show(.notebook)
        settle(shell)
        let notebook = shell.workspace.notebook
        check(!notebook.debugPageToolbarIsShown, "Notebook still draws its own toolbar row", &ok)
        let popUp = notebook.debugToolbarModePopUp
        check(shell.toolbar.debugPageActions.contains { $0 === popUp }, "Notebook's view mode is not in the toolbar", &ok)
        popUp.selectItem(at: 2)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        settle(shell)
        check(notebook.debugMode == .preview, "picking Preview in the toolbar left Notebook in \(notebook.debugMode)", &ok)
        notebook.debugSetMode(.split)
        settle(shell)
        check(popUp.titleOfSelectedItem == "Split", "the toolbar's view mode did not follow the page (\(popUp.titleOfSelectedItem ?? ""))", &ok)
        // The overflow form runs a control, through the control.
        let menuItems = WorkspaceToolbar.menuItems(for: [popUp])
        if let preview = menuItems.first?.submenu?.items.first(where: { $0.title == "Preview" }),
           let action = preview.action {
            _ = (preview.target as? NSObject)?.perform(action, with: preview)
            settle(shell)
            check(notebook.debugMode == .preview, "the overflow menu's Preview did not switch Notebook", &ok)
        } else {
            fail("the view mode's overflow form has no Preview row", &ok)
        }
        notebook.debugSetMode(.split)
        settle(shell)
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: R2-UX-07 - empty states that invite

    /// Every visible, page-level empty state under `view`.
    static func pageEmptyStates(in view: NSView) -> [HelmEmptyState] {
        var found: [HelmEmptyState] = []
        func walk(_ v: NSView) {
            if v.isHidden || v.alphaValue == 0 { return }
            if let state = v as? HelmEmptyState, state.frame.height > 0 { found.append(state) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private static func checkEmptyStatesInvite(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        // Tasks with nothing in it: one invitation, not three empty states.
        shell.show(.shift)
        settle(shell)
        guard let shift = shell.debugSlotController(.shift) as? ShiftController else {
            fail("Tasks did not mount", &ok)
            return
        }
        if shift.debugStoreIsEmpty {
            check(!shift.debugStartHereState.isHiddenOrHasHiddenAncestor,
                  "an empty Tasks page has no start-here state", &ok)
            check(shift.debugStartHereReplacesHidden.allSatisfy { $0 },
                  "an empty Tasks page still draws Follow-ups or Projects under its start-here state", &ok)
            check(shift.drillHeaderSubtitle == "No tasks yet", "an empty Tasks page says \(shift.drillHeaderSubtitle ?? "")", &ok)
            check(pageEmptyStates(in: shell.debugContentPane).count == 1,
                  "an empty Tasks page draws \(pageEmptyStates(in: shell.debugContentPane).count) empty states, want one", &ok)
            check(shift.debugStartHereState.debugHasWatermark, "Tasks' start-here state is not the shared look", &ok)
        } else {
            fail("the suite's Tasks store is not empty, so the start-here check measures nothing", &ok)
        }
        // Schedules with nothing: one invitation, not three cards of zeros.
        shell.show(.schedules)
        settle(shell)
        if let schedules = shell.debugSlotController(.schedules) as? SchedulesController {
            check(!schedules.debugPageEmptyState.isHiddenOrHasHiddenAncestor && schedules.debugEmptyReplacesHidden.allSatisfy { $0 },
                  "an empty Schedules page shows its invitation \(schedules.debugPageEmptyState.isHidden ? "hidden" : "shown") over sections hidden \(schedules.debugEmptyReplacesHidden)", &ok)
            check(pageEmptyStates(in: shell.debugContentPane).count == 1,
                  "an empty Schedules page draws \(pageEmptyStates(in: shell.debugContentPane).count) empty states, want one", &ok)
        }
        // Knowledge's tabs: the same look - a watermark, not a tile or an
        // outline of their own - and Docs' state is not inside a card.
        for destination in [RailDestination.notebook, .runbooks, .postmortems, .docs, .readingList] {
            shell.show(destination)
            settle(shell)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            settle(shell)
            let states = pageEmptyStates(in: shell.debugContentPane).filter { $0.debugIsPageLevel }
            check(states.count == 1, "\(destination.rawValue) draws \(states.count) page-level empty states, want one", &ok)
            if let state = states.first {
                check(state.debugHasWatermark, "\(destination.rawValue)'s empty state is not the shared look (no watermark)", &ok)
            }
        }
        // Profile-aware copy: a Personal Postmortems page is told what a
        // postmortem is and is not sent to a module it does not have.
        if let postmortems = shell.debugSlotController(.postmortems) as? PostmortemsController {
            AppSettings.shared.setProfile(.personal)
            postmortems.debugRefreshEmptyCopy()
            check(!postmortems.debugOpenLogsButtonIsShown, "a Personal Postmortems page still offers Open Logs", &ok)
            AppSettings.shared.hiddenModules = []
            postmortems.debugRefreshEmptyCopy()
            check(postmortems.debugOpenLogsButtonIsShown, "an Operator Postmortems page lost Open Logs", &ok)
        }
        shell.show(.homeCanvas)
        settle(shell)
    }

    // MARK: R2-UX-08 - Settings housekeeping

    /// Four things on one page: the window's Back and Forward walk the
    /// categories (so the page draws no arrows of its own), a relaunch button
    /// sits beside each row that waits for the next launch, the lock's two
    /// thresholds are the captain's to choose, and the locality fact is said
    /// once.
    private static func checkSettingsHousekeeping(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        shell.show(.shift)
        settle(shell)
        shell.show(.settings)
        settle(shell)
        guard let settings = shell.debugSlotController(.settings) as? SettingsController else {
            fail("Settings did not mount", &ok)
            return
        }
        // No second pair of arrows, and no second storage notice.
        check(!settings.debugHeaderRowShown, "Settings still draws its own Back and Forward under the window's", &ok)
        check(settings.debugFooterText.hasPrefix("Stored locally"), "the column footer reads \(settings.debugFooterText)", &ok)
        check(!(shell.debugHeader?.subtitle ?? "").lowercased().contains("stored locally"),
              "the module line repeats the footer: \(shell.debugHeader?.subtitle ?? "")", &ok)

        // The window's Back and Forward walk the categories: Tasks, then
        // Settings on the category it opened with, then two more.
        let first = settings.debugSelectedCategory
        let picks = SettingsController.Category.allCases.filter { $0 != first }.prefix(2)
        guard picks.count == 2 else { fail("Settings has fewer than three categories", &ok); return }
        for category in picks {
            settings.debugSidebar.debugClickRow(id: category.rawValue)
            settle(shell)
        }
        let navigation = shell.toolbar.debugNavigation
        // The real control's own action. It is momentary, which drops a
        // selection set from code, so the press holds it for the one send.
        func press(_ segment: Int) {
            guard navigation.isEnabled(forSegment: segment) else {
                fail("\(segment == 0 ? "Back" : "Forward") is not offered", &ok)
                return
            }
            navigation.trackingMode = .selectOne
            navigation.selectedSegment = segment
            _ = navigation.sendAction(navigation.action, to: navigation.target)
            navigation.trackingMode = .momentary
            settle(shell)
        }
        let walkedBack = [picks.first!, first]
        for want in walkedBack {
            press(0)
            check(shell.debugHistory.current == .rail(.settings) && settings.debugSelectedCategory == want,
                  "Back from a category reached \(String(describing: shell.debugHistory.current)) on \(settings.debugSelectedCategory.rawValue), want Settings on \(want.rawValue)", &ok)
        }
        press(0)
        check(shell.debugHistory.current == .rail(.shift),
              "Back past Settings' first category reached \(String(describing: shell.debugHistory.current)), want Tasks", &ok)
        press(1)
        check(shell.debugHistory.current == .rail(.settings) && settings.debugSelectedCategory == first,
              "Forward into Settings landed on \(settings.debugSelectedCategory.rawValue), want \(first.rawValue)", &ok)
        press(1)
        check(settings.debugSelectedCategory == picks.first!,
              "Forward within Settings landed on \(settings.debugSelectedCategory.rawValue), want \(picks.first!.rawValue)", &ok)
        check(navigation.isEnabled(forSegment: 1), "Forward is not offered with one more category ahead", &ok)

        // Relaunch: offered only while a row has a change waiting, and the
        // button reaches the relaunch path. The path itself is a recorder.
        settings.debugSidebar.debugClickRow(id: SettingsController.Category.appearance.rawValue)
        settle(shell)
        let savedLayout = AppSettings.shared.workspaceLayout
        let savedPerform = AppRelaunch.perform
        var relaunches = 0
        AppRelaunch.perform = { relaunches += 1 }
        // This binary has no bundle, so the real button is disabled here -
        // asserted, then overridden so the click path can be measured.
        check(!AppRelaunch.canRelaunch && !settings.debugLayoutRelaunchButton.isEnabled,
              "an unbundled binary offers an enabled Relaunch Grand Line it cannot carry out", &ok)
        AppRelaunch.canRelaunchOverrideForTests = true
        defer {
            AppSettings.shared.workspaceLayout = savedLayout
            AppRelaunch.perform = savedPerform
            AppRelaunch.canRelaunchOverrideForTests = nil
        }
        check(settings.debugLayoutRelaunchButton.isHidden, "Relaunch is offered beside Window layout with nothing to apply", &ok)
        check(settings.debugTextSizeRelaunchButton.isHidden, "Relaunch is offered beside text size with nothing to apply", &ok)
        let other = WorkspaceLayout.allCases.first { $0 != PlaceName.layout } ?? .floatingBar
        settings.debugWindowLayoutTabs.debugClickTab(id: other.rawValue)
        settle(shell)
        check(!settings.debugLayoutRelaunchButton.isHidden,
              "choosing the other window layout does not offer Relaunch Grand Line", &ok)
        settings.debugLayoutRelaunchButton.performClick(nil)
        check(relaunches == 1, "Relaunch Grand Line beside Window layout did not reach the relaunch path", &ok)
        settings.debugWindowLayoutTabs.debugClickTab(id: PlaceName.layout.rawValue)
        settle(shell)
        check(settings.debugLayoutRelaunchButton.isHidden, "Relaunch stays offered after the layout went back", &ok)

        let savedScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(savedScale) }
        if let index = ChromeTextScale.steps.firstIndex(where: { abs($0.scale - ChromeTextScale.shared.launchScale) > 0.001 }),
           let button = settings.debugUIScaleButtons[index] {
            button.performClick(nil)
            settle(shell)
            check(!settings.debugTextSizeRelaunchButton.isHidden,
                  "a new text size does not offer Relaunch Grand Line beside it", &ok)
            settings.debugTextSizeRelaunchButton.performClick(nil)
            check(relaunches == 2, "Relaunch Grand Line beside text size did not reach the relaunch path", &ok)
        } else {
            fail("no text size differs from the launch one, so the text-size relaunch measures nothing", &ok)
        }

        // The lock thresholds: a choice is stored and the live lock reads it.
        settings.debugSidebar.debugClickRow(id: SettingsController.Category.security.rawValue)
        settle(shell)
        let savedIdle = AppSettings.shared.appLockIdleSeconds
        let savedSession = AppSettings.shared.appLockSessionSeconds
        defer {
            AppSettings.shared.appLockIdleSeconds = savedIdle
            AppSettings.shared.appLockSessionSeconds = savedSession
        }
        let idle = settings.debugLockIdlePopUp
        let session = settings.debugLockSessionPopUp
        check(idle.isEnabled && session.isEnabled, "the lock's thresholds are not editable in Settings", &ok)
        check(idle.numberOfItems == AppLockController.idleChoices.count,
              "Lock when idle offers \(idle.numberOfItems) choices, want \(AppLockController.idleChoices.count)", &ok)
        let lock = AppLockController()
        for (popUp, want) in [(idle, TimeInterval(15 * 60)), (session, TimeInterval(4 * 3600))] {
            guard let index = popUp.itemArray.firstIndex(where: { ($0.representedObject as? TimeInterval) == want }) else {
                fail("\(popUp.accessibilityLabel() ?? "a threshold") does not offer \(want)s", &ok)
                continue
            }
            popUp.selectItem(at: index)
            _ = popUp.sendAction(popUp.action, to: popUp.target)
        }
        check(AppSettings.shared.appLockIdleSeconds == 15 * 60 && AppSettings.shared.appLockSessionSeconds == 4 * 3600,
              "choosing 15 minutes and 4 hours stored \(String(describing: AppSettings.shared.appLockIdleSeconds)) and \(String(describing: AppSettings.shared.appLockSessionSeconds))", &ok)
        check(lock.idleThreshold == 15 * 60 && lock.sessionThreshold == 4 * 3600,
              "the running lock still uses \(lock.idleThreshold)s and \(lock.sessionThreshold)s", &ok)
        shell.show(.homeCanvas)
        settle(shell)
    }
}

#endif
