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

    deinit {
        if let keyActivityMonitor {
            NSEvent.removeMonitor(keyActivityMonitor)
        }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        for o in appActivityObservers { NotificationCenter.default.removeObserver(o) }
    }
}
