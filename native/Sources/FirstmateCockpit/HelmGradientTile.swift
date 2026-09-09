// Manjesh Grand Line - native macOS app.
//
// `HelmGradientTile` - the Daylight icon tile (migration §6.2).
//
// Phase 1 of the Daylight migration ships this as a **primitive only**: no
// page constructs one yet. Phase 2's canvas modules and floating bar and
// Phase 4's drill headers are what wire it in.
//
// It replaces `IconTileView` on Daylight surfaces only. The two are different
// components on purpose, not one with a flag: `IconTileView` paints a *faint
// wash* of a hue with a same-hue glyph (and therefore routes through
// `HelmContrast.tintedSurface` to stay legible), while this paints the hue at
// full saturation as a **gradient** with a white glyph. Every surface not yet
// migrated keeps `IconTileView`, unchanged.

import AppKit

/// A rounded square carrying a domain hue's 135deg gradient with a centred
/// white SF Symbol.
///
/// Sizes are §6.2's three, and each one's radius comes from §2.6's scale
/// (`HelmMetrics.daylightRadii`) rather than a literal - `Size.cornerRadius`
/// is asserted against that set by `HelmContrastSelfTest`.
///
/// **Themes itself**, like `HelmCard` and `HelmButton`: it owns its own
/// `ThemeManager` observation and unregisters in `deinit`. A page must not set
/// its layer colours or its image's tint - the next theme change overwrites
/// them (this codebase's most-repeated bug class; see `ThemeManager.swift`'s
/// checklist).
final class HelmGradientTile: NSView {
    /// §6.2's three tile classes, each pinned to its own §2.6 radius and §4
    /// glyph point size.
    enum Size {
        /// The app logo dot.
        case logo
        /// A module header.
        case module
        /// A drill header or a card row.
        case drill
        /// An empty state's focal tile (Daylight §6.14's 40pt plate).
        case hero
        /// §6.11's ⌘K palette row tile.
        case palette

        var side: CGFloat {
            switch self {
            case .logo: return 22
            case .module: return 30
            case .drill: return 34
            case .hero: return 40
            case .palette: return 28
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .logo: return HelmMetrics.dLogoDot
            case .module: return HelmMetrics.dTileSmall
            case .drill: return HelmMetrics.dTileLarge
            // §2.6 names no radius for a 40pt tile; `dWell` (14) is the scale's
            // own next step up from `dTileLarge` (12) and keeps the set closed.
            case .hero: return HelmMetrics.dWell
            case .palette: return HelmMetrics.dTileSmall
            }
        }

        /// §4's point sizes: 13 on a 30pt tile, 14 on a 34pt tile. The 22pt
        /// logo dot takes 12, scaled from the same ratio.
        var glyphPointSize: CGFloat {
            switch self {
            case .logo: return 12
            case .module: return 13
            case .drill: return 14
            case .palette: return 13
            case .hero: return 17
            }
        }
    }

    private let imageView = NSImageView()
    private let gradient = CAGradientLayer()
    private let size: Size
    private var hue: HelmDomainHue = .blue
    /// A user-chosen literal hue, when this tile carries a record's own colour
    /// rather than an area of the app's - see `configure(symbol:literalHex:)`.
    private var literalHex: String?
    private var symbolName: String?
    /// Set by `configure(artwork:symbol:hue:)`. When non-nil the tile renders a
    /// full-colour raster asset edge to edge instead of an SF Symbol glyph
    /// centred on the gradient - see that method for why the gradient stays
    /// underneath rather than being removed.
    private var artwork: NSImage?
    /// The four constraints that pin the image view to the tile's own edges,
    /// activated only in artwork mode. Built once, because activating a
    /// constraint whose views share no ancestor traps and re-creating them per
    /// `configure` call would leave the old set dangling.
    private var artworkFill: [NSLayoutConstraint] = []
    private var themeToken: ThemeObservation?

