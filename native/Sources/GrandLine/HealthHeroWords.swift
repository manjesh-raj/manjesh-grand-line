// Grand Line - native macOS app.
//
// What Health's hero column says (H-4 on the page-redesign board): the
// verdict, the ring, the four buckets and which pills sit at its foot, all
// from one `ServiceHealthSummary` - the same snapshot the table beside it
// renders, so the two cannot disagree (R5-BUG-02).
//
// A pure value, so the words are asserted headless
// (`PageHeroColumnsSelfTest`), and `HealthCardView` only paints them.
//
// The rules, which keep the Home hero cards' colour and state rules:
//
//   - **The column is the theme's accent, and red while something fails.**
//     A service with a recent failure (one or two in a row) keeps the accent
//     and the ring's arc turns amber; a failing one (`failureThreshold` in a
//     row) turns the column red. The red goes through the same palette rule
//     as any hero colour.
//   - **Unknown is never zero (GL-14).** Before anything has reported there
//     is no ring and no bucket figure, and the column is dimmed the way a
//     stale Home card is.
//   - The words are the page's own: the bucket names are `StateWord`'s, and
//     a failing service is named by its title.

import Foundation

struct HealthHeroWords: Equatable {

    enum Tone: Equatable {
        /// The theme's accent.
        case accent
        /// Something is failing: the theme's red.
        case failing
        /// Nothing has reported: the accent, dimmed (GL-14).
        case unknown
    }

    struct BucketRow: Equatable {
        let bucket: ServiceHealthSummary.Bucket
        /// `nil` before anything has reported.
        let count: Int?
        /// Which services are in it, or "None". Empty before anything has
        /// reported: the headline says so once.
        let detail: String
    }

    let headline: String
    let body: String
    /// Healthy over total, or `nil` before anything has reported.
    let ring: (healthy: Int, total: Int)?
    let ringCaption: String
    let ringState: HelmModuleRowState
    let tone: Tone
    let buckets: [BucketRow]
    /// The services that need attention and can be run again, worst first.
    let retryable: [HealthService]
    /// Whether the foot offers Copy diagnostics: while something needs
    /// attention, next to it.
    let offersDiagnostics: Bool

    static func == (a: HealthHeroWords, b: HealthHeroWords) -> Bool {
        a.headline == b.headline && a.body == b.body && a.ring?.healthy == b.ring?.healthy
            && a.ring?.total == b.ring?.total && a.ringCaption == b.ringCaption && a.ringState == b.ringState
            && a.tone == b.tone && a.buckets == b.buckets && a.retryable == b.retryable
            && a.offersDiagnostics == b.offersDiagnostics
    }

    /// The order the buckets stack in, the board's.
    static let bucketOrder: [ServiceHealthSummary.Bucket] = [.healthy, .degraded, .failing, .notRun]

    static func make(_ summary: ServiceHealthSummary, canRetry: (HealthService) -> Bool,
                     relative: (Date) -> String) -> HealthHeroWords {
        let known = summary.total > 0
        let buckets = bucketOrder.map { bucket in
            BucketRow(bucket: bucket, count: known ? summary.count(bucket) : nil,
                      detail: known ? names(summary.services(in: bucket)) : "")
        }
        guard known else {
            return HealthHeroWords(
                headline: "No background service has reported yet.",
                body: "Services report here as they run. A schedule is the usual way one runs without you.",
                ring: nil, ringCaption: "", ringState: .idle, tone: .unknown, buckets: buckets,
                retryable: [], offersDiagnostics: false)
        }

        let failing = summary.entries.filter { $0.state.bucket == .failing }
        let degraded = summary.entries.filter { $0.state.bucket == .degraded }
        let attention = failing + degraded
        let retryable = attention.map(\.service).filter(canRetry)
        let latestReport = summary.entries.compactMap { [$0.state.lastSuccess, $0.state.lastFailure].compactMap { $0 }.max() }.max()
        var caption = "services healthy"
        if let latestReport { caption += "\nlast report \(relative(latestReport))" }

        let headline: String
        var body: String
        let tone: Tone
        let ringState: HelmModuleRowState
        if !failing.isEmpty {
            tone = .failing
            // On a red column the arc stays in the ink: the column already
            // says it, and a red arc on red would not read.
            ringState = .ok
            if failing.count == 1, let entry = failing.first {
                headline = "\(entry.service.title) has failed \(entry.state.consecutiveFailures) runs in a row."
            } else {
                headline = "\(failing.count) services are failing."
            }
            body = lastError(failing, relative: relative)
        } else if !degraded.isEmpty {
            tone = .accent
            ringState = .warn
            if degraded.count == 1, let entry = degraded.first {
                headline = "\(entry.service.title) failed its last run."
            } else {
                headline = "\(degraded.count) services failed their last run."
            }
            body = lastError(degraded, relative: relative)
        } else if summary.healthy == summary.total {
            tone = .accent
            ringState = .ok
            headline = summary.total == 1 ? "The one background service is healthy."
                : "All \(summary.total) background services are healthy."
            body = "Every service's last run succeeded."
        } else {
            tone = .accent
            ringState = .ok
            headline = "\(summary.healthy) of \(summary.total) services are healthy."
            let waiting = summary.services(in: .notRun)
            body = "\(names(waiting)) \(waiting.count == 1 ? "has" : "have") not run yet."
        }
        if !body.isEmpty, !attention.isEmpty, retryable.isEmpty {
            body += " Copy diagnostics has the details."
        }
        return HealthHeroWords(headline: headline, body: body, ring: (summary.healthy, summary.total),
                               ringCaption: caption, ringState: ringState, tone: tone, buckets: buckets,
                               retryable: retryable, offersDiagnostics: !attention.isEmpty)
    }

    /// The newest failure among `entries`, as one sentence.
    private static func lastError(_ entries: [ServiceHealthSummary.Entry], relative: (Date) -> String) -> String {
        let newest = entries.filter { $0.state.lastFailure != nil }
            .max { ($0.state.lastFailure ?? .distantPast) < ($1.state.lastFailure ?? .distantPast) }
        guard let newest, let when = newest.state.lastFailure else { return "" }
        let reason = FailureExplainer.sentence(newest.state.lastFailureDetail ?? "")
        let who = entries.count > 1 ? "\(newest.service.title), " : ""
        return "Last error \(who)\(relative(when)): \(reason)"
    }

    /// "Tasks git sync", "Tasks git sync and Docs & runbooks sync",
    /// "Tasks git sync, Due-item reminders and 3 more", or "None".
    static func names(_ services: [HealthService]) -> String {
        let titles = services.map(\.title)
        switch titles.count {
        case 0: return "None"
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        default: return "\(titles[0]), \(titles[1]) and \(titles.count - 2) more"
        }
    }
}
