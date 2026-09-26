// Grand Line - native macOS app.
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
// So the lights are repositioned by hand, and the main hook is a layout
// pass. Measured: a manual `setFrameOrigin` survives a runloop turn, a
// key/resign, and an appearance change, and is undone by a window resize, a
// `title` change, a `styleMask` touch, and - the one that matters, because
// this app does it on every resize (`AppShellController.
// reassertBodyContainerWidthTie`) - any forced `layoutSubtreeIfNeeded()`.
// Re-applying from the content view's own `layout()` covers the resize and
// forced-layout cases, including a synchronous layout with no intervening
// runloop turn.
//
// **It does NOT, on its own, cover a title change - a real, captain-reported
// regression, not a theoretical gap.** A window resize/move genuinely
// changes this view's geometry, which AppKit marks `needsLayout` for on its
// own; a title change does neither, so `layoutSubtreeIfNeeded()` alone is a
// no-op after one (it only calls `layout()` if something already marked the
// view dirty) and the lights stay at AppKit's own stock, uncentred position
// until the next real resize/move. A Console tab's shell reports its own
// title on ordinary activity (`ConsoleController+Tabs.swift`'s
// `updateWindowTitle`/`setTerminalTitle`), so this could fire many times a
// minute during real use - matching the captain's own report exactly
// ("after going through a couple of consoles", fixed by "moving the
// window", a real geometry change). `ChromeFusionRootView.
// viewDidMoveToWindow` closes this with its own `NSKeyValueObservation` on
// `window.title`, explicitly marking the view dirty before forcing the
// layout - see that class's own doc comment.
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
        // Remember where the cluster ended up, so `trafficLightHitTest` can
        // reject the overwhelming majority of points with one rect test
        // instead of resolving three system buttons - see that method for why
        // the difference is not academic.
        setClusterRect(buttons.reduce(NSRect.null) {
            $0.union($1.convert($1.bounds, to: nil))
        }, for: window)
    }

    // MARK: PF9 - the cluster-rect cache holds windows weakly and prunes
    //
    // PF9 of the 2026-09-25 full review. This cache used to be
    // `[ObjectIdentifier(window): NSRect]` and nothing ever removed an entry,
    // which is two separate defects wearing one coat:
    //
    //   1. **A leak.** Every host page, the host editor, the probe's windows
    //      and every window a self-test mounts left an entry behind for the
    //      life of the process. Small individually; unbounded by construction,
    //      which GL-35 is about.
    //   2. **An aliasing hazard, which is the one that could actually be
    //      seen.** `ObjectIdentifier` is the object's address. A deallocated
    //      window's address is free for reuse, so a *later* window allocated
    //      there inherits the dead one's cached cluster rect - and
    //      `trafficLightHitTest` rejects every point outside that rect before
    //      resolving a button. A window whose inherited rect is in the wrong
    //      place has dead traffic lights, which is precisely the
    //      captain-reported bug the forwarding below exists to fix.
    //
    // Holding the window **weakly** fixes both at once: an entry whose window
    // is gone is dropped on the next write, and the lookup compares object
    // identity (`===`) against a live reference rather than a recycled
    // address, so an alias cannot be mistaken for a hit.
    private final class ClusterRectEntry {
        weak var window: NSWindow?
        var rect: NSRect
        init(window: NSWindow, rect: NSRect) {
            self.window = window
            self.rect = rect
        }
    }

    private static var clusterRects: [ClusterRectEntry] = []

    private static func setClusterRect(_ rect: NSRect, for window: NSWindow) {
        // Prune on write: the cache is only ever touched from the main thread
        // and only by `positionTrafficLights`, so this is the one place an
        // entry can be created and the natural place to drop the dead ones.
        clusterRects.removeAll { $0.window == nil }
        if let existing = clusterRects.first(where: { $0.window === window }) {
            existing.rect = rect
            return
        }
        clusterRects.append(ClusterRectEntry(window: window, rect: rect))
    }

    private static func clusterRect(for window: NSWindow) -> NSRect? {
        clusterRects.first { $0.window === window }?.rect
    }

    #if FM_SELFTESTS
    /// How many windows the cache is currently holding a rect for, so a suite
    /// can assert it shrinks as windows go away.
    static var debugClusterRectCount: Int { clusterRects.count }
    static func debugResetClusterRects() { clusterRects.removeAll() }
    #endif

    /// **The half A1 shipped without, and the reason close/minimise/zoom were
    /// dead to the mouse for every captain on every build since it landed.**
    ///
    /// `positionTrafficLights` moves the buttons to the bar's own centre -
    /// measured on a real window, `frame.origin.y == -14` inside a superview
    /// whose `bounds.height` is 32. That is *entirely outside* their own
    /// superview, and AppKit's default `hitTest(_:)` rejects a point outside
    /// a view's frame **before** it ever asks that view's subviews. So the
    /// cluster rendered perfectly (a view draws outside its superview's
    /// bounds; only clipping stops that, and the titlebar does not clip) and
    /// received nothing: measured on the real running app, a `hitTest` at
    /// each button's own rendered centre returned a plain `NSView` rather
    /// than the button, for all three.
    ///
    /// That is exactly the captain's "the app max window size and closing is
    /// also not working", and it explains their own workaround too: a real
    /// move or resize makes AppKit reset the cluster to its stock position
    /// *inside* the titlebar, where it is briefly clickable again until the
    /// next layout pass moves it back out.
    ///
    /// The fix is deliberately **hit-test forwarding rather than
    /// reparenting**. Re-adding the buttons as subviews of the bar would also
    /// work and is what several apps do, but it takes ownership of system
    /// views away from AppKit across full-screen transitions and style-mask
    /// changes; this is purely additive, leaves the buttons where AppKit put
    /// them, and is directly assertable with the one measurement that was
    /// failing.
    ///
    /// `point` is in the window's base coordinates - which is what a content
    /// view's own `hitTest(_:)` is handed, since its superview (the theme
    /// frame) shares the window's origin.
    /// Which events this forwarding is for. **Review bug B3.**
    ///
    /// `GrandLine-2026-09-25-131709.ips`: `EXC_BAD_ACCESS`, "Thread stack size
    /// exceeded due to excessive recursion", with
    /// `-[NSView(NSTrackingArea) cursorUpdate:]` ->
    /// `-[NSTitlebarContainerView _nextResponderForEvent:]` ->
    /// `ChromeFusionRootView.hitTest(_:)` -> `trafficLightHitTest` repeating
    /// until the stack was gone. The mechanism: this returns a button that
    /// lives in the **titlebar container**, not in the content view, so when
    /// AppKit forwards a `cursorUpdate:` up that button's responder chain the
    /// container hit-tests the content view again, gets the same button back,
    /// and the two feed each other. The captain runs the app full screen most
    /// of the time, where `:227` returns nil before any of this - which is
    /// probably why one probe caught it and three days of real use did not.
    ///
    /// **Deliberately a deny-list rather than an allow-list, and the reason is
    /// what could be verified.** The forwarding only ever existed to make a
    /// *click* reach a repositioned button, so answering only for a click
    /// reads like the tighter fix - but it rests on
    /// `NSApp.currentEvent` being the mouse-down while AppKit hit-tests for
    /// one, and this repository cannot check that: the suite's own real-click
    /// case (`test_a1ZoomButtonReallyZooms`) skips, because a headless process
    /// cannot make a window key, and a suite calling `NSWindow.sendEvent`
    /// directly never sets `currentEvent` at all. An allow-list that is wrong
    /// about that trades a rare crash for close/minimise/zoom being dead
    /// again, which is the captain-reported bug this forwarding was written
    /// for in the first place.
    ///
    /// The cursor and tracking family needs no argument in either direction:
    /// none of them is a click, none of them ever had any business resolving
    /// to a traffic-light button, and they are the family the crash came
    /// from. Everything else keeps today's behaviour exactly, including "no
    /// current event". `hitTestDepth` is what covers the rest, structurally.
    static func forwardingApplies(to eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited:
            return false
        default:
            return true
        }
    }

    /// The type of the event AppKit is currently dispatching, or nil.
    ///
    /// `NSApp` is an implicitly-unwrapped `NSApplication!` and is genuinely
    /// nil in a headless suite, where reading a property on it *crashes*
    /// rather than failing (AGENTS.md's own rule) - hence the `if let`. The
    /// override is how a suite drives a specific event type without a running
    /// application.
    static func currentEventType() -> NSEvent.EventType? {
        #if FM_SELFTESTS
        if let override = debugCurrentEventTypeOverride { return override() }
        #endif
        guard let app = NSApp else { return nil }
        return app.currentEvent?.type
    }

    #if FM_SELFTESTS
    /// GL-27: debug builds only. Returns the type `currentEventType()` reports.
    /// Returning `.some(nil)` models "AppKit is dispatching nothing".
    static var debugCurrentEventTypeOverride: (() -> NSEvent.EventType?)?
    #endif

    /// Re-entrancy depth, per the B3 recursion above.
    ///
    /// The event-type gate closes the path that was actually captured; this is
    /// the backstop for any other route from a returned button back into this
    /// function, because the defect is structural - anything that hit-tests
    /// the content view while resolving an event *for a view this returns* is
    /// a cycle, whatever event it happens to be carrying. Main-thread only, by
    /// the same argument `hitTest` itself is.
    private static var hitTestDepth = 0

    static func trafficLightHitTest(_ point: NSPoint, in window: NSWindow?) -> NSView? {
        // B3's backstop. Already inside this call means the button we are
        // about to return is what asked, which is the cycle.
        guard hitTestDepth == 0 else { return nil }
        hitTestDepth += 1
        defer { hitTestDepth -= 1 }

        // B3: never for a cursor or tracking event. See `forwardingApplies`.
        guard forwardingApplies(to: currentEventType()) else { return nil }

        // Full screen: AppKit owns the cluster in its own auto-hiding overlay
        // and nothing is repositioned, so it must keep its own hit testing.
        guard let window, !isFullScreen(window) else { return nil }
        // **The cheap rejection has to come first, and it is not an
        // optimisation.** This runs on *every* hit test in the window -
        // which includes every mouse-moved and every step of every drag -
        // and `standardWindowButton(_:)` is a window-level accessor that can
        // reach into the titlebar. Resolving three of them per hit test made
        // a real, previously-passing window-backed suite
        // (`FM_RUN_SHIFT_BOARD_VIEW_TESTS`, which synthesizes drags) stop
        // finishing at all - measured: it passes in well under a minute
        // without this and had not produced a line after ten with it. The
        // cluster only ever moves in `positionTrafficLights`, so its rect is
        // cached there and this is one containment test for every point that
        // is not on a traffic light.
        guard let cluster = clusterRect(for: window),
              !cluster.isNull,
              cluster.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) else { return nil }

        for kind in trafficLightKinds {
            guard let button = window.standardWindowButton(kind),
                  !button.isHidden, button.alphaValue > 0.01,
                  let superview = button.superview else { continue }
            // Only a *repositioned* button needs this: one still inside its
            // own superview is reachable through AppKit's own hit testing,
            // and claiming it here would take a click AppKit should have had.
            guard button.frame.minY < 0 || button.frame.maxY > superview.bounds.height else { continue }
            let inWindow = button.convert(button.bounds, to: nil)
            // macOS gives the stock cluster a slightly larger clickable area
            // than the 14pt dot. `hitSlop` stays well inside the gap between
            // the cluster and the bar's first real control
            // (`reservedLeadingInset` leaves 12pt), so it cannot steal a
            // click meant for the back button or the wordmark.
            if inWindow.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) { return button }
        }
        return nil
    }

    /// How far outside its own 14pt bounds a traffic light still answers a
    /// click. Deliberately smaller than the clearance
    /// `reservedLeadingInset` leaves after the cluster.
    static let hitSlop: CGFloat = 4

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

