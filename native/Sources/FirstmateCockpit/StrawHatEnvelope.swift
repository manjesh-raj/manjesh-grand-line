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
// Phase 3 completes the plan's vocabulary: `add_sticky` (Usopp),
// `save_command_draft` (Zoro) and `create_schedule_draft` (Franky) join the
// three write kinds, plus the two navigation handoffs `open_sre_lead` /
// `open_destination`. `StrawHatSelfTest` asserts the membership as a literal
// list, so a kind added without a matching executor branch and a deliberate
// decision fails there rather than shipping.
//
// ## Two families, and the split is behavioural rather than cosmetic
//
// `StrawHatProposalKind.isNavigation` divides the vocabulary in two, and
// which side a kind sits on decides what the captain has to do with it:
//
//  - **A write** renders as a `StrawHatConfirmCard` with a confirm *button*,
//    and nothing happens until they press it. Six of the eight.
//  - **A handoff** (`open_sre_lead` / `open_destination`) renders as a link
//    row and runs on the click itself, because it writes nothing anywhere -
//    it selects a destination the captain could have reached from the nav.
//    A confirm card in front of a link would be a modal in front of a link.
//
// That second claim is load-bearing, so it is kept literally true rather
// than approximately: `open_sre_lead` deliberately **will not connect a host
// that is not already connected** (see `StrawHatHandoff`), because forking a
// real `ssh` and possibly prompting for Touch ID is not navigation. It
// switches into a live session or lands on the Hosts page.
//
// ## Validated to a real enum at parse time, never carried as a string
//
// `create_schedule_draft` and `open_destination` both name something from a
// closed set the app already owns (`ScheduledActionKind`, `RailDestination`),
// and both are resolved **here** rather than in the executor. A model that
// invents an action or a destination therefore produces no proposal at all -
// the same structural refusal an invented `kind` gets, one level in - and the
// executor's `switch` has nothing left to validate.
//
// `open_destination`'s set is additionally an allowlist *narrower* than
// `RailDestination`: see `StrawHatHandoff.allowedDestinations`.
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
//
// ## One exception to "the reply is never dropped": leaked tool-use narration
//
// Phase 2.5's read-only tools gave the model something to deliberate about
// mid-turn, and that deliberation can leak into the visible reply as an
// unattributed message with no crew avatar - the captain's own screenshot
// caught one verbatim: "Context already says tasks_due_soon: 0, no need for
// a tool call." `StrawHatCrew.persona`'s "HOW TO REPLY" section now forbids
// narrating a tool-use decision outright, in any form, whether or not a tool
// ran; `isLikelyToolNarration` is the parser-side belt to that persona-side
// braces, for whatever gets through anyway.
//
// It is deliberately a narrow, specific check (literal context/tool field
// names, or a phrase about the tool-call decision itself) rather than
// treating every leading/trailing prose fragment as suspect - the
// "genuinely both" case two paragraphs up (a reply explaining its own reply
// format) is real content the captain may have asked for, and stays exactly
// as it was. Only a fragment matching one of those two specific signals is
// suppressed: as unattributed leading/trailing prose around a real envelope,
// it is dropped outright (the genuine crew reply already renders in full,
// so a garbled aside next to it is a strict downgrade); as the *entire*
// reply (rung 3, no envelope at all), `StrawHatController.renderReply`
// renders a plain "that reply didn't come through cleanly" note instead of
// putting the leaked fragment in Luffy's own voice - misattributing internal
// reasoning to a character speaking in character is exactly the kind of
// immersion break this whole feature exists to avoid.

import Foundation

/// What a crew member may propose. **Closed on purpose** - see this file's
/// header. Raw values are the wire strings the persona names.
enum StrawHatProposalKind: String, CaseIterable {
    case addTask = "add_task"
    case addFollowUp = "add_follow_up"
    case createRunbookDraft = "create_runbook_draft"
    // Phase 3 (M3.1) - one per new voice.
    case addSticky = "add_sticky"
    case saveCommandDraft = "save_command_draft"
    case createScheduleDraft = "create_schedule_draft"
    // Phase 3 (M3.2) - navigation, not writes. See `isNavigation`.
    case openSRELead = "open_sre_lead"
    case openDestination = "open_destination"

