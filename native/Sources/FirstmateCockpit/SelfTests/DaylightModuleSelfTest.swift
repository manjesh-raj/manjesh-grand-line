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
                      checkUniformCardHeight, checkRowsEqualiseCardHeights,
                      checkNoCardIsAWindowFloor,
                      checkModuleAnatomy, checkCanvasConstructsNoStores,
                      checkBarAnatomy, checkBarDestinationIcons, checkBarDoesNotCapWindow,
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
        .command: [.console, .tasks, .mergeQueue, .commandLibrary],
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
    private static let overviewOnly: Set<DaylightModule> =
        [.briefing, .claudeStatus, .fleet, .strawHat]

    /// `fm/grandline-overview-canvas-trim`'s own captain decision, restated
    /// as literal data for the same reason `lockedMembership` above is: a
    /// test that reads `appearsOnOverview` to check `appearsOnOverview`
    /// asserts nothing. That decision named six modules as staying on the
    /// Overview canvas after a screenshot review.
    ///
    /// It is **seven** now, and the seventh is the captain's own explicit
    /// later ask: `fm/polish-straw-hat-overview-card-and-voice-c8d3` is him
    /// saying he expected the Straw Hat Pirates chat to be its own Overview
    /// card "like the Console card" rather than a tab inside Fleet's page.
    /// Raising the count is exactly the deliberate two-place edit this
    /// literal exists to force.
    ///
    /// It is **eight** now. `fm/grandline-claude-status-card-implement` is the
    /// captain picking a design for a Claude quota readout on the Home page
    /// and saying "we can start implementing this" - which, like the Straw
    /// Hat card before it, is him asking for a card on the landing rather
    /// than a surface he has to navigate to. Raising the count is exactly the
    /// deliberate two-place edit this literal exists to force.
    private static let overviewVisibleModules: Set<DaylightModule> =
        [.briefing, .claudeStatus, .fleet, .strawHat, .mergeQueue, .console, .health, .schedules]

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
        // (`fm/grand-line-whiteboard-excalidraw`), Kubernetes
        // (`fm/grandline-k8s-cluster-tail`), Sticky Board
        // (`fm/grandline-sticky-board`) and Code Preview
        // (`fm/grandline-monaco-code-preview`) - all six new modules with
        // `appearsOnOverview == false`, matching their space siblings. The
        // Kubernetes card in particular has nothing to show without a live
        // session and a chosen feed tab, so it belongs on Operations beside
        // Log Analyzer rather than on the pulse-check hub; Sticky Board and
        // Code Preview are Stores utilities like every one of their
        // neighbours there.
        //
        // The literal is deliberate: the captain's own trim decision names the
        // six that *stay*, so a module quietly gaining an Overview card is the
        // regression this catches. Adding a module means bumping this by one
        // and saying why, which is what every line above did.
        //
        // 18 -> 19: `fm/implement-grand-line-secrets-vault-poneg-ad` added
        // `.poneglyph` (Setup's fifth tab - Automic Vault's hardening panel at
        // the time, the captain's own credential vault since
        // `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`). It is trimmed
        // from Overview like every other Setup card - and this check is what
        // caught it defaulting to *visible* there, which would have put a
        // seventh card on Overview against the captain's own locked decision.
        //
        // 20 -> 21: `fm/grandline-feature-f1-notebook` added `.notebook`
        // (F1 of full review #3 §8). It is a Stores utility like Docs,
        // Runbooks and Postmortems beside it, so it is trimmed from Overview
        // for the same reason they are - the canvas's seven cards are the
        // captain's own locked decision, and a notebook is a surface you open
        // when you have something to write down rather than one you check in
        // on each morning.
        // `fm/grandline-feature-f4-reading-list` made it 22, adding the Reading
        // List (F4 of the same section) on the same reasoning: a link inbox is
        // a Stores surface you open when you have something to file or
        // something to read, not one you check in on each morning.
        if trimmed.count != 22 {
            fail("expected exactly 22 modules trimmed from Overview, got \(trimmed.count): "
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

        // Every module belongs somewhere reachable, and every space that
        // *filters the canvas* has something in it - such a pill filtering to
        // nothing is a dead end.
        //
        // `fm/grandline-overview-page-daily-review`: a space that owns a
        // destination is not a filter and legitimately has no modules, so it
        // is checked for the other property instead - that the page its pill
        // opens is a real destination that maps back to this pill. Written as
        // an either/or rather than an exemption list, so a sixth kind of pill
        // cannot slip through by being neither.
        for space in DaylightSpace.allCases {
            if let destination = space.destination {
                if space.filtersCanvas {
                    fail("space \(space.rawValue) owns \(destination) and still claims to filter the canvas", &ok)
                }
                if destination.title.isEmpty {
                    fail("space \(space.rawValue) opens \(destination), which has no title", &ok)
                }
                if DaylightModule.space(forDestination: destination) != space {
                    fail("\(destination) does not map back to the \(space.rawValue) pill - "
                         + "every deep link and \u{2318}K would light the wrong one", &ok)
                }
                continue
            }
            if DaylightModule.allCases.filter({ $0.isVisible(in: space) }).isEmpty {
                fail("space \(space.rawValue) has no modules at all", &ok)
            }
        }

        // §5.4's copy, and the shortcut indices `⌘1`…`⌘5` carry.
        // Review #3 §7 renamed the first pill "Overview" -> "Home"; the
        // literal list is restated here rather than derived, exactly as
        // `checkSpaceTable`'s own header requires.
        // `fm/grandline-overview-page-daily-review` put the new Overview pill
        // leftmost on the captain's own ask, which moved Home to the second
        // slot and its shortcut from \u{2318}1 to \u{2318}2.
        let expectedTitles = ["Overview", "Home", "Command", "Operations", "Stores", "Engineering"]
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
            print("  OK - 4 spaces x their locked modules, \(overviewOnly.count) Overview-only, Overview trimmed to "
                  + "\(overviewVisibleModules.count), \(DaylightSpace.allCases.count) pills in shortcut order")
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
        // `fm/implement-grand-line-secrets-vault-poneg-ad` had added
        // `.poneglyph` between GitHub Sync and Settings, and
        // `fm/swap-vault-poneglyph-naming-in-grand-lin-1f` later swapped which
        // feature `.poneglyph` shows (see `VaultController.swift`'s header)
        // with no change to its position here. `fm/move-poneglyph-to-stores-space-282a`
        // then moved `.poneglyph` itself out of Engineering into Stores (see
        // `DaylightSpace.swift`'s `space` table), so it no longer appears in
        // this lineup at all. `.settings` stays last, as the captain's own
        // refinement put it.
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

        // The real five, at their most demanding: the longest key this card
        // ever draws ("Session (5h)" uppercases to 12 characters) and the
        // longest figure ("$137.62").
        let stripColumns: [HelmModuleStripColumn] = [
            .init(label: "Session (5h)", value: "96%", fill: 0.96, state: .bad),
            .init(label: "Week", value: "70%", fill: 0.70, state: .ok),
            .init(label: "Fable week", value: "100%", fill: 1, state: .bad),
            .init(label: "Extra usage", value: "$137.62", fill: 0.98, state: .bad),
            .init(label: "Spend cap", value: "$140", fill: 1, state: .idle),
        ]

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
            // The Claude status strip, at the span-2 width it is really
            // built for and carrying the widest realistic figures - a
            // six-character dollar amount under an eleven-character key.
            measure("statusStrip", .statusStrip(stripColumns, perRow: HelmModuleCard.maxStripColumns),
                    width: spanTwo)
            // And the same five columns on a card `packRows` degraded to one
            // column, which wraps them into two rows rather than truncating.
            measure("statusStrip-1col",
                    .statusStrip(stripColumns,
                                 perRow: HomeCanvasController.claudeStripColumnsPerRow(forCardWidth: narrow)),
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

    private static func checkBarAnatomy(_ ok: inout Bool) {
        print("\n-- floating bar: \u{00A7}6.3's geometry, its pills, and no `.behindWindow` vibrancy --")
        let bar = DaylightBarController()
        bar.loadView()
        // 1512, the captain's own screen width, deliberately above
        // `DaylightBarController.quickAccessCollapseWidth`: review #3's B6
        // gives the shortcut row back to the drill title on a narrow bar, so
        // below that width every one of these buttons is legitimately zero
        // wide and what this case measures would not exist. The expanded row
        // is the state it was written for.
        bar.view.frame = NSRect(x: 0, y: 0, width: 1512, height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()

        let geometry = bar.geometryForTests
        // gotcha (8): the single most-repeated bug class in this codebase.
        //
        // **This used to assert the bar contained no `NSVisualEffectView` at
        // all.** The UI modernization audit's B1 corrected that reading:
        // gotcha (8) is a finding about `.behindWindow`, which composites
        // against the *desktop* and therefore renders the wrong tint on every
        // theme. `.withinWindow` composites against this window's own content
        // and is what the audit asks for here, with its own §6 constraint list
        // keeping the `.behindWindow` ban intact by name. So the assertion is
        // inverted to the thing that was actually true all along - and made
        // stronger, because it now names the mode rather than the class.
        //
        // `checkBarMaterial` (in `BarNavigationModernizationSelfTest`) carries
        // the other half: that the material is *present* on the Daylight
        // family and *absent* on the twelve legacy palettes.
        if geometry.visualEffectBlendingModes.contains(.behindWindow) {
            fail("the bar contains a `.behindWindow` NSVisualEffectView - AGENTS.md gotcha (8) forbids it, and the audit's own \u{00A7}6 keeps that ban", &ok)
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
        // The fourth pill since `fm/grandline-overview-page-daily-review` put
        // the Overview page's own pill leftmost - Home, Command and Operations
        // each shifted right by one.
        pills[3].performPrimaryAction()
        if picked != [.operations] {
            fail("clicking the fourth pill reported \(picked.map(\.rawValue)), expected [operations]", &ok)
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

        if ok { print("  OK - geometry, shadow, no vibrancy, \(pills.count) radio pills, click and silent-select") }
    }

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

    private static func checkBarDestinationIcons(_ ok: inout Bool) {
        print("\n-- bar quick-access: six icons drawn, the seventh in the overflow menu (UX2) --")
        let bar = DaylightBarController()
        bar.loadView()
        // 1512, the captain's own screen width, deliberately above
        // `DaylightBarController.quickAccessCollapseWidth`: review #3's B6
        // gives the shortcut row back to the drill title on a narrow bar, so
        // below that width every one of these buttons is legitimately zero
        // wide and what this case measures would not exist. The expanded row
        // is the state it was written for.
        bar.view.frame = NSRect(x: 0, y: 0, width: 1512, height: DaylightBarController.height + DaylightBarController.topMargin)
        bar.view.layoutSubtreeIfNeeded()

        // Typed out as a literal rather than read back from
        // `debugDestinationButtons()`, for the same reason `lockedMembership`
        // above is: a test that derives its expectation from the thing it is
        // checking would pass for *any* set of icons in *any* order. Adding
        // one is therefore a deliberate two-place edit - which is what made
        // `fm/grandline-daylight-console-shortcut`'s own seven-site wiring
        // (declaration, target/action loop, `addSubview`, the constraint
        // chain, `keyViewChain`, `iconSquares`, `debugDestinationButtons`)
        // verifiable rather than merely compiled. Only two of those seven
        // fail loudly - a missing constraint collapses the row, a missing
        // `addSubview` traps on "no common ancestor". The other five render a
        // pixel-identical bar, and each was confirmed to fail here by name.
        // **Review #3's UX2 capped the drawn row at six**, so the expectation
        // is now in two halves: the captain's whole *pinned* list (which is
        // still the seven that shipped, in their shipped order - that default
        // is the migration, not a redesign) and the *drawn* prefix of it.
        //
        // Both are typed out as literals rather than read back from
        // `debugDestinationButtons()` / `QuickAccessConfiguration`, for the
        // reason this case has always given: a check that derives its
        // expectation from the thing it is checking passes for any set of
        // icons in any order, including an accidental duplicate or a
        // reordering that moves an icon the captain has muscle memory for.
        // Adding a shortcut stays a deliberate two-place edit.
        let pinned: [RailDestination] = [.stickyBoard, .codePreview, .shift, .strawHat, .poneglyph, .console, .hosts]
        if bar.quickAccessConfiguration.pinned != pinned {
            fail("the default pinned row is \(bar.quickAccessConfiguration.pinned.map(\.title)), expected \(pinned.map(\.title))", &ok)
        }
        let expected = Array(pinned.prefix(QuickAccessConfiguration.visibleLimit))
        let buttons = bar.debugDestinationButtons()
        guard buttons.count == expected.count else {
            fail("expected \(expected.count) quick-access icons (UX2's cap), found \(buttons.count)", &ok)
            return
        }
        if buttons.map(\.destination) != expected {
            fail("quick-access icons are \(buttons.map { $0.destination.title }), expected \(expected.map(\.title))", &ok)
        }
        // The seventh is reachable rather than dropped - that is the whole
        // difference between a cap and a deletion.
        let overflowed = pinned.dropFirst(QuickAccessConfiguration.visibleLimit).map(\.title)
        let menuTitles = bar.debugQuickAccessOverflowMenu().items.map(\.title)
        for title in overflowed where !menuTitles.contains(title) {
            fail("\(title) is past UX2's cap and is not in the overflow menu either - it is unreachable from the bar", &ok)
        }

        // The glyph is each destination's OWN symbol, so the bar icon and the
        // page it opens can never drift apart. A symbol name that does not
        // resolve renders as an invisible button with no error anywhere,
        // which this app has shipped before ("anchor", which is not an SF
        // Symbol at all).
        //
        // **This used to also assert `debugUsesArtwork == (drillHeaderArtwork
        // != nil)`, i.e. that Straw Hat Pirates' bar icon rendered the Jolly
        // Roger raster** (`fm/strawhat-toolbar-shortcut-use-jolly-roger-icon-
        // 69c3`). The UI modernization audit's B2 reverses that deliberately:
        // five saturated raster tiles between grey symbol squares is what it
        // calls "the noisiest thing in the app", and its preferred fix
        // reserves the artwork for the destination *pages*. So the assertion
        // is inverted rather than deleted - every shortcut is a symbol now,
        // and the artwork still has to be reachable from the same
        // `RailDestination`, which is what the earlier fix was really about.
        for button in buttons {
            if !button.debugHasIcon {
                fail("\(button.destination.title): its icon (symbol '\(button.destination.symbol)') did not resolve - the icon is invisible", &ok)
            }
            if button.debugSymbolName != button.destination.symbol {
                fail("\(button.destination.title): renders '\(button.debugSymbolName)', expected its own RailDestination.symbol '\(button.destination.symbol)'", &ok)
            }
            if button.accessibilityLabel() != button.destination.title {
                fail("\(button.destination.title): accessibility label is \(button.accessibilityLabel() ?? "nil"), expected the destination title", &ok)
            }
        }

        // Order, measured rather than assumed: the captain's own reviewed
        // layout is search -> Recents -> Sticky Board -> Code Preview ->
        // Tasks -> Straw Hat Pirates -> Poneglyph -> Console -> theme toggle
        // -> bell -> avatar.
        let searchMaxX = bar.debugSearchPill().frame.maxX
        let toggleMinX = bar.debugThemeToggleButton().frame.minX
        let bellMinX = bar.notificationCenter.bell.frame.minX
        // UX2 moved these buttons inside an `NSStackView`, so their own
        // `frame` is in that row's coordinate space rather than the bar's -
        // comparing it against the search pill's bar-space frame directly
        // would be comparing two different origins, which is a check that
        // fails for a reason that is not the one it names. Converted into the
        // bar's space, which is the space every other number here is in.
        //
        // Asserted rather than assumed: the row must actually be somewhere,
        // or every comparison below is against a zero rect and vacuous.
        let barView = bar.view
        func barFrame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: barView) }
        if buttons.contains(where: { barFrame($0).width <= 0 }) {
            fail("a quick-access button has no laid-out width - the order checks below would be vacuous", &ok)
        }
        for button in buttons where barFrame(button).width > 0 {
            if barFrame(button).minX < searchMaxX {
                fail("\(button.destination.title) sits before the search pill", &ok)
            }
            if barFrame(button).maxX > toggleMinX {
                fail("\(button.destination.title) sits after the theme toggle - it must come immediately before it", &ok)
            }
        }
        // Pairwise rather than a single comparison, so a third (or fourth)
        // icon landing out of order fails by name instead of only the first
        // two being checked.
        for (left, right) in zip(buttons, buttons.dropFirst()) {
            if barFrame(left).minX >= barFrame(right).minX {
                fail("\(left.destination.title) should sit left of \(right.destination.title)", &ok)
            }
        }
        if toggleMinX >= bellMinX {
            fail("the theme toggle should still sit before the bell", &ok)
        }
        // Square, and the same side as the toggle and bell beside them - three
        // icon squares of different sizes in one row is exactly the "two icon
        // button languages" finding this app's own UI audit spent a phase
        // undoing.
        for button in buttons {
            if abs(button.frame.width - DaylightBarIconButton.side) > 0.5
                || abs(button.frame.height - DaylightBarIconButton.side) > 0.5 {
                fail("\(button.destination.title) is \(button.frame.size), expected \(DaylightBarIconButton.side)pt square", &ok)
            }
        }

        // A real click through the button's own target/action reports the
        // destination - a button wired to nothing renders identically.
        var picked: [RailDestination] = []
        bar.onSelectDestination = { picked.append($0) }
        for button in buttons { button.performClick(nil) }
        if picked != expected {
            fail("clicking every icon reported \(picked.map(\.title)), expected \(expected.map(\.title))", &ok)
        }

        // Both icons re-tint with the theme like every other control on the
        // bar - they share `DaylightBarIconButton.applyTheme` with the toggle,
        // so this catches a caller that forgot to include them in the sweep.
        for id in ["helm-light", "helm-dark"] {
            guard let theme = HelmTheme.theme(id: id) else { continue }
            bar.applyThemeForTests(theme)
            for button in buttons where button.debugIconBackground.layer?.backgroundColor == nil {
                fail("\(id): \(button.destination.title) has no icon-square fill after a theme change", &ok)
            }
        }

        // Every icon is reachable by keyboard too - the bar's own half of
        // §8's key loop. A control added to the row but not to the chain is
        // invisible to Tab and renders identically.
        let chain = bar.keyViewChain
        for button in buttons where !chain.contains(where: { $0 === button }) {
            fail("\(button.destination.title) is missing from the bar's key view chain", &ok)
        }

        if ok { print("  OK - \(buttons.count) icons, right order, right glyphs, real clicks, themed, in the key loop") }
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
        let window = OffScreenProbe.window(width: 1200, height: 200, styleMask: [.titled, .resizable])
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
            let window = OffScreenProbe.window(width: 1400, height: 900, styleMask: [.titled, .resizable])
            let hostStore = HostStore()
            let keyStore = SSHKeyStore()
            let snippetStore = SnippetStore()
            // **Not a first-run app.** Review #3's UX13 gave the hub a
            // first-run hero for a captain with nothing saved, and
            // `withScratchEnv` gives this case exactly that - empty stores -
            // so without a seeded task the hero below is legitimately the
            // welcome banner and this case's all-clear assertions would be
            // checking the wrong state. One task is the cheapest way to say
            // "this app has been used", and UX13's own case asserts the
            // first-run half.
            let shiftStore = ShiftStore()
            var seeded = ShiftTask.fresh()
            seeded.title = "a task, so the hub is not in its first-run state"
            shiftStore.addTask(seeded)
            let shell = AppShellController(
                hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
                console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
                settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                             snippetStore: snippetStore, dictationStore: DictationStore()),
                hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                shiftStore: shiftStore, dictationStore: DictationStore(),
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
            // `fm/straw-hat-voice-order-composer-polish-8dd2`: the captain's
            // second ordering ask - Straw Hat Pirates should render LAST on
            // Overview, after every other visible card, reversing the earlier
            // "beside the briefing and the fleet board" placement. `canvasOrder`
            // is `allCases` (declaration order), so this is checked as a real
            // ordering property of the rendered list, not just membership -
            // `visibleModulesForTests` preserves `canvasOrder`'s own order
            // among whichever modules pass `isVisible(in: .overview)`.
            if canvas.visibleModulesForTests.last != .strawHat {
                fail("Straw Hat Pirates must be the LAST card on Overview, got "
                     + "\(canvas.visibleModulesForTests.map(\.rawValue))", &ok)
            }
            // A space that owns a destination is a page, not a canvas filter -
            // it is driven in its own case below rather than swept here.
            for space in DaylightSpace.allCases where space != .overview && space.filtersCanvas {
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

            // `fm/grandline-overview-page-daily-review`: the sixth pill is a
            // page, and this is the behavioural half of that - a real click
            // path (`selectSpace`, which is what the pill's own handler calls)
            // landing on a real mounted destination, with the canvas's own
            // filter left where the captain had it.
            //
            // Discriminating power first: the canvas is parked on a space that
            // is NOT the one being clicked, so "the filter survived" cannot
            // pass by accident.
            shell.selectSpace(.command)
            for space in DaylightSpace.allCases where !space.filtersCanvas {
                guard let destination = space.destination else { continue }
                shell.selectSpace(space)
                if !shell.mountedDestinationSlotsForTests.contains(destination.slot) {
                    fail("selecting \(space.rawValue) did not mount \(destination)", &ok)
                }
                // Which page is showing, read off the shell's own current
                // destination rather than off the drill header's title.
                //
                // `fm/grandline-overview-layout-fix-gmail-settings`: a pill's
                // own page is top-level, so it has no drill header to read -
                // and the drill header's title was never the thing under test
                // here anyway. `currentContextTitle` is what the window title
                // and the Recents list already read.
                if shell.currentContextTitle != destination.title {
                    fail("\(space.rawValue)'s pill opened "
                         + "'\(shell.currentContextTitle ?? "nothing")', expected '\(destination.title)'", &ok)
                }
                if let view = shell.destinationViewIfMountedForTests(destination.slot),
                   view.isHiddenOrHasHiddenAncestor {
                    fail("\(space.rawValue)'s pill mounted \(destination) but left it hidden", &ok)
                }
                if canvas.selectedSpace != .command {
                    fail("selecting \(space.rawValue) changed the canvas's own filter to "
                         + "\(canvas.selectedSpace.rawValue) - a page pill must not touch it", &ok)
                }
            }

            // The canvas has no drill header; every other destination does,
            // and its back button returns to the canvas with the space intact.
            shell.selectSpace(.stores)
            shell.show(.homeCanvas)
            if !shell.drillHeaderIsHiddenForTests {
                fail("the canvas shows a drill cluster in the bar - the hub has no back", &ok)
            }
            // A2: the wordmark and the space pills are the canvas's own
            // leading area, and they only come back if the swap is genuinely
            // two-way.
            if shell.bar.wordmarkIsHiddenForTests {
                fail("the canvas hides the wordmark - the leading swap is one-way", &ok)
            }
            if shell.bar.pillsAreHiddenForTests {
                fail("the canvas hides the space pills - they only collapse on a drill page", &ok)
            }

            // `fm/grandline-overview-layout-fix-gmail-settings`: the canvas is
            // no longer the only top-level page. A space pill that opens a
            // page of its own (`DaylightSpace.destination` - the Overview tab
            // is the first) is still the top of the navigation, so it keeps
            // the wordmark and the pills exactly as the canvas does. The
            // sweep below is about **drill** pages; a page opened by a pill
            // is asserted the other way, immediately after it.
            let topLevel = Set(DaylightSpace.allCases.compactMap(\.destination) + [.homeCanvas])
            for dest in RailDestination.allCases where !topLevel.contains(dest) {
                shell.show(dest)
                if shell.drillHeaderIsHiddenForTests {
                    fail("\(dest) has no drill header - it would have no way back", &ok)
                }
                // A2: a drill page collapses the pills to make room for the
                // cluster and the page's own actions - measured, they do not
                // all fit (see `DaylightBarController`'s header).
                if !shell.bar.pillsAreHiddenForTests {
                    fail("\(dest) leaves the space pills showing beside the drill cluster", &ok)
                }
                if !shell.bar.wordmarkIsHiddenForTests {
                    fail("\(dest) shows the wordmark and the drill title at once", &ok)
                }
                // `fm/grandline-separate-setup-destinations`: this used to
                // read `dest.bodyTitle`, a property whose only job was to
                // report "Setup" for the four Engineering setup destinations
                // regardless of which one was showing. With that property
                // gone, this sweep *is* the behavioural guard that every
                // destination's drill header names the page the captain
                // actually opened - there is nowhere left for a lumped title
                // to hide.
                if shell.drillHeaderForTests.titleForTests != dest.title {
                    fail("\(dest)'s drill header says '\(shell.drillHeaderForTests.titleForTests)', "
                         + "expected '\(dest.title)'", &ok)
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

            // The other half of that rule: a pill that opens a page must not
            // hide the pill strip it was pressed on. Shipped that way once -
            // the captain reported the new Overview tab rendering with a back
            // arrow and no tabs at all.
            for space in DaylightSpace.allCases {
                guard let dest = space.destination else { continue }
                shell.selectSpace(space)
                if !shell.drillHeaderIsHiddenForTests {
                    fail("\(dest) is a pill's own page - it should carry no drill cluster", &ok)
                }
                if shell.bar.pillsAreHiddenForTests {
                    fail("\(dest) hid the space pills the captain pressed to get there", &ok)
                }
                if shell.bar.wordmarkIsHiddenForTests {
                    fail("\(dest) hid the wordmark - it is a top-level page, not a drill", &ok)
                }
            }
            shell.selectSpace(.stores)
            shell.show(.homeCanvas)

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

            // Overview's hero comes from `FleetGreeting`, shared with the
            // Overview page - not a second implementation.
            //
            // C1 changed *which* of that type's values the hero renders, and
            // this assertion is inverted rather than deleted for the reason
            // this codebase has had to relearn several times: an assertion
            // left pinning the old shape is a record of the old behaviour,
            // and silently keeps passing for the wrong reason. Before C1 the
            // hero was a time-of-day greeting over `answer.canvasLine`; it is
            // now the answer banner itself - badge, kicker, headline, detail -
            // which is what gives the hub the focal point §3C asks for.
            shell.selectSpace(.overview)
            let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                         queuedCount: 0, doneCount: 0, projectsCount: 0,
                                         watcher: WatcherHealth(status: "healthy"))
            canvas.applyFleet(snapshot: snapshot, mergedPRs: [], prFetchFailure: nil)
            let greeting = canvas.greetingForTests
            let expected = FleetGreeting.answer(tasks: [], readyCount: 0,
                                                prFetchFailure: nil, homeOk: true)
            if greeting.title != expected.title {
                fail("Overview hero headline is '\(greeting.title)', expected the answer banner's own "
                     + "'\(expected.title)'", &ok)
            }
            // **Review #3's UX5 deliberately split the detail line here.**
            // The all-clear `meta` enumerates the two cards drawn directly
            // under this hero ("N crew working" is the Fleet card, the PR
            // clause is the Merge queue card), which is the finding's "the
            // same fact appears three times". On the hub - and only there -
            // it is replaced with how fresh the reading is, which is the one
            // thing no card below can say.
            //
            // So the assertion inverts rather than being deleted (this case's
            // own rule, two comments up): the hub must NOT restate the cards,
            // and must say when it read.
            if !expected.metaRestatesCards {
                fail("the all-clear answer no longer declares its meta a restatement - UX5's substitution is dead code", &ok)
            }
            if greeting.subtitle == expected.meta {
                fail("the hub hero is still restating the Fleet and Merge queue cards below it: '\(greeting.subtitle)'", &ok)
            }
            if !greeting.subtitle.hasPrefix("Fleet read ") {
                fail("Overview hero detail is '\(greeting.subtitle)', expected the freshness line UX5 put there", &ok)
            }
            if greeting.kicker != expected.kicker.uppercased() {
                fail("Overview hero kicker is '\(greeting.kicker)', expected '\(expected.kicker.uppercased())'", &ok)
            }
            // GL-14: a failed PR scan must not read as a confident zero.
            canvas.applyFleet(snapshot: snapshot, mergedPRs: nil, prFetchFailure: "no network")
            if canvas.greetingForTests.subtitle.contains("0 PRs ready") {
                fail("a failed PR scan rendered as '0 PRs ready' - GL-14's exact rule", &ok)
            }
            // GL-14 again, and the half UX5's substitution could have broken:
            // the hub's hero must still say the reading is partial. That lives
            // in the *kicker* and the headline ("Partly unknown" / "Nothing
            // **known** needs you"), which the freshness line does not touch -
            // asserted here rather than assumed, because a substitution that
            // swallowed the failure state would look exactly like this one.
            if canvas.greetingForTests.kicker != "PARTLY UNKNOWN" {
                fail("a failed PR scan left the hub kicker at '\(canvas.greetingForTests.kicker)' - "
                     + "UX5's freshness line must not hide a partial reading", &ok)
            }

            if ok {
                print("  OK - eager canvas, per-space filtering and copy, drill navigation in the bar on "
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
            let window = OffScreenProbe.window(width: 1400, height: 900, styleMask: [.titled, .resizable])
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
                // An honest loading state: it says it is still looking, and it
                // does NOT claim a number or an "all current" verdict.
                //
                // **Review #3's UI10 moved where it says so, and this case
                // moved with it** rather than being left beside a new one.
                // Five of these cards render side by side on Engineering, and
                // a `Checking\u{2026}` chip over a sentence beginning
                // "Checking" - on all five, for the ~10s the first pass takes
                // - read as one wall of identical cards rather than as five
                // loading ones. The chip and the sentence are gone from the
                // body; D3's skeleton says "not yet" by shape, and the
                // sentence moved to the card's hover text.
                //
                // The property this case has always guarded is unchanged: the
                // card must not look finished before it has an answer. It is
                // asserted against what actually carries that now.
                if a.chipText != nil {
                    fail("\(module.rawValue) shows chip \(a.chipText ?? "nil") before the first pass - "
                         + "five identical chips are what UI10 removed", &ok)
                }
                if !a.showsSkeleton {
                    fail("\(module.rawValue) shows no D3 skeleton before the first pass - "
                         + "nothing on the card says it is still looking", &ok)
                }
                if !(a.toolTip ?? "").lowercased().contains("checking") {
                    fail("\(module.rawValue)'s hover text is '\(a.toolTip ?? "nil")' - "
                         + "it no longer says what is being checked", &ok)
                }
                let body = (a.noteTexts + a.metricTexts).joined(separator: " ")
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

            // The Automic-Vault-counts card and Dictation are no longer on
            // Overview - repeat the same warming-up -> real-count cycle where
            // each of them actually lives now.
            //
            // `fm/implement-grand-line-secrets-vault-poneg-ad` originally
            // repointed these three assertions from `.vault` to `.poneglyph`,
            // since Automic Vault's hardening panel was Poneglyph under Setup
            // at the time. `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`
            // swapped which feature each destination shows - Automic Vault's
            // panel reclaimed `.vault`/Stores, so these assertions (about
            // *Automic Vault's* secret/attention counts arriving from
            // `BackgroundSignalsPoller`) move back to `.vault` here. The
            // `.poneglyph` card is now the captain's own credential vault,
            // whose count is inside the ciphertext and is deliberately never
            // read from a poller.
            shell.selectSpace(.stores)

            poller.debugSetLastCompletedPassAt(nil)
            poller.debugSetCounts(BackgroundSignalsPoller.SignalCounts())
            canvas.debugRenderNow()

            if let a = card(.vault) {
                // UI10, as above: the loading state is D3's skeleton plus the
                // hover text, not a chip and a sentence.
                if a.chipText != nil {
                    fail("Vault shows chip \(a.chipText ?? "nil") before the first pass - "
                         + "five identical chips are what UI10 removed", &ok)
                }
                if !a.showsSkeleton {
                    fail("Vault shows no D3 skeleton before the first pass", &ok)
                }
                if !(a.toolTip ?? "").lowercased().contains("checking") {
                    fail("Vault's hover text is '\(a.toolTip ?? "nil")' - it no longer says "
                         + "what is being checked", &ok)
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

            // --- 2. Dictation, through the real forwarding path. On Stores,
            // where Dictation lives.
            shell.selectSpace(.stores)
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
