// Manjesh Grand Line - native macOS app.
//
// The saved-command library (design report Section B2 + B5, Section D Phase
// 3): "a reusable library of shell snippets you run in the active tab" - and,
// per-host, an optional startup snippet auto-run once a saved host's session
// looks ready. There is nothing secret here, so - unlike `SSHKey` - this model
// is fully `Codable` and lives entirely in `SnippetStore`'s plain JSON file.

import Foundation

/// A saved piece of text: a label to find it by, the literal text itself, and
/// - since F12 - an optional `;abbrev` trigger that expands it wherever the
/// captain is typing.
///
/// **F12 generalised this type rather than adding a second store.** The report
/// asked for exactly that ("the Snippets store already exists for shell text -
/// generalise it"), and the alternative would have been two lists of saved
/// text with two editors, two backup entries and a captain having to remember
/// which one a given string lives in. `command` keeps its name because ~40
/// call sites read it and because it is still literally the command for every
/// snippet that has no trigger; the UI calls it the expansion where a trigger
/// is involved.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var command: String

    /// The abbreviation, **without** the `;` - `sig`, not `;sig`. Empty means
    /// "no trigger", which is what every snippet saved before F12 is and what
    /// a snippet that is only ever run from the list stays.
    ///
    /// See `SnippetTrigger` for the grammar and the boundary rules.
    var trigger: String = ""

    /// Where this snippet's trigger is allowed to fire. Defaults to
    /// `.consoleOnly` - see `SnippetScope`'s own note for why the default is
    /// the conservative one rather than the interesting one.
    var scope: SnippetScope = .consoleOnly

    /// Apps this snippet must never expand into, by bundle identifier or by
    /// the name shown in the Dock. Only consulted for `.systemWide`.
    var excludedApps: [String] = []

    /// A trigger this snippet can actually be found by: normalized, non-empty
    /// and legal. The list, the detail panel and the expander all ask this
    /// rather than re-deriving it.
    var normalizedTrigger: String {
        let abbreviation = SnippetTrigger.normalize(trigger)
        guard !abbreviation.isEmpty, SnippetTrigger.rejection(for: abbreviation) == nil else { return "" }
        return abbreviation
    }

    /// Reads `;sig`, or nil when there is no usable trigger.
    var triggerDisplay: String? {
        let abbreviation = normalizedTrigger
        return abbreviation.isEmpty ? nil : SnippetTrigger.display(abbreviation)
    }

    /// The claim the page's subtitle counts: this one will fire in other apps.
    var expandsSystemWide: Bool { scope == .systemWide && !normalizedTrigger.isEmpty }

    var subtitle: String {
        let short = command.count > 60 ? String(command.prefix(60)) + "\u{2026}" : command
        return short.replacingOccurrences(of: "\n", with: " \u{23ce} ")
    }

    init(id: UUID = UUID(),
         label: String,
         command: String,
         trigger: String = "",
         scope: SnippetScope = .consoleOnly,
         excludedApps: [String] = []) {
        self.id = id
        self.label = label
        self.command = command
        self.trigger = trigger
        self.scope = scope
        self.excludedApps = excludedApps
    }

    /// **Hand-written on purpose - do not delete it back to the synthesised
    /// one** (full-app audit, finding 4.8). Same reasoning, verbatim, as
    /// `SSHKey.init(from:)` - see that decoder's own comment for the full
    /// account of how a Swift-side default does *not* make a key optional to
    /// the synthesised decoder, and what that cost this app once already.
    /// Nothing here is broken today; this is the preventive half, so the next
    /// field added to `Snippet` cannot silently take every existing
    /// `snippets.json` with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        // F12 is the field addition this decoder was written for: all three
        // arrive through `decodeIfPresent` with the property defaults above,
        // so every `snippets.json` written before this build still decodes -
        // as an untriggered, Console-only snippet, which is what it was.
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        // An unrecognised scope string reads as the conservative default
        // rather than throwing. GL-01 is about not letting one bad file look
        // empty; this is the same instinct one field down - a hand-edited or
        // newer-build value must not take the whole list with it.
        scope = (try? c.decodeIfPresent(SnippetScope.self, forKey: .scope)).flatMap { $0 } ?? .consoleOnly
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
    }
}
