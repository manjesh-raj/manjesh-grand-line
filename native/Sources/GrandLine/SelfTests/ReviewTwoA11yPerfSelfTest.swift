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
        for check in [checkTheLabelsSayWhatTheControlsDo, checkHealthReadsInWords, checkTheSidebarFitsAtLarger] {
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

    // MARK: R2-A11Y-04 - colour is not the only carrier

    private static func checkHealthReadsInWords(_ shell: MainSplitShellController, _ window: NSWindow,
                                                _ ok: inout Bool) {
        print("\n-- R2-A11Y-04: Health's runs and Home's ring in words --")
        ReviewTourLab.seedDemoHealth(shell.workspace.health)
        shell.workspace.navigator.show(.health)
        settle(shell)
        let registry = ServiceHealthRegistry.shared
        let table = shell.workspace.health.debugHealthCard.debugServicesTable
        let tableView = table.debugTable
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("runs"))
        check(column >= 0, "the services table shows no Recent runs column at 1512", &ok)
        var read = 0
        var mixedSeen = false
        for (row, item) in table.debugRows.enumerated() where column >= 0 {
            guard case .record(let key) = item.kind, let service = HealthService(rawValue: key) else { continue }
            let want = HealthCardView.runTicksSpoken(registry.state(service))
            guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true),
                  let label = textFields(in: cell).first else {
                fail("\(service.title): no Recent runs cell", &ok)
                continue
            }
            read += 1
            if want.contains("failure"), want.contains("success") { mixedSeen = true }
            check(label.accessibilityLabel() == want,
                  "\(service.title)'s runs (\"\(label.stringValue)\") read \"\(label.accessibilityLabel() ?? "")\", want \"\(want)\"",
                  &ok)
        }
        check(read >= 5, "only \(read) Recent runs cells were read", &ok)
        check(mixedSeen, "the fixture has no service with both a failure and a success", &ok)

        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        settle(shell)
        let readings = registry.knownServices().map { service -> HomeCanvasController.HealthServiceReading in
            let state = registry.state(service)
            return .init(title: service.title, verdict: state.verdict, hasReported: state.hasReported)
        }
        let want = HomeCanvasController.healthRingSpoken(readings)
        let ring = shell.debugHomeCanvas.cardForTests(.health)?.debugRingGauge
        check(ring != nil, "Home's Health card draws no ring", &ok)
        check(ring?.isAccessibilityElement() == true && ring?.accessibilityLabel() == want,
              "Home's Health ring reads \"\(ring?.accessibilityLabel() ?? "nil")\", want \"\(want)\"", &ok)
        if ok { print("  OK   every Recent runs cell and Home's Health ring carry their counts in words") }
    }

    // MARK: R2-A11Y-05 - the sidebar at the Larger text scale

    /// Every module row at the Larger chrome text scale, in the narrowest
    /// column the sidebar is drawn at (236pt, below which it steps aside),
    /// each with a two-digit attention pill - the widest badge there is. The
    /// review asked whether "Connections" and a two-digit badge still fit.
    /// This asks it of every row, measured after a real layout pass.
    private static func checkTheSidebarFitsAtLarger(_ shell: MainSplitShellController, _ window: NSWindow,
                                                    _ ok: inout Bool) {
        print("\n-- R2-A11Y-05: every sidebar row fits a 236pt column at Larger --")
        let savedScale = ChromeTextScale.shared.scale
        let savedFrame = window.frame
        defer {
            ChromeTextScale.shared.setScale(savedScale)
            MainSplitShellController.routeFloorOverrideForTests = nil
            window.setFrame(savedFrame, display: true)
            settle(shell)
        }
        let larger = ChromeTextScale.steps.first { $0.title == "Larger" }?.scale ?? ChromeTextScale.maxScale
        ChromeTextScale.shared.setScale(larger)
        // A floor that leaves the window's width to decide the sidebar's.
        MainSplitShellController.routeFloorOverrideForTests = 600
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        var frame = window.frame
        let chromeWidth = frame.width - window.contentRect(forFrameRect: frame).width
        frame.size.width = shell.debugNarrowestWidthKeepingSidebar + chromeWidth
        window.setFrame(frame, display: true)
        settle(shell)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        settle(shell)
        let column = shell.sidebar.view.frame.width
        check(!shell.debugSidebarIsCollapsed && abs(column - MainSplitShellController.sidebarComfortWidth) <= 1,
              "the sidebar is \(shell.debugSidebarIsCollapsed ? "collapsed" : "\(column)pt"), want the 236pt column", &ok)

        // Each row with the widest badge it can carry: a two-digit pill on
        // every module whose badge is a count, its own mark on Health and
        // Secrets, and none on the rest. Under both scroller styles, because
        // "Show scroll bars: Always" reserves a track that narrows every row
        // by about 15pt - measured on CI's runner, which shows them always.
        let pill = WorkspaceBadge(mark: .count("16"), tone: .attention, description: "16 things")
        let widest: [WorkspaceModule: WorkspaceBadge] = [
            .tasks: pill, .crew: pill, .console: pill, .setup: pill,
            .health: WorkspaceBadge(mark: .dot, tone: .alarm, description: "failing"),
            .secrets: WorkspaceBadge(mark: .symbol("exclamationmark.triangle.fill"), tone: .alarm, description: "unreadable"),
        ]
        func fits(_ module: WorkspaceModule, _ badge: WorkspaceBadge?, _ when: String) -> Bool {
            guard let row = cell(module, shell) else {
                fail("\(module.title): no row", &ok)
                return false
            }
            row.setBadge(badge, theme: ThemeManager.shared.theme)
            row.layoutSubtreeIfNeeded()
            defer { row.setBadge(nil, theme: ThemeManager.shared.theme) }
            let label = row.debugLabel
            let needed = label.intrinsicContentSize.width
            check(label.font?.pointSize ?? 0 >= WorkspaceSidebarMetrics.moduleTextSize * larger - 0.5,
                  "\(module.title): its row was not rebuilt at the Larger scale (\(label.font?.pointSize ?? 0)pt)", &ok)
            let whole = label.frame.width >= needed - 0.5
            let apart = badge == nil || (label.frame.maxX <= row.badgeView.frame.minX + 0.5
                                         && row.badgeView.frame.maxX <= row.bounds.maxX + 0.5)
            check(whole, "\(when): \(module.title) is truncated at Larger in a \(column)pt column - "
                  + "\(label.frame.width)pt of \(needed)pt", &ok)
            check(apart, "\(when): \(module.title)'s label and badge overlap or overflow a \(row.bounds.width)pt row", &ok)
            return whole && apart
        }
        var measured = 0
        var rowWidths: [NSScroller.Style: CGFloat] = [:]
        for (style, name) in [(NSScroller.Style.overlay, "overlay scrollers"), (.legacy, "always-visible scrollers")] {
            shell.sidebar.debugSetScrollerStyle(style)
            settle(shell)
            rowWidths[style] = cell(.connections, shell)?.bounds.width
            for module in WorkspaceSidebarModel.listedModules() {
                _ = fits(module, widest[module], name)
                measured += 1
            }
        }
        check(measured == WorkspaceSidebarModel.listedModules().count * 2, "only \(measured) rows were measured", &ok)
        // The legacy half has to narrow the rows, or on a Mac with overlay
        // scrollers it measures the overlay case twice.
        check((rowWidths[.overlay] ?? 0) - (rowWidths[.legacy] ?? 0) > 5,
              "always-visible scrollers did not narrow the rows (\(rowWidths)), so that half measures nothing", &ok)
        // The review's own question, "Connections" beside a two-digit badge,
        // which Connections never carries: it fits with overlay scrollers.
        // With always-visible ones it is a few points short, which the PR
        // reports rather than this case hiding.
        shell.sidebar.debugSetScrollerStyle(.overlay)
        settle(shell)
        _ = fits(.connections, pill, "overlay scrollers, the review's case")
        shell.sidebar.debugSetScrollerStyle(NSScroller.preferredScrollerStyle)
        settle(shell)
        if ok { print("  OK   \(measured) rows with their widest badge, under both scroller styles, fit a \(column)pt column at \(larger)x") }

        // The full-width attention card at the same scale: a long verdict
        // wraps inside the card and leaves Refresh on it, rather than running
        // past the card and out of the window (found in the Larger renders).
        let canvas = shell.debugHomeCanvas
        var summary = ReviewTourLab.demoAttentionSummary(count: 4)
        summary.headline = "Two things are late, and point Grand Line at your firstmate home, and Claude is near "
            + "its spend cap, and two more are due today."
        canvas.debugAttentionOverride = summary
        defer { canvas.debugAttentionOverride = nil }
        for width: CGFloat in [1512, 1100] {
            var wide = window.frame
            wide.size.width = width
            window.setFrame(wide, display: true)
            shell.workspace.navigator.show(.homeCanvas)
            settle(shell)
            canvas.debugRenderNow()
            settle(shell)
            let card = canvas.debugAttentionCard
            let headline = card.debugHeader.titleLabel
            let refresh = card.debugRefreshButton
            let inCard = { (view: NSView) in view.convert(view.bounds, to: card) }
            check(card.debugHeadline == summary.headline, "\(width): the card shows \"\(card.debugHeadline)\"", &ok)
            check(card.bounds.width > 0 && inCard(headline).maxX <= card.bounds.maxX + 0.5,
                  "\(width): the headline ends at \(inCard(headline).maxX) in a \(card.bounds.width)pt card", &ok)
            check(inCard(headline).height > headline.font.map { $0.boundingRectForFont.height * 1.5 } ?? 0,
                  "\(width): a headline longer than the card did not wrap (\(inCard(headline).height)pt tall)", &ok)
            check(card.debugRefreshButtonVisible && inCard(refresh).maxX <= card.bounds.maxX + 0.5,
                  "\(width): Refresh ends at \(inCard(refresh).maxX) in a \(card.bounds.width)pt card", &ok)
        }
        if ok { print("  OK   the full-width attention headline wraps inside its card at 1512 and 1100") }
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
    }
}

#endif
