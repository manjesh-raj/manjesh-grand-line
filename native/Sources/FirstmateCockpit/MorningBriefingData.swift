// Manjesh Grand Line - native macOS app.
//
// F12 (production-readiness review section 25): the morning briefing - one
// short generated paragraph atop Overview on the first activation of the day,
// each clause deep-linking to the page it came from.
//
// ## The two layers, and why they are kept apart
//
// This file is deliberately built the same way `LogAnalyzerModels.swift` is,
// because the review's own F12 entry names that split as the precedent
// ("degrades to a plain non-AI stat line offline (the Log Analyzer local/AI
// split pattern)"):
//
//   - **`MorningBriefingLocal`** is computed on this machine with no network
//     and no `claude`, and is *always* present. It turns `BriefingInputs`
//     into a deterministic clause list ("2 PRs ready to merge", "1 task needs
//     you", "2 forks behind upstream", "40% of the weekly quota used") whose
//     joined form is exactly the plain stat line the degraded mode renders.
//   - **`MorningBriefingAI`** is one `ClaudeOneShot` call that rewrites those
//     same numbers as prose. It can be absent - no `claude`, not
//     authenticated, offline, a timeout - and its absence costs only the
//     phrasing, never the information.
//
// So the feature is useful with the AI half missing, and the local half is
// what the self-test can pin deterministically (`MorningBriefingSelfTest`).
//
// ## Where the numbers come from - no new collection
//
// The review is explicit that this is "a composer over existing sources...
// no new collection, no raw logs, structured input only", and `BriefingInputs`
// is the enforcement of that: it is a flat struct of counts and short titles,
// with no way to carry a terminal buffer or a log line even by mistake. Every
// field is something a page in this app already computes and already shows:
//
//   - fleet counts            `FleetDataSource.snapshot()` - Overview's own refresh
//   - PRs ready to merge      `FleetDataSource.mergedPRs(...)` - Overview's own refresh
//   - Shift due items         the shared `ShiftStore`'s in-memory lists, via the
//                             same `ShiftDateFormatting.dateTime` reading
//                             `ShiftNotificationScheduler.poll()` already uses
//   - fork drift / tool       `BackgroundSignalsPoller.lastCounts` - the counts
//     updates / setup drift   that poller *already* computed for the
//                             Notification Center, read rather than recomputed
//   - Claude quota            `QuotaSource.fetch()` - the same source the
//                             Claude-usage popover shows
//
// Four of those five are handed in by whoever already fetched them. The one
// this file fetches itself is the quota, because nothing in the app caches it
// (the popover fetches on open), and section 25 lists it as one of the five
// inputs. It runs once per generated briefing - i.e. once a day, or when the
// captain presses refresh.
//
// ## What the model is not allowed to decide
//
// Two rules are enforced in code rather than trusted to the prompt, mirroring
// `LogAnalyzerAI`'s own "observed -> inferred" downgrade:
//
//   1. **The link target comes from a fixed enumeration.** A clause's `link`
//      is matched against `BriefingTarget`'s known raw values and anything
//      unrecognised becomes `.none` (rendered as plain text, not a link that
//      goes nowhere). The model cannot invent a destination.
//   2. **The colour is derived from the target, never from the model.**
//      `BriefingTarget.tint` is the whole mapping, so a model reply can change
//      what a clause *says* and never what it looks like or where it goes.
//
// And the deep link for a single due Shift task is resolved by the *app* from
// its own store (`BriefingInputs.singleDueTaskID`), never from an id the model
// wrote - a hallucinated task id would otherwise open the wrong record.

import Foundation

// MARK: - Where a clause points

/// The fixed set of places a briefing clause may link to. Deliberately a
/// closed `String` enum: it is both the persisted form (`BriefingClause` is
/// `Codable`, so a briefing survives a relaunch within the same day) and the
/// allowlist the model's reply is validated against.
enum BriefingTarget: String, Codable {
    /// No link at all - rendered as plain text. This is what an unrecognised
    /// marker degrades to, and it matters: a link that navigates nowhere is a
    /// lie, and this app's accessibility work (GL-16) is explicit that a
    /// control which does nothing must not present itself as one.
    case none
    /// The Review destination - PRs ready to merge.
    case review
    /// The Tasks (Shift) destination - due tasks and follow-ups.
    case tasks
    /// The GitHub Sync page - forks behind upstream.
    case githubSync
    /// The Updates page - tools with updates available.
    case updates
    /// The Bootstrap page - setup drift.
    case setup
    /// The Claude usage popover (`QuotaUsageController`), anchored on the
    /// briefing paragraph rather than on Console's toolbar button, which is
    /// only present on a Herdr-backed mirror tab.
    case quota
    /// Overview's own "In flight" section - scrolled into view, since the
    /// fleet tasks a clause is talking about are rows on this very page.
    case fleet

