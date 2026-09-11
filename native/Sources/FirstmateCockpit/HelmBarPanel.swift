// Manjesh Grand Line - native macOS app.
//
// `HelmBarPanel` - the floating bar's dropdown chrome (UI modernization audit
// B5, `data/grandline-ui-modernization-audit/report.md` §3B).
//
// **What it replaces.** Recents, notifications and the avatar menu each opened
// a stock `NSPopover`: system arrow, system corner radius, system opaque
// chrome, hanging off a radius-18 floating bar. The audit's words: "stock
// popover chrome ... next to radius-18 floating glass reads as system UI
// poking through the theme - the same class of mismatch the audit history
// spent phases removing from buttons". Its preferred fix, option (a), is a
// detachable borderless panel styled like the ⌘K palette - radius 16, raised
// elevation, no arrow, anchored under the control - which is the pattern
// Raycast and Linear use and, more to the point, the one this app had already
// proven works here.
//
// **So this is `UnifiedSearchController`'s panel recipe, extracted.** The
// window flags, the `isOpaque = false` + clear background that lets a corner
// radius actually read on a titled `NSPanel`, the window-owned shadow, and the
// local+global outside-click monitor pair are all that file's, lifted into one
// type rather than copied a third and fourth time. What is new here is only
// what a *dropdown* needs and a centred palette does not: anchoring under a
// control, and not fighting its own trigger button.
//
// **Three things that are easy to get wrong, written down because each cost
// something to find:**
//
//   1. **The shadow has to be the window's**, not a layer shadow on the
//      content view. The content view clips (that is what makes the radius
//      read), and a layer shadow inside a clipped view is drawn inside its own
//      mask - i.e. invisible. `hasShadow` is the only mechanism that puts a
//      shadow outside a rounded window.
//   2. **The outside-click monitor must ignore clicks on the trigger.** A
//      local `NSEvent` monitor sees the click *before* it is dispatched, so
//      without this a second click on the bell would close the panel and then
//      let the bell's own action immediately reopen it - a dropdown that
//      cannot be closed by clicking the thing that opened it. `UnifiedSearch`
//      never hit this because ⌘K has no on-screen trigger.
//   3. **Trailing-aligned, not leading-aligned.** Every control that opens one
//      of these sits within ~200pt of the window's trailing edge, and these
//      panels are 172-360pt wide; leading-aligning them would hang most of
//      each panel off the right of the screen before the clamp pulled it back.
//
// **The lock gate moves with the mechanism.** These were registered with
// `AppLockGate.registerLockDismissiblePopover`, which exists because an
// `NSPopover` tracks its own shown state and ordering its window out behind
// its back leaves it permanently broken. A panel has no such state, so these
// register as secondary windows instead - the same call the ⌘K palette, Quick
// Capture and the Host Editor already make, for the same reason (a panel is
// its own window, layered above the lock overlay, and the 12h session-expiry
// lock fires mid-use).

import AppKit

