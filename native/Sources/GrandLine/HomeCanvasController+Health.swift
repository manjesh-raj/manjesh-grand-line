// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the Health card and its ring summary.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    /// What the Health card's ring and its sentence both say.
    struct HealthRingSummary: Equatable {
        let value: Int
        let total: Int
        let title: String
        let note: String
        /// S11: the headline's colour, which the arc and the title both take.
        /// `nil` while the headline is healthy or not a verdict yet, so the
        /// ring keeps the card's own hue and the title stays in ink.
        var tint: HelmTint? = nil
    }

    /// **Review defect U5**, then R5-BUG-02, then S11. U5: the ring counted
    /// one set and its sentence another ("2/6" beside "All reporting
    /// services healthy"). Its fix counted *reporting* services over total
    /// while any had not reported ("Reporting 7 of 8"), which is a third
    /// number for the same registry. So the ring is healthy over total,
    /// always, from the same `ServiceHealthSummary` the Health page and the
    /// footer read.
    ///
    /// S11 of the 2026-11-17 UI/UX proposals: the card still said three
    /// things about one fact - a red "1 failing" pill, a green ring and the
    /// title "Healthy". The title is now the summary's headline (its worst
    /// verdict, `ServiceHealthSummary.headline`), in that state's colour, and
    /// the ring takes the same tint. The pill is gone: the title carries the
    /// state, once. GL-14 still holds: a service that has never finished a
    /// pass is "not run yet", never healthy.
    static func healthRingSummary(_ summary: ServiceHealthSummary) -> HealthRingSummary {
        guard summary.total > 0, let headline = summary.headline else {
            // B9: shorter copy as well as a third line - the note column
            // beside a 66pt gauge is genuinely narrow, and a summary that
            // needs three lines to say "fine" is not a summary.
            // UI-11 / GL-14: nothing reported is not healthy. The ring draws
            // its grey track and a dash, and the title says what is true.
            return HealthRingSummary(value: 0, total: 0, title: HelmReading<String>.unknownCaption,
                                     note: "Nothing has reported yet.")
        }
        let total = summary.total
        let names = { (bucket: ServiceHealthSummary.Bucket) in
            summary.services(in: bucket).map(\.title).joined(separator: ", ")
        }
        // The figures the headline does not already say, for a sentence that
        // follows a named failure: "6 of 8 healthy, 1 not run yet".
        let rest = { (lead: ServiceHealthSummary.Bucket) -> String in
            var parts = ["\(summary.healthy) of \(total) \(ServiceHealthSummary.Bucket.healthy.phrase)"]
            for bucket in [ServiceHealthSummary.Bucket.failing, .degraded, .notRun] where bucket != lead {
                let n = summary.count(bucket)
                if n > 0 { parts.append(bucket.word.counted(n)) }
            }
            return parts.joined(separator: ", ")
        }
        let title: String
        let note: String
        switch headline {
        case .failing:
            title = ServiceHealthSummary.Bucket.failing.word.counted(summary.failing)
            note = "\(names(.failing)) needs a look. \(rest(.failing))."
        case .degraded:
            title = ServiceHealthSummary.Bucket.degraded.word.counted(summary.degraded)
            note = "\(names(.degraded)) had a recent failure. \(rest(.degraded))."
        case .healthy:
            title = ServiceHealthSummary.Bucket.healthy.label
            if summary.notRun > 0 {
                note = "\(summary.notRun) of \(total) \(ServiceHealthSummary.Bucket.notRun.phrase)."
            } else {
                // "All 1 services healthy." is what a bare count reads as on
                // a machine where only one service has registered - measured
                // in the probe.
                note = total == 1 ? "The only service is healthy." : "All \(total) services healthy."
            }
        case .notRun:
            title = ServiceHealthSummary.Bucket.notRun.label
            note = "\(summary.notRun) of \(total) \(ServiceHealthSummary.Bucket.notRun.phrase)."
        }
        // Healthy keeps the card's own green hue rather than the good tint,
        // so an all-clear card looks exactly as it did.
        let tint = headline == .healthy ? nil : headline.word.tint
        return HealthRingSummary(value: summary.healthy, total: total, title: title, note: note, tint: tint)
    }

    func fillHealth(_ content: inout HelmModuleCard.Content) {
        // `fm/grandline-rail-icons-batch2`: the captain's own health
        // artwork, replacing the plain `waveform.path.ecg` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.health` case.
        content.artwork = HealthIcon.image
        let health = healthSummary
        content.subtitle = "background services"
        // S11: no "1 failing" pill. The ring's title says it, once.
        let summary = Self.healthRingSummary(health)
        content.body = .ring(value: summary.value, total: summary.total,
                             title: summary.title, note: summary.note, spoken: health.spoken, tint: summary.tint)
    }
}
