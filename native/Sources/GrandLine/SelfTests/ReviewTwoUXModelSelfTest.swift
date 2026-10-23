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
        checkTheProfiles(&ok)
        checkTheFirstLaunchProfile(&ok)
        checkTheHiddenModulesReachEveryReader(&ok)
        checkTheWelcomeOffersTheProfiles(&ok)
        checkThePlainLanguageCopy(&ok)
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

    // MARK: R2-UX-01 (b) - Personal and Operator

    static let personalModules: [WorkspaceModule] = [.home, .tasks, .knowledge, .secrets, .tools, .whiteboard,
                                                     .stickyBoard, .code, .dictation, .settings]

    /// A scratch settings store, removed after `body`.
    static func withScratchSettings(_ name: String, _ body: (AppSettings) -> Void) {
        let suite = "fm.selftest.review2ux.\(name).\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        body(AppSettings(defaults: defaults))
    }

    private static func checkTheProfiles(_ ok: inout Bool) {
        check(WorkspaceSidebarModel.listedModules(hidden: WorkspaceProfile.personal.hiddenModules) == personalModules,
              "the Personal sidebar is \(WorkspaceSidebarModel.listedModules(hidden: WorkspaceProfile.personal.hiddenModules).map(\.rawValue)), want the review's ten", &ok)
        check(WorkspaceProfile.operator.hiddenModules.isEmpty, "the Operator profile hides something", &ok)
        check(!WorkspaceModule.home.canBeHidden && !WorkspaceModule.settings.canBeHidden,
              "Home or Settings can be hidden - then nothing could bring a module back", &ok)
        check(WorkspaceProfile.matching([]) == .operator && WorkspaceProfile.matching([.logs]) == nil,
              "a hidden set is not matched to its profile, or an edited one is", &ok)
        // A group whose modules are all hidden draws no empty heading.
        let roots = WorkspaceSidebarModel.roots(sessions: [], hidden: WorkspaceProfile.personal.hiddenModules)
        let sections = roots.compactMap { node -> String? in
            if case .section(let title) = node.entry { return title }
            return nil
        }
        check(sections == ["Work", "Workbench", "Machine"], "the Personal sidebar's headings are \(sections)", &ok)
        // The stored set never holds Home or Settings, whatever is written.
        withScratchSettings("hidden") { settings in
            settings.hiddenModules = [.home, .settings, .logs]
            check(settings.hiddenModules == [.logs], "the stored hidden set kept \(settings.hiddenModules.map(\.rawValue))", &ok)
        }
    }

    private static func checkTheFirstLaunchProfile(_ ok: inout Bool) {
        withScratchSettings("fresh") { settings in
            settings.settleFirstLaunch(isExistingInstall: false)
            check(settings.workspaceProfile == .personal && settings.hiddenModules == WorkspaceProfile.personal.hiddenModules,
                  "a fresh install started on \(String(describing: settings.workspaceProfile)), want Personal", &ok)
            check(settings.homeCardLayout == .standard(for: .personal),
                  "a fresh Personal install's Home does not lead with its own cards", &ok)
        }
        withScratchSettings("existing") { settings in
            settings.settleFirstLaunch(isExistingInstall: true)
            check(settings.workspaceProfile == .operator && settings.hiddenModules.isEmpty,
                  "an existing install lost modules at launch: \(settings.hiddenModules.map(\.rawValue))", &ok)
            check(settings.homeCardLayout == .standard, "an existing install's Home changed its default cards", &ok)
        }
        withScratchSettings("kept") { settings in
            settings.hiddenModules = [.kubernetes]
            settings.setProfile(.operator)
            settings.hiddenModules = [.kubernetes]
            settings.settleFirstLaunch(isExistingInstall: false)
            check(settings.hiddenModules == [.kubernetes], "a later launch replaced the captain's own hidden set", &ok)
        }
        let personal = HomeCardLayout.standard(for: .personal).shown
        let operatorCards: Set<DaylightModule> = [.fleet, .briefing, .mergeQueue, .claudeStatus, .health]
        check(Set(personal).isDisjoint(with: operatorCards),
              "a Personal Home still leads with operator cards: \(personal.filter(operatorCards.contains).map(\.rawValue))", &ok)
    }

    private static func checkTheHiddenModulesReachEveryReader(_ ok: inout Bool) {
        let hidden = WorkspaceProfile.personal.hiddenModules
        // The Go menu.
        let menuModules = WorkspaceGoMenu.entries(hidden: hidden).compactMap { entry -> WorkspaceModule? in
            if case .module(let module) = entry { return module }
            return nil
        }
        check(menuModules == personalModules, "the Personal Go menu lists \(menuModules.map(\.rawValue))", &ok)
        let menu = NSMenu()
        WorkspaceGoMenu.populate(menu, target: nil)
        WorkspaceGoMenu.populate(menu, target: nil, hidden: hidden)
        let rows = menu.items.filter { $0.action == #selector(WorkspaceShellController.selectModuleFromMenu(_:)) }
        check(rows.map(\.title) == personalModules.map(\.title),
              "repopulating the Go menu for a hidden set left \(rows.map(\.title))", &ok)
        // The palette.
        var provider = UnifiedSearchActionProvider(actions: [
            .init(title: "Switch to Kubernetes", meta: "Destination", keywords: [], destination: .kubernetes, run: {}),
            .init(title: "Switch to Notebook", meta: "Destination", keywords: [], destination: .notebook, run: {}),
            .init(title: "New Task…", meta: "Tasks", keywords: [], run: {}),
        ])
        provider.isHidden = { hidden.contains(ModuleTable.module(for: $0)) }
        let titles = provider.items(query: "").map(\.title)
        check(titles == ["Switch to Notebook", "New Task…"], "the palette with Kubernetes hidden lists \(titles)", &ok)
        // The launch landing, and the shell's answer (source guards: both
        // need a whole workspace to drive).
        if let workspace = source("Workspace.swift") {
            check(workspace.contains("AppSettings.shared.hiddenModules.contains(.setup)"),
                  "the launch landing no longer skips a hidden Setup (GL-31 would open a Personal install on Setup)", &ok)
        }
        if let shell = source("MainSplitShellController.swift") {
            check(shell.contains("AppSettings.shared.hiddenModules.contains(ModuleTable.module(for: destination))"),
                  "the sidebar shell no longer tells the palette which pages are hidden", &ok)
        }
        if let palette = source("UnifiedSearchProviders.swift") {
            check(palette.contains("provider.isHidden = { [weak shell] destination in shell?.hidesPage(destination)"),
                  "the palette's destinations no longer ask the shell what is hidden", &ok)
        }
    }

    private static func checkTheWelcomeOffersTheProfiles(_ ok: inout Bool) {
        let saved = PlaceName.layout
        defer { PlaceName.layout = saved }
        PlaceName.layout = .sidebar
        let savedHidden = AppSettings.shared.hiddenModules
        defer { AppSettings.shared.hiddenModules = savedHidden }
        let sheet = WelcomeSheetController()
        sheet.loadView()
        sheet.debugNext()
        check(sheet.debugStepTitle == "How will you use Grand Line?" && !sheet.debugProfileChoiceIsHidden,
              "the welcome sheet's second step is \(sheet.debugStepTitle), not the profile choice", &ok)
        sheet.debugPickProfile(.personal)
        check(AppSettings.shared.hiddenModules == WorkspaceProfile.personal.hiddenModules,
              "picking Personal on the welcome sheet did not hide its modules", &ok)
        sheet.debugPickProfile(.operator)
        check(AppSettings.shared.hiddenModules.isEmpty, "picking Operator on the welcome sheet left modules hidden", &ok)
        PlaceName.layout = .floatingBar
        check(WelcomeSheetController.debugStepCount == 3, "the floating bar's welcome sheet offers a profile it cannot use", &ok)
    }

    // MARK: R2-UX-01 (c) - plain language outside the operator modules

    private static func checkThePlainLanguageCopy(_ ok: inout Bool) {
        check(LockScreenController.greeting(fullName: "Ada Lovelace") == "Welcome back, Ada",
              "the lock screen greets Ada Lovelace as \(LockScreenController.greeting(fullName: "Ada Lovelace"))", &ok)
        check(LockScreenController.greeting(fullName: "") == "Welcome back", "a Mac with no full name gets a broken greeting", &ok)
        // The phrases the review read off the general-user surfaces, which
        // must not come back in their copy. Comments are stripped, so a note
        // naming the old wording does not count.
        let banned: [(file: String, phrase: String)] = [
            ("LockScreenController.swift", "Welcome back, Manjesh\""),
            ("ShiftQuickCapture.swift", "Ask the crew to file it\""),
            ("ShiftQuickCapture.swift", "The crew couldn"),
            ("HomeCanvasController.swift", "let SRE Lead generate one"),
            ("HomeCanvasController.swift", "Generate one from an SRE Lead investigation"),
        ]
        for (file, phrase) in banned {
            guard let text = source(file) else { fail("\(file) was not found", &ok); continue }
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            check(!code.contains { $0.contains(phrase) }, "\(file) still says \"\(phrase)\" to every user", &ok)
        }
        if let home = source("HomeCanvasController.swift") {
            check(home.contains("crew ? fleetAttentionItem() : nil") && home.contains("setup ? sessionChecksAttentionItem() : nil"),
                  "Home's attention card no longer leaves out the fleet and Setup rows for a profile that hides them", &ok)
        }
    }
}

#endif
