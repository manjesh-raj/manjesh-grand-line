// Grand Line - native macOS app.
//
// What a toast says beyond its own message (TO-1 Hero capsule, on the hero
// restyle board `data/grandline-hero-restyle-designs-scout/`).
//
// The capsule's glyph says what kind of report it is: a check for done, a
// triangle for a warning, a cross for a failure. Before TO-1 every toast drew
// the same green check, so "Docs sync failed" and "Couldn't write the
// incident record" looked like successes (the report's finding 1).
//
// A toast also used to say nothing to VoiceOver (finding 2). It now posts one
// announcement, and this is its wording: the message as the captain reads it,
// plus "Undo available" when the pill carries Undo, because a VoiceOver user
// cannot see the button and it is gone six seconds later.
//
// Pure, so `FeedbackRoutingSelfTest` asserts it in CI's blocking lane.

import Foundation

enum ToastHeroWords {

    /// The glyph in the capsule's glass circle, one per kind.
    static func symbol(for kind: Feedback.Kind) -> String {
        switch kind {
        case .done: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark"
        }
    }

    /// What VoiceOver hears, once, as the pill appears. A message that already
    /// ends a sentence gets a second sentence rather than a comma after its
    /// full stop.
    static func announcement(message: String, hasUndo: Bool) -> String {
        guard hasUndo else { return message }
        if let last = message.last, ".!?\u{2026}".contains(last) {
            return message + " " + undoAvailable + "."
        }
        return message + ", " + undoAvailable
    }

    static let undoAvailable = "Undo available"
}
