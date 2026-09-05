// Manjesh Grand Line - native macOS app.
//
// The saved-command library (design report Section B2 + B5, Section D Phase
// 3): "a reusable library of shell snippets you run in the active tab" - and,
// per-host, an optional startup snippet auto-run once a saved host's session
// looks ready. There is nothing secret here, so - unlike `SSHKey` - this model
// is fully `Codable` and lives entirely in `SnippetStore`'s plain JSON file.

import Foundation

/// A saved command: a label to find it by, and the literal text sent to a
/// terminal (plus a trailing Enter) when it is run.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var command: String

    var subtitle: String {
        let short = command.count > 60 ? String(command.prefix(60)) + "\u{2026}" : command
        return short.replacingOccurrences(of: "\n", with: " \u{23ce} ")
    }

    init(id: UUID = UUID(), label: String, command: String) {
        self.id = id
        self.label = label
        self.command = command
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
    }
}
