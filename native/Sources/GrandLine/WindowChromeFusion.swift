// Grand Line - native macOS app.
//
// `WindowChromeFusion` - a transparent, title-less titlebar for a utility
// window whose own content runs edge to edge under the traffic lights (the
// Host editor's teal ribbon, F2a).
//
// **History.** This file used to do far more. A1 of the UI modernization
// audit fused the *main* window's titlebar into the floating bar: it hid the
// title, then moved the traffic lights by hand onto the bar from a layout
// hook, cached their cluster rect per window and forwarded hit tests to them,
// because a relocated button falls outside its own superview and AppKit stops
// hit-testing it. UX-12 of the 2026-10 review retired all of that: the main
// window now has a visible system title (the module) and an `NSToolbar`, and
// its traffic lights stay where AppKit puts them (see `WorkspaceWindowChrome`
// in `WorkspaceShell.swift`). `docs/history/03-navigation-and-chrome.md` and
// `24-window-and-layout.md` keep the measurements in case anyone is tempted to
// move the lights again.
//
// What is left is the one thing a utility window still wants: full-size
// content with a transparent titlebar, while staying closable, minimisable and
// zoomable (unlike the two `NSPanel`s that hide all three buttons).

import AppKit

enum WindowChromeFusion {

    /// The traffic lights' top-down centre in a full-size-content window with
    /// no toolbar. Measured on a real `NSWindow`.
    static let naturalVerticalCenter: CGFloat = 16

    /// How far down a fused window's own content must start before it clears
    /// the traffic-light cluster: the cluster is ~14pt tall around the centre
    /// above, plus a row of breathing room. Derived from the centre so a
    /// future macOS that moves the cluster moves this with it.
    static var contentTopClearance: CGFloat { naturalVerticalCenter * 2 }

    /// Full-size content, a transparent titlebar, no title text - and the
    /// three window buttons still there.
    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = false
        }
    }

    static func isFullScreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen)
    }
}
