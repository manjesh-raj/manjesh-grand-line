// Manjesh Grand Line - native macOS app.
//
// The Daylight token layer - Phase 1 of the 7-phase Daylight UI migration
// (`data/grandline-ui-modernization-review/daylight-ui-design.md`, §8).
//
// Phase 1 is **tokens only**. Nothing in this file is wired into a page: it
// adds the `daylight` palette as a real, selectable 13th `HelmTheme`, the
// per-domain hue mapping, and the primitives Phase 2's shell and Phase 4's
// drill-page restyles will draw with. A captain who selects Daylight today
// gets the app it already has, resolved in the Daylight colours - which is
// exactly what that phase's own description asks for ("nothing visible
// changes yet except the theme becoming selectable").
//
// **Every value below is either lifted verbatim from the design doc's §2.1-§2.3
// tables, or is one of §2.4's six measured contrast corrections, or is a
// minimal darkening of one of those that this file derives and states.** No
// colour here was invented to fill a gap. The measurements are re-run by
// `HelmContrastSelfTest` (`FM_RUN_CONTRAST_TESTS=1`), which sweeps every §2.4
// pair against the codebase's own WCAG formula rather than trusting the table.
//
// Two deliberate deviations from the spec, both recorded rather than silent:
//
// 1. **The dark terminal card (§2.1's `termBg`/`termInk`) is NOT this theme's
//    `backgroundHex`.** In this codebase `backgroundHex` is one token doing two
//    jobs: SwiftTerm's background (`HelmTheme.apply(to:)`) *and* every
//    destination's own page ground (`view.layer.backgroundColor`), and it is
//    one of the two surfaces `HelmContrast`/`mutedInk` score every chrome
//    colour against. Daylight is the first palette that wants those two jobs
//    to disagree - warm paper for the chrome, a deliberately dark card for the
//    terminal. Setting `backgroundHex` to `termBg` would turn every page's
//    ground dark; setting it to `paper` gives a light terminal, which is what
//    `helm-light` already does and what keeps every contrast guarantee in this
//    file meaningful. So `backgroundHex` is `paper`, `termBackgroundHex`/
//    `termInkHex` are recorded here for the phase that owns the Console page
//    (§6.13, Phase 4), and `HelmTheme.apply(to:)` is untouched - it is on the
//    migration's own "must NOT change" list. That phase will need its own
//    contrast-verified ANSI set for a dark card; inventing one here, unused
//    and unverifiable against a real render, would be worse than saying so.
//
// 2. **`ShiftFont.serif` is not re-pointed at the rounded face yet.** §3
//    retires the serif as the page-title voice, but `HelmType.pageTitle`'s
//    voice is theme-independent by design, and re-resolving it per active
//    theme would restyle every existing hero title the moment Daylight is
//    selected - a visible change Phase 1 is explicitly not allowed to make.
//    The retirement happens naturally in Phase 2/4, when `pageTitle(.serif)`'s
//    callers move onto `heroTitle()`/`drillTitle()` (added in this phase).
//
// The dark companion ("Dusk") does not exist - see §2.8. Until it does, the 12
// existing palettes stay selectable and every Daylight component MUST resolve
// its colours through the theme system, never a literal hex, so a captain on
// `helm-dark` still gets a legible app. `HelmDomainHue` below is what makes
// that true for the one genuinely new colour concept Daylight introduces.

import AppKit

// MARK: - The palette

/// Daylight's named tokens, exactly as the design doc's §2.1-§2.4 tables
/// define them.
///
/// A separate namespace from `HelmTheme.daylight` (which is the terminal-and-
/// chrome palette every other theme also fills in) because Daylight has real
/// tokens the 12-theme struct has no field for - `inset`, `faint`, `rowHover`,
/// the seven domain gradient pairs - and Phase 2 onward needs them by name.
/// Anything a *component* consumes should reach it through `HelmDomainHue` or
/// a `HelmTheme` field, not by reading these constants directly, so that a
/// non-Daylight theme still resolves.
enum DaylightPalette {
    // MARK: §2.1 Base tokens

