// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates, the pure-logic half (phase 1's M1.5, extended by phase
// 2's M2.1-M2.3).
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
// Phase 2 adds, one case per milestone:
//
//  - **Each of the three parser rungs, separately** (M2.1). Not "the parser
//    works" - each rung asserts the thing that rung exists *for*: rung 1 that
//    a validated envelope becomes attributed sections and confirm-able
//    proposals, rung 2 that an unknown speaker or kind still *renders* and
//    still never *executes*, rung 3 that a prose reply containing braces is
//    not shredded in the attempt to salvage one.
//  - **The closed proposal vocabulary** (M2.2), asserted as a literal list,
//    so a kind added without a matching executor branch fails here.
//  - **The confirm-only guarantee**, asserted by counting store contents
//    before and after *parsing* - the property the whole feature rests on,
//    and one no amount of prose in a header can prove.
//  - **The context snapshot** (M2.3), including GL-14's rule: an unreported
//    health registry must read as a stated gap, never as a clean bill of
//    health.
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
        checkProposalVocabulary(&ok)
        checkRung1ValidatedEnvelope(&ok)
        checkRung2PartialSalvage(&ok)
        checkRung3PlainText(&ok)
        checkEnvelopeCaps(&ok)
        checkDueResolution(&ok)
        checkContextSnapshot(&ok)
        checkTurnEnvelope(&ok)
        checkProposalExecution(&ok)
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

        // Honesty rule 1: the crew cannot change anything themselves.
        //
        // Phase 1 asserted the literal words "no tools", which phase 2 has
        // outgrown - the crew now genuinely has *facts* (a bounded snapshot),
        // just not tools or write access. So the assertion moved to the clause
        // that still carries the whole property rather than being deleted with
        // the wording it happened to be written against.
        check(persona.contains("you cannot change anything in the app or on the machine"),
              "the persona must still say the crew cannot change anything itself", &ok)
        check(persona.contains("never say \"added\", \"saved\", \"created\", \"scheduled\", or \"done\" about a proposal"),
              "the persona must still forbid past-tense language about a proposal", &ok)
        // Honesty rule 3, unchanged from phase 1.
        check(persona.contains("never invent the contents"),
              "persona must still forbid inventing store contents", &ok)

        // The crew that is NOT aboard still has to be named as absent, or the
        // model answers as a colleague the parser will refuse.
        check(persona.contains("not aboard yet"),
              "persona must say the rest of the crew is not aboard yet", &ok)

        // The reply discipline SRE Lead already had to be corrected into once.
        check(persona.contains("lead with the answer"),
              "persona must still ask for answer-first replies", &ok)
        check(persona.contains("terse"),
              "persona must still ask for terse replies", &ok)

        // Phase 2's reply format IS the envelope, so the phase-1 assertions
        // that this must NOT mention JSON or confirm cards are inverted here
        // rather than deleted: they encoded phase 1 as the expected behaviour
        // (the same shape audit #2 §4.5 found in `SessionRestoreSelfTest` and
        // §1's own `checkSettingsTwoColumnLayout`), and phase 2's whole
        // contract is that the persona describes what `StrawHatEnvelope.parse`
        // reads.
        check(persona.contains("json"),
              "the persona must ask for a fenced json block - `StrawHatEnvelope` parses nothing else", &ok)
        check(persona.contains("sections"),
              "the persona must name the `sections` array the parser looks for", &ok)
        check(persona.contains("confirm"),
              "the persona must tell the crew a proposal is confirmed by the captain, not by them", &ok)

        // A write is a proposal, never a claim - the single worst failure this
        // feature can have, and the half of the defence a prompt owns.
        check(persona.contains("never write prose claiming a write has happened"),
              "the persona must forbid claiming a write happened", &ok)
        check(persona.contains("nothing you propose happens until they press it"),
              "the persona must say the captain's press is what writes", &ok)

        // The wire contract with the parser: every kind and every speaker id
        // the app accepts has to actually be named, or the model is being
        // asked to guess at a vocabulary that is then silently refused.
        for kind in StrawHatProposalKind.allCases {
            check(StrawHatCrew.persona.contains(kind.rawValue),
                  "the persona must name the \"\(kind.rawValue)\" proposal kind it is allowed to use", &ok)
        }
        for member in StrawHatMember.allCases {
            check(StrawHatCrew.persona.contains("\"\(member.rawValue)\""),
                  "the persona must name \(member.displayName)'s speaker id \"\(member.rawValue)\"", &ok)
        }

        // The plan's phase-3 vocabulary must not have leaked in early: a
        // persona describing a proposal nothing can execute produces exactly
        // the plausible-but-wrong the confirm-card rule exists to prevent.
        for absent in ["add_sticky", "save_command_draft", "create_schedule_draft",
                       "open_sre_lead", "open_destination"] {
            check(!StrawHatCrew.persona.contains(absent),
                  "phase 2's persona must not describe \"\(absent)\" - phase 3 owns it and nothing executes it yet", &ok)
        }
        for absent in ["zoro", "usopp", "franky"] {
            check(!persona.contains("\"\(absent)\""),
                  "phase 2's persona must not hand \(absent) a speaker id - the parser would refuse it", &ok)
        }

        // The bounded-context honesty rule (#2 in this file's header): the
        // crew sees a capped slice, so most things are still genuinely unknown.
        check(persona.contains("bounded"),
              "the persona must say the context snapshot is bounded", &ok)
        // Against the raw persona, not the lowercased copy - the label the
        // envelope actually emits is upper-case, and matching it in lower case
        // would pass for a persona that named a block that does not exist.
        check(StrawHatCrew.persona.contains("[CONTEXT"),
              "the persona must name the [CONTEXT] block so it is not answered directly", &ok)
        check(persona.contains("unavailable:"),
              "the persona must know what an `unavailable:` line means - GL-14, unknown is not empty", &ok)
    }

    private static func checkRoster(_ ok: inout Bool) {
        // Phase 2's four. Asserted as a literal set rather than a count, so a
        // fifth voice arriving early fails by name.
        check(StrawHatMember.allCases.map(\.rawValue) == ["luffy", "nami", "chopper", "robin"],
              "phase 2 ships Luffy, Nami, Chopper and Robin, got \(StrawHatMember.allCases.map(\.rawValue))", &ok)
        check(StrawHatCrew.speaker == .luffy, "the fallback speaker is Luffy - he owns the conversation", &ok)

        // `NSImage(systemSymbolName:)` returns nil silently, and this app has
        // shipped an invisible icon that way before (the Hosts list's
        // "anchor", which is not an SF Symbol at all). These are the fallback
        // glyphs for a portrait that fails to decode, so an unresolvable one
        // would turn a bad payload into a blank tile.
        for member in StrawHatMember.allCases {
            check(NSImage(systemSymbolName: member.symbol, accessibilityDescription: nil) != nil,
                  "\(member.displayName)'s SF Symbol \"\(member.symbol)\" resolves", &ok)
        }

        // M2.4: the portraits themselves. A nil payload degrades to the glyph
        // above rather than to a hole, so this cannot be caught by a build.
        for member in StrawHatMember.allCases {
            guard let portrait = StrawHatPortraits.image(for: member) else {
                check(false, "\(member.displayName)'s portrait failed to decode", &ok)
                continue
            }
            check(portrait.size.width == StrawHatPortraits.side
                    && portrait.size.height == StrawHatPortraits.side,
                  "\(member.displayName)'s portrait is \(StrawHatPortraits.side)pt square, got \(portrait.size)", &ok)
        }

        // A crew member's colour is an identity, so `.critical` - the app's
        // "something is wrong" hue - is not available to it. AGENTS.md records
        // this trap on Dictation's history rows: a semantic tint on a benign
        // row paints an alert bar on something that is not an alert.
        for member in StrawHatMember.allCases {
            check(member.tint != .critical,
                  "\(member.displayName)'s tint must not be `.critical` - it would read as an alert", &ok)
        }
        // ...and they must be distinguishable, or M2.4's per-crew colour buys
        // nothing.
        let tints = StrawHatMember.allCases.map { "\($0.tint)" }
        check(Set(tints).count == tints.count,
              "every crew member needs their own tint, got \(tints)", &ok)

        // Read-only by design: no store write is mapped to Chopper, and giving
        // him one would mean inventing a capability.
        check(StrawHatMember.chopper.proposalKinds.isEmpty,
              "Chopper is read-only in phase 2 - he must have no proposal kinds", &ok)
        check(StrawHatMember.luffy.proposalKinds.isEmpty,
              "Luffy orchestrates and proposes nothing himself", &ok)
        check(StrawHatMember.nami.proposalKinds.contains(.addTask)
                && StrawHatMember.nami.proposalKinds.contains(.addFollowUp),
              "Nami owns tasks and follow-ups", &ok)
        check(StrawHatMember.robin.proposalKinds == [.createRunbookDraft],
              "Robin owns runbook drafts", &ok)
    }

    // MARK: M2.2 - the closed proposal vocabulary

    private static func checkProposalVocabulary(_ ok: inout Bool) {
        // The enum IS the security mechanism (`KubeCommand`/
        // `ScheduledActionKind`'s convention), so its membership is asserted
        // as a literal: a kind added without a matching executor branch and a
        // deliberate decision fails here rather than shipping.
        check(StrawHatProposalKind.allCases.map(\.rawValue)
                == ["add_task", "add_follow_up", "create_runbook_draft"],
              "phase 2's vocabulary is exactly three kinds, got \(StrawHatProposalKind.allCases.map(\.rawValue))", &ok)

        for kind in StrawHatProposalKind.allCases {
            check(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil,
                  "\(kind.rawValue)'s SF Symbol \"\(kind.symbol)\" resolves", &ok)
            check(!kind.confirmTitle.isEmpty && !kind.confirmedTitle.isEmpty,
                  "\(kind.rawValue) needs both a confirm and a confirmed title", &ok)
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
            transcript: ["Captain: name two ports", "Crew: Loguetown and Water Seven"])
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

    // MARK: M2.1 - the three-rung parser
    //
    // Each rung gets its own case, and each asserts the thing that rung is
    // *for* rather than merely that parsing succeeded:
    //
    //   rung 1 - a validated envelope becomes attributed sections + proposals
    //   rung 2 - an unknown speaker/kind still renders, and never executes
    //   rung 3 - no envelope at all still shows the captain their reply
    //
    // Plus the invariant all three share: the reply is never dropped.

    private static func checkRung1ValidatedEnvelope(_ ok: inout Bool) {
        // The plan's own worked example, verbatim.
        let reply = """
        ```json
        { "sections": [
            { "speaker": "nami",
              "text": "I heard a task and a follow-up in there - drafted both:",
              "proposals": [
                { "kind": "add_task", "title": "Fix the login issue", "due": "2026-09-09" },
                { "kind": "add_follow_up", "title": "Ask Rahul about the Cognito config" } ] },
            { "speaker": "luffy",
              "text": "Both drafted - confirm to add.",
              "followup": "Want Robin to check for a Cognito runbook before you talk to Rahul?" }
        ] }
        ```
        """
        guard case .envelope(let sections) = StrawHatEnvelope.parse(reply) else {
            check(false, "the plan's own worked example must parse as a validated envelope", &ok)
            return
        }
        check(sections.count == 2, "that example is two sections, got \(sections.count)", &ok)
        check(sections.first?.speaker == .nami, "the first section is Nami's", &ok)
        check(sections.last?.speaker == .luffy, "the second is Luffy's", &ok)
        check(sections.first?.proposals.count == 2,
              "Nami's section carries both proposals, got \(sections.first?.proposals.count ?? -1)", &ok)
        check(sections.first?.proposals.first?.kind == .addTask, "a task first", &ok)
        check(sections.first?.proposals.first?.title == "Fix the login issue", "with the captain's own wording", &ok)
        check(sections.first?.proposals.last?.kind == .addFollowUp, "then a follow-up", &ok)
        check(sections.first?.droppedProposalCount == 0, "nothing was dropped from a valid envelope", &ok)
        check(sections.last?.followup?.contains("Cognito runbook") == true,
              "the closing question survives as a followup, not as a proposal", &ok)
        check(sections.last?.proposals.isEmpty == true,
              "a followup is not a proposal - it asks, it does not write", &ok)

        // The two shapes the extractor accepts, and only those.
        let bare = StrawHatEnvelope.parse(#"{ "sections": [ { "speaker": "luffy", "text": "hi" } ] }"#)
        guard case .envelope = bare else {
            check(false, "an unfenced object is the shape the persona asks for and must parse", &ok)
            return
        }
        let prosePrefixed = StrawHatEnvelope.parse("""
        One moment.

        ```json
        { "sections": [ { "speaker": "luffy", "text": "here you go" } ] }
        ```
        """)
        guard case .envelope(let salvaged) = prosePrefixed else {
            check(false, "a fence after a stray sentence must still parse - `stripCodeFence` only looks at line 0", &ok)
            return
        }
        check(salvaged.contains(where: { $0.speaker == .luffy && $0.text == "here you go" }),
              "the envelope's own section is attributed, got \(salvaged.map { "\($0.speaker?.rawValue ?? "-"):\($0.text)" })", &ok)
        // The stray sentence is kept too, unattributed - neither half of a
        // reply that is both prose and envelope is dropped.
        check(salvaged.contains(where: { $0.speaker == nil && $0.text == "One moment." }),
              "...and the prose around it survives as an unattributed section", &ok)
    }

    private static func checkRung2PartialSalvage(_ ok: inout Bool) {
        // An unknown speaker (a phase-3 voice arriving early) and an unknown
        // proposal kind, in one reply.
        // Note the unaboard speaker's proposal uses a **valid** kind. An
        // invented kind is refused by the kind check regardless of who
        // proposed it, so a fixture pairing the two leaves the speaker guard
        // completely untested - which is exactly what an injected regression
        // proved here: removing that guard passed the whole suite.
        let reply = """
        ```json
        { "sections": [
            { "speaker": "zoro",
              "text": "I'd restart the pod.",
              "proposals": [ { "kind": "add_task", "title": "Should never be offered" } ] },
            { "speaker": "nami",
              "text": "Drafted the task anyway:",
              "proposals": [
                { "kind": "add_task", "title": "Restart the API pods" },
                { "kind": "delete_everything", "title": "wipe it" } ] }
        ] }
        ```
        """
        guard case .envelope(let sections) = StrawHatEnvelope.parse(reply) else {
            check(false, "a salvageable envelope must not fall all the way to plain text", &ok)
            return
        }
        check(sections.count == 2, "both sections still render, got \(sections.count)", &ok)

        // The unattributed one: text kept, speaker refused, proposals refused.
        let unknown = sections[0]
        check(unknown.speaker == nil,
              "a voice that is not aboard must not be credited, got \(unknown.speaker?.rawValue ?? "nil")", &ok)
        check(unknown.rawSpeaker == "zoro", "...but what the model wrote is kept for the log", &ok)
        check(unknown.text == "I'd restart the pod.", "its text still renders - the reply is never dropped", &ok)
        check(unknown.proposals.isEmpty,
              "an unattributed section's proposals must never be executable, got \(unknown.proposals.map(\.title))", &ok)
        check(!unknown.proposals.contains(where: { $0.title == "Should never be offered" }),
              "...even when the kind itself is one the enum knows", &ok)
        check(unknown.droppedProposalCount == 1,
              "...and the refusal is counted, not silent, got \(unknown.droppedProposalCount)", &ok)

        // The attributed one: the good proposal survives, the invented one does not.
        let known = sections[1]
        check(known.speaker == .nami, "a real speaker is still credited", &ok)
        check(known.proposals.count == 1,
              "only the valid proposal survives, got \(known.proposals.count)", &ok)
        check(known.proposals.first?.kind == .addTask, "and it is the one the enum knows", &ok)
        check(known.droppedProposalCount == 1,
              "the invented kind is counted as dropped, got \(known.droppedProposalCount)", &ok)

        // A proposal missing the field its kind requires is refused too -
        // there is nothing safe to invent for either.
        let missing = StrawHatEnvelope.parse("""
        {"sections":[{"speaker":"nami","text":"x","proposals":[
          {"kind":"add_task"},
          {"kind":"create_runbook_draft","title":"No body"}
        ]}]}
        """)
        guard case .envelope(let refused) = missing, let only = refused.first else {
            check(false, "a section whose every proposal is refused still renders its text", &ok)
            return
        }
        check(only.proposals.isEmpty,
              "a titleless task and a bodyless runbook are both refused, got \(only.proposals.count)", &ok)
        check(only.droppedProposalCount == 2, "both counted, got \(only.droppedProposalCount)", &ok)
    }

    private static func checkRung3PlainText(_ ok: inout Bool) {
        // Ordinary prose - the common case, and phase 1's whole behaviour.
        let prose = "Loguetown and Water Seven. Want the rest?"
        guard case .plain(let text) = StrawHatEnvelope.parse(prose) else {
            check(false, "an ordinary prose reply is rung 3", &ok)
            return
        }
        check(text == prose, "and it renders verbatim, got: \(text)", &ok)

        // The direction that matters most: a prose answer that merely
        // *contains* braces must not be mistaken for an envelope and
        // shredded. This is why there is no brace-balanced last-resort scan -
        // see `StrawHatEnvelope`'s header.
        //
        // The object here has no `sections` key at all, so the only thing that
        // could turn this reply into an envelope is a widest-brace-span scan -
        // which is precisely what must not exist. An injected regression that
        // adds one is caught by this case.
        let bracey = """
        Your config needs a `logging` block:

        ```json
        { "level": "debug", "handlers": ["console"] }
        ```

        Drop that in and restart.
        """
        guard case .plain(let kept) = StrawHatEnvelope.parse(bracey) else {
            check(false, "a fenced json block that is not an envelope must not be read as one", &ok)
            return
        }
        check(kept.contains("Drop that in and restart."),
              "the prose after the block survives - losing it would be silent data loss", &ok)
        check(kept.contains("\"level\": \"debug\""), "and so does the code the captain asked for", &ok)

        // A reply that is genuinely *both* - a real envelope wrapped in real
        // prose, which is what "how does your reply format work?" produces -
        // keeps both, rather than choosing a side. See `Extracted`'s note.
        let both = StrawHatEnvelope.parse("""
        Your reply format looks like this:

        ```json
        { "sections": [ { "speaker": "nami", "text": "example" } ] }
        ```

        The `speaker` has to be one of the four of us.
        """)
        guard case .envelope(let mixed) = both else {
            check(false, "a real envelope inside prose still parses as one", &ok)
            return
        }
        check(mixed.count == 3,
              "leading prose, the envelope's section, then trailing prose - got \(mixed.count)", &ok)
        check(mixed.first?.speaker == nil && mixed.first?.text.contains("format looks like this") == true,
              "the prose before the fence comes first, unattributed", &ok)
        check(mixed.dropFirst().first?.speaker == .nami,
              "the envelope's own section keeps its attribution", &ok)
        check(mixed.last?.speaker == nil && mixed.last?.text.contains("one of the four of us") == true,
              "and the prose after it is kept too - nothing is lost either way", &ok)

        // The one shape a brace-balanced scan would genuinely destroy: an
        // *unfenced* inline example, whose widest brace span really is a
        // valid envelope. With no fence there is nothing for `extract` to
        // find, so the correct answer is the whole prose - and a scan would
        // return the span, drop everything around it, and render the
        // captain's own question back at them as Nami's reply.
        let inlineExample = """
        You'd send me something like {"sections": [{"speaker": "nami", "text": "hi"}]}         and I'd turn each entry into its own card. Want me to walk through the fields?
        """
        guard case .plain(let inlineKept) = StrawHatEnvelope.parse(inlineExample) else {
            check(false, "an unfenced inline example is prose, not an envelope - a brace scan would shred it", &ok)
            return
        }
        check(inlineKept.contains("Want me to walk through the fields?"),
              "...and every word of it survives", &ok)

        // Every way an envelope can be unusable lands here rather than
        // rendering nothing.
        let unusable = [
            "```json\n{ not json at all\n```",
            #"{"sections": []}"#,
            #"{"sections": [{"speaker":"nami"}]}"#,
            #"{"reply": "wrong key"}"#,
            #"{"sections": "not an array"}"#,
        ]
        for reply in unusable {
            guard case .plain(let shown) = StrawHatEnvelope.parse(reply) else {
                check(false, "an unusable envelope must fall to plain text: \(reply)", &ok)
                continue
            }
            check(!shown.isEmpty, "...and still show the captain something: \(reply)", &ok)
        }
    }

    private static func checkEnvelopeCaps(_ ok: inout Bool) {
        // Bounded, because these become permanent arranged subviews of the
        // transcript stack - and a runaway list of confirm cards is worse than
        // a truncated one, since every card is a button that writes.
        let manySections = (0..<(StrawHatEnvelope.maxSections + 4))
            .map { #"{"speaker":"luffy","text":"line \#($0)"}"# }
            .joined(separator: ",")
        guard case .envelope(let capped) = StrawHatEnvelope.parse("{\"sections\":[\(manySections)]}") else {
            check(false, "an over-long envelope still parses", &ok)
            return
        }
        // maxSections real sections plus the one "N more weren't shown" note -
        // the "no silent caps" rule.
        check(capped.count == StrawHatEnvelope.maxSections + 1,
              "sections are capped at \(StrawHatEnvelope.maxSections) plus an overflow note, got \(capped.count)", &ok)
        check(capped.last?.text.contains("weren't shown") == true,
              "the overflow must be stated, not silently truncated", &ok)

        let manyProposals = (0..<(StrawHatEnvelope.maxProposalsPerSection + 3))
            .map { #"{"kind":"add_task","title":"task \#($0)"}"# }
            .joined(separator: ",")
        guard case .envelope(let s) = StrawHatEnvelope.parse(
            "{\"sections\":[{\"speaker\":\"nami\",\"text\":\"lots\",\"proposals\":[\(manyProposals)]}]}"),
              let section = s.first else {
            check(false, "an over-long proposal list still parses", &ok)
            return
        }
        check(section.proposals.count == StrawHatEnvelope.maxProposalsPerSection,
              "proposals are capped at \(StrawHatEnvelope.maxProposalsPerSection), got \(section.proposals.count)", &ok)
        check(section.droppedProposalCount == 3,
              "the ones past the cap are counted, got \(section.droppedProposalCount)", &ok)
    }

    // MARK: M2.2 - due-date resolution

    private static func checkDueResolution(_ ok: inout Bool) {
        // A fixed reference, so "tomorrow" is a checkable date rather than
        // whatever day the suite happens to run on.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10
        guard let now = Calendar.current.date(from: comps) else {
            check(false, "could not build a reference date", &ok)
            return
        }

        // Strict ISO, the shape the persona prefers. No time invented.
        let iso = StrawHatProposal(kind: .addTask, title: "t", due: "2026-09-09")
        check(iso.resolvedDue(now: now)?.date == "2026-09-09",
              "an ISO due date resolves as written, got \(iso.resolvedDue(now: now)?.date ?? "nil")", &ok)
        check(iso.resolvedDue(now: now)?.time == nil,
              "a bare date carries no time - inventing one would show a due time nobody proposed", &ok)

        // Natural language, through the app's own scanner - so "tomorrow"
        // means the same thing whether the captain typed it or Nami proposed it.
        let tomorrow = StrawHatProposal(kind: .addTask, title: "t", due: "tomorrow")
        check(tomorrow.resolvedDue(now: now)?.date == "2026-09-10",
              "\"tomorrow\" resolves through ShiftDateParser, got \(tomorrow.resolvedDue(now: now)?.date ?? "nil")", &ok)
        let withTime = StrawHatProposal(kind: .addTask, title: "t", due: "tomorrow 3pm")
        check(withTime.resolvedDue(now: now)?.time == "15:00",
              "a time-of-day survives, got \(withTime.resolvedDue(now: now)?.time ?? "nil")", &ok)

        // The direction that matters: never a fabricated fallback. A wrong due
        // date presented as the captain's own choice is worse than none.
        let nonsense = StrawHatProposal(kind: .addTask, title: "t", due: "whenever, really")
        check(nonsense.resolvedDue(now: now) == nil,
              "an unreadable date leaves the task undated rather than landing on today", &ok)
        check(nonsense.detail(now: now).contains("couldn't read"),
              "...and says so, so the captain can fix it on the Tasks page", &ok)
        check(StrawHatProposal(kind: .addTask, title: "t").resolvedDue(now: now) == nil,
              "no date proposed, no date resolved", &ok)
    }

    // MARK: M2.3 - the bounded context snapshot

    private static func checkContextSnapshot(_ ok: inout Bool) {
        // Real stores against a scratch directory - never the captain's own.
        // `FM_SHIFT_DIR` is the root override the whole `GrandLineDocs/`
        // family resolves through, so this keeps both stores away from the
        // real clone (audit #2 §7.1's own lesson).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Both overrides, not just `FM_SHIFT_DIR`: `DocsRunbookStore.init`
        // checks `FM_DOCS_RUNBOOKS_DIR` **first** and only falls back to
        // `FM_SHIFT_DIR`, and `main.swift`'s own self-test block already sets
        // the former - so setting only the root override leaves this case
        // sharing one docs folder with every other case in the process. Found
        // by a real failure here: a runbook one case created was still present
        // when another deleted its own, and the undo assertion read as broken.
        let previousShiftDir = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let previousDocsDir = ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratch.appendingPathComponent("runbooks").path, 1)
        defer {
            if let previousShiftDir { setenv("FM_SHIFT_DIR", previousShiftDir, 1) } else { unsetenv("FM_SHIFT_DIR") }
            if let previousDocsDir { setenv("FM_DOCS_RUNBOOKS_DIR", previousDocsDir, 1) } else { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let shift = ShiftStore()
        let docs = DocsRunbookStore()

        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10
        guard let now = Calendar.current.date(from: comps) else {
            check(false, "could not build a reference date", &ok)
            return
        }
        let day = ShiftDateFormatting.components(from: now).dateStr

        // Due today, well past the window, and a pending follow-up.
        var soon = ShiftTask.fresh(now: now)
        soon.title = "Rotate the staging certificate"
        soon.dueDate = day
        shift.addTask(soon)

        var faraway = ShiftTask.fresh(now: now)
        faraway.title = "Plan the Q4 migration"
        faraway.dueDate = "2027-01-01"
        shift.addTask(faraway)

        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Ask Rahul about the Cognito config"
        followUp.followUpAt = day
        shift.addFollowUp(followUp)

        _ = docs.createRunbook(title: "Draining a node", content: "# Draining a node\n\nkubectl drain")

        let snapshot = StrawHatContextSnapshot.capture(shift: shift, docs: docs, now: now)
        let rendered = snapshot.render()

        check(snapshot.dueTaskCount == 1,
              "only the task inside the due-soon window counts, got \(snapshot.dueTaskCount)", &ok)
        check(rendered.contains("Rotate the staging certificate"),
              "a due-soon task's title reaches the crew - Nami cannot say \"you already have one\" otherwise", &ok)
        check(!rendered.contains("Plan the Q4 migration"),
              "a task months out is noise in every turn and must stay out of the snapshot", &ok)
        check(snapshot.pendingFollowUpCount == 1,
              "the pending follow-up counts, got \(snapshot.pendingFollowUpCount)", &ok)
        check(rendered.contains("Ask Rahul"), "...and is named", &ok)
        check(rendered.contains("Draining a node"),
              "a runbook title reaches Robin - recognition is her whole job", &ok)
        check(rendered.contains("runbooks: 1"), "with a real count beside it", &ok)

        // GL-14: unknown is never rendered as zero. A registry that has not
        // reported is a stated gap, not a clean bill of health.
        let emptyHealth = StrawHatContextSnapshot.capture(shift: shift, docs: docs,
                                                          healthStates: [], now: now)
        check(emptyHealth.health.isEmpty, "an unreported registry contributes no health lines", &ok)
        check(emptyHealth.unavailable.contains(where: { $0.contains("health") }),
              "...and says so - \"nothing has checked yet\" is not \"nothing is broken\"", &ok)
        check(emptyHealth.render().contains("unavailable:"),
              "the gap must be visible in the prompt itself", &ok)

        // A real failing service reads as failing, with its count. Built as a
        // real `ServiceHealthState` rather than by driving the shared
        // registry, which is process-wide and would poison whatever suite runs
        // next in the same process.
        var broken = ServiceHealthState()
        broken.lastFailure = now
        broken.lastFailureDetail = "boom"
        broken.consecutiveFailures = ServiceHealthRegistry.failureThreshold
        let failing = StrawHatContextSnapshot.capture(
            shift: shift, docs: docs,
            healthStates: [(service: .scheduledAutomations, state: broken)], now: now)
        check(failing.render().lowercased().contains("failing"),
              "a failing service must read as failing, got: \(failing.render())", &ok)
        check(failing.render().contains("\(ServiceHealthRegistry.failureThreshold)"),
              "...with its failure count, so Chopper can say how bad it is", &ok)

        // And a healthy one reads as ok, so "failing" is not just the only
        // word this ever produces.
        var fine = ServiceHealthState()
        fine.lastSuccess = now
        let healthy = StrawHatContextSnapshot.capture(
            shift: shift, docs: docs,
            healthStates: [(service: .docsSync, state: fine)], now: now)
        check(healthy.render().contains("=ok"),
              "a healthy service reads as ok, got: \(healthy.render())", &ok)
        check(healthy.unavailable.isEmpty, "...and is not also reported as unavailable", &ok)

        // Titles are capped; the count never is. Overflow is stated.
        for i in 0..<(StrawHatContextSnapshot.maxTaskTitles + 3) {
            var t = ShiftTask.fresh(now: now)
            t.title = "Bulk task \(i)"
            t.dueDate = day
            shift.addTask(t)
        }
        let big = StrawHatContextSnapshot.capture(shift: shift, docs: docs, now: now)
        check(big.dueTasks.count == StrawHatContextSnapshot.maxTaskTitles,
              "titles cap at \(StrawHatContextSnapshot.maxTaskTitles), got \(big.dueTasks.count)", &ok)
        check(big.dueTaskCount > big.dueTasks.count, "but the count stays exact", &ok)
        check(big.render().contains("and \(big.dueTaskCount - big.dueTasks.count) more"),
              "and the overflow is stated - \"no silent caps\"", &ok)

        // A docs folder that cannot be read is a stated gap, not "no runbooks".
        let noDocs = StrawHatContextSnapshot.capture(shift: shift, docs: nil, now: now)
        check(noDocs.unavailable.contains(where: { $0.contains("runbooks") }),
              "an unreadable docs folder is stated rather than reported empty", &ok)
    }

    // MARK: M2.3 - the turn envelope

    private static func checkTurnEnvelope(_ ok: inout Bool) {
        var snapshot = StrawHatContextSnapshot()
        snapshot.dueTaskCount = 2
        snapshot.dueTasks = [.init(title: "Rotate the cert", due: "Sep 9", isOverdue: false)]

        let prompt = StrawHatTurn.prompt(context: snapshot, message: "what should I do first?")
        check(prompt.contains("[CONTEXT"), "the snapshot is labelled as context", &ok)
        check(prompt.contains("[MESSAGE FROM THE CAPTAIN"), "the captain's words are labelled as theirs", &ok)
        check(prompt.contains("Rotate the cert"), "the snapshot's contents travel", &ok)
        check(prompt.contains("what should I do first?"), "and so does the message", &ok)
        // The whole reason for two labelled parts: the snapshot carries task
        // titles the captain wrote, and a model reading them as the current
        // message would answer the wrong question entirely.
        guard let ctx = prompt.range(of: "[CONTEXT"),
              let msg = prompt.range(of: "[MESSAGE FROM THE CAPTAIN") else {
            check(false, "both labels must be present", &ok)
            return
        }
        check(ctx.lowerBound < msg.lowerBound, "context comes before the message it is background for", &ok)
        check(prompt.contains("read-only"), "and says it is read-only, so it is not treated as an instruction", &ok)

        // No context and no recap: the bare message, exactly as phase 1 sent
        // it - which is also what the recap case asserts.
        check(StrawHatTurn.prompt(context: nil, message: "hello") == "hello",
              "an unadorned turn carries no scaffolding", &ok)

        // A recovered turn carries all three, in order.
        let recovered = StrawHatTurn.prompt(context: snapshot,
                                            recap: ["Captain: two ports?", "Crew: Loguetown"],
                                            message: "and the second?")
        check(recovered.contains("[RECAP"), "a recovered turn labels its recap", &ok)
        guard let r = recovered.range(of: "[RECAP"),
              let c = recovered.range(of: "[CONTEXT"),
              let m = recovered.range(of: "[MESSAGE FROM THE CAPTAIN") else {
            check(false, "all three labels must be present on a recovered turn", &ok)
            return
        }
        check(c.lowerBound < r.lowerBound && r.lowerBound < m.lowerBound,
              "context, then recap, then the live message", &ok)
        check(recovered.contains("Loguetown"), "the thread is genuinely carried, not just labelled", &ok)
    }

    // MARK: M2.2 - execution, and the confirm-only guarantee

    private static func checkProposalExecution(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-exec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Both overrides, not just `FM_SHIFT_DIR`: `DocsRunbookStore.init`
        // checks `FM_DOCS_RUNBOOKS_DIR` **first** and only falls back to
        // `FM_SHIFT_DIR`, and `main.swift`'s own self-test block already sets
        // the former - so setting only the root override leaves this case
        // sharing one docs folder with every other case in the process. Found
        // by a real failure here: a runbook one case created was still present
        // when another deleted its own, and the undo assertion read as broken.
        let previousShiftDir = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let previousDocsDir = ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratch.appendingPathComponent("runbooks").path, 1)
        defer {
            if let previousShiftDir { setenv("FM_SHIFT_DIR", previousShiftDir, 1) } else { unsetenv("FM_SHIFT_DIR") }
            if let previousDocsDir { setenv("FM_DOCS_RUNBOOKS_DIR", previousDocsDir, 1) } else { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let shift = ShiftStore()
        let docs = DocsRunbookStore()
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10
        guard let now = Calendar.current.date(from: comps) else {
            check(false, "could not build a reference date", &ok)
            return
        }

        // ---- The confirm-only guarantee, asserted rather than described ----
        //
        // Parsing the plan's own worked example must write nothing. This is
        // the property the whole feature rests on: a model cannot reach the
        // captain's stores, only hand the app a value that becomes a button.
        let tasksBefore = shift.activeTasks.count
        let followUpsBefore = shift.followUps.count
        let runbooksBefore = docs.listRunbooks().count
        _ = StrawHatEnvelope.parse("""
        {"sections":[{"speaker":"nami","text":"drafted","proposals":[
          {"kind":"add_task","title":"Should not exist"},
          {"kind":"add_follow_up","title":"Should not exist either"}]}]}
        """)
        check(shift.activeTasks.count == tasksBefore
                && shift.followUps.count == followUpsBefore
                && docs.listRunbooks().count == runbooksBefore,
              "parsing a reply must never write - only a captain's press does", &ok)

        // ---- add_task ----
        let taskProposal = StrawHatProposal(kind: .addTask, title: "Fix the login issue",
                                            due: "2026-09-09", notes: "from the crew")
        guard case .written(let taskMessage, let taskUndo) =
                StrawHatProposalExecutor.execute(taskProposal, shift: shift, docs: docs, now: now) else {
            check(false, "confirming a task proposal must write it", &ok)
            return
        }
        check(taskMessage.contains("Fix the login issue"), "the toast names what landed", &ok)
        // GL-33: an undo must genuinely restore. `ShiftStore` has no delete
        // for a task, so there is deliberately none here - see
        // `StrawHatProposalExecutor`'s header.
        check(taskUndo == nil,
              "a task add offers no undo - ShiftStore cannot delete one, and a fake undo would be a lie", &ok)
        guard let written = shift.activeTasks.first(where: { $0.title == "Fix the login issue" }) else {
            check(false, "the task must actually be in the store", &ok)
            return
        }
        check(written.dueDate == "2026-09-09", "with its due date, got \(written.dueDate ?? "nil")", &ok)
        check(written.notes == "from the crew", "and its notes", &ok)
        // Nothing invented: the model was asked for neither, so neither is set.
        check(written.projectID == nil, "no project is invented", &ok)
        check(written.priority == ShiftTask.fresh(now: now).priority,
              "and the priority stays the store's own default rather than a guess", &ok)

        // Survives a real reload - i.e. it reached disk, not just the array.
        let reloaded = ShiftStore()
        check(reloaded.activeTasks.contains(where: { $0.title == "Fix the login issue" }),
              "a confirmed task must survive a fresh store - otherwise it never reached disk", &ok)

        // ---- add_follow_up ----
        let followUpProposal = StrawHatProposal(kind: .addFollowUp,
                                                title: "Ask Rahul about the Cognito config",
                                                due: "tomorrow")
        guard case .written = StrawHatProposalExecutor.execute(followUpProposal, shift: shift, docs: docs, now: now) else {
            check(false, "confirming a follow-up proposal must write it", &ok)
            return
        }
        guard let wroteFollowUp = shift.followUps.first(where: { $0.title.contains("Rahul") }) else {
            check(false, "the follow-up must actually be in the store", &ok)
            return
        }
        check(wroteFollowUp.followUpAt == "2026-09-10",
              "\"tomorrow\" resolved through ShiftDateParser, got \(wroteFollowUp.followUpAt ?? "nil")", &ok)
        check(wroteFollowUp.status == .pending, "and it lands pending", &ok)

        // ---- create_runbook_draft, the one kind with a real undo ----
        let draft = StrawHatProposal(kind: .createRunbookDraft, title: "Draining a node",
                                     content: "# Draining a node\n\nkubectl drain node-1")
        guard case .written(let draftMessage, let draftUndo) =
                StrawHatProposalExecutor.execute(draft, shift: shift, docs: docs, now: now) else {
            check(false, "confirming a runbook draft must write it", &ok)
            return
        }
        check(draftMessage.contains("Draining a node"), "the toast names the runbook", &ok)
        check(docs.listRunbooks().contains(where: { $0.title == "Draining a node" }),
              "and it is really in the runbook list", &ok)
        guard let undo = draftUndo else {
            check(false, "a runbook draft DOES get an undo - `deleteRunbook` exists and the id is in hand", &ok)
            return
        }
        undo()
        check(!docs.listRunbooks().contains(where: { $0.title == "Draining a node" }),
              "and that undo genuinely removes the file it wrote - GL-33's whole rule", &ok)

        // A body with no heading gets one, or `DocsRunbookStore` reads the
        // display title back off the slug instead of the proposed title.
        let headless = StrawHatProposal(kind: .createRunbookDraft, title: "Rolling a secret",
                                        content: "Step one: revoke it.")
        guard case .written = StrawHatProposalExecutor.execute(headless, shift: shift, docs: docs, now: now) else {
            check(false, "a headingless body still saves", &ok)
            return
        }
        check(docs.listRunbooks().contains(where: { $0.title == "Rolling a secret" }),
              "...under the proposed title, because a `# ` heading was added", &ok)

        // A runbook proposal with nowhere to save fails visibly - the captain
        // pressed a button and is owed an answer either way.
        guard case .failed = StrawHatProposalExecutor.execute(draft, shift: shift, docs: nil, now: now) else {
            check(false, "a runbook draft with no docs store must fail visibly, not silently", &ok)
            return
        }
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
