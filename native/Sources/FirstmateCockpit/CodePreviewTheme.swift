// Manjesh Grand Line - native macOS app.
//
// The Code Preview destination's syntax palette: one `HelmTheme` in, the set
// of colours the page hands to `monaco.editor.defineTheme` out.
//
// ## Why the palette is the theme's own ANSI set
//
// Monaco ships `vs` and `vs-dark`, and using either would put a VS Code
// colour scheme inside an app that has fourteen of its own. Every `HelmTheme`
// already carries a sixteen-colour ANSI set - it is a terminal app - and those
// sets are exactly what a syntax palette needs: a red, a green, a yellow, a
// blue, a magenta and a cyan, chosen by whoever built that theme, in that
// theme's own voice.
//
// They are also the only colours in this app that are already
// **contrast-verified against `backgroundHex` specifically**. That is not a
// happy accident, it is why `backgroundHex` (the terminal's own ground) is the
// editor's background here rather than `chromeBackgroundHex` (the card
// surface): every theme's ANSI slots were tuned against it, and
// `FM_RUN_CONTRAST_TESTS` re-measures them there. `HelmTheme.light`'s own
// source comments record two of those corrections by hand
// ("index 3 darkened from ad6800 (4.11:1) to 995c00 (4.91:1)"), and
// `checkDaylightPalette` asserts the whole set for the Daylight family.
//
// ## The one correction this file still applies, and why it is needed
//
// Slots 1-15 clear the text floor on `backgroundHex` in every theme. **Slot 0
// does not, by nature** - AGENTS.md states the exemption plainly: a terminal's
// "black" cannot separate from a dark background and lightening it until it
// could would stop it being black. Slot 8 ("bright black") is derived from
// slot 0 in the Daylight family (a 15% blend), so it inherits the problem: on
// `dusk` it lands a hair above the page ground.
//
// Slot 8 is the natural comment colour - it is the documented
// "genuinely-dim-but-still-legible" slot in the hand-tuned palettes - so every
// colour here goes through `HelmContrast.legibleOn(fill:preferring:)`, which
// is a **no-op for any colour that already clears the floor** and a guaranteed
// correction for the ones that do not. That is the whole rule: no per-theme
// special cases, no exempted slots, and the twelve palettes where nothing
// needed correcting are byte-identical to their raw ANSI values.

import AppKit

/// The colours one `HelmTheme` contributes to the editor page.
///
/// A flat dictionary of hex strings rather than a struct with typed colours:
/// this crosses the WebKit bridge as JSON, and every value is consumed by
/// Monaco as a CSS colour string. Keeping it in the wire shape means there is
/// one conversion, at the boundary, rather than a struct that has to be
/// re-serialised anyway.
enum CodePreviewTheme {

    /// Monaco's own key names, so a caller (and the self-test) can name a
    /// colour without a string literal per call site.
    ///
    /// `operatorToken`'s raw value is pinned to `"operator"` explicitly -
    /// **this was the actual root cause of the captain's "Code Preview never
    /// re-themes" report** (`fm/grandline-recents-position-and-codepreview-
    /// theme`), and it shipped silently for the same reason every case here
    /// has to keep matching `Vendor/Monaco/src/code-preview.js`'s
    /// `applyTheme(t)` exactly: `operator` is a Swift keyword, so this case
    /// cannot be named after it directly, and every *other* case's
    /// auto-synthesised raw value already happens to equal the JS property
    /// name it feeds (`t.ink`, `t.comment`, `t.keyword`, ...) - so it is easy
    /// to assume the whole enum "just matches" without checking each one.
    /// Without this override the wire key was `"operatorToken"`, the JS side
    /// read `t.operator` (`undefined`), `strip(undefined)` produced an empty
    /// string, and `monaco.editor.defineTheme()` throws
    /// `"Illegal value for token color: "` on an empty rule foreground -
    /// synchronously, before its own `monaco.editor.setTheme(THEME_ID)` call
    /// ever runs. `CodePreviewController.pushTheme()` sent this bridge call
    /// with **no completion handler**, so that thrown-and-caught failure
    /// (the JS side replies `{ok: false, message: ...}` rather than crashing)
    /// was silently dropped on every single theme push since this feature
    /// shipped - Monaco therefore never once left its initial default `vs`
    /// (light) base theme, regardless of the app's own theme toggle, which is
    /// exactly the captain's screenshots. `pushTheme()` now logs a failure
    /// instead of swallowing it, so this class of regression cannot go silent
    /// again. Confirmed live via a bridge call that isolated the JS handler
    /// from the controller's own wiring: the reply was literally
    /// `"failure: Illegal value for token color: "` before this fix.
    enum Key: String, CaseIterable {
        case mode, background, chrome, ink, line
        case accent, selection, selectionInactive, currentLine, lineNumber
        case scrollbar, scrollbarHover
        case comment, keyword, string, constant, type, function, invalid
        case operatorToken = "operator"
    }

