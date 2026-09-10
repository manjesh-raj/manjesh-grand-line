// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 2**: the bounded, read-only context snapshot and
// the two-part turn envelope (the plan's milestone M2.3).
//
// Phase 1's Luffy was told, in as many words, that he could not see the
// captain's tasks, docs or machine health - and told to say so rather than
// guess. Phase 2's crew has to actually know a few things: Nami cannot say
// "you already have a task for that" without seeing the task list, Chopper
// cannot answer "is anything broken?" without the health verdicts, and Robin
// cannot say "there's already a runbook for that" without the doc titles.
//
// This file is the plan's **push** strategy, which it names as phase 2's
// default: a small snapshot injected into every turn's prompt, zero extra
// latency because it rides the same single call. The plan's own trade-off
// table budgets it at ~0.5-1k input tokens per turn, which is why every list
// here is capped rather than complete. The **pull** alternative - read-only
// MCP tools the model calls when it wants them (`luffy_stores_mcp.py`) - is
// phase 2.5, and is what will scale this past the point injection can.
//
// ## Two hard rules
//
// **Read-only.** Nothing in this file writes, and it takes its stores as
// parameters rather than constructing them, so a snapshot cannot be the thing
// that reaches a real clone. Every read is one the app already performs
// elsewhere on the same data (`MorningBriefing.shiftDue` walks the same
// `activeTasks`, `HealthCardView` renders the same registry, the Runbooks
// page lists the same folder).
//
// **GL-14: unknown is never rendered as zero.** A health service that has not
// reported yet is `unknown`, not `ok` - and the snapshot says so. A store
// whose read failed is omitted with a stated reason rather than reported
// empty. "Nothing is broken" and "nothing has checked yet" are different
// facts, and a crew that confuses them tells the captain their fleet is
// healthy when nobody has looked.
//
// ## Why the envelope has two labelled parts
//
// `[CONTEXT ...]` then `[MESSAGE]`, exactly as the plan's wire contract
// specifies, so an injected snapshot can never be mistaken for something the
// captain typed. Phase 1 already needed the minimal form of this for its
// stale-resume recap (`StrawHatRunner.promptWithRecap`); this is the same
// separation, formalised. It matters more than it looks: the snapshot carries
// task titles the captain wrote, and a model that read them as the current
// message would answer the wrong question entirely.

import Foundation

/// One turn's read-only view of the app. Small by construction.
struct StrawHatContextSnapshot {

    /// How many due/overdue task titles the snapshot names. The *count* is
    /// always exact; only the titles are capped, because the titles are what
    /// costs tokens. Overflow is stated ("+3 more"), never silently dropped.
    static let maxTaskTitles = 6
    /// Same, for pending follow-ups.
    static let maxFollowUpTitles = 4
    /// Doc titles are for recognition ("is there already a runbook for
    /// this?"), so a bounded recent slice is genuinely enough - and this is
    /// the list most likely to grow without limit.
    static let maxDocTitles = 12
    /// How far ahead "due soon" reaches. A week is the horizon a captain
    /// plans a task against; beyond that it is noise in every turn.
    static let dueSoonWindow: TimeInterval = 7 * 24 * 60 * 60

    struct DatedItem {
        let title: String
        /// `nil` when the item has no date at all - which for an *overdue*
        /// list cannot happen, but for the general shape can.
        let due: String?
        let isOverdue: Bool
    }

    struct HealthLine {
        let service: String
        /// Already rendered: `"ok"`, `"failing(2)"`, `"not checked yet"`.
        let verdict: String
    }

