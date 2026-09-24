// Grand Line - native macOS app.
//
// F12's decision layer: everything about "did the captain just type a trigger,
// and may this snippet expand here" that can be decided without a window, a
// keyboard or a frontmost app. `SnippetExpander.swift` is the AppKit half that
// feeds this one real keystrokes and carries out its answer.
//
// The split is deliberate and follows AGENTS.md's "Writing a self-test" rule:
// the matching rules below are the correctness surface of this feature, and
// they are asserted in CI's *blocking* lane (`FM_RUN_SNIPPET_EXPANSION_TESTS`)
// because nothing here builds a view. The injection itself cannot be asserted
// in CI at all - see `SnippetExpander`'s header for what that means in
// practice.
//
// ## The trigger grammar, stated once
//
// A trigger is `;` + an abbreviation of word characters (letters, digits, `_`,
// `-`). It fires when **all four** of these hold:
//
//   1. the `;` is at a word boundary - start of the typed run, or preceded by
//      a non-word character. `foo;sig` does not expand, `(;sig` does. This is
//      the rule the task brief asks for by name;
//   2. the abbreviation matches a saved trigger **in full**. `;ab` never fires
//      inside `;abcdef`, because the candidate word is only read once it has
//      ended, and at that point the word is `abcdef`;
//   3. the word is ended by a *printable* terminator - a space or punctuation.
//      Return and Tab deliberately do **not** expand (see `isTerminator`);
//   4. the `;` is not itself preceded by another `;`. `;;sig` is the escape
//      hatch for typing a trigger literally.
//
// Matching is case-insensitive, so `;Sig` at the start of a sentence expands
// the same snippet `;sig` does. Trigger uniqueness is enforced on the same
// case-insensitive key, so the two can never mean different snippets.

import Foundation

// MARK: - Scope

/// Where a snippet is allowed to expand. The mockup's two chips.
///
/// `.consoleOnly` is the default and is what every snippet saved before F12
/// decodes as, which is the whole reason it is the default: the store predates
/// this feature by a year of shell one-liners, and a migration that silently
/// armed `kubectl drain ...` to fire into Mail would be the wrong answer to
/// "generalise the store".
enum SnippetScope: String, Codable, CaseIterable {
    /// Expands only while this app is frontmost with the Console on screen -
    /// the shell-snippet case the store was built for.
    case consoleOnly
    /// Expands in whatever app has focus, minus the snippet's own exclusions.
    case systemWide

    var title: String {
        switch self {
        case .consoleOnly: return "Console only"
        case .systemWide: return "Every app"
        }
    }

    /// The list-row chip, which reads as a capability rather than a setting.
    var chipText: String {
        switch self {
        case .consoleOnly: return "Console only"
        case .systemWide: return "system-wide"
        }
    }
}

// MARK: - The trigger grammar

enum SnippetTrigger {

    /// The one prefix. A captain-configurable prefix was considered and left
    /// out: the boundary rules above are stated in terms of "a non-word
    /// character starts a trigger", and a prefix that is itself a word
    /// character would make rule 1 undecidable.
    static let prefix: Character = ";"

    /// Long enough for `;postmortem`, short enough that a runaway buffer can
    /// never be mistaken for one.
    static let maximumLength = 24

    /// A character that may appear *inside* an abbreviation. Everything else
    /// ends the word.
    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    /// A character that ends a candidate word **and** may fire an expansion.
    ///
    /// Return (`\n`/`\r`) and Tab are excluded on purpose, and this is not a
    /// stylistic choice. A global `NSEvent` monitor is passive - it observes
    /// the keystroke, it cannot swallow it - so by the time this code sees a
    /// Return the app has already received it. In a send-on-Return app
    /// (Slack, Messages, half of every chat surface) the message is gone
    /// before an expansion could land, and the "expansion" would then be typed
    /// into the *next* message. So Return ends the typed run without
    /// expanding; a space or any punctuation is what fires.
    static func isTerminator(_ c: Character) -> Bool {
        guard !isWordCharacter(c), c != prefix else { return false }
        guard !c.isNewline, c != "\t" else { return false }
        return true
    }

