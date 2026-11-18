// Grand Line - native macOS app.
//
// Home's two hero cards, the halves that need no window: the hero palette
// over every colour the captain can pick in every theme, the colour store,
// the three size modes, the style menu's shape, and the words each card says
// in its five states.
//
// The view half - where the gradient lands, the ink on every label, the menu
// reaching the real arrangement - is `HeroCardsViewSelfTest`.
//
// Run with:
//   swift build && FM_RUN_HERO_CARDS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum HeroCardsSelfTest {

    static func run() -> Bool {
        let savedColors = AppSettings.shared.homeCardColors
        defer { AppSettings.shared.homeCardColors = savedColors }

        var allOK = true
        let checks: [(inout Bool) -> Void] = [
            checkEveryColourClearsTheFloorInEveryTheme,
            checkThePresetsAreDistinct,
            checkTheStoredValueRoundTrips,
            checkTheStoreKeepsWhatItCannotRead,
            checkTheSizeModes,
            checkTheLayoutThresholds,
            checkTheStyleMenu,
            checkTheClaudePanelStates,
            checkTheFleetStates,
        ]
        for check in checks {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "HeroCardsSelfTest: all checks passed" : "HeroCardsSelfTest: FAILED")
        return allOK
    }

    private static var everyTheme: [HelmTheme] {
        var seen = Set<String>()
        return (HelmTheme.appThemes + HelmTheme.allThemes).filter { seen.insert($0.id).inserted }
    }

    private static func ratio(_ value: Double) -> String { String(format: "%.2f", value) }

    // MARK: Colour

    /// Every colour the menu offers, fresh and dimmed, in every theme: the
    /// ink clears the text floor on both stops, and a warning or limit arc
    /// clears the non-text floor on both.
    private static func checkEveryColourClearsTheFloorInEveryTheme(_ ok: inout Bool) {
        let themes = everyTheme
        check(themes.count >= 26, "fixture: only \(themes.count) themes - the sweep is not every palette", &ok)
        let colours: [HomeCardColor] = [.accent] + HomeCardColorPreset.allCases.map { .preset($0) }
            // A pale custom pick, where white needs the deepest step or the
            // dark-ink fallback.
            + [.custom("#F4E8A0"), .custom("#FFFFFF"), .custom("#000000")]
        var deepened = 0
        for theme in themes {
            for colour in colours {
                for dimmed in [false, true] {
                    let tone = HelmModuleCard.HeroTone(colour: colour.heroColour, isDimmed: dimmed)
                    let palette = tone.palette(in: theme)
                    let tag = "\(theme.id) \(colour.storedValue)\(dimmed ? " dimmed" : "")"
                    let start = HelmContrast.ratio(palette.ink, palette.start)
                    let end = HelmContrast.ratio(palette.ink, palette.end)
                    check(start >= HelmContrast.textTarget && end >= HelmContrast.textTarget,
                          "\(tag): the ink measures \(ratio(start)) and \(ratio(end)) on the two stops", &ok)
                    for hex in [theme.ansiHex[3], theme.ansiHex[1]] {
                        let arc = HelmContrast.components(HelmHeroSurface.signalColor(tintHex: hex, on: palette))
                        let a = HelmContrast.ratio(arc, palette.start), b = HelmContrast.ratio(arc, palette.end)
                        check(a >= HelmContrast.nonTextTarget && b >= HelmContrast.nonTextTarget,
                              "\(tag): a \(hex) arc measures \(ratio(a)) and \(ratio(b)) on the two stops", &ok)
                    }
                    let accent = colour.rgb(in: theme)
                    if !dimmed, palette.start != HelmContrast.mix((1, 1, 1), accent, HelmHeroSurface.startLift) {
                        deepened += 1
                    }
                }
            }
        }
        check(deepened > 0, "fixture: no colour needed its stops deepened - the rule is untested", &ok)
        // Dimming really moves the colour toward grey.
        let ember = HomeCardColor.preset(.ember).rgb(in: themes[0])
        let dim = HelmHeroSurface.dimmed(ember)
        let spread = { (c: (Double, Double, Double)) in max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
        check(spread(dim) < spread(ember) * 0.5,
              "a dimmed colour keeps \(ratio(spread(dim))) of \(ratio(spread(ember))) chroma", &ok)
    }

    /// Weighted RGB distance, never `HelmContrast.ratio` (AGENTS.md's colour
    /// rules: two hues of equal brightness score identically on luminance).
    private static func checkThePresetsAreDistinct(_ ok: inout Bool) {
        func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            let r = (a.0 + b.0) / 2
            let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
            return ((2 + r) * dr * dr + 4 * dg * dg + (3 - r) * db * db).squareRoot() / 3
        }
        let theme = HelmTheme.appThemes[0]
        let presets = HomeCardColorPreset.allCases
        check(presets.count >= 6, "only \(presets.count) presets - the captain asked for a spread", &ok)
        for (i, a) in presets.enumerated() {
            for b in presets[(i + 1)...] {
                let d = distance(HomeCardColor.preset(a).rgb(in: theme), HomeCardColor.preset(b).rgb(in: theme))
                check(d >= 0.15, "\(a.rawValue) and \(b.rawValue) are \(ratio(d)) apart - too close to tell apart", &ok)
            }
        }
    }

    private static func checkTheStoredValueRoundTrips(_ ok: inout Bool) {
        let colours: [HomeCardColor] = [.accent, .custom("#12AB9F")] + HomeCardColorPreset.allCases.map { .preset($0) }
        for colour in colours {
            check(HomeCardColor(storedValue: colour.storedValue) == colour,
                  "\(colour.storedValue) does not read back as itself", &ok)
        }
        check(HomeCardColor(storedValue: "12ab9f") == .custom("#12AB9F"), "a bare lower-case hex does not read", &ok)
        for junk in ["preset:sunset", "#12AB9", "#GGGGGG", "", "blue"] {
            check(HomeCardColor(storedValue: junk) == nil, "\"\(junk)\" reads as a colour", &ok)
        }
        let picked = NSColor(srgbRed: 0x12 / 255.0, green: 0xAB / 255.0, blue: 0x9F / 255.0, alpha: 1)
        check(HomeCardColor.hex(from: picked) == "#12AB9F",
              "the colour panel's colour stores as \(HomeCardColor.hex(from: picked) ?? "nil")", &ok)
        // A custom colour is the colour picked, in every theme.
        let rgb = HomeCardColor.custom("#12AB9F").rgb(in: HelmTheme.appThemes[0])
        check(abs(rgb.0 - 0x12 / 255.0) < 0.002 && abs(rgb.2 - 0x9F / 255.0) < 0.002,
              "a custom colour resolves to \(rgb)", &ok)
    }

    /// GL-01: a value this build cannot read is skipped, never dropped.
    private static func checkTheStoreKeepsWhatItCannotRead(_ ok: inout Bool) {
        AppSettings.shared.homeCardColors = ["fleet": "preset:sunset", "someFutureCard": "#123456"]
        check(HomeCardStyle.color(for: .fleet) == .accent, "an unknown preset is not read as the accent", &ok)
        check(HomeCardStyle.color(for: .claudeStatus) == .accent, "an unset card is not the accent", &ok)
        HomeCardStyle.setColor(.preset(.teal), for: .claudeStatus)
        let stored = AppSettings.shared.homeCardColors
        check(stored["claudeStatus"] == "preset:teal", "Teal was stored as \(stored["claudeStatus"] ?? "nil")", &ok)
        check(stored["fleet"] == "preset:sunset" && stored["someFutureCard"] == "#123456",
              "a write dropped entries this build cannot read: \(stored)", &ok)
        HomeCardStyle.setColor(.accent, for: .claudeStatus)
        check(AppSettings.shared.homeCardColors["claudeStatus"] == nil,
              "the accent is stored rather than left as the default", &ok)
        AppSettings.shared.homeCardColors = [:]
    }

    // MARK: Size and layout

    private static func checkTheSizeModes(_ ok: inout Bool) {
        let columns = HomeCardSizeMode.allCases.map(\.columns)
        check(columns == [6, 12, 24], "the three sizes are \(columns) columns, expected the report's 6, 12 and 24", &ok)
        check(HomeCardSizeMode.allCases.map(\.title) == ["Narrow", "Default", "Full width"],
              "the size titles are \(HomeCardSizeMode.allCases.map(\.title))", &ok)
        for mode in HomeCardSizeMode.allCases {
            check(HomeCardSizeMode(columns: mode.columns) == mode, "\(mode) does not read back from its columns", &ok)
        }
        check(HomeCardSizeMode(columns: 9) == nil, "a dragged width reads as a mode", &ok)
        // The modes are the old fixed sizes, so a migrated layout lands on one.
        check(HomeCardSizeMode.standard.size == HomeCardLayout.ownSize(of: .claudeStatus)
                && HomeCardSizeMode.narrow.size == HomeCardLayout.ownSize(of: .fleet),
              "the cards' own sizes are not Default and Narrow", &ok)
    }

    private static func checkTheLayoutThresholds(_ ok: inout Bool) {
        let cases: [(CGFloat, HelmModuleCard.HeroLayout)] = [(255, .narrow), (290, .narrow), (399, .narrow),
                                                            (400, .standard), (584, .standard), (879, .standard),
                                                            (880, .wide), (1180, .wide)]
        for (width, layout) in cases {
            check(HelmModuleCard.HeroLayout(cardWidth: width) == layout,
                  "a \(width)pt card is \(HelmModuleCard.HeroLayout(cardWidth: width)), expected \(layout)", &ok)
        }
        // The report beside a standard panel is narrow enough for the short
        // labels, and the wide one is not.
        let standard = HelmModuleCard.HeroSplit.detailWidth(cardWidth: 584, layout: .standard)
        let wide = HelmModuleCard.HeroSplit.detailWidth(cardWidth: 1180, layout: .wide)
        check(HomeCanvasController.claudeUsesShortLabels(forCardWidth: standard),
              "the report beside a 584pt card's panel (\(standard)pt) uses the long labels", &ok)
        check(!HomeCanvasController.claudeUsesShortLabels(forCardWidth: wide),
              "the report beside a 1180pt card's panel (\(wide)pt) uses the short labels", &ok)
    }

    private static func checkTheStyleMenu(_ ok: inout Bool) {
        var sized: HomeCardSizeMode?
        var coloured: HomeCardColor?
        var customs = 0
        var hides = 0
        let menu = HomeCardStyleMenu(cardTitle: "Fleet",
                                     sizing: .init(current: .narrow, choose: { sized = $0 }),
                                     color: .preset(.rose), chooseColor: { coloured = $0 },
                                     chooseCustomColor: { customs += 1 }, hide: { hides += 1 }).makeMenu()
        let titles = menu.items.map(\.title)
        let expected = ["Size", "Narrow", "Default", "Full width", "", "Colour", "Theme accent"]
            + HomeCardColorPreset.allCases.map(\.title) + ["Custom colour\u{2026}", "", HomeCardStyleMenu.hideTitle]
        check(titles == expected, "the menu reads \(titles)", &ok)
        check(menu.items.filter { $0.state == .on }.map(\.title) == ["Narrow", "Rose"],
              "the checked items are \(menu.items.filter { $0.state == .on }.map(\.title))", &ok)
        check(menu.items.filter { HomeCardColorPreset.allCases.map(\.title).contains($0.title) }
                .allSatisfy { $0.image != nil }, "a preset has no swatch", &ok)
        func fire(_ title: String) {
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action,
                  let target = item.target as? NSObject else { return }
            target.perform(action, with: item)
        }
        fire("Full width")
        fire("Forest")
        fire("Custom colour\u{2026}")
        fire(HomeCardStyleMenu.hideTitle)
        check(hides == 1, "Hide from Home hid the card \(hides) times", &ok)
        check(sized == .fullWidth, "Full width chose \(String(describing: sized))", &ok)
        check(coloured == .preset(.forest), "Forest chose \(String(describing: coloured))", &ok)
        check(customs == 1, "Custom colour opened the panel \(customs) times", &ok)

        let colourOnly = HomeCardStyleMenu(cardTitle: "Fleet", sizing: nil, color: .custom("#123456"),
                                           chooseColor: { _ in }, chooseCustomColor: {}).makeMenu()
        check(!colourOnly.items.contains { $0.title == "Narrow" }, "a card with no size to choose offers sizes", &ok)
        check(!colourOnly.items.contains { $0.title == HomeCardStyleMenu.hideTitle },
              "a card with no place on Home offers Hide", &ok)
        check(colourOnly.items.first { $0.title == "Custom colour\u{2026}" }?.state == .on,
              "a custom colour does not check Custom colour", &ok)
    }

    // MARK: The words

    private static func checkTheClaudePanelStates(_ ok: inout Bool) {
        typealias State = HeroCardsViewSelfTest.State
        let now = Date()
        func panel(_ state: State) -> HomeCanvasController.ClaudeHeroPanel {
            HomeCanvasController.claudeHeroPanel(snapshot: HeroCardsViewSelfTest.quota(state),
                                                 failure: state == .stale ? "quota-axi timed out" : nil,
                                                 fetchedAt: now, now: now)
        }
        let normal = panel(.normal)
        check(normal.headline == "Plenty of room this week" && normal.chip == nil && !normal.isStale,
              "normal reads \"\(normal.headline)\"", &ok)
        check(normal.ring?.label == "49%" && normal.ring?.state == .ok && normal.ring?.caption == "of the week used",
              "normal's ring is \(String(describing: normal.ring))", &ok)
        check(normal.body?.contains("The week is at 49%") ?? false, "normal's body is \(normal.body ?? "nil")", &ok)

        let warn = panel(.warn)
        check(warn.headline == "Week limit close" && warn.ring?.state == .warn && warn.ring?.label == "84%",
              "near limit reads \"\(warn.headline)\" with \(String(describing: warn.ring))", &ok)

        let critical = panel(.critical)
        check(critical.headline == "Spend cap reached", "at limit reads \"\(critical.headline)\"", &ok)
        check(critical.ring?.state == .bad && critical.ring?.caption == "of the $15 cap",
              "at limit's ring is \(String(describing: critical.ring)) - the spend is the verdict", &ok)

        let stale = panel(.stale)
        check(stale.isStale && stale.chip == .warn("Can't reach") && stale.headline.hasPrefix("Showing the "),
              "stale reads \"\(stale.headline)\" with \(String(describing: stale.chip))", &ok)
        check(stale.ring?.label == "49%", "stale drops the last reading's ring", &ok)

        let idle = panel(.idle)
        check(idle.ring?.label == "0%" && idle.ring?.fraction == 0 && idle.body?.contains("No extra usage spent") == true,
              "idle is \(String(describing: idle.ring)), \(idle.body ?? "nil")", &ok)

        let loading = HomeCanvasController.claudeHeroPanel(snapshot: nil, failure: nil, fetchedAt: nil)
        check(loading.ring == nil && !loading.isStale && loading.headline.hasPrefix("Reading"),
              "loading reads \"\(loading.headline)\"", &ok)
        let failed = HomeCanvasController.claudeHeroPanel(snapshot: nil, failure: "no quota-axi", fetchedAt: nil)
        check(failed.ring == nil && failed.isStale && failed.chip != nil,
              "a failure with no reading reads \"\(failed.headline)\" - GL-14 wants a stated gap", &ok)
    }

    private static func checkTheFleetStates(_ ok: inout Bool) {
        typealias State = HeroCardsViewSelfTest.State
        func hero(_ state: State) -> HomeCanvasController.FleetHero {
            HomeCanvasController.fleetHero(snapshot: HeroCardsViewSelfTest.fleet(state))
        }
        let normal = hero(.normal)
        check(normal.headline == "3 crew working" && normal.chip == .ok("All clear") && !normal.isStale,
              "normal reads \"\(normal.headline)\"", &ok)
        // The ring is the day's progress: 20 done of 20 + 3 working + 46 queued.
        check(abs((normal.ring?.fraction ?? -1) - 20.0 / 69.0) < 0.0001 && normal.ring?.label == "20",
              "normal's ring is \(String(describing: normal.ring))", &ok)
        check(normal.items.map(\.reading) == [.value("3"), .value("20"), .value("46")],
              "normal's numbers are \(normal.items.map(\.reading))", &ok)

        let warn = hero(.warn)
        check(warn.chip == .warn("1 needs you") && warn.ring?.state == .warn && warn.headline == "1 waiting on you",
              "a decision reads \"\(warn.headline)\" with \(String(describing: warn.chip))", &ok)
        let critical = hero(.critical)
        check(critical.chip == .bad("1 blocked") && critical.ring?.state == .bad,
              "a blocked crewmate reads \(String(describing: critical.chip)) - it should be red, not amber", &ok)
        check(critical.body.contains("1 more is waiting on you"), "blocked hides the decision behind it", &ok)
        let stale = hero(.stale)
        check(stale.isStale && stale.chip == .warn("Watcher stale") && stale.subtitle == "watcher stale",
              "a stale watcher reads \"\(stale.headline)\", \(stale.subtitle)", &ok)
        let idle = hero(.idle)
        check(idle.headline == "All clear" && idle.items.first?.reading == .value("0"),
              "idle reads \"\(idle.headline)\"", &ok)

        let reading = HomeCanvasController.fleetHero(snapshot: nil)
        check(reading.ring == nil && reading.items.allSatisfy { !$0.reading.isKnown },
              "a fleet not yet read draws numbers", &ok)
        let unread = HomeCanvasController.fleetHero(snapshot: FleetSnapshot(
            homeOk: false, captain: "", tasks: [], queuedCount: 0, doneCount: 0, projectsCount: 0,
            watcher: WatcherHealth(status: "off")))
        check(unread.isStale && unread.items.allSatisfy { !$0.reading.isKnown } && unread.ring == nil,
              "no firstmate home draws zeroes (GL-14)", &ok)
    }
}

#endif
