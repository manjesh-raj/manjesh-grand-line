// Grand Line - native macOS app.
//
// The app's own themes: seven families, each with a light and a dark
// register, and nothing else.
//
// `fm/grandline-theme-split-app-terminal`. Until this existed the app had one
// theme setting and it was a terminal colour scheme: picking Catppuccin Mocha
// painted the terminal *and* the sidebar, the cards, the buttons and every
// status chip in Catppuccin. The captain chose to split the two (option C of
// the scout report, "linked by default, with an independent terminal
// override") and approved a prototype whose app table and companion map are
// reproduced here verbatim. **Every hex in `AppThemeRegister.all` is the
// prototype's value. None of them was invented or retuned here**, and a
// self-test (`ThemeSplitSelfTest.checkTheRegistersAreThePrototypes`) fails the
// run if one drifts.
//
// What an app theme is, in this codebase's own vocabulary:
//
//   - It is still a `HelmTheme`, because ~600 call sites read
//     `ThemeManager.shared.theme` for chrome, ground, cards, accent and
//     `HelmTint`, and every one of them keeps working unchanged.
//   - It speaks the Daylight design language (`isDaylight`), with its own
//     `DaylightTokens`. Daylight and Dusk already did; the other twelve
//     registers would otherwise have rendered with the flat, border-only
//     recipes the K1 audit called the legacy half of the app.
//   - Its `ansiHex` is **not a terminal palette**. No terminal is ever painted
//     from an app theme (see `TerminalColors.swift`). Slots 1-5 are the app's
//     status vocabulary - `HelmTint` reads critical, good, warn, info and
//     violet from them - and the rest are filler from the same register's
//     Daylight-family set, so a stray reader still gets a legible colour.
//   - It names a **companion** terminal scheme, which is what the terminal
//     paints in while Settings > Terminal > Terminal colours is "Match app
//     theme". The 26 terminal schemes stay in `HelmTheme.allThemes`.

import AppKit

/// What makes a `HelmTheme` one of the app's own themes rather than a
/// terminal scheme.
struct AppThemeInfo {
    let family: AppThemeFamily
    /// The prototype's `side`: the fill behind a nav column.
    let sideHex: String
    /// The terminal scheme this register uses under "Match app theme".
    let companionSchemeID: String
}

/// The seven families the Appearance page offers, in the prototype's order.
enum AppThemeFamily: String, CaseIterable {
    case daylight, graphite, paper, harbor, grove, ember, highContrast = "high-contrast"

    var title: String {
        switch self {
        case .daylight: return "Daylight"
        case .graphite: return "Graphite"
        case .paper: return "Paper"
        case .harbor: return "Harbor"
        case .grove: return "Grove"
        case .ember: return "Ember"
        case .highContrast: return "High Contrast"
        }
    }

    var lightID: String {
        switch self {
        case .daylight: return "daylight"
        case .graphite: return "graphite-light"
        case .paper: return "paper"
        case .harbor: return "harbor"
        case .grove: return "grove"
        case .ember: return "ember"
        case .highContrast: return "contrast-light"
        }
    }

    var darkID: String {
        switch self {
        case .daylight: return "dusk"
        case .graphite: return "graphite-dark"
        case .paper: return "ink"
        case .harbor: return "night-watch"
        case .grove: return "moss"
        case .ember: return "cinder"
        case .highContrast: return "contrast-dark"
        }
    }

    /// This family's register for `mode`.
    func register(_ mode: HelmTheme.Mode) -> HelmTheme {
        // Every id above is in `HelmTheme.appThemes`; the suite asserts it.
        HelmTheme.appTheme(id: mode == .light ? lightID : darkID) ?? .dusk
    }
}

/// One register of the prototype's `APP` table, verbatim.
struct AppThemeRegister {
    let id: String
    let family: AppThemeFamily
    let name: String
    let mode: HelmTheme.Mode
    let ground: String
    let side: String
    let card: String
    let hair: String
    let ink: String
    let muted: String
    let accent: String
    let ok: String
    let warn: String
    let bad: String
    let info: String
    let pair: String
    let onAccent: String
    /// The prototype's `COMPANION` entry for this register.
    let companion: String