    /// The stored form: no prefix, no surrounding whitespace. The captain may
    /// type `;sig` or `sig` into the editor's field and mean the same thing.
    static func normalize(_ raw: String) -> String {
        var trimmed = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while trimmed.first == prefix { trimmed = trimmed.dropFirst() }
        return String(trimmed)
    }

    /// What the UI shows: `;sig`.
    static func display(_ abbreviation: String) -> String {
        "\(prefix)\(abbreviation)"
    }

    /// Why an abbreviation cannot be saved, or `nil` when it can. An empty
    /// abbreviation is legal and means "this snippet has no trigger" - the
    /// pre-F12 shape - so emptiness is the caller's question, not this one's.
    static func rejection(for abbreviation: String) -> String? {
        if abbreviation.isEmpty { return "A trigger needs at least one character after \(prefix)." }
        if abbreviation.count > maximumLength {
            return "A trigger is at most \(maximumLength) characters."
        }
        if let bad = abbreviation.first(where: { !isWordCharacter($0) }) {
            let shown = bad == " " ? "a space" : "\u{201c}\(bad)\u{201d}"
            return "A trigger may only contain letters, digits, - and _ - \(shown) is not allowed."
        }
        return nil
    }

    /// The case-insensitive identity two triggers are compared on.
    static func key(_ abbreviation: String) -> String { abbreviation.lowercased() }
}

// MARK: - The typed-run buffer

/// What the expander feeds the buffer. Deliberately not `NSEvent`: the
/// classification (is this a character, a delete, or something that abandons
/// the run) is the AppKit half's job, and keeping this type free of AppKit is
/// what lets the whole grammar be asserted in CI's blocking lane.
enum SnippetTypingEvent: Equatable {
    case character(Character)
    case backspace
    /// Anything that means "wherever the caret is now, it is not where the
    /// typed run was": a click, an arrow key, a command chord, an app switch,
    /// Return, Tab, Escape.
    case abandon
}

/// A trigger the captain has just finished typing. Not yet matched against the
/// store - `SnippetTriggerTable` does that - so this type describes the
/// *keystrokes*, which is what the deletion has to be measured in.
struct SnippetTypedTrigger: Equatable {
    /// The abbreviation, without the `;`.
    let abbreviation: String
    /// The character that ended the word. Always a real terminator.
    let terminator: Character

    /// How many characters are on screen and have to come back off before the
    /// expansion is pasted: `;` + the abbreviation + the terminator.
    var typedLength: Int { abbreviation.count + 2 }
}

/// A bounded rolling record of the current typed run.
///
/// Bounded because it is a record of the captain's keystrokes and there is no
/// reason for this app to hold more of one than the longest trigger could
/// possibly need. `capacity` is the longest trigger plus the two characters
/// that bracket it plus one character of left context (rule 1 needs to know
/// what preceded the `;`), rounded up.
struct SnippetTypingBuffer {

    static let capacity = SnippetTrigger.maximumLength + 8

    private(set) var run: String = ""

    init() {}

    /// Feed one event. Returns the trigger the captain just completed, or
    /// `nil` - which is the overwhelmingly common answer, since this runs on
    /// every keystroke on the machine.
    mutating func consume(_ event: SnippetTypingEvent) -> SnippetTypedTrigger? {
        switch event {
        case .abandon:
            run = ""
            return nil
        case .backspace:
            if !run.isEmpty { run.removeLast() }
            return nil
        case .character(let c):
            let candidate = SnippetTrigger.isTerminator(c) ? completedTrigger(endedBy: c) : nil
            append(c)
            // A terminator ends the run either way: whether or not it matched,
            // whatever follows starts fresh.
            if SnippetTrigger.isTerminator(c) { run = "" }
            return candidate
        }
    }

    private mutating func append(_ c: Character) {
        run.append(c)
        if run.count > Self.capacity { run.removeFirst(run.count - Self.capacity) }
    }

