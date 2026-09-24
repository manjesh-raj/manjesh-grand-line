// Grand Line - native macOS app.
//
// The theme **family** invariants - the rules that are about how a palette
// joins the picker rather than about what any one of its hexes measures.
// Contrast is `HelmContrastSelfTest`'s job and is deliberately not repeated
// here; that suite already sweeps `HelmTheme.allThemes`, so the twelve
// palettes `fm/grandline-new-themes-nord-dracula-etc` added are covered by it
// with no edit at all.
//
// What was *not* covered, and is what this file exists for: the family
// pairing. `ThemeManager.toggle()` (⌘⌥T, the View menu, the console's theme
// button) flips to `theme.pairId`, falling back to the plain `helm-dark` /
// `helm-light` swap when the lookup misses. That fallback is a safety net, so
// a typo'd or one-way `pairId` does not crash and does not fail any existing
// check - it just quietly drops the captain out of the family they were in,
// on a keystroke they press constantly. Six new families doubled the number of
// places that can happen.
//
// Pure logic - no window, no view hierarchy, no store. It belongs in CI's
// **blocking** lane and is therefore deliberately NOT in `NEEDS_SESSION`. The
// render half of the same work (a real page, painted, under each new palette)
// is `ThemeFamilyRenderSelfTest`, which is window-backed and is listed there.
//
// `FM_RUN_THEME_FAMILY_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ThemeFamilySelfTest {
    static func run() -> Bool {
        print("== theme families ==")
        var ok = true
        checkEveryThemeIsAMutualPair(&ok)
        checkTogglePathReachesThePair(&ok)
        checkIdsAndNamesAreUnique(&ok)
        checkPaletteShape(&ok)
        print(ok ? "== theme families: PASS ==" : "== theme families: FAIL ==")
        return ok
    }

    // MARK: The pairing

    /// Every theme's `pairId` must resolve, point back at the theme that
    /// named it, and be the *other* mode. All three matter separately:
    ///
    /// - an unresolvable id silently falls back to `helm-dark`/`helm-light`;
    /// - a one-way link means ⌘⌥T flips out of a family and cannot flip back
    ///   into it, which is the shape a copy-pasted palette produces;
    /// - two darks paired with each other make ⌘⌥T a no-op for brightness,
    ///   which is the one thing the keystroke is for.
    private static func checkEveryThemeIsAMutualPair(_ ok: inout Bool) {
        print("\n-- pairId: resolves, is mutual, and crosses the mode --")
        for theme in HelmTheme.allThemes {
            guard let pair = HelmTheme.theme(id: theme.pairId) else {
                print("  FAIL \(theme.id): pairId \"\(theme.pairId)\" resolves to no registered theme")
                ok = false
                continue
            }
            if pair.pairId != theme.id {
                print("  FAIL \(theme.id) -> \(pair.id), but \(pair.id) -> \(pair.pairId): the pair is one-way")
                ok = false
            }
            if pair.mode == theme.mode {
                print("  FAIL \(theme.id) and \(pair.id) are both \(theme.mode == .dark ? "dark" : "light")"
                      + " - toggling between them changes no register")
                ok = false
            }
            if pair.id == theme.id {
                print("  FAIL \(theme.id) is its own pair")
                ok = false
            }
        }
        // Discriminating power: the lookup this check depends on must be able
        // to miss, or every `guard let` above passes vacuously.
        if HelmTheme.theme(id: "no-such-palette") != nil {
            print("  FAIL HelmTheme.theme(id:) resolves an id that does not exist - the checks above prove nothing")
            ok = false
        }
        print("  \(HelmTheme.allThemes.count) palettes, \(HelmTheme.allThemes.count / 2) families")
    }

    /// The pairing above is a property of the data; this is the property of
    /// the *path* that reads it. `ThemeManager.toggle()` is what ⌘⌥T calls,
    /// and it is the only thing that can prove the fallback branch is not
    /// being taken - a palette with a broken `pairId` still toggles, just to
    /// the wrong theme.
    ///
    /// Restores the theme it started on: this suite writes the real
    /// `GrandLine` `UserDefaults` domain like every other one
    /// (AGENTS.md's hermeticity note), and
    /// `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` fails the run for a
    /// suite that calls `setTheme` without first reading the current theme.
    private static func checkTogglePathReachesThePair(_ ok: inout Bool) {
        print("\n-- ThemeManager.toggle() lands inside the family --")
        let original = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(original) }

        for theme in HelmTheme.allThemes {
            ThemeManager.shared.setTheme(theme)
            ThemeManager.shared.toggle()
            let landed = ThemeManager.shared.theme
            if landed.id != theme.pairId {
                print("  FAIL \(theme.id): ⌘⌥T landed on \(landed.id), want \(theme.pairId)")
                ok = false
            }
            ThemeManager.shared.toggle()
            if ThemeManager.shared.theme.id != theme.id {
                print("  FAIL \(theme.id): a second ⌘⌥T landed on \(ThemeManager.shared.theme.id), not back home")
                ok = false
            }
        }
        print("  every palette toggles into its own family and back")
    }

    // MARK: Registration

    /// An id collision breaks persistence (`fm.themeID` is the stored key) and
    /// `HelmTheme.theme(id:)` silently resolves to whichever came first; a
    /// duplicate *name* is a picker with two identical-looking cells.
    private static func checkIdsAndNamesAreUnique(_ ok: inout Bool) {
        print("\n-- ids and display names are unique --")
        var seenIds: Set<String> = []
        var seenNames: Set<String> = []
        for theme in HelmTheme.allThemes {
            if !seenIds.insert(theme.id).inserted {
                print("  FAIL duplicate theme id \"\(theme.id)\"")
                ok = false
            }
            if !seenNames.insert(theme.name).inserted {
                print("  FAIL duplicate theme name \"\(theme.name)\"")
                ok = false
            }
        }
        print("  \(seenIds.count) distinct ids, \(seenNames.count) distinct names")
    }

    /// The structural shape every palette has to hold, and which a
    /// hand-transcribed one is exactly as likely to get wrong as a hex:
    ///
    /// - **16 ANSI slots**, parseable. `HelmTheme.channels` maps an
    ///   unparseable string to `0x000000` rather than trapping, so a typo'd
    ///   or `#`-prefixed value becomes a silent black cell.
    /// - **`backgroundHex == chromeBackgroundHex`** for every non-Daylight
    ///   palette. That is the one-step convention
    ///   `fm/grand-line-legacy-terminal-canvas-chrome-match` established to
    ///   kill the seam between the terminal canvas and the chrome around it,
    ///   and `backgroundHex` is simultaneously the page ground and the
    ///   terminal background - so a second surface step reopens that seam.
    ///   Daylight and Dusk are exempt because they carry a real
    ///   `terminalCard` (§6.13), which is the *other* way to solve the same
    ///   problem.
    /// - **`cursorHex == selectionHex == accentHex`** on those same palettes,
    ///   which is what every one of them actually does and what makes the
    ///   accent a single identity rather than three near-misses.
    private static func checkPaletteShape(_ ok: inout Bool) {
        print("\n-- palette shape (16 parseable ANSI slots, one surface step, one accent) --")
        for theme in HelmTheme.allThemes {
            if theme.ansiHex.count != 16 {
                print("  FAIL \(theme.id): \(theme.ansiHex.count) ANSI slots, want 16")
                ok = false
            }
            let fields = theme.ansiHex + [theme.chromeBackgroundHex, theme.chromeInkHex,
                                          theme.chromeLineHex, theme.accentHex,
                                          theme.foregroundHex, theme.backgroundHex,
                                          theme.cursorHex, theme.selectionHex,
                                          theme.selectionTextHex]
            for hex in fields where !isSixDigitHex(hex) {
                print("  FAIL \(theme.id): \"\(hex)\" is not a bare six-digit hex - it parses as black")
                ok = false
            }
            guard theme.terminalCard == nil else { continue }
            if theme.backgroundHex != theme.chromeBackgroundHex {
                print("  FAIL \(theme.id): page \(theme.backgroundHex) and card \(theme.chromeBackgroundHex)"
                      + " differ, and this palette has no terminalCard - that is the terminal seam")
                ok = false
            }
            if theme.cursorHex != theme.accentHex || theme.selectionHex != theme.accentHex {
                print("  FAIL \(theme.id): cursor \(theme.cursorHex) / selection \(theme.selectionHex)"
                      + " are not both the accent \(theme.accentHex)")
                ok = false
            }
        }
        // Discriminating power: the hex validator must actually reject
        // something, or the sweep above is a no-op.
        if isSixDigitHex("#2e3440") || isSixDigitHex("2e344") || isSixDigitHex("gg3440") {
            print("  FAIL the hex validator accepts a malformed value - the sweep above proves nothing")
            ok = false
        }
        print("  \(HelmTheme.allThemes.count) palettes checked")
    }

    private static func isSixDigitHex(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy { $0.isHexDigit }
    }
}

#endif
