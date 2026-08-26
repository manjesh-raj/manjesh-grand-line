// Manjesh Grand Line - native macOS app.
//
// F8 - Incident mode (production-readiness review section 25). The record
// type behind the "Start Incident" action on a host page.
//
// **The problem this exists to solve.** During a real incident the captain
// uses SRE Lead (investigate), Log Analyzer (evidence), Runbooks (remediate)
// and the terminal - four surfaces with no shared record, so afterwards the
// only account of what happened is whatever anyone remembers. An `Incident`
// is that shared record: metadata plus an append-only timeline of things that
// genuinely happened, each pointing at an artifact one of those four features
// already stored.
//
// **What this file deliberately does NOT contain: any detection, any
// execution.** Every timeline entry is appended by the code path that already
// causes the thing it describes - SRE Lead's own reply completion, the
// terminal capture handed to the Log Analyzer, the MCP bridge's runbook run.
// This is the same discipline `FleetLogSources`/`NotificationSources` already
// follow: format at the edge, detect nowhere new. `IncidentSources` below is
// the phrasing layer; nothing in it decides whether an event happened.
//
// **Security (the review's own constraint, not a preference).** An incident
// record carries ids, record titles, counts and one-line descriptions - never
// command output, never a terminal buffer, never a line of a captured log.
// The evidence itself stays where its own feature already put it, behind that
// feature's redaction boundary: a Log Analyzer investigation is referenced by
// id, and the one piece of text this feature does write to disk (an SRE Lead
// transcript snapshot) goes through `LogRedactor` first and lands in a
// sibling artifact file, never inside `incident.yaml`. `IncidentTimelineEntry`
// enforces the one-line rule structurally, the same way `FleetLogEvent` does,
// so an accidental multi-line paste is unstorable rather than merely
// discouraged.

import Foundation

/// Where an incident is in its life. Deliberately two states and not three:
/// "resolved but postmortem pending" is not a distinct thing the captain has
/// to manage - ending an incident generates the postmortem, and a generation
/// failure leaves the incident ended with no RCA rather than in limbo.
enum IncidentStatus: String, Codable, CaseIterable {
    case active
    case ended

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .ended: return "Ended"
        }
    }
}

/// What kind of thing attached itself to the incident.
///
/// Closed on purpose, and each case corresponds to a real, already-existing
/// event in this app - adding a fifth means finding a fifth such event, not
/// inventing a free-text label at a call site.
enum IncidentEntryKind: String, Codable, CaseIterable {
    /// An SRE Lead turn completed on a tab of this host (`ConsoleController.handleSRELeadSubmit`).
    case sreLead
    /// Terminal output was captured into the Log Analyzer, or the resulting
    /// investigation was saved (`onAnalyzeLogs` / `LogAnalyzerStore.save`).
    case logCapture
    /// A runbook ran through SRE Lead's MCP bridge (`sre_kubectl_mcp.py`'s
    /// `run_runbook`).
    case runbook
    /// The captain typed something into the incident card themselves.
    case note

    /// The mockup's per-kind row glyph. Chosen to match what each source
    /// feature already uses for itself, so one concept is not drawn two ways
    /// a click apart: `sparkles` is SRE Lead's own glyph everywhere in this
    /// app, and `text.magnifyingglass` is the Analyze Logs toolbar button's.
    var symbol: String {
        switch self {
        case .sreLead: return "sparkles"
        case .logCapture: return "text.magnifyingglass"
        case .runbook: return "doc.text"
        case .note: return "text.bubble"
        }
    }

    /// The mockup's per-kind hue - violet for SRE Lead, blue for a capture,
    /// green for a runbook run - resolved per theme through `HelmTint` rather
    /// than the mockup's literal hexes, which were picked against one palette.
    var tint: HelmTint {
        switch self {
        case .sreLead: return .violet
        case .logCapture: return .info
        case .runbook: return .good
        case .note: return .neutral
        }
    }

    /// The uppercase kicker on the row.
    var kicker: String {
        switch self {
        case .sreLead: return "SRE Lead"
        case .logCapture: return "Evidence"
        case .runbook: return "Runbook"
        case .note: return "Note"
        }
    }
}

/// One thing that happened during the incident, in the order it happened.
///
/// `reference` is the handle back into whichever feature owns the real
/// artifact (a Log Analyzer investigation id today); `artifact` is the
/// relative path of a file this feature itself wrote under the incident's own
/// directory (an SRE Lead transcript snapshot). Both optional: a runbook run
/// and a note have neither.
struct IncidentTimelineEntry: Equatable, Identifiable {
    let id: String
    let at: Date
    let kind: IncidentEntryKind
    /// One line, already phrased for display.
    let title: String
    /// A second, quieter line - the mockup's "6 turns · attached
    /// automatically". Also one line.
    let detail: String?
    let reference: String?
    let artifact: String?

    init(id: String = UUID().uuidString,
         at: Date = Date(),
         kind: IncidentEntryKind,
         title: String,
         detail: String? = nil,
         reference: String? = nil,
         artifact: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = IncidentTimelineEntry.sanitize(title)
        self.detail = detail.map(IncidentTimelineEntry.sanitize)
        self.reference = reference
        self.artifact = artifact
    }

    /// The security constraint, enforced rather than trusted - the same
    /// mechanism and the same reasoning as `FleetLogEvent.sanitize`. A caller
    /// is meant to pass a one-line summary built from ids and record titles;
    /// this makes an accidental multi-line paste (the shape a stray log
    /// excerpt takes) structurally impossible to store in the record, and
    /// bounds the length so one pathological title cannot bloat the file.
    static let maxTextLength = 240

