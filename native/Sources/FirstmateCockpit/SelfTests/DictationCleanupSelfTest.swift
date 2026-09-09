// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `DictationCleanup.rewrite` (phase
// 3, fm/grandline-dictation-phase3) - same convention as
// `DictationDataSelfTest.swift`/`DictationHotkeySelfTest.swift`. Drives the
// real `Process`/parsing code in `DictationCleanup.swift` end to end against
// real, disposable shell scripts standing in for `claude`
// (`DictationCleanup.claudePathOverrideForTests`), never the real `claude`
// CLI or a real network call - this is what makes the test fast and
// deterministic instead of depending on the machine's own Claude
// authentication.
// `FM_RUN_DICTATION_CLEANUP_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum DictationCleanupSelfTest {
    static func run() -> Bool {
        var ok = true
        defer { DictationCleanup.claudePathOverrideForTests = nil }

        // 1. A well-formed success response is parsed and returned as-is.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "This is a clean sentence.", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("uh so like the the thing is broken i think")
            check(expectation == .success("This is a clean sentence."), "well-formed success response should parse cleanly", &ok)
        }

        // 2. A response wrapped in straight quotes is unwrapped.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "\"Quoted clean sentence.\"", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("some rough transcript")
            check(expectation == .success("Quoted clean sentence."), "a quote-wrapped result should be unwrapped, got \(expectation)", &ok)
        }

        // 3. `is_error: true` is treated as a failure, not a success.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "not authenticated", "is_error": true}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("some rough transcript")
            check(expectation.isFailure, "is_error:true should be reported as a failure, got \(expectation)", &ok)
        }

        // 4. Garbled/non-JSON output (simulating a crash or unexpected format)
        //    is a failure, not a crash and not treated as success.
        do {
            let script = writeFakeClaude(rawOutput: "not json at all\n", exitCode: 1)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("some rough transcript")
            check(expectation.isFailure, "garbled output should be reported as a failure, got \(expectation)", &ok)
        }

        // 5. A nonexistent claude path (simulating "not installed") fails
        //    cleanly via the `try proc.run()` catch path, not a crash.
        do {
            DictationCleanup.claudePathOverrideForTests = "/nonexistent/path/to/claude-\(UUID().uuidString)"
            let expectation = runRewriteSync("some rough transcript")
            check(expectation.isFailure, "a nonexistent claude path should fail cleanly, got \(expectation)", &ok)
        }

        // 6. An empty transcript is rejected up front, no process spawned.
        do {
            DictationCleanup.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let expectation = runRewriteSync("   ")
            check(expectation.isFailure, "an empty/whitespace-only transcript should fail without spawning a process", &ok)
        }

        // 7. The prompt sent to claude contains the exact transcript and asks
        //    for a plain-text-only rewrite - a change to this shape without
        //    updating `stripWrappingQuotes`'s defensive parsing would be easy
        //    to miss otherwise.
        do {
            let transcript = "so basically what im trying to say is"
            let prompt = DictationCleanup.prompt(for: transcript)
            check(prompt.contains(transcript), "prompt should embed the exact transcript text", &ok)
            check(prompt.lowercased().contains("only"), "prompt should ask for the rewrite only, no extra commentary", &ok)
        }

        // 8. With no vocabulary supplied, the prompt carries no
        //    vocabulary-correction instruction at all - byte-for-byte the
        //    same shape as before this feature existed, so a caller that
        //    never passes a vocabulary list (the default) sees no behavior
        //    change. Regression guard for "vocabulary correction only
        //    activates when there's something to check against."
        do {
            let prompt = DictationCleanup.prompt(for: "some transcript")
            check(!prompt.lowercased().contains("vocabulary"), "an empty/omitted vocabulary list should add no vocabulary-correction instruction, got:\n\(prompt)", &ok)
        }

        // 9. With a vocabulary list supplied, the prompt names every word and
        //    carries both the "correct a plausible misrecognition" instruction
        //    and the explicit anti-over-correction guard (the captain's own
        //    reported failure mode is under-correction; a naive fix that only
        //    asks for correction, with no guard, would trade it for the
        //    opposite bug - turning a genuinely-meant common word into a
        //    vocabulary word that happens to sound similar).
        do {
            let prompt = DictationCleanup.prompt(for: "an older session", vocabulary: ["herdr", "no-mistakes"])
            check(prompt.contains("herdr"), "prompt should list the herdr vocabulary word", &ok)
            check(prompt.contains("no-mistakes"), "prompt should list every vocabulary word, not just the first", &ok)
            check(prompt.lowercased().contains("phonetic"), "prompt should ask for a phonetic-near-match correction", &ok)
            check(prompt.lowercased().contains("do not force"), "prompt should explicitly guard against over-correction", &ok)
        }

        // 10. `rewrite(_:vocabulary:)` actually threads the vocabulary list
        //     into the real prompt argv sent to `claude` - not just into the
        //     pure `prompt(for:vocabulary:)` function tested above. A fake
        //     `claude` that records its own argv (the prompt travels as one
        //     argv element - see `ClaudeOneShot.swift`'s header) is what
        //     proves the call site wiring, not just the prompt builder in
        //     isolation; without this, a regression that forgot to pass
        //     `vocabulary:` through at the `rewrite` call site would pass
        //     every case above and still ship the captain's original bug.
        do {
            let script = writeFakeClaudeCapturingArgv(outputJSON: #"{"result": "a herdr session", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let box = OutcomeBox()
            DictationCleanup.rewrite("an older session", vocabulary: ["herdr"]) { result in
                switch result {
                case .success(let text): box.outcome = .success(text)
                case .failure: box.outcome = .failure
                }
            }
            waitFor(box)
            check(box.outcome == .success("a herdr session"), "expected the corrected result to pass through, got \(String(describing: box.outcome))", &ok)

            let argvPath = script.deletingLastPathComponent().appendingPathComponent("argv.txt")
            let sentArgv = (try? String(contentsOf: argvPath, encoding: .utf8)) ?? ""
            check(sentArgv.contains("herdr"), "the vocabulary word should reach the real prompt sent to claude, got argv:\n\(sentArgv)", &ok)
            check(sentArgv.lowercased().contains("phonetic"), "the correction instruction should reach the real prompt sent to claude", &ok)
        }

        // 11. The counterpart to case 10: with no vocabulary passed (the
        //     default), the sent prompt carries no vocabulary-correction
        //     instruction - proving the omission from case 8 also holds
        //     through the real call site, not just the pure prompt builder.
        do {
            let script = writeFakeClaudeCapturingArgv(outputJSON: #"{"result": "a clean sentence", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let box = OutcomeBox()
            DictationCleanup.rewrite("some rough transcript") { result in
                switch result {
                case .success(let text): box.outcome = .success(text)
                case .failure: box.outcome = .failure
                }
            }
            waitFor(box)
            check(box.outcome == .success("a clean sentence"), "expected the plain rewrite to still work with no vocabulary passed", &ok)

            let argvPath = script.deletingLastPathComponent().appendingPathComponent("argv.txt")
            let sentArgv = (try? String(contentsOf: argvPath, encoding: .utf8)) ?? ""
            check(!sentArgv.lowercased().contains("vocabulary"), "no vocabulary passed should mean no vocabulary section in the real sent prompt, got argv:\n\(sentArgv)", &ok)
        }

        // 12. No-over-correction, exercised as a round trip: when the
        //     "model" (the fake script's canned reply) leaves a genuinely-
        //     meant word untouched despite it superficially resembling a
        //     vocabulary entry, that unmodified text passes through exactly -
        //     `rewrite` never second-guesses or post-processes whatever
        //     `claude` actually returned. (Live-verified separately, against
        //     the real `claude` CLI with this exact prompt shape, that the
        //     model itself correctly declines to over-correct "he's a bit
        //     older than expected" into "herdr" - see this task's PR
        //     description for the transcript. This case guards the plumbing
        //     side of that: a correctly-declining model's answer must not be
        //     mangled on the way back to the caller.)
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "He's a bit older than expected for this position.", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("he's a bit older than expected for this position", vocabulary: ["herdr"])
            check(expectation == .success("He's a bit older than expected for this position."), "a correctly-declined correction should pass through unmodified, got \(expectation)", &ok)
        }

        return ok
    }

    /// A fake `claude` executable: a shell script that ignores its real
    /// arguments (mirroring how `claude -p ... --output-format json` is
    /// actually invoked) and prints one line of canned output, exactly the
    /// shape `DictationCleanup.parseResult` expects to parse (its last
    /// non-empty stdout line).
    private static func writeFakeClaude(outputJSON: String) -> URL {
        writeFakeClaude(rawOutput: outputJSON + "\n", exitCode: 0)
    }

    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        let escaped = rawOutput.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// A fake `claude` that, before printing its canned output, dumps its own
    /// real argv (the prompt travels as one argv element - `-p <prompt>`, see
    /// `ClaudeOneShot.swift`'s header) to a sibling `argv.txt` file - this is
    /// what proves what `rewrite` actually sent, not just what
    /// `prompt(for:vocabulary:)` would build in isolation. Its own directory
    /// (not just the script) so `argv.txt` has somewhere stable to live -
    /// callers remove the whole directory in their own `defer`.
    private static func writeFakeClaudeCapturingArgv(outputJSON: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-dictation-cleanup-argv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude")
        let escaped = (outputJSON + "\n").replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$(dirname "$0")/argv.txt"
        printf '%s' '\(escaped)'
        exit 0
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private enum RewriteOutcome: Equatable {
        case success(String)
        case failure

        static func == (lhs: RewriteOutcome, rhs: RewriteOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.success(let a), .success(let b)): return a == b
            case (.failure, .failure): return true
            default: return false
            }
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    /// Waits for `DictationCleanup.rewrite`'s async completion by pumping the
    /// main run loop, not by blocking on a semaphore - `rewrite`'s completion
    /// is always dispatched via `DispatchQueue.main.async` (see that file's
    /// own doc comment), and this self-test runs on the main thread with no
    /// `NSApplication.run()` loop active yet (`main.swift` calls this before
    /// `app.run()`, matching `ShiftGitSyncSelfTest.swift`'s own note about
    /// the same constraint) - blocking that same thread on a semaphore would
    /// prevent the main dispatch queue from ever draining the very block
    /// this is waiting on, deadlocking every run. `RunLoop.main.run(mode:before:)`
    /// still drains the main dispatch queue's run-loop source even without
    /// AppKit's own event loop running.
    private static func runRewriteSync(_ transcript: String, vocabulary: [String] = []) -> RewriteOutcome {
        let box = OutcomeBox()
        DictationCleanup.rewrite(transcript, vocabulary: vocabulary) { result in
            switch result {
            case .success(let text): box.outcome = .success(text)
            case .failure: box.outcome = .failure
            }
        }
        waitFor(box)
        return box.outcome ?? .failure
    }

    /// A plain reference-type box for the completion result, rather than a
    /// captured local `var` - passing that same local as `inout` to a shared
    /// wait helper (an earlier version of this file did exactly that) creates
    /// a genuine Swift exclusivity conflict: the wait helper's `inout` access
    /// spans its whole call, and `rewrite`'s completion closure (which
    /// captures the identical local by reference) can fire and try to write
    /// to it *during* that span once the run loop is pumped, which the
    /// runtime correctly flags as simultaneous access to the same storage. A
    /// class instance mutated through two separate references has no such
    /// conflict, so both the closure and the wait loop below read/write
    /// `box.outcome` directly with no `inout` involved.
    private final class OutcomeBox {
        var outcome: RewriteOutcome?
    }

    /// Shared with the two argv-capturing cases above, which build their own
    /// `rewrite` calls directly (to keep the fake-script/argv-file setup
    /// local to each case) but still need the same non-blocking wait - see
    /// `runRewriteSync`'s own doc comment for why this pumps the run loop
    /// rather than blocking on a semaphore.
    private static func waitFor(_ box: OutcomeBox) {
        let deadline = Date().addingTimeInterval(15)
        while box.outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }
}

#endif
