// Manjesh Grand Line - native macOS app.
//
// Runs one non-interactive `claude -p ... --output-format json` process per
// SRE Lead question/follow-up and hands back just the assistant's final
// reply text - see `SRELead.swift`'s header for why this replaced the
// tmux-mirrored interactive `claude` TUI this pane used to run.
//
// `--output-format json` (a single JSON object on completion), not
// `stream-json`: the pane only ever needs to render the assistant's final
// reply as one message block (`SRELeadChatView`), never partial/incremental
// text or the intermediate tool-call events a streaming parser would also
// have to handle - `json` gets the same information with a far simpler,
// less fragile parse (one `JSONSerialization` call on one line of output,
// no line-buffering or event-type dispatch to get right without a real
// cluster to test against).
//
// Multi-turn context: confirmed live (`claude --help`, then a real two-call
// local test) that `-r`/`--resume <session_id>` works with `-p`/`--print` -
// the first call's response JSON carries a `session_id`, and passing that
// back via `--resume` on the next call continues the same conversation.
// `SRELeadRunner` tracks the most recent `session_id` and threads it through
// automatically; the caller never has to think about it.

import Foundation

/// One SRE Lead session's turn-by-turn `claude -p` runner. Not thread-safe
/// for concurrent `ask` calls - `SRELeadChatView`'s send button is disabled
/// while a turn is in flight, so callers should not need to serialize this
/// themselves, but `ask` does not defend against it either.
final class SRELeadRunner {
    private let session: SRELeadSession
    private let claude: String
    private var sessionID: String?
    /// Cancellation handle for the turn currently in flight, so the pane can
    /// tear down a running `claude` when it closes. GL-15/GL-26 replaced the
    /// raw `Process` this used to hold - `SubprocessCancellation` is the seam
    /// `Subprocess` exposes for exactly this, so a caller can stop a run
    /// without this file owning process plumbing again.
    private var inFlight: SubprocessCancellation?

    init(session: SRELeadSession, claude: String) {
        self.session = session
        self.claude = claude
    }

    /// Ask one question. `completion` is always called on the main thread.
    func ask(_ question: String, completion: @escaping (Result<String, SRELeadSetupError>) -> Void) {
        let extraArgs = Self.arguments(session: session)

        // GL-26: this was the one of the five `claude -p` callers with *no*
        // timeout at all, so a wedged `claude` left a turn spinning forever with
        // no way out but closing the pane. It is bounded now, deliberately
        // generously - a real turn can run several bridged `kubectl` calls
        // through the captain's own terminal. **This is a called-out behaviour
        // change**, not an accident of the migration.
        inFlight = ClaudeOneShot.run(
            executable: claude,
            prompt: question,
            extraArguments: extraArgs,
            builtInTools: SRELead.builtInTools,
            resumeSessionID: sessionID,
            cwd: session.workingDir,
            timeout: ClaudeOneShot.conversationTimeout,
            label: "claude -p (SRE Lead)"
        ) { [weak self] result in
            guard let self else { return }
            self.inFlight = nil
            switch result {
            case .success(let reply):
                // Threading the session id back through `--resume` is what
                // makes the pane a conversation rather than a series of
                // unrelated questions.
                if let sid = reply.sessionID { self.sessionID = sid }
                completion(.success(reply.text))
            case .failure(let error):
                completion(.failure(SRELeadSetupError(message: error.message)))
            }
        }
    }

    /// Every turn's `claude` arguments beyond the prompt and `--tools`.
    ///
    /// `static` and taking the session explicitly so
    /// `ClaudeOneShotToolPolicySelfTest` can assert the exact argv - including
    /// the negative half, that `--permission-mode` never appears again - the
    /// same shape `StrawHatRunner.arguments(tools:)` already had.
    ///
    /// ## Why `--permission-mode bypassPermissions` is gone
    ///
    /// Full review #3's S1. This runner predated `StrawHatRunner` and carried
    /// the flag from its first version; `StrawHatTools.swift`'s header had
    /// already measured, with a throwaway MCP server, that `--allowedTools`
    /// alone both permits a listed tool and denies an unlisted one, so the
    /// flag was buying nothing even then - and it actively widened the one
    /// gap S1 is about, since `bypassPermissions` turns off permission
    /// checking for the whole session.
    ///
    /// Re-measured for this fix against a real `claude -p`: with `--tools`
    /// naming only `Task,TodoWrite`, a Bash request was refused **even with
    /// `--permission-mode bypassPermissions` still passed** - so `--tools` is
    /// the layer doing the work, and dropping the flag costs this pane
    /// nothing. Its kubectl tool is reached through `--allowedTools`, exactly
    /// as the crew's four tools are.
    static func arguments(session: SRELeadSession) -> [String] {
        [
            "--mcp-config", session.mcpConfigPath.path,
            "--strict-mcp-config",
            "--append-system-prompt", SRELead.persona,
            "--allowedTools", SRELead.allowedTools,
        ]
    }

    /// Best-effort kill of an in-flight turn - called when the pane closes.
    /// Safe to call whether or not a turn is running.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }
}
