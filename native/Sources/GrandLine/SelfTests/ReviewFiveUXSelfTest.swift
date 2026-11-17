// Grand Line - native macOS app.
//
// Review #5's UX findings (R5-UX-01 to R5-UX-11): the pure half - models,
// tables, menus and source guards. Each check names the finding it guards.
//
// Pure logic, no window: every case drives a model, reads a table or greps
// the app's own sources, so it runs in CI's blocking headless lane.

#if FM_SELFTESTS

import AppKit

enum ReviewFiveUXSelfTest {

    static func run() -> Bool {
        var ok = true
        checkPersonalLeavesOutTheFirstmateSteps(&ok)
        checkTheLaunchLandingFollowsTheProfileInBothLayouts(&ok)
        checkKnowledgeIsSplitPerProfile(&ok)
        checkTheCalendarIsAPlace(&ok)
        checkTheConsoleToolbarFollowsTheProfile(&ok)
        checkPersonalHomeLeadsWithWhatYouCanActOn(&ok)
        checkAStoredSidebarSettlesTheSplitOnce(&ok)
        print(ok ? "ReviewFiveUXSelfTest: PASS" : "ReviewFiveUXSelfTest: FAIL")
        return ok
    }

    // MARK: Shared

    static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Runs `body` with the profile and hidden set it sets, and puts this
    /// process's own values back after.
    static func withProfile(_ profile: WorkspaceProfile?, _ body: () -> Void) {
        let defaults = AppDefaults.store
        let savedProfile = defaults.object(forKey: "fm.workspaceProfile")
        let savedHidden = defaults.object(forKey: "fm.hiddenModules")
        defer {
            defaults.set(savedProfile, forKey: "fm.workspaceProfile")
            defaults.set(savedHidden, forKey: "fm.hiddenModules")
        }
        if let profile {
            AppSettings.shared.setProfile(profile)
        } else {
            defaults.removeObject(forKey: "fm.workspaceProfile")
            defaults.removeObject(forKey: "fm.hiddenModules")
        }
        body()
    }

    // MARK: R5-UX-01 - profile-first onboarding

    /// A Personal install has no firstmate home and needs none, so Setup's
    /// steps about the fleet and the dotfiles are neither listed nor counted.
    /// An Operator, and a process with no profile, keep all five.
    private static func checkPersonalLeavesOutTheFirstmateSteps(_ ok: inout Bool) {
        let personal = SetupStepKind.shown(for: .personal)
        check(personal == [.software, .restoreConfig],
              "R5-UX-01: Personal's Setup steps are \(personal)", &ok)
        check(SetupStepKind.shown(for: .operator) == SetupStepKind.allCases && SetupStepKind.shown(for: nil) == SetupStepKind.allCases,
              "R5-UX-01: an Operator or an unsettled install no longer sees every Setup step", &ok)
        // The fixture's own power: Personal really leaves something out.
        check(personal.count < SetupStepKind.allCases.count, "R5-UX-01: the Personal fixture leaves nothing out", &ok)

        withProfile(.personal) {
            // Every step unanswered but Software, which drifted: a count over
            // the steps Personal shows answers, and the firstmate steps that
            // would read "not done" forever are not in it.
            let verdicts: [SetupStepKind: Bool?] = [.software: false, .restoreConfig: true]
            check(BackgroundSignalsPoller.setupDriftCount(from: verdicts) == 1,
                  "R5-UX-01: Personal's drift count waits on a step it does not show", &ok)
            let progress = SetupPipelineProgress.of(verdicts)
            check(progress.total == 2 && progress.done == 1,
                  "R5-UX-01: Personal's Setup progress reads \(progress.done) of \(progress.total)", &ok)
            // Custom built from Personal keeps the profile's Setup steps.
            var hidden = AppSettings.shared.hiddenModules
            hidden.remove(.setup)
            AppSettings.shared.hiddenModules = hidden
            check(SetupStepKind.shown == personal, "R5-UX-01: showing Setup to a Personal install brought the firstmate steps back", &ok)
        }
        withProfile(.operator) {
            let verdicts: [SetupStepKind: Bool?] = [.software: false, .restoreConfig: true]
            check(BackgroundSignalsPoller.setupDriftCount(from: verdicts) == nil,
                  "R5-UX-01: an Operator's drift count published with three steps unanswered", &ok)
        }
    }

