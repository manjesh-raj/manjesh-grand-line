// Manjesh Grand Line - native macOS app.
//
// Dictation, phase 3 (fm/grandline-dictation-phase3): the "clean up my
// sentences" polish pass. When the Dictation page's "Clean up my sentences"
// toggle is on, a raw transcript is rewritten into a well-formed sentence via
// a single non-interactive `claude -p ... --output-format json` call before
// it's pasted/recorded - the exact same invocation shape `SRELeadRunner.swift`
// already established (see that file's own header for the full reasoning:
// `json` over `stream-json` since only the final reply text is ever needed,
// `/dev/null` stdin to skip `claude -p`'s ~3s piped-stdin probe, draining both
// pipes before `waitUntilExit()` to avoid a full-buffer deadlock).
//
// Deliberately NOT reusing `SRELeadRunner` itself: that type threads a
// `session_id` across turns via `--resume` for a multi-turn conversation
// pane, carries an MCP config + a restricted `--allowedTools`/persona for the
// kubectl tool, and reports failures into `SRELeadChatView`'s chat feed. This
// is a single, stateless one-shot rewrite per dictation with no conversation
// to resume and no MCP tool involved - a second, smaller type mirroring
// `SRELeadRunner`'s `Process`/argument/parsing shape was clearer than
// stretching that one to cover both call shapes. `SRELead.resolveClaude()` is
// reused as-is (it's already `internal`, built for exactly this kind of
// second caller - see its own doc comment).
//
// Real response shape, verified live rather than assumed (see this task's PR
// description for the actual transcript): `claude -p "<prompt>" --output-
// format json` with a plain rewrite instruction returns `result` as clean
// text with no wrapping quotes or preamble - matching the persona-free,
// system-prompt-free single-turn case (SRE Lead's own persona is what
// produces its `**Finding:**`-labeled structure; a bare `-p` prompt with no
// system prompt does not add that kind of framing on its own). `cleanedText`
// still strips a leading/trailing straight or curly quote pair defensively,
// since a model can occasionally wrap a "rewrite this text" answer in quotes
// depending on phrasing - cheap insurance, not something depended on to make
// the feature work.
//
// This step needs network access and the captain's own already-authenticated
// `claude` CLI - unlike every other step in the Dictation pipeline, which is
// fully on-device/offline (see `DictationEngine.swift`'s header). A failure
// here (no network, not authenticated, `claude` not on PATH, a bad/garbled
// response) always falls back to the raw transcript rather than losing or
// blocking the dictation - `DictationEngine.finish(text:)` is the one call
// site, and it never waits on this indefinitely either (see `timeout` below).
//
// Vocabulary-aware correction (captain report: "an herdr session" reliably
// transcribed as "an older session" - a common word beating a custom
// vocabulary word, even with that word already in "Words I use often" and
// therefore already wired into `SFSpeechRecognitionRequest.contextualStrings`
// - see `DictationEngine.beginCapture`). `contextualStrings` is a flat array
// with no per-word weight/priority knob - there is no dial to turn up a
// single word's influence beyond what's already applied live, during
// recognition. This rewrite pass is the one place in the pipeline that sees
// the *whole* finished sentence at once, which is exactly the extra signal a
// human proofreader would use to catch "an older session" next to
// fleet/terminal-shaped words and realize it should read "an herdr session" -
// so `prompt(for:vocabulary:)` now also asks the model to make that specific
// kind of correction, using the captain's own vocabulary list
// (`DictationStore.vocabulary`, the same list `contextualStrings` already
// reads) as the set of words worth checking for.
//
// This rides on the *existing* "Clean up my sentences" toggle rather than
// getting a second one, deliberately: both the sentence rewrite and this
// correction need the identical network+`claude`-CLI dependency, so a second
// toggle would either be redundant (needing both switches on to get vocabulary
// correction) or would mean a second, separate `claude -p` call purely for
// vocabulary correction - doubling latency/API calls for a captain who wants
// both, for no capability the combined single-call version doesn't already
// provide. The captain's own report described exactly what one whole-sentence
// rewrite pass already does (use surrounding context, not a single word in
// isolation) - see this task's PR description for the fuller reasoning.
//
// Over-correction is a real, named risk, not just an under-correction one: a
// genuinely-meant "an older session" must not be turned into "an herdr
// session" just because "herdr" happens to be on the list. `prompt(for:
// vocabulary:)` states the guard explicitly (only correct when the rest of
// the sentence actually supports the vocabulary reading) rather than only
// asking for corrections and hoping restraint follows.

import Foundation

/// Rewrites a raw transcript into a well-formed sentence via one non-
/// interactive `claude -p` call - and, in the same pass, corrects a word or
/// short phrase that's a plausible phonetic near-match for one of the
/// captain's own vocabulary words when the rest of the sentence supports that
/// reading. Stateless - a fresh instance's `rewrite` call is independent of
/// any other; there is no conversation to resume.
enum DictationCleanup {
    /// Bounded wait for the whole `claude -p` round trip - a rewrite that
    /// takes meaningfully longer than this is assumed hung/unreachable, and
    /// the caller falls back to the raw transcript rather than blocking a
    /// dictation indefinitely on a network call. Generous relative to a
    /// typical `claude -p` turn (SRE Lead's own turns routinely complete in a
    /// few seconds) while still being far short of "the captain gives up."
    static let timeout: TimeInterval = 20

