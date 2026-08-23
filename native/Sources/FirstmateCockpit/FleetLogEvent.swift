// Manjesh Grand Line - native macOS app.
//
// F6 - Fleet history / captain's log (production-readiness review section 25).
// The record type behind Overview's "Log" tab.
//
// **What this is, and what it deliberately is not.** The Notification Center
// (`GrandLineNotificationCenter.swift`) answers "what needs you *right now*" -
// a live set of conditions that clear themselves the moment they stop being
// true. This is the opposite half: a durable, append-only record of things
// that already happened, which nothing ever clears. They share one discipline
// and no code - format at the edge (`FleetLogSources`, mirroring
// `NotificationSources`), detect nowhere new. Every event here is appended
// synchronously by the code path that already causes it (a merge completing,
// a conflict resolving, an investigation saving); there is no poller, and
// this file knows nothing about how any of those are detected.
//
// **Security (the spec's own constraint, not a preference).** An event carries
// an id and a title and nothing else. Never command output, never a terminal
// buffer, never a line of a captured log - Log Analyzer and SRE Lead already
// own that content behind `LogRedactor`'s boundary, and a second, unredacted
// copy of it sitting in a plain JSONL file on disk would quietly undo that.
// `FleetLogEvent.title` is built from record titles the app already renders on
// screen; `reference` is an id or a URL.

import Foundation

/// The kinds the captain-approved mockup's filter pills name (All / Merges /
/// Tasks / Sync / Investigations), plus Incidents. Deliberately closed: a new
/// kind means a new pill (the filter row is built from `allCases`) and a real,
/// already-existing signal to put behind it, not a free-text label a caller
/// invents at the call site. `.incident` earned one when F8 gave incidents a
/// real start/end event of their own - it is deliberately not folded into
/// `.investigation`, which is a Log Analyzer artifact rather than a declared
/// incident, and the two are filtered separately for exactly that reason.
enum FleetLogEventKind: String, Codable, CaseIterable {
    case merge
    case task
    case sync
    case investigation
    case incident

    /// The filter pill's label, and the plural used in the empty state.
    var pluralTitle: String {
        switch self {
        case .merge: return "Merges"
        case .task: return "Tasks"
        case .sync: return "Sync"
        case .investigation: return "Investigations"
        case .incident: return "Incidents"
        }
    }

    /// The mockup's per-kind row glyph. `checkmark.circle.fill` for a task and
    /// `arrow.triangle.pull` for a merge match what Overview's own task rows
    /// and Review's PR rows already use, so one concept is not drawn two ways
    /// a rail click apart.
    var symbol: String {
        switch self {
        case .merge: return "arrow.triangle.pull"
        case .task: return "checkmark.circle.fill"
        case .sync: return "arrow.triangle.2.circlepath"
        case .investigation: return "sparkles"
        case .incident: return "bolt.fill"
        }
    }

    /// The mockup's per-kind hue: merges green, tasks green, sync blue,
    /// investigations violet - resolved per theme through `HelmTint` rather
    /// than the mockup's literal hexes, which were picked against one palette.
    var tint: HelmTint {
        switch self {
        case .merge: return .good
        case .task: return .good
        case .sync: return .info
        case .investigation: return .violet
        // Red, matching the incident card's own header tile and the toolbar
        // action that starts one - the one event kind in this feed that is
        // about something going wrong rather than something completing.
        case .incident: return .critical
        }
    }
}

/// One thing that happened. `Codable` because the store's on-disk form is one
/// JSON object per line (the spec's own "append-only local JSONL event log").
///
/// `id` exists so a re-read of the file can dedupe against itself; `reference`
/// is the optional "jump to it" handle (a task id, a PR url, an investigation
/// id) - carried now, acted on by nothing yet, so a later affordance does not
/// need a data migration to find its target.
struct FleetLogEvent: Codable, Equatable, Identifiable {
    let id: String
    let date: Date
    let kind: FleetLogEventKind
    /// One line, already phrased for display. Never multi-line, never output.
    let title: String
    let reference: String?

    init(id: String = UUID().uuidString, date: Date = Date(), kind: FleetLogEventKind,
         title: String, reference: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = FleetLogEvent.sanitize(title)
        self.reference = reference
    }

    /// The security constraint, enforced rather than trusted. A caller is
    /// supposed to pass a one-line title built from ids and record titles;
    /// this makes an accidental multi-line paste (the shape a stray log
    /// excerpt would take) structurally impossible to store, and bounds the
    /// length so a pathologically long record title cannot bloat the file.
    static let maxTitleLength = 240

    static func sanitize(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > maxTitleLength else { return oneLine }
        return String(oneLine.prefix(maxTitleLength - 1)) + "\u{2026}"
    }
}

/// Where each event's one-line text is phrased - the direct counterpart of
/// `NotificationSources`, and for the same reason: the call sites that append
/// events are spread across `ReviewController`, `ShiftGitSync` and
/// `LogAnalyzerStore`, and none of them should be inventing wording of its
/// own. No detection logic lives here; every function takes a value its
/// caller already had in hand.
enum FleetLogSources {

    /// A merge that actually succeeded (`FleetDataSource.mergePR` returned
    /// `ok`) - never an attempted or failed one, which is a transient error
    /// the captain already saw in an alert, not history.
    static func merged(prNumber: Int?, prTitle: String, repo: String, url: String) -> FleetLogEvent {
        let number = prNumber.map { "PR #\($0)" } ?? "PR"
        let named = prTitle.isEmpty ? number : "\(number) \u{201C}\(prTitle)\u{201D}"
        let where_ = repo.isEmpty ? "" : " in \(repo)"
        return FleetLogEvent(kind: .merge, title: "Merged \(named)\(where_)", reference: url)
    }

    /// One resolved Shift sync conflict. `keptLocal` is the captain's own
    /// choice, so the event says which side won - that is the whole point of
    /// recording it (the mockup's "kept local edit to task-129").
    static func syncConflictResolved(recordKind: String, recordTitle: String,
                                     recordID: String, keptLocal: Bool) -> FleetLogEvent {
        let side = keptLocal ? "kept this machine's edit" : "kept GitHub's edit"
        return FleetLogEvent(kind: .sync,
                             title: "Shift sync conflict resolved \u{2014} \(side) to \(recordKind) \u{201C}\(recordTitle)\u{201D}",
                             reference: recordID)
    }

    /// An investigation that was genuinely written to disk. A `.doNotSave`
    /// investigation is not saved and gets no event.
    static func investigationSaved(title: String, id: String) -> FleetLogEvent {
        FleetLogEvent(kind: .investigation, title: "Saved investigation \u{201C}\(title)\u{201D}", reference: id)
    }

    /// F8: an incident the captain declared on a host page, appended once the
    /// record genuinely reached disk.
    static func incidentStarted(id: String, title: String, hostLabel: String) -> FleetLogEvent {
        FleetLogEvent(kind: .incident,
                      title: "Started incident \(id) \u{2014} \u{201C}\(title)\u{201D} on \(hostLabel)",
                      reference: id)
    }

    /// F8: the same incident ended. Carries how long it ran, which is the one
    /// thing about an incident that only the log can say at a glance.
    static func incidentEnded(id: String, title: String, hostLabel: String,
                              startedAt: Date, endedAt: Date) -> FleetLogEvent {
        let duration = Incident.elapsedText(from: startedAt, to: endedAt)
            .replacingOccurrences(of: " ago", with: "")
        return FleetLogEvent(kind: .incident,
                             title: "Ended incident \(id) \u{2014} \u{201C}\(title)\u{201D} on \(hostLabel) after \(duration)",
                             reference: id)
    }
}