    /// Whether this kind only *navigates*.
    ///
    /// The whole of the write/handoff split in the file header rests on this
    /// one property: the view picks a confirm card or a link row from it, and
    /// `StrawHatProposalExecutor` reads it to decide whether a press is a
    /// store write at all. A kind that writes anywhere - a store, a file, a
    /// remote - must answer `false`, and `StrawHatSelfTest` asserts the
    /// membership of both sides as a literal list so a new kind cannot be
    /// quietly filed on the side that needs no confirmation.
    var isNavigation: Bool {
        switch self {
        case .addTask, .addFollowUp, .createRunbookDraft,
             .addSticky, .saveCommandDraft, .createScheduleDraft:
            return false
        case .openSRELead, .openDestination:
            return true
        }
    }

    /// Whether the model has to supply a `title`, or the app derives one.
    ///
    /// Derived is better wherever the title is a *function of already
    /// validated data*: a schedule draft's title is its `ScheduledActionKind`'s
    /// own picker title, and a handoff's is its destination's own name. That
    /// keeps "nothing is invented" literally true - a derived title comes out
    /// of a closed enum, not out of a guess - and stops a model being asked
    /// to name something the app already names better.
    var requiresTitle: Bool {
        switch self {
        case .addTask, .addFollowUp, .createRunbookDraft, .addSticky, .saveCommandDraft:
            return true
        case .createScheduleDraft, .openSRELead, .openDestination:
            return false
        }
    }

    /// The confirm card's own kicker (or the handoff row's).
    var label: String {
        switch self {
        case .addTask: return "New task"
        case .addFollowUp: return "New follow-up"
        case .createRunbookDraft: return "Runbook draft"
        case .addSticky: return "Sticky note"
        case .saveCommandDraft: return "Command draft"
        case .createScheduleDraft: return "Schedule draft"
        case .openSRELead: return "Hand off"
        case .openDestination: return "Hand off"
        }
    }

    /// The confirm button's title - a verb, because clicking it writes. For a
    /// navigation kind it is the link row's own title instead, and says where
    /// the click goes rather than what it changes.
    var confirmTitle: String {
        switch self {
        case .addTask: return "Add task"
        case .addFollowUp: return "Add follow-up"
        case .createRunbookDraft: return "Save draft"
        case .addSticky: return "Add note"
        case .saveCommandDraft: return "Save command"
        case .createScheduleDraft: return "Create schedule"
        case .openSRELead: return "Open SRE Lead"
        case .openDestination: return "Open"
        }
    }

    /// Past tense, for the card's confirmed state and the toast. Unused by the
    /// navigation kinds, which have no "after" state on the row - the app
    /// simply moves.
    var confirmedTitle: String {
        switch self {
        case .addTask: return "Added to Tasks"
        case .addFollowUp: return "Added to Follow-ups"
        case .createRunbookDraft: return "Saved to Runbooks"
        case .addSticky: return "Added to Sticky Board"
        case .saveCommandDraft: return "Saved to Commands"
        case .createScheduleDraft: return "Added to Schedules"
        case .openSRELead, .openDestination: return "Opened"
        }
    }

    var symbol: String {
        switch self {
        case .addTask: return "checkmark.circle"
        case .addFollowUp: return "bell"
        case .createRunbookDraft: return "doc.text"
        case .addSticky: return "note.text"
        case .saveCommandDraft: return "terminal"
        case .createScheduleDraft: return "clock.arrow.circlepath"
        case .openSRELead: return "shield.lefthalf.filled"
        case .openDestination: return "arrow.up.forward.square"
        }
    }

