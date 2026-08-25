// Manjesh Grand Line - native macOS app.
//
// The paste-hardening terminal view. This is the Phase 1 subclass kept verbatim
// (design report section 5.3): both Phase 2 tabs - the Shell and the tmux Mirror
// - use it, so the screenshot-paste-into-Claude flow behaves identically on both.

import AppKit
import SwiftTerm

// MARK: - Paste-hardening terminal (design report section 5.3)

/// A `LocalProcessTerminalView` that guarantees the bracketed-paste signal for
/// an image-only clipboard.
///
/// SwiftTerm's default `paste(_:)` already emits an empty bracketed paste
/// (`ESC[200~` `ESC[201~`) when the clipboard holds no text, which is the exact
/// signal Claude Code needs to notice a paste and go read the image off the
/// system clipboard. This subclass makes that contract explicit and independent
/// of any future upstream change: if there is an image and no text, and the
/// terminal has bracketed paste mode on, it sends the empty bracketed paste
/// directly. Otherwise it defers to SwiftTerm's normal paste (real text still
/// pastes as text).
final class CockpitTerminalView: LocalProcessTerminalView {
    override func paste(_ sender: Any) {
        lastUserActivity = Date()
        let pb = NSPasteboard.general
        let hasText = (pb.string(forType: .string)?.isEmpty == false)
        let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
        if !hasText, hasImage, terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(data: EscapeSequences.bracketedPasteEnd[0...])
            return
        }
        super.paste(sender)
    }

    // MARK: Captain activity tracking (`fm/cockpit-sre-lead-shared-terminal`)

    /// The most recent moment a real keystroke or paste reached this
    /// terminal - never set by `SRELeadBridge`'s own `send(txt:)` injections,
    /// which don't go through key events. `SRELeadBridge` reads this (via
    /// `TabModel`'s `SRELeadBridgeTerminal` conformance) to refuse a command
    /// when the captain is actively using the tab, and to detect after the
    /// fact that the captain typed into it while a command was still
    /// running.
    private(set) var lastUserActivity: Date?

    /// `TerminalView.keyDown(with:)` is declared `public`, not `open` (see
    /// the AGENTS.md gotcha catalogue's note on SwiftTerm's non-`open`
    /// override points), so it can't be overridden from this module the way
    /// `paste(_:)` above can. A local event monitor, scoped to exactly the
    /// events this view itself receives as first responder, gets the same
    /// "a real keystroke arrived" signal without needing an override point
    /// SwiftTerm doesn't expose.
    private var keyActivityMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyActivityMonitor {
            NSEvent.removeMonitor(keyActivityMonitor)
            self.keyActivityMonitor = nil
        }
        guard window != nil else { return }
        keyActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            self.lastUserActivity = Date()
            return event
        }
    }

    // MARK: Local, theme-coloured selection in a mouse-reporting tab
    //       (`fm/grandline-console-selection-contrast-followup`)

    /// When `true`, an *unmodified* left-button **drag** builds this app's own
    /// SwiftTerm selection - the one `HelmTheme.apply(to:)` colours with the
    /// active theme's `selectionHex` / `selectionTextHex` pair - even while the
    /// child process has mouse reporting enabled. Holding **Shift** forwards
    /// the whole gesture to the child instead, and a plain *click* is still
    /// forwarded either way.
    ///
    /// Why this exists, and why it is a *routing* fix rather than a colour one:
    ///
    /// Console's Herdr/Mirror tab runs a real `herdr session attach` client,
    /// and that client enables mouse capture (`?1002h` / `?1006h`, both present
    /// in the herdr binary; herdr also exposes `mouse_capture` and
    /// `copy_on_select` as config keys). SwiftTerm's `mouseDown`/`mouseDragged`
    /// therefore hand every drag straight to the child
    /// (`allowMouseReporting && terminal.mouseMode != .off`) and **never build
    /// a selection of their own** - so `selectedTextBackgroundColor` /
    /// `selectedTextForegroundColor` are simply never consulted in that tab.
    /// What the captain sees highlighted is herdr's *own* selection, painted
    /// from herdr's own fixed dark theme (its documented default is
    /// `selection_bg = "#313244"`, a dark navy) with no knowledge of which of
    /// this app's 14 themes is active - which is exactly the reported
    /// "dark navy block with dark, illegible text in light mode".
    ///
    /// A plain Shell tab enables no mouse mode at all, so the identical drag
    /// there goes down SwiftTerm's own selection path and comes out in the
    /// theme's colours. That is the whole difference between the two tabs, and
    /// it was reproduced with real rendered pixels before this was written:
    /// same content, same theme, same synthesized drag, `mouseMode = .off`
    /// paints `selectionHex` behind `selectionTextHex`, `mouseMode =
    /// .buttonEventTracking` paints nothing.
    ///
    /// No colour value in this app could have fixed that, because none of them
    /// were being read. Routing the gesture back to SwiftTerm's own selection
    /// is what puts the Herdr tab on the *same* mapping the Shell tab already
    /// uses correctly, which is what makes both tabs inherit
    /// `FM_RUN_CONTRAST_TESTS`' existing per-theme floor for that pair.
    ///
    /// Nothing herdr can do with the mouse is lost: a click (press and release
    /// with no drag in between) is still delivered, the scroll wheel is
    /// untouched, and Shift+drag forwards the drag as before. Only which of the
    /// two owns an *unmodified* drag changes, and only in a mirror tab.
    var prefersLocalSelection = false

    /// The left-button press we deliberately did not deliver yet, held until
    /// the gesture reveals itself as a click (forward it) or a drag (keep it).
    /// Deferring - rather than forwarding the press and then stealing the
    /// motion - is what keeps herdr's own button state consistent: it never
    /// sees a press whose release it will not also see.
    private var deferredPress: NSEvent?
    /// True once a deferred press turned into a local selection drag.
    private var localSelectionDragActive = false

    /// Should this event start a local selection instead of being reported?
    private func divertsToLocalSelection(_ event: NSEvent) -> Bool {
        guard prefersLocalSelection, allowMouseReporting else { return false }
        guard getTerminal().mouseMode != .off else { return false }
        return !event.modifierFlags.contains(.shift)
    }

    /// Run `body` with mouse reporting suppressed, so SwiftTerm's own
    /// selection code runs instead of `sharedMouseEvent`.
    private func withoutMouseReporting(_ body: () -> Void) {
        let saved = allowMouseReporting
        allowMouseReporting = false
        body()
        allowMouseReporting = saved
    }

    /// Deliver `event` to the child even though Shift is held. SwiftTerm's
    /// `shiftBypassesMouseReporting` would otherwise route a Shift-modified
    /// event to its own selection - the default this tab inverts - so the copy
    /// handed to `super` carries no Shift flag.
    private func withoutShift(_ event: NSEvent) -> NSEvent {
        guard event.modifierFlags.contains(.shift) else { return event }
        return NSEvent.mouseEvent(with: event.type,
                                  location: event.locationInWindow,
                                  modifierFlags: event.modifierFlags.subtracting(.shift),
                                  timestamp: event.timestamp,
                                  windowNumber: event.windowNumber,
                                  context: nil,
                                  eventNumber: event.eventNumber,
                                  clickCount: event.clickCount,
                                  pressure: event.pressure) ?? event
    }

    override func mouseDown(with event: NSEvent) {
        guard prefersLocalSelection, allowMouseReporting, getTerminal().mouseMode != .off else {
            super.mouseDown(with: event)
            return
        }
        if divertsToLocalSelection(event) {
            // Hold it: a click still has to reach herdr, and we only know this
            // is a drag once motion arrives.
            deferredPress = event
            localSelectionDragActive = false
            return
        }
        super.mouseDown(with: withoutShift(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = deferredPress else {
            if prefersLocalSelection, allowMouseReporting, getTerminal().mouseMode != .off,
               event.modifierFlags.contains(.shift) {
                super.mouseDragged(with: withoutShift(event))
                return
            }
            super.mouseDragged(with: event)
            return
        }
        withoutMouseReporting {
            if !localSelectionDragActive {
                // Anchor the selection at the press point, not at wherever the
                // first motion event happened to land: SwiftTerm's own
                // `mouseDragged` seeds `setSoftStart` from the event it is
                // given, so the press has to go through it first.
                super.mouseDragged(with: press)
                localSelectionDragActive = true
            }
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let press = deferredPress else {
            if prefersLocalSelection, allowMouseReporting, getTerminal().mouseMode != .off,
               event.modifierFlags.contains(.shift) {
                super.mouseUp(with: withoutShift(event))
                return
            }
            super.mouseUp(with: event)
            return
        }
        deferredPress = nil
        if localSelectionDragActive {
            localSelectionDragActive = false
            withoutMouseReporting { super.mouseUp(with: event) }
            return
        }
        // No motion arrived: it was a click, so replay the press and release
        // for the child exactly as it would have received them.
        super.mouseDown(with: press)
        super.mouseUp(with: event)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Non-nil while a self-test wants to know which mouse gestures were
    /// actually reported to the child process. `TerminalSelectionRenderSelfTest`
    /// uses it to prove that a mirror tab still forwards clicks and Shift-drags
    /// to herdr while keeping an unmodified drag for its own selection - the
    /// half of the fix that a pixel check cannot see.
    var sentToChildForTests: [UInt8]?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if sentToChildForTests != nil { sentToChildForTests?.append(contentsOf: data) }
        super.send(source: source, data: data)
    }
    #endif

    deinit {
        if let keyActivityMonitor {
            NSEvent.removeMonitor(keyActivityMonitor)
        }
    }
}