    /// The clause's colour, decided here and never by the model. Chosen for
    /// what the clause *means*, on the same "a tint only ever means this
    /// number is itself a signal" rule Overview's stat row already follows.
    var tint: HelmTint {
        switch self {
        case .review: return .good
        case .tasks, .fleet: return .warn
        case .githubSync, .updates: return .info
        case .setup: return .warn
        case .quota: return .neutral
        case .none: return .neutral
        }
    }

    /// Whether this target is actually navigable. `.none` is not, and is the
    /// only one that is not.
    var isLink: Bool { self != .none }
}

// MARK: - One clause

/// One sentence of the briefing plus where it points. `Codable` so a briefing
/// generated this morning is still on screen after a relaunch at lunchtime
/// rather than silently vanishing (or re-running the AI call).
struct BriefingClause: Codable, Equatable {
    let text: String
    let target: BriefingTarget

    init(text: String, target: BriefingTarget) {
        self.text = text
        self.target = target
    }
}

// MARK: - The persisted briefing

/// One generated briefing, as stored in `AppSettings.morningBriefingRecord`.
///
/// `day` is what makes "once per day on first activation" hold across a
/// relaunch: the card re-renders from this record for the rest of the day and
/// only regenerates when `day` no longer matches today (or when the captain
/// presses refresh, which always regenerates).
struct MorningBriefingRecord: Codable, Equatable {
    /// `"yyyy-MM-dd"` in the local calendar - see `MorningBriefing.dayKey`.
    var day: String
    var generatedAt: Date
    var clauses: [BriefingClause]
    /// `true` when the AI half was unavailable and these clauses are the
    /// deterministic local stat line. Drives the card's footer note.
    var isDegraded: Bool
    /// Why, in one short line, when degraded. Shown to the captain rather than
    /// swallowed - the whole point of the degraded mode is that it says what
    /// it is instead of silently looking like a worse briefing.
    var degradedReason: String?
    /// Set by the dismiss (X) action, so the card stays gone for the rest of
    /// the day rather than reappearing on the next visit to Overview.
    var dismissed: Bool
    /// The human-readable list of sources the subtitle names ("the fleet
    /// snapshot, PR queue, tasks, drift, and quota") - only the ones that
    /// actually contributed, so the subtitle never claims an input the
    /// briefing did not have.
    var sources: [String]
    /// The one Shift task a `.tasks` clause should open, when the app itself
    /// determined there is exactly one due. Resolved from the store, never
    /// from model output.
    var shiftTaskID: String?
}

// MARK: - The structured input

/// Everything the briefing is allowed to know. Counts and short, already-
/// displayed titles only - there is deliberately no field here that could
/// hold a terminal buffer, a log line, or any text the captain has not
/// already seen on another page.
///
/// An `Int?` field means "not known this time round" rather than zero, and
/// every consumer below distinguishes the two: a failed PR scan must not read
/// as "no PRs are ready", and a poller that has not run yet must not read as
/// "nothing has drifted".
struct BriefingInputs: Equatable {
    var homeOk: Bool = true

    // Fleet - `FleetDataSource.snapshot()`
    var workingCount: Int = 0
    var needsDecisionCount: Int = 0
    var blockedCount: Int = 0
    var doneTodayCount: Int = 0
    var queuedCount: Int = 0
    var watcherStatus: String = "unknown"

    // PR queue - `FleetDataSource.mergedPRs(...)`. `nil` = the scan was
    // degraded, so readiness is unknown (GL-14's rule).
    var prReadyCount: Int?

