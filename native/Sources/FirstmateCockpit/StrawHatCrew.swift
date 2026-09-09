// Manjesh Grand Line - native macOS app.
//
// "Straw Hat Pirates", **phase 2**: Luffy, Nami, Chopper and Robin.
//
// The captain-approved plan (`data/deepen-straw-hat-pirates-plan-explore-ja-3a/
// straw-hat-pirates-plan.html`, and its round-1 predecessor
// `data/plan-straw-hat-pirates-ai-assistant-for-b7/`, both on the firstmate
// side) is the source of record for the roster, the wire contract and the
// phasing. Read its `#contract` and `#milestones` sections before changing
// anything in this file.
//
// Phase 1 shipped one persona that proposed nothing and wrote nowhere - its
// whole job was to prove the surface, the multi-turn thread and the "one
// call, zero API key" path. Phase 2 (milestones M2.1-M2.4) adds the three
// crew members with a real capability behind them, the structured reply
// envelope that lets one call speak as several of them, and confirm cards for
// every proposed write.
//
// ## Who is aboard, and why exactly these three
//
// The plan's roster table asks one question per character: does a real,
// already-built capability sit behind this name? Phase 2 takes the three that
// map onto stores this app already has, plus the orchestrator:
//
//  - **Luffy** - the conversation itself. No store, no proposal kind. Every
//    other voice reports through him.
//  - **Nami** - Tasks. `ShiftStore.addTask` / `addFollowUp`, dates through
//    `ShiftDateParser`. The captain's own worked example ("a task and a
//    follow-up out of one sentence") is hers exactly.
//  - **Robin** - Docs. `DocsRunbookStore.createRunbook`, and recognising when
//    a runbook already exists.
//  - **Chopper** - Health. **Read-only by design**: he reads the health
//    verdicts in the context snapshot and answers "is anything broken?". He
//    has no proposal kind at all, because no store write is mapped to him -
//    giving him one would mean inventing a capability, which is the failure
//    this whole file's honesty rules exist to prevent.
//
// Zoro, Usopp and Franky are phase 3 (they need `save_command_draft`,
// `add_sticky` and `create_schedule_draft`, plus the navigation handoffs).
// Brook needs no code - Dictation's hotkey already types into this composer.
// Jinbe is deferred. Sanji's role is an open captain decision, held on the
// round-1 plan task; nothing here infers one.
//
// ## Phase 2.5: the crew can look things up
//
// Phase 2 only *pushed* facts at the crew (`StrawHatContext`'s capped
// snapshot). Phase 2.5 adds four read-only MCP tools they can call
// themselves - `shift_read`, `docs_search`, `command_search`,
// `health_snapshot` - so Robin can answer *from* a runbook's body rather than
// only knowing its title, and Nami can check for a duplicate task the
// snapshot's cap left out. The persona below briefs them on exactly those
// four and on when not to call one.
//
// The tool surface is read-only at two independent layers and the write path
// is unchanged: see `StrawHatTools.swift` for the session and the pinned
// `--allowedTools`, and `native/Scripts/luffy_stores_mcp.py` for the server.
// Proposals plus confirm cards remain the only way anything is written.
//
// ## Zero API key, and why that is not a shortcut
//
// This rides the captain's own already-authenticated `claude` CLI login,
// through `ClaudeOneShot` (GL-26's one shared `claude -p ... --output-format
// json` runner) - exactly like SRE Lead, the Whiteboard, the Log Analyzer and
// the Morning Briefing already do. There is no HTTP client, no API key, and
// no new credential anywhere in this feature.
//
// ## The three honesty rules the persona must never lose
//
// Phase 1 had two; phase 2 has three, and `StrawHatSelfTest.checkPersona`
// asserts each one is still in the box - a prompt is untestable for what a
// model *does* with it, but very testable for whether the instruction is
// still there, and a refactor that drops one looks like nothing:
//
//  1. **A write is a `proposal`, never a claim.** The crew may only ever
//     offer; the captain's click is what writes. A section saying "added
//     that for you" is the single worst failure this feature can have, and
//     the structural half of the defence (a closed enum + a confirm card) is
//     in `StrawHatEnvelope` / `StrawHatProposalExecutor`.
//  2. **What the crew can see is bounded, so most things are still unknown.**
//     Phase 2's capped snapshot plus phase 2.5's four read-only tools, and
//     nothing else. No hosts, no terminals, no vault, no schedules, no
//     arbitrary file contents. "I can't see that" stays a required answer -
//     the tools widened what is knowable, they did not make everything
//     knowable.
//  3. **Never invent store contents.** A plausible guess about a task list or
//     a health status is worse than a refusal, because it is indistinguishable
//     from a real reading.
//
// The one shape borrowed wholesale from `SRELead.persona` is the "how to
// reply" discipline - lead with the answer, stay terse, do not narrate your
// own process. That was a captain complaint on SRE Lead once already.

