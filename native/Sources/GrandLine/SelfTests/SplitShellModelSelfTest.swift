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
//   3. **The layout setting.** The sidebar is the default - for a fresh
//      store, and as the answer to any value this build does not know - while
//      a stored choice of either layout is kept, so a captain who picked the
//      floating bar still gets it. Each layout builds its own shell, and the
//      default is spelled once (`WorkspaceLayout.standard`), with no second
//      literal in the app or the tour lab.
//   4. **The wiring a behaviour check cannot see.** The app delegate builds
//      the shell the setting names and skips the floating bar's chrome fusion
//      for the sidebar; ⌘⇧D asks the shell first; the lock overlay tells the
//      shell when it shows; the toolbar's trailing cluster keeps the
//      captain's light/dark toggle and notifications button.
//   5. **No status strip, anywhere.** The captain had the layout's status
//      strip removed from every module, so no source draws one, the content
//      pane runs its body to its foot, and the focus timer's chip - the one
//      control the strip carried - is the toolbar's.
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
                      checkTheTabsAreTheRealViews, checkTheCalendarRow, checkSavedSidebarsGetTheCalendar,
                      checkTheSidebarDrawsNoPins, checkSessionsAreConsoleChildren,
                      checkHistoryWalksBackAndForward, checkHistoryEdges, checkTheLayoutSetting,
                      checkTheDefaultIsTheSidebar, checkTheDefaultIsSpelledOnce, checkHomeCardLayout,
                      checkTheWiring, checkTheLayoutDrawsNoStatusStrip] {
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
        check(listed.count == 19 && Set(listed) == Set(WorkspaceModule.allCases) && Set(listed).count == listed.count,
              "the sidebar lists \(listed.map(\.rawValue)), want Home and the eighteen modules once each", &ok)

        // The same set as the rows the outline view gets, read off the tree.
        let roots = WorkspaceSidebarModel.roots(sessions: [])
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
        let roots = WorkspaceSidebarModel.roots(sessions: [])
        let sections = roots.compactMap { node -> String? in
            if case .section(let title) = node.entry { return title }
            return nil
        }
        check(sections == WorkspaceGroup.allCases.map(\.title),
              "the sections are \(sections), want the four groups in order", &ok)
        let expected: [WorkspaceGroup: [WorkspaceModule]] = [
            .work: [.tasks, .calendar, .crew, .connections, .console, .knowledge, .secrets],
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
            .tasks: [("Board", .shift, true), ("List", .shift, true), ("Weekly review", .shift, true)],
            // The Calendar's own page draws its four views (`TaskCalendarController`).
            .calendar: [("Month", .calendar, true), ("Week", .calendar, true), ("Day", .calendar, true),
                        ("Agenda", .calendar, true)],
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
        // the Calendar draws its mockup's heading itself; every other module
        // keeps its title and subtitle.
        let headless = WorkspaceModule.allCases.filter { !$0.showsHeader }
        check(headless == [.calendar, .connections, .console], "the modules without a header are \(headless.map(\.rawValue))", &ok)
    }

    /// Stage 6, the captain's call: the sidebar lists no pins. A Pinned
    /// section repeated pages that already had a module row and a tab. The
    /// pins themselves are the floating bar's, untouched.
    /// The captain's mockup: Calendar is its own row in Work, right after
    /// Tasks and before Crew, and it is the one route to the calendar - Tasks
    /// has no Calendar tab left to be a second one.
    private static func checkTheCalendarRow(_ ok: inout Bool) {
        let work = WorkspaceSidebarModel.modules(in: .work)
        if let tasks = work.firstIndex(of: .tasks), let calendar = work.firstIndex(of: .calendar),
           let crew = work.firstIndex(of: .crew) {
            check(calendar == tasks + 1 && crew == calendar + 1,
                  "Work lists \(work.map(\.rawValue)), want Calendar between Tasks and Crew", &ok)
        } else {
            fail("Work lists \(work.map(\.rawValue)), with no Calendar row", &ok)
        }
        // The tree the outline view draws, not only the model's list.
        let workNode = WorkspaceSidebarModel.roots(sessions: []).first { $0.entry == .section(WorkspaceGroup.work.title) }
        check(workNode?.children.prefix(3).map(\.entry) == [.module(.tasks), .module(.calendar), .module(.crew)],
              "the sidebar's Work rows start \(workNode?.children.prefix(3).map(\.entry) ?? [])", &ok)

        // Routing: the row opens the Calendar page, on its Month view, and
        // that page belongs to the row.
        check(WorkspaceModule.calendar.primaryRoute == .calendar,
              "the Calendar row opens \(WorkspaceModule.calendar.primaryRoute.rawValue)", &ok)
        check(ModuleTable.module(for: .calendar) == .calendar, "the Calendar page lights the \(ModuleTable.module(for: .calendar)) row", &ok)
        check(ModuleTable.tab(for: .calendar, pageTab: nil)?.name == "Month",
              "the Calendar page stands for \(ModuleTable.tab(for: .calendar, pageTab: nil)?.name ?? "no tab")", &ok)
        check(RailDestination.calendar.slot == .calendar, "the Calendar has no slot of its own", &ok)
        check(ContextualNewAction.forDestination(.calendar) == .task, "⌘N on the Calendar should make a task", &ok)
        check(WorkspaceToolbar.calendarSymbol == RailDestination.calendar.symbol,
              "the toolbar's calendar button and the Calendar row draw different glyphs", &ok)
        check(RailDestination.calendar.symbol != RailDestination.schedules.symbol,
              "Calendar and Schedules share a sidebar glyph", &ok)

        // One route: no tab anywhere else is called Calendar.
        let stray = WorkspaceModule.allCases.filter { $0 != .calendar }.flatMap(\.tabs).filter { $0.name == "Calendar" }
        check(stray.isEmpty, "\(stray.map { "\($0.module.title) › \($0.name)" }) is a second route to the calendar", &ok)

        // The Go menu is the sidebar's map, and the chords follow the rows.
        let entries = WorkspaceGoMenu.entries()
        if let tasks = entries.firstIndex(of: .module(.tasks)), let calendar = entries.firstIndex(of: .module(.calendar)) {
            let between = entries[(tasks + 1)..<calendar]
            check(between.allSatisfy { if case .tab(let tab) = $0 { return tab.module == .tasks } else { return false } },
                  "the Go menu puts \(between) between Tasks and Calendar", &ok)
        } else {
            fail("the Go menu has no Calendar row", &ok)
        }
        // The Calendar takes no number, so the chords the captain already
        // knows stay put: Crew keeps ⌘3 and Logs keeps ⌘9.
        check(WorkspaceGoMenu.chord(for: .calendar) == nil && WorkspaceGoMenu.chord(for: .crew) == 3
                && WorkspaceGoMenu.chord(for: .logs) == 9,
              "Calendar takes ⌘\(WorkspaceGoMenu.chord(for: .calendar) ?? 0), Crew ⌘\(WorkspaceGoMenu.chord(for: .crew) ?? 0) "
              + "and Logs ⌘\(WorkspaceGoMenu.chord(for: .logs) ?? 0)", &ok)
    }

    /// A captain who has customised the sidebar - hidden modules of their own,
    /// or a profile's starting set - still gets the new Calendar row. The set
    /// is stored as the modules to *hide*, so a module the stored list has
    /// never heard of is shown; this pins that, against the obvious-looking
    /// rewrite to a list of modules to show, which would silently drop every
    /// new module from every existing install.
    private static func checkSavedSidebarsGetTheCalendar(_ ok: inout Bool) {
        let defaults = AppDefaults.store
        let key = "fm.hiddenModules"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        // As an install from before the Calendar row wrote it: two modules
        // hidden, and one id this build no longer knows.
        defaults.set(["crew", "logs", "today"], forKey: key)
        let hidden = AppSettings.shared.hiddenModules
        check(hidden == [.crew, .logs], "a saved hidden set read back as \(hidden.map(\.rawValue).sorted())", &ok)
        let work = WorkspaceSidebarModel.modules(in: .work, hidden: hidden)
        check(work.prefix(2) == [.tasks, .calendar] && !work.contains(.crew),
              "a customised sidebar's Work lists \(work.map(\.rawValue)), want Calendar after Tasks", &ok)
        check(WorkspaceGoMenu.entries(hidden: hidden).contains(.module(.calendar)),
              "a customised sidebar's Go menu has no Calendar", &ok)
        check(WorkspaceGoMenu.chord(for: .calendar, hidden: hidden) == nil
                && WorkspaceGoMenu.chord(for: .connections, hidden: hidden) == 3,
              "with Crew hidden its ⌘3 should pass to Connections, not the Calendar", &ok)

        // Even Tasks hidden leaves Calendar where the captain can find it.
        defaults.set(["tasks"], forKey: key)
        check(WorkspaceSidebarModel.modules(in: .work, hidden: AppSettings.shared.hiddenModules).first == .calendar,
              "hiding Tasks hid the Calendar too", &ok)

        // Both profiles' starting sets show it, so a profile still matches
        // the set it wrote before the row existed.
        for profile in WorkspaceProfile.allCases {
            check(!profile.hiddenModules.contains(.calendar), "the \(profile.title) profile hides the Calendar", &ok)
            defaults.set(profile.hiddenModules.map(\.rawValue).sorted(), forKey: key)
            check(WorkspaceProfile.matching(AppSettings.shared.hiddenModules) == profile,
                  "a saved \(profile.title) set no longer reads as \(profile.title)", &ok)
        }
        check(WorkspaceModule.calendar.canBeHidden, "the Calendar row cannot be hidden in Settings", &ok)
    }

    private static func checkTheSidebarDrawsNoPins(_ ok: inout Bool) {
        // Every top-level row is Home or one of the four groups - there is
        // nowhere for a pin to go.
        let roots = WorkspaceSidebarModel.roots(sessions: [])
        let groups = Set(WorkspaceGroup.allCases.map(\.title))
        let strays = roots.dropFirst().filter { node in
            if case .section(let title) = node.entry { return !groups.contains(title) }
            return true
        }
        check(roots.first?.entry == .module(.home) && strays.isEmpty && roots.count == 1 + groups.count,
              "the sidebar's top level is \(roots.map(\.entry)), want Home and the four groups only", &ok)
        // Source guards, because a model check cannot see the context menu
        // or the wiring: no Pinned section, no Pin or Unpin verb, and the
        // sidebar shell no longer edits the quick-access list.
        guard let sidebar = code("WorkspaceSidebar.swift"), let shell = code("MainSplitShellController.swift"),
              let base = code("WorkspaceShellController.swift") else {
            fail("could not read the sidebar's sources - the guard would pass vacuously", &ok)
            return
        }
        for token in ["\"Pinned\"", "case pinned", "Pin \\(", "Unpin \\(", "onTogglePin", "quickAccess"] {
            check(!sidebar.contains(token), "WorkspaceSidebar.swift draws or edits pins again (`\(token)`)", &ok)
        }
        for token in ["toggleQuickAccessPin", "isQuickAccessPinned", "quickAccessDidChange"] {
            check(!shell.contains(token), "the sidebar shell edits or follows the quick-access pins again (`\(token)`)", &ok)
        }
        // The pins are still the floating bar's to edit.
        check(base.contains("func toggleQuickAccessPin(") && code("main.swift")?.contains("appShell.toggleQuickAccessPin(") == true,
              "the floating bar's ⌘⇧D map can no longer pin a page - the pins were the floating bar's to keep", &ok)
    }

    private static func checkSessionsAreConsoleChildren(_ ok: inout Bool) {
        let first = HostSession(hostID: UUID(), label: "DEV Bastion", accentHex: nil, startedAt: Date(), state: .connected)
        let second = HostSession(hostID: UUID(), label: "PROD Web", accentHex: nil, startedAt: Date(), state: .restored)
        let roots = WorkspaceSidebarModel.roots(sessions: [first, second])
        let nodes = roots.flatMap { [$0] + $0.children }
        let consoles = nodes.filter { $0.entry == .module(.console) }
        check(consoles.count == 1, "Console appears \(consoles.count) times in the groups", &ok)
        check(consoles.first?.children.map(\.entry) == [.session(hostID: first.hostID), .session(hostID: second.hostID)],
              "the sessions are not Console's children, in the registry's order", &ok)
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
        settings.workspaceLayout = .floatingBar
        check(settings.workspaceLayout == .floatingBar, "the floating bar layout did not persist", &ok)
        settings.workspaceLayout = .sidebar
        check(settings.workspaceLayout == .sidebar, "the sidebar layout did not persist", &ok)
        defaults.set("a-layout-from-the-future", forKey: "fm.workspaceLayout")
        check(settings.workspaceLayout == .sidebar, "an unknown layout did not fall back to the sidebar", &ok)
        check(WorkspaceLayout.floatingBar.shellType == AppShellController.self
                && WorkspaceLayout.sidebar.shellType == MainSplitShellController.self,
              "a layout builds the wrong shell", &ok)
        check(WorkspaceLayout.allCases == [.floatingBar, .sidebar],
              "Settings no longer offers both layouts: \(WorkspaceLayout.allCases.map(\.rawValue))", &ok)
    }

    /// The captain's call: the sidebar is the default, and the floating bar
    /// stays a real choice. Three stores, each its own scratch domain, so a
    /// case cannot see what the one before it wrote: one that never chose,
    /// one that chose the sidebar, and one that chose the floating bar - the
    /// last is the captain who must not be moved by this change.
    private static func checkTheDefaultIsTheSidebar(_ ok: inout Bool) {
        check(WorkspaceLayout.standard == .sidebar, "the default layout is \(WorkspaceLayout.standard.rawValue), not the sidebar", &ok)
        check(WorkspaceLayout.standard.shellType == MainSplitShellController.self,
              "a first launch would not build the sidebar shell", &ok)
        for (stored, want) in [(nil, WorkspaceLayout.sidebar), ("sidebar", .sidebar), ("floatingBar", .floatingBar)] {
            let suite = "split-shell-default-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                fail("could not open a scratch defaults domain", &ok)
                return
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            if let stored { defaults.set(stored, forKey: "fm.workspaceLayout") }
            // The domain really holds what the case says it does, so a fresh
            // case cannot pass on a value something else left behind.
            check(defaults.string(forKey: "fm.workspaceLayout") == stored,
                  "the scratch store for \(stored ?? "a fresh store") holds \(defaults.string(forKey: "fm.workspaceLayout") ?? "nothing")", &ok)
            let read = AppSettings(defaults: defaults).workspaceLayout
            check(read == want, "\(stored.map { "a stored \($0) choice" } ?? "a fresh store") opens \(read.rawValue), want \(want.rawValue)", &ok)
            // Reading never writes, so a captain who never chose keeps
            // following the default rather than being pinned to today's.
            check(defaults.string(forKey: "fm.workspaceLayout") == stored,
                  "reading the layout wrote \(defaults.string(forKey: "fm.workspaceLayout") ?? "nothing") into \(stored ?? "a fresh store")", &ok)
        }
    }

    /// The default has one spelling. `AppSettings` falls back to
    /// `WorkspaceLayout.standard`, the tour lab falls back to the setting,
    /// and nothing else in the app names a fallback layout of its own - a
    /// second literal is how a launch, a tour and Settings would disagree
    /// about what a first launch looks like.
    private static func checkTheDefaultIsSpelledOnce(_ ok: inout Bool) {
        guard let settings = code("AppSettings.swift"), let dir = SelfTestSources.appSourceDirectory(),
              let tourText = try? String(contentsOf: dir.appendingPathComponent("SelfTests/ReviewTourLab.swift"), encoding: .utf8) else {
            fail("could not read the sources this check reads - it would pass vacuously", &ok)
            return
        }
        let tour = FeatureInventorySelfTest.stripComments(tourText)
        check(settings.contains("flatMap(WorkspaceLayout.init(rawValue:)) ?? .standard"),
              "AppSettings.workspaceLayout no longer falls back to WorkspaceLayout.standard", &ok)
        check(tour.contains("let layout = AppSettings.shared.workspaceLayout"),
              "the tour lab no longer mounts the layout setting, so a tour's first launch can differ from the app's", &ok)
        let sources = FeatureInventorySelfTest.appSources() + [("ReviewTourLab", tour)]
        check(sources.count > 100, "only \(sources.count) sources were read - the scan would pass vacuously", &ok)
        for (file, text) in sources {
            for literal in ["?? .floatingBar", "?? .sidebar", "?? WorkspaceLayout.floatingBar", "?? WorkspaceLayout.sidebar"]
            where text.contains(literal) {
                fail("\(file).swift falls back to a layout of its own (`\(literal)`) rather than WorkspaceLayout.standard", &ok)
            }
        }
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
        // The captain's ask: a calendar button right after the bell.
        check(ids.firstIndex(of: WorkspaceToolbar.ItemID.calendar) == bell + 1,
              "the calendar button does not follow the notifications button: \(ids.map(\.rawValue))", &ok)
        check(WorkspaceToolbar.customizableItems.contains(WorkspaceToolbar.ItemID.calendar),
              "the calendar button cannot be moved or removed in Customize Toolbar", &ok)
        check(ids.first == WorkspaceToolbar.ItemID.sidebar && ids.contains(.sidebarTrackingSeparator),
              "the sidebar button no longer sits over the sidebar", &ok)
        // R2-ARCH-06: customisable, and still never autosaved by AppKit -
        // the toolbar saves its own items to `AppSettings`, which is
        // `AppDefaults.store`. `MainSplitShellSelfTest
        // .checkTheToolbarIsCustomisable` drives the round trip.
        check(!toolbar.toolbar.autosavesConfiguration,
              "the toolbar autosaves its configuration, which writes UserDefaults.standard outside AppDefaults.store", &ok)
        check(toolbar.toolbar.allowsUserCustomization,
              "R2-ARCH-06: the sidebar layout's toolbar is not customisable", &ok)
    }

    // MARK: 5 - no status strip

    /// The captain: "Yes have this removed everywhere". A source guard,
    /// because the strip could come back on one module only, which a
    /// behaviour check on a sample of modules would miss; the window-backed
    /// half (`MainSplitShellSelfTest.checkTheContentReachesTheFoot`) measures
    /// every module.
    private static func checkTheLayoutDrawsNoStatusStrip(_ ok: inout Bool) {
        guard let files = SelfTestSources.appSourceFiles(), files.count > 100,
              let shell = code("MainSplitShellController.swift") else {
            fail("could not read the app's sources - the guard would pass vacuously", &ok)
            return
        }
        let strip = ["WorkspaceStatusLine", "WorkspaceStatusReadout", "WorkspaceStatusItem", "func statusItems(",
                     "setStatusLineVisible", "showsStatusLine"]
        for file in files {
            guard let text = code(file.lastPathComponent) else { continue }
            for token in strip where text.contains(token) {
                fail("\(file.lastPathComponent) draws the sidebar layout's status strip again (`\(token)`)", &ok)
            }
        }
        // The pane's body ends at the pane's foot, and nothing else is laid
        // out under it.
        for tie in ["body.bottomAnchor.constraint(equalTo: root.bottomAnchor)"] {
            check(shell.contains(tie), "the content pane no longer runs its content to its foot (`\(tie)`)", &ok)
        }
        check(!FeatureInventorySelfTest.shellPlaces.contains("Status line"),
              "the inventory still offers the status line as a place a feature can live", &ok)

        // The focus timer's chip is the toolbar's. When the toolbar runs out
        // of room it yields to the page's own actions, whose overflow form
        // does nothing, and keeps a menu form that opens its popover.
        let toolbar = WorkspaceToolbar(splitView: NSSplitView())
        // R2-ARCH-06: the chip is one of the items the toolbar places itself,
        // so it is not in the customisation palette; it still builds.
        check(WorkspaceToolbar.dynamicItems.contains(WorkspaceToolbar.ItemID.focusTimer)
                && !toolbar.toolbarAllowedItemIdentifiers(toolbar.toolbar).contains(WorkspaceToolbar.ItemID.focusTimer),
              "the focus timer's chip is not one of the toolbar's own placed items", &ok)
        let item = toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: WorkspaceToolbar.ItemID.focusTimer,
                                   willBeInsertedIntoToolbar: true)
        let priority = item?.visibilityPriority.rawValue ?? 0
        let moduleAction = toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: WorkspaceToolbar.ItemID.moduleAction,
                                           willBeInsertedIntoToolbar: true)?.visibilityPriority.rawValue ?? 0
        check(item?.view is FocusTimerChip && item?.menuFormRepresentation != nil
                && priority > moduleAction && moduleAction > NSToolbarItem.VisibilityPriority.low.rawValue
                && priority < NSToolbarItem.VisibilityPriority.standard.rawValue,
              "the toolbar's focus item is not the chip, does nothing from the overflow menu, or does not overflow "
                + "after the crumb and the module's action and before the page's actions (chip \(priority), "
                + "module action \(moduleAction))", &ok)
        check(shell.contains("toolbar.setFocusChip(") && shell.contains("toolbar.onFocusChip ="),
              "the sidebar shell no longer puts the running timer in the toolbar", &ok)
        // Not this check's subject, but the same file and the same review:
        // the machine's mouse button is not a divider drag in this window.
        check(!shell.contains("pressedMouseButtons") && shell.contains("Self.isDividerDrag(NSApp?.currentEvent, in: window)"),
              "the sidebar's remembered width follows the machine's mouse button again, not a drag in its window", &ok)
    }
}

#endif