    // Tasks - the shared `ShiftStore`
    var dueTaskCount: Int = 0
    var dueFollowUpCount: Int = 0
    /// Set only when exactly one task is due, so a `.tasks` clause can open
    /// that record directly instead of the destination.
    var singleDueTaskID: String?

    // Drift/updates - `BackgroundSignalsPoller.lastCounts`
    var forkDriftCount: Int?
    var toolUpdateCount: Int?
    var setupDriftCount: Int?

    // Claude quota - `QuotaSource.fetch()`
    var quotaWeeklyPercentUsed: Double?
    var quotaWeeklyPace: String?
    var quotaSessionPercentUsed: Double?

    /// Which of the five inputs actually contributed, in the order the
    /// mockup's subtitle names them.
    var contributingSources: [String] {
        var out: [String] = ["the fleet snapshot"]
        if prReadyCount != nil { out.append("PR queue") }
        if dueTaskCount + dueFollowUpCount > 0 || singleDueTaskID != nil { out.append("tasks") }
        if forkDriftCount != nil || setupDriftCount != nil || toolUpdateCount != nil { out.append("drift") }
        if quotaWeeklyPercentUsed != nil { out.append("quota") }
        return out
    }
}

// MARK: - The local (always-present) layer

/// The non-AI half. Deterministic, offline, and the only thing allowed to
/// state a number - `MorningBriefingAI`'s prompt is given these same numbers
/// and told not to recompute them.
enum MorningBriefingLocal {

    /// The deterministic clause list. This *is* the degraded rendering (its
    /// joined form is the plain stat line), and it is also what the AI prompt
    /// is built from, so the two can never disagree about the facts.
    ///
    /// Clauses are ordered by how much they ask of the captain: things holding
    /// the crew first, then things that are merely behind.
    static func clauses(from inputs: BriefingInputs) -> [BriefingClause] {
        var out: [BriefingClause] = []

        // Setup not finished is the one state where every number below it is
        // zero for a reason that has nothing to do with the fleet, so it is
        // the whole briefing rather than one clause among five (GL-31's rule,
        // as Overview's own banner already applies it).
        if !inputs.homeOk {
            return [BriefingClause(
                text: "Setup isn't finished - point Grand Line at your firstmate home.",
                target: .setup)]
        }

        let needing = inputs.needsDecisionCount + inputs.blockedCount
        if needing > 0 {
            out.append(BriefingClause(
                text: "\(needing) fleet \(plural(needing, "task")) \(needing == 1 ? "needs" : "need") your call",
                target: .fleet))
        }

        if let ready = inputs.prReadyCount, ready > 0 {
            out.append(BriefingClause(
                text: "\(ready) \(plural(ready, "PR")) ready to merge",
                target: .review))
        } else if inputs.prReadyCount == nil {
            out.append(BriefingClause(text: "PR status unavailable", target: .review))
        }

        let due = inputs.dueTaskCount + inputs.dueFollowUpCount
        if due > 0 {
            out.append(BriefingClause(
                text: "\(due) \(plural(due, "task")) due or overdue",
                target: .tasks))
        }

        if let drift = inputs.forkDriftCount, drift > 0 {
            out.append(BriefingClause(
                text: "\(drift) \(plural(drift, "fork")) behind upstream",
                target: .githubSync))
        }

        if let updates = inputs.toolUpdateCount, updates > 0 {
            out.append(BriefingClause(
                text: "\(updates) \(plural(updates, "tool")) \(updates == 1 ? "has" : "have") an update",
                target: .updates))
        }

        if let setupDrift = inputs.setupDriftCount, setupDrift > 0 {
            out.append(BriefingClause(
                text: "\(setupDrift) setup \(plural(setupDrift, "item")) drifted",
                target: .setup))
        }

        if let weekly = inputs.quotaWeeklyPercentUsed {
            let pace = inputs.quotaWeeklyPace.map { ", \($0.lowercased())" } ?? ""
            out.append(BriefingClause(
                text: "\(percent(weekly)) of the weekly Claude quota used\(pace)",
                target: .quota))
        }

        if out.isEmpty {
            // Honest rather than padded: with every signal either clear or
            // genuinely unknown, there is one thing worth saying.
            out.append(BriefingClause(text: "Nothing needs you right now.", target: .none))
        }
        return out
    }

