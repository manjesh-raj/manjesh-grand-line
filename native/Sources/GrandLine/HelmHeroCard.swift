// Grand Line - native macOS app.
//
// The feel pass's hero (the Fable second-opinion review, Stage 1: "a gradient
// hero for the briefing with the ring gauge inside it"). One full-width card
// on the theme's accent, washed from a lighter corner to a deeper one, with a
// soft glow in the top-right.
//
// **The layout is the captain's Br-3 pick (Helm 9.4.0).** A kicker, a
// headline that wraps across the card's whole width, then one tile per fact:
// each briefing sentence is a tile labelled with the page it came from, and
// the services figure is a tile of its own with a small ring. Tiles fill the
// width in balanced rows (`rows(count:width:)`), so a wide card is used end to
// end and every line stays short. Up to two actions sit under the tiles.
//
// It replaced a one-line headline that truncated with an ellipsis, a text
// column capped at 560pt (the prototype's 62ch) that left the middle of a
// wide card empty, and a paragraph that dropped every sentence's link.
//
// **The gradient is the accent, and the ink is measured against it.** The
// prototype draws white text on the accent at 92% and the accent at 62%. On a
// pale accent (Ayu's amber, Alucard's pink) white would sit far under the
// text floor, so `palette(for:)` deepens both stops by the smallest step that
// lets white clear `HelmContrast.textTarget` against the *lighter* stop - the
// darker one then clears it by construction - and only where no deepening
// can do it does the ink step toward black instead. The rule is asserted for
// every theme the app ships (`FeelPassSelfTest`).
//
// **A tile's wash moves away from the ink**, never toward it: black under a
// white ink, white under a black one. A tile can then only ever raise the
// text's contrast over the gradient it sits on, so the palette rule above
// still holds inside every tile without a second measurement per theme.
//
// **The gradient and the glow are `HelmHeroSurface`'s** (1.0.2). The recipe
// and the palette rule moved there when two Home cards took the hero style,
// so this card and `HelmModuleCard` paint one copy of it.
//
// **The card is not a button.** A tile that points somewhere is a
// `HoverHighlightView` with its own click (role, focus ring and keyboard press
// come with it, GL-16), and the actions are real `HelmButton`s. The card
// itself takes no click, so nothing competes with them (gotcha (20)).

import AppKit

final class HelmHeroCard: NSView {

    /// The colours one hero is drawn in. The recipe lives on
    /// `HelmHeroSurface`, which a module card paints too.
    typealias Palette = HelmHeroSurface.Palette

