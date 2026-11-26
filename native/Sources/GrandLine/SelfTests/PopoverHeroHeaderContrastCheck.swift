// Grand Line - native macOS app.
//
// Part of `FM_RUN_CONTRAST_TESTS` (`HelmContrastSelfTest.run()` calls it).
//
// Full review 4, A-01 and T-04: the Compose, SRE Lead and Claude usage
// popovers printed their second line at 86 percent ink on the plain hero
// palette, which lands under the 4.5:1 text floor in several palettes
// (4.21:1 on Lavender's lighter stop, 3.93:1 on Powder). The notifications
// panel and the menu-bar popover had already moved to the quiet-ink palette,
// and nothing checked the three older call sites.
//
// Two halves, because each catches what the other cannot:
//
// - **A source guard over every `PopoverHeroHeader(` construction** in the
//   app's sources. A new call site without `quietInk:` fails by name, even
//   one this file does not know how to build.
// - **The real headers, painted in every palette.** The Compose and Claude
//   usage popovers' own headers, and the SRE Lead hero from the factory the
//   console builds it with. The subtitle's painted colour is composited over
//   each painted gradient stop and must clear the floor against both.
//
// Pure logic: no window. A header's colours are set by `applyTheme(_:)`, so
// nothing here needs a layout pass.

#if FM_SELFTESTS
import AppKit

extension HelmContrastSelfTest {

    static func checkEveryPopoverHeroHeaderSubtitle(_ ok: inout Bool) {
        print("\n-- every PopoverHeroHeader's second line clears the text floor in every palette (review 4 A-01) --")
        checkPopoverHeroHeaderCallSitesPassQuietInk(&ok)
        checkPopoverHeroHeadersPaintedInEveryPalette(&ok)
    }

    /// Every construction of the header passes `quietInk:`.
    private static func checkPopoverHeroHeaderCallSitesPassQuietInk(_ ok: inout Bool) {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "PopoverHeroHeader.swift" }) else {
            print("  SKIP - sources not present next to this binary")
            return
        }
        var sites: [(String, String)] = []
        for file in files where file.pathExtension == "swift" && file.lastPathComponent != "PopoverHeroHeader.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var rest = text[...]
            while let range = rest.range(of: "PopoverHeroHeader(") {
                // The argument list, up to the matching close parenthesis.
                var depth = 1
                var index = range.upperBound
                while index < rest.endIndex, depth > 0 {
                    if rest[index] == "(" { depth += 1 } else if rest[index] == ")" { depth -= 1 }
                    index = rest.index(after: index)
                }
                let line = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                sites.append(("\(file.lastPathComponent):\(line)", String(rest[range.upperBound..<index])))
                rest = rest[index...]
            }
        }
        // The guard's own power: the five known surfaces are all found, so a
        // rename that hid them would fail here rather than pass empty.
        check(sites.count >= 5, "found only \(sites.count) PopoverHeroHeader call sites, expected at least 5", &ok)
        let missing = sites.filter { !$0.1.contains("quietInk:") }
        for site in missing {
            fail("\(site.0) builds a PopoverHeroHeader without quietInk:, so its 86% second line can fall under 4.5:1", &ok)
        }
        if missing.isEmpty { print("  OK - all \(sites.count) call sites pass quietInk:") }
    }

    /// The three Console surfaces' real headers, painted in every palette.
    private static func checkPopoverHeroHeadersPaintedInEveryPalette(_ ok: inout Bool) {
        let composer = ConsoleComposerController()
        let quota = QuotaUsageController()
        let sreLead = ConsoleController.makeSRELeadHero()
        // Both popovers repaint only a loaded view, so load them first.
        _ = composer.debugContentView
        _ = quota.debugContentView
        defer { composer.shutdown(); quota.shutdown() }
        let heads: [(String, PopoverHeroHeader, (HelmTheme) -> Void)] = [
            ("Compose", composer.debugHeroHeader, { composer.debugApplyTheme($0) }),
            ("Claude usage", quota.debugHeroHeader, { quota.debugApplyTheme($0) }),
            ("SRE Lead", sreLead, { sreLead.applyTheme($0) }),
        ]
        let alpha = Double(PopoverHeroHeader.subtitleAlpha)
        /// The subtitle composited over the worse of the two painted stops.
        func worstRatio(ink: (Double, Double, Double), alpha: Double, stops: [(Double, Double, Double)]) -> Double {
            stops.map { HelmContrast.ratio(HelmContrast.mix(ink, $0, alpha), $0) }.min() ?? 0
        }
        // The check's own power: on the plain palette the same 86% line
        // fails in at least one palette, so a header that fell back to it
        // would be caught rather than pass on a lucky set of themes.
        let plainFails = everyChromePalette.contains { theme in
            let plain = HelmHeroSurface.palette(for: theme)
            return worstRatio(ink: plain.ink, alpha: alpha, stops: [plain.start, plain.end]) < HelmContrast.textTarget
        }
        check(plainFails, "no palette fails on the plain hero palette, so this sweep cannot tell the two apart", &ok)

        var worst: (String, Double) = ("", .infinity)
        for theme in everyChromePalette {
            for (name, head, apply) in heads {
                apply(theme)
                let stops = head.debugGradientColors.compactMap { NSColor(cgColor: $0) }.map(HelmContrast.components)
                guard stops.count == 2, let painted = head.subtitleLabel.textColor?.usingColorSpace(.sRGB) else {
                    fail("\(name) / \(theme.id): the header painted no gradient or no subtitle colour", &ok)
                    continue
                }
                let ratio = worstRatio(ink: HelmContrast.components(painted),
                                       alpha: Double(painted.alphaComponent), stops: stops)
                if ratio < worst.1 { worst = ("\(name) / \(theme.id)", ratio) }
                check(ratio >= HelmContrast.textTarget,
                      "\(name) / \(theme.id): the second line is \(String(format: "%.2f", ratio)):1 on the hero", &ok)
            }
        }
        print("  \(heads.count) headers x \(everyChromePalette.count) palettes, lowest \(worst.0) at \(String(format: "%.2f", worst.1)):1")
    }
}
#endif
