// Grand Line - native macOS app.
//
// The When panel's model (tasks-calendar plan PR 5): what
// `ShiftScheduleEditor` edits, and the one mapping between its controls and a
// task's `dueDate`, `dueTime`, `recurrence` and `reminderMinutesBefore`.
//
// **Why a draft rather than the rule itself.** The panel's rows are not the
// rule's fields. "Every weekday" is a weekly rule with five days, "Custom" is
// any rule with its unit unlocked, and the monthly row offers "Day 13", "The
// 2nd Friday" and "The last day", which are three different components. A
// draft holds what the captain picked, so a weekday circle clicked under
// "Every weekday" can become "Weekly on chosen days" without the rule having
// an opinion, and so switching Custom's unit from week to day and back keeps
// the days that were picked.
//
// **An unchanged rule writes back byte-identical.** `init(task:)` keeps every
// part of a rule the panel can show in the form the file had it: an empty
// weekly `BYDAY` stays empty (it means the due date's own weekday), a plain
// monthly rule stays plain, an explicit `BYMONTHDAY=13` stays explicit, and
// `EXDATE` rides along untouched. So opening the panel and pressing Done on a
// task changes nothing in its YAML.
//
// **A rule the panel cannot show is kept whole.** Two ends at once, several
// month days, a carried component from a newer build: the Repeat menu reads
// "Custom rule" and the rule is written back unchanged unless the captain
// picks another. The same "a write that loses something" shape AGENTS.md
// describes under GL-01, one level up from `ShiftRecurrence.carried`.
//
// **A rule needs a date.** Choosing a repeat with no date picks today as the
// start, so Repeat is never greyed out (the plan's decision), and "No date"
// takes the rule and the reminder with it, because a rule with no anchor
// recurs zero times.

import Foundation

struct ShiftScheduleDraft: Equatable {

    /// The Repeat menu, in its order.
    enum Repeat: String, CaseIterable {
        case none, daily, weekdays, weekly, monthly, yearly, custom
        /// A rule this panel cannot show. Only reachable from `init(task:)`.
        case customRule

        var title: String {
            switch self {
            case .none: return "Does not repeat"
            case .daily: return "Every day"
            case .weekdays: return "Every weekday"
            case .weekly: return "Weekly on chosen days"
            case .monthly: return "Monthly"
            case .yearly: return "Every year"
            case .custom: return "Custom\u{2026}"
            case .customRule: return "Custom rule"
            }
        }

        /// What the menu offers: every case but `customRule`, which is added
        /// only while the panel holds such a rule.
        static let menu: [Repeat] = [.none, .daily, .weekdays, .weekly, .monthly, .yearly, .custom]
    }

    /// Custom's unit.
    enum Unit: String, CaseIterable {
        case day, week, month, year

        var frequency: ShiftRecurrenceFrequency {
            switch self {
            case .day: return .daily
            case .week: return .weekly
            case .month: return .monthly
            case .year: return .yearly
            }
        }

        init(_ frequency: ShiftRecurrenceFrequency) {
            switch frequency {
            case .daily: self = .day
            case .weekly: self = .week
            case .monthly: self = .month
            case .yearly: self = .year
            }
        }

        func title(plural: Bool) -> String { plural ? "\(rawValue)s" : rawValue }
    }

    /// The monthly row.
    enum MonthlyMode: String, CaseIterable {
        /// "Day 13 of the month". Plain (the due date's own day) unless the
        /// rule named a day explicitly (`monthDay`).
        case dayOfMonth
        /// "The 2nd Friday".
        case weekdayOfMonth
        /// "The last day" (`BYMONTHDAY=-1`).
        case lastDay
    }

    /// The Ends row.
    enum End: String, CaseIterable {
        case never, onDate, afterCount

        var title: String {
            switch self {
            case .never: return "Never"
            case .onDate: return "On a date"
            case .afterCount: return "After"
            }
        }
    }

