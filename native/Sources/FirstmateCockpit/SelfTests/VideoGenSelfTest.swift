// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the Video Stores destination
// (fm/grandline-videogen-feasibility-scout) - `VideoGenEnvironment`'s pure
// path/state logic, `VideoGenEngine`'s filename slugging and the
// generate/subprocess contract (against a real, disposable fake `ltx-2-mlx`
// script via `VideoGenEngine.executableOverrideForTests`/
// `readyOverrideForTests` - never the real ~19GB venv binary or a real
// generation), and `VideoPromptEnhancer` (against a real, disposable fake
// `claude` script, same convention as `DictationCleanupSelfTest.swift`).
// `FM_RUN_VIDEOGEN_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only - see `DictationCleanupSelfTest
// .swift`'s header for the full reasoning. Do not remove this guard.
#if FM_SELFTESTS

import Foundation

enum VideoGenSelfTest {
    static func run() -> Bool {
        var ok = true
        defer {
            VideoGenEngine.executableOverrideForTests = nil
            VideoGenEngine.readyOverrideForTests = nil
            VideoPromptEnhancer.claudePathOverrideForTests = nil
        }

        testEnvironmentState(&ok)
        testOutputDirOverride(&ok)
        testSetupScriptResolution(&ok)
        testFilenameSlugging(&ok)
        testGenerateGuards(&ok)
        testGenerateSuccessAndFailure(&ok)
        testPromptEnhancer(&ok)

        return ok
    }

    // MARK: VideoGenEnvironment.currentState()

    private static func testEnvironmentState(_ ok: inout Bool) {
        let scratchDir = makeScratchDir("videogen-env")
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        withEnv(["FM_VIDEOGEN_DIR": scratchDir.path]) {
            check(VideoGenEnvironment.currentState() == .notSetUp,
                  "an empty directory should report notSetUp", &ok)

            // A venv binary with none of the model files present.
            let venvBin = scratchDir.appendingPathComponent("venv/bin")
            try? FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
            let ltxPath = venvBin.appendingPathComponent("ltx-2-mlx")
            try? "#!/bin/sh\nexit 0\n".write(to: ltxPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ltxPath.path)
            check(VideoGenEnvironment.currentState() == .notSetUp,
                  "a venv with no model files should still report notSetUp", &ok)

            // All required files present at a plausible size.
            let modelDir = VideoGenEnvironment.modelDir()
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            for file in VideoGenEnvironment.requiredModelFiles {
                writeFile(at: modelDir.appendingPathComponent(file.name), sizeAtLeast: file.minimumSize)
            }
            check(VideoGenEnvironment.currentState() == .ready,
                  "every required file present at a plausible size should report ready", &ok)

            // Truncate one file below its floor (simulating an interrupted
            // download) - should no longer read as ready.
            let truncated = modelDir.appendingPathComponent("transformer-distilled.safetensors")
            try? Data([0x01, 0x02]).write(to: truncated)
            check(VideoGenEnvironment.currentState() == .notSetUp,
                  "a truncated file below its size floor should not read as ready", &ok)
        }
    }

    // MARK: outputDir()

    private static func testOutputDirOverride(_ ok: inout Bool) {
        let scratchDir = makeScratchDir("videogen-output")
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        withEnv(["FM_VIDEOGEN_OUTPUT_DIR": scratchDir.path]) {
            // Compare `.path` strings, not `URL` equality directly - two
            // `URL`s built via different constructors (`temporaryDirectory`
            // vs. `URL(fileURLWithPath:)`) can carry different internal
            // `isDirectory`/relative-path representations for the identical
            // real path, which makes `==` unreliable here even though both
            // resolve to the same file on disk.
            check(VideoGenEnvironment.outputDir().path == scratchDir.path,
                  "FM_VIDEOGEN_OUTPUT_DIR should override the default ~/Movies/Grand Line location", &ok)
        }
    }

    // MARK: resolveSetupScript()

    private static func testSetupScriptResolution(_ ok: inout Bool) {
        let scratchDir = makeScratchDir("videogen-script")
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scriptPath = scratchDir.appendingPathComponent("videogen-setup.sh")
        try? "#!/bin/bash\necho hi\n".write(to: scriptPath, atomically: true, encoding: .utf8)
        withEnv(["FM_VIDEOGEN_SETUP_SCRIPT": scriptPath.path]) {
            check(VideoGenEnvironment.resolveSetupScript() == scriptPath.path,
                  "FM_VIDEOGEN_SETUP_SCRIPT should be honoured when readable", &ok)
            check(VideoGenEnvironment.setupCommand() == "bash \"\(scriptPath.path)\"",
                  "setupCommand() should wrap the resolved script path in a bash invocation", &ok)
        }
    }

    // MARK: VideoGenEngine.filename(for:)

