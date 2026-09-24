// Grand Line - native macOS app.
//
// RRULE-lite recurrence for `ShiftTask` (F5 of full review #3 §8 - see
// `docs/history/34-recurrence-and-calendar.md`).
//
// **Why "lite" rather than RFC 5545.** The report asked for `RRULE`-lite and
// this takes that literally: three frequencies, an interval, a weekday set,
// and two ways to stop. `BYSETPOS`, `BYMONTHDAY`, `BYYEARDAY`, `WKST`,
// `EXDATE` and the whole `VEVENT` envelope are deliberately absent. Nothing
// in this app reads or writes a real `.ics` file, so a full parser would be
// code with no second reader - and the one thing a full parser buys
// (interoperability) is exactly what is not being asked for.
//
// What *is* borrowed from RFC 5545 is the **serialized form**, because the
// store is a captain-owned YAML tree that a person edits by hand
// (`ShiftYaml.swift`'s header). `FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR`
// is a string a captain can read, recognise and correct in a text editor;
// a nested YAML sub-map for the same five fields is not. So the whole rule
// travels as one scalar under a single `recurrence` key.
//
// **The anchor is the task's own due date, and is never stored here.** A rule
// is a pattern ("every weekday"), not a series - which is what lets a task's
// due date be pushed without rewriting its rule, and what makes this type a
// value with no identity of its own.

import Foundation

enum ShiftRecurrenceFrequency: String, CaseIterable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
}

/// One recurrence rule. See this file's header for the deliberate limits.
///
/// `Equatable` for the same reason `ShiftTask` is: `ShiftThreeWayMerge` needs
/// to tell "unchanged" from "edited" when comparing a task across revisions.
struct ShiftRecurrence: Equatable {

    /// Two-letter weekday codes, RFC 5545's own, indexed by `Calendar`'s
    /// weekday numbering (1 = Sunday ... 7 = Saturday) so a value read off
    /// `Calendar.component(.weekday:)` indexes straight into it.
    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// Monday through Friday, in `Calendar` weekday numbers - the set behind
    /// the "Every weekday" preset, and the one selection this app names.
    static let weekdaySet: Set<Int> = [2, 3, 4, 5, 6]

    var frequency: ShiftRecurrenceFrequency
    /// Every `interval` days/weeks/months. Always >= 1: `normalized` clamps
    /// it, so a hand-edited `INTERVAL=0` cannot make the generator loop
    /// forever rather than fail.
    var interval: Int
    /// `Calendar` weekday numbers (1 = Sunday). Weekly only, and **empty
    /// means "whatever weekday the anchor itself falls on"** rather than
    /// "no days at all" - an empty `BYDAY` in a weekly rule is how a plain
    /// "every week" is expressed, and reading it as "never" would silently
    /// turn a valid rule into a task that recurs zero times.
    var weekdays: Set<Int>
    /// Inclusive last date the rule may produce, "YYYY-MM-DD". `nil` = never
    /// ends, which is the default and what the editor shows.
    var until: String?
    /// Total occurrences **including the anchor**, matching RFC 5545's own
    /// `COUNT`. `nil` = unbounded.
    var count: Int?

    init(frequency: ShiftRecurrenceFrequency, interval: Int = 1, weekdays: Set<Int> = [],
         until: String? = nil, count: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.until = until
        self.count = count
    }

    /// The rule with every field forced into range. Every generator below
    /// starts here, so a rule that arrived from a hand-edited YAML file (or
    /// from a git pull of a file another machine wrote) cannot drive the
    /// expansion loop out of bounds.
    var normalized: ShiftRecurrence {
        var copy = self
        copy.interval = max(1, interval)
        copy.weekdays = frequency == .weekly ? weekdays.filter { (1...7).contains($0) } : []
        if let count, count < 1 { copy.count = 1 }
        return copy
    }

    // MARK: Serialization

    /// The RRULE-lite string written under the task's `recurrence` key. Key
    /// order is fixed (never a dictionary's) so an unchanged rule round-trips
    /// to a byte-identical line and a git-synced file shows no diff for a
    /// save that changed nothing.
    var ruleText: String {
        let rule = normalized
        var parts = ["FREQ=\(rule.frequency.rawValue)"]
        parts.append("INTERVAL=\(rule.interval)")
        if !rule.weekdays.isEmpty {
            let codes = rule.weekdays.sorted().map { Self.weekdayCodes[$0 - 1] }
            parts.append("BYDAY=\(codes.joined(separator: ","))")
        }
        if let until = rule.until { parts.append("UNTIL=\(until)") }
        if let count = rule.count { parts.append("COUNT=\(count)") }
        return parts.joined(separator: ";")
    }

