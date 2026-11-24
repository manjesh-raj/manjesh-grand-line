// Grand Line - native macOS app.
//
// The treasure chest the Secrets page's gate draws
// (`fm/grandline-login-lamp-design-scout`, board design S-1): an iron-bound
// wooden chest with a gold-banded dome lid, a velvet lid lining, a heap of
// coins, cut stones, gold bars, a goblet, a crown and pearls, and a gold
// padlock.
//
// **Why a separate file.** Like `LockSceneArt.swift`, these are pictures, not
// chrome. Wood, gold and gemstones are the picture's own paint, so they live
// here as fixed colours rather than as theme tokens. The page around the chest
// still takes its colours from the theme in `CredentialVaultUnlockView`.
//
// **Why a port of the board's generator.** The board drew the treasure with
// small functions (`coin`, `brilliant`, `stepCut`, `bar`, `goblet`, `crown`,
// `strand`) seeded by a fixed LCG, so the heap is the same pile every time.
// This file is a line-for-line port of those functions to Core Graphics: the
// same coordinates, the same seed, and SVG's `objectBoundingBox` gradient
// mapping, so a tweak can be made in either place and read the same. The one
// approximation is SVG's Gaussian blur filter, which becomes a soft radial
// falloff.
//
// Every coordinate below is in the board's own y-down space. Each image is a
// flipped `NSImage` drawing handler, so the drawing reads exactly like the SVG.

import AppKit

// MARK: - Paint

/// `0xRRGGBB` (and an optional alpha) to an sRGB colour, for the chest's own paint.
private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Linear interpolation between two colours' sRGB components (the board's `Lock.mixHex`).
private func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let t = max(0, min(1, t))
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
    return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                   green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                   blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                   alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * t)
}

/// A gradient in SVG's `objectBoundingBox` units: its geometry is in the unit
/// square of whatever shape it fills, so it stretches with that shape.
private struct Gradient {
    enum Shape {
        case linear(CGPoint, CGPoint)
        case radial(CGPoint, CGFloat)
    }
    let shape: Shape
    let cg: CGGradient

    init(_ shape: Shape, _ stops: [(CGFloat, NSColor)]) {
        self.shape = shape
        cg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: stops.map { $0.1.cgColor } as CFArray,
                        locations: stops.map(\.0))!
    }

    static func vertical(_ stops: [(CGFloat, NSColor)]) -> Gradient {
        Gradient(.linear(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)), stops)
    }
    static func horizontal(_ stops: [(CGFloat, NSColor)]) -> Gradient {
        Gradient(.linear(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)), stops)
    }
    /// The board's `rad(...)`: a lit-from-the-upper-left sphere.
    static func sphere(_ a: NSColor, _ b: NSColor, _ c: NSColor) -> Gradient {
        Gradient(.radial(CGPoint(x: 0.35, y: 0.3), 0.8), [(0, a), (0.4, b), (1, c)])
    }

    func draw(in c: CGContext) {
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch shape {
        case .linear(let a, let b):
            c.drawLinearGradient(cg, start: a, end: b, options: options)
        case .radial(let o, let r):
            c.drawRadialGradient(cg, startCenter: o, startRadius: 0, endCenter: o, endRadius: r, options: options)
        }
    }
}

/// The board's `<defs>`.
private enum Defs {
    static let wood = Gradient.vertical([(0, rgb(0xA2673D)), (0.55, rgb(0x74441F)), (1, rgb(0x4F2C14))])
    static let woodDome = Gradient.vertical([(0, rgb(0xB87A4C)), (0.7, rgb(0x7A4724)), (1, rgb(0x5A3318))])
    static let goldH = Gradient.horizontal([(0, rgb(0x8A5D18)), (0.2, rgb(0xF7D77C)), (0.48, rgb(0xE8B84E)),
                                            (0.82, rgb(0xBD872A)), (1, rgb(0x7D5314))])
    static let goldV = Gradient.vertical([(0, rgb(0xFFF0B4)), (0.35, rgb(0xEEC05A)), (0.75, rgb(0xC28D2E)),
                                          (1, rgb(0x8A5D18))])
    static let goldR = Gradient.sphere(rgb(0xFFF6CF), rgb(0xF0C457), rgb(0xA8751F))
    static let ruby = Gradient.sphere(rgb(0xFFD5DC), rgb(0xE2445C), rgb(0x6E1022))
    static let velvet = Gradient.vertical([(0, rgb(0x3A0B15)), (0.6, rgb(0x7A1D2C)), (1, rgb(0xA63347))])
    static let innerGlow = Gradient(.linear(CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0)),
                                    [(0, rgb(0xFFD68C, 0.8)), (0.55, rgb(0xFFD68C, 0.16)), (1, rgb(0xFFD68C, 0))])
    static let coinFaces = [18.0, 52.0, 84.0].map(coinFace)
    static let coinEdge = Gradient.vertical([(0, rgb(0xD9A640)), (0.55, rgb(0xA87418)), (1, rgb(0x6E4608))])
    static let pearl = Gradient(.radial(CGPoint(x: 0.36, y: 0.32), 0.75),
                                [(0, rgb(0xFFFFFF)), (0.3, rgb(0xF7F2EC)), (0.72, rgb(0xDDD1C6)), (1, rgb(0xA6958A))])
    static let barFront = Gradient.vertical([(0, rgb(0xF8DA7C)), (0.5, rgb(0xE0A93C)), (1, rgb(0xA26F17))])
    static let barTop = Gradient(.linear(CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
                                 [(0, rgb(0xF2C75C)), (0.6, rgb(0xFFF1BC)), (1, rgb(0xF6D27A))])
    static let metalBand = Gradient.horizontal([(0, rgb(0x8A5A12)), (0.18, rgb(0xF2C55A)), (0.3, rgb(0xFFF4C8)),
                                                (0.45, rgb(0xD49A32)), (0.7, rgb(0xF6D77C)), (0.86, rgb(0xB07A1C)),
                                                (1, rgb(0x6E4608))])
    static let bloom = Gradient(.radial(CGPoint(x: 0.5, y: 0.5), 0.5),
                                [(0, rgb(0xFFF4CD, 0.75)), (1, rgb(0xFFF4CD, 0))])

    /// A coin face: banded metal at an angle, so neighbouring coins catch the
    /// light differently (`gradientTransform="rotate(angle - 45 .5 .5)"`).
    static func coinFace(_ angle: Double) -> Gradient {
        let t = (angle - 45) * Double.pi / 180
        func rotate(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: 0.5 + x * CGFloat(cos(t)) - y * CGFloat(sin(t)),
                    y: 0.5 + x * CGFloat(sin(t)) + y * CGFloat(cos(t)))
        }
        return Gradient(.linear(rotate(-0.5, -0.5), rotate(0.5, 0.5)),
                        [(0, rgb(0xFFF9DE)), (0.16, rgb(0xFCE38E)), (0.38, rgb(0xEBB64C)), (0.56, rgb(0xFCDB74)),
                         (0.76, rgb(0xD39A32)), (1, rgb(0x946014))])
    }
}