/// The window's content view, with the two hooks A1 needs: AppKit resets the
/// traffic lights' frames on every layout pass, so the reposition has to ride
/// that same pass. See `WindowChromeFusion`'s header for the measurements
/// behind that.
///
/// **A real, measured regression this class also fixes: a window title
/// change resets the lights too, and - unlike a resize - never marks this
/// view `needsLayout`, so `onLayout` is silently never called again.** A
/// Console tab reports its shell's own title (`ConsoleController+Tabs.swift`'s
/// `updateWindowTitle`/`setTerminalTitle`), which fires on ordinary shell
/// activity (a new prompt, a `cd`), so this could and did happen many times
/// per minute during real use - matching the captain-reported symptom
/// exactly ("after going through a couple of consoles", "moving the window
/// unsticks it" - a move/resize is a real geometry change, which *does* mark
/// this view dirty, and is the only other thing that does).
///
/// Confirmed empirically (a temporary probe, reverted before commit): a bare
/// `layoutSubtreeIfNeeded()` call right after a title change does **nothing**
/// - that method only invokes `layout()` if something already marked the
/// view dirty, and a title change alone never does. `needsLayout = true`
/// immediately before it is what makes the reposition actually happen again.
final class ChromeFusionRootView: NSView {
    var onLayout: (() -> Void)?

    private var titleObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-established on every window change (including to `nil`, which
        // simply drops the old observation) - this view's own `window` is
        // resolved by AppKit at exactly the right time for this, unlike
        // trying to grab a window reference during the controller's
        // `loadView()`, which may run before the view has one.
        titleObservation = window?.observe(\.title, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// A1 moves the traffic lights outside their own superview, which makes
    /// AppKit's own hit testing skip them entirely - see
    /// `WindowChromeFusion.trafficLightHitTest` for the measurement and for
    /// why this forwards rather than reparenting. Without this the buttons
    /// render correctly and do nothing at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let button = WindowChromeFusion.trafficLightHitTest(point, in: window) { return button }
        return super.hitTest(point)
    }
}
