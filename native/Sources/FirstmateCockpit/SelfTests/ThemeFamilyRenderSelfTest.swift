// Manjesh Grand Line - native macOS app.
//
// The render half of `ThemeFamilySelfTest`: a real page, mounted in a real
// `NSWindow`, **painted**, and read back - once per palette, in both
// registers.
//
// It exists for one defect in particular, and the reason it has to be a
// render rather than a colour comparison is that the defect is invisible to
// every colour comparison. AGENTS.md calls it the "half-themed" defect:
// `ThemeManager.swift`'s checklist item 2 requires a theme-aware view to force
// `view.appearance` to the theme's own light/dark mode, and without it the
// layer-backed fills track the palette while everything resolving a *system
// semantic* colour - scroller chrome, the shared field editor, an `NSMenu`, a
// focus ring - follows the OS instead. The palette's own hexes all still
// measure correctly; the page is still wrong. It has shipped four times.
//
// So this asserts two things per palette that a table of hex values cannot:
//
// 1. **The page ground is actually painted in the palette's own colour** -
//    sampled out of a `cacheDisplay` render, not read back off the layer that
//    was just set.
// 2. **The forced appearance wins over the window's**, which is the half-themed
//    defect stated as an experiment rather than as a convention: the probe
//    window is deliberately given the *opposite* appearance before mounting,
//    so a page that merely inherits fails.
//
// The page is `SettingsController` - the page these themes are selected on,
// and the one whose Appearance grid renders a swatch for every one of them.
//
// Window-backed, so it is listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` and guards CI's windowed job. Its pure-logic half
// (`ThemeFamilySelfTest`, the family pairing and the palette shape) guards the
// blocking one.
//
// Hermeticity: the suite changes the theme, so it saves and restores
// `ThemeManager.shared.theme` - AGENTS.md's most-repeated operational lesson,
// and `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` fails the run for a
// suite that does not. Every store it needs is redirected to a scratch path.
//
// `FM_RUN_THEME_FAMILY_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ThemeFamilyRenderSelfTest {
    /// The six families `fm/grandline-new-themes-nord-dracula-etc` added, as
    /// (dark, light) pairs. Named explicitly rather than derived from
    /// `allThemes`, because the claim being made is about these twelve and a
    /// future palette that quietly stopped rendering should fail *this* list's
    /// own membership check below, not silently drop out of the sweep.
    private static let newFamilies: [(String, String)] = [
        ("nord-polar", "nord-snow"),
        ("dracula", "alucard"),
        ("one-dark", "one-light"),
        ("ayu-dark", "ayu-light"),
        ("night-owl", "light-owl"),
        ("oxocarbon-dark", "oxocarbon-light"),
    ]

    static func run() -> Bool {
        print("== new theme families: real render ==")
        var ok = true
        let original = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(original) }

        checkAllTwelveAreRegistered(&ok)
        checkEachPaletteIsActuallyPainted(&ok)

        print(ok ? "== new theme families: PASS ==" : "== new theme families: FAIL ==")
        return ok
    }

    private static func checkAllTwelveAreRegistered(_ ok: inout Bool) {
        print("\n-- the twelve palettes are registered and selectable --")
        for (darkID, lightID) in newFamilies {
            for id in [darkID, lightID] {
                guard let theme = HelmTheme.theme(id: id) else {
                    print("  FAIL \(id) is not in HelmTheme.allThemes")
                    ok = false
                    continue
                }
                let wantDark = id == darkID
                if (theme.mode == .dark) != wantDark {
                    print("  FAIL \(id) is registered as the wrong register")
                    ok = false
                }
            }
        }
        print("  \(newFamilies.count) families, \(newFamilies.count * 2) palettes")
    }

    // MARK: The render

    private static func checkEachPaletteIsActuallyPainted(_ ok: inout Bool) {
        print("\n-- page ground painted, and the forced appearance wins --")
        scratchStores()
        for (darkID, lightID) in newFamilies {
            for id in [darkID, lightID] {
                guard let theme = HelmTheme.theme(id: id) else { continue }
                render(theme: theme, &ok)
            }
        }
    }

    private static func render(theme: HelmTheme, _ ok: inout Bool) {
        // Mandatory around any repeated AppKit construct/teardown loop in a
        // headless suite: nothing turns the run loop, so removed views are
        // never drained and a healthy page reads as a leak.
        autoreleasepool {
            ThemeManager.shared.setTheme(theme)
            let controller = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                                snippetStore: SnippetStore(), dictationStore: DictationStore())
            let window = OffScreenProbe.window(width: 1200, height: 860)
            // The experiment that makes the appearance claim real: hand the
            // window the *wrong* register before mounting. A page that only
            // inherits its appearance now reports the opposite of its palette.
            window.appearance = NSAppearance(named: theme.mode == .dark ? .aqua : .darkAqua)
            window.contentViewController = controller
            let root = controller.view
            root.layoutSubtreeIfNeeded()

            defer {
                window.contentViewController = nil
                window.close()
            }

            guard root.bounds.width > 10, root.bounds.height > 10 else {
                print("  FAIL \(theme.id): the page never laid out (\(root.bounds)) - the sample would be vacuous")
                ok = false
                return
            }

            // 1. The forced appearance.
            let wanted: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
            let resolved = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            if resolved != wanted {
                print("  FAIL \(theme.id): the page resolves \(resolved?.rawValue ?? "nil") under a window forced to"
                      + " the opposite register - this is the half-themed defect")
                ok = false
            }

            // 2. The painted pixel.
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                print("  FAIL \(theme.id): could not build a bitmap rep")
                ok = false
                return
            }
            root.cacheDisplay(in: root.bounds, to: rep)

            // The rep is measured in **pixels**, not points - a factor of two
            // on a retina machine, so sampling point coordinates lands in the
            // top-left quadrant of what was rendered.
            let scaleX = CGFloat(rep.pixelsWide) / root.bounds.width
            let scaleY = CGFloat(rep.pixelsHigh) / root.bounds.height
            // Page ground that is genuinely outside every card, outside the
            // nav column's band and outside any scroller track.
            //
            // It used to be the bottom-*left* corner, `x = 2`, and two things
            // in `fm/grandline-settings-sidebar-differentiation-fix` broke
            // that. The column got a toned band of its own running the page's
            // full height from its very left edge, so `x = 2` now samples
            // `HelmTheme.sidePanelFill` rather than the ground (0.1059 away on
            // `oxocarbon-light` - the band's real one-step offset, not a
            // defect). And moving the sample a gutter right of the band put it
            // *inside the theme grid*, where it read the **selected** theme
            // card's accent wash - which failed on `one-dark` alone, because
            // one-dark's own card is the one that lands at that corner when
            // one-dark is the theme being rendered. A point that is only
            // outside the cards for fifteen palettes out of sixteen is not a
            // ground sample.
            //
            // So the point is the bare strip **above the toolbar**: the
            // toolbar is inset `s3` from the page's top edge, nothing is
            // mounted in that strip, it is above the scroll view (so no
            // scroller track) and it is page ground at every window size -
            // unlike the right-hand margin, which this window's 900pt-wide
            // root does not actually have (the cards end 24pt from its edge).
            // Right of the band, so it is the content region's ground.
            let band = controller.debugSidebarPanel.frame
            let cards = controller.debugPageContainerFrameInRoot
            let contentX = band.maxX + HelmMetrics.s5
            let contentY = root.bounds.maxY - HelmMetrics.s3 / 2
            // Discriminating power, asserted rather than assumed: a sample
            // point that has drifted inside a card or back under the band
            // measures those, and would do it silently.
            guard contentX < root.bounds.maxX, contentX > band.maxX,
                  !cards.insetBy(dx: -2, dy: -2).contains(NSPoint(x: contentX, y: contentY)) else {
                print(String(format: "  FAIL %@: the ground sample (%.1f, %.1f) is not outside the band"
                             + " (ends %.1f) and the cards (%@) - it would be vacuous",
                             theme.id, contentX, contentY, band.maxX, NSStringFromRect(cards)))
                ok = false
                return
            }
            let px = Int(contentX * scaleX)
            // `SettingsController`'s root is a plain unflipped `NSView`, so the
            // rep's row 0 is the view's top edge - the row is mirrored.
            let py = Int((root.bounds.height - contentY) * scaleY)
            guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                  let sampled = rep.colorAt(x: px, y: py) else {
                print("  FAIL \(theme.id): the sample point fell outside the rep")
                ok = false
                return
            }
            // Compared in **`rep.colorSpace`**, never by converting the sample
            // into sRGB: `bitmapImageRepForCachingDisplay` returns a rep in the
            // display's own profile inside a real window, and the sRGB
            // conversion is only correct outside one.
            guard let expected = HelmTheme.nsColor(theme.backgroundHex).usingColorSpace(rep.colorSpace) else {
                print("  FAIL \(theme.id): could not express the palette's ground in the rep's space")
                ok = false
                return
            }
            let delta = distance(sampled, expected)
            if delta >= 0.06 {
                print(String(format: "  FAIL %@: the painted page ground is %.4f away from the palette's own %@",
                             theme.id, delta, theme.backgroundHex))
                ok = false
            }

            // Discriminating power: the same sample must NOT match this
            // theme's own pair, or "the page is painted in this palette" is a
            // claim the fixture cannot actually distinguish.
            if let pair = HelmTheme.theme(id: theme.pairId),
               let pairGround = HelmTheme.nsColor(pair.backgroundHex).usingColorSpace(rep.colorSpace) {
                let pairDelta = distance(sampled, pairGround)
                if pairDelta < 0.06 {
                    print(String(format: "  FAIL %@: the sampled pixel matches %@'s ground too (%.4f) -"
                                 + " the check above proves nothing", theme.id, pair.id, pairDelta))
                    ok = false
                }
            }

            print(String(format: "  %-18@ ground %@ delta %.4f  appearance %@",
                         theme.id as NSString, theme.backgroundHex as NSString, delta,
                         (resolved?.rawValue ?? "nil") as NSString))
        }
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    /// Nothing here may touch real captain data - every store `SettingsController`
    /// constructs is redirected to a scratch directory first.
    private static func scratchStores() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-family-render-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
    }
}

#endif