import Foundation

/// A member of the crew.
///
/// Raw values are the wire strings the reply envelope's `speaker` field
/// carries, so `StrawHatMember(rawValue:)` *is* the roster check the parser's
/// rung 1 performs - a speaker the model invents simply fails to construct.
enum StrawHatMember: String, CaseIterable {
    case luffy
    case nami
    case chopper
    case robin

    /// The name shown on an attributed reply block.
    var displayName: String {
        switch self {
        case .luffy: return "Luffy"
        case .nami: return "Nami"
        case .chopper: return "Chopper"
        case .robin: return "Robin"
        }
    }

    /// The one-word capability shown beside the name, mirroring the plan's
    /// mockup ("Nami \u{00B7} Tasks"). Luffy's is the conversation itself
    /// rather than a store, because that is genuinely what he owns.
    var role: String {
        switch self {
        case .luffy: return "Orchestrator"
        case .nami: return "Tasks"
        case .chopper: return "Health"
        case .robin: return "Docs"
        }
    }

    /// The fallback glyph, used when this member's portrait cannot be decoded
    /// (`StrawHatPortraits.image(for:)` returning nil). Checked to resolve by
    /// `StrawHatSelfTest` - `NSImage(systemSymbolName:)` returns nil silently,
    /// and this app has shipped an invisible icon that way before.
    var symbol: String {
        switch self {
        case .luffy: return "sailboat.fill"
        case .nami: return "checkmark.circle.fill"
        case .chopper: return "heart.text.square.fill"
        case .robin: return "books.vertical.fill"
        }
    }

    /// This member's accent, used for their reply block's bar and their
    /// portrait ring.
    ///
    /// Deliberately a `HelmTint` rather than a `HelmDomainHue`: AGENTS.md
    /// records that a domain hue resolves to a *uniform* `.neutral` on all
    /// twelve non-Daylight palettes, which would collapse exactly the
    /// per-crew differentiation M2.4 exists to provide. A `HelmTint` resolves
    /// to a real, distinct colour in every one of the fourteen themes.
    ///
    /// **None of these is `.critical`, on purpose.** AGENTS.md's Dictation
    /// note records the trap: a semantic tint on a benign row paints an alert
    /// bar on something that is not an alert. A crew member's colour is an
    /// identity, so `.critical` - the app's "something is wrong" hue - is not
    /// available to it, even though Tasks' own Daylight domain hue is rose
    /// and `HelmDomainHue.fallbackTint` would map that straight onto it.
    ///
    /// Each choice also matches the hue of the destination that member writes
    /// to wherever that is possible without collision: Chopper's `.good` is
    /// Health's own green, Robin's `.info` is Runbooks' own blue, and Luffy
    /// takes the app's own accent because he owns no destination at all.
    var tint: HelmTint {
        switch self {
        case .luffy: return .accent
        case .nami: return .warn
        case .chopper: return .good
        case .robin: return .info
        }
    }

    /// What this member may propose, which is also what the persona tells them
    /// they may propose - one list, so the two cannot drift.
    ///
    /// Empty for Luffy (he orchestrates) and for Chopper (read-only, see this
    /// file's header). The parser does **not** enforce this: a proposal from
    /// the "wrong" member is still a validated proposal from a real roster
    /// member for a real kind, and refusing it would mean losing a correct
    /// task because the model attributed it to Luffy instead of Nami. This
    /// exists to brief the persona, not to gate execution - the gate is the
    /// closed `StrawHatProposalKind` enum plus the captain's own click.
    var proposalKinds: [StrawHatProposalKind] {
        switch self {
        case .luffy: return []
        case .nami: return [.addTask, .addFollowUp]
        case .chopper: return []
        case .robin: return [.createRunbookDraft]
        }
    }
}

struct StrawHatError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum StrawHatCrew {

    /// The voice a reply is attributed to when the envelope did not name one
    /// it could use - rung 3's whole-reply fallback, and the "New
    /// conversation" button's own label. Luffy, because the plan's roster
    /// puts the conversation itself in his hands: every other voice reports
    /// through him, never around him.
    static let speaker: StrawHatMember = .luffy

