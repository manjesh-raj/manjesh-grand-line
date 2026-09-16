// Manjesh Grand Line - native macOS app.
//
// The one place a window-backed self-test gets an `NSWindow` from, and the one
// place that proves the window is genuinely off the captain's display.
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
// Both idioms in use failed, for two *different* measured reasons, and the
// distinction is the whole reason this file is a factory rather than a comment:
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
//     This is the half `constrainFrameRect` fixes, and it is load-bearing:
//     measured side by side, the plain window snapped to `(0, 0)` while the
//     subclass held at -20_000.
//
// So the working recipe is **both**: build at any origin, `setFrameOrigin` to
// the parked point, and let the override keep it there through every later
// `orderFront` / `makeKeyAndOrderFront` / resize.
//
// A third path had to be closed that the scout report does not mention,
// because it only shows up once the window genuinely starts off-screen: the
// suites resize constantly, and nearly every `setFrame` they issue passes
// `x: 0`. Left alone, the very first resize undoes the parking. The subclass
// therefore *pins* the origin on every geometry mutation rather than being
// positioned once - see its overrides below.
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
// # The guard
//
// `order(_:relativeTo:)` is the funnel every `orderFront` and
// `makeKeyAndOrderFront` goes through, so the check sits there: after the
// window is ordered in, no `NSScreen` frame may intersect its own. That is what
// makes a regression fail loudly instead of leaking silently again - remove the
// `constrainFrameRect` override and every window-backed suite stops at the
// first window it orders in, naming the caller.
//
// Note it is deliberately *not* a check on the proposed rect inside
// `constrainFrameRect`: that method is asked about frames the window is never
// given, and `zoom(nil)` bypasses it entirely (measured - a zoom genuinely does
// move the window onto a screen, which is a test's own deliberate action and
// none of this file's business).

#if FM_SELFTESTS

import AppKit

/// An `NSWindow` that is structurally incapable of appearing on a display.
///
/// AppKit constrains an ordinary window on the way to the screen so its
/// titlebar stays reachable - correct for a document window, wrong for a probe
/// that must never appear on the captain's display. The same
/// `constrainFrameRect` override, for the same reason, is what
/// `HelmBarPanelWindow` uses to stop a dropdown being dragged away from its
/// anchor.
///
/// On top of that it pins its own origin, so a suite may resize it freely
/// without having to thread the parked x through every call.
final class OffScreenProbeWindow: NSWindow {

    /// Set once by the factory so a guard failure can name the suite that
    /// created the window rather than this file.
    fileprivate var probeOrigin: String = "<unknown>"

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // The origin is pinned, not merely set once. A probe window is resized a
    // great deal - `AppShellBodyWidthSelfTest` alone sweeps a dozen widths per
    // case - and almost every one of those calls passes `x: 0`, which would
    // walk the window straight back onto the display. Pinning here is what
    // makes "off every screen" a property of the type rather than something
    // each of ~117 call sites has to remember.
    //
    // Measured: `setFrame(_:display:)` is the funnel for `setContentSize` and
    // for `zoom(nil)` (so a test that clicks the real zoom button still
    // observes a real size change, and no longer flashes a maximised window
    // onto the captain's screen), while `setFrameOrigin` and
    // `setFrameTopLeftPoint` reposition on their own and need their own
    // overrides.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: OffScreenProbe.parkedOrigin, size: frameRect.size), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(NSRect(origin: OffScreenProbe.parkedOrigin, size: frameRect.size),
                       display: flag, animate: animate)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(OffScreenProbe.parkedOrigin)
    }

    override func setFrameTopLeftPoint(_ point: NSPoint) {
        super.setFrameOrigin(OffScreenProbe.parkedOrigin)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        guard place != .out else { return }
        OffScreenProbe.enforceOffScreen(self)
    }
}

enum OffScreenProbe {

    /// Far enough left that no plausible display arrangement reaches it, and
    /// the value every migrated suite used to pass to `init` in the belief that
    /// it worked.
    static let parkedOrigin = NSPoint(x: -20_000, y: 0)

    /// A real, fully-chromed window parked off every screen.
    ///
    /// Takes a **size**, not a rect: the origin handed to `NSWindow.init` is
    /// discarded by AppKit's initial placement (see this file's header), so
    /// accepting one would be inviting the next caller to believe a number that
    /// does nothing.
    ///
    /// Does **not** order the window in - each suite keeps its own decision
    /// about that, because `isVisible` is a real observable several of them
    /// assert on.
    static func window(size: NSSize,
                       styleMask: NSWindow.StyleMask = [.titled],
                       file: StaticString = #fileID,
                       line: UInt = #line) -> OffScreenProbeWindow {
        let window = OffScreenProbeWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false)
        window.probeOrigin = "\(file):\(line)"
        window.setFrameOrigin(parkedOrigin)
        enforceOffScreen(window)
        return window
    }

    /// Convenience for the common `width:`/`height:` call shape.
    static func window(width: CGFloat,
                       height: CGFloat,
                       styleMask: NSWindow.StyleMask = [.titled],
                       file: StaticString = #fileID,
                       line: UInt = #line) -> OffScreenProbeWindow {
        window(size: NSSize(width: width, height: height),
               styleMask: styleMask, file: file, line: line)
    }

    /// True when no screen's frame intersects `window`'s.
    ///
    /// A host with no screens at all (a genuinely headless runner) has nothing
    /// to leak onto, so it answers `true` - which is the honest reading, not a
    /// loophole: this guard exists to catch a window landing on a display that
    /// does exist.
    static func isOffScreen(_ window: NSWindow) -> Bool {
        !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// Fail the run rather than let a probe window land on the captain's
    /// display.
    ///
    /// `exit(1)` rather than `fatalError`: the runner keys on a suite's exit
    /// status (`Scripts/run-all-tests.sh`), so this reports as a plain `FAIL`
    /// for that suite, and it leaves no crash report behind on the captain's
    /// own machine.
    static func enforceOffScreen(_ window: NSWindow) {
        guard !isOffScreen(window) else { return }
        let origin = (window as? OffScreenProbeWindow)?.probeOrigin ?? "<not an OffScreenProbeWindow>"
        print("  FAIL: a self-test window is ON the captain's display: \(window.frame) "
            + "intersects \(NSScreen.screens.map { $0.frame })")
        print("        created at \(origin). Build it with `OffScreenProbe.window(...)` and do not "
            + "re-position it onto a screen; see OffScreenProbeWindow.swift.")
        exit(1)
    }
}

#endif
