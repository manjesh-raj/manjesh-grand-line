// Manjesh Grand Line - native macOS app.
//
// Phase 0 of the Daylight UI migration: the mechanism fixes, asserted against
// real controls in a real window rather than by reading the code.
//
// Every check here exists because the thing it checks shipped broken and
// looked fine:
//
// - D1 (`checkFocusAnswersTheClick`): the composers' focus glow was wired to
//   `textDidBeginEditing`, which fires on the first *keystroke*. Reading the
//   code, "the card lights when the field starts editing" looks correct. Only
//   focusing a field without typing into it shows the bug, which is what this
//   does - `makeFirstResponder` and then assert, with no text inserted.
// - D4 (`checkSelectionIsThemed`): selection is painted by the field editor's
//   `selectedTextAttributes`, and AppKit resets that to the system value on
//   every editing session (measured: setting it on one field and focusing the
//   next reads back `System selectedTextBackgroundColor`). So a check that
//   only sets it once and reads it back would pass while the app still
//   highlighted in system blue on the second field.
// - D3/D6 (`checkHealthCard`): Health's private pill painted the raw tint hue
//   as its own label - the §5.7 defect the shared pill already fixed - and its
//   rows used raw `.systemFont` sizes, which silently opt out of the captain's
//   chrome-text-scale setting (GL-32).
//
// Window-backed (focus has no meaning without a window), so
// `Scripts/run-all-tests.sh` lists it in `NEEDS_SESSION` with its peers. The
// window is never ordered front: nothing here needs to be seen, and this app
// must not be launched from a worktree (one bundle identity across builds -
// see the README).
//
// Run: `FM_RUN_INPUT_SURFACE_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only - see `Phase3PolishSelfTest`.
#if FM_SELFTESTS

import AppKit

enum InputSurfaceSelfTest {

