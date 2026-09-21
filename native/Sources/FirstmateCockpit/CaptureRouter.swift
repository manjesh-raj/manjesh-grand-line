// Manjesh Grand Line - native macOS app.
//
// F2 of full review #3 §8, "Universal capture (⌥Space grows up)".
//
// ⌥Space used to do exactly one thing: create a Shift task. The report's
// finding is that the panel, the parser and every destination store already
// existed, so the only thing missing was the *routing* - "type text, then ⌘1
// task / ⌘2 sticky / ⌘3 note / ⌘4 credential / ⌘5 code snippet, with the
// pasteboard pre-filled and an 'ask the crew to file it' option".
//
// **This file is the pure-logic half, and it owns no AppKit.** The panel
// (`ShiftQuickCaptureController`) draws the five tiles and reads the chords;
// the shell (`AppShellController.fileCapture`) owns the five stores. What
// lives here is everything in between that is a *decision* rather than a view
// or a write: which digit means which destination, how one typed line is split
// into the fields each store actually needs, what the crew is asked when the
// captain would rather not choose, and how the crew's answer is read back.
//
// Splitting it out this way is not tidiness - it is AGENTS.md's own self-test
// classification rule applied before the code is written. Every rule below is
// assertable with no window at all, so `CaptureRouterSelfTest` guards CI's
// **blocking** lane; only the panel's own geometry and key handling need a
// session, and those are `CaptureRouterViewSelfTest`'s.

import Foundation

// MARK: - The five destinations

/// Where a captured line can be filed.
///
/// The order is the report's own (`⌘1` task ... `⌘5` code snippet) and it is
/// load-bearing twice over: `chordDigit` is derived from it rather than
/// written out a second time, and the panel lays its tiles out in
/// `allCases` order, so the printed chord under a tile cannot drift from the
/// key that actually fires it.
enum CaptureDestination: String, CaseIterable {
    case task
    case sticky
    case note
    case credential
    case codeSnippet

    /// `1`...`5`, derived from the case order - see the type's own note.
    var chordDigit: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    /// What the tile is labelled. Short on purpose: five of these sit in a
    /// 600pt panel, so "Credential" is as long as any of them may be.
    var title: String {
        switch self {
        case .task: return "Task"
        case .sticky: return "Sticky"
        case .note: return "Note"
        case .credential: return "Credential"
        case .codeSnippet: return "Snippet"
        }
    }

