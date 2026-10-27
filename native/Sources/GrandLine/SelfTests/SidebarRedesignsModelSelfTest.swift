// Grand Line - native macOS app.
//
// Stage 7 of the modular-shell migration, the half that needs no window: the
// models behind the redesigned pages, and source guards on the wiring a
// behaviour check cannot see. `SidebarRedesignsSelfTest` is the window-backed
// half.
//
//   1. **The sidebar is the system's Large source-list size** (32pt rows,
//      15pt text, 24pt icons), from one table the rows read.
//   2. **Quick Connect is a caption and two separate icons**, Console and
//      Hosts, each its own toolbar item with its own action - never one
//      merged glyph - and the old single action is gone from the shell. The
//      Console icon opens a session only when Console has none (the
//      captain's Option B).
//   3. **Knowledge draws no tree**: nothing declares it, the content pane has
//      no column for it, and Notebook keeps its own page column.
//   4. **Setup's summary cards** say what the readings say, a dash for one
//      not taken (GL-14), and "Paused" only for a confirmed public config
//      repo.
//   5. **The readings the cards come from**: the poller's counts carry their
//      totals, the dotfiles sync says nothing before its first pass, the
//      config repo's last check is kept, and the focus log counts distinct
//      tasks over the chart's days.
//   6. **Tasks keeps every filter its column had**, in the filter row.
//
// Pure logic: no window, so it runs in CI's blocking lane.
//
// Run with:
//   swift build && FM_RUN_SIDEBAR_REDESIGNS_MODEL_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SidebarRedesignsModelSelfTest {

    static func run() -> Bool {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-redesigns-model-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            for check in [checkTheSidebarIsTheLargeSize, checkQuickConnectIsTwoIcons, checkKnowledgeHasNoTree,
                          checkTheSetupSummary, checkTheReadings, checkTheFocusCount, checkTasksKeepsItsFilters,
                          checkTheSetupWiring] {
                var ok = true
                check(&ok)
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "SidebarRedesignsModelSelfTest: all checks passed" : "SidebarRedesignsModelSelfTest: FAILED")
        return allOK
    }

    private static func code(_ file: String) -> String? { FeatureInventorySelfTest.source(file) }

    // MARK: 1 - The sidebar's size

    /// Apple's Human Interface Guidelines, Sidebars: Large is 32pt rows, 24pt
    /// icons and 15pt text. The captain asked for bigger rows (stage 7).
    private static func checkTheSidebarIsTheLargeSize(_ ok: inout Bool) {
        typealias M = WorkspaceSidebarMetrics
        check(M.moduleRowHeight == 32 && M.moduleTextSize == 15 && M.iconSide == 24,
              "the sidebar's rows are \(M.moduleRowHeight)pt, \(M.moduleTextSize)pt text, \(M.iconSide)pt icons - "
                  + "not the Large source-list size", &ok)
        check(M.sessionRowHeight < M.moduleRowHeight && M.sectionTextSize < M.moduleTextSize,
              "a session or a heading is not a step down from a module row", &ok)
        guard let sidebar = code("WorkspaceSidebar.swift") else {
            fail("could not read WorkspaceSidebar.swift - the guard would pass vacuously", &ok)
            return
        }
        // Every size comes from the table, so a literal back in a row is the
        // one way the Medium size could return.
        for literal in ["scaledRowHeight(28)", "scaledRowHeight(26)", "scaledRowHeight(30)", "HelmType.scaled(13))",
                        "HelmType.scaled(18))", "HelmType.scaled(12.5))"] {
            check(!sidebar.contains(literal), "WorkspaceSidebar.swift draws a Medium size again (`\(literal)`)", &ok)
        }
        for use in ["HelmType.scaledRowHeight(M.moduleRowHeight)", "WorkspaceSidebarMetrics.moduleTextSize",
                    "WorkspaceSidebarMetrics.iconSide", "WorkspaceSidebarMetrics.sectionTextSize"] {
            check(sidebar.contains(use), "the sidebar no longer reads `\(use)`", &ok)
        }
    }

    // MARK: 2 - Quick Connect

    private static func checkQuickConnectIsTwoIcons(_ ok: inout Bool) {
        let toolbar = WorkspaceToolbar(splitView: NSSplitView())
        let ids = WorkspaceToolbar.ItemID.quickConnect
        // U-02 took the caption out: Console, then Hosts.
        check(ids == [WorkspaceToolbar.ItemID.quickConnectConsole, WorkspaceToolbar.ItemID.quickConnectHosts],
              "Quick Connect is not Console, then Hosts", &ok)
        // R2-ARCH-06: placed by the toolbar on every module, so they are
        // its own items rather than the customisation palette's.
        check(ids.allSatisfy(WorkspaceToolbar.dynamicItems.contains), "the toolbar cannot show Quick Connect's items", &ok)
        let item = { (id: NSToolbarItem.Identifier) in
            toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true)
        }
        guard let console = item(WorkspaceToolbar.ItemID.quickConnectConsole),
              let hosts = item(WorkspaceToolbar.ItemID.quickConnectHosts) else {
            fail("the toolbar builds no item for one of Quick Connect's two", &ok)
            return
        }
        // Two separate icons: two items, each its own image and its own
        // action - one merged glyph would be one item.
        check(console.image != nil && hosts.image != nil && console !== hosts
                && console.action != nil && hosts.action != nil && console.action != hosts.action,
              "Console and Hosts are not two icons with two actions", &ok)
        check(WorkspaceToolbar.QuickConnectIcon.consoleSymbol != WorkspaceToolbar.QuickConnectIcon.hostsSymbol,
              "Console and Hosts draw the same symbol", &ok)
        // With no caption, each icon's label says what it is - for VoiceOver,
        // and for the overflow menu, which lists an image item by its label.
        check(console.label == "Quick Connect to Console" && hosts.label == "Quick Connect to a Host",
              "the icons are labelled \(console.label) and \(hosts.label)", &ok)
        check(console.toolTip?.hasPrefix("Quick Connect to Console") == true && hosts.toolTip?.hasPrefix("Quick Connect to a host") == true,
              "the icons' tooltips do not say they are Quick Connect: \(console.toolTip ?? "") / \(hosts.toolTip ?? "")", &ok)
        check(console.image?.accessibilityDescription == console.label && hosts.image?.accessibilityDescription == hosts.label,
              "the icons' images are not described for VoiceOver", &ok)
        // U-02: above the module's action and the chip, below the page's own
        // actions, so a narrow window keeps them and still has the page's.
        check(console.visibilityPriority == WorkspaceToolbar.quickConnectPriority
                && hosts.visibilityPriority == WorkspaceToolbar.quickConnectPriority
                && WorkspaceToolbar.quickConnectPriority.rawValue > WorkspaceToolbar.focusChipPriority.rawValue
                && WorkspaceToolbar.quickConnectPriority.rawValue < NSToolbarItem.VisibilityPriority.standard.rawValue,
              "Quick Connect's icons left their overflow band", &ok)

        guard let shell = code("MainSplitShellController.swift") else {
            fail("could not read MainSplitShellController.swift - the guard would pass vacuously", &ok)
            return
        }
        check(!shell.contains("setModuleAction(title: \"Quick Connect\""),
              "the shell draws Quick Connect as one button again", &ok)
        check(shell.contains("toolbar.setQuickConnect(console: !hidden.contains(.console), hosts: !hidden.contains(.connections))"),
              "the shell no longer shows Quick Connect on every module (U-02)", &ok)
        check(shell.contains("toolbar.onQuickConnectHosts = { [weak self] in self?.workspace.navigator.revealHostsQuickConnect() }"),
              "the Hosts icon no longer opens the quick-connect host picker", &ok)
        let consoleBody = shell.range(of: "private func quickConnectConsole()").map {
            FeatureInventorySelfTest.braceBody(shell, from: shell.index(after: shell[$0.upperBound...].firstIndex(of: "{")!))
        } ?? ""
        check(consoleBody.contains("workspace.navigator.show(.console)")
                && consoleBody.contains("workspace.console.focusOrOpenSession()"),
              "the Console icon no longer goes to Console's session", &ok)
        // The captain's Option B: the session Console has, and a new one only
        // when there is none.
        guard let sessions = code("ConsoleController+Sessions.swift"),
              let start = sessions.range(of: "func focusOrOpenSession()"),
              let open = sessions[start.upperBound...].firstIndex(of: "{") else {
            fail("ConsoleController+Sessions.swift has no focusOrOpenSession - the guard would pass vacuously", &ok)
            return
        }
        let body = FeatureInventorySelfTest.braceBody(sessions, from: sessions.index(after: open))
        check(body.contains("guard let tab = currentTab ?? tabs.first else") && body.contains("newShellTab()")
                && body.contains("select(tabID: tab.id)"),
              "the Console icon opens a session when Console already has one - the captain chose Option B", &ok)
    }

    // MARK: 3 - Knowledge

    private static func checkKnowledgeHasNoTree(_ ok: inout Bool) {
        let sources = FeatureInventorySelfTest.appSources()
        guard sources.count > 100, let shell = code("MainSplitShellController.swift"),
              let notebook = code("NotebookController.swift") else {
            fail("could not read the app's sources - the guard would pass vacuously", &ok)
            return
        }
        for (file, text) in sources {
            for token in ["KnowledgeTreeController", "KnowledgeTreePage", "KnowledgeTreeModel", "setLeadingColumn(",
                          "onKnowledgeChanged"] where text.contains(token) {
                fail("\(file).swift brings Knowledge's tree back (`\(token)`)", &ok)
            }
        }
        check(!sources.contains { $0.0 == "KnowledgeTree" }, "KnowledgeTree.swift is back", &ok)
        check(shell.contains("body.leadingAnchor.constraint(equalTo: root.leadingAnchor)") && !shell.contains("columnHost"),
              "the content pane has a column beside the body again", &ok)
        check(!notebook.contains("pageForcesCollapse = true"),
              "Notebook puts its own page column away again - the tree was the reason it did", &ok)
    }

    // MARK: 4 - Setup's summary cards

    private static func checkTheSetupSummary(_ ok: inout Bool) {
        typealias Counts = BackgroundSignalsPoller.SignalCounts
        // Nothing read yet: every figure a dash, with a reason.
        let unknown = SetupSummary.cards(counts: Counts(), steps: .of([:]), dotfiles: nil, configRepo: nil)
        check(unknown.map(\.caption) == SetupSummary.captions && unknown.allSatisfy { $0.text == nil && $0.unknownReason != nil },
              "a summary with no readings draws \(unknown.map { $0.text ?? "-" }), want five dashes", &ok)

        var counts = Counts()
        counts.toolsTotal = 8
        counts.toolsUpToDate = 6
        counts.toolsWithUpdate = 2
        counts.toolUpdates = 2
        counts.setupDrift = 1
        counts.forksTotal = 8
        counts.forksChecked = 8
        counts.forkDrift = 0
        var steps: [SetupStepKind: Bool?] = [:]
        for (index, kind) in SetupStepKind.allCases.enumerated() { steps[kind] = index != 1 }
        let read = SetupSummary.cards(counts: counts, steps: .of(steps), dotfiles: .synced, configRepo: nil)
        check(read.map(\.text) == ["6 / 8", "2", "4 / 5", "Synced", "In sync"],
              "the summary reads \(read.map { $0.text ?? "-" })", &ok)
        check(read[1].signals && read[1].tint == .warn && !read[0].signals,
              "two updates are not the Updates card's signal", &ok)

        // R2-BUG-05: a step still being checked is a dash on the card while
        // the subtitle, reading the same progress, says "checking" - never a
        // confident count beside it.
        var partial = steps
        partial[.software] = Bool?.none as Bool??
        let partialCard = SetupSummary.stepsCard(.of(partial))
        check(partialCard.text == nil && partialCard.unknownReason?.contains("still being checked") == true,
              "a step still being checked reads \(partialCard.text ?? "-") on the card", &ok)
        check(SetupPipelineProgress.of(partial).summary.hasSuffix("checking\u{2026}"),
              "fixture: the same progress makes the subtitle say checking", &ok)

        // A real zero is a zero; it is the dash that means unknown.
        counts.toolsWithUpdate = 0
        check(SetupSummary.updatesCard(counts).text == "0" && !SetupSummary.updatesCard(counts).signals,
              "no updates reads \(SetupSummary.updatesCard(counts).text ?? "-")", &ok)

        // The forks: behind, a check that read nothing, and a partial read.
        counts.forkDrift = 3
        check(SetupSummary.githubCard(counts, configRepo: nil).text == "3 behind", "three forks behind is not stated", &ok)
        counts.forkDrift = 0
        counts.forksChecked = 0
        check(SetupSummary.githubCard(counts, configRepo: nil).text == "Couldn\u{2019}t check",
              "a sweep that read no fork says \(SetupSummary.githubCard(counts, configRepo: nil).text ?? "-")", &ok)
        counts.forksChecked = 5
        check(SetupSummary.githubCard(counts, configRepo: nil).text == "5 / 8 read",
              "a partial read says \(SetupSummary.githubCard(counts, configRepo: nil).text ?? "-") - "
                  + "\"In sync\" would claim three forks nobody read", &ok)

        // Paused only for a confirmed public repo: an unknown answer never
        // blocks a push, so it never claims a pause.
        let paused = ConfigRepoPrivacy.Reading(visibility: .publicRepo, at: Date())
        let unknownRepo = ConfigRepoPrivacy.Reading(visibility: .unknown("offline"), at: Date())
        check(SetupSummary.githubCard(counts, configRepo: paused).text == "Paused"
                && SetupSummary.githubCard(counts, configRepo: paused).tint == .critical,
              "a public config repo does not read Paused", &ok)
        check(SetupSummary.githubCard(counts, configRepo: unknownRepo).text != "Paused",
              "an unanswered visibility check reads Paused", &ok)

        // Each dotfiles state says itself; the failures are the signal.
        let states: [(DotfilesAutoSync.Status, String, Bool)] = [
            (.synced, "Synced", false), (.localChanges, "Local changes", true), (.diverged("x"), "Diverged", true),
            (.failed("x"), "Failed", true), (.off, "Off", false), (.noRepo, "Not set up", false),
        ]
        for (status, text, signals) in states {
            let card = SetupSummary.dotfilesCard(status)
            check(card.text == text && card.signals == signals, "dotfiles \(status) reads \(card.text ?? "-")", &ok)
        }
    }

    // MARK: 5 - The readings

    private static func checkTheReadings(_ ok: inout Bool) {
        // The poller's counts carry their totals, in one assignment.
        let poller = BackgroundSignalsPoller.shared
        let saved = poller.lastCounts
        defer { poller.debugSetCounts(saved) }
        let statuses: [DependencyStatus] = [.upToDate, .upToDate, .updateAvailable, .notInstalled, .checkFailed]
        poller.publishToolStatuses(statuses, gatheredAt: Date().addingTimeInterval(3600))
        let tools = poller.lastCounts
        check(tools.toolsTotal == 5 && tools.toolsUpToDate == 2 && tools.toolsWithUpdate == 1 && tools.toolUpdates == 3,
              "the tool totals are \(String(describing: tools.toolsTotal)), \(String(describing: tools.toolsUpToDate)), "
                  + "\(String(describing: tools.toolsWithUpdate)), want 5, 2, 1", &ok)
        let forks: [GitHubSyncStatus] = [.inSync, .behind(3), .checkFailed, .diverged(localOnly: 1, upstreamAhead: 2)]
        poller.publishForkStatuses(forks, gatheredAt: Date().addingTimeInterval(3600))
        check(poller.lastCounts.forksTotal == 4 && poller.lastCounts.forksChecked == 3 && poller.lastCounts.forkDrift == 1,
              "the fork totals are \(String(describing: poller.lastCounts.forksTotal)) and "
                  + "\(String(describing: poller.lastCounts.forksChecked))", &ok)
        var results: [SetupStepKind: Bool?] = [:]
        for (index, kind) in SetupStepKind.allCases.enumerated() { results[kind] = index != 1 }
        let reading = SetupStepsReading.shared
        defer { reading.resetForTests() }
        reading.resetForTests()
        poller.publishSetupStepResults(results, gatheredAt: Date().addingTimeInterval(3600))
        // R2-BUG-05: the poller's pass is one of the module reading's
        // producers, so the steps card hears it.
        check(reading.progress.done == SetupStepKind.allCases.count - 1 && reading.progress.checking == 0,
              "the module's step reading is \(reading.progress) after the poller's pass", &ok)
        // An unanswered step never erases an answered one, and an older
        // answer never replaces a newer one.
        reading.record([.software: Bool?.none])
        check(reading.verdicts[.software] == .some(true), "a step still being checked erased its answer", &ok)
        reading.record([.software: false], gatheredAt: Date())
        check(reading.verdicts[.software] == .some(true), "an older answer replaced a newer one", &ok)
        reading.record([.software: false], gatheredAt: Date().addingTimeInterval(7200))
        check(reading.verdicts[.software] == .some(false), "a newer answer did not replace an older one", &ok)

        // The dotfiles sync says nothing before a pass has reported - its
        // initial `.synced` is a default, not a reading.
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("no-dotfiles-\(UUID().uuidString)")
        let sync = DotfilesAutoSync(workingTree: tree, isEnabled: { false })
        check(sync.reportedStatus == nil, "a dotfiles sync that has not run reports \(String(describing: sync.reportedStatus))", &ok)
        sync.debugSetStatus(.noRepo)
        check(sync.reportedStatus == .noRepo, "a reported status is not kept", &ok)

        // The config repo's last answer is kept and observed.
        ConfigRepoPrivacy.debugReset()
        defer { ConfigRepoPrivacy.debugReset() }
        check(ConfigRepoPrivacy.lastReading == nil, "a check that never ran left a reading", &ok)
        var heard: [ConfigRepoPrivacy.Visibility] = []
        let token = ConfigRepoPrivacy.observe { reading in if let reading { heard.append(reading.visibility) } }
        defer { ConfigRepoPrivacy.unobserve(token) }
        ConfigRepoPrivacy.debugRecord(.publicRepo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(ConfigRepoPrivacy.lastReading?.visibility == .publicRepo && heard.last == .publicRepo,
              "a public answer was not kept or not heard (heard \(heard))", &ok)
        check(ConfigRepoPrivacy.settingsURL?.absoluteString.hasSuffix("/settings") == true,
              "Open on GitHub does not open the repo's settings: \(String(describing: ConfigRepoPrivacy.settingsURL))", &ok)
    }

    // MARK: Focus time

    private static func checkTheFocusCount(_ ok: inout Bool) {
        let store = ShiftStore()
        let now = Date()
        let calendar = Calendar.current
        guard let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now),
              let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now) else { return }
        store.logFocusSession(taskID: "a", taskTitle: "A", seconds: 600, now: now)
        store.logFocusSession(taskID: "a", taskTitle: "A", seconds: 600, now: threeDaysAgo)
        store.logFocusSession(taskID: "b", taskTitle: "B", seconds: 600, now: threeDaysAgo)
        store.logFocusSession(taskID: "c", taskTitle: "C", seconds: 600, now: tenDaysAgo)
        check(store.focusTaskCount(days: 7, reference: now) == 2,
              "the last 7 days focused \(store.focusTaskCount(days: 7, reference: now)) distinct tasks, want 2", &ok)
        check(store.focusTaskCount(days: 1, reference: now) == 1, "today focused \(store.focusTaskCount(days: 1, reference: now)) tasks", &ok)
        check(store.focusTaskCount(days: 30, reference: now) == 3, "the last 30 days focused the wrong count", &ok)
    }

    // MARK: 6 - Tasks' filters

    /// The page column held the Workspace views, Follow-ups, the Projects and
    /// the Smart views; the filter row is where they live in the sidebar
    /// layout. A source guard, because the window-backed half drives a sample.
    private static func checkTasksKeepsItsFilters(_ ok: inout Bool) {
        guard let shift = code("ShiftController.swift") else {
            fail("could not read ShiftController.swift - the guard would pass vacuously", &ok)
            return
        }
        check(ShiftController.ShiftTaskScope.allCases.count == 5,
              "the scopes changed; the filter row lists \(ShiftController.ShiftTaskScope.allCases.count)", &ok)
        for needle in ["ShiftTaskScope.allCases.map { .init(id: $0.rawValue, title: $0.title) }",
                       "[scopeFilter, followUpsJump, projectPopup, spacer, sortPopup, doneWindowNote]",
                       "splitPage?.pageForcesCollapse = drawsSidebarLayout || view != .dashboard",
                       "var workspacePrimaryAction: NSView? { drawsSidebarLayout ? newTaskButton : nil }",
                       "boardView.adoptWorkspaceStyle()"] {
            check(shift.contains(needle), "Tasks' sidebar presentation lost `\(needle)`", &ok)
        }
    }

    // MARK: Setup's wiring

    private static func checkTheSetupWiring(_ ok: inout Bool) {
        guard let updates = code("UpdatesController.swift"), let github = code("GitHubSyncController.swift"),
              let bootstrap = code("BootstrapController.swift"), let automation = code("AutomationController.swift"),
              let workspace = code("Workspace.swift") else {
            fail("could not read the Setup pages' sources - the guard would pass vacuously", &ok)
            return
        }
        // Each of the four shows the summary row first, and keeps its own
        // main action as the toolbar's primary one.
        for (name, text, primary) in [("Updates", updates, "checkForUpdatesButton"), ("GitHub sync", github, "syncAllButton"),
                                      ("Setup steps", bootstrap, "runFullSetupButton"), ("Automation", automation, "runButton")] {
            check(text.contains("insertArrangedSubview(setupSummary, at: 0)"), "\(name) does not open on the summary row", &ok)
            check(text.contains("var workspacePrimaryAction: NSView? { drawsSidebarLayout ? \(primary) : nil }"),
                  "\(name)'s primary action is no longer `\(primary)`", &ok)
        }
        check(updates.contains("action: #selector(checkAllTapped)") && updates.contains("title: \"Check for updates\""),
              "Check for updates is no longer Check all", &ok)
        check(github.contains("rows.allSatisfy({ $0.status == .inSync })"),
              "GitHub sync's subtitle can say \"all in sync\" over checks that failed again", &ok)
        check(workspace.contains("automation.scheduleStore = scheduleStore"),
              "Automation no longer lists the app's own schedule store", &ok)
    }
}

#endif
