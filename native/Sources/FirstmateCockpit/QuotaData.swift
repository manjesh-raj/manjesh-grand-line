// Manjesh Grand Line - native macOS app.
//
// Data side of the "Claude usage" popover (`fm/grandline-herdr-utilization-
// panel`, following the captain-approved design plan built from
// `data/grandline-herdr-utilization-panel-research/report.md`) - originally
// reachable from a Console toolbar button gated to the herdr-attached
// "Mirror" tab, which `fm/grand-line-remove-firstmate-mirror` removed along
// with that tab; `FleetController`'s Morning Briefing card is the one
// remaining live entry point (`QuotaUsagePopover.swift`'s header has the
// full history). Follows this app's established "thin native window
// onto another CLI tool" pattern (see `VaultData.swift`'s own header): every
// read goes through the real `quota-axi` CLI via `Process`, never a
// reimplementation of its quota math, and every field is parsed tolerantly
// (skip, don't crash, on anything missing/malformed) exactly like
// `VaultSource.parseDoctorTools` already does.
//
// Scope, per the captain's explicit review: Claude only. No multi-provider
// picker - `quota-axi --json --provider claude` already narrows the
// `providers` array to the one entry this feature cares about.
//
// This file writes its own small `run`/`resolveExecutable`/`RunResult` trio
// rather than reusing `VaultData.swift`'s (private) copies or refactoring the
// five existing near-duplicates in this codebase - consolidating them was
// explicitly out of scope for this task, and every other integration in this
// app (Vault, Updates, Dotfiles, NotSynced, Fleet) already writes its own.

import Foundation

/// One usage window from `quota-axi`'s `windows[]` array - only the fields
/// this popover shows (the real JSON key is `percentRemaining`; `percentUsed`
/// here is `100 - percentRemaining`, converted once at the parse boundary -
/// see `QuotaSource.parse`'s comment - since the popover's own UI is written
/// in terms of "used", plus `resetsAt`, `pace.status`).
///
/// Three of `quota-axi`'s four windows have this shape: `five_hour`,
/// `seven_day` and `model:fable`. The fourth, `extra_usage`, is measured in
/// dollars rather than in a resetting allowance and has no `resetsAt` at
/// all - it is `QuotaCreditWindow` below. Any *other* id still falls through
/// `parse`'s `default: continue`.
struct QuotaWindow: Equatable {
    enum Kind: Equatable {
        case session
        case weekly
        /// `quota-axi`'s `model:fable` window - a per-model weekly allowance
        /// that runs alongside `seven_day` rather than inside it, so it can
        /// be exhausted while the plain weekly window still has room.
        case fable
    }

    enum PaceStatus: Equatable {
        case onPace
        case behind
        case ahead
        case unknown

        init(rawValue: String?) {
            switch rawValue {
            case "on_pace": self = .onPace
            case "behind": self = .behind
            case "ahead": self = .ahead
            default: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .onPace: return "On pace"
            case .behind: return "Behind"
            case .ahead: return "Ahead"
            case .unknown: return "Unknown"
            }
        }
    }

    let kind: Kind
    let percentUsed: Double
    let resetsAt: Date?
    let pace: PaceStatus
}

/// `quota-axi`'s `extra_usage` window - the extra-usage credit pool, which is
/// a different shape from the three resetting allowances above and so is a
/// sibling type rather than a `QuotaWindow` with unused fields.
///
/// **What it is not.** This is *not* organisation month-to-date spend as the
/// Anthropic Console's Usage & Cost page reports it. The window's own `kind`
/// is `credits`, and `quota-axi` returns `pace: {status: "unknown", reason:
/// "missing_cycle"}` for it - it does not know the billing cycle's
/// boundaries, so nothing here may honestly be called "month to date". The
/// Home card labels it **"Extra usage"** and **"Spend cap"** for exactly that
/// reason; see `docs/history/07-fleet-and-notifications.md`.
///
/// Both dollar figures are optional and independently so (GL-14): a plan or
/// account configuration that reports the window without them must render a
/// stated gap, never a `$0`.
struct QuotaCreditWindow: Equatable {
    /// **Optional, unlike every other window's.** The real output carries
    /// `extra_usage` with `pace.reason: "missing_usage"` and no
    /// `percentRemaining` at all - a shape the popover's own live fixture
    /// already contained, and which cost this parse a rewrite when the fixture
    /// was finally read rather than skipped. The dollars are the reading here;
    /// the percentage is a convenience the response may simply not have.
    let percentUsed: Double?
    let spentUsd: Double?
    let limitUsd: Double?
}

