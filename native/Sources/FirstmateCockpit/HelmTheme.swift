// Manjesh Grand Line - native macOS app.
//
// The "Helm" terminal palette (design report section 9), plus 10 real named
// theme families (cockpit-theme-overhaul), plus `daylight` - the
// captain-approved Daylight design language's own palette, which lives in
// `HelmDaylight.swift` alongside the rest of its token layer.
// `helm-dark`/`helm-light` are the
// original, hand-pinned Helm tokens; the other 10 are sourced verbatim from
// each family's own canonical repo (see `data/cockpit-theme-research/report.md`
// for exact sources, per-family tables, and the reasoning behind every
// deviation from canonical values below).
//
// `foreground`/`background` come straight from Helm `--ink` / `--term-bg`, the
// cursor from `--accent`, and the ANSI reds/greens/yellows/blues are tuned off
// Helm `--bad` / `--ok` / `--need` / `--accent` so the terminal reads as the same
// instrument panel as the rest of the cockpit.
//
// Contrast is verified with a hand-written WCAG relative-luminance check
// (sRGB -> linear -> 0.2126R + 0.7152G + 0.0722B -> (L1+0.05)/(L2+0.05)) held
// to a 4.5:1 floor for text-bearing fields. There used to be a
// `scripts/verify-contrast.mjs` for the old web app that did the equivalent
// check against OKLCH input; it was removed along with that app
// (`83cd4b3`) and never carried forward - this file's comments no longer
// point at it.

import AppKit
import SwiftTerm

/// The colours a theme's **terminal cells** are painted in, when those should
/// differ from the page around them.
///
/// K2 of the UI modernization audit (`data/grandline-ui-modernization-audit/
/// report.md` §3K) finishing the design doc's §6.13: "the terminal renders
/// inside a dark card". Only the Daylight family has one; `terminalCard` is
/// `nil` for all twelve pre-Daylight palettes, where the page ground and the
/// terminal background are correctly the same colour.
///
/// **One struct rather than four optional fields on `HelmTheme`, and that is
/// the safety property.** A background set without a matching ANSI set is an
/// illegible terminal - light-corrected glyphs on a dark fill - so "either
/// this theme's terminal has its own palette or it does not" has to be one
/// decision, not four that can disagree.
///
/// **Selection is deliberately absent.** `HelmTheme.selectionHex` is an
/// *opaque* fill with `selectionTextHex` drawn on it (see `apply(to:)`'s own
/// note on why it is not alpha-blended), so that pair's contrast does not
/// depend on what is behind it and needs no per-surface variant. What it does
/// need is to stay *visible* against the card, which is a separation floor
/// rather than a text floor - `HelmContrastSelfTest.checkTerminalCard`
/// measures it.
struct HelmTerminalCard {
    /// The card's fill - SwiftTerm's `nativeBackgroundColor`.
    let backgroundHex: String
    /// Default cell ink - SwiftTerm's `nativeForegroundColor`.
    let inkHex: String
    /// The caret. Its own field because a cursor that reads correctly on the
    /// page ground can vanish on the card: Daylight's page cursor (the
    /// light-corrected link blue) measures **3.07:1** on this card, against
    /// the dark register's own blue at 4.89:1.
    let cursorHex: String
    /// 16 ANSI colours for *this* surface, same SwiftTerm/xterm order as
    /// `HelmTheme.ansiHex`.
    let ansiHex: [String]
}

/// A complete terminal colour scheme: the 16 ANSI colours plus foreground,
/// background, cursor, and selection.
struct HelmTheme {
    enum Mode { case dark, light }

    /// Stable identifier - used for persistence (`ThemeManager`) and for the
    /// topbar/Settings theme pickers to look a theme back up by id.
    let id: String
    let mode: Mode
    let name: String
    /// The id of this theme's light/dark counterpart within the same family
    /// (e.g. `catppuccin-mocha` <-> `catppuccin-latte`), used by
    /// `ThemeManager.toggle()` to flip within a family instead of always
    /// landing on `helm-dark`/`helm-light`.
    let pairId: String
    /// Window / chrome colours so the AppKit shell around the terminal matches.
    let chromeBackgroundHex: String
    let chromeInkHex: String
    let chromeLineHex: String
    let accentHex: String

    let foregroundHex: String
    let backgroundHex: String
    let cursorHex: String
    let selectionHex: String
    /// Text colour for a selected run, paired with `selectionHex` so selected
    /// text always clears WCAG AA against the (now opaque) selection fill -
    /// the same role as the web app's `--accent-ink` token against `--accent`.
    /// Without this SwiftTerm defaults `selectedTextForegroundColor` to a
    /// hardcoded black, which is unreadable once `selectionHex` is a
    /// mid-luminance accent (every light theme) rather than a pale tint.
    let selectionTextHex: String
    /// 16 ANSI colours, in SwiftTerm/xterm order:
    /// black, red, green, yellow, blue, magenta, cyan, white, then the 8 bright.
    let ansiHex: [String]

    /// This theme's terminal cells, when they should NOT be painted in the
    /// same colours as the page around them - `nil` for every theme where
    /// they should, which is all twelve pre-Daylight palettes.
    ///
    /// K2 of the UI modernization audit, finishing the design doc's §6.13.
    /// See `HelmTerminalCard` for why this is one optional struct rather than
    /// four parallel optional fields, and `HelmDaylight.swift`'s
    /// `darkRegisterTerminalCard` for where the values come from.
    let terminalCard: HelmTerminalCard?

    // MARK: Apply

    /// Install this theme onto a SwiftTerm terminal view: the 16 ANSI colours,
    /// then foreground / background / cursor / selection.
    ///
    /// **A theme with a `terminalCard` paints the cells from that instead**,
    /// which is what makes §6.13's dark card real rather than a border drawn
    /// around a light terminal. Selection is deliberately NOT part of the
    /// override - see `HelmTerminalCard`'s own note on why that pair is
    /// already background-independent.
    func apply(to view: TerminalView) {
        let cells = terminalCard
        view.installColors((cells?.ansiHex ?? ansiHex).map(Self.termColor))
        view.nativeForegroundColor = Self.nsColor(cells?.inkHex ?? foregroundHex)
        view.nativeBackgroundColor = Self.nsColor(cells?.backgroundHex ?? backgroundHex)
        view.caretColor = Self.nsColor(cells?.cursorHex ?? cursorHex)
        // Opaque, not alpha-blended: an alpha-blended fill's effective colour
        // (and thus its contrast against selectionTextHex) depends on
        // whatever background happened to be underneath a given cell -
        // including arbitrary ANSI colours from the remote program's own
        // output. A solid fill keeps the contrast guarantee exact.
        view.selectedTextBackgroundColor = Self.nsColor(selectionHex)
        view.selectedTextForegroundColor = Self.nsColor(selectionTextHex)
        view.needsDisplay = true
    }