    /// The SF Symbol on the tile. Each is the symbol its own destination
    /// already uses elsewhere in the app, so the tile reads as a shortcut to
    /// a page the captain knows rather than as new iconography.
    var symbol: String {
        switch self {
        case .task: return "checkmark.circle"
        case .sticky: return "note.text"
        case .note: return "book.closed"
        case .credential: return "key.fill"
        case .codeSnippet: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The tile's identity colour. `HelmDomainHue`, not a `HelmTint`: a tile
    /// says "this is the Sticky Board", never "this is a warning" - and
    /// routing a domain hue through `fallbackTint` is the exact defect
    /// `HelmDomainHue.identityHex(in:)` exists to stop (see
    /// `RecentDestinationsPopover.makeRow`'s own note about the red alert bar
    /// it once painted on a Recents row).
    var hue: HelmDomainHue {
        switch self {
        case .task: return .violet
        case .sticky: return .amber
        case .note: return .blue
        case .credential: return .rose
        case .codeSnippet: return .teal
        }
    }

    /// The destination this files into, for the panel's confirmation line and
    /// for the shell's own navigation.
    var railDestination: RailDestination {
        switch self {
        case .task: return .shift
        case .sticky: return .stickyBoard
        case .note: return .notebook
        case .credential: return .poneglyph
        case .codeSnippet: return .codePreview
        }
    }

    /// What the panel says after a successful file. Present tense and
    /// specific: "landed in My Tasks" is what the pre-F2 panel said, and the
    /// other four follow its shape.
    var confirmation: String {
        switch self {
        case .task: return "Captured \u{2014} landed straight in My Tasks."
        case .sticky: return "Captured \u{2014} pinned to the Sticky Board."
        case .note: return "Captured \u{2014} filed as a Notebook page."
        case .credential: return "Opening Poneglyph with it filled in\u{2026}"
        case .codeSnippet: return "Captured \u{2014} saved as a code snippet."
        }
    }

    /// The digit-to-destination map, as one function.
    ///
    /// Returns nil for anything outside 1...5 rather than clamping: a ⌘6 that
    /// silently filed a task would be worse than a ⌘6 that does nothing.
    static func forChordDigit(_ digit: Int) -> CaptureDestination? {
        allCases.first { $0.chordDigit == digit }
    }
}

// MARK: - The draft

/// One captured line, plus everything derived from it that a store needs.
///
/// Built once, in `CaptureRouter.draft(from:)`, and handed to whichever
/// destination the captain picks - so ⌘1 and ⌘3 see byte-for-byte the same
/// parse of the same text. Before F2 the parse happened inside the capture
/// function itself and there was only one destination to disagree with.
struct CaptureDraft: Equatable {
    /// Exactly what was typed, trimmed. Never lost: every destination stores
    /// this somewhere, even when it also stores a derived title.
    let text: String
    /// The first line, for the destinations whose row is one line (a task
    /// title, a notebook page title, a snippet label).
    let title: String
    /// Everything after the first line, or "" when the capture is one line.
    let body: String
    /// `ShiftDateParser`'s reading of the text, when it found one. The panel
    /// draws this as a chip so the router never silently guesses.
    let dueDate: Date?
    /// Whether the parsed date carried a time of day - `ShiftDateParser`'s
    /// own distinction, preserved because "Friday" and "Friday 3pm" are
    /// different due dates, not the same one rounded.
    let dueHasTime: Bool

    /// Empty text is the one state every caller has to reject, so it is named
    /// here rather than re-derived at four call sites.
    var isEmpty: Bool { text.isEmpty }
}

// MARK: - The router

enum CaptureRouter {

    /// The longest a derived one-line title may be before it is elided.
    ///
    /// A captured paste can be a 4KB stack trace; a Notebook page called
    /// "Traceback (most recent call last): File "/usr/lib/python3..." is not a
    /// page anyone finds again. 72 is the width at which the app's own row
    /// titles start truncating on a 1512pt window, so nothing is lost on
    /// screen that this does not already cost.
    static let derivedTitleLimit = 72

    /// Parse one captured string into a draft.
    ///
    /// `now` is injected for the same reason `ShiftDateParser.parse` takes it:
    /// "tomorrow" is a function of the clock, and a test that cannot pin the
    /// clock cannot assert the parse.
    static func draft(from raw: String, now: Date = Date()) -> CaptureDraft {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let rest = text.dropFirst(firstLine.count).drop(while: { $0 == "\n" })
        let parsed = text.isEmpty ? nil : ShiftDateParser.parse(text, now: now)
        return CaptureDraft(
            text: text,
            title: elide(firstLine.trimmingCharacters(in: .whitespaces)),
            body: String(rest),
            dueDate: parsed?.date,
            dueHasTime: parsed?.hasTime ?? false)
    }

    /// A one-line title, never longer than `derivedTitleLimit`.
    ///
    /// Elides on a word boundary when there is one in the last quarter of the
    /// budget, so a truncated title ends at a word rather than mid-token - and
    /// falls back to a hard cut when there is not, which is the usual case for
    /// the pasted URLs and ARNs this feature exists to catch.
    static func elide(_ line: String, limit: Int = derivedTitleLimit) -> String {
        guard line.count > limit else { return line }
        let cut = String(line.prefix(limit))
        let breakpoint = cut.lastIndex(of: " ")
        if let breakpoint, cut.distance(from: cut.startIndex, to: breakpoint) > (limit * 3) / 4 {
            return String(cut[cut.startIndex..<breakpoint]) + "\u{2026}"
        }
        return cut + "\u{2026}"
    }

    // MARK: Per-destination field derivation

    /// The label a code snippet is saved under.
    ///
    /// Sanitised through `CodePreviewStore.sanitize` here rather than at the
    /// write, because the panel shows the captain what it is about to be
    /// called and the two must agree. An empty result after sanitising (a
    /// capture that is nothing but punctuation) falls back to a dated name,
    /// since a file needs *some* name and a silent refusal is the worse
    /// outcome for a capture the captain has already typed.
    static func snippetName(for draft: CaptureDraft, now: Date = Date()) -> String {
        // `CodePreviewStore.sanitize` never returns empty - it substitutes
        // `snippet.txt` - so whether a real title survived has to be decided
        // from its *input*, not from its output. A capture that is nothing but
        // punctuation sanitises to that same substitute, which is why both
        // halves are checked.
        let stem = CodePreviewStore.sanitize(draft.title)
        let usable = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && stem != CodePreviewStore.sanitize("")
        return usable ? stem : "capture-\(Self.fileStamp(now)).txt"
    }

    /// The title a Notebook page is created under. Same fallback reasoning as
    /// `snippetName`, and the same stamp, so two captures in the same minute
    /// never collide silently.
    static func notebookTitle(for draft: CaptureDraft, now: Date = Date()) -> String {
        draft.title.isEmpty ? "Capture \(Self.stamp(now))" : draft.title
    }

    /// The title a drafted credential is opened with.
    ///
    /// Deliberately **not** the captured text: ⌘4's whole point is that the
    /// captured string is the *secret*, and a secret is not a title. The
    /// credential opens titled by when it was captured and with the secret in
    /// the secret field, for the captain to name properly in the editor.
    static func credentialTitle(now: Date = Date()) -> String {
        "Captured \(Self.stamp(now))"
    }

    /// `2026-09-21 15:04`, the app's own already-used shape for a dated name.
    static func stamp(_ now: Date) -> String { formatted(now, "yyyy-MM-dd HH:mm") }

    /// The same instant with nothing a filename would have to be cleaned of -
    /// `sanitize` would turn the `:` in `stamp` into a `-` anyway, and a name
    /// the store silently rewrites is a name the panel showed wrong.
    static func fileStamp(_ now: Date) -> String { formatted(now, "yyyy-MM-dd-HHmm") }

    private static func formatted(_ now: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: now)
    }

    // MARK: "Ask the crew to file it"

    /// The prompt handed to `claude -p` when the captain presses the crew
    /// button instead of choosing a destination.
    ///
    /// Shaped the way `DictationCleanup.prompt(for:vocabulary:)` is - one
    /// instruction, an explicit output contract, and no room for prose -
    /// because the same thing is true here: the reply is parsed, not read.
    /// The five destinations are listed with what each one *is* rather than
    /// only its name, since "note" and "sticky" are not self-explanatory
    /// labels for anyone who has not used this app.
    static func classificationPrompt(for text: String) -> String {
        """
        Classify the following captured text into exactly one of five \
        destinations in a personal DevOps cockpit app, and answer with \
        nothing but the destination's identifier.

        - task: something to do, an action, a reminder, anything with a verb \
        aimed at the person who captured it.
        - sticky: a short thought, quote or scrap worth keeping visible on a \
        pinboard, with no action attached.
        - note: reference material worth a written page - a procedure, an \
        explanation, a paragraph of prose, anything long.
        - credential: a secret - a password, an API token, a private key, a \
        connection string with a password in it.
        - codeSnippet: source code, a shell command, a configuration \
        fragment, a query.

        Answer with exactly one of: task, sticky, note, credential, \
        codeSnippet. No punctuation, no explanation, no code fences.

        The captured text:
        \(text)
        """
    }

    /// Read a destination out of the crew's reply.
    ///
    /// Tolerant on purpose about the shapes a model actually produces -
    /// surrounding whitespace, a wrapping quote pair, a trailing full stop, a
    /// different case - and **intolerant** about everything else: a reply
    /// that names two destinations, or names none, returns nil and the panel
    /// keeps the captain in the loop rather than picking one. `DictationCleanup`'s
    /// header records the same "strip a quote pair defensively, do not depend
    /// on it" posture for the same CLI.
    static func parseClassification(_ reply: String) -> CaptureDestination? {
        var cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}'`."))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let lowered = cleaned.lowercased()
        let matches = CaptureDestination.allCases.filter { $0.rawValue.lowercased() == lowered }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// Bounded wait for the crew's answer.
    ///
    /// Short, like `DictationCleanup.timeout` and for the same reason: this
    /// sits between the captain and a keystroke they could have made
    /// themselves in half a second. A crew that has not answered by now has
    /// lost the race to ⌘1.
    static let classificationTimeout: TimeInterval = 20
}
