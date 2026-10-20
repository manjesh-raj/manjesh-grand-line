// Grand Line - native macOS app.
//
// P7 of the Grand Line vs Automic Vault polish report: Increase Contrast and
// Reduce Transparency, read through `HelmDisplayAccessibility`.
//
// What is asserted is what is painted - the layer colours a real
// `applyTheme` leaves behind - in both states of each setting, through the
// helper's test overrides (there is no API to set the system setting). The
// live half - that a change reaches views nobody re-themed - is driven by
// posting the notification on `NSWorkspace`'s own center, which is where
// macOS posts it.
//
// Run with:
//   swift build && FM_RUN_DISPLAY_ACCESSIBILITY_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: the bar is checked inside a real shell. Listed in
// `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DisplayAccessibilitySelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var ok = true
        let captainTheme = ThemeManager.shared.theme
        defer {
            HelmDisplayAccessibility.increaseContrastOverrideForTests = nil
            HelmDisplayAccessibility.reduceTransparencyOverrideForTests = nil
            ThemeManager.shared.setTheme(captainTheme)
        }
        checkIncreaseContrastStrengthensEveryEdge(&ok)
        checkReduceTransparencyDropsTheBarMaterial(&ok)
        checkAChangeReachesMountedViews(&ok)
        checkNothingObservesTheDefaultCenter(&ok)
        print(ok ? "DisplayAccessibilitySelfTest: all checks passed" : "DisplayAccessibilitySelfTest: FAILED")
        return ok
    }

    // MARK: Increase Contrast

    /// An edge's contrast against the surface it sits on, compositing its
    /// alpha first - a 60% line is not the same edge as a 100% one.
    private static func edgeRatio(_ edge: NSColor, over surface: NSColor) -> Double {
        let e = edge.usingColorSpace(.sRGB) ?? edge
        let s = surface.usingColorSpace(.sRGB) ?? surface
        let a = e.alphaComponent
        let mix = (Double(s.redComponent * (1 - a) + e.redComponent * a),
                   Double(s.greenComponent * (1 - a) + e.greenComponent * a),
                   Double(s.blueComponent * (1 - a) + e.blueComponent * a))
        return HelmContrast.ratio(mix, (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)))
    }

    private static func checkIncreaseContrastStrengthensEveryEdge(_ ok: inout Bool) {
        print("\n-- P7: Increase Contrast strengthens the shared edges in every palette --")
        var weaker: [String] = []
        var swept = 0
        for theme in HelmTheme.allThemes {
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            func edges() -> [(String, NSColor)] {
                let card = NSView()
                HelmCard.applyCardSurface(to: card, theme: theme)
                let cardEdge = card.layer?.borderColor.flatMap(NSColor.init(cgColor:)) ?? .clear
                return [("card", cardEdge),
                        ("field", HelmField.border(theme)),
                        ("side panel", HelmTheme.sidePanelEdge(theme))]
            }
            HelmDisplayAccessibility.increaseContrastOverrideForTests = false
            let normal = edges()
            HelmDisplayAccessibility.increaseContrastOverrideForTests = true
            let strong = edges()
            for ((name, before), (_, after)) in zip(normal, strong) {
                swept += 1
                let r0 = edgeRatio(before, over: surface), r1 = edgeRatio(after, over: surface)
                if !(r1 > r0 + 0.05) || after.alphaComponent < 0.999 {
                    weaker.append("\(theme.id) \(name) \(String(format: "%.2f -> %.2f", r0, r1))")
                }
            }
        }
        HelmDisplayAccessibility.increaseContrastOverrideForTests = nil
        check(swept == HelmTheme.allThemes.count * 3 && swept > 30, "swept only \(swept) edges", &ok)
        check(weaker.isEmpty, "edges not strengthened under Increase Contrast: \(weaker.prefix(6))", &ok)
        if weaker.isEmpty { print("  OK   \(swept) edges stronger and opaque across \(HelmTheme.allThemes.count) palettes") }
    }

    // MARK: Reduce Transparency

    private static func checkReduceTransparencyDropsTheBarMaterial(_ ok: inout Bool) {
        print("\n-- P7: the Workspace chrome has no translucency to reduce --")
        // UX-01/UX-12 retired the floating bar and its `.withinWindow`
        // material. The sidebar and the content column now paint opaque Helm
        // fills (see `WorkspaceSidebar.swift`), so Reduce Transparency has
        // nothing left to drop: the property worth holding is that both stay
        // opaque with the setting off and on.
        guard let daylight = HelmTheme.theme(id: "daylight") else { return fail("no `daylight` theme", &ok) }
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        ThemeManager.shared.setTheme(daylight)
        for reduced in [false, true] {
            HelmDisplayAccessibility.reduceTransparencyOverrideForTests = reduced
            ThemeManager.shared.reapplyCurrentTheme()
            let sidebarAlpha = shell.sidebar.view.layer?.backgroundColor?.alpha ?? 0
            let contentAlpha = shell.contentPane.layer?.backgroundColor?.alpha ?? 0
            check(sidebarAlpha > 0.999, "the sidebar's fill is not opaque (reduce transparency \(reduced))", &ok)
            check(contentAlpha > 0.999, "the content column's fill is not opaque (reduce transparency \(reduced))", &ok)
        }
        HelmDisplayAccessibility.reduceTransparencyOverrideForTests = nil
        ThemeManager.shared.reapplyCurrentTheme()
        if ok { print("  OK   sidebar and content column opaque with Reduce Transparency off and on") }
    }

    // MARK: The live path

    /// The setting changes underneath a card nobody re-themes: only the
    /// notification can reach it. Posted on `NSWorkspace`'s own center,
    /// which is the one macOS uses.
    private static func checkAChangeReachesMountedViews(_ ok: inout Bool) {
        print("\n-- P7: a display-options change repaints mounted views --")
        func edge(_ color: CGColor?) -> [Double] {
            let c = HelmContrast.components(color.flatMap(NSColor.init(cgColor:)) ?? .clear)
            let alpha = Double(color?.alpha ?? 0)
            return [c.0, c.1, c.2, alpha].map { ($0 * 1000).rounded() / 1000 }
        }
        HelmDisplayAccessibility.increaseContrastOverrideForTests = false
        defer { HelmDisplayAccessibility.increaseContrastOverrideForTests = nil }
        // A module card observes the theme itself, as every card on Home does.
        let card = HelmModuleCard()
        let before = edge(card.debugSurfaceBorderColor)

        HelmDisplayAccessibility.increaseContrastOverrideForTests = true
        let probe = NSView()
        HelmCard.applyCardSurface(to: probe, theme: ThemeManager.shared.theme)
        let expected = edge(probe.layer?.borderColor)
        // Discriminating power: the two states really paint different edges,
        // and nothing has repainted the mounted card yet.
        check(expected != before, "Increase Contrast paints the same card edge - this proves nothing", &ok)
        check(edge(card.debugSurfaceBorderColor) == before, "the card repainted before any notification", &ok)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        check(edge(card.debugSurfaceBorderColor) == expected,
              "a mounted card did not repaint its edge when the display options changed", &ok)
        withExtendedLifetime(card) {}
        if ok { print("  OK   a mounted card's edge repainted from the NSWorkspace notification alone") }
    }

    /// The notification only ever arrives on `NSWorkspace`'s center, so an
    /// observer on the default center is dead code that looks like wiring.
    /// That shipped once (the dictation HUD's Reduce Motion pulse).
    private static func checkNothingObservesTheDefaultCenter(_ ok: inout Bool) {
        print("\n-- P7: no observer of the display options sits on the default center --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("  SKIP could not find the app's sources")
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var offenders: [String] = []
        var observed = 0
        for name in files where name.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("accessibilityDisplayOptionsDidChangeNotification") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                observed += 1
                let window = lines[max(0, index - 2)...index].joined(separator: "\n")
                if window.contains("NotificationCenter.default") { offenders.append("\(name):\(index + 1)") }
            }
        }
        check(observed >= 2, "found only \(observed) uses of the notification - the guard would be vacuous", &ok)
        check(offenders.isEmpty, "observing the display options on the default center, where it never arrives: \(offenders)", &ok)
        if offenders.isEmpty && observed >= 2 { print("  OK   \(observed) uses, all on NSWorkspace's center") }
    }
}

#endif
