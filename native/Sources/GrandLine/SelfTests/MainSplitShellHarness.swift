// Grand Line - native macOS app.
//
// The one setup the two sidebar-shell suites share,
// `MainSplitShellNavigationSelfTest` and `MainSplitShellPanesSelfTest`. Not a
// suite of its own: it has no `FM_RUN_*` flag. Each half mounts its own shell
// through it, so the halves start from the same state and run apart, and
// neither depends on what the other left behind.
//
// They were one suite until it ran 1,573 checks in 297.6s against the
// runner's 300s per-suite bound on CI's window-backed shard, and it grows
// whenever a page is added. Splitting it was chosen over raising the bound.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum MainSplitShellHarness {

    typealias Check = (MainSplitShellController, NSWindow, inout Bool) -> Void

    /// Mounts the real shell in an off-screen window and runs `checks` on it
    /// in order, with the settings they measure pinned and put back after.
    static func run(_ suite: String, _ checks: [Check]) -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedPins = AppSettings.shared.quickAccess
        defer { AppSettings.shared.quickAccess = savedPins }
        let savedHome = AppSettings.shared.homeCardLayout
        defer { AppSettings.shared.homeCardLayout = savedHome }
        AppSettings.shared.homeCardLayout = .standard
        // R5-UI-08: Home leaves the Morning briefing card off while the
        // briefing is off and has nothing on record. The checks here measure
        // the five-card Home, so the briefing is on, in this process's own
        // suite domain, and put back after.
        let briefingWasOn = AppSettings.shared.morningBriefingEnabled
        AppSettings.shared.morningBriefingEnabled = true
        defer { AppSettings.shared.morningBriefingEnabled = briefingWasOn }

        var allOK = true
        let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(shell)
        for check in checks {
            var ok = true
            check(shell, window, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "\(suite): all checks passed" : "\(suite): FAILED")
        return allOK
    }

    static func settle(_ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    static func resize(_ window: NSWindow, width: CGFloat, _ shell: MainSplitShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }
}

#endif
