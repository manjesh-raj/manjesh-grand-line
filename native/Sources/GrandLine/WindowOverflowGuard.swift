// Grand Line - native macOS app.
//
// `WindowOverflowGuard` - puts the main window back inside its screen when
// page content, not the captain, pushed it past the screen's edge.
//
// **Why it exists.** A window holds its size at priority 500, so any content
// constraint above 500 resizes it (AGENTS.md gotcha (13)). AppKit grows the
// window to satisfy such a constraint and never shrinks it again on its own.
// `fm/grandline-layout-breaks-refresh-reply` measured the captain's case: the
// Fleet reply composer's one-line "Replying to ..." label asked for 1746pt,
// the window grew from 1512 to 1746, ran past the right edge of a 1512pt
// screen, and stayed that wide on every page after the composer was closed.
// The label is fixed at its source. This is the backstop, so the next view
// that makes the same mistake costs one page and not the rest of the session.
//
// **What counts as overflow.** A window wider than its screen's visible area,
// outside full screen. A captain cannot produce that: dragging, zoom and
// tiling all keep a window inside the screen. So the rule needs no guess about
// who resized the window, and it can never undo a size the captain chose.
//
// **What it does.** It remembers the last frame that fitted. On an overflowing
// resize it logs (GL-11) and restores that frame once, on the next main-queue
// turn, because the resize arrives from inside a layout pass. If the content
// still needs the width, AppKit grows the window again and the guard leaves it
// alone (a visibly wide window beats a resize loop). The next navigation gets
// one more restore, which is the moment the offending view usually goes away.
//
// It is inert with no screen to judge by, which is every off-screen probe
// window. A suite injects `visibleFrame` instead.

import AppKit

final class WindowOverflowGuard {

    /// The area the window must stay inside, or `nil` when there is nothing to
    /// judge by. The window's screen in the app; a suite's fixture rect in a
    /// test, because an `OffScreenProbe` window is on no screen at all.
    var visibleFrame: (NSWindow) -> NSRect? = { $0.screen?.visibleFrame }

    /// The most recent frame that fitted the visible area.
    private(set) var lastFittingFrame: NSRect?

    /// Restores spent since the last navigation. One per navigation, so a
    /// content constraint that still needs the width cannot start a loop.
    private var restoresSinceNavigation = 0
    private static let restoresPerNavigation = 1

    /// Every `NSWindow.didResizeNotification` for the guarded window.
    func windowDidResize(_ window: NSWindow) {
        guard let visible = judgeableVisibleFrame(for: window) else { return }
        guard Self.overflows(window.frame, visible: visible) else {
            lastFittingFrame = window.frame
            return
        }
        AppLog.ui.error("""
            the window was pushed to \(window.frame.width, privacy: .public)pt, past its \
            \(visible.width, privacy: .public)pt screen, by its content - restoring the last frame that fitted
            """)
        guard spendRestore() else { return }
        // The resize arrives from inside a layout pass, where setting the
        // frame again is not safe.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.restore(window)
        }
    }

    /// Every navigation. Synchronous: a navigation is not inside a layout pass.
    func destinationDidChange(in window: NSWindow?) {
        restoresSinceNavigation = 0
        guard let window, let visible = judgeableVisibleFrame(for: window),
              Self.overflows(window.frame, visible: visible) else { return }
        guard spendRestore() else { return }
        restore(window)
    }

    private func judgeableVisibleFrame(for window: NSWindow) -> NSRect? {
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        return visibleFrame(window)
    }

    private func spendRestore() -> Bool {
        guard restoresSinceNavigation < Self.restoresPerNavigation else { return false }
        restoresSinceNavigation += 1
        return true
    }

    private func restore(_ window: NSWindow) {
        guard let visible = judgeableVisibleFrame(for: window),
              Self.overflows(window.frame, visible: visible) else { return }
        window.setFrame(Self.restoredFrame(current: window.frame, lastFitting: lastFittingFrame,
                                           visible: visible),
                        display: true)
    }

    // MARK: Pure

    /// Whether `frame` is wider than `visible`. Half a point of slack for the
    /// non-integral widths a Retina display produces.
    static func overflows(_ frame: NSRect, visible: NSRect) -> Bool {
        frame.width > visible.width + 0.5
    }

    /// The frame to restore: the last fitting width (or the visible width when
    /// nothing fitted yet), the current height and top edge, moved left only
    /// as far as it takes to end inside the visible area.
    static func restoredFrame(current: NSRect, lastFitting: NSRect?, visible: NSRect) -> NSRect {
        let width = min(lastFitting?.width ?? visible.width, visible.width)
        var x = current.minX
        if x + width > visible.maxX { x = visible.maxX - width }
        x = max(x, visible.minX)
        return NSRect(x: x, y: current.minY, width: width, height: current.height)
    }
}
