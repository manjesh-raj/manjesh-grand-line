// Grand Line - native macOS app.
//
// The status pill's one guarantee: **two rows in the same status render the
// same pill**, whatever the theme did while they were being checked.
//
// The captain reported this twice, a day apart, on the two pages that shared
// the defect:
//
//   * GitHub Sync - eight forks, every one of them reporting "In Sync", and
//     four rendering a solid dark-green pill beside four rendering a light,
//     muted green one, all in the same (light) theme. Clicking "Sync" on one
//     of the dark ones flipped just that row to the light treatment while its
//     status text never changed.
//   * Updates - two rows both reading "Update Available", one a light tan
//     pill and the other a solid dark one, while the amber card border the
//     two rows share matched correctly on both.
//
// **This was never two states hiding under one label** - worth stating,
// because that was the first thing to rule out and it would have been the
// worse finding. `GitHubSyncStatus.inSync` and `DependencyStatus
// .updateAvailable` each carry one case with no payload that reaches the
// pill, and `pillVisuals` is a total function of that case, so two rows in
// the same status cannot resolve different hues. The mechanism was time, not
// state:
//
//   1. `ToolRowLayout.pill` resolves a fill and a label tone for **one**
//      specific theme (via `HelmContrast.tintedSurface`) and bakes both into
//      the layer and the label. Nothing re-resolves them afterwards.
//   2. `ToolRowLayout.applyTheme` deliberately never touches the pill - it is
//      passed to `build` as one of `statusViews`, not as part of `Views`' own
//      chrome - so a row's theme pass re-themed its icon, labels, border and
//      accent bar and left the pill alone.
//   3. So the pill was painted only from `render(_:)`, i.e. only when a row's
//      **status** changed. A theme switch left every pill wearing the palette
//      it had last been painted in.
//   4. Each repo's/tool's check completes on its own schedule, so a theme
//      switch part-way through the opening sweep froze the rows that had
//      already reported in the old palette and let the rest land in the new
//      one. Two treatments, one status, one theme - exactly the screenshots.
//
// The fix moves the pill's paint into `applyThemeToRow`, which `render` ends
// by calling: one owner, reached by a status change **and** a theme change.
//
// Why this needs a test rather than a read-through: the fill is a colour on a
// CALayer that nothing ever reads back, so a stale pill renders perfectly -
// it is only wrong *relative to the row beside it*. Every assertion here
// therefore reads what the pill was **actually painted with** rather than
// re-deriving it from the status; a check that re-derives cannot see a drift
// between the painted value and the current theme, which is the entire bug.
//
// Run with:
//   FM_RUN_STATUS_PILL_THEME_TESTS=1 .build/debug/GrandLine
//
// Window-backed (the pages are mounted into a real `NSWindow`), so it sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Neither page's `viewWillAppear` is ever called: both start their real
// `gh`/`brew`/`npm`/`git` sweeps from it, and this suite has no business
// shelling out against the captain's own machine. Mounting a page's *view*
// runs `loadView`, which touches no subprocess.
//
// Theme changes are driven through the **real** `ThemeManager.shared
// .setTheme`, so each page's own `ThemeManager.observe` closure runs exactly
// as it does in the app - the wiring from "the captain pressed the theme
// toggle" to "the pill is repainted" is part of what has to hold, and a
// hand-mirrored `debugApplyTheme` would assert the repaint while leaving that
// wiring untested. `setTheme` persists to the captain's real `fm.themeID`
// (AGENTS.md records that poisoning whole suite runs), so `run()` captures it
// up front and restores it in a `defer` - the convention every Daylight suite
// in this directory already follows.

#if FM_SELFTESTS

import AppKit

enum StatusPillThemeSelfTest {

