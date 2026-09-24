// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-topbar-icon-tiles`: the top bar's quick-access shortcuts draw
// a coloured tile at rest instead of a monochrome glyph - the treatment #458
// gave Settings' nav rows, asked for here by the captain.
//
// `fm/grandline-topbar-icon-tiles-round2` then fixed two things the captain
// found in the shipped row, and both left a case here: three controls that
// had no tile at all (Recents, the theme toggle, the bell), and three tiles
// the captain could not tell apart. The second turned out not to be a
// colour-choice problem - see `checkEveryPaletteKeepsTheHuesApart`.
//
// Six things are worth asserting, and they are different in kind:
//
//   - **The colour is the destination's own.** Not "a colour appeared" but
//     "this button's fill is the one `HelmContrast.tintedSurface` produces
//     over *this destination's* `domainHue`". A check that only asked whether
//     the row is colourful would pass with every tile the same hue, which is
//     precisely the defect the fix exists to end.
//   - **It is legible in all 26 palettes.** The glyph sits on a wash of its
//     own hue, which is the exact recipe `HelmContrast` exists to police.
//     A single-theme check proves nothing about the other 25.
//   - **No two of those colours collapse into one, in any palette.** This is
//     round 2's real finding and the reason that case sweeps a matrix rather
//     than naming three destinations: the hues were always distinct, and the
//     *resolution* is what collapsed them.
//   - **The row's footprint did not move.** This is the sizing-consistency
//     guard. The bar's height and the 34pt square are load-bearing, and the
//     honest way to prove a colour change did not disturb them is to assert
//     the numbers as literals rather than to re-derive them from the code
//     under test.
//   - **The bar's own controls wear their own tiles.** Recents, the theme
//     toggle and the bell are not destinations, but round 2 gave all three
//     real tiles on the captain's instruction - slate for the two that are
//     app chrome, amber for the one that is asking for something. Asserting
//     *which* tile, not merely that one appeared.
//   - **The one button that is still exempt, on purpose.** The overflow
//     control drawing its generic ellipsis opens a menu rather than a
//     surface, so it has no identity to paint; it takes a real tile in its
//     other identity, and one case asserts both halves.
//
// Run with:
//   swift build && FM_RUN_BAR_ICON_TILE_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// **Pure logic, no window.** Every case reads layer colours and frames off a
// `DaylightBarController` laid out by hand, and drives hover through the
// button's own `debugSetHovering` rather than a real mouse - so this guards
// the *blocking* CI lane and is deliberately not in `NEEDS_SESSION`.
// `BarNavigationModernizationSelfTest` is the window-backed sibling and stays
// where it is.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightBarIconTileSelfTest {

    /// The bar's own pre-fix geometry, written out rather than read back from
    /// the code under test. A guard that derives its expectation from
    /// `DaylightBarIconButton.side` cannot fail when that constant moves,
    /// which is the one thing it is here to catch.
    private enum Baseline {
        static let iconSide: CGFloat = 34
        static let barHeight: CGFloat = 50
        static let topMargin: CGFloat = 14
        static let cornerRadius: CGFloat = 9
        /// `HelmMetrics.s2`, the gap between two shortcuts in the row.
        static let rowSpacing: CGFloat = 8
    }

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)

        let cases: [(String, () -> String?)] = [
            ("every shortcut wears its own destination's tile", checkEveryShortcutWearsItsOwnTile),
            ("the tile is legible in all 26 palettes, in all three states", checkEveryPaletteTilesLegibly),
            ("hover and active deepen the tile the captain is looking at", checkStatesDeepenTheSameTile),
            ("the terminal shortcut wears Settings' own Terminal tint", checkTerminalShortcutMatchesSettings),
            ("the bar's own controls wear their own tiles", checkTheBarsOwnControlsAreTiled),
            ("no two domain hues collapse onto one tile in any palette", checkEveryPaletteKeepsTheHuesApart),
            ("Docs, Hosts and Schedules are tellable apart everywhere", checkTheCaptainsThreeAreTellableApart),
            ("the single-overflow shortcut is tiled, the ellipsis is not", checkOverflowButtonFollowsItsIdentity),
            ("the row's height and footprint are unchanged", checkRowFootprintIsUnchanged),
        ]

        var allOK = true
        for (name, check) in cases {
            if let failure = check() {
                print("FAIL \(name): \(failure)")
                allOK = false
            } else {
                print("OK   \(name)")
            }
        }
        print(allOK ? "DaylightBarIconTileSelfTest: all checks passed"
                    : "DaylightBarIconTileSelfTest: FAILED")
        return allOK
    }

    // MARK: The colour is the destination's own

    private static func checkEveryShortcutWearsItsOwnTile() -> String? {
        // One palette from each side of `tileHex`'s own split, so a fix that
        // only ever resolved one of the two branches fails here rather than
        // in whichever theme happened to be ambient.
        for id in ["daylight", "dusk", "helm-dark", "catppuccin-latte"] {
            guard let theme = theme(id) else {
                return "no `\(id)` theme - has the palette been renamed?"
            }
            let bar = makeLaidOutBar(theme: theme)

            let buttons = bar.debugDestinationButtons()
            guard buttons.count >= 2 else {
                return "the bar drew \(buttons.count) shortcuts - this case needs at least two to compare"
            }

            var fills: [String: NSColor] = [:]
            for button in buttons {
                let hex = DaylightBarIconButton.tileHex(for: button.destination, in: theme)
                let expected = HelmContrast.tintedSurface(tintHex: hex,
                                                          theme: theme,
                                                          target: HelmContrast.nonTextTarget,
                                                          washSteps: HelmContrast.tileWashSteps)
                guard let fill = layerFill(button) else {
                    return "\(theme.id)/\(button.destination.title): the tile has no fill at all"
                }
                guard sameColor(fill, expected.fill) else {
                    return "\(theme.id)/\(button.destination.title): the tile is \(describe(fill)), expected a wash of "
                        + "its own \(button.destination.domainHue.rawValue) hue \(describe(expected.fill)) - "
                        + "a shortcut must carry *its* colour, not a colour"
                }
                guard let glyph = button.debugGlyphColor, sameColor(glyph, expected.foreground) else {
                    return "\(theme.id)/\(button.destination.title): the glyph is "
                        + "\(button.debugGlyphColor.map(describe) ?? "nil"), expected the contrast-corrected "
                        + "\(describe(expected.foreground)) `tintedSurface` pairs with that fill"
                }
                fills[button.destination.rawValue] = fill
            }

            // Discriminating power, asserted rather than assumed. The default
            // row pins six destinations across four domain hues, so a
            // rendering that painted every tile one colour - the pre-fix
            // chrome square very much included - fails here even if the
            // per-button comparison above were somehow satisfied.
            var distinct: [NSColor] = []
            for fill in fills.values where !distinct.contains(where: { sameColor($0, fill) }) {
                distinct.append(fill)
            }
            guard distinct.count >= 3 else {
                return "\(theme.id): the row's \(buttons.count) shortcuts render only \(distinct.count) distinct "
                    + "tile colours - the point of the fix is that the row is scannable"
            }

            // And the tile is not the chrome square it replaced.
            let chrome = theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.inset)
                : HelmTheme.nsColor(theme.chromeBackgroundHex)
            for (id, fill) in fills where sameColor(fill, chrome) {
                return "\(theme.id)/\(id): the tile is still the plain chrome surface \(describe(chrome))"
            }
        }
        return nil
    }

    // MARK: Legibility across every palette

    private static func checkEveryPaletteTilesLegibly() -> String? {
        // The floor `IconTileView` holds itself to: a glyph is a non-text UI
        // component, so 3:1. The slack is `tintedSurface`'s own - it lands
        // within one ladder step of the true crossing and documents that.
        let floor = HelmContrast.nonTextTarget - 0.02
        let ladders: [(String, [CGFloat])] = [
            ("rest", HelmContrast.tileWashSteps),
            ("hover", DaylightBarIconButton.hoverTileWashSteps),
            ("active", DaylightBarIconButton.activeTileWashSteps),
        ]
        // Every §2.2 hue, plus every tint a destination borrows instead of its
        // hue. The overrides are not reachable from `HelmDomainHue.allCases`
        // and are exactly the risky ones: `.neutral` resolves to
        // `chromeInkHex`, so its wash lands near full ink rather than near the
        // surface, which is the pairing AGENTS.md's colour rules warn about.
        let overrides = RailDestination.allCases
            .compactMap { DaylightBarIconButton.tileTintOverride(for: $0) }
        var sources: [(String, (HelmTheme) -> String)] = HelmDomainHue.allCases.map { hue in
            (hue.rawValue, { DaylightBarIconButton.tileHex(for: hue, in: $0) })
        }
        sources += overrides.map { tint in ("override:\(tint)", { tint.hex(in: $0) }) }

        var measured = 0
        for theme in HelmTheme.allThemes {
            for (name, hexFor) in sources {
                let hex = hexFor(theme)
                for (state, steps) in ladders {
                    let resolved = HelmContrast.tintedSurface(tintHex: hex,
                                                              theme: theme,
                                                              target: HelmContrast.nonTextTarget,
                                                              washSteps: steps)
                    let ratio = HelmContrast.ratio(HelmContrast.components(resolved.foreground),
                                                   HelmContrast.components(resolved.fill))
                    guard ratio >= floor else {
                        return String(format: "%@/%@/%@: the glyph measures %.4f against its own tile, below the %.2f "
                                      + "non-text floor", theme.id, name, state, ratio, HelmContrast.nonTextTarget)
                    }
                    measured += 1
                }
            }
        }
        // The sweep is only worth its runtime if it really covered the whole
        // matrix - a `allThemes` that silently shrank would pass vacuously.
        let expected = HelmTheme.allThemes.count * sources.count * ladders.count
        guard measured == expected, HelmTheme.allThemes.count >= 26,
              sources.count == HelmDomainHue.allCases.count + overrides.count, !overrides.isEmpty else {
            return "swept \(measured) of \(expected) combinations over \(HelmTheme.allThemes.count) palettes and "
                + "\(sources.count) tile hues (\(overrides.count) of them borrowed) - the matrix shrank, so this "
                + "case stopped proving what it claims"
        }
        return nil
    }

    // MARK: The one borrowed tint

    /// `fm/grandline-topbar-terminal-icon-color`: the captain asked for the
    /// bar's terminal shortcut and Settings' own Terminal row to be the same
    /// colour, so this asserts they are **one value**, not two that happen to
    /// agree today.
    ///
    /// Three claims, because they fail for different reasons. The override is
    /// Settings' own `tint` property (an edit to either side fails here rather
    /// than drifting silently); it resolves unbranched across all 26 palettes,
    /// which is the half that `HelmDomainHue.slate` would have got wrong on
    /// the Daylight family alone; and the painted tile really is that colour,
    /// because a resolution nothing renders is not a fix.
    private static func checkTerminalShortcutMatchesSettings() -> String? {
        guard DaylightBarIconButton.tileTintOverride(for: .console)
                == SettingsController.Category.terminal.tint else {
            return "the Console shortcut's tint override is "
                + "\(DaylightBarIconButton.tileTintOverride(for: .console).map { "\($0)" } ?? "nil"), and Settings' "
                + "Terminal row draws \(SettingsController.Category.terminal.tint) - the two are supposed to be "
                + "one value"
        }
        // Discriminating power first: teal is what the override replaces, so a
        // fixture in which the two already agreed would prove nothing.
        guard RailDestination.console.domainHue == .teal,
              SettingsController.Category.terminal.tint != HelmDomainHue.teal.fallbackTint else {
            return "Console's domain hue is \(RailDestination.console.domainHue) and Settings' Terminal tint is "
                + "\(SettingsController.Category.terminal.tint) - they no longer differ, so this case can no "
                + "longer fail"
        }

        for theme in HelmTheme.allThemes {
            let expected = SettingsController.Category.terminal.tint.hex(in: theme)
            let resolved = DaylightBarIconButton.tileHex(for: .console, in: theme)
            guard resolved.caseInsensitiveCompare(expected) == .orderedSame else {
                return "\(theme.id): the terminal shortcut resolves #\(resolved) where Settings' Terminal row "
                    + "resolves #\(expected) - the override must not take `tileHex`'s Daylight split"
            }
            // Every other shortcut still takes its own domain hue: an override
            // that leaked would read here as the whole row going slate.
            guard DaylightBarIconButton.tileHex(for: .hosts, in: theme)
                    == DaylightBarIconButton.tileHex(for: RailDestination.hosts.domainHue, in: theme) else {
                return "\(theme.id): Hosts no longer takes its own domain hue - the override is not Console-only"
            }
        }

        // And it is what gets painted, on both sides of the split.
        for id in ["daylight", "dusk"] {
            guard let theme = theme(id) else { return "no `\(id)` theme - has the palette been renamed?" }
            let bar = makeLaidOutBar(theme: theme)
            guard let button = bar.debugDestinationButtons().first(where: { $0.destination == .console }) else {
                return "the fixture row no longer pins Console, so nothing here is measured"
            }
            let expected = HelmContrast.tintedSurface(
                tintHex: SettingsController.Category.terminal.tint.hex(in: theme),
                theme: theme,
                target: HelmContrast.nonTextTarget,
                washSteps: HelmContrast.tileWashSteps)
            guard let fill = layerFill(button), sameColor(fill, expected.fill) else {
                return "\(theme.id): the terminal shortcut paints \(layerFill(button).map(describe) ?? "nil"), "
                    + "expected Settings' own Terminal wash \(describe(expected.fill))"
            }
        }
        return nil
    }

    // MARK: State

    private static func checkStatesDeepenTheSameTile() -> String? {
        guard let theme = theme("dusk") else {
            return "no `dusk` theme - has the palette been renamed?"
        }
        let bar = makeLaidOutBar(theme: theme)
        guard let button = bar.debugDestinationButtons().first else { return "no quick-access shortcuts on the bar" }

        guard let resting = layerFill(button), let restingBorder = layerBorder(button) else {
            return "the resting tile has no fill or border"
        }

        button.debugSetHovering(true)
        guard let hovered = layerFill(button), let hoveredBorder = layerBorder(button) else {
            return "the hovered tile has no fill or border"
        }
        button.debugSetHovering(false)

        bar.setActiveDestination(button.destination)
        guard let active = layerFill(button), let activeBorder = layerBorder(button) else {
            return "the active tile has no fill or border"
        }

        // Three states, three renderings. Before this fix the fill was the
        // chrome square in two of the three and the state lived on the glyph
        // alone, so this is the case that fails if the ladders are ever
        // collapsed back into one.
        guard !sameColor(resting, hovered) else {
            return "the tile is the same colour hovered as at rest (\(describe(resting))) - pointing at a shortcut "
                + "has to do something"
        }
        guard !sameColor(hovered, active), !sameColor(resting, active) else {
            return "the active tile (\(describe(active))) is not distinguishable from rest (\(describe(resting))) "
                + "or hover (\(describe(hovered)))"
        }
        // The border carries the same ladder, and its alphas are strictly
        // ordered - a ring that got *quieter* while the page it opens is the
        // one showing would be backwards.
        guard restingBorder.alphaComponent < hoveredBorder.alphaComponent,
              hoveredBorder.alphaComponent < activeBorder.alphaComponent else {
            return String(format: "the tile's ring reads %.2f at rest, %.2f hovered, %.2f active - "
                          + "it must strengthen, not weaken",
                          restingBorder.alphaComponent, hoveredBorder.alphaComponent, activeBorder.alphaComponent)
        }

        // Active survives the pointer leaving - which is what makes it "the
        // page you are on" rather than a second hover.
        button.debugSetHovering(true)
        button.debugSetHovering(false)
        guard let stillActive = layerFill(button), sameColor(stillActive, active) else {
            return "the active tile faded once the pointer left it"
        }
        for other in bar.debugDestinationButtons() where other !== button {
            guard other.isActiveDestination == false else {
                return "\(other.destination.title) is lit too - only the destination actually showing may be"
            }
        }
        return nil
    }

    // MARK: The bar's own controls

    /// `fm/grandline-topbar-icon-tiles-round2`: Recents, the theme toggle and
    /// the notification bell carry real tiles now.
    ///
    /// The captain reported all three as "no coloured tile at all" after #460,
    /// and they were: #460 tiled the destination shortcuts and left every
    /// other square on the plain chrome rendering. Each of the three is
    /// asserted to paint the wash of its own declared hue - `chromeTileHue`
    /// for the two that are app chrome, `bellTileHue` for the one that is
    /// asking for something - rather than merely "not the chrome square",
    /// because "a colour appeared" is the assertion that would pass with all
    /// three the same and with any of them accidentally wearing a
    /// destination's identity.
    ///
    /// The bell is checked hardest of the three, and that is deliberate: it is
    /// a `NotificationBellButton` rather than a `DaylightBarIconButton`, so it
    /// shares none of the tile code and is the one control that can silently
    /// fall back out of the treatment. Its badge ring has to follow the tile
    /// too - the ring exists to separate a red disc from what is under it, so
    /// a ring left painting the old chrome surface reads as a hairline around
    /// the badge.
    private static func checkTheBarsOwnControlsAreTiled() -> String? {
        // Both sides of the palette families, and the captain's own theme.
        for id in ["daylight", "dusk", "ayu-dark", "catppuccin-latte"] {
            guard let theme = theme(id) else {
                return "no `\(id)` theme - has the palette been renamed?"
            }
            let bar = makeLaidOutBar(theme: theme)
            let chrome = theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.inset)
                : HelmTheme.nsColor(theme.chromeBackgroundHex)

            let chromeWash = wash(DaylightBarIconButton.chromeTileHue, theme)
            let bellWash = wash(DaylightBarIconButton.bellTileHue, theme)

            // Discriminating power first: if the tile a control is supposed to
            // wear were already the chrome square, every assertion below would
            // pass vacuously on a control nobody had fixed.
            guard !sameColor(chromeWash.fill, chrome), !sameColor(bellWash.fill, chrome) else {
                return "\(theme.id): the chrome-control wash \(describe(chromeWash.fill)) or the bell's "
                    + "\(describe(bellWash.fill)) is indistinguishable from the plain square "
                    + "\(describe(chrome)) - this case could not fail"
            }

            for button in bar.debugIconSquares() where button is RecentDestinationsButton
                                                    || button is DaylightThemeToggleButton {
                let name = button.accessibilityLabel() ?? "icon"
                guard let fill = layerFill(button), sameColor(fill, chromeWash.fill) else {
                    return "\(theme.id)/\(name) paints \(layerFill(button).map(describe) ?? "nil"), expected the "
                        + "\(DaylightBarIconButton.chromeTileHue.rawValue) wash \(describe(chromeWash.fill)) every "
                        + "bar-owned control wears"
                }
                guard let glyph = button.debugGlyphColor, sameColor(glyph, chromeWash.foreground) else {
                    return "\(theme.id)/\(name)'s glyph is \(button.debugGlyphColor.map(describe) ?? "nil"), "
                        + "expected the contrast-corrected \(describe(chromeWash.foreground)) that wash pairs with"
                }
            }
            // Both really were found - a `where` clause that matched nothing
            // would leave the loop above asserting nothing at all.
            let owned = bar.debugIconSquares().filter {
                $0 is RecentDestinationsButton || $0 is DaylightThemeToggleButton
            }
            guard owned.count == 2 else {
                return "\(theme.id): found \(owned.count) bar-owned squares, expected Recents and the theme toggle"
            }

            let bell = bar.notificationCenter.debugBell
            guard let bellFill = bell.debugTileFill, sameColor(bellFill, bellWash.fill) else {
                return "\(theme.id): the bell paints \(bell.debugTileFill.map(describe) ?? "nil"), expected the "
                    + "\(DaylightBarIconButton.bellTileHue.rawValue) wash \(describe(bellWash.fill))"
            }
            guard let bellGlyph = bell.debugGlyphColor, sameColor(bellGlyph, bellWash.foreground) else {
                return "\(theme.id): the bell's glyph is \(bell.debugGlyphColor.map(describe) ?? "nil"), expected "
                    + "\(describe(bellWash.foreground))"
            }
            guard let ring = bell.debugBadgeRingColor, sameColor(ring, bellWash.fill) else {
                return "\(theme.id): the badge's ring is \(bell.debugBadgeRingColor.map(describe) ?? "nil") - it has "
                    + "to be the tile it sits on \(describe(bellWash.fill)), or a red disc merges into the glyph"
            }
            guard let bellBorder = layerBorderColor(bell.debugTileBorder) else {
                return "\(theme.id): the bell's tile has no ring at all"
            }
            guard abs(bellBorder.alphaComponent - DaylightBarIconButton.restingTileBorderAlpha) < 0.01 else {
                return String(format: "%@: the bell's ring reads %.2f where every other resting tile reads %.2f",
                              theme.id, bellBorder.alphaComponent,
                              DaylightBarIconButton.restingTileBorderAlpha)
            }

            // And the three do not all wear one colour - "they got tiles" is
            // not the same claim as "the tiles mean something".
            guard !sameColor(chromeWash.fill, bellWash.fill) else {
                return "\(theme.id): the bell wears the same tile as Recents and the theme toggle "
                    + "\(describe(bellWash.fill)) - the bell is the one control that is asking for something"
            }
        }
        return nil
    }

    // MARK: The captain's complaint

    /// The separation floor two washed tiles must clear to be *seen* as two
    /// colours, in the weighted-RGB distance below.
    ///
    /// 0.045 is picked off the measurement rather than out of the air, and it
    /// has to clear both ways. The resolution this branch replaced put the
    /// closest pair at **0.0000** on eight of the 26 palettes and under 0.035
    /// on fourteen; the one it installed puts the worst pair over the whole
    /// matrix at 0.0568. So the floor sits above every failure and below the
    /// tightest pass, with about 26% of headroom on the passing side.
    private static let separationFloor: CGFloat = 0.045

    /// `fm/grandline-topbar-icon-tiles-round2`'s actual bug, generalised.
    ///
    /// The captain reported three tiles in one warm tan; the cause was not
    /// three unlucky hue choices but the *resolution*. Routing §2.2's seven
    /// identity hues through `HelmDomainHue.fallbackTint` hands them to seven
    /// `HelmTint` slots, and a palette is free to spend one colour on two
    /// slots - Ayu publishes a single amber and uses it as both `accent` and
    /// its ANSI yellow, so teal (Hosts) and amber (Poneglyph, Sticky Board)
    /// came out as *the same tile*.
    ///
    /// So this asserts the property rather than the three symptoms: over every
    /// palette, no two of the tile colours this bar can draw land within
    /// `separationFloor` of each other. Console's borrowed `HelmTint.neutral`
    /// is swept alongside the seven, because a hue colliding with *it* is the
    /// same defect.
    ///
    /// **It is proven able to fail without reverting anything**: the same
    /// sweep is run a second time against the replaced resolution, and this
    /// case fails if that one does *not* produce a collision. A floor that
    /// nothing can breach is the one failure mode a sweep like this has.
    private static func checkEveryPaletteKeepsTheHuesApart() -> String? {
        var sources: [(String, (HelmTheme) -> String)] = HelmDomainHue.allCases.map { hue in
            (hue.rawValue, { DaylightBarIconButton.tileHex(for: hue, in: $0) })
        }
        for tint in RailDestination.allCases.compactMap(DaylightBarIconButton.tileTintOverride)
        where !sources.contains(where: { $0.0 == "override:\(tint)" }) {
            sources.append(("override:\(tint)", { tint.hex(in: $0) }))
        }

        var measured = 0
        var worst = (distance: CGFloat.greatestFiniteMagnitude, where: "")
        for theme in HelmTheme.allThemes {
            for i in 0..<sources.count {
                for j in (i + 1)..<sources.count {
                    let a = washed(sources[i].1(theme), theme)
                    let b = washed(sources[j].1(theme), theme)
                    let d = separation(a, b)
                    measured += 1
                    if d < worst.distance {
                        worst = (d, "\(theme.id) \(sources[i].0)/\(sources[j].0)")
                    }
                    guard d >= separationFloor else {
                        return String(format: "%@: %@ and %@ both render %@ / %@ - a distance of %.4f, under the "
                                      + "%.3f floor. Two destinations in one colour is the whole complaint.",
                                      theme.id, sources[i].0, sources[j].0, describe(a), describe(b),
                                      d, separationFloor)
                    }
                }
            }
        }

        let expectedPairs = HelmTheme.allThemes.count * sources.count * (sources.count - 1) / 2
        guard measured == expectedPairs, HelmTheme.allThemes.count >= 26,
              sources.count > HelmDomainHue.allCases.count else {
            return "swept \(measured) of \(expectedPairs) pairs over \(HelmTheme.allThemes.count) palettes and "
                + "\(sources.count) tile sources - the matrix shrank, so this case stopped proving what it claims"
        }

        // The discriminating half. Re-run the sweep through the resolution
        // this branch replaced; if *that* no longer collides anywhere, the
        // floor has drifted high enough to be meaningless and this case is
        // no longer catching the bug it was written for.
        var collisions = 0
        for theme in HelmTheme.allThemes {
            let hues = HelmDomainHue.allCases
            for i in 0..<hues.count {
                for j in (i + 1)..<hues.count {
                    let priorHex: (HelmDomainHue) -> String = {
                        theme.isDaylight ? $0.identityHex(in: theme) : $0.fallbackTint.hex(in: theme)
                    }
                    let d = separation(washed(priorHex(hues[i]), theme), washed(priorHex(hues[j]), theme))
                    if d < separationFloor { collisions += 1 }
                }
            }
        }
        guard collisions > 0 else {
            return String(format: "the replaced `fallbackTint` resolution produces no collision at the %.3f floor "
                          + "any more - this case can no longer fail, so it is not guarding the fix "
                          + "(worst live pair: %.4f at %@)", separationFloor, worst.distance, worst.where)
        }
        return nil
    }

    /// The captain's own three, by name.
    ///
    /// `checkEveryPaletteKeepsTheHuesApart` already covers these as part of
    /// the matrix, and this is still worth its own case: it is the report that
    /// was filed, it fails with the reported wording rather than with a pair
    /// of hue names, and it pins down that the fix for these three was to keep
    /// each destination's **own** `domainHue` (Docs blue, Hosts teal,
    /// Schedules violet - §2.2's table, unchanged) rather than to invent three
    /// new colours for the bar.
    private static func checkTheCaptainsThreeAreTellableApart() -> String? {
        let three: [RailDestination] = [.docs, .hosts, .schedules]
        // The hues really are the §2.2 ones, so "they differ" is a claim about
        // the app's own identity table rather than about a bar-local invention.
        let expected: [RailDestination: HelmDomainHue] = [.docs: .blue, .hosts: .teal, .schedules: .violet]
        for destination in three {
            guard destination.domainHue == expected[destination] else {
                return "\(destination.title)'s domain hue is \(destination.domainHue), expected "
                    + "\(expected[destination].map { "\($0)" } ?? "?") - the bar draws §2.2's table, so a change "
                    + "there is a change here"
            }
            guard DaylightBarIconButton.tileTintOverride(for: destination) == nil else {
                return "\(destination.title) has a tile override - these three are supposed to take their own hue"
            }
        }

        for theme in HelmTheme.allThemes {
            for i in 0..<three.count {
                for j in (i + 1)..<three.count {
                    let a = washed(DaylightBarIconButton.tileHex(for: three[i], in: theme), theme)
                    let b = washed(DaylightBarIconButton.tileHex(for: three[j], in: theme), theme)
                    let d = separation(a, b)
                    guard d >= separationFloor else {
                        return String(format: "%@: %@ renders %@ and %@ renders %@ - %.4f apart, under the %.3f "
                                      + "floor. The captain reported exactly this: \"hard to tell apart at a "
                                      + "glance\".", theme.id, three[i].title, describe(a), three[j].title,
                                      describe(b), d, separationFloor)
                    }
                }
            }
        }
        return nil
    }

    private static func checkOverflowButtonFollowsItsIdentity() -> String? {
        guard let theme = theme("dusk") else {
            return "no `dusk` theme - has the palette been renamed?"
        }

        // Seven pinned, six visible: exactly one destination overflows, so
        // #452's "draw the real destination's icon" branch is the live one and
        // the button is a shortcut in everything but name.
        let single = makeLaidOutBar(theme: theme)
        guard let direct = single.debugQuickAccessOverflowClickTarget() else {
            return "seven pinned did not produce a single overflowing destination - the fixture no longer "
                + "exercises #452's branch"
        }
        let overflow = single.debugQuickAccessOverflowButton()
        let hex = DaylightBarIconButton.tileHex(for: direct, in: theme)
        let expected = HelmContrast.tintedSurface(tintHex: hex,
                                                  theme: theme,
                                                  target: HelmContrast.nonTextTarget,
                                                  washSteps: HelmContrast.tileWashSteps)
        guard let fill = layerFill(overflow), sameColor(fill, expected.fill) else {
            return "the single-overflow button draws \(direct.title)'s icon but not its tile "
                + "(\(layerFill(overflow).map(describe) ?? "nil") against \(describe(expected.fill)))"
        }

        // Eight pinned: two overflow, so the button is a menu opener drawing a
        // generic ellipsis. A tile there would be claiming an identity it does
        // not have.
        let menu = makeLaidOutBar(theme: theme, pinned: fixturePins + [.docs])
        guard menu.debugQuickAccessOverflowClickTarget() == nil else {
            return "eight pinned still resolved to a single direct destination - the fixture is wrong"
        }
        let chrome = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ellipsis = menu.debugQuickAccessOverflowButton()
        guard let menuFill = layerFill(ellipsis), sameColor(menuFill, chrome) else {
            return "the ellipsis overflow button is tiled (\(layerFill(ellipsis).map(describe) ?? "nil")) - "
                + "it opens a menu, not a destination"
        }
        return nil
    }

    // MARK: The sizing guard

    private static func checkRowFootprintIsUnchanged() -> String? {
        guard let theme = theme("dusk") else {
            return "no `dusk` theme - has the palette been renamed?"
        }
        let bar = makeLaidOutBar(theme: theme)

        guard abs(DaylightBarIconButton.side - Baseline.iconSide) < 0.01,
              abs(DaylightBarController.height - Baseline.barHeight) < 0.01,
              abs(DaylightBarController.topMargin - Baseline.topMargin) < 0.01 else {
            return "the bar's own constants moved: side \(DaylightBarIconButton.side) (was \(Baseline.iconSide)), "
                + "height \(DaylightBarController.height) (was \(Baseline.barHeight)), "
                + "top margin \(DaylightBarController.topMargin) (was \(Baseline.topMargin))"
        }

        // Every visible square, measured. A tile drawn *around* a button
        // rather than inside it is the failure this is written for, and it
        // would show up here as a square that grew.
        for button in bar.debugIconSquares() where !button.isHidden {
            let name = button.accessibilityLabel() ?? "icon"
            guard abs(button.frame.width - Baseline.iconSide) < 0.5,
                  abs(button.frame.height - Baseline.iconSide) < 0.5 else {
                return "\(name) measures \(button.frame.size), expected \(Baseline.iconSide) square"
            }
            let background = button.debugIconBackground
            guard abs(background.frame.width - Baseline.iconSide) < 0.5,
                  abs(background.frame.height - Baseline.iconSide) < 0.5 else {
                return "\(name)'s tile measures \(background.frame.size) inside a \(Baseline.iconSide)pt button - "
                    + "the tile is sized to fit the button, never the other way round"
            }
            guard abs((background.layer?.cornerRadius ?? -1) - Baseline.cornerRadius) < 0.01 else {
                return "\(name)'s tile radius is \(background.layer?.cornerRadius ?? -1), expected \(Baseline.cornerRadius)"
            }
        }

        // And the row as a whole, so a per-button check that passed while the
        // stack's own spacing or height drifted still fails.
        let row = bar.debugQuickAccessRow()
        let visible = bar.debugDestinationButtons().filter { !$0.isHidden }
        guard !visible.isEmpty else { return "no visible shortcuts at 1512pt - the fixture no longer lays the row out" }
        let expectedWidth = CGFloat(visible.count) * Baseline.iconSide
            + CGFloat(visible.count - 1) * Baseline.rowSpacing
        guard abs(row.frame.width - expectedWidth) < 0.5 else {
            return "the shortcut row measures \(row.frame.width)pt for \(visible.count) icons, expected "
                + "\(expectedWidth)pt (\(Baseline.iconSide)pt squares, \(Baseline.rowSpacing)pt apart)"
        }
        guard abs(row.frame.height - Baseline.iconSide) < 0.5 else {
            return "the shortcut row is \(row.frame.height)pt tall, expected \(Baseline.iconSide)pt - "
                + "a taller row is what would push the bar's own height"
        }
        guard abs(bar.view.frame.height - (Baseline.barHeight + Baseline.topMargin)) < 0.5 else {
            return "the bar is \(bar.view.frame.height)pt tall, expected \(Baseline.barHeight + Baseline.topMargin)pt"
        }
        return nil
    }

    // MARK: Fixtures

    /// The seven `QuickAccessConfiguration` shipped with, pinned explicitly.
    ///
    /// **Not `AppSettings.shared.quickAccess`**, which is the captain's real
    /// stored list: a suite that inherited it would measure a different row on
    /// every machine, and "the row shows at least three distinct hues" would
    /// be a claim about the captain's pins rather than about this fix. Seven
    /// against a `visibleLimit` of six also keeps exactly one destination in
    /// overflow, which is the state #452's direct-navigation branch needs.
    private static let fixturePins: [RailDestination] = [
        .stickyBoard, .codePreview, .shift, .strawHat, .poneglyph, .console, .hosts,
    ]

    /// **The theme is applied last, and the order is load-bearing.**
    /// `setQuickAccess` rebuilds the row and ends by re-applying
    /// `ThemeManager.shared.theme` to every square - so a fixture that themed
    /// the bar first had its choice silently replaced by whatever theme is
    /// ambient in the test process, and measured the overflow button's tile in
    /// a palette nobody asked for. That cost real time here; it reads as a
    /// colour bug in the button.
    private static func makeLaidOutBar(theme: HelmTheme,
                                       pinned: [RailDestination] = fixturePins) -> DaylightBarController {
        let bar = DaylightBarController()
        bar.loadView()
        // 1512, the captain's own screen width, deliberately above
        // `DaylightBarController.quickAccessCollapseWidth` - below it the row
        // collapses into the overflow button and every shortcut is
        // legitimately zero wide.
        bar.view.frame = NSRect(x: 0, y: 0, width: 1512,
                                height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.setQuickAccess(QuickAccessConfiguration(pinned: pinned))
        bar.applyThemeForTests(theme)
        bar.view.layoutSubtreeIfNeeded()
        return bar
    }

    private static func theme(_ id: String) -> HelmTheme? {
        HelmTheme.allThemes.first(where: { $0.id == id })
    }

    private static func layerFill(_ button: DaylightBarIconButton) -> NSColor? {
        button.debugIconBackground.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    /// The resting tile a hue produces in a theme - the one recipe every tile
    /// on this bar draws, so a case never rebuilds it by hand.
    private static func wash(_ hue: HelmDomainHue,
                             _ theme: HelmTheme) -> (fill: NSColor, foreground: NSColor) {
        let resolved = HelmContrast.tintedSurface(tintHex: DaylightBarIconButton.tileHex(for: hue, in: theme),
                                                  theme: theme,
                                                  target: HelmContrast.nonTextTarget,
                                                  washSteps: HelmContrast.tileWashSteps)
        return (resolved.fill, resolved.foreground)
    }

    private static func washed(_ hex: String, _ theme: HelmTheme) -> NSColor {
        HelmContrast.tintedSurface(tintHex: hex,
                                   theme: theme,
                                   target: HelmContrast.nonTextTarget,
                                   washSteps: HelmContrast.tileWashSteps).fill
    }

    /// How far apart two tiles look, weighted-RGB.
    ///
    /// Deliberately **not** `HelmContrast.ratio`, which compares relative
    /// luminance and would score two different hues of equal brightness as
    /// identical - which is the exact defect being measured, so a luminance
    /// check here would be blind to it by construction (AGENTS.md records this
    /// trap; this codebase has walked into it twice). The 2/4/3 weights are
    /// the standard Rec. 601-ish approximation to how much each channel moves
    /// perceived colour, which is enough to separate hue *families* - and hue
    /// families are what the complaint was about.
    ///
    /// Components come from `HelmContrast.components`, the same accessor
    /// `sameColor` uses, so the two agree about what a colour is.
    private static func separation(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        let dr = x.0 - y.0, dg = x.1 - y.1, db = x.2 - y.2
        return sqrt(2 * dr * dr + 4 * dg * dg + 3 * db * db)
    }

    private static func layerBorderColor(_ color: NSColor?) -> NSColor? { color }

    private static func layerBorder(_ button: DaylightBarIconButton) -> NSColor? {
        button.debugIconBackground.layer?.borderColor.flatMap { NSColor(cgColor: $0) }
    }

    private static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        // Component-wise, never `HelmContrast.ratio` - that compares relative
        // *luminance*, so two entirely different hues of similar brightness
        // pass it. AGENTS.md records this trap; this codebase has walked into
        // it twice.
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.02 && abs(x.1 - y.1) < 0.02 && abs(x.2 - y.2) < 0.02
    }

    private static func describe(_ color: NSColor) -> String {
        let c = HelmContrast.components(color)
        return String(format: "rgb(%.2f, %.2f, %.2f)", c.0, c.1, c.2)
    }
}

#endif