/// A cut stone's six tones (the board's `STONES`).
private struct Stone {
    let hi: NSColor, light: NSColor, mid: NSColor, dark: NSColor, deep: NSColor, glow: NSColor

    static let ruby = Stone(hi: rgb(0xFFE0E6), light: rgb(0xFF5F7E), mid: rgb(0xD0204A), dark: rgb(0x740A24),
                            deep: rgb(0x3D0413), glow: rgb(0xFF466E, 0.55))
    static let sapphire = Stone(hi: rgb(0xE0ECFF), light: rgb(0x62A2FF), mid: rgb(0x2063D4), dark: rgb(0x0C2C78),
                                deep: rgb(0x061741), glow: rgb(0x5096FF, 0.5))
    static let emerald = Stone(hi: rgb(0xE0FFF1), light: rgb(0x46E3A6), mid: rgb(0x10A06A), dark: rgb(0x05573B),
                               deep: rgb(0x023121), glow: rgb(0x32E19B, 0.45))
    static let amethyst = Stone(hi: rgb(0xF6EBFF), light: rgb(0xC493FF), mid: rgb(0x8B47E2), dark: rgb(0x4B1B8E),
                                deep: rgb(0x2A0B53), glow: rgb(0xAF73FF, 0.45))
    static let topaz = Stone(hi: rgb(0xFFF5DC), light: rgb(0xFFC864), mid: rgb(0xE98A1C), dark: rgb(0x8C4807),
                             deep: rgb(0x4B2502), glow: rgb(0xFFAF46, 0.45))

    /// The order the board's burst cycles through (`GEMS`).
    static let burst: [Stone] = [.ruby, .sapphire, .emerald, .amethyst, .topaz]
}

// MARK: - The pen

/// The handful of SVG operations the board's chest uses, on a y-down context.
private struct Pen {
    let c: CGContext

    func path(_ d: String) -> CGPath { SVGPath.cgPath(d) }

    func polygon(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }

    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> CGPath {
        let box = CGRect(x: x, y: y, width: w, height: h)
        let radius = min(r, w / 2, h / 2)
        return radius > 0 ? CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
                          : CGPath(rect: box, transform: nil)
    }

    func fill(_ p: CGPath, _ color: NSColor) {
        c.addPath(p); c.setFillColor(color.cgColor); c.fillPath()
    }

    /// Fills with a gradient mapped to the shape's own bounding box.
    func fill(_ p: CGPath, _ g: Gradient) {
        let box = p.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return }
        c.saveGState()
        c.addPath(p); c.clip()
        c.concatenate(CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY))
        g.draw(in: c)
        c.restoreGState()
    }

    func stroke(_ p: CGPath, _ color: NSColor, _ width: CGFloat,
                cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
        c.addPath(p); c.setStrokeColor(color.cgColor); c.setLineWidth(width)
        c.setLineCap(cap); c.setLineJoin(join); c.strokePath()
    }

    /// Strokes with a gradient mapped to the path's geometry box, as SVG does.
    func stroke(_ p: CGPath, _ g: Gradient, _ width: CGFloat,
                cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
        let box = p.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return }
        c.saveGState()
        c.addPath(p); c.setLineWidth(width); c.setLineCap(cap); c.setLineJoin(join)
        c.replacePathWithStrokedPath(); c.clip()
        c.concatenate(CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY))
        g.draw(in: c)
        c.restoreGState()
    }

    func fillStroke(_ p: CGPath, _ fill: NSColor, _ stroke: NSColor, _ width: CGFloat) {
        self.fill(p, fill); self.stroke(p, stroke, width)
    }

    func fillStroke(_ p: CGPath, _ fill: Gradient, _ stroke: NSColor, _ width: CGFloat) {
        self.fill(p, fill); self.stroke(p, stroke, width)
    }

    /// SVG's `opacity` on one element or group.
    func faded(_ alpha: CGFloat, _ body: () -> Void) {
        c.saveGState(); c.setAlpha(alpha); body(); c.restoreGState()
    }

    /// An ellipse under SVG's `feGaussianBlur`, approximated by a radial
    /// falloff that starts a little inside the edge and ends a little past it.
    func soft(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: NSColor, blur: CGFloat) {
        let spread = blur * 1.6
        let ex = rx + spread, ey = ry + spread
        let edge = ((rx / ex) + (ry / ey)) / 2
        let solid = max(0, edge - (spread / max(ex, ey)) * 1.2)
        let g = Gradient(.radial(CGPoint(x: 0.5, y: 0.5), 0.5),
                         [(0, color), (solid, color), (edge, color.withAlphaComponent(color.alphaComponent * 0.5)),
                          (1, color.withAlphaComponent(0))])
        fill(ellipse(cx, cy, ex, ey), g)
    }

    /// The rotation in SVG's `rotate(deg cx cy)`, around `body`.
    func rotated(_ degrees: CGFloat, about x: CGFloat, _ y: CGFloat, _ body: () -> Void) {
        c.saveGState()
        c.translateBy(x: x, y: y); c.rotate(by: degrees * .pi / 180); c.translateBy(x: -x, y: -y)
        body()
        c.restoreGState()
    }
}

