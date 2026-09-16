// Manjesh Grand Line - native macOS app.
//
// The one place a window-backed self-test gets an `NSWindow` from, and the one
// place that proves the window never appears on the captain's display.
//
// # The bug this exists to close
//
// ~20 suites used to hand-roll `NSWindow(contentRect:…)` and believed they had
// parked it off-screen. They had not: a scout investigation
// (`data/grand-line-stray-window-glitch-scout/report.md`, "BUG A") enumerated
// the real window list with `CGWindowListCopyWindowInfo` and caught these
// windows **on the captain's physical display** - `layer=0`, front-orderable,
// clickable - every time a sibling crewmate's test run went past. They are what
// he reported as a stray dark panel showing three grey traffic lights: fused
// chrome (`WindowChromeFusion.apply`) with its content not yet laid out.
//
// Both idioms in use failed, for two *different* measured reasons:
//
//   - **Construction does not honour `constrainFrameRect`.** A window built as
//     `NSWindow(contentRect: NSRect(x: -20_000, …))` is placed by AppKit's own
//     initial-placement logic and lands at **x=160, fully on screen**, before
//     `orderFront` is ever called. Overriding `constrainFrameRect` does *not*
//     prevent this - measured, an `OffScreenProbeWindow` built at -20_000 still
//     came back at `(160, 0)`. The origin passed to `init` is simply not the
//     origin you get, which is why `window(size:)` below takes a **size** and
//     parks afterwards rather than taking a rect.
//
//   - **`orderFront` re-constrains an already-parked window.** A plain
//     `NSWindow` moved to -20_000 with `setFrame` holds there until it is
//     ordered in, at which point AppKit drags it back to `(0, 0)` - the
//     bottom-left corner, which is exactly where the scout caught several live.
//
// # Why `constrainFrameRect` does all of the forcing
//
// The suites resize constantly, and nearly every `setFrame` they issue passes
// `x: 0` - so parking once is not enough, the origin has to be *pinned*. The
// obvious way to pin it is to override `setFrame`/`setFrameOrigin` and
// substitute the origin. That works, and it is the worse mechanism:
// `AppShellBodyWidthSelfTest` deliberately creates constraint conflicts that
// make AppKit resize the *window* from inside a layout pass, and an override
// that hands back a frame AppKit did not ask for is a surprise in the middle of
// one.
//
// `constrainFrameRect(_:to:)` is AppKit's own sanctioned "where should this
// window actually go" callback: it is consulted by `setFrame`, `setFrameOrigin`,
// `setFrameTopLeftPoint`, `setContentSize`, `zoom(nil)` and `orderFront` alike,
// and AppKit uses what it returns without re-deriving anything. One hook, no
// surprise frame changes. Construction is the only path that skips it, which is
// what the explicit park in the factory covers.
//
// # Why not simply stop calling `orderFront`
//
// A window that is never ordered in is genuinely invisible and still gets a
// real `windowNumber`, so it is tempting. It is also `isVisible == false`, and
// several suites read that deliberately - `KubeContextBridgeSelfTest`'s
// `orderFront: true`, `TerminalDisplayGatingSelfTest`'s occlusion state, and
// SwiftTerm, which draws nothing at all in a window that was never ordered
// front. Keeping the window logically visible while physically nowhere is the
// property this file provides, so those suites needed no behavioural change.
//
// # The one exception, and why it is not a loophole
//
// A real `NSDraggingSession` cannot complete in a window the window server will
// not deliver mouse events to. `ShiftBoardViews.swift:334` is the app's only
// `beginDraggingSession` call, and `ShiftBoardViewSelfTest` is the only suite
// that drives it. That suite starts a session and never sends a matching
// mouse-up, so off-screen the session sits waiting and the next `performClick`
// in the same suite blocks behind it in
// `NSCoreDragManager._dragUntilMouseUp`. Measured over five runs each:
// on-screen **1-3s**, off-screen **4-25s** - the wait does resolve eventually
// on this machine, but it is unbounded enough to have hit CI's 300s per-suite
// bound twice, against ~4s for the same suite on `main`. A matching
// `leftMouseUp` does **not** shorten it (measured): the session is wedged in
// the drag manager, not waiting on the window's own event queue.
//
// `needsWindowServerMouse` is that suite's opt-out, and it buys invisibility a
// different way: the window sits at the origin but at `alphaValue = 0`, so
// nothing is ever drawn. **`ignoresMouseEvents` must not be set with it** -
// measured, that reintroduces the hang, because it is the same "the window
// server will not deliver mouse events here" condition by another name. A
// suite's own `window.sendEvent` is unaffected either way.
//
// # The guard
//
// `order(_:relativeTo:)` is the funnel every `orderFront` and
// `makeKeyAndOrderFront` goes through, so the check sits there: once ordered
// in, a window must either intersect no screen or be fully transparent. That is
// what makes a regression fail loudly instead of leaking silently again.
//
// It is deliberately *not* a check on the proposed rect inside
// `constrainFrameRect`: that method is asked about frames the window is never
// given.

