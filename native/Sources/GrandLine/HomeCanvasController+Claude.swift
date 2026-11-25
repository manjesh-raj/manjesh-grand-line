// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the Claude usage card: the usage report and the split hero.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    // MARK: The Claude usage report

    /// The captain's picked usage report: a header carrying the plan, one
    /// overall verdict and the reading's age, then a "Plan limits" section
    /// with one full-width bar per window, then an "Extra usage" section
    /// showing the spend against its cap.
    ///
    /// It replaced a five-column "Status strip"
    /// (`docs/history/07-fleet-and-notifications.md` has that shape's own
    /// history). The card is taller than the strip was, deliberately and on
    /// the captain's own instruction - `HelmModuleCard.minimumHeight` is a
    /// floor rather than a fixed height, so it simply grows.
    ///
    /// **The two labelling decisions this card is built on**, both carried
    /// forward from the design exploration the captain picked a mockup from
    /// (`docs/history/07-fleet-and-notifications.md` records the reasoning):
    ///
    ///  - The five-hour window is **"Session (5h)"**, never "Daily". Claude's
    ///    quota has no daily window and `quota-axi` reports none - the window
    ///    is `five_hour`, which the tool itself labels `session`. Naming it
    ///    "Daily" would be a claim about a reset cadence that does not exist.
    ///  - The credit pool is **"Extra usage"** against a **"Spend cap"**,
    ///    never "MTD spend". Its window id is `extra_usage` and its kind is
    ///    `credits`; `quota-axi` returns `pace: {status: "unknown", reason:
    ///    "missing_cycle"}` for it, so it does not know the billing cycle's
    ///    boundaries and nothing derived from it may honestly say "month to
    ///    date". True organisation month-to-date spend would need Anthropic's
    ///    Admin/Usage API and an Admin key, which this app does not have.
    ///
    /// GL-14 runs through the whole card: every window is independently
    /// optional, and one this account's response does not carry renders
    /// "Not reported" in the muted face with no bar at all - never a `0%` or
    /// a `$0`, which on a quota readout are real and alarming values rather
    /// than synonyms for "unknown".
    func fillClaudeStatus(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        // On every state, including no reading and a failed one: the one
        // moment a captain most wants to re-take a reading is when the card
        // is stating a gap.
        content.headerAction = HelmModuleCard.HeaderAction(
            symbol: "arrow.clockwise",
            tooltip: isRefreshingQuota
                ? "Reading the Claude quota\u{2026}"
                : "Refresh the Claude quota",
            isBusy: isRefreshingQuota,
            handler: { [weak self] in self?.refreshQuotaTapped() })

        // The captain's split hero.
        fillClaudeHero(&content, width: width)
    }

    /// Below this card width the dense grid's four columns do not fit the
    /// long names and the "Resets" word: "Session (5h)", a figure, a 40pt bar
    /// and "Resets Mon 12:32 PM" need about 280pt of a 293pt column's 261pt
    /// of content. Measured with the tour lab's `probe` verb.
    static let claudeShortLabelWidth: CGFloat = 400

    static func claudeUsesShortLabels(forCardWidth width: CGFloat) -> Bool {
        width < claudeShortLabelWidth
    }

    /// Whether this card is narrow enough to need the report's stacked
    /// reflow rather than its aligned four-column grid.
    ///
    /// The same threshold `claudeStripColumnsPerRow` used, and for the same
    /// reason: `HelmResponsiveGrid.packRows` degrades a span-2 card to one
    /// column in a single-column grid, and at that width the grid's three
    /// content columns leave the bar a stub. This is the direct analogue of
    /// the mockup's own `@media (max-width: 560px)` rule, which reflows the
    /// same four fields the same way - title and figure on one line, the bar
    /// full width beneath, the reset caption under that.
    ///
    /// The card pays height, never a reading. Nothing is dropped in either
    /// layout, which is the property the strip already had when it wrapped.
    static func claudeUsageIsCompact(forCardWidth width: CGFloat) -> Bool {
        isNarrowerThanTwoColumns(width)
    }

    /// The report's two sections, in the mockup's order. `static` so a suite
    /// can assert the mapping from a fabricated snapshot without mounting a
    /// canvas.
    ///
    /// GL-14 runs through the whole function exactly as it ran through
    /// `claudeStripColumns` before it: every window is independently
    /// optional, and one this account's response does not carry renders
    /// "Not reported" in the muted caption face with no bar at all - never a
    /// `0%` or a `$0`, which on a quota readout are real and alarming values
    /// rather than synonyms for "unknown".
    /// - Parameter headerCarriesVerdict: UI-8 - when the card's header already
    ///   says the plan's verdict ("Comfortable"), the Plan limits section
    ///   keeps only its title rather than saying it a second time. A compact
    ///   card drops the header word (see `fillClaudeStatus`), so there the
    ///   section keeps it.
    /// - Parameter shortLabels: the dense form at a narrow column's width -
    ///   "Session" / "Week" / "Fable" and the reset time without its
    ///   "Resets" word. The long reset sentence stays on each row's hover
    ///   text and VoiceOver help, so nothing is lost but the painted word.
    static func claudeUsageSections(for snapshot: QuotaSnapshot,
                                    now: Date = Date(),
                                    headerCarriesVerdict: Bool = false,
                                    shortLabels: Bool = false) -> [HelmModuleUsageSection] {
        func row(_ title: String, _ window: QuotaWindow?) -> HelmModuleUsageRow {
            guard let window else {
                return HelmModuleUsageRow(title: title, value: "Not reported",
                                          fill: nil, state: .idle, isGap: true)
            }
            return HelmModuleUsageRow(
                title: title,
                value: percentText(window.percentUsed),
                fill: max(0, min(1, window.percentUsed / 100)),
                state: QuotaSeverity(percentUsed: window.percentUsed).moduleRowState,
                // Both forms, deliberately: the short one is painted beside
                // the bar and the long one stays on the hover and the
                // accessibility label, so the full date is still one hover
                // away. Both are `nil` for a window carrying no reset
                // instant, which passes through as no caption and no
                // affordance rather than a fabricated one.
                //
                // **The `Resets` prefix is the redesign's own addition**, and
                // it is the mockup's wording. In the strip the compact time
                // sat directly under a column headed SESSION (5H), which
                // said what it was; here it sits at the card's right edge
                // with a bar between it and its row's title, and a bare
                // "10:30 PM" out there could be anything. The mockup also
                // carries a live countdown ("in 2h 14m") which this card
                // deliberately does not: a counting figure needs one
                // injectable clock on a controller that ticks it (AGENTS.md),
                // and nothing on this canvas ticks - a countdown rendered
                // once at build time and then left to go stale would be
                // worse than the instant it replaced.
                caption: window.resetsCompact(now: now).map { shortLabels ? $0 : "Resets \($0)" },
                detail: window.resetsSentence)
        }

        let rows = [
            row(shortLabels ? "Session" : "Session (5h)", snapshot.session),
            row("Week", snapshot.weekly),
            row(shortLabels ? "Fable" : "Fable week", snapshot.fable),
        ]

        var sections: [HelmModuleUsageSection] = [
            HelmModuleUsageSection(title: "Plan limits",
                                   status: headerCarriesVerdict ? nil : claudePlanLimitsStatus(for: snapshot),
                                   content: .limits(rows)),
        ]
        sections.append(HelmModuleUsageSection(title: "Extra usage",
                                               status: claudeSpendStatus(for: snapshot),
                                               content: claudeSpendContent(for: snapshot,
                                                                           shortLabels: shortLabels)))
        // U4: one alarm colour per card. The thresholds above are untouched -
        // this only stops a card spending two hues on one situation. See
        // `keepingOnlyTheWorstAlarm`.
        return sections.keepingOnlyTheWorstAlarm()
    }

    /// The extra-usage section's body. Three genuinely different states, and
    /// they read differently (GL-14): no window at all, a window carrying
    /// dollars but no cap, and the full reading.
    /// `shortLabels` drops the word "cap" from "of $140 cap" for the dense
    /// form's narrow column, where the worst-case "$137.62 of $140 cap" was
    /// measured painting truncated at 293pt. The row's hover text still
    /// carries the footnote, which says "before the cap" in full.
    static func claudeSpendContent(for snapshot: QuotaSnapshot,
                                   shortLabels: Bool = false) -> HelmModuleUsageSection.Content {
        guard let credits = snapshot.extraUsage, let spent = credits.spentUsd else {
            return .note("Not reported.")
        }
        guard let limit = credits.limitUsd, limit > 0 else {
            // No ceiling, so no bar and no percentage: a track drawn against
            // a cap nobody sent would be a picture of a number that does not
            // exist.
            return .spend(HelmModuleUsageSpend(
                amount: dollarText(spent), against: "spent, no cap set",
                value: nil, fill: nil, state: .idle, footnote: nil))
        }
        let fraction = max(0, min(1, spent / limit))
        // The percentage the *card* states is derived from the two dollar
        // figures it is already showing, rather than from `percentUsed` -
        // which is independently optional on this window and, when both are
        // present, is the same quantity. A figure the captain can check
        // against the two numbers beside it is worth more than one they
        // cannot.
        let state = QuotaSeverity(percentUsed: fraction * 100).moduleRowState
        let remaining = max(0, limit - spent)
        return .spend(HelmModuleUsageSpend(
            amount: dollarText(spent),
            against: shortLabels ? "of \(dollarText(limit))" : "of \(dollarText(limit)) cap",
            value: percentText(fraction * 100),
            fill: fraction,
            state: state,
            footnote: remaining > 0
                ? "\(dollarText(remaining)) left before the cap"
                : "Cap reached, extra usage is paused"))
    }

    /// The Plan limits section's verdict - the binding window, named.
    static func claudePlanLimitsStatus(for snapshot: QuotaSnapshot) -> HelmModuleUsageStatus? {
        guard let worst = claudeWorstWindow(for: snapshot) else {
            return HelmModuleUsageStatus(text: "No limits reported", state: .idle)
        }
        if worst.window.percentUsed >= 100 {
            return HelmModuleUsageStatus(text: "\(worst.name) limit reached", state: .bad)
        }
        switch QuotaSeverity(percentUsed: worst.window.percentUsed) {
        case .critical: return HelmModuleUsageStatus(text: "\(worst.name) nearly used", state: .bad)
        case .warning: return HelmModuleUsageStatus(text: "\(worst.name) getting close", state: .warn)
        case .comfortable: return HelmModuleUsageStatus(text: "Comfortable", state: .ok)
        }
    }

    /// The Extra usage section's verdict.
    static func claudeSpendStatus(for snapshot: QuotaSnapshot) -> HelmModuleUsageStatus? {
        guard let fraction = claudeSpendFraction(for: snapshot) else {
            return HelmModuleUsageStatus(text: "No cap", state: .idle)
        }
        if fraction >= 1 { return HelmModuleUsageStatus(text: "Cap reached", state: .bad) }
        switch QuotaSeverity(percentUsed: fraction * 100) {
        case .critical: return HelmModuleUsageStatus(text: "Near cap", state: .bad)
        case .warning: return HelmModuleUsageStatus(text: "Approaching cap", state: .warn)
        case .comfortable: return HelmModuleUsageStatus(text: "Within cap", state: .ok)
        }
    }

    /// `spent / limit`, or `nil` when the response did not carry both - the
    /// one place the card decides whether it has a spend reading at all.
    static func claudeSpendFraction(for snapshot: QuotaSnapshot) -> Double? {
        guard let credits = snapshot.extraUsage,
              let spent = credits.spentUsd,
              let limit = credits.limitUsd, limit > 0 else { return nil }
        return max(0, spent / limit)
    }

    /// The window that runs out first, with the name the header pill uses
    /// for it. `nil` when the response carried no resetting window at all.
    static func claudeWorstWindow(for snapshot: QuotaSnapshot) -> (name: String, window: QuotaWindow)? {
        let windows: [(String, QuotaWindow)] = [
            ("Session", snapshot.session), ("Week", snapshot.weekly), ("Fable", snapshot.fable),
        ].compactMap { name, window in window.map { (name, $0) } }
        return windows.max(by: { $0.1.percentUsed < $1.1.percentUsed }).map { ($0.0, $0.1) }
    }

    /// `Updated 2 min ago`. Relative, not absolute, because the question the
    /// caption answers is "are these figures worth acting on" rather than
    /// "what time was it" - and a wall-clock stamp makes the captain do the
    /// subtraction themselves.
    ///
    /// `now` is injectable for the same reason every other date helper here
    /// is: a suite that drove a fabricated instant and then measured the real
    /// elapsed time would be testing two clocks rather than the feature
    /// (AGENTS.md's one-injectable-clock rule).
    static func claudeUpdatedText(fetchedAt: Date, now: Date = Date()) -> String {
        "Updated " + HelmRelativeTime.phrase(since: fetchedAt, now: now)
    }

    /// `96%`. No decimal: `quota-axi` reports whole `percentRemaining`
    /// integers, so a `.1f` here would invent precision the source does not
    /// have.
    static func percentText(_ percentUsed: Double) -> String {
        "\(Int(percentUsed.rounded()))%"
    }

    /// `$140` for a whole number of dollars, `$137.62` otherwise - the cap is
    /// always round and the spend rarely is, and `$140.00` beside `$137.62`
    /// reads as false precision on a card this dense.
    static func dollarText(_ amount: Double) -> String {
        amount == amount.rounded()
            ? String(format: "$%.0f", amount)
            : String(format: "$%.2f", amount)
    }

    /// The plan, named as a plan - the mockup's `Team plan` rather than the
    /// bare `Team` the strip carried.
    ///
    /// The extra word is worth its width: "Team" beside a gauge tile reads as
    /// a label for something on the card, where "Team plan" is unambiguously
    /// the account's own tier, which is what the header is for. Falls back to
    /// naming the *source* when the response carried no plan at all, which is
    /// a stated gap rather than a guess (GL-14).
    static func claudeSubtitle(for snapshot: QuotaSnapshot) -> String {
        guard let plan = snapshot.plan, !plan.isEmpty else { return "quota-axi" }
        return "\(plan.capitalized) plan"
    }

    /// The header pill: **one** verdict for the whole card.
    ///
    /// It has to weigh two independent things now, which is what the
    /// redesign changed. The strip's chip only ever looked at the three
    /// resetting windows, so a card whose spend was a dollar off its cap
    /// could read "Comfortable" - the captain's own mockup names that case
    /// ("Near spend cap") and shows it winning over three comfortable
    /// windows, which is the right call: the windows refill on a clock and
    /// the cap does not.
    ///
    /// The tie-break is the mockup's: spend wins when it is at least as
    /// alarming as the worst window. Below the warning threshold on both,
    /// the card says so in one word rather than restating a row.
    static func claudeChip(for snapshot: QuotaSnapshot) -> HelmModuleChip? {
        let worst = claudeWorstWindow(for: snapshot)
        let windowSeverity = worst.map { QuotaSeverity(percentUsed: $0.window.percentUsed) }
        let spendFraction = claudeSpendFraction(for: snapshot)
        let spendSeverity = spendFraction.map { QuotaSeverity(percentUsed: $0 * 100) }

        if let spendSeverity, spendSeverity != .comfortable,
           claudeSeverityRank(spendSeverity) >= claudeSeverityRank(windowSeverity ?? .comfortable) {
            if (spendFraction ?? 0) >= 1 { return .bad("Spend cap reached") }
            return spendSeverity == .critical
                ? .bad("Near spend cap")
                : .warn("Extra usage climbing")
        }

        guard let worst, let windowSeverity else { return nil }
        switch windowSeverity {
        case .critical, .warning:
            let text = worst.window.percentUsed >= 100
                ? "\(worst.name) limit reached"
                : "\(worst.name) limit close"
            return windowSeverity == .critical ? .bad(text) : .warn(text)
        case .comfortable:
            return .ok("Comfortable")
        }
    }

    /// How alarming one severity is against another. `QuotaSeverity` is
    /// deliberately not `Comparable` - it is a verdict, not a scale, and the
    /// only place this app needs to order two of them is the pill above.
    static func claudeSeverityRank(_ severity: QuotaSeverity) -> Int {
        switch severity {
        case .comfortable: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    /// The split hero's panel for one reading: what the gradient says.
    struct ClaudeHeroPanel: Equatable {
        let headline: String
        let body: String?
        let ring: HelmModuleCard.HeroRing?
        /// The header's status. `nil` while the headline is the verdict;
        /// only a refresh that failed adds one.
        let chip: HelmModuleChip?
        /// GL-14: there is no reading to show, so the colour dims. A failed
        /// refresh over a real reading keeps the colour - its pill and
        /// headline say the figures may be behind.
        let isStale: Bool
    }

    /// The panel for a reading, a failure, or neither yet. `static` so a suite
    /// can assert every state from a fabricated snapshot.
    ///
    /// The headline is the card's one verdict - `claudeChip`'s, worded as a
    /// sentence - and the ring shows the reading that verdict is about: the
    /// spend against its cap when the spend is what is alarming, otherwise
    /// the window that runs out first.
    static func claudeHeroPanel(snapshot: QuotaSnapshot?, failure: String?, fetchedAt: Date?,
                                now: Date = Date()) -> ClaudeHeroPanel {
        guard let snapshot else {
            if failure != nil {
                return ClaudeHeroPanel(headline: "No reading yet",
                                       body: "The Claude quota could not be read. Refresh to try again.",
                                       ring: nil, chip: .warn("unavailable"), isStale: true)
            }
            return ClaudeHeroPanel(headline: "Reading the quota\u{2026}", body: nil, ring: nil, chip: nil,
                                   isStale: false)
        }

        let verdict = claudeChip(for: snapshot)
        let spendFraction = claudeSpendFraction(for: snapshot)
        let worst = claudeWorstWindow(for: snapshot)
        // The spend is the subject when it is the verdict: `claudeChip` lets
        // it win only when it is at least as alarming as the worst window.
        let spendIsTheSubject = spendFraction != nil
            && QuotaSeverity(percentUsed: (spendFraction ?? 0) * 100) != .comfortable
            && claudeSpendWinsVerdict(snapshot)

        var ring: HelmModuleCard.HeroRing?
        if spendIsTheSubject, let fraction = spendFraction, let limit = snapshot.extraUsage?.limitUsd {
            let percent = percentText(fraction * 100)
            ring = HelmModuleCard.HeroRing(
                fraction: min(1, fraction), label: percent, caption: "of the \(dollarText(limit)) cap",
                spoken: "Extra usage, \(percent) of the \(dollarText(limit)) cap",
                state: QuotaSeverity(percentUsed: fraction * 100).moduleRowState)
        } else if let worst {
            let percent = percentText(worst.window.percentUsed)
            let noun = claudeWindowNoun(worst.name)
            ring = HelmModuleCard.HeroRing(
                fraction: max(0, min(1, worst.window.percentUsed / 100)), label: percent,
                caption: "of \(noun) used", spoken: "\(percent) of \(noun) used",
                state: QuotaSeverity(percentUsed: worst.window.percentUsed).moduleRowState)
        }

        let headline: String
        switch verdict?.kind {
        case nil: headline = "No limits reported"
        case .ok?: headline = worst?.name == "Session" ? "Plenty of room this session" : "Plenty of room this week"
        default: headline = verdict?.text ?? "Plenty of room"
        }

        var sentences: [String] = []
        if let worst {
            let noun = claudeWindowNoun(worst.name)
            // `String(...)` on both halves: a `Substring` in a concatenation
            // is what CI's compiler rejected once (AGENTS.md's toolchain note).
            var sentence = String(noun.prefix(1)).uppercased() + String(noun.dropFirst())
                + " is at \(percentText(worst.window.percentUsed))"
            if let resets = worst.window.resetsCompact(now: now) { sentence += " and resets \(resets)" }
            sentences.append(sentence + ".")
        }
        if let spend = claudeSpendSentence(for: snapshot) {
            if spendIsTheSubject { sentences.insert(spend, at: 0) } else { sentences.append(spend) }
        }

        if failure != nil {
            let time = fetchedAt.map { briefingTimeFormatter.string(from: $0) }
            return ClaudeHeroPanel(headline: time.map { "Showing the \($0) reading" } ?? "Showing the last reading",
                                   body: "The last refresh failed, so these figures may be behind.",
                                   ring: ring, chip: .warn("Can't reach"), isStale: false)
        }
        return ClaudeHeroPanel(headline: headline, body: sentences.isEmpty ? nil : sentences.joined(separator: " "),
                               ring: ring, chip: nil, isStale: false)
    }

    /// Whether the spend, rather than a window, carries `claudeChip`'s verdict.
    static func claudeSpendWinsVerdict(_ snapshot: QuotaSnapshot) -> Bool {
        guard let spend = claudeSpendFraction(for: snapshot) else { return false }
        let spendSeverity = QuotaSeverity(percentUsed: spend * 100)
        let windowSeverity = claudeWorstWindow(for: snapshot).map { QuotaSeverity(percentUsed: $0.window.percentUsed) }
        return claudeSeverityRank(spendSeverity) >= claudeSeverityRank(windowSeverity ?? .comfortable)
    }

    /// "the week", "the session", "the Fable week" - `claudeWorstWindow`'s
    /// names in a sentence.
    static func claudeWindowNoun(_ name: String) -> String {
        switch name {
        case "Session": return "the session"
        case "Fable": return "the Fable week"
        default: return "the week"
        }
    }

    /// The extra-usage pool in one sentence, or `nil` when it was not reported.
    static func claudeSpendSentence(for snapshot: QuotaSnapshot) -> String? {
        guard let credits = snapshot.extraUsage, let spent = credits.spentUsd else { return nil }
        guard let limit = credits.limitUsd, limit > 0 else {
            return spent > 0 ? "\(dollarText(spent)) of extra usage spent, with no cap set." : "No extra usage spent."
        }
        if spent >= limit { return "Extra usage hit the \(dollarText(limit)) cap and is paused." }
        if spent <= 0 { return "No extra usage spent." }
        return "\(dollarText(spent)) of the \(dollarText(limit)) extra-usage cap is spent."
    }

    /// The Claude card as the split hero: the verdict and its ring on the
    /// panel, every reading and reset time on the card beside it - the dense
    /// report's own rows, so no figure, threshold or short-label rule moves.
    func fillClaudeHero(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        let layout = HelmModuleCard.HeroLayout(cardWidth: width)
        let detailWidth = HelmModuleCard.HeroSplit.detailWidth(cardWidth: width, layout: layout)
        let panel = Self.claudeHeroPanel(snapshot: quotaSnapshot, failure: quotaFailure, fetchedAt: quotaFetchedAt)

        if let snapshot = quotaSnapshot {
            content.subtitle = Self.claudeSubtitle(for: snapshot)
        } else {
            content.subtitle = quotaFailure == nil ? "reading" : "no reading"
        }
        content.chip = panel.chip
        if let failure = quotaFailure {
            content.toolTip = "The last refresh failed: \(failure)"
        } else if quotaSnapshot != nil, let fetchedAt = quotaFetchedAt {
            // The narrow band has no room beside Refresh and the palette, so
            // the age moves to the card's hover text there (the compact rule).
            let updated = Self.claudeUpdatedText(fetchedAt: fetchedAt)
            if layout == .narrow { content.toolTip = updated } else { content.headerCaption = updated }
        }

        let detail: HelmModuleCard.HeroSplit.Detail
        if let snapshot = quotaSnapshot {
            detail = .report(Self.claudeUsageSections(
                for: snapshot, headerCarriesVerdict: true,
                shortLabels: Self.claudeUsesShortLabels(forCardWidth: detailWidth)))
        } else if let failure = quotaFailure {
            detail = .note(failure)
        } else {
            detail = .loading
        }
        content.body = .heroSplit(HelmModuleCard.HeroSplit(headline: panel.headline, body: panel.body,
                                                           ring: panel.ring, detail: detail, layout: layout))
        content.hero = heroTone(for: .claudeStatus, dimmed: panel.isStale)
        content.headerMenu = styleMenu(for: .claudeStatus)
    }
}
