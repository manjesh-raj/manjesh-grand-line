// Grand Line - native macOS app.
//
// `fm/grandline-layout-breaks-refresh-reply`: two layout breaks the captain
// reported, and the backstop for the class one of them belongs to.
//
// Run with `FM_RUN_LAYOUT_STABILITY_TESTS=1 .build/debug/GrandLine`.
//
//   1. **Reply never widens the window** and **3. Home holds its layout
//      through a refresh** measured the floating bar's Overview composer and
//      Home dashboard. P-03 of the 2026-11-25 review removed that layout, and
//      the sidebar's Home and Crew reply card do not draw either, so those
//      cases went with it.
//   2. **A widened window does not outlive its page.** `WindowOverflowGuard`
//      puts back a window that content pushed past its screen, on the next
//      navigation. Asserted with a deliberately over-wide view, because the
//      composer no longer produces the state.
//
// **Why this suite is window-backed.** Every case reads resolved frames from
// the real shell in a real (off-screen) window, and it needs the window
// ordered in: AppKit only re-derives a window's frame
// from its content's constraints while it is on the window list, which is the
// growth case 2 must produce. Listed in
// `NEEDS_SESSION` in `Scripts/run-all-tests.sh`. No run-loop pumps, posted
// events, modal alerts or drag sessions: every click is `performClick` and
// every state is read synchronously after `layoutSubtreeIfNeeded`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum LayoutStabilitySelfTest {

    /// An unbroken line: no space anywhere a word wrap could use.
    /// `PageRedesignsSelfTest` uses it for the sidebar's reply card.
    static let unbrokenNote = "https://127.0.0.1:4387/session/"
        + String(repeating: "76371d2d67d88839", count: 36)

    @discardableResult
    static func run() -> Bool {
        var ok = true
        let savedTheme = ThemeManager.shared.theme
        let savedBriefing = AppSettings.shared.morningBriefingRecord
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-stability-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.morningBriefingRecord = savedBriefing
            FleetActions.stateDirectoryOverrideForTests = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        if let daylight = HelmTheme.theme(id: "daylight") { ThemeManager.shared.setTheme(daylight) }

        checkTheGuardArithmetic(&ok)
        autoreleasepool {
            let (window, shell) = ReviewTourLab.makeOffScreenShell()
            defer { window.orderOut(nil) }
            window.orderFront(nil)
            shell.workspace.navigator.show(.homeCanvas)
            ReviewTourLab.seedDemoHome(shell.debugHomeCanvas)
            ReviewTourLab.seedDemoBriefing()

            checkTheGuardRestoresAWidenedWindow(shell: shell, window: window, &ok)
        }

        print(ok ? "LayoutStabilitySelfTest: all checks passed" : "LayoutStabilitySelfTest: FAILED")
        return ok
    }

    private static func resize(_ window: NSWindow, to size: NSSize, shell: MainSplitShellController) {
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: false)
        settle(window, shell)
    }

    /// The shell's layout pass and then the window's own. AppKit re-derives
    /// the window's frame from its content in the second one, so a suite that
    /// ran only the first would never see the window grow - measured: the
    /// over-wide fixture below left the window at 960pt until
    /// `window.layoutIfNeeded()` ran, and then it was 2000pt.
    private static func settle(_ window: NSWindow, _ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
    }

    // MARK: 1. Reply never widens the window

    // MARK: 2. A widened window does not outlive its page

    private static func checkTheGuardArithmetic(_ ok: inout Bool) {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 945)
        check(!WindowOverflowGuard.overflows(NSRect(x: 0, y: 0, width: 1512.4, height: 900), visible: screen),
              "guard: a window as wide as its screen is not overflow", &ok)
        check(WindowOverflowGuard.overflows(NSRect(x: 0, y: 0, width: 1746, height: 900), visible: screen),
              "guard: a window wider than its screen is overflow", &ok)
        let back = WindowOverflowGuard.restoredFrame(current: NSRect(x: 100, y: 40, width: 1746, height: 900),
                                                     lastFitting: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                                     visible: screen)
        check(back == NSRect(x: 100, y: 40, width: 1200, height: 900),
              "guard: restores the last fitting width and keeps the current top-left and height (\(back))", &ok)
        let clamped = WindowOverflowGuard.restoredFrame(current: NSRect(x: 600, y: 40, width: 1746, height: 900),
                                                        lastFitting: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                                        visible: screen)
        check(clamped.maxX <= screen.maxX && clamped.width == 1200,
              "guard: moves a restored window left until it ends inside the screen (\(clamped))", &ok)
        let fallback = WindowOverflowGuard.restoredFrame(current: NSRect(x: 0, y: 40, width: 1746, height: 900),
                                                         lastFitting: nil, visible: screen)
        check(fallback.width == screen.width,
              "guard: with no fitting frame on record it restores the screen's width (\(fallback.width))", &ok)
    }

    private static func checkTheGuardRestoresAWidenedWindow(shell: MainSplitShellController, window: NSWindow,
                                                           _ ok: inout Bool) {
        let guardrail = shell.workspace.windowOverflowGuard
        let savedVisible = guardrail.visibleFrame
        defer {
            guardrail.visibleFrame = savedVisible
            guardrail.disarmForTests()
        }
        // An `OffScreenProbe` window is on no screen, so the guard is handed a
        // 1512pt one at the window's own parked origin.
        guardrail.visibleFrame = { NSRect(x: $0.frame.minX, y: $0.frame.minY, width: 1512, height: 945) }
        check(!guardrail.isArmed, "guard: a shell a suite mounts does not arm the guard on its own", &ok)

        resize(window, to: NSSize(width: 1000, height: 620), shell: shell)
        resize(window, to: NSSize(width: 960, height: 620), shell: shell)
        guardrail.arm(for: window)
        shell.workspace.navigator.show(.overview)
        settle(window, shell)

        // A view that makes the same mistake the composer's label made: a
        // required width wider than the screen, inside the showing page.
        let wide = NSView()
        wide.translatesAutoresizingMaskIntoConstraints = false
        shell.debugOverview.view.addSubview(wide)
        NSLayoutConstraint.activate([
            wide.leadingAnchor.constraint(equalTo: shell.debugOverview.view.leadingAnchor),
            wide.topAnchor.constraint(equalTo: shell.debugOverview.view.topAnchor),
            wide.trailingAnchor.constraint(lessThanOrEqualTo: shell.debugOverview.view.trailingAnchor),
            wide.widthAnchor.constraint(equalToConstant: 2000),
            wide.heightAnchor.constraint(equalToConstant: 1),
        ])
        settle(window, shell)
        // The fixture's own power: AppKit really grew the window.
        check(window.frame.width >= 2000 - 0.5,
              "guard: the over-wide view grows the window, as the composer's label did (\(window.frame.width))", &ok)

        wide.removeFromSuperview()
        settle(window, shell)
        shell.workspace.navigator.show(.homeCanvas)
        settle(window, shell)
        check(abs(window.frame.width - 960) < 0.5,
              "guard: navigating away puts the window back at its last fitting 960pt (got \(window.frame.width))", &ok)
    }
}

#endif
