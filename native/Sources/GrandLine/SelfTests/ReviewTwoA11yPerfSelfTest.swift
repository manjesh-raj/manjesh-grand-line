// Grand Line - native macOS app.
//
// The second full review's accessibility and performance findings
// (R2-A11Y-03 to R2-A11Y-05, R2-PERF-01 to R2-PERF-06): the window-backed
// half.
//
// Everything here needs a real window - the real sidebar shell from
// `ReviewTourLab.makeOffScreenSplitShell()`, its real toolbar and outline
// view - so it is in `NEEDS_SESSION`. The label words, the caches and the
// source guards are `ReviewTwoA11yPerfModelSelfTest`, which CI runs headless.
//
// It never runs a real `npm`, `brew` or `git`, seeds no store it does not
// own, and puts back every preference it changes.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ReviewTwoA11yPerfSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let savedCounts = BackgroundSignalsPoller.shared.lastCounts
        defer { BackgroundSignalsPoller.shared.debugSetCounts(savedCounts) }

        var allOK = true
        let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(shell)
        for check in [checkTheLabelsSayWhatTheControlsDo] {
            var ok = true
            check(shell, window, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "ReviewTwoA11yPerfSelfTest: all checks passed" : "ReviewTwoA11yPerfSelfTest: FAILED")
        return allOK
    }

    // MARK: Shared

    static func settle(_ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    static func pump(timeout: TimeInterval = 2, until landed: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !landed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    static func waitForPanes(_ shell: MainSplitShellController) {
        pump(timeout: 5) { WorkspaceMotion.debugPaneMotionsInFlight == 0 }
        settle(shell)
    }

    static func cell(_ module: WorkspaceModule, _ shell: MainSplitShellController) -> WorkspaceSidebarPageCell? {
        shell.sidebar.debugCell(for: .module(module)) as? WorkspaceSidebarPageCell
    }

    // MARK: R2-A11Y-03 - the words agree with the behaviour

    private static func checkTheLabelsSayWhatTheControlsDo(_ shell: MainSplitShellController, _ window: NSWindow,
                                                           _ ok: inout Bool) {
        print("\n-- R2-A11Y-03: the labels say what the controls do --")

        // The account header opens a menu whose only item is Log Out, and it
        // says so rather than promising an account menu.
        let header = shell.sidebar.debugHeader
        let items = shell.sidebar.debugAccountMenuTitles
        check(header.accessibilityRole() == .menuButton,
              "the account header's role is \(String(describing: header.accessibilityRole())), want a menu button", &ok)
        check(header.accessibilityLabel() == "\(AppPaths.displayName), Log Out",
              "the account header reads \"\(header.accessibilityLabel() ?? "")\"", &ok)
        let spoken = header.accessibilityLabel() ?? ""
        for item in items {
            let name = item.replacingOccurrences(of: "\u{2026}", with: "")
            check(spoken.contains(name), "the account header does not name its menu's \"\(name)\"", &ok)
        }
        check(!spoken.lowercased().contains("account menu"),
              "the account header still promises an account menu: \"\(spoken)\"", &ok)

        // The sidebar button says which way it will go, and does it.
        let toolbar: WorkspaceToolbar = shell.toolbar
        let button = toolbar.debugSidebarButton
        func sidebarMatches(shown: Bool, _ when: String) {
            let want = shown ? "Hide Sidebar" : "Show Sidebar"
            check(button.accessibilityLabel() == want,
                  "\(when): the sidebar button reads \"\(button.accessibilityLabel() ?? "")\", want \"\(want)\"", &ok)
            check(button.toolTip == (shown ? "Hide the sidebar" : "Show the sidebar"),
                  "\(when): the sidebar button's tooltip is \"\(button.toolTip ?? "")\"", &ok)
            check(toolbar.debugSidebarItem?.label == want,
                  "\(when): the sidebar item's label is \"\(toolbar.debugSidebarItem?.label ?? "nil")\"", &ok)
        }
        check(!shell.debugSidebarIsCollapsed, "the sidebar does not start shown", &ok)
        sidebarMatches(shown: true, "at launch")
        button.performClick(nil)
        waitForPanes(shell)
        check(shell.debugSidebarIsCollapsed, "\"Hide Sidebar\" did not hide the sidebar", &ok)
        sidebarMatches(shown: false, "after hiding it")
        button.performClick(nil)
        waitForPanes(shell)
        check(!shell.debugSidebarIsCollapsed, "\"Show Sidebar\" did not show the sidebar", &ok)
        sidebarMatches(shown: true, "after showing it again")

        // The inspector button's label flips with its tooltip.
        guard let inspector = toolbar.debugInspectorItem else {
            fail("the toolbar has no inspector item", &ok)
            return
        }
        check(inspector.label == "Show Inspector" && inspector.toolTip == "Show the inspector",
              "with the inspector closed its button reads \"\(inspector.label)\" / \"\(inspector.toolTip ?? "")\"", &ok)
        shell.setInspectorShown(true)
        waitForPanes(shell)
        check(!shell.debugInspectorIsCollapsed, "the inspector did not open", &ok)
        check(inspector.label == "Hide Inspector" && inspector.toolTip == "Hide the inspector",
              "with the inspector open its button reads \"\(inspector.label)\" / \"\(inspector.toolTip ?? "")\"", &ok)
        shell.setInspectorShown(false)
        waitForPanes(shell)
        check(inspector.label == "Show Inspector",
              "with the inspector closed again its button reads \"\(inspector.label)\"", &ok)
        check(inspector.paletteLabel == "Inspector" && toolbar.debugSidebarItem?.paletteLabel == "Sidebar",
              "the customisation palette's names changed with the state", &ok)
        shell.debugResetInspectorPreference()
        settle(shell)

        // Setup's badge is read with its unit.
        var counts = BackgroundSignalsPoller.SignalCounts()
        counts.toolUpdates = 16
        BackgroundSignalsPoller.shared.debugSetCounts(counts)
        pump { shell.debugSignalsMonitor.signals.setup.value == 16 }
        settle(shell)
        check(cell(.setup, shell)?.accessibilityLabel() == "Setup, 16 tools need attention",
              "Setup's row reads \"\(cell(.setup, shell)?.accessibilityLabel() ?? "")\"", &ok)
        BackgroundSignalsPoller.shared.debugSetCounts(BackgroundSignalsPoller.SignalCounts())
        settle(shell)
        if ok { print("  OK   Log Out named, the sidebar and inspector buttons say which way, Setup's count has its unit") }
    }
}

#endif
