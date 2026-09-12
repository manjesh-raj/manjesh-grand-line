// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_ICONS_TYPOGRAPHY_TESTS=1 .build/debug/FirstmateCockpit`
//
// The UI modernization audit's §3I (iconography) and §3J (typography).
//
// **Pure logic and source guards, so it runs in CI** - unlike its four sibling
// suites in this rollout, which mount real windows. That is not a shortcut: I1
// and I2 are *policy* findings ("define where each language lives", "pair the
// weight to the adjacent label"), and a policy is only ever violated in source.
// A raster app-icon dropped into a toolbar renders perfectly; a symbol left at
// the default light weight renders perfectly. Neither is visible to a check
// that looks at pixels, which is precisely why both drifted far enough to be
// worth a finding.
//
// What *is* asserted behaviourally is the half a source grep cannot see: that
// a tile's symbol really comes back hierarchically rendered, and that the
// retired serif is genuinely unreachable through the type scale.

#if FM_SELFTESTS

import AppKit
import Foundation

enum IconsTypographySelfTest {

    static func run() -> Bool {
        print("== icons + typography (audit I1/I2, J1/J2) ==")
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if condition { return }
            print("  FAIL \(message)")
            ok = false
        }

        checkHierarchicalTiles(check)
        checkRasterIsPageIdentityOnly(check)
        checkSymbolsCarryAWeight(check)
        checkSerifIsRetired(check)
        checkBodyAndCaptionBump(check)