struct QuotaSnapshot {
    let plan: String?
    let session: QuotaWindow?
    let weekly: QuotaWindow?
    /// The `model:fable` window. `nil` when this account's response carries
    /// no per-model window - a stated gap on the card, never a zero.
    let fable: QuotaWindow?
    /// The `extra_usage` credit pool. `nil` for the same reason `fable` is.
    let extraUsage: QuotaCreditWindow?
    /// Wall-clock time the underlying `quota-axi` call took - shown in the
    /// popover's footer ("quota-axi · 1.4s"), matching this app's convention
    /// of surfacing the real data source/latency rather than hiding it.
    let latency: TimeInterval
    /// Raw command output for whatever failed, if anything - mirrors
    /// `VaultSnapshot.log`'s "show the real command output" principle.
    let log: String
}

/// How alarming a quota reading is.
///
/// **One copy of the 80/90 decision.** The thresholds were specified in the
/// Claude-usage popover's own review (`.good` below 80% used, `.warn` at
/// 80-90%, `.critical` above 90%) and lived only inside
/// `QuotaUsageWindowRow.tint(for:)`. The Home page's status strip needs the
/// same verdict in a different vocabulary (`HelmModuleRowState`, which is a
/// dot/track state rather than a `HelmTint`), and two surfaces reading the
/// same number must not be able to disagree about whether it is a warning -
/// so the decision moved here and both sides map from it.
enum QuotaSeverity: Equatable {
    case comfortable
    case warning
    case critical

    init(percentUsed: Double) {
        if percentUsed > 90 { self = .critical }
        else if percentUsed >= 80 { self = .warning }
        else { self = .comfortable }
    }

    var tint: HelmTint {
        switch self {
        case .comfortable: return .good
        case .warning: return .warn
        case .critical: return .critical
        }
    }

    var moduleRowState: HelmModuleRowState {
        switch self {
        case .comfortable: return .ok
        case .warning: return .warn
        case .critical: return .bad
        }
    }
}

enum QuotaFetchResult {
    case success(QuotaSnapshot)
    case failure(String)
}

enum QuotaSource {

    /// Bounds how long a fetch waits for `quota-axi` before giving up -
    /// confirmed live to normally return in ~1-2s; this is generous
    /// headroom for a real keychain prompt or a slow network hop, mirroring
    /// `VaultSource.appPasswordCheckTimeout`'s "never risk an indefinite
    /// hang" reasoning.
    private static let timeout: TimeInterval = 15

    /// Full fetch: resolves `quota-axi`, runs it with the Claude-only flag,
    /// and parses the confirmed-live JSON shape (report section 5) into a
    /// typed snapshot. Safe to call from a background queue; never touches
    /// the main thread.
    static func fetch() -> QuotaFetchResult {
        guard let exe = resolveExecutable("quota-axi") else {
            return .failure("quota-axi isn't on PATH.")
        }
        let start = Date()
        guard let result = runWithTimeout(exe, ["--json", "--provider", "claude", "--allow-keychain-prompt"], timeout: timeout) else {
            return .failure("quota-axi timed out.")
        }
        let latency = Date().timeIntervalSince(start)
        guard result.status == 0, !result.stdout.isEmpty else {
            // GL-14: this used to surface `quota-axi`'s raw stderr, which for
            // the most common failure by far - no network - is a stack of
            // transport detail that reads like a bug in the tool. Name the
            // recognisable cases; anything else still shows the real output,
            // because inventing a friendly message for an unknown failure would
            // hide the one thing worth reading.
            return .failure(friendlyFailure(result))
        }
        guard let snapshot = parse(result.stdout, latency: latency, log: result.combinedLog) else {
            return .failure("Couldn't parse quota-axi's output.")
        }
        return .success(snapshot)
    }

    /// Recognises the offline/auth shapes in `quota-axi`'s own output. Kept
    /// `internal` so `QuotaDataSelfTest` can pin the mapping.
    static func friendlyFailure(_ result: SubprocessResult) -> String {
        let log = result.combinedLog
        let lower = log.lowercased()
        let offlineMarkers = ["could not resolve host", "network is unreachable", "connection refused",
                              "temporary failure in name resolution", "offline", "no route to host",
                              "nodename nor servname", "operation timed out", "timed out"]
        if offlineMarkers.contains(where: { lower.contains($0) }) {
            return "Couldn't reach Anthropic - check your connection, then try again."
        }
        if lower.contains("unauthorized") || lower.contains("401") || lower.contains("not authenticated")
            || lower.contains("no credentials") {
            return "quota-axi isn't authenticated. Run it once in a terminal to sign in."
        }
        if log.isEmpty {
            return "quota-axi failed (exit \(result.status))."
        }
        return log
    }

