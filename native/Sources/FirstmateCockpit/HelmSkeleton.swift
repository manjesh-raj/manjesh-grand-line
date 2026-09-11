// Manjesh Grand Line - native macOS app.
//
// `HelmSkeletonRow` - D3 of the UI modernization audit
// (`data/grandline-ui-modernization-audit/report.md` §3D): "21 stock
// `NSProgressIndicator` sites; pages show 'Loading open PRs…' text or a bare
// spinner mid-canvas; the stock spinner is the one grey system control left
// on every themed page. ... modern apps show layout-shaped placeholders
// (redacted rows, shimmering tiles) so the page arrives composed and content
// fades in."
//
// **What this is, and what it deliberately is not.** It is a placeholder in
// the *shape of the content that is coming* - so a page arrives already
// composed and the real rows land in the same geometry, rather than the page
// jumping from a centred spinner to a full list. It is not a progress
// indicator: it reports no fraction and makes no claim about how long
// anything will take, which is exactly right for the three fetches that use
// it (a `gh` sweep, a fleet snapshot, a `brew` check) since none of them can
// honestly report one.
//
// **The finding's own scope limit is kept**: "keep the tiny spinner only for
// inline button-level busyness". A spinner inside a button the captain just
// pressed is still a spinner here - it is feedback for *their own action*,
// not a stand-in for content. What changed is the page-level and
// status-column cases, where a spinner was standing in for a row that had
// not arrived yet.
//
// GL-14 rides along: a skeleton says "this has not arrived", never "this is
// empty". A page whose fetch *failed* must show its own failure state, not
// leave a skeleton shimmering forever - see `ReviewController`'s own
// `unavailable` branch.

import AppKit

/// One redacted row: a leading block for whatever badge the real row has,
/// then one or two bars where its text will be.
final class HelmSkeletonRow: NSView {

    /// Which shape of placeholder this is.
    enum Shape {
        /// A full list row - a badge block plus a title bar and a shorter
        /// meta bar. What Review and Overview show while fetching.
        case row
        /// A single small bar the size of a status pill. What a dense
        /// checklist row (Updates, GitHub Sync) shows in its status column
        /// while that one row is being checked.
        case pill
    }

    /// The shimmer's full sweep. Slow on purpose: a fast shimmer reads as a
    /// progress bar, which would be a claim this makes no attempt to honour.
    static let shimmerDuration: TimeInterval = 1.6
    static let cornerRadius: CGFloat = 4
    static let rowHeight: CGFloat = 44
    static let pillSize = NSSize(width: 74, height: 16)

    private let shape: Shape
    private var bars: [NSView] = []
    private let shimmer = CAGradientLayer()
    private var themeToken: ThemeObservation?

    init(shape: Shape = .row) {
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // A placeholder is not content: VoiceOver is told what is happening
        // once, here, rather than being handed a pile of nameless boxes.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Loading")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    private func build() {
        switch shape {
        case .pill:
            let bar = makeBar()
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.topAnchor.constraint(equalTo: topAnchor),
                bar.widthAnchor.constraint(equalToConstant: Self.pillSize.width),
                bar.heightAnchor.constraint(equalToConstant: Self.pillSize.height),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            bars = [bar]

        case .row:
            let badge = makeBar()
            let title = makeBar()
            let meta = makeBar()
            for v in [badge, title, meta] { addSubview(v) }
            badge.layer?.cornerRadius = 9
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Self.rowHeight),

                badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 26),
                badge.heightAnchor.constraint(equalToConstant: 26),

                title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
                title.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
                title.heightAnchor.constraint(equalToConstant: 10),
                // Proportional, so a skeleton on a wide page still reads as a
                // row rather than as a short stub floating at the left.
                title.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.42),

                meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
                meta.heightAnchor.constraint(equalToConstant: 8),
                meta.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.24),
            ])
            bars = [badge, title, meta]
        }

        layer?.addSublayer(shimmer)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        applyTheme(ThemeManager.shared.theme)
    }

    private func makeBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = Self.cornerRadius
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    override func layout() {
        super.layout()
        // A standalone (non view-backed) layer animates `frame` implicitly, so
        // a resize would otherwise slide the shimmer behind the instant
        // relayout of everything else.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = bounds
        CATransaction.commit()
        refreshShimmer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // GL-13: a placeholder for a page nobody is looking at must not keep
        // the compositor busy.
        refreshShimmer()
    }

    func applyTheme(_ theme: HelmTheme) {
        let fill = HelmField.fill(theme)
        for bar in bars { bar.layer?.backgroundColor = fill.cgColor }
        // The sweep is the *ink* at a low alpha over the same fill, so it
        // reads as a highlight passing across the bars rather than as a
        // second colour this component invented.
        let highlight = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.06)
        shimmer.colors = [fill.withAlphaComponent(0).cgColor, highlight.cgColor,
                          fill.withAlphaComponent(0).cgColor]
        shimmer.locations = [0, 0.5, 1]
        refreshShimmer()
    }

    /// Starts or stops the sweep. Reduce Motion gets the redacted bars and no
    /// movement at all - `HelmMotion`'s own rule: the end state, instantly,
    /// never the same motion slower.
    private func refreshShimmer() {
        let wanted = window != nil && !HelmMotion.isReduced && bounds.width > 0
        guard wanted else {
            shimmer.removeAllAnimations()
            shimmer.isHidden = true
            return
        }
        shimmer.isHidden = false
        guard shimmer.animation(forKey: "sweep") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -bounds.width
        sweep.toValue = bounds.width
        sweep.duration = Self.shimmerDuration
        sweep.repeatCount = .infinity
        shimmer.add(sweep, forKey: "sweep")
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugBarCount: Int { bars.count }
    var debugIsShimmering: Bool { !shimmer.isHidden && shimmer.animation(forKey: "sweep") != nil }
    #endif
}

/// A stack of `HelmSkeletonRow`s - what a page shows in place of the list it
/// is fetching.
///
/// A fixed, small count on purpose: the point is to shape the page, not to
/// guess how many rows are coming. Guessing would make the layout jump *more*
/// when the real answer arrives, which is the thing skeletons exist to avoid.
final class HelmSkeletonList: NSStackView {

    static let defaultRowCount = 3

    init(rows: Int = defaultRowCount) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = HelmMetrics.s2
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<max(1, rows) {
            let row = HelmSkeletonRow(shape: .row)
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Loading")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        for case let row as HelmSkeletonRow in arrangedSubviews { row.applyTheme(theme) }
    }
}