    /// The prototype's `APP` and `COMPANION` tables. Daylight and Dusk are
    /// listed for the side value and the companion; their surfaces, ink and
    /// status colours already equal these values (`DaylightTokens`), so they
    /// keep the `HelmTheme`s they always had.
    static let all: [AppThemeRegister] = [
        .init(id: "daylight", family: .daylight, name: "Daylight", mode: .light,
              ground: "F5F2EA", side: "FAF8F3", card: "FFFFFF", hair: "E4DFD2", ink: "2A2B33", muted: "726D60",
              accent: "3C67DC", ok: "1D7B5E", warn: "93621E", bad: "BC4142", info: "3C67DC",
              pair: "dusk", onAccent: "FFFFFF", companion: "daylight"),
        .init(id: "dusk", family: .daylight, name: "Dusk", mode: .dark,
              ground: "191A1F", side: "1E1F25", card: "23242B", hair: "383A45", ink: "E8E6DE", muted: "979283",
              accent: "6A8DED", ok: "38A882", warn: "CD8D2E", bad: "E07272", info: "6A8DED",
              pair: "daylight", onAccent: "111111", companion: "dusk"),
        .init(id: "graphite-light", family: .graphite, name: "Graphite", mode: .light,
              ground: "F5F5F7", side: "ECECEE", card: "FFFFFF", hair: "E1E1E5", ink: "1D1D1F", muted: "66666B",
              accent: "0A63D1", ok: "1F7A3D", warn: "9A5B00", bad: "C4302B", info: "0A63D1",
              pair: "graphite-dark", onAccent: "FFFFFF", companion: "one-light"),
        .init(id: "graphite-dark", family: .graphite, name: "Graphite Dark", mode: .dark,
              ground: "1C1C1E", side: "242426", card: "2C2C2E", hair: "3A3A3D", ink: "F2F2F7", muted: "A1A1A8",
              accent: "4C9BFF", ok: "4CC777", warn: "F0B23E", bad: "FF6B61", info: "4C9BFF",
              pair: "graphite-light", onAccent: "111111", companion: "one-dark"),
        .init(id: "paper", family: .paper, name: "Paper", mode: .light,
              ground: "FFFFFF", side: "F7F7F5", card: "FFFFFF", hair: "E9E9E6", ink: "37352F", muted: "73716B",
              accent: "1F6FC5", ok: "2B7A4B", warn: "94621A", bad: "C0392F", info: "1F6FC5",
              pair: "ink", onAccent: "FFFFFF", companion: "catppuccin-latte"),
        .init(id: "ink", family: .paper, name: "Ink", mode: .dark,
              ground: "191919", side: "202020", card: "252525", hair: "333333", ink: "E9E9E7", muted: "9E9E9B",
              accent: "5AA2DA", ok: "5BB98A", warn: "D9A548", bad: "E8776C", info: "5AA2DA",
              pair: "paper", onAccent: "111111", companion: "tokyo-night-dark"),
        .init(id: "harbor", family: .harbor, name: "Harbor", mode: .light,
              ground: "F2F5F8", side: "E7EDF3", card: "FFFFFF", hair: "D8E0E9", ink: "14212E", muted: "566778",
              accent: "0B6A87", ok: "1E7A55", warn: "8F5E12", bad: "B83A3A", info: "2462B8",
              pair: "night-watch", onAccent: "FFFFFF", companion: "light-owl"),
        .init(id: "night-watch", family: .harbor, name: "Night Watch", mode: .dark,
              ground: "0E1620", side: "121C28", card: "172331", hair: "263547", ink: "E4ECF4", muted: "8FA2B5",
              accent: "4FB6D3", ok: "4CC291", warn: "E9B04F", bad: "F07A72", info: "7AA7F0",
              pair: "harbor", onAccent: "111111", companion: "night-owl"),
        .init(id: "grove", family: .grove, name: "Grove", mode: .light,
              ground: "F4F6F1", side: "EAEFE5", card: "FFFFFF", hair: "DAE2D2", ink: "1E2A1F", muted: "5A6857",
              accent: "2C7149", ok: "2C7149", warn: "8E5F17", bad: "B73E37", info: "2F64A8",
              pair: "moss", onAccent: "FFFFFF", companion: "gruvbox-light"),
        .init(id: "moss", family: .grove, name: "Moss", mode: .dark,
              ground: "141914", side: "1A201A", card: "202820", hair: "303B30", ink: "E2EADE", muted: "95A390",
              accent: "6CC08C", ok: "6CC08C", warn: "DDB053", bad: "EC7B70", info: "7FA9E8",
              pair: "grove", onAccent: "111111", companion: "gruvbox-dark"),
        .init(id: "ember", family: .ember, name: "Ember", mode: .light,
              ground: "FBF6F2", side: "F4EBE4", card: "FFFFFF", hair: "EADCD1", ink: "2B1F1A", muted: "776358",
              accent: "B83E0B", ok: "2B7A4B", warn: "8F5C10", bad: "B8322F", info: "2E63B5",
              pair: "cinder", onAccent: "FFFFFF", companion: "rose-pine-dawn"),
        .init(id: "cinder", family: .ember, name: "Cinder", mode: .dark,
              ground: "1A1513", side: "211A17", card: "2A211D", hair: "3C302A", ink: "F2E8E2", muted: "AD9B90",
              accent: "F28C5E", ok: "5DBE8A", warn: "E8B451", bad: "F27A6E", info: "80A8F0",
              pair: "ember", onAccent: "111111", companion: "rose-pine-main"),
        .init(id: "contrast-light", family: .highContrast, name: "High Contrast", mode: .light,
              ground: "FFFFFF", side: "F0F0F0", card: "FFFFFF", hair: "767676", ink: "000000", muted: "333333",
              accent: "0038B8", ok: "0B6B2E", warn: "7A4A00", bad: "A3110C", info: "0038B8",
              pair: "contrast-dark", onAccent: "FFFFFF", companion: "oxocarbon-light"),
        .init(id: "contrast-dark", family: .highContrast, name: "High Contrast Dark", mode: .dark,
              ground: "000000", side: "0D0D0D", card: "111111", hair: "8A8A8A", ink: "FFFFFF", muted: "D6D6D6",
              accent: "85B7FF", ok: "6FE39A", warn: "FFD166", bad: "FF8A80", info: "85B7FF",
              pair: "contrast-light", onAccent: "111111", companion: "oxocarbon-dark"),
    ]

