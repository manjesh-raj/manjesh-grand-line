// Grand Line - native macOS app.
//
// The theme split's window-backed half: a real console in a real window,
// whose terminal has to change colour when the terminal colours choice does
// while the page around it does not, and the real Settings > Terminal
// controls that make that choice.
//
// **Window-backed**, so it is in `NEEDS_SESSION`: what it asserts is what a
// real `TerminalView` holds after a real paint and what a real page layer is
// filled with, which a headless suite cannot see. Its pure-logic half
// (migration, catalogue, backup) is `ThemeSplitSelfTest`.
//
// Run with:
//   swift build && FM_RUN_THEME_SPLIT_CONSOLE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ThemeSplitConsoleSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkAnOverrideRepaintsTheTerminalAndNotThePage,
                      checkTheTerminalPageChoosesAScheme] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ThemeSplitConsoleSelfTest: all checks passed" : "ThemeSplitConsoleSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func scratchStores() -> (SSHKeyStore, SnippetStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-split-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        return (SSHKeyStore(), SnippetStore())
    }

    /// Component-wise, in sRGB - never `HelmContrast.ratio`, which compares
    /// luminance and would call two hues of one brightness equal.
    private static func same(_ color: NSColor?, _ hex: String) -> Bool {
        guard let color else { return false }
        let a = HelmContrast.components(color)
        let b = HelmContrast.components(HelmTheme.nsColor(hex))
        return abs(a.0 - b.0) < 0.004 && abs(a.1 - b.1) < 0.004 && abs(a.2 - b.2) < 0.004
    }

    private static func layerColor(_ view: NSView) -> NSColor? {
        view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: 1. The console

    private static func checkAnOverrideRepaintsTheTerminalAndNotThePage(_ ok: inout Bool) {
        print("\n-- an override repaints the terminal's cells and nothing else on the page --")
        let (keyStore, snippetStore) = scratchStores()
        let manager = ThemeManager.shared
        let restoreTheme = manager.theme
        let restoreColors = manager.terminalColors
        defer {
            manager.setTerminalColors(restoreColors)
            manager.setTheme(restoreTheme)
        }
        manager.setTheme(.dusk)
        manager.setTerminalColors(TerminalColorsSettings())

        let host = ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false)
        let window = OffScreenProbe.window(width: 1200, height: 820)
        window.contentViewController = host
        defer { _ = window }
        host.view.layoutSubtreeIfNeeded()
        host.debugOpenTestSSHTab(label: "bastion")
        host.viewDidAppear()
        host.view.layoutSubtreeIfNeeded()
        guard let terminal = host.currentTab?.terminal else {
            fail("the console opened no terminal", &ok)
            return
        }

        // Match app theme: Dusk's own dark card, the old behaviour exactly.
        check(same(terminal.nativeBackgroundColor, "131418"),
              "under Match app theme Dusk's terminal is its card (131418)", &ok)
        check(host.debugTerminalCardVisible(), "and sits in a card, since 131418 is not the page's 191A1F", &ok)
        let pageBefore = layerColor(host.view)
        let contentBefore = layerColor(host.content)
        check(same(pageBefore, "191A1F"), "the page is Dusk's ground", &ok)

        // The override. Solarized Light is a light scheme in a dark app, so
        // every channel the check reads moves a long way.
        manager.setTerminalColors(TerminalColorsSettings(mode: .custom, schemeID: "solarized-light"))
        host.view.layoutSubtreeIfNeeded()
        check(same(terminal.nativeBackgroundColor, "eee8d5"), "the terminal's cells are Solarized Light's ground", &ok)
        check(same(terminal.nativeForegroundColor, "002b36"), "its ink is Solarized Light's", &ok)
        check(same(terminal.caretColor, "2aa198"), "its cursor is Solarized Light's, not the app accent", &ok)
        check(same(terminal.selectedTextBackgroundColor, "2aa198"), "its selection is the scheme's own", &ok)
        check((terminal.rowHighlighter as? TerminalKeywordHighlighter)?.theme.id == "solarized-light",
              "keyword highlighting follows the scheme", &ok)
        check(same(layerColor(host.view), "191A1F") && same(layerColor(host.content), "191A1F"),
              "the page around it is still Dusk's ground", &ok)
        check(pageBefore != nil && contentBefore != nil, "the page had a fill to compare - not vacuous", &ok)
        check(host.theme.id == "dusk", "the console's app theme did not move (\(host.theme.id))", &ok)
        check(host.debugTerminalCardVisible(), "a light terminal on a dark page sits in a card", &ok)

        // A tab opened now starts in the chosen scheme, not the app's.
        host.debugOpenTestSSHTab(label: "staging")
        host.view.layoutSubtreeIfNeeded()
        check(same(host.currentTab?.terminal.nativeBackgroundColor, "eee8d5"),
              "a tab opened after the choice paints the chosen scheme", &ok)

        // Back to Match app theme, then an app theme change: the terminal
        // follows the app's companion.
        manager.setTerminalColors(TerminalColorsSettings())
        manager.setTheme(HelmTheme.appTheme(id: "graphite-dark") ?? .dusk)
        host.view.layoutSubtreeIfNeeded()
        check(same(terminal.nativeBackgroundColor, "282c34"), "Graphite Dark's terminal is One Dark (282c34)", &ok)
        check(same(layerColor(host.view), "1C1C1E"), "on Graphite Dark's own ground (1C1C1E)", &ok)
        _ = waitUntil(timeout: 0.2) { true }
    }

    // MARK: 2. Settings > Terminal > Terminal colours

    private static func checkTheTerminalPageChoosesAScheme(_ ok: inout Bool) {
        print("\n-- Settings > Terminal's own controls choose a scheme --")
        let manager = ThemeManager.shared
        let restoreTheme = manager.theme
        let restoreColors = manager.terminalColors
        defer {
            manager.setTerminalColors(restoreColors)
            manager.setTheme(restoreTheme)
        }
        manager.setTheme(.dusk)
        manager.setTerminalColors(TerminalColorsSettings())

        let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                          snippetStore: SnippetStore(), dictationStore: DictationStore())
        let window = OffScreenProbe.window(width: 1200, height: 900)
        window.contentView = settings.view
        settings.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        defer { _ = window }
        settings.select(.terminal)
        settings.view.layoutSubtreeIfNeeded()
        let section = settings.debugTerminalColors

        check(section.matchCard.isSelected && !section.customCard.isSelected, "Match app theme starts selected", &ok)
        check(section.matchCard.detail.contains("Dusk"), "and says which scheme Dusk uses (\(section.matchCard.detail))", &ok)
        check(section.debugCustomSections.allSatisfy(\.isHidden), "the scheme grid is hidden while matching", &ok)
        check(section.preview.schemeID == "dusk", "the preview shows Dusk's card", &ok)

        _ = section.customCard.hoverView.accessibilityPerformPress()
        settings.view.layoutSubtreeIfNeeded()
        check(manager.terminalColors.mode == .custom, "Choose a scheme switches the mode", &ok)
        check(manager.terminalScheme.id == "dusk", "and changes nothing on screen by itself", &ok)
        check(section.debugCustomSections.allSatisfy { !$0.isHidden }, "the scheme grid appears", &ok)
        check(section.schemeCards.count == HelmTheme.allThemes.count,
              "it draws all 26 schemes (\(section.schemeCards.count))", &ok)
        check(section.schemeCards.filter(\.isActive).map(\.theme.id) == ["dusk"], "with Dusk marked", &ok)

        guard let dracula = section.schemeCards.first(where: { $0.theme.id == "dracula" }) else {
            fail("no Dracula card to press", &ok)
            return
        }
        _ = dracula.hoverView.accessibilityPerformPress()
        settings.view.layoutSubtreeIfNeeded()
        check(manager.terminalScheme.id == "dracula", "pressing Dracula paints the terminal in it", &ok)
        check(manager.theme.id == "dusk", "and leaves the app on Dusk", &ok)
        check(section.preview.schemeID == "dracula", "the preview follows", &ok)
        check(section.schemeCards.filter(\.isActive).map(\.theme.id) == ["dracula"], "and the check mark moves", &ok)
        check(settings.debugAppearanceNote.stringValue.contains("Dracula"),
              "Appearance's note says the terminal is on Dracula (\(settings.debugAppearanceNote.stringValue))", &ok)

        _ = section.matchCard.hoverView.accessibilityPerformPress()
        check(manager.terminalScheme.id == "dusk", "Match app theme puts the terminal back on Dusk's card", &ok)
    }
}

#endif
