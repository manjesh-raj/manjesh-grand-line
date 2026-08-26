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
    //       (`fm/grand-line-shell-tab-local-selection`)

    /// When `true`, an *unmodified* left-button **drag** builds this app's own
    /// SwiftTerm selection - the one `HelmTheme.apply(to:)` colours with the
    /// active theme's `selectionHex` / `selectionTextHex` pair - even while the
    /// child process has mouse reporting enabled. Holding **Shift** forwards
    /// the whole gesture to the child instead, and a plain *click* is still
    /// forwarded either way.
    ///
    /// **Only a `.shell` tab opts in** (`ConsoleController.addTab`), and that
    /// scope is the decision, not an implementation detail - see below.
    ///
    /// Why this exists, and why it is a *routing* fix rather than a colour one:
    ///
    /// `MacTerminalView.mouseDragged` returns early whenever
    /// `allowMouseReporting && !shiftBypassesMouseReporting(event) &&
    /// terminal.mouseMode != .off`, and never builds a selection of its own -
    /// so for any child that enables mouse capture (Claude Code, vim, `less`,
    /// tmux, `herdr` run by hand) `selectedTextBackgroundColor` /
    /// `selectedTextForegroundColor` are simply never consulted. What the
    /// captain sees highlighted in that state is the *child program's* own
    /// selection, painted from that program's own fixed palette with no idea
    /// which of this app's 14 themes is active - herdr's documented default is
    /// `selection_bg = "#313244"`, a dark navy, which is exactly the reported
    /// "dark navy block with dark, illegible text in light mode".
    ///
    /// That was measured rather than reasoned about, twice: with mouse
    /// reporting off the identical synthesized drag paints `selectionHex`
    /// behind `selectionTextHex` in all 14 themes, and with it on the same drag
    /// paints **nothing at all** (`fm/grand-line-shell-selection-investigate-fix`,
    /// whose report has the transcripts). No colour value in this app could
    /// have fixed that, because none of them were being read.
    ///
    /// **Scope, and why it is `.shell` only.** A `.shell` tab is a local login
    /// shell on the captain's own machine: whatever mouse-reporting program he
    /// starts *inside* it is something he can also reach through its own
    /// keyboard interface, and reading its output is the tab's main job - so an
    /// unmodified drag is worth more as a selection than as a mouse report.
    /// An `.ssh` tab is the opposite case and is deliberately left alone: it
    /// may be running vim or the captain's own tmux on a remote host, where a
    /// plain drag reaching the remote program is the expected behaviour and the
    /// keyboard alternative is someone else's machine away. This mechanism
    /// previously existed scoped to the (since-deleted) herdr tab; the captain's
    /// decision here re-scopes the same routing to `.shell`, and it is not a
    /// reinstatement of that tab.
    ///
    /// Nothing the child can do with the mouse is lost: a click (press and
    /// release with no drag in between) is still delivered, the scroll wheel is
    /// untouched, and Shift+drag forwards the drag as before.
    var prefersLocalSelection = false

    /// The left-button press we deliberately did not deliver yet, held until
    /// the gesture reveals itself as a click (forward it) or a drag (keep it).
    /// Deferring - rather than forwarding the press and then stealing the
    /// motion - is what keeps the child's own button state consistent: it never
    /// sees a press whose release it will not also see.
    private var deferredPress: NSEvent?
    /// True once a deferred press turned into a local selection drag.
    private var localSelectionDragActive = false

    /// Minimum on-screen movement (points, `locationInWindow` units - already
    /// scale-independent) between the held press and a `mouseDragged` event
    /// before the gesture is treated as a genuine drag rather than hand/
    /// trackpad jitter during an ordinary click.
    ///
    /// AppKit calls `mouseDragged` for essentially any movement while the
    /// button is held - there is no built-in click-vs-drag hysteresis, and
    /// without one here a single stray sub-pixel `mouseDragged` event (which
    /// a real click's hold time can easily produce, and which trackpad event
    /// coalescing under CPU load - e.g. a `.shell` tab actively repainting -
    /// can deliver already several points from the press) immediately:
    ///
    ///  1. Flipped `localSelectionDragActive` to `true` with no distance
    ///     check, which - since `mouseUp` only replays the press+release to
    ///     the child when no drag happened - silently ate the click instead
    ///     of forwarding it. The captain sees this as "I have to click twice"
    ///     on a mouse-reporting child's own row/item.
    ///  2. Seeded SwiftTerm's own selection at the press point and then
    ///     immediately extended it to wherever that one jittered event
    ///     landed (`MacTerminalView.mouseDragged`'s `selection.dragExtend`).
    ///     Extending a selection across even one row boundary highlights the
    ///     *entire width* of every row in between (ordinary stream-selection
    ///     semantics) - which is what a captain sees as the app's own themed
    ///     selection colour "bleeding" across a mouse-reporting TUI's own
    ///     panes (e.g. herdr's sidebar/main-content columns), since SwiftTerm
    ///     has no notion of the child program's own column layout.
    ///
    /// A small threshold absorbs both: it is well below what any deliberate
    /// drag-to-select gesture produces within one or two events, so real
    /// selection is unaffected, while an accidental sub-threshold wiggle
    /// during a click keeps the press held until either real movement
    /// arrives or the button comes back up. AppKit exposes no public
    /// click-vs-drag distance constant, so this is a deliberately small,
    /// documented choice rather than a system value.
    private static let localSelectionDragThreshold: CGFloat = 4

    #if FM_SELFTESTS
    /// Test-only override so `TerminalSelectionRenderSelfTest` can force the
    /// pre-fix (zero-threshold) behaviour with the exact same synthesized
    /// gesture and prove it reproduces both symptoms - the codebase's own
    /// standing bar for a regression guard being one that can tell the fix
    /// from its absence, not just one that passes.
    static var localSelectionDragThresholdOverrideForTests: CGFloat?
    #endif

    private var effectiveLocalSelectionDragThreshold: CGFloat {
        #if FM_SELFTESTS
        if let override = Self.localSelectionDragThresholdOverrideForTests { return override }
        #endif
        return Self.localSelectionDragThreshold
    }

    private func distance(_ a: NSEvent, _ b: NSEvent) -> CGFloat {
        let dx = a.locationInWindow.x - b.locationInWindow.x
        let dy = a.locationInWindow.y - b.locationInWindow.y
        return (dx * dx + dy * dy).squareRoot()
    }

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
            // Defensive: AppKit normally guarantees a `mouseUp` for every
            // `mouseDown`, but a popover or modal opening mid-gesture can
            // interrupt one. A press left held from a previous gesture would
            // otherwise be consumed by this one - anchoring a selection at a
            // stale point, or (in this branch) leaving a child that received a
            // real press never seeing its release.
            deferredPress = nil
            super.mouseDown(with: event)
            return
        }
        if divertsToLocalSelection(event) {
            // Hold it: a click still has to reach the child, and we only know
            // this is a drag once motion arrives.
            deferredPress = event
            localSelectionDragActive = false
            return
        }
        deferredPress = nil
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
        if !localSelectionDragActive, distance(press, event) < effectiveLocalSelectionDragThreshold {
            // Not yet real movement - keep the press held. Neither building a
            // local selection nor forwarding to the child would be correct
            // here, since the gesture might still resolve to a plain click on
            // `mouseUp`; see `localSelectionDragThreshold`'s doc comment.
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
    /// uses it to prove a `.shell` tab still forwards clicks and Shift-drags to
    /// a mouse-reporting child while keeping an unmodified drag for its own
    /// selection - the half of the fix a pixel check cannot see.
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