    /// GL-31 lands a machine with no firstmate home on Setup. A profile that
    /// hides Setup has nothing there to fix, in either layout.
    private static func checkTheLaunchLandingFollowsTheProfileInBothLayouts(_ ok: inout Bool) {
        guard let workspace = source("Workspace.swift") else {
            fail("R5-UX-01: Workspace.swift is not readable", &ok)
            return
        }
        check(workspace.contains("if FirstmateHome.homeOk() || AppSettings.shared.hiddenModules.contains(.setup) {"),
              "R5-UX-01: the launch landing no longer skips a hidden Setup in both layouts", &ok)
        check(!workspace.contains("PlaceName.layout == .sidebar && AppSettings.shared.hiddenModules.contains(.setup)"),
              "R5-UX-01: the launch landing still opens a Personal floating-bar install on Setup", &ok)
    }

    // MARK: R5-UX-04 - the Calendar as its own place

    /// The Calendar's own toolbar is its periods in the card's order, its row
    /// takes ⌘0, Tasks' Calendar tab still lands on it, and the Tasks page
    /// hands it Today. The window-backed half is `MainSplitShellSelfTest`.
    private static func checkTheCalendarIsAPlace(_ ok: inout Bool) {
        check(ShiftCalendarScale.toolbarOrder == [.day, .week, .month, .agenda],
              "R5-UX-04: the Calendar's tabs are \(ShiftCalendarScale.toolbarOrder.map(\.title))", &ok)
        check(Set(ShiftCalendarScale.toolbarOrder) == Set(ShiftCalendarScale.allCases),
              "R5-UX-04: a calendar period has no tab of its own", &ok)
        check(WorkspaceGoMenu.chord(for: .calendar, hidden: WorkspaceProfile.personal.hiddenModules) == 0
                && WorkspaceGoMenu.chord(for: .calendar, hidden: WorkspaceProfile.operator.hiddenModules) == 0,
              "R5-UX-04: the Calendar lost its ⌘0 in a profile", &ok)
        check(ModuleTable.litModule(for: .shift, pageTab: "Calendar", hidden: []) == .calendar
                && WorkspaceModule.tasks.tabs.contains { $0.name == "Calendar" },
              "R5-UX-04: Tasks' Calendar tab is no longer a shortcut to the Calendar", &ok)
        if let shift = source("ShiftController.swift"), let shell = source("MainSplitShellController.swift") {
            check(shift.contains("tasksView == .calendar ? [calendarTodayButton] : []"),
                  "R5-UX-04: the Calendar's toolbar lost Today", &ok)
            check(shell.contains("} else if let calendar = shownCalendar {"),
                  "R5-UX-04: the shell no longer draws the Calendar's own tabs", &ok)
        }
    }

    // MARK: R5-UX-06 - the Console toolbar per profile

