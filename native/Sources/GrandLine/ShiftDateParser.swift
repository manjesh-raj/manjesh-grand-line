// Grand Line - native macOS app.
//
// Hand-rolled natural-language date/time detection for the New/Edit Task
// sheet's Title field (cockpit-shift-create-edit, phase 2). Per the brief:
// this doesn't need full natural-language coverage, just the common cases
// the reviewed mockup demonstrated - today/tomorrow/next-week/next-<weekday>/
// a bare time-of-day, and simple combinations of a day phrase plus a time.
//
// It also reads a **repeat phrase** (tasks-calendar plan PR 7): "every
// weekday", "every mon, wed", "every 2 weeks", "monthly on the last day",
// "every month on the 2nd friday". The phrase becomes a `ShiftRecurrence`,
// and the date it returns is the rule's first date, so a task added as "every
// tue" is due on a Tuesday rather than on whatever day it was typed.
// No third-party dependency - the recognized vocabulary is small and fixed,
// so a small hand-rolled scanner is simpler and more predictable than parsing
// with `NSDataDetector` (which is tuned for prose, not short task titles) or
// a general NLP library.

import Foundation

struct ShiftParsedDate {
    /// The resolved date/time, if a match was found.
    let date: Date
    /// Whether a time-of-day was part of the match (false = date-only, the
    /// task's due time stays unset).
    let hasTime: Bool
    /// The substring that was recognized - shown in the inline confirmation
    /// label so the person typing can see what was detected.
    let matchedText: String

    /// The individual phrases the scan matched, each an exact (lowercased)
    /// substring of the title - the day phrase and the time phrase are
    /// separate entries because the title may have a connector between them
    /// ("tomorrow **at** 5pm") that `matchedText` joins over.
    ///
    /// Review defect U16 needs these rather than `matchedText`: to take the
    /// detected phrase back out of the title you have to know where it
    /// really was, and "tomorrow 5pm" is not a substring of "Buy milk
    /// tomorrow at 5pm".
    let matchedPhrases: [String]

    /// The repeat phrase's rule, when there was one. `date` is then the
    /// rule's first date on or after the day the text names (or today), so
    /// the task's due date - the rule's anchor - is itself an occurrence.
    var recurrence: ShiftRecurrence? = nil
}

enum ShiftDateParser {

    private static let weekdayNames: [String: Int] = [
        // Calendar.current weekday: 1 = Sunday ... 7 = Saturday.
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    /// Scans `text` for a recognized date/time phrase. Returns `nil` if
    /// nothing in the small vocabulary above matched.
    ///
    /// `day` is the day the text is being added on, when there is one - the
    /// calendar cell a quick add was typed into. It stands in for a missing
    /// day phrase, so "Patch notes 3pm" typed into Friday's cell is Friday at
    /// 15:00 rather than today or tomorrow. A day phrase in the text still
    /// wins, because the captain typed it on purpose.
    static func parse(_ text: String, now: Date = Date(), on day: Date? = nil) -> ShiftParsedDate? {
        var lower = text.lowercased()
        let cal = Calendar.current

        // The repeat phrase first, and then blanked out of what the day and
        // time scans below read: "every tue" must not also be read as the
        // day phrase "tue", which would resolve to next Tuesday and never to
        // today. Blanked with spaces, character for character, so nothing
        // after it moves.
        var repeatMatch: String?
        var rule: ShiftRecurrence?
        if let found = repeatPhrase(in: lower) {
            rule = found.rule
            repeatMatch = String(lower[found.range])
            lower.replaceSubrange(found.range, with: String(repeating: " ", count: lower[found.range].count))
        }

        var baseDate: Date?
        var dayMatch: String?

        // Longest/most-specific phrases first so "next week" isn't shadowed
        // by a bare "next" and "next monday" isn't shadowed by a bare
        // "monday" match later in the same string.
        //
        // Every one of these goes through `firstWholeWord`, never a bare
        // `range(of:)`: B21 was a missing leading word boundary, and the
        // literals here have exactly the same exposure as the weekday table
        // ("Tomorrowland tickets", "Todays-standup notes").
        if let range = firstWholeWord("next week", in: lower) {
            baseDate = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))
            dayMatch = String(lower[range])
        } else if let (weekday, range) = firstMatch(of: weekdayNames, prefixedBy: "next ", in: lower) {
            baseDate = nextOccurrence(of: weekday, from: now, cal: cal, allowToday: false, skipCurrentWeek: true)
            dayMatch = String(lower[range])
        } else if let range = firstWholeWord("tomorrow", in: lower) {
            baseDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            dayMatch = String(lower[range])
        } else if let range = firstWholeWord("today", in: lower) {
            baseDate = cal.startOfDay(for: now)
            dayMatch = String(lower[range])
        } else if let (weekday, range) = firstMatch(of: weekdayNames, prefixedBy: nil, in: lower) {
            baseDate = nextOccurrence(of: weekday, from: now, cal: cal, allowToday: false, skipCurrentWeek: false)
            dayMatch = String(lower[range])
        }

