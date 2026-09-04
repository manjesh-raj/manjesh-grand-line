// Manjesh Grand Line - native macOS app.
//
// Daylight Phase 2's own suite: the shell (floating bar + home canvas +
// drill headers) that replaced the icon rail and the top bar.
//
// The migration spec names four things this has to pin (§8's "Testing
// requirements per phase"), and each maps to a case below:
//
//   1. **Module anatomy** - a module really is §6.1's card: ribbon, gradient
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
//   swift build && FM_RUN_DAYLIGHT_MODULE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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
        var allOK = true
        for check in [checkSpaceTable, checkSymbolsResolve, checkUniformCardSizing,
                      checkUniformCardHeight, checkNoCardIsAWindowFloor,
                      checkModuleAnatomy, checkCanvasConstructsNoStores,
                      checkBarAnatomy, checkBarDoesNotCapWindow,
                      checkCanvasAndDrillHeader, checkLiveModuleWiring,
                      checkNoNewPolling] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightModuleSelfTest: all checks passed"
                    : "DaylightModuleSelfTest: FAILED")
        return allOK
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: 3 - the locked space table

    /// The captain's locked decision, restated as literal data.
    ///
    /// Deliberately typed out again rather than derived from
    /// `DaylightModule.space`: a test that reads the same table it is checking
    /// asserts nothing. These five lines are the decision block at the top of
    /// `daylight-ui-design.md`, verbatim.
    private static let lockedMembership: [DaylightSpace: Set<DaylightModule>] = [
        .command: [.console, .tasks, .mergeQueue],
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
        // it gets used next to.
        .stores: [.vault, .docs, .runbooks, .postmortems, .tools, .dictation, .whiteboard],
        .engineering: [.updates, .bootstrap, .automation, .githubSync, .settings],
    ]

    /// The two that appear on Overview and nowhere else.
    private static let overviewOnly: Set<DaylightModule> = [.briefing, .fleet]

    /// `fm/grandline-overview-canvas-trim`'s own captain decision, restated
    /// as literal data for the same reason `lockedMembership` above is: a
    /// test that reads `appearsOnOverview` to check `appearsOnOverview`
    /// asserts nothing. This is the exact six the captain named as staying
    /// on the Overview canvas after a screenshot review.
    private static let overviewVisibleModules: Set<DaylightModule> =
        [.briefing, .fleet, .mergeQueue, .console, .health, .schedules]

    private static func checkSpaceTable(_ ok: inout Bool) {
        print("\n-- space filter: the table matches the locked captain decision --")

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

        // Overview shows exactly the trimmed six; each other space shows
        // only its own.
        let onOverview = Set(DaylightModule.allCases.filter { $0.isVisible(in: .overview) })
        if onOverview != overviewVisibleModules {
            fail("Overview should show exactly \(overviewVisibleModules.map(\.rawValue).sorted()), "
                 + "showed \(onOverview.map(\.rawValue).sorted())", &ok)
        }
        for (space, expected) in lockedMembership {
            let visible = Set(DaylightModule.allCases.filter { $0.isVisible(in: space) })
            if visible != expected {
                fail("\(space.rawValue) should show exactly its own modules, showed \(visible.map(\.rawValue).sorted())", &ok)
            }
            for module in overviewOnly where module.isVisible(in: space) {
                fail("\(module.rawValue) must appear only on Overview, but is visible in \(space.rawValue)", &ok)
            }
        }

        // Every one of the twelve trimmed-from-Overview modules must still be
        // fully reachable on its own space's canvas - the trim removes a
        // card from Overview specifically, never the module, its destination,
        // or its own canvas presence. A module that fell out of both would be
        // a real regression this suite has to catch, not just assume away.
        let trimmed = DaylightModule.allCases.filter { !overviewVisibleModules.contains($0) }
        // 12 from the original trim, plus Runbooks, Postmortems
        // (`fm/grandline-docs-split-runbooks-postmortems`), Whiteboard
        // (`fm/grand-line-whiteboard-excalidraw`) and Kubernetes
        // (`fm/grandline-k8s-cluster-tail`) - all four new modules with
        // `appearsOnOverview == false`, matching their space siblings. The
        // Kubernetes card in particular has nothing to show without a live
        // session and a chosen feed tab, so it belongs on Operations beside
        // Log Analyzer rather than on the pulse-check hub.
        if trimmed.count != 16 {
            fail("expected exactly 16 modules trimmed from Overview, got \(trimmed.count): "
                 + "\(trimmed.map(\.rawValue).sorted())", &ok)
        }
        for module in trimmed {
            guard let ownSpace = module.space else {
                fail("\(module.rawValue) is trimmed from Overview but has no other space to live in - "
                     + "it would be unreachable from the canvas entirely", &ok)
                continue
            }
            if !module.isVisible(in: ownSpace) {
                fail("\(module.rawValue) is trimmed from Overview but is not visible in its own "
                     + "space (\(ownSpace.rawValue)) either", &ok)
            }
        }
        // Its destination - the thing a click, the nav, or `⌘K` actually
        // opens - is untouched by this trim: the module's card is
        // presentation, `RailDestination` is the functional path, and every
        // one of these twelve is still driven through its real drill page
        // (mount, title, back button) by `checkCanvasAndDrillHeader`'s own
        // `RailDestination.allCases` loop below, unaffected by which modules
        // Overview shows.

        // Every module belongs somewhere reachable, and every space has
        // something in it - a space pill that filters to nothing is a dead end.
        for space in DaylightSpace.allCases {
            if DaylightModule.allCases.filter({ $0.isVisible(in: space) }).isEmpty {
                fail("space \(space.rawValue) has no modules at all", &ok)
            }
        }

        // §5.4's copy, and the shortcut indices `⌘1`…`⌘5` carry.
        let expectedTitles = ["Overview", "Command", "Operations", "Stores", "Engineering"]
        let actualTitles = DaylightSpace.allCases.map(\.title)
        if actualTitles != expectedTitles {
            fail("space pill order/copy should be \(expectedTitles), got \(actualTitles)", &ok)
        }
        for (index, space) in DaylightSpace.allCases.enumerated() where space.shortcutIndex != index + 1 {
            fail("\(space.rawValue) should map to \u{2318}\(index + 1), reports \u{2318}\(space.shortcutIndex)", &ok)
        }
        for space in DaylightSpace.allCases where space.subtitle.isEmpty {
            fail("\(space.rawValue) has no subtitle copy", &ok)
        }

        if ok {
            print("  OK - 4 spaces x their locked modules, 2 Overview-only, Overview trimmed to "
                  + "\(overviewVisibleModules.count), 5 pills in \u{2318}1-\u{2318}5 order")
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
        print("\n-- grid: every module card the same size, on every space --")

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
        let wide = DaylightModule.allCases.filter { $0.gridSpan != 1 }
        if wide != [.briefing] {
            fail("the wide modules should be exactly [briefing], got \(wide.map(\.rawValue))", &ok)
        }
        if DaylightModule.briefing.gridSpan != 2 {
            fail("the briefing should span 2 columns, got \(DaylightModule.briefing.gridSpan)", &ok)
        }

        // The real grid, at several real widths, for every space - including
        // the partial-last-row case, which is what a lone leftover card
        // stretching to fill its row would look like.
        for space in DaylightSpace.allCases {
            let modules = DaylightModule.canvasOrder.filter { $0.isVisible(in: space) }
            for container in [CGFloat(560), 820, 1100, 1512, 1900] {
                let columns = HelmResponsiveGrid.columns(containerWidth: container,
                                                         minItemWidth: HomeCanvasController.minModuleWidth,
                                                         spacing: HomeCanvasController.gridSpacing)
                let unit = HelmResponsiveGrid.itemWidth(containerWidth: container,
                                                        columns: columns,
                                                        spacing: HomeCanvasController.gridSpacing)
                let rows = HelmResponsiveGrid.spanningRows(
                    modules,
                    spans: { $0.gridSpan },
                    containerWidth: container,
                    minItemWidth: HomeCanvasController.minModuleWidth,
                    spacing: HomeCanvasController.gridSpacing
                ) { module, width in
                    let v = NSView()
                    v.identifier = NSUserInterfaceItemIdentifier("\(module.rawValue)|\(width)")
                    v.translatesAutoresizingMaskIntoConstraints = false
                    return v
                }

                for (index, row) in rows.enumerated() {
                    // Every cell's width is an explicit constraint on this
                    // path, and every one of them must sit below the window's
                    // own stay-put priority or a card becomes a window-width
                    // floor (gotcha (13)) - the failure `AppShellBody-
                    // WidthSelfTest` reproduces end to end.
                    var rowWidth: CGFloat = 0
                    for view in row.arrangedSubviews {
                        let widths = view.constraints.filter { $0.firstAttribute == .width }
                        guard let width = widths.first, widths.count == 1 else {
                            fail("\(space.rawValue) at \(container)pt: row \(index) has a cell with "
                                 + "\(widths.count) width constraints, expected exactly 1", &ok)
                            continue
                        }
                        if width.priority != HelmDaylightPriority.contentTie {
                            fail("\(space.rawValue) at \(container)pt: a cell's width is priority "
                                 + "\(width.priority.rawValue), expected "
                                 + "\(HelmDaylightPriority.contentTie.rawValue) - above 500 it caps the window", &ok)
                        }
                        // A cell is one column, or two columns plus the gap
                        // between them. Nothing else.
                        let single = abs(width.constant - unit) < 0.01
                        let double = abs(width.constant - (unit * 2 + HomeCanvasController.gridSpacing)) < 0.01
                        if !(single || (double && columns >= 2)) {
                            fail("\(space.rawValue) at \(container)pt: a cell is \(width.constant)pt, "
                                 + "which is neither one column (\(unit)) nor two", &ok)
                        }
                        rowWidth += width.constant
                    }
                    // The row fills its container exactly - no overflow, and
                    // no short row left stretching its cards.
                    let gaps = HomeCanvasController.gridSpacing * CGFloat(max(0, row.arrangedSubviews.count - 1))
                    if abs(rowWidth + gaps - container) > 0.5 {
                        fail("\(space.rawValue) at \(container)pt: row \(index) resolves to "
                             + "\(rowWidth + gaps)pt, not the container's \(container)pt", &ok)
                    }
                }

                // Every module placed exactly once, in order.
                let placed = rows.flatMap { $0.arrangedSubviews }
                    .compactMap { $0.identifier?.rawValue.split(separator: "|").first.map(String.init) }
                if placed != modules.map(\.rawValue) {
                    fail("\(space.rawValue) at \(container)pt: laid out \(placed), expected "
                         + "\(modules.map(\.rawValue))", &ok)
                }

                // At two or more columns the briefing is genuinely built for
                // the double width - not handed one column's worth and left
                // to wrap.
                if columns >= 2, modules.contains(.briefing) {
                    let built = rows.flatMap { $0.arrangedSubviews }
                        .first { $0.identifier?.rawValue.hasPrefix("briefing|") == true }?
                        .identifier?.rawValue.split(separator: "|").last.flatMap { Double($0) }
                    let expected = Double(unit * 2 + HomeCanvasController.gridSpacing)
                    if let built, abs(built - expected) > 0.01 {
                        fail("\(space.rawValue) at \(container)pt: the briefing card was built for "
                             + "\(built)pt, expected \(expected)pt", &ok)
                    } else if built == nil {
                        fail("\(space.rawValue) at \(container)pt: no briefing cell was built", &ok)
                    }
                }
            }
        }

        // Engineering's own lineup, in order - the captain's second
        // refinement, stated as the list they asked for.
        let engineering = DaylightModule.canvasOrder.filter { $0.isVisible(in: .engineering) }
        let expected: [DaylightModule] = [.updates, .bootstrap, .automation, .githubSync, .settings]
        if engineering != expected {
            fail("Engineering should show \(expected.map(\.rawValue)) in that order, got "
                 + "\(engineering.map(\.rawValue))", &ok)
        }
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
            print("  OK - briefing wide + every other cell one column, on 5 spaces x 5 widths, "
                  + "Engineering's five cards, packing math")
        }
    }

    // MARK: 2b - uniform card height
    //
    // The half PR #259 never addressed. Matching widths alone still left the
    // rows ragged, because each body kind rendered at its own natural height -
    // a `.note` is two lines and a `.progress` is a 34pt numeral over a bar
    // over a note. `HelmModuleCard.standardHeight` is the fix, and this case
    // is what makes the number defensible rather than a guess: it measures
    // every body kind's real content against the real body area, at the
    // narrowest realistic column, in a real window.
    //
    // It also prints each measurement, so the next agent changing a body kind
    // can see how much slack is left rather than re-deriving it.

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

        // The narrowest column the grid ever hands a card: one column at the
        // minimum column width. Anything wider only makes the text shorter.
        let narrow = HomeCanvasController.minModuleWidth

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

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
            if abs(a.cardHeight - HelmModuleCard.standardHeight) > 0.5 {
                fail("\(name) at \(width)pt: the card resolved to \(a.cardHeight)pt, not "
                     + "standardHeight (\(HelmModuleCard.standardHeight)) - the grid row would be ragged", &ok)
            }
            if a.bodyContentHeight > a.bodyAreaHeight + 0.5 {
                fail("\(name) at \(width)pt: the body needs \(a.bodyContentHeight)pt but the card gives "
                     + "it \(a.bodyAreaHeight)pt - it would be clipped with nothing said about it. "
                     + "Raise standardHeight or cap this body kind's content.", &ok)
            }
            let slack = a.bodyAreaHeight - a.bodyContentHeight
            print(String(format: "     %-10@ body needs %6.1fpt of %6.1fpt (%+.1f slack)",
                         name as NSString, a.bodyContentHeight, a.bodyAreaHeight, slack))
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
            BriefingClause(text: "Claude usage is comfortable for the rest of the day.", target: .quota),
        ]
        if clauses.count != HelmModuleCard.maxBriefingClauses {
            fail("this case measures \(clauses.count) clauses but the cap is "
                 + "\(HelmModuleCard.maxBriefingClauses) - measure the cap, not a number beside it", &ok)
        }
        var capped = clauses
        capped.append(BriefingClause(text: "+3 more on Overview.", target: .none))
        let spanTwo = narrow * 2 + HomeCanvasController.gridSpacing

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
            // And the same paragraph on a briefing `packRows` has degraded to
            // one column, which takes the narrower cap.
            measure("paragraph-1col",
                    .paragraph(Array(capped.prefix(HelmModuleCard.maxNarrowBriefingClauses))
                               + [BriefingClause(text: "+3 more on Overview.", target: .none)]),
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

        if ok {
            print("  OK - every body kind fits one \(HelmModuleCard.baseStandardHeight)pt card "
                  + "(briefing included, at span-2 width) across \(ChromeTextScale.steps.count) text scales")
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
                BriefingClause(text: "Claude usage is comfortable for the rest of the day.", target: .quota),
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
            if !a.hasRibbon { fail("\(name): no ribbon layer", &ok) }
            if a.ribbonStopCount != 2 { fail("\(name): ribbon has \(a.ribbonStopCount) gradient stops, expected 2", &ok) }
            if abs(a.ribbonHeight - 6) > 0.01 { fail("\(name): ribbon is \(a.ribbonHeight)pt, \u{00A7}6.1 says 6", &ok) }
            if abs(a.cornerRadius - HelmMetrics.dModule) > 0.01 {
                fail("\(name): radius \(a.cornerRadius), expected \(HelmMetrics.dModule)", &ok)
            }
            if !HelmMetrics.daylightRadii.contains(a.cornerRadius) {
                fail("\(name): radius \(a.cornerRadius) is not in \u{00A7}2.6's scale", &ok)
            }
            // The two-layer shadow arrangement (\u{00A7}2.5): the shadow host must
            // not clip, the card must.
            if a.shadowHostClipsToBounds { fail("\(name): the shadow host clips - it would cast no shadow", &ok) }
            if !a.cardClipsToBounds { fail("\(name): the card does not clip - its ribbon would escape the radius", &ok) }
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
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP - app sources are not next to this binary")
            return
        }
        let url = dir.appendingPathComponent("HomeCanvasController.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
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
                      "SSHKeyStore(", "DictationStore(", "IncidentStore(", "FleetLogStore("]
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

    private static func checkBarAnatomy(_ ok: inout Bool) {
        print("\n-- floating bar: \u{00A7}6.3's geometry, five pills, and no vibrancy --")
        let bar = DaylightBarController()
        bar.loadView()
        bar.view.frame = NSRect(x: 0, y: 0, width: 1200, height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()

        let geometry = bar.geometryForTests
        // gotcha (8): the single most-repeated bug class in this codebase, and
        // \u{00A7}6.3 rules it out by name for this exact surface.
        if geometry.usesVisualEffect {
            fail("the bar contains an NSVisualEffectView - \u{00A7}6.3 and AGENTS.md gotcha (8) both forbid it", &ok)
        }
        if abs(geometry.cornerRadius - HelmMetrics.dBar) > 0.01 {
            fail("bar radius \(geometry.cornerRadius), expected \(HelmMetrics.dBar)", &ok)
        }
        if abs(geometry.barFrame.height - DaylightBarController.height) > 0.5 {
            fail("bar height \(geometry.barFrame.height), expected \(DaylightBarController.height)", &ok)
        }
        if abs(geometry.barFrame.minX - DaylightBarController.sideMargin) > 0.5 {
            fail("bar leading inset \(geometry.barFrame.minX), expected \(DaylightBarController.sideMargin)", &ok)
        }
        let trailingInset = bar.view.bounds.width - geometry.barFrame.maxX
        if abs(trailingInset - DaylightBarController.sideMargin) > 0.5 {
            fail("bar trailing inset \(trailingInset), expected \(DaylightBarController.sideMargin)", &ok)
        }
        if geometry.shadowOpacity <= 0 {
            fail("the bar casts no shadow - \u{00A7}6.3 asks for the resting level", &ok)
        }
        if geometry.pillCount != DaylightSpace.allCases.count {
            fail("\(geometry.pillCount) pills, expected \(DaylightSpace.allCases.count)", &ok)
        }

        // Radio semantics, exactly one selected, and a real click through the
        // recognizer moves it.
        var picked: [DaylightSpace] = []
        bar.onSelectSpace = { picked.append($0) }
        let pills = bar.debugPills()
        for pill in pills {
            if pill.accessibilityRoleOverride != .radioButton {
                fail("a space pill announces as \(String(describing: pill.accessibilityRoleOverride)), expected .radioButton", &ok)
            }
            if !pill.isActivatable { fail("a space pill is not activatable", &ok) }
        }
        let selectedCount = pills.filter { $0.accessibilityValueOverride == "selected" }.count
        if selectedCount != 1 { fail("\(selectedCount) pills report as selected, expected exactly 1", &ok) }

        guard pills.count >= 3 else {
            fail("not enough pills to drive a selection", &ok)
            return
        }
        pills[2].performPrimaryAction()
        if picked != [.operations] {
            fail("clicking the third pill reported \(picked.map(\.rawValue)), expected [operations]", &ok)
        }
        if bar.selectedSpaceForTests != .operations {
            fail("the bar's own selection is \(bar.selectedSpaceForTests.rawValue) after a click on Operations", &ok)
        }
        // `setSelectedSpace` moves the pill without reporting - the path a
        // `\u{2318}N` shortcut or a restore takes.
        picked.removeAll()
        bar.setSelectedSpace(.stores)
        if !picked.isEmpty { fail("setSelectedSpace fired onSelectSpace - it must not", &ok) }
        if bar.selectedSpaceForTests != .stores { fail("setSelectedSpace did not move the selection", &ok) }

        if ok { print("  OK - geometry, shadow, no vibrancy, 5 radio pills, click and silent-select") }
    }

    // MARK: 5 - the bar cannot cap the window

    private static func checkBarDoesNotCapWindow(_ ok: inout Bool) {
        print("\n-- gotcha (13): the bar cannot set a window-width floor --")
        let bar = DaylightBarController()
        bar.loadView()

        for (description, priority) in bar.debugWidthConstraints() where priority >= 500 {
            fail("a bar width constraint sits at priority \(priority) - anything >= "
                 + "NSLayoutPriorityWindowSizeStayPut (500) can cap the window: \(description)", &ok)
        }

        // Measured, not reasoned: a real window carrying the bar has to hold a
        // width well below \u{00A7}6.3's own comfortable floor.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = bar
        for width in [CGFloat(1400), 900, 640, 520, 420] {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 200), display: true)
            let actual = window.frame.width
            if abs(actual - width) > 1.0 {
                fail("asked for a \(width)pt window, got \(actual)pt - the bar is capping it", &ok)
            }
        }
        if ok { print("  OK - every bar constraint < 500, and a real window holds 420pt") }
    }

    // MARK: canvas + drill header, driven through the real shell

    private static func checkCanvasAndDrillHeader(_ ok: inout Bool) {
        print("\n-- shell: the canvas is the landing, every drill page has a back button --")
        withScratchEnv {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let hostStore = HostStore()
            let keyStore = SSHKeyStore()
            let snippetStore = SnippetStore()
            let shell = AppShellController(
                hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
                console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
                settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                             snippetStore: snippetStore, dictationStore: DictationStore()),
                hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                shiftStore: ShiftStore(), dictationStore: DictationStore(),
                commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
                makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                     isFirstmateConsole: false) }
            )
            window.contentViewController = shell
            window.layoutIfNeeded()

            let canvas = shell.homeCanvasForTests

            // The canvas is eagerly mounted - it is the launch landing and
            // every back button's target, so it can never be a lazy slot.
            if !shell.mountedDestinationSlotsForTests.contains(.homeCanvas) {
                fail("the home canvas is not mounted at launch", &ok)
            }

            // Overview shows exactly the trimmed six (`fm/grandline-overview-
            // canvas-trim`); each other space shows only its own.
            shell.selectSpace(.overview)
            if Set(canvas.visibleModulesForTests) != overviewVisibleModules {
                fail("Overview shows \(Set(canvas.visibleModulesForTests).map(\.rawValue).sorted()), "
                     + "expected exactly \(overviewVisibleModules.map(\.rawValue).sorted())", &ok)
            }
            if canvas.moduleCardsForTests.count != overviewVisibleModules.count {
                fail("Overview built \(canvas.moduleCardsForTests.count) cards for "
                     + "\(overviewVisibleModules.count) modules", &ok)
            }
            for space in DaylightSpace.allCases where space != .overview {
                shell.selectSpace(space)
                let visible = Set(canvas.visibleModulesForTests)
                guard let expected = lockedMembership[space] else { continue }
                if visible != expected {
                    fail("\(space.rawValue) rendered \(visible.map(\.rawValue).sorted()), "
                         + "expected \(expected.map(\.rawValue).sorted())", &ok)
                }
                if canvas.moduleCardsForTests.count != expected.count {
                    fail("\(space.rawValue) built \(canvas.moduleCardsForTests.count) cards for "
                         + "\(expected.count) modules", &ok)
                }
                // \u{00A7}5.4's exact copy for a non-Overview space.
                let greeting = canvas.greetingForTests
                if greeting.title != space.title || greeting.subtitle != space.subtitle {
                    fail("\(space.rawValue) greeting is \(greeting), expected \((space.title, space.subtitle))", &ok)
                }
                // Selecting a space lands on the canvas, whichever page was up.
                if shell.drillHeaderIsHiddenForTests == false {
                    fail("selecting \(space.rawValue) left a drill header showing - it should be on the canvas", &ok)
                }
            }

            // The canvas has no drill header; every other destination does,
            // and its back button returns to the canvas with the space intact.
            shell.selectSpace(.stores)
            shell.show(.homeCanvas)
            if !shell.drillHeaderIsHiddenForTests || shell.drillHeaderHeightForTests != 0 {
                fail("the canvas shows a drill header (hidden=\(shell.drillHeaderIsHiddenForTests), "
                     + "height=\(shell.drillHeaderHeightForTests)) - the hub has no back", &ok)
            }

            for dest in RailDestination.allCases where dest != .homeCanvas {
                shell.show(dest)
                if shell.drillHeaderIsHiddenForTests {
                    fail("\(dest) has no drill header - it would have no way back", &ok)
                }
                if abs(shell.drillHeaderHeightForTests - HelmDrillHeader.height) > 0.01 {
                    fail("\(dest)'s drill header is \(shell.drillHeaderHeightForTests)pt tall", &ok)
                }
                if shell.drillHeaderForTests.titleForTests != dest.bodyTitle {
                    fail("\(dest)'s drill header says '\(shell.drillHeaderForTests.titleForTests)', "
                         + "expected '\(dest.bodyTitle)'", &ok)
                }
                // The real back path a click or a VoiceOver press takes.
                if !shell.drillHeaderForTests.debugActivateBack() {
                    fail("\(dest)'s back button did not activate", &ok)
                }
                if !shell.drillHeaderIsHiddenForTests {
                    fail("back from \(dest) did not land on the canvas", &ok)
                }
                // The space survives the round trip - the canvas is never
                // rebuilt, which is what \u{00A7}5.2's "keeps its last space
                // selection" means.
                if canvas.selectedSpace != .stores {
                    fail("the canvas lost its space over a \(dest) round trip: now \(canvas.selectedSpace.rawValue)", &ok)
                }
            }

            // The canvas rebuilds fifteen self-theming cards on every space
            // switch. Each card - and each card's gradient tile - registers a
            // `ThemeManager` observer and unregisters in `deinit`, so a card
            // that failed to deallocate would leak a dead closure per rebuild.
            //
            // **`autoreleasepool` is load-bearing here, and finding out why
            // cost real time.** A first version of this check without it
            // reported 224 leaked observers over 20 switches and a live-card
            // count climbing 69 -> 181, which reads exactly like a retain
            // cycle. It is not one: a headless suite never turns the run loop,
            // so nothing drains the pool that removed views are autoreleased
            // into, and every discarded card stays alive until the process
            // exits. Draining per switch reports a flat 69 -> 69. Any future
            // AppKit self-test that measures deallocation needs the same
            // wrapper, or it will chase a cycle that does not exist.
            autoreleasepool { shell.selectSpace(.overview) }
            let baselineObservers = ThemeManager.shared.observerCountForTests
            for _ in 0..<4 {
                for space in DaylightSpace.allCases {
                    autoreleasepool { shell.selectSpace(space) }
                }
            }
            autoreleasepool { shell.selectSpace(.overview) }
            let afterObservers = ThemeManager.shared.observerCountForTests
            if afterObservers > baselineObservers {
                fail("20 space switches left \(afterObservers - baselineObservers) extra ThemeManager "
                     + "observers behind (\(baselineObservers) -> \(afterObservers)) - a module card "
                     + "is not being deallocated", &ok)
            }

            // Overview's greeting comes from `FleetGreeting`, shared with the
            // Overview page - not a second implementation.
            shell.selectSpace(.overview)
            let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                         queuedCount: 0, doneCount: 0, projectsCount: 0,
                                         watcher: WatcherHealth(status: "healthy"))
            canvas.applyFleet(snapshot: snapshot, mergedPRs: [], prFetchFailure: nil)
            let greeting = canvas.greetingForTests
            if greeting.title != FleetGreeting.greeting(captain: "Manjesh") {
                fail("Overview greeting is '\(greeting.title)', expected FleetGreeting's own", &ok)
            }
            let expectedAnswer = FleetGreeting.answer(tasks: [], readyCount: 0,
                                                      prFetchFailure: nil, homeOk: true).canvasLine
            if greeting.subtitle != expectedAnswer {
                fail("Overview subtitle is '\(greeting.subtitle)', expected the answer banner's own line", &ok)
            }
            // GL-14: a failed PR scan must not read as a confident zero.
            canvas.applyFleet(snapshot: snapshot, mergedPRs: nil, prFetchFailure: "no network")
            if canvas.greetingForTests.subtitle.contains("0 PRs ready") {
                fail("a failed PR scan rendered as '0 PRs ready' - GL-14's exact rule", &ok)
            }

            if ok {
                print("  OK - eager canvas, per-space filtering and copy, drill headers on "
                      + "\(RailDestination.allCases.count - 1) destinations, back preserves the space")
            }
        }
    }

    // MARK: Helpers

    /// Scratch overrides for every store the shell builds, so this suite never
    /// touches the captain's real hosts/keys/snippets/tasks/dictation data -
    /// the same convention `AppShellBodyWidthSelfTest` established.
    // MARK: 7 - Phase 3: the modules are live, and honest before they are

    /// Two things Phase 2 shipped that only a behavioural check could catch,
    /// because both look completely correct in the source.
    ///
    /// 1. **The Setup and Vault modules never left their loading state.** Both
    ///    read `BackgroundSignalsPoller.lastCounts`, whose first pass lands
    ///    ~10s after launch. The canvas is the launch landing, so no
    ///    `viewWillAppear` fires afterwards, and nothing else the canvas
    ///    observed changed when a pass completed - so both cards said "hasn't
    ///    been checked yet this session" for the rest of the session. Fixed by
    ///    `BackgroundSignalsPoller.observeCounts`, and pinned here by driving a
    ///    real count publish and asserting the cards actually changed.
    ///
    /// 2. **`HomeCanvasController.applyDictationStatus` was dead code.** It
    ///    existed and was correct; nothing ever called it, so the Dictation
    ///    module's chip showed its initial value forever. Driven here through
    ///    the *real* `AppShellController.setDictationEngineStatus`, the same
    ///    entry point the engine's own callback uses - calling
    ///    `applyDictationStatus` directly would pass with the bug present.
    private static func checkLiveModuleWiring(_ ok: inout Bool) {
        print("\n-- modules: live data in, honest loading state before it arrives --")

        let poller = BackgroundSignalsPoller.shared
        // The poller is a process-wide singleton shared with every other check
        // in this suite, so its state is restored on the way out.
        let savedCounts = poller.lastCounts
        let savedCompletedAt = poller.lastCompletedPassAt
        defer {
            poller.debugSetLastCompletedPassAt(savedCompletedAt)
            poller.debugSetCounts(savedCounts)
        }

        withScratchEnv {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let hostStore = HostStore()
            let keyStore = SSHKeyStore()
            let snippetStore = SnippetStore()
            let shell = AppShellController(
                hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
                console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
                settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                             snippetStore: snippetStore, dictationStore: DictationStore()),
                hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                shiftStore: ShiftStore(), dictationStore: DictationStore(),
                commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
                makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                     isFirstmateConsole: false) }
            )
            window.contentViewController = shell
            window.layoutIfNeeded()
            let canvas = shell.homeCanvasForTests

            func card(_ module: DaylightModule) -> HelmModuleCard.Anatomy? {
                guard let index = canvas.visibleModulesForTests.firstIndex(of: module),
                      index < canvas.moduleCardsForTests.count else { return nil }
                return canvas.moduleCardsForTests[index].anatomyForTests
            }

            // --- The canvas actually subscribed. Without this the whole
            // transition below is untestable, and the bug is silent.
            if poller.debugCountsObserverCount == 0 {
                fail("the canvas registered no counts observer - Setup and Vault can never leave "
                     + "their loading state (Phase 3's whole point)", &ok)
            }

            // Updates/Bootstrap/Automation/GitHub Sync no longer render on
            // Overview (`fm/grandline-overview-canvas-trim`) - they live on
            // Engineering now, per the locked space table, and the
            // observer-driven live-update behaviour below is unaffected by
            // which space a card happens to be on, so it is exercised there.
            shell.selectSpace(.engineering)

            // --- 1a. Warming up: no pass has completed, no count exists.
            poller.debugSetLastCompletedPassAt(nil)
            poller.debugSetCounts(BackgroundSignalsPoller.SignalCounts())
            canvas.debugRenderNow()

            // All four Setup modules read the poller too now, not just the
            // one aggregate card - each must be honest about having no number
            // yet, or four cards go stale instead of one.
            for module in [DaylightModule.updates, .bootstrap, .automation, .githubSync] {
                guard let a = card(module) else {
                    fail("no \(module.rawValue) card rendered", &ok)
                    continue
                }
                // An honest loading state: it says it is checking, and it does
                // NOT claim a number or an "all current" verdict.
                if a.chipText != "Checking\u{2026}" {
                    fail("\(module.rawValue) shows chip \(a.chipText ?? "nil") before the first pass - "
                         + "expected a Checking\u{2026} chip", &ok)
                }
                let body = (a.noteTexts + a.metricTexts).joined(separator: " ")
                if !body.lowercased().contains("checking") {
                    fail("\(module.rawValue)'s pre-pass body is '\(body)' - it does not say it is checking", &ok)
                }
                if !a.metricTexts.isEmpty {
                    fail("\(module.rawValue) rendered metric text \(a.metricTexts) before any pass - "
                         + "a fabricated number is exactly GL-14's failure", &ok)
                }
                for word in ["Current", "0 issues", "All current"] where body.contains(word) {
                    fail("\(module.rawValue) claims '\(word)' before anything was checked", &ok)
                }
            }

            // --- 1b. A pass publishes real counts. The cards must change
            // WITHOUT any visit, refresh or space switch - the observer alone.
            poller.debugSetLastCompletedPassAt(Date())
            poller.debugSetCounts(.init(toolUpdates: 0, forkDrift: 0, vaultAttention: 2,
                                        setupDrift: 0, vaultSecrets: 7))
            // The canvas coalesces renders onto the next main-queue turn, so
            // one turn has to be drained - not a sleep, and not a re-render
            // this check performs itself.
            //
            // What this half proves, precisely: that the *content* a real
            // published count produces is right, and that it is no longer the
            // loading copy. It does NOT attribute the render to the counts
            // observer specifically - a window resize notification arriving
            // during the drained turn would relayout the grid too. The wiring
            // itself is proven by `debugCountsObserverCount` above (which is
            // what actually failed when the subscription was removed) and by
            // the fan-out count in 1c below.
            drainMainQueue()

            if let a = card(.bootstrap) {
                if a.chipText != "Current" {
                    fail("Bootstrap chip is \(a.chipText ?? "nil") after a clean pass, expected Current", &ok)
                }
                if a.metricTexts.isEmpty {
                    fail("Bootstrap still shows no progress figure after a pass published a count - "
                         + "the observer did not reach it", &ok)
                }
                if (a.noteTexts + a.metricTexts).joined().lowercased().contains("checking") {
                    fail("Bootstrap is still showing its loading copy after real data arrived", &ok)
                }
            } else { fail("no Bootstrap card after the pass", &ok) }

            // The other three Engineering cards read three different published
            // numbers, so each has to leave its loading state on its own -
            // one card working proves nothing about the other three.
            if let a = card(.updates) {
                if a.chipText != "Current" {
                    fail("Updates chip is \(a.chipText ?? "nil") after a pass reported 0 updates, expected Current", &ok)
                }
            } else { fail("no Updates card after the pass", &ok) }

            if let a = card(.githubSync) {
                if a.chipText != "In sync" {
                    fail("GitHub Sync chip is \(a.chipText ?? "nil") after a pass reported 0 drift, expected In sync", &ok)
                }
            } else { fail("no GitHub Sync card after the pass", &ok) }

            if let a = card(.automation) {
                if a.chipText != "Nothing to run" {
                    fail("Automation chip is \(a.chipText ?? "nil") after a clean pass, expected Nothing to run", &ok)
                }
                if (a.noteTexts + a.metricTexts).joined().lowercased().contains("checking") {
                    fail("Automation is still showing its loading copy after real data arrived", &ok)
                }
            } else { fail("no Automation card after the pass", &ok) }

            // --- 1c. An unchanged publish must not fan out. A pass runs every
            // 15 minutes and usually reports the same numbers; rebuilding
            // every visible card for no change is pure waste. Space-agnostic -
            // this exercises the poller's own fan-out logic, not a card.
            var fanouts = 0
            let probe = poller.observeCounts { _ in fanouts += 1 }
            poller.debugSetCounts(.init(toolUpdates: 0, forkDrift: 0, vaultAttention: 2,
                                        setupDrift: 0, vaultSecrets: 7))
            if fanouts != 0 { fail("an identical counts publish fanned out \(fanouts) time(s)", &ok) }
            poller.debugSetCounts(.init(toolUpdates: 1, forkDrift: 0, vaultAttention: 2,
                                        setupDrift: 0, vaultSecrets: 7))
            if fanouts != 1 { fail("a changed counts publish fanned out \(fanouts) time(s), expected 1", &ok) }
            poller.unobserveCounts(probe)

            // Vault and Dictation are on Stores now, likewise no longer on
            // Overview - repeat the same warming-up -> real-count cycle there.
            shell.selectSpace(.stores)

            poller.debugSetLastCompletedPassAt(nil)
            poller.debugSetCounts(BackgroundSignalsPoller.SignalCounts())
            canvas.debugRenderNow()

            if let a = card(.vault) {
                if a.chipText != "Checking\u{2026}" {
                    fail("Vault shows chip \(a.chipText ?? "nil") before the first pass - "
                         + "expected a Checking\u{2026} chip", &ok)
                }
                if !a.metricTexts.isEmpty {
                    fail("Vault rendered metric text \(a.metricTexts) before any pass - "
                         + "a fabricated number is exactly GL-14's failure", &ok)
                }
            } else { fail("no Vault card rendered before the first pass", &ok) }

            poller.debugSetLastCompletedPassAt(Date())
            poller.debugSetCounts(.init(toolUpdates: 0, forkDrift: 0, vaultAttention: 2,
                                        setupDrift: 0, vaultSecrets: 7))
            drainMainQueue()

            if let a = card(.vault) {
                if a.metricTexts.first != "7" {
                    fail("Vault metric is \(a.metricTexts.first ?? "nil") after a pass reported 7 secrets", &ok)
                }
                if a.chipText?.contains("2") != true {
                    fail("Vault chip is \(a.chipText ?? "nil") - it should carry the 2 tools needing a look", &ok)
                }
            } else { fail("no Vault card after the pass", &ok) }

            // --- 2. Dictation, through the real forwarding path. Still on
            // Stores, where Dictation now lives.
            for status in [DictationStatus.recording, .needsMicrophone, .ready] {
                shell.setDictationEngineStatus(status)
                drainMainQueue()
                guard let a = card(.dictation) else {
                    fail("no Dictation card rendered", &ok)
                    break
                }
                let expected: String
                switch status {
                case .recording: expected = status.title
                case .ready: expected = "Ready"
                default: expected = "Needs access"
                }
                if a.chipText != expected {
                    fail("Dictation chip is \(a.chipText ?? "nil") after the engine reported "
                         + "\(status) - expected \(expected). `applyDictationStatus` is not being called.", &ok)
                }
            }
        }

        if ok {
            print("  OK - canvas observes the poller, Setup/Vault load then fill in, "
                  + "no fan-out on an unchanged pass, dictation status reaches the hub")
        }
    }

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
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP - app sources are not next to this binary")
            return
        }
        let url = dir.appendingPathComponent("HomeCanvasController.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
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
