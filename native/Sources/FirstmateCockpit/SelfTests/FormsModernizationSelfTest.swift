// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's §3F ("Inputs and forms") - F1, F2, F3.
//
// What is worth asserting here, and what deliberately is not. Three of these
// four findings are *motion* or *colour* polish, and a check that measures an
// animation's duration is taste rather than a regression guard - it only ever
// fails for the wrong reason. So this spends its assertions on the things that
// can silently stop working:
//
//   1. **F1's `animated:` is threaded, and the end state does not depend on
//      it.** The failure mode is not "it does not animate" (invisible, and the
//      finding is cosmetic) - it is "the animated branch leaves a *different*
//      resting chrome", which would make a field that has been focused once
//      render wrong for the rest of the session. Both branches are driven and
//      compared.
//   2. **F1 animates a focus transition and not a theme change.** Threading
//      the flag through and then passing `true` everywhere would cross-fade
//      every field in the window on a palette switch, which is the churn
//      Phase 6 removed from the gradient ribbons.
//   3. **F2(a): the Host editor window is genuinely fused**, and its sheet
//      reserves room for the traffic lights it now shows over its own
//      content. Both halves, because either alone is a defect: an unfused
//      window with the inset wastes 32pt, and a fused one without it puts the
//      heading behind the close button.
//   4. **F3: the selected swatch is a real selection state.** The finding is
//      that it "is a faint wash", so what is measured is the thing a wash is
//      not - an opaque fill behind the chosen icon, and a ring *plus* a
//      visible checkmark on the chosen colour - along with the 28-32pt target
//      the finding names.
//
// F2(c)'s keycaps live in `DaylightChromeSelfTest`'s sheet sweep, beside the
// rest of the footer recipe they are part of, rather than being split off here.
//
// Window-backed (it mounts real controllers in a real `NSWindow`), so it is in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with:
//   swift build && FM_RUN_FORMS_MODERNIZATION_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum FormsModernizationSelfTest {

    static func run() -> Bool {
        let restoreTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restoreTheme) }
        scratchStores()
        var allOK = true
        for check in [checkFocusEndStateIsIdenticalAnimatedOrNot,
                      checkFocusAnimatesOnlyTheTransition,
                      checkLayerAnimationPrimitive,
                      checkHostEditorWindowIsFused,
                      checkIconSwatchSelectionIsFilled,
                      checkColourSwatchSelectionIsRingPlusTick,
                      checkSwatchGridWraps] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "FormsModernizationSelfTest: all checks passed"
                    : "FormsModernizationSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    private static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    private static func scratchStores() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forms-modernization-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_SHIFT_DIR", dir.appendingPathComponent("shift").path, 1)
    }

    /// A real window, far off-screen. Never `makeKeyAndOrderFront`/`activate` -
    /// this machine runs the captain's own instance.
    private static func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 700, height: 820),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: 1. F1 - the animated branch resolves to the same chrome

    private static func checkFocusEndStateIsIdenticalAnimatedOrNot(_ ok: inout Bool) {
        print("\n-- F1: the focus chrome does not depend on whether it animated --")
        for theme in HelmTheme.allThemes {
            // A real well, in a real window, so `HelmField.applySunken`'s own
            // layer work runs exactly as it does in the app.
            let a = NSView(); a.wantsLayer = true
            let b = NSView(); b.wantsLayer = true
            let host = NSView()
            host.addSubview(a); host.addSubview(b)
            _ = makeWindow(host)

            for focused in [true, false] {
                HelmInputSurface.apply(chrome: a, theme: theme, focused: focused, animated: false)
                HelmInputSurface.apply(chrome: b, theme: theme, focused: focused, animated: true)
                // Read the *model* layer, which is what a later unanimated
                // pass will overwrite - a presentation-layer read would be
                // mid-flight and prove nothing either way.
                let ga = HelmInputSurface.focusGeometry(chrome: a)
                let gb = HelmInputSurface.focusGeometry(chrome: b)
                var problems: [String] = []
                if abs(ga.borderWidth - gb.borderWidth) > 0.01 {
                    problems.append("border \(fmt(ga.borderWidth)) vs \(fmt(gb.borderWidth))")
                }
                if !sameColor(ga.borderColor, gb.borderColor) { problems.append("border colour differs") }
                guard problems.isEmpty else {
                    print("  FAIL \(theme.id) focused=\(focused): \(problems.joined(separator: "; "))")
                    ok = false
                    continue
                }
            }
        }
        if ok {
            print("  OK   \(HelmTheme.allThemes.count) themes x focused/unfocused resolve identically")
        }
        // And the resting border really is the hairline while the focused one
        // is thicker - F1's own "1pt-to-1.5pt on focus" half. If these were
        // equal the whole check above would pass vacuously.
        let well = NSView(); well.wantsLayer = true
        _ = makeWindow(well)
        HelmInputSurface.apply(chrome: well, theme: HelmTheme.allThemes[0], focused: false)
        let resting = HelmInputSurface.focusGeometry(chrome: well).borderWidth
        HelmInputSurface.apply(chrome: well, theme: HelmTheme.allThemes[0], focused: true)
        let lit = HelmInputSurface.focusGeometry(chrome: well).borderWidth
        if abs(resting - HelmField.hairlineBorderWidth) > 0.01 || lit <= resting {
            print("  FAIL resting \(fmt(resting))pt / focused \(fmt(lit))pt - focus must thicken the border")
            ok = false
        } else {
            print("  OK   border \(fmt(resting))pt -> \(fmt(lit))pt on focus, every palette")
        }
    }

    // MARK: 2. F1 - a theme change must not animate

    private static func checkFocusAnimatesOnlyTheTransition(_ ok: inout Bool) {
        print("\n-- F1: `animated` defaults off, so a theme change stays instant --")
        // A source check, because both branches render the same end state (see
        // check 1) - which is exactly what makes "did it animate?" invisible to
        // a geometry read, and exactly why threading `true` everywhere would
        // ship unnoticed.
        guard let text = source("HelmForm.swift"), let ui = source("HelmUIComponents.swift"),
              let input = source("HelmInput.swift") else {
            print("  SKIP sources not present next to this binary")
            return
        }
        var problems: [String] = []
        if !input.contains("animated: Bool = false") {
            problems.append("HelmInputSurface.apply's `animated` no longer defaults off")
        }
        // The focus registrations pass a *computed* transition flag, never a
        // literal `true`: `register` fires once at registration to deliver the
        // current state, and animating that first fire would light every field
        // in a freshly-opened sheet.
        let transitions = text.components(separatedBy: "let changed = self.isFocused != focused").count - 1
        if transitions != 4 {
            problems.append("HelmForm has \(transitions) transition-guarded focus closures, want 4")
        }
        // The composer's own guard is structural (`guard focused != isFocused`),
        // so it passes `true` unconditionally and legitimately.
        if !ui.contains("applyTheme(lastTheme, animated: true)") {
            problems.append("HelmComposerCard no longer animates its focus change")
        }
        if problems.isEmpty {
            print("  OK   4 transition-guarded registrations + the composer's own guard")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 3. The primitive F1 depends on

    private static func checkLayerAnimationPrimitive(_ ok: inout Bool) {
        print("\n-- F1: `animateLayers` sets the flag that makes a layer property animate at all --")
        guard let motion = source("HelmMotion.swift") else {
            print("  SKIP sources not present next to this binary")
            return
        }
        // Without `allowsImplicitAnimation`, a layer property assigned on a
        // view-backed layer pops - which is the finding verbatim, and which no
        // amount of wrapping in `animate` would fix. Source, because the flag
        // leaves no property to read back afterwards.
        var problems: [String] = []
        if !motion.contains("context.allowsImplicitAnimation = true") {
            problems.append("animateLayers does not set allowsImplicitAnimation")
        }
        // Reduce Motion still means the end state, instantly.
        var reduced = false
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        HelmMotion.animateLayers(true, duration: 1) { reduced = true }
        if !reduced { problems.append("animateLayers skipped its body under Reduce Motion") }
        if problems.isEmpty {
            print("  OK   implicit animation enabled; Reduce Motion still runs the body")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 4. F2(a) - the Host editor window

    private static func checkHostEditorWindowIsFused(_ ok: inout Bool) {
        print("\n-- F2(a): the Host editor is a fused window, not a stock titlebar --")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 640, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        WindowChromeFusion.apply(to: window)

        var problems: [String] = []
        if !window.styleMask.contains(.fullSizeContentView) { problems.append("not .fullSizeContentView") }
        if !window.titlebarAppearsTransparent { problems.append("titlebar is not transparent") }
        if window.titleVisibility != .hidden { problems.append("title strip still visible") }
        // The lights stay: this window has no bar to hand them to, and a
        // window with no close button is not a window a captain can dismiss.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if window.standardWindowButton(kind)?.isHidden != false {
                problems.append("\(kind) is hidden")
            }
        }

        // And the sheet reserves room for them.
        let editor = HostEditorController(host: nil, keyStore: SSHKeyStore(),
                                          snippets: [], existingLabels: [])
        guard let form = editor.view as? HelmFormSheet else {
            print("  FAIL the Host editor's root is not a HelmFormSheet")
            ok = false
            return
        }
        window.contentViewController = editor
        form.layoutSubtreeIfNeeded()
        let plainTop = form.debugHeaderTopInset
        form.reservesWindowChromeInset = true
        form.layoutSubtreeIfNeeded()
        let fusedTop = form.debugHeaderTopInset
        let wanted = plainTop + WindowChromeFusion.contentTopClearance
        if abs(fusedTop - wanted) > 0.01 {
            problems.append("header top \(fmt(fusedTop))pt, want \(fmt(wanted)) (was \(fmt(plainTop)))")
        }
        // The clearance has to actually clear the cluster, not merely be
        // nonzero - the lights are centred at 16 and are ~14pt across.
        if WindowChromeFusion.contentTopClearance < WindowChromeFusion.naturalVerticalCenter + 7 {
            problems.append("contentTopClearance does not clear the traffic lights")
        }

        // The two checks above prove the *primitive* works and that the sheet
        // can reserve the room. Neither can see whether `presentHostEditor`
        // actually calls them - and a Host editor that quietly went back to a
        // stock titlebar would pass every geometry read above. Source, because
        // the window is built inside a method that opens and focuses a real
        // window, which a headless suite must not drive.
        if let main = source("main.swift") {
            let body = main.components(separatedBy: "func presentHostEditor(")
            if body.count < 2 {
                problems.append("presentHostEditor is gone - re-point this check")
            } else {
                let fn = body[1].prefix(9_000)
                if !fn.contains("WindowChromeFusion.apply(to: win)") {
                    problems.append("presentHostEditor does not fuse its window")
                }
                if !fn.contains("reservesWindowChromeInset = true") {
                    problems.append("presentHostEditor does not reserve room for the lights")
                }
            }
        } else {
            print("  NOTE sources not present - the wiring half of this check is skipped")
        }

        if problems.isEmpty {
            print("  OK   fused, lights kept, wired in presentHostEditor, header \(fmt(fusedTop))pt down")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 5/6/7. F3 - the swatch pickers

    private static func hostEditorInWindow() -> (HostEditorController, HelmFormSheet)? {
        let editor = HostEditorController(host: nil, keyStore: SSHKeyStore(),
                                          snippets: [], existingLabels: [])
        guard let form = editor.view as? HelmFormSheet else { return nil }
        _ = makeWindow(form)
        form.layoutSubtreeIfNeeded()
        return (editor, form)
    }

    private static func checkIconSwatchSelectionIsFilled(_ ok: inout Bool) {
        print("\n-- F3: the chosen icon sits on a filled tile, not a faint wash --")
        guard let (editor, _) = hostEditorInWindow() else {
            print("  FAIL could not build the Host editor")
            ok = false
            return
        }
        let swatches = editor.debugIconSwatches
        var problems: [String] = []
        if swatches.count != HostCatalog.icons.count {
            problems.append("\(swatches.count) icon swatches, want \(HostCatalog.icons.count)")
        }
        let selected = swatches.filter { $0.isSelected }
        if selected.count != 1 { problems.append("\(selected.count) selected, want exactly 1") }

        if let chosen = selected.first {
            let accent = HelmTheme.nsColor(editor.debugSelectedAccent)
            if !sameColor(chosen.fill, accent) {
                // The finding verbatim: "selection is a faint wash". An alpha
                // below 1 here *is* that wash.
                problems.append("selected tile is not an opaque fill of the chosen accent")
            }
            if (chosen.fill?.alphaComponent ?? 0) < 0.99 {
                problems.append("selected tile fill is \(fmt(chosen.fill?.alphaComponent ?? 0)) alpha - a wash")
            }
            // The glyph on it has to be legible against that fill, not the
            // accent itself (which on the accent is invisible).
            let wanted = HelmContrast.legibleGlyph(over: accent)
            if !sameColor(chosen.glyphTint, wanted) {
                problems.append("selected glyph is not contrast-corrected against its own fill")
            }
        }
        for s in swatches where !s.isSelected {
            if (s.fill?.alphaComponent ?? 0) > 0.01 {
                problems.append("an unselected icon tile carries a fill")
                break
            }
        }
        // F3's "28-32pt targets".
        for s in swatches where s.side < 28 || s.side > 32 {
            problems.append("icon target \(fmt(s.side))pt, want 28-32")
            break
        }
        if problems.isEmpty {
            print("  OK   \(swatches.count) tiles, one opaque selected, glyph corrected, \(fmt(swatches[0].side))pt")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    private static func checkColourSwatchSelectionIsRingPlusTick(_ ok: inout Bool) {
        print("\n-- F3: the chosen colour gets a ring AND a checkmark --")
        guard let (editor, _) = hostEditorInWindow() else {
            print("  FAIL could not build the Host editor")
            ok = false
            return
        }
        var problems: [String] = []
        let swatches = editor.debugColourSwatches
        if swatches.count != HostCatalog.accents.count {
            problems.append("\(swatches.count) colour swatches, want \(HostCatalog.accents.count)")
        }
        let selected = swatches.filter { $0.isSelected }
        if selected.count != 1 { problems.append("\(selected.count) selected, want exactly 1") }
        if let chosen = selected.first {
            if chosen.ringWidth < 1 { problems.append("selected swatch has no ring") }
            if chosen.tickHidden { problems.append("selected swatch has no checkmark") }
            if chosen.tickTint == nil { problems.append("the checkmark has no tint") }
        }
        for s in swatches where !s.isSelected {
            if s.ringWidth > 0.01 { problems.append("an unselected swatch carries a ring"); break }
            if !s.tickHidden { problems.append("an unselected swatch shows a checkmark"); break }
        }
        for s in swatches where s.side < 28 || s.side > 32 {
            problems.append("colour target \(fmt(s.side))pt, want 28-32")
            break
        }

        // Drive a real pick: the selection must move, and exactly one swatch
        // may carry it afterwards.
        if let other = swatches.first(where: { !$0.isSelected }) {
            editor.debugPickColour(other.hex)
            let after = editor.debugColourSwatches
            let nowSelected = after.filter { $0.isSelected }
            if nowSelected.count != 1 || nowSelected.first?.hex != other.hex {
                problems.append("picking a colour did not move the selection")
            }
            if nowSelected.first?.tickHidden == true {
                problems.append("the newly picked swatch has no checkmark")
            }
            // And the icon tile follows the new accent - the two pickers are
            // coupled and always were.
            let iconFill = editor.debugIconSwatches.first { $0.isSelected }?.fill
            if !sameColor(iconFill, HelmTheme.nsColor(other.hex)) {
                problems.append("the icon tile did not follow the new accent")
            }
        }

        if problems.isEmpty {
            print("  OK   ring + tick on the chosen swatch only, and picking moves both")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    private static func checkSwatchGridWraps(_ ok: inout Bool) {
        print("\n-- F3: a grid, not one long row --")
        guard let (editor, _) = hostEditorInWindow() else {
            print("  FAIL could not build the Host editor")
            ok = false
            return
        }
        // 12 icons at 6 per row is two rows; counting distinct y centres is
        // what tells a grid from a row, and is read off real frames after a
        // real layout pass rather than from the builder's own arithmetic.
        //
        // **Clustered, not bucketed.** The first version of this rounded each
        // centre into a 4pt bucket, which has boundary artefacts: two swatches
        // genuinely on one row split into two buckets whenever they straddle a
        // bucket edge, and `NSButton.alignmentRectInsets` is non-zero (AGENTS.md
        // records the measurement) so they do resolve a fraction apart. It
        // passed on this machine and reported "3 row(s), want 2" on a CI
        // runner - a real 12-icon grid on two rows, split by arithmetic.
        // Grouping centres that are *near each other* has no such edge, and is
        // what "distinct rows" means in the first place.
        let rowTolerance: CGFloat = 6   // well under a swatch (30) plus its gap
        var rows: [CGFloat] = []
        for centre in editor.debugIconSwatches.map({ $0.centreY }).sorted() {
            if let last = rows.last, abs(centre - last) <= rowTolerance { continue }
            rows.append(centre)
        }
        let wantRows = Int((Double(HostCatalog.icons.count) / 6.0).rounded(.up))
        if rows.count != wantRows {
            print("  FAIL icon swatches sit on \(rows.count) row(s), want \(wantRows)")
            ok = false
        } else {
            print("  OK   \(HostCatalog.icons.count) icons wrap onto \(rows.count) rows")
        }
    }

    // MARK: Source access

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }
}

#endif