    // MARK: Colour parsing

    /// `"rrggbb"` (or `"#rrggbb"`) -> the three 8-bit channels.
    private static func channels(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    }

    static func termColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = channels(hex)
        // SwiftTerm.Color channels are 16-bit; scale 8-bit 0-255 to 0-65535 (× 257).
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = channels(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// The one "muted/secondary text" tone every destination should use
    /// instead of picking its own opacity ad hoc (Fix 8, fixes4). Alpha-
    /// blending `chromeInkHex` looks fine in the dark palettes at much lower
    /// opacity, but the same opacity can silently drop below WCAG AA (4.5:1)
    /// in the light ones - that's exactly how the Overview dashboard's PR
    /// text and timestamps went near-invisible.
    ///
    /// 0.7 was the measured floor **for the original 8 palettes only**, and
    /// the doc comment here used to say so and leave it. The full-app UI
    /// audit re-measured it against all 12 (`fm/grandline-design-audit-phase0`,
    /// audit §7 item 7) and found a flat 0.7 genuinely fails five of the ten
    /// sourced-family themes - solarized-dark 3.14, catppuccin-latte 3.47,
    /// tokyo-night-light 3.75, rose-pine-dawn 4.04, gruvbox-light 4.37 -
    /// because those palettes' own `chromeInkHex`/background pairs are
    /// naturally lower-contrast than Helm's hand-picked tones.
    ///
    /// So this is no longer one flat constant. `baseMutedAlpha` (0.7) is the
    /// starting point and the **look** every theme that can afford it keeps
    /// byte for byte; a theme that cannot is raised - by the smallest amount
    /// that clears 4.5:1 against the *worse* of the two surfaces real text
    /// sits on (`chromeBackgroundHex` and `backgroundHex`), never further.
    /// Raising the constant globally instead would have washed out the seven
    /// themes that already clear it comfortably (helm-dark measures 8.36) for
    /// no reason. Contrast rises monotonically with alpha here - more alpha
    /// means less of the background showing through - so a plain bisection
    /// finds the minimum directly. Covered by `HelmContrastSelfTest`
    /// (`FM_RUN_CONTRAST_TESTS=1`), which fails if any theme drops below the
    /// floor the next time a palette is added or a token retuned.
    static let baseMutedAlpha: CGFloat = 0.7

    // MARK: - The side-panel tone

    /// How far apart a page's nav column and the page ground have to measure
    /// before the two read as two regions rather than one flat surface.
    ///
    /// **1.08:1, and it is this app's own existing step rather than a number
    /// picked here.** Daylight's `card` over its `paper` (`FFFFFF` over
    /// `F5F2EA`) measures 1.08:1 and Dusk's measures 1.12:1 - that pair is
    /// what already carries "cards float on a ground" in the two palettes
    /// this design system was actually specified against, so a nav column
    /// separated by the same step sits on the scale the rest of the app
    /// already uses instead of introducing a second, louder one.
    static let sidePanelSeparation: Double = 1.08

    /// The fill a **page-scoped nav column** paints behind itself, so the
    /// column and the content beside it read as two regions.
    ///
    /// **Why this is derived rather than a token.** The obvious spelling is
    /// "blend the card into the page ground", which is what the captain's
    /// reference does (`--side: color-mix(in srgb, var(--panel) 55%,
    /// var(--bg))`). That spelling cannot work here:
    /// `chromeBackgroundHex == backgroundHex` in several of the palettes -
    /// `HelmCard.borderAlpha`'s own comment names `gruvbox-light`,
    /// `tokyo-night-dark` and `tokyo-night-light`, and `helm-dark` matched
    /// the two deliberately when the terminal background was aligned to the
    /// chrome - so in those themes a card/ground blend is the ground, at any
    /// mix fraction, and the column stays invisible. That is precisely the
    /// defect this exists to fix, so the derivation must not be able to
    /// reproduce it in any palette.
    ///
    /// So the tone is derived from the page ground alone, stepped toward
    /// whichever of black/white reads as "a surface above this one" for the
    /// theme's own register - lighten on a dark palette, darken on a light
    /// one, the same direction `NSColor.hoverShifted(by:forMode:)` already
    /// picks for a hover shade. The fraction is **bisected to the smallest
    /// one that clears `sidePanelSeparation`** rather than fixed, for the
    /// same reason `mutedAlpha(for:)` bisects instead of shipping a flat
    /// 0.7: a fixed fraction against a near-white paper and against a
    /// near-black one do not land on the same perceptual step, so a constant
    /// that looks right in one register is either invisible or heavy-handed
    /// in the other.
    ///
    /// The result is a *fill*, never text. Anything drawn on it goes through
    /// `HelmContrast` like any other surface (AGENTS.md's colour rules).
    static func sidePanelFill(_ theme: HelmTheme) -> NSColor {
        if let cached = sidePanelCache.value(for: theme.id) { return cached }
        let resolved = computeSidePanelFill(theme)
        sidePanelCache.store(resolved, for: theme.id)
        return resolved
    }

    private static let sidePanelCache = SidePanelFillCache()

    /// The largest step this is ever allowed to take. A palette whose ground
    /// is already a hair from its endpoint (pure white paper, pure black
    /// ground) still resolves - the endpoint itself clears the floor - so
    /// this cap is a guard against a pathological palette rather than a
    /// value any real theme reaches.
    private static let maxSidePanelStep: CGFloat = 0.5

    private static func computeSidePanelFill(_ theme: HelmTheme) -> NSColor {
        let ground = nsColor(theme.backgroundHex)
        let groundComponents = HelmContrast.components(ground)
        let endpoint: (Double, Double, Double) = theme.mode == .dark ? (1, 1, 1) : (0, 0, 0)

        // `HelmContrast.mix(a, b, t)` weights its **first** argument by `t`,
        // so the endpoint goes first and `fraction` is how much of it shows.
        // Spelling this the other way round inverts the bisection below -
        // measured, it resolved every palette to the pure endpoint (a white
        // band on Nord Polar, a black one on Nord Snow) and the render check
        // in `ThemeFamilyRenderSelfTest` is what caught it.
        func stepped(_ fraction: CGFloat) -> (Double, Double, Double) {
            HelmContrast.mix(endpoint, groundComponents, Double(fraction))
        }
        func clears(_ fraction: CGFloat) -> Bool {
            HelmContrast.ratio(stepped(fraction), groundComponents) >= sidePanelSeparation
        }

        // Contrast against the ground rises monotonically with the step - more
        // of the endpoint showing means further from where we started - so a
        // plain bisection finds the minimum directly, exactly as
        // `computeMutedAlpha` does for its own alpha.
        guard clears(maxSidePanelStep) else { return HelmContrast.color(stepped(maxSidePanelStep)) }
        var low: CGFloat = 0
        var high = maxSidePanelStep
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if clears(mid) { high = mid } else { low = mid }
        }
        return HelmContrast.color(stepped(high))
    }

