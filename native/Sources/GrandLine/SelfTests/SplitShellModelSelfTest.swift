// Grand Line - native macOS app.
//
// Stages 3 and 4 of the modular-shell migration: the sidebar shell's pure
// halves.
//
//   1. **The sidebar lists every module, once, and every route still lands.**
//      `WorkspaceSidebarModel` over the module table: Home first, the
//      captain's pins in their own order, then the four groups, with
//      Console's live sessions as its children. Every one of the 29 routes
//      resolves to exactly one module, and to one of its tabs where the
//      toolbar draws them - the deep-link sweep the review's step 4 asks for.
//      A destination added without a module, or a tab with no real view
//      behind it, fails here by name.
//   2. **Back and Forward walk what was shown.** `NavigationHistory`.
//   3. **The layout setting.** The floating bar is the default and the
//      answer to any value this build does not know, and each layout builds
//      its own shell.
//   4. **The wiring a behaviour check cannot see.** The app delegate builds
//      the shell the setting names and skips the floating bar's chrome fusion
//      for the sidebar; ⌘⇧D asks the shell first; the lock overlay tells the
//      shell when it shows; the toolbar's trailing cluster keeps the
//      captain's light/dark toggle and notifications button.
//
// Pure logic: no window. `MainSplitShellSelfTest` is the window-backed half.
//
// Run with:
//   swift build && FM_RUN_SPLIT_SHELL_MODEL_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SplitShellModelSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkEveryModuleIsListedOnce, checkEveryRouteLandsOnAModuleAndATab, checkGroupsFollowTheModuleTable,
                      checkTheTabsAreTheRealViews, checkPinnedMirrorsQuickAccess, checkSessionsAreConsoleChildren,
                      checkHistoryWalksBackAndForward, checkHistoryEdges, checkTheLayoutSetting, checkHomeCardLayout,
                      checkTheWiring] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SplitShellModelSelfTest: all checks passed" : "SplitShellModelSelfTest: FAILED")
        return allOK
    }

    // MARK: 1 - the sidebar

    private static func checkEveryModuleIsListedOnce(_ ok: inout Bool) {
        let listed = WorkspaceSidebarModel.listedModules()
        check(listed.count == 18 && Set(listed) == Set(WorkspaceModule.allCases) && Set(listed).count == listed.count,
              "the sidebar lists \(listed.map(\.rawValue)), want Home and the seventeen modules once each", &ok)

        // The same set as the rows the outline view gets, read off the tree.
        let roots = WorkspaceSidebarModel.roots(pinned: [], sessions: [])
        let fromTree = roots.flatMap { [$0] + $0.children }.compactMap { node -> WorkspaceModule? in
            if case .module(let module) = node.entry { return module }
            return nil
        }
        check(fromTree == listed, "the tree's module rows \(fromTree.map(\.rawValue)) are not the listed modules", &ok)
        check(roots.first?.entry == .module(.home), "Home is not the sidebar's first row", &ok)
    }

    /// The review's step 4 acceptance: every one of the 29 routes still
    /// resolves, through the module the sidebar lists and - where the toolbar
    /// draws the module's tabs - through one of them, so a deep link, a
    /// notification's Show in app, ⌘K or Recents lights the right row and tab.
    private static func checkEveryRouteLandsOnAModuleAndATab(_ ok: inout Bool) {
        let listed = Set(WorkspaceSidebarModel.listedModules())
        for route in RailDestination.allCases {
            let module = ModuleTable.module(for: route)
            check(ModuleTable.descriptor(for: route) != nil && listed.contains(module),
                  "\(route.rawValue) has no module the sidebar lists", &ok)
            if module.drawsToolbarTabs {
                check(module.tabs.contains { $0.route == route },
                      "\(route.rawValue) lives in \(module.title) but none of its tabs shows it", &ok)
                check(ModuleTable.tab(for: route, pageTab: nil)?.route == route,
                      "a deep link to \(route.rawValue) does not light one of \(module.title)'s tabs", &ok)
            } else {
                check(ModuleTable.routes(in: module).contains(route) && module.pages.contains(route),
                      "\(route.rawValue) is not one of \(module.title)'s pages", &ok)
            }
        }
        // Every module opens on one of its own pages.
        for module in WorkspaceModule.allCases {
            check(ModuleTable.module(for: module.primaryRoute) == module,
                  "\(module.title) opens on \(module.primaryRoute.rawValue), which is not its own", &ok)
        }
    }

    private static func checkGroupsFollowTheModuleTable(_ ok: inout Bool) {
        let roots = WorkspaceSidebarModel.roots(pinned: [], sessions: [])
        let sections = roots.compactMap { node -> String? in
            if case .section(let title) = node.entry { return title }
            return nil
        }
        check(sections == WorkspaceGroup.allCases.map(\.title),
              "the sections are \(sections), want the four groups in order", &ok)
        let expected: [WorkspaceGroup: [WorkspaceModule]] = [
            .work: [.tasks, .crew, .connections, .console, .knowledge, .secrets],
            .observe: [.kubernetes, .logs, .health, .schedules],
            .workbench: [.tools, .whiteboard, .stickyBoard, .code, .dictation],
            .machine: [.setup, .settings],
        ]
        for group in WorkspaceGroup.allCases {
            let modules = WorkspaceSidebarModel.modules(in: group)
            check(modules == expected[group],
                  "\(group.title) lists \(modules.map(\.rawValue)), want \(expected[group]?.map(\.rawValue) ?? [])", &ok)
        }
    }

    /// Each module's tabs are real views: a destination of its own, or one of
    /// the page's own tabs. Typed out, because the table is what is being
    /// checked.
    private static func checkTheTabsAreTheRealViews(_ ok: inout Bool) {
        typealias Tab = (name: String, route: RailDestination, pageTab: Bool)
        let expected: [WorkspaceModule: [Tab]] = [
            .tasks: [("Board", .shift, true), ("List", .shift, true), ("Calendar", .shift, true),
                     ("Weekly review", .shift, true)],
            // Needs you is the Fleet page's, in the sidebar layout only: the
            // parked tasks and their open decisions (the later page work).
            .crew: [("Needs you", .overview, true), ("In flight", .overview, true), ("Review", .review, false),
                    ("Ask the crew", .strawHat, false), ("Log", .overview, true)],
            .connections: [("Hosts", .hosts, true), ("Keys", .hosts, true), ("Snippets", .hosts, true),
                           ("Commands", .commandLibrary, false)],
            .knowledge: [("Notebook", .notebook, false), ("Runbooks", .runbooks, false),
                         ("Postmortems", .postmortems, false), ("Docs", .docs, false),
                         ("Reading list", .readingList, false)],
            .secrets: [("Poneglyph", .poneglyph, false), ("Automic Vault", .vault, false)],
            .kubernetes: [("Cluster", .kubernetes, true), ("Log Tail", .kubernetes, true)],
            .setup: [("Updates", .updates, false), ("Setup steps", .bootstrap, false),
                     ("Automation", .automation, false), ("GitHub sync", .githubSync, false)],
        ]
        for module in WorkspaceModule.allCases {
            let tabs = module.tabs.map { Tab($0.name, $0.route, $0.isPageTab) }
            let want = expected[module] ?? []
            check(tabs.count == want.count && zip(tabs, want).allSatisfy { $0.name == $1.name && $0.route == $1.route && $0.pageTab == $1.pageTab },
                  "\(module.title)'s tabs are \(tabs.map { "\($0.name)/\($0.route.rawValue)/\($0.pageTab)" }), want \(want.map { "\($0.name)/\($0.route.rawValue)/\($0.pageTab)" })", &ok)
            if module.drawsToolbarTabs {
                check(tabs.count == module.children.count, "\(module.title) has a child with no view behind it", &ok)
            }
        }
        check(!WorkspaceModule.settings.drawsToolbarTabs && !WorkspaceModule.settings.children.isEmpty,
              "Settings' categories moved into the toolbar; its page keeps its own column", &ok)
        // The captain's call: no big title on Connections and Console, and
        // every other module keeps its title and subtitle.
        let headless = WorkspaceModule.allCases.filter { !$0.showsHeader }
        check(headless == [.connections, .console], "the modules without a header are \(headless.map(\.rawValue))", &ok)
    }

    private static func checkPinnedMirrorsQuickAccess(_ ok: inout Bool) {
        // Pages nested inside a module of several, in the captain's order;
        // a page that is its module's only page is that module's row already.
        let pinned: [RailDestination] = [.hosts, .console, .strawHat, .stickyBoard]
        let roots = WorkspaceSidebarModel.roots(pinned: pinned, sessions: [])
        guard roots.count > 1, roots[1].entry == .section(WorkspaceSidebarModel.pinnedTitle) else {
            fail("the Pinned section is not right under Home", &ok)
            return
        }
        check(roots[1].children.map(\.entry) == [.pinned(.hosts), .pinned(.strawHat)],
              "the Pinned rows are \(roots[1].children.map(\.entry)), want Hosts then Straw Hat Pirates", &ok)
        check(RailDestination.hosts.isNestedInItsModule && !RailDestination.stickyBoard.isNestedInItsModule,
              "the fixture's two kinds of pin are not what this check assumes - it would pass vacuously", &ok)
        for none in [[RailDestination](), [.console, .stickyBoard]] {
            check(!WorkspaceSidebarModel.roots(pinned: none, sessions: []).contains { $0.entry == .section(WorkspaceSidebarModel.pinnedTitle) },
                  "pins \(none.map(\.rawValue)) still draw a Pinned section", &ok)
        }
        // The floating bar's own default pins: the nested ones are listed.
        let defaults = WorkspaceSidebarModel.roots(pinned: QuickAccessConfiguration().pinned, sessions: [])
        let nested = QuickAccessConfiguration.defaultPinned.filter(\.isNestedInItsModule)
        check(!nested.isEmpty && defaults[1].children.map(\.entry) == nested.map { .pinned($0) },
              "the default Pinned section does not carry the bar's nested default pins", &ok)
    }

    private static func checkSessionsAreConsoleChildren(_ ok: inout Bool) {
        let first = HostSession(hostID: UUID(), label: "DEV Bastion", accentHex: nil, startedAt: Date(), state: .connected)
        let second = HostSession(hostID: UUID(), label: "PROD Web", accentHex: nil, startedAt: Date(), state: .restored)
        let roots = WorkspaceSidebarModel.roots(pinned: [.console, .hosts], sessions: [first, second])
        let nodes = roots.flatMap { [$0] + $0.children }
        let consoles = nodes.filter { $0.entry == .module(.console) }
        check(consoles.count == 1, "Console appears \(consoles.count) times in the groups", &ok)
        check(consoles.first?.children.map(\.entry) == [.session(hostID: first.hostID), .session(hostID: second.hostID)],
              "the sessions are not Console's children, in the registry's order", &ok)
        check(!nodes.contains { $0.entry == .pinned(.console) }, "a pinned Console repeats the Console row", &ok)
        check(nodes.first { $0.entry == .pinned(.hosts) }?.children.isEmpty == true, "a pinned row carries children", &ok)
        let others = nodes.filter {
            if case .module(let module) = $0.entry { return module != .console }
            return false
        }
        check(others.allSatisfy { $0.children.isEmpty }, "a module other than Console has children", &ok)
    }

    // MARK: 2 - back and forward

    private static func checkHistoryWalksBackAndForward(_ ok: inout Bool) {
        var history = NavigationHistory()
        for page in [RailDestination.homeCanvas, .shift, .hosts] { history.arrive(.rail(page)) }
        check(history.back == [.rail(.homeCanvas), .rail(.shift)] && history.current == .rail(.hosts),
              "three visits left back \(history.back), current \(String(describing: history.current))", &ok)
        check(history.canGoBack && !history.canGoForward, "after three visits there should be Back and no Forward", &ok)

        history.expect(.back)
        history.arrive(.rail(.shift))
        history.finishStep(.back, arrived: true)
        check(history.current == .rail(.shift) && history.back == [.rail(.homeCanvas)] && history.forward == [.rail(.hosts)],
              "Back did not move one step: back \(history.back), forward \(history.forward)", &ok)

        history.expect(.back)
        history.arrive(.rail(.homeCanvas))
        history.finishStep(.back, arrived: true)
        check(!history.canGoBack && history.forward == [.rail(.hosts), .rail(.shift)],
              "two steps back left forward \(history.forward)", &ok)

        history.expect(.forward)
        history.arrive(.rail(.shift))
        history.finishStep(.forward, arrived: true)
        check(history.current == .rail(.shift) && history.back == [.rail(.homeCanvas)] && history.forward == [.rail(.hosts)],
              "Forward did not move one step: back \(history.back), forward \(history.forward)", &ok)

        // A new visit is a new branch: Forward is gone.
        history.arrive(.rail(.settings))
        check(!history.canGoForward && history.back.last == .rail(.shift),
              "a new visit kept Forward, or did not record where it came from", &ok)
    }

    private static func checkHistoryEdges(_ ok: inout Bool) {
        var history = NavigationHistory()
        history.arrive(.rail(.homeCanvas))
        history.arrive(.rail(.homeCanvas))
        check(!history.canGoBack, "showing the same page again pushed it onto Back", &ok)

        // A host page renamed while showing refreshes its label in place.
        let id = UUID()
        history.arrive(.host(id: id, label: "old"))
        history.arrive(.host(id: id, label: "new"))
        check(history.back == [.rail(.homeCanvas)] && history.current == .host(id: id, label: "new"),
              "a re-revealed host page was recorded as a new visit", &ok)

        // A walk whose target never arrives (a deleted host) drops it.
        history.arrive(.rail(.shift))
        history.expect(.back)
        history.finishStep(.back, arrived: false)
        check(history.back == [.rail(.homeCanvas)], "an unreachable Back target stayed offered: \(history.back)", &ok)

        // An expected step that a different page answers is a new visit.
        history.expect(.back)
        history.arrive(.rail(.review))
        check(history.current == .rail(.review) && history.back.last == .rail(.shift) && !history.canGoForward,
              "an arrival that was not the Back target moved along the stacks", &ok)

        // GL-35: bounded.
        var long = NavigationHistory()
        for index in 0..<(NavigationHistory.limit + 20) {
            long.arrive(.host(id: UUID(), label: "h\(index)"))
        }
        check(long.back.count == NavigationHistory.limit, "Back holds \(long.back.count), more than its limit", &ok)
    }

    // MARK: 3 - the layout setting

    private static func checkTheLayoutSetting(_ ok: inout Bool) {
        let suite = "split-shell-model-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("could not open a scratch defaults domain", &ok)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        check(settings.workspaceLayout == .floatingBar, "the default layout is not the floating bar", &ok)
        settings.workspaceLayout = .sidebar
        check(settings.workspaceLayout == .sidebar, "the sidebar layout did not persist", &ok)
        defaults.set("a-layout-from-the-future", forKey: "fm.workspaceLayout")
        check(settings.workspaceLayout == .floatingBar, "an unknown layout did not fall back to the floating bar", &ok)
        check(WorkspaceLayout.floatingBar.shellType == AppShellController.self
                && WorkspaceLayout.sidebar.shellType == MainSplitShellController.self,
              "a layout builds the wrong shell", &ok)
    }

    // MARK: 3b - Home's arranged cards

    private static func checkHomeCardLayout(_ ok: inout Bool) {
        // Before the captain arranges anything Home shows the hub's own cards.
        let standard = HomeCardLayout.standard
        check(Set(standard.shown) == Set(DaylightModule.canvasOrder.filter { $0.isVisible(in: .overview) })
                && standard.shown.count == Set(standard.shown).count && !standard.shown.isEmpty,
              "the standard layout is \(standard.shown.map(\.rawValue)), not the hub's own cards", &ok)
        // Arranged to fill rows: at four columns, two full rows.
        let rows = HelmResponsiveGrid.packRows(spans: standard.shown.map { standard.size(of: $0).span }, columns: 4)
        check(rows.allSatisfy { $0.reduce(0) { $0 + $1.span } == 4 },
              "at four columns Home's own cards leave a gap: \(rows.map { $0.map(\.span) })", &ok)
        check(Set(standard.shown).union(standard.hidden) == Set(DaylightModule.allCases)
                && Set(standard.shown).isDisjoint(with: standard.hidden),
              "shown and hidden do not partition every card", &ok)
        check(standard.size(of: .briefing) == .large && standard.size(of: .fleet) == .small,
              "a card's own span is not its standard size", &ok)

        var layout = standard
        guard let first = layout.shown.first, let second = layout.shown.dropFirst().first,
              let extra = layout.hidden.first else {
            fail("the standard layout has too few cards to arrange - the case is vacuous", &ok)
            return
        }
        layout.show(extra)
        check(layout.shown.last == extra && !layout.hidden.contains(extra), "showing a card did not add it at the end", &ok)
        layout.move(second, by: -1)
        check(Array(layout.shown.prefix(2)) == [second, first], "moving a card earlier did not swap it with the one before", &ok)
        check(!layout.canMove(second, by: -1), "the first card can still move earlier", &ok)
        layout.setSize(.wide, for: first)
        check(layout.size(of: first) == .wide && HomeCardLayout.Size.wide.span >= 12, "a card's size did not stick", &ok)
        layout.hide(first)
        check(!layout.shown.contains(first) && layout.hidden.contains(first), "hiding a card did not take it off Home", &ok)

        // A newer build's card survives this build's edits and round trip.
        guard let data = layout.storedData,
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var ids = json["shown"] as? [String] else {
            fail("the layout did not encode", &ok)
            return
        }
        ids.insert("aCardFromANewerBuild", at: 1)
        json["shown"] = ids
        guard let newer = try? JSONSerialization.data(withJSONObject: json),
              var read = HomeCardLayout(storedData: newer) else {
            fail("a layout with an unknown card did not decode", &ok)
            return
        }
        check(read.shown == layout.shown, "an unknown card changed the cards this build shows", &ok)
        read.move(second, by: 1)
        read.show(.settings)
        guard let rewritten = read.storedData, let again = HomeCardLayout(storedData: rewritten) else {
            fail("the edited layout did not round-trip", &ok)
            return
        }
        check(again.shownIDs.contains("aCardFromANewerBuild"), "an edit dropped a newer build's card", &ok)
        check(HomeCardLayout(storedData: Data("not json".utf8)) == nil, "junk decoded as a layout", &ok)

        // The preference: the standard set until written, and what was written after.
        let suite = "split-shell-home-layout-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("could not open a scratch defaults domain", &ok)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        check(settings.homeCardLayout == .standard, "Home's layout does not default to the standard set", &ok)
        settings.homeCardLayout = layout
        check(settings.homeCardLayout == layout, "Home's layout did not persist", &ok)
        defaults.set(Data("junk".utf8), forKey: "fm.homeCardLayout")
        check(settings.homeCardLayout == .standard, "an unreadable layout did not fall back to the standard set", &ok)
    }

    // MARK: 4 - the wiring

    private static func code(_ file: String) -> String? { FeatureInventorySelfTest.source(file) }

    private static func checkTheWiring(_ ok: inout Bool) {
        guard let main = code("main.swift"), let lock = code("LockPresenter.swift"),
              let shell = code("MainSplitShellController.swift"), let settings = code("SettingsController.swift"),
              let classic = code("AppShellController.swift"), let canvas = code("HomeCanvasController.swift") else {
            fail("could not read the sources this check reads - it would pass vacuously", &ok)
            return
        }
        // Home's arranged cards are the sidebar layout's: it hands the canvas
        // the captain's layout, the floating bar never does, and without one
        // the hub keeps its hand-placed dashboard.
        check(shell.contains("workspace.homeCanvas.cardLayout = AppSettings.shared.homeCardLayout"),
              "the sidebar layout no longer gives Home the captain's arranged cards", &ok)
        check(!classic.contains("cardLayout"), "the floating bar hands Home a card layout, which would replace its hub", &ok)
        check(canvas.contains("private var usesDashboardLayout: Bool { space == .overview && cardLayout == nil }"),
              "Home's hub no longer keeps its dashboard when no layout is set", &ok)
        // The four pages whose own tabs are a module's tabs.
        for (file, type) in [("ShiftController.swift", "ShiftController"), ("FleetController.swift", "FleetController"),
                             ("HostsController.swift", "HostsController"),
                             ("KubernetesController+Behaviour.swift", "KubernetesController")] {
            check(code(file)?.contains("extension \(type): ModuleTabHosting") == true,
                  "\(type) no longer lets the toolbar draw its tabs", &ok)
        }
        check(main.contains("workspaceLayout.shellType.init("),
              "main.swift no longer builds the shell the layout setting names", &ok)
        if let fusion = main.range(of: "WindowChromeFusion.apply(to: window)"),
           let gate = main.range(of: "if workspaceLayout == .floatingBar {") {
            check(gate.lowerBound < fusion.lowerBound
                    && main[gate.upperBound..<fusion.lowerBound].count < 40,
                  "the floating bar's chrome fusion is no longer applied only to the floating-bar layout", &ok)
        } else {
            fail("main.swift's window no longer gates its chrome fusion on the layout", &ok)
        }
        if let map = main.range(of: "@objc func showAllDestinations() {") {
            let body = main[map.upperBound...].prefix(400)
            check(body.contains("appShell.revealDestinationMap()"),
                  "⌘⇧D no longer asks the shell first, so the sidebar shell would open the floating map", &ok)
        }
        for (method, value) in [("func showLock(reason:", "true"), ("func hideLock()", "false")] {
            guard let start = lock.range(of: method) else {
                fail("LockPresenter has no \(method)", &ok)
                continue
            }
            let body = FeatureInventorySelfTest.braceBody(lock, from: start.upperBound)
            check(body.contains("onOverlayVisibilityChanged?(\(value))"),
                  "LockPresenter.\(method) no longer tells the shell, so the sidebar shell's toolbar stays up over the lock", &ok)
        }
        check(shell.contains("workspace.lock.onOverlayVisibilityChanged ="),
              "the sidebar shell no longer listens for the lock overlay", &ok)
        check(settings.contains("title: \"Window layout\"") && settings.contains("AppSettings.shared.workspaceLayout = layout"),
              "Settings > Appearance no longer offers the window layout", &ok)

        // The captain's call, kept: both stay in the toolbar's trailing
        // cluster, after the middle and before Search.
        let toolbar = WorkspaceToolbar(splitView: NSSplitView())
        let ids = toolbar.toolbarDefaultItemIdentifiers(toolbar.toolbar)
        guard let lastFlexible = ids.lastIndex(of: .flexibleSpace),
              let theme = ids.firstIndex(of: WorkspaceToolbar.ItemID.theme),
              let bell = ids.firstIndex(of: WorkspaceToolbar.ItemID.notifications),
              let search = ids.firstIndex(of: WorkspaceToolbar.ItemID.search) else {
            fail("the toolbar lost its light/dark toggle, its notifications button or Search: \(ids.map(\.rawValue))", &ok)
            return
        }
        check(lastFlexible < theme && theme < bell && bell < search,
              "the light/dark toggle and the notifications button are no longer the trailing cluster: \(ids.map(\.rawValue))", &ok)
        check(ids.first == WorkspaceToolbar.ItemID.sidebar && ids.contains(.sidebarTrackingSeparator),
              "the sidebar button no longer sits over the sidebar", &ok)
        check(!toolbar.toolbar.autosavesConfiguration && !toolbar.toolbar.allowsUserCustomization,
              "the toolbar autosaves its configuration, which writes UserDefaults.standard outside AppDefaults.store", &ok)
    }
}

#endif
