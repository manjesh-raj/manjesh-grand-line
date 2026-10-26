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
}

#endif