    /// Reads the word immediately before the caret and decides rules 1, 3 and
    /// 4. Rule 2 (does this abbreviation actually name a snippet) belongs to
    /// `SnippetTriggerTable`, because only the store knows.
    private func completedTrigger(endedBy terminator: Character) -> SnippetTypedTrigger? {
        var chars = Array(run)
        var word: [Character] = []
        while let last = chars.last, SnippetTrigger.isWordCharacter(last) {
            word.insert(last, at: 0)
            chars.removeLast()
        }
        guard !word.isEmpty, word.count <= SnippetTrigger.maximumLength else { return nil }
        // Rule 1's own prefix: the character before the word must be the `;`.
        guard chars.last == SnippetTrigger.prefix else { return nil }
        chars.removeLast()
        // Rule 1: what precedes the `;`. Nothing (the run started here) is a
        // boundary; a word character is not. Rule 4 folds in here, since `;`
        // is not a word character but is explicitly rejected.
        if let before = chars.last {
            guard !SnippetTrigger.isWordCharacter(before), before != SnippetTrigger.prefix else {
                return nil
            }
        }
        return SnippetTypedTrigger(abbreviation: String(word), terminator: terminator)
    }
}

// MARK: - Looking a trigger up

/// The store's triggers, indexed on `SnippetTrigger.key`. Rebuilt whenever the
/// store changes - it is a handful of strings, and a cache that can go stale
/// is a worse trade here than a rebuild nobody can measure.
struct SnippetTriggerTable {

    private var byKey: [String: Snippet] = [:]

    init(_ snippets: [Snippet]) {
        for snippet in snippets {
            let abbreviation = SnippetTrigger.normalize(snippet.trigger)
            guard !abbreviation.isEmpty, SnippetTrigger.rejection(for: abbreviation) == nil else { continue }
            // First wins, so a duplicate that somehow reached disk (a hand-
            // edited file, a git sync between two builds) resolves to exactly
            // one snippet rather than to whichever the dictionary happened to
            // hash last.
            let key = SnippetTrigger.key(abbreviation)
            if byKey[key] == nil { byKey[key] = snippet }
        }
    }

    var count: Int { byKey.count }

    func snippet(for typed: SnippetTypedTrigger) -> Snippet? {
        byKey[SnippetTrigger.key(typed.abbreviation)]
    }

    /// The editor's duplicate check. `excluding` is the snippet being edited,
    /// so re-saving it without touching its trigger is not a clash with
    /// itself.
    static func existingSnippet(withTrigger abbreviation: String,
                                in snippets: [Snippet],
                                excluding id: UUID?) -> Snippet? {
        let key = SnippetTrigger.key(abbreviation)
        return snippets.first {
            $0.id != id && SnippetTrigger.key(SnippetTrigger.normalize($0.trigger)) == key
        }
    }
}

// MARK: - Placeholders

/// The four placeholders the mockup names, resolved at expansion time.
///
/// An unknown `{{token}}` is left **verbatim**: a snippet that is itself a
/// template (a Helm values file, a Mustache fragment) must survive being
/// expanded, and silently eating a brace pair it does not recognise is how a
/// text expander earns a reputation for mangling things.
enum SnippetPlaceholder: String, CaseIterable {
    case date = "{{date}}"
    case time = "{{time}}"
    case clipboard = "{{clipboard}}"
    case cursor = "{{cursor}}"

    var help: String {
        switch self {
        case .date: return "today, as 2026-09-21"
        case .time: return "now, as 14:05"
        case .clipboard: return "whatever is on the clipboard"
        case .cursor: return "where the caret lands afterwards"
        }
    }
}

struct SnippetExpansionText: Equatable {
    /// What gets pasted.
    let text: String
    /// How many characters the caret has to walk back over afterwards, from
    /// the end of the pasted text, to land where `{{cursor}}` was. Zero when
    /// the snippet has no `{{cursor}}`.
    let caretOffsetFromEnd: Int
}

enum SnippetPlaceholders {

    /// Deterministic on purpose: `DateFormatter` with an explicit POSIX locale
    /// and no timezone surprises, so the suite asserts a literal string rather
    /// than re-deriving one from the function under test.
    static func dateString(_ now: Date, timeZone: TimeZone = .current) -> String {
        format("yyyy-MM-dd", now, timeZone)
    }

    static func timeString(_ now: Date, timeZone: TimeZone = .current) -> String {
        format("HH:mm", now, timeZone)
    }

