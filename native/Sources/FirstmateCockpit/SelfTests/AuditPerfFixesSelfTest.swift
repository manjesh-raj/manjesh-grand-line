// Manjesh Grand Line - native macOS app.
//
// The Section 3 performance findings from `data/grand-line-e2e-audit/report.md`
// that are testable as *behaviour* rather than as a stopwatch. Run with:
//
//   swift build && FM_RUN_AUDIT_PERF_FIXES_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
//   P2  a hidden page does not rebuild on a theme change
//   P3  a visit does not rebuild what has not changed; Shift's YAML parse is
//       off the main thread
//   P4  the Health card coalesces registry reports and skips them while hidden
//   P6  the per-task `fm-crew-state.sh` fan-out is bounded and concurrent
//
// Deliberately not timing assertions. What went wrong in every one of these
// was a *rule* ("rebuild everything, on every report, forever") and not a slow
// implementation, so what is pinned is the rule - a stopwatch here would be
// flaky on a loaded machine and would say nothing about why.
//
// Window-backed (visibility is the whole subject), so this sits in
// `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS

import AppKit

enum AuditPerfFixesSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("P4_registryReportsAreCoalescedIntoOneRebuild", test_p4_coalesced),
            ("P4_reportsWhileHiddenDoNotRebuild", test_p4_hidden),
            ("P3_aVisitThatChangedNothingDoesNotRebuild", test_p3_visit),
            ("P3_shiftParsesItsYamlOffTheMainThread", test_p3_shiftAsync),
            ("P2_hiddenPagesDeferTheirThemeRebuild", test_p2_sources),
            ("P6_crewStateFanOutIsBoundedAndConcurrent", test_p6_sources),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "AuditPerfFixesSelfTest: all \(cases.count) cases passed"
              : "AuditPerfFixesSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func mountedCard(visible: Bool) -> (NSWindow, HealthCardView) {
        let card = HealthCardView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = card.card
        card.card.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        card.card.isHidden = !visible
        card.card.layoutSubtreeIfNeeded()
        return (window, card)
    }

    /// One turn of the main queue, so a coalescing `DispatchQueue.main.async`
    /// latch actually fires. A headless suite never turns the run loop on its
    /// own.
    private static func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: P4

    /// The registry notifies on **every** mutation, `markRunning` included,
    /// and a `BackgroundSignalsPoller` pass emits several in a row. Those are
    /// one visual change.
    private static func test_p4_coalesced() -> String? {
        let (window, card) = mountedCard(visible: true)
        defer { window.contentView = nil }
        drainMainQueue()
        let before = card.debugRebuildCount

        for _ in 0..<5 {
            ServiceHealthRegistry.shared.markRunning(.fleetTasks)
            ServiceHealthRegistry.shared.recordSuccess(.fleetTasks)
        }
        drainMainQueue()

        let rebuilds = card.debugRebuildCount - before
        guard rebuilds > 0 else {
            return "ten reports produced no rebuild at all - the card would go stale"
        }
        guard rebuilds <= 2 else {
            return "ten reports in one turn produced \(rebuilds) rebuilds - they are not being coalesced"
        }
        return nil
    }

    /// Once the page has been visited it stays mounted for the session
    /// (GL-37), so before this the app performed 2-4 full Health-card rebuilds
    /// per minute forever, on the main thread, whether or not anyone was
    /// looking at it.
    private static func test_p4_hidden() -> String? {
        let (window, card) = mountedCard(visible: false)
        defer { window.contentView = nil }
        drainMainQueue()
        let before = card.debugRebuildCount

        for _ in 0..<4 {
            ServiceHealthRegistry.shared.markRunning(.shiftGitSync)
            ServiceHealthRegistry.shared.recordSuccess(.shiftGitSync)
        }
        drainMainQueue()

        guard card.debugRebuildCount == before else {
            return "a hidden card rebuilt \(card.debugRebuildCount - before) time(s) for reports nobody could see"
        }
        guard card.debugPendingWhileHidden else {
            return "the card forgot that a report arrived while it was hidden - it would show stale rows on the next visit"
        }
        // And the next appearance must settle it.
        card.card.isHidden = false
        card.refreshIfNeeded(theme: ThemeManager.shared.theme)
        guard card.debugRebuildCount > before else {
            return "the deferred rebuild never happened on the next appearance"
        }
        return nil
    }

    // MARK: P3

    private static func test_p3_visit() -> String? {
        let (window, card) = mountedCard(visible: true)
        defer { window.contentView = nil }
        let theme = ThemeManager.shared.theme
        card.refresh(theme: theme)
        drainMainQueue()
        let after = card.debugRebuildCount

        // A second visit with nothing changed in between: this used to rebuild
        // every row (123ms measured on a debug build - ~15 dropped frames at
        // 120Hz for a tab switch).
        card.refreshIfNeeded(theme: theme)
        guard card.debugRebuildCount == after else {
            return "a visit that changed nothing still rebuilt the card"
        }
        // A theme change is a real reason to rebuild.
        if let other = HelmTheme.allThemes.first(where: { $0.id != theme.id }) {
            card.refreshIfNeeded(theme: other)
            guard card.debugRebuildCount > after else {
                return "a theme change did not rebuild the card"
            }
        }
        return nil
    }

    private static func test_p3_shiftAsync() -> String? {
        guard let text = source("ShiftController.swift") else { return nil }
        guard text.contains("store.reloadAllAsync") else {
            return "ShiftController.viewWillAppear parses four YAML files synchronously on the main thread again"
        }
        guard let store = source("ShiftStore.swift") else { return nil }
        // The split that makes it safe: parsing is pure and off-main, every
        // mutation stays on main.
        guard store.contains("private static func parseAll(root: URL) -> LoadedState"),
              store.contains("private func apply(_ loaded: LoadedState)") else {
            return "ShiftStore no longer separates the (pure, off-main) parse from the (main-thread) apply"
        }
        guard store.contains("DispatchQueue.main.async") else {
            return "ShiftStore applies its parse result without hopping back to the main thread"
        }
        return nil
    }

    // MARK: P2

    /// ~900 `ThemeManager` observers fan out synchronously, and several pages
    /// answered with a full teardown-rebuild rather than a repaint - measured
    /// at 657-1015ms for one `setTheme` with every destination mounted, which
    /// is a visible hang on ⌘⌥T. A hidden page rebuilding eagerly is pure
    /// waste: it rebuilds again on its next appearance anyway.
    private static func test_p2_sources() -> String? {
        guard let health = source("HealthController.swift") else { return nil }
        guard health.contains("refreshCardIfVisible") else {
            return "HealthController's theme observer rebuilds its card even while the page is hidden"
        }
        guard let schedules = source("SchedulesController.swift") else { return nil }
        guard schedules.contains("needsRefreshOnAppear = true") else {
            return "SchedulesController rebuilds every card on a theme change even while the page is hidden"
        }
        return nil
    }

    // MARK: P6

    private static func test_p6_sources() -> String? {
        guard let text = source("FleetData.swift") else { return nil }
        // Anchored on the function that actually performs the fan-out.
        // `parseTasks()` itself is now the thin `FleetTaskCache` wrapper in
        // front of it (3.5 of `data/grandline-full-app-audit/report.md`); the
        // bounded-concurrency contract P6 established lives here.
        guard let range = text.range(of: "static func parseTasksUncached()") else {
            return "parseTasks' bounded fan-out is gone"
        }
        let body = String(text[range.lowerBound...].prefix(3000))
        guard body.contains("DispatchSemaphore"), body.contains("attributes: .concurrent") else {
            return "parseTasks shells out to fm-crew-state.sh strictly one task at a time again"
        }
        guard body.contains("let concurrency = 6") else {
            return "parseTasks' fan-out is unbounded - one short-lived child per task with no cap"
        }
        // Order is part of the contract: the fleet list is sorted by meta
        // filename, and a concurrent fan-out must not reorder it.
        guard body.contains("tasks[index] = task") else {
            return "parseTasks no longer collects results by index, so a concurrent run can reorder the fleet list"
        }
        return nil
    }
}

#endif
