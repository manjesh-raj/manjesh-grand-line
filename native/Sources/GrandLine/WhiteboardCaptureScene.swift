// Grand Line - native macOS app.
//
// F15's middle third: turning a captured `NSImage` into something the
// Whiteboard's existing bridge already knows how to draw, and turning what the
// board exports back into bytes for the pasteboard.
//
// Everything here is pure. There is no screen, no web view and no pasteboard
// in this file, which is what lets `WhiteboardCaptureSceneSelfTest` run in
// CI's blocking lane against real PNG bytes it builds itself.
//
// # Nothing new was invented on the canvas
//
// Excalidraw already draws images: `loadScene` has taken a `files` array
// alongside its element skeletons since the component-icon work, and an
// `image` skeleton referencing a `fileId` is exactly how
// `WhiteboardDiagramDSL` puts a component's artwork on the board. A capture is
// one more file and one more `image` element through that same path - no new
// bridge call for the placement, no second notion of "insert".
//
// # Placement: append below, never replace
//
// A board can hold real work, and the capture button is one click from a
// header. So a capture is appended *below* whatever is already there rather
// than replacing it, and `boardBottom` is the rule that finds where "below"
// is. Kept pure and separate from the controller because the interesting cases
// (an empty board, an element with no geometry, a board whose content sits at
// negative y) are exactly the ones a window-backed test would be a clumsy way
// to reach.
//
// # Retina, and why this does not call `normalizedPNGData`
//
// `ShiftImageAttachmentWell.normalizedPNGData` is this app's other
// image-encoding path, and it is deliberately not reused here: it redraws at
// the image's **point** size, which halves a Retina capture's real pixels. For
// a task attachment that is right (it is a thumbnail of a photo, and the file
// is git-synced). For a screenshot of a log line or a dashboard axis it throws
// away the only thing that made the capture worth taking. `pngCapture` encodes
// the backing representation's own pixel grid instead and records the scale,
// so the image is *placed* at its point size - the size the captain dragged -
// while carrying twice the detail into a zoom.
//
// The pasteboard intake itself is still the shared one
// (`ShiftImageAttachmentWell.image(fromPasteboard:)`, called by
// `ScreenRegionCapture`); it is only the encode that differs, and only for
// this reason.

import AppKit
import Foundation

enum WhiteboardCaptureScene {

    /// A capture, encoded and measured.
    struct Encoded: Equatable {
        let png: Data
        /// The real pixel grid, after any downscale.
        let pixelWidth: Int
        let pixelHeight: Int
        /// How many pixels per point the capture carries - 2 on a Retina
        /// display, 1 elsewhere, and possibly fractional after a downscale.
        /// Reported to the captain, never used to place the image.
        let scale: CGFloat

        /// Where the image is drawn on the canvas: the size the captain
        /// actually dragged, in points.
        var pointWidth: Double { Double(CGFloat(pixelWidth) / max(scale, 0.01)) }
        var pointHeight: Double { Double(CGFloat(pixelHeight) / max(scale, 0.01)) }
    }

    /// The longest edge a capture is allowed to carry, in **pixels**.
    ///
    /// A cap exists because the whole PNG travels to the page base64-encoded
    /// inside one `evaluateJavaScript` string, and an uncapped full-screen
    /// Retina grab is ~30MB of that. 3200 keeps a full-width Retina capture of
    /// this machine's own display (1512pt, 3024px) intact - the common case is
    /// not downscaled at all - while bounding the pathological one.
    static let maxPixelDimension: CGFloat = 3200

    // MARK: Encoding

