// Manjesh Grand Line - native macOS app.
//
// Proof that `OffScreenProbe.window(...)` genuinely keeps a self-test's window
// off the captain's display, through every path a suite actually exercises.
//
// This suite exists because the old convention *read* correct and was wrong:
// ~20 suites parked a window at `x: -20_000`, documented that as invisible,
// and were caught live on the captain's physical display by a
// `CGWindowListCopyWindowInfo` enumeration
// (`data/grand-line-stray-window-glitch-scout/report.md`, "BUG A"). Nothing in
// the repo measured the claim, so nothing could tell the claim from the
// reality. These cases measure it.
//
// Every check compares the window's own frame against the real
// `NSScreen.screens` rather than against the literal -20_000, because the
// property that matters is "no display can show this", not "the number is the
// one we typed".

#if FM_SELFTESTS

import AppKit

enum OffScreenProbeSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var ok = true

        // Nothing here means anything on a host with no displays at all: every
        // window is vacuously off-screen, so a broken fix would pass.
        guard !NSScreen.screens.isEmpty else {
            print("  NOTE: this process sees no NSScreen, so 'off-screen' cannot be distinguished "
                + "from 'no screen exists' - skipping.")
            print("OffScreenProbeSelfTest: all checks passed")
            return true
        }
        print("  screens: \(NSScreen.screens.map { $0.frame })")

        checkTheFactoryParksTheWindow(&ok)
        checkOrderingInKeepsItOffScreen(&ok)
        checkResizingKeepsItOffScreen(&ok)
        checkZoomKeepsItOffScreen(&ok)
        checkAPlainWindowWouldHaveLeaked(&ok)
        checkTheWindowIsStillLogicallyVisible(&ok)
        checkTheDragOptOutIsInvisibleAndStillGetsMouse(&ok)

        print(ok ? "OffScreenProbeSelfTest: all checks passed"
                 : "OffScreenProbeSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL: \(message)")
        ok = false
    }

    private static func describe(_ window: NSWindow) -> String {
        "\(window.frame) vs screens \(NSScreen.screens.map { $0.frame })"
    }

    /// Construction alone must not put it on a display.
    ///
    /// This is the half the scout report's own recommendation does not cover:
    /// AppKit's initial placement ignores the origin handed to
    /// `NSWindow.init(contentRect:)` entirely - a window *asked* for -20_000
    /// comes back at `x: 160`, fully on screen, before anything is ordered in.
    /// The factory therefore has to re-park after building.
    private static func checkTheFactoryParksTheWindow(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 900, height: 600)
        defer { window.close() }
        guard OffScreenProbe.isInvisible(window) else {
            fail("a freshly built probe window is on a display: \(describe(window))", &ok)
            return
        }
        guard window.frame.width == 900 else {
            fail("the factory did not honour the requested width: \(window.frame)", &ok)
            return
        }
    }

    /// `orderFront` and `makeKeyAndOrderFront` are where a plain window is
    /// dragged back onto the screen, so both are driven.
    private static func checkOrderingInKeepsItOffScreen(_ ok: inout Bool) {
        let window = OffScreenProbe.window(
            width: 1220, height: 720,
            styleMask: [.titled, .closable, .miniaturizable, .resizable])
        defer { window.close() }

        window.orderFront(nil)
        guard OffScreenProbe.isInvisible(window) else {
            fail("orderFront put the probe window on a display: \(describe(window))", &ok)
            return
        }
        window.makeKeyAndOrderFront(nil)
        guard OffScreenProbe.isInvisible(window) else {
            fail("makeKeyAndOrderFront put the probe window on a display: \(describe(window))", &ok)
            return
        }
    }

    /// The suites resize constantly and almost always pass `x: 0`.
    ///
    /// `AppShellBodyWidthSelfTest` alone sweeps a dozen widths per case, so a
    /// window that is only parked once is back on the display by its second
    /// assertion. The size still has to be honoured, or every one of those
    /// sweeps would be measuring the wrong thing.
    private static func checkResizingKeepsItOffScreen(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 900, height: 600,
                                           styleMask: [.titled, .resizable])
        defer { window.close() }
        window.orderFront(nil)

        for width in [1440.0, 1016.0, 1900.0] as [CGFloat] {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
            guard OffScreenProbe.isInvisible(window) else {
                fail("a resize to \(width) put the probe window on a display: \(describe(window))", &ok)
                return
            }
            guard window.frame.width == width else {
                fail("a resize to \(width) was not honoured: \(window.frame) - a pinned origin must "
                    + "not cost the suites their width sweeps", &ok)
                return
            }
        }

        window.setContentSize(NSSize(width: 640, height: 480))
        guard OffScreenProbe.isInvisible(window) else {
            fail("setContentSize put the probe window on a display: \(describe(window))", &ok)
            return
        }
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        guard OffScreenProbe.isInvisible(window) else {
            fail("setFrameOrigin put the probe window on a display: \(describe(window)) - "
                + "setFrameOrigin does not route through setFrame and needs its own override", &ok)
            return
        }
    }

    /// `WindowChromeFusionSelfTest` clicks the real zoom button, and a zoom
    /// computes its own frame from a screen.
    ///
    /// It must still genuinely resize - that case asserts the frame changed -
    /// while never landing the maximised window on the captain's display.
    private static func checkZoomKeepsItOffScreen(_ ok: inout Bool) {
        let window = OffScreenProbe.window(
            width: 900, height: 600,
            styleMask: [.titled, .closable, .miniaturizable, .resizable])
        defer { window.close() }
        window.orderFront(nil)

        let before = window.frame
        window.zoom(nil)
        guard OffScreenProbe.isInvisible(window) else {
            fail("zoom put the probe window on a display: \(describe(window))", &ok)
            return
        }
        guard window.frame.size != before.size else {
            fail("zoom changed nothing (\(window.frame)) - a pinned origin must not make a real "
                + "zoom click unobservable", &ok)
            return
        }
    }

    /// The override is load-bearing, measured rather than assumed.
    ///
    /// Without this the suite could pass against a factory that does nothing
    /// but call `setFrameOrigin`, which is exactly what several suites already
    /// did while leaking. A plain `NSWindow` given the identical treatment has
    /// to come back **on** a screen, or `constrainFrameRect` is not what is
    /// holding the probe window off it and this whole suite proves nothing.
    private static func checkAPlainWindowWouldHaveLeaked(_ ok: inout Bool) {
        // OffScreenProbe-exempt: this case's whole job is to observe the
        // un-fixed behaviour, so it has to build the shape the factory exists
        // to replace.
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),   // OffScreenProbe-exempt:
                             styleMask: [.titled], backing: .buffered, defer: false)
        defer { plain.close() }
        plain.setFrameOrigin(OffScreenProbe.parkedOrigin)
        guard OffScreenProbe.isInvisible(plain) else {
            fail("a plain NSWindow did not even hold its parked origin before being ordered in - "
                + "this control case can no longer tell the fix from its absence", &ok)
            return
        }
        plain.orderFront(nil)
        guard !OffScreenProbe.isInvisible(plain) else {
            fail("a plain NSWindow stayed off-screen through orderFront, so the constrainFrameRect "
                + "override is not what is keeping the probe window off the display - this suite "
                + "would pass with the fix removed", &ok)
            return
        }
    }

    /// Off-screen, not un-ordered.
    ///
    /// Never calling `orderFront` would also keep a window off the display, and
    /// is the wrong fix: `isVisible` is a real observable that
    /// `KubeContextBridgeSelfTest` and `TerminalDisplayGatingSelfTest` read
    /// deliberately, and SwiftTerm draws nothing at all in a window that was
    /// never ordered front.
    private static func checkTheWindowIsStillLogicallyVisible(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 700, height: 400)
        defer { window.close() }
        window.orderFront(nil)
        guard window.isVisible else {
            fail("an ordered-in probe window reports isVisible == false - suites that read that "
                + "observable would silently change behaviour", &ok)
            return
        }
        guard OffScreenProbe.isInvisible(window) else {
            fail("visible and on a display: \(describe(window))", &ok)
            return
        }
    }

    /// The one documented exception: a suite driving a real `NSDraggingSession`
    /// gets on-screen geometry and invisibility by alpha instead.
    ///
    /// Both halves are asserted, because each fails differently: a window that
    /// is not actually transparent is the leak this whole file exists to stop,
    /// and one that sets `ignoresMouseEvents` wedges the very drag session the
    /// opt-out exists to let finish (measured - see the header).
    private static func checkTheDragOptOutIsInvisibleAndStillGetsMouse(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 800, height: 600,
                                           styleMask: [.titled, .resizable],
                                           needsWindowServerMouse: true)
        defer { window.close() }
        window.orderFront(nil)

        guard window.alphaValue == 0 else {
            fail("the drag opt-out must be fully transparent, got alpha \(window.alphaValue) - "
                + "it sits on a real screen, so alpha is the only thing keeping it unseen", &ok)
            return
        }
        guard OffScreenProbe.isInvisible(window) else {
            fail("the drag opt-out is visible: \(describe(window))", &ok)
            return
        }
        guard !window.ignoresMouseEvents else {
            fail("the drag opt-out sets ignoresMouseEvents - measured, that reproduces the hang it "
                + "exists to avoid, because it is the same 'the window server will not deliver "
                + "mouse events here' condition that off-screen already was", &ok)
            return
        }
        // The point of the opt-out: this one *is* on a screen, so the contrast
        // with every other probe window is real rather than a naming choice.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            fail("the drag opt-out is off-screen after all (\(window.frame)) - then it buys nothing "
                + "over the default and the drag session will still hang", &ok)
            return
        }
    }
}

#endif