    private static func testFilenameSlugging(_ ok: inout Bool) {
        let name = VideoGenEngine.filename(for: "A Calm Ocean at Sunset!")
        check(name.hasPrefix("a-calm-ocean-at-sunset-"), "the slug should lowercase and hyphenate the prompt, got \(name)", &ok)
        check(name.hasSuffix(".mp4"), "the filename should end in .mp4, got \(name)", &ok)
        check(!name.contains("--"), "consecutive non-alphanumeric characters should collapse to one hyphen, got \(name)", &ok)

        let empty = VideoGenEngine.filename(for: "!!!")
        check(empty.hasPrefix("clip-"), "a prompt with no alphanumeric characters should fall back to a generic 'clip' name, got \(empty)", &ok)
    }

    // MARK: VideoGenEngine.generate - guard clauses (no process spawned)

    private static func testGenerateGuards(_ ok: inout Bool) {
        VideoGenEngine.executableOverrideForTests = "/nonexistent/should-not-be-invoked-\(UUID().uuidString)"

        VideoGenEngine.readyOverrideForTests = true
        let emptyOutcome = runGenerateSync(prompt: "   ")
        check(emptyOutcome.isFailure, "an empty/whitespace-only prompt should fail without spawning a process", &ok)

        VideoGenEngine.readyOverrideForTests = false
        let notReadyOutcome = runGenerateSync(prompt: "a calm ocean at sunset")
        check(notReadyOutcome.isFailure, "generate() should refuse when the model isn't set up, without spawning a process", &ok)
    }

    // MARK: VideoGenEngine.generate - real Subprocess path, fake executable

    private static func testGenerateSuccessAndFailure(_ ok: inout Bool) {
        let outputScratch = makeScratchDir("videogen-output-real")
        defer { try? FileManager.default.removeItem(at: outputScratch) }

        withEnv(["FM_VIDEOGEN_OUTPUT_DIR": outputScratch.path]) {
            VideoGenEngine.readyOverrideForTests = true

            // A fake `ltx-2-mlx` that creates the file it was told to write
            // (`-o <path>`, mirroring how the real tool's own exit code and
            // the presence of the output file are both checked) and exits 0.
            let successScript = writeFakeLtx(touchesOutputFile: true, exitCode: 0)
            defer { try? FileManager.default.removeItem(at: successScript) }
            VideoGenEngine.executableOverrideForTests = successScript.path
            let successOutcome = runGenerateSync(prompt: "a calm ocean at sunset")
            switch successOutcome {
            case .success(let result):
                check(FileManager.default.fileExists(atPath: result.outputPath.path),
                      "a successful run's reported output path should actually exist on disk", &ok)
            case .failure:
                check(false, "a fake ltx-2-mlx exiting 0 and creating its output file should be reported as success", &ok)
            }

            // A fake tool that exits non-zero (and does not create its
            // output file) - reported as a failure, not a crash.
            //
            // Each scenario below uses its own distinct prompt text
            // deliberately, not a shared one: `filename(for:)` derives its
            // name from a slug of the prompt plus a *second*-granularity
            // timestamp, so three fast, sequential calls sharing one prompt
            // can collide on the exact same filename within the same wall-
            // clock second - and a stale file a prior scenario's script
            // actually touched would then satisfy a *later* scenario's own
            // file-existence check even though that scenario's own script
            // never touched anything. Confirmed live: this is exactly what
            // made the "lying" case below intermittently pass for the wrong
            // reason before this fix. Distinct prompts make the three
            // scenarios' output paths structurally incapable of colliding.
            let failureScript = writeFakeLtx(touchesOutputFile: false, exitCode: 1)
            defer { try? FileManager.default.removeItem(at: failureScript) }
            VideoGenEngine.executableOverrideForTests = failureScript.path
            let failureOutcome = runGenerateSync(prompt: "a rainy city street at night")
            check(failureOutcome.isFailure, "a fake ltx-2-mlx exiting non-zero should be reported as a failure", &ok)

            // A fake tool that exits 0 but never actually wrote the output
            // file - still a failure (GL-14's "no confident success without
            // real evidence" rule applied here: an exit code alone is not
            // proof a video actually landed on disk).
            let lyingScript = writeFakeLtx(touchesOutputFile: false, exitCode: 0)
            defer { try? FileManager.default.removeItem(at: lyingScript) }
            VideoGenEngine.executableOverrideForTests = lyingScript.path
            let lyingOutcome = runGenerateSync(prompt: "a mountain covered in snow at dawn")
            check(lyingOutcome.isFailure, "exit 0 with no actual output file should still be reported as a failure", &ok)
        }
    }

    // MARK: VideoPromptEnhancer - same shape as DictationCleanupSelfTest

