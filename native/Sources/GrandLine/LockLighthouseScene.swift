// Grand Line - native macOS app.
//
// The lock screen's lighthouse (`fm/grandline-login-lamp-design-scout`,
// board design L-2): a lighthouse on a cliff whose lamp lights the gate.
//
// The lens turns like a real lighthouse seen from the side. Each of two
// opposite beams is a warm wedge pivoting at the lamp, foreshortened by
// `scale.x = sin(phi)`: it stretches out across the sea, shrinks away behind
// the tower, and the lamp flashes each time a beam faces the viewer
// (`cos(phi)^12`, once per half turn - one soft flash every 4.5 s, far below
// WCAG 2.3.1's three per second).
//
// **All of it is render-server keyframes, no timer.** One revolution is
// sampled into keyframe values and repeated forever, so a Mac left locked
// overnight costs what the waves already cost, with nothing on the main
// thread. A speed change (spin-up on reveal, the faster turn while Automic
// Vault checks) retimes the lens's container with the `timeOffset` pattern,
// which keeps the phase continuous.
//
// This type owns layers only. `LockScreenController` decides when the lamp is
// lit, owns the card and the unlock handshake, and hands this scene a palette
// it derived from the theme.

import AppKit

final class LockLighthouseScene {

    struct Palette {
        let art: LighthouseArt.Palette
        /// The beam's warm core and its lighter centre (the lamp's own colour).
        let warm: NSColor
        let warmLight: NSColor
        let fog: NSColor
    }

    /// Seconds per revolution. Two beams, so a flash every half of this.
    static let revolution: CFTimeInterval = 9
    static let beamLength: CGFloat = 1400
    private static let samples = 72

