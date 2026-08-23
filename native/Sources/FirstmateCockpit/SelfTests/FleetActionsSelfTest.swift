// Manjesh Grand Line - native macOS app.
//
// F7's permanent coverage: the reply-routing logic behind Overview's "Reply"
// affordance and the header's "Message first mate" action.
//
// What is covered, and why each part is here rather than assumed:
//
//   - **The decision-key fold.** `FleetStatusDecisions` is a Swift port of
//     `bin/fm-classify-lib.sh`'s `status_open_decisions`, and a drift in it is
//     silent in the worst way: a key this app reports as open but firstmate
//     does not makes `fm-send` refuse the *whole* send (it validates the key
//     before typing anything), so the captain's answer never leaves the app.
//   - **The exactly-one rule.** With two decisions open, which one an answer
//     settles is genuinely ambiguous, and closing the wrong record is worse
//     than closing none.
//   - **The argv.** `--resolve-key` must precede the message, and the message
//     must reach the script byte-for-byte - this feature has no AI pass and
//     must never acquire one. GL-38 is the standing reminder that an unasserted
//     argv shape can be wrong for a feature's entire life.
//   - **The three exit-code outcomes.** `fm-send.sh`'s contract is *not* the
//     usual zero-or-broken shape: 0 is confirmed, **3 is "typed and Enter
//     sent, but unconfirmed"**, anything else failed. Collapsing 3 into either
//     neighbour is a lie in one direction or the other.
//   - **That the general-message path never touches `fm-send.sh`.** It has no
//     task id to address, so it goes through the Mirror tab instead.
//
// ## What is faked, and what is real
//
// The real `bin/fm-send.sh` cannot be exercised here: it resolves a live
// crewmate endpoint and types into it, so a self-test running it would steer a
// real crewmate in the captain's actual fleet. `FleetActions.
// sendScriptOverrideForTests` points at a disposable script instead - the same
// seam `DictationCleanupSelfTest`/`SRELeadPostmortemSelfTest` use for `claude`
// - which records the argv it received and exits with a chosen status. So the
// *subprocess plumbing, argv and outcome mapping are genuinely exercised end
// to end*; the script's own verified-submit behaviour is not, and this file
// does not claim it is.
//
// Run: `FM_RUN_FLEET_ACTIONS_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard - see
// `Phase3PolishSelfTest`.
#if FM_SELFTESTS

import Foundation

enum FleetActionsSelfTest {