    /// A host page's Console: SRE Lead, Analyze Logs, Tail Logs, the
    /// cluster badge and Start Incident are an Operator's. A Personal Console
    /// is a terminal - Find, text size, Compose and new tabs - and a change
    /// of profile reshapes a page already open.
    private static func checkTheConsoleToolbarFollowsTheProfile(_ ok: inout Bool) {
        autoreleasepool {
            let console = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
            _ = console.view
            func titles() -> [String] { console.pageToolViews.compactMap { ($0 as? HelmButton)?.title } }
            let operatorTools = ["SRE Lead", "Analyze Logs", "Tail Logs", "Start Incident"]
            withProfile(.operator) {
                let shown = titles()
                check(console.operatorToolViews.count == 5 && operatorTools.allSatisfy { title in shown.contains { $0.hasPrefix(title) } },
                      "R5-UX-06: an Operator's host Console shows \(shown)", &ok)
                withProfile(.personal) {
                    let personal = titles()
                    check(!personal.contains { title in operatorTools.contains { title.hasPrefix($0) } },
                          "R5-UX-06: a Personal host Console still shows \(personal)", &ok)
                    check(console.pageToolViews.contains { $0 === console.findButton }
                            && console.pageToolViews.contains { $0 === console.zoomStepper }
                            && console.pageToolViews.contains { $0 === console.composeButton },
                          "R5-UX-06: a Personal Console lost Find, text size or Compose", &ok)
                    // The page's own row follows the profile too (the
                    // floating bar's toolbar).
                    check(console.operatorToolViews.allSatisfy { $0.window == nil && !$0.isDescendant(of: console.view) },
                          "R5-UX-06: a Personal Console's tab row still holds an operator tool", &ok)
                }
                AppSettings.shared.setProfile(.operator)
                check(console.operatorToolViews.allSatisfy { $0.isDescendant(of: console.view) },
                      "R5-UX-06: choosing Operator again did not bring the tools back", &ok)
            }
        }
    }

    // MARK: R5-UX-07 - Home's default cards per profile

    private static func checkPersonalHomeLeadsWithWhatYouCanActOn(_ ok: inout Bool) {
        // The review's six, in its order; the Operator keeps the hub's own.
        check(HomeCardLayout.standard(for: .personal).shown == [.tasks, .calendar, .notebook, .stickyBoard, .readingList, .focusTimer],
              "R5-UX-07: a Personal Home starts with \(HomeCardLayout.standard(for: .personal).shown.map(\.rawValue))", &ok)
        check(HomeCardLayout.standard(for: .operator) == .standard, "R5-UX-07: the Operator's Home changed its default cards", &ok)
        check(DaylightModule.calendar.opens == .calendar && DaylightModule.focusTimer.opens == .shift
                && !DaylightModule.calendar.appearsOnOverview && !DaylightModule.focusTimer.appearsOnOverview,
              "R5-UX-07: the new cards open the wrong page or joined the floating hub", &ok)

        // Next up: a fixed clock, and the calendar's own day words.
        var cal = Calendar.current
        cal.firstWeekday = 2
        guard let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) else { return }
        func day(_ offset: Int) -> String {
            ShiftDateFormatting.components(from: cal.date(byAdding: .day, value: offset, to: noon) ?? noon).dateStr
        }
        var earlier = ShiftTask.fresh()
        earlier.title = "Call the bank"
        earlier.dueDate = day(0)
        earlier.dueTime = "09:00"
        var later = ShiftTask.fresh()
        later.title = "Dentist"
        later.dueDate = day(0)
        later.dueTime = "15:30"
        var tomorrow = ShiftTask.fresh()
        tomorrow.title = "Pay rent"
        tomorrow.dueDate = day(1)
        var overdue = ShiftTask.fresh()
        overdue.title = "Renew passport"
        overdue.dueDate = day(-3)
        var faraway = ShiftTask.fresh()
        faraway.title = "Book flights"
        faraway.dueDate = day(HomeNextUpCard.horizonDays + 5)
        let rows = HomeNextUpCard.rows(tasks: [faraway, overdue, tomorrow, later, earlier], followUps: [], now: noon, calendar: cal)
        check(rows.map(\.title) == ["Dentist", "Pay rent"],
              "R5-UX-07: next up lists \(rows.map(\.title)), want what is still ahead within two weeks", &ok)
        check(rows.first?.when == "Today 15:30" && rows.last?.when == "Tomorrow",
              "R5-UX-07: next up reads \(rows.map(\.when))", &ok)