    /// The app ground (window / content background).
    static let paper = "F5F2EA"
    /// Module and card surfaces.
    static let card = "FFFFFF"
    /// Input wells at rest, quiet chip fills, hover-adjacent fills.
    static let inset = "F3F0E7"
    /// 1px borders on cards, wells, bars.
    static let hair = "E4DFD2"
    /// Row separators inside cards - the same value as `inset`, per §2.1.
    static let hairRow = "F3F0E7"
    /// Primary text.
    static let ink = "2A2B33"
    /// Secondary text. **§2.4's correction** - the prototype's `7C7767`
    /// measures 4.48 / 4.00 / 3.93 on card / paper / inset and fails the
    /// 4.5:1 floor on all three; this measures 5.16 / 4.61 / 4.53.
    static let muted = "726D60"
    /// Decorative only: chevrons, leader dots, disabled glyphs. **Never**
    /// running text and never a placeholder - it measures 2.08:1 on paper.
    /// Placeholders use `muted`.
    static let faint = "B0AA97"
    /// Row hover fill inside cards.
    static let rowHover = "FCFAF4"

    // MARK: §2.1 Terminal card - recorded for Phase 4, see this file's header

    /// The dark terminal card inside the light UI. **Not** wired up in Phase 1
    /// - see deviation 1 in this file's header for why, and §6.13 for the
    /// phase that owns it.
    static let termBackground = "23242B"
    /// The terminal card's default ink (SwiftTerm's own palette still governs
    /// individual cells). Same deferral as `termBackground`.
    static let termInk = "E6E4DC"

    // MARK: §2.3 Semantic state colours (state only - never identity)

    static let ok = "189A6E"
    static let warn = "C77E13"
    static let bad = "D64545"

    // MARK: §2.4 Contrast corrections - measured, mandatory

    /// The blue used as **text on `paper`**. The raw domain blue (`3D6BE8`)
    /// measures 4.20 there and 4.70 on card, so it passes on a card and fails
    /// on the page; this passes on both (4.51 / 5.04) and is therefore what
    /// `HelmTheme.daylight.accentHex` carries, since `accentHex` is used as a
    /// label colour in plenty of places that cannot know which surface they
    /// landed on. The raw `3D6BE8` stays the *gradient* value in
    /// `HelmDomainHue.blue`, where it is a fill and legal at full saturation.
    static let linkBlue = "3C67DC"
    /// `ok` as a **label on its own 12% wash** - the raw hue measures 3.11.
    static let okText = "1D7B5E"
    /// `warn` as a **label on its own 14% wash** - the raw hue measures 2.82.
    static let warnText = "93621E"
    /// `bad` as a **label on its own 12% wash** - the raw hue measures 3.72.
    static let badText = "BC4142"

    /// The four domain hues whose raw `h1` cannot carry a **white label** at
    /// 4.5:1 when used as an opaque primary-button fill (measured 3.27-3.85),
    /// with the corrected fill §2.4 specifies. Blue (4.70) and violet (5.09)
    /// pass raw and are absent here; slate is not a primary-button hue.
    ///
    /// Not consumed as one-offs: `HelmButton` already routes a label on a
    /// known fill through `HelmContrast.legible`, which computes the same
    /// correction. These are listed so a render can be checked by eye against
    /// known-good values, and so the self-test can assert the table is real.
    static let primaryButtonFills: [(hue: HelmDomainHue, corrected: String)] = [
        (.green, "158760"),
        (.teal, "0D8292"),
        (.amber, "A66910"),
        (.rose, "C64B73"),
    ]

    // MARK: §2.5 Shadows

    /// Both depth levels are `#2A2B33`-tinted rather than pure black - a black
    /// shadow over warm paper reads grey-green.
    static let shadowInk = ink
}

// MARK: - Domain hues (§2.2, with §2.8's per-theme fallback)

/// The seven per-domain hues, each a gradient pair (`h1` start, `h2` end).
///
/// **This is the one genuinely new colour concept Daylight introduces**, and
/// §2.8's requirement is that it resolve *per theme*: on Daylight it returns
/// the §2.2 table verbatim, and on any of the 12 pre-existing palettes it
/// falls back to that palette's own `HelmTint` semantic slot. That fallback is
/// what makes the migration shippable page by page without a dark rewrite - a
/// Phase 2/4 component can ask for "the Hosts hue" unconditionally and a
/// captain on `gruvbox-light` still gets a legible, in-palette tile.
///
/// The mapping onto `HelmTint` is 1:1 in both directions (seven hues, seven
/// tint cases) and was chosen by role rather than by RGB proximity:
/// `teal` -> `.accent` because the theme's own accent is its primary
/// identity hue (and is literally cyan in `helm-dark`), `rose` -> `.critical`
/// because both are the red family, `slate` -> `.neutral`.
enum HelmDomainHue: String, CaseIterable {
    case blue, teal, green, amber, rose, violet, slate

