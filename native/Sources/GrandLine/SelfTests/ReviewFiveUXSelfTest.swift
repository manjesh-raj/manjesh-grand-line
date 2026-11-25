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
        checkOneWordPerState(&ok)
        checkFailuresSayWhatToDo(&ok)
        checkTheHiddenPowerIsVisible(&ok)
        checkTheKeyboardReachesEveryPage(&ok)
        checkListsKeepAQuietHint(&ok)
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
    /// hands it Today. The window-backed half is
    /// `MainSplitShellNavigationSelfTest`.
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
                // The window toolbar holds the cluster and re-reads
                // `pageToolViews`; the page's own tab row holds none of it.
                let back = titles()
                check(operatorTools.allSatisfy { title in back.contains { $0.hasPrefix(title) } },
                      "R5-UX-06: choosing Operator again did not bring the tools back (\(back))", &ok)
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

        // A Home with no Crew never speaks for the fleet.
        if let home = SelfTestSources.homeCanvas(read: source) {
            check(home.contains("let answerIfAny = fleetSpeaks ? overviewAnswer() : nil"),
                  "R5-UX-07: a Home without Crew reports on the fleet again", &ok)
        }
        // The card re-renders when the session changes, not on every tick.
        if let home = SelfTestSources.homeCanvas(read: source) {
            check(home.contains("guard key != focusCardKey else { return }"),
                  "R5-UX-07: Home re-renders the Focus timer card on every timer tick", &ok)
        }
    }

    // MARK: R5-UX-02 - one vocabulary for state

    private static func checkOneWordPerState(_ ok: inout Bool) {
        // The table names every state once, and no two states share a word.
        let labels = StateWord.allCases.map(\.label)
        check(!labels.contains("") && Set(labels).count == labels.count,
              "R5-UX-02: the state table has a missing or repeated word: \(labels)", &ok)
        check(StateWord.checkFailed.counted(1) == "1 check failed" && StateWord.checkFailed.counted(3) == "3 checks failed"
                && StateWord.upToDate.counted(2) == "2 up to date" && StateWord.recentFailure.counted(2) == "2 recent failures",
              "R5-UX-02: a counted state reads \(StateWord.checkFailed.counted(3)) / \(StateWord.recentFailure.counted(2))", &ok)
        // The registries' and stores' summaries speak it.
        for bucket in ServiceHealthSummary.Bucket.allCases {
            check(bucket.label == bucket.word.label, "R5-UX-02: the \(bucket) service state has a word of its own", &ok)
        }
        let statuses: [DependencyStatus] = [.unknown, .checking, .upToDate, .updateAvailable, .notInstalled,
                                            .checkFailed, .updating, .updateFailed]
        check(Set(statuses.map(\.stateWord)).count == statuses.count,
              "R5-UX-02: two tool states share a word", &ok)
        check(UpdatesSummary([.checkFailed, .upToDate]).parts == ["1 up to date", "1 check failed"],
              "R5-UX-02: Updates' summary reads \(UpdatesSummary([.checkFailed, .upToDate]).parts)", &ok)
        check(ShiftController.ShiftTaskScope.overdue.title == StateWord.overdue.label && ShiftController.ShiftTaskScope.dueToday.title == StateWord.dueToday.label,
              "R5-UX-02: Tasks' filters name overdue and due today their own way", &ok)
        // Setup's software step and the Updates page say the same thing about
        // the same tool, and neither spells it itself.
        if let bootstrap = source("BootstrapController.swift"), let updates = source("UpdatesController.swift") {
            check(bootstrap.contains("let word = status.stateWord.label"),
                  "R5-UX-02: Setup's software step names a tool's state its own way again", &ok)
            check(updates.contains(".muted(StateWord.upToDate.label)") && updates.contains(".status(StateWord.checkFailed.label"),
                  "R5-UX-02: Updates names a tool's state its own way again", &ok)
        }
        // No retired word comes back in a string the app shows. Comments
        // are stripped, so a note naming the old word does not count.
        guard let dir = SelfTestSources.appSourceDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            fail("R5-UX-02: the app's sources are not readable, so the retired words are unchecked", &ok)
            return
        }
        var scanned = 0
        for file in files where file.hasSuffix(".swift") && file != "StateVocabulary.swift" {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
            scanned += 1
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for (word, state) in StateVocabulary.retired where code.contains(where: { $0.contains(word) }) {
                fail("R5-UX-02: \(file) says \(word) for what is now \"\(state.label)\"", &ok)
            }
        }
        check(scanned > 100, "R5-UX-02: the retired-word scan read only \(scanned) files", &ok)
    }

    // MARK: R5-UX-08 - errors that say what to do

    private static func checkFailuresSayWhatToDo(_ ok: inout Bool) {
        // The review's own example, on the Health page.
        let gh = FailureExplainer.explain(service: .backgroundSignals,
                                          detail: "gh: could not reach api.github.com", canRetry: true)
        check(FailureExplainer.cause(of: "gh: could not reach api.github.com") == .network
                && gh.why == "gh: could not reach api.github.com." && gh.whatToDo.contains("connection")
                && gh.whatToDo.contains("press Retry") && !gh.whatFailed.isEmpty,
              "R5-UX-08: the Health page's network error reads \(gh)", &ok)
        // A row with no Retry never names one.
        let noRetry = FailureExplainer.explain(service: .fleetTasks, detail: "connection refused", canRetry: false)
        check(!noRetry.whatToDo.contains("Retry"), "R5-UX-08: a row without Retry tells the captain to press it", &ok)
        // Each cause reads its own way, and an unclassified error still has
        // a next step.
        let causes: [(String, FailureExplainer.Cause)] = [
            ("fatal: Authentication failed for 'https://github.com/x/y'", .signedOut),
            ("write failed: No space left on device", .diskFull),
            ("'herdr' not found on PATH", .missingTool),
            ("open: Operation not permitted", .permission),
            ("git fetch timed out after 60s", .timedOut),
            ("exit 1", .unknown),
        ]
        for (text, want) in causes {
            check(FailureExplainer.cause(of: text) == want, "R5-UX-08: \"\(text)\" reads as \(FailureExplainer.cause(of: text))", &ok)
        }
        for service in HealthService.allCases {
            let e = FailureExplainer.explain(service: service, detail: "exit 1", canRetry: false)
            check(!e.whatFailed.isEmpty && !e.whatToDo.isEmpty, "R5-UX-08: \(service) has no next step for an unknown error", &ok)
        }
        // Updates: "Check failed" with the reason and what to do.
        let npm = FailureExplainer.explain(tool: "claude", status: .checkFailed,
                                           detail: "Installed 1.0.3 - could not reach npm registry for the latest version", log: "")
        check(npm.whatFailed == "claude couldn\u{2019}t be checked for updates." && npm.whatToDo.contains("press Check"),
              "R5-UX-08: a failed npm check reads \(npm)", &ok)
        if let updates = source("UpdatesController.swift"), let health = source("HealthCardView.swift") {
            check(updates.contains("let subtitle = failed ? Self.failureExplanation(row).rowLine : nil")
                    && updates.contains("detail.fields.append(.init(\"What to do\", failure.whatToDo))"),
                  "R5-UX-08: an Updates row no longer says what to do in its table row and its details", &ok)
            check(health.components(separatedBy: "FailureExplainer.explain(service: service").count == 3,
                  "R5-UX-08: a Health row no longer says what to do in both layouts", &ok)
        }
    }

    // MARK: R5-UX-03 - the first week's tips and ⌘/

    private static func checkTheHiddenPowerIsVisible(_ ok: inout Bool) {
        let cal = Calendar.current
        guard let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) else { return }
        let tips = HomeTips.all(settings: AppSettings.shared)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: start) ?? start }
        // One a day for seven days, each different, then none.
        let week = (0..<HomeTips.days).compactMap { HomeTips.tip(firstShown: start, now: day($0), dismissed: false, tips: tips) }
        check(week.count == 7 && Set(week.map(\.title)).count == 7,
              "R5-UX-03: the first week shows \(week.map(\.title))", &ok)
        check(HomeTips.tip(firstShown: start, now: day(7), dismissed: false, tips: tips) == nil,
              "R5-UX-03: a tip still shows on day eight", &ok)
        check(HomeTips.tip(firstShown: start, now: day(1), dismissed: true, tips: tips) == nil,
              "R5-UX-03: a dismissed strip came back", &ok)
        // The tips name the keys the app really has: the recorded capture
        // and dictation chords, and the layout's own navigation.
        let titles = tips.map(\.title).joined(separator: " | ")
        check(titles.contains(AppSettings.shared.quickCaptureShortcut.displayString)
                && titles.contains(AppSettings.shared.dictationShortcut.displayString)
                && titles.contains("\u{2318}K") && titles.contains(";abbreviation") && titles.contains("\u{2325}\u{2318}I"),
              "R5-UX-03: the tips are \(titles)", &ok)

        // ⌘/: the page's chords, then the ones that work everywhere.
        let tasks = PageShortcuts.sections(module: .tasks, route: .shift, settings: AppSettings.shared)
        check(tasks.map(\.title) == ["On Tasks", "Everywhere"]
                && tasks[0].entries.contains { $0.title == ContextualNewAction.task.menuTitle && $0.chord == "\u{2318}N" }
                && tasks[0].entries.contains { $0.title == "Previous or next tab" }
                && tasks[1].entries.contains { $0.chord == "\u{2318}K" }
                && tasks[1].entries.contains { $0.chord == "\u{2325}\u{2318}I" },
              "R5-UX-03: ⌘/ on Tasks lists \(tasks)", &ok)
        let console = PageShortcuts.sections(module: .console, route: .console, settings: AppSettings.shared)
        check(console[0].entries.count > TerminalShortcutAction.allCases.count - 1,
              "R5-UX-03: ⌘/ on Console lists \(console)", &ok)
        // The chord is real, in the Help menu, once.
        let menu = AppDelegate().buildMenu(installing: false)
        let help = menu.items.compactMap(\.submenu).first { $0.title == "Help" }
        let item = help?.items.first { $0.action == #selector(AppDelegate.showPageShortcuts) }
        check(item?.keyEquivalent == "/" && item?.keyEquivalentModifierMask == [.command],
              "R5-UX-03: Help has no ⌘/ Shortcuts for This Page", &ok)
        // Home starts the week at a real launch, never in a test process.
        if let settings = source("AppSettings.swift"), let home = SelfTestSources.homeCanvas(read: source) {
            check(settings.contains("if homeTipsFirstShown == nil { homeTipsFirstShown = Date() }")
                    && home.contains("stack.addArrangedSubview(tipRow)"),
                  "R5-UX-03: Home's tip strip or its week is no longer wired", &ok)
        }
    }

    // MARK: R5-UX-09 - keyboard and accessibility

    private static func checkTheKeyboardReachesEveryPage(_ ok: inout Bool) {
        // ⌥⌘I, the platform's inspector chord, in the layout that has one.
        let sidebarMenu = ReviewTwoUXModelSelfTest.mainMenu()
        func inspectorItem(_ menu: NSMenu) -> NSMenuItem? {
            menu.items.compactMap(\.submenu).flatMap(\.items)
                .first { $0.action == #selector(WorkspaceShellController.toggleInspectorFromMenu) }
        }
        let inspector = inspectorItem(sidebarMenu)
        check(inspector?.keyEquivalent == "i" && inspector?.keyEquivalentModifierMask == [.command, .option],
              "R5-UX-09: Go › Toggle Inspector is not ⌥⌘I", &ok)

        // The dictation key asks for Accessibility once, at the first press
        // without it, naming the key that was pressed.
        check(DictationPermissions.shouldAskForAccessibility(trusted: false, alreadyAsked: false)
                && !DictationPermissions.shouldAskForAccessibility(trusted: false, alreadyAsked: true)
                && !DictationPermissions.shouldAskForAccessibility(trusted: true, alreadyAsked: false),
              "R5-UX-09: the dictation key's Accessibility question is asked at the wrong time", &ok)
        let request = DictationPermissions.accessibilityRequest(key: KeyChord.dictationDefault.displayString)
        check(request.body.contains(KeyChord.dictationDefault.displayString) && request.confirmTitle.contains("Accessibility"),
              "R5-UX-09: the dictation question reads \(request.title): \(request.body)", &ok)
        if let composition = source("AppComposition.swift") {
            check(composition.contains("settings.dictationAccessibilityAsked = true")
                    && composition.contains("_ = DictationPermissions.requestAccessibility()"),
                  "R5-UX-09: the dictation key no longer asks for Accessibility at the moment of intent", &ok)
        }

        // Labels: a host card says its live state, and Health's run dots
        // are spoken, so neither is a colour alone.
        let host = Host(label: "DEV Bastion", address: "bastion.dev.example.test")
        check(HostsController.accessibilityLabel(for: host, session: nil, group: "Staging").contains("group Staging"),
              "R5-UX-09: a host card's VoiceOver label is \(HostsController.accessibilityLabel(for: host, session: nil, group: "Staging"))", &ok)
        if let health = source("HealthCardView.swift") {
            check(health.contains(".runDots(runs, spoken: Self.runTicksSpoken(state))"),
                  "R5-UX-09: Health's recent runs are no longer spoken", &ok)
        }
    }

    // MARK: R5-UX-10 - a quiet hint after the first item

    private static func checkListsKeepAQuietHint(_ ok: inout Bool) {
        check(QuietHint.line("1 link", count: 1, hint: "\u{2318}V pastes a link") == "1 link \u{00B7} \u{2318}V pastes a link"
                && QuietHint.line("5 links", count: 5, hint: "h") == "5 links \u{00B7} h"
                && QuietHint.line("6 links", count: 6, hint: "h") == "6 links"
                && QuietHint.line("Nothing saved yet", count: 0, hint: "h") == "Nothing saved yet",
              "R5-UX-10: the quiet hint shows for the wrong number of items", &ok)
        // Each list page keeps one, from its own empty state's advice.
        let pages: [(file: String, hint: String)] = [
            ("ReadingListController.swift", "pastes a link, or drop one here"),
            ("StickyBoardController.swift", "adds a note, drag one to move it"),
            ("NotebookController.swift", "type [[ to link another page"),
            ("ShiftController.swift", "adds one from any app"),
            ("RunbooksController.swift", "adds another"),
        ]
        for page in pages {
            guard let text = source(page.file) else { fail("R5-UX-10: \(page.file) is not readable", &ok); continue }
            check(text.contains("QuietHint.line(") && text.contains(page.hint),
                  "R5-UX-10: \(page.file) no longer keeps its quiet hint", &ok)
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
        // Copy names a listed door row as the sidebar does.
        withProfile(.personal) {
            check(PlaceName.of(.notebook) == "Notebook" && PlaceName.of(.calendar) == "Calendar",
                  "R5-UX-05: a Personal Notebook is called \(PlaceName.of(.notebook))", &ok)
        }
        withProfile(.operator) {
            check(PlaceName.of(.notebook) == "Knowledge \u{203A} Notebook" && PlaceName.of(.runbooks) == "Runbooks",
                  "R5-UX-05: an Operator's Notebook is called \(PlaceName.of(.notebook))", &ok)
        }
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
