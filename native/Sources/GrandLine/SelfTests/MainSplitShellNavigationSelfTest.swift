// Grand Line - native macOS app.
//
// Stages 3 and 4 of the modular-shell migration: the sidebar shell
// (`MainSplitShellController`), mounted in a real off-screen window and
// driven through its own controls. This half is how the captain gets
// around: the routes, the sidebar, the tabs, the toolbar and Home's cards.
// The other half, `MainSplitShellPanesSelfTest`, is the frame around the
// page.
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
//      Connections' children, ⌘⇧D reveals it, and ⌥⌘S toggles the page's own
//      column where there is one and the sidebar everywhere else.
//   4. **A module's tabs are its pages.** A tab shows its page; on the four
//      pages whose own tabs are the module's, the toolbar drives the page,
//      the page hides its own control, and a switch the page makes by itself
//      moves the toolbar's tab too.
//   5. **The toolbar carries the chrome.** The page's actions, Home's spaces,
//      the module's one action, the notifications badge from the bell's
//      store, Back and Forward, the calendar button, and the captain's own
//      arrangement of it.
//   6. **Console is a module**: no header, its session strip, Quick Connect.
//   7. **Home is the captain's to arrange**: Customize hides, adds, moves and
//      resizes the real cards, keeps the result, and gets out of the way.
//
// It was one suite with the other half until it ran 1,573 checks in 297.6s
// against the runner's 300s bound on CI. The halves split by area and by CI
// time, about 140s each; `MainSplitShellHarness` holds the one setup both use.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_MAIN_SPLIT_SHELL_NAVIGATION_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum MainSplitShellNavigationSelfTest {

    static func run() -> Bool {
        MainSplitShellHarness.run("MainSplitShellNavigationSelfTest", [
            checkEveryRouteShowsThroughTheMounter, checkNoPageGrowsTheWindow,
            checkAPageColumnNeverGrowsTheWindow, checkTheSidebarIsTheMap,
            checkPageTabsAreDrivenFromTheToolbar, checkTheToolbar, checkConsoleIsAModule,
            checkHomeIsTheCaptainsToArrange, checkHomeRowsFillBesideTheSidebar, checkHomeLeavesAnOffBriefingOff,
            checkHomeFeelPass, checkToolbarTabsSlide, checkDensityReachesTheSidebar,
            checkBackAndForward, checkTheCalendarButton, checkTheToolbarIsCustomisable,
        ])
    }

    private static func settle(_ shell: MainSplitShellController) {
        MainSplitShellHarness.settle(shell)
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: MainSplitShellController) {
        MainSplitShellHarness.resize(window, width: width, shell)
    }

    /// R4-PROC-01: wait for Home's grid to reflow for the width its page has
    /// now, then lay it out. Opening or closing the sidebar narrows Home's
    /// clip view without resizing the window, and Home reflows its cards on
    /// the *next* main-queue turn after that (`HomeCanvasController`'s
    /// clip-view observer). `settle`'s one 50 ms turn usually covered that
    /// turn and on CI's loaded runner sometimes did not: the row then had the
    /// new width and its cards the old one - "row 1 ends at 1217.0pt of
    /// 952.0pt" on #551's push, 5 flaky in 20 `main` runs of this suite.
    /// Asserting with no turn at all reproduces that shape on every step.
    /// `false` when the grid never caught up, which is a failure in itself.
    private static func settleHomeGrid(_ shell: MainSplitShellController, _ canvas: HomeCanvasController) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !canvas.gridIsCurrentForTests, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            shell.view.layoutSubtreeIfNeeded()
        }
        shell.view.layoutSubtreeIfNeeded()
        return canvas.gridIsCurrentForTests
    }

    /// Click the toolbar's tab with this name, through the control's own
    /// target and action, the way a real click reaches it.
    @discardableResult
    private static func clickTab(_ name: String, _ shell: MainSplitShellController) -> Bool {
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return false }
        shell.toolbar.debugClickTab(index)
        settle(shell)
        return true
    }

    private static func selectedTabName(_ shell: MainSplitShellController) -> String? {
        let names = shell.toolbar.debugTabNames
        return shell.toolbar.debugSelectedTab.map { names[$0] }
    }

    // MARK: 1 - every route

    private static func checkEveryRouteShowsThroughTheMounter(_ shell: MainSplitShellController, _ window: NSWindow,
                                                             _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for destination in RailDestination.allCases {
            shell.workspace.navigator.show(destination)
            settle(shell)
            let module = ModuleTable.module(for: destination)
            // A door's route lands on its host page's tab: the Calendar on
            // Tasks' Calendar view (`ModuleTable.landing(for:)`).
            let landing = ModuleTable.landing(for: destination)
            check(shell.debugCurrentDestination == landing.route, "\(destination.rawValue) did not show", &ok)
            let slotView = shell.destinationViewIfMountedForTests(destination.slot)
            check(slotView != nil && slotView === shell.workspace.content.visibleDestinationView(),
                  "\(destination.rawValue) is not showing its own mounter slot", &ok)
            check(slotView?.isDescendant(of: shell.debugContentPane) == true,
                  "\(destination.rawValue)'s page is not in the content column", &ok)
            // A hidden door row leaves its page to the module it lives in
            // (R5-UX-05: an Operator's Notebook lights Knowledge).
            let row = ModuleTable.litModule(for: destination, pageTab: shell.debugCurrentTab?.name,
                                            hidden: AppSettings.shared.hiddenModules)
            // DevOps Hub's projects are cards on its page, so its own row is
            // lit whichever of its views shows.
            check(shell.sidebar.debugSelectedEntry == .module(row),
                  "\(destination.rawValue) did not light \(row.title)'s row (lit: \(String(describing: shell.sidebar.debugSelectedEntry)))", &ok)
            check(shell.currentModule == module && window.title == module.title,
                  "the window is titled \"\(window.title)\" on \(destination.rawValue), want \"\(module.title)\"", &ok)
            // R5-BUG-05: the crumb and the header name the lit row, which is
            // the Calendar on the Calendar door's route.
            // DevOps Hub's crumb names a project only while its view shows,
            // as a host page's names its host.
            let shownProject = (shell.debugSlotController(destination) as? DevOpsHubController)?.shownProject
            let crumbEnd = destination == .devopsHub ? (shownProject?.name ?? row.title) : row.title
            check(shell.toolbar.debugCrumb.hasSuffix(crumbEnd) && window.titleVisibility == .hidden,
                  "the crumb reads \"\(shell.toolbar.debugCrumb)\" on \(destination.rawValue), want \(row.title)", &ok)
            // The big title, with the page's live subtitle under it - except
            // on Connections and Console, where the captain dropped it.
            let page = shell.debugSlotController(destination) as? DaylightDrillActions
            let live = page?.drillHeaderSubtitle ?? destination.drillSubtitle
            // Home has no live subtitle of its own, so its header carries the day.
            let subtitle = destination == .homeCanvas && live.isEmpty ? MainSplitShellController.homeSubtitle() : live
            // Tf-2, Cf-4 and Sk-1: a page whose own hero says what its line
            // said draws no line, though its subtitle is still its summary.
            let drawsLine = (page as? WorkspaceHeaderLineCollapsing)?.drawsSubtitleOnHeaderLine ?? true
            if module.showsHeader && !drawsLine {
                check(shell.debugHeader == nil,
                      "\(destination.rawValue) repeats \(String(describing: shell.debugHeader)) over its own hero", &ok)
                check(!live.isEmpty, "\(destination.rawValue) has no summary for the crew panel", &ok)
            } else if module.showsHeader {
                check(shell.debugHeader?.title == row.title && shell.debugHeader?.subtitle == subtitle,
                      "\(destination.rawValue)'s header is \(String(describing: shell.debugHeader)), want \(row.title) / \(subtitle)", &ok)
            } else {
                check(shell.debugHeader == nil, "\(module.title) draws a header the captain dropped", &ok)
            }
            // The middle of the toolbar: the module's tabs with this page's
            // lit, or nothing for a module that is one page - and nothing for
            // Home, whose five spaces were a second map of the app (R2-UX-02).
            let names = shell.toolbar.debugTabNames
            if module == .home {
                check(names.isEmpty, "Home's toolbar still shows tabs \(names) (R2-UX-02 retired its spaces)", &ok)
            } else if row == .calendar {
                // R5-UX-04: the Calendar is a place of its own, and its tabs
                // are its periods, with the one on screen lit.
                let calendar = (shell.debugSlotController(.shift) as? ShiftController)?.calendar
                check(names == ShiftCalendarScale.toolbarOrder.map(\.title)
                        && selectedTabName(shell) == calendar?.scale.title,
                      "the Calendar's toolbar shows \(names) with \(selectedTabName(shell) ?? "nothing") lit", &ok)
            } else if row != module, !row.drawsToolbarTabs {
                // R5-UX-05: a listed door row to a page of its own draws no
                // host tab bar.
                check(names.isEmpty, "\(row.title), a place of its own, shows \(module.title)'s tabs \(names)", &ok)
            } else if module.drawsToolbarTabs {
                check(names == module.tabs.map(\.name), "\(module.title)'s toolbar shows \(names)", &ok)
                let lit = selectedTabName(shell).flatMap { name in module.tabs.first { $0.name == name } }
                check(lit?.route == landing.route && (landing.pageTab == nil || lit?.name == landing.pageTab),
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

    /// The narrowest window that keeps the sidebar beside the showing page,
    /// re-measured until the column floor stops moving under it.
    ///
    /// R4-PROC-01: "overview at 998pt: the sidebar is collapsed", twice in 22
    /// `main` runs. A traced replay on CI showed the floor includes a legacy
    /// scroller's track (760pt + 15 for Overview, so 1013pt), and both
    /// failures measured 998 - the same floor without the track. CI's
    /// runner changes `NSScroller.preferredScrollerStyle` after launch (the
    /// same flip `HomeCanvasController`'s clip observer records), and the
    /// shell re-fits the panes on that notification. So the floor was read
    /// under overlay scrollers, the style turned legacy during the resize's
    /// settle, and the shell rightly stepped the sidebar aside at a width
    /// that no longer had room. Waiting for the floor to hold, rather than
    /// trusting one reading, is the check measuring what it means to.
    private static func narrowestWidthKeepingSidebar(_ shell: MainSplitShellController, _ window: NSWindow) -> CGFloat {
        var keep = shell.debugNarrowestWidthKeepingSidebar.rounded(.up) + 1
        for _ in 0..<3 {
            resize(window, width: keep, shell)
            let now = shell.debugNarrowestWidthKeepingSidebar.rounded(.up) + 1
            if now == keep { break }
            keep = now
        }
        return keep
    }

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
            let keep = narrowestWidthKeepingSidebar(shell, window)
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
        // Stage 7: Tasks' column became the band's filters, and P-03 removed
        // the column itself, so no tab brings a column out at all.
        shell.workspace.navigator.show(.shift)
        settle(shell)
        check(!(shell.debugSlotController(.shift) is HelmSplitPageHosting),
              "Tasks has a page column of its own again", &ok)
        for tab in ["Board", "Weekly review", "List", "Board"] {
            clickTab(tab, shell)
            check(abs(window.frame.width - 1100) < 0.5,
                  "Tasks' \(tab) tab grew a 1100pt window to \(Int(window.frame.width))pt", &ok)
        }
        // A column that does come back - Notebook's Pages, put away and
        // brought back by Toggle Sidebar, unanimated - takes its room from
        // the page. (Tasks' Weekly review used to force its column away; P-03
        // removed that switch with the column.)
        shell.workspace.navigator.show(.notebook)
        settle(shell)
        let sidebarBefore = shell.debugSidebarIsCollapsed
        if let split = (shell.debugSlotController(.notebook) as? HelmSplitPageHosting)?.splitPage {
            let column = split.debugSidebarWidth
            check(!split.isSidebarCollapsed && column > 0, "Notebook opened without its Pages column", &ok)
            let savedMotion = HelmMotion.reducedOverrideForTests
            HelmMotion.reducedOverrideForTests = true
            defer { HelmMotion.reducedOverrideForTests = savedMotion }
            split.toggleSidebar(nil)
            settle(shell)
            check(split.isSidebarCollapsed, "Notebook's column did not step aside", &ok)
            split.toggleSidebar(nil)
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
        clickTab("Reading list", shell)
        check(shell.sidebar.debugClick(.module(.crew)), "the Crew row is not in the sidebar", &ok)
        settle(shell)
        check(shell.currentModule == .crew, "the Crew row opened \(shell.currentModule.title)", &ok)
        check(shell.sidebar.debugClick(.module(.knowledge)), "the Knowledge row is not in the sidebar", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .readingList,
              "Knowledge's row reopened \(String(describing: shell.debugCurrentDestination)), not the Reading list tab it showed last", &ok)

        // A page inside a module of several lights its module's row.
        shell.workspace.navigator.show(.review)
        shell.workspace.navigator.show(.strawHat)
        settle(shell)
        check(shell.sidebar.debugSelectedEntry == .module(.crew),
              "a page reached from outside the sidebar lit \(String(describing: shell.sidebar.debugSelectedEntry))", &ok)

        // Home and every module the sidebar lists have a visible row, under
        // their own names, and a hidden one has none (R5-UX-05: an
        // Operator's sidebar hides the Notebook and Reading list door rows).
        let entries = shell.sidebar.debugVisibleEntries
        let hidden = AppSettings.shared.hiddenModules
        for module in WorkspaceModule.allCases {
            check(entries.contains(.module(module)) == !hidden.contains(module),
                  "\(module.title)'s row is \(entries.contains(.module(module)) ? "shown" : "missing") with \(hidden.map(\.rawValue).sorted()) hidden", &ok)
        }
        check(!hidden.isEmpty, "the sidebar check hides nothing, so it cannot see a hidden row drawn", &ok)
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
                // R5-UX-04: Tasks' Calendar tab stays a shortcut to the
                // Calendar, which is a place with its own toolbar - so the
                // next tab is reached from the Tasks row again.
                if shell.toolbar.debugTabNames.firstIndex(of: tab.name) == nil {
                    shell.openModule(module)
                    settle(shell)
                }
                check(clickTab(tab.name, shell), "\(module.title)'s toolbar has no \(tab.name) tab", &ok)
                if ModuleTable.litModule(for: tab.route, pageTab: tab.name, hidden: AppSettings.shared.hiddenModules) == .calendar {
                    check(shell.debugCurrentTab == tab && shell.sidebar.debugSelectedEntry == .module(.calendar)
                            && shell.toolbar.debugTabNames == ShiftCalendarScale.toolbarOrder.map(\.title),
                          "\(module.title) › \(tab.name) did not open the Calendar with its own toolbar", &ok)
                    continue
                }
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
        // The toolbar's tabs are the page's only switcher...
        if let shift = shell.debugSlotController(.shift) as? ShiftController {
            check(!shift.debugHasOwnViewSwitcher, "Tasks draws a view switcher of its own under the toolbar's tabs", &ok)
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
            // C-4: the split's pane holds the hero column
            // (`HostsController+HeroColumn.swift`).
            check(hosts.heroColumn?.isHidden == false,
                  "the Hosts page's hero column is not out beside Connections' tabs", &ok)
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

        // The badge is the bell's own count, from the one store. (`debugReset`
        // tells no observer, so the first real change is what the toolbar sees.)
        let center = GrandLineNotificationCenter.shared
        center.debugReset()
        defer { center.debugReset() }
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
        // On Home, which fills no inspector: on a page that does, the
        // inspector button is `.high` (R4-UI-01, `WorkspaceToolbarSelfTest`).
        for id in [WorkspaceToolbar.ItemID.recents, WorkspaceToolbar.ItemID.inspector] {
            check(priority(id) == .low, "\(id.rawValue) is not among the first to overflow", &ok)
        }
        check(items.first { $0.itemIdentifier == WorkspaceToolbar.ItemID.recents }?.menuFormRepresentation?.action != nil,
              "Recents does nothing from the overflow menu", &ok)

        // UI-08 of full review 4: at 1512 an open inspector takes 320pt of
        // the toolbar's room, and the full toolbar does not fit beside it -
        // AppKit clipped the crumb at its leading edge ("rk › Connections").
        // The toolbar goes compact instead: the crumb gives up its group,
        // keeps the page's name whole, and outlasts Quick Connect and the
        // module's action, since the window itself is not narrow.
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        check(shell.toolbar.debugCrumb.hasPrefix("Work"), "fixture: the crumb has no group to drop (\(shell.toolbar.debugCrumb))", &ok)
        shell.setInspectorShown(true)
        settle(shell)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "UI-08: fixture: the inspector did not open", &ok)
        check(shell.toolbar.debugIsCompact, "UI-08: at 1512 beside the open inspector the toolbar is not compact", &ok)
        check(shell.toolbar.debugCrumb == "Connections",
              "UI-08: beside the inspector the crumb reads \"\(shell.toolbar.debugCrumb)\", want the page's name alone", &ok)
        check(shell.toolbar.toolbar.items.first { $0.itemIdentifier == WorkspaceToolbar.ItemID.crumb }?.visibilityPriority
                == WorkspaceToolbar.crumbPriority,
              "UI-08: beside the inspector the crumb yields before Quick Connect", &ok)
        shell.setInspectorShown(false)
        settle(shell)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        settle(shell)
        check(!shell.toolbar.debugIsCompact && shell.toolbar.debugCrumb.hasPrefix("Work"),
              "UI-08: with the inspector closed the crumb reads \"\(shell.toolbar.debugCrumb)\"", &ok)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)

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
        let band = shell.workspace.console.sessionBand
        check(!band.isHiddenOrHasHiddenAncestor && band.debugChipHostIDs() == [host],
              "Console has a live session but its band lists \(band.debugChipHostIDs())", &ok)
        check(shell.sidebar.debugSelectedEntry == .module(.console), "the Console row is not lit", &ok)
        // The band is Console's page: no other module carries it.
        shell.workspace.navigator.show(.review)
        settle(shell)
        check(band.isHiddenOrHasHiddenAncestor, "the session band followed the page change out of Console", &ok)
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
        // The feel pass draws the briefing as the hero above the grid, so the
        // grid is the arranged cards less that one (`checkHomeFeelPass`).
        check(canvas.visibleModulesForTests == HomeCardLayout.standard.shown.filter { $0 != .briefing },
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
        // Customize draws the briefing as a card; after Done it is the hero.
        check(canvas.visibleModulesForTests == after.filter { $0 != .briefing }, "Done changed the arrangement", &ok)
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

    /// The captain's report: with the sidebar open, Home's cards stopped
    /// filling their rows. A card the narrower grid made too small was
    /// widened on its own, so a row that summed to the whole grid overflowed -
    /// Health dropped to a row of its own, Merge queue sat alone at half
    /// width, and every row ended short of the right edge.
    ///
    /// Measured on real cards in a real window: at each width, with the
    /// sidebar open and put away, every row reaches the grid's right edge,
    /// no card is narrower than the canvas's minimum, and nothing overlaps.
    /// Home's own cards and the captain's own arrangement (from their
    /// screenshot: 12, 7 and 5 columns, then two halves) both.
    /// The feel pass's item 6: switching density reaches rows already on
    /// screen. The sidebar repaints a theme re-fire in place, so it has to
    /// notice that its row heights moved, as it does for the text scale.
    private static func checkDensityReachesTheSidebar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                      _ ok: inout Bool) {
        let saved = AppSettings.shared.density
        defer {
            AppSettings.shared.density = saved
            settle(shell)
        }
        AppSettings.shared.density = .comfortable
        settle(shell)
        let comfortable = shell.sidebar.debugRowHeight(for: .module(.tasks)) ?? 0
        AppSettings.shared.density = .compact
        settle(shell)
        let compact = shell.sidebar.debugRowHeight(for: .module(.tasks)) ?? 0
        check(comfortable > 0 && compact > 0 && compact < comfortable,
              "the sidebar's Tasks row is \(comfortable)pt Comfortable and \(compact)pt Compact", &ok)
        check(abs(compact - HelmType.scaledRowHeight(WorkspaceSidebarMetrics.moduleRowHeight)) < 0.5,
              "the Compact Tasks row is \(compact)pt, want \(HelmType.scaledRowHeight(WorkspaceSidebarMetrics.moduleRowHeight))", &ok)
    }

    /// The feel pass's item 5: the toolbar's module tabs are the kit's
    /// sliding strip, and a click moves its thumb onto the tab it chose.
    private static func checkToolbarTabsSlide(_ shell: MainSplitShellController, _ window: NSWindow,
                                              _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        shell.workspace.navigator.show(.shift)
        settle(shell)
        guard let strip = shell.toolbar.debugTabs, shell.toolbar.debugTabNames.count > 1 else {
            fail("Tasks shows no tab strip in the toolbar - the slide check is vacuous", &ok)
            return
        }
        let names = shell.toolbar.debugTabNames
        // A tab that is not lit already, or nothing has to move.
        let start = shell.toolbar.debugSelectedTab ?? 0
        let index = start == 0 ? 1 : 0
        let target = names[index]
        let before = strip.debugThumbFrame
        check(clickTab(target, shell), "the toolbar has no \(target) tab", &ok)
        settle(shell)
        let lit = shell.toolbar.debugSelectedTab
        check(lit == index, "clicking \(target) lit tab \(String(describing: lit))", &ok)
        let after = shell.toolbar.debugTabs?.debugThumbFrame ?? .zero
        check(after.width > 0 && abs(after.minX - before.minX) > 1,
              "the thumb did not move to \(target): \(before) then \(after)", &ok)
        _ = clickTab(names[start], shell)
    }

    /// The feel pass (the feasibility audit's items 1 to 3) on real Home in a
    /// real window: the greeting is the page's title in place of the
    /// column's date line, the briefing is the gradient hero above the grid
    /// rather than a card in it, the strip has the audit's four tiles, and
    /// Customize draws the briefing as a card again so it can be placed.
    private static func checkHomeFeelPass(_ shell: MainSplitShellController, _ window: NSWindow,
                                          _ ok: inout Bool) {
        let saved = AppSettings.shared.homeCardLayout
        defer {
            AppSettings.shared.homeCardLayout = saved
            shell.debugHomeCanvas.cardLayout = saved
            shell.debugHomeCanvas.setCustomizing(false)
            resize(window, width: 1512, shell)
        }
        shell.workspace.navigator.show(.homeCanvas)
        let canvas = shell.debugHomeCanvas
        AppSettings.shared.homeCardLayout = .standard
        canvas.cardLayout = .standard
        check(HomeCardLayout.standard.shown.contains(.briefing) && HomeCanvasController.briefingHasSomethingToSay,
              "fixture: the briefing is not on Home with something to say - the hero check measures nothing", &ok)
        resize(window, width: 1512, shell)
        settle(shell)
        _ = settleHomeGrid(shell, canvas)
        check(shell.debugHeader == nil, "the column still draws Home's date line over the greeting", &ok)
        guard let hero = canvas.debugBriefingHero else {
            fail("the briefing is not drawn as the hero", &ok)
            return
        }
        // Hg-2: the greeting is the hero's title, its date leads the kicker,
        // and the day's verdict is the hero's pill - with no second greeting
        // on the page ground above it.
        let content = hero.debugContent
        let greeting = content.greeting ?? ""
        check(greeting.hasSuffix(HomeGreeting.captainName(fleetCaptain: nil)) || greeting.contains(", "),
              "Hg-2: the hero's greeting reads \"\(greeting)\"", &ok)
        check(!canvas.debugGreetingOnGround, "Hg-2: the greeting is drawn twice, on the page and in the hero", &ok)
        check(content.kicker.hasPrefix(HomeGreeting.date() + " \u{00B7} Morning briefing"),
              "Hg-2: the hero's kicker does not open with the day: \"\(content.kicker)\"", &ok)
        check(hero.debugGreetingLabel != nil && !(content.status?.text ?? "").isEmpty && hero.debugStatusPill != nil,
              "Hg-2: the hero draws no greeting or no verdict pill", &ok)
        check(canvas.cardForTests(.briefing) == nil, "the briefing is drawn twice: as the hero and as a card", &ok)
        check(hero.frame.width > 600, "the hero is \(hero.frame.width)pt wide - not the page's width", &ok)
        // The captain removed the band between the hero and the cards: no
        // KPI tiles on Home. (The Needs attention card that sat there was
        // deleted in the P-03 sweep, so there is no type left to look for.)
        func findsCaption(_ view: NSView, _ words: String) -> Bool {
            if !view.isHidden, let label = view as? NSTextField, label.stringValue == words { return true }
            return view.subviews.contains { !$0.isHidden && findsCaption($0, words) }
        }
        for caption in ["Tasks due today", "PRs ready to merge", "Services healthy"] {
            check(!findsCaption(canvas.view, caption), "Home still draws the \"\(caption)\" tile", &ok)
        }
        // The cards start right under the hero: one grid gap, no hole.
        if let first = canvas.moduleCardsForTests.first {
            let heroBottom = hero.convert(hero.bounds, to: nil).minY
            let cardTop = first.convert(first.bounds, to: nil).maxY
            check(abs(heroBottom - cardTop - HomeCanvasController.gridSpacing) < 1.5,
                  "the first card sits \(heroBottom - cardTop)pt under the hero, want \(HomeCanvasController.gridSpacing)", &ok)
        } else {
            fail("Home's arranged space drew no cards", &ok)
        }
        canvas.setCustomizing(true)
        settle(shell)
        _ = settleHomeGrid(shell, canvas)
        check(canvas.debugBriefingHero == nil && canvas.cardForTests(.briefing) != nil,
              "Customize does not draw the briefing as a card the captain can place", &ok)
    }

    /// R5-UI-08: with the briefing off and nothing on record, Home's own
    /// cards are the other four, and the slot the briefing had is not left as
    /// a hole: every row still reaches the grid's edge. Customize still draws
    /// it, so the captain can place or hide it.
    private static func checkHomeLeavesAnOffBriefingOff(_ shell: MainSplitShellController, _ window: NSWindow,
                                                       _ ok: inout Bool) {
        let record = AppSettings.shared.morningBriefingRecord
        let saved = AppSettings.shared.homeCardLayout
        AppSettings.shared.morningBriefingEnabled = false
        AppSettings.shared.morningBriefingRecord = nil
        defer {
            AppSettings.shared.morningBriefingEnabled = true
            AppSettings.shared.morningBriefingRecord = record
            AppSettings.shared.homeCardLayout = saved
            shell.debugHomeCanvas.cardLayout = saved
            shell.debugHomeCanvas.setCustomizing(false)
            resize(window, width: 1512, shell)
        }
        shell.workspace.navigator.show(.homeCanvas)
        let canvas = shell.debugHomeCanvas
        AppSettings.shared.homeCardLayout = .standard
        canvas.cardLayout = .standard
        check(HomeCardLayout.standard.shown.contains(.briefing),
              "fixture: Home's own cards no longer include the briefing - this check measures nothing", &ok)
        for width: CGFloat in [1512, 1100] {
            resize(window, width: width, shell)
            settle(shell)
            guard settleHomeGrid(shell, canvas) else {
                fail("R5-UI-08 at \(Int(width))pt: Home never reflowed", &ok)
                continue
            }
            let rows = canvas.gridRowsForTests
            let cards = rows.map { $0.arrangedSubviews.compactMap { $0 as? HelmModuleCard } }
            check(canvas.cardForTests(.briefing) == nil && cards.joined().count == 4,
                  "R5-UI-08 at \(Int(width))pt: with the briefing off Home draws \(cards.joined().count) cards"
                  + (canvas.cardForTests(.briefing) != nil ? ", the briefing among them" : ""), &ok)
            for (index, row) in cards.enumerated() {
                guard let last = row.last else { continue }
                check(abs(last.frame.maxX - rows[index].bounds.width) < 1,
                      "R5-UI-08 at \(Int(width))pt: row \(index + 1) ends at \(last.frame.maxX)pt of "
                      + "\(rows[index].bounds.width)pt - the briefing's slot is a hole", &ok)
            }
        }
        canvas.setCustomizing(true)
        settle(shell)
        _ = settleHomeGrid(shell, canvas)
        check(canvas.cardForTests(.briefing) != nil,
              "R5-UI-08: Customize does not draw the briefing, so the captain cannot place it", &ok)
    }

    private static func checkHomeRowsFillBesideTheSidebar(_ shell: MainSplitShellController, _ window: NSWindow,
                                                         _ ok: inout Bool) {
        let saved = AppSettings.shared.homeCardLayout
        defer {
            AppSettings.shared.homeCardLayout = saved
            shell.debugHomeCanvas.cardLayout = saved
            if shell.debugSidebarIsCollapsed { shell.toggleSidebarFromMenu() }
            resize(window, width: 1512, shell)
        }
        let captains = HomeCardLayout(shown: [.briefing, .fleet, .health, .claudeStatus, .mergeQueue],
                                      sizes: [.briefing: .init(columns: 12), .fleet: .init(columns: 7),
                                              .health: .init(columns: 5), .claudeStatus: .init(columns: 12),
                                              .mergeQueue: .init(columns: 12)])
        shell.workspace.navigator.show(.homeCanvas)
        let canvas = shell.debugHomeCanvas
        var sawANarrowedCard = false
        for (name, layout) in [("Home's own cards", HomeCardLayout.standard), ("the captain's arrangement", captains)] {
            AppSettings.shared.homeCardLayout = layout
            canvas.cardLayout = layout
            for width: CGFloat in [1512, 1280, 1100] {
                for sidebarOpen in [true, false] {
                    resize(window, width: width, shell)
                    if shell.debugSidebarIsCollapsed == sidebarOpen { shell.toggleSidebarFromMenu() }
                    settle(shell)
                    let when = "\(name) at \(Int(width))pt, sidebar \(sidebarOpen ? "open" : "away")"
                    guard settleHomeGrid(shell, canvas) else {
                        fail("\(when): Home never reflowed for its \(canvas.gridRowsForTests.first?.bounds.width ?? 0)pt "
                             + "grid within 2s", &ok)
                        continue
                    }
                    guard shell.debugSidebarIsCollapsed != sidebarOpen else {
                        fail("\(when): the sidebar would not \(sidebarOpen ? "open" : "go away") - the case is vacuous", &ok)
                        continue
                    }
                    let rows = canvas.gridRowsForTests
                    let gridWidth = rows.map(\.frame.width).max() ?? 0
                    let cards = rows.map { $0.arrangedSubviews.compactMap { $0 as? HelmModuleCard } }
                    // Less the briefing, which the feel pass draws as the hero.
                    let inGrid = layout.shown.filter { $0 != .briefing }.count
                    check(cards.joined().count == inGrid,
                          "\(when): \(cards.joined().count) of \(inGrid) cards are on Home", &ok)
                    for (index, row) in cards.enumerated() {
                        guard let last = row.last else { continue }
                        let stack = rows[index]
                        let reach = last.frame.maxX
                        check(abs(reach - stack.bounds.width) < 1,
                              "\(when): row \(index + 1) (\(row.count) cards) ends at \(reach)pt of \(stack.bounds.width)pt", &ok)
                        for card in row where card.frame.width < HomeCanvasController.minModuleWidth - 1 {
                            fail("\(when): a card in row \(index + 1) is \(card.frame.width)pt, under the minimum", &ok)
                        }
                    }
                    if layout == captains, let health = canvas.cardForTests(.health),
                       health.frame.width > HomeCardGrid.width(columns: 5, containerWidth: gridWidth,
                                                               spacing: HomeCanvasController.gridSpacing) + 1 {
                        sawANarrowedCard = true
                    }
                    checkNoCardsOverlap(canvas, when, &ok)
                }
            }
        }
        // The window really did make a saved card too narrow somewhere, or
        // nothing above was ever asked to reflow.
        check(sawANarrowedCard, "no width made the captain's 5-column card too narrow - the reflow is never exercised", &ok)

        // Arranging beside the sidebar: at 1512 the captain's row draws as
        // 11, 7 and 6. The captain sizes what they see - drag Fleet a column
        // narrower and Morning briefing stays the 11 it was drawn at, rather
        // than its stored 12 coming back to fill the column Fleet let go.
        AppSettings.shared.homeCardLayout = captains
        canvas.cardLayout = captains
        resize(window, width: 1512, shell)
        if shell.debugSidebarIsCollapsed { shell.toggleSidebarFromMenu() }
        settle(shell)
        shell.debugModuleAction()
        settle(shell)
        defer { if canvas.isCustomizing { shell.debugModuleAction(); settle(shell) } }
        guard canvas.isCustomizing, let fleet = canvas.cardForTests(.fleet),
              let grip = canvas.resizeHandlesForTests[.fleet]?.first(where: { $0.edge == .trailing }) else {
            fail("Customize did not open on the captain's arrangement - the drag check is vacuous", &ok)
            return
        }
        let gridWidth = canvas.gridRowsForTests.map(\.frame.width).max() ?? 0
        let spacing = HomeCanvasController.gridSpacing
        let unit = HomeCardGrid.unitWidth(containerWidth: gridWidth, spacing: spacing)
        check(abs(fleet.frame.width - HomeCardGrid.width(columns: 7, containerWidth: gridWidth, spacing: spacing)) < 1,
              "before the drag Fleet is \(fleet.frame.width)pt, not 7 columns - the drag check starts wrong", &ok)
        let briefingWidth = canvas.cardForTests(.briefing)?.frame.width ?? 0
        check(abs(briefingWidth - HomeCardGrid.width(columns: 11, containerWidth: gridWidth, spacing: spacing)) < 1,
              "before the drag Morning briefing is \(briefingWidth)pt, not the 11 columns its row draws it at", &ok)
        grip.debugDrag(dx: -(unit + spacing), dy: 0)
        settle(shell)
        let kept = AppSettings.shared.homeCardLayout
        let columns = [DaylightModule.briefing, .fleet, .health].map { kept.size(of: $0).columns }
        check(columns == [11, 6, 6], "a column-narrower drag on Fleet kept \(columns), want [11, 6, 6]", &ok)
        for (module, span) in [(DaylightModule.briefing, 11), (.fleet, 6), (.health, 6)] {
            let width = canvas.cardForTests(module)?.frame.width ?? 0
            check(abs(width - HomeCardGrid.width(columns: span, containerWidth: gridWidth, spacing: spacing)) < 1,
                  "after the drag \(module.rawValue) is \(width)pt, not \(span) columns", &ok)
        }
        checkNoCardsOverlap(canvas, "after a drag beside the sidebar", &ok)
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

    /// Tasks and the calendar are one surface (tasks-calendar plan PR 4):
    /// the toolbar's calendar button and the Calendar sidebar row are doors
    /// to Tasks' Calendar view, the Calendar row is lit while that view shows
    /// and the Tasks row on its other views, and a filter set on Board is
    /// still the filter on the calendar.
    private static func checkTheCalendarButton(_ shell: MainSplitShellController, _ window: NSWindow,
                                               _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        let store = shell.workspace.shiftStore
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        guard let item = shell.toolbar.toolbar.items.first(where: { $0.itemIdentifier == WorkspaceToolbar.ItemID.calendar }),
              let action = item.action else {
            fail("the toolbar has no calendar button on Hosts", &ok)
            return
        }
        check(item.visibilityPriority != .low, "the calendar button is among the first to overflow", &ok)

        // The button: the button's own target and action, from a page far
        // from Tasks.
        _ = NSApplication.shared.sendAction(action, to: item.target, from: item)
        settle(shell)
        check(shell.debugCurrentDestination == .shift && tasks.isShowingCalendar,
              "the calendar button went to \(String(describing: shell.debugCurrentDestination)), "
              + "Tasks on \(tasks.selectedModuleTabName)", &ok)
        // R5-BUG-05: the crumb and the header name the row the sidebar
        // lights, so the Calendar view reads "Work › Calendar" beside a lit
        // Calendar row. R5-UX-04: its tabs are its own periods, not Tasks'
        // views, and its action is New task. UI-05 of full review 4: Today
        // is the head's alone, beside its arrows, not a second copy here.
        check(shell.currentModule == .tasks && shell.toolbar.debugCrumb.hasSuffix("Calendar"),
              "the calendar button drew \(shell.currentModule.title)'s chrome (\(shell.toolbar.debugCrumb)), "
              + "want a Work \u{203A} Calendar crumb", &ok)
        check(shell.toolbar.debugTabNames == ["Day", "Week", "Month", "Agenda"]
                && selectedTabName(shell) == tasks.calendar.scale.title,
              "the calendar button lit \(selectedTabName(shell) ?? "no tab") of \(shell.toolbar.debugTabNames)", &ok)
        let actionTitles = shell.toolbar.debugPageActions.compactMap { ($0 as? HelmButton)?.title }
        check(!actionTitles.contains("Today") && (shell.toolbar.debugPrimaryAction as? HelmButton)?.title == "New task",
              "the Calendar's toolbar carries \(actionTitles) and \(String(describing: (shell.toolbar.debugPrimaryAction as? HelmButton)?.title))", &ok)
        // A period tab is the card's own pill: Week shows the week, and
        // ⌘⇧] steps on to Month.
        clickTab("Week", shell)
        check(tasks.calendar.scale == .week && selectedTabName(shell) == "Week" && tasks.isShowingCalendar,
              "the Week tab left the calendar on \(tasks.calendar.scale.title)", &ok)
        shell.selectNextModuleTab(nil)
        settle(shell)
        check(tasks.calendar.scale == .month && selectedTabName(shell) == "Month",
              "\u{2318}\u{21E7}] on the Calendar's Week showed \(tasks.calendar.scale.title)", &ok)
        check(shell.sidebar.debugSelectedEntry == .module(.calendar),
              "Tasks' Calendar view lit \(String(describing: shell.sidebar.debugSelectedEntry)), want the Calendar row", &ok)
        // Cf-4: the caption line is gone - the month head says it - and the
        // filters are the head's own menus, so nothing sits over the card.
        check(shell.debugHeader == nil,
              "the Calendar view's header line still reads \(String(describing: shell.debugHeader))", &ok)
        check(!tasks.calendar.caption.isEmpty, "the calendar has no caption for the page's summary", &ok)
        check(!tasks.debugCalendarSection.isHidden
                && tasks.calendar.debugCalendarView.debugHeroHead?.debugMenuButtons != nil,
              "the Calendar view should show the calendar with its filter menus on the month head", &ok)

        // The calendar fills the column under the filter row, and gives the
        // window back its size.
        let section = tasks.debugCalendarSection
        let clip = section.enclosingScrollView?.contentView
        let below = section.convert(section.bounds, to: clip)
        check(clip.map { below.maxY <= $0.bounds.maxY + 1 && below.height > ShiftCalendarView.minimumHeight - 30 } ?? false,
              "the calendar should fill the column under the filter row, it sits at \(below) in \(clip?.bounds ?? .zero)", &ok)

        // The Tasks row leaves the Calendar for Board and lights Tasks; the
        // Calendar row brings the view back; the Tasks row returns to Board
        // rather than to the Calendar.
        check(shell.sidebar.debugClick(.module(.tasks)), "the sidebar has no Tasks row", &ok)
        settle(shell)
        // It reopens the Tasks view shown last (List, after the tab sweep),
        // never the Calendar.
        check(shell.sidebar.debugSelectedEntry == .module(.tasks) && tasks.debugCalendarSection.isHidden
                && ["Board", "List"].contains(selectedTabName(shell) ?? ""),
              "the Tasks row lit \(String(describing: shell.sidebar.debugSelectedEntry)) on \(selectedTabName(shell) ?? "nothing"), want Tasks on a Tasks view", &ok)
        clickTab("Board", shell)
        check(!(shell.toolbar.debugPageActions.compactMap { ($0 as? HelmButton)?.title }.contains("Today")),
              "Board's toolbar still carries the Calendar's Today", &ok)
        check(shell.toolbar.debugCrumb.hasSuffix("Tasks") && shell.debugHeader == nil,
              "Board's crumb and header read \(shell.toolbar.debugCrumb) / \(shell.debugHeader?.title ?? "none"), want Tasks and no line", &ok)
        check(shell.sidebar.debugClick(.module(.calendar)), "the sidebar has no Calendar row", &ok)
        settle(shell)
        check(tasks.isShowingCalendar && selectedTabName(shell) == tasks.calendar.scale.title
                && shell.sidebar.debugSelectedEntry == .module(.calendar),
              "the Calendar row opened Tasks on \(tasks.selectedModuleTabName)", &ok)
        check(shell.toolbar.debugCrumb.hasSuffix("Calendar"),
              "the Calendar row lit beside a \(shell.toolbar.debugCrumb) crumb", &ok)
        check(shell.sidebar.debugClick(.module(.tasks)), "the sidebar has no Tasks row", &ok)
        settle(shell)
        check(selectedTabName(shell) == "Board" && shell.sidebar.debugSelectedEntry == .module(.tasks),
              "the Tasks row after the Calendar opened \(selectedTabName(shell) ?? "nothing")", &ok)

        // A filter set on Board is the filter on the calendar: Overdue keeps
        // the late task on the calendar and in the tray's pinned rows, and
        // takes today's task off it.
        let today = Calendar.current.startOfDay(for: Date())
        func day(_ offset: Int) -> String {
            ShiftDateFormatting.components(from: Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today).dateStr
        }
        var late = ShiftTask.fresh()
        late.title = "Renew the staging certificate"
        late.dueDate = day(-2)
        store.addTask(late)
        var current = ShiftTask.fresh()
        current.title = "Rotate the deploy key"
        current.dueDate = day(0)
        store.addTask(current)
        settle(shell)
        // The page was empty until these two tasks, so it was showing its
        // start-here state with the band hidden (R2-UX-07). The band comes
        // back on the store's coalesced re-render, one main-queue turn after
        // `addTask`, and `settle`'s one 50 ms turn did not always cover that
        // turn on CI's loaded runner. The press then reached no band at all,
        // through an optional chain that cannot fail, and four checks below
        // failed instead of this one (PR #633's push). Wait for the band
        // itself, bounded, and say so by name if it never comes.
        let bandDeadline = Date().addingTimeInterval(2)
        while tasks.debugHeroBand == nil, Date() < bandDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let band = tasks.debugHeroBand
        check(band != nil,
              "the band never came back after two tasks were added (start-here showing: "
                + "\(!tasks.debugStartHereState.isHidden), calendar: \(tasks.isShowingCalendar))", &ok)
        // Tf-2: through the band's own Overdue figure.
        check(band?.debugFigureButtons[2].performPrimaryAction() == true,
              "the band's Overdue figure did nothing when pressed", &ok)
        settle(shell)
        check(tasks.taskScope == .overdue, "the Overdue filter did not take on Board", &ok)
        clickTab("Calendar", shell)
        let calendarView = tasks.calendar.debugCalendarView
        let events = Set(calendarView.debugEventIDs)
        let overdue = (calendarView.debugTrayPayload["overdue"] as? [[String: Any]] ?? []).compactMap { $0["taskID"] as? String }
        check(tasks.taskScope == .overdue, "switching to the Calendar dropped the Board's filter", &ok)
        // The fixture's own discriminating power: both tasks fall in the
        // month the calendar opens on, so only the filter can tell them apart.
        let unfiltered = ShiftCalendarModel.entries(tasks: [late, current],
                                                    from: Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today,
                                                    through: Calendar.current.date(byAdding: .day, value: 7, to: today) ?? today)
        check(unfiltered.count == 2, "the fixture's two tasks did not both land on the calendar unfiltered", &ok)
        check(!events.contains(current.id) && overdue.contains(late.id),
              "with Overdue set on Board the calendar draws \(events.sorted()) and pins \(overdue)", &ok)
        // Cf-4: the month head says which filter is on, drawn solid.
        let scopeMenu = tasks.calendar.debugCalendarView.debugHeroHead?.debugMenuButtons?.scope
        check(scopeMenu?.title.hasPrefix("Showing Overdue") == true && scopeMenu?.heroSelection != nil,
              "the filtered calendar's scope menu reads \(scopeMenu?.title ?? "nothing")", &ok)
        tasks.debugPickScopeFromMenu(ShiftController.ShiftTaskScope.all.rawValue)
        settle(shell)
        check(tasks.taskScope == .all, "All tasks from the calendar's menu left \(tasks.taskScope) on", &ok)
        check(Set(calendarView.debugEventIDs).contains(current.id),
              "All tasks on the calendar should draw today's task again, got \(calendarView.debugEventIDs)", &ok)
        store.deleteTask(id: late.id)
        store.deleteTask(id: current.id)
        shell.openModule(.tasks)
        settle(shell)
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
        // A captain's change is saved on the next main-queue turn
        // (`WorkspaceToolbar.captainChangedItems`). One 50ms drain missed that
        // turn on CI's loaded runner - "taking Recents off saved nil" and its
        // mirror below, on main as well - so a save that must land is waited
        // for. A save that must not happen still gets the plain drain.
        func drain(until saved: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !saved(), Date() < deadline { drain() }
        }
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
        let expected = WorkspaceToolbar.defaultCustomizedIdentifiers.filter { $0 != WorkspaceToolbar.ItemID.recents }
        drain { AppSettings.shared.workspaceToolbarItems == expected.map(\.rawValue) }
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
        drain { AppSettings.shared.workspaceToolbarItems == nil }
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
}

#endif
