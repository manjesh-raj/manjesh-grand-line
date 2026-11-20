// Grand Line - native macOS app.
//
// The six palettes (`fm/grand-line-color-options`): Chart, Porcelain,
// Midnight, Powder, Pearl and Forest, each a theme family with a light and a
// dark register, in a group of their own under the seven classic families.
//
// **Pure logic, no window or view hierarchy**, so it guards CI's blocking
// lane. The Settings grid's heading, selection and search are asserted in a
// real window by `SettingsRedesignSelfTest.checkThePalettesAreTheirOwnGroup`,
// and the registers' values and text contrast by `ThemeSplitSelfTest`.
//
// What each case rules out:
//   1. A classic family's heroes moving. Every classic register, and every
//      terminal scheme a suite can set directly, must draw every hero entry
//      point (the hero surface, a hero card's theme tone, the hero column,
//      the sidebar's ink, the lane and calendar bands, Setup's hero) from its
//      accent exactly as before the palettes existed.
//   2. A pinned hero not reaching one of those entry points, so a page would
//      paint the accent's grey-steel hero beside the sidebar's real colour.
//   3. A palette hero that is illegible, or that sinks into its own ground.
//   4. Home's card colours misbehaving across a theme change: the theme
//      choice must follow the theme (and a palette's pinned hero), and a
//      preset or a custom colour must stay exactly the colour picked.
//   5. The theme menu running the two groups together.
//   5a. A palette painting Daylight's fixed blue where the app asks for its
//      blue (primary buttons, blue tiles, links), or a classic family losing it.
//   6. Settings' search missing a palette's or a register's name.
//
// Run with:
//   swift build && FM_RUN_THEME_PALETTES_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ThemePalettesSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkClassicHeroesAreTheirAccents,
                      checkPinnedHeroesReachEveryEntryPoint,
                      checkPaletteHeroesAreLegibleAndStandOut,
                      checkTheBlueHueIsThePalettes,
                      checkHomeCardColoursAcrossThemes,
                      checkTheMenuSeparatesTheGroups,
                      checkSearchFindsEveryPalette] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ThemePalettesSelfTest: all checks passed" : "ThemePalettesSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        HelmContrast.components(HelmTheme.nsColor(hex))
    }

    private static func close(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
        abs(a.0 - b.0) < 1e-9 && abs(a.1 - b.1) < 1e-9 && abs(a.2 - b.2) < 1e-9
    }

    private static func theme(_ id: String) -> HelmTheme? { HelmTheme.appTheme(id: id) }

    private static let setupWords = SetupHeroWords.Words(headline: "h", body: "b", tone: .accent, isDimmed: false)

    /// Every hero entry point's palette for `theme`, by name.
    private static func entryPoints(_ theme: HelmTheme) -> [(String, HelmHeroSurface.Palette)] {
        [
            ("HelmHeroSurface.palette(for:)", HelmHeroSurface.palette(for: theme)),
            ("HelmHeroCard.palette(for:)", HelmHeroCard.palette(for: theme)),
            ("a hero card's theme tone", HelmModuleCard.HeroTone(colour: .themeAccent).palette(in: theme)),
            ("the hero column", HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)),
            ("the sidebar's ink", WorkspaceSidebarInk.of(theme).palette),
            ("the Backlog lane band", ShiftLaneTone.accent.palette(in: theme)),
            ("Setup's hero", SetupHeroRow.palette(for: setupWords, in: theme)),
        ]
    }

    /// What every entry point should be when the hero is drawn from `hex`.
    private static func expected(_ name: String, from hex: String) -> HelmHeroSurface.Palette {
        let base = rgb(hex)
        switch name {
        case "the hero column", "the sidebar's ink":
            return HelmHeroSurface.palette(accent: base, quietInk: Double(HelmHeroColumn.quietInkAlpha))
        case "the Backlog lane band":
            return HelmHeroSurface.palette(accent: base, quietInk: Double(ShiftLaneHeroBand.detailAlpha))
        case "Setup's hero":
            return HelmHeroSurface.palette(accent: base, quietInk: Double(SetupHeroRow.quietInkAlpha))
        default:
            return HelmHeroSurface.palette(accent: base)
        }
    }

    // MARK: 1. The classic families are untouched

    private static func checkClassicHeroesAreTheirAccents(_ ok: inout Bool) {
        print("\n-- every classic register and terminal scheme draws its heroes from its accent --")
        let classics = HelmTheme.appThemes.filter { $0.app?.family.group == .classic }
        check(classics.count == 14, "the seven classic families are fourteen registers (got \(classics.count))", &ok)
        var measured = 0
        for theme in classics + HelmTheme.allThemes {
            check(theme.heroAccentHex == theme.accentHex,
                  "\(theme.id) draws its heroes from its accent (got \(theme.heroAccentHex))", &ok)
            check(theme.app?.heroHex == nil, "\(theme.id) pins no hero", &ok)
            for (name, palette) in entryPoints(theme) {
                check(palette == expected(name, from: theme.accentHex),
                      "\(theme.id): \(name) is the accent's palette", &ok)
                measured += 1
            }
        }
        if ok { print("  ok   \(measured) entry points across \(classics.count + HelmTheme.allThemes.count) themes, all from the accent") }
    }

    // MARK: 2. A pinned hero reaches everything

    private static func checkPinnedHeroesReachEveryEntryPoint(_ ok: inout Bool) {
        print("\n-- a pinned hero reaches every hero entry point --")
        let pins = HelmTheme.appThemes.filter { $0.app?.heroHex != nil }
        check(pins.map(\.id).sorted() == ["fathom", "forest"],
              "the pinned registers are Fathom and Forest (got \(pins.map(\.id)))", &ok)
        for theme in pins {
            guard let pin = theme.app?.heroHex else { continue }
            // The fixture discriminates: the pin is not the accent, and its
            // hero is not the accent's.
            check(pin.uppercased() != theme.accentHex.uppercased(), "\(theme.id)'s pin differs from its accent", &ok)
            check(HelmHeroSurface.palette(accent: rgb(pin)) != HelmHeroSurface.palette(accent: rgb(theme.accentHex)),
                  "\(theme.id)'s pinned hero is a different palette from its accent's", &ok)
            for (name, palette) in entryPoints(theme) {
                check(palette == expected(name, from: pin), "\(theme.id): \(name) is drawn from the pin \(pin)", &ok)
            }
            // The two status tones on a band keep the theme's own hues.
            check(ShiftLaneTone.green.palette(in: theme) == expected("the Backlog lane band", from: theme.ansiHex[2]),
                  "\(theme.id): the Done lane keeps the theme's green", &ok)
        }
        // The pin is the colour the palette is named for, in both registers.
        check(theme("fathom")?.heroAccentHex == theme("chart")?.accentHex,
              "Fathom's hero is Chart's deep blue", &ok)
        check(theme("forest")?.heroAccentHex == theme("oat")?.accentHex,
              "Forest's hero is Oat's forest green", &ok)
        if ok { print("  ok   Fathom and Forest draw every hero from their pinned colour") }
    }

    // MARK: 3. Legible, and clear of the ground

    private static func checkPaletteHeroesAreLegibleAndStandOut(_ ok: inout Bool) {
        print("\n-- every palette hero is legible and stands out from its ground --")
        let palettes = HelmTheme.appThemes.filter { $0.app?.family.group == .palette }
        check(palettes.count == 12, "the six palettes are twelve registers (got \(palettes.count))", &ok)
        var worstSeparation = (id: "", ratio: 99.0)
        for theme in palettes {
            for (name, palette) in entryPoints(theme) {
                let lighter = palette.lighterStop
                check(HelmContrast.ratio(palette.ink, lighter) >= HelmContrast.textTarget - 0.005,
                      "\(theme.id): \(name)'s text clears 4.5:1 on its lighter stop", &ok)
            }
            let column = HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
            let quiet = HelmContrast.mix(column.ink, column.lighterStop, Double(HelmHeroColumn.quietInkAlpha))
            check(HelmContrast.ratio(quiet, column.lighterStop) >= HelmContrast.textTarget - 0.005,
                  "\(theme.id): the sidebar's quiet text clears 4.5:1", &ok)
            let hero = HelmHeroSurface.palette(for: theme)
            let middle = HelmContrast.mix(hero.start, hero.end, 0.5)
            let separation = HelmContrast.ratio(middle, rgb(theme.backgroundHex))
            if separation < worstSeparation.ratio { worstSeparation = (theme.id, separation) }
            check(separation >= 1.5, "\(theme.id): the hero stands out from the page (\(String(format: "%.2f", separation)):1)", &ok)
        }
        print("  least separation: \(worstSeparation.id) at \(String(format: "%.2f", worstSeparation.ratio)):1")
    }

    // MARK: 3a. The app's blue

    private static func checkTheBlueHueIsThePalettes(_ ok: inout Bool) {
        print("\n-- the app's blue is each palette's accent, and Daylight's blue everywhere else --")
        let daylightBlue = HelmDomainHue.blue.categoricalHex
        for theme in HelmTheme.appThemes {
            let h1 = HelmContrast.components(HelmDomainHue.blue.pair(in: theme).h1)
            let identity = HelmDomainHue.blue.identityHex(in: theme)
            if theme.isPaletteTheme {
                check(close(h1, rgb(theme.accentHex)), "\(theme.id): the blue hue is its accent", &ok)
                check(identity == theme.accentHex, "\(theme.id): the blue identity is its accent", &ok)
                check(theme.daylightTokens.linkBlue == theme.accentHex, "\(theme.id): links are its accent", &ok)
            } else {
                check(close(h1, rgb(daylightBlue)), "\(theme.id): the blue hue is still Daylight's \(daylightBlue)", &ok)
                check(identity == daylightBlue, "\(theme.id): the blue identity is still Daylight's", &ok)
            }
            // The other six hues never move.
            for hue in HelmDomainHue.allCases where hue != .blue && theme.isDaylight {
                check(close(HelmContrast.components(hue.pair(in: theme).h1), rgb(hue.categoricalHex)),
                      "\(theme.id): \(hue) keeps its own colour", &ok)
            }
            // A primary button on the app's blue carries a white label.
            let fill = DaylightPalette.primaryButtonFill(for: .blue, theme: theme)
            check(HelmContrast.ratio(.white, fill) >= HelmContrast.textTarget - 0.005,
                  "\(theme.id): a blue primary button's label clears 4.5:1", &ok)
        }
        if ok { print("  ok   26 registers") }
    }

    // MARK: 4. Home's card colours across a theme change

    private static func checkHomeCardColoursAcrossThemes(_ ok: inout Bool) {
        print("\n-- Home's card colours follow the theme only where they were left to --")
        let ids = ["dusk", "daylight", "chart", "fathom", "porcelain", "forest"]
        let themes = ids.compactMap(theme)
        check(themes.count == ids.count, "every fixture theme exists", &ok)
        for theme in themes {
            check(close(HomeCardColor.accent.rgb(in: theme), rgb(theme.heroAccentHex)),
                  "the theme choice on \(theme.id) is its hero colour", &ok)
        }
        // A picked colour is the colour picked, whichever theme is showing.
        let picks: [HomeCardColor] = [.preset(.ocean), .preset(.forest), .custom("#3A7BD5")]
        for pick in picks {
            let first = pick.rgb(in: themes[0])
            for theme in themes {
                check(close(pick.rgb(in: theme), first), "\(pick.title) is unchanged on \(theme.id)", &ok)
            }
            check(HomeCardColor(storedValue: pick.storedValue) == pick, "\(pick.title) survives being stored", &ok)
        }
        // And the theme choice is still stored as the choice, not a colour,
        // so a card left on it keeps following the next theme too.
        check(HomeCardColor.accent.storedValue == "accent", "the theme choice is stored as itself", &ok)
        if let fathom = theme("fathom"), let chart = theme("chart") {
            check(close(HomeCardColor.accent.rgb(in: fathom), HomeCardColor.accent.rgb(in: chart)),
                  "a card on the theme choice is the same deep blue in Chart and Fathom", &ok)
        }
        if ok { print("  ok   the theme choice follows the hero, presets and custom colours stay put") }
    }

    // MARK: 5. The theme menu

    private final class Target: NSObject { @objc func pick(_ sender: Any?) {} }

    private static func checkTheMenuSeparatesTheGroups(_ ok: inout Bool) {
        print("\n-- the theme menu lists the classics, a separator, then the palettes --")
        let target = Target()
        let menu = ThemeMenu.build(target: target, action: #selector(Target.pick(_:)))
        // Each register group as menu titles, split at separators.
        var runs: [[String]] = [[]]
        for item in menu.items {
            if item.isSeparatorItem { runs.append([]) } else { runs[runs.count - 1].append(item.title) }
        }
        let classicDark = AppThemeFamily.members(of: .classic).map { $0.register(.dark).name }
        let paletteDark = AppThemeFamily.members(of: .palette).map { $0.register(.dark).name }
        let classicLight = AppThemeFamily.members(of: .classic).map { $0.register(.light).name }
        let paletteLight = AppThemeFamily.members(of: .palette).map { $0.register(.light).name }
        let want = [["DARK"] + classicDark, paletteDark, ["LIGHT"] + classicLight, paletteLight]
        check(runs == want, "the menu reads \(runs), want \(want)", &ok)
        if ok { print("  ok   DARK classics | palettes | LIGHT classics | palettes") }
    }

    // MARK: 6. Search

    private static func checkSearchFindsEveryPalette(_ ok: inout Bool) {
        print("\n-- Settings' search knows every palette and register by name --")
        let keywords = SettingsController.Category.appearance.searchKeywords.lowercased()
        let names = AppThemeFamily.members(of: .palette).flatMap { [$0.title, $0.register(.light).name, $0.register(.dark).name] }
        for name in names {
            check(keywords.contains(name.lowercased()), "Appearance's search words include \(name)", &ok)
        }
        check(keywords.contains("palettes"), "Appearance's search words include the group's name", &ok)
        if ok { print("  ok   \(names.count) names") }
    }
}

#endif