    private static func format(_ pattern: String, _ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// `clipboard` is passed in rather than read here, and that is a security
    /// decision rather than a testability one: the caller is the only place
    /// that knows whether `CredentialVaultClipboard.isConcealed` said the
    /// pasteboard is holding a vault secret. See `SnippetExpander.clipboardText`.
    static func resolve(_ template: String,
                        now: Date,
                        clipboard: String?,
                        timeZone: TimeZone = .current) -> SnippetExpansionText {
        var text = template
        text = text.replacingOccurrences(of: SnippetPlaceholder.date.rawValue,
                                         with: dateString(now, timeZone: timeZone))
        text = text.replacingOccurrences(of: SnippetPlaceholder.time.rawValue,
                                         with: timeString(now, timeZone: timeZone))
        text = text.replacingOccurrences(of: SnippetPlaceholder.clipboard.rawValue,
                                         with: clipboard ?? "")

        let marker = SnippetPlaceholder.cursor.rawValue
        guard let first = text.range(of: marker) else {
            return SnippetExpansionText(text: text, caretOffsetFromEnd: 0)
        }
        // Only the first marker positions the caret; any later one is stripped
        // too, because leaving `{{cursor}}` visible in the pasted text would
        // be the worse of the two wrong answers.
        let head = String(text[text.startIndex..<first.lowerBound])
        let tail = String(text[first.upperBound...]).replacingOccurrences(of: marker, with: "")
        return SnippetExpansionText(text: head + tail, caretOffsetFromEnd: tail.count)
    }
}

// MARK: - May this expand here?

/// Everything outside the snippet that the decision depends on, gathered once
/// at the moment of the keystroke so the decision itself is a pure function.
struct SnippetExpansionContext: Equatable {
    var expansionEnabled: Bool
    var accessibilityTrusted: Bool
    var appIsLocked: Bool
    var isGrandLineFrontmost: Bool
    var isConsoleFocused: Bool
    var frontmostBundleID: String?
    var frontmostAppName: String?
}

/// Why an expansion did not happen. Every one of these is a state the UI can
/// explain, which is the point of enumerating them rather than returning a
/// `Bool` - "nothing happened when I typed `;sig`" is the failure mode a text
/// expander has to be able to answer for.
enum SnippetExpansionRefusal: Equatable {
    case expansionTurnedOff
    case appLocked
    case accessibilityNotTrusted
    case noTrigger
    case outsideConsole
    case excludedApp(String)

    var explanation: String {
        switch self {
        case .expansionTurnedOff: return "Snippet expansion is turned off in Settings."
        case .appLocked: return "Grand Line is locked."
        case .accessibilityNotTrusted: return "Grand Line is not a trusted Accessibility app yet."
        case .noTrigger: return "This snippet has no trigger."
        case .outsideConsole: return "This snippet only expands in the Console."
        case .excludedApp(let app): return "This snippet is excluded from \(app)."
        }
    }
}

enum SnippetExpansionPolicy {

    /// `nil` means expand. The order is the order the captain would want to be
    /// told about: a global "off" beats everything, then the lock (GL-09),
    /// then the permission, then the snippet's own two rules.
    static func refusal(for snippet: Snippet,
                        in context: SnippetExpansionContext) -> SnippetExpansionRefusal? {
        if !context.expansionEnabled { return .expansionTurnedOff }
        if context.appIsLocked { return .appLocked }
        if !context.accessibilityTrusted { return .accessibilityNotTrusted }
        if SnippetTrigger.normalize(snippet.trigger).isEmpty { return .noTrigger }
        switch snippet.scope {
        case .consoleOnly:
            guard context.isGrandLineFrontmost, context.isConsoleFocused else { return .outsideConsole }
            return nil
        case .systemWide:
            if let excluded = excludedMatch(snippet, context) { return .excludedApp(excluded) }
            return nil
        }
    }

    /// An exclusion entry matches the frontmost app by bundle identifier or by
    /// name, case-insensitively, because the captain types what they see in
    /// the Dock ("1Password") and the system knows a reverse-DNS string.
    /// Matching both is what keeps the field usable without a picker.
    private static func excludedMatch(_ snippet: Snippet,
                                      _ context: SnippetExpansionContext) -> String? {
        let candidates = [context.frontmostBundleID, context.frontmostAppName]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        for entry in snippet.excludedApps {
            let needle = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { continue }
            if candidates.contains(needle) { return entry }
        }
        return nil
    }
}
