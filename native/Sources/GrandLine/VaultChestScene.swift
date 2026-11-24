// Grand Line - native macOS app.
//
// The Secrets page's treasure chest (`fm/grandline-login-lamp-design-scout`,
// board design S-1). While the chest is shut the page goes dark and light
// leaks from under the lid. Opening it swings the lid back, throws coins and
// gems, and lets a warm light and slow rays bring the unlock form in.
//
// **Two views, one scene.** The board stacks the vault's form between the
// chest's back (its shadow, the open lid's lining, the dark mouth) and its
// front (the heap, the body, the padlock), so in the narrow stacked layout the
// form rises out of the chest. `backView` sits below the form and `frontView`
// above it, and both cover the gate's whole bounds. Neither takes a click
// except on the chest and the padlock.
//
// **All of it is render-server animation.** Every loop (the seam's pulse, the
// rays' sway, the twinkles) is a repeating Core Animation, and every one
// stops when the gate is hidden (`stopLoops`), so a locked vault left on
// screen costs nothing on the main thread and a hidden one costs nothing at
// all (GL-13).
//
// This type owns layers only. `CredentialVaultUnlockView` decides when the
// chest is open, owns the form and the unlock handshake, and never lets the
// chest stand between the captain and the password field: typing always
// works, and the padlock always reaches Touch ID.

import AppKit

final class VaultChestScene {

    /// The board's stacked layout puts the form above the chest; side by side
    /// it is the chest on the left and the form on the right.
    enum Layout: Equatable { case side, stacked }

    /// Stacked, how far the form is raised so the form and the chest under
    /// it are centred as a pair: half the chest group's height.
    static let stackedLift: CGFloat = 105

    let backView = ChestLayerView()
    let frontView = ChestLayerView()

    /// The chest's tap target, and the padlock's on top of it.
    let chestHotspot = ChestHotspotView()
    let padlockHotspot = ChestHotspotView()

    private let hold = CAGradientLayer()
    private let seamGlow = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let formGlow = CAGradientLayer()
    private let raysWrap = CALayer()
    private let rays = CAGradientLayer()
    private let raysMask = CAGradientLayer()

    private let backGroup = CALayer()
    private let shadow = CAGradientLayer()
    private let lid = CALayer()
    private let mouthLayer = CAGradientLayer()

    private let frontGroup = CALayer()
    private let heap = CALayer()
    private let body = CALayer()
    private let spill = CALayer()
    private let dome = CALayer()
    private let seam = CALayer()
    private let padlock = CALayer()
    private let sparkles = CALayer()
    private var stars: [CALayer] = []
    private let fx = CALayer()

    private(set) var isOpen = false { didSet { updateLabels() } }
    private var touchID = false
    private var reducedMotion = false
    private var hovering = false
    private var checking = false
    private var light = VaultChestArt.Light.forDarkRegister(false)
    private var artKey: String?
    private(set) var layout: Layout = .side
    /// The chest group's frame in the gate's (y-up) coordinates.
    private(set) var chestFrame: CGRect = .zero

    init() {
        for view in [backView, frontView] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            view.layer?.masksToBounds = true
        }
        frontView.addSubview(chestHotspot)
        frontView.addSubview(padlockHotspot)

        for radial in [hold, seamGlow, glow, formGlow, shadow, raysMask] {
            radial.type = .radial
            radial.startPoint = CGPoint(x: 0.5, y: 0.5)
            radial.endPoint = CGPoint(x: 1, y: 1)
        }
        rays.type = .conic
        rays.startPoint = CGPoint(x: 0.5, y: 0.5)
        rays.endPoint = CGPoint(x: 0.5, y: 1)
        rays.mask = raysMask
        raysWrap.masksToBounds = true
        raysWrap.addSublayer(rays)
        mouthLayer.cornerRadius = 6

