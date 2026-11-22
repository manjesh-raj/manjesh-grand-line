// Grand Line - native macOS app.
//
// The hero header the Console's three AI surfaces share (`fm/grandline-
// popover-redesign`): Comp-1's Compose popover, Use-1's Claude usage popover
// and Sre-2's SRE Lead panel, picked on the console popovers board
// (`data/grand-line-console-popovers-sre-mockups/`).
//
// It is the hero gradient every hero card paints (`HelmHeroSurface`) with a
// tile, a title, one quiet line under it and a trailing slot for the
// surface's own controls. The three boards drew it the same way, so it is one
// view rather than three copies of the same constraints:
//
//   - `.white` tile: a white tile with the hero's deep stop as the glyph,
//     the board's `.tile.white` (Compose, SRE Lead).
//   - `.glass` tile: a translucent shade of the ink with an ink glyph and an
//     ink hairline, the board's `.tile.glass` (Claude usage).
//
// Callers put their controls in `trailing` and read `palette` / `ink` after
// `applyTheme(_:)` to paint them (a `HelmButton.heroInk`, a
// `HelmStatusPill.heroInk`, a ring's arc). `body` is an optional view under
// the title row, inside the gradient (Claude usage's three rings).

import AppKit

final class PopoverHeroHeader: NSView {

    enum TileStyle { case white, glass }

    static let titleSize: CGFloat = 15
    static let subtitleSize: CGFloat = 11.5
    static let subtitleAlpha: CGFloat = 0.86
    static let glassFillAlpha: CGFloat = 0.2
    static let glassBorderAlpha: CGFloat = 0.3

    private let hero = HelmHeroSurface()
    private let tile = NSView()
    private let glyph = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    /// Trailing controls, right-aligned on the title row.
    let trailing = NSStackView()
    private let tileStyle: TileStyle
    private let symbol: String
    private let tileSide: CGFloat
    private(set) var palette: HelmHeroSurface.Palette?

    /// The hero's text colour after the last `applyTheme(_:)`.
    var ink: NSColor { palette.map { HelmContrast.color($0.ink) } ?? .white }

    /// The deeper of the two stops: what a white tile's glyph takes, and what
    /// a popover's arrow is closest to at the top edge.
    var deepStop: NSColor {
        guard let palette else { return .black }
        let darker = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
            ? palette.start : palette.end
        return HelmContrast.color(darker)
    }

    init(symbol: String, tileStyle: TileStyle, tileSide: CGFloat = 32,
         insets: NSEdgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 13, right: 14),
         body: NSView? = nil, bodySpacing: CGFloat = 12) {
        self.symbol = symbol
        self.tileStyle = tileStyle
        self.tileSide = tileSide
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(hero)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = tileSide >= 30 ? 9 : 8
        tile.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyDown
        tile.addSubview(glyph)

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.subtitleSize))
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let words = NSStackView(views: [titleLabel, subtitleLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 0
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)
        words.setHuggingPriority(.defaultLow, for: .horizontal)

        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = HelmMetrics.s2
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)

        // Gotcha (10): `.fill`, with only the words free to give way.
        let row = NSStackView(views: [tile, words, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        var constraints = [
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            hero.topAnchor.constraint(equalTo: topAnchor),
            hero.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.widthAnchor.constraint(equalToConstant: tileSide),
            tile.heightAnchor.constraint(equalToConstant: tileSide),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            row.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
        ]
        if let body {
            body.translatesAutoresizingMaskIntoConstraints = false
            addSubview(body)
            constraints += [
                body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
                body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
                body.topAnchor.constraint(equalTo: row.bottomAnchor, constant: bodySpacing),
                body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            ]
        } else {
            constraints.append(row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom))
        }
        NSLayoutConstraint.activate(constraints)
        tile.setContentHuggingPriority(.required, for: .horizontal)
        tile.setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.toolTip = subtitle
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    func applyTheme(_ theme: HelmTheme) {
        let palette = HelmHeroSurface.palette(for: theme)
        self.palette = palette
        hero.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        // A white-ink hero is a dark surface, so a control on it resolves the
        // dark appearance's system colours (a spinner, a focus ring).
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        titleLabel.textColor = ink
        subtitleLabel.textColor = ink.withAlphaComponent(Self.subtitleAlpha)
        let glyphColor: NSColor
        switch tileStyle {
        case .white:
            tile.layer?.backgroundColor = NSColor.white.cgColor
            tile.layer?.borderWidth = 0
            glyphColor = deepStop
        case .glass:
            tile.layer?.backgroundColor = ink.withAlphaComponent(Self.glassFillAlpha).cgColor
            tile.layer?.borderColor = ink.withAlphaComponent(Self.glassBorderAlpha).cgColor
            tile.layer?.borderWidth = 1
            glyphColor = ink
        }
        glyph.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(tileSide * 0.47),
                                       weight: .semibold, hierarchicalColor: glyphColor)
    }

    #if FM_SELFTESTS
    var debugGradientColors: [CGColor] { hero.debugGradientColors }
    var debugTileFill: CGColor? { tile.layer?.backgroundColor }
    #endif
}
