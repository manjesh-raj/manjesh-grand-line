// Grand Line - native macOS app.
//
// Stage 3 of the modular-shell migration: the sidebar shell
// (`MainSplitShellController`), mounted in a real off-screen window and
// driven through its own controls.
//
//   1. **Every route shows, through the one mounter.** Each of the 29
//      destinations lands in the same `DestinationMounter` slot the floating
//      bar uses, lights its sidebar row and names itself in the title bar.
//   2. **No page grows the window.** At the narrowest width the sidebar is
//      kept for, and at 1100 (where it steps aside), visiting every page
//      leaves the window the width it was - gotcha (13), which the content
//      column's minimum and the sidebar's collapse exist to hold.
//   3. **The sidebar is the map.** A click navigates, a Pinned row stays lit,
//      Pin and Unpin edit the quick-access list in place, sessions are
//      Console's children, ⌘⇧D reveals it, and ⌥⌘S toggles the page's own
//      column where there is one and the sidebar everywhere else.
//   4. **The toolbar carries the chrome.** The page's actions, Home's
//      spaces, the notifications badge from the bell's store, Back and
//      Forward, the inspector.
//   5. **The lock hides what the overlay cannot cover** - the toolbar and the
//      title, which sit above the content view.
//   6. **The status line** shows the live sessions and the focus timer chip.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_MAIN_SPLIT_SHELL_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum MainSplitShellSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedPins = AppSettings.shared.quickAccess
        defer { AppSettings.shared.quickAccess = savedPins }

        var allOK = true
        let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(shell)
        for check in [checkEveryRouteShowsThroughTheMounter, checkNoPageGrowsTheWindow, checkTheSidebarIsTheMap,
                      checkPinsEditInPlace, checkTheMapAndTheSidebarToggle, checkTheToolbar, checkBackAndForward,
                      checkTheInspector, checkTheLockHidesTheToolbar, checkTheStatusLine, checkToastsLandInTheColumn,
                      checkTheAccountMenu] {
            var ok = true
            check(shell, window, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "MainSplitShellSelfTest: all checks passed" : "MainSplitShellSelfTest: FAILED")
        return allOK
    }

    private static func settle(_ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: MainSplitShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    // MARK: 1 - every route

    private static func checkEveryRouteShowsThroughTheMounter(_ shell: MainSplitShellController, _ window: NSWindow,
                                                             _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for destination in RailDestination.allCases {
            shell.show(destination)
            settle(shell)
            check(shell.debugCurrentDestination == destination, "\(destination.rawValue) did not show", &ok)
            let slotView = shell.destinationViewIfMountedForTests(destination.slot)
            check(slotView != nil && slotView === shell.workspace.content.visibleDestinationView(),
                  "\(destination.rawValue) is not showing its own mounter slot", &ok)
            check(slotView?.isDescendant(of: shell.debugContentPane) == true,
                  "\(destination.rawValue)'s page is not in the content column", &ok)
            check(shell.sidebar.debugSelectedEntry == .destination(destination, pinned: false),
                  "\(destination.rawValue) did not light its sidebar row (lit: \(String(describing: shell.sidebar.debugSelectedEntry)))", &ok)
            let title = shell.workspace.content.mounter.slot(for: destination.slot)?.title
            check(window.title == title && shell.debugPageTitle.title == title,
                  "the title bar says \"\(window.title)\" on \(destination.rawValue), want \"\(title ?? "-")\"", &ok)
            let spaces = shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.spaces)
            check(spaces == (destination == .homeCanvas),
                  "the spaces are \(spaces ? "shown" : "hidden") on \(destination.rawValue)", &ok)
        }
        // The mounter is the floating bar's, untouched: every slot mounted
        // once, and no second copy of any page.
        check(Set(shell.mountedDestinationSlotsForTests).count == DestinationSlotID.allCases.count,
              "visiting every page mounted \(Set(shell.mountedDestinationSlotsForTests).count) of \(DestinationSlotID.allCases.count) slots", &ok)
    }

    // MARK: 2 - the window keeps its width

    private static func checkNoPageGrowsTheWindow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        // The narrowest width that keeps the sidebar: its pane plus the
        // column's minimum.
        resize(window, width: 1512, shell)
        let pane = shell.debugSidebarPane?.frame.width ?? MainSplitShellController.sidebarWidth
        let narrowest = (pane + MainSplitShellController.contentMinimum).rounded(.up) + 1
        for (width, sidebarShown) in [(narrowest, true), (CGFloat(1100), false)] {
            resize(window, width: width, shell)
            check(shell.debugSidebarIsCollapsed == !sidebarShown,
                  "at \(Int(width))pt the sidebar is \(shell.debugSidebarIsCollapsed ? "collapsed" : "showing")", &ok)
            for destination in RailDestination.allCases {
                shell.show(destination)
                settle(shell)
                check(abs(window.frame.width - width) < 0.5,
                      "\(destination.rawValue) grew a \(Int(width))pt window to \(Int(window.frame.width))pt", &ok)
                if abs(window.frame.width - width) >= 0.5 { resize(window, width: width, shell) }
            }
        }
        // Wide again: the sidebar comes back at the width it opened at.
        resize(window, width: 1512, shell)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5,
              "widening the window brought the sidebar back at \(shell.debugSidebarWidth)pt (collapsed: \(shell.debugSidebarIsCollapsed))", &ok)
    }

    // MARK: 3 - the sidebar

    private static func checkTheSidebarIsTheMap(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        shell.show(.homeCanvas)
        settle(shell)
        check(shell.sidebar.debugClick(.destination(.hosts, pinned: false)), "the Hosts row is not in the sidebar", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .hosts, "clicking Hosts showed \(String(describing: shell.debugCurrentDestination))", &ok)

        // A pinned row stays the lit one.
        AppSettings.shared.quickAccess = QuickAccessConfiguration(pinned: [.console, .stickyBoard])
        shell.quickAccessDidChange(AppSettings.shared.quickAccess)
        check(shell.sidebar.debugClick(.destination(.stickyBoard, pinned: true)), "the pinned Sticky Board row is missing", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .stickyBoard
                && shell.sidebar.debugSelectedEntry == .destination(.stickyBoard, pinned: true),
              "the pinned row did not stay lit (lit: \(String(describing: shell.sidebar.debugSelectedEntry)))", &ok)
        // Reached any other way, the group row lights.
        shell.show(.stickyBoard)
        shell.show(.review)
        shell.show(.stickyBoard)
        settle(shell)
        check(shell.sidebar.debugSelectedEntry == .destination(.stickyBoard, pinned: false),
              "a page reached from outside the sidebar lit \(String(describing: shell.sidebar.debugSelectedEntry))", &ok)

        // Every visible page row carries the page's real name.
        let entries = shell.sidebar.debugVisibleEntries
        for destination in RailDestination.allCases {
            check(entries.contains(.destination(destination, pinned: false)), "no visible row for \(destination.rawValue)", &ok)
        }
    }

    private static func checkPinsEditInPlace(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        AppSettings.shared.quickAccess = QuickAccessConfiguration(pinned: [.console])
        shell.quickAccessDidChange(AppSettings.shared.quickAccess)
        settle(shell)
        let row = WorkspaceSidebarEntry.destination(.review, pinned: false)
        check(shell.sidebar.debugContextMenuTitles(for: row).contains("Pin to Sidebar"),
              "Review's menu does not offer Pin: \(shell.sidebar.debugContextMenuTitles(for: row))", &ok)
        check(shell.sidebar.debugPerformContextMenuItem("Pin to Sidebar", on: row), "could not run Pin to Sidebar", &ok)
        settle(shell)
        check(AppSettings.shared.quickAccess.contains(.review), "Pin did not write the quick-access list", &ok)
        check(shell.sidebar.debugVisibleEntries.contains(.destination(.review, pinned: true)),
              "Pin did not add Review to the Pinned section", &ok)
        check(shell.sidebar.debugPerformContextMenuItem("Unpin from Sidebar", on: .destination(.review, pinned: true)),
              "the pinned row does not offer Unpin", &ok)
        settle(shell)
        check(!AppSettings.shared.quickAccess.contains(.review)
                && !shell.sidebar.debugVisibleEntries.contains(.destination(.review, pinned: true)),
              "Unpin did not take Review back out", &ok)
        // Home is always first, so there is nothing to pin.
        check(!shell.sidebar.debugContextMenuTitles(for: .destination(.homeCanvas, pinned: false)).contains("Pin to Sidebar"),
              "Home offers Pin", &ok)
    }

    private static func checkTheMapAndTheSidebarToggle(_ shell: MainSplitShellController, _ window: NSWindow,
                                                      _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        shell.show(.homeCanvas)
        settle(shell)
        // ⌥⌘S on a page with no column of its own: the sidebar.
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(shell.debugSidebarIsCollapsed, "⌥⌘S on Home did not hide the sidebar", &ok)
        // ⌘⇧D: the sidebar is the map, so it comes back with the keyboard in it.
        check(shell.revealDestinationMap(), "the sidebar shell did not take ⌘⇧D", &ok)
        settle(shell)
        check(!shell.debugSidebarIsCollapsed && window.firstResponder === shell.sidebar.outlineView,
              "⌘⇧D did not reveal the sidebar and focus it", &ok)

        // ⌥⌘S on a page with its own column: that column, as before.
        shell.show(.settings)
        settle(shell)
        guard let split = (shell.debugSlotController(.settings) as? HelmSplitPageHosting)?.splitPage else {
            fail("Settings has no split page - the column half cannot be checked", &ok)
            return
        }
        let columnWasCollapsed = split.isSidebarCollapsed
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(split.isSidebarCollapsed != columnWasCollapsed && !shell.debugSidebarIsCollapsed,
              "⌥⌘S on Settings did not toggle Settings' own column (or hid the sidebar instead)", &ok)
        shell.toggleSidebarFromMenu()
        settle(shell)
    }

    // MARK: 4 - the toolbar

    private static func checkTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        // The page's own actions are the page's views, moved into the toolbar.
        shell.show(.hosts)
        settle(shell)
        let hostsActions = (shell.debugSlotController(.hosts) as? DaylightDrillActions)?.drillHeaderActions ?? []
        check(!hostsActions.isEmpty, "the Hosts page offers no actions - this check would pass vacuously", &ok)
        check(shell.toolbar.debugPageActions.map(ObjectIdentifier.init) == hostsActions.map(ObjectIdentifier.init),
              "the toolbar is not carrying Hosts' own actions", &ok)
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "the page-actions item is not in the toolbar", &ok)
        // A page that hides all its own buttons leaves no empty capsule, and
        // gets the item back when it shows one again.
        let wasHidden = hostsActions.map(\.isHidden)
        hostsActions.forEach { $0.isHidden = true }
        check(!shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "with every Hosts button hidden the toolbar still holds an actions item", &ok)
        zip(hostsActions, wasHidden).forEach { $0.isHidden = $1 }
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "showing Hosts' buttons again did not bring the actions item back", &ok)
        if let subtitle = (shell.debugSlotController(.hosts) as? DaylightDrillActions)?.drillHeaderSubtitle {
            check(window.subtitle == subtitle, "the subtitle is \"\(window.subtitle)\", want Hosts' live \"\(subtitle)\"", &ok)
        }
        shell.show(.homeCanvas)
        settle(shell)
        check(shell.toolbar.debugPageActions.isEmpty
                && !shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "Home still shows the previous page's actions", &ok)
        // Home's spaces filter its cards, as the pills did.
        let spaces = shell.toolbar.debugSpaces
        spaces.selectedSegment = DaylightSpace.allCases.firstIndex(of: .operations) ?? 0
        _ = spaces.sendAction(spaces.action, to: spaces.target)
        settle(shell)
        check(shell.debugHomeCanvas.selectedSpace == .operations, "the toolbar's spaces did not filter Home", &ok)
        shell.selectSpace(.overview)

        // The badge is the bell's own count, from the one store. (`resetForTesting`
        // tells no observer, so the first real change is what the toolbar sees.)
        let center = GrandLineNotificationCenter.shared
        center.resetForTesting()
        defer { center.resetForTesting() }
        center.set(AppNotification(id: "split-shell-badge", title: "Backup failed", subtext: "test", source: "Tests",
                                   kind: .actionNeeded, tint: .warn, date: Date(), navigate: {}), id: "split-shell-badge")
        check(center.badgeCount == 1 && shell.toolbar.debugBadgeText == "1",
              "one notification shows badge \(String(describing: shell.toolbar.debugBadgeText))", &ok)
        center.remove(id: "split-shell-badge")
        check(center.badgeCount == 0 && shell.toolbar.debugBadgeText == nil,
              "the badge stayed after the notification resolved", &ok)

        // The light/dark toggle flips the theme within its family.
        let before = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(before) }
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.theme), "the light/dark item has no action", &ok)
        check(ThemeManager.shared.theme.mode != before.mode, "the light/dark item did not flip the appearance", &ok)
    }

    private static func checkBackAndForward(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        for page in [RailDestination.homeCanvas, .shift, .review] { shell.show(page) }
        settle(shell)
        let navigation = shell.toolbar.debugNavigation
        check(navigation.isEnabled(forSegment: 0) && !navigation.isEnabled(forSegment: 1),
              "after three pages Back should be on and Forward off", &ok)
        shell.debugStep(.back)
        check(shell.debugCurrentDestination == .shift, "Back went to \(String(describing: shell.debugCurrentDestination))", &ok)
        shell.debugStep(.back)
        check(shell.debugCurrentDestination == .homeCanvas, "a second Back went to \(String(describing: shell.debugCurrentDestination))", &ok)
        shell.debugStep(.forward)
        check(shell.debugCurrentDestination == .shift && navigation.isEnabled(forSegment: 1),
              "Forward went to \(String(describing: shell.debugCurrentDestination))", &ok)
        shell.show(.settings)
        check(!navigation.isEnabled(forSegment: 1), "a new page kept Forward enabled", &ok)
        // The segmented control itself reaches the same step, through its own
        // target and action. A momentary control keeps no selection set from
        // code, so it is switched to select-one for the length of the "click"
        // - the handler reads the same `selectedSegment` a real click sets.
        navigation.trackingMode = .selectOne
        navigation.selectedSegment = 0
        _ = navigation.sendAction(navigation.action, to: navigation.target)
        navigation.trackingMode = .momentary
        check(shell.debugCurrentDestination == .shift, "the Back segment went to \(String(describing: shell.debugCurrentDestination))", &ok)
    }

    private static func checkTheInspector(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        check(shell.debugInspectorIsCollapsed, "the inspector is open at launch", &ok)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector), "the inspector item has no action", &ok)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "the inspector item did not open the inspector", &ok)
        check(shell.inspector.debugEmptyState.isDescendant(of: shell.inspector.view),
              "the inspector does not say it has nothing to show", &ok)
        shell.inspector.debugCloseButton.performClick(nil)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "the inspector's close button did not close it", &ok)
    }

    // MARK: 5 - the lock

    private static func checkTheLockHidesTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                   _ ok: inout Bool) {
        shell.show(.hosts)
        settle(shell)
        // The closure `LockPresenter.showLock`/`hideLock` call -
        // `SplitShellModelSelfTest` guards that they do. `showLock` itself
        // would run the `av` availability check, which no suite may.
        guard let overlay = shell.workspace.lock.onOverlayVisibilityChanged else {
            fail("the sidebar shell does not listen for the lock overlay", &ok)
            return
        }
        overlay(true)
        check(window.toolbar?.isVisible == false && window.titleVisibility == .hidden && window.title != "Hosts",
              "with the lock up the toolbar or the page's title is still showing", &ok)
        overlay(false)
        check(window.toolbar?.isVisible == true && window.titleVisibility == .visible && window.title == "Hosts",
              "the toolbar and the title did not come back after the lock", &ok)
    }

    // MARK: 6 - the status line

    private static func checkTheStatusLine(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let status = shell.debugStatusLine
        check(status.debugSessionsText == "No live sessions", "with no sessions the line says \"\(status.debugSessionsText)\"", &ok)
        let live = UUID()
        let restored = UUID()
        shell.sessions.register(hostID: live, label: "DEV Bastion", accentHex: nil, state: .connected)
        shell.sessions.register(hostID: restored, label: "PROD Web", accentHex: nil, state: .restored)
        settle(shell)
        check(status.debugSessionsText == "1 session live \u{00B7} 1 restored, not connected",
              "two sessions read \"\(status.debugSessionsText)\"", &ok)
        let entries = shell.sidebar.debugVisibleEntries
        if let console = entries.firstIndex(of: .destination(.console, pinned: false)) {
            check(Array(entries.dropFirst(console + 1).prefix(2)) == [.session(hostID: live), .session(hostID: restored)],
                  "the sessions are not listed under Console", &ok)
        } else {
            fail("Console is not in the sidebar", &ok)
        }
        shell.sessions.unregister(hostID: live)
        shell.sessions.unregister(hostID: restored)
        settle(shell)
        check(status.debugSessionsText == "No live sessions", "unregistering left \"\(status.debugSessionsText)\"", &ok)

        // F7's chip rides the status line here.
        check(!status.debugFocusChipIsVisible, "a focus chip shows with no timer running", &ok)
        var task = ShiftTask.fresh()
        task.title = "Rotate the staging certificate"
        shell.focusTimer.start(task: task)
        check(status.debugFocusChipIsVisible, "a running timer did not put its chip on the status line", &ok)
        _ = shell.focusTimer.stop()
        check(!status.debugFocusChipIsVisible, "the chip stayed after the timer stopped", &ok)
    }

    private static func checkToastsLandInTheColumn(_ shell: MainSplitShellController, _ window: NSWindow,
                                                  _ ok: inout Bool) {
        let before = Toast.debugCount(in: shell.debugContentPane)
        shell.showToast("Saved")
        check(Toast.debugCount(in: shell.debugContentPane) == before + 1, "a toast did not land in the content column", &ok)
        check(Toast.debugCount(in: shell.sidebar.view) == 0, "a toast landed in the sidebar", &ok)
    }

    private static func checkTheAccountMenu(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        check(shell.sidebar.debugHeader.debugTitle == AppPaths.displayName, "the sidebar header does not name the app", &ok)
        shell.sidebar.onOpenSettings?()
        check(shell.debugCurrentDestination == .settings, "the account menu's Settings did not open Settings", &ok)
        // Log Out goes through the one confirmation, then the app delegate.
        var loggedOut = false
        let previous = shell.onLogoutRequested
        shell.onLogoutRequested = { loggedOut = true }
        defer { shell.onLogoutRequested = previous }
        var asked: String?
        HelmConfirm.responderForTests = { request in
            asked = request.title
            return .confirm
        }
        defer { HelmConfirm.responderForTests = nil }
        shell.sidebar.onLogOut?()
        check(asked == "Log out of Grand Line?" && loggedOut, "Log Out did not confirm and lock (asked: \(asked ?? "nothing"))", &ok)
    }
}

#endif
