// Grand Line - native macOS app.
//
// The polish stage of the modular-shell migration, in a real off-screen
// sidebar shell, driven through its own controls and its real sources.
//
//   1. **The panes move on the motion table.** The sidebar's toggle and ⌘⇧D
//      ease it over `WorkspaceMotion.paneDuration`; the inspector's button
//      does the same and slides its panel in, and a selection on another page
//      while it is open brings that panel in again. Under Reduce Motion every
//      one lands at once, with nothing animating.
//   2. **A tab switch moves like a navigation.** One of a page's own tabs, and
//      one of Home's spaces, take the page change's entrance - from the
//      trailing side for a later tab and the leading side for an earlier one -
//      and none of it under Reduce Motion.
//   3. **Rows ease their hover and selection.** A sidebar row eases its fill
//      on a real `mouseEntered`/`mouseExited` and on a navigation, lands at
//      once on a rebuild, and never moves under Reduce Motion; a data table's
//      row view does the same for a state change and not for a theme repaint.
//   4. **The badges come from the real sources.** Crew from the Fleet page's
//      own render (before Crew is ever opened, and a failed read keeping the
//      last count), Tasks from the Shift store, Secrets from the vault's lock,
//      Health and Setup from the registry and the poller, Console from the
//      session registry - each with its accessibility label, and the pill
//      legible in Dusk and Daylight. The layout's status strip, which said
//      the same things in words, is gone at the captain's call; Claude usage,
//      which only the strip drew from the monitor, still reaches Home's
//      Claude card through the Fleet page's own closure.
//
// Every store this suite writes is its own (`SelfTestScratchStores`), and the
// caller's are fingerprinted either side.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_SIDEBAR_POLISH_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SidebarPolishSelfTest {

    static func run() -> Bool {
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let savedFleetState = FleetActions.stateDirectoryOverrideForTests
        defer { FleetActions.stateDirectoryOverrideForTests = savedFleetState }
        let savedCounts = BackgroundSignalsPoller.shared.lastCounts
        defer { BackgroundSignalsPoller.shared.debugSetCounts(savedCounts) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-polish-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            settle(shell)
            // Crew first: its badge must come from the Fleet page's read
            // before Crew has ever been opened.
            for check in [checkCrewBadge, checkPaneMotion, checkInspectorEntrance, checkTabMotion, checkSidebarRowMotion,
                          checkTasksBadge, checkVaultBadge, checkHealthAndSetup, checkSessionsAndClaude] {
                var ok = true
                HelmMotion.reducedOverrideForTests = true
                check(shell, window, scratch, &ok)
                allOK = allOK && ok
            }
            var ok = true
            checkDataTableRowMotion(&ok)
            return allOK && ok
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "SidebarPolishSelfTest: all checks passed" : "SidebarPolishSelfTest: FAILED")
        return allOK
    }

    // MARK: Helpers

    private static func settle(_ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    private static func pump(timeout: TimeInterval = 2, until landed: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !landed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Until every eased pane change has landed (its completion has run),
    /// bounded. Measured on CI: a toggle issued while the last eased expand
    /// was still running was undone when that animation completed.
    private static func waitForPanes(_ shell: MainSplitShellController) {
        pump(timeout: 5) { WorkspaceMotion.debugPaneMotionsInFlight == 0 }
        settle(shell)
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: MainSplitShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    /// The toolbar's tab with this name, through the control's own target and
    /// action, the way a real click reaches it.
    @discardableResult
    private static func clickTab(_ name: String, _ shell: MainSplitShellController) -> Bool {
        let tabs = shell.toolbar.debugTabs
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return false }
        tabs.selectedSegment = index
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        settle(shell)
        return true
    }

    private static func click(_ button: NSButton) {
        _ = button.sendAction(button.action, to: button.target)
    }

    private static func cell(_ module: WorkspaceModule, _ shell: MainSplitShellController) -> WorkspaceSidebarPageCell? {
        shell.sidebar.debugCell(for: .module(module)) as? WorkspaceSidebarPageCell
    }

    private static func badge(_ module: WorkspaceModule, _ shell: MainSplitShellController) -> WorkspaceBadge? {
        cell(module, shell)?.debugBadge
    }

    private static func translationX(_ value: Any?) -> CGFloat? {
        (value as? NSValue).map { $0.caTransform3DValue.m41 }
    }

    // MARK: 1 - the panes

    private static func checkPaneMotion(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                        _ ok: inout Bool) {
        print("\n-- the sidebar and the inspector move on the motion table --")
        resize(window, width: 1512, shell)
        shell.show(.homeCanvas)
        settle(shell)
        let toggle = shell.toolbar.debugSidebarButton

        HelmMotion.reducedOverrideForTests = false
        click(toggle)
        let collapse = shell.lastPaneMotionForTests
        check(collapse?.pane == "sidebar" && collapse?.collapsed == true && collapse?.duration == WorkspaceMotion.paneDuration,
              "the sidebar button's collapse was \(String(describing: collapse)), want it eased over \(WorkspaceMotion.paneDuration)s", &ok)
        waitForPanes(shell)
        check(shell.debugSidebarIsCollapsed, "the eased collapse never landed", &ok)
        click(toggle)
        let expand = shell.lastPaneMotionForTests
        check(expand?.collapsed == false && expand?.duration == WorkspaceMotion.paneDuration,
              "the sidebar button's expand was \(String(describing: expand))", &ok)
        waitForPanes(shell)
        check(!shell.debugSidebarIsCollapsed, "the eased expand never landed", &ok)
        // R2-BUG-02: and it lands at its own width. The eased expand released
        // its pin in the animation's completion, before Home re-laid out for
        // the narrower column, so the sidebar came back squeezed to its 200pt
        // minimum - measured in the review's lab on every run.
        pump(timeout: 1) { abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5 }
        settle(shell)
        check(abs(shell.debugSidebarWidth - MainSplitShellController.sidebarWidth) < 0.5,
              "R2-BUG-02: after an eased hide and show the sidebar is \(shell.debugSidebarWidth)pt, want \(MainSplitShellController.sidebarWidth)", &ok)

        // ⌘⇧D opens it the same way.
        check(!shell.debugSidebarIsCollapsed,
              "before the Reduce Motion collapse the sidebar is already collapsed (last pane change \(String(describing: shell.lastPaneMotionForTests)), window \(window.frame.width)pt)", &ok)
        HelmMotion.reducedOverrideForTests = true
        click(toggle)
        check(shell.debugSidebarIsCollapsed, "Reduce Motion: the collapse did not land at once", &ok)
        check(shell.lastPaneMotionForTests?.duration == nil, "Reduce Motion: the collapse eased", &ok)
        HelmMotion.reducedOverrideForTests = false
        shell.revealDestinationMap()
        check(shell.lastPaneMotionForTests?.collapsed == false && shell.lastPaneMotionForTests?.duration == WorkspaceMotion.paneDuration,
              "⌘⇧D's reveal was \(String(describing: shell.lastPaneMotionForTests)), want it eased", &ok)
        waitForPanes(shell)

        // Reduce Motion: both ways at once.
        check(!shell.debugSidebarIsCollapsed,
              "after ⌘⇧D the sidebar is collapsed (last pane change \(String(describing: shell.lastPaneMotionForTests)))", &ok)
        HelmMotion.reducedOverrideForTests = true
        click(toggle)
        check(shell.debugSidebarIsCollapsed && shell.lastPaneMotionForTests?.duration == nil,
              "Reduce Motion: the sidebar did not collapse at once", &ok)
        click(toggle)
        check(!shell.debugSidebarIsCollapsed && shell.lastPaneMotionForTests?.duration == nil,
              "Reduce Motion: the sidebar did not come back at once", &ok)
        settle(shell)
        if ok { print("  OK   the button and ⌘⇧D ease over the move row; Reduce Motion lands at once") }
    }

    private static func checkInspectorEntrance(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                               _ ok: inout Bool) {
        print("\n-- the inspector slides in --")
        resize(window, width: 1512, shell)
        shell.show(.homeCanvas)
        settle(shell)
        if !shell.debugInspectorIsCollapsed { shell.setInspectorShown(false) }
        settle(shell)
        guard let panel = shell.debugInspector.debugPanelLayer else {
            fail("the inspector has no panel layer to move", &ok)
            return
        }

        HelmMotion.reducedOverrideForTests = false
        panel.removeAllAnimations()
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.inspector), "the toolbar has no inspector button", &ok)
        let open = shell.lastPaneMotionForTests
        check(open?.pane == "inspector" && open?.collapsed == false && open?.duration == WorkspaceMotion.paneDuration,
              "the inspector button's open was \(String(describing: open))", &ok)
        let slide = panel.animation(forKey: "transform") as? CABasicAnimation
        let fade = panel.animation(forKey: "opacity") as? CABasicAnimation
        check(slide?.duration == WorkspaceMotion.inspectorEntranceDuration && fade?.duration == WorkspaceMotion.inspectorEntranceDuration,
              "the panel did not slide and fade in over \(WorkspaceMotion.inspectorEntranceDuration)s (keys \(panel.animationKeys() ?? []))", &ok)
        check(translationX(slide?.fromValue) == WorkspaceMotion.inspectorEntranceOffset,
              "the panel slides from \(String(describing: translationX(slide?.fromValue))), not the prototype's 16pt", &ok)
        check(CATransform3DIsIdentity(panel.transform) && panel.opacity == 1, "the panel's end state is not in place and opaque", &ok)
        waitForPanes(shell)

        // Open, and another page's details arrive: the panel comes in again.
        // A second selection on the same page swaps in place.
        ReviewTourLab.seedDemoHosts(shell.workspace)
        shell.show(.hosts)
        settle(shell)
        panel.removeAllAnimations()
        _ = ReviewTourLab.selectRow(titled: "edge-proxy-01", shell: shell)
        settle(shell)
        check(shell.debugInspector.debugIsShowingContent, "selecting a host did not fill the inspector", &ok)
        check(panel.animation(forKey: "transform") != nil, "a page's details arriving in the open inspector did not slide in", &ok)
        panel.removeAllAnimations()
        _ = ReviewTourLab.selectRow(titled: "grafana", shell: shell)
        settle(shell)
        check(panel.animation(forKey: "transform") == nil, "a second selection on the same page slid the panel in again", &ok)

        // Reduce Motion: open and closed at once, nothing moving.
        HelmMotion.reducedOverrideForTests = true
        shell.setInspectorShown(false)
        check(shell.debugInspectorIsCollapsed && shell.lastPaneMotionForTests?.duration == nil,
              "Reduce Motion: the inspector did not close at once", &ok)
        panel.removeAllAnimations()
        shell.setInspectorShown(true)
        check(!shell.debugInspectorIsCollapsed && shell.lastPaneMotionForTests?.duration == nil,
              "Reduce Motion: the inspector did not open at once", &ok)
        check((panel.animationKeys() ?? []).isEmpty, "Reduce Motion: the panel still moved (\(panel.animationKeys() ?? []))", &ok)
        check(CATransform3DIsIdentity(panel.transform) && panel.opacity == 1, "Reduce Motion: the panel is not in place", &ok)
        shell.setInspectorShown(false)
        shell.debugResetInspectorPreference()
        shell.show(.homeCanvas)
        settle(shell)
        if ok { print("  OK   the pane eases, the panel slides 16pt in, again for another page, and nothing under Reduce Motion") }
    }

    // MARK: 2 - tabs

    private static func checkTabMotion(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                       _ ok: inout Bool) {
        print("\n-- a tab switch moves like a navigation --")
        shell.show(.shift)
        settle(shell)
        clickTab("Board", shell)
        guard let page = shell.destinationViewIfMountedForTests(RailDestination.shift.slot) else {
            fail("Tasks did not mount", &ok)
            return
        }
        let content = shell.workspace.content
        HelmMotion.reducedOverrideForTests = false
        // A navigation to the page already showing records a skipped
        // entrance: the sentinel a tab switch must replace.
        shell.show(.shift)
        check(content.lastTransitionForTests?.skipped == true, "the sentinel navigation was not skipped", &ok)
        page.layer?.removeAllAnimations()
        clickTab("List", shell)
        var t = content.lastTransitionForTests
        check(t?.skipped == false && t?.direction == .drillIn && t?.reducedMotion == false
              && t?.entryOffset == WorkspaceContent.destinationTransitionOffset,
              "Tasks › List took no entrance from the trailing side: \(String(describing: t))", &ok)
        check(page.layer?.animation(forKey: "transform") != nil, "Tasks › List's page did not move", &ok)
        clickTab("Board", shell)
        t = content.lastTransitionForTests
        check(t?.skipped == false && t?.direction == .back && t?.entryOffset == -WorkspaceContent.destinationTransitionOffset,
              "an earlier tab did not come in from the leading side: \(String(describing: t))", &ok)
        // The tab already showing is not a switch.
        shell.show(.shift)
        clickTab("Board", shell)
        check(content.lastTransitionForTests?.skipped == true, "clicking the showing tab moved the page", &ok)

        // Home's spaces took the same entrance until R2-UX-02 retired them
        // in this layout: Home draws no tabs to switch between now.
        shell.show(.homeCanvas)
        settle(shell)
        check(shell.toolbar.debugTabNames.isEmpty, "Home shows tabs \(shell.toolbar.debugTabNames) (R2-UX-02)", &ok)

        // Reduce Motion: the switch happens, the page does not move.
        HelmMotion.reducedOverrideForTests = true
        shell.show(.shift)
        settle(shell)
        page.layer?.removeAllAnimations()
        clickTab("List", shell)
        t = content.lastTransitionForTests
        check(t?.reducedMotion == true && t?.entryOffset == 0, "Reduce Motion: the tab switch still travelled: \(String(describing: t))", &ok)
        check(page.layer?.animation(forKey: "transform") == nil, "Reduce Motion: Tasks' page still moved", &ok)
        check(page.alphaValue == 1, "Reduce Motion: the page is not fully shown", &ok)
        clickTab("Board", shell)
        shell.show(.homeCanvas)
        settle(shell)
        if ok { print("  OK   a later tab from the trailing side, an earlier one from the leading side, Home's spaces, none under Reduce Motion") }
    }

    // MARK: 3 - rows

    private static func checkSidebarRowMotion(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                              _ ok: inout Bool) {
        print("\n-- a sidebar row eases its hover and its selection --")
        shell.show(.homeCanvas)
        settle(shell)
        let theme = ThemeManager.shared.theme
        guard let row = shell.sidebar.debugRowView(for: .module(.tasks)),
              let home = shell.sidebar.debugRowView(for: .module(.home)) else {
            fail("the Tasks or Home row is not on screen", &ok)
            return
        }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   trackingNumber: 0, userData: nil)!
        }
        func same(_ a: CGColor?, _ b: NSColor) -> Bool {
            guard let a, let c = NSColor(cgColor: a) else { return false }
            return HelmContrast.components(c) == HelmContrast.components(b) && abs(c.alphaComponent - b.alphaComponent) < 0.001
        }

        HelmMotion.reducedOverrideForTests = false
        row.debugFill.layer?.removeAllAnimations()
        row.mouseEntered(with: event(.mouseEntered))
        let ease = row.debugFill.layer?.animation(forKey: "backgroundColor") as? CABasicAnimation
        check(ease?.duration == HelmRowWash.duration, "a real mouseEntered did not ease the row's fill over the state row", &ok)
        check(same(row.debugFill.debugFill, WorkspaceSidebarRowView.hover(theme)), "the hovered row is not the hover fill", &ok)
        row.debugFill.layer?.removeAllAnimations()
        row.mouseExited(with: event(.mouseExited))
        check(row.debugFill.debugIsEasing, "mouseExited did not ease the fill away", &ok)
        check(row.debugFill.debugFill.flatMap { NSColor(cgColor: $0) }?.alphaComponent ?? 1 < 0.01,
              "the row kept a fill after the pointer left", &ok)

        // A navigation: the lit wash eases across.
        row.debugFill.layer?.removeAllAnimations()
        home.debugFill.layer?.removeAllAnimations()
        shell.show(.shift)
        check(row.debugFill.debugIsEasing && home.debugFill.debugIsEasing,
              "a navigation did not ease the lit wash from Home to Tasks", &ok)
        check(same(row.debugFill.debugFill, WorkspaceSidebarRowView.wash(theme)), "the lit row is not the accent wash", &ok)

        // A rebuild (a session coming or going) paints at once.
        shell.sidebar.reload(sessions: shell.sessions)
        settle(shell)
        if let rebuilt = shell.sidebar.debugRowView(for: .module(.tasks)) {
            check(!rebuilt.debugFill.debugIsEasing, "a rebuild faded the lit row in rather than painting it", &ok)
            check(same(rebuilt.debugFill.debugFill, WorkspaceSidebarRowView.wash(theme)), "a rebuild lost the lit row's wash", &ok)
        } else {
            fail("the Tasks row is gone after a rebuild", &ok)
        }

        // Reduce Motion: the fill lands at once.
        HelmMotion.reducedOverrideForTests = true
        guard let still = shell.sidebar.debugRowView(for: .module(.console)) else { fail("no Console row", &ok); return }
        still.debugFill.layer?.removeAllAnimations()
        still.mouseEntered(with: event(.mouseEntered))
        check(!still.debugFill.debugIsEasing && same(still.debugFill.debugFill, WorkspaceSidebarRowView.hover(theme)),
              "Reduce Motion: the hover fill eased, or did not land", &ok)
        still.mouseExited(with: event(.mouseExited))
        shell.show(.homeCanvas)
        settle(shell)
        if ok { print("  OK   hover in and out, the lit wash across a navigation, a rebuild at once, Reduce Motion at once") }
    }

    /// The table's real hover entry is `PageRedesignsSelfTest`'s (a real mouse
    /// event reaching `configure(hovered: true)`); this is the row view's half
    /// - that a state change eases and a repaint does not.
    private static func checkDataTableRowMotion(_ ok: inout Bool) {
        print("\n-- a data table's row eases a state change, never a repaint --")
        let window = OffScreenProbe.window(width: 400, height: 80)
        defer { window.orderOut(nil) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        window.contentView = host
        window.orderFront(nil)
        let row = HelmDataTableRowView(frame: NSRect(x: 0, y: 20, width: 400, height: 38))
        host.addSubview(row)
        let theme = ThemeManager.shared.theme
        HelmMotion.reducedOverrideForTests = false
        row.configure(selected: false, hovered: false, separator: true, theme: theme, animated: false)
        row.layoutSubtreeIfNeeded()
        check(!row.debugFill.debugIsEasing, "a row handed its state eased", &ok)
        row.configure(selected: false, hovered: true, separator: true, theme: theme)
        check(row.debugFill.debugIsEasing, "hovering a row did not ease its fill", &ok)
        row.debugFill.layer?.removeAllAnimations()
        row.configure(selected: true, hovered: true, separator: true, theme: theme)
        check(row.debugFill.debugIsEasing, "selecting a row did not ease its fill", &ok)
        row.debugFill.layer?.removeAllAnimations()
        let other = HelmTheme.allThemes.first { $0.id != theme.id } ?? theme
        row.configure(selected: true, hovered: true, separator: true, theme: other)
        check(!row.debugFill.debugIsEasing, "a theme repaint eased the row's fill", &ok)
        HelmMotion.reducedOverrideForTests = true
        row.configure(selected: false, hovered: false, separator: true, theme: theme)
        check(!row.debugFill.debugIsEasing, "Reduce Motion: a state change eased", &ok)
        if ok { print("  OK   hover and selection ease, a hand-off and a repaint do not, Reduce Motion never") }
    }

    // MARK: 4 - badges

    private static func checkCrewBadge(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                       _ ok: inout Bool) {
        print("\n-- Crew's badge, from the Fleet page's own read --")
        ReviewTourLab.seedDemoDecision(shell.workspace.overview, scratch: scratch)
        settle(shell)
        let crew = badge(.crew, shell)
        check(crew?.mark == .count("1") && crew?.tone == .attention,
              "one task waiting drew \(String(describing: crew)), before Crew was ever opened", &ok)
        check(cell(.crew, shell)?.accessibilityLabel() == "Crew, 1 task is waiting on you",
              "Crew's row reads \"\(cell(.crew, shell)?.accessibilityLabel() ?? "")\" to VoiceOver", &ok)

        // The next read cannot list the crew's tasks: the count stays, and
        // says when it was read.
        let failed = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [], queuedCount: 0, doneCount: 0,
                                   projectsCount: 0, watcher: WatcherHealth(status: "healthy"), tasksRead: false)
        shell.workspace.overview.debugRender(snapshot: failed, mergedPRs: [])
        settle(shell)
        let stale = badge(.crew, shell)
        check(stale?.mark == .count("1") && (stale?.description.contains("when last read") ?? false),
              "a failed read drew \(String(describing: stale)), want the last count and when it was read", &ok)

        // Legible in both palettes.
        for id in ["daylight", "dusk"] {
            guard let theme = HelmTheme.theme(id: id) else { fail("no \(id) palette", &ok); continue }
            ThemeManager.shared.setTheme(theme)
            settle(shell)
            guard let view = cell(.crew, shell)?.badgeView, let text = view.debugTextColor, let fill = view.debugFill else {
                fail("\(id): Crew's badge has no digits or no pill", &ok)
                continue
            }
            let ratio = HelmContrast.ratio(text, fill)
            check(ratio >= HelmContrast.textTarget, "\(id): Crew's digits are \(String(format: "%.2f", ratio)):1 on their pill", &ok)
        }
        if ok { print("  OK   a count before Crew opened, a failed read keeps it with its time, legible in Daylight and Dusk") }
    }

    private static func checkTasksBadge(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                        _ ok: inout Bool) {
        print("\n-- Tasks' badge, from the Shift store --")
        let store = shell.workspace.shiftStore
        let monitor = shell.debugSignalsMonitor
        let before = monitor.signals.tasksDue.value?.total ?? 0
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        var task = ShiftTask.fresh()
        task.title = "Sidebar polish fixture"
        task.dueDate = String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        store.addTask(task)
        pump { monitor.signals.tasksDue.value?.total == before + 1 }
        settle(shell)
        check(badge(.tasks, shell)?.mark == .count("\(before + 1)"),
              "a task due today drew \(String(describing: badge(.tasks, shell))) over \(before) before", &ok)
        check(cell(.tasks, shell)?.accessibilityLabel()?.contains("due today") == true,
              "Tasks' row does not say what is due to VoiceOver", &ok)
        _ = store.deleteTask(id: task.id)
        pump { monitor.signals.tasksDue.value?.total == before }
        settle(shell)
        check((badge(.tasks, shell)?.mark) == (before > 0 ? .count("\(before)") : nil),
              "deleting the task left \(String(describing: badge(.tasks, shell)))", &ok)
        if ok { print("  OK   added, counted, removed") }
    }

    private static func checkVaultBadge(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                        _ ok: inout Bool) {
        print("\n-- Secrets' badge, from Poneglyph's lock --")
        let monitor = shell.debugSignalsMonitor
        check(monitor.signals.vault == .none && badge(.secrets, shell) == nil,
              "a scratch Mac with no vault drew \(String(describing: badge(.secrets, shell)))", &ok)
        let store = shell.workspace.credentialVaultStore
        let seeded = ReviewTourLab.seedDemoVault(store)
        settle(shell)
        check(!seeded.contains("FAILED"), "the scratch vault was not created: \(seeded)", &ok)
        check(monitor.signals.vault == .unlocked && badge(.secrets, shell) == nil,
              "an unlocked vault drew \(String(describing: badge(.secrets, shell)))", &ok)
        store.lock(reason: "sidebar polish self-test")
        settle(shell)
        check(badge(.secrets, shell)?.mark == .symbol("lock.fill"), "locking drew \(String(describing: badge(.secrets, shell)))", &ok)
        check(cell(.secrets, shell)?.accessibilityLabel() == "Secrets, Poneglyph is locked",
              "Secrets' row reads \"\(cell(.secrets, shell)?.accessibilityLabel() ?? "")\"", &ok)
        if ok { print("  OK   none, unlocked, locked - through the store's lock, not its onChange") }
    }

    private static func checkHealthAndSetup(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                            _ ok: inout Bool) {
        print("\n-- Health's dot and Setup's count, from the registry and the poller --")
        let registry = ServiceHealthRegistry.shared
        // The registry and the poller are per process, and this process is
        // this suite's; each is put back below.
        for _ in 0..<ServiceHealthRegistry.failureThreshold {
            registry.recordFailure(.docsSync, "sidebar polish self-test")
        }
        pump { shell.debugSignalsMonitor.signals.failingServices.count == 1 }
        settle(shell)
        check(badge(.health, shell)?.mark == .dot && badge(.health, shell)?.tone == .alarm,
              "a failing service drew \(String(describing: badge(.health, shell)))", &ok)
        check(badge(.health, shell)?.description == "Docs & runbooks sync is failing",
              "Health's badge does not name the failing service: \(String(describing: badge(.health, shell)))", &ok)
        registry.recordSuccess(.docsSync)
        NotificationSources.clearServiceFailing(.docsSync)
        pump { shell.debugSignalsMonitor.signals.failingServices.isEmpty }
        settle(shell)
        check(badge(.health, shell) == nil, "a recovered service left its mark", &ok)

        var counts = BackgroundSignalsPoller.shared.lastCounts
        counts.toolUpdates = 2
        counts.forkDrift = 1
        BackgroundSignalsPoller.shared.debugSetCounts(counts)
        counts.setupDrift = 4
        BackgroundSignalsPoller.shared.debugSetCounts(counts)
        pump { shell.debugSignalsMonitor.signals.setup.value == 2 }
        settle(shell)
        // R2-BUG-09: the badge counts the tools needing attention and nothing
        // else - the fork behind and the drifted steps are not added in.
        check(badge(.setup, shell)?.mark == .count("2"),
              "two tools needing attention, a fork behind and four drifted steps drew \(String(describing: badge(.setup, shell)))", &ok)
        BackgroundSignalsPoller.shared.debugSetCounts(BackgroundSignalsPoller.SignalCounts())
        settle(shell)
        if ok { print("  OK   failing and recovered; counted and cleared") }
    }

    private static func checkSessionsAndClaude(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL,
                                               _ ok: inout Bool) {
        print("\n-- Console's count and Claude usage --")
        let live = UUID()
        shell.sessions.register(hostID: live, label: "DEV Bastion", accentHex: nil, state: .connected)
        settle(shell)
        check(badge(.console, shell) == WorkspaceBadge(mark: .count("1"), tone: .neutral, description: "1 connected"),
              "one live session drew \(String(describing: badge(.console, shell)))", &ok)
        shell.sessions.unregister(hostID: live)
        settle(shell)
        check(badge(.console, shell) == nil, "no live sessions left a count", &ok)

        // The Fleet page's own closure, the one Home's card reads - Claude
        // usage's home now the strip is gone, and in the sidebar layout's
        // standard Home.
        let reading = QuotaSnapshot(plan: "team",
                                    session: QuotaWindow(kind: .session, percentUsed: 62, resetsAt: nil, pace: .onPace),
                                    weekly: nil, fable: nil, extraUsage: nil, latency: 1, log: "")
        shell.workspace.overview.onQuotaChanged?(.success(reading))
        shell.show(.homeCanvas)
        settle(shell)
        let home = shell.workspace.homeCanvas
        check(home.cardForTests(.claudeStatus) != nil, "the sidebar layout's Home draws no Claude card", &ok)
        check(home.debugQuota.snapshot?.session?.percentUsed == 62, "Home's Claude card did not get the reading", &ok)
        shell.workspace.overview.onQuotaChanged?(.failure("quota-axi is not installed"))
        settle(shell)
        check(home.debugQuota.snapshot?.session?.percentUsed == 62 && home.debugQuota.failure != nil,
              "a failed Claude reading left Home's card with \(String(describing: home.debugQuota)), want the last reading kept", &ok)
        if ok { print("  OK   a live session counted and gone; Home's Claude card keeps a reading through a failure") }
    }
}

#endif
