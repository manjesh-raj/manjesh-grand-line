// Grand Line - native macOS app.
//
// The illustrations the lock screen draws: the Going Merry, the lighthouse on
// its cliff, and the sea fog's noise texture
// (`fm/grandline-login-lamp-design-scout`, board design L-2).
//
// **Why a separate file.** These are pictures, not chrome. Their paint (the
// ship's wood and sail, the Jolly Roger) is the picture's own, while every
// colour the *screen* uses still resolves from the theme in
// `LockScreenController`. `LockScreenSelfTest.checkSharedComponentsAndNoLiterals`
// guards that file, and this one is where the fixed paint lives instead. The
// lighthouse takes its colours from a palette the controller derives from the
// theme, so it follows the register like the rest of the scene.
//
// **Why path strings.** The board drew these as SVG paths, and this app does
// not ship resource bundles (see `CodePreviewAssets.swift`). `SVGPath` parses
// the small subset the paths use (M L H V C Q T Z, absolute and relative), so
// the drawing here stays a line-for-line port of the board and a future tweak
// can be made in either place.
//
// The Going Merry is the Straw Hat Pirates' first ship, by Eiichiro Oda. This
// is fan art in the captain's own app; it is not a licensed asset.

import AppKit

// MARK: - SVG path subset

enum SVGPath {
    /// A `CGPath` for an SVG path string using M, L, H, V, C, Q, T and Z
    /// (either case). Unknown commands end the parse.
    static func cgPath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(d)[...]
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        func num() -> CGFloat {
            guard case .number(let v)? = tokens.first else { return 0 }
            tokens = tokens.dropFirst()
            return v
        }
        while let token = tokens.first {
            if case .command(let c) = token { cmd = c; tokens = tokens.dropFirst() }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            switch Character(cmd.uppercased()) {
            case "M":
                cur = CGPoint(x: base.x + num(), y: base.y + num())
                path.move(to: cur); start = cur; lastControl = nil
                cmd = rel ? "l" : "L"          // following pairs are line-tos
            case "L":
                cur = CGPoint(x: base.x + num(), y: base.y + num()); path.addLine(to: cur); lastControl = nil
            case "H":
                cur = CGPoint(x: (rel ? cur.x : 0) + num(), y: cur.y); path.addLine(to: cur); lastControl = nil
            case "V":
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + num()); path.addLine(to: cur); lastControl = nil
            case "C":
                let c1 = CGPoint(x: base.x + num(), y: base.y + num())
                let c2 = CGPoint(x: base.x + num(), y: base.y + num())
                cur = CGPoint(x: base.x + num(), y: base.y + num())
                path.addCurve(to: cur, control1: c1, control2: c2); lastControl = nil
            case "Q":
                let c = CGPoint(x: base.x + num(), y: base.y + num())
                cur = CGPoint(x: base.x + num(), y: base.y + num())
                path.addQuadCurve(to: cur, control: c); lastControl = c
            case "T":
                let c = lastControl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                cur = CGPoint(x: base.x + num(), y: base.y + num())
                path.addQuadCurve(to: cur, control: c); lastControl = c
            case "Z":
                path.closeSubpath(); cur = start; lastControl = nil
                if case .number? = tokens.first { tokens = tokens.dropFirst() }
            default:
                return path
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = [], buf = ""
        func flush() { if let v = Double(buf) { out.append(.number(CGFloat(v))) }; buf = "" }
        for ch in d {
            if ch.isLetter, ch != "e" {
                flush(); out.append(.command(ch))
            } else if ch == "-" && !buf.isEmpty && buf.last != "e" {
                flush(); buf = "-"
            } else if ch == "." && buf.contains(".") {
                flush(); buf = "."
            } else if ch == "," || ch == " " || ch == "\n" {
                flush()
            } else {
                buf.append(ch)
            }
        }
        flush()
        return out
    }
}

// MARK: - Drawing helpers