    /// The edge between a nav column and the content beside it.
    ///
    /// The colour difference alone carries the boundary in most palettes, but
    /// `sidePanelSeparation` is deliberately a *minimum* - in a theme that
    /// lands near it the two tones are a step apart and little more, which is
    /// the case a hairline exists for. Same tone and the same damping every
    /// other 1px edge in this app draws, through `HelmCard`'s own constants
    /// rather than a second copy of them, so the column's edge and a card's
    /// edge are one idiom and cannot drift apart.
    static func sidePanelEdge(_ theme: HelmTheme) -> NSColor {
        theme.isDaylight
            ? nsColor(theme.daylightTokens.hair)
            : nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.borderAlpha)
    }

    private static let mutedAlphaCache = MutedAlphaCache()

    static func mutedInk(_ theme: HelmTheme) -> NSColor {
        // Daylight publishes a real muted token (§2.1's `muted`, corrected in
        // §2.4) rather than leaving this to be an alpha of its ink. That
        // matters for more than precision: `muted` is a warm grey-brown, and
        // `ink` at any alpha over warm paper lands on a *cool* grey of roughly
        // the same luminance - legible, but off-palette. Every other theme
        // keeps the bisected-alpha derivation below unchanged.
        if theme.isDaylight { return nsColor(theme.daylightTokens.muted) }
        return nsColor(theme.chromeInkHex).withAlphaComponent(mutedAlpha(for: theme))
    }

    /// The alpha `mutedInk` actually uses for `theme` - exposed so the
    /// contrast self-test can report it, and so a probe can confirm a given
    /// theme was or was not raised.
    static func mutedAlpha(for theme: HelmTheme) -> CGFloat {
        // Daylight's `mutedInk` is an opaque token, so it is composited at
        // full strength - reported here for the self-test's own printout
        // rather than used to derive anything.
        if theme.isDaylight { return 1 }
        if let cached = mutedAlphaCache.value(for: theme.id) { return cached }
        let resolved = computeMutedAlpha(for: theme)
        mutedAlphaCache.store(resolved, for: theme.id)
        return resolved
    }

    private static func computeMutedAlpha(for theme: HelmTheme) -> CGFloat {
        let ink = HelmContrast.components(nsColor(theme.chromeInkHex))
        let surfaces = [theme.chromeBackgroundHex, theme.backgroundHex].map {
            HelmContrast.components(nsColor($0))
        }
        func clears(_ alpha: CGFloat) -> Bool {
            surfaces.allSatisfy { surface in
                HelmContrast.ratio(HelmContrast.mix(ink, surface, Double(alpha)), surface) >= HelmContrast.textTarget
            }
        }
        if clears(baseMutedAlpha) { return baseMutedAlpha }
        // Even fully opaque ink cannot separate from this palette's own
        // surface (no palette shipped today is in this state) - use the most
        // legible value available rather than staying at the failing default.
        if !clears(1) { return 1 }
        var lo = Double(baseMutedAlpha), hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if clears(CGFloat(mid)) { hi = mid } else { lo = mid }
        }
        return CGFloat(hi)
    }

    /// Tiny thread-safe memo - `mutedInk` is called for effectively every
    /// muted label on every re-theme, and the bisection above, while cheap,
    /// has no reason to run more than once per palette.
    /// Same shape as `MutedAlphaCache` below and for the same reason: the
    /// derivation bisects, and a fill is asked for on every repaint of every
    /// themed column.
    private final class SidePanelFillCache {
        private var storage: [String: NSColor] = [:]
        private let lock = NSLock()
        func value(for id: String) -> NSColor? {
            lock.lock(); defer { lock.unlock() }
            return storage[id]
        }
        func store(_ value: NSColor, for id: String) {
            lock.lock(); defer { lock.unlock() }
            storage[id] = value
        }
    }

    private final class MutedAlphaCache {
        private var storage: [String: CGFloat] = [:]
        private let lock = NSLock()
        func value(for id: String) -> CGFloat? {
            lock.lock(); defer { lock.unlock() }
            return storage[id]
        }
        func store(_ value: CGFloat, for id: String) {
            lock.lock(); defer { lock.unlock() }
            storage[id] = value
        }
    }

    // MARK: The two original, hand-pinned Helm palettes

    static let dark = HelmTheme(
        id: "helm-dark",
        mode: .dark,
        name: "Helm Dark",
        pairId: "helm-light",
        chromeBackgroundHex: "111820", // --surface
        chromeInkHex: "f0f4f7",        // --ink
        chromeLineHex: "323a43",       // --line
        accentHex: "6cd7e3",           // --accent
        foregroundHex: "f0f4f7",       // --ink
        // Matched to chromeBackgroundHex (was "05090e") so the terminal
        // canvas is pixel-identical to the surrounding chrome, rather than a
        // subtly darker shade - the visible seam the captain reported.
        // `fm/grand-line-legacy-terminal-canvas-chrome-match` applied this
        // uniformly across every legacy (pre-Daylight) palette; see
        // `data/grand-line-terminal-pane-theme-match-scout/report.md`. This
        // does NOT touch the separate, deliberate dark-terminal-card design
        // on `daylight`/`dusk` (see `HelmTerminalCard`/`HelmDaylight.swift`).
        backgroundHex: "111820",       // --surface (was "05090e", --term-bg)
        cursorHex: "6cd7e3",           // --accent
        selectionHex: "6cd7e3",        // --accent, opaque fill
        selectionTextHex: "001a22",    // --accent-ink (10.6:1 on the accent fill)
        ansiHex: [
            // index 8 (bright black / "dim") brightened from 585e65 (3.05:1 on
            // term-bg, below the 4.5:1 floor) to 747c86 (4.68:1) - it is used
            // for genuinely-dim-but-still-legible text (comments, timestamps).
            "292e34", "ef6661", "67d283", "f2bf4e", "5eade2", "d285cb", "71cfd9", "ced1d4",
            "747c86", "ff8179", "7fe998", "ffd972", "7dc7f7", "e9a1e3", "96e8ef", "f9fcfe",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    static let light = HelmTheme(
        id: "helm-light",
        mode: .light,
        name: "Helm Light",
        pairId: "helm-dark",
        chromeBackgroundHex: "fcfeff", // --surface
        chromeInkHex: "212c3a",        // --ink
        chromeLineHex: "cdd5dd",       // --line
        accentHex: "007194",           // --accent
        foregroundHex: "212c3a",       // --ink
        // Matched to chromeBackgroundHex (was "f5f7f9", --term-bg) - see the
        // fuller note on `helm-dark`'s `backgroundHex` above.
        backgroundHex: "fcfeff",       // --surface
        cursorHex: "007194",           // --accent
        selectionHex: "007194",        // --accent, opaque fill
        selectionTextHex: "f9fcff",    // --accent-ink (5.4:1 on the accent fill)
        ansiHex: [
            // index 3 (yellow) darkened from ad6800 (4.11:1) to 995c00
            // (4.91:1) - just under the floor on a light background.
            // index 7 ("white", i.e. SGR 37/1m bold-white without an
            // explicit bright flag) was 9ca5b1, a pale grey at only 2.32:1
            // on term-bg - effectively invisible, and the actual bug the
            // captain hit: SwiftTerm only promotes indices 0-6 to their
            // bright siblings on bold text, so bold "white" stays on this
            // slot rather than jumping to index 15. Darkened to 4c5866
            // (6.75:1), the same muted-ink hue the web app uses for
            // secondary text on this theme.
            "272e38", "c22826", "007a43", "995c00", "0069a1", "93398e", "007984", "4c5866",
            "4e5661", "b3000d", "006c32", "9d5400", "005893", "852381", "006875", "212c3a",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )
}

// MARK: - The 10 named-family palettes (cockpit-theme-overhaul)
//
// Sourced from each family's own canonical repo - see
// `data/cockpit-theme-research/report.md` Part 2 for exact source URLs, the
// full per-family contrast tables, and the reasoning behind every deviation
// called out below. Unlike the old `derived(...)` palettes these are not
// computed from OKLCH tokens - every hex value here is either lifted
// verbatim from the family's own source, or a deliberate, documented
// deviation from it.

extension HelmTheme {
    // --- Solarized (github.com/altercation/solarized) ---
    //
    // Solarized's own README.md defines a single set of 8 accent hues + an
    // 8-step monotone ramp (base03...base3) reused unchanged across both
    // modes - only which end of the ramp is "background" flips.
    static let solarizedDarkAnsi = [
        "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
        // index 8 ("bright black") is base03 - the same hex as this theme's
        // own backgroundHex, an exact 1.00:1 self-match. This is a known,
        // accepted Solarized limitation (confirmed in the family's own
        // ANSI-16 table): no other ramp step is a clean substitute without
        // stopping to look like Solarized's own "bright black".
        "002b36", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "fdf6e3",
    ]

    static let solarizedDark = HelmTheme(
        id: "solarized-dark", mode: .dark, name: "Solarized Dark", pairId: "solarized-light",
        chromeBackgroundHex: "073642", chromeInkHex: "93a1a1", chromeLineHex: "586e75",
        accentHex: "2aa198",
        // backgroundHex matched to chromeBackgroundHex (was "002b36",
        // Solarized's `base03`) - see the fuller note on `helm-dark`'s
        // `backgroundHex` above.
        //
        // foregroundHex moved from `base0` (`839496`) to `base1` (`93a1a1`)
        // as a direct consequence: `base0` was tuned to clear 4.75:1 against
        // the old, darker `base03` background, and only reaches 4.11:1 (under
        // the 4.5:1 floor - `checkTextSelectionContrast` caught it) against
        // the new, lighter `base02`. `base1` is the next step up Solarized's
        // own monotone ramp - the same "one step up the family's own ramp,
        // not a hand-mixed darkening" correction `solarized-light`'s own
        // `foregroundHex` already uses below - and it clears 4.86:1. It is
        // also, not by coincidence, already this theme's `chromeInkHex`: once
        // the terminal's background is literally the chrome's background, the
        // terminal's own default text colour matching the chrome's own ink
        // token is the natural, zero-hue-drift consequence.
        foregroundHex: "93a1a1", backgroundHex: "073642",
        cursorHex: "2aa198", selectionHex: "2aa198", selectionTextHex: "002b36",
        ansiHex: solarizedDarkAnsi,
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    static let solarizedLight = HelmTheme(
        id: "solarized-light", mode: .light, name: "Solarized Light", pairId: "solarized-dark",
        chromeBackgroundHex: "eee8d5", chromeInkHex: "002b36", chromeLineHex: "93a1a1",
        accentHex: "2aa198",
        // `base01`/`base3`. This shipped as `base00` (`657b83`) - Solarized's
        // own README-recommended default body pairing - which measures
        // **4.13:1**, under the 4.5:1 floor, and was carried as an accepted
        // limitation because the sourcing report's contrast pass only covered
        // the ANSI/accent/chrome slots. `fm/grandline-text-selection-contrast-
        // audit` swept normal text as well and this was the one theme of the
        // fourteen that failed it.
        //
        // The correction is one step **up the family's own monotone ramp**
        // (base00 -> base01), not a hand-mixed darkening: base01 is a
        // canonical Solarized value that the spec itself lists for emphasized
        // content on a light background, so there is no hue drift and the
        // palette's identity is untouched. Measures 4.99:1 on `base3`.
        //
        // backgroundHex matched to chromeBackgroundHex (was "fdf6e3", i.e.
        // `base3`) - see the fuller note on `helm-dark`'s `backgroundHex`
        // above. That in turn broke the `base01` correction immediately
        // above: `base01` was tuned to clear 4.99:1 against `base3`, and only
        // reaches 4.39:1 (under the 4.5:1 floor - `checkTextSelectionContrast`
        // caught it) against the new, darker `base2`. `base3`/`base01` are
        // adjacent on the ramp with no intermediate step available, so the
        // next value that clears the floor is `base03` (`002b36`, 12.25:1) -
        // still one canonical Solarized value with no hue drift, and, not by
        // coincidence, already this theme's `chromeInkHex`: once the
        // terminal's background is literally the chrome's background, the
        // terminal's own default text colour matching the chrome's own ink
        // token is the natural, zero-hue-drift consequence (the same
        // reasoning `solarized-dark`'s own `foregroundHex` fix above uses).
        foregroundHex: "002b36", backgroundHex: "eee8d5",
        cursorHex: "2aa198", selectionHex: "2aa198", selectionTextHex: "002b36",
        ansiHex: [
            "073642", "dc322f", "859900",
            // index 3 (yellow) ships as canonical b58900 despite measuring
            // only 2.98:1 against this light background - darkening it away
            // from Solarized's actual yellow isn't worth the hue drift for a
            // slot most themes here only use sparingly. Accepted limitation.
            "b58900",
            "268bd2", "d33682", "2aa198",
            // index 7/15 ("white"/"bright white") deviate from canonical
            // base2/base3 (`eee8d5`/`fdf6e3`) - both measure 1.14:1/1.00:1
            // against this light background, nearly invisible. base01
            // (`586e75`) is the only ramp step that clears 4.5:1 (4.99:1)
            // without abandoning Solarized's own ramp for a non-canonical hue.
            "586e75",
            "002b36", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "586e75",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    // --- Catppuccin (github.com/catppuccin/palette, github.com/catppuccin/alacritty) ---
    //
    // Every value below is sourced verbatim - the report found zero contrast
    // failures for this family, so no deviations were needed anywhere.
    static let catppuccinMocha = HelmTheme(
        id: "catppuccin-mocha", mode: .dark, name: "Catppuccin Mocha", pairId: "catppuccin-latte",
        chromeBackgroundHex: "1e1e2e", chromeInkHex: "cdd6f4", chromeLineHex: "6c7086",
        accentHex: "cba6f7",
        // backgroundHex matched to chromeBackgroundHex (was "181825") - see
        // the fuller note on `helm-dark`'s `backgroundHex` above.
        foregroundHex: "cdd6f4", backgroundHex: "1e1e2e",
        cursorHex: "cba6f7", selectionHex: "cba6f7", selectionTextHex: "1e1e2e",
        ansiHex: [
            "45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
            "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    static let catppuccinLatte = HelmTheme(
        id: "catppuccin-latte", mode: .light, name: "Catppuccin Latte", pairId: "catppuccin-mocha",
        chromeBackgroundHex: "eff1f5", chromeInkHex: "4c4f69", chromeLineHex: "9ca0b0",
        accentHex: "8839ef",
        // backgroundHex matched to chromeBackgroundHex (was "e6e9ef") - see
        // the fuller note on `helm-dark`'s `backgroundHex` above.
        foregroundHex: "4c4f69", backgroundHex: "eff1f5",
        cursorHex: "8839ef", selectionHex: "8839ef", selectionTextHex: "eff1f5",
        ansiHex: [
            "bcc0cc", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "5c5f77",
            "acb0be", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "6c6f85",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    // --- Gruvbox (github.com/morhetz/gruvbox, colors/gruvbox.vim) ---
    static let gruvboxDark = HelmTheme(
        id: "gruvbox-dark", mode: .dark, name: "Gruvbox Dark", pairId: "gruvbox-light",
        chromeBackgroundHex: "3c3836", chromeInkHex: "ebdbb2", chromeLineHex: "665c54",
        accentHex: "fe8019",
        // backgroundHex matched to chromeBackgroundHex (was "282828") - see
        // the fuller note on `helm-dark`'s `backgroundHex` above.
        foregroundHex: "ebdbb2", backgroundHex: "3c3836",
        cursorHex: "fe8019", selectionHex: "fe8019", selectionTextHex: "282828",
        ansiHex: [
            "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
            // index 8 ("bright black" / dim-but-legible text, per this
            // project's own precedent for this slot) brightened from
            // Gruvbox's canonical `gray` (928374, 4.02:1 on this background -
            // below the 4.5:1 floor this slot is held to) to 9e8c7a
            // (4.55:1), staying the same grey-brown hue.
            "9e8c7a", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    static let gruvboxLight = HelmTheme(
        id: "gruvbox-light", mode: .light, name: "Gruvbox Light", pairId: "gruvbox-dark",
        chromeBackgroundHex: "fbf1c7", chromeInkHex: "3c3836", chromeLineHex: "bdae93",
        accentHex: "af3a03",
        foregroundHex: "3c3836", backgroundHex: "fbf1c7",
        cursorHex: "af3a03", selectionHex: "af3a03", selectionTextHex: "fbf1c7",
        ansiHex: [
            "fbf1c7", "cc241d", "98971a",
            // index 3 (yellow) darkened from canonical `neutral_yellow`
            // (d79921, 2.19:1 on this light background) to 876700 (4.66:1) -
            // Gruvbox publishes no third yellow to fall back to.
            "876700",
            "458588", "b16286", "689d6a", "7c6f64",
            // index 8 ("bright black"), same fix as gruvbox-dark's ansi[8]
            // but darkened instead: canonical `gray` (928374) measures only
            // 3.24:1 here; 726557 clears at 4.98:1, same grey-brown hue.
            "726557",
            "9d0006", "79740e",
            // index 11 ("bright yellow" / faded_yellow) darkened from
            // canonical b57614 (3.33:1) to 8f5f0a (4.86:1), same reasoning
            // as index 3 above.
            "8f5f0a",
            "076678", "8f3f71", "427b58", "3c3836",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    // --- Tokyo Night (github.com/enkia/tokyo-night-vscode-theme) ---
    static let tokyoNightDark = HelmTheme(
        id: "tokyo-night-dark", mode: .dark, name: "Tokyo Night", pairId: "tokyo-night-light",
        chromeBackgroundHex: "16161e", chromeInkHex: "a9b1d6",
        // No dedicated divider token is published for this family; derived
        // as a ~12% blend of chromeInkHex into chromeBackgroundHex, the same
        // ratio helm-dark/helm-light's own hand-picked chromeLineHex sits at
        // relative to their chrome background (~1.5:1, decorative only).
        chromeLineHex: "282934",
        accentHex: "7aa2f7",
        // `editor.foreground`, not the literal `terminal.foreground`
        // (787c99) - that value measures only 4.40:1 on this background,
        // just under the floor. `editor.foreground` is an equally authentic
        // published Tokyo Night token and clears at 8.10:1.
        foregroundHex: "a9b1d6", backgroundHex: "16161e",
        cursorHex: "7aa2f7", selectionHex: "7aa2f7", selectionTextHex: "16161e",
        ansiHex: [
            "363b54", "f7768e", "73daca", "e0af68", "7aa2f7", "bb9af7", "7dcfff",
            // index 7 ("white") - same `editor.foreground` swap as
            // `foregroundHex` above, replacing canonical `terminal.foreground`.
            "a9b1d6",
            "363b54", "f7768e", "73daca", "e0af68", "7aa2f7", "bb9af7", "7dcfff",
            // index 15 ("bright white") keeps the canonical, unreplaced
            // `terminal.foreground`-derived value - enkia's port doesn't
            // distinguish it from index 7 the way it does on light mode below.
            "acb0d0",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    static let tokyoNightLight = HelmTheme(
        id: "tokyo-night-light", mode: .light, name: "Tokyo Night Light", pairId: "tokyo-night-dark",
        chromeBackgroundHex: "d6d8df", chromeInkHex: "343b59",
        chromeLineHex: "c3c5cf",
        accentHex: "2959aa",
        foregroundHex: "343b59", backgroundHex: "d6d8df",
        cursorHex: "2959aa", selectionHex: "2959aa", selectionTextHex: "d6d8df",
        ansiHex: [
            "343B58", "8c4351", "33635c",
            // index 3 (yellow) ships as canonical 8f5e15 despite measuring
            // only 3.90:1 - no alternate yellow is published for this port.
            // Accepted limitation, same reasoning as Solarized's yellow.
            "8f5e15",
            "2959aa", "7b43ba", "006c86",
            // index 7 ("white") - `editor.foreground` swap, same as dark
            // mode above, replacing canonical `terminal.foreground` (707280).
            "343b59",
            "343B58", "8c4351", "33635c", "8f5e15", "2959aa", "7b43ba", "006c86",
            // index 15 ("bright white") keeps the canonical value (707280,
            // 3.35:1) - enkia's port makes this the one slot that's
            // byte-identical to its normal counterpart, so it wasn't swapped
            // to `editor.foreground` like index 7 was. Accepted limitation,
            // no alternate published to substitute.
            "707280",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    // --- Rosé Pine (github.com/rose-pine/palette, /alacritty, /vscode) ---
    static let rosePineMain = HelmTheme(
        id: "rose-pine-main", mode: .dark, name: "Rosé Pine", pairId: "rose-pine-dawn",
        chromeBackgroundHex: "1f1d2e", chromeInkHex: "e0def4", chromeLineHex: "26233a",
        // `iris` - clears both the UI-accent job (7.88:1 on chromeBackground)
        // and the selection-fill job (8.43:1) on this mode; `pine` (used for
        // Dawn instead) fails the UI-accent job here at 2.70:1. An
        // intentionally asymmetric accent choice across the family's two
        // modes, mirroring how helm-dark/helm-light already use two
        // different accent hexes rather than a lightness twist of one hue.
        accentHex: "c4a7e7",
        // backgroundHex matched to chromeBackgroundHex (was "191724") - see
        // the fuller note on `helm-dark`'s `backgroundHex` above.
        foregroundHex: "e0def4", backgroundHex: "1f1d2e",
        cursorHex: "c4a7e7", selectionHex: "c4a7e7", selectionTextHex: "191724",
        ansiHex: [
            "26233a", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
            "6e6a86", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )

    static let rosePineDawn = HelmTheme(
        id: "rose-pine-dawn", mode: .light, name: "Rosé Pine Dawn", pairId: "rose-pine-main",
        chromeBackgroundHex: "fffaf3",
        // Current `rose-pine/palette` repo's `dawn.text` (`464261`), not the
        // older `575279` still shipped by some of the family's other ports
        // (`alacritty`/`vscode`) for the same role - both clear contrast,
        // `464261` is simply the more current source of record.
        chromeInkHex: "464261", chromeLineHex: "f2e9e1",
        // `pine` - clears both jobs on this mode (5.88:1 UI accent, 5.59:1
        // selection fill); `iris` (used for Main instead) fails both here.
        accentHex: "286983",
        // backgroundHex matched to chromeBackgroundHex (was "faf4ed") - see
        // the fuller note on `helm-dark`'s `backgroundHex` above.
        foregroundHex: "464261", backgroundHex: "fffaf3",
        cursorHex: "286983", selectionHex: "286983", selectionTextHex: "faf4ed",
        ansiHex: [
            "f2e9e1", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "464261",
            "9893a5", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "464261",
        ],
        // Twelve pre-Daylight palettes: the page ground and the
        // terminal background are correctly the same colour, so there
        // is no separate card to paint (K2 / HelmTerminalCard).
        terminalCard: nil
    )
}

// MARK: - The 6 captain-picked families (grandline-new-themes-nord-dracula-etc)
//
// Nord, Dracula/Alucard, One Dark/One Light, Ayu, Night Owl/Light Owl and
// Oxocarbon - the six families the captain picked off the theme-suggestions
// board. Sourcing, the per-family contrast table and the reasoning behind
// every deviation below are in `docs/history/44-new-theme-families.md`; the
// upstream file each hex was lifted from is named per family here.
//
// **Two conventions these twelve inherit rather than invent**, both of them
// load-bearing and both easy to get wrong:
//
// 1. `backgroundHex == chromeBackgroundHex`, and both are the family's own
//    canonical editor background. Every pre-Daylight palette is one-step
//    (`fm/grand-line-legacy-terminal-canvas-chrome-match` made it so, to kill
//    the seam between the terminal canvas and the chrome around it), and
//    `backgroundHex` is simultaneously the page ground *and* the terminal
//    background - so a second surface step here would reopen exactly that
//    seam. The card is separated from the page by `chromeLineHex` at
//    `HelmDesignSystem.borderAlpha`, the same way `gruvbox-light` and both
//    Tokyo Nights already are.
// 2. `selectionTextHex` is the primary button's label on the accent fill as
//    well as the terminal's selected-run ink, so it has to clear 4.5:1 on
//    `accentHex`. Four of the accents below are darkened for exactly that
//    reason, each along its own hue line and each marked.

extension HelmTheme {
    // --- Nord (github.com/nordtheme/nord, src/nord.css nord0-nord15) ---
    //
    // Nord ships **dark only** upstream. The light half is ours: it reuses
    // Nord's own Snow Storm ramp for the surfaces (which Nord does publish)
    // and darkens the Aurora/Frost hues along their own hue lines for paper.
    // That is a real ownership cost - there is no upstream to re-sync a Nord
    // light from - and it is recorded here rather than left to be discovered.
    static let nordPolar = HelmTheme(
        id: "nord-polar", mode: .dark, name: "Nord", pairId: "nord-snow",
        // nord0. Nord's own editor background, used for both surfaces per the
        // one-step convention above; nord1 (`3b4252`) is Nord's elevated
        // surface and is what `chromeLineHex`'s neighbour would have been.
        chromeBackgroundHex: "2e3440",
        chromeInkHex: "d8dee9",   // nord4
        chromeLineHex: "4c566a",  // nord3
        accentHex: "88c0d0",      // nord8, Nord's own primary accent
        foregroundHex: "d8dee9", backgroundHex: "2e3440",
        cursorHex: "88c0d0", selectionHex: "88c0d0",
        selectionTextHex: "2e3440", // nord0 on nord8: 6.24:1
        ansiHex: [
            "3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
            "4c566a", "bf616a", "a3be8c", "ebcb8b", "5e81ac", "b48ead", "8fbcbb", "eceff4",
        ],
        terminalCard: nil
    )

    static let nordSnow = HelmTheme(
        id: "nord-snow", mode: .light, name: "Nord Snow Storm", pairId: "nord-polar",
        chromeBackgroundHex: "eceff4", // nord6
        chromeInkHex: "2e3440",        // nord0
        // nord4 (`d8dee9`) is Nord's own divider tone and measures 1.11:1 on
        // nord6 - invisible, and this app's card border carries real load
        // (`HelmDesignSystem.borderAlpha`). Darkened along the same blue-grey
        // line to `c2cbd8`, which reads as a hairline without becoming a rule.
        chromeLineHex: "c2cbd8",
        // nord10 (`5e81ac`) darkened 17% along its own hue line. The canonical
        // value carries a white label at only 3.50:1, and this slot is the
        // primary button's fill - see convention (2) above. The scout's board
        // proposed a 14% darkening (`516f94`); measured against this app's own
        // `HelmContrast` that lands at **4.497:1** and fails the floor by
        // three thousandths, so it is one more step down the same line.
        accentHex: "4e6b8f",
        foregroundHex: "2e3440", backgroundHex: "eceff4",
        cursorHex: "4e6b8f", selectionHex: "4e6b8f",
        selectionTextHex: "eceff4", // nord6 on the darkened nord10: 4.77:1
        ansiHex: [
            // Aurora and Frost are published for a dark ground. Every slot
            // here is the canonical hue darkened for paper; the greys
            // (nord0-nord3) are verbatim.
            "4c566a", "a54049", "4a663a", "8a6a1f", "3b628f", "7d5178", "2e6a78", "4c566a",
            "434c5e", "bf616a", "5b7a46", "a17c2a", "5e81ac", "8f6389", "3d7e8c", "2e3440",
        ],
        terminalCard: nil
    )

    // --- Dracula / Alucard (github.com/dracula/dracula-theme README.md) ---
    //
    // The one family on this list that publishes its own light half, and
    // publishes it as a real palette rather than a community port.
    static let dracula = HelmTheme(
        id: "dracula", mode: .dark, name: "Dracula", pairId: "alucard",
        chromeBackgroundHex: "282a36", // Dracula `Background`
        chromeInkHex: "f8f8f2",        // `Foreground`
        chromeLineHex: "44475a",       // `Current Line` / `Selection`
        accentHex: "bd93f9",           // `Purple`
        foregroundHex: "f8f8f2", backgroundHex: "282a36",
        cursorHex: "bd93f9", selectionHex: "bd93f9",
        selectionTextHex: "282a36", // 5.90:1
        ansiHex: [
            "21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
            "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff",
        ],
        terminalCard: nil
    )

    static let alucard = HelmTheme(
        id: "alucard", mode: .light, name: "Alucard", pairId: "dracula",
        // Alucard's `Background` is the cream `fffbeb`, not white - that cream
        // *is* the theme's identity, so it is the single surface here. The
        // pure-white `ffffff` the family publishes alongside it is Alucard's
        // elevated surface and has no role under the one-step convention.
        chromeBackgroundHex: "fffbeb",
        chromeInkHex: "1f1f1f",  // `Foreground`
        chromeLineHex: "cfcfde", // `Current Line`
        accentHex: "644ac9",     // `Purple`
        foregroundHex: "1f1f1f", backgroundHex: "fffbeb",
        cursorHex: "644ac9", selectionHex: "644ac9",
        selectionTextHex: "fffbeb", // 6.02:1
        ansiHex: [
            "6c664b", "cb3a2a", "14710a", "846e15", "644ac9", "a3144d", "036a96", "1f1f1f",
            "6c664b", "cb3a2a", "14710a", "846e15", "644ac9", "a3144d", "036a96", "1f1f1f",
        ],
        terminalCard: nil
    )

    // --- One Dark / One Light (github.com/atom/one-*-syntax, styles/colors.less) ---
    //
    // Atom publishes these as HSL in Less (`hsl(220, 13%, 18%)`); every value
    // below is that arithmetic resolved, not a downstream port's rounding.
    static let oneDark = HelmTheme(
        id: "one-dark", mode: .dark, name: "One Dark", pairId: "one-light",
        chromeBackgroundHex: "282c34", // `syntax-bg`
        chromeInkHex: "abb2bf",        // `mono-1`
        chromeLineHex: "3e4451",       // `syntax-cursor-line`
        accentHex: "61afef",           // `hue-2`
        foregroundHex: "abb2bf", backgroundHex: "282c34",
        cursorHex: "61afef", selectionHex: "61afef",
        selectionTextHex: "282c34", // 5.92:1
        ansiHex: [
            "3f4451", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf",
            "5c6370", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "ffffff",
        ],
        terminalCard: nil
    )

    static let oneLight = HelmTheme(
        id: "one-light", mode: .light, name: "One Light", pairId: "one-dark",
        chromeBackgroundHex: "fafafa", // `syntax-bg`
        chromeInkHex: "383a42",        // `mono-1`
        chromeLineHex: "d4d4d5",       // `syntax-cursor-line`
        // `hue-2` (`4078f2`) darkened 9% along its own hue line: the canonical
        // value carries a white label at 3.88:1 - convention (2) above.
        accentHex: "3a6ddc",
        foregroundHex: "383a42", backgroundHex: "fafafa",
        cursorHex: "3a6ddc", selectionHex: "3a6ddc",
        selectionTextHex: "fafafa", // 4.57:1
        ansiHex: [
            "383a42", "e45649", "50a14f", "986801", "4078f2", "a626a4", "0184bc", "696c77",
            "a0a1a7", "ca1243", "50a14f", "c18401", "4078f2", "a626a4", "0184bc", "383a42",
        ],
        terminalCard: nil
    )

    // --- Ayu (github.com/ayu-theme/vscode-ayu, built ayu-dark.json / ayu-light.json) ---
    //
    // `ayu-colors` publishes a computed lightness ramp (`$palette.yellow.l4`)
    // rather than literal hex, so the values come out of `vscode-ayu`'s built
    // theme files - the same ramp already evaluated.
    //
    // **Ayu makes the hairline load-bearing**, and more so than any other
    // family here: `base` and `lift` are only 1.03:1 apart upstream, so under
    // the one-step convention a card is separated from the page by
    // `chromeLineHex` alone. That is the same position `gruvbox-light` and
    // both Tokyo Nights are already in, and it is faithful to Ayu - the
    // `1b1f29` / `dfe2e6` lines below are deliberately the strongest divider
    // each half publishes rather than its faintest.
    static let ayuDark = HelmTheme(
        id: "ayu-dark", mode: .dark, name: "Ayu Dark", pairId: "ayu-light",
        chromeBackgroundHex: "0d1017", // `editor.background`
        chromeInkHex: "bfbdb6",        // `editor.foreground`
        chromeLineHex: "1b1f29",       // `editorGroup.border`
        accentHex: "e6b450",           // Ayu's one amber accent
        foregroundHex: "bfbdb6", backgroundHex: "0d1017",
        cursorHex: "e6b450", selectionHex: "e6b450",
        selectionTextHex: "0d1017", // 9.98:1
        ansiHex: [
            "1b1f29", "f06b73", "70bf56", "fdb04c", "4fbfff", "d0a1ff", "93e2c8", "c7c7c7",
            "686868", "f07178", "aad94c", "ffb454", "59c2ff", "d2a6ff", "95e6cb", "ffffff",
        ],
        terminalCard: nil
    )

    static let ayuLight = HelmTheme(
        id: "ayu-light", mode: .light, name: "Ayu Light", pairId: "ayu-dark",
        chromeBackgroundHex: "fcfcfc", // `editor.background`
        chromeInkHex: "5c6166",        // `editor.foreground`
        chromeLineHex: "dfe2e6",       // `editorGroup.border`
        accentHex: "f29718",           // the same amber, light-corrected upstream
        foregroundHex: "5c6166", backgroundHex: "fcfcfc",
        cursorHex: "f29718", selectionHex: "f29718",
        // Ayu Light's amber is a *light* fill, so its label is Ayu's own dark
        // `common.ui` ink rather than the page ground every other light theme
        // here uses - a pale label on this accent measures under 2:1.
        selectionTextHex: "1f2430", // 6.81:1
        ansiHex: [
            "5c6166", "f06b6c", "6cbf43", "e7a100", "21a1e2", "a176cb", "4abc96", "8a9199",
            "8a9199", "f07171", "86b300", "eba400", "22a4e6", "a37acc", "4cbf99", "5c6166",
        ],
        terminalCard: nil
    )

    // --- Night Owl / Light Owl (github.com/sdras/night-owl-vscode-theme) ---
    //
    // The accessibility answer of the six: built for low light and for
    // colour-blind readers, and it measures that way (11.00:1 ink, 11.25:1
    // button label on the dark half).
    static let nightOwl = HelmTheme(
        id: "night-owl", mode: .dark, name: "Night Owl", pairId: "light-owl",
        chromeBackgroundHex: "011627", // `editor.background`
        chromeInkHex: "d6deeb",        // `editor.foreground`
        chromeLineHex: "122d42",       // `editorGroup.border`
        accentHex: "7fdbca",           // Night Owl's signature teal
        foregroundHex: "d6deeb", backgroundHex: "011627",
        cursorHex: "7fdbca", selectionHex: "7fdbca",
        selectionTextHex: "011627", // 11.25:1
        ansiHex: [
            "011627", "ef5350", "22da6e", "c5e478", "82aaff", "c792ea", "21c7a8", "ffffff",
            "575656", "ef5350", "22da6e", "ffeb95", "82aaff", "c792ea", "7fdbca", "ffffff",
        ],
        terminalCard: nil
    )

    static let lightOwl = HelmTheme(
        id: "light-owl", mode: .light, name: "Light Owl", pairId: "night-owl",
        chromeBackgroundHex: "fbfbfb", // `editor.background`
        chromeInkHex: "403f53",        // `editor.foreground`
        chromeLineHex: "d9d9d9",       // `editorGroup.border`
        // Light Owl's own teal (`2aa298`) darkened 21% along its hue line: the
        // canonical value carries a white label at 3.13:1 - convention (2).
        accentHex: "218078",
        foregroundHex: "403f53", backgroundHex: "fbfbfb",
        cursorHex: "218078", selectionHex: "218078",
        selectionTextHex: "ffffff", // 4.75:1
        ansiHex: [
            "403f53", "de3d3b", "08916a", "a37f00", "288ed7", "d6438a", "2aa298", "93a1a1",
            "989fb1", "de3d3b", "08916a", "daaa01", "288ed7", "d6438a", "2aa298", "403f53",
        ],
        terminalCard: nil
    )

    // --- Oxocarbon (github.com/nyoom-engineering/oxocarbon.nvim) ---
    //
    // IBM Carbon's own grey ramp with Carbon's electric accents - the only
    // achromatic chrome on offer here, and the sharpest departure from
    // anything already shipped.
    static let oxocarbonDark = HelmTheme(
        id: "oxocarbon-dark", mode: .dark, name: "Oxocarbon", pairId: "oxocarbon-light",
        chromeBackgroundHex: "161616", // base00, Carbon gray-100
        chromeInkHex: "f2f4f8",        // base05
        chromeLineHex: "393939",       // base02, Carbon gray-80
        accentHex: "33b1ff",           // Carbon blue-40
        foregroundHex: "f2f4f8", backgroundHex: "161616",
        cursorHex: "33b1ff", selectionHex: "33b1ff",
        selectionTextHex: "161616", // 7.65:1
        ansiHex: [
            "262626", "ee5396", "42be65", "ff7eb6", "78a9ff", "be95ff", "3ddbd9", "dde1e6",
            "525252", "ee5396", "42be65", "be95ff", "33b1ff", "82cfff", "08bdba", "ffffff",
        ],
        terminalCard: nil
    )

    static let oxocarbonLight = HelmTheme(
        id: "oxocarbon-light", mode: .light, name: "Oxocarbon Light", pairId: "oxocarbon-dark",
        chromeBackgroundHex: "f4f4f4", // light base00, Carbon gray-10
        chromeInkHex: "161616",        // Carbon gray-100
        chromeLineHex: "e0e0e0",       // Carbon gray-20
        accentHex: "0f62fe",           // Carbon blue-60, the interactive token
        foregroundHex: "161616", backgroundHex: "f4f4f4",
        cursorHex: "0f62fe", selectionHex: "0f62fe",
        selectionTextHex: "ffffff", // 5.00:1
        ansiHex: [
            // oxocarbon.nvim's own light half leaves several ANSI slots on
            // Material hues that are neither Carbon nor legible on gray-10.
            // Those slots take IBM Carbon v11's own token ramp instead, which
            // is the palette oxocarbon is itself derived from.
            "525252", "da1e28", "0e6027", "8e6a00", "0f62fe", "8a3ffc", "005d5d", "525252",
            "6f6f6f", "da1e28", "198038", "b28600", "0f62fe", "a56eff", "007d79", "161616",
        ],
        terminalCard: nil
    )
}

extension HelmTheme {
    /// All 26 palettes: the Daylight family (`daylight` and its Phase 6 dark
    /// companion `dusk` - see `HelmDaylight.swift`), then the two hand-pinned
    /// Helm originals, then the 10 sourced-family themes grouped by family
    /// (dark variant then its light pair).
    ///
    /// Daylight leads the list but is **not** the default theme - Phase 1 of
    /// its migration is tokens only, and flipping the default is a visible
    /// change that belongs with the shell that makes Daylight mean something
    /// (Phase 2). `ThemeManager`'s own default is still `helm-dark`.
    ///
    /// Dusk sits immediately after Daylight because the picker groups by
    /// family (`ThemeMenu` and Settings' Appearance grid both derive from this
    /// array), so a family's two registers read as one pair.
    static let allThemes: [HelmTheme] = [
        daylight, dusk,
        dark, light,
        solarizedDark, solarizedLight,
        catppuccinMocha, catppuccinLatte,
        gruvboxDark, gruvboxLight,
        tokyoNightDark, tokyoNightLight,
        rosePineMain, rosePineDawn,
        nordPolar, nordSnow,
        dracula, alucard,
        oneDark, oneLight,
        ayuDark, ayuLight,
        nightOwl, lightOwl,
        oxocarbonDark, oxocarbonLight,
    ]

    static func theme(id: String) -> HelmTheme? {
        allThemes.first { $0.id == id }
    }

    /// A small rounded two-tone swatch (chrome background + accent) for the
    /// theme-picker menu.
    func swatchImage(size: NSSize = NSSize(width: 24, height: 14)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        let left = NSRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        let right = NSRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        Self.nsColor(chromeBackgroundHex).setFill()
        left.fill()
        Self.nsColor(accentHex).setFill()
        right.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
