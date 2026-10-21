// Grand Line - native macOS app.
//
// Step 0 of the modular-shell migration: `ModuleTable` restates six tables as
// one, and this suite asserts it agrees with each of them.
//
// Two sources of truth are tolerable for a few weeks only if a test says they
// agree. Each row of `ModuleTable` is checked against:
//
//   1. `RailDestination` - title and symbol,
//   2. `RailDestination.domainHue` - the hue,
//   3. `DestinationRegistry` - the body slot and the drill subtitle,
//   4. the `register(...)` lines in `Workspace.registerDestinations` - the
//      eager-mount flag, read from the source because the workspace cannot
//      be built headless,
//   5. `DaylightModule` - the space, and the Home cards that open the page,
//   6. `ContextualNewAction` - what ⌘N creates there,
//
// plus the shape of the planned workspace: every destination in exactly one
// row, every module reached by at least one destination, and the eighteen
// sidebar items in the groups the captain's prototype draws.
//
// Pure logic, no window.
//
// Run with:
//   swift build && FM_RUN_MODULE_TABLE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ModuleTableSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkEveryDestinationHasOneRow, checkRowsAgreeWithTheOldTables,
                      checkEagerMountsAgreeWithTheShell, checkWorkspaceShape,
                      checkChildrenAreReal] {
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

    private static func checkRowsAgreeWithTheOldTables(_ ok: inout Bool) {
        for row in ModuleTable.rows {
            let route = row.route
            let name = route.rawValue
            check(row.title == route.title, "\(name): title \"\(row.title)\" but RailDestination says \"\(route.title)\"", &ok)
            check(row.symbol == route.symbol, "\(name): symbol \(row.symbol) but RailDestination says \(route.symbol)", &ok)
            check(row.hue == route.domainHue, "\(name): hue \(row.hue) but domainHue says \(route.domainHue)", &ok)
            check(row.slot == route.slot, "\(name): slot \(row.slot) but DestinationRegistry says \(route.slot)", &ok)
            check(row.subtitle == route.drillSubtitle,
                  "\(name): subtitle \"\(row.subtitle)\" but drillSubtitle says \"\(route.drillSubtitle)\"", &ok)
            let space = DaylightModule.space(forDestination: route)
            check(row.space == space, "\(name): space \(String(describing: row.space)) but DaylightModule says "
                    + String(describing: space), &ok)
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
        }
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

    /// Eighteen sidebar items: Home on its own, then six Work, four Observe,
    /// five Workbench and two Machine - the prototype's Version 2 sidebar,
    /// typed out so a change to the plan is a deliberate edit here too.
    private static func checkWorkspaceShape(_ ok: inout Bool) {
        let expected: [WorkspaceGroup?: [WorkspaceModule]] = [
            nil: [.home],
            .work: [.tasks, .crew, .connections, .console, .knowledge, .secrets],
            .observe: [.kubernetes, .logs, .health, .schedules],
            .workbench: [.tools, .whiteboard, .stickyBoard, .code, .dictation],
            .machine: [.setup, .settings],
        ]
        for (group, modules) in expected {
            let actual = WorkspaceModule.allCases.filter { $0.group == group }
            check(actual == modules, "group \(group?.title ?? "none") holds \(actual) but the plan is \(modules)", &ok)
        }
        check(WorkspaceModule.allCases.count == 18, "the sidebar has \(WorkspaceModule.allCases.count) items, not 18", &ok)
        for module in WorkspaceModule.allCases {
            check(!ModuleTable.routes(in: module).isEmpty, "\(module.title) has no destination moving into it", &ok)
        }
        let titles = WorkspaceModule.allCases.map(\.title)
        check(Set(titles).count == titles.count, "two modules share a title", &ok)
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
    }
}

#endif
