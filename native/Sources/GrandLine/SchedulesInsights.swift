// Grand Line - native macOS app.
//
// `fm/grand-line-schedules-page-redesign`: the three run-history surfaces the
// captain's two reference designs asked the Schedules page for - a per-row
// sparkline, a "recent activity" feed, and a 7-day run-overview chart - plus
// the one pure function that buckets a run history into days.
//
// **Every number here comes from `ScheduleRunHistoryStore`, which is real.**
// That mattered more than anything else about this redesign. The references
// are standalone HTML mockups carrying fabricated demo data (a fictional
// "Daily workspace report" schedule, a hardcoded 24-run bar chart), and the
// brief's own instruction was explicit: wire these to whatever real history
// the app already tracks, or scope the piece out - never invent data points to
// fill a shape. This app does keep a real per-run log (`ScheduleRunner.execute`
// appends one `ScheduleRunHistoryEntry` per completed run), so all three are
// backable, with two honesty caveats that shape the code below:
//
//  1. **The window is 7 days, not "the last 14 runs".** The second reference
//     labels its sparkline "LAST 14 RUNS"; `ScheduleRunHistoryStore.retentionWindow`
//     is 7 days, so for a nightly schedule there are at most ~7 real bars ever.
//     `ScheduleRunSparkline` therefore draws exactly as many bars as there are
//     real entries - never padded to a target count - and its tooltip states
//     the real number and the window. A schedule with no runs on record draws
//     nothing at all rather than a row of grey placeholders.
//
//  2. **The bar *count* is shared across rows, and that is a layout
//     requirement rather than a cosmetic one.** The row's trailing cluster is
//     `[sparkline, time column, overflow, toggle]`, and the time column is a
//     genuine column - one constant x down the list, which
//     `DaylightDrillPageSlice3SelfTest` measures. A sparkline sized to its own
//     row's history would move every column right of it, so the card passes one
//     `slots` value (the widest real history in this render pass, capped at
//     `maxBars`) and every sparkline reserves that same width. Zero slots
//     collapses the view on every row at once, so an app with no history yet
//     has no dead gap.

import AppKit

// MARK: - Bucketing (pure)

/// The arithmetic behind the run-overview chart, split out with no AppKit in
/// it so a self-test can drive the real function rather than re-deriving a
/// second copy of the same day maths in the check.
enum ScheduleRunStats {

    /// One calendar day of runs.
    struct DayBucket: Equatable {
        let day: Date
        let total: Int
        /// Runs that came back `.changed` or `.failed` - i.e. the half that
        /// wanted the captain. Deliberately *not* folded into `total`: the
        /// chart draws both, so it needs them apart.
        let needsAttention: Int
        let isToday: Bool
    }

    /// How many days the chart shows. Exactly
    /// `ScheduleRunHistoryStore.retentionWindow` in days, so the chart's own
    /// window and the store's are the same fact rather than two constants that
    /// can drift - the store prunes at 7 days, so an 8th column could only ever
    /// be empty and would read as "nothing ran that day" rather than "that day
    /// is past the horizon".
    static let dayCount = Int(ScheduleRunHistoryStore.retentionWindow / (24 * 3600))

    /// Oldest first, so the chart reads left-to-right into today.
    ///
    /// Every day in the window is emitted, including the ones with no runs - a
    /// gap in a bar chart is a real signal ("nothing ran on Tuesday") and
    /// dropping empty days would silently compress the axis.
    static func dailyBuckets(entries: [ScheduleRunHistoryEntry],
                             now: Date = Date(),
                             calendar: Calendar = .current) -> [DayBucket] {
        let today = calendar.startOfDay(for: now)
        return (0..<dayCount).reversed().compactMap { offset -> DayBucket? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let runs = entries.filter { calendar.isDate($0.at, inSameDayAs: day) }
            return DayBucket(day: day,
                             total: runs.count,
                             needsAttention: runs.filter { $0.verdict != .clean }.count,
                             isToday: offset == 0)
        }
    }

    /// The single-letter weekday axis label ("M", "T", ...). `veryShortWeekdaySymbols`
    /// rather than a hand-written table so a non-English locale is not silently
    /// mislabelled.
    static func axisLabel(for day: Date, calendar: Calendar = .current) -> String {
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }
}

// MARK: - Per-row sparkline

