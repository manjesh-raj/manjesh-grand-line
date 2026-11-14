// Grand Line - native macOS app.
//
// RRULE-lite recurrence for `ShiftTask` (F5 of full review #3 §8 - see
// `docs/history/34-recurrence-and-calendar.md`).
//
// **Why "lite" rather than RFC 5545.** The report asked for `RRULE`-lite and
// this takes that literally: four frequencies, an interval, a weekday set,
// a day-of-month or "2nd Friday" set for monthly rules, skipped dates, and
// two ways to stop. `BYSETPOS`, `BYYEARDAY`, `BYMONTH`, `WKST` and the whole
// `VEVENT` envelope are deliberately absent. Nothing in this app reads or
// writes a real `.ics` file, so a full parser would be code with no second
// reader - and the one thing a full parser buys (interoperability) is exactly
// what is not being asked for.
//
// **A component this build does not model is carried, never dropped.** The
// whole rule is one value under one key, so the task-level
// `ShiftYamlPassthrough` cannot help: a rule rewritten from this struct alone
// would silently lose anything a newer build added to the line, which is the
// "a write that loses something" shape AGENTS.md describes under GL-01. So
// `parse` keeps every component it cannot interpret in `carried`, verbatim
// and in file order, and `ruleText` writes them back after its own. That
// includes a known key whose value this build cannot read for the rule's
// frequency (a plain `BYDAY=MO` on a monthly rule, say): it is kept as text
// rather than half-applied.
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
    case yearly = "YEARLY"
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
    /// `BYMONTHDAY`: days of the month, `1...31`, or `-1...-31` counted from
    /// the month's end (`-1` is the last day). Monthly only. Empty means "the
    /// anchor's own day of the month", the same way an empty weekly `BYDAY`
    /// means the anchor's own weekday.
    var monthDays: Set<Int>
    /// Ordinal `BYDAY` entries ("2FR", "-1MO"). Monthly only. With
    /// `monthDays` as well, a date must match both, as RFC 5545 has it - which
    /// is how "Friday the 13th" is written.
    var monthWeekdays: Set<ShiftRecurrenceMonthWeekday>
    /// `EXDATE`: "YYYY-MM-DD" days the rule would produce but skips. A skipped
    /// date still counts toward `COUNT` (RFC 5545 applies `EXDATE` after
    /// `COUNT`), which is what makes skipping one occurrence of a
    /// ten-times rule leave nine rather than shift the tenth a slot later.
    var exceptionDates: Set<String>
    /// Components this build does not model, as written ("BYSETPOS=2"), in
    /// the order the file had them. See this file's header.
    var carried: [String]

    init(frequency: ShiftRecurrenceFrequency, interval: Int = 1, weekdays: Set<Int> = [],
         until: String? = nil, count: Int? = nil, monthDays: Set<Int> = [],
         monthWeekdays: Set<ShiftRecurrenceMonthWeekday> = [], exceptionDates: Set<String> = [],
         carried: [String] = []) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.until = until
        self.count = count
        self.monthDays = monthDays
        self.monthWeekdays = monthWeekdays
        self.exceptionDates = exceptionDates
        self.carried = carried
    }

    /// The rule with every field forced into range. Every generator below
    /// starts here, so a rule that arrived from a hand-edited YAML file (or
    /// from a git pull of a file another machine wrote) cannot drive the
    /// expansion loop out of bounds.
    var normalized: ShiftRecurrence {
        var copy = self
        copy.interval = max(1, interval)
        copy.weekdays = frequency == .weekly ? weekdays.filter { (1...7).contains($0) } : []
        copy.monthDays = frequency == .monthly ? monthDays.filter(Self.isValidMonthDay) : []
        copy.monthWeekdays = frequency == .monthly ? monthWeekdays.filter(\.isValid) : []
        if let count, count < 1 { copy.count = 1 }
        return copy
    }

    /// The same rule without the skipped dates before `day` ("YYYY-MM-DD").
    ///
    /// GL-35: `EXDATE` only ever grows as dates are skipped, so the instance
    /// `ShiftStore.nextOccurrence` writes drops the ones its own walk can no
    /// longer reach. A date compares as a string because the format is
    /// fixed-width; a value in any other shape is kept, not guessed at.
    func prunedExceptionDates(before day: String) -> ShiftRecurrence {
        var copy = self
        copy.exceptionDates = exceptionDates.filter { date in
            !(ShiftRecurrence.isDayString(date) && date < day)
        }
        return copy
    }

    // MARK: B24 - COUNT across instances

    /// The same rule with no `COUNT`, so a walk terminates only on `UNTIL`.
    ///
    /// B24: `COUNT` is consumed **per instance actually created**, not per
    /// calendar slot that elapsed. `ShiftStore` enforces it with
    /// `afterOneOccurrence` below, and asks the walk itself for a date using
    /// this - otherwise a task that went 8 days unnoticed would have its
    /// remaining occurrences eaten by the days it was missed.
    var withoutCount: ShiftRecurrence {
        var copy = self
        copy.count = nil
        return copy
    }

    /// The rule the **next** instance should carry, or `nil` when this
    /// instance was the last one.
    ///
    /// B24: `ShiftStore.nextOccurrence` asked the rule for "the occurrence
    /// after this task's due date, anchored at this task's due date" - and
    /// every spawned instance has its own due date, so `COUNT`'s walk
    /// restarted from 1 on every completion and a `COUNT=3` series repeated
    /// for ever. Carrying the *remaining* count on the instance is what makes
    /// the budget survive the hop from one task to the next; there is no
    /// stored series to hold it in (see `ShiftStore.nextOccurrence`'s own
    /// header for why).
    ///
    /// `COUNT` includes the anchor (RFC 5545), so an instance carrying
    /// `COUNT=1` is the last one and spawns nothing.
    var afterOneOccurrence: ShiftRecurrence? {
        let rule = normalized
        guard let count = rule.count else { return rule }
        guard count > 1 else { return nil }
        var copy = rule
        copy.count = count - 1
        return copy
    }

    // MARK: Serialization

    /// The RRULE-lite string written under the task's `recurrence` key. Key
    /// order is fixed (never a dictionary's) so an unchanged rule round-trips
    /// to a byte-identical line and a git-synced file shows no diff for a
    /// save that changed nothing.
    ///
    /// The order is FREQ, INTERVAL, BYDAY, BYMONTHDAY, UNTIL, COUNT, EXDATE,
    /// then the carried components. `EXDATE` sits last of this build's own
    /// because it is the one that grows.
    var ruleText: String {
        let rule = normalized
        var parts = ["FREQ=\(rule.frequency.rawValue)"]
        parts.append("INTERVAL=\(rule.interval)")
        if !rule.weekdays.isEmpty {
            let codes = rule.weekdays.sorted().map { Self.weekdayCodes[$0 - 1] }
            parts.append("BYDAY=\(codes.joined(separator: ","))")
        }
        if !rule.monthWeekdays.isEmpty {
            let codes = rule.monthWeekdays.sorted(by: ShiftRecurrenceMonthWeekday.inRuleOrder).map(\.code)
            parts.append("BYDAY=\(codes.joined(separator: ","))")
        }
        if !rule.monthDays.isEmpty {
            let days = rule.monthDays.sorted { Self.ordinalOrder($0) < Self.ordinalOrder($1) }
            parts.append("BYMONTHDAY=\(days.map(String.init).joined(separator: ","))")
        }
        if let until = rule.until { parts.append("UNTIL=\(until)") }
        if let count = rule.count { parts.append("COUNT=\(count)") }
        if !rule.exceptionDates.isEmpty {
            parts.append("EXDATE=\(rule.exceptionDates.sorted().joined(separator: ","))")
        }
        parts.append(contentsOf: rule.carried)
        return parts.joined(separator: ";")
    }

    /// Parses `ruleText`'s form back. Returns `nil` for anything without a
    /// frequency this app understands - an empty string, a blank key, or a
    /// real RFC 5545 rule with `FREQ=HOURLY` - rather than guessing, because
    /// a rule quietly downgraded to "daily" would fire a task every morning
    /// forever.
    ///
    /// Any other component this build cannot interpret goes into `carried`
    /// and is written back unchanged (this file's header). It is not applied:
    /// the rule expands as if it were absent, which is what every earlier
    /// build already did with it.
    static func parse(_ text: String) -> ShiftRecurrence? {
        let components: [(key: String, value: String, raw: String)] = text.split(separator: ";").compactMap { part in
            let raw = part.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            let pair = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = pair.count == 2 ? pair[1].trimmingCharacters(in: .whitespaces) : ""
            return (key, value, raw)
        }
        // `FREQ` first, because what `BYDAY` and `BYMONTHDAY` mean depends on
        // it and nothing says it is written before them.
        guard let freqValue = components.first(where: { $0.key == "FREQ" })?.value,
              let frequency = ShiftRecurrenceFrequency(rawValue: freqValue.uppercased()) else { return nil }

        var rule = ShiftRecurrence(frequency: frequency)
        var sawFrequency = false
        for component in components {
            if component.key == "FREQ" && !sawFrequency {
                sawFrequency = true
            } else if !rule.apply(key: component.key, value: component.value) {
                rule.carried.append(component.raw)
            }
        }
        return rule.normalized
    }

    /// Applies one component this build models, or returns `false` so the
    /// caller carries it verbatim. A second `FREQ` is never applied.
    private mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "INTERVAL":
            interval = Int(value) ?? 1
        case "BYDAY" where frequency == .weekly:
            guard let days = Self.parseWeekdays(value) else { return false }
            weekdays.formUnion(days)
        case "BYDAY" where frequency == .monthly:
            guard let positions = Self.parseMonthWeekdays(value) else { return false }
            monthWeekdays.formUnion(positions)
        case "BYMONTHDAY" where frequency == .monthly:
            let days = value.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !days.isEmpty, days.allSatisfy({ $0.map(Self.isValidMonthDay) ?? false }) else { return false }
            monthDays.formUnion(days.compactMap { $0 })
        case "UNTIL":
            until = value.isEmpty ? nil : value
        case "COUNT":
            count = Int(value)
        case "EXDATE":
            for date in value.split(separator: ",") {
                let day = date.trimmingCharacters(in: .whitespaces)
                if !day.isEmpty { exceptionDates.insert(day) }
            }
        default:
            return false
        }
        return true
    }

    /// A plain weekly `BYDAY` list ("MO,WE,FR"), or `nil` when any entry is
    /// not a bare two-letter code - so a value this build cannot read whole
    /// is carried whole rather than half-applied.
    private static func parseWeekdays(_ value: String) -> Set<Int>? {
        var days: Set<Int> = []
        for code in value.uppercased().split(separator: ",") {
            guard let index = weekdayCodes.firstIndex(of: code.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            days.insert(index + 1)
        }
        return days.isEmpty ? nil : days
    }

    /// A monthly ordinal `BYDAY` list ("2FR,-1MO"), or `nil` under the same
    /// all-or-nothing rule as `parseWeekdays`.
    private static func parseMonthWeekdays(_ value: String) -> Set<ShiftRecurrenceMonthWeekday>? {
        var positions: Set<ShiftRecurrenceMonthWeekday> = []
        for entry in value.uppercased().split(separator: ",") {
            guard let position = ShiftRecurrenceMonthWeekday(code: entry.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            positions.insert(position)
        }
        return positions.isEmpty ? nil : positions
    }

    private static func isValidMonthDay(_ day: Int) -> Bool {
        (1...31).contains(abs(day))
    }

    /// Positive ordinals first and ascending, then negative ones from `-1`,
    /// so "the 1st, the 15th and the last day" reads in that order.
    fileprivate static func ordinalOrder(_ n: Int) -> Int {
        n > 0 ? n : 100 - n
    }

    /// "YYYY-MM-DD" and nothing else.
    static func isDayString(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.map(\.count) == [4, 2, 2]
            && parts.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) } }
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
                // After `COUNT`, so a skipped date still spends its slot.
                if !rule.exceptionDates.isEmpty,
                   rule.exceptionDates.contains(Self.dayString(date, calendar: calendar)) { continue }
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

    /// `date`'s own day as "YYYY-MM-DD" in the caller's calendar - the form
    /// `EXDATE` stores - for the same reason `endExclusive` avoids the
    /// machine-local formatter.
    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The dates this rule produces at one step of the walk - a single date
    /// for daily/yearly and a plain monthly rule, a whole week's selected
    /// days for weekly, and a whole month's matching days for a monthly rule
    /// with `BYMONTHDAY` or an ordinal `BYDAY`. Always in ascending order.
    ///
    /// Every returned slot preserves the anchor's time of day, so a task due
    /// at 09:00 recurs at 09:00 rather than at midnight.
    private func candidates(step: Int, anchor: Date, calendar: Calendar) -> [Date] {
        switch frequency {
        case .daily:
            guard let date = calendar.date(byAdding: .day, value: step * interval, to: anchor) else { return [] }
            return [date]
        case .monthly:
            guard monthDays.isEmpty && monthWeekdays.isEmpty else {
                return monthCandidates(step: step, anchor: anchor, calendar: calendar)
            }
            // `byAdding: .month` clamps rather than skipping - the 31st of a
            // 30-day month lands on the 30th. That is the behaviour a task
            // wants ("month-end review" should not skip February), and it is
            // stated here because the alternative is what a strict RFC 5545
            // reader would expect.
            guard let date = calendar.date(byAdding: .month, value: step * interval, to: anchor) else { return [] }
            return [date]
        case .yearly:
            // The anchor's own month and day, clamped the same way the plain
            // monthly rule is: a 29 February anchor lands on the 28th in a
            // common year rather than skipping three years in four.
            guard let date = calendar.date(byAdding: .year, value: step * interval, to: anchor) else { return [] }
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

    /// The matching days of one month for a monthly rule with `BYMONTHDAY`
    /// and/or an ordinal `BYDAY`, at the anchor's time of day.
    ///
    /// Unlike the plain monthly rule this **skips** a month the day does not
    /// exist in, as RFC 5545 does: `BYMONTHDAY=31` is "the 31st", and a
    /// month-end rule is written `BYMONTHDAY=-1`, which every month has. A
    /// "5th Friday" likewise only lands in months that have one.
    private func monthCandidates(step: Int, anchor: Date, calendar: Calendar) -> [Date] {
        var monthStart = calendar.dateComponents([.year, .month], from: anchor)
        monthStart.day = 1
        guard let anchorMonth = calendar.date(from: monthStart),
              let month = calendar.date(byAdding: .month, value: step * interval, to: anchorMonth),
              let length = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let time = calendar.dateComponents([.hour, .minute, .second], from: anchor)
        let monthParts = calendar.dateComponents([.year, .month], from: month)

        func resolve(_ n: Int) -> Int? {
            let day = n > 0 ? n : length + n + 1
            return (1...length).contains(day) ? day : nil
        }
        let byMonthDay = Set(monthDays.compactMap(resolve))

        var byWeekday: Set<Int> = []
        if !monthWeekdays.isEmpty {
            let firstWeekday = calendar.component(.weekday, from: month)
            for position in monthWeekdays {
                // The first day of the month that falls on this weekday, then
                // whole weeks forward (or back from the last such day).
                let first = (position.weekday - firstWeekday + 7) % 7 + 1
                let all = Array(stride(from: first, through: length, by: 7))
                let index = position.ordinal > 0 ? position.ordinal - 1 : all.count + position.ordinal
                if all.indices.contains(index) { byWeekday.insert(all[index]) }
            }
        }

        let days: Set<Int>
        switch (monthDays.isEmpty, monthWeekdays.isEmpty) {
        case (false, false): days = byMonthDay.intersection(byWeekday)
        case (false, true): days = byMonthDay
        default: days = byWeekday
        }
        return days.sorted().compactMap { day in
            var parts = monthParts
            parts.day = day
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
            return calendar.date(from: parts)
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
            let every = rule.interval == 1 ? "Every month" : "Every \(rule.interval) months"
            if let on = Self.monthlyOnText(rule) {
                base = "\(every) on \(on)"
            } else {
                base = every
            }
        case .yearly:
            base = rule.interval == 1 ? "Every year" : "Every \(rule.interval) years"
        }
        if let count = rule.count { return "\(base), \(count) times" }
        if let until = rule.until { return "\(base), until \(ShiftDateFormatting.friendly(until))" }
        return base
    }

    /// "day 13", "the last day", "the 2nd Friday" - or `nil` for a plain
    /// monthly rule. Several entries are joined with "and" in rule order.
    private static func monthlyOnText(_ rule: ShiftRecurrence) -> String? {
        var parts: [String] = []
        for day in rule.monthDays.sorted(by: { ordinalOrder($0) < ordinalOrder($1) }) {
            switch day {
            case -1: parts.append("the last day")
            case ..<0: parts.append("\(-day) days before the end")
            default: parts.append("day \(day)")
            }
        }
        for position in rule.monthWeekdays.sorted(by: ShiftRecurrenceMonthWeekday.inRuleOrder) {
            parts.append("the \(position.ordinalName) \(longWeekdayName(position.weekday))")
        }
        guard !parts.isEmpty else { return nil }
        // Both kinds at once is an intersection ("Friday the 13th"), so it
        // is not worded as a list of alternatives.
        if !rule.monthDays.isEmpty && !rule.monthWeekdays.isEmpty {
            return parts.joined(separator: " that is ")
        }
        return parts.joined(separator: " and ")
    }

    /// "Monday", "Tuesday" … in the captain's own locale.
    static func longWeekdayName(_ weekday: Int) -> String {
        let symbols = DateFormatter().weekdaySymbols ?? weekdayCodes
        guard (1...symbols.count).contains(weekday) else { return weekdayCodes[max(0, min(6, weekday - 1))] }
        return symbols[weekday - 1]
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

/// One ordinal `BYDAY` entry of a monthly rule: "the 2nd Friday" is
/// `ordinal: 2, weekday: 6`, "the last Monday" is `ordinal: -1, weekday: 2`.
/// `weekday` uses `Calendar`'s numbering, like `ShiftRecurrence.weekdays`.
struct ShiftRecurrenceMonthWeekday: Hashable {
    var ordinal: Int
    var weekday: Int

    init(ordinal: Int, weekday: Int) {
        self.ordinal = ordinal
        self.weekday = weekday
    }

    /// "2FR", "+2FR" or "-1MO". `nil` for a bare "FR", which is not an
    /// ordinal entry, and for an ordinal no month can have.
    init?(code: String) {
        let upper = code.uppercased()
        guard upper.count > 2 else { return nil }
        let dayCode = String(upper.suffix(2))
        guard let index = ShiftRecurrence.weekdayCodes.firstIndex(of: dayCode),
              let ordinal = Int(upper.dropLast(2)) else { return nil }
        self.init(ordinal: ordinal, weekday: index + 1)
        guard isValid else { return nil }
    }

    /// A month holds at most five of any weekday.
    var isValid: Bool {
        (1...5).contains(abs(ordinal)) && (1...7).contains(weekday)
    }

    var code: String {
        "\(ordinal)\(ShiftRecurrence.weekdayCodes[weekday - 1])"
    }

    /// "1st" … "5th", and "last" / "2nd to last" for the negative ones.
    var ordinalName: String {
        if ordinal == -1 { return "last" }
        if ordinal < 0 { return "\(Self.ordinalSuffixed(-ordinal)) to last" }
        return Self.ordinalSuffixed(ordinal)
    }

    private static func ordinalSuffixed(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    /// The order `ruleText` writes them in, so one set always serialises to
    /// one byte-identical line.
    static func inRuleOrder(_ a: Self, _ b: Self) -> Bool {
        let (oa, ob) = (ShiftRecurrence.ordinalOrder(a.ordinal), ShiftRecurrence.ordinalOrder(b.ordinal))
        return oa != ob ? oa < ob : a.weekday < b.weekday
    }
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