/// A titled-but-chromeless `NSPanel` that closes on Escape.
///
/// `cancelOperation` rather than a `keyDown` override: Escape reaches a window
/// through the responder chain as a cancel action, and an override here
/// catches it whatever inside the panel happens to hold focus.
final class HelmBarPanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Keep the frame this panel was given.
    ///
    /// AppKit constrains an ordinary window on the way to the screen so its
    /// titlebar stays reachable - correct for a document window, wrong for a
    /// dropdown, which it drags away from the control it is supposed to be
    /// attached to. `HelmBarPanel.position(under:)` already does its own
    /// screen-aware clamping (and flips the panel *above* the control rather
    /// than sliding it over the control, which is what AppKit's own rule would
    /// effectively do), so this hands back what it was asked for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class HelmBarPanel {

    /// §6.11's palette radius, which B5 asks these to match.
    static let cornerRadius: CGFloat = HelmMetrics.dSurface
    /// The gap between the trigger control's bottom edge and the panel's top.
    /// `HelmMetrics.s2` is the same step the bar uses between its own icons.
    static let gapBelowAnchor: CGFloat = HelmMetrics.s2
    /// Keep the panel this far inside the screen's visible frame when the
    /// anchor sits near an edge.
    static let screenMargin: CGFloat = 8

    let panel: HelmBarPanelWindow
    let content: NSViewController

    /// Fired after the panel closes, whichever way it closed - so an owner can
    /// keep its own "is it open" state honest without polling.
    var onClose: (() -> Void)?

    private weak var anchor: NSView?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var themeToken: ThemeObservation?

    init(content: NSViewController) {
        self.content = content
        panel = HelmBarPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 160),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        // Matches the ⌘K palette: an explicit outside click (or Escape, or the
        // trigger again) is what closes these, not the app losing focus - a
        // dropdown that vanished every time the captain glanced at another app
        // would lose whatever they were reading mid-sentence.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = content
        panel.onCancel = { [weak self] in self?.close() }

        // Audit §5.1: a panel is its own window, layered above the lock
        // overlay (which only covers the main window's own view tree), so one
        // left open when the 12h session lock fires would stay readable and
        // interactive over the lock screen. Weak, because there is no
        // unregister.
        AppLockGate.shared.registerSecondaryWindow { [weak self] in self?.panel }

        _ = panel.followHelmTheme()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
    }

    deinit {
        removeClickMonitors()
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    var isShown: Bool { panel.isVisible }

    /// Resize to the content's own fitting size - the same call the popovers
    /// made through `NSPopover.contentSize`, so each panel controller's
    /// existing `onSizeChanged` wiring needs no change.
    func setContentSize(_ size: NSSize) {
        panel.setContentSize(size)
        if isShown, let anchor { position(under: anchor) }
    }

    func toggle(under anchor: NSView) {
        if isShown { close() } else { show(under: anchor) }
    }

    func show(under anchor: NSView) {
        self.anchor = anchor
        applyTheme(ThemeManager.shared.theme)
        panel.setContentSize(content.view.fittingSize)
        position(under: anchor)
        // Key, not merely ordered front: every row in these panels is a
        // `HoverHighlightView`, whose tracking area is `.activeInKeyWindow`,
        // so a non-key panel would render rows that never highlight. The ⌘K
        // palette makes the same call for the same reason.
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
    }

    func close() {
        guard isShown else { return }
        panel.orderOut(nil)
        removeClickMonitors()
        onClose?()
    }

    // MARK: Placement

    private func position(under anchor: NSView) {
        guard let anchorWindow = anchor.window else { return }
        let inWindow = anchor.convert(anchor.bounds, to: nil)
        let onScreen = anchorWindow.convertToScreen(inWindow)
        let size = panel.frame.size

        // Trailing-aligned under the control - see this file's header for why
        // that is the right edge to pin.
        var origin = NSPoint(x: onScreen.maxX - size.width,
                             y: onScreen.minY - Self.gapBelowAnchor - size.height)

        // The anchor's **own** screen, with no `NSScreen.main` fallback: an
        // anchor window on a second display must not have its dropdown yanked
        // onto the primary one, and a window that is on no screen at all (an
        // off-screen test fixture) wants no clamp rather than a clamp onto
        // whatever screen happens to be main.
        if let visible = anchorWindow.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + Self.screenMargin),
                           visible.maxX - size.width - Self.screenMargin)
            // A panel that would fall off the bottom flips above the control
            // rather than being clamped into it, which would cover the very
            // thing the captain just clicked.
            if origin.y < visible.minY + Self.screenMargin {
                origin.y = onScreen.maxY + Self.gapBelowAnchor
            }
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: Dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            // The trigger's own click must reach the trigger, or its toggle
            // reopens what this just closed - see the header.
            if let anchor = self.anchor, let anchorWindow = anchor.window,
               event.window === anchorWindow {
                let point = anchor.convert(event.locationInWindow, from: nil)
                if anchor.bounds.contains(point) { return event }
            }
            self.close()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        panel.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        // A titled `NSPanel` paints its own square background behind the
        // content view, so a corner radius on that view only reads once the
        // *window* stops drawing one. `UnifiedSearchController.applyTheme` has
        // the same pair, and for the same reason.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.invalidateShadow()

        guard let root = panel.contentView else { return }
        root.wantsLayer = true
        // The app's one card fill+border, at the palette's own radius - so
        // these read as the same surface as every other floating thing in the
        // app rather than as a fourth recipe. The border is not decoration on
        // three of the fourteen palettes (`chromeBackgroundHex ==
        // backgroundHex`), where it is the only thing separating the panel
        // from what is behind it.
        // Both radii, not just `cornerRadius`: `applyCardSurface` takes a
        // separate `daylightRadius` and defaults it to §6.5's card radius
        // (20), so passing only the first leaves the Daylight family rendering
        // a card corner where B5 asks for the palette's own 16.
        HelmCard.applyCardSurface(to: root, theme: theme,
                                  cornerRadius: Self.cornerRadius,
                                  daylightRadius: Self.cornerRadius)
        root.layer?.masksToBounds = true
    }

    #if FM_SELFTESTS
    var debugPanelWindow: NSWindow { panel }
    var debugAnchor: NSView? { anchor }
    var debugHasClickMonitors: Bool { localClickMonitor != nil && globalClickMonitor != nil }
    #endif
}
