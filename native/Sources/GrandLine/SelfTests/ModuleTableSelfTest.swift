// Grand Line - native macOS app.
//
// UX-01's table guard: the Workspace shell's seventeen modules
// (`WorkspaceModule.swift`) against the thirty routes they replace.
//
// Pure logic - no window, no view - so it runs in CI's blocking lane.
//
// What it holds, and why each one can fail:
//
//   1. **Every route has exactly one owner.** A `RailDestination` added
//      without a module row would be a page nothing in the sidebar reaches,
//      which is UX-01's defect coming back one case at a time. A route listed
//      under two modules would make the sidebar light one item while the
//      toolbar names another.
//   2. **The structure is the decision.** The review's section 4.3 (and the
//      prototype the captain picked) fixes seventeen items in Home plus four
//      headed groups. Restated here as literal data, never derived from the
//      table under test - a check that reads the table it is checking asserts
//      nothing.
//   3. **Chords are unique and are the review's ⌘1-⌘6.**
//   4. **Every symbol resolves**, because an unresolved SF Symbol draws an
//      empty sidebar row with no error.
//   5. **The table agrees with the per-route facts it was derived from**: the
//      ⌘N owner of every creatable thing is reachable, a sub-page names a tab
//      its page really has, and a single-route module keeps its page's title
//      unless the rename is one of the review's deliberate ones.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ModuleTableSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkEveryRouteHasOneOwner, checkStructureIsTheDecision,
                      checkChords, checkSymbolsResolve, checkAgreesWithPerRouteFacts,
                      checkTabLookup] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ModuleTableSelfTest: all checks passed" : "ModuleTableSelfTest: FAILED")
        return allOK
    }

    // MARK: 1 - one owner per route

    private static func checkEveryRouteHasOneOwner(_ ok: inout Bool) {
        var local = true
        for route in RailDestination.allCases {
            let owners = ModuleTable.all.filter { $0.routes.contains(route) }
            check(owners.count == 1,
                  "route .\(route.rawValue) is owned by \(owners.count) modules (\(owners.map(\.title))), expected exactly one",
                  &local)
            if owners.count == 1 {
                check(ModuleTable.owner(of: route)?.id == owners[0].id,
                      "module(for: .\(route.rawValue)) disagrees with the table", &local)
            }
        }
        // Discriminating power: the table really does cover thirty routes, so
        // a shrunken `RailDestination` cannot make the loop above vacuous.
        check(RailDestination.allCases.count >= 30,
              "expected at least 30 routes to consolidate, found \(RailDestination.allCases.count)", &local)
        if local { SelfTestAssertions.reportPass("every one of \(RailDestination.allCases.count) routes has exactly one module") }
        ok = ok && local
    }

    // MARK: 2 - the structure

    /// Section 4.3 of the review, typed out again on purpose.
    private static let decidedStructure: [(WorkspaceSection, [String])] = [
        (.home, ["Home"]),
        (.work, ["Tasks", "Connections", "Crew", "Knowledge", "Secrets"]),
        (.observe, ["Kubernetes", "Logs", "Health", "Schedules"]),
        (.workbench, ["Tools", "Whiteboard", "Sticky Board", "Code", "Dictation"]),
        (.machine, ["Setup", "Settings"]),
    ]

    private static func checkStructureIsTheDecision(_ ok: inout Bool) {
        var local = true
        check(ModuleTable.all.count == 17, "expected 17 modules, found \(ModuleTable.all.count)", &local)
        check(WorkspaceModuleID.allCases.count == ModuleTable.all.count,
              "every module id needs exactly one row", &local)
        check(WorkspaceSection.allCases == decidedStructure.map(\.0), "section order changed", &local)
        for (section, titles) in decidedStructure {
            let actual = ModuleTable.modules(in: section).map(\.title)
            check(actual == titles, "\(section.rawValue): expected \(titles), found \(actual)", &local)
        }
        check(WorkspaceSection.home.title == nil, "Home must sit above the first header, untitled", &local)
        for section in WorkspaceSection.allCases where section != .home {
            check(!(section.title ?? "").isEmpty, "\(section.rawValue) needs a header", &local)
        }
        // The sidebar order is the table order, so the flattened sections must
        // be the table itself.
        let flattened = WorkspaceSection.allCases.flatMap { ModuleTable.modules(in: $0).map(\.id) }
        check(flattened == ModuleTable.all.map(\.id), "table order is not section order", &local)
        if local { SelfTestAssertions.reportPass("17 modules in Home plus four headed groups, as decided") }
        ok = ok && local
    }

    // MARK: 3 - chords

    private static func checkChords(_ ok: inout Bool) {
        var local = true
        let expected: [WorkspaceModuleID: String] = [
            .home: "1", .tasks: "2", .connections: "3", .crew: "4", .knowledge: "5", .secrets: "6",
        ]
        for module in ModuleTable.all {
            if let key = expected[module.id] {
                check(module.chord == WorkspaceChord(key: key, modifiers: .command),
                      "\(module.title) should be ⌘\(key), is \(module.chord?.displayString ?? "none")", &local)
            } else {
                check(module.chord == nil,
                      "\(module.title) carries \(module.chord?.displayString ?? "") - only Home and the Work group get chords",
                      &local)
            }
        }
        let chords = ModuleTable.all.compactMap(\.chord)
        for (index, chord) in chords.enumerated() {
            check(!chords[(index + 1)...].contains(chord), "chord \(chord.displayString) is declared twice", &local)
        }
        check(WorkspaceChord(key: "1", modifiers: .command).displayString == "\u{2318}1",
              "chord display string is wrong", &local)
        if local { SelfTestAssertions.reportPass("⌘1-⌘6 belong to Home and the Work group, once each") }
        ok = ok && local
    }

    // MARK: 4 - symbols

    private static func checkSymbolsResolve(_ ok: inout Bool) {
        var local = true
        for module in ModuleTable.all {
            check(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) != nil,
                  "\(module.title)'s symbol \(module.symbol) does not resolve", &local)
            check(!module.summary.isEmpty, "\(module.title) has no summary", &local)
            check(!module.tabs.isEmpty, "\(module.title) has no tabs", &local)
        }
        if local { SelfTestAssertions.reportPass("every module symbol resolves and every module has a tab") }
        ok = ok && local
    }

    // MARK: 5 - agreement with the per-route facts

    /// The review's deliberate renames of a single-route module: the sidebar
    /// says what a thing is, and the page keeps its own name as the tab.
    private static let deliberateRenames: [WorkspaceModuleID: String] = [
        .logs: "Log Analyzer",
        .code: "Code Preview",
    ]

    private static func checkAgreesWithPerRouteFacts(_ ok: inout Bool) {
        var local = true
        // Every creatable thing ⌘N knows about lands in a module that lists
        // its owning route.
        for action in ContextualNewAction.allCases {
            let route = action.owningDestination
            check(ModuleTable.owner(of: route)?.routes.contains(route) == true,
                  "⌘N's \(action.rawValue) owner .\(route.rawValue) is not a tab of any module", &local)
        }
        // A sub-page names a tab its page really has.
        for module in ModuleTable.all {
            for tab in module.tabs {
                guard let subpage = tab.subpage else { continue }
                switch tab.route {
                case .hosts:
                    check(HostsTab(rawValue: subpage.rawValue) != nil,
                          "\(module.title) tab \(tab.title) names a Hosts sub-page that does not exist (\(subpage.rawValue))",
                          &local)
                default:
                    check(false, "\(module.title) tab \(tab.title) names a sub-page on .\(tab.route.rawValue), which hosts none",
                          &local)
                }
            }
        }
        // A single-route module keeps its page's title.
        for module in ModuleTable.all where module.routes.count == 1 {
            let pageTitle = module.defaultTab.route.title
            if let rename = deliberateRenames[module.id] {
                check(pageTitle == rename, "\(module.title)'s recorded rename (\(rename)) no longer matches its page (\(pageTitle))",
                      &local)
            } else {
                check(module.title == pageTitle, "\(module.title) disagrees with its page's title \(pageTitle)", &local)
            }
        }
        if local { SelfTestAssertions.reportPass("the table agrees with ⌘N's owners, the Hosts sub-pages and the page titles") }
        ok = ok && local
    }

    // MARK: 6 - tab lookup

    private static func checkTabLookup(_ ok: inout Bool) {
        var local = true
        // Every lookup below is guarded by `owner(of:)` first, so a broken
        // table reports here instead of trapping in `module(for:)`.
        guard [RailDestination.hosts, .review].allSatisfy({ ModuleTable.owner(of: $0) != nil }) else {
            check(false, "the tab lookups need .hosts and .review to have owners", &local)
            ok = false
            return
        }
        check(ModuleTable.tab(for: .hosts).subpage == WorkspaceSubpage("hosts"),
              "a bare .hosts route should land on the Hosts tab", &local)
        check(ModuleTable.tab(for: .hosts, subpage: WorkspaceSubpage("keys")).title == "Keys",
              "a keys sub-page should land on the Keys tab", &local)
        check(ModuleTable.tab(for: .review).title == "Merge queue", "Review should land on Merge queue", &local)
        check(ModuleTable.owner(of: .dailyOverview)?.id == .home, "Today belongs to Home", &local)
        check(ModuleTable.owner(of: .vault)?.id == .secrets, "Automic Vault belongs to Secrets", &local)
        check(ModuleTable.owner(of: .githubSync)?.id == .setup, "GitHub Sync belongs to Setup", &local)
        if local { SelfTestAssertions.reportPass("a route and a sub-page resolve to the right tab") }
        ok = ok && local
    }
}

#endif