    /// Every colour the page's `applyTheme` reads, resolved from `theme`.
    static func palette(for theme: HelmTheme) -> [String: String] {
        let background = HelmTheme.nsColor(theme.backgroundHex)

        /// A syntax colour: this theme's own ANSI slot, corrected only if it
        /// does not already clear the text floor on the editor's ground.
        func syntax(_ ansiIndex: Int) -> String {
            legibleHex(HelmTheme.nsColor(theme.ansiHex[ansiIndex]), on: background)
        }

        // The ANSI slot each token role takes. A conventional terminal-scheme
        // mapping (keywords magenta, strings green, numbers yellow, types
        // cyan, functions blue) rather than an invented one, so a captain who
        // recognises their theme in a terminal recognises it here.
        //
        // Operators take slot 7 ("white"), which is not white: every theme in
        // this app deliberately treats that slot as a *muted ink* - see
        // `HelmTheme.light`'s own comment about darkening it from a 2.32:1
        // pale grey to a 6.75:1 muted ink - which is exactly the weight
        // punctuation should carry.
        return [
            Key.mode.rawValue: theme.mode == .dark ? "dark" : "light",

            Key.background.rawValue: "#" + theme.backgroundHex,
            Key.chrome.rawValue: "#" + theme.chromeBackgroundHex,
            Key.ink.rawValue: legibleHex(HelmTheme.nsColor(theme.foregroundHex), on: background),
            Key.line.rawValue: "#" + theme.chromeLineHex,
            Key.accent.rawValue: "#" + theme.accentHex,

            // Monaco composites these itself, so they are the one place an
            // alpha is genuinely wanted: an opaque selection fill would hide
            // the token colours underneath it, which is the opposite of what a
            // selection in a code editor should do.
            Key.selection.rawValue: rgba(theme.selectionHex, alpha: theme.mode == .dark ? 0.32 : 0.24),
            Key.selectionInactive.rawValue: rgba(theme.selectionHex, alpha: 0.16),
            Key.currentLine.rawValue: rgba(theme.chromeInkHex, alpha: theme.mode == .dark ? 0.06 : 0.05),
            Key.scrollbar.rawValue: rgba(theme.chromeInkHex, alpha: 0.18),
            Key.scrollbarHover.rawValue: rgba(theme.chromeInkHex, alpha: 0.30),

            // A line number is deliberately dim but has to stay readable, so
            // it takes the same correction path as a token rather than a raw
            // alpha - `mutedInk`'s own alpha is measured against
            // `chromeBackgroundHex`, which is not this surface.
            Key.lineNumber.rawValue: syntax(8),

            Key.comment.rawValue: syntax(8),   // bright black - the dim slot
            Key.keyword.rawValue: syntax(5),   // magenta
            Key.string.rawValue: syntax(2),    // green
            Key.constant.rawValue: syntax(3),  // yellow - numbers, true/false/null
            Key.type.rawValue: syntax(6),      // cyan
            Key.function.rawValue: syntax(4),  // blue
            Key.operatorToken.rawValue: syntax(7),
            Key.invalid.rawValue: syntax(1),   // red
        ]
    }

    /// `base` corrected against `surface`, **as the 8-bit hex that actually
    /// ships**.
    ///
    /// A real finding rather than belt-and-braces, and worth knowing before
    /// reaching for `HelmContrast.legibleOn` from a caller that serialises its
    /// result. That function's guarantee is about the `NSColor` it returns: it
    /// bisects until the ratio clears 4.5 and stops at the first blend that
    /// does, which lands *just* over the line by construction. Every colour
    /// here then crosses the WebKit bridge as a `#rrggbb` string, and rounding
    /// each channel to 8 bits moves the ratio by up to ±0.02 - which measured
    /// 4.47-4.50 for fourteen token/theme pairs across seven themes, i.e.
    /// below the floor for the colour Monaco was actually handed while the
    /// `NSColor` nobody renders was fine.
    ///
    /// So the check is made against the quantised value, and the correction
    /// continues from there until the *shipped* colour clears the floor.
    static func legibleHex(_ base: NSColor, on surface: NSColor) -> String {
        let corrected = HelmContrast.legibleOn(fill: surface, preferring: base)
        let candidate = hex(corrected)
        if HelmContrast.ratio(HelmTheme.nsColor(String(candidate.dropFirst())), surface) >= textFloor {
            return candidate
        }
        // One 8-bit step at a time toward whichever endpoint this surface has
        // headroom against - the same endpoint choice `legibleOn` makes, for
        // the same reason (a tone already close to one extreme has nowhere
        // left to go in that direction). 255 steps is a hard bound, and the
        // endpoint itself is always at or above 4.58:1 against any colour, so
        // this terminates.
        let endpoint: NSColor = HelmContrast.ratio(.black, surface) > HelmContrast.ratio(.white, surface)
            ? .black : .white
        for step in 1...255 {
            let fraction = CGFloat(step) / 255.0
            guard let blended = corrected.blended(withFraction: fraction, of: endpoint) else { break }
            let candidate = hex(blended)
            if HelmContrast.ratio(HelmTheme.nsColor(String(candidate.dropFirst())), surface) >= textFloor {
                return candidate
            }
        }
        return hex(endpoint)
    }

    /// WCAG AA for body text - the same floor `HelmContrast` enforces
    /// everywhere else in this app, named here because this file measures
    /// against it directly.
    static let textFloor: Double = 4.5

    /// `#rrggbb` for an opaque colour.
    static func hex(_ color: NSColor) -> String {
        let (r, g, b) = HelmContrast.components(color)
        func byte(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// `#rrggbbaa` - the form Monaco's `colors` map accepts for a translucent
    /// UI colour.
    private static func rgba(_ hexString: String, alpha: Double) -> String {
        let a = max(0, min(255, Int((alpha * 255).rounded())))
        return String(format: "%@%02X", "#" + hexString.uppercased(), a)
    }
}
