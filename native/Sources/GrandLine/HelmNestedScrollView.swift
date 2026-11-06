// Grand Line - native macOS app.
//
// A scroll view that sits inside a page that already scrolls.
//
// AppKit has no scroll chaining between nested scroll views. A wheel or
// trackpad event goes to the innermost `NSScrollView` under the pointer, and
// a plain one keeps it even when its document fits and there is nothing to
// scroll. So a card whose list lives in its own scroll view becomes a dead
// zone for the page around it: the page scrolls over the margins and stops
// the moment the pointer crosses the card. That shipped twice - Home's Needs
// Attention list, and every `HelmDataTable` with `sizesToFitRows` (Setup >
// Updates' Tools card, GitHub Sync's forks, the Tasks page's tables).
//
// This one keeps its events while it really has rows below the fold, and
// hands them to the next responder - the page - when it does not.

import AppKit

class HelmNestedScrollView: NSScrollView {
    /// Whether a wheel event here belongs to the page rather than this view:
    /// true when the whole document already fits vertically.
    var forwardsWheelToPage: Bool {
        (documentView?.frame.height ?? 0) <= contentView.bounds.height + 0.5
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsWheelToPage {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
