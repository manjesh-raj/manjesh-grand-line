// Grand Line - native macOS app.
//
// `HelmHeroColumn` - the hero's gradient as a page's column (Helm 6.8.0), the
// captain's H-4 (Health) and C-4 (Connections) picks on the page-redesign
// board (`data/grand-line-page-redesign-mockups/`).
//
// The Home hero cards put a verdict, a ring and a few figures on the gradient.
// The hero-column designs go further: the gradient becomes a 300pt column
// beside the page's content, and the page's own rows - Health's four buckets,
// Connections' recent hosts - sit on it in the hero's ink. So the column
// carries three things a hero card does not:
//
//   - **Rows on the gradient** (`HelmHeroRow`): a big rounded figure or a
//     translucent glyph tile, a title, a quiet second line and an optional
//     pill, with a hairline in the ink between rows.
//   - **Sections**: a small-caps title in the ink, with an optional count at
//     its trailing edge.
//   - **A foot**: whatever the page puts at the bottom of the column - ghost
//     pills, or a strip of figures - pushed to the column's foot when there
//     is room and scrolled to when there is not.
//
// **One colour rule.** The column paints `HelmHeroSurface` in a
// `HelmModuleCard.HeroTone` - the theme's accent, a fixed colour, or either
// dimmed for a stale reading - so it goes through exactly the palette rule
// the Home hero cards and the briefing hero do. Every word, rule, ring and
// control the column holds takes the palette's ink: rows, labels and rings
// are painted here, and a `HelmButton`, `HelmSearchField` or `HelmKPIStrip`
// handed in is given the ink through its own `heroInk`, so a ghost pill and a
// field on the gradient are the kit's own controls rather than lookalikes.
//
// **Two layouts.** `.column` fills the height its page gives it, with the
// sections at the top and the foot at the bottom, and scrolls inside the
// gradient when the window is too short - a column taller than its pane
// would otherwise be a floor on the window's height (gotcha (16)). `.band` is
// the same header and foot across the top of a narrow page, without the
// sections: a page whose column collapses (a narrow window, Toggle Sidebar)
// moves the same instance into its content and switches it to `.band`, so the
// verdict stays on screen.
//
// Not interactive itself: the gradient takes no clicks (`HelmHeroSurface`),
// and the only controls are the ones a page put on it.
//
// **1.1.0, for Secrets' column (S-3).** `HelmHeroNavRow` is a row the captain
// picks - a page's navigation on the gradient, with the selected row a pill in
// the ink - and `setRing(_:)` moves the header's ring in place, for a ring
// that counts down (the vault's auto-lock) without rebuilding the column every
// second.
//
// **1.2.0, for Dictation's split card (Dic-1).** `.panel` is the third layout:
// the gradient half of a `HelmHeroSplitCard`. The words at the hero card's
// title size on the left with the foot under them, and the hero's 86pt ring
// with its caption centred under it on the right - the same panel
// `HelmModuleCard`'s wide `.heroSplit` draws, but holding the page's own
// pills. Its body wraps to as many lines as it needs, because the panel is as
// tall as its card anyway. A ring can also be `isDimmed`, for a reading that
// is absent rather than low (a model not downloaded).
//
// **1.3.0, for Settings' split cards (Set-2).** A `.panel` can hold a page's
// own view in the ring's place (`Accessory`): Appearance's preview of the
// theme that is showing, with the theme's name under it in the quiet ink.

import AppKit

final class HelmHeroColumn: NSView {

    /// `.column` fills a page's column, `.band` goes across the top of a
    /// narrow page, and `.panel` is the gradient half of a split card.
    enum Layout: Equatable { case column, band, panel }

    /// A ring on the gradient, beside its caption.
    struct Ring: Equatable {
        /// 0...1 of the arc.
        let fraction: Double
        /// The centre label - "6/8".
        let label: String
        /// The words beside the ring. Up to two lines.
        let caption: String?
        /// What VoiceOver reads for the ring.
        let spoken: String
        /// `.warn` and `.bad` paint the arc in that state's colour lifted to
        /// read on the gradient; `.ok` and `.idle` paint it in the ink.
        let state: HelmModuleRowState
        /// 1.2.0: the whole ring at the quiet ink, for a reading that is
        /// absent rather than low - a model not downloaded, an engine off.
        var isDimmed: Bool = false
    }

