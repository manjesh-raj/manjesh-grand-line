// Grand Line - native macOS app.
//
// The hero's gradient as a surface of its own (Helm 6.6.0), so a module card
// can be painted with it as well as `HelmHeroCard`.
//
// The briefing hero used to own its two layers and its colour maths. The
// captain then picked the hero style for two Home cards (the Claude usage
// card's split hero and the Fleet card's full hero, on the widget-style
// board), and a module card cannot be a `HelmHeroCard`: it has a click, a
// header, Customize's strip and resize grips. So the recipe moved here, and
// both components paint the same view. There is still exactly one copy of
// the gradient, the glow and the palette rule.
//
// **The palette rule is unchanged.** The accent with 8% white at the top-left
// and with 38% black at the bottom-right, both deepened by the smallest step
// that lets white text clear `HelmContrast.textTarget` against the lighter
// stop. Where no deepening the design allows can get there, the ink steps
// toward black instead. `palette(accent:)` takes any colour, which is what
// lets a captain pick the hero's colour on Home without a second set of maths.
//
// **Two tones on top of a palette**, both for a module card's states:
//
//   - `dimmed(_:)` is GL-14's stale reading. The colour steps most of the way
//     to a grey of its own lightness, so a reading that may be behind does not
//     look as alive as a fresh one, and the captain's colour is still
//     recognisable under it.
//   - `signalColor(tintHex:on:)` is a state hue (amber, red) brightened, and
//     desaturated only as far as it must be, until it clears the non-text
//     floor on both stops, for a ring arc on the gradient. A raw amber arc on
//     a deep blue gradient is two dark colours side by side.
//
// **Not interactive.** `hitTest` returns nil, so a click on the gradient lands
// on whatever is behind it - the module card's own surface, which is the
// card's one click target (gotcha (20)).
//
// **Every layer is a standalone sublayer**, so a colour write goes through
// `HelmMotion.withoutImplicitAnimation` (the app's one gradient gate) and a
// frame write through `HelmMotion.withoutActions`.

import AppKit

final class HelmHeroSurface: NSView {

    /// The colours one hero is drawn in.
    struct Palette: Equatable {
        /// The top-left stop.
        let start: (Double, Double, Double)
        /// The bottom-right stop.
        let end: (Double, Double, Double)
        /// The text, the ring's arc and the ring's centre label.
        let ink: (Double, Double, Double)

        static func == (a: Palette, b: Palette) -> Bool {
            a.start == b.start && a.end == b.end && a.ink == b.ink
        }

        /// Of the two stops, the one white ink is measured against.
        var lighterStop: (Double, Double, Double) {
            HelmContrast.relativeLuminance(start) >= HelmContrast.relativeLuminance(end) ? start : end
        }
    }

