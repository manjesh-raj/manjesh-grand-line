// Grand Line - native macOS app.
//
// Stages 3 and 4 of the modular-shell migration: the sidebar shell
// (`MainSplitShellController`), mounted in a real off-screen window and
// driven through its own controls.
//
//   1. **Every route shows, through the one mounter, in its module.** Each of
//      the 29 destinations lands in the same `DestinationMounter` slot the
//      floating bar uses, lights its module's row and tab, and is named by
//      the crumb and the module's header.
//   2. **No page grows the window.** At the narrowest width the sidebar is
//      kept for, and at 1100 (where it steps aside), visiting every page
//      leaves the window the size it was - gotcha (13), which the content
//      column's minimum and the sidebar's collapse exist to hold. A page's
//      own column coming back (Tasks' board, ⌥⌘S on Settings) does too.
//   3. **The sidebar is the map.** A module row opens the tab it showed last,
//      it draws no pins and offers no Pin or Unpin (stage 6), sessions are
//      Console's children, ⌘⇧D reveals it, and ⌥⌘S toggles the page's own
//      column where there is one and the sidebar everywhere else.
//   4. **A module's tabs are its pages.** A tab shows its page; on the four
//      pages whose own tabs are the module's, the toolbar drives the page,
//      the page hides its own control, and a switch the page makes by itself
//      moves the toolbar's tab too.
//   5. **The toolbar carries the chrome.** The page's actions, Home's spaces,
//      the module's one action, the notifications badge from the bell's
//      store, Back and Forward, the inspector.
//   6. **Console is a module**: no header, its session strip, Quick Connect.
//   7. **Home is the captain's to arrange**: Customize hides, adds, moves and
//      resizes the real cards, keeps the result, and gets out of the way.
//   8. **The lock hides what the overlay cannot cover** - the toolbar.
//   9. **No status strip, on any module.** The captain had it removed
//      everywhere: under every module the content reaches the foot of the
//      window. What it carried is elsewhere and checked here - the live
//      sessions in Console's session strip and the sidebar, and the focus
//      timer's chip, with its ring popover, in the toolbar.
//  10. **The account menu** is Log Out only, under a rule that sets the
//      header apart from Home.
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
        let savedHome = AppSettings.shared.homeCardLayout
        defer { AppSettings.shared.homeCardLayout = savedHome }
        AppSettings.shared.homeCardLayout = .standard

        var allOK = true
        let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(shell)
        for check in [checkEveryRouteShowsThroughTheMounter, checkNoPageGrowsTheWindow,
                      checkAPageColumnNeverGrowsTheWindow, checkTheSidebarIsTheMap,
                      checkTheSidebarDrawsNoPins, checkTheMapAndTheSidebarToggle, checkModuleTabsArePages,
                      checkPageTabsAreDrivenFromTheToolbar, checkTheToolbar, checkConsoleIsAModule,
                      checkHomeIsTheCaptainsToArrange, checkBackAndForward, checkTheInspector,
                      checkTheLockHidesTheToolbar, checkTheContentReachesTheFoot, checkTheFocusChipIsInTheToolbar,
                      checkTheFocusChipFitsTheNarrowToolbar, checkOnlyADividerDragIsAChosenWidth,
                      checkToastsLandInTheColumn,
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

    /// Click the toolbar's tab with this name, through the control's own
    /// target and action, the way a real click reaches it.
    @discardableResult
    private static func clickTab(_ name: String, _ shell: MainSplitShellController) -> Bool {
        let tabs = shell.toolbar.debugTabs
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return false }
        tabs.selectedSegment = index
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        settle(shell)
        return true
    }

    private static func selectedTabName(_ shell: MainSplitShellController) -> String? {
        let tabs = shell.toolbar.debugTabs
        let names = shell.toolbar.debugTabNames
        return names.indices.contains(tabs.selectedSegment) ? names[tabs.selectedSegment] : nil
    }

    // MARK: 1 - every route

    private static func checkEveryRouteShowsThroughTheMounter(_ shell: MainSplitShellController, _ window: NSWindow,
                                                             _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for destination in RailDestination.allCases {
            shell.show(destination)
            settle(shell)
            let module = ModuleTable.module(for: destination)
            check(shell.debugCurrentDestination == destination, "\(destination.rawValue) did not show", &ok)
            let slotView = shell.destinationViewIfMountedForTests(destination.slot)
            check(slotView != nil && slotView === shell.workspace.content.visibleDestinationView(),
                  "\(destination.rawValue) is not showing its own mounter slot", &ok)
            check(slotView?.isDescendant(of: shell.debugContentPane) == true,
                  "\(destination.rawValue)'s page is not in the content column", &ok)
            check(shell.sidebar.debugSelectedEntry == .module(module),
                  "\(destination.rawValue) did not light \(module.title)'s row (lit: \(String(describing: shell.sidebar.debugSelectedEntry)))", &ok)
            check(shell.currentModule == module && window.title == module.title,
                  "the window is titled \"\(window.title)\" on \(destination.rawValue), want \"\(module.title)\"", &ok)
            check(shell.toolbar.debugCrumb.hasSuffix(module.title) && window.titleVisibility == .hidden,
                  "the crumb reads \"\(shell.toolbar.debugCrumb)\" on \(destination.rawValue)", &ok)
            // The big title, with the page's live subtitle under it - except
            // on Connections and Console, where the captain dropped it.
            let page = shell.debugSlotController(destination) as? DaylightDrillActions
            let live = page?.drillHeaderSubtitle ?? destination.drillSubtitle
            // Home has no live subtitle of its own, so its header carries the day.
            let subtitle = destination == .homeCanvas && live.isEmpty ? MainSplitShellController.homeSubtitle() : live
            if module.showsHeader {
                check(shell.debugHeader?.title == module.title && shell.debugHeader?.subtitle == subtitle,
                      "\(destination.rawValue)'s header is \(String(describing: shell.debugHeader)), want \(module.title) / \(subtitle)", &ok)
            } else {
                check(shell.debugHeader == nil, "\(module.title) draws a header the captain dropped", &ok)
            }
            // The middle of the toolbar: Home's spaces, the module's tabs with
            // this page's lit, or nothing for a module that is one page.
            let names = shell.toolbar.debugTabNames
            if module == .home {
                check(names == DaylightSpace.allCases.map(\.title), "Home's toolbar shows \(names), not its spaces", &ok)
            } else if module.drawsToolbarTabs {
                check(names == module.tabs.map(\.name), "\(module.title)'s toolbar shows \(names)", &ok)
                let lit = selectedTabName(shell).flatMap { name in module.tabs.first { $0.name == name } }
                check(lit?.route == destination,
                      "\(destination.rawValue) lit the \(String(describing: selectedTabName(shell))) tab", &ok)
            } else {
                check(names.isEmpty, "\(module.title), one page, shows tabs \(names)", &ok)
            }
        }
        // The mounter is the floating bar's, untouched: every slot mounted
        // once, and no second copy of any page.
        check(Set(shell.mountedDestinationSlotsForTests).count == DestinationSlotID.allCases.count,
              "visiting every page mounted \(Set(shell.mountedDestinationSlotsForTests).count) of \(DestinationSlotID.allCases.count) slots", &ok)
    }

    // MARK: 2 - the window keeps its size

    private static func checkNoPageGrowsTheWindow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        // The narrowest width that keeps the sidebar: its pane plus the
        // column's minimum.
        resize(window, width: 1512, shell)
        let pane = shell.debugSidebarPane?.frame.width ?? MainSplitShellController.sidebarWidth
        let narrowest = (pane + MainSplitShellController.contentMinimum).rounded(.up) + 1
        let height = window.frame.height
        for (width, sidebarShown) in [(narrowest, true), (CGFloat(1100), false)] {
            resize(window, width: width, shell)
            check(shell.debugSidebarIsCollapsed == !sidebarShown,
                  "at \(Int(width))pt the sidebar is \(shell.debugSidebarIsCollapsed ? "collapsed" : "showing")", &ok)
            for destination in RailDestination.allCases {
                shell.show(destination)
                settle(shell)
                check(abs(window.frame.width - width) < 0.5,
                      "\(destination.rawValue) grew a \(Int(width))pt window to \(Int(window.frame.width))pt", &ok)
                // The module's header takes height, so no page may push the
                // window taller to make up for it either.
                check(abs(window.frame.height - height) < 0.5,
                      "\(destination.rawValue) grew the window's height to \(Int(window.frame.height))pt", &ok)
                if abs(window.frame.width - width) >= 0.5 || abs(window.frame.height - height) >= 0.5 {
                    var frame = window.frame
                    frame.size = NSSize(width: width, height: height)
                    window.setFrame(frame, display: true)
                    settle(shell)
                }
            }
        }
        // Wide again: the sidebar comes back at the width it opened at.
        resize(window, width: 1512, shell)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5,
              "widening the window brought the sidebar back at \(shell.debugSidebarWidth)pt (collapsed: \(shell.debugSidebarIsCollapsed))", &ok)
        // The same round trip on Home, whose grid still holds the wider
        // column's widths (at 499, above the sidebar's 489) while the sidebar
        // comes back - measured: squeezed to its 200pt minimum when the
        // sidebar's pin was released in the same turn.
        shell.show(.homeCanvas)
        settle(shell)
        resize(window, width: 1100, shell)
        resize(window, width: 1512, shell)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5,
              "a 1100-to-1512 round trip on Home brought the sidebar back at \(shell.debugSidebarWidth)pt", &ok)
    }

    /// A page's own column coming back takes its room from the page, never
    /// from the window - measured before `HelmSplitPage` reopened it through
    /// constraints: Tasks' column back for the board at 1100pt grew the
    /// window to 1349 and brought the sidebar out with it.
    private static func checkAPageColumnNeverGrowsTheWindow(_ shell: MainSplitShellController, _ window: NSWindow,
                                                            _ ok: inout Bool) {
        resize(window, width: 1100, shell)
        check(shell.debugSidebarIsCollapsed, "at 1100pt the sidebar did not step aside", &ok)
        shell.show(.shift)
        settle(shell)
        clickTab("Board", shell)
        if let split = (shell.debugSlotController(.shift) as? HelmSplitPageHosting)?.splitPage {
            let column = split.debugSidebarWidth
            check(!split.isSidebarCollapsed && column > 0, "Tasks' board opened without its column", &ok)
            clickTab("Weekly review", shell)
            check(split.isSidebarCollapsed, "Weekly review left the board's column out", &ok)
            clickTab("Board", shell)
            check(!split.isSidebarCollapsed && abs(split.debugSidebarWidth - column) < 0.5,
                  "back on the board, Tasks' column is \(split.debugSidebarWidth)pt, it was \(column)pt", &ok)
            check(abs(window.frame.width - 1100) < 0.5,
                  "Tasks' column coming back grew a 1100pt window to \(Int(window.frame.width))pt", &ok)
            check(shell.debugSidebarIsCollapsed, "Tasks' column coming back brought the sidebar out too", &ok)
        } else {
            fail("Tasks has no column of its own", &ok)
        }
        // The same reopen from ⌥⌘S, on a page whose column is the captain's.
        shell.show(.settings)
        settle(shell)
        if let split = (shell.debugSlotController(.settings) as? HelmSplitPageHosting)?.splitPage {
            shell.toggleSidebarFromMenu()
            settle(shell)
            check(split.isSidebarCollapsed, "⌥⌘S did not put Settings' column away", &ok)
            shell.toggleSidebarFromMenu()
            settle(shell)
            check(!split.isSidebarCollapsed, "⌥⌘S did not bring Settings' column back", &ok)
            check(abs(window.frame.width - 1100) < 0.5,
                  "Settings' column coming back grew a 1100pt window to \(Int(window.frame.width))pt", &ok)
        } else {
            fail("Settings has no column of its own", &ok)
        }
        var frame = window.frame
        frame.size.width = 1100
        window.setFrame(frame, display: true)
        shell.show(.homeCanvas)
        resize(window, width: 1512, shell)
    }

    // MARK: 3 - the sidebar

    private static func checkTheSidebarIsTheMap(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        // A module's row reopens the tab it showed last. (Which tab a module
        // opens on before it has shown one is `primaryRoute`, which the model
        // suite checks; every module has been shown by now.)
        shell.show(.notebook)
        settle(shell)
        clickTab("Runbooks", shell)
        check(shell.sidebar.debugClick(.module(.crew)), "the Crew row is not in the sidebar", &ok)
        settle(shell)
        check(shell.currentModule == .crew, "the Crew row opened \(shell.currentModule.title)", &ok)
        check(shell.sidebar.debugClick(.module(.knowledge)), "the Knowledge row is not in the sidebar", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .runbooks,
              "Knowledge's row reopened \(String(describing: shell.debugCurrentDestination)), not the Runbooks tab it showed last", &ok)

        // A page inside a module of several lights its module's row.
        shell.show(.review)
        shell.show(.strawHat)
        settle(shell)
        check(shell.sidebar.debugSelectedEntry == .module(.crew),
              "a page reached from outside the sidebar lit \(String(describing: shell.sidebar.debugSelectedEntry))", &ok)

        // Home and every module have a visible row, under their own names.
        let entries = shell.sidebar.debugVisibleEntries
        for module in WorkspaceModule.allCases {
            check(entries.contains(.module(module)), "no visible row for \(module.title)", &ok)
        }
    }

    /// Stage 6, the captain's call: the pins are the floating bar's. With
    /// pages pinned that a Pinned section used to list (Straw Hat Pirates and
    /// Hosts, each one of several pages in its module), the sidebar draws no
    /// such section, no row's menu offers Pin or Unpin, and the saved list is
    /// left exactly as it was.
    private static func checkTheSidebarDrawsNoPins(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let pins = QuickAccessConfiguration(pinned: [.console, .strawHat, .hosts, .poneglyph])
        AppSettings.shared.quickAccess = pins
        shell.quickAccessDidChange(pins)
        shell.sessions.register(hostID: UUID(), label: "Fixture", accentHex: nil, state: .connected)
        settle(shell)
        let entries = shell.sidebar.debugVisibleEntries
        let groups = Set(WorkspaceGroup.allCases.map(\.title))
        let sections = entries.compactMap { entry -> String? in
            if case .section(let title) = entry { return title }
            return nil
        }
        check(Set(sections) == groups && sections.count == groups.count,
              "with pins set the sidebar draws the sections \(sections), want the four groups only", &ok)
        check(entries.first == .module(.home), "Home is not the first row under the header", &ok)
        for module in WorkspaceModule.allCases {
            let titles = shell.sidebar.debugContextMenuTitles(for: .module(module))
            check(!titles.contains { $0.hasPrefix("Pin ") || $0.hasPrefix("Unpin ") },
                  "\(module.title)'s menu still offers to pin: \(titles)", &ok)
            check(titles.first == "Open \(module.title)", "\(module.title)'s menu lost Open: \(titles)", &ok)
        }
        check(shell.sidebar.debugContextMenuTitles(for: .module(.console)).contains("Connect to a Host\u{2026}"),
              "Console's menu lost Connect to a Host", &ok)
        check(AppSettings.shared.quickAccess == pins, "the sidebar layout changed the floating bar's pins", &ok)
        for id in shell.sessions.sessions.map(\.hostID) { shell.sessions.unregister(hostID: id) }
        settle(shell)
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

        // On Connections the page's column is put away for the toolbar's
        // tabs, so ⌥⌘S does what it does on any page without one.
        shell.show(.hosts)
        settle(shell)
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(shell.debugSidebarIsCollapsed, "⌥⌘S on Connections did nothing", &ok)
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(!shell.debugSidebarIsCollapsed, "a second ⌥⌘S on Connections did not bring the sidebar back", &ok)
    }

    // MARK: 4 - a module's tabs

    private static func checkModuleTabsArePages(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for module in WorkspaceModule.allCases where module.drawsToolbarTabs {
            shell.show(module.primaryRoute)
            settle(shell)
            for tab in module.tabs {
                check(clickTab(tab.name, shell), "\(module.title)'s toolbar has no \(tab.name) tab", &ok)
                check(shell.debugCurrentDestination == tab.route,
                      "\(module.title) › \(tab.name) showed \(String(describing: shell.debugCurrentDestination))", &ok)
                check(selectedTabName(shell) == tab.name && shell.debugCurrentTab == tab,
                      "\(module.title) › \(tab.name) left \(String(describing: selectedTabName(shell))) lit", &ok)
                if tab.isPageTab {
                    let host = shell.debugSlotController(tab.route) as? ModuleTabHosting
                    check(host?.selectedModuleTabName == tab.name,
                          "\(module.title) › \(tab.name) left the page on \(host?.selectedModuleTabName ?? "nothing")", &ok)
                }
            }
        }
        // A deep link to a page lands on its tab; the page keeps the tab of
        // its own it last showed.
        shell.show(.hosts)
        settle(shell)
        clickTab("Keys", shell)
        shell.show(.review)
        shell.show(.hosts)
        settle(shell)
        check(selectedTabName(shell) == "Keys", "returning to Hosts lit \(String(describing: selectedTabName(shell))), not Keys", &ok)
        clickTab("Hosts", shell)
    }

    private static func checkPageTabsAreDrivenFromTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                            _ ok: inout Bool) {
        // Each page's own tabs are its module's, name for name.
        for module in WorkspaceModule.allCases {
            guard let route = module.pageTabHost else { continue }
            shell.show(route)
            settle(shell)
            guard let host = shell.debugSlotController(route) as? ModuleTabHosting else {
                fail("\(route.rawValue) draws \(module.title)'s tabs but is not a ModuleTabHosting page", &ok)
                continue
            }
            check(host.moduleTabNames == module.tabs.filter(\.isPageTab).map(\.name),
                  "\(route.rawValue)'s own tabs are \(host.moduleTabNames), \(module.title)'s are \(module.tabs.map(\.name))", &ok)
        }
        // The page's own control is put away while the toolbar draws it...
        if let shift = shell.debugSlotController(.shift) as? ShiftController {
            check(shift.debugViewTabs.isHidden, "Tasks still draws its own view switcher under the toolbar's tabs", &ok)
            // ...and a switch the page makes by itself moves the toolbar's tab.
            shell.show(.shift)
            settle(shell)
            shift.showWeeklyReview()
            settle(shell)
            check(selectedTabName(shell) == "Weekly review",
                  "Tasks switched to Weekly review but the toolbar lit \(String(describing: selectedTabName(shell)))", &ok)
            shift.showDashboard()
            settle(shell)
        } else {
            fail("Tasks did not mount", &ok)
        }
        if let fleet = shell.debugSlotController(.overview) as? FleetController {
            check(fleet.debugTabsAreHidden, "the Fleet page still draws its own tabs under Crew's", &ok)
            shell.openFleetLog()
            settle(shell)
            check(shell.currentModule == .crew && selectedTabName(shell) == "Log",
                  "opening the captain's log lit \(String(describing: selectedTabName(shell))) in \(shell.currentModule.title)", &ok)
        }
        if let hosts = shell.debugSlotController(.hosts) as? HostsController {
            check(hosts.splitPage?.pageForcesCollapse == true && hosts.splitPage?.isSidebarCollapsed == true,
                  "the Hosts page's own column is still out beside Connections' tabs", &ok)
        }
        if let kubernetes = shell.debugSlotController(.kubernetes) as? KubernetesController {
            check(kubernetes.pageTabs.isHidden, "Kubernetes still draws its own Cluster and Log Tail tabs", &ok)
        }
    }

    // MARK: 5 - the toolbar

    private static func checkTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        // The page's own actions are the page's views, moved into the toolbar.
        shell.show(.hosts)
        settle(shell)
        // Stage 6: Hosts' one action is its primary one, the page's own
        // button at the toolbar's far right rather than among the others.
        let hostsActions = (shell.debugSlotController(.hosts) as? DaylightDrillActions)?.drillHeaderActions ?? []
        check(hostsActions.count == 1, "the Hosts page offers \(hostsActions.count) actions - this check assumes its one add button", &ok)
        check(shell.toolbar.debugPrimaryAction === hostsActions.first && shell.toolbar.debugPageActions.isEmpty,
              "the toolbar is not carrying Hosts' own action as its primary one", &ok)
        // A hidden primary button leaves no empty capsule, and comes back.
        hostsActions.first?.isHidden = true
        check(!shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.primaryAction),
              "with Hosts' button hidden the toolbar still holds its primary item", &ok)
        hostsActions.first?.isHidden = false
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.primaryAction),
              "showing Hosts' button again did not bring the primary item back", &ok)
        // A page with other actions too (Health's Refresh): those are the
        // page-actions item, which follows its buttons the same way.
        shell.show(.health)
        settle(shell)
        let healthActions = (shell.debugSlotController(.health) as? DaylightDrillActions)?.drillHeaderActions ?? []
        let others = healthActions.filter { $0 !== shell.toolbar.debugPrimaryAction }
        check(!others.isEmpty && shell.toolbar.debugPageActions.map(ObjectIdentifier.init) == others.map(ObjectIdentifier.init),
              "the toolbar is not carrying Health's own actions", &ok)
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "the page-actions item is not in the toolbar", &ok)
        let wasHidden = others.map(\.isHidden)
        others.forEach { $0.isHidden = true }
        check(!shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "with every Health button hidden the toolbar still holds an actions item", &ok)
        zip(others, wasHidden).forEach { $0.isHidden = $1 }
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "showing Health's buttons again did not bring the actions item back", &ok)
        shell.show(.hosts)
        settle(shell)
        // Connections' Activity: the captain's log, which the Hosts page's
        // column linked to before the toolbar's tabs replaced it.
        check(shell.toolbar.debugModuleActionButton?.title == "Activity", "Connections offers no Activity button", &ok)
        shell.debugModuleAction()
        settle(shell)
        check(shell.debugCurrentDestination == .overview && selectedTabName(shell) == "Log",
              "Activity opened \(String(describing: shell.debugCurrentDestination)), not Crew › Log", &ok)

        shell.show(.homeCanvas)
        settle(shell)
        check(shell.toolbar.debugPageActions.isEmpty
                && !shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "Home still shows the previous page's actions", &ok)
        // Home's spaces filter its cards, as the pills did.
        check(clickTab(DaylightSpace.operations.title, shell), "Home's toolbar has no Operations space", &ok)
        check(shell.debugHomeCanvas.selectedSpace == .operations, "the toolbar's spaces did not filter Home", &ok)
        clickTab(DaylightSpace.overview.title, shell)
        check(shell.debugHomeCanvas.selectedSpace == .overview, "the Home space did not come back", &ok)

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

        // Narrow, the prototype's compact toolbar: Search is its glyph, and
        // when room still runs out the crumb, Recents and the inspector
        // toggle overflow first - never Search, the bell or the toggle.
        resize(window, width: 1100, shell)
        check(shell.toolbar.debugIsCompact, "at 1100 the toolbar is not compact", &ok)
        resize(window, width: 1512, shell)
        check(!shell.toolbar.debugIsCompact, "at 1512 the toolbar is still compact", &ok)
        let items = shell.toolbar.toolbar.items
        func priority(_ id: NSToolbarItem.Identifier) -> NSToolbarItem.VisibilityPriority? {
            items.first { $0.itemIdentifier == id }?.visibilityPriority
        }
        for id in [WorkspaceToolbar.ItemID.search, WorkspaceToolbar.ItemID.notifications, WorkspaceToolbar.ItemID.theme] {
            check(priority(id) == .high, "\(id.rawValue) can overflow before the crumb", &ok)
        }
        for id in [WorkspaceToolbar.ItemID.crumb, WorkspaceToolbar.ItemID.recents, WorkspaceToolbar.ItemID.inspector] {
            check(priority(id) == .low, "\(id.rawValue) is not among the first to overflow", &ok)
        }
        check(items.first { $0.itemIdentifier == WorkspaceToolbar.ItemID.recents }?.menuFormRepresentation?.action != nil,
              "Recents does nothing from the overflow menu", &ok)

        // The light/dark toggle flips the theme within its family.
        let before = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(before) }
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.theme), "the light/dark item has no action", &ok)
        check(ThemeManager.shared.theme.mode != before.mode, "the light/dark item did not flip the appearance", &ok)
    }

    // MARK: 6 - Console

    private static func checkConsoleIsAModule(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let host = UUID()
        shell.sessions.register(hostID: host, label: "DEV Bastion", accentHex: nil, state: .connected)
        defer {
            shell.sessions.unregister(hostID: host)
            settle(shell)
        }
        shell.show(.console)
        settle(shell)
        check(shell.debugHeader == nil && shell.toolbar.debugCrumb.hasSuffix("Console"),
              "Console draws a header, or the crumb reads \"\(shell.toolbar.debugCrumb)\"", &ok)
        check(shell.debugSessionStripIsShown, "Console has a live session but no session strip", &ok)
        check(shell.sidebar.debugSelectedEntry == .module(.console), "the Console row is not lit", &ok)
        // The strip is Console's: no other module carries it.
        shell.show(.review)
        settle(shell)
        check(!shell.debugSessionStripIsShown, "the session strip followed the captain out of Console", &ok)
        // Quick Connect: Hosts' own quick-connect field.
        shell.show(.console)
        settle(shell)
        check(shell.toolbar.debugModuleActionButton?.title == "Quick Connect", "Console offers no Quick Connect", &ok)
        shell.debugModuleAction()
        settle(shell)
        check(shell.debugCurrentDestination == .hosts && shell.currentModule == .connections,
              "Quick Connect opened \(String(describing: shell.debugCurrentDestination))", &ok)
    }

    // MARK: 7 - Home's cards

    private static func checkHomeIsTheCaptainsToArrange(_ shell: MainSplitShellController, _ window: NSWindow,
                                                       _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        AppSettings.shared.homeCardLayout = .standard
        shell.debugHomeCanvas.cardLayout = .standard
        shell.show(.homeCanvas)
        settle(shell)
        let canvas = shell.debugHomeCanvas
        check(canvas.visibleModulesForTests == HomeCardLayout.standard.shown && !canvas.usesDashboardLayoutForTests,
              "Home shows \(canvas.visibleModulesForTests.map(\.rawValue)), not its arranged cards", &ok)
        check(shell.toolbar.debugModuleActionButton?.title == "Customize", "Home offers no Customize", &ok)
        // Claude's card carries a header action (Refresh), which the arranging
        // controls once let show under them.
        check(canvas.cardForTests(.claudeStatus)?.debugHeaderActionFrameInCard != nil,
              "Claude's card has no header action, so the check on its arranging controls is vacuous", &ok)
        let headerHeight = canvas.cardForTests(.claudeStatus)?.debugHeaderGeometry?.row.height ?? 0

        // Customize: the tray, and controls on every card.
        shell.debugModuleAction()
        settle(shell)
        check(canvas.isCustomizing && canvas.customizeTrayForTests != nil
                && shell.toolbar.debugModuleActionButton?.title == "Done",
              "Customize did not open (tray: \(canvas.customizeTrayForTests != nil))", &ok)
        check(Set(canvas.cardStripsForTests.keys) == Set(HomeCardLayout.standard.shown),
              "not every card wears its controls in Customize", &ok)
        // Each strip keeps its own width, on a large card too, so the title
        // takes the header's spare room.
        for (module, strip) in canvas.cardStripsForTests {
            check(abs(strip.frame.width - strip.fittingSize.width) < 1,
                  "\(module.rawValue)'s controls are \(strip.frame.width)pt wide, their own width is \(strip.fittingSize.width)pt", &ok)
        }
        // The controls take the header's trailing place rather than covering
        // it: the card's own action is put away, and the controls sit in the
        // header row beside the title.
        if let claude = canvas.cardForTests(.claudeStatus) {
            check(claude.debugHeaderActionFrameInCard == nil, "Claude's Refresh still shows under Customize's controls", &ok)
            if let header = claude.debugHeaderGeometry, let controls = claude.debugHeaderAccessoryFrameInCard {
                check(header.row.insetBy(dx: -0.5, dy: -0.5).contains(controls) && !controls.intersects(header.text),
                      "Customize's controls on Claude's card sit at \(controls), outside its header row \(header.row) "
                      + "or over its title \(header.text)", &ok)
                check(abs(header.row.height - headerHeight) < 0.5,
                      "Claude's header is \(header.row.height)pt while arranged and \(headerHeight)pt otherwise", &ok)
            } else {
                fail("Claude's card has no arranging controls in its header", &ok)
            }
        } else {
            fail("Claude's card is not on Home in Customize", &ok)
        }
        // A card does not navigate while it is being arranged.
        let open = shell.debugCurrentDestination
        canvas.cardForTests(.fleet)?.onOpen?()
        check(shell.debugCurrentDestination == open, "a card click navigated away from Customize", &ok)

        // Hide, through the card's own button.
        guard let first = HomeCardLayout.standard.shown.first, let strip = canvas.cardStripsForTests[first] else {
            fail("the first card has no controls - the rest is vacuous", &ok)
            return
        }
        strip.debugHideButton.performClick(nil)
        settle(shell)
        check(!canvas.visibleModulesForTests.contains(first) && canvas.cardForTests(first) == nil,
              "hiding \(first.rawValue) left it on Home", &ok)
        check(!AppSettings.shared.homeCardLayout.shown.contains(first), "the hidden card was not kept", &ok)
        check(canvas.customizeTrayForTests?.hiddenCards.contains(first) == true, "the tray does not offer the hidden card back", &ok)

        // Add it back, from the tray's own menu.
        if let tray = canvas.customizeTrayForTests {
            let menu = tray.addMenu()
            if let index = menu.items.firstIndex(where: { $0.title == first.title }) {
                menu.performActionForItem(at: index)
            }
        }
        settle(shell)
        check(canvas.visibleModulesForTests.last == first, "adding \(first.rawValue) back did not put it at the end", &ok)

        // Full width: the card spans the grid.
        if let strip = canvas.cardStripsForTests[first] {
            let menu = strip.sizeMenu()
            if let index = menu.items.firstIndex(where: { $0.title == HomeCardLayout.Size.wide.title }) {
                menu.performActionForItem(at: index)
            }
        }
        settle(shell)
        let widths = canvas.gridRowsForTests.map(\.frame.width)
        if let card = canvas.cardForTests(first), let widest = widths.max() {
            check(abs(card.frame.width - widest) < 1, "a full-width card is \(card.frame.width)pt in a \(widest)pt grid", &ok)
        } else {
            fail("the resized card is not on Home", &ok)
        }
        check(AppSettings.shared.homeCardLayout.size(of: first) == .wide, "the card's size was not kept", &ok)

        // Move earlier, through its button.
        let before = canvas.visibleModulesForTests
        canvas.cardStripsForTests[first]?.debugEarlierButton.performClick(nil)
        settle(shell)
        let after = canvas.visibleModulesForTests
        check(after.count == before.count && after.last != first && after.firstIndex(of: first) == before.count - 2,
              "moving \(first.rawValue) earlier gave \(after.map(\.rawValue))", &ok)

        // Done, from the toolbar: the controls go, the arrangement stays.
        shell.debugModuleAction()
        settle(shell)
        check(!canvas.isCustomizing && canvas.customizeTrayForTests == nil && canvas.cardStripsForTests.isEmpty,
              "Done left Customize's controls on Home", &ok)
        check(canvas.visibleModulesForTests == after, "Done changed the arrangement", &ok)
        check(canvas.cardForTests(.claudeStatus)?.debugHeaderActionFrameInCard != nil,
              "Done did not give Claude's card its Refresh back", &ok)

        // Reset brings Home's own set back.
        shell.debugModuleAction()
        settle(shell)
        canvas.customizeTrayForTests?.debugResetButton.performClick(nil)
        settle(shell)
        check(canvas.visibleModulesForTests == HomeCardLayout.standard.shown && AppSettings.shared.homeCardLayout == .standard,
              "Reset left \(canvas.visibleModulesForTests.map(\.rawValue))", &ok)
        // Leaving Home's own space ends Customize.
        clickTab(DaylightSpace.stores.title, shell)
        check(!canvas.isCustomizing && shell.toolbar.debugModuleActionButton?.title == "Customize",
              "switching to Stores kept Customize on", &ok)
        clickTab(DaylightSpace.overview.title, shell)
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

    // MARK: 8 - the lock

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
        check(window.toolbar?.isVisible == false && window.title == AppPaths.displayName,
              "with the lock up the toolbar shows, or the window is titled \"\(window.title)\"", &ok)
        overlay(false)
        check(window.toolbar?.isVisible == true && window.title == WorkspaceModule.connections.title,
              "the toolbar and the module's name did not come back after the lock (\"\(window.title)\")", &ok)
    }

    // MARK: 9 - no status strip

    private static func checkTheContentReachesTheFoot(_ shell: MainSplitShellController, _ window: NSWindow,
                                                      _ ok: inout Bool) {
        // The captain: "Yes have this removed everywhere". Every module, so a
        // strip that came back under one of them fails by name.
        let pane = shell.debugContentPane
        let body = shell.debugBodyContainer
        let foot = pane.isFlipped ? pane.bounds.maxY : pane.bounds.minY
        // The pane itself must reach the window's foot, or the body reaching
        // the pane's would prove nothing.
        let paneInWindow = pane.convert(pane.bounds, to: nil)
        check(paneInWindow.minY.magnitude < 0.5, "the content pane stops \(paneInWindow.minY)pt above the window's foot", &ok)
        for module in WorkspaceModule.allCases {
            shell.debugOpenModule(module)
            settle(shell)
            let frame = body.convert(body.bounds, to: pane)
            let bodyFoot = pane.isFlipped ? frame.maxY : frame.minY
            check(abs(bodyFoot - foot) < 0.5,
                  "under \(module.title) the body stops \(abs(bodyFoot - foot))pt from the window's foot", &ok)
        }
        // Knowledge's tree is the one column beside the body; it runs down
        // as far.
        shell.show(.notebook)
        settle(shell)
        let column = shell.debugLeadingColumnHost
        let columnFrame = column.convert(column.bounds, to: pane)
        check(!column.isHidden && abs((pane.isFlipped ? columnFrame.maxY : columnFrame.minY) - foot) < 0.5,
              "Knowledge's tree stops short of the window's foot (\(columnFrame))", &ok)

        // The live sessions the strip counted are Console's: its session
        // strip lists each one, connected or restored, and so does the
        // sidebar under Console.
        let live = UUID()
        let restored = UUID()
        shell.sessions.register(hostID: live, label: "DEV Bastion", accentHex: nil, state: .connected)
        shell.sessions.register(hostID: restored, label: "PROD Web", accentHex: nil, state: .restored)
        shell.show(.console)
        settle(shell)
        check(shell.debugSessionStripIsShown && shell.debugSessionStrip.debugPillHostIDs() == [live, restored],
              "Console's session strip lists \(shell.debugSessionStrip.debugPillHostIDs()), want both sessions", &ok)
        let entries = shell.sidebar.debugVisibleEntries
        if let console = entries.firstIndex(of: .module(.console)) {
            check(Array(entries.dropFirst(console + 1).prefix(2)) == [.session(hostID: live), .session(hostID: restored)],
                  "the sessions are not listed under Console", &ok)
        } else {
            fail("Console is not in the sidebar", &ok)
        }
        shell.sessions.unregister(hostID: live)
        shell.sessions.unregister(hostID: restored)
        settle(shell)
        check(!shell.debugSessionStripIsShown, "Console's session strip stayed with no sessions", &ok)
    }

    private static func checkTheFocusChipIsInTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                        _ ok: inout Bool) {
        let toolbar = shell.toolbar!
        shell.show(.homeCanvas)
        settle(shell)
        check(!toolbar.debugFocusChipIsShown, "the toolbar shows a focus chip with no timer running", &ok)
        var task = ShiftTask.fresh()
        task.title = "Rotate the staging certificate"
        shell.focusTimer.start(task: task)
        settle(shell)
        let chip = toolbar.debugFocusChip
        guard toolbar.debugFocusChipIsShown else {
            fail("a running timer put no chip in the toolbar", &ok)
            _ = shell.focusTimer.stop()
            return
        }
        check(chip.debugTitleText == task.title && chip.debugCountdownText == "25:00",
              "a running timer put \"\(chip.debugCountdownText) \(chip.debugTitleText)\" in the toolbar", &ok)
        let ids = toolbar.debugItemIdentifiers
        let focus = ids.firstIndex(of: WorkspaceToolbar.ItemID.focusTimer)
        check(focus.map { $0 + 1 } == ids.firstIndex(of: WorkspaceToolbar.ItemID.theme),
              "the chip is not just before the trailing cluster: \(ids.map(\.rawValue))", &ok)
        // On every module, Console included - the strip never showed it
        // there - and still beside the trailing cluster after a module's own
        // action has come and gone around it.
        for route in [RailDestination.console, .health, .notebook, .homeCanvas] {
            shell.show(route)
            settle(shell)
            check(toolbar.debugFocusChipIsShown, "the focus chip is not in the toolbar under \(route.rawValue)", &ok)
            let ids = toolbar.debugItemIdentifiers
            check(ids.firstIndex(of: WorkspaceToolbar.ItemID.focusTimer).map { $0 + 1 } == ids.firstIndex(of: WorkspaceToolbar.ItemID.theme),
                  "under \(route.rawValue) the chip is not just before the trailing cluster: \(ids.map(\.rawValue))", &ok)
        }
        // Through its own click recognizer, which is what Return, Space and
        // VoiceOver's press reach too (`HoverHighlightView`).
        check(chip.performPrimaryAction(), "the focus chip has no click", &ok)
        check(shell.debugFocusPopoverIsShown, "clicking the focus chip opened no ring popover", &ok)
        check(chip.performPrimaryAction() && !shell.debugFocusPopoverIsShown, "a second click left the popover open", &ok)
        _ = chip.performPrimaryAction()
        _ = shell.focusTimer.stop()
        settle(shell)
        check(!toolbar.debugFocusChipIsShown, "the chip stayed in the toolbar after the timer stopped", &ok)
        check(!shell.debugFocusPopoverIsShown, "the ring popover stayed open after the timer stopped", &ok)
    }

    /// The sidebar's remembered width changes only on a drag in this window.
    /// The predicate used to be the machine's mouse button, so a button held
    /// anywhere while the panes resized recorded a squeezed sidebar as the
    /// captain's choice - the "came back at 200pt" flake in
    /// `checkNoPageGrowsTheWindow`, about one run in ten.
    private static func checkOnlyADividerDragIsAChosenWidth(_ shell: MainSplitShellController, _ window: NSWindow,
                                                           _ ok: inout Bool) {
        func event(_ type: NSEvent.EventType, in target: NSWindow?) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 240, y: 300), modifierFlags: [], timestamp: 0,
                               windowNumber: target?.windowNumber ?? 0, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)
        }
        let other = OffScreenProbe.window(width: 400, height: 300)
        defer { other.close() }
        check(MainSplitShellController.isDividerDrag(event(.leftMouseDragged, in: window), in: window),
              "a drag in the shell's window is not taken as a divider drag", &ok)
        check(!MainSplitShellController.isDividerDrag(nil, in: window),
              "a resize with no event (a mouse held anywhere else) counts as a divider drag", &ok)
        check(!MainSplitShellController.isDividerDrag(event(.leftMouseDragged, in: other), in: window),
              "a drag in another window counts as a divider drag", &ok)
        check(!MainSplitShellController.isDividerDrag(event(.leftMouseDown, in: window), in: window),
              "a mouse-down counts as a divider drag", &ok)
    }

    /// At 1100 the narrow toolbar drops the chip's task name, and a running
    /// timer never pushes the page's own actions into the overflow menu -
    /// measured on Knowledge, whose five tabs leave the least room.
    private static func checkTheFocusChipFitsTheNarrowToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                               _ ok: inout Bool) {
        let toolbar = shell.toolbar!
        let width = window.frame.width
        defer { resize(window, width: width, shell) }
        resize(window, width: 1100, shell)
        shell.show(.notebook)
        settle(shell)
        let actionsAlone = toolbar.debugPageActions.first?.window != nil
        var task = ShiftTask.fresh()
        task.title = "Rotate the staging certificate"
        shell.focusTimer.start(task: task)
        settle(shell)
        defer { _ = shell.focusTimer.stop() }
        let chip = toolbar.debugFocusChip
        check(toolbar.debugIsCompact && !chip.debugTitleIsShown && chip.toolTip?.contains(task.title) == true,
              "at 1100 the chip still names its task, or its tooltip does not", &ok)
        // The fixture can fail: the page's actions fit at 1100 without a
        // timer, or there is nothing to push out.
        check(actionsAlone, "Knowledge's actions are already in the overflow at 1100 with no timer", &ok)
        check(toolbar.debugPageActions.first?.window != nil,
              "at 1100 a running timer pushed Knowledge's actions into the toolbar's overflow menu", &ok)
        // Where even the compact chip leaves no room, it is the chip that
        // yields, and its overflow item still opens the ring popover.
        if chip.window == nil {
            check(toolbar.debugPerformFocusChipMenuForm() && shell.debugFocusPopoverIsShown,
                  "with the chip in the overflow menu its item opened no ring popover", &ok)
            _ = toolbar.debugPerformFocusChipMenuForm()
        }
        // On a module with room, the compact chip is in the toolbar beside
        // the page's actions.
        shell.show(.health)
        settle(shell)
        check(chip.window != nil && toolbar.debugPageActions.first?.window != nil,
              "at 1100 on Health the compact chip or the page's actions went to the overflow menu", &ok)
        resize(window, width: 1512, shell)
        check(chip.debugTitleIsShown, "at 1512 the chip does not name its task", &ok)
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
        // Stage 6: Log Out only. Settings is its own sidebar row.
        check(shell.sidebar.debugAccountMenuTitles == ["Log Out\u{2026}"],
              "the account menu offers \(shell.sidebar.debugAccountMenuTitles), want Log Out only", &ok)
        check(shell.sidebar.debugVisibleEntries.contains(.module(.settings)), "Settings has no sidebar row to replace the menu's", &ok)
        check(shell.sidebar.debugClick(.module(.settings)), "the Settings row cannot be clicked", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .settings, "the Settings row did not open Settings", &ok)
        // A rule, with room either side, between the header and Home.
        let root = shell.sidebar.view
        root.layoutSubtreeIfNeeded()
        let header = shell.sidebar.debugHeader.convert(shell.sidebar.debugHeader.bounds, to: root)
        let rule = shell.sidebar.debugHeaderRule.convert(shell.sidebar.debugHeaderRule.bounds, to: root)
        // The list's top, which is where Home sits until the list scrolls.
        guard let list = shell.sidebar.outlineView.enclosingScrollView else {
            fail("the sidebar list has no scroll view", &ok)
            return
        }
        let listFrame = list.convert(list.bounds, to: root)
        let gapAbove = root.isFlipped ? rule.minY - header.maxY : header.minY - rule.maxY
        let gapBelow = root.isFlipped ? listFrame.minY - rule.maxY : rule.minY - listFrame.maxY
        check(rule.height == 1 && rule.width > header.width * 0.8,
              "the header rule is \(rule.size), want a 1pt line across the sidebar", &ok)
        check(gapAbove >= WorkspaceSidebarController.headerRuleGap - 0.5 && gapBelow >= WorkspaceSidebarController.headerRuleGap - 0.5,
              "the rule sits \(gapAbove)pt under the header and \(gapBelow)pt over Home, want at least \(WorkspaceSidebarController.headerRuleGap) each", &ok)
        check(shell.sidebar.debugHeaderRule.layer?.backgroundColor != nil, "the header rule is not painted", &ok)
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
        check(shell.sidebar.debugPerformAccountMenuItem("Log Out\u{2026}"), "the account menu has no Log Out", &ok)
        check(asked == "Log out of Grand Line?" && loggedOut, "Log Out did not confirm and lock (asked: \(asked ?? "nothing"))", &ok)
    }
}

#endif
