// Grand Line - native macOS app.
//
// `FullScreenMenuBarFill` - the second half of A1's chrome fusion, and the one
// `WindowChromeFusion`'s header deliberately deferred ("Full screen is left
// entirely to AppKit").
//
// **The defect it fixes, measured rather than reasoned.** In a full-screen
// Space macOS does not hand the window the whole display. On this machine
// (1512x982 logical, notched) it hands it `1512x949` and keeps the top **33pt**
// for the menu bar - and with the captain's menu bar set to auto-hide
// (`_HIHideMenuBar = 1`) nothing is drawn there, so the strip renders solid
// black across the full width, directly above the floating bar. That is the
// captain-reported "black band at the very top of the window".
//
// It is **not** this app's doing, and that is measured too: a stock 40-line
// AppKit app built for this experiment gets the identical `1512x949` full-screen
// frame and the identical 33pt black strip above its own teal content, in three
// variants - plain `.titled`, `.fullSizeContentView` + transparent titlebar (this
// app's own shape), and one whose window delegate returns
// `[.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]` from
// `window(_:willUseFullScreenPresentationOptions:)`. All three: 949, black strip.
// `NSPrefersDisplaySafeAreaCompatibilityMode = false` in the bundle's plist
// changes nothing either. So a full-screen window cannot reach that strip, and
// every attempt to make it do so is a dead end - do not spend the afternoon
// there again. `docs/history/24-window-and-layout.md` has the full transcript.
//
// **So the strip is filled from outside the window.** A borderless,
// non-activating panel is placed over it, painted with the active theme's page
// ground, and shown only while the main window is actually in full screen. The
// app's ground then runs to the physical top edge of the display, which is what
// A1's "the floating bar becomes the top edge" was always supposed to look like.
//
// Three properties are load-bearing, and each is the answer to a way this could
// go wrong:
//
//   - **Above the menu bar window, and it has to be - which is the whole
//     reason this needs a hover rule at all.** The black is not "nothing
//     drawn": it is the Window Server's own menu bar window, layer 24
//     (`kCGMainMenuWindowLevel`), **opaque** and painted solid black while the
//     menu bar is hidden. Measured by capturing that window on its own
//     (`screencapture -l`): every pixel `(0, 0, 0, 255)`. A fill below it is
//     therefore invisible - the first attempt sat at level 23, painted the
//     right colour, and changed nothing on screen. So the panel is
//     `.statusBar` (25).
//   - **And therefore it must get out of the way on hover.** Sitting over the
//     menu bar window means that with the pointer at the top of the screen the
//     revealed menu bar would be behind an opaque panel. The panel carries a
//     tracking area: on `mouseEntered` it goes transparent *and*
//     `ignoresMouseEvents`, so the menu bar both shows and clicks; a short
//     poll - which exists only while the pointer is inside the strip, so the
//     idle cost is zero - restores it on the way out. The reveal is the
//     system's own, unchanged; only the paint underneath it moves.
//   - **The level is also what lets the panel sit in that strip at all, which
//     is not obvious and cost a round here.** AppKit silently constrains a
//     window's frame to sit *below* the menu bar - and stops doing so at
//     level 25. Measured, same proposal (`y 949...982`) through
//     `constrainFrameRect` on four windows: a `.titled` window at level 0, a
//     borderless one at level 0 and a borderless panel at 23 all come back
//     `y 917...949` - the right height, one strip too low - and only the
//     panel at 25 is left alone. So the first attempt, at level 23, was
//     invisible *and* misplaced for the same reason, and "the panel never
//     appeared" is the symptom of both.
//   - **Sized from the gap, never from a constant.** The height is whatever the
//     screen has above the window (`screen.frame.maxY - window.frame.maxY`), so
//     an external display with no notch, a different menu bar height, or a
//     future macOS that stops reserving anything at all all resolve correctly -
//     a zero or negative gap shows no panel at all.
//
// It observes the theme like any other painted surface (GL-24: it repaints, it
// never fetches).

import AppKit

final class FullScreenMenuBarFill {

    /// Just above `kCGMainMenuWindowLevel` (24) - see the header for why below
    /// it does not work.
    static let windowLevel = NSWindow.Level(rawValue: 25)

    /// The strip of `screen` that lies above `window`, or `nil` when there is
    /// none to fill.
    ///
    /// Pure, and separated out deliberately: every interesting case here is a
    /// question about two rectangles, and a rectangle is assertable without a
    /// full-screen Space (which no self-test can enter).
    static func stripFrame(windowFrame: NSRect, screenFrame: NSRect) -> NSRect? {
        let gap = screenFrame.maxY - windowFrame.maxY
        guard gap > 0.5 else { return nil }
        return NSRect(x: screenFrame.minX, y: windowFrame.maxY, width: screenFrame.width, height: gap)
    }