        for layer in [lid, heap, body, spill, dome, padlock] { layer.contentsGravity = .resize }
        // The two lids hinge on their bottom edges.
        lid.anchorPoint = CGPoint(x: 0.5, y: 0)
        dome.anchorPoint = CGPoint(x: 0.5, y: 0)
        seam.cornerRadius = 1.5
        seam.shadowOffset = .zero
        seam.shadowRadius = 5
        seam.shadowOpacity = 0.7
        padlock.shadowOffset = CGSize(width: 0, height: -2)
        padlock.shadowRadius = 1.5
        padlock.shadowOpacity = 0.45

        let back = backView.layer!
        for layer in [hold, seamGlow, glow, formGlow, raysWrap, backGroup] as [CALayer] { back.addSublayer(layer) }
        for layer in [shadow, lid, mouthLayer] as [CALayer] { backGroup.addSublayer(layer) }
        let front = frontView.layer!
        front.addSublayer(frontGroup)
        for layer in [heap, body, spill, dome, seam, padlock, sparkles, fx] { frontGroup.addSublayer(layer) }
        for _ in VaultChestArt.sparks {
            let star = CALayer()
            star.contents = VaultChestArt.star
            star.contentsGravity = .resize
            star.opacity = 0
            sparkles.addSublayer(star)
            stars.append(star)
        }
        showShut()
    }

    // MARK: Theme

    /// Repaints for a theme. The art is redrawn only when the register
    /// (light or dark) or the padlock's glyph changes.
    func applyTheme(_ theme: HelmTheme, touchID: Bool) {
        light = VaultChestArt.Light.forDarkRegister(theme.mode == .dark)
        self.touchID = touchID
        updateLabels()
        let key = "\(theme.mode == .dark)-\(touchID)"
        HelmMotion.withoutImplicitAnimation {
            if key != artKey {
                artKey = key
                let dim = light.dim
                lid.contents = VaultChestArt.lid(dim: dim)
                heap.contents = VaultChestArt.heap(dim: dim)
                body.contents = VaultChestArt.body(dim: dim)
                spill.contents = VaultChestArt.spill(dim: dim)
                dome.contents = VaultChestArt.dome(dim: dim)
                padlock.contents = VaultChestArt.padlock(dim: dim, touchID: touchID)
            }
            hold.colors = [light.holdCentre.cgColor, light.holdEdge.cgColor]
            seamGlow.colors = [light.seamGlow.cgColor, light.seamGlow.withAlphaComponent(0).cgColor]
            seamGlow.locations = [0, 0.7]
            shadow.colors = [light.shadow.cgColor, light.shadow.withAlphaComponent(0).cgColor]
            shadow.locations = [0, 0.7]
            formGlow.colors = [light.formGlow.cgColor, light.formGlow.withAlphaComponent(0).cgColor]
            formGlow.locations = [0, 0.7]
            // Stacked, the board's mouth gradient runs dark at the top.
            mouthLayer.colors = [light.mouthBottom.cgColor, light.mouthTop.cgColor]
            seam.backgroundColor = light.seam.cgColor
            seam.shadowColor = light.glow.cgColor
            padlock.shadowColor = light.mouthBottom.cgColor
            raysMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor,
                               NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.clear.cgColor]
            raysMask.locations = [0, 0.13, 0.48, 1]
            applyRays()
            applyGlow()
        }
    }

    /// The rays: 28 warm wedges round the mouth, each a third of its slot.
    private func applyRays() {
        let ray = light.ray.cgColor, clear = light.ray.withAlphaComponent(0).cgColor
        var colors: [CGColor] = [], locations: [NSNumber] = []
        let slots = 28
        for k in 0..<slots {
            let a0 = Double(k) / Double(slots), a1 = Double(k + 1) / Double(slots)
            let w = (a1 - a0) * 4.5 / 13
            colors += [ray, ray, clear, clear]
            locations += [a0, a0 + w, a0 + w + 0.0005, a1].map { NSNumber(value: $0) }
        }
        rays.colors = colors
        rays.locations = locations
    }

    private func applyGlow() {
        let side = layout == .side
        glow.colors = [light.glow.withAlphaComponent(0.42).cgColor,
                       light.glow.withAlphaComponent(side ? 0.1 : 0.12).cgColor,
                       light.glow.withAlphaComponent(0).cgColor]
        glow.locations = [0, side ? 0.52 : 0.5, 0.72]
    }

    /// VoiceOver hears what a tap will do now.
    private func updateLabels() {
        let chest = isOpen ? "Close the chest" : "Open the chest"
        chestHotspot.label = chest
        padlockHotspot.label = touchID ? "Unlock with Touch ID" : chest
    }

    // MARK: Layout

    /// Places the chest. `chestTopLeft` is where the board's chest group
    /// starts, in the gate's y-up coordinates; `formCentre` is the form's
    /// centre, which the side layout's second glow sits beside.
    func layout(bounds: CGRect, chestTopLeft: CGPoint, layout: Layout, formCentre: CGPoint) {
        let size = VaultChestArt.groupSize
        let changed = layout != self.layout
        self.layout = layout
        chestFrame = CGRect(x: chestTopLeft.x, y: chestTopLeft.y - size.height, width: size.width, height: size.height)
        let side = layout == .side
        /// A point in chest space (y-down) in the gate's coordinates.
        func gate(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: chestFrame.minX + x, y: chestFrame.maxY - y) }
        /// A frame in chest space (y-down) in the group's own y-up coordinates.
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
        }
        HelmMotion.withoutImplicitAnimation {
            for group in [backGroup, frontGroup] { group.frame = chestFrame }
            shadow.frame = local(VaultChestArt.shadowFrame)
            mouthLayer.frame = local(VaultChestArt.mouthFrame)
            for (layer, frame) in [(heap, VaultChestArt.heapFrame), (body, VaultChestArt.bodyFrame),
                                   (spill, VaultChestArt.spillFrame), (seam, VaultChestArt.seamFrame),
                                   (padlock, VaultChestArt.padlockFrame)] {
                layer.bounds = CGRect(origin: .zero, size: frame.size)
                let f = local(frame)
                layer.position = CGPoint(x: f.midX, y: f.midY)
            }
            seam.shadowPath = CGPath(rect: seam.bounds.insetBy(dx: -3, dy: -3), transform: nil)
            for (layer, frame) in [(lid, VaultChestArt.lidFrame), (dome, VaultChestArt.domeFrame)] {
                layer.bounds = CGRect(origin: .zero, size: frame.size)
                let f = local(frame)
                layer.position = CGPoint(x: f.midX, y: f.minY)
            }
            sparkles.frame = CGRect(origin: .zero, size: size)
            fx.frame = CGRect(origin: .zero, size: size)
            for (star, point) in zip(stars, VaultChestArt.sparks) {
                star.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
                star.position = CGPoint(x: point.x, y: size.height - point.y)
            }

            // The dark, centred under the chest, and big enough to cover every corner.
            let holdCentre = gate(122, 136)
            let rx: CGFloat = side ? 400 : 420, ry: CGFloat = side ? 260 : 250
            let reach = max(bounds.width, bounds.height) * 2
            let k = max(1, reach / ry)
            hold.bounds = CGRect(x: 0, y: 0, width: rx * 2 * k, height: ry * 2 * k)
            hold.position = holdCentre
            hold.locations = [0, NSNumber(value: Double(0.78 / k))]

            seamGlow.bounds = CGRect(x: 0, y: 0, width: 460, height: 180)
            seamGlow.position = gate(122, 90)
            glow.bounds = side ? CGRect(x: 0, y: 0, width: 1040, height: 800) : CGRect(x: 0, y: 0, width: 1120, height: 840)
            glow.position = gate(122, 80)
            formGlow.isHidden = !side
            formGlow.bounds = CGRect(x: 0, y: 0, width: 1040, height: 760)
            formGlow.position = CGPoint(x: formCentre.x - 50, y: formCentre.y)

            // The rays fan up from the mouth, and stop at its line.
            let mouthLine = chestFrame.maxY - 96
            raysWrap.frame = CGRect(x: bounds.minX, y: mouthLine, width: bounds.width, height: max(0, bounds.maxY - mouthLine))
            let raysCentre = gate(122, 90)
            rays.bounds = CGRect(x: 0, y: 0, width: 910, height: 910)
            rays.position = CGPoint(x: raysCentre.x - raysWrap.frame.minX, y: raysCentre.y - raysWrap.frame.minY)
            raysMask.frame = rays.bounds
        }
        chestHotspot.frame = VaultChestScene.flip(VaultChestArt.hitFrame, in: chestFrame)
        padlockHotspot.frame = VaultChestScene.flip(VaultChestArt.padlockFrame, in: chestFrame)
        if changed { applyGlow() }
    }

    private static func flip(_ r: CGRect, in group: CGRect) -> CGRect {
        CGRect(x: group.minX + r.minX, y: group.maxY - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Transforms

    /// CSS's `perspective(520px) rotateX(deg)` for a layer hinged on its
    /// bottom edge. CSS's y runs down, so its angle is negated here.
    private static func hinge(_ degrees: CGFloat, scaleY: CGFloat = 1) -> CATransform3D {
        var p = CATransform3DIdentity
        p.m34 = -1 / 520
        let r = CATransform3DMakeRotation(-degrees * .pi / 180, 1, 0, 0)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeScale(1, scaleY, 1), r), p)
    }

    /// CSS's `translateY(dy) rotate(deg)` for the padlock (y down, clockwise positive).
    private static func tilt(_ degrees: CGFloat, dy: CGFloat = 0) -> CATransform3D {
        CATransform3DConcat(CATransform3DMakeRotation(-degrees * .pi / 180, 0, 0, 1), CATransform3DMakeTranslation(0, -dy, 0))
    }

    private static let padlockOpen = tilt(-8, dy: 1)

    // MARK: States

    /// Shut, at once: the page dark and light leaking from the lid.
    func showShut() {
        isOpen = false
        removeStateAnimations()
        HelmMotion.withoutImplicitAnimation {
            dome.transform = Self.hinge(0); dome.opacity = 1
            lid.transform = Self.hinge(-90); lid.opacity = 0
            for layer in [mouthLayer, heap, spill, glow, formGlow, raysWrap] as [CALayer] { layer.opacity = 0 }
            hold.opacity = 1
            seam.opacity = 0.5
            seamGlow.opacity = 0.7
            sparkles.opacity = 0
            padlock.transform = CATransform3DIdentity
        }
        startLoops()
    }

    /// Open, at once: Reduce Motion's resting state and the lit start.
    func showOpen(reducedMotion: Bool) {
        isOpen = true
        self.reducedMotion = reducedMotion
        removeStateAnimations()
        HelmMotion.withoutImplicitAnimation {
            dome.transform = Self.hinge(90); dome.opacity = 0
            lid.transform = Self.hinge(0); lid.opacity = 1
            for layer in [mouthLayer, heap, spill, glow, formGlow, raysWrap] as [CALayer] { layer.opacity = 1 }
            hold.opacity = 0
            seam.opacity = 0
            seamGlow.opacity = 0
            sparkles.opacity = reducedMotion ? 0 : 1
            padlock.transform = Self.padlockOpen
        }
        startLoops()
    }

    /// The board's `openLid`: the dome swings back, the lining swings up with
    /// a little overshoot, the treasure and the light come in, and coins fly.
    /// `fast` (from a key) runs it at 45% of the time with fewer coins.
    func open(fast: Bool, reducedMotion: Bool) {
        guard !isOpen else { return }
        self.reducedMotion = reducedMotion
        if reducedMotion { showOpen(reducedMotion: true); return }
        isOpen = true
        hovering = false
        let k: CFTimeInterval = fast ? 0.45 : 1
        stopLoop(seam, "pulse"); stopLoop(seamGlow, "pulse")
        keyframes(padlock, "transform", [CATransform3DIdentity, Self.tilt(-14, dy: 3), Self.padlockOpen].map { NSValue(caTransform3D: $0) },
                  times: [0, 0.5, 1], duration: 0.22 * k)
        keyframes(dome, "transform", [Self.hinge(0), Self.hinge(90)].map { NSValue(caTransform3D: $0) },
                  times: [0, 1], duration: 0.23 * k, delay: 0.06 * k, timing: CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45))
        fade(dome, to: 0, duration: 0.01, delay: 0.29 * k)
        keyframes(lid, "transform", [Self.hinge(-90), Self.hinge(10), Self.hinge(-4), Self.hinge(0)].map { NSValue(caTransform3D: $0) },
                  times: [0, 0.65, 0.85, 1], duration: 0.46 * k, delay: 0.29 * k,
                  timing: CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
        fade(lid, to: 1, duration: 0.01, delay: 0.29 * k)
        fade(seam, to: 0, duration: 0.12 * k, delay: 0.2 * k)
        fade(seamGlow, to: 0, duration: 0.3 * k, delay: 0.2 * k)
        fade(mouthLayer, to: 1, duration: 0.12 * k, delay: 0.29 * k)
        fade(heap, to: 1, duration: 0.2 * k, delay: 0.3 * k)
        fade(spill, to: 1, duration: 0.2 * k, delay: 0.38 * k)
        fade(raysWrap, to: 1, duration: 0.6 * k, delay: 0.32 * k)
        fade(glow, to: 1, duration: 0.7 * k, delay: 0.32 * k)
        fade(formGlow, to: 1, duration: 0.7 * k, delay: 0.32 * k)
        fade(hold, to: 0, duration: 0.8 * k, delay: 0.3 * k)
        fade(sparkles, to: 1, duration: 0.01, delay: 0.38 * k)
        burst(count: fast ? 4 : 14, height: 210, spread: 300, delay: 0.38 * k)
        startLoops()
    }

    /// The board's `shut`: the light and the treasure go, the lining folds
    /// down, the dome drops back with a little bounce, and the padlock settles.
    func shut() {
        guard isOpen else { return }
        isOpen = false
        let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
        stopLoop(rays, "sway")
        for star in stars { stopLoop(star, "twinkle") }
        HelmMotion.withoutImplicitAnimation { sparkles.opacity = 0 }
        fade(raysWrap, to: 0, duration: 0.38, delay: 0.2, timing: easeInOut)
        fade(glow, to: 0, duration: 0.5, delay: 0.2, timing: easeInOut)
        fade(formGlow, to: 0, duration: 0.5, delay: 0.2, timing: easeInOut)
        fade(spill, to: 0, duration: 0.16, delay: 0.3, timing: easeInOut)
        fade(heap, to: 0, duration: 0.16, delay: 0.42, timing: easeInOut)
        fade(mouthLayer, to: 0, duration: 0.12, delay: 0.47, timing: easeInOut)
        keyframes(lid, "transform", [Self.hinge(0), Self.hinge(-90)].map { NSValue(caTransform3D: $0) }, times: [0, 1],
                  duration: 0.24, delay: 0.38, timing: CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45))
        fade(lid, to: 0, duration: 0.01, delay: 0.62)
        HelmMotion.withoutImplicitAnimation { dome.opacity = 1 }
        keyframes(dome, "transform", [Self.hinge(90), Self.hinge(-6, scaleY: 0.94), Self.hinge(0)].map { NSValue(caTransform3D: $0) },
                  times: [0, 0.7, 1], duration: 0.32, delay: 0.6, timing: CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.4, 1))
        keyframes(padlock, "transform", [Self.padlockOpen, CATransform3DIdentity].map { NSValue(caTransform3D: $0) },
                  times: [0, 1], duration: 0.2, delay: 0.86)
        fade(hold, to: 1, duration: 0.7, delay: 0.4, timing: easeInOut)
        fade(seam, to: 0.5, duration: 0.2, delay: 0.9)
        fade(seamGlow, to: 0.7, duration: 0.2, delay: 0.9)
        let generation = shutGeneration &+ 1
        shutGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, !self.isOpen, self.shutGeneration == generation else { return }
            self.startLoops()
        }
    }

    private var shutGeneration = 0

    /// A wrong password: the lining jolts and the light dips. The field keeps
    /// what was typed; that is the gate's job, not the scene's.
    func jolt() {
        guard isOpen else { return }
        keyframes(raysWrap, "opacity", [1, 0.3, 1], times: [0, 0.3, 1], duration: 0.7,
                  timing: CAMediaTimingFunction(name: .easeInEaseOut), keepModel: true)
        guard !reducedMotion else { return }
        keyframes(lid, "transform", [Self.hinge(0), Self.hinge(-40), Self.hinge(7), Self.hinge(0)].map { NSValue(caTransform3D: $0) },
                  times: [0, 0.35, 0.7, 1], duration: 0.56, timing: CAMediaTimingFunction(name: .easeInEaseOut), keepModel: true)
        keyframes(padlock, "transform", [Self.tilt(-8), Self.tilt(10), Self.tilt(-12), Self.tilt(-8)].map { NSValue(caTransform3D: $0) },
                  times: [0, 0.33, 0.66, 1], duration: 0.38, keepModel: true)
    }

    /// The rays pulse while the key is being derived.
    func setChecking(_ on: Bool) {
        guard on != checking else { return }
        checking = on
        startLoops()
    }

    /// The hover cue on a shut chest: the dome lifts a little and the seam brightens.
    func setHovering(_ on: Bool) {
        let lift = on && !isOpen && !reducedMotion
        guard lift != hovering else { return }
        hovering = lift
        keyframes(dome, "transform", [dome.presentation()?.transform ?? dome.transform, Self.hinge(lift ? 9 : 0)]
                    .map { NSValue(caTransform3D: $0) }, times: [0, 1], duration: 0.18,
                  timing: CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
        if lift {
            stopLoop(seam, "pulse")
            fade(seam, to: 1, duration: 0.12)
        } else {
            fade(seam, to: 0.5, duration: 0.12)
            startLoops()
        }
    }

    /// A star glints by the treasure (on each key while open).
    func glint() {
        guard isOpen, !reducedMotion, let point = VaultChestArt.sparks.randomElement() else { return }
        let star = CALayer()
        star.contents = VaultChestArt.star
        star.contentsGravity = .resize
        star.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        star.position = CGPoint(x: point.x, y: VaultChestArt.groupSize.height - point.y)
        star.opacity = 0
        let scale = CAKeyframeAnimation(keyPath: "transform")
        scale.values = [(0.2, 0), (1.2, 45), (0.3, 90)].map { s, deg in
            NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                                       CATransform3DMakeRotation(-deg * .pi / 180, 0, 0, 1)))
        }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 0]
        let group = CAAnimationGroup()
        for animation in [scale, opacity] { animation.keyTimes = [0, 0.4, 1] }
        group.animations = [scale, opacity]
        group.duration = 0.52
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { star.removeFromSuperlayer() }
        fx.addSublayer(star)
        star.add(group, forKey: "glint")
        CATransaction.commit()
    }

    // MARK: Loops

    /// Starts whichever loops the current state wants. Idempotent.
    func startLoops() {
        let reduced = reducedMotion || HelmMotion.isReduced
        if isOpen {
            stopLoop(seam, "pulse"); stopLoop(seamGlow, "pulse")
            if checking {
                stopLoop(rays, "sway")
                addLoop(rays, "pulse", keyPath: "opacity", from: 0.7, to: 1, duration: 1)
            } else {
                stopLoop(rays, "pulse")
                if !reduced {
                    addLoop(rays, "sway", keyPath: "transform.rotation.z", from: 5 * CGFloat.pi / 180,
                            to: -5 * CGFloat.pi / 180, duration: 9)
                }
            }
            guard !reduced else { return }
            for (i, star) in stars.enumerated() where star.animation(forKey: "twinkle") == nil {
                star.add(Self.twinkle(offset: CFTimeInterval(i) * 0.37), forKey: "twinkle")
            }
        } else {
            stopLoop(rays, "sway"); stopLoop(rays, "pulse")
            guard !reduced, !hovering else { return }
            addLoop(seam, "pulse", keyPath: "opacity", from: 0.35, to: 0.9, duration: 1.3)
            addLoop(seamGlow, "pulse", keyPath: "opacity", from: 0.35, to: 0.9, duration: 1.3)
        }
    }

    /// Stops every loop and every flying coin: the gate is no longer on screen.
    func stopLoops() {
        for (layer, key) in [(seam, "pulse"), (seamGlow, "pulse"), (rays, "sway"), (rays, "pulse")] { stopLoop(layer, key) }
        for star in stars { star.removeAnimation(forKey: "twinkle") }
        fx.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private static func twinkle(offset: CFTimeInterval) -> CAAnimation {
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = [(0.3, 0), (1, 45), (0.3, 0)].map { s, deg in
            NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                                       CATransform3DMakeRotation(-deg * .pi / 180, 0, 0, 1)))
        }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 0]
        let group = CAAnimationGroup()
        for animation in [transform, opacity] {
            animation.keyTimes = [0, 0.5, 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        }
        group.animations = [transform, opacity]
        group.duration = 2.2
        group.repeatCount = .infinity
        group.timeOffset = offset
        return group
    }

    private func addLoop(_ layer: CALayer, _ key: String, keyPath: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        guard layer.animation(forKey: key) == nil else { return }
        let loop = CABasicAnimation(keyPath: keyPath)
        loop.fromValue = from
        loop.toValue = to
        loop.duration = duration
        loop.autoreverses = true
        loop.repeatCount = .infinity
        loop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(loop, forKey: key)
    }

    private func stopLoop(_ layer: CALayer, _ key: String) {
        guard layer.animation(forKey: key) != nil else { return }
        layer.removeAnimation(forKey: key)
    }

    private func removeStateAnimations() {
        for layer in [dome, lid, padlock, mouthLayer, heap, spill, glow, formGlow, raysWrap, hold, seam, seamGlow, sparkles] as [CALayer] {
            layer.removeAllAnimations()
        }
        fx.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: Animation helpers

    /// Fades a layer's opacity to `to` after `delay`, holding its current
    /// value until then. The model takes the end value at once.
    private func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0,
                      timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = timing
        HelmMotion.withoutImplicitAnimation { layer.opacity = value }
        layer.add(animation, forKey: "fade")
    }

    /// A keyframe animation that leaves the model on its last value, or on
    /// the value it had (`keepModel`) for a there-and-back flourish.
    private func keyframes(_ layer: CALayer, _ keyPath: String, _ values: [Any], times: [NSNumber],
                           duration: CFTimeInterval, delay: CFTimeInterval = 0,
                           timing: CAMediaTimingFunction? = nil, keepModel: Bool = false) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = timing
        if !keepModel, let last = values.last {
            HelmMotion.withoutImplicitAnimation { layer.setValue(last, forKeyPath: keyPath) }
        }
        layer.add(animation, forKey: keyPath)
    }

    /// The board's `burst`: coins and gems thrown from the mouth on a fan,
    /// each on its own arc, spin and timing, then gone.
    private func burst(count: Int, height: CGFloat, spread: CGFloat, delay: CFTimeInterval) {
        guard !reducedMotion else { return }
        let start = CGPoint(x: VaultChestArt.mouth.x, y: VaultChestArt.groupSize.height - VaultChestArt.mouth.y)
        let now = CACurrentMediaTime()
        for i in 0..<count {
            let isCoin = i % 3 != 2
            let sprite = CALayer()
            sprite.contents = isCoin ? VaultChestArt.coinSprite : VaultChestArt.gemSprites[i % VaultChestArt.gemSprites.count]
            sprite.contentsGravity = .resize
            sprite.bounds = CGRect(x: 0, y: 0, width: isCoin ? 13 : 12, height: isCoin ? 13 : 12)
            sprite.position = start
            sprite.opacity = 0
            let dir = CGFloat((i * 37) % 100) / 100 - 0.5
            let dx = dir * spread, h = height * (0.65 + CGFloat((i * 53) % 35) / 100)
            let rot = CGFloat(i % 2 == 1 ? 1 : -1) * CGFloat(180 + (i * 47) % 360)
            // CSS's y runs down and its rotation is clockwise; this space is y-up.
            let points = [(0, 0, 0, 0.4), (dx * 0.25, h * 0.45, rot * 0.25, 1), (dx * 0.7, h, rot * 0.6, 1),
                          (dx, h * 0.35 - 24, rot, 0.85)] as [(CGFloat, CGFloat, CGFloat, CGFloat)]
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.values = points.map { x, y, deg, s in
                NSValue(caTransform3D: CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeRotation(-deg * .pi / 180, 0, 0, 1)),
                    CATransform3DMakeTranslation(x, y, 0)))
            }
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            for animation in [transform, opacity] { animation.keyTimes = [0, 0.15, 0.5, 1] }
            let group = CAAnimationGroup()
            group.animations = [transform, opacity]
            group.duration = 1.1 + CFTimeInterval((i * 61) % 420) / 1000
            group.beginTime = now + delay + CFTimeInterval((i * 23) % 160) / 1000
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.4, 1)
            group.isRemovedOnCompletion = true
            group.delegate = SpriteReaper(sprite)
            fx.addSublayer(sprite)
            sprite.add(group, forKey: "burst")
        }
    }

    #if FM_SELFTESTS
    var debugHoldOpacity: Float { hold.opacity }
    var debugLidOpacity: Float { lid.opacity }
    var debugDomeOpacity: Float { dome.opacity }
    var debugRaysOpacity: Float { raysWrap.opacity }
    var debugSeamPulsing: Bool { seam.animation(forKey: "pulse") != nil }
    var debugRaysLooping: Bool { rays.animation(forKey: "sway") != nil || rays.animation(forKey: "pulse") != nil }
    var debugTwinkling: Bool { stars.contains { $0.animation(forKey: "twinkle") != nil } }
    var debugFlyingCount: Int { fx.sublayers?.count ?? 0 }
    var debugHasArt: Bool { body.contents != nil && dome.contents != nil && heap.contents != nil }
    #endif
}

/// Removes a burst sprite when its flight ends.
private final class SpriteReaper: NSObject, CAAnimationDelegate {
    weak var sprite: CALayer?
    init(_ sprite: CALayer) { self.sprite = sprite }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { sprite?.removeFromSuperlayer() }
}

/// A full-bounds layer host that only ever takes a click on its hotspots.
final class ChestLayerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is ChestHotspotView ? hit : nil
    }
}

/// The chest's and the padlock's tap targets. They never take first
/// responder, so a click leaves the password field focused.
final class ChestHotspotView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var label = "" { didSet { setAccessibilityLabel(label) } }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    #if FM_SELFTESTS
    func debugClick() { onClick?() }
    #endif
}