    static var startLift: Double { HelmHeroSurface.startLift }
    static let insets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 28)
    static let titleSize: CGFloat = 22
    static let bodySize: CGFloat = 13.5
    /// The narrowest a tile may get before the row wraps to another.
    static let tileMinWidth: CGFloat = 200
    static let tileGap: CGFloat = 10
    /// The services tile's ring.
    static let tileRingSide: CGFloat = 40

    struct Content: Equatable {
        var kicker: String
        /// The headline. It wraps; it is never truncated.
        var title: String
        /// One per fact, in order.
        var tiles: [Tile]
        /// The services figure, drawn as the last tile. `nil` draws none.
        var ring: Ring?

        struct Tile: Equatable {
            /// The page the fact came from, as a kicker. `nil` draws the text
            /// alone.
            var label: String?
            var text: String
            /// The fact's hue, drawn as a dot before the label.
            var tint: HelmTint?
            /// Whether a click on the tile goes somewhere.
            var isLink: Bool
        }

        struct Ring: Equatable {
            var value: Int
            var total: Int
            /// The tile's kicker ("Health").
            var label: String
            /// The words after the count ("services healthy").
            var caption: String
            var isLink: Bool
        }
    }

    /// A fact tile was clicked, by its index in `Content.tiles`.
    var onActivateTile: ((Int) -> Void)?
    /// The services tile was clicked.
    var onActivateRing: (() -> Void)?

    /// The gradient and the glow - the one copy of the recipe.
    private let surface = HelmHeroSurface()
    private let kickerLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let grid = HelmHeroTileGrid()
    private let actionsRow = NSStackView()
    private let column = NSStackView()
    private var tileViews: [HelmHeroTile] = []
    private var ringTile: HelmHeroTile?
    private var content = Content(kicker: "", title: "", tiles: [], ring: nil)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Both wrap: `wrappingLabelWithString` is the constructor whose cell
        // wraps at all (gotcha (22)), and nothing caps the line count.
        for label in [kickerLabel, titleLabel] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            // Gotcha (5): the words give way, never the card.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .bold)

        actionsRow.orientation = .horizontal
        actionsRow.spacing = HelmMetrics.s2
        actionsRow.detachesHiddenViews = true
        // Hidden until `setActions` gives it a button. Home only calls that
        // when the titles change, and a row left visible but empty still
        // costs the column its spacing under the tiles.
        actionsRow.isHidden = true

        column.setViews([kickerLabel, titleLabel, grid, actionsRow], in: .top)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.setCustomSpacing(HelmMetrics.s1 + 2, after: kickerLabel)
        column.setCustomSpacing(HelmMetrics.s3 + 4, after: titleLabel)
        column.setCustomSpacing(HelmMetrics.s3 + 2, after: grid)
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        column.setClippingResistancePriority(.defaultLow, for: .horizontal)

        addSubview(column)
        let i = Self.insets
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right),
            column.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -i.bottom),
            // The headline and the tiles span the column; the kicker and the
            // actions keep their own widths at its leading edge.
            titleLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            kickerLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            grid.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    /// The words, the tiles and the ring.
    func configure(_ content: Content) {
        let tilesChanged = content.tiles.count != self.content.tiles.count
            || (content.ring == nil) != (self.content.ring == nil)
            || content.tiles.map(\.isLink) != self.content.tiles.map(\.isLink)
            || content.ring?.isLink != self.content.ring?.isLink
        self.content = content
        kickerLabel.stringValue = content.kicker.uppercased()
        kickerLabel.isHidden = content.kicker.isEmpty
        titleLabel.stringValue = content.title
        if tilesChanged { rebuildTiles() }
        for (tile, fact) in zip(tileViews, content.tiles) {
            tile.configure(label: fact.label, text: fact.text)
        }
        if let ring = content.ring, let ringTile {
            ringTile.configure(label: ring.label, text: "\(ring.value) of \(ring.total) \(ring.caption)")
            ringTile.ring?.configure(value: ring.value, total: ring.total)
            ringTile.ring?.setSpokenLabel("\(ring.value) of \(ring.total) \(ring.caption)")
        }
        grid.isHidden = grid.tiles.isEmpty
        setAccessibilityLabel(([content.kicker, content.title] + content.tiles.map(\.text)
            + [content.ring.map { "\($0.value) of \($0.total) \($0.caption)" }].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: ", "))
        applyTheme(theme)
        needsLayout = true
    }

    /// Up to two actions under the tiles, in order. A card with none shows
    /// no row at all.
    func setActions(_ buttons: [HelmButton]) {
        for view in actionsRow.arrangedSubviews {
            actionsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for button in buttons.prefix(2) {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionsRow.addArrangedSubview(button)
        }
        actionsRow.isHidden = buttons.isEmpty
    }

    /// New tile views only when the set of tiles changed shape, so a render
    /// that only changes words keeps the views it has (and their hover).
    private func rebuildTiles() {
        tileViews = content.tiles.enumerated().map { index, fact in
            let tile = HelmHeroTile(ringSide: nil)
            if fact.isLink { tile.setAction { [weak self] in self?.onActivateTile?(index) } }
            return tile
        }
        if let ring = content.ring {
            let tile = HelmHeroTile(ringSide: Self.tileRingSide)
            if ring.isLink { tile.setAction { [weak self] in self?.onActivateRing?() } }
            ringTile = tile
        } else {
            ringTile = nil
        }
        grid.tiles = tileViews + [ringTile].compactMap { $0 }
    }

    // MARK: The rows

    /// How many tiles go on each row: as few rows as the width allows, with
    /// the tiles spread evenly over them (earlier rows take any extra one), so
    /// five tiles at room for four read as three over two rather than four
    /// over a lone fifth. Every row fills the width.
    static func rows(count: Int, width: CGFloat,
                     minWidth: CGFloat = tileMinWidth, gap: CGFloat = tileGap) -> [Int] {
        guard count > 0 else { return [] }
        let fit = max(1, Int(floor((width + gap) / (minWidth + gap))))
        let rowCount = Int(ceil(Double(count) / Double(fit)))
        let base = count / rowCount
        let extra = count % rowCount
        return (0..<rowCount).map { $0 < extra ? base + 1 : base }
    }

    // MARK: The palette

    /// The hero's colours for `theme`. See `HelmHeroSurface` for the rule.
    static func palette(for theme: HelmTheme) -> Palette {
        HelmHeroSurface.palette(for: theme)
    }

    static func palette(accent: (Double, Double, Double)) -> Palette {
        HelmHeroSurface.palette(accent: accent)
    }

    /// A tile's wash: the colour away from the ink, at an alpha that reads as
    /// a frosted well. A white ink gets a black wash and a black ink a white
    /// one, so a tile only ever raises the text's contrast.
    static func tileWash(for palette: Palette, hovered: Bool = false) -> (rgb: (Double, Double, Double), alpha: Double) {
        let inkIsLight = HelmContrast.relativeLuminance(palette.ink) > 0.5
        let alpha = inkIsLight ? (hovered ? 0.24 : 0.16) : (hovered ? 0.42 : 0.30)
        return (inkIsLight ? (0, 0, 0) : (1, 1, 1), alpha)
    }

    // MARK: Theme and layout

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = Self.palette(for: theme)
        let ink = HelmContrast.color(palette.ink)
        let radius = HelmModuleCard.cornerRadius(for: theme)
        // The app's one gradient gate, as at every other gradient site
        // (`DaylightHardeningSelfTest` guards it): instant under Reduce
        // Motion, and a theme change is the window's own crossfade anyway.
        // The surface's own colour writes go through the same gate.
        HelmMotion.withoutImplicitAnimation {
            layer?.cornerRadius = radius
        }
        surface.apply(palette)
        // The kicker keeps the page's kicker recipe, in the hero's ink.
        kickerLabel.attributedStringValue = NSAttributedString(string: kickerLabel.stringValue,
                                                               attributes: HelmType.kickerAttributes(color: ink))
        titleLabel.textColor = ink
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .bold)
        let wash = Self.tileWash(for: palette)
        let hover = Self.tileWash(for: palette, hovered: true)
        let fill = HelmContrast.color(wash.rgb).withAlphaComponent(wash.alpha)
        let hoverFill = HelmContrast.color(hover.rgb).withAlphaComponent(hover.alpha)
        for (tile, fact) in zip(tileViews, content.tiles) {
            let dot = fact.tint.map { HelmHeroSurface.signalColor(tintHex: $0.hex(in: theme), on: palette) }
            tile.apply(ink: ink, fill: fill, hoverFill: hoverFill, dot: dot, theme: theme)
        }
        ringTile?.apply(ink: ink, fill: fill, hoverFill: hoverFill, dot: nil, theme: theme)
        // Item 2 of `ThemeManager`'s checklist: system-resolved colours in the
        // buttons follow the theme's mode, not the OS's.
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        // Gotcha (22): every wrap width comes from the card's own width, less
        // its insets - never from a label's own resolved frame.
        let width = max(120, floor(bounds.width - Self.insets.left - Self.insets.right))
        for label in [kickerLabel, titleLabel] where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
        grid.layoutWidth = width
    }

    #if FM_SELFTESTS
    var debugContent: Content { content }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugGradientColors: [CGColor] { surface.debugGradientColors }
    var debugRing: HelmRingGauge? { ringTile?.ring }
    var debugRingShown: Bool { ringTile != nil }
    var debugTiles: [HelmHeroTile] { tileViews }
    var debugRingTile: HelmHeroTile? { ringTile }
    var debugActionTitles: [String] { actionsRow.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    #endif
}

