// Manjesh Grand Line - native macOS app.
//
// "Claude writes per-shot prompts" - the one AI-authorship step the original
// ask named directly. A single, stateless, non-interactive `claude -p ...
// --output-format json` call rewriting a rough idea into a detailed
// text-to-video prompt, via `ClaudeOneShot` (GL-26's shared one-shot runner -
// this is its sixth caller, after `SRELeadRunner`, `SRELeadPostmortem`,
// `DictationCleanup`, `ConsoleCommandComposer`, `LogAnalyzerAI`). Mirrors
// `DictationCleanup.swift`'s exact shape - same reasoning applies here: no
// conversation to resume, no MCP tool, so a second small type is clearer
// than stretching `SRELeadRunner`.
//
// Optional by design, matching `DictationCleanup`'s own "Clean up my
// sentences" toggle: a captain can type a prompt directly (the exact path
// the scout's own validation used - "a calm ocean at sunset" typed verbatim)
// or turn this on to have Claude expand a rough idea first. A failure here
// (no network, not authenticated, `claude` missing, a garbled reply) never
// blocks generation - `VideoGenController` falls back to the captain's own
// typed text.

import Foundation

enum VideoPromptEnhancer {

    /// Same bound as `DictationCleanup.timeout` and for the same reason - a
    /// captain waiting to click Generate should not be held up by a slow/
    /// unreachable network call for long.
    static let timeout: TimeInterval = 20

    static func prompt(for idea: String) -> String {
        """
        Rewrite the following rough video idea into a single, vivid, concrete \
        prompt for an AI text-to-video model. Describe the subject, setting, \
        lighting, and camera framing in 1-3 sentences. Preserve the original \
        intent exactly - do not invent a different scene or add unrelated \
        elements. Reply with ONLY the rewritten prompt and nothing else - no \
        quotes, no preamble, no explanation.

        Idea:
        \(idea)
        """
    }

    /// Test-only seam, same convention as `DictationCleanup
    /// .claudePathOverrideForTests` - a real, disposable fake-`claude` script
    /// in tests, never the real binary or a real network call.
    static var claudePathOverrideForTests: String?

    static func enhance(_ idea: String, completion: @escaping (Result<String, VideoGenError>) -> Void) {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(VideoGenError(message: "Describe what you want to generate first.")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(VideoGenError(message: "claude is not installed or not on PATH")))
            return
        }

        ClaudeOneShot.run(
            executable: claude, prompt: prompt(for: trimmed),
            timeout: timeout, label: "claude -p (video prompt)"
        ) { result in
            switch result {
            case .success(let reply):
                let cleaned = stripWrappingQuotes(reply.text)
                if cleaned.isEmpty {
                    completion(.failure(VideoGenError(message: "Claude's rewrite was empty.")))
                } else {
                    completion(.success(cleaned))
                }
            case .failure(let error):
                completion(.failure(VideoGenError(message: error.message)))
            }
        }
    }

    /// Defensive only, same as `DictationCleanup.stripWrappingQuotes` - not
    /// load-bearing for the common case.
    private static func stripWrappingQuotes(_ text: String) -> String {
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs {
            if text.count >= 2, text.first == open, text.last == close {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }
}
