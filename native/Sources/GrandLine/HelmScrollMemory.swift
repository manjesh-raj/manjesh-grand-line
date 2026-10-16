// Grand Line - native macOS app.
//
// P3 of the Grand Line vs Automic Vault polish report: fourteen pages reset
// their scroll position to the top on every visit, so going to Settings and
// back to Updates lost the captain's place on Updates every time. The report's
// rule is "keep each page's scroll position unless its data changed".
//
// **What "its data changed" means here, and why it is one signal for every
// page.** Each page loads differently (synchronously, off the main thread, on
// a poller), so a per-page "did my data change" flag would be fourteen
// definitions of the same question. The signal used instead is the scroll
// document's own height: a page whose content is the same height as when the
// captain left it gets its old offset back, and a page that grew or shrank -
// new rows, a section that appeared, a re-layout at a new window width - goes
// to the top as before. It is deliberately conservative: when in doubt, the
// page does what it always did.
//
// Two calls per page, both on the controller's own appearance hooks:
// `remember(_:)` from `viewWillDisappear` (which AppKit sends when the shell
// hides a page - measured) and `restore(_:otherwise:)` in place of the
// `scrollToTop()` its `viewWillAppear` already made.

import AppKit

final class HelmScrollMemory {

    private var left: (origin: NSPoint, documentHeight: CGFloat)?

    /// Note where the captain was. Call from `viewWillDisappear`.
    func remember(_ scroll: NSScrollView?) {
        guard let scroll, let document = scroll.documentView else { return }
        left = (scroll.contentView.bounds.origin, document.frame.height)
    }

    /// Put the captain back where they were if the page is the same height it
    /// was when they left, and otherwise run `scrollToTop` - the page's own,
    /// unchanged. Call where `viewWillAppear` used to call `scrollToTop()`,
    /// after the layout pass it already forces.
    func restore(_ scroll: NSScrollView?, otherwise scrollToTop: () -> Void) {
        defer { left = nil }
        guard let left, let scroll, let document = scroll.documentView,
              abs(document.frame.height - left.documentHeight) < 0.5 else {
            scrollToTop()
            return
        }
        scroll.contentView.scroll(to: left.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    #if FM_SELFTESTS
    var debugHasRemembered: Bool { left != nil }
    #endif
}
