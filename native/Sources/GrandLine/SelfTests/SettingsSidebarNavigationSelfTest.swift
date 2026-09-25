// Grand Line - native macOS app.
//
// `fm/grandline-settings-page-sidebar-redesign`'s own suite: Settings is a
// sidebar-navigated master/detail page now, not one continuously-scrolling
// column of ten cards.
//
// The redesign's whole risk is **silent loss of reach**. A page that used to
// put every setting in one scroll now puts each behind a category, and the
// failure mode is not a crash or a visibly broken layout - it is a toggle
// that still exists, still has its target/action, still syncs in
// `refreshFromSettings`, and simply has no row that ever reveals it. Nothing
// about that is visible in a diff, in a build, or in a render of whichever
// pane happens to be selected. So every case here is about reach and about
// the controls still working, not about how the page looks:
//
//   1. **Every card is reachable, and each from exactly one category.** The
//      partition is asserted against the page's own card list, so a card
//      added without a category fails by name rather than going missing.
//   2. **Selecting a category really swaps the detail pane**, driven through
//      the sidebar's own row (a real `HoverHighlightView` press, the path a
//      click, a keyboard activation and VoiceOver all take), never by
//      calling `select(_:)` behind the component's back.
//   3. **The selection is visible.** A nav column whose rows all look
//      identical is not navigation; the selected row's fill has to differ
//      from a resting row's, on both a Daylight and a legacy palette.
//   4. **The drill header names the category**, which is the reference
//      mockup's "Settings / Shortcuts & Siri" - and is also the only thing
//      on screen that says where you are once the pane has scrolled.
//   5. **Every control still works.** One representative control per
//      category is exercised end to end against `AppSettings`: the toggle is
//      flipped through its own action and the stored value is read back, so
//      "the page renders" and "the page works" are different claims and this
//      file makes the second one.
//   6. **A pane does not cap the window.** Ten cards behind seven categories
//      is ten new chances at AGENTS.md gotcha (13); the detail column's
//      width cap is a `<=`, which can never be a floor, and this measures
//      that rather than trusting it.
//
// Window-backed on purpose (and so listed in `NEEDS_SESSION`): every case
// reads real rendered geometry or drives a real press through
// `HoverHighlightView`, which is hover/press behaviour, not pure logic.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_SIDEBAR_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsSidebarNavigationSelfTest {

    /// How many cards Settings builds. A literal for the same reason
    /// `DaylightDrillPageSlice6SelfTest` keeps one: "every card is reachable"
    /// is vacuous if the page built none, and a card genuinely appearing
    /// should have to come here and say so.
    ///
    /// Twenty-four since `fm/grandline-capture-global-hotkey-configurable`
    /// added the Capture page's two (Shortcut, System-wide access).
    private static let expectedCardCount = 24

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var allOK = true
        for check in [checkEveryCardIsReachableFromExactlyOneCategory,
                      checkARowClickSwapsTheDetailPane,
                      checkTheSelectedRowIsVisiblyDifferent,
                      checkTheDrillHeaderNamesTheCategory,
                      checkEveryCategorysControlsStillWork,
                      checkNoPaneCapsTheWindow,
                      checkEveryThemeSeparatesTheBandFromTheGround,
                      checkTheBandIsPaintedApartFromTheContent,
                      checkTheDividerIsPainted,
                      checkEveryRowCarriesItsOwnColouredTile,
                      checkTheHeaderEndsWhereItsColumnEnds,
                      checkTheColumnIsCentredInTheVisibleSpace] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SettingsSidebarNavigationSelfTest: all checks passed"
                    : "SettingsSidebarNavigationSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// Scratch store files and a scratch `UserDefaults` suite, so nothing
    /// here can reach the captain's real data or preferences - the
    /// convention every store-backed suite in this repo follows.
    private static func scratchStores() -> (HostStore, SSHKeyStore, SnippetStore, DictationStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-sidebar-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
        return (HostStore(), SSHKeyStore(), SnippetStore(), DictationStore())
    }

    private static func makeSettings() -> SettingsController {
        let (hosts, keys, snippets, dictation) = scratchStores()
        return SettingsController(hostStore: hosts, keyStore: keys,
                                  snippetStore: snippets, dictationStore: dictation)
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1400,
                              height: CGFloat = 900) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: height)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// The sidebar row for `category`, found by the identifier
    /// `HelmPageSidebar` stamps on each row - the same string the page
    /// supplies as the row's id, so this cannot drift from the production
    /// mapping.
    private static func row(for category: SettingsController.Category,
                            in settings: SettingsController) -> HoverHighlightView? {
        var found: HoverHighlightView?
        func walk(_ view: NSView) {
            if let hover = view as? HoverHighlightView,
               hover.identifier?.rawValue == category.rawValue {
                found = hover
            }
            for child in view.subviews { walk(child) }
        }
        walk(settings.debugSidebar)
        return found
    }

    /// Drive a row the way a captain does: the component's own handler by
    /// row id (`HelmPageSidebar.debugClickRow(id:)` calls the same `pick`
    /// the click gesture does), not `SettingsController.select(_:)`. A test
    /// that moved the page's model directly would pass with the sidebar
    /// unwired.
    @discardableResult
    private static func click(_ category: SettingsController.Category,
                              in settings: SettingsController) -> Bool {
        guard settings.debugSidebar.debugRowIndex(id: category.rawValue) != nil else { return false }
        settings.debugSidebar.debugClickRow(id: category.rawValue)
        settings.view.layoutSubtreeIfNeeded()
        return true
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    // MARK: 1. Reach

    private static func checkEveryCardIsReachableFromExactlyOneCategory(_ ok: inout Bool) {
        print("\n-- every settings card is reachable from exactly one category --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        let all = settings.debugGroupCards
        guard all.count == expectedCardCount else {
            print("  FAIL Settings built \(all.count) cards, want \(expectedCardCount) - "
                  + "move this literal and say what added or removed one")
            ok = false
            return
        }

        var seen: [ObjectIdentifier: [String]] = [:]
        for category in SettingsController.Category.allCases {
            let cards = settings.debugGroupCards(in: category)
            if cards.isEmpty {
                print("  FAIL category \(category.rawValue) shows no cards at all")
                ok = false
            }
            for card in cards { seen[ObjectIdentifier(card), default: []].append(category.rawValue) }
        }
        for card in all {
            let owners = seen[ObjectIdentifier(card)] ?? []
            if owners.isEmpty {
                print("  FAIL a card (\(card.debugHeaderTitle ?? "untitled")) belongs to no category - "
                      + "it is built, wired, and unreachable")
                ok = false
            } else if owners.count > 1 {
                print("  FAIL a card (\(card.debugHeaderTitle ?? "untitled")) is in \(owners.joined(separator: ", "))")
                ok = false
            }
        }
        // And every category has a row. A category with no row is the same
        // defect one level up.
        for category in SettingsController.Category.allCases where row(for: category, in: settings) == nil {
            print("  FAIL category \(category.rawValue) has no sidebar row")
            ok = false
        }
        if ok {
            print("  ok   \(all.count) cards across \(SettingsController.Category.allCases.count) categories, "
                  + "each in exactly one, each with a row")
        }
    }

    // MARK: 2. Navigation

    private static func checkARowClickSwapsTheDetailPane(_ ok: inout Bool) {
        print("\n-- clicking a sidebar row swaps the detail pane to that category --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        for category in SettingsController.Category.allCases {
            guard click(category, in: settings) else {
                print("  FAIL no row for \(category.rawValue)")
                ok = false
                continue
            }

            if settings.debugSelectedCategory != category {
                print("  FAIL clicking \(category.rawValue) left the page on "
                      + "\(settings.debugSelectedCategory.rawValue)")
                ok = false
            }
            if settings.debugSidebar.selection != category.rawValue {
                print("  FAIL the sidebar's own selection is \(settings.debugSidebar.selection ?? "nil") "
                      + "after clicking \(category.rawValue)")
                ok = false
            }
            let mounted = settings.debugMountedGroupCards
            let want = settings.debugGroupCards(in: category)
            if mounted.map(ObjectIdentifier.init) != want.map(ObjectIdentifier.init) {
                print("  FAIL \(category.rawValue)'s pane holds \(mounted.count) cards, want \(want.count) "
                      + "in the same order")
                ok = false
            }
            // The other pages must be genuinely detached, not hidden -
            // gotcha (15): a hidden view is still walked by the window's own
            // full-screen minimum-size derivation, so hiding would keep every
            // page's constraint chains live.
            //
            // **Asserted as "no path to the window", not "no superview".**
            // Detachment happens one level up now: a page keeps its own
            // section/card subtree assembled and it is the *page* that is
            // pulled out of the detail pane, so an unmounted card still has a
            // superview and always did. What gotcha (15) is actually about is
            // whether the window's constraint solve can reach it, and
            // `window == nil` is that question asked directly.
            for card in settings.debugGroupCards where !want.contains(where: { $0 === card }) {
                if card.window != nil {
                    print("  FAIL a card from another category still reaches the window on \(category.rawValue)")
                    ok = false
                    break
                }
            }
            // And the pane really rendered - a swap that mounts the right
            // cards at zero height is not a working pane.
            if mounted.contains(where: { $0.frame.height < 1 || $0.frame.width < 1 }) {
                print("  FAIL \(category.rawValue) mounted a card that never laid out")
                ok = false
            }
        }
        if ok { print("  ok   all \(SettingsController.Category.allCases.count) categories swap on a real row press") }
    }

    // MARK: 3. The selection is visible

    private static func checkTheSelectedRowIsVisiblyDifferent(_ ok: inout Bool) {
        print("\n-- the selected category's row is painted differently from a resting row --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        let daylight = HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
        let legacy = HelmTheme.allThemes.first { !$0.isDaylight } ?? HelmTheme.allThemes[0]

        for theme in [daylight, legacy] {
            ThemeManager.shared.setTheme(theme)
            let settings = makeSettings()
            let window = mount(settings)
            defer { _ = window }

            let selected = settings.debugSelectedCategory
            guard let other = SettingsController.Category.allCases.first(where: { $0 != selected }),
                  let selectedRow = row(for: selected, in: settings),
                  let restingRow = row(for: other, in: settings) else {
                print("  FAIL \(theme.id): could not find a selected and a resting row")
                ok = false
                continue
            }
            settings.view.layoutSubtreeIfNeeded()

            let selectedFill = selectedRow.layer?.backgroundColor
            let restingFill = restingRow.layer?.backgroundColor
            // Discriminating power first: a selected fill that is nil or
            // fully transparent cannot differ from anything, and would let
            // this case pass on a component that stopped painting selection
            // at all.
            let selectedAlpha = selectedFill.map { $0.alpha } ?? 0
            if selectedAlpha < 0.01 {
                print("  FAIL \(theme.id): the selected row has no fill at all (alpha \(fmt(selectedAlpha)))")
                ok = false
                continue
            }
            if let a = selectedFill, let b = restingFill, a == b {
                print("  FAIL \(theme.id): the selected row is painted exactly like a resting one")
                ok = false
                continue
            }
            print("  ok   \(theme.id): selected fill alpha \(fmt(selectedAlpha)), resting "
                  + "\(fmt(restingFill.map { $0.alpha } ?? 0))")
        }
    }

    // MARK: 4. The header

    private static func checkTheDrillHeaderNamesTheCategory(_ ok: inout Bool) {
        print("\n-- the drill header's subtitle follows the selected category --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        var refreshes = 0
        settings.onDrillSubtitleChanged = { refreshes += 1 }

        var subtitles: [String] = []
        for category in SettingsController.Category.allCases {
            guard click(category, in: settings) else { continue }
            let subtitle = settings.drillHeaderSubtitle ?? ""
            subtitles.append(subtitle)
            if !subtitle.hasPrefix(category.title) {
                print("  FAIL on \(category.rawValue) the subtitle reads \"\(subtitle)\"")
                ok = false
            }
            // The one fact this page's own caption used to carry, and the
            // reason the subtitle is not just the category name.
            if !subtitle.contains("stored locally on this machine") {
                print("  FAIL the subtitle dropped the locality fact: \"\(subtitle)\"")
                ok = false
            }
        }
        // Vacuity: identical subtitles everywhere would satisfy a sloppier
        // version of the prefix check above.
        if Set(subtitles).count != SettingsController.Category.allCases.count {
            print("  FAIL \(Set(subtitles).count) distinct subtitles across "
                  + "\(SettingsController.Category.allCases.count) categories")
            ok = false
        }
        // The shell owns the header, so the page has to *ask* for a re-read.
        // A subtitle that is correct when asked but never announced leaves
        // the header naming whichever category the captain arrived on.
        if refreshes < SettingsController.Category.allCases.count - 1 {
            print("  FAIL the page announced \(refreshes) subtitle changes across "
                  + "\(SettingsController.Category.allCases.count) selections")
            ok = false
        }
        if ok { print("  ok   \(subtitles.count) categories, \(refreshes) announced changes") }
    }

    // MARK: 5. The controls still work

    /// One representative control per category, driven through its own
    /// action and read back off `AppSettings`.
    ///
    /// Written as "flip it, read it, flip it back" rather than against a
    /// fixed expected value, so the case does not depend on what the
    /// preference happened to be - and so it leaves the domain as it found
    /// it, which matters because these suites share one real `UserDefaults`
    /// domain (AGENTS.md's hermeticity note).
    private static func checkEveryCategorysControlsStillWork(_ ok: inout Bool) {
        print("\n-- a representative control in every category still writes through --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        // (category, a human name, read, the toggle that drives it)
        //
        // Each toggle is reached by **name**, never by an index into
        // `debugToggles`: that array's order is the page's reading order, so
        // an index silently starts pointing at a different switch the moment
        // a row moves - which is how this case came to press "Follow system
        // appearance" and report that Reconnect automatically was broken.
        let cases: [(SettingsController.Category, String, () -> Bool, HelmToggle)] = [
            (.terminal, "Reconnect automatically",
             { AppSettings.shared.autoReconnect }, settings.debugAutoReconnectSwitch),
            (.terminal, "Bell & notifications",
             { AppSettings.shared.notifyOnNeedsDecision }, settings.debugNotifySwitch),
            (.briefings, "Show a morning briefing on Fleet",
             { AppSettings.shared.morningBriefingEnabled }, settings.debugMorningBriefingSwitch),
            (.briefings, "Show the daily review on Fleet",
             { AppSettings.shared.dailyReviewEnabled }, settings.debugDailyReviewSwitch),
            (.menuBar, "Badge the status item",
             { AppSettings.shared.compactModeBadgesOverdueCount }, settings.debugCompactBadgeSwitch),
        ]

        // The badge row is a *dependent* row of "Live in the menu bar" now
        // (`fm/grandline-settings-page-redesign`), so it is deliberately
        // inert while that switch is off - which is exactly the state a fresh
        // domain is in. Turning the parent on is what makes the case measure
        // the wiring rather than the dimming; the dimming itself has its own
        // case in `SettingsRedesignSelfTest`.
        let compactBefore = AppSettings.shared.compactModeEnabled
        defer {
            AppSettings.shared.compactModeEnabled = compactBefore
            settings.debugCompactModeSwitch.isOn = compactBefore
        }
        if !compactBefore {
            _ = settings.debugCompactModeSwitch.accessibilityPerformPress()
        }

        for (category, name, read, toggle) in cases {
            guard click(category, in: settings) else {
                print("  FAIL no row for \(category.rawValue)")
                ok = false
                continue
            }

            // `accessibilityPerformPress` is the real activation path a
            // click, a keyboard press and VoiceOver all take - assigning
            // `isOn` alone would prove nothing about the wiring.
            let before = read()
            _ = toggle.accessibilityPerformPress()
            let after = read()
            if after == before {
                print("  FAIL \(category.rawValue)/\(name): pressing the toggle did not change "
                      + "the stored value (\(before))")
                ok = false
            }
            if toggle.isOn != after {
                print("  FAIL \(category.rawValue)/\(name): the control reads \(toggle.isOn) "
                      + "while the setting reads \(after)")
                ok = false
            }
            _ = toggle.accessibilityPerformPress()
            if read() != before {
                print("  FAIL \(category.rawValue)/\(name): could not be restored to \(before)")
                ok = false
            }
        }

        // The Appearance card's theme grid is not a toggle, so it gets its
        // own end-to-end: it is the one control on this page whose effect is
        // visible everywhere else in the app.
        if click(.appearance, in: settings) {
            let before = ThemeManager.shared.theme
            let target = HelmTheme.allThemes.first { $0.id != before.id }
            if let target {
                ThemeManager.shared.setTheme(target)
                if ThemeManager.shared.theme.id != target.id {
                    print("  FAIL the theme did not change to \(target.id)")
                    ok = false
                }
                // And the grid really rebuilt against the pane it is in -
                // `debugAppearanceGridColumnCounts` is empty if the grid
                // never laid out, which is what a pane that mounts its card
                // without giving it a width produces.
                if settings.debugAppearanceGridColumnCounts.isEmpty {
                    print("  FAIL the Appearance card's theme grid did not lay out inside its pane")
                    ok = false
                }
                ThemeManager.shared.setTheme(before)
            }
        }

        // The Connection card's working-directory field, which is the one
        // control with a text-field commit path rather than an action.
        if click(.terminal, in: settings) {
            let fields = allTextFields(in: settings.view).filter { $0.isEditable }
            if fields.isEmpty {
                print("  FAIL the Terminal pane shows no editable field - the working directory chooser is gone")
                ok = false
            }
        }

        if ok { print("  ok   \(cases.count) toggles, the theme grid and the working-directory field all still work") }
    }

    private static func allTextFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for child in view.subviews { found += allTextFields(in: child) }
        return found
    }

    // MARK: 6. No window cap

    private static func checkNoPaneCapsTheWindow(_ ok: inout Bool) {
        print("\n-- no category's pane caps how wide or narrow the window may get --")
        let settings = makeSettings()
        let window = mount(settings, width: 1400)
        defer { _ = window }

        for category in SettingsController.Category.allCases {
            guard click(category, in: settings) else { continue }

            for width in [820.0, 1600.0] as [CGFloat] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                settings.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                settings.view.layoutSubtreeIfNeeded()
                let got = window.frame.width
                if abs(got - width) > 1 {
                    print("  FAIL \(category.rawValue) forced the window to \(fmt(got))pt when asked for "
                          + "\(fmt(width))pt - gotcha (13)")
                    ok = false
                }
                // And the detail column really is capped rather than tracking
                // the window forever, which is the other half of the change.
                let widest = settings.debugMountedGroupCards.map(\.frame.width).max() ?? 0
                if widest > 940 {
                    print("  FAIL \(category.rawValue)'s cards render \(fmt(widest))pt wide at a "
                          + "\(fmt(width))pt window - the column cap is not holding")
                    ok = false
                }
                if widest < 1 {
                    print("  FAIL \(category.rawValue) laid out no card at \(fmt(width))pt")
                    ok = false
                }
            }
        }
        if ok { print("  ok   every pane holds 820pt and 1600pt, with the card column capped") }
    }

    // MARK: 7. The nav column reads as its own region

    /// The token half, swept over **every** palette rather than a sample.
    ///
    /// Cheap enough to be exhaustive, and exhaustive is what matters here:
    /// the defect this guards is "the band and the ground are the same
    /// colour", and a palette-derived tone can collapse in one family while
    /// every other family stays fine. The pixel check below proves the tone
    /// actually reaches the screen; this one proves there is a tone to reach
    /// it in all twenty-six.
    private static func checkEveryThemeSeparatesTheBandFromTheGround(_ ok: inout Bool) {
        print("\n-- every palette's side-panel tone is a real step off its own page ground --")
        var worst = (id: "", ratio: Double.greatestFiniteMagnitude)
        for theme in HelmTheme.allThemes {
            let ground = HelmTheme.nsColor(theme.backgroundHex)
            let band = HelmTheme.sidePanelFill(theme)
            let ratio = HelmContrast.ratio(band, ground)
            if ratio < worst.ratio { worst = (theme.id, ratio) }
            // A hair under the floor, because the bisection lands *on* it and
            // the last step is a float.
            if ratio < HelmTheme.sidePanelSeparation - 0.001 {
                print(String(format: "  FAIL %@: the band measures %.4f against its own ground - below the %.2f floor",
                             theme.id, ratio, HelmTheme.sidePanelSeparation))
                ok = false
            }
            // The other direction, and the one a naive "blend the card into
            // the ground" derivation would fail: the tone must not simply be
            // the card either, or a palette where `chromeBackgroundHex ==
            // backgroundHex` renders the band invisible again.
            if HelmContrast.ratio(band, HelmTheme.nsColor(theme.chromeBackgroundHex)) < 1.001,
               theme.chromeBackgroundHex == theme.backgroundHex {
                print("  FAIL \(theme.id): the band resolved to the card, which in this palette is the ground")
                ok = false
            }
        }
        print(String(format: "  ok   %d palettes; the closest is %@ at %.4f (floor %.2f)",
                     HelmTheme.allThemes.count, worst.id, worst.ratio, HelmTheme.sidePanelSeparation))
    }

    /// The painted half: a real Settings page rendered off-screen, with the
    /// band's own pixels and the content region's own pixels read back out of
    /// the bitmap.
    ///
    /// **Assert what is painted, not what was computed.** A check that only
    /// read `HelmTheme.sidePanelFill` would pass with the band view deleted,
    /// never added to the page, left transparent, or covered by the scroll
    /// view - which is the whole defect being fixed. So this samples the
    /// render, and its vacuity guards assert that each sample really landed
    /// in the region it claims.
    private static func checkTheBandIsPaintedApartFromTheContent(_ ok: inout Bool) {
        print("\n-- the nav column's band and the content region are painted different colours --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        // One dark and one light out of several families, plus Daylight and
        // Dusk, so a fix that only works in one register or one family fails
        // here. Not all twenty-six: each entry is a full page render, and the
        // token sweep above already covers every palette.
        let sampled = ["daylight", "dusk", "helm-dark", "helm-light",
                       "nord-polar", "nord-snow", "dracula", "alucard",
                       "one-dark", "one-light", "oxocarbon-dark", "oxocarbon-light",
                       "gruvbox-light", "tokyo-night-dark", "tokyo-night-light"]
        var measured = 0
        for id in sampled {
            guard let theme = HelmTheme.theme(id: id) else {
                print("  FAIL no such theme: \(id)")
                ok = false
                continue
            }
            // Mandatory around a repeated AppKit construct/teardown loop in a
            // headless suite: nothing turns the run loop, so removed views are
            // never drained.
            autoreleasepool {
                ThemeManager.shared.setTheme(theme)
                let settings = makeSettings()
                let window = mount(settings)
                defer { window.contentView = nil }
                let root = settings.view
                root.layoutSubtreeIfNeeded()

                guard root.bounds.width > 10, root.bounds.height > 10 else {
                    print("  FAIL \(id): the page never laid out (\(root.bounds)) - the sample would be vacuous")
                    ok = false
                    return
                }
                guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                    print("  FAIL \(id): could not build a bitmap rep")
                    ok = false
                    return
                }
                root.cacheDisplay(in: root.bounds, to: rep)

                // The rep is measured in **pixels**, not points - a factor of
                // two on a retina machine, so sampling point coordinates
                // without this lands in the top-left quadrant of the render.
                let scaleX = CGFloat(rep.pixelsWide) / root.bounds.width
                let scaleY = CGFloat(rep.pixelsHigh) / root.bounds.height
                let band = settings.debugSidebarPanel.frame
                let cards = settings.debugPageContainerFrameInRoot

                // Both samples share one y: the bare strip above the toolbar,
                // which is page ground on the content side at every window
                // size and is inside the band on the column side, because the
                // band runs the page's full height. One y means the comparison
                // cannot be an artefact of two different rows.
                let y = root.bounds.maxY - HelmMetrics.s3 / 2
                let bandX = band.midX
                let contentX = band.maxX + HelmMetrics.s5

                // `SettingsController`'s root is a plain unflipped `NSView`,
                // so the rep's row 0 is the view's top edge - the row mirrors.
                func sample(_ x: CGFloat) -> NSColor? {
                    let px = Int(x * scaleX)
                    let py = Int((root.bounds.height - y) * scaleY)
                    guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { return nil }
                    return rep.colorAt(x: px, y: py)
                }

                // Discriminating power, before any colour is compared.
                guard band.width > 40, band.height > root.bounds.height - 1,
                      contentX < root.bounds.maxX,
                      !cards.insetBy(dx: -2, dy: -2).contains(NSPoint(x: contentX, y: y)) else {
                    print(String(format: "  FAIL %@: the sample points are not in the regions they claim"
                                 + " (band %@, content x %.1f, cards %@)",
                                 id, NSStringFromRect(band), contentX, NSStringFromRect(cards)))
                    ok = false
                    return
                }
                guard let bandPixel = sample(bandX), let contentPixel = sample(contentX) else {
                    print("  FAIL \(id): a sample point fell outside the rep")
                    ok = false
                    return
                }

                // Compared in **`rep.colorSpace`**, never by converting the
                // samples into sRGB: `bitmapImageRepForCachingDisplay` returns
                // a rep in the display's own profile inside a real window, and
                // the sRGB conversion is only correct outside one.
                guard let expectedBand = HelmTheme.sidePanelFill(theme).usingColorSpace(rep.colorSpace),
                      let expectedGround = HelmTheme.nsColor(theme.backgroundHex).usingColorSpace(rep.colorSpace) else {
                    print("  FAIL \(id): could not express the expected colours in the rep's space")
                    ok = false
                    return
                }

                // 1. The content side really is the page ground, so "they
                //    differ" below is a claim about the band and not about
                //    having sampled some card.
                if distance(contentPixel, expectedGround) >= 0.06 {
                    print(String(format: "  FAIL %@: the content sample is %.4f off the palette's ground - not ground",
                                 id, distance(contentPixel, expectedGround)))
                    ok = false
                    return
                }
                // 2. The band side really is the derived tone - i.e. the view
                //    exists, is in the tree, is opaque and is on top of the
                //    ground rather than under the scroll view.
                if distance(bandPixel, expectedBand) >= 0.06 {
                    print(String(format: "  FAIL %@: the band sample is %.4f off `sidePanelFill` -"
                                 + " the band is not being painted", id, distance(bandPixel, expectedBand)))
                    ok = false
                    return
                }
                // 3. And the two are a real, measurable distance apart. This
                //    is the captain's own report: "there is literally nothing
                //    ... which differentiate".
                //
                //    **Measured on the rep's own raw components, never via
                //    `usingColorSpace(.sRGB)`** - AGENTS.md's rule, and it
                //    bites here rather than theoretically. `HelmContrast`'s
                //    `NSColor` overload converts to sRGB internally, so the
                //    tuple overload is what keeps this in the rep's space. An
                //    earlier revision of this check used the `NSColor` one and
                //    reported 1.0597 for Daylight and 1.1305 for Dusk against
                //    a token separation of exactly 1.0800 in both - i.e. the
                //    display profile deflating every light palette below the
                //    floor and inflating every dark one above it, which reads
                //    as a real colour bug in eight themes and as a suspiciously
                //    generous margin in seven. On raw components the same two
                //    measure 1.0753 and 1.0801.
                //
                //    The floor carries a 0.01 allowance for the bitmap's 8-bit
                //    quantisation, which is the whole of the remaining gap
                //    (worst measured: Daylight at 1.0753). The *perceptual*
                //    1.08 in true sRGB is not weakened by that - it is
                //    asserted exhaustively, on all twenty-six palettes, by
                //    `checkEveryThemeSeparatesTheBandFromTheGround` above.
                //    This check's job is that the render actually paints it.
                func raw(_ color: NSColor) -> (Double, Double, Double) {
                    (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
                }
                let ratio = HelmContrast.ratio(raw(bandPixel), raw(contentPixel))
                if ratio < HelmTheme.sidePanelSeparation - 0.01 {
                    print(String(format: "  FAIL %@: the painted band and the painted content measure %.4f apart,"
                                 + " below the %.2f floor - they read as one flat surface",
                                 id, ratio, HelmTheme.sidePanelSeparation))
                    ok = false
                    return
                }
                measured += 1
                print(String(format: "  ok   %@: band/content %.4f apart", id, ratio))
            }
        }
        // The loop itself must not be able to measure nothing.
        if measured < sampled.count {
            print("  FAIL only \(measured) of \(sampled.count) palettes were actually measured")
            ok = false
        }
    }

    /// The hairline, which is what carries the boundary in a palette that
    /// lands near the separation floor.
    private static func checkTheDividerIsPainted(_ ok: inout Bool) {
        print("\n-- a hairline closes the band, and is its own colour --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        for id in ["dusk", "daylight", "helm-dark", "helm-light"] {
            guard let theme = HelmTheme.theme(id: id) else { continue }
            autoreleasepool {
                ThemeManager.shared.setTheme(theme)
                let settings = makeSettings()
                let window = mount(settings)
                defer { window.contentView = nil }
                settings.view.layoutSubtreeIfNeeded()

                let edge = settings.debugSidebarEdge
                let band = settings.debugSidebarPanel
                // It exists, it is in the page, it is a real hairline and it
                // sits exactly on the band's trailing edge.
                guard edge.superview != nil, !edge.isHidden,
                      edge.frame.width >= 1, edge.frame.height > 100,
                      abs(edge.frame.minX - band.frame.maxX) < 0.6 else {
                    print("  FAIL \(id): the divider is missing or misplaced"
                          + " (edge \(NSStringFromRect(edge.frame)), band \(NSStringFromRect(band.frame)))")
                    ok = false
                    return
                }
                guard let painted = edge.layer?.backgroundColor, painted.alpha > 0.2 else {
                    print("  FAIL \(id): the divider has no fill")
                    ok = false
                    return
                }
                // And it is not simply the band repainted, which would leave
                // no boundary at all.
                let edgeColor = NSColor(cgColor: painted)?.usingColorSpace(.sRGB)
                let bandColor = HelmTheme.sidePanelFill(theme).usingColorSpace(.sRGB)
                if let a = edgeColor, let b = bandColor, distance(a, b) < 0.03 {
                    print("  FAIL \(id): the divider is painted the same colour as the band")
                    ok = false
                    return
                }
                print("  ok   \(id): divider at x \(fmt(edge.frame.minX)), alpha \(fmt(painted.alpha))")
            }
        }
    }

    // MARK: 8. The rows carry colour

    /// Every nav row is led by a colour tile, and the tiles are not all one
    /// colour - which is the difference between a column you scan and a list
    /// you read.
    private static func checkEveryRowCarriesItsOwnColouredTile(_ ok: inout Bool) {
        print("\n-- every category's row is led by an `IconTileView` in that page's own hue --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        for id in ["dusk", "daylight"] {
            guard let theme = HelmTheme.theme(id: id) else { continue }
            autoreleasepool {
                ThemeManager.shared.setTheme(theme)
                let settings = makeSettings()
                let window = mount(settings)
                defer { window.contentView = nil }
                settings.view.layoutSubtreeIfNeeded()

                var fills: [(id: String, color: NSColor)] = []
                for category in SettingsController.Category.allCases {
                    guard let rowView = row(for: category, in: settings) else {
                        print("  FAIL \(id): no row for \(category.rawValue)")
                        ok = false
                        continue
                    }
                    let tiles = rowView.subviews.compactMap { $0 as? IconTileView }
                    guard tiles.count == 1, let tile = tiles.first else {
                        print("  FAIL \(id): \(category.rawValue)'s row carries \(tiles.count) tiles, wanted 1")
                        ok = false
                        continue
                    }
                    // The glyph really was built - a tile with no image is a
                    // coloured square, not an icon.
                    if tile.debugRenderedImage == nil {
                        print("  FAIL \(id): \(category.rawValue)'s tile rendered no symbol")
                        ok = false
                    }
                    guard let fill = tile.layer?.backgroundColor,
                          let color = NSColor(cgColor: fill)?.usingColorSpace(.sRGB) else {
                        print("  FAIL \(id): \(category.rawValue)'s tile has no fill")
                        ok = false
                        continue
                    }
                    fills.append((category.rawValue, color))
                }

                guard fills.count == SettingsController.Category.allCases.count else { return }
                // Seven tints across eight pages, so seven distinct fills is
                // the expected answer and anything less means two pages
                // collapsed onto one hue (or the tint stopped being read).
                var distinct: [NSColor] = []
                for entry in fills where !distinct.contains(where: { distance($0, entry.color) < 0.04 }) {
                    distinct.append(entry.color)
                }
                if distinct.count < 6 {
                    print("  FAIL \(id): the eight rows paint only \(distinct.count) distinct tiles")
                    ok = false
                    return
                }

                // **The assertion that actually encodes the requirement.**
                // Eight pages share seven tints and two of those tints are the
                // same hue in some palettes, so a distinct *count* is not the
                // goal - a column the eye can scan is, and that only breaks
                // when two rows read together are one colour. `allCases` is
                // the sidebar's own order (its sections are built by walking
                // `NavGroup` over it), so consecutive entries are consecutive
                // rows.
                var adjacentClash: String?
                for pair in zip(fills, fills.dropFirst())
                where distance(pair.0.color, pair.1.color) < 0.04 {
                    adjacentClash = "\(pair.0.id) and \(pair.1.id)"
                    break
                }
                if let adjacentClash {
                    print("  FAIL \(id): adjacent rows \(adjacentClash) paint the same tile -"
                          + " the column stops being scannable exactly there")
                    ok = false
                    return
                }
                print("  ok   \(id): \(fills.count) tiles, \(distinct.count) distinct hues,"
                      + " no two adjacent rows alike")
            }
        }
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }


    // MARK: 11. The header and the column it heads share one right edge

    /// `fm/grandline-settings-alignment-regression-fix`. The page toolbar -
    /// the breadcrumb on its left, "Saved on this Mac" on its right - is the
    /// header for the **capped** content column below it, not for the window.
    /// It was pinned to `root.trailingAnchor`, so on a wide window it spanned
    /// the whole page while the column stopped at `contentMaxWidth`: measured
    /// at a 1512pt window, the toolbar ended at 1488 against the column's own
    /// 936, and "Saved on this Mac" sat 552pt right of everything it labels.
    ///
    /// **Why this needs a window and not a fitting-size calculation.** The
    /// column's right edge is where Auto Layout actually resolved it against
    /// a real clip view - the cap binds or it does not depending on the
    /// window's width, and with "Show scroll bars: Always" a non-overlay
    /// scroller takes a real ~15pt bite out of that clip (gotcha (4)). Both
    /// widths are checked for that reason: 1512 is where the cap binds and
    /// the old bug was visible, 900 is where it does not and the clip view is
    /// what decides.
    ///
    /// **Discriminating power, asserted first.** At the wide window the two
    /// edges agreeing is only meaningful if the column is genuinely capped
    /// short of the page - if a future `contentMaxWidth` grew past the
    /// window, every category would trivially pass with the old constraint
    /// restored. So the wide pass fails loudly unless the column ends at
    /// least 100pt inside the page's own trailing gutter.
    private static func checkTheHeaderEndsWhereItsColumnEnds(_ ok: inout Bool) {
        print("-- the page header ends where its content column ends --")
        for (width, capMustBind) in [(CGFloat(1512), true), (CGFloat(900), false)] {
            autoreleasepool {
                let settings = makeSettings()
                let window = mount(settings, width: width, height: 950)
                defer { window.close() }
                for category in SettingsController.Category.allCases {
                    guard click(category, in: settings) else {
                        fail("\(category.rawValue) has no sidebar row to click", &ok)
                        continue
                    }
                    settings.view.layoutSubtreeIfNeeded()
                    let header = settings.debugToolbarFrameInRoot
                    let column = settings.debugPageContainerFrameInRoot
                    let pageEdge = settings.view.bounds.maxX - HelmMetrics.pageGutter

                    if capMustBind, column.maxX > pageEdge - 100 {
                        fail("\(category.rawValue) at \(fmt(width)): the column ends at "
                             + "\(fmt(column.maxX)) against a page edge of \(fmt(pageEdge)) - it is "
                             + "not capped short of the page here, so this comparison is vacuous", &ok)
                        continue
                    }
                    let delta = abs(header.maxX - column.maxX)
                    check(delta <= 0.5,
                          "\(category.rawValue) at \(fmt(width)): the header ends at "
                          + "\(fmt(header.maxX)) and its content column at \(fmt(column.maxX)) - "
                          + "\(fmt(delta))pt apart, so the header is not over the column it heads", &ok)
                    // The two also start together, which the leading
                    // constants already say - asserted so a future edit to
                    // either one cannot silently align only one end.
                    let leadDelta = abs(header.minX - column.minX)
                    check(leadDelta <= 0.5,
                          "\(category.rawValue) at \(fmt(width)): the header starts at "
                          + "\(fmt(header.minX)) and its column at \(fmt(column.minX))", &ok)
                    guard delta <= 0.5, leadDelta <= 0.5 else { continue }
                    print("  ok   \(category.rawValue) at \(fmt(width)): header "
                          + "\(fmt(header.minX))..\(fmt(header.maxX)), column "
                          + "\(fmt(column.minX))..\(fmt(column.maxX)), page edge \(fmt(pageEdge))")
                }
            }
        }
    }

    // MARK: 12. The column is centred, not left-pinned

    /// **The captain reported this three times.** Every settings page
    /// rendered flush against the sidebar with a large empty gap on the
    /// right only, because the content column was positioned by a required
    /// `leading == content.leading + pageGutter` underneath its width cap -
    /// deliberate left-alignment with a ceiling, so past the cap every extra
    /// point of window became slack on one side.
    ///
    /// Case 11 above cannot see this: it asserts the header and the column
    /// share both *ends*, which was true throughout - the two were left-
    /// pinned together. Nor can case 6, which only asserts the cap never
    /// becomes a window floor. Centring is a third, independent property and
    /// needs its own assertion.
    ///
    /// Measured against the sidebar's **visible** edge rather than the
    /// scroll area's leading edge, which are 25pt apart: `scroll.leading` is
    /// `sidebarColumn.trailing`, while `sidebarPanel` paints a further
    /// `pageGutter` past that column with `sidebarEdge`'s 1pt rule on top.
    /// The captain sees the panel, not the clip view, so the panel is what
    /// the margins have to be equal about - and a version of this check
    /// written against the clip view would pass on a page that visibly is
    /// not centred.
    private static func checkTheColumnIsCentredInTheVisibleSpace(_ ok: inout Bool) {
        print("-- the content column is centred in the space beside the sidebar --")
        // Counts the cases where the cap actually binds, so this cannot pass
        // vacuously on a run where every page happened to fill its pane -
        // at which point equal margins prove nothing about centring.
        var discriminating = 0
        for width in [CGFloat(1512), CGFloat(1400), CGFloat(1100)] {
            autoreleasepool {
                let settings = makeSettings()
                let window = mount(settings, width: width, height: 950)
                defer { window.close() }
                for category in SettingsController.Category.allCases {
                    guard click(category, in: settings) else {
                        fail("\(category.rawValue) has no sidebar row to click", &ok)
                        continue
                    }
                    settings.view.layoutSubtreeIfNeeded()
                    let root = settings.view
                    let edge = settings.debugSidebarEdge
                        .convert(settings.debugSidebarEdge.bounds, to: root)
                    let column = settings.debugPageContainerFrameInRoot
                    let header = settings.debugToolbarFrameInRoot
                    let left = column.minX - edge.maxX
                    let right = root.bounds.maxX - column.maxX

                    guard left > 0.5, right > 0.5 else {
                        fail("\(category.rawValue) at \(fmt(width)): the column runs "
                             + "\(fmt(column.minX))..\(fmt(column.maxX)) against a visible "
                             + "sidebar edge of \(fmt(edge.maxX)) and a page edge of "
                             + "\(fmt(root.bounds.maxX)) - one margin is gone entirely", &ok)
                        continue
                    }
                    if left > 40 { discriminating += 1 }

                    let delta = abs(left - right)
                    check(delta <= 0.5,
                          "\(category.rawValue) at \(fmt(width)): \(fmt(left))pt of visible "
                          + "margin on the left against \(fmt(right))pt on the right - "
                          + "\(fmt(delta))pt apart, so the column is not centred beside the "
                          + "sidebar", &ok)

                    // The header rides the same centre. Asserted here as well
                    // as in case 11 because that case compares the two to
                    // each other, and two equally off-centre things agree.
                    let headerLeft = header.minX - edge.maxX
                    let headerRight = root.bounds.maxX - header.maxX
                    let headerDelta = abs(headerLeft - headerRight)
                    check(headerDelta <= 0.5,
                          "\(category.rawValue) at \(fmt(width)): the header has "
                          + "\(fmt(headerLeft))pt of visible margin on the left against "
                          + "\(fmt(headerRight))pt on the right", &ok)

                    guard delta <= 0.5, headerDelta <= 0.5 else { continue }
                    print("  ok   \(category.rawValue) at \(fmt(width)): visible margins "
                          + "\(fmt(left)) / \(fmt(right)), column "
                          + "\(fmt(column.minX))..\(fmt(column.maxX))")
                }
            }
        }
        check(discriminating > 0,
              "no width x category combination left real slack beside the column, so every "
              + "equal-margin comparison above was vacuous - the fixture widths need raising "
              + "above the widest contentMaxWidth", &ok)
    }

}

#endif
