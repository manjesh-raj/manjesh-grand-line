// Grand Line - native macOS app.
//
// Regression coverage for `FullScreenMenuBarFill` - the captain-reported
// "solid black horizontal band spanning the full width at the very top of the
// window, above the toolbar row", reported three times and fixed on the third
// (`fm/grandline-settings-black-band-real-fix`).
//
// **Read this before changing anything here, because the two previous rounds
// were defeated by exactly the thing this file's shape is designed around.**
// The band is not painted by this app and is not on the Settings page. In a
// full-screen Space macOS hands the window `1512x949` of a `1512x982` display
// and keeps the top 33pt for the menu bar, whose window (layer 24) is opaque
// and solid black while the menu bar is hidden. `#458` and `#461` both looked
// for it in an **off-screen synthetic render** of the Settings page, where
// there is no full-screen Space, no menu bar window and no 33pt strip at all -
// so a clean pixel diff there was never evidence of anything. The measurement
// that settled it is in `docs/history/24-window-and-layout.md`.
//
// **What this suite can and cannot assert, stated rather than implied.** No
// self-test may enter a real full-screen Space (there is no API that does it
// synchronously, and the result would be on the captain's display), and none
// may order a real panel onto a real screen. So the two facts about the
// environment are injected - `isWindowFullScreen` and `screenFrame` - and
// *everything else is real*: a real `NSWindow` from `OffScreenProbe`, the real
// `update()`, the real `NSPanel` it builds, its real level, frame, alpha and
// painted colour, and the real `mouseEntered`/`mouseExited` AppKit delivers to
// the real tracking-area owner. The fabricated screen is placed far off-screen
// so the panel this suite really does create cannot be seen.
//
// The live half - that the band is gone on a real full-screen window, in a
// dark theme and a light one, and that the menu bar still reveals on hover -
// was measured on a launched probe app with `screencapture`, and is recorded
// in the history file rather than here, because it is not reproducible from
// this process.
//
// Window-backed: it mounts a real `NSWindow` and orders a real panel, so it is
// listed in `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: debug builds only.
#if FM_SELFTESTS

import AppKit

