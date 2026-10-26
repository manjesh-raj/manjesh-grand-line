// Grand Line - native macOS app.
//
// The second full review's accessibility and performance findings
// (R2-A11Y-03 to R2-A11Y-05, R2-PERF-01 to R2-PERF-06): the pure half.
//
// Each case is one finding's words, cache or source guard - everything that
// needs no window, so it runs in CI's blocking lane. The behaviour that does
// need one (a real toolbar, a real outline view, a real resize) is
// `ReviewTwoA11yPerfSelfTest`, window-backed.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ReviewTwoA11yPerfModelSelfTest {

    static func run() -> Bool {
        var ok = true
        checkTheLabelWords(&ok)
        checkTheHealthMarksInWords(&ok)
        checkTheTourTakesATextScale(&ok)
        checkTheUpdatesRecords(&ok)
        checkAVisitRunsNoCheckOnAFreshRecord(&ok)
        print(ok ? "ReviewTwoA11yPerfModelSelfTest: PASS" : "ReviewTwoA11yPerfModelSelfTest: FAIL")
        return ok
    }

    // MARK: Shared

    static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: R2-A11Y-03

    private static func checkTheLabelWords(_ ok: inout Bool) {
        print("\n-- R2-A11Y-03: the words for each state --")
        check(WorkspaceToolbar.sidebarButtonLabel(shown: true) == "Hide Sidebar"
              && WorkspaceToolbar.sidebarButtonLabel(shown: false) == "Show Sidebar",
              "the sidebar button's labels do not say which way it goes", &ok)
        check(WorkspaceToolbar.inspectorLabel(shown: true) == "Hide Inspector"
              && WorkspaceToolbar.inspectorLabel(shown: false) == "Show Inspector",
              "the inspector button's labels do not say which way it goes", &ok)
        check(WorkspaceSidebarHeader.accessibilityLabel == "\(AppPaths.displayName), Log Out",
              "the account header reads \"\(WorkspaceSidebarHeader.accessibilityLabel)\"", &ok)
        var signals = WorkspaceSignals()
        signals.setup = .read(16, at: Date())
        check(signals.badge(for: .setup)?.description == "16 tools need attention",
              "Setup's badge says \"\(signals.badge(for: .setup)?.description ?? "nil")\" for sixteen tools", &ok)
        signals.setup = .read(1, at: Date())
        check(signals.badge(for: .setup)?.description == "1 tool needs attention",
              "Setup's badge says \"\(signals.badge(for: .setup)?.description ?? "nil")\" for one tool", &ok)
        if ok { print("  OK   Hide and Show for both panes, Log Out named, Setup's count has its unit") }
    }

    // MARK: R2-A11Y-04

    private static func checkTheHealthMarksInWords(_ ok: inout Bool) {
        print("\n-- R2-A11Y-04: the run marks and the ring in words --")
        let now = Date()
        var mixed = ServiceHealthState()
        mixed.lastSuccess = now.addingTimeInterval(-600)
        mixed.lastFailure = now
        mixed.consecutiveFailures = 3
        var passing = ServiceHealthState()
        passing.lastSuccess = now
        var failing = ServiceHealthState()
        failing.lastFailure = now
        failing.consecutiveFailures = 2
        var longStreak = mixed
        longStreak.consecutiveFailures = 7
        let cases: [(String, ServiceHealthState, String)] = [
            ("mixed", mixed, "3 failures, 1 success"),
            ("all passing", passing, "1 success"),
            ("all failing", failing, "2 failures"),
            ("never run", ServiceHealthState(), "No runs yet"),
            ("a streak past the cap", longStreak, "5 failures"),
        ]
        for (name, state, want) in cases {
            let spoken = HealthCardView.runTicksSpoken(state)
            check(spoken == want, "\(name): the runs read \"\(spoken)\", want \"\(want)\"", &ok)
            // The words count the marks that are drawn, never a different set.
            let marks = HealthCardView.runTicks(state)
            let crosses = marks.filter { $0 == "\u{2715}" }.count
            let ticks = marks.filter { $0 == "\u{2713}" }.count
            let saidCrosses = crosses == 0 ? !spoken.contains("failure") : spoken.contains("\(crosses) failure")
            let saidTicks = ticks == 0 ? !spoken.contains("success") : spoken.contains("\(ticks) success")
            check(saidCrosses && saidTicks, "\(name): \"\(marks)\" is read as \"\(spoken)\"", &ok)
        }

        typealias Reading = HomeCanvasController.HealthServiceReading
        func reading(_ verdict: ServiceHealthState.Verdict) -> Reading {
            Reading(title: "Service", verdict: verdict, hasReported: verdict != .unknown && verdict != .running)
        }
        let rings: [(String, [Reading], String)] = [
            ("mixed", [reading(.healthy), reading(.healthy), reading(.failing), reading(.degraded)],
             "2 healthy, 1 failing, 1 recent failure"),
            ("all healthy", [reading(.healthy), reading(.healthy), reading(.healthy)], "3 healthy"),
            ("all failing", [reading(.failing), reading(.failing)], "2 failing"),
            ("nothing reported", [], "No background service has reported yet"),
            ("still reporting", [reading(.healthy), reading(.running), reading(.unknown)],
             "1 healthy, 1 checking, 1 not run yet"),
        ]
        for (name, readings, want) in rings {
            let spoken = HomeCanvasController.healthRingSpoken(readings)
            check(spoken == want, "\(name): the Health ring reads \"\(spoken)\", want \"\(want)\"", &ok)
        }
        if ok { print("  OK   runs and ring read as counts with their words: mixed, all passing, all failing, empty") }
    }

    // MARK: R2-A11Y-05

    /// The Larger render is one tour line, by the names Settings offers.
    private static func checkTheTourTakesATextScale(_ ok: inout Bool) {
        print("\n-- R2-A11Y-05: the tour's textscale line --")
        for (name, scale) in ChromeTextScale.steps {
            let parsed = ReviewTourLab.parse(line: "textscale \(name.lowercased())")
            check(parsed == .success(.textScale(scale)), "\"textscale \(name.lowercased())\" parsed as \(parsed)", &ok)
        }
        check(ReviewTourLab.parse(line: "textscale huge") == .failure(.badArgument("huge")),
              "an unknown scale name was accepted", &ok)
        check(ReviewTourLab.parse(line: "textscale") == .failure(.missingArgument("textscale")),
              "a bare textscale was accepted", &ok)
        let tour = ReviewTourLab.parse(tour: "textscale larger\ntheme dusk\nresize 1512x950\nrender home")
        check(tour.errors.isEmpty && tour.steps.first == .textScale(1.3),
              "a Larger tour parsed as \(tour.steps) with \(tour.errors)", &ok)
        if ok { print("  OK   default, large and larger parse, a bad or missing name does not") }
    }

    // MARK: R2-PERF-05

    static let fixtureOutcome = CheckOutcome(installedLabel: "1.0.0", latestLabel: "1.2.0", status: .updateAvailable,
                                             detail: "1.0.0 installed, 1.2.0 available", log: "fixture output")

    private static func checkTheUpdatesRecords(_ ok: inout Bool) {
        print("\n-- R2-PERF-05: the kept checks - written, read, expired --")
        let defaults = AppDefaults.store
        defer { defaults.removeObject(forKey: DependencyCheckRecords.defaultsKey) }
        defaults.removeObject(forKey: DependencyCheckRecords.defaultsKey)
        let records = DependencyCheckRecords(defaults: defaults)
        let now = Date()
        records.record(fixtureOutcome, for: "fixture-tool", at: now.addingTimeInterval(-2 * 3600))
        let kept = records.recent(for: "fixture-tool", maxAge: UpdatesController.visitFreshness, now: now)
        check(kept?.outcome.status == .updateAvailable && kept?.outcome.installedLabel == "1.0.0"
              && kept?.outcome.latestLabel == "1.2.0" && kept?.outcome.detail == fixtureOutcome.detail,
              "a kept check read back as \(String(describing: kept?.outcome))", &ok)
        check(kept.map { abs($0.gatheredAt.timeIntervalSince(now.addingTimeInterval(-2 * 3600))) < 1 } == true,
              "a kept check lost when it was taken", &ok)
        check(kept?.outcome.log == DependencyCheckRecords.keptLog, "a kept check kept the tool's raw output", &ok)
        check(records.recent(for: "fixture-tool", maxAge: UpdatesController.visitFreshness,
                             now: now.addingTimeInterval(11 * 3600)) == nil,
              "a check thirteen hours old still stands for a visit", &ok)
        check(UpdatesController.visitFreshness == 12 * 3600, "the visit window moved without its comment", &ok)
        var checking = fixtureOutcome
        checking = CheckOutcome(installedLabel: "", latestLabel: nil, status: .checking, detail: "", log: "")
        records.record(checking, for: "mid-check", at: now)
        check(records.recent(for: "mid-check", maxAge: 60, now: now) == nil, "a row mid-check was kept as an answer", &ok)
        for status in [DependencyStatus.upToDate, .updateAvailable, .notInstalled, .checkFailed] {
            let name = DependencyCheckRecords.storedName(status)
            check(name.flatMap(DependencyCheckRecords.status(named:)) == status, "\(status) does not round-trip", &ok)
        }
        defaults.set(Data("not json".utf8), forKey: DependencyCheckRecords.defaultsKey)
        check(records.recent(for: "fixture-tool", maxAge: 3600, now: now) == nil, "an unreadable record read as an answer", &ok)

        // The cache reads the newer of its own entry and the kept one, and
        // records every real check it runs.
        defaults.removeObject(forKey: DependencyCheckRecords.defaultsKey)
        guard let item = DependencyCatalog.items.first else { fail("the catalog is empty", &ok); return }
        let saved = DependencyCheckCache.checkOverrideForTests
        defer { DependencyCheckCache.checkOverrideForTests = saved }
        DependencyCheckCache.checkOverrideForTests = { _ in fixtureOutcome }
        let cache = DependencyCheckCache(records: records)
        check(cache.recentOutcome(for: item, maxAge: 3600) == nil, "an empty cache has a recent answer", &ok)
        _ = cache.check(item, forceRefresh: true)
        check(records.recent(for: item.id, maxAge: 60) != nil, "a real check was not kept", &ok)
        check(cache.recentOutcome(for: item, maxAge: 60)?.outcome.status == .updateAvailable,
              "the cache does not read its own fresh entry", &ok)
        check(DependencyCheckCache().records == nil, "a suite's disposable cache keeps records", &ok)

        // Never the captain's domain.
        if let text = source("DependencyCheckCache.swift") {
            check(!text.contains("UserDefaults.standard"), "the kept checks reach UserDefaults.standard", &ok)
            check(text.contains("init(defaults: UserDefaults = AppDefaults.store)"),
                  "the kept checks are not stored through AppDefaults.store", &ok)
        } else {
            fail("DependencyCheckCache.swift was not found, so the store guard measures nothing", &ok)
        }
        if ok { print("  OK   written through AppDefaults, read back with its time, expired at twelve hours, never mid-check") }
    }

    /// The page itself: a visit with a fresh record starts no check and says
    /// how old it is. Check for updates and a stale record both check.
    private static func checkAVisitRunsNoCheckOnAFreshRecord(_ ok: inout Bool) {
        print("\n-- R2-PERF-05: a visit on a fresh record starts no check --")
        let defaults = AppDefaults.store
        defer { defaults.removeObject(forKey: DependencyCheckRecords.defaultsKey) }
        let saved = DependencyCheckCache.checkOverrideForTests
        defer { DependencyCheckCache.checkOverrideForTests = saved }
        let lock = NSLock()
        var checks = 0
        DependencyCheckCache.checkOverrideForTests = { _ in
            lock.lock(); checks += 1; lock.unlock()
            return fixtureOutcome
        }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return checks }
        let items = DependencyCatalog.items
        func reset(keptAt date: Date?) {
            for item in items { DependencyCheckCache.shared.invalidate(item.id) }
            defaults.removeObject(forKey: DependencyCheckRecords.defaultsKey)
            guard let date, let records = DependencyCheckCache.shared.records else { return }
            for item in items { records.record(fixtureOutcome, for: item.id, at: date) }
            lock.lock(); checks = 0; lock.unlock()
        }
        func visit() -> UpdatesController {
            let page = UpdatesController()
            _ = page.view
            page.viewWillAppear()
            return page
        }
        func pump(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }

        reset(keptAt: Date().addingTimeInterval(-2 * 3600))
        check(DependencyCheckCache.shared.records != nil, "the shared cache keeps no records", &ok)
        let page = visit()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(count() == 0, "a visit with every tool checked two hours ago ran \(count()) check(s)", &ok)
        check(!page.debugIsCheckingAll, "the visit is still sweeping", &ok)
        check(page.debugLastCheckedText == "2h ago", "the page says it was checked \"\(page.debugLastCheckedText)\"", &ok)
        check(page.debugRowStatuses.values.allSatisfy { $0 == .updateAvailable },
              "the kept answers are not on the rows: \(Set(page.debugRowStatuses.values))", &ok)

        // Check for updates runs every check, through the button.
        page.debugCheckForUpdatesButton.performClick(nil)
        pump { count() >= items.count && !page.debugIsCheckingAll }
        check(count() == items.count, "Check for updates ran \(count()) checks for \(items.count) tools", &ok)
        check(page.debugLastCheckedText == "just now", "after Check for updates the page says \"\(page.debugLastCheckedText)\"", &ok)
        page.viewWillDisappear()

        // A record older than the window is no record.
        reset(keptAt: Date().addingTimeInterval(-(UpdatesController.visitFreshness + 3600)))
        let stale = visit()
        pump { count() >= items.count && !stale.debugIsCheckingAll }
        check(count() == items.count, "a visit with thirteen-hour-old records ran \(count()) of \(items.count) checks", &ok)
        stale.viewWillDisappear()
        if ok { print("  OK   no check on a fresh record, \"2h ago\" shown, the button and a stale record check every tool") }
    }
}

#endif