    /// Encode a captured image as PNG on its own pixel grid.
    ///
    /// Returns `nil` for an image with no usable representation, which a
    /// caller reports rather than drawing an empty box for.
    static func pngCapture(from image: NSImage,
                           maxPixelDimension: CGFloat = maxPixelDimension) -> Encoded? {
        let points = image.size
        guard points.width > 0, points.height > 0 else { return nil }

        // The real pixel grid. `NSImage.size` is points; the backing
        // representation knows how many pixels are behind them, and a
        // screenshot from `screencapture` on a Retina display carries two per
        // point in each axis.
        let nativePixels = image.representations.reduce(into: CGSize.zero) { widest, rep in
            widest.width = max(widest.width, CGFloat(rep.pixelsWide))
            widest.height = max(widest.height, CGFloat(rep.pixelsHigh))
        }
        let sourcePixels = (nativePixels.width > 0 && nativePixels.height > 0) ? nativePixels : points
        let nativeScale = sourcePixels.width / points.width

        let shrink = min(1.0, maxPixelDimension / max(sourcePixels.width, sourcePixels.height))
        let targetWidth = max(1, Int((sourcePixels.width * shrink).rounded()))
        let targetHeight = max(1, Int((sourcePixels.height * shrink).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetWidth, pixelsHigh: targetHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // The rep's *point* size has to stay the pixel count here, or
        // `image.draw(in:)` below would scale a second time.
        rep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.current?.flushGraphics()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }

        return Encoded(png: png,
                       pixelWidth: targetWidth,
                       pixelHeight: targetHeight,
                       scale: nativeScale * shrink)
    }

    // MARK: Data URLs

    static let pngDataURLPrefix = "data:image/png;base64,"

    static func dataURL(for png: Data) -> String {
        pngDataURLPrefix + png.base64EncodedString()
    }

    /// The inverse, used on the way back out of `exportImage`.
    ///
    /// Strict on purpose: the page is trusted code, but a malformed or
    /// truncated reply must read as a failure the captain is told about rather
    /// than as an empty image quietly written over their clipboard.
    static func png(fromDataURL url: String) -> Data? {
        guard url.hasPrefix(pngDataURLPrefix) else { return nil }
        let base64 = String(url.dropFirst(pngDataURLPrefix.count))
        guard !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              isPNG(data) else { return nil }
        return data
    }

    /// The eight-byte PNG signature. Asserted rather than trusted so a reply
    /// that decoded as *something* cannot be handed to the pasteboard as a
    /// PNG it is not.
    static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    // MARK: Placement

    /// Gap between whatever is already on the board and a new capture.
    static let stackGap: Double = 48

    /// The lowest edge of anything already on the board, in canvas
    /// coordinates - or `nil` when there is nothing with real geometry to
    /// measure, which is the empty-board case and the "every element came back
    /// without x/y/height" case at once.
    ///
    /// Excalidraw's y axis grows downwards, so "below" is the **maximum**
    /// `y + height`. Getting that backwards would stack every capture on top
    /// of the board's own content, which is why it is asserted directly.
    ///
    /// **A missing `y` means zero, not "no geometry"**, and that distinction
    /// was a real bug the window-backed suite caught rather than a defensive
    /// flourish: `whiteboard.js`'s `toSkeleton` omits any numeric field whose
    /// value is `0`, so the very first capture - placed at the origin - comes
    /// back with no `y` at all. Requiring one made `boardBottom` return `nil`
    /// for a board holding exactly one capture, and the *second* capture then
    /// landed on top of the first. An element is measurable if it carries any
    /// geometry at all; one carrying none (a bare `{type:"text"}`) still
    /// contributes nothing.
    static func boardBottom(of elements: [[String: Any]]) -> Double? {
        var bottom: Double?
        for element in elements {
            let y = number(element["y"])
            let height = number(element["height"])
            // Something has to be known about this element, or it is not on
            // the board in any measurable sense.
            guard y != nil || height != nil || number(element["x"]) != nil
                    || number(element["width"]) != nil else { continue }
            let edge = (y ?? 0) + (height ?? 0)
            bottom = max(bottom ?? edge, edge)
        }
        return bottom
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// A file id that is unique per capture.
    ///
    /// Unlike a component icon's id - which is stable *so that* re-inserting
    /// the same component reuses the artwork already in the scene - two
    /// captures are never the same bytes, and sharing an id would make the
    /// second one silently render as the first.
    static func fileID(for date: Date = Date(), suffix: String = UUID().uuidString) -> String {
        "gl-capture-\(Int(date.timeIntervalSince1970 * 1000))-\(suffix.prefix(8))"
    }

    /// The `loadScene` payload for one capture: an `image` element and the file
    /// it references.
    ///
    /// `files` is returned alongside rather than folded in because that is the
    /// shape the bridge takes - files go in first, then the elements that name
    /// them, or the image renders as a permanently broken placeholder (see
    /// `whiteboard.js`'s own note on ordering).
    static func payload(for encoded: Encoded,
                        fileID: String,
                        boardBottom: Double?) -> (elements: [[String: Any]], files: [[String: Any]]) {
        let top = boardBottom.map { $0 + stackGap } ?? 0
        let element: [String: Any] = [
            "type": "image",
            "id": fileID + "-element",
            "fileId": fileID,
            "x": 0.0,
            "y": top,
            "width": encoded.pointWidth.rounded(),
            "height": encoded.pointHeight.rounded(),
        ]
        let file: [String: Any] = [
            "id": fileID,
            "dataURL": dataURL(for: encoded.png),
            "mimeType": "image/png",
        ]
        return ([element], [file])
    }

    // MARK: Copy

    /// What "Copy image" writes.
    ///
    /// PNG **and** TIFF, in that order of preference. A single flavour is the
    /// easy mistake here: several Mac apps still ask a pasteboard only for
    /// `.tiff` and would find nothing on a PNG-only write, while PNG is what
    /// anything modern (and anything that cares about the file being small)
    /// reads. `NSImage` writes TIFF; the PNG is written explicitly.
    ///
    /// Returns the number of types actually written, so a caller can tell the
    /// captain the truth rather than reporting "Copied" unconditionally.
    @discardableResult
    static func writeToPasteboard(png: Data, pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        var written = 0
        if pasteboard.setData(png, forType: .png) { written += 1 }
        if let image = NSImage(data: png), let tiff = image.tiffRepresentation,
           pasteboard.setData(tiff, forType: .tiff) {
            written += 1
        }
        return written
    }

    /// Human-readable summary of what was captured, for the drill subtitle.
    ///
    /// GL-14: the scale is only printed when it is genuinely known to be
    /// greater than 1. A capture whose backing scale could not be read says
    /// nothing about it rather than claiming `1x`.
    static func summary(for encoded: Encoded) -> String {
        let points = "\(Int(encoded.pointWidth.rounded())) \u{00D7} \(Int(encoded.pointHeight.rounded()))"
        guard encoded.scale > 1.01 else { return "Captured region \(points)" }
        let scale = (encoded.scale * 10).rounded() / 10
        let text = scale == scale.rounded() ? String(Int(scale)) : String(format: "%.1f", Double(scale))
        return "Captured region \(points) \u{00B7} Retina \(text)\u{00D7}"
    }
}
