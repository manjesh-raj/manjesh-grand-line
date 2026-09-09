// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 2**: the reply envelope, its closed proposal
// vocabulary, and the three-rung parser (the plan's milestones M2.1 + M2.2).
//
// Phase 1's reply was prose: whatever `claude` said became one Luffy message.
// Phase 2's contract is one fenced ```json block carrying a `sections` array,
// so a single call can speak as several crew members and can *propose* a
// write - which the captain then confirms. The plan's own worked example:
//
//     { "sections": [
//       { "speaker": "nami",
//         "text": "I heard a task and a follow-up in there - drafted both:",
//         "proposals": [
//           { "kind": "add_task", "title": "Fix the login issue",
//             "due": "2026-09-09" },
//           { "kind": "add_follow_up",
//             "title": "Ask Rahul about the Cognito config" } ] },
//       { "speaker": "luffy", "text": "Both drafted - confirm to add.",
//         "followup": "Want Robin to check for a Cognito runbook first?" } ] }
//
// ## The closed enum IS the security mechanism
//
// `StrawHatProposalKind` is a fixed set, exactly like `KubeCommand` and
// `ScheduledActionKind`: a `kind` the model invents that is not a case here
// **cannot execute**, structurally rather than by review. There is no
// default case, no string passthrough, and no "run it if it looks safe"
// branch anywhere in this file or in `StrawHatProposalExecutor`. Adding a
// write to the crew's vocabulary is a deliberate edit to this enum plus a
// deliberate edit to that executor's `switch`, which is the point.
//
// Phase 2 ships three kinds. The plan's phase-3 set (`add_sticky`,
// `save_command_draft`, `create_schedule_draft`, `open_sre_lead` /
// `open_destination`) is deliberately absent - a persona that describes a
// proposal nothing can execute produces exactly the failure the confirm-card
// rule exists to prevent, and `StrawHatSelfTest` asserts the enum has not
// grown early.
//
// ## The three rungs, and the one thing all three guarantee
//
//  1. **Validated envelope** - the fenced JSON parses, every `speaker` is on
//     the roster and every `proposal.kind` is a case here. Renders as
//     attributed crew blocks plus confirm cards.
//     (`WhiteboardDiagram.parse`'s validate-or-refuse discipline.)
//  2. **Partial salvage** - the envelope parses but a section names a voice
//     that is not aboard, or a proposal kind that is not a case. That section
//     still renders (its `speaker` becomes `nil`, so the view shows the text
//     with no attribution header rather than crediting a crew member who did
//     not say it) and the unrecognized proposal is **dropped, never
//     executed** - counted into `droppedProposalCount` so the view can say so
//     rather than silently losing it.
//     (`LogAnalyzerAI`'s downgrade-don't-trust move.)
//  3. **Plain text** - no usable envelope at all. The whole reply renders as
//     one ordinary Luffy message, i.e. exactly phase 1's behaviour.
//     (`CommandLibraryAI.parse` returning nil and the feature degrading.)
//
// **The reply is never dropped.** Every rung renders something, and rung 3 is
// reachable from every failure inside rungs 1-2 (unparseable JSON, no
// `sections` key, an empty array, sections that carry neither text nor a
// usable proposal). That invariant is what makes a schema change in the model
// a cosmetic regression rather than a chat that silently stops answering.
//
// ## Why there is deliberately no brace-balanced last-resort scan
//
// `LogAnalyzerAI.decodeJSONObject` ends with "the widest brace-balanced span"
// - correct there, because that reply is *always meant to be* JSON, so a
// stray sentence around it is noise. Here the opposite is true: most replies
// are prose, and Luffy explaining a config file, or writing a fenced Swift
// block, legitimately contains `{ ... }`. A widest-span scan would swallow
// that answer and render a fragment of it - losing the captain's actual reply
// to salvage something that was never an envelope. So this file recognises
// exactly two shapes, and everything else is honest rung-3 prose:
//
//  - a fenced block (```json or bare ```) whose contents are an object with a
//    `sections` array, anywhere in the reply, or
//  - the entire trimmed reply being such an object.
//
// The failure direction that matters: a real envelope mis-read as prose is
// visible, honest and degraded (the captain sees the JSON). A real prose
// answer mis-read as an envelope is silent data loss.
//
// And where a reply is genuinely *both* - prose wrapped around a real
// envelope - neither side is dropped: the envelope renders as attributed
// sections and the surrounding prose renders as unattributed ones, in place.
// See `Extracted`'s own note for why picking a side was the wrong trade.