    static func run() -> Bool {
        var ok = true
        checkDecisionFold(&ok)
        checkResolveKeyRule(&ok)
        checkArguments(&ok)
        checkOutcomeMapping(&ok)
        checkRealSubprocessRoundTrip(&ok)
        checkLockGate(&ok)
        checkGeneralMessageNeverUsesSendScript(&ok)
        print(ok ? "FleetActionsSelfTest: all checks passed" : "FleetActionsSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition { fail(message, &ok) }
    }

    // MARK: The fold

    private static func checkDecisionFold(_ ok: inout Bool) {
        // Documented position: the token sits between the verb and the colon.
        var open = FleetStatusDecisions.open(inStatusText: """
        working: started
        needs-decision [key=api-shape]: one field or two?
        """)
        check(open.map(\.key) == ["api-shape"], "before-colon key token is read", &ok)
        check(open.first?.verb == "needs-decision", "the opening verb is recorded", &ok)
        check(open.first?.note == "one field or two?", "the note is the text after the colon", &ok)

        // Equivalent position: a complete token at the head of the note. This
        // is common real worker output and must not collapse into "default".
        open = FleetStatusDecisions.open(inStatusText: "blocked: [key=creds] need the staging key")
        check(open.map(\.key) == ["creds"], "note-head key token is read", &ok)
        check(open.first?.note == "need the staging key", "a consumed note-head token is stripped from the note", &ok)

        // Both stated: the documented position wins, and the note-head token
        // stays note text.
        open = FleetStatusDecisions.open(inStatusText: "needs-decision [key=outer]: [key=inner] which?")
        check(open.map(\.key) == ["outer"], "the before-colon token wins over a note-head one", &ok)
        check(open.first?.note == "[key=inner] which?", "the losing token stays note text", &ok)

        // No token at all: the historical one-open-decision-per-task bucket.
        open = FleetStatusDecisions.open(inStatusText: "needs-decision: roll back or patch forward?")
        check(open.map(\.key) == ["default"], "an unkeyed line opens \"default\"", &ok)

        // A token deeper inside the note is prose, never a stated key.
        open = FleetStatusDecisions.open(inStatusText: "needs-decision: should we reuse [key=old] here?")
        check(open.map(\.key) == ["default"], "a token deep in the note is prose, not a key", &ok)

        // An invalid slug skips the line entirely - never rewritten to
        // "default", which would open a decision the ledger does not have.
        open = FleetStatusDecisions.open(inStatusText: "needs-decision [key=bad slug]: hmm")
        check(open.isEmpty, "an invalid slug skips the line rather than opening \"default\"", &ok)

        // Closure, both verbs.
        open = FleetStatusDecisions.open(inStatusText: """
        needs-decision [key=a]: ask
        resolved [key=a]: answered
        """)
        check(open.isEmpty, "resolved closes its key", &ok)
        open = FleetStatusDecisions.open(inStatusText: """
        blocked [key=b]: stuck
        captain-held [key=b]: moved to the backlog
        """)
        check(open.isEmpty, "captain-held closes its key", &ok)

        // A bare `resolved:` closes "default" only.
        open = FleetStatusDecisions.open(inStatusText: """
        needs-decision [key=a]: ask
        needs-decision: bare
        resolved: done
        """)
        check(open.map(\.key) == ["a"], "a bare resolved: closes only \"default\"", &ok)

        // Re-opening replaces rather than duplicating, and two distinct keys
        // both stay open.
        open = FleetStatusDecisions.open(inStatusText: """
        needs-decision [key=a]: first ask
        needs-decision [key=a]: sharper ask
        blocked [key=b]: also stuck
        """)
        check(open.map(\.key) == ["a", "b"], "re-opening a key replaces it, and a second key coexists", &ok)
        check(open.first?.note == "sharper ask", "the latest opening line's note wins", &ok)

        // A working:/done: line moves nothing.
        open = FleetStatusDecisions.open(inStatusText: """
        needs-decision [key=a]: ask
        working: still going
        done: shipped
        """)
        check(open.map(\.key) == ["a"], "only the four transition verbs move a key", &ok)

        // Reserved namespace: only its owner's own vocabulary may move it.
        open = FleetStatusDecisions.open(inStatusText: "needs-decision [key=pending-reply-42]: unrelated prose")
        check(open.isEmpty, "a reserved key is not opened by a line that does not speak its vocabulary", &ok)
        open = FleetStatusDecisions.open(inStatusText: "needs-decision [key=pending-reply-42]: pending-reply-42: awaiting mate")
        check(open.map(\.key) == ["pending-reply-42"], "a reserved key IS opened by its owner's own note", &ok)
    }

    // MARK: The exactly-one rule

    private static func checkResolveKeyRule(_ ok: inout Bool) {
        let none: [FleetDecision] = []
        check(FleetActions.resolveKey(among: none) == nil, "no open decision means no --resolve-key", &ok)

        let one = [FleetDecision(key: "api-shape", verb: "needs-decision", note: "n")]
        check(FleetActions.resolveKey(among: one) == "api-shape", "exactly one open decision is closed by the answer", &ok)

        let two = [FleetDecision(key: "a", verb: "needs-decision", note: "n"),
                   FleetDecision(key: "b", verb: "blocked", note: "n")]
        check(FleetActions.resolveKey(among: two) == nil,
              "two open decisions is ambiguous - send without a key rather than guess one", &ok)

        // "default" is a real, closable key the ledger genuinely reports, not
        // a placeholder to be filtered out.
        let bare = [FleetDecision(key: "default", verb: "needs-decision", note: "n")]
        check(FleetActions.resolveKey(among: bare) == "default", "\"default\" is a real key", &ok)

        // And the whole path, from raw status text through to the flag.
        let text = "needs-decision [key=rollback]: v2.3.1 or patch forward?"
        check(FleetActions.resolveKey(among: FleetStatusDecisions.open(inStatusText: text)) == "rollback",
              "the fold and the rule compose", &ok)
    }

    // MARK: argv

    private static func checkArguments(_ ok: inout Bool) {
        let previous = FleetActions.sendScriptOverrideForTests
        defer { FleetActions.sendScriptOverrideForTests = previous }
        FleetActions.sendScriptOverrideForTests = "/tmp/fake-fm-send.sh"

        let withKey = FleetActions.arguments(taskID: "task-142", resolveKey: "rollback",
                                             text: "Patch forward - v2.3.1 has the token bug too.")
        check(withKey == ["/tmp/fake-fm-send.sh", "task-142", "--resolve-key", "rollback",
                          "Patch forward - v2.3.1 has the token bug too."],
              "argv is <script> <task> --resolve-key <key> <text>, in that order", &ok)

        let plain = FleetActions.arguments(taskID: "task-138", resolveKey: nil, text: "go ahead")
        check(plain == ["/tmp/fake-fm-send.sh", "task-138", "go ahead"],
              "no key means no flag - a plain steer, which fm-send accepts", &ok)

        // The message is one argument and is never reshaped: no AI pass, no
        // quoting, no trimming beyond the caller's own.
        let awkward = "line one\nline two --resolve-key nope"
        let args = FleetActions.arguments(taskID: "t", resolveKey: nil, text: awkward)
        check(args.last == awkward, "the message reaches the script byte-for-byte, as one argument", &ok)
        check(args.filter { $0 == "--resolve-key" }.isEmpty,
              "text that merely mentions the flag never becomes one", &ok)
    }

    // MARK: Exit-code contract

    private static func checkOutcomeMapping(_ ok: inout Bool) {
        func result(_ outcome: SubprocessResult.Outcome, _ status: Int32) -> SubprocessResult {
            SubprocessResult(outcome: outcome, status: status, stdoutData: Data(),
                             stderrData: Data("boom".utf8), duration: 0)
        }
        check(FleetActions.outcome(for: result(.exited, 0)) == .confirmed,
              "exit 0 is a confirmed submit", &ok)
        if case .sentUnconfirmed = FleetActions.outcome(for: result(.exited, 3)) {} else {
            fail("exit 3 must be sent-but-unconfirmed, never success and never failure", &ok)
        }
        if case .failed = FleetActions.outcome(for: result(.exited, 1)) {} else {
            fail("exit 1 is a real failure", &ok)
        }
        if case .failed = FleetActions.outcome(for: result(.timedOut, Subprocess.timedOutStatus)) {} else {
            fail("a timeout is a failure - nothing may be assumed delivered", &ok)
        }
        if case .failed = FleetActions.outcome(for: SubprocessResult.launchFailure("no such file")) {} else {
            fail("a launch failure is a failure", &ok)
        }

        // The three are reported differently. A blanket "sent!" for all three
        // is exactly what this feature's acceptance bar forbids.
        let messages = Set([FleetReplyOutcome.confirmed.message,
                            FleetReplyOutcome.sentUnconfirmed("").message,
                            FleetReplyOutcome.failed("x").message])
        check(messages.count == 3, "each outcome tells the captain something different", &ok)
        check(FleetReplyOutcome.failed("x").clearsComposer == false,
              "a failed send keeps the captain's text so it can be retried without re-typing", &ok)
        check(FleetReplyOutcome.sentUnconfirmed("").clearsComposer,
              "an unconfirmed send did reach the endpoint - the box clears so nothing invites a blind resend", &ok)
    }

    // MARK: The real subprocess path, against a disposable fake script

    private static func checkRealSubprocessRoundTrip(_ ok: inout Bool) {
        guard FileManager.default.fileExists(atPath: FirstmateHome.root.path) else {
            print("  SKIP subprocess round trip - no firstmate home at \(FirstmateHome.root.path) to run from")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-actions-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let argvLog = dir.appendingPathComponent("argv.txt")
        let script = dir.appendingPathComponent("fake-fm-send.sh")

        let wasLocked = AppLockGate.shared.isLocked
        let previous = FleetActions.sendScriptOverrideForTests
        defer {
            FleetActions.sendScriptOverrideForTests = previous
            AppLockGate.shared.setLocked(wasLocked)
        }
        AppLockGate.shared.setLocked(false)
        FleetActions.sendScriptOverrideForTests = script.path

        /// A stand-in for `bin/fm-send.sh`: records the argv it was handed and
        /// exits with the status this case is testing. It deliberately writes
        /// to both streams, so a regression to the pre-`Subprocess` drain
        /// order would show up here as a hang rather than a wrong answer.
        func writeScript(exit status: Int) {
            let body = """
            #!/bin/bash
            : > "\(argvLog.path)"
            for a in "$@"; do printf '%s\\n' "$a" >> "\(argvLog.path)"; done
            printf 'FM_HOME=%s\\n' "$FM_HOME"
            printf 'noise\\n' >&2
            exit \(status)
            """
            try? body.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        writeScript(exit: 0)
        var outcome = FleetActions.reply(taskID: "selftest-task", text: "  patch forward  ")
        check(outcome == .confirmed, "a confirming fake script maps to .confirmed", &ok)

        let recorded = (try? String(contentsOf: argvLog, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init) ?? []
        check(recorded.first == "selftest-task", "the task id is the first argument", &ok)
        check(recorded.last == "patch forward",
              "the message is the last argument, trimmed of surrounding whitespace only", &ok)
        // `selftest-task` has no status file, so there is no open decision and
        // therefore nothing to close - the rule, exercised for real.
        check(!recorded.contains("--resolve-key"),
              "a task with no open decision is answered without --resolve-key", &ok)

        writeScript(exit: 3)
        outcome = FleetActions.reply(taskID: "selftest-task", text: "hello")
        if case .sentUnconfirmed = outcome {} else {
            fail("a real exit-3 run maps to .sentUnconfirmed", &ok)
        }

        writeScript(exit: 4)
        outcome = FleetActions.reply(taskID: "selftest-task", text: "hello")
        if case .failed = outcome {} else { fail("a real exit-4 run maps to .failed", &ok) }

        // Empty text never reaches a subprocess at all.
        try? FileManager.default.removeItem(at: argvLog)
        outcome = FleetActions.reply(taskID: "selftest-task", text: "   \n ")
        if case .failed = outcome {} else { fail("an empty message is refused", &ok) }
        check(!FileManager.default.fileExists(atPath: argvLog.path),
              "an empty message never spawns the script", &ok)

        // A missing script is a clear failure, not a crash or a silent no-op.
        FleetActions.sendScriptOverrideForTests = dir.appendingPathComponent("nope.sh").path
        outcome = FleetActions.reply(taskID: "selftest-task", text: "hello")
        if case .failed(let reason) = outcome {
            check(reason.contains("nope.sh"), "a missing script names the path it looked for", &ok)
        } else {
            fail("a missing script is a failure", &ok)
        }
    }

    // MARK: GL-09

    private static func checkLockGate(_ ok: inout Bool) {
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        AppLockGate.shared.setLocked(true)
        check(!AppLockGate.shared.allows(.crewReply), "a locked app refuses a crew reply", &ok)

        let previous = FleetActions.sendScriptOverrideForTests
        defer { FleetActions.sendScriptOverrideForTests = previous }
        // Point at something that would succeed if it ever ran, so a passing
        // gate is the only thing that can make this fail.
        FleetActions.sendScriptOverrideForTests = "/bin/echo"
        if case .failed(let reason) = FleetActions.reply(taskID: "t", text: "hello") {
            check(reason.contains("locked"), "the refusal says the app is locked", &ok)
        } else {
            fail("a locked app must not send a reply", &ok)
        }

        AppLockGate.shared.setLocked(false)
        check(AppLockGate.shared.allows(.crewReply), "an unlocked app allows it again", &ok)
    }

    // MARK: The general-message channel

    /// A source guard, because the property worth protecting is structural:
    /// the unaddressed "message first mate" path has no task id, so it must
    /// never reach `fm-send.sh`. The two files that implement it are named
    /// here; if that path ever grows a `FleetActions.reply` call, this fails
    /// by file name.
    private static func checkGeneralMessageNeverUsesSendScript(_ ok: inout Bool) {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("could not locate the app's sources for the general-message source guard", &ok)
            return
        }
        // The general-message chain, end to end.
        let generalPathFiles = ["ConsoleController+Sessions.swift"]
        for name in generalPathFiles {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else {
                fail("could not read \(name)", &ok)
                continue
            }
            check(!text.contains("FleetActions.reply"),
                  "\(name) must not send a general message through fm-send.sh", &ok)
        }

        // `fm-send.sh` is named in exactly one place - the reply path - so a
        // second caller cannot appear without this failing.
        guard let files = SelfTestSources.appSourceFiles() else {
            fail("could not enumerate the app's sources", &ok)
            return
        }
        var namers: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Code, not prose: the doc comments in this feature legitimately
            // discuss the script by name.
            let codeLines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if codeLines.contains(where: { $0.contains("fm-send.sh") }) {
                namers.append(file.lastPathComponent)
            }
        }
        check(namers == ["FleetActions.swift"],
              "only FleetActions.swift may invoke fm-send.sh (found: \(namers))", &ok)
    }
}

#endif