// MARK: - The board's drawing functions

private extension Pen {
    func rivet(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 2.1) {
        let dot = ellipse(x, y, r, r)
        fill(dot, Defs.goldR)
        stroke(dot, rgb(0x6E4710), 0.6)
        fill(ellipse(x - r * 0.3, y - r * 0.35, r * 0.32, r * 0.32), rgb(0xFFFBE6, 0.9))
    }

    func curl(_ x: CGFloat, _ y: CGFloat, _ sx: CGFloat = 1, _ sy: CGFloat = 1) {
        let d = "M\(x) \(y) q\(6 * sx) \(1 * sy) \(5 * sx) \(7 * sy) q\(-1 * sx) \(4 * sy) \(-4.5 * sx) \(2.5 * sy) "
            + "q\(-2 * sx) \(-1.5 * sy) \(-0.2 * sx) \(-3 * sy)"
        stroke(path(d), rgb(0xF6D47A), 1.4, cap: .round)
    }

    /// A small faceted gem, as on the dome's medallion.
    func facetGem(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ g: Gradient, _ dark: NSColor) {
        c.saveGState()
        c.translateBy(x: x, y: y); c.scaleBy(x: s, y: s)
        let body = path("M0 -6 L5 -1.5 L0 6 L-5 -1.5 Z")
        fill(body, g); stroke(body, dark, 0.7)
        fill(path("M0 -6 L2.2 -1.5 L0 1.6 L-2.2 -1.5 Z"), rgb(0xFFFFFF, 0.42))
        stroke(path("M-5 -1.5 H5"), rgb(0xFFFFFF, 0.35), 0.5)
        c.restoreGState()
    }

    func grain(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) {
        let w = x2 - x1
        stroke(path("M\(x1) \(y) q\(w / 4) -2.4 \(w / 2) 0 t\(w / 2) 0"), rgb(0x281408, 0.3), 0.8)
    }

