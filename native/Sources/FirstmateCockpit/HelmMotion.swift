// Manjesh Grand Line - native macOS app.
//
// The app's one Reduce Motion gate - Phase 6 of the Daylight UI migration
// (`data/grandline-ui-modernization-review/daylight-ui-design.md`, §8's
// "Reduce Motion audit of the hover translate and any ribbon animation").
//
// **What the audit actually found, so the next reader does not have to redo
// it.** Phases 1-5 introduced three classes of motion, and only one of them
// was a bug:
//
// 1. **Explicit, deliberate animation** - `HoverHighlightView`'s hover fill,
//    `HelmModuleCard`'s 3pt hover lift, `HelmToggle`'s knob slide, `Toast`'s
//    fade. Each already read `NSWorkspace.accessibilityDisplayShouldReduceMotion`
//    at its own call site, except `Toast`, which this phase gated. They are
//    now all routed through `HelmMotion.isReduced` so there is one definition
//    of the question rather than six copies of it - which is what
//    `DaylightMotionSelfTest`'s source guard enforces.
//
// 2. **Implicit animation on the seven Daylight gradient layers** - the real
//    finding, and invisible in a diff. A `CAGradientLayer` added as a *sublayer*
//    (which every ribbon, tile and gradient fill in this design is) is not
//    view-backed, so Core Animation gives it the default ~0.25s implicit
//    animation for any property change. `colors` is reassigned on every theme
//    change and on every `configure(...)`, so a re-used module card cross-faded
//    from the previous row's hue to the new one, and a theme switch cross-faded
//    every ribbon in the window - motion nobody designed, nobody asked for, and
//    nothing gated. `HelmMotion.withoutImplicitAnimation` is the fix and is
//    applied at all seven sites.
//
// 3. **Out of scope, deliberately** - `LockScreenController`'s scene and
//    `DictationHUD`'s pulse. Both are on the migration's own "must NOT change"
//    list and both already gate their looping animations; they read the gate
//    through this type now purely so the app has one definition, with no
//    behavioural change. `ConsoleController`'s SRE Lead pane slide is
//    pre-Daylight and is not a hover translate or a gradient animation, so this
//    phase left its timing alone rather than quietly re-tuning a surface whose
//    own history warns against touching its geometry.
//
// The rule this file encodes: **Reduce Motion means the end state, instantly -
// never the same motion, slower.** A halved duration is still motion.

import AppKit

enum HelmMotion {
    /// Does the captain have "Reduce motion" on?
    ///
    /// The one place this question is asked. Read fresh every time rather than
    /// cached: the setting is a live System Settings toggle, and the two
    /// surfaces that need to *react* to it changing (a module card's hover
    /// state, the dictation HUD's pulse) already observe
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and
    /// re-ask.
    static var isReduced: Bool {
        #if FM_SELFTESTS
        if let forced = reducedOverrideForTests { return forced }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    #if FM_SELFTESTS
    /// Forces the answer, so a self-test can drive the *real* hover, ribbon
    /// and toast code paths in both states.
    ///
    /// There is no API to set the system setting, and asserting only "the
    /// call site mentions the gate" is the weaker check - it passes for a gate
    /// that is read and then ignored. Every user of it restores `nil`.
    static var reducedOverrideForTests: Bool?
    #endif

    /// Runs `body` with Core Animation's implicit animations suppressed when
    /// Reduce Motion is on, and unchanged otherwise.
    ///
    /// For a standalone (non-view-backed) `CALayer` - every Daylight gradient
    /// ribbon, tile and fill - assigning `colors`, `frame` or `cornerRadius`
    /// animates by default. Wrapping the assignment is the only way to make
    /// that instant; there is no per-layer "don't animate" flag.
    ///
    /// Deliberately gated rather than always-off: with Reduce Motion off, the
    /// existing cross-fade is what every render and every screenshot of this
    /// app has shown since Phase 1, and this phase is hardening, not a
    /// retune.
    static func withoutImplicitAnimation(_ body: () -> Void) {
        guard isReduced else {
            body()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// `NSAnimationContext.runAnimationGroup` that collapses to an immediate
    /// state change under Reduce Motion.
    ///
    /// The `animated` parameter is the caller's own "should this be animated
    /// at all" (a first paint, a programmatic selection) and is ANDed with the
    /// accessibility setting, so a call site never has to remember both.
    static func animate(_ animated: Bool = true,
                        duration: TimeInterval,
                        _ body: () -> Void) {
        guard animated, !isReduced else {
            body()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            body()
        }
    }
}