    /// The cliff and tower; a sibling of the beams so `zPosition` can put a
    /// beam behind the tower while it faces away.
    private let tower = CALayer()
    /// Holds the tower, beams, halo and lit glass, in the root's coordinates.
    let lensGroup = CALayer()
    private let beams: [CALayer] = [CALayer(), CALayer()]
    private let halo = CAGradientLayer()
    private let glass = CALayer()
    /// The faint scene-wide warmth at each flash.
    let flare = CAGradientLayer()
    private let rings: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer()]

    let fogFar = FogBand(spec: FogTexture.far, drift: 150, reverse: false)
    let fogBank = FogBand(spec: FogTexture.bank, drift: 95, reverse: true)
    let fogVeil = FogBand(spec: FogTexture.veil, drift: 120, reverse: false)

    private(set) var lamp: CGPoint = .zero
    /// The tower's tap target in the root's coordinates.
    private(set) var hotspot: CGRect = .zero
    private var turning = false

    init() {
        for layer in [tower, glass] { layer.contentsGravity = .resize }
        tower.zPosition = 2
        glass.zPosition = 2.5
        halo.zPosition = 4
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        flare.type = .radial
        flare.startPoint = CGPoint(x: 0.5, y: 0.5)
        flare.endPoint = CGPoint(x: 1, y: 1)
        flare.opacity = 0
        lensGroup.addSublayer(tower)
        for beam in beams {
            beam.anchorPoint = CGPoint(x: 1, y: 0.5)
            beam.bounds = CGRect(x: 0, y: 0, width: Self.beamLength, height: 400)
            beam.opacity = 0
            beam.zPosition = 1
            // A wide soft wedge under a narrow bright one reads as a beam
            // through haze without a blur filter.
            for (spread, alpha) in [(CGFloat(1), CGFloat(0.42)), (0.6, 1)] {
                let wedge = CAGradientLayer()
                wedge.startPoint = CGPoint(x: 1, y: 0.5)
                wedge.endPoint = CGPoint(x: 0, y: 0.5)
                wedge.locations = [0, 0.28, 0.68, 1]
                wedge.opacity = Float(alpha)
                wedge.frame = beam.bounds
                let mask = CAShapeLayer()
                let half = 200 * spread
                let p = CGMutablePath()
                p.move(to: CGPoint(x: Self.beamLength, y: 196)); p.addLine(to: CGPoint(x: 0, y: 200 - half))
                p.addLine(to: CGPoint(x: 0, y: 200 + half)); p.addLine(to: CGPoint(x: Self.beamLength, y: 204)); p.closeSubpath()
                mask.path = p
                mask.frame = beam.bounds
                wedge.mask = mask
                beam.addSublayer(wedge)
            }
            lensGroup.addSublayer(beam)
        }
        lensGroup.addSublayer(glass)
        lensGroup.addSublayer(halo)
        for ring in rings {
            ring.fillColor = nil
            ring.lineWidth = 2
            ring.opacity = 0
            lensGroup.addSublayer(ring)
        }
        halo.opacity = 0
        glass.opacity = 0
    }

    // MARK: Install, layout, theme

    /// Puts the layers into the scene between the sky and the sea.
    func install(in root: CALayer, aboveBackSea backSea: CALayer, belowFrontSea frontSea: CALayer) {
        root.insertSublayer(fogFar.layer, below: backSea)
        root.insertSublayer(lensGroup, above: backSea)
        root.insertSublayer(fogBank.layer, above: lensGroup)
        root.insertSublayer(fogVeil.layer, above: frontSea)
        root.insertSublayer(flare, above: fogVeil.layer)
        FogTexture.loadShared { [weak self] far, bank, veil in
            self?.fogFar.setImage(far)
            self?.fogBank.setImage(bank)
            self?.fogVeil.setImage(veil)
        }
    }

    /// Lays the scene out in the root's (unflipped) coordinates: the cliff on
    /// the bottom-right corner, the fog in bands up from the sea.
    func layout(bounds: CGRect) {
        HelmMotion.withoutImplicitAnimation {
            lensGroup.frame = bounds
            let art = LighthouseArt.canvas
            tower.frame = CGRect(x: bounds.maxX - art.width, y: 0, width: art.width, height: art.height)
            lamp = CGPoint(x: tower.frame.minX + LighthouseArt.lamp.x, y: art.height - LighthouseArt.lamp.y)
            let g = LighthouseArt.glass
            glass.frame = CGRect(x: tower.frame.minX + g.minX, y: art.height - g.maxY, width: g.width, height: g.height)
            hotspot = CGRect(x: lamp.x - 34, y: lamp.y - 131, width: 68, height: 172)
            for beam in beams { beam.position = lamp }
            halo.bounds = CGRect(x: 0, y: 0, width: 170, height: 170)
            halo.position = lamp
            flare.frame = bounds
            for ring in rings {
                ring.bounds = CGRect(x: 0, y: 0, width: 240, height: 120)
                ring.position = lamp
                ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            }
            fogFar.layout(frame: CGRect(x: 0, y: 100, width: bounds.width, height: CGFloat(FogTexture.far.height)))
            fogBank.layout(frame: CGRect(x: 0, y: 30, width: bounds.width, height: CGFloat(FogTexture.bank.height)))
            let veilY = max(150, bounds.height * 0.22)
            fogVeil.layout(frame: CGRect(x: 0, y: veilY, width: bounds.width, height: CGFloat(FogTexture.veil.height)))
        }
    }

    func applyPalette(_ p: Palette) {
        HelmMotion.withoutImplicitAnimation {
            tower.contents = LighthouseArt.image(palette: p.art)
            glass.backgroundColor = p.warmLight.cgColor
            for ring in rings { ring.strokeColor = p.warmLight.withAlphaComponent(0.75).cgColor }
            for band in [fogFar, fogBank, fogVeil] { band.layer.backgroundColor = p.fog.cgColor }
        }
        for beam in beams {
            for case let wedge as CAGradientLayer in beam.sublayers ?? [] {
                Self.setStops(wedge, [p.warmLight.withAlphaComponent(0.78), p.warm.withAlphaComponent(0.34),
                                      p.warm.withAlphaComponent(0.11), p.warm.withAlphaComponent(0)])
            }
        }
        Self.setStops(halo, [p.warmLight.withAlphaComponent(1), p.warm.withAlphaComponent(0.6), p.warm.withAlphaComponent(0)],
                      [0, 0.26, 0.68])
        Self.setStops(flare, [p.warm.withAlphaComponent(0.9), p.warm.withAlphaComponent(0.25), p.warm.withAlphaComponent(0)],
                      [0, 0.55, 0.8])
    }

    /// Every gradient's stops go through here with implicit animation off: a
    /// standalone layer's colour change would otherwise cross-fade on a theme
    /// switch.
    private static func setStops(_ layer: CAGradientLayer, _ colors: [NSColor], _ locations: [NSNumber]? = nil) {
        HelmMotion.withoutImplicitAnimation {
            layer.colors = colors.map(\.cgColor)
            if let locations { layer.locations = locations }
        }
    }

    // MARK: The lamp

    /// The resting, unlit scene: dark lamp, no beams, the fog veil drawn in.
    func showUnlit() {
        stopLens()
        HelmMotion.withoutImplicitAnimation {
            lensGroup.opacity = 1
            for beam in beams { beam.opacity = 0; beam.transform = CATransform3DIdentity }
            halo.opacity = 0
            glass.opacity = 0
            flare.opacity = 0
            fogVeil.layer.opacity = 0.5
            fogFar.layer.opacity = 0.62
            fogBank.layer.opacity = 0.78
        }
    }

    /// The lit scene, at once: lens turning (or one still beam), veil gone.
    func showLit(reducedMotion: Bool) {
        HelmMotion.withoutImplicitAnimation {
            lensGroup.opacity = 1
            glass.opacity = 1
            fogVeil.layer.opacity = 0
            fogFar.layer.opacity = 0.62
            fogBank.layer.opacity = 0.78
        }
        startLens(reducedMotion: reducedMotion, spinUp: false)
    }

    /// Lights the lamp. `spinUp` turns the first quarter fast, so the first
    /// beam reaches the card in about a second rather than 2.25 s.
    func light(reducedMotion: Bool, spinUp: Bool, fadeVeil: CFTimeInterval) {
        HelmMotion.withoutImplicitAnimation { lensGroup.opacity = 1 }
        fade(glass, to: 1, duration: 0.22)
        fade(fogVeil.layer, to: 0, duration: fadeVeil)
        startLens(reducedMotion: reducedMotion, spinUp: spinUp)
    }

    /// Puts the lamp out: the lens stops, the beams fade, the veil closes in.
    func dim(duration: CFTimeInterval = 0.7) {
        stopLens()
        for beam in beams { fade(beam, to: 0, duration: duration * 0.7) }
        fade(halo, to: 0, duration: duration * 0.7)
        fade(glass, to: 0, duration: duration * 0.7)
        fade(fogVeil.layer, to: 0.5, duration: duration + 0.3)
    }

    /// The lens's speed: 1 at rest, about twice that while the vault checks.
    func setTurnSpeed(_ speed: Float) {
        guard turning else { return }
        let now = CACurrentMediaTime()
        let local = lensGroup.convertTime(now, from: nil)
        lensGroup.beginTime = now
        lensGroup.timeOffset = local
        lensGroup.speed = speed
    }

    /// Two foghorn rings from the lamp for a refused password.
    func foghorn() {
        for (i, ring) in rings.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.25; scale.toValue = 2.2
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.7; opacity.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 1.0
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.28
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            ring.add(group, forKey: "foghorn")
        }
    }

    /// One bright flash toward the viewer: the success flourish's first beat.
    func lastFlash() {
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.5, 0]
        flash.keyTimes = [0, 0.3, 1]
        flash.duration = 0.7
        flare.add(flash, forKey: "lastFlash")
    }

    func fadeOutForDay(duration: CFTimeInterval, delay: CFTimeInterval) {
        for layer in [halo, glass, fogFar.layer, fogBank.layer] as [CALayer] + beams {
            fade(layer, to: 0, duration: duration, delay: delay)
        }
    }

    /// E4: no looping animation outlives the overlay.
    func stopAll() {
        stopLens()
        for band in [fogFar, fogBank, fogVeil] { band.stopDrift() }
    }

    func startDrift(reducedMotion: Bool) {
        guard !reducedMotion else { return }
        for band in [fogFar, fogBank, fogVeil] { band.startDrift() }
    }

    // MARK: Lens keyframes

    private func startLens(reducedMotion: Bool, spinUp: Bool) {
        stopLens()
        turning = true
        lensGroup.speed = 1
        lensGroup.timeOffset = 0
        lensGroup.beginTime = 0
        if reducedMotion {
            // One still beam out to sea, no flash: Reduce Motion keeps the
            // light but not the turning.
            HelmMotion.withoutImplicitAnimation {
                beams[0].transform = CATransform3DMakeScale(1, 1, 1)
                beams[0].opacity = 0.61
                beams[0].zPosition = 3
                beams[1].opacity = 0
                halo.opacity = 0.75
            }
            turning = false
            return
        }
        let n = Self.samples
        let times = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        for (i, beam) in beams.enumerated() {
            var scales: [NSNumber] = [], opacities: [NSNumber] = [], zs: [NSNumber] = []
            for k in 0...n {
                let phi = 2 * Double.pi * Double(k) / Double(n) + Double(i) * .pi
                let s = sin(phi), c = cos(phi)
                scales.append(NSNumber(value: abs(s) < 0.002 ? (s < 0 ? -0.002 : 0.002) : s))
                opacities.append(NSNumber(value: 0.22 + 0.78 * (0.5 + 0.5 * c)))
                zs.append(NSNumber(value: c >= 0 ? 3 : 1))
            }
            beam.add(keyframes("transform.scale.x", scales, times), forKey: "lens.scale")
            beam.add(keyframes("opacity", opacities, times), forKey: "lens.opacity")
            let z = keyframes("zPosition", zs, times)
            z.calculationMode = .discrete
            beam.add(z, forKey: "lens.z")
        }
        var haloOpacity: [NSNumber] = [], haloScale: [NSNumber] = [], flareOpacity: [NSNumber] = []
        for k in 0...n {
            let phi = 2 * Double.pi * Double(k) / Double(n)
            let p = pow(max(0, max(cos(phi), cos(phi + .pi))), 12)
            haloOpacity.append(NSNumber(value: 0.5 + 0.5 * p))
            haloScale.append(NSNumber(value: 1 + 0.38 * p))
            flareOpacity.append(NSNumber(value: 0.1 * p))
        }
        halo.add(keyframes("opacity", haloOpacity, times), forKey: "lens.opacity")
        halo.add(keyframes("transform.scale", haloScale, times), forKey: "lens.scale")
        flare.add(keyframes("opacity", flareOpacity, times), forKey: "lens.opacity")
        if spinUp {
            // The first quarter turn at 2.1x, then the resting speed, phase kept.
            setTurnSpeed(2.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revolution / 4 / 2.1) { [weak self] in
                self?.setTurnSpeed(1)
            }
        }
    }

    private func stopLens() {
        turning = false
        for beam in beams { for key in ["lens.scale", "lens.opacity", "lens.z"] { beam.removeAnimation(forKey: key) } }
        for key in ["lens.opacity", "lens.scale"] { halo.removeAnimation(forKey: key) }
        flare.removeAnimation(forKey: "lens.opacity")
        lensGroup.speed = 1
        lensGroup.timeOffset = 0
        lensGroup.beginTime = 0
    }

    private func keyframes(_ keyPath: String, _ values: [NSNumber], _ times: [NSNumber]) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times
        a.duration = Self.revolution
        a.repeatCount = .infinity
        a.calculationMode = .linear
        a.isRemovedOnCompletion = false
        return a
    }

    private func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        HelmMotion.withoutImplicitAnimation { layer.opacity = value }
        layer.add(a, forKey: "fade")
    }

    #if FM_SELFTESTS
    var debugLensTurning: Bool { beams[0].animation(forKey: "lens.scale") != nil }
    var debugVeilOpacity: Float { fogVeil.layer.opacity }
    var debugGlassOpacity: Float { glass.opacity }
    var debugLensSpeed: Float { lensGroup.speed }
    #endif
}

