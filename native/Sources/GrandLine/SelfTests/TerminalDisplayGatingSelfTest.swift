// Grand Line - native macOS app.
//
// Permanent self-test for E1's battery half: `CockpitTerminalView`'s display
// gating and the vendored SwiftTerm patch it drives
// (`Vendor/SwiftTerm/README.md`'s "Fourth patch"). Run with:
//
//   swift build && FM_RUN_TERMINAL_DISPLAY_GATING_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed (visibility has no meaning without a real window), so it sits
// in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// The two properties worth pinning here are the two the fix could plausibly
// get wrong in opposite directions:
//
//   1. A terminal nobody can see must stop painting. That is the whole
//      finding - the app was the machine's top CPU consumer while merely
//      backgrounded.
//   2. A terminal that stopped painting must NOT have stopped *reading*.
//      Gating the model instead of the display would corrupt scrollback,
//      which is exactly what this app's own history says never to do to a
//      terminal, and it would be invisible in a diff.
//
// Plus a source guard, because the gate is only as real as the vendored patch
// underneath it and a SwiftTerm re-sync would silently drop that patch while
// every property here still compiled and read back correctly.
//
// Full review #5 (R5-PERF-01, fix 7) added two more, both about the cost of a
// terminal that *is* on screen:
//
//   3. A terminal in the active app that does not have the keyboard paints at
//      30 Hz, not 60.
//   4. A TUI frame repaints only the rows it changed (vendored patch 10), and
//      no row is ever left showing stale text. "Stale" is checked against what
//      real display passes painted, recorded through `rowPaintObserver` and
//      fingerprinted from public API only, across every step the brief named:
//      scrolling, resize, selection, the alternate screen, cursor moves, a
//      theme change and a find highlight.

