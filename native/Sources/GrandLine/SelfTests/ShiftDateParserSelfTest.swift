// Grand Line - native macOS app.
//
// Permanent, env-gated self-test for `ShiftDateParser` (cockpit-shift-create-
// edit, phase 2) - same convention as `ShiftStoreSelfTest.swift`/
// `YamlBeautifySelfTest.swift`: run via `FM_RUN_SHIFT_DATE_PARSER_TESTS=1
// .build/debug/GrandLine`, checked against a fixed reference "now" so
// results are deterministic regardless of which real day this runs on.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ShiftDateParserSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        let cal = Calendar.current

        // Fixed reference point: Wednesday 2026-08-12, 10:00 local.
        var refComps = DateComponents()
        refComps.year = 2026; refComps.month = 8; refComps.day = 12
        refComps.hour = 10; refComps.minute = 0
        guard let now = cal.date(from: refComps) else {
            print("FAIL: could not build reference date")
            return false
        }
        precondition(cal.component(.weekday, from: now) == 4, "reference date must be a Wednesday")

        // 1. A relative day + time ("tomorrow 3pm").
        if let parsed = ShiftDateParser.parse("Ship the release tomorrow 3pm", now: now) {
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.date)
            if !(comps.day == 13 && comps.hour == 15 && comps.minute == 0 && parsed.hasTime) {
                failures.append("'tomorrow 3pm' resolved to \(comps) hasTime=\(parsed.hasTime), expected day=13 hour=15 min=0 hasTime=true")
            }
        } else {
            failures.append("'tomorrow 3pm' failed to parse at all")
        }

        // 2. A specific weekday ("next mon").
        if let parsed = ShiftDateParser.parse("Follow up next mon", now: now) {
            let comps = cal.dateComponents([.year, .month, .day], from: parsed.date)
            // Wed 2026-08-12 -> next Monday is 2026-08-17.
            if !(comps.year == 2026 && comps.month == 8 && comps.day == 17 && !parsed.hasTime) {
                failures.append("'next mon' resolved to \(comps) hasTime=\(parsed.hasTime), expected 2026-08-17 hasTime=false")
            }
        } else {
            failures.append("'next mon' failed to parse at all")
        }

        // 3. A bare time-of-day ("9am") - later than the reference "now"
        // (10:00), so it should resolve to tomorrow at 9am (today's 9am
        // already passed).
        if let parsed = ShiftDateParser.parse("Stand-up prep 9am", now: now) {
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.date)
            if !(comps.day == 13 && comps.hour == 9 && comps.minute == 0 && parsed.hasTime) {
                failures.append("'9am' resolved to \(comps) hasTime=\(parsed.hasTime), expected day=13 hour=9 min=0 hasTime=true")
            }
        } else {
            failures.append("'9am' failed to parse at all")
        }

        // 4. A bare time-of-day still in the future today ("11pm" at 10am
        // reference) - should resolve to today.
        if let parsed = ShiftDateParser.parse("Check logs 11pm", now: now) {
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.date)
            if !(comps.day == 12 && comps.hour == 23 && comps.minute == 0) {
                failures.append("'11pm' (still upcoming today) resolved to \(comps), expected day=12 hour=23")
            }
        } else {
            failures.append("'11pm' failed to parse at all")
        }

        // 5. "today" alone - date-only, no time.
        if let parsed = ShiftDateParser.parse("Wrap up today", now: now) {
            let comps = cal.dateComponents([.year, .month, .day], from: parsed.date)
            if !(comps.day == 12 && !parsed.hasTime) {
                failures.append("'today' resolved to \(comps) hasTime=\(parsed.hasTime), expected day=12 hasTime=false")
            }
        } else {
            failures.append("'today' failed to parse at all")
        }

        // 6. "next week" - date-only, +7 days.
        if let parsed = ShiftDateParser.parse("Revisit next week", now: now) {
            let comps = cal.dateComponents([.year, .month, .day], from: parsed.date)
            if !(comps.day == 19 && !parsed.hasTime) {
                failures.append("'next week' resolved to \(comps) hasTime=\(parsed.hasTime), expected day=19 hasTime=false")
            }
        } else {
            failures.append("'next week' failed to parse at all")
        }

        // 7. A plain title with no recognizable date phrase should return nil.
        if ShiftDateParser.parse("Write the quarterly report", now: now) != nil {
            failures.append("'Write the quarterly report' unexpectedly parsed a date")
        }

        // 8. A plain number should not be mistaken for a time.
        if ShiftDateParser.parse("Version 2 release notes", now: now) != nil {
            failures.append("'Version 2 release notes' unexpectedly parsed a date from the bare number")
        }

        // 9. B21: an abbreviation inside an ordinary word is not a weekday.
        //
        // "Followed up with the vendor" was parsed as due on Wednesday (`wed`
        // inside `followed`) and "Common ownership review" as due on Monday
        // (`mon` inside `common`). The captain never typed a date, and the
        // task silently acquired one - and then showed up as overdue.
        let embedded = [
            "Followed up with the vendor",          // wed
            "Common ownership review",              // mon
            "Monsoon readiness plan",               // mon
            "Satellite uplink runbook",             // sat
            "Sunset the old API",                   // sun
            "Tomorrowland ticket refund",           // tomorrow
            "Thursday-ish planning".replacingOccurrences(of: "Thursday", with: "Thursdayish"),
            "Refactor the frieze renderer",         // fri
        ]
        for title in embedded {
            if let parsed = ShiftDateParser.parse(title, now: now) {
                failures.append("B21: \(title.debugDescription) must not parse a date, "
                                + "matched \(parsed.matchedText.debugDescription)")
            }
        }

        // The discriminating half: the very same words with a real boundary
        // still parse, so the boundary rule cannot quietly become "never
        // match an abbreviation".
        let standalone: [(String, Int)] = [
            ("Followed up, due wed", 4),            // Wed 2026-08-12 -> 19 (not today)
            ("Common review on mon", 2),
            ("Ship it (fri)", 6),
            ("Ship it sat.", 7),
        ]
        for (title, weekday) in standalone {
            guard let parsed = ShiftDateParser.parse(title, now: now) else {
                failures.append("B21: \(title.debugDescription) should still parse a weekday")
                continue
            }
            let got = cal.component(.weekday, from: parsed.date)
            if got != weekday {
                failures.append("B21: \(title.debugDescription) resolved to weekday \(got), "
                                + "expected \(weekday)")
            }
        }

        // And a rejected embedded hit must not hide a real one later in the
        // same string - `wed` inside `followed` comes first.
        if let parsed = ShiftDateParser.parse("Followed up on wed", now: now) {
            if cal.component(.weekday, from: parsed.date) != 4 {
                failures.append("B21: a real weekday after an embedded hit must still be found, "
                                + "got weekday \(cal.component(.weekday, from: parsed.date))")
            }
        } else {
            failures.append("B21: 'Followed up on wed' must still find the real 'wed'")
        }

        checkRepeatPhrases(now: now, calendar: cal, failures: &failures)
        checkAddedOnADay(now: now, calendar: cal, failures: &failures)

        if failures.isEmpty {
            print("PASS: ShiftDateParserSelfTest (11 checks)")
            return true
        } else {
            for f in failures { print("FAIL: \(f)") }
            return false
        }
    }

    // MARK: 10. Repeat phrases (tasks-calendar plan PR 7)

    /// "every weekday", "every mon, wed", "every 2 weeks" and "monthly on the
    /// last day" become rules, the date is the rule's first date, and the
    /// phrase comes out of the title along with the date.
    private static func checkRepeatPhrases(now: Date, calendar cal: Calendar, failures: inout [String]) {
        func day(_ date: Date) -> String { ShiftDateFormatting.components(from: date).dateStr }
        func expect(_ text: String, rule: ShiftRecurrence, due: String, time: String? = nil, title: String,
                    line: Int = #line) {
            guard let parsed = ShiftDateParser.parse(text, now: now) else {
                failures.append("repeat: \(text.debugDescription) parsed nothing (line \(line))")
                return
            }
            if parsed.recurrence?.ruleText != rule.ruleText {
                failures.append("repeat: \(text.debugDescription) gave rule \(parsed.recurrence?.ruleText ?? "none"), "
                                + "expected \(rule.ruleText)")
            }
            let (gotDay, gotTime) = ShiftDateFormatting.components(from: parsed.date)
            if gotDay != due || parsed.hasTime != (time != nil) || (time != nil && gotTime != time) {
                failures.append("repeat: \(text.debugDescription) is due \(gotDay) \(parsed.hasTime ? gotTime : "all day"), "
                                + "expected \(due) \(time ?? "all day")")
            }
            let stripped = ShiftDateParser.titleWithoutDatePhrase(text, parsed: parsed)
            if stripped != title {
                failures.append("repeat: \(text.debugDescription) left the title \(stripped.debugDescription), "
                                + "expected \(title.debugDescription)")
            }
        }

        // The reference day is Wednesday 2026-08-12, 10:00.
        expect("Standup every weekday", rule: ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet),
               due: "2026-08-12", title: "Standup")
        expect("Gym every mon, wed", rule: ShiftRecurrence(frequency: .weekly, weekdays: [2, 4]),
               due: "2026-08-12", title: "Gym")
        expect("Gym every tue and thu 7am", rule: ShiftRecurrence(frequency: .weekly, weekdays: [3, 5]),
               due: "2026-08-13", time: "07:00", title: "Gym")
        expect("Review dashboards every 2 weeks", rule: ShiftRecurrence(frequency: .weekly, interval: 2),
               due: "2026-08-12", title: "Review dashboards")
        expect("Pay rent monthly on the last day", rule: ShiftRecurrence(frequency: .monthly, monthDays: [-1]),
               due: "2026-08-31", title: "Pay rent")
        // August 2026 opens on a Saturday, so its Fridays are 7 and 14.
        expect("Board deck every month on the 2nd friday",
               rule: ShiftRecurrence(frequency: .monthly,
                                     monthWeekdays: [ShiftRecurrenceMonthWeekday(ordinal: 2, weekday: 6)]),
               due: "2026-08-14", title: "Board deck")
        expect("Invoice every month on the 1st", rule: ShiftRecurrence(frequency: .monthly, monthDays: [1]),
               due: "2026-09-01", title: "Invoice")
        expect("Patch notes every tue 10am", rule: ShiftRecurrence(frequency: .weekly, weekdays: [3]),
               due: "2026-08-18", time: "10:00", title: "Patch notes")
        expect("Water the plants every other day", rule: ShiftRecurrence(frequency: .daily, interval: 2),
               due: "2026-08-12", title: "Water the plants")
        expect("Rotate keys every 3 months", rule: ShiftRecurrence(frequency: .monthly, interval: 3),
               due: "2026-08-12", title: "Rotate keys")
        expect("Renew the domain yearly", rule: ShiftRecurrence(frequency: .yearly),
               due: "2026-08-12", title: "Renew the domain")
        expect("Water plants daily at 9am", rule: ShiftRecurrence(frequency: .daily),
               due: "2026-08-13", time: "09:00", title: "Water plants")
        expect("Sync with Ana weekly on fri", rule: ShiftRecurrence(frequency: .weekly, weekdays: [6]),
               due: "2026-08-14", title: "Sync with Ana")
        expect("Clean the desk every weekend", rule: ShiftRecurrence(frequency: .weekly, weekdays: [1, 7]),
               due: "2026-08-15", title: "Clean the desk")

        // The repeat phrase is taken out of what the day scan reads. Read as a
        // day phrase, "wed" is *next* Wednesday (the 19th); as a rule it is
        // today, the 12th.
        if let parsed = ShiftDateParser.parse("Retro every wed", now: now) {
            if day(parsed.date) != "2026-08-12" {
                failures.append("repeat: \"every wed\" on a Wednesday should start today, got \(day(parsed.date)) "
                                + "(the weekday was read as a day phrase as well)")
            }
        } else {
            failures.append("repeat: \"Retro every wed\" parsed nothing")
        }

        // A day phrase beside the rule moves where it starts.
        if let parsed = ShiftDateParser.parse("Standup every weekday starting next week", now: now) {
            if day(parsed.date) != "2026-08-19" || parsed.recurrence?.weekdays != ShiftRecurrence.weekdaySet {
                failures.append("repeat: \"every weekday starting next week\" should start 2026-08-19, got "
                                + "\(day(parsed.date)) \(parsed.recurrence?.ruleText ?? "no rule")")
            }
        } else {
            failures.append("repeat: \"every weekday starting next week\" parsed nothing")
        }

        // The bare adverbs are also ordinary words in a title. These must not
        // become rules, or the task is dated and loses the word.
        let ordinary = ["Weekly review", "Send the monthly report", "Daily standup notes",
                        "Check every log file", "Yearly budget planning", "Everyday carry list"]
        for title in ordinary {
            if let parsed = ShiftDateParser.parse(title, now: now) {
                failures.append("repeat: \(title.debugDescription) must not parse, matched "
                                + "\(parsed.matchedText.debugDescription) as \(parsed.recurrence?.ruleText ?? "a date")")
            }
        }
        // No repeat phrase, no rule: the old phrases are unchanged.
        if ShiftDateParser.parse("Ship the release tomorrow 3pm", now: now)?.recurrence != nil {
            failures.append("repeat: a plain day phrase must not produce a rule")
        }
    }

    // MARK: 11. Added on a day (the calendar's quick add)

    /// The day a quick add was typed into stands in for a missing day phrase,
    /// and a day phrase in the text still wins.
    private static func checkAddedOnADay(now: Date, calendar cal: Calendar, failures: inout [String]) {
        func day(_ date: Date) -> String { ShiftDateFormatting.components(from: date).dateStr }
        guard let thursday = cal.date(byAdding: .day, value: 8, to: cal.startOfDay(for: now)),
              let saturday = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: now)) else {
            failures.append("on a day: could not build the fixture days")
            return
        }
        if ShiftDateParser.parse("Write the patch notes", now: now, on: thursday) != nil {
            failures.append("on a day: a title with no phrase must still parse nothing, so the caller keeps its day")
        }
        // 9am has passed on the reference day, but not on the 20th: no roll
        // over to the next day when the day was given.
        if let parsed = ShiftDateParser.parse("Ship it 9am", now: now, on: thursday) {
            let (d, t) = ShiftDateFormatting.components(from: parsed.date)
            if d != "2026-08-20" || t != "09:00" || !parsed.hasTime {
                failures.append("on a day: \"9am\" on 2026-08-20 resolved to \(d) \(t)")
            }
        } else {
            failures.append("on a day: \"Ship it 9am\" parsed nothing")
        }
        if let parsed = ShiftDateParser.parse("Call the bank tomorrow", now: now, on: thursday),
           day(parsed.date) != "2026-08-13" {
            failures.append("on a day: a typed \"tomorrow\" should win over the cell, got \(day(parsed.date))")
        }
        // A rule from a Saturday's cell starts on its first date after it.
        if let parsed = ShiftDateParser.parse("Standup every weekday", now: now, on: saturday) {
            if day(parsed.date) != "2026-08-17" {
                failures.append("on a day: \"every weekday\" added on Saturday should start Monday 2026-08-17, "
                                + "got \(day(parsed.date))")
            }
        } else {
            failures.append("on a day: \"Standup every weekday\" parsed nothing")
        }
    }
}

#endif
