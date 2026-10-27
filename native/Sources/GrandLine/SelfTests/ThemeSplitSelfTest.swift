// Grand Line - native macOS app.
//
// The theme split (`fm/grandline-theme-split-app-terminal`): the app's own
// seven families, the terminal's own colour choice, and the one-time move of
// an install's saved theme from the old model onto the new one.
//
// **Pure logic, no window or view hierarchy**, so it guards CI's blocking
// lane. Its window-backed half (a real console whose terminal has to change
// colour while the page around it does not) is `ThemeSplitConsoleSelfTest`.
//
// What each case rules out:
//   1. A register drifting from the captain's approved prototype. The table
//      below is a literal copy of the prototype's `APP` and `COMPANION`, kept
//      apart from `AppThemeRegister.all` so an edit to one is caught by the
//      other.
//   2. A register below WCAG AA for its text and status colours.
//   3. An upgrade changing what the terminal looks like, for any of the 26
//      old themes, in either register, with or without following the system,
//      and for the legacy dark/light key.
//   4. The move running twice, or writing a theme for a fresh install (which
//      would turn "Follow system appearance" off for it).
//   5. A terminal colours change reaching anything but the terminal.
//   6. A backup losing the terminal choice, or an old bundle failing to
//      decode or restoring a terminal different from the one it was made on.
//
// Run with:
//   swift build && FM_RUN_THEME_SPLIT_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ThemeSplitSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkTheRegistersAreThePrototypes,
                      checkEveryRegisterClearsTheTextFloor,
                      checkTheMoveKeepsEveryTerminal,
                      checkTheMoveRunsOnceAndLeavesAFreshInstallAlone,
                      checkAnOverrideMovesOnlyTheTerminal,
                      checkTheBackupCarriesTheTerminalChoice] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ThemeSplitSelfTest: all checks passed" : "ThemeSplitSelfTest: FAILED")
        return allOK
    }

    // MARK: 1. The prototype's table

    /// The approved prototype's `APP` table and `COMPANION` map, verbatim:
    /// ground side card hair ink muted accent ok warn bad info onAccent, then
    /// the companion scheme.
    private static let prototype: [String: String] = [
        "daylight": "F5F2EA FAF8F3 FFFFFF E4DFD2 2A2B33 726D60 3C67DC 1D7B5E 93621E BC4142 3C67DC FFFFFF daylight",
        "dusk": "191A1F 1E1F25 23242B 383A45 E8E6DE 979283 6A8DED 38A882 CD8D2E E07272 6A8DED 111111 dusk",
        "graphite-light": "F5F5F7 ECECEE FFFFFF E1E1E5 1D1D1F 66666B 0A63D1 1F7A3D 9A5B00 C4302B 0A63D1 FFFFFF one-light",
        "graphite-dark": "1C1C1E 242426 2C2C2E 3A3A3D F2F2F7 A1A1A8 4C9BFF 4CC777 F0B23E FF6B61 4C9BFF 111111 one-dark",
        "paper": "FFFFFF F7F7F5 FFFFFF E9E9E6 37352F 73716B 1F6FC5 2B7A4B 94621A C0392F 1F6FC5 FFFFFF catppuccin-latte",
        "ink": "191919 202020 252525 333333 E9E9E7 9E9E9B 5AA2DA 5BB98A D9A548 E8776C 5AA2DA 111111 tokyo-night-dark",
        "harbor": "F2F5F8 E7EDF3 FFFFFF D8E0E9 14212E 566778 0B6A87 1E7A55 8F5E12 B83A3A 2462B8 FFFFFF light-owl",
        "night-watch": "0E1620 121C28 172331 263547 E4ECF4 8FA2B5 4FB6D3 4CC291 E9B04F F07A72 7AA7F0 111111 night-owl",
        "grove": "F4F6F1 EAEFE5 FFFFFF DAE2D2 1E2A1F 5A6857 2C7149 2C7149 8E5F17 B73E37 2F64A8 FFFFFF gruvbox-light",
        "moss": "141914 1A201A 202820 303B30 E2EADE 95A390 6CC08C 6CC08C DDB053 EC7B70 7FA9E8 111111 gruvbox-dark",
        "ember": "FBF6F2 F4EBE4 FFFFFF EADCD1 2B1F1A 776358 B83E0B 2B7A4B 8F5C10 B8322F 2E63B5 FFFFFF rose-pine-dawn",
        "cinder": "1A1513 211A17 2A211D 3C302A F2E8E2 AD9B90 F28C5E 5DBE8A E8B451 F27A6E 80A8F0 111111 rose-pine-main",
        "contrast-light": "FFFFFF F0F0F0 FFFFFF 767676 000000 333333 0038B8 0B6B2E 7A4A00 A3110C 0038B8 FFFFFF oxocarbon-light",
        "contrast-dark": "000000 0D0D0D 111111 8A8A8A FFFFFF D6D6D6 85B7FF 6FE39A FFD166 FF8A80 85B7FF 111111 oxocarbon-dark",
    ]

    private static func same(_ a: String, _ b: String) -> Bool { a.uppercased() == b.uppercased() }

    private static func checkTheRegistersAreThePrototypes(_ ok: inout Bool) {
        print("\n-- every app register is the prototype's, wired where the app reads it --")
        check(HelmTheme.appThemes.count == 14, "there are 14 app registers (got \(HelmTheme.appThemes.count))", &ok)
        check(Set(HelmTheme.appThemes.map(\.id)) == Set(prototype.keys),
              "the app registers are exactly the prototype's", &ok)
        for theme in HelmTheme.appThemes {
            guard let row = prototype[theme.id]?.split(separator: " ").map(String.init), row.count == 13 else {
                fail("\(theme.id) is not in the prototype's table", &ok)
                continue
            }
            let tokens = theme.daylightTokens
            let wired: [(String, String, String)] = [
                ("ground (page)", theme.backgroundHex, row[0]),
                ("side (nav column)", theme.app?.sideHex ?? "", row[1]),
                ("card", theme.chromeBackgroundHex, row[2]),
                ("hair", tokens.hair, row[3]),
                ("ink", theme.chromeInkHex, row[4]),
                ("muted", tokens.muted, row[5]),
                ("accent", theme.accentHex, row[6]),
                ("ok (HelmTint.good)", HelmTint.good.hex(in: theme), row[7]),
                ("warn (HelmTint.warn)", HelmTint.warn.hex(in: theme), row[8]),
                ("bad (HelmTint.critical)", HelmTint.critical.hex(in: theme), row[9]),
                ("info (HelmTint.info)", HelmTint.info.hex(in: theme), row[10]),
            ]
            for (name, actual, expected) in wired where !same(actual, expected) {
                fail("\(theme.id) \(name) is \(actual), the prototype's is \(expected)", &ok)
            }
            // Dusk keeps its own measured accent ink (`12131A`, 5.86:1) where
            // the prototype's table rounds every dark register to `111111`;
            // the two are a single 8-bit step apart in each channel.
            if theme.id != "dusk", !same(theme.selectionTextHex, row[11]) {
                fail("\(theme.id) text on accent is \(theme.selectionTextHex), the prototype's is \(row[11])", &ok)
            }
            check(theme.companionScheme.id == row[12],
                  "\(theme.id) matches the terminal to \(row[12]) (got \(theme.companionScheme.id))", &ok)
            check(HelmTheme.theme(id: row[12]) != nil, "\(row[12]) is one of the 26 terminal schemes", &ok)
            check(theme.isDaylight, "\(theme.id) speaks the Daylight design language", &ok)
            check(same(HelmTheme.sidePanelFill(theme).hexForTests, row[1]),
                  "\(theme.id) paints a nav column in its own side value", &ok)
            if let family = theme.app?.family {
                check(family.register(theme.mode).id == theme.id, "\(theme.id) is its family's \(theme.mode) register", &ok)
                check(HelmTheme.appTheme(id: theme.pairId)?.app?.family == family
                        && HelmTheme.appTheme(id: theme.pairId)?.mode != theme.mode,
                      "\(theme.id) pairs with its family's other register", &ok)
            }
        }
        // The terminal catalogue is untouched: still 26, none of them an app
        // theme except the two that always were both.
        check(HelmTheme.allThemes.count == 26, "the terminal keeps all 26 schemes", &ok)
        let both = HelmTheme.allThemes.filter(\.isAppTheme).map(\.id)
        check(both == ["daylight", "dusk"], "only Daylight and Dusk are in both catalogues (got \(both))", &ok)
        check(!HelmTheme.solarizedLight.isDaylight,
              "a terminal scheme set directly still renders with its own recipes, not the app's", &ok)
        if ok { print("  ok   14 registers, every wired value the prototype's, every companion a real scheme") }
    }

    // MARK: 2. Contrast

    private static func checkEveryRegisterClearsTheTextFloor(_ ok: inout Bool) {
        print("\n-- every register's text and status colours clear 4.5:1 on their own surfaces --")
        var worst = (id: "", pair: "", ratio: 99.0)
        for theme in HelmTheme.appThemes {
            let t = theme.daylightTokens
            let surfaces = [("card", theme.chromeBackgroundHex), ("ground", theme.backgroundHex),
                            ("side", theme.app?.sideHex ?? theme.backgroundHex)]
            var pairs: [(String, String, String)] = []
            for (name, surface) in surfaces {
                pairs.append(("ink on \(name)", t.ink, surface))
                pairs.append(("muted on \(name)", t.muted, surface))
            }
            pairs.append(("accent on card", theme.accentHex, theme.chromeBackgroundHex))
            pairs.append(("accent on ground", theme.accentHex, theme.backgroundHex))
            pairs.append(("text on accent", theme.selectionTextHex, theme.accentHex))
            for tint in [HelmTint.good, .warn, .critical, .info] {
                pairs.append(("\(tint) on card", tint.hex(in: theme), theme.chromeBackgroundHex))
            }
            for (name, fg, bg) in pairs {
                let ratio = HelmContrast.ratio(HelmTheme.nsColor(fg), HelmTheme.nsColor(bg))
                if ratio < worst.ratio { worst = (theme.id, name, ratio) }
                check(ratio >= HelmContrast.textTarget - 0.005,
                      "\(theme.id) \(name) measures \(String(format: "%.2f", ratio)):1", &ok)
            }
        }
        print("  worst pair: \(worst.id) \(worst.pair) at \(String(format: "%.2f", worst.ratio)):1")
    }

    // MARK: 3. The move keeps every terminal

    private static func checkTheMoveKeepsEveryTerminal(_ ok: inout Bool) {
        print("\n-- moving any of the 26 old themes leaves the terminal exactly as it was --")
        // Discriminating power first: at least one old theme has to need the
        // override, or every assertion below could pass with the override
        // logic deleted.
        var overridden = 0
        for old in HelmTheme.allThemes {
            let outcome = AppThemeMigration.outcome(oldTheme: old, followPair: nil)
            guard let app = HelmTheme.appTheme(id: outcome.appThemeID) else {
                fail("\(old.id) moved to \(outcome.appThemeID), which is not an app theme", &ok)
                continue
            }
            if outcome.terminalColors != nil { overridden += 1 }
            let colors = outcome.terminalColors ?? TerminalColorsSettings()
            check(app.mode == old.mode, "\(old.id) keeps its register (moved to \(app.id))", &ok)
            check(colors.scheme(for: app).id == old.id,
                  "\(old.id): the terminal still paints \(old.id) after the move "
                  + "(got \(colors.scheme(for: app).id))", &ok)
            // And the light/dark toggle still lands the terminal where the
            // old pair did.
            if let flipped = HelmTheme.appTheme(id: app.pairId), let oldPair = HelmTheme.theme(id: old.pairId) {
                check(colors.scheme(for: flipped).id == oldPair.id,
                      "\(old.id): after the toggle the terminal paints \(oldPair.id) "
                      + "(got \(colors.scheme(for: flipped).id))", &ok)
            }
        }
        check(overridden > 0 && overridden < HelmTheme.allThemes.count,
              "some old themes need the override and some do not (\(overridden) of 26 do)", &ok)
        // A companion family moves with no override at all.
        check(AppThemeMigration.outcome(oldTheme: HelmTheme.oneDark, followPair: nil)
                == .init(appThemeID: "graphite-dark", terminalColors: nil),
              "One Dark moves to Graphite Dark with the terminal on Match app theme", &ok)
        check(AppThemeMigration.outcome(oldTheme: .dusk, followPair: nil)
                == .init(appThemeID: "dusk", terminalColors: nil),
              "Dusk stays Dusk with nothing to override", &ok)

        // Following the system: the old pair becomes the terminal's pair when
        // it is not the family's companions. The shipped defaults (Helm Light
        // by day, Dusk by night) are the case most installs are in.
        let defaults = AppThemeMigration.outcome(oldTheme: .dusk, followPair: (.light, .dusk))
        let colors = defaults.terminalColors ?? TerminalColorsSettings()
        check(defaults.appThemeID == "dusk", "a following Dusk install stays on Dusk", &ok)
        check(colors.scheme(for: .daylight).id == "helm-light" && colors.scheme(for: .dusk).id == "dusk",
              "by day the terminal is still Helm Light and by night still Dusk "
              + "(got \(colors.scheme(for: .daylight).id) / \(colors.scheme(for: .dusk).id))", &ok)
        let matching = AppThemeMigration.outcome(oldTheme: .daylight, followPair: (.daylight, .dusk))
        check(matching.terminalColors == nil, "a pair that is the family's own companions needs no override", &ok)
        if ok { print("  ok   all 26 keep their terminal in both registers; \(overridden) carry the override") }
    }

    // MARK: 4. Once, and never for a fresh install

    private static func checkTheMoveRunsOnceAndLeavesAFreshInstallAlone(_ ok: inout Bool) {
        print("\n-- the move runs once, keeps the legacy key working, and writes nothing for a fresh install --")
        var suites: [String] = []
        func scratch(_ name: String) -> UserDefaults {
            let suite = "grandline.themesplit.\(name).\(ProcessInfo.processInfo.processIdentifier)"
            suites.append(suite)
            let store = UserDefaults(suiteName: suite) ?? .standard
            store.removePersistentDomain(forName: suite)
            return store
        }
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }

        let saved = scratch("saved")
        saved.set("catppuccin-mocha", forKey: "fm.themeID")
        saved.set(false, forKey: "fm.followSystemAppearance")
        let first = ThemeManager.debugMigrate(saved)
        check(first.theme.id == "ink", "a saved Catppuccin Mocha moves to Ink (got \(first.theme.id))", &ok)
        check(first.terminal.scheme(for: first.theme).id == "catppuccin-mocha",
              "and its terminal is still Catppuccin Mocha", &ok)
        check(saved.string(forKey: "fm.themeID") == "ink", "the moved theme is stored", &ok)
        // Run it again: nothing moves a second time, even though `fm.themeID`
        // now names a theme that is in both catalogues' vocabulary.
        saved.set("dusk", forKey: "fm.themeID")
        let second = ThemeManager.debugMigrate(saved)
        check(second.theme.id == "dusk" && second.terminal == first.terminal,
              "a second launch moves nothing (theme \(second.theme.id))", &ok)

        let legacy = scratch("legacy")
        legacy.set("light", forKey: "fm.themeMode")
        legacy.set(false, forKey: "fm.followSystemAppearance")
        let fromLegacy = ThemeManager.debugMigrate(legacy)
        check(fromLegacy.theme.mode == .light, "the legacy light key lands on a light register", &ok)
        check(fromLegacy.terminal.scheme(for: fromLegacy.theme).id == "helm-light",
              "and its terminal is still Helm Light, as that key meant", &ok)

        let fresh = scratch("fresh")
        let freshResult = ThemeManager.debugMigrate(fresh)
        check(fresh.string(forKey: "fm.themeID") == nil,
              "a fresh install has no theme written for it, so it still follows the system by default", &ok)
        check(freshResult.theme.id == ThemeManager.fallbackTheme.id && freshResult.terminal.mode == .matchApp,
              "a fresh install opens on \(ThemeManager.fallbackTheme.id) with the terminal matching it", &ok)
        check(fresh.integer(forKey: ThemeManager.themeModelKey) == ThemeManager.currentThemeModel,
              "and records that it is on the new model", &ok)
    }

    // MARK: 5. An override moves only the terminal

    private static func checkAnOverrideMovesOnlyTheTerminal(_ ok: inout Bool) {
        print("\n-- choosing a terminal scheme changes the terminal and nothing the app observes --")
        let manager = ThemeManager.shared
        let restoreTheme = manager.theme
        let restoreColors = manager.terminalColors
        defer {
            manager.setTerminalColors(restoreColors)
            manager.setTheme(restoreTheme)
        }
        manager.setTheme(.dusk)
        manager.setTerminalColors(TerminalColorsSettings())
        check(manager.terminalScheme.id == "dusk", "Dusk matches its own card", &ok)

        var appFires = 0
        var terminalFires: [String] = []
        let appToken = manager.observe { _ in appFires += 1 }
        let terminalToken = manager.observeTerminalScheme { terminalFires.append($0.id) }
        defer {
            manager.unobserve(appToken)
            manager.unobserve(terminalToken)
        }
        appFires = 0
        terminalFires = []

        manager.setTerminalColors(TerminalColorsSettings(mode: .custom, schemeID: "solarized-light"))
        check(manager.terminalScheme.id == "solarized-light", "the terminal paints the chosen scheme", &ok)
        check(manager.theme.id == "dusk", "the app theme did not move", &ok)
        check(appFires == 0, "no app theme observer fired (\(appFires) did) - the page has nothing to repaint", &ok)
        check(terminalFires == ["solarized-light"], "the terminal observers heard it once (\(terminalFires))", &ok)

        // A fixed scheme survives the light/dark toggle.
        terminalFires = []
        manager.toggle()
        check(manager.theme.id == "daylight" && manager.terminalScheme.id == "solarized-light",
              "the toggle flips the app and leaves a fixed scheme alone", &ok)
        check(terminalFires.isEmpty, "and tells no terminal anything", &ok)

        // A pair follows it.
        manager.setTerminalColors(TerminalColorsSettings(mode: .custom, schemeID: "solarized-light",
                                                         changesWithAppearance: true,
                                                         lightSchemeID: "gruvbox-light", darkSchemeID: "dracula"))
        check(manager.terminalScheme.id == "gruvbox-light", "a pair paints its light slot in a light app", &ok)
        manager.toggle()
        check(manager.terminalScheme.id == "dracula", "and its dark slot after the toggle", &ok)

        // A retired scheme id falls back to the companion, never to nothing.
        manager.setTerminalColors(TerminalColorsSettings(mode: .custom, schemeID: "a-scheme-that-was-removed"))
        check(manager.terminalScheme.id == manager.theme.companionScheme.id,
              "an unknown scheme id reads as Match app theme", &ok)
    }

    // MARK: 6. The backup

    private static func checkTheBackupCarriesTheTerminalChoice(_ ok: inout Bool) {
        print("\n-- a backup round-trips the terminal choice and an old bundle still restores --")
        let choice = TerminalColorsSettings(mode: .custom, schemeID: "dracula", changesWithAppearance: true,
                                            lightSchemeID: "alucard", darkSchemeID: "dracula")
        let settings = BackupSettings(themeID: "night-watch", terminalColors: choice)
        guard let data = try? JSONEncoder().encode(settings),
              let back = try? JSONDecoder().decode(BackupSettings.self, from: data) else {
            fail("BackupSettings with terminal colours did not round-trip", &ok)
            return
        }
        check(back.terminalColors == choice, "the terminal choice survives encode and decode", &ok)
        check(back.summary.contains("terminal colours"), "the import preview names it (\(back.summary))", &ok)
        check(back.resolvedThemes.theme?.id == "night-watch" && back.resolvedThemes.terminalColors == choice,
              "and restores as written", &ok)

        // A bundle from before the split: no terminal field, and a theme id
        // that is one of the 26 schemes.
        let old = Data(#"{"themeID":"gruvbox-light","fontSize":14}"#.utf8)
        guard let oldSettings = try? JSONDecoder().decode(BackupSettings.self, from: old) else {
            fail("a pre-split bundle's settings no longer decode (GL-01)", &ok)
            return
        }
        check(oldSettings.terminalColors == nil, "an old bundle reads as carrying no terminal choice", &ok)
        let restored = oldSettings.resolvedThemes
        check(restored.theme?.id == "grove", "an old Gruvbox Light bundle restores onto Grove (got \(restored.theme?.id ?? "nil"))", &ok)
        if let app = restored.theme {
            check((restored.terminalColors ?? TerminalColorsSettings()).scheme(for: app).id == "gruvbox-light",
                  "with the terminal it was made on", &ok)
        }
        let catppuccin = BackupSettings(themeID: "catppuccin-mocha").resolvedThemes
        if let app = catppuccin.theme {
            check(catppuccin.terminalColors?.scheme(for: app).id == "catppuccin-mocha",
                  "an old Catppuccin Mocha bundle keeps its terminal through the override", &ok)
        } else {
            fail("an old Catppuccin Mocha bundle restored no app theme", &ok)
        }

        // The terminal value itself tolerates a newer build's fields and an
        // unknown mode.
        let newer = Data(#"{"mode":"somethingNew","schemeID":"nord-polar","extra":1}"#.utf8)
        let decoded = try? JSONDecoder().decode(TerminalColorsSettings.self, from: newer)
        check(decoded?.mode == .matchApp && decoded?.schemeID == "nord-polar",
              "an unknown mode decodes as Match app theme and keeps the rest", &ok)
    }
}

private extension NSColor {
    var hexForTests: String {
        let c = HelmContrast.components(self)
        return String(format: "%02X%02X%02X", Int((c.0 * 255).rounded()), Int((c.1 * 255).rounded()),
                      Int((c.2 * 255).rounded()))
    }
}

#endif
