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
// **Phase 6 added the dark companion, "Dusk"** (§2.8's stated debt, and the
// captain's own decision to derive it now rather than defer). It is not a
// second design - it is this same language in a dark register: `isDaylight`
// covers both, every non-colour recipe is shared verbatim, and only the
// surface/ink token set moves (`DaylightTokens.light` vs `.dusk`, resolved per
// theme by `HelmTheme.daylightTokens`). Its values were measured with §2.4's
// own methodology rather than inverted - two of the three correction
// directions actually *reverse* in the dark register, which is exactly why an
// inversion would have shipped illegible chips. §2.8's fallback survives
// unchanged and still matters: the 12 pre-existing palettes stay selectable,
// so every Daylight component MUST resolve its colours through the theme
// system, never a literal hex. `HelmDomainHue` below is what makes that true
// for the one genuinely new colour concept Daylight introduces - and note that
// it needs no Dusk branch at all, because a domain hue is identity and does
// not change register.

import AppKit

// MARK: - The token set (Daylight + Dusk)

/// One complete set of Daylight's named surface/ink tokens.
///
/// **Why this is a struct with two instances rather than one namespace of
/// constants (Phase 6).** Phases 1-5 read the light values directly, because
/// Daylight was the only theme speaking this design language. Dusk is the
/// same language in a dark register - every recipe (radii, spacing, elevation,
/// gradient direction, chip shape) is identical and only the surface/ink
/// values move - so the honest shape is one token *set* resolved per theme
/// (`HelmTheme.daylightTokens`) rather than a second parallel set of `if`
/// branches in every component. `theme.isDaylight` therefore means "is a
/// Daylight-family theme" (Daylight or Dusk) and every existing recipe branch
/// keeps working unchanged for both.
///
/// The semantic hues (`ok`/`warn`/`bad`) and the seven domain gradient pairs
/// (§2.2) are **deliberately not in here**: they are identity, not surface,
/// and Dusk keeps them byte for byte so a Vault tile is the same violet in
/// both registers. What does move is every *text* form of those hues, because
/// a hue legible as a label on warm paper is not legible on a dark ground and
/// vice versa - see `linkBlue`/`okText`/`warnText`/`badText`.
struct DaylightTokens {
    /// The app ground (window / content background).
    let paper: String
    /// Module and card surfaces.
    let card: String
    /// Input wells at rest, quiet chip fills, hover-adjacent fills.
    let inset: String
    /// 1px borders on cards, wells, bars.
    let hair: String
    /// Row separators inside cards.
    let hairRow: String
    /// Primary text.
    let ink: String
    /// Secondary text - contrast-verified against `card`, `paper`, `inset`
    /// *and* `rowHover`, the four surfaces running text actually lands on.
    let muted: String
    /// Decorative only: chevrons, leader dots, disabled glyphs. Deliberately
    /// **below** the text floor in both registers - a value that passed it
    /// would just be a second `muted`.
    let faint: String
    /// Row hover fill inside cards.
    let rowHover: String
    /// The terminal card's own fill (Log Analyzer's raw pane, §6.13's card).
    let termBackground: String
    /// The terminal card's default ink.
    let termInk: String
    /// The blue used as **text** on this register's own surfaces.
    let linkBlue: String
    /// `ok`/`warn`/`bad` as a **label on their own wash** over `card`.
    let okText: String
    let warnText: String
    let badText: String
    /// What a card shadow is tinted with. Never pure black on Daylight (a
    /// black shadow over warm paper reads grey-green); effectively black on
    /// Dusk, where there is no warmth beneath it to muddy.
    let shadowInk: String