    /// Which store this writes to, named for the card's own detail line so the
    /// captain can see where a click lands before making it. For a navigation
    /// kind this is where the click *goes*, which is the same question.
    var destination: String {
        switch self {
        case .addTask, .addFollowUp: return "Tasks"
        case .createRunbookDraft: return "Runbooks"
        case .addSticky: return "Sticky Board"
        case .saveCommandDraft: return "DevOps Commands"
        case .createScheduleDraft: return "Schedules"
        case .openSRELead: return "SRE Lead"
        case .openDestination: return "another page"
        }
    }
}

/// Where a navigation handoff goes - the resolved half of `open_sre_lead` /
/// `open_destination`, built by the parser out of real enum cases so nothing
/// downstream has a string to interpret.
enum StrawHatHandoff: Equatable {
    /// SRE Lead on a host. The hint is whatever the *captain* called the host
    /// earlier in the conversation, if the model repeated it - never
    /// something the crew can look up, because hosts are deliberately outside
    /// everything they can see (`StrawHatCrew.persona`'s bounded-visibility
    /// rule, and `StrawHatContext` carries no hosts). The app resolves it
    /// against the real host store, or refuses to guess: see
    /// `AppShellController.openSRELeadForCrew`.
    case sreLead(hostHint: String?)
    /// A destination, already checked against `allowedDestinations`. The
    /// `hint` is the idea the crew was talking about, carried so a handoff can
    /// land on the target's own entry point with it rather than on an empty
    /// page - today that is the Whiteboard's "Generate diagram" composer,
    /// which is Usopp's "draw it out" (M3.1). Every other destination ignores
    /// it.
    case destination(RailDestination, hint: String?)

    /// The destinations a crew handoff may name. **An allowlist, and narrower
    /// than `RailDestination` on purpose.**
    ///
    /// The closed-enum argument that makes `StrawHatProposalKind` safe applies
    /// again one level in, and it is not only about capability: a link row runs
    /// on a single click with no confirmation, so "which pages may a model put
    /// a one-click link to" is a real question. What is deliberately out:
    ///
    ///  - **`.poneglyph` and `.vault`** - the captain's credential surfaces. A
    ///    crew member producing a one-click link to a password store is the
    ///    phishing-shaped move to make structurally impossible, whatever the
    ///    surrounding text says. The crew is told it cannot see the vault; it
    ///    does not get to send the captain there either.
    ///  - **`.settings`, `.bootstrap`, `.updates`, `.automation`,
    ///    `.githubSync`** - machine configuration and unattended-write pages.
    ///    None is a handoff from a conversation; all are places the captain
    ///    goes deliberately.
    ///  - **`.dictation`** - a device-permission page, not a work surface.
    ///  - **`.overview` / `.homeCanvas`** - where the chat already is. A
    ///    handoff to the page you are on is a dead link.
    ///
    /// What is in is every surface a crew member can genuinely hand work to.
    static let allowedDestinations: [RailDestination] = [
        .console, .hosts, .kubernetes, .logAnalyzer, .health,
        .shift, .review, .schedules,
        .runbooks, .postmortems, .docs,
        .whiteboard, .stickyBoard, .codePreview, .tools,
    ]