/// A compact strip of one bar per recorded run, oldest on the left.
///
/// The second reference's per-schedule run history, adapted to the real 7-day
/// window (see this file's header). Bars are painted with the verdict's own
/// `HelmTint` as a **fill**, which is the sanctioned use of a hue - never as
/// text, where it would need `HelmContrast`'s correction first.
final class ScheduleRunSparkline: NSView {

    /// The most bars ever drawn. A schedule running hourly would otherwise
    /// produce ~168 one-pixel slivers inside a row, which is noise rather than
    /// history - the newest `maxBars` are shown and the tooltip says how many
    /// were recorded in total, so the cap is stated rather than silent.
    static let maxBars = 14
    static let barWidth: CGFloat = 4
    static let barGap: CGFloat = 2
    static let barHeight: CGFloat = 16

    /// The width `slots` bars occupy, which is what every row in one render
    /// pass reserves. See the header for why this is shared rather than
    /// per-row.
    static func width(forSlots slots: Int) -> CGFloat {
        guard slots > 0 else { return 0 }
        return CGFloat(slots) * barWidth + CGFloat(slots - 1) * barGap
    }

    private var verdicts: [ScheduleRunVerdict] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        // Below `NSLayoutPriorityWindowSizeStayPut` (500) - AGENTS.md gotcha
        // (13). A row's decoration must never be the thing that decides how
        // narrow the window may get.
        widthConstraint.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// - Parameters:
    ///   - entries: this schedule's own real history, newest first (exactly
    ///     what `ScheduleRunHistoryStore.entries(for:)` returns).
    ///   - fallback: the schedule's own `lastRun`, used **only** when the
    ///     history store has nothing for it. Not a fabrication: `lastRun` is a
    ///     real completed run, and the two records genuinely diverge in one
    ///     case worth drawing - a schedule whose last run is older than the
    ///     store's 7-day retention still has a `lastRun` on the schedule
    ///     itself, and showing one bar there is more honest than showing none.
    ///   - slots: the shared reserved bar count for this render pass.
    func setRuns(_ entries: [ScheduleRunHistoryEntry],
                 fallback: ScheduleRunRecord?,
                 slots: Int,
                 theme: HelmTheme) {
        self.theme = theme
        let recorded: [ScheduleRunVerdict]
        let totalRecorded: Int
        if entries.isEmpty {
            recorded = fallback.map { [$0.verdict] } ?? []
            totalRecorded = recorded.count
        } else {
            totalRecorded = entries.count
            // `entries` is newest-first; the strip reads oldest-to-newest, and
            // the cap keeps the *newest* runs.
            recorded = Array(entries.prefix(Self.maxBars)).reversed().map { $0.verdict }
        }
        verdicts = recorded
        widthConstraint.constant = Self.width(forSlots: slots)
        isHidden = slots <= 0
        toolTip = Self.tooltip(shown: recorded.count, total: totalRecorded)
        setAccessibilityLabel(toolTip)
        needsDisplay = true
    }

    private static func tooltip(shown: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        let runs = total == 1 ? "1 run" : "\(total) runs"
        if shown < total {
            return "Last \(shown) of \(runs) recorded in the past 7 days"
        }
        return "\(runs) recorded in the past 7 days"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !verdicts.isEmpty else { return }
        // Newest at the right, so a history still filling up grows toward the
        // time column rather than away from it.
        let used = Self.width(forSlots: verdicts.count)
        var x = bounds.width - used
        for verdict in verdicts {
            let rect = NSRect(x: x, y: 0, width: Self.barWidth, height: bounds.height)
            HelmTheme.nsColor(verdict.tint.hex(in: theme)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            x += Self.barWidth + Self.barGap
        }
    }

    #if FM_SELFTESTS
    /// The bars actually drawn - so a check can prove a never-run schedule
    /// draws none rather than a row of placeholders.
    var debugBarCount: Int { verdicts.count }
    var debugReservedWidth: CGFloat { widthConstraint.constant }
    #endif
}

// MARK: - The 7-day run overview chart

/// The first reference's "Run overview" bar chart, over the real 7-day window.
final class ScheduleRunOverviewChart: NSView {

    static let chartHeight: CGFloat = 78
    private static let barCorner: CGFloat = 4
    private static let minVisibleBar: CGFloat = 3
    /// The widest a day's bar is drawn, whatever the panel's own width.
    ///
    /// Without a cap, seven bars across a half-page card resolve to ~120pt
    /// each, and a rounded 120x80 rectangle reads as a *card* rather than as a
    /// bar - measured in a real off-screen render of this panel. The bar is
    /// centred in its slot, so the axis label underneath still lines up with
    /// it and the chart keeps its full width as a chart.
    private static let maxBarWidth: CGFloat = 46