    /// The column's own words, at its top.
    struct Header: Equatable {
        var symbol: String
        var kicker: String
        var headline: String
        var body: String?
        var ring: Ring?
    }

    /// 1.3.0: a page's own view in the ring's place on a `.panel`, with a
    /// caption under it in the quiet ink. The page paints the view and the
    /// column lays it out. A ring wins when both are set, and `.band` and
    /// `.column` draw no accessory.
    struct Accessory {
        let view: NSView
        let caption: String?
        /// What VoiceOver reads for the view.
        let spoken: String
    }

    /// A titled run of rows (or any views) on the gradient.
    struct Section {
        let title: String
        /// A short figure at the title's trailing edge ("3").
        var trailing: String?
        let views: [NSView]
    }

    // MARK: Metrics

    static let width: CGFloat = 300
    static let insets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
    static let bandInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
    static let headlineSize: CGFloat = 20
    static let bodySize: CGFloat = 12.5
    static let ringSide: CGFloat = 66
    static let bandRingSide: CGFloat = 54
    /// 1.2.0: `.panel`'s insets, its ring (the hero card's) and the width its
    /// caption wraps at under the ring.
    static let panelInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
    static let panelRingSide: CGFloat = HelmRingGauge.heroSide
    static let panelRingCaptionWidth: CGFloat = 120
    static let sectionTitleSize: CGFloat = 10.5
    static let cornerRadius: CGFloat = 14
    /// The ink's alpha for a section title, a row's second line and a quiet
    /// figure, as the board draws them.
    static let quietInkAlpha: CGFloat = 0.8
    static let ruleAlpha: CGFloat = 0.14
    static let tileFillAlpha: CGFloat = 0.2
    /// The column's colours for `tone` in `theme`: the hero's palette rule,
    /// deepened until the second lines clear the text floor too
    /// (`HelmHeroSurface.palette(accent:quietInk:)`).
    static func palette(for tone: HelmModuleCard.HeroTone, in theme: HelmTheme) -> HelmHeroSurface.Palette {
        let accent = tone.accent(in: theme)
        return HelmHeroSurface.palette(accent: tone.isDimmed ? HelmHeroSurface.dimmed(accent) : accent,
                                       quietInk: Double(quietInkAlpha))
    }

    // MARK: State

    private(set) var arrangement: Layout = .column
    private(set) var header = Header(symbol: "circle", kicker: "", headline: "", body: nil, ring: nil)
    private(set) var sections: [Section] = []
    private(set) var footViews: [NSView] = []
    private(set) var accessory: Accessory?
    private(set) var tone = HelmModuleCard.HeroTone(colour: .themeAccent)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private(set) var ink: NSColor = .white

    private let surface = HelmHeroSurface()
    /// `.column`: the content scrolls inside the gradient.
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let topStack = NSStackView()
    private let footStack = NSStackView()
    /// `.band`: the content sits straight on the gradient.
    private let bandStack = NSStackView()

    // The header's own views, built once and re-filled.
    private let kickerTile = NSView()
    private let kickerGlyph = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var ringGauge = HelmRingGauge(side: HelmHeroColumn.ringSide)
    private let ringCaption = NSTextField(wrappingLabelWithString: "")
    private let accessoryCaption = NSTextField(wrappingLabelWithString: "")
    /// Labels painted in the ink at full strength, and at `quietInkAlpha`.
    private var inkLabels: [NSTextField] = []
    private var quietLabels: [NSTextField] = []

    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildHeaderViews()
        buildColumnContainer()
        buildBandContainer()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: Content

    /// The column's words, its sections and its foot, in one call - a page
    /// re-renders the whole column from its state, the way every hero does.
    func configure(header: Header, sections: [Section], foot: [NSView], tone: HelmModuleCard.HeroTone,
                   accessory: Accessory? = nil) {
        self.header = header
        self.sections = sections
        self.footViews = foot
        self.tone = tone
        self.accessory = accessory
        rebuild()
    }

    /// 1.1.0: the header's ring, moved in place. A ring that comes or goes
    /// changes the column's shape, so that rebuilds; a ring that only moves
    /// re-fills the gauge and its caption.
    func setRing(_ ring: Ring?) {
        guard ring != header.ring else { return }
        let reshapes = (ring == nil) != (header.ring == nil)
            || (ring?.caption ?? "").isEmpty != (header.ring?.caption ?? "").isEmpty
        header.ring = ring
        guard !reshapes, let ring else {
            rebuild()
            return
        }
        ringGauge.configure(fraction: ring.fraction, text: ring.label)
        ringGauge.setSpokenLabel(ring.spoken)
        ringCaption.stringValue = ring.caption ?? ""
        applyTheme(theme)
    }