        let (time, timeMatch) = parseTimeOfDay(lower)
        // Nothing recognised: `nil`, even with a `day`, so a caller can tell
        // "the text named nothing" from "the text named this day".
        guard baseDate != nil || time != nil || rule != nil else { return nil }

        // A day phrase wins over the day the text was added on.
        let anchorDay = baseDate ?? day.map { cal.startOfDay(for: $0) }

        var resolved: Date
        switch (anchorDay, time) {
        case (.some(let day), .some((let hour, let minute))):
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            guard let combined = cal.date(from: comps) else { return nil }
            resolved = combined
        case (.some(let day), .none):
            resolved = day
        case (.none, .some((let hour, let minute))):
            // A bare time with no day phrase: today if that time hasn't
            // passed yet, otherwise tomorrow - matches how a person would
            // read "3pm" typed at 10am vs at 5pm.
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            guard let combined = cal.date(from: comps) else { return nil }
            resolved = combined < now ? (cal.date(byAdding: .day, value: 1, to: combined) ?? combined) : combined
        case (.none, .none):
            resolved = cal.startOfDay(for: now)
        }

        // The rule's first date on or after that day: "every tue" typed on a
        // Wednesday is due next Tuesday, and "every weekday" typed on a
        // Saturday is due on Monday. A rule with no day of its own (every
        // day, a plain monthly or yearly rule) starts on the day itself.
        if let rule, let first = rule.occurrences(anchor: resolved, from: resolved, through: nil,
                                                  calendar: cal, limit: 1).first {
            resolved = first
        }

