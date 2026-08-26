// Manjesh Grand Line - native macOS app.
//
// Console's terminal text selection, measured from **real rendered pixels**.
//
// History, because it explains what this file does and does not cover now.
// PR #283 audited every theme's `selectionHex` / `selectionTextHex` pair and
// every one measured well clear of 4.5:1 - and a Console selection was still
// illegible afterwards, on the herdr-attached "Mirror" tab specifically, while
// the plain Shell tab beside it was fine. No assertion over palette *values*
// could have caught that, because in that tab those values were never read at
// all: an attached multiplexer client enables mouse capture, SwiftTerm's
// `mouseDown`/`mouseDragged` then hand every drag straight to the child and
// never build a selection of their own, and what was highlighted was the
// multiplexer's own fixed dark theme. `fm/grandline-console-selection-contrast-followup`
// fixed that by *routing* an unmodified drag back to SwiftTerm's own selection,
// and this suite was written to prove it with pixels.
//
// `fm/grand-line-remove-firstmate-mirror` (PR #293) then removed the Mirror tab
// outright, so that routing mechanism, its opt-in and its
// `sentToChildForTests` hook went with it - and this whole file was deleted as
// "dead code". **That deleted more than it needed to**: the suite's first case
// never had anything to do with herdr. It is the plain Shell tab's own
// selection, rendered for real, in every theme - the only pixel-level guard in
// this codebase that the theme's selection pair actually reaches the screen
// rather than merely existing in the palette. `fm/grand-line-shell-selection-investigate-fix`
// restored exactly that half.
//
// That investigation also measured what the removal had left unmitigated, and
// the captain's decision on it is what cases 3-5 now guard:
// `fm/grand-line-shell-tab-local-selection` re-scoped the same *routing* to
// `.shell` tabs. A local shell's tab keeps an unmodified drag for its own
// theme-coloured selection even when the program inside it has enabled mouse
// capture; Shift+drag forwards the gesture to that program. `.ssh` tabs are
// deliberately untouched - see `CockpitTerminalView.prefersLocalSelection`.
//
// So every rendering case here drives a **real `CockpitTerminalView` in a real
// window**, feeds it real bytes, synthesizes a **real click-drag**, renders
// with `cacheDisplay` and reads the pixels back. What is asserted is what a
// screenshot would show, not what a constant says.
//
//   1. A Shell tab's drag paints `selectionHex` behind `selectionTextHex`,
//      swept over all of `HelmTheme.allThemes`.
//   2. That pair clears 4.5:1 in every theme - measured from the palette, not
//      from the captured pixels, and case 2's own comment records why that is
//      the honest way round here.
//   3. With a **mouse-reporting child**, an opted-in tab renders byte-identically
//      to case 1; with the opt-in off - i.e. the pre-fix behaviour - the same
//      drag paints **no selection at all**. That second half is what makes this
//      a real regression guard rather than a case that merely passes.
//   4. Nothing the child can do with the mouse is lost: a plain *click* is still
//      reported to it, a *Shift*-drag is still reported to it, and only an
//      unmodified drag is kept locally.
//   5. Source guard: `.shell` is what opts in, and `.ssh` does not.
//   6. `fm/grandline-console-selection-overlay-sidebar`: a click's own
//      sub-pixel hand-tremor jitter must still be reported to the child, and
//      must not paint a local selection of its own -
//      `CockpitTerminalView.localSelectionDragThreshold`'s doc comment has
//      the mechanism. AppKit calls `mouseDragged` for essentially any
//      movement while the button is held, with no built-in click-vs-drag
//      hysteresis; with none added here, the smallest jitter during an
//      ordinary click over a mouse-reporting child (herdr's own row-switcher
//      is the reported case) silently ate the click - needing a second,
//      steadier click to reach the child - and could paint the app's own
//      themed selection colour over part of the child's own on-screen UI,
//      which read as a highlight "bleeding" past where it should stop.
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
                      checkPaintedPairClearsTheTextFloor,
                      checkMouseReportingChildStillSelectsLocally,
                      checkChildKeepsItsMouse,
                      checkShellTabsOptIn,
                      checkClickJitterDoesNotEatTheClickOrBleedTheSelection] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "TerminalSelectionRenderSelfTest: all checks passed"
                    : "TerminalSelectionRenderSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// The DECSET pair a real mouse-capturing TUI sends - vim, Claude Code,
    /// tmux and `herdr` all enable this pair (`?1002` button-event tracking,
    /// `?1006` SGR extended coordinates).
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
    /// pixels back.
    private static func renderDrag(theme: HelmTheme,
                                   mouseCapture: Bool = false,
                                   localSelection: Bool = true,
                                   shiftHeld: Bool = false,
                                   clickOnly: Bool = false,
                                   jitter: Bool = false,
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

        func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: shiftHeld ? [.shift] : [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let from = NSPoint(x: 10, y: size.height * 0.95)
        let to = NSPoint(x: size.width - 10, y: size.height * 0.55)
        // A couple of points in either direction - the shape of ordinary
        // hand/trackpad tremor during a stationary click, not a deliberate
        // drag-to-select. Well under `CockpitTerminalView`'s default
        // threshold, so `jitter` proves the *fixed* gesture is still a click.
        let jitterPoint = NSPoint(x: from.x + 1.5, y: from.y - 1.0)
        if let e = ev(.leftMouseDown, from) { view.mouseDown(with: e) }
        if jitter {
            if let e = ev(.leftMouseDragged, jitterPoint) { view.mouseDragged(with: e) }
        } else if !clickOnly {
            // A real drag emits motion from the press point onwards, and
            // SwiftTerm seeds its selection anchor from the first motion event
            // it is given - so the first one has to be at the press point, or
            // the two paths under test would anchor differently.
            for p in [from, NSPoint(x: size.width / 2, y: (from.y + to.y) / 2), to] {
                if let e = ev(.leftMouseDragged, p) { view.mouseDragged(with: e) }
            }
        }
        let upPoint = jitter ? jitterPoint : (clickOnly ? from : to)
        if let e = ev(.leftMouseUp, upPoint) { view.mouseUp(with: e) }
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

    // MARK: 1 - a Shell tab's drag paints the theme's pair

    private static func checkShellTabPaintsTheThemeSelection(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: a Shell tab's drag paints the theme's selection pair")
        for theme in HelmTheme.allThemes {
            var sent: [UInt8] = []
            guard let r = renderDrag(theme: theme, sentBytes: &sent) else {
                fail(&ok, "\(theme.id): nothing rendered")
                continue
            }
            print("  \(theme.id): rows=\(r.filledRows) fill=\(hex(r.fill)) (want \(theme.selectionHex.uppercased())) inkBlend=\(fmt(r.inkBlend)) residual=\(fmt(r.inkResidual))")
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

    // MARK: 2 - the pair that reaches the screen is the guarded pair

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

    // MARK: 3 - a mouse-reporting child, and the regression this replaces

    private static func checkMouseReportingChildStillSelectsLocally(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: a drag over a mouse-reporting child renders identically to a plain one")
        // Both registers, because the reported symptom was light-mode-specific
        // and a dark theme can hide a wrong fill.
        for id in ["helm-light", "helm-dark", "daylight", "dusk"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else {
                fail(&ok, "\(id) not found"); continue
            }
            var sent: [UInt8] = []
            guard let plain = renderDrag(theme: theme, sentBytes: &sent) else {
                fail(&ok, "\(id): plain-child reference did not render"); continue
            }
            // The shipped configuration for a `.shell` tab.
            guard let captured = renderDrag(theme: theme, mouseCapture: true, sentBytes: &sent) else {
                fail(&ok, "\(id): mouse-reporting render failed"); continue
            }
            if hex(captured.fill) != hex(plain.fill) || abs(captured.inkBlend - plain.inkBlend) > 0.02 {
                fail(&ok, "\(id): mouse-reporting drew \(hex(captured.fill)) ink-blend \(fmt(captured.inkBlend)), plain drew \(hex(plain.fill)) ink-blend \(fmt(plain.inkBlend))")
            }
            if captured.filledRows < 3 {
                fail(&ok, "\(id): mouse-reporting painted only \(captured.filledRows) selected row(s)")
            }
            // The pre-fix behaviour, asserted rather than described: with the
            // opt-in off, mouse capture swallows the drag and nothing is
            // selected. If this ever stops being true the fix has become a
            // no-op and this case's pass above means nothing.
            var ignored: [UInt8] = []
            guard let unfixed = renderDrag(theme: theme, mouseCapture: true, localSelection: false,
                                           sentBytes: &ignored) else {
                fail(&ok, "\(id): unfixed render failed"); continue
            }
            if unfixed.filledRows != 0 || matches(unfixed.fill, theme.selectionHex, in: unfixed.repSpace) {
                fail(&ok, "\(id): mouse capture no longer swallows the drag - this suite can no longer tell the fix from its absence")
            }
        }
        if ok { print("  mouse-reporting == plain with the opt-in on; nothing selected with it off") }
    }

    // MARK: 4 - the child keeps its mouse

    private static func checkChildKeepsItsMouse(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: an opted-in tab still reports clicks and Shift-drags to the child")
        guard let theme = HelmTheme.allThemes.first(where: { $0.id == "helm-light" }) else {
            fail(&ok, "helm-light not found"); return
        }

        var clickBytes: [UInt8] = []
        _ = renderDrag(theme: theme, mouseCapture: true, clickOnly: true, sentBytes: &clickBytes)
        if clickBytes.isEmpty {
            fail(&ok, "a plain click reported nothing to the child - a TUI's own click targets would stop working")
        }

        var shiftBytes: [UInt8] = []
        let shiftDrag = renderDrag(theme: theme, mouseCapture: true, shiftHeld: true, sentBytes: &shiftBytes)
        if shiftBytes.isEmpty {
            fail(&ok, "a Shift-drag reported nothing to the child - a TUI's own drag gestures would be unreachable")
        }
        if let shiftDrag, shiftDrag.filledRows != 0 {
            fail(&ok, "a Shift-drag also painted a local selection - it is meant to be forwarded instead")
        }

        var dragBytes: [UInt8] = []
        _ = renderDrag(theme: theme, mouseCapture: true, sentBytes: &dragBytes)
        if !dragBytes.isEmpty {
            fail(&ok, "an unmodified drag reported \(dragBytes.count) byte(s) to the child - it should be kept locally, so the child never draws a second selection under ours")
        }
        if ok { print("  click reported, Shift-drag reported, plain drag kept local") }
    }

    // MARK: 5 - source guard: which tab kind opts in

    /// The scope *is* the captain's decision here, and it is invisible in a
    /// render: an `.ssh` tab opted in by mistake would paint exactly the same
    /// pixels as the `.shell` tab this suite drives, while silently changing
    /// what a plain drag does inside a remote vim or tmux.
    private static func checkShellTabsOptIn(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: `.shell` is what opts into local selection, and `.ssh` does not")
        let path = SelfTestSources.appSourceDirectory()?
            .appendingPathComponent("ConsoleController+Tabs.swift")
        guard let path, let text = try? String(contentsOf: path, encoding: .utf8) else {
            print("  SKIP: app sources not reachable from here")
            return
        }
        if !text.contains("if case .shell = launch { term.prefersLocalSelection = true }") {
            fail(&ok, "ConsoleController+Tabs.swift no longer opts the `.shell` tab into local selection")
        }
        let optIns = text.components(separatedBy: "prefersLocalSelection = true").count - 1
        if optIns != 1 {
            fail(&ok, "expected exactly one `prefersLocalSelection = true` opt-in in addTab, found \(optIns)")
        }
        if ok { print("  addTab opts `.shell` in, and nothing else") }
    }

    // MARK: 6 - a click's own hand-tremor jitter is still a click

    private static func checkClickJitterDoesNotEatTheClickOrBleedTheSelection(_ ok: inout Bool) {
        print("TerminalSelectionRenderSelfTest: sub-threshold jitter during a click is still a click, not a drag")
        guard let theme = HelmTheme.allThemes.first(where: { $0.id == "helm-light" }) else {
            fail(&ok, "helm-light not found"); return
        }

        var jitterBytes: [UInt8] = []
        guard let jittered = renderDrag(theme: theme, mouseCapture: true, jitter: true, sentBytes: &jitterBytes) else {
            fail(&ok, "a jittered click did not render"); return
        }
        if jitterBytes.isEmpty {
            fail(&ok, "a click with sub-threshold jitter reported nothing to the child - the click was swallowed, exactly the 'have to click twice' symptom")
        }
        if jittered.filledRows != 0 {
            fail(&ok, "a click with sub-threshold jitter painted \(jittered.filledRows) selected row(s) - a highlight appeared where nothing was deliberately dragged")
        }

        // Prove this case can actually tell the fix from its absence: force
        // the pre-fix (zero-threshold) behaviour on the identical gesture and
        // confirm it reproduces at least one of the two symptoms.
        CockpitTerminalView.localSelectionDragThresholdOverrideForTests = 0
        defer { CockpitTerminalView.localSelectionDragThresholdOverrideForTests = nil }
        var unfixedBytes: [UInt8] = []
        guard let unfixed = renderDrag(theme: theme, mouseCapture: true, jitter: true, sentBytes: &unfixedBytes) else {
            fail(&ok, "the unfixed jittered click did not render"); return
        }
        if !unfixedBytes.isEmpty, unfixed.filledRows == 0 {
            fail(&ok, "forcing the pre-fix threshold reproduced neither symptom - this case can no longer tell the fix from its absence")
        }
        if ok { print("  jitter still reaches the child and paints nothing locally; the pre-fix (zero) threshold reproduces the regression") }
    }
}

#endif