    /// `vocabulary` is the captain's own "Words I use often" list
    /// (`DictationStore.vocabulary`) - empty when he hasn't configured any,
    /// in which case the prompt carries no vocabulary-correction instruction
    /// at all (nothing to check against, so nothing to ask for).
    static func prompt(for transcript: String, vocabulary: [String] = []) -> String {
        var sections = [
            """
            Rewrite the following rough, spoken transcript as a single grammatically \
            correct, well-formed piece of text. Fix filler words, false starts, and \
            awkward phrasing, but preserve the original meaning and intent exactly - \
            do not add information, opinions, or commentary.
            """
        ]

        if !vocabulary.isEmpty {
            let list = vocabulary.map { "- \($0)" }.joined(separator: "\n")
            sections.append(
                """
                The speaker has a personal vocabulary of words/phrases the speech \
                recognizer sometimes mishears as a common, similar-sounding word or \
                phrase, because their custom words compete against far more common \
                words during recognition:
                \(list)

                Check the transcript for a word or short phrase that's a plausible \
                phonetic near-match for one of these vocabulary entries, and correct \
                it to the vocabulary spelling ONLY when the rest of the sentence \
                actually supports that reading (e.g. "an older session" next to \
                fleet/terminal-related words strongly implies the vocabulary word \
                "herdr", not a coincidental "older"). Do not force a vocabulary word \
                in where it doesn't genuinely fit the sentence's own meaning - a word \
                the speaker plainly meant to say (a genuine "older", "brook", "sea", \
                etc.) must be left exactly as it is, even if it superficially \
                resembles a vocabulary entry. When you're not confident a mismatch is \
                really a misrecognition of a vocabulary word, leave the transcript's \
                own wording alone.
                """
            )
        }

        sections.append(
            """
            Reply with ONLY the rewritten text and nothing else - no quotes, no \
            preamble, no explanation.

            Transcript:
            \(transcript)
            """
        )

        return sections.joined(separator: "\n\n")
    }

    /// Runs the rewrite. `completion` is always called on the main thread,
    /// exactly once, with `.success(rewritten)` or `.failure(reason)` - the
    /// caller (`DictationEngine.finish`) treats any failure as "fall back to
    /// the raw transcript," so `reason` only matters for whatever debug
    /// logging a caller chooses to do with it, never for control flow beyond
    /// success/failure.
    /// Test-only seam: `DictationCleanupSelfTest` points this at a real,
    /// disposable fake-`claude` script (never the real `claude` binary) so it
    /// can drive `rewrite`'s actual `Process`/parsing code end to end without
    /// depending on real network access or the machine's own Claude auth.
    /// `nil` (the production default) means "resolve the real `claude` via
    /// `SRELead.resolveClaude()`, exactly as before this seam existed."
    static var claudePathOverrideForTests: String?

    /// `vocabulary` is the captain's current "Words I use often" list,
    /// threaded straight through to `prompt(for:vocabulary:)` - see this
    /// file's header for why this rides on the same call rather than a
    /// second one. Defaults to empty so every pre-existing caller (and this
    /// file's own self-test) keeps its original behavior unless it opts in.
    static func rewrite(_ transcript: String, vocabulary: [String] = [], completion: @escaping (Result<String, DictationCleanupError>) -> Void) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(DictationCleanupError(message: "empty transcript")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(DictationCleanupError(message: "claude is not installed or not on PATH")))
            return
        }

        // GL-26: the `Process` setup, the finish-exactly-once lock and the
        // JSON parse this function used to own are all `ClaudeOneShot` now -
        // one copy shared with the other four `claude -p` callers. The
        // behaviour this call site cares about is unchanged: bounded by
        // `timeout`, completion always on the main thread exactly once, and any
        // failure means "fall back to the raw transcript".
        ClaudeOneShot.run(executable: claude, prompt: prompt(for: trimmed, vocabulary: vocabulary),
                          timeout: timeout, label: "claude -p (dictation cleanup)") { result in
            switch result {
            case .success(let reply):
                // Defensive only - see this file's header on why the quote
                // stripping is not load-bearing for the common case.
                let cleaned = stripWrappingQuotes(reply.text)
                if cleaned.isEmpty {
                    completion(.failure(DictationCleanupError(message: "claude's rewrite was empty.")))
                } else {
                    completion(.success(cleaned))
                }
            case .failure(let error):
                completion(.failure(DictationCleanupError(message: error.message)))
            }
        }
    }

    /// Defensive only - see this file's header for why this isn't load-
    /// bearing for the feature to work in the common case.
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

struct DictationCleanupError: Error {
    let message: String
}
