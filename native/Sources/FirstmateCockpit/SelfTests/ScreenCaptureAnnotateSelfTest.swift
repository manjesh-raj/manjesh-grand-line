// Manjesh Grand Line - native macOS app.
//
// F15's pure-logic half: `ScreenRegionCapture`'s three-way decision and its
// pasteboard intake, and every step of `WhiteboardCaptureScene` between an
// `NSImage` and a `loadScene` payload.
//
// **Nothing here touches a real screen**, which is the point. The actual
// system capture cannot run in CI (it needs a captain to drag a rectangle),
// so `ScreenRegionCapture.capture` is built with the subprocess behind an
// injectable `Runner` and the real decision extracted into
// `ScreenRegionCapture.decide`, a pure function. What this suite proves is
// everything on both sides of the one call that genuinely cannot be
// automated - see this task's PR for what was checked by hand instead.
//
// Classified as pure logic (AGENTS.md's "the test is what the suite asserts,
// never what it imports"): it uses AppKit for `NSImage`/`NSBitmapImageRep`/
// `NSPasteboard`, none of which need a window server. The offscreen bitmap
// work is the same shape as `ShiftImageAttachmentWellSelfTest`'s, which is
// also in CI's blocking lane. The window-backed half - a real capture landing
// on a real Excalidraw canvas and coming back out as a real PNG - is
// `WhiteboardCaptureViewSelfTest`.
//
// `FM_RUN_SCREEN_CAPTURE_ANNOTATE_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ScreenCaptureAnnotateSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkArgv(check)
        checkDecision(check)
        checkCaptureReadsThePasteboard(check)
        checkCaptureNeverReachesClipboardHistory(check)
        checkEncoding(check)
        checkDataURLRoundTrip(check)
        checkBoardBottom(check)
        checkPayload(check)
        checkSummary(check)
        checkPasteboardWrite(check)

        print(ok ? "ScreenCaptureAnnotateSelfTest: OK" : "ScreenCaptureAnnotateSelfTest: FAILURES")
        return ok
    }

    // MARK: The argv

    /// The flags are the security posture of this feature, so they are
    /// asserted rather than left to a reader of the file.
    private static func checkArgv(_ check: (Bool, String) -> Void) {
        let args = ScreenRegionCapture.arguments
        check(ScreenRegionCapture.executable == "/usr/sbin/screencapture",
              "screencapture must be reached by absolute path, never through PATH")
        check(args.contains("-i"),
              "-i is what makes this the system's own region picker rather than a whole-screen grab")
        check(args.contains("-c"),
              "-c keeps the unredacted capture off disk - the promise the page's subtitle prints")
        check(!args.contains(where: { $0.hasSuffix(".png") || $0.hasPrefix("/") }),
              "no file path may appear in the argv, or the capture would be written to disk after all")
        // The fixture's own discriminating power: these flags are genuinely
        // distinguishable, so a silently-emptied array fails here too.
        check(args.count >= 4, "the argv should not have collapsed to nothing")
    }

    // MARK: The three-way decision

    private static func checkDecision(_ check: (Bool, String) -> Void) {
        func decide(_ outcome: SubprocessResult.Outcome, _ status: Int32,
                    _ stderr: String = "", changed: Bool) -> ScreenRegionCapture.Outcome {
            ScreenRegionCapture.decide(outcome: outcome, status: status,
                                       stderr: stderr, pasteboardChanged: changed)
        }

        check(decide(.exited, 0, changed: true) == .captured,
              "exit 0 with a pasteboard that moved is a capture")
        // The case the whole function exists for: `screencapture -i` exits 0
        // when the captain presses Escape, so the status alone cannot tell
        // these two apart and a naive `status == 0 -> success` would report a
        // capture that never happened.
        check(decide(.exited, 0, changed: false) == .cancelled,
              "exit 0 with an unchanged pasteboard is a cancel, not a capture")

        if case .failed(let message) = decide(.exited, 1, "boom", changed: false) {
            check(message.contains("1"), "a non-zero exit should name its status")
            check(message.contains("boom"), "a non-zero exit should carry stderr when there is any")
        } else {
            check(false, "a non-zero exit must be a failure")
        }
        // A non-zero exit is a failure even when something did reach the
        // pasteboard - a partially-written capture is not a capture.
        if case .failed = decide(.exited, 2, changed: true) {} else {
            check(false, "a non-zero exit must stay a failure even if the pasteboard moved")
        }
        if case .failed = decide(.launchFailed, -1, changed: false) {} else {
            check(false, "a launch failure must be a failure")
        }
        if case .failed(let message) = decide(.timedOut, Subprocess.timedOutStatus, changed: false) {
            check(!message.isEmpty, "a timeout should say something the captain can act on")
        } else {
            check(false, "a timeout must be a failure")
        }
    }

    // MARK: Intake

    /// The whole of `capture(...)` with only the subprocess replaced, so the
    /// pasteboard read, the change-count comparison and the "captured but
    /// nothing usable arrived" path are all real.
    private static func checkCaptureReadsThePasteboard(_ check: (Bool, String) -> Void) {
        let board = NSPasteboard(name: .init("fm.selftest.capture.intake"))

        func runner(_ writeImage: Bool) -> ScreenRegionCapture.Runner {
            { completion in
                if writeImage {
                    board.clearContents()
                    board.writeObjects([sampleImage(width: 8, height: 6, red: 1)])
                }
                completion(SubprocessResult(outcome: .exited, status: 0,
                                            stdoutData: Data(), stderrData: Data(), duration: 0.01))
            }
        }

        var captured: ScreenRegionCapture.Result?
        ScreenRegionCapture.capture(runner: runner(true), pasteboard: board) { captured = $0 }
        check(captured?.outcome == .captured, "a run that wrote an image to the pasteboard is a capture")
        check(captured?.image != nil, "a capture must hand back the image it read")

        // Nothing written: the change count does not move, so this is a
        // cancel and the image is nil.
        var cancelled: ScreenRegionCapture.Result?
        ScreenRegionCapture.capture(runner: runner(false), pasteboard: board) { cancelled = $0 }
        check(cancelled?.outcome == .cancelled, "a run that wrote nothing is a cancel")
        check(cancelled?.image == nil, "a cancel must not hand back an image")

        // The awkward middle: the pasteboard moved, but what landed is not an
        // image. Reported as a failure rather than handed on as a success
        // carrying nothing.
        let textRunner: ScreenRegionCapture.Runner = { completion in
            board.clearContents()
            board.setString("not an image", forType: .string)
            completion(SubprocessResult(outcome: .exited, status: 0,
                                        stdoutData: Data(), stderrData: Data(), duration: 0.01))
        }
        var odd: ScreenRegionCapture.Result?
        ScreenRegionCapture.capture(runner: textRunner, pasteboard: board) { odd = $0 }
        if case .failed? = odd?.outcome {} else {
            check(false, "a pasteboard that moved but holds no image must be a failure, not a silent success")
        }

        board.clearContents()
    }

    /// The rule that matters most about routing a capture through the
    /// pasteboard: it must not end up in the on-disk clipboard history.
    ///
    /// Asserted against the real `ClipboardHistoryStore.record(from:)` rather
    /// than by reading it, because "images are not recorded" is a property of
    /// that function and could stop being true without anything in this
    /// feature changing. The fixture carries its own discriminating half - the
    /// same pasteboard with a *string* on it does record - so a store that had
    /// quietly become a no-op could not pass this.
    private static func checkCaptureNeverReachesClipboardHistory(_ check: (Bool, String) -> Void) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-capture-clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // A throwaway key, never the captain's real Keychain item - the same
        // seam `ClipboardHistorySelfTest` uses.
        guard let key = ClipboardHistoryKey.ephemeralKey() else {
            check(false, "could not build a throwaway clipboard-history key")
            return
        }
        let store = ClipboardHistoryStore(fileURL: file, key: key)
        let board = NSPasteboard(name: .init("fm.selftest.capture.history"))

        board.clearContents()
        board.writeObjects([sampleImage(width: 8, height: 6, red: 1)])
        let imageOutcome = store.record(from: board)
        check(imageOutcome == .nothingToRecord,
              "a captured image must not be recorded into the clipboard history - got \(imageOutcome)")

        board.clearContents()
        board.setString("a plain string", forType: .string)
        if case .recorded = store.record(from: board) {} else {
            check(false, "the fixture is not discriminating: a plain string should still be recorded")
        }
        board.clearContents()
    }

    // MARK: Encoding

    /// The reason this app does not reuse `normalizedPNGData` for a capture:
    /// a Retina image must keep its real pixels.
    private static func checkEncoding(_ check: (Bool, String) -> Void) {
        // 200x100 pixels behind a 100x50 point image - exactly what
        // `screencapture` hands back on a 2x display.
        let retina = retinaImage(pixelWidth: 200, pixelHeight: 100, pointWidth: 100, pointHeight: 50)
        guard let encoded = WhiteboardCaptureScene.pngCapture(from: retina) else {
            check(false, "a Retina capture should encode")
            return
        }
        check(encoded.pixelWidth == 200 && encoded.pixelHeight == 100,
              "the encode must keep the backing pixel grid, not redraw at point size - got "
              + "\(encoded.pixelWidth)x\(encoded.pixelHeight)")
        check(abs(encoded.scale - 2) < 0.01, "the scale should read as 2x - got \(encoded.scale)")
        check(abs(encoded.pointWidth - 100) < 0.5 && abs(encoded.pointHeight - 50) < 0.5,
              "the image is placed at the size the captain dragged - got "
              + "\(encoded.pointWidth)x\(encoded.pointHeight)")
        check(WhiteboardCaptureScene.isPNG(encoded.png), "the encode must produce real PNG bytes")

        // The discriminating half: the app's *other* encoder really does halve
        // this, which is why a second one exists. If that ever stops being
        // true, the comment justifying this file is wrong and should fail.
        if let viaWell = ShiftImageAttachmentWell.normalizedPNGData(from: retina),
           let rep = NSBitmapImageRep(data: viaWell) {
            check(rep.pixelsWide == 100,
                  "the fixture assumes normalizedPNGData redraws at point size - it produced "
                  + "\(rep.pixelsWide)px, so this file's justification needs revisiting")
        } else {
            check(false, "the comparison encode should have produced a bitmap")
        }

        // The cap applies to pixels and never upscales.
        let huge = retinaImage(pixelWidth: 8000, pixelHeight: 2000, pointWidth: 4000, pointHeight: 1000)
        guard let capped = WhiteboardCaptureScene.pngCapture(from: huge, maxPixelDimension: 800) else {
            check(false, "an oversized capture should still encode")
            return
        }
        check(capped.pixelWidth == 800, "the longest edge is capped in pixels - got \(capped.pixelWidth)")
        check(capped.pixelHeight == 200, "the aspect ratio must survive the cap - got \(capped.pixelHeight)")
        // A downscale is a real loss of detail, so the reported scale has to
        // come down with it or the subtitle would claim Retina detail the
        // image no longer carries (GL-14).
        check(abs(capped.scale - 0.2) < 0.01,
              "the reported scale must follow the downscale - got \(capped.scale)")

        let small = sampleImage(width: 10, height: 10, red: 1)
        if let unchanged = WhiteboardCaptureScene.pngCapture(from: small, maxPixelDimension: 800) {
            check(unchanged.pixelWidth == 10, "a small capture must never be upscaled")
        } else {
            check(false, "a small capture should encode")
        }

        check(WhiteboardCaptureScene.pngCapture(from: NSImage(size: .zero)) == nil,
              "an empty image has nothing to encode and must report so")
    }

    // MARK: Data URLs

    private static func checkDataURLRoundTrip(_ check: (Bool, String) -> Void) {
        guard let encoded = WhiteboardCaptureScene.pngCapture(from: sampleImage(width: 12, height: 9, red: 1)) else {
            check(false, "the round-trip fixture should encode")
            return
        }
        let url = WhiteboardCaptureScene.dataURL(for: encoded.png)
        check(url.hasPrefix("data:image/png;base64,"), "a file's dataURL must declare PNG")
        check(WhiteboardCaptureScene.png(fromDataURL: url) == encoded.png,
              "a dataURL must decode back to the exact bytes that went in")

        // Every way the reply can be wrong has to read as wrong, or a
        // malformed export would be written over the captain's clipboard as
        // an empty image.
        check(WhiteboardCaptureScene.png(fromDataURL: "data:image/jpeg;base64,AAAA") == nil,
              "a non-PNG dataURL must be refused")
        check(WhiteboardCaptureScene.png(fromDataURL: "data:image/png;base64,") == nil,
              "an empty payload must be refused")
        check(WhiteboardCaptureScene.png(fromDataURL: "data:image/png;base64,aGVsbG8=") == nil,
              "bytes that decode but are not a PNG must be refused")
        check(WhiteboardCaptureScene.png(fromDataURL: "") == nil, "an empty reply must be refused")
    }

    // MARK: Placement

    private static func checkBoardBottom(_ check: (Bool, String) -> Void) {
        check(WhiteboardCaptureScene.boardBottom(of: []) == nil,
              "an empty board has no bottom to measure")
        check(WhiteboardCaptureScene.boardBottom(of: [["type": "text"]]) == nil,
              "an element with no geometry at all contributes nothing rather than a zero")
        // The case the window-backed suite found: `toSkeleton` omits any
        // numeric field that is zero, so the first capture - placed at the
        // origin - comes back carrying a height and no `y`. Treating that as
        // "no geometry" made the second capture land on top of it.
        check(WhiteboardCaptureScene.boardBottom(of: [["type": "image", "height": 120.0]]) == 120,
              "an element whose zero y was omitted still has a measurable bottom")
        check(WhiteboardCaptureScene.boardBottom(of: [["type": "image", "y": 40.0]]) == 40,
              "an element whose zero height was omitted still has a measurable bottom")

        let board: [[String: Any]] = [
            ["y": 0.0, "height": 100.0],
            ["y": 40.0, "height": 500.0],   // the real bottom, at 540
            ["y": 300.0, "height": 20.0],
            ["y": 10.0],                     // no height: its own edge, 10
        ]
        check(WhiteboardCaptureScene.boardBottom(of: board) == 540,
              "the bottom is the largest y + height - got "
              + String(describing: WhiteboardCaptureScene.boardBottom(of: board)))

        // Excalidraw's y axis grows downwards, so a board entirely above the
        // origin still has a bottom and it is still the maximum. Getting this
        // backwards would stack every capture on top of the captain's work.
        let negative: [[String: Any]] = [["y": -900.0, "height": 100.0], ["y": -400.0, "height": 50.0]]
        check(WhiteboardCaptureScene.boardBottom(of: negative) == -350,
              "a board above the origin still measures its lowest edge")

        // Ints and NSNumbers arrive from JSON as readily as Doubles.
        let mixed: [[String: Any]] = [["y": 10, "height": NSNumber(value: 30.5)]]
        check(WhiteboardCaptureScene.boardBottom(of: mixed) == 40.5,
              "JSON numbers of every flavour must be read")
    }

    private static func checkPayload(_ check: (Bool, String) -> Void) {
        guard let encoded = WhiteboardCaptureScene.pngCapture(
            from: retinaImage(pixelWidth: 400, pixelHeight: 200, pointWidth: 200, pointHeight: 100)) else {
            check(false, "the payload fixture should encode")
            return
        }
        let id = "gl-capture-fixture"
        let empty = WhiteboardCaptureScene.payload(for: encoded, fileID: id, boardBottom: nil)
        check(empty.elements.count == 1 && empty.files.count == 1,
              "one capture is one element and one file")
        let element = empty.elements[0]
        check(element["type"] as? String == "image", "the element must be an image")
        check(element["fileId"] as? String == id, "the element must name its file")
        check(element["y"] as? Double == 0, "an empty board places the capture at the origin")
        check(element["width"] as? Double == 200 && element["height"] as? Double == 100,
              "the capture is placed at its point size")
        let file = empty.files[0]
        check(file["id"] as? String == id, "the file must carry the id the element references")
        check(file["mimeType"] as? String == "image/png", "the file must declare PNG")
        check((file["dataURL"] as? String)?.hasPrefix("data:image/png;base64,") == true,
              "the file must carry a PNG dataURL")

        let stacked = WhiteboardCaptureScene.payload(for: encoded, fileID: id, boardBottom: 640)
        check(stacked.elements[0]["y"] as? Double == 640 + WhiteboardCaptureScene.stackGap,
              "a capture lands below what is already on the board, with a gap")

        // Two captures must never share a file id - Excalidraw keys its file
        // cache by it, so a shared id makes the second capture silently render
        // as the first.
        let a = WhiteboardCaptureScene.fileID()
        let b = WhiteboardCaptureScene.fileID()
        check(a != b, "two captures must get different file ids")
        check(a.hasPrefix("gl-capture-"), "a capture's file id should be recognisable - got \(a)")
    }

    private static func checkSummary(_ check: (Bool, String) -> Void) {
        guard let retina = WhiteboardCaptureScene.pngCapture(
                from: retinaImage(pixelWidth: 2168, pixelHeight: 1024, pointWidth: 1084, pointHeight: 512)),
              let plain = WhiteboardCaptureScene.pngCapture(from: sampleImage(width: 300, height: 120, red: 1))
        else {
            check(false, "the summary fixtures should encode")
            return
        }
        let retinaText = WhiteboardCaptureScene.summary(for: retina)
        check(retinaText.contains("1084") && retinaText.contains("512"),
              "the summary names the region the captain dragged - got \(retinaText)")
        check(retinaText.contains("2"), "a 2x capture should say so - got \(retinaText)")

        // GL-14: a 1x capture says nothing about scale rather than claiming a
        // reading it does not have.
        let plainText = WhiteboardCaptureScene.summary(for: plain)
        check(!plainText.lowercased().contains("retina"),
              "a non-Retina capture must not claim Retina - got \(plainText)")
        check(plainText.contains("300"), "the summary should still name the size - got \(plainText)")
    }

    // MARK: Copy

    private static func checkPasteboardWrite(_ check: (Bool, String) -> Void) {
        guard let encoded = WhiteboardCaptureScene.pngCapture(from: sampleImage(width: 20, height: 10, red: 1)) else {
            check(false, "the copy fixture should encode")
            return
        }
        let board = NSPasteboard(name: .init("fm.selftest.capture.copy"))
        board.clearContents()
        board.setString("something else entirely", forType: .string)

        let written = WhiteboardCaptureScene.writeToPasteboard(png: encoded.png, pasteboard: board)
        check(written == 2, "a copy writes both PNG and TIFF - got \(written)")
        check(board.data(forType: .png) == encoded.png, "the PNG on the pasteboard must be the exact bytes")
        check(board.data(forType: .tiff) != nil, "an app that only reads TIFF must find something")
        check(board.string(forType: .string) == nil,
              "the copy must clear what was there - a stale string beside an image is a paste nobody expects")
        board.clearContents()
    }

    // MARK: Fixtures

    /// A flat-coloured bitmap at 1 pixel per point.
    private static func sampleImage(width: Int, height: Int, red: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: red, green: 0.2, blue: 0.3, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// A bitmap whose pixel grid is denser than its point size, which is what
    /// a capture from a Retina display is.
    private static func retinaImage(pixelWidth: Int, pixelHeight: Int,
                                    pointWidth: CGFloat, pointHeight: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pointWidth, height: pointHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pointWidth, height: pointHeight))
        image.addRepresentation(rep)
        return image
    }
}

#endif