private extension CGContext {
    func fill(_ d: String, _ color: NSColor) {
        addPath(SVGPath.cgPath(d)); setFillColor(color.cgColor); fillPath()
    }
    func stroke(_ d: String, _ color: NSColor, _ width: CGFloat, round: Bool = false) {
        addPath(SVGPath.cgPath(d)); setStrokeColor(color.cgColor); setLineWidth(width)
        setLineCap(round ? .round : .butt); setLineJoin(.round); strokePath()
    }
    func fillStroke(_ d: String, fill: NSColor, stroke: NSColor, width: CGFloat) {
        let p = SVGPath.cgPath(d)
        addPath(p); setFillColor(fill.cgColor); fillPath()
        addPath(p); setStrokeColor(stroke.cgColor); setLineWidth(width); setLineJoin(.round); strokePath()
    }
    /// Fills `d` with a linear gradient between two points in the path's own space.
    func fillGradient(_ d: String, _ colors: [NSColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
        saveGState()
        addPath(SVGPath.cgPath(d)); clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: colors.map(\.cgColor) as CFArray, locations: locations)!
        drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 0) {
        let r = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        setFillColor(fill.cgColor); fillEllipse(in: r)
        if let stroke { setStrokeColor(stroke.cgColor); setLineWidth(width); strokeEllipse(in: r) }
    }
    func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 0) {
        let p = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        addPath(p); setFillColor(fill.cgColor); fillPath()
        if let stroke { addPath(p); setStrokeColor(stroke.cgColor); setLineWidth(width); strokePath() }
    }
}

/// `#rrggbb` (and an optional alpha) to an sRGB colour, for the illustrations' own paint.
private func paint(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: - The Going Merry

enum GoingMerryArt {
    /// The drawing's own coordinate space, in which its waterline sits at y = 91.
    static let canvas = NSSize(width: 120, height: 104)

    /// The ship as a resolution-independent image. `dim` darkens it for the
    /// scene's light (0 by day; the dusk and night registers pass more).
    static func image(size: NSSize, dim: CGFloat) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.scaleBy(x: rect.width / canvas.width, y: rect.height / canvas.height)
            draw(in: ctx)
            ctx.restoreGState()
            if dim > 0 {
                // Darken only where the ship is drawn.
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(paint(0x0B0D22, dim).cgColor)
                ctx.fill(rect)
            }
            return true
        }
    }

    private static func draw(in c: CGContext) {
        let wood = paint(0x6B4426), iron = paint(0x4A2F1D)
        // Rig: flagpole, the Straw Hat flag, mast, crow's nest, yards and the main sail.
        c.stroke("M60 1 V12", iron, 1.5)
        c.fill("M61 1.5 H80 L76.2 7 L80 12.5 H61 Z", paint(0x26222E))
        jollyRoger(c, cx: 70, cy: 7.3, s: 0.42, onSail: false)
        c.roundRect(58.5, 10, 3, 58, 1.2, fill: wood)
        c.fillStroke("M52.5 15.5 H67.5 L65.8 23 H54.2 Z", fill: paint(0x8A5A34), stroke: iron, width: 0.9)
        c.stroke("M53.3 18.4 H66.7", iron.withAlphaComponent(0.7), 0.7)
        c.roundRect(27, 25, 66, 2.6, 1.3, fill: wood)
        let sail = "M31 27.4 H89 Q96.5 42 89 57 H31 Q23.5 42 31 27.4 Z"
        c.fillGradient(sail, [paint(0xECE6D8), paint(0xFDFBF5), paint(0xE9E2D2)], [0, 0.5, 1],
                       from: CGPoint(x: 24, y: 0), to: CGPoint(x: 97, y: 0))
        c.stroke(sail, paint(0xCDBF9F), 0.9)
        c.stroke("M38 28 Q35 42 38 56 M82 28 Q85 42 82 56", paint(0xE2D8C2), 0.8)
        jollyRoger(c, cx: 60, cy: 42.6, s: 1.08, onSail: true)
        c.roundRect(30, 56.6, 60, 2.2, 1.1, fill: wood)
        // Stern cabin.
        c.fillStroke("M8 47 H36 V64 H10 Z", fill: paint(0xD3A868), stroke: wood, width: 0.9)
        c.roundRect(14, 51, 6, 5.4, 1, fill: paint(0xFFF1C4), stroke: wood, width: 0.6)
        c.roundRect(24, 51, 6, 5.4, 1, fill: paint(0xFFF1C4), stroke: wood, width: 0.6)
        c.stroke("M7 47 H37", paint(0x7A4B2A), 2.2, round: true)
        // Hull.
        let hull = "M7 58 C9.5 76 20 88.5 34 91.5 L87 91.5 C103 88.5 111.5 76 116.5 57.5 C106 63.5 92 66 60 66 C30 66 16 63.5 7 58 Z"
        c.fillGradient(hull, [paint(0xE8C890), paint(0xB98A52)], [0, 1], from: CGPoint(x: 0, y: 57), to: CGPoint(x: 0, y: 92))
        c.stroke(hull, wood, 1.2)
        c.stroke("M10 71 C24 77 40 79 60 79 C83 79 99 77 112 70 M14 81 C27 86 42 87.5 60 87.5 C80 87.5 94 86 105 81",
                 paint(0x6B4426, 0.38), 1)
        c.stroke("M7 58 C16 63.5 30 66 60 66 C92 66 106 63.5 116.5 57.5", paint(0x7A4B2A), 3.2, round: true)
        // The sheep figurehead.
        c.stroke("M109 60 Q110.5 55 112.5 52.5", paint(0xF3EDE2), 4.6, round: true)
        c.ellipse(114.6, 49.4, 6.2, 5.6, fill: paint(0xF7F2E8), stroke: paint(0xC9BFAE), width: 0.6)
        c.ellipse(118, 51.6, 2.7, 2.3, fill: paint(0xEFE6D6), stroke: paint(0xC9BFAE), width: 0.4)
        c.ellipse(116, 48.2, 0.95, 0.95, fill: paint(0x1F1D24))
        c.ellipse(111.2, 46.8, 3.3, 3.3, fill: paint(0xE7B65C), stroke: paint(0xB8862E), width: 0.7)
        c.ellipse(111.2, 46.8, 1.5, 1.5, fill: .clear, stroke: paint(0xB8862E), width: 0.7)
        // Foam at the waterline.
        c.stroke("M18 94 q5 -2.4 10 0 t10 0 t10 0 t10 0 t10 0 t10 0 t10 0 t10 0", paint(0xFFFFFF, 0.82), 1.8, round: true)
    }

    /// The straw-hat Jolly Roger: light on the black flag, black on the white sail.
    private static func jollyRoger(_ c: CGContext, cx: CGFloat, cy: CGFloat, s: CGFloat, onSail: Bool) {
        let ink = onSail ? paint(0x1F1D24) : paint(0xF4EFE6)
        let hole = onSail ? paint(0xFBF7EE) : paint(0x26222E)
        let hat = onSail ? paint(0x1F1D24) : paint(0xF2C94C)
        let band = onSail ? paint(0xFBF7EE) : paint(0xD0342C)
        c.saveGState()
        c.translateBy(x: cx, y: cy); c.scaleBy(x: s, y: s)
        c.stroke("M-9 -5.5 L9 8 M9 -5.5 L-9 8", ink, 2.6, round: true)
        for (x, y) in [(-9.0, -5.5), (9.0, -5.5), (-9.0, 8.0), (9.0, 8.0)] { c.ellipse(x, y, 1.7, 1.7, fill: ink) }
        c.ellipse(0, -0.4, 6, 6, fill: ink)
        c.roundRect(-3.6, 3.2, 7.2, 3.6, 1.3, fill: ink)
        c.ellipse(-2.3, -0.5, 1.6, 1.6, fill: hole)
        c.ellipse(2.3, -0.5, 1.6, 1.6, fill: hole)
        c.fill("M0 1.6 L-0.9 3 H0.9 Z", hole)
        c.stroke("M-1.6 4.4 V6.6 M0 4.4 V6.6 M1.6 4.4 V6.6", hole, 0.6)
        c.fill("M-4.8 -5 Q-4.8 -10.8 0 -10.8 Q4.8 -10.8 4.8 -5 Z", hat)
        c.setFillColor(band.cgColor); c.fill(CGRect(x: -4.8, y: -7, width: 9.6, height: 1.8))
        c.ellipse(0, -5, 9.2, 2.1, fill: hat, stroke: hole, width: 0.7)
        c.restoreGState()
    }
}

