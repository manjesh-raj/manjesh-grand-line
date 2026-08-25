// Manjesh Grand Line - native macOS app.
//
// The paste-hardening terminal view. This is the Phase 1 subclass kept verbatim
// (design report section 5.3): every tab uses it, so the
// screenshot-paste-into-Claude flow behaves identically on all of them.
//
// It is also where E1's *battery* half lives - see "Display gating" below.

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
        registerDisplayGatingObservers()
        refreshDisplayGating()
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

    // MARK: Display gating (E1 - the audit's headline battery finding)

    /// Everything in this section exists because of one measurement: with the
    /// Console showing a tab attached to firstmate's own live session (which
    /// prints almost continuously - running crewmates, logs), the app burned
    /// **~6-16% CPU and 2.9% GPU sustained while merely backgrounded**, and a
    /// 5-second `sample` of the captain's real instance put nearly all of the
    /// main thread's busy time in `CA::Transaction commit -> TerminalView.draw`.
    /// It was the app's top CPU consumer machine-wide, at Energy Impact 19.9
    /// against Chrome's 143 12-hr power vs. this app's 2,312.
    ///
    /// The cause is not a bug in SwiftTerm: it repaints when its buffer
    /// changes, which is correct. The gap is that **nothing ever told it to
    /// stop**. macOS keeps drawing a window that is only *behind* other
    /// windows, and this app checked neither `NSApplication.isActive` nor
    /// `NSWindow.occlusionState` anywhere.
    ///
    /// Two rules, and the distinction between them is deliberate:
    ///
    ///  - **Not on screen at all** (this view is hidden - its page was
    ///    navigated away from, or another tab is selected - or its window is
    ///    closed, minimised, or fully covered by another window): painting is
    ///    *suspended*. Nothing is scheduled, and the one deferred pass is
    ///    flushed on resume. See `windowOccluded` for why the "fully covered"
    ///    half is tracked from the notification rather than read live.
    ///  - **On screen but the app is not active**: painting is *throttled* to
    ///    `backgroundIntervalNanos` (~2 Hz) instead of 60 Hz. It cannot be
    ///    suspended, because a backgrounded window can still be partly
    ///    visible and must not freeze into a stale image.
    ///
    /// The terminal **model** is never gated - every byte still reaches the
    /// buffer through the ordinary `feed` path, so scrollback stays exact and
    /// a resumed view is correct immediately rather than needing a reconnect.
    /// That is the whole reason this is a display-scheduling gate and not
    /// something that pauses the child or drops output.
    ///
    /// `displaySuspended` / `displayIntervalNanos` are Grand Line patch 4 on
    /// the vendored SwiftTerm (`Vendor/SwiftTerm/README.md`) - none of
    /// `updateDisplay`, `queuePendingDisplay` or `draw(_:)` is `open`, so
    /// there is no override point for this from outside that module.

    /// 60 Hz - upstream's own hardcoded cadence, for a visible, active window.
    static let foregroundIntervalNanos: UInt64 = 16_670_000
    /// ~2 Hz, for a visible window whose app is not frontmost. Slow enough to
    /// take the redraw cost to near nothing, fast enough that a glance at a
    /// half-covered window still shows live output.
    static let backgroundIntervalNanos: UInt64 = 500_000_000

    private var occlusionObserver: NSObjectProtocol?
    private var appActivityObservers: [NSObjectProtocol] = []

    /// Whether this view's window is currently *fully* covered, tracked only
    /// from `NSWindow.didChangeOcclusionStateNotification` and defaulting to
    /// "not occluded".
    ///
    /// Deliberately not read live off `window.occlusionState` inside
    /// `refreshDisplayGating`: a window only reports `.visible` for a process
    /// the window server actually composites, so a headless/`.prohibited`
    /// context (every self-test run, and anything driving this view without a
    /// real GUI session) reports "not visible" for a window that is perfectly
    /// fine - and suspending on that reading would freeze a live terminal.
    /// Deriving the flag from the change notification instead fails safe: an
    /// environment that never posts one keeps painting, exactly as before this
    /// gate existed, while a real Mac still suspends the moment a window is
    /// genuinely covered.
    private var windowOccluded = false

    /// Registered on every window move (the occlusion notification is
    /// per-window, so it has to follow this view between windows) and torn
    /// down in `deinit`.
    private func registerDisplayGatingObservers() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            windowOccluded = false
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let self else { return }
                if let w = note.object as? NSWindow {
                    self.windowOccluded = !w.occlusionState.contains(.visible)
                }
                self.refreshDisplayGating()
            }
        } else {
            windowOccluded = false
        }
        guard appActivityObservers.isEmpty else { return }
        for name: NSNotification.Name in [NSApplication.didBecomeActiveNotification,
                                          NSApplication.didResignActiveNotification,
                                          NSApplication.didHideNotification,
                                          NSApplication.didUnhideNotification] {
            appActivityObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshDisplayGating() })
        }
    }

    /// `viewDidHide`/`viewDidUnhide` fire on an *effective* visibility change -
    /// this view's own `isHidden` or any ancestor's - which is exactly the
    /// signal needed and the reason this gate lives on the view rather than
    /// being wired per page in `ConsoleController`. Both the console's own
    /// tab switching (`updateTabViewVisibility`) and the app shell's
    /// destination hiding (`DestinationRegistry`'s permanent-mount +
    /// `isHidden` model) reach it for free.
    override func viewDidHide() {
        super.viewDidHide()
        refreshDisplayGating()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshDisplayGating()
    }

    /// Recompute both gates from live state. Deliberately derived rather than
    /// tracked: a missed notification then costs at most one stale reading
    /// that the next event corrects, instead of latching a visible terminal
    /// into a suspended state.
    func refreshDisplayGating() {
        let onScreen: Bool
        if let window, window.isVisible, !window.isMiniaturized,
           !windowOccluded, !isHiddenOrHasHiddenAncestor {
            onScreen = true
        } else {
            onScreen = false
        }
        displaySuspended = !onScreen
        displayIntervalNanos = NSApp.isActive
            ? Self.foregroundIntervalNanos
            : Self.backgroundIntervalNanos
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
    /// Console's Herdr/Herdr tab runs a real `herdr session attach` client,
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
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        for o in appActivityObservers { NotificationCenter.default.removeObserver(o) }
    }
}
