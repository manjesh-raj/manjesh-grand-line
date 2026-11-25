// Grand Line - native macOS app.
//
// Daylight Phase 2's own suite: the shell (floating bar + home canvas +
// drill headers) that replaced the icon rail and the top bar.
//
// The migration spec names four things this has to pin (§8's "Testing
// requirements per phase"), and each maps to a case below:
//
//   1. **Module anatomy** - a module really is §6.1's card (less the ribbon
//      the UI/UX revamp retired): gradient
//      tile, header text, optional chip, one of the body kinds, and one
//      clickable target that announces as a button.
//   2. **Uniform card sizing** - every card the same width, rows
//      never overflow their column count, and a short row is padded rather
//      than stretched.
//   3. **The space table matches the locked decision exactly** - restated
//      here as literal data, so a future edit to `DaylightModule.space` that
//      disagrees with the captain's decision fails rather than ships.
//   4. **The canvas constructs no store** - a source guard, because the
//      failure it prevents (a fetch on every hub visit) is invisible in a
//      passing behavioural test and only shows up as the app feeling slow.
//
// Plus two this phase added for its own risk profile:
//
//   5. **The bar cannot cap the window** - AGENTS.md gotcha (13) is this
//      codebase's most expensive recurring bug, and a full-width bar is the
//      most dangerous new surface for it. Measured against a real window, not
//      reasoned about. (`AppShellBodyWidthSelfTest` covers the body half.)
//   6. **No `NSVisualEffectView` in the bar** - gotcha (8), which §6.3 calls
//      out by name. Checked structurally rather than by eye.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_MODULE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightModuleSelfTest {

    static func run() -> Bool {
        // Each check gets its own flag and reports its own verdict, so one
        // failure never silences the seven checks after it - a suite that
        // stops printing OK lines after the first FAIL hides how much else is
        // broken, which is the opposite of what a regression run is for.
        // R5-UI-08: Home leaves the Morning briefing card off while the
        // briefing is off and has nothing on record. The checks here measure
        // the five-card Home, so the briefing is on, in this process's own
        // suite domain, and put back after.
        let briefingWasOn = AppSettings.shared.morningBriefingEnabled
        AppSettings.shared.morningBriefingEnabled = true
        defer { AppSettings.shared.morningBriefingEnabled = briefingWasOn }
        var allOK = true
        for check in [checkSpaceTable, checkSymbolsResolve, checkUniformCardSizing,
                      checkUniformCardHeight, checkRowsEqualiseCardHeights,
                      checkAnExemptCardSizesToItsOwnContent,
                      checkNoCardIsAWindowFloor,
                      checkModuleAnatomy, checkCanvasConstructsNoStores,
                      checkNoNewPolling] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightModuleSelfTest: all checks passed"
                    : "DaylightModuleSelfTest: FAILED")
        return allOK
    }

    // MARK: 3 - the locked space table

    /// The captain's locked decision, restated as literal data.
    ///
    /// Deliberately typed out again rather than derived from
    /// `DaylightModule.space`: a test that reads the same table it is checking
    /// asserts nothing. These five lines are the decision block at the top of
    /// `daylight-ui-design.md`, verbatim.
    private static let lockedMembership: [DaylightSpace: Set<DaylightModule>] = [
        // `fm/grandline-devops-space-and-diagram-tool` added `.commandLibrary`
        // here, out of `.stores` below - the captain's own correction after
        // using the page `fm/grandline-tasks-kanban-devops-split` shipped. It
        // is the deliberate table change `DaylightSpace.swift`'s own doc
        // comment says to make together with `DaylightModule.space`.
        // `fm/grandline-home-card-reorg` added `.strawHat` here, out of the
        // Overview-only set below - the captain's own ask after reviewing the
        // live Home page: the crew is something he commands, so the card
        // belongs beside the Console and the task queue. The deliberate table
        // change `DaylightSpace.swift`'s own doc comment says to make together
        // with `DaylightModule.space`.
        // R5-UX-07 added the Calendar's next-up card and the Focus timer.
        .command: [.console, .tasks, .mergeQueue, .commandLibrary, .strawHat, .calendar, .focusTimer],
        // `fm/grandline-k8s-cluster-tail` added `.kubernetes` here - the
        // deliberate table change this file's own doc comment says to make
        // together with `DaylightModule.space`. The scout report's own
        // placement note puts it in Operations, beside Log Analyzer: it is the
        // running systems seen from a different angle.
        .operations: [.hosts, .logAnalyzer, .kubernetes, .health, .schedules],
        // `fm/grandline-docs-split-runbooks-postmortems` added Runbooks and
        // Postmortems here, promoted out of `DocsController`'s former tabs
        // into their own destinations - the deliberate table change this
        // file's own doc comment says to make together with the test.
        // `fm/grand-line-whiteboard-excalidraw` added `.whiteboard` here for
        // the same reason and by the same rule: a whiteboard is a thinking
        // surface, which belongs on the same shelf as the reference material
        // it gets used next to. `fm/grandline-sticky-board` added
        // `.stickyBoard` for the identical reason - a quick-notes corkboard -
        // and `fm/grandline-monaco-code-preview` added `.codePreview` by that
        // same rule: a place to read a pasted snippet properly is reference
        // material, on the same shelf as the docs and runbooks it sits beside.
        // `fm/implement-grand-line-secrets-vault-poneg-ad` originally put
        // `.poneglyph` in `.engineering` (Automic Vault's hardening panel had
        // moved out of `.vault` into Setup, so its module moved from Stores to
        // Engineering with it); `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`
        // then swapped which feature each of `.vault`/`.poneglyph` shows (see
        // `VaultController.swift`'s header) with no space-table change, since a
        // destination's *slot* is independent of which controller populates
        // it. `fm/move-poneglyph-to-stores-space-282a` is the captain's own
        // later ask to move it here, beside the other Stores utilities.
        .stores: [.vault, .docs, .notebook, .readingList, .runbooks, .postmortems, .tools, .dictation, .whiteboard, .stickyBoard, .codePreview, .poneglyph],
        .engineering: [.updates, .bootstrap, .automation, .githubSync, .settings],
    ]

    /// The modules that appear on Overview and nowhere else.
    ///
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` made this three: the
    /// captain asked for the Straw Hat Pirates chat to be its own Overview
    /// card, and it has no natural space of its own (not Command, not
    /// Operations, not a Store, not a Setup page) - which is exactly the "no
    /// other home" property the briefing and the fleet board have.
    ///
    /// `fm/grandline-claude-status-card-implement` makes this four.
    /// `.claudeStatus` has the same "no other home" property as the other
    /// three - Claude's quota is not a Command surface, an Operations one, a
    /// Store or a Setup page - and the captain asked for the status strip on
    /// the launch landing specifically.
    ///
    /// `fm/grandline-home-card-reorg` takes it back to three. `.strawHat`
    /// left this set the moment it gained a real space: the captain asked for
    /// the crew card on Command rather than on Home, so it is in
    /// `lockedMembership[.command]` above instead.
    private static let overviewOnly: Set<DaylightModule> =
        [.briefing, .claudeStatus, .fleet]

    private static func checkSpaceTable(_ ok: inout Bool) {
        print("\n-- space table: the table matches the locked captain decision --")

        for (space, expected) in lockedMembership {
            let actual = Set(DaylightModule.allCases.filter { $0.space == space })
            if actual != expected {
                fail("\(space.rawValue): expected \(expected.map(\.rawValue).sorted()), got \(actual.map(\.rawValue).sorted())", &ok)
            }
        }

        let actualOverviewOnly = Set(DaylightModule.allCases.filter { $0.space == nil })
        if actualOverviewOnly != overviewOnly {
            fail("Overview-only set should be \(overviewOnly.map(\.rawValue).sorted()), got \(actualOverviewOnly.map(\.rawValue).sorted())", &ok)
        }

        // P-03 of the 2026-11-25 full review removed the floating bar's
        // space filter, and with it the checks on what each space's canvas
        // showed (`isVisible(in:)`, Overview's trimmed set). The table itself
        // still says which space a card belongs to.

        // §5.4's copy, and the shortcut indices `⌘1`…`⌘5` carry.
        // Review #3 §7 renamed the first pill "Overview" -> "Home"; the
        // literal list is restated here rather than derived, exactly as
        // `checkSpaceTable`'s own header requires. A "Today" pill sat
        // leftmost for a while and was removed with its page
        // (`fm/grandline-remove-today-calendar-1792553365`), which gave Home
        // \u{2318}1 back.
        let expectedTitles = ["Home", "Command", "Operations", "Stores", "Engineering"]
        let actualTitles = DaylightSpace.allCases.map(\.title)
        if actualTitles != expectedTitles {
            fail("space pill order/copy should be \(expectedTitles), got \(actualTitles)", &ok)
        }
        for (index, space) in DaylightSpace.allCases.enumerated() where space.shortcutIndex != index + 1 {
            fail("\(space.rawValue) should map to \u{2318}\(index + 1), reports \u{2318}\(space.shortcutIndex)", &ok)
        }

        if ok {
            print("  OK - 4 spaces x their locked modules, \(overviewOnly.count) Overview-only, "
                  + "\(DaylightSpace.allCases.count) spaces in shortcut order")
        }
    }

    // MARK: symbols

    /// `NSImage(systemSymbolName:)` returns nil *silently*, and this app has
    /// shipped an invisible icon exactly that way before (the `anchor`
    /// incident). Every glyph Phase 2 introduces is checked here.
    private static func checkSymbolsResolve(_ ok: inout Bool) {
        print("\n-- SF Symbols: every glyph this phase introduces actually resolves --")
        var names = DaylightModule.allCases.map(\.symbol)
        names.append(contentsOf: RailDestination.allCases.map(\.symbol))
        names.append(contentsOf: ["sailboat.fill", "magnifyingglass", "chevron.left",
                                  "arrow.clockwise", "bell.fill", "gearshape",
                                  "rectangle.portrait.and.arrow.right"])
        for name in Set(names) where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            fail("SF Symbol '\(name)' does not resolve - it would render as an invisible icon", &ok)
        }
        if ok { print("  OK - all \(Set(names).count) symbols resolve") }
    }

    // MARK: 2 - uniform card sizing
    //
    // The captain's rule, in the shape it finally settled into (see
    // `DaylightModule`'s own doc comment for the three passes): the Morning
    // briefing is two columns wide, every other module is one, and *every*
    // card - briefing included - is the same height. This case measures the
    // real canvas grid rather than reasoning about the `gridSpan` property,
    // so per-card sizing creeping back by any route (a second module claiming
    // span 2, a width constraint at a priority that can cap the window, a
    // stretched partial row) fails here. The height half is
    // `checkUniformCardHeight` below, which needs a real window.

    private static func checkUniformCardSizing(_ ok: inout Bool) {
        print("\n-- grid: every module card the same size --")

        // Column count is monotonic in width and never below one.
        var previous = 0
        for width in stride(from: CGFloat(200), through: 2400, by: 100) {
            let columns = HelmResponsiveGrid.columns(containerWidth: width,
                                                     minItemWidth: HomeCanvasController.minModuleWidth,
                                                     spacing: HomeCanvasController.gridSpacing)
            if columns < 1 { fail("column count fell below 1 at width \(width)", &ok) }
            if columns < previous { fail("column count is not monotonic: \(previous) -> \(columns) at width \(width)", &ok) }
            previous = columns
        }

        // Exactly one module is wide, and it is the briefing. A second one
        // claiming span 2 is the misreading this case exists to catch.
        // Two wide modules now, and the literal stays a literal for the
        // reason it always did: a *third* card quietly claiming span 2 is the
        // misreading this case exists to catch.
        //
        // `fm/grandline-claude-status-card-implement` added `.claudeStatus`.
        // It is wide for a reason of the same kind as the briefing's - five
        // hairline-separated columns need measure, and at one column each key
        // truncates to an initial - but it degrades differently: the briefing
        // *cuts clauses* at one column, where the strip *wraps* and drops
        // nothing (`HomeCanvasController.claudeStripColumnsPerRow`).
        let wide = DaylightModule.allCases.filter { $0.gridSpan != 1 }
        if wide != [.briefing, .claudeStatus] {
            fail("the wide modules should be exactly [briefing, claudeStatus], got \(wide.map(\.rawValue))", &ok)
        }
        for module in [DaylightModule.briefing, .claudeStatus] where module.gridSpan != 2 {
            fail("\(module.rawValue) should span 2 columns, got \(module.gridSpan)", &ok)
        }

        // The real grid for every space, and Engineering's own lineup, were
        // the floating bar's wrapping shelf. P-03 of the 2026-11-25 full
        // review removed it; Home's arranged grid is `HomeCardGrid`'s, which
        // `MainSplitShellNavigationSelfTest` measures in a real window.
        for module in [DaylightModule.updates, .bootstrap, .automation, .githubSync] {
            if module.opens == .updates && module != .updates {
                fail("\(module.rawValue) opens .updates - each Setup card must open its own page", &ok)
            }
        }
        let opened = Set([DaylightModule.updates, .bootstrap, .automation, .githubSync].map(\.opens))
        if opened != [.updates, .bootstrap, .automation, .githubSync] {
            fail("the four Engineering cards should open four distinct destinations, got "
                 + "\(opened.map(String.init(describing:)).sorted())", &ok)
        }

        // The packing math itself, at every column count including the
        // single-column case a span-2 card has to degrade into rather than
        // overflow. Literal spans rather than the module property, so this
        // stays a test of the arithmetic.
        for columns in 1...6 {
            let spans = [2, 1, 1, 1, 1, 1, 1]
            let rows = HelmResponsiveGrid.packRows(spans: spans, columns: columns)
            for (index, row) in rows.enumerated() {
                let used = row.reduce(0) { $0 + $1.span }
                if used > columns { fail("packRows: at \(columns) columns, row \(index) uses \(used)", &ok) }
            }
            let placed = rows.flatMap { $0 }.map(\.index)
            if placed != Array(spans.indices) {
                fail("packRows: at \(columns) columns, packing lost or reordered items: \(placed)", &ok)
            }
            let wide = rows.flatMap { $0 }.first { $0.index == 0 }
            let expectedSpan = columns == 1 ? 1 : 2
            if wide?.span != expectedSpan {
                fail("packRows: at \(columns) columns a span-2 item should be \(expectedSpan), "
                     + "got \(wide?.span ?? -1)", &ok)
            }
        }

        if ok {
            print("  OK - briefing and Claude wide, every other module one column, the four Setup cards' "
                  + "own pages, packing math")
        }
    }

    // MARK: 2b - card height: a floor, and no clipping
    //
    // The half PR #259 never addressed was that matching widths alone left
    // rows ragged, because each body kind renders at its own natural height.
    // `HelmModuleCard.standardHeight` fixed that by making every card exactly
    // as tall as the tallest body kind could ever need.
    //
    // **Full review #3's PF2 changed what is being asserted here**, because
    // that answer stopped being the right one: most modules now render a
    // single line, and the review measured seven canvas cards whose bodies
    // were about 55% empty. The card sizes to its content now, with a floor
    // (`minimumHeight`) underneath it and per-row equalisation
    // (`HelmResponsiveGrid`'s `equalHeights`) above it, so uniformity is per
    // row rather than per canvas.
    //
    // So this case asserts the three things that still have to be true, and
    // no longer asserts the one that deliberately is not:
    //
    //   1. **Nothing is clipped.** Every body kind fits the area the card
    //      gives it. This is the assertion that actually protected anything,
    //      and it is unchanged.
    //   2. **The floor holds.** No card resolves below `minimumHeight`, so a
    //      one-line card is still a card.
    //   3. **The floor is not secretly the old fixed height.** At least one
    //      realistic body kind must resolve *above* it and at least one must
    //      sit *at* it - otherwise the change did nothing and this case would
    //      pass while the waste it exists for was still there.
    //
    // It still prints each measurement, so the next agent changing a body
    // kind can see the real numbers rather than re-deriving them.

    private static func checkUniformCardHeight(_ ok: inout Bool) {
        print("\n-- module card: one height for every body kind --")

        // Deliberately pessimistic content: the longest note that fits two
        // lines, a peek list at its own cap, a wide metric, and a briefing
        // paragraph at `maxBriefingClauses` - the states that actually set the
        // floor, not the tidy ones.
        let longNote = "Two crew are working, one pull request is ready to merge, and nothing is blocked right now."
        let bodies: [(String, HelmModuleCard.Body)] = [
            ("metric", .metric(value: "128", unit: "updates", note: longNote)),
            ("progress", .progress(value: 4, total: 5, note: longNote)),
            ("ring", .ring(value: 4, total: 5, title: "Healthy", note: longNote)),
            ("peekRows", .peekRows((1...HelmModuleCard.maxPeekRows).map {
                HelmModulePeekRow(state: .warn, text: "a-long-crew-task-identifier-\($0)",
                                  value: "needs decision")
            })),
            ("note", .note(longNote)),
        ]

        // The strip is measured at its real span-2 width below rather than
        // here, because five columns in one `minModuleWidth` column is the
        // one state it is never built in - `claudeStripColumnsPerRow` wraps
        // it instead. Measuring it at a width it never gets would assert
        // something about a card that does not exist.

        // The narrowest column the grid ever hands a card: one column at the
        // minimum column width. Anything wider only makes the text shorter.
        let narrow = HomeCanvasController.minModuleWidth

        let window = OffScreenProbe.window(width: 1200, height: 700, styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        // PF2's own discriminating half - see this section's note 3.
        var measuredHeights: [(String, CGFloat)] = []

        func measure(_ name: String, _ body: HelmModuleCard.Body, width: CGFloat) {
            let card = HelmModuleCard()
            card.configure(.init(title: "Morning briefing", subtitle: "generated 9:41 AM",
                                 symbol: "cup.and.saucer.fill", hue: .amber,
                                 chip: .mute("3 sources"), body: body))
            host.addSubview(card)
            let widthConstraint = card.widthAnchor.constraint(equalToConstant: width)
            widthConstraint.priority = HelmDaylightPriority.contentTie
            NSLayoutConstraint.activate([
                widthConstraint,
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()

            let a = card.anatomyForTests
            if a.cardHeight < HelmModuleCard.minimumHeight - 0.5 {
                fail("\(name) at \(width)pt: the card resolved to \(a.cardHeight)pt, below the floor "
                     + "minimumHeight (\(HelmModuleCard.minimumHeight)) - a card that short stops "
                     + "reading as a card", &ok)
            }
            if a.bodyContentHeight > a.bodyAreaHeight + 0.5 {
                fail("\(name) at \(width)pt: the body needs \(a.bodyContentHeight)pt but the card gives "
                     + "it \(a.bodyAreaHeight)pt - it would be clipped with nothing said about it. "
                     + "Cap this body kind's content.", &ok)
            }
            measuredHeights.append((name, a.cardHeight))
            let slack = a.bodyAreaHeight - a.bodyContentHeight
            print(String(format: "     %-10@ card %6.1fpt, body needs %6.1fpt of %6.1fpt (%+.1f slack)",
                         name as NSString, a.cardHeight, a.bodyContentHeight, a.bodyAreaHeight, slack))
            card.removeFromSuperview()
        }

        // The briefing, at the span-2 width it actually gets, carrying a full
        // cap's worth of realistic clauses plus the overflow line the caller
        // appends. If this stops fitting, `maxBriefingClauses` is too high -
        // which is the whole reason that constant exists now that the card's
        // height is fixed.
        let clauses = [
            BriefingClause(text: "Two crew are working and nothing is blocked.", target: .fleet),
            BriefingClause(text: "One pull request is ready to merge whenever you are.", target: .review),
            BriefingClause(text: "Two tasks are due today and the cert renewal is the urgent one.", target: .tasks),
            BriefingClause(text: "Three tools have updates waiting in Setup.", target: .updates),
            BriefingClause(text: "Two machine setup items have drifted since Tuesday.", target: .setup),
        ]
        if clauses.count != HelmModuleCard.maxBriefingClauses {
            fail("this case measures \(clauses.count) clauses but the cap is "
                 + "\(HelmModuleCard.maxBriefingClauses) - measure the cap, not a number beside it", &ok)
        }
        var capped = clauses
        capped.append(BriefingClause(text: "+3 more on Fleet.", target: .none))
        let spanTwo = narrow * 2 + HomeCanvasController.gridSpacing

        // The Claude usage report at its most demanding: the longest row
        // title this card ever draws, the longest figures, and - on the
        // three windows that have one - the painted reset line. A fixture
        // without the captions would measure a card the app never builds.
        let usageSections: [HelmModuleUsageSection] = [
            .init(title: "Plan limits",
                  status: .init(text: "Fable limit reached", state: .bad),
                  content: .limits([
                    .init(title: "Session (5h)", value: "96%", fill: 0.96, state: .bad,
                          caption: "Sun 6:30 pm", detail: "Resets 23 Sep 2026 at 6:30 pm"),
                    .init(title: "Week", value: "70%", fill: 0.70, state: .ok,
                          caption: "Sun 9:30 am", detail: "Resets 27 Sep 2026 at 9:30 am"),
                    .init(title: "Fable week", value: "100%", fill: 1, state: .bad,
                          caption: "Mon 2:30 pm", detail: "Resets 28 Sep 2026 at 2:30 pm"),
                  ])),
            .init(title: "Extra usage", status: .init(text: "Near cap", state: .bad),
                  content: .spend(.init(amount: "$137.62", against: "of $140 cap",
                                        value: "98%", fill: 0.98, state: .bad,
                                        footnote: "$2.38 left before the cap"))),
        ]
        guard case let .limits(usageRows) = usageSections[0].content,
              !usageRows.allSatisfy({ $0.caption == nil }) else {
            fail("the usage fixture carries no reset lines - it would measure a state the "
                 + "Claude card never renders", &ok)
            return
        }

        // Swept across GL-32's chrome text scale, because that is what makes
        // one fixed height a real claim rather than one true at the default
        // setting: at x1.3 every font in the card grows, so `standardHeight`
        // is scaled too and the fit has to hold at the top of the range.
        //
        // `ChromeTextScale.setScale` writes through to the real
        // `AppSettings.uiTextScale`, so the captain's own setting is saved and
        // restored - the same care `BackupSelfTest` takes with the dictation
        // shortcut for the same reason.
        let captainScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(captainScale) }

        for (title, scale) in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(scale)
            print("   \(title) (x\(scale)), card \(HelmModuleCard.standardHeight)pt:")
            for (name, body) in bodies { measure(name, body, width: narrow) }
            measure("paragraph", .paragraph(capped), width: spanTwo)
            // The Claude usage report, at the span-2 width it is really
            // built for and carrying the widest realistic figures.
            //
            // **This is the one body kind that is deliberately allowed past
            // the card's floor**, on the captain's own instruction - so what
            // `measure` checks for it is the same thing it checks for every
            // other body (the content fits the area the card gives it, so
            // nothing is clipped), against a card that has grown rather than
            // against the floor.
            measure("usageReport", .usageReport(usageSections, compact: false), width: spanTwo)
            // And the same report on a card `packRows` degraded to one
            // column, which reflows into stacked rows rather than truncating.
            measure("usageReport-1col",
                    .usageReport(usageSections,
                                 compact: HomeCanvasController.claudeUsageIsCompact(forCardWidth: narrow)),
                    width: narrow)
            // And the same paragraph on a briefing `packRows` has degraded to
            // one column, which takes the narrower cap.
            measure("paragraph-1col",
                    .paragraph(Array(capped.prefix(HelmModuleCard.maxNarrowBriefingClauses))
                               + [BriefingClause(text: "+3 more on Fleet.", target: .none)]),
                    width: narrow)
            // And the fallback the briefing renders before the day's first one
            // is generated, which is a plain note on the same wide card.
            measure("briefing-empty",
                    .note("Your first briefing of the day appears here."),
                    width: spanTwo)
        }

        // The cap the canvas actually picks, from the width the grid built the
        // card for - the wide number only above a real span-2 width.
        let spanTwoCap = HomeCanvasController.briefingClauseCap(forCardWidth: spanTwo)
        let narrowCap = HomeCanvasController.briefingClauseCap(forCardWidth: narrow)
        if spanTwoCap != HelmModuleCard.maxBriefingClauses {
            fail("a span-2 card should take \(HelmModuleCard.maxBriefingClauses) clauses, got \(spanTwoCap)", &ok)
        }
        if narrowCap != HelmModuleCard.maxNarrowBriefingClauses {
            fail("a one-column card should take \(HelmModuleCard.maxNarrowBriefingClauses) clauses, "
                 + "got \(narrowCap)", &ok)
        }

        // PF2's discriminating half. Without this the two checks above would
        // both pass with the fixed height put straight back - every card
        // would sit at one height, that height would be at or above the
        // floor, and nothing would be clipped. These assert that the card
        // genuinely sizes to its content: something is taller than the floor,
        // and something is sitting on it.
        let atTheFloor = measuredHeights.filter { abs($0.1 - HelmModuleCard.minimumHeight) < 1.0 }
        let aboveTheFloor = measuredHeights.filter { $0.1 > HelmModuleCard.minimumHeight + 1.0 }
        if measuredHeights.count < 5 {
            fail("only \(measuredHeights.count) card heights were measured - the checks below would be "
                 + "nearly vacuous", &ok)
        }
        if atTheFloor.isEmpty {
            fail("no body kind resolves to minimumHeight (\(HelmModuleCard.minimumHeight)) - the floor is "
                 + "below every real card, so it is not doing anything. Measured: "
                 + "\(measuredHeights.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))", &ok)
        }
        if aboveTheFloor.isEmpty {
            fail("every body kind resolves to the same height - the card is not sizing to its content, "
                 + "which is exactly the state PF2 removed. Measured: "
                 + "\(measuredHeights.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))", &ok)
        }

        if ok {
            let shortest = measuredHeights.map(\.1).min() ?? 0
            let tallest = measuredHeights.map(\.1).max() ?? 0
            print(String(format: "  OK - nothing clipped, floor %.0fpt held, cards range %.0f-%.0fpt "
                         + "(the old fixed height was %.0f) across %d text scales",
                         HelmModuleCard.minimumHeight, shortest, tallest,
                         HelmModuleCard.standardHeight, ChromeTextScale.steps.count))
        }
    }

    /// PF2's other half: the card sizes to its content, so a *row* is what
    /// has to be uniform now.
    ///
    /// **What this asserts, and why not the obvious thing.** The obvious case
    /// would build the same row twice, with and without `equalHeights`, and
    /// check the second is uniform where the first is ragged. That comparison
    /// turned out not to be reproducible: a card's own height preference is
    /// priority 1 (see `HelmModuleCard`'s `bodyHug`), so an `NSStackView`
    /// row's geometry can already leave the cards equal without being asked
    /// to, and the "ragged" half of the comparison is then not ragged. A case
    /// built on it would pass or fail for reasons that have nothing to do
    /// with the fix.
    ///
    /// So it asserts the three properties that are actually load-bearing, all
    /// on the equalised row:
    ///
    ///   1. **The row is uniform.** Every card the same height.
    ///   2. **Nothing is clipped by the equalisation.** This is the real
    ///      hazard, and it is not hypothetical - an earlier version of this
    ///      fix tied heights with a required `==`, which outranked the peek
    ///      list's own vertical resistance and rendered it into a 68pt area
    ///      it needed 86pt for, silently.
    ///   3. **The row grew to its content, not to the old fixed height.** The
    ///      row must be taller than `minimumHeight` when a taller body is in
    ///      it (otherwise the tallest card is being squashed to the floor)
    ///      and shorter than the old `standardHeight` for this content
    ///      (otherwise nothing was reclaimed and PF2 did nothing).
    private static func checkRowsEqualiseCardHeights(_ ok: inout Bool) {
        print("\n-- module grid: every card in a row is as tall as the tallest, and nothing clips --")

        let window = OffScreenProbe.window(width: 1200, height: 700, styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        // A one-line note beside a full-cap peek list: naturally different
        // heights, which is what makes any of this meaningful.
        let bodies: [HelmModuleCard.Body] = [
            .note("Locked."),
            .peekRows((1...HelmModuleCard.maxPeekRows).map {
                HelmModulePeekRow(state: .warn, text: "task-\($0)", value: "needs decision")
            }),
            .note("Two crew working, nothing blocked."),
        ]

        let rows = HelmResponsiveGrid.rows(bodies,
                                           containerWidth: 1100,
                                           minItemWidth: HomeCanvasController.minModuleWidth,
                                           spacing: HomeCanvasController.gridSpacing,
                                           equalHeights: true) { body, _ in
            let card = HelmModuleCard()
            card.configure(.init(title: "Module", subtitle: "updated 9:41 AM",
                                 symbol: "circle.fill", hue: .teal, chip: nil, body: body))
            return card
        }
        guard let row = rows.first else {
            fail("the grid produced no rows", &ok)
            return
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.widthAnchor.constraint(equalToConstant: 1100),
        ])
        host.layoutSubtreeIfNeeded()

        let cards = row.arrangedSubviews.compactMap { $0 as? HelmModuleCard }
        guard cards.count == bodies.count else {
            fail("expected \(bodies.count) cards in the row, got \(cards.count)", &ok)
            return
        }
        // The fixture really did lay out - without this every measurement
        // below is zero and the case passes vacuously.
        guard row.frame.height > 0 else {
            fail("the row never laid out (height 0) - every check below would be vacuous", &ok)
            return
        }

        let heights = cards.map { $0.anatomyForTests.cardHeight }
        if Set(heights.map { Int($0.rounded()) }).count != 1 {
            fail("the row should be uniform, got \(heights) - a canvas row of content-sized cards "
                 + "hangs ragged without equalisation (PF2)", &ok)
        }

        for (i, card) in cards.enumerated() {
            let a = card.anatomyForTests
            if a.bodyContentHeight > a.bodyAreaHeight + 0.5 {
                fail("card \(i) was clipped by the row equalisation: its body needs "
                     + "\(a.bodyContentHeight)pt and it was given \(a.bodyAreaHeight)pt. A required "
                     + "equal-height tie outranks a body's own vertical resistance - which is exactly "
                     + "how the first version of this fix squashed a peek list", &ok)
            }
        }

        let rowHeight = heights.first ?? 0
        if rowHeight <= HelmModuleCard.minimumHeight + 1 {
            fail("the row settled at \(rowHeight), at or below the floor "
                 + "(\(HelmModuleCard.minimumHeight)) - the taller card is being squashed to it", &ok)
        }
        if rowHeight >= HelmModuleCard.standardHeight - 1 {
            fail("the row settled at \(rowHeight), no better than the old fixed height "
                 + "(\(HelmModuleCard.standardHeight)) - nothing was reclaimed", &ok)
        }
        host.subviews.forEach { $0.removeFromSuperview() }

        if ok {
            print(String(format: "  OK - %d cards uniform at %.0fpt, nothing clipped "
                         + "(floor %.0f, old fixed height %.0f)",
                         cards.count, rowHeight,
                         HelmModuleCard.minimumHeight, HelmModuleCard.standardHeight))
        }
    }

    /// A card may leave the row's height tie, and only that card.
    ///
    /// **The captain's report this exists for.** #478 made the Claude usage
    /// card taller. `equalHeights` then pulled Morning briefing and Fleet up
    /// to match it, so two cards whose design had not changed rendered the
    /// same content in a taller box. The Claude card has since become the
    /// split hero and joined its row's tie again (`fm/grandline-widget-polish`),
    /// but the grid's `exemptsHeightTie` is still the path every card with a
    /// height the captain dragged takes (`fixedHeight`), so it is still
    /// asserted here.
    ///
    /// Three properties, and the second is the one that actually caught the
    /// first attempt at this fix:
    ///
    ///   1. **The exempt card keeps its own taller height**, and nothing in
    ///      it is clipped.
    ///   2. **Its tied neighbour shrinks back to its own content.** Leaving a
    ///      card out of `tieHeights` is *not* enough on its own - measured on
    ///      the real home canvas, an untied card in a 171pt row still
    ///      rendered 171pt tall, because an `NSStackView` stretches an
    ///      arranged subview whose own height preference is weak (a card's is
    ///      priority 1, `HelmModuleCard.bodyHug`). What makes it size to its
    ///      content is the collapsing `NSLayoutGuide` the exempt path ties it
    ///      to instead of the row. Asserting only "it is not in the tie"
    ///      would have passed against the broken version.
    ///   3. **A row with no exempt card is untouched**, still tied to its own
    ///      tallest.
    private static func checkAnExemptCardSizesToItsOwnContent(_ ok: inout Bool) {
        print("\n-- module grid: an exempt card renders at its own height, and only it --")

        /// A fixture module: a body, a span, and whether it leaves the tie.
        struct Cell {
            let body: HelmModuleCard.Body
            let span: Int
            let exempt: Bool
        }

        // Row 0: a tall exempt card beside a short one - the canvas's real
        // shape, where `.claudeStatus` spans two columns and Fleet one.
        // Row 1: two ordinary cards, neither exempt, of different natural
        // heights - the case that must still tie.
        // Row 2: the short card alone, which is the *reference*: a row of one
        // is never tied to anything, so this is what that body renders at
        // when nothing stretches it. Row 0's neighbour has to match it.
        let tall = HelmModuleCard.Body.peekRows((1...HelmModuleCard.maxPeekRows).map {
            HelmModulePeekRow(state: .warn, text: "task-\($0)", value: "needs decision")
        })
        let short = HelmModuleCard.Body.note("Locked.")
        let cells = [
            Cell(body: tall, span: 2, exempt: true),
            Cell(body: short, span: 1, exempt: false),
            Cell(body: short, span: 1, exempt: false),
            Cell(body: tall, span: 2, exempt: false),
            Cell(body: short, span: 1, exempt: false),
        ]

        let window = OffScreenProbe.window(width: 1200, height: 900, styleMask: [.titled, .resizable])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let containerWidth: CGFloat = 860
        let rows = HelmResponsiveGrid.spanningRows(
            cells,
            spans: { $0.span },
            containerWidth: containerWidth,
            minItemWidth: HomeCanvasController.minModuleWidth,
            spacing: HomeCanvasController.gridSpacing,
            equalHeights: true,
            exemptsHeightTie: { $0.exempt }
        ) { cell, _ in
            let card = HelmModuleCard()
            card.configure(.init(title: "Module", subtitle: "updated 9:41 AM",
                                 symbol: "circle.fill", hue: .teal, chip: nil, body: cell.body))
            return card
        }
        guard rows.count == 3 else {
            fail("expected the fixture to pack into 3 rows, got \(rows.count) - the packing "
                 + "changed and every measurement below is about the wrong rows", &ok)
            return
        }

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HomeCanvasController.gridSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.widthAnchor.constraint(equalToConstant: containerWidth),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        host.layoutSubtreeIfNeeded()
        defer { host.subviews.forEach { $0.removeFromSuperview() } }

        let cards = rows.map { $0.arrangedSubviews.compactMap { $0 as? HelmModuleCard } }
        guard cards[0].count == 2, cards[1].count == 2, cards[2].count == 1 else {
            fail("expected 2, 2 and 1 cards in the three rows, got \(cards.map(\.count))", &ok)
            return
        }
        // The fixture really laid out - otherwise every height below is 0 and
        // every comparison passes vacuously.
        guard rows.allSatisfy({ $0.frame.height > 0 }) else {
            fail("a row never laid out (height 0) - every check below would be vacuous", &ok)
            return
        }

        let exemptHeight = cards[0][0].anatomyForTests.cardHeight
        let neighbourHeight = cards[0][1].anatomyForTests.cardHeight

        // The fixture's own discriminating power: the two bodies must really
        // want different heights, or "the neighbour is shorter" means nothing.
        let tiedTall = cards[1][1].anatomyForTests.cardHeight
        let tiedShort = cards[1][0].anatomyForTests.cardHeight
        // The short body's own natural height, measured where nothing is
        // tied to anything: row 2 holds it alone.
        let loneShort = cards[2][0].anatomyForTests.cardHeight
        // Measured on row 1 and row 2, neither of which contains an exempt
        // card - so this stays a statement about the *fixture* even when the
        // exemption is broken, and cannot swallow a real failure below.
        if tiedTall <= loneShort + 1 {
            fail("the fixture is not discriminating: a tied peek-list card settled at \(tiedTall) "
                 + "and a lone one-line card at \(loneShort). The two bodies must want visibly "
                 + "different heights or nothing below this line can fail", &ok)
            return
        }

        // 1. The exempt card kept its own height, and nothing in it clips.
        let exemptAnatomy = cards[0][0].anatomyForTests
        if exemptAnatomy.bodyContentHeight > exemptAnatomy.bodyAreaHeight + 0.5 {
            fail("the exempt card was clipped: its body needs \(exemptAnatomy.bodyContentHeight)pt "
                 + "and it was given \(exemptAnatomy.bodyAreaHeight)pt", &ok)
        }
        if abs(exemptHeight - tiedTall) > 1 {
            fail("the exempt card settled at \(exemptHeight) but the same body tied in row 1 "
                 + "settled at \(tiedTall) - the exemption should change nothing about the "
                 + "exempt card's own height", &ok)
        }

        // 2. Its neighbour is back at its own content, not stretched to it.
        //    This is the regression: leaving the card out of the tie is not
        //    enough, the stack stretches it anyway.
        if abs(neighbourHeight - loneShort) > 1 {
            fail("the exempt card's neighbour settled at \(neighbourHeight), not at the "
                 + "\(loneShort) the same one-line card renders at on its own. It is being "
                 + "stretched to the exempt card's \(exemptHeight) - which is the whole defect "
                 + "the exemption exists to fix", &ok)
        }

        // 3. A row with no exempt card still ties to its own tallest.
        if abs(tiedShort - tiedTall) > 1 {
            fail("row 1 has no exempt card and should still be uniform, got "
                 + "\(tiedShort) and \(tiedTall) - the exemption must not switch the tie off "
                 + "for ordinary rows", &ok)
        }
        let tiedAnatomy = cards[1][1].anatomyForTests
        if tiedAnatomy.bodyContentHeight > tiedAnatomy.bodyAreaHeight + 0.5 {
            fail("the tied row squashed its taller card: body needs "
                 + "\(tiedAnatomy.bodyContentHeight)pt, given \(tiedAnatomy.bodyAreaHeight)pt", &ok)
        }

        if ok {
            print(String(format: "  OK - exempt card %.0fpt, its neighbour back at its own %.0fpt "
                         + "(not stretched), ordinary row still tied at %.0fpt",
                         exemptHeight, neighbourHeight, tiedTall))
        }
    }

    /// Nothing inside a module card may outrank the window's own size.
    ///
    /// **The invariant, asserted structurally rather than by reproducing the
    /// layout.** A grid row is `.fillEqually`, so a card that refuses to
    /// compress does not cap the window at its own width - it caps it at
    /// *column count times* that width. That is how one card holding a long
    /// note produced a real 1135.5pt floor on every destination at once
    /// (`.homeCanvas` is eagerly mounted, so its constraints are live whatever
    /// page is showing - gotcha (11)).
    ///
    /// The emergent failure itself is caught by
    /// `AppShellBodyWidthSelfTest.bodyContainerTracksWindowAcrossAllDestinations`,
    /// which mounts a real shell in a real window and is the guard that
    /// actually reproduced it. Reproducing it synthetically here needs the
    /// whole scroll/clip/document/grid chain, at which point the test is just
    /// a worse copy of that one - so this checks the *cause* instead, which
    /// is deterministic and reads as a rule: no stack inside a card, and no
    /// label or text view inside one, may sit at or above
    /// `NSLayoutPriorityWindowSizeStayPut` (500) horizontally.
    ///
    /// It also covers the one body kind that other suite cannot reach: it
    /// mounts a real shell against a scratch environment, where
    /// `AppSettings.morningBriefingRecord` is nil, so the briefing card there
    /// renders its `.note` fallback and the `.paragraph` body - an
    /// `NSTextView`, the widest-intrinsic thing a card can hold - is never
    /// laid out at all. In production it is.
    private static func checkNoCardIsAWindowFloor(_ ok: inout Bool) {
        print("\n-- module card: nothing inside outranks the window's own size --")

        let longNote = "Two crew are working, one pull request is ready to merge, and nothing is blocked right now."
        let bodies: [(String, HelmModuleCard.Body)] = [
            ("paragraph", .paragraph([
                BriefingClause(text: "Two crew are working and nothing is blocked.", target: .fleet),
                BriefingClause(text: "One pull request is ready to merge whenever you are.", target: .review),
                BriefingClause(text: "Two machine setup items have drifted since Tuesday.", target: .setup),
            ])),
            ("note", .note(longNote)),
            ("metric", .metric(value: "12", unit: "updates", note: longNote)),
            ("progress", .progress(value: 4, total: 5, note: longNote)),
            ("ring", .ring(value: 4, total: 5, title: "Healthy", note: longNote)),
            ("peekRows", .peekRows([
                HelmModulePeekRow(state: .ok, text: "a-long-crew-task-identifier-here", value: "working"),
                HelmModulePeekRow(state: .warn, text: "another-long-identifier-here", value: "needs decision"),
            ])),
        ]

        let stayPut = NSLayoutConstraint.Priority(rawValue: 500)

        for (name, body) in bodies {
            let card = HelmModuleCard()
            card.configure(.init(title: "Morning briefing", subtitle: "generated 9:41 AM",
                                 symbol: "cup.and.saucer.fill", hue: .amber,
                                 chip: .mute("3 sources"), body: body))
            card.frame = NSRect(x: 0, y: 0, width: 263, height: 200)
            card.layoutSubtreeIfNeeded()

            // Stacks only, and that is the measured scope rather than a
            // shortcut: a leaf's own compression resistance was tried as a
            // suspect first and does *not* propagate through a stack that has
            // already agreed to clip - reverting only the paragraph text
            // view's 750 priority left the floor gone. The stack is what
            // binds, so the stack is what this asserts.
            func walk(_ view: NSView) {
                if let stack = view as? NSStackView,
                   stack.clippingResistancePriority(for: .horizontal) >= stayPut {
                    // gotcha (12): a stack has no intrinsic content size, so
                    // the *content* priority APIs are no-ops on it - clipping
                    // resistance is the one that binds, and it defaults to 750.
                    fail("\(name): a stack inside the card resists clipping at "
                         + "\(stack.clippingResistancePriority(for: .horizontal).rawValue) - "
                         + "at or above 500 that is a window-width floor", &ok)
                }
                view.subviews.forEach(walk)
            }
            walk(card)
        }

        if ok { print("  OK - 6 body kinds, every stack below the window's stay-put priority") }
    }

    // MARK: 1 - module anatomy

    private static func checkModuleAnatomy(_ ok: inout Bool) {
        print("\n-- module card: \u{00A7}6.1's anatomy, and one clickable target --")

        let bodies: [(String, HelmModuleCard.Body)] = [
            ("metric", .metric(value: "3", unit: "tasks", note: "One is overdue.")),
            ("peekRows", .peekRows([
                HelmModulePeekRow(state: .ok, text: "one", value: "live"),
                HelmModulePeekRow(state: .warn, text: "two", value: "idle"),
            ])),
            ("ring", .ring(value: 4, total: 5, title: "Healthy", note: "One service is degraded.")),
            ("progress", .progress(value: 4, total: 5, note: "One step drifted.")),
            ("note", .note("A single wrapping line.")),
        ]

        for (name, body) in bodies {
            let card = HelmModuleCard()
            var opened = 0
            card.onOpen = { opened += 1 }
            card.configure(.init(title: "Title", subtitle: "subtitle",
                                 symbol: "sailboat.fill", hue: .teal,
                                 chip: .ok("All clear"), body: body))
            card.frame = NSRect(x: 0, y: 0, width: 300, height: 170)
            card.layoutSubtreeIfNeeded()

            let a = card.anatomyForTests
            // The UI/UX revamp's UI-6 retired §6.1's ribbon: identity lives in
            // the tile, and the only edge a card may carry is the attention
            // card's semantic one.
            if a.hasRibbon { fail("\(name): a module card still carries a ribbon (UI-6)", &ok) }
            if abs(a.cornerRadius - HelmMetrics.dModule) > 0.01 {
                fail("\(name): radius \(a.cornerRadius), expected \(HelmMetrics.dModule)", &ok)
            }
            if !HelmMetrics.daylightRadii.contains(a.cornerRadius) {
                fail("\(name): radius \(a.cornerRadius) is not in \u{00A7}2.6's scale", &ok)
            }
            // The two-layer shadow arrangement (\u{00A7}2.5): the shadow host must
            // not clip, the card must.
            if a.shadowHostClipsToBounds { fail("\(name): the shadow host clips - it would cast no shadow", &ok) }
            if !a.cardClipsToBounds { fail("\(name): the card does not clip - its fill would escape the radius", &ok) }
            if a.borderWidth != 1 { fail("\(name): border is \(a.borderWidth)pt, expected 1", &ok) }
            if !a.hasTile { fail("\(name): the gradient tile has no glyph", &ok) }
            if a.title != "Title" || a.subtitle != "subtitle" { fail("\(name): header text did not render", &ok) }
            if a.chipText != "All clear" { fail("\(name): chip text is \(a.chipText ?? "nil")", &ok) }

            // \u{00A7}6.1: the whole card is one click target, announcing as a button
            // with "<title>, <subtitle>, <chip text>".
            if !a.isCardActivatable { fail("\(name): the card is not activatable - it would be invisible to VoiceOver", &ok) }
            if a.accessibilityLabel != "Title, subtitle, All clear" {
                fail("\(name): accessibility label is \(a.accessibilityLabel ?? "nil")", &ok)
            }
            card.debugActivate()
            if opened != 1 { fail("\(name): a press fired onOpen \(opened) times, expected 1", &ok) }
        }

        // A body with no chip renders no chip, and the label drops it.
        let bare = HelmModuleCard()
        bare.configure(.init(title: "Tools", subtitle: "9 utilities",
                             symbol: "wrench.and.screwdriver.fill", hue: .slate,
                             chip: nil, body: .note("YAML \u{00B7} JSON")))
        if bare.anatomyForTests.chipText != nil {
            fail("a module with no chip still rendered one", &ok)
        }
        if bare.anatomyForTests.accessibilityLabel != "Tools, 9 utilities" {
            fail("chipless label is \(bare.anatomyForTests.accessibilityLabel ?? "nil")", &ok)
        }

        // \u{00A7}6.1's "2-3 rows": a fourth row is dropped rather than turning the
        // canvas into a table.
        let crowded = HelmModuleCard()
        crowded.configure(.init(title: "Hosts", subtitle: "5 saved", symbol: "desktopcomputer",
                                hue: .teal, chip: nil,
                                body: .peekRows((1...6).map {
                                    HelmModulePeekRow(state: .idle, text: "host \($0)", value: "idle")
                                })))
        if crowded.anatomyForTests.peekRowCount != HelmModuleCard.maxPeekRows {
            fail("six peek rows rendered as \(crowded.anatomyForTests.peekRowCount), expected \(HelmModuleCard.maxPeekRows)", &ok)
        }

        // The gauges carry the value they were given rather than a placeholder.
        let ring = HelmRingGauge()
        ring.configure(value: 3, total: 4)
        if abs(ring.fractionForTests - 0.75) > 0.001 { fail("ring fraction \(ring.fractionForTests), expected 0.75", &ok) }
        if ring.centreLabelForTests != "3/4" { fail("ring label \(ring.centreLabelForTests), expected 3/4", &ok) }
        ring.configure(value: 0, total: 0)
        if ring.fractionForTests != 0 { fail("an empty ring should be 0, got \(ring.fractionForTests)", &ok) }

        let bar = HelmProgressBar()
        bar.configure(fraction: 2.5)
        if bar.fractionForTests != 1 { fail("progress fraction should clamp to 1, got \(bar.fractionForTests)", &ok) }

        if ok { print("  OK - ribbon/tile/header/chip/body, two-layer shadow, button semantics, row cap, gauges") }
    }

    // MARK: 4 - the canvas constructs no store

    private static func checkCanvasConstructsNoStores(_ ok: inout Bool) {
        print("\n-- canvas: reads already-owned state, never constructs a store --")
        guard SelfTestSources.appSourceDirectory() != nil else {
            print("  SKIP - app sources are not next to this binary")
            return
        }
        guard let text = SelfTestSources.homeCanvasSource() else {
            fail("could not read HomeCanvasController.swift - has it moved? this check would silently pass", &ok)
            return
        }
        // Comments name these types on purpose (explaining what is injected and
        // why), so only real code lines are scanned.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // A constructor call, not a mention: `Store()` / `Source()`.
        let banned = ["ShiftStore(", "HostStore(", "ScheduleStore(", "LogAnalyzerStore(",
                      "DocsRunbookStore(", "CommandLibraryStore(", "SnippetStore(",
                      "SSHKeyStore(", "DictationStore(", "IncidentStore(", "FleetLogStore(",
                      // `fm/implement-grand-line-secrets-vault-poneg-ad`: the
                      // most consequential entry in this list. A
                      // `CredentialVaultStore()` built here would reach
                      // `CredentialVaultGitSync.shared` - the captain's real
                      // `manjesh-config` clone - on every hub render. The card
                      // reads injected state instead (`credentialVaultState`).
                      "CredentialVaultStore("]
        for name in banned where code.contains(name) {
            fail("HomeCanvasController constructs a \(name.dropLast()) - it must be injected "
                 + "(see the file header: a store built here means a fetch on every hub visit)", &ok)
        }
        // The expensive fleet/PR reads in particular must never appear here.
        for name in ["FleetDataSource.snapshot(", "OpenPRsSource.fetch", "VaultSource.loadSnapshot("] {
            if code.contains(name) {
                fail("HomeCanvasController calls \(name)) - \u{00A7}6.1 forbids a fresh fetch from the canvas", &ok)
            }
        }
        if ok { print("  OK - no store construction, no fleet/PR/vault fetch") }
    }

    // MARK: 6 - bar anatomy

    // MARK: 6b - the quick-access destination icons
    //
    // `fm/grandline-sticky-code-preview-polish`: the captain reaches Sticky
    // Board and Code Preview often enough that a space switch plus a card
    // click is friction, so both get a bar icon. Tasks joined them in
    // `fm/grandline-tasks-quick-access-icon`, and Straw Hat Pirates/Poneglyph
    // joined them in `fm/poneglyph-own-destination-and-strawhat-toolbar-
    // shortcut`. Every one of them remains a full destination in its own
    // space - this is a shortcut, not a relocation.
    //
    // The expected list is a literal here on purpose: a check that derived it
    // from `debugDestinationButtons()` would pass for any set of icons in any
    // order, including an accidental duplicate or a reordering that moves an
    // icon the captain has muscle memory for.

    // MARK: 5 - the bar cannot cap the window

    // MARK: canvas + drill header, driven through the real shell

    // MARK: Helpers

    /// Scratch overrides for every store the shell builds, so this suite never
    /// touches the captain's real hosts/keys/snippets/tasks/dictation data -
    /// the same convention `AppShellBodyWidthSelfTest` established.
    // MARK: 7 - Phase 3: the modules are live, and honest before they are

    // MARK: 8 - Phase 3's one-line rule

    /// "No new polling." A source guard rather than a behavioural check,
    /// because a timer added here is invisible in a passing render test and
    /// only shows up as background cost.
    ///
    /// The companion behavioural halves are `checkCanvasConstructsNoStores`
    /// above (no fetch) and the `debugCountsObserverCount` assertion in
    /// `checkLiveModuleWiring` (the live path really is a subscription).
    private static func checkNoNewPolling(_ ok: inout Bool) {
        print("\n-- Phase 3's rule: the hub subscribes, it never polls --")
        guard SelfTestSources.appSourceDirectory() != nil else {
            print("  SKIP - app sources are not next to this binary")
            return
        }
        guard let text = SelfTestSources.homeCanvasSource() else {
            fail("could not read HomeCanvasController.swift - this check would silently pass", &ok)
            return
        }
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for token in ["Timer(", "Timer.scheduledTimer", "DispatchSourceTimer",
                      "asyncAfter(", "DispatchQueue.global"] where code.contains(token) {
            fail("HomeCanvasController contains `\(token)` - \u{00A7}6.1's refresh model is "
                 + "\"viewWillAppear plus the existing signals\", with no timer of its own", &ok)
        }
        // The subscription itself, so a future edit that deletes it fails here
        // as well as in the behavioural check above.
        if !code.contains("BackgroundSignalsPoller.shared.observeCounts") {
            fail("the canvas no longer subscribes to the signals poller - Setup and Vault "
                 + "would go back to showing a permanent loading state", &ok)
        }
        // And it must unregister: the canvas is app-lifetime today, but the
        // poller holds these closures forever and this app's most-repeated bug
        // is a leaked observer (see ThemeManager.swift's checklist).
        if !code.contains("unobserveCounts") {
            fail("the canvas registers a counts observer it never removes", &ok)
        }
        if ok { print("  OK - no timer, no background queue, one subscription, unregistered in deinit") }
    }

    /// Runs the main queue until the blocks already enqueued have run.
    ///
    /// The canvas coalesces render requests with a `DispatchQueue.main.async`
    /// hop (a burst of health reports or dictation transitions would otherwise
    /// rebuild fifteen cards several times for one change). A headless suite
    /// never turns the run loop, so those hops need draining explicitly - a
    /// `sleep` would not run them at all.
    private static func drainMainQueue() {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Pumps the main run loop until `landed()` holds, bounded by
    /// `timeout`. For a check that waits on the canvas's own coalesced render
    /// (`setNeedsRender` runs it on a later main-queue turn): a fixed
    /// `drainMainQueue()` is 40ms of pumping, and on CI's slower window-backed
    /// runner that once ended before the render ran, failing "Dictation chip
    /// is Needs access after the engine reported ready" with the wiring
    /// intact (PR #504's first run). This waits for the event rather than for
    /// time; the assertion after it is unchanged, so wiring that never renders
    /// still fails - after `timeout` instead of after 40ms.
    ///
    /// Full review 2026-11-25, T-02: 2s was still a guess at the runner's
    /// speed. On main (runs 44731186275 and 45150476006) the Engineering
    /// cards' first published pass had not rendered after 2s, failing five
    /// checks that passed on the re-run moments later. The bound is now
    /// generous, which costs a passing run nothing because the wait ends the
    /// moment the render lands, and a timeout says it was one, so a real
    /// wiring break reads differently from a slow runner.
    private static func pumpMainQueue(timeout: TimeInterval = 15, until landed: () -> Bool) {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        while !landed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if !landed() {
            print("  NOTE the canvas had not rendered the awaited state after \(Int(Date().timeIntervalSince(started)))s")
        }
    }

    /// `FM_DOCS_RUNBOOKS_DIR` was added by `fm/grandline-docs-split-runbooks-
    /// postmortems` - see `DestinationMountingSelfTest.withScratchEnv`'s own
    /// doc comment for why a store this checked directly can otherwise reach
    /// a real clone of the captain's `manjesh-config` repo. `checkCanvasAndDrillHeader`
    /// below visits every `RailDestination`, `.runbooks`/`.postmortems`
    /// included, so this harness needs the same protection that one does.
    private static func withScratchEnv(_ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-daylight-module-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_SCHEDULES_FILE": dir.appendingPathComponent("schedules.json").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
        ]
        var saved: [String: String?] = [:]
        for (key, value) in overrides {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, old) in saved {
                if let old { setenv(key, old, 1) } else { unsetenv(key) }
            }
        }
        body()
    }
}

#endif
