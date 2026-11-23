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
// **The greeting can lead the card (2.1.0).** The captain's Hg-2 pick on
// the five-screen redesign board (`data/grandline-page-redesign-options/`):
// Home's "Good afternoon" left its own row on the page ground and became this
// card's title, so one card answers "how is my day". With a `greeting`, the
// card draws it in the page's display voice (`HelmType.heroTitle`) and the
// headline drops to a second line under it. A `status` is the day's verdict
// as a glass pill at the top right, its dot in the verdict's own colour. A
// card with neither draws exactly as 2.0.0 did.
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
    /// The headline's size when a greeting leads the card: a second line,
    /// not a second title.
    static let headlineUnderGreetingSize: CGFloat = 17
    /// The widest the verdict pill grows before its words wrap.
    static let statusMaxWidth: CGFloat = 340
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
        /// The page's greeting ("Good afternoon, Manjesh"), drawn above the
        /// headline in the display voice. `nil` keeps the headline as the
        /// card's title.
        var greeting: String? = nil
        /// The day's verdict, as a glass pill at the top right. `nil` draws
        /// none.
        var status: Status? = nil

        struct Status: Equatable {
            var text: String
            /// The verdict's colour, drawn as the pill's dot. `nil` draws the
            /// ink's own quiet dot: a verdict this page has not read yet.
            var tint: HelmTint?
        }

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
    private let greetingLabel = NSTextField(wrappingLabelWithString: "")
    private let statusPill = HelmHeroStatusPill()
    /// The kicker, the greeting and the headline, beside the verdict pill.
    private let textColumn = NSStackView()
    private let head = NSStackView()
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
        for label in [kickerLabel, greetingLabel, titleLabel] {
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

        greetingLabel.font = HelmType.heroTitle()
        greetingLabel.isHidden = true
        statusPill.isHidden = true

        for label in [kickerLabel, greetingLabel, titleLabel] { textColumn.addArrangedSubview(label) }
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = HelmMetrics.s1 + 2
        textColumn.detachesHiddenViews = true
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): stack-level priorities for a stack. The words take the
        // slack; the pill keeps its own width.
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        // Arranged, not gravity areas: under `.fill` the words are the one
        // flexible member (gotcha (10)).
        head.addArrangedSubview(textColumn)
        head.addArrangedSubview(statusPill)
        head.orientation = .horizontal
        head.alignment = .top
        head.distribution = .fill
        head.spacing = HelmMetrics.s4
        head.detachesHiddenViews = true
        head.translatesAutoresizingMaskIntoConstraints = false
        head.setHuggingPriority(.defaultLow, for: .horizontal)
        head.setClippingResistancePriority(.defaultLow, for: .horizontal)

        column.setViews([head, grid, actionsRow], in: .top)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.setCustomSpacing(HelmMetrics.s3 + 4, after: head)
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
            // The words and the tiles span the column, less the verdict pill
            // beside the words; the actions keep their own widths at its
            // leading edge.
            head.widthAnchor.constraint(equalTo: column.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            greetingLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            kickerLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
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
        greetingLabel.stringValue = content.greeting ?? ""
        greetingLabel.isHidden = (content.greeting ?? "").isEmpty
        titleLabel.stringValue = content.title
        statusPill.isHidden = content.status == nil
        if let status = content.status { statusPill.configure(text: status.text) }
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
        setAccessibilityLabel(([content.kicker, content.greeting ?? "", content.title, content.status?.text ?? ""]
            + content.tiles.map(\.text)
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
        greetingLabel.textColor = ink
        greetingLabel.font = HelmType.heroTitle()
        // Under a greeting the headline is the card's second line.
        titleLabel.font = greetingLabel.isHidden
            ? .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .bold)
            : .systemFont(ofSize: HelmType.scaled(Self.headlineUnderGreetingSize), weight: .semibold)
        let wash = Self.tileWash(for: palette)
        let hover = Self.tileWash(for: palette, hovered: true)
        let fill = HelmContrast.color(wash.rgb).withAlphaComponent(wash.alpha)
        let hoverFill = HelmContrast.color(hover.rgb).withAlphaComponent(hover.alpha)
        for (tile, fact) in zip(tileViews, content.tiles) {
            let dot = fact.tint.map { HelmHeroSurface.signalColor(tintHex: $0.hex(in: theme), on: palette) }
            tile.apply(ink: ink, fill: fill, hoverFill: hoverFill, dot: dot, theme: theme)
        }
        ringTile?.apply(ink: ink, fill: fill, hoverFill: hoverFill, dot: nil, theme: theme)
        let statusDot = content.status?.tint.map { HelmHeroSurface.signalColor(tintHex: $0.hex(in: theme), on: palette) }
        statusPill.apply(ink: ink, fill: fill, dot: statusDot ?? ink.withAlphaComponent(0.55))
        // Item 2 of `ThemeManager`'s checklist: system-resolved colours in the
        // buttons follow the theme's mode, not the OS's.
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        // Gotcha (22): every wrap width comes from the card's own width, less
        // its insets - never from a label's own resolved frame.
        let width = max(120, floor(bounds.width - Self.insets.left - Self.insets.right))
        // The pill's own width comes from its words, capped, never from the
        // words beside it; the words then wrap in what is left.
        var textWidth = width
        if !statusPill.isHidden {
            statusPill.maxWidth = min(Self.statusMaxWidth, floor(width * 0.45))
            textWidth = max(120, width - statusPill.fittingSize.width - head.spacing)
        }
        for label in [kickerLabel, greetingLabel, titleLabel] where abs(label.preferredMaxLayoutWidth - textWidth) > 0.5 {
            label.preferredMaxLayoutWidth = textWidth
            label.invalidateIntrinsicContentSize()
        }
        grid.layoutWidth = width
    }

    #if FM_SELFTESTS
    var debugContent: Content { content }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugGreetingLabel: NSTextField? { greetingLabel.isHidden ? nil : greetingLabel }
    var debugStatusPill: HelmHeroStatusPill? { statusPill.isHidden ? nil : statusPill }
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
/// The hero's verdict: a glass pill with a coloured dot and a few words, at
/// the card's top right (Hg-2). Not a control - the tiles and the actions are
/// the card's ways out - so it is one static-text element for VoiceOver.
///
/// Its wash is the tiles' own, so the words never read worse than on the
/// gradient (the file header's rule), and it carries a hairline in the ink so
/// it reads as a pill rather than a darker patch. Long words wrap inside it
/// at `maxWidth`; nothing is ever cut off.
final class HelmHeroStatusPill: NSView {

    static let height: CGFloat = 30
    static let dotSide: CGFloat = 8
    static let insets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 13)

    /// The widest the pill may grow; its words wrap inside this.
    var maxWidth: CGFloat = HelmHeroCard.statusMaxWidth {
        didSet {
            guard abs(maxWidth - oldValue) > 0.5 else { return }
            label.preferredMaxLayoutWidth = max(40, maxWidth - Self.insets.left - Self.dotSide - 8 - Self.insets.right)
            label.invalidateIntrinsicContentSize()
        }
    }

    private let dot = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 1
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = maxWidth - Self.insets.left - Self.dotSide - 8 - Self.insets.right
        label.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (5): a leaf view, so its content priorities hold the pill to
        // its words.
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        addSubview(dot)
        addSubview(label)
        let i = Self.insets
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            // Centred on the first line by the label's top, never by a
            // baseline: a baseline constraint in a hidden pill, which the
            // head's stack detaches, is lowered with no engine and throws.
            dot.topAnchor.constraint(equalTo: label.topAnchor,
                                     constant: floor((HelmType.scaled(13) * 1.25 - Self.dotSide) / 2)),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right),
            label.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -i.bottom),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(text: String) {
        label.stringValue = text
        setAccessibilityLabel(text)
        needsLayout = true
    }

    func apply(ink: NSColor, fill: NSColor, dot dotColor: NSColor) {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = ink.withAlphaComponent(0.28).cgColor
        label.textColor = ink
        dot.layer?.backgroundColor = dotColor.cgColor
    }

    override func layout() {
        super.layout()
        // A capsule on one line, a rounded card when the words wrap.
        layer?.cornerRadius = min(bounds.height / 2, Self.height / 2)
    }

    #if FM_SELFTESTS
    var debugText: String { label.stringValue }
    var debugDotColor: NSColor? { dot.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    var debugLabel: NSTextField { label }
    #endif
}

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
