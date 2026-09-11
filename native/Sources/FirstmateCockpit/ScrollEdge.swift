// Manjesh Grand Line - native macOS app.
//
// `ScrollEdgeObserver` - A3 of the UI modernization audit
// (`data/grandline-ui-modernization-audit/report.md` §3A): "a shared 'scroll
// edge' behavior on the drill header/bar: transparent at rest, hairline +
// slight material once `scrollView.contentView.bounds.origin.y > 0`. One
// observer in the shell, all pages inherit."
//
// **"All pages inherit" is the requirement, so this discovers rather than
// asks.** The obvious seam would be a protocol beside `DaylightDrillActions`
// (`var pageScrollView: NSScrollView? { get }`), and it was rejected: a
// survey of the 24 mounted destinations found **zero** of them expose their
// page scroll view - 9 hold it in a `private let`, 8 in a
// `private var ...!` assigned inside `loadView`, and the rest have several
// siblings or none at all. A protocol would therefore mean editing ~17
// controllers, and - worse - a destination added later would silently opt
// out of the treatment by doing nothing. Walking the showing destination's
// own view tree costs one shallow search per navigation and cannot be
// forgotten.
//
// **What counts as a page scroll view**, and why the test is geometric: a
// scroll view pinned to the destination's own top edge is the one whose
// content passes under the chrome. A page whose top is a static strip - a
// tab row (Hosts, Setup), a toolbar (Console, Tools, Docs), a session card
// (Kubernetes) - has nothing sliding under the bar, and correctly gets no
// edge. That also excludes the Sticky Board's corkboard, which is a 2-D
// canvas inside a card rather than a top-anchored page scroll, and where
// `origin.y > 0` would mean something else entirely.
//
// **`origin.y > 0` is only right for a flipped document.** The report's
// literal test holds for the `FlippedView` documents this app's pages use,
// and inverts for a non-flipped one (an `NSTableView`'s own document is
// bottom-up, so scrolled-to-top is its *maximum* `origin.y`). `isScrolled`
// asks "is this away from its own top edge" and handles both.

import AppKit

final class ScrollEdgeObserver {

    /// Fired only when the answer actually changes, so a caller can animate
    /// the transition without re-animating on every scroll event.
    var onChange: ((Bool) -> Void)?

    /// `true` once any watched scroll view has moved off its own top edge.
    private(set) var isScrolled = false

    /// How far a scroll view's top edge may sit below the destination's own
    /// top and still count as "the page scroll". A page pins its scroll view
    /// with `topAnchor == root.topAnchor`; the tolerance only absorbs
    /// rounding.
    static let topTolerance: CGFloat = 4

    /// Ignore sub-pixel jitter, and treat a rubber-banded overscroll above
    /// the top (negative on a flipped document) as "at rest".
    static let offsetThreshold: CGFloat = 0.5

    private var watched: [NSScrollView] = []

    init() {}

    deinit { stopWatching() }

    /// Point the observer at whatever is showing. Safe to call on every
    /// navigation; a `nil` destination clears the state.
    func observe(destination: NSView?) {
        stopWatching()
        guard let destination else {
            update(force: true)
            return
        }
        watched = Self.pageScrollViews(in: destination)
        for scroll in watched {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        update(force: true)
    }

    /// Watch one specific scroll view, rather than discovering a
    /// destination's own.
    ///
    /// D5(a) asks for the same scroll-edge treatment "at the top of each
    /// card's list", and a card's list is *not* pinned to its destination's
    /// top edge - which is exactly what `pageScrollViews(in:)` looks for, and
    /// correctly so for A3's own job. Rather than grow a second observer, the
    /// same class takes an explicit target: one definition of "is this away
    /// from its own top edge", one notification subscription, one `onChange`
    /// contract.
    func observe(scrollView: NSScrollView?) {
        stopWatching()
        guard let scrollView else {
            update(force: true)
            return
        }
        watched = [scrollView]
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        update(force: true)
    }

    /// Re-read the current offsets without re-discovering the scroll views -
    /// for a caller that changed something the observer cannot see (a page
    /// that just replaced its content, a theme rebuild).
    func refresh() { update(force: false) }

    private func stopWatching() {
        for scroll in watched {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        watched = []
    }

    @objc private func boundsChanged() { update(force: false) }

    private func update(force: Bool) {
        let next = watched.contains { Self.isScrolled($0) }
        guard force || next != isScrolled else { return }
        let changed = next != isScrolled
        isScrolled = next
        if changed || force { onChange?(next) }
    }

    /// Is this scroll view away from its own top edge?
    ///
    /// A flipped document (every `FlippedView`-backed page in this app)
    /// counts up from its top, so the report's own `origin.y > 0` is exactly
    /// right. A non-flipped document counts up from its *bottom*, so
    /// scrolled-to-top is the clip view's maximum offset and the test has to
    /// be the mirror of it.
    static func isScrolled(_ scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        if document.isFlipped {
            return clip.bounds.origin.y > offsetThreshold
        }
        return (document.bounds.maxY - clip.bounds.maxY) > offsetThreshold
    }

    /// Every scroll view in `destination`'s subtree whose top edge sits at
    /// the destination's own top edge - see this file's header.
    ///
    /// Depth-first and pruning: once a scroll view qualifies, its own
    /// subtree is not searched, so a nested table inside a page scroll never
    /// double-counts.
    static func pageScrollViews(in destination: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let scroll = sub as? NSScrollView {
                    let top = destination.convert(scroll.bounds, from: scroll).minY
                    // `destination` is whatever the shell mounted; its own
                    // coordinate space may be flipped or not, so measure the
                    // distance to whichever edge is visually the top.
                    let distanceFromTop = destination.isFlipped
                        ? top
                        : destination.bounds.maxY - destination.convert(scroll.bounds, from: scroll).maxY
                    if distanceFromTop <= topTolerance {
                        found.append(scroll)
                        continue
                    }
                }
                walk(sub)
            }
        }
        walk(destination)
        return found
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var watchedForTests: [NSScrollView] { watched }
    #endif
}
