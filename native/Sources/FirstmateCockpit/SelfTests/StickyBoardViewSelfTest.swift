// Manjesh Grand Line - native macOS app.
//
// The window-backed half of the Sticky Board's coverage
// (`fm/grandline-sticky-board`): the real `StickyBoardController` in a real
// off-screen window, driven through real `NSEvent`-synthesized mouse
// gestures - mirroring `WhiteboardViewSelfTest.swift`/
// `TerminalSelectionRenderSelfTest.swift`'s own established harness shape
// rather than reinventing one.
//
// What this covers, in order:
//
//   1. **Theme correctness of the board/chrome, never the notes.** Sweeps a
//      Daylight-family theme pair (`daylight`/`dusk`) and a legacy theme pair
//      (`helm-light`/`helm-dark`) via `debugApplyTheme` - never
//      `ThemeManager.shared.setTheme`, which persists to real `UserDefaults`
//      and would clobber the captain's own saved preference on a shared dev
//      machine (`UnifiedSearch.swift`'s own `debugApplyTheme` established
//      this exact pattern). Confirms the root view / board card / canvas all
//      track the active theme's own tokens, and - the other half of the same
//      contract - that an already-placed note's own literal paper color is
//      byte-for-byte unchanged across all four themes.
//   2. **Real drag mechanics.** A synthesized mousedown/mousedrag/mouseup on
//      a note's header row moves the note's frame and persists the new
//      position to the store - not a click, which must NOT move it.
//   3. **Delete + undo**, including actually finding and clicking the real
//      `Toast` "Undo" button in the live view tree, not just calling the
//      store method directly (that half is already covered by
//      `StickyBoardSelfTest`'s pure-logic suite).
//
// `FM_RUN_STICKY_BOARD_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum StickyBoardViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = StickyBoardController()
        window.contentView = controller.view
        // A window only becomes genuinely composited for a process that is a
        // UI app - see `WhiteboardViewSelfTest`'s own note on this.
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        window.displayIfNeeded()

        checkThemeSweep(controller, check)
        checkNoteRedesign(controller, check)
        checkCorkRenders(controller, check)
        checkDragMechanics(controller, window, check)
        checkResizeMechanics(controller, window, check)
        checkBoardHeader(controller, check)
        checkDeleteAndUndo(controller, check)

        if ok {
            print("[sticky-board-view] OK - all window-backed StickyBoard checks passed")
        }
        return ok
    }

    // MARK: 1. Theme sweep - chrome tracks the theme, notes never do

    private static func checkThemeSweep(_ controller: StickyBoardController, _ check: (Bool, String) -> Void) {
        // Seed one note BEFORE the sweep, so we can prove its own paper color
        // survives every theme change unchanged.
        controller.debugNewNote()
        guard let note = controller.debugNoteViews.values.first else {
            check(false, "expected a note view to exist after debugNewNote()")
            return
        }
        let noteColorBefore = note.layer?.backgroundColor

        // One Daylight-family pair (light/dark) and one legacy pair
        // (light/dark) - the acceptance bar this task was built against.
        let themeIDs = ["daylight", "dusk", "helm-light", "helm-dark"]
        var rootColors: [String: Bool] = [:]
        var cardColors: [String: Bool] = [:]

        for id in themeIDs {
            guard let theme = HelmTheme.theme(id: id) else {
                check(false, "no HelmTheme registered for id \(id)")
                continue
            }
            controller.debugApplyTheme(theme)
            let dark = theme.mode == .dark
            let rootMatches = colorsClose(controller.view.layer?.backgroundColor, HelmTheme.nsColor(theme.backgroundHex).cgColor)
            // The board surface is cork and the card is the wood frame around
            // it - both literal hues chosen by light/dark MODE, not theme
            // tokens (see `StickyBoardModels.swift`'s header for why this is a
            // deliberate third colour category). This assertion changed shape
            // in `fm/grandline-sticky-code-preview-polish`; before it, the
            // board was a theme-token-filled dotted grid.
            let canvasMatches = colorsClose(controller.debugCanvas.layer?.backgroundColor,
                                            HelmTheme.nsColor(StickyBoardCork.baseHex(dark: dark)).cgColor)
            let cardMatches = colorsClose(controller.debugBoardCard.layer?.backgroundColor,
                                          HelmTheme.nsColor(StickyBoardCork.frameHex(dark: dark)).cgColor)
            check(rootMatches, "\(id): the page root should paint theme.backgroundHex")
            check(canvasMatches, "\(id): the board canvas should paint the cork base for its mode")
            check(cardMatches, "\(id): the board card should paint the wood frame tone for its mode")

            // **The actual bug the captain reported, and the assertion that
            // would have caught it.** Every layer fill above already tracked
            // the theme before this task - which is precisely why "Sticky
            // Board doesn't re-theme properly" survived a green self-test.
            // What did not track it is everything resolving a *system
            // semantic* colour (scroller track and knob, the field editor
            // behind the note title, the overflow `NSMenu`, focus rings):
            // those follow `effectiveAppearance`, which is the OS's own
            // light/dark until a view forces it. That is `ThemeManager.swift`'s
            // checklist item 2, which every other destination in this app has
            // obeyed for years and these two never did.
            let wantAqua: NSAppearance.Name = dark ? .darkAqua : .aqua
            let effective = controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            check(effective == wantAqua,
                  "\(id): the page's effectiveAppearance should be \(wantAqua.rawValue), was \(effective?.rawValue ?? "nil") "
                  + "- system-semantic colours (scrollers, field editors, menus) follow this, not the layer fills")

            rootColors[id] = rootMatches
            cardColors[id] = cardMatches

            // The note's own literal paper color must be completely
            // unaffected by the theme switch - the captain's own explicit
            // instruction ("the board's own background - not the notes - is
            // what actually switches with light/dark mode").
            check(colorsEqual(note.layer?.backgroundColor, noteColorBefore),
                  "\(id): a note's own paper color must not change when the app theme changes")
        }

        check(rootColors.values.allSatisfy { $0 }, "every swept theme should have painted the page root correctly")
        check(cardColors.values.allSatisfy { $0 }, "every swept theme should have painted the board card correctly")

        // Cork is cork, but a corkboard in a dark room is a darker cork - the
        // captain's explicit ask was that the board's TONE genuinely switches,
        // never "the same flat colour regardless of theme". Asserted as a real
        // measured difference rather than by reading the constants.
        for (light, dark) in [(StickyBoardCork.baseHex(dark: false), StickyBoardCork.baseHex(dark: true)),
                              (StickyBoardCork.frameHex(dark: false), StickyBoardCork.frameHex(dark: true))] {
            let lum = { HelmContrast.relativeLuminance(HelmContrast.components(HelmTheme.nsColor($0))) }
            check(lum(light) > lum(dark) + 0.08,
                  "the light-mode cork/wood tone (\(light)) should be visibly lighter than the dark-mode one (\(dark))")
        }

        // Two palettes in the SAME mode must show the same cork: the tone is
        // keyed to light/dark, not to the individual theme, so a captain
        // switching helm-light -> gruvbox-light sees the board stay put.
        if let helmLight = HelmTheme.theme(id: "helm-light"), let gruvLight = HelmTheme.theme(id: "gruvbox-light") {
            controller.debugApplyTheme(helmLight)
            let a = controller.debugCanvas.layer?.backgroundColor
            controller.debugApplyTheme(gruvLight)
            check(colorsEqual(a, controller.debugCanvas.layer?.backgroundColor),
                  "two light palettes should show the identical cork - the tone follows mode, not palette")
        }

        // The rotation transform is a genuine, non-identity tilt, applied
        // once at creation and unaffected by the theme sweep above.
        let transform = note.layer?.transform ?? CATransform3DIdentity
        check(!CATransform3DEqualToTransform(transform, CATransform3DIdentity),
              "a freshly created note should carry a non-zero rotation transform")
    }

    // MARK: 1b. The note redesign (`fm/grandline-sticky-code-preview-polish`)

    /// The four things the captain's reference photo asked for, each measured
    /// on the real view rather than inferred from the code: a title line, a
    /// handwriting body face, a red pin, and a resize grip.
    private static func checkNoteRedesign(_ controller: StickyBoardController, _ check: (Bool, String) -> Void) {
        guard let note = controller.debugNoteViews.values.first else {
            check(false, "no note view to inspect")
            return
        }
        // The note was created after this window's one `displayIfNeeded`, and
        // a note is frame-positioned on a non-Auto-Layout canvas - so nothing
        // has laid its own subtree out yet. Call it on the NOTE, not an
        // ancestor: `layoutSubtreeIfNeeded` does not descend into a subtree
        // whose own `needsLayout` is false (AGENTS.md's own gotcha, learned
        // the hard way on the Kubernetes describe panel).
        note.layoutSubtreeIfNeeded()

        // The body is a real handwriting face, not the system font. Checking
        // "not the system font" rather than a literal name is what makes this
        // survive a machine missing one candidate while still catching the
        // failure that actually ships (a typo'd name silently falling back).
        let system = NSFont.systemFont(ofSize: 14).fontName
        check(note.debugTextView.font?.fontName != system,
              "the note body should render in a handwriting face, got \(note.debugTextView.font?.fontName ?? "nil")")
        check(note.debugTitleField.font?.fontName != system,
              "the note title should render in a handwriting face, got \(note.debugTitleField.font?.fontName ?? "nil")")

        // A title with no text still shows where the label goes rather than
        // collapsing the row - the field is the least discoverable part of the
        // redesign, so it must not be invisible when empty.
        check(note.debugTitleField.placeholderAttributedString?.string == StickyNoteView.titlePlaceholder,
              "an empty title should show its placeholder")
        check(note.debugTitleField.frame.height > 0, "the title field should occupy real height")

        // The pin is red on every paper colour (see `StickyNoteView.pinFill`'s
        // own note on why it is the one thing not drawn from the note's ink).
        let pinColor = note.debugPin.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        let pinComponents = pinColor.map { HelmContrast.components($0) }
        check(pinComponents.map { $0.0 > 0.55 && $0.1 < 0.45 && $0.2 < 0.45 } ?? false,
              "the pin should be a red marker, got \(String(describing: pinComponents))")
        check(note.debugPin.frame.width > 0 && note.debugPin.frame.width == note.debugPin.frame.height,
              "the pin should be a real, circular marker")

        // The grip is a real view in the bottom-right corner, not a hit-test
        // region - see `StickyNoteResizeHandleView`'s own note on why.
        let grip = note.debugResizeHandle
        check(grip.superview === note, "the resize grip should be a child of the note")
        check(abs(grip.frame.maxX - note.bounds.maxX) < 0.5 && abs(grip.frame.minY - note.bounds.minY) < 0.5,
              "the resize grip should sit in the note's bottom-right corner, at \(grip.frame) in \(note.bounds)")
    }

    // MARK: 2. Drag mechanics - a real mousedown/mousedrag/mouseup

    private static func checkDragMechanics(_ controller: StickyBoardController, _ window: NSWindow, _ check: (Bool, String) -> Void) {
        guard let note = controller.debugNoteViews.values.first else {
            check(false, "no note view to drag")
            return
        }
        let originalOrigin = note.frame.origin
        let header = note.debugHeader

        func ev(_ type: NSEvent.EventType, _ pointInHeader: NSPoint) -> NSEvent? {
            // `locationInWindow` is what `mouseDown`/`mouseDragged` read, so
            // convert the header-local point up through the note and canvas
            // into window coordinates the same way AppKit itself would.
            let inNote = header.convert(pointInHeader, to: nil)
            return NSEvent.mouseEvent(with: type, location: inNote, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil,
                                     eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // A genuine drag: press, then real motion well past the 3pt
        // threshold, then release.
        let press = NSPoint(x: 10, y: 10)
        if let e = ev(.leftMouseDown, press) { header.mouseDown(with: e) }
        if let e = ev(.leftMouseDragged, NSPoint(x: 60, y: 45)) { header.mouseDragged(with: e) }
        if let e = ev(.leftMouseUp, NSPoint(x: 60, y: 45)) { header.mouseUp(with: e) }

        let movedOrigin = note.frame.origin
        check(movedOrigin != originalOrigin,
              "a real drag past the threshold should move the note's frame, stayed at \(originalOrigin)")

        let storeNote = controller.debugStore.notes.first { $0.id == note.noteID }
        check(storeNote != nil, "the dragged note should still exist in the store")
        if let storeNote {
            check(abs(storeNote.x - movedOrigin.x) < 0.5 && abs(storeNote.y - movedOrigin.y) < 0.5,
                  "the store's persisted position should match where the note actually ended up, "
                  + "store=(\(storeNote.x), \(storeNote.y)) view=(\(movedOrigin.x), \(movedOrigin.y))")
        }

        // A plain click (no motion past the threshold) must NOT move the
        // note - this is what lets a click inside the body still place a
        // caret rather than being read as a drag.
        let clickOrigin = note.frame.origin
        if let e = ev(.leftMouseDown, press) { header.mouseDown(with: e) }
        if let e = ev(.leftMouseUp, press) { header.mouseUp(with: e) }
        check(note.frame.origin == clickOrigin, "a plain click with no motion must not move the note")
    }

    // MARK: 1c. The cork actually paints
    //
    // Every other assertion in this file reads a colour *property*. A pattern
    // fill is the one thing that can be configured perfectly and still paint
    // nothing - `NSColor(patternImage:)` with an empty image, a tile that
    // failed to lock focus, a `draw(_:)` that stopped being called. So this
    // renders the real canvas and reads the pixels back.

    private static func checkCorkRenders(_ controller: StickyBoardController, _ check: (Bool, String) -> Void) {
        func sample(_ theme: HelmTheme) -> (base: NSColor?, distinctTones: Int) {
            controller.debugApplyTheme(theme)
            let canvas = controller.debugCanvas
            // Far from the top-left, where new notes cascade from - sampling
            // over a note would count the note's own rendering as "grain" and
            // make this check pass against a completely flat board.
            let region = NSRect(x: 1400, y: 1000, width: 120, height: 120)
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: region) else { return (nil, 0) }
            canvas.cacheDisplay(in: region, to: rep)
            var tones = Set<String>()
            var mid: NSColor?
            for x in stride(from: 2, to: 118, by: 3) {
                for y in stride(from: 2, to: 118, by: 3) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if mid == nil { mid = c }
                    let comps = HelmContrast.components(c)
                    // Quantised, so antialiasing on a speck edge does not count
                    // as its own "tone" and inflate the variation reading.
                    tones.insert(String(format: "%.2f-%.2f-%.2f", comps.0, comps.1, comps.2))
                }
            }
            return (mid, tones.count)
        }

        for id in ["helm-light", "helm-dark"] {
            guard let theme = HelmTheme.theme(id: id) else { continue }
            let (base, tones) = sample(theme)
            guard let base else {
                check(false, "\(id): could not render the cork canvas")
                continue
            }
            let dark = theme.mode == .dark
            let expected = HelmTheme.nsColor(StickyBoardCork.baseHex(dark: dark))
            let comps = HelmContrast.components(base)
            let want = HelmContrast.components(expected)
            // Rendered pixels come back in the display's own profile, so this
            // is a tolerant identity check rather than an exact match -
            // AGENTS.md's own standing rule for any probe that samples a
            // render.
            check(abs(comps.0 - want.0) < 0.2 && abs(comps.1 - want.1) < 0.2 && abs(comps.2 - want.2) < 0.2,
                  "\(id): the rendered board is \(comps), expected roughly the cork base \(want)")
            // Cork reads as cork because of the grain. A flat fill produces
            // exactly one tone; a real drawn texture produces many.
            check(tones > 6,
                  "\(id): the board rendered \(tones) distinct tone(s) - a drawn cork texture should render many, a flat fill renders one")
        }
    }

    // MARK: 2b. Resize mechanics - the same shape as the drag test

    private static func checkResizeMechanics(_ controller: StickyBoardController, _ window: NSWindow, _ check: (Bool, String) -> Void) {
        guard let note = controller.debugNoteViews.values.first else {
            check(false, "no note view to resize")
            return
        }
        let grip = note.debugResizeHandle
        let sizeBefore = note.frame.size

        func ev(_ type: NSEvent.EventType, _ pointInGrip: NSPoint) -> NSEvent? {
            let inWindow = grip.convert(pointInGrip, to: nil)
            return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // A click that never moves must not resize - and, just as importantly,
        // must not write an identical size to the store and wake the git
        // debounce. Same minimum-movement contract the drag handle carries.
        if let e = ev(.leftMouseDown, NSPoint(x: 8, y: 8)) { grip.mouseDown(with: e) }
        if let e = ev(.leftMouseDragged, NSPoint(x: 9, y: 8)) { grip.mouseDragged(with: e) }
        if let e = ev(.leftMouseUp, NSPoint(x: 9, y: 8)) { grip.mouseUp(with: e) }
        check(note.frame.size == sizeBefore,
              "a sub-threshold click on the grip must not resize the note")

        // A genuine drag: down and to the right grows the note in both axes.
        if let e = ev(.leftMouseDown, NSPoint(x: 8, y: 8)) { grip.mouseDown(with: e) }
        if let e = ev(.leftMouseDragged, NSPoint(x: 68, y: -42)) { grip.mouseDragged(with: e) }
        if let e = ev(.leftMouseUp, NSPoint(x: 68, y: -42)) { grip.mouseUp(with: e) }

        let sizeAfter = note.frame.size
        check(sizeAfter.width > sizeBefore.width && sizeAfter.height > sizeBefore.height,
              "a real grip drag should grow the note, \(sizeBefore) -> \(sizeAfter)")

        // And it must reach the store, the same way a drag's end does.
        let stored = controller.debugStore.notes.first { $0.id == note.noteID }
        check(stored.map { abs($0.width - Double(sizeAfter.width)) < 0.5 && abs($0.height - Double(sizeAfter.height)) < 0.5 } ?? false,
              "the resized size should be persisted, view=\(sizeAfter) store=\(stored.map { "\($0.width)x\($0.height)" } ?? "nil")")

        // Never past the metric bounds, however far the drag goes.
        if let e = ev(.leftMouseDown, NSPoint(x: 8, y: 8)) { grip.mouseDown(with: e) }
        if let e = ev(.leftMouseDragged, NSPoint(x: 4000, y: -4000)) { grip.mouseDragged(with: e) }
        if let e = ev(.leftMouseUp, NSPoint(x: 4000, y: -4000)) { grip.mouseUp(with: e) }
        check(note.frame.width <= StickyBoardMetrics.maxNoteSize.width
                && note.frame.height <= StickyBoardMetrics.maxNoteSize.height,
              "an enormous drag should clamp to the maximum note size, got \(note.frame.size)")

        // A title typed into the field reaches the store through the real
        // delegate callback, exactly like the body text does.
        let field = note.debugTitleField
        field.stringValue = "CLUE"
        // `controlTextDidChange` is what a real keystroke triggers; posting the
        // real notification drives the same path rather than calling the
        // callback directly.
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        check(controller.debugStore.notes.first { $0.id == note.noteID }?.title == "CLUE",
              "editing the title field should persist the title")
    }

    // MARK: 2c. The board's own case-file header

    private static func checkBoardHeader(_ controller: StickyBoardController, _ check: (Bool, String) -> Void) {
        let title = controller.debugBoardTitle
        check(!title.stringValue.isEmpty, "the board should carry its own case-file title")
        check(title.font?.fontName != NSFont.systemFont(ofSize: 15).fontName,
              "the board title should render in the typewriter voice, got \(title.font?.fontName ?? "nil")")
        // Deliberately below the hero floor `DaylightDrillPageSelfTest`
        // polices: this is a label stuck on the board, not a second page title
        // competing with the drill header's own.
        check((title.font?.pointSize ?? 99) < 20,
              "the board title must stay under the 20pt hero floor, was \(title.font?.pointSize ?? -1)")

        // The pill states something true rather than a permanent sticker: a
        // board with notes is ACTIVE, an empty one is not (GL-14's rule - an
        // empty state and a broken one must never render the same).
        check(controller.debugStatusLabel.stringValue == "ACTIVE",
              "a board with notes should read ACTIVE, got \(controller.debugStatusLabel.stringValue)")
        check(controller.debugStatusDot.layer?.backgroundColor != nil, "the status dot should be filled")

        // The header's ink is corrected against the CORK it sits on, not
        // against the theme's own background - a dark theme's near-white ink
        // on light tan cork would be illegible.
        for id in ["helm-light", "helm-dark"] {
            guard let theme = HelmTheme.theme(id: id) else { continue }
            controller.debugApplyTheme(theme)
            let cork = HelmTheme.nsColor(StickyBoardCork.baseHex(dark: theme.mode == .dark))
            guard let ink = controller.debugBoardTitle.textColor else {
                check(false, "\(id): the board title should have an ink colour")
                continue
            }
            let ratio = HelmContrast.ratio(ink, cork)
            check(ratio >= HelmContrast.textTarget,
                  "\(id): the board title reads \(ratio) against the cork, below the \(HelmContrast.textTarget) floor")
        }
    }

    // MARK: 3. Delete + undo, including the real Toast button

    private static func checkDeleteAndUndo(_ controller: StickyBoardController, _ check: (Bool, String) -> Void) {
        guard let note = controller.debugNoteViews.values.first else {
            check(false, "no note view to delete")
            return
        }
        let id = note.noteID
        let countBefore = controller.debugStore.notes.count

        controller.debugDeleteNote(id: id)
        check(controller.debugStore.notes.count == countBefore - 1, "deleting a note should remove it from the store")
        check(controller.debugNoteViews[id] == nil, "deleting a note should remove its view")

        // Find and click the real Toast "Undo" button in the live view tree
        // - not a synthetic call to the store's own restore method, which
        // `StickyBoardSelfTest`'s pure-logic suite already covers.
        guard let undoButton = findButton(titled: "Undo", in: controller.view) else {
            check(false, "expected a real Toast Undo button in the view tree after a delete")
            return
        }
        undoButton.performClick(nil)

        check(controller.debugStore.notes.count == countBefore, "clicking the real Undo button should restore the note in the store")
        check(controller.debugNoteViews[id] != nil, "clicking the real Undo button should re-add the note's view")
    }

    // MARK: Helpers

    private static func findButton(titled: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == titled { return button }
        for sub in view.subviews {
            if let found = findButton(titled: titled, in: sub) { return found }
        }
        return nil
    }

    /// Compares two `CGColor`s through `HelmContrast.components`, which
    /// normalizes into a straight sRGB triple regardless of the color spaces
    /// the two literal `CGColor`s happen to carry.
    private static func colorsClose(_ a: CGColor?, _ b: CGColor?, tolerance: Double = 0.01) -> Bool {
        guard let a, let b, let na = NSColor(cgColor: a), let nb = NSColor(cgColor: b) else { return false }
        let ca = HelmContrast.components(na)
        let cb = HelmContrast.components(nb)
        return abs(ca.0 - cb.0) < tolerance && abs(ca.1 - cb.1) < tolerance && abs(ca.2 - cb.2) < tolerance
    }

    private static func colorsEqual(_ a: CGColor?, _ b: CGColor?) -> Bool {
        colorsClose(a, b, tolerance: 0.001)
    }
}

#endif
