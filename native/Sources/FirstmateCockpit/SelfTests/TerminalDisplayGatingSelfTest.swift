// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for E1's battery half: `CockpitTerminalView`'s display
// gating and the vendored SwiftTerm patch it drives
// (`Vendor/SwiftTerm/README.md`'s "Fourth patch"). Run with:
//
//   swift build && FM_RUN_TERMINAL_DISPLAY_GATING_TESTS=1 .build/debug/FirstmateCockpit; echo $?
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
        print(ok ? "TerminalDisplayGatingSelfTest: all checks passed"
                 : "TerminalDisplayGatingSelfTest: FAILED")
        return ok
    }

    private static func fail(_ ok: inout Bool, _ message: String) {
        print("  FAIL: \(message)")
        ok = false
    }

    /// A real window, ordered front so it is genuinely `.visible` to the
    /// window server - the same requirement `TerminalSelectionRenderSelfTest`
    /// documents for getting a SwiftTerm view to draw at all.
    private static func mount() -> (NSWindow, CockpitTerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
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
        // .../native/Sources/FirstmateCockpit -> .../native
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
}

#endif
