// Grand Line - native macOS app.
//
// P-03 of the 2026-11-25 full review: the captain decided to remove the
// floating-bar layout, so the sidebar is the only window layout and Settings
// offers no choice of one. Two things guard that:
//
//   1. **Settings shows no layout picker.** Every row on every Settings page,
//      the split cards included, is read off the real views, and none may be
//      "Window layout". The Appearance panel's words no longer name a layout.
//      A source guard backs it up: `SettingsController` and `AppSettings`
//      read and write no layout preference.
//   2. **A stored floating-bar preference is retired safely.** An install
//      that had chosen the floating bar has `fm.workspaceLayout = floatingBar`
//      (and the bar's shortcut row in `fm.quickAccess`). Nothing reads either
//      any more, so that install already opens on the sidebar;
//      `AppSettings.retireFloatingBarLayout()` removes both keys once at launch
//      (`main.swift`). It must remove exactly those two keys, keep every other
//      preference, and do nothing on a fresh install or on a second launch.
//
// Each rule first runs against a fixture it must fail, so a drifted check
// fails loudly instead of passing vacuously.
//
// Pure logic: it builds `SettingsController`'s views but mounts no window, so
// it is not in `NEEDS_SESSION` and guards CI's blocking lane. Run with
// `FM_RUN_SETTINGS_LAYOUT_CHOICE_TESTS=1 .build/debug/GrandLine`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum SettingsLayoutChoiceSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== SettingsLayoutChoiceSelfTest ==")
        checkSettingsOffersNoLayout(&ok)
        checkTheSourcesReadNoLayout(&ok)
        checkTheRetirementRemovesOnlyTheTwoKeys(&ok)
        checkTheRetirementIsANoOpWhenNothingIsStored(&ok)
        print(ok ? "SettingsLayoutChoiceSelfTest: OK" : "SettingsLayoutChoiceSelfTest: FAILED")
        return ok
    }

    // MARK: 1 - no picker

    private static func checkSettingsOffersNoLayout(_ ok: inout Bool) {
        let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                          snippetStore: SnippetStore(), dictationStore: DictationStore())
        let appearance = settings.debugRowTitles(in: .appearance)
        // The fixture's own power: the page really has its rows, so an empty
        // read cannot pass.
        check(appearance.contains("Density") || appearance.count >= 3,
              "read the Appearance page's rows (\(appearance))", &ok)
        for category in SettingsController.Category.allCases {
            let titles = settings.debugRowTitles(in: category)
            check(!titles.contains { $0.localizedCaseInsensitiveContains("layout") && $0.localizedCaseInsensitiveContains("window") },
                  "Settings > \(category.rawValue) offers a window layout again: \(titles)", &ok)
        }
        let words = SettingsHeroWords.appearance(themeName: "Daylight", isDark: false, followsSystem: false,
                                                 density: .comfortable, profile: .operator, terminal: "matches the app")
        check(!(words.body ?? "").localizedCaseInsensitiveContains("layout")
                && !(words.body ?? "").localizedCaseInsensitiveContains("floating"),
              "the Appearance panel names a layout: \(words.body ?? "")", &ok)
    }

    private static func checkTheSourcesReadNoLayout(_ ok: inout Bool) {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return
        }
        func code(_ name: String) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        guard let settings = code("SettingsController.swift"), let appSettings = code("AppSettings.swift") else {
            fail("could not read SettingsController.swift and AppSettings.swift", &ok)
            return
        }
        // Discriminating power: the reader found the real files.
        check(settings.contains("final class SettingsController") && appSettings.contains("final class AppSettings"),
              "the source reader found the Settings files", &ok)
        for token in ["\"Window layout\"", "workspaceLayout", "WorkspaceLayout", "floatingBar"] {
            check(!settings.contains(token), "SettingsController.swift mentions \(token) again", &ok)
        }
        check(!appSettings.contains("var workspaceLayout") && !appSettings.contains("var quickAccess"),
              "AppSettings reads a layout preference again", &ok)
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("MainSplitShellController.swift").path)
                && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("AppShellController.swift").path),
              "the floating bar's shell is back beside the sidebar shell", &ok)
    }

    // MARK: 2 - the migration

    private static func scratchDefaults() -> (UserDefaults, String) {
        let name = "grandline-layout-choice-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private static func checkTheRetirementRemovesOnlyTheTwoKeys(_ ok: inout Bool) {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("floatingBar", forKey: "fm.workspaceLayout")
        defaults.set(Data(#"{"pinned":["hosts","console"]}"#.utf8), forKey: "fm.quickAccess")
        defaults.set("dusk", forKey: "fm.themeID")
        // Fixture first: both keys really are stored.
        check(defaults.string(forKey: "fm.workspaceLayout") == "floatingBar" && defaults.data(forKey: "fm.quickAccess") != nil,
              "the fixture stored a floating-bar choice and its shortcut row", &ok)

        let settings = AppSettings(defaults: defaults)
        let removed = settings.retireFloatingBarLayout()
        check(removed["fm.workspaceLayout"] == "floatingBar" && removed["fm.quickAccess"] != nil && removed.count == 2,
              "the retirement reported \(removed)", &ok)
        check(defaults.object(forKey: "fm.workspaceLayout") == nil && defaults.object(forKey: "fm.quickAccess") == nil,
              "a stored floating-bar layout or its shortcut row survived the retirement", &ok)
        check(defaults.string(forKey: "fm.themeID") == "dusk",
              "the retirement removed a preference that is not the layout's", &ok)
        // A second launch finds nothing to do.
        check(settings.retireFloatingBarLayout().isEmpty, "a second launch retired something again", &ok)

        // A stored sidebar choice is retired the same way: the key itself is gone.
        defaults.set("sidebar", forKey: "fm.workspaceLayout")
        check(settings.retireFloatingBarLayout() == ["fm.workspaceLayout": "sidebar"]
                && defaults.object(forKey: "fm.workspaceLayout") == nil,
              "a stored sidebar choice was not retired", &ok)
    }

    private static func checkTheRetirementIsANoOpWhenNothingIsStored(_ ok: inout Bool) {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "fm.hasSeenWelcome")
        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("fm.") }.count
        let removed = AppSettings(defaults: defaults).retireFloatingBarLayout()
        let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("fm.") }.count
        check(removed.isEmpty && before == after && defaults.bool(forKey: "fm.hasSeenWelcome"),
              "a fresh install's retirement changed something (removed \(removed), \(before) -> \(after) keys)", &ok)
        check(AppSettings.retiredLayoutKeys == ["fm.workspaceLayout", "fm.quickAccess"],
              "the retired keys are \(AppSettings.retiredLayoutKeys), not the floating bar's two", &ok)
    }
}

#endif
