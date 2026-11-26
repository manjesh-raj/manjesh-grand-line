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
//
// **The verdict style** (Helm 10.4.0, the notifications panel's N-1 head,
// `data/grandline-notifications-hero-design-scout/`). A popover that leads
// with what is true now, as every page hero does, draws a kicker over the
// title and sets the title in the rounded display face. With a kicker the
// row is top-aligned, so the tile and the trailing slot sit level with the
// kicker rather than floating beside three lines.
//
// **The quiet-ink palette** is an option, `quietInk`. A header whose quiet
// lines must clear the text floor paints `palette(accent:quietInk:)`, as the
// hero columns do. On the plain palette the 86% subtitle falls under 4.5:1
// against the lighter stop (3.78:1 on Daylight and 3.91:1 on Dusk, measured
// by `NotificationBridgePanelSelfTest`'s sweep). `nil`, the default, keeps
// the plain palette. Every call site in the app passes it since full review 4
// (A-01), and `FM_RUN_CONTRAST_TESTS` fails a new one that does not.
//
// **Three more options for the menu-bar popover** (MB-1, Helm 10.4.0), all
// off by default. `titleSize` sets the verdict headline's point size: the
// popover is 330pt wide with a ring and a gear beside the words, and at 21pt
// "2 of 6 done today" (177pt) did not fit the 168pt they leave. `setSymbol(_:)` changes the tile's glyph
// (the padlock while the app is locked), and `setBodyHidden(_:)` takes the
// body out of the head (the tabs, which a locked popover does not show).

import AppKit

final class PopoverHeroHeader: NSView {

    enum TileStyle { case white, glass }

    /// `.standard` is the Console surfaces' 15pt semibold title. `.verdict`
    /// is a page hero's headline: a kicker above it, and the title in the
    /// rounded display face.
    enum TitleStyle { case standard, verdict }

    static let titleSize: CGFloat = 15
    static let subtitleSize: CGFloat = 11.5
    static let subtitleAlpha: CGFloat = 0.86
    static let glassFillAlpha: CGFloat = 0.2
    static let glassBorderAlpha: CGFloat = 0.3
    /// `.verdict`'s headline size, in the rounded heavy face.
    static let verdictTitleSize: CGFloat = 21
    static let verdictSubtitleSize: CGFloat = 12

    private let hero = HelmHeroSurface()
    private let tile = NSView()
    private let glyph = NSImageView()
    let kickerLabel = NSTextField(labelWithString: "")
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    /// Trailing controls, right-aligned on the title row.
    let trailing = NSStackView()
    private let tileStyle: TileStyle
    private var symbol: String
    private let tileSide: CGFloat
    private let titleStyle: TitleStyle
    private let quietInk: CGFloat?
    private let titleSize: CGFloat?
    /// The body's own bottom pin and the title row's, exactly one active:
    /// a hidden view still holds its height in Auto Layout, so hiding the
    /// body alone would leave the head as tall as before (gotcha (17)'s
    /// footnote, two alternative constraints).
    private var bodyBottom: NSLayoutConstraint?
    private var rowBottomWithoutBody: NSLayoutConstraint?
    private weak var bodyView: NSView?
    private var kickerText = ""
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
         body: NSView? = nil, bodySpacing: CGFloat = 12,
         titleStyle: TitleStyle = .standard, quietInk: CGFloat? = nil, titleSize: CGFloat? = nil) {
        self.symbol = symbol
        self.tileStyle = tileStyle
        self.tileSide = tileSide
        self.titleStyle = titleStyle
        self.quietInk = quietInk
        self.titleSize = titleSize
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

        applyFonts()
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        kickerLabel.lineBreakMode = .byTruncatingTail
        kickerLabel.isHidden = titleStyle == .standard
        for label in [kickerLabel, titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let words = NSStackView(views: [kickerLabel, titleLabel, subtitleLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 0
        if titleStyle == .verdict {
            words.setCustomSpacing(2, after: kickerLabel)
            words.setCustomSpacing(3, after: titleLabel)
        }
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
        row.alignment = titleStyle == .verdict ? .top : .centerY
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
            bodyView = body
            let bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
            self.bodyBottom = bodyBottom
            rowBottomWithoutBody = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
            constraints += [
                body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
                body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
                body.topAnchor.constraint(equalTo: row.bottomAnchor, constant: bodySpacing),
                bodyBottom,
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

    /// The tile's glyph, repainted in the current ink.
    func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        paintGlyph()
    }

    /// Takes the body out of the head, or puts it back. The head closes up
    /// under the title row rather than keeping the body's room.
    func setBodyHidden(_ hidden: Bool) {
        guard let bodyView, let bodyBottom, let rowBottomWithoutBody else { return }
        bodyView.isHidden = hidden
        // Deactivate before activating, so the two pins never hold together.
        if hidden {
            bodyBottom.isActive = false
            rowBottomWithoutBody.isActive = true
        } else {
            rowBottomWithoutBody.isActive = false
            bodyBottom.isActive = true
        }
    }

    /// `.verdict`'s three lines. The kicker is drawn in capitals, as every
    /// kicker in the app is, and read in its own case.
    func set(kicker: String, title: String, subtitle: String) {
        kickerText = kicker
        paintKicker()
        set(title: title, subtitle: subtitle)
        setAccessibilityLabel([kicker, title, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func paintKicker() {
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerText.uppercased(),
            attributes: HelmType.kickerAttributes(color: ink.withAlphaComponent(Self.subtitleAlpha)))
    }

    /// Read again on every theme pass, so the interface text size reaches a
    /// header that outlives a change of it.
    private func applyFonts() {
        switch titleStyle {
        case .standard:
            titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .semibold)
            subtitleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.subtitleSize))
        case .verdict:
            titleLabel.font = HelmType.rounded(HelmType.scaled(titleSize ?? Self.verdictTitleSize), .heavy)
            subtitleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.verdictSubtitleSize))
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        let palette: HelmHeroSurface.Palette
        if let quietInk {
            palette = HelmHeroSurface.palette(accent: HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex)),
                                              quietInk: Double(quietInk))
        } else {
            palette = HelmHeroSurface.palette(for: theme)
        }
        self.palette = palette
        applyFonts()
        hero.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        // A white-ink hero is a dark surface, so a control on it resolves the
        // dark appearance's system colours (a spinner, a focus ring).
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        titleLabel.textColor = ink
        subtitleLabel.textColor = ink.withAlphaComponent(Self.subtitleAlpha)
        paintKicker()
        switch tileStyle {
        case .white:
            tile.layer?.backgroundColor = NSColor.white.cgColor
            tile.layer?.borderWidth = 0
        case .glass:
            tile.layer?.backgroundColor = ink.withAlphaComponent(Self.glassFillAlpha).cgColor
            tile.layer?.borderColor = ink.withAlphaComponent(Self.glassBorderAlpha).cgColor
            tile.layer?.borderWidth = 1
        }
        paintGlyph()
    }

    private func paintGlyph() {
        let glyphColor: NSColor
        switch tileStyle {
        case .white: glyphColor = deepStop
        case .glass: glyphColor = ink
        }
        glyph.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(tileSide * 0.47),
                                       weight: .semibold, hierarchicalColor: glyphColor)
    }

    #if FM_SELFTESTS
    var debugGradientColors: [CGColor] { hero.debugGradientColors }
    var debugTileFill: CGColor? { tile.layer?.backgroundColor }
    var debugSymbol: String { symbol }
    var debugBodyIsHidden: Bool { bodyView?.isHidden ?? true }
    #endif
}
