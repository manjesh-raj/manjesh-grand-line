// Grand Line - native macOS app.
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
        /// S18: a web island's own shape while its bundle loads - a gutter
        /// and code lines (`editor`), a faint grid (`canvas`), a month of day
        /// cells (`monthGrid`). Drawn as one path sized to the island, so it
        /// fills whatever space the island will.
        case editor
        case canvas
        case monthGrid
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
    /// The island shapes' bars, as one path laid out from the bounds.
    private let islandLayer = CAShapeLayer()
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

        case .editor, .canvas, .monthGrid:
            layer?.addSublayer(islandLayer)
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
        islandLayer.frame = bounds
        islandLayer.path = Self.islandPath(shape, in: bounds, flipped: isFlipped)
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
        HelmMotion.withoutImplicitAnimation { islandLayer.fillColor = fill.cgColor }
        // The sweep is the *ink* at a low alpha over the same fill, so it
        // reads as a highlight passing across the bars rather than as a
        // second colour this component invented.
        let highlight = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.06)
        // Daylight Phase 6's rule, enforced by `DaylightHardeningSelfTest`: a
        // standalone (non view-backed) `CAGradientLayer` animates `colors`
        // implicitly, so a theme change would cross-fade every skeleton on
        // the page - motion nobody designed and nothing gated.
        HelmMotion.withoutImplicitAnimation {
            shimmer.colors = [fill.withAlphaComponent(0).cgColor, highlight.cgColor,
                              fill.withAlphaComponent(0).cgColor]
            shimmer.locations = [0, 0.5, 1]
        }
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

    // MARK: Island shapes

    /// The bars of an island shape, in `bounds`. Proportions follow the
    /// island each one stands in for: the editor's line widths vary the way
    /// code does, the canvas is a 32pt grid of hairlines, and the month is a
    /// header bar over five weeks of seven cells.
    static func islandPath(_ shape: Shape, in bounds: CGRect, flipped: Bool) -> CGPath? {
        let path = CGMutablePath()
        func rect(_ x: CGFloat, _ yFromTop: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = cornerRadius) {
            let y = flipped ? yFromTop : bounds.height - yFromTop - h
            guard w > 0, h > 0 else { return }
            let r = min(radius, w / 2, h / 2)
            path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r)
        }
        switch shape {
        case .editor:
            let widths: [CGFloat] = [0.42, 0.6, 0.3, 0.55, 0.7, 0.25, 0.5, 0.62, 0.35, 0.48, 0.2, 0.58, 0.4, 0.66]
            let gutter: CGFloat = 36, lineStep: CGFloat = 20
            var index = 0
            var top: CGFloat = 16
            while top + 8 < bounds.height && index < 60 {
                rect(12, top, 14, 8)
                rect(gutter + 12, top, (bounds.width - gutter - 24) * widths[index % widths.count], 8)
                top += lineStep
                index += 1
            }
        case .canvas:
            let step: CGFloat = 32
            var x = step
            while x < bounds.width { rect(x, 0, 1, bounds.height, radius: 0); x += step }
            var y = step
            while y < bounds.height { rect(0, y, bounds.width, 1, radius: 0); y += step }
        case .monthGrid:
            let gap: CGFloat = 8, columns = 7, weeks = 5
            let cell = (bounds.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            rect(gap, gap, bounds.width * 0.28, 14)
            let gridTop: CGFloat = 40
            let rowHeight = (bounds.height - gridTop - gap * CGFloat(weeks + 1)) / CGFloat(weeks)
            guard cell > 0, rowHeight > 0 else { return path }
            for week in 0..<weeks {
                for day in 0..<columns {
                    rect(gap + CGFloat(day) * (cell + gap), gridTop + gap + CGFloat(week) * (rowHeight + gap),
                         cell, rowHeight, radius: HelmMetrics.rControl)
                }
            }
        case .row, .pill:
            return nil
        }
        return path
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugBarCount: Int { bars.count }
    var debugShape: Shape { shape }
    var debugIslandPathIsEmpty: Bool { islandLayer.path?.isEmpty ?? true }
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

    // MARK: Islands (S18)

    /// How long a web island may take before the placeholder says so.
    static let stillLoadingAfter: TimeInterval = 5
    static let stillLoadingText = "Still loading. If this keeps happening, Copy diagnostics has the details."

    private var captionLabel: NSTextField?
    private var stillLabel: NSTextField?
    private var stillTimer: DispatchWorkItem?

    /// S18: a web island's loader - its own shape, shimmering (Reduce Motion
    /// aware), with the loading phrase under it, and after
    /// `stillLoadingAfter` a line saying where to look. An empty state says
    /// "nothing here"; this says "something is coming".
    init(island: HelmSkeletonRow.Shape, caption: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = HelmMetrics.s3
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false
        let shape = HelmSkeletonRow(shape: island)
        addArrangedSubview(shape)
        shape.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        shape.setContentHuggingPriority(.defaultLow, for: .vertical)
        let captionText = NSTextField(labelWithString: caption)
        let still = NSTextField(labelWithString: Self.stillLoadingText)
        still.isHidden = true
        for label in [captionText, still] {
            label.font = HelmType.caption()
            label.alignment = .center
            label.setContentHuggingPriority(.required, for: .vertical)
            addArrangedSubview(label)
        }
        captionLabel = captionText
        stillLabel = still
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Loading. \(caption)")
        applyTheme(ThemeManager.shared.theme)
        let item = DispatchWorkItem { [weak self] in self?.stillLabel?.isHidden = false }
        stillTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillLoadingAfter, execute: item)
    }

    deinit { stillTimer?.cancel() }

    func applyTheme(_ theme: HelmTheme) {
        for case let row as HelmSkeletonRow in arrangedSubviews { row.applyTheme(theme) }
        captionLabel?.textColor = HelmTheme.mutedInk(theme)
        stillLabel?.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugCaption: String? { captionLabel?.stringValue }
    var debugStillLoadingShown: Bool { stillLabel?.isHidden == false }
    func debugFireStillLoading() { stillTimer?.perform() }
    var debugIslandShape: HelmSkeletonRow.Shape? { (arrangedSubviews.first as? HelmSkeletonRow)?.debugShape }
    #endif
}

