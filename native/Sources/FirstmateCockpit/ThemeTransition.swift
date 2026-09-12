// Manjesh Grand Line - native macOS app.
//
// K3 of the UI modernization audit (`data/grandline-ui-modernization-audit/
// report.md` §3K): "Theme switching is instant and global - animate it. A
// 200ms crossfade on theme change (snapshot old, fade to new) turns the app's
// most dramatic visual event from a flash into a flourish. `ThemeManager` is
// the single choke point."
//
// It is also the last outstanding item of §3L's motion spec - every other
// entry in that list (navigation crossfade, segmented-thumb slide,
// sheet/palette pop, toast rise, row-entrance stagger, button-state ease,
// card press) shipped with its own finding in an earlier round.
//
// **Why a snapshot overlay rather than animating the colours themselves.**
// The tempting alternative is to run the observer fan-out inside
// `HelmMotion.animateLayers`, so every layer-backed fill and border
// cross-fades on its own. It was rejected because it is a *partial*
// crossfade that reads worse than none: `NSTextField.textColor` is not an
// animatable property, so every label in the window would snap to its new
// colour while the surfaces behind them faded - which is exactly the
// "half-themed" reading this app has been corrected for twice. A snapshot
// covers text, glyphs, gradients and terminal cells alike, because it is a
// picture of the whole thing.
//
// **The one honest hole, and why it is a guard rather than a caveat.**
// `cacheDisplay` does not capture `WKWebView` content - that is composited
// out of process, and this codebase already records the same limitation from
// the Whiteboard's own self-test. On the three web-hosted islands
// (Whiteboard, Code Preview, Docs) a snapshot would therefore show a blank
// rectangle where the canvas or the editor is, and fade *that* in over the
// real thing: a flash of nothing, which is worse than the instant switch the
// captain has today. So the coordinator looks for a visible `WKWebView`
// first and skips the transition when it finds one, leaving those three pages
// switching exactly as they do now. §3M's own opinion on those islands is
// that they are "worlds of their own", which is the same judgement.
//
// **Only `setTheme` animates, never `reapplyCurrentTheme`.** That second
// entry point exists for GL-32's chrome-text-scale change, which re-derives
// every font and re-lays out; cross-fading a snapshot over text that is
// simultaneously changing size and re-flowing would read as a glitch rather
// than a transition. A scale change stays instant.

import AppKit
import WebKit

/// Wraps a theme change in the 200ms crossfade, or applies it instantly when
/// it should not animate.
///
/// One instance, owned by `AppDelegate` and handed to
/// `ThemeManager.transitionCoordinator` once the window is live. It is
/// deliberately **not** installed by `AppShellController`: several
/// window-backed self-tests mount a real shell and call `setTheme`, and a
/// transient snapshot overlay on top of the view they are about to measure
/// would be a rendering hazard for every one of them. Production wiring lives
/// at the one place self-tests never reach (`applicationDidFinishLaunching`),
/// and this type is driven directly by its own suite instead.
final class ThemeTransitionCoordinator {

    /// The report's own number.
    static let duration: TimeInterval = 0.2

    private weak var window: NSWindow?
    /// The snapshot currently fading out, if any - held so a second theme
    /// change lands on a clean view tree rather than stacking overlays.
    private var liveOverlay: NSImageView?

    init(window: NSWindow) {
        self.window = window
    }

    /// Apply a theme change, cross-fading from the state on screen now.
    ///
    /// `apply` is the real change (`ThemeManager`'s own persist-and-fan-out);
    /// it is called exactly once on every path, so a caller can never end up
    /// with the animation but not the theme.
    func performThemeChange(_ apply: () -> Void) {
        // Interruptible: a change arriving mid-fade removes the stale
        // snapshot *before* the new one is taken, so the new snapshot shows
        // the state actually on screen rather than a half-faded picture of an
        // older one, and overlays never stack.
        dropLiveOverlay()

        guard let overlay = makeSnapshotOverlay() else {
            apply()
            return
        }
        apply()
        liveOverlay = overlay
        HelmMotion.fade(overlay, to: 0, duration: Self.duration, animated: true)
        // Removal is scheduled rather than tied to the animation's completion
        // so the view is guaranteed to go away even when `fade` took its
        // Reduce Motion path and set `alphaValue` directly with no animation
        // to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self, weak overlay] in
            guard let overlay, overlay === self?.liveOverlay else {
                overlay?.removeFromSuperview()
                return
            }
            self?.dropLiveOverlay()
        }
    }

    private func dropLiveOverlay() {
        liveOverlay?.removeFromSuperview()
        liveOverlay = nil
    }

    /// The frozen picture of the current state, already installed on top of
    /// the content view - or `nil` when this change should not animate.
    private func makeSnapshotOverlay() -> NSImageView? {
        guard !HelmMotion.isReduced else { return nil }
        guard let window, window.isVisible, let content = window.contentView else { return nil }
        let bounds = content.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        guard !Self.containsVisibleWebContent(content) else { return nil }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        content.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let overlay = ThemeSnapshotOverlay(frame: bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        // Frame-based, not Auto Layout: it exists for a fifth of a second and
        // never needs to track a resize, and adding constraints to the
        // content view would put a transient participant into the one
        // constraint graph AGENTS.md's gotchas (11)/(13)/(14) are all about.
        overlay.autoresizingMask = [.width, .height]
        return overlay
    }

    /// Is a `WKWebView` currently on screen anywhere in this tree?
    ///
    /// Hidden subtrees are skipped, which matters: every destination in this
    /// app is mounted once and then only hidden (GL-37), so the Whiteboard
    /// and Code Preview web views exist in the tree for the whole session.
    /// Vetoing on their mere presence would disable the crossfade app-wide
    /// after one visit to either page.
    static func containsVisibleWebContent(_ view: NSView) -> Bool {
        if view.isHidden { return false }
        if view is WKWebView { return true }
        for sub in view.subviews where containsVisibleWebContent(sub) { return true }
        return false
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Is the fading snapshot transparent to the mouse? A 200ms window in
    /// which every click lands on a picture is a real defect, not a cosmetic
    /// one - see `ThemeSnapshotOverlay`.
    var debugOverlayIsHitTestTransparent: Bool {
        guard let overlay = liveOverlay, let content = overlay.superview else { return false }
        return overlay.hitTest(NSPoint(x: content.bounds.midX, y: content.bounds.midY)) == nil
    }

    /// The snapshot currently fading, for a suite that needs to assert one
    /// was taken at all (and that a second change did not stack a second).
    var debugLiveOverlay: NSImageView? { liveOverlay }
    #endif
}

/// The fading snapshot itself - an image view that is transparent to the
/// mouse.
///
/// **Load-bearing, not a tidy-up**, and the same lesson `ConsoleCardChrome`
/// records for the same shape: this view covers the entire content view for
/// 200ms, so without `hitTest` returning `nil` every click, drag and scroll
/// in that window would land on a picture instead of on the real, already
/// re-themed control underneath - the app would go briefly dead on every
/// theme change. Disabling the control is not enough to rely on: `hitTest` is
/// what AppKit routes mouse and scroll events by.
private final class ThemeSnapshotOverlay: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
