// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-settings-page-redesign`'s own suite: the five behaviours the
// captain's reference introduced that nothing in this repository could
// previously assert.
//
// `SettingsSidebarNavigationSelfTest` already covers what the *previous*
// redesign added - reach, the category partition, a real row press swapping
// the pane - and it still does. This file covers what is new, and every case
// is about something that can break silently:
//
//   1. **Sidebar search really filters, and says so when it matches nothing.**
//      A filter that quietly empties the list is indistinguishable from a
//      broken list, which is why the empty state is asserted as loudly as the
//      matches. The discriminating half matters most: the case first proves
//      the unfiltered list is *larger*, so a search that silently did nothing
//      cannot pass by leaving everything visible.
//   2. **Back and forward walk the real history.** Including the two things a
//      browser does that a naive stack does not: Back is disabled on the
//      first page, and navigating somewhere new from the middle of the
//      history truncates what was ahead.
//   3. **The theme grid renders the real catalogue, filters it, and selects.**
//      Every card is a real palette, the All/Dark/Light segments really
//      partition it, and pressing a card changes `ThemeManager`.
//   4. **A dependent row is dimmed AND inert.** The reference's `data-dep`.
//      Dimming alone is the dangerous half-fix: a row that says a setting
//      does not apply and then applies it is worse than no dimming at all, so
//      the case presses the disabled control and asserts the store did not
//      move.
//   6. **The wide page survives being narrowed and widened again.** It is the
//      one page laid out in two columns, and it collapses to one below a
//      breakpoint - so the two arrangements' constraints have to be swapped
//      rather than accumulated. Asserted across several resizes in both
//      directions, because a single collapse cannot see the defect.
//   5. **The secure fields reveal and re-mask**, through the one
//      `HelmRevealableSecretField` both OAuth rows use - and the reveal is
//      display-only, so the stored value is the same in both states.
//
// Window-backed on purpose (and so listed in `NEEDS_SESSION`): the search and
// history cases drive real `HoverHighlightView` presses and read painted
// state back, and the theme grid is measured after a real layout pass.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_REDESIGN_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsRedesignSelfTest {

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var allOK = true
        for check in [checkSearchFiltersTheSidebar,
                      checkBackAndForwardWalkTheHistory,
                      checkTheThemeGridRendersFiltersAndSelects,
                      checkADependentRowIsDimmedAndInert,
                      checkTheSecureFieldsRevealAndReMask,
                      checkTheWidePageCollapsesAndComesBack] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SettingsRedesignSelfTest: all checks passed"
                    : "SettingsRedesignSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func makeSettings() -> SettingsController {
        SettingsController(hostStore: HostStore(),
                           keyStore: SSHKeyStore(),
                           snippetStore: SnippetStore(),
                           dictationStore: DictationStore())
    }

    @discardableResult
    private static func mount(_ controller: SettingsController, width: CGFloat = 1200) -> NSWindow {
        // `OffScreenProbe.window` rather than a hand-rolled `NSWindow`: a
        // hand-rolled one is *not* off-screen whatever origin it is given,
        // and this suite runs on the captain's own display.
        let window = OffScreenProbe.window(width: width, height: 820)
        window.contentView?.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: content.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        controller.viewWillAppear()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: 1. Search

    private static func checkSearchFiltersTheSidebar(_ ok: inout Bool) {
        print("\n-- the sidebar's search field filters the page list --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        let everything = settings.debugVisibleCategories
        // Discriminating power first: a filter that did nothing at all would
        // pass every "contains" assertion below if the unfiltered list were
        // already the filtered one.
        guard everything.count == SettingsController.Category.allCases.count else {
            print("  FAIL the unfiltered sidebar shows \(everything.count) of "
                  + "\(SettingsController.Category.allCases.count) pages")
            ok = false
            return
        }

        // (typed text, the pages that must survive it)
        let cases: [(String, Set<SettingsController.Category>)] = [
            // A word only one page's keywords carry.
            ("sudo", [.security]),
            // A word two pages share, matched through keywords rather than
            // titles - neither page is called "shortcut".
            ("shortcut", [.terminal, .menuBar, .intents]),
            // A title match, and one that is not a prefix of the title.
            ("backup", [.backup]),
            // Case-insensitive, and matching a title word.
            ("TERMINAL", [.terminal]),
        ]

        for (typed, want) in cases {
            settings.debugSetSearchText(typed)
            let got = Set(settings.debugVisibleCategories)
            if got != want {
                print("  FAIL \"\(typed)\" left \(got.map(\.rawValue).sorted()), "
                      + "want \(want.map(\.rawValue).sorted())")
                ok = false
            }
            if settings.debugNoMatchVisible {
                print("  FAIL \"\(typed)\" showed the no-match message with \(got.count) matches")
                ok = false
            }
        }

        // The empty state. A filter that silently empties the column reads as
        // a broken column, which is why the reference draws a sentence there.
        settings.debugSetSearchText("zzzznothing")
        if !settings.debugVisibleCategories.isEmpty {
            print("  FAIL a nonsense search still left "
                  + "\(settings.debugVisibleCategories.count) pages")
            ok = false
        }
        if !settings.debugNoMatchVisible {
            print("  FAIL a nonsense search showed no pages and no explanation")
            ok = false
        }

        // Clearing restores everything, and the selection survived the whole
        // sequence - a filter that dropped the selected row would leave the
        // detail pane showing a page no row points at.
        settings.debugSetSearchText("")
        if settings.debugVisibleCategories.count != SettingsController.Category.allCases.count {
            print("  FAIL clearing the search left \(settings.debugVisibleCategories.count) pages")
            ok = false
        }
        if settings.debugSidebar.selection != settings.debugSelectedCategory.rawValue {
            print("  FAIL after filtering, the sidebar selects "
                  + "\(settings.debugSidebar.selection ?? "nil") while the pane shows "
                  + "\(settings.debugSelectedCategory.rawValue)")
            ok = false
        }
        if ok { print("  ok   \(cases.count) searches, an empty state, and the selection survives") }
    }

    // MARK: 2. History

    private static func checkBackAndForwardWalkTheHistory(_ ok: inout Bool) {
        print("\n-- back and forward walk the page history --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        // A fresh page is at the start of its own history: nothing behind and
        // nothing ahead.
        if settings.debugCanGoBack || settings.debugCanGoForward {
            print("  FAIL a fresh page offers back=\(settings.debugCanGoBack) "
                  + "forward=\(settings.debugCanGoForward)")
            ok = false
        }
        if settings.debugToolbarTitle != settings.debugSelectedCategory.title {
            print("  FAIL the toolbar reads \"\(settings.debugToolbarTitle)\" on "
                  + "\(settings.debugSelectedCategory.rawValue)")
            ok = false
        }

        settings.select(.terminal)
        settings.select(.security)
        guard settings.debugSelectedCategory == .security else {
            print("  FAIL two selections did not land on security")
            ok = false
            return
        }
        if !settings.debugCanGoBack || settings.debugCanGoForward {
            print("  FAIL after two selections: back=\(settings.debugCanGoBack) "
                  + "forward=\(settings.debugCanGoForward)")
            ok = false
        }

        settings.debugGoBack()
        if settings.debugSelectedCategory != .terminal {
            print("  FAIL back landed on \(settings.debugSelectedCategory.rawValue), want terminal")
            ok = false
        }
        // The toolbar title is the only thing on screen that says where you
        // are once the pane has scrolled, so it has to follow a history move
        // and not only a click.
        if settings.debugToolbarTitle != SettingsController.Category.terminal.title {
            print("  FAIL after back the toolbar reads \"\(settings.debugToolbarTitle)\"")
            ok = false
        }
        // And the sidebar's own selection has to follow too - a nav column
        // still highlighting the page you just left is worse than none.
        if settings.debugSidebar.selection != SettingsController.Category.terminal.rawValue {
            print("  FAIL after back the sidebar selects "
                  + "\(settings.debugSidebar.selection ?? "nil")")
            ok = false
        }
        if !settings.debugCanGoForward {
            print("  FAIL forward is disabled immediately after a back")
            ok = false
        }

        settings.debugGoBack()
        if settings.debugSelectedCategory != .appearance || settings.debugCanGoBack {
            print("  FAIL two backs: on \(settings.debugSelectedCategory.rawValue), "
                  + "back=\(settings.debugCanGoBack)")
            ok = false
        }

        settings.debugGoForward()
        if settings.debugSelectedCategory != .terminal {
            print("  FAIL forward landed on \(settings.debugSelectedCategory.rawValue), want terminal")
            ok = false
        }

        // The browser rule a naive stack gets wrong: navigating somewhere new
        // from the middle of the history discards what was ahead, rather than
        // leaving a Forward button pointing at a branch you left.
        settings.select(.backup)
        if settings.debugCanGoForward {
            print("  FAIL a new selection mid-history left forward enabled, pointing at "
                  + "\(settings.debugHistory.map(\.rawValue))")
            ok = false
        }
        if settings.debugHistory != [.appearance, .terminal, .backup] {
            print("  FAIL history is \(settings.debugHistory.map(\.rawValue)), "
                  + "want [appearance, terminal, backup]")
            ok = false
        }
        if ok { print("  ok   back, forward, the disabled ends, and forward truncation") }
    }

    // MARK: 3. The theme grid

    private static func checkTheThemeGridRendersFiltersAndSelects(_ ok: inout Bool) {
        print("\n-- the theme grid draws the real catalogue, filters it, and selects --")
        // A known starting palette, so "selecting changed the theme" cannot
        // pass by accident because the grid happened to start there.
        ThemeManager.shared.setTheme(.dusk)
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }
        settings.select(.appearance)
        settings.view.layoutSubtreeIfNeeded()

        let all = settings.debugThemeCards
        if all.count != HelmTheme.allThemes.count {
            print("  FAIL the grid drew \(all.count) cards for "
                  + "\(HelmTheme.allThemes.count) themes")
            ok = false
        }
        // Every card is a *real* palette, not a placeholder - the reference's
        // own 26 colours are illustrative and this is what says the grid is
        // reading the catalogue instead.
        for card in all where HelmTheme.theme(id: card.theme.id) == nil {
            print("  FAIL the grid drew a card for unknown theme \(card.theme.id)")
            ok = false
            break
        }
        // Exactly one card is the active one, and it is the active theme.
        let active = all.filter(\.isActive)
        if active.count != 1 || active.first?.theme.id != ThemeManager.shared.theme.id {
            print("  FAIL \(active.count) cards marked active, for "
                  + "\(active.map { $0.theme.id }) against \(ThemeManager.shared.theme.id)")
            ok = false
        }
        // The cards really rendered: a grid of zero-sized cards would satisfy
        // every count above.
        if all.contains(where: { $0.frame.height < 1 || $0.frame.width < 1 }) {
            print("  FAIL some theme cards laid out at zero size")
            ok = false
        }

        // The filter really partitions the catalogue, and the two halves add
        // back up to it.
        settings.debugSetThemeFilter("dark")
        settings.view.layoutSubtreeIfNeeded()
        let dark = settings.debugThemeCards
        settings.debugSetThemeFilter("light")
        settings.view.layoutSubtreeIfNeeded()
        let light = settings.debugThemeCards
        if dark.contains(where: { $0.theme.mode != .dark }) {
            print("  FAIL the Dark filter showed a light palette")
            ok = false
        }
        if light.contains(where: { $0.theme.mode != .light }) {
            print("  FAIL the Light filter showed a dark palette")
            ok = false
        }
        if dark.count + light.count != HelmTheme.allThemes.count {
            print("  FAIL Dark (\(dark.count)) + Light (\(light.count)) != "
                  + "\(HelmTheme.allThemes.count)")
            ok = false
        }
        if dark.isEmpty || light.isEmpty {
            print("  FAIL a filter emptied the grid - the check above would pass vacuously")
            ok = false
        }

        settings.debugSetThemeFilter("all")
        settings.view.layoutSubtreeIfNeeded()

        // Selecting: a real activation, not an assignment. The target is a
        // palette that is definitely not the current one.
        guard let target = settings.debugThemeCards
            .first(where: { $0.theme.id != ThemeManager.shared.theme.id }) else {
            print("  FAIL no card to select other than the active theme")
            ok = false
            return
        }
        let wanted = target.theme.id
        _ = target.hoverView.accessibilityPerformPress()
        if ThemeManager.shared.theme.id != wanted {
            print("  FAIL pressing the \(wanted) card left the theme on "
                  + "\(ThemeManager.shared.theme.id)")
            ok = false
        }
        settings.view.layoutSubtreeIfNeeded()
        // And the grid repainted: the checkmark has to move with the theme,
        // or the page shows one palette and claims another.
        let nowActive = settings.debugThemeCards.filter(\.isActive)
        if nowActive.count != 1 || nowActive.first?.theme.id != wanted {
            print("  FAIL after selecting \(wanted) the grid marks "
                  + "\(nowActive.map { $0.theme.id }) active")
            ok = false
        }
        if ok {
            print("  ok   \(all.count) real palettes, a partitioning filter, and a real selection")
        }
    }

    // MARK: 4. Dependent rows

    private static func checkADependentRowIsDimmedAndInert(_ ok: inout Bool) {
        print("\n-- a dependent row is dimmed and inert while its switch is off --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }

        let parentBefore = AppSettings.shared.compactModeEnabled
        let childBefore = AppSettings.shared.compactModeBadgesOverdueCount
        defer {
            AppSettings.shared.compactModeEnabled = parentBefore
            AppSettings.shared.compactModeBadgesOverdueCount = childBefore
        }

        settings.select(.menuBar)
        let dependents = settings.debugDependentRows(of: "compactMode")
        guard dependents.count == 2 else {
            print("  FAIL \"Live in the menu bar\" has \(dependents.count) dependent rows, want 2")
            ok = false
            return
        }

        // Off: dimmed, and - the half that matters - genuinely inert.
        AppSettings.shared.compactModeEnabled = true
        settings.debugCompactModeSwitch.isOn = true
        _ = settings.debugCompactModeSwitch.accessibilityPerformPress()   // -> off
        if settings.debugCompactModeSwitch.isOn {
            print("  FAIL could not switch compact mode off")
            ok = false
            return
        }
        for row in dependents where row.isRowEnabled {
            print("  FAIL a dependent row is still enabled with its switch off")
            ok = false
        }
        for row in dependents where row.alphaValue > 0.9 {
            print("  FAIL a dependent row is not dimmed (alpha \(row.alphaValue))")
            ok = false
        }
        // Press the disabled control and assert the store did not move.
        // Dimming without this is the dangerous half-fix: a row that says a
        // setting does not apply and then applies it.
        let badge = settings.debugCompactBadgeSwitch
        let storedBefore = AppSettings.shared.compactModeBadgesOverdueCount
        _ = badge.accessibilityPerformPress()
        if AppSettings.shared.compactModeBadgesOverdueCount != storedBefore {
            print("  FAIL pressing a disabled dependent switch still wrote through")
            ok = false
        }

        // On: live again, and now the same press does write.
        _ = settings.debugCompactModeSwitch.accessibilityPerformPress()   // -> on
        for row in dependents where !row.isRowEnabled {
            print("  FAIL a dependent row stayed disabled with its switch on")
            ok = false
        }
        for row in dependents where row.alphaValue < 0.99 {
            print("  FAIL a dependent row stayed dimmed (alpha \(row.alphaValue))")
            ok = false
        }
        _ = badge.accessibilityPerformPress()
        if AppSettings.shared.compactModeBadgesOverdueCount == storedBefore {
            print("  FAIL with its switch on, the dependent switch still does not write - "
                  + "the inert check above would pass vacuously")
            ok = false
        }

        // The same mechanism on the Appearance page's own pair, which is the
        // row the reference actually draws greyed out. A second dependency
        // key, so this is the registry rather than one hard-coded row.
        settings.select(.appearance)
        let pair = settings.debugDependentRows(of: "followSystemAppearance")
        guard pair.count == 1 else {
            print("  FAIL \"Follow system appearance\" has \(pair.count) dependent rows, want 1")
            ok = false
            return
        }
        let followBefore = AppSettings.shared.followSystemAppearance
        defer {
            AppSettings.shared.followSystemAppearance = followBefore
            settings.debugFollowSystemSwitch.isOn = followBefore
        }
        AppSettings.shared.followSystemAppearance = true
        settings.debugFollowSystemSwitch.isOn = true
        _ = settings.debugFollowSystemSwitch.accessibilityPerformPress()  // -> off
        if pair[0].isRowEnabled {
            print("  FAIL the light/dark pair stays live with Follow system appearance off")
            ok = false
        }
        if settings.debugSystemLightPopUp.isEnabled || settings.debugSystemDarkPopUp.isEnabled {
            print("  FAIL the pair's popups are still enabled inside a disabled row")
            ok = false
        }
        _ = settings.debugFollowSystemSwitch.accessibilityPerformPress()  // -> on
        if !pair[0].isRowEnabled || !settings.debugSystemLightPopUp.isEnabled {
            print("  FAIL the pair did not come back with Follow system appearance on")
            ok = false
        }
        if ok { print("  ok   two dependency keys, dimmed and inert in both directions") }
    }

    // MARK: 5. The secure fields

    private static func checkTheSecureFieldsRevealAndReMask(_ ok: inout Bool) {
        print("\n-- the OAuth fields reveal and re-mask, without changing what is stored --")
        let settings = makeSettings()
        let window = mount(settings)
        defer { _ = window }
        settings.select(.gmail)

        for (name, field) in [("client ID", settings.debugGmailClientIDField),
                              ("client secret", settings.debugGmailClientSecretField)] {
            // A value only in the control, never through the store: this case
            // is about the reveal, and writing a fabricated client ID into
            // the captain's real Keychain to test a display toggle would be
            // exactly the "never touch real captain data" rule.
            let probe = "probe-\(name.replacingOccurrences(of: " ", with: "-"))-value"
            field.stringValue = probe

            if field.isRevealed {
                print("  FAIL the \(name) field starts revealed")
                ok = false
            }
            field.toggleReveal()
            if !field.isRevealed {
                print("  FAIL the \(name) field did not reveal")
                ok = false
            }
            // Display-only: the value the store would see is the same in both
            // states, which is the claim that makes masking safe to apply to
            // a field the captain edits.
            if field.stringValue != probe {
                print("  FAIL revealing the \(name) changed its value to \"\(field.stringValue)\"")
                ok = false
            }
            field.toggleReveal()
            if field.isRevealed {
                print("  FAIL the \(name) field did not re-mask")
                ok = false
            }
            if field.stringValue != probe {
                print("  FAIL re-masking the \(name) changed its value to \"\(field.stringValue)\"")
                ok = false
            }
            field.stringValue = ""
        }
        if ok { print("  ok   both OAuth fields reveal, re-mask, and keep their value") }
    }

    // MARK: 6. The wide page's collapse

    private static func checkTheWidePageCollapsesAndComesBack(_ ok: inout Bool) {
        print("\n-- the wide page collapses when narrowed and comes back when widened --")
        let settings = makeSettings()
        // Wide enough that App Intents & Shortcuts is really two columns.
        let window = mount(settings, width: 1500)
        defer { _ = window }
        settings.select(.intents)
        settings.view.layoutSubtreeIfNeeded()

        /// How many distinct leading edges the page's cards sit at - which is
        /// how many columns it is actually showing.
        func columnCount() -> Int {
            Set(settings.debugMountedGroupCards.compactMap { card in
                card.superview.map {
                    ((($0.convert(card.frame.origin, to: settings.view)).x) * 10).rounded() / 10
                }
            }).count
        }

        guard columnCount() == 2 else {
            print("  FAIL at 1500pt the wide page shows \(columnCount()) columns, want 2 - "
                  + "the rest of this case would be vacuous")
            ok = false
            return
        }

        // Back and forth several times. One collapse cannot see the defect
        // this guards: the two arrangements' constraints were *added* rather
        // than swapped, so the stale full-width ties only conflict once the
        // page has been widened again.
        for (index, width) in [820.0, 1500.0, 900.0, 1500.0, 780.0, 1500.0].enumerated() {
            window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                                   width: width, height: window.frame.height),
                            display: true)
            settings.view.layoutSubtreeIfNeeded()
            let want = width >= 1000 ? 2 : 1
            let got = columnCount()
            if got != want {
                print("  FAIL resize \(index + 1) to \(Int(width))pt shows \(got) columns, want \(want)")
                ok = false
            }
            // **Review #3's B9, at every width.** `Audit3BugFixesSelfTest`
            // asserts "a card is as tall as its own content" at one width;
            // this page's wide arrangement regressed it at a width only a
            // GitHub runner produced (the right-hand card resolved to 271pt
            // against 134pt of content), so the property is checked here
            // across the whole resize sequence too - the place a two-column
            // page can lose it.
            for card in settings.debugMountedGroupCards {
                let slack = card.frame.height - card.fittingSize.height
                if slack > 1 {
                    print("  FAIL at \(Int(width))pt a card is \(card.frame.height)pt tall "
                          + "against \(card.fittingSize.height)pt of content - B9 is back")
                    ok = false
                    break
                }
            }
            // A conflict resolves by breaking something, and a broken column
            // reads as a zero-width or overflowing card rather than as a
            // logged warning - so measure the cards themselves.
            let pageWidth = settings.debugMountedGroupCards
                .compactMap { $0.superview?.frame.width }.max() ?? 0
            for card in settings.debugMountedGroupCards
            where card.frame.width < 1 || card.frame.width > pageWidth + 1 {
                print("  FAIL at \(Int(width))pt a card measures \(card.frame.width) "
                      + "in a \(pageWidth)pt column")
                ok = false
                break
            }
        }
        if ok { print("  ok   two columns, one, and back again across six resizes") }
    }
}

#endif