    /// The due date, "YYYY-MM-DD", or `nil` for no date.
    var day: String?
    /// "HH:MM", or `nil` for all day.
    var time: String?
    var repeatKind: Repeat = .none
    /// Every `interval` units. Always 1 for the named presets: stepping it
    /// turns the rule into Custom, as the mockup does.
    var interval: Int = 1
    var unit: Unit = .week
    /// `Calendar` weekday numbers. Empty means the due date's own weekday,
    /// which is how a plain "every week" rule is written (and how it stays).
    var weekdays: Set<Int> = []
    var monthlyMode: MonthlyMode = .dayOfMonth
    /// An explicit `BYMONTHDAY` for `.dayOfMonth`, as the file had it. `nil`
    /// is the plain monthly rule, which follows the due date.
    var monthDay: Int?
    /// An explicit ordinal `BYDAY` for `.weekdayOfMonth`. `nil` derives it
    /// from the due date when the rule is written.
    var monthWeekday: ShiftRecurrenceMonthWeekday?
    var end: End = .never
    var until: String?
    var count: Int = 10
    /// `EXDATE`, carried through every edit. Skipping is PR 6's; this panel
    /// only keeps what is there.
    var exceptionDates: Set<String> = []
    var reminderMinutes: Int?
    /// The rule this panel could not show, kept for `.customRule`.
    var customRule: ShiftRecurrence?

    static let countRange = 1...999
    static let intervalRange = 1...99

    init(day: String? = nil, time: String? = nil, recurrence: ShiftRecurrence? = nil,
         reminderMinutes: Int? = nil) {
        self.day = day
        self.time = time
        self.reminderMinutes = reminderMinutes
        guard let recurrence else { return }
        if !adopt(recurrence.normalized) {
            repeatKind = .customRule
            customRule = recurrence.normalized
        }
    }

    init(task: ShiftTask) {
        self.init(day: task.dueDate, time: task.dueTime, recurrence: task.recurrence,
                  reminderMinutes: task.reminderMinutesBefore)
    }

    /// Reads a rule into the panel's rows, or returns `false` when the panel
    /// cannot show it.
    private mutating func adopt(_ rule: ShiftRecurrence) -> Bool {
        guard rule.carried.isEmpty, !(rule.until != nil && rule.count != nil) else { return false }
        switch rule.frequency {
        case .monthly:
            switch (rule.monthDays.count, rule.monthWeekdays.count) {
            case (0, 0):
                monthlyMode = .dayOfMonth
            case (1, 0) where rule.monthDays.first == -1:
                monthlyMode = .lastDay
            case (1, 0) where rule.monthDays.first.map { $0 > 0 } == true:
                monthlyMode = .dayOfMonth
                monthDay = rule.monthDays.first
            case (0, 1):
                monthlyMode = .weekdayOfMonth
                monthWeekday = rule.monthWeekdays.first
            default:
                return false
            }
        case .weekly:
            weekdays = rule.weekdays
        case .daily, .yearly:
            break
        }

        unit = Unit(rule.frequency)
        interval = rule.interval
        if rule.interval != 1 {
            repeatKind = .custom
        } else {
            switch rule.frequency {
            case .daily: repeatKind = .daily
            case .weekly: repeatKind = rule.weekdays == ShiftRecurrence.weekdaySet ? .weekdays : .weekly
            case .monthly: repeatKind = .monthly
            case .yearly: repeatKind = .yearly
            }
        }

        if let until = rule.until {
            end = .onDate
            self.until = until
        } else if let count = rule.count {
            end = .afterCount
            self.count = count
        }
        exceptionDates = rule.exceptionDates
        return true
    }

    // MARK: The rule

    /// The unit the rule is in, whichever row chose it.
    var effectiveUnit: Unit? {
        switch repeatKind {
        case .none, .customRule: return nil
        case .daily: return .day
        case .weekdays, .weekly: return .week
        case .monthly: return .month
        case .yearly: return .year
        case .custom: return unit
        }
    }

