// Grand Line - native macOS app.
//
// The window-backed half of universal capture (F2 of full review #3 §8):
// the real ⌥Space panel, built by the real controller, driven by real
// ⌘1-⌘5 key equivalents and real tile clicks, and rendered off-screen in
// both registers.
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
        }

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
            capture.window?.orderOut(nil)
        }
    }

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

    // MARK: ⌘1-⌘5

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
            for id in ["dusk", "daylight"] {
                guard let palette = HelmTheme.theme(id: id) else {
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
            guard tiles.count == 5 else { return }
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
            func pixel(_ rect: NSRect) -> NSColor? {
                let x = Int(rect.midX * scaleX)
                // `bitmapImageRepForCachingDisplay` is top-left origin; the
                // view is not flipped, so the row has to be mirrored.
                let y = Int((root.bounds.height - rect.midY) * scaleY)
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
                return rep.colorAt(x: x, y: y)
            }
            guard let selectedPixel = pixel(selected), let neighbourPixel = pixel(neighbour) else {
                check(false, "could not sample both tiles")
                return
            }
            let a = HelmContrast.components(selectedPixel)
            let b = HelmContrast.components(neighbourPixel)
            let delta = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
            check(delta > 0.01,
                  "the default tile's wash really paints - sampled \(a) against \(b), delta \(String(format: "%.4f", delta))")
        }
    }
}

#endif