    func sparkle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        let k = r * 0.22
        let star = polygon([CGPoint(x: x, y: y - r), CGPoint(x: x + k, y: y - k), CGPoint(x: x + r, y: y),
                            CGPoint(x: x + k, y: y + k), CGPoint(x: x, y: y + r), CGPoint(x: x - k, y: y + k),
                            CGPoint(x: x - r, y: y), CGPoint(x: x - k, y: y - k)])
        fill(star, rgb(0xFFFFFF, 0.95))
    }

    /// A facet's tone from its angle to the light, which comes from the upper left.
    static func lit(_ angle: CGFloat) -> CGFloat { (1 + cos(angle - (-2.35))) / 2 }

    /// A round brilliant seen from above at an angle: crown facets around a
    /// table, and the pavilion below.
    func brilliant(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ g: Stone) {
        let sq: CGFloat = 0.74, n = 8
        var out: [(CGPoint, CGFloat)] = [], tab: [CGPoint] = []
        for i in 0..<n {
            let a = -CGFloat.pi / 2 + (CGFloat(i) + 0.5) * (2 * .pi / CGFloat(n))
            out.append((CGPoint(x: x + r * cos(a), y: y + r * sq * sin(a)), a))
            tab.append(CGPoint(x: x + r * 0.5 * cos(a), y: y - r * 0.1 + r * 0.5 * sq * sin(a)))
        }
        soft(x, y + r * 0.85, r * 1.4, r * 0.55, g.glow, blur: 1.6)
        let cul = CGPoint(x: x, y: y + r * 0.98)
        let gird = (0...4).map { k -> CGPoint in
            let t = CGFloat(k) / 4 * .pi
            return CGPoint(x: x + r * cos(t), y: y + r * sq * sin(t))
        }
        let pavilion = [g.dark, g.mid, g.light, g.deep]
        for k in 0..<4 { fill(polygon([gird[k], gird[k + 1], cul]), pavilion[k]) }
        let crown = polygon(out.map(\.0))
        fillStroke(crown, g.mid, g.deep, 0.45)
        for i in 0..<n {
            let j = (i + 1) % n
            let angle = (out[i].1 + out[j].1) / 2 + (j == 0 ? .pi : 0)
            fillStroke(polygon([out[i].0, out[j].0, tab[j], tab[i]]), mix(g.dark, g.light, Self.lit(angle)),
                       mix(g.deep, g.mid, 0.5), 0.25)
        }
        fillStroke(polygon(tab), mix(g.mid, g.hi, 0.55), g.light, 0.3)
        fill(polygon([tab[5], tab[6], CGPoint(x: x - r * 0.05, y: y - r * 0.05)]), rgb(0xFFFFFF, 0.55))
        sparkle(x - r * 0.28, y - r * 0.38, r * 0.42)
    }

    /// A step cut (emerald cut): nested octagonal rings, each side shaded by
    /// its angle to the light.
    func stepCut(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ g: Stone) {
        func ring(_ s: CGFloat) -> [CGPoint] {
            let a = w * s / 2, b = h * s / 2, k = min(a, b) * 0.42
            return [CGPoint(x: x - a + k, y: y - b), CGPoint(x: x + a - k, y: y - b), CGPoint(x: x + a, y: y - b + k),
                    CGPoint(x: x + a, y: y + b - k), CGPoint(x: x + a - k, y: y + b), CGPoint(x: x - a + k, y: y + b),
                    CGPoint(x: x - a, y: y + b - k), CGPoint(x: x - a, y: y - b + k)]
        }
        let angles: [CGFloat] = [-.pi / 2, -.pi / 4, 0, .pi / 4, .pi / 2, 3 * .pi / 4, .pi, -3 * .pi / 4]
        soft(x, y + h * 0.5, w * 0.75, h * 0.45, g.glow, blur: 1.6)
        fillStroke(polygon(ring(1)), g.dark, g.deep, 0.5)
        for (k, pair) in [(CGFloat(1), CGFloat(0.74)), (0.74, 0.5)].enumerated() {
            let o = ring(pair.0), i = ring(pair.1)
            for f in 0..<8 {
                let f2 = (f + 1) % 8
                fillStroke(polygon([o[f], o[f2], i[f2], i[f]]),
                           mix(g.deep, g.light, Self.lit(angles[f] + 0.4) * (k == 1 ? 1 : 0.9)),
                           mix(g.deep, g.mid, 0.4), 0.25)
            }
        }
        let table = ring(0.5)
        fillStroke(polygon(table), mix(g.mid, g.hi, 0.45), g.light, 0.3)
        fill(polygon([table[7], table[0], table[1], CGPoint(x: x - w * 0.05, y: y - h * 0.02)]), rgb(0xFFFFFF, 0.45))
        sparkle(x - w * 0.2, y - h * 0.25, min(w, h) * 0.32)
    }

    /// Points along the lower half of an ellipse, left to right.
    static func lowerHalf(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                          reversed: Bool = false) -> [CGPoint] {
        let points = (0...18).map { k -> CGPoint in
            let t = CGFloat.pi - CGFloat.pi * CGFloat(k) / 18
            return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        }
        return reversed ? points.reversed() : points
    }

    /// A coin as a disc: a reeded edge underneath, a banded face, a raised rim
    /// and an embossed centre.
    func coin(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ tilt: CGFloat, _ rot: CGFloat, _ dim: CGFloat, _ face: Int) {
        let ry = r * tilt, th = max(1.1, r * 0.2)
        rotated(rot, about: x, y) {
            let band = CGMutablePath()
            band.addLines(between: Self.lowerHalf(x, y, r, ry) + Self.lowerHalf(x, y + th, r, ry, reversed: true))
            band.closeSubpath()
            fill(band, Defs.coinEdge)
            // The reeding: SVG's userSpaceOnUse pattern of 0.5-wide strokes every 1.3.
            c.saveGState()
            c.addPath(band); c.clip()
            c.setFillColor(rgb(0x3C2406, 0.35).cgColor)
            var stripe = (floor((x - r) / 1.3)) * 1.3
            while stripe < x + r {
                c.fill(CGRect(x: stripe, y: y - ry, width: 0.5, height: ry * 2 + th + 1))
                stripe += 1.3
            }
            c.restoreGState()
            let top = ellipse(x, y, r, ry)
            fill(top, Defs.coinFaces[face])
            stroke(top, rgb(0x86560F), 0.4)
            stroke(ellipse(x, y, r * 0.8, ry * 0.8), rgb(0x704608, 0.6), 0.55)
            let rim = CGMutablePath()
            let end = atan2(-0.77 / 0.8, 0.3 / 0.8) + 2 * .pi
            rim.addLines(between: (0...14).map { k -> CGPoint in
                let t = .pi + (end - .pi) * CGFloat(k) / 14
                return CGPoint(x: x + r * 0.8 * cos(t), y: y + ry * 0.8 * sin(t))
            })
            stroke(rim, rgb(0xFFFAE2, 0.9), 0.55)
            fill(ellipse(x + r * 0.04, y + ry * 0.05, r * 0.34, ry * 0.34), rgb(0x8C5A10, 0.35))
            fill(ellipse(x - r * 0.06, y - ry * 0.06, r * 0.2, ry * 0.2), rgb(0xFFF0BE, 0.55))
            if dim > 0 {
                fill(ellipse(x, y + th / 2, r + 0.3, ry + th / 2 + 0.3), rgb(0x783A00, dim))
            }
        }
    }

    func stack(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ n: Int, _ seed: UInt32) {
        var rand = VaultChestArt.Random(seed)
        for k in 0..<n {
            let dx = (rand.next() - 0.5) * 1.6
            let rot = (rand.next() - 0.5) * 6
            coin(x + dx, y - CGFloat(k) * r * 0.21, r, 0.4, rot, 0, k % 3)
        }
    }

    func pearl(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 2.1) {
        soft(x + 0.4, y + r * 0.9, r, r * 0.45, rgb(0x281404, 0.35), blur: 0.9)
        fill(ellipse(x, y, r, r), Defs.pearl)
        fill(ellipse(x - r * 0.35, y - r * 0.38, r * 0.28, r * 0.28), rgb(0xFFFFFF))
    }

    static func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * b.x + t * t * c.x, y: u * u * a.y + 2 * u * t * b.y + t * t * c.y)
    }

    func strand(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, step: CGFloat = 4.3, r: CGFloat = 2.05) {
        var length: CGFloat = 0, previous = p0
        for i in 1...60 {
            let q = Self.bezier(p0, p1, p2, CGFloat(i) / 60)
            length += hypot(q.x - previous.x, q.y - previous.y)
            previous = q
        }
        let n = max(2, Int((length / step).rounded()))
        for i in 0...n {
            let q = Self.bezier(p0, p1, p2, CGFloat(i) / CGFloat(n))
            pearl(q.x, q.y, r)
        }
    }

    /// A trapezoidal gold bar with a stamped top.
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ d: CGFloat) {
        let k: CGFloat = 3.2
        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: px, y: py) }
        fillStroke(polygon([p(x, y), p(x + w, y), p(x + w - k, y - h), p(x + k, y - h)]), Defs.barFront,
                   rgb(0x86560F), 0.5)
        fillStroke(polygon([p(x + w, y), p(x + w + d, y - d * 0.55), p(x + w - k + d, y - h - d * 0.55),
                            p(x + w - k, y - h)]), rgb(0x9C6814), rgb(0x6E4608), 0.4)
        fillStroke(polygon([p(x + k, y - h), p(x + w - k, y - h), p(x + w - k + d, y - h - d * 0.55),
                            p(x + k + d, y - h - d * 0.55)]), Defs.barTop, rgb(0x86560F), 0.4)
        stroke(polygon([p(x + k + 3, y - h - 0.7), p(x + w - k - 3, y - h - 0.7),
                        p(x + w - k - 3 + d * 0.7, y - h - d * 0.45), p(x + k + 3 + d * 0.7, y - h - d * 0.45)]),
               rgb(0x966010, 0.6), 0.45)
        stroke(path("M\(x + k) \(y - h) H\(x + w - k)"), rgb(0xFFFADC, 0.9), 0.5)
    }

    func goblet(_ x: CGFloat, _ y: CGFloat) {
        let foot = ellipse(x, y + 27, 7.5, 2.2)
        fillStroke(foot, Defs.metalBand, rgb(0x6E4608), 0.4)
        fill(path("M\(x - 1.4) \(y + 13) H\(x + 1.4) L\(x + 1.8) \(y + 26) H\(x - 1.8) Z"), Defs.metalBand)
        fillStroke(ellipse(x, y + 17, 2.6, 1.5), Defs.metalBand, rgb(0x6E4608), 0.3)
        fillStroke(path("M\(x - 8) \(y) Q\(x - 8) \(y + 12) \(x) \(y + 13.5) Q\(x + 8) \(y + 12) \(x + 8) \(y) Z"),
                   Defs.metalBand, rgb(0x6E4608), 0.5)
        fillStroke(ellipse(x, y, 8, 2.3), rgb(0x5A3606), rgb(0xF6D77C), 0.7)
        stroke(path("M\(x - 7.4) \(y + 4) Q\(x) \(y + 6.2) \(x + 7.4) \(y + 4)"), rgb(0x6E4608, 0.6), 0.6)
        brilliant(x, y + 8, 2.3, .ruby)
    }

    func crown(_ x: CGFloat, _ y: CGFloat) {
        let tips = [-13, -6.5, 0, 6.5, 13].enumerated().map { i, dx in
            CGPoint(x: x + CGFloat(dx), y: y - (i % 2 == 1 ? 9 : 13))
        }
        fill(path("M\(x - 13) \(y) Q\(x) \(y - 17) \(x + 13) \(y) Z"), rgb(0x8C1A2E))
        stroke(path("M\(x - 8) \(y - 6) Q\(x) \(y - 13) \(x + 8) \(y - 6)"), rgb(0xFFBEC8, 0.35), 1)
        let body = "M\(x - 15) \(y) L\(tips[0].x) \(tips[0].y) L\(x - 9.6) \(y - 4) L\(tips[1].x) \(tips[1].y) "
            + "L\(x - 3) \(y - 4.5) L\(tips[2].x) \(tips[2].y) L\(x + 3) \(y - 4.5) L\(tips[3].x) \(tips[3].y) "
            + "L\(x + 9.6) \(y - 4) L\(tips[4].x) \(tips[4].y) L\(x + 15) \(y) Z"
        fillStroke(path(body), Defs.metalBand, rgb(0x6E4608), 0.5)
        fillStroke(path("M\(x - 15.5) \(y) Q\(x) \(y + 3) \(x + 15.5) \(y) V\(y + 4.4) "
                        + "Q\(x) \(y + 7.4) \(x - 15.5) \(y + 4.4) Z"), Defs.metalBand, rgb(0x6E4608), 0.5)
        for tip in tips { pearl(tip.x, tip.y - 1, 1.5) }
        brilliant(x - 8, y + 3, 1.8, .sapphire)
        brilliant(x, y + 3.6, 2.2, .ruby)
        brilliant(x + 8, y + 3, 1.8, .emerald)
    }
}