    /// The prototype's two stops: the accent with 8% white, and the accent
    /// with 38% black.
    static let startLift = 0.08
    static let endDepth = 0.38
    /// How far `palette(accent:)` may deepen both stops looking for white
    /// ink, in steps of `deepenStep`.
    static let maxDeepen = 0.6
    static let deepenStep = 0.02
    static let glowSide: CGFloat = 220
    static let glowAlpha: CGFloat = 0.28
    /// How much of a dimmed colour is the grey of its own lightness.
    static let dimmedGrey = 0.72

    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private(set) var palette: Palette?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradient)
        layer?.addSublayer(glow)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Paint `palette`. The glow is the ink at `glowAlpha`, fading out.
    func apply(_ palette: Palette) {
        self.palette = palette
        let ink = HelmContrast.color(palette.ink)
        HelmMotion.withoutImplicitAnimation {
            gradient.colors = [HelmContrast.color(palette.start).cgColor, HelmContrast.color(palette.end).cgColor]
            glow.colors = [ink.withAlphaComponent(Self.glowAlpha).cgColor, ink.withAlphaComponent(0).cgColor]
        }
    }

    override func layout() {
        super.layout()
        HelmMotion.withoutActions {
            gradient.frame = bounds
            let side = Self.glowSide
            glow.frame = CGRect(x: bounds.maxX - side + 40, y: bounds.maxY - side + 60, width: side, height: side)
        }
    }

    // MARK: The palette

    /// The hero's colours on `theme`'s own accent.
    static func palette(for theme: HelmTheme) -> Palette {
        palette(accent: HelmContrast.components(HelmTheme.nsColor(theme.accentHex)))
    }

    /// The hero's colours on any accent. See the file header for the rule.
    static func palette(accent: (Double, Double, Double)) -> Palette {
        let white = (1.0, 1.0, 1.0)
        let black = (0.0, 0.0, 0.0)
        let start = HelmContrast.mix(white, accent, startLift)
        let end = HelmContrast.mix(black, accent, endDepth)
        var deepen = 0.0
        while deepen <= maxDeepen + 1e-9 {
            let s = HelmContrast.mix(black, start, deepen)
            let e = HelmContrast.mix(black, end, deepen)
            if HelmContrast.ratio(white, s) >= HelmContrast.textTarget {
                return Palette(start: s, end: e, ink: white)
            }
            deepen += deepenStep
        }
        // No deepening the design allows gets white there: a very light
        // accent. Keep the prototype's stops and set the ink dark enough for
        // both of them.
        let lighter = HelmContrast.relativeLuminance(start) >= HelmContrast.relativeLuminance(end) ? start : end
        let ink = HelmContrast.components(HelmContrast.legibleOn(fill: HelmContrast.color(lighter),
                                                                preferring: HelmContrast.color(black)))
        return Palette(start: start, end: end, ink: ink)
    }

    /// 1.1.0: the same rule for a surface whose second lines are the ink at
    /// a lower alpha (`HelmHeroColumn`'s row details, section titles and ring
    /// caption). Both stops are deepened until white at `quietInk` alpha also
    /// clears the text floor on the lighter stop. The plain rule stops at
    /// exactly the floor for white, so on Rosé Pine's accent 80% white
    /// measured 3.41:1. Where no deepening the design allows gets there, it
    /// falls back to the plain rule.
    static func palette(accent: (Double, Double, Double), quietInk: Double) -> Palette {
        let white = (1.0, 1.0, 1.0)
        let black = (0.0, 0.0, 0.0)
        let start = HelmContrast.mix(white, accent, startLift)
        let end = HelmContrast.mix(black, accent, endDepth)
        var deepen = 0.0
        while deepen <= maxDeepen + 1e-9 {
            let s = HelmContrast.mix(black, start, deepen)
            let e = HelmContrast.mix(black, end, deepen)
            let lighter = HelmContrast.relativeLuminance(s) >= HelmContrast.relativeLuminance(e) ? s : e
            if HelmContrast.ratio(HelmContrast.mix(white, lighter, quietInk), lighter) >= HelmContrast.textTarget {
                return Palette(start: s, end: e, ink: white)
            }
            deepen += deepenStep
        }
        return palette(accent: accent)
    }

    /// GL-14's stale tone: `accent` most of the way to a grey of its own
    /// lightness. Run the result through `palette(accent:)` like any other.
    static func dimmed(_ accent: (Double, Double, Double)) -> (Double, Double, Double) {
        let lightness = 0.2126 * accent.0 + 0.7152 * accent.1 + 0.0722 * accent.2
        return HelmContrast.mix((lightness, lightness, lightness), accent, dimmedGrey)
    }

    /// A state hue for a mark on the gradient - a ring's arc - that still
    /// reads as that hue and clears the non-text floor against both stops.
    ///
    /// The hue is kept and its brightness raised to full first, then its
    /// saturation given up one step at a time until the floor is met. Mixing
    /// toward the ink instead was measured: Daylight's amber had to go so far
    /// toward white that a near-limit arc read as a plain white one.
    static func signalColor(tintHex: String, on palette: Palette) -> NSColor {
        let darker = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
            ? palette.start : palette.end
        func clears(_ rgb: (Double, Double, Double)) -> Bool {
            HelmContrast.ratio(rgb, palette.lighterStop) >= HelmContrast.nonTextTarget
                && HelmContrast.ratio(rgb, darker) >= HelmContrast.nonTextTarget
        }
        let base = HelmTheme.nsColor(tintHex).usingColorSpace(.sRGB) ?? HelmTheme.nsColor(tintHex)
        let raw = HelmContrast.components(base)
        if clears(raw) { return base }
        // A dark-ink hero (a very pale colour) wants a darker mark, which the
        // raw hue already is or the ink is.
        if HelmContrast.relativeLuminance(palette.ink) < 0.5 { return HelmContrast.color(palette.ink) }
        var saturation = Double(base.saturationComponent)
        while saturation >= -1e-9 {
            let candidate = NSColor(hue: base.hueComponent, saturation: CGFloat(max(0, saturation)),
                                    brightness: 1, alpha: 1)
            if clears(HelmContrast.components(candidate)) { return candidate }
            saturation -= 0.05
        }
        return HelmContrast.color(palette.ink)
    }

    #if FM_SELFTESTS
    var debugGradientColors: [CGColor] { (gradient.colors as? [CGColor]) ?? [] }
    #endif
}