// MARK: - The lighthouse on its cliff

enum LighthouseArt {
    /// The drawing's space: the board's cliff and tower, from x 988 and y 286
    /// of its 1220 x 720 stage. The cliff runs off the bottom edge.
    static let canvas = NSSize(width: 232, height: 434)
    /// Where the lamp sits in that space, which is where the beams pivot.
    static let lamp = CGPoint(x: 162, y: 37)
    /// The lamp room's glass, which the controller lights as its own layer.
    static let glass = CGRect(x: 153, y: 26, width: 18, height: 22)

    struct Palette {
        let rock: NSColor
        let rockEdge: NSColor
        let tower: NSColor
        let towerLine: NSColor
        let band: NSColor
        let iron: NSColor
        let darkGlass: NSColor
    }

    static func image(palette p: Palette) -> NSImage {
        NSImage(size: canvas, flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.translateBy(x: -988, y: -286)
            c.fill("M990 720 L1004 652 C1012 618 1030 590 1046 560 C1060 520 1072 490 1096 466 C1108 454 1124 448 1140 446 L1220 444 L1220 720 Z", p.rock)
            c.stroke("M1046 560 C1060 520 1072 490 1096 466 C1108 454 1124 448 1140 446", p.rockEdge, 3)
            func slice(_ y1: CGFloat, _ y2: CGFloat) -> String {
                func hw(_ y: CGFloat) -> CGFloat { 13 + 6 * (y - 340) / 106 }
                return "M\(1150 - hw(y1)) \(y1) L\(1150 + hw(y1)) \(y1) L\(1150 + hw(y2)) \(y2) L\(1150 - hw(y2)) \(y2) Z"
            }
            c.fillStroke(slice(340, 446), fill: p.tower, stroke: p.towerLine, width: 1)
            c.fill(slice(362, 374), p.band)
            c.fill(slice(398, 410), p.band)
            c.fill("M1145 446 V436 Q1150 430 1155 436 V446 Z", p.iron)
            c.roundRect(1133, 334, 34, 6, 1.5, fill: p.iron)
            c.stroke("M1135 328 H1165 M1137 328 V334 M1144 328 V334 M1156 328 V334 M1163 328 V334", p.iron, 1.4)
            c.setFillColor(p.darkGlass.cgColor); c.fill(CGRect(x: 1141, y: 312, width: 18, height: 22))
            c.stroke("M1147 312 V334 M1153 312 V334", p.iron, 1.2)
            c.fill("M1137 312 Q1150 292 1163 312 Z", p.iron)
            c.ellipse(1150, 291, 2.2, 2.2, fill: p.iron)
            return true
        }
    }