// MARK: - The parts

enum VaultChestArt {

    /// The board's seeded LCG (`rng(seed)`), so the heap is the same pile every time.
    struct Random {
        private var value: UInt32
        init(_ seed: UInt32) { value = seed }
        mutating func next() -> CGFloat {
            value = value &* 1664525 &+ 1013904223
            return CGFloat(Double(value) / 4294967296)
        }
    }

    // The chest group's layout, in its own y-down space: the board's stage
    // coordinates less (488, 500). Its centre line is x = 122.
    static let groupSize = CGSize(width: 244, height: 202)
    /// Where treasure leaves the chest.
    static let mouth = CGPoint(x: 122, y: 84)
    static let shadowFrame = CGRect(x: 0, y: 172, width: 244, height: 30)
    static let lidFrame = CGRect(x: 34, y: 6, width: 176, height: 86)
    static let mouthFrame = CGRect(x: 38, y: 80, width: 168, height: 16)
    static let heapFrame = CGRect(x: 34, y: 24, width: 176, height: 72)
    /// The body's image is 6pt wider each side than the board's 184pt box,
    /// because its side handles hang outside it.
    static let bodyFrame = CGRect(x: 24, y: 88, width: 196, height: 104)
    static let spillFrame = CGRect(x: 46, y: 78, width: 152, height: 40)
    static let domeFrame = CGRect(x: 26, y: 40, width: 192, height: 54)
    static let seamFrame = CGRect(x: 36, y: 87, width: 172, height: 3)
    static let padlockFrame = CGRect(x: 104, y: 94, width: 36, height: 44)
    /// The chest's tap target.
    static let hitFrame = CGRect(x: 20, y: 0, width: 204, height: 192)
    /// Where the resting twinkles sit while the chest is open.
    static let sparks: [CGPoint] = [CGPoint(x: 72, y: 60), CGPoint(x: 174, y: 52), CGPoint(x: 110, y: 40),
                                    CGPoint(x: 148, y: 66), CGPoint(x: 60, y: 90), CGPoint(x: 188, y: 86),
                                    CGPoint(x: 124, y: 12)]

