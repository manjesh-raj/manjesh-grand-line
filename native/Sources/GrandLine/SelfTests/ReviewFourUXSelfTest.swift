// Grand Line - native macOS app.
//
// The UX ideas the captain picked from the 2026-11-25 full review (UX-02 to
// UX-28): the half that needs no window.
//
// Each case is one idea's words, model or view, built and laid out without a
// window, so it runs in CI's blocking lane. Where an idea needs real event
// dispatch or the real shell, its check sits in the window-backed suite that
// already mounts that page.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ReviewFourUXSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        var ok = true
        checkTheToolbarNamesItsShortcuts(&ok)
        checkSettingsStaysInReach(&ok)
        checkHomeHealthIsAHeroCard(&ok)
        checkUpdatesGroupByState(&ok)
        checkTheWelcomeShowsEachSidebar(&ok)
        checkTheHostSheetHasTwoColumns(&ok)
        checkTheCrewLogIsATimeline(&ok)
        checkAskTheCrewStartsWithThingsToAsk(&ok)
        checkTheConsoleStartPage(&ok)
        checkTheTaskInspectorWords(&ok)
        print(ok ? "ReviewFourUXSelfTest: all checks passed" : "ReviewFourUXSelfTest: FAILED")
        return ok
    }

    // MARK: UX-25

    /// The three shortcut glyphs are named, their tooltips carry the key, the
    /// first week opens on names, and only the glyph items keep a name.
    private static func checkTheToolbarNamesItsShortcuts(_ ok: inout Bool) {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 24 * 60 * 60
        check(WorkspaceToolbar.defaultDisplayMode(saved: nil, labelsWeekStart: start, now: start + 3 * day) == .iconAndLabel,
              "UX-25: the first week does not open on names", &ok)
        check(WorkspaceToolbar.defaultDisplayMode(saved: nil, labelsWeekStart: start, now: start + 8 * day) == .iconOnly,
              "UX-25: names still show after the first week", &ok)
        check(WorkspaceToolbar.defaultDisplayMode(saved: nil, labelsWeekStart: nil, now: start) == .iconOnly,
              "UX-25: a launch that never started the week shows names", &ok)
        check(WorkspaceToolbar.defaultDisplayMode(saved: Int(NSToolbar.DisplayMode.iconOnly.rawValue),
                                                  labelsWeekStart: start, now: start + day) == .iconOnly,
              "UX-25: a mode the captain chose lost to the first week", &ok)

        let hidden: Set<WorkspaceModule> = []
        let chord = WorkspaceGoMenu.chordText(for: .console, hidden: hidden)
        check(chord != nil && WorkspaceToolbar.shortcutHelp("Go", module: .console, hidden: hidden) == "Go (\(chord ?? ""))",
              "UX-25: Console's tooltip does not end on its key", &ok)
        check(WorkspaceToolbar.shortcutHelp("Open", module: .calendar, hidden: hidden) == "Open (\u{2318}0)",
              "UX-25: the Calendar's tooltip does not name \u{2318}0", &ok)

        let toolbar = WorkspaceToolbar(splitView: NSSplitView(), identifier: "ux25.probe.\(UUID().uuidString)")
        toolbar.toolbar.displayMode = .iconOnly
        let ids: [NSToolbarItem.Identifier] = [WorkspaceToolbar.ItemID.quickConnectConsole,
                                                WorkspaceToolbar.ItemID.quickConnectHosts,
                                                WorkspaceToolbar.ItemID.calendar, WorkspaceToolbar.ItemID.crumb,
                                                WorkspaceToolbar.ItemID.search]
        for id in ids { toolbar.toolbar.insertItem(withItemIdentifier: id, at: toolbar.toolbar.items.count) }
        let items = Dictionary(uniqueKeysWithValues: toolbar.toolbar.items.map { ($0.itemIdentifier, $0) })
        check(items[WorkspaceToolbar.ItemID.quickConnectConsole]?.label == "Console"
                && items[WorkspaceToolbar.ItemID.quickConnectHosts]?.label == "Connections"
                && items[WorkspaceToolbar.ItemID.calendar]?.label == "Calendar",
              "UX-25: the shortcuts are named \(ids.prefix(3).map { items[$0]?.label ?? "-" })", &ok)
        check((items[WorkspaceToolbar.ItemID.quickConnectConsole]?.toolTip ?? "").hasSuffix("(\(chord ?? "?"))")
                && (items[WorkspaceToolbar.ItemID.calendar]?.toolTip ?? "").hasSuffix("(\u{2318}0)"),
              "UX-25: the shortcuts' tooltips do not carry their keys", &ok)
        check(items[WorkspaceToolbar.ItemID.crumb]?.label == "Location",
              "UX-25: icon mode put away the crumb's name, which the overflow menu reads", &ok)
        toolbar.toolbar.displayMode = .iconAndLabel
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(items[WorkspaceToolbar.ItemID.crumb]?.label == "" && items[WorkspaceToolbar.ItemID.search]?.label == ""
                && items[WorkspaceToolbar.ItemID.quickConnectConsole]?.label == "Console",
              "UX-25: Icon and Text names the crumb and Search, or drops Console's name", &ok)
        toolbar.toolbar.displayMode = .iconOnly
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(items[WorkspaceToolbar.ItemID.crumb]?.label == "Location" && items[WorkspaceToolbar.ItemID.search]?.label == "Search",
              "UX-25: going back to icons did not give the view items their names back", &ok)
    }

    // MARK: UX-28

    /// Settings sits in the sidebar's foot, out of the list, lit when it
    /// shows and lined up with the rows above; the list fades only while it
    /// continues below.
    private static func checkSettingsStaysInReach(_ ok: inout Bool) {
        let roots = WorkspaceSidebarModel.roots(sessions: [])
        let listed = roots.flatMap { [$0] + $0.children }.map(\.entry)
        check(!listed.contains(.module(.settings)) && listed.contains(.module(.setup)),
              "UX-28: Settings is still a row in the list, or Setup left with it", &ok)
        check(WorkspaceGoMenu.chord(for: .settings) == WorkspaceGoMenu.chord(for: .settings, hidden: []),
              "UX-28: the foot moved Settings' chord", &ok)

        autoreleasepool {
            let sidebar = WorkspaceSidebarController()
            sidebar.loadView()
            sidebar.view.frame = NSRect(x: 0, y: 0, width: MainSplitShellController.sidebarWidth, height: 360)
            sidebar.view.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            let foot = sidebar.debugFoot
            check(foot.frame.minY <= HelmMetrics.s2 + 0.5 && foot.frame.height > 0,
                  "UX-28: the foot is not at the sidebar's bottom (\(foot.frame))", &ok)
            check(sidebar.debugListFades, "UX-28: a list that continues below does not fade", &ok)
            // The foot's glyph lines up with the rows' glyphs.
            if let row = sidebar.debugCell(for: .module(.home)) as? WorkspaceSidebarPageCell {
                let listX = row.debugIcon.convert(row.debugIcon.bounds, to: sidebar.view).minX
                let footX = foot.debugCell.debugIcon.convert(foot.debugCell.debugIcon.bounds, to: sidebar.view).minX
                check(abs(listX - footX) < 1, "UX-28: the foot's glyph is at x \(footX), the rows' at \(listX)", &ok)
            } else {
                fail("UX-28: the list built no Home row", &ok)
            }
            let scroll = sidebar.debugScrollView
            let documentHeight = sidebar.outlineView.frame.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            sidebar.viewDidLayout()
            check(!sidebar.debugListFades, "UX-28: the list still fades scrolled to its end", &ok)
            sidebar.select(.rail(.settings))
            check(foot.debugIsLit && sidebar.outlineView.selectedRow < 0,
                  "UX-28: showing Settings does not light the foot, or lights a list row too", &ok)
            sidebar.select(.rail(.homeCanvas))
            check(!foot.debugIsLit, "UX-28: the foot stays lit on Home", &ok)
            var opened: WorkspaceModule?
            sidebar.onSelectModule = { opened = $0 }
            foot.row.performPrimaryAction()
            check(opened == .settings, "UX-28: the foot did not open Settings", &ok)
        }
    }

    // MARK: UX-02

    /// Home's Health card says one verdict, names each service that needs a
    /// look, and is the short tile when nothing does.
    private static func checkHomeHealthIsAHeroCard(_ ok: inout Bool) {
        let now = Date()
        func entry(_ service: HealthService, success: Bool = true, failures: Int = 0) -> ServiceHealthSummary.Entry {
            var state = ServiceHealthState()
            if success { state.lastSuccess = now.addingTimeInterval(-60) }
            if failures > 0 {
                state.consecutiveFailures = failures
                state.lastFailure = now.addingTimeInterval(-30)
                state.lastFailureDetail = "no"
            }
            return ServiceHealthSummary.Entry(service: service, state: state)
        }
        let failing = HomeCanvasController.healthHero(ServiceHealthSummary([
            entry(.fleetTasks), entry(.persistence), entry(.dotfilesAutoSync, failures: 3),
            entry(.docsSync, success: false),
        ]))
        check(failing.headline == "1 service needs a look" && failing.body == "2 healthy, 1 not run yet"
                && failing.rows == [.init(service: .dotfilesAutoSync, detail: "failed 3 runs in a row")]
                && failing.chip == .bad("1 failing") && failing.ring?.state == .bad && failing.ring?.label == "2/4",
              "UX-02: a failing service reads \(failing)", &ok)
        let healthy = HomeCanvasController.healthHero(ServiceHealthSummary([entry(.fleetTasks), entry(.persistence)]))
        check(healthy.rows.isEmpty && healthy.headline == "All 2 services healthy" && healthy.body == nil
                && healthy.chip == nil && healthy.ring?.state == .ok,
              "UX-02: a healthy summary reads \(healthy)", &ok)
        let unknown = HomeCanvasController.healthHero(ServiceHealthSummary())
        check(unknown.isUnknown && unknown.ring == nil, "UX-02: nothing reported is not the dimmed tile (GL-14)", &ok)

        // A hero with no figures draws no strip and no rule over nothing.
        autoreleasepool {
            let card = HelmModuleCard()
            var content = HelmModuleCard.Content(title: "Health", subtitle: "", symbol: "heart",
                                                 hue: .green, chip: nil, body: .heroSummary(.init(
                headline: "All 2 services healthy", body: nil, ring: healthy.ring, items: [],
                layout: .standard)))
            content.hero = .init(colour: .themeAccent)
            card.configure(content)
            card.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
            card.layoutSubtreeIfNeeded()
            check(card.debugKPIStrip?.superview == nil, "UX-02: the healthy tile still draws an empty strip", &ok)
        }
    }

    // MARK: UX-22

    /// Each state lands in one group, in the order a captain acts on them,
    /// and only the groups with something to do carry an action.
    private static func checkUpdatesGroupByState(_ ok: inout Bool) {
        let statuses: [DependencyStatus] = [.unknown, .checking, .upToDate, .updateAvailable, .notInstalled,
                                            .checkFailed, .updating, .updateFailed]
        check(statuses.map(UpdatesGroup.init) == [.notChecked, .notChecked, .upToDate, .updateAvailable,
                                                    .notInstalled, .couldNotCheck, .notChecked, .updateAvailable],
              "UX-22: the states group as \(statuses.map(UpdatesGroup.init))", &ok)
        check(UpdatesGroup.allCases == [.updateAvailable, .notInstalled, .couldNotCheck, .notChecked, .upToDate],
              "UX-22: the groups are not in the order a captain acts on them", &ok)
        check(UpdatesGroup.actionTitle(.notInstalled, count: 7, setupName: "Setup steps") == "Install 7 in Setup steps"
                && UpdatesGroup.actionTitle(.updateAvailable, count: 2, setupName: "x") == "Update 2"
                && UpdatesGroup.actionTitle(.couldNotCheck, count: 3, setupName: "x") == "Check again"
                && UpdatesGroup.actionTitle(.upToDate, count: 3, setupName: "x") == nil
                && UpdatesGroup.actionTitle(.notChecked, count: 3, setupName: "x") == nil,
              "UX-22: the group actions are wrong", &ok)
    }

    // MARK: UX-24

    /// Each profile's card pictures the sidebar it gives, every listed module
    /// once in the sidebar's order, and the step's words are on the gradient.
    private static func checkTheWelcomeShowsEachSidebar(_ ok: inout Bool) {
        for profile in WorkspaceProfile.allCases {
            let lines = WelcomeSheetController.sidebarPreviewLines(for: profile)
            let names = lines.flatMap { $0.components(separatedBy: " \u{00B7} ") }
            let listed = WorkspaceSidebarModel.listedModules(hidden: profile.hiddenModules).map(\.title)
            check(names == listed && lines.first == "Home"
                    && lines.allSatisfy { $0.components(separatedBy: " \u{00B7} ").count <= WelcomeSheetController.previewPerLine },
                  "UX-24: \(profile.title)'s preview reads \(lines), want \(listed)", &ok)
        }
        autoreleasepool {
            let sheet = WelcomeSheetController()
            sheet.loadView()
            sheet.view.layoutSubtreeIfNeeded()
            func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
                view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + all(type, in: $0) }
            }
            let cards = all(HelmChoiceCard.self, in: sheet.view)
            check(cards.count == WorkspaceProfile.allCases.count && cards.allSatisfy { $0.accessory is WelcomeSidebarPreview },
                  "UX-24: a profile card has no sidebar preview", &ok)
            check(!all(HelmHeroSurface.self, in: sheet.view).isEmpty, "UX-24: the welcome sheet has no hero head", &ok)
        }
    }

    // MARK: UX-26

    /// The Add Host sheet is 560pt wide, with the connection on the left and
    /// the authentication on the right, top-aligned.
    private static func checkTheHostSheetHasTwoColumns(_ ok: inout Bool) {
        autoreleasepool {
            let editor = HostEditorController(host: nil, keyStore: SSHKeyStore(), snippets: [], presentation: .sheet)
            editor.loadView()
            editor.view.layoutSubtreeIfNeeded()
            check(abs(editor.view.frame.width - HostEditorController.sheetWidth) < 0.5,
                  "UX-26: the sheet is \(editor.view.frame.width)pt wide", &ok)
            let address = editor.debugAddressField.convert(editor.debugAddressField.bounds, to: editor.view)
            let name = editor.debugLabelField.convert(editor.debugLabelField.bounds, to: editor.view)
            let keys = editor.debugKeyPicker.convert(editor.debugKeyPicker.bounds, to: editor.view)
            check(keys.minX > address.maxX && keys.width > 150 && address.width > 150,
                  "UX-26: authentication (\(keys)) is not beside the connection (\(address))", &ok)
            check(abs(name.height - address.height) < 1 && abs(address.minY - name.minY) < 90,
                  "UX-26: the name field (\(name)) is not a field like the address (\(address))", &ok)
        }
    }

    // MARK: UX-07

    /// One line per event under its day and hour, a run of the same thing
    /// folded and opened by its id, and the Today scope beside All.
    private static func checkTheCrewLogIsATimeline(_ ok: inout Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        func event(_ title: String, minutesAgo: Double, kind: FleetLogEventKind = .task) -> FleetLogEvent {
            FleetLogEvent(id: title, date: noon.addingTimeInterval(-minutesAgo * 60), kind: kind, title: title)
        }
        let events = [
            event("Completed \"Renew the TLS certificate\"", minutesAgo: 0),
            event("Created \"A\"", minutesAgo: 100), event("Created \"B\"", minutesAgo: 100.5),
            event("Created \"C\"", minutesAgo: 101), event("Created \"D\"", minutesAgo: 101.5),
            event("Created project \"Infra\"", minutesAgo: 102), event("Created project \"Release\"", minutesAgo: 102.5),
            event("Merged PR #12", minutesAgo: 103, kind: .merge),
        ]
        let rows = FleetLogFeed.timelineRows(for: events, reference: noon, calendar: calendar)
        let shape = rows.map { row -> String in
            switch row {
            case .day(let text): return "day \(text)"
            case .hour: return "hour"
            case .event(let event): return "event \(event.title)"
            case .run(let run): return "run \(run.text)"
            }
        }
        check(shape == ["day Today", "hour", "event Completed \"Renew the TLS certificate\"", "hour",
                        "run Created 4 tasks", "run Created 2 projects: Infra, Release", "event Merged PR #12"],
              "UX-07: the timeline reads \(shape)", &ok)
        let opened = FleetLogFeed.timelineRows(for: events, expanded: ["Created \"A\""], reference: noon, calendar: calendar)
        check(opened.count == rows.count + 4, "UX-07: Show all did not open the run's four events in place", &ok)
        check(FleetLogFeed.parse("Merged PR #12") == nil && FleetLogFeed.parse("Created follow-up \"Ping\"")?.noun == "follow-up",
              "UX-07: the activity lines parse wrongly", &ok)

        var reading = CrewHeroWords.LogReading()
        reading.hasRead = true
        reading.counts = [.task: 23]
        reading.today = [.task: 15]
        let segments = CrewHeroWords.logSegments(reading)
        check(segments.first?.label == "Today\u{2002}15" && segments.first?.isToday == true
                && segments.dropFirst().first?.label == "All\u{2002}23",
              "UX-07: the scopes read \(segments.prefix(2).map(\.label))", &ok)
        check(FleetLogListView.filterItems.prefix(2).map(\.id) == [FleetLogListView.todayFilterID, FleetLogListView.allFilterID],
              "UX-07: the filter does not open on Today and All", &ok)
    }

    // MARK: UX-08

    /// Six starters from the captain's own data, a role under every
    /// portrait, and a starter fills the composer rather than sending.
    private static func checkAskTheCrewStartsWithThingsToAsk(_ ok: inout Bool) {
        let busy = StrawHatStarters.make(.init(openTasks: 7, overdueTasks: 1, dueToday: 1, pendingFollowUps: 2,
                                               failingService: "Docs & runbooks sync", servicesReporting: 8, schedules: 3))
        check(busy.count == StrawHatStarters.count && busy[0].question == "What is overdue, and what can wait?"
                && busy[0].detail == "From your 7 open tasks"
                && busy[2].question == "Why does Docs & runbooks sync keep failing?"
                && busy[4].detail == "From your 2 follow-ups",
              "UX-08: a busy captain's starters read \(busy.map(\.question))", &ok)
        let quiet = StrawHatStarters.make(.init())
        check(quiet.count == StrawHatStarters.count && !quiet.contains { $0.detail.contains(" 0 ") },
              "UX-08: a new captain's starters count zeros: \(quiet.map(\.detail))", &ok)
        check(Set(StrawHatMember.allCases.map(\.roleWord)).count == StrawHatMember.allCases.count
                && StrawHatMember.allCases.allSatisfy { !$0.roleWord.contains(" ") },
              "UX-08: a crew member's role is not one word of its own", &ok)
        autoreleasepool {
            let chat = StrawHatChatView()
            chat.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            chat.setStarters(busy)
            chat.layoutSubtreeIfNeeded()
            check(!chat.debugStarterGrid.isHidden && chat.debugEmptyStateHidden && chat.debugStarterGrid.debugCards.count == 6,
                  "UX-08: the empty thread does not show six starters in place of the paragraph", &ok)
            chat.debugStarterGrid.debugPick(1)
            check(chat.debugComposerText == busy[1].question, "UX-08: a starter did not fill the composer", &ok)
        }
    }

    // MARK: UX-11

    /// The hosts connected to most recently, newest first; the tiles and the
    /// snippets do what they say; Return opens the first.
    private static func checkTheConsoleStartPage(_ ok: inout Bool) {
        let now = Date()
        func host(_ label: String, daysAgo: Double?) -> Host {
            var h = Host(label: label, address: "\(label).example.test")
            h.lastConnectedAt = daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
            return h
        }
        let tiles = ConsoleStartWords.hosts([host("old", daysAgo: 9), host("never", daysAgo: nil), host("new", daysAgo: 1),
                                             host("mid", daysAgo: 3), host("older", daysAgo: 20)], now: now)
        check(tiles.map(\.title) == ["new", "mid", "old"] && tiles.first?.detail.hasPrefix("connected ") == true,
              "UX-11: the start page's hosts are \(tiles.map(\.title))", &ok)
        autoreleasepool {
            let page = ConsoleStartPage()
            var did: [String] = []
            page.onNewShell = { did.append("shell") }
            page.onHost = { _ in did.append("host") }
            page.onSnippet = { did.append("snippet \($0.label)") }
            page.configure(hosts: tiles, snippets: [Snippet(label: "Disk usage", command: "du -sh *")])
            check(page.debugTileTitles == ["New shell on this Mac", "new", "mid", "old"] && page.debugSnippetTitles == ["Disk usage"],
                  "UX-11: the start page offers \(page.debugTileTitles) and \(page.debugSnippetTitles)", &ok)
            page.debugClickTile(1)
            page.debugClickSnippet(0)
            if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36) {
                page.keyDown(with: enter)
            }
            check(did == ["host", "snippet Disk usage", "shell"], "UX-11: the start page did \(did)", &ok)
        }
    }

    // MARK: UX-04

    /// The inspector's chips and activity, against a pinned local noon.
    private static func checkTheTaskInspectorWords(_ ok: inout Bool) {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                 of: calendar.date(from: DateComponents(year: 2026, month: 11, day: 26)) ?? Date()) ?? Date()
        func day(_ offset: Int) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: offset, to: noon) ?? noon)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        var task = ShiftTask.fresh(now: noon)
        task.dueDate = day(0)
        task.dueTime = "15:00"
        let today = TaskInspectorWords.dueChip(task, now: noon, calendar: calendar)
        check(today.text == "Today " + ShiftDateFormatting.clock("15:00") && today.tint == .warn,
              "UX-04: a task due later today reads \(today.text) in \(String(describing: today.tint))", &ok)
        task.dueDate = day(-2)
        task.dueTime = nil
        let late = TaskInspectorWords.dueChip(task, now: noon, calendar: calendar)
        check(late.text == "Overdue 2 days" && late.tint == .critical, "UX-04: two days late reads \(late.text)", &ok)
        task.dueDate = day(1)
        check(TaskInspectorWords.dueChip(task, now: noon, calendar: calendar).text == "Tomorrow",
              "UX-04: tomorrow does not read Tomorrow", &ok)
        task.dueDate = nil
        check(TaskInspectorWords.dueChip(task, now: noon, calendar: calendar) .text == "No date",
              "UX-04: no date does not say so", &ok)
        check(TaskInspectorWords.priorityChip(.high).tint == .critical && TaskInspectorWords.priorityChip(.normal).tint == nil,
              "UX-04: only High carries a hue", &ok)
        check(TaskInspectorWords.checklistKicker([]) == "Checklist"
                && TaskInspectorWords.checklistKicker([.init(id: "a", title: "a", done: true),
                                                      .init(id: "b", title: "b", done: false)]) == "Checklist \u{00B7} 1 of 2",
              "UX-04: the checklist kicker does not count", &ok)

        task.createdAt = ShiftStore.iso8601(calendar.date(byAdding: .day, value: -3, to: noon) ?? noon)
        func entry(_ kind: String, _ offset: Int, seconds: Int? = nil, target: String? = nil) -> ShiftActivityEntry {
            ShiftActivityEntry(id: UUID().uuidString,
                               timestamp: ShiftStore.iso8601(calendar.date(byAdding: .day, value: offset, to: noon) ?? noon),
                               kind: kind, summary: "", targetID: target ?? task.id, durationSeconds: seconds)
        }
        let entries = [entry(FocusActivityLog.kind, -1, seconds: 1800), entry(FocusActivityLog.kind, 0, seconds: 2400),
                       entry("task_due_date_changed", -1), entry("task_due_date_changed", -2),
                       entry(FocusActivityLog.kind, 0, seconds: 9000, target: "someone-else")]
        let created = ShiftRecurrence.shortWeekdayName(calendar.component(.weekday, from: calendar.date(byAdding: .day, value: -3, to: noon) ?? noon))
        let lines = TaskInspectorWords.activityLines(task: task, entries: entries, unreadable: false, now: noon, calendar: calendar)
        check(lines == ["Focused 1h 10m \u{00B7} today", "Pushed back 2 times", "Created \u{00B7} \(created)"],
              "UX-04: the activity reads \(lines)", &ok)
        // GL-14: an unreadable month is said, never read as no focus time.
        let unread = TaskInspectorWords.activityLines(task: task, entries: [], unreadable: true, now: noon, calendar: calendar)
        check(unread.count == 2 && unread.last?.contains("could not be read") == true,
              "UX-04: an unreadable activity log reads \(unread)", &ok)
    }
}

#endif