    static func register(id: String) -> AppThemeRegister? { all.first { $0.id == id } }

    var themeInfo: AppThemeInfo {
        AppThemeInfo(family: family, sideHex: side, companionSchemeID: companion)
    }
}

extension HelmTheme {

    /// The fourteen app themes, family by family, light then dark.
    static let appThemes: [HelmTheme] = AppThemeFamily.allCases.flatMap { family in
        [family.lightID, family.darkID].compactMap { id -> HelmTheme? in
            guard let register = AppThemeRegister.register(id: id) else { return nil }
            switch id {
            case "daylight": return HelmTheme.daylight
            case "dusk": return HelmTheme.dusk
            default: return HelmTheme(appRegister: register)
            }
        }
    }

    static func appTheme(id: String) -> HelmTheme? {
        appThemes.first { $0.id == id }
    }

    /// Is this one of the fourteen app themes, rather than a terminal scheme
    /// the app has been put on directly (which only a self-test does)?
    var isAppTheme: Bool { app != nil }

    /// The terminal scheme this theme's terminal paints in under "Match app
    /// theme".
    ///
    /// A terminal scheme that a self-test sets as the app theme directly is
    /// its own companion, which is exactly what the app did before the split
    /// - so every suite that sweeps `allThemes` through `setTheme` still sees
    /// the terminal it always saw.
    var companionScheme: HelmTheme {
        guard let id = app?.companionSchemeID, let scheme = HelmTheme.theme(id: id) else { return self }
        return scheme
    }