    static func sanitize(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > maxTextLength else { return oneLine }
        return String(oneLine.prefix(maxTextLength - 1)) + "\u{2026}"
    }

    /// `HH:mm`, the mockup's own row kicker on the left of each timeline row.
    var clockText: String { IncidentTimelineEntry.clockFormatter.string(from: at) }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// One incident: the shared object every artifact attaches to.
struct Incident: Equatable, Identifiable {
    /// Human-facing and stable: `INC-014`. Assigned by `IncidentStore` from
    /// the highest number already on disk, so it reads like an incident
    /// number rather than a UUID the captain has to copy around.
    let id: String
    var title: String
    /// The saved `Host.id` this incident belongs to, as a string. The
    /// one-active-incident rule is keyed on this, not on the label, so
    /// renaming a host mid-incident cannot orphan its own incident.
    let hostID: String
    /// The host's label at the moment the incident started - display only.
    var hostLabel: String
    let startedAt: Date
    var endedAt: Date?
    var status: IncidentStatus
    var entries: [IncidentTimelineEntry]
    /// The generated postmortem markdown, present only once the incident has
    /// been ended *and* generation succeeded. Stored in its own `rca.md`
    /// file, never inline in `incident.yaml`.
    var rcaMarkdown: String?

    var isActive: Bool { status == .active }

    /// The mockup's "Active · started 32m ago on EKS Preprod Bastion".
    func subtitle(now: Date = Date()) -> String {
        let state = status == .active ? "Active" : "Ended"
        return "\(state) · started \(Incident.elapsedText(from: startedAt, to: now)) on \(hostLabel)"
    }

    /// "32m ago" / "2h 14m ago" / "just now" - deliberately coarse, because
    /// the exact second is on every timeline row already.
    static func elapsedText(from: Date, to: Date = Date()) -> String {
        let seconds = max(0, Int(to.timeIntervalSince(from)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 { return remainder == 0 ? "\(hours)h ago" : "\(hours)h \(remainder)m ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// Every entry that belongs on the Evidence tab: the captures and the
    /// saved investigations behind them. A runbook run and an SRE Lead turn
    /// are timeline events, not evidence a captain would open.
    var evidenceEntries: [IncidentTimelineEntry] {
        entries.filter { $0.kind == .logCapture }
    }
}

/// Where each timeline entry's wording is decided - the direct counterpart of
/// `FleetLogSources`, and for the same reason: the call sites that attach
/// entries are spread across `ConsoleController`, `AppShellController` and
/// the SRE Lead bridge, and none of them should be inventing its own phrasing.
/// No detection logic lives here; every function takes values its caller
/// already had in hand.
enum IncidentSources {

    /// One completed SRE Lead turn on a tab of this host. `turn` is 1-based;
    /// the first one reads as the investigation starting, which is the
    /// mockup's own wording.
    static func sreLeadTurn(question: String, tabName: String, turn: Int) -> IncidentTimelineEntry {
        let title = turn <= 1 ? "SRE Lead investigation started" : "SRE Lead follow-up"
        let quoted = question.isEmpty ? tabName : "\u{201C}\(question)\u{201D}"
        return IncidentTimelineEntry(kind: .sreLead,
                                     title: title,
                                     detail: "\(quoted) · turn \(turn) on \(tabName) · transcript attached")
    }

    /// Terminal output handed to the Log Analyzer. Carries the *shape* of the
    /// capture (how many lines, and the scope sentence the capture builder
    /// already wrote for the captain) - never the captured text itself.
    static func logCapture(tabName: String, lineCount: Int, scopeDescription: String) -> IncidentTimelineEntry {
        IncidentTimelineEntry(kind: .logCapture,
                              title: "Log Analyzer capture \u{2014} \(tabName)",
                              detail: "\(lineCount) line\(lineCount == 1 ? "" : "s") · \(scopeDescription)")
    }

    /// A Log Analyzer investigation that was genuinely written to disk while
    /// this incident was active - the one evidence entry that can be reopened
    /// later, which is why it is the only one carrying a `reference`.
    static func investigationSaved(title: String, id: String) -> IncidentTimelineEntry {
        IncidentTimelineEntry(kind: .logCapture,
                              title: "Saved investigation \u{201C}\(title)\u{201D}",
                              detail: "Attached as evidence · open in Log Analyzer",
                              reference: id)
    }

    /// A runbook run through SRE Lead's MCP bridge. `ran`/`total` differ when
    /// the run stopped at a failing step; `refused` is the validation refusal
    /// (`run_runbook` never runs a partial runbook - see that tool's own
    /// "refuses the whole runbook by name" behaviour).
    static func runbookRun(name: String, ran: Int, total: Int, ok: Bool, refused: Bool) -> IncidentTimelineEntry {
        let detail: String
        if refused {
            detail = "Refused before running \u{2014} a step is not an allowed read-only command"
        } else if ok {
            detail = "\(total) step\(total == 1 ? "" : "s") · all green"
        } else {
            detail = "\(ran) of \(total) step\(total == 1 ? "" : "s") ran · stopped on a failure"
        }
        return IncidentTimelineEntry(kind: .runbook, title: "Ran runbook: \u{201C}\(name)\u{201D}", detail: detail)
    }

    /// The captain's own note, typed into the incident card.
    static func note(_ text: String) -> IncidentTimelineEntry {
        IncidentTimelineEntry(kind: .note, title: text, detail: nil)
    }
}
