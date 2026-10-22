// Grand Line - native macOS app.
//
// The sidebar layout's badges and status line readouts (`WorkspaceSignals`),
// as pure logic: every honest state of every signal, the words each one says,
// the colours each one paints in every palette, and the source guards that
// keep the monitor a listener.
//
//   1. **A failed read keeps the last good value** (`WorkspaceReading.failing`).
//   2. **Each signal's states**, badge and readout: nothing for unknown, a
//      dash for a first read in flight, the value for a read, the last good
//      value and its time for a failed read, and no badge for a real zero.
//   3. **Tasks due** counts by day, the way compact mode does.
//   4. **Contrast**: an attention pill's digits on its fill, and every
//      attention or alarm mark on the sidebar and the line, clear the text
//      floor in all palettes.
//   5. **Source guards**: the monitor starts no timer, pass or subprocess,
//      takes no one's single closure, and only the sidebar layout builds one;
//      the Fleet page keeps Needs you's bookkeeping in both layouts.
//
// Run with:
//   swift build && FM_RUN_WORKSPACE_SIGNALS_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: values, colours and source text, no window.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum WorkspaceSignalsSelfTest {

    static func run() -> Bool {
        var ok = true
        for check in [checkFailingKeepsTheLastGoodValue, checkCrew, checkTasks, checkTasksCountByDay, checkVault,
                      checkHealth, checkSetup, checkClaude, checkSync, checkConsole, checkContrast,
                      checkTheMonitorOnlyListens] {
            var caseOK = true
            check(&caseOK)
            ok = ok && caseOK
        }
        print(ok ? "WorkspaceSignalsSelfTest: all checks passed" : "WorkspaceSignalsSelfTest: FAILED")
        return ok
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let t1 = t0.addingTimeInterval(600)

    private static func signals(_ edit: (inout WorkspaceSignals) -> Void) -> WorkspaceSignals {
        var s = WorkspaceSignals()
        edit(&s)
        return s
    }

    private static func item(_ id: WorkspaceStatusItem.ID, _ s: WorkspaceSignals, now: Date = t1) -> WorkspaceStatusItem? {
        s.statusItems(now: now).first { $0.id == id }
    }

    // MARK: 1

    private static func checkFailingKeepsTheLastGoodValue(_ ok: inout Bool) {
        print("\n-- a failed read keeps the last good value, and when --")
        let read: WorkspaceReading<Int> = .read(3, at: t0)
        check(read.failing(at: t1) == .failed(last: 3, lastReadAt: t0, failedAt: t1),
              "a read that then fails lost its value: \(read.failing(at: t1))", &ok)
        let twice = read.failing(at: t0.addingTimeInterval(60)).failing(at: t1)
        check(twice == .failed(last: 3, lastReadAt: t0, failedAt: t1),
              "a second failure lost the last good value or its time: \(twice)", &ok)
        check(WorkspaceReading<Int>.reading.failing(at: t1) == .failed(last: nil, lastReadAt: nil, failedAt: t1),
              "a first read that fails invented a value", &ok)
        check(WorkspaceReading<Int>.unknown.value == nil && WorkspaceReading<Int>.reading.value == nil,
              "an unread signal has a value", &ok)
        if ok { print("  OK   read, failed, failed again, and a first read that fails") }
    }

    // MARK: 2

    private static func checkCrew(_ ok: inout Bool) {
        print("\n-- Crew: the badge and the readout in every state --")
        let unknown = signals { $0.crew = .unknown }
        check(unknown.badge(for: .crew) == nil && item(.crew, unknown) == nil,
              "a crew nobody can read (no firstmate home) drew something", &ok)

        let reading = signals { $0.crew = .reading }
        check(reading.badge(for: .crew)?.mark == .count(WorkspaceSignals.scanningMark),
              "the first read in flight is not a dash: \(String(describing: reading.badge(for: .crew)))", &ok)
        check(item(.crew, reading)?.text == "Crew \u{2013} scanning", "the line while reading says \(item(.crew, reading)?.text ?? "nothing")", &ok)

        let two = signals { $0.crew = .read(2, at: t0) }
        let badge = two.badge(for: .crew)
        check(badge == WorkspaceBadge(mark: .count("2"), tone: .attention, description: "2 tasks are waiting on you"),
              "two waiting drew \(String(describing: badge))", &ok)
        check(item(.crew, two)?.text == "2 need you" && item(.crew, two)?.lead == .dot(.attention, quiet: false),
              "two waiting read \(item(.crew, two)?.text ?? "nothing")", &ok)
        check(item(.crew, two)?.destination == .overview, "the crew readout does not open Crew", &ok)

        let clear = signals { $0.crew = .read(0, at: t0) }
        check(clear.badge(for: .crew) == nil, "a real zero drew a badge", &ok)
        check(item(.crew, clear)?.text == "Crew all clear", "nothing waiting read \(item(.crew, clear)?.text ?? "nothing")", &ok)

        let stale = signals { $0.crew = .failed(last: 2, lastReadAt: t0, failedAt: t1) }
        check(stale.badge(for: .crew)?.mark == .count("2"), "a failed read dropped the last good count", &ok)
        let staleDescription = stale.badge(for: .crew)?.description ?? ""
        check(staleDescription.contains(WorkspaceSignals.clock(t0)) && staleDescription.contains("Couldn\u{2019}t read"),
              "a failed read's badge does not say when it was last read: \(staleDescription)", &ok)
        check(item(.crew, stale)?.text == "2 need you \u{00B7} as of \(WorkspaceSignals.clock(t0))",
              "a failed read's readout is \(item(.crew, stale)?.text ?? "nothing")", &ok)

        let never = signals { $0.crew = .failed(last: nil, lastReadAt: nil, failedAt: t1) }
        check(never.badge(for: .crew)?.mark == .count("?") && item(.crew, never)?.text == "Crew unreadable",
              "a failed first read is not stated as one", &ok)

        // Needs you's own reading, mapped: before the first read, with no
        // firstmate home, read, and failed with and without a good read.
        func mapped(hasRead: Bool = true, homeOk: Bool = true, waiting: Int = 2, readAt: Date? = t0,
                     failed: Bool = false) -> WorkspaceReading<Int> {
            WorkspaceSignalsMonitor.crewReading(from: FleetNeedsYouReading(
                hasRead: hasRead, homeOk: homeOk, waiting: waiting, readAt: readAt, checkedAt: t1, readFailed: failed))
        }
        check(mapped(hasRead: false) == .reading, "before the first read the crew is not reading", &ok)
        check(mapped(homeOk: false) == .unknown, "with no firstmate home the crew is not unknown", &ok)
        check(mapped() == .read(2, at: t0), "a read maps to \(mapped())", &ok)
        check(mapped(failed: true) == .failed(last: 2, lastReadAt: t0, failedAt: t1),
              "a failed read after a good one maps to \(mapped(failed: true))", &ok)
        check(mapped(readAt: nil, failed: true) == .failed(last: nil, lastReadAt: nil, failedAt: t1),
              "a failed first read invented a count", &ok)
        if ok { print("  OK   unknown, reading, read, zero, failed with and without a last good value") }
    }

    private static func checkTasks(_ ok: inout Bool) {
        print("\n-- Tasks: due today and overdue --")
        let none = signals { $0.tasksDue = .read(.init(today: 0, overdue: 0), at: t0) }
        check(none.badge(for: .tasks) == nil, "nothing due drew a badge", &ok)
        let due = signals { $0.tasksDue = .read(.init(today: 2, overdue: 1), at: t0) }
        check(due.badge(for: .tasks) == WorkspaceBadge(mark: .count("3"), tone: .neutral, description: "2 due today, 1 overdue"),
              "two due and one overdue drew \(String(describing: due.badge(for: .tasks)))", &ok)
        let stale = signals { $0.tasksDue = .failed(last: .init(today: 1, overdue: 0), lastReadAt: t0, failedAt: t1) }
        check(stale.badge(for: .tasks)?.mark == .count("1")
              && (stale.badge(for: .tasks)?.description.contains(WorkspaceSignals.clock(t0)) ?? false),
              "a failed read did not keep the last count and its time", &ok)
        check(signals { $0.tasksDue = .unknown }.badge(for: .tasks) == nil, "an unread store drew a badge", &ok)
        if ok { print("  OK   zero, a count with its words, and a failed read") }
    }

    private static func checkTasksCountByDay(_ ok: inout Bool) {
        print("\n-- Tasks due counts by day, the way compact mode does --")
        // Local noon, so no runner's time zone puts the fixture on a boundary
        // (AGENTS.md, "Writing a self-test").
        let calendar = Calendar.current
        guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: t0),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: noon),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon) else {
            fail("could not build the fixture days", &ok)
            return
        }
        // The store's own day format, which `ShiftDateFormatting.date(from:)`
        // reads back at local midnight.
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.calendar = Calendar(identifier: .gregorian)
        func task(_ due: Date?, status: ShiftTaskStatus = .todo) -> ShiftTask {
            var task = ShiftTask.fresh()
            task.dueDate = due.map(day.string(from:))
            task.status = status
            return task
        }
        let tasks = [task(noon), task(noon), task(yesterday), task(tomorrow), task(nil),
                     task(noon, status: .completed), task(yesterday, status: .cancelled)]
        let counts = CompactModeDigest.dueCounts(tasks: tasks, now: noon, calendar: calendar)
        check(counts.today == 2 && counts.overdue == 1,
              "two due today and one overdue counted as \(counts.today) and \(counts.overdue)", &ok)
        let digest = CompactModeDigest.today(tasks: tasks, followUps: [], focusSecondsToday: 0, now: noon, calendar: calendar)
        check(digest.overdueCount == counts.overdue, "the badge and compact mode disagree about overdue", &ok)
        if ok { print("  OK   today, overdue, later, undated and finished tasks") }
    }

    private static func checkVault(_ ok: inout Bool) {
        print("\n-- Secrets: Poneglyph's lock --")
        check(signals { $0.vault = .none }.badge(for: .secrets) == nil && item(.vault, signals { $0.vault = .none }) == nil,
              "a Mac with no vault drew a lock", &ok)
        let locked = signals { $0.vault = .locked }
        check(locked.badge(for: .secrets) == WorkspaceBadge(mark: .symbol("lock.fill"), tone: .neutral, description: "Poneglyph is locked"),
              "a locked vault drew \(String(describing: locked.badge(for: .secrets)))", &ok)
        check(item(.vault, locked)?.text == "Poneglyph locked" && item(.vault, locked)?.destination == .poneglyph,
              "a locked vault's readout is \(item(.vault, locked)?.text ?? "nothing")", &ok)
        let unlocked = signals { $0.vault = .unlocked }
        check(unlocked.badge(for: .secrets) == nil && item(.vault, unlocked)?.text == "Poneglyph unlocked",
              "an unlocked vault drew a badge or no readout", &ok)
        let unreadable = signals { $0.vault = .unreadable }
        check(unreadable.badge(for: .secrets)?.tone == .alarm && item(.vault, unreadable)?.text == "Poneglyph unreadable",
              "an unreadable vault file is not an alarm", &ok)
        if ok { print("  OK   none, locked, unlocked and unreadable") }
    }

    private static func checkHealth(_ ok: inout Bool) {
        print("\n-- Health: a failing service --")
        let docs = WorkspaceSignals.ServiceIssue(title: HealthService.docsSync.title, failures: 3, lastFailure: t0)
        let tasks = WorkspaceSignals.ServiceIssue(title: HealthService.shiftGitSync.title, failures: 4, lastFailure: t1)
        let one = signals { $0.failingServices = [docs] }
        check(one.badge(for: .health)?.mark == .dot && one.badge(for: .health)?.tone == .alarm,
              "a failing service is not an alarm dot", &ok)
        check(item(.health, one)?.text == "Docs & runbooks sync failing" && item(.health, one)?.destination == .health,
              "one failing service read \(item(.health, one)?.text ?? "nothing")", &ok)
        let two = signals { $0.failingServices = [docs, tasks] }
        check(item(.health, two)?.text == "2 services failing", "two failing read \(item(.health, two)?.text ?? "nothing")", &ok)
        check(item(.health, two)?.toolTip.contains(WorkspaceSignals.clock(t1)) == true,
              "the readout does not say when the last failure was", &ok)
        let degraded = signals { $0.degradedServices = [docs] }
        check(degraded.badge(for: .health)?.tone == .attention && item(.health, degraded) == nil,
              "a degraded service is an alarm, or is on the line", &ok)
        check(WorkspaceSignals().badge(for: .health) == nil && item(.health, WorkspaceSignals()) == nil,
              "a healthy app drew a Health mark", &ok)
        if ok { print("  OK   failing, two failing, degraded, healthy") }
    }

    private static func checkSetup(_ ok: inout Bool) {
        print("\n-- Setup: updates and drift --")
        check(signals { $0.setup = .unknown }.badge(for: .setup) == nil, "an unchecked Setup drew a badge", &ok)
        check(signals { $0.setup = .reading }.badge(for: .setup)?.mark == .count(WorkspaceSignals.scanningMark),
              "a first check in flight is not a dash", &ok)
        let counts = WorkspaceSignals.SetupCounts(toolUpdates: 2, setupDrift: nil, forkDrift: 1)
        let read = signals { $0.setup = .read(counts, at: t0) }
        check(read.badge(for: .setup)?.mark == .count("3"), "two updates and a fork behind drew \(String(describing: read.badge(for: .setup)))", &ok)
        check(read.badge(for: .setup)?.description == "2 tool updates, 1 fork behind, setup drift not checked yet",
              "Setup's badge does not say which checks it counts: \(read.badge(for: .setup)?.description ?? "")", &ok)
        let zero = signals { $0.setup = .read(.init(toolUpdates: 0, setupDrift: 0, forkDrift: 0), at: t0) }
        check(zero.badge(for: .setup) == nil, "nothing to do drew a badge", &ok)
        let stale = signals { $0.setup = .failed(last: counts, lastReadAt: t0, failedAt: t1) }
        check(stale.badge(for: .setup)?.mark == .count("3")
              && (stale.badge(for: .setup)?.description.contains(WorkspaceSignals.clock(t1)) ?? false),
              "a failed check dropped the count or did not say when it failed", &ok)
        if ok { print("  OK   unknown, checking, counted with its parts, zero, failed") }
    }

    private static func checkClaude(_ ok: inout Bool) {
        print("\n-- Claude usage --")
        check(item(.claude, signals { $0.claude = .unknown }) == nil, "unread Claude usage drew a readout", &ok)
        check(item(.claude, signals { $0.claude = .reading })?.text == "Claude \u{2013} scanning", "reading Claude usage is not a dash", &ok)
        let usage = WorkspaceSignals.ClaudeUsage(percentUsed: 61.6, resetsAt: nil)
        let read = signals { $0.claude = .read(usage, at: t0) }
        check(item(.claude, read)?.text == "Claude 62% of 5 h", "a reading read \(item(.claude, read)?.text ?? "nothing")", &ok)
        check(item(.claude, read)?.trailing == true, "Claude usage is not in the line's right-hand group", &ok)
        let stale = signals { $0.claude = .failed(last: usage, lastReadAt: t0, failedAt: t1) }
        check(item(.claude, stale)?.text == "Claude 62% of 5 h \u{00B7} as of \(WorkspaceSignals.clock(t0))",
              "a failed reading read \(item(.claude, stale)?.text ?? "nothing")", &ok)
        let never = signals { $0.claude = .failed(last: nil, lastReadAt: nil, failedAt: t1) }
        check(item(.claude, never)?.text == "Claude usage unavailable", "a failed first reading is not stated as one", &ok)
        if ok { print("  OK   unknown, reading, read, failed with and without a last reading") }
    }

    private static func checkSync(_ ok: inout Bool) {
        print("\n-- Tasks sync --")
        check(item(.sync, WorkspaceSignals()) == nil, "a Tasks store with no reported sync drew a readout", &ok)
        let synced = signals { $0.sync = .init(status: .synced, lastSuccess: t0) }
        check(item(.sync, synced, now: t0.addingTimeInterval(4 * 60 + 5))?.text == "Synced 4 min ago",
              "a sync four minutes ago read \(item(.sync, synced, now: t0.addingTimeInterval(245))?.text ?? "nothing")", &ok)
        check(item(.sync, synced, now: t0.addingTimeInterval(20))?.text == "Synced just now", "a fresh sync is not \"just now\"", &ok)
        check(item(.sync, synced, now: t0.addingTimeInterval(2 * 3600 + 1))?.text == "Synced 2 h ago", "two hours is not \"2 h ago\"", &ok)
        let failed = signals { $0.sync = .init(status: .failed("fatal: refusing to merge"), lastSuccess: t0) }
        check(item(.sync, failed)?.text == "Sync failed" && item(.sync, failed)?.lead == .dot(.alarm, quiet: false),
              "a failed sync is not an alarm", &ok)
        check(item(.sync, failed)?.toolTip.contains(WorkspaceSignals.clock(t0)) == true, "a failed sync does not say when it last synced", &ok)
        let offline = signals { $0.sync = .init(status: .failed("Could not resolve host: github.com"), lastSuccess: t0) }
        check(item(.sync, offline)?.lead == .dot(.neutral, quiet: true), "being offline is an alarm, which the Tasks pill says it is not", &ok)
        check(item(.sync, synced)?.destination == .shift, "the sync readout does not open Tasks", &ok)
        if ok { print("  OK   unreported, synced and its age, failed, offline") }
    }

    private static func checkConsole(_ ok: inout Bool) {
        print("\n-- Console: live sessions --")
        check(WorkspaceSignals().badge(for: .console) == nil, "no sessions drew a badge", &ok)
        check(signals { $0.liveSessions = 2 }.badge(for: .console) == WorkspaceBadge(mark: .count("2"), tone: .neutral, description: "2 connected"),
              "two live sessions drew the wrong badge", &ok)
        for module in WorkspaceModule.allCases where ![.crew, .tasks, .secrets, .health, .setup, .console].contains(module) {
            let loud = signals {
                $0.crew = .read(5, at: t0); $0.liveSessions = 3; $0.vault = .locked
                $0.failingServices = [.init(title: "x", failures: 9, lastFailure: t0)]
            }
            check(loud.badge(for: module) == nil, "\(module.title) drew a badge it has no data for", &ok)
        }
        if ok { print("  OK   and no module without a signal draws one") }
    }

    // MARK: 4

    private static func checkContrast(_ ok: inout Bool) {
        print("\n-- every mark clears the text floor, in every palette --")
        var failures: [String] = []
        for theme in HelmTheme.allThemes {
            let panel = HelmTheme.sidePanelFill(theme)
            let ground = HelmTheme.nsColor(theme.backgroundHex)
            for tone in [WorkspaceBadge.Tone.attention, .alarm] {
                let fill = WorkspaceSidebarBadgeView.pillFill(for: tone, theme: theme)
                let digits = HelmContrast.legibleOn(fill: fill, preferring: WorkspaceSidebarBadgeView.hue(tone, theme))
                let pill = HelmContrast.ratio(digits, fill)
                if pill < HelmContrast.textTarget { failures.append("\(theme.id) \(tone) pill \(String(format: "%.2f", pill))") }
                for (name, surface) in [("sidebar", panel), ("line", ground)] {
                    let mark = HelmContrast.ratio(WorkspaceSidebarBadgeView.ink(for: tone, over: surface, theme: theme), surface)
                    if mark < HelmContrast.textTarget {
                        failures.append("\(theme.id) \(tone) mark on the \(name) \(String(format: "%.2f", mark))")
                    }
                }
            }
        }
        check(failures.isEmpty, "a badge or readout mark is below the text floor: \(failures)", &ok)
        // The fixture can fail: the raw warn hue on its own pill does not
        // clear the floor in every palette, which is why the digits are
        // corrected at all.
        let raw = HelmTheme.allThemes.contains { theme in
            let fill = WorkspaceSidebarBadgeView.pillFill(for: .attention, theme: theme)
            return HelmContrast.ratio(WorkspaceSidebarBadgeView.hue(.attention, theme), fill) < HelmContrast.textTarget
        }
        check(raw, "the raw warn hue clears its pill in every palette, so this check cannot tell a correction from none", &ok)
        if ok { print("  OK   \(HelmTheme.allThemes.count) palettes, attention and alarm, pill and marks") }
    }

    // MARK: 5

    private static func checkTheMonitorOnlyListens(_ ok: inout Bool) {
        print("\n-- the monitor only listens, and only the sidebar layout has one --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP the app's sources are not next to this binary - the source guards did not run")
            return
        }
        func read(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let monitor = read("WorkspaceSignalsMonitor.swift")
        guard !monitor.isEmpty else { fail("WorkspaceSignalsMonitor.swift is missing", &ok); return }
        for banned in ["Timer(", "Timer.scheduled", "Subprocess", "Process(", "DispatchQueue.global", ".refresh", ".fetch"] {
            check(!monitor.contains(banned), "the monitor reaches for \(banned) - it may only listen (GL-13)", &ok)
        }
        check(!monitor.contains("onChange =") && monitor.contains("observeLock"),
              "the monitor takes the vault store's onChange, which is Poneglyph's (ARCH-04)", &ok)
        // Building the vault store starts the vault's git sync, so the badge
        // follows a store something else built and never builds one.
        let builds = monitor.contains("credentialVaultStore")
            || monitor.range(of: #"shared\.vault\b"#, options: .regularExpression) != nil
        check(!builds && monitor.contains("whenVaultIsBuilt"),
              "the monitor builds the vault store, which starts its git sync at launch", &ok)
        for source in ["shiftStore.observe", "ServiceHealthRegistry.shared.observe", "observeCounts", "observeStatus"] {
            check(monitor.contains(source), "the monitor no longer follows \(source)", &ok)
        }
        let builders = (SelfTestSources.appSourceFiles() ?? []).filter { url in
            url.lastPathComponent != "WorkspaceSignalsMonitor.swift"
                && ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("WorkspaceSignalsMonitor(")
        }.map(\.lastPathComponent)
        check(builders == ["MainSplitShellController.swift"],
              "the monitor is built by \(builders), not only by the sidebar layout - the floating bar must not change", &ok)
        let fleet = read("FleetController.swift")
        check(fleet.contains("let carried = noteNeedsYouRead(snapshot, needs: needs)"),
              "the Fleet page's Needs you bookkeeping is no longer run for every read, so Crew's badge waits for a visit", &ok)
        let workspace = read("Workspace.swift")
        check(workspace.contains("chrome?.workspaceCrewDidRead()") && workspace.contains("chrome?.workspaceQuotaDidRead(result)"),
              "the workspace no longer forwards the Fleet page's readings to the shell", &ok)
        if ok { print("  OK   no timer, pass or subprocess; Poneglyph's closure untouched; one builder; both readings forwarded") }
    }
}

#endif
