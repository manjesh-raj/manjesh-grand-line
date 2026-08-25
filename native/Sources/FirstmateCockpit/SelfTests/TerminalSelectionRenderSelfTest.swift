// Manjesh Grand Line - native macOS app.
//
// Console's terminal text selection, measured from **real rendered pixels**
// (`fm/grandline-console-selection-contrast-followup`).
//
// Why this suite exists rather than another colour-value check: PR #283 audited
// every theme's `selectionHex` / `selectionTextHex` pair and every one of them
// measured well clear of 4.5:1 - and the captain's Console selection was still
// illegible afterwards, on the Herdr tab specifically, while the Shell tab
// beside it was fine. No assertion over palette *values* could have caught that,
// because in the Herdr tab those values were never being read at all:
//
//   A `herdr session attach` client enables mouse capture (`?1002h` / `?1006h`,
//   both present in the herdr binary; herdr also ships `mouse_capture` and
//   `copy_on_select` config keys). SwiftTerm's `mouseDown` / `mouseDragged`
//   hand every drag straight to the child whenever
//   `allowMouseReporting && terminal.mouseMode != .off`, and never build a
//   selection of their own - so what the captain saw highlighted was herdr's
//   own selection, painted from herdr's own fixed dark theme (its documented
//   default is `selection_bg = "#313244"`, a dark navy) with no knowledge of
//   which of this app's 14 themes is active. A plain Shell tab enables no mouse
//   mode, so the identical drag there goes down SwiftTerm's own selection path
//   and comes out in the theme's colours.
//
// So every case here drives a **real `CockpitTerminalView` in a real window**,
// feeds it real bytes, synthesizes a **real click-drag**, renders with
// `cacheDisplay` and reads the pixels back. What is asserted is what a
// screenshot would show, not what a constant says.
//
//   1. The Shell reference: mouse mode off, a drag paints `selectionHex`
//      behind `selectionTextHex`. Swept over all 14 themes.
//   2. The Herdr case: mouse mode on. With `prefersLocalSelection` (the shipped
//      configuration for a mirror tab) the rendered pixels are byte-identical
//      to case 1; with it off - i.e. the pre-fix behaviour - the same drag
//      paints **no selection at all**. That second half is what makes this a
//      real regression guard rather than a test that merely passes.
//   3. That pair clears 4.5:1 in every theme - measured from the palette, not
//      from the captured pixels, and case 3's own comment records why that is
//      the honest way round here.
//   4. Nothing herdr can do with the mouse is lost: a plain *click* is still
//      reported to the child, a *Shift*-drag is still reported to the child,
//      and only an unmodified drag is kept locally.
//   5. Source guard: a mirror tab is the thing that opts in.
//
// Run with:
//   swift build && FM_RUN_TERMINAL_SELECTION_RENDER_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum TerminalSelectionRenderSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkShellTabPaintsTheThemeSelection,
                      checkMirrorTabMatchesTheShellTab,
                      checkPaintedPairClearsTheTextFloor,
                      checkHerdrKeepsItsMouse,
                      checkMirrorTabsOptIn] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "TerminalSelectionRenderSelfTest: all checks passed"
                    : "TerminalSelectionRenderSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// The DECSET pair a real `herdr session attach` client sends - both
    /// literals are present in the herdr binary.
    private static let mouseCaptureOn = "\u{1b}[?1002h\u{1b}[?1006h"

    /// Twelve full rows of ordinary text, so every sampled row has glyphs on it
    /// and the "which colour is the ink" question has an answer.
    private static let content: String = (0..<12)
        .map { "row \($0) selection legibility check " + String(repeating: "M", count: 40) }
        .joined(separator: "\r\n")

    private static let size = NSSize(width: 820, height: 420)

    private struct Render {
        /// The colour covering most of a selected row: a large flat area, so
        /// this is an exact reading of what the selection fill painted.
        var fill: NSColor
        /// How far the darkest/lightest glyph pixel on a selected row travels
        /// from `fill` towards the theme's declared `selectionTextHex`, as a
        /// fraction of that segment. Text is antialiased, so no pixel reaches
        /// the nominal ink exactly - but every glyph pixel lies *on the segment
        /// between the two*, and how far along it goes is a faithful, tolerant
        /// statement of "the ink in use is that one".
        var inkBlend: Double
        /// The largest distance any sampled glyph colour sat *off* that
        /// segment. A different ink would show up here, not in `inkBlend`.
        var inkResidual: Double
        /// How many rows the fill covers, i.e. did a selection happen at all.
        var filledRows: Int
        var repSpace: NSColorSpace
    }

    private static func theme(_ id: String) -> HelmTheme? {
        HelmTheme.allThemes.first { $0.id == id }
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func fail(_ ok: inout Bool, _ message: String) {
        print("  FAIL: \(message)")
        ok = false
    }

    private static func hex(_ c: NSColor) -> String {
        String(format: "%02X%02X%02X",
               Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// Build a real window + terminal, feed it, drag across it, and read the
    /// pixels back. `body` sees the view before the drag so a case can assert
    /// on it, and the recorded child bytes come back with the render.
    @discardableResult
    private static func renderDrag(theme: HelmTheme,
                                   mouseCapture: Bool,
                                   localSelection: Bool,
                                   shiftHeld: Bool = false,
                                   clickOnly: Bool = false,
                                   sentBytes: inout [UInt8]) -> Render? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = CockpitTerminalView(frame: NSRect(origin: .zero, size: size))
        view.sentToChildForTests = []
        view.prefersLocalSelection = localSelection
        // A deliberately large glyph: text is drawn antialiased, so at a normal
        // UI size almost no pixel reaches the nominal ink colour and a
        // pixel-measured contrast would systematically under-report. Big
        // strokes give a real, solid glyph core to sample.
        view.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .regular)
        window.contentView = view
        theme.apply(to: view)
        view.layoutSubtreeIfNeeded()
        // AGENTS.md's probe rule: a SwiftTerm view never calls `draw(_:)` in a
        // window that was never ordered front, so an off-screen capture of one
        // comes back empty and looks exactly like a rendering bug.
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        if mouseCapture { view.feed(text: mouseCaptureOn) }
        view.feed(text: content)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        view.sentToChildForTests = []

        let flags: NSEvent.ModifierFlags = shiftHeld ? [.shift] : []
        func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let from = NSPoint(x: 10, y: size.height * 0.95)
        let to = NSPoint(x: size.width - 10, y: size.height * 0.55)
        if let e = ev(.leftMouseDown, from) { view.mouseDown(with: e) }
        if !clickOnly {
            // A real drag emits motion from the press point onwards, and
            // SwiftTerm seeds its selection anchor from the first motion event
            // it is given - so the first one has to be at the press point or
            // the two paths under test would anchor differently.
            for p in [from, NSPoint(x: size.width / 2, y: (from.y + to.y) / 2), to] {
                if let e = ev(.leftMouseDragged, p) { view.mouseDragged(with: e) }
            }
        }
        if let e = ev(.leftMouseUp, clickOnly ? from : to) { view.mouseUp(with: e) }
        view.needsDisplay = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        sentBytes = view.sentToChildForTests ?? []

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        window.contentView = nil

        // Per-terminal-row histograms. A row the drag selected has the
        // selection fill as its dominant colour; every other row has the page
        // background. That distinction - rather than "the biggest block of one
        // colour anywhere" - is what makes `filledRows == 0` mean "nothing was
        // selected" instead of "the page is mostly empty".
        // Compared with a tolerance, never by an exact hex string: inside a
        // real window `bitmapImageRepForCachingDisplay` hands back a rep in the
        // *display's* profile, so a converted palette colour lands a channel
        // step or two away from the pixel it painted (AGENTS.md's probe rule).
        let pageBG = HelmTheme.nsColor(theme.backgroundHex).usingColorSpace(rep.colorSpace)
        func isPageBG(_ c: NSColor) -> Bool {
            guard let pageBG else { return false }
            return abs(c.redComponent - pageBG.redComponent) < 0.03
                && abs(c.greenComponent - pageBG.greenComponent) < 0.03
                && abs(c.blueComponent - pageBG.blueComponent) < 0.03
        }
        let rows = max(1, Int(view.getTerminal().rows))
        let cellH = Double(rep.pixelsHigh) / Double(rows)
        var selectedRowCounts: [String: (NSColor, Int)] = [:]
        var dominantOfSelectedRows: [String: Int] = [:]
        var colourByKey: [String: NSColor] = [:]
        var filledRows = 0
        for row in 0..<rows {
            let top = Int(Double(row) * cellH) + 2
            let bottom = Int(Double(row + 1) * cellH) - 2
            guard bottom > top else { continue }
            var counts: [String: (NSColor, Int)] = [:]
            var y = top
            while y < min(rep.pixelsHigh, bottom) {
                var x = 0
                while x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y) {
                        let k = hex(c)
                        counts[k] = (c, (counts[k]?.1 ?? 0) + 1)
                        colourByKey[k] = c
                    }
                    x += 2
                }
                y += 1
            }
            guard let dominant = counts.max(by: { $0.value.1 < $1.value.1 }) else { continue }
            guard !isPageBG(dominant.value.0) else { continue }
            filledRows += 1
            dominantOfSelectedRows[dominant.key, default: 0] += 1
            for (k, v) in counts {
                selectedRowCounts[k] = (v.0, (selectedRowCounts[k]?.1 ?? 0) + v.1)
            }
        }
        guard filledRows > 0,
              let fillKey = dominantOfSelectedRows.max(by: { $0.value < $1.value })?.key,
              let fill = colourByKey[fillKey] else {
            // Nothing was selected: report the page's own colours so a caller
            // can still see what it got, with `filledRows == 0` saying why.
            return Render(fill: pageBG ?? .black, inkBlend: 0, inkResidual: 0,
                          filledRows: 0, repSpace: rep.colorSpace)
        }
        // Where the glyphs sit. Text is drawn antialiased, so the honest
        // question is not "is any pixel exactly `selectionTextHex`" - at a
        // normal size none is - but "are the glyph pixels blends of the fill
        // and *that* ink". Every sampled colour is projected onto the segment
        // from the drawn fill to the declared ink: `inkBlend` is how far the
        // furthest one travels, `inkResidual` how far the worst one strays off
        // it. A different ink would strand them off the segment.
        let declaredInk = HelmTheme.nsColor(theme.selectionTextHex).usingColorSpace(rep.colorSpace)
        var inkBlend = 0.0
        var inkResidual = 0.0
        if let declaredInk {
            let f = (Double(fill.redComponent), Double(fill.greenComponent), Double(fill.blueComponent))
            let d = (Double(declaredInk.redComponent) - f.0,
                     Double(declaredInk.greenComponent) - f.1,
                     Double(declaredInk.blueComponent) - f.2)
            let dd = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
            let totalSelected = selectedRowCounts.values.reduce(0) { $0 + $1.1 }
            let floor = max(8, totalSelected / 4000)
            for (key, entry) in selectedRowCounts where key != fillKey && entry.1 >= floor {
                guard !isPageBG(entry.0), dd > 0 else { continue }
                let v = (Double(entry.0.redComponent) - f.0,
                         Double(entry.0.greenComponent) - f.1,
                         Double(entry.0.blueComponent) - f.2)
                let t = max(0, min(1, (v.0 * d.0 + v.1 * d.1 + v.2 * d.2) / dd))
                let r = ((v.0 - t * d.0), (v.1 - t * d.1), (v.2 - t * d.2))
                let residual = (r.0 * r.0 + r.1 * r.1 + r.2 * r.2).squareRoot()
                if residual > inkResidual { inkResidual = residual }
                if t > inkBlend { inkBlend = t }
            }
        }
        return Render(fill: fill, inkBlend: inkBlend, inkResidual: inkResidual,
                      filledRows: filledRows, repSpace: rep.colorSpace)
    }

    /// Same-colour test done the only way that is safe here: element-wise in
    /// the rep's own colour space. A luminance comparison is NOT a colour
    /// comparison - two different hues of similar brightness pass it, which has
    /// already bitten two suites in this codebase.
    private static func matches(_ sampled: NSColor, _ expectedHex: String, in space: NSColorSpace) -> Bool {
        guard let expected = HelmTheme.nsColor(expectedHex).usingColorSpace(space) else { return false }
        return abs(sampled.redComponent - expected.redComponent) < 0.03
            && abs(sampled.greenComponent - expected.greenComponent) < 0.03
            && abs(sampled.blueComponent - expected.blueComponent) < 0.03
    }

    // MARK: 1 - the Shell reference

    private static func checkShellTabPaintsTheThemeSelection(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: a Shell tab's drag paints the theme's selection pair")
        for theme in HelmTheme.allThemes {
            var sent: [UInt8] = []
            guard let r = renderDrag(theme: theme, mouseCapture: false, localSelection: false,
                                     sentBytes: &sent) else {
                fail(&ok, "\(theme.id): nothing rendered")
                continue
            }
            if r.filledRows < 3 {
                fail(&ok, "\(theme.id): the drag painted only \(r.filledRows) selected row(s)")
            }
            if !matches(r.fill, theme.selectionHex, in: r.repSpace) {
                fail(&ok, "\(theme.id): drawn fill \(hex(r.fill)) is not selectionHex \(theme.selectionHex)")
            }
            if r.inkBlend < 0.7 {
                fail(&ok, "\(theme.id): glyphs only travel \(fmt(r.inkBlend)) of the way to selectionTextHex \(theme.selectionTextHex)")
            }
            if r.inkResidual > 0.08 {
                fail(&ok, "\(theme.id): glyph colours sit \(fmt(r.inkResidual)) off the fill->selectionTextHex segment - a different ink is being drawn")
            }
        }
        if ok { print("  all \(HelmTheme.allThemes.count) themes paint selectionHex behind selectionTextHex") }
    }

    // MARK: 2 - the Herdr case, and the regression it replaces

    private static func checkMirrorTabMatchesTheShellTab(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: a mirror tab's drag renders identically to a Shell tab's")
        // Both registers, because the reported symptom was light-mode-specific
        // and a dark theme can hide a wrong fill.
        for id in ["helm-light", "helm-dark", "daylight", "dusk"] {
            guard let theme = theme(id) else { fail(&ok, "\(id) not found"); continue }
            var sent: [UInt8] = []
            guard let shell = renderDrag(theme: theme, mouseCapture: false, localSelection: false,
                                         sentBytes: &sent) else {
                fail(&ok, "\(id): shell reference did not render"); continue
            }
            // The shipped configuration for a mirror tab.
            guard let mirror = renderDrag(theme: theme, mouseCapture: true, localSelection: true,
                                          sentBytes: &sent) else {
                fail(&ok, "\(id): mirror render failed"); continue
            }
            if hex(mirror.fill) != hex(shell.fill) || abs(mirror.inkBlend - shell.inkBlend) > 0.02 {
                fail(&ok, "\(id): mirror drew \(hex(mirror.fill)) ink-blend \(fmt(mirror.inkBlend)), shell drew \(hex(shell.fill)) ink-blend \(fmt(shell.inkBlend))")
            }
            if mirror.filledRows < 3 {
                fail(&ok, "\(id): mirror painted only \(mirror.filledRows) selected row(s)")
            }
            // The pre-fix behaviour, asserted rather than described: with the
            // opt-in off, mouse capture swallows the drag and nothing is
            // selected. If this ever stops being true the fix has become a
            // no-op and case 2's pass above means nothing.
            var ignored: [UInt8] = []
            guard let unfixed = renderDrag(theme: theme, mouseCapture: true, localSelection: false,
                                           sentBytes: &ignored) else {
                fail(&ok, "\(id): unfixed render failed"); continue
            }
            if unfixed.filledRows != 0 || matches(unfixed.fill, theme.selectionHex, in: unfixed.repSpace) {
                fail(&ok, "\(id): mouse capture no longer swallows the drag - this suite can no longer tell the fix from its absence")
            }
        }
        if ok { print("  mirror == shell with the opt-in on; nothing selected with it off") }
    }

    // MARK: 3 - the pair that reaches the screen is the guarded pair

    /// Case 1 proves *which* colours a drag paints; this closes the loop by
    /// measuring that exact pair against the text floor.
    ///
    /// Deliberately measured from the palette rather than from the captured
    /// pixels, and the reason is worth recording so nobody "improves" it back:
    /// inside a real window `bitmapImageRepForCachingDisplay` hands back a rep
    /// in the display's own profile, and that conversion is **not losslessly
    /// invertible** - measured here, `helm-light`'s `007194` fill comes back
    /// through `usingColorSpace(.sRGB)` as `3C82A2`, several steps lighter,
    /// which drags a genuinely 5.38:1 pair down to a false 4.13:1. A tolerant
    /// identity check in the rep's *own* space (case 1) is reliable; an
    /// absolute WCAG number derived from those same pixels is not.
    private static func checkPaintedPairClearsTheTextFloor(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: the pair a drag paints clears 4.5:1 in every theme")
        for theme in HelmTheme.allThemes {
            let ratio = HelmContrast.ratio(HelmTheme.nsColor(theme.selectionTextHex),
                                           HelmTheme.nsColor(theme.selectionHex))
            if ratio < 4.5 {
                fail(&ok, "\(theme.id): selectionTextHex on selectionHex measures \(fmt(ratio)):1 (floor 4.50)")
            }
        }
        if ok { print("  every theme's painted selection pair clears the text floor") }
    }

    // MARK: 4 - herdr keeps its mouse

    private static func checkHerdrKeepsItsMouse(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: a mirror tab still reports clicks and Shift-drags to the child")
        guard let theme = theme("helm-light") else { fail(&ok, "helm-light not found"); return }

        var clickBytes: [UInt8] = []
        _ = renderDrag(theme: theme, mouseCapture: true, localSelection: true,
                       clickOnly: true, sentBytes: &clickBytes)
        if clickBytes.isEmpty {
            fail(&ok, "a plain click reported nothing to the child - herdr's own click targets would stop working")
        }

        var shiftBytes: [UInt8] = []
        let shiftDrag = renderDrag(theme: theme, mouseCapture: true, localSelection: true,
                                   shiftHeld: true, sentBytes: &shiftBytes)
        if shiftBytes.isEmpty {
            fail(&ok, "a Shift-drag reported nothing to the child - herdr's own drag gestures would be unreachable")
        }
        if let shiftDrag, shiftDrag.filledRows != 0 {
            fail(&ok, "a Shift-drag also painted a local selection - it is meant to be forwarded instead")
        }

        var dragBytes: [UInt8] = []
        _ = renderDrag(theme: theme, mouseCapture: true, localSelection: true, sentBytes: &dragBytes)
        if !dragBytes.isEmpty {
            fail(&ok, "an unmodified drag reported \(dragBytes.count) byte(s) to the child - it should be kept locally, so herdr never draws a second selection under ours")
        }
        if ok { print("  click reported, Shift-drag reported, plain drag kept local") }
    }

    // MARK: 5 - source guard

    private static func checkMirrorTabsOptIn(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: a mirror tab is what opts into local selection")
        let path = SelfTestSources.appSourceDirectory()?
            .appendingPathComponent("ConsoleController+Tabs.swift")
        guard let path, let text = try? String(contentsOf: path, encoding: .utf8) else {
            print("  SKIP: app sources not reachable from here")
            return
        }
        if !text.contains("if case .mirror = launch { term.prefersLocalSelection = true }") {
            fail(&ok, "ConsoleController+Tabs.swift no longer opts a mirror tab into local selection")
        }
        if ok { print("  addTab opts .mirror in") }
    }
}

#endif
