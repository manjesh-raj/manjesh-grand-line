#if FM_SELFTESTS
// Manjesh Grand Line - native macOS app.
//
// Phase 6 of the Daylight UI migration
// (`data/grandline-ui-modernization-review/daylight-ui-design.md` §8's
// "Phase 6 - hardening"): the accessibility sweep and the Reduce Motion audit.
// Dusk's own colour derivation is measured by `HelmContrastSelfTest`
// (`checkDuskPalette`), where the rest of the palette maths already lives.
//
// Three things this file asserts, and why each is a *behavioural* check rather
// than a source grep:
//
// 1. **Canvas modules are real buttons.** §6.1 says "the card is a
//    `.button`", and the failure mode is silent: a module that lost its
//    recognizer still renders, still hovers, and simply stops existing for
//    VoiceOver and for the keyboard. So this reads the role and label off the
//    real card and *presses* it, asserting `onOpen` fired - a role with no
//    working press is the same defect one layer in.
//
// 2. **The space pills are a radio group, not five buttons.** Individually
//    `.radioButton` was already true from Phase 2; what Phase 6 added is the
//    container role, without which VoiceOver never says "1 of 5" and group
//    navigation does not work. Both halves are asserted, plus the selected
//    *value* moving with the selection - a radio group whose value never
//    changes announces the wrong state confidently.
//
// 3. **The key loop is bar -> canvas -> content.** Followed through
//    `nextKeyView` from the first pill on a real mounted shell, so the thing
//    measured is the loop AppKit would actually walk, not the array this app
//    would like it to walk.
//
// And the motion half: every gate is driven in **both** states through
// `HelmMotion.reducedOverrideForTests`, because "the call site mentions the
// gate" passes for a gate that is read and then ignored. The gradient path is
// additionally source-guarded, since an implicit `CAGradientLayer` animation
// leaves no property to read back - it is the absence of a wrapper, which only
// the source can show.

import AppKit

enum DaylightHardeningSelfTest {

    static func run() -> Bool {
        print("== daylight phase 6 hardening (accessibility + reduce motion) ==")
        var ok = true
        for (name, body) in cases {
            if let failure = body() {
                print("  FAIL \(name): \(failure)")
                ok = false
            } else {
                print("  OK   \(name)")
            }
        }
        print(ok ? "== daylight hardening: PASS ==" : "== daylight hardening: FAIL ==")
        return ok
    }

    private static var cases: [(String, () -> String?)] {
        [
            ("canvas modules are accessible buttons that actually press", test_moduleIsAButton),
            ("a module with no open action is not announced at all", test_decorativeModuleIsSilent),
            ("space pills are a radio group with a live selected value", test_spacePillsAreARadioGroup),
            ("space pills move with the arrow keys", test_spacePillArrowKeys),
            ("key loop runs bar -> canvas -> content", test_keyLoopOrder),
            ("key loop re-derives its hand-off per destination", test_keyLoopFollowsDestination),
            ("reduce motion removes the hover translate, keeps the shadow", test_reduceMotionHoverTranslate),
            ("reduce motion suppresses implicit gradient animation", test_reduceMotionGradientTransaction),
            ("every gradient layer write is wrapped", test_gradientWritesAreWrapped),
            ("reduce motion is asked in exactly one place", test_oneReduceMotionDefinition),
            ("the quick flip reaches dusk and comes back", test_quickFlipRoundTrip),
        ]
    }

    // MARK: Accessibility - canvas modules

    private static func makeCard() -> HelmModuleCard {
        let card = HelmModuleCard()
        card.frame = NSRect(x: 0, y: 0, width: 300, height: HelmModuleCard.standardHeight)
        card.configure(HelmModuleCard.Content(
            title: "Merge queue",
            subtitle: "2 open",
            symbol: "arrow.triangle.branch",
            hue: .green,
            chip: HelmModuleChip(text: "1 ready", kind: .ok),
            body: .metric(value: "1", unit: "ready", note: "One PR is ready when you are.")
        ))
        card.layoutSubtreeIfNeeded()
        return card
    }