        let phrases = [dayMatch, repeatMatch, timeMatch].compactMap { $0 }
        return ShiftParsedDate(date: resolved, hasTime: time != nil,
                               matchedText: phrases.joined(separator: " "),
                               matchedPhrases: phrases, recurrence: rule)
    }

    /// **Review defect U16.** What the title should read once the date it
    /// carried has been lifted out of it into the due-date field.
    ///
    /// The review's own example: typing "Buy milk tomorrow at 5pm" detects
    /// the date, fills the picker - and leaves the task called "Buy milk
    /// tomorrow at 5pm" forever, so a list of tasks reads as a list of
    /// stale dates. The phrase has been turned into structured data; leaving
    /// a copy of it in the prose is the duplication.
    ///
    /// Each matched phrase is removed once, case-insensitively, and then any
    /// connector word left dangling where it used to be ("at", "on", "by",
    /// "due", "@", "-") is dropped, because "Buy milk at" is not an
    /// improvement on the original.
    ///
    /// **Returns the title unchanged when the result would be empty.** A
    /// task called just "tomorrow" is a task whose whole title is the date,
    /// and silently blanking it would lose the only thing the captain typed.
    static func titleWithoutDatePhrase(_ title: String, parsed: ShiftParsedDate) -> String {
        var working = title
        for phrase in parsed.matchedPhrases where !phrase.isEmpty {
            guard let range = working.range(of: phrase, options: .caseInsensitive) else { continue }
            working.replaceSubrange(range, with: " ")
        }
        var words = working.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let last = words.last, isConnector(last) { words.removeLast() }
        while let first = words.first, isConnector(first) { words.removeFirst() }
        let stripped = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? title : stripped
    }

    /// A word that only made sense as glue in front of the date phrase that
    /// is no longer there.
    private static func isConnector(_ word: String) -> Bool {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:"))
        return ["at", "on", "by", "due", "starting", "@", "-", "\u{2013}", "\u{2014}"].contains(bare)
    }

    // MARK: Repeat phrases

    /// The first repeat phrase in `text` (already lowercased): its rule and
    /// where it was.
    ///
    /// Two shapes start one:
    ///
    ///   - **"every"**, then "day", "weekday", "weekend", "week", "month",
    ///     "year" (with "other" or a number in front for an interval), or a
    ///     list of weekdays ("every mon, wed", "every tue and thu"). A week
    ///     takes "on <weekdays>" and a month takes "on the last day", "on the
    ///     15th", "on day 15" or "on the 2nd friday".
    ///   - **"daily", "weekly", "monthly", "yearly" or "annually"**, with the
    ///     same "on …" for a week or a month.
    ///
    /// The bare adverbs are also ordinary words in a task's title - "Weekly
    /// review", "Send the monthly report", "Daily standup notes" - and
    /// reading those as rules would date the task and cut the word out of
    /// its title. So a bare adverb counts only when it ends the phrase it is
    /// in: followed by "on …", by nothing, by "at", "@", "from" or
    /// "starting", or by a time ("water the plants daily 9am").
    static func repeatPhrase(in text: String) -> (rule: ShiftRecurrence, range: Range<String.Index>)? {
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let start = text.range(of: #"\b(every|daily|weekly|monthly|yearly|annually)\b"#,
                                     options: .regularExpression, range: searchFrom..<text.endIndex) {
            let word = String(text[start])
            let found = word == "every"
                ? everyPhrase(in: text, after: start.upperBound)
                : adverbPhrase(word, in: text, after: start.upperBound)
            if let found { return (found.rule, start.lowerBound..<found.end) }
            searchFrom = start.upperBound
        }
        return nil
    }

    private static let weekdayPattern =
        #"(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b"#
    /// One weekday or several: "mon", "mon, wed", "tue and thu", "mon/wed/fri".
    private static var weekdayListPattern: String {
        let separator = #"(?:\s*[,&/+]\s*(?:and\s+)?|\s+and\s+|\s+)"#
        return "\(weekdayPattern)(?:\(separator)\(weekdayPattern))*"
    }

    /// "every …", from just after the word "every".
    private static func everyPhrase(in text: String, after index: String.Index)
        -> (rule: ShiftRecurrence, end: String.Index)? {
        if let m = match(#"\s+(weekdays?|weekends?)\b"#, in: text, at: index) {
            let days: Set<Int> = m.groups[0]?.hasPrefix("weekday") == true ? ShiftRecurrence.weekdaySet : [1, 7]
            return (ShiftRecurrence(frequency: .weekly, weekdays: days), m.end)
        }
        var cursor = index
        var interval = 1
        if let m = match(#"\s+other\b"#, in: text, at: cursor) {
            interval = 2
            cursor = m.end
        } else if let m = match(#"\s+(\d{1,2})\b"#, in: text, at: cursor), let n = Int(m.groups[0] ?? ""), n >= 1 {
            interval = n
            cursor = m.end
        }
        if let m = match(#"\s+(day|week|month|year)s?\b"#, in: text, at: cursor) {
            switch m.groups[0] {
            case "day":
                return (ShiftRecurrence(frequency: .daily, interval: interval), m.end)
            case "week":
                var rule = ShiftRecurrence(frequency: .weekly, interval: interval)
                var end = m.end
                if let on = weekdaysOn(in: text, at: end) {
                    rule.weekdays = on.days
                    end = on.end
                }
                return (rule, end)
            case "month":
                var rule = ShiftRecurrence(frequency: .monthly, interval: interval)
                var end = m.end
                if let on = monthDayOn(in: text, at: end) {
                    rule.monthDays = on.days
                    rule.monthWeekdays = on.positions
                    end = on.end
                }
                return (rule, end)
            default:
                return (ShiftRecurrence(frequency: .yearly, interval: interval), m.end)
            }
        }
        // "every mon, wed", and "every other friday".
        if let list = weekdayList(in: text, at: cursor) {
            return (ShiftRecurrence(frequency: .weekly, interval: interval, weekdays: list.days), list.end)
        }
        return nil
    }

    /// "daily", "weekly on mon", "monthly on the last day", "yearly", from
    /// just after the adverb.
    private static func adverbPhrase(_ word: String, in text: String, after index: String.Index)
        -> (rule: ShiftRecurrence, end: String.Index)? {
        var rule: ShiftRecurrence
        var end = index
        var hasOn = false
        switch word {
        case "daily":
            rule = ShiftRecurrence(frequency: .daily)
        case "weekly":
            rule = ShiftRecurrence(frequency: .weekly)
            if let on = weekdaysOn(in: text, at: index) {
                rule.weekdays = on.days
                end = on.end
                hasOn = true
            }
        case "monthly":
            rule = ShiftRecurrence(frequency: .monthly)
            if let on = monthDayOn(in: text, at: index) {
                rule.monthDays = on.days
                rule.monthWeekdays = on.positions
                end = on.end
                hasOn = true
            }
        default:
            rule = ShiftRecurrence(frequency: .yearly)
        }
        guard hasOn || endsThePhrase(text, at: end) else { return nil }
        return (rule, end)
    }

    /// Whether what follows `index` lets a bare adverb stand as a rule: the
    /// end of the text, a connector that introduces the rest of the schedule,
    /// or a time. See `repeatPhrase(in:)`.
    private static func endsThePhrase(_ text: String, at index: String.Index) -> Bool {
        let rest = text[index...].drop { $0 == " " || ",.;:!".contains($0) }
        if rest.isEmpty { return true }
        return match(#"(?:at|@|from|starting)\b|@|(?:noon|midnight)\b|\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|\d{1,2}:\d{2}\b"#,
                     in: text, at: rest.startIndex) != nil
    }

    /// " on mon, wed" after a weekly rule.
    private static func weekdaysOn(in text: String, at index: String.Index) -> (days: Set<Int>, end: String.Index)? {
        guard let on = match(#"\s+on\b"#, in: text, at: index) else { return nil }
        return weekdayList(in: text, at: on.end)
    }

    /// A list of weekday names, as `Calendar` weekday numbers.
    private static func weekdayList(in text: String, at index: String.Index) -> (days: Set<Int>, end: String.Index)? {
        guard let m = match(#"\s+"# + weekdayListPattern, in: text, at: index) else { return nil }
        let phrase = String(text[index..<m.end])
        let days = Set(phrase.split(whereSeparator: { !$0.isLetter }).compactMap { weekdayNames[String($0)] })
        return days.isEmpty ? nil : (days, m.end)
    }

    /// " on the last day", " on the 15th", " on day 15", " on the 2nd friday"
    /// or " on the last friday" after a monthly rule.
    private static func monthDayOn(in text: String, at index: String.Index)
        -> (days: Set<Int>, positions: Set<ShiftRecurrenceMonthWeekday>, end: String.Index)? {
        guard let on = match(#"\s+on(?:\s+the)?\b"#, in: text, at: index) else { return nil }
        if let m = match(#"\s+last\s+day\b"#, in: text, at: on.end) {
            return ([-1], [], m.end)
        }
        let ordinals: [String: Int] = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3,
                                       "fourth": 4, "4th": 4, "fifth": 5, "5th": 5, "last": -1]
        if let m = match(#"\s+(first|1st|second|2nd|third|3rd|fourth|4th|fifth|5th|last)\s+("# + weekdayPattern + ")",
                         in: text, at: on.end),
           let ordinal = ordinals[m.groups[0] ?? ""],
           let weekday = weekdayNames[m.groups[1] ?? ""] {
            return ([], [ShiftRecurrenceMonthWeekday(ordinal: ordinal, weekday: weekday)], m.end)
        }
        if let m = match(#"\s+(?:day\s+)?([1-9]|[12][0-9]|3[01])(?:st|nd|rd|th)?\b"#, in: text, at: on.end),
           let day = Int(m.groups[0] ?? "") {
            return ([day], [], m.end)
        }
        return nil
    }

    /// A regular expression matched **at** `index` rather than anywhere
    /// after it, with its capture groups. Every repeat-phrase step is one of
    /// these, which is what keeps the phrase contiguous.
    private static func match(_ pattern: String, in text: String, at index: String.Index)
        -> (groups: [String?], end: String.Index)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let searchRange = NSRange(index..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: .anchored, range: searchRange),
              let whole = Range(result.range, in: text) else { return nil }
        let groups = (1..<max(result.numberOfRanges, 1)).map { i -> String? in
            Range(result.range(at: i), in: text).map { String(text[$0]) }
        }
        return (groups, whole.upperBound)
    }

    /// Finds the first weekday-name keyword in `text`, optionally requiring
    /// it be immediately preceded by `prefix` (used to implement "next
    /// <weekday>" without also matching a bare "<weekday>" via the same
    /// table). Returns the weekday number and the full matched range
    /// (including the prefix, if any).
    private static func firstMatch(
        of table: [String: Int], prefixedBy prefix: String?, in text: String
    ) -> (Int, Range<String.Index>)? {
        var best: (Int, Range<String.Index>)?
        for (name, weekday) in table {
            let needle = (prefix ?? "") + name
            guard let range = firstWholeWord(needle, in: text) else { continue }
            if best == nil || range.lowerBound < best!.1.lowerBound {
                best = (weekday, range)
            }
        }
        return best
    }

    /// The first occurrence of `needle` in `text` that is a whole word.
    ///
    /// **Both** boundaries, and every occurrence rather than only the first.
    /// B21: there was a boundary check after the match but none before it, so
    /// the three-letter abbreviations matched inside ordinary words - a task
    /// called "Followed up with the vendor" was parsed as due on **Wednesday**
    /// (`wed` inside `followed`) and "Common ownership review" as due on
    /// **Monday** (`mon` inside `common`). The captain never typed a date.
    ///
    /// Scanning past a rejected hit matters for the same reason: "followed up
    /// on wed" has `wed` inside `followed` first, and stopping at that one
    /// would lose the real weekday further along.
    ///
    /// A boundary is "not a letter and not a digit" on either side, so
    /// "wed." and "(wed)" and "wed," all still match while "wed2" and
    /// "followed" do not.
    private static func firstWholeWord(_ needle: String, in text: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var searchFrom = text.startIndex
        while let range = text.range(of: needle, range: searchFrom..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex
                || !isWordCharacter(text[range.upperBound])
            if beforeOK && afterOK { return range }
            // Advance by one character rather than to `range.upperBound`, so
            // an overlapping later occurrence is not skipped.
            guard range.lowerBound < text.endIndex else { return nil }
            searchFrom = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// The next date matching `weekday` (1=Sunday...7=Saturday) strictly
    /// after `from`'s calendar day. `skipCurrentWeek` is unused in practice
    /// today (both "next <weekday>" and a bare "<weekday>" resolve to the
    /// nearest future occurrence) but is threaded through in case a future
    /// refinement wants "next Monday" to mean "the Monday after this
    /// upcoming one" - kept as a documented, named no-op rather than a
    /// silent behavior difference between the two call sites.
    private static func nextOccurrence(
        of weekday: Int, from now: Date, cal: Calendar, allowToday: Bool, skipCurrentWeek: Bool
    ) -> Date {
        let today = cal.startOfDay(for: now)
        let todayWeekday = cal.component(.weekday, from: today)
        var offset = (weekday - todayWeekday + 7) % 7
        if offset == 0 && !allowToday { offset = 7 }
        return cal.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// Recognizes "3pm", "3:30pm", "9am", "15:00", "noon", "midnight" -
    /// returns (hour, minute) in 24-hour form plus the matched substring.
    /// Deliberately requires an am/pm suffix or a colon (never a bare
    /// integer) so an ordinary number in a title ("Version 2 release") is
    /// never mistaken for a time.
    private static func parseTimeOfDay(_ text: String) -> ((hour: Int, minute: Int)?, String?) {
        if let range = text.range(of: "\\bnoon\\b", options: .regularExpression) {
            return ((12, 0), String(text[range]))
        }
        if let range = text.range(of: "\\bmidnight\\b", options: .regularExpression) {
            return ((0, 0), String(text[range]))
        }
        // e.g. "3pm", "3:30 pm", "11:45am"
        if let range = text.range(
            of: "\\b([0-1]?[0-9])(?::([0-5][0-9]))?\\s*(am|pm)\\b", options: .regularExpression
        ) {
            let match = String(text[range])
            if let parsed = parseAmPm(match) { return (parsed, match) }
        }
        // e.g. "15:00", "9:05" - 24-hour, colon required (bare "9" is
        // ambiguous and intentionally not matched).
        if let range = text.range(of: "\\b([0-1]?[0-9]|2[0-3]):([0-5][0-9])\\b", options: .regularExpression) {
            let match = String(text[range])
            let parts = match.split(separator: ":")
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h < 24 {
                return ((h, m), match)
            }
        }
        return (nil, nil)
    }

    private static func parseAmPm(_ match: String) -> (Int, Int)? {
        let lower = match.lowercased()
        let isPM = lower.hasSuffix("pm")
        let digits = lower.dropLast(2).trimmingCharacters(in: .whitespaces)
        let parts = digits.split(separator: ":")
        guard let hourRaw = parts.first, var hour = Int(hourRaw), hour >= 1, hour <= 12 else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        if isPM && hour != 12 { hour += 12 }
        if !isPM && hour == 12 { hour = 0 }
        return (hour, minute)
    }
}
