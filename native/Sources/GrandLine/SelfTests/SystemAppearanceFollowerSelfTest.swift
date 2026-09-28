// Grand Line - native macOS app.
//
// `fm/grandline-settings-page-redesign`'s "Follow system appearance" - the
// one behaviour that redesign added rather than restyled.
//
// **Pure logic, no window or view hierarchy**, and therefore deliberately NOT
// in `NEEDS_SESSION`: every case here drives `resolvedTheme`, which is a
// static function over a Bool and two theme ids. That classification is what
// decides whether this guards the **blocking** CI job at all (AGENTS.md's
// "Writing a self-test"), and this feature wants that guard - it changes the
// captain's theme behind their back when it is wrong, at the one moment
// nobody is watching.
//
// The behaviour worth guarding is the *fallbacks*, not the happy path. A pair
// naming a theme that has since been retired, or a "light" slot somehow
// holding a dark palette, must not put the app in the dark on a light system:
// that reads exactly like a broken observer, and it is the failure mode a
// stored id makes possible. So each case says which wrong answer it exists to
// rule out.
//
// Run with:
//   swift build && FM_RUN_SYSTEM_APPEARANCE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SystemAppearanceFollowerSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkThePairIsHonouredInBothDirections,
                      checkAnUnknownIDFallsBackToTheRightMode,
                      checkAMiscastPairIsCorrected,
                      checkTheSettingsDefaultsAreARealPair,
                      checkTheFirstRunDefaultFollowsTheSystem] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SystemAppearanceFollowerSelfTest: all checks passed"
                    : "SystemAppearanceFollowerSelfTest: FAILED")
        return allOK
    }

    // MARK: 1. The happy path, both ways

    private static func checkThePairIsHonouredInBothDirections(_ ok: inout Bool) {
        print("\n-- a stored pair is honoured on a light system and on a dark one --")
        // Two palettes from *different* families, so "it returned the right
        // mode" and "it returned the theme that was asked for" are different
        // claims and this case makes the second one. A pair from one family
        // would let a `toggle()`-style implementation pass.
        let light = "catppuccin-latte"
        let dark = "gruvbox-dark"
        guard HelmTheme.theme(id: light)?.mode == .light,
              HelmTheme.theme(id: dark)?.mode == .dark else {
            print("  FAIL the fixture ids are no longer a light/dark pair in the catalogue")
            ok = false
            return
        }

        let onLight = SystemAppearanceFollower.resolvedTheme(isSystemDark: false,
                                                             lightID: light, darkID: dark)
        if onLight?.id != light {
            print("  FAIL a light system resolved to \(onLight?.id ?? "nil"), want \(light)")
            ok = false
        }
        let onDark = SystemAppearanceFollower.resolvedTheme(isSystemDark: true,
                                                            lightID: light, darkID: dark)
        if onDark?.id != dark {
            print("  FAIL a dark system resolved to \(onDark?.id ?? "nil"), want \(dark)")
            ok = false
        }
        if ok { print("  ok   \(light) on a light system, \(dark) on a dark one") }
    }

    // MARK: 2. A retired id

    private static func checkAnUnknownIDFallsBackToTheRightMode(_ ok: inout Bool) {
        print("\n-- a pair naming a theme that no longer exists still resolves to the right mode --")
        // The realistic way this happens: a palette is renamed or dropped
        // while a stored `fm.systemDarkThemeID` still names it. The wrong
        // answer is `nil` - which would silently stop following - or a theme
        // of the *other* mode, which is the visible bug.
        let resolvedDark = SettingsFallback.resolve(isSystemDark: true,
                                                    lightID: "helm-light",
                                                    darkID: "a-theme-that-was-removed")
        if resolvedDark == nil {
            print("  FAIL an unknown dark id resolved to nil - following would silently stop")
            ok = false
        } else if resolvedDark?.mode != .dark {
            print("  FAIL an unknown dark id resolved to \(resolvedDark?.id ?? "nil"), "
                  + "which is a light theme")
            ok = false
        }

        let resolvedLight = SettingsFallback.resolve(isSystemDark: false,
                                                     lightID: "also-gone",
                                                     darkID: "dusk")
        if resolvedLight?.mode != .light {
            print("  FAIL an unknown light id resolved to \(resolvedLight?.id ?? "nil")")
            ok = false
        }
        if ok { print("  ok   an unknown id falls back within the right mode, never to nil") }
    }

    // MARK: 3. A pair pointing the wrong way

    private static func checkAMiscastPairIsCorrected(_ ok: inout Bool) {
        print("\n-- a pair whose light slot holds a dark theme is corrected, not obeyed --")
        // Obeying it is the failure this rules out: the app would go dark the
        // moment the system went light, which reads as an inverted observer
        // rather than as a bad stored value.
        let resolved = SettingsFallback.resolve(isSystemDark: false,
                                                lightID: "dusk",       // a dark palette
                                                darkID: "dusk")
        if resolved?.mode != .light {
            print("  FAIL a light system with a dark theme in the light slot resolved to "
                  + "\(resolved?.id ?? "nil")")
            ok = false
        }
        if resolved?.id == "dusk" {
            print("  FAIL the miscast id was obeyed rather than corrected")
            ok = false
        }
        if ok { print("  ok   a miscast slot resolves within the mode the system asked for") }
    }

    // MARK: 4. The shipped defaults

    private static func checkTheSettingsDefaultsAreARealPair(_ ok: inout Bool) {
        print("\n-- the shipped defaults are a real light/dark pair --")
        // `AppSettings`' defaults are what a captain switching this on for
        // the first time gets, before they touch either popup - so a default
        // that is not a real pair would make the feature wrong on its very
        // first use, and would do it on a machine with no stored values to
        // inspect afterwards.
        //
        // Read through a scratch domain so this case measures the *defaults*
        // rather than whatever the captain (or an earlier suite) has stored.
        let defaults = AppSettings.shared
        let storedLight = defaults.systemLightThemeID
        let storedDark = defaults.systemDarkThemeID

        guard let light = HelmTheme.theme(id: storedLight),
              let dark = HelmTheme.theme(id: storedDark) else {
            print("  FAIL the stored pair (\(storedLight) / \(storedDark)) names a theme "
                  + "that is not in the catalogue")
            ok = false
            return
        }
        if light.mode != .light {
            print("  FAIL the light slot holds \(light.id), which is a dark theme")
            ok = false
        }
        if dark.mode != .dark {
            print("  FAIL the dark slot holds \(dark.id), which is a light theme")
            ok = false
        }
        // Whether following is *on* by default is X10's question now, and it
        // is asserted in `checkTheFirstRunDefaultFollowsTheSystem` below
        // against `AppDefaults.store`. This case used to assert "off with
        // nothing stored" and read the real `UserDefaults.standard` domain to
        // do it, so on a machine that had ever stored the key it short-
        // circuited and asserted nothing - which is why it kept passing
        // through the change rather than catching it.
        if ok { print("  ok   \(light.id) / \(dark.id) is a real pair") }
    }

    /// A one-line alias so the cases above read as sentences rather than as
    /// four repetitions of a long static call.
    private enum SettingsFallback {
        static func resolve(isSystemDark: Bool, lightID: String, darkID: String) -> HelmTheme? {
            SystemAppearanceFollower.resolvedTheme(isSystemDark: isSystemDark,
                                                   lightID: lightID, darkID: darkID)
        }
    }
    // MARK: 5. X10 - the first-run default

    /// X10 (review UX): "Follow system appearance" was off by default, and an
    /// app shipping thirteen light/dark pairs is expected to follow the
    /// system. The default is now on for a **fresh install** and off for a
    /// captain who already picked a palette - overriding a stored `fm.themeID`
    /// would be a real defect, and is what kept this off before.
    ///
    /// Driven against the real `AppDefaults.store` (a per-process suite domain
    /// in an `FM_RUN_*` process - AGENTS.md's hermeticity rule), with the two
    /// keys saved and put back, because the whole behaviour is "what does an
    /// absent key mean".
    private static func checkTheFirstRunDefaultFollowsTheSystem(_ ok: inout Bool) {
        print("\n-- X10: following is on for a fresh install and off once a palette was picked --")
        let followKey = "fm.followSystemAppearance"
        let themeKey = "fm.themeID"
        let store = AppDefaults.store
        let savedFollow = store.object(forKey: followKey)
        let savedTheme = store.object(forKey: themeKey)
        defer {
            if let savedFollow { store.set(savedFollow, forKey: followKey) }
            else { store.removeObject(forKey: followKey) }
            if let savedTheme { store.set(savedTheme, forKey: themeKey) }
            else { store.removeObject(forKey: themeKey) }
        }

        // A fresh install: neither key has ever been written.
        store.removeObject(forKey: followKey)
        store.removeObject(forKey: themeKey)
        store.removeObject(forKey: "fm.themeMode")
        if !AppSettings.shared.followSystemAppearance {
            print("  FAIL a fresh install does not follow the system")
            ok = false
        } else {
            print("  ok   a fresh install follows the system")
        }
        // And the answer was *materialised*, not re-derived - otherwise the
        // follower's own first `setTheme` (which writes `fm.themeID`) would
        // flip the setting off behind the captain's back an hour later.
        if store.object(forKey: followKey) == nil {
            print("  FAIL the first read did not store the resolved default - it would flip "
                  + "to off as soon as the follower switched a theme")
            ok = false
        }

        // A captain who has chosen: the stored palette wins, as before.
        store.removeObject(forKey: followKey)
        store.set(HelmTheme.dusk.id, forKey: themeKey)
        if AppSettings.shared.followSystemAppearance {
            print("  FAIL an install with a stored palette follows the system - it would discard "
                  + "that choice the first time the sun set")
            ok = false
        } else {
            print("  ok   a stored palette choice is left alone")
        }

        // An explicit setting always wins over either default, in both
        // directions - without this the two cases above could both pass
        // against a getter that ignored the stored value entirely.
        for (theme, explicit) in [(HelmTheme.dusk.id, true), (HelmTheme.dusk.id, false)] as [(String, Bool)] {
            store.set(theme, forKey: themeKey)
            AppSettings.shared.followSystemAppearance = explicit
            if AppSettings.shared.followSystemAppearance != explicit {
                print("  FAIL an explicit \(explicit) was not honoured")
                ok = false
            }
        }
        store.removeObject(forKey: followKey)
        store.removeObject(forKey: themeKey)
        AppSettings.shared.followSystemAppearance = false
        if AppSettings.shared.followSystemAppearance {
            print("  FAIL an explicit false on a fresh install was overridden by the default")
            ok = false
        } else {
            print("  ok   an explicit choice beats the first-run default in both directions")
        }
    }

}

#endif
