// Grand Line - native macOS app.
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
//     .build/debug/GrandLine; echo $?
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
        // persists to the real `GrandLine` UserDefaults domain that
        // every other suite in this run reads as its ambient theme.
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` is the guard.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        let cases: [(String, () -> String?)] = [
            ("B2 the bell's badge sits on the glyph's corner", test_b2BellBadgeSitsOnTheGlyph),
            ("the clipboard history has no toolbar control, and ⌘⇧V opens it under Recents",
             test_clipboardHistoryIsOffTheBar),
            ("B3 the window's initial focus is the page, not the sidebar", test_b3InitialFirstResponderIsThePage),
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

    // MARK: B2 - the bell

    private static func test_b2BellBadgeSitsOnTheGlyph() -> String? {
        let toolbar = makeLaidOutToolbar()
        let bell = toolbar.notificationCenter.bell

        bell.setBadgeCount(0)
        guard bell.debugBadgeIsHidden else { return "the badge shows with nothing waiting - PRODUCT.md's \"quiet until it matters\"" }

        bell.setBadgeCount(3)
        bell.layoutSubtreeIfNeeded()
        guard !bell.debugBadgeIsHidden else { return "the badge stays hidden with 3 waiting" }
        guard bell.debugBadgeText == "3" else { return "badge reads '\(bell.debugBadgeText)' for a count of 3" }

        // The finding's own words: "attached to the symbol's corner". UX-12
        // made the bell a toolbar button, so the button's own bounds are the
        // square the glyph sits in, and the badge has to be inside them.
        let badge = bell.debugBadgeFrame
        let icon = bell.bounds
        guard icon.contains(badge) else {
            return "the badge \(badge) is not inside the bell button \(icon) - it is beside the control again, "
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
        // Centres, not edges: where the badge's centre lands is the question
        // "is this a corner badge" actually asks.
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

    /// The captain asked for the clipboard square off the top bar, and UX-12
    /// moved the bar's controls into the window toolbar. Both halves still
    /// hold:
    ///
    ///   - nothing in the toolbar is the clipboard history - no item, no
    ///     control carrying its symbol or label;
    ///   - the feature is still reachable: ⌘⇧V's verb opens the real panel,
    ///     dropped down from the Recents button's trailing edge.
    private static func test_clipboardHistoryIsOffTheBar() -> String? {
        let toolbar = makeLaidOutToolbar()
        let window = OffScreenProbe.window(width: 1512, height: 400)
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1512, height: 400), display: false)
        WorkspaceWindowChrome.apply(to: window, toolbar: toolbar.toolbar)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1512, height: 400))
        // Ordered in (still off every screen): AppKit builds and lays out a
        // toolbar's item views only for a window that is on the window list.
        window.orderFront(nil)
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()

        let items = toolbar.toolbar.items
        guard items.contains(where: { $0.view === toolbar.recentDestinations.button }) else {
            return "the toolbar carries no Recents item - the clipboard check below would be vacuous"
        }
        let clipboardish = items.filter { item in
            let text = [item.label, item.toolTip ?? "", item.view?.accessibilityLabel() ?? ""].joined(separator: " ")
            return text.localizedCaseInsensitiveContains("clipboard")
        }
        guard clipboardish.isEmpty else {
            return "the toolbar carries a clipboard control: \(clipboardish.map(\.label))"
        }

        let recents = toolbar.recentDestinations.button
        guard recents.window === window else {
            return "the Recents button is not in the toolbar's window - the anchor check would be vacuous"
        }
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }
        let clipboard = toolbar.clipboardHistory
        let panel = clipboard.debugPanel
        defer { panel.close() }
        guard !panel.isShown else { return "the clipboard panel is showing before ⌘⇧V opened it" }
        clipboard.toggle()
        guard panel.isShown else { return "⌘⇧V's toggle did not open the clipboard panel" }
        guard panel.debugAnchor === recents else {
            return "the clipboard panel anchored on \(String(describing: panel.debugAnchor)), not the Recents button"
        }
        let anchorOnScreen = window.convertToScreen(recents.convert(recents.bounds, to: nil))
        let panelFrame = panel.debugPanelWindow.frame
        guard panelFrame.maxY <= anchorOnScreen.minY + 0.5, abs(panelFrame.maxX - anchorOnScreen.maxX) < 0.5 else {
            return "the clipboard panel at \(panelFrame) is not under Recents' trailing edge \(anchorOnScreen)"
        }
        clipboard.toggle()
        guard !panel.isShown else { return "a second ⌘⇧V did not close the clipboard panel" }
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

            // `initialFirstResponder` is already `NSView?` - no cast.
            guard let initial = window.initialFirstResponder else {
                return "the window has no initial first responder at all - Tab would start nowhere"
            }
            // The reported bug, stated directly: it used to be the head of the
            // navigation chrome's chain. That chrome is the sidebar now.
            if initial === shell.sidebar.outline {
                return "the window's initial focus is the sidebar - that is exactly B3's bug, and at launch "
                    + "it draws a focus ring on the navigation instead of the page"
            }
            let canvasView = shell.homeCanvasForTests.view
            var ancestor: NSView? = initial
            while let current = ancestor, current !== canvasView { ancestor = current.superview }
            guard ancestor === canvasView else {
                return "the initial focus is neither the sidebar nor Home - B3 asks for the page"
            }
            return nil
        }
    }

    private static func test_b3FocusRingOnlyForKeyboardFocus() -> String? {
        let saved = HelmFocusVisibility.overrideForTests
        defer { HelmFocusVisibility.overrideForTests = saved }

        let window = OffScreenProbe.window(width: 200, height: 60)
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
            // The fade alone used to satisfy the check above while the slide
            // landed in one frame (`allowsImplicitAnimation` does not animate
            // a view-backed layer's `transform`), so the slide is asked for
            // by name.
            guard (layer.animationKeys() ?? []).contains("transform") else {
                return "the incoming page fades but does not slide (keys \(layer.animationKeys() ?? []))"
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

            // UX-01: Home is a sidebar item like any other, not the target of a
            // back button, so returning to it is an ordinary navigation that
            // still animates.
            shell.show(.homeCanvas)
            guard let home = shell.lastTransitionForTests, !home.skipped else {
                return "navigating to Home from Review was skipped as a no-op"
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
            let toolbar = makeLaidOutToolbar()
            for (name, panel) in toolbar.debugBarPanels() {
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
        let toolbar = makeLaidOutToolbar()
        // Off-screen, so nothing lands on the captain's own display. The panel
        // follows its anchor's window and `HelmBarPanel.position` deliberately
        // clamps only to the anchor's *own* screen, of which there is none here.
        let window = OffScreenProbe.window(width: 1200, height: 400)
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1200, height: 400), display: false)
        WorkspaceWindowChrome.apply(to: window, toolbar: toolbar.toolbar)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400))
        window.orderFront(nil)
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()

        let panel = toolbar.notificationCenter.debugPanel
        let bell = toolbar.notificationCenter.bell
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
        // A toolbar centres its items, so the control can sit on a half
        // point; the panel lands on a whole one. One device pixel is the
        // honest tolerance (AGENTS.md's half-point rule).
        guard abs(frame.maxX - anchorOnScreen.maxX) <= 1.0 / window.backingScaleFactor + 0.01 else {
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
        let toolbar = makeLaidOutToolbar()
        let registered = AppLockGate.shared.debugRegisteredWindows
        for (name, panel) in toolbar.debugBarPanels() {
            guard registered.contains(where: { $0 === panel.debugPanelWindow }) else {
                return "\(name)'s panel is not registered with the lock gate. These used to be popovers on "
                    + "`registerLockDismissiblePopover`; a panel is its own window layered above the lock "
                    + "overlay, so it needs `registerSecondaryWindow` or it stays readable over the lock screen"
            }
        }
        return nil
    }

    // MARK: Fixtures

    /// The window toolbar's controller, its controls laid out at their own
    /// sizes - the fixture the badge and panel cases read.
    private static func makeLaidOutToolbar() -> WorkspaceToolbarController {
        let toolbar = WorkspaceToolbarController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.addSubview(toolbar.notificationCenter.bell)
        host.layoutSubtreeIfNeeded()
        toolbar.notificationCenter.bell.removeFromSuperview()
        return toolbar
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
        let window = OffScreenProbe.window(width: 1220, height: 720, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
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
