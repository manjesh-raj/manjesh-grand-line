// Grand Line - native macOS app.
//
// The window-backed half of terminal keyword highlighting (T1): the colours
// reach a drawn row, and only a drawn row. Run with:
//
//   swift build && FM_RUN_TERMINAL_KEYWORD_HIGHLIGHT_TESTS=1 .build/debug/GrandLine; echo $?
//
// The colouring is the eighth vendored SwiftTerm patch, applied while
// `draw(_:)` builds a visible row. A SwiftTerm view never draws in a window
// that was never ordered front, so every case here needs a real window server
// (AGENTS.md's probe rule), and nothing can be asserted from the model alone.
//
// What is painted is measured as **pixels**: a count of red-dominant pixels in
// a real render, compared with and without highlighting. A channel-dominance
// count rather than an exact colour match, because glyph antialiasing and the
// display's colour profile both move individual pixels (AGENTS.md's pixel
// rules), while "this text came out red" survives both.
//
//   1. Discriminating power first: plain "error" text renders red with the
//      highlighter on and not red with it off.
//   2. A program's own colour wins: blue "error" stays blue.
//   3. The alternate screen (vim, htop, less) is never coloured or scanned.
//   4. The buffer, copy and `getBufferAsData` never see a highlight.
//   5. An unchanged screen rescans nothing, and a settings change repaints.
//   6. Once scrollback is full every frame rotates every row past patch 7's
//      identity check, and the memo still keeps scans to the new lines.
//   7. A row wider than 2,000 columns is never scanned.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum TerminalKeywordHighlightSelfTest {

    private static let size = NSSize(width: 640, height: 300)
    private static let clear = "\u{1b}[0m\u{1b}[2J\u{1b}[3J\u{1b}[H"

    static func run() -> Bool {
        print("TerminalKeywordHighlightSelfTest")
        var ok = true

        let window = OffScreenProbe.window(size: size)
        let view = CockpitTerminalView(frame: NSRect(origin: .zero, size: size))
        view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        window.contentView = view
        // The suite's own highlighter, so nothing here reaches the shared one
        // the app's terminals use.
        let highlighter = TerminalKeywordHighlighter(settings: .defaults, theme: .dusk)
        highlighter.attach(view)
        HelmTheme.dusk.apply(to: view)
        view.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let red = HelmContrast.components(
            TerminalKeywordHighlighter.resolvedColor(for: .error, settings: .defaults, theme: .dusk))
        check(red.0 - max(red.1, red.2) > 0.3,
              "Dusk's resolved Error colour \(red) is not clearly red; the red-pixel count below could not "
              + "tell highlighted text from plain", &ok)

        checkPlainTextIsColoured(view, highlighter, &ok)
        checkProgramColourWins(view, highlighter, &ok)
        checkAlternateScreenIsSkipped(view, highlighter, &ok)
        checkTheBufferIsUntouched(view, highlighter, &ok)
        checkCachingAndRepaint(view, highlighter, &ok)
        checkTheMemoSurvivesScrolling(view, &ok)
        checkWideRowsAreSkipped(view, &ok)

        window.orderOut(nil)
        print(ok ? "TerminalKeywordHighlightSelfTest: all checks passed"
                 : "TerminalKeywordHighlightSelfTest: FAILURES")
        return ok
    }

    // MARK: Cases

    private static func checkPlainTextIsColoured(_ view: CockpitTerminalView,
                                                 _ highlighter: TerminalKeywordHighlighter,
                                                 _ ok: inout Bool) {
        show(view, String(repeating: "ERROR error failed fatal\r\n", count: 6))
        let on = redPixels(view)
        let off = withHighlighting(off: highlighter) { redPixels(view) }
        check(off < 20, "plain text with highlighting off already has \(off) red pixels; the fixture "
              + "cannot tell highlighted text from plain", &ok)
        check(on > off + 300, "plain \"error\" text rendered \(on) red pixels with highlighting on against "
              + "\(off) off; the highlight is not reaching the drawn row", &ok)
    }

    private static func checkProgramColourWins(_ view: CockpitTerminalView,
                                               _ highlighter: TerminalKeywordHighlighter,
                                               _ ok: inout Bool) {
        show(view, String(repeating: "\u{1b}[34mERROR error failed fatal\u{1b}[0m\r\n", count: 6))
        let on = redPixels(view)
        let off = withHighlighting(off: highlighter) { redPixels(view) }
        check(abs(on - off) < 20, "text a program coloured blue gained \(on - off) red pixels from the "
              + "highlighter; a program's own colour must win", &ok)
    }

    private static func checkAlternateScreenIsSkipped(_ view: CockpitTerminalView,
                                                      _ highlighter: TerminalKeywordHighlighter,
                                                      _ ok: inout Bool) {
        show(view, "")
        view.feed(text: "\u{1b}[?1049h\u{1b}[H" + String(repeating: "ERROR error failed fatal\r\n", count: 6))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scansBefore = view.rowHighlightScans
        let on = redPixels(view)
        let scans = view.rowHighlightScans - scansBefore
        let off = withHighlighting(off: highlighter) { redPixels(view) }
        check(scans == 0, "the alternate screen was scanned \(scans) times; vim, htop and less must never be", &ok)
        check(abs(on - off) < 20, "the alternate screen gained \(on - off) red pixels from the highlighter", &ok)
        view.feed(text: "\u{1b}[?1049l")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private static func checkTheBufferIsUntouched(_ view: CockpitTerminalView,
                                                  _ highlighter: TerminalKeywordHighlighter,
                                                  _ ok: inout Bool) {
        show(view, "ERROR at 10.0.0.1, retrying\r\nall OK\r\n")
        _ = redPixels(view)
        let withHighlight = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        view.selectAll(nil)
        let copiedWith = view.getSelection()
        let (withoutHighlight, copiedWithout) = withHighlighting(off: highlighter) { () -> (String, String?) in
            _ = redPixels(view)
            return (String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self), view.getSelection())
        }
        view.selectNone()
        check(withHighlight.contains("ERROR at 10.0.0.1, retrying"),
              "the buffer no longer holds the text that was written", &ok)
        check(!withHighlight.contains("\u{1b}"), "the buffer gained an escape sequence; highlighting must "
              + "never rewrite what the program wrote", &ok)
        check(withHighlight == withoutHighlight, "the buffer reads differently with highlighting on", &ok)
        check(copiedWith == copiedWithout && copiedWith?.contains("ERROR at 10.0.0.1") == true,
              "a copy reads differently with highlighting on (\(copiedWith ?? "nil"))", &ok)
    }

    private static func checkCachingAndRepaint(_ view: CockpitTerminalView,
                                               _ highlighter: TerminalKeywordHighlighter,
                                               _ ok: inout Bool) {
        show(view, String(repeating: "ERROR error failed fatal\r\n", count: 6))
        _ = render(view)
        let again = render(view)
        check(again.misses == 0 && again.scans == 0,
              "re-rendering an unchanged screen rebuilt \(again.misses) rows and scanned \(again.scans); "
              + "a row is scanned only when its text changes", &ok)

        var settings = highlighter.settings
        settings[.error] = KeywordHighlightClassSetting(enabled: false)
        highlighter.update(settings: settings)
        let afterChange = render(view)
        let redAfter = redPixels(view)
        check(afterChange.misses >= 6, "switching the Error class off rebuilt only \(afterChange.misses) "
              + "rows; a settings change must repaint every row", &ok)
        check(redAfter < 20, "with the Error class off, \(redAfter) red pixels are still painted", &ok)
        highlighter.update(settings: .defaults)
    }

    private static func checkTheMemoSurvivesScrolling(_ view: CockpitTerminalView, _ ok: inout Bool) {
        show(view, "")
        view.getTerminal().changeScrollback(40)
        for i in 0..<120 { view.feed(text: "line \(i) ERROR seen at 10.0.0.\(i % 250)\r\n") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        _ = render(view)
        var misses = 0
        var scans = 0
        let frames = 8
        for i in 0..<frames {
            view.feed(text: "tail \(i) warning from 192.168.0.\(i)\r\n")
            let pass = render(view)
            misses += pass.misses
            scans += pass.scans
        }
        // Discriminating power: with scrollback full, every row really does
        // rotate past patch 7's identity check, or this case proves nothing.
        check(misses >= frames * 6, "a full scrollback rebuilt only \(misses) rows over \(frames) frames; "
              + "the fixture is not exercising the rotation the memo exists for", &ok)
        check(scans <= frames * 2, "\(scans) rows were scanned over \(frames) frames of one new line each; "
              + "the memo should keep that to the new lines (\(misses) rebuilds)", &ok)
        view.getTerminal().changeScrollback(500)
    }

    private static func checkWideRowsAreSkipped(_ view: CockpitTerminalView, _ ok: inout Bool) {
        view.minimumColumns = TerminalView.rowHighlightMaximumColumns + 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        show(view, "ERROR in a very wide row\r\n")
        let pass = render(view)
        check(pass.misses > 0, "the wide-row fixture rendered no rows at all", &ok)
        check(pass.scans == 0, "a row over \(TerminalView.rowHighlightMaximumColumns) columns was scanned "
              + "\(pass.scans) times", &ok)
        view.minimumColumns = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    // MARK: Helpers

    private static func show(_ view: CockpitTerminalView, _ text: String) {
        view.feed(text: clear + text)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    /// Runs `body` with highlighting switched off, then back on.
    private static func withHighlighting<T>(off highlighter: TerminalKeywordHighlighter, _ body: () -> T) -> T {
        let saved = highlighter.settings
        var off = saved
        off.enabled = false
        highlighter.update(settings: off)
        defer { highlighter.update(settings: saved) }
        return body()
    }

    /// One real `draw(_:)` pass, with what patch 7's cache and patch 8's memo
    /// did during it.
    private static func render(_ view: CockpitTerminalView) -> (misses: Int, scans: Int) {
        let misses = view.lineRenderCacheMisses
        let scans = view.rowHighlightScans
        _ = capture(view)
        return (view.lineRenderCacheMisses - misses, view.rowHighlightScans - scans)
    }

    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
        var result: NSBitmapImageRep?
        autoreleasepool {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                result = rep
            }
        }
        return result
    }

    /// Pixels whose red channel clearly leads both others, in the rep's own
    /// raw components (AGENTS.md: never convert the sample).
    private static func redPixels(_ view: NSView) -> Int {
        guard let rep = capture(view) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent - max(c.greenComponent, c.blueComponent) > 0.2 { count += 1 }
            }
        }
        return count
    }
}

#endif