    func setArrangement(_ arrangement: Layout) {
        guard arrangement != self.arrangement else { return }
        self.arrangement = arrangement
        rebuild()
    }

    // MARK: Building

    private func buildHeaderViews() {
        kickerTile.wantsLayer = true
        kickerTile.layer?.cornerRadius = 6
        kickerTile.translatesAutoresizingMaskIntoConstraints = false
        kickerGlyph.translatesAutoresizingMaskIntoConstraints = false
        kickerGlyph.imageScaling = .scaleNone
        kickerTile.addSubview(kickerGlyph)
        NSLayoutConstraint.activate([
            kickerTile.widthAnchor.constraint(equalToConstant: 20),
            kickerTile.heightAnchor.constraint(equalToConstant: 20),
            kickerGlyph.centerXAnchor.constraint(equalTo: kickerTile.centerXAnchor),
            kickerGlyph.centerYAnchor.constraint(equalTo: kickerTile.centerYAnchor),
        ])
        kickerLabel.lineBreakMode = .byTruncatingTail
        // 1.1.0: one line, always - a long kicker in a band wrapped to two.
        kickerLabel.maximumNumberOfLines = 1
        kickerLabel.cell?.usesSingleLineMode = true
        kickerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kickerLabel.setAccessibilityElement(false)
        for (label, lines) in [(headlineLabel, 3), (bodyLabel, 3), (ringCaption, 2), (accessoryCaption, 2)] {
            label.isSelectable = false
            label.maximumNumberOfLines = lines
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        ringCaption.setAccessibilityElement(false)
        accessoryCaption.setAccessibilityElement(false)
    }

    private func buildColumnContainer() {
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        for stack in [topStack, footStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
        }
        footStack.spacing = HelmMetrics.s2
        addSubview(scroll)
        let insets = Self.insets
        // The document is at least as tall as the column, so the foot rests
        // at the column's foot; taller content scrolls. Its height hugs the
        // content just above the stack defaults (gotcha (16)'s "make the
        // child exactly fill its container" for the short case).
        let hug = document.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(251)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Gotcha (4): the clip view, never the scroll view.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            hug,
            topStack.topAnchor.constraint(equalTo: document.topAnchor, constant: insets.top),
            topStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
            topStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right),
            footStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
            footStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right),
            footStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -insets.bottom),
            footStack.topAnchor.constraint(greaterThanOrEqualTo: topStack.bottomAnchor, constant: HelmMetrics.s4),
        ])
    }

    private func buildBandContainer() {
        bandStack.orientation = .vertical
        bandStack.alignment = .leading
        bandStack.spacing = HelmMetrics.s3
        bandStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bandStack)
        let insets = Self.bandInsets
        bandLeading = bandStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left)
        bandTrailing = bandStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right)
        bandTop = bandStack.topAnchor.constraint(equalTo: topAnchor, constant: insets.top)
        NSLayoutConstraint.activate([bandLeading, bandTrailing, bandTop])
        bandBottom = bandStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        panelBottom = bandStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor,
                                                        constant: -Self.panelInsets.bottom)
        // Where nothing else decides the panel's height (a stacked split
        // card), it is its content's. Under the stack defaults, so a card
        // that pins the panel to its own height wins.
        panelHug = heightAnchor.constraint(equalToConstant: 0)
        panelHug.priority = NSLayoutConstraint.Priority(245)
    }

    /// The band container's edges, re-inset for `.panel`.
    private var bandLeading: NSLayoutConstraint!
    private var bandTrailing: NSLayoutConstraint!
    private var bandTop: NSLayoutConstraint!
    /// Active in `.band` and `.panel`, where the height is the content's.
    private var bandBottom: NSLayoutConstraint!
    /// 1.3.0: `.panel`'s bottom, which only bounds the content. A panel is
    /// as tall as its card, and an equality stretched the words' column so
    /// the pills sank to the foot of a tall card; now they stay under the
    /// words and the gradient takes the rest.
    private var panelBottom: NSLayoutConstraint!
    private var panelHug: NSLayoutConstraint!

    private static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// Lay the current content out for the current layout. Views a page
    /// handed in are re-parented, never copied.
    private func rebuild() {
        for stack in [topStack, footStack, bandStack] { Self.clear(stack) }
        inkLabels = [kickerLabel, headlineLabel, bodyLabel, ringCaption]
        quietLabels = []

        kickerGlyph.image = HelmSymbol.image(header.symbol, pointSize: 11, weight: .semibold)
        kickerLabel.stringValue = header.kicker.uppercased()
        headlineLabel.stringValue = header.headline
        bodyLabel.stringValue = header.body ?? ""
        bodyLabel.isHidden = (header.body ?? "").isEmpty

        let isBand = arrangement == .band
        let isPanel = arrangement == .panel
        scroll.isHidden = isBand || isPanel
        bandStack.isHidden = !(isBand || isPanel)
        let insets = isPanel ? Self.panelInsets : Self.bandInsets
        bandLeading.constant = insets.left
        bandTrailing.constant = -insets.right
        bandTop.constant = insets.top
        bandBottom.constant = -insets.bottom
        bandBottom.isActive = isBand
        panelBottom.isActive = isPanel
        panelHug.isActive = isPanel
        let headlineSize = isPanel ? HelmHeroCard.titleSize : isBand ? 17 : Self.headlineSize
        headlineLabel.font = .systemFont(ofSize: HelmType.scaled(headlineSize), weight: .bold)
        bodyLabel.font = .systemFont(ofSize: HelmType.scaled(isPanel ? HelmHeroCard.bodySize : Self.bodySize))
        kickerLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
        headlineLabel.maximumNumberOfLines = isBand ? 2 : 3
        // A panel is as tall as its card, so its body says all of itself.
        bodyLabel.maximumNumberOfLines = isPanel ? 0 : isBand ? 2 : 3

        let kickerRow = Self.row([kickerTile, kickerLabel], spacing: HelmMetrics.s2)
        let ringRow = header.ring.map(makeRingRow)

        if isPanel {
            // The words with the foot under them on the left, the ring with
            // its caption under it on the right, both from the top.
            let words = Self.column([kickerRow, headlineLabel, bodyLabel], spacing: HelmMetrics.s1 + 2)
            words.setCustomSpacing(HelmMetrics.s2 + 2, after: kickerRow)
            var left: [NSView] = [words]
            if !footViews.isEmpty {
                // The pills keep their own width: a stack's hugging is the
                // stack-level API (gotcha (12)), and without it the column's
                // leading alignment stretched a lone pill across the panel.
                let foot = Self.row(footViews, spacing: HelmMetrics.s2, alignment: .centerY)
                foot.setHuggingPriority(.required, for: .horizontal)
                for view in footViews { view.setContentHuggingPriority(.required, for: .horizontal) }
                left.append(foot)
            }
            let leftColumn = Self.column(left, spacing: HelmMetrics.s4)
            words.widthAnchor.constraint(equalTo: leftColumn.widthAnchor).isActive = true
            var top: [NSView] = [leftColumn]
            if let trailing = ringRow ?? accessory.map(makeAccessoryColumn) { top.append(trailing) }
            add(Self.row(top, spacing: HelmMetrics.s5, alignment: .top), to: bandStack)
        } else if isBand {
            // Words on the left, the ring on the right, the foot under both.
            let words = Self.column([kickerRow, headlineLabel, bodyLabel], spacing: HelmMetrics.s1 + 2)
            var top: [NSView] = [words]
            if let ringRow { top.append(ringRow) }
            let headerRow = Self.row(top, spacing: HelmMetrics.s5, alignment: .centerY)
            add(headerRow, to: bandStack)
            if !footViews.isEmpty {
                let foot = Self.row(footViews, spacing: HelmMetrics.s2, alignment: .centerY)
                add(foot, to: bandStack, fills: false)
            }
        } else {
            add(kickerRow, to: topStack)
            topStack.setCustomSpacing(HelmMetrics.s2, after: kickerRow)
            add(headlineLabel, to: topStack)
            topStack.setCustomSpacing(HelmMetrics.s1 + 2, after: headlineLabel)
            if !bodyLabel.isHidden {
                add(bodyLabel, to: topStack)
            }
            if let ringRow {
                let last = topStack.arrangedSubviews.last
                add(ringRow, to: topStack)
                if let last { topStack.setCustomSpacing(HelmMetrics.s3 + 2, after: last) }
            }
            for section in sections {
                let last = topStack.arrangedSubviews.last
                let title = makeSectionTitle(section)
                add(title, to: topStack)
                if let last { topStack.setCustomSpacing(HelmMetrics.s4 + 2, after: last) }
                topStack.setCustomSpacing(HelmMetrics.s1 + 2, after: title)
                for (index, view) in section.views.enumerated() {
                    (view as? HelmHeroRow)?.showsTopRule = index > 0
                    (view as? HelmHeroNavRow)?.showsTopRule = index > 0
                    add(view, to: topStack)
                }
            }
            for view in footViews { add(view, to: footStack, fills: !(view is HelmButton)) }
        }
        setAccessibilityLabel([header.kicker, header.headline, header.body].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: ". "))
        applyTheme(theme)
        needsLayout = true
    }

    private func add(_ view: NSView, to stack: NSStackView, fills: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        if fills { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func makeRingRow(_ ring: Ring) -> NSView {
        let side: CGFloat
        switch arrangement {
        case .band: side = Self.bandRingSide
        case .panel: side = Self.panelRingSide
        case .column: side = Self.ringSide
        }
        if ringGauge.diameter != side { ringGauge = HelmRingGauge(side: side) }
        ringGauge.configure(fraction: ring.fraction, text: ring.label)
        ringGauge.setSpokenLabel(ring.spoken)
        ringCaption.stringValue = ring.caption ?? ""
        ringCaption.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        ringCaption.isHidden = (ring.caption ?? "").isEmpty
        quietLabels.append(ringCaption)
        inkLabels.removeAll { $0 === ringCaption }
        if arrangement == .panel {
            ringCaption.preferredMaxLayoutWidth = Self.panelRingCaptionWidth
            ringCaption.alignment = .center
            return Self.panelTrailingColumn([ringGauge, ringCaption])
        }
        ringCaption.preferredMaxLayoutWidth = arrangement == .band ? 120 : Self.width - Self.insets.left
            - Self.insets.right - side - HelmMetrics.s3
        ringCaption.alignment = .left
        return Self.row([ringGauge, ringCaption], spacing: HelmMetrics.s3, alignment: .centerY)
    }

    /// 1.3.0: the accessory and its caption, where a `.panel` puts its ring.
    private func makeAccessoryColumn(_ accessory: Accessory) -> NSView {
        accessory.view.translatesAutoresizingMaskIntoConstraints = false
        accessory.view.setAccessibilityElement(true)
        accessory.view.setAccessibilityRole(.image)
        accessory.view.setAccessibilityLabel(accessory.spoken)
        accessoryCaption.stringValue = accessory.caption ?? ""
        accessoryCaption.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        accessoryCaption.isHidden = (accessory.caption ?? "").isEmpty
        accessoryCaption.preferredMaxLayoutWidth = Self.panelRingCaptionWidth
        accessoryCaption.alignment = .center
        quietLabels.append(accessoryCaption)
        // The column hugs its views at the required priority, which pins
        // every one of them to the caption's width. A ring draws centred in
        // whatever it is given; a page's view keeps its own size, so it sits
        // centred in a host that takes the column's width instead.
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(accessory.view)
        NSLayoutConstraint.activate([
            accessory.view.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            accessory.view.topAnchor.constraint(equalTo: host.topAnchor),
            accessory.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            accessory.view.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor),
        ])
        return Self.panelTrailingColumn([host, accessoryCaption])
    }

    /// A `.panel`'s trailing column: a ring or an accessory, with its caption
    /// centred under it, never narrower than the caption's width.
    private static func panelTrailingColumn(_ views: [NSView]) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = HelmMetrics.s2
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.required, for: .horizontal)
        column.setClippingResistancePriority(.required, for: .horizontal)
        column.widthAnchor.constraint(greaterThanOrEqualToConstant: panelRingCaptionWidth).isActive = true
        return column
    }

    private func makeSectionTitle(_ section: Section) -> NSView {
        let title = NSTextField(labelWithString: section.title.uppercased())
        title.font = .systemFont(ofSize: HelmType.scaled(Self.sectionTitleSize), weight: .semibold)
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel(section.title)
        quietLabels.append(title)
        var views: [NSView] = [title]
        if let trailing = section.trailing {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            let collapse = spacer.widthAnchor.constraint(equalToConstant: 0)
            collapse.priority = .defaultLow
            collapse.isActive = true
            let count = NSTextField(labelWithString: trailing)
            count.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11.5), weight: .medium)
            count.setContentHuggingPriority(.required, for: .horizontal)
            quietLabels.append(count)
            views += [spacer, count]
        }
        return Self.row(views, spacing: HelmMetrics.s2, alignment: .centerY)
    }

    private static func row(_ views: [NSView], spacing: CGFloat,
                            alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = alignment
        row.spacing = spacing
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = spacing
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setClippingResistancePriority(.defaultLow, for: .horizontal)
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        return column
    }

    // MARK: Theme and layout

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = Self.palette(for: tone, in: theme)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        self.ink = ink
        // A white-ink hero is a dark surface: the controls on it take the
        // dark appearance, so a field's caret and selection, and any system
        // colour a control resolves, are the light ones.
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        kickerTile.layer?.backgroundColor = ink.withAlphaComponent(Self.tileFillAlpha).cgColor
        kickerGlyph.contentTintColor = ink
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue,
            attributes: HelmType.kickerAttributes(color: ink.withAlphaComponent(0.85)))
        for label in inkLabels where label !== kickerLabel { label.textColor = ink }
        for label in quietLabels { label.textColor = ink.withAlphaComponent(Self.quietInkAlpha) }
        if let ring = header.ring {
            let arc: NSColor
            switch ring.state {
            case .warn: arc = HelmHeroSurface.signalColor(tintHex: theme.ansiHex[3], on: palette)
            case .bad: arc = HelmHeroSurface.signalColor(tintHex: theme.ansiHex[1], on: palette)
            case .ok, .idle: arc = ink
            }
            // 1.2.0: a dimmed ring is the quiet ink throughout - its label
            // still clears the text floor, which is what the quiet palette
            // was deepened for.
            let quiet = ink.withAlphaComponent(Self.quietInkAlpha)
            ringGauge.trackColorOverride = ink.withAlphaComponent(ring.isDimmed ? 0.16 : 0.25)
            ringGauge.labelColorOverride = ring.isDimmed ? quiet : ink
            ringGauge.valueColorOverride = ring.isDimmed ? quiet : arc
            ringGauge.applyTheme(theme, hue: .blue)
        }
        for section in sections { for view in section.views { Self.applyInk(ink, to: view) } }
        for view in footViews { Self.applyInk(ink, to: view) }
        // A selected nav row is a pill in the ink, so its words take the stop
        // furthest from the ink: the deep one under white ink, the light one
        // under a dark ink (a very pale colour).
        let deep = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
            ? palette.start : palette.end
        let pillWords = HelmContrast.color(darkInk ? palette.lighterStop : deep)
        for section in sections {
            for case let row as HelmHeroNavRow in section.views { row.applyInk(ink, selectedInk: pillWords) }
        }
    }

    /// Hand the ink to the kit controls a page put on the gradient, and to
    /// the rows. Anything else is left as the page built it.
    static func applyInk(_ ink: NSColor, to view: NSView) {
        switch view {
        case let row as HelmHeroRow:
            row.applyInk(ink)
        case let row as HelmHeroNavRow:
            row.applyInk(ink)
        case let button as HelmButton:
            button.heroInk = ink
        case let field as HelmSearchField:
            field.heroInk = ink
        case let strip as HelmKPIStrip:
            strip.heroInk = ink
        default:
            for sub in view.subviews { applyInk(ink, to: sub) }
        }
    }

    override func layout() {
        super.layout()
        // Gotcha (22): the headline and body wrap at a width these labels do
        // not decide - the column's own, less its insets, and in a band less
        // the ring's column.
        let insets: NSEdgeInsets
        switch arrangement {
        case .band: insets = Self.bandInsets
        case .panel: insets = Self.panelInsets
        case .column: insets = Self.insets
        }
        var width = bounds.width - insets.left - insets.right
        if arrangement == .band, header.ring != nil {
            width -= Self.bandRingSide + HelmMetrics.s3 + 120 + HelmMetrics.s5
        }
        if arrangement == .panel, header.ring != nil || accessory != nil {
            width -= max(Self.panelRingSide, Self.panelRingCaptionWidth) + HelmMetrics.s5
        }
        width = max(120, floor(width))
        for label in [headlineLabel, bodyLabel] where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
        // 1.1.0: a column a page narrows below `width` wraps its ring's
        // caption at the room it really has beside the ring.
        if arrangement == .column, header.ring != nil, bounds.width > 0 {
            let caption = max(60, floor(bounds.width - insets.left - insets.right - Self.ringSide - HelmMetrics.s3))
            if abs(ringCaption.preferredMaxLayoutWidth - caption) > 0.5 {
                ringCaption.preferredMaxLayoutWidth = caption
                ringCaption.invalidateIntrinsicContentSize()
            }
        }
    }

    #if FM_SELFTESTS
    var debugHeadline: String { headlineLabel.stringValue }
    var debugBody: String? { bodyLabel.isHidden ? nil : bodyLabel.stringValue }
    var debugKicker: String { header.kicker }
    var debugRing: HelmRingGauge? { header.ring == nil ? nil : ringGauge }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugHeadlineLabel: NSTextField { headlineLabel }
    var debugBodyLabel: NSTextField { bodyLabel }
    var debugRows: [HelmHeroRow] { sections.flatMap(\.views).compactMap { $0 as? HelmHeroRow } }
    var debugSectionTitles: [String] { sections.map(\.title) }
    var debugScroll: NSScrollView { scroll }
    var debugFootButtons: [HelmButton] { footViews.compactMap { $0 as? HelmButton } }
    /// 1.3.0: the accessory's caption as drawn, or nil when none is drawn.
    var debugAccessoryCaption: NSTextField? {
        arrangement == .panel && header.ring == nil && accessory != nil ? accessoryCaption : nil
    }
    #endif
}