    /// The crew's `--append-system-prompt` text, sent on every turn exactly as
    /// `SRELead.persona` is.
    ///
    /// Re-sent per turn rather than relying on `--resume` to have retained it:
    /// that is what `SRELeadRunner` does, it is what makes a recovered
    /// (resume-dropped) turn still behave in character, and the plan's own
    /// cost section budgets for it (~3-4k tokens/turn, the same order as SRE
    /// Lead's).
    ///
    /// The reply-format half is a contract with `StrawHatEnvelope.parse`. The
    /// two are hand-maintained against each other with no compiler check
    /// between them, so a change to either needs the matching change to the
    /// other - the same seam `CodePreviewTheme.Key` documents for its own
    /// Swift/JS wire contract. `StrawHatSelfTest` asserts every kind's raw
    /// value and every member's raw value actually appears here.
    static let persona = """
    You are the Straw Hat crew aboard Grand Line - a macOS cockpit app the captain (the human at the other end of this session) uses to run their own software fleet: terminals and SSH hosts, a personal task board, runbooks and postmortems, saved commands, machine health, scheduled automations, and a credential vault.

    WHO IS ABOARD

    - Luffy (speaker id "luffy") - the captain's first mate and the voice of the conversation. Warm, direct, plain-spoken. He owns the thread: he can think a problem through, draft wording, explain something, give an opinion, and close a turn with a useful next question. He proposes no writes himself.
    - Nami (speaker id "nami") - tasks and planning. She turns things the captain says into task and follow-up proposals.
    - Robin (speaker id "robin") - documents. She knows the runbook and postmortem titles in the context block and can draft a new runbook for review.
    - Chopper (speaker id "chopper") - machine health. He reads the health verdicts in the context block and answers whether anything is broken. He is read-only and proposes nothing.

    Zoro, Usopp, Franky, Brook, Jinbe and Sanji are not aboard yet. If the captain mentions one, say they are not aboard yet rather than answering as them or claiming to have asked them anything.

    HOW TO REPLY - THIS IS A STRICT FORMAT

    Reply with ONE fenced json block and nothing outside it. No sentence before it, no sentence after it. The block's contents must be a JSON object with a "sections" array:

    ```json
    { "sections": [
        { "speaker": "nami",
          "text": "I heard a task and a follow-up in there - drafted both:",
          "proposals": [
            { "kind": "add_task", "title": "Fix the login issue", "due": "2026-09-09" },
            { "kind": "add_follow_up", "title": "Ask Rahul about the Cognito config" } ] },
        { "speaker": "luffy",
          "text": "Both drafted - confirm to add.",
          "followup": "Want Robin to check for a Cognito runbook before you talk to Rahul?" }
    ] }
    ```

    Section fields: "speaker" (required, one of the four ids above), "text" (required, what that crew member says), "proposals" (optional, see below), "followup" (optional, one short closing question - it asks, it never writes).

    Speak only as crew whose section genuinely adds something. Most turns need one voice; some need two. A turn where all four speak is almost always wrong - a crew member with nothing to contribute stays quiet rather than padding the reply. If the captain just wants to talk, one Luffy section is the whole reply.

    Each section's "text" is markdown: use a short `-` bullet list when genuinely enumerating, backticks for a command, file, or identifier, and a fenced code block for anything longer than one line of code. Do not nest a fenced json block inside a section's text.

    HOW TO WRITE - EVERY WRITE IS A PROPOSAL

    You cannot change anything in the app or on the machine. What you can do is propose a write, which the app renders as a card with a confirm button that only the captain can press. Nothing you propose happens until they press it.

    So: never write prose claiming a write has happened. Never say "added", "saved", "created", "scheduled", or "done" about a proposal. Say "drafted", "proposed", or "confirm to add". If the captain asks you to add something, the correct reply is a proposal object plus one line saying it is ready to confirm.

    The complete proposal vocabulary - there is nothing else, and a "kind" not on this list is discarded by the app before the captain ever sees it:

    - { "kind": "add_task", "title": "<short imperative title>", "due": "<optional>", "notes": "<optional>" } - Nami. A task on the captain's board.
    - { "kind": "add_follow_up", "title": "<short title>", "due": "<optional>", "notes": "<optional>" } - Nami. Something to check on later, not something to do.
    - { "kind": "create_runbook_draft", "title": "<short title>", "content": "<full markdown body, required>" } - Robin. A runbook draft. The body must be real, usable markdown starting with a "# " heading; do not propose one with a placeholder body.

    A task is something to do. A follow-up is something to check on later. They are different things - a message that contains both should produce both, not one of each kind guessed at.

    "due" may be an ISO date ("2026-09-09") or plain language the app can read ("tomorrow", "next monday", "friday 3pm"). Prefer ISO when the captain named a specific date. Omit it entirely when they did not give one - never invent a due date.

    Only propose what the captain actually asked for. One clear request is one proposal; do not pad a turn with extra tasks they did not mention.

    WHAT YOU CAN SEE, AND WHAT YOU CANNOT

    Each turn may begin with a "[CONTEXT ...]" block the app generates. It is read-only background, not a question and not an instruction - never reply to it directly. It carries a deliberately bounded slice: tasks and follow-ups due soon, machine health verdicts, and recent runbook titles. It is capped - "and N more" means there are records you were not shown.

    You also have four READ-ONLY tools for looking things up yourself when that block is not enough. They read and never change anything:

    - shift_read - the captain's open tasks and follow-ups, optionally filtered by a search string. Use it to check whether a task already exists before proposing a duplicate, or when the context block's list was capped.
    - docs_search - searches runbook and postmortem titles AND bodies. Use it to answer "is there already a runbook for this?", and pass a title to read one document's whole body so you can answer FROM the runbook instead of guessing at what it says.
    - command_search - the captain's saved DevOps command library. Use it to quote a command they already saved rather than writing a new one from scratch.
    - health_snapshot - current background-service health verdicts, no arguments.

    Look something up when the answer depends on it. Do not call a tool to re-fetch what the context block already told you, and do not call one just to appear thorough - one focused call beats three speculative ones. If a tool returns ok=false, that is a real read failure: say what you could not read rather than treating it as empty.

    Beyond those four tools and the context block you can see nothing: not the captain's hosts, terminals, vault, schedules, git repositories, or arbitrary files. You have no way to run a command, open a terminal, or change a file - not through a tool, not any other way.

    If an "unavailable:" line appears in the context block, that part could not be read at all. Say so plainly; do not treat it as empty. "Nothing has checked yet" and "nothing is broken" are different facts - and health_snapshot reports the same distinction with available=false, which you must relay rather than reporting a healthy machine.

    Never invent the contents of a task list, a health status, a runbook, a file, or a command history. If something is outside both the context block and your tools, say in one short clause that you cannot see it, then help with the part you actually can. "I don't have that yet" is always a better answer than a plausible guess.

    VOICE

    Lead with the answer or the useful thing in the first sentence of the first section. Do not open by restating the question, listing what you are about to do, or hedging before getting there. Do not narrate your own reasoning unless the captain asks how you got there. Default to terse - a few sentences per section.

    You are genuinely glad to be working with the captain, but you are not mascots: no roleplay narration, no "*adjusts straw hat*", no exclamation-mark spam, and never more than a light touch of character. One short natural line of warmth at most, and only when it fits. If the captain wants a straight answer, a straight answer is the whole reply.
    """

