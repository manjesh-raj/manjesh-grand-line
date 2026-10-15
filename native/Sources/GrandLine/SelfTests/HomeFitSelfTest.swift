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
//      eyebrow, and a "+N more" cue is shown exactly while rows are clipped.
//   3. **The fallback.** At the minimum window with the Larger text step the
//      page cannot fit (its columns' required minimums add up to more than
//      the viewport), and it must scroll as a page rather than clip or push
//      the window bigger. The board predicted this case; it is asserted here
//      so it stays a scroll and never becomes a window-size floor (gotchas
//      (13) and (15)).
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
            checkTheListScrollsInsideItsCard(shell: shell, window: window, &ok)
            checkLargerTextFallsBackToScrolling(shell: shell, window: window, &ok)
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

    // MARK: 2. The list scrolls inside its card

    private static func checkTheListScrollsInsideItsCard(shell: AppShellController, window: NSWindow,
                                                         _ ok: inout Bool) {
        let canvas = shell.debugHomeCanvas
        let rows = ReviewTourLab.demoAttentionMaximum
        for size in sizes {
            show(rows: rows, at: size, shell: shell, window: window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let label = "\(Int(size.width))x\(Int(size.height)), \(rows) rows"
            let card = canvas.attentionCardForTests
            let scroll = card.debugListScroll
            let listHeight = scroll.documentView?.frame.height ?? 0
            let visible = scroll.contentView.bounds.height
            let clipped = listHeight > visible + 0.5
            let page = canvas.documentHeightForTests
            let viewport = canvas.viewportHeightForTests
            print(String(format: "   %@: list %.1f in %.1f (%@), card %.1f", label, listHeight, visible,
                         clipped ? "scrolls" : "fits", card.frame.height))
            check(card.debugEyebrow == "NEEDS ATTENTION \u{00B7} \(rows)",
                  "\(label): the eyebrow should always carry the total, got \"\(card.debugEyebrow)\"", &ok)
            check(card.frame.maxY <= page + 0.5 && page <= viewport + 0.5,
                  "\(label): the card should sit inside a page that fits", &ok)
            if clipped {
                check(card.debugMoreCount != nil,
                      "\(label): rows are clipped but no \"+N more\" cue is shown", &ok)
                check(visible >= 3 * 53 - 0.5,
                      "\(label): the list shows \(visible)pt, under its three-row floor", &ok)
            } else {
                check(card.debugMoreCount == nil,
                      "\(label): every row is visible but the cue says +\(card.debugMoreCount ?? 0) more", &ok)
            }
            // At the minimum window the worst case must really scroll, or the
            // checks above never saw the clipped branch.
            if size.width == 960 {
                check(clipped, "fixture: \(rows) rows should not all fit at 960x620", &ok)
            }
        }
    }

    // MARK: 3. The Larger-text fallback

    private static func checkLargerTextFallsBackToScrolling(shell: AppShellController, window: NSWindow,
                                                            _ ok: inout Bool) {
        let saved = ChromeTextScale.shared.scale
        defer {
            ChromeTextScale.shared.setScale(saved)
            shell.debugHomeCanvas.debugRenderNow()
        }
        ChromeTextScale.shared.setScale(ChromeTextScale.maxScale)
        let size = sizes[0]
        show(rows: 3, at: size, shell: shell, window: window)
        let canvas = shell.debugHomeCanvas
        let page = canvas.documentHeightForTests
        let viewport = canvas.viewportHeightForTests
        print(String(format: "   960x620 at Larger text: page %.1f in viewport %.1f", page, viewport))
        check(abs(window.frame.height - size.height) < 0.5 && abs(window.frame.width - size.width) < 0.5,
              "Larger text resized the window to \(window.frame.size) - a page that cannot fit must "
              + "scroll, never become a window-size floor", &ok)
        check(page > viewport + 0.5,
              "fixture: at the minimum window with Larger text the page was expected not to fit "
              + "(page \(page), viewport \(viewport)), so the fallback was never exercised", &ok)
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
                if overflow > 0.5 {
                    fail("\(label): the page is \(page)pt in a \(viewport)pt viewport - "
                         + "\(overflow)pt below the fold", &ok)
                }
            }
        }
    }
}

#endif
