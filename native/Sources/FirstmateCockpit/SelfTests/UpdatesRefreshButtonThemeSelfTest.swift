// Manjesh Grand Line - native macOS app.
//
// Regression coverage for a real, captain-reported theming bug on Setup >
// Updates: the "Refresh" pill (`UpdatesController.checkAllPill`) rendered
// washed-out/near-invisible in light mode on a fresh load, then rendered
// correctly (a solid theme-accent fill) after the captain switched to dark
// mode and back to light.
//
// **Root cause, and why it is NOT PR #278/#279's mechanism.** #278/#279's
// bug shape is a *stored cache value* (`lastLayoutWasTwoColumn`-style) that
// `ThemeManager.shared.observe`'s premature synchronous fire poisons before
// real content exists, and an early-return guard then blocks the later,
// correct repaint from ever running. `UpdatesController.applyTheme()` has no
// such guard - it unconditionally repaints every view it touches, every
// time it runs - and `loadView()` already follows this codebase's own rule
// for exactly this class of bug (populate everything the observer's closure
// touches before registering it, or end `loadView` with an explicit
// `applyTheme()` call after everything is built - it does both). Confirmed
// directly below: `checkAllPill.layer.backgroundColor` reads back correct
// immediately after a fresh `loadView()`, with no round trip, in every
// theme tried - ruling the #278/#279 poisoned-cache mechanism out entirely
// for this bug. The *value* was never wrong.
//
// **The real defect is one level down, inside how the color is applied,
// not what it's applied to.** `checkAllPill` is a `HoverHighlightView`
// (`HelmUIComponents.swift`), a component that owns its *own* persistent
// `normalColor`/`hoverColor` state specifically so a mouse hover cycle can
// restore the right fill on exit (`mouseExited` calls `setBackground
// (normalColor, animated: true)`). `applyTheme()` never set either
// property - it wrote `checkAllPill.layer?.backgroundColor = accent.cgColor`
// straight to the underlying `CALayer`, bypassing that tracked state
// entirely. Since `normalColor`/`hoverColor` both defaulted to their
// construction-time `.clear`, the very first time the cursor entered and
// then left the pill - near-certain, since it's a clickable control the
// captain would naturally move toward - `mouseExited` overwrote the
// correctly-painted accent fill with the untouched `.clear` default, and
// nothing ever repainted it again until the next theme change re-ran
// `applyTheme()` and wrote the accent color straight back onto the layer
// (bypassing `normalColor` once more, so the *next* hover cycle strands it
// again the same way).
//
// This explains the light-mode-specific symptom precisely: with the fill
// stranded at `.clear`, the pill's icon/label (`selectionTextHex`, a
// near-white tone chosen for contrast against an *opaque accent fill*) sit
// directly on the page's background instead. On a light page that reads as
// "washed out/barely-visible" - on a dark page the same near-white text
// still reads fine against the dark background even with no purple fill
// under it, so the identical defect is far less noticeable there. It also
// explains why a theme round trip "fixes" it: `setTheme` re-fires every
// observer, `applyTheme()` runs again and writes the accent straight onto
// the layer, restoring the correct look - until the next accidental hover.
//
// Confirmed empirically, live, before writing the fix: constructing a fresh
// `UpdatesController()` and reading `checkAllPill.layer.backgroundColor`
// immediately after `loadView()` already matches the theme's accent (no
// bug at the value level, in any theme); driving a real `mouseEntered`/
// `mouseExited` pair through the pill afterward left the layer's color at
// `.clear` (matched `NSColor.clear`'s components exactly) rather than
// restoring the accent it started at.
//
// Fix: `applyTheme()` now sets `checkAllPill.normalColor`/`.hoverColor`
// instead of writing the layer directly - the same pattern every other
// filled `HoverHighlightView` pill in this app already uses (e.g.
// `HelmFormSheet`'s `closeSquare`, `DaylightBarController`'s pills/rows).
// `normalColor`'s own `didSet` paints the layer immediately (unanimated,
// since `isHovering` starts `false`), so the fresh-load appearance is
// unchanged - only a hover cycle's *restore* path now lands on the real
// accent instead of the untouched default.
//
// This bug is a genuinely different mechanism from #278/#279's (a
// component's own tracked reset-on-interaction state getting bypassed by a
// caller writing around it, rather than a stale cache guard on a rebuild
// function) - see this task's PR description for whether a follow-up audit
// of other `HoverHighlightView` callers is warranted.
//
// Run with:
//   swift build && FM_RUN_UPDATES_REFRESH_BUTTON_THEME_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum UpdatesRefreshButtonThemeSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkPillColorCorrectOnFreshLightLoad,
                      checkPillColorCorrectAfterThemeRoundTrip,
                      checkHoverCycleRestoresTheFillInsteadOfClearingIt] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "UpdatesRefreshButtonThemeSelfTest: all checks passed"
                    : "UpdatesRefreshButtonThemeSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// Catppuccin Latte - a real light theme whose accent (`8839ef`) is
    /// genuinely purple, matching the captain's own "solid purple primary
    /// button" description; its dark pair (Mocha) is what a captain toggling
    /// dark-then-light actually round-trips through (`ThemeManager.toggle()`
    /// swaps within a theme's own family via `pairId`, not to an unrelated
    /// palette).
    private static var lightTheme: HelmTheme {
        HelmTheme.theme(id: "catppuccin-latte") ?? HelmTheme.allThemes.first { $0.mode == .light }!
    }

    private static var darkTheme: HelmTheme {
        HelmTheme.theme(id: "catppuccin-mocha") ?? HelmTheme.allThemes.first { $0.mode == .dark }!
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 900) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// Component-wise, deliberately not a luminance-ratio comparison (see
    /// `DaylightDrillPageSlice6SelfTest.sameColor`'s own note on why a ratio
    /// check can pass for two different-but-similarly-bright hues - here it
    /// additionally has to distinguish a real fill from `.clear`, which a
    /// luminance check could not do reliably either).
    private static func sameColor(_ a: CGColor?, _ b: NSColor) -> Bool {
        guard let a, let comps = a.components, comps.count >= 3 else { return false }
        let bc = b.usingColorSpace(.sRGB) ?? b
        return abs(comps[0] - bc.redComponent) < 0.01
            && abs(comps[1] - bc.greenComponent) < 0.01
            && abs(comps[2] - bc.blueComponent) < 0.01
            && (a.alpha) > 0.5
    }

    private static func isClear(_ a: CGColor?) -> Bool {
        guard let a else { return true }
        return a.alpha < 0.01
    }

    /// A dummy enter/exit event: `HoverHighlightView.mouseEntered`/
    /// `.mouseExited` never read anything off the event itself (see their
    /// bodies in `HelmUIComponents.swift`), so any real `NSEvent` of the
    /// right type is sufficient to drive the real handler code.
    private static func dummyEnterExitEvent(in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        )!
    }

    // MARK: Cases

    /// The value `checkAllPill.layer.backgroundColor` reports right after a
    /// fresh `loadView()` pass, with no theme round trip and no hover. If
    /// this were the #278/#279 cache-guard shape, this is where it would
    /// show up as the *wrong* color (the underlying value would never reach
    /// the accent in the first place). It doesn't - `applyTheme()` has no
    /// early-return guard, so the property is already correct here.
    private static func checkPillColorCorrectOnFreshLightLoad(_ ok: inout Bool) {
        print("\n-- Updates Refresh pill: fresh light-mode load, no interaction --")
        let theme = lightTheme
        ThemeManager.shared.setTheme(theme)
        let controller = UpdatesController()
        let window = mount(controller)
        defer { _ = window }

        let accent = HelmTheme.nsColor(theme.accentHex)
        guard sameColor(controller.checkAllPillForTests.layer?.backgroundColor, accent) else {
            print("  FAIL checkAllPill.layer.backgroundColor does not match \(theme.id)'s accent " +
                  "immediately after loadView() - got " +
                  "\(String(describing: controller.checkAllPillForTests.layer?.backgroundColor))")
            ok = false
            return
        }
        print("  ok   checkAllPill's fill is \(theme.id)'s accent right after loadView(), with no theme round trip")
    }

    /// The same read, but after a dark -> light round trip on an
    /// already-mounted controller. Confirms the round trip does not change
    /// the underlying *value* - if it did, the bug would be a stale value
    /// (#278/#279's shape), not a component-state bypass.
    private static func checkPillColorCorrectAfterThemeRoundTrip(_ ok: inout Bool) {
        print("\n-- Updates Refresh pill: light -> dark -> light round trip --")
        let light = lightTheme
        let dark = darkTheme
        ThemeManager.shared.setTheme(light)
        let controller = UpdatesController()
        let window = mount(controller)
        defer { _ = window }

        ThemeManager.shared.setTheme(dark)
        ThemeManager.shared.setTheme(light)

        let accent = HelmTheme.nsColor(light.accentHex)
        guard sameColor(controller.checkAllPillForTests.layer?.backgroundColor, accent) else {
            print("  FAIL checkAllPill.layer.backgroundColor is wrong after a theme round trip - got " +
                  "\(String(describing: controller.checkAllPillForTests.layer?.backgroundColor))")
            ok = false
            return
        }
        print("  ok   checkAllPill's fill is still \(light.id)'s accent after a dark -> light round trip")
    }

    /// **The actual regression guard.** Drives a real mouse enter/exit
    /// cycle through the pill's own `HoverHighlightView.mouseEntered`/
    /// `.mouseExited` - exactly what a captain moving the cursor toward this
    /// clickable control triggers - and asserts the fill afterward is the
    /// theme's accent again, not `.clear`.
    ///
    /// Confirmed to catch the real regression: with `applyTheme()` reverted
    /// to writing `checkAllPill.layer?.backgroundColor = accent.cgColor`
    /// directly (never touching `normalColor`/`hoverColor`), this case
    /// fails by name - the fill reads back as `.clear` after `mouseExited`,
    /// reproducing the captain's exact "washed out" symptom.
    private static func checkHoverCycleRestoresTheFillInsteadOfClearingIt(_ ok: inout Bool) {
        print("\n-- regression: a hover cycle must restore the accent fill, not clear it --")
        let theme = lightTheme
        ThemeManager.shared.setTheme(theme)
        let controller = UpdatesController()
        let window = mount(controller)
        defer { _ = window }

        let pill = controller.checkAllPillForTests
        let accent = HelmTheme.nsColor(theme.accentHex)
        guard sameColor(pill.layer?.backgroundColor, accent) else {
            print("  FAIL pill did not start with the correct accent fill - test setup is wrong")
            ok = false
            return
        }

        let event = dummyEnterExitEvent(in: window)
        pill.mouseEntered(with: event)
        pill.mouseExited(with: event)

        if isClear(pill.layer?.backgroundColor) {
            print("  FAIL a hover enter/exit cycle stranded checkAllPill's fill at .clear - this is " +
                  "the exact \"washed out\" bug: the icon/label now sit on the bare page background " +
                  "instead of the theme's accent")
            ok = false
            return
        }
        guard sameColor(pill.layer?.backgroundColor, accent) else {
            print("  FAIL after a hover cycle, checkAllPill's fill is neither the accent nor clear - got " +
                  "\(String(describing: pill.layer?.backgroundColor))")
            ok = false
            return
        }
        print("  ok   checkAllPill's fill is restored to \(theme.id)'s accent after a hover enter/exit cycle")
    }
}

#endif
