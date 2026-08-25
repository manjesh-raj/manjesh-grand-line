// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the Whiteboard destination's
// *logic* half (`fm/grand-line-whiteboard-excalidraw`): where the vendored
// Excalidraw bundle is found, whether it is genuinely offline, what the AI
// prompt asks for, what a model reply is allowed to put on the canvas, and
// whether the destination is wired into the shell's tables.
//
// The canvas itself is not testable this way and this suite does not pretend
// otherwise - `WhiteboardViewSelfTest` covers the parts that need a real
// `WKWebView` and window, and the drawing experience is verified by running the
// app. What *is* covered here is everything that can silently rot: an asset
// path that stops resolving, a CDN reference creeping back into the page, a
// parse that accepts something the canvas will choke on.
//
// `FM_RUN_WHITEBOARD_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum WhiteboardSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }

        checkAssets(check)
        checkOfflineByConstruction(check)
        checkPrompt(check)
        checkParsing(check)
        checkGeneration(check)
        checkDestinationWiring(check)

        print(ok ? "WhiteboardSelfTest: OK" : "WhiteboardSelfTest: FAILURES")
        return ok
    }

    // MARK: Assets

    private static func checkAssets(_ check: (Bool, String) -> Void) {
        guard let dir = WhiteboardAssets.webDirectory() else {
            check(false, "no Excalidraw bundle found - run native/Scripts/build-excalidraw-web.sh")
            return
        }
        check(WhiteboardAssets.isAvailable, "isAvailable should agree with webDirectory()")

        let fm = FileManager.default
        for name in ["index.html", "whiteboard.js", "whiteboard.css"] {
            check(fm.isReadableFile(atPath: dir.appendingPathComponent(name).path),
                  "the bundle is missing \(name)")
        }
        // The lazily-fetched woff2 subsets resolve against
        // `window.EXCALIDRAW_ASSET_PATH` (= "./"), so `fonts/` has to be a
        // sibling of the bundle - a build that stopped copying it would render
        // every board in a fallback face with nothing failing loudly.
        var isDir: ObjCBool = false
        let fonts = dir.appendingPathComponent("fonts").path
        check(fm.fileExists(atPath: fonts, isDirectory: &isDir) && isDir.boolValue,
              "the bundle is missing its fonts/ directory")
        check((try? fm.contentsOfDirectory(atPath: fonts).contains("Excalifont")) == true,
              "fonts/Excalifont is missing - the default hand-drawn face")

        // A bundle that built but produced a stub would resolve every path
        // above and still show an empty canvas.
        let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("whiteboard.js").path)[.size]) as? Int ?? 0
        check(size > 1_000_000, "whiteboard.js is only \(size) bytes - that is not a real Excalidraw build")

        // The override is what a self-test or a freshly rebuilt bundle uses;
        // it is checked after `Bundle.main.resourceURL` and before the source
        // tree, so pointing it somewhere real must win over the walk-up.
        // Restored afterwards rather than just cleared: a caller may have set
        // it deliberately (pointing the whole run at a modified copy of the
        // bundle is how a regression gets injected into the offline checks
        // below), and a test that silently unsets a caller's environment
        // would make that impossible.
        let priorOverride = ProcessInfo.processInfo.environment["FM_WHITEBOARD_WEB_DIR"]
        let scratch = fm.temporaryDirectory.appendingPathComponent("whiteboard-assets-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: scratch)
            if let priorOverride { setenv("FM_WHITEBOARD_WEB_DIR", priorOverride, 1) } else { unsetenv("FM_WHITEBOARD_WEB_DIR") }
        }
        try? "<html></html>".write(to: scratch.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        setenv("FM_WHITEBOARD_WEB_DIR", scratch.path, 1)
        let overridden = WhiteboardAssets.webDirectory()?.standardizedFileURL
        unsetenv("FM_WHITEBOARD_WEB_DIR")
        check(overridden == scratch.standardizedFileURL,
              "FM_WHITEBOARD_WEB_DIR should win over the source-tree walk-up, got \(String(describing: overridden?.path))")
        // With the override cleared, the walk-up has to find the committed
        // bundle - the dev flow's only path to it.
        check(WhiteboardAssets.webDirectory() != nil,
              "clearing the override should still resolve the vendored bundle from the source tree")
    }

    /// The offline guarantee, checked in the bytes rather than trusted.
    ///
    /// This app is offline-first by posture, and a whiteboard that could fetch
    /// a script or a font from a CDN would be a real regression from it - so
    /// the page's own CSP is the mechanism, and this is what stops a future
    /// edit from quietly loosening it or reintroducing a remote `<script>`.
    private static func checkOfflineByConstruction(_ check: (Bool, String) -> Void) {
        guard let dir = WhiteboardAssets.webDirectory(),
              let html = try? String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8) else {
            check(false, "could not read the bundle's index.html")
            return
        }
        // The policy itself, not the file - the page's own comments discuss
        // directives by name, and a substring search over the whole document
        // would happily read one of those as the policy.
        guard let policy = cspPolicy(in: html) else {
            check(false, "index.html has no Content-Security-Policy meta tag")
            return
        }
        check(policy.contains("default-src 'self'"), "the CSP should default to 'self' only")
        check(policy.contains("connect-src 'self'"),
              "the CSP must pin connect-src to 'self' - that is what makes the library's own CDN font fallback unreachable")
        check(!policy.contains("frame-src"),
              "frame-src should be absent so it falls back to default-src, keeping embeddable links from loading")
        check(policy.contains("object-src 'none'"), "the CSP should forbid plugins outright")
        // A directive that allowed a remote origin would defeat all of the
        // above, whichever directive it was.
        check(!policy.contains("http://") && !policy.contains("https://") && !policy.contains("*"),
              "the CSP names a remote origin: \(policy)")
        // Any absolute http(s) URL in the page shell is a remote fetch by
        // definition. (The bundle's *script* text legitimately contains
        // excalidraw.com links - they are help-dialog anchors the app opens in
        // the system browser, not loads.)
        // Any absolute URL in a real tag is a remote fetch by definition. The
        // page's own explanatory comments are stripped first, since they
        // legitimately talk about CDNs to explain why there is no CDN.
        let markup = html.replacingOccurrences(of: "<!--[^>]*(?:(?!-->)[\\s\\S])*?-->",
                                               with: "", options: .regularExpression)
        check(!markup.contains("http://") && !markup.contains("https://"),
              "index.html references an absolute URL - the page shell must be entirely local")
    }

    /// The `content="…"` of the page's CSP meta tag.
    private static func cspPolicy(in html: String) -> String? {
        guard let tagStart = html.range(of: "Content-Security-Policy") else { return nil }
        let rest = html[tagStart.upperBound...]
        guard let contentKey = rest.range(of: "content=\"") else { return nil }
        let afterQuote = rest[contentKey.upperBound...]
        guard let closing = afterQuote.range(of: "\"") else { return nil }
        return String(afterQuote[..<closing.lowerBound])
    }

    // MARK: Prompt

    private static func checkPrompt(_ check: (Bool, String) -> Void) {
        let description = "a load balancer in front of two app servers and one database"
        let prompt = WhiteboardDiagram.prompt(for: description)
        check(prompt.contains(description), "the prompt should embed the description verbatim")
        check(prompt.contains("ONLY a JSON array"), "the prompt should ask for only a JSON array")
        check(prompt.lowercased().contains("code fence"), "the prompt should rule out a markdown fence")
        // The whole reason this asks for the *skeleton* format: a model must
        // not be inventing ids, seeds or version nonces.
        check(prompt.contains("skeleton"), "the prompt should name the element skeleton format")
        check(prompt.contains("do not invent those"), "the prompt should tell the model not to invent derived fields")
        check(prompt.contains("\(WhiteboardDiagram.maxElements) elements"),
              "the prompt should state the element cap it is going to be held to")
        for type in ["rectangle", "diamond", "ellipse", "arrow", "line", "text", "frame"] {
            check(prompt.contains(type), "the prompt should list \(type) as an allowed type")
        }
        check(prompt.contains("\"start\""), "the prompt should show how to bind an arrow to two shapes")
    }

    // MARK: Parsing

    private static func checkParsing(_ check: (Bool, String) -> Void) {
        func parse(_ text: String) -> Result<[[String: Any]], WhiteboardDiagramError> {
            WhiteboardDiagram.parse(text)
        }
        func succeeded(_ result: Result<[[String: Any]], WhiteboardDiagramError>) -> [[String: Any]]? {
            if case .success(let elements) = result { return elements }
            return nil
        }
        func failureMessage(_ result: Result<[[String: Any]], WhiteboardDiagramError>) -> String? {
            if case .failure(let error) = result { return error.message }
            return nil
        }

        let good = """
        [{"type":"rectangle","x":0,"y":0,"width":180,"height":80,"id":"lb","label":{"text":"LB"}},
         {"type":"rectangle","x":300,"y":0,"width":180,"height":80,"id":"app"},
         {"type":"arrow","x":190,"y":40,"width":100,"height":0,"start":{"id":"lb"},"end":{"id":"app"}}]
        """
        check(succeeded(parse(good))?.count == 3, "a well-formed skeleton array should parse to 3 elements")

        // Every field the model sent has to survive: the page hands them
        // straight to `convertToExcalidrawElements`, so a parse that dropped
        // `label` or `start` would silently lose the diagram's meaning.
        if let elements = succeeded(parse(good)) {
            check(elements[0]["label"] != nil, "an element's label must survive parsing")
            check(elements[2]["start"] != nil, "an arrow's binding must survive parsing")
        }

        let wrapped = "{\"elements\": [{\"type\":\"ellipse\",\"x\":0,\"y\":0,\"width\":40,\"height\":40}]}"
        check(succeeded(parse(wrapped))?.count == 1,
              "an array wrapped in a scene-shaped object should be accepted, not refused on a technicality")

        let fenced = "```json\n[{\"type\":\"text\",\"x\":0,\"y\":0,\"text\":\"hi\"}]\n```"
        check(succeeded(parse(fenced))?.count == 1, "a fenced reply should have its fence stripped")

        check(failureMessage(parse("Sure! Here's a diagram of your system.")) != nil,
              "a prose reply must fail rather than half-load")
        check(failureMessage(parse("[]")) != nil, "an empty array must fail")
        check(failureMessage(parse("{\"note\":\"none\"}")) != nil, "a JSON object with no elements must fail")
        check(failureMessage(parse("[{\"x\":0,\"y\":0}]")) != nil, "an element with no type must fail")
        check(failureMessage(parse("[\"rectangle\"]")) != nil, "a non-object element must fail")

        // The narrowed type list is a real decision, not tidiness: `image`
        // needs a fileId that only exists for a file already in the scene, and
        // `embeddable`/`iframe` exist to load a remote URL the page's CSP
        // blocks - so accepting either would only produce a broken box.
        for refused in ["embeddable", "iframe", "image", "selection"] {
            let message = failureMessage(parse("[{\"type\":\"\(refused)\",\"x\":0,\"y\":0}]"))
            check(message != nil, "a \(refused) element must be refused")
            check(message?.contains(refused) == true,
                  "the refusal should name the type it refused, got \(String(describing: message))")
        }

        let tooMany = (0..<(WhiteboardDiagram.maxElements + 1))
            .map { "{\"type\":\"rectangle\",\"x\":\($0),\"y\":0,\"width\":10,\"height\":10}" }
            .joined(separator: ",")
        check(failureMessage(parse("[\(tooMany)]")) != nil,
              "more than maxElements must be refused rather than handed to the canvas")

        let justEnough = (0..<WhiteboardDiagram.maxElements)
            .map { "{\"type\":\"rectangle\",\"x\":\($0),\"y\":0,\"width\":10,\"height\":10}" }
            .joined(separator: ",")
        check(succeeded(parse("[\(justEnough)]"))?.count == WhiteboardDiagram.maxElements,
              "exactly maxElements must be accepted - the cap is a ceiling, not an off-by-one")
    }

    // MARK: Generation (real Process/parse path, fake `claude`)

    private static func checkGeneration(_ check: (Bool, String) -> Void) {
        defer { WhiteboardDiagram.claudePathOverrideForTests = nil }

        do {
            let script = writeFakeClaude(result: "[{\"type\":\"rectangle\",\"x\":0,\"y\":0,\"width\":100,\"height\":50}]",
                                         isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            WhiteboardDiagram.claudePathOverrideForTests = script.path
            let outcome = generateSync(description: "one box")
            check(outcome.elements?.count == 1, "a well-formed reply should produce one element, got \(outcome)")
        }

        do {
            let script = writeFakeClaude(result: "I can't draw that.", isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            WhiteboardDiagram.claudePathOverrideForTests = script.path
            check(generateSync(description: "something").elements == nil,
                  "a prose reply must surface as a failure the captain can retry from")
        }

        do {
            let script = writeFakeClaude(result: "not authenticated", isError: true)
            defer { try? FileManager.default.removeItem(at: script) }
            WhiteboardDiagram.claudePathOverrideForTests = script.path
            check(generateSync(description: "something").elements == nil, "is_error:true must fail")
        }

        do {
            let script = writeFakeClaude(rawOutput: "garbage\n", exitCode: 1)
            defer { try? FileManager.default.removeItem(at: script) }
            WhiteboardDiagram.claudePathOverrideForTests = script.path
            check(generateSync(description: "something").elements == nil, "garbled output must fail")
        }

        WhiteboardDiagram.claudePathOverrideForTests = "/nonexistent/claude-\(UUID().uuidString)"
        check(generateSync(description: "something").elements == nil, "a missing claude must fail cleanly")

        WhiteboardDiagram.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
        check(generateSync(description: "   ").elements == nil, "an empty description must fail without spawning anything")
    }

    // MARK: Wiring

    /// The destination has to be reachable and it has to be *lazy*: the whole
    /// battery argument for embedding a web view rests on a session that never
    /// opens the Whiteboard never starting a web content process.
    private static func checkDestinationWiring(_ check: (Bool, String) -> Void) {
        check(RailDestination.whiteboard.slot == .whiteboard, "the whiteboard destination should own its own slot")
        check(RailDestination.allCases.filter { $0.slot == .whiteboard }.count == 1,
              "exactly one destination should map to the whiteboard slot")
        check(!RailDestination.whiteboard.title.isEmpty, "the destination needs a title")
        check(!RailDestination.whiteboard.drillSubtitle.isEmpty, "the destination needs a drill subtitle")
        check(!RailDestination.whiteboard.isDailyUse, "the whiteboard is a utility, like Tools")
        check(RailDestination.whiteboard.domainHue == .violet,
              "the whiteboard should carry this app's own AI hue")
        // `NSImage(systemSymbolName:)` returns nil silently, and this app has
        // shipped an invisible icon exactly that way before.
        check(NSImage(systemSymbolName: RailDestination.whiteboard.symbol, accessibilityDescription: nil) != nil,
              "the destination's symbol \(RailDestination.whiteboard.symbol) does not resolve")
        check(NSImage(systemSymbolName: DaylightModule.whiteboard.symbol, accessibilityDescription: nil) != nil,
              "the module's symbol does not resolve")

        check(DaylightModule.whiteboard.opens == .whiteboard, "the module should open the whiteboard destination")
        check(DaylightModule.whiteboard.space == .stores, "the whiteboard module belongs to Stores")
        check(!DaylightModule.whiteboard.appearsOnOverview,
              "the whiteboard should not add an eighteenth card back onto the trimmed Overview canvas")
        check(DaylightModule.whiteboard.isVisible(in: .stores), "it must render on its own space")
        check(!DaylightModule.whiteboard.isVisible(in: .overview), "it must not render on Overview")
        check(DaylightModule.whiteboard.gridSpan == 1, "only the briefing is a wide card")
        check(DaylightModule.space(forDestination: .whiteboard) == .stores,
              "the destination-to-space derivation should find it")

        // The registry itself, driven the way `DestinationMountingSelfTest`
        // does: registered, not mounted until shown.
        var mounted: [String] = []
        let mounter = DestinationMounter { vc in mounted.append(String(describing: type(of: vc))) }
        let controller = WhiteboardController()
        mounter.register(DestinationSlot(id: .whiteboard, title: RailDestination.whiteboard.bodyTitle,
                                         mountsEagerly: false, controller: controller))
        mounter.mountEagerSlots()
        check(mounted.isEmpty, "the whiteboard must not mount eagerly - that is the whole lazy-web-view argument")
        check(mounter.slot(for: .whiteboard)?.isMounted == false, "it should still be unmounted after the eager pass")
    }

    // MARK: Helpers

    private static func writeFakeClaude(result: String, isError: Bool) -> URL {
        let obj: [String: Any] = ["result": result, "is_error": isError]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return writeFakeClaude(rawOutput: json + "\n", exitCode: 0)
    }

    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-whiteboard-\(UUID().uuidString).sh")
        let escaped = rawOutput.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private struct GenerateOutcome: CustomStringConvertible {
        let elements: [[String: Any]]?
        let message: String?
        var description: String {
            elements.map { "success(\($0.count) elements)" } ?? "failure(\(message ?? "?"))"
        }
    }

    /// Pumps the main run loop rather than blocking on a semaphore, for the
    /// reason every sibling suite records: the completion is dispatched to the
    /// main queue and this runs before `NSApplication.run()`, so a semaphore
    /// would deadlock against the block it is waiting for.
    private static func generateSync(description: String) -> GenerateOutcome {
        var outcome: GenerateOutcome?
        WhiteboardDiagram.generate(description: description) { result in
            switch result {
            case .success(let elements): outcome = GenerateOutcome(elements: elements, message: nil)
            case .failure(let error): outcome = GenerateOutcome(elements: nil, message: error.message)
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return outcome ?? GenerateOutcome(elements: nil, message: "timed out")
    }
}

#endif
