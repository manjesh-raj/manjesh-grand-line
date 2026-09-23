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
                      checkTheReadingIsNotGatedOnTheBriefing] {
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

    // MARK: Probe helpers

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
