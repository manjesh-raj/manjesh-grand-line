// Manjesh Grand Line - native macOS app.
//
// `WindowChromeFusion` - A1 of the UI modernization audit
// (`data/grandline-ui-modernization-audit/report.md` §3A): fuse the main
// window's stock titlebar into the floating bar.
//
// **What it does, and what it deliberately does not.** It makes the window
// `.fullSizeContentView` with a transparent, title-less titlebar, so the
// content view covers the whole window and the floating bar becomes the top
// edge. It does **not** hide the standard window buttons: unlike the two
// `NSPanel`s that already use this idiom (`UnifiedSearch.swift`,
// `ShiftQuickCapture.swift`, which hide all three), a main window has to stay
// closable, minimisable and zoomable - only the *title text* and the opaque
// strip behind it go away.
//
// **Measured, not assumed** (a real `NSWindow`, this machine, probes reverted
// before commit - AGENTS.md's "verifying native UI bugs" convention):
//
//   - A stock `.titled` window's titlebar is **32pt**, not the report's
//     estimated ~28 - so the reclaimed height is 32.
//   - With `.fullSizeContentView` the traffic lights land at **top-down
//     centre 16**, cluster x **9...69**. `trafficLightClusterWidth` (78) is
//     that 69 plus the same ~9pt AppKit already leaves on the left.
//   - The lights are **not** vertically centred in the bar by any stock
//     configuration. An `NSToolbar` was measured as the Apple-sanctioned way
//     to grow the titlebar region and re-centre them, and it quantises: no
//     toolbar 32/centre 16, `.unifiedCompact` 40/centre 20, `.unified`
//     52/centre 26, `.expanded` 68/centre 16 - **regardless of the toolbar
//     item's own height**. None of those is the bar's own centre (39), so the
//     toolbar route cannot express this design.
//
// So the lights are repositioned by hand, and the *only* hook that actually
// holds is a layout pass. Measured: a manual `setFrameOrigin` survives a
// runloop turn, a key/resign, and an appearance change, and is undone by a
// window resize, a `title` change, a `styleMask` touch, and - the one that
// matters, because this app does it on every resize
// (`AppShellController.reassertBodyContainerWidthTie`) - any forced
// `layoutSubtreeIfNeeded()`. Re-applying from the content view's own
// `layout()` covers every one of those, including a synchronous layout with
// no intervening runloop turn.
//
// **Do not observe the titlebar view's own frame.** Setting
// `postsFrameChangedNotifications` on AppKit's private `NSTitlebarView` and
// observing it segfaulted the probe process outright (exit 139, no output);
// the `layout()` hook needs neither.
//
// **Full screen is left entirely to AppKit.** There, macOS hides the lights
// and shows them in its own auto-hiding overlay titlebar, which is a
// different container - repositioning into it would be wrong, and there is no
// cluster on screen to reserve room for either, so `leadingInset` drops back
// to the plain one.

import AppKit

enum WindowChromeFusion {

    /// Width of the traffic-light cluster itself, in *window* coordinates.
    /// Measured: close at x=9, zoom trailing at x=69.
    static let trafficLightClusterSpan: CGFloat = 60

    /// **The cluster has to move sideways too, and the report's own number
    /// does not account for that.** A1 says "left padding ~78pt", which is
    /// the cluster's natural 9...69 plus AppKit's own 9pt inset - correct
    /// for a bar that starts at the window's edge. This bar does not: it is
    /// inset `sideMargin` (22pt), so leaving the lights where AppKit puts
    /// them leaves the close button sitting on the page ground *outside* the
    /// bar's rounded leading edge, with the other two inside it. Confirmed
    /// in a real render of a real window before it was changed.
    ///
    /// So the cluster is placed at the bar's own content inset, exactly like
    /// any other leading content, and `leadingInset` reserves the room it
    /// then needs. Both numbers come from this one place so they cannot
    /// drift apart.
    static func trafficLightLeadingX(sideMargin: CGFloat, plain: CGFloat) -> CGFloat {
        sideMargin + plain
    }

    /// How far down a fused window's own content must start before it clears
    /// the traffic-light cluster (F2a).
    ///
    /// The lights sit at a top-down centre of 16 (measured, see this file's
    /// header) and are ~14pt across, so the cluster's bottom edge is about 23.
    /// 32 is that plus a row of breathing room - and it is deliberately a
    /// *derived* pair rather than a literal, so a future macOS that moves the
    /// cluster moves this with it.
    ///
    /// Only for a window with no floating bar of its own to hand the lights
    /// to. `AppShellController`'s window re-centres them onto the bar instead
    /// and reserves room with `leadingInset`.
    static let naturalVerticalCenter: CGFloat = 16
    static var contentTopClearance: CGFloat { naturalVerticalCenter * 2 }