import Foundation

/// What a crew member may propose. **Closed on purpose** - see this file's
/// header. Raw values are the wire strings the persona names.
enum StrawHatProposalKind: String, CaseIterable {
    case addTask = "add_task"
    case addFollowUp = "add_follow_up"
    case createRunbookDraft = "create_runbook_draft"

    /// The confirm card's own kicker.
    var label: String {
        switch self {
        case .addTask: return "New task"
        case .addFollowUp: return "New follow-up"
        case .createRunbookDraft: return "Runbook draft"
        }
    }

    /// The confirm button's title - a verb, because clicking it writes.
    var confirmTitle: String {
        switch self {
        case .addTask: return "Add task"
        case .addFollowUp: return "Add follow-up"
        case .createRunbookDraft: return "Save draft"
        }
    }

    /// Past tense, for the card's confirmed state and the toast.
    var confirmedTitle: String {
        switch self {
        case .addTask: return "Added to Tasks"
        case .addFollowUp: return "Added to Follow-ups"
        case .createRunbookDraft: return "Saved to Runbooks"
        }
    }

    var symbol: String {
        switch self {
        case .addTask: return "checkmark.circle"
        case .addFollowUp: return "bell"
        case .createRunbookDraft: return "doc.text"
        }
    }

    /// Which store this writes to, named for the card's own detail line so the
    /// captain can see where a click lands before making it.
    var destination: String {
        switch self {
        case .addTask, .addFollowUp: return "Tasks"
        case .createRunbookDraft: return "Runbooks"
        }
    }
}

/// One proposed write, already validated: `kind` is a real case and every
/// field that kind *requires* is present and non-empty. A proposal that fails
/// either test never becomes one of these - it is counted as dropped instead.
struct StrawHatProposal: Equatable {
    let kind: StrawHatProposalKind
    let title: String
    /// The due/follow-up date exactly as the model wrote it - `"2026-09-09"`,
    /// or natural language like `"tomorrow 3pm"`. Resolved at execution time
    /// by `resolvedDue(now:)`, never here: turning a string into a moment
    /// needs a `now`, and a parser is not the place to decide what "tomorrow"
    /// meant.
    let due: String?
    let notes: String?
    /// A runbook draft's markdown body. Required for `.createRunbookDraft`
    /// and meaningless for the other two.
    let content: String?

    init(kind: StrawHatProposalKind, title: String, due: String? = nil,
         notes: String? = nil, content: String? = nil) {
        self.kind = kind
        self.title = title
        self.due = due
        self.notes = notes
        self.content = content
    }