    /// The rule these rows describe, or `nil` for "Does not repeat" and for
    /// a task with no date.
    var recurrence: ShiftRecurrence? {
        guard let day else { return nil }
        if repeatKind == .customRule { return customRule }
        guard let unit = effectiveUnit else { return nil }
        var rule = ShiftRecurrence(frequency: unit.frequency,
                                   interval: repeatKind == .custom ? interval : 1)
        switch unit {
        case .week:
            rule.weekdays = repeatKind == .weekdays ? ShiftRecurrence.weekdaySet : weekdays
        case .month:
            switch monthlyMode {
            case .dayOfMonth:
                if let monthDay { rule.monthDays = [monthDay] }
            case .weekdayOfMonth:
                if let position = monthWeekday ?? Self.monthPosition(of: day) {
                    rule.monthWeekdays = [position]
                }
            case .lastDay:
                rule.monthDays = [-1]
            }
        case .day, .year:
            break
        }
        switch end {
        case .never: break
        case .onDate: rule.until = until ?? Self.defaultUntil(after: day)
        case .afterCount: rule.count = count
        }
        rule.exceptionDates = exceptionDates
        return rule.normalized
    }

    /// The task with this schedule written into it.
    ///
    /// Two more things than the four fields:
    ///
    ///   - A rule set for the first time mints the series id (the plan's
    ///     data model: "minted when a rule is first set, copied on every
    ///     spawn"), so the instances it spawns can be read back as one series.
    ///   - A new date or a new rule clears `occurrence`. That key pins the
    ///     instance to an earlier rule slot after a move "only this", and an
    ///     edit here applies to the series from this instance on, so walking
    ///     the new rule from the old slot would put the next date in the
    ///     wrong place.
    func applied(to task: ShiftTask) -> ShiftTask {
        var out = task
        out.dueDate = day
        out.dueTime = day == nil ? nil : time
        out.recurrence = recurrence
        out.reminderMinutesBefore = day == nil ? nil : reminderMinutes
        if out.recurrence != nil, out.seriesID == nil {
            out.seriesID = UUID().uuidString
        }
        if out.dueDate != task.dueDate || out.recurrence != task.recurrence {
            out.occurrence = nil
        }
        return out
    }

    /// Whether `applied(to:)` would change anything the panel shows.
    func changes(_ task: ShiftTask) -> Bool {
        let out = applied(to: task)
        return out.dueDate != task.dueDate || out.dueTime != task.dueTime
            || out.recurrence != task.recurrence || out.reminderMinutesBefore != task.reminderMinutesBefore
    }

    // MARK: Edits
    //
    // Each control's action, as one mutation, so the sheet, the popover and a
    // suite drive the same rules.

    /// The date row: a picked day, a quick chip, or `nil` for "No date".
    ///
    /// A rule part that only echoed the old date follows the new one: a
    /// weekly rule on the old date's weekday alone, and a monthly "2nd
    /// Friday" or "day 13" that was the old date's own. Anything the captain
    /// set apart from the date stays.
    mutating func setDay(_ newDay: String?) {
        guard newDay != day else { return }
        let old = day
        day = newDay
        guard let newDay else {
            repeatKind = .none
            reminderMinutes = nil
            return
        }
        guard let old else { return }
        if let oldWeekday = Self.weekday(of: old), weekdays == [oldWeekday],
           let newWeekday = Self.weekday(of: newDay) {
            weekdays = [newWeekday]
        }
        if let position = monthWeekday, position == Self.monthPosition(of: old) {
            monthWeekday = nil
        }
        if let explicit = monthDay, explicit == Self.dayOfMonth(old) {
            monthDay = nil
        }
        if let until, until < newDay { self.until = newDay }
    }

    /// The Repeat menu. A rule with no date starts today.
    mutating func setRepeat(_ kind: Repeat, today: String) {
        guard kind != repeatKind else { return }
        if kind == .customRule && customRule == nil { return }
        if kind != .none && day == nil { day = today }
        let previousUnit = effectiveUnit
        repeatKind = kind
        if kind != .custom { interval = 1 }
        switch kind {
        case .weekly:
            // The days already picked under another weekly row stay lit.
            // Otherwise the circles start on the due date's own weekday.
            if previousUnit != .week || weekdays.isEmpty {
                weekdays = day.flatMap { Self.weekday(of: $0) }.map { [$0] } ?? []
            }
        case .weekdays:
            weekdays = ShiftRecurrence.weekdaySet
        case .custom:
            unit = previousUnit ?? .week
            if unit == .week, weekdays.isEmpty, let day, let weekday = Self.weekday(of: day) {
                weekdays = [weekday]
            }
        default:
            break
        }
    }

