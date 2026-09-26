// Grand Line - native macOS app.
//
// PF1 of the 2026-09-25 full-application review, measured: a Console tab cost
// roughly a tenth of a CPU core continuously *while the app was backgrounded*.
// Two 5-second `sample` runs on the captain's own running instance put 232-256
// of 4000 main-thread samples in `TerminalView.draw` ->
// `buildAttributedString` / `getAttributes`. The display gating that patch 4
// added was working - the tab was already repainting at 2 fps rather than 60 -
// and every one of those frames still rebuilt an `NSAttributedString`, a
// `CTLine` and a run array for every visible row, from scratch, and threw all
// of it away again.
//
// The seventh vendored SwiftTerm patch caches that per-row work and reuses it
// while the row has not changed. `Vendor/SwiftTerm/README.md`'s "Seventh patch"
// section has the design; `VendoredPatchesSelfTest` asserts the patch is still
// in the tree after a re-sync. **This suite is the behavioural half**: it drives
// a real terminal in a real window, renders it for real, and reads the cache's
// own hit/miss counters back.
//
// Why window-backed: a SwiftTerm view never calls `draw(_:)` in a window that
// was never ordered front (AGENTS.md's probe rule), so every case here needs a
// real window server. Nothing in the cache can be asserted from the model.
//
//   1. Discriminating power first. The very first render of a screen of text
//      must *miss* on every row it draws - a suite that measured zero misses
//      everywhere would pass just as happily with the whole cache deleted.
//   2. Re-rendering an unchanged terminal adds hits and **no** misses at all.
//      This is PF1's own scenario: the background repaint that was costing a
//      tenth of a core.
//   3. Writing one more line invalidates that row and leaves the rest cached,
//      so the cost of a repaint tracks what changed rather than what is on
//      screen.
//   4. A theme change repaints every row. `colorsChanged` drops the whole
//      cache, because a cached row holds already-resolved colours - a cache
//      that survived a palette swap would paint the old theme.
//   5. A selection is not part of the line's own content, so it has to be part
//      of the cache key: selecting across the screen must re-render.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum TerminalRowRenderCacheSelfTest {

    private static let size = NSSize(width: 700, height: 420)

    static func run() -> Bool {
        print("TerminalRowRenderCacheSelfTest")
        var ok = true

        let window = OffScreenProbe.window(size: size)
        let view = CockpitTerminalView(frame: NSRect(origin: .zero, size: size))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        window.contentView = view
        HelmTheme.dusk.apply(to: view)
        view.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // A full screen of text, so there is real per-row work to cache.
        var lines: [String] = []
        for i in 0..<24 {
            lines.append("row \(i): the quick brown fox jumps over the lazy dog 0123456789")
        }
        view.feed(text: lines.joined(separator: "\r\n") + "\r\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // Case 1 - the first render must actually build rows.
        let first = render(view)
        check(first.misses >= 20,
              "the first render of 24 rows of text missed the cache \(first.misses) times; "
              + "under 20 means the fixture is not drawing rows and every later case here "
              + "would pass vacuously",
              &ok)

        // Case 2 - PF1 itself: repaint an unchanged terminal.
        var repeatHits = 0
        var repeatMisses = 0
        for _ in 0..<3 {
            let pass = render(view)
            repeatHits += pass.hits
            repeatMisses += pass.misses
        }
        check(repeatMisses == 0,
              "re-rendering an unchanged terminal rebuilt \(repeatMisses) rows; PF1 is "
              + "exactly this repaint, and a changed row count of zero is the whole point "
              + "of the cache",
              &ok)
        check(repeatHits >= 20,
              "re-rendering an unchanged terminal produced only \(repeatHits) cache hits "
              + "across three passes; it should reuse every visible row every time",
              &ok)

        // Case 3 - one new line invalidates its own row, not the screen.
        view.feed(text: "a brand new line of output\r\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let afterWrite = render(view)
        check(afterWrite.misses >= 1,
              "writing a line rebuilt \(afterWrite.misses) rows - it must rebuild at least "
              + "the row it wrote, or the cache is serving stale output",
              &ok)
        check(afterWrite.misses < first.misses,
              "writing one line rebuilt \(afterWrite.misses) rows against the first "
              + "render's \(first.misses); the repaint cost must track what changed, not "
              + "what is on screen",
              &ok)

        // Case 4 - a palette swap must invalidate everything.
        _ = render(view)
        // No run loop turn between the swap and the render: the view repaints
        // itself on a theme change, and letting that pass happen first would
        // refill the cache and make this case measure nothing.
        HelmTheme.daylight.apply(to: view)
        let afterTheme = render(view)
        check(afterTheme.misses >= 20,
              "a theme change rebuilt only \(afterTheme.misses) rows; a cached row holds "
              + "already-resolved colours, so surviving a palette swap would paint the "
              + "old theme",
              &ok)

        // Case 5 - a selection is not part of the line's contents.
        _ = render(view)
        view.selectAll(nil)
        let afterSelection = render(view)
        check(afterSelection.misses >= 20,
              "selecting the whole screen rebuilt only \(afterSelection.misses) rows; the "
              + "selection is not part of a `BufferLine`'s own generation counter, so it "
              + "has to be part of the cache key",
              &ok)

        window.orderOut(nil)
        print(ok ? "TerminalRowRenderCacheSelfTest: all checks passed"
                 : "TerminalRowRenderCacheSelfTest: FAILURES")
        return ok
    }

    /// Force one real `draw(_:)` pass and report what the row cache did during
    /// it. `cacheDisplay` is this repo's screenshot substitute and, unlike
    /// `display()`, always draws the whole requested rect rather than whatever
    /// AppKit last invalidated - which is what makes the counters comparable
    /// between passes.
    private static func render(_ view: NSView) -> (hits: Int, misses: Int) {
        guard let terminal = view as? CockpitTerminalView else { return (0, 0) }
        let beforeHits = terminal.lineRenderCacheHits
        let beforeMisses = terminal.lineRenderCacheMisses
        autoreleasepool {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }
        return (terminal.lineRenderCacheHits - beforeHits,
                terminal.lineRenderCacheMisses - beforeMisses)
    }
}

#endif
