// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates phase 1's conversation runner - the plan's `LuffyRunner`
// milestone (M1.2), named for the feature rather than the one member phase 1
// ships so phase 2 adds crew inside it rather than around it.
//
// This is the **ninth** caller of `ClaudeOneShot` (GL-26's one shared
// `claude -p ... --output-format json` runner) and adds no new invocation
// shape. `SRELeadRunner` is the sibling it copies: one non-interactive
// process per turn, the persona re-sent via `--append-system-prompt` every
// time, and `claude`'s own `session_id` threaded back through `--resume` to
// make the pane a conversation rather than a series of unrelated questions.
//
// What it deliberately does NOT copy from `SRELeadRunner`: the MCP config,
// `--strict-mcp-config`, `--allowedTools` and `--permission-mode
// bypassPermissions`. Phase 1's Luffy has no tools at all, so passing an
// allowlist would be describing a capability that does not exist, and
// `bypassPermissions` on a session with nothing to permit is a strictly
// worse default. Read-only MCP tools are phase 2.5 (`luffy_stores_mcp.py`);
// writes stay out of MCP entirely and always will - confirm cards are the
// only write path this feature will ever have.
//
// ## Stale `--resume`, and why the recovery is not just "drop it"
//
// `--resume <id>` fails for reasons that have nothing to do with the turn:
// `claude`'s own session store can be pruned, a machine can be rebooted, a
// session can simply expire. `WhiteboardDiagram` established this app's
// recovery for that - retry the same turn once without `--resume` - and it
// works there because that feature re-sends the whole board on every turn,
// so the retry is a genuine equivalent rather than a degraded guess.
//
// Here it is not: drop `--resume` from a chat turn and the thread is gone,
// which is exactly the failure the captain would notice ("it forgot what we
// were talking about"). So the retry carries a **recap** - a bounded tail of
// this conversation's own turns, from this runner's in-memory transcript,
// labelled as a recap so the model does not mistake it for something the
// captain just said. That is the plan's own prescription (`#memory`:
// "`WhiteboardDiagram`'s retry-without-resume plus a transcript-tail
// recap"), and it is what makes M1.2's acceptance criterion - "killing the
// session id mid-conversation recovers without losing the thread" - true
// rather than aspirational.
//
// The transcript is in memory only. Phase 1 has no on-disk chat history by
// explicit scope (the plan's M1.4 is deferred), so a conversation lives as
// long as the app session does and no transcript is ever written anywhere.

import Foundation

/// One Straw Hat conversation's turn-by-turn `claude -p` runner.
///
/// Not thread-safe for concurrent `ask` calls, and does not defend against
/// them - the chat view disables its composer while a turn is in flight, the
/// same contract `SRELeadRunner` documents.
final class StrawHatRunner {

    /// One remembered turn, for the stale-resume recap only. Never written to
    /// disk (phase 1 has no persistence) and never shown - the chat view keeps
    /// its own copy of the messages it renders.
    private struct Turn {
        let captain: String
        let luffy: String
    }

    /// How many past turns the recap may carry. Bounded because it is prepended
    /// to a real prompt: an unbounded recap would grow every turn and, on a
    /// long conversation, cost more than the conversation itself. Six turns is
    /// comfortably enough to keep a thread coherent through one recovery, which
    /// is the only thing it exists for.
    static let maxRecapTurns = 6

    private let claude: String
    private let workingDir: URL?

    /// `claude`'s own session id from the last successful turn. `nil` until the
    /// first reply lands, and after `reset()`.
    private var sessionID: String?
    private var transcript: [Turn] = []

    /// Cancellation handle for the turn currently in flight, so the page can
    /// stop a running `claude` when it goes away. Shared across a retry on
    /// purpose: a cancel during the first attempt must also stop the second.
    private var inFlight: SubprocessCancellation?

    /// Fails only when `claude` cannot be found at all - which the chat view
    /// renders as a real, actionable message rather than a dead composer.
    init?(claude: String? = nil) {
        guard let resolved = claude ?? StrawHatCrew.resolveClaude() else { return nil }
        self.claude = resolved
        self.workingDir = StrawHatCrew.resolveWorkingDirectory()
    }

    /// Whether this conversation has any history yet - the chat view's "New
    /// conversation" affordance is pointless before the first exchange.
    var hasHistory: Bool { !transcript.isEmpty }

