// Grand Line - native macOS app.
//
// The window-backed half of universal capture (F2 of full review #3 §8):
// the real ⌥Space panel, built by the real controller, driven by real
// ⌘1-⌘6 key equivalents and real tile clicks, and rendered off-screen in
// both registers.
//
// **CP-1, the hero head** (the hero restyle board, the captain's pick) is
// measured here too, in Lavender and Powder: the head's quiet-ink gradient,
// the field on the hero's dark shade (its typed words and placeholder against
// the lighter stop, with the white wash the board rejected shown to fail),
// the chips on the gradient, the lit tile following Return's default and the
// crew's pick, the confirmation taking the head (and holding still under
// Reduce Motion), the hint naming every chord, and the gradient reaching a
// real bitmap.
//
// **Why this is `NEEDS_SESSION` even though it builds no `OffScreenProbe`
// window.** `ShiftQuickCaptureController` constructs its own `NSPanel` - the
// same shape as `UnifiedSearchLayoutSelfTest` and `AuditSecurityLockSelfTest`,
// and exactly what `E2ETestingPolicySelfTest.mountsAWindow` cannot see, since
// its markers look for `OffScreenProbe.window(`/`NSWindow(contentRect` in the
// *suite's* own source. Hence the `# session-not-window:` marker on this
// suite's entry in `Scripts/run-all-tests.sh`, which is the per-entry escape
// hatch AGENTS.md describes rather than a blanket exemption.
//
// **The panel is never ordered in.** `present()` activates the app and makes
// the panel key, which on the captain's own machine puts a real floating
// window over whatever they are doing. Everything here drives the controller's
// own API and the panel's own responder path instead, and the one render goes
// through `cacheDisplay` into an off-screen bitmap.
//
// **The theme is saved and restored.** `Phase3PolishSelfTest.checkSuitesRestore
// TheTheme` enforces the necessary condition, and AGENTS.md records what an
// unrestored `fm.themeID` costs the next unrelated run.
//
// `FM_RUN_CAPTURE_ROUTER_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CaptureRouterViewSelfTest {

    /// What a panel under test filed, in order.
    private final class Recorder {
        var filed: [(CaptureDestination, CaptureDraft)] = []
        var outcome: CaptureFilingOutcome = .filed(.task)

        func filer() -> CaptureFiler {
            CaptureFiler { [weak self] destination, draft in
                self?.filed.append((destination, draft))
                switch self?.outcome ?? .filed(.task) {
                case .filed: return .filed(destination)
                case .handedOff: return .handedOff(destination)
                case .refused(let why): return .refused(why)
                }
            }
        }
    }

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        autoreleasepool {
            checkTilesMatchTheReport(check)
            checkChordKeyEquivalentsFile(check)
            checkTileClicksFile(check)
            checkEmptyCaptureFilesNothing(check)
            checkRefusalKeepsThePanelOpen(check)
            checkCrewRouting(check)
            checkChipsTrackTheText(check)
            checkTilesAreLegibleInBothRegisters(check)
            checkTheSelectedTileReallyPaints(check)
            checkCapsLockDoesNotKillTheChords(check)
            checkTheHeadIsAHero(check)
            checkTheHeadFollowsTheTheme(check)
            checkTheLightFollowsTheDefault(check)
            checkTheConfirmationTakesTheHead(check)
            checkTheHintNamesEveryChord(check)
        }
        check(!panelWasShown, "a case put the capture panel on screen")

        print(ok ? "CaptureRouterViewSelfTest: OK" : "CaptureRouterViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Fixture

    private static func withPanel(_ body: (ShiftQuickCaptureController, Recorder) -> Void) {
        autoreleasepool {
            let recorder = Recorder()
            let capture = ShiftQuickCaptureController(filer: recorder.filer())
            // Force `loadView`'s equivalent - the panel builds its content in
            // `init`, but the frame is only real after a layout pass.
            capture.window?.contentView?.layoutSubtreeIfNeeded()
            body(capture, recorder)
            // The panel is a real `.floating` `NSPanel`; nothing here may
            // order it in over the captain's own screen.
            if capture.window?.isVisible == true { panelWasShown = true }
            capture.window?.orderOut(nil)
        }
    }

    /// Set by `withPanel` if any case left the panel visible.
    private static var panelWasShown = false

    // MARK: The tiles

    private static func checkTilesMatchTheReport(_ check: (Bool, String) -> Void) {
        withPanel { capture, _ in
            let tiles = capture.debugTiles
            // Six since `fm/grandline-feature-f4-reading-list` appended
            // `.link` (F4), which is ⌘6.
            check(tiles.count == 6, "six tiles are built, found \(tiles.count)")
            guard tiles.count == 6 else { return }
            let order: [CaptureDestination] = [.task, .sticky, .note, .credential, .codeSnippet, .link]
            for (index, expected) in order.enumerated() {
                check(tiles[index].destination == expected,
                      "tile \(index + 1) is \(expected.rawValue), got \(tiles[index].destination.rawValue)")
            }
            // Return's default is drawn, not only documented.
            check(tiles[0].isDefault, "the Task tile is drawn as the default")
            check(!tiles.dropFirst().contains { $0.isDefault },
                  "exactly one tile is the default")
        }
    }

    // MARK: ⌘1-⌘6

    /// A real command-modified digit, dispatched through the real root view's
    /// `performKeyEquivalent` - the same path AppKit uses while the field
    /// editor has focus, which is the only time these are ever pressed.
    private static func commandDigit(_ digit: Int) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: .command,
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: "\(digit)",
                         charactersIgnoringModifiers: "\(digit)",
                         isARepeat: false,
                         keyCode: 0)
    }

    private static func checkChordKeyEquivalentsFile(_ check: (Bool, String) -> Void) {
        withPanel { capture, recorder in
            guard let root = capture.debugRootView else {
                check(false, "the panel's root view is not a CaptureRootView")
                return
            }
            capture.debugSetText("rotate the RaaS deploy key")

            let expected: [(Int, CaptureDestination)] = [
                (1, .task), (2, .sticky), (3, .note), (4, .credential), (5, .codeSnippet),
                // `fm/grandline-feature-f4-reading-list` (F4) appended `.link`
                // as ⌘6. A URL is the one capture that needs no parse to know
                // where it belongs, and before F4 it became a task titled with
                // a URL.
                (6, .link),
            ]
            for (digit, destination) in expected {
                recorder.filed.removeAll()
                // Each chord is its own presentation: a filed capture holds
                // its confirmation and takes no second file until the panel
                // opens again.
                capture.debugResetHead()
                guard let event = commandDigit(digit) else {
                    check(false, "could not synthesise \u{2318}\(digit)")
                    continue
                }
                let handled = root.performKeyEquivalent(with: event)
                check(handled, "\u{2318}\(digit) is handled by the panel")
                check(recorder.filed.count == 1,
                      "\u{2318}\(digit) files exactly once, filed \(recorder.filed.count)")
                check(recorder.filed.first?.0 == destination,
                      "\u{2318}\(digit) files to \(destination.rawValue), got \(String(describing: recorder.filed.first?.0))")
                check(recorder.filed.first?.1.title == "rotate the RaaS deploy key",
                      "the draft reaching the store carries the typed text")
            }

            // The discriminating half: a digit the router does not own must
            // fall through, or the panel would swallow it (and, worse, ⌘W).
            // ⌘7 since F4 took ⌘6.
            recorder.filed.removeAll()
            if let seven = commandDigit(7) {
                check(!root.performKeyEquivalent(with: seven), "\u{2318}7 is not swallowed")
                check(recorder.filed.isEmpty, "\u{2318}7 files nothing")
            }
        }
    }

    private static func checkTileClicksFile(_ check: (Bool, String) -> Void) {
        withPanel { capture, recorder in
            capture.debugSetText("kubectl -n raas get pods")
            for tile in capture.debugTiles {
                recorder.filed.removeAll()
                capture.debugResetHead()
                // The tile's own accessibility press - the same action a real
                // click and a real Space keypress both run (GL-16).
                _ = tile.accessibilityPerformPress()
                check(recorder.filed.first?.0 == tile.destination,
                      "clicking the \(tile.destination.title) tile files to it, got \(String(describing: recorder.filed.first?.0))")
            }
        }
    }

    private static func checkEmptyCaptureFilesNothing(_ check: (Bool, String) -> Void) {
        withPanel { capture, recorder in
            capture.debugSetText("   \n ")
            capture.file(to: .task)
            check(recorder.filed.isEmpty, "an empty capture files nothing, filed \(recorder.filed.count)")
            _ = capture.debugTiles[2].accessibilityPerformPress()
            check(recorder.filed.isEmpty, "an empty capture files nothing via a tile either")
        }
    }

    private static func checkRefusalKeepsThePanelOpen(_ check: (Bool, String) -> Void) {
        withPanel { capture, recorder in
            recorder.outcome = .refused("the vault is locked")
            capture.debugSetText("hunter2")
            capture.file(to: .credential)
            check(capture.debugStatusText == "the vault is locked",
                  "a refusal is shown, got \(String(describing: capture.debugStatusText))")
            // The typed text must survive a refusal - it is the whole point of
            // not dismissing.
            check(capture.debugInputField.stringValue == "hunter2",
                  "a refusal leaves the capture intact, got \(capture.debugInputField.stringValue)")
        }
    }

    // MARK: The crew

    private static func checkCrewRouting(_ check: (Bool, String) -> Void) {
        withPanel { capture, recorder in
            capture.classifier = { _, done in done(.note) }
            capture.debugSetText("A paragraph of prose worth keeping.")
            capture.debugAskTheCrew()
            check(recorder.filed.first?.0 == .note,
                  "the crew's answer is what gets filed, got \(String(describing: recorder.filed.first?.0))")
            check(capture.debugTiles.first(where: { $0.isDefault })?.destination == .note,
                  "the crew's answer becomes the highlighted tile")
            check(capture.debugTiles.filter(\.debugIsLit).map(\.destination) == [.note],
                  "CP-1: the light moved to the crew's pick before it filed, lit \(capture.debugTiles.filter(\.debugIsLit).map(\.destination))")
            check(capture.debugVerdictText == CaptureDestination.note.confirmation,
                  "the crew's file is confirmed in the head, got \(String(describing: capture.debugVerdictText))")
        }

        withPanel { capture, recorder in
            // The crew's pick is refused: the light goes back to the tile
            // Return files to, so it never points somewhere Return will not.
            recorder.outcome = .refused("the vault is locked")
            capture.classifier = { _, done in done(.credential) }
            capture.debugSetText("A paragraph of prose worth keeping.")
            capture.debugAskTheCrew()
            let lit = capture.debugTiles.filter(\.debugIsLit).map(\.destination)
            check(recorder.filed.first?.0 == .credential, "the refused crew pick was tried")
            check(lit == [.task], "a refused crew pick hands the light back to Return's tile, lit \(lit)")
            check(capture.debugStatusText == "the vault is locked" && capture.debugStatusIsError,
                  "the refusal is the body's error line, got \(String(describing: capture.debugStatusText))")
        }

        withPanel { capture, recorder in
            // GL-14's shape: "the crew could not say" is not "file it as a
            // task". Nothing is written and the captain is told.
            capture.classifier = { _, done in done(nil) }
            capture.debugSetText("something ambiguous")
            capture.debugAskTheCrew()
            check(recorder.filed.isEmpty,
                  "an unparseable crew answer files nothing, filed \(recorder.filed.count)")
            check(capture.debugStatusText?.isEmpty == false,
                  "an unparseable crew answer says so, got \(String(describing: capture.debugStatusText))")
        }
    }

    // MARK: The chips

    private static func checkChipsTrackTheText(_ check: (Bool, String) -> Void) {
        withPanel { capture, _ in
            capture.debugSetText("kubectl -n raas get pods")
            check(capture.debugDateChipText == nil,
                  "no date chip for text with no date, got \(String(describing: capture.debugDateChipText))")

            capture.debugSetText("review the deploy notes tomorrow 3pm")
            let chip = capture.debugDateChipText
            check(chip != nil, "a parsed date is shown as a chip")
            check(chip?.contains("3:00") == true || chip?.contains("3 PM") == true || chip?.contains("3:00 PM") == true,
                  "the chip names the parsed time, got \(String(describing: chip))")
        }
    }

    // MARK: Both registers

    private static func checkTilesAreLegibleInBothRegisters(_ check: (Bool, String) -> Void) {
        withPanel { capture, _ in
            for id in ["dusk", "daylight", "lavender", "powder"] {
                guard let palette = HelmTheme.theme(id: id) ?? HelmTheme.appTheme(id: id) else {
                    check(false, "theme \(id) is not a real palette any more - fixture is stale")
                    continue
                }
                ThemeManager.shared.setTheme(palette)
                let theme = ThemeManager.shared.theme
                for tile in capture.debugTiles {
                    let ratio = HelmContrast.ratio(tile.debugNameColor, tile.debugFillColor(under: theme))
                    check(ratio >= 4.5,
                          "\(id): the \(tile.destination.title) tile's label clears 4.5:1 on its own fill, measured \(String(format: "%.2f", ratio))")
                }
            }
        }
    }

    /// One real render, per AGENTS.md's "assert what is painted, not what was
    /// computed": the selected tile's wash has to actually reach the bitmap.
    private static func checkTheSelectedTileReallyPaints(_ check: (Bool, String) -> Void) {
        withPanel { capture, _ in
            guard let dusk = HelmTheme.theme(id: "dusk") else {
                check(false, "dusk is not a real palette any more - fixture is stale")
                return
            }
            ThemeManager.shared.setTheme(dusk)
            guard let root = capture.window?.contentView else {
                check(false, "the panel has no content view to render")
                return
            }
            root.layoutSubtreeIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                check(false, "could not build a bitmap rep for the capture panel")
                return
            }
            root.cacheDisplay(in: root.bounds, to: rep)

            let tiles = capture.debugTiles
            // This guard read `== 5` from F2 until CP-1, so once F4 appended
            // Link the whole render check returned before asserting anything.
            // It is a failure now, not a silent return.
            guard tiles.count == CaptureDestination.allCases.count else {
                check(false, "\(tiles.count) tiles for \(CaptureDestination.allCases.count) destinations")
                return
            }
            // The fixture's own discriminating power first: the two tiles have
            // to be somewhere real and distinct, or "their pixels differ" is
            // vacuous.
            let selected = tiles[0].convert(tiles[0].bounds, to: root)
            let neighbour = tiles[1].convert(tiles[1].bounds, to: root)
            check(selected.width > 40 && selected.height > 30,
                  "the selected tile has a real frame, got \(selected)")
            check(!selected.intersects(neighbour), "the two sampled tiles do not overlap")

            // `rep.colorSpace`, never a `.sRGB` conversion - AGENTS.md's
            // hard-won probe rule.
            // **The rep is in *pixels*, not points**, and on a retina machine
            // that is a factor of two - sampling point coordinates directly
            // lands in the top-left quadrant of the panel, which is chrome
            // rather than either tile, and reports two identical background
            // pixels. Measured, not reasoned: the first version of this check
            // failed with delta 0.0000 for exactly that reason.
            let scaleX = CGFloat(rep.pixelsWide) / root.bounds.width
            let scaleY = CGFloat(rep.pixelsHigh) / root.bounds.height
            // 4pt in from the leading edge, half way down: inside the rounded
            // surface and clear of the glyph, the name and the keycap.
            func pixel(_ rect: NSRect) -> (Double, Double, Double)? {
                let x = Int((rect.minX + 4) * scaleX)
                // `bitmapImageRepForCachingDisplay` is top-left origin; the
                // view is not flipped, so the row has to be mirrored.
                let y = Int((root.bounds.height - rect.midY) * scaleY)
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let c = rep.colorAt(x: x, y: y) else { return nil }
                // The raw components are already in the rep's space; only the
                // expected colour is converted (AGENTS.md's probe rules).
                return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
            }
            func inRep(_ color: NSColor) -> (Double, Double, Double) {
                let c = color.usingColorSpace(rep.colorSpace) ?? color
                return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
            }
            func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
                abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
            }
            let head = capture.debugHeadView.convert(capture.debugHeadView.bounds, to: root)
            guard let selectedPixel = pixel(selected), let neighbourPixel = pixel(neighbour),
                  let headPixel = pixel(head) else {
                check(false, "could not sample both tiles and the head")
                return
            }
            let card = inRep(HelmTheme.nsColor(dusk.chromeBackgroundHex))
            let start = inRep(HelmContrast.color(ShiftQuickCaptureController.palette(in: dusk).start))
            check(distance(neighbourPixel, card) < 0.03,
                  "an unlit tile is the card, sampled \(neighbourPixel) against \(card)")
            check(distance(selectedPixel, card) > 0.3 && distance(selectedPixel, start) < 0.25,
                  "CP-1: the default tile's gradient really paints, sampled \(selectedPixel) against the start stop \(start)")
            check(distance(headPixel, start) < 0.25,
                  "CP-1: the head's gradient really paints, sampled \(headPixel) against the start stop \(start)")
        }
    }

    // MARK: Gotcha (21)

    /// A command digit with Caps Lock on - and one from the keypad - still
    /// files. The root view compared `.deviceIndependentFlagsMask` against
    /// `.command`, which those ambient flags make unequal.
    private static func checkCapsLockDoesNotKillTheChords(_ check: (Bool, String) -> Void) {
        withPanel { capture, recorder in
            guard let root = capture.debugRootView else { return }
            capture.debugSetText("rotate the RaaS deploy key")
            for (name, flags) in [("Caps Lock", NSEvent.ModifierFlags([.command, .capsLock])),
                                  ("the keypad", NSEvent.ModifierFlags([.command, .numericPad]))] {
                recorder.filed.removeAll()
                capture.debugResetHead()
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "2", charactersIgnoringModifiers: "2",
                                                   isARepeat: false, keyCode: 0) else { continue }
                check(root.performKeyEquivalent(with: event) && recorder.filed.first?.0 == .sticky,
                      "\u{2318}2 with \(name) still files to Sticky, got \(String(describing: recorder.filed.first?.0))")
            }
            // The discriminating half: ⌘⌥2 is a different chord and must fall through.
            recorder.filed.removeAll()
            capture.debugResetHead()
            if let other = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                            timestamp: 0, windowNumber: 0, context: nil, characters: "2",
                                            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 0) {
                check(!root.performKeyEquivalent(with: other) && recorder.filed.isEmpty,
                      "\u{2318}\u{2325}2 is not a capture chord")
            }
        }
    }

    // MARK: CP-1 - the hero head

    /// `color` laid over an opaque `backdrop`, as alpha compositing does it.
    private static func over(_ color: NSColor, _ backdrop: (Double, Double, Double)) -> (Double, Double, Double) {
        HelmContrast.mix(HelmContrast.components(color), backdrop, Double(color.alphaComponent))
    }

    private static func same(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    private static func ratio(_ r: Double) -> String { String(format: "%.2f", r) }

    private static func checkTheHeadIsAHero(_ check: (Bool, String) -> Void) {
        for id in ["lavender", "powder"] {
            guard let theme = HelmTheme.appTheme(id: id) else {
                check(false, "\(id) is not an app theme any more - the fixture is stale")
                continue
            }
            ThemeManager.shared.setTheme(theme)
            withPanel { capture, _ in
                let palette = ShiftQuickCaptureController.palette(in: theme)
                let lighter = palette.lighterStop
                let ink = HelmContrast.color(palette.ink)
                check(capture.debugHeadPalette == palette, "\(id): the head is not the quiet-ink hero palette")
                let stops = capture.debugHeadGradient.compactMap { NSColor(cgColor: $0) }
                check(stops.count == 2 && same(stops.first, HelmContrast.color(palette.start))
                        && same(stops.last, HelmContrast.color(palette.end)),
                      "\(id): the head's gradient layer does not paint the palette's two stops")
                let title = HelmContrast.ratio(HelmContrast.components(capture.debugTitleColor ?? .clear), lighter)
                check(title >= HelmContrast.textTarget, "\(id): \"Capture\" is \(ratio(title)):1 on the lighter stop")

                // The field: the hero's ink on its dark shade.
                let field = capture.debugInputField
                check(field.heroInk.map { same($0, ink) } == true, "\(id): the field is not in the hero's ink")
                let well = field.chromeView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } ?? .clear
                let wellOnHero = over(well, lighter)
                let typed = HelmContrast.ratio(HelmContrast.components(field.debugEditor.textColor ?? .clear), wellOnHero)
                let placeholder = HelmContrast.ratio(
                    HelmContrast.mix(palette.ink, wellOnHero, Double(HelmSearchField.heroPlaceholderAlpha)), wellOnHero)
                check(HelmContrast.relativeLuminance(wellOnHero) < HelmContrast.relativeLuminance(lighter),
                      "\(id): the field's well lifts the gradient instead of shading it")
                check(typed >= HelmContrast.textTarget, "\(id): typed words are \(ratio(typed)):1 on the field")
                check(placeholder >= HelmContrast.textTarget,
                      "\(id): the placeholder is \(ratio(placeholder)):1 on the field")
                // The fixture's discriminating power: the white wash the board
                // measured and rejected really does fail here.
                let wash = HelmContrast.mix((1, 1, 1), lighter, 0.14)
                check(HelmContrast.ratio(palette.ink, wash) < HelmContrast.textTarget,
                      "\(id): fixture - a 14% white wash should fail the floor, it measured \(ratio(HelmContrast.ratio(palette.ink, wash))):1")

                // The chips on the gradient.
                capture.debugSetText("review the deploy notes tomorrow 3pm")
                for chip in capture.debugChips where !chip.isHidden {
                    let fill = chip.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } ?? .clear
                    let r = HelmContrast.ratio(HelmContrast.components(chip.debugTextColor ?? .clear), over(fill, lighter))
                    check(r >= HelmContrast.textTarget, "\(id): a chip's words are \(ratio(r)):1 on the gradient")
                }
                check(capture.debugHotkeyText == AppSettings.shared.quickCaptureShortcut.displayString,
                      "\(id): the head's chord reads \(capture.debugHotkeyText)")
                print("  \(id): title \(ratio(title)):1, typed \(ratio(typed)):1, placeholder \(ratio(placeholder)):1")
            }
        }
    }

    /// The panel observes the theme: the head repaints in the new register.
    private static func checkTheHeadFollowsTheTheme(_ check: (Bool, String) -> Void) {
        guard let lavender = HelmTheme.appTheme(id: "lavender"),
              let powder = HelmTheme.appTheme(id: "powder") else { return }
        ThemeManager.shared.setTheme(lavender)
        withPanel { capture, _ in
            ThemeManager.shared.setTheme(powder)
            let want = ShiftQuickCaptureController.palette(in: powder)
            check(want != ShiftQuickCaptureController.palette(in: lavender), "fixture: the two registers share a palette")
            check(capture.debugHeadPalette == want, "a theme change left the head in the old register")
            check(capture.debugTiles.first(where: \.isDefault).map { $0.debugFillColor(under: powder) }
                    .map { same($0, HelmContrast.color(want.lighterStop)) } == true,
                  "a theme change left the lit tile in the old register")
        }
    }

    /// One lit tile, and it is the one Return files to.
    private static func checkTheLightFollowsTheDefault(_ check: (Bool, String) -> Void) {
        withPanel { capture, _ in
            func lit() -> [CaptureDestination] { capture.debugTiles.filter(\.debugIsLit).map(\.destination) }
            capture.debugSetText("")
            check(lit() == [.task], "an empty capture lights Task, lit \(lit())")
            capture.debugSetText("https://developer.apple.com/design/")
            let urlDefault = CaptureRouter.defaultDestination(for: CaptureRouter.draft(from: "https://developer.apple.com/design/"))
            check(urlDefault == .link, "fixture: a bare URL should default to Link, got \(urlDefault)")
            check(lit() == [urlDefault], "a URL lights \(urlDefault), lit \(lit())")
            check(capture.debugTiles.filter { !$0.debugIsLit }.allSatisfy { $0.debugGlassTileHidden },
                  "an unlit tile still shows the glass tile")
            capture.debugSetText("review the deploy notes")
            check(lit() == [.task], "prose lights Task again, lit \(lit())")
        }
    }

    /// A filed capture's confirmation takes the head, at once under Reduce
    /// Motion, and the panel takes no second file while it stands.
    private static func checkTheConfirmationTakesTheHead(_ check: (Bool, String) -> Void) {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        withPanel { capture, recorder in
            capture.debugSetText("review the deploy notes")
            let headHeight = capture.debugHeadView.frame.height
            capture.debugPressReturn()
            check(recorder.filed.count == 1, "Return filed \(recorder.filed.count) times")
            check(capture.debugVerdictText == CaptureDestination.task.confirmation,
                  "the head says \(String(describing: capture.debugVerdictText))")
            check(capture.debugHeadContentAlpha == 0 && capture.debugVerdictAlpha == 1,
                  "under Reduce Motion the swap is immediate, head \(capture.debugHeadContentAlpha) verdict \(capture.debugVerdictAlpha)")
            check(capture.debugStatusText == nil, "a filed capture still shows a status line")
            capture.window?.contentView?.layoutSubtreeIfNeeded()
            check(abs(capture.debugHeadView.frame.height - headHeight) < 0.5,
                  "the confirmation changed the head's height from \(headHeight) to \(capture.debugHeadView.frame.height)")
            // A second Return inside the confirmation's 0.9s.
            capture.debugPressReturn()
            check(recorder.filed.count == 1, "a second Return during the confirmation filed again (\(recorder.filed.count))")
        }
    }

    private static func checkTheHintNamesEveryChord(_ check: (Bool, String) -> Void) {
        withPanel { capture, _ in
            check(capture.debugHintText == CaptureHeroWords.hint, "the panel shows \(capture.debugHintText)")
            let last = "\u{2318}\(CaptureDestination.allCases.count)"
            check(capture.debugHintText.contains(last), "the hint does not reach \(last)")
            check(capture.debugTiles.last.map { $0.debugChordCap.text == last } == true,
                  "the last tile's keycap and the hint disagree")
        }
    }
}

#endif
