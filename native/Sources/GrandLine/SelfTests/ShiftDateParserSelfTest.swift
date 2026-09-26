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

        if failures.isEmpty {
            print("PASS: ShiftDateParserSelfTest (9 checks)")
            return true
        } else {
            for f in failures { print("FAIL: \(f)") }
            return false
        }
    }
}

#endif