    private weak var window: NSWindow?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private let isWindowFullScreen: (NSWindow) -> Bool
    private let screenFrame: (NSWindow) -> NSRect?

    /// `isWindowFullScreen` and `screenFrame` are the two facts about the
    /// environment this cannot make true for itself: no self-test can enter a
    /// real full-screen Space, and none may put a panel on the captain's
    /// display. They default to the real window and are injected only by
    /// `FullScreenMenuBarFillSelfTest`, which then drives the **real**
    /// `update()`, builds the real panel and asserts its real level, frame and
    /// paint - see that file's header.
    init(window: NSWindow,
         isWindowFullScreen: @escaping (NSWindow) -> Bool = { $0.styleMask.contains(.fullScreen) },
         screenFrame: @escaping (NSWindow) -> NSRect? = { $0.screen?.frame }) {
        self.window = window
        self.isWindowFullScreen = isWindowFullScreen
        self.screenFrame = screenFrame
        let center = NotificationCenter.default
        // `object: window` on all three: this app opens other windows (the host
        // editor, the probe panels) and their own full-screen transitions say
        // nothing about this one.
        for name: NSNotification.Name in [NSWindow.didEnterFullScreenNotification,
                                          NSWindow.didExitFullScreenNotification,
                                          NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
        // GL-24: repaint, never fetch. Fires synchronously at registration,
        // which is harmless here - `update()` finds no full-screen window yet
        // and simply tears nothing down.
        _ = ThemeManager.shared.observe { [weak self] _ in self?.update() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        panel?.orderOut(nil)
    }

    /// Show, move, repaint or hide the fill to match the window's current state.
    /// Idempotent and cheap - safe to call from any of the triggers above.
    func update() {
        guard let window,
              isWindowFullScreen(window),
              let screen = screenFrame(window),
              let frame = Self.stripFrame(windowFrame: window.frame, screenFrame: screen) else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        panel.contentView?.layer?.backgroundColor =
            HelmTheme.nsColor(ThemeManager.shared.theme.backgroundHex).cgColor
        // Ordered relative to the main window rather than `orderFront`: the
        // panel belongs to this window's Space, and joining the front of
        // whatever is key would put it over another app.
        panel.order(.above, relativeTo: window.windowNumber)
        // A pointer already parked in the strip when full screen begins would
        // otherwise never produce a `mouseEntered`.
        setYielding(frame.contains(NSEvent.mouseLocation))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.level = Self.windowLevel
        panel.backgroundColor = .clear
        // `.stationary` keeps it still during a Mission Control swipe, and
        // `.fullScreenAuxiliary` is what lets a panel live in a full-screen
        // Space at all (AGENTS.md gotcha (7) is the same collection behaviour
        // for the opposite reason - there, to stop a window tiling into one).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = HoverRevealView()
        content.wantsLayer = true
        content.onHoverChanged = { [weak self] hovering in self?.setYielding(hovering) }
        panel.contentView = content
        return panel
    }

    // MARK: Yielding to a revealed menu bar

    /// `true` while the pointer is in the strip and the fill has stepped aside.
    private var isYielding = false
    private var yieldPoll: Timer?

    private func setYielding(_ yielding: Bool) {
        guard yielding != isYielding else { return }
        isYielding = yielding
        panel?.alphaValue = yielding ? 0 : 1
        panel?.ignoresMouseEvents = yielding
        yieldPoll?.invalidate()
        yieldPoll = nil
        guard yielding else { return }
        // Only alive while the pointer is actually in the strip: once the panel
        // ignores the mouse it can no longer be told that the pointer left, and
        // a standing timer for a state that is almost never true is exactly the
        // idle cost GL-13 exists to avoid.
        let poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.insetBy(dx: 0, dy: -2).contains(NSEvent.mouseLocation) {
                self.setYielding(false)
            }
        }
        // Audit 3.4: every repeating timer states a tolerance so the system may
        // coalesce its wake-ups. A quarter of the interval is plenty here - the
        // only thing this delays is the fill fading back in behind a pointer
        // that has already left the strip.
        poll.tolerance = 0.05
        yieldPoll = poll
    }

    /// The fill's own content view, which only exists to notice the pointer.
    private final class HoverRevealView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // `.activeAlways`: this panel is never the key window, and a
            // tracking area scoped to key/active state would never fire.
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    }

    #if FM_SELFTESTS
    /// The live panel, or `nil` while nothing is being filled. A suite reads
    /// its frame, level, alpha and painted colour off the real object rather
    /// than off a mirror of them.
    var debugPanel: NSPanel? {
        guard let panel, panel.isVisible else { return nil }
        return panel
    }

    /// The panel's own content view, so a suite can drive the same
    /// `mouseEntered`/`mouseExited` AppKit calls the tracking area delivers -
    /// the real entry point, not the helper behind it (AGENTS.md's `debug*`
    /// hook convention).
    var debugPanelContentView: NSView? { panel?.contentView }
    #endif
}
