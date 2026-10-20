// Grand Line - native macOS app.
//
// P1 of the Grand Line vs Automic Vault polish report: the app's hover and
// press feedback was written to ease over 120ms, and it never did.
//
// **The defect, measured rather than read.** A `wantsLayer` view makes itself
// its layer's delegate, and that delegate answers `NSNull` for every action
// unless the current `NSAnimationContext` has `allowsImplicitAnimation` set.
// So a `layer.backgroundColor` or `layer.transform` written inside a plain
// `runAnimationGroup` - or inside `CATransaction.setAnimationDuration` - lands
// in a single frame. `HelmMotion.animateLayers` is the primitive that sets the
// flag, and before this suite it had one caller (`HelmInputSurface`'s focus
// glow). Measured on `9871bcd` with this file's own cases: every hover and
// press check below failed with `animationKeys() == []`.
//
// **What is asserted, and what deliberately is not.** The thing that was
// broken is "an animation is attached at all", so that is what each case
// reads: `layer.animationKeys()` straight after the real entry point
// (`mouseEntered`, `highlight(_:)`, the press path). Durations and curves are
// taste and are not pinned here - `MotionTableSelfTest` owns the one table
// they come from. Each case also asserts the **end state** (the model value
// the layer will settle on), because an animation towards the wrong value
// would pass a keys-only check.
//
// Every case runs in both Reduce Motion states, since `HelmMotion`'s rule is
// "the end state, instantly - never the same motion, slower": with Reduce
// Motion on, the end state must be reached and the keys must be empty.
//
// The press must also compress about the view's **centre**. A view-backed
// layer's anchor point is its bottom-left corner, so a bare scale transform
// shrinks a control towards that corner. Nobody could see that while the
// press snapped; once it eases it reads as the button sliding down and left.
//
// Run with:
//   swift build && FM_RUN_HOVER_PRESS_EASING_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: an implicit layer action is resolved through the view's own
// layer delegate inside a real window, so this is in `run-all-tests.sh`'s
// `NEEDS_SESSION` list. No posted mouse events and no run-loop timing: every
// read happens synchronously after the call that attaches the animation.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum HoverPressEasingSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        defer { HelmMotion.reducedOverrideForTests = nil }

        let cases: [(String, () -> [String])] = [
            ("a HoverHighlightView's hover fill eases in and out", test_hoverFillEases),
            ("a HoverHighlightView's press eases, about its centre", test_hoverViewPressEases),
            ("a HelmButton's hover fill eases", test_buttonHoverEases),
            ("a HelmButton's press eases, about its centre", test_buttonPressEases),
            ("a module card's hover lift and shadow ease", test_moduleCardHoverEases),
            ("a field's focus glow eases", test_focusGlowEases),
            ("a theme repaint stays instant", test_themeRepaintIsInstant),
        ]

        var failures: [String] = []
        for (name, body) in cases {
            let found = body()
            if found.isEmpty {
                SelfTestAssertions.reportPass(name)
            } else {
                for message in found { SelfTestAssertions.reportFailure("\(name): \(message)") }
                failures.append(contentsOf: found)
            }
        }
        if failures.isEmpty {
            print("HoverPressEasingSelfTest: all \(cases.count) cases passed")
            return true
        }
        print("HoverPressEasingSelfTest: \(failures.count) check(s) FAILED")
        return false
    }

    // MARK: - HoverHighlightView

    private static func test_hoverFillEases() -> [String] {
        var failures: [String] = []
        for reduced in [false, true] {
            HelmMotion.reducedOverrideForTests = reduced
            let view = HoverHighlightView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
            view.normalColor = .clear
            view.hoverColor = .systemRed
            let window = makeWindow(view, size: NSSize(width: 160, height: 40))
            defer { window.orderOut(nil) }
            guard let layer = view.layer else { return ["no backing layer"] }
            layer.removeAllAnimations()
            let label = reduced ? "Reduce Motion" : "motion on"

            view.mouseEntered(with: hoverEvent(window))
            expect(sameColor(layer.backgroundColor, NSColor.systemRed.cgColor),
                   "\(label): hovering did not reach the hover fill", &failures)
            expectKeys(layer, contain: "backgroundColor", reduced: reduced,
                       "\(label): hover in", &failures)

            layer.removeAllAnimations()
            view.mouseExited(with: hoverEvent(window))
            expect(sameColor(layer.backgroundColor, NSColor.clear.cgColor),
                   "\(label): leaving did not return to the resting fill", &failures)
            expectKeys(layer, contain: "backgroundColor", reduced: reduced,
                       "\(label): hover out", &failures)
        }
        HelmMotion.reducedOverrideForTests = nil
        return failures
    }

    private static func test_hoverViewPressEases() -> [String] {
        var failures: [String] = []
        for reduced in [false, true] {
            HelmMotion.reducedOverrideForTests = reduced
            let view = HoverHighlightView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            view.pressScale = 0.9
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
            host.addSubview(view)
            view.frame = NSRect(x: 50, y: 30, width: 200, height: 60)
            let window = makeWindow(host, size: NSSize(width: 300, height: 120))
            defer { window.orderOut(nil) }
            guard let layer = view.layer else { return ["no backing layer"] }
            layer.removeAllAnimations()
            let label = reduced ? "Reduce Motion" : "motion on"
            let resting = layer.frame

            view.debugSetPressed(true)
            expect(layer.transform.m11 < 1, "\(label): pressing did not compress the view", &failures)
            expectKeys(layer, contain: "transform", reduced: reduced, "\(label): press", &failures)
            expectCentred(layer.frame, on: resting, "\(label): the pressed view", &failures)

            layer.removeAllAnimations()
            view.debugSetPressed(false)
            expect(CATransform3DIsIdentity(layer.transform),
                   "\(label): releasing left a transform behind", &failures)
            expectKeys(layer, contain: "transform", reduced: reduced, "\(label): release", &failures)
        }
        HelmMotion.reducedOverrideForTests = nil
        return failures
    }

    // MARK: - HelmButton

    private static func test_buttonHoverEases() -> [String] {
        var failures: [String] = []
        // Dusk's `.secondary` is a flat fill (no gradient sublayer), so the
        // fill under test is the button's own view-backed layer.
        ThemeManager.shared.setTheme(HelmTheme.dusk)
        for reduced in [false, true] {
            HelmMotion.reducedOverrideForTests = reduced
            let button = HelmButton(title: "Save", variant: .secondary)
            let window = makeWindow(button, size: NSSize(width: 160, height: 40))
            defer { window.orderOut(nil) }
            guard let layer = button.layer else { return ["no backing layer"] }
            let label = reduced ? "Reduce Motion" : "motion on"
            let restingFill = layer.backgroundColor
            layer.removeAllAnimations()

            button.mouseEntered(with: hoverEvent(window))
            // The fixture's own discriminating power: a hover that changes
            // nothing would make "no animation" the right answer.
            expect(!sameColor(layer.backgroundColor, restingFill),
                   "\(label): the fixture's hover fill equals its resting fill - nothing to ease", &failures)
            expectKeys(layer, contain: "backgroundColor", reduced: reduced, "\(label): hover in", &failures)

            layer.removeAllAnimations()
            button.mouseExited(with: hoverEvent(window))
            expect(sameColor(layer.backgroundColor, restingFill),
                   "\(label): leaving did not return to the resting fill", &failures)
            expectKeys(layer, contain: "backgroundColor", reduced: reduced, "\(label): hover out", &failures)
        }
        HelmMotion.reducedOverrideForTests = nil
        return failures
    }

    private static func test_buttonPressEases() -> [String] {
        var failures: [String] = []
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = nil }
        let button = HelmButton(title: "Deploy", variant: .secondary)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        host.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 60, y: 30, width: 180, height: 40)
        let window = makeWindow(host, size: NSSize(width: 300, height: 100))
        defer { window.orderOut(nil) }
        guard let layer = button.layer else { return ["no backing layer"] }
        let resting = layer.frame
        layer.removeAllAnimations()

        // `highlight(_:)` is where AppKit's own tracking loop and
        // `performClick` both deliver a press, so it is the real entry point.
        button.highlight(true)
        expect(layer.transform.m11 < 1, "pressing did not compress the button", &failures)
        expectKeys(layer, contain: "transform", reduced: false, "press", &failures)
        expectCentred(layer.frame, on: resting, "the pressed button", &failures)

        layer.removeAllAnimations()
        button.highlight(false)
        expect(CATransform3DIsIdentity(layer.transform), "releasing left the button transformed", &failures)
        expectKeys(layer, contain: "transform", reduced: false, "release", &failures)

        // Reduce Motion: a press compression is decoration, so it is skipped
        // outright (`HelmButton`'s existing rule) and nothing animates.
        HelmMotion.reducedOverrideForTests = true
        layer.removeAllAnimations()
        button.highlight(true)
        expect(CATransform3DIsIdentity(layer.transform),
               "Reduce Motion still compressed the button", &failures)
        expectKeys(layer, contain: "transform", reduced: true, "Reduce Motion press", &failures)
        button.highlight(false)
        return failures
    }

    // MARK: - HelmModuleCard

    private static func test_moduleCardHoverEases() -> [String] {
        var failures: [String] = []
        // The hover shadow is a Daylight-family recipe; the twelve legacy
        // palettes keep a flat card, so the shadow half needs this theme.
        ThemeManager.shared.setTheme(HelmTheme.daylight)
        for reduced in [false, true] {
            HelmMotion.reducedOverrideForTests = reduced
            let card = HelmModuleCard()
            card.configure(HelmModuleCard.Content(
                title: "Fleet", subtitle: "1 crew working", symbol: "sailboat.fill",
                hue: .teal, chip: nil, body: .metric(value: "1", unit: nil, note: "working")))
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
            host.addSubview(card)
            card.frame = NSRect(x: 20, y: 20, width: 260, height: HelmModuleCard.standardHeight)
            let window = makeWindow(host, size: NSSize(width: 320, height: 260))
            defer { window.orderOut(nil) }
            guard let outer = card.layer, let inner = card.debugCardView.layer else {
                return ["no backing layer"]
            }
            let label = reduced ? "Reduce Motion" : "motion on"
            let restingShadow = outer.shadowRadius
            outer.removeAllAnimations()
            inner.removeAllAnimations()

            card.mouseEntered(with: hoverEvent(window))
            expect(outer.shadowRadius != restingShadow,
                   "\(label): the fixture's raised shadow equals its resting one - nothing to ease", &failures)
            expectKeys(outer, contain: "shadowRadius", reduced: reduced, "\(label): hover shadow", &failures)
            if reduced {
                // §6.1: the lift is skipped under Reduce Motion, the shadow swap is not.
                expect(CATransform3DIsIdentity(inner.transform),
                       "Reduce Motion still lifted the card", &failures)
            } else {
                expect(inner.transform.m42 > 0, "hovering did not lift the card", &failures)
            }
            expectKeys(inner, contain: "transform", reduced: reduced, "\(label): hover lift", &failures,
                       requiredWhenMoving: !reduced)
        }
        HelmMotion.reducedOverrideForTests = nil
        return failures
    }

    // The bar's own icon squares and their press ease were retired with the
    // floating bar (UX-12): the window toolbar's buttons are AppKit's own
    // toolbar buttons, whose press the system draws.

    // MARK: - Theme repaint

    /// "Keep theme repaints instant": a theme change is a whole-window
    /// repaint that `ThemeTransitionCoordinator` cross-fades as a snapshot,
    /// and a per-control fade underneath it would show as labels snapping
    /// while their surfaces still travel (that file's header).
    private static func test_themeRepaintIsInstant() -> [String] {
        var failures: [String] = []
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = nil }
        ThemeManager.shared.setTheme(HelmTheme.dusk)
        let button = HelmButton(title: "Save", variant: .secondary)
        let view = HoverHighlightView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        host.addSubview(button)
        host.addSubview(view)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 200, y: 20, width: 160, height: 40)
        let window = makeWindow(host, size: NSSize(width: 400, height: 80))
        defer { window.orderOut(nil) }
        guard let buttonLayer = button.layer, let viewLayer = view.layer else { return ["no backing layer"] }
        let before = buttonLayer.backgroundColor
        buttonLayer.removeAllAnimations()
        viewLayer.removeAllAnimations()

        ThemeManager.shared.setTheme(HelmTheme.daylight)
        view.normalColor = .systemBlue
        expect(!sameColor(buttonLayer.backgroundColor, before),
               "the button's fill did not change with the theme - the fixture proves nothing", &failures)
        expect((buttonLayer.animationKeys() ?? []).isEmpty,
               "a theme change animated the button (\(buttonLayer.animationKeys() ?? []))", &failures)
        expect((viewLayer.animationKeys() ?? []).isEmpty,
               "a repaint of a resting fill animated (\(viewLayer.animationKeys() ?? []))", &failures)
        return failures
    }

    // MARK: - The field focus glow

    /// F1's "the glow currently pops in" - `animateLayers`' first caller, and
    /// broken the same way as the hover fills until this suite measured it.
    private static func test_focusGlowEases() -> [String] {
        var failures: [String] = []
        ThemeManager.shared.setTheme(HelmTheme.daylight)
        for reduced in [false, true] {
            HelmMotion.reducedOverrideForTests = reduced
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
            host.wantsLayer = true
            let chrome = NSView(frame: NSRect(x: 20, y: 15, width: 200, height: 30))
            chrome.wantsLayer = true
            host.addSubview(chrome)
            let window = makeWindow(host, size: NSSize(width: 260, height: 60))
            defer { window.orderOut(nil) }
            let theme = ThemeManager.shared.theme
            HelmInputSurface.apply(chrome: chrome, shadowHost: host, theme: theme, focused: false)
            guard let chromeLayer = chrome.layer, let hostLayer = host.layer else { return ["no backing layer"] }
            let restingWidth = chromeLayer.borderWidth
            chromeLayer.removeAllAnimations()
            hostLayer.removeAllAnimations()
            let label = reduced ? "Reduce Motion" : "motion on"

            HelmInputSurface.apply(chrome: chrome, shadowHost: host, theme: theme, focused: true, animated: true)
            expect(chromeLayer.borderWidth != restingWidth,
                   "\(label): focusing did not change the border - nothing to ease", &failures)
            expectKeys(chromeLayer, contain: "borderWidth", reduced: reduced, "\(label): focus border", &failures)
            expectKeys(hostLayer, contain: "shadowOpacity", reduced: reduced, "\(label): focus glow", &failures)
        }
        HelmMotion.reducedOverrideForTests = nil
        return failures
    }

    // MARK: - Helpers

    private static func expect(_ condition: Bool, _ message: String, _ failures: inout [String]) {
        SelfTestAssertions.record(condition, message, into: &failures)
    }

    /// With motion on, `key` must be animating; under Reduce Motion nothing
    /// may be. `requiredWhenMoving: false` relaxes only the first half, for a
    /// property the case expects to stay still in that state.
    private static func expectKeys(_ layer: CALayer, contain key: String, reduced: Bool,
                                   _ what: String, _ failures: inout [String],
                                   requiredWhenMoving: Bool = true) {
        let keys = layer.animationKeys() ?? []
        if reduced {
            expect(keys.isEmpty, "\(what) animated under Reduce Motion (\(keys))", &failures)
        } else if requiredWhenMoving {
            expect(keys.contains(key), "\(what) did not ease - \(key) is not animating (keys \(keys))", &failures)
        }
    }

    /// The pressed frame's centre must sit on the resting one: a compression
    /// about the anchor (the bottom-left corner) moves it.
    private static func expectCentred(_ pressed: NSRect, on resting: NSRect,
                                      _ what: String, _ failures: inout [String]) {
        let dx = abs(pressed.midX - resting.midX), dy = abs(pressed.midY - resting.midY)
        expect(pressed.width < resting.width, "\(what) did not get smaller (\(pressed) vs \(resting))", &failures)
        expect(dx < 0.01 && dy < 0.01,
               "\(what) compressed off-centre: its centre moved by (\(dx), \(dy))", &failures)
    }

    private static func makeWindow(_ content: NSView, size: NSSize) -> NSWindow {
        let window = OffScreenProbe.window(size: size, styleMask: [.titled, .resizable])
        window.contentView = content
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        return window
    }

    private static func hoverEvent(_ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 5, y: 5),
                           modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    /// Component-wise, never a luminance ratio (two hues of similar brightness
    /// pass a ratio check).
    private static func sameColor(_ a: CGColor?, _ b: CGColor?) -> Bool {
        guard let a, let b,
              let ca = a.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              let cb = b.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              ca.count >= 3, cb.count >= 3
        else { return a == nil && b == nil }
        return abs(ca[0] - cb[0]) < 0.01 && abs(ca[1] - cb[1]) < 0.01
            && abs(ca[2] - cb[2]) < 0.01 && abs(a.alpha - b.alpha) < 0.01
    }
}

#endif