#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum TerminalDisplayGatingSelfTest {

    static func run() -> Bool {
        var ok = true
        checkSuspendsWhenNotVisible(&ok)
        checkModelKeepsReadingWhileSuspended(&ok)
        checkIntervalFollowsAppActivation(&ok)
        checkVendoredPatchIsPresent(&ok)
        checkUnfocusedTerminalPaintsAtThirtyHertz(&ok)
        checkDirtyRowRepaint(&ok)
        print(ok ? "TerminalDisplayGatingSelfTest: all checks passed"
                 : "TerminalDisplayGatingSelfTest: FAILED")
        return ok
    }

    private static func fail(_ ok: inout Bool, _ message: String) {
        SelfTestAssertions.recordFailure(message, &ok)
    }

    /// A real window, ordered front so it is genuinely `.visible` to the
    /// window server - the same requirement `TerminalSelectionRenderSelfTest`
    /// documents for getting a SwiftTerm view to draw at all.
    private static func mount() -> (NSWindow, CockpitTerminalView) {
        let window = OffScreenProbe.window(width: 700, height: 400)
        let term = CockpitTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        window.contentView?.addSubview(term)
        // A window only becomes `.visible` to the window server for a
        // process that is actually a UI app - a self-test run from a terminal
        // is `.prohibited` by default, and its windows are never composited.
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        // Occlusion state is delivered asynchronously; give the window server
        // a turn so `refreshDisplayGating` reads a settled value.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        term.refreshDisplayGating()
        return (window, term)
    }

    // MARK: 1 - the gate itself

    private static func checkSuspendsWhenNotVisible(_ ok: inout Bool) {
        print("TerminalDisplayGatingSelfTest: painting is suspended exactly when nothing can see it")
        let (window, term) = mount()
        defer { window.orderOut(nil) }

        if term.displaySuspended {
            fail(&ok, "a terminal in a visible window is suspended")
        }

        // The console's own tab switching and the app shell's destination
        // hiding both reduce to this - `viewDidHide` is what carries it.
        term.isHidden = true
        if !term.displaySuspended {
            fail(&ok, "a hidden terminal still schedules display passes")
        }
        term.isHidden = false
        if term.displaySuspended {
            fail(&ok, "a re-shown terminal stayed suspended")
        }

        // An ancestor hiding is the destination-navigation case, and it must
        // reach the same gate - this is why the gate lives on the view.
        window.contentView?.isHidden = true
        if !term.displaySuspended {
            fail(&ok, "a terminal under a hidden ancestor still schedules display passes")
        }
        window.contentView?.isHidden = false
        if term.displaySuspended {
            fail(&ok, "a terminal stayed suspended after its ancestor was re-shown")
        }

        // A closed/ordered-out window is the same thing as far as painting is
        // concerned.
        window.orderOut(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        term.refreshDisplayGating()
        if !term.displaySuspended {
            fail(&ok, "a terminal in an ordered-out window still schedules display passes")
        }
        if ok { print("  visible -> live; hidden view, hidden ancestor, ordered-out window -> suspended") }
    }

    // MARK: 2 - the model is never gated

    private static func checkModelKeepsReadingWhileSuspended(_ ok: inout Bool) {
        print("TerminalDisplayGatingSelfTest: a suspended terminal still reads every byte")
        let (window, term) = mount()
        defer { window.orderOut(nil) }

        term.isHidden = true
        guard term.displaySuspended else {
            fail(&ok, "hiding the view did not suspend painting")
            return
        }
        let marker = "gating-marker-8317"
        term.feed(text: marker + "\r\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let buffer = String(data: term.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        if !buffer.contains(marker) {
            fail(&ok, "output fed while suspended never reached the terminal buffer - the gate is on the model, not the display")
        }
        // And it must render on resume without needing a reconnect.
        term.isHidden = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let after = String(data: term.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        if !after.contains(marker) {
            fail(&ok, "the buffer lost content across a suspend/resume cycle")
        }
        if ok { print("  fed while suspended, present in the buffer, still present after resume") }
    }

    // MARK: 3 - throttle, not suspend, for a visible-but-inactive app

    private static func checkIntervalFollowsAppActivation(_ ok: inout Bool) {
        print("TerminalDisplayGatingSelfTest: a visible window whose app is inactive throttles instead of freezing")
        let (window, term) = mount()
        defer { window.orderOut(nil) }

        // `NSApp.isActive` cannot be forced from in-process, so assert the
        // mapping rather than a literal: whichever state this run is in, the
        // interval must be the one that state calls for.
        let expected = NSApp.isActive
            ? CockpitTerminalView.foregroundIntervalNanos
            : CockpitTerminalView.backgroundIntervalNanos
        if term.displayIntervalNanos != expected {
            fail(&ok, "app active = \(NSApp.isActive) but the interval is \(term.displayIntervalNanos), expected \(expected)")
        }
        if CockpitTerminalView.backgroundIntervalNanos <= CockpitTerminalView.foregroundIntervalNanos {
            fail(&ok, "the inactive-app interval is not slower than the active one")
        }
        // The distinction that matters: inactive must never mean suspended,
        // because a backgrounded window can still be partly visible.
        if window.isVisible, !NSApp.isActive, term.displaySuspended {
            fail(&ok, "a visible window was suspended merely because the app was not frontmost")
        }
        if ok { print("  interval \(term.displayIntervalNanos)ns for app-active=\(NSApp.isActive), not suspended") }
    }

    // MARK: 4 - source guard on the vendored patch

    private static func checkVendoredPatchIsPresent(_ ok: inout Bool) {
        print("TerminalDisplayGatingSelfTest: the vendored SwiftTerm patch that makes the gate real is still there")
        guard let appDir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not reachable from here")
            return
        }
        // .../native/Sources/GrandLine -> .../native
        let native = appDir.deletingLastPathComponent().deletingLastPathComponent()
        let queue = native.appendingPathComponent("Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift")
        let decl = native.appendingPathComponent("Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift")
        guard let queueText = try? String(contentsOf: queue, encoding: .utf8),
              let declText = try? String(contentsOf: decl, encoding: .utf8) else {
            print("  SKIP: vendored SwiftTerm sources not reachable from here")
            return
        }
        if !declText.contains("public var displaySuspended") || !declText.contains("public var displayIntervalNanos") {
            fail(&ok, "MacTerminalView.swift no longer declares the gating properties (a SwiftTerm re-sync dropping patch 4?)")
        }
        if !queueText.contains("if displaySuspended {") || !queueText.contains("suspendedDisplayPending = true") {
            fail(&ok, "queuePendingDisplay() no longer honours displaySuspended - the app-side gate would be a no-op")
        }
        if !queueText.contains("Int(displayIntervalNanos)") {
            fail(&ok, "queuePendingDisplay() no longer reads displayIntervalNanos - the throttle would be a no-op")
        }
        if ok { print("  both hunks of patch 4 present") }
    }

    // MARK: 5 - a visible terminal without the keyboard paints at 30 Hz

    private static func checkUnfocusedTerminalPaintsAtThirtyHertz(_ ok: inout Bool) {
        print("TerminalDisplayGatingSelfTest: a visible terminal without the keyboard is capped at 30 Hz")
        let fg = CockpitTerminalView.foregroundIntervalNanos
        let unfocused = CockpitTerminalView.unfocusedIntervalNanos
        let bg = CockpitTerminalView.backgroundIntervalNanos
        if !(fg < unfocused && unfocused < bg) {
            fail(&ok, "the intervals are not ordered focused < unfocused < inactive app: \(fg), \(unfocused), \(bg)")
        }
        if unfocused != 33_340_000 {
            fail(&ok, "the unfocused interval is \(unfocused)ns, not 30 Hz")
        }

        // `NSApp.isActive` cannot be forced from in-process, so the suite pins
        // the app-active half and drives the focus half for real.
        let (window, term) = mount()
        CockpitTerminalView.appIsActiveOverrideForTests = true
        defer {
            CockpitTerminalView.appIsActiveOverrideForTests = nil
            window.orderOut(nil)
        }
        window.makeFirstResponder(nil)
        term.refreshDisplayGating()
        if term.displayIntervalNanos != unfocused {
            fail(&ok, "an active app's terminal that is not first responder paints every \(term.displayIntervalNanos)ns, expected \(unfocused)")
        }

        // Becoming first responder has to reach the gate by itself: nothing
        // else calls `refreshDisplayGating` when the captain clicks into a tab.
        window.makeKey()
        window.makeFirstResponder(term)
        if term.hasFocus {
            if term.displayIntervalNanos != fg {
                fail(&ok, "the focused terminal paints every \(term.displayIntervalNanos)ns, expected \(fg) - "
                     + "the focus change never reached the display gate")
            }
            window.makeFirstResponder(nil)
            if term.displayIntervalNanos != unfocused {
                fail(&ok, "losing focus left the terminal at \(term.displayIntervalNanos)ns, expected \(unfocused)")
            }
        } else {
            print("  SKIP the focused half: this session cannot make the probe window key")
        }

        // The wiring, without needing a key window: change what the gate
        // would compute, then fire only the signal under test and see the
        // interval follow. A signal that does not reach `refreshDisplayGating`
        // leaves the old interval in place.
        CockpitTerminalView.appIsActiveOverrideForTests = false
        term.hasFocus = false
        if term.displayIntervalNanos != bg {
            fail(&ok, "setting `hasFocus` (what becomeFirstResponder/resignFirstResponder do) did not reach the display gate")
        }
        CockpitTerminalView.appIsActiveOverrideForTests = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        if term.displayIntervalNanos != unfocused {
            fail(&ok, "the window resigning key did not reach the display gate")
        }
        CockpitTerminalView.appIsActiveOverrideForTests = false
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        if term.displayIntervalNanos != bg {
            fail(&ok, "the window becoming key did not reach the display gate")
        }

        term.refreshDisplayGating()
        if term.displayIntervalNanos != bg {
            fail(&ok, "an inactive app's terminal paints every \(term.displayIntervalNanos)ns, expected \(bg)")
        }
        if ok { print("  focused \(fg)ns, unfocused \(unfocused)ns, inactive app \(bg)ns") }
    }

    // MARK: 6 - dirty-row repaint (Grand Line patch 10)

    /// What a row should look like on screen, built only from public API so it
    /// does not share a line of code with the patch it checks.
    private static func fingerprint(_ term: CockpitTerminalView, row: Int) -> String {
        let terminal = term.getTerminal()
        guard let line = terminal.getLine(row: row) else { return "<no line>" }
        var attributes = Hasher()
        for col in 0..<line.count { attributes.combine(line[col].attribute) }
        return line.translateToString()
            + "|attrs \(attributes.finalize())"
            + "|selection \(term.selectionActive) \(term.getSelection() ?? "")"
            + "|ink \(term.nativeForegroundColor) on \(term.nativeBackgroundColor)"
    }

    /// The rows a real display pass painted, and what each one showed.
    private final class PaintLog {
        var painted: [Int: String] = [:]
        var paintedThisStep: Set<Int> = []
    }

    /// Runs the run loop until the parser has nothing pending and AppKit has
    /// nothing left to draw, so every check below reads a settled screen.
    private static func settle(_ term: CockpitTerminalView) {
        term.displayIntervalNanos = CockpitTerminalView.foregroundIntervalNanos
        let deadline = Date().addingTimeInterval(2)
        var quiet = 0
        while quiet < 3 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            quiet = term.getTerminal().getUpdateRange() == nil && !term.needsDisplay ? quiet + 1 : 0
        }
    }

    /// Every visible row must show what the buffer holds now. A row whose
    /// paint is older than its content is exactly a missed repaint.
    private static func checkNoStaleRows(_ term: CockpitTerminalView, _ log: PaintLog,
                                         after step: String, _ ok: inout Bool) {
        let rows = term.getTerminal().rows
        var stale: [String] = []
        for row in 0..<rows {
            let live = fingerprint(term, row: row)
            if log.painted[row] != live {
                stale.append("row \(row) shows \"\(log.painted[row]?.prefix(40) ?? "never painted")\" "
                             + "but holds \"\(live.prefix(40))\"")
            }
        }
        if !stale.isEmpty {
            fail(&ok, "after \(step), \(stale.count) row(s) are stale: " + stale.prefix(3).joined(separator: "; "))
        }
    }

    private static func step(_ term: CockpitTerminalView, _ log: PaintLog, _ name: String,
                             _ ok: inout Bool, _ action: () -> Void) -> Set<Int> {
        log.paintedThisStep = []
        action()
        settle(term)
        checkNoStaleRows(term, log, after: name, &ok)
        return log.paintedThisStep
    }

    private static func checkDirtyRowRepaint(_ ok: inout Bool) {
        print("TerminalDisplayGatingSelfTest: a TUI frame repaints only the rows it changed, and no row is ever left stale")
        let (window, term) = mount()
        defer {
            term.rowPaintObserver = nil
            window.orderOut(nil)
        }
        term.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        term.allowMouseReporting = false
        let log = PaintLog()
        term.rowPaintObserver = { [unowned term] row in
            log.painted[row] = fingerprint(term, row: row)
            log.paintedThisStep.insert(row)
        }
        let rows = term.getTerminal().rows
        let sync = (begin: "\u{1b}[?2026h\u{1b}[?25l", end: "\u{1b}[?25h\u{1b}[?2026l")
        func tuiRow(_ row: Int, _ text: String) -> String { "\u{1b}[\(row + 1);1H\u{1b}[2K" + text }
        func fullFrame(spinner: String) -> String {
            var frame = sync.begin
            for row in 0..<rows {
                frame += tuiRow(row, row == 4 ? "│ \(spinner) task-04 running" : "│ task-\(row) idle ─────────")
            }
            return frame + sync.end
        }

        // The baseline: a full paint, so every row has a known picture.
        let baseline = step(term, log, "the first full paint", &ok) {
            term.feed(text: "\u{1b}[?1049h" + fullFrame(spinner: "⠋"))
            term.needsDisplay = true
        }
        if baseline.count < rows - 1 {
            fail(&ok, "the first paint reported only \(baseline.count) of \(rows) rows - the observer is not "
                 + "seeing real display passes, and every check below would pass vacuously")
            return
        }

        // R5-PERF-01's frame: the TUI rewrites every row inside synchronized
        // output and only the spinner differs. Stock SwiftTerm repaints all rows.
        let spinnerFrame = step(term, log, "a synchronized frame that moves one spinner", &ok) {
            term.feed(text: fullFrame(spinner: "⠙"))
        }
        if spinnerFrame.isEmpty || spinnerFrame.count > 3 {
            fail(&ok, "a frame that changed one row repainted \(spinnerFrame.count) of \(rows) rows; "
                 + "expected that row and at most its two neighbours")
        }

        let identical = step(term, log, "a synchronized frame identical to the last", &ok) {
            term.feed(text: fullFrame(spinner: "⠙"))
        }
        if !identical.isEmpty {
            fail(&ok, "a frame that changed nothing repainted \(identical.count) rows")
        }

        // A draw can run ahead of `updateDisplay` (anything else that dirties
        // the view). It paints the newer text, so when the row goes back to
        // what `updateDisplay` last recorded, the record is wrong and the row
        // must still repaint. This is why a draw forgets records.
        _ = step(term, log, "a draw that runs ahead of updateDisplay", &ok) {
            term.feed(text: fullFrame(spinner: "⠹"))
            term.display()
            term.feed(text: fullFrame(spinner: "⠙"))
        }

        _ = step(term, log, "a change at the top and the bottom of one frame", &ok) {
            term.feed(text: sync.begin + tuiRow(0, "top changed") + tuiRow(rows - 1, "bottom changed") + sync.end)
        }
        _ = step(term, log, "leaving the alternate screen", &ok) {
            term.feed(text: "\u{1b}[?1049l")
        }
        _ = step(term, log, "output that scrolls the normal screen", &ok) {
            term.feed(text: (0..<(rows + 5)).map { "line \($0) needle" }.joined(separator: "\r\n") + "\r\n")
        }
        _ = step(term, log, "scrolling back into the scrollback", &ok) {
            term.scrollUp(lines: 4)
        }
        _ = step(term, log, "scrolling back to the bottom", &ok) {
            term.scrollDown(lines: 4)
        }
        _ = step(term, log, "a cursor move with no new text", &ok) {
            term.feed(text: "\u{1b}[3;5H\u{1b}[?25l\u{1b}[?25h")
        }
        _ = step(term, log, "a find that highlights a match", &ok) {
            _ = term.findNext("needle", scrollToResult: false)
        }

        // A selection lives on absolute rows. When identical rows scroll under
        // it, no cell changes and only the selection moves, so a row compared
        // by content alone would keep its old highlight.
        _ = step(term, log, "identical rows filling a cleared screen", &ok) {
            term.selectNone()
            term.feed(text: "\u{1b}[2J\u{1b}[H" + String(repeating: "same\r\n", count: rows - 1))
        }
        // Searching backwards from no selection lands on the last match, which
        // is on screen; `scrollToResult: false` keeps the viewport where it is.
        _ = step(term, log, "a find on identical rows", &ok) {
            _ = term.findPrevious("same", scrollToResult: false)
        }
        guard term.getSelection() == "same" else {
            fail(&ok, "the find on identical rows selected \(term.getSelection() ?? "nothing") - the "
                 + "selection-under-scroll case below would measure nothing")
            return
        }
        let selectionScroll = step(term, log, "identical rows scrolling under a selection", &ok) {
            term.feed(text: "same\r\n")
        }
        if selectionScroll.isEmpty {
            fail(&ok, "identical rows scrolled under an active selection and nothing repainted - the "
                 + "highlight stayed on the row it left")
        }
        _ = step(term, log, "clearing the selection", &ok) {
            term.selectNone()
        }

        _ = step(term, log, "a theme change", &ok) {
            HelmTheme.daylight.apply(to: term)
        }
        _ = step(term, log, "a frame after the theme change", &ok) {
            term.feed(text: "after the theme change\r\n")
        }
        _ = step(term, log, "a resize", &ok) {
            term.setFrameSize(NSSize(width: 560, height: 300))
        }
        _ = step(term, log, "a frame after the resize", &ok) {
            term.feed(text: "after the resize\r\n")
        }
        HelmTheme.dusk.apply(to: term)
        if ok { print("  one changed row repainted \(spinnerFrame.count) rows of \(rows), an identical frame 0; no stale row across 19 steps") }
    }
}

#endif
