// Manjesh Grand Line - native macOS app.
//
// D5 of the UI modernization audit
// (`data/grandline-ui-modernization-audit/report.md` §3D, "Tables and
// scrolling"): "keep the architecture; add (a) scroll-edge hairline/blur at
// the top of each card's list (A3), (b) subtle row-entrance stagger on first
// load (30ms/row, capped, `HelmMotion`-gated) ..., (c) leave scrollbars stock
// - modern macOS overlay scrollers are already right, and custom scrollbars
// are a web-app tell to avoid."
//
// (c) is a decision to change nothing, and is honoured by this file existing
// for the other two and touching no scroller anywhere.
//
// Both helpers are deliberately *additive*: a list that does not call them
// renders exactly as it did, which is what keeps this finding's blast radius
// to the lists that actually opted in.

import AppKit

/// D5(a): a hairline that appears at the top of a card's list once that list
/// has scrolled away from its own top edge.
///
/// Reuses `ScrollEdgeObserver` rather than adding a second mechanism - the
/// finding says so explicitly, and that class already owns the one definition
/// of "is this away from its own top edge" (including the flipped/unflipped
/// document distinction, which is easy to get backwards).
final class HelmScrollEdgeHairline {

    static let thickness: CGFloat = 1
    static let fadeDuration: TimeInterval = 0.14

    private let line = NSView()
    private let observer = ScrollEdgeObserver()
    private var themeToken: ThemeObservation?

    /// Installs the hairline across the top of `target`, inside `container`,
    /// **driven by the caller** rather than by a scroll view of its own.
    ///
    /// M2 of the UI modernization audit (§3M): "give Monaco's page the same
    /// scroll-edge hairline treatment as native pages". Monaco has no
    /// `NSScrollView` - it scrolls inside a `WKWebView` - so there is nothing
    /// for `ScrollEdgeObserver` to watch, and the page reports its own offset
    /// over the JS bridge instead. Everything else about the treatment (the
    /// geometry, the token, the fade, the Reduce Motion gate) is the same
    /// code, which is the point of this initializer existing rather than a
    /// second hairline being written next to it.
    init(atTopOf target: NSView, in container: NSView) {
        install(over: target, in: container)
    }

    /// Set the hairline's state from outside - the externally-driven
    /// counterpart of the observer's own `onChange`.
    func setScrolled(_ scrolled: Bool) { setVisible(scrolled) }

    /// Installs the hairline across the top of `scrollView`, inside
    /// `container` (the card body, so the line spans the card rather than the
    /// clip view's scrolled content).
    init(over scrollView: NSScrollView, in container: NSView) {
        install(over: scrollView, in: container)
        observer.onChange = { [weak self] scrolled in self?.setVisible(scrolled) }
        observer.observe(scrollView: scrollView)
    }

    /// The half both initializers share: the line's geometry and its theming.
    private func install(over target: NSView, in container: NSView) {
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.alphaValue = 0
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            line.topAnchor.constraint(equalTo: target.topAnchor),
            line.heightAnchor.constraint(equalToConstant: Self.thickness),
        ])
        applyTheme(ThemeManager.shared.theme)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    func applyTheme(_ theme: HelmTheme) {
        line.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
    }

    private func setVisible(_ visible: Bool) {
        HelmMotion.fade(line, to: visible ? 1 : 0, duration: Self.fadeDuration, animated: true)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugIsVisible: Bool { line.alphaValue > 0.5 }
    var debugLine: NSView { line }
    #endif
}

/// D5(b): a subtle staggered entrance for a list's rows, on first load only.
///
/// **First load only, and that is the whole design.** A table re-renders on
/// every refresh, every theme change and every scroll that dequeues a cell;
/// replaying an entrance on any of those would make the list twitch
/// constantly, which is the opposite of the "the app is alive" feel this is
/// for. The owning list calls `reset()` when it genuinely has new content to
/// introduce, and nothing else replays.
enum HelmRowEntrance {

    /// The finding's own 30ms.
    static let perRowDelay: TimeInterval = 0.03
    /// "capped" - beyond this many rows the stagger stops accumulating, so a
    /// 50-row list does not spend a second and a half introducing itself.
    static let maxStaggeredRows = 8
    static let duration: TimeInterval = 0.22
    static let rise: CGFloat = 6

    /// Plays the entrance for one row, if this list is still in its first
    /// load. Safe to call for every row from `tableView(_:viewFor:row:)`.
    static func play(_ view: NSView, row: Int) {
        // `HelmMotion`'s rule: Reduce Motion gets the end state instantly,
        // which for an entrance means simply not playing one.
        guard !HelmMotion.isReduced else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let delay = Double(min(row, maxStaggeredRows)) * perRowDelay
        let begin = CACurrentMediaTime() + delay

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.beginTime = begin
        // Hold the "before" state during the delay, or every row would be
        // fully visible until its own animation started and the stagger would
        // be invisible.
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        // A table's rows live in a flipped document, so "rise" is downward in
        // layer terms there. Asking the view keeps this right either way.
        slide.fromValue = view.isFlipped ? -rise : rise
        slide.toValue = 0
        slide.duration = duration
        slide.beginTime = begin
        slide.fillMode = .backwards
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.add(fade, forKey: "entrance.fade")
        layer.add(slide, forKey: "entrance.slide")
    }
}
