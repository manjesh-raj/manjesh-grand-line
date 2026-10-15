// Grand Line - native macOS app.
//
// `fm/grandline-bar-active-state`: the top bar's squares follow one rule.
// A square is lit (its hued tile) while its page is open, however the page was
// opened, and every square shows a pressed tile while a press is held on it.
// The light/dark toggle is an action rather than a page, so it never lights.
// Instead it presses like the rest and shows the current appearance through
// its glyph.
//
// The captain reported Hosts and the toggle never showing their colour, while
// Console and the other shortcuts did. Three separate causes were behind it,
// and each has a case here:
//
//   - **Hosts is drawn by the overflow control**, not by a shortcut button.
//     It is the seventh of the seven default pins against UX2's cap of six,
//     and the old active-state loop only ever asked
//     `DaylightDestinationButton`s. `checkEveryBarDestinationLightsItsSquare`
//     opens every destination with a square and asserts exactly that square
//     is lit, which is the check that would have caught it.
//   - **The active state was pushed from two of the shell's three navigation
//     routes** and kept nowhere. The SRE Lead reply-jump skipped the push,
//     and a pin/unpin or a collapse rebuilt the row with nothing lit.
//     `checkOtherRoutesLightTheSameSquare` drives the other routes, and
//     `checkTheShellPushesFromOnePlace` source-guards the one call.
//   - **A real press drew nothing.** The pressed state hung off
//     `highlight(_:)`, which AppKit's tracking loop never calls on the
//     control. `checkARealClickDrawsThePressedTile` hands a real mouse-down
//     to the button and reads what the square drew while AppKit's tracking
//     loop was running.
//
// Run with:
//   swift build && FM_RUN_BAR_ACTIVE_STATE_TESTS=1 .build/debug/GrandLine; echo $?
//
// **Window-backed.** It mounts a real `AppShellController` in a real
// `OffScreenProbe` window, so it is listed in `NEEDS_SESSION`. Every state
// change is followed by a synchronous layout pass rather than a wait. The
// press cases do not depend on the window server delivering anything: the
// window is never made key or ordered front, the mouse-down goes straight to
// the button, and the mouse-up sits on this process's own queue for AppKit's
// tracking loop to take (`pressAndRelease` says why). No modal alert and no
// drag session is reachable from anything it drives.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum BarActiveStateSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        HelmMotion.reducedOverrideForTests = true
        let savedTheme = ThemeManager.shared.theme
        let savedQuickAccess = AppSettings.shared.quickAccess
        defer {
            HelmMotion.reducedOverrideForTests = nil
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.quickAccess = savedQuickAccess
        }
        var ok = true
        print("== BarActiveStateSelfTest ==")
        let cases: [(String, (inout Bool) -> Void)] = [
            ("every destination with a bar square lights exactly that square", checkEveryBarDestinationLightsItsSquare),
            ("Recents, the bar's own click, a host page, a pin change and a collapse keep it right",
             checkOtherRoutesLightTheSameSquare),
            ("the shell pushes the lit square from the one call every route makes",
             checkTheShellPushesFromOnePlace),
            ("a real click draws the pressed tile while it is held, then the active one",
             checkARealClickDrawsThePressedTile),
            ("the light/dark toggle shows the mode, presses, and never lights",
             checkTheToggleShowsTheModeAndPresses),
        ]
        for (name, body) in cases {
            var caseOK = true
            // A pin change in one case must not reshape the next one's bar.
            AppSettings.shared.quickAccess = QuickAccessConfiguration()
            autoreleasepool { body(&caseOK) }
            print(caseOK ? "OK   \(name)" : "FAIL \(name)")
            ok = ok && caseOK
        }
        print(ok ? "BarActiveStateSelfTest: all checks passed" : "BarActiveStateSelfTest: FAILED")
        return ok
    }

    // MARK: Fixture

    /// A real shell in a real off-screen window, at the tour lab's own size,
    /// which is above `quickAccessCollapseWidth` so the row is expanded.
    private static func mountShell(width: CGFloat = 1512) -> (window: NSWindow, shell: AppShellController) {
        let window = OffScreenProbe.window(width: width, height: 900, styleMask: [.titled, .resizable])
        WindowChromeFusion.apply(to: window)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let dictationStore = DictationStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         snippetStore: snippetStore, dictationStore: dictationStore),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: ShiftStore(),
            dictationStore: dictationStore, commandLibraryStore: CommandLibraryStore(),
            scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        // Assigning the controller resizes the window to its content's
        // fitting size, so the width is set again afterwards - the tour lab's
        // own `resize` step does the same.
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: width, height: 900),
                        display: true)
        shell.view.layoutSubtreeIfNeeded()
        return (window, shell)
    }

    /// The square that stands for `destination` on the bar right now: its own
    /// shortcut, or the overflow control when that is what draws it.
    private static func square(for destination: RailDestination,
                               in bar: DaylightBarController) -> DaylightBarIconButton? {
        if let shortcut = bar.debugDestinationButtons().first(where: { $0.destination == destination && !$0.isHidden }) {
            return shortcut
        }
        let overflow = bar.debugQuickAccessOverflowButton()
        return (!overflow.isHidden && overflow.debugSymbolName == destination.symbol) ? overflow : nil
    }

    private static func name(_ square: DaylightBarIconButton) -> String {
        if let shortcut = square as? DaylightDestinationButton { return shortcut.destination.rawValue }
        if square is DaylightThemeToggleButton { return "theme toggle" }
        if square is RecentDestinationsButton { return "recents" }
        return "overflow(\(square.debugSymbolName))"
    }

    /// The fill a square draws in a coloured state, from the same recipe and
    /// ladder the button uses - the expectation is the shared helper's answer
    /// for this square's own hue, not a value read back off the button.
    private static func tileFill(hex: String, theme: HelmTheme, steps: [CGFloat]) -> NSColor {
        HelmContrast.tintedSurface(tintHex: hex, theme: theme, target: HelmContrast.nonTextTarget,
                                   washSteps: steps).fill
    }

    private static func layerFill(_ square: DaylightBarIconButton) -> NSColor? {
        square.debugIconBackground.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    /// Asserts exactly one square is lit and it is `destination`'s, painted in
    /// that destination's own active tile.
    private static func expectLit(_ destination: RailDestination, in shell: AppShellController,
                                  route: String, _ ok: inout Bool) {
        shell.view.layoutSubtreeIfNeeded()
        let bar = shell.bar
        let lit = bar.debugActiveSquares()
        guard let expected = square(for: destination, in: bar) else {
            return fail("\(route): \(destination.rawValue) has no square on the bar", &ok)
        }
        guard lit.count == 1, lit[0] === expected else {
            return fail("\(route): with \(destination.rawValue) open the lit squares are "
                        + "\(lit.map(name)), expected exactly \(name(expected))", &ok)
        }
        let theme = ThemeManager.shared.theme
        let hex = DaylightBarIconButton.tileHex(for: destination, in: theme)
        let want = tileFill(hex: hex, theme: theme, steps: DaylightBarIconButton.activeTileWashSteps)
        check(sameColor(layerFill(expected), want),
              "\(route): \(destination.rawValue)'s lit square is not painted in its own active tile", &ok)
        check(expected.accessibilityValue() as? String == DaylightBarIconButton.activeAccessibilityValue,
              "\(route): VoiceOver hears \(String(describing: expected.accessibilityValue())) on the lit square", &ok)
    }

    private static func expectNoneLit(in shell: AppShellController, route: String, _ ok: inout Bool) {
        shell.view.layoutSubtreeIfNeeded()
        let lit = shell.bar.debugActiveSquares()
        check(lit.isEmpty, "\(route): \(lit.map(name)) lit with no bar page open", &ok)
    }

    // MARK: 1. Every destination with a square

    private static func checkEveryBarDestinationLightsItsSquare(_ ok: inout Bool) {
        let pinned = QuickAccessConfiguration.defaultPinned
        for themeID in ["daylight", "dusk"] {
            guard let theme = HelmTheme.theme(id: themeID) else { return fail("no `\(themeID)` theme", &ok) }
            ThemeManager.shared.setTheme(theme)
            let (window, shell) = mountShell()
            defer { window.close() }
            let bar = shell.bar

            // Discriminating power: the fixture really has a destination that
            // the overflow control draws, or this case cannot see the bug.
            let onRow = Set(bar.debugDestinationButtons().map(\.destination))
            guard pinned.contains(.hosts), !onRow.contains(.hosts),
                  square(for: .hosts, in: bar) === bar.debugQuickAccessOverflowButton() else {
                return fail("\(themeID): Hosts is not drawn by the overflow control - the fixture lost the "
                            + "shape this case exists for (row \(onRow.map(\.rawValue)))", &ok)
            }

            shell.show(.homeCanvas)
            expectNoneLit(in: shell, route: "\(themeID) home", &ok)
            for destination in pinned {
                shell.show(destination)
                expectLit(destination, in: shell, route: "\(themeID) show", &ok)
            }
            // A page with no square clears the bar rather than leaving the
            // last one asserting it is current.
            shell.show(.settings)
            expectNoneLit(in: shell, route: "\(themeID) settings", &ok)
        }
    }

    // MARK: 2. The other routes

    private static func checkOtherRoutesLightTheSameSquare(_ ok: inout Bool) {
        let (window, shell) = mountShell()
        defer { window.close() }
        let bar = shell.bar

        // Recents' own click handler.
        shell.show(.console)
        shell.debugNavigateToRecent(.rail(.hosts))
        expectLit(.hosts, in: shell, route: "recents", &ok)

        // A space pill lands on the canvas, which has no square.
        shell.selectSpace(.engineering)
        expectNoneLit(in: shell, route: "space pill", &ok)

        // The bar's own squares, through `performClick` - the real target and
        // action, including the overflow control's straight-to-Hosts branch.
        bar.debugQuickAccessOverflowButton().performClick(nil)
        expectLit(.hosts, in: shell, route: "overflow click", &ok)
        if let console = square(for: .console, in: bar) {
            console.performClick(nil)
            expectLit(.console, in: shell, route: "shortcut click", &ok)
        } else {
            fail("no Console square on the bar", &ok)
        }

        // A host page is not a `RailDestination`, so nothing is lit on it.
        let hostID = UUID()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        shell.debugSeedHostConsole(ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                     isFirstmateConsole: false), hostID: hostID)
        shell.sessions.register(hostID: hostID, label: "DEV Bastion", accentHex: "#e8a23d", state: .connected)
        shell.switchToSession(hostID: hostID)
        check(shell.activeHostIDForTests == hostID, "switchToSession did not reveal the seeded host page", &ok)
        expectNoneLit(in: shell, route: "host page", &ok)

        // A pin change rebuilds every shortcut as a new view. Unpinning
        // Sticky Board brings Hosts onto the row, where it must stay lit.
        shell.show(.hosts)
        shell.toggleQuickAccessPin(.stickyBoard)
        check(bar.debugDestinationButtons().contains { $0.destination == .hosts },
              "unpinning Sticky Board should bring Hosts onto the row", &ok)
        expectLit(.hosts, in: shell, route: "after unpin", &ok)
        shell.toggleQuickAccessPin(.stickyBoard)
        expectLit(.hosts, in: shell, route: "after re-pin", &ok)

        // Narrower than `quickAccessCollapseWidth`, the whole row folds into
        // the overflow control, which then holds the open page.
        shell.show(.console)
        var frame = window.frame
        frame.size.width = DaylightBarController.quickAccessCollapseWidth - 100
        window.setFrame(frame, display: true)
        shell.view.layoutSubtreeIfNeeded()
        let overflow = bar.debugQuickAccessOverflowButton()
        guard overflow.debugSymbolName == "ellipsis", !overflow.isHidden else {
            return fail("at \(Int(frame.width))pt the row did not collapse into the overflow menu", &ok)
        }
        let lit = bar.debugActiveSquares()
        check(lit.count == 1 && lit[0] === overflow,
              "collapsed: with Console open the lit squares are \(lit.map(name)), expected the overflow menu", &ok)
        let theme = ThemeManager.shared.theme
        let slate = DaylightBarIconButton.tileHex(for: DaylightBarIconButton.chromeTileHue, in: theme)
        check(sameColor(layerFill(overflow), tileFill(hex: slate, theme: theme,
                                                      steps: DaylightBarIconButton.activeTileWashSteps)),
              "collapsed: the lit overflow menu is not in the bar's own slate tile", &ok)
        frame.size.width = 1512
        window.setFrame(frame, display: true)
        expectLit(.console, in: shell, route: "expanded again", &ok)
    }

    // MARK: 3. One push

    /// The behaviour above cannot drive the SRE Lead reply-jump (it needs a
    /// live SRE Lead reply), and that is the route that used to skip the
    /// push. So the push has one home, and this asserts it is the only one.
    private static func checkTheShellPushesFromOnePlace(_ ok: inout Bool) {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            return fail("could not find the app's sources - this guard cannot run", &ok)
        }
        let file = dir.appendingPathComponent("AppShellController.swift")
        guard let source = try? String(contentsOf: file, encoding: .utf8),
              source.contains("func updateRecentDestinations(arriving") else {
            return fail("AppShellController.swift has no updateRecentDestinations - the sentinel moved", &ok)
        }
        let calls = source.components(separatedBy: "bar.setActiveDestination(").count - 1
        guard let start = source.range(of: "private func updateRecentDestinations(arriving"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            return fail("could not isolate updateRecentDestinations' body", &ok)
        }
        let inside = String(source[start.lowerBound..<end.upperBound])
            .components(separatedBy: "bar.setActiveDestination(").count - 1
        check(calls > 0 && calls == inside,
              "bar.setActiveDestination is called \(calls) times in the shell and \(inside) of them are in "
              + "updateRecentDestinations - a second push site is how one route came to skip it", &ok)
    }

    // MARK: 4. A real press

    /// `NSApplication.shared`, never `NSApp` - AGENTS.md's rule.
    private static var app: NSApplication { NSApplication.shared }

    /// A real press and release, delivered to `button.mouseDown(with:)` itself.
    ///
    /// **Not posted through the window.** The first version of this case
    /// posted a mouse-down/mouse-up pair to the app's queue and let the app
    /// dispatch them, which passed locally and failed on CI's windowed lane:
    /// there the window is not key, and the first click into a non-key window
    /// is consumed by AppKit's activation and first-mouse handling before the
    /// button sees it. Which window is key is a property of the runner, not of
    /// this app, so the case now starts one step further in, at the button's
    /// own `mouseDown(with:)` - the method this branch overrides, and the one
    /// `NSWindow.sendEvent` calls for a click on it.
    ///
    /// Everything from there on is AppKit's own: `super.mouseDown` runs the
    /// button's real tracking loop, which dequeues the matching mouse-up
    /// itself and sends the action. That mouse-up is put on this process's own
    /// queue first, so the loop finds it immediately, with no window server
    /// and no wait. The fixture window is deliberately never made key or
    /// ordered front, which is the runner's situation.
    ///
    /// Returns whether the tracking loop consumed its mouse-up, so the case
    /// can tell "the loop ran and released" from "the loop never ran".
    @discardableResult
    private static func pressAndRelease(_ button: NSButton, in window: NSWindow) -> Bool {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        app.postEvent(up, atStart: true)
        button.mouseDown(with: down)
        // Anything the loop left behind is drained without waiting, so a
        // stray mouse-up cannot reach the next case.
        var consumed = true
        while let leftover = app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            if leftover.type == .leftMouseUp { consumed = false }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return consumed
    }

    private static func checkARealClickDrawsThePressedTile(_ ok: inout Bool) {
        guard let dusk = HelmTheme.theme(id: "dusk") else { return fail("no `dusk` theme", &ok) }
        ThemeManager.shared.setTheme(dusk)
        let (window, shell) = mountShell()
        defer {
            DaylightBarIconButton.debugOnPressChange = nil
            window.close()
        }
        // Never made key or ordered front - see `pressAndRelease`.
        shell.show(.homeCanvas)
        let bar = shell.bar

        var pressedFill: [ObjectIdentifier: NSColor] = [:]
        var pressedBorderAlpha: CGFloat = 0
        var releases: [ObjectIdentifier: Int] = [:]
        DaylightBarIconButton.debugOnPressChange = { square, pressed in
            let id = ObjectIdentifier(square)
            if pressed {
                pressedFill[id] = square.debugIconBackground.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
                pressedBorderAlpha = square.debugBorderColor?.alpha ?? 0
            } else {
                releases[id, default: 0] += 1
            }
        }

        // The overflow control, which draws Hosts and goes straight to it.
        let overflow = bar.debugQuickAccessOverflowButton()
        check(pressAndRelease(overflow, in: window), "the Hosts square's tracking loop never consumed its mouse-up", &ok)
        let hostsHex = DaylightBarIconButton.tileHex(for: .hosts, in: dusk)
        let wantPressed = tileFill(hex: hostsHex, theme: dusk, steps: DaylightBarIconButton.pressedTileWashSteps)
        guard let seen = pressedFill[ObjectIdentifier(overflow)] else {
            return fail("a real click on the Hosts square never entered the pressed state", &ok)
        }
        check(sameColor(seen, wantPressed), "the held Hosts square is not painted in its pressed tile", &ok)
        check(releases[ObjectIdentifier(overflow)] == 1 && !overflow.isPressed,
              "the Hosts square did not release exactly once on the mouse-up", &ok)
        // The click really navigated, so it was a click and not just a press.
        expectLit(.hosts, in: shell, route: "real click on Hosts", &ok)

        // Pressing the square whose page is already open still reads: the
        // pressed ladder is deeper than the active one.
        pressedFill.removeAll()
        pressAndRelease(overflow, in: window)
        let wantActive = tileFill(hex: hostsHex, theme: dusk, steps: DaylightBarIconButton.activeTileWashSteps)
        if let seenAgain = pressedFill[ObjectIdentifier(overflow)] {
            // Either the deeper wash or the firmer ring has to differ, or the
            // press is invisible on the one square a captain is most likely to
            // click twice.
            check(!sameColor(seenAgain, wantActive) || pressedBorderAlpha > DaylightBarIconButton.activeTileBorderAlpha,
                  "a press on the open page's square draws exactly its active tile", &ok)
        } else {
            fail("a real click on the already-lit Hosts square never entered the pressed state", &ok)
        }
        expectLit(.hosts, in: shell, route: "second click on Hosts", &ok)
    }

    // MARK: 5. The toggle

    private static func checkTheToggleShowsTheModeAndPresses(_ ok: inout Bool) {
        guard let daylight = HelmTheme.theme(id: "daylight"), let dusk = HelmTheme.theme(id: "dusk") else {
            return fail("no `daylight`/`dusk` theme", &ok)
        }
        check(daylight.mode != dusk.mode, "the fixture's two themes are the same mode", &ok)
        check(DaylightThemeToggleButton.lightSymbol != DaylightThemeToggleButton.darkSymbol,
              "the two mode glyphs are the same symbol", &ok)

        ThemeManager.shared.setTheme(daylight)
        let (window, shell) = mountShell()
        defer {
            DaylightBarIconButton.debugOnPressChange = nil
            window.close()
        }
        let toggle = shell.bar.debugThemeToggleButton()

        for (theme, symbol, value) in [(daylight, DaylightThemeToggleButton.lightSymbol, "Light"),
                                       (dusk, DaylightThemeToggleButton.darkSymbol, "Dark")] {
            ThemeManager.shared.setTheme(theme)
            shell.view.layoutSubtreeIfNeeded()
            check(toggle.debugSymbolName == symbol && toggle.debugHasIcon,
                  "\(theme.id): the toggle draws \(toggle.debugSymbolName), expected \(symbol)", &ok)
            check(toggle.accessibilityValue() as? String == value,
                  "\(theme.id): VoiceOver hears \(String(describing: toggle.accessibilityValue())), expected \(value)", &ok)

            // Monochrome at rest: the same plain square as its neighbours.
            let plain = theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.inset)
                : HelmTheme.nsColor(theme.chromeBackgroundHex)
            check(sameColor(layerFill(toggle), plain), "\(theme.id): the toggle is not monochrome at rest", &ok)

            // The keyboard's press (`performClick` goes through here).
            toggle.highlight(true)
            let slate = DaylightBarIconButton.tileHex(for: DaylightBarIconButton.chromeTileHue, in: theme)
            check(toggle.isPressed && sameColor(layerFill(toggle), tileFill(
                    hex: slate, theme: theme, steps: DaylightBarIconButton.pressedTileWashSteps)),
                  "\(theme.id): the held toggle is not in its pressed slate tile", &ok)
            toggle.highlight(false)
            check(!toggle.isPressed && sameColor(layerFill(toggle), plain),
                  "\(theme.id): the toggle did not return to rest on release", &ok)

            // An action, never a page.
            for destination in QuickAccessConfiguration.defaultPinned {
                shell.show(destination)
                if toggle.isActiveDestination {
                    fail("\(theme.id): the toggle lit with \(destination.rawValue) open", &ok)
                    break
                }
            }
        }

        // A real click flips the mode and the glyph with it.
        ThemeManager.shared.setTheme(daylight)
        shell.view.layoutSubtreeIfNeeded()
        var sawPress = false
        DaylightBarIconButton.debugOnPressChange = { square, pressed in
            if square === toggle && pressed { sawPress = true }
        }
        check(pressAndRelease(toggle, in: window), "the toggle's tracking loop never consumed its mouse-up", &ok)
        check(sawPress, "a real click on the toggle never entered the pressed state", &ok)
        check(ThemeManager.shared.theme.mode == .dark,
              "a real click on the toggle did not switch to a dark palette", &ok)
        check(toggle.debugSymbolName == DaylightThemeToggleButton.darkSymbol && !toggle.isPressed,
              "after the click the toggle draws \(toggle.debugSymbolName), pressed \(toggle.isPressed)", &ok)
    }
}

#endif
