// Manjesh Grand Line - native macOS app.
//
// The Straw Hat Pirates conversation runner - the plan's `LuffyRunner`
// milestone (M1.2), named for the feature rather than for one member so that
// phase 2's crew arrived *inside* it rather than around it. That held: phase
// 2 added the context snapshot to a turn and changed nothing else here.
//
// This is the **ninth** caller of `ClaudeOneShot` (GL-26's one shared
// `claude -p ... --output-format json` runner) and adds no new invocation
// shape. `SRELeadRunner` is the sibling it copies: one non-interactive
// process per turn, the persona re-sent via `--append-system-prompt` every
// time, and `claude`'s own `session_id` threaded back through `--resume` to
// make the pane a conversation rather than a series of unrelated questions.
//
// **Phase 2.5 gave the crew real tools**, so this now also passes
// `--mcp-config`, `--strict-mcp-config` and `--allowedTools`, matching
// `SRELeadRunner`'s own argv shape rather than inventing a second one. The
// tools are read-only and the allowlist is pinned to exactly four of them -
// see `StrawHatTools.swift` for the session that registers them and for the
// two independent layers that keep the surface read-only. Push and pull are
// complementary: `StrawHatContext`'s bounded snapshot still rides every turn
// unchanged, and the tools cover what a capped snapshot cannot.
//
// The one flag it still does **not** copy is `--permission-mode
// bypassPermissions`. That was measured, not reasoned about: `--allowedTools`
// alone both permits a listed tool and denies an unlisted one, so
// `bypassPermissions` would be a strictly broader grant bought for nothing.
// The measurement is written up in `StrawHatTools.swift`'s header.
//
// Writes stay out of MCP entirely and always will - proposals plus confirm
// cards are the only write path this feature will ever have.
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
// The transcript is in memory only. There is no on-disk chat history by
// explicit scope (the plan's M1.4 is still deferred through phase 2), so a
// conversation lives as long as the app session does and no transcript is
// ever written anywhere.

import Foundation

/// One Straw Hat conversation's turn-by-turn `claude -p` runner.
///
/// Not thread-safe for concurrent `ask` calls, and does not defend against
/// them - the chat view disables its composer while a turn is in flight, the
/// same contract `SRELeadRunner` documents.
final class StrawHatRunner {

    /// One remembered turn, for the stale-resume recap only. Never written to
    /// disk (there is no persistence yet) and never shown - the chat view
    /// keeps its own copy of the messages it renders.
    ///
    /// `crew` is the reply's raw text, envelope and all. Deliberately not the
    /// parsed sections: a recap's job is to remind the model what was already
    /// said, and its own words are the most faithful form of that.
    private struct Turn {
        let captain: String
        let crew: String
    }

    /// How many past turns the recap may carry. Bounded because it is prepended
    /// to a real prompt: an unbounded recap would grow every turn and, on a
    /// long conversation, cost more than the conversation itself. Six turns is
    /// comfortably enough to keep a thread coherent through one recovery, which
    /// is the only thing it exists for.
    static let maxRecapTurns = 6

    private let claude: String
    private let workingDir: URL?

    /// This conversation's read-only tool session (phase 2.5), or `nil` when
    /// the tools could not be set up - a missing `python3`, a missing script,
    /// an unwritable scratch directory, or a caller that passed no store
    /// roots at all.
    ///
    /// `nil` is a supported, survivable state, not an error path: the turn
    /// simply runs without `--mcp-config`, which is exactly phase 2's
    /// behaviour, and the pushed context snapshot still tells the crew what it
    /// told them before. Losing the tools must degrade the crew from "able to
    /// look" to "told", never break the chat.
    private let tools: StrawHatToolSession?

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
    ///
    /// `storeRoots` is what phase 2.5's tools are pointed at, supplied by the
    /// caller from stores it already holds. Passing `nil` runs the
    /// conversation with no tools at all - phase 2's behaviour, kept
    /// reachable so a self-test can drive the pushed-context path in
    /// isolation.
    init?(claude: String? = nil, storeRoots: StrawHatStoreRoots? = nil) {
        guard let resolved = claude ?? StrawHatCrew.resolveClaude() else { return nil }
        self.claude = resolved
        self.workingDir = StrawHatCrew.resolveWorkingDirectory()
        self.tools = storeRoots.flatMap { StrawHatCrew.setUpTools(roots: $0) }
    }