    private static func testPromptEnhancer(_ ok: inout Bool) {
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "A cinematic wide shot of a calm ocean at sunset, gentle waves, warm light.", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            VideoPromptEnhancer.claudePathOverrideForTests = script.path
            let outcome = runEnhanceSync("ocean at sunset")
            check(outcome == .success("A cinematic wide shot of a calm ocean at sunset, gentle waves, warm light."),
                  "a well-formed success response should parse cleanly, got \(outcome)", &ok)
        }

        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "\"Quoted cinematic prompt.\"", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            VideoPromptEnhancer.claudePathOverrideForTests = script.path
            let outcome = runEnhanceSync("a rough idea")
            check(outcome == .success("Quoted cinematic prompt."), "a quote-wrapped result should be unwrapped, got \(outcome)", &ok)
        }

        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "not authenticated", "is_error": true}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            VideoPromptEnhancer.claudePathOverrideForTests = script.path
            let outcome = runEnhanceSync("a rough idea")
            check(outcome.isFailure, "is_error:true should be reported as a failure, got \(outcome)", &ok)
        }

        do {
            VideoPromptEnhancer.claudePathOverrideForTests = "/nonexistent/path/to/claude-\(UUID().uuidString)"
            let outcome = runEnhanceSync("a rough idea")
            check(outcome.isFailure, "a nonexistent claude path should fail cleanly, got \(outcome)", &ok)
        }

        do {
            VideoPromptEnhancer.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let outcome = runEnhanceSync("   ")
            check(outcome.isFailure, "an empty idea should fail without spawning a process", &ok)
        }

        do {
            let idea = "a dog running on a beach"
            let prompt = VideoPromptEnhancer.prompt(for: idea)
            check(prompt.contains(idea), "the enhancement prompt should embed the exact idea text", &ok)
            check(prompt.lowercased().contains("only"), "the enhancement prompt should ask for the rewrite only, no extra commentary", &ok)
        }
    }

    // MARK: Fakes

    /// A fake `ltx-2-mlx`: parses `-o <path>` out of its own argv and, when
    /// asked, touches that path (mirroring the real tool actually producing
    /// an mp4 there) before exiting with the requested code.
    private static func writeFakeLtx(touchesOutputFile: Bool, exitCode: Int32) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-ltx-\(UUID().uuidString).sh")
        let touch = touchesOutputFile ? "touch \"$out\"" : ": # not touching the output file"
        let script = """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; fi
          shift
        done
        \(touch)
        exit \(exitCode)
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private static func writeFakeClaude(outputJSON: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-claude-videogen-\(UUID().uuidString).sh")
        let escaped = (outputJSON + "\n").replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\nexit 0\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    // MARK: Small helpers

    private enum Outcome<T: Equatable>: Equatable {
        case success(T)
        case failure
        var isFailure: Bool { if case .failure = self { return true }; return false }
    }

    private static func runGenerateSync(prompt: String) -> Outcome<VideoGenResult.Comparable> {
        final class Box { var outcome: Outcome<VideoGenResult.Comparable>? }
        let box = Box()
        VideoGenEngine.generate(prompt: prompt) { result in
            switch result {
            case .success(let r): box.outcome = .success(.init(outputPath: r.outputPath))
            case .failure: box.outcome = .failure
            }
        }
        return pump { box.outcome }
    }

    private static func runEnhanceSync(_ idea: String) -> Outcome<String> {
        final class Box { var outcome: Outcome<String>? }
        let box = Box()
        VideoPromptEnhancer.enhance(idea) { result in
            switch result {
            case .success(let text): box.outcome = .success(text)
            case .failure: box.outcome = .failure
            }
        }
        return pump { box.outcome }
    }

    /// Waits for an async completion by pumping the main run loop, not a
    /// semaphore - same reasoning and same technique as
    /// `DictationCleanupSelfTest.runRewriteSync`'s own doc comment (this
    /// suite runs before `NSApplication.run()`, and `Subprocess`/
    /// `ClaudeOneShot`'s completions are always dispatched via
    /// `DispatchQueue.main.async`).
    ///
    /// Reads through a reference-type `Box` (an escaping getter closure)
    /// rather than an `inout` parameter - an `inout` borrow held for the
    /// whole polling loop conflicts with the completion closure's own write
    /// to the same captured variable the moment it fires mid-loop, which
    /// Swift's exclusivity checker (correctly) treats as a fatal
    /// simultaneous-access violation rather than a data race it silently
    /// allows. A class instance has no such exclusivity constraint on reads
    /// of its stored property from two different closures.
    private static func pump<T>(until getResult: () -> Outcome<T>?) -> Outcome<T> {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let result = getResult() { return result }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return .failure
    }

    private static func makeScratchDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeFile(at url: URL, sizeAtLeast bytes: Int) {
        let size = max(bytes, 16)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
    }

    /// Sets the given environment variables for the duration of `body`, then
    /// restores whatever was there before - `ProcessInfo.environment` has no
    /// public setter, so this goes through `setenv`/`unsetenv` directly, the
    /// same primitive `withScratchEnv`-style helpers elsewhere in this suite
    /// use.
    private static func withEnv(_ values: [String: String], _ body: () -> Void) {
        var previous: [String: String?] = [:]
        for (key, value) in values {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        body()
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }
}

/// A trimmed, `Equatable` stand-in for `VideoGenResult` (which carries a
/// `TimeInterval` that would make exact equality comparisons in the tests
/// above flaky) - only the output path is compared.
extension VideoGenResult {
    struct Comparable: Equatable {
        let outputPath: URL
    }
}

#endif
