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

    /// UX-02: what the Health hero card says, as values - its pill, its
    /// headline and second line, its ring, and the services that need a
    /// look, worst first. Pure, so CI's blocking lane asserts it.
    struct HealthHero: Equatable {
        struct Row: Equatable {
            let service: HealthService
            let detail: String
        }
        let chip: HelmModuleChip?
        let headline: String
        let body: String?
        let ring: HelmModuleCard.HeroRing?
        /// The services that need a look. Empty draws the one-line tile.
        let rows: [Row]
        /// Nothing has reported yet: the dimmed accent (GL-14).
        let isUnknown: Bool
    }

    static func healthHero(_ summary: ServiceHealthSummary) -> HealthHero {
        guard summary.total > 0 else {
            return HealthHero(chip: nil, headline: "Nothing has reported yet",
                              body: "Background services report here as they run.", ring: nil, rows: [],
                              isUnknown: true)
        }
        let failing = summary.entries.filter { $0.state.bucket == .failing }
        let degraded = summary.entries.filter { $0.state.bucket == .degraded }
        let attention = failing + degraded
        // "6 healthy, 1 not run yet": the figures the headline does not say.
        var parts = ["\(summary.healthy) healthy"]
        if summary.notRun > 0 { parts.append("\(summary.notRun) not run yet") }
        let state: HelmModuleRowState = !failing.isEmpty ? .bad : (!degraded.isEmpty ? .warn : .ok)
        let ring = HelmModuleCard.HeroRing(
            fraction: Double(summary.healthy) / Double(summary.total), label: "\(summary.healthy)/\(summary.total)",
            caption: nil, spoken: summary.spoken, state: state)
        guard !attention.isEmpty else {
            let headline = summary.healthy == summary.total
                ? (summary.total == 1 ? "The one service is healthy" : "All \(summary.total) services healthy")
                : "\(summary.healthy) of \(summary.total) services healthy"
            return HealthHero(chip: nil, headline: headline,
                              body: summary.notRun > 0 ? parts.dropFirst().joined(separator: ", ") : nil,
                              ring: ring, rows: [], isUnknown: false)
        }
        let headline = attention.count == 1 ? "1 service needs a look" : "\(attention.count) services need a look"
        let rows = attention.map { entry -> HealthHero.Row in
            let runs = entry.state.consecutiveFailures
            let detail = entry.state.bucket == .failing && runs > 1 ? "failed \(runs) runs in a row" : "failed its last run"
            return HealthHero.Row(service: entry.service, detail: detail)
        }
        let chip: HelmModuleChip = !failing.isEmpty ? .bad("\(failing.count) failing")
            : .warn(degraded.count == 1 ? "1 recent failure" : "\(degraded.count) recent failures")
        return HealthHero(chip: chip, headline: headline, body: parts.joined(separator: ", "), ring: ring,
                          rows: rows, isUnknown: false)
    }

    /// UX-02: Health is the row's third hero card, in the theme's accent, as
    /// Fleet and Claude are: the ring, the verdict, and each service that
    /// needs a look as a row with Retry (or Open, for one with no run of its
    /// own). With nothing to look at it is the verdict and the ring alone.
    func fillHealth(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        content.artwork = HealthIcon.image
        content.subtitle = "background services"
        let hero = Self.healthHero(healthSummary)
        content.chip = hero.chip
        content.hero = HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: hero.isUnknown)
        let layout = HelmModuleCard.HeroLayout(cardWidth: width)
        guard !hero.rows.isEmpty else {
            content.body = .heroSummary(HelmModuleCard.HeroSummary(
                headline: hero.headline, body: hero.body, ring: hero.ring, items: [], layout: layout))
            return
        }
        let rows = hero.rows.prefix(HelmModuleCard.maxPeekRows).map { row -> HelmModuleCard.HeroListRow in
            if let retry = healthRetryActions[row.service] {
                return HelmModuleCard.HeroListRow(symbol: row.service.symbol, title: row.service.title,
                                                  subtitle: row.detail, actionTitle: "Retry",
                                                  actionTooltip: "Run \(row.service.title) again", handler: retry)
            }
            return HelmModuleCard.HeroListRow(symbol: row.service.symbol, title: row.service.title,
                                              subtitle: row.detail, actionTitle: "Open",
                                              actionTooltip: "Open \(PlaceName.of(.health))") { [weak self] in
                self?.onOpenDestination?(.health)
            }
        }
        content.body = .heroList(HelmModuleCard.HeroList(
            headline: hero.headline, body: hero.body, ring: hero.ring, sectionTitle: "Needs a look",
            rows: Array(rows), emptyText: "", layout: layout))
    }
}
