// Grand Line - native macOS app.
//
// The second full review's UX findings (R2-UX-01 to R2-UX-09) and the
// captain's three UI items (U-01 to U-03): the pure half.
//
// Each case is one finding's model, menu or source guard - everything that
// needs no window, so it runs in CI's blocking lane. The behaviour that does
// need one (a real toolbar, a real sidebar, real pixels) is
// `ReviewTwoUXSelfTest`, window-backed.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ReviewTwoUXModelSelfTest {

    static func run() -> Bool {
        var ok = true
        checkTheGoMenuIsTheSidebarsMap(&ok)
        checkTheGoMenuPerLayout(&ok)
        checkHomeDrawsNoSpaces(&ok)
        print(ok ? "ReviewTwoUXModelSelfTest: PASS" : "ReviewTwoUXModelSelfTest: FAIL")
        return ok
    }

    // MARK: Shared

    static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// The main menu `AppDelegate` builds for `layout`, in this process's own
    /// defaults domain, with the stored layout put back after.
    static func mainMenu(for layout: WorkspaceLayout) -> NSMenu {
        let stored = AppDefaults.store.string(forKey: "fm.workspaceLayout")
        defer {
            if let stored { AppDefaults.store.set(stored, forKey: "fm.workspaceLayout") } else {
                AppDefaults.store.removeObject(forKey: "fm.workspaceLayout")
            }
        }
        AppSettings.shared.workspaceLayout = layout
        return AppDelegate().buildMenu(installing: false)
    }

    static func goMenu(for layout: WorkspaceLayout) -> NSMenu? {
        mainMenu(for: layout).items.compactMap(\.submenu).first { $0.title == "Go" }
    }

    // MARK: R2-UX-02 - one taxonomy

    /// The model is the sidebar: every module once, in sidebar order, each
    /// under its own group, and each module's toolbar tabs straight after it.
    private static func checkTheGoMenuIsTheSidebarsMap(_ ok: inout Bool) {
        let entries = WorkspaceGoMenu.entries()
        let modules = entries.compactMap { entry -> WorkspaceModule? in
            if case .module(let module) = entry { return module }
            return nil
        }
        check(modules == WorkspaceSidebarModel.listedModules(),
              "the Go menu lists \(modules.map(\.rawValue)), not the sidebar's modules in its order", &ok)
        let groups = entries.compactMap { entry -> String? in
            if case .group(let title) = entry { return title }
            return nil
        }
        check(groups == WorkspaceGroup.allCases.map(\.title), "the Go menu's groups are \(groups), not the sidebar's", &ok)
        var currentModule: WorkspaceModule?
        var tabs: [WorkspaceModule: [String]] = [:]
        var currentGroup: String?
        for entry in entries {
            switch entry {
            case .group(let title): currentGroup = title
            case .module(let module):
                currentModule = module
                check(module.group?.title == currentGroup,
                      "\(module.title) sits under \(currentGroup ?? "no group") in the Go menu, not \(module.group?.title ?? "none")", &ok)
            case .tab(let tab):
                check(tab.module == currentModule, "the \(tab.name) tab is listed under \(currentModule?.title ?? "nothing")", &ok)
                tabs[tab.module, default: []].append(tab.name)
            }
        }
        for module in WorkspaceModule.allCases {
            check((tabs[module] ?? []) == module.tabs.map(\.name),
                  "\(module.title)'s Go menu tabs are \(tabs[module] ?? []), want \(module.tabs.map(\.name))", &ok)
        }
        // A tab survives the round trip through its menu item.
        for module in WorkspaceModule.allCases {
            for tab in module.tabs {
                check(WorkspaceGoMenu.tab(from: WorkspaceGoMenu.representation(of: tab)) == tab,
                      "\(module.title) › \(tab.name) does not come back from its Go menu item", &ok)
            }
        }
    }

    /// The real menu: the sidebar layout's has the module rows and no
    /// spaces, and the floating bar's keeps its spaces.
    private static func checkTheGoMenuPerLayout(_ ok: inout Bool) {
        let spaces = Set(DaylightSpace.allCases.filter { $0 != .overview }.map(\.title))
        guard let sidebar = goMenu(for: .sidebar), let floating = goMenu(for: .floatingBar) else {
            fail("there is no Go menu, so the taxonomy check measures nothing", &ok)
            return
        }
        let sidebarRows = sidebar.items.filter { !$0.isSeparatorItem }
        let moduleRows = sidebarRows.filter { $0.action == #selector(WorkspaceShellController.selectModuleFromMenu(_:)) }
        check(moduleRows.map(\.title) == WorkspaceSidebarModel.listedModules().map(\.title),
              "the sidebar layout's Go menu module rows are \(moduleRows.map(\.title))", &ok)
        let leftovers = sidebarRows.filter { spaces.contains($0.title) || $0.action == #selector(WorkspaceShellController.selectSpaceByShortcut(_:)) }
        check(leftovers.isEmpty, "the sidebar layout's Go menu still lists the spaces: \(leftovers.map(\.title))", &ok)
        let floatingSpaces = floating.items.filter { $0.action == #selector(WorkspaceShellController.selectSpaceByShortcut(_:)) }
        check(floatingSpaces.count == DaylightSpace.allCases.count,
              "the floating bar's Go menu lost its spaces (\(floatingSpaces.count) rows)", &ok)
        check(!floating.items.contains { $0.action == #selector(WorkspaceShellController.selectModuleFromMenu(_:)) },
              "the floating bar's Go menu lists the sidebar's modules", &ok)
    }

    /// Source guard: the sidebar shell hands Home no tabs.
    private static func checkHomeDrawsNoSpaces(_ ok: inout Bool) {
        guard let shell = source("MainSplitShellController.swift") else {
            print("  SKIP MainSplitShellController.swift was not found")
            return
        }
        check(!shell.contains("DaylightSpace.allCases"),
              "the sidebar shell still lays Home's spaces out somewhere (DaylightSpace.allCases)", &ok)
        check(shell.contains("toolbar.setTabs([], selected: nil)"), "the sidebar shell no longer clears Home's tabs", &ok)
    }
}

#endif