    static func run() -> Bool {
        var ok = true
        _ = NSApplication.shared
        checkFocusAnswersTheClick(&ok)
        checkFocusMovesBetweenFields(&ok)
        checkTextViewFocusGlows(&ok)
        checkSelectionIsThemed(&ok)
        checkSearchField(&ok)
        checkHealthCard(&ok)
        print(ok ? "InputSurfaceSelfTest: all checks passed" : "InputSurfaceSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition { fail(message, &ok) } else { print("  OK \(message)") }
    }

    /// A real window with a real content view, laid out once so every control
    /// has a frame. Never ordered front.
    private static func makeWindow(_ views: [NSView], height: CGFloat = 240) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
        window.contentView = content
        var previous: NSView?
        for view in views {
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                view.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? content.topAnchor,
                                          constant: 16),
            ])
            previous = view
        }
        content.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: D1 - the click, not the keystroke

    /// The whole point of `HelmFocusSensing`: focus, do not type, and the well
    /// must already be lit.
    ///
    /// The pre-Phase-0 behaviour passes an "is the border thicker after
    /// typing" check and fails this one, which is why this deliberately never
    /// touches `stringValue` or inserts text.
    private static func checkFocusAnswersTheClick(_ ok: inout Bool) {
        print("\n-- D1: focus answers the click, before any keystroke --")
        let theme = HelmTheme.allThemes.first { $0.id == "helm-dark" } ?? HelmTheme.allThemes[0]
        let field = HelmTextField(placeholder: "Something")
        let window = makeWindow([field])
        field.applyTheme(theme)

        let resting = HelmInputSurface.focusGeometry(chrome: field)
        check(abs(resting.borderWidth - HelmField.hairlineBorderWidth) < 0.01,
              "resting border is the hairline (\(resting.borderWidth))", &ok)

        // The click, in the only form a headless probe has: AppKit routes a
        // click on a text field to exactly this.
        _ = window.makeFirstResponder(field)
        check(HelmFocusSensing.isFocused(field),
              "the field reports focused via its field editor", &ok)
        check(field.stringValue.isEmpty, "no text was typed (this is the D1 case)", &ok)

        let focused = HelmInputSurface.focusGeometry(chrome: field)
        check(abs(focused.borderWidth - HelmInputSurface.focusBorderWidth) < 0.01,
              "focused border thickened to \(HelmInputSurface.focusBorderWidth) "
              + "(measured \(focused.borderWidth))", &ok)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let border = focused.borderColor?.usingColorSpace(.sRGB)
        let expected = accent.withAlphaComponent(HelmInputSurface.focusBorderAlpha).usingColorSpace(.sRGB)
        check(border != nil && expected != nil
              && abs(border!.redComponent - expected!.redComponent) < 0.02
              && abs(border!.greenComponent - expected!.greenComponent) < 0.02
              && abs(border!.blueComponent - expected!.blueComponent) < 0.02,
              "focused border is the theme accent, not a system colour", &ok)

        _ = window.makeFirstResponder(nil)
        let after = HelmInputSurface.focusGeometry(chrome: field)
        check(abs(after.borderWidth - HelmField.hairlineBorderWidth) < 0.01,
              "border returns to the hairline when focus leaves (\(after.borderWidth))", &ok)
    }

    /// Two fields in one window: exactly one may be lit at a time. A
    /// registration that never hears about focus *leaving* passes the
    /// single-field check above and fails this one.
    private static func checkFocusMovesBetweenFields(_ ok: inout Bool) {
        print("\n-- focus moves, and only one well is lit --")
        let theme = HelmTheme.allThemes[0]
        let first = HelmTextField(placeholder: "First")
        let second = HelmTextField(placeholder: "Second")
        let window = makeWindow([first, second])
        first.applyTheme(theme)
        second.applyTheme(theme)

        _ = window.makeFirstResponder(first)
        var a = HelmInputSurface.focusGeometry(chrome: first).borderWidth
        var b = HelmInputSurface.focusGeometry(chrome: second).borderWidth
        check(a > b, "first lit, second not (\(a) vs \(b))", &ok)

        _ = window.makeFirstResponder(second)
        a = HelmInputSurface.focusGeometry(chrome: first).borderWidth
        b = HelmInputSurface.focusGeometry(chrome: second).borderWidth
        check(b > a, "focus moved: second lit, first back to the hairline (\(a) vs \(b))", &ok)
    }

    /// `HelmTextView` is the shape that also gets the glow, because it owns an
    /// un-clipped wrapper. A clipped well can only thicken its border.
    private static func checkTextViewFocusGlows(_ ok: inout Bool) {
        print("\n-- multi-line well: border plus a real glow --")
        let theme = HelmTheme.allThemes[0]
        let field = HelmTextView(height: 90)
        let window = makeWindow([field])
        field.applyTheme(theme)

        check(HelmInputSurface.focusGeometry(chrome: field.chromeView, shadowHost: field)
                .shadowOpacity == 0, "no glow at rest", &ok)
        _ = window.makeFirstResponder(field.textView)
        let lit = HelmInputSurface.focusGeometry(chrome: field.chromeView, shadowHost: field)
        check(lit.shadowOpacity > 0, "glow lit on focus (opacity \(lit.shadowOpacity))", &ok)
        check(abs(lit.borderWidth - HelmInputSurface.focusBorderWidth) < 0.01,
              "border thickened too (\(lit.borderWidth))", &ok)
        check(field.layer?.masksToBounds == false,
              "the glow host does not clip (a clipped layer casts no shadow)", &ok)
        _ = window.makeFirstResponder(nil)
        check(HelmInputSurface.focusGeometry(chrome: field.chromeView, shadowHost: field)
                .shadowOpacity == 0, "glow off when focus leaves", &ok)
    }

    // MARK: D4 - themed selection

    /// The selection colour has to be re-applied per editing session, and this
    /// asserts the *second* field too - which is where the naive
    /// "set it once" implementation fails.
    private static func checkSelectionIsThemed(_ ok: inout Bool) {
        print("\n-- D4: text selection is theme-derived, on every field --")
        let systemBlue = NSColor.selectedTextBackgroundColor

        // The recipe itself, swept across every palette. Pure - no window
        // needed - and the half that guarantees a *new* theme cannot ship a
        // selection colour that fails the floor.
        for theme in HelmTheme.allThemes {
            let attrs = HelmSelection.attributes(theme)
            guard let background = attrs[.backgroundColor] as? NSColor,
                  let foreground = attrs[.foregroundColor] as? NSColor else {
                fail("\(theme.id): HelmSelection produced no colours", &ok)
                return
            }
            if background == systemBlue {
                fail("\(theme.id): selection is the system colour", &ok)
                return
            }
            // `fm/grandline-text-selection-contrast-audit` made the fill
            // **opaque** - a translucent wash's effective colour depends on
            // whatever surface is underneath, and on Daylight no single
            // foreground clears the floor against both a light field and
            // §6.13's dark terminal card. So the assertion is no longer "the
            // raw accent hue" but "a wash of the accent over the field fill":
            // the fill has to sit on the segment between those two, which is
            // exactly what an alpha composite produces.
            if !isWashOfAccent(background, theme: theme) {
                fail("\(theme.id): selection fill is not a wash of the theme accent", &ok)
                return
            }
            // The ink sits on that opaque fill, so it is scored against the
            // real drawn colour rather than against a reconstruction of it.
            let composited = background
            let ratio = HelmContrast.ratio(foreground, composited)
            if ratio < HelmContrast.textTarget {
                fail(String(format: "%@: selected text %.2f against its own wash (floor %.2f)",
                            theme.id, ratio, HelmContrast.textTarget), &ok)
                return
            }
        }
        print("  OK all \(HelmTheme.allThemes.count) themes: selection is the accent wash with "
              + "legible ink on it")

        // The wiring half, against real controls in the *active* theme (the
        // only one the live field editor can be painted in without writing to
        // this machine's real theme preference). The second field is the case
        // that matters: AppKit resets the shared editor's
        // `selectedTextAttributes` on every editing session, so a fix that
        // paints it once passes on the first field and fails here.
        let theme = ThemeManager.shared.theme
        let first = HelmTextField(placeholder: "First")
        let second = HelmTextField(placeholder: "Second")
        let multi = HelmTextView(height: 60)
        let window = makeWindow([first, second, multi], height: 320)
        for control in [first, second] { control.applyTheme(theme) }
        multi.applyTheme(theme)

        for (label, control) in [("first", first), ("second", second)] {
            _ = window.makeFirstResponder(control)
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                fail("\(label) field: no field editor became first responder", &ok)
                continue
            }
            let background = editor.selectedTextAttributes[.backgroundColor] as? NSColor
            check(background != nil && background != systemBlue
                  && isWashOfAccent(background!, theme: theme),
                  "\(label) field's editor paints selection from the theme accent", &ok)
        }
        let owned = multi.textView.selectedTextAttributes[.backgroundColor] as? NSColor
        check(owned != nil && owned != systemBlue,
              "HelmTextView paints its own selection", &ok)
        _ = window.makeFirstResponder(nil)
    }

    /// The selection fill has to be the theme's own accent washed over the
    /// field fill - i.e. a point on the segment between them, at whichever
    /// rung of `HelmSelection.alphaLadder` that palette needed. Comparing
    /// against the raw accent would only be right for a translucent fill.
    private static func isWashOfAccent(_ color: NSColor, theme: HelmTheme) -> Bool {
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.accentHex))
        let field = HelmContrast.components(HelmField.fill(theme))
        for step in HelmSelection.alphaLadder {
            let candidate = HelmContrast.color(HelmContrast.mix(accent, field, Double(step)))
            if sameHue(candidate, color) { return true }
        }
        return false
    }

    /// Hue comparison rather than equality: colours reconstructed through
    /// `HelmContrast`'s sRGB maths can differ from the painted one in the last
    /// bit, and the comparison must not care about that.
    private static func sameHue(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.02
            && abs(x.greenComponent - y.greenComponent) < 0.02
            && abs(x.blueComponent - y.blueComponent) < 0.02
    }

    // MARK: The search well

    /// `HelmSearchField` replaced two `NSSearchField`s whose only theming was
    /// a forced `appearance`. This asserts it is a real themed well that
    /// reports typing and forwards command keys - the two behaviours its call
    /// sites depend on.
    private static func checkSearchField(_ ok: inout Bool) {
        print("\n-- search well: themed chrome, live text, forwarded commands --")
        let theme = HelmTheme.allThemes[0]
        let search = HelmSearchField(placeholder: "Filter tools\u{2026}", shortcutHint: "\u{2318}K")
        let window = makeWindow([search])
        search.applyTheme(theme)

        check(search.debugHasShortcutChip, "the shortcut chip renders when asked for", &ok)
        check(search.debugPlaceholderHidden == false, "placeholder shows while empty", &ok)

        let geometry = HelmField.geometry(of: search.chromeView)
        check(abs(geometry.radius - HelmField.cornerRadius(for: theme)) < 0.01,
              "the well is the shared radius (\(geometry.radius))", &ok)
        let fill = geometry.fill?.usingColorSpace(.sRGB)
        let expected = HelmField.fill(theme).usingColorSpace(.sRGB)
        check(fill != nil && expected != nil
              && abs(fill!.redComponent - expected!.redComponent) < 0.02,
              "the well is filled from HelmField.fill, not a system colour", &ok)

        var typed: [String] = []
        search.onTextChanged = { typed.append($0) }
        var commands: [Selector] = []
        search.onCommand = { commands.append($0); return true }

        search.debugEditor.stringValue = "cert"
        // The notification AppKit posts as the field editor changes - what a
        // real keystroke produces.
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                 object: search.debugEditor))
        check(typed == ["cert"], "typing reports through onTextChanged \(typed)", &ok)
        check(search.debugPlaceholderHidden, "placeholder hides once there is text", &ok)

        let consumed = search.control(search.debugEditor, textView: NSTextView(),
                                     doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(consumed && commands.count == 1,
              "Return is forwarded to onCommand and its verdict respected", &ok)

        search.focusEditor()
        check(HelmFocusSensing.isFocused(search.debugEditor),
              "focusEditor() puts the caret in the well", &ok)
        check(HelmInputSurface.focusGeometry(chrome: search.chromeView, shadowHost: search)
                .borderWidth > HelmField.hairlineBorderWidth,
              "the search well lights on focus like every other input", &ok)
        _ = window.makeFirstResponder(nil)
    }

    // MARK: D3 / D6 - Health

    /// Health's own two regressions, asserted on the real card.
    private static func checkHealthCard(_ ok: inout Bool) {
        print("\n-- D3/D6: Health uses the shared pill and HelmType --")
        // A real report, so the card renders a real service row rather than
        // its empty state.
        ServiceHealthRegistry.shared.recordSuccess(.scheduledAutomations)
        ServiceHealthRegistry.shared.recordFailure(.backgroundSignals, "probe failure")
        ServiceHealthRegistry.shared.register(.shiftGitSync)
        let card = HealthCardView()
        let theme = HelmTheme.allThemes.first { $0.mode == .light } ?? HelmTheme.allThemes[0]
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        card.card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card.card)
        NSLayoutConstraint.activate([
            card.card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.card.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        card.refresh(theme: theme)
        host.layoutSubtreeIfNeeded()
        card.layoutDidChange()
        host.layoutSubtreeIfNeeded()

        // D3: every pill label must clear the text floor against its own fill.
        // The private pill painted the raw hue on a 15% wash of itself, which
        // is what failed in 44 of 72 theme/hue pairs.
        //
        // Confirmed to catch it: reinstating that private pill reports a worst
        // ratio of 1.00, because the label and the wash are then literally the
        // same colour with only an alpha between them - the defect's own
        // signature. The shared pill flattens its fill to an opaque colour
        // (`HelmContrast.tintedSurface`), which is what makes the measured
        // number here exact rather than alpha-dependent.
        var pills = 0
        var worst = 99.0
        for (fill, label) in pillPairs(in: card.card, theme: theme) {
            pills += 1
            worst = min(worst, HelmContrast.ratio(label, fill))
        }
        check(pills > 0, "found \(pills) status pill(s) to measure", &ok)
        check(worst >= HelmContrast.textTarget,
              String(format: "worst pill label contrast %.2f (floor %.2f)",
                     worst, HelmContrast.textTarget), &ok)

        // D6: no label may carry a size `HelmType` would not have produced -
        // a raw `.systemFont(ofSize: 12.5)` ignores the captain's own
        // chrome-text-scale setting entirely.
        // `cardTitle()` joined this list when Daylight Phase 4 made `HelmCard`
        // resolve its header to §6.5's 13.5 semibold. It is a real `HelmType`
        // role, which is what this check is about - not a raw point size.
        let allowed = Set([HelmType.rowTitle(), HelmType.caption(), HelmType.body(),
                           HelmType.sectionTitle(), HelmType.cardTitle(),
                           HelmType.kicker(), HelmType.code()]
                          .map { Double($0.pointSize).rounded(toPlaces: 2) })
        var offenders: [String] = []
        walk(card.card) { view in
            guard let text = view as? NSTextField, let font = text.font else { return }
            // Pill labels are `ToolRowLayout.pill`'s own recipe, which owns
            // its size; a stat/metric font is likewise the component's.
            if text.superview?.layer?.cornerRadius
                == ToolRowLayout.pillCornerRadius(for: theme) { return }
            let size = Double(font.pointSize).rounded(toPlaces: 2)
            if !allowed.contains(size) {
                offenders.append("\(text.stringValue.prefix(24))@\(size)")
            }
        }
        check(offenders.isEmpty, "every Health label size comes from HelmType "
              + (offenders.isEmpty ? "" : "- offenders: \(offenders)"), &ok)

        // D5: the destination name is stated once on this page, not three
        // times. The top bar (outside this card) is statement one; the card's
        // own header must not repeat it.
        var headerTitles: [String] = []
        walk(card.card) { view in
            guard let text = view as? NSTextField else { return }
            if text.stringValue == "Health" { headerTitles.append(text.stringValue) }
        }
        check(headerTitles.isEmpty,
              "the card header no longer restates the destination name", &ok)

        // D6's other half: the description column uses the real card width
        // rather than a hardcoded 360pt cap.
        var widest: CGFloat = 0
        walk(card.card) { view in
            guard let text = view as? NSTextField, text.maximumNumberOfLines != 1 else { return }
            widest = max(widest, text.preferredMaxLayoutWidth)
        }
        check(widest > 400, "descriptions wrap at the real card width (\(widest)pt), "
              + "not the old 360pt cap", &ok)
    }

    /// Every (opaque fill, label colour) pair inside a pill-shaped container.
    /// `theme` matters, and is not `ThemeManager.shared.theme`: the card under
    /// test was themed explicitly, so the radius to look for is the one *that*
    /// theme paints - not whatever the machine happens to have selected.
    private static func pillPairs(in root: NSView, theme: HelmTheme) -> [(NSColor, NSColor)] {
        var pairs: [(NSColor, NSColor)] = []
        walk(root) { view in
            guard let fill = view.layer?.backgroundColor,
                  abs((view.layer?.cornerRadius ?? 0)
                      - ToolRowLayout.pillCornerRadius(for: theme)) < 0.01,
                  let label = view.subviews.compactMap({ $0 as? NSTextField }).first,
                  let ink = label.textColor
            else { return }
            pairs.append((NSColor(cgColor: fill) ?? .clear, ink))
        }
        return pairs
    }

    private static func walk(_ view: NSView, _ body: (NSView) -> Void) {
        body(view)
        for child in view.subviews { walk(child, body) }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

#endif
