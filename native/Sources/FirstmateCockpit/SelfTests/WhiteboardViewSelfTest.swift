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
        checkFrameChildrenSafetyNet(controller, check)
        checkComposerDrawsOntoTheCanvas(controller, check)
        checkBoardSnapshotRoundTrip(controller, check)
        checkIterativeRefinement(controller, check)
        checkKubernetesRequestPathRepro(controller, check)
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

    // MARK: JS-side safety net for a malformed skeleton (real bundle)

    /// The defense-in-depth half of the frame-crash fix
    /// (`fm/grand-line-whiteboard-generate-crash`): whatever the Swift-side
    /// `WhiteboardDiagram.parse` validation does or does not catch, the page's
    /// own `loadScene` must never let a raw internal JS error from
    /// `convertToExcalidrawElements` reach the captain. This drives
    /// `controller.debugLoad` directly with a skeleton that skips
    /// `WhiteboardDiagram.parse` entirely - a frame with no "children" key,
    /// the exact real, captain-reported crash - against the real vendored
    /// bundle, so it is the one test in this codebase proving the safety net
    /// (not just the Swift-side check) actually holds.
    private static func checkFrameChildrenSafetyNet(_ controller: WhiteboardController, _ check: (Bool, String) -> Void) {
        let before = statsCount(controller.debugWebView) ?? 0

        let malformedFrame: [[String: Any]] = [
            ["type": "rectangle", "x": 0, "y": 0, "width": 200, "height": 100, "id": "ingress"],
            ["type": "frame", "id": "cluster", "name": "Kubernetes Cluster"],
        ]
        var failure: String? = "never answered"
        var answered = false
        controller.debugLoad(elements: malformedFrame, append: true) { message in
            failure = message
            answered = true
        }
        check(waitFor(timeout: 15, until: { answered }), "a malformed frame load should still answer")
        check(failure != nil, "a frame with no children must be reported as a failure, not silently accepted")
        if let failure {
            check(!failure.contains("forEach") && !failure.contains("undefined is not an object"),
                  "the raw JS crash text leaked to the captain: \"\(failure)\"")
            check(!failure.isEmpty, "the failure needs a real message, not an empty string")
        }
        // A rejected load must leave the board untouched - the whole reason
        // `append` mode exists is so a failed generation cannot destroy
        // whatever was already there.
        check((statsCount(controller.debugWebView) ?? -1) == before,
              "a failed load must not change the board (\(before) -> \(String(describing: statsCount(controller.debugWebView))))")
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
        composer.debugClearStatus()
        composer.debugClickGenerate()
        _ = waitFor(timeout: 30, until: { settled(composer) })
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
        composer.debugClearStatus()
        composer.debugClickGenerate()
        // The synchronous interim status ("Asking Claude for a diagram…") set
        // the instant the click fires already satisfies "not empty and not
        // Drew" - waiting on that alone (as this used to) does not actually
        // wait for the async generation to finish, and lets its completion
        // land later, stale, clobbering whatever the *next* check happens to
        // be reading at that moment. Wait for the interim status to be gone
        // instead, matching the positive-outcome wait every other scenario in
        // this file uses.
        _ = waitFor(timeout: 30, until: { settled(composer) })
        check(!composer.debugStatus.isEmpty && !composer.debugStatus.contains("Drew"),
              "a prose reply should surface as an error in the popover, got \"\(composer.debugStatus)\"")
        check((statsCount(controller.debugWebView) ?? 0) == after,
              "a failed generation must not change the board")
    }

    // MARK: The captain's exact repro - "Kubernetes request path"

    /// `fm/grand-line-whiteboard-generate-crash`'s captain-reported repro: type
    /// "Kubernetes request path" into the composer, click Generate. Two
    /// scenarios, both against the real composer, real popover controls and
    /// the real vendored bundle:
    ///
    ///  1. A model reply shaped exactly like the one that crashed in the wild
    ///     (a frame grouping some pods, with no "children" list) must now be
    ///     refused by `WhiteboardDiagram.parse` - at the *Swift* layer, before
    ///     ever reaching the page - with a clear message in the popover, and
    ///     the board must be untouched.
    ///  2. A well-formed reply for the same prompt - the shape the prompt's
    ///     own new documentation asks the model to produce - must draw onto
    ///     the real canvas with no error, which is the acceptance bar the
    ///     captain's report set.
    private static func checkKubernetesRequestPathRepro(_ controller: WhiteboardController, _ check: (Bool, String) -> Void) {
        let composer = controller.debugComposer
        let before = statsCount(controller.debugWebView) ?? 0

        // Scenario 1: the malformed reply, unwittingly reproducing what a
        // real Claude call for this exact prompt returned before the prompt
        // was told about "children".
        let malformed = "[{\"type\":\"rectangle\",\"x\":0,\"y\":0,\"width\":200,\"height\":100," +
            "\"id\":\"ingress\",\"label\":{\"text\":\"Ingress\"}}," +
            "{\"type\":\"rectangle\",\"x\":300,\"y\":0,\"width\":200,\"height\":100," +
            "\"id\":\"svc\",\"label\":{\"text\":\"Service\"}}," +
            "{\"type\":\"arrow\",\"x\":210,\"y\":50,\"width\":80,\"height\":0," +
            "\"start\":{\"id\":\"ingress\"},\"end\":{\"id\":\"svc\"}}," +
            "{\"type\":\"frame\",\"id\":\"cluster\",\"name\":\"Kubernetes Cluster\"}]"
        let malformedScript = writeFakeClaude(result: malformed)
        defer {
            try? FileManager.default.removeItem(at: malformedScript)
            WhiteboardDiagram.claudePathOverrideForTests = nil
        }
        WhiteboardDiagram.claudePathOverrideForTests = malformedScript.path

        composer.debugPrepare(prompt: "Kubernetes request path", appends: true)
        composer.debugClearStatus()
        composer.debugClickGenerate()
        _ = waitFor(timeout: 20, until: { !composer.debugStatus.isEmpty && !composer.debugStatus.contains("Asking") })
        let malformedStatus = composer.debugStatus
        check(!malformedStatus.isEmpty && !malformedStatus.contains("Drew"),
              "a frame with no children should surface as a refusal, got \"\(malformedStatus)\"")
        check(malformedStatus.contains("children"),
              "the refusal should be the Swift-side parse error naming the missing field, got \"\(malformedStatus)\"")
        check(!malformedStatus.contains("forEach") && !malformedStatus.contains("undefined is not an object"),
              "the raw JS crash text must never reach the popover, got \"\(malformedStatus)\"")
        check((statsCount(controller.debugWebView) ?? -1) == before,
              "the malformed reply must not touch the board")

        // Scenario 2: a well-formed reply for the identical prompt - the
        // acceptance bar - draws a real diagram with no error.
        let wellFormed = "[{\"type\":\"rectangle\",\"x\":0,\"y\":0,\"width\":200,\"height\":100," +
            "\"id\":\"ingress\",\"label\":{\"text\":\"Ingress\"}}," +
            "{\"type\":\"rectangle\",\"x\":300,\"y\":0,\"width\":200,\"height\":100," +
            "\"id\":\"svc-a\",\"label\":{\"text\":\"Service A\"}}," +
            "{\"type\":\"rectangle\",\"x\":300,\"y\":150,\"width\":200,\"height\":100," +
            "\"id\":\"svc-b\",\"label\":{\"text\":\"Service B\"}}," +
            "{\"type\":\"arrow\",\"x\":210,\"y\":50,\"width\":80,\"height\":30," +
            "\"start\":{\"id\":\"ingress\"},\"end\":{\"id\":\"svc-a\"}}," +
            "{\"type\":\"arrow\",\"x\":210,\"y\":50,\"width\":80,\"height\":150," +
            "\"start\":{\"id\":\"ingress\"},\"end\":{\"id\":\"svc-b\"}}," +
            "{\"type\":\"frame\",\"id\":\"cluster\",\"name\":\"Kubernetes Cluster\"," +
            "\"children\":[\"ingress\",\"svc-a\",\"svc-b\"]}]"
        let wellFormedScript = writeFakeClaude(result: wellFormed)
        defer { try? FileManager.default.removeItem(at: wellFormedScript) }
        WhiteboardDiagram.claudePathOverrideForTests = wellFormedScript.path

        composer.debugPrepare(prompt: "Kubernetes request path", appends: true)
        composer.debugClearStatus()
        composer.debugClickGenerate()
        _ = waitFor(timeout: 20, until: { composer.debugStatus.contains("Drew") || composer.debugStatus.contains("couldn't") })
        check(composer.debugStatus.contains("Drew"),
              "a well-formed reply for the captain's exact prompt should draw with no error, got \"\(composer.debugStatus)\"")
        let after = statsCount(controller.debugWebView) ?? 0
        check(after > before, "the real diagram should reach the canvas (\(before) -> \(after))")
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

    // MARK: Snapshot (board -> skeleton)

    /// The refine turn's whole correctness rests on this: what the model is
    /// told the board contains has to be what the board actually contains.
    /// Excalidraw publishes no inverse of `convertToExcalidrawElements`, so
    /// `snapshot` reconstructs the skeleton by hand - and the parts most worth
    /// asserting are exactly the ones that are *not* a straight field copy: a
    /// shape's caption lives as a separate `text` element pointing back at it,
    /// an arrow's bindings live as `startBinding`/`endBinding`, and a frame's
    /// membership lives on each *child* rather than on the frame.
    private static func checkBoardSnapshotRoundTrip(_ controller: WhiteboardController,
                                                    _ check: (Bool, String) -> Void) {
        let skeleton: [[String: Any]] = [
            ["type": "rectangle", "id": "db", "x": 0, "y": 0, "width": 160, "height": 80,
             "label": ["text": "Postgres"], "backgroundColor": "#b2f2bb"],
            ["type": "rectangle", "id": "api", "x": 320, "y": 0, "width": 160, "height": 80,
             "label": ["text": "API"]],
            ["type": "arrow", "id": "edge", "x": 170, "y": 40, "width": 140, "height": 0,
             "start": ["id": "api"], "end": ["id": "db"]],
            ["type": "frame", "id": "cluster", "name": "Cluster", "children": ["db", "api"]],
        ]
        var loadFailure: String?
        var loaded = false
        controller.debugLoad(elements: skeleton, append: false) { failure in
            loadFailure = failure
            loaded = true
        }
        _ = waitFor(timeout: 20, until: { loaded })
        guard loadFailure == nil else {
            check(false, "the snapshot fixture failed to load: \(loadFailure!)")
            return
        }

        var snapshot: [[String: Any]]?
        var message: String?
        var answered = false
        controller.debugSnapshotBoard { result in
            switch result {
            case .success(let elements): snapshot = elements
            case .failure(let error): message = error.message
            }
            answered = true
        }
        _ = waitFor(timeout: 20, until: { answered })
        guard let board = snapshot else {
            check(false, "the board snapshot failed: \(message ?? "no answer")")
            return
        }

        let types = board.compactMap { $0["type"] as? String }
        check(types.contains("rectangle") && types.contains("arrow") && types.contains("frame"),
              "the snapshot should carry every shape kind on the board, got \(types)")
        // A caption is its own element in Excalidraw; if it came back standalone
        // the model would be handed a diagram whose boxes look empty and whose
        // text floats.
        let standaloneText = board.filter { ($0["type"] as? String) == "text" }
        check(standaloneText.isEmpty,
              "a bound caption must fold back into its shape's label, not come back as a loose text element")
        // Elements are found by their caption, not by the id the fixture used:
        // `convertToExcalidrawElements` mints its own ids, and a skeleton's
        // "id" is a *reference key* for bindings rather than the id the drawn
        // element ends up carrying. A snapshot has to report the real ids, or
        // a refinement's bindings would name elements that do not exist.
        func labelled(_ text: String) -> [String: Any]? {
            board.first { (($0["label"] as? [String: Any])?["text"] as? String) == text }
        }
        let db = labelled("Postgres")
        let api = labelled("API")
        check(db != nil, "the snapshot must recover a shape's caption as its label")
        check((db?["backgroundColor"] as? String) != nil,
              "the snapshot must carry the styling fields the prompt itself offers")
        check((db?["id"] as? String)?.isEmpty == false && (api?["id"] as? String)?.isEmpty == false,
              "every snapshot element needs a real id for a refinement to reference")

        let arrow = board.first { ($0["type"] as? String) == "arrow" }
        let startID = (arrow?["start"] as? [String: Any])?["id"] as? String
        let endID = (arrow?["end"] as? [String: Any])?["id"] as? String
        check(startID == (api?["id"] as? String) && endID == (db?["id"] as? String),
              "the snapshot must recover an arrow's bindings as the real start/end ids")

        let frame = board.first { ($0["type"] as? String) == "frame" }
        let children = (frame?["children"] as? [String]) ?? []
        let boardIDs = Set(board.compactMap { $0["id"] as? String })
        // Membership is Excalidraw's own call - it assigns `frameId` by
        // containment, so an arrow drawn between two framed shapes is a member
        // too. What has to hold is not a count but the invariant the validator
        // enforces: every named child is genuinely in the snapshot.
        check(children.allSatisfy { boardIDs.contains($0) },
              "a frame's children must all be elements that are actually in the snapshot - a bound caption inherits its container's frameId and is folded away, so naming it here produces a skeleton nothing will accept (got \(children))")
        check(Set([db?["id"] as? String, api?["id"] as? String].compactMap { $0 }).isSubset(of: Set(children)),
              "the shapes inside the frame must be listed as its children")

        // The strongest single property: whatever comes out must be something
        // the app's own validator accepts and the canvas can draw. A snapshot
        // that round-trips is what makes "refine" safe to apply as a replace.
        switch WhiteboardDiagram.parse(WhiteboardDiagram.encode(board) ?? "[]") {
        case .success(let parsed):
            check(parsed.count == board.count,
                  "a snapshot must survive the app's own parse unchanged (\(board.count) -> \(parsed.count))")
        case .failure(let error):
            check(false, "a board snapshot must be a skeleton this app would accept, got: \(error.message)")
        }
    }

    // MARK: Iterative refinement (the real UI path, real Process, fake claude)

    /// A genuine multi-turn exchange driven through the popover's own controls.
    ///
    /// This is the acceptance case for the feature: turn one draws, turn two is
    /// read as a *change to that diagram* rather than a fresh unrelated
    /// request, and the popover says which mode it is in at each point. It
    /// drives the real button target/action and the real `claude -p` path
    /// (against a scripted fake), so a break in the wiring fails here rather
    /// than passing.
    private static func checkIterativeRefinement(_ controller: WhiteboardController,
                                                 _ check: (Bool, String) -> Void) {
        let composer = controller.debugComposer
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-wbview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claude = dir.appendingPathComponent("claude")
        defer {
            try? FileManager.default.removeItem(at: dir)
            WhiteboardDiagram.claudePathOverrideForTests = nil
            composer.endSession()
        }

        func write(reply turn: Int, elements: String, session: String) {
            let obj: [String: Any] = ["result": elements, "is_error": false, "session_id": session]
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            let json = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
            try? json.write(to: dir.appendingPathComponent("reply-\(turn)"), atomically: true, encoding: .utf8)
        }
        write(reply: 1, elements: "[{\"type\":\"rectangle\",\"id\":\"one\",\"x\":0,\"y\":0,\"width\":120,\"height\":60,\"label\":{\"text\":\"Only box\"}}]",
              session: "wb-session-1")
        write(reply: 2, elements: "[{\"type\":\"rectangle\",\"id\":\"one\",\"x\":0,\"y\":0,\"width\":400,\"height\":200,\"label\":{\"text\":\"Only box\"}},{\"type\":\"rectangle\",\"id\":\"two\",\"x\":500,\"y\":0,\"width\":120,\"height\":60,\"label\":{\"text\":\"Second box\"}}]",
              session: "wb-session-1")
        let script = """
        #!/bin/sh
        DIR="\(dir.path)"
        N=$(cat "$DIR/count" 2>/dev/null || echo 0)
        N=$((N+1))
        echo "$N" > "$DIR/count"
        : > "$DIR/argv-$N"
        for a in "$@"; do printf '%s\\n' "$a" >> "$DIR/argv-$N"; done
        if [ -f "$DIR/reply-$N" ]; then cat "$DIR/reply-$N"; else cat "$DIR/reply-1"; fi
        """
        try? script.write(to: claude, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        WhiteboardDiagram.claudePathOverrideForTests = claude.path

        func argv(_ turn: Int) -> String {
            (try? String(contentsOf: dir.appendingPathComponent("argv-\(turn)"), encoding: .utf8)) ?? ""
        }
        /// Clears the status, fires the button, and waits for a genuinely new
        /// terminal status. Clearing first is what makes this a wait for a
        /// *transition*: the interim status a click sets synchronously is
        /// otherwise indistinguishable from one left over from an earlier
        /// step, and the wait returns instantly against stale state.
        func clickAndSettle() {
            composer.debugClearStatus()
            composer.debugClickGenerate()
            _ = waitFor(timeout: 30, until: { settled(composer) })
        }

        // --- Turn 1: a fresh generation, from the fresh-mode popover ---------
        composer.endSession()
        check(!composer.debugIsRefining, "a popover with no session is in fresh mode")
        check(composer.debugTitle == "Generate a diagram",
              "fresh mode should say Generate, got \"\(composer.debugTitle)\"")
        check(composer.debugGenerateButtonTitle == "Generate",
              "fresh mode's button should say Generate, got \"\(composer.debugGenerateButtonTitle)\"")
        check(composer.debugAppendToggleVisible,
              "the add-to-board checkbox belongs to a first generation and must still be offered")
        check(!composer.debugStartOverVisible, "there is nothing to start over from yet")
        check(composer.debugHistoryLines.isEmpty, "a fresh popover has no turns to list")

        // `appends: false` so the fixture from the snapshot case is replaced
        // and the counts below are about this exchange only.
        composer.debugPrepare(prompt: "one box", appends: false)
        clickAndSettle()
        check(composer.debugStatus.contains("Drew"),
              "turn 1 should report what it drew, got \"\(composer.debugStatus)\"")
        check(skeletonCount(controller) == 1,
              "turn 1 should leave exactly its own diagram on the board, got \(skeletonCount(controller) ?? -1)")
        check(composer.debugTurns == ["one box"], "turn 1 should be recorded, got \(composer.debugTurns)")
        check(composer.debugSessionID == "wb-session-1",
              "the session id from turn 1 must be kept, got \(composer.debugSessionID ?? "nil")")

        // --- The popover has visibly become a conversation -------------------
        check(composer.debugIsRefining, "after one turn the popover is refining")
        check(composer.debugTitle == "Refine the diagram",
              "refining mode should say Refine, got \"\(composer.debugTitle)\"")
        check(composer.debugGenerateButtonTitle == "Refine",
              "refining mode's button should say Refine, got \"\(composer.debugGenerateButtonTitle)\"")
        check(!composer.debugAppendToggleVisible,
              "a refinement replaces the board with its revision, so the add-or-replace question is gone")
        check(composer.debugStartOverVisible, "a session must offer a deliberate way out")
        check(composer.debugHistoryLines.contains(where: { $0.contains("one box") }),
              "the popover must show what was already asked for, got \(composer.debugHistoryLines)")

        // --- Turn 2: a follow-up, refining THAT diagram ----------------------
        composer.debugPrepare(prompt: "make it bigger and add a second box", appends: false)
        clickAndSettle()
        check(composer.debugStatus.contains("Refined"),
              "turn 2 should report a refinement, not a fresh draw - got \"\(composer.debugStatus)\"")
        check(skeletonCount(controller) == 2,
              "turn 2's revision should be what is on the board, got \(skeletonCount(controller) ?? -1)")
        check(composer.debugTurns.count == 2, "both turns should be recorded, got \(composer.debugTurns)")

        // The two properties that make it a genuine refinement rather than an
        // unrelated regeneration: the conversation was resumed, and the prompt
        // carried the board that was actually on the canvas.
        let second = argv(2)
        check(second.contains("--resume") && second.contains("wb-session-1"),
              "turn 2 must resume turn 1's conversation")
        check(second.contains("Only box"),
              "turn 2's prompt must carry the live board - the model has to be told what \"it\" is")
        check(second.contains("make it bigger and add a second box"),
              "turn 2's prompt must carry the follow-up instruction")
        check(!argv(1).contains("--resume"), "turn 1 must not have resumed anything")

        // --- Start over: a deliberate way back to a brand-new generation -----
        composer.debugClickStartOver()
        check(!composer.debugIsRefining, "Start over must end the session")
        check(composer.debugTurns.isEmpty, "Start over must forget the turns, got \(composer.debugTurns)")
        check(composer.debugSessionID == nil, "Start over must forget the claude session id")
        check(composer.debugTitle == "Generate a diagram", "Start over returns the popover to fresh mode")
        check(composer.debugAppendToggleVisible, "the add-to-board checkbox comes back with fresh mode")
        check(composer.debugHistoryLines.isEmpty, "Start over clears the listed turns")
        check(skeletonCount(controller) == 2,
              "Start over must not touch the board - clearing it is the destination's own action")
        check(composer.debugStatus.contains("untouched"),
              "Start over should say the board was left alone, got \"\(composer.debugStatus)\"")

        // --- And the next generation really is fresh -------------------------
        composer.debugPrepare(prompt: "one box", appends: false)
        clickAndSettle()
        check(!argv(3).contains("--resume"),
              "the generation after Start over must not resume the discarded conversation")
        check(!argv(3).contains("Only box"),
              "the generation after Start over must not carry the old board as context")
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

    /// Has the composer finished the turn it was given?
    ///
    /// Both interim statuses are excluded, not just the first: a wait that
    /// only rules out "Asking Claude…" returns the instant a click sets
    /// "Reading the board…" - and a completion landing after a case returns
    /// rewrites the popover's state in the *middle of the next one*, which is
    /// exactly how this suite produced a run of unrelated-looking failures.
    private static func settled(_ composer: WhiteboardComposerController) -> Bool {
        !composer.debugStatus.isEmpty
            && !composer.debugStatus.contains("Asking")
            && !composer.debugStatus.contains("Reading the board")
    }

    /// How many *skeleton* elements the board holds - which is not the raw
    /// scene element count, because a captioned shape is two scene elements
    /// (the shape and its bound text) and one skeleton element.
    private static func skeletonCount(_ controller: WhiteboardController) -> Int? {
        var count: Int?
        var answered = false
        controller.debugSnapshotBoard { result in
            if case .success(let elements) = result { count = elements.count }
            answered = true
        }
        _ = waitFor(timeout: 10, until: { answered })
        return count
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
