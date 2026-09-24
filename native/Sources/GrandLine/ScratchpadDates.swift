// Grand Line - native macOS app.
//
// The Scratchpad calculator's date half (F9 of full review #3 §8): the words
// that name a day, and calendar-aware arithmetic on them.
//
// **Every entry point takes `now` and a `Calendar`.** Nothing here reads the
// clock or the ambient time zone on its own, which is the single decision that
// makes `2 weeks from Friday` testable at all - `ScratchpadEngineSelfTest`
// pins a fixed `now` and a fixed calendar and asserts real answers, instead of
// asserting something vague about a value it cannot predict.
//
// Durations of a month or more are added **as calendar components, not as
// seconds**. `1 month from 31 Jan` is 28 Feb, and a mean-month of 2,629,746
// seconds would land on 2 March. The mean-second factors in
// `ScratchpadUnits` are for converting a *duration* (`1 year in months`); this
// file is for moving a *date*, and the two genuinely want different answers.

import Foundation

enum ScratchpadDates {

    /// The weekday words, mapped to `Calendar`'s 1 = Sunday numbering.
    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    static func isWeekday(_ word: String) -> Bool { weekdays[word.lowercased()] != nil }

    /// True for any word that can begin a date phrase - used by the parser to
    /// decide whether a bare word is a date, a unit or a variable.
    static func isDateWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        if isWeekday(lower) { return true }
        return ["today", "now", "tomorrow", "yesterday", "next", "last", "this"].contains(lower)
    }

    /// Resolve a date phrase starting at `word`, optionally consuming a second
    /// word (`next` + `tuesday`).
    ///
    /// Returns nil when the phrase is not a date after all, so the parser can
    /// fall through to units and variables rather than failing the line.
    static func resolve(_ word: String, following: String?, now: Date, calendar: Calendar)
        -> (date: Date, consumedFollowing: Bool)? {
        let lower = word.lowercased()
        let today = calendar.startOfDay(for: now)
        switch lower {
        case "now":
            return (now, false)
        case "today":
            return (today, false)
        case "tomorrow":
            return (calendar.date(byAdding: .day, value: 1, to: today) ?? today, false)
        case "yesterday":
            return (calendar.date(byAdding: .day, value: -1, to: today) ?? today, false)
        case "next", "last", "this":
            guard let following, let weekday = weekdays[following.lowercased()] else { return nil }
            switch lower {
            case "next":
                return (occurrence(of: weekday, from: today, forward: true, strict: true, calendar: calendar), true)
            case "last":
                return (occurrence(of: weekday, from: today, forward: false, strict: true, calendar: calendar), true)
            default:
                return (occurrence(of: weekday, from: today, forward: true, strict: false, calendar: calendar), true)
            }
        default:
            guard let weekday = weekdays[lower] else { return nil }
            // A bare weekday is the **coming** one, and today counts. "Friday"
            // said on a Friday means today, which is how the word is used out
            // loud; "next Friday" is the strict one, a week away.
            return (occurrence(of: weekday, from: today, forward: true, strict: false, calendar: calendar), false)
        }
    }

    /// An ISO `yyyy-MM-dd` literal, at midnight in `calendar`'s time zone.
    static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func occurrence(of weekday: Int, from day: Date, forward: Bool, strict: Bool,
                                   calendar: Calendar) -> Date {
        let current = calendar.component(.weekday, from: day)
        var delta = forward ? (weekday - current + 7) % 7 : -((current - weekday + 7) % 7)
        if delta == 0 && strict { delta = forward ? 7 : -7 }
        return calendar.date(byAdding: .day, value: delta, to: day) ?? day
    }

    /// Move `date` by a duration, calendar-aware for the units where that
    /// matters. See this file's header for why months and years are not
    /// seconds.
    static func shift(_ date: Date, by duration: ScratchpadQuantity, sign: Int, calendar: Calendar) -> Date {
        guard let unit = duration.unit, unit.dimension == .duration else { return date }
        let amount = duration.amount * Double(sign)
        let whole = amount.rounded()
        let isWhole = abs(amount - whole) < 1e-9
        if isWhole {
            switch unit.code {
            case "year": return calendar.date(byAdding: .year, value: Int(whole), to: date) ?? date
            case "month": return calendar.date(byAdding: .month, value: Int(whole), to: date) ?? date
            case "week": return calendar.date(byAdding: .day, value: Int(whole) * 7, to: date) ?? date
            case "day": return calendar.date(byAdding: .day, value: Int(whole), to: date) ?? date
            default: break
            }
        }
        return date.addingTimeInterval(duration.base * Double(sign))
    }
}
