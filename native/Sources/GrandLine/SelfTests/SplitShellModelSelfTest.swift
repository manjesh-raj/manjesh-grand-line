// Grand Line - native macOS app.
//
// Stage 3 of the modular-shell migration: the sidebar shell's pure halves.
//
//   1. **The sidebar lists every page, once.** `WorkspaceSidebarModel` over
//      the module table: Home first, the captain's pins in their own order,
//      then the four groups, with Console's live sessions as its children.
//      A destination added without a module, or dropped from the table,
//      fails here by name rather than quietly having no row.
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
        for check in [checkEveryPageIsListedOnce, checkGroupsFollowTheModuleTable, checkPinnedMirrorsQuickAccess,
                      checkSessionsAreConsoleChildren, checkHistoryWalksBackAndForward,
                      checkHistoryEdges, checkTheLayoutSetting, checkTheWiring] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SplitShellModelSelfTest: all checks passed" : "SplitShellModelSelfTest: FAILED")
        return allOK
    }

    // MARK: 1 - the sidebar

    private static func checkEveryPageIsListedOnce(_ ok: inout Bool) {
        let listed = WorkspaceSidebarModel.listedDestinations()
        check(listed.count == RailDestination.allCases.count,
              "the sidebar lists \(listed.count) pages for \(RailDestination.allCases.count) destinations", &ok)
        let missing = Set(RailDestination.allCases).subtracting(listed)
        check(missing.isEmpty, "no sidebar row for \(missing.map(\.rawValue).sorted())", &ok)
        let duplicated = Dictionary(grouping: listed, by: { $0 }).filter { $0.value.count > 1 }.keys
        check(duplicated.isEmpty, "listed twice outside Pinned: \(duplicated.map(\.rawValue).sorted())", &ok)

        // The same set as the rows the outline view gets, read off the tree.
        let roots = WorkspaceSidebarModel.roots(pinned: [], sessions: [])
        let fromTree = roots.flatMap { [$0] + $0.children }.compactMap { node -> RailDestination? in
            if case .destination(let destination, pinned: false) = node.entry { return destination }
            return nil
        }
        check(fromTree == listed, "the tree's page rows \(fromTree.map(\.rawValue)) are not the listed pages", &ok)
        check(roots.first?.entry == .destination(.homeCanvas, pinned: false), "Home is not the sidebar's first row", &ok)
    }

    private static func checkGroupsFollowTheModuleTable(_ ok: inout Bool) {
        let roots = WorkspaceSidebarModel.roots(pinned: [], sessions: [])
        let sections = roots.compactMap { node -> String? in
            if case .section(let title) = node.entry { return title }
            return nil
        }
        check(sections == WorkspaceGroup.allCases.map(\.title),
              "the sections are \(sections), want the four groups in order", &ok)
        for group in WorkspaceGroup.allCases {
            for destination in WorkspaceSidebarModel.destinations(in: group) {
                let module = ModuleTable.descriptor(for: destination)?.module
                check(module?.group == group,
                      "\(destination.rawValue) is listed under \(group.title) but the table puts it in \(module?.group?.title ?? "none")", &ok)
            }
        }
        // Inside a module, the order of its children - Knowledge in the
        // prototype's tab order rather than declaration order.
        let work = WorkspaceSidebarModel.destinations(in: .work)
        let knowledge = work.filter { ModuleTable.descriptor(for: $0)?.module == .knowledge }
        check(knowledge == [.notebook, .runbooks, .postmortems, .docs, .readingList],
              "Knowledge's pages are \(knowledge.map(\.rawValue)), want Notebook, Runbooks, Postmortems, Docs, Reading List", &ok)
        let setup = WorkspaceSidebarModel.destinations(in: .machine)
        check(setup == [.updates, .bootstrap, .automation, .githubSync, .settings],
              "Machine lists \(setup.map(\.rawValue)), want Updates, Bootstrap, Automation, GitHub Sync, Settings", &ok)
    }

    private static func checkPinnedMirrorsQuickAccess(_ ok: inout Bool) {
        let pinned: [RailDestination] = [.console, .stickyBoard, .hosts]
        let roots = WorkspaceSidebarModel.roots(pinned: pinned, sessions: [])
        guard roots.count > 1, roots[1].entry == .section(WorkspaceSidebarModel.pinnedTitle) else {
            fail("the Pinned section is not right under Home", &ok)
            return
        }
        check(roots[1].children.map(\.entry) == pinned.map { .destination($0, pinned: true) },
              "the Pinned rows are not the pins in the captain's order", &ok)
        let none = WorkspaceSidebarModel.roots(pinned: [], sessions: [])
        check(!none.contains { $0.entry == .section(WorkspaceSidebarModel.pinnedTitle) },
              "an empty pin list still draws a Pinned section", &ok)
        // The default pins are the floating bar's own seven.
        let defaults = WorkspaceSidebarModel.roots(pinned: QuickAccessConfiguration().pinned, sessions: [])
        check(defaults[1].children.count == QuickAccessConfiguration.defaultPinned.count,
              "the default Pinned section does not carry the bar's default pins", &ok)
    }

    private static func checkSessionsAreConsoleChildren(_ ok: inout Bool) {
        let first = HostSession(hostID: UUID(), label: "DEV Bastion", accentHex: nil, startedAt: Date(), state: .connected)
        let second = HostSession(hostID: UUID(), label: "PROD Web", accentHex: nil, startedAt: Date(), state: .restored)
        let roots = WorkspaceSidebarModel.roots(pinned: [.console], sessions: [first, second])
        let nodes = roots.flatMap { [$0] + $0.children }
        let consoles = nodes.filter { $0.entry == .destination(.console, pinned: false) }
        check(consoles.count == 1, "Console appears \(consoles.count) times in the groups", &ok)
        check(consoles.first?.children.map(\.entry) == [.session(hostID: first.hostID), .session(hostID: second.hostID)],
              "the sessions are not Console's children, in the registry's order", &ok)
        let pinnedConsole = nodes.first { $0.entry == .destination(.console, pinned: true) }
        check(pinnedConsole?.children.isEmpty == true, "the Pinned copy of Console carries the sessions too", &ok)
        let others = nodes.filter {
            if case .destination(let destination, _) = $0.entry { return destination != .console }
            return false
        }
        check(others.allSatisfy { $0.children.isEmpty }, "a page other than Console has children", &ok)
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

    // MARK: 4 - the wiring

    private static func code(_ file: String) -> String? { FeatureInventorySelfTest.source(file) }

    private static func checkTheWiring(_ ok: inout Bool) {
        guard let main = code("main.swift"), let lock = code("LockPresenter.swift"),
              let shell = code("MainSplitShellController.swift"), let settings = code("SettingsController.swift") else {
            fail("could not read the sources this check reads - it would pass vacuously", &ok)
            return
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