    deinit {
        // The scratch directory holds this conversation's MCP config and its
        // health snapshot, and nothing else - nothing lingers once the page
        // that owned the runner goes away.
        tools?.tearDown()
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
    func ask(_ message: String,
             context: StrawHatContextSnapshot? = nil,
             completion: @escaping (Result<String, StrawHatError>) -> Void) {
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
        // Phase 2 (M2.3): the turn envelope's `[CONTEXT]` half. Captured by
        // the caller, not here - this class owns `claude`, and a runner that
        // reached into `ShiftStore`/`DocsRunbookStore` to build its own
        // snapshot would be the second consumer of stores the page already
        // holds (AGENTS.md's `CommandLibraryStore` lesson).
        let prompt = StrawHatTurn.prompt(context: context, message: trimmed)

        // M2.5b: health is in-process app state, so the `health_snapshot`
        // tool reads a file the app writes instead of opening a store. Written
        // *before* the process starts, and from the same snapshot the
        // `[CONTEXT]` block above was rendered from, so the pushed and pulled
        // views of health cannot disagree within one turn. A write failure is
        // logged and survivable - the tool then reports an honest read
        // failure, never a healthy machine.
        if let tools, let context {
            tools.writeHealthSnapshot(context.healthBridgePayload())
        }

        runOnce(prompt: prompt, resumeSessionID: resume, token: token) { [weak self] result in
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
                // The recovered turn carries the same snapshot as the one it
                // replaces: the thread is what was lost, not the context, and
                // a recovery that silently dropped it would answer with less
                // than the failed attempt had.
                let recapped = StrawHatTurn.prompt(context: context,
                                                   recap: Self.recapLines(self.transcript),
                                                   message: trimmed)
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
        transcript.append(Turn(captain: captain, crew: reply.text))
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
            extraArguments: Self.arguments(tools: tools),
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

    /// Every turn's `claude` arguments beyond the prompt itself.
    ///
    /// `static` and taking the session explicitly so `StrawHatMCPSelfTest`
    /// can assert the exact argv - including the negative half, that
    /// `--permission-mode` never appears - without spawning anything.
    ///
    /// With no tool session this is byte-for-byte phase 2's argv: the persona
    /// and nothing else. `--strict-mcp-config` is what stops `claude` also
    /// loading whatever MCP servers the captain has configured globally for
    /// their own use, so the crew's surface is exactly the four tools below
    /// and not a superset that varies per machine.
    static func arguments(tools: StrawHatToolSession?) -> [String] {
        var args = ["--append-system-prompt", StrawHatCrew.persona]
        guard let tools else { return args }
        args += [
            "--mcp-config", tools.mcpConfigPath.path,
            "--strict-mcp-config",
            "--allowedTools", StrawHatCrew.allowedTools,
        ]
        return args
    }

    /// The recovery prompt's recap half, kept as this class's own entry point
    /// because `StrawHatSelfTest` asserts its shape directly and because
    /// "how much of the transcript does a recovery carry" is this runner's
    /// decision, not the envelope's.
    ///
    /// The labelling itself belongs to `StrawHatTurn.prompt`, which owns all
    /// three of a turn's blocks - see its own note on why that is one place
    /// rather than two. `internal` so the suite can call it with no
    /// subprocess.
    static func promptWithRecap(message: String, transcript: [String]) -> String {
        StrawHatTurn.prompt(context: nil, recap: transcript, message: message)
    }

    /// The in-memory transcript flattened into the alternating speaker lines a
    /// recap carries. Attributed to the crew as a whole rather than to Luffy
    /// by name: phase 2's replies can carry several voices, and re-labelling
    /// every past reply as his would tell a recovered session that Nami's
    /// task proposals were his.
    private static func recapLines(_ transcript: [Turn]) -> [String] {
        transcript.flatMap { ["Captain: \($0.captain)", "Crew: \($0.crew)"] }
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

    /// This conversation's tool session, so a suite can read the MCP config
    /// this runner actually wrote and the health file it actually rewrites.
    var debugTools: StrawHatToolSession? { tools }

    /// The argv this runner would pass, with its real session.
    var debugArguments: [String] { Self.arguments(tools: tools) }
    #endif
}
