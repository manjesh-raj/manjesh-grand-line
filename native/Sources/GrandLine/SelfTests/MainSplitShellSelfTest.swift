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
//      own column coming back (Notebook's Pages, ⌥⌘S on Settings) does too.
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
                      checkHomeIsTheCaptainsToArrange, checkBackAndForward, checkTheCalendarButton, checkTheInspector,
                      checkTheInspectorIsTheSystemsItem, checkTheToolbarIsCustomisable,
                      checkTheLockHidesTheToolbar, checkTheContentReachesTheFoot, checkTheFocusChipIsInTheToolbar,
                      checkTheFocusChipFitsTheNarrowToolbar, checkOnlyADividerDragIsAChosenWidth,
                      checkToastsLandInTheColumn,
                      checkTheAccountMenu, checkNotebookLeavesTheToolbarRoomAtNarrowWidths] {
            var ok = true
            check(shell, window, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "MainSplitShellSelfTest: all checks passed" : "MainSplitShellSelfTest: FAILED")
        return allOK
    }

    // MARK: R2-BUG-07 - Notebook's toolbar at 1100

    /// At 1100 Notebook's two labelled toolbar actions (222pt) pushed the
    /// crumb, Recents and the inspector button into the overflow menu. Below
    /// `NotebookController.compactToolbarActionsBelow` they draw as icons
    /// and all three stay on the toolbar; at 1512 they keep their labels.
    private static func checkNotebookLeavesTheToolbarRoomAtNarrowWidths(_ shell: MainSplitShellController,
                                                                       _ window: NSWindow, _ ok: inout Bool) {
        shell.workspace.navigator.show(.notebook)
        resize(window, width: 1100, shell)
        settle(shell)
        let notebook = shell.workspace.notebook
        // What R2-BUG-07 kept on the toolbar, as far as Knowledge's five tabs
        // (422pt) leave room for it now that R2-UX-06 moved Notebook's own
        // toolbar row up here and U-02 put Quick Connect on every module: the
        // crumb, which is the module's one name (R2-UX-05), at every width,
        // and Recents and the inspector button from 1700. Whatever does not
        // fit runs from the overflow menu - checked item by item below, and
        // the page's own controls through their menu form.
        func shown(_ wanted: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
            let visible = Set((window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
            return wanted.filter { visible.contains($0) }
        }
        func overflowRuns(_ width: Int) {
            let visible = Set((window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
            for item in window.toolbar?.items ?? [] where !visible.contains(item.itemIdentifier)
                && item.itemIdentifier != .sidebarTrackingSeparator && item.itemIdentifier != .flexibleSpace
                && item.itemIdentifier != .space {
                // An image item runs its own action from the overflow menu. A
                // view item needs a form of its own: AppKit synthesises one
                // that sends `_standardCustomMenuFormRepresentationClicked:`
                // back to the item, which for a view item runs nothing
                // (measured), so only a submenu or a real target counts.
                let form = item.menuFormRepresentation
                let realTarget = form?.target.map { !($0 is NSToolbarItem) } ?? false
                let runs = item.view == nil ? item.action != nil
                    : (form?.submenu != nil || (realTarget && form?.action != nil))
                check(runs, "at \(width) on Notebook \(item.itemIdentifier.rawValue) overflowed with nothing to run", &ok)
            }
        }
        let crumb = [WorkspaceToolbar.ItemID.crumb]
        // R2-UX-10: at 1100 the sidebar now stays beside Notebook, which
        // leaves the toolbar about 250pt less. Its selection names the
        // module, so the crumb is the item that yields - and it still runs
        // from the overflow menu (it shows the place in the sidebar).
        check(!shell.debugSidebarIsCollapsed, "R2-UX-10: at 1100 the sidebar is not beside Notebook", &ok)
        check(notebook.debugToolbarActionTitles == ["", ""],
              "R2-BUG-07: at 1100 Notebook's toolbar actions read \(notebook.debugToolbarActionTitles), want icons", &ok)
        overflowRuns(1100)
        // R2-BUG-07's own state, a full-width toolbar at 1100 with the
        // sidebar put away: the crumb stays on the toolbar.
        shell.toggleWorkspaceSidebar()
        settle(shell)
        check(shell.debugSidebarIsCollapsed, "the sidebar toggle did not put the sidebar away", &ok)
        check(shown(crumb) == crumb, "R2-BUG-07: at 1100 on Notebook, sidebar away, the crumb is not on the toolbar", &ok)
        overflowRuns(1100)
        shell.toggleWorkspaceSidebar()
        settle(shell)
        check(abs(window.frame.width - 1100) < 0.5 || !shell.debugSidebarIsCollapsed,
              "bringing the sidebar back at 1100 on Notebook left it away", &ok)
        resize(window, width: 1100, shell)
        check(shell.toolbar.debugPageActionsMenuTitles == ["View", "Today's note", "More"],
              "Notebook's page actions overflow as \(shell.toolbar.debugPageActionsMenuTitles)", &ok)
        // At 1512 too, since U-02 and U-03 (`compactToolbarActionsBelow`).
        resize(window, width: 1512, shell)
        settle(shell)
        check(notebook.debugToolbarActionTitles == ["", ""],
              "R2-BUG-07: at 1512 Notebook's toolbar actions read \(notebook.debugToolbarActionTitles), want icons", &ok)
        check(shown(crumb) == crumb, "at 1512 on Notebook the crumb is not on the toolbar", &ok)
        overflowRuns(1512)
        let all = [WorkspaceToolbar.ItemID.crumb, WorkspaceToolbar.ItemID.recents, WorkspaceToolbar.ItemID.inspector]
        resize(window, width: 1700, shell)
        settle(shell)
        check(notebook.debugToolbarActionTitles == ["Today's note", "New page"],
              "R2-BUG-07: at 1700 Notebook's toolbar actions read \(notebook.debugToolbarActionTitles)", &ok)
        check(shown(all) == all, "at 1700 on Notebook the toolbar shows \(shown(all).map(\.rawValue))", &ok)
        resize(window, width: 1512, shell)
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
            shell.workspace.navigator.show(destination)
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
            // The middle of the toolbar: the module's tabs with this page's
            // lit, or nothing for a module that is one page - and nothing for
            // Home, whose five spaces were a second map of the app (R2-UX-02).
            let names = shell.toolbar.debugTabNames
            if module == .home {
                check(names.isEmpty, "Home's toolbar still shows tabs \(names) (R2-UX-02 retired its spaces)", &ok)
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
        let height = window.frame.height
        func holds(_ width: CGFloat, _ what: String) {
            check(abs(window.frame.width - width) < 0.5,
                  "\(what) grew a \(Int(width))pt window to \(Int(window.frame.width))pt", &ok)
            // The module's header takes height, so no page may push the
            // window taller to make up for it either.
            check(abs(window.frame.height - height) < 0.5,
                  "\(what) grew the window's height to \(Int(window.frame.height))pt", &ok)
            if abs(window.frame.width - width) >= 0.5 || abs(window.frame.height - height) >= 0.5 {
                var frame = window.frame
                frame.size = NSSize(width: width, height: height)
                window.setFrame(frame, display: true)
                settle(shell)
            }
        }
        // R2-UX-10: every page at the narrowest width that keeps the sidebar
        // beside its own floor, and just under it, where the sidebar steps
        // aside for that page only. A floor set too low fails here, because
        // the page then grows the window (gotcha (13)).
        for destination in RailDestination.allCases {
            resize(window, width: 1512, shell)
            shell.workspace.navigator.show(destination)
            settle(shell)
            let keep = shell.debugNarrowestWidthKeepingSidebar.rounded(.up) + 1
            for (width, sidebarShown) in [(keep, true), (keep - 3, false)] {
                resize(window, width: width, shell)
                check(shell.debugSidebarIsCollapsed == !sidebarShown,
                      "\(destination.rawValue) at \(Int(width))pt: the sidebar is \(shell.debugSidebarIsCollapsed ? "collapsed" : "showing")", &ok)
                holds(width, destination.rawValue)
            }
        }

        // What R2-UX-10 is for, in both palettes: at a laptop's 1100pt the
        // sidebar stays beside every page except the two that keep the old
        // floor, and at 1280 beside every page. Navigating there and back
        // never grows the window either.
        let wide: Set<RailDestination> = [.logAnalyzer, .commandLibrary]
        let themeBefore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(themeBefore) }
        for palette in [HelmTheme.allThemes.first { $0.isDaylight }, HelmTheme.allThemes.first { $0.id == "dusk" }] {
            guard let palette else { fail("a palette for the 1100/1280 sweep is missing", &ok); continue }
            ThemeManager.shared.setTheme(palette)
            for width: CGFloat in [1100, 1280] {
                resize(window, width: width, shell)
                var collapsedOn: [String] = []
                for destination in RailDestination.allCases {
                    shell.workspace.navigator.show(destination)
                    settle(shell)
                    holds(width, "\(destination.rawValue) in \(palette.id) at \(Int(width))")
                    if shell.debugSidebarIsCollapsed { collapsedOn.append(destination.rawValue) }
                }
                let expected = width < 1200 ? wide.map(\.rawValue).sorted() : []
                check(collapsedOn.sorted() == expected,
                      "R2-UX-10: in \(palette.id) at \(Int(width))pt the sidebar stepped aside on \(collapsedOn.sorted()), want \(expected)", &ok)
            }
        }
        // Tasks' Weekly review is the one tab wider than its page: at 1100
        // it puts the sidebar away, and the other tabs bring it back.
        resize(window, width: 1100, shell)
        shell.workspace.navigator.show(.shift)
        settle(shell)
        clickTab("Board", shell)
        settle(shell)
        check(!shell.debugSidebarIsCollapsed, "R2-UX-10: at 1100 Tasks' Board has no sidebar beside it", &ok)
        clickTab("Weekly review", shell)
        settle(shell)
        check(shell.debugSidebarIsCollapsed, "R2-UX-10: at 1100 Tasks' Weekly review kept the sidebar it has no room for", &ok)
        holds(1100, "Tasks' Weekly review")
        clickTab("List", shell)
        settle(shell)
        check(!shell.debugSidebarIsCollapsed, "R2-UX-10: leaving Weekly review at 1100 did not bring the sidebar back", &ok)
        holds(1100, "Tasks' List after Weekly review")
        clickTab("Board", shell)
        settle(shell)

        // Wide again: the sidebar comes back at the width it opened at.
        resize(window, width: 1512, shell)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5,
              "widening the window brought the sidebar back at \(shell.debugSidebarWidth)pt (collapsed: \(shell.debugSidebarIsCollapsed))", &ok)
        // The same round trip on Home, whose grid still holds the wider
        // column's widths (at 499, above the sidebar's 489) while the sidebar
        // comes back - measured: squeezed to its 200pt minimum when the
        // sidebar's pin was released in the same turn. Through Log Analyzer
        // at 1100, so the sidebar really did step aside on the way.
        shell.workspace.navigator.show(.logAnalyzer)
        settle(shell)
        resize(window, width: 1100, shell)
        check(shell.debugSidebarIsCollapsed, "at 1100 on Log Analyzer the sidebar did not step aside", &ok)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        resize(window, width: 1512, shell)
        check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5,
              "a 1100-to-1512 round trip on Home brought the sidebar back at \(shell.debugSidebarWidth)pt", &ok)
    }

    /// A page's own column coming back takes its room from the page, never
    /// from the window - measured before `HelmSplitPage` reopened it through
    /// constraints: Tasks' column back for the board at 1100pt grew the
    /// window to 1349 and brought the sidebar out with it. Since stage 7
    /// Tasks draws no column in this layout, so Notebook's is the one that
    /// comes back.
    private static func checkAPageColumnNeverGrowsTheWindow(_ shell: MainSplitShellController, _ window: NSWindow,
                                                            _ ok: inout Bool) {
        resize(window, width: 1100, shell)
        // Stage 7: Tasks' column is its filter row in this layout, so no tab
        // brings a column out at all.
        shell.workspace.navigator.show(.shift)
        settle(shell)
        if let split = (shell.debugSlotController(.shift) as? HelmSplitPageHosting)?.splitPage {
            for tab in ["Board", "Weekly review", "List", "Board"] {
                clickTab(tab, shell)
                check(split.isSidebarCollapsed, "Tasks' \(tab) tab brought its page column out", &ok)
            }
            check(abs(window.frame.width - 1100) < 0.5,
                  "Tasks' tabs grew a 1100pt window to \(Int(window.frame.width))pt", &ok)
        } else {
            fail("Tasks has no split page to keep its column in", &ok)
        }
        // A column that does come back - Notebook's Pages, put away and
        // brought back through `pageForcesCollapse`, the switch Tasks' own
        // Weekly review used before stage 7 - takes its room from the page.
        shell.workspace.navigator.show(.notebook)
        settle(shell)
        let sidebarBefore = shell.debugSidebarIsCollapsed
        if let split = (shell.debugSlotController(.notebook) as? HelmSplitPageHosting)?.splitPage {
            let column = split.debugSidebarWidth
            check(!split.isSidebarCollapsed && column > 0, "Notebook opened without its Pages column", &ok)
            split.pageForcesCollapse = true
            settle(shell)
            check(split.isSidebarCollapsed, "Notebook's column did not step aside", &ok)
            split.pageForcesCollapse = false
            settle(shell)
            check(!split.isSidebarCollapsed && abs(split.debugSidebarWidth - column) < 0.5,
                  "back again, Notebook's column is \(split.debugSidebarWidth)pt, it was \(column)pt", &ok)
            check(abs(window.frame.width - 1100) < 0.5,
                  "Notebook's column coming back grew a 1100pt window to \(Int(window.frame.width))pt", &ok)
            // R2-UX-10: the window's sidebar shows beside Notebook at 1100 now;
            // what matters is that the page's column leaves it as it was.
            check(shell.debugSidebarIsCollapsed == sidebarBefore,
                  "Notebook's column coming back changed the window's sidebar", &ok)
        } else {
            fail("Notebook has no column of its own", &ok)
        }
        // The same reopen from Toggle Page Column (⌥⇧⌘S since R2-UX-09), on a
        // page whose column is the captain's.
        shell.workspace.navigator.show(.settings)
        settle(shell)
        if let split = (shell.debugSlotController(.settings) as? HelmSplitPageHosting)?.splitPage {
            shell.togglePageColumnFromMenu()
            settle(shell)
            check(split.isSidebarCollapsed, "Toggle Page Column did not put Settings' column away", &ok)
            shell.togglePageColumnFromMenu()
            settle(shell)
            check(!split.isSidebarCollapsed, "Toggle Page Column did not bring Settings' column back", &ok)
            check(abs(window.frame.width - 1100) < 0.5,
                  "Settings' column coming back grew a 1100pt window to \(Int(window.frame.width))pt", &ok)
        } else {
            fail("Settings has no column of its own", &ok)
        }
        var frame = window.frame
        frame.size.width = 1100
        window.setFrame(frame, display: true)
        shell.workspace.navigator.show(.homeCanvas)
        resize(window, width: 1512, shell)
    }

    // MARK: 3 - the sidebar

    private static func checkTheSidebarIsTheMap(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        // A module's row reopens the tab it showed last. (Which tab a module
        // opens on before it has shown one is `primaryRoute`, which the model
        // suite checks; every module has been shown by now.)
        shell.workspace.navigator.show(.notebook)
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
        shell.workspace.navigator.show(.review)
        shell.workspace.navigator.show(.strawHat)
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
        shell.workspace.hosts.sessions.register(hostID: UUID(), label: "Fixture", accentHex: nil, state: .connected)
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
        for id in shell.workspace.hosts.sessions.sessions.map(\.hostID) { shell.workspace.hosts.sessions.unregister(hostID: id) }
        settle(shell)
    }

    private static func checkTheMapAndTheSidebarToggle(_ shell: MainSplitShellController, _ window: NSWindow,
                                                      _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        shell.workspace.navigator.show(.homeCanvas)
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

        // R2-UX-09: ⌥⌘S on a page with its own column is still the app's
        // sidebar, and the column is Toggle Page Column's.
        shell.workspace.navigator.show(.settings)
        settle(shell)
        guard let split = (shell.debugSlotController(.settings) as? HelmSplitPageHosting)?.splitPage else {
            fail("Settings has no split page - the column half cannot be checked", &ok)
            return
        }
        let columnWasCollapsed = split.isSidebarCollapsed
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(split.isSidebarCollapsed == columnWasCollapsed && shell.debugSidebarIsCollapsed,
              "⌥⌘S on Settings toggled Settings' own column, or left the sidebar showing (R2-UX-09)", &ok)
        shell.toggleSidebarFromMenu()
        settle(shell)
        shell.togglePageColumnFromMenu()
        settle(shell)
        check(split.isSidebarCollapsed != columnWasCollapsed && !shell.debugSidebarIsCollapsed,
              "Toggle Page Column on Settings did not toggle Settings' own column (or hid the sidebar instead)", &ok)
        shell.togglePageColumnFromMenu()
        settle(shell)

        // On Connections the page's column is put away for the toolbar's
        // tabs, so ⌥⌘S does what it does on any page without one.
        shell.workspace.navigator.show(.hosts)
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
            shell.workspace.navigator.show(module.primaryRoute)
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
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        clickTab("Keys", shell)
        shell.workspace.navigator.show(.review)
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        check(selectedTabName(shell) == "Keys", "returning to Hosts lit \(String(describing: selectedTabName(shell))), not Keys", &ok)
        clickTab("Hosts", shell)
    }

    private static func checkPageTabsAreDrivenFromTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                            _ ok: inout Bool) {
        // Each page's own tabs are its module's, name for name.
        for module in WorkspaceModule.allCases {
            guard let route = module.pageTabHost else { continue }
            shell.workspace.navigator.show(route)
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
            shell.workspace.navigator.show(.shift)
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
            shell.workspace.navigator.openFleetLog()
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
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        // Stage 6: Hosts' one action is its primary one, the page's own
        // button at the toolbar's far right rather than among the others.
        // H8 of the Termius-style plan: in this layout that action is the
        // page's `workspacePrimaryAction`, Add Host's split button, rather
        // than the floating bar's drill-header button.
        let drillActions = (shell.debugSlotController(.hosts) as? DaylightDrillActions)?.drillHeaderActions ?? []
        check(drillActions.count == 1, "the Hosts page offers \(drillActions.count) actions - this check assumes its one add button", &ok)
        let hostsActions = [(shell.debugSlotController(.hosts) as? WorkspacePrimaryActionProviding)?.workspacePrimaryAction]
            .compactMap { $0 }
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
        shell.workspace.navigator.show(.health)
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
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        // Connections' Activity: the captain's log, which the Hosts page's
        // column linked to before the toolbar's tabs replaced it.
        check(shell.toolbar.debugModuleActionButton?.title == "Activity", "Connections offers no Activity button", &ok)
        shell.debugModuleAction()
        settle(shell)
        check(shell.debugCurrentDestination == .overview && selectedTabName(shell) == "Log",
              "Activity opened \(String(describing: shell.debugCurrentDestination)), not Crew › Log", &ok)

        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        check(shell.toolbar.debugPageActions.isEmpty
                && !shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.pageActions),
              "Home still shows the previous page's actions", &ok)
        // R2-UX-02: Home has one space here, its own. A route that still
        // names another one lands on Home's own cards.
        shell.selectSpace(.operations)
        settle(shell)
        check(shell.debugHomeCanvas.selectedSpace == .overview && shell.debugCurrentDestination == .homeCanvas,
              "a route naming the Operations space filtered Home to \(shell.debugHomeCanvas.selectedSpace)", &ok)

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
        // The crumb outlasts Quick Connect, the chip and the module's action
        // since U-02: R2-UX-05 made it the one place that names the module.
        check(priority(WorkspaceToolbar.ItemID.crumb) == WorkspaceToolbar.crumbPriority,
              "the crumb left its overflow band", &ok)
        for id in [WorkspaceToolbar.ItemID.recents, WorkspaceToolbar.ItemID.inspector] {
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
        shell.workspace.hosts.sessions.register(hostID: host, label: "DEV Bastion", accentHex: nil, state: .connected)
        defer {
            shell.workspace.hosts.sessions.unregister(hostID: host)
            settle(shell)
        }
        shell.workspace.navigator.show(.console)
        settle(shell)
        check(shell.debugHeader == nil && shell.toolbar.debugCrumb.hasSuffix("Console"),
              "Console draws a header, or the crumb reads \"\(shell.toolbar.debugCrumb)\"", &ok)
        check(shell.debugSessionStripIsShown, "Console has a live session but no session strip", &ok)
        check(shell.sidebar.debugSelectedEntry == .module(.console), "the Console row is not lit", &ok)
        // The strip is Console's: no other module carries it.
        shell.workspace.navigator.show(.review)
        settle(shell)
        check(!shell.debugSessionStripIsShown, "the session strip followed the captain out of Console", &ok)
        // Quick Connect: its Hosts icon is Hosts' own quick-connect field. Stage
        // 7 made the one button a caption and two icons;
        // `SidebarRedesignsSelfTest` drives the Console icon and the caption's
        // menu form.
        shell.workspace.navigator.show(.console)
        settle(shell)
        check(shell.toolbar.debugItemIdentifiers.contains(WorkspaceToolbar.ItemID.quickConnectHosts), "Console offers no Quick Connect", &ok)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectHosts), "Quick Connect has no Hosts icon", &ok)
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
        shell.workspace.navigator.show(.homeCanvas)
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

        // Free sizing, through the card's own grips.
        checkHomeCardsResizeByDragging(shell, canvas, first, &ok)

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
        // Home has no other space to leave Customize by (R2-UX-02), so Done
        // is the way out, and it is checked above. End it for what follows.
        if canvas.isCustomizing { shell.debugModuleAction(); settle(shell) }
    }

    /// Every arranged card's frame in window coordinates.
    private static func cardFrames(_ canvas: HomeCanvasController) -> [DaylightModule: NSRect] {
        var frames: [DaylightModule: NSRect] = [:]
        for module in canvas.visibleModulesForTests {
            if let card = canvas.cardForTests(module) { frames[module] = card.convert(card.bounds, to: nil) }
        }
        return frames
    }

    private static func checkNoCardsOverlap(_ canvas: HomeCanvasController, _ when: String, _ ok: inout Bool) {
        let frames = cardFrames(canvas)
        check(frames.count == canvas.visibleModulesForTests.count, "\(when): not every card is on Home", &ok)
        let pairs = frames.flatMap { a in frames.compactMap { b in a.key.rawValue < b.key.rawValue ? (a, b) : nil } }
        for (a, b) in pairs where a.value.insetBy(dx: 0.5, dy: 0.5).intersects(b.value.insetBy(dx: 0.5, dy: 0.5)) {
            fail("\(when): \(a.key.rawValue) \(a.value) overlaps \(b.key.rawValue) \(b.value)", &ok)
        }
    }

    /// The captain drags a card's trailing edge, bottom edge and corner: the
    /// card is that size on the grid, its neighbours reflow without overlap,
    /// the size is kept, and a double-click or Reset Size puts it back.
    private static func checkHomeCardsResizeByDragging(_ shell: MainSplitShellController, _ canvas: HomeCanvasController,
                                                       _ module: DaylightModule, _ ok: inout Bool) {
        guard let card = canvas.cardForTests(module),
              let handles = canvas.resizeHandlesForTests[module],
              let trailing = handles.first(where: { $0.edge == .trailing }),
              let bottom = handles.first(where: { $0.edge == .bottom }),
              let corner = handles.first(where: { $0.edge == .corner }) else {
            fail("\(module.rawValue) has no resize grips in Customize - the rest is vacuous", &ok)
            return
        }
        check(canvas.resizeHandlesForTests.count == canvas.visibleModulesForTests.count,
              "not every card wears resize grips in Customize", &ok)
        // The grips sit inside the card, on its edges, and clear of its header controls.
        let cardFrame = card.convert(card.bounds, to: nil)
        for handle in handles {
            let frame = handle.convert(handle.bounds, to: nil)
            check(cardFrame.insetBy(dx: -0.5, dy: -0.5).contains(frame) && frame.width > 0 && frame.height > 0,
                  "the \(handle.edge) grip sits at \(frame), outside its card \(cardFrame)", &ok)
            if let controls = card.debugHeaderAccessoryFrameInCard {
                check(!card.convert(controls, to: nil).intersects(frame), "the \(handle.edge) grip covers the card's controls", &ok)
            }
        }
        let gridWidth = canvas.gridRowsForTests.map(\.frame.width).max() ?? 0
        let startWidth = card.frame.width

        // Wider, past the grid: the card takes the whole row, the card that
        // shared its row moves below it, and nothing overlaps.
        trailing.debugDrag(dx: 4_000, dy: 0)
        settle(shell)
        check(canvas.cardForTests(module) === card, "a drag rebuilt the card it was dragging", &ok)
        check(abs(card.frame.width - gridWidth) < 1, "dragged past the grid, the card is \(card.frame.width)pt of \(gridWidth)pt", &ok)
        check(AppSettings.shared.homeCardLayout.size(of: module).columns == HomeCardGrid.columns,
              "the full width was not kept: \(AppSettings.shared.homeCardLayout.size(of: module))", &ok)
        let wide = card.convert(card.bounds, to: nil)
        for (other, frame) in cardFrames(canvas) where other != module {
            check(frame.maxY <= wide.minY + 0.5 || frame.minY >= wide.maxY - 0.5,
                  "\(other.rawValue) still shares a row with a full-width card", &ok)
        }
        checkNoCardsOverlap(canvas, "after a full-width drag", &ok)

        // Narrower, by about four columns' worth: the width lands on the grid,
        // not where the pointer let go.
        let unit = (gridWidth + HomeCanvasController.gridSpacing) / CGFloat(HomeCardGrid.columns)
        trailing.debugDrag(dx: -(unit * 4 + 7), dy: 0)
        settle(shell)
        let columns = AppSettings.shared.homeCardLayout.size(of: module).columns
        check(columns == HomeCardGrid.columns - 4, "four columns narrower kept \(columns) columns", &ok)
        let expected = unit * CGFloat(columns) - HomeCanvasController.gridSpacing
        check(abs(card.frame.width - expected) < 1, "a \(columns)-column card is \(card.frame.width)pt, not \(expected)pt", &ok)
        checkNoCardsOverlap(canvas, "after a narrowing drag", &ok)

        // Narrower than a card can be read at: held at the canvas's minimum.
        trailing.debugDrag(dx: -4_000, dy: 0)
        settle(shell)
        check(card.frame.width >= HomeCanvasController.minModuleWidth - 1,
              "dragged to nothing, the card is \(card.frame.width)pt, under the \(HomeCanvasController.minModuleWidth)pt minimum", &ok)

        // Taller, from the bottom edge: a height of its own, snapped, and the
        // card is drawn at it. Its row grows to it.
        let startHeight = card.frame.height
        bottom.debugDrag(dx: 0, dy: 123)
        settle(shell)
        guard let height = AppSettings.shared.homeCardLayout.size(of: module).height else {
            fail("a bottom-edge drag kept no height", &ok)
            return
        }
        check(height.truncatingRemainder(dividingBy: HomeCardGrid.heightStep) == 0 && abs(height - (startHeight + 123)) <= HomeCardGrid.heightStep,
              "dragged 123pt down from \(startHeight)pt, the height kept is \(height)pt", &ok)
        check(abs(card.frame.height - height) < 1, "a \(height)pt card is drawn \(card.frame.height)pt tall", &ok)
        checkNoCardsOverlap(canvas, "after a taller drag", &ok)

        // Shorter than its content: held where the content still fits, never clipped.
        bottom.debugDrag(dx: 0, dy: -2_000)
        settle(shell)
        let floor = HomeCardGrid.heightRange.lowerBound
        check(card.frame.height >= floor - 0.5 && card.frame.height >= card.fittingSize.height - 1,
              "dragged to nothing, the card is \(card.frame.height)pt; its floor is \(floor)pt and its content \(card.fittingSize.height)pt", &ok)

        // The corner sizes both at once.
        corner.debugDrag(dx: unit * 3, dy: 60)
        settle(shell)
        let both = AppSettings.shared.homeCardLayout.size(of: module)
        check(both.height != nil && card.frame.width > HomeCanvasController.minModuleWidth,
              "a corner drag did not size both: \(both)", &ok)
        checkNoCardsOverlap(canvas, "after a corner drag", &ok)
        check(canvas.sizeBadgeForTests.superview == nil, "the size badge stayed after the drag ended", &ok)

        // The sizes survive a relaunch's read of the preference.
        let kept = AppSettings.shared.homeCardLayout
        check(HomeCardLayout(storedData: kept.storedData ?? Data()) == kept, "the dragged sizes did not round-trip", &ok)

        // Double-click the bottom grip: the height goes back to the row's.
        bottom.debugDoubleClick()
        settle(shell)
        check(AppSettings.shared.homeCardLayout.size(of: module).height == nil,
              "a double-click on the bottom grip left a height of \(String(describing: AppSettings.shared.homeCardLayout.size(of: module).height))", &ok)

        // Reset Size, from the card's controls: its own size again.
        guard let strip = canvas.cardStripsForTests[module] else {
            fail("the resized card lost its controls", &ok)
            return
        }
        check(strip.debugResetSizeButton.isEnabled, "Reset Size is off on a card the captain sized", &ok)
        strip.debugResetSizeButton.performClick(nil)
        settle(shell)
        check(!AppSettings.shared.homeCardLayout.hasCustomSize(module), "Reset Size left \(AppSettings.shared.homeCardLayout.size(of: module))", &ok)
        if let card = canvas.cardForTests(module) {
            check(abs(card.frame.width - startWidth) < 1, "after Reset Size the card is \(card.frame.width)pt, it started \(startWidth)pt", &ok)
        }
        check(canvas.cardStripsForTests[module]?.debugResetSizeButton.isEnabled == false,
              "Reset Size is still on for a card at its own size", &ok)
        checkNoCardsOverlap(canvas, "after Reset Size", &ok)
    }

    private static func checkBackAndForward(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        for page in [RailDestination.homeCanvas, .shift, .review] { shell.workspace.navigator.show(page) }
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
        shell.workspace.navigator.show(.settings)
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

    /// The toolbar's calendar button, after the bell on every page: from a
    /// page far from it, its own target and action land on the Calendar page
    /// with its Calendar sidebar row lit and its own view tab selected - and
    /// not on Tasks, which no longer has a Calendar tab to land on.
    private static func checkTheCalendarButton(_ shell: MainSplitShellController, _ window: NSWindow,
                                               _ ok: inout Bool) {
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        guard let item = shell.toolbar.toolbar.items.first(where: { $0.itemIdentifier == WorkspaceToolbar.ItemID.calendar }),
              let action = item.action else {
            fail("the toolbar has no calendar button on Hosts", &ok)
            return
        }
        check(item.visibilityPriority != .low, "the calendar button is among the first to overflow", &ok)
        _ = NSApplication.shared.sendAction(action, to: item.target, from: item)
        settle(shell)
        check(shell.debugCurrentDestination == .calendar,
              "the calendar button went to \(String(describing: shell.debugCurrentDestination))", &ok)
        check(shell.currentModule == .calendar,
              "the calendar button lit the \(shell.currentModule.title) row instead of Calendar", &ok)
        // It reopens the view the calendar last showed, as the row does, so
        // the lit tab is whichever view the page is on.
        let view = shell.workspace.calendar.selectedModuleTabName
        check(selectedTabName(shell) == view,
              "the calendar button lit \(selectedTabName(shell) ?? "no tab") with the Calendar on \(view)", &ok)
        check(shell.workspace.calendar.drawsSidebarLayout && shell.workspace.calendar.debugCalendarView.showsHeading,
              "the Calendar page did not take the sidebar layout's heading", &ok)
    }

    private static func checkTheInspector(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        check(shell.debugInspectorIsCollapsed, "the inspector is open at launch", &ok)
        // R2-BUG-10: the button draws the standing choice. At launch it is
        // on, so a selection opens the inspector.
        check(shell.toolbar.debugInspectorSymbolName == WorkspaceToolbar.inspectorOnSymbol,
              "R2-BUG-10: at launch the inspector button draws \(shell.toolbar.debugInspectorSymbolName)", &ok)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector), "the inspector item has no action", &ok)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "the inspector item did not open the inspector", &ok)
        check(shell.inspector.debugEmptyState.isDescendant(of: shell.inspector.view),
              "the inspector does not say it has nothing to show", &ok)
        shell.inspector.debugCloseButton.performClick(nil)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "the inspector's close button did not close it", &ok)
        // R2-BUG-10: closing it turns the choice off for the session, and
        // the button now says so - a closed pane with the choice on (nothing
        // selected yet) and one with it off no longer look the same.
        let item = shell.toolbar.debugInspectorItem
        check(shell.toolbar.debugInspectorSymbolName == WorkspaceToolbar.inspectorOffSymbol,
              "R2-BUG-10: after closing the inspector its button still draws the on state", &ok)
        check(item?.toolTip?.contains("is off") == true,
              "R2-BUG-10: the closed-and-off inspector's tooltip reads \(item?.toolTip ?? "nothing")", &ok)
        check(WorkspaceToolbar.inspectorOnSymbol != WorkspaceToolbar.inspectorOffSymbol,
              "fixture: the two states draw two symbols", &ok)
    }

    /// R2-ARCH-06: on macOS 14 and later the inspector is the system's
    /// inspector item, which draws the column and its edge, so the
    /// controller paints nothing of its own; before that it is a plain pane
    /// the controller paints. Both open and close through the same button,
    /// keep the same 320pt width, and take it out of the content column
    /// rather than out of the window. The fallback is built here too, by
    /// forcing it, because no runner this app tests on is macOS 13.
    private static func checkTheInspectorIsTheSystemsItem(_ shell: MainSplitShellController, _ window: NSWindow,
                                                         _ ok: inout Bool) {
        func opensClosesAndKeepsItsWidth(_ shell: MainSplitShellController, _ window: NSWindow, _ label: String) {
            resize(window, width: 1512, shell)
            shell.workspace.navigator.show(.homeCanvas)
            settle(shell)
            if !shell.debugInspectorIsCollapsed { shell.setInspectorShown(false); settle(shell) }
            let before = window.frame.width
            shell.setInspectorShown(true)
            settle(shell)
            let pane = shell.inspector.view
            let frame = pane.convert(pane.bounds, to: nil)
            check(!shell.debugInspectorIsCollapsed, "\(label): the inspector did not open", &ok)
            check(abs(frame.width - WorkspaceInspectorController.width) < 0.5,
                  "\(label): the open inspector is \(frame.width)pt wide, want \(WorkspaceInspectorController.width)", &ok)
            check(abs(frame.maxX - window.contentLayoutRect.maxX) < 0.5 || abs(frame.maxX - window.frame.width) < 0.5,
                  "\(label): the inspector is not the window's trailing column (maxX \(frame.maxX))", &ok)
            check(window.frame.width == before, "\(label): opening the inspector resized the window", &ok)
            // A narrower window takes its room from the column, never from
            // the inspector's fixed width.
            resize(window, width: 1300, shell)
            settle(shell)
            let narrow = pane.convert(pane.bounds, to: nil)
            check(!shell.debugInspectorIsCollapsed && abs(narrow.width - WorkspaceInspectorController.width) < 0.5,
                  "\(label): at 1300 the inspector is \(narrow.width)pt or collapsed", &ok)
            shell.inspector.debugCloseButton.performClick(nil)
            settle(shell)
            check(shell.debugInspectorIsCollapsed, "\(label): the close button did not close the inspector", &ok)
            shell.debugResetInspectorPreference()
            resize(window, width: 1512, shell)
        }

        let theme = ThemeManager.shared.theme
        if #available(macOS 14, *) {
            check(MainSplitShellController.usesSystemInspector && shell.debugInspectorItemBehavior == .inspector,
                  "on macOS 14+ the inspector is not the system's inspector item (behavior \(shell.debugInspectorItemBehavior.rawValue))", &ok)
            check(!shell.inspector.drawsOwnPane && shell.inspector.debugPanelLayer?.backgroundColor == nil
                    && shell.inspector.view.layer?.backgroundColor == nil && shell.inspector.debugEdgeIsHidden,
                  "the system's inspector is painted over by the controller's own column", &ok)
            opensClosesAndKeepsItsWidth(shell, window, "system inspector")
        }

        // The hand-drawn pane a macOS 13 install gets.
        MainSplitShellController.systemInspectorOverrideForTests = false
        defer { MainSplitShellController.systemInspectorOverrideForTests = nil }
        let (fallbackWindow, fallback) = ReviewTourLab.makeOffScreenSplitShell()
        fallbackWindow.orderFront(nil)
        defer { fallbackWindow.orderOut(nil) }
        settle(fallback)
        check(fallback.debugInspectorItemBehavior == .default,
              "the fallback inspector is not a plain split pane (behavior \(fallback.debugInspectorItemBehavior.rawValue))", &ok)
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        check(fallback.inspector.drawsOwnPane && fallback.inspector.debugPanelLayer?.backgroundColor == card
                && !fallback.inspector.debugEdgeIsHidden,
              "the fallback inspector does not paint its card-coloured column and its edge", &ok)
        opensClosesAndKeepsItsWidth(fallback, fallbackWindow, "fallback pane")
        if ok { print("  OK   the inspector is the system's item on macOS 14+, and the hand-drawn pane before") }
    }

    /// R2-ARCH-06: the captain can customise the toolbar, and the result is
    /// saved to `AppSettings` (`AppDefaults.store`) rather than autosaved by
    /// AppKit into `UserDefaults.standard`. A change the captain makes is
    /// saved; a fresh toolbar puts it back; the default again clears it;
    /// and nothing the toolbar does to its own items counts as one.
    private static func checkTheToolbarIsCustomisable(_ shell: MainSplitShellController, _ window: NSWindow,
                                                      _ ok: inout Bool) {
        let savedItems = AppSettings.shared.workspaceToolbarItems
        let savedMode = AppSettings.shared.workspaceToolbarDisplayMode
        defer {
            AppSettings.shared.workspaceToolbarItems = savedItems
            AppSettings.shared.workspaceToolbarDisplayMode = savedMode
        }
        AppSettings.shared.workspaceToolbarItems = nil
        AppSettings.shared.workspaceToolbarDisplayMode = nil
        func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        func ids(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbar.items.map(\.itemIdentifier) }

        let toolbar = shell.toolbar!
        check(toolbar.toolbar.allowsUserCustomization && !toolbar.toolbar.autosavesConfiguration,
              "the toolbar is not customisable, or AppKit autosaves it", &ok)
        // The page's own items come and go without saving anything.
        shell.workspace.navigator.show(.notebook)
        settle(shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        drain()
        check(AppSettings.shared.workspaceToolbarItems == nil,
              "the toolbar's own placing of the page's items was saved as a customisation", &ok)

        // The captain takes Recents off the toolbar.
        guard let recents = toolbar.toolbar.items.firstIndex(where: { $0.itemIdentifier == WorkspaceToolbar.ItemID.recents }) else {
            fail("the toolbar has no Recents to take off", &ok)
            return
        }
        toolbar.toolbar.removeItem(at: recents)
        drain()
        let expected = WorkspaceToolbar.defaultCustomizedIdentifiers.filter { $0 != WorkspaceToolbar.ItemID.recents }
        check(AppSettings.shared.workspaceToolbarItems == expected.map(\.rawValue),
              "taking Recents off saved \(String(describing: AppSettings.shared.workspaceToolbarItems))", &ok)
        check(UserDefaults.standard.object(forKey: "NSToolbar Configuration \(toolbar.toolbar.identifier)") == nil,
              "the toolbar's configuration reached UserDefaults.standard", &ok)

        // A toolbar built later - the next launch - puts it back, with the
        // display mode the sheet chose.
        AppSettings.shared.workspaceToolbarDisplayMode = Int(NSToolbar.DisplayMode.iconAndLabel.rawValue)
        // Its own identifier: AppKit syncs live toolbars that share one, so
        // the shell's toolbar would otherwise hand it its own items.
        let next = WorkspaceToolbar(splitView: NSSplitView(), identifier: "workspace.toolbar.nextLaunch")
        let nextWindow = OffScreenProbe.window(width: 1512, height: 400)
        defer { nextWindow.close() }
        nextWindow.toolbar = next.toolbar
        next.reconcileDynamicItems()
        drain()
        check(!ids(next.toolbar).contains(WorkspaceToolbar.ItemID.recents)
                && next.customizedIdentifiers == expected,
              "a new toolbar did not put the saved items back: \(ids(next.toolbar).map(\.rawValue))", &ok)
        check(Array(ids(next.toolbar).prefix(2)) == WorkspaceToolbar.fixedItems,
              "the sidebar button no longer leads a customised toolbar: \(ids(next.toolbar).map(\.rawValue))", &ok)
        check(next.toolbar.displayMode == .iconAndLabel, "the saved display mode did not come back", &ok)
        // The page's items still go in around what the captain kept.
        next.setTabs(["One", "Two"], selected: 0)
        check(ids(next.toolbar).contains(WorkspaceToolbar.ItemID.tabs),
              "a customised toolbar no longer shows the module's tabs", &ok)
        next.setTabs([], selected: nil)
        drain()
        check(AppSettings.shared.workspaceToolbarItems == expected.map(\.rawValue),
              "the toolbar placing its tabs changed the saved customisation", &ok)

        // Recents back where it was is the default, which clears the setting.
        let at = (toolbar.toolbar.items.firstIndex { $0.itemIdentifier == WorkspaceToolbar.ItemID.navigation } ?? 1) + 1
        toolbar.toolbar.insertItem(withItemIdentifier: WorkspaceToolbar.ItemID.recents, at: at)
        drain()
        check(AppSettings.shared.workspaceToolbarItems == nil,
              "the default toolbar again did not clear the setting: \(String(describing: AppSettings.shared.workspaceToolbarItems))", &ok)

        // What another build saved cannot break this one.
        check(WorkspaceToolbar.sanitized(["workspace.search", "workspace.search", "workspace.tabs", "bogus",
                                          NSToolbarItem.Identifier.space.rawValue])
                == [WorkspaceToolbar.ItemID.search, .space],
              "a saved list with a duplicate, a page item or an unknown id is not cleaned", &ok)
        // The palette's copies never take a live view out of the toolbar.
        let liveSearch = toolbar.toolbar.items.first { $0.itemIdentifier == WorkspaceToolbar.ItemID.search }?.view
        let paletteSearch = toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: WorkspaceToolbar.ItemID.search,
                                            willBeInsertedIntoToolbar: false)
        check(paletteSearch?.view == nil && liveSearch?.superview != nil,
              "the palette's Search item took the live Search button", &ok)
        check(!toolbar.toolbarAllowedItemIdentifiers(toolbar.toolbar).contains(where: WorkspaceToolbar.dynamicItems.contains),
              "the customisation palette offers one of the page's own items", &ok)
        if ok { print("  OK   the toolbar is customisable, saved to AppDefaults and put back on the next launch") }
    }

    // MARK: 8 - the lock

    private static func checkTheLockHidesTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                   _ ok: inout Bool) {
        shell.workspace.navigator.show(.hosts)
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
        // Nothing sits beside the body either: Knowledge's tree was the one
        // column, and stage 7 removed it.
        shell.workspace.navigator.show(.notebook)
        settle(shell)
        let knowledgeBody = body.convert(body.bounds, to: pane)
        check(knowledgeBody.minX.magnitude < 0.5, "under Knowledge the body starts \(knowledgeBody.minX)pt in", &ok)

        // The live sessions the strip counted are Console's: its session
        // strip lists each one, connected or restored, and so does the
        // sidebar under Console.
        let live = UUID()
        let restored = UUID()
        shell.workspace.hosts.sessions.register(hostID: live, label: "DEV Bastion", accentHex: nil, state: .connected)
        shell.workspace.hosts.sessions.register(hostID: restored, label: "PROD Web", accentHex: nil, state: .restored)
        shell.workspace.navigator.show(.console)
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
        shell.workspace.hosts.sessions.unregister(hostID: live)
        shell.workspace.hosts.sessions.unregister(hostID: restored)
        settle(shell)
        check(!shell.debugSessionStripIsShown, "Console's session strip stayed with no sessions", &ok)
    }

    private static func checkTheFocusChipIsInTheToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                        _ ok: inout Bool) {
        let toolbar = shell.toolbar!
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        check(!toolbar.debugFocusChipIsShown, "the toolbar shows a focus chip with no timer running", &ok)
        var task = ShiftTask.fresh()
        task.title = "Rotate the staging certificate"
        shell.workspace.focusTimer.start(task: task)
        settle(shell)
        let chip = toolbar.debugFocusChip
        guard toolbar.debugFocusChipIsShown else {
            fail("a running timer put no chip in the toolbar", &ok)
            _ = shell.workspace.focusTimer.stop()
            return
        }
        check(chip.debugTitleText == task.title && chip.debugCountdownText == "25:00",
              "a running timer put \"\(chip.debugCountdownText) \(chip.debugTitleText)\" in the toolbar", &ok)
        // The trailing cluster opens with Quick Connect's icons since U-02.
        func clusterStart(_ ids: [NSToolbarItem.Identifier]) -> Int? {
            ids.firstIndex { WorkspaceToolbar.ItemID.quickConnect.contains($0) || $0 == WorkspaceToolbar.ItemID.theme }
        }
        let ids = toolbar.debugItemIdentifiers
        let focus = ids.firstIndex(of: WorkspaceToolbar.ItemID.focusTimer)
        check(focus.map { $0 + 1 } == clusterStart(ids),
              "the chip is not just before the trailing cluster: \(ids.map(\.rawValue))", &ok)
        // On every module, Console included - the strip never showed it
        // there - and still beside the trailing cluster after a module's own
        // action has come and gone around it.
        for route in [RailDestination.console, .health, .notebook, .homeCanvas] {
            shell.workspace.navigator.show(route)
            settle(shell)
            check(toolbar.debugFocusChipIsShown, "the focus chip is not in the toolbar under \(route.rawValue)", &ok)
            let ids = toolbar.debugItemIdentifiers
            check(ids.firstIndex(of: WorkspaceToolbar.ItemID.focusTimer).map { $0 + 1 } == clusterStart(ids),
                  "under \(route.rawValue) the chip is not just before the trailing cluster: \(ids.map(\.rawValue))", &ok)
        }
        // Through its own click recognizer, which is what Return, Space and
        // VoiceOver's press reach too (`HoverHighlightView`).
        check(chip.performPrimaryAction(), "the focus chip has no click", &ok)
        check(shell.debugFocusPopoverIsShown, "clicking the focus chip opened no ring popover", &ok)
        check(chip.performPrimaryAction() && !shell.debugFocusPopoverIsShown, "a second click left the popover open", &ok)
        _ = chip.performPrimaryAction()
        _ = shell.workspace.focusTimer.stop()
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
    /// measured on Console, whose whole action cluster is in the toolbar
    /// since R2-UX-06. (Knowledge's five tabs leave Notebook's actions no
    /// room at 1100 at all now; they run from the overflow menu's form,
    /// which `checkNotebookLeavesTheToolbarRoomAtNarrowWidths` covers.)
    private static func checkTheFocusChipFitsTheNarrowToolbar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                               _ ok: inout Bool) {
        let toolbar = shell.toolbar!
        let width = window.frame.width
        defer { resize(window, width: width, shell) }
        resize(window, width: 1100, shell)
        shell.workspace.navigator.show(.console)
        settle(shell)
        // Measured with the full-width toolbar this check was written for:
        // R2-UX-10 keeps the sidebar beside Console at 1100, and the toolbar
        // beside it is about 250pt narrower. Put away by the captain, it stays
        // away for the rest of this check.
        if !shell.debugSidebarIsCollapsed { shell.toggleWorkspaceSidebar(); settle(shell) }
        defer { if shell.debugSidebarIsCollapsed { shell.toggleWorkspaceSidebar(); settle(shell) } }
        let actionsAlone = toolbar.debugPageActions.first?.window != nil
        var task = ShiftTask.fresh()
        task.title = "Rotate the staging certificate"
        shell.workspace.focusTimer.start(task: task)
        settle(shell)
        defer { _ = shell.workspace.focusTimer.stop() }
        let chip = toolbar.debugFocusChip
        check(toolbar.debugIsCompact && !chip.debugTitleIsShown && chip.toolTip?.contains(task.title) == true,
              "at 1100 the chip still names its task, or its tooltip does not", &ok)
        // The fixture can fail: the page's actions fit at 1100 without a
        // timer, or there is nothing to push out.
        check(actionsAlone, "Console's actions are already in the overflow at 1100 with no timer", &ok)
        check(toolbar.debugPageActions.first?.window != nil,
              "at 1100 a running timer pushed Console's actions into the toolbar's overflow menu", &ok)
        // Where even the compact chip leaves no room, it is the chip that
        // yields, and its overflow item still opens the ring popover.
        if chip.window == nil {
            check(toolbar.debugPerformFocusChipMenuForm() && shell.debugFocusPopoverIsShown,
                  "with the chip in the overflow menu its item opened no ring popover", &ok)
            _ = toolbar.debugPerformFocusChipMenuForm()
        }
        // On a module with room, the compact chip is in the toolbar beside
        // the page's actions.
        shell.workspace.navigator.show(.health)
        settle(shell)
        check(chip.window != nil && toolbar.debugPageActions.first?.window != nil,
              "at 1100 on Health the compact chip or the page's actions went to the overflow menu", &ok)
        // On Home the chip outranks Customize, whose overflow item still
        // opens Customize.
        // Through a resize, as the window gets there: the toolbar decides
        // what overflows when its width changes, not when an item is added.
        shell.workspace.navigator.show(.homeCanvas)
        resize(window, width: 1512, shell)
        resize(window, width: 1100, shell)
        check(chip.window != nil, "at 1100 on Home the chip went to the overflow menu ahead of Customize", &ok)
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
