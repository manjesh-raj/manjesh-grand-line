// Manjesh Grand Line - native macOS app.
//
// The app's one "should a view taking focus right now paint a focus ring?"
// gate - the UI modernization audit's B3
// (`data/grandline-ui-modernization-audit/report.md` §3B), which the report
// files as half polish and half defect and its own bug appendix (§5 item 3)
// lists as a real, reproducible one.
//
// **The bug.** `AppShellController.updateKeyViewLoop()` ended with
// `if window.initialFirstResponder == nil { window.initialFirstResponder =
// chain.first }`, and `chain` starts with the bar's own controls - so the
// first space pill became the window's initial first responder the first time
// that ran, which is at launch. A `HoverHighlightView` draws a real
// `.exterior` focus ring (GL-16, deliberately - a keyboard user could not
// otherwise see where focus was), and the *selected* space pill is a solid
// ink capsule, so the captain saw two differently-decorated pills at once and
// read the ring as a second selection. Every one of the audit's ~95 captures
// shows it.
//
// **Why the ring itself is not the thing to delete.** GL-16 measured that
// this app had ~12 real controls with `focusRingType = .none`, so a keyboard
// user could not tell where focus was anywhere; removing the ring again would
// undo that. What is wrong is not that a focused pill is decorated, it is that
// *nothing the captain did* put focus there.
//
// **So the rule this encodes** is the one macOS itself follows, and the web
// calls `:focus-visible`: a ring is for focus the captain *moved*. Full
// Keyboard Access users always get it (that setting is exactly "I navigate by
// keyboard"); everyone else gets it the moment a key event is what moved
// focus, and never for a programmatic `makeFirstResponder` or a mouse click.
//
// **The mechanism is `NSApp.currentEvent`, read at the moment focus is
// taken**, rather than a keyDown monitor. Two reasons that matters:
//
//   1. It needs no `NSEvent` monitor, so it adds nothing for
//      `LockGateCoverageSelfTest`'s monitor sweep to have to exempt - and an
//      exemption there has to name where the real gate is, which for a
//      question this small would be pure ceremony.
//   2. It is per-focus-change accurate rather than a latched "keyboard has
//      been used at some point" flag: clicking a card after tabbing to one
//      correctly stops showing a ring, which is what macOS does.
//
// The decision has to be captured at `becomeFirstResponder` time and not at
// draw time - `drawFocusRingMask` runs in a later layout/draw pass, by which
// point `NSApp.currentEvent` is no longer the key event that moved focus.
// `HoverHighlightView.becomeFirstResponder()` is the single call site.
//
// **Scope: `HoverHighlightView` only, deliberately.** That one class is both
// views that can realistically be focused before the captain has touched
// anything - a space pill (the reported bug) and a canvas module card (where
// B3's other half now points the initial first responder). `HelmButton`,
// `HelmPopUpButton` and `HelmStatTile` also draw GL-16 rings, and are left
// exactly as they are: they live inside a page, below the first
// `HoverHighlightView` in the key loop, so none of them is ever the window's
// initial first responder, and a ring on a page control is not the
// double-selection ambiguity the audit is describing.

import AppKit

enum HelmFocusVisibility {

    /// Should a view that is taking first-responder status *right now* show a
    /// focus ring?
    ///
    /// Read at the moment focus is acquired - see this file's header for why
    /// draw time is too late.
    static var shouldShowRing: Bool {
        #if FM_SELFTESTS
        if let forced = overrideForTests { return forced }
        #endif
        // "I navigate by keyboard" as a standing statement. A captain with
        // this on wants to see focus everywhere, always, including the very
        // first responder at launch.
        if NSApp?.isFullKeyboardAccessEnabled == true { return true }
        // Otherwise: only if a key event is what is moving focus. A Tab
        // arrives here as the `.keyDown` AppKit is still dispatching when it
        // calls `selectNextKeyView`; a mouse click arrives as
        // `.leftMouseDown`; a programmatic `makeFirstResponder` (the launch
        // case) has no event of its own at all.
        switch NSApp?.currentEvent?.type {
        case .keyDown, .keyUp, .flagsChanged: return true
        default: return false
        }
    }

    /// The ring style a focusable view should wear for the focus it is taking
    /// right now.
    static var ringTypeForFocusBeingTaken: NSFocusRingType {
        shouldShowRing ? .exterior : .none
    }

    #if FM_SELFTESTS
    /// Forces the answer, so a suite can drive the *real* focus path in both
    /// states.
    ///
    /// There is no way to synthesise `NSApp.currentEvent` (it is read-only and
    /// driven by the event loop) and no API to set Full Keyboard Access, so
    /// without this the only testable claim would be "the call site mentions
    /// the gate" - which passes just as happily for a gate that is read and
    /// then ignored. Same convention, and the same reason, as
    /// `HelmMotion.reducedOverrideForTests`; every user of it restores `nil`.
    static var overrideForTests: Bool?
    #endif
}