#if FM_SELFTESTS

import AppKit

/// An `NSWindow` that never becomes visible on a display.
///
/// AppKit constrains an ordinary window on the way to the screen so its
/// titlebar stays reachable - correct for a document window, wrong for a probe
/// that must never appear on the captain's display. The same
/// `constrainFrameRect` override, for the same reason, is what
/// `HelmBarPanelWindow` uses to stop a dropdown being dragged away from its
/// anchor.
final class OffScreenProbeWindow: NSWindow {

    /// Set once by the factory so a guard failure can name the suite that
    /// created the window rather than this file.
    fileprivate var probeOrigin: String = "<unknown>"

    /// See this file's "one exception" section: on-screen geometry, invisible
    /// by alpha, so a real drag session can complete.
    fileprivate var needsWindowServerMouse = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard !needsWindowServerMouse else { return frameRect }
        return NSRect(origin: OffScreenProbe.parkedOrigin, size: frameRect.size)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        guard place != .out else { return }
        OffScreenProbe.enforceInvisible(self)
    }
}

enum OffScreenProbe {

    /// Far enough left that no plausible display arrangement reaches it, and
    /// the value every migrated suite used to pass to `init` in the belief that
    /// it worked.
    static let parkedOrigin = NSPoint(x: -20_000, y: 0)

    /// A real, fully-chromed window that cannot appear on a display.
    ///
    /// Takes a **size**, not a rect: the origin handed to `NSWindow.init` is
    /// discarded by AppKit's initial placement (see this file's header), so
    /// accepting one would be inviting the next caller to believe a number that
    /// does nothing.
    ///
    /// Does **not** order the window in - each suite keeps its own decision
    /// about that, because `isVisible` is a real observable several of them
    /// assert on.
    ///
    /// - Parameter needsWindowServerMouse: only for a suite that drives a real
    ///   `NSDraggingSession`, which cannot complete in a window the window
    ///   server ignores. Read this file's "one exception" section before
    ///   passing `true`; there is exactly one such suite today.
    static func window(size: NSSize,
                       styleMask: NSWindow.StyleMask = [.titled],
                       needsWindowServerMouse: Bool = false,
                       file: StaticString = #fileID,
                       line: UInt = #line) -> OffScreenProbeWindow {
        let window = OffScreenProbeWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false)
        window.probeOrigin = "\(file):\(line)"
        window.needsWindowServerMouse = needsWindowServerMouse
        if needsWindowServerMouse {
            // Invisible by alpha rather than by position. Deliberately *not*
            // `ignoresMouseEvents` - measured, that wedges the drag session
            // this opt-out exists to let finish.
            window.alphaValue = 0
            window.setFrameOrigin(.zero)
        } else {
            window.setFrameOrigin(parkedOrigin)
        }
        enforceInvisible(window)
        return window
    }

    /// Convenience for the common `width:`/`height:` call shape.
    static func window(width: CGFloat,
                       height: CGFloat,
                       styleMask: NSWindow.StyleMask = [.titled],
                       needsWindowServerMouse: Bool = false,
                       file: StaticString = #fileID,
                       line: UInt = #line) -> OffScreenProbeWindow {
        window(size: NSSize(width: width, height: height),
               styleMask: styleMask, needsWindowServerMouse: needsWindowServerMouse,
               file: file, line: line)
    }

    /// True when nothing of `window` can be seen: either no screen's frame
    /// intersects it, or it is fully transparent.
    ///
    /// A host with no screens at all (a genuinely headless runner) has nothing
    /// to leak onto, so it answers `true` - which is the honest reading, not a
    /// loophole: this guard exists to catch a window landing on a display that
    /// does exist.
    static func isInvisible(_ window: NSWindow) -> Bool {
        if window.alphaValue == 0 { return true }
        return !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// Fail the run rather than let a probe window show on the captain's
    /// display.
    ///
    /// `exit(1)` rather than `fatalError`: the runner keys on a suite's exit
    /// status (`Scripts/run-all-tests.sh`), so this reports as a plain `FAIL`
    /// for that suite, and it leaves no crash report behind on the captain's
    /// own machine.
    static func enforceInvisible(_ window: NSWindow) {
        guard !isInvisible(window) else { return }
        let origin = (window as? OffScreenProbeWindow)?.probeOrigin ?? "<not an OffScreenProbeWindow>"
        print("  FAIL: a self-test window is visible on the captain's display: \(window.frame) "
            + "intersects \(NSScreen.screens.map { $0.frame }) at alpha \(window.alphaValue)")
        print("        created at \(origin). Build it with `OffScreenProbe.window(...)` and do not "
            + "re-position it onto a screen; see OffScreenProbeWindow.swift.")
        exit(1)
    }
}

#endif
