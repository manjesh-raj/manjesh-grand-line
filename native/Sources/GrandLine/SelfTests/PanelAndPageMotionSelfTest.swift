// Grand Line - native macOS app.
//
// P3 of the Grand Line vs Automic Vault polish report: panels and page
// changes that move both ways, and pages that keep the captain's place.
//
// What is asserted:
//
//   1. **The shared window fades** (`HelmMotion.fadeIn`/`fadeOut`): a window
//      comes in from transparent, goes out over a fade and is ordered out
//      only once the fade lands, stops taking clicks the moment it starts
//      leaving, is not taken down if reopened mid-fade, and does all of it
//      instantly under Reduce Motion. `HelmConfirm` and Quick Capture use
//      these and `fadeInContent`, so they are covered here as primitives.
//   2. **`HelmBarPanel` wires them, with its state synchronous.** `isShown`
//      flips the moment `show`/`close` is called, while the pixels fade -
//      the brief's "update state synchronously" rule, and what every toggle
//      and suite reads.
//   3. **The outgoing page crossfades** (`PageCrossfade`): a hit-transparent
//      picture of the page being left sits over the body and goes away, it
//      is skipped for a navigation to the page already showing and under
//      Reduce Motion, and only a shell that installed one gets one.
//   4. **A page keeps its scroll position** across a visit elsewhere, and
//      goes to the top when its content changed height (`HelmScrollMemory`).
//   5. **Source guards** for the two surfaces this suite does not present:
//      `HelmConfirm` is modal (window-backed suites stay free of modal
//      sessions) and Quick Capture positions itself on the real main screen.
//
// No posted events, and no fixed sleeps: anything that waits for a fade
// pumps the run loop until the expected state lands, bounded.
//
// Run with:
//   swift build && FM_RUN_PANEL_AND_PAGE_MOTION_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: real windows, a real shell, real `viewWillAppear`s. Listed in
// `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum PanelAndPageMotionSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var ok = true
        let savedTheme = ThemeManager.shared.theme
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            HelmMotion.reducedOverrideForTests = nil
        }
        checkTheWindowFades(&ok)
        checkTheBarPanel(&ok)
        checkThePageCrossfade(&ok)
        checkScrollPositionIsKept(&ok)
        checkTheUnpresentedSurfaces(&ok)
        print(ok ? "PanelAndPageMotionSelfTest: all checks passed" : "PanelAndPageMotionSelfTest: FAILED")
        return ok
    }

    // MARK: 1. The shared window fades

    private static func checkTheWindowFades(_ ok: inout Bool) {
        print("\n-- P3: a window fades in, fades out, then orders out --")
        HelmMotion.reducedOverrideForTests = false
        let window = OffScreenProbe.window(width: 200, height: 100)
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        HelmMotion.fadeIn(window: window)
        check(window.alphaValue < 1, "fadeIn did not start the window transparent (alpha \(window.alphaValue))", &ok)
        pump { window.alphaValue >= 0.999 }
        check(window.alphaValue >= 0.999, "fadeIn never reached full opacity (alpha \(window.alphaValue))", &ok)

        var orderedOut = false
        HelmMotion.fadeOut(window: window) { orderedOut = true; window.orderOut(nil) }
        check(!orderedOut, "fadeOut ordered the window out before fading it", &ok)
        check(window.ignoresMouseEvents, "a leaving window still takes clicks during its fade", &ok)
        pump { orderedOut }
        check(orderedOut && !window.isVisible, "fadeOut never ordered the window out", &ok)
        check(!window.ignoresMouseEvents && window.alphaValue == 1,
              "a window that faded out was left unclickable or transparent for its next show", &ok)

        // Reopened mid-fade: the completion must not take it back down.
        window.orderFront(nil)
        HelmMotion.fadeIn(window: window)
        var reopened = false
        var secondOrderOut = false
        HelmMotion.fadeOut(window: window, stillClosed: { !reopened }) { secondOrderOut = true; window.orderOut(nil) }
        reopened = true
        HelmMotion.fadeIn(window: window)
        pump(timeout: HelmMotion.moveDuration * 4) { false }
        check(!secondOrderOut && window.isVisible, "a window reopened mid-fade was ordered out by the old fade", &ok)

        // Reduce Motion: the end state, instantly.
        HelmMotion.reducedOverrideForTests = true
        HelmMotion.fadeIn(window: window)
        check(window.alphaValue == 1, "Reduce Motion still faded the window in", &ok)
        var instant = false
        HelmMotion.fadeOut(window: window) { instant = true; window.orderOut(nil) }
        check(instant && !window.isVisible, "Reduce Motion did not order the window out at once", &ok)
        HelmMotion.reducedOverrideForTests = false

        // The modal-safe entrance fades the content layer, explicitly.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = content
        window.orderFront(nil)
        HelmMotion.fadeInContent(of: window)
        check((content.layer?.animationKeys() ?? []).contains("opacity"),
              "fadeInContent attached no opacity animation (keys \(content.layer?.animationKeys() ?? []))", &ok)
        check(content.layer?.opacity == 1, "fadeInContent did not end at full opacity", &ok)
        HelmMotion.reducedOverrideForTests = nil
        if ok { print("  OK   in, out, reopened mid-fade, Reduce Motion, and the modal-safe entrance") }
    }

    // MARK: 2. HelmBarPanel

    private static func checkTheBarPanel(_ ok: inout Bool) {
        print("\n-- P3: a bar panel's state is synchronous while it fades --")
        for reduced in [false, true] {
            HelmMotion.reducedOverrideForTests = reduced
            let label = reduced ? "Reduce Motion" : "motion on"
            let host = OffScreenProbe.window(width: 400, height: 200)
            defer { host.orderOut(nil) }
            let anchor = NSView(frame: NSRect(x: 300, y: 150, width: 30, height: 30))
            host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            host.contentView?.addSubview(anchor)
            host.orderFront(nil)
            let content = NSViewController()
            content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            let panel = HelmBarPanel(content: content)

            panel.show(under: anchor)
            check(panel.isShown, "\(label): isShown is false straight after show", &ok)
            check(reduced ? panel.panel.alphaValue == 1 : panel.panel.alphaValue < 1,
                  "\(label): the panel's alpha is \(panel.panel.alphaValue) straight after show", &ok)
            pump { panel.panel.alphaValue >= 0.999 }

            var closedCallbacks = 0
            panel.onClose = { closedCallbacks += 1 }
            panel.close()
            check(!panel.isShown, "\(label): isShown is still true straight after close", &ok)
            check(closedCallbacks == 1, "\(label): onClose fired \(closedCallbacks) times on close", &ok)
            if reduced {
                check(!panel.panel.isVisible, "Reduce Motion: the panel was not ordered out at once", &ok)
            } else {
                check(panel.panel.isVisible, "motion on: the panel vanished without fading out", &ok)
            }
            pump { !panel.panel.isVisible }
            check(!panel.panel.isVisible, "\(label): the panel was never ordered out", &ok)
            // A second close is a no-op, not a second onClose.
            panel.close()
            check(closedCallbacks == 1, "\(label): a second close fired onClose again", &ok)
        }
        HelmMotion.reducedOverrideForTests = nil
        if ok { print("  OK   isShown and onClose are immediate, the pixels fade, in both Reduce Motion states") }
    }

    // MARK: 3. The outgoing page

    private static func checkThePageCrossfade(_ ok: inout Bool) {
        print("\n-- P3: the outgoing page crossfades --")
        HelmMotion.reducedOverrideForTests = false
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        shell.show(.settings)
        shell.view.layoutSubtreeIfNeeded()

        // A shell with none installed - every suite's - cuts, as before.
        shell.show(.updates)
        check(overlays(in: shell.view).isEmpty, "a shell with no PageCrossfade installed drew a snapshot", &ok)

        let crossfade = PageCrossfade()
        shell.pageCrossfade = crossfade
        shell.view.layoutSubtreeIfNeeded()
        shell.show(.settings)
        guard let overlay = crossfade.debugLiveOverlay else {
            fail("navigating away from Updates left no picture of it to fade", &ok)
            return
        }
        check(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil,
              "the fading picture takes clicks - the incoming page would be dead for its whole fade", &ok)
        check(overlay.frame.width > 100 && overlay.frame.height > 100,
              "the picture is \(overlay.frame.size), not the page it replaced", &ok)
        pump { crossfade.debugLiveOverlay == nil && overlays(in: shell.view).isEmpty }
        check(overlays(in: shell.view).isEmpty, "the picture of the outgoing page was never removed", &ok)

        shell.show(.settings)
        check(crossfade.debugLiveOverlay == nil, "a navigation to the page already showing drew a snapshot", &ok)

        HelmMotion.reducedOverrideForTests = true
        shell.show(.updates)
        check(crossfade.debugLiveOverlay == nil, "Reduce Motion still crossfaded the outgoing page", &ok)
        HelmMotion.reducedOverrideForTests = nil
        if ok { print("  OK   a hit-transparent picture fades and goes; skipped when repeated, under Reduce Motion, and uninstalled") }
    }

    private static func overlays(in root: NSView) -> [NSView] {
        var out: [NSView] = []
        func walk(_ view: NSView) {
            if view is HitTransparentSnapshotView { out.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    // MARK: 4. Scroll position

    private static func checkScrollPositionIsKept(_ ok: inout Bool) {
        print("\n-- P3: a page keeps the captain's place unless it changed --")
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        var frame = window.frame
        frame.size = NSSize(width: 1100, height: 420)
        window.setFrame(frame, display: false)
        window.orderFront(nil)
        shell.show(.settings)
        shell.view.layoutSubtreeIfNeeded()
        guard let page = shell.destinationViewIfMountedForTests(RailDestination.settings.slot),
              let scroll = pageScroll(in: page), let document = scroll.documentView else {
            fail("Settings has no page scroll view to measure", &ok)
            return
        }
        let overflow = document.frame.height - scroll.contentView.bounds.height
        // The fixture's discriminating power: there must be room to scroll,
        // or "kept at 0" and "reset to 0" are the same number.
        check(overflow > 120, "Settings only overflows its viewport by \(overflow)pt - nothing to keep", &ok)
        let target = NSPoint(x: 0, y: min(120, max(overflow, 0)))
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)

        shell.show(.updates)
        shell.view.layoutSubtreeIfNeeded()
        shell.show(.settings)
        shell.view.layoutSubtreeIfNeeded()
        check(abs(scroll.contentView.bounds.origin.y - target.y) < 0.5,
              "back on Settings the page is at y \(scroll.contentView.bounds.origin.y), expected the \(target.y) it was left at", &ok)

        // The other half, on the helper directly: a page whose content
        // changed height goes to the top, as before.
        let memory = HelmScrollMemory()
        let plain = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        plain.documentView = doc
        plain.contentView.scroll(to: NSPoint(x: 0, y: 200))
        memory.remember(plain)
        doc.frame.size.height = 900
        var wentToTop = false
        memory.restore(plain) { wentToTop = true }
        check(wentToTop, "a page whose content grew was put back at its old offset rather than at the top", &ok)
        plain.contentView.scroll(to: NSPoint(x: 0, y: 200))
        memory.remember(plain)
        plain.contentView.scroll(to: .zero)
        var resetUnchanged = false
        memory.restore(plain) { resetUnchanged = true }
        check(!resetUnchanged && abs(plain.contentView.bounds.origin.y - 200) < 0.5,
              "an unchanged page was not put back at y 200 (y \(plain.contentView.bounds.origin.y))", &ok)
        if ok { print("  OK   Settings kept y \(target.y) across a visit to Updates; a changed page still goes to the top") }
    }

    /// The page's own document scroll view: the largest one in its tree.
    private static func pageScroll(in page: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
               scroll.frame.height > (best?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(page)
        return best
    }

    // MARK: 5. Source guards

    private static func checkTheUnpresentedSurfaces(_ ok: inout Bool) {
        print("\n-- P3: HelmConfirm and Quick Capture use the shared fades --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP the app's sources are not next to this binary")
            return
        }
        let confirm = (try? String(contentsOf: dir.appendingPathComponent("HelmConfirm.swift"), encoding: .utf8)) ?? ""
        check(confirm.contains("HelmMotion.fadeInContent(of: panel)") && confirm.contains("HelmMotion.fadeOut(window: panel)"),
              "HelmConfirm no longer fades its dialog in and out through HelmMotion", &ok)
        let capture = (try? String(contentsOf: dir.appendingPathComponent("ShiftQuickCapture.swift"), encoding: .utf8)) ?? ""
        let code = capture.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let orderOuts = code.filter { $0.contains("orderOut(") }.count
        check(orderOuts == 1, "Quick Capture orders its window out in \(orderOuts) places - every exit must go through dismiss()'s fade", &ok)
        check(capture.contains("HelmMotion.fadeIn(window: window)"), "Quick Capture no longer fades in", &ok)
        if ok { print("  OK   both route through HelmMotion's fades") }
    }

    // MARK: Helpers

    /// Pump the run loop until `landed()` holds, bounded - never a fixed wait.
    private static func pump(timeout: TimeInterval = 2, until landed: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !landed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

#endif
