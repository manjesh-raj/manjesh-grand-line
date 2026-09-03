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
//
// `fm/grandline-videogen-settings-fix` extended this suite with the new
// settings work: `testFrameCountAndEstimates` (the pure duration-to-frame-
// count grid math and the wall-clock estimate/timeout derivation, no
// subprocess involved), `testOptionToArgumentMapping` (every duration/
// resolution/clarity/reference-type combination's real, captured CLI argv -
// via a fake `ltx-2-mlx` that writes its own `$@` to a side file rather than
// just touching `-o`, so the test can assert on the exact flags this app
// sent, not just that *something* ran), `testFeedbackRevision` (the
// feedback-driven regeneration loop's `VideoPromptEnhancer
// .reviseForFeedback`, same fake-`claude` convention as `testPromptEnhancer`),
// and `testVersionHistoryAndRestore` (a real `VideoGenController`, driven
// through its `#if FM_SELFTESTS` debug hooks, confirming "Restore this
// version" never spawns a real generation).

// GL-27: compiled into debug builds only - see `DictationCleanupSelfTest
// .swift`'s header for the full reasoning. Do not remove this guard.
#if FM_SELFTESTS

import AppKit
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
        testFrameCountAndEstimates(&ok)
        testOptionToArgumentMapping(&ok)
        testFeedbackRevision(&ok)
        testVersionHistoryAndRestore(&ok)

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

    // MARK: VideoGenEngine.frameCount / estimatedSeconds / timeout - pure logic, no subprocess

    private static func testFrameCountAndEstimates(_ ok: inout Bool) {
        check(VideoGenEngine.frameCount(forSeconds: 4, frameRate: 24) == 97,
              "4s @ 24fps should snap to 97 frames - the scout report's own validated case", &ok)
        check(VideoGenEngine.frameCount(forSeconds: 8, frameRate: 24) == 193,
              "8s @ 24fps should snap to the nearest 8k+1 grid point (193/24=8.04s)", &ok)
        for seconds in VideoGenController.durationRangeForTests {
            let frames = VideoGenEngine.frameCount(forSeconds: Double(seconds), frameRate: 24)
            check((frames - 1) % 8 == 0,
                  "every offered duration (\(seconds)s) should produce a frame count on the VAE's 8k+1 temporal grid, got \(frames)", &ok)
            check(frames >= 1, "frame count should never be zero or negative, got \(frames) for \(seconds)s", &ok)
        }

        let baseline = VideoGenEngine.estimatedSeconds(forFrameCount: 97, width: 704, height: 448, clarity: .standard)
        check(abs(baseline - 85.8) < 0.01,
              "the exact validated combination (97 frames, 704x448, standard) should reproduce the scout report's own 85.8s number, got \(baseline)", &ok)

        let draft = VideoGenEngine.estimatedSeconds(forFrameCount: 97, width: 704, height: 448, clarity: .draft)
        check(draft < baseline, "draft clarity's fewer denoising steps should estimate faster than standard, got \(draft) vs \(baseline)", &ok)

        let high = VideoGenEngine.estimatedSeconds(forFrameCount: 97, width: 704, height: 448, clarity: .high)
        check(high > baseline, "high clarity's CFG-guided two-stage pipeline should estimate slower than standard, got \(high) vs \(baseline)", &ok)

        let small = VideoGenEngine.estimatedSeconds(forFrameCount: 97, width: 512, height: 320, clarity: .standard)
        check(small < baseline, "a smaller resolution should estimate faster than the validated baseline, got \(small) vs \(baseline)", &ok)

        let large = VideoGenEngine.estimatedSeconds(forFrameCount: 97, width: 896, height: 576, clarity: .standard)
        check(large > baseline, "a larger resolution should estimate slower than the validated baseline, got \(large) vs \(baseline)", &ok)

        let doubleDuration = VideoGenEngine.estimatedSeconds(forFrameCount: 194, width: 704, height: 448, clarity: .standard)
        check(abs(doubleDuration - baseline * 2) < 0.1,
              "doubling the frame count should roughly double the estimate (linear scaling), got \(doubleDuration) vs \(baseline * 2)", &ok)

        let floorTimeout = VideoGenEngine.timeout(forFrameCount: 41, width: 512, height: 320, clarity: .draft)
        check(floorTimeout >= 360, "the timeout should never drop below the original validated floor even for a cheap combination, got \(floorTimeout)", &ok)

        let standardTimeout = VideoGenEngine.timeout(forFrameCount: 97, width: 704, height: 448, clarity: .standard)
        let bigTimeout = VideoGenEngine.timeout(forFrameCount: 97 * 3, width: 896, height: 576, clarity: .high)
        check(bigTimeout > standardTimeout,
              "a slower/larger/longer combination should get a proportionally larger timeout bound, got \(bigTimeout) vs \(standardTimeout)", &ok)
    }

    // MARK: Every duration/resolution/clarity/reference-type combination -> real CLI argv

    private static func testOptionToArgumentMapping(_ ok: inout Bool) {
        let outputScratch = makeScratchDir("videogen-argv-output")
        defer { try? FileManager.default.removeItem(at: outputScratch) }
        let captureDir = makeScratchDir("videogen-argv-capture")
        defer { try? FileManager.default.removeItem(at: captureDir) }

        withEnv(["FM_VIDEOGEN_OUTPUT_DIR": outputScratch.path]) {
            VideoGenEngine.readyOverrideForTests = true

            func capturedArgv(_ label: String, prompt: String, durationSeconds: Double,
                              resolution: VideoGenResolutionPreset, clarity: VideoGenClarity,
                              reference: VideoGenReferenceType) -> [String] {
                let captureURL = captureDir.appendingPathComponent("\(label)-\(UUID().uuidString).txt")
                let script = writeFakeLtxCapturingArgv(to: captureURL)
                defer { try? FileManager.default.removeItem(at: script) }
                VideoGenEngine.executableOverrideForTests = script.path
                _ = runGenerateSyncFull(prompt: prompt, durationSeconds: durationSeconds,
                                        resolution: resolution, clarity: clarity, reference: reference)
                return (try? String(contentsOf: captureURL, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
            }

            // Duration -> frame count, at a fixed 24fps.
            let durationArgv = capturedArgv("duration", prompt: "duration test", durationSeconds: 4,
                                            resolution: .standard, clarity: .standard, reference: .text)
            check(argvContainsPair(durationArgv, flag: "-f", value: "97"),
                  "requesting 4s should pass -f 97 (the validated case), got \(durationArgv)", &ok)
            check(argvContainsPair(durationArgv, flag: "--frame-rate", value: "24"),
                  "frame rate should stay fixed at 24 regardless of duration, got \(durationArgv)", &ok)

            let longerDurationArgv = capturedArgv("duration-8s", prompt: "duration test 2", durationSeconds: 8,
                                                  resolution: .standard, clarity: .standard, reference: .text)
            check(argvContainsPair(longerDurationArgv, flag: "-f", value: "193"),
                  "requesting 8s should pass -f 193 (nearest 8k+1 grid point), got \(longerDurationArgv)", &ok)

            // Resolution presets -> --height/--width, every preset an exact
            // multiple of 64 (see VideoGenEngine.swift's header on why).
            for preset in VideoGenResolutionPreset.allCases {
                let argv = capturedArgv("resolution-\(preset.rawValue)", prompt: "resolution test \(preset.rawValue)",
                                        durationSeconds: 5, resolution: preset, clarity: .standard, reference: .text)
                check(argvContainsPair(argv, flag: "--width", value: String(preset.width)),
                      "\(preset.rawValue) preset should pass width \(preset.width), got \(argv)", &ok)
                check(argvContainsPair(argv, flag: "--height", value: String(preset.height)),
                      "\(preset.rawValue) preset should pass height \(preset.height), got \(argv)", &ok)
                check(preset.width % 64 == 0 && preset.height % 64 == 0,
                      "\(preset.rawValue) preset's dims should be exact multiples of 64 (never silently floor-snapped by the tool), got \(preset.width)x\(preset.height)", &ok)
            }

            // Clarity -> the real, mutually exclusive pipeline-mode flags.
            let draftArgv = capturedArgv("clarity-draft", prompt: "clarity test draft", durationSeconds: 5,
                                         resolution: .standard, clarity: .draft, reference: .text)
            check(draftArgv.contains("--distilled"),
                  "draft clarity should still use the validated --distilled pipeline, got \(draftArgv)", &ok)
            check(argvContainsPair(draftArgv, flag: "--stage1-steps", value: "4"),
                  "draft clarity should reduce stage1 steps, got \(draftArgv)", &ok)
            check(argvContainsPair(draftArgv, flag: "--stage2-steps", value: "2"),
                  "draft clarity should reduce stage2 steps, got \(draftArgv)", &ok)

            let standardArgv = capturedArgv("clarity-standard", prompt: "clarity test standard", durationSeconds: 5,
                                            resolution: .standard, clarity: .standard, reference: .text)
            check(standardArgv.contains("--distilled"), "standard clarity should use --distilled, got \(standardArgv)", &ok)
            check(!standardArgv.contains("--stage1-steps"),
                  "standard clarity should use --distilled's own defaults, not an override, got \(standardArgv)", &ok)

            let highArgv = capturedArgv("clarity-high", prompt: "clarity test high", durationSeconds: 5,
                                        resolution: .standard, clarity: .high, reference: .text)
            check(highArgv.contains("--two-stages-hq"), "high clarity should use --two-stages-hq, got \(highArgv)", &ok)
            check(!highArgv.contains("--distilled"), "high clarity should not also pass --distilled, got \(highArgv)", &ok)

            // Reference type -> --image (or its real absence for text-only).
            let textArgv = capturedArgv("reference-text", prompt: "text reference test", durationSeconds: 5,
                                        resolution: .standard, clarity: .standard, reference: .text)
            check(!textArgv.contains("--image"), "a text reference should never pass --image, got \(textArgv)", &ok)

            let imageFile = outputScratch.appendingPathComponent("ref-image.png")
            FileManager.default.createFile(atPath: imageFile.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
            let imageArgv = capturedArgv("reference-image", prompt: "image reference test", durationSeconds: 5,
                                         resolution: .standard, clarity: .standard, reference: .image(path: imageFile.path))
            check(argvContainsPair(imageArgv, flag: "--image", value: imageFile.path),
                  "an image reference should pass --image <path>, got \(imageArgv)", &ok)

            // A reference image that doesn't exist on disk fails before
            // spawning anything - never silently falls back to text-only.
            VideoGenEngine.executableOverrideForTests = "/nonexistent/should-not-be-invoked-\(UUID().uuidString)"
            let missingImageOutcome = runGenerateSyncFull(
                prompt: "missing image", durationSeconds: 5, resolution: .standard, clarity: .standard,
                reference: .image(path: "/nonexistent/ref-\(UUID().uuidString).png"))
            check(missingImageOutcome.isFailure,
                  "a reference image that doesn't exist on disk should fail without spawning a process", &ok)
        }
    }

    // MARK: VideoPromptEnhancer.reviseForFeedback - the feedback-driven regeneration loop

    private static func testFeedbackRevision(_ ok: inout Bool) {
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "A calm ocean at sunset with choppy, wind-driven waves.", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            VideoPromptEnhancer.claudePathOverrideForTests = script.path
            let outcome = runReviseSync(currentPrompt: "A calm ocean at sunset.", feedback: "the water is too still, make it choppier")
            check(outcome == .success("A calm ocean at sunset with choppy, wind-driven waves."),
                  "a well-formed revision should parse cleanly, got \(outcome)", &ok)
        }

        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "\"Quoted revised prompt.\"", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            VideoPromptEnhancer.claudePathOverrideForTests = script.path
            let outcome = runReviseSync(currentPrompt: "A calm ocean at sunset.", feedback: "make it darker")
            check(outcome == .success("Quoted revised prompt."), "a quote-wrapped result should be unwrapped, got \(outcome)", &ok)
        }

        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "not authenticated", "is_error": true}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            VideoPromptEnhancer.claudePathOverrideForTests = script.path
            let outcome = runReviseSync(currentPrompt: "A calm ocean at sunset.", feedback: "make it darker")
            check(outcome.isFailure, "is_error:true should be reported as a failure, got \(outcome)", &ok)
        }

        do {
            VideoPromptEnhancer.claudePathOverrideForTests = "/nonexistent/path/to/claude-\(UUID().uuidString)"
            let outcome = runReviseSync(currentPrompt: "A calm ocean at sunset.", feedback: "make it darker")
            check(outcome.isFailure, "a nonexistent claude path should fail cleanly, got \(outcome)", &ok)
        }

        do {
            VideoPromptEnhancer.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let outcome = runReviseSync(currentPrompt: "A calm ocean at sunset.", feedback: "   ")
            check(outcome.isFailure, "empty feedback should fail without spawning a process", &ok)
        }

        do {
            VideoPromptEnhancer.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let outcome = runReviseSync(currentPrompt: "   ", feedback: "make it darker")
            check(outcome.isFailure, "an empty current prompt should fail without spawning a process", &ok)
        }

        do {
            let prompt = VideoPromptEnhancer.revisionPrompt(currentPrompt: "A calm ocean at sunset.", feedback: "make it choppier")
            check(prompt.contains("A calm ocean at sunset."), "the revision prompt should embed the current prompt", &ok)
            check(prompt.contains("make it choppier"), "the revision prompt should embed the feedback text", &ok)
        }
    }

    // MARK: Version history + restore-without-regenerating

    private static func testVersionHistoryAndRestore(_ ok: inout Bool) {
        let controller = VideoGenController()
        _ = controller.view // force loadView() so the debug hooks below have something to read

        check(controller.debugVersions.isEmpty, "a fresh controller should start with no version history", &ok)
        check(controller.debugActiveVersionIndex == nil, "a fresh controller should have no active version", &ok)

        let clipV1 = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).mp4")
        controller.debugRecordVersion(prompt: "A calm ocean at sunset.", feedback: nil, outputPath: clipV1)
        check(controller.debugVersions.count == 1, "recording a version should add it to history, got \(controller.debugVersions.count)", &ok)
        check(controller.debugVersions.first?.number == 1, "the first version should be numbered 1", &ok)
        check(controller.debugVersions.first?.historyLabel == "Original",
              "v1 with no feedback should be labeled Original, got \(controller.debugVersions.first?.historyLabel ?? "nil")", &ok)
        check(controller.debugActiveVersionIndex == 0, "recording a version should make it the active one", &ok)

        let clipV2 = FileManager.default.temporaryDirectory.appendingPathComponent("v2-\(UUID().uuidString).mp4")
        controller.debugRecordVersion(prompt: "A calm ocean at sunset with choppy waves.",
                                      feedback: "the water is too still, make it choppier", outputPath: clipV2)
        check(controller.debugVersions.count == 2, "a second recorded version should append, not replace, got \(controller.debugVersions.count)", &ok)
        check(controller.debugVersions.last?.historyLabel == "the water is too still, make it choppier",
              "v2's history label should be its feedback text, got \(controller.debugVersions.last?.historyLabel ?? "nil")", &ok)
        check(controller.debugActiveVersionIndex == 1, "the newest version should become active", &ok)

        // Restore v1 - this must NOT spawn a real generation. Pointing the
        // executable override at a nonexistent path is what proves it: if
        // `restoreVersionTapped` ever called `VideoGenEngine.generate`, the
        // fake path would be invoked, `isGenerating` would flip, and this
        // whole check would fail loudly rather than silently.
        VideoGenEngine.executableOverrideForTests = "/nonexistent/should-not-be-invoked-by-restore-\(UUID().uuidString)"
        controller.debugRestoreVersion(number: 1)
        check(controller.debugActiveVersionIndex == 0, "restoring v1 should make it active again", &ok)
        check(controller.debugPromptField.stringValue == "A calm ocean at sunset.",
              "restoring a version should make its prompt the active one, got \(controller.debugPromptField.stringValue)", &ok)
        check(controller.debugActiveVersion?.outputPath == clipV1,
              "restoring a version should point the active clip at that version's own file", &ok)
        check(!controller.debugIsGenerating, "restoring a version must never trigger a real generation", &ok)
        check(controller.debugVersions.count == 2, "restoring must never delete or overwrite any prior version - both clips stay in history", &ok)

        // Restoring an unknown version number is a no-op, not a crash.
        controller.debugRestoreVersion(number: 999)
        check(controller.debugActiveVersionIndex == 0, "restoring a nonexistent version number should be a no-op", &ok)

        VideoGenEngine.executableOverrideForTests = nil
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

    /// A fake `ltx-2-mlx` that writes every argument it was given, one per
    /// line, to `captureURL` (rather than just parsing out `-o` like
    /// `writeFakeLtx` above) - what `testOptionToArgumentMapping` reads back
    /// to assert on the *exact* flags this app sent for a given duration/
    /// resolution/clarity/reference-type combination, not just that
    /// something ran and produced a file. Also touches `-o`'s path so the
    /// real `generate()` call this drives reports success.
    private static func writeFakeLtxCapturingArgv(to captureURL: URL, exitCode: Int32 = 0) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-ltx-argv-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        out=""
        : > "\(captureURL.path)"
        while [ $# -gt 0 ]; do
          printf '%s\\n' "$1" >> "\(captureURL.path)"
          if [ "$1" = "-o" ]; then out="$2"; fi
          shift
        done
        if [ -n "$out" ]; then touch "$out"; fi
        exit \(exitCode)
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// True when `argv` contains `flag` immediately followed by `value` -
    /// the way this app always passes a two-token option (`-f 97`,
    /// `--width 704`), never `--flag=value`.
    private static func argvContainsPair(_ argv: [String], flag: String, value: String) -> Bool {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return false }
        return argv[index + 1] == value
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

    /// `generate()`'s full signature, for the settings/argument-mapping
    /// tests - `runGenerateSync` above stays as-is (unchanged callers, plain
    /// defaults) rather than widening it and touching every existing case.
    private static func runGenerateSyncFull(
        prompt: String, durationSeconds: Double, resolution: VideoGenResolutionPreset,
        clarity: VideoGenClarity, reference: VideoGenReferenceType
    ) -> Outcome<VideoGenResult.Comparable> {
        final class Box { var outcome: Outcome<VideoGenResult.Comparable>? }
        let box = Box()
        VideoGenEngine.generate(
            prompt: prompt, durationSeconds: durationSeconds, resolution: resolution,
            clarity: clarity, reference: reference
        ) { result in
            switch result {
            case .success(let r): box.outcome = .success(.init(outputPath: r.outputPath))
            case .failure: box.outcome = .failure
            }
        }
        return pump { box.outcome }
    }

    private static func runReviseSync(currentPrompt: String, feedback: String) -> Outcome<String> {
        final class Box { var outcome: Outcome<String>? }
        let box = Box()
        VideoPromptEnhancer.reviseForFeedback(currentPrompt: currentPrompt, feedback: feedback) { result in
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