    /// Ask one turn. `completion` is always called on the main thread, exactly
    /// once (`ClaudeOneShot`'s own contract).
    ///
    /// GL-09 / `AppLockedSurface.strawHatChat`: refused outright while the app
    /// is locked. The composer lives inside the main window under the lock
    /// overlay, so this is not a walk-up click path today - the gate is here
    /// because of what the call *is*: it ships the captain's own words to a
    /// subprocess and renders a reply, which is precisely the "shows or writes
    /// the captain's data while nobody is meant to be at the keyboard" rule in
    /// `AppLockGate`'s header.
    func ask(_ message: String, completion: @escaping (Result<String, StrawHatError>) -> Void) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(StrawHatError(message: "There was nothing to send.")))
            return
        }
        guard AppLockGate.shared.allows(.strawHatChat) else {
            completion(.failure(StrawHatError(message: "Unlock Grand Line to talk to the crew.")))
            return
        }

        let token = SubprocessCancellation()
        inFlight = token
        let resume = sessionID

        runOnce(prompt: trimmed, resumeSessionID: resume, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply):
                self.finish(captain: trimmed, reply: reply, token: token, completion: completion)

            case .failure(let error):
                // Only a turn that was *resuming* has anything to recover
                // from; a first turn's failure is a real failure, and a
                // second identical call would only double the wait.
                guard resume != nil, !token.isCancelled else {
                    self.inFlight = nil
                    completion(.failure(error))
                    return
                }
                AppLog.ai.error("straw hat: turn failed while resuming - retrying with a transcript recap")
                let recapped = Self.promptWithRecap(message: trimmed, transcript: self.transcript)
                self.runOnce(prompt: recapped, resumeSessionID: nil, token: token) { [weak self] retry in
                    guard let self else { return }
                    switch retry {
                    case .success(let reply):
                        self.finish(captain: trimmed, reply: reply, token: token, completion: completion)
                    case .failure(let retryError):
                        self.inFlight = nil
                        completion(.failure(retryError))
                    }
                }
            }
        }
    }

    /// Start a fresh conversation: the next turn carries no `--resume` and no
    /// recap. Cancels anything in flight, since its reply would land in a
    /// thread that no longer exists.
    func reset() {
        cancel()
        sessionID = nil
        transcript.removeAll()
    }

    /// Best-effort kill of an in-flight turn. Safe whether or not one is
    /// running.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }

    // MARK: Internals

    private func finish(captain: String,
                        reply: ClaudeReply,
                        token: SubprocessCancellation,
                        completion: (Result<String, StrawHatError>) -> Void) {
        inFlight = nil
        // Threading the session id back through `--resume` is what makes this
        // a conversation. A reply that carried none (older `claude`, or a
        // recovered turn that produced no new session) simply leaves the
        // previous one in place rather than clearing it - dropping a working
        // session because one reply omitted the field would break the thread
        // for no reason.
        if let sid = reply.sessionID { sessionID = sid }
        transcript.append(Turn(captain: captain, luffy: reply.text))
        if transcript.count > Self.maxRecapTurns {
            transcript.removeFirst(transcript.count - Self.maxRecapTurns)
        }
        completion(.success(reply.text))
    }

    private func runOnce(prompt: String,
                         resumeSessionID: String?,
                         token: SubprocessCancellation,
                         completion: @escaping (Result<ClaudeReply, StrawHatError>) -> Void) {
        ClaudeOneShot.run(
            executable: claude,
            prompt: prompt,
            extraArguments: ["--append-system-prompt", StrawHatCrew.persona],
            resumeSessionID: resumeSessionID,
            cwd: workingDir,
            timeout: ClaudeOneShot.conversationTimeout,
            label: "claude -p (Straw Hat)",
            cancellation: token
        ) { result in
            switch result {
            case .success(let reply): completion(.success(reply))
            case .failure(let error): completion(.failure(StrawHatError(message: error.message)))
            }
        }
    }

    /// The recovery prompt: a labelled recap of the conversation so far,
    /// then the captain's actual message.
    ///
    /// Two labelled parts rather than one blob, so the recap can never be
    /// mistaken for something the captain just typed - the same separation the
    /// plan's phase-2 `[CONTEXT]`/`[MESSAGE]` turn envelope formalises, in the
    /// one minimal form phase 1 genuinely needs. `internal` so
    /// `StrawHatSelfTest` can assert its shape without spawning anything.
    static func promptWithRecap(message: String, transcript: [String]) -> String {
        guard !transcript.isEmpty else { return message }
        let recap = transcript.joined(separator: "\n")
        return """
        [RECAP OF THIS CONVERSATION SO FAR - the session was interrupted and had to be restarted. This is history, not something the captain just said. Do not reply to it, and do not mention the interruption unless asked.]
        \(recap)

        [MESSAGE FROM THE CAPTAIN - reply to this]
        \(message)
        """
    }

    private static func promptWithRecap(message: String, transcript: [Turn]) -> String {
        promptWithRecap(message: message, transcript: transcript.flatMap {
            ["Captain: \($0.captain)", "\(StrawHatCrew.speaker.displayName): \($0.luffy)"]
        })
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// The session id the next turn would resume, so `StrawHatSelfTest` can
    /// prove multi-turn threading from the runner's own state as well as from
    /// the argv a fake `claude` recorded.
    var debugSessionID: String? { sessionID }

    /// Forces the next turn to resume a session id `claude` will reject -
    /// the "killing the session id mid-conversation" half of M1.2, which
    /// cannot otherwise be provoked without waiting for a real session to
    /// expire.
    func debugCorruptSessionID(_ id: String = "fm-selftest-stale-session") {
        sessionID = id
    }

    /// How many turns the recap would carry right now.
    var debugTranscriptCount: Int { transcript.count }
    #endif
}
