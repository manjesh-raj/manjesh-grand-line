// Grand Line - native macOS app.
//
// Stage 7 of the modular-shell migration, on the real off-screen shells: the
// captain's six items, as the pages draw and drive them.
//
//   1. **The sidebar** draws every module at the Large source-list size, and
//      every name and badge fits the column with nothing truncated, in Dusk
//      and Daylight; the whole list fits a 950pt window. Since Sb-4 it is a
//      hero column (1d): a plain split pane with no system material, the
//      gradient edge to edge under the title bar, every word in its ink in
//      every app theme, the lit row a pill with the focus ring inside it,
//      group titles with their counts, rules between rows, the nested
//      sessions, and collapse - with renders beside Home and Tasks when
//      `FM_SIDEBAR_HERO_RENDER_DIR` is set.
//   2. **Quick Connect** on Console is its caption and two icons: Hosts opens
//      Connections' quick-connect field, Console focuses Console's session and
//      opens one only when there is none (the captain's Option B), and the
//      caption's menu form does what Quick Connect did.
//   3. **Tasks**: no page column, the filter row in its place (every scope,
//      the project filter, Follow-ups, the sort and the Done window), New
//      task at the toolbar's far right, the prototype's board lanes and cards,
//      the List tab as one table that completes and reopens a task through
//      its check, Follow-ups as the same table with the same ⋯ menu (Delete
//      included) and an editor sheet with the task editor's Delete, the
//      calendar's month card, and Weekly review's five cards.
//   4. **Setup**: the Sup-1 hero on all four tabs; Updates as one table of
//      tools grouped by source, with Update only where there is one and
//      Check for updates at the far right; Setup steps as a list with Details
//      and the current step's own action; Automation's switches; GitHub
//      sync's paused-push card (only for a confirmed public repo) over the
//      forks table, and a subtitle that never says "all in sync" over checks
//      that failed.
//   5. **The floating bar is unchanged** on every one of those pages, except
//      the GitHub sync subtitle's fix, which is the same in both.
//
// Knowledge with no tree is `PageRedesignsSelfTest`'s, beside the rest of
// Knowledge.
//
// It runs no real check: tool checks come from a fixture through
// `DependencyCheckCache.checkOverrideForTests`, `gh` and `av` are refused in a
// self-test process (`ExternalToolGuard`), every Console session it starts
// is `/usr/bin/true`, and every store a page it mounts can write is the
// suite's own, fingerprinted either side.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_SIDEBAR_REDESIGNS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SidebarRedesignsSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        DependencyCheckCache.checkOverrideForTests = fixtureCheck
        defer { DependencyCheckCache.checkOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let savedCounts = BackgroundSignalsPoller.shared.lastCounts
        defer { BackgroundSignalsPoller.shared.debugSetCounts(savedCounts) }
        defer { ConfigRepoPrivacy.debugReset() }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-redesigns-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Every shell a Console starts in this run is `/usr/bin/true` in the
        // scratch directory, the shared console's own first tab included, so
        // not even a login shell's rc files of the captain's run.
        let savedEnvironment = ["SHELL", "FM_SHELL_CWD"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("SHELL", "/usr/bin/true", 1)
        setenv("FM_SHELL_CWD", scratch.path, 1)
        defer {
            for (name, value) in savedEnvironment {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            do {
                let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                resize(window, width: 1512, shell)
                ReviewTourLab.seedDemoTasks(shell.workspace.shiftStore)
                settle(shell)
                for check in [checkTheSidebar, checkHomeStaysInSight, checkSectionHeadingComesWithTheLitRow,
                              checkQuickConnect, checkTasksBoard, checkTasksList, checkTasksFollowUps,
                              checkTasksReview,
                              checkUpdates, checkGitHubSync, checkSetupSteps, checkAutomation, checkTheSummaryRow,
                              writeSetupRenders,
                              // Last: the theme sweep and the profile renders
                              // leave Setup's seeded readings stale for the
                              // Setup cases above (measured).
                              checkTheHeroColumn, writeSidebarRenders] {
                    var ok = true
                    check(shell, window, &ok)
                    allOK = allOK && ok
                }
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "SidebarRedesignsSelfTest: all checks passed" : "SidebarRedesignsSelfTest: FAILED")
        return allOK
    }

    /// Every tool's check, from a fixture: three of them say something other
    /// than "up to date".
    private static func fixtureCheck(_ item: DependencyItem) -> CheckOutcome {
        switch item.id {
        case "quota-axi":
            return CheckOutcome(installedLabel: "0.1.65", latestLabel: "0.1.66", status: .updateAvailable,
                                detail: "0.1.65 \u{2192} 0.1.66", log: "fixture")
        case "gh":
            return CheckOutcome(installedLabel: "not installed", latestLabel: "2.78.0", status: .notInstalled,
                                detail: "Not installed - 2.78.0 available", log: "fixture")
        case "claude-code":
            return CheckOutcome(installedLabel: "2.1.308", latestLabel: nil, status: .checkFailed,
                                detail: "Installed 2.1.308 - Homebrew could not read the latest version", log: "fixture")
        default:
            return CheckOutcome(installedLabel: "1.0.0", latestLabel: "1.0.0", status: .upToDate,
                                detail: "1.0.0 - up to date", log: "fixture")
        }
    }

    // MARK: 1 - The sidebar

    private static func checkTheSidebar(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        // The column's width is its own, not the window's: 236pt unless the
        // captain drags it, down to 200pt at the least. (A window too narrow
        // for the column and the page's 940pt floor - 1100pt is one - puts
        // the sidebar away rather than squeezing it.) So the rows have to fit
        // at both widths, in both themes.
        guard let split = shell.debugSidebarPane?.superview as? NSSplitView, let pane = shell.debugSidebarPane else {
            fail("the shell has no split view to size the sidebar in", &ok)
            return
        }
        // The divider sits at the pane's edge, and the pane is the sidebar
        // plus its inset (measured 244pt for the 236pt sidebar).
        let inset = pane.frame.width - shell.debugSidebarWidth
        defer {
            split.setPosition(MainSplitShellController.sidebarWidth + inset, ofDividerAt: 0)
            settle(shell)
        }
        for column in [MainSplitShellController.sidebarWidth, MainSplitShellController.sidebarMinimum] {
            split.setPosition(column + inset, ofDividerAt: 0)
            settle(shell)
            check(abs(shell.debugSidebarWidth - column) < 0.5,
                  "the sidebar is \(shell.debugSidebarWidth)pt, the check wants it at \(column)pt", &ok)
            for themeID in ["dusk", "daylight"] {
                guard let theme = HelmTheme.theme(id: themeID) else {
                    fail("no \(themeID) theme", &ok)
                    continue
                }
                ThemeManager.shared.setTheme(theme)
                settle(shell)
                let tag = "[\(themeID), \(Int(column))pt]"
                for module in WorkspaceSidebarModel.listedModules(hidden: AppSettings.shared.hiddenModules) {
                    guard let cell = shell.sidebar.debugCell(for: .module(module)) as? WorkspaceSidebarPageCell else {
                        fail("\(tag) the sidebar draws no row for \(module.title)", &ok)
                        continue
                    }
                    cell.layoutSubtreeIfNeeded()
                    let row = cell.frame.height
                    check(abs(row - HelmType.scaledRowHeight(WorkspaceSidebarMetrics.moduleRowHeight)) < 0.5,
                          "\(tag) \(module.title)'s row is \(row)pt, want the Large size's 32", &ok)
                    check(cell.debugLabel.font?.pointSize == HelmType.scaled(WorkspaceSidebarMetrics.moduleTextSize),
                          "\(tag) \(module.title) is set at \(cell.debugLabel.font?.pointSize ?? 0)pt", &ok)
                    // The layout box, not the frame: an image view showing a
                    // symbol takes its alignment insets from the symbol's own
                    // alignment rect, so its frame is wider and taller than
                    // the 24pt square Auto Layout gives it (measured 24.5 x
                    // 37.5 for Home's house).
                    let icon = cell.debugIcon.alignmentRect(forFrame: cell.debugIcon.frame)
                    let side = HelmType.scaled(WorkspaceSidebarMetrics.iconSide)
                    check(abs(icon.width - side) < 0.5 && abs(icon.height - side) < 0.5,
                          "\(tag) \(module.title)'s icon is \(icon.size), want \(side)pt square", &ok)
                    // Nothing truncated: the name's own width fits its frame.
                    let label = cell.debugLabel
                    check(label.intrinsicContentSize.width <= label.frame.width + 0.5,
                          "\(tag) \(module.title) is truncated (\(label.intrinsicContentSize.width) in "
                              + "\(label.frame.width))", &ok)
                    let badge = cell.badgeView
                    if !badge.isHidden {
                        let frame = badge.convert(badge.bounds, to: cell)
                        check(frame.maxX <= cell.bounds.maxX + 0.5 && frame.minX >= label.frame.maxX - 0.5,
                              "\(tag) \(module.title)'s badge sits outside its row or over its name", &ok)
                    }
                }
            }
        }
        // What a window's height changes is whether the list scrolls: at
        // 950pt the whole list is in sight, Settings included.
        let outline = shell.sidebar.outlineView
        let lastRow = outline.rect(ofRow: outline.numberOfRows - 1)
        let visible = outline.visibleRect
        check(visible.contains(NSPoint(x: lastRow.midX, y: lastRow.maxY - 1)),
              "at 950pt the sidebar's last row is below the fold (\(lastRow.maxY) of \(visible.maxY))", &ok)
    }

    // MARK: 1c - the lit row's section heading comes with it (R5-UI-09)

    /// The review's own sequence at 1100x760 with one session: a visit to
    /// Settings scrolls the list to its foot, and Knowledge is then lit
    /// under a "Work" heading cut off at the top.
    private static func checkSectionHeadingComesWithTheLitRow(_ shell: MainSplitShellController, _ window: NSWindow,
                                                              _ ok: inout Bool) {
        let registry = shell.workspace.hosts.sessions
        let session = UUID()
        registry.register(hostID: session, label: "DEV Bastion", accentHex: nil, state: .connected)
        var frame = window.frame
        frame.size = NSSize(width: 1100, height: 760)
        window.setFrame(frame, display: false)
        settle(shell)
        defer {
            registry.unregister(hostID: session)
            resize(window, width: 1512, shell)
            shell.workspace.navigator.show(.homeCanvas)
            settle(shell)
        }
        let outline = shell.sidebar.outlineView
        guard let clip = outline.enclosingScrollView?.contentView,
              let work = (0..<outline.numberOfRows).first(where: {
                  (outline.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == .section("Work")
              }) else {
            fail("the sidebar has no scroll view or no Work heading", &ok)
            return
        }
        func headingInSight() -> Bool {
            let heading = outline.rect(ofRow: work)
            return heading.minY >= clip.bounds.minY - 0.5 && heading.maxY <= clip.bounds.maxY + 0.5
        }
        // UX-28: Settings is the sidebar's foot and scrolls nothing, so the
        // fixture visits the list's own last row, Setup.
        shell.workspace.navigator.show(WorkspaceModule.setup.primaryRoute)
        settle(shell)
        // Discriminating power: the visit to Setup really has to leave the
        // heading out of sight, or the next assertion holds without the fix.
        check(clip.bounds.minY > outline.rect(ofRow: work).minY + 1,
              "fixture: at 1100x760 Setup did not scroll the Work heading out of sight "
              + "(list at \(clip.bounds.minY), heading at \(outline.rect(ofRow: work).minY))", &ok)
        shell.workspace.navigator.show(.docs)
        settle(shell)
        check(headingInSight(), "R5-UI-09: Knowledge is lit with its Work heading cut at the top "
              + "(list at \(clip.bounds.minY), heading \(outline.rect(ofRow: work)))", &ok)
        let lit = outline.rect(ofRow: outline.selectedRow)
        check(lit.minY >= clip.bounds.minY - 0.5 && lit.maxY <= clip.bounds.maxY + 0.5,
              "R5-UI-09: Knowledge's own row is not fully in sight", &ok)
    }

    // MARK: 1d - Sb-4: the whole sidebar is a hero column

    private static func checkTheHeroColumn(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let registry = shell.workspace.hosts.sessions
        let session = UUID()
        registry.register(hostID: session, label: "DEV Bastion", accentHex: nil, state: .connected)
        defer {
            registry.unregister(hostID: session)
            shell.workspace.navigator.show(.homeCanvas)
            ThemeManager.shared.setTheme(HelmTheme.dusk)
            settle(shell)
        }
        shell.workspace.navigator.show(.shift)
        settle(shell)
        let sidebar = shell.sidebar
        let root = sidebar.view

        // The pane: a plain split item, and no system material anywhere
        // between the window and the rows - the material is what Sb-4
        // replaces.
        check(shell.debugSidebarItemBehavior == .default,
              "Sb-4: the sidebar is still the system's sidebar item (behavior \(shell.debugSidebarItemBehavior.rawValue))", &ok)
        func effectViews(in view: NSView) -> [NSView] {
            (view is NSVisualEffectView && !view.isHiddenOrHasHiddenAncestor ? [view] : [])
                + view.subviews.flatMap(effectViews)
        }
        let above = sequence(first: root.superview, next: { $0?.superview }).compactMap { $0 }
            .filter { $0 is NSVisualEffectView }
        check(above.isEmpty && effectViews(in: root).isEmpty,
              "Sb-4: the sidebar still sits in or holds system material (\(above.count) above, "
                  + "\(effectViews(in: root).map { v in sequence(first: v, next: { $0.superview }).prefix(6).map { "\(type(of: $0))(\(Int($0.frame.width))x\(Int($0.frame.height)) state \(($0 as? NSVisualEffectView)?.material.rawValue ?? -1))" }.joined(separator: "<") }) inside)", &ok)
        // The gradient covers the whole pane, from the window's top edge -
        // the traffic lights sit on it - to its foot.
        let surface = sidebar.debugSurface
        let paneInWindow = root.convert(root.bounds, to: nil)
        let contentHeight = window.contentView?.bounds.height ?? 0
        check(surface.frame == root.bounds && root.bounds.height > 0,
              "Sb-4: the gradient \(surface.frame) does not fill the pane \(root.bounds)", &ok)
        check(abs(paneInWindow.maxY - contentHeight) < 0.5 && root.safeAreaInsets.top > 0,
              "Sb-4: the pane does not run under the title bar (top \(paneInWindow.maxY) of \(contentHeight), "
                  + "safe area \(root.safeAreaInsets.top))", &ok)

        // Every word in the ink, in every app theme: what is painted, read
        // off the cells, against the recipe.
        for theme in HelmTheme.appThemes {
            ThemeManager.shared.setTheme(theme)
            settle(shell)
            let ink = WorkspaceSidebarInk.of(theme)
            let tag = "[\(theme.id)]"
            check(surface.palette == ink.palette, "\(tag) the gradient is not the hero palette on the accent", &ok)
            check(root.appearance?.name == ink.appearance?.name,
                  "\(tag) the pane's controls are not in the gradient's appearance", &ok)
            check(same(sidebar.debugHeader.debugTitleColor, ink.ink),
                  "\(tag) the account header's name is not in the ink", &ok)
            if let home = sidebar.debugCell(for: .module(.home)) as? WorkspaceSidebarPageCell {
                check(same(home.debugLabelColor, ink.ink) && same(home.debugIconTint, ink.ink),
                      "\(tag) Home's words and glyph are not in the ink", &ok)
            } else {
                fail("\(tag) no Home row", &ok)
            }
            if let lit = sidebar.debugCell(for: .module(.tasks)) as? WorkspaceSidebarPageCell,
               let row = sidebar.debugRowView(for: .module(.tasks)) {
                check(same(lit.debugLabelColor, ink.selectedInk) && same(lit.debugIconTint, ink.selectedInk),
                      "\(tag) the lit row's words are not the pill's", &ok)
                check(same(row.debugFill.debugFill.flatMap { NSColor(cgColor: $0) }, ink.ink),
                      "\(tag) the lit row is not a pill in the ink", &ok)
            } else {
                fail("\(tag) Tasks is not lit", &ok)
            }
            if let work = sidebar.debugCell(for: .section("Work")) as? WorkspaceSidebarSectionCell {
                check(same(work.debugTitleColor, ink.quiet), "\(tag) the Work title is not the quiet ink", &ok)
            }
            if let dot = (sidebar.debugCell(for: .session(hostID: session)) as? WorkspaceSidebarSessionCell)?.debugDotColor {
                check(same(dot, ink.signal(tintHex: HelmTint.good.hex(in: theme), selected: false)),
                      "\(tag) the live session's dot is not the good hue lifted for the gradient", &ok)
            }
        }
        ThemeManager.shared.setTheme(HelmTheme.dusk)
        settle(shell)
        let ink = WorkspaceSidebarInk.of(HelmTheme.dusk)

        // An open group's title carries no number (UI-02 of full review 4:
        // it used to be the group's row count, which read as eight things
        // waiting); the session nests under Connections with its chord.
        let outline = sidebar.outlineView
        if let work = sidebar.debugCell(for: .section("Work")) as? WorkspaceSidebarSectionCell {
            check(work.debugTitle == "WORK" && work.debugCount == nil,
                  "UI-02: the open Work title reads \"\(work.debugTitle)\" \(work.debugCount ?? "-"), want WORK alone", &ok)
        } else {
            fail("Sb-4: no Work title", &ok)
        }
        let entries = sidebar.debugVisibleEntries
        if let connections = entries.firstIndex(of: .module(.connections)) {
            check(entries.indices.contains(connections + 1) && entries[connections + 1] == .session(hostID: session),
                  "Sb-4: the live session is not nested under Connections", &ok)
        }
        if let cell = sidebar.debugCell(for: .session(hostID: session)) as? WorkspaceSidebarSessionCell {
            check(cell.debugShortcut.hasPrefix("\u{2303}\u{2318}"), "Sb-4: the session lost its chord", &ok)
        }

        // The rules: none under a title, none beside the lit pill, one
        // between two plain rows - drawn, so in the ink's rule colour too.
        func rule(_ entry: WorkspaceSidebarEntry) -> Bool? {
            _ = sidebar.debugCell(for: entry)
            return sidebar.debugRowView(for: entry).map { row in
                guard !row.debugRule.isHidden else { return false }
                return same(row.debugRule.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
                            WorkspaceSidebarInk.of(ThemeManager.shared.theme).rule)
            }
        }
        let work = WorkspaceSidebarModel.modules(in: .work, hidden: AppSettings.shared.hiddenModules)
        if work.count >= 4, let litIndex = work.firstIndex(of: .tasks) {
            check(rule(.module(work[0])) == false, "Sb-4: the first row under Work draws a rule under the title", &ok)
            check(rule(.module(.tasks)) == false || litIndex == 0, "Sb-4: the lit pill draws a rule", &ok)
            if work.indices.contains(litIndex + 1) {
                check(rule(.module(work[litIndex + 1])) == false, "Sb-4: the row under the lit pill draws a rule", &ok)
            }
            let plain = work.indices.first { $0 > 0 && $0 != litIndex && $0 != litIndex + 1 }
            if let plain {
                check(rule(.module(work[plain])) == true, "Sb-4: \(work[plain].title) has no rule above it", &ok)
            }
        }

        // A profile change rebuilds the rows, and the rules come with them.
        // The rebuild makes new row views that are never hovered or lit
        // before they draw, which is how the first renders came out with
        // colourless rules.
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        let savedHidden = AppSettings.shared.hiddenModules
        AppSettings.shared.hiddenModules = WorkspaceProfile.personal.hiddenModules
        settle(shell)
        let personal = WorkspaceSidebarModel.modules(in: .work, hidden: AppSettings.shared.hiddenModules)
        if personal.count >= 2 {
            check(rule(.module(personal[1])) == true,
                  "Sb-4: after a profile change \(personal[1].title) lost its rule", &ok)
        } else {
            fail("Sb-4: fixture: the Personal Work group has fewer than two rows", &ok)
        }
        AppSettings.shared.hiddenModules = savedHidden
        shell.workspace.navigator.show(.shift)
        settle(shell)

        // UI-02: a folded group says what is waiting in the rows it hides -
        // the sum of their waiting counts, in the rows' own pill, lined up
        // with the rows' badges - and nothing when nothing waits.
        checkAFoldedGroupSaysWhatIsWaiting(sidebar, shell, &ok)

        // The focus ring on the pill: inside it, in the pill's words colour.
        HelmFocusVisibility.overrideForTests = true
        defer { HelmFocusVisibility.overrideForTests = nil }
        window.makeFirstResponder(outline)
        settle(shell)
        if let row = sidebar.debugRowView(for: .module(.tasks)) {
            check(row.showsFocusRing && same(row.debugFill.layer?.borderColor.flatMap { NSColor(cgColor: $0) },
                                             ink.selectedInk),
                  "Sb-4: the keyboard ring on the lit pill is not in the pill's words colour", &ok)
            check(HelmContrast.ratio(ink.selectedInk, ink.ink) >= HelmContrast.nonTextTarget,
                  "Sb-4: the ring does not clear the non-text floor on the pill", &ok)
        }
        window.makeFirstResponder(nil)

        // Collapse keeps the title and its count, and the menus stay in the
        // theme's own mode rather than the gradient's.
        let before = outline.numberOfRows
        sidebar.debugSetSection("Observe", expanded: false)
        settle(shell)
        check(outline.numberOfRows < before && sidebar.debugVisibleEntries.contains(.section("Observe")),
              "Sb-4: collapsing Observe did not fold its rows", &ok)
        sidebar.debugSetSection("Observe", expanded: true)
        settle(shell)
        check(outline.numberOfRows == before, "Sb-4: Observe did not open again", &ok)
        if let menu = outline.menu {
            sidebar.menuNeedsUpdate(menu)
            check(menu.appearance?.name == .darkAqua, "Sb-4: the context menu is not in Dusk's own mode", &ok)
        }
    }

    /// UI-02: the number on a group's title. Signals are set on the sidebar
    /// directly, through the same `setSignals` the shell calls.
    private static func checkAFoldedGroupSaysWhatIsWaiting(_ sidebar: WorkspaceSidebarController,
                                                          _ shell: MainSplitShellController, _ ok: inout Bool) {
        let outline = sidebar.outlineView
        var signals = WorkspaceSignals()
        signals.tasksDue = .read(.init(today: 2, overdue: 1), at: Date())
        signals.crew = .read(2, at: Date())
        signals.liveSessions = 1
        sidebar.setSignals(signals)
        settle(shell)
        let work = WorkspaceSidebarModel.modules(in: .work, hidden: AppSettings.shared.hiddenModules)
        // The fixture can fail: Work holds both counted rows and the
        // sessions row, whose count is not a queue.
        guard work.contains(.tasks), work.contains(.crew), work.contains(.connections) else {
            fail("UI-02: fixture: Work does not hold Tasks, Crew and Connections (\(work))", &ok)
            return
        }
        guard let tasks = sidebar.debugCell(for: .module(.tasks)) as? WorkspaceSidebarPageCell,
              !tasks.badgeView.isHidden else {
            fail("UI-02: fixture: Tasks draws no badge to line the group's number up with", &ok)
            return
        }
        if let open = sidebar.debugCell(for: .section("Work")) as? WorkspaceSidebarSectionCell {
            check(open.debugCount == nil, "UI-02: the open Work title draws \(open.debugCount ?? "-")", &ok)
        }
        // Folded from Home, so the lit row is not one the fold hides.
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        sidebar.debugSetSection("Work", expanded: false)
        settle(shell)
        defer {
            sidebar.debugSetSection("Work", expanded: true)
            sidebar.setSignals(WorkspaceSignals())
            shell.workspace.navigator.show(.shift)
            settle(shell)
        }
        // Where a row's badge ends, read off a row still in sight: the
        // module cell's trailing edge less the badge's inset.
        guard let home = sidebar.debugCell(for: .module(.home)) else {
            fail("UI-02: fixture: no Home row to line the group's number up with", &ok)
            return
        }
        let rowBadgeEnd = home.convert(home.bounds, to: outline).maxX - HelmMetrics.s2
        guard let folded = sidebar.debugCell(for: .section("Work")) as? WorkspaceSidebarSectionCell else {
            fail("UI-02: no Work title once folded", &ok)
            return
        }
        // 3 tasks due plus 2 decisions; the live session is not waiting.
        check(folded.debugCount == "5",
              "UI-02: the folded Work title draws \(folded.debugCount ?? "nothing"), want the 5 waiting inside", &ok)
        let pill = folded.debugBadgeView
        check(pill.layer?.backgroundColor != nil, "UI-02: the folded Work number is not in the badge pill", &ok)
        let end = pill.convert(pill.bounds, to: outline).maxX
        check(abs(end - rowBadgeEnd) < 1, "UI-02: the Work number ends at \(end) and the rows' badges at \(rowBadgeEnd)", &ok)
        check(pill.frame.height <= (sidebar.debugRowHeight(for: .section("Work")) ?? 0),
              "UI-02: the Work pill (\(pill.frame.height)pt) is taller than its row", &ok)
        // The disclosure chevron takes the trailing edge under the pointer,
        // so the number steps aside for it, and comes back.
        if let row = sidebar.debugRowView(for: .section("Work")) {
            row.mouseEntered(with: NSEvent())
            check(folded.debugCount == nil, "UI-02: the Work number stays under the disclosure chevron", &ok)
            row.mouseExited(with: NSEvent())
            check(folded.debugCount == "5", "UI-02: the Work number did not come back", &ok)
        }
        // Nothing waiting: a folded group draws nothing, not a zero, and
        // the live session alone is not counted.
        var quiet = WorkspaceSignals()
        quiet.liveSessions = 1
        sidebar.setSignals(quiet)
        settle(shell)
        check(folded.debugCount == nil,
              "UI-02: a folded Work with nothing waiting draws \(folded.debugCount ?? "-")", &ok)
    }

    /// Whether `color` is `expected`, components and alpha.
    private static func same(_ color: NSColor?, _ expected: NSColor) -> Bool {
        guard let a = color?.usingColorSpace(.sRGB), let b = expected.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01 && abs(a.alphaComponent - b.alphaComponent) < 0.02
    }

    /// The PR's renders: the whole window beside Home and Tasks, in Daylight
    /// and Dusk, in the Operator and Personal profiles, with a nested session,
    /// collapsed groups, the keyboard ring, Compact, and a short window whose
    /// list scrolls; and the sidebar alone in every app theme.
    private static func writeSidebarRenders(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_SIDEBAR_HERO_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        let savedHidden = AppSettings.shared.hiddenModules
        let savedDensity = AppSettings.shared.density
        let savedLayout = AppSettings.shared.homeCardLayout
        let registry = shell.workspace.hosts.sessions
        let live = UUID(), restored = UUID()
        registry.register(hostID: live, label: "DEV Bastion", accentHex: nil, state: .connected)
        registry.register(hostID: restored, label: "prod-db-1", accentHex: nil, state: .restored)
        defer {
            registry.unregister(hostID: live)
            registry.unregister(hostID: restored)
            AppSettings.shared.hiddenModules = savedHidden
            AppSettings.shared.density = savedDensity
            AppSettings.shared.homeCardLayout = savedLayout
            ThemeManager.shared.setTheme(HelmTheme.dusk)
            var frame = window.frame
            frame.size = NSSize(width: 1512, height: 950)
            window.setFrame(frame, display: false)
            shell.workspace.navigator.show(.homeCanvas)
            settle(shell)
        }
        ReviewTourLab.seedDemoBriefing()
        let canvas = shell.debugHomeCanvas
        func shoot(_ name: String) {
            settle(shell)
            if !ReviewTourLab.writeSplitShellPNG(shell, window: window, to: folder.appendingPathComponent("\(name).png")) {
                fail("Sb-4: the \(name) render was not written", &ok)
            }
        }
        func show(_ route: RailDestination) {
            shell.workspace.navigator.show(route)
            if route == .homeCanvas {
                ReviewTourLab.seedDemoHome(canvas)
                canvas.debugRenderNow()
            }
            settle(shell)
        }
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            ThemeManager.shared.setTheme(theme)
            for profile in [WorkspaceProfile.operator, .personal] {
                AppSettings.shared.hiddenModules = profile.hiddenModules
                for (route, page) in [(RailDestination.homeCanvas, "home"), (.shift, "tasks")] {
                    show(route)
                    shoot("\(page)-\(profile.rawValue)-\(theme.id)")
                }
            }
            AppSettings.shared.hiddenModules = WorkspaceProfile.operator.hiddenModules
            show(.shift)
            shell.sidebar.debugSetSection("Observe", expanded: false)
            shell.sidebar.debugSetSection("Workbench", expanded: false)
            shoot("tasks-collapsed-\(theme.id)")
            shell.sidebar.debugSetSection("Observe", expanded: true)
            shell.sidebar.debugSetSection("Workbench", expanded: true)
            HelmFocusVisibility.overrideForTests = true
            window.makeFirstResponder(shell.sidebar.outlineView)
            shoot("tasks-keyboard-ring-\(theme.id)")
            window.makeFirstResponder(nil)
            HelmFocusVisibility.overrideForTests = nil
            AppSettings.shared.density = .compact
            shoot("tasks-compact-\(theme.id)")
            AppSettings.shared.density = savedDensity
            var frame = window.frame
            frame.size = NSSize(width: 1280, height: 700)
            window.setFrame(frame, display: false)
            show(.settings)
            shoot("settings-short-window-\(theme.id)")
            frame.size = NSSize(width: 1512, height: 950)
            window.setFrame(frame, display: false)
        }
        // The sidebar alone, in every app theme, beside Tasks.
        show(.shift)
        for theme in HelmTheme.appThemes {
            ThemeManager.shared.setTheme(theme)
            settle(shell)
            ReviewTourLab.writePNG(of: shell.sidebar.view, to: folder.appendingPathComponent("sidebar-\(theme.id).png"))
        }
        print("SidebarRedesignsSelfTest: Sb-4 renders written to \(dir)")
    }

    // MARK: 1b - Home stays in sight (R4-BUG-03)

    /// With Console holding one session the default sidebar is 26 rows (24
    /// until R5-UX-05 put Runbooks in Observe, 25 until DevOps Hub, 27 while
    /// DevOps Hub listed its project under it), a few
    /// points taller than its clip view in a 950pt window. Selecting a bottom
    /// row then scrolled the whole column up by the overflow and left Home
    /// half under the header, on every page whose module sits low in the
    /// list. Every module is visited, the way the captain moves between them.
    private static func checkHomeStaysInSight(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let registry = shell.workspace.hosts.sessions
        let session = UUID()
        registry.register(hostID: session, label: "DEV Bastion", accentHex: nil, state: .connected)
        defer {
            registry.unregister(hostID: session)
            shell.workspace.navigator.show(.homeCanvas)
            settle(shell)
        }
        settle(shell)
        let outline = shell.sidebar.outlineView
        guard let clip = outline.enclosingScrollView?.contentView else {
            fail("the sidebar's outline is not in a scroll view", &ok)
            return
        }
        // DevOps Hub made it 26. Its projects are cards on its page now, not
        // rows under it. At 950pt the list still overflows, so the whole-list
        // sweep runs where the default set fits.
        // UX-28 took Settings out of the list into the sidebar's foot: 25.
        check(outline.numberOfRows == 25, "the default sidebar with one session should be 25 rows, got \(outline.numberOfRows)", &ok)
        var fits = window.frame
        fits.size.height = Self.defaultSetFitsHeight
        window.setFrame(fits, display: false)
        settle(shell)
        func homeInSight() -> Bool { clip.bounds.minY <= outline.rect(ofRow: 0).minY + 0.5 }
        let overflow = outline.frame.height - clip.bounds.height
        for module in WorkspaceSidebarModel.listedModules(hidden: AppSettings.shared.hiddenModules) {
            shell.workspace.navigator.show(module.primaryRoute)
            settle(shell)
            check(homeInSight(), "at \(Int(Self.defaultSetFitsHeight))pt on \(module.title) Home is clipped: the list is scrolled to "
                  + "\(clip.bounds.minY) of a \(outline.frame.height)pt list in a \(clip.bounds.height)pt clip view", &ok)
            if let row = (0..<outline.numberOfRows).first(where: {
                (outline.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == .module(module)
            }) {
                let lit = outline.rect(ofRow: row)
                check(lit.maxY - clip.bounds.maxY < lit.height / 2,
                      "at \(Int(Self.defaultSetFitsHeight))pt \(module.title)'s lit row is more than half below the fold", &ok)
            }
        }
        // The whole default set fits a window this tall, so the list does
        // not scroll at all there.
        check(overflow <= 0.5, "at \(Int(Self.defaultSetFitsHeight))pt the default sidebar overflows its clip view by \(overflow)pt", &ok)

        // A window a little shorter, so the list overflows by less than one
        // row (10pt): the bottom row is still lit and mostly in sight, and
        // the list stays at the top rather than lifting Home by the overflow.
        let rowsHeight = outline.rect(ofRow: outline.numberOfRows - 1).maxY
        var frame = window.frame
        frame.size.height -= clip.bounds.height - (rowsHeight - 10)
        window.setFrame(frame, display: false)
        settle(shell)
        let shortOverflow = outline.frame.height - clip.bounds.height
        check(shortOverflow > 5 && shortOverflow < outline.rect(ofRow: 0).height,
              "the fixture should overflow by less than one row, got \(shortOverflow)pt", &ok)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        if let bottom = WorkspaceSidebarModel.listedModules().last(where: { $0 != WorkspaceSidebarModel.footModule }) {
            shell.workspace.navigator.show(bottom.primaryRoute)
            settle(shell)
            let lit = outline.rect(ofRow: outline.selectedRow)
            check(outline.selectedRow == outline.numberOfRows - 1, "the fixture's last module should be the last row", &ok)
            check(homeInSight(), "overflowing by \(shortOverflow)pt, \(bottom.title) scrolled Home under the header "
                  + "(scrolled to \(clip.bounds.minY))", &ok)
            check(lit.maxY - clip.bounds.maxY < lit.height / 2,
                  "overflowing by \(shortOverflow)pt, \(bottom.title)'s lit row is more than half below the fold", &ok)
        }

        // A rebuild that leaves the selection where it was (a session coming
        // or going) leaves the scroll where it was too. The fixture has to
        // scroll for that to mean anything, so the window is made short.
        frame = window.frame
        frame.size.height = 700
        window.setFrame(frame, display: false)
        settle(shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        clip.scroll(to: NSPoint(x: 0, y: 40))
        outline.enclosingScrollView?.reflectScrolledClipView(clip)
        let scrolled = clip.bounds.minY
        check(scrolled > 30, "the short window's sidebar should scroll for the rebuild check to mean anything, got \(scrolled)", &ok)
        let second = UUID()
        registry.register(hostID: second, label: "PROD Web", accentHex: nil, state: .connected)
        settle(shell)
        check(abs(clip.bounds.minY - scrolled) < 0.5,
              "a session arriving moved the sidebar's scroll from \(scrolled) to \(clip.bounds.minY)", &ok)
        registry.unregister(hostID: second)
        settle(shell)
        resize(window, width: 1512, shell)
    }

    // MARK: 2 - Quick Connect

    private static func checkQuickConnect(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let ids = WorkspaceToolbar.ItemID.quickConnect
        shell.workspace.navigator.show(.console)
        settle(shell)
        let toolbarIDs = shell.toolbar.debugItemIdentifiers
        let positions = ids.compactMap { toolbarIDs.firstIndex(of: $0) }
        check(positions.count == 2 && positions[1] - positions[0] == 1,
              "Console's toolbar does not show Console, then Hosts: \(toolbarIDs.map(\.rawValue))", &ok)
        // Adjacent icons share one capsule. S02: Quick Connect's icons and the
        // calendar are the Open group, and a space closes it before the
        // Window group's light/dark toggle.
        check(positions.count == 2 && positions[1] + 3 < toolbarIDs.count
                && toolbarIDs[positions[1] + 1] == WorkspaceToolbar.ItemID.calendar
                && toolbarIDs[positions[1] + 2] == .space
                && toolbarIDs[positions[1] + 3] == WorkspaceToolbar.ItemID.theme,
              "Quick Connect and the calendar are not the Open group at the head of the trailing cluster: \(toolbarIDs.map(\.rawValue))", &ok)
        check(shell.toolbar.debugModuleActionButton == nil, "Console still draws a one-button Quick Connect", &ok)

        // Hosts: the quick-connect host picker, as Quick Connect always was.
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectHosts), "the Hosts icon has no action", &ok)
        settle(shell)
        check(shell.debugCurrentDestination == .hosts && shell.currentModule == .connections,
              "the Hosts icon opened \(String(describing: shell.debugCurrentDestination))", &ok)

        // Console (the captain's Option B): a session only when Console has
        // none, and after that the one it has, with the keyboard in it. The
        // tour lab's console opens nothing of its own as it loads (the real
        // app's shared console always has its Firstmate shell), so the first
        // click is the open half and the second the focus half.
        shell.workspace.navigator.show(.console)
        settle(shell)
        let console = shell.workspace.console
        check(console.tabs.isEmpty, "Console starts with a session - the open half would pass vacuously", &ok)
        check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectConsole), "the Console icon has no action", &ok)
        settle(shell)
        let opened = console.tabs.map(\.id)
        if opened.count == 1, case .shell(let executable, _, _)? = console.tabs.first?.launch {
            check(executable == "/usr/bin/true", "the suite's session runs \(executable), not /usr/bin/true", &ok)
        } else {
            fail("with no session the Console icon opened \(opened.count)", &ok)
        }
        guard let session = console.currentTab else {
            fail("the Console icon left Console with no current session", &ok)
            return
        }
        // The keyboard goes into the session only while the app is unlocked:
        // the icon's path is Console's own gated focus (GL-09), and a
        // self-test process starts locked, as the app does.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        for locked in [true, false] {
            AppLockGate.shared.setLocked(locked)
            window.makeFirstResponder(nil)
            check(shell.toolbar.debugPerform(WorkspaceToolbar.ItemID.quickConnectConsole), "the Console icon has no action", &ok)
            settle(shell)
            check(shell.debugCurrentDestination == .console && console.tabs.map(\.id) == opened
                    && console.currentTab === session,
                  "with a session the Console icon opened another (\(console.tabs.count) tabs)", &ok)
            let focused = window.firstResponder === console.focusedTerminal(of: session)
            check(focused != locked,
                  locked ? "the Console icon put the keyboard into a terminal behind the lock"
                         : "the Console icon left the keyboard in \(String(describing: window.firstResponder))", &ok)
        }

        // U-02: Quick Connect is on every module now, the same two icons in
        // the same place - `ReviewTwoUXSelfTest` walks every module.
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell)
        check(ids.allSatisfy(shell.toolbar.debugItemIdentifiers.contains),
              "Quick Connect is missing on Home: \(shell.toolbar.debugItemIdentifiers.map(\.rawValue))", &ok)
    }

    // MARK: 3 - Tasks

    private static func checkTasksBoard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        shell.workspace.navigator.show(.shift)
        settle(shell)
        clickTab("Board", shell)
        check(!drawsPageColumn(tasks.view), "Tasks still draws its own page column beside the board", &ok)
        // Tf-2: the band is the page's filters.
        guard let band = tasks.debugHeroBand else {
            fail("Tasks has no band to filter from", &ok)
            return
        }
        check(band.window != nil, "Tasks' band is not on screen", &ok)
        // ...and it starts at the page's gutter, with nothing to its left.
        let bandLeading = band.convert(band.bounds, to: tasks.view).minX
        check(abs(bandLeading - HelmMetrics.pageGutter) < 0.5,
              "Tasks' band starts \(bandLeading)pt into the page, want the \(HelmMetrics.pageGutter)pt gutter", &ok)

        // New task at the toolbar's far right, after Search.
        let ids = shell.toolbar.debugItemIdentifiers
        check(shell.toolbar.debugPrimaryAction === tasks.debugNewTaskButton && ids.last == WorkspaceToolbar.ItemID.primaryAction
                && ids.firstIndex(of: WorkspaceToolbar.ItemID.primaryAction) == ids.firstIndex(of: WorkspaceToolbar.ItemID.search).map { $0 + 1 },
              "New task is not the toolbar's last item, after Search: \(ids.map(\.rawValue))", &ok)
        check(!shell.toolbar.debugPageActions.contains { $0 === tasks.debugNewTaskButton }, "New task is drawn twice", &ok)

        // The column's scopes, through the band's own figures (Tf-2).
        let counts = tasks.counts()
        check(tasks.debugTaskScope == "all" && band.debugSelectedFigure == "All open",
              "the band does not start on All open", &ok)
        band.debugFigureButtons[1].performPrimaryAction()
        settle(shell)
        check(tasks.debugTaskScope == "due_today", "the Due today filter did not filter", &ok)
        let dueToday = tasks.debugVisibleTaskIDs(.backlog) + tasks.debugVisibleTaskIDs(.inProgress)
        check(dueToday.count == counts.dueToday && counts.dueToday > 0,
              "Due today shows \(dueToday.count) cards, the count says \(counts.dueToday)", &ok)
        band.debugFigureButtons[0].performPrimaryAction()
        settle(shell)

        // The project filter, through the project menu's own item.
        guard let project = shell.workspace.shiftStore.projects.first else {
            fail("the demo tasks have no project", &ok)
            return
        }
        tasks.debugPickProject(id: project.id)
        settle(shell)
        let inProject = tasks.debugVisibleTaskIDs(.backlog) + tasks.debugVisibleTaskIDs(.inProgress)
        let projectOf = Dictionary(shell.workspace.shiftStore.activeTasks.map { ($0.id, $0.projectID) }, uniquingKeysWith: { a, _ in a })
        check(tasks.debugProjectFilter == project.id && !inProject.isEmpty && inProject.allSatisfy { projectOf[$0] == project.id },
              "picking \(project.name) did not filter the board to it", &ok)
        tasks.debugPickProject(id: nil)
        settle(shell)
        check(tasks.debugProjectFilter == nil, "All projects did not clear the filter", &ok)

        // Follow-ups: the column's jump, now the band's figure.
        check(band.debugFigureCaptions.last == "Follow-ups", "the Follow-ups figure is missing", &ok)

        // The prototype's lanes: each a tint hugging its own cards.
        guard let lanes = tasks.debugBoardView?.debugColumnViews, lanes.count == 3 else {
            fail("the board has no lanes", &ok)
            return
        }
        check(lanes.allSatisfy(\.usesWorkspaceStyle) && lanes.flatMap(\.debugCardViews).allSatisfy(\.usesWorkspaceStyle),
              "the board's lanes or cards are the floating bar's", &ok)
        let heights = lanes.map { $0.debugLaneBackground.frame.height }
        let fullest = lanes.map { $0.debugCardViews.count }
        if let most = fullest.max(), let least = fullest.min(), most > least,
           let tall = fullest.firstIndex(of: most), let short = fullest.firstIndex(of: least) {
            check(heights[short] < heights[tall] - 20,
                  "every lane is as tall as the fullest (\(heights)) - a lane should hug its cards", &ok)
        }
    }

    private static func checkTasksList(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        clickTab("List", shell)
        let table = tasks.debugTasksTable
        check(!table.card.isHidden && table.card.window != nil, "the List tab draws no table", &ok)
        let records = table.debugRows.filter(\.isRecord)
        let store = shell.workspace.shiftStore
        check(records.count >= store.activeTasks.count, "the table lists \(records.count) tasks of \(store.activeTasks.count)", &ok)
        check(table.debugHeaderTitles.contains("Task") && table.debugHeaderTitles.contains("Due"),
              "the table's columns are \(table.debugHeaderTitles)", &ok)
        guard let first = records.first, let key = first.key, case .view(let view)? = first.cells["done"],
              let badge = view as? ShiftTaskCheckBadge else {
            fail("a task row has no check", &ok)
            return
        }
        let menu = table.debugMenuTitles(key: key)
        for title in ["Open Task\u{2026}", "Mark Done", "Push to Tomorrow", "Delete Task\u{2026}"] {
            check(menu.contains(title), "a task row's menu lacks \(title): \(menu)", &ok)
        }
        // The check completes a task and reopens it, through its own button.
        badge.performClick(nil)
        settle(shell)
        check(!store.activeTasks.contains { $0.id == key }, "the check did not complete the task", &ok)
        let reopened = tasks.debugTasksTable.debugRows.first { $0.key == key }
        if case .view(let view)? = reopened?.cells["done"], let badge = view as? ShiftTaskCheckBadge {
            badge.performClick(nil)
            settle(shell)
            check(store.activeTasks.contains { $0.id == key }, "the check did not reopen the task", &ok)
        } else {
            fail("the completed task left the table", &ok)
        }
        // Tf-2: the sort is the band's menu on List too.
        if let band = tasks.debugHeroBand {
            check(!band.debugPills.sort.isHidden, "the List tab's band has no sort", &ok)
            tasks.debugPickSort(.priority)
            settle(shell)
            check(band.debugPills.sort.title == ShiftTaskSort.priority.title,
                  "picking Priority left the sort reading \(band.debugPills.sort.title)", &ok)
            tasks.debugPickSort(.dueDate)
            settle(shell)
        } else {
            fail("the List tab draws no band", &ok)
        }
    }

    /// Follow-ups are the List tab's table too: a check, the columns and a ⋯
    /// on hover whose menu deletes, through GL-06's confirm. The flat list
    /// they used to be offered Delete only on a right click, so a captain saw
    /// a follow-up they could tick off and nothing else. The editor sheet
    /// carries the task editor's Delete as well.
    private static func checkTasksFollowUps(_ shell: MainSplitShellController, _ window: NSWindow,
                                            _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        let store = shell.workspace.shiftStore
        // A follow-up of the suite's own, so deleting it leaves the seeded two
        // for every check after this one.
        var mine = ShiftFollowUp.fresh()
        mine.title = "Chase the vendor about the renewal quote"
        mine.followUpAt = ShiftDateFormatting.components(from: Date()).dateStr
        store.addFollowUp(mine)
        // The List tab draws the Follow-ups card. On a Board wide enough for
        // four lanes Follow-ups is a lane instead (R4-UI-09), and the card
        // is put away.
        clickTab("List", shell)
        tasks.render()
        settle(shell)

        let table = tasks.debugFollowUpsTable
        check(!table.card.isHiddenOrHasHiddenAncestor && table.card.window != nil,
              "the Follow-ups card is not on the List page", &ok)
        check(table.debugHeaderTitles.contains("Follow-up") && table.debugHeaderTitles.contains("Due"),
              "the Follow-ups table's columns are \(table.debugHeaderTitles)", &ok)
        let keys = table.debugRows.compactMap(\.key)
        check(Set(keys) == Set(store.followUps.map(\.id)),
              "the Follow-ups table lists \(keys.count) of \(store.followUps.count) follow-ups", &ok)
        guard let row = table.debugRows.first(where: { $0.key == mine.id }) else {
            fail("the new follow-up has no row", &ok)
            return
        }
        guard case .view(let view)? = row.cells["done"], view is ShiftTaskCheckBadge else {
            fail("a follow-up row has no check", &ok)
            return
        }
        let menu = table.debugMenuTitles(key: mine.id)
        for title in ["Open Follow-up\u{2026}", "Mark Done", "Snooze to Tomorrow", "Delete Follow-up\u{2026}"] {
            check(menu.contains(title), "a follow-up row's menu lacks \(title): \(menu)", &ok)
        }
        // The ⋯ a task row shows on hover, and so where Delete can be seen.
        table.debugHover(key: mine.id)
        settle(shell)
        check(table.debugActionsCell(key: mine.id)?.debugRevealed == true,
              "hovering a follow-up shows no \u{22EF} for its actions", &ok)
        // A re-render under a pointer that has not moved (the store's
        // background reload) keeps the row's hover. CI's slower runner landed
        // that reload between the hover and the check above.
        tasks.render()
        settle(shell)
        check(table.debugActionsCell(key: mine.id)?.debugRevealed == true,
              "a re-render hid the hovered follow-up's \u{22EF}", &ok)
        table.debugHover(key: nil)

        // Delete asks first (GL-06), and Cancel keeps it.
        var asked: [String] = []
        var answer = HelmConfirm.Response.cancel
        HelmConfirm.responderForTests = { request in
            asked.append(request.title)
            return answer
        }
        defer { HelmConfirm.responderForTests = nil }
        check(table.debugPickMenuItem(key: mine.id, title: "Delete Follow-up\u{2026}"),
              "the menu's Delete Follow-up did not run", &ok)
        settle(shell)
        check(asked == ["Delete \u{201C}\(mine.title)\u{201D}?"], "Delete asked \(asked), not the follow-up's confirm", &ok)
        check(store.followUps.contains { $0.id == mine.id }, "Cancel deleted the follow-up", &ok)
        answer = .confirm
        _ = table.debugPickMenuItem(key: mine.id, title: "Delete Follow-up\u{2026}")
        settle(shell)
        check(!store.followUps.contains { $0.id == mine.id }, "confirming Delete Follow-up did not delete it", &ok)
        check(!tasks.debugFollowUpsTable.debugRows.contains { $0.key == mine.id },
              "the deleted follow-up is still in the table", &ok)

        // The check marks a follow-up done, and back, through its own button.
        if let first = store.followUps.first,
           case .view(let view)? = tasks.debugFollowUpsTable.debugRows.first(where: { $0.key == first.id })?.cells["done"],
           let badge = view as? ShiftTaskCheckBadge {
            let wasDone = first.status == .done
            badge.performClick(nil)
            settle(shell)
            check(store.followUps.first { $0.id == first.id }.map { ($0.status == .done) != wasDone } == true,
                  "the check did not change the follow-up's status", &ok)
            if case .view(let view)? = tasks.debugFollowUpsTable.debugRows.first(where: { $0.key == first.id })?.cells["done"],
               let badge = view as? ShiftTaskCheckBadge {
                badge.performClick(nil)
                settle(shell)
            }
            check(store.followUps.first { $0.id == first.id }.map { ($0.status == .done) == wasDone } == true,
                  "the check did not put the follow-up back", &ok)
        } else {
            fail("the seeded follow-ups have no check", &ok)
        }

        // The editor sheet: an existing follow-up's has the task editor's
        // Delete, which hands its owner the id; a new one's has none.
        guard let existing = store.followUps.first else {
            fail("the seeded follow-ups are gone", &ok)
            return
        }
        let editor = ShiftFollowUpEditorController(followUp: existing, tasks: [], projects: [])
        var deletedID: String?
        editor.onDelete = { deletedID = $0 }
        let delete = descendants(HelmButton.self, in: editor.view).first { $0.title == "Delete" }
        check(delete != nil, "the Edit Follow-up sheet has no Delete button", &ok)
        delete?.performClick(nil)
        check(deletedID == existing.id, "the sheet's Delete handed over \(deletedID ?? "nothing")", &ok)
        let fresh = ShiftFollowUpEditorController(followUp: nil, tasks: [], projects: [])
        check(!descendants(HelmButton.self, in: fresh.view).contains { $0.title == "Delete" },
              "the New Follow-up sheet offers Delete for a follow-up that does not exist", &ok)
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// The Calendar is Tasks' third view again, behind its own sidebar row
    /// (tasks-calendar plan PR 4), so Tasks' tabs are four.
    private static func checkTasksReview(_ shell: MainSplitShellController, _ window: NSWindow,
                                         _ ok: inout Bool) {
        let tasks = shell.workspace.shift
        check(tasks.moduleTabNames == ["Board", "List", "Calendar", "Weekly review"],
              "Tasks' tabs are \(tasks.moduleTabNames)", &ok)
        clickTab("Weekly review", shell)
        check(tasks.debugHeroBand == nil, "the band and its filters show over Weekly review", &ok)
        // UX-05: the review's own band carries the week's done count and
        // focus time; overdue, follow-ups and next week are its verdict and
        // the agenda under it.
        let band = tasks.reviewBand
        let summary = shell.workspace.shiftStore.weeklySummary()
        check(band.debugFigures.map(\.caption) == ["Done this week", "Focus time"],
              "Weekly review's figures are \(band.debugFigures.map(\.caption))", &ok)
        check(band.debugFigures.first?.count == "\(summary.completedCount)",
              "Done this week reads \(band.debugFigures.first?.count ?? "-"), want \(summary.completedCount)", &ok)
        // The floating bar's strip counts the tasks pushed back 2+ times; here
        // that figure is the Pushed back panel's own count.
        check(tasks.debugPushedBackCount == "\(summary.pushedBack.count)",
              "Pushed back repeatedly counts \(tasks.debugPushedBackCount ?? "nothing"), "
                  + "want \(summary.pushedBack.count)", &ok)
        // Focus time is the focus log's: none, then what was logged.
        check(band.debugFigures.last?.count == "None", "Focus time with no sessions reads \(band.debugFigures.last?.count ?? "-")", &ok)
        if let task = shell.workspace.shiftStore.activeTasks.first {
            shell.workspace.shiftStore.logFocusSession(taskID: task.id, taskTitle: task.title, seconds: 3000)
            clickTab("Board", shell)
            clickTab("Weekly review", shell)
            check(band.debugFigures.last?.count == FocusTimerFormat.total(3000),
                  "Focus time reads \(band.debugFigures.last?.count ?? "-") after a 50 minute session", &ok)
        }
        // Back from Weekly review is where the floating bar's column used to
        // return (the review put it away), so it is where it would come back.
        clickTab("Board", shell)
        check(!drawsPageColumn(tasks.view), "back on Board from Weekly review, Tasks draws its page column again", &ok)
        if let band = tasks.debugHeroBand {
            let bandLeading = band.convert(band.bounds, to: tasks.view).minX
            check(abs(bandLeading - HelmMetrics.pageGutter) < 0.5,
                  "back on Board from Weekly review, Tasks' band starts \(bandLeading)pt into the page", &ok)
        } else {
            fail("back on Board from Weekly review, Tasks' band is not showing", &ok)
        }
    }

    /// Whether a page draws a column of its own (`HelmPageSidebar`).
    private static func drawsPageColumn(_ view: NSView) -> Bool {
        view is HelmPageSidebar || view.subviews.contains(where: drawsPageColumn)
    }

    // MARK: 4 - Setup

    private static func checkUpdates(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let updates = shell.workspace.updates
        shell.workspace.navigator.show(.updates)
        settle(shell)
        _ = waitUntil(timeout: 10) {
            updates.debugToolRows.filter(\.isRecord).count == DependencyCatalog.items.count
                && !updates.debugToolRows.contains { row in
                    if case .muted(let text)? = row.cells["available"] { return text.hasPrefix("Checking") }
                    return false
                }
        }
        check(updates.debugSetupSummary.window != nil, "Updates has no Setup hero", &ok)
        let rows = updates.debugToolRows
        // UX-22: the tools are grouped by state, one card each, and each
        // group's header carries its one action.
        let shown = UpdatesGroup.allCases.filter { updates.debugGroupCard($0)?.table.card.isHidden == false }
        check(shown == [.updateAvailable, .notInstalled, .couldNotCheck, .upToDate],
              "UX-22: the Updates groups shown are \(shown)", &ok)
        check(updates.debugGroupCard(.notInstalled)?.actionButton.title == "Install 1 in \(PlaceName.short(.bootstrap))"
                && updates.debugGroupCard(.updateAvailable)?.actionButton.title == "Update 1"
                && updates.debugGroupCard(.couldNotCheck)?.actionButton.title == "Check again"
                && updates.debugGroupCard(.upToDate)?.actionButton.isHidden == true,
              "UX-22: the group actions read \(UpdatesGroup.allCases.map { updates.debugGroupCard($0)?.actionButton.title ?? "-" })", &ok)
        check(updates.debugGroupCard(.upToDate)?.table.isCollapsed == true,
              "UX-22: Up to date is not folded to its header", &ok)
        func row(_ id: String) -> HelmDataTable.Row? { rows.first { $0.key == id } }
        if let quota = row("quota-axi") {
            if case .status(let text, let tint)? = quota.cells["available"] {
                check(text.contains("0.1.66") && tint == .warn, "quota-axi's update reads \(text)", &ok)
            } else {
                fail("quota-axi's available version is not drawn", &ok)
            }
            check(quota.primary?.title == "Update" && quota.pinsPrimary, "quota-axi offers \(quota.primary?.title ?? "nothing")", &ok)
        } else {
            fail("the table has no quota-axi", &ok)
        }
        // UX-22: the group says Install once; the row keeps what is its own.
        check(row("gh")?.primary == nil, "gh still offers \(row("gh")?.primary?.title ?? "nothing") of its own", &ok)
        if let up = row("tasks-axi") {
            check(up.primary == nil, "an up-to-date tool offers \(up.primary?.title ?? "")", &ok)
            if case .muted(let text)? = up.cells["available"] { check(text == "Up to date", "tasks-axi reads \(text)", &ok) }
            if case .code(let text)? = up.cells["installed"] { check(text == "1.0.0", "tasks-axi's version reads \(text)", &ok) }
        }

        // The filter row: Needs Attention, then the tool filter.
        updates.debugSetFilter(needsAttention: true)
        settle(shell)
        let attention = updates.debugToolRows.compactMap(\.key)
        check(Set(attention) == ["quota-axi", "gh", "claude-code"], "Needs Attention lists \(attention)", &ok)
        updates.debugSetFilter(needsAttention: false)
        updates.debugSetQuery("axi")
        settle(shell)
        let axi = updates.debugToolRows.compactMap(\.key)
        check(!axi.isEmpty && axi.allSatisfy { $0.hasSuffix("axi") }, "filtering \"axi\" lists \(axi)", &ok)
        updates.debugSetQuery("")
        settle(shell)

        // Check for updates is the toolbar's primary action, and it is Check all.
        let primary = shell.toolbar.debugPrimaryAction as? HelmButton
        check(primary === updates.debugCheckForUpdatesButton && primary?.title == "Check for updates"
                && primary?.action == NSSelectorFromString("checkAllTapped"),
              "the far-right button is \(primary?.title ?? "missing")", &ok)

        // A tool's detail and its output are the inspector's.
        updates.debugGroupCard(.updateAvailable)?.table.debugSelect(key: "quota-axi")
        settle(shell)
        check(updates.inspectorContent?.title == "quota-axi", "selecting a tool does not fill the inspector", &ok)
        updates.debugGroupCard(.updateAvailable)?.table.debugSelect(key: nil)
    }

    private static func checkGitHubSync(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let github = shell.workspace.githubSync
        ConfigRepoPrivacy.debugReset()
        shell.workspace.navigator.show(.githubSync)
        settle(shell)
        _ = waitUntil(timeout: 15) { !github.debugIsCheckingAll }
        // GL-14: a test process refuses `gh`, so every check failed - which
        // the subtitle used to report as "all in sync".
        let subtitle = github.drillHeaderSubtitle ?? ""
        check(!subtitle.contains("all in sync") && subtitle.contains("every check failed"),
              "with every check failed the subtitle reads \"\(subtitle)\"", &ok)
        check(!github.debugPausedCardIsShown, "the paused card shows with no confirmed public repo", &ok)
        ConfigRepoPrivacy.debugRecord(.unknown("offline"))
        settle(shell)
        check(!github.debugPausedCardIsShown, "an unanswered visibility check shows the paused card", &ok)
        ConfigRepoPrivacy.debugRecord(.publicRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        settle(shell)
        check(github.debugPausedCardIsShown && github.debugPausedTitle == "Pushing is paused"
                && github.debugPausedActions.map(\.title) == ["Open on GitHub", "Check again"],
              "a public config repo does not show the paused card with its two actions", &ok)
        let notice = github.debugPausedNotice
        let card = notice.convert(notice.bounds, to: nil)
        for button in github.debugPausedActions {
            let frame = button.convert(button.bounds, to: nil)
            check(card.contains(frame), "\(button.title) is drawn outside the paused card", &ok)
        }
        ConfigRepoPrivacy.debugRecord(.privateRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        settle(shell)
        check(!github.debugPausedCardIsShown, "the paused card stayed after the repo was private", &ok)

        // The forks table: one row each, Sync only on one behind.
        let records = github.debugForksTable.debugRows.filter(\.isRecord)
        check(records.count == GitHubSyncCatalog.repos.count, "the table lists \(records.count) forks", &ok)
        github.debugApplyCheck(index: 0, status: .behind(3), upstream: "kunchenguid/x")
        settle(shell)
        let behind = github.debugForksTable.debugRows.first { $0.key == GitHubSyncCatalog.repos[0].fullName }
        if case .status(let text, _)? = behind?.cells["behind"] {
            check(text == "3 commits", "a fork 3 behind reads \(text)", &ok)
        } else {
            fail("a fork behind draws no count", &ok)
        }
        check(behind?.primary?.title == "Sync" && behind?.pinsPrimary == true, "a fork behind offers no Sync", &ok)
        check(shell.toolbar.debugPrimaryAction === github.debugSyncAllButton, "Sync all is not the far-right button", &ok)
        check(shell.toolbar.debugPageActions.contains { $0 === github.debugRefreshButton }, "Refresh left the toolbar", &ok)
    }

    private static func checkSetupSteps(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let steps = shell.workspace.bootstrap
        shell.workspace.navigator.show(.bootstrap)
        settle(shell)
        check(!steps.debugFullSetupCardShown, "Setup steps still draws its own run card", &ok)
        check(shell.toolbar.debugPrimaryAction === steps.debugRunFullSetupButton, "Run full setup is not the far-right button", &ok)
        for kind in SetupStepKind.allCases {
            guard let details = steps.debugDetailsButton(kind) else {
                fail("\(kind.title) has no Details", &ok)
                continue
            }
            check(!steps.debugStepContentIsShown(kind), "\(kind.title)'s controls are open by default", &ok)
            details.performClick(nil)
            settle(shell)
            check(steps.debugStepContentIsShown(kind) && details.title == "Hide details",
                  "Details did not open \(kind.title)'s controls", &ok)
            details.performClick(nil)
            settle(shell)
            check(!steps.debugStepContentIsShown(kind), "Hide details did not close \(kind.title)'s controls", &ok)
            // The step's own action shows on the current step and nowhere else.
            if let action = steps.debugStepActionButton(kind), !action.isHidden {
                check(steps.debugStepIsCurrent(kind), "\(kind.title) offers \(action.title) but is not the current step", &ok)
            }
        }
    }

    private static func checkAutomation(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let store = shell.workspace.scheduleStore
        let schedule = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10))
        store.add(schedule)
        defer { store.delete(id: schedule.id) }
        let automation = shell.workspace.automation
        shell.workspace.navigator.show(.automation)
        settle(shell)
        check(!automation.debugRunCardShown, "Automation still draws its run card", &ok)
        check(shell.toolbar.debugPrimaryAction === automation.debugRunButton, "Run Automation is not the far-right button", &ok)
        let rows = automation.debugAutomationRows
        let titles = rows.map(\.titleLabel.stringValue)
        for title in [ScheduledActionKind.forkSync.title, "Commit and push dotfiles changes automatically",
                      "Reconnect dropped terminal sessions"] {
            check(titles.contains(title), "the Automation card lacks \(title): \(titles)", &ok)
        }
        // A schedule's switch writes the store the Schedules page reads.
        guard let row = rows.first(where: { $0.titleLabel.stringValue == ScheduledActionKind.forkSync.title }),
              let toggle = row.control as? HelmToggle else {
            fail("the schedule's row has no switch", &ok)
            return
        }
        check(toggle.isOn, "an enabled schedule's switch is off", &ok)
        toggle.isOn = false
        toggle.onToggle?()
        settle(shell)
        check(store.schedule(id: schedule.id)?.isEnabled == false, "the switch did not pause the schedule", &ok)
    }

    /// Sup-1: the same five figures on all four tabs, from the same
    /// readings, under each tab's own verdict and pills.
    private static func checkTheSummaryRow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        var counts = BackgroundSignalsPoller.SignalCounts()
        counts.toolsTotal = 8
        counts.toolsUpToDate = 6
        counts.toolsWithUpdate = 2
        counts.toolUpdates = 2
        counts.setupDrift = 1
        counts.forksTotal = 8
        counts.forksChecked = 8
        counts.forkDrift = 0
        BackgroundSignalsPoller.shared.debugSetCounts(counts)
        // Newer than anything the scratch pages answer for themselves, so
        // the fixture is what every tab reads.
        var steps: [SetupStepKind: Bool?] = [:]
        for (index, kind) in SetupStepKind.allCases.enumerated() { steps[kind] = index != 1 }
        SetupStepsReading.shared.record(steps, gatheredAt: Date().addingTimeInterval(3600))
        defer { SetupStepsReading.shared.resetForTests() }
        DotfilesAutoSync.shared.debugSetStatus(.synced)
        ConfigRepoPrivacy.debugRecord(.publicRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let want = ["6 / 8", "2", "4 / 5", "Synced", "Paused"]
        let rows: [(String, SetupHeroRow)] = [
            ("Updates", shell.workspace.updates.debugSetupSummary),
            ("Setup steps", shell.workspace.bootstrap.debugSetupSummary),
            ("Automation", shell.workspace.automation.debugSetupSummary),
            ("GitHub sync", shell.workspace.githubSync.debugSetupSummary),
        ]
        for (name, row) in rows {
            check(row.debugValues == want, "\(name)'s hero tiles read \(row.debugValues), want \(want)", &ok)
            check(row.debugCards.allSatisfy { $0.debugIsHeroTile && $0.debugFigureIsAboveCaption },
                  "\(name)'s tiles are not the hero's inset tiles", &ok)
            check(row.debugKicker == "SETUP \u{00B7} THIS MAC", "\(name)'s kicker reads \(row.debugKicker)", &ok)
            check(row.debugRing.debugLabel == "4/5", "\(name)'s ring reads \(row.debugRing.debugLabel)", &ok)
        }
        // Each tab's verdict is its own, from the readings its tiles show.
        let verdicts = rows.map(\.1.debugHeadline)
        check(verdicts[0] == "2 tools have an update.", "Updates' verdict reads \(verdicts[0])", &ok)
        check(verdicts[1] == "4 of 5 setup steps are done.", "Setup steps' verdict reads \(verdicts[1])", &ok)
        check(verdicts[3] == "Pushing to the config repo is paused.", "GitHub sync's verdict reads \(verdicts[3])", &ok)
        check(Set(verdicts).count == verdicts.count, "two tabs share a verdict: \(verdicts)", &ok)
        // The pills are each tab's own controls.
        let pills = rows.map { $0.1.debugPills.map(\.title) }
        check(pills == [["Check for updates"], ["Run full setup", "Refresh"], ["Run Automation", "Refresh"],
                        ["Sync All", "Refresh"]], "the hero's pills read \(pills)", &ok)
        // GL-14's tone: amber on a tab whose own subject needs attention (two
        // updates), red on a paused push, the accent on a tab with neither.
        let theme = ThemeManager.shared.theme
        let tones = rows.map { SetupHeroRow.palette(for: $0.1.current, in: theme) }
        check(rows[0].1.current.tone == .amber && rows[3].1.current.tone == .red && rows[1].1.current.tone == .accent,
              "the tabs' tones are \(rows.map(\.1.current.tone))", &ok)
        for ((name, row), palette) in zip(rows, tones) {
            check(row.debugPalette == palette, "\(name)'s gradient is not its verdict's tone", &ok)
        }
        // R2-BUG-05: both step tabs' subtitles state the reading the tile
        // renders, whichever tab computed last.
        let subtitles = [shell.workspace.bootstrap.drillHeaderSubtitle, shell.workspace.automation.drillHeaderSubtitle]
        check(subtitles.allSatisfy { $0 == "4 of 5 steps done" },
              "the Setup tabs' subtitles read \(subtitles) beside a \"4 / 5\" tile", &ok)

        // A pill runs the control it mirrors, and follows its state: Check for
        // updates is disabled while its sweep runs, and so is its pill.
        let updates = shell.workspace.updates
        shell.workspace.navigator.show(.updates)
        settle(shell)
        if let pill = rows[0].1.debugPills.first {
            pill.performClick(nil)
            check(!updates.debugCheckForUpdatesButton.isEnabled && !pill.isEnabled,
                  "the Check for updates pill did not start the sweep it mirrors", &ok)
            _ = waitUntil(timeout: 10) { updates.debugCheckForUpdatesButton.isEnabled }
            check(pill.isEnabled, "the pill stayed disabled after the sweep ended", &ok)
        } else {
            fail("Updates' hero has no pill", &ok)
        }

        // R5-BUG-03: every tab's hero follows a theme change, Setup steps'
        // included, and a later count change does not put the old theme back.
        // The gradient is the theme's accent, so it is the theme's palette.
        let accentPalette = { (theme: HelmTheme) in
            SetupHeroRow.palette(for: SetupHeroWords.Words(headline: "", body: "", tone: .accent, isDimmed: false),
                                 in: theme)
        }
        check(accentPalette(.dusk) != accentPalette(.daylight),
              "Dusk and Daylight share a hero palette, so the theme check is vacuous", &ok)
        ConfigRepoPrivacy.debugRecord(.privateRepo)
        for theme in [HelmTheme.dusk, .daylight] {
            ThemeManager.shared.setTheme(theme)
            counts.toolsUpToDate = theme.id == HelmTheme.dusk.id ? 5 : 6
            BackgroundSignalsPoller.shared.debugSetCounts(counts)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            for (name, row) in rows {
                check(row.debugPalette == SetupHeroRow.palette(for: row.current, in: theme),
                      "\(name)'s hero kept another theme's gradient after switching to \(theme.id)", &ok)
            }
        }
        // R5-PROC-04: one set of source observers, one feed observer per row.
        check(SetupSummaryFeed.shared.debugObserverCount == rows.count,
              "the summary feed has \(SetupSummaryFeed.shared.debugObserverCount) observers for \(rows.count) rows", &ok)

        checkTheSetupHeroWidths(shell, window, &ok)
    }

    /// The hero's three widths on a real page, and never a window floor
    /// (gotcha (13)): wide in one row, then the tiles under the words, then
    /// the ring steps out.
    private static func checkTheSetupHeroWidths(_ shell: MainSplitShellController, _ window: NSWindow,
                                                _ ok: inout Bool) {
        let github = shell.workspace.githubSync
        shell.workspace.navigator.show(.githubSync)
        let hero = github.debugSetupSummary
        for width in [1512, 1100] as [CGFloat] {
            resize(window, width: width, shell)
            hero.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - width) < 0.5, "the Setup hero held the window at \(window.frame.width)pt", &ok)
            let want: SetupHeroRow.Arrangement = hero.bounds.width >= SetupHeroRow.wideWidth ? .wide
                : (hero.bounds.width >= SetupHeroRow.ringMinimumWidth ? .stacked : .narrow)
            check(hero.arrangement == want, "a \(hero.bounds.width)pt hero is \(hero.arrangement), want \(want)", &ok)
            let tiles = hero.debugTiles.convert(hero.debugTiles.bounds, to: hero)
            let words = hero.debugWordsColumn.convert(hero.debugWordsColumn.bounds, to: hero)
            check(hero.bounds.contains(tiles) && hero.bounds.contains(words),
                  "at \(width)pt the hero's words or tiles are drawn outside it", &ok)
            check(!tiles.intersects(words), "at \(width)pt the tiles overlap the words", &ok)
            check(hero.debugCards.allSatisfy { $0.debugValueFits }, "at \(width)pt a tile's figure is cut off", &ok)
            // Every tab's words wrap at the room they have rather than giving
            // it up to save a line: a body narrower than both its one-line
            // width and its wrap width has been squeezed, and truncates.
            for row in [shell.workspace.updates.debugSetupSummary, shell.workspace.bootstrap.debugSetupSummary,
                        shell.workspace.automation.debugSetupSummary, hero] {
                row.layoutSubtreeIfNeeded()
                for label in [row.debugHeadlineLabel, row.debugBodyLabel] where !label.isHidden && row.window != nil {
                    let oneLine = ceil(label.attributedStringValue.size().width)
                    let room = min(oneLine, label.preferredMaxLayoutWidth)
                    check(label.frame.width >= room - 2,
                          "at \(width)pt \"\(label.stringValue)\" is \(label.frame.width)pt wide with \(room)pt to wrap in", &ok)
                }
            }
            if hero.debugRingShown {
                let ring = hero.debugRingColumn.convert(hero.debugRingColumn.bounds, to: hero)
                check(hero.bounds.contains(ring) && !ring.intersects(tiles) && !ring.intersects(words),
                      "at \(width)pt the ring overlaps the words or the tiles", &ok)
            }
        }
        check(hero.arrangement != .wide, "the 1100pt window's hero is still in one row, so the stacked case is vacuous", &ok)
        resize(window, width: 1512, shell)
    }

    // MARK: Renders

    /// With `FM_SETUP_HERO_RENDER_DIR`, one PNG per sub-page, theme and
    /// window width, and the states a fork reading can be in on GitHub sync.
    /// Every figure is the pages' own reading: the scratch setup steps, the
    /// fixture's tool checks and fork rows set through the page, so a verdict
    /// never disagrees with the table under it.
    private static func writeSetupRenders(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_SETUP_HERO_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        ConfigRepoPrivacy.debugRecord(.privateRepo)
        DotfilesAutoSync.shared.debugSetStatus(.off)
        let github = shell.workspace.githubSync
        func setForks(_ status: (Int) -> GitHubSyncStatus) {
            for (index, repo) in GitHubSyncCatalog.repos.enumerated() {
                let upstream = repo.manualUpstreamFullName ?? "kunchenguid/\(repo.name)"
                let fork = status(index)
                let detail: String
                switch fork {
                case let .ahead(own): detail = GitHubSyncStatus.detail(localOnly: own, upstreamAhead: 0, upstream: upstream)
                case let .diverged(own, ahead):
                    detail = GitHubSyncStatus.detail(localOnly: own, upstreamAhead: ahead, upstream: upstream)
                case let .behind(count): detail = GitHubSyncStatus.detail(localOnly: 0, upstreamAhead: count, upstream: upstream)
                case .checkFailed: detail = "no answer from gh"
                default: detail = ""
                }
                github.debugApplyCheck(index: index, status: fork, upstream: upstream, detail: detail)
            }
        }
        let vault = GitHubSyncCatalog.repos.firstIndex { $0.name == "automic-vault" }
        // The board's Automation: fork sync daily at 11:10 AM, on.
        let store = shell.workspace.scheduleStore
        let forkSync = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10))
        store.add(forkSync)
        defer { store.delete(id: forkSync.id) }
        let inSync: (Int) -> GitHubSyncStatus = { $0 == vault ? .ahead(6) : .inSync }
        // Each page answers for itself once, so the tiles are its readings.
        shell.workspace.navigator.show(.bootstrap)
        settle(shell)
        // The suite reset the steps' reading; the page's own Refresh, pressed
        // through its pill, records them again.
        let stepsHero = shell.workspace.bootstrap.debugSetupSummary
        stepsHero.debugPills.last?.performClick(nil)
        _ = waitUntil(timeout: 20) { stepsHero.debugPills.last?.isEnabled == true && !stepsHero.current.isDimmed }
        shell.workspace.navigator.show(.updates)
        settle(shell)
        shell.workspace.updates.renderStats()
        shell.workspace.navigator.show(.githubSync)
        settle(shell)
        _ = waitUntil(timeout: 15) { !github.debugIsCheckingAll }
        setForks(inSync)
        let pages: [(String, RailDestination)] = [("updates", .updates), ("steps", .bootstrap),
                                                  ("automation", .automation), ("github", .githubSync)]
        func shoot(_ name: String) {
            settle(shell)
            TasksSecretsHeroViewSelfTest.write(shell.view, to: folder.appendingPathComponent("\(name).png"))
        }
        for theme in [HelmTheme.daylight, .dusk] {
            ThemeManager.shared.setTheme(theme)
            for width in [1512, 1100] as [CGFloat] {
                resize(window, width: width, shell)
                for (name, destination) in pages {
                    shell.workspace.navigator.show(destination)
                    shoot("setup-\(name)-\(theme.id)-\(Int(width))")
                }
            }
            // The states a fork reading can be in, on GitHub sync.
            resize(window, width: 1512, shell)
            shell.workspace.navigator.show(.githubSync)
            setForks { $0 < 2 ? .behind(3) : inSync($0) }
            shoot("setup-github-behind-\(theme.id)")
            setForks { $0 == 0 ? .diverged(localOnly: 2, upstreamAhead: 4) : inSync($0) }
            shoot("setup-github-diverged-\(theme.id)")
            setForks { _ in .checkFailed }
            shoot("setup-github-failed-\(theme.id)")
            setForks { _ in .unknown }
            shoot("setup-github-unread-\(theme.id)")
            setForks(inSync)
        }
        resize(window, width: 1512, shell)
        print("SidebarRedesignsSelfTest: Setup renders written to \(dir)")
    }

    private static func sameColour(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
        abs(a.0 - b.0) < 0.01 && abs(a.1 - b.1) < 0.01 && abs(a.2 - b.2) < 0.01
    }

    // MARK: Helpers

    private static func clickTab(_ name: String, _ shell: MainSplitShellController) {
        guard let index = shell.toolbar.debugTabNames.firstIndex(of: name) else { return }
        shell.debugClickTab(index)
        settle(shell)
    }

    /// The window height the Operator sidebar with one live session fits in
    /// whole. It was 950 until DevOps Hub's two rows arrived.
    static let defaultSetFitsHeight: CGFloat = 1000

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size = NSSize(width: width, height: 950)
        window.setFrame(frame, display: false)
        settle(shell)
    }

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    /// Pumps the main run loop until `condition()` is true or `timeout`
    /// elapses (`HerdrRestartButtonSelfTest.waitUntil`'s convention).
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

#endif