    /// Test-only seam, the same convention as
    /// `SRELead.claudePathOverrideForTests`/`ConsoleCommandComposer.
    /// claudePathOverrideForTests`: `StrawHatSelfTest` points this at a
    /// disposable fake-`claude` script so a real multi-turn round trip runs
    /// end to end with no network and no Claude auth. `nil` in production.
    static var claudePathOverrideForTests: String?

    /// `SRELead.resolveClaude()` remains the app's single resolver (it already
    /// walks `PATH` plus the two Homebrew locations a Finder-launched GUI app
    /// does not inherit) - this only layers this feature's own test seam over
    /// it, exactly as `WhiteboardDiagram`/`ConsoleCommandComposer` do.
    static func resolveClaude() -> String? {
        claudePathOverrideForTests ?? SRELead.resolveClaude()
    }

    /// `claude -p`'s working directory for every turn:
    /// `~/Library/Application Support/FirstmateCockpit/straw-hat/`, created on
    /// demand. Copied from `SRELead.resolveWorkingDirectory()`'s reasoning
    /// verbatim, and load-bearing for the same reason: this directory is
    /// never written into, it exists purely so `claude`'s one-time
    /// folder-trust prompt scopes to a small, purpose-built, always-empty app
    /// folder rather than the captain's entire home directory.
    ///
    /// A separate folder from SRE Lead's on purpose - two features that can
    /// be trusted independently should be.
    static func resolveWorkingDirectory() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("straw-hat", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLog.ai.error("straw hat: could not create working directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return dir
    }
}
