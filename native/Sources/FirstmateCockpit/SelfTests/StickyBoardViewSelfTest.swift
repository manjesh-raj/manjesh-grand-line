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
        checkDragMechanics(controller, window, check)
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
            let rootMatches = colorsClose(controller.view.layer?.backgroundColor, HelmTheme.nsColor(theme.backgroundHex).cgColor)
            let canvasMatches = colorsClose(controller.debugCanvas.layer?.backgroundColor, HelmTheme.nsColor(theme.backgroundHex).cgColor)
            let cardMatches = colorsClose(controller.debugBoardCard.layer?.backgroundColor, HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor)
            check(rootMatches, "\(id): the page root should paint theme.backgroundHex")
            check(canvasMatches, "\(id): the board canvas should paint theme.backgroundHex")
            check(cardMatches, "\(id): the board card should paint theme.chromeBackgroundHex")
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

        // The rotation transform is a genuine, non-identity tilt, applied
        // once at creation and unaffected by the theme sweep above.
        let transform = note.layer?.transform ?? CATransform3DIdentity
        check(!CATransform3DEqualToTransform(transform, CATransform3DIdentity),
              "a freshly created note should carry a non-zero rotation transform")
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
