// Grand Line - native macOS app.
//
// `ModuleTable` is where a destination's identity is written down. Step 0 of
// the modular-shell migration restated six tables there and this suite checked
// the restatement against each of them. R2-ARCH-03 made the table the source:
// `RailDestination.title`, `.symbol`, `.domainHue`, `.drillSubtitle`,
// `DaylightModule.space(forDestination:)` and the six facts about a sidebar
// item now read it, and their switches are gone.
//
// A check of the table against values derived from it asserts nothing, so the
// suite asserts three other things now:
//
//   1. the rows agree with what the table does not own - the body slot
//      (`DestinationRegistry`), the eager-mount flag (the `register(...)`
//      lines, read as text because the workspace cannot be built headless),
//      the Home cards that open a page (`DaylightModule.opens`), what ⌘N
//      creates (`ContextualNewAction`), the floating bar's own grouping and
//      its cards' spaces - and every symbol resolves,
//   2. a typed-out fixture pins what every destination and every sidebar item
//      is called, its glyph, hue, line, space, module and tab, so changing
//      one is a deliberate edit in two places (it was captured from the old
//      switches and passed against them before they were deleted),
//   3. the shape of the workspace: every destination in exactly one row,
//      every module reached by at least one destination, and the nineteen
//      sidebar items in the groups the captain's prototype draws, with the
//      Calendar row the captain added after it.
//
// Pure logic, no window.
//
// Run with:
//   swift build && FM_RUN_MODULE_TABLE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ModuleTableSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkEveryDestinationHasOneRow, checkRowsAgreeWithWhatStaysElsewhere,
                      checkEagerMountsAgreeWithTheShell, checkWorkspaceShape,
                      checkChildrenAreReal, checkNoDestinationWasRenamedOrMoved,
                      checkNoModuleWasRenamedOrMoved] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ModuleTableSelfTest: all checks passed" : "ModuleTableSelfTest: FAILED")
        return allOK
    }

    private static func checkEveryDestinationHasOneRow(_ ok: inout Bool) {
        let routes = ModuleTable.rows.map(\.route)
        check(routes.count == RailDestination.allCases.count,
              "ModuleTable has \(routes.count) rows for \(RailDestination.allCases.count) destinations", &ok)
        for destination in RailDestination.allCases {
            let count = routes.filter { $0 == destination }.count
            check(count == 1, "\(destination.rawValue) has \(count) ModuleTable rows, not one", &ok)
        }
        check(routes == RailDestination.allCases,
              "ModuleTable rows are not in RailDestination declaration order", &ok)
    }

    /// What the table does not own, checked against it: the body slot, the
    /// Home cards that open a destination, what ⌘N creates there, and the
    /// floating bar's own grouping. Since R2-ARCH-03 the title, symbol, hue,
    /// line and space are read from the rows themselves, so comparing those
    /// would compare a value with itself; `checkNoDestinationWasRenamedOrMoved`
    /// pins them instead.
    private static func checkRowsAgreeWithWhatStaysElsewhere(_ ok: inout Bool) {
        for row in ModuleTable.rows {
            let route = row.route
            let name = route.rawValue
            check(row.slot == route.slot, "\(name): slot \(row.slot) but DestinationRegistry says \(route.slot)", &ok)
            let cards = DaylightModule.allCases.filter { $0.opens == route }
            check(row.homeCards == cards, "\(name): Home cards \(row.homeCards) but DaylightModule.opens gives \(cards)", &ok)
            let newAction = ContextualNewAction.forDestination(route)
            check(row.newAction == newAction, "\(name): ⌘N \(row.newAction) but ContextualNewAction says \(newAction)", &ok)
            // The Go menu and the ⌘⇧D overlay group a page under its space, or
            // under "Elsewhere" when it has none. The table's space has to put
            // it in the same group.
            let group = AllDestinationsOverlayController.groups().first { $0.destinations.contains(route) }?.title
            check(group == (row.space?.title ?? "Elsewhere"),
                  "\(name): the Go menu groups it under \(group ?? "nothing") but its space is "
                    + (row.space?.title ?? "none"), &ok)
            check(NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) != nil,
                  "\(name)'s symbol \(row.symbol) does not resolve - an invisible icon", &ok)
        }
        // The floating bar's cards keep spaces of their own, for its canvas.
        // A card that sits on a space sits on the space of the page it opens:
        // the two maps cannot disagree about where a page lives.
        for card in DaylightModule.allCases {
            guard let space = card.space else { continue }
            let pageSpace = ModuleTable.descriptor(for: card.opens)?.space
            check(pageSpace == space || pageSpace == nil,
                  "the \(card.rawValue) card sits on \(space.title) but its page \(card.opens.rawValue) on "
                    + (pageSpace?.title ?? "none"), &ok)
        }
        for module in WorkspaceModule.allCases {
            check(ModuleTable.modules.filter { $0.module == module }.count == 1,
                  "\(module.rawValue) has \(ModuleTable.modules.filter { $0.module == module }.count) module rows, not one", &ok)
            check(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) != nil,
                  "the \(module.title) sidebar symbol \(module.symbol) does not resolve", &ok)
        }
        check(ModuleTable.modules.map(\.module) == WorkspaceModule.allCases,
              "ModuleTable.modules is not in WorkspaceModule declaration order", &ok)
    }

    /// The eager-mount flag lives in the `register(...)` lines, and the
    /// workspace that holds them needs a full app to construct, so the lines
    /// are read as text. `Workspace.registerDestinations` since stage 2 of the
    /// migration moved them out of `AppShellController.loadView`.
    private static func checkEagerMountsAgreeWithTheShell(_ ok: inout Bool) {
        guard let shell = FeatureInventorySelfTest.source("Workspace.swift") else {
            fail("could not read Workspace.swift - the eager-mount check cannot run", &ok)
            return
        }
        let pattern = #"register\(DestinationSlot\(id: \.([A-Za-z]+),[^)]*mountsEagerly: (true|false)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = shell as NSString
        var flags: [String: Bool] = [:]
        for match in regex.matches(in: shell, range: NSRange(location: 0, length: ns.length)) {
            flags[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2)) == "true"
        }
        check(flags.count == DestinationSlotID.allCases.count,
              "found \(flags.count) register(...) lines for \(DestinationSlotID.allCases.count) slots", &ok)
        for row in ModuleTable.rows {
            guard let flag = flags[row.slot.rawValue] else {
                fail("\(row.route.rawValue): no register(...) line for slot \(row.slot.rawValue)", &ok)
                continue
            }
            check(flag == row.mountsEagerly, "\(row.route.rawValue): mountsEagerly \(row.mountsEagerly) "
                    + "but the shell registers it \(flag)", &ok)
        }
    }

    /// Nineteen sidebar items: Home on its own, then seven Work, four Observe,
    /// five Workbench and two Machine - the prototype's Version 2 sidebar plus
    /// the Calendar row the captain's later mockup puts after Tasks, typed
    /// out so a change to the plan is a deliberate edit here too.
    private static func checkWorkspaceShape(_ ok: inout Bool) {
        let expected: [WorkspaceGroup?: [WorkspaceModule]] = [
            nil: [.home],
            .work: [.tasks, .calendar, .crew, .connections, .console, .knowledge, .secrets],
            .observe: [.kubernetes, .logs, .health, .schedules],
            .workbench: [.tools, .whiteboard, .stickyBoard, .code, .dictation],
            .machine: [.setup, .settings],
        ]
        for (group, modules) in expected {
            let actual = WorkspaceModule.allCases.filter { $0.group == group }
            check(actual == modules, "group \(group?.title ?? "none") holds \(actual) but the plan is \(modules)", &ok)
        }
        check(WorkspaceModule.allCases.count == 19, "the sidebar has \(WorkspaceModule.allCases.count) items, not 19", &ok)
        for module in WorkspaceModule.allCases {
            check(!ModuleTable.routes(in: module).isEmpty, "\(module.title) has no destination moving into it", &ok)
        }
        let titles = WorkspaceModule.allCases.map(\.title)
        check(Set(titles).count == titles.count, "two modules share a title", &ok)
    }

    // MARK: R2-ARCH-03 - the table is the source, and the identity is pinned

    /// What every destination is called and where it lives, as it was when
    /// R2-ARCH-03 made `ModuleTable.rows` the one source of it. Typed out on
    /// purpose: since the derivation, `RailDestination.title`, `.symbol`,
    /// `.domainHue`, `.drillSubtitle` and `DaylightModule.space(forDestination:)`
    /// read the table, so a check of the table against them would assert
    /// nothing. This fixture is the second copy that makes an edit to the
    /// table deliberate - change a destination's name, glyph, hue, line,
    /// space or home and this fails until the fixture says so too.
    static let pinnedDestinations: [(RailDestination, String, String, HelmDomainHue, String, DaylightSpace?,
                                     WorkspaceModule, String?)] = [
        (.homeCanvas, "Home", "sailboat.fill", .blue, "", nil, .home, nil),
        (.overview, "Fleet", "square.grid.2x2", .blue, "Dispatched crew, decisions and the morning briefing", nil, .crew, "In flight"),
        (.strawHat, "Straw Hat Pirates", "person.3.fill", .violet, "Ask the crew - every write is yours to confirm", .command, .crew, "Ask the crew"),
        (.console, "Console", "terminal", .teal, "Terminals, hosts and the shared Firstmate session", .command, .console, nil),
        (.hosts, "Hosts", "server.rack", .teal, "Saved hosts, SSH keys and snippets", .operations, .connections, "Hosts"),
        (.shift, "Tasks", "checkmark.circle", .rose, "A task board, follow-ups and projects", .command, .tasks, nil),
        (.calendar, "Calendar", "calendar.badge.checkmark", .rose, "Tasks and follow-ups by the day they are due", .command, .calendar, nil),
        (.review, "Review", "arrow.triangle.branch", .green, "Open pull requests, ready to merge", .command, .crew, "Review"),
        (.logAnalyzer, "Log Analyzer", "text.magnifyingglass", .teal, "Collect, analyse and explain captured output", .operations, .logs, nil),
        (.kubernetes, "Kubernetes", "cube.transparent", .teal, "Read-only cluster browsing and multi-pod log tailing", .operations, .kubernetes, nil),
        (.tools, "Tools", "wrench.and.screwdriver", .slate, "Nine offline utilities", .stores, .tools, nil),
        (.whiteboard, "Whiteboard", "scribble.variable", .violet, "An Excalidraw canvas, offline, with AI diagrams", .stores, .whiteboard, nil),
        (.codePreview, "Code Preview", "chevron.left.forwardslash.chevron.right", .blue, "Paste code and read it properly, synced to your config repo", .stores, .code, nil),
        (.stickyBoard, "Sticky Board", "note.text", .amber, "A freeform corkboard of quick sticky notes", .stores, .stickyBoard, nil),
        (.commandLibrary, "DevOps Commands", "books.vertical", .teal, "Your saved shell commands, parameterised and ready to run", .command, .connections, "Commands"),
        (.vault, "Vault", "lock.shield", .violet, "Secret names and tool hardening status from Automic Vault", .stores, .secrets, "Automic Vault"),
        (.dictation, "Dictation", "waveform", .rose, "Speech to text, on this machine", .stores, .dictation, nil),
        (.schedules, "Schedules", "calendar", .violet, "Unattended runs of actions this app already has", .operations, .schedules, nil),
        (.health, "Health", "waveform.path.ecg", .green, "How this app's own background services are doing", .operations, .health, nil),
        (.docs, "Docs", "book.closed", .blue, "The DevOps Playbook, browsable offline", .stores, .knowledge, "Docs"),
        (.notebook, "Notebook", "book.and.wrench", .blue, "Linked markdown pages, in your own config repo", .stores, .knowledge, "Notebook"),
        (.readingList, "Reading List", "bookmark.fill", .green, "Links you saved to read, with titles read on this machine", .stores, .knowledge, "Reading list"),
        (.runbooks, "Runbooks", "list.bullet.rectangle", .blue, "Step-by-step operational procedures", .stores, .knowledge, "Runbooks"),
        (.postmortems, "Postmortems", "doc.text.magnifyingglass", .amber, "Incident write-ups and root causes", .stores, .knowledge, "Postmortems"),
        (.updates, "Updates", "steeringwheel", .amber, "Every tool in the catalog, and what needs updating", .engineering, .setup, "Updates"),
        (.bootstrap, "Bootstrap", "hammer", .amber, "Set this machine up, and see what has drifted", .engineering, .setup, "Setup steps"),
        (.automation, "Automation", "bolt.fill", .amber, "Run every setup step in order, unattended", .engineering, .setup, "Automation"),
        (.githubSync, "GitHub Sync", "arrow.2.squarepath", .amber, "Pull upstream into each of your personal forks", .engineering, .setup, "GitHub sync"),
        (.poneglyph, "Poneglyph", "doc.text.image", .amber, "Your credentials, encrypted and one click from the clipboard", .stores, .secrets, "Poneglyph"),
        (.settings, "Settings", "gearshape", .slate, "Connection, appearance, terminal, security and backup", .engineering, .settings, nil),
    ]

    private static func checkNoDestinationWasRenamedOrMoved(_ ok: inout Bool) {
        check(pinnedDestinations.map(\.0) == RailDestination.allCases,
              "the pinned fixture no longer covers every destination in order", &ok)
        for (route, title, symbol, hue, subtitle, space, module, child) in pinnedDestinations {
            let name = route.rawValue
            check(route.title == title, "\(name) is called \"\(route.title)\", pinned \"\(title)\"", &ok)
            check(route.symbol == symbol, "\(name)'s symbol is \(route.symbol), pinned \(symbol)", &ok)
            check(route.domainHue == hue, "\(name)'s hue is \(route.domainHue), pinned \(hue)", &ok)
            check(route.drillSubtitle == subtitle, "\(name)'s line is \"\(route.drillSubtitle)\", pinned \"\(subtitle)\"", &ok)
            check(DaylightModule.space(forDestination: route) == space,
                  "\(name)'s space is \(String(describing: DaylightModule.space(forDestination: route))), pinned "
                    + String(describing: space), &ok)
            check(ModuleTable.module(for: route) == module, "\(name) lives in \(ModuleTable.module(for: route)), pinned \(module)", &ok)
            check(ModuleTable.descriptor(for: route)?.child == child,
                  "\(name)'s tab is \(ModuleTable.descriptor(for: route)?.child ?? "none"), pinned \(child ?? "none")", &ok)
        }
    }

    /// The same for the nineteen sidebar items: each one's title, group,
    /// children, symbol, the page that draws its own tabs, and whether the
    /// content column opens with its header.
    static let pinnedModules: [(WorkspaceModule, String, WorkspaceGroup?, [String], String, RailDestination?, Bool)] = [
        (.home, "Home", nil, [], "sailboat.fill", nil, true),
        (.tasks, "Tasks", .work, ["Board", "List", "Weekly review"], "checkmark.circle", .shift, true),
        (.calendar, "Calendar", .work, ["Month", "Week", "Day", "Agenda"], "calendar.badge.checkmark", .calendar, false),
        (.crew, "Crew", .work, ["Needs you", "In flight", "Review", "Ask the crew", "Log"], "person.3.fill", .overview, true),
        (.connections, "Connections", .work, ["Hosts", "Keys", "Snippets", "Commands"], "server.rack", .hosts, false),
        (.console, "Console", .work, [], "terminal", nil, false),
        (.knowledge, "Knowledge", .work, ["Notebook", "Runbooks", "Postmortems", "Docs", "Reading list"], "books.vertical", nil, true),
        (.secrets, "Secrets", .work, ["Poneglyph", "Automic Vault"], "key.fill", nil, true),
        (.kubernetes, "Kubernetes", .observe, ["Cluster", "Log Tail"], "cube.transparent", .kubernetes, true),
        (.logs, "Logs", .observe, [], "text.magnifyingglass", nil, true),
        (.health, "Health", .observe, [], "waveform.path.ecg", nil, true),
        (.schedules, "Schedules", .observe, [], "calendar", nil, true),
        (.tools, "Tools", .workbench, [], "wrench.and.screwdriver", nil, true),
        (.whiteboard, "Whiteboard", .workbench, [], "scribble.variable", nil, true),
        (.stickyBoard, "Sticky Board", .workbench, [], "note.text", nil, true),
        (.code, "Code", .workbench, [], "chevron.left.forwardslash.chevron.right", nil, true),
        (.dictation, "Dictation", .workbench, [], "waveform", nil, true),
        (.setup, "Setup", .machine, ["Updates", "Setup steps", "Automation", "GitHub sync"], "hammer", nil, true),
        (.settings, "Settings", .machine, SettingsController.Category.allCases.map(\.title), "gearshape", nil, true),
    ]

    private static func checkNoModuleWasRenamedOrMoved(_ ok: inout Bool) {
        check(pinnedModules.map(\.0) == WorkspaceModule.allCases,
              "the pinned fixture no longer covers every sidebar item in order", &ok)
        for (module, title, group, children, symbol, host, header) in pinnedModules {
            let name = module.rawValue
            check(module.title == title, "\(name) is called \"\(module.title)\", pinned \"\(title)\"", &ok)
            check(module.group == group, "\(name) sits in \(String(describing: module.group)), pinned \(String(describing: group))", &ok)
            check(module.children == children, "\(name)'s children are \(module.children), pinned \(children)", &ok)
            check(module.symbol == symbol, "\(name)'s symbol is \(module.symbol), pinned \(symbol)", &ok)
            check(module.pageTabHost == host, "\(name)'s tab host is \(String(describing: module.pageTabHost)), pinned \(String(describing: host))", &ok)
            check(module.showsHeader == header, "\(name) showsHeader \(module.showsHeader), pinned \(header)", &ok)
        }
    }

    /// A row's `child` must be one of its module's declared children, and two
    /// destinations must not claim the same tab.
    private static func checkChildrenAreReal(_ ok: inout Bool) {
        var claimed: [String: RailDestination] = [:]
        for row in ModuleTable.rows {
            guard let child = row.child else {
                check(ModuleTable.rows.filter { $0.module == row.module && $0.child == nil }.count == 1,
                      "\(row.module.title) has more than one destination claiming its whole page", &ok)
                continue
            }
            check(row.module.children.contains(child),
                  "\(row.route.rawValue) moves to \(row.module.title) › \(child), which is not one of its children", &ok)
            let key = "\(row.module.rawValue)/\(child)"
            if let other = claimed[key] {
                fail("\(row.route.rawValue) and \(other.rawValue) both claim \(row.module.title) › \(child)", &ok)
            }
            claimed[key] = row.route
        }
        // The captain's call during stage 3: the prototype's Playbook tab is
        // named Docs, because it is the Docs page.
        let knowledge = WorkspaceModule.knowledge.children
        check(knowledge == ["Notebook", "Runbooks", "Postmortems", "Docs", "Reading list"],
              "Knowledge's tabs are \(knowledge), want Notebook, Runbooks, Postmortems, Docs, Reading list", &ok)
        check(ModuleTable.descriptor(for: .docs)?.child == "Docs",
              "the Docs page moves to Knowledge › \(ModuleTable.descriptor(for: .docs)?.child ?? "-"), not Knowledge › Docs", &ok)
    }
}

#endif
