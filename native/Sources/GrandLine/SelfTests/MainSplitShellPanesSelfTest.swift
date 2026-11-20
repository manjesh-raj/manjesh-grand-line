// Grand Line - native macOS app.
//
// Stages 3 and 4 of the modular-shell migration: the sidebar shell
// (`MainSplitShellController`), mounted in a real off-screen window and
// driven through its own controls. This half is the frame around the page:
// the inspector beside it, where its first content starts, the foot it
// reaches, the sidebar's width next to it, and what the toolbar keeps room
// for. The other half, `MainSplitShellNavigationSelfTest`, is how the
// captain gets around.
//
//   1. **The inspector** opens and closes from its toolbar button on every
//      page, is the system's own sidebar item, lies inside the window, and
//      its empty state follows the theme (S22).
//   2. **One page frame** (S03): every page's first content starts at one
//      height under the toolbar.
//   3. **The lock hides what the overlay cannot cover** - the toolbar.
//   4. **No status strip, on any module.** The captain had it removed
//      everywhere: under every module the content reaches the foot of the
//      window. What it carried is elsewhere and checked here - the live
//      sessions in Console's session strip and the sidebar, and the focus
//      timer's chip, with its ring popover, in the toolbar.
//   5. **The sidebar keeps one width on every page.** A page laid out for a
//      wider column no longer squeezes it, and a divider can still be placed.
//   6. **Toasts land in the content column**, not the sidebar.
//   7. **The account menu** is Log Out only, under a rule that sets the
//      header apart from Home.
//   8. **Notebook leaves the toolbar room at 1100** (R2-BUG-07).
//   9. **Tasks fits its page** (full review #4): Follow-ups is a lane on the
//      board, and the filter row collapses rather than running past the edge.
//
// Split from `MainSplitShellNavigationSelfTest` when the two together came
// within seconds of the runner's 300s bound on CI; `MainSplitShellHarness`
// holds the one setup both use.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_MAIN_SPLIT_SHELL_PANES_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum MainSplitShellPanesSelfTest {

    static func run() -> Bool {
        MainSplitShellHarness.run("MainSplitShellPanesSelfTest", [
            checkTheInspector, checkTheInspectorIsTheSystemsItem, checkTheInspectorEmptyStateFollowsTheTheme,
            checkEveryPageStartsAtOneHeight,
            checkTheLockHidesTheToolbar, checkTheContentReachesTheFoot, checkTheFocusChipIsInTheToolbar,
            checkTheFocusChipFitsTheNarrowToolbar, checkOnlyADividerDragIsAChosenWidth,
            checkTheSidebarKeepsOneWidthOnEveryPage, checkToastsLandInTheColumn,
            checkTheAccountMenu, checkNotebookLeavesTheToolbarRoomAtNarrowWidths,
            checkTasksBoardAndFilterRow,
        ])
    }

    private static func settle(_ shell: MainSplitShellController) {
        MainSplitShellHarness.settle(shell)
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: MainSplitShellController) {
        MainSplitShellHarness.resize(window, width: width, shell)
    }

    private static func checkTheInspector(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        check(shell.debugInspectorIsCollapsed, "the inspector is open at launch", &ok)
        // R2-BUG-10: the button draws the standing choice. At launch it is
        // on, so a selection opens the inspector.
        check(shell.toolbar.debugInspectorSymbolName == WorkspaceToolbar.inspectorOnSymbol,
              "R2-BUG-10: at launch the inspector button draws \(shell.toolbar.debugInspectorSymbolName)", &ok)
        checkTheInspectorOpensOnEveryPage(shell, window, &ok)
        // A page that does fill it, with nothing selected yet, opens on its
        // own empty text.
        resize(window, width: 1512, shell)
        shell.workspace.navigator.show(.hosts)
        settle(shell)
        check(shell.toolbar.debugInspectorItem?.isEnabled == true,
              "the inspector button is disabled on Connections, which fills it", &ok)
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

    /// The captain's call, reversing R4-UX-05's disabled button: the
    /// inspector opens and closes from its toolbar button on every page,
    /// including the 26 that fill nothing in it (Home and Console among
    /// them), where it opens on the pane's empty state. A press goes through
    /// the item's own target and action, and only once the item says it is
    /// enabled, since AppKit sends no action for a disabled one. Then an
    /// inspector the captain opened stays open across a page change, and one
    /// they closed stays closed.
    private static func checkTheInspectorOpensOnEveryPage(_ shell: MainSplitShellController, _ window: NSWindow,
                                                         _ ok: inout Bool) {
        let walked = RailDestination.allCases
        var sources: [RailDestination] = []
        for destination in walked {
            resize(window, width: 1512, shell)
            shell.workspace.navigator.show(destination)
            settle(shell)
            let fillsInspector = shell.debugSlotController(destination) is WorkspaceInspectorSource
            if fillsInspector { sources.append(destination) }
            if !shell.debugInspectorIsCollapsed { shell.setInspectorShown(false); settle(shell) }
            guard let item = shell.toolbar.debugInspectorItem else {
                fail("the toolbar has no inspector button on \(destination.rawValue)", &ok)
                return
            }
            check(item.isEnabled, "the inspector button is disabled on \(destination.rawValue)", &ok)
            guard item.isEnabled else { continue }
            check(item.toolTip == "Show the inspector" || item.toolTip?.contains("is off") == true,
                  "the closed inspector's button on \(destination.rawValue) says \(item.toolTip ?? "nothing")", &ok)
            _ = shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector)
            settle(shell)
            check(!shell.debugInspectorIsCollapsed, "the inspector button did not open the inspector on \(destination.rawValue)", &ok)
            check(item.toolTip == "Hide the inspector",
                  "the open inspector's button on \(destination.rawValue) says \(item.toolTip ?? "nothing")", &ok)
            // Open is not enough: it must be inside the window. A page that
            // holds its own width (Home's grid) once kept the column wide and
            // laid the inspector out past the trailing edge. Such a page
            // re-lays out over a few turns, as it does for the sidebar.
            let inside = settleInspectorInsideWindow(shell, window)
            check(inside.isInside,
                  "the open inspector on \(destination.rawValue) ends at \(inside.maxX)pt, past the \(window.frame.width)pt window", &ok)
            // S27: a page that fills nothing opens on the crew panel (or, on
            // a Personal install, the page's shortcuts), never an empty pane.
            if !fillsInspector {
                check(shell.inspector.hostedContentView === shell.crewPanel.view
                        && shell.inspector.debugTitle == shell.crewPanel.paneTitle,
                      "S27: the inspector on \(destination.rawValue) does not show the crew panel", &ok)
                check(shell.crewPanel.context.module == shell.currentModule,
                      "S27: the crew panel on \(destination.rawValue) holds \(shell.crewPanel.context.module)'s context", &ok)
            }
            _ = shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector)
            settle(shell)
            check(shell.debugInspectorIsCollapsed, "the inspector button did not close the inspector on \(destination.rawValue)", &ok)
        }
        // Fixture: the walk crossed both kinds of page, so it proved the
        // button on pages that fill nothing, not only on the four that do.
        check(!sources.isEmpty && sources.count < walked.count && !sources.contains(.homeCanvas) && !sources.contains(.console),
              "fixture: the pages that fill the inspector are \(sources.map(\.rawValue))", &ok)

        // Opened on Home, it stays open on Console and on Settings, and
        // closed on Console it stays closed back on Home.
        resize(window, width: 1512, shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        _ = shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector)
        settle(shell)
        check(!shell.debugInspectorIsCollapsed, "the inspector button did not open the inspector on Home", &ok)
        for destination in [RailDestination.console, .settings] {
            shell.workspace.navigator.show(destination)
            settle(shell)
            check(!shell.debugInspectorIsCollapsed, "the inspector opened on Home closed on \(destination.rawValue)", &ok)
        }
        shell.workspace.navigator.show(.console)
        settle(shell)
        _ = shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector)
        settle(shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        check(shell.debugInspectorIsCollapsed, "the inspector closed on Console opened again on Home", &ok)
    }

    /// Wait for the open inspector to lie inside the window: a page laid out
    /// for a wider column gives it room over the next few turns (Home's grid
    /// measured about 200 ms). Returns where it ended either way.
    private static func settleInspectorInsideWindow(_ shell: MainSplitShellController,
                                                    _ window: NSWindow) -> (isInside: Bool, maxX: CGFloat) {
        func maxX() -> CGFloat {
            let pane = shell.inspector.view
            return pane.convert(pane.bounds, to: nil).maxX
        }
        let deadline = Date().addingTimeInterval(2)
        while maxX() > window.frame.width + 0.5, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            shell.view.layoutSubtreeIfNeeded()
        }
        return (maxX() <= window.frame.width + 0.5, maxX())
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

    // MARK: S22 - the inspector's empty state follows the theme

    /// S22 of the 2026-11-17 UI/UX proposals. The inspector's "Nothing
    /// selected" read paler than its own body text in Daylight. Measured
    /// before the fix: after a switch from Dusk to Daylight the title still
    /// held Dusk's ink (E8E6DE) and the body Dusk's muted ink, because
    /// `HelmEmptyState` painted the theme once at `init` and the inspector
    /// never passed a change on. The label is not vibrant, so the system
    /// glass was not the cause.
    ///
    /// Each register is reached by a switch from the other one, with the
    /// empty state already built, which is the case that went stale. The live
    /// label colours must be the theme's ink and muted ink, and the title's
    /// rendered glyphs must carry the ink, compared in the bitmap's own
    /// colour space (AGENTS.md's probe rule: convert the expected colour,
    /// leave the sample alone).
    private static func checkTheInspectorEmptyStateFollowsTheTheme(_ shell: MainSplitShellController,
                                                                  _ window: NSWindow, _ ok: inout Bool) {
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved); settle(shell) }
        resize(window, width: 1512, shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        shell.setInspectorShown(true)
        settle(shell)
        defer { shell.setInspectorShown(false); shell.debugResetInspectorPreference(); settle(shell) }
        shell.inspector.setContent(nil)
        settle(shell)
        let empty = shell.inspector.debugEmptyState
        check(!empty.isHidden, "S22: the inspector's empty state is not showing", &ok)

        func close(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) <= 0.02 && abs(a.greenComponent - b.greenComponent) <= 0.02
                && abs(a.blueComponent - b.blueComponent) <= 0.02
        }
        func describe(_ color: NSColor?) -> String {
            guard let c = color?.usingColorSpace(.sRGB) else { return "nil" }
            return String(format: "%.3f %.3f %.3f", c.redComponent, c.greenComponent, c.blueComponent)
        }

        // The fixture can tell the two registers apart: Daylight's ink and
        // Dusk's are not within the tolerance of each other.
        let daylightInk = HelmTheme.nsColor(HelmTheme.daylight.chromeInkHex)
        let duskInk = HelmTheme.nsColor(HelmTheme.dusk.chromeInkHex)
        check(!close(daylightInk, duskInk), "S22: Daylight's and Dusk's ink are too close for this check to fail", &ok)

        for (from, to) in [(HelmTheme.dusk, HelmTheme.daylight), (HelmTheme.daylight, HelmTheme.dusk)] {
            ThemeManager.shared.setTheme(from)
            settle(shell)
            ThemeManager.shared.setTheme(to)
            settle(shell)
            let ink = HelmTheme.nsColor(to.chromeInkHex)
            let title = empty.debugTitleLabel
            check(close(title.textColor, ink),
                  "S22: after \(from.id) → \(to.id) the empty state's title is \(describe(title.textColor)), want the ink \(describe(ink))",
                  &ok)
            check(close(empty.debugBodyLabel.textColor, HelmTheme.mutedInk(to)),
                  "S22: after \(from.id) → \(to.id) the empty state's body is \(describe(empty.debugBodyLabel.textColor)), want the muted ink",
                  &ok)

            // What is painted: the title's solid glyph pixels. The state draws
            // no ground of its own, so only fully covered pixels carry the
            // ink unblended.
            guard let rep = title.bitmapImageRepForCachingDisplay(in: title.bounds),
                  title.bounds.width > 0, title.bounds.height > 0 else {
                fail("S22: the empty state's title has no bitmap to render", &ok)
                continue
            }
            title.cacheDisplay(in: title.bounds, to: rep)
            guard let expected = ink.usingColorSpace(rep.colorSpace) else {
                fail("S22: the ink does not convert into the render's colour space", &ok)
                continue
            }
            var nearest = CGFloat.greatestFiniteMagnitude
            var solid = 0
            for py in 0..<rep.pixelsHigh {
                for px in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: px, y: py), c.alphaComponent >= 0.98 else { continue }
                    solid += 1
                    let distance = max(abs(c.redComponent - expected.redComponent),
                                       abs(c.greenComponent - expected.greenComponent),
                                       abs(c.blueComponent - expected.blueComponent))
                    nearest = min(nearest, distance)
                }
            }
            check(solid > 0, "S22: the title rendered no solid glyph pixel after \(from.id) → \(to.id)", &ok)
            check(nearest <= 0.03,
                  "S22: after \(from.id) → \(to.id) no title pixel is the ink (nearest \(String(format: "%.3f", nearest)) away)",
                  &ok)
        }
        if ok { print("  OK   S22: the inspector's empty state takes the theme's ink and muted ink after a switch") }
    }

    // MARK: S03 - one page frame

    /// S03 of the 2026-11-17 UI/UX proposals. Measured before the change
    /// (the proposals' pixel tool over the tour renders, and
    /// `PageScaffoldProbe` in-process): the first content started at ten
    /// heights across the pages, from 76pt (Connections, Commands) to 117pt
    /// (Tasks, Calendar), because each page set its own top constant and the
    /// header line hid on pages with no subtitle.
    ///
    /// Every destination now has the header line's slot under the toolbar,
    /// `pageHeaderLine` tall whether it says anything or not, and its first
    /// content at `pageContentTop` under the toolbar. The scan is the
    /// proposals' own: the first row in the content column that is not page
    /// ground. A page with nothing in the scan's reach (an empty or locked
    /// state centred lower down) has no first content to place and is
    /// skipped, and the check fails if too few pages were measured for it to
    /// mean anything.
    ///
    /// The tolerance is the line plus 4pt, minus 1: a filter row's pills
    /// and a card's antialiased border start a point or two inside the frame
    /// that sits on the line. Schedules is the one page whose first block
    /// draws nothing at its own top - a borderless number strip, whose
    /// large figures' ascent starts its ink 9pt below the frame - so there
    /// the strip's frame is what is checked.
    private static func checkEveryPageStartsAtOneHeight(_ shell: MainSplitShellController, _ window: NSWindow,
                                                        _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        var measured = 0
        var report: [String] = []
        for destination in RailDestination.allCases {
            shell.workspace.navigator.show(destination)
            settle(shell)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            settle(shell)
            guard let reading = PageScaffoldProbe.measure(shell) else {
                fail("S03: \(destination.rawValue) could not be measured", &ok)
                continue
            }
            let slot = shell.debugContentPaneHeader.frame.height
            check(abs(slot - HelmMetrics.pageHeaderLine) < 0.5,
                  "S03: \(destination.rawValue)'s header line is \(slot)pt tall, want \(HelmMetrics.pageHeaderLine)", &ok)
            let line = reading.toolbarBottom + HelmMetrics.pageContentTop
            if destination == .schedules {
                let strip = shell.workspace.schedules.debugSummaryStrip
                let top = window.frame.height - strip.convert(NSPoint(x: 0, y: strip.isFlipped ? 0 : strip.bounds.height), to: nil).y
                check(strip.window != nil && abs(top - line) < 1,
                      "S03: Schedules' number strip starts at \(top)pt, want the line at \(line)", &ok)
                measured += 1
                continue
            }
            guard let first = reading.firstContent else {
                report.append("\(destination.rawValue) none")
                continue
            }
            measured += 1
            report.append("\(destination.rawValue) \(first)")
            check(first >= line - 1 && first <= line + 4,
                  "S03: \(destination.rawValue)'s first content starts at \(first)pt, want the line at \(line) (\(reading.line))",
                  &ok)
        }
        // The fixture can fail: enough pages carried content in the scan's
        // reach for a drifted page to be seen.
        check(measured >= 20, "S03: only \(measured) pages had first content to measure (\(report))", &ok)
        if ok { print("  OK   S03: \(measured) pages start their first content on one line under a fixed header line") }
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
        // band (Con-1) has a chip for each one, connected or restored, and
        // the sidebar lists them under Connections, where they were launched
        // from.
        let live = UUID()
        let restored = UUID()
        shell.workspace.hosts.sessions.register(hostID: live, label: "DEV Bastion", accentHex: nil, state: .connected)
        shell.workspace.hosts.sessions.register(hostID: restored, label: "PROD Web", accentHex: nil, state: .restored)
        shell.workspace.navigator.show(.console)
        settle(shell)
        let band = shell.workspace.console.sessionBand
        check(!band.isHiddenOrHasHiddenAncestor && band.debugChipHostIDs() == [live, restored],
              "Console's session band lists \(band.debugChipHostIDs()), want both sessions", &ok)
        let entries = shell.sidebar.debugVisibleEntries
        if let connections = entries.firstIndex(of: .module(.connections)),
           let console = entries.firstIndex(of: .module(.console)) {
            check(Array(entries.dropFirst(connections + 1).prefix(2)) == [.session(hostID: live), .session(hostID: restored)],
                  "the sessions are not listed under Connections", &ok)
            check(entries.dropFirst(console + 1).first.map { $0 != .session(hostID: live) && $0 != .session(hostID: restored) } ?? true,
                  "the sessions are still listed under Console", &ok)
            // A session row under Connections still hands its host to the
            // shell's switch, which opens it on Console's page. These hosts
            // have no page behind them, so the switch itself is recorded on
            // the way through rather than watched.
            let wired = shell.sidebar.onSelectSession
            var picked: UUID?
            shell.sidebar.onSelectSession = { id in picked = id; wired?(id) }
            check(shell.sidebar.debugClick(.session(hostID: restored)), "the restored session's row could not be clicked", &ok)
            settle(shell)
            shell.sidebar.onSelectSession = wired
            check(picked == restored, "clicking a session under Connections did not ask to switch to it", &ok)
        } else {
            fail("Connections or Console is not in the sidebar", &ok)
        }
        shell.workspace.hosts.sessions.unregister(hostID: live)
        shell.workspace.hosts.sessions.unregister(hostID: restored)
        settle(shell)
        check(shell.workspace.console.sessionBand.debugChipHostIDs().isEmpty,
              "Console's session band kept a chip with no sessions", &ok)
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

    // MARK: 11 - one sidebar width on every page

    /// The captain's report: the sidebar was narrower on Home than on Console.
    /// Home holds its grid's last width as a constant at `contentTie` (499),
    /// which beat the sidebar's old 489 hold. So a Home laid out for a wider
    /// column squeezed the sidebar to its 200pt minimum on every visit, and
    /// the next page put it back. Two ways in, both reproduced on main: the
    /// sidebar put away on Home and brought back elsewhere, and the window
    /// narrowed while another page showed.
    private static func checkTheSidebarKeepsOneWidthOnEveryPage(_ shell: MainSplitShellController,
                                                               _ window: NSWindow, _ ok: inout Bool) {
        let resting = MainSplitShellController.sidebarRestingPriority
        check(resting.rawValue > HelmDaylightPriority.contentTie.rawValue && resting.rawValue < NSLayoutConstraint.Priority.windowSizeStayPut.rawValue,
              "the sidebar rests at \(resting.rawValue), want above a page's ties (499) and below the window's 500", &ok)
        let width = window.frame.width
        defer { resize(window, width: width, shell) }
        resize(window, width: 1512, shell)
        shell.debugOpenModule(.home)
        settle(shell)
        let chosen = shell.debugSidebarWidth
        check(!shell.debugSidebarIsCollapsed && shell.debugSidebarHoldingPriority == resting,
              "at rest the sidebar holds at \(shell.debugSidebarHoldingPriority.rawValue), want \(resting.rawValue)", &ok)

        // 1: Home laid out with the sidebar away, which is a wider column
        // than the one it comes back to.
        shell.toggleWorkspaceSidebar()
        settle(shell)
        let sidebarAway = shell.debugContentPane.frame.width
        shell.debugOpenModule(.console)
        settle(shell)
        shell.toggleWorkspaceSidebar()
        settle(shell)
        check(!shell.debugSidebarIsCollapsed && shell.debugContentPane.frame.width < sidebarAway - 100,
              "fixture: with the sidebar back the column is \(shell.debugContentPane.frame.width)pt, "
                + "not narrower than the \(sidebarAway)pt Home was laid out for", &ok)
        for module in ReviewTwoUXSelfTest.sidebarModules(shell) + [.home, .console, .home] {
            shell.debugOpenModule(module)
            settle(shell)
            check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - chosen) < 0.5,
                  "after the sidebar came back, on \(module.title) it is "
                    + "\(shell.debugSidebarIsCollapsed ? "collapsed" : "\(shell.debugSidebarWidth)pt"), want \(chosen)", &ok)
        }

        // 2: the window narrowed while Home was hidden. At 1100 every page's
        // floor still leaves the sidebar its own width.
        shell.debugOpenModule(.console)
        settle(shell)
        resize(window, width: 1100, shell)
        for module in [WorkspaceModule.home, .tasks, .home] {
            shell.debugOpenModule(module)
            settle(shell)
            check(!shell.debugSidebarIsCollapsed && abs(shell.debugSidebarWidth - chosen) < 0.5,
                  "at 1100 on \(module.title) the sidebar is "
                    + "\(shell.debugSidebarIsCollapsed ? "collapsed" : "\(shell.debugSidebarWidth)pt"), want \(chosen)", &ok)
        }
        resize(window, width: 1512, shell)

        // A divider can still be placed: the hold drops for the placement and
        // comes back after, and the new width is the one every page keeps.
        guard let split = shell.debugSplitView, let pane = shell.debugSidebarPane else {
            fail("the shell's split view is not a WorkspaceShellSplitView", &ok)
            return
        }
        let inset = pane.frame.width - shell.debugSidebarWidth
        shell.debugOpenModule(.console)
        settle(shell)
        // The shell holds the sidebar at one width for a turn after a fit
        // (`holdSidebar`), and a placement made inside that turn is refused,
        // as it should be - no real drag lands in it. `settle`'s one 50 ms
        // turn usually covered it and sometimes did not: "setPosition left
        // the sidebar at 264.0pt" in about 1 run in 10 on `main`, with the
        // range still pinned at 264-264 when the placement was made
        // (measured). So the placement waits for the pin to come off, and a
        // pin that never does is a failure in itself.
        check(settleSidebarPin(shell), "the sidebar was still pinned at \(shell.debugSidebarWidth)pt two seconds after a fit", &ok)
        split.setPosition(chosen - 40 + inset, ofDividerAt: 0)
        settle(shell)
        check(abs(shell.debugSidebarWidth - (chosen - 40)) < 0.5 && shell.debugSidebarHoldingPriority == resting,
              "setPosition left the sidebar at \(shell.debugSidebarWidth)pt holding at "
                + "\(shell.debugSidebarHoldingPriority.rawValue), want \(chosen - 40) at \(resting.rawValue)", &ok)
        // Only a drag is the captain's choice (`checkOnlyADividerDragIsAChosenWidth`),
        // so the next page shows the chosen width again.
        shell.debugOpenModule(.home)
        settle(shell)
        check(abs(shell.debugSidebarWidth - chosen) < 0.5,
              "after a placement that was not a drag, Home's sidebar is \(shell.debugSidebarWidth)pt, want \(chosen)", &ok)

        // And a press on the divider reaches the same path, through the
        // window's real event dispatch: lowered for the drag, back after it.
        var holds: [Float] = []
        let placing = split.onPlacingDivider
        split.onPlacingDivider = { isPlacing in
            placing?(isPlacing)
            holds.append(shell.debugSidebarHoldingPriority.rawValue)
        }
        defer { split.onPlacingDivider = placing }
        let onDivider = split.convert(NSPoint(x: pane.frame.maxX + split.dividerThickness / 2, y: split.bounds.midY), to: nil)
        func press(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: onDivider, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let hit = window.contentView.flatMap { $0.hitTest($0.convert(onDivider, from: nil)) }
        check(hit === split, "the point between the panes hits \(hit.map { "\(type(of: $0))" } ?? "nothing"), not the divider", &ok)
        guard let down = press(.leftMouseDown), let up = press(.leftMouseUp) else {
            fail("could not build the divider press", &ok)
            return
        }
        // Queued first: the split view's drag loop takes it, and ends there.
        window.postEvent(up, atStart: false)
        window.sendEvent(down)
        settle(shell)
        let want = [HelmSplitPage.sidebarHoldingPriority.rawValue, resting.rawValue]
        check(holds == want, "a press on the divider held the sidebar at \(holds), want \(want)", &ok)
        check(abs(shell.debugSidebarWidth - chosen) < 0.5,
              "a press on the divider with no drag moved the sidebar to \(shell.debugSidebarWidth)pt", &ok)
        shell.debugOpenModule(.home)
        settle(shell)
    }

    /// Wait for the shell's one-turn sidebar pin to come off. `false` when it
    /// never did, which is a failure in itself.
    private static func settleSidebarPin(_ shell: MainSplitShellController) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while shell.debugSidebarWidthIsPinned, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            shell.view.layoutSubtreeIfNeeded()
        }
        return !shell.debugSidebarWidthIsPinned
    }

    private static func checkToastsLandInTheColumn(_ shell: MainSplitShellController, _ window: NSWindow,
                                                  _ ok: inout Bool) {
        let before = Toast.debugCount(in: shell.debugContentPane)
        shell.showToast("Saved")
        check(Toast.debugCount(in: shell.debugContentPane) == before + 1, "a toast did not land in the content column", &ok)
        check(Toast.debugCount(in: shell.sidebar.view) == 0, "a toast landed in the sidebar", &ok)
    }

    // MARK: 10 - the account menu

    private static func checkTheAccountMenu(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        check(shell.sidebar.debugHeader.debugTitle == AppPaths.displayName, "the sidebar header does not name the app", &ok)
        // Stage 6: Log Out only. Settings is its own sidebar row.
        check(shell.sidebar.debugAccountMenuTitles == ["Log Out\u{2026}"],
              "the account menu offers \(shell.sidebar.debugAccountMenuTitles), want Log Out only", &ok)
        check(shell.sidebar.debugVisibleEntries.contains(.module(.settings)), "Settings has no sidebar row to replace the menu's", &ok)
        check(shell.sidebar.debugClick(.module(.settings)), "the Settings row cannot be clicked", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .settings, "the Settings row did not open Settings", &ok)
        // The captain removed the feel pass's search pill: the toolbar's
        // Search is on every page. The list starts a plain gap under the
        // header, and nothing in the sidebar is a second way into ⌘K.
        let root = shell.sidebar.view
        root.layoutSubtreeIfNeeded()
        let header = shell.sidebar.debugHeader.convert(shell.sidebar.debugHeader.bounds, to: root)
        guard let list = shell.sidebar.outlineView.enclosingScrollView else {
            fail("the sidebar list has no scroll view", &ok)
            return
        }
        let listFrame = list.convert(list.bounds, to: root)
        let gap = root.isFlipped ? listFrame.minY - header.maxY : header.minY - listFrame.maxY
        check(abs(gap - WorkspaceSidebarController.headerGap) < 0.5,
              "the list sits \(gap)pt under the header, want \(WorkspaceSidebarController.headerGap)", &ok)
        func findsSearchWords(_ view: NSView) -> Bool {
            if let label = view as? NSTextField, label.stringValue.lowercased().contains("search") { return true }
            return view.subviews.contains(where: findsSearchWords)
        }
        check(!findsSearchWords(root), "the sidebar still draws a search field", &ok)
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
        // S12: Today's note keeps the short word "Today" beside its glyph.
        check(notebook.debugToolbarActionTitles == ["Today", ""],
              "R2-BUG-07/S12: at 1100 Notebook's toolbar actions read \(notebook.debugToolbarActionTitles)", &ok)
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
        // The view mode is not among them: since R5-UI-01 it sits on the
        // module header's row, so it never overflows.
        check(shell.toolbar.debugPageActionsMenuTitles == ["Today's note", "More"],
              "Notebook's page actions overflow as \(shell.toolbar.debugPageActionsMenuTitles)", &ok)
        // At 1512 too, since U-02 and U-03 (`compactToolbarActionsBelow`).
        resize(window, width: 1512, shell)
        settle(shell)
        check(notebook.debugToolbarActionTitles == ["Today", ""],
              "R2-BUG-07/S12: at 1512 Notebook's toolbar actions read \(notebook.debugToolbarActionTitles)", &ok)
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

    // MARK: R4-UI-08 and R4-UI-09 - Tasks (full review #4)

    /// Follow-ups is a lane on the board while four lanes fit, Projects is the
    /// filter row's pop-up, the filter row collapses into one Filter button
    /// rather than running past the page, and the Weekly review lists next
    /// week. Last in the run: it seeds the shell's Tasks store.

    private static func checkTasksBoardAndFilterRow(_ shell: MainSplitShellController, _ window: NSWindow,
                                                    _ ok: inout Bool) {
        let store = shell.workspace.shiftStore
        ReviewTourLab.seedDemoTasks(store)
        // One follow-up due in the middle of next week, so the agenda has a
        // row whatever day the suite runs on.
        if let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()),
           let midNext = Calendar.current.date(byAdding: .day, value: 3, to: week.end) {
            var followUp = ShiftFollowUp.fresh()
            followUp.title = "Check the quarterly access review"
            followUp.followUpAt = ShiftDateFormatting.components(from: midNext).dateStr
            store.addFollowUp(followUp)
        }
        let pending = store.followUps.filter { $0.status == .pending }.count
        let tasks = shell.workspace.shift
        shell.workspace.navigator.show(.shift)
        tasks.selectModuleTab(named: "Board")
        resize(window, width: 1512, shell)
        let deadline = Date().addingTimeInterval(3)
        while tasks.followUpLane.debugCount != "\(pending)", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(pending >= 2, "the fixture has \(pending) pending follow-ups - the lane check is vacuous", &ok)

        // 1512: Follow-ups on the board, nothing stacked under it, the jump
        // gone with them, and the whole filter row.
        check(tasks.debugFollowUpLaneOnBoard, "R4-UI-09: at 1512 Follow-ups is not a lane on the board", &ok)
        check(tasks.followUpLane.debugCount == "\(pending)",
              "R4-UI-09: the lane counts \(tasks.followUpLane.debugCount) of \(pending) pending follow-ups", &ok)
        check(tasks.debugFollowUpsRowHidden && tasks.debugProjectsSectionHidden,
              "R4-UI-09: at 1512 Follow-ups or Projects still stacks under the board", &ok)
        check(tasks.debugFollowUpsJumpHidden, "R4-UI-09: the Follow-ups jump shows beside the lane it would jump to", &ok)
        check(!tasks.debugFilterRowCollapsed, "R4-UI-08: at 1512 the filter row collapsed", &ok)
        check(tasks.followUpLane.debugMenuTitles(at: 0).contains("Mark Done"),
              "R4-UI-09: a lane card's menu reads \(tasks.followUpLane.debugMenuTitles(at: 0))", &ok)
        // S08: four lanes, one chrome. The page's first render runs before
        // the shell adopts the sidebar layout, which used to leave this lane
        // in the floating bar's classic shape beside three washed lanes.
        let lane = tasks.followUpLane
        check(!lane.debugUsesClassicStyle && lane.debugLaneWashShown,
              "S08: the sidebar layout's Follow-ups lane is not washed like the status lanes", &ok)
        check(lane.debugHeaderMark == .dot(.warn), "S08: the lane lost its amber identity dot", &ok)
        let foot = lane.debugAddRow
        check(foot.inLane && foot.outlined && foot.button.title == "Add follow-up",
              "S08: the lane has no dashed \"Add follow-up\" row (in lane \(foot.inLane), outlined \(foot.outlined))", &ok)
        check(foot.button.target === lane && foot.button.action != nil,
              "S08: \"Add follow-up\" is not wired to the lane's add", &ok)
        checkFilterRowFits(tasks, "1512", &ok)

        // 960: the lanes are too narrow for four, so Follow-ups goes back
        // under the board, and the row collapses into one Filter button.
        resize(window, width: 960, shell)
        check(!tasks.debugFollowUpLaneOnBoard && !tasks.debugFollowUpsRowHidden,
              "R4-UI-09: at 960 Follow-ups is neither off the board nor under it", &ok)
        check(tasks.debugFilterRowCollapsed, "R4-UI-08: at 960 the filter row did not collapse", &ok)
        // S16: the folded controls open in the bar's popover - the same
        // project pop-up, Follow-ups jump and sort, with their own handlers.
        let bar = tasks.debugFilterRow
        check(bar.debugFilterButtonShown, "S16: at 960 the Filter button is not on the row", &ok)
        bar.debugOpenFilters()
        let folded = bar.debugPopoverViews
        check(folded.contains { $0 === tasks.debugProjectPopup } && folded.contains { $0 === tasks.debugSortPopup }
                && folded.contains { $0 === tasks.debugFollowUpsJump },
              "S16: the Filter popover holds \(folded.map { type(of: $0) })", &ok)
        bar.debugCloseFilters()
        check(bar.arrangedSubviews.contains { $0 === tasks.debugProjectPopup }
                && bar.arrangedSubviews.contains { $0 === tasks.debugSortPopup },
              "S16: closing the popover did not put the folded controls back on the row", &ok)
        checkFilterRowFits(tasks, "960", &ok)

        // List keeps Projects under its table; Weekly review lists next week.
        resize(window, width: 1512, shell)
        tasks.selectModuleTab(named: "List")
        settle(shell)
        check(!tasks.debugProjectsSectionHidden, "R4-UI-09: the List tab lost the Projects section", &ok)
        tasks.selectModuleTab(named: "Weekly review")
        settle(shell)
        let agenda = store.nextWeekAgenda()
        check(!agenda.isEmpty, "the fixture has nothing next week - the agenda check is vacuous", &ok)
        check(agenda.count == store.weeklySummary().upcomingCount,
              "R4-UI-09: the agenda lists \(agenda.count) and the tile counts \(store.weeklySummary().upcomingCount)", &ok)
        check(tasks.debugAgendaPanelShown && tasks.debugAgendaRowCount == agenda.count,
              "R4-UI-09: the Weekly review shows \(tasks.debugAgendaRowCount) agenda rows of \(agenda.count)", &ok)
        tasks.selectModuleTab(named: "Board")
    }

    /// Every control the Tasks filter row shows ends inside it, at its own width. Measured
    /// on alignment rects, which is what the stack places: a label's frame
    /// runs a couple of points past its text either side.
    private static func checkFilterRowFits(_ tasks: ShiftController, _ width: String, _ ok: inout Bool) {
        let row = tasks.debugFilterRow
        row.layoutSubtreeIfNeeded()
        for view in row.arrangedSubviews where !view.isHidden && view.fittingSize.width > 0 {
            let placed = view.alignmentRect(forFrame: view.frame)
            check(placed.maxX <= row.bounds.width + 0.5 && view.frame.width + 0.5 >= view.fittingSize.width,
                  "R4-UI-08: at \(width) a \(type(of: view)) is cut at \(view.frame.width) of "
                  + "\(view.fittingSize.width)pt, ending at \(placed.maxX) of \(row.bounds.width)", &ok)
        }
    }
}

#endif
