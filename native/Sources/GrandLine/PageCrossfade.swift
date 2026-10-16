// Grand Line - native macOS app.
//
// P3 of the Grand Line vs Automic Vault polish report: a page change used to
// move one way only. The incoming page faded in with a short slide, and the
// outgoing one was hidden in the same frame, so every navigation cut away
// from where the captain was looking before it eased into where they were
// going.
//
// **The technique is `ThemeTransitionCoordinator`'s.** A picture of the
// outgoing page is laid over the body and faded out while the real incoming
// page eases in underneath it. A snapshot rather than keeping the old page up
// and fading it: a destination is hidden by deactivating its pins (gotcha
// (15)), so the old page cannot stay on screen without staying in the
// constraint graph, and that costs a full relayout of a page nobody is
// looking at. A picture costs one `cacheDisplay`.
//
// **Skipped, not slowed, where it would read worse than a cut:** under Reduce
// Motion (`HelmMotion`'s rule), for a navigation to the page already showing,
// and over a visible `WKWebView`, which `cacheDisplay` cannot capture - the
// snapshot would fade a blank rectangle over the real page (the theme
// crossfade's own reasoning).
//
// **Installed by `AppDelegate`, never by `AppShellController`,** for the
// theme crossfade's reason: window-backed suites mount a real shell and
// measure it right after a navigation, and a transient picture over the view
// they are reading would be a hazard for every one of them. `PageCrossfadeSelfTest`
// installs one on its own shell.

import AppKit

final class PageCrossfade {

    /// The picture currently fading, if any - held so a second navigation
    /// mid-fade replaces it rather than stacking a second one on top.
    private var liveOverlay: NSView?

    /// Lay a picture of `page` over its place in `container`, and fade it.
    /// Call **before** `page` is hidden.
    func crossfade(from page: NSView, in container: NSView) {
        drop()
        guard !HelmMotion.isReduced else { return }
        guard page.window?.isVisible == true, !page.isHidden, page.superview === container else { return }
        let bounds = page.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        guard !ThemeTransitionCoordinator.containsVisibleWebContent(page) else { return }
        guard let rep = page.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        page.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let overlay = HitTransparentSnapshotView(frame: page.frame)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        // Frame-based, like the theme crossfade's: it lives for one move
        // duration and must not join the constraint graph.
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        liveOverlay = overlay

        HelmMotion.fade(overlay, to: 0, duration: HelmMotion.moveDuration, animated: true)
        // Scheduled rather than tied to the fade's completion, so the picture
        // is guaranteed to go even if the fade did not animate.
        DispatchQueue.main.asyncAfter(deadline: .now() + HelmMotion.moveDuration) { [weak self, weak overlay] in
            guard let overlay else { return }
            if overlay === self?.liveOverlay { self?.drop() } else { overlay.removeFromSuperview() }
        }
    }

    private func drop() {
        liveOverlay?.removeFromSuperview()
        liveOverlay = nil
    }

    #if FM_SELFTESTS
    /// The picture fading right now, for `PageCrossfadeSelfTest`.
    var debugLiveOverlay: NSView? { liveOverlay }
    #endif
}