    /// One weekday circle. The last selected day cannot be cleared, because
    /// a weekly rule with no days means "the due date's weekday", which is
    /// not what clearing the last circle asks for. A circle under "Every
    /// weekday" turns the rule into "Weekly on chosen days", as the mockup
    /// does.
    mutating func toggleWeekday(_ weekday: Int) {
        guard (1...7).contains(weekday), effectiveUnit == .week else { return }
        if repeatKind == .weekdays { repeatKind = .weekly }
        var days = displayedWeekdays
        if days.contains(weekday) {
            guard days.count > 1 else { return }
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        weekdays = days
        // Five weekdays picked one by one is the named rule, so the menu
        // says what the rule is.
        if repeatKind == .weekly && weekdays == ShiftRecurrence.weekdaySet { repeatKind = .weekdays }
    }

    /// The Every row's stepper. Stepping a named preset makes it Custom in
    /// the same unit.
    mutating func stepInterval(by delta: Int) {
        guard let current = effectiveUnit, repeatKind != .weekdays, repeatKind != .yearly else { return }
        let next = min(Self.intervalRange.upperBound, max(Self.intervalRange.lowerBound,
                                                          (repeatKind == .custom ? interval : 1) + delta))
        if repeatKind != .custom {
            guard next != 1 else { return }
            if current == .week, weekdays.isEmpty, let day, let weekday = Self.weekday(of: day) {
                weekdays = [weekday]
            }
            repeatKind = .custom
            unit = current
        }
        interval = next
    }

    /// Custom's unit popup.
    mutating func setUnit(_ newUnit: Unit) {
        guard repeatKind == .custom else { return }
        unit = newUnit
        if newUnit == .week, weekdays.isEmpty, let day, let weekday = Self.weekday(of: day) {
            weekdays = [weekday]
        }
    }

    mutating func setMonthlyMode(_ mode: MonthlyMode) {
        monthlyMode = mode
        monthDay = nil
        monthWeekday = nil
    }

    mutating func setEnd(_ newEnd: End) {
        end = newEnd
        if newEnd == .onDate, until == nil, let day { until = Self.defaultUntil(after: day) }
    }

    mutating func setUntil(_ newUntil: String) {
        until = day.map { max($0, newUntil) } ?? newUntil
    }

    mutating func stepCount(by delta: Int) {
        count = min(Self.countRange.upperBound, max(Self.countRange.lowerBound, count + delta))
    }

    // MARK: What the rows show

    /// The circles that are lit: the rule's days, or the due date's own
    /// weekday for a weekly rule written without any.
    var displayedWeekdays: Set<Int> {
        if repeatKind == .weekdays { return ShiftRecurrence.weekdaySet }
        if !weekdays.isEmpty { return weekdays }
        guard let day, let weekday = Self.weekday(of: day) else { return [] }
        return [weekday]
    }

    /// The monthly row's three labels, from the due date.
    func monthlyTitle(_ mode: MonthlyMode) -> String {
        switch mode {
        case .dayOfMonth:
            let n = monthDay ?? day.flatMap(Self.dayOfMonth) ?? 1
            return "Day \(n) of the month"
        case .weekdayOfMonth:
            guard let position = monthWeekday ?? day.flatMap({ Self.monthPosition(of: $0) }) else {
                return "The same weekday"
            }
            return "The \(position.ordinalName) \(ShiftRecurrence.longWeekdayName(position.weekday))"
        case .lastDay:
            return "The last day"
        }
    }

    /// Which rows the panel shows.
    var showsEvery: Bool { [.daily, .weekly, .monthly, .custom].contains(repeatKind) }
    var showsUnitPicker: Bool { repeatKind == .custom }
    var showsWeekdays: Bool { effectiveUnit == .week }
    var showsMonthly: Bool { effectiveUnit == .month }
    var showsEnds: Bool { effectiveUnit != nil }
    /// The Every row's number: 1 for the named presets.
    var shownInterval: Int { repeatKind == .custom ? interval : 1 }

    // MARK: Date helpers

    static func weekday(of day: String, calendar: Calendar = .current) -> Int? {
        ShiftDateFormatting.date(from: day).map { calendar.component(.weekday, from: $0) }
    }

    static func dayOfMonth(_ day: String) -> Int? {
        guard ShiftRecurrence.isDayString(day) else { return nil }
        return Int(day.suffix(2))
    }

    /// The date's own place in its month: the 2nd Friday, or "the last
    /// Friday" for a fifth one, which most months do not have.
    static func monthPosition(of day: String, calendar: Calendar = .current) -> ShiftRecurrenceMonthWeekday? {
        guard let date = ShiftDateFormatting.date(from: day), let n = dayOfMonth(day) else { return nil }
        let ordinal = (n - 1) / 7 + 1
        return ShiftRecurrenceMonthWeekday(ordinal: ordinal == 5 ? -1 : ordinal,
                                           weekday: calendar.component(.weekday, from: date))
    }

    /// "On a date"'s first value: the last day of the month after the due
    /// date's, which is the mockup's "31 Dec" for a task due in November.
    static func defaultUntil(after day: String, calendar: Calendar = .current) -> String {
        guard let date = ShiftDateFormatting.date(from: day),
              let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let end = calendar.date(byAdding: DateComponents(month: 2, day: -1), to: start) else { return day }
        return ShiftDateFormatting.components(from: end).dateStr
    }

    static func adding(days: Int, to day: String, calendar: Calendar = .current) -> String? {
        guard let date = ShiftDateFormatting.date(from: day),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return ShiftDateFormatting.components(from: moved).dateStr
    }

    /// The date row's quick chips, from `today`: Today, Tomorrow and the next
    /// Monday after today.
    static func quickDays(today: String, calendar: Calendar = .current) -> [(title: String, day: String)] {
        var out: [(String, String)] = [("Today", today)]
        if let tomorrow = adding(days: 1, to: today, calendar: calendar) { out.append(("Tomorrow", tomorrow)) }
        if let weekday = weekday(of: today, calendar: calendar) {
            let ahead = (2 - weekday + 7) % 7
            if let monday = adding(days: ahead == 0 ? 7 : ahead, to: today, calendar: calendar) {
                out.append(("Next \(ShiftRecurrence.shortWeekdayName(2))", monday))
            }
        }
        return out
    }
}

// MARK: - The preview

/// The panel's preview: a five-week strip with the dates the rule lands on,
/// the sentence under it and the literal `recurrence:` line.
///
/// Pure, from the draft and an injected `today`, so a suite can read the
/// strip for any rule without a window.
struct ShiftSchedulePreview: Equatable {

