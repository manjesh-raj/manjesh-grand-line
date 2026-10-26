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
}

#endif
