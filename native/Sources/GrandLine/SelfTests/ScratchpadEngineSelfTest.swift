// Grand Line - native macOS app.
//
// The Scratchpad calculator's **pure-logic** half (F9 of full review #3 §8):
// the lexer, the parser, the unit table, the currency table, the date words
// and the formatter. No window, no view, no store - so this suite is
// deliberately NOT in `run-all-tests.sh`'s `NEEDS_SESSION` list and guards
// CI's *blocking* lane. Its window-backed sibling is
// `ScratchpadPadViewSelfTest`.
//
// That split is AGENTS.md's own rule ("the test is what the suite *asserts*,
// never what it imports"), and it is the whole reason the engine was written
// as four Foundation-only files rather than inside `ToolInstance`: the value
// of F9 is that `3 * 4.5 USD in INR` is *right*, and being right is a claim
// that can be asserted ~170 times in a few milliseconds if nothing about it
// needs a window server.
//
// ## Why every case pins `now`
//
// `2 weeks from Friday` has no fixed answer, so a suite that ran against the
// real clock could only assert something vague - "it parsed", "it is in the
// future" - which is AGENTS.md's "a check that cannot fail is worse than no
// check". `ScratchpadEngine.evaluate` takes `now` and a `Calendar`, so every
// date case here asserts a real date against a pinned **Monday 21 September
// 2026, 14:00 UTC**, in a UTC Gregorian calendar with the POSIX locale - which
// also means the suite gives the same answer on a runner in any time zone.
//
// ## Discriminating power
//
// Three cases exist only to keep the rest honest (AGENTS.md: "assert the
// fixture's own discriminating power first"): the rate table is checked for
// USD == 1 and for every rate being positive and finite, the `asOf` stamp is
// checked to actually parse, and the formatter is checked to produce
// *different* strings for the two duration branches - so a formatter that
// collapsed to one branch cannot pass the table above by accident.
//
// ## What else is in here
//
// `ScratchpadStore`'s round trip: a real file, in a scratch directory, read
// back by a second store. That is a file round trip rather than a rendering,
// so by AGENTS.md's own classification rule it belongs in the lane that guards
// merges, next to the engine - not in the windowed suite.
//
// `FM_RUN_SCRATCHPAD_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ScratchpadEngineSelfTest {

    /// Monday 21 September 2026, 14:00 UTC. See this file's header.
    private static let now = Date(timeIntervalSince1970: 1_789_999_200)

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkTheFixtureIsWhatItClaims(check)
        checkArithmetic(check)
        checkRadix(check)
        checkPercentages(check)
        checkUnitConversion(check)
        checkCurrency(check)
        checkDurations(check)
        checkDates(check)
        checkKubernetesCPU(check)
        checkVariablesAndThat(check)
        checkTheMockupPadEvaluatesEndToEnd(check)
        checkProseIsSilentAndErrorsAreNot(check)
        checkTheExamplesUnderThePadAllWork(check)
        checkTheStoreRoundTrips(check)

        print(ok ? "ScratchpadEngineSelfTest: OK" : "ScratchpadEngineSelfTest: FAILURES")
        return ok
    }

    // MARK: Harness

    /// One line, evaluated in its own fresh context.
    private static func result(_ line: String) -> ScratchpadEngine.LineResult {
        ScratchpadEngine.evaluate(lines: [line], now: now, calendar: calendar)[0]
    }

    private static func display(_ line: String) -> String { result(line).display }

    /// A table of `expression -> exactly what the result column must read`.
    private static func expect(_ cases: [(String, String)], _ label: String,
                               _ check: (Bool, String) -> Void) {
        for (input, expected) in cases {
            let actual = display(input)
            check(actual == expected, "\(label): \"\(input)\" gave \"\(actual)\", expected \"\(expected)\"")
        }
    }

    // MARK: The fixture itself

    private static func checkTheFixtureIsWhatItClaims(_ check: (Bool, String) -> Void) {
        check(ScratchpadRates.perUSD["USD"] == 1,
              "the rate table's anchor: USD must be exactly 1 per USD")
        let bad = ScratchpadRates.perUSD.filter { !$0.value.isFinite || $0.value <= 0 }
        check(bad.isEmpty, "the rate table has non-positive or non-finite rates: \(bad.keys.sorted())")
        check(ScratchpadRates.perUSD.count >= 20,
              "the rate table has shrunk to \(ScratchpadRates.perUSD.count) currencies")

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        check(parser.date(from: ScratchpadRates.asOf) != nil,
              "ScratchpadRates.asOf (\(ScratchpadRates.asOf)) does not parse - the pad's footer would say so out loud")
        check(ScratchpadRates.footerLine.contains("2026"),
              "the footer line does not carry the rate date: \(ScratchpadRates.footerLine)")

        // The pinned fixture really is the Monday the date cases below assume.
        check(calendar.component(.weekday, from: now) == 2,
              "the pinned `now` is not a Monday - every date case below is written against one")

        // The two duration branches must actually differ, or the duration
        // table's passes prove nothing.
        let short = ScratchpadFormat.quantity(ScratchpadQuantity(1.134, unit: ScratchpadUnits.unit(code: "s")))
        let long = ScratchpadFormat.quantity(ScratchpadQuantity(18900, unit: ScratchpadUnits.unit(code: "s")))
        check(short != long && !long.hasSuffix(" s"),
              "the duration formatter's scaled and compound branches are not distinguishable: \(short) / \(long)")
    }

    // MARK: Arithmetic

    private static func checkArithmetic(_ check: (Bool, String) -> Void) {
        expect([
            ("3 * 4.5", "13.5"),
            ("2 + 3 * 4", "14"),
            ("(2 + 3) * 4", "20"),
            ("10 / 4", "2.5"),
            ("2 ^ 10", "1,024"),
            ("2 ^ 0.5", "1.4142"),
            ("-5 + 2", "-3"),
            ("1,000 + 1", "1,001"),
            ("1_000_000 / 4", "250,000"),
            ("12,345,678 + 0", "12,345,678"),
            ("1e5", "100,000"),
            ("1.5e3 + 1", "1,501"),
            ("2e-3", "0.002"),
            ("100 - 250", "-150"),
            ("7 \u{00D7} 6", "42"),
            ("84 \u{00F7} 2", "42"),
            ("0.1 + 0.2", "0.3"),
            ("1/3", "0.3333"),
        ], "arithmetic", check)

        // A comma is a thousands separator only in the shape one actually
        // takes, so a European decimal is refused rather than silently read as
        // a bigger number - `5,5` must not be 55.
        check(display("5,5").isEmpty, "\"5,5\" should not quietly become \(display("5,5"))")
        check(display("1,0000").isEmpty, "a four-digit group is not a thousands separator")

        check(result("10 / 0").isError, "10 / 0 should be an error, not a number")
        check(display("10 / 0") == "divided by zero", "10 / 0 said \"\(display("10 / 0"))\"")
    }

    private static func checkRadix(_ check: (Bool, String) -> Void) {
        expect([
            ("0x1F + 12", "43"),
            ("0xFF", "255"),
            ("0b1011", "11"),
            ("0o17", "15"),
            ("0b1011 as hex", "0xB"),
            ("255 as hex", "0xFF"),
            ("255 as binary", "0b11111111"),
            ("64 as octal", "0o100"),
            ("0x10 * 0x10 as hex", "0x100"),
        ], "radix", check)
        check(result("1.5 as hex").isError, "a fractional number has no hex form, and the pad should say so")
    }

    private static func checkPercentages(_ check: (Bool, String) -> Void) {
        expect([
            ("15% of 2400", "360"),
            ("2400 + 15%", "2,760"),
            ("2400 - 10%", "2,160"),
            ("12.5% of 80", "10"),
            ("20% of 150 USD", "$30.00"),
            ("0.25 as %", "25%"),
        ], "percentages", check)
    }

    // MARK: Units

    private static func checkUnitConversion(_ check: (Bool, String) -> Void) {
        expect([
            ("1.4 TiB in GB", "1,539.32 GB"),
            ("120 GiB in MB", "128,849 MB"),
            ("1 GB in MB", "1,000 MB"),
            ("1 GiB in MiB", "1,024 MiB"),
            ("500 MB in GiB", "0.4657 GiB"),
            ("5 km in m", "5,000 m"),
            ("1 mi in km", "1.6093 km"),
            ("100 cm in in", "39.3701 in"),
            ("2 kg in lb", "4.4092 lb"),
            ("16 oz in g", "453.59 g"),
            ("100 F in C", "37.7778 \u{00B0}C"),
            ("0 C in F", "32 \u{00B0}F"),
            ("300 K in C", "26.85 \u{00B0}C"),
            ("1 year in months", "12 months"),
            ("90 min in h", "1.5 h"),
            ("1 week in h", "168 h"),
            ("2 GB / 4", "500 MB"),
        ], "units", check)

        // A ratio of two same-dimension quantities is a plain number, and a
        // pair from different dimensions is refused rather than guessed at.
        expect([("1 GiB / 1 MiB", "1,024")], "unit ratios", check)
        check(result("1 kg + 3 s").isError, "kg + s should be refused")
        check(display("1 kg + 3 s").contains("not the same kind of thing"),
              "the kg + s message should name the problem: \(display("1 kg + 3 s"))")
        check(result("5 kg in m").isError, "kg cannot be expressed in metres")
        check(result("5 in zorkmids").isError, "an unknown unit in a conversion is a stated error")
    }

    private static func checkCurrency(_ check: (Bool, String) -> Void) {
        expect([
            ("100 USD in INR", "\u{20B9}8,355"),
            ("$100 in EUR", "\u{20AC}92.00"),
            ("50 EUR in USD", "$54.35"),
            ("3 * 4.5 USD in INR", "\u{20B9}1,128"),
            ("1000 INR in USD", "$11.97"),
        ], "currency", check)
        check(display("100 USD").hasPrefix("$"), "a bare USD amount should render with its symbol")
    }

    private static func checkDurations(_ check: (Bool, String) -> Void) {
        expect([
            ("840ms", "840 ms"),
            ("840ms * 1.35", "1.134 s"),
            ("3h 40m + 95m", "5 h 15 min"),
            ("2 days + 4 h", "2 days 4 h"),
            ("45 s + 30 s", "1 min 15 s"),
            ("500 us", "500 \u{00B5}s"),
            ("1.5 h in min", "90 min"),
        ], "durations", check)
    }

    // MARK: Dates

    private static func checkDates(_ check: (Bool, String) -> Void) {
        expect([
            ("today", "21 Sep 2026"),
            ("tomorrow", "22 Sep 2026"),
            ("yesterday", "20 Sep 2026"),
            ("friday", "25 Sep 2026"),
            ("next tuesday", "22 Sep 2026"),
            ("last friday", "18 Sep 2026"),
            ("2 weeks from Friday", "9 Oct 2026"),
            ("3 days from today", "24 Sep 2026"),
            ("1 month from 2026-01-31", "28 Feb 2026"),
            ("2026-10-09 - today", "18 days"),
            ("2026-10-09 + 3 weeks", "30 Oct 2026"),
            ("1789977651 as date", "21 Sep, 8:00 AM"),
            ("3 days ago", "18 Sep, 2:00 PM"),
            ("2 weeks before 2026-10-09", "25 Sep 2026"),
        ], "dates", check)

        // A bare weekday means the coming one and today counts; "next" is the
        // strict one. Asserted as a *pair* so a rule that collapsed them into
        // one answer fails here rather than silently.
        check(display("monday") != display("next monday"),
              "\"monday\" (today, a Monday) and \"next monday\" must not be the same day")
        check(display("monday") == "21 Sep 2026", "a bare weekday naming today should be today")
        check(display("next monday") == "28 Sep 2026", "\"next monday\" from a Monday is a week on")

        check(result("today + today").isError, "two dates cannot be added")
        check(result("today * 2").isError, "a date cannot be multiplied")

        checkAbsurdDurationsAreRefusedRatherThanFatal(check)
    }

    /// B18: `1e30 days from today` **killed the process**.
    ///
    /// `Int(Double)` traps rather than returning nil for anything past
    /// `Int.max`, so a line the captain typed into a scratchpad took the whole
    /// app down - and every one of these phrasings reaches a different one of
    /// the four `ScratchpadDates.shift` call sites. Nothing here can run at
    /// all if the trap is back, which is the point: a crashed suite is the
    /// failure.
    private static func checkAbsurdDurationsAreRefusedRatherThanFatal(
        _ check: (Bool, String) -> Void) {
        let absurd = [
            "1e30 days from today",       // `from`
            "1e30 weeks from today",      // the `* 7` overflow, one step further in
            "1e30 years from today",
            "1e30 months from today",
            "1e30 days ago",              // `ago`
            "today + 1e30 days",          // ScratchpadMath, date on the left
            "1e30 days + today",          // ScratchpadMath, date on the right
            "today - 1e30 days",
            "1e30 seconds from today",    // the seconds path, which never trapped
                                          // but did produce an unrenderable Date
            "1e400 days from today",      // literal overflows to `.infinity`
        ]
        for line in absurd {
            let answer = result(line)
            check(answer.isError,
                  "\"\(line)\" must be refused as out of range, got \"\(answer.display)\"")
        }

        // The discriminating half: the cap must not be so tight that a real
        // date phrase is refused with it.
        check(!result("5000 days from today").isError,
              "a large but sane duration still resolves - "
              + "got \"\(display("5000 days from today"))\"")
        check(display("36500 days from today").hasSuffix("2126"),
              "a century out still resolves to a real date, got "
              + "\"\(display("36500 days from today"))\"")
    }

    private static func checkKubernetesCPU(_ check: (Bool, String) -> Void) {
        expect([
            ("250m cpu", "250m cpu"),
            ("250m cpu * 6", "1.5 cpu"),
            ("250m cpu * 2", "500m cpu"),
            ("2 cpu in cpu", "2 cpu"),
            ("1 cpu / 4", "250m cpu"),
        ], "kubernetes cpu", check)
    }

    // MARK: Variables, `that`, whole pads

    private static func checkVariablesAndThat(_ check: (Bool, String) -> Void) {
        let pad = ScratchpadEngine.evaluate(lines: [
            "seats = 42",
            "seat_price = 18.50 USD / month",
            "seats * seat_price",
            "that * 12",
        ], now: now, calendar: calendar)
        check(pad[0].display == "42", "an assignment shows its value, got \"\(pad[0].display)\"")
        check(pad[1].display == "$18.50/mo", "a rate keeps its period, got \"\(pad[1].display)\"")
        check(pad[2].display == "$777.00/mo", "a count times a rate, got \"\(pad[2].display)\"")
        check(pad[3].display == "$9,324/mo", "`that` is the previous line's result, got \"\(pad[3].display)\"")

        // A variable outranks a unit of the same name, which is what keeps a
        // pad that defines `t` from silently meaning tonnes.
        let shadow = ScratchpadEngine.evaluate(lines: ["t = 12", "t * 2"], now: now, calendar: calendar)
        check(shadow[1].display == "24", "a defined variable must outrank a unit of the same name, got \"\(shadow[1].display)\"")

        // Several statements on one line: the assignment lands, the last
        // statement is the line's answer.
        let compound = ScratchpadEngine.evaluate(lines: ["p95 = 840ms; p95 * 1.35", "p95 * 2"],
                                                 now: now, calendar: calendar)
        check(compound[0].display == "1.134 s", "a `;` line shows its last statement, got \"\(compound[0].display)\"")
        check(compound[1].display == "1.68 s", "the assignment before the `;` must have landed, got \"\(compound[1].display)\"")

        check(result("that + 1").isError, "`that` with nothing before it is a stated error")
    }

    /// The pad the captain reviewed in the mockup, line for line.
    private static func checkTheMockupPadEvaluatesEndToEnd(_ check: (Bool, String) -> Void) {
        let lines = [
            "seats = 42",
            "seat_price = 18.50 USD / month",
            "seats * seat_price",
            "",
            "that * 12 in INR",
            "",
            "0x1F + 12",
            "2 weeks from Friday",
            "1789977651 as date",
            "",
            "1.4 TiB in GB",
            "p95 = 840ms; p95 * 1.35",
        ]
        let results = ScratchpadEngine.evaluate(lines: lines, now: now, calendar: calendar)
        check(results.count == lines.count, "one result per line, always - the columns are index-aligned")
        let expected = [
            "42", "$18.50/mo", "$777.00/mo", "", "\u{20B9}7,79,020/mo", "", "43",
            "9 Oct 2026", "21 Sep, 8:00 AM", "", "1,539.32 GB", "1.134 s",
        ]
        for (index, want) in expected.enumerated() {
            check(results[index].display == want,
                  "mockup line \(index + 1) (\"\(lines[index])\") gave \"\(results[index].display)\", expected \"\(want)\"")
        }
        check(results.allSatisfy { !$0.isError }, "no line of the reviewed mockup pad may be an error")

        // Blank lines stay blank in the copied column too, so a paste still
        // lines up with what is on screen.
        let copied = ScratchpadEngine.copyableResults(results).components(separatedBy: "\n")
        check(copied.count == lines.count, "Copy all results must keep one line per pad line")
        check(copied[3].isEmpty, "a blank pad line copies as a blank line")
    }

    // MARK: The quiet/loud split

    private static func checkProseIsSilentAndErrorsAreNot(_ check: (Bool, String) -> Void) {
        for prose in ["renewal quote came in today", "# a heading", "// a note", "   ", "TODO: ask finance",
                      "ping the vendor about seats"] {
            let line = result(prose)
            check(line.display.isEmpty && !line.isError, "prose must stay silent: \"\(prose)\" said \"\(line.display)\"")
        }
        // ...and the other direction, which is the half that would rot
        // unnoticed: a well-formed expression that cannot be computed must
        // print its reason.
        for (expression, fragment) in [("1 kg + 3 s", "not the same kind of thing"),
                                       ("10 / 0", "divided by zero"),
                                       ("5 kg in m", "cannot be expressed"),
                                       ("that", "no earlier result")] {
            let line = result(expression)
            check(line.isError && line.display.contains(fragment),
                  "\"\(expression)\" should explain itself, said \"\(line.display)\"")
        }
    }

    private static func checkTheExamplesUnderThePadAllWork(_ check: (Bool, String) -> Void) {
        for example in ScratchpadEngine.examples {
            let line = result(example)
            check(!line.display.isEmpty && !line.isError,
                  "the pad advertises \"\(example)\" under its own footer, and it gave \"\(line.display)\"")
        }
    }

    // MARK: The store

    private static func checkTheStoreRoundTrips(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-scratchpad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scratchpad.json")

        let store = ScratchpadStore(fileURL: file)
        check(store.text(for: "Scratchpad").isEmpty, "a store with no file yet reads as an empty pad, not a failure")
        store.save("seats = 42\nseats * 2", for: "Scratchpad")
        store.save("0x1F + 12", for: "Scratchpad 2")

        check(FileManager.default.fileExists(atPath: file.path), "the pad was never written to \(file.path)")
        let reopened = ScratchpadStore(fileURL: file)
        check(reopened.text(for: "Scratchpad") == "seats = 42\nseats * 2",
              "the pad did not survive a reopen: \"\(reopened.text(for: "Scratchpad"))\"")
        check(reopened.text(for: "Scratchpad 2") == "0x1F + 12",
              "two open pads must not share one document")

        // A rename carries the text; an emptied pad leaves nothing behind.
        reopened.rename(from: "Scratchpad 2", to: "Renewal maths")
        check(reopened.text(for: "Renewal maths") == "0x1F + 12", "a rename must carry the pad with it")
        check(reopened.text(for: "Scratchpad 2").isEmpty, "a renamed pad must not also stay under its old name")
        reopened.save("   \n  ", for: "Renewal maths")
        check(reopened.text(for: "Renewal maths").isEmpty, "clearing a pad should remove it rather than store blanks")
        check(ScratchpadStore(fileURL: file).text(for: "Renewal maths").isEmpty,
              "the cleared pad came back from disk")

        // M3's 0600/0700: the same treatment `snippets.json` gets, and for the
        // same reason - a pad carries prices, seat counts and hostnames.
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)??.intValue
        check(mode == 0o600, "scratchpad.json should be 0600, is \(mode.map { String($0, radix: 8) } ?? "unreadable")")

        // GL-35: nothing unbounded.
        let bulk = ScratchpadStore(fileURL: root.appendingPathComponent("bulk.json"))
        for index in 0..<(ScratchpadStore.maximumPads + 12) {
            bulk.save("pad \(index)", for: "Pad \(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        check(bulk.pads.count == ScratchpadStore.maximumPads,
              "the pad map is capped at \(ScratchpadStore.maximumPads), held \(bulk.pads.count)")
        check(bulk.text(for: "Pad \(ScratchpadStore.maximumPads + 11)") == "pad \(ScratchpadStore.maximumPads + 11)",
              "pruning must keep the most recently edited pads")
    }
}

#endif