    /// The light the open chest throws, and the dark while it is shut. Fixed,
    /// like the gold: it is the treasure's light, not the page's.
    struct Light {
        let holdCentre: NSColor
        let holdEdge: NSColor
        let glow: NSColor
        let ray: NSColor
        let seam: NSColor
        let seamGlow: NSColor
        let formGlow: NSColor
        let flood: NSColor
        let mouthTop: NSColor
        let mouthBottom: NSColor
        let shadow: NSColor
        let star: NSColor
        /// The board's `--chest-filter: brightness(.82)` in the dark register.
        let dim: CGFloat

        static func forDarkRegister(_ dark: Bool) -> Light {
            Light(holdCentre: dark ? rgb(0x281A1A, 0.66) : rgb(0x3A262A, 0.62),
                  holdEdge: dark ? rgb(0x05050E, 0.95) : rgb(0x18142C, 0.93),
                  glow: rgb(0xFFCE78),
                  ray: rgb(0xFFD680, 0.34),
                  seam: rgb(0xFFE3A0),
                  seamGlow: rgb(0xFFC46E, 0.34),
                  formGlow: rgb(0xFFD282, 0.2),
                  flood: rgb(0xFFF6D8),
                  mouthTop: rgb(0x1F130B),
                  mouthBottom: rgb(0x3A2414),
                  shadow: rgb(0x0A0612, 0.5),
                  star: rgb(0xFFF6D8),
                  dim: dark ? 0.18 : 0)
        }
    }

    /// V-4 Open's avatar: a gold coin of a tile.
    enum Avatar {
        static let top = rgb(0xF6D47E)
        static let bottom = rgb(0xC9902E)
        static let glyph = rgb(0x3A2408)
        static let ring = rgb(0xFFFFFF, 0.7)
        static let shadow = rgb(0x785014)
    }

    // MARK: Images

    static func body(dim: CGFloat) -> NSImage {
        image(bodyFrame.size, dim: dim) { pen in
            pen.c.translateBy(x: 6, y: 0)
            drawBody(pen)
        }
    }
    static func dome(dim: CGFloat) -> NSImage { image(domeFrame.size, dim: dim, draw: drawDome) }
    static func lid(dim: CGFloat) -> NSImage { image(lidFrame.size, dim: dim, draw: drawLid) }
    static func heap(dim: CGFloat) -> NSImage { image(heapFrame.size, dim: dim, draw: drawHeap) }
    static func spill(dim: CGFloat) -> NSImage { image(spillFrame.size, dim: dim, draw: drawSpill) }
    /// The padlock shows a fingerprint when Touch ID can open the vault, and a keyhole otherwise.
    static func padlock(dim: CGFloat, touchID: Bool) -> NSImage {
        image(padlockFrame.size, dim: dim) { drawPadlock($0, touchID: touchID) }
    }

    /// A flying coin, face on.
    static let coinSprite: NSImage = image(CGSize(width: 14, height: 14), dim: 0) { pen in
        pen.coin(7, 6.4, 6.2, 0.92, 0, 0, 0)
    }

    /// A flying gem, one per burst stone.
    static let gemSprites: [NSImage] = Stone.burst.map { stone in
        image(CGSize(width: 12, height: 12), dim: 0) { pen in
            let g = Gradient.sphere(stone.hi, stone.mid, stone.deep)
            pen.facetGem(6, 6, 1, g, stone.deep)
        }
    }

    /// The four-point twinkle.
    static let star: NSImage = image(CGSize(width: 14, height: 14), dim: 0) { pen in
        pen.fill(pen.path("M7 0 L8.2 5.8 L14 7 L8.2 8.2 L7 14 L5.8 8.2 L0 7 L5.8 5.8 Z"), rgb(0xFFF6D8))
    }

