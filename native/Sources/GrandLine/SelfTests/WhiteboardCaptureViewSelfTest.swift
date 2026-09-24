// Grand Line - native macOS app.
//
// F15's window-backed half: a capture landing on a **real** Excalidraw canvas,
// and the annotated board coming back out as a **real** PNG.
//
// Split from `ScreenCaptureAnnotateSelfTest` for the reason AGENTS.md's
// "Writing a self-test" section gives - everything here needs a window server
// and a live web content process, so it belongs in `NEEDS_SESSION` while the
// logic half guards the blocking CI job. `FM_RUN_WHITEBOARD_TESTS` /
// `FM_RUN_WHITEBOARD_VIEW_TESTS` is the model this pair follows.
//
// # What only this suite can see
//
// The logic suite proves the payload is *shaped* right. It cannot prove that
// Excalidraw accepted it: an `image` element whose `fileId` names a file the
// scene does not hold renders as a permanently broken placeholder and reports
// success all the way back to Swift. So the assertions here are about what the
// canvas did with the payload, not about what Swift sent:
//
//   1. The capture really becomes an `image` element on the board, at the size
//      it was captured at, and a second capture lands *below* the first rather
//      than on top of it.
//   2. `exportImage` returns bytes that are a decodable PNG of a plausible
//      size - which is the only evidence that the new bridge command survived
//      the bundle rebuild at all. A renamed library export would fail exactly
//      here and nowhere else.
//   3. **The export actually contains the capture.** The flattened PNG is
//      pixel-sampled and compared against the colour the fixture was filled
//      with. Everything upstream can pass while the export renders an empty
//      board, and this is the one check that can tell.
//   4. An empty board refuses to copy rather than writing a blank image over
//      the captain's clipboard.
//
// `FM_RUN_WHITEBOARD_CAPTURE_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum WhiteboardCaptureViewSelfTest {

    /// The fixture's fill. Deliberately a colour nothing in either Excalidraw
    /// theme paints on its own - a mid magenta - so finding it in the export
    /// cannot be a coincidence of the canvas background.
    private static let fillRGB: (CGFloat, CGFloat, CGFloat) = (0.85, 0.15, 0.65)

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        guard WhiteboardAssets.isAvailable else {
            check(false, "no Excalidraw bundle - run native/Scripts/build-excalidraw-web.sh")
            return false
        }

        // `AppLockGate` starts **locked** on purpose (see its own note: the
        // app shows the lock screen before anything else at launch), and both
        // halves of F15 now consult it - so without this every case below
        // would be refused and read as a broken feature. Restored at the end
        // rather than left flipped, for the same hermeticity reason
        // `withScratchEnv` restores the theme.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        AppLockGate.shared.setLocked(false)

        let window = OffScreenProbe.window(width: 1100, height: 760, styleMask: [.titled, .resizable])
        let controller = WhiteboardController()
        window.contentView = controller.view
        // Same requirement, same reason as `WhiteboardViewSelfTest`: a web
        // view in a window that was never ordered front is never composited,
        // so nothing below would measure anything.
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        window.displayIfNeeded()

        let webView = controller.debugWebView
        guard waitFor(timeout: 30, until: { webView.isReady }) else {
            check(false, "the Excalidraw canvas never reported ready")
            return false
        }

        checkEmptyBoardRefusesToCopy(controller, check)
        checkCaptureLandsOnTheBoard(controller, check)
        checkSecondCaptureStacksBelow(controller, check)
        checkExportContainsTheCapture(controller, check)
        checkCancelChangesNothing(controller, check)
        checkTheLockGatesBothHalves(controller, check)
        checkHeaderDoesNotResizeTheWindow(controller, window, check)

        window.orderOut(nil)
        print(ok ? "WhiteboardCaptureViewSelfTest: OK" : "WhiteboardCaptureViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Cases

    /// An export of nothing must fail loudly. The alternative - a 1x1
    /// transparent PNG written over whatever the captain had copied - is worse
    /// than a refusal, and it is what a naive `exportToCanvas` with no guard
    /// produces.
    private static func checkEmptyBoardRefusesToCopy(_ controller: WhiteboardController,
                                                     _ check: (Bool, String) -> Void) {
        var answered = false
        var failed = false
        var message = ""
        controller.debugWebView.call("exportImage") { result in
            answered = true
            if case .failure(let error) = result {
                failed = true
                message = error.message
            }
        }
        guard waitFor(timeout: 15, until: { answered }) else {
            check(false, "exportImage on an empty board never answered")
            return
        }
        check(failed, "exporting an empty board must fail rather than return a blank PNG")
        check(message.lowercased().contains("empty"),
              "the refusal should say the board is empty - got \(message)")
    }

    private static func checkCaptureLandsOnTheBoard(_ controller: WhiteboardController,
                                                    _ check: (Bool, String) -> Void) {
        guard let placed = capture(controller, pixelWidth: 480, pixelHeight: 240,
                                   pointWidth: 240, pointHeight: 120, check: check) else { return }
        check(placed.count == 1, "one capture should put exactly one element on the board - got \(placed.count)")
        guard let image = placed.first(where: { ($0["type"] as? String) == "image" }) else {
            check(false, "the capture should have become an image element - got "
                  + String(describing: placed.map { $0["type"] as? String }))
            return
        }
        let width = (image["width"] as? Double) ?? 0
        let height = (image["height"] as? Double) ?? 0
        check(abs(width - 240) < 2 && abs(height - 120) < 2,
              "the capture should be placed at the point size it was dragged at - got \(width)x\(height)")
        check(controller.debugLastCaptureSummary?.contains("240") == true,
              "the drill subtitle should describe the capture - got "
              + String(describing: controller.debugLastCaptureSummary))
        check(controller.debugLastCaptureSummary?.contains("2") == true,
              "a 2x fixture should be reported as Retina")
    }

    /// A capture must never land on top of the captain's existing work. The
    /// placement rule is pure logic and tested as such; what this adds is that
    /// the rule is actually *fed* by a real board read rather than by an
    /// assumption that the board is empty.
    private static func checkSecondCaptureStacksBelow(_ controller: WhiteboardController,
                                                      _ check: (Bool, String) -> Void) {
        guard let board = capture(controller, pixelWidth: 200, pixelHeight: 200,
                                  pointWidth: 100, pointHeight: 100, check: check) else { return }
        let images = board.filter { ($0["type"] as? String) == "image" }
        check(images.count == 2, "the second capture should join the first, not replace it - got \(images.count)")
        guard images.count == 2 else { return }
        // A missing `y` is zero, not missing data - `toSkeleton` omits any
        // numeric field whose value is 0, which is exactly what the first
        // capture (placed at the origin) comes back as.
        let tops = images.map { ($0["y"] as? Double) ?? 0 }.sorted()
        guard tops.count == 2 else {
            check(false, "both captures should be measurable")
            return
        }
        check(tops[0] < 1, "the first capture should still be at the origin - got \(tops[0])")
        // The first capture is 120pt tall at y=0, so anything overlapping it
        // would sit below 120. The gap puts the second at 168.
        check(tops[1] >= 120 + WhiteboardCaptureScene.stackGap - 1,
              "the second capture must clear the first - tops were \(tops)")
    }

    /// The check that everything else is a proxy for: the flattened PNG really
    /// contains the captured pixels.
    private static func checkExportContainsTheCapture(_ controller: WhiteboardController,
                                                      _ check: (Bool, String) -> Void) {
        var answered = false
        var png: Data?
        var reported: (Int, Int) = (0, 0)
        var problem = ""
        controller.debugWebView.call("exportImage", payload: ["maxWidthOrHeight": 2048, "padding": 16]) { result in
            answered = true
            guard case .success(let body) = result else {
                if case .failure(let error) = result { problem = error.message }
                return
            }
            if let url = body["dataURL"] as? String {
                png = WhiteboardCaptureScene.png(fromDataURL: url)
                if png == nil { problem = "the reply was not a PNG data URL (\(url.prefix(40)))" }
            } else {
                problem = "the reply carried no dataURL"
            }
            reported = ((body["width"] as? Int) ?? 0, (body["height"] as? Int) ?? 0)
        }
        guard waitFor(timeout: 20, until: { answered }) else {
            check(false, "exportImage never answered")
            return
        }
        guard let png else {
            check(false, "exportImage did not return a decodable PNG - \(problem)")
            return
        }
        check(reported.0 > 0 && reported.1 > 0,
              "the export should report its own dimensions - got \(reported)")
        guard let rep = NSBitmapImageRep(data: png) else {
            check(false, "the exported PNG should decode as a bitmap")
            return
        }
        check(rep.pixelsWide > 100 && rep.pixelsHigh > 100,
              "the export should be a real board-sized image - got \(rep.pixelsWide)x\(rep.pixelsHigh)")

        // The fixture's own discriminating half first: the fill really is a
        // colour the canvas would not produce by itself, so finding it is
        // evidence and not luck.
        let target = NSColor(calibratedRed: fillRGB.0, green: fillRGB.1, blue: fillRGB.2, alpha: 1)
        // AGENTS.md's probe rule: compare in the rep's own colour space, never
        // via a `.sRGB` conversion, and index in *pixels*.
        guard let expected = target.usingColorSpace(rep.colorSpace) else {
            check(false, "could not express the fixture colour in the export's own colour space")
            return
        }
        var best: CGFloat = 3
        // The two captures are the only non-background content, and both sit
        // near the left edge. Sample a grid rather than one point: the export
        // pads and scales, so no single coordinate is predictable.
        let stepX = max(1, rep.pixelsWide / 24)
        let stepY = max(1, rep.pixelsHigh / 24)
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(pixel.redComponent - expected.redComponent)
                    + abs(pixel.greenComponent - expected.greenComponent)
                    + abs(pixel.blueComponent - expected.blueComponent)
                best = min(best, delta)
            }
        }
        check(best < 0.12,
              "the flattened export should contain the captured image's own colour - closest sampled "
              + "pixel was \(String(format: "%.3f", Double(best))) away")
    }

    /// Escape during a drag must leave the board exactly as it was, and must
    /// not report a failure - it is a decision, not an error.
    private static func checkCancelChangesNothing(_ controller: WhiteboardController,
                                                  _ check: (Bool, String) -> Void) {
        let before = elements(of: controller, check: check)?.count ?? -1
        controller.captureProvider = { done in
            done(ScreenRegionCapture.Result(outcome: .cancelled, image: nil))
        }
        controller.captureTapped()
        // Nothing is asynchronous on the cancel path, but give the run loop a
        // turn anyway so a future implementation that defers cannot make this
        // pass by racing.
        _ = waitFor(timeout: 1, until: { false })
        let after = elements(of: controller, check: check)?.count ?? -2
        check(before == after, "a cancelled capture must change nothing - \(before) -> \(after)")
        controller.captureProvider = nil
    }

    /// GL-09, both halves independently.
    ///
    /// Each gate is asserted on its own - a shared `AppLockedSurface` case
    /// would let this pass with one of the two deleted, which is precisely
    /// what `AppLockGate.swift`'s header warns about.
    private static func checkTheLockGatesBothHalves(_ controller: WhiteboardController,
                                                    _ check: (Bool, String) -> Void) {
        // Restored to *unlocked* rather than to whatever it was: `run()` above
        // already unlocked for the whole suite, and any case added after this
        // one would otherwise inherit a locked gate.
        defer { AppLockGate.shared.setLocked(false) }

        // The fixture's discriminating half first: unlocked, the gate lets
        // both through, so a gate that refused unconditionally would fail here
        // rather than look like good security.
        AppLockGate.shared.setLocked(false)
        check(AppLockGate.shared.allows(.screenCapture), "an unlocked app must allow a capture")
        check(AppLockGate.shared.allows(.whiteboardCopy), "an unlocked app must allow a copy")

        AppLockGate.shared.setLocked(true)
        check(!AppLockGate.shared.allows(.screenCapture),
              "a locked app must refuse a capture - screencapture's crosshair draws over the lock overlay")
        check(!AppLockGate.shared.allows(.whiteboardCopy), "a locked app must refuse a board copy")

        // And the call sites really consult it. A capture that got through
        // would move the subtitle; a copy that got through would reach the
        // pasteboard.
        let summaryBefore = controller.debugLastCaptureSummary
        var providerRan = false
        controller.captureProvider = { done in
            providerRan = true
            done(ScreenRegionCapture.Result(outcome: .cancelled, image: nil))
        }
        controller.captureTapped()
        check(!providerRan, "captureTapped must not reach the capture provider while the app is locked")
        check(controller.debugLastCaptureSummary == summaryBefore,
              "a refused capture must leave the board's subtitle alone")
        controller.captureProvider = nil

        let board = NSPasteboard(name: .init("fm.selftest.capture.lock"))
        board.clearContents()
        board.setString("untouched", forType: .string)
        controller.copyPasteboard = board
        controller.copyImageTapped()
        _ = waitFor(timeout: 2, until: { board.data(forType: .png) != nil })
        check(board.string(forType: .string) == "untouched",
              "copyImageTapped must not reach the pasteboard while the app is locked")
        controller.copyPasteboard = .general
        board.clearContents()
    }

    /// Gotcha (13): the drill header's actions hug at `.required`, so adding
    /// two more labeled buttons is adding to a chain that can reach the
    /// window's own minimum size. Measured rather than reasoned about.
    private static func checkHeaderDoesNotResizeTheWindow(_ controller: WhiteboardController,
                                                          _ window: NSWindow,
                                                          _ check: (Bool, String) -> Void) {
        let actions = controller.drillHeaderActions
        check(actions.count == 6, "the Whiteboard's action cluster should carry six buttons - got \(actions.count)")
        let total = actions.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
        // The narrowest display this app is expected on is 1280pt wide; the
        // cluster shares the bar with a title, a search pill and an avatar, so
        // it has no business claiming half of that.
        check(total < 620,
              "the six action buttons should stay well inside a bar - they want \(Int(total))pt")

        // And the window itself still resizes, which is the outcome gotcha
        // (13) is actually about.
        let small = NSRect(x: 0, y: 0, width: 900, height: 620)
        window.setFrame(small, display: true)
        controller.view.layoutSubtreeIfNeeded()
        check(abs(window.frame.width - 900) < 1,
              "the window must hold a width the caller set - it came back at \(window.frame.width)")
    }

    // MARK: Driving a capture

    /// Injects a synthetic capture through the controller's real path and
    /// returns the board afterwards.
    private static func capture(_ controller: WhiteboardController,
                                pixelWidth: Int, pixelHeight: Int,
                                pointWidth: CGFloat, pointHeight: CGFloat,
                                check: (Bool, String) -> Void) -> [[String: Any]]? {
        let image = fixtureImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                 pointWidth: pointWidth, pointHeight: pointHeight)
        controller.captureProvider = { done in
            done(ScreenRegionCapture.Result(outcome: .captured, image: image))
        }
        let before = controller.debugLastCaptureSummary
        controller.captureTapped()
        // The placement is two bridge round trips (snapshot, then load), so
        // wait on the observable outcome rather than on a fixed delay.
        let landed = waitFor(timeout: 20, until: { controller.debugLastCaptureSummary != before })
        controller.captureProvider = nil
        guard landed else {
            check(false, "the injected capture never reached the board")
            return nil
        }
        return elements(of: controller, check: check)
    }

    private static func elements(of controller: WhiteboardController,
                                 check: (Bool, String) -> Void) -> [[String: Any]]? {
        var snapshot: [[String: Any]]?
        var answered = false
        controller.debugSnapshotBoard { result in
            answered = true
            if case .success(let elements) = result { snapshot = elements }
        }
        guard waitFor(timeout: 15, until: { answered }) else {
            check(false, "the board snapshot never answered")
            return nil
        }
        return snapshot
    }

    /// A Retina-shaped fixture filled with `fillRGB`.
    private static func fixtureImage(pixelWidth: Int, pixelHeight: Int,
                                     pointWidth: CGFloat, pointHeight: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pointWidth, height: pointHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: fillRGB.0, green: fillRGB.1, blue: fillRGB.2, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pointWidth, height: pointHeight))
        image.addRepresentation(rep)
        return image
    }

    private static func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

#endif
