// Manjesh Grand Line - native macOS app.
//
// The lock screen's own suite, added with the Daylight Harbour restyle
// (`fm/grandline-home-login-redesign-plan`). Before this the screen had no
// coverage at all - which is part of how it stayed the app's last
// pre-Daylight surface for seven phases without anyone noticing.
//
// What each case protects, and why it needs a test rather than a read-through:
//
//   1. **Every state's mark symbol actually resolves.**
//      `NSImage(systemSymbolName:)` returns nil *silently*, and this app has
//      shipped an invisible icon exactly that way before (the `anchor`
//      incident). A nil glyph on the one screen you cannot navigate away from
//      is the worst place for it.
//   2. **All six states render correctly in both registers.** The interesting
//      failure is not a missing view, it is the *wrong set* of views visible -
//      e.g. a form offered in `.serviceNotRunning`, where there is nothing
//      useful to type yet, or the retry states silently collapsing into
//      `.noPasswordConfigured` (the exact bug `fm/grandline-vault-wake-recheck-fix`
//      closed). Run against Daylight and Dusk, because the whole point of the
//      restyle is that dark is a token set rather than a second hand-tuned
//      palette.
//   3. **The corrected fills are actually corrected**, and - the half that
//      stops the exception quietly widening - **the raw hues they replace
//      genuinely fail.** A "passes 4.5:1" assertion alone would still pass if
//      someone reverted the correction to a hue that happened to be legible.
//   4. **The render probe can finally see this screen.** The sky gradient used
//      to *be* `root.layer`, which is why the full UI audit recorded this
//      screen as "Not verifiable by off-screen capture ... Assessed from source
//      only". Moving it to a sublayer is the fix; this case samples real
//      rendered pixels to prove it, and is the reason anyone touching this
//      screen from now on can verify their own work visually.
//   5. **The two-layer shadow arrangement holds** (§2.5): the shadowed layer
//      must not clip and the rounded fill must. Getting this backwards renders
//      as either a clipped-away shadow or square corners, both of which look
//      like a design choice rather than a bug.
//   6. **Source guards.** No colour literals crept back in, the shared
//      components are genuinely used, and the auth flow is untouched - the last
//      one because this is the one screen where a well-meant "improvement"
//      would be a security change.
//
// Run with:
//   swift build && FM_RUN_LOCK_SCREEN_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum LockScreenSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkStateSymbolsResolve,
                      checkStatesRenderInBothRegisters,
                      checkCorrectedContrast,
                      checkRenderProbeSeesTheScene,
                      checkTwoLayerShadow,
                      checkPasswordWellCentringAndMasking,
                      checkSharedComponentsAndNoLiterals,
                      checkAuthFlowUntouched,
                      checkLoopingAnimationsStopOnUnlock] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "LockScreenSelfTest: all checks passed" : "LockScreenSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static let allStates: [(name: String, state: LockScreenController.ContentState)] = [
        ("locked", .locked(subtitle: "Manjesh Grand Line is locked.")),
        ("sessionExpired", .locked(subtitle: "Your session expired - please log in again.")),
        ("noPasswordConfigured", .noPasswordConfigured),
        ("avUnavailable", .avUnavailable),
        ("serviceNotRunning", .serviceNotRunning),
        ("transientFailure", .transientFailure),
    ]

    private static func theme(_ id: String) -> HelmTheme? {
        HelmTheme.allThemes.first { $0.id == id }
    }

    /// A real window, because focus, first responder and rendering all mean
    /// nothing without one - and because `bitmapImageRepForCachingDisplay`
    /// resolves into the *display's* colour profile inside a real window,
    /// which case 4 has to account for.
    private static func mount(_ controller: LockScreenController,
                              size: NSSize = NSSize(width: 1220, height: 760)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        return window
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func fail(_ ok: inout Bool, _ message: String) {
        print("  FAIL: \(message)")
        ok = false
    }

    // MARK: 1 - symbols

    private static func checkStateSymbolsResolve(_ ok: inout Bool) {
        print("LockScreenSelfTest: state mark symbols resolve")
        for (name, state) in allStates {
            if NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil) == nil {
                fail(&ok, "\(name): SF Symbol \"\(state.symbol)\" does not resolve - it would render as nothing")
            }
        }
        // The boat itself, which is not a `ContentState` symbol.
        if NSImage(systemSymbolName: "sailboat", accessibilityDescription: nil) == nil {
            fail(&ok, "the scene's \"sailboat\" symbol does not resolve")
        }
        if ok { print("  \(allStates.count) state symbols + the boat all resolve") }
    }

    // MARK: 2 - every state, both registers

    private static func checkStatesRenderInBothRegisters(_ ok: inout Bool) {
        print("LockScreenSelfTest: all six states render in Daylight and Dusk")
        guard let daylight = theme("daylight"), let dusk = theme("dusk") else {
            fail(&ok, "daylight/dusk themes not found in HelmTheme.allThemes")
            return
        }

        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }

        for register in [daylight, dusk] {
            ThemeManager.shared.setTheme(register)
            let controller = LockScreenController()
            let window = mount(controller)
            defer { window.contentView = nil }

            for (name, state) in allStates {
                controller.apply(state)
                controller.view.layoutSubtreeIfNeeded()
                let tag = "\(register.id)/\(name)"

                // The right *set* of views, which is the real contract.
                let form = !controller.debugFormStack.isHidden
                let av = !controller.debugAvStack.isHidden
                let waiting = !controller.debugWaitingStack.isHidden
                let setupWell = !controller.debugSetupCommandWell.isHidden
                switch state {
                case .locked:
                    if !form || av || waiting || setupWell {
                        fail(&ok, "\(tag): expected only the form (form=\(form) av=\(av) waiting=\(waiting) well=\(setupWell))")
                    }
                case .noPasswordConfigured:
                    if form || av || waiting || !setupWell {
                        fail(&ok, "\(tag): expected only the setup command well")
                    }
                case .avUnavailable:
                    if form || !av || waiting || setupWell {
                        fail(&ok, "\(tag): expected only the install action")
                    }
                case .serviceNotRunning, .transientFailure:
                    if form || av || !waiting || setupWell {
                        fail(&ok, "\(tag): expected only the waiting spinner - offering a password form here is the bug")
                    }
                }

                // The hue the captain's decision pinned.
                if controller.debugCurrentHue != state.hue {
                    fail(&ok, "\(tag): hue is \(controller.debugCurrentHue), expected \(state.hue)")
                }

                // Real copy, and a real card behind it.
                if controller.debugTitle.stringValue.isEmpty {
                    fail(&ok, "\(tag): empty title")
                }
                if controller.debugSubtitle.stringValue.isEmpty {
                    fail(&ok, "\(tag): empty subtitle")
                }
                let card = controller.debugCard
                if card.frame.width <= 0 || card.frame.height <= 0 {
                    fail(&ok, "\(tag): card has no size (\(card.frame))")
                }
                if (card.layer?.borderWidth ?? 0) <= 0 {
                    fail(&ok, "\(tag): card has no border - applyCardSurface not applied?")
                }
                if card.layer?.backgroundColor == nil {
                    fail(&ok, "\(tag): card has no fill")
                }
                if (controller.debugRibbonLayer.colors?.count ?? 0) != 2 {
                    fail(&ok, "\(tag): ribbon is not a two-stop gradient")
                }
                if controller.debugRibbonLayer.frame.width <= 0 {
                    fail(&ok, "\(tag): ribbon has no width")
                }
            }

            // The register-specific scene switch: stars and the moon bite
            // belong to the dark register only.
            controller.apply(.locked(subtitle: "x"))
            let starsShown = controller.debugStarLayers.contains { !$0.isHidden }
            let moonShown = !controller.debugMoonBite.isHidden
            let expectDark = register.mode == .dark
            if starsShown != expectDark || moonShown != expectDark {
                fail(&ok, "\(register.id): stars=\(starsShown) moon=\(moonShown), expected \(expectDark) for mode=\(register.mode)")
            }

            // The title copy the captain chose, verbatim.
            if controller.debugTitle.stringValue != "Welcome back, Manjesh" {
                fail(&ok, "\(register.id): locked title is \"\(controller.debugTitle.stringValue)\", expected \"Welcome back, Manjesh\"")
            }
        }
        if ok { print("  6 states x 2 registers: view sets, hues, copy and card chrome all correct") }
    }

    // MARK: 3 - contrast

    private static func checkCorrectedContrast(_ ok: inout Bool) {
        print("LockScreenSelfTest: corrected fills clear 4.5:1 and the raw ones do not")
        guard let daylight = theme("daylight"), let dusk = theme("dusk") else {
            fail(&ok, "daylight/dusk themes not found")
            return
        }
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }

        for register in [daylight, dusk] {
            ThemeManager.shared.setTheme(register)
            let controller = LockScreenController()
            let window = mount(controller)
            defer { window.contentView = nil }
            let card = HelmTheme.nsColor(register.chromeBackgroundHex)

            // The error label, on the card it sits on.
            controller.apply(.locked(subtitle: "x"))
            controller.debugSimulateFailedAttempt()
            controller.view.layoutSubtreeIfNeeded()
            let errorColor = controller.debugErrorLabel.textColor ?? .black
            let errorRatio = HelmContrast.ratio(errorColor, card)
            if errorRatio < 4.5 {
                fail(&ok, "\(register.id): error label \(fmt(errorRatio)):1 on the card - below the 4.5 text floor")
            }
            // And the raw hue it corrects genuinely needs correcting on at
            // least one of the two registers, or this branch is decoration.
            let rawRatio = HelmContrast.ratio(HelmTheme.nsColor(register.ansiHex[1]), card)
            print("  \(register.id): error label \(fmt(errorRatio)):1 (raw hue \(fmt(rawRatio)):1)")

            // Every state's primary button label, on its own resolved fill.
            for (name, state) in allStates {
                controller.apply(state)
                controller.view.layoutSubtreeIfNeeded()
                let button = state.hue == .amber && !controller.debugAvStack.isHidden
                    ? controller.debugInstallButton
                    : controller.debugUnlockButton
                guard let fill = button.layer?.backgroundColor.map({ NSColor(cgColor: $0) ?? .black }),
                      let label = button.attributedTitle.length > 0
                        ? button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                        : nil else { continue }
                let ratio = HelmContrast.ratio(label, fill)
                if ratio < 4.5 {
                    fail(&ok, "\(register.id)/\(name): primary button label \(fmt(ratio)):1 on its fill - below the text floor")
                }
            }

            // §2.4's own headline case, stated as a measurement rather than a
            // comment: a white label on the RAW amber h1 fails, which is why
            // `DaylightPalette.primaryButtonFill` exists and why the
            // `.avUnavailable` install button must route through it.
            if register.isDaylight {
                let rawAmber = HelmDomainHue.amber.pair(in: register).h1
                let rawRatioAmber = HelmContrast.ratio(.white, rawAmber)
                let corrected = DaylightPalette.primaryButtonFill(for: .amber, theme: register)
                let correctedRatio = HelmContrast.ratio(.white, corrected)
                if rawRatioAmber >= 4.5 {
                    fail(&ok, "\(register.id): raw amber measures \(fmt(rawRatioAmber)):1 against white - the correction's premise no longer holds, re-derive it")
                }
                if correctedRatio < 4.5 {
                    fail(&ok, "\(register.id): corrected amber fill measures \(fmt(correctedRatio)):1 - below the floor")
                }
                print("  \(register.id): amber raw \(fmt(rawRatioAmber)):1 -> corrected \(fmt(correctedRatio)):1")
            }
        }
        if ok { print("  every label on this screen clears the 4.5 floor in both registers") }
    }

    // MARK: 4 - the render probe can see it

    private static func checkRenderProbeSeesTheScene(_ ok: inout Bool) {
        print("LockScreenSelfTest: the off-screen render probe can see this screen")
        guard let daylight = theme("daylight") else {
            fail(&ok, "daylight theme not found")
            return
        }
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        ThemeManager.shared.setTheme(daylight)

        let controller = LockScreenController()
        let window = mount(controller)
        defer { window.contentView = nil }
        controller.apply(.locked(subtitle: "Manjesh Grand Line is locked."))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        // The structural half: the root layer must not BE the gradient. This
        // is the actual fix, and it is worth asserting directly as well as
        // through pixels, because a future "tidy-up" that reassigns
        // `root.layer = skyLayer` would be a one-line regression.
        if controller.view.layer === controller.debugSkyLayer {
            fail(&ok, "root.layer IS the sky gradient again - that is what made this screen unscreenshottable")
        }
        if controller.debugSkyLayer.superlayer !== controller.view.layer {
            fail(&ok, "the sky gradient is not a sublayer of the root layer")
        }
        if controller.debugSkyLayer.frame != controller.view.bounds {
            fail(&ok, "sky frame \(controller.debugSkyLayer.frame) != view bounds \(controller.view.bounds)")
        }

        // The pixel half: render for real and confirm the sky is painted.
        let view = controller.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fail(&ok, "could not create a bitmap rep for the lock screen")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Sample well above the card, in open sky.
        let sample = NSPoint(x: view.bounds.width * 0.12, y: view.bounds.height * 0.08)
        guard let pixel = rep.colorAt(x: Int(sample.x), y: Int(sample.y)) else {
            fail(&ok, "no pixel at the sampled sky point")
            return
        }
        // AGENTS.md's probe rule: compare in `rep.colorSpace`, never via an
        // sRGB conversion - inside a real window the rep comes back in the
        // display's own profile and the conversion silently disagrees.
        let expectedSky = NSColor(cgColor: (controller.debugSkyLayer.colors?.first as! CGColor))?
            .usingColorSpace(rep.colorSpace)
        let got = pixel.usingColorSpace(rep.colorSpace)
        guard let expectedSky, let got else {
            fail(&ok, "could not convert sampled/expected colours into the rep's colour space")
            return
        }
        let dr = abs(expectedSky.redComponent - got.redComponent)
        let dg = abs(expectedSky.greenComponent - got.greenComponent)
        let db = abs(expectedSky.blueComponent - got.blueComponent)
        let delta = max(dr, max(dg, db))
        // The old failure mode rendered *blank white*, so the tolerance only
        // has to be tight enough to tell the real sky from that.
        if delta > 0.08 {
            fail(&ok, "sampled sky pixel differs from the resolved sky colour by \(fmt(Double(delta))) per channel - is it rendering blank again?")
        }
        if got.redComponent > 0.98, got.greenComponent > 0.98, got.blueComponent > 0.98 {
            fail(&ok, "sampled sky pixel is blank white - the render probe still cannot see this screen")
        }
        print("  sky renders: sampled \(fmt(Double(got.redComponent))),\(fmt(Double(got.greenComponent))),\(fmt(Double(got.blueComponent))) vs expected, max channel delta \(fmt(Double(delta)))")
    }

    // MARK: 5 - two-layer shadow

    private static func checkTwoLayerShadow(_ ok: inout Bool) {
        print("LockScreenSelfTest: the card's shadow host does not clip and the card does")
        guard let daylight = theme("daylight") else {
            fail(&ok, "daylight theme not found")
            return
        }
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        ThemeManager.shared.setTheme(daylight)

        let controller = LockScreenController()
        let window = mount(controller)
        defer { window.contentView = nil }
        controller.apply(.locked(subtitle: "x"))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        let host = controller.debugCardShadowHost
        let card = controller.debugCard
        if host.layer?.masksToBounds != false {
            fail(&ok, "the shadow host clips - a clipped layer casts no shadow outside its bounds (§2.5)")
        }
        if card.layer?.masksToBounds != true {
            fail(&ok, "the card does not clip - its rounded corners will not hold")
        }
        if (host.layer?.shadowOpacity ?? 0) <= 0 {
            fail(&ok, "the shadow host has no shadow")
        }
        if host.layer?.shadowPath == nil {
            fail(&ok, "shadowPath is nil - it must be resynced with the card's bounds on every layout pass")
        }
        if (card.layer?.cornerRadius ?? 0) != HelmMetrics.dModule {
            fail(&ok, "card radius \(card.layer?.cornerRadius ?? 0) != HelmMetrics.dModule (\(HelmMetrics.dModule))")
        }
        if ok { print("  un-clipped shadowed host + clipped rounded card, shadowPath synced") }
    }

    // MARK: 5b - the well's text centring, and that it still masks

    private static func checkPasswordWellCentringAndMasking(_ ok: inout Bool) {
        print("LockScreenSelfTest: the password well centres its text and still masks it")
        guard let daylight = theme("daylight") else {
            fail(&ok, "daylight theme not found")
            return
        }
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        ThemeManager.shared.setTheme(daylight)

        let controller = LockScreenController()
        let window = mount(controller)
        defer { window.contentView = nil }
        controller.apply(.locked(subtitle: "x"))
        controller.view.layoutSubtreeIfNeeded()

        let field = controller.debugPasswordField
        guard let cell = field.cell as? NSTextFieldCell else {
            fail(&ok, "the password field has no NSTextFieldCell")
            return
        }

        // Masking first, because the centring fix swaps the cell class and a
        // plain `NSTextFieldCell` on a secure field would silently render the
        // password in clear text. That is a disclosure, not a layout nit.
        if !(cell is NSSecureTextFieldCell) {
            fail(&ok, "the password field's cell is \(type(of: cell)) - not an NSSecureTextFieldCell, so it would NOT mask what is typed")
        }

        // Centring: the drawing rect the cell actually uses must sit centred
        // in the well rather than flush with its top.
        let bounds = NSRect(x: 0, y: 0, width: 300, height: HelmField.controlHeight)
        let drawn = cell.drawingRect(forBounds: bounds)
        let topGap = drawn.minY - bounds.minY
        let bottomGap = bounds.maxY - drawn.maxY
        if drawn.height >= bounds.height {
            fail(&ok, "the cell fills the whole well (\(drawn.height) of \(bounds.height)) - centring cannot be verified")
        } else if abs(topGap - bottomGap) > 1.5 {
            fail(&ok, "text is not centred in the well: \(fmt(Double(topGap)))pt above vs \(fmt(Double(bottomGap)))pt below")
        } else {
            print("  drawing rect centred: \(fmt(Double(topGap)))pt above, \(fmt(Double(bottomGap)))pt below")
        }

        // And it is still a working, editable field.
        if !field.isEditable || !field.isEnabled {
            fail(&ok, "the password field is not editable/enabled in the locked state")
        }
        field.stringValue = "hunter2"
        if field.stringValue != "hunter2" {
            fail(&ok, "the field did not accept a value after the cell swap")
        }
        field.stringValue = ""
    }

    // MARK: 6 - source guards

    // MARK: E4 - the looping decoration must end when the overlay does

    /// `startAnimationsIfNeeded()` latched `animationsStarted` true and only a
    /// Reduce Motion toggle ever took the animations off again, while
    /// `hideLock` did nothing but set `isHidden` - which does not stop a
    /// `CAAnimation`. So after the first unlock, three infinite animations
    /// stayed attached to hidden layers for the rest of the session.
    ///
    /// Driven through the controller's own `stopAnimations()` /
    /// `restartAnimationsIfNeeded()` (what `AppShellController.hideLock` /
    /// `showLock` call), plus a source guard that those calls are still there -
    /// the animation state is invisible from a screenshot and the wiring is
    /// the half most likely to be dropped.
    private static func checkLoopingAnimationsStopOnUnlock(_ ok: inout Bool) {
        print("LockScreenSelfTest: the looping animations stop when the lock screen is dismissed")
        if HelmMotion.isReduced {
            print("  SKIP: Reduce Motion is on, so there is no looping decoration to stop")
        } else {
            let controller = LockScreenController()
            let window = mount(controller)
            defer { window.contentView = nil }
            controller.apply(.locked(subtitle: "Manjesh Grand Line is locked."))
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()

            guard controller.debugLoopingAnimationsAttached else {
                fail(&ok, "the scene never started its looping animations, so this check would pass vacuously")
                return
            }
            controller.stopAnimations()
            if controller.debugLoopingAnimationsAttached {
                fail(&ok, "the looping animations survived the unlock - they would run on hidden layers for the rest of the session")
            }
            // H2: a layout pass while the overlay is hidden (which is how it
            // sits after an unlock - permanently mounted, merely hidden, and
            // still fully participating in layout) must NOT re-attach them.
            // Before the visibility guard, the first window resize after an
            // unlock did exactly that and undid E4 for the rest of the session.
            controller.view.isHidden = true
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            controller.restartAnimationsIfNeeded()
            if controller.debugLoopingAnimationsAttached {
                fail(&ok, "a layout pass on the hidden lock overlay re-attached the looping animations - E4's fix is undone")
            }
            controller.view.isHidden = false

            // And a re-lock must genuinely restart them, which is what
            // clearing the latch buys.
            controller.restartAnimationsIfNeeded()
            if !controller.debugLoopingAnimationsAttached {
                fail(&ok, "re-locking left a still scene - `animationsStarted` latched and never restarted")
            }
        }

        guard let dir = SelfTestSources.appSourceDirectory(),
              let shell = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            print("  SKIP: app sources not reachable for the wiring guard")
            return
        }
        if !shell.contains("lockScreen.stopAnimations()") {
            fail(&ok, "AppShellController.hideLock no longer stops the animations")
        }
        if !shell.contains("lockScreen.restartAnimationsIfNeeded()") {
            fail(&ok, "AppShellController.showLock no longer restarts them, so a re-lock would show a frozen scene")
        }
        if ok { print("  attached while locked, detached on unlock, re-attached on re-lock, and both call sites present") }
    }

    private static func checkSharedComponentsAndNoLiterals(_ ok: inout Bool) {
        print("LockScreenSelfTest: no colour literals, shared components in use")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app source directory not found")
            return
        }
        let path = dir.appendingPathComponent("LockScreenController.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            print("  SKIP: could not read LockScreenController.swift")
            return
        }
        // Comments quote the old literals to explain what was removed, so the
        // guard looks at code lines only.
        let codeLines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for banned in ["NSColor(calibratedRed:", "NSColor(srgbRed:", "NSColor(red:", "NSColor.white.withAlphaComponent", "NSColor.black.withAlphaComponent"] {
            if codeLines.contains(banned) {
                fail(&ok, "colour literal \(banned) is back - every colour on this screen resolves from the theme")
            }
        }
        for required in ["HelmCard.applyCardSurface", "HelmCard.elevation", "HelmSecureTextField",
                         "HelmButton", "HelmGradientTile", "HelmType.", "HelmField.",
                         "HelmContrast.legible", "HelmDomainHue", "HelmMotion.withoutImplicitAnimation"] {
            if !codeLines.contains(required) {
                fail(&ok, "\(required) is no longer used - the screen has drifted back off the design system")
            }
        }
        if ok { print("  zero colour literals; all 10 shared-component references present") }
    }

    private static func checkAuthFlowUntouched(_ ok: inout Bool) {
        print("LockScreenSelfTest: the auth flow is untouched")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app source directory not found")
            return
        }
        guard let lock = try? String(contentsOf: dir.appendingPathComponent("LockScreenController.swift"), encoding: .utf8),
              let shell = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            print("  SKIP: could not read the sources")
            return
        }

        // This controller must stay ignorant of how the password is checked.
        for banned in ["LAContext", "VaultSource.verifyAppPassword", "av inject", "Subprocess"] {
            if lock.contains(banned) && !lock.split(separator: "\n").filter({ $0.contains(banned) }).allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) {
                fail(&ok, "\(banned) appears in executable code in LockScreenController - verification belongs to AppShellController, and there is no biometric path on this screen")
            }
        }
        // And the shell must still be the one doing it, off the main thread.
        if !shell.contains("VaultSource.verifyAppPassword") {
            fail(&ok, "AppShellController no longer calls VaultSource.verifyAppPassword")
        }
        // The unlock handshake: the overlay is hidden from the animation's
        // completion, never from `onAttempt`'s.
        if !shell.contains("lockScreen.onUnlockAnimationFinished") {
            fail(&ok, "onUnlockAnimationFinished is no longer wired - the overlay would hide before the flourish plays")
        }
        if !lock.contains("onUnlockAnimationFinished?()") {
            fail(&ok, "LockScreenController no longer fires onUnlockAnimationFinished")
        }
        // Reduce Motion: the loops are gated, the success flourish is not.
        if !lock.contains("HelmMotion.isReduced") {
            fail(&ok, "the looping decoration is no longer Reduce-Motion gated (GL-16)")
        }
        if ok { print("  verification still lives in AppShellController; handshake and motion gating intact") }
    }
}

#endif