// MARK: - A row on the gradient

/// One row in a `HelmHeroColumn`: a leading figure or glyph tile, a title, a
/// quiet second line and an optional trailing control, with a hairline in the
/// ink above it when it follows another row.
final class HelmHeroRow: NSView {

    enum Leading: Equatable {
        /// A big rounded figure - a bucket's count. `quiet` draws it at the
        /// quiet ink, for a zero that is not the news.
        case figure(String, quiet: Bool)
        /// A glyph in a translucent tile, the kicker's own recipe.
        case symbol(String)
        case none
    }

    static let minimumHeight: CGFloat = 36
    static let figureSize: CGFloat = 22
    static let tileSide: CGFloat = 22

    var showsTopRule = false {
        didSet { rule.isHidden = !showsTopRule }
    }

    let leading: Leading
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    private(set) var trailing: NSView?
    private let rule = NSView()
    private let figureLabel = NSTextField(labelWithString: "")
    private let tile = NSView()
    private let glyph = NSImageView()

    init(leading: Leading, title: String, subtitle: String?, subtitleIsCode: Bool = false,
         subtitleTruncation: NSLineBreakMode = .byTruncatingTail, trailing: NSView? = nil) {
        self.leading = leading
        self.trailing = trailing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.isHidden = true
        addSubview(rule)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        subtitleLabel.font = subtitleIsCode
            ? .monospacedSystemFont(ofSize: HelmType.scaled(11), weight: .regular)
            : .systemFont(ofSize: HelmType.scaled(11))
        subtitleLabel.lineBreakMode = subtitleTruncation
        subtitleLabel.toolTip = subtitle
        for label in [titleLabel, subtitleLabel] {
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
        }
        let words = NSStackView(views: [titleLabel, subtitleLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = HelmMetrics.s0
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)
        words.setHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = []
        switch leading {
        case let .figure(text, _):
            figureLabel.stringValue = text
            figureLabel.font = HelmType.rounded(HelmType.scaled(Self.figureSize), .bold)
            figureLabel.alignment = .center
            figureLabel.setContentHuggingPriority(.required, for: .horizontal)
            figureLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            figureLabel.setAccessibilityElement(false)
            figureLabel.translatesAutoresizingMaskIntoConstraints = false
            figureLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
            views.append(figureLabel)
        case let .symbol(name):
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 6
            tile.translatesAutoresizingMaskIntoConstraints = false
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.imageScaling = .scaleNone
            glyph.image = HelmSymbol.image(name, pointSize: 11, weight: .semibold)
            tile.addSubview(glyph)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
                tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
                glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])
            views.append(tile)
        case .none:
            break
        }
        views.append(words)
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(trailing)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s2
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
        ])

        // One element with words; a trailing control stays its own.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        var spoken: [String] = []
        if case let .figure(text, _) = leading { spoken.append(text) }
        spoken.append(title)
        if let subtitle, !subtitle.isEmpty { spoken.append(subtitle) }
        setAccessibilityLabel(spoken.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func accessibilityChildren() -> [Any]? { trailing.map { [$0] } }

    func applyInk(_ ink: NSColor) {
        rule.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.ruleAlpha).cgColor
        titleLabel.textColor = ink
        subtitleLabel.textColor = ink.withAlphaComponent(HelmHeroColumn.quietInkAlpha)
        if case let .figure(_, quiet) = leading {
            figureLabel.textColor = quiet ? ink.withAlphaComponent(0.6) : ink
        }
        tile.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.tileFillAlpha).cgColor
        glyph.contentTintColor = ink
        if let trailing { HelmHeroColumn.applyInk(ink, to: trailing) }
    }

    #if FM_SELFTESTS
    var debugFigure: String? {
        if case let .figure(text, _) = leading { return text }
        return nil
    }
    var debugFigureColor: NSColor? { figureLabel.textColor }
    #endif
}