    private static func image(_ size: CGSize, dim: CGFloat, draw: @escaping (Pen) -> Void) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            draw(Pen(c: ctx))
            ctx.restoreGState()
            if dim > 0 {
                // Darken only where the chest is drawn.
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(rgb(0x000000, dim).cgColor)
                ctx.fill(rect)
            }
            return true
        }
    }

    // MARK: Drawing

    private static func drawBody(_ p: Pen) {
        p.stroke(p.path("M5 34 C-5 36 -5 52 5 54 M179 34 C189 36 189 52 179 54"), Defs.goldV, 3.6, cap: .round)
        for (x, y) in [(5, 34), (5, 54), (179, 34), (179, 54)] as [(CGFloat, CGFloat)] { p.rivet(x, y) }
        p.fillStroke(p.rect(4, 5, 176, 84, r: 5), Defs.wood, rgb(0x3A200E), 1.4)
        p.faded(0.55) { p.stroke(p.path("M6 33 H178 M6 61 H178"), rgb(0x2F1909), 2.2) }
        p.faded(0.4) { p.stroke(p.path("M6 35.2 H178 M6 63.2 H178"), rgb(0xC48A5A), 0.8) }
        for (y1, y2) in [(16, 44), (24, 52), (44, 72), (50, 78)] as [(CGFloat, CGFloat)] {
            p.grain(44, 140, y1); p.grain(8, 24, y2); p.grain(160, 176, y2)
        }
        p.grain(44, 140, 80); p.grain(52, 136, 22)
        p.fillStroke(p.rect(0, 86, 184, 10, r: 3), rgb(0x4A2A14), rgb(0x2A1608), 0.8)
        p.fill(p.rect(0, 86, 184, 3.4, r: 1.5), Defs.goldV)
        p.fillStroke(p.path("M8 96 h16 l-2.4 6 h-11.2 z M160 96 h16 l-2.4 6 h-11.2 z"), Defs.goldV, rgb(0x6E4710), 0.6)
        p.fillStroke(p.rect(1, 1, 182, 9, r: 3), Defs.goldV, rgb(0x6E4710), 0.8)
        for x in [12, 34, 56, 128, 150, 172] as [CGFloat] { p.rivet(x, 5.6, 1.8) }
        p.fillStroke(p.rect(26, 9, 14, 78), Defs.goldH, rgb(0x6E4710), 0.7)
        p.fillStroke(p.rect(144, 9, 14, 78), Defs.goldH, rgb(0x6E4710), 0.7)
        for y in [20, 47, 74] as [CGFloat] { p.rivet(33, y); p.rivet(151, y) }
        p.stroke(p.path("M5 64 V87 H25 M179 64 V87 H159 M5 28 V10 M179 28 V10"), Defs.goldV, 5, join: .round)
        p.curl(9, 68); p.curl(175, 68, -1); p.curl(9, 25, 1, -1); p.curl(175, 25, -1, -1)
        p.fillStroke(p.path("M72 9 H112 V33 Q112 48 92 55 Q72 48 72 33 Z"), Defs.goldH, rgb(0x6E4710), 1)
        p.faded(0.85) {
            p.stroke(p.path("M76.5 13 H107.5 V32.5 Q107.5 44.5 92 50.5 Q76.5 44.5 76.5 32.5 Z"), rgb(0x8A5D18), 0.9)
        }
        p.curl(79, 14); p.curl(105, 14, -1); p.rivet(76.6, 12.4, 1.6); p.rivet(107.4, 12.4, 1.6)
        p.fillStroke(p.rect(86, 0, 12, 16, r: 2), Defs.goldH, rgb(0x6E4710), 0.8)
    }

    private static func drawDome(_ p: Pen) {
        let shell = p.path("M4 52 C4 15 42 3 96 3 C150 3 188 15 188 52 Z")
        p.fillStroke(shell, Defs.woodDome, rgb(0x3A200E), 1.4)
        p.c.saveGState()
        p.c.addPath(shell); p.c.clip()
        p.faded(0.5) {
            p.stroke(p.path("M4 38 C32 22 62 17 96 17 C130 17 160 22 188 38 M4 26 C34 11 64 7 96 7 C128 7 158 11 188 26"),
                     rgb(0x2F1909), 1.8)
        }
        p.stroke(p.path("M60 30 q18 -3 36 0 t36 0 M70 13 q13 -2 26 0 t26 0"), rgb(0x281408, 0.3), 0.8)
        p.fill(p.rect(27, 0, 16, 54), Defs.goldH)
        p.fill(p.rect(149, 0, 16, 54), Defs.goldH)
        p.rivet(35, 16); p.rivet(35, 32); p.rivet(157, 16); p.rivet(157, 32)
        p.stroke(p.path("M22 32 C42 12 84 7 124 9"), rgb(0xFFF0D7, 0.2), 6, cap: .round)
        p.c.restoreGState()
        p.stroke(p.path("M4 52 C4 15 42 3 96 3 C150 3 188 15 188 52"), Defs.goldV, 2.2)
        p.fillStroke(p.rect(0, 45, 192, 8.6, r: 2.5), Defs.goldV, rgb(0x6E4710), 0.8)
        for x in [12, 62, 130, 180] as [CGFloat] { p.rivet(x, 49.3, 1.8) }
        p.fillStroke(p.ellipse(96, 26, 14.5, 11.5), Defs.goldR, rgb(0x6E4710), 1)
        p.stroke(p.ellipse(96, 26, 10.8, 8.3), rgb(0x8A5D18), 0.8)
        p.curl(83, 21); p.curl(109, 21, -1)
        p.facetGem(96, 26, 1.15, Defs.ruby, rgb(0x5A0C1A))
    }

    private static func drawLid(_ p: Pen) {
        p.fillStroke(p.rect(0, 0, 176, 86, r: 10), Defs.wood, rgb(0x3A200E), 1.2)
        p.fill(p.rect(9, 9, 158, 74, r: 6), Defs.velvet)
        p.stroke(p.path("M9 14 L48 83 M38 9 L87 83 M77 9 L126 83 M116 9 L165 83 M167 14 L128 83 M138 9 L89 83 "
                        + "M99 9 L50 83 M60 9 L11 83"), rgb(0x000000, 0.22), 0.8)
        for row in 0..<3 {
            for col in 0..<6 {
                let x = 26 + CGFloat(col) * 25 + (row % 2 == 1 ? 12.5 : 0), y = 24 + CGFloat(row) * 20
                guard x < 160 else { continue }
                p.fill(p.ellipse(x, y, 1.6, 1.6), rgb(0x2A0710))
                p.fill(p.ellipse(x - 0.5, y - 0.5, 0.5, 0.5), rgb(0xFFC8C8, 0.5))
            }
        }
        p.fill(p.rect(9, 9, 158, 74, r: 6), Defs.innerGlow)
        p.stroke(p.path("M2 22 V3 H22 M174 22 V3 H154"), Defs.goldV, 4, join: .round)
        p.rivet(6, 6, 1.6); p.rivet(170, 6, 1.6)
        p.fill(p.rect(0, 80, 176, 6), Defs.goldV)
    }

    private static func drawHeap(_ p: Pen) {
        // The board's viewBox starts at y = -16.
        p.c.translateBy(x: 0, y: 16)
        var rand = Random(7)
        func mound(_ x: CGFloat, _ peak: CGFloat) -> CGFloat { 48 - peak * (1 - pow((x - 88) / 84, 2)) }
        typealias CoinSpec = (x: CGFloat, y: CGFloat, r: CGFloat, tilt: CGFloat, rot: CGFloat, dim: CGFloat, face: Int)
        func row(from start: CGFloat, to end: CGFloat, by step: CGFloat, jitter: CGFloat,
                 y: (CGFloat) -> CGFloat, r: CGFloat, tilt: CGFloat, tiltSpread: CGFloat,
                 rot: CGFloat, dim: CGFloat) -> [CoinSpec] {
            var out: [CoinSpec] = []
            var x = start
            while x <= end {
                // The board's argument order, so the seeded pile matches it.
                let cx = x + (rand.next() - 0.5) * jitter
                let cy = y(x) + (rand.next() - 0.5) * 3
                let t = tilt + rand.next() * tiltSpread
                let angle = (rand.next() - 0.5) * rot
                let face = min(2, Int(rand.next() * 3))
                out.append((cx, cy, r, t, angle, dim, face))
                x += step
            }
            return out
        }
        let back = row(from: 12, to: 164, by: 7.2, jitter: 3, y: { mound($0, 30) + 4 }, r: 6.4,
                       tilt: 0.34, tiltSpread: 0.12, rot: 40, dim: 0.2)
        let middle = row(from: 16, to: 160, by: 8.6, jitter: 4, y: { mound($0, 22) + 6 }, r: 7.4,
                         tilt: 0.36, tiltSpread: 0.12, rot: 34, dim: 0.07)
        let front = row(from: 10, to: 166, by: 10, jitter: 4, y: { _ in 44 }, r: 8.4,
                        tilt: 0.4, tiltSpread: 0.1, rot: 26, dim: 0)
        func draw(_ coins: [CoinSpec]) {
            for coin in coins { p.coin(coin.x, coin.y, coin.r, coin.tilt, coin.rot, coin.dim, coin.face) }
        }

        p.soft(88, 40, 86, 18, rgb(0xFFC45C, 0.55), blur: 1.6)
        draw(back)
        p.bar(10, 34, 30, 7.5, 5); p.bar(15, 27, 30, 7.5, 5); p.bar(20, 20, 30, 7.5, 5)
        p.goblet(66, -6)
        p.crown(136, 18)
        draw(middle)
        p.coin(100, 22, 7, 0.32, 78, 0, 1); p.coin(36, 30, 6.6, 0.32, -72, 0, 0)
        p.brilliant(46, 27, 7.6, .ruby); p.stepCut(92, 21, 16, 11.5, .emerald); p.brilliant(130, 32, 7, .sapphire)
        p.brilliant(76, 34, 5.6, .amethyst); p.stepCut(112, 35, 10.5, 8, .topaz)
        draw(front)
        p.stack(12, 46, 7.8, 5, 3); p.stack(164, 46, 7.4, 4, 9)
        p.strand(CGPoint(x: 26, y: 41), CGPoint(x: 88, y: 58), CGPoint(x: 152, y: 38))
        p.brilliant(118, 45, 4.4, .ruby); p.brilliant(58, 46, 3.8, .emerald); p.brilliant(146, 44, 3.6, .amethyst)
        p.c.saveGState()
        p.c.setBlendMode(.screen)
        p.c.setAlpha(0.6)
        p.fill(p.ellipse(88, 26, 70, 20), Defs.bloom)
        p.c.restoreGState()
    }

    /// Coins tipped over the front rim, and a loop of pearls hanging down the front.
    private static func drawSpill(_ p: Pen) {
        p.strand(CGPoint(x: 18, y: 8), CGPoint(x: 34, y: 38), CGPoint(x: 58, y: 9), step: 4.1, r: 1.95)
        p.coin(12, 10, 7, 0.42, 16, 0, 0); p.coin(24, 13, 6.4, 0.4, -10, 0, 2); p.coin(9, 20, 6.2, 0.3, 74, 0, 1)
        p.coin(134, 11, 7, 0.42, -18, 0, 1); p.coin(146, 18, 6, 0.3, -76, 0, 0)
        p.brilliant(118, 8, 3.8, .sapphire)
    }

    private static func drawPadlock(_ p: Pen, touchID: Bool) {
        // The board's shackle is `a8 8 0 0 1 16 0`; two quarter circles draw the same arc.
        let shackle = p.path("M10 18 V12 C10 7.582 13.582 4 18 4 C22.418 4 26 7.582 26 12 V18")
        p.stroke(shackle, rgb(0x8A5D18), 5.2)
        p.stroke(shackle, Defs.goldV, 3.6)
        p.fillStroke(p.path("M3 18 H33 V31 Q33 41 18 43 Q3 41 3 31 Z"), Defs.goldH, rgb(0x6E4710), 1.1)
        p.faded(0.85) {
            p.stroke(p.path("M6.5 21 H29.5 V30.6 Q29.5 38.4 18 40 Q6.5 38.4 6.5 30.6 Z"), rgb(0x8A5D18), 0.8)
        }
        p.rivet(7, 21.5, 1.2); p.rivet(29, 21.5, 1.2)
        if touchID, let glyph = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [rgb(0x5A3B12)]))) {
            let side: CGFloat = 15
            glyph.draw(in: CGRect(x: 18 - side / 2, y: 30.5 - side / 2, width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            p.fill(p.ellipse(18, 27.5, 3.2, 3.2), rgb(0x4A3110))
            p.fill(p.path("M16.4 29 h3.2 l1.1 6.4 h-5.4 z"), rgb(0x4A3110))
        }
    }
}