    /// The `("YYYY-MM-DD", "HH:MM"?)` pair `ShiftTask`/`ShiftFollowUp`
    /// persist, or `nil` when the model gave no date or gave one nothing
    /// recognises.
    ///
    /// Strict ISO first, then `ShiftDateParser` - the app's own
    /// natural-language scanner, the same one the New Task sheet runs on a
    /// typed title, so "tomorrow" means the same thing whether the captain
    /// typed it or Nami proposed it. **Never a fabricated fallback**: an
    /// unrecognised date leaves the task undated rather than quietly landing
    /// on today, which would be a wrong due date presented as the captain's
    /// own choice.
    func resolvedDue(now: Date = Date()) -> (date: String, time: String?)? {
        guard let due = due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty else { return nil }

        if let iso = Self.isoDay.date(from: due) {
            // A bare "YYYY-MM-DD" carries no time-of-day, and inventing one
            // would show a due *time* the model never proposed.
            return (Self.isoDay.string(from: iso), nil)
        }
        if let parsed = ShiftDateParser.parse(due, now: now) {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: parsed.date)
            return (dateStr, parsed.hasTime ? timeStr : nil)
        }
        return nil
    }

    /// A one-line human summary of what the confirm card is about to write,
    /// so the captain is not clicking on a title alone.
    func detail(now: Date = Date()) -> String {
        var parts: [String] = [kind.destination]
        if let resolved = resolvedDue(now: now) {
            parts.append(ShiftDateFormatting.friendly(resolved.date, time: resolved.time))
        } else if let due, !due.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The model proposed a date nothing could read. Say so rather than
            // dropping it silently - the captain can fix it on the Tasks page.
            parts.append("couldn't read \u{201C}\(due)\u{201D}")
        }
        if kind == .createRunbookDraft, let content {
            let lines = content.split(separator: "\n").count
            parts.append("\(lines) line\(lines == 1 ? "" : "s")")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

/// One attributed block of a reply.
struct StrawHatSection {
    /// `nil` when the model named a voice that is not on the roster - rung 2.
    /// The view renders a `nil` speaker with no attribution header, because
    /// crediting the text to a crew member who did not say it is exactly the
    /// kind of plausible-but-wrong the whole ladder exists to avoid.
    let speaker: StrawHatMember?
    /// What the model actually wrote in `speaker`, kept for the log line so a
    /// persona drifting off the roster is diagnosable.
    let rawSpeaker: String
    let text: String
    /// Only proposals that passed validation. Everything else is dropped.
    let proposals: [StrawHatProposal]
    /// How many proposals were refused (unknown kind, or a required field
    /// missing). Surfaced by the view - the "no silent caps" rule: a proposal
    /// that vanishes with no trace reads as the app losing work.
    let droppedProposalCount: Int
    /// An optional closing question. Rendered as a muted line under the text,
    /// not as a proposal - it asks, it does not write.
    let followup: String?

    /// A section carrying nothing but text from a known member.
    ///
    /// Two callers: rung 3's whole-reply fallback (the parser's `.plain`
    /// case, rendered as one Luffy block exactly as phase 1 did), and the
    /// page's own error/system lines. It is a real `StrawHatSection` rather
    /// than a second message case so the transcript has one shape for
    /// "something a crew member said", however it got there.
    static func text(_ member: StrawHatMember, _ text: String) -> StrawHatSection {
        StrawHatSection(speaker: member, rawSpeaker: member.rawValue, text: text,
                        proposals: [], droppedProposalCount: 0, followup: nil)
    }
}

/// The parser's verdict. Both cases render; see this file's header.
enum StrawHatReply {
    /// Rungs 1 and 2 - at least one section carried something usable.
    case envelope([StrawHatSection])
    /// Rung 3 - the reply, verbatim, as one ordinary Luffy message.
    case plain(String)
}

enum StrawHatEnvelope {

    /// How many sections one reply may render. A bounded cap for the same
    /// reason `HelmModuleCard.maxPeekRows` and `maxBriefingClauses` are
    /// bounded: these become permanent arranged subviews of the transcript
    /// stack, and a model that answers with forty voices would make one turn
    /// taller than the whole pane. The persona asks for one or two; six is
    /// generous headroom, and the overflow is *stated* rather than silently
    /// truncated.
    static let maxSections = 6

    /// How many proposals one section may carry. Same reasoning - and a
    /// runaway list of confirm cards is worse than a truncated one, because
    /// every card is a button that writes.
    static let maxProposalsPerSection = 8

    /// Turn one `claude` reply into something the transcript can render.
    /// Never fails - see the header's "the reply is never dropped".
    static func parse(_ reply: String) -> StrawHatReply {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found = extract(from: trimmed),
              let rawSections = found.object["sections"] as? [Any],
              !rawSections.isEmpty else {
            return .plain(trimmed)
        }

        var sections: [StrawHatSection] = []
        var overflow = 0
        for entry in rawSections {
            guard let dict = entry as? [String: Any] else { continue }
            guard let section = self.section(from: dict) else { continue }
            if sections.count >= maxSections {
                overflow += 1
                continue
            }
            sections.append(section)
        }

        // An envelope whose sections all turned out to be empty is not an
        // envelope worth rendering - fall back to showing the reply rather
        // than rendering a turn with nothing in it.
        guard !sections.isEmpty else { return .plain(trimmed) }

        if overflow > 0 {
            AppLog.ai.info("straw hat: reply carried \(rawSections.count) sections, rendering \(sections.count)")
            sections.append(StrawHatSection(
                speaker: nil, rawSpeaker: "",
                text: "_\(overflow) more section\(overflow == 1 ? "" : "s") in that reply weren't shown._",
                proposals: [], droppedProposalCount: 0, followup: nil))
        }

        // Prose the model wrote outside the fence, kept in its original
        // position and unattributed - see `Extracted`'s own note on why
        // losing either side of this was the wrong trade.
        if let leading = found.leading {
            sections.insert(StrawHatSection(speaker: nil, rawSpeaker: "", text: leading,
                                            proposals: [], droppedProposalCount: 0, followup: nil), at: 0)
        }
        if let trailing = found.trailing {
            sections.append(StrawHatSection(speaker: nil, rawSpeaker: "", text: trailing,
                                            proposals: [], droppedProposalCount: 0, followup: nil))
        }
        return .envelope(sections)
    }

    // MARK: Internals

    /// One section, or `nil` when it carries nothing worth rendering.
    private static func section(from dict: [String: Any]) -> StrawHatSection? {
        let rawSpeaker = (dict["speaker"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let speaker = StrawHatMember(rawValue: rawSpeaker)
        if speaker == nil && !rawSpeaker.isEmpty {
            // Rung 2. Not an error - a persona drift, or a phase-3 voice
            // arriving early. The text still renders; nothing is attributed.
            AppLog.ai.info("straw hat: reply named a speaker that is not aboard: \(rawSpeaker, privacy: .public)")
        }

        let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let followupRaw = (dict["followup"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let followup = (followupRaw?.isEmpty == false) ? followupRaw : nil

        var proposals: [StrawHatProposal] = []
        var dropped = 0
        if let rawProposals = dict["proposals"] as? [Any] {
            for entry in rawProposals {
                guard let proposalDict = entry as? [String: Any] else { dropped += 1; continue }
                // Rung 2's hard rule: an unknown kind, or a kind missing the
                // field it needs, is counted and discarded. It never reaches
                // the executor, so there is no path from a model-invented
                // proposal to a store write.
                guard let proposal = self.proposal(from: proposalDict) else { dropped += 1; continue }
                if proposals.count >= maxProposalsPerSection { dropped += 1; continue }
                // A speaker who is not aboard does not get to propose writes
                // either: the section is already being treated as unattributed
                // salvage, and executing its proposals would trust exactly the
                // half of the envelope that has already proven unreliable.
                guard speaker != nil else { dropped += 1; continue }
                proposals.append(proposal)
            }
        }

        // Nothing to say and nothing to offer.
        guard !text.isEmpty || !proposals.isEmpty || dropped > 0 || followup != nil else { return nil }
        return StrawHatSection(speaker: speaker, rawSpeaker: rawSpeaker, text: text,
                               proposals: proposals, droppedProposalCount: dropped,
                               followup: followup)
    }

    /// One proposal, or `nil` when it cannot be executed as written.
    private static func proposal(from dict: [String: Any]) -> StrawHatProposal? {
        guard let rawKind = (dict["kind"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawKind.isEmpty else { return nil }
        guard let kind = StrawHatProposalKind(rawValue: rawKind) else {
            AppLog.ai.info("straw hat: refused an unknown proposal kind: \(rawKind, privacy: .public)")
            return nil
        }
        guard let title = (dict["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            // Every kind needs a title, and there is nothing safe to invent -
            // a task called "Untitled" is a task the captain did not ask for.
            AppLog.ai.info("straw hat: refused a \(rawKind, privacy: .public) proposal with no title")
            return nil
        }

        let due = optionalString(dict["due"]) ?? optionalString(dict["follow_up_at"])
        let notes = optionalString(dict["notes"])
        let content = optionalString(dict["content"]) ?? optionalString(dict["body"])

        if kind == .createRunbookDraft && content == nil {
            // A runbook with no body is an empty file in the captain's
            // git-synced docs folder.
            AppLog.ai.info("straw hat: refused a runbook draft with no content")
            return nil
        }
        return StrawHatProposal(kind: kind, title: title, due: due, notes: notes, content: content)
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// An envelope found in a reply, plus whatever prose surrounded it.
    ///
    /// The prose matters. An earlier draft of this file kept only the
    /// envelope, which resolved a real tension by losing one side of it: a
    /// reply that is plainly prose *about* the format ("your reply format
    /// looks like this: ```json {sections:[...]} ``` - the speaker has to be
    /// one of the four of us") had its explanation silently discarded, while
    /// the alternative - refusing any envelope that is not the entire reply -
    /// would drop every confirm card the moment a model prepended "Sure!",
    /// which is the far more common violation and takes a task the captain
    /// actually asked for with it.
    ///
    /// Keeping both sides removes the trade entirely: the envelope renders as
    /// attributed sections *and* the surrounding prose renders as
    /// unattributed ones, in its original position. That is the ladder's own
    /// invariant - the reply is never dropped - applied to the one case where
    /// "the reply" is two things at once.
    struct Extracted {
        let object: [String: Any]
        /// Prose before the fence, if any is left after trimming.
        let leading: String?
        /// Prose after the closing fence, if any.
        let trailing: String?
    }

    /// The two recognised shapes, and only those - see the header's note on
    /// the deliberately absent brace-balanced scan.
    ///
    /// `internal` so `StrawHatSelfTest` can assert the boundary directly on
    /// payloads a fake `claude` cannot easily produce.
    static func extract(from reply: String) -> Extracted? {
        // The whole reply is the object. Checked first: it is the shape the
        // persona asks for once the model stops adding a fence.
        if reply.hasPrefix("{"), let object = jsonObject(reply), object["sections"] != nil {
            return Extracted(object: object, leading: nil, trailing: nil)
        }
        // A fenced block, anywhere in the reply. `WhiteboardDiagram.
        // stripCodeFence` only looks at line 0, which misses the very common
        // "one sentence, then the block".
        for block in fencedBlocks(in: reply) {
            guard let object = jsonObject(block.body), object["sections"] != nil else { continue }
            return Extracted(object: object,
                             leading: trimmedOrNil(block.before),
                             trailing: trimmedOrNil(block.after))
        }
        return nil
    }

    private static func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private struct FencedBlock {
        let body: String
        let before: String
        let after: String
    }

    /// Every ```-fenced block, with the text on each side of it. Opening
    /// fences may carry an info string (```json); a closing fence is a line
    /// that is just backticks. An unterminated final fence still yields what
    /// follows it, since a truncated reply's block is worth trying to read.
    private static func fencedBlocks(in text: String) -> [FencedBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [FencedBlock] = []
        var openIndex: Int?
        var body: [String] = []

        for (index, line) in lines.enumerated() {
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("```") else {
                if openIndex != nil { body.append(line) }
                continue
            }
            if let start = openIndex {
                blocks.append(FencedBlock(
                    body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    before: lines[..<start].joined(separator: "\n"),
                    after: lines[(index + 1)...].joined(separator: "\n")))
                openIndex = nil
                body = []
            } else {
                openIndex = index
            }
        }
        // An unterminated final fence: everything after it is the body, and
        // there is nothing after the block by definition.
        if let start = openIndex, !body.isEmpty {
            blocks.append(FencedBlock(
                body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                before: lines[..<start].joined(separator: "\n"),
                after: ""))
        }
        return blocks.filter { !$0.body.isEmpty }
    }
}