// MARK: - The tile grid

/// Lays the hero's tiles out in `HelmHeroCard.rows` - every row the full
/// width, every tile in a row as tall as the tallest. Frames, not
/// constraints: the arrangement changes with the width, and the height it
/// reports is derived from `layoutWidth`, which the card sets from its own
/// bounds (the same shape as a wrapping label's `preferredMaxLayoutWidth`).
final class HelmHeroTileGrid: NSView {

    var tiles: [HelmHeroTile] = [] {
        didSet {
            for tile in oldValue where !tiles.contains(where: { $0 === tile }) { tile.removeFromSuperview() }
            for tile in tiles where tile.superview !== self { addSubview(tile) }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var layoutWidth: CGFloat = 0 {
        didSet {
            guard abs(layoutWidth - oldValue) > 0.5 else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrangement(width: layoutWidth).height)
    }

    /// Re-measure when a tile's words change.
    func wordsChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let placed = arrangement(width: bounds.width > 1 ? bounds.width : layoutWidth)
        for (tile, frame) in zip(tiles, placed.frames) where tile.frame != frame {
            tile.frame = frame
        }
    }

    private func arrangement(width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        guard width > 0, !tiles.isEmpty else { return ([], 0) }
        let gap = HelmHeroCard.tileGap
        var frames: [NSRect] = []
        var y: CGFloat = 0
        var index = 0
        for count in HelmHeroCard.rows(count: tiles.count, width: width) {
            let tileWidth = floor((width - gap * CGFloat(count - 1)) / CGFloat(count))
            let row = tiles[index..<index + count]
            let height = ceil(row.map { $0.height(forWidth: tileWidth) }.max() ?? 0)
            var x: CGFloat = 0
            for (offset, _) in row.enumerated() {
                // The last tile takes the rounding, so the row ends on the edge.
                let w = offset == count - 1 ? width - x : tileWidth
                frames.append(NSRect(x: x, y: y, width: w, height: height))
                x += w + gap
            }
            y += height + gap
            index += count
        }
        return (frames, max(0, y - gap))
    }
}

// MARK: - One tile

/// A frosted well holding one fact: a dot and a kicker naming the page it
/// came from, then the sentence - or, with `ringSide`, a small ring before
/// the words. A tile that points somewhere is clickable through
/// `HoverHighlightView`, which supplies the button role, the focus ring and
/// the keyboard press; one that does not is plain text to VoiceOver.
final class HelmHeroTile: HoverHighlightView {