    /// `resetsAt` comes back from `quota-axi` as e.g.
    /// `"2026-08-17T18:50:00.081363+00:00"` - fractional seconds plus a
    /// `+00:00` offset (not `Z`). A plain `ISO8601DateFormatter()` (default
    /// format options) fails to parse this and returns `nil` for every
    /// window, unconditionally - confirmed live before landing this fix:
    /// `ISO8601DateFormatter().date(from:)` on that exact string is `nil`,
    /// while adding `.withFractionalSeconds` to `formatOptions` parses it
    /// correctly. Tried with fractional seconds first, then without (in case
    /// a future `quota-axi` response omits them), rather than a single fixed
    /// formatter.
    private static func parseResetsAt(_ s: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: s) { return date }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Not `private` - exercisable directly for future tests, mirroring
    /// `VaultSource.parseDoctorTools`'s own visibility.
    static func parse(_ json: String, latency: TimeInterval, log: String) -> QuotaSnapshot? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = obj["providers"] as? [[String: Any]],
              let claude = providers.first(where: { ($0["provider"] as? String) == "claude" })
        else { return nil }

        let plan = claude["plan"] as? String
        let windows = (claude["windows"] as? [[String: Any]]) ?? []

        var session: QuotaWindow?
        var weekly: QuotaWindow?
        var fable: QuotaWindow?
        var extraUsage: QuotaCreditWindow?
        for entry in windows {
            // The real `quota-axi` output carries `percentRemaining`, not
            // `percentUsed` - confirmed live: a `windows[]` entry looks like
            // `{"id": "five_hour", "percentRemaining": 93, ...}`. There is
            // no `percentUsed` key at all in the real output; the popover's
            // own UI (bar fill width, the 80%/90% warning thresholds) is
            // written in terms of "used," so the conversion happens once,
            // right here at the parse boundary, rather than threading a
            // "remaining" semantic through code that assumes "used"
            // everywhere else.
            guard let id = entry["id"] as? String else { continue }

            // `extra_usage` is handled before the `percentRemaining` guard
            // below, because it is the one window that can legitimately
            // arrive without it (see `QuotaCreditWindow.percentUsed`) - and
            // requiring it here is what silently dropped this window on a
            // real payload.
            if id == "extra_usage" {
                // Every field read with `as? Double` and left `nil` when
                // absent rather than defaulted (GL-14) - the card states the
                // gap instead of rendering a fabricated `$0` or `0%`, both of
                // which are real and alarming values on a spend readout.
                let percentRemaining = entry["percentRemaining"] as? Double
                extraUsage = QuotaCreditWindow(
                    percentUsed: percentRemaining.map { 100 - $0 },
                    spentUsd: entry["spentUsd"] as? Double,
                    limitUsd: entry["limitUsd"] as? Double)
                continue
            }

            guard let percentRemaining = entry["percentRemaining"] as? Double
            else { continue }
            let percentUsed = 100 - percentRemaining
            let resetsAt = (entry["resetsAt"] as? String).flatMap { parseResetsAt($0) }
            let paceStatus = QuotaWindow.PaceStatus(rawValue: (entry["pace"] as? [String: Any])?["status"] as? String)
            switch id {
            case "five_hour":
                session = QuotaWindow(kind: .session, percentUsed: percentUsed, resetsAt: resetsAt, pace: paceStatus)
            case "seven_day":
                weekly = QuotaWindow(kind: .weekly, percentUsed: percentUsed, resetsAt: resetsAt, pace: paceStatus)
            case "model:fable":
                fable = QuotaWindow(kind: .fable, percentUsed: percentUsed, resetsAt: resetsAt, pace: paceStatus)
            default:
                continue
            }
        }

        // At least one of the two windows this popover cares about must be
        // present, or there's nothing worth showing.
        guard session != nil || weekly != nil else { return nil }
        return QuotaSnapshot(plan: plan, session: session, weekly: weekly,
                             fable: fable, extraUsage: extraUsage,
                             latency: latency, log: log)
    }

    // MARK: Process plumbing

    // GL-15: this file's own header used to explain why it carried a fresh copy
    // of `resolveExecutable`/`RunResult`/`runWithTimeout`; `Subprocess` is that
    // consolidation, and its bounded-wait behaviour *is* the shape this file
    // established.

    private static func resolveExecutable(_ name: String) -> String? {
        Subprocess.resolveExecutable(name)
    }

    private typealias RunResult = SubprocessResult

    /// `nil` on timeout, matching what the local copy returned so the caller's
    /// "couldn't read quota" branch is unchanged.
    private static func runWithTimeout(_ executable: String, _ args: [String], timeout: TimeInterval) -> RunResult? {
        let result = Subprocess.run(executable: executable, arguments: args,
                                    timeout: timeout, log: AppLog.network)
        return result.timedOut ? nil : result
    }
}
