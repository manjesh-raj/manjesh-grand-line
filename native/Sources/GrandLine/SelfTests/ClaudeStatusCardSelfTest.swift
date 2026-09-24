// Grand Line - native macOS app.
//
// Permanent, env-gated self-test for the Home page's Claude usage card -
// run via `FM_RUN_CLAUDE_STATUS_CARD_TESTS=1 .build/debug/GrandLine`.
//
// The card was a five-column "status strip" until
// `fm/grand-line-claude-usage-card-redesign` replaced it with the captain's
// sectioned mockup - a header carrying the plan, one overall verdict and the
// reading's age, a "Plan limits" section with a full-width bar per window,
// and an "Extra usage" section for the spend against its cap. Every case
// below kept the claim it was written to make and changed only the shape it
// makes it against; the suite's name is unchanged because the thing it
// guards is.
//
// **Window-backed on purpose**, and listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` accordingly: it builds a real `HelmModuleCard`
// in a real `OffScreenProbe` window, runs a real layout pass, and reads the
// rendered geometry and a real rasterised pixel back. The column-mapping half
// could be pure logic, but the two things most worth guarding here cannot be:
// that the readings are actually *painted* legibly in both registers, and
// that the bars line up and nothing is clipped at a real span-2 width.
//
// `HomeCanvasController.claudeUsageSections` is `static` precisely so the
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

        for check in [checkSectionsAndLabels, checkStatedGaps,
                      checkRendersInBothThemes, checkStaysWithinItsCard,
                      checkTheReadingIsNotGatedOnTheBriefing,
                      checkSeverityIsNotInverted,
                      checkTheHeaderCarriesARefresh,
                      checkTheHeaderStatesTheReadingsAge,
                      checkTheOverallVerdictWeighsTheSpendCap,
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

    // MARK: Probe scaffolding

    /// One real card in one real off-screen window, laid out.
    ///
    /// Every window-backed case below needs the same four lines, and the
    /// width constraint is the one that has to be right: `contentTie` (499),
    /// never required, for AGENTS.md gotcha (13)'s reason - a required width
    /// on a card is a floor on the window it is in.
    private static func mountCard(_ body: HelmModuleCard.Body,
                                  width: CGFloat,
                                  chip: HelmModuleChip? = nil,
                                  headerCaption: String? = nil)
        -> (window: NSWindow, host: NSView, card: HelmModuleCard) {
        let window = OffScreenProbe.window(width: 900, height: 700,
                                           styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let card = HelmModuleCard()
        var content = HelmModuleCard.Content(
            title: "Claude", subtitle: "Team", symbol: "gauge.with.needle",
            hue: .violet, chip: chip, body: body)
        content.headerCaption = headerCaption
        card.configure(content)
        host.addSubview(card)
        let widthConstraint = card.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            widthConstraint,
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return (window, host, card)
    }

    private static var spanTwoWidth: CGFloat {
        HomeCanvasController.minModuleWidth * 2 + HomeCanvasController.gridSpacing
    }

    /// The body the card is really given for a snapshot at a given width -
    /// one call rather than the three-line incantation at every site, so a
    /// case can never accidentally assert the wide layout while claiming the
    /// narrow one.
    private static func usageBody(for snapshot: QuotaSnapshot,
                                  now: Date = Date(),
                                  width: CGFloat) -> HelmModuleCard.Body {
        .usageReport(HomeCanvasController.claudeUsageSections(for: snapshot, now: now),
                     compact: HomeCanvasController.claudeUsageIsCompact(forCardWidth: width))
    }

    // MARK: 1 - the two sections, the rows in the captain's order, the agreed labels

    private static func checkSectionsAndLabels(_ ok: inout Bool) {
        print("\n-- claude usage: two sections, the picked row order, the agreed labels --")

        let sections = HomeCanvasController.claudeUsageSections(for: liveSnapshot())

        let sectionTitles = sections.map(\.title)
        if sectionTitles != ["Plan limits", "Extra usage"] {
            fail("section order/titles should be [Plan limits, Extra usage], got \(sectionTitles)", &ok)
        }

        guard case let .limits(rows) = sections.first?.content else {
            fail("the first section is not a limits grid - got "
                 + "\(String(describing: sections.first?.content))", &ok)
            return
        }
        let expectedTitles = ["Session (5h)", "Week", "Fable week"]
        if rows.map(\.title) != expectedTitles {
            fail("row order/titles should be \(expectedTitles), got \(rows.map(\.title))", &ok)
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
        let joined = (rows.map(\.title) + sectionTitles).joined(separator: " ").lowercased()
        for banned in ["daily", "mtd", "month to date", "month-to-date"] {
            if joined.contains(banned) {
                fail("a label reads \"\(banned)\" - see this case's own note: the data "
                     + "does not support that claim", &ok)
            }
        }

        let values = rows.map(\.value)
        if values != ["90%", "69%", "100%"] {
            fail("row values should be [90%, 69%, 100%], got \(values)", &ok)
        }
        // Severity really is derived, not constant: at 90/69/100 the three
        // rows must not all land on one state, or every assertion here would
        // pass against a hard-coded verdict.
        let rowStates = Set(rows.map(\.state).map(String.init(describing:)))
        if rowStates.count < 2 {
            fail("all three rows resolved to one state (\(rowStates)) - severity is not being "
                 + "derived from the reading", &ok)
        }

        // The spend section, and the three formatting decisions in it.
        guard case let .spend(spend) = sections.last?.content else {
            fail("the second section is not a spend figure - got "
                 + "\(String(describing: sections.last?.content))", &ok)
            return
        }
        check(spend.amount == "$137.62", "the spend reads \(spend.amount), expected $137.62", &ok)
        check(spend.against == "of $140 cap",
              "the cap line reads \(spend.against ?? "nothing"), expected \"of $140 cap\"", &ok)
        check(spend.value == "98%", "the spend percentage reads \(spend.value ?? "nothing")", &ok)
        check(spend.footnote == "$2.38 left before the cap",
              "the footnote reads \(spend.footnote ?? "nothing")", &ok)
        // The bar is a fraction of the cap, not of anything else. Asserted
        // against the two dollar figures the card is already showing, which
        // is the point of deriving it from them.
        if let fill = spend.fill, abs(fill - 137.62 / 140) > 0.001 {
            fail("the spend bar is filled \(fill), expected 137.62/140", &ok)
        } else if spend.fill == nil {
            fail("the spend has a cap and drew no bar", &ok)
        }

        // The section verdicts. Both are derived from the readings above -
        // the worst window here is Fable at 100%, and the spend is at 98% of
        // its cap - so a constant in either place fails by name.
        check(sections[0].status?.text == "Fable limit reached",
              "the Plan limits verdict reads \(sections[0].status?.text ?? "nothing"), expected "
              + "\"Fable limit reached\" at 100% used", &ok)
        check(sections[0].status?.state == .bad,
              "the Plan limits verdict is not a bad state at 100% used", &ok)
        check(sections[1].status?.text == "Near cap",
              "the Extra usage verdict reads \(sections[1].status?.text ?? "nothing"), expected "
              + "\"Near cap\" at 98% of the cap", &ok)

        if ok {
            print("  OK - \(sectionTitles.joined(separator: " | ")); rows "
                  + "\(values.joined(separator: " | ")); spend \(spend.amount) \(spend.against ?? "")")
        }
    }

    // MARK: 2 - GL-14: an unreadable field is a stated gap, never a zero

    private static func checkStatedGaps(_ ok: inout Bool) {
        print("\n-- claude usage: a missing window states the gap and never renders zero --")

        // Session only: no weekly, no Fable, no credit window at all - a real
        // shape (`QuotaDataSelfTest`'s own `noExtras`/`sessionOnly` payloads
        // produce it).
        let sparse = QuotaSnapshot(
            plan: nil,
            session: QuotaWindow(kind: .session, percentUsed: 12, resetsAt: nil, pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 0.4, log: "")
        let sections = HomeCanvasController.claudeUsageSections(for: sparse)
        guard case let .limits(rows) = sections.first?.content else {
            fail("a sparse snapshot did not produce a limits grid", &ok)
            return
        }

        if rows.count != 3 {
            fail("a sparse snapshot should still render all three window rows - a dropped row "
                 + "is a silently missing reading, not a stated gap; got \(rows.count)", &ok)
        }
        for row in rows.dropFirst() {
            if !row.isGap {
                fail("\"\(row.title)\" has no data but did not render as a gap", &ok)
            }
            if row.fill != nil {
                fail("\"\(row.title)\" is a gap but drew a bar - a bar is a reading", &ok)
            }
            // The whole point: the value must not be a number.
            if row.value.contains("0%") || row.value.contains("$0") {
                fail("\"\(row.title)\" rendered \"\(row.value)\" for an absent window - "
                     + "GL-14: unknown is never rendered as zero", &ok)
            }
        }
        // The discriminating half: the one row that *does* have a reading
        // must not have been swept up as a gap too, or this case would pass
        // against a card that gave up entirely.
        if rows[0].isGap {
            fail("the session row had a real reading but rendered as a gap", &ok)
        }
        if rows[0].value != "12%" {
            fail("the session row should read 12%, got \(rows[0].value)", &ok)
        }

        // A snapshot with no credit window at all: the Extra usage section
        // stays and states its gap, rather than vanishing. A section that
        // disappears is indistinguishable from one that was never part of
        // the design, and "we could not read your spend" is a different
        // sentence from "you have no spend".
        guard case let .note(gapText) = sections.last?.content else {
            fail("a snapshot with no extra_usage window did not state the gap - got "
                 + "\(String(describing: sections.last?.content))", &ok)
            return
        }
        if gapText.contains("$0") || gapText.contains("0%") {
            fail("the extra-usage gap reads \"\(gapText)\" - GL-14: unknown is never zero", &ok)
        }

        // `extra_usage` present but carrying no `limitUsd` - the shape
        // `QuotaDataSelfTest`'s real payload actually contains. The spend
        // must read, and the missing cap must cost the bar rather than being
        // filled in.
        let noCap = QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 9, resetsAt: nil, pace: .behind),
            weekly: nil, fable: nil,
            extraUsage: QuotaCreditWindow(percentUsed: nil, spentUsd: 260.28, limitUsd: nil),
            latency: 0.4, log: "")
        guard case let .spend(spend) = HomeCanvasController
            .claudeUsageSections(for: noCap).last?.content else {
            fail("a spend with no cap should still render its dollars", &ok)
            return
        }
        check(spend.amount == "$260.28",
              "a spend figure with no cap read \(spend.amount)", &ok)
        if spend.fill != nil || spend.value != nil {
            fail("a spend with no cap drew a bar or a percentage against a ceiling nobody "
                 + "sent - fill \(String(describing: spend.fill)), value "
                 + "\(spend.value ?? "nil")", &ok)
        }
        if spend.against?.contains("$0") == true {
            fail("a missing cap rendered as \"\(spend.against ?? "")\" - a $0 cap is a real and "
                 + "alarming value, not a synonym for unknown", &ok)
        }

        if ok {
            print("  OK - absent windows read \"\(rows[1].value)\" with no bar; a capless spend "
                  + "reads \(spend.amount) with no bar; reading rows unaffected")
        }
    }

    // MARK: 3 - it is actually painted, in both registers, with the bars aligned

    private static func checkRendersInBothThemes(_ ok: inout Bool) {
        print("\n-- claude usage: really painted, legibly, bars aligned, in Daylight and Dusk --")

        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            ThemeManager.shared.setTheme(theme)

            let mounted = mountCard(usageBody(for: liveSnapshot(), width: spanTwoWidth),
                                    width: spanTwoWidth,
                                    chip: .bad("Near spend cap"),
                                    headerCaption: "Updated 2 min ago")
            let anatomy = mounted.card.anatomyForTests

            // The card really built both sections with the agreed titles, and
            // both verdicts beside them.
            let drawnSections = anatomy.usageSections.map(\.title)
            if drawnSections != ["Plan limits", "Extra usage"] {
                fail("\(theme.id): the card drew sections \(drawnSections)", &ok)
            }
            if anatomy.usageSections.contains(where: { $0.status == nil }) {
                fail("\(theme.id): a section painted no verdict at all", &ok)
            }

            let drawnRows = anatomy.usageRows.map(\.title)
            if drawnRows != ["Session (5h)", "Week", "Fable week"] {
                fail("\(theme.id): the card drew rows \(drawnRows)", &ok)
            }

            // **The alignment claim, and the reason this body uses an
            // `NSGridView` at all** (AGENTS.md gotcha (2)): the three limit
            // bars share one grid column, so their beds must be identical -
            // and wide, because the whole arrangement exists so the bar
            // column absorbs the card's slack. A grid whose fill column
            // absorbed nothing leaves every bed sitting on its 40pt floor,
            // which is exactly the defect gotcha (2) describes in the other
            // direction.
            let limitBeds = anatomy.usageTrackFills.prefix(3).map(\.bedWidth)
            if limitBeds.count != 3 {
                fail("\(theme.id): found \(limitBeds.count) limit bars, expected 3", &ok)
            } else {
                if let lo = limitBeds.min(), let hi = limitBeds.max(), hi - lo > 1.0 {
                    fail("\(theme.id): the three bars are \(limitBeds)pt wide - they share one "
                         + "grid column and must line up (gotcha (2))", &ok)
                }
                if let width = limitBeds.first, width <= 45 {
                    fail("\(theme.id): the bars are \(width)pt - the grid's fill column absorbed "
                         + "no slack, so they are sitting on their own minimum", &ok)
                }
            }

            // Nothing that carries a reading truncated at the width it really
            // got. A reset line rendering `Resets Sun 21...` answers nothing,
            // and no assertion on the model can see it.
            for caption in anatomy.usageCaptions where caption.isTruncated {
                fail("\(theme.id): the caption \"\(caption.text)\" truncated at the width it "
                     + "was given", &ok)
            }
            for caption in anatomy.usageCaptions where !caption.isPainted {
                fail("\(theme.id): the caption \"\(caption.text)\" is not in the window or is "
                     + "hidden - it is not a visible reading", &ok)
            }

            // Legibility, in the theme's own terms. A figure is page ink on
            // the card surface; a gap is muted. Both must clear the body-text
            // floor against what is actually behind them.
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let ratio = HelmContrast.ratio(ink, surface)
            if ratio < 4.5 {
                fail("\(theme.id): the card's figures sit at \(String(format: "%.2f", ratio)):1 "
                     + "against the card surface, below the 4.5:1 body floor", &ok)
            }

            // And every severity **word** clears it too, which is the thing
            // the raw state hue would not. AGENTS.md: a `HelmTint` hue is
            // safe as a fill and is not automatically safe as text - so the
            // bars may take the hue raw and these labels may not.
            for (index, painted) in anatomy.usageStatusColors.enumerated() {
                guard let painted else {
                    fail("\(theme.id): section \(index)'s verdict has no painted colour", &ok)
                    continue
                }
                let wordRatio = HelmContrast.ratio(painted, surface)
                if wordRatio < HelmContrast.textTarget {
                    fail("\(theme.id): section \(index)'s verdict "
                         + "(\"\(anatomy.usageSections[index].status ?? "")\") is painted "
                         + "\(describe(painted)) at \(String(format: "%.2f", wordRatio)):1 on "
                         + "the card surface, below the \(HelmContrast.textTarget):1 floor - it "
                         + "is taking a fill hue as text", &ok)
                }
            }

            // And the card genuinely rasterises rather than rendering blank.
            // Both of AGENTS.md's probe rules apply: sample in the rep's own
            // colour space, and scale point coordinates into pixels.
            if !cardPaintsSomething(mounted.card) {
                fail("\(theme.id): the rendered card is a single flat colour - nothing was "
                     + "painted into it", &ok)
            }

            mounted.card.removeFromSuperview()
            print(String(format: "     %-9@ bars %.1fpt each, ink %.2f:1 on surface",
                         theme.id as NSString, limitBeds.first ?? 0, ratio))
        }

        if ok { print("  OK - both sections painted, bars aligned, every verdict legible") }
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

    /// The instant these cases pretend it is: the morning of the same day
    /// the session window turns over.
    ///
    /// Pinned rather than `Date()` because the visible line's *shape*
    /// depends on it - `QuotaWindow.resetsCompactText` drops the day for a
    /// reset later today and keeps an abbreviated weekday otherwise - so a
    /// real clock would make these cases assert a different string every
    /// day, and would exercise only whichever branch today happened to pick.
    /// This one instant puts the session row on the first branch and the
    /// two weekly rows on the second, so both are measured every run.
    ///
    /// `Calendar.current`, per AGENTS.md: the fixture pins the *day*, and
    /// "today" has to mean today where the captain is.
    private static func fixtureNow() -> Date { fixtureReset(day: 23, hour: 9) }

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

    /// The limit rows of a snapshot, or an empty list with a stated failure -
    /// every case below wants the rows and none of them wants the `guard`.
    private static func limitRows(for snapshot: QuotaSnapshot,
                                  now: Date,
                                  _ ok: inout Bool) -> [HelmModuleUsageRow] {
        guard case let .limits(rows) = HomeCanvasController
            .claudeUsageSections(for: snapshot, now: now).first?.content else {
            fail("the first section is not a limits grid - every assertion here would be "
                 + "vacuous", &ok)
            return []
        }
        return rows
    }

    private static func checkResetTimesAreOfferedOnlyWhereTheyExist(_ ok: inout Bool) {
        print("\n-- claude usage: the reset time rides the three resetting windows only --")

        // The fixture's own discriminating power, before anything is asserted
        // against it: three genuinely different instants, so a card that
        // reused one row's sentence on all three cannot pass, and a
        // formatter that collapsed them to a constant cannot either.
        let sessionAt = fixtureReset(day: 23, hour: 18)
        let weeklyAt = fixtureReset(day: 27, hour: 9)
        let fableAt = fixtureReset(day: 28, hour: 14)
        let rendered = [sessionAt, weeklyAt, fableAt].map(QuotaWindow.resetsAtText)
        if Set(rendered).count != 3 {
            fail("the three fixture instants rendered \(rendered) - the fixture cannot "
                 + "discriminate between rows, so every assertion below would be vacuous", &ok)
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

        let now = fixtureNow()
        let rows = limitRows(for: resettingSnapshot(), now: now, &ok)
        guard rows.count == 3 else { return }

        let expected = [sessionAt, weeklyAt, fableAt].map { "Resets \(QuotaWindow.resetsAtText($0))" }
        for (index, want) in expected.enumerated() where rows[index].detail != want {
            fail("\"\(rows[index].title)\" carries detail "
                 + "\(rows[index].detail.map { "\"\($0)\"" } ?? "nil"), expected \"\(want)\"", &ok)
        }

        // The short form each row also carries, which is the half that gets
        // painted. Both branches of the formatter are in here: the session
        // window turns over later on the fixture's own day and so drops the
        // day entirely, the two weekly ones keep an abbreviated weekday.
        let wantCaptions = [sessionAt, weeklyAt, fableAt]
            .map { "Resets " + QuotaWindow.resetsCompactText($0, now: now) }
        if wantCaptions[0].split(separator: " ").count > 3 {
            fail("the same-day caption rendered \"\(wantCaptions[0])\" - it is supposed to be "
                 + "\"Resets\" plus the time alone, and a longer string is what will not fit "
                 + "beside the bar", &ok)
        }
        if wantCaptions[0] == wantCaptions[1] || !wantCaptions[1].hasPrefix(
            "Resets " + weeklyAt.formatted(.dateTime.weekday(.abbreviated))) {
            fail("the fixture's two branches rendered \(wantCaptions) - a caption for another "
                 + "day must carry its weekday, or a captain reads Saturday's reset as tonight's", &ok)
        }
        for (index, want) in wantCaptions.enumerated() where rows[index].caption != want {
            fail("\"\(rows[index].title)\" carries caption "
                 + "\(rows[index].caption.map { "\"\($0)\"" } ?? "nil"), expected \"\(want)\"", &ok)
        }
        // And the caption is genuinely shorter than the sentence - if the
        // two were the same string, the row would be painting the long form
        // and the truncation check in the case below would be the only thing
        // standing between the captain and `Resets 5 Jan 20...`.
        for (index, sentence) in expected.enumerated()
        where (rows[index].caption?.count ?? 0) >= sentence.count {
            fail("row \(index)'s caption is no shorter than its sentence - the visible line "
                 + "is not the short form", &ok)
        }

        // The other half, and the one a blanket "always attach something"
        // implementation fails: the credit pool has no cycle, so the spend
        // section may not claim one (GL-14 - a fabricated reset time is a
        // fabricated reading). Its own caption is about the *cap*, never
        // about a boundary.
        guard case let .spend(spend) = HomeCanvasController
            .claudeUsageSections(for: resettingSnapshot(), now: now).last?.content else {
            fail("the spend section vanished", &ok)
            return
        }
        for line in [spend.against, spend.footnote].compactMap({ $0 })
        where line.lowercased().contains("reset") {
            fail("the spend section says \"\(line)\" - the credit pool's boundary is unknown, "
                 + "not soon", &ok)
        }

        // The stated-gap case: a window the response did not carry at all.
        let sparse = QuotaSnapshot(
            plan: nil,
            session: QuotaWindow(kind: .session, percentUsed: 12,
                                 resetsAt: fixtureReset(day: 23, hour: 18), pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 0.4, log: "")
        let sparseRows = limitRows(for: sparse, now: now, &ok)
        for row in sparseRows.dropFirst()
        where row.detail != nil || row.caption != nil {
            fail("gap row \"\(row.title)\" offered a reset time - a window that was never "
                 + "reported has no reset instant to offer", &ok)
        }
        // Discriminating: the one row that *does* have one still has it, so
        // this case cannot pass against a build that dropped the feature.
        if sparseRows.first?.detail == nil || sparseRows.first?.caption == nil {
            fail("the session row carried a real resetsAt and still offered nothing", &ok)
        }

        // A window present but carrying no `resetsAt` - `QuotaSource.parse`
        // yields exactly this when the response omits the field - is a third
        // state again: a real reading, and nothing to say about its boundary.
        let noReset = QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 41, resetsAt: nil, pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 0.4, log: "")
        let noResetRows = limitRows(for: noReset, now: now, &ok)
        if noResetRows.first?.isGap == true {
            fail("a window with a reading and no resetsAt is not a stated gap", &ok)
        }
        if let detail = noResetRows.first?.detail {
            fail("a window with no resetsAt offered \"\(detail)\"", &ok)
        }
        if let caption = noResetRows.first?.caption {
            fail("a window with no resetsAt painted \"\(caption)\"", &ok)
        }

        if ok {
            print("  OK - \(expected[0]) | \(expected[1]) | \(expected[2]); painted as "
                  + "\(wantCaptions.joined(separator: " | ")); the spend claims no boundary")
        }
    }

    // MARK: 3c - the affordance is on the real row, for the pointer and for VoiceOver

    /// The behavioural half of the case above. The model carrying `detail`
    /// and `caption` says nothing about whether anything was wired to
    /// either, which is exactly the shape AGENTS.md's `debug*` convention
    /// warns about - so this reads the painted line, the tooltip and the
    /// accessibility help back off the **row views the card actually
    /// built**, after a real layout pass.
    ///
    /// The captain's own instruction on the first version of this feature is
    /// what the painted half is for: a reading you have to hover each row to
    /// collect is a reading they do not have. So the short line is painted
    /// and the full sentence stays one hover (or one VoiceOver stop) away.
    private static func checkTheResetAffordanceIsReallyWiredToTheCell(_ ok: inout Bool) {
        print("\n-- claude usage: the reset time is painted on the row, not hidden behind a hover --")

        ThemeManager.shared.setTheme(.dusk)
        let mounted = mountCard(usageBody(for: resettingSnapshot(), now: fixtureNow(),
                                          width: spanTwoWidth),
                                width: spanTwoWidth, chip: .bad("Near spend cap"))
        let anatomy = mounted.card.anatomyForTests

        let affordances = anatomy.usageRowAffordances
        guard affordances.count == 3 else {
            fail("the card exposed \(affordances.count) row affordances, expected 3 - the probe "
                 + "is not seeing the real rows", &ok)
            return
        }

        let expected = [fixtureReset(day: 23, hour: 18),
                        fixtureReset(day: 27, hour: 9),
                        fixtureReset(day: 28, hour: 14)]
            .map { "Resets \(QuotaWindow.resetsAtText($0))" }

        for (index, want) in expected.enumerated() {
            if affordances[index].toolTip != want {
                fail("row \(index) (\(anatomy.usageRows[index].title)) painted tooltip "
                     + "\(affordances[index].toolTip.map { "\"\($0)\"" } ?? "nil"), expected "
                     + "\"\(want)\"", &ok)
            }
            // GL-16: a reading reachable only by hovering a mouse is a
            // reading a keyboard captain does not have.
            if affordances[index].help != want {
                fail("row \(index) (\(anatomy.usageRows[index].title)) has the reset time as a "
                     + "tooltip but not as VoiceOver help - the reading is mouse-only", &ok)
            }
        }

        // **The captain's actual ask**: the reading is on the card, in real
        // painted text, with no pointer involved. Read off the labels the
        // card built - `caption` reaching the model proves nothing about
        // whether a label was ever added to a row.
        let wantCaptions = [fixtureReset(day: 23, hour: 18),
                            fixtureReset(day: 27, hour: 9),
                            fixtureReset(day: 28, hour: 14)]
            .map { "Resets " + QuotaWindow.resetsCompactText($0, now: fixtureNow()) }
        let painted = anatomy.usageCaptions.map(\.text)
        for want in wantCaptions where !painted.contains(want) {
            fail("no painted caption reads \"\(want)\" - the reset time is back to being "
                 + "hover-only. Painted: \(painted)", &ok)
        }
        for caption in anatomy.usageCaptions {
            if !caption.isPainted {
                fail("the caption \"\(caption.text)\" exists but is not in the window or is "
                     + "hidden - it is not a visible reading", &ok)
            }
            // The reason the line is the short form and not the sentence: a
            // truncated reset time is worse than none, because
            // `Resets 5 Jan 20...` answers nothing.
            if caption.isTruncated {
                fail("the caption \"\(caption.text)\" truncated at the width it was given - "
                     + "shorten it, do not ship an ellipsis where the answer goes", &ok)
            }
        }

        // The height the painted lines cost, measured against the same card
        // built from a snapshot whose windows carry no reset instant at all -
        // so the only difference between the two is the lines.
        //
        // Asserted in both directions, because each catches a different
        // defect. It must be **taller**, or the lines are not being painted
        // (and every check above could still pass against labels added to no
        // stack). And it must be taller by no more than one caption line per
        // row, or a row has gained something other than the one line this
        // feature is allowed - a wrapped sentence, say, which is exactly what
        // the long form would do if a future caller passed it here.
        //
        // In the **wide** layout a caption sits beside the bar in its own
        // grid column, so it costs no height at all - which is why this
        // measurement is taken in the compact layout, where it genuinely is
        // an extra line.
        let narrow = HomeCanvasController.minModuleWidth
        let withResets = mountCard(usageBody(for: resettingSnapshot(), now: fixtureNow(),
                                             width: narrow), width: narrow)
        let withoutResets = mountCard(usageBody(for: liveSnapshot(), width: narrow), width: narrow)
        let withAnatomy = withResets.card.anatomyForTests
        let withoutAnatomy = withoutResets.card.anatomyForTests

        // The reference really is the no-caption case, or the comparison is
        // measuring the same card twice.
        let referenceResetCaptions = withoutAnatomy.usageCaptions
            .filter { $0.text.hasPrefix("Resets") }
        if !referenceResetCaptions.isEmpty {
            fail("the reference card painted \(referenceResetCaptions.count) reset lines - its "
                 + "snapshot is supposed to carry no reset instants at all, so this comparison "
                 + "would be vacuous", &ok)
        }
        if withoutAnatomy.cardHeight <= 0 {
            fail("the reference card resolved to \(withoutAnatomy.cardHeight)pt - the height "
                 + "comparison below would be vacuous", &ok)
        }
        let oneLine = HelmType.captionSmall().boundingRectForFont.height + HelmMetrics.s1
        let grew = withAnatomy.cardHeight - withoutAnatomy.cardHeight
        if grew <= 0.5 {
            fail("the compact card with reset times is \(withAnatomy.cardHeight)pt against "
                 + "\(withoutAnatomy.cardHeight)pt without - it did not grow at all, so the "
                 + "lines are not being laid out", &ok)
        }
        if grew > oneLine * 3 + 3 {
            fail("the reset lines cost the card \(grew)pt, more than the three caption lines "
                 + "(\(oneLine * 3)pt) they are allowed - a row is carrying more than a single "
                 + "short line, or a line is wrapping", &ok)
        }
        if withAnatomy.bodyContentHeight > withAnatomy.bodyAreaHeight + 0.5 {
            fail("the compact report with reset lines needs \(withAnatomy.bodyContentHeight)pt "
                 + "of \(withAnatomy.bodyAreaHeight)pt - it would be clipped", &ok)
        }

        if ok {
            print(String(format: "  OK - three reset lines painted (%@), full sentence still on "
                         + "the tooltip and VoiceOver help; compact card %.0fpt against %.0fpt "
                         + "without (+%.0f, three caption lines)",
                         wantCaptions.joined(separator: " | ") as NSString,
                         withAnatomy.cardHeight, withoutAnatomy.cardHeight, grew))
        }
    }

    // MARK: 4 - the report grows the card rather than being clipped, at both widths

    private static func checkStaysWithinItsCard(_ ok: inout Bool) {
        print("\n-- claude usage: taller than the strip was, and clipped at neither width --")

        ThemeManager.shared.setTheme(.dusk)

        let wide = mountCard(usageBody(for: resettingSnapshot(), now: fixtureNow(),
                                       width: spanTwoWidth),
                             width: spanTwoWidth, chip: .bad("Near spend cap"),
                             headerCaption: "Updated 2 min ago")
        let wideAnatomy = wide.card.anatomyForTests

        // **The height decision this redesign was scoped around, asserted
        // rather than assumed.** The captain's instruction was explicit: "if
        // the resulting card ends up a bit taller than today's, that is fine
        // - do not compress the new design to fit the old height". So this
        // card genuinely is past the floor, and that is the intended state
        // rather than an overflow - `HelmModuleCard.minimumHeight` is a floor
        // (PF2), and `HelmResponsiveGrid`'s `equalHeights` pulls the card's
        // whole grid row up with it.
        if wideAnatomy.cardHeight <= HelmModuleCard.minimumHeight + 1.0 {
            fail("the report card resolved to \(wideAnatomy.cardHeight)pt, at or under the "
                 + "\(HelmModuleCard.minimumHeight)pt floor - the sections have collapsed into "
                 + "something the size of the strip they replaced", &ok)
        }
        // And the one thing a taller card must still be: not clipped. The
        // card's own `masksToBounds` would swallow the overflow silently.
        if wideAnatomy.bodyContentHeight > wideAnatomy.bodyAreaHeight + 0.5 {
            fail("the report needs \(wideAnatomy.bodyContentHeight)pt of "
                 + "\(wideAnatomy.bodyAreaHeight)pt - it would be clipped with nothing said "
                 + "about it", &ok)
        }

        // The narrow reflow. `packRows` degrades a span-2 card to one column,
        // and at that width the grid's three content columns would leave the
        // bar a stub - so the row stacks instead, and still draws everything.
        if !HomeCanvasController.claudeUsageIsCompact(
            forCardWidth: HomeCanvasController.minModuleWidth) {
            fail("a one-column card still asks for the wide grid - its bars would be stubs", &ok)
        }
        if HomeCanvasController.claudeUsageIsCompact(forCardWidth: spanTwoWidth) {
            fail("a span-2 card asked for the compact reflow - it has the width for the grid", &ok)
        }

        let narrow = mountCard(usageBody(for: resettingSnapshot(), now: fixtureNow(),
                                         width: HomeCanvasController.minModuleWidth),
                               width: HomeCanvasController.minModuleWidth,
                               chip: .bad("Near spend cap"))
        let narrowAnatomy = narrow.card.anatomyForTests

        // Nothing is dropped: the compact layout costs height, never a
        // reading. This is the property the strip's own wrap already had.
        if narrowAnatomy.usageRows.map(\.title) != wideAnatomy.usageRows.map(\.title) {
            fail("the compact layout drew rows \(narrowAnatomy.usageRows.map(\.title)) against "
                 + "the wide layout's \(wideAnatomy.usageRows.map(\.title)) - reflowing must "
                 + "cost height, never a reading", &ok)
        }
        if narrowAnatomy.usageCaptions.count != wideAnatomy.usageCaptions.count {
            fail("the compact layout painted \(narrowAnatomy.usageCaptions.count) captions "
                 + "against the wide layout's \(wideAnatomy.usageCaptions.count)", &ok)
        }
        if narrowAnatomy.bodyContentHeight > narrowAnatomy.bodyAreaHeight + 0.5 {
            fail("the compact report needs \(narrowAnatomy.bodyContentHeight)pt of "
                 + "\(narrowAnatomy.bodyAreaHeight)pt and would be clipped", &ok)
        }
        // The discriminating half: reflowing really did make it taller. If
        // the two cards were the same height, nothing reflowed and the
        // assertions above would be measuring the wide layout twice.
        if narrowAnatomy.cardHeight <= wideAnatomy.cardHeight + 1.0 {
            fail("the compact card (\(narrowAnatomy.cardHeight)pt) is no taller than the wide "
                 + "one (\(wideAnatomy.cardHeight)pt) - it did not actually reflow", &ok)
        }
        // And the compact bars really do span the card, which is the whole
        // point of moving the caption off their row.
        //
        // Measured against this card's **own** body width, not against the
        // wide card's bar: the wide card is twice as wide, so its bar column
        // is legitimately wider in absolute points. The claim here is that
        // the compact bar takes every point its card has, which a bar still
        // sharing its row with a caption could not.
        let compactBody = HomeCanvasController.minModuleWidth
            - HelmModuleCard.horizontalInset * 2
        if let bed = narrowAnatomy.usageTrackFills.first?.bedWidth, bed < compactBody - 1 {
            fail("the compact bar is \(bed)pt of the \(compactBody)pt its card's body has - "
                 + "the caption is still taking a column beside it", &ok)
        }

        if ok {
            print(String(format: "  OK - span-2 %.0fpt (floor %.0fpt) with %.0fpt bars, one "
                         + "column reflows to %.0fpt with full-width bars and every reading "
                         + "intact, neither clipped",
                         wideAnatomy.cardHeight, HelmModuleCard.minimumHeight,
                         wideAnatomy.usageTrackFills.first?.bedWidth ?? 0,
                         narrowAnatomy.cardHeight))
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
        print("\n-- claude usage: its reading is taken by the refresh, not by the briefing --")

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
    /// a colour when `HelmModuleRowState.color(in:)` writes a bar's layer,
    /// and it only becomes a *direction* when the fill view is laid out
    /// against its bed. Both are asserted here, on a real card after a real
    /// layout pass, in both registers.
    ///
    /// The discriminating half comes first: if the two fabricated snapshots
    /// ever resolve to the same colour, every assertion below would pass
    /// vacuously against a card that had stopped distinguishing them at all.
    private static func checkSeverityIsNotInverted(_ ok: inout Bool) {
        print("\n-- claude usage: 0% used is green and empty, 100% used is red and full --")

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
                let mounted = mountCard(
                    usageBody(for: snapshot(percentUsed: percentUsed), width: spanTwoWidth),
                    width: spanTwoWidth)

                // The three real windows - session, week, Fable week. The
                // spend section is absent from this fixture on purpose:
                // `extraUsage` is `nil`, so it renders as a stated gap with
                // no bar at all, and a bar it does not have cannot be
                // asserted.
                let tracks = mounted.card.anatomyForTests.usageTrackFills
                if tracks.count != 3 {
                    fail("\(theme.id) @ \(percentUsed)%: found \(tracks.count) painted bars, "
                         + "expected the three quota windows - the fixture has drifted", &ok)
                    mounted.card.removeFromSuperview()
                    continue
                }

                for (index, track) in tracks.enumerated() {
                    guard let painted = track.color else {
                        fail("\(theme.id) @ \(percentUsed)%: bar \(index) painted nothing", &ok)
                        continue
                    }
                    if !componentsMatch(painted, expected) {
                        fail("\(theme.id) @ \(percentUsed)% used: bar \(index) is painted "
                             + "\(describe(painted)), expected \(name) \(describe(expected)) - "
                             + "the severity mapping is inverted", &ok)
                    }
                    // And the bar itself runs the right way: none of the bed
                    // at 0% used, all of it at 100%.
                    let wanted = CGFloat(percentUsed / 100)
                    if abs(track.fraction - wanted) > 0.02 {
                        fail("\(theme.id) @ \(percentUsed)% used: bar \(index) covers "
                             + String(format: "%.2f", track.fraction)
                             + " of its bed, expected \(wanted) - the fill is inverted", &ok)
                    }
                }
                mounted.card.removeFromSuperview()
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
        let spanTwo = spanTwoWidth

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
                body: usageBody(for: liveSnapshot(), width: spanTwoWidth))
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

    // MARK: 7b - the header states how old the reading is

    /// The mockup's `Updated 2 min ago`, which is the one genuinely new
    /// thing in the header.
    ///
    /// It matters more than it looks: every other figure on this card is a
    /// claim about *now*, and `FleetController` serves a cached reading for
    /// five minutes by design. A card that shows a two-hour-old reading with
    /// no way to tell is the same class of dishonesty GL-14 is about - and
    /// the caption is also what makes the Refresh beside it meaningful.
    ///
    /// Window-backed because both halves of the claim are rendering: the
    /// label has to be in the hierarchy and unhidden, and it has to reach
    /// VoiceOver through the card's own spoken label rather than being a
    /// decoration the mouse can read and a keyboard cannot (GL-16).
    private static func checkTheHeaderStatesTheReadingsAge(_ ok: inout Bool) {
        print("\n-- claude card: the header says how old the reading is --")

        // The wording, across the four branches, from one injected clock.
        // AGENTS.md's rule: a case that drove a fabricated instant and then
        // measured the real elapsed time would be testing two clocks rather
        // than the feature.
        let now = fixtureNow()
        let cases: [(TimeInterval, String)] = [
            (5, "Updated just now"),
            (59, "Updated just now"),
            (60, "Updated 1 min ago"),
            (125, "Updated 2 min ago"),
            (3 * 3600 + 60, "Updated 3h ago"),
            (50 * 3600, "Updated 2d ago"),
        ]
        for (age, want) in cases {
            let got = HomeCanvasController.claudeUpdatedText(
                fetchedAt: now.addingTimeInterval(-age), now: now)
            check(got == want, "a reading \(age)s old reads \"\(got)\", expected \"\(want)\"", &ok)
        }
        // Discriminating: the four branches really are four different
        // strings, so a constant cannot pass the table above.
        let distinct = Set(cases.map { HomeCanvasController.claudeUpdatedText(
            fetchedAt: now.addingTimeInterval(-$0.0), now: now) })
        if distinct.count < 4 {
            fail("the age wording collapsed to \(distinct) - it is not derived from the "
                 + "interval", &ok)
        }

        ThemeManager.shared.setTheme(.dusk)
        let mounted = mountCard(usageBody(for: liveSnapshot(), width: spanTwoWidth),
                                width: spanTwoWidth, chip: .bad("Near spend cap"),
                                headerCaption: "Updated 2 min ago")
        let anatomy = mounted.card.anatomyForTests

        guard let caption = anatomy.headerCaption else {
            fail("the card was given a header caption and built none", &ok)
            return
        }
        check(caption.text == "Updated 2 min ago",
              "the header painted \"\(caption.text)\"", &ok)
        check(caption.isPainted,
              "the header caption exists but is not in the window or is hidden", &ok)
        // GL-16: the freshness of the reading is part of the reading.
        if anatomy.accessibilityLabel?.contains("Updated 2 min ago") != true {
            fail("VoiceOver would announce \"\(anatomy.accessibilityLabel ?? "nothing")\" - the "
                 + "reading\'s age is visible to the eye and not to the ear", &ok)
        }

        // And it is opt-in: a card that carries no caption builds none, so
        // the header of every other module is exactly the shape it was.
        let plain = HelmModuleCard()
        plain.configure(.init(title: "Health", subtitle: "background services",
                              symbol: "heart", hue: .green, chip: nil, body: .note("fine")))
        check(plain.anatomyForTests.headerCaption == nil,
              "a card with no header caption built one anyway", &ok)

        if ok { print("  OK - painted, announced, and carried by this card alone") }
    }

    // MARK: 7c - the overall verdict weighs the spend cap, not only the windows

    /// The header pill is the card\'s one summary, and the redesign widened
    /// what it is allowed to see.
    ///
    /// The strip\'s chip only ever looked at the three resetting windows, so
    /// a card whose spend was a dollar off its cap could read "Comfortable".
    /// The captain\'s own mockup names that case - it is the state the target
    /// screenshot is *in*, three comfortable windows under a "Near spend cap"
    /// pill - and it is the right call: a window refills on a clock and a cap
    /// does not.
    ///
    /// Pure logic, deliberately: this is a decision about which of two
    /// severities wins, and nothing about it is rendering. The pill\'s own
    /// painting is covered by `checkRendersInBothThemes`.
    private static func checkTheOverallVerdictWeighsTheSpendCap(_ ok: inout Bool) {
        print("\n-- claude card: one verdict, weighing the windows and the cap together --")

        func snapshot(window: Double, spent: Double?, cap: Double?) -> QuotaSnapshot {
            QuotaSnapshot(
                plan: "team",
                session: QuotaWindow(kind: .session, percentUsed: window, resetsAt: nil, pace: .onPace),
                weekly: QuotaWindow(kind: .weekly, percentUsed: 10, resetsAt: nil, pace: .onPace),
                fable: nil,
                extraUsage: spent.map {
                    QuotaCreditWindow(percentUsed: nil, spentUsd: $0, limitUsd: cap)
                },
                latency: 1.0, log: "")
        }

        // **The case the mockup is drawn in, and the regression this exists
        // for**: every window comfortable, the spend at 98% of its cap. The
        // old chip read "Comfortable" here.
        let nearCap = HomeCanvasController.claudeChip(for: snapshot(window: 13, spent: 137.62, cap: 140))
        check(nearCap?.text == "Near spend cap",
              "three comfortable windows under a 98%-spent cap read "
              + "\(nearCap?.text ?? "nothing"), expected \"Near spend cap\"", &ok)
        check(nearCap?.kind == .bad,
              "\"Near spend cap\" is not a bad-state pill", &ok)

        // At the cap, it says so outright rather than approximating.
        check(HomeCanvasController.claudeChip(for: snapshot(window: 13, spent: 140, cap: 140))?.text
                == "Spend cap reached",
              "a spend at its cap does not say so", &ok)

        // Warning territory on the spend, with the windows still fine.
        let climbing = HomeCanvasController.claudeChip(for: snapshot(window: 13, spent: 119, cap: 140))
        check(climbing?.text == "Extra usage climbing",
              "a spend at 85% of its cap reads \(climbing?.text ?? "nothing")", &ok)
        check(climbing?.kind == .warn, "\"Extra usage climbing\" is not a warn-state pill", &ok)

        // A window in worse shape than the spend still wins, so the new rule
        // did not simply replace one blind spot with the opposite one.
        let windowWins = HomeCanvasController.claudeChip(for: snapshot(window: 95, spent: 10, cap: 140))
        check(windowWins?.text == "Session limit close",
              "a 95%-used window under a comfortable spend reads "
              + "\(windowWins?.text ?? "nothing")", &ok)
        check(HomeCanvasController.claudeChip(for: snapshot(window: 100, spent: 10, cap: 140))?.text
                == "Session limit reached",
              "a fully-used window does not say so", &ok)

        // And with nothing wrong anywhere, one word.
        let calm = HomeCanvasController.claudeChip(for: snapshot(window: 13, spent: 10, cap: 140))
        check(calm?.text == "Comfortable" && calm?.kind == .ok,
              "a card with nothing wrong reads \(calm?.text ?? "nothing")", &ok)

        // A spend with no cap cannot be near one - the verdict falls back to
        // the windows rather than inventing a ceiling (GL-14).
        check(HomeCanvasController.claudeChip(for: snapshot(window: 13, spent: 9999, cap: nil))?.text
                == "Comfortable",
              "a capless spend produced a cap verdict - there is no ceiling to be near", &ok)

        if ok { print("  OK - the cap wins when it is the worse news, and only then") }
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