    private var buckets: [ScheduleRunStats.DayBucket] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private let axis = NSStackView()
    private let plot = ChartPlot()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        plot.translatesAutoresizingMaskIntoConstraints = false
        axis.orientation = .horizontal
        axis.distribution = .fillEqually
        axis.spacing = HelmMetrics.s1
        axis.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [plot, axis])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            plot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            axis.widthAnchor.constraint(equalTo: stack.widthAnchor),
            plot.heightAnchor.constraint(equalToConstant: Self.chartHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setBuckets(_ buckets: [ScheduleRunStats.DayBucket], theme: HelmTheme) {
        self.buckets = buckets
        self.theme = theme
        plot.buckets = buckets
        plot.theme = theme
        plot.needsDisplay = true

        for view in axis.arrangedSubviews {
            axis.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for bucket in buckets {
            let label = NSTextField(labelWithString: ScheduleRunStats.axisLabel(for: bucket.day))
            label.font = HelmType.captionSmall()
            label.alignment = .center
            label.textColor = bucket.isToday
                ? HelmTheme.nsColor(theme.chromeInkHex)
                : HelmTheme.mutedInk(theme)
            label.lineBreakMode = .byClipping
            // A one-letter label must never be what stops the window shrinking.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.toolTip = Self.dayTooltip(bucket)
            axis.addArrangedSubview(label)
        }
    }

    private static func dayTooltip(_ bucket: ScheduleRunStats.DayBucket) -> String {
        let date = dayFormatter.string(from: bucket.day)
        guard bucket.total > 0 else { return "\(date): no runs" }
        let runs = bucket.total == 1 ? "1 run" : "\(bucket.total) runs"
        guard bucket.needsAttention > 0 else { return "\(date): \(runs), all clean" }
        return "\(date): \(runs), \(bucket.needsAttention) needing you"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// The drawing half, separate so the axis labels below it are ordinary
    /// views rather than something this had to lay out by hand.
    private final class ChartPlot: NSView {
        var buckets: [ScheduleRunStats.DayBucket] = []
        var theme: HelmTheme = ThemeManager.shared.theme

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard !buckets.isEmpty else { return }
            let peak = max(1, buckets.map(\.total).max() ?? 1)
            let gap = HelmMetrics.s1
            let slot = (bounds.width - gap * CGFloat(buckets.count - 1)) / CGFloat(buckets.count)
            guard slot > 0 else { return }

            let track = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.45)
            let clean = HelmTheme.nsColor(HelmTint.good.hex(in: theme))
            let attention = HelmTheme.nsColor(HelmTint.warn.hex(in: theme))

            let barWidth = min(slot, ScheduleRunOverviewChart.maxBarWidth)
            let inset = (slot - barWidth) / 2
            for (index, bucket) in buckets.enumerated() {
                let x = CGFloat(index) * (slot + gap) + inset
                guard bucket.total > 0 else {
                    // An empty day still draws a hairline baseline, so "nothing
                    // ran" is visible as a day rather than as a missing column.
                    track.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: 2),
                                 xRadius: 1, yRadius: 1).fill()
                    continue
                }
                let height = max(Self.floorHeight,
                                 bounds.height * CGFloat(bucket.total) / CGFloat(peak))
                let cleanCount = bucket.total - bucket.needsAttention
                let cleanHeight = height * CGFloat(cleanCount) / CGFloat(bucket.total)

                // One stacked bar per day: the clean share at the bottom, the
                // needs-you share on top. Two hues in one column rather than
                // two columns, so the day's *total* stays readable as one
                // height - which is what the chart is for.
                clean.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: max(0, cleanHeight)),
                             xRadius: barCorner, yRadius: barCorner).fill()
                if bucket.needsAttention > 0 {
                    attention.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: cleanHeight,
                                                     width: barWidth, height: height - cleanHeight),
                                 xRadius: barCorner, yRadius: barCorner).fill()
                }
            }
        }

        private static let floorHeight: CGFloat = ScheduleRunOverviewChart.minVisibleBar
        private var barCorner: CGFloat { ScheduleRunOverviewChart.barCorner }
    }

    #if FM_SELFTESTS
    var debugAxisLabels: [String] {
        axis.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
    #endif
}
