// Manjesh Grand Line - native macOS app.
//
// F4's optional one-paragraph summary, through `ClaudeOneShot` (GL-26) and
// nothing else. No second `Process` setup, no second JSON parse, no second
// timeout constant - see that file's header for the five copies this app
// already consolidated once.
//
// ## Why it is opt-in per card rather than automatic
//
// The report says "optional AI one-paragraph summary", and the firstmate spec
// asked for the reasoning to be stated rather than assumed. Three things
// decided it, and the mockup the captain reviewed already draws the answer -
// one card carries a summary, one carries a **Summarise** button, one needed
// neither:
//
//   - **A paste is not a request.** ⌥Space and a drop are one gesture each;
//     spending a `claude -p` turn on every one of them makes a keystroke cost
//     money and several seconds of somebody's rate limit, for a card the
//     captain may be filing precisely because they have not decided to read
//     it yet.
//   - **It would be unbounded.** Dropping a browser window's worth of tabs is
//     a normal thing to do with a link inbox, and twenty automatic turns from
//     one drop is exactly the "nothing unbounded" GL-35 is about.
//   - **The state is the feature.** Summarised / not-summarised is the most
//     useful axis the list has after read/unread - it is one of the three
//     segmented tabs - and it only means anything if it records a decision
//     rather than how long the fetch queue was.
//
// So: a button on the card, one turn per press, and the result stored so it is
// never fetched twice.
//
// ## What the model is given, and what it is not
//
// The title, the host and the page's own description - never the page body,
// because this app never fetches one (`LinkPresentation` returns metadata, and
// the reader's `WKWebView` content is the web view's, not ours). That is a
// real limit and it is stated on the card: the paragraph is written from the
// page's own summary, not from having read it. Claiming otherwise would be
// the kind of false claim GL-14 exists to keep out of this app.
//
// `--tools` defaults to none through `ClaudeOneShot.run` (full review #3's
// S1), which is the whole point of routing through it: this caller names no
// built-in tool, so it gets none, and the captain's ambient `permissions.allow`
// cannot widen that.

import Foundation

struct ReadingListAIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum ReadingListAI {

    /// Short, like `DictationCleanup`'s and for the same reason: this sits
    /// between the captain and a card they are looking at. A turn that has not
    /// answered by now has lost the captain's attention, and the card says so
    /// rather than spinning.
    static let timeout: TimeInterval = 45

    /// The longest a stored paragraph may be.
    ///
    /// A cap, not a target: the prompt asks for one paragraph, and a model
    /// that answers with five would otherwise put five into a git-synced YAML
    /// file and into a 320pt card. Elided rather than refused - a long answer
    /// is still a useful answer, and refusing would spend the turn for
    /// nothing.
    static let maximumSummaryLength = 700

    /// Test-only seam, the same convention every other `claude -p` caller in
    /// this app uses (`DictationCleanup.claudePathOverrideForTests`,
    /// `CommandLibraryAI.claudePathOverrideForTests`): a suite points this at
    /// a fake `claude` script and drives the real argv, the real parse and the
    /// real completion contract.
    static var claudePathOverrideForTests: String?

    /// The prompt.
    ///
    /// Shaped like `CaptureRouter.classificationPrompt` - one instruction, an
    /// explicit output contract, no room for prose - because the same thing is
    /// true here: the reply is *stored and rendered*, not read once. The
    /// honesty clause at the end is load-bearing rather than polite: without
    /// it a model asked to summarise a URL will happily invent the article.
    static func prompt(title: String, host: String, url: String, pageSummary: String) -> String {
        let titleLine = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryLine = pageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        var known = """
        - URL: \(url)
        - Site: \(host)
        """
        if !titleLine.isEmpty { known += "\n- Title: \(titleLine)" }
        if !summaryLine.isEmpty { known += "\n- The page's own description: \(summaryLine)" }

        return """
        Write one short paragraph - three sentences at most - saying what this \
        saved link is about and who would want to read it. Write it for the \
        person who saved it, in plain technical English.

        You have not read the page. Work only from what is listed below. If it \
        is not enough to say anything specific, say exactly what the title and \
        the site tell you and no more - do not invent findings, numbers, \
        conclusions or section headings that are not in the material given.

        Answer with the paragraph and nothing else: no heading, no bullet \
        points, no code fences, no preamble such as "This article".

        What is known:
        \(known)
        """
    }

    /// Read a paragraph out of the reply.
    ///
    /// Tolerant about the shapes a model actually produces - a wrapping quote
    /// pair, a code fence, a "Summary:" label, blank lines between paragraphs
    /// - and intolerant about nothing else, because unlike
    /// `CaptureRouter.parseClassification` there is no enumerated answer to
    /// check against. An empty result after cleaning is a failure: an empty
    /// paragraph stored on the card would read as "summarised" in the tab
    /// strip while saying nothing.
    static func parse(_ reply: String) -> String? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // Drop the opening fence line and a closing fence if there is one.
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["Summary:", "summary:", "TL;DR:", "tl;dr:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        // A paragraph, not a document: internal newlines are folded so the
        // card's own wrapping decides the line breaks rather than the model's.
        text = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > maximumSummaryLength else { return text }
        return String(text.prefix(maximumSummaryLength)) + "\u{2026}"
    }

    /// Summarise one link. `completion` runs on the main thread exactly once -
    /// `ClaudeOneShot.run`'s own contract, not a second hand-rolled one.
    static func summarise(_ link: ReadingLink,
                          timeout: TimeInterval = timeout,
                          completion: @escaping (Result<String, ReadingListAIError>) -> Void) {
        guard let claude = claudePathOverrideForTests ?? ClaudeOneShot.resolve() else {
            completion(.failure(ReadingListAIError(
                message: "The claude CLI was not found on this machine, so nothing can be summarised.")))
            return
        }
        ClaudeOneShot.run(executable: claude,
                          prompt: prompt(title: link.title,
                                         host: link.host,
                                         url: link.url,
                                         pageSummary: link.summary),
                          timeout: timeout,
                          label: "claude -p (reading list summary)") { result in
            switch result {
            case .success(let reply):
                guard let paragraph = parse(reply.text) else {
                    completion(.failure(ReadingListAIError(message: "claude's summary was empty.")))
                    return
                }
                completion(.success(paragraph))
            case .failure(let error):
                completion(.failure(ReadingListAIError(message: error.message)))
            }
        }
    }
}
