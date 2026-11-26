// Grand Line - native macOS app.
//
// The tap target over a scene gate: the lock screen's lighthouse, and the
// Secrets page's chest and padlock. One class for the three, since full
// review 4 (A-02) found both copies had the same gap.
//
// **Clicks never move focus.** A click on the tower or the chest leaves the
// password field first responder, because both gates are typing-first: the
// first key always reaches the field. So the view refuses first responder
// while a mouse event is being dispatched (that is when `NSWindow` asks).
//
// **The keyboard can reach it.** Before A-02 the view refused first
// responder outright, so Tab never landed on it and nothing showed where the
// keyboard was. It now joins the key view loop, draws a real `.exterior`
// focus ring (GL-16), and Space or Return does what a click does. It is
// labelled by what pressing it does ("Light the lamp to sign in", "Open the
// chest to unlock"), not by what it is.
//
// The gate's own first-key monitor must stand aside while this view has
// focus, or Space would light the lamp through the monitor and then dim it
// again through `keyDown`. `isFocused(in:)` is what both monitors ask.

import AppKit

final class SceneGateHotspotView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// What VoiceOver says, and what the ring's owner is called: the action.
    var label = "" { didSet { setAccessibilityLabel(label) } }
    /// The focus ring's corner radius.
    var ringRadius: CGFloat = 12 { didSet { noteFocusRingMaskChanged() } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// True when the keyboard is on this target in `window`.
    static func isFocused(in window: NSWindow?) -> Bool {
        window?.firstResponder is SceneGateHotspotView
    }

    // MARK: Focus

    /// Not from a click: the password field keeps the keyboard. Everything
    /// else (Tab, Shift-Tab, a programmatic move) may focus it.
    override var acceptsFirstResponder: Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown?, .rightMouseDown?, .otherMouseDown?: return false
        default: return true
        }
    }

    override var canBecomeKeyView: Bool { acceptsFirstResponder && !bounds.isEmpty }

    // GL-16: a focusable view draws a real exterior ring.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: ringRadius, yRadius: ringRadius).fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        noteFocusRingMaskChanged()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: onClick?() // Return, Space, keypad Enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    #if FM_SELFTESTS
    func debugClick() { onClick?() }
    #endif
}