    struct Cell: Equatable {
        let day: String
        let number: Int
        /// The task's own due date.
        let isDue: Bool
        /// A date the rule produces.
        let isOccurrence: Bool
        /// A date the rule would produce but skips (`EXDATE`).
        let isSkipped: Bool
        let isToday: Bool
        let isPast: Bool
    }

    static let weeks = 5

    /// Seven times `weeks` cells, from the first day of the due date's week.
    let cells: [Cell]
    /// The strip's single-letter weekday heads, in the calendar's order.
    let weekdayHeads: [String]
    /// "8 Nov – 12 Dec".
    let rangeTitle: String
    /// "9 dates in view", or empty for a task that happens once.
    let countText: String
    /// "Every Mon, Wed, Fri at 9:30 AM".
    let summary: String
    /// "Next: Mon 16 Nov, Wed 18 Nov, Fri 20 Nov. 10 times in total."
    let detail: String
    /// "recurrence: FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR", or `nil`.
    let ruleLine: String?

    /// `nil` for a task with no date: there is nothing to preview.
    init?(draft: ShiftScheduleDraft, today: Date = Date(), calendar: Calendar = .current) {
        guard let day = draft.day, let dueDate = ShiftDateFormatting.date(from: day) else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        var back = calendar.component(.weekday, from: dueDate) - calendar.firstWeekday
        if back < 0 { back += 7 }
        guard let stripStart = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: dueDate)),
              let stripEnd = calendar.date(byAdding: .day, value: 7 * Self.weeks, to: stripStart) else { return nil }