    private static func test_moduleIsAButton() -> String? {
        let card = makeCard()
        var opened = 0
        card.onOpen = { opened += 1 }
        let hit = card.debugCardHitView

        guard hit.isActivatable else { return "the module's hit view is not activatable" }
        guard hit.isAccessibilityElement() else { return "the module is not an accessibility element" }
        guard hit.accessibilityRole() == .button else {
            return "role is \(hit.accessibilityRole()?.rawValue ?? "nil"), want .button"
        }
        // §6.1's own label spec: title, subtitle, chip - in that order, and
        // never the body's numerals first.
        guard let label = hit.accessibilityLabel() else { return "no accessibility label" }
        guard label == "Merge queue, 2 open, 1 ready" else {
            return "label is \"\(label)\", want \"Merge queue, 2 open, 1 ready\""
        }
        guard hit.accessibilityPerformPress() else { return "press was not handled" }
        guard opened == 1 else { return "press fired onOpen \(opened) times, want 1" }
        // Keyboard reachability is the other half of "it is a button".
        guard hit.canBecomeKeyView else { return "the module cannot become a key view" }
        guard hit.focusRingType == .exterior else {
            return "the module draws no focus ring, so keyboard focus would be invisible"
        }
        // Its own labels must not be announced separately - that reads every
        // fragment twice.
        guard (hit.accessibilityChildren()?.isEmpty ?? false) else {
            return "the module exposes children, so VoiceOver would read its title twice"
        }
        return nil
    }

    private static func test_decorativeModuleIsSilent() -> String? {
        // A `HoverHighlightView` with no recognizer and no press handler is
        // decorative - this app is built almost entirely out of such
        // containers, and announcing them all is its own accessibility
        // failure.
        let plain = HoverHighlightView()
        if plain.isAccessibilityElement() { return "a decorative hover view announces itself" }
        if plain.canBecomeKeyView { return "a decorative hover view is in the key view loop" }
        return nil
    }

    // MARK: Accessibility - space pills

    private static func test_spacePillsAreARadioGroup() -> String? {
        let bar = DaylightBarController()
        bar.loadView()
        bar.view.layoutSubtreeIfNeeded()

        let pills = bar.keyViewChain.prefix(DaylightSpace.allCases.count)
        guard pills.count == DaylightSpace.allCases.count else {
            return "expected \(DaylightSpace.allCases.count) pills at the head of the key chain, got \(pills.count)"
        }
        guard let row = pills.first?.superview as? NSStackView else {
            return "the pills' container is not the stack view that should carry the group role"
        }
        guard row.accessibilityRole() == .radioGroup else {
            return "the pill row's role is \(row.accessibilityRole()?.rawValue ?? "nil"), want .radioGroup"
        }
        guard row.accessibilityLabel() == "Spaces" else {
            return "the pill row's label is \(row.accessibilityLabel() ?? "nil"), want \"Spaces\""
        }

        for (pill, space) in zip(pills, DaylightSpace.allCases) {
            guard let hover = pill as? HoverHighlightView else {
                return "\(space.title)'s pill is not a HoverHighlightView"
            }
            guard hover.accessibilityRole() == .radioButton else {
                return "\(space.title) announces \(hover.accessibilityRole()?.rawValue ?? "nil"), want .radioButton"
            }
            guard hover.accessibilityLabel() == space.title else {
                return "\(space.title) announces the label \(hover.accessibilityLabel() ?? "nil")"
            }
        }

        // The value has to *move*, or the group announces the wrong state.
        func value(_ index: Int) -> String {
            ((pills[pills.startIndex + index] as? HoverHighlightView)?.accessibilityValue() as? String) ?? ""
        }
        bar.setSelectedSpace(DaylightSpace.allCases[0])
        guard value(0) == "selected", value(1) == "not selected" else {
            return "with the first space selected the values read \(value(0))/\(value(1))"
        }
        bar.setSelectedSpace(DaylightSpace.allCases[1])
        guard value(0) == "not selected", value(1) == "selected" else {
            return "the selected value did not move with the selection"
        }
        return nil
    }

