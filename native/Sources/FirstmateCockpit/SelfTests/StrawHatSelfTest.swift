// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates phase 1, the pure-logic half (milestone M1.5).
//
// Split from `StrawHatViewSelfTest` on the convention `WhiteboardSelfTest` /
// `WhiteboardViewSelfTest` and `FleetActionsSelfTest` /
// `FleetReplyLayoutSelfTest` already follow: this one builds no `NSWindow`
// and therefore runs in CI's blocking job; the view half mounts a real
// `FleetController` and lives in `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// What is asserted here, and why each one:
//
//  - **The persona's actual contents.** Two of its clauses are the feature's
//    only safety property in phase 1 - "you have no tools" and "never claim
//    you added anything". A prompt is not testable for what a model *does*
//    with it, but it is absolutely testable for whether the instruction is
//    still in the box, and a refactor that drops it looks like nothing.
//  - **`--resume` really threads.** Not "the runner stored a session id" -
//    the *argv the second turn actually ran with*, recorded by the fake
//    `claude` itself. A session id kept in a property and never passed is
//    exactly the bug that would make this a series of unrelated questions
//    while every in-process assertion still passed.
//  - **A stale session recovers without losing the thread** (M1.2's own
//    acceptance criterion), and recovers *with the recap* rather than by
//    silently dropping the conversation.
//  - **The lock gate.** `AppLockedSurface.strawHatChat`, which cannot be
//    observed any other way: a locked app must not spawn a `claude` turn.
//
// Every `claude` here is a disposable shell script - the real CLI is never
// invoked, so there is no network call, no Claude auth and no quota spend.
//
// Run: `swift build && FM_RUN_STRAW_HAT_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum StrawHatSelfTest {

    static func run() -> Bool {
        var ok = true
        // The gate starts locked, because the app does. Every case below that
        // is not specifically testing the gate needs it open, and it is put
        // back the way it was found - `AppLockGate.shared` is process-wide
        // state and a suite that leaves it flipped poisons whatever runs next
        // in the same process.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        checkPersona(&ok)
        checkRoster(&ok)
        checkRecapPrompt(&ok)
        checkLockGate(&ok)
        checkSingleTurn(&ok)
        checkResumeThreading(&ok)
        checkStaleSessionRecovery(&ok)
        checkFailuresAreReported(&ok)
        checkQuitCancelsAnInFlightTurn(&ok)

        print(ok ? "StrawHatSelfTest: all checks passed" : "StrawHatSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("  FAIL: \(message)")
            ok = false
        }
    }

    // MARK: The persona

    private static func checkPersona(_ ok: inout Bool) {
        let persona = StrawHatCrew.persona.lowercased()

        // The two clauses that are the whole of phase 1's honesty contract.
        check(persona.contains("no tools"),
              "persona must still tell Luffy he has no tools this turn", &ok)
        check(persona.contains("never claim you have added"),
              "persona must still forbid claiming a write that did not happen", &ok)
        check(persona.contains("never invent the contents"),
              "persona must still forbid inventing store contents", &ok)

        // Phase 1 ships one member. A persona that briefs the whole crew
        // would have Luffy answering as, or delegating to, colleagues who do
        // not exist - the exact failure the confirm-card rule exists to
        // prevent, one phase early.
        check(persona.contains("not aboard yet"),
              "persona must say the rest of the crew is not aboard yet", &ok)

        // The reply discipline SRE Lead already had to be corrected into once.
        check(persona.contains("lead with the answer"),
              "persona must still ask for answer-first replies", &ok)
        check(persona.contains("terse"),
              "persona must still ask for terse replies", &ok)

        // The plan's phase-2/2.5 mechanisms must not have leaked in early: a
        // persona that describes proposals or confirm cards while no parser
        // and no card exist produces replies the app silently drops.
        check(!persona.contains("confirm card"),
              "phase 1's persona must not describe confirm cards - nothing renders them yet", &ok)
        check(!persona.contains("json"),
              "phase 1's persona must not ask for a JSON envelope - phase 1 renders plain prose", &ok)
    }

    private static func checkRoster(_ ok: inout Bool) {
        check(StrawHatMember.allCases.count == 1,
              "phase 1 ships exactly one crew member, got \(StrawHatMember.allCases.map(\.rawValue))", &ok)
        check(StrawHatCrew.speaker == .luffy, "the phase-1 speaker is Luffy", &ok)

        // `NSImage(systemSymbolName:)` returns nil silently, and this app has
        // shipped an invisible icon that way before (the Hosts list's
        // "anchor", which is not an SF Symbol at all).
        for member in StrawHatMember.allCases {
            check(NSImage(systemSymbolName: member.symbol, accessibilityDescription: nil) != nil,
                  "\(member.displayName)'s SF Symbol \"\(member.symbol)\" resolves", &ok)
        }
    }

    // MARK: The recap prompt

    private static func checkRecapPrompt(_ ok: inout Bool) {
        // No history: the message travels alone, with no recap scaffolding
        // wrapped around it.
        let bare = StrawHatRunner.promptWithRecap(message: "what next?", transcript: [])
        check(bare == "what next?",
              "with no transcript the recap prompt is just the message, got: \(bare)", &ok)

        let recapped = StrawHatRunner.promptWithRecap(
            message: "and the second one?",
            transcript: ["Captain: name two ports", "Luffy: Loguetown and Water Seven"])
        check(recapped.contains("Loguetown"),
              "the recap must carry the earlier turns - that is the whole point of it", &ok)
        check(recapped.contains("and the second one?"),
              "the recap prompt must still carry the captain's actual message", &ok)
        // The two halves have to be distinguishable, or the model answers the
        // recap instead of the message. This is the minimal form of the plan's
        // phase-2 [CONTEXT]/[MESSAGE] envelope.
        check(recapped.contains("[RECAP") && recapped.contains("[MESSAGE FROM THE CAPTAIN"),
              "the recap and the live message must be separately labelled", &ok)
        check(recapped.range(of: "[RECAP")!.lowerBound < recapped.range(of: "[MESSAGE FROM THE CAPTAIN")!.lowerBound,
              "the recap comes before the message it is context for", &ok)
    }

    // MARK: The lock gate

    private static func checkLockGate(_ ok: inout Bool) {
        // A path that would spawn a real `claude` if the gate failed open -
        // pointed at a script that records being run, so "it was refused" is
        // proven by the absence of an invocation, not only by the error text.
        let log = scratchFile("lock-argv")
        let script = writeFakeClaude(reply: "should never run", argvLog: log)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build against a fake claude", &ok)
            return
        }

        AppLockGate.shared.setLocked(true)
        let locked = ask(runner, "are you there?")
        check(locked.failure != nil, "a locked app must refuse a turn, got \(locked)", &ok)
        check(!FileManager.default.fileExists(atPath: log.path),
              "a locked app must not spawn claude at all", &ok)

        AppLockGate.shared.setLocked(false)
        let unlocked = ask(runner, "are you there?")
        check(unlocked.reply == "should never run",
              "an unlocked app runs the turn normally, got \(unlocked)", &ok)
        check(FileManager.default.fileExists(atPath: log.path),
              "...and that turn really did spawn claude", &ok)
    }

    // MARK: Turns

    private static func checkSingleTurn(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        let log = scratchFile("single-argv")
        let script = writeFakeClaude(reply: "Aye. What's the plan?", argvLog: log, sessionID: "sess-1")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }
        let outcome = ask(runner, "hello")
        check(outcome.reply == "Aye. What's the plan?", "the reply text comes back verbatim, got \(outcome)", &ok)

        let argv = readArgv(log)
        let printable = printableArgv(log)
        // The captain's message travels as its own argv element - never
        // through a shell - which is what makes a message containing
        // backticks or `$(...)` inert.
        check(argv.contains("hello"), "the message is passed as an argv element, got \(printable)", &ok)
        check(argv.contains("--append-system-prompt"), "the persona is attached, got \(printable)", &ok)
        check(argv.contains(StrawHatCrew.persona), "the persona attached is the real one", &ok)
        check(argv.contains("--output-format") && argv.contains("json"),
              "the shared ClaudeOneShot argv shape is used", &ok)
        check(!argv.contains("--resume"), "a first turn has nothing to resume, got \(printable)", &ok)
        // Phase 1 has no tools, so it must not claim any - see
        // `StrawHatRunner`'s header.
        check(!argv.contains("--allowedTools"),
              "phase 1 grants no tools, so it must not pass an allowlist", &ok)
        check(!argv.contains("--mcp-config"), "phase 1 has no MCP server", &ok)
        check(!argv.contains("bypassPermissions"),
              "phase 1 has nothing to permit, so it must not bypass permissions", &ok)
        check(runner.debugSessionID == "sess-1",
              "the reply's session id is retained for the next turn, got \(String(describing: runner.debugSessionID))", &ok)
    }

    /// The multi-turn property, proven from the argv the *second* turn really
    /// ran with rather than from the runner's own bookkeeping.
    private static func checkResumeThreading(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        let log = scratchFile("resume-argv")
        let script = writeFakeClaude(reply: "Still here.", argvLog: log, sessionID: "sess-42")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }
        _ = ask(runner, "first")
        let second = ask(runner, "second")
        check(second.reply == "Still here.", "the second turn succeeds, got \(second)", &ok)

        let argv = readArgv(log) // the log holds the LAST invocation
        let printable = printableArgv(log)
        check(argv.contains("second"), "the log should hold the second turn, got \(printable)", &ok)
        guard let resumeIndex = argv.firstIndex(of: "--resume") else {
            check(false, "the second turn must pass --resume, got \(printable)", &ok)
            return
        }
        check(argv.indices.contains(resumeIndex + 1) && argv[resumeIndex + 1] == "sess-42",
              "--resume must carry the first turn's own session id, got \(printable)", &ok)
        // A resumed turn carries no recap - the session already holds the
        // history, and sending it twice would pay for it twice.
        check(!argv.contains { $0.contains("[RECAP") },
              "an ordinary resumed turn must not carry a recap", &ok)

        // Third turn: still threading, not just the second.
        _ = ask(runner, "third")
        let third = readArgv(log)
        check(third.contains("--resume"), "every later turn keeps resuming, got \(third.map { $0 == StrawHatCrew.persona ? "<persona>" : $0 })", &ok)

        // A new conversation drops the thread deliberately.
        runner.reset()
        check(runner.debugSessionID == nil, "reset() clears the session id", &ok)
        check(runner.debugTranscriptCount == 0, "reset() clears the recap transcript", &ok)
        _ = ask(runner, "fresh start")
        check(!readArgv(log).contains("--resume"),
              "the turn after reset() starts a new session, got \(printableArgv(log))", &ok)
    }

    /// M1.2's own acceptance criterion: "killing the session id mid-
    /// conversation recovers without losing the thread."
    private static func checkStaleSessionRecovery(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        let log = scratchFile("stale-argv")
        // A fake `claude` that fails whenever `--resume` is present and
        // succeeds otherwise - exactly how a pruned/expired session behaves.
        let script = writeResumeRejectingClaude(reply: "Right - the login bug, and Rahul.", argvLog: log)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }

        // Turn one succeeds (no --resume yet) and gives the runner history.
        let first = ask(runner, "remind me what I said about the login bug")
        check(first.failure == nil, "the first turn should succeed, got \(first)", &ok)
        check(runner.debugTranscriptCount == 1, "the first turn is remembered for a recap", &ok)

        // Now force a session id `claude` will reject.
        runner.debugCorruptSessionID()
        let second = ask(runner, "and who was I supposed to ask?")

        check(second.failure == nil,
              "a stale session must recover rather than surfacing as a failed turn, got \(second)", &ok)
        let argv = readArgv(log) // the retry is the last invocation
        let printable = printableArgv(log)
        check(!argv.contains("--resume"),
              "the recovery retry must drop --resume, got \(printable)", &ok)
        // The whole point: recovering must not cost the conversation. Without
        // the recap the model would answer "who was I supposed to ask?" with
        // no idea what came before.
        check(argv.contains { $0.contains("[RECAP") },
              "the recovery retry must carry a transcript recap, got \(printable)", &ok)
        check(argv.contains { $0.contains("remind me what I said about the login bug") },
              "the recap must contain the earlier turn's real text", &ok)
        check(argv.contains { $0.contains("and who was I supposed to ask?") },
              "the recovery retry must still carry the captain's live message", &ok)
    }

    private static func checkFailuresAreReported(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)

        // A `claude` that is not there at all.
        StrawHatCrew.claudePathOverrideForTests = "/nonexistent/claude-\(UUID().uuidString)"
        check(StrawHatRunner() != nil,
              "the runner builds against any path - 'is it real' is the turn's problem, not init's", &ok)
        if let runner = StrawHatRunner() {
            let outcome = ask(runner, "hello")
            check(outcome.failure != nil, "a missing claude is a reported failure, got \(outcome)", &ok)
        }

        // Garbled output: a failure, never a silently-empty success.
        let script = writeRawClaude(stdout: "not json at all\n", exitCode: 1)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        if let runner = StrawHatRunner() {
            let outcome = ask(runner, "hello")
            check(outcome.failure != nil, "garbled output is a reported failure, got \(outcome)", &ok)
        }

        // An empty message never reaches a process.
        let log = scratchFile("empty-argv")
        let ok2 = writeFakeClaude(reply: "should not run", argvLog: log)
        defer { try? FileManager.default.removeItem(at: ok2) }
        StrawHatCrew.claudePathOverrideForTests = ok2.path
        if let runner = StrawHatRunner() {
            let outcome = ask(runner, "   \n  ")
            check(outcome.failure != nil, "an empty message is refused, got \(outcome)", &ok)
            check(!FileManager.default.fileExists(atPath: log.path),
                  "an empty message must not spawn claude", &ok)
        }
        StrawHatCrew.claudePathOverrideForTests = nil
    }

    /// GL-13: an in-flight `claude -p` child must not outlive the app.
    ///
    /// Half behavioural, half source guard, because neither alone is enough:
    /// `cancel()` genuinely stops a turn from delivering (observable), but
    /// whether the app's quit path *calls* it leaves nothing to observe in
    /// process - and an unwired `shutdownCrew` is exactly the shape
    /// `CodePreviewController.shutdown()` shipped in for its whole life with
    /// zero callers.
    private static func checkQuitCancelsAnInFlightTurn(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        // A `claude` that never answers, so the turn is genuinely still in
        // flight when it is cancelled.
        let script = writeScript("sleep 30\nexit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }
        var landed = false
        runner.ask("hello") { _ in landed = true }
        // Let the process actually start before pulling it out from under.
        let started = Date().addingTimeInterval(1.0)
        while Date() < started { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        check(!landed, "the turn should still be in flight against a sleeping claude", &ok)

        runner.cancel()
        let deadline = Date().addingTimeInterval(5)
        while !landed && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // `Subprocess` reports a cancelled run rather than hanging - what
        // matters is that it came back in seconds, not after `sleep 30`.
        check(landed, "cancel() must end the turn rather than leaving it running", &ok)

        // ...and the quit path really reaches it. Skips rather than passes
        // when the source tree is not reachable (a release/installed run),
        // matching every other source guard in this repo - a guard that
        // silently passes because it found nothing to read is worse than none.
        guard let sources = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: source tree not reachable - skipping the quit-wiring source guard")
            return
        }
        let shell = (try? String(contentsOf: sources.appendingPathComponent("AppShellController.swift"), encoding: .utf8)) ?? ""
        let main = (try? String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8)) ?? ""
        check(shell.contains("overview.shutdownCrew()"),
              "AppShellController must forward the quit teardown to the Crew tab", &ok)
        check(main.contains("appShell.shutdownStrawHatCrew()"),
              "applicationWillTerminate must call that forward - an unwired shutdown is invisible", &ok)
    }

    // MARK: Harness

    private struct Outcome: CustomStringConvertible {
        let reply: String?
        let failure: String?
        var description: String { reply.map { "success(\($0))" } ?? "failure(\(failure ?? "?"))" }
    }

    /// Drives `ask` and waits for its completion by pumping the main run loop
    /// - `ClaudeOneShot` always completes via `DispatchQueue.main.async`, and
    /// this suite runs before `NSApplication.run()`, so a semaphore would
    /// deadlock against the very block being waited on. Same convention as
    /// `ConsoleCommandComposerSelfTest.runGenerateSync`.
    private static func ask(_ runner: StrawHatRunner, _ message: String) -> Outcome {
        var outcome: Outcome?
        runner.ask(message) { result in
            switch result {
            case .success(let text): outcome = Outcome(reply: text, failure: nil)
            case .failure(let error): outcome = Outcome(reply: nil, failure: error.message)
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return outcome ?? Outcome(reply: nil, failure: "timed out waiting for the turn")
    }

    private static func scratchFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-\(name)-\(UUID().uuidString).log")
    }

    /// One argv element per line, so an element containing spaces or newlines
    /// still round-trips - which matters, because the persona and the recap
    /// are both multi-line.
    private static func readArgv(_ log: URL) -> [String] {
        guard let raw = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        // `printf '%s\0'` writes a NUL after each element; the last one leaves
        // a trailing empty component.
        var parts = raw.components(separatedBy: "\0")
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// The same argv with the ~2.5KB persona collapsed to a marker. A failure
    /// message that dumps the whole persona buries the one thing it is trying
    /// to say - found the first time an injected regression was verified here.
    private static func printableArgv(_ log: URL) -> [String] {
        readArgv(log).map { $0 == StrawHatCrew.persona ? "<persona>" : $0 }
    }

    private static func fakeClaudePayload(reply: String, sessionID: String?) -> String {
        var obj: [String: Any] = ["result": reply, "is_error": false]
        if let sessionID { obj["session_id"] = sessionID }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// A fake `claude` that records its own argv NUL-separated and prints one
    /// `--output-format json` payload.
    private static func writeFakeClaude(reply: String, argvLog: URL, sessionID: String? = nil) -> URL {
        let payload = fakeClaudePayload(reply: reply, sessionID: sessionID)
        return writeScript("""
        printf '%s\\0' "$@" > "\(argvLog.path)"
        printf '%s\\n' '\(shellSingleQuoted(payload))'
        exit 0
        """)
    }

    /// A fake `claude` that rejects any turn carrying `--resume` - a pruned or
    /// expired session, exactly as the real CLI reports it.
    private static func writeResumeRejectingClaude(reply: String, argvLog: URL) -> URL {
        let good = fakeClaudePayload(reply: reply, sessionID: "sess-recovered")
        let bad = fakeClaudePayload(reply: "No conversation found with session ID", sessionID: nil)
            .replacingOccurrences(of: "\"is_error\":false", with: "\"is_error\":true")
        return writeScript("""
        printf '%s\\0' "$@" > "\(argvLog.path)"
        for arg in "$@"; do
          if [ "$arg" = "--resume" ]; then
            printf '%s\\n' '\(shellSingleQuoted(bad))'
            exit 1
          fi
        done
        printf '%s\\n' '\(shellSingleQuoted(good))'
        exit 0
        """)
    }

    private static func writeRawClaude(stdout: String, exitCode: Int32) -> URL {
        writeScript("""
        printf '%s' '\(shellSingleQuoted(stdout))'
        exit \(exitCode)
        """)
    }

    private static func shellSingleQuoted(_ raw: String) -> String {
        raw.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func writeScript(_ body: String) -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-strawhat-\(UUID().uuidString).sh")
        try? "#!/bin/sh\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
}

#endif