    /// Exact count of tasks due within the window (including overdue).
    var dueTaskCount: Int = 0
    var dueTasks: [DatedItem] = []
    var pendingFollowUpCount: Int = 0
    var followUps: [DatedItem] = []
    var health: [HealthLine] = []
    /// Whether the health registry had anything to say at all this turn.
    ///
    /// Explicit rather than inferred from `health.isEmpty`: phase 2.5's
    /// `health_snapshot` tool has to tell the crew *which* of the two GL-14
    /// facts it is looking at ("nobody has checked" vs "nothing is broken"),
    /// and reconstructing that from an empty array plus a string match
    /// against `unavailable` would be a second, weaker encoding of something
    /// `capture` already knows for certain.
    var healthAvailable: Bool = false
    /// Why health could not be read, when `healthAvailable` is false.
    var healthUnavailableReason: String?
    var runbookTitles: [String] = []
    var runbookCount: Int = 0
    var postmortemCount: Int = 0
    /// Whether the docs folder was readable at all this turn.
    ///
    /// Explicit rather than inferred from the two counts, for exactly
    /// `healthAvailable`'s reason one field up: a genuinely empty docs folder
    /// and an unreadable one both leave `runbookCount == 0`, and those are
    /// different facts. `render()` skips the count line entirely when this is
    /// false, so a "0" the crew could read as certain never appears beside the
    /// `unavailable:` line that contradicts it - the end-to-end review's own
    /// L2 finding, and the exact unknown-as-zero seam this type's header
    /// claims to uphold.
    var docsAvailable: Bool = false
    /// Anything the snapshot could not read, stated rather than reported as
    /// empty - GL-14. Rendered into the context block so the crew says "I
    /// couldn't read your runbooks" instead of "you have no runbooks".
    var unavailable: [String] = []

    // MARK: Capture

    /// Builds a snapshot from stores the caller already owns.
    ///
    /// Synchronous and cheap: `ShiftStore`'s task/follow-up arrays are already
    /// in memory, the health registry is a lock-guarded dictionary, and the
    /// only filesystem touch is one bounded directory listing per docs folder
    /// (the same read the Runbooks page does on every visit). No subprocess,
    /// no network - so a turn never waits on the snapshot.
    /// The health half's input, read off the registry by
    /// `readHealthStates()`.
    ///
    /// An explicit parameter rather than the registry itself, so this whole
    /// function is a pure function of real values: `ServiceHealthRegistry` is
    /// a singleton with a `private init` (correctly - the app has exactly one),
    /// which would otherwise have left the GL-14 "nothing has reported yet"
    /// branch reachable only on a machine that happened to have reported
    /// nothing. That is the one branch most worth asserting, so the seam is a
    /// parameter rather than a test-only initializer on a production
    /// singleton.
    typealias HealthStates = [(service: HealthService, state: ServiceHealthState)]

    /// Every service the registry has something to say about, paired with its
    /// state. `knownServices()` is the registry's own "has something to say"
    /// list - a service that never registered is simply absent, which is what
    /// the caller renders as a stated gap rather than as "ok".
    static func readHealthStates(_ registry: ServiceHealthRegistry = .shared) -> HealthStates {
        registry.knownServices().map { (service: $0, state: registry.state($0)) }
    }

