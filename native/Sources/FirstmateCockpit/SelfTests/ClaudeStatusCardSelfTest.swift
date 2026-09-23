// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for the Home page's Claude status strip -
// run via `FM_RUN_CLAUDE_STATUS_CARD_TESTS=1 .build/debug/FirstmateCockpit`.
//
// **Window-backed on purpose**, and listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` accordingly: it builds a real `HelmModuleCard`
// in a real `OffScreenProbe` window, runs a real layout pass, and reads the
// rendered geometry and a real rasterised pixel back. The column-mapping half
// could be pure logic, but the two things most worth guarding here cannot be:
// that the five columns are actually *painted* legibly in both registers, and
// that the card holds its compact height at a real span-2 width.
//
// `HomeCanvasController.claudeStripColumns` is `static` precisely so the
// mapping can be driven from a fabricated `QuotaSnapshot` without mounting a
// canvas, which would drag in a dozen stores this suite has no business
// constructing.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ClaudeStatusCardSelfTest {

    /// The live shape, from `quota-axi --json --provider claude` on the
    /// captain's own account (2026-09-23). Percentages are already converted
    /// to "used" the way `QuotaSource.parse` converts them.
    private static func liveSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 90, resetsAt: nil, pace: .ahead),
            weekly: QuotaWindow(kind: .weekly, percentUsed: 69, resetsAt: nil, pace: .ahead),
            fable: QuotaWindow(kind: .fable, percentUsed: 100, resetsAt: nil, pace: .ahead),
            extraUsage: QuotaCreditWindow(percentUsed: 98, spentUsd: 137.62, limitUsd: 140),
            latency: 1.4, log: "")
    }

    static func run() -> Bool {
        var allOK = true
        // The hermeticity rule in AGENTS.md: this suite drives
        // `ThemeManager.shared.setTheme`, so it captures and restores the
        // captain's own theme. Captured by *reading* `theme` first, which is
        // the necessary condition `Phase3PolishSelfTest.
        // checkSuitesRestoreTheTheme` greps for.
        let captainTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(captainTheme) }

        for check in [checkColumnsAndLabels, checkStatedGaps,
                      checkRendersInBothThemes, checkStaysCompact,
                      checkTheReadingIsNotGatedOnTheBriefing,
                      checkSeverityIsNotInverted,
                      checkTheHeaderCarriesARefresh,
                      checkTheRefreshIsWiredToAForcedReading,
                      checkResetTimesAreOfferedOnlyWhereTheyExist,
                      checkTheResetAffordanceIsReallyWiredToTheCell] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ClaudeStatusCardSelfTest: all checks passed"
                    : "ClaudeStatusCardSelfTest: FAILED")
        return allOK
    }

    // MARK: 1 - the five columns, in the captain's order, with the agreed labels

    private static func checkColumnsAndLabels(_ ok: inout Bool) {
        print("\n-- claude strip: five columns, the picked order, the agreed labels --")

        let columns = HomeCanvasController.claudeStripColumns(for: liveSnapshot())

        let expectedLabels = ["Session (5h)", "Week", "Fable week", "Extra usage", "Spend cap"]
        if columns.map(\.label) != expectedLabels {
            fail("column order/labels should be \(expectedLabels), got \(columns.map(\.label))", &ok)
        }
        if columns.count != HelmModuleCard.maxStripColumns {
            fail("the strip should fill its \(HelmModuleCard.maxStripColumns)-column cap, "
                 + "got \(columns.count)", &ok)
        }

        // **The two labelling decisions, asserted as prohibitions rather than
        // only as the strings above.** Both are decisions about what the data
        // does *not* say, and a future edit that "tidies" a label would
        // reintroduce exactly the claim they exist to avoid:
        //
        //  - Claude's quota has no daily window at all, so "Daily" would name
        //    a reset cadence that does not exist.
        //  - `extra_usage` is a credit pool whose billing cycle `quota-axi`
        //    explicitly reports as unknown (`missing_cycle`), so nothing here
        //    may claim "month to date".
        let joined = columns.map(\.label).joined(separator: " ").lowercased()
        for banned in ["daily", "mtd", "month to date", "month-to-date"] {
            if joined.contains(banned) {
                fail("a column is labelled \"\(banned)\" - see this case's own note: the data "
                     + "does not support that claim", &ok)
            }
        }

        // The values, and the two formatting decisions in them.
        let values = columns.map(\.value)
        let expectedValues = ["90%", "69%", "100%", "$137.62", "$140"]
        if values != expectedValues {
            fail("values should be \(expectedValues), got \(values)", &ok)
        }

        // The spend cap is the ceiling, not a reading against one - a full
        // neutral bar rather than a 100%-used alarm. Asserted because the
        // obvious implementation colours every full track the same way.
        if columns.last?.state != .idle || columns.last?.fill != 1 {
            fail("the spend cap should be a full neutral track (idle, fill 1), got "
                 + "state \(String(describing: columns.last?.state)) fill "
                 + "\(String(describing: columns.last?.fill))", &ok)
        }
        // And severity really is derived, not constant: at 90/69/100 the
        // three windows must not all land on one state, or this whole column
        // of assertions would pass against a hard-coded verdict.
        let windowStates = Set(columns.prefix(3).map(\.state).map(String.init(describing:)))
        if windowStates.count < 2 {
            fail("all three window columns resolved to one state (\(windowStates)) - severity "
                 + "is not being derived from the reading", &ok)
        }

        if ok { print("  OK - \(expectedLabels.joined(separator: " | ")) -> \(values.joined(separator: " | "))") }
    }

    // MARK: 2 - GL-14: an unreadable field is a stated gap, never a zero

    private static func checkStatedGaps(_ ok: inout Bool) {
        print("\n-- claude strip: a missing window states the gap and never renders zero --")

        // Session only: no weekly, no Fable, no credit window at all - a real
        // shape (`QuotaDataSelfTest`'s own `noExtras`/`sessionOnly` payloads
        // produce it).
        let sparse = QuotaSnapshot(
            plan: nil,
            session: QuotaWindow(kind: .session, percentUsed: 12, resetsAt: nil, pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 0.4, log: "")
        let columns = HomeCanvasController.claudeStripColumns(for: sparse)

        if columns.count != HelmModuleCard.maxStripColumns {
            fail("a sparse snapshot should still render all \(HelmModuleCard.maxStripColumns) "
                 + "columns - a dropped column is a silently missing reading, not a stated gap; "
                 + "got \(columns.count)", &ok)
        }
        for column in columns.dropFirst() {
            if !column.isGap {
                fail("\"\(column.label)\" has no data but did not render as a gap", &ok)
            }
            if column.fill != nil {
                fail("\"\(column.label)\" is a gap but drew a track - a track is a reading", &ok)
            }
            // The whole point: the value must not be a number.
            if column.value.contains("0%") || column.value.contains("$0") {
                fail("\"\(column.label)\" rendered \"\(column.value)\" for an absent window - "
                     + "GL-14: unknown is never rendered as zero", &ok)
            }
        }
        // The discriminating half: the one column that *does* have a reading
        // must not have been swept up as a gap too, or this case would pass
        // against a card that gave up entirely.
        if columns[0].isGap {
            fail("the session column had a real reading but rendered as a gap", &ok)
        }
        if columns[0].value != "12%" {
            fail("the session column should read 12%, got \(columns[0].value)", &ok)
        }

        // `extra_usage` present but carrying no `limitUsd` - the shape
        // `QuotaDataSelfTest`'s real payload actually contains. The spend
        // column must read, and the cap column must state its gap.
        let noCap = QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 9, resetsAt: nil, pace: .behind),
            weekly: nil, fable: nil,
            extraUsage: QuotaCreditWindow(percentUsed: nil, spentUsd: 260.28, limitUsd: nil),
            latency: 0.4, log: "")
        let capColumns = HomeCanvasController.claudeStripColumns(for: noCap)
        if capColumns[3].value != "$260.28" || capColumns[3].isGap {
            fail("a spend figure with no cap should still read its dollars, got "
                 + "\"\(capColumns[3].value)\" (gap: \(capColumns[3].isGap))", &ok)
        }
        if capColumns[3].fill != nil {
            fail("a spend figure with no percentage drew a track from a number nobody sent", &ok)
        }
        if !capColumns[4].isGap {
            fail("a missing limitUsd must state its gap, got \"\(capColumns[4].value)\"", &ok)
        }

        if ok { print("  OK - absent windows read \"\(columns[1].value)\" with no track, reading columns unaffected") }
    }

    // MARK: 3 - it is actually painted, in both registers

    private static func checkRendersInBothThemes(_ ok: inout Bool) {
        print("\n-- claude strip: really painted, legibly, in Daylight and Dusk --")

        let spanTwo = HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing

        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            ThemeManager.shared.setTheme(theme)

            let window = OffScreenProbe.window(width: 900, height: 400,
                                               styleMask: [.titled, .resizable])
            let host = NSView(frame: window.contentLayoutRect)
            window.contentView = host

            let card = HelmModuleCard()
            card.configure(.init(title: "Claude", subtitle: "Team",
                                 symbol: "gauge.with.needle", hue: .violet,
                                 chip: .warn("Fable 100%"),
                                 body: .statusStrip(
                                    HomeCanvasController.claudeStripColumns(for: liveSnapshot()),
                                    perRow: HelmModuleCard.maxStripColumns)))
            host.addSubview(card)
            let width = card.widthAnchor.constraint(equalToConstant: spanTwo)
            width.priority = HelmDaylightPriority.contentTie
            NSLayoutConstraint.activate([
                width,
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()

            let anatomy = card.anatomyForTests

            // The card really built five columns with the agreed keys. The
            // labels are drawn uppercased, which is a render-time decision -
            // asserting it here rather than on the model is the difference
            // between "the string is right" and "the text is painted right".
            let drawn = anatomy.stripColumns.map(\.label)
            let expected = ["SESSION (5H)", "WEEK", "FABLE WEEK", "EXTRA USAGE", "SPEND CAP"]
            if drawn != expected {
                fail("\(theme.id): the card drew \(drawn), expected \(expected)", &ok)
            }

            // Every column got real horizontal room. Five columns plus four
            // 1pt hairlines inside the card's own insets - if a column is
            // near zero the strip has collapsed, which no assertion on the
            // model could see.
            let columnWidths = stripColumnWidths(in: card)
            if columnWidths.count != HelmModuleCard.maxStripColumns {
                fail("\(theme.id): found \(columnWidths.count) laid-out columns, expected "
                     + "\(HelmModuleCard.maxStripColumns)", &ok)
            }
            if let narrowest = columnWidths.min(), narrowest < 60 {
                fail("\(theme.id): the narrowest column is \(narrowest)pt - the keys would "
                     + "truncate to initials at that width", &ok)
            }
            // Equal columns, not just present ones. 1pt of slack for the
            // hairlines' own rounding.
            if let lo = columnWidths.min(), let hi = columnWidths.max(), hi - lo > 1.5 {
                fail("\(theme.id): columns range \(lo)-\(hi)pt - they should be equal, or the "
                     + "hairlines are not evenly spaced (gotcha (10))", &ok)
            }

            // Legibility, in the theme's own terms. A figure is page ink on
            // the card surface; a gap is muted. Both must clear the body-text
            // floor against what is actually behind them.
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let ratio = HelmContrast.ratio(ink, surface)
            if ratio < 4.5 {
                fail("\(theme.id): the strip's figures sit at \(String(format: "%.2f", ratio)):1 "
                     + "against the card surface, below the 4.5:1 body floor", &ok)
            }

            // And the card genuinely rasterises rather than rendering blank.
            // Both of AGENTS.md's probe rules apply: sample in the rep's own
            // colour space, and scale point coordinates into pixels.
            if !cardPaintsSomething(card) {
                fail("\(theme.id): the rendered card is a single flat colour - nothing was "
                     + "painted into it", &ok)
            }

            card.removeFromSuperview()
            print(String(format: "     %-9@ columns %.1fpt each, ink %.2f:1 on surface",
                         theme.id as NSString, columnWidths.first ?? 0, ratio))
        }

        if ok { print("  OK - five equal columns painted and legible in both registers") }
    }

    // MARK: 3b - the reset time: offered on the three resetting windows, on nothing else

    /// A fixed local day at noon, per AGENTS.md's calendar rule: a bare
    /// `Date()` would make this suite's own expectation drift with the clock,
    /// and a UTC-pinned fixture would put the formatted instant on the wrong
    /// side of a day boundary for the captain's own locale - which is the one
    /// frame "resets at" is written in.
    private static func fixtureReset(day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = hour
        components.minute = 30
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Three windows carrying real reset instants, and a credit pool that
    /// cannot carry one - the exact split the card has to honour.
    private static func resettingSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 90,
                                 resetsAt: fixtureReset(day: 23, hour: 18), pace: .ahead),
            weekly: QuotaWindow(kind: .weekly, percentUsed: 69,
                                resetsAt: fixtureReset(day: 27, hour: 9), pace: .ahead),
            fable: QuotaWindow(kind: .fable, percentUsed: 100,
                               resetsAt: fixtureReset(day: 28, hour: 14), pace: .ahead),
            extraUsage: QuotaCreditWindow(percentUsed: 98, spentUsd: 137.62, limitUsd: 140),
            latency: 1.4, log: "")
    }

    private static func checkResetTimesAreOfferedOnlyWhereTheyExist(_ ok: inout Bool) {
        print("\n-- claude strip: the reset time rides the three resetting windows only --")

        // The fixture's own discriminating power, before anything is asserted
        // against it: three genuinely different instants, so a card that
        // reused one column's sentence on all three cannot pass, and a
        // formatter that collapsed them to a constant cannot either.
        let sessionAt = fixtureReset(day: 23, hour: 18)
        let weeklyAt = fixtureReset(day: 27, hour: 9)
        let fableAt = fixtureReset(day: 28, hour: 14)
        let rendered = [sessionAt, weeklyAt, fableAt].map(QuotaWindow.resetsAtText)
        if Set(rendered).count != 3 {
            fail("the three fixture instants rendered \(rendered) - the fixture cannot "
                 + "discriminate between columns, so every assertion below would be vacuous", &ok)
        }
        // Independent of the helper: the shortened time really is in there.
        // Re-deriving the whole expectation from `resetsAtText` would assert
        // nothing about the format at all.
        let timeOnly = DateFormatter()
        timeOnly.timeStyle = .short
        timeOnly.dateStyle = .none
        if !rendered[0].contains(timeOnly.string(from: sessionAt)) {
            fail("\"\(rendered[0])\" does not carry the shortened time "
                 + "\"\(timeOnly.string(from: sessionAt))\" - the reset instant is being "
                 + "rendered to the day only, which cannot tell a captain whether a 90% "
                 + "session window turns over in a minute or in four hours", &ok)
        }

        let columns = HomeCanvasController.claudeStripColumns(for: resettingSnapshot())

        let expected = [sessionAt, weeklyAt, fableAt].map { "Resets \(QuotaWindow.resetsAtText($0))" }
        for (index, want) in expected.enumerated() {
            guard columns[index].detail == want else {
                fail("\"\(columns[index].label)\" carries detail "
                     + "\(columns[index].detail.map { "\"\($0)\"" } ?? "nil"), expected "
                     + "\"\(want)\"", &ok)
                continue
            }
        }

        // The other half, and the one a blanket "always attach something"
        // implementation fails: the credit pool has no cycle, so neither of
        // its columns may claim one (GL-14 - a fabricated reset time is a
        // fabricated reading).
        for index in 3...4 {
            if let detail = columns[index].detail {
                fail("\"\(columns[index].label)\" has no reset cycle but offered "
                     + "\"\(detail)\" - the credit pool's boundary is unknown, not soon", &ok)
            }
        }

        // The stated-gap case: a window the response did not carry at all.
        let sparse = QuotaSnapshot(
            plan: nil,
            session: QuotaWindow(kind: .session, percentUsed: 12,
                                 resetsAt: fixtureReset(day: 23, hour: 18), pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 0.4, log: "")
        let sparseColumns = HomeCanvasController.claudeStripColumns(for: sparse)
        for column in sparseColumns.dropFirst() where column.detail != nil {
            fail("gap column \"\(column.label)\" offered a reset time - a window that was "
                 + "never reported has no reset instant to offer", &ok)
        }
        // Discriminating: the one column that *does* have one still has it,
        // so this case cannot pass against a build that dropped the feature.
        if sparseColumns[0].detail == nil {
            fail("the session column carried a real resetsAt and still offered nothing", &ok)
        }

        // A window present but carrying no `resetsAt` - `QuotaSource.parse`
        // yields exactly this when the response omits the field - is a third
        // state again: a real reading, and nothing to say about its boundary.
        let noReset = QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 41, resetsAt: nil, pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 0.4, log: "")
        let noResetColumns = HomeCanvasController.claudeStripColumns(for: noReset)
        if noResetColumns[0].isGap {
            fail("a window with a reading and no resetsAt is not a stated gap", &ok)
        }
        if let detail = noResetColumns[0].detail {
            fail("a window with no resetsAt offered \"\(detail)\"", &ok)
        }

        if ok { print("  OK - \(expected[0]) | \(expected[1]) | \(expected[2]); credit columns offer nothing") }
    }

    // MARK: 3c - the affordance is on the real cell, for the pointer and for VoiceOver

    /// The behavioural half of the case above. The model carrying `detail`
    /// says nothing about whether anything was wired to it, which is exactly
    /// the shape AGENTS.md's `debug*` convention warns about - so this reads
    /// the tooltip and the accessibility help back off the **cell views the
    /// card actually built**, after a real layout pass.
    private static func checkTheResetAffordanceIsReallyWiredToTheCell(_ ok: inout Bool) {
        print("\n-- claude strip: the reset time is on the painted cell, and is not mouse-only --")

        ThemeManager.shared.setTheme(.dusk)
        let spanTwo = HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing
        let window = OffScreenProbe.window(width: 900, height: 400,
                                           styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let card = HelmModuleCard()
        card.configure(.init(title: "Claude", subtitle: "Team", symbol: "gauge.with.needle",
                             hue: .violet, chip: .warn("Fable 100%"),
                             body: .statusStrip(
                                HomeCanvasController.claudeStripColumns(for: resettingSnapshot()),
                                perRow: HelmModuleCard.maxStripColumns)))
        host.addSubview(card)
        let width = card.widthAnchor.constraint(equalToConstant: spanTwo)
        width.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            width,
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let anatomy = card.anatomyForTests
        let affordances = anatomy.stripColumnAffordances
        guard affordances.count == HelmModuleCard.maxStripColumns else {
            fail("the card exposed \(affordances.count) column affordances, expected "
                 + "\(HelmModuleCard.maxStripColumns) - the probe is not seeing the real cells", &ok)
            return
        }

        let expected = [fixtureReset(day: 23, hour: 18),
                        fixtureReset(day: 27, hour: 9),
                        fixtureReset(day: 28, hour: 14)]
            .map { "Resets \(QuotaWindow.resetsAtText($0))" }

        for (index, want) in expected.enumerated() {
            if affordances[index].toolTip != want {
                fail("column \(index) (\(anatomy.stripColumns[index].label)) painted tooltip "
                     + "\(affordances[index].toolTip.map { "\"\($0)\"" } ?? "nil"), expected "
                     + "\"\(want)\"", &ok)
            }
            // GL-16: a reading reachable only by hovering a mouse is a
            // reading a keyboard captain does not have.
            if affordances[index].help != want {
                fail("column \(index) (\(anatomy.stripColumns[index].label)) has the reset time "
                     + "as a tooltip but not as VoiceOver help - the reading is mouse-only", &ok)
            }
        }
        for index in 3...4 {
            if affordances[index].toolTip != nil || affordances[index].help != nil {
                fail("column \(index) (\(anatomy.stripColumns[index].label)) painted an "
                     + "affordance for a window with no reset cycle", &ok)
            }
        }

        // The compactness the whole tooltip decision exists to protect: the
        // card carrying three reset times is exactly as tall as the same card
        // carrying none. A second visible line per column would fail here,
        // which is the point.
        let plain = HelmModuleCard()
        plain.configure(.init(title: "Claude", subtitle: "Team", symbol: "gauge.with.needle",
                              hue: .violet, chip: .warn("Fable 100%"),
                              body: .statusStrip(
                                 HomeCanvasController.claudeStripColumns(for: liveSnapshot()),
                                 perRow: HelmModuleCard.maxStripColumns)))
        host.addSubview(plain)
        let plainWidth = plain.widthAnchor.constraint(equalToConstant: spanTwo)
        plainWidth.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            plainWidth,
            plain.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            plain.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
        ])
        host.layoutSubtreeIfNeeded()

        let withResets = anatomy.cardHeight
        let withoutResets = plain.anatomyForTests.cardHeight
        if withoutResets <= 0 {
            fail("the reference card resolved to \(withoutResets)pt - the height comparison "
                 + "below would be vacuous", &ok)
        }
        if abs(withResets - withoutResets) > 0.5 {
            fail("the card with reset times is \(withResets)pt against \(withoutResets)pt "
                 + "without - the affordance is costing the card height, which breaks the row's "
                 + "uniform height", &ok)
        }

        if ok {
            print("  OK - tooltip and VoiceOver help on the three resetting columns, "
                  + "nothing on the credit pool, card still \(withResets)pt")
        }
    }

    // MARK: 4 - the strip stays compact, and stays inside its card

    private static func checkStaysCompact(_ ok: inout Bool) {
        print("\n-- claude strip: compact by design, not clipped --")

        ThemeManager.shared.setTheme(.dusk)
        let spanTwo = HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing
        let window = OffScreenProbe.window(width: 900, height: 400,
                                           styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let card = HelmModuleCard()
        card.configure(.init(title: "Claude", subtitle: "Team", symbol: "gauge.with.needle",
                             hue: .violet, chip: .warn("Fable 100%"),
                             body: .statusStrip(
                                HomeCanvasController.claudeStripColumns(for: liveSnapshot()),
                                perRow: HelmModuleCard.maxStripColumns)))
        host.addSubview(card)
        let width = card.widthAnchor.constraint(equalToConstant: spanTwo)
        width.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            width,
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let anatomy = card.anatomyForTests

        // **The height finding this feature was scoped around.** The design
        // exploration flagged the strip as ~104pt - shorter than a module
        // card - and expected a grid restructure. It needed none: PF2 already
        // made `HelmModuleCard` size to its content above a floor, and
        // `HelmResponsiveGrid`'s `equalHeights` already makes a *row* uniform
        // rather than the whole canvas. So the strip simply sits on the floor,
        // exactly as a `.note` body does, and reads as deliberately compact.
        //
        // Asserted both ways: at the floor (not taller, which would mean it
        // has grown into a second row of something) and not clipped.
        if abs(anatomy.cardHeight - HelmModuleCard.minimumHeight) > 1.0 {
            fail("the strip card resolved to \(anatomy.cardHeight)pt, not the "
                 + "\(HelmModuleCard.minimumHeight)pt floor - if this grew on purpose, this "
                 + "case is the place to say so", &ok)
        }
        if anatomy.bodyContentHeight > anatomy.bodyAreaHeight + 0.5 {
            fail("the strip needs \(anatomy.bodyContentHeight)pt of \(anatomy.bodyAreaHeight)pt "
                 + "- it would be clipped with nothing said about it", &ok)
        }

        // The narrow form wraps rather than truncating. `packRows` degrades a
        // span-2 card to one column, and five keys in 255pt would each become
        // an initial - so the card takes the height instead, and still draws
        // all five.
        let perRowNarrow = HomeCanvasController
            .claudeStripColumnsPerRow(forCardWidth: HomeCanvasController.minModuleWidth)
        if perRowNarrow >= HelmModuleCard.maxStripColumns {
            fail("a one-column card still asks for \(perRowNarrow) columns per row - it would "
                 + "truncate every key", &ok)
        }
        let perRowWide = HomeCanvasController.claudeStripColumnsPerRow(forCardWidth: spanTwo)
        if perRowWide != HelmModuleCard.maxStripColumns {
            fail("a span-2 card should take all \(HelmModuleCard.maxStripColumns) columns in one "
                 + "row, got \(perRowWide)", &ok)
        }

        let narrowCard = HelmModuleCard()
        narrowCard.configure(.init(title: "Claude", subtitle: "Team", symbol: "gauge.with.needle",
                                   hue: .violet, chip: nil,
                                   body: .statusStrip(
                                    HomeCanvasController.claudeStripColumns(for: liveSnapshot()),
                                    perRow: perRowNarrow)))
        host.addSubview(narrowCard)
        let narrowWidth = narrowCard.widthAnchor
            .constraint(equalToConstant: HomeCanvasController.minModuleWidth)
        narrowWidth.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            narrowWidth,
            narrowCard.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            narrowCard.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
        ])
        host.layoutSubtreeIfNeeded()

        let narrowAnatomy = narrowCard.anatomyForTests
        if narrowAnatomy.stripColumns.count != HelmModuleCard.maxStripColumns {
            fail("the wrapped strip drew \(narrowAnatomy.stripColumns.count) columns - wrapping "
                 + "must cost height, never a reading", &ok)
        }
        if narrowAnatomy.bodyContentHeight > narrowAnatomy.bodyAreaHeight + 0.5 {
            fail("the wrapped strip needs \(narrowAnatomy.bodyContentHeight)pt of "
                 + "\(narrowAnatomy.bodyAreaHeight)pt and would be clipped", &ok)
        }
        // The discriminating half: wrapping really did make it taller. If the
        // two cards were the same height, nothing wrapped and the assertion
        // above would be measuring the wide layout twice.
        if narrowAnatomy.cardHeight <= anatomy.cardHeight + 1.0 {
            fail("the wrapped card (\(narrowAnatomy.cardHeight)pt) is no taller than the wide one "
                 + "(\(anatomy.cardHeight)pt) - it did not actually wrap", &ok)
        }

        if ok {
            print(String(format: "  OK - span-2 sits on the %.0fpt floor; one column wraps to "
                         + "%.0fpt with all five columns intact",
                         HelmModuleCard.minimumHeight, narrowAnatomy.cardHeight))
        }
    }

    // MARK: 5 - the card's reading has an owner of its own

    /// A **source guard**, because the behaviour it protects needs a mounted
    /// `FleetController` with a real fleet scan behind it - and because the
    /// failure it protects against is a call site being moved rather than a
    /// function misbehaving, which no amount of driving the card can see.
    ///
    /// **The bug this exists for, found during this task's own verification
    /// rather than by a captain.** The card was first fed from the reading
    /// the Morning briefing already took. That reading happens *inside*
    /// `considerMorningBriefing`, which returns early when Morning briefing
    /// is disabled (it is off by default) and again when a briefing has
    /// already been generated today. So the card would have shown its loading
    /// skeleton forever on a machine with the briefing off, and on every
    /// launch after the day's first briefing - which is most launches.
    ///
    /// `refreshQuota()` is therefore called from the refresh pass itself.
    /// This asserts it stays there.
    private static func checkTheReadingIsNotGatedOnTheBriefing(_ ok: inout Bool) {
        print("\n-- claude strip: its reading is taken by the refresh, not by the briefing --")

        guard let root = SelfTestSources.appSourceDirectory() else {
            fail("could not resolve the app source directory - this guard would pass vacuously", &ok)
            return
        }
        let path = root.appendingPathComponent("FleetController.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            fail("could not read FleetController.swift - this guard would pass vacuously", &ok)
            return
        }

        // The discriminating half first: if these anchors ever stop matching,
        // every assertion below would pass against a file that no longer says
        // what this case thinks it says.
        guard let briefingGate = source.range(of: "private func considerMorningBriefing"),
              source.contains("func refreshQuota(") else {
            fail("FleetController.swift no longer contains `considerMorningBriefing` and "
                 + "`refreshQuota` - this guard's anchors have drifted and it is asserting "
                 + "nothing", &ok)
            return
        }

        // `refreshQuota()` must be called before the briefing gate, i.e. from
        // the refresh pass, not from inside the once-a-day branch.
        let beforeTheGate = String(source[source.startIndex..<briefingGate.lowerBound])
        if !beforeTheGate.contains("self.refreshQuota()") {
            fail("`refreshQuota()` is no longer called from the refresh pass - if it moved inside "
                 + "`considerMorningBriefing`, the status card goes back to showing a skeleton "
                 + "whenever the briefing is off or already generated today", &ok)
        }

        // And it must not have become a per-navigation subprocess either: the
        // freshness window is what keeps `viewWillAppear` from spawning
        // `quota-axi` on every visit to Overview (GL-12/GL-13).
        if !source.contains("quotaFreshness") {
            fail("the quota reading has no freshness window - every Overview visit would spawn "
                 + "`quota-axi` again", &ok)
        }

        if ok { print("  OK - the reading is taken by the refresh pass, behind a freshness window") }
    }

    // MARK: 6 - the severity colours, as painted

    /// **The captain's reported "the colours look inverted".**
    ///
    /// `QuotaSeverity` is `> 90` critical / `>= 80` warning / else
    /// comfortable, over *percent used* - so a window with none of its
    /// allowance spent is comfortable and one with all of it spent is
    /// critical. That reads correctly in the source, and reading the source is
    /// exactly what this case exists not to rely on: the decision only becomes
    /// a colour when `HelmModuleRowState.color(in:)` writes a track's layer,
    /// and it only becomes a *direction* when the fill view is laid out
    /// against its bed. Both are asserted here, on a real card after a real
    /// layout pass, in both registers.
    ///
    /// The discriminating half comes first: if the two fabricated snapshots
    /// ever resolve to the same colour, every assertion below would pass
    /// vacuously against a card that had stopped distinguishing them at all.
    private static func checkSeverityIsNotInverted(_ ok: inout Bool) {
        print("\n-- claude strip: 0% used is green and empty, 100% used is red and full --")

        func snapshot(percentUsed: Double) -> QuotaSnapshot {
            QuotaSnapshot(
                plan: "team",
                session: QuotaWindow(kind: .session, percentUsed: percentUsed, resetsAt: nil, pace: .onPace),
                weekly: QuotaWindow(kind: .weekly, percentUsed: percentUsed, resetsAt: nil, pace: .onPace),
                fable: QuotaWindow(kind: .fable, percentUsed: percentUsed, resetsAt: nil, pace: .onPace),
                extraUsage: nil, latency: 1.0, log: "")
        }

        // The model-level decision, stated once so a drifted threshold fails
        // by name rather than as a colour mismatch nobody can read.
        check(QuotaSeverity(percentUsed: 0) == .comfortable,
              "0% used is not comfortable", &ok)
        check(QuotaSeverity(percentUsed: 79.9) == .comfortable,
              "79.9% used is not comfortable", &ok)
        check(QuotaSeverity(percentUsed: 80) == .warning, "80% used is not a warning", &ok)
        check(QuotaSeverity(percentUsed: 90) == .warning, "90% used is not a warning", &ok)
        check(QuotaSeverity(percentUsed: 90.1) == .critical, "90.1% used is not critical", &ok)
        check(QuotaSeverity(percentUsed: 100) == .critical, "100% used is not critical", &ok)

        let spanTwo = HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing

        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            ThemeManager.shared.setTheme(theme)

            let green = HelmModuleRowState.ok.color(in: theme)
            let red = HelmModuleRowState.bad.color(in: theme)
            if componentsMatch(green, red) {
                fail("\(theme.id): this palette paints .ok and .bad the same colour - every "
                     + "assertion below would be vacuous", &ok)
                continue
            }

            for (percentUsed, expected, name) in [(0.0, green, "green"), (100.0, red, "red")] {
                let window = OffScreenProbe.window(width: 900, height: 400,
                                                   styleMask: [.titled, .resizable])
                let host = NSView(frame: window.contentLayoutRect)
                window.contentView = host

                let card = HelmModuleCard()
                card.configure(.init(title: "Claude", subtitle: "Team",
                                     symbol: "gauge.with.needle", hue: .violet, chip: nil,
                                     body: .statusStrip(
                                        HomeCanvasController.claudeStripColumns(for: snapshot(percentUsed: percentUsed)),
                                        perRow: HelmModuleCard.maxStripColumns)))
                host.addSubview(card)
                let width = card.widthAnchor.constraint(equalToConstant: spanTwo)
                width.priority = HelmDaylightPriority.contentTie
                NSLayoutConstraint.activate([
                    width,
                    card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    card.topAnchor.constraint(equalTo: host.topAnchor),
                ])
                host.layoutSubtreeIfNeeded()

                // The three real windows - session, week, Fable week. The two
                // dollar columns are absent from this fixture on purpose:
                // `extraUsage` is `nil`, so they render as stated gaps with no
                // track at all, and a track they do not have cannot be
                // asserted.
                let tracks = card.anatomyForTests.stripTrackFills
                if tracks.count != 3 {
                    fail("\(theme.id) @ \(percentUsed)%: found \(tracks.count) painted tracks, "
                         + "expected the three quota windows - the fixture has drifted", &ok)
                    card.removeFromSuperview()
                    continue
                }

                for (index, track) in tracks.enumerated() {
                    guard let painted = track.color else {
                        fail("\(theme.id) @ \(percentUsed)%: track \(index) painted nothing", &ok)
                        continue
                    }
                    if !componentsMatch(painted, expected) {
                        fail("\(theme.id) @ \(percentUsed)% used: track \(index) is painted "
                             + "\(describe(painted)), expected \(name) \(describe(expected)) - "
                             + "the severity mapping is inverted", &ok)
                    }
                    // And the bar itself runs the right way: none of the bed
                    // at 0% used, all of it at 100%.
                    let wanted = CGFloat(percentUsed / 100)
                    if abs(track.fraction - wanted) > 0.02 {
                        fail("\(theme.id) @ \(percentUsed)% used: track \(index) covers "
                             + String(format: "%.2f", track.fraction)
                             + " of its bed, expected \(wanted) - the fill is inverted", &ok)
                    }
                }
                card.removeFromSuperview()
            }
            print("     \(theme.id): 0% used green and empty, 100% used red and full")
        }

        if ok { print("  OK - the severity mapping is not inverted, in colour or in direction") }
    }

    // MARK: 7 - the header's Refresh

    /// The card-level half of the captain's Refresh: the control is really
    /// built, really fires, really goes disabled while a reading is in
    /// flight, and - the part that is easy to get wrong - a click on it does
    /// **not** also fire the card's own "open my page" recognizer.
    ///
    /// Window-backed because all four of those are properties of a real view
    /// tree: the hit test the gesture arbitration runs needs a real window,
    /// and a disabled control is a rendered state rather than a model one.
    /// `HomeCanvasController.fillClaudeStatus` is what *supplies* this action,
    /// and it cannot be reached without mounting a canvas full of stores -
    /// `checkTheRefreshIsWiredToAForcedReading` is the source guard that
    /// covers that half instead, and says so.
    private static func checkTheHeaderCarriesARefresh(_ ok: inout Bool) {
        print("\n-- claude card: the header's Refresh --")

        ThemeManager.shared.setTheme(.dusk)
        let spanTwo = HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing

        for busy in [false, true] {
            let window = OffScreenProbe.window(width: 900, height: 400,
                                               styleMask: [.titled, .resizable])
            let host = NSView(frame: window.contentLayoutRect)
            window.contentView = host

            var pressed = 0
            var opened = 0
            let card = HelmModuleCard()
            var content = HelmModuleCard.Content(
                title: "Claude", subtitle: "Team", symbol: "gauge.with.needle",
                hue: .violet, chip: .warn("Fable 100%"),
                body: .statusStrip(
                    HomeCanvasController.claudeStripColumns(for: liveSnapshot()),
                    perRow: HelmModuleCard.maxStripColumns))
            content.headerAction = HelmModuleCard.HeaderAction(
                symbol: "arrow.clockwise", tooltip: "Refresh the Claude quota",
                isBusy: busy, handler: { pressed += 1 })
            card.configure(content)
            card.onOpen = { opened += 1 }
            host.addSubview(card)
            let width = card.widthAnchor.constraint(equalToConstant: spanTwo)
            width.priority = HelmDaylightPriority.contentTie
            NSLayoutConstraint.activate([
                width,
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()

            guard let action = card.anatomyForTests.headerAction else {
                fail("busy=\(busy): the card built no header control at all", &ok)
                continue
            }
            check(action.symbol == "arrow.clockwise",
                  "busy=\(busy): the control's glyph is \(action.symbol ?? "nothing")", &ok)
            // GL-16: an icon-only button announces its tooltip, never the raw
            // symbol name. Read back from the control, not from the content.
            check(action.announcedLabel == "Refresh the Claude quota",
                  "busy=\(busy): VoiceOver would announce "
                  + "\(action.announcedLabel ?? "nothing")", &ok)
            check(action.isEnabled == !busy,
                  "busy=\(busy): the control's enabled state is \(action.isEnabled) - the "
                  + "in-flight state is not reaching the button", &ok)

            // It really landed somewhere on screen, and inside the card.
            guard let frame = card.debugHeaderActionFrameInCard else {
                fail("busy=\(busy): the control has no frame in the card", &ok)
                continue
            }
            if frame.width < 20 || frame.height < 20 {
                fail("busy=\(busy): the control laid out \(frame.size) - too small to aim at", &ok)
            }
            if !card.bounds.insetBy(dx: -1, dy: -1).contains(frame) {
                fail("busy=\(busy): the control is at \(frame), outside the card's own "
                     + "\(card.bounds)", &ok)
            }

            // A click on it must not *also* open the card.
            if !card.debugCardClickWouldBeDeclined(at: NSPoint(x: frame.midX, y: frame.midY)) {
                fail("busy=\(busy): a click on the Refresh control would also fire the card's "
                     + "own navigation", &ok)
            }
            // The discriminating half: a click on the card's own title is
            // still a click on the card. Without this, an arbitration that
            // declined everything would pass the assertion above.
            if card.debugCardClickWouldBeDeclined(at: NSPoint(x: frame.minX - 60, y: frame.midY)) {
                fail("busy=\(busy): the arbitration declines an ordinary click on the card too - "
                     + "the whole card has stopped navigating", &ok)
            }

            let fired = card.debugActivateHeaderAction()
            check(fired == !busy,
                  "busy=\(busy): pressing the control reported \(fired)", &ok)
            check(pressed == (busy ? 0 : 1),
                  "busy=\(busy): the handler ran \(pressed) time(s)", &ok)
            check(opened == 0,
                  "busy=\(busy): pressing Refresh opened the card's destination \(opened) time(s)", &ok)

            card.removeFromSuperview()
        }

        // And a card with no action still builds none, so this is opt-in
        // rather than something every module now carries.
        let plain = HelmModuleCard()
        plain.configure(.init(title: "Health", subtitle: "background services",
                              symbol: "heart", hue: .green, chip: nil, body: .note("fine")))
        check(plain.anatomyForTests.headerAction == nil,
              "a card with no header action built one anyway", &ok)

        if ok { print("  OK - built, labelled, disabled while busy, fires once, never navigates") }
    }

    // MARK: 8 - the Refresh reaches a forced reading

    /// The source-guard half of the case above, and it is a source guard on
    /// purpose: `HomeCanvasController.fillClaudeStatus` is private on a
    /// controller whose construction reaches a dozen stores this suite has no
    /// business building (`checkCanvasConstructsNoStores` is the rule), so the
    /// wiring from the card's press to a real `quota-axi` run cannot be driven
    /// behaviourally from here. What is asserted is the chain, link by link,
    /// with every anchor checked for drift first so a renamed symbol fails
    /// loudly instead of passing vacuously.
    ///
    /// The `force` half is the whole point. `FleetController.refreshQuota`
    /// serves a cached reading for `quotaFreshness` (5 minutes), which is
    /// right for a page visit and wrong for a captain pressing Refresh - an
    /// unforced press would hand back the very reading they are asking to
    /// replace, which looks exactly like a button that does nothing.
    private static func checkTheRefreshIsWiredToAForcedReading(_ ok: inout Bool) {
        print("\n-- claude card: Refresh reaches a forced quota-axi run --")

        guard let root = SelfTestSources.appSourceDirectory() else {
            fail("could not resolve the app source directory - this guard would pass vacuously", &ok)
            return
        }
        func read(_ name: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        guard let canvas = read("HomeCanvasController.swift"),
              let shell = read("AppShellController.swift"),
              let fleet = read("FleetController.swift") else {
            fail("could not read the three files this guard is written against", &ok)
            return
        }

        // Anchors first.
        guard canvas.contains("private func fillClaudeStatus"),
              canvas.contains("var onRefreshQuota"),
              fleet.contains("func refreshQuotaNow()") else {
            fail("`fillClaudeStatus`, `onRefreshQuota` or `refreshQuotaNow` no longer exists - "
                 + "this guard's anchors have drifted and it is asserting nothing", &ok)
            return
        }

        // 1. The card offers the action, and offers it *before* the
        //    no-snapshot early return - the loading and failure states are
        //    exactly when a captain reaches for Refresh.
        guard let fill = canvas.range(of: "private func fillClaudeStatus"),
              let earlyReturn = canvas.range(of: "guard let snapshot = quotaSnapshot else {",
                                             range: fill.upperBound..<canvas.endIndex) else {
            fail("`fillClaudeStatus` no longer has its no-snapshot guard - anchor drift", &ok)
            return
        }
        let beforeTheGuard = String(canvas[fill.upperBound..<earlyReturn.lowerBound])
        if !beforeTheGuard.contains("content.headerAction") {
            fail("the Claude card's header action is set after the no-snapshot early return, so "
                 + "the loading and failure states - the two a captain most wants to re-read - "
                 + "have no Refresh", &ok)
        }

        // 2. Pressing it asks the shell rather than fetching here.
        if !canvas.contains("onRefreshQuota?()") {
            fail("the canvas's Refresh no longer calls `onRefreshQuota` - either it does nothing "
                 + "or this page has started fetching for itself", &ok)
        }
        // Comment lines stripped first: this file's own doc comments name
        // `QuotaSource.fetch()` when explaining why the canvas does not call
        // it, and a guard that matched those would fail on the very sentence
        // saying the rule is being followed.
        let canvasCode = canvas
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        if canvasCode.contains("QuotaSource.fetch") {
            fail("the canvas is calling `QuotaSource.fetch` directly - the reading is pushed in, "
                 + "never fetched here (GL-04/GL-12)", &ok)
        }

        // 3. The shell forwards it to Overview's own reading.
        if !shell.contains("homeCanvas.onRefreshQuota") || !shell.contains("refreshQuotaNow()") {
            fail("`onRefreshQuota` is not wired to `FleetController.refreshQuotaNow()` in the "
                 + "shell - the button is inert", &ok)
        }

        // 4. And that reading is forced past the freshness window.
        guard let now = fleet.range(of: "func refreshQuotaNow()") else {
            fail("`refreshQuotaNow` vanished between two reads of the same file", &ok)
            return
        }
        let body = String(fleet[now.lowerBound...].prefix(200))
        if !body.contains("refreshQuota(force: true)") {
            fail("`refreshQuotaNow` does not force the reading, so a press inside the five-minute "
                 + "freshness window hands back the cached number the captain is asking to "
                 + "replace", &ok)
        }

        if ok { print("  OK - offered in every state, forwarded, and forced past the cache") }
    }

    // MARK: Probe helpers

    /// Element-wise, never `HelmContrast.ratio` - that compares relative
    /// luminance, so two different hues of similar brightness compare equal
    /// (AGENTS.md's own note).
    private static func componentsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        let lhs = HelmContrast.components(a)
        let rhs = HelmContrast.components(b)
        return abs(lhs.0 - rhs.0) < 0.01 && abs(lhs.1 - rhs.1) < 0.01 && abs(lhs.2 - rhs.2) < 0.01
    }

    private static func describe(_ color: NSColor) -> String {
        let c = HelmContrast.components(color)
        return String(format: "(%.3f, %.3f, %.3f)", c.0, c.1, c.2)
    }


    /// The laid-out widths of the strip's column stacks, found by walking the
    /// card's real view tree rather than by re-deriving them from the width
    /// the card was given - which would assert nothing.
    private static func stripColumnWidths(in card: NSView) -> [CGFloat] {
        var found: [CGFloat] = []
        func walk(_ view: NSView) {
            // A column is a vertical stack whose first arranged subview is
            // the uppercase key label.
            if let stack = view as? NSStackView, stack.orientation == .vertical,
               let first = stack.arrangedSubviews.first as? NSTextField,
               first.stringValue == first.stringValue.uppercased(),
               !first.stringValue.isEmpty,
               stack.arrangedSubviews.count >= 2 {
                found.append(stack.frame.width)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(card)
        return found
    }

    /// Whether the card rasterises to more than one flat colour.
    ///
    /// Both of AGENTS.md's `bitmapImageRepForCachingDisplay` rules apply and
    /// are the reason this is a helper rather than three inline lines: the rep
    /// comes back in the **display's** colour space (so comparisons happen in
    /// `rep.colorSpace`, never via an sRGB conversion), and it is measured in
    /// **pixels** rather than points (so a retina machine needs the
    /// `pixelsWide / bounds.width` scale before indexing, or every sample
    /// lands in the top-left quadrant).
    private static func cardPaintsSomething(_ card: NSView) -> Bool {
        guard card.bounds.width > 4, card.bounds.height > 4,
              let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)
        else { return false }
        card.cacheDisplay(in: card.bounds, to: rep)

        let scaleX = CGFloat(rep.pixelsWide) / card.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / card.bounds.height

        var seen: Set<String> = []
        for fx in stride(from: 0.05, through: 0.95, by: 0.05) {
            for fy in stride(from: 0.05, through: 0.95, by: 0.1) {
                let x = Int(card.bounds.width * CGFloat(fx) * scaleX)
                let y = Int(card.bounds.height * CGFloat(fy) * scaleY)
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let color = rep.colorAt(x: x, y: y) else { continue }
                // In the rep's own space - no `.usingColorSpace(.sRGB)`.
                seen.insert(String(format: "%.2f-%.2f-%.2f",
                                   color.redComponent, color.greenComponent, color.blueComponent))
            }
        }
        // A card that painted its ribbon, its tile, its text and its tracks
        // has many distinct values; a blank one has one or two.
        return seen.count > 3
    }
}

#endif