    /// What joins two deterministic clauses. A middot rather than a space,
    /// because these clauses are fragments ("2 PRs ready to merge") rather
    /// than sentences - run together with a space they read as one long
    /// garbled line. `MorningBriefingCard` renders the degraded briefing with
    /// this same constant, so the rendered card and `statLine` below cannot
    /// disagree about the shape of the line.
    static let statSeparator = " \u{00B7} "

    /// The plain stat line the degraded card renders, and the exact shape the
    /// review's own F12 example names ("2 PRs ready to merge \u{00B7} 1 task
    /// needs you \u{00B7} 2 forks drifted \u{00B7} 40% quota used"). Built from
    /// `clauses` rather than independently, so the line and the links can
    /// never drift apart.
    static func statLine(from inputs: BriefingInputs) -> String {
        line(from: clauses(from: inputs))
    }

    /// The same join, for a clause list already in hand - which is what the
    /// card has.
    static func line(from clauses: [BriefingClause]) -> String {
        clauses
            .map { $0.text.hasSuffix(".") ? String($0.text.dropLast()) : $0.text }
            .joined(separator: statSeparator)
    }

    // MARK: Small shared formatting

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }

    /// Whole percent - a briefing is a glance, and "40%" reads where "40.4%"
    /// does not.
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

// MARK: - The AI layer

struct MorningBriefingAIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// One `ClaudeOneShot` call over `BriefingInputs`. The sixth caller of the
/// consolidated runner (GL-26), as section 25's F12 entry specifies - not a
/// new subprocess path, and the prompt travels as an argv element, never
/// through a shell.
enum MorningBriefingAI {

    /// A briefing is a small ask over a handful of numbers, so this is far
    /// shorter than the log analyzer's 120s - and a timeout is never fatal:
    /// the caller falls back to the local clause list, which is always there.
    static let timeout: TimeInterval = 45

    /// Test-only seam, same convention as `LogAnalyzerAI.claudePathOverride
    /// ForTests`/`DictationCleanup.claudePathOverrideForTests`: points at a
    /// disposable fake `claude` script so the self-test can drive the real
    /// `ClaudeOneShot`/parse path with no network and no Claude auth.
    static var claudePathOverrideForTests: String?

    static func resolvedClaude() -> String? {
        claudePathOverrideForTests ?? ClaudeOneShot.resolve()
    }

    static var isAvailable: Bool { resolvedClaude() != nil }

    // MARK: Prompt

    /// The structured input, as text. Only counts and the fixed link
    /// vocabulary - there is nothing here the captain has not already seen on
    /// one of the five pages this replaces.
    static func prompt(inputs: BriefingInputs) -> String {
        var facts: [String] = []
        facts.append("- firstmate home configured: \(inputs.homeOk ? "yes" : "no")")
        facts.append("- fleet crew working: \(inputs.workingCount)")
        facts.append("- fleet tasks needing a decision: \(inputs.needsDecisionCount)")
        facts.append("- fleet tasks blocked: \(inputs.blockedCount)")
        facts.append("- fleet tasks finished today: \(inputs.doneTodayCount)")
        facts.append("- fleet tasks queued: \(inputs.queuedCount)")
        facts.append("- watcher status: \(inputs.watcherStatus)")
        if let ready = inputs.prReadyCount {
            facts.append("- pull requests ready to merge: \(ready)")
        } else {
            facts.append("- pull requests ready to merge: unknown (the scan could not reach the forge)")
        }
        facts.append("- personal tasks due or overdue: \(inputs.dueTaskCount)")
        facts.append("- personal follow-ups due or overdue: \(inputs.dueFollowUpCount)")
        facts.append("- forks behind upstream: \(describe(inputs.forkDriftCount))")
        facts.append("- tools with an update available: \(describe(inputs.toolUpdateCount))")
        facts.append("- machine setup items drifted: \(describe(inputs.setupDriftCount))")
        if let weekly = inputs.quotaWeeklyPercentUsed {
            let pace = inputs.quotaWeeklyPace ?? "unknown"
            facts.append("- weekly Claude quota used: \(MorningBriefingLocal.percent(weekly)) (pace: \(pace))")
        } else {
            facts.append("- weekly Claude quota used: unknown")
        }
        if let session = inputs.quotaSessionPercentUsed {
            facts.append("- current session Claude quota used: \(MorningBriefingLocal.percent(session))")
        }

        return """
        You are writing a one-paragraph morning briefing for an engineer sitting down at their \
        own operations cockpit. Reply with ONE JSON object and nothing else - no prose before or \
        after, no markdown code fence.

        Rules you must follow:
        - Use ONLY the facts listed below. They were computed locally and are exact. Do not \
        recompute, estimate, round differently, or add any number that is not listed.
        - Say nothing about a fact listed as "unknown" other than that it is unknown, and only \
        if it is worth mentioning at all.
        - Write 2 to 4 short clauses, most-urgent first. Each clause is one short sentence.
        - Skip anything that is zero or clear. A briefing that has little to report should be \
        short; do not pad it.
        - Be plain and factual. No greetings, no encouragement, no advice about what to do next.
        - Every clause carries a "link" naming which page it came from, chosen from exactly this \
        list: "review" (pull requests), "tasks" (personal tasks and follow-ups), "fleet" (fleet \
        crew tasks needing a decision or blocked), "githubSync" (forks behind upstream), \
        "updates" (tools with updates), "setup" (machine setup drift), "quota" (Claude quota), \
        "none" (anything else). Use "none" rather than guessing.

        Reply with exactly this JSON shape:
        {"clauses": [{"text": "one short sentence", "link": "review"}]}

        Facts:
        \(facts.joined(separator: "\n"))
        """
    }