    init(size: Size = .drill) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = size.cornerRadius
        // The gradient is its own sublayer rather than the view's backing
        // layer so the radius/mask live in one place and a caller can never
        // end up with a square gradient inside a rounded view.
        layer?.masksToBounds = true
        gradient.startPoint = HelmDomainHue.tileStart
        gradient.endPoint = HelmDomainHue.tileEnd
        gradient.cornerRadius = size.cornerRadius
        layer?.addSublayer(gradient)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.side),
            heightAnchor.constraint(equalToConstant: size.side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Built here, while the image view is genuinely in the tree, and left
        // inactive - the glyph path wants the image at its natural size,
        // centred, and only artwork mode fills the tile.
        artworkFill = [
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        // Both axes, per §6.2 - a tile in a dense row must never be the thing
        // that shrinks (AGENTS.md gotcha #5: these are *content* priorities,
        // which is correct here because an `NSView` with a fixed size
        // constraint does have an effective intrinsic size to defend, unlike
        // an `NSStackView` or a bare spacer).
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: axis)
            setContentCompressionResistancePriority(.required, for: axis)
        }

        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
        #if FM_SELFTESTS
        Self.debugLiveInstanceCount += 1
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    #if FM_SELFTESTS
    /// `fm/grandline-daylight-shell-regressions`: same live-instance counter
    /// convention as `HelmModuleCard.debugLiveInstanceCount`, to isolate
    /// whether a tile specifically (rather than its owning card) is what a
    /// suspected retention holds onto.
    static var debugLiveInstanceCount = 0
    #endif

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        #if FM_SELFTESTS
        Self.debugLiveInstanceCount -= 1
        #endif
    }

    /// Point the tile at a hue and an SF Symbol.
    ///
    /// A symbol that does not resolve is reported rather than silently
    /// rendering an empty tile - this codebase has shipped an invisible icon
    /// exactly that way before (`anchor`, which is not an SF Symbol at all).
    func configure(symbol: String, hue: HelmDomainHue) {
        self.hue = hue
        self.literalHex = nil
        self.symbolName = symbol
        setArtworkMode(nil)
        let configured = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.glyphPointSize, weight: .semibold))
        if configured == nil {
            AppLog.ui.error("HelmGradientTile: SF Symbol '\(symbol, privacy: .public)' did not resolve")
        }
        imageView.image = configured
        applyTheme(ThemeManager.shared.theme)
    }

    /// Convenience for a destination's own tile - §2.2's hue for that area of
    /// the app plus that destination's existing symbol.
    func configure(for destination: RailDestination) {
        configure(symbol: destination.symbol, hue: destination.domainHue)
    }

    /// Point the tile at a **literal** hue instead of a domain hue.
    ///
    /// Phase 4 slice 2 addition, for the one case §7 asks for by name: Hosts'
    /// "per-host gradient tiles from `Host.accentHex`". A saved host's accent
    /// is a colour the captain picked in the host editor - it is not an area
    /// of the app, so there is no `HelmDomainHue` that honestly describes it,
    /// and mapping it onto the nearest one would silently discard the choice.
    /// This is the same distinction `HelmAccentRow.Content.tintHex` already
    /// draws against its own semantic `tint`.
    ///
    /// The lighter end is derived exactly the way §2.8's fallback derives one
    /// for a non-Daylight palette's hue - `fallbackLightenFraction`, measured
    /// off Daylight's own seven pairs - so a per-host gradient reads in the
    /// same direction and at the same strength as a real §2.2 one. Nothing
    /// theme-dependent: a literal hue is literal in all thirteen palettes,
    /// which is the whole point of the field it comes from.
    func configure(symbol: String, literalHex: String) {
        self.literalHex = literalHex
        self.symbolName = symbol
        setArtworkMode(nil)
        let configured = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.glyphPointSize, weight: .semibold))
        if configured == nil {
            AppLog.ui.error("HelmGradientTile: SF Symbol '\(symbol, privacy: .public)' did not resolve")
        }
        imageView.image = configured
        applyTheme(ThemeManager.shared.theme)
    }

    /// Point the tile at a **full-colour raster asset** instead of an SF
    /// Symbol.
    ///
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3`: the captain asked
    /// for the Straw Hat Pirates card to carry the crew's own Jolly Roger
    /// rather than a glyph, because the point of that card is that it is
    /// recognisable at a glance. Phase 2 had already made the same call one
    /// level in - `StrawHatPortraitTile` renders the crew's faces as raster
    /// art for the identical reason - so this is that decision applied to the
    /// tile the design system already owns, not a second tile type.
    ///
    /// Three things differ from the glyph path, each deliberate:
    ///
    ///   - The image fills the tile edge to edge (`artworkFill`) rather than
    ///     sitting at its natural size in the middle. A 128px asset centred
    ///     at natural size in a 30pt tile would be clipped to its middle
    ///     quarter by `masksToBounds`.
    ///   - `contentTintColor` is left alone. It is what `applyTheme` uses to
    ///     correct a *glyph* against the gradient, and applying it to artwork
    ///     would flatten every colour in it - the same reason
    ///     `StrawHatFlag.image` sets `isTemplate = false`.
    ///   - The gradient stays underneath rather than being torn down. An
    ///     opaque asset simply covers it, and one with transparency gets the
    ///     area's own hue behind it for free; removing the layer would make
    ///     the second case render on nothing.
    ///
    /// `hue` is still required, because it is what the tile falls back to if
    /// `artwork` is nil - a corrupt payload degrades to that area's coloured
    /// tile with its glyph, never to a hole.
    func configure(artwork: NSImage?, symbol: String, hue: HelmDomainHue) {
        self.hue = hue
        self.literalHex = nil
        self.symbolName = symbol
        guard let artwork else {
            // Not silent: a nil asset here means a generated payload stopped
            // decoding, which is invisible in a build and nearly invisible on
            // screen once it has degraded to a plausible-looking glyph.
            AppLog.ui.error("HelmGradientTile: artwork for '\(symbol, privacy: .public)' is nil, falling back to the glyph")
            configure(symbol: symbol, hue: hue)
            return
        }
        setArtworkMode(artwork)
        applyTheme(ThemeManager.shared.theme)
    }

    /// Switches between the two rendering modes. Called by every `configure`
    /// overload so neither can leave the other's state behind - a tile reused
    /// across a rebuild would otherwise keep whichever it saw first.
    private func setArtworkMode(_ image: NSImage?) {
        artwork = image
        if let image {
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate(artworkFill)
        } else {
            NSLayoutConstraint.deactivate(artworkFill)
            imageView.imageScaling = .scaleNone
        }
    }

    /// The pair this tile is actually painting - a literal hue's own derived
    /// pair, or its domain hue's §2.2 pair resolved against `theme`.
    private func resolvedPair(in theme: HelmTheme) -> (h1: NSColor, h2: NSColor) {
        guard let literalHex else { return hue.pair(in: theme) }
        let h1 = HelmTheme.nsColor(literalHex)
        return (h1, h1.blended(withFraction: HelmDomainHue.fallbackLightenFraction, of: .white) ?? h1)
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    func applyTheme(_ theme: HelmTheme) {
        let pair = resolvedPair(in: theme)
        HelmMotion.withoutImplicitAnimation {
            gradient.colors = [pair.h1.cgColor, pair.h2.cgColor]
        }
        // Artwork carries its own colours - see `configure(artwork:symbol:hue:)`.
        // A tint here would flatten them, and `nil` rather than "skip the
        // assignment" so a tile that was a glyph before this configure call
        // does not keep a stale tint.
        guard artwork == nil else {
            imageView.contentTintColor = nil
            return
        }
        // Scored against `h1`, the gradient's darker end, exactly as the
        // domain-hue path does - see `glyphColor`.
        imageView.contentTintColor = HelmContrast.legibleGlyph(over: pair.h1)
    }

    /// The glyph colour: white, corrected only when white genuinely cannot
    /// carry the hue.
    ///
    /// Scored against `h1`, the gradient's **darker** end, which is the floor
    /// §2.4 itself uses for this claim ("all seven tile hues pass 3:1 with a
    /// white glyph - lowest is amber at 3.27"). Re-measured here and true.
    ///
    /// **Measured caveat, recorded rather than hidden.** A strict reading of
    /// the 3:1 non-text floor against the *lighter* half of the tile does not
    /// hold: white on the 135deg midpoint measures blue 3.54, violet 3.68,
    /// rose 2.99, teal 2.91, green 2.74, slate 2.74, amber 2.53. Two options
    /// were measured. Correcting the glyph greys it on five of the seven hues,
    /// abandoning the approved prototype's look outright. Pulling `h2` back
    /// toward `h1` until the midpoint clears keeps the glyph white but costs
    /// most of the gradient - amber survives with only 32% of its spread, i.e.
    /// a flat tile. Neither is worth it here, because the floor's own
    /// exemption applies: every tile in §4's table sits beside a visible text
    /// label carrying the same information, so the glyph is redundant
    /// decoration rather than the sole carrier of meaning. Fidelity to the
    /// approved design was chosen deliberately, and this is the record of it -
    /// an icon-**only** Daylight tile would need one of the two corrections
    /// above and must not be added without re-opening this.
    ///
    /// The correction still fires for real on a **fallback** theme, where `h1`
    /// is an arbitrary `HelmTint` slot rather than a hue picked to carry
    /// white: `gruvbox-light`'s amber and `catppuccin-latte`'s green are both
    /// far too light for a white glyph, and there it darkens rather than
    /// leaving the tile unreadable.
    static func glyphColor(for hue: HelmDomainHue, theme: HelmTheme) -> NSColor {
        HelmContrast.legibleGlyph(over: hue.baseColor(in: theme))
    }

    // MARK: Probe / self-test surface

    struct Geometry {
        let side: CGFloat
        let cornerRadius: CGFloat
        let gradientFrame: CGRect
        let gradientColorCount: Int
        let hasImage: Bool
        /// Whether the *artwork* path is the one being rendered. `hasImage`
        /// alone cannot say: a resolved SF Symbol is an image too, so a check
        /// written against it passes for either mode.
        let hasArtwork: Bool
    }

    var geometryForTests: Geometry {
        Geometry(side: bounds.width,
                 cornerRadius: layer?.cornerRadius ?? 0,
                 gradientFrame: gradient.frame,
                 gradientColorCount: gradient.colors?.count ?? 0,
                 hasImage: imageView.image != nil,
                 hasArtwork: artwork != nil)
    }

    /// What the tile is actually painted with right now - the two gradient
    /// stops and the glyph colour, so a test can prove it followed a theme
    /// change rather than only that it did not crash.
    var resolvedColorsForTests: (h1: NSColor?, h2: NSColor?, glyph: NSColor?) {
        let stops = (gradient.colors as? [CGColor])?.compactMap { NSColor(cgColor: $0) } ?? []
        return (stops.first, stops.count > 1 ? stops[1] : nil, imageView.contentTintColor)
    }
}