/// One drifting band of fog: a fill in the fog's colour, masked by a tiled
/// noise texture that slides one tile-width and repeats.
final class FogBand {
    let layer = CALayer()
    private let replicator = CAReplicatorLayer()
    private let tile = CALayer()
    private let spec: FogTexture.Spec
    private let drift: CFTimeInterval
    private let reverse: Bool

    init(spec: FogTexture.Spec, drift: CFTimeInterval, reverse: Bool) {
        self.spec = spec
        self.drift = drift
        self.reverse = reverse
        replicator.anchorPoint = .zero
        replicator.addSublayer(tile)
        layer.mask = replicator
    }

    func setImage(_ image: CGImage?) {
        HelmMotion.withoutImplicitAnimation { tile.contents = image }
    }

    func layout(frame: CGRect) {
        let period = CGFloat(spec.period)
        HelmMotion.withoutImplicitAnimation {
            layer.frame = frame
            replicator.frame = CGRect(x: 0, y: 0, width: frame.width + period, height: frame.height)
            tile.frame = CGRect(x: 0, y: 0, width: period, height: frame.height)
            replicator.instanceCount = Int(ceil(frame.width / period)) + 1
            replicator.instanceTransform = CATransform3DMakeTranslation(period, 0, 0)
        }
    }

    func startDrift() {
        guard replicator.animation(forKey: "drift") == nil else { return }
        let a = CABasicAnimation(keyPath: "position.x")
        let period = CGFloat(spec.period)
        a.fromValue = reverse ? -period : 0
        a.toValue = reverse ? 0 : -period
        a.duration = drift
        a.repeatCount = .infinity
        replicator.add(a, forKey: "drift")
    }

    func stopDrift() { replicator.removeAnimation(forKey: "drift") }
}

extension FogTexture {
    private static var cache: (CGImage?, CGImage?, CGImage?)?
    private static var waiting: [(CGImage?, CGImage?, CGImage?) -> Void] = []

    /// The three band textures, generated once off the main thread and
    /// handed back on main.
    static func loadShared(_ done: @escaping (CGImage?, CGImage?, CGImage?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let cache { done(cache.0, cache.1, cache.2); return }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        DispatchQueue.global(qos: .utility).async {
            let images = (make(far), make(bank), make(veil))
            DispatchQueue.main.async {
                cache = images
                let callbacks = waiting
                waiting.removeAll()
                callbacks.forEach { $0(images.0, images.1, images.2) }
            }
        }
    }
}