    static func run() -> Bool {
        // `setTheme` persists to the real `UserDefaults`; put the captain's
        // own selection back before returning.
        let restoreTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restoreTheme) }
        var allOK = true
        for check in [checkGitHubSyncPillsSurviveAThemeSwitch,
                      checkUpdatesPillsSurviveAThemeSwitch,
                      checkSyncingOneRowChangesNoOtherRow,
                      checkOneStatusIsOneTreatmentInEveryTheme] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "StatusPillThemeSelfTest: all checks passed"
                    : "StatusPillThemeSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// A light palette and a dark one - the captain's own "switching between
    /// light and dark mode". Resolved from the real registry rather than
    /// named, so a renamed palette does not silently drop the sweep.
    private static var lightTheme: HelmTheme {
        HelmTheme.allThemes.first { $0.mode == .light } ?? HelmTheme.allThemes[0]
    }

    private static var darkTheme: HelmTheme {
        HelmTheme.allThemes.first { $0.mode == .dark } ?? HelmTheme.allThemes[0]
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: 820)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// Component-wise, deliberately **not** `HelmContrast.ratio(a, b) < 1.01`:
    /// that compares relative *luminance*, so two entirely different hues of
    /// similar brightness pass it. This codebase has walked into that twice.
    private static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    private static func color(_ cg: CGColor?) -> NSColor? {
        cg.map { NSColor(cgColor: $0) } ?? nil
    }

    private static func hex(_ c: NSColor?) -> String {
        guard let c else { return "nil" }
        let (r, g, b) = HelmContrast.components(c)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// What a pill painted **now, in this theme, for this hue** looks like -
    /// the reference every row is measured against. Built through the real
    /// component, so it cannot drift from what the pages paint.
    private static func referencePill(hex colorHex: String, theme: HelmTheme) -> (fill: NSColor?, label: NSColor?) {
        let pill = NSView()
        let label = NSTextField(labelWithString: "")
        ToolRowLayout.pill(text: "reference", colorHex: colorHex, into: pill, label: label, theme: theme)
        return (color(pill.layer?.backgroundColor), label.textColor)
    }

    // MARK: 1 - GitHub Sync: the captain's exact scenario

    /// Half the forks report "In Sync", the theme is switched, the rest
    /// report "In Sync". Pre-fix the first half kept the old palette's pill
    /// for the rest of the session; this asserts all eight now match, and
    /// match a pill painted fresh in the theme that is actually current.
    private static func checkGitHubSyncPillsSurviveAThemeSwitch(_ ok: inout Bool) {
        let controller = GitHubSyncController()
        ThemeManager.shared.setTheme(darkTheme)
        _ = mount(controller)
        ThemeManager.shared.setTheme(darkTheme)

        let count = controller.debugRowCount
        guard count >= 4 else {
            print("StatusPillThemeSelfTest: FAIL - GitHub Sync has only \(count) row(s), too few to split")
            ok = false
            return
        }
        let split = count / 2

        // The opening sweep, half of it landing before the captain's toggle.
        for i in 0..<split { controller.debugSetStatus(.inSync, atRow: i) }

        // The toggle.
        ThemeManager.shared.setTheme(lightTheme)

        // The rest of the sweep reporting afterwards.
        for i in split..<count { controller.debugSetStatus(.inSync, atRow: i) }

        let expected = referencePill(hex: lightTheme.ansiHex[2], theme: lightTheme)
        for i in 0..<count {
            guard let paint = controller.debugPillPaint(atRow: i) else {
                print("StatusPillThemeSelfTest: FAIL - GitHub Sync row \(i) has no pill")
                ok = false
                continue
            }
            guard paint.text == "In Sync" else {
                print("StatusPillThemeSelfTest: FAIL - GitHub Sync row \(i) reads '\(paint.text)', want 'In Sync'")
                ok = false
                continue
            }
            if !sameColor(color(paint.fill), expected.fill) {
                print("StatusPillThemeSelfTest: FAIL - GitHub Sync row \(i) ('In Sync') pill fill is "
                      + "\(hex(color(paint.fill))), but a pill painted now in \(lightTheme.id) is \(hex(expected.fill)) "
                      + "- this row kept the palette it was painted in")
                ok = false
            }
            if !sameColor(paint.label, expected.label) {
                print("StatusPillThemeSelfTest: FAIL - GitHub Sync row \(i) ('In Sync') pill label is "
                      + "\(hex(paint.label)), want \(hex(expected.label))")
                ok = false
            }
        }
        if ok {
            print("StatusPillThemeSelfTest: OK - all \(count) 'In Sync' GitHub Sync pills match one treatment "
                  + "(\(hex(expected.fill)) fill) after a theme switch mid-sweep")
        }
    }

    // MARK: 2 - Updates: the same defect, same shared component

    private static func checkUpdatesPillsSurviveAThemeSwitch(_ ok: inout Bool) {
        let controller = UpdatesController()
        ThemeManager.shared.setTheme(darkTheme)
        _ = mount(controller)
        ThemeManager.shared.setTheme(darkTheme)

        let count = controller.debugRowCount
        guard count >= 4 else {
            print("StatusPillThemeSelfTest: FAIL - Updates has only \(count) row(s), too few to split")
            ok = false
            return
        }
        let split = count / 2

        for i in 0..<split { controller.debugSetStatus(.updateAvailable, atRow: i) }
        ThemeManager.shared.setTheme(lightTheme)
        for i in split..<count { controller.debugSetStatus(.updateAvailable, atRow: i) }

        let expected = referencePill(hex: lightTheme.ansiHex[3], theme: lightTheme)
        for i in 0..<count {
            guard let paint = controller.debugPillPaint(atRow: i) else {
                print("StatusPillThemeSelfTest: FAIL - Updates row \(i) has no pill")
                ok = false
                continue
            }
            guard paint.text == "Update Available" else {
                print("StatusPillThemeSelfTest: FAIL - Updates row \(i) reads '\(paint.text)', want 'Update Available'")
                ok = false
                continue
            }
            if !sameColor(color(paint.fill), expected.fill) {
                print("StatusPillThemeSelfTest: FAIL - Updates row \(i) ('Update Available') pill fill is "
                      + "\(hex(color(paint.fill))), but a pill painted now in \(lightTheme.id) is \(hex(expected.fill))")
                ok = false
            }
            if !sameColor(paint.label, expected.label) {
                print("StatusPillThemeSelfTest: FAIL - Updates row \(i) ('Update Available') pill label is "
                      + "\(hex(paint.label)), want \(hex(expected.label))")
                ok = false
            }
        }
        if ok {
            print("StatusPillThemeSelfTest: OK - all \(count) 'Update Available' Updates pills match one treatment "
                  + "after a theme switch mid-sweep")
        }
    }

    // MARK: 3 - the transition the captain actually clicked

    /// "Clicking Sync on one repo changed that repo's badge." A row going
    /// `.inSync` -> `.syncing` -> `.inSync` must come back to the same pill it
    /// started with, and must not have disturbed any sibling on the way -
    /// which is the honest statement of "no visible badge change other than
    /// what a real state transition would justify".
    private static func checkSyncingOneRowChangesNoOtherRow(_ ok: inout Bool) {
        let controller = GitHubSyncController()
        ThemeManager.shared.setTheme(lightTheme)
        _ = mount(controller)
        ThemeManager.shared.setTheme(lightTheme)

        let count = controller.debugRowCount
        guard count >= 2 else {
            print("StatusPillThemeSelfTest: FAIL - need at least 2 GitHub Sync rows")
            ok = false
            return
        }
        for i in 0..<count { controller.debugSetStatus(.inSync, atRow: i) }

        let before = (0..<count).map { controller.debugPillPaint(atRow: $0) }

        // The row the captain pressed Sync on: busy, then back to in-sync.
        controller.debugSetStatus(.syncing, atRow: 0)
        controller.debugSetStatus(.inSync, atRow: 0)

        for i in 0..<count {
            guard let now = controller.debugPillPaint(atRow: i), let was = before[i] else {
                print("StatusPillThemeSelfTest: FAIL - GitHub Sync row \(i) lost its pill")
                ok = false
                continue
            }
            if !sameColor(color(now.fill), color(was.fill)) || now.text != was.text {
                let which = i == 0 ? "the synced row" : "an untouched sibling row"
                print("StatusPillThemeSelfTest: FAIL - \(which) \(i) changed across a sync: "
                      + "'\(was.text)' \(hex(color(was.fill))) -> '\(now.text)' \(hex(color(now.fill)))")
                ok = false
            }
        }
        if ok {
            print("StatusPillThemeSelfTest: OK - a full sync round trip on one row left every pill "
                  + "(its own included) exactly as it was")
        }
    }

    // MARK: 4 - one status is one treatment, in every palette

    /// The broad sweep: for every registered palette, every row in the same
    /// status paints the same pill, and toggling away and back does not
    /// reintroduce a second variant. This is the half that would catch a
    /// future palette (or a future row-building path) opting out.
    private static func checkOneStatusIsOneTreatmentInEveryTheme(_ ok: inout Bool) {
        let controller = GitHubSyncController()
        ThemeManager.shared.setTheme(lightTheme)
        _ = mount(controller)
        ThemeManager.shared.setTheme(lightTheme)

        let count = controller.debugRowCount
        guard count >= 2 else {
            print("StatusPillThemeSelfTest: FAIL - need at least 2 GitHub Sync rows")
            ok = false
            return
        }

        for theme in HelmTheme.allThemes {
            // Stagger the rows across the switch again, so each palette is
            // entered with rows painted in the *previous* one.
            controller.debugSetStatus(.inSync, atRow: 0)
            ThemeManager.shared.setTheme(theme)
            for i in 1..<count { controller.debugSetStatus(.inSync, atRow: i) }

            let expected = referencePill(hex: theme.ansiHex[2], theme: theme)
            var mismatched: [Int] = []
            for i in 0..<count {
                guard let paint = controller.debugPillPaint(atRow: i) else { continue }
                if !sameColor(color(paint.fill), expected.fill) || !sameColor(paint.label, expected.label) {
                    mismatched.append(i)
                }
            }
            if !mismatched.isEmpty {
                print("StatusPillThemeSelfTest: FAIL - \(theme.id): row(s) \(mismatched) render a different "
                      + "'In Sync' pill than the \(hex(expected.fill)) one this palette resolves")
                ok = false
            }
        }
        if ok {
            print("StatusPillThemeSelfTest: OK - one 'In Sync' treatment per palette across all "
                  + "\(HelmTheme.allThemes.count) themes")
        }
    }
}

#endif
