// Grand Line - native macOS app.
//
// Settings' split cards (Set-2 on the second page-redesign board), mounted in
// a real off-screen sidebar shell and driven through the pages' own controls.
//
// Window-backed, because what it asserts is real layout and real dispatch:
//
//   - Every page opens with its split card, and the card's half holds the
//     page's own rows (Appearance: Appearance, Window layout, Density,
//     Profile), not copies; the rest of the page follows.
//   - No setting became unreachable: every row the floating bar's Settings
//     draws is still on a page, in a section or on a card.
//   - The card sits beside its rows on a wide page and stacks on a narrow
//     one, and neither grows the window.
//   - A control on the card still writes its setting, and the panel's words
//     follow it; the panel's pills run the page's own actions.
//   - Every word on the gradient is in the hero's ink.
//
// The words for every page and state are asserted headless in
// `SettingsSplitCardWordsSelfTest`.
//
// With `FM_SETTINGS_SPLIT_RENDER_DIR` set it also writes one PNG per page,
// window width and theme into that folder (the PR's renders). Nothing is
// written otherwise.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_SPLIT_CARDS_VIEW_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsSplitCardsViewSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-split-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.daylight)
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            settle(shell)
            let checks: [(MainSplitShellController, NSWindow, inout Bool) -> Void] = [
                checkEveryPageOpensWithItsCard, checkAppearanceCard, checkNoSettingBecameUnreachable,
                checkSideBySideAndStacked, checkCardControlsStillWrite, checkPanelPills, checkShortcutsCard,
                checkBackupCard, checkPanelWordsAreInk, writeRenders,
            ]
            for check in checks {
                var ok = true
                autoreleasepool { check(shell, window, &ok) }
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "SettingsSplitCardsViewSelfTest: all checks passed" : "SettingsSplitCardsViewSelfTest: FAILED")
        return allOK
    }

    // MARK: Harness

    static func settle(_ shell: WorkspaceShellController) {
        TasksSecretsHeroViewSelfTest.settle(shell)
    }

    static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        TasksSecretsHeroViewSelfTest.resize(window, width: width, shell)
    }

    @discardableResult
    static func show(_ category: SettingsController.Category, _ shell: MainSplitShellController) -> SettingsController {
        shell.workspace.navigator.show(.settings)
        shell.setInspectorShown(false)
        let settings = shell.workspace.settings
        settings.select(category)
        settle(shell)
        return settings
    }

    /// The rows each page's card is planned to hold, by title.
    static let expectedCardRows: [SettingsController.Category: [String]] = [
        .appearance: ["Appearance", "Window layout", "Density", "Profile"],
        .terminal: ["Working directory", "Reconnect automatically", "Default font size",
                    "Notify when the crew needs you"],
        .shortcuts: ["Find a shortcut", "Show"],
        .capture: ["Open the capture panel", "Accessibility permission", "Keep a clipboard history"],
        .menuBar: ["Live in the menu bar", "Hide the Dock icon", "Show the overdue count on the icon",
                   "Separate icons for Tasks, the vault and the crew"],
        .briefings: ["Show a morning briefing"],
        .security: ["Require a password to open Grand Line", "Lock when idle", "Lock after a full session",
                    "Vault settings live in the vault"],
    ]

    // MARK: Cases

    private static func checkEveryPageOpensWithItsCard(_ shell: MainSplitShellController, _ window: NSWindow,
                                                       _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for category in SettingsController.Category.allCases {
            let settings = show(category, shell)
            guard let split = settings.debugSplitCard(category) else {
                fail("\(category.title) has no split card in the sidebar layout", &ok)
                continue
            }
            check(settings.debugMountedPageViews.first === split,
                  "\(category.title): the split card is not the first thing on the page", &ok)
            check(split.window != nil, "\(category.title): the split card is not in the window", &ok)
            let kicker = split.card.panel.debugKicker
            check(kicker == SettingsHeroWords.kicker(category.title),
                  "\(category.title): the panel's kicker is \"\(kicker)\"", &ok)
            check(!split.card.panel.debugHeadline.isEmpty, "\(category.title): the panel says nothing", &ok)
            if let expected = expectedCardRows[category] {
                let titles = split.list?.rows.map(\.titleLabel.stringValue) ?? []
                check(titles == expected, "\(category.title): the card holds \(titles), want \(expected)", &ok)
            }
            // The rows on the card are not also in a section.
            let sectionRows = settings.debugSections(in: category).flatMap { $0.group.rows }
            for row in split.list?.rows ?? [] where sectionRows.contains(where: { $0 === row }) {
                fail("\(category.title): \"\(row.titleLabel.stringValue)\" is on the card and in a section", &ok)
            }
            check(settings.debugAnyHeroIsShown == false, "\(category.title): the floating bar's hero shows", &ok)
        }
        let intents = show(.intents, shell)
        let intentRows = intents.debugSplitCard(.intents)?.list?.rows.map(\.titleLabel.stringValue) ?? []
        check(intentRows == GrandLineIntentCatalog.entries.map(\.title),
              "App Intents: the card holds \(intentRows), want every action", &ok)
    }

    private static func checkAppearanceCard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for theme in [TasksSecretsHeroViewSelfTest.daylight, TasksSecretsHeroViewSelfTest.dusk] {
            ThemeManager.shared.setTheme(theme)
            let settings = show(.appearance, shell)
            guard let split = settings.debugSplitCard(.appearance) else { continue }
            check(split.card.panel.debugHeadline == "\(theme.name) is showing.",
                  "Appearance: the panel says \"\(split.card.panel.debugHeadline)\" under \(theme.name)", &ok)
            guard let tile = split.debugPreviewTile, let content = tile.content else {
                fail("Appearance: no theme preview on the panel", &ok)
                continue
            }
            check(content.showingDark == (theme.mode == .dark),
                  "Appearance: the preview marks the wrong half under \(theme.name)", &ok)
            check(tile.window != nil && tile.frame.width > 0, "Appearance: the preview is not on screen", &ok)
            // Its own size, not stretched to the caption's width by the
            // panel's trailing column.
            check(abs(tile.frame.width - SettingsThemePreviewTile.size.width) < 0.5,
                  "Appearance: the preview is \(tile.frame.width) wide, want \(SettingsThemePreviewTile.size.width)", &ok)
            let caption = split.card.panel.debugAccessoryCaption?.stringValue
            check(caption == "Daylight \u{00B7} Dusk", "Appearance: the preview's caption is \(caption ?? "nil")", &ok)
            // The marker sits over the half that is showing.
            let marker = tile.debugMarkerFrame
            let onRight = marker.midX > tile.bounds.midX
            check(onRight == (theme.mode == .dark),
                  "Appearance: the showing-half ring is on the \(onRight ? "right" : "left") under \(theme.name)", &ok)
            // The sections the card did not take, in order.
            let headings = settings.debugSections(in: .appearance).compactMap { $0.headingLabel?.stringValue }
            check(headings == ["App theme", "Sidebar", "Text"],
                  "Appearance: the page's sections are \(headings), want App theme, Sidebar, Text", &ok)
            check(settings.debugThemeCards.count == AppThemeFamily.allCases.count,
                  "Appearance: \(settings.debugThemeCards.count) theme tiles, want every family", &ok)
            check(settings.debugModuleSwitches.allSatisfy { $0.toggle.window != nil },
                  "Appearance: a module switch is not on the page", &ok)
        }
        ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.daylight)
    }

    private static func checkNoSettingBecameUnreachable(_ shell: MainSplitShellController, _ window: NSWindow,
                                                       _ ok: inout Bool) {
        // The floating bar's Settings, built the same way, never adopted.
        let floating = SettingsController(hostStore: shell.workspace.hostStore, keyStore: shell.workspace.keyStore,
                                          snippetStore: shell.workspace.snippetStore,
                                          dictationStore: shell.workspace.dictationStore)
        let menu = AppDelegate().buildMenu(installing: false)
        floating.shortcutsMainMenu = { menu }
        floating.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        floating.view.layoutSubtreeIfNeeded()
        let sidebar = shell.workspace.settings
        let before = Set(floating.debugRows.map(\.titleLabel.stringValue))
        let after = Set(sidebar.debugRows.map(\.titleLabel.stringValue))
        check(before.count > 40, "only \(before.count) rows on the floating bar's Settings - the fixture is broken", &ok)
        // "Currently saved" is Backup's panel in the sidebar layout.
        let missing = before.subtracting(after).subtracting(["Currently saved"])
        check(missing.isEmpty, "rows the sidebar layout no longer draws: \(missing.sorted())", &ok)
        check(floating.debugSplitCard(.appearance) == nil, "the floating bar's Settings drew a split card", &ok)
        check(floating.debugAnyHeroIsShown, "the floating bar's Settings lost its hero", &ok)
    }

    private static func checkSideBySideAndStacked(_ shell: MainSplitShellController, _ window: NSWindow,
                                                  _ ok: inout Bool) {
        for (width, stacked) in [(1512, false), (1100, true)] as [(CGFloat, Bool)] {
            resize(window, width: width, shell)
            for category in SettingsController.Category.allCases {
                let settings = show(category, shell)
                guard let split = settings.debugSplitCard(category) else { continue }
                check(abs(window.frame.width - width) < 0.5,
                      "\(category.title) at \(Int(width)): the window is \(window.frame.width) wide", &ok)
                check(split.card.isStacked == stacked,
                      "\(category.title) at \(Int(width)): the card is \(split.card.isStacked ? "stacked" : "side by side")",
                      &ok)
                let card = split.card.convert(split.card.bounds, to: settings.view)
                let panel = split.card.panel.convert(split.card.panel.bounds, to: settings.view)
                check(card.width <= SettingsController.splitPageMaxWidth + 0.5,
                      "\(category.title) at \(Int(width)): the card is \(card.width) wide", &ok)
                check(card.maxX <= settings.view.bounds.maxX + 0.5,
                      "\(category.title) at \(Int(width)): the card runs past the page (\(card.maxX))", &ok)
                if stacked {
                    check(abs(panel.width - card.width) < 1,
                          "\(category.title) stacked: the panel is \(panel.width) of a \(card.width) card", &ok)
                } else {
                    check(abs(panel.width - SettingsHeroSplitView.panelWidth) < 1,
                          "\(category.title) side by side: the panel is \(panel.width) wide", &ok)
                    check(abs(panel.height - card.height) < 1,
                          "\(category.title) side by side: the panel is \(panel.height) of a \(card.height) card", &ok)
                }
                // Every row on the card fits inside it.
                for row in split.list?.rows ?? [] {
                    let frame = row.convert(row.bounds, to: split.card)
                    check(frame.minX >= -0.5 && frame.maxX <= split.card.bounds.width + 0.5
                            && frame.minY >= -0.5 && frame.maxY <= split.card.bounds.height + 0.5,
                          "\(category.title) at \(Int(width)): \"\(row.titleLabel.stringValue)\" spills off the card \(frame)",
                          &ok)
                }
            }
        }
        resize(window, width: 1512, shell)
    }

    private static func checkCardControlsStillWrite(_ shell: MainSplitShellController, _ window: NSWindow,
                                                    _ ok: inout Bool) {
        let saved = AppSettings.shared.density
        let settings = show(.appearance, shell)
        // Put it back through the control, so the tabs show it too.
        defer { settings.densityTabs.debugClickTab(id: saved.rawValue) }
        guard let split = settings.debugSplitCard(.appearance) else { return }
        let target: HelmDensity = saved == .compact ? .comfortable : .compact
        settings.densityTabs.debugClickTab(id: target.rawValue)
        settle(shell)
        check(AppSettings.shared.density == target, "Appearance: Density on the card did not write the setting", &ok)
        let body = split.card.panel.debugBody ?? ""
        check(body.contains("\(target.title.lowercased()) rows"),
              "Appearance: the panel did not follow Density (\"\(body)\")", &ok)

        let savedBriefing = AppSettings.shared.morningBriefingEnabled
        defer { AppSettings.shared.morningBriefingEnabled = savedBriefing }
        let briefings = show(.briefings, shell)
        let toggle = briefings.debugMorningBriefingSwitch
        // The real activation path a click, a key press and VoiceOver take.
        _ = toggle.accessibilityPerformPress()
        settle(shell)
        check(AppSettings.shared.morningBriefingEnabled == toggle.isOn && toggle.isOn != savedBriefing,
              "Briefings: the switch on the card did not write the setting", &ok)
        let headline = briefings.debugSplitCard(.briefings)?.card.panel.debugHeadline ?? ""
        check(headline == SettingsHeroWords.briefings(enabled: toggle.isOn, place: PlaceName.of(.overview)).headline,
              "Briefings: the panel says \"\(headline)\" with the briefing \(toggle.isOn ? "on" : "off")", &ok)
    }

    private static func checkPanelPills(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let savedFollow = AppSettings.shared.followSystemAppearance
        let savedTheme = ThemeManager.shared.theme
        defer {
            // The follower does nothing once following is off again.
            AppSettings.shared.followSystemAppearance = savedFollow
            ThemeManager.shared.setTheme(savedTheme)
        }
        AppSettings.shared.followSystemAppearance = false
        let settings = show(.appearance, shell)
        settings.debugRefreshFromSettings()
        guard let panel = settings.debugSplitCard(.appearance)?.card.panel else { return }
        check(panel.debugFootButtons.contains { $0 === settings.debugMatchMacOSPill },
              "Appearance: no Match macOS pill while the app does not follow macOS", &ok)
        settings.debugMatchMacOSPill.performClick(nil)
        settle(shell)
        check(AppSettings.shared.followSystemAppearance, "Appearance: Match macOS did not follow macOS", &ok)
        check(!panel.debugFootButtons.contains { $0 === settings.debugMatchMacOSPill },
              "Appearance: Match macOS is still offered while following macOS", &ok)

        let capture = show(.capture, shell)
        check(capture.debugSplitCard(.capture)?.card.panel.debugFootButtons.first === capture.debugResetCaptureShortcutButton,
              "Capture: Restore Default is not the panel's pill", &ok)
        let backup = show(.backup, shell)
        let pills = backup.debugSplitCard(.backup)?.card.panel.debugFootButtons ?? []
        check(pills.count == 2 && pills[0] === backup.debugBackupButtons.export
                && pills[1] === backup.debugBackupButtons.import,
              "Backup: the panel's pills are not the page's Export and Import", &ok)
        var navigated: RailDestination?
        let briefings = show(.briefings, shell)
        let savedNavigate = briefings.onNavigate
        briefings.onNavigate = { navigated = $0 }
        briefings.debugOpenOverviewPill.performClick(nil)
        briefings.onNavigate = savedNavigate
        check(navigated == .overview, "Briefings: the panel's pill opened \(String(describing: navigated))", &ok)
    }

    private static func checkShortcutsCard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let settings = show(.shortcuts, shell)
        let page = settings.debugShortcutsPage
        guard let split = settings.debugSplitCard(.shortcuts) else { return }
        check(page.debugSearchField.isDescendant(of: split.card.detail),
              "Shortcuts: the search field is not on the card", &ok)
        check(split.card.panel.debugFootButtons.first === page.debugRestoreAllButton,
              "Shortcuts: Restore All Defaults is not the panel's pill", &ok)
        let all = page.debugVisibleRows.count
        page.debugSearchField.stringValue = "capture"
        page.debugSearchField.onTextChanged?("capture")
        settle(shell)
        let filtered = page.debugVisibleRows.count
        check(filtered > 0 && filtered < all, "Shortcuts: searching from the card left \(filtered) of \(all) rows", &ok)
        page.debugSearchField.stringValue = ""
        page.debugSearchField.onTextChanged?("")
        settle(shell)
        let headline = split.card.panel.debugHeadline
        check(headline.hasPrefix("\(page.rows.count) shortcuts"), "Shortcuts: the panel says \"\(headline)\"", &ok)
    }

    private static func checkBackupCard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let saved = AppSettings.shared.lastBackupExport
        defer { AppSettings.shared.lastBackupExport = saved }
        AppSettings.shared.lastBackupExport = nil
        let settings = show(.backup, shell)
        guard let split = settings.debugSplitCard(.backup) else { return }
        check(split.card.panel.debugHeadline == "No backup exported from this Mac yet.",
              "Backup: with no export the panel says \"\(split.card.panel.debugHeadline)\"", &ok)
        BackupUI.recordExport(bytes: 1_843_200, destination: "grand-line-backup.glbackup")
        settle(shell)
        let headline = split.card.panel.debugHeadline
        check(headline.hasPrefix("Last export today, ") && headline.contains("MB"),
              "Backup: after an export the panel says \"\(headline)\"", &ok)
        // On a card far taller than its words the pills stay under them -
        // after the route a captain takes too: narrow, wide again, and a
        // theme change, each of which lays the panel out afresh.
        resize(window, width: 1100, shell)
        resize(window, width: 1512, shell)
        ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.dusk)
        show(.backup, shell)
        defer { ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.daylight) }
        let panel = split.card.panel
        if let pill = panel.debugFootButtons.first, let body = panel.debugBody, !body.isEmpty {
            let words = panel.debugBodyLabel.convert(panel.debugBodyLabel.bounds, to: panel)
            let pillFrame = pill.convert(pill.bounds, to: panel)
            let gap = panel.isFlipped ? pillFrame.minY - words.maxY : words.minY - pillFrame.maxY
            check(gap >= 0 && gap <= HelmMetrics.s6, "Backup: the pills sit \(gap)pt under the words", &ok)
            check(panel.bounds.height > words.height + pillFrame.height + 100,
                  "Backup: the panel is not taller than its words (\(panel.bounds.height)), so the pill check is vacuous", &ok)
        } else {
            fail("Backup: the panel has no body or no pills", &ok)
        }
        check(settings.debugSections(in: .backup).isEmpty,
              "Backup: \(settings.debugSections(in: .backup).count) sections left under the card", &ok)
        check(!(split.noteLabels.first?.stringValue ?? "").isEmpty, "Backup: the inventory's note is gone", &ok)
    }

    private static func checkPanelWordsAreInk(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        for theme in [TasksSecretsHeroViewSelfTest.daylight, TasksSecretsHeroViewSelfTest.dusk] {
            ThemeManager.shared.setTheme(theme)
            for category in SettingsController.Category.allCases {
                let settings = show(category, shell)
                guard let panel = settings.debugSplitCard(category)?.card.panel else { continue }
                check(TasksSecretsHeroViewSelfTest.isInk(panel.debugHeadlineLabel.textColor, panel.ink),
                      "\(category.title) under \(theme.name): the headline is not in the ink", &ok)
                if let palette = panel.debugPalette {
                    let ink = HelmContrast.components(panel.ink)
                    let ratio = min(HelmContrast.ratio(ink, palette.start), HelmContrast.ratio(ink, palette.end))
                    check(ratio >= HelmContrast.textTarget - 0.01,
                          "\(category.title) under \(theme.name): the ink measures \(ratio):1 on the gradient", &ok)
                }
            }
        }
        ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.daylight)
    }

    // MARK: Renders

    private static func writeRenders(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_SETTINGS_SPLIT_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for theme in [TasksSecretsHeroViewSelfTest.daylight, TasksSecretsHeroViewSelfTest.dusk] {
            ThemeManager.shared.setTheme(theme)
            for width in [1512, 1100] as [CGFloat] {
                resize(window, width: width, shell)
                for category in SettingsController.Category.allCases {
                    let settings = show(category, shell)
                    TasksSecretsHeroViewSelfTest.write(
                        settings.view,
                        to: folder.appendingPathComponent("settings-\(category.rawValue)-\(theme.id)-\(Int(width)).png"))
                }
            }
        }
        ThemeManager.shared.setTheme(TasksSecretsHeroViewSelfTest.daylight)
        resize(window, width: 1512, shell)
        print("SettingsSplitCardsViewSelfTest: renders written to \(dir)")
    }
}

#endif