// MARK: - A row the captain picks

/// 1.1.0: a navigation row on the gradient - Secrets' kinds and collections
/// in its hero column (S-3). A glyph, a title and a count, all in the ink; the
/// selected row is a pill in the ink with its words in the hero's own deep
/// colour, the board's "white pill".
///
/// A `HoverHighlightView`, so it is a real button to VoiceOver and the
/// keyboard, with the focus ring and Return and Space (GL-16). A press runs
/// `onSelect` with the row's id; the page decides what is selected and says
/// so with `isSelected`, so a selection is never the row's own guess.
final class HelmHeroNavRow: HoverHighlightView {

    static let height: CGFloat = 34
    /// The ink's share of a row under the pointer.
    static let hoverAlpha: CGFloat = 0.12
    static let glyphSide: CGFloat = 16

    let id: String
    var onSelect: ((String) -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            paint()
        }
    }

    var showsTopRule = false {
        didSet { paint() }
    }

    private let rule = NSView()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var ink: NSColor = .white
    /// What the selected pill's words are drawn in: the hero's deeper stop,
    /// so the pill reads as a cut-out of the gradient.
    private var selectedInk: NSColor = .black

    init(id: String, symbol: String, title: String) {
        self.id = id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = 8
        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = HelmSymbol.image(symbol, pointSize: 12, weight: .semibold)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11.5), weight: .medium)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        for label in [titleLabel, countLabel] { label.setAccessibilityElement(false) }
        for view in [rule, glyph, titleLabel, countLabel] as [NSView] { addSubview(view) }
        // The pill spans the column's content width plus its own inset
        // either side, so its words line up with the section title's.
        let inset = HelmMetrics.s2
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HelmType.scaled(Self.height)),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: HelmMetrics.s2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: HelmMetrics.s2),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        onAccessibilityPress = { [weak self] in self?.pressed() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        accessibilityLabelOverride = title
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { pressed() }

    private func pressed() { onSelect?(id) }

    /// The row's count, or none.
    func setCount(_ text: String?) {
        countLabel.stringValue = text ?? ""
        countLabel.isHidden = (text ?? "").isEmpty
        accessibilityValueOverride = text.map { "\($0)" }
    }

    /// The column's ink, and the deeper of its two stops for the selected
    /// pill's words.
    func applyInk(_ ink: NSColor, selectedInk: NSColor? = nil) {
        self.ink = ink
        if let selectedInk { self.selectedInk = selectedInk }
        paint()
    }

    private func paint() {
        rule.isHidden = !showsTopRule || isSelected
        rule.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.ruleAlpha).cgColor
        if isSelected {
            normalColor = ink
            hoverColor = ink
            titleLabel.textColor = selectedInk
            countLabel.textColor = selectedInk.withAlphaComponent(0.8)
            glyph.contentTintColor = selectedInk
        } else {
            normalColor = .clear
            hoverColor = ink.withAlphaComponent(Self.hoverAlpha)
            titleLabel.textColor = ink
            countLabel.textColor = ink.withAlphaComponent(HelmHeroColumn.quietInkAlpha)
            glyph.contentTintColor = ink
        }
        accessibilityValueOverride = [isSelected ? "selected" : nil, countLabel.isHidden ? nil : countLabel.stringValue]
            .compactMap { $0 }.joined(separator: ", ")
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugCount: String { countLabel.isHidden ? "" : countLabel.stringValue }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugFill: NSColor { normalColor }
    #endif
}
