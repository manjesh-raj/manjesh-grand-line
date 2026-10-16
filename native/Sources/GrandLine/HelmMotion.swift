// Grand Line - native macOS app.
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
//
// # The motion table
//
// P8 of the Grand Line vs Automic Vault polish report counted nine different
// UI durations in use (0.09 to 0.25), two of them tokens. There are now three,
// and every UI transition takes one of them:
//
// | Token            | Value | Use it for |
// |------------------|-------|------------|
// | `stateDuration`  | 0.12s | A control changing state where it stands: hover, press, focus, a fill or border, a row's actions revealing, a hairline appearing. The eye should register that it *happened*, not watch it travel. |
// | `moveDuration`   | 0.18s | Something travelling or a surface changing over: a page change, a pane sliding, a thumb or knob moving, a panel or palette appearing or leaving. |
// | `springDuration` | 0.25s | An element arriving on the spring curve, or a first-appearance rise: a toast, the dictation HUD's pop, an empty state's entrance, a list's row entrance. |
//
// Curves: `fade`, `animate` and `animateLayers` all take the one ease-out;
// `spring()` is the one spring. Nothing else.
//
// **Which primitive.** A property of a *view* (`frame`, `alphaValue`, a
// constraint's `constant`) animates through the animator proxy, so `animate`
// or `fade`. A property of a view's *layer* (`backgroundColor`,
// `borderColor`, `transform`, `shadowOpacity`) does not animate through
// either - nor, measured on macOS 26.7, through `allowsImplicitAnimation` -
// so `animateLayers(on:)`, always, naming the layers it covers. P1 of that
// report found the app's hover and press feedback written with the first
// shape on layer properties, and every one of them landed in a single frame;
// `HoverPressEasingSelfTest` now reads `layer.animationKeys()` to keep it
// honest.
//
// **What stays instant.** A theme change (`ThemeTransitionCoordinator`
// cross-fades a snapshot of the whole window instead), a first paint, and a
// programmatic state restore. Pass `animated: false` for those.
//
// **The exceptions, and why they are not tokens.** Ambient loops (the
// skeleton shimmer, the lock screen's scene, the dictation pulse, the crew
// pulse, the bell's arrival bounce), the lock screen's shake, the theme
// crossfade (K3's own 200ms, asserted by `ThemeMotionWebIslandsSelfTest`) and
// a toast's dwell time are each a one-off with its own reason, so each keeps
// its own number. `MotionTableSelfTest` fails the run on any other literal
// duration, and its allowlist is where a new exception has to say why.

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

    /// Runs `body` with every implicit layer action suppressed, whatever
    /// Reduce Motion says.
    ///
    /// For setting an entrance's *start* state - the scale or offset a layer
    /// travels from - which must land instantly in both states, before
    /// `animateLayers` eases it to the end. `withoutImplicitAnimation` is the
    /// Reduce-Motion-gated sibling and is the wrong tool for that.
    static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// The app's one spring curve.
    ///
    /// The audit's motion spec is explicit that there are "two curves total -
    /// one spring, one ease-out - all through the existing Reduce Motion
    /// gate", and the captain-approved visual gives the spring's own control
    /// points. It overshoots slightly (the 1.4), which is what makes a
    /// sliding selection read as a physical thing arriving rather than as a
    /// rectangle being repositioned.
    static func spring() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.3, 1.4, 0.45, 1)
    }

    /// The spring's duration, from the same spec ("spring 250ms").
    static let springDuration: TimeInterval = 0.25

    /// Fades a view to `target`, animating only when it should.
    ///
    /// **Do not reach for `view.animator().alphaValue` outside an animation
    /// context.** Measured, not assumed: the animator proxy routes the write
    /// through AppKit's animation machinery whether or not a context is open,
    /// so a caller that sets it "unanimated" and then reads `alphaValue` back
    /// gets the *old* value - which is how D1's hover-reveal shipped its
    /// first draft looking entirely correct in code and doing nothing at all
    /// in a real list. The proxy is used only on the branch that genuinely
    /// animates; every other path assigns the property directly.
    static func fade(_ view: NSView, to target: CGFloat, duration: TimeInterval, animated: Bool) {
        guard view.alphaValue != target else { return }
        guard animated, !isReduced else {
            view.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // L's headline complaint is "No springs anywhere. **No timing
            // curves set (default ease).**" Earlier rounds answered the first
            // half and set a curve at each *new* call site, but the two
            // shared primitives - this and `animate` - still took AppKit's
            // default ease-in-ease-out, which is what most of the app's motion
            // actually runs through. This is the spec's one ease-out, so the
            // statement "two curves total" is now true of the primitives
            // rather than only of the call sites that remembered.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = target
        }
    }

    /// The ease-out curve's duration - the audit's motion spec states two
    /// curves and two durations ("spring 250ms", "120ms eased state changes"),
    /// and this is the second of them: a state change the eye should register
    /// as *having happened* rather than as a thing travelling.
    static let stateDuration: TimeInterval = 0.12

    /// The motion table's middle row: something travelling, or one surface
    /// changing over to another. The page change has used this number since
    /// `AppShellController.destinationTransitionDuration` was introduced; it
    /// is now the one definition every travelling thing reads.
    static let moveDuration: TimeInterval = 0.18

    /// A scale of `scale` about `layer`'s own centre, composed after `base`.
    ///
    /// A view-backed layer's `anchorPoint` is its bottom-left corner, so a bare
    /// `CATransform3DMakeScale` compresses a control *towards that corner* -
    /// a 2% press on a 200pt button moves its centre 2pt down and left.
    /// While the press snapped nobody could see it; once it eases, it reads
    /// as the control sliding. Read from the layer's real `anchorPoint` rather
    /// than assuming (0, 0), so a layer that was re-anchored still scales
    /// about its centre.
    static func centredScale(_ scale: CGFloat, of layer: CALayer,
                             after base: CATransform3D = CATransform3DIdentity) -> CATransform3D {
        guard scale != 1 else { return base }
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -dx, -dy, 0)
        return CATransform3DConcat(t, base)
    }

    /// Runs `body` and eases every **layer** property it changed on `layers` -
    /// `backgroundColor`, `borderColor`, `borderWidth`, the shadow, `transform`,
    /// `opacity`, a gradient's `colors`.
    ///
    /// **Why the layers are named, and why this does not lean on implicit
    /// animation.** This primitive used to open a context with
    /// `allowsImplicitAnimation = true` and trust AppKit's view-backed layer
    /// delegate to supply an action. Measured on macOS 26.7 (P1 of the Grand
    /// Line vs Automic Vault polish report): inside exactly that context the
    /// delegate answers **no action** for `backgroundColor`, `borderColor`,
    /// `borderWidth`, `shadowOpacity` and `transform` - it supplies one only
    /// for `opacity`, `cornerRadius`, `shadowRadius`, `shadowColor`, `bounds`
    /// and `position`. So every hover fill, every press, the module card's
    /// lift and the field focus glow (F1, this primitive's first caller) landed
    /// in a single frame, while the code read as eased. The report's own probe
    /// had predicted the flag would be enough; it was not.
    ///
    /// So this snapshots each named layer's animatable properties, runs `body`
    /// with actions disabled (one owner of every animation, no double ones),
    /// and adds an explicit ease-out `CABasicAnimation` for each property whose
    /// model value changed, keyed by the property name. That depends on no
    /// delegate, no window and no run-loop turn, which is also what lets
    /// `HoverPressEasingSelfTest` read `layer.animationKeys()` straight after
    /// the real entry point. A change that lands while an earlier one on the
    /// same key is still running starts from where the layer is *drawn*
    /// (its presentation value), so a quick press-and-release turns round
    /// smoothly instead of jumping.
    ///
    /// A layer the body touches but the caller did not name changes instantly.
    /// That is deliberate: naming is what makes the animation explicit.
    ///
    /// `timing` is the one ease-out unless the caller is an arrival on the
    /// spring (`spring()`), which is the motion table's third row.
    ///
    /// **An entrance sets its start state first, then calls this.** The
    /// change is detected against the model value at the moment of the call,
    /// so a caller that snaps a layer to its entry transform (with actions
    /// disabled) and then sets identity inside the body gets the travel
    /// between the two.
    static func animateLayers(_ animated: Bool = true,
                              duration: TimeInterval,
                              timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut),
                              on layers: [CALayer?],
                              _ body: () -> Void) {
        guard animated, !isReduced else {
            // Reduce Motion means the end state, instantly - and "instantly"
            // for a layer property means suppressing whatever implicit
            // animation a *standalone* sublayer in the same block would
            // otherwise take.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body()
            CATransaction.commit()
            return
        }
        let targets = layers.compactMap { $0 }
        let before = targets.map { layer in easedKeys(for: layer).map { layer.value(forKey: $0) } }
        let drawn = targets.map { layer in
            easedKeys(for: layer).map { key -> Any? in
                layer.animation(forKey: key) == nil ? nil : layer.presentation()?.value(forKey: key)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        for (i, layer) in targets.enumerated() {
            for (j, key) in easedKeys(for: layer).enumerated() {
                let after = layer.value(forKey: key)
                guard !sameLayerValue(before[i][j], after) else { continue }
                let ease = CABasicAnimation(keyPath: key)
                ease.fromValue = drawn[i][j] ?? before[i][j] ?? fallbackFromValue(for: key)
                ease.toValue = after
                ease.duration = duration
                ease.timingFunction = timing
                layer.add(ease, forKey: key)
            }
        }
    }

    /// The layer properties `animateLayers` eases. Not `bounds` or
    /// `position`: those are Auto Layout's, and a layout pass easing them
    /// would make every relayout drift into place.
    static let easedLayerKeys = ["backgroundColor", "borderColor", "borderWidth",
                                 "shadowColor", "shadowOpacity", "shadowRadius", "shadowOffset",
                                 "transform", "opacity"]

    private static func easedKeys(for layer: CALayer) -> [String] {
        layer is CAGradientLayer ? easedLayerKeys + ["colors"] : easedLayerKeys
    }

    /// `nil` (no fill yet) and a clear fill mean the same thing on screen,
    /// and a colour animation needs a real starting colour.
    private static func fallbackFromValue(for key: String) -> Any? {
        key.hasSuffix("Color") ? CGColor.clear : nil
    }

    private static func sameLayerValue(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        }
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
            // The same ease-out `fade` and `animateLayers` take - see the note
            // in `fade`. None of this method's callers sets its own timing
            // function, and all of them (a press scale, a hover lift, a
            // drawer slide) are ease-out shapes; a caller that genuinely
            // wants the spring sets `HelmMotion.spring()` inside the body,
            // which runs after this line and therefore wins.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            body()
        }
    }
}