    /// The §2.2 pair, used only when the active theme is Daylight.
    private var daylightPair: (h1: String, h2: String) {
        switch self {
        case .blue: return ("3D6BE8", "7C9BF2")
        case .teal: return ("0E8FA0", "57BCC9")
        case .green: return ("189A6E", "5CC49E")
        case .amber: return ("C77E13", "E8AE4E")
        case .rose: return ("D9527E", "EC8FAC")
        case .violet: return ("7A56D6", "A98FE8")
        case .slate: return ("8B8677", "B8B2A0")
        }
    }

    /// The `HelmTint` slot this hue borrows on a non-Daylight palette.
    var fallbackTint: HelmTint {
        switch self {
        case .blue: return .info
        case .teal: return .accent
        case .green: return .good
        case .amber: return .warn
        case .rose: return .critical
        case .violet: return .violet
        case .slate: return .neutral
        }
    }

    /// How much white is blended into a fallback theme's own hue to derive the
    /// gradient's lighter end.
    ///
    /// 0.32 is **measured off Daylight's own seven pairs**, not picked: solving
    /// each pair's `h2` as a lighten of its `h1` toward white gives a per-hue
    /// mean of 0.347-0.404 and a per-channel spread of 0.25-0.59, clustering
    /// just under a third. One constant keeps a fallback gradient reading in
    /// the same direction and at the same strength as a real Daylight one.
    static let fallbackLightenFraction: CGFloat = 0.32

    /// This hue's gradient pair in `theme` - the §2.2 values on Daylight, the
    /// theme's own `HelmTint` slot (plus a derived lighter end) anywhere else.
    func pair(in theme: HelmTheme) -> (h1: NSColor, h2: NSColor) {
        if theme.isDaylight {
            let pair = daylightPair
            return (HelmTheme.nsColor(pair.h1), HelmTheme.nsColor(pair.h2))
        }
        let h1 = HelmTheme.nsColor(fallbackTint.hex(in: theme))
        let h2 = h1.blended(withFraction: Self.fallbackLightenFraction, of: .white) ?? h1
        return (h1, h2)
    }

    /// The gradient's darker end on its own - what a solid fill, an accent bar
    /// or a primary button uses when it wants this hue without a gradient.
    func baseColor(in theme: HelmTheme) -> NSColor { pair(in: theme).h1 }

    /// Direction for a ribbon: left to right (`90deg` in the prototype's CSS).
    static let ribbonStart = CGPoint(x: 0, y: 0.5)
    static let ribbonEnd = CGPoint(x: 1, y: 0.5)
    /// Direction for a tile: top-left to bottom-right (`135deg`).
    static let tileStart = CGPoint(x: 0, y: 0)
    static let tileEnd = CGPoint(x: 1, y: 1)
}

extension RailDestination {
    /// Which domain hue this destination owns, per §2.2's "Owns" column and
    /// §4's tile-hue table.
    ///
    /// Read by Phase 2's canvas modules and Phase 4's drill headers. It is
    /// deliberately separate from `flyoutTint`, which is the pre-Daylight
    /// `HelmTint` the Setup flyout's four rows already carry: that property
    /// answers "what tint does this row's `IconTileView` wash", this one
    /// answers "what hue does this *area of the app* own". They will agree once
    /// the flyout is a Daylight surface; until then, changing one must not
    /// silently change the other.
    ///
    /// The four Setup sub-pages all take amber, because §2.2 gives the hue to
    /// "Setup" as one area rather than to each page inside it.
    var domainHue: HelmDomainHue {
        switch self {
        // The hub itself carries the app's own identity hue.
        case .homeCanvas: return .blue
        case .overview: return .blue          // Fleet
        case .console: return .teal
        case .hosts: return .teal
        case .logAnalyzer: return .teal
        case .shift: return .rose             // Tasks
        case .dictation: return .rose
        case .review: return .green           // Merge queue
        case .health: return .green
        case .vault: return .violet
        case .schedules: return .violet
        case .docs: return .blue
        case .updates, .bootstrap, .automation, .githubSync: return .amber  // Setup
        case .settings: return .slate
        case .tools: return .slate
        }
    }
}