enum FullScreenMenuBarFillSelfTest {

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` and AGENTS.md's
        // hermeticity note.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var allOK = true
        for check in [checkStripIsTheGapAboveTheWindow,
                      checkNothingIsFilledOutsideFullScreen,
                      checkTheFillCoversTheStripAboveTheMenuBarWindow,
                      checkThePanelRefusesToBeConstrainedBelowTheMenuBar,
                      checkTheFillTakesThePageGroundAndFollowsTheTheme,
                      checkTheFillYieldsWhileThePointerIsInTheStrip] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "FullScreenMenuBarFillSelfTest: all checks passed"
                    : "FullScreenMenuBarFillSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// Deliberately nowhere near a real display, for the same reason
    /// `OffScreenProbe` exists: this suite builds a genuine `NSPanel` and
    /// orders it in, and a panel at the top of the captain's actual screen
    /// would be a 33pt bar across their menu bar.
    private static let fakeScreen = NSRect(x: -40_000, y: -40_000, width: 1512, height: 982)
    /// What macOS really hands a full-screen window on the captain's machine.
    private static let fakeWindowFrame = NSRect(x: -40_000, y: -40_000, width: 1512, height: 949)
    private static let expectedStripHeight: CGFloat = 33

    private static func mountedFill(fullScreen: Bool) -> (NSWindow, FullScreenMenuBarFill) {
        let window = OffScreenProbe.window(width: fakeWindowFrame.width, height: fakeWindowFrame.height)
        window.setFrame(fakeWindowFrame, display: false)
        let fill = FullScreenMenuBarFill(window: window,
                                         isWindowFullScreen: { _ in fullScreen },
                                         screenFrame: { _ in fakeScreen })
        return (window, fill)
    }

    // MARK: Checks

    /// The geometry on its own, with its discriminating power asserted first:
    /// the two rectangles really do differ by 33pt, so a fixture that drifted
    /// into "window already covers the screen" would fail loudly instead of
    /// passing vacuously.
    private static func checkStripIsTheGapAboveTheWindow(_ ok: inout Bool) {
        check(fakeScreen.maxY - fakeWindowFrame.maxY == expectedStripHeight,
              "fixture is not discriminating: the fabricated screen and window differ by "
              + "\(fakeScreen.maxY - fakeWindowFrame.maxY)pt, not \(expectedStripHeight)pt", &ok)

        let strip = FullScreenMenuBarFill.stripFrame(windowFrame: fakeWindowFrame, screenFrame: fakeScreen)
        check(strip?.height == expectedStripHeight,
              "strip height was \(String(describing: strip?.height)), expected \(expectedStripHeight)", &ok)
        check(strip?.minY == fakeWindowFrame.maxY,
              "the strip must start at the window's top edge, not \(String(describing: strip?.minY))", &ok)
        check(strip?.width == fakeScreen.width,
              "the strip must span the whole screen width", &ok)

        // A display with no reserved strip - an external monitor, or a future
        // macOS that stops reserving one - must produce no panel at all
        // rather than a zero-height window.
        check(FullScreenMenuBarFill.stripFrame(windowFrame: fakeScreen, screenFrame: fakeScreen) == nil,
              "a window that already covers the screen must need no fill", &ok)
        check(FullScreenMenuBarFill.stripFrame(
                windowFrame: fakeScreen.insetBy(dx: 0, dy: -10), screenFrame: fakeScreen) == nil,
              "a window taller than its screen must need no fill", &ok)
    }

    /// The window this app spends most of its life in is not full screen, and
    /// nothing may be ordered onto the menu bar then.
    private static func checkNothingIsFilledOutsideFullScreen(_ ok: inout Bool) {
        autoreleasepool {
            let (window, fill) = mountedFill(fullScreen: false)
            fill.update()
            check(fill.debugPanel == nil,
                  "a window that is not in full screen must have no fill panel", &ok)
            window.close()
        }
    }

    /// The load-bearing measurement, and the one that would silently undo the
    /// fix: the black is the *menu bar's own window* at
    /// `kCGMainMenuWindowLevel` (24), opaque, and a fill below it is invisible.
    /// The first attempt sat at 23 and changed nothing on screen.
    private static func checkTheFillCoversTheStripAboveTheMenuBarWindow(_ ok: inout Bool) {
        autoreleasepool {
            let (window, fill) = mountedFill(fullScreen: true)
            fill.update()
            guard let panel = fill.debugPanel else {
                fail("a full-screen window with a reserved strip must have a fill panel", &ok)
                window.close()
                return
            }
            check(panel.frame == NSRect(x: fakeScreen.minX, y: fakeWindowFrame.maxY,
                                        width: fakeScreen.width, height: expectedStripHeight),
                  "the fill landed at \(panel.frame), not on the reserved strip - AppKit's own "
                  + "`constrainFrameRect` pushes a window below the menu bar unless it is overridden", &ok)
            check(panel.level.rawValue > 24,
                  "the fill is at level \(panel.level.rawValue); the menu bar's own window is an opaque "
                  + "black 24, so anything at or below that is invisible", &ok)
            check(panel.isOpaque && panel.alphaValue == 1,
                  "the fill must actually paint: opaque=\(panel.isOpaque) alpha=\(panel.alphaValue)", &ok)
            window.close()
        }
    }

    /// The second half of the level rule, and the half that is invisible in
    /// the panel's own frame from here: AppKit silently constrains a window
    /// out of the menu bar's strip, and stops doing so only at level 25.
    /// Measured - the same proposal returns one strip-height lower from a
    /// `.titled` window, a borderless window and a borderless panel at 23, and
    /// unchanged from one at 25. The suite's fabricated screen is deliberately
    /// nowhere near a real display, and AppKit only constrains against real
    /// ones, so this asks the real panel the question directly rather than
    /// reading its frame.
    ///
    /// A stock window is measured alongside it, so the day macOS stops
    /// constraining at all this fails as a stale fixture instead of passing
    /// while asserting nothing.
    private static func checkThePanelRefusesToBeConstrainedBelowTheMenuBar(_ ok: inout Bool) {
        guard let screen = NSScreen.main else {
            print("  SKIP no screen attached - nothing constrains a frame on a headless host")
            return
        }
        let overMenuBar = NSRect(x: screen.frame.minX, y: screen.frame.maxY - expectedStripHeight,
                                 width: screen.frame.width, height: expectedStripHeight)
        autoreleasepool {
            let stock = OffScreenProbe.window(width: 200, height: 200)
            check(stock.constrainFrameRect(overMenuBar, to: screen) != overMenuBar,
                  "fixture is not discriminating: AppKit no longer moves a stock window out of the "
                  + "menu bar's strip, so the override below proves nothing", &ok)
            stock.close()

            let (window, fill) = mountedFill(fullScreen: true)
            fill.update()
            guard let panel = fill.debugPanel else {
                fail("no fill panel to ask about constraining", &ok)
                window.close()
                return
            }
            check(panel.constrainFrameRect(overMenuBar, to: screen) == overMenuBar,
                  "AppKit would move the fill panel out of the menu bar's strip "
                  + "(\(panel.constrainFrameRect(overMenuBar, to: screen)) rather than \(overMenuBar)) - "
                  + "its window level is too low to be left alone there", &ok)
            window.close()
        }
    }

    /// It is the page ground, and it repaints on a theme change (GL-24).
    private static func checkTheFillTakesThePageGroundAndFollowsTheTheme(_ ok: inout Bool) {
        autoreleasepool {
            let (window, fill) = mountedFill(fullScreen: true)
            let themes = HelmTheme.allThemes.filter { $0.id == "dusk" || $0.id == "daylight" }
            check(themes.count == 2, "expected both Daylight and Dusk in the palette table", &ok)
            let grounds = Set(themes.map(\.backgroundHex))
            check(grounds.count == 2,
                  "fixture is not discriminating: both themes share the ground \(grounds)", &ok)

            for theme in themes {
                ThemeManager.shared.setTheme(theme)
                fill.update()
                guard let painted = fill.debugPanel?.contentView?.layer?.backgroundColor else {
                    fail("no fill was painted under \(theme.id)", &ok)
                    continue
                }
                let expected = HelmTheme.nsColor(theme.backgroundHex).cgColor
                check(HelmContrast.components(NSColor(cgColor: painted) ?? .black)
                        == HelmContrast.components(NSColor(cgColor: expected) ?? .white),
                      "under \(theme.id) the fill painted \(painted) rather than the page ground "
                      + "\(theme.backgroundHex)", &ok)
            }
            window.close()
        }
    }

    /// Sitting over the menu bar's window is only acceptable because the fill
    /// steps aside the moment the pointer is in the strip - otherwise the band
    /// is gone and the menu bar is unreachable, which is a worse bug than the
    /// one being fixed. Driven through the real AppKit callbacks the tracking
    /// area delivers, not through the private setter behind them.
    private static func checkTheFillYieldsWhileThePointerIsInTheStrip(_ ok: inout Bool) {
        autoreleasepool {
            let (window, fill) = mountedFill(fullScreen: true)
            fill.update()
            guard let panel = fill.debugPanel, let content = fill.debugPanelContentView else {
                fail("no fill panel to drive the hover against", &ok)
                window.close()
                return
            }
            check(panel.alphaValue == 1 && !panel.ignoresMouseEvents,
                  "the settled fill must be painted and must own the strip's pointer", &ok)

            content.mouseEntered(with: hoverEvent())
            check(panel.alphaValue == 0,
                  "with the pointer in the strip the fill must be transparent, not \(panel.alphaValue) - "
                  + "a revealed menu bar renders behind it", &ok)
            check(panel.ignoresMouseEvents,
                  "with the pointer in the strip the fill must pass clicks to the menu bar", &ok)

            content.mouseExited(with: hoverEvent())
            check(panel.alphaValue == 1 && !panel.ignoresMouseEvents,
                  "the fill must come back once the pointer leaves the strip", &ok)
            window.close()
        }
    }

    /// The tracking area's callbacks read nothing off the event, so any mouse
    /// event of the right type is a faithful stand-in for the real one.
    private static func hoverEvent() -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved,
                           location: .zero,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 0,
                           pressure: 0)!
    }
}

#endif
