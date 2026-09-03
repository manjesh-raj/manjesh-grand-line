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
//
// `reviseForFeedback(prompt:feedback:completion:)` (fm/grandline-videogen-
// settings-fix's expanded scope - the feedback-driven regeneration loop) is
// the *same* one-shot mechanism, a second prompt template on the identical
// `ClaudeOneShot.run` call - not a second Claude-calling path. It folds a
// captain's "what should change?" note into the prompt that produced the
// clip they're looking at, and - like `enhance` above - always shows the
// revised prompt to the captain before anything regenerates
// (`VideoGenController` sets `promptField.stringValue` to the reply exactly
// as `generateTapped`'s existing enhance branch already does); a failure
// here is reported, never silently substituted.

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

    /// The revision half of the feedback loop - folds `feedback` into
    /// `currentPrompt`, keeping everything about the current prompt that the
    /// feedback doesn't address.
    static func revisionPrompt(currentPrompt: String, feedback: String) -> String {
        """
        You wrote the following prompt for an AI text-to-video model. The \
        captain watched the resulting clip and left feedback on what should \
        change. Revise the prompt to address the feedback, keeping everything \
        else about the scene, subject, and framing the same unless the \
        feedback implies otherwise. Reply with ONLY the revised prompt and \
        nothing else - no quotes, no preamble, no explanation.

        Current prompt:
        \(currentPrompt)

        Feedback:
        \(feedback)
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

    /// Folds captain feedback ("the water is too still, make it choppier")
    /// into `currentPrompt` via one `ClaudeOneShot` call - the exact same
    /// mechanism `enhance` above uses, a different prompt template only.
    static func reviseForFeedback(
        currentPrompt: String, feedback: String,
        completion: @escaping (Result<String, VideoGenError>) -> Void
    ) {
        let trimmedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFeedback.isEmpty else {
            completion(.failure(VideoGenError(message: "Say what should change first.")))
            return
        }
        let trimmedPrompt = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            completion(.failure(VideoGenError(message: "There's no prompt to revise yet.")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(VideoGenError(message: "claude is not installed or not on PATH")))
            return
        }

        ClaudeOneShot.run(
            executable: claude,
            prompt: revisionPrompt(currentPrompt: trimmedPrompt, feedback: trimmedFeedback),
            timeout: timeout, label: "claude -p (video prompt revision)"
        ) { result in
            switch result {
            case .success(let reply):
                let cleaned = stripWrappingQuotes(reply.text)
                if cleaned.isEmpty {
                    completion(.failure(VideoGenError(message: "Claude's revision was empty.")))
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
