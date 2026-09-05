// Manjesh Grand Line - native macOS app.
//
// F6's read side: what Overview's "Log" tab actually renders.
//
// **Why the task half is not in the JSONL file.** The spec's own instruction
// is that "Shift's activity YAML already covers the task half and can feed
// it", and that is exactly what this does - `ShiftStore` has been logging
// `task_created`/`task_completed`/`follow_up_snoozed`/... into
// `activity/<YYYY-MM>.yaml` since Shift phase 1, with a human-readable
// summary already phrased by the code that caused it. Copying those into a
// second file would mean two sources of truth for one fact, a write path that
// can half-fail, and a retention cap on this side silently truncating history
// Shift's own files still hold. Reading them instead also means the Log tab
// is useful on first launch, against months of task history that predates
// this feature.
//
// So the feed is a merge: `FleetLogStore`'s own events (merges, resolved sync
// conflicts, saved investigations - none of which had anywhere to be recorded
// before) plus Shift's activity entries, sorted newest-first and grouped by
// day. Nothing here polls; both sides are read on demand when the tab is
// shown or refreshed.

import Foundation

enum FleetLogFeed {

    /// How far back Shift's activity is read. Matches `weeklySummary`'s own
    /// bounded lookback rather than scanning every month file that has ever
    /// existed - the Log tab is "what happened lately", and a captain wanting
    /// the full record has Weekly Review and the YAML itself.
    static let shiftMonthsBack = 2

    /// A hard cap on how many events the feed hands the table, after the
    /// merge. Purely a rendering bound (the table itself is demand-driven);
    /// it stops a captain with an enormous activity history from paying a
    /// sort and a group-walk over all of it every time the tab is shown.
    static let displayLimit = 500

    /// The merged, newest-first feed. `shift` is optional so the feed still
    /// works (with merges/sync/investigations only) in a configuration with no
    /// Shift store to read.
    static func events(store: FleetLogStore,
                       shift: ShiftStore?,
                       reference: Date = Date()) -> [FleetLogEvent] {
        var all = store.events()
        if let shift {
            all.append(contentsOf: shift
                .recentActivity(monthsBack: shiftMonthsBack, reference: reference)
                .compactMap(taskEvent(from:)))
        }
        all.sort { $0.date > $1.date }
        return Array(all.prefix(displayLimit))
    }

    /// One Shift activity entry as a feed event. Every activity kind Shift
    /// logs is a task/follow-up/project state change, which is one concept -
    /// the mockup's "Tasks" pill - so they all map to `.task` rather than
    /// this inventing sub-kinds the filter row has no place for. The summary
    /// is Shift's own already-rendered wording, not re-phrased here.
    /// An entry whose timestamp will not parse is dropped rather than dated
    /// "now", which would float ancient history to the top of the feed.
    static func taskEvent(from entry: ShiftActivityEntry) -> FleetLogEvent? {
        guard let date = Self.isoFormatter.date(from: entry.timestamp) else { return nil }
        return FleetLogEvent(id: entry.id, date: date, kind: .task,
                             title: entry.summary, reference: entry.targetID)
    }

    // MARK: Filtering

    /// `nil` = the "All" pill.
    static func filtered(_ events: [FleetLogEvent], kind: FleetLogEventKind?) -> [FleetLogEvent] {
        guard let kind else { return events }
        return events.filter { $0.kind == kind }
    }

    // MARK: Day grouping

    /// The flattened row list the table renders: a day header followed by that
    /// day's events, in feed order. Flattened rather than nested so the table
    /// stays a single-column, demand-driven `NSTableView` (this codebase's
    /// established list shape) instead of needing sections.
    enum Row: Equatable {
        case header(String)
        case event(FleetLogEvent)
    }

    /// TODAY / YESTERDAY / an absolute date for anything older, matching the
    /// mockup. Uppercased at render time by the header view's own styling, so
    /// the string here stays a plain readable label.
    static func dayLabel(for date: Date, reference: Date = Date(),
                         calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: reference) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return absoluteDayFormatter.string(from: date)
    }

    static func rows(for events: [FleetLogEvent], reference: Date = Date(),
                     calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        var currentDay: Date?
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if currentDay != day {
                currentDay = day
                rows.append(.header(dayLabel(for: event.date, reference: reference, calendar: calendar)))
            }
            rows.append(.event(event))
        }
        return rows
    }

    // MARK: Row text

    /// The row's kicker: the time of day plus the kind, e.g. "10:32 AM ·
    /// MERGE". The mockup's own kicker reads "10:32 today", but the day is
    /// already the group header directly above the row, so repeating it on
    /// every line would be noise - the kind is the thing a grouped feed still
    /// needs per row.
    static func kicker(for event: FleetLogEvent) -> String {
        "\(timeFormatter.string(from: event.date)) \u{00B7} \(event.kind.rawValue)"
    }

    // GL-P3: static formatters - constructing a `DateFormatter` per row is a
    // measurable cost in a list, and these carry no per-call state.
    /// GL-P3: `taskEvent(from:)` runs once per Shift activity entry when the
    /// log is assembled, so this cannot be per-call.
    private static let isoFormatter = ISO8601DateFormatter()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()

    private static let absoluteDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()
}
