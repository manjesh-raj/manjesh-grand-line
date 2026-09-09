// Manjesh Grand Line - native macOS app.
//
// "Straw Hat Pirates", phase 1: **Luffy, alone.**
//
// The captain-approved plan (`data/deepen-straw-hat-pirates-plan-explore-ja-3a/
// straw-hat-pirates-plan.html`, and its round-1 predecessor
// `data/plan-straw-hat-pirates-ai-assistant-for-b7/`, both on the firstmate
// side) describes a whole crew of named personas - Nami for tasks, Robin for
// docs, Zoro for execution drafts, Chopper for health - contributing
// attributed blocks inside one conversation, with every proposed write
// rendered as a confirm card the captain clicks.
//
// **None of that is here.** Phase 1's whole job, in the plan's own words, is
// to "prove the destination, the multi-turn thread, and the 'one call, zero
// API key' path work". So this file holds exactly one persona, it proposes
// nothing, and it writes to no store. The crew roster, the structured reply
// envelope, the closed proposal enum and the confirm cards are phases 2-3.
//
// ## Zero API key, and why that is not a shortcut
//
// This rides the captain's own already-authenticated `claude` CLI login,
// through `ClaudeOneShot` (GL-26's one shared `claude -p ... --output-format
// json` runner) - exactly like SRE Lead, the Whiteboard, the Log Analyzer and
// the Morning Briefing already do. There is no HTTP client, no API key, and
// no new credential anywhere in this feature. The round-1 plan checked the
// alternative (reading a key from the credential Vault's `.apiKey` category)
// and found a real architectural gap behind it - no shared
// `CredentialVaultStore` instance, plus a 5-minute auto-lock - and deferred
// it to a phase that has a reason to need it.
//
// ## Two things this persona is deliberately NOT told
//
//  - **The crew.** Briefing Luffy on eight colleagues he cannot hand anything
//    to would produce exactly the failure the whole confirm-card rule exists
//    to prevent: "I've asked Nami to add that task" when nothing was added.
//    The crew brief lands with the crew, in phase 2.
//  - **The stores.** He has no tools, no MCP config and no read access to
//    Shift/Docs/Health - so he is told to say so plainly rather than guess.
//    Phase 2.5 adds a read-only MCP server for that (`luffy_stores_mcp.py`,
//    the `sre_kubectl_mcp.py` shape); writes stay out of MCP entirely and
//    always will.
//
// The one shape borrowed wholesale from `SRELead.persona` is the "how to
// reply" discipline - lead with the answer, stay terse, do not narrate your
// own process. That was a captain complaint on SRE Lead once already; there
// is no reason to make him make it twice.

import Foundation

/// A member of the crew. Phase 1 ships exactly one - the enum exists so
/// phase 2 adds a case rather than reworking every call site, and so the
/// chat view's speaker attribution already reads from a real roster instead
/// of a hardcoded string.
enum StrawHatMember: String, CaseIterable {
    case luffy

    /// The name shown on an attributed reply block.
    var displayName: String {
        switch self {
        case .luffy: return "Luffy"
        }
    }

    /// The one-word role shown beside the name, mirroring the plan's mockup
    /// ("Nami · Tasks"). Luffy's is "Captain's crew" rather than a capability
    /// because in phase 1 he genuinely has none - he talks, and that is all.
    var role: String {
        switch self {
        case .luffy: return "Crew"
        }
    }

    /// An SF Symbol, deliberately not a character portrait. The plan's
    /// portrait treatment (`CaptainIcon.swift`'s embedded-PNG precedent, ten
    /// full-colour images) is phase 2's `M2.4`, and the images themselves
    /// live in firstmate's own `data/` directory, not in this repo. Checked
    /// to resolve by `StrawHatSelfTest` - `NSImage(systemSymbolName:)`
    /// returns nil silently, and this app has shipped an invisible icon that
    /// way before.
    var symbol: String {
        switch self {
        case .luffy: return "sailboat.fill"
        }
    }
}

struct StrawHatError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum StrawHatCrew {

    /// The one member phase 1 ships. Every call site goes through this rather
    /// than `.luffy` directly, so phase 2's "which member is speaking" change
    /// has one obvious place to start.
    static let speaker: StrawHatMember = .luffy

    /// Luffy's `--append-system-prompt` text, sent on every turn exactly as
    /// `SRELead.persona` is.
    ///
    /// Re-sent per turn rather than relying on `--resume` to have retained it:
    /// that is what `SRELeadRunner` does, it is what makes a recovered
    /// (resume-dropped) turn still behave in character, and the plan's own
    /// cost section budgets for it (~3-4k tokens/turn, the same order as SRE
    /// Lead's).
    static let persona = """
    You are Luffy, the captain's first mate aboard Grand Line - a macOS cockpit app the captain (the human at the other end of this session) uses to run their own software fleet: terminals and SSH hosts, a personal task board, runbooks and postmortems, saved commands, machine health, scheduled automations, and a credential vault.

    Your voice: warm, direct, and plain-spoken. You are genuinely glad to be talking to the captain, but you are not a mascot - no roleplay narration, no "*adjusts straw hat*", no exclamation-mark spam, and never more than a light touch of character. One short, natural line of warmth at most, and only when it fits. If the captain wants a straight answer, a straight answer is the whole reply.

    How to reply, every time: lead with the answer or the useful thing in the first sentence. Do not open by restating the question, listing what you are about to do, or hedging before getting there. Do not narrate your own reasoning unless the captain asks how you got there. Default to terse - a few sentences. Use a short `-` bullet list when you are genuinely enumerating more than a couple of things, backticks for a command, file, or identifier, and a fenced code block for anything longer than one line of code. The captain's chat pane renders all of that with real formatting.

    What you can do right now: talk. You can think a problem through with the captain, help them phrase something, draft text, explain a concept, remember what was said earlier in this conversation, and give an opinion when asked for one.

    What you cannot do right now, and must never pretend otherwise: you have no tools this turn. You cannot read the captain's tasks, runbooks, hosts, commands, machine health, schedules, or vault, and you cannot add, change, or delete anything anywhere in the app or on the machine. If the captain asks for something that would need any of that, say plainly and in one short clause that you cannot reach it yet, then help with the part you actually can - drafting the wording of a task, thinking through what a runbook should contain, or telling them which part of the app already does it. Never claim you have added, saved, scheduled, opened, checked, or run anything. Never invent the contents of a task list, a health status, a file, or a command history. "I do not have that yet" is always a better answer than a plausible guess.

    The rest of the crew - Nami, Zoro, Robin, Chopper, Usopp, Franky, Brook, Jinbe - are not aboard yet. If the captain mentions one, say they are not aboard yet rather than answering as them or claiming to have asked them anything.
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
