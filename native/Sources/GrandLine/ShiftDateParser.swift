// Grand Line - native macOS app.
//
// Hand-rolled natural-language date/time detection for the New/Edit Task
// sheet's Title field (cockpit-shift-create-edit, phase 2). Per the brief:
// this doesn't need full natural-language coverage, just the common cases
// the reviewed mockup demonstrated - today/tomorrow/next-week/next-<weekday>/
// a bare time-of-day, and simple combinations of a day phrase plus a time.
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
    static func parse(_ text: String, now: Date = Date()) -> ShiftParsedDate? {
        let lower = text.lowercased()
        let cal = Calendar.current

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

        switch (baseDate, time) {
        case (.some(let day), .some((let hour, let minute))):
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            guard let combined = cal.date(from: comps) else { return nil }
            let phrases = [dayMatch, timeMatch].compactMap { $0 }
            return ShiftParsedDate(date: combined, hasTime: true,
                                   matchedText: phrases.joined(separator: " "),
                                   matchedPhrases: phrases)
        case (.some(let day), .none):
            return ShiftParsedDate(date: day, hasTime: false, matchedText: dayMatch ?? "",
                                   matchedPhrases: [dayMatch].compactMap { $0 })
        case (.none, .some((let hour, let minute))):
            // A bare time with no day phrase: today if that time hasn't
            // passed yet, otherwise tomorrow - matches how a person would
            // read "3pm" typed at 10am vs at 5pm.
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            guard var combined = cal.date(from: comps) else { return nil }
            if combined < now {
                combined = cal.date(byAdding: .day, value: 1, to: combined) ?? combined
            }
            return ShiftParsedDate(date: combined, hasTime: true, matchedText: timeMatch ?? "",
                                   matchedPhrases: [timeMatch].compactMap { $0 })
        case (.none, .none):
            return nil
        }
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
        return ["at", "on", "by", "due", "@", "-", "\u{2013}", "\u{2014}"].contains(bare)
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