    /// **Daylight** - §2.1-§2.4's tables verbatim, including the six measured
    /// corrections. Unchanged by Phase 6.
    static let light = DaylightTokens(
        paper: "F5F2EA",
        card: "FFFFFF",
        inset: "F3F0E7",
        hair: "E4DFD2",
        hairRow: "F3F0E7",
        ink: "2A2B33",
        muted: "726D60",
        faint: "B0AA97",
        rowHover: "FCFAF4",
        termBackground: "23242B",
        termInk: "E6E4DC",
        linkBlue: "3C67DC",
        okText: "1D7B5E",
        warnText: "93621E",
        badText: "BC4142",
        shadowInk: "2A2B33"
    )

    /// **Dusk** - Daylight's dark companion, derived in Phase 6 and measured
    /// with §2.4's own methodology rather than inverted.
    ///
    /// The derivation, value by value, so none of it reads as a guess:
    ///
    /// - **`card` is §2.1's own `termBg` (`23242B`).** The spec already named
    ///   the one dark surface it wanted inside the light UI; in Dusk that
    ///   value *is* the card, which is why the terminal stops needing to be a
    ///   different colour from everything around it in this register.
    /// - **`paper` (`191A1F`) sits one step below the card**, so the same
    ///   "cards float on a ground" reading survives (1.12:1 apart - the same
    ///   order of separation as Daylight's own `FFFFFF`/`F5F2EA`, which is
    ///   1.08:1, and like Daylight the 1px `hair` border is what actually
    ///   carries the boundary).
    /// - **`inset` (`1E1F25`) is darker than the card**, matching Daylight's
    ///   direction (a well recedes) rather than the more common dark-mode
    ///   habit of lifting it.
    /// - **`hair` (`383A45`) reads at 1.37:1 against the card**, against
    ///   Daylight's own `E4DFD2`-on-white at 1.33:1. A dark register needs at
    ///   least as firm an edge as a light one - this value was raised from a
    ///   first pass at `343640` (1.29:1) because the self-test's
    ///   compare-against-Daylight assertion caught it as fainter, which is
    ///   exactly the class of "looks fine, measures worse" regression that
    ///   check exists for.
    /// - **`ink` (`E8E6DE`) is §2.1's `termInk` family**: 12.37:1 on card,
    ///   13.90:1 on paper.
    /// - **`muted` (`979283`) is measured, not chosen**: 4.97 card / 5.59
    ///   paper / 5.29 inset / **4.60 rowHover**, deliberately profiled to
    ///   mirror Daylight's own muted (5.16 / 4.61 / 4.53) rather than to sit
    ///   comfortably above the floor - a muted that measures 8:1 is not muted.
    ///   Daylight's own `726D60` measures **3.00** on this card, which is why
    ///   this token had to move at all.
    /// - **`faint` (`6B675C`) measures 2.74-3.08** and stays decorative, the
    ///   same contract as Daylight's `B0AA97` (2.08 on paper).
    /// - **`linkBlue` (`6A8DED`)**: the raw domain blue measures 3.29 on this
    ///   card and Daylight's corrected `3C67DC` measures 3.07 - both fail - so
    ///   this is the smallest lightening of the raw hue that clears 4.5 on all
    ///   four surfaces (4.89 / 5.50 / 5.20 / 4.53). The *gradient* still uses
    ///   the raw `3D6BE8` (§2.2 is identity and does not move).
    /// - **`okText` / `warnText` / `badText` (`38A882` / `CD8D2E` /
    ///   `E07272`)**: each raw hue on its own wash over this card measures
    ///   3.74 / 3.89 / 3.17, and each of these is the smallest lightening that
    ///   clears 4.5 on that same wash (all three land at 4.51). Note the
    ///   direction reverses from §2.4, where the corrections darken - which is
    ///   exactly why a value-inversion of Daylight would not have worked.
    /// - **`shadowInk` (`0B0C0F`)**: near-black. Daylight tints its shadow
    ///   with `ink` because warm paper turns pure black grey-green; on a dark
    ///   ground there is nothing to muddy, and a tinted shadow would only lift
    ///   the card's surround.
    static let dusk = DaylightTokens(
        paper: "191A1F",
        card: "23242B",
        inset: "1E1F25",
        hair: "383A45",
        hairRow: "2A2B33",
        ink: "E8E6DE",
        muted: "979283",
        faint: "6B675C",
        rowHover: "282A32",
        termBackground: "131418",
        termInk: "E6E4DC",
        linkBlue: "6A8DED",
        okText: "38A882",
        warnText: "CD8D2E",
        badText: "E07272",
        shadowInk: "0B0C0F"
    )
}

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
    static let paper = DaylightTokens.light.paper
    /// Module and card surfaces.
    static let card = DaylightTokens.light.card
    /// Input wells at rest, quiet chip fills, hover-adjacent fills.
    static let inset = DaylightTokens.light.inset
    /// 1px borders on cards, wells, bars.
    static let hair = DaylightTokens.light.hair
    /// Row separators inside cards - the same value as `inset`, per §2.1.
    static let hairRow = DaylightTokens.light.hairRow
    /// Primary text.
    static let ink = DaylightTokens.light.ink
    /// Secondary text. **§2.4's correction** - the prototype's `7C7767`
    /// measures 4.48 / 4.00 / 3.93 on card / paper / inset and fails the
    /// 4.5:1 floor on all three; this measures 5.16 / 4.61 / 4.53.
    static let muted = DaylightTokens.light.muted
    /// Decorative only: chevrons, leader dots, disabled glyphs. **Never**
    /// running text and never a placeholder - it measures 2.08:1 on paper.
    /// Placeholders use `muted`.
    static let faint = DaylightTokens.light.faint
    /// Row hover fill inside cards.
    static let rowHover = DaylightTokens.light.rowHover

    // MARK: §2.1 Terminal card - recorded for Phase 4, see this file's header

    /// The dark terminal card inside the light UI. **Not** wired up in Phase 1
    /// - see deviation 1 in this file's header for why, and §6.13 for the
    /// phase that owns it.
    static let termBackground = DaylightTokens.light.termBackground
    /// The terminal card's default ink (SwiftTerm's own palette still governs
    /// individual cells). Same deferral as `termBackground`.
    static let termInk = DaylightTokens.light.termInk

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
    static let linkBlue = DaylightTokens.light.linkBlue
    /// `ok` as a **label on its own 12% wash** - the raw hue measures 3.11.
    static let okText = DaylightTokens.light.okText
    /// `warn` as a **label on its own 14% wash** - the raw hue measures 2.82.
    static let warnText = DaylightTokens.light.warnText
    /// `bad` as a **label on its own 12% wash** - the raw hue measures 3.72.
    static let badText = DaylightTokens.light.badText

    /// The four domain hues whose raw `h1` cannot carry a **white label** at
    /// 4.5:1 when used as an opaque primary-button fill (measured 3.27-3.85),
    /// with the corrected fill §2.4 specifies. Blue (4.70) and violet (5.09)
    /// pass raw and are absent here; slate is not a primary-button hue.
    ///
    /// Not consumed as one-offs: `HelmButton` already routes a label on a
    /// known fill through `HelmContrast.legible`, which computes the same
    /// correction. These are listed so a render can be checked by eye against
    /// known-good values, and so the self-test can assert the table is real.
    /// §2.4's correction, resolved for any hue rather than only the four the
    /// table lists.
    ///
    /// **Why the table alone is not the implementation, and why
    /// `HelmContrast.legible` cannot do this job.** The obvious form of this -
    /// keep the raw hue as the fill and correct the *label* - is a documented
    /// no-op here: `legible` picks its blend endpoint from the surface's
    /// luminance, so `legible(.white, over: <mid-luminance hue>)` returns white
    /// unchanged (AGENTS.md records this as a real bug found in Phase 1). §2.4
    /// is therefore explicit that the **fill** darkens, not the label.
    ///
    /// So: the table's hand-picked value when there is one, else the raw hue
    /// if white already clears the icon-and-text floor on it, else the
    /// smallest darkening that does clear. That last branch is what covers
    /// `slate` - §2.4 says slate "is not a primary-button hue", but a
    /// component cannot refuse a hue a caller hands it, and rendering an
    /// illegible button is worse than rendering a slightly darker one.
    static func primaryButtonFill(for hue: HelmDomainHue, theme: HelmTheme) -> NSColor {
        if let corrected = primaryButtonFills.first(where: { $0.hue == hue })?.corrected {
            return HelmTheme.nsColor(corrected)
        }
        return darkenedForWhiteLabel(hue.baseColor(in: theme))
    }

    /// The smallest darkening of `base` that carries a **white label** at
    /// 4.5:1, or `base` itself when it already does.
    ///
    /// Bisection rather than a fixed step: contrast against white is monotonic
    /// in "how far toward black", so the smallest fraction that clears the
    /// floor is findable in a handful of iterations and the result is the
    /// least visible change to the approved hue.
    static func darkenedForWhiteLabel(_ base: NSColor) -> NSColor {
        if HelmContrast.ratio(.white, base) >= HelmContrast.textTarget { return base }
        var low: CGFloat = 0
        var high: CGFloat = 1
        var best = NSColor.black
        for _ in 0..<12 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: .black) ?? base
            if HelmContrast.ratio(.white, candidate) >= HelmContrast.textTarget {
                best = candidate
                high = mid
            } else {
                low = mid
            }
        }
        return best
    }

    /// §6.10's "primary Save (domain gradient capsule)" - the hue's pair with
    /// **both stops** corrected so a white label clears 4.5:1 anywhere on it.
    ///
    /// This is the one place a Daylight gradient is corrected rather than used
    /// raw, and the reason is that a button's label is the *sole* carrier of
    /// its meaning. §2.4's own tile caveat (recorded in AGENTS.md) is that the
    /// seven raw pairs only clear the 3:1 icon floor against `h1`, and against
    /// the 135° midpoint they measure 2.53-3.68 - acceptable for a
    /// `HelmGradientTile`, whose glyph always sits beside a text label saying
    /// the same thing, and not acceptable for a Save button whose word *is*
    /// the affordance. So `h1` is `primaryButtonFill` (already at or above the
    /// floor) and `h2` is the raw lighter stop darkened by the same bisection
    /// until it clears too. A real gradient in the approved direction, every
    /// stop of which is legible - rather than either a flat fill (dropping the
    /// design) or a raw pair (shipping a 2.5:1 label).
    static func primaryButtonGradient(for hue: HelmDomainHue,
                                      theme: HelmTheme) -> (h1: NSColor, h2: NSColor) {
        (primaryButtonFill(for: hue, theme: theme),
         darkenedForWhiteLabel(hue.pair(in: theme).h2))
    }

    static let primaryButtonFills: [(hue: HelmDomainHue, corrected: String)] = [
        (.green, "158760"),
        (.teal, "0D8292"),
        (.amber, "A66910"),
        (.rose, "C64B73"),
    ]

    // MARK: §2.5 Shadows

    /// Both depth levels are `#2A2B33`-tinted rather than pure black - a black
    /// shadow over warm paper reads grey-green.
    static let shadowInk = DaylightTokens.light.shadowInk
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

    #if FM_SELFTESTS
    /// This hue's §2.2 `h1` verbatim, independent of the active theme - so a
    /// self-test can measure the *raw* table value against a surface without
    /// having to construct the Daylight theme just to resolve it.
    var daylightH1ForTests: String { daylightPair.h1 }
    #endif

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

    /// The hue that borrows `tint` - the exact inverse of `fallbackTint`.
    ///
    /// Safe to write as a total function because that mapping is 1:1 in both
    /// directions (seven hues, seven `HelmTint` cases, mapped by role - see
    /// `fallbackTint`'s own note). Phase 4 slice 2 needs it so a component
    /// carrying a *semantic* `HelmTint` (`HelmAccentRow.Content.tint`) can
    /// paint a Daylight gradient tile without every call site inventing its
    /// own mapping.
    init(tint: HelmTint) {
        switch tint {
        case .info: self = .blue
        case .accent: self = .teal
        case .good: self = .green
        case .warn: self = .amber
        case .critical: self = .rose
        case .violet: self = .violet
        case .neutral: self = .slate
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
        // `fm/grandline-docs-split-runbooks-postmortems`: the same two hues
        // the runbook/postmortem plate cards already used before the split
        // (`HelmDomainHue(tint:)` maps `.info` -> `.blue`, `.warn` -> `.amber`
        // - the exact `HelmTint` each `DocGridItem` carried), so a card and
        // the destination it opens can never disagree about a hue.
        case .runbooks: return .blue
        case .postmortems: return .amber
        case .updates, .bootstrap, .automation, .githubSync: return .amber  // Setup
        case .settings: return .slate
        case .tools: return .slate
        }
    }
}