        let rule = draft.recurrence
        let anchor = ShiftDateFormatting.dateTime(from: day, time: draft.time) ?? dueDate
        let dayString = { (date: Date) in ShiftDateFormatting.components(from: date).dateStr }
        var occurring: Set<String> = []
        if let rule {
            for date in rule.occurrences(anchor: anchor, from: stripStart, through: stripEnd,
                                         calendar: calendar, limit: 7 * Self.weeks) {
                occurring.insert(dayString(date))
            }
        }
        let skipped = rule?.exceptionDates ?? []
        let todayString = dayString(todayStart)

        var cells: [Cell] = []
        for offset in 0..<(7 * Self.weeks) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: stripStart) else { continue }
            let key = dayString(date)
            cells.append(Cell(day: key, number: calendar.component(.day, from: date),
                              isDue: key == day, isOccurrence: occurring.contains(key),
                              isSkipped: skipped.contains(key), isToday: key == todayString,
                              isPast: date < todayStart))
        }
        self.cells = cells

        let symbols = calendar.veryShortWeekdaySymbols
        weekdayHeads = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: stripEnd) ?? stripEnd
        rangeTitle = "\(ShiftDateFormatting.monthDay(stripStart)) \u{2013} \(ShiftDateFormatting.monthDay(lastDay))"

        let at = draft.time.map { " at \(ShiftDateFormatting.clock($0))" } ?? ""
        guard let rule else {
            countText = ""
            summary = "Happens once\(at)"
            detail = "On \(Self.longDay(dueDate))."
            ruleLine = nil
            return
        }
        let inView = cells.filter { $0.isOccurrence || ($0.isDue && !$0.isSkipped) }.count
        countText = inView == 1 ? "1 date in view" : "\(inView) dates in view"
        summary = rule.patternName + at

        let next = rule.occurrences(anchor: anchor, from: anchor.addingTimeInterval(1), through: nil,
                                    calendar: calendar, limit: 3)
        var detail = next.isEmpty
            ? "No further dates."
            : "Next: " + next.map(Self.shortDay).joined(separator: ", ") + "."
        if let count = rule.count {
            detail += count == 1 ? " Once in total." : " \(count) times in total."
        } else if let until = rule.until, let end = ShiftDateFormatting.date(from: until) {
            detail += " Ends \(Self.longDay(end))."
        }
        self.detail = detail
        ruleLine = "recurrence: \(rule.ruleText)"
    }

    /// "Mon 16 Nov": `HelmDateField`'s own shape, with no comma inside a
    /// date, because the sentence lists several with commas between them.
    static func shortDay(_ date: Date) -> String { shortDayFormatter.string(from: date) }
    /// "Fri 13 Nov 2026".
    static func longDay(_ date: Date) -> String { longDayFormatter.string(from: date) }

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private static let longDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()
}

// MARK: - Reminder wording

extension ShiftReminderOffset {

    /// The Remind menu's wording for a task with or without a time.
    ///
    /// A date-only task is reminded at `settings.yaml`'s
    /// `all_day_reminder_at` on its day, less the offset
    /// (`ShiftDue.reminderFireInstant`), so its choices say the time they
    /// will fire at rather than "at the due time" of a task that has none.
    static func label(for minutes: Int, allDayAt: String?) -> String {
        guard let allDayAt else { return label(for: minutes) }
        let clock = ShiftDue.clockTime(allDayAt) ?? ShiftDue.defaultAllDayReminderAt
        guard minutes != 0 else { return "On the day at \(ShiftDateFormatting.clock(clock))" }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        let total = (parts.first ?? 9) * 60 + (parts.last ?? 0) - minutes
        let wrapped = ((total % 1440) + 1440) % 1440
        let fires = String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
        return "\(label(for: minutes)), at \(ShiftDateFormatting.clock(fires))"
    }
}
