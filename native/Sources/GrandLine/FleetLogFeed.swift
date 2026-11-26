// Grand Line - native macOS app.
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
        read(store: store, shift: shift, reference: reference).events
    }

    /// One read of the feed, and which half of it could not be read.
    ///
    /// GL-14: the Crew band's Log tab counts this feed, and an unreadable
    /// file is not an empty one. The two halves hold different kinds - the
    /// log file merges, sync fixes, investigations and incidents, Shift's
    /// activity the task updates - so each half's failure leaves exactly
    /// its own kinds unknown, and the rest still counted.
    struct Read: Equatable {
        /// Newest first, capped at `displayLimit`: what the list renders.
        var events: [FleetLogEvent]
        /// The log file is there and could not be read.
        var logUnreadable = false
        /// At least one of Shift's activity months in the window is there
        /// and could not be read.
        var activityUnreadable = false
        /// When this read was taken.
        var readAt: Date
    }

    static func read(store: FleetLogStore, shift: ShiftStore?, reference: Date = Date()) -> Read {
        let logged = store.eventsChecked()
        var all = logged.events
        var activityUnreadable = false
        if let shift {
            let activity = shift.recentActivityChecked(monthsBack: shiftMonthsBack, reference: reference)
            all.append(contentsOf: activity.entries.compactMap(taskEvent(from:)))
            activityUnreadable = !activity.unreadableMonths.isEmpty
        }
        all.sort { $0.date > $1.date }
        return Read(events: Array(all.prefix(displayLimit)), logUnreadable: logged.unreadable,
                    activityUnreadable: activityUnreadable, readAt: reference)
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

    // MARK: UX-07 - the timeline

    /// One line of the timeline: a day, an hour, an event, or a run of
    /// events of the same kind folded into one line.
    enum TimelineRow: Equatable {
        case day(String)
        case hour(String)
        case event(FleetLogEvent)
        case run(Run)
    }

    /// Consecutive events in one hour that say the same thing about the
    /// same sort of record: "Created 8 tasks", "Created 3 projects: Infra
    /// hardening, Release 4.20, SRE hiring".
    struct Run: Equatable {
        /// The first event's id, which names the run while it is expanded.
        let id: String
        let events: [FleetLogEvent]
        let verb: String
        let noun: String
        let isExpanded: Bool
        /// The count phrase the row sets in bold: "8 tasks".
        var countPhrase: String { "\(events.count) \(Self.plural(noun, events.count))" }
        /// The names it holds, when three or fewer: said after the count.
        var names: [String] { events.compactMap { FleetLogFeed.parse($0.title)?.name } }
        /// The whole line, as VoiceOver reads it.
        var text: String {
            let tail = events.count <= Self.namesShownUpTo ? ": " + names.joined(separator: ", ") : ""
            return "\(verb) \(countPhrase)\(tail)"
        }
        static let namesShownUpTo = 3

        static func plural(_ noun: String, _ count: Int) -> String {
            count == 1 ? noun : noun + "s"
        }
    }

    /// A Shift activity line, read back into its verb, the sort of record it
    /// is about and the record's name: "Created follow-up \"Ping Nithin\""
    /// is ("Created", "follow-up", "Ping Nithin"). `nil` for a line that is
    /// not in that shape (a merge, a sync fix), which is never folded.
    static func parse(_ title: String) -> (verb: String, noun: String, name: String)? {
        guard let quote = title.firstIndex(of: "\""), title.hasSuffix("\""), quote < title.index(before: title.endIndex)
        else { return nil }
        let head = title[..<quote].trimmingCharacters(in: .whitespaces)
        let name = String(title[title.index(after: quote)..<title.index(before: title.endIndex)])
        let words = head.split(separator: " ").map(String.init)
        guard let verb = words.first, ["Created", "Completed", "Reopened", "Deleted", "Snoozed"].contains(verb)
        else { return nil }
        let rest = words.dropFirst().joined(separator: " ")
        let noun: String
        switch rest {
        case "": noun = "task"
        case "project", "follow-up": noun = rest
        default: return nil
        }
        return (verb, noun, name)
    }

    /// The fewest consecutive events that fold into a run.
    static let foldsFrom = 2

    /// The timeline's rows: each day, each hour inside it, and its events,
    /// newest first, with runs folded unless their id is in `expanded`.
    static func timelineRows(for events: [FleetLogEvent], expanded: Set<String> = [], reference: Date = Date(),
                             calendar: Calendar = .current) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        var currentDay: Date?
        var currentHour: Date?
        var index = 0
        while index < events.count {
            let event = events[index]
            let day = calendar.startOfDay(for: event.date)
            if currentDay != day {
                currentDay = day
                currentHour = nil
                rows.append(.day(dayLabel(for: event.date, reference: reference, calendar: calendar)))
            }
            let hour = calendar.dateInterval(of: .hour, for: event.date)?.start ?? event.date
            if currentHour != hour {
                currentHour = hour
                rows.append(.hour(hourFormatter.string(from: event.date)))
            }
            // The run this event starts: the same kind, verb and noun, in
            // the same hour.
            var end = index + 1
            if let key = parse(event.title) {
                while end < events.count, events[end].kind == event.kind,
                      let next = parse(events[end].title), next.verb == key.verb, next.noun == key.noun,
                      calendar.dateInterval(of: .hour, for: events[end].date)?.start == hour {
                    end += 1
                }
                if end - index >= foldsFrom {
                    let run = Run(id: event.id, events: Array(events[index..<end]), verb: key.verb, noun: key.noun,
                                  isExpanded: expanded.contains(event.id))
                    rows.append(.run(run))
                    if run.isExpanded { rows += run.events.map(TimelineRow.event) }
                    index = end
                    continue
                }
            }
            rows.append(.event(event))
            index += 1
        }
        return rows
    }

    /// "11 AM", the hour heading, localised.
    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()

    /// "11:00", the row's own time.
    static func time(for event: FleetLogEvent) -> String { timeFormatter.string(from: event.date) }

    /// Whether `event` happened on `reference`'s day: the Today scope.
    static func isToday(_ event: FleetLogEvent, reference: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(event.date, inSameDayAs: reference)
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