    /// The light-gathering mullions drawn over the lit glass.
    static func mullionPath() -> CGPath { SVGPath.cgPath("M6 0 V22 M12 0 V22") }
}

// MARK: - Sea fog

/// A tileable fractal-noise alpha texture for one fog band.
///
/// It is generated once off the main thread (GL-12: nothing slow on main
/// before the window exists) and tiles seamlessly in x with a period of
/// `period` points, so a band can drift forever by translating one period.
enum FogTexture {
    struct Spec {
        let period: Int            // tile width, points
        let height: Int            // band height, points
        let cellsX: Int            // noise cells across one tile at the lowest octave
        let cellsY: Int
        let seed: UInt32
        let gain: Double           // alpha = gain * noise + bias, clipped
        let bias: Double
    }

    static let far = Spec(period: 1220, height: 260, cellsX: 3, cellsY: 3, seed: 3, gain: 1.7, bias: -0.62)
    static let bank = Spec(period: 1220, height: 170, cellsX: 4, cellsY: 4, seed: 7, gain: 2.1, bias: -0.72)
    static let veil = Spec(period: 1220, height: 420, cellsX: 3, cellsY: 5, seed: 11, gain: 1.9, bias: -0.7)

    /// White with the noise as alpha, softened top and bottom, at half
    /// resolution (fog has no detail to lose, and the layer scales it up).
    static func make(_ spec: Spec) -> CGImage? {
        let w = spec.period / 2, h = spec.height / 2
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var lattice: [[Double]] = []
        var rng = spec.seed &* 2654435761
        func rand() -> Double { rng = rng &* 1664525 &+ 1013904223; return Double(rng >> 8) / Double(1 << 24) }
        let octaves = 4
        for o in 0..<octaves {
            let cx = spec.cellsX << o, cy = spec.cellsY << o
            lattice.append((0..<(cx * (cy + 1))).map { _ in rand() })
        }
        func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        for y in 0..<h {
            let fy = Double(y) / Double(h)
            // Soft edges: clear, full from 35% to 72%, clear again.
            let edge = fy < 0.35 ? fy / 0.35 : (fy > 0.72 ? max(0, (1 - fy) / 0.28) : 1)
            for x in 0..<w {
                let fx = Double(x) / Double(w)
                var sum = 0.0, amp = 0.5, norm = 0.0
                for o in 0..<octaves {
                    let cx = spec.cellsX << o, cy = spec.cellsY << o
                    let gx = fx * Double(cx), gy = fy * Double(cy)
                    let x0 = Int(gx) % cx, y0 = min(Int(gy), cy - 1)
                    let x1 = (x0 + 1) % cx, y1 = y0 + 1
                    let tx = smooth(gx - Double(Int(gx))), ty = smooth(gy - Double(Int(gy)))
                    let l = lattice[o]
                    let a = l[y0 * cx + x0], b = l[y0 * cx + x1], c = l[y1 * cx + x0], d = l[y1 * cx + x1]
                    sum += amp * ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
                    norm += amp; amp *= 0.5
                }
                let n = sum / norm
                let alpha = max(0, min(1, spec.gain * n + spec.bias)) * edge
                let i = (y * w + x) * 4
                let v = UInt8(alpha * 255)
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = v   // premultiplied white
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