    /// One of the twelve app registers that are not Daylight or Dusk.
    ///
    /// Every surface, ink and status value is the prototype's. What the
    /// prototype does not specify, `DaylightTokens` still needs, and each of
    /// those is derived from the register's own values by a rule that
    /// reproduces Daylight's and Dusk's hand-picked tokens (stated per field in
    /// `designTokens(for:)`), rather than chosen.
    fileprivate init(appRegister r: AppThemeRegister) {
        let companion = HelmTheme.theme(id: r.companion) ?? .dusk
        self.init(
            id: r.id, mode: r.mode, name: r.name, pairId: r.pair,
            chromeBackgroundHex: r.card, chromeInkHex: r.ink, chromeLineHex: r.hair,
            accentHex: r.accent,
            foregroundHex: r.ink, backgroundHex: r.ground,
            cursorHex: r.accent, selectionHex: r.accent, selectionTextHex: r.onAccent,
            ansiHex: Self.statusVocabulary(for: r),
            terminalCard: nil,
            app: r.themeInfo,
            designTokens: Self.designTokens(for: r, companion: companion))
    }

    /// Slots 1-5 are what the app reads (`HelmTint`): critical, good, warn,
    /// info and violet. Violet is not in the prototype's table, so it is the
    /// Daylight family's own violet for the same register - the app's one
    /// existing violet, already measured on surfaces of this kind. Everything
    /// else is the same register's Daylight-family filler.
    private static func statusVocabulary(for r: AppThemeRegister) -> [String] {
        var slots = r.mode == .light ? HelmTheme.daylight.ansiHex : DaylightPalette.darkRegisterAnsi
        slots[0] = r.ink
        slots[1] = r.bad
        slots[2] = r.ok
        slots[3] = r.warn
        slots[4] = r.info
        slots[8] = r.muted
        slots[15] = r.ink
        return slots
    }

    /// The Daylight token set for a register.
    ///
    /// - paper, card, hair, ink, muted and the three status texts are the
    ///   prototype's values.
    /// - `inset` is the prototype's `side`. On Dusk the two are the same value
    ///   (`1E1F25`), and the prototype checked `muted` on it.
    /// - `hairRow` is half way from the card to the hair, `rowHover` a quarter
    ///   of the way, and `faint` muted 40% of the way to the card. Applied to
    ///   Dusk these give `2D2F38`, `282A32` (exact) and `6A6760` against its
    ///   hand-picked `2A2B33`, `282A32` and `6B675C`.
    /// - `linkBlue` is the register's `info`, which is its blue; Daylight's
    ///   accent and info are the same value.
    /// - The terminal well (`termBackground`/`termInk`, which the Log Analyzer's
    ///   raw pane and the pod log list paint) is the companion scheme's own
    ///   cells - what this theme's terminal looks like by default.
    /// - `shadowInk` is the ink on a light register, as on Daylight, and the
    ///   ground taken most of the way to black on a dark one, as on Dusk.
    private static func designTokens(for r: AppThemeRegister, companion: HelmTheme) -> DaylightTokens {
        let cells = companion.terminalCells
        return DaylightTokens(
            paper: r.ground,
            card: r.card,
            inset: r.side,
            hair: r.hair,
            hairRow: mixHex(r.hair, r.card, 0.5),
            ink: r.ink,
            muted: r.muted,
            faint: mixHex(r.card, r.muted, 0.4),
            rowHover: mixHex(r.hair, r.card, 0.25),
            termBackground: cells.backgroundHex,
            termInk: cells.inkHex,
            linkBlue: r.info,
            okText: r.ok,
            warnText: r.warn,
            badText: r.bad,
            shadowInk: r.mode == .light ? r.ink : mixHex("000000", r.ground, 0.55))
    }