// MARK: - The theme

extension HelmTheme {
    /// Is this a **Daylight-family** palette - Daylight or its dark companion
    /// Dusk?
    ///
    /// The one switch behind every §2.8 fallback in the app. A component asks
    /// this rather than comparing hexes, so the fallback stays in one place
    /// per concept (`HelmDomainHue.pair`, `HelmTheme.mutedInk`,
    /// `HelmCard.elevation`) instead of spreading through view code.
    ///
    /// **Phase 6 widened this from `id == "daylight"` to cover Dusk, and that
    /// is deliberately the entire mechanism by which Dusk gets the design
    /// language.** Every one of this property's ~90 call sites is a *recipe*
    /// branch - a radius, a border weight, a chip shape, which of two badge
    /// views is visible, whether a gradient is drawn - and not one of them is
    /// a claim that the surface underneath is light. The surface/ink values
    /// they pair with all resolve through `daylightTokens`, which is what
    /// moves. A `isDaylightLight`-style split would have meant auditing all
    /// ~90 to decide which half each belonged in; there is no such split,
    /// because "is this the Daylight design language" is one question.
    var isDaylight: Bool { id == "daylight" || id == "dusk" }

    /// Is this specifically the dark register?
    ///
    /// Exists for the handful of places that genuinely need the *register*
    /// rather than the language (nothing in the shipped views today - the
    /// self-tests use it to name which set they measured). Prefer
    /// `daylightTokens` over branching on this: a component that has to ask
    /// which register it is in usually wants a token that should have been
    /// added to `DaylightTokens` instead.
    var isDusk: Bool { id == "dusk" }

