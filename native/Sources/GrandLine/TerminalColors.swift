// Grand Line - native macOS app.
//
// Settings > Terminal > Terminal colours: which of the 26 schemes the terminal
// paints in.
//
// `fm/grandline-theme-split-app-terminal`. The app theme (`AppTheme.swift`)
// and the terminal's colours used to be one value. They are two now, linked
// by default: "Match app theme" paints the terminal in the app theme's
// companion scheme, and "Choose a scheme" names any of the 26 on its own,
// optionally as a light and dark pair that follows the app's appearance.
//
// **What follows the effective scheme, and only that**: the terminal's cells
// (text, the 16 ANSI colours, cursor and selection), the keyword highlighter,
// and the `[theme.custom]` block `HerdrThemeSync` writes for herdr, which runs
// inside a terminal tab. Nothing outside the terminal reads it - the page
// around the terminal, the status colours, Code Preview and the Notebook all
// stay on the app theme.

import AppKit

/// The captain's terminal colour choice. Absent everywhere means "Match app
/// theme", so an install that never opens the setting is never moved by it.
struct TerminalColorsSettings: Codable, Equatable {
    enum Mode: String, Codable {
        case matchApp
        case custom
    }

    var mode: Mode = .matchApp
    /// The one scheme "Choose a scheme" paints in, while
    /// `changesWithAppearance` is off.
    var schemeID: String?
    /// "Change with appearance": paint `lightSchemeID` while the app is light
    /// and `darkSchemeID` while it is dark.
    var changesWithAppearance = false
    var lightSchemeID: String?
    var darkSchemeID: String?

    init(mode: Mode = .matchApp, schemeID: String? = nil, changesWithAppearance: Bool = false,
         lightSchemeID: String? = nil, darkSchemeID: String? = nil) {
        self.mode = mode
        self.schemeID = schemeID
        self.changesWithAppearance = changesWithAppearance
        self.lightSchemeID = lightSchemeID
        self.darkSchemeID = darkSchemeID
    }

    /// GL-01: every field optional on the way in, so a value written by a
    /// later build with a field this one does not know still decodes, and an
    /// unknown mode reads as "Match app theme" rather than failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .matchApp
        schemeID = try c.decodeIfPresent(String.self, forKey: .schemeID)
        changesWithAppearance = try c.decodeIfPresent(Bool.self, forKey: .changesWithAppearance) ?? false
        lightSchemeID = try c.decodeIfPresent(String.self, forKey: .lightSchemeID)
        darkSchemeID = try c.decodeIfPresent(String.self, forKey: .darkSchemeID)
    }

    /// The scheme the terminal paints in while the app is on `app`.
    ///
    /// Every fallback lands on the companion rather than on nothing: a stored
    /// id that names a retired scheme reads as "Match app theme", never as an
    /// unpainted terminal.
    func scheme(for app: HelmTheme) -> HelmTheme {
        let companion = app.companionScheme
        guard mode == .custom else { return companion }
        if changesWithAppearance {
            let id = app.mode == .light ? lightSchemeID : darkSchemeID
            return id.flatMap(HelmTheme.theme(id:)) ?? companion
        }
        return schemeID.flatMap(HelmTheme.theme(id:)) ?? companion
    }

    /// The light and dark slots "Change with appearance" uses, each falling
    /// back to the app family's own companion for that register.
    func pair(for app: HelmTheme) -> (light: HelmTheme, dark: HelmTheme) {
        let family = app.app?.family ?? .daylight
        let light = lightSchemeID.flatMap(HelmTheme.theme(id:)).flatMap { $0.mode == .light ? $0 : nil }
            ?? family.register(.light).companionScheme
        let dark = darkSchemeID.flatMap(HelmTheme.theme(id:)).flatMap { $0.mode == .dark ? $0 : nil }
            ?? family.register(.dark).companionScheme
        return (light, dark)
    }
}

extension HelmTheme {
    /// What this scheme paints a terminal's cells in: its own card when it
    /// has one (Daylight and Dusk), otherwise its own palette.
    var terminalCells: HelmTerminalCard {
        terminalCard ?? HelmTerminalCard(backgroundHex: backgroundHex, inkHex: foregroundHex,
                                         cursorHex: cursorHex, ansiHex: ansiHex)
    }

    /// Whether a terminal painted in `scheme` reads as a different surface
    /// from this (app) theme's page ground, and so sits in a card - the
    /// prototype's rule, and the one Daylight's dark card always followed.
    func drawsTerminalCard(for scheme: HelmTheme) -> Bool {
        scheme.terminalCells.backgroundHex.lowercased() != backgroundHex.lowercased()
    }
}
