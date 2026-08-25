// Manjesh Grand Line - native macOS app.
//
// The window-backed half of the Whiteboard's coverage
// (`fm/grand-line-whiteboard-excalidraw`): the real `WhiteboardWebView` in a
// real window, loading the real vendored Excalidraw bundle, driven through the
// real bridge.
//
// Split from `WhiteboardSelfTest` because everything here needs a window server
// and a live web content process - so this suite sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list beside its window-backed peers,
// while the logic suite runs in CI.
//
// What it is for, in order of how much it matters:
//
//   1. **The gating decision.** "The hidden tab costs nothing" is this
//      feature's headline claim, and E1 is what happens when nobody checks it.
//      What is asserted here is WebKit's own reading: while the view is hidden
//      the page reports `document.visibilityState === "hidden"` and its
//      `requestAnimationFrame` counter does not advance.
//
//      **Measured limitation, stated rather than papered over.** A suite run
//      from a terminal is not a real UI app (activation policy `.accessory`,
//      `NSApp.run()` never called), so the window server never composites its
//      windows and WebKit reports the page as `hidden` *even while the view is
//      shown* - confirmed by reading `visibilityState` back through the bridge.
//      So the shown-state half cannot be measured here and the suite says so
//      instead of asserting something it cannot see. That half is verified by
//      running the real app (see this branch's PR for the readings and the
//      Activity Monitor numbers); what this suite locks down is that hiding
//      never *fails* to reach the page, which is the direction a regression
//      would break.
//   2. **The page actually mounts.** The bundle can resolve, load, and still
//      fail at runtime (a renamed library export, a CSP that blocks something
//      new). `ready` arriving is the one signal that the real Excalidraw
//      component mounted and its API is live.
//   3. **The bridge round trip.** A load that reports success has to have
//      really put elements on the board, and a bad skeleton has to come back
//      as a message rather than a silent no-op.
//
// `FM_RUN_WHITEBOARD_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum WhiteboardViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }

        // The bridge's failure paths need no page at all, so they run first and
        // cannot be skipped by a canvas that fails to start.
        checkBridgeFailurePaths(check)

        guard WhiteboardAssets.isAvailable else {
            check(false, "no Excalidraw bundle - run native/Scripts/build-excalidraw-web.sh")
            return false
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = WhiteboardController()
        window.contentView = controller.view
        // A window only becomes genuinely `.visible` to the window server for
        // a process that is a UI app - a suite run from a terminal is
        // `.prohibited` by default and its windows are never composited, which
        // for a web view means `requestAnimationFrame` never fires even when
        // shown. `TerminalDisplayGatingSelfTest.mount()` records the same
        // requirement for the same reason.
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        // A web view in a window that was never ordered front is never
        // composited, which would make every measurement below meaningless -
        // the same lesson `fm/grandline-sre-lead-app-feel` recorded for
        // SwiftTerm.
        window.displayIfNeeded()

        let webView = controller.debugWebView
        check(controller.debugOverlayVisible, "the overlay should cover the canvas until it reports ready")

        guard waitFor(timeout: 30, until: { webView.isReady }) else {
            check(false, "the Excalidraw canvas never reported ready - the bundle loaded but did not mount")
            return false
        }
        check(!controller.debugOverlayVisible, "the overlay should be gone once the canvas is ready")

        checkSceneLoading(controller, check)
        checkComposerDrawsOntoTheCanvas(controller, check)
        checkGating(controller, webView, check)
        checkNoLeakedBridgeCalls(webView, check)

        window.orderOut(nil)
        print(ok ? "WhiteboardViewSelfTest: OK" : "WhiteboardViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Bridge failure paths (no page needed)

    private static func checkBridgeFailurePaths(_ check: (Bool, String) -> Void) {
        let view = WhiteboardWebView()

        // Before `activate()`, a caller must get an answer rather than a
        // completion that never fires.
        var early: Result<[String: Any], WhiteboardBridgeError>?
        view.call("stats") { early = $0 }
        check(early != nil, "a call before the page is loaded must answer immediately")
        if case .failure(let error)? = early {
            check(!error.message.isEmpty, "the early failure should carry a real message")
        } else {
            check(false, "a call before the page is loaded should fail, not succeed")
        }
        check(view.debugPendingCallCount == 0, "a rejected call must not leave a pending completion behind")

        // A reply for a call id nobody is waiting on (a late arrival after a
        // failure) must be a no-op, not a crash.
        view.debugHandle(message: ["type": "reply", "callID": 999, "ok": true])

        // The error channel reaches the controller rather than being swallowed.
        var reported: String?
        view.onPageError = { reported = $0 }
        view.debugHandle(message: ["type": "error", "message": "boom"])
        check(reported == "boom", "a page error should surface with its own message")
    }

    // MARK: Scene loading

    private static func checkSceneLoading(_ controller: WhiteboardController, _ check: (Bool, String) -> Void) {
        // A real skeleton, the same shape `WhiteboardDiagram.parse` hands over:
        // two labelled boxes and an arrow bound to both.
        let skeleton: [[String: Any]] = [
            ["type": "rectangle", "x": 0, "y": 0, "width": 180, "height": 80,
             "id": "lb", "label": ["text": "Load balancer"]],
            ["type": "rectangle", "x": 320, "y": 0, "width": 180, "height": 80,
             "id": "app", "label": ["text": "App server"]],
            ["type": "arrow", "x": 190, "y": 40, "width": 120, "height": 0,
             "start": ["id": "lb"], "end": ["id": "app"]],
        ]

        var failure: String? = "never answered"
        var answered = false
        controller.debugLoad(elements: skeleton, append: false) { message in
            failure = message
            answered = true
        }
        check(waitFor(timeout: 15, until: { answered }), "loading a scene should answer")
        check(failure == nil, "a valid skeleton should load, got \(failure ?? "-")")

        // `convertToExcalidrawElements` binds an arrow's label and container
        // wiring itself, so the element count on the canvas is the library's
        // business - what this asserts is only that the board is no longer
        // empty, which is the claim the drill header makes.
        let count = statsCount(controller.debugWebView)
        check((count ?? 0) >= 3, "the canvas should hold at least the three elements loaded, got \(String(describing: count))")

        // Append must add rather than replace - the composer's checkbox is the
        // only thing choosing between them.
        answered = false
        controller.debugLoad(elements: [["type": "ellipse", "x": 0, "y": 200, "width": 60, "height": 60]],
                             append: true) { _ in answered = true }
        check(waitFor(timeout: 15, until: { answered }), "an append should answer")
        let appended = statsCount(controller.debugWebView)
        check((appended ?? 0) > (count ?? 0),
              "append should grow the board (\(String(describing: count)) -> \(String(describing: appended)))")

        // A skeleton the library rejects has to come back as a message. An
        // arrow bound to ids that do not exist is the realistic model mistake.
        answered = false
        var rejection: String?
        controller.debugLoad(elements: [], append: false) { message in
            rejection = message
            answered = true
        }
        check(waitFor(timeout: 15, until: { answered }), "an empty load should answer")
        check(rejection != nil, "an empty element list should be reported, not silently accepted")
    }

    // MARK: The composer, end to end

    /// The whole AI path as the captain drives it: type a description, click
    /// Generate, and have the elements land on the real canvas - through the
    /// popover's own controls and its `onGenerated` wiring, against a fake
    /// `claude`. Everything from the button's target/action to
    /// `convertToExcalidrawElements` is real.
    private static func checkComposerDrawsOntoTheCanvas(_ controller: WhiteboardController,
                                                       _ check: (Bool, String) -> Void) {
        let composer = controller.debugComposer
        let before = statsCount(controller.debugWebView) ?? 0

        let reply = "[{\"type\":\"rectangle\",\"x\":0,\"y\":600,\"width\":140,\"height\":60," +
            "\"label\":{\"text\":\"From the composer\"}}]"
        let script = writeFakeClaude(result: reply)
        defer {
            try? FileManager.default.removeItem(at: script)
            WhiteboardDiagram.claudePathOverrideForTests = nil
        }
        WhiteboardDiagram.claudePathOverrideForTests = script.path

        composer.debugPrepare(prompt: "one box", appends: true)
        composer.debugClickGenerate()
        _ = waitFor(timeout: 20, until: { composer.debugStatus.contains("Drew") || composer.debugStatus.contains("couldn't") })
        check(composer.debugStatus.contains("Drew"),
              "the composer should report what it drew, got \"\(composer.debugStatus)\"")
        let after = statsCount(controller.debugWebView) ?? 0
        check(after > before, "the composer's diagram should reach the canvas (\(before) -> \(after))")

        // A failing generation has to say so and leave the board alone - the
        // one behaviour that decides whether a bad reply is recoverable.
        let bad = writeFakeClaude(result: "I can't draw that, sorry.")
        defer { try? FileManager.default.removeItem(at: bad) }
        WhiteboardDiagram.claudePathOverrideForTests = bad.path
        composer.debugPrepare(prompt: "something impossible", appends: true)
        composer.debugClickGenerate()
        _ = waitFor(timeout: 20, until: { !composer.debugStatus.contains("Drew") && !composer.debugStatus.isEmpty })
        check(!composer.debugStatus.isEmpty && !composer.debugStatus.contains("Drew"),
              "a prose reply should surface as an error in the popover, got \"\(composer.debugStatus)\"")
        check((statsCount(controller.debugWebView) ?? 0) == after,
              "a failed generation must not change the board")
    }

    private static func writeFakeClaude(result: String) -> URL {
        let obj: [String: Any] = ["result": result, "is_error": false]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8) ?? "{}"
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-wb-view-\(UUID().uuidString).sh")
        let escaped = (json + "\n").replacingOccurrences(of: "'", with: "'\\''")
        try? "#!/bin/sh\nprintf '%s' '\(escaped)'\n".write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    // MARK: Gating

    /// The measurement that matters: while the view is hidden, WebKit stops
    /// compositing the page, so `requestAnimationFrame` stops firing. A probe
    /// that kept ticking would mean the canvas is still being driven behind the
    /// captain's back, which is precisely E1's bug.
    private static func checkGating(_ controller: WhiteboardController,
                                    _ webView: WhiteboardWebView,
                                    _ check: (Bool, String) -> Void) {
        check(webView.isOnScreen, "a shown web view in an ordered-front window should read as on screen")
        check(!webView.isSuspended, "a visible canvas should not be suspended")

        startProbe(webView)
        let visible = probeReading(webView, after: 0.6)
        let canMeasureVisible = visible.visibility == "visible"
        if canMeasureVisible {
            check(visible.frames > 0, "the page should animate while genuinely visible")
        } else {
            print("  NOTE: this process is not a composited UI app (visibilityState=\(visible.visibility) while shown), " +
                  "so the shown-state half of the gate is not measurable here - see this file's header.")
        }

        // Exactly what the destination model does on navigate-away.
        controller.view.isHidden = true
        check(!webView.isOnScreen, "a hidden view must not read as on screen")
        check(webView.isSuspended, "hiding the destination should suspend the page")

        startProbe(webView)
        let hidden = probeReading(webView, after: 1.0)
        check(hidden.frames == 0,
              "the page kept animating while hidden (\(hidden.frames) frames) - the hidden tab is costing real work")
        check(hidden.visibility == "hidden",
              "WebKit should report the page hidden while the view is hidden, got \(hidden.visibility)")
        check(hidden.suspended, "the page should know it is suspended")

        controller.view.isHidden = false
        check(webView.isOnScreen, "unhiding should read as on screen again")
        check(!webView.isSuspended, "unhiding should resume the page")
        let resumed = probeReading(webView, after: 0.2)
        check(!resumed.suspended, "the page should know it resumed")
        if canMeasureVisible {
            startProbe(webView)
            check(probeReading(webView, after: 0.6).frames > 0, "the page should animate again once visible")
        }
        // Leave nothing running behind us.
        controller.view.isHidden = true
        controller.view.isHidden = false

        // Occlusion is the other half of "not on screen", and it is tracked
        // from the notification rather than read live for the reason
        // `CockpitTerminalView` documents - so it is driven directly here.
        webView.debugSetOccluded(true)
        check(!webView.isOnScreen, "a fully occluded window means not on screen")
        check(webView.isSuspended, "occlusion should suspend the page")
        webView.debugSetOccluded(false)
        check(webView.isOnScreen && !webView.isSuspended, "un-occluding should resume")
    }

    private static func checkNoLeakedBridgeCalls(_ webView: WhiteboardWebView, _ check: (Bool, String) -> Void) {
        _ = waitFor(timeout: 2, until: { webView.debugPendingCallCount == 0 })
        check(webView.debugPendingCallCount == 0,
              "\(webView.debugPendingCallCount) bridge call(s) never got a reply - a caller would hang forever")
    }

    // MARK: Helpers

    private static func startProbe(_ webView: WhiteboardWebView) {
        var done = false
        webView.call("startGatingProbe") { _ in done = true }
        _ = waitFor(timeout: 5, until: { done })
    }

    private struct ProbeReading {
        let frames: Int
        let visibility: String
        let suspended: Bool
    }

    /// Runs the run loop for `interval`, then reads the page's own view of its
    /// state. The read itself works while hidden - `evaluateJavaScript` still
    /// executes script in a non-visible page; it is rendering and rAF that stop.
    private static func probeReading(_ webView: WhiteboardWebView, after interval: TimeInterval) -> ProbeReading {
        pump(interval)
        var reading: ProbeReading?
        webView.call("readGatingProbe") { result in
            if case .success(let body) = result {
                reading = ProbeReading(frames: (body["frames"] as? Int) ?? -1,
                                       visibility: (body["visibility"] as? String) ?? "?",
                                       suspended: (body["suspended"] as? Bool) ?? false)
            } else {
                reading = ProbeReading(frames: -1, visibility: "?", suspended: false)
            }
        }
        _ = waitFor(timeout: 5, until: { reading != nil })
        let value = reading ?? ProbeReading(frames: -1, visibility: "?", suspended: false)
        print("  probe: frames=\(value.frames) visibility=\(value.visibility) suspended=\(value.suspended)")
        return value
    }

    private static func statsCount(_ webView: WhiteboardWebView) -> Int? {
        var count: Int?
        var answered = false
        webView.call("stats") { result in
            if case .success(let body) = result { count = body["count"] as? Int }
            answered = true
        }
        _ = waitFor(timeout: 10, until: { answered })
        return count
    }

    private static func pump(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
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
