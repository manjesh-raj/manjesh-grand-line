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
        checkTheGoMenuListsTheModules(&ok)
        checkHomeDrawsNoSpaces(&ok)
        checkHomeHasNoSpaces(&ok)
        checkTheProfiles(&ok)
        checkTheFirstLaunchProfile(&ok)
        checkTheHiddenModulesReachEveryReader(&ok)
        checkTheWelcomeOffersTheProfiles(&ok)
        checkThePlainLanguageCopy(&ok)
        checkTheModuleChords(&ok)
        checkTheSidebarChordIsOneThing(&ok)
        checkTheToolbarEnforcesOneFilledButton(&ok)
        checkHistoryWalksAPagesPlaces(&ok)
        checkTheLockThresholds(&ok)
        checkTheRelaunchHelper(&ok)
        print(ok ? "ReviewTwoUXModelSelfTest: PASS" : "ReviewTwoUXModelSelfTest: FAIL")
        return ok
    }

    // MARK: Shared

    static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// The main menu `AppDelegate` builds, without installing it.
    static func mainMenu() -> NSMenu {
        AppDelegate().buildMenu(installing: false)
    }

    static func goMenu() -> NSMenu? {
        mainMenu().items.compactMap(\.submenu).first { $0.title == "Go" }
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
        // A tab a door row opens is that row's item, not a second one under
        // its module: Tasks' Calendar view is the Calendar row (⌘0).
        for module in WorkspaceModule.allCases {
            let want = module.tabs.filter { ModuleTable.sidebarModule(for: $0.route, pageTab: $0.name) == module }.map(\.name)
            check((tabs[module] ?? []) == want,
                  "\(module.title)'s Go menu tabs are \(tabs[module] ?? []), want \(want)", &ok)
        }
        // A tab survives the round trip through its menu item.
        for module in WorkspaceModule.allCases {
            for tab in module.tabs {
                check(WorkspaceGoMenu.tab(from: WorkspaceGoMenu.representation(of: tab)) == tab,
                      "\(module.title) › \(tab.name) does not come back from its Go menu item", &ok)
            }
        }
    }

    /// The real menu has the sidebar's module rows and none of the floating
    /// bar's spaces, which P-03 of the 2026-11-25 review removed.
    private static func checkTheGoMenuListsTheModules(_ ok: inout Bool) {
        let spaces = Set(DaylightSpace.allCases.filter { $0 != .overview }.map(\.title))
        guard let sidebar = goMenu() else {
            fail("there is no Go menu, so the taxonomy check measures nothing", &ok)
            return
        }
        let sidebarRows = sidebar.items.filter { !$0.isSeparatorItem }
        let moduleRows = sidebarRows.filter { $0.action == #selector(WorkspaceShellController.selectModuleFromMenu(_:)) }
        check(moduleRows.map(\.title) == WorkspaceSidebarModel.listedModules(hidden: AppSettings.shared.hiddenModules).map(\.title),
              "the sidebar layout's Go menu module rows are \(moduleRows.map(\.title))", &ok)
        let leftovers = sidebarRows.filter { spaces.contains($0.title) }
        check(leftovers.isEmpty, "the Go menu lists the floating bar's spaces again: \(leftovers.map(\.title))", &ok)
    }

    /// R2-ARCH-01: Home does not read the floating bar's spaces - its
    /// Customize menu files each card under the sidebar group of the module
    /// it opens. P-03 of the 2026-11-25 review removed the floating bar
    /// itself; `SettingsLayoutChoiceSelfTest` guards that the choice is gone.
    private static func checkHomeHasNoSpaces(_ ok: inout Bool) {
        // Home's Customize menu, with every card hidden so every card is offered.
        let tray = HomeCustomizeTray()
        tray.hiddenCards = DaylightModule.allCases
        var header: String?
        var filed: [DaylightModule: String] = [:]
        for item in tray.addMenu().items where !item.isSeparatorItem {
            if !item.isEnabled && item.action == nil { header = item.title; continue }
            if let card = DaylightModule.allCases.first(where: { $0.title == item.title }) { filed[card] = header }
        }
        let headers = Set(filed.values)
        let spaces = Set(DaylightSpace.allCases.filter { $0 != .overview }.map(\.title))
        check(headers.isDisjoint(with: spaces),
              "R2-ARCH-01: Home's Customize menu still files cards under the floating bar's spaces: \(headers.intersection(spaces).sorted())", &ok)
        check(filed.count == DaylightModule.allCases.count,
              "Home's Customize menu offered \(filed.count) of \(DaylightModule.allCases.count) hidden cards", &ok)
        for (card, title) in filed {
            let expected = ModuleTable.module(for: card.opens).group?.title ?? "Home"
            check(title == expected, "Home's Customize menu files \(card.title) under \(title), not its sidebar group \(expected)", &ok)
        }
        check(source("HomeCardLayout.swift").map { !$0.contains("DaylightSpace") } == true,
              "R2-ARCH-01: the sidebar layout's Home card set reads the floating bar's spaces again", &ok)
        if ok { print("  OK   R2-ARCH-01: Home's Customize uses the sidebar's groups") }
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

    /// The review's ten, plus the Calendar row the captain added after Tasks:
    /// it is Shift's own data, so it is a Personal module like Tasks.
    /// R5-UX-05: Notebook and Reading list are Personal's own rows where
    /// Knowledge's tab bar was.
    static let personalModules: [WorkspaceModule] = [.home, .tasks, .calendar, .notebook, .readingList, .secrets, .tools,
                                                     .whiteboard, .stickyBoard, .code, .dictation, .settings]

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
              "the Personal sidebar is \(WorkspaceSidebarModel.listedModules(hidden: WorkspaceProfile.personal.hiddenModules).map(\.rawValue)), want the review's ten, the Calendar and Knowledge as two rows", &ok)
        // R5-UX-05: the Operator hides only the two door rows, which would
        // repeat Knowledge's tabs - every module is in its sidebar.
        check(WorkspaceProfile.operator.hiddenModules == [.notebook, .readingList],
              "the Operator profile hides \(WorkspaceProfile.operator.hiddenModules.map(\.rawValue))", &ok)
        check(!WorkspaceModule.home.canBeHidden && !WorkspaceModule.settings.canBeHidden,
              "Home or Settings can be hidden - then nothing could bring a module back", &ok)
        check(WorkspaceProfile.matching([.notebook, .readingList]) == .operator && WorkspaceProfile.matching([.logs]) == nil
                && WorkspaceProfile.matching([]) == nil,
              "a hidden set is not matched to its profile, or an edited one is", &ok)
        // A group whose modules are all hidden draws no empty heading.
        let roots = WorkspaceSidebarModel.roots(sessions: [], hidden: WorkspaceProfile.personal.hiddenModules)
        let sections = roots.compactMap { node -> String? in
            if case .section(let title) = node.entry { return title }
            return nil
        }
        // UX-28: Personal's Machine group held only Settings, which is the
        // sidebar's foot now, so the group draws no heading.
        check(sections == ["Work", "Workbench"], "the Personal sidebar's headings are \(sections)", &ok)
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
            check(settings.workspaceProfile == .operator && settings.hiddenModules == WorkspaceProfile.operator.hiddenModules,
                  "an existing install lost modules at launch: \(settings.hiddenModules.map(\.rawValue))", &ok)
            check(settings.homeCardLayout == .standard, "an existing install's Home changed its default cards", &ok)
        }
        withScratchSettings("kept") { settings in
            settings.hiddenModules = [.kubernetes]
            settings.setProfile(.operator)
            settings.hiddenModules = [.kubernetes, .notebook, .readingList]
            settings.settleFirstLaunch(isExistingInstall: false)
            check(settings.hiddenModules == [.kubernetes, .notebook, .readingList],
                  "a later launch replaced the captain's own hidden set", &ok)
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
        provider.isHidden = { ModuleTable.hidesPage($0, hidden: hidden) }
        let titles = provider.items(query: "").map(\.title)
        check(titles == ["Switch to Notebook", "New Task…"], "the palette with Kubernetes hidden lists \(titles)", &ok)
        // R5-UX-05: an Operator hides the Notebook row and keeps Knowledge ›
        // Notebook, so the palette keeps the page; hiding both drops it.
        check(!ModuleTable.hidesPage(.notebook, hidden: WorkspaceProfile.operator.hiddenModules)
                && ModuleTable.hidesPage(.notebook, hidden: [.notebook, .knowledge])
                && ModuleTable.hidesPage(.calendar, hidden: [.calendar])
                && !ModuleTable.hidesPage(.calendar, hidden: [.tasks]),
              "the palette's hidden pages no longer follow their door rows and modules", &ok)
        // The launch landing, and the shell's answer (source guards: both
        // need a whole workspace to drive).
        if let workspace = source("Workspace.swift") {
            check(workspace.contains("AppSettings.shared.hiddenModules.contains(.setup)"),
                  "the launch landing no longer skips a hidden Setup (GL-31 would open a Personal install on Setup)", &ok)
        }
        if let shell = source("MainSplitShellController.swift") {
            check(shell.contains("ModuleTable.hidesPage(destination, hidden: AppSettings.shared.hiddenModules)"),
                  "the sidebar shell no longer tells the palette which pages are hidden", &ok)
        }
        if let palette = source("UnifiedSearchProviders.swift") {
            check(palette.contains("provider.isHidden = { [weak shell] destination in shell?.hidesPage(destination)"),
                  "the palette's destinations no longer ask the shell what is hidden", &ok)
        }
    }

    private static func checkTheWelcomeOffersTheProfiles(_ ok: inout Bool) {
        let savedHidden = AppSettings.shared.hiddenModules
        defer { AppSettings.shared.hiddenModules = savedHidden }
        let sheet = WelcomeSheetController()
        sheet.loadView()
        // R5-UX-01: who the app is for is the first question, not the second.
        check(sheet.debugStepIndex == 0 && sheet.debugStepTitle == "How will you use Grand Line?"
                && !sheet.debugProfileChoiceIsHidden,
              "the welcome sheet's first step is \(sheet.debugStepTitle), not the profile choice", &ok)
        sheet.debugPickProfile(.personal)
        check(AppSettings.shared.hiddenModules == WorkspaceProfile.personal.hiddenModules,
              "picking Personal on the welcome sheet did not hide its modules", &ok)
        sheet.debugPickProfile(.operator)
        check(AppSettings.shared.hiddenModules == WorkspaceProfile.operator.hiddenModules,
              "picking Operator on the welcome sheet hid \(AppSettings.shared.hiddenModules.map(\.rawValue))", &ok)
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
            let read = file == "HomeCanvasController.swift" ? SelfTestSources.homeCanvas(read: source) : source(file)
            guard let text = read else { fail("\(file) was not found", &ok); continue }
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            check(!code.contains { $0.contains(phrase) }, "\(file) still says \"\(phrase)\" to every user", &ok)
        }
        // The guard on Home's attention card leaving out the fleet and Setup
        // rows is gone with the card (P-03); `ReviewTwoUXSelfTest` checks the
        // greeting does the same.
    }

    // MARK: R2-UX-03 - module chords and keyboard parity

    private static func checkTheModuleChords(_ ok: inout Bool) {
        // The first nine sidebar items, in its order, whatever is hidden.
        let numbered = WorkspaceSidebarModel.listedModules().filter { !WorkspaceGoMenu.unnumbered.contains($0) }
        let operatorChords = WorkspaceSidebarModel.listedModules().compactMap { module in
            WorkspaceGoMenu.chord(for: module).map { (module, $0) }
        }
        let digitChords = operatorChords.filter { $0.1 != 0 }
        check(digitChords.map(\.0) == Array(numbered.prefix(9))
                && digitChords.map(\.1) == Array(1...9),
              "the Operator chords are \(operatorChords.map { "\($0.0.rawValue)=\($0.1)" })", &ok)
        // DevOps Hub arrived after the chords were learned and takes none,
        // so the modules under it keep theirs.
        let operatorHidden = WorkspaceProfile.operator.hiddenModules
        let hubChord = WorkspaceGoMenu.chord(for: .devopsHub, hidden: operatorHidden)
        let kubernetesChord = WorkspaceGoMenu.chord(for: .kubernetes, hidden: operatorHidden)
        let logsChord = WorkspaceGoMenu.chord(for: .logs, hidden: operatorHidden)
        check(hubChord == nil && kubernetesChord == 8 && logsChord == 9,
              "DevOps Hub moved a learned chord: it has \(String(describing: hubChord)), Kubernetes "
                + "\(String(describing: kubernetesChord)), Logs \(String(describing: logsChord))", &ok)
        // R4-UX-01: ⌘0 is the Calendar's, and nobody else's.
        check(operatorChords.filter { $0.1 == 0 }.map(\.0) == [.calendar],
              "\u{2318}0 belongs to \(operatorChords.filter { $0.1 == 0 }.map(\.0.rawValue)), want the Calendar alone", &ok)
        let hidden = WorkspaceProfile.personal.hiddenModules
        // The Calendar row takes ⌘0 rather than a place in the count. R5-UX-05
        // gave Personal two rows where Knowledge was one, so Tools is ⌘6 and
        // Code takes the last digit.
        check(WorkspaceGoMenu.chord(for: .notebook, hidden: hidden) == 3 && WorkspaceGoMenu.chord(for: .readingList, hidden: hidden) == 4
                && WorkspaceGoMenu.chord(for: .tools, hidden: hidden) == 6 && WorkspaceGoMenu.chord(for: .code, hidden: hidden) == 9
                && WorkspaceGoMenu.chord(for: .dictation, hidden: hidden) == nil
                && WorkspaceGoMenu.chord(for: .calendar, hidden: hidden) == 0
                && WorkspaceGoMenu.chord(for: .settings, hidden: hidden) == nil && WorkspaceGoMenu.chord(for: .crew, hidden: hidden) == nil,
              "a hidden module does not hand its number to the next one down", &ok)
        // The real menu: every module row in the first nine carries its
        // chord, and Previous and Next Tab are there.
        guard let sidebar = goMenu() else {
            fail("there is no Go menu to read the chords from", &ok)
            return
        }
        let rows = sidebar.items.filter { $0.action == #selector(WorkspaceShellController.selectModuleFromMenu(_:)) }
        // Counted by hand, skipping the rows the count does not number
        // (the Calendar and DevOps Hub, `WorkspaceGoMenu.unnumbered`), so
        // Crew is still ⌘3 and Kubernetes still ⌘8. The Calendar carries ⌘0
        // instead (R4-UX-01), and DevOps Hub carries nothing.
        var number = 1
        for row in rows {
            let isCalendar = row.representedObject as? String == WorkspaceModule.calendar.rawValue
            let isHub = row.representedObject as? String == WorkspaceModule.devopsHub.rawValue
            let skipped = isCalendar || isHub
            let want = isCalendar ? "0" : isHub ? "" : number <= 9 ? "\(number)" : ""
            if !skipped { number += 1 }
            check(row.keyEquivalent == want && (want.isEmpty || row.keyEquivalentModifierMask == [.command]),
                  "the Go menu's \(row.title) row carries \"\(row.keyEquivalent)\", want \u{2318}\(want)", &ok)
        }
        func item(_ menu: NSMenu, _ action: Selector) -> NSMenuItem? { menu.items.first { $0.action == action } }
        let previous = item(sidebar, #selector(WorkspaceShellController.selectPreviousModuleTab(_:)))
        let next = item(sidebar, #selector(WorkspaceShellController.selectNextModuleTab(_:)))
        check(previous?.keyEquivalent == "{" && next?.keyEquivalent == "}"
                && previous?.keyEquivalentModifierMask == [.command] && next?.keyEquivalentModifierMask == [.command],
              "the sidebar layout's Go menu has no \u{2318}\u{21E7}[ / \u{2318}\u{21E7}] tab items", &ok)
        // The palette's module rows say their chords.
        var provider = UnifiedSearchActionProvider(actions: [])
        provider.moduleActions = {
            WorkspaceSidebarModel.listedModules().map { module in
                .init(title: module.title, meta: "Module", keywords: [module.title],
                      hint: WorkspaceGoMenu.chordText(for: module), run: {})
            }
        }
        let tasks = provider.items(query: "Tasks").first { $0.title == "Tasks" }
        check(tasks?.actionHint == "\u{2318}2", "the palette's Tasks row says \(tasks?.actionHint ?? "nothing"), want \u{2318}2", &ok)
        if let shell = source("MainSplitShellController.swift") {
            check(shell.contains("hint: WorkspaceGoMenu.chordText(for: module, hidden: hidden)"),
                  "the sidebar shell's palette rows no longer carry their chords", &ok)
        }
        // Option A, the captain's choice: Console, a host page and Tools keep
        // ⌘1-⌘9 for their own tabs, through the monitor that sees the key
        // before the menu does.
        if let navigator = source("Navigator.swift") {
            check(navigator.contains("case .console: return workspace.console") && navigator.contains("case .tools: return workspace.tools"),
                  "Console or Tools no longer keep their own number chords (option A)", &ok)
        }
    }

    // MARK: R2-UX-09 - ⌥⌘S is the sidebar everywhere

    private static func checkTheSidebarChordIsOneThing(_ ok: inout Bool) {
        guard let sidebar = goMenu() else {
            fail("there is no Go menu to read ⌥⌘S from", &ok)
            return
        }
        let column = sidebar.items.first { $0.action == #selector(WorkspaceShellController.togglePageColumnFromMenu) }
        check(column?.keyEquivalent == "s" && column?.keyEquivalentModifierMask == [.command, .option, .shift],
              "the sidebar layout's page columns have no \u{2325}\u{21E7}\u{2318}S item", &ok)
        if let shell = source("MainSplitShellController.swift"),
           let start = shell.range(of: "override func toggleSidebarFromMenu() {"),
           let end = shell.range(of: "}", range: start.upperBound..<shell.endIndex) {
            let body = shell[start.upperBound..<end.lowerBound]
            check(body.trimmingCharacters(in: .whitespacesAndNewlines) == "toggleWorkspaceSidebar()",
                  "\u{2325}\u{2318}S in the sidebar layout does something other than toggle its sidebar: \(body)", &ok)
        } else {
            fail("the sidebar shell no longer overrides \u{2325}\u{2318}S", &ok)
        }
    }

    // MARK: R2-UX-04 - the toolbar enforces one filled button

    private static func checkTheToolbarEnforcesOneFilledButton(_ ok: inout Bool) {
        let toolbar = WorkspaceToolbar(splitView: NSSplitView())
        let action = HelmButton(title: "Filled page action", variant: .primary)
        let primary = HelmButton(title: "Outlined primary", variant: .secondary)
        toolbar.setPageActions([action])
        toolbar.setPrimaryAction(primary)
        check(action.variant == .secondary, "a page action stays filled in the toolbar", &ok)
        check(primary.variant == .primary, "the far-right primary is drawn outlined", &ok)
    }

    // MARK: R2-UX-08 - Settings housekeeping

    /// The window's Back and Forward walk a page's own places (Settings'
    /// categories), so the page needs no arrows of its own.
    private static func checkHistoryWalksAPagesPlaces(_ ok: inout Bool) {
        var history = NavigationHistory()
        history.arrive(.rail(.shift))
        history.arrive(.rail(.settings))
        history.settlePlace("appearance")
        history.arrive(.rail(.settings), place: "terminal")
        history.arrive(.rail(.settings), place: "security")
        check(history.backEntries.map(\.identityKey) == ["rail:shift", "rail:settings#appearance", "rail:settings#terminal"],
              "three categories after Tasks left Back \(history.backEntries.map(\.identityKey))", &ok)
        // Re-reporting the place that is showing is not a visit.
        history.arrive(.rail(.settings), place: "security")
        history.arrive(.rail(.settings))
        check(history.backEntries.count == 3, "re-reporting the current category pushed it onto Back", &ok)
        // Back within the page.
        history.expect(.back)
        history.arrive(.rail(.settings), place: "terminal")
        history.finishStep(.back, arrived: true)
        check(history.currentEntry?.identityKey == "rail:settings#terminal"
                && history.forwardEntries.map(\.identityKey) == ["rail:settings#security"],
              "Back within Settings left \(history.currentEntry?.identityKey ?? "-"), forward \(history.forwardEntries.map(\.identityKey))", &ok)
        // Back out of the page and Forward into it: the arrival names no
        // place, and the entry keeps the one it was recorded with.
        history.expect(.back)
        history.arrive(.rail(.settings), place: "appearance")
        history.expect(.back)
        history.arrive(.rail(.shift))
        history.expect(.forward)
        history.arrive(.rail(.settings))
        check(history.currentEntry?.identityKey == "rail:settings#appearance",
              "Forward into Settings is \(history.currentEntry?.identityKey ?? "-"), want its first category", &ok)
        // A place named before the shell settled one is that step's place.
        var early = NavigationHistory()
        early.arrive(.rail(.shift))
        early.arrive(.rail(.settings))
        early.arrive(.rail(.settings), place: "backup")
        check(early.backEntries.map(\.identityKey) == ["rail:shift"] && early.currentEntry?.identityKey == "rail:settings#backup",
              "a category named before the shell settled one became a visit: \(early.backEntries.map(\.identityKey))", &ok)
        // A different page still clears Forward.
        history.arrive(.rail(.notebook))
        check(!history.canGoForward, "a new page after Back left Forward offered", &ok)
    }

    /// The lock's thresholds: the captain's choice, clamped to the list's
    /// range, with the environment override still winning.
    private static func checkTheLockThresholds(_ ok: inout Bool) {
        withScratchSettings("lock-thresholds") { settings in
            let none: [String: String] = [:]
            var thresholds = AppLockController.configuredThresholds(settings: settings, environment: none)
            check(thresholds.idle == 3600 && thresholds.session == 12 * 3600,
                  "the defaults are \(thresholds.idle)s and \(thresholds.session)s, want an hour and 12 hours", &ok)
            settings.appLockIdleSeconds = 15 * 60
            settings.appLockSessionSeconds = 4 * 3600
            thresholds = AppLockController.configuredThresholds(settings: settings, environment: none)
            check(thresholds.idle == 15 * 60 && thresholds.session == 4 * 3600,
                  "a stored choice reads back as \(thresholds.idle)s and \(thresholds.session)s", &ok)
            // A hand-edited preference cannot stretch the idle window, or
            // shrink either below the list.
            settings.appLockIdleSeconds = 30 * 24 * 3600
            settings.appLockSessionSeconds = 5
            thresholds = AppLockController.configuredThresholds(settings: settings, environment: none)
            check(thresholds.idle == AppLockController.idleChoices.last && thresholds.session == AppLockController.sessionChoices.first,
                  "out-of-range values read back as \(thresholds.idle)s and \(thresholds.session)s, not clamped", &ok)
            settings.appLockIdleSeconds = .infinity
            check(AppLockController.configuredThresholds(settings: settings, environment: none).idle == AppLockController.idleChoices.first,
                  "an infinite idle time was not refused", &ok)
            let env = [AppLockController.idleOverrideKey: "7", AppLockController.sessionOverrideKey: "11"]
            thresholds = AppLockController.configuredThresholds(settings: settings, environment: env)
            check(thresholds.idle == 7 && thresholds.session == 11, "the environment override lost to the stored choice", &ok)
            check(SettingsController.thresholdDescription("Base.", overrideKey: AppLockController.idleOverrideKey,
                                                          environment: env).contains(AppLockController.idleOverrideKey),
                  "an overridden threshold's row does not say so", &ok)
            check(!SettingsController.thresholdDescription("Base.", overrideKey: AppLockController.idleOverrideKey,
                                                           environment: none).contains("FM_"),
                  "a row with no override still names an environment variable", &ok)
        }
        guard let lock = source("AppLock.swift") else {
            fail("cannot read AppLock.swift, so the threshold guard measures nothing", &ok)
            return
        }
        check(lock.contains("fixedIdleThreshold ?? Self.configuredThresholds().idle"),
              "the live lock no longer reads the configured idle time", &ok)
    }

    /// The relaunch helper, run for real with `open` swapped for `echo`: it
    /// waits for the pid, opens only once that pid is gone, and passes the
    /// path through as one argument.
    private static func checkTheRelaunchHelper(_ ok: inout Bool) {
        let path = "/Applications/Grand \"Line\" $(touch x).app"
        func run(pid: Int32, attempts: Int) -> String {
            var args = AppRelaunch.helperArguments(pid: pid, bundlePath: path, attempts: attempts)
            guard args.count == 5, args[1].contains("/usr/bin/open") else { return "unexpected argv \(args)" }
            args[1] = args[1].replacingOccurrences(of: "/usr/bin/open", with: "/bin/echo")
            return Subprocess.run(executable: "/bin/sh", arguments: args, timeout: 10).stdout
        }
        check(AppRelaunch.helperArguments(pid: 42, bundlePath: path).suffix(2) == ["42", path],
              "the pid and the path are not passed as their own arguments", &ok)
        check(!AppRelaunch.helperArguments(pid: 42, bundlePath: path)[1].contains(path),
              "the bundle path is spliced into the script", &ok)
        // A pid that cannot exist: the wait ends at once and the bundle opens.
        let opened = run(pid: 99_999_999, attempts: 3)
        check(opened == path, "after the app exited the helper opened \(opened), want \(path)", &ok)
        // This process, which is alive: the helper gives up and opens nothing.
        let alive = run(pid: ProcessInfo.processInfo.processIdentifier, attempts: 2)
        check(alive.isEmpty, "the helper opened a second copy while the first was still running: \(alive)", &ok)
    }
}

#endif