    /// The row's own title - derived, never model-authored. A handoff whose
    /// label the model wrote could say "open your tasks" over a link to
    /// something else entirely.
    var title: String {
        switch self {
        case .sreLead(let hint):
            guard let hint else { return "Open SRE Lead on a host" }
            return "Open SRE Lead on \u{201C}\(hint)\u{201D}"
        case .destination(let dest, _):
            return "Open \(dest.title)"
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
    /// and meaningless for every other kind.
    let content: String?
    /// A saved command's own shell template, `{{token}}` placeholders and all.
    /// Required for `.saveCommandDraft`, meaningless elsewhere.
    ///
    /// **Never carries a risk level.** `CommandRiskLevel` on a saved command
    /// is a record of a *human* having read the text and vouched for it, so a
    /// model-supplied one would be a vouch nobody made - audit #2 §5.3's own
    /// finding, one store over. The level is re-derived from this string by
    /// `CommandRiskConfirmation.heuristicRisk` at execution time.
    let command: String?
    /// Which of the app's six pre-approved scheduled actions this draft would
    /// run. Required for `.createScheduleDraft`.
    ///
    /// Already the real enum, resolved by the parser - so this cannot name an
    /// automation the app does not have, and Franky cannot invent one. See
    /// this file's header.
    let scheduleAction: ScheduledActionKind?
    /// How often. Required for `.createScheduleDraft`, and likewise already
    /// parsed into the real type rather than left as text.
    let scheduleCadence: ScheduleCadence?
    /// Where a navigation kind goes. Required for `.openSRELead` /
    /// `.openDestination` and nil for every write kind.
    let handoff: StrawHatHandoff?

    init(kind: StrawHatProposalKind, title: String, due: String? = nil,
         notes: String? = nil, content: String? = nil, command: String? = nil,
         scheduleAction: ScheduledActionKind? = nil,
         scheduleCadence: ScheduleCadence? = nil,
         handoff: StrawHatHandoff? = nil) {
        self.kind = kind
        self.title = title
        self.due = due
        self.notes = notes
        self.content = content
        self.command = command
        self.scheduleAction = scheduleAction
        self.scheduleCadence = scheduleCadence
        self.handoff = handoff
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
        // The command itself is the whole point of the card - the captain is
        // about to let model-written shell text into their own library, so it
        // is on the card *before* the gate, not only inside the alert.
        if kind == .saveCommandDraft, let command {
            parts.append(command)
        }
        if kind == .createScheduleDraft, let scheduleCadence {
            parts.append(scheduleCadence.displayString)
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
        // losing either side of this was the wrong trade. The one exception:
        // text that looks like leaked tool-use deliberation rather than a
        // genuine aside - see `isLikelyToolNarration`'s own header - is
        // dropped instead of rendered, since the real crew reply already
        // renders fully in `sections` and putting a garbled internal-
        // reasoning fragment next to it is a strict downgrade, not a second
        // thing worth showing.
        if let leading = found.leading {
            if isLikelyToolNarration(leading) {
                AppLog.ai.info("straw hat: dropped stray pre-envelope text that looked like tool-use narration")
            } else {
                sections.insert(StrawHatSection(speaker: nil, rawSpeaker: "", text: leading,
                                                proposals: [], droppedProposalCount: 0, followup: nil), at: 0)
            }
        }
        if let trailing = found.trailing {
            if isLikelyToolNarration(trailing) {
                AppLog.ai.info("straw hat: dropped stray post-envelope text that looked like tool-use narration")
            } else {
                sections.append(StrawHatSection(speaker: nil, rawSpeaker: "", text: trailing,
                                                proposals: [], droppedProposalCount: 0, followup: nil))
            }
        }
        return .envelope(sections)
    }

    /// Whether `text` reads as the model's own internal tool-use
    /// deliberation leaking into a reply, rather than a genuine answer that
    /// merely missed the envelope wrapper.
    ///
    /// The fixture this was written against is the captain's own screenshot:
    /// a plain, unattributed message reading "Context already says
    /// tasks_due_soon: 0, no need for a tool call." - a sentence about
    /// *whether to call a tool*, quoting the `[CONTEXT ...]` block's own
    /// field name verbatim, that should never have left the model's own
    /// reasoning. `StrawHatCrew.persona`'s "HOW TO REPLY" section now
    /// forbids this outright; this is the belt to that braces.
    ///
    /// **Deliberately narrower than "any leading/trailing prose"**, so the
    /// preserved "genuinely both prose and envelope" case (a reply
    /// explaining its own reply format) is untouched - see `Extracted`'s own
    /// note on why that case keeps both halves, and
    /// `StrawHatSelfTest.checkRung3PlainText`'s "both" fixture, which
    /// contains neither of the two signals below.
    ///
    /// Two signals, either enough on its own:
    ///
    ///  - **A literal context-block or tool identifier**
    ///    (`tasks_due_soon`, `follow_ups_pending`, `shift_read`,
    ///    `docs_search`, `command_search`, `health_snapshot`). These are
    ///    internal wire tokens `StrawHatContext.render()`/`StrawHatTools.
    ///    swift` produce for the model to read, never words the persona asks
    ///    a crew member to say - their presence in ordinary prose is close
    ///    to conclusive on its own.
    ///  - **A phrase about the tool-call decision itself** ("no need for a
    ///    tool call", "don't need to call a tool", "skip the tool call", and
    ///    similar).
    ///
    /// `internal` (not `private`) so `StrawHatSelfTest` can drive it
    /// directly against fixtures a fake `claude` script cannot easily be
    /// made to produce on its own.
    static func isLikelyToolNarration(_ text: String) -> Bool {
        let lower = text.lowercased()
        let tokens = [
            "tasks_due_soon", "follow_ups_pending",
            "shift_read", "docs_search", "command_search", "health_snapshot",
        ]
        if tokens.contains(where: lower.contains) { return true }
        let phrases = [
            "no need for a tool call", "no need for the tool call",
            "no need to call a tool", "no need to call the tool",
            "don't need a tool call", "don't need to call a tool",
            "no tool call needed", "no need to use a tool", "no need to use the tool",
            "not going to call a tool", "skip the tool call",
            "no need to look anything up", "no need to look that up",
        ]
        return phrases.contains(where: lower.contains)
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
        let modelTitle = optionalString(dict["title"])
        if kind.requiresTitle && modelTitle == nil {
            // A kind whose title is the captain's own words needs them, and
            // there is nothing safe to invent - a task called "Untitled" is a
            // task the captain did not ask for. The three kinds whose title is
            // a function of validated data derive it below instead.
            AppLog.ai.info("straw hat: refused a \(rawKind, privacy: .public) proposal with no title")
            return nil
        }

        let due = optionalString(dict["due"]) ?? optionalString(dict["follow_up_at"])
        let notes = optionalString(dict["notes"]) ?? optionalString(dict["text"])
        let content = optionalString(dict["content"]) ?? optionalString(dict["body"])
        let command = optionalString(dict["command"]) ?? optionalString(dict["template"])

        if kind == .createRunbookDraft && content == nil {
            // A runbook with no body is an empty file in the captain's
            // git-synced docs folder.
            AppLog.ai.info("straw hat: refused a runbook draft with no content")
            return nil
        }

        var scheduleAction: ScheduledActionKind?
        var scheduleCadence: ScheduleCadence?
        var handoff: StrawHatHandoff?

        switch kind {
        case .addTask, .addFollowUp, .createRunbookDraft, .addSticky:
            break

        case .saveCommandDraft:
            // A command draft with no command is a named row that does
            // nothing, and there is nothing to derive it from.
            guard let command else {
                AppLog.ai.info("straw hat: refused a command draft with no command")
                return nil
            }
            // The one-line rule is the *gate's* (`confirmAIAuthored` refuses a
            // multi-line command outright, because only its first line is
            // visible in the alert). Refusing it here as well means the
            // captain never sees a card for something that could not have
            // been saved anyway - and the reason is stated in the log rather
            // than shown as an alert they did not ask for.
            guard !command.contains(where: \.isNewline) else {
                AppLog.ai.info("straw hat: refused a multi-line command draft")
                return nil
            }

        case .createScheduleDraft:
            // Both halves come out of closed types - see this file's header.
            // A model that names an automation the app does not have, or a
            // cadence nothing can read, produces no proposal at all rather
            // than a card whose press would have to guess.
            guard let action = self.scheduledAction(from: dict) else {
                AppLog.ai.info("straw hat: refused a schedule draft with no recognised action")
                return nil
            }
            guard let cadence = self.cadence(from: dict) else {
                AppLog.ai.info("straw hat: refused a schedule draft with no recognised cadence")
                return nil
            }
            scheduleAction = action
            scheduleCadence = cadence

        case .openSRELead:
            // The host hint is optional by design: the crew genuinely cannot
            // see the captain's hosts, so this is only ever a name the captain
            // themselves used. The app resolves it, or refuses to guess.
            handoff = .sreLead(hostHint: optionalString(dict["host"]))

        case .openDestination:
            guard let dest = self.handoffDestination(from: dict) else {
                AppLog.ai.info("straw hat: refused a handoff to an unknown or disallowed destination")
                return nil
            }
            // `notes` is the idea the crew was talking about, so a handoff can
            // land on the target's own entry point carrying it - Usopp's
            // "draw it out" into the Whiteboard's composer. Every other
            // destination ignores it.
            handoff = .destination(dest, hint: notes)
        }

        // Derived, for the kinds whose title is a function of the validated
        // data above rather than something a model should be naming.
        let title = modelTitle
            ?? scheduleAction?.pickerTitle
            ?? handoff?.title
            ?? kind.label

        return StrawHatProposal(kind: kind, title: title, due: due, notes: notes,
                                content: content, command: command,
                                scheduleAction: scheduleAction, scheduleCadence: scheduleCadence,
                                handoff: handoff)
    }

    /// One of the app's six pre-approved scheduled actions, matched against
    /// `ScheduledActionKind`'s own raw values plus the snake_case spelling a
    /// model is likelier to write. Anything else is refused.
    private static func scheduledAction(from dict: [String: Any]) -> ScheduledActionKind? {
        guard let raw = optionalString(dict["action"])?.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "") else { return nil }
        return ScheduledActionKind.allCases.first { $0.rawValue.lowercased() == raw }
    }

    /// A destination from `StrawHatHandoff.allowedDestinations`, matched
    /// against `RailDestination`'s raw values (case- and separator-insensitive,
    /// since a model writes "log_analyzer" as readily as "logAnalyzer").
    ///
    /// A destination that exists but is not on the allowlist is refused
    /// exactly like one that does not exist - the log line does not
    /// distinguish them, because "this page is off-limits to you" is not
    /// information a persona needs to be taught by trial and error.
    private static func handoffDestination(from dict: [String: Any]) -> RailDestination? {
        guard let raw = optionalString(dict["destination"])?.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "") else { return nil }
        return StrawHatHandoff.allowedDestinations.first { $0.rawValue.lowercased() == raw }
    }

    /// `"daily 09:00"` or `"weekly monday 06:00"`, and nothing else.
    ///
    /// Deliberately strict rather than forgiving. `ShiftDateParser` is the
    /// app's natural-language *date* scanner and is reused for a task's due
    /// date, but a cadence is not a date - it is a recurrence, and a schedule
    /// that fires at the wrong hour every day forever is a worse failure than
    /// a refused draft. `ScheduleCadence.normalized` clamps the numbers, so a
    /// parsed cadence can never be one that matches nothing.
    private static func cadence(from dict: [String: Any]) -> ScheduleCadence? {
        guard let raw = optionalString(dict["cadence"])?.lowercased() else { return nil }
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard let first = parts.first else { return nil }

        func clock(_ text: String) -> (hour: Int, minute: Int)? {
            let halves = text.split(separator: ":").map(String.init)
            guard halves.count == 2, let h = Int(halves[0]), let m = Int(halves[1]),
                  (0...23).contains(h), (0...59).contains(m) else { return nil }
            return (h, m)
        }

        switch first {
        case "daily", "nightly":
            guard parts.count == 2, let time = clock(parts[1]) else { return nil }
            return ScheduleCadence.daily(hour: time.hour, minute: time.minute).normalized
        case "weekly":
            guard parts.count == 3, let time = clock(parts[2]),
                  let weekday = ScheduleCadence.weekdayNames
                    .firstIndex(where: { !$0.isEmpty && $0.lowercased() == parts[1] }) else { return nil }
            return ScheduleCadence.weekly(weekday: weekday, hour: time.hour, minute: time.minute).normalized
        default:
            return nil
        }
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