    static let padding = NSEdgeInsets(top: 11, left: 13, bottom: 12, right: 13)
    static let labelGap: CGFloat = 5
    static let dotSide: CGFloat = 7
    static let dotGap: CGFloat = 6
    static let ringGap: CGFloat = 12

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    let ring: HelmRingGauge?
    private var action: (() -> Void)?
    private var ink: NSColor = .white
    private var hasDot = false

    init(ringSide: CGFloat?) {
        ring = ringSide.map { HelmRingGauge(side: $0) }
        super.init(frame: .zero)
        // Placed by the grid's frames, not by constraints.
        translatesAutoresizingMaskIntoConstraints = true
        cornerRadius = 12
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        label.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byWordWrapping
        for view in [dot, label, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        if let ring {
            // The ring pins its own size with constraints; the tile places it.
            addSubview(ring)
            ring.translatesAutoresizingMaskIntoConstraints = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func setAction(_ action: @escaping () -> Void) {
        self.action = action
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        pressScale = 0.985
    }

    @objc private func clicked() { action?() }

    func configure(label words: String?, text sentence: String) {
        label.isHidden = words == nil
        label.stringValue = (words ?? "").uppercased()
        text.stringValue = sentence
        restyleLabel()
        (superview as? HelmHeroTileGrid)?.wordsChanged()
        needsLayout = true
    }

    func apply(ink: NSColor, fill: NSColor, hoverFill: NSColor, dot dotColor: NSColor?, theme: HelmTheme) {
        self.ink = ink
        normalColor = fill
        hoverColor = isActivatable ? hoverFill : fill
        layer?.borderColor = ink.withAlphaComponent(0.18).cgColor
        hasDot = dotColor != nil
        dot.isHidden = dotColor == nil || label.isHidden
        dot.layer?.backgroundColor = dotColor?.cgColor
        text.textColor = ink
        text.font = .systemFont(ofSize: HelmType.scaled(HelmHeroCard.bodySize))
        restyleLabel()
        if let ring {
            ring.valueColorOverride = ink
            ring.trackColorOverride = ink.withAlphaComponent(0.25)
            ring.labelColorOverride = ink
            ring.applyTheme(theme, hue: .blue)
        }
        needsLayout = true
    }

    private func restyleLabel() {
        label.attributedStringValue = NSAttributedString(string: label.stringValue,
                                                         attributes: HelmType.kickerAttributes(color: ink))
        dot.isHidden = !hasDot || label.isHidden
    }

    /// The words' left edge, past the ring when there is one.
    private var textLeft: CGFloat {
        Self.padding.left + (ring.map { $0.diameter + Self.ringGap } ?? 0)
    }

    private func textHeight(width: CGFloat) -> CGFloat {
        guard let cell = text.cell, !text.stringValue.isEmpty else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height)
    }

    private var labelHeight: CGFloat {
        guard !label.isHidden, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize.height)
    }

    /// The tile's height at `width`: the kicker, the gap and the wrapped
    /// sentence, or the ring when that is taller.
    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(40, width - textLeft - Self.padding.right)
        var words = textHeight(width: textWidth)
        if !label.isHidden { words += labelHeight + Self.labelGap }
        let ringHeight = ring?.diameter ?? 0
        return Self.padding.top + max(words, ringHeight) + Self.padding.bottom
    }