    private static func describe(_ value: Int?) -> String {
        guard let value else { return "unknown (not checked yet this session)" }
        return "\(value)"
    }

    // MARK: Running

    /// Generates the AI clause list. `completion` runs on the main thread,
    /// exactly once. A failure is never fatal - the caller renders
    /// `MorningBriefingLocal.clauses` instead and says so.
    static func generate(inputs: BriefingInputs,
                         completion: @escaping (Result<[BriefingClause], MorningBriefingAIError>) -> Void) {
        guard let claude = resolvedClaude() else {
            completion(.failure(MorningBriefingAIError(message: "claude isn't installed or on PATH")))
            return
        }
        ClaudeOneShot.run(executable: claude,
                          prompt: prompt(inputs: inputs),
                          timeout: timeout,
                          label: "claude -p (morning briefing)") { result in
            switch result {
            case .failure(let error):
                completion(.failure(MorningBriefingAIError(message: error.message)))
            case .success(let reply):
                switch parse(reply.text) {
                case .success(let clauses): completion(.success(clauses))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    /// The most clauses a reply may contribute. A briefing is a glance; a
    /// model that returns fifteen sentences is not one, and rendering all of
    /// them would turn the card into a wall.
    static let maxClauses = 6
    /// Bound on one clause, so a runaway reply cannot produce a card taller
    /// than the page.
    static let maxClauseLength = 220

    /// Turns a reply into validated clauses. Kept `internal` so the self-test
    /// can drive it against hand-built payloads including the malformed ones a
    /// fake `claude` cannot easily produce.
    ///
    /// Validation is the second half of this file's security story: the link
    /// marker is matched against `BriefingTarget`'s own raw values and anything
    /// else becomes `.none`, so the model cannot name a destination that does
    /// not exist - and it never gets to choose a colour at all.
    static func parse(_ reply: String) -> Result<[BriefingClause], MorningBriefingAIError> {
        guard let object = decodeJSONObject(from: reply) else {
            return .failure(MorningBriefingAIError(message: "claude's reply was not valid JSON"))
        }
        guard let raw = object["clauses"] as? [Any] else {
            return .failure(MorningBriefingAIError(message: "claude's reply had no clauses"))
        }
        var out: [BriefingClause] = []
        for entry in raw {
            guard let dict = entry as? [String: Any],
                  let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let bounded = text.count <= maxClauseLength
                ? text
                : String(text.prefix(maxClauseLength)) + "\u{2026}"
            let target = BriefingTarget(rawValue: (dict["link"] as? String) ?? "") ?? BriefingTarget.none
            out.append(BriefingClause(text: bounded, target: target))
            if out.count == maxClauses { break }
        }
        guard !out.isEmpty else {
            return .failure(MorningBriefingAIError(message: "claude's reply had no usable clauses"))
        }
        return .success(out)
    }

    /// Tolerant of the two things a model does anyway despite being asked not
    /// to - wrapping the object in a ```json fence, and adding a sentence
    /// around it. Same shape as `LogAnalyzerAI.decodeJSONObject`, kept local
    /// rather than shared because that one is private to its own file and the
    /// two prompts' schemas are unrelated.
    static func decodeJSONObject(from reply: String) -> [String: Any]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let span = String(text[start...end])
        guard let data = span.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Orchestration

/// The pieces that actually reach outside this process, kept together so the
/// pure logic above stays testable without any of them.
enum MorningBriefing {

    /// `"yyyy-MM-dd"` in the local calendar - the "have I already briefed
    /// today" key. A fixed `en_US_POSIX` formatter, so the key is stable
    /// regardless of the machine's locale.
    static func dayKey(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The Shift half of the inputs. Reads only the store's already-loaded
    /// in-memory arrays, using the same `ShiftDateFormatting.dateTime` due
    /// reading `ShiftNotificationScheduler.poll()` uses - not a second
    /// definition of "due".
    ///
    /// Call on the main thread (`ShiftStore` is not thread-safe); it is a
    /// cheap in-memory scan, no I/O.
    static func shiftDue(store: ShiftStore, now: Date = Date())
        -> (tasks: Int, followUps: Int, singleTaskID: String?) {
        var dueTaskIDs: [String] = []
        for task in store.activeTasks {
            guard let due = ShiftDateFormatting.dateTime(from: task.dueDate, time: task.dueTime) else { continue }
            if due <= now { dueTaskIDs.append(task.id) }
        }
        var followUps = 0
        for followUp in store.followUps where followUp.status == .pending {
            guard let due = ShiftDateFormatting.dateTime(from: followUp.followUpAt, time: followUp.followUpTime) else { continue }
            if due <= now { followUps += 1 }
        }
        return (dueTaskIDs.count, followUps, dueTaskIDs.count == 1 ? dueTaskIDs[0] : nil)
    }

    /// The one input this file fetches itself - see the file header for why.
    /// Safe to call from a background queue only; `QuotaSource.fetch()` shells
    /// out to `quota-axi`.
    static func fetchQuota() -> (weekly: Double?, pace: String?, session: Double?) {
        switch QuotaSource.fetch() {
        case .failure(let reason):
            // Not an error worth surfacing on its own: the quota clause simply
            // does not appear, and the subtitle stops claiming quota as a
            // source. Logged so a captain wondering where it went can find out.
            AppLog.ai.info("morning briefing: no quota reading (\(reason, privacy: .public))")
            return (nil, nil, nil)
        case .success(let snapshot):
            return (snapshot.weekly?.percentUsed,
                    snapshot.weekly?.pace.label,
                    snapshot.session?.percentUsed)
        }
    }

    /// Assembles a record from a finished clause list. Pure - the caller
    /// decides whether `clauses` came from the AI or the local layer.
    static func record(inputs: BriefingInputs,
                       clauses: [BriefingClause],
                       isDegraded: Bool,
                       degradedReason: String?,
                       now: Date = Date()) -> MorningBriefingRecord {
        MorningBriefingRecord(
            day: dayKey(for: now),
            generatedAt: now,
            clauses: clauses,
            isDegraded: isDegraded,
            degradedReason: degradedReason,
            dismissed: false,
            sources: inputs.contributingSources,
            shiftTaskID: inputs.singleDueTaskID)
    }

    /// "Generated 6:58 AM from the fleet snapshot, PR queue, tasks, drift, and
    /// quota" - the mockup's own subtitle, built from what actually
    /// contributed rather than a fixed sentence that could claim an input the
    /// briefing did not have.
    static func subtitle(for record: MorningBriefingRecord) -> String {
        let time = timeFormatter.string(from: record.generatedAt)
        let sources = record.sources
        let list: String
        switch sources.count {
        case 0: return "Generated \(time)"
        case 1: list = sources[0]
        case 2: list = "\(sources[0]) and \(sources[1])"
        default: list = sources.dropLast().joined(separator: ", ") + ", and " + sources[sources.count - 1]
        }
        return "Generated \(time) from \(list)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()
}