// MARK: - The theme

extension HelmTheme {
    /// Is this the Daylight palette?
    ///
    /// The one switch behind every §2.8 fallback in the app. A component asks
    /// this rather than comparing hexes, so the fallback stays in one place
    /// per concept (`HelmDomainHue.pair`, `HelmTheme.mutedInk`,
    /// `HelmCard.elevation`) instead of spreading through view code.
    var isDaylight: Bool { id == "daylight" }

    /// **Daylight** - the captain-approved design language's own palette, and
    /// the 13th theme.
    ///
    /// Field-by-field derivation (§2.1 unless noted):
    /// - `chromeBackgroundHex` = `card`, `backgroundHex` = `paper`. Cards are
    ///   white and float on warm paper; see this file's header for why
    ///   `backgroundHex` is paper rather than §2.1's `termBg`.
    /// - `chromeInkHex` = `ink`, `chromeLineHex` = `hair`.
    /// - `accentHex` = §2.4's corrected `linkBlue`, not the raw domain blue -
    ///   `accentHex` is used as a *label* colour in this app, and the raw blue
    ///   fails 4.5:1 on paper. Gradients still use the raw value via
    ///   `HelmDomainHue.blue`.
    /// - `selectionHex` = the accent with a white `selectionTextHex` (5.04:1).
    ///
    /// The 16 ANSI slots are built from the tokens above rather than invented:
    /// each normal slot is that hue's **§2.4 text-corrected** variant, because
    /// an ANSI slot's job here is precisely "this hue used as text on the
    /// theme's own background". Only cyan needed a value §2.4 does not list -
    /// derived as the smallest darkening of the teal `h1` that clears 4.5:1 on
    /// paper (`0C7A88`, 4.52) - and the two greys, derived the same way.
    /// Bright slots are 15% black blended into their normal sibling: on a light
    /// background "brighter" has to mean *deeper* to stay legible, which is
    /// the same call `helm-light` already makes (its bright red `b3000d` is
    /// darker than its red `c22826`).
    ///
    /// Every one of the 16 measures >= 4.5:1 against `paper`; the two greys and
    /// the black/bright-white pair inherit `helm-light`'s accepted limitation
    /// that on a light background slot 0 ("black") and slot 15 ("bright
    /// white") both have to be near-ink, so they are the same value.
    static let daylight = HelmTheme(
        id: "daylight",
        mode: .light,
        name: "Daylight",
        // No Dusk yet (§2.8), so the quick dark/light flip (⌘⌥T) lands on the
        // app's own original dark palette rather than nowhere. Deliberately
        // one-way: `helm-dark` keeps pairing back to `helm-light`, because
        // re-pointing it at Daylight would change what ⌘⌥T does for a captain
        // who has never selected Daylight at all. Revisit when Dusk lands.
        pairId: "helm-dark",
        chromeBackgroundHex: DaylightPalette.card,
        chromeInkHex: DaylightPalette.ink,
        chromeLineHex: DaylightPalette.hair,
        accentHex: DaylightPalette.linkBlue,
        foregroundHex: DaylightPalette.ink,
        backgroundHex: DaylightPalette.paper,
        cursorHex: DaylightPalette.linkBlue,
        selectionHex: DaylightPalette.linkBlue,
        selectionTextHex: DaylightPalette.card,
        ansiHex: [
            // black         red                        green
            DaylightPalette.ink, DaylightPalette.badText, DaylightPalette.okText,
            // yellow                  blue                        magenta
            DaylightPalette.warnText, DaylightPalette.linkBlue, "7A56D6",
            // cyan (derived, 4.52 on paper)
            "0C7A88",
            // white - the bold-"white" slot `helm-light`'s own comment warns
            // about: a pale grey here is invisible, so this is a deep warm
            // grey (6.95 on paper).
            "56524A",
            // bright black - the dim-but-still-legible slot: the app's own
            // muted token (4.61 on paper).
            DaylightPalette.muted,
            // bright red/green/yellow/blue/magenta/cyan - 15% black into each
            // normal sibling (5.77-6.06 on paper).
            "A03738", "196950", "7D5319", "3358BB", "6849B6", "0A6874",
            // bright white
            DaylightPalette.ink,
        ]
    )
}