    /// This theme's Daylight token set - Dusk's in the dark register,
    /// Daylight's otherwise.
    ///
    /// Safe to call on any of the 13 themes and returns the light set for the
    /// 12 non-Daylight ones, which is harmless because every caller is already
    /// inside an `isDaylight` branch (the tokens have no meaning outside it -
    /// a `gruvbox-light` card resolves through `HelmTheme`'s own fields, not
    /// through here).
    var daylightTokens: DaylightTokens { isDusk ? .dusk : .light }

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
        // Phase 6: Dusk exists, so ⌘⌥T finally flips within this family the
        // way it does for every other pair - and it is a *mutual* pair, unlike
        // the interim `helm-dark` pointer this replaced. `helm-dark` still
        // pairs back to `helm-light`, untouched: re-pointing it at Dusk would
        // change what ⌘⌥T does for a captain who has never selected either
        // Daylight theme.
        pairId: "dusk",
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

    /// **Dusk** - Daylight's dark companion (Phase 6), and the 14th theme.
    ///
    /// Same design language, dark register. Every non-colour recipe is shared
    /// verbatim through `HelmTheme.isDaylight`; every surface and ink value
    /// comes from `DaylightTokens.dusk`, whose own doc comment carries the
    /// per-value derivation and measured ratios. The seven domain hues (§2.2)
    /// and the three semantic hues (§2.3) are **identical to Daylight** - they
    /// are identity, and a Vault tile has to be the same violet in both
    /// registers - so `HelmDomainHue.pair` needs no dark branch at all.
    ///
    /// Field-by-field:
    /// - `chromeBackgroundHex` = `card`, `backgroundHex` = `paper`, exactly the
    ///   same two jobs those fields do on Daylight. Note that in this register
    ///   the terminal genuinely wants a dark background, so unlike Daylight
    ///   there is no tension between "page ground" and "terminal background" -
    ///   this is the register where that deviation stops costing anything.
    /// - `accentHex` = the register's own `linkBlue` (`6A8DED`), for the same
    ///   reason Daylight's is the corrected one and not the raw domain blue:
    ///   `accentHex` is used as a *label* colour in plenty of places that
    ///   cannot know which surface they landed on. The raw `3D6BE8` measures
    ///   3.29 on this card; this measures 4.89 / 5.50 / 5.20 / 4.53 across
    ///   card / paper / inset / rowHover.
    /// - `selectionTextHex` = `12131A`, a near-ink dark on the accent fill
    ///   (5.86:1) - the mirror of Daylight's white-on-accent.
    ///
    /// The 16 ANSI slots are built the same way Daylight's are - each normal
    /// slot is that hue's **text-corrected** variant for this register, since
    /// an ANSI slot's job is precisely "this hue used as text on the theme's
    /// own background". Red/green/yellow/blue/magenta reuse the four semantic
    /// text corrections plus `linkBlue` and a lightened violet; cyan is the
    /// teal hue lightened by the same rule (`2E9EAD`). Bright slots are 15%
    /// **white** into their normal sibling - on a dark background "brighter"
    /// has to mean *lighter*, the exact mirror of the call Daylight makes when
    /// it blends 15% black.
    ///
    /// Slots 1-15 all measure >= 4.5:1 against `paper` (worst is blue/magenta
    /// at 5.47). Slot 0 ("black", `2A2B33`) measures 1.23:1 and is **exempt by
    /// nature**, exactly as it is in `helm-dark` (`292e34`, 1.3:1) and every
    /// other dark palette: a terminal's black slot cannot be legible against a
    /// dark background, and lightening it until it were would stop it being
    /// black. `HelmContrastSelfTest` asserts 1-15 and states that exemption
    /// rather than skipping the slot silently.
    static let dusk = HelmTheme(
        id: "dusk",
        mode: .dark,
        name: "Dusk",
        pairId: "daylight",
        chromeBackgroundHex: DaylightTokens.dusk.card,
        chromeInkHex: DaylightTokens.dusk.ink,
        chromeLineHex: DaylightTokens.dusk.hair,
        accentHex: DaylightTokens.dusk.linkBlue,
        foregroundHex: DaylightTokens.dusk.ink,
        backgroundHex: DaylightTokens.dusk.paper,
        cursorHex: DaylightTokens.dusk.linkBlue,
        selectionHex: DaylightTokens.dusk.linkBlue,
        selectionTextHex: "12131A",
        ansiHex: [
            // black (exempt, see above)  red                        green
            DaylightTokens.dusk.hairRow, DaylightTokens.dusk.badText, DaylightTokens.dusk.okText,
            // yellow                        blue                          magenta
            DaylightTokens.dusk.warnText, DaylightTokens.dusk.linkBlue, "9C81E0",
            // cyan (teal lightened by the same rule, 5.47 on paper)
            "2E9EAD",
            // white - a light warm grey (10.07 on paper), the mirror of
            // Daylight's deep warm grey in this slot.
            "C9C5B9",
            // bright black - the dim-but-still-legible slot: this register's
            // own muted token (5.59 on paper).
            DaylightTokens.dusk.muted,
            // bright red/green/yellow/blue/magenta/cyan - 15% white into each
            // normal sibling (6.61-7.30 on paper).
            "E58787", "56B595", "D59E4D", "809EF0", "AB94E5", "4DADB9",
            // bright white
            DaylightTokens.dusk.ink,
        ]
    )
}
