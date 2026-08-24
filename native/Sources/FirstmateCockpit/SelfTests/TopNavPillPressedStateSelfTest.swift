// Manjesh Grand Line - native macOS app.
//
// Regression coverage for a real, captain-reported bug on the top nav's space
// pills (`DaylightBarController`, Overview/Command/Operations/Stores/
// Engineering): clicking a pill and leaving the cursor in place (not moving
// away) rendered that pill's label nearly invisible, blended into its own
// background - moving the mouse away restored it. Confirmed by the captain
// on both light and dark mode, across pills, not just the one screenshot
// ("Operations" in dark mode) that first surfaced it.
//
// **The missing state is neither hover, nor resting, nor "selected" in the
// sense the design already covers - it is "just became selected while the
// cursor is still resting on it", which only the click path can produce.**
// `DaylightBarController.applyTheme()` already computes the right colors for
// every pill on every call: a newly-selected pill's `HoverHighlightView.
// normalColor` *and* `.hoverColor` are both set to `selectedFill` (the same
// fill, so hovering or not makes no visual difference once settled), and its
// label's `textColor` is set to `selectedInk`, a color chosen specifically to
// read against `selectedFill`. That part was never wrong - reading it back
// right after a click already shows the correct intended values on every
// property.
//
// **The bug is in what actually gets painted, not in what gets computed.**
// `HoverHighlightView.normalColor`'s own `didSet` already knew to repaint
// immediately whenever it changes while the view is *not* currently hovering
// (`if !isHovering { setBackground(normalColor, ...) }`) - a caller re-theming
// a row that the mouse happens not to be over needs to see the change land at
// once, without waiting for a hover event that may never come. `hoverColor`
// had no such `didSet` at all. So the one moment this bug can occur is the
// mirror image of what `normalColor` already handles: reassigning colors
// *while the view is currently hovering* only ever updated `hoverColor`'s
// stored value, never repainted anything - the layer kept showing whichever
// color a *previous* `mouseEntered` had painted it with, which for a pill
// that just became selected is the stale, pre-selection `hoverFill` (a faint
// muted wash), not the newly-intended `selectedFill` (an opaque ink color).
// The label's `textColor`, meanwhile, ran through the normal, unconditional
// property-set path with no hover gate at all, so it updated immediately to
// `selectedInk` - a color computed for legibility against `selectedFill`, not
// against whatever stale background was still actually painted. Two colors
// that were each individually correct for the *intended* end state ended up
// on screen together with the *wrong* one of the pair still painted.
//
// This is why it only ever showed up transiently: `mouseExited` (moving the
// mouse away) repaints unconditionally from whatever `normalColor`/
// `hoverColor` hold *now* - which by then are both the correct, settled
// `selectedFill` - so the very next hover-exit "fixes" it, and it never
// reproduces on a pill that was already selected before the cursor arrived
// (no state changed while hovering, so nothing was ever stale to begin
// with). It is also why the captain saw it in both light and dark mode: the
// mechanism never inspects any color's actual value, only whether a color
// changed while `isHovering` was `true` - it is exactly as reproducible on a
// palette where `hoverFill` and `selectedFill` happen to be closer in
// contrast as on one where they are further apart.
//
// Fix: `HoverHighlightView.hoverColor` (`HelmUIComponents.swift`) gained the
// symmetric `didSet` - `if isHovering { setBackground(hoverColor, ...) }` -
// so a color reassignment made mid-hover repaints immediately from the new
// value, the same guarantee `normalColor` already gave the non-hovering case.
// This is a shared-component fix, not a `DaylightBarController`-specific
// patch: the same latent defect could in principle affect any other
// `HoverHighlightView` caller that reassigns `hoverColor` in response to a
// state change while the cursor may already be resting on the view (a click,
// a keyboard activation, an external selection change) - this task did not
// attempt a codebase-wide audit of every such caller, only fixed the shared
// mechanism and confirmed it closes the one reported symptom.
//
// Run with:
//   swift build && FM_RUN_TOPNAV_PILL_PRESSED_STATE_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TopNavPillPressedStateSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkPressedStateContrastAcrossEveryThemeAndPill,
                      checkArrowKeyActivationAlsoRepaintsWhileHovering,
                      checkMouseExitStillRestoresTheSameFill] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "TopNavPillPressedStateSelfTest: all checks passed"
                    : "TopNavPillPressedStateSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func mount(_ controller: NSViewController, width: CGFloat = 1100) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// `HoverHighlightView.mouseEntered`/`.mouseExited` never read anything
    /// off the event itself (see their bodies in `HelmUIComponents.swift`),
    /// so any real `NSEvent` of the right type is sufficient to drive the
    /// real handler code - the same fixture
    /// `UpdatesRefreshButtonThemeSelfTest` already established.
    private static func dummyEnterExitEvent(in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        )!
    }

    private static func labelTextColor(of pill: NSView) -> NSColor? {
        pill.subviews.compactMap { $0 as? NSTextField }.first?.textColor
    }

    /// The color actually on screen right now, read back off the real
    /// `CALayer` - never the `normalColor`/`hoverColor` properties directly,
    /// since the whole bug is that those can disagree with what is painted.
    private static func paintedBackground(of pill: NSView) -> NSColor? {
        guard let cg = pill.layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cg)
    }

    private static func ratio(_ text: NSColor?, _ background: NSColor?) -> Double? {
        guard let text, let background, background.alphaComponent > 0.5 else { return nil }
        return HelmContrast.ratio(text, background)
    }

    // MARK: Cases

    /// **The actual regression guard.** For every real `HelmTheme` (light and
    /// dark alike - the captain confirmed this is not mode-specific) and
    /// every real space pill: hover the pill, click it (the exact sequence a
    /// captain's mouse produces - `mouseEntered` then the click recognizer's
    /// own handler), and assert the *painted* background and the label's
    /// text color, read back together right after the click with no further
    /// event, clear the WCAG AA text floor.
    ///
    /// Confirmed to catch the real regression: with `HoverHighlightView.
    /// hoverColor` reverted to a plain stored property (no `didSet`), this
    /// fails by name on every theme - the painted background stays the stale
    /// pre-selection `hoverFill` while the label already reads the
    /// post-selection `selectedInk`, reproducing the captain's exact
    /// "text blended into a dark pill-shaped background" symptom.
    private static func checkPressedStateContrastAcrossEveryThemeAndPill(_ ok: inout Bool) {
        print("\n-- top nav pill: clicked-and-not-moved state, every theme x every pill --")
        var failures = 0
        var checked = 0
        for theme in HelmTheme.allThemes {
            ThemeManager.shared.setTheme(theme)
            let bar = DaylightBarController()
            let window = mount(bar)
            defer { _ = window }

            let event = dummyEnterExitEvent(in: window)
            let pills = bar.debugPills()
            guard !pills.isEmpty else {
                print("  FAIL \(theme.id): DaylightBarController built zero pills")
                failures += 1
                continue
            }

            for pill in pills {
                // The real sequence: the cursor arrives (mouseEntered fires,
                // painting the *pre-click* hover fill), then the click lands
                // (the state change that used to leave the paint stale).
                pill.mouseEntered(with: event)
                guard let recognizer = pill.gestureRecognizers
                        .compactMap({ $0 as? NSClickGestureRecognizer })
                        .first(where: { $0.isEnabled && $0.action != nil }),
                      let action = recognizer.action, let target = recognizer.target else {
                    print("  FAIL \(theme.id): a pill has no enabled click recognizer")
                    failures += 1
                    continue
                }
                _ = NSApp.sendAction(action, to: target, from: recognizer)

                checked += 1
                let text = labelTextColor(of: pill)
                let background = paintedBackground(of: pill)
                guard let r = ratio(text, background) else {
                    print("  FAIL \(theme.id)/\(pill.identifier?.rawValue ?? "?"): could not read back " +
                          "a painted (opaque) background right after the click")
                    failures += 1
                    continue
                }
                if r < HelmContrast.textTarget - 0.01 {
                    print("  FAIL \(theme.id)/\(pill.identifier?.rawValue ?? "?"): label vs. the painted " +
                          "background measures \(String(format: "%.2f", r)):1 immediately after a click " +
                          "while still hovering (need >= \(HelmContrast.textTarget):1)")
                    failures += 1
                }
            }
        }
        guard failures == 0 else {
            print("  FAIL \(failures) of \(checked) pill/theme combinations failed the pressed-state contrast floor")
            ok = false
            return
        }
        print("  ok   all \(checked) pill/theme combinations stay legible immediately after a click, mouse still resting")
    }

    /// Arrow-key navigation between pills (`handleArrowKey`) moves selection
    /// the same way a click does, and can also land on a pill the cursor
    /// happens to already be resting on (a captain tabbing to the bar, then
    /// using the keyboard while the mouse sits over a pill it moves to). Same
    /// mechanism, different trigger - covered separately so a fix scoped only
    /// to the click recognizer's own call site would still be caught here.
    private static func checkArrowKeyActivationAlsoRepaintsWhileHovering(_ ok: inout Bool) {
        print("\n-- top nav pill: arrow-key selection while the cursor is already resting on the target --")
        let theme = HelmTheme.allThemes.first { $0.mode == .light } ?? HelmTheme.allThemes[0]
        ThemeManager.shared.setTheme(theme)
        let bar = DaylightBarController()
        let window = mount(bar)
        defer { _ = window }

        let event = dummyEnterExitEvent(in: window)
        let pills = bar.debugPills()
        guard pills.count >= 2 else {
            print("  FAIL fewer than two pills to move between")
            ok = false
            return
        }

        // Hover pill 2 first - as if the cursor already sits over the pill an
        // arrow-key press is about to select.
        pills[1].mouseEntered(with: event)
        guard bar.handleArrowKeyForTests(keyCode: 124, from: bar.selectedSpaceForTests) else {
            print("  FAIL arrow-key handler did not report handling the event")
            ok = false
            return
        }

        let text = labelTextColor(of: pills[1])
        let background = paintedBackground(of: pills[1])
        guard let r = ratio(text, background) else {
            print("  FAIL could not read back a painted background after an arrow-key selection")
            ok = false
            return
        }
        if r < HelmContrast.textTarget - 0.01 {
            print("  FAIL label vs. painted background measures \(String(format: "%.2f", r)):1 after an " +
                  "arrow-key selection landed on an already-hovered pill")
            ok = false
            return
        }
        print("  ok   an arrow-key selection onto an already-hovered pill also repaints correctly")
    }

    /// Confirms the fix did not just move the bug - moving the mouse away
    /// after a click (`mouseExited`) must still repaint from the current,
    /// correct `normalColor`, exactly as before this task.
    private static func checkMouseExitStillRestoresTheSameFill(_ ok: inout Bool) {
        print("\n-- top nav pill: mouse-exit after a click still lands on the settled fill --")
        let theme = HelmTheme.allThemes.first { $0.mode == .dark } ?? HelmTheme.allThemes[0]
        ThemeManager.shared.setTheme(theme)
        let bar = DaylightBarController()
        let window = mount(bar)
        defer { _ = window }

        let event = dummyEnterExitEvent(in: window)
        let pills = bar.debugPills()
        guard let pill = pills.first,
              let recognizer = pill.gestureRecognizers
                  .compactMap({ $0 as? NSClickGestureRecognizer })
                  .first(where: { $0.isEnabled && $0.action != nil }),
              let action = recognizer.action, let target = recognizer.target else {
            print("  FAIL setup: no pill/recognizer to drive")
            ok = false
            return
        }
        pill.mouseEntered(with: event)
        _ = NSApp.sendAction(action, to: target, from: recognizer)
        let whileHovering = paintedBackground(of: pill)

        pill.mouseExited(with: event)
        let afterExit = paintedBackground(of: pill)

        guard let a = whileHovering, let b = afterExit else {
            print("  FAIL could not read back a background before/after mouse-exit")
            ok = false
            return
        }
        let ca = HelmContrast.components(a), cb = HelmContrast.components(b)
        let same = abs(ca.0 - cb.0) < 0.02 && abs(ca.1 - cb.1) < 0.02 && abs(ca.2 - cb.2) < 0.02
        guard same else {
            print("  FAIL background while hovering and after mouse-exit disagree - " +
                  "the selected fill should be identical hovering or not")
            ok = false
            return
        }
        print("  ok   mouse-exit after a click still lands on the same settled selected fill")
    }
}

#endif
