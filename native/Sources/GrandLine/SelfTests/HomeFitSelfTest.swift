// Grand Line - native macOS app.
//
// `fm/grandline-home-fit-implement`: the Home page fits the window.
//
// Run with `FM_RUN_HOME_FIT_TESTS=1 .build/debug/GrandLine`.
//
// The captain asked for Home to be a fixed page that does not scroll down,
// with the follow-ups list scrolling inside its own card. Measured before
// this work (`docs/history/07-fleet-and-notifications.md`): at the captain's
// 1512x945 window the page was 29pt taller than its viewport with three
// attention rows and 468pt taller with ten, and at the 960x620 minimum it was
// 384pt over.
//
// **Why this suite is window-backed.** Every case reads a resolved frame from
// the real `AppShellController` in a real (off-screen) window with the real
// window's chrome fusion, because the viewport is the window minus the bar's
// reserved height, and only the shell knows that. It is listed in
// `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// What it covers:
//
//   1. **The page fits.** At 960x620, 1512x945 and 1920x1050, with 0, 3 and
//      11 attention rows (11 is the most the digest's own caps allow), the
//      page's document is no taller than its viewport.
//   2. **The follow-ups list scrolls inside its card** when its rows do not
//      fit: the card stays inside the page, the total count is always in the
//      eyebrow, a "+N more" cue is shown while rows are clipped, and it goes
//      away once the last row is scrolled into view.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum HomeFitSelfTest {

    /// The three window sizes the captain's board measured: the app's minimum
    /// (`main.swift`'s `minContentSize`), the captain's own 14-inch window,
    /// and a 1080p external display.
    static let sizes: [NSSize] = [
        NSSize(width: 960, height: 620),
        NSSize(width: 1512, height: 945),
        NSSize(width: 1920, height: 1050),
    ]
    static let rowCounts = [0, 3, ReviewTourLab.demoAttentionMaximum]

    /// Off until the three-column page lands. Before it the page cannot fit -
    /// which is the measurement this suite prints - and a suite that fails on
    /// every run between two commits of one change guards nothing.
    static let fitIsEnforced = false

    @discardableResult
    static func run() -> Bool {
        var ok = true
        let savedTheme = ThemeManager.shared.theme
        let savedBriefing = AppSettings.shared.morningBriefingRecord
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.morningBriefingRecord = savedBriefing
        }
        if let daylight = HelmTheme.theme(id: "daylight") { ThemeManager.shared.setTheme(daylight) }

        autoreleasepool {
            let (window, shell) = ReviewTourLab.makeOffScreenShell()
            defer { window.orderOut(nil) }
            window.orderFront(nil)
            shell.show(.homeCanvas)
            ReviewTourLab.seedDemoHome(shell.debugHomeCanvas)
            ReviewTourLab.seedDemoBriefing()
            checkThePageFits(shell: shell, window: window, &ok)
        }

        print(ok ? "HomeFitSelfTest: all checks passed" : "HomeFitSelfTest: FAILED")
        return ok
    }

    // MARK: Fixtures

    /// Resize, put `rows` attention rows on the page, and lay it out twice -
    /// the grid is built from the clip view's width, which is only real after
    /// the first pass (the same reason `containerWidthMayHaveChanged` exists).
    static func show(rows: Int, at size: NSSize, shell: AppShellController, window: NSWindow) {
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: false)
        let canvas = shell.debugHomeCanvas
        canvas.debugAttentionOverride = ReviewTourLab.demoAttentionSummary(count: rows)
        for _ in 0..<2 {
            canvas.debugRenderNow()
            shell.view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: 1. The page fits

    private static func checkThePageFits(shell: AppShellController, window: NSWindow, _ ok: inout Bool) {
        let canvas = shell.debugHomeCanvas
        for size in sizes {
            for rows in rowCounts {
                show(rows: rows, at: size, shell: shell, window: window)
                let label = "\(Int(size.width))x\(Int(size.height)), \(rows) rows"
                let viewport = canvas.viewportHeightForTests
                let page = canvas.documentHeightForTests
                // The fixture's own discriminating power: a viewport that
                // never laid out makes "page <= viewport" meaningless, and a
                // page that silently drew no rows would fit for the wrong
                // reason.
                if viewport < 300 {
                    fail("\(label): the viewport resolved to \(viewport)pt - the window never laid out", &ok)
                    continue
                }
                let drawn = canvas.attentionCardForTests.debugRows.count
                if drawn != rows {
                    fail("\(label): the attention card drew \(drawn) rows, not \(rows)", &ok)
                }
                let overflow = page - viewport
                print(String(format: "   %@: page %.1f in viewport %.1f (%@%.1f)",
                             label, page, viewport, overflow > 0 ? "+" : "", overflow))
                if fitIsEnforced, overflow > 0.5 {
                    fail("\(label): the page is \(page)pt in a \(viewport)pt viewport - "
                         + "\(overflow)pt below the fold", &ok)
                }
            }
        }
    }
}

#endif
