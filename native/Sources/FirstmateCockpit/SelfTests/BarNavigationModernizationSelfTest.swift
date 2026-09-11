// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's B1-B5
// (`data/grandline-ui-modernization-audit/report.md` §3B, "The floating bar
// and navigation"), the sibling of `WindowChromeFusionSelfTest`'s A1/A2/A3.
//
// Five findings, and what is worth asserting differs sharply between them:
//
//   - **B1 (the bar's material)** is a *per-theme-family* claim. The finding
//     asks for a `.withinWindow` material on Daylight/Dusk and the opaque fill
//     kept on the twelve legacy palettes, so a check that only ever looks at
//     one theme proves nothing. `DaylightModuleSelfTest.checkBarAnatomy`
//     carries the half that holds on all fourteen (never `.behindWindow` -
//     AGENTS.md gotcha (8)); this carries the split.
//   - **B2 (one icon language)** is measured, not described: every icon square
//     the same size and radius, no raster artwork left on the bar, and a real
//     hover/active state that actually changes the glyph's colour. Plus the
//     bell's badge, which B2 asks to move *onto the symbol's corner* - which
//     means "inside the tile", and is the one assertion that would have caught
//     both of the earlier attempts at an attached badge.
//   - **B3 (the launch focus ring)** is the one with a real, reproducible bug
//     behind it, so it gets the most direct coverage: the window's initial
//     first responder must not be a bar control, and a view taking focus
//     without a key event must not paint a ring. Both halves are needed and
//     both are asserted separately - fixing only the first moves the stray
//     ring from a pill onto the canvas's first card.
//   - **B4 (the transition)** is asserted as a *decision* plus an *effect*.
//     The decision (direction, and whether it was skipped) is recorded,
//     because once the animation settles the end state is identical either
//     way and a frame read could not tell them apart. The effect is the entry
//     transform, which `animateDestinationEntrance` applies synchronously
//     inside a `CATransaction` and is therefore readable immediately.
//   - **B5 (the panels)** is asserted on the chrome that made the old
//     popovers look like system UI (arrow, opaque background, system radius),
//     on the anchoring, on dismissal, and on the lock gate having moved with
//     the mechanism rather than been dropped.
//
// Run with:
//   swift build && FM_RUN_BAR_NAV_MODERNIZATION_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// Window-backed: the focus ring, the panel anchoring and the navigation
// transition are all questions about a real window. In `run-all-tests.sh`'s
// `NEEDS_SESSION` list for that reason.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum BarNavigationModernizationSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)

        // A suite that changes the active theme MUST put it back - `setTheme`
        // persists to the real `FirstmateCockpit` UserDefaults domain that
        // every other suite in this run reads as its ambient theme.
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` is the guard.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        let cases: [(String, () -> String?)] = [
            ("B1 the bar's material is per-theme-family", test_b1BarMaterialPerThemeFamily),
            ("B1 the material cannot cost the bar its legibility", test_b1MaterialCannotBreakContrast),
            ("B2 the icon row is one language", test_b2IconRowIsOneLanguage),
            ("B2 a shortcut lights in its own hue on hover and while active", test_b2ShortcutHoverAndActiveState),
            ("B2 the bell's badge sits on the glyph, inside the tile", test_b2BellBadgeSitsOnTheGlyph),
            ("B3 the window's initial focus is the page, not the bar", test_b3InitialFirstResponderIsThePage),
            ("B3 a ring is painted only for focus the captain moved", test_b3FocusRingOnlyForKeyboardFocus),
            ("B4 a navigation animates, and repeating it does not", test_b4TransitionSkippedWhenAlreadyShowing),
            ("B4 Reduce Motion gets the end state instantly", test_b4ReduceMotionIsInstant),
            ("B5 the bar's dropdowns are borderless themed panels", test_b5PanelsAreBorderlessAndThemed),
            ("B5 a panel anchors under its control and dismisses", test_b5PanelAnchorsAndDismisses),
            ("B5 every panel is registered with the lock gate", test_b5PanelsAreLockRegistered),
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
        print(allOK ? "BarNavigationModernizationSelfTest: all checks passed"
                    : "BarNavigationModernizationSelfTest: FAILED")
        return allOK
    }

    // MARK: B1 - the material

    private static func test_b1BarMaterialPerThemeFamily() -> String? {
        let bar = DaylightBarController()
        bar.loadView()
        bar.view.frame = NSRect(x: 0, y: 0, width: 1200,
                                height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()

        // Every one of the fourteen, so "never `.behindWindow`" is a claim
        // about the app rather than about whichever two themes got sampled.
        for theme in HelmTheme.allThemes {
            bar.applyThemeForTests(theme)
            bar.view.layoutSubtreeIfNeeded()
            let geometry = bar.geometryForTests

            if geometry.visualEffectBlendingModes.contains(.behindWindow) {
                return "\(theme.id): a `.behindWindow` material - gotcha (8), which the audit's §6 keeps banned by name"
            }

            if theme.isDaylight {
                guard geometry.usesVisualEffect else {
                    return "\(theme.id) is a Daylight-family theme and shows no material - B1 asks for one here"
                }
                guard geometry.visualEffectBlendingModes.contains(.withinWindow) else {
                    return "\(theme.id): the material is not `.withinWindow` (modes: \(geometry.visualEffectBlendingModes))"
                }
                let expected = DaylightBarController.daylightFillAlpha
                guard abs(geometry.fillAlpha - expected) < 0.01 else {
                    return "\(theme.id): the bar fill is \(geometry.fillAlpha) alpha, expected \(expected) - "
                        + "at 1.0 the material below it is invisible and B1 buys nothing"
                }
            } else {
                guard !geometry.usesVisualEffect else {
                    return "\(theme.id) is a legacy palette and renders a material - B1 keeps those opaque "
                        + "(\"their surfaces are already near-black; translucency buys little\")"
                }
                guard abs(geometry.fillAlpha - 1) < 0.01 else {
                    return "\(theme.id): the bar fill is \(geometry.fillAlpha) alpha, expected the opaque 1.0 it always had"
                }
            }
        }
        return nil
    }

    /// B1's risk, bounded by measurement rather than by eye.
    ///
    /// `NSVisualEffectView` is composited by the window server, so
    /// `cacheDisplay` - this repo's screenshot substitute - captures a flat
    /// placeholder for it, and launching a real build to look is forbidden
    /// (the captain's own instance shares this bundle identity). So what the
    /// material *resolves to* cannot be observed from here.
    ///
    /// What can be bounded is the damage. The bar paints `chromeBackgroundHex`
    /// at `daylightFillAlpha` over the material, and the material composites
    /// against the page ground this controller's own root paints
    /// (`backgroundHex`). So the bar's effective surface is somewhere between
    /// those two colours, whatever the material does in between - and if the
    /// bar's own text clears the contrast floor against *both* ends, it clears
    /// it everywhere in between too.
    ///
    /// That is the honest form of "this change cannot make the bar
    /// illegible", and it is also what picks `daylightFillAlpha`: the number
    /// is whatever lets the material read while this still holds.
    private static func test_b1MaterialCannotBreakContrast() -> String? {
        for theme in HelmTheme.allThemes where theme.isDaylight {
            let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let page = HelmTheme.nsColor(theme.backgroundHex)
            let inks: [(String, NSColor)] = [
                ("chrome ink (the wordmark, a hovered pill)", HelmTheme.nsColor(theme.chromeInkHex)),
                ("muted ink (an idle pill, the search placeholder)", HelmTheme.mutedInk(theme)),
            ]
            for (name, ink) in inks {
                for (surfaceName, surface) in [("card", card), ("page ground", page)] {
                    let ratio = HelmContrast.ratio(ink, surface)
                    guard ratio >= HelmContrast.textTarget else {
                        return "\(theme.id): \(name) measures \(String(format: "%.2f", ratio)):1 on the \(surfaceName) "
                            + "- the material blends the bar between those two surfaces, so B1's translucency "
                            + "could land the bar's own text below the floor. Lower `daylightFillAlpha` or "
                            + "leave this family opaque."
                    }
                }
            }
        }
        return nil
    }

    // MARK: B2 - one icon language

    private static func test_b2IconRowIsOneLanguage() -> String? {
        let bar = makeLaidOutBar()

        // Every square the same size, including the bell - which is the whole
        // of B2's "the History and theme buttons should match the bell's
        // square", and was not true while the bell reserved an outboard badge
        // zone.
        let side = DaylightBarIconButton.side
        guard abs(NotificationBellButton.controlWidth - side) < 0.01 else {
            return "the bell's control is \(NotificationBellButton.controlWidth)pt wide against a \(side)pt icon square - "
                + "B2 asks for one shape, and an outboard badge zone is what made it two"
        }

        var squares: [(String, NSView)] = [("bell", bar.notificationCenter.bell)]
        for button in bar.debugIconSquares() {
            squares.append((button.accessibilityLabel() ?? "icon", button))
        }
        for (name, view) in squares {
            guard abs(view.frame.width - side) < 0.5, abs(view.frame.height - side) < 0.5 else {
                return "\(name) measures \(view.frame.size), expected \(side)x\(side) - one square, not several"
            }
        }

        // The radii have to match too, or three identically-sized tiles still
        // read as different shapes.
        var radii: Set<CGFloat> = []
        for button in bar.debugIconSquares() { radii.insert(button.debugIconBackground.layer?.cornerRadius ?? -1) }
        radii.insert(bar.notificationCenter.bell.debugIconFrameRadius)
        guard radii.count == 1 else {
            return "the icon squares use \(radii.count) different corner radii (\(radii.sorted())) - B2 asks for one"
        }
        return nil
    }

    private static func test_b2ShortcutHoverAndActiveState() -> String? {
        // Daylight, because that is the family whose domain hues are real
        // (`identityHex` is uniformly neutral on the twelve - see
        // `DaylightBarIconButton`'s header for why that is the honest
        // fallback rather than a gap).
        guard let daylight = HelmTheme.allThemes.first(where: { $0.id == "daylight" }) else {
            return "no `daylight` theme - has the palette been renamed?"
        }
        let bar = makeLaidOutBar()
        bar.applyThemeForTests(daylight)

        guard let button = bar.debugDestinationButtons().first else { return "no quick-access shortcuts on the bar" }
        let resting = button.debugGlyphColor

        button.debugSetHovering(true)
        let hovered = button.debugGlyphColor
        button.debugSetHovering(false)
        guard let resting, let hovered else { return "the shortcut has no glyph colour at all" }
        guard !sameColor(resting, hovered) else {
            return "\(button.destination.title): the glyph is the same colour hovered as at rest - "
                + "B2's whole point is that the row is quiet until you point at it"
        }
        let hue = HelmTheme.nsColor(button.destination.domainHue.identityHex(in: daylight))
        guard sameColor(hovered, hue) else {
            return "\(button.destination.title): hovered glyph is \(describe(hovered)), expected its own domain hue \(describe(hue))"
        }

        // Active: exactly the one showing, and it survives the pointer leaving.
        bar.setActiveDestination(button.destination)
        guard let active = button.debugGlyphColor, sameColor(active, hue) else {
            return "\(button.destination.title): its shortcut does not light while its own page is showing"
        }
        for other in bar.debugDestinationButtons() where other !== button {
            guard other.isActiveDestination == false else {
                return "\(other.destination.title) is lit too - only the destination actually showing may be"
            }
        }
        bar.setActiveDestination(nil)
        guard button.isActiveDestination == false else {
            return "clearing the active destination left \(button.destination.title) lit - a host page would keep "
                + "the last visited shortcut asserting it is current"
        }
        return nil
    }

    private static func test_b2BellBadgeSitsOnTheGlyph() -> String? {
        let bar = makeLaidOutBar()
        let bell = bar.notificationCenter.bell

        bell.setBadgeCount(0)
        guard bell.debugBadgeIsHidden else { return "the badge shows with nothing waiting - PRODUCT.md's \"quiet until it matters\"" }

        bell.setBadgeCount(3)
        bell.layoutSubtreeIfNeeded()
        guard !bell.debugBadgeIsHidden else { return "the badge stays hidden with 3 waiting" }
        guard bell.debugBadgeText == "3" else { return "badge reads '\(bell.debugBadgeText)' for a count of 3" }

        // The finding's own words: "attached to the symbol's corner". A symbol
        // is inside the tile, so the badge has to be too - which is exactly
        // what both previous attempts at an attached badge could not manage,
        // because they aimed at the *tile's* rounded corner instead.
        let badge = bell.debugBadgeFrame
        let icon = bell.debugIconFrame
        guard icon.contains(badge) else {
            return "the badge \(badge) is not inside the icon tile \(icon) - it is beside the square again, "
                + "which is the shape B2 asks to replace"
        }
        guard abs(badge.width - NotificationBellButton.badgeSide) < 0.5,
              abs(badge.height - NotificationBellButton.badgeSide) < 0.5 else {
            return "the badge measures \(badge.size), expected \(NotificationBellButton.badgeSide) square"
        }
        // Top-trailing, not centred or leading - a badge anywhere else is not
        // a corner badge.
        //
        // Read flip-agnostically. Auto Layout's `topAnchor` always means the
        // *visual* top, but a frame read does not: in an unflipped superview
        // (AppKit's default, and `NSButton`'s) a subview's `origin.y` is
        // measured from the bottom, so the visually-top badge reports a *low*
        // y. Asserting `maxY <= midY` without checking would fail against
        // correct geometry - which is exactly what it did the first time this
        // check ran.
        // Centres, not edges: a 15pt badge inset 3pt from a 34pt tile's top
        // spans 3...18 against a midline of 17, so demanding it sit *entirely*
        // in the top half fails a badge that is plainly in the corner. Where
        // its centre lands is the question "is this a corner badge" actually
        // asks.
        let badgeIsAtTop = bell.isFlipped
            ? badge.midY < icon.midY
            : badge.midY > icon.midY
        guard badgeIsAtTop, badge.midX >= icon.midX else {
            return "the badge sits at \(badge) inside \(icon) (flipped: \(bell.isFlipped)) - expected the top-trailing corner"
        }

        bell.setBadgeCount(42)
        guard bell.debugBadgeText == "9+" else {
            return "badge reads '\(bell.debugBadgeText)' for 42 - a badge this size carries one digit, "
                + "and the exact count is spoken and listed in the panel"
        }
        // The exact count still has to be *reachable*, which is the half that
        // makes abbreviating honest rather than lossy.
        guard (bell.accessibilityLabel() ?? "").contains("42") else {
            return "the accessibility label no longer carries the exact count: \(bell.accessibilityLabel() ?? "nil")"
        }
        return nil
    }

    // MARK: B3 - the launch focus ring

    private static func test_b3InitialFirstResponderIsThePage() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            defer { window.orderOut(nil) }
            shell.show(.homeCanvas)
            window.contentView?.layoutSubtreeIfNeeded()
            shell.updateKeyViewLoop()

            guard let initial = window.initialFirstResponder as? NSView else {
                return "the window has no initial first responder at all - Tab would start nowhere"
            }
            // The reported bug, stated directly: it used to be `chain.first`,
            // i.e. the first space pill.
            let barChain = shell.barKeyViewChainForTests
            if barChain.contains(where: { $0 === initial }) {
                return "the window's initial focus is a bar control - that is exactly B3's bug, and at launch "
                    + "it draws a focus ring on a space pill beside a differently decorated selected one"
            }
            let canvasView = shell.homeCanvasForTests.view
            var ancestor: NSView? = initial
            while let current = ancestor, current !== canvasView { ancestor = current.superview }
            guard ancestor === canvasView else {
                return "the initial focus is neither the bar nor the canvas - B3 asks for the page"
            }
            return nil
        }
    }

    private static func test_b3FocusRingOnlyForKeyboardFocus() -> String? {
        let saved = HelmFocusVisibility.overrideForTests
        defer { HelmFocusVisibility.overrideForTests = saved }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.setFrame(NSRect(x: -20_000, y: 0, width: 200, height: 60), display: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        window.contentView = root

        // A real activatable `HoverHighlightView` - the class both a space pill
        // and a canvas module card are built from.
        let view = HoverHighlightView()
        view.frame = NSRect(x: 10, y: 10, width: 100, height: 30)
        view.addGestureRecognizer(NSClickGestureRecognizer(target: NSApp, action: #selector(NSApplication.hide(_:))))
        root.addSubview(view)
        root.layoutSubtreeIfNeeded()
        guard view.canBecomeKeyView else { return "the fixture view cannot take focus - the check would be vacuous" }

        HelmFocusVisibility.overrideForTests = false
        guard window.makeFirstResponder(view) else { return "could not focus the fixture view (no keyboard)" }
        guard view.focusRingType == .none else {
            return "focus arrived with no key event and still painted a ring (\(view.focusRingType.rawValue)) - "
                + "this is the launch-time ring B3 is about"
        }

        _ = window.makeFirstResponder(root)
        HelmFocusVisibility.overrideForTests = true
        guard window.makeFirstResponder(view) else { return "could not re-focus the fixture view" }
        guard view.focusRingType == .exterior else {
            return "keyboard-driven focus paints no ring (\(view.focusRingType.rawValue)) - that would undo GL-16, "
                + "which measured that a keyboard user could not see where focus was anywhere in this app"
        }
        return nil
    }

    // MARK: B4 - the navigation transition

    private static func test_b4TransitionSkippedWhenAlreadyShowing() -> String? {
        let savedMotion = HelmMotion.reducedOverrideForTests
        defer { HelmMotion.reducedOverrideForTests = savedMotion }
        HelmMotion.reducedOverrideForTests = false

        return withScratchEnv {
            let (window, shell) = makeMountedShell()
            defer { window.orderOut(nil) }
            shell.show(.homeCanvas)
            window.contentView?.layoutSubtreeIfNeeded()

            // Drill in: a real navigation to a different destination.
            shell.show(.review)
            guard let drill = shell.lastTransitionForTests else { return "no transition was recorded for a real navigation" }
            guard !drill.skipped else { return "navigating from the canvas to Review was skipped as a no-op" }
            guard case .drillIn = drill.direction else { return "going to a drill page reported \(drill.direction), expected .drillIn" }

            guard abs(drill.entryOffset - AppShellController.destinationTransitionOffset) < 0.01 else {
                return "the incoming page entered at dx=\(drill.entryOffset), "
                    + "expected +\(AppShellController.destinationTransitionOffset)"
            }

            // And the animation genuinely exists on the layer, rather than the
            // code merely having recorded that it meant to make one. The model
            // transform is already back at identity by now
            // (`runAnimationGroup`'s body is synchronous), so the animation
            // object is the only evidence left.
            guard let layer = shell.destinationViewIfMountedForTests(RailDestination.review.slot)?.layer else {
                return "the Review page has no layer - the slide has nothing to animate"
            }
            guard !(layer.animationKeys() ?? []).isEmpty else {
                return "no animation was added to the incoming page's layer - the navigation is still a hard cut"
            }

            // Now the finding's own explicit requirement.
            shell.show(.review)
            guard let repeated = shell.lastTransitionForTests, repeated.skipped else {
                return "navigating to the destination already showing animated again - B4 asks for it to be "
                    + "\"skipped when the destination is already visible\""
            }
            guard let settled = shell.destinationViewIfMountedForTests(RailDestination.review.slot) else {
                return "Review unmounted itself"
            }
            guard abs(settled.alphaValue - 1) < 0.001,
                  abs(settled.layer?.transform.m41 ?? 0) < 0.01 else {
                return "the skipped navigation left the page at alpha \(settled.alphaValue) / dx "
                    + "\(settled.layer?.transform.m41 ?? 0) - a skip has to land on the end state, not part way"
            }

            // Back out to the hub is the mirror image.
            shell.show(.homeCanvas)
            guard let back = shell.lastTransitionForTests, case .back = back.direction else {
                return "returning to the canvas reported \(String(describing: shell.lastTransitionForTests?.direction)), expected .back"
            }
            guard back.entryOffset < 0 else {
                return "the back navigation entered at dx=\(back.entryOffset) - it slides the same way as a "
                    + "drill-in, so the direction signals nothing"
            }
            return nil
        }
    }

    private static func test_b4ReduceMotionIsInstant() -> String? {
        let savedMotion = HelmMotion.reducedOverrideForTests
        defer { HelmMotion.reducedOverrideForTests = savedMotion }
        HelmMotion.reducedOverrideForTests = true

        return withScratchEnv {
            let (window, shell) = makeMountedShell()
            defer { window.orderOut(nil) }
            shell.show(.homeCanvas)
            shell.show(.review)
            guard let view = shell.destinationViewIfMountedForTests(RailDestination.review.slot) else {
                return "Review did not mount"
            }
            // `HelmMotion`'s own rule: the end state *instantly*, never the
            // same motion slower.
            guard abs(view.alphaValue - 1) < 0.001 else {
                return "Reduce Motion still faded the page in (alpha \(view.alphaValue))"
            }
            guard abs(view.layer?.transform.m41 ?? 0) < 0.01 else {
                return "Reduce Motion still slid the page in (dx \(view.layer?.transform.m41 ?? 0))"
            }
            guard let recorded = shell.lastTransitionForTests, recorded.reducedMotion,
                  abs(recorded.entryOffset) < 0.01 else {
                return "Reduce Motion still applied an entry offset "
                    + "(\(shell.lastTransitionForTests?.entryOffset ?? -1)) - a halved motion is still motion"
            }
            guard (view.layer?.animationKeys() ?? []).isEmpty else {
                return "Reduce Motion still added a layer animation - `HelmMotion`'s rule is the end state instantly"
            }
            return nil
        }
    }

    // MARK: B5 - the panels

    private static func test_b5PanelsAreBorderlessAndThemed() -> String? {
        for theme in [HelmTheme.allThemes.first(where: { $0.id == "daylight" }),
                      HelmTheme.allThemes.first(where: { $0.id == "helm-dark" })].compactMap({ $0 }) {
            ThemeManager.shared.setTheme(theme)
            let bar = makeLaidOutBar()
            for (name, panel) in bar.debugBarPanels() {
                let window = panel.debugPanelWindow
                guard !window.isOpaque else {
                    return "\(name) on \(theme.id): the panel window is opaque, so its corner radius cannot read - "
                        + "the stock square chrome B5 is about"
                }
                guard window.hasShadow else {
                    return "\(name) on \(theme.id): no window shadow - B5 asks for raised elevation, and a layer "
                        + "shadow inside the clipped content view would be drawn inside its own mask"
                }
                guard let content = window.contentView else { return "\(name): no content view" }
                guard abs((content.layer?.cornerRadius ?? 0) - HelmBarPanel.cornerRadius) < 0.01 else {
                    return "\(name) on \(theme.id): content radius \(content.layer?.cornerRadius ?? 0), "
                        + "expected the palette's own \(HelmBarPanel.cornerRadius)"
                }
                guard content.layer?.masksToBounds == true else {
                    return "\(name) on \(theme.id): the content view does not clip, so the radius is decorative"
                }
                let expected: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
                guard window.appearance?.name == expected else {
                    return "\(name) on \(theme.id): appearance is \(window.appearance?.name.rawValue ?? "nil"), "
                        + "expected \(expected.rawValue) - system-semantic content inside would follow the OS"
                }
            }
        }
        return nil
    }

    private static func test_b5PanelAnchorsAndDismisses() -> String? {
        let bar = makeLaidOutBar()
        // Off-screen, so nothing lands on the captain's own display. The panel
        // follows its anchor's window and `HelmBarPanel.position` deliberately
        // clamps only to the anchor's *own* screen, of which there is none here.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1200, height: 120), display: false)
        window.contentView = bar.view
        bar.view.layoutSubtreeIfNeeded()

        let panel = bar.notificationCenter.debugPanel
        let bell = bar.notificationCenter.bell
        defer { panel.close() }

        guard !panel.isShown else { return "the panel is showing before anything opened it" }
        panel.show(under: bell)
        guard panel.isShown else { return "the panel did not open" }
        guard panel.debugHasClickMonitors else {
            return "no outside-click monitors while open - a bare NSPanel has no built-in dismissal, so the "
                + "panel would only close via its own button"
        }

        let anchorOnScreen = window.convertToScreen(bell.convert(bell.bounds, to: nil))
        let frame = panel.debugPanelWindow.frame
        guard frame.maxY <= anchorOnScreen.minY + 0.5 else {
            return "the panel's top (\(frame.maxY)) is not below the control's bottom (\(anchorOnScreen.minY)) - "
                + "B5 asks for it anchored *under* the control"
        }
        guard abs(frame.maxX - anchorOnScreen.maxX) < 0.5 else {
            return "the panel's trailing edge (\(frame.maxX)) does not line up with the control's "
                + "(\(anchorOnScreen.maxX)) - every one of these controls sits near the window's trailing edge"
        }

        // Escape, the way a captain would.
        panel.debugPanelWindow.cancelOperation(nil)
        guard !panel.isShown else { return "Escape did not close the panel" }
        guard !panel.debugHasClickMonitors else { return "the outside-click monitors outlived the panel" }
        return nil
    }

    private static func test_b5PanelsAreLockRegistered() -> String? {
        let bar = makeLaidOutBar()
        let registered = AppLockGate.shared.debugRegisteredWindows
        for (name, panel) in bar.debugBarPanels() {
            guard registered.contains(where: { $0 === panel.debugPanelWindow }) else {
                return "\(name)'s panel is not registered with the lock gate. These used to be popovers on "
                    + "`registerLockDismissiblePopover`; a panel is its own window layered above the lock "
                    + "overlay, so it needs `registerSecondaryWindow` or it stays readable over the lock screen"
            }
        }
        return nil
    }

    // MARK: Fixtures

    private static func makeLaidOutBar() -> DaylightBarController {
        let bar = DaylightBarController()
        bar.loadView()
        bar.view.frame = NSRect(x: 0, y: 0, width: 1200,
                                height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()
        return bar
    }

    private static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        // Component-wise, never `HelmContrast.ratio` - that compares relative
        // *luminance*, so two entirely different hues of similar brightness
        // pass it. This codebase has walked into that twice.
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.02 && abs(x.1 - y.1) < 0.02 && abs(x.2 - y.2) < 0.02
    }

    private static func describe(_ color: NSColor) -> String {
        let c = HelmContrast.components(color)
        return String(format: "rgb(%.2f, %.2f, %.2f)", c.0, c.1, c.2)
    }

    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        WindowChromeFusion.apply(to: window)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                                         dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: ShiftStore(),
            dictationStore: DictationStore(), commandLibraryStore: CommandLibraryStore(),
            scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1220, height: 720), display: false)
        return (window, shell)
    }

    /// Same shape as every other window-backed suite's: isolate every file
    /// this touches, and put the captain's own theme and font size back.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-bar-nav-modernization-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }
}

#endif
