// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's §3H - overlays: the ⌘K palette, menus, the
// dictation HUD and the lock screen (H1-H4).
//
// What is asserted, and what deliberately is not. Most of §3H is motion and
// material, and a check that measures an animation's duration is taste - it
// only ever fails for the wrong reason. So this spends its assertions on the
// things that can silently stop working:
//
//   1. **H1's per-item icons are per *item*.** "Destinations use their real
//      artwork/hue, commands use their category tint, hosts their accent" -
//      the finding's own complaint is "every action row wears the same
//      colored square", and a regression to that renders perfectly and is
//      invisible to every other check.
//   2. **H1's material cannot break contrast.** The panel paints its fill at
//      less than full opacity over a material, so its effective surface is
//      somewhere between the two - and the ink has to clear the floor against
//      *both* ends. The material itself cannot be seen from here (the window
//      server composites it), so the damage is bounded rather than guessed.
//   3. **H1's footer strip is `HelmKeyHint`**, not a second keycap recipe.
//   4. **H2's symbols are template images.** A non-template menu image keeps
//      its own colour on a highlighted row, which is the "two icon languages"
//      tell this whole section is about - and it looks fine until the row is
//      highlighted.
//   5. **H3's waveform animates and stops**, and Reduce Motion gets neither
//      the animation nor a slower one.
//   6. **H4's sea is a gradient and the unlock field has a glow host.** Those
//      are the two halves of that finding not already shipped; the rest of it
//      (sky gradient, celestial glow, parallax) predates this and is pinned
//      here so a later change cannot quietly undo it.
//
// Window-backed, so it is in `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with:
//   swift build && FM_RUN_OVERLAYS_MODERNIZATION_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum OverlaysModernizationSelfTest {

    static func run() -> Bool {
        let restoreTheme = ThemeManager.shared.theme
        defer {
            ThemeManager.shared.setTheme(restoreTheme)
            HelmMotion.reducedOverrideForTests = nil
        }
        var allOK = true
        for check in [checkPaletteIconsArePerItem,
                      checkPaletteMaterialCannotBreakContrast,
                      checkPaletteFooterStrip,
                      checkMenuSymbolsAreTemplates,
                      checkDictationWaveform,
                      checkLockScreenSeaAndField] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "OverlaysModernizationSelfTest: all checks passed"
                    : "OverlaysModernizationSelfTest: FAILED")
        return allOK
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    private static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a, let b else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    private static func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 700, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += descendants(type, in: sub) }
        return found
    }

    // MARK: 1. H1 - per-item icons

    private static func checkPaletteIconsArePerItem(_ ok: inout Bool) {
        print("\n-- H1: a row's icon is its own identity, not its kind's --")
        let theme = ThemeManager.shared.theme
        var problems: [String] = []

        // A destination row: its own artwork where it has any, its own hue.
        let destination = RailDestination.strawHat
        let destinationItem = UnifiedSearchItem(kind: .action, id: "a", title: "Switch",
                                                meta: "Destination",
                                                icon: .destination(destination), activate: {})
        let destinationRow = UnifiedSearchRowView()
        destinationRow.configure(item: destinationItem, theme: theme, selected: false)
        _ = makeWindow(destinationRow)
        if destination.drillHeaderArtwork != nil && !destinationRow.debugTileUsesArtwork {
            problems.append("a destination with real artwork rendered a plain glyph")
        }

        // A host row: the captain's own accent, used literally.
        let hostItem = UnifiedSearchItem(kind: .host, id: "h", title: "Prod", meta: "",
                                         icon: .literal(hex: "ff8179", symbol: "server.rack"),
                                         activate: {})
        let hostRow = UnifiedSearchRowView()
        hostRow.configure(item: hostItem, theme: theme, selected: false)
        _ = makeWindow(hostRow)
        // Component-wise, never a luminance ratio: that passes for two
        // entirely different hues of similar brightness.
        let wanted = HelmContrast.tintedSurface(tintHex: "ff8179", theme: theme,
                                                target: HelmContrast.nonTextTarget,
                                                washSteps: HelmContrast.tileWashSteps).fill
        if !sameColor(hostRow.debugFlatTileFill, wanted) {
            problems.append("a host row did not take the host's own accent")
        }

        // And the finding's actual complaint: two rows of different kinds must
        // not resolve to the same square.
        let commandInfo = CommandLibraryCategory.info(for: "kubernetes")
        let commandItem = UnifiedSearchItem(kind: .command, id: "c", title: "Get pods", meta: "",
                                            icon: .tinted(commandInfo.tint, symbol: commandInfo.symbol),
                                            activate: {})
        let commandRow = UnifiedSearchRowView()
        commandRow.configure(item: commandItem, theme: theme, selected: false)
        _ = makeWindow(commandRow)
        if sameColor(commandRow.debugFlatTileFill, hostRow.debugFlatTileFill) {
            problems.append("a command row and a host row resolve to the same square")
        }
        // Every category resolves a tint, and not every category shares one.
        let tints = Set(CommandLibraryCategory.all.map { "\($0.tint)" })
        if tints.count < 4 {
            problems.append("\(tints.count) distinct category tints - not differentiated")
        }
        // `.critical` is a *state*, and a category asserts none.
        if CommandLibraryCategory.all.contains(where: { "\($0.tint)" == "critical" }) {
            problems.append("a category took the critical tint")
        }

        if problems.isEmpty {
            print("  OK   destination artwork, host accent, category tint - three sources, three squares")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 2. H1 - the material's contrast cost is bounded

    private static func checkPaletteMaterialCannotBreakContrast(_ ok: inout Bool) {
        print("\n-- H1: the material cannot break the palette's contrast --")
        // The material itself is composited by the window server and is
        // invisible to `cacheDisplay`, so this bounds the damage rather than
        // measuring it: the panel's effective surface lies between its own
        // fill and whatever that fill is laid over, and the ink must clear the
        // text floor at both ends. Same shape as B1's own bound for the bar.
        var problems: [String] = []
        for theme in HelmTheme.allThemes where theme.isDaylight {
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let under = HelmTheme.nsColor(theme.backgroundHex)
            // Straight sRGB, via the app's own `mix` - not
            // `NSColor.blended(withFraction:of:)`, which converts into a
            // *calibrated* space first and drifts from the composite alpha
            // blending actually performs (the lesson Phase 4's segmented-tab
            // correction records).
            let effective = HelmContrast.mix(HelmContrast.components(surface),
                                             HelmContrast.components(under),
                                             Double(UnifiedSearchController.daylightFillAlpha))
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            for (name, against) in [("its own fill", HelmContrast.components(surface)),
                                    ("what it composites over", effective)] {
                let ratio = HelmContrast.ratio(HelmContrast.components(ink), against)
                if ratio < HelmContrast.textTarget {
                    problems.append("\(theme.id) ink is \(String(format: "%.2f", ratio)):1 against \(name)")
                }
            }
        }
        if UnifiedSearchController.daylightFillAlpha >= 1 {
            problems.append("the fill is fully opaque - the material can never read")
        }
        if problems.isEmpty {
            print("  OK   ink clears the floor at both ends of the blend, alpha \(fmt(UnifiedSearchController.daylightFillAlpha))")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 3. H1 - the footer strip

    private static func checkPaletteFooterStrip(_ ok: inout Bool) {
        print("\n-- H1: a persistent footer strip of real keycaps --")
        let palette = UnifiedSearchController(index: UnifiedSearchIndex())
        guard let content = palette.window?.contentView else {
            print("  FAIL the palette has no content view")
            ok = false
            return
        }
        content.layoutSubtreeIfNeeded()
        let hints = descendants(HelmKeyHint.self, in: content)
        var problems: [String] = []
        if hints.count != 2 {
            problems.append("\(hints.count) key hints in the footer, want 2 (run + close)")
        }
        let glyphs = hints.flatMap(\.debugCapGlyphs)
        if !glyphs.contains(HelmKeyHint.returnKey) { problems.append("no Return keycap") }
        if !glyphs.contains(HelmKeyHint.command) { problems.append("no Command keycap") }
        // F2c's own glyph rule reaches here too.
        if glyphs.contains("\u{23ce}") { problems.append("the footer uses U+23CE") }
        if problems.isEmpty {
            print("  OK   \(hints.count) hints: \(glyphs.joined(separator: " "))")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 4. H2 - menu symbols

    private static func checkMenuSymbolsAreTemplates(_ ok: inout Bool) {
        print("\n-- H2: menu items carry template SF Symbols --")
        var problems: [String] = []
        let item = NSMenuItem(title: "Probe", action: nil, keyEquivalent: "")
        item.withSymbol("trash")
        guard let image = item.image else {
            problems.append("withSymbol did not set an image")
            print("  FAIL \(problems.joined(separator: "; "))")
            ok = false
            return
        }
        // A non-template image keeps its own colour on a highlighted row -
        // which looks fine until the row is highlighted, and is exactly the
        // mixed-icon-language tell H2 is about.
        if !image.isTemplate { problems.append("the symbol is not a template image") }
        // A name that does not resolve must leave the item text-only rather
        // than blank - `NSImage(systemSymbolName:)` returns nil silently, and
        // this app has shipped an invisible icon that way before.
        let bogus = NSMenuItem(title: "Probe", action: nil, keyEquivalent: "")
        bogus.withSymbol("definitely.not.a.real.symbol.name")
        if bogus.image != nil { problems.append("an unresolvable symbol still set an image") }

        // And the real menus carry them. A source sweep, because building the
        // whole main menu needs a real `AppDelegate`.
        if let dir = SelfTestSources.appSourceDirectory(),
           let main = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8) {
            let annotated = main.components(separatedBy: ".withSymbol(").count - 1
                + main.components(separatedBy: ", symbol: \"").count - 1
            if annotated < 20 {
                problems.append("only \(annotated) main-menu items carry a symbol")
            }
        } else {
            print("  NOTE sources not present - the main-menu half is skipped")
        }

        if problems.isEmpty {
            print("  OK   template image, silent-nil handled, main menu annotated")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 5. H3 - the waveform

    private static func checkDictationWaveform(_ ok: inout Bool) {
        print("\n-- H3: the waveform animates while listening and stops after --")
        HelmMotion.reducedOverrideForTests = false
        let hud = DictationHUDController()
        var problems: [String] = []

        hud.handle(.recording)
        if !hud.debugIsAnimatingIcon { problems.append("not animating while listening") }
        // The macOS-13 equivalent of `.variableColor`: `waveform` is a
        // variable-value symbol, so stepping that value lights its bars in
        // sequence. If that ever stops resolving the opacity pulse still runs,
        // which is why `debugIsAnimatingIcon` and this are separate reads.
        if !hud.debugUsesVariableColor {
            print("  NOTE the waveform fell back to the opacity pulse (variable value unavailable)")
        }
        hud.handle(.ready)
        if hud.debugIsAnimatingIcon { problems.append("still animating after it stopped listening") }

        // Reduce Motion gets neither the animation nor a slower one.
        HelmMotion.reducedOverrideForTests = true
        hud.handle(.recording)
        if hud.debugIsAnimatingIcon { problems.append("Reduce Motion still animates") }
        hud.handle(.ready)
        HelmMotion.reducedOverrideForTests = nil

        if problems.isEmpty {
            print("  OK   animates, stops, and holds still under Reduce Motion")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 6. H4 - the sea and the unlock field

    private static func checkLockScreenSeaAndField(_ ok: inout Bool) {
        print("\n-- H4: the sea is a gradient, the unlock field has a glow --")
        let lock = LockScreenController()
        lock.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        _ = makeWindow(lock.view)
        lock.view.layoutSubtreeIfNeeded()

        var problems: [String] = []
        let scene = lock.debugSceneLayers
        // H4's own words: "two subtle gradients (sky, sea)". The sky was
        // already one; the sea was a flat fill.
        if scene.skyStops < 2 { problems.append("the sky is not a gradient") }
        if scene.seaStops < 2 { problems.append("the sea is not a gradient") }
        if scene.backSeaStops < 2 { problems.append("the far swell is not a gradient") }
        // Pinned rather than changed: these predate H4 and a later edit must
        // not quietly undo them.
        if scene.celestialGlowRadius <= 0 { problems.append("no glow behind the sun/moon") }
        if scene.driftDurations.count < 2 { problems.append("only one wave layer drifts - no parallax") }
        if Set(scene.driftDurations).count < 2 {
            problems.append("both swells drift at the same rate - that is not parallax")
        }
        // H4: "the unlock field given the composer-card focus glow". A sunken
        // well clips, so the glow needs an un-clipped host - without one the
        // field gets the border and nothing else.
        if !lock.debugPasswordFieldHasGlowHost {
            problems.append("the unlock field has no glow host")
        }

        if problems.isEmpty {
            print("  OK   sky/sea gradients, celestial glow, \(scene.driftDurations.count)-layer parallax, field glow")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }
}

#endif
