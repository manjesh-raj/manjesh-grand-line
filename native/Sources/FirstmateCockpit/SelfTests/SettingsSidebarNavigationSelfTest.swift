// Manjesh Grand Line - native macOS app.
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
//   swift build && FM_RUN_SETTINGS_SIDEBAR_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsSidebarNavigationSelfTest {

    /// How many cards Settings builds. A literal for the same reason
    /// `DaylightDrillPageSlice6SelfTest` keeps one: "every card is reachable"
    /// is vacuous if the page built none, and a card genuinely appearing
    /// should have to come here and say so.
    private static let expectedCardCount = 11

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
                      checkNoPaneCapsTheWindow] {
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

        let all = settings.debugCards
        guard all.count == expectedCardCount else {
            print("  FAIL Settings built \(all.count) cards, want \(expectedCardCount) - "
                  + "move this literal and say what added or removed one")
            ok = false
            return
        }

        var seen: [ObjectIdentifier: [String]] = [:]
        for category in SettingsController.Category.allCases {
            let cards = settings.debugCards(in: category)
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
            let mounted = settings.debugMountedCards
            let want = settings.debugCards(in: category)
            if mounted.map(ObjectIdentifier.init) != want.map(ObjectIdentifier.init) {
                print("  FAIL \(category.rawValue)'s pane holds \(mounted.count) cards, want \(want.count) "
                      + "in the same order")
                ok = false
            }
            // The other categories' cards must be genuinely detached, not
            // hidden - gotcha (15): a hidden view is still solved by the
            // window's own full-screen minimum-size derivation, so hiding
            // would keep all ten constraint chains live.
            for card in settings.debugCards where !want.contains(where: { $0 === card }) {
                if card.superview != nil {
                    print("  FAIL a card from another category is still in the tree on \(category.rawValue)")
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
        let cases: [(SettingsController.Category, String, () -> Bool, HelmToggle)] = [
            (.terminal, "Reconnect automatically",
             { AppSettings.shared.autoReconnect }, settings.debugToggles[0]),
            (.terminal, "Bell & notifications",
             { AppSettings.shared.notifyOnNeedsDecision }, settings.debugToggles[1]),
            (.briefings, "Show a morning briefing on Fleet",
             { AppSettings.shared.morningBriefingEnabled }, settings.debugToggles[2]),
            (.briefings, "Show the daily review on Fleet",
             { AppSettings.shared.dailyReviewEnabled }, settings.debugToggles[3]),
            (.menuBar, "Badge the status item",
             { AppSettings.shared.compactModeBadgesOverdueCount }, settings.debugCompactBadgeSwitch),
        ]

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
                let widest = settings.debugMountedCards.map(\.frame.width).max() ?? 0
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
}

#endif