        // Focus: idle, running and paused say different things.
        check(HomeFocusCard.state(session: nil, focusedSecondsToday: 25 * 60, now: noon) == .idle(minutesToday: 25),
              "R5-UX-07: an idle focus card does not count today's minutes", &ok)
        var session = FocusSession(taskID: "t1", taskTitle: "Write the report", plannedSeconds: 25 * 60,
                                   accumulatedSeconds: 0, segmentStartedAt: noon, startedAt: noon)
        let running = HomeFocusCard.state(session: session, focusedSecondsToday: 0, now: noon.addingTimeInterval(5 * 60))
        check(running == .running(task: "Write the report", endsAt: noon.addingTimeInterval(25 * 60)),
              "R5-UX-07: a running session reads \(running)", &ok)
        session.accumulatedSeconds = 10 * 60
        session.segmentStartedAt = nil
        check(HomeFocusCard.state(session: session, focusedSecondsToday: 0, now: noon) == .paused(task: "Write the report", minutesLeft: 15),
              "R5-UX-07: a paused session does not say what is left", &ok)

        // The card re-renders when the session changes, not on every tick.
        if let home = source("HomeCanvasController.swift") {
            check(home.contains("guard key != focusCardKey else { return }"),
                  "R5-UX-07: Home re-renders the Focus timer card on every timer tick", &ok)
        }
    }

    // MARK: R5-UX-05 - Knowledge split

    /// Personal lists Notebook and Reading list as rows of their own and no
    /// SRE shelf; Operator keeps Knowledge's tab bar (without Runbooks and
    /// Postmortems) and finds those two in Observe.
    private static func checkKnowledgeIsSplitPerProfile(_ ok: inout Bool) {
        let personal = WorkspaceProfile.personal.hiddenModules
        let op = WorkspaceProfile.operator.hiddenModules
        let personalWork = WorkspaceSidebarModel.modules(in: .work, hidden: personal)
        check(personalWork == [.tasks, .calendar, .notebook, .readingList, .secrets],
              "R5-UX-05: a Personal Work group lists \(personalWork.map(\.rawValue))", &ok)
        check(WorkspaceSidebarModel.modules(in: .observe, hidden: personal).isEmpty,
              "R5-UX-05: a Personal sidebar lists Observe modules", &ok)
        let operatorWork = WorkspaceSidebarModel.modules(in: .work, hidden: op)
        let operatorObserve = WorkspaceSidebarModel.modules(in: .observe, hidden: op)
        check(operatorWork.contains(.knowledge) && !operatorWork.contains(.notebook) && !operatorWork.contains(.readingList),
              "R5-UX-05: an Operator's Work group lists \(operatorWork.map(\.rawValue))", &ok)
        check(operatorObserve == [.kubernetes, .logs, .runbooks, .health, .schedules],
              "R5-UX-05: an Operator's Observe group lists \(operatorObserve.map(\.rawValue))", &ok)
        check(WorkspaceModule.knowledge.tabs.map(\.name) == ["Notebook", "Docs", "Reading list"]
                && WorkspaceModule.runbooks.tabs.map(\.route) == [.runbooks, .postmortems],
              "R5-UX-05: Knowledge's tabs are \(WorkspaceModule.knowledge.tabs.map(\.name)) and Runbooks' \(WorkspaceModule.runbooks.tabs.map(\.name))", &ok)

        // The row each profile lights for the same page, and the one ⌘K
        // keeps: the Notebook is a place of its own for Personal and a
        // Knowledge tab for an Operator, and reachable from both.
        check(ModuleTable.litModule(for: .notebook, hidden: personal) == .notebook
                && ModuleTable.litModule(for: .readingList, hidden: personal) == .readingList,
              "R5-UX-05: a Personal Notebook or Reading list does not light its own row", &ok)
        check(ModuleTable.litModule(for: .notebook, hidden: op) == .knowledge
                && ModuleTable.litModule(for: .runbooks, hidden: op) == .runbooks,
              "R5-UX-05: an Operator's Notebook or Runbooks lights the wrong row", &ok)
        check(!ModuleTable.hidesPage(.notebook, hidden: personal) && !ModuleTable.hidesPage(.notebook, hidden: op)
                && ModuleTable.hidesPage(.runbooks, hidden: personal) && !ModuleTable.hidesPage(.docs, hidden: op),
              "R5-UX-05: ⌘K hides the wrong Knowledge pages for a profile", &ok)
        // A door row opens its page, and Knowledge opens on a tab that is
        // its own when a Notebook row is listed beside it.
        check(WorkspaceModule.notebook.primaryRoute == .notebook && WorkspaceModule.readingList.primaryRoute == .readingList
                && WorkspaceModule.knowledge.primaryRoute == .docs,
              "R5-UX-05: the rows open \(WorkspaceModule.notebook.primaryRoute), \(WorkspaceModule.readingList.primaryRoute) and \(WorkspaceModule.knowledge.primaryRoute)", &ok)
        // Every profile still matches the set it writes.
        for profile in WorkspaceProfile.allCases {
            check(WorkspaceProfile.matching(profile.hiddenModules) == profile,
                  "R5-UX-05: the \(profile.title) set does not read as \(profile.title)", &ok)
        }
        // The shell draws a door row's place as its own: no host tab bar,
        // and ⌘⇧[ / ] has nothing to step through there.
        if let shell = source("MainSplitShellController.swift") {
            check(shell.contains("} else if showsDoorAsOwnPlace {") && shell.contains("guard !showsDoorAsOwnPlace else { return }"),
                  "R5-UX-05: the shell no longer draws a door row's page as a place of its own", &ok)
        }
    }

    /// A hidden set stored before the split names none of the new rows. It is
    /// settled once, by what it already said, and a fresh install's set is the
    /// profile's own.
    private static func checkAStoredSidebarSettlesTheSplitOnce(_ ok: inout Bool) {
        ReviewTwoUXModelSelfTest.withScratchSettings("r5split.operator") { settings in
            settings.setProfile(.operator)
            settings.hiddenModules = [.kubernetes]
            settings.settleFirstLaunch(isExistingInstall: true)
            check(settings.hiddenModules == [.kubernetes, .notebook, .readingList],
                  "R5-UX-05: an Operator's stored set settled to \(settings.hiddenModules.map(\.rawValue).sorted())", &ok)
            // Once: a later edit is the captain's and is never redone.
            settings.hiddenModules = [.kubernetes]
            settings.settleFirstLaunch(isExistingInstall: true)
            check(settings.hiddenModules == [.kubernetes], "R5-UX-05: the split was settled a second time", &ok)
        }
        ReviewTwoUXModelSelfTest.withScratchSettings("r5split.personal") { settings in
            settings.setProfile(.personal)
            settings.hiddenModules = [.crew, .connections, .console, .kubernetes, .logs, .health, .schedules, .setup]
            settings.settleFirstLaunch(isExistingInstall: true)
            check(settings.hiddenModules == WorkspaceProfile.personal.hiddenModules,
                  "R5-UX-05: a stored Personal set settled to \(settings.hiddenModules.map(\.rawValue).sorted())", &ok)
        }
        ReviewTwoUXModelSelfTest.withScratchSettings("r5split.noKnowledge") { settings in
            settings.setProfile(.operator)
            settings.hiddenModules = [.knowledge]
            settings.settleFirstLaunch(isExistingInstall: true)
            check(settings.hiddenModules == [.knowledge, .notebook, .readingList, .runbooks],
                  "R5-UX-05: a set hiding Knowledge settled to \(settings.hiddenModules.map(\.rawValue).sorted())", &ok)
        }
        ReviewTwoUXModelSelfTest.withScratchSettings("r5split.fresh") { settings in
            settings.settleFirstLaunch(isExistingInstall: false)
            check(settings.hiddenModules == WorkspaceProfile.personal.hiddenModules,
                  "R5-UX-05: a fresh install's set is \(settings.hiddenModules.map(\.rawValue).sorted())", &ok)
        }
    }
}

#endif
