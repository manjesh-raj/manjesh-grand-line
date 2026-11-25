// Grand Line - native macOS app.
//
// RP-2 Question head, the captain's pick for the Needs you reply composer on
// the hero restyle board (`data/grandline-hero-restyle-designs-scout/`, stage
// `stage-reply`). When Reply opens on Needs you, the decision row and its
// composer become one card whose head is the question in full. This file is
// what that card and the row it replaces say.
//
// **Pure, and Foundation only.** Every input is a value `FleetController`
// already holds - the task's id, repo, status and detail, and the open
// decisions `FleetActions.openDecisions` read from its status file - so the
// words are asserted in CI's blocking lane (`PageHeroColumnsSelfTest`)
// without a window, a store or a status file.
//
// **No new words for the row.** The kicker, the row's second line and the
// caption under the composer are the ones `FleetController+Reply.swift`
// spelled inline until now, moved here so the row, the floating bar's
// composer and the card read from one definition. The head's own words are
// those same pieces rearranged: the row's kicker, the note the row showed as
// its second line (now the headline, unclipped), and the repo with the
// decision or decisions an answer is addressed to.

import Foundation

enum ReplyHeroWords {

    /// The head's colour: the theme's hero accent for a task waiting on a
    /// decision, and the theme's amber for a blocked one.
    enum Tone: Equatable { case accent, amber }

    /// What the card's head says.
    struct Head: Equatable {
        /// The glass tile's glyph: the row's badge, drawn in outline as the
        /// board's tile draws it.
        var symbol: String
        /// "Needs decision · task-142", the row's kicker.
        var kicker: String
        /// The question: the open decision's note, in full.
        var headline: String
        /// "grand-line · 2 open decisions: helm-bump, board-review".
        var detail: String
        var tone: Tone
        /// What VoiceOver calls the whole card.
        var groupLabel: String
    }

    /// The composer's own words, unchanged from the floating bar's.
    static let placeholder = "Type your answer\u{2026}"
    static let sendTitle = "Send"
    static let cancelTitle = "Cancel"

    static func isBlocked(status: String) -> Bool { status == "blocked" }

    /// The row's kicker and the head's: "Needs decision · task-142" or
    /// "Blocked · task-142".
    static func kicker(taskID: String, blocked: Bool) -> String {
        blocked ? "Blocked \u{00B7} \(taskID)" : "Needs decision \u{00B7} \(taskID)"
    }

    /// The row's badge glyph.
    static func symbol(blocked: Bool) -> String {
        blocked ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    /// The same glyph in outline, for the head's glass tile. Filled, the
    /// triangle is one solid shape around a cut-out mark, which at the tile's
    /// 11pt read as a brown smudge on the gradient in the first render.
    static func tileSymbol(blocked: Bool) -> String {
        blocked ? "xmark.octagon" : "exclamationmark.triangle"
    }

    /// The question: the crew's own words where there are any (the newest
    /// open decision's note), falling back to `fm-crew-state.sh`'s detail and
    /// then to where the task came from. Never invented text. The row shows
    /// it as its second line, and the head as its headline.
    static func question(decisions: [FleetDecision], detail: String, source: String) -> String {
        if let note = decisions.last?.note, !note.isEmpty { return note }
        return detail.isEmpty ? "source: \(source)" : detail
    }

    /// The head's second line: the repo, then what an answer is addressed
    /// to - the one open decision by its verb and key, or every open key when
    /// there are several, so the captain can see the answer is ambiguous
    /// before typing it. A task with no decision on record names its repo
    /// alone.
    static func detail(repo: String, decisions: [FleetDecision]) -> String {
        switch decisions.count {
        case 0:
            return repo
        case 1:
            return "\(repo) \u{00B7} \(decisions[0].verb) \u{201C}\(decisions[0].key)\u{201D}"
        default:
            let keys = decisions.map(\.key).joined(separator: ", ")
            return "\(repo) \u{00B7} \(decisions.count) open decisions: \(keys)"
        }
    }

    static func head(taskID: String, repo: String?, status: String, detail: String, source: String,
                     decisions: [FleetDecision]) -> Head {
        let blocked = isBlocked(status: status)
        return Head(symbol: tileSymbol(blocked: blocked),
                    kicker: kicker(taskID: taskID, blocked: blocked),
                    headline: question(decisions: decisions, detail: detail, source: source),
                    detail: self.detail(repo: repo ?? taskID, decisions: decisions),
                    tone: blocked ? .amber : .accent,
                    groupLabel: "Answer \(taskID)")
    }

    /// The caption under the composer: where the text goes, plus - only when
    /// it is actually true - that this answer also closes the decision record.
    /// With several open, which one an answer settles is ambiguous, so nothing
    /// is closed and the captain is told so rather than having one picked.
    static func caption(decisions: [FleetDecision]) -> String {
        let base = "Sent as a reply into the firstmate session for this crew, same as answering in a terminal."
        switch decisions.count {
        case 1:
            return base + " Closes the open \(decisions[0].verb) \u{201C}\(decisions[0].key)\u{201D}."
        case let n where n > 1:
            return base + " \(n) decisions are open on this task, so none is closed automatically - resolve the right one from the crew's session."
        default:
            return base
        }
    }
}