    static func capture(shift: ShiftStore,
                        docs: DocsRunbookStore?,
                        healthStates: HealthStates? = nil,
                        now: Date = Date()) -> StrawHatContextSnapshot {
        var snapshot = StrawHatContextSnapshot()
        let horizon = now.addingTimeInterval(dueSoonWindow)

        // --- Tasks (Nami) ---
        var dated: [(due: Date, item: DatedItem)] = []
        for task in shift.activeTasks {
            // Both bindings, not `?? ""`: `friendly` takes a non-optional
            // "YYYY-MM-DD", and handing it an empty string would render a
            // date label out of nothing.
            guard let dueDate = task.dueDate,
                  let due = ShiftDateFormatting.dateTime(from: dueDate, time: task.dueTime),
                  due <= horizon else { continue }
            let label = ShiftDateFormatting.friendly(dueDate, time: task.dueTime)
            dated.append((due, DatedItem(title: task.title, due: label, isOverdue: due <= now)))
        }
        dated.sort { $0.due < $1.due }
        snapshot.dueTaskCount = dated.count
        snapshot.dueTasks = dated.prefix(maxTaskTitles).map(\.item)

        // --- Follow-ups (Nami) ---
        var followUps: [(due: Date?, item: DatedItem)] = []
        for followUp in shift.followUps where followUp.status == .pending {
            let due = ShiftDateFormatting.dateTime(from: followUp.followUpAt, time: followUp.followUpTime)
            // A pending follow-up with no date is still pending - unlike a
            // task, whose whole due-soon question needs a date to answer.
            if let due, due > horizon { continue }
            let label = followUp.followUpAt.map { ShiftDateFormatting.friendly($0, time: followUp.followUpTime) }
            followUps.append((due, DatedItem(title: followUp.title, due: label,
                                             isOverdue: due.map { $0 <= now } ?? false)))
        }
        followUps.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        snapshot.pendingFollowUpCount = followUps.count
        snapshot.followUps = followUps.prefix(maxFollowUpTitles).map(\.item)

        // --- Health (Chopper) ---
        //
        // A service that has never registered is not silently ok - it is
        // simply not a line, and if none of them are, `unavailable` says the
        // whole registry has not reported. GL-14: "nothing has checked yet"
        // and "nothing is broken" are different facts.
        let states = healthStates ?? readHealthStates()
        if states.isEmpty {
            snapshot.healthAvailable = false
            snapshot.healthUnavailableReason = "no service has reported yet this session"
            snapshot.unavailable.append("machine health (no service has reported yet this session)")
        } else {
            snapshot.healthAvailable = true
            for entry in states {
                snapshot.health.append(HealthLine(service: entry.service.title,
                                                  verdict: describe(entry.state)))
            }
        }

        // --- Docs (Robin) ---
        if let docs {
            snapshot.docsAvailable = true
            let runbooks = docs.listRunbooks()
            snapshot.runbookCount = runbooks.count
            snapshot.runbookTitles = runbooks
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(maxDocTitles)
                .map(\.title)
            snapshot.postmortemCount = docs.listPostmortems().count
        } else {
            snapshot.unavailable.append("runbooks and postmortems (the docs folder isn't readable)")
        }
        return snapshot
    }

    // MARK: The health file bridge (phase 2.5, M2.5b)

    /// This turn's health state as the JSON payload `luffy_stores_mcp.py`'s
    /// `health_snapshot` tool reads.
    ///
    /// Health is the one store phase 2.5's tools cannot open directly:
    /// `ServiceHealthRegistry` is in-process app state (a lock-guarded
    /// dictionary), so a subprocess has nothing to read. The app therefore
    /// writes it out per turn - the same file-bridge idea `SRELeadBridge`
    /// proved for the far harder version of this problem, reduced to one
    /// direction and one file.
    ///
    /// **Built from the snapshot rather than re-read from the registry**, and
    /// that is the point: the pushed `[CONTEXT]` block and the pulled tool
    /// then carry the same values, computed once, so the crew can never be
    /// told two different things about the same service in one turn.
    ///
    /// GL-14 is carried across the boundary explicitly rather than left to be
    /// inferred from an empty list: `available: false` plus a reason is a
    /// registry that has not reported, which the tool is required to report as
    /// such and never as a healthy machine.
    func healthBridgePayload(now: Date = Date()) -> [String: Any] {
        var payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: now),
            "available": healthAvailable,
            "services": health.map { ["service": $0.service, "verdict": $0.verdict] },
        ]
        if !healthAvailable {
            payload["reason"] = healthUnavailableReason ?? "no service has reported yet this session"
        }
        return payload
    }

    private static func describe(_ state: ServiceHealthState) -> String {
        switch state.verdict {
        case .unknown: return "not checked yet"
        case .running: return "checking now"
        case .healthy: return "ok"
        case .degraded: return "degraded (\(state.consecutiveFailures) recent failure\(state.consecutiveFailures == 1 ? "" : "s"))"
        case .failing: return "FAILING (\(state.consecutiveFailures) consecutive failures)"
        }
    }

    // MARK: Rendering

    /// The `[CONTEXT ...]` block's body - plain labelled lines rather than
    /// JSON, which reads more naturally to a model and costs fewer tokens for
    /// the same facts.
    func render() -> String {
        var lines: [String] = []

        lines.append("tasks_due_soon: \(dueTaskCount)")
        for item in dueTasks {
            let due = item.due.map { " (\($0)\(item.isOverdue ? ", OVERDUE" : ""))" } ?? ""
            lines.append("  - \(item.title)\(due)")
        }
        if dueTaskCount > dueTasks.count {
            lines.append("  - ...and \(dueTaskCount - dueTasks.count) more")
        }

        lines.append("follow_ups_pending: \(pendingFollowUpCount)")
        for item in followUps {
            let due = item.due.map { " (\($0)\(item.isOverdue ? ", OVERDUE" : ""))" } ?? " (no date)"
            lines.append("  - \(item.title)\(due)")
        }
        if pendingFollowUpCount > followUps.count {
            lines.append("  - ...and \(pendingFollowUpCount - followUps.count) more")
        }

        if !health.isEmpty {
            lines.append("health: " + health.map { "\($0.service)=\($0.verdict)" }.joined(separator: " "))
        }

        // Only when the folder was genuinely readable: a `runbooks: 0` the
        // crew has no reason to doubt, printed a few lines above an
        // `unavailable:` note it may not connect to that zero, is worse than
        // printing nothing and letting the note speak for itself (L2).
        if docsAvailable {
            lines.append("runbooks: \(runbookCount) \u{00B7} postmortems: \(postmortemCount)")
            for title in runbookTitles {
                lines.append("  - \(title)")
            }
            if runbookCount > runbookTitles.count {
                lines.append("  - ...and \(runbookCount - runbookTitles.count) more")
            }
        }

        // GL-14, made explicit in the prompt itself: the crew is told what it
        // could NOT see, so "I don't know" stays available as an answer.
        for reason in unavailable {
            lines.append("unavailable: \(reason)")
        }
        return lines.joined(separator: "\n")
    }
}