        print(ok ? "IconsTypographySelfTest: all checks passed"
                 : "IconsTypographySelfTest: FAILURES")
        return ok
    }

    // MARK: I1 - one icon language, rendered hierarchically

    /// §3I1's own suggested fix: "hierarchical rendering" for the shared tile
    /// components, so a symbol reads as one object with depth rather than a
    /// flat monochrome stencil.
    ///
    /// Behavioural, and it has to be: `SymbolConfiguration(hierarchicalColor:)`
    /// is applied at build time and leaves no property to read back, so the
    /// only evidence is the rendered image's own configuration. A site that
    /// dropped the configuration would still produce a perfectly good-looking
    /// glyph - just a flat one - which is the whole reason this is checked.
    private static func checkHierarchicalTiles(_ check: (Bool, String) -> Void) {
        print("\n-- I1: shared tiles render hierarchically --")
        let theme = ThemeManager.shared.theme

        let tile = IconTileView()
        tile.configure(symbol: "bolt.fill", tint: .accent)
        tile.applyTheme(theme)
        check(tile.debugRenderedImage != nil, "IconTileView rendered no image at all")
        if let image = tile.debugRenderedImage {
            check(HelmSymbol.isHierarchical(image),
                  "IconTileView's symbol is flat - I1 asks for hierarchical rendering")
        }

        let stat = HelmStatTile(symbol: "checkmark.seal.fill", value: "3", caption: "Ready to merge")
        stat.applyTheme(theme)
        check(stat.debugRenderedIcon != nil, "HelmStatTile rendered no icon")
        if let image = stat.debugRenderedIcon {
            check(HelmSymbol.isHierarchical(image), "HelmStatTile's symbol is flat")
        }

        let empty = HelmEmptyState(symbol: "tray", title: "Nothing here yet", body: "Nothing to show.")
        empty.applyTheme(theme)
        check(empty.debugRenderedIcon != nil, "HelmEmptyState rendered no icon")
        if let image = empty.debugRenderedIcon {
            check(HelmSymbol.isHierarchical(image), "HelmEmptyState's symbol is flat")
        }

        // `HelmSymbol.weight(for:)` is the pairing I2 asks for. A semibold
        // label wants a semibold glyph, not the view's default.
        check(HelmSymbol.weight(for: .semibold) == .semibold,
              "HelmSymbol.weight does not pass a semibold text weight through")
        check(HelmSymbol.weight(for: .heavy) == .bold,
              "HelmSymbol.weight should cap a display weight at .bold - SF Symbols has no .heavy")
        print("  OK   IconTileView / HelmStatTile / HelmEmptyState all hierarchical;"
              + " weight pairing passes semibold through")
    }

    // MARK: I1 - where each language lives

    /// §3I1 is the policy statement the rest of this rollout implemented
    /// piecemeal: "raster app-icons only as page identity (drill header +
    /// canvas card tile); bar/toolbar/menu/row icons always SF Symbols in the
    /// domain hue; palette rows use symbol + hue".
    ///
    /// `RailDestination.drillHeaderArtwork` is the one door to the raster set,
    /// so the policy is expressible as: what a reader is allowed to *do* with
    /// it. Every sanctioned use hands it to a component as an `artwork:`
    /// argument - the drill header, the canvas card's gradient tile, and D4's
    /// empty-state watermark, which is the page's own identity filling the
    /// page's own empty content area. The violation this catches is the one
    /// that actually happened twice: handing it straight to an `NSButton` or
    /// a row's image view, which is how five app squares ended up in the
    /// floating bar and how the palette briefly grew them too.
    ///
    /// **Deliberately a use-shape rule rather than a list of allowed files.**
    /// A filename allowlist has to be edited every time a page adds an empty
    /// state, so it would be rotting from the day it was written - and every
    /// edit to it is an opportunity to wave a real violation through.
    ///
    /// B2 (#375) took raster off the floating bar; H1 (#380) briefly put it in
    /// the palette and I1 narrows H1 there - see the `.destination` case in
    /// `UnifiedSearchRowView.configure`.
    private static func checkRasterIsPageIdentityOnly(_ check: (Bool, String) -> Void) {
        print("\n-- I1: raster artwork is page identity only --")
        guard let files = sourceFiles() else {
            print("  SKIP source guard - sources not present next to this binary")
            return
        }
        var offenders: [String] = []
        var uses = 0
        for file in files where file.pathExtension == "swift" {
            if ["RailDestination.swift", "IconsTypographySelfTest.swift"]
                .contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (n, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                guard line.contains("drillHeaderArtwork") else { continue }
                uses += 1
                // The label may sit on this line or open a multi-line call a
                // line or two above it.
                let window = lines[max(0, n - 2)...n].joined(separator: "\n")
                let handedToAComponent = window.contains("artwork:") || window.contains(".artwork =")
                if !handedToAComponent { offenders.append("\(file.lastPathComponent):\(n + 1)") }
            }
        }
        if offenders.isEmpty {
            print("  OK   \(uses) raster uses, every one handed to a page-identity component")
        } else {
            for o in offenders {
                check(false, "\(o) uses drillHeaderArtwork outside a page-identity component"
                      + " - I1 keeps raster off bars, toolbars, menus and rows")
            }
        }
    }

    // MARK: I2 - a symbol's weight is paired to its label

    /// §3I2: "symbols render at default weight in tiles; several look light
    /// against bold labels ... `.medium`/`.semibold` symbol configurations
    /// paired to the adjacent text weight."
    ///
    /// Source-guarded because the defect is an *absence*: a symbol built with
    /// no configuration renders at the image view's default, which looks like
    /// a deliberate light glyph rather than an oversight. So the rule is that
    /// every symbol this app builds states its weight somewhere - either by
    /// routing through `HelmSymbol.image` or by carrying its own
    /// `SymbolConfiguration`.
    private static func checkSymbolsCarryAWeight(_ check: (Bool, String) -> Void) {
        print("\n-- I2: every symbol states a weight --")
        guard let files = sourceFiles() else {
            print("  SKIP source guard - sources not present next to this binary")
            return
        }
        var offenders: [String] = []
        var counted = 0
        for file in files where file.pathExtension == "swift" {
            // `HelmSymbol` is the helper every other site routes through.
            if ["HelmSymbol.swift", "IconsTypographySelfTest.swift"]
                .contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (n, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                guard line.contains("NSImage(systemSymbolName") else { continue }
                counted += 1
                // The configuration may sit on this line or on one of the next
                // few - `withSymbolConfiguration` is routinely chained after a
                // multi-line initializer.
                let window = lines[n..<min(n + 5, lines.count)].joined(separator: "\n")
                // Three equally valid ways to state a weight: build the image
                // with a configuration, chain one on, or set one on the image
                // *view* (`NSImageView.symbolConfiguration`), which several
                // sites do and which renders identically.
                let stated = window.contains("withSymbolConfiguration")
                    || window.contains("SymbolConfiguration")
                    || window.contains("symbolConfiguration")
                    || window.contains("variableValue:")     // the dictation waveform
                if !stated { offenders.append("\(file.lastPathComponent):\(n + 1)") }
            }
        }
        if offenders.isEmpty {
            print("  OK   \(counted) raw symbol sites, every one weighted")
        } else {
            for o in offenders {
                check(false, "\(o) builds a symbol with no weight - route it through HelmSymbol.image")
            }
        }
    }

    // MARK: J1 - the serif is retired

    /// §3J1: "Keep serif *nowhere*." The lock screen was the one place the
    /// finding was willing to keep one, and it never had one - it has been on
    /// `HelmType.rounded(...)` since it was rebuilt.
    ///
    /// `HelmContrastSelfTest.checkPageTitleVoice` carries the source half
    /// (nothing may name Georgia). What is asserted here is the part a grep
    /// cannot reach: that the *type scale itself* offers no route back to it,
    /// and that the one site the finding names by name actually moved.
    private static func checkSerifIsRetired(_ check: (Bool, String) -> Void) {
        print("\n-- J1: the serif is retired --")
        let georgia = NSFont(name: "Georgia", size: 22)
        check(georgia != nil, "Georgia is not installed here, so this check cannot prove anything")

        for voice in [HelmType.Voice.sans, .display] {
            let name = HelmType.pageTitle(voice).fontName
            check(name != georgia?.fontName,
                  "pageTitle(\(voice)) still resolves to Georgia")
        }
        check(HelmType.heroTitle().fontName != georgia?.fontName, "heroTitle resolves to Georgia")
        check(HelmType.drillTitle().fontName != georgia?.fontName, "drillTitle resolves to Georgia")

        // The rounded face is the one J1 says is right, and the display voice
        // must actually be on it rather than merely off Georgia.
        let rounded = HelmType.rounded(HelmType.scaled(22), .heavy)
        check(HelmType.pageTitle(.display).fontName == rounded.fontName,
              "pageTitle(.display) is \(HelmType.pageTitle(.display).fontName), want the rounded face")

        guard let files = sourceFiles() else { return }
        // "Fleet hero -> heroTitle()" is the finding's own named site: the
        // canvas greeting one click away is already a heroTitle, and "same
        // words, two voices" was the defect.
        guard let fleet = files.first(where: { $0.lastPathComponent == "FleetController.swift" }),
              let text = try? String(contentsOf: fleet, encoding: .utf8) else { return }
        check(text.contains("greetingLabel.font = HelmType.heroTitle()"),
              "Fleet's greeting is not on heroTitle() - J1 names that site explicitly")
        print("  OK   no route back to Georgia; Fleet's hero matches the canvas greeting")
    }

    // MARK: J2 - the deferred body bump

    /// §3J2: "take the deferred bump (body 12 -> 13, caption 11.5 -> 12)."
    ///
    /// The row-height reflow this causes is swept by
    /// `TextScaleRowHeightSelfTest`, which measures every accent-row shape in
    /// the app against the height its list gives it. What is asserted here is
    /// the token change itself, and - the part worth pinning - that the bump
    /// did not walk into `minimumUIPointSize`'s floor and quietly stop
    /// meaning anything.
    private static func checkBodyAndCaptionBump(_ check: (Bool, String) -> Void) {
        print("\n-- J2: body 13, caption 12 --")
        check(abs(HelmType.body().pointSize - HelmType.scaled(13)) < 0.01,
              "body() is \(HelmType.body().pointSize)pt, want 13")
        check(abs(HelmType.caption().pointSize - HelmType.scaled(12)) < 0.01,
              "caption() is \(HelmType.caption().pointSize)pt, want 12")
        check(HelmType.caption().pointSize < HelmType.body().pointSize,
              "caption is no longer smaller than body - the two roles collapsed")
        check(HelmType.caption().pointSize > HelmType.minimumUIPointSize,
              "caption landed on the \(HelmType.minimumUIPointSize)pt floor, so the bump is a no-op")

        // GL-32's floor still applies and still bites the one role below it.
        check(abs(HelmType.captionSmall().pointSize - HelmType.minimumUIPointSize) < 0.01,
              "captionSmall no longer floors at minimumUIPointSize")
        print("  OK   body \(HelmType.body().pointSize) / caption \(HelmType.caption().pointSize),"
              + " floor \(HelmType.minimumUIPointSize) intact")
    }

    // MARK: -

    private static func sourceFiles() -> [URL]? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else { return nil }
        return files
    }
}

#endif