    /// Turn a stock window into the fused one. Idempotent.
    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Deliberately NOT hidden - see this file's header. A main window
        // keeps its close/minimise/zoom controls; only the title strip goes.
        for kind in trafficLightKinds {
            window.standardWindowButton(kind)?.isHidden = false
        }
    }

    /// `true` while AppKit owns the lights in its own full-screen overlay.
    static func isFullScreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen)
    }

    /// How far a bar pinned `sideMargin` from the window edge must inset its
    /// own leading content so nothing sits under the traffic lights.
    ///
    /// `plain` is what the bar would use with no lights to avoid - which is
    /// also what full screen gets back, since the cluster is not on screen
    /// there.
    static func leadingInset(for window: NSWindow?, sideMargin: CGFloat, plain: CGFloat) -> CGFloat {
        // A window in full screen has no cluster on screen to reserve for.
        // A **nil** window is the opposite case and must not share that
        // branch: it means "not in a window yet", which a bar hits on its
        // very first layout pass, and under-reserving there would render the
        // leading content under the lights for a frame. Reserve by default;
        // only a window known to be full screen gives the room back.
        if let window, isFullScreen(window) { return plain }
        return reservedLeadingInset(plain: plain)
    }

    /// The room the cluster needs inside the bar: its own inset, the
    /// cluster, then the same inset again before the bar's first control.
    static func reservedLeadingInset(plain: CGFloat) -> CGFloat {
        plain + trafficLightClusterSpan + plain
    }

    /// Re-centre the cluster on `verticalCenter`, measured top-down from the
    /// window's own top edge.
    ///
    /// Call this from a `layout()` override on the window's content view -
    /// see the header for why nothing else holds. Cheap enough to run on
    /// every pass: it compares before it writes, so a pass that changed
    /// nothing touches no frames.
    static func positionTrafficLights(in window: NSWindow?, verticalCenter: CGFloat, leadingX: CGFloat) {
        guard let window, !isFullScreen(window) else { return }
        // Re-entrancy: moving a subview can drive another layout pass, and
        // this is called *from* one.
        if isPositioning { return }
        isPositioning = true
        defer { isPositioning = false }

        let buttons = trafficLightKinds.compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first else { return }
        // Shift the whole cluster rather than placing each button: AppKit
        // owns the spacing between them, and re-deriving it here would drift
        // the moment a future macOS changes it.
        let dx = leadingX - first.frame.minX
        for button in buttons {
            guard let titlebar = button.superview else { continue }
            // The titlebar container is bottom-up and its own height is the
            // titlebar's, so a top-down target converts through its bounds.
            let wantedY = titlebar.bounds.height - verticalCenter - button.frame.height / 2
            let wanted = NSPoint(x: button.frame.origin.x + dx, y: wantedY)
            if abs(button.frame.origin.x - wanted.x) > 0.01 || abs(button.frame.origin.y - wanted.y) > 0.01 {
                button.setFrameOrigin(wanted)
            }
        }
    }

    private static var isPositioning = false
    private static let trafficLightKinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// The cluster's current top-down centre in the content view's own
    /// coordinates, or `nil` if the window has no close button.
    static func trafficLightCenterForTests(in window: NSWindow) -> CGFloat? {
        guard let content = window.contentView,
              let button = window.standardWindowButton(.closeButton) else { return nil }
        let inContent = content.convert(button.convert(button.bounds, to: nil), from: nil)
        return content.bounds.height - inContent.midY
    }

    /// The cluster's horizontal extent in the content view's own coordinates.
    static func trafficLightSpanForTests(in window: NSWindow) -> (minX: CGFloat, maxX: CGFloat)? {
        guard let content = window.contentView,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return nil }
        let c = content.convert(close.convert(close.bounds, to: nil), from: nil)
        let z = content.convert(zoom.convert(zoom.bounds, to: nil), from: nil)
        return (min(c.minX, z.minX), max(c.maxX, z.maxX))
    }
    #endif
}

/// The window's content view, with the one hook A1 needs: AppKit resets the
/// traffic lights' frames on every layout pass, so the reposition has to ride
/// that same pass. See `WindowChromeFusion`'s header for the measurements
/// behind that.
final class ChromeFusionRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