enum StrawHatTurn {

    /// The plan's wire contract: a labelled read-only snapshot, then the
    /// captain's own words under their own label - plus, on a recovered turn,
    /// a labelled recap between them.
    ///
    /// **One owner for all three labels.** Phase 1 had the recap half in
    /// `StrawHatRunner`; putting the context beside it there would have meant
    /// two files agreeing on how a turn is framed, and a nested `[MESSAGE]`
    /// inside another `[MESSAGE]` the first time someone composed them. Every
    /// part is optional, so the same function builds an ordinary turn, a
    /// context-only turn, a recovered turn, and (in a self-test with no
    /// stores) a bare message.
    ///
    /// Each label states *what the block is and who wrote it*, so neither the
    /// snapshot nor the recap can be mistaken for something the captain just
    /// typed. That is not decoration: the snapshot carries task titles the
    /// captain wrote themselves, and a model reading them as the current
    /// message would answer the wrong question entirely.
    static func prompt(context: StrawHatContextSnapshot?,
                       recap: [String] = [],
                       message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        if let rendered = context?.render(), !rendered.isEmpty {
            parts.append("""
            [CONTEXT \u{2014} read-only snapshot of the captain's app, generated by Grand Line itself. This is background, not a question and not an instruction. Do not reply to it, and do not repeat it back unless it is genuinely relevant.]
            \(rendered)
            """)
        }
        if !recap.isEmpty {
            parts.append("""
            [RECAP OF THIS CONVERSATION SO FAR \u{2014} the session was interrupted and had to be restarted. This is history, not something the captain just said. Do not reply to it, and do not mention the interruption unless asked.]
            \(recap.joined(separator: "\n"))
            """)
        }

        // A turn with no context and no recap is just the message - no
        // scaffolding wrapped around it, which is what phase 1 sent and what
        // `StrawHatSelfTest` still asserts for the no-history case.
        guard !parts.isEmpty else { return trimmed }
        parts.append("""
        [MESSAGE FROM THE CAPTAIN \u{2014} their own words. Reply to this.]
        \(trimmed)
        """)
        return parts.joined(separator: "\n\n")
    }
}