    /// `a` weighted by `t` over `b`, per 8-bit channel, as `RRGGBB`.
    static func mixHex(_ a: String, _ b: String, _ t: Double) -> String {
        let ca = HelmContrast.components(nsColor(a))
        let cb = HelmContrast.components(nsColor(b))
        let m = HelmContrast.mix(ca, cb, t)
        return String(format: "%02X%02X%02X",
                      Int((m.0 * 255).rounded()), Int((m.1 * 255).rounded()), Int((m.2 * 255).rounded()))
    }
}

// MARK: - Moving a saved terminal-scheme theme onto an app theme

enum AppThemeMigration {

    /// The app register each of the 26 old theme ids moves to.
    ///
    /// The register always matches (a dark palette lands on a dark register),
    /// and a family moves as a family, so ⌘-toggling after the move still
    /// lands where the old pair did. Where an old palette is one of the
    /// prototype's companions the choice is that companion's app theme, which
    /// is what makes the move invisible in the terminal for those twelve
    /// palettes; the rest go to the family whose character is nearest
    /// (navy and teal to Harbor, warm amber to Ember, neutral purple to
    /// Graphite).
    static let legacyMap: [String: String] = [
        "daylight": "daylight", "dusk": "dusk",
        "helm-dark": "night-watch", "helm-light": "harbor",
        "solarized-dark": "night-watch", "solarized-light": "harbor",
        "catppuccin-mocha": "ink", "catppuccin-latte": "paper",
        "gruvbox-dark": "moss", "gruvbox-light": "grove",
        "tokyo-night-dark": "ink", "tokyo-night-light": "paper",
        "rose-pine-main": "cinder", "rose-pine-dawn": "ember",
        "nord-polar": "night-watch", "nord-snow": "harbor",
        "dracula": "graphite-dark", "alucard": "graphite-light",
        "one-dark": "graphite-dark", "one-light": "graphite-light",
        "ayu-dark": "cinder", "ayu-light": "ember",
        "night-owl": "night-watch", "light-owl": "harbor",
        "oxocarbon-dark": "contrast-dark", "oxocarbon-light": "contrast-light",
    ]

    /// What an install saved before the split moves to.
    struct Outcome: Equatable {
        let appThemeID: String
        /// `nil` means "Match app theme", which is also what a fresh install
        /// gets.
        let terminalColors: TerminalColorsSettings?
    }

    /// The pure decision. `oldTheme` is the scheme the app was on, and
    /// `followPair` the light and dark schemes it switched between when it
    /// was following the system (`nil` when it was not).
    ///
    /// The terminal is kept **exactly** as it was. An old theme whose family
    /// is the new theme's companion needs nothing. Any other gets the
    /// override, as a light and dark pair so that the light/dark toggle and
    /// following the system still change the terminal the way they did.
    static func outcome(oldTheme: HelmTheme,
                        followPair: (light: HelmTheme, dark: HelmTheme)?) -> Outcome {
        let appID = legacyMap[oldTheme.id] ?? (oldTheme.mode == .light ? "daylight" : "dusk")
        let app = HelmTheme.appTheme(id: appID) ?? .dusk
        let family = app.app?.family ?? .daylight

        let oldLight: HelmTheme
        let oldDark: HelmTheme
        if let followPair {
            oldLight = followPair.light
            oldDark = followPair.dark
        } else {
            let pair = HelmTheme.theme(id: oldTheme.pairId) ?? oldTheme
            oldLight = oldTheme.mode == .light ? oldTheme : pair
            oldDark = oldTheme.mode == .dark ? oldTheme : pair
        }
        let companionLight = family.register(.light).companionScheme.id
        let companionDark = family.register(.dark).companionScheme.id
        guard oldLight.id != companionLight || oldDark.id != companionDark else {
            return Outcome(appThemeID: appID, terminalColors: nil)
        }
        return Outcome(appThemeID: appID, terminalColors: TerminalColorsSettings(
            mode: .custom, schemeID: oldTheme.id, changesWithAppearance: true,
            lightSchemeID: oldLight.id, darkSchemeID: oldDark.id))
    }
}
