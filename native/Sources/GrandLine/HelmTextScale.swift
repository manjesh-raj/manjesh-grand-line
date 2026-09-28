// Grand Line - native macOS app.
//
// GL-32's font-recompute half (review bug B33).
//
// `ChromeTextScale`'s own header states the gap this file closes: "text whose
// font is set once in a page's own `loadView` and never re-derived ... keeps
// its size until the view is rebuilt or the app relaunches". Roughly 150 such
// labels were left across ~40 files, most of them below
// `HelmType.minimumUIPointSize` at their designed size, so the floor half of
// GL-32 did not reach them either.
//
// **Why one mechanism rather than 150 hand-written re-derivations.** The
// established pattern is a font expression that is re-evaluated from
// `applyTheme(_:)`, because a scale change arrives as an app-wide theme
// re-fire (`AppShellController`'s `ChromeTextScale.observe`). That works
// wherever the label's font assignment already sits on a path `applyTheme`
// re-runs. It does not work for a label built once in `loadView` and only
// ever re-*coloured* afterwards, which is what almost all of the remaining
// sites are - and giving each of those a bespoke re-derivation means ~150
// new assignments that nothing can check for completeness, in files whose
// `applyTheme` would have to learn about labels it does not otherwise touch.
//
// So the recipe travels with the label instead. `setScaledFont` records how
// the font was derived (designed point size, weight, face) on the view itself
// and assigns the scaled result; `HelmTextScale.reapply(in:)` walks a subtree
// and re-derives every recorded font from the *current* scale. The shell
// calls that once, from the same observer that fires the theme re-fire, so a
// page pays nothing and cannot forget.
//
// Two properties this buys that a per-site rewrite does not:
//
//   * it is complete by construction - a label that carries a recipe is
//     re-derived whether or not its page knows the label exists;
//   * it is checkable - `TextScaleFontSelfTest` greps this app's own sources
//     for a raw `.systemFont(ofSize: <literal>)` assignment, so a new one
//     fails the run by name rather than becoming the 151st site.
//
// What deliberately stays raw, and why, is the exemption list in that suite:
// `CredentialVaultRecoveryKitView` (a print/PDF view that draws fixed black
// on white and must not track any theme or scale setting - paper and file
// cannot drift), and the sites whose size already comes from
// `FontSizeManager` (the captain's *monospace* size, a different setting).

import AppKit
import ObjectiveC

/// The chrome-text-scale recipe carried by a view whose font was set through
/// `setScaledFont`, plus the subtree walk that re-derives them all.
enum HelmTextScale {

    /// Which system face a recipe rebuilds from. Mirrors the four
    /// constructors the app's raw sites actually used.
    enum Voice {
        case system
        case monospaced
        case monospacedDigit
        case rounded
    }

    /// A designed point size and face, before `HelmType.scaled` is applied.
    ///
    /// `base` is the size the layout around it was measured at - the literal
    /// that used to be written at the call site - not the size currently on
    /// screen. Storing the *base* is what makes a second scale change correct:
    /// re-deriving from the rendered size would compound the multiplier, and
    /// could not undo `HelmType.minimumUIPointSize`'s floor at all.
    struct Recipe {
        let base: CGFloat
        let weight: NSFont.Weight
        let voice: Voice

        /// The font this recipe resolves to at the captain's current scale.
        func font() -> NSFont {
            let size = HelmType.scaled(base)
            switch voice {
            case .system: return .systemFont(ofSize: size, weight: weight)
            case .monospaced: return .monospacedSystemFont(ofSize: size, weight: weight)
            case .monospacedDigit: return .monospacedDigitSystemFont(ofSize: size, weight: weight)
            case .rounded: return HelmType.rounded(size, weight)
            }
        }
    }

    /// Boxed so the recipe (a struct) can be an associated object.
    private final class RecipeBox {
        let recipe: Recipe
        init(_ recipe: Recipe) { self.recipe = recipe }
    }

    private static var recipeKey: UInt8 = 0

    /// Record `recipe` on `view` and assign the font it resolves to now.
    static func record(_ recipe: Recipe, on view: NSView) {
        objc_setAssociatedObject(view, &recipeKey, RecipeBox(recipe),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The recipe `view` is carrying, if it was given one.
    static func recipe(of view: NSView) -> Recipe? {
        (objc_getAssociatedObject(view, &recipeKey) as? RecipeBox)?.recipe
    }

    /// Re-derive every recorded font in `root`'s subtree from the current
    /// chrome text scale.
    ///
    /// Idempotent, and a no-op for any view that never recorded a recipe -
    /// which is what keeps it clear of the terminal views, the code preview
    /// and anything else whose size belongs to `FontSizeManager` instead.
    ///
    /// Called from `AppShellController`'s own `ChromeTextScale` observer,
    /// *after* the theme re-fire: a page whose `applyTheme` rebuilds its rows
    /// hands back fresh labels, which are then already correct, and this walk
    /// catches the ones that survived.
    static func reapply(in root: NSView) {
        if let recipe = recipe(of: root) {
            apply(recipe.font(), to: root)
        }
        for child in root.subviews { reapply(in: child) }
    }

    /// Assign a font to whichever of the handful of AppKit shapes this app
    /// actually sets fonts on. `NSControl` covers `NSTextField`, `NSButton`,
    /// `NSPopUpButton`, `NSSearchField` and `NSSegmentedControl`; `NSTextView`
    /// is the one non-control that matters here.
    private static func apply(_ font: NSFont, to view: NSView) {
        if let control = view as? NSControl {
            control.font = font
        } else if let textView = view as? NSTextView {
            textView.font = font
        }
    }
}

extension NSControl {

    /// Set a chrome-scaled font from its designed point size, and remember
    /// how it was derived so a later scale change can re-derive it
    /// (`HelmTextScale.reapply(in:)`).
    ///
    /// This is the replacement for a raw `field.font = .systemFont(ofSize: 11)`
    /// anywhere in this app's own chrome. `base` is the size the surrounding
    /// layout was measured at; `HelmType.scaled` applies the captain's scale
    /// and GL-32's 11pt floor on top of it, so a site that used to write a
    /// sub-11pt literal gets the floor for free.
    func setScaledFont(ofSize base: CGFloat,
                       weight: NSFont.Weight = .regular,
                       voice: HelmTextScale.Voice = .system) {
        let recipe = HelmTextScale.Recipe(base: base, weight: weight, voice: voice)
        HelmTextScale.record(recipe, on: self)
        font = recipe.font()
    }
}

extension NSTextView {

    /// `NSTextView` is not an `NSControl`, and three surfaces here set its
    /// font directly (the console composer's intent field, the chat
    /// transcripts). Same contract as the `NSControl` overload.
    func setScaledFont(ofSize base: CGFloat,
                       weight: NSFont.Weight = .regular,
                       voice: HelmTextScale.Voice = .system) {
        let recipe = HelmTextScale.Recipe(base: base, weight: weight, voice: voice)
        HelmTextScale.record(recipe, on: self)
        font = recipe.font()
    }
}