    /// Parses `ruleText`'s form back. Returns `nil` for anything without a
    /// frequency this app understands - an empty string, a blank key, or a
    /// real RFC 5545 rule with `FREQ=YEARLY` - rather than guessing, because
    /// a rule quietly downgraded to "daily" would fire a task every morning
    /// forever. Unknown keys are ignored, so a rule that picked up an
    /// extra component elsewhere still loads with the parts this app owns.
    static func parse(_ text: String) -> ShiftRecurrence? {
        var frequency: ShiftRecurrenceFrequency?
        var interval = 1
        var weekdays: Set<Int> = []
        var until: String?
        var count: Int?

        for component in text.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "FREQ":
                frequency = ShiftRecurrenceFrequency(rawValue: value.uppercased())
            case "INTERVAL":
                interval = Int(value) ?? 1
            case "BYDAY":
                for code in value.uppercased().split(separator: ",") {
                    guard let index = weekdayCodes.firstIndex(of: String(code)) else { continue }
                    weekdays.insert(index + 1)
                }
            case "UNTIL":
                until = value.isEmpty ? nil : value
            case "COUNT":
                count = Int(value)
            default:
                continue
            }
        }
        guard let frequency else { return nil }
        return ShiftRecurrence(frequency: frequency, interval: interval, weekdays: weekdays,
                               until: until, count: count).normalized
    }

    // MARK: Expansion

    /// The occurrence that follows `after`, given the series' `anchor` (the
    /// task's own due date). `nil` once the rule has run out - `UNTIL` passed
    /// or `COUNT` exhausted.
    ///
    /// The anchor is itself occurrence 1, which is what makes `COUNT=1` mean
    /// "this once and no repeat" rather than "one more time".
    func next(after date: Date, anchor: Date, calendar: Calendar = .current) -> Date? {
        // Strictly after the given *instant*, not after its day: a rule whose
        // anchor is the date being asked about must not answer with the
        // anchor itself, which is exactly what completing an occurrence asks
        // (`ShiftStore.nextOccurrence`).
        occurrences(anchor: anchor, from: date.addingTimeInterval(1),
                    through: nil, calendar: calendar, limit: 1).first
    }

    /// Every occurrence in `[from, through]`, in order.
    ///
    /// `through` may be `nil` only when `limit` bounds the walk - the two
    /// together are what guarantee termination for an unbounded rule, and
    /// `limit` is required rather than defaulted for exactly that reason.
    /// GL-35: nothing here is unbounded.
    func occurrences(anchor: Date, from: Date, through: Date?, calendar: Calendar = .current,
                     limit: Int) -> [Date] {
        let rule = normalized
        guard limit > 0 else { return [] }
        let untilDate = rule.until.flatMap { Self.endExclusive($0, calendar: calendar) }

        var out: [Date] = []
        var produced = 0
        // A hard ceiling on how many candidates the walk will examine, quite
        // apart from how many it keeps. A weekly rule asked for one occurrence
        // inside a window years ahead still has to step through the weeks in
        // between, and `limit` alone does not bound that.
        let maxSteps = 4000

        for step in 0..<maxSteps {
            let slot = rule.candidates(step: step, anchor: anchor, calendar: calendar)
            if slot.isEmpty { continue }
            for date in slot {
                if date < anchor { continue }
                produced += 1
                if let count = rule.count, produced > count { return out }
                if let untilDate, date >= untilDate { return out }
                if date < from { continue }
                if let through, date > through { return out }
                out.append(date)
                if out.count >= limit { return out }
            }
            // Past the far edge with nothing left that could come back into
            // range: every generator below is monotonic in `step`.
            if let through, let last = slot.last, last > through { return out }
            if let untilDate, let last = slot.last, last >= untilDate { return out }
        }
        return out
    }

    /// `UNTIL`'s own day resolved **in the caller's calendar**, as the first
    /// instant after it - so the bound is inclusive of its own date.
    ///
    /// Parsed here rather than through `ShiftDateFormatting.date(from:)`,
    /// which always resolves in the machine's local zone: mixing that with a
    /// caller-supplied calendar silently shifts the bound by the offset
    /// between the two, and cost this rule its own last day when the test
    /// calendar was UTC and the machine was not.
    private static func endExclusive(_ until: String, calendar: Calendar) -> Date? {
        let parts = until.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let start = calendar.date(from: components) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    /// The dates this rule produces at one step of the walk - a single date
    /// for daily/monthly, and a whole week's selected days for weekly, which
    /// is why this returns an array rather than an optional.
    ///
    /// Every returned slot preserves the anchor's time of day, so a task due
    /// at 09:00 recurs at 09:00 rather than at midnight.
    private func candidates(step: Int, anchor: Date, calendar: Calendar) -> [Date] {
        switch frequency {
        case .daily:
            guard let date = calendar.date(byAdding: .day, value: step * interval, to: anchor) else { return [] }
            return [date]
        case .monthly:
            // `byAdding: .month` clamps rather than skipping - the 31st of a
            // 30-day month lands on the 30th. That is the behaviour a task
            // wants ("month-end review" should not skip February), and it is
            // stated here because the alternative is what a strict RFC 5545
            // reader would expect.
            guard let date = calendar.date(byAdding: .month, value: step * interval, to: anchor) else { return [] }
            return [date]
        case .weekly:
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: step * interval,
                                                to: anchor) else { return [] }
            guard !weekdays.isEmpty else { return [weekStart] }
            // Walk the seven days of the week `weekStart` lands in, keeping
            // the selected ones. Anchored on the week's own first day rather
            // than on `weekStart` itself, or a Friday anchor would never
            // produce that week's Monday.
            let anchorWeekday = calendar.component(.weekday, from: weekStart)
            let firstWeekday = calendar.firstWeekday
            var offsetToWeekStart = anchorWeekday - firstWeekday
            if offsetToWeekStart < 0 { offsetToWeekStart += 7 }
            guard let start = calendar.date(byAdding: .day, value: -offsetToWeekStart, to: weekStart) else { return [] }
            return (0..<7).compactMap { day -> Date? in
                guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
                return weekdays.contains(calendar.component(.weekday, from: date)) ? date : nil
            }
        }
    }

    // MARK: Presentation

    /// The one-line description shown on the editor's Repeat card, on a task
    /// row's repeat chip and in the calendar's own rule panel. One
    /// derivation, so those three can never word the same rule differently.
    var displayName: String {
        let rule = normalized
        let base: String
        switch rule.frequency {
        case .daily:
            base = rule.interval == 1 ? "Every day" : "Every \(rule.interval) days"
        case .weekly:
            if rule.weekdays == Self.weekdaySet && rule.interval == 1 {
                base = "Every weekday"
            } else if rule.weekdays.isEmpty {
                base = rule.interval == 1 ? "Every week" : "Every \(rule.interval) weeks"
            } else {
                let names = rule.weekdays.sorted().map { Self.shortWeekdayName($0) }.joined(separator: ", ")
                base = rule.interval == 1 ? "Every \(names)" : "Every \(rule.interval) weeks on \(names)"
            }
        case .monthly:
            base = rule.interval == 1 ? "Every month" : "Every \(rule.interval) months"
        }
        if let count = rule.count { return "\(base), \(count) times" }
        if let until = rule.until { return "\(base), until \(ShiftDateFormatting.friendly(until))" }
        return base
    }

    /// "Mon", "Tue" … in the captain's own locale, for `displayName`.
    static func shortWeekdayName(_ weekday: Int) -> String {
        let symbols = DateFormatter().shortWeekdaySymbols ?? weekdayCodes
        guard (1...symbols.count).contains(weekday) else { return weekdayCodes[max(0, min(6, weekday - 1))] }
        return symbols[weekday - 1]
    }

    // MARK: The editor's presets

    /// What the Repeat card offers. Deliberately a short list of named rules
    /// rather than a frequency picker plus an interval stepper: the mockup
    /// the captain reviewed shows one popup reading "Every weekday", and
    /// five presets cover every recurrence this app's own task data has ever
    /// carried. The weekday chips underneath are the one escape hatch, and
    /// they refine the weekly presets rather than replacing the list.
    static let presets: [(title: String, rule: ShiftRecurrence?)] = [
        ("Does not repeat", nil),
        ("Every day", ShiftRecurrence(frequency: .daily)),
        ("Every weekday", ShiftRecurrence(frequency: .weekly, weekdays: weekdaySet)),
        ("Every week", ShiftRecurrence(frequency: .weekly)),
        ("Every 2 weeks", ShiftRecurrence(frequency: .weekly, interval: 2)),
        ("Every month", ShiftRecurrence(frequency: .monthly)),
    ]
}

/// How far ahead of a task's due time its reminder fires.
///
/// A fixed list rather than a free number field: this is one popup on a form
/// card, the values are the ones a person actually picks, and a stored
/// integer that no control can produce is a state the editor cannot show.
/// The stored value is plain minutes, so a hand-edited `45` still works -
/// `ShiftReminderOffset.label(for:)` names an unlisted value rather than
/// discarding it.
enum ShiftReminderOffset {

    /// Minutes before the due time, in the order the menu lists them.
    static let choices: [Int] = [0, 5, 15, 30, 60, 120, 1440]

    static func label(for minutes: Int) -> String {
        switch minutes {
        case 0: return "At the due time"
        case 1: return "1 minute before"
        case 60: return "1 hour before"
        case 120: return "2 hours before"
        case 1440: return "1 day before"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440) days before" }
            if minutes % 60 == 0 { return "\(minutes / 60) hours before" }
            return "\(minutes) minutes before"
        }
    }
}
