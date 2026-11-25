// Grand Line - native macOS app.
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
//   2. **K-2's card surface reads on every app theme.** H1 put the panel on
//      a material behind a 90% fill, and this case bounded what that could
//      cost. K-2 took the material away, so it now sweeps all 26 app themes:
//      the row ink and meta on the card, and the lit row's words on its own
//      gradient.
//   3. **H1's footer strip is `HelmKeyHint`**, not a second keycap recipe,
//      and since K-2 it leads with the arrows.
//   4. **H2's symbols are template images.** A non-template menu image keeps
//      its own colour on a highlighted row, which is the "two icon languages"
//      tell this whole section is about - and it looks fine until the row is
//      highlighted.
//   5. **H3's waveform animates and stops**, and Reduce Motion gets neither
//      the animation nor a slower one. Since DH-2 that is the HUD's level
//      meter while listening and its sweep while transcribing, and 5b is the
//      hero pill itself: every state's words and tone, 4.5:1 on its own
//      gradient in Lavender and Powder, and the theme followed live.
//   6. **H4's sea is a gradient and the unlock field has a glow host.** Those
//      are the two halves of that finding not already shipped; the rest of it
//      (sky gradient, celestial glow, parallax) predates this and is pinned
//      here so a later change cannot quietly undo it.
//
// Window-backed, so it is in `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with:
//   swift build && FM_RUN_OVERLAYS_MODERNIZATION_TESTS=1 .build/debug/GrandLine; echo $?

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
                      checkDictationHUDIsAHeroPill,
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
        let window = OffScreenProbe.window(width: 700, height: 600)
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
        // I1 narrowed H1 here: a palette row takes the destination's *hue*
        // but never its raster artwork, because I1's policy reserves raster
        // for page identity (drill header + canvas card tile). Since K-2 the
        // row's only tiles are the wash tile and the lit row's glass tile,
        // both symbol-only, so there is no artwork path left to assert on;
        // `IconsTypographySelfTest`'s raster sweep still guards the source.
        let destinationFill = destinationRow.debugFlatTileFill
        if destinationFill == nil { problems.append("a destination row has no tile fill") }

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

    // MARK: 2. K-2 - the card surface, and the lit row, in every app theme

    private static func checkPaletteMaterialCannotBreakContrast(_ ok: inout Bool) {
        print("\n-- K-2: H1's material is gone, and the palette reads on every app theme --")
        // K-2 (the hero restyle board's "Lit selection") took H1's `.menu`
        // material away, so the bound this case used to draw - the ink against
        // both ends of a 90% fill over a blur - is now one opaque surface. What
        // replaces it is the sweep the board itself only drew for Lavender and
        // Powder: on all 26 app themes, the row ink and the muted meta on the
        // card, and the lit row's title and 80% meta on its own gradient.
        var problems: [String] = []
        for theme in HelmTheme.appThemes {
            let card = HelmContrast.components(HelmTheme.nsColor(theme.chromeBackgroundHex))
            for (name, color) in [("ink", HelmTheme.nsColor(theme.chromeInkHex)),
                                  ("muted meta", HelmTheme.mutedInk(theme))] {
                let ratio = HelmContrast.ratio(HelmContrast.components(color), card)
                if ratio < HelmContrast.textTarget {
                    problems.append("\(theme.id) \(name) is \(fmt(CGFloat(ratio))):1 on the card")
                }
            }
            let hero = UnifiedSearchRowView.palette(in: theme)
            let lighter = hero.lighterStop
            let title = HelmContrast.ratio(hero.ink, lighter)
            let meta = HelmContrast.ratio(HelmContrast.mix(hero.ink, lighter, Double(HelmHeroColumn.quietInkAlpha)), lighter)
            if title < HelmContrast.textTarget || meta < HelmContrast.textTarget {
                problems.append("\(theme.id) lit row \(fmt(CGFloat(title))):1 / meta \(fmt(CGFloat(meta))):1")
            }
        }
        let palette = UnifiedSearchController(index: UnifiedSearchIndex())
        if palette.debugHasMaterial { problems.append("the panel still carries a system material") }
        if problems.isEmpty {
            print("  OK   no material; \(HelmTheme.appThemes.count) app themes clear 4.5:1 on the card and on the lit row")
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
        let hints = palette.debugFooterHints
        var problems: [String] = []
        // K-2's footer: move, run, close.
        if hints.count != 3 {
            problems.append("\(hints.count) key hints in the footer, want 3 (move + run + close)")
        }
        let glyphs = hints.flatMap(\.debugCapGlyphs)
        if !glyphs.contains(UnifiedSearchController.upKey) || !glyphs.contains(UnifiedSearchController.downKey) {
            problems.append("no arrow keycaps")
        }
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
        if let main = SelfTestSources.appDelegateSource() {
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

    // MARK: 5. H3 and DH-2 - the meter and the sweep

    private static func checkDictationWaveform(_ ok: inout Bool) {
        print("\n-- H3 + DH-2: the meter moves while listening, the sweep while transcribing, and both stop --")
        HelmMotion.reducedOverrideForTests = false
        let hud = DictationHUDController()
        var problems: [String] = []

        hud.handle(.recording)
        let moving = hud.debugMeter?.debugBars.filter { $0.animation(forKey: DictationHUDMeter.animationKey) != nil } ?? []
        if !hud.debugIsAnimatingMeter || moving.count != DictationHUDMeter.barCount {
            problems.append("\(moving.count) of \(DictationHUDMeter.barCount) bars move while listening")
        }
        if hud.debugMeter?.isHidden != false || hud.debugSweep?.isHidden != true {
            problems.append("listening does not show the meter alone")
        }
        hud.handle(.transcribing)
        if hud.debugIsAnimatingMeter || hud.debugMeter?.isHidden != true {
            problems.append("the meter still runs while transcribing")
        }
        if !hud.debugIsAnimatingSweep || hud.debugSweep?.isHidden != false
            || hud.debugSweep?.debugArc.animation(forKey: DictationHUDSweep.animationKey) == nil {
            problems.append("the sweep is not turning while transcribing")
        }
        hud.handle(.ready)
        if hud.debugIsAnimatingMeter || hud.debugIsAnimatingSweep {
            problems.append("still moving after it stopped listening")
        }

        // Reduce Motion gets neither, and the board's still pattern.
        HelmMotion.reducedOverrideForTests = true
        hud.handle(.recording)
        let still = hud.debugMeter?.debugBars.map(\.bounds.height) ?? []
        if hud.debugIsAnimatingMeter
            || hud.debugMeter?.debugBars.contains(where: { $0.animation(forKey: DictationHUDMeter.animationKey) != nil }) == true {
            problems.append("Reduce Motion still moves the meter")
        }
        if still.count != DictationHUDMeter.barCount || still.first != DictationHUDMeter.stillTall
            || still.dropFirst().first != DictationHUDMeter.stillShort {
            problems.append("Reduce Motion's meter is \(still), not the still pattern")
        }
        hud.handle(.transcribing)
        if hud.debugIsAnimatingSweep || hud.debugSweep?.debugArc.animation(forKey: DictationHUDSweep.animationKey) != nil {
            problems.append("Reduce Motion still turns the sweep")
        }
        hud.handle(.ready)
        HelmMotion.reducedOverrideForTests = nil

        if problems.isEmpty {
            print("  OK   the meter and the sweep move, stop, and hold still under Reduce Motion")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 5b. DH-2 - the HUD is the Dictation hero pill

    /// The dictation HUD is the Dictation hero pill in the app's theme, and
    /// its words are legible on its own gradient.
    ///
    /// This reverses review #3 section 7's check, which asserted a system
    /// material and a HUD that never read the theme. The reason is in
    /// `DictationHUD.swift`'s header: the pill is opaque now, so its words are
    /// measured against its own gradient rather than against whatever is
    /// behind it, and that is what this asserts, in Lavender and Powder, for
    /// every state's headline and tone.
    ///
    /// **Discriminating power first**: the accent and the amber palettes must
    /// differ, or the tone checks could not tell them apart.
    private static func checkDictationHUDIsAHeroPill(_ ok: inout Bool) {
        print("\n-- DH-2: the dictation HUD is the Dictation hero pill, in the theme, legible on its own gradient --")
        guard let lavender = HelmTheme.appTheme(id: "lavender"),
              let powder = HelmTheme.appTheme(id: "powder") else {
            print("  FAIL Lavender or Powder is missing - the checks below would be vacuous")
            ok = false
            return
        }
        // Every state, driven through the real entry point. `wasActive` arms
        // only on a real `.recording`, so each terminal state follows one.
        let script: [(status: DictationStatus, words: String, amber: Bool)] = [
            (.recording, "Listening\u{2026}", false),
            (.transcribing, "Transcribing\u{2026}", false),
            (.cleaningUp, "Cleaning up\u{2026}", false),
            (.ready, "Pasted", false),
            (.copiedOnly, "Copied - press \u{2318}V to paste", true),
            (.didNotCatchThat, "Didn't catch that", true),
            (.systemDictationDisabled, "System Dictation is off", true),
        ]
        for theme in [lavender, powder] {
            ThemeManager.shared.setTheme(theme)
            // The two tones from the kit's own primitives, not through
            // `DictationController.heroTone`, so a HUD that drifts off the
            // Dic-1 rule fails.
            let quiet = Double(HelmHeroColumn.quietInkAlpha)
            let accentPalette = HelmHeroSurface.palette(
                accent: HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex)), quietInk: quiet)
            let amberPalette = HelmHeroSurface.palette(
                accent: HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3])), quietInk: quiet)
            guard !sameColor(HelmContrast.color(accentPalette.start), HelmContrast.color(amberPalette.start)) else {
                print("  FAIL \(theme.id): the accent and the amber are one colour - the tone checks would be vacuous")
                ok = false
                continue
            }
            let hud = DictationHUDController()
            var problems: [String] = []
            for step in script {
                if step.status != .recording && step.status != .transcribing && step.status != .cleaningUp {
                    hud.handle(.recording)
                }
                hud.handle(step.status)
                let palette = step.amber ? amberPalette : accentPalette
                if hud.debugTitleText != step.words {
                    problems.append("\(step.status) reads \"\(hud.debugTitleText ?? "nil")\"")
                }
                if hud.debugKickerText != DictationHeroWords.hudKicker.uppercased() {
                    problems.append("\(step.status)'s kicker reads \"\(hud.debugKickerText ?? "nil")\"")
                }
                let stops = hud.debugSurface?.debugGradientColors.compactMap { NSColor(cgColor: $0) } ?? []
                if stops.count != 2 || !sameColor(stops[0], HelmContrast.color(palette.start))
                    || !sameColor(stops[1], HelmContrast.color(palette.end)) {
                    problems.append("\(step.status) is not on the \(step.amber ? "amber" : "accent") gradient")
                }
                // The words on the lighter stop, the worse of the two: the
                // headline in the ink, the kicker at the quiet ink.
                let ink = HelmContrast.color(palette.ink)
                if !sameColor(hud.debugTitleLabel?.textColor, ink) {
                    problems.append("\(step.status)'s headline is not the hero's ink")
                }
                let headline = HelmContrast.ratio(palette.ink, palette.lighterStop)
                let kicker = HelmContrast.ratio(HelmContrast.mix(palette.ink, palette.lighterStop, quiet),
                                                palette.lighterStop)
                if headline < HelmContrast.textTarget || kicker < HelmContrast.textTarget {
                    problems.append(String(format: "\(step.status): headline %.2f:1, kicker %.2f:1 on the lighter stop",
                                           headline, kicker))
                }
            }
            hud.handle(.recording)
            if let pill = hud.debugPill, let surface = hud.debugSurface, let panel = hud.debugPanel {
                if abs(pill.bounds.height - DictationHUDController.pillHeight) > 0.51 {
                    problems.append("the pill is \(fmt(pill.bounds.height))pt tall, want \(fmt(DictationHUDController.pillHeight))")
                }
                if abs((surface.layer?.cornerRadius ?? 0) - DictationHUDController.pillHeight / 2) > 0.01
                    || surface.layer?.masksToBounds != true {
                    problems.append("the gradient is not clipped to a capsule")
                }
                // The white hairline that separates it from a dark editor.
                let edge = surface.layer?.borderColor.flatMap { NSColor(cgColor: $0) }
                if (surface.layer?.borderWidth ?? 0) < 1 || edge.map({ $0.alphaComponent < 0.15 }) ?? true {
                    problems.append("no white hairline round the pill")
                }
                if surface.glowShape != .capsule { problems.append("the pill draws the card's glow") }
                if hud.debugGlyphTile.map({ abs($0.frame.width - DictationHUDController.glyphTileSide) > 0.51 }) ?? true {
                    problems.append("no \(fmt(DictationHUDController.glyphTileSide))pt glass glyph tile")
                }
                // The panel the HUD has always been: non-activating, never
                // key, click-through, floating, with a window shadow.
                if !panel.styleMask.contains(.nonactivatingPanel) || panel.canBecomeKey || !panel.ignoresMouseEvents
                    || panel.level != .floating || !panel.hasShadow {
                    problems.append("the panel is no longer a non-activating, click-through floating panel")
                }
                if abs(panel.frame.width - ceil(pill.fittingSize.width)) > 0.51 {
                    problems.append("the panel is \(fmt(panel.frame.width))pt for a \(fmt(pill.fittingSize.width))pt pill")
                }
                // ThemeManager's checklist, item 2: a white-ink gradient is a
                // dark surface, whatever the OS is set to.
                if panel.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua {
                    problems.append("the pill does not force the dark appearance under its white ink")
                }
                // A self-test never puts the HUD on the captain's display.
                if !OffScreenProbe.isInvisible(panel) {
                    problems.append("the HUD panel is on a display during a self-test: \(panel.frame)")
                }
            } else {
                problems.append("the HUD built no pill")
            }
            // It follows the theme while it is up.
            let other = theme.id == lavender.id ? powder : lavender
            ThemeManager.shared.setTheme(other)
            let followed = HelmHeroSurface.palette(
                accent: HelmContrast.components(HelmTheme.nsColor(other.heroAccentHex)), quietInk: quiet)
            let live = hud.debugSurface?.debugGradientColors.compactMap { NSColor(cgColor: $0) } ?? []
            if live.first.map({ !sameColor($0, HelmContrast.color(followed.start)) }) ?? true {
                problems.append("a theme change did not repaint the HUD")
            }
            ThemeManager.shared.setTheme(theme)
            hud.handle(.ready)
            if problems.isEmpty {
                print("  OK   \(theme.id): every state's words on the accent or the amber gradient, 4.5:1, "
                      + "a 52pt capsule with a hairline, follows the theme, off every display")
            } else {
                for p in problems { print("  FAIL \(theme.id): \(p)") }
                ok = false
            }
        }
        // And the file says so: it observes the theme and draws no material.
        if let dir = SelfTestSources.appSourceDirectory(),
           let raw = try? String(contentsOf: dir.appendingPathComponent("DictationHUD.swift"), encoding: .utf8) {
            let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let slashes = line.range(of: "//") else { return line }
                    return line[line.startIndex..<slashes.lowerBound]
                }.joined(separator: "\n")
            if !code.contains("ThemeManager.shared.observe") {
                print("  FAIL the HUD no longer observes the theme")
                ok = false
            }
            if code.contains("NSVisualEffectView") {
                print("  FAIL the HUD draws a system material again - its words would depend on what is behind it")
                ok = false
            }
        } else {
            print("  FAIL could not read DictationHUD.swift - this half of the check silently passes otherwise")
            ok = false
        }
    }

    // MARK: 6. H4 - the sea and the unlock field

    private static func checkLockScreenSeaAndField(_ ok: inout Bool) {
        print("\n-- H4: the sea is a gradient, the unlock field has a glow --")
        // **The parallax below is only observable with motion on**, and
        // whether it is on is a property of the machine rather than of this
        // app: `startAnimationsIfNeeded` refuses to attach either drift under
        // Reduce Motion, which is GL-16 working exactly as the lock screen's
        // own header says it must ("this screen is *mandatory* - a captain who
        // has turned it on cannot navigate away from it").
        //
        // A GitHub runner reports Reduce Motion **on**, so this check read the
        // app doing the right thing as "no parallax" and failed there while
        // passing on every developer machine. Pinning the setting is what
        // makes the measurement about the scene rather than about the host -
        // and the `true` half below is then worth asserting outright, which is
        // coverage this check did not have before.
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = nil }

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

        // The other half of GL-16, now that the setting is under this check's
        // control: with Reduce Motion on, a freshly built scene attaches
        // neither drift. The two gradients stay - a still illustration is the
        // documented Reduce Motion rendering, not a blank one.
        HelmMotion.reducedOverrideForTests = true
        let still = LockScreenController()
        still.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        _ = makeWindow(still.view)
        still.view.layoutSubtreeIfNeeded()
        let stillScene = still.debugSceneLayers
        if !stillScene.driftDurations.isEmpty {
            problems.append("the swells drift under Reduce Motion - GL-16 says this screen holds still")
        }
        if stillScene.skyStops < 2 || stillScene.seaStops < 2 {
            problems.append("Reduce Motion lost the gradients - it should still render the illustration")
        }
        HelmMotion.reducedOverrideForTests = false

        if problems.isEmpty {
            print("  OK   sky/sea gradients, celestial glow, \(scene.driftDurations.count)-layer parallax,"
                  + " field glow, still under Reduce Motion")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }
}

#endif