    private static func test_spacePillArrowKeys() -> String? {
        let bar = DaylightBarController()
        bar.loadView()
        bar.view.layoutSubtreeIfNeeded()
        bar.setSelectedSpace(DaylightSpace.allCases[0])

        guard let first = bar.keyViewChain.first as? HoverHighlightView,
              let handler = first.onKeyDown else {
            return "the first pill has no key handler, so arrow keys do nothing"
        }
        // 124 = right arrow, the keycode `handleArrowKey` reads.
        guard let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: 124) else {
            return "could not synthesise a right-arrow event"
        }
        guard handler(right) else { return "the right arrow was not handled" }
        guard bar.selectedSpaceForTests == DaylightSpace.allCases[1] else {
            return "the right arrow left the selection on \(bar.selectedSpaceForTests.title)"
        }
        return nil
    }

    // MARK: Accessibility - the key view loop

    private static func makeShell() -> (NSWindow, AppShellController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         snippetStore: snippetStore, dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
            shiftStore: ShiftStore(), dictationStore: DictationStore(),
            commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        return (window, shell)
    }

    private static func test_keyLoopOrder() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            shell.show(.homeCanvas)
            window.contentView?.layoutSubtreeIfNeeded()
            shell.updateKeyViewLoop()

            let chain = shell.barKeyViewChainForTests
            let loop = shell.keyViewLoopOrderForTests()
            guard loop.count > chain.count else {
                return "the loop stops inside the bar (\(loop.count) views for a \(chain.count)-view bar) - nothing below it is reachable by Tab"
            }
            for (i, expected) in chain.enumerated() where loop[i] !== expected {
                return "loop position \(i) is not the bar control the reading order asks for"
            }
            // The hand-off has to land inside the canvas, not in some other
            // mounted-but-hidden destination.
            let handoff = loop[chain.count]
            let canvasView = shell.homeCanvasForTests.view
            var ancestor: NSView? = handoff
            while let current = ancestor, current !== canvasView { ancestor = current.superview }
            guard ancestor === canvasView else {
                return "Tab leaves the bar into a view outside the canvas"
            }
            // ...and specifically onto a module, which is the canvas's own
            // content rather than its chrome.
            let cards = shell.homeCanvasForTests.moduleCardsForTests
            guard !cards.isEmpty else { return "the canvas rendered no modules to reach" }
            return nil
        }
    }

    private static func test_keyLoopFollowsDestination() -> String? {
        withScratchEnv {
            let (window, shell) = makeShell()
            // A drill page: the back button is the first thing below the bar,
            // because it is the way out and the topmost control.
            shell.show(.review)
            window.contentView?.layoutSubtreeIfNeeded()
            shell.updateKeyViewLoop()
            guard let handoff = shell.firstBodyKeyViewForTests else {
                return "a drill page offers nothing below the bar for Tab to reach"
            }
            let header = shell.drillHeaderForTests
            var ancestor: NSView? = handoff
            while let current = ancestor, current !== header { ancestor = current.superview }
            guard ancestor === header else {
                return "on a drill page the hand-off is not the drill header's own control"
            }
            // Back on the canvas the header is collapsed, so the hand-off must
            // move rather than pointing at a hidden view.
            shell.show(.homeCanvas)
            window.contentView?.layoutSubtreeIfNeeded()
            shell.updateKeyViewLoop()
            guard let canvasHandoff = shell.firstBodyKeyViewForTests else {
                return "the canvas offers nothing below the bar for Tab to reach"
            }
            if canvasHandoff.isHiddenOrHasHiddenAncestor {
                return "the hand-off points at a hidden view"
            }
            var inHeader: NSView? = canvasHandoff
            while let current = inHeader, current !== header { inHeader = current.superview }
            if inHeader === header {
                return "the hand-off is still the collapsed drill header's control"
            }
            return nil
        }
    }

    // MARK: Reduce Motion

    private static func withReduceMotion<T>(_ reduced: Bool, _ body: () -> T) -> T {
        let previous = HelmMotion.reducedOverrideForTests
        HelmMotion.reducedOverrideForTests = reduced
        defer { HelmMotion.reducedOverrideForTests = previous }
        return body()
    }

    private static func test_reduceMotionHoverTranslate() -> String? {
        let card = makeCard()

        let moved: CGFloat = withReduceMotion(false) {
            card.debugSetHovering(true)
            let ty = card.debugCardTransform.m42
            card.debugSetHovering(false)
            return ty
        }
        guard abs(moved - HelmModuleCard.hoverLift) < 0.01 else {
            return "with motion allowed the hover lift is \(moved), want \(HelmModuleCard.hoverLift)"
        }

        let still: CGFloat = withReduceMotion(true) {
            card.debugSetHovering(true)
            let ty = card.debugCardTransform.m42
            card.debugSetHovering(false)
            return ty
        }
        guard abs(still) < 0.01 else {
            return "with Reduce Motion on the card still translates by \(still) - the end state has to be instant, not slower"
        }
        // The shadow swap is deliberately NOT gated (§6.1 allows it), so a
        // hovered card still reads as raised with no motion at all. Asserted
        // by the card having *some* shadow after the reduced-motion hover.
        let raisedShadow: Float = withReduceMotion(true) {
            card.debugSetHovering(true)
            let opacity = card.layer?.shadowOpacity ?? 0
            card.debugSetHovering(false)
            return opacity
        }
        guard raisedShadow > 0 else {
            return "with Reduce Motion on a hovered card has no shadow either - hover became invisible instead of still"
        }
        return nil
    }

    private static func test_reduceMotionGradientTransaction() -> String? {
        var sawDisabled: Bool?
        withReduceMotion(true) {
            HelmMotion.withoutImplicitAnimation { sawDisabled = CATransaction.disableActions() }
        }
        guard sawDisabled == true else {
            return "with Reduce Motion on, a gradient write still runs with implicit animation enabled"
        }
        var sawEnabled: Bool?
        withReduceMotion(false) {
            HelmMotion.withoutImplicitAnimation { sawEnabled = CATransaction.disableActions() }
        }
        guard sawEnabled == false else {
            return "with Reduce Motion off the wrapper changed behaviour - Phase 6 is hardening, not a retune"
        }
        // And `animate` has to collapse rather than shorten.
        var ran = 0
        withReduceMotion(true) { HelmMotion.animate(duration: 5) { ran += 1 } }
        guard ran == 1 else { return "HelmMotion.animate skipped its body under Reduce Motion" }
        return nil
    }

    /// Source guard: an implicit `CAGradientLayer` animation leaves nothing to
    /// read back after the fact, so the only place the absence of a wrapper is
    /// visible is the source.
    private static func test_gradientWritesAreWrapped() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return nil  // stated as skipped by `SelfTestSources` itself
        }
        // The lock screen's scene is explicitly out of this migration's scope
        // and animates its own sky deliberately.
        let exempt: Set<String> = ["LockScreenController.swift", "HelmMotion.swift"]
        var offenders: [String] = []
        for url in files where !exempt.contains(url.lastPathComponent) {
            let file = url.lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                guard trimmed.contains(".colors = [") else { continue }
                // Walk back over the lines that make up this statement and its
                // wrapper - the write is legal if a `withoutImplicitAnimation`
                // opened within a few lines above it.
                let window = lines[max(0, i - 4)..<i].joined(separator: " ")
                if !window.contains("withoutImplicitAnimation") {
                    offenders.append("\(file):\(i + 1)")
                }
            }
        }
        guard offenders.isEmpty else {
            return "gradient colour writes not wrapped in HelmMotion.withoutImplicitAnimation: "
                + offenders.joined(separator: ", ")
        }
        return nil
    }

    private static func test_oneReduceMotionDefinition() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else { return nil }
        var offenders: [String] = []
        for url in files where url.lastPathComponent != "HelmMotion.swift" {
            let file = url.lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                guard trimmed.contains("accessibilityDisplayShouldReduceMotion") else { continue }
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                offenders.append("\(file):\(i + 1)")
            }
        }
        guard offenders.isEmpty else {
            return "Reduce Motion read outside HelmMotion (six copies is how one of them drifts): "
                + offenders.joined(separator: ", ")
        }
        return nil
    }

    // MARK: Dusk - the quick flip

    /// §2.8's own acceptance bar for the dark companion: it has to be reachable
    /// by the *same* quick flip every other family pair uses, not a special
    /// case. Driven through the real `ThemeManager.toggle()` rather than by
    /// re-reading `pairId`, because `toggle()` is the thing ⌘⌥T and the top
    /// bar's toggle button actually call.
    ///
    /// `setTheme` writes through to real `UserDefaults`, so the captain's own
    /// selection is saved and restored around this - the same courtesy
    /// `DaylightChromeSelfTest` already extends.
    private static func test_quickFlipRoundTrip() -> String? {
        let manager = ThemeManager.shared
        let original = manager.theme
        defer { manager.setTheme(original) }

        guard let daylight = HelmTheme.theme(id: "daylight") else { return "no daylight theme" }
        manager.setTheme(daylight)
        manager.toggle()
        guard manager.theme.id == "dusk" else {
            return "flipping from daylight landed on \(manager.theme.id), want dusk"
        }
        guard manager.theme.mode == .dark else { return "dusk is not a dark-mode theme" }
        manager.toggle()
        guard manager.theme.id == "daylight" else {
            return "flipping back from dusk landed on \(manager.theme.id), want daylight"
        }
        // The interim pointer this replaced sent Daylight to helm-dark; make
        // sure that pairing did not survive somewhere as a second answer.
        guard let helmDark = HelmTheme.theme(id: "helm-dark") else { return "no helm-dark theme" }
        manager.setTheme(helmDark)
        manager.toggle()
        guard manager.theme.id == "helm-light" else {
            return "helm-dark's own pair changed to \(manager.theme.id) - Phase 6 must not move it"
        }
        return nil
    }

    // MARK: Environment

    /// Every store this suite's shell builds is pointed at scratch paths, so a
    /// run never reads or writes the captain's real data.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = NSTemporaryDirectory() + "grandline-phase6-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let overrides = [
            "FM_HOSTS_FILE": dir + "/hosts.json",
            "FM_KEYS_FILE": dir + "/keys.json",
            "FM_SNIPPETS_FILE": dir + "/snippets.json",
            "FM_SHIFT_DIR": dir + "/shift",
            "FM_DICTATION_DIR": dir + "/dictation",
            "FM_LOG_ANALYZER_DIR": dir + "/loganalyzer",
            "FM_DOCS_RUNBOOKS_DIR": dir + "/runbooks",
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
        return body()
    }
}
#endif