    override func layout() {
        super.layout()
        let left = textLeft
        let textWidth = max(40, bounds.width - left - Self.padding.right)
        let words = textHeight(width: textWidth) + (label.isHidden ? 0 : labelHeight + Self.labelGap)
        // Words sit at the top of a tile, so a row's tiles start level; a
        // ring tile centres its words against the ring.
        var y = Self.padding.top
        if let ring {
            ring.frame = NSRect(x: Self.padding.left, y: floor((bounds.height - ring.diameter) / 2),
                                width: ring.diameter, height: ring.diameter)
            y = max(Self.padding.top, floor((bounds.height - words) / 2))
        }
        if !label.isHidden {
            let lh = labelHeight
            var x = left
            if !dot.isHidden {
                dot.frame = NSRect(x: x, y: y + floor((lh - Self.dotSide) / 2), width: Self.dotSide, height: Self.dotSide)
                x += Self.dotSide + Self.dotGap
            }
            label.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - Self.padding.right), height: lh)
            y += lh + Self.labelGap
        }
        text.preferredMaxLayoutWidth = textWidth
        text.frame = NSRect(x: left, y: y, width: textWidth, height: textHeight(width: textWidth))
    }

    #if FM_SELFTESTS
    var debugText: String { text.stringValue }
    var debugLabel: String? { label.isHidden ? nil : label.stringValue }
    var debugTextLabel: NSTextField { text }
    var debugDotColor: NSColor? { dot.isHidden ? nil : dot.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    #endif
}
