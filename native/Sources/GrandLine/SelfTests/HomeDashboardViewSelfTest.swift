// Grand Line - native macOS app.
//
// The render half of the Home page's dashboard layout
// (`fm/grandline-home-page-visual-overhaul`). `HomeDashboardSelfTest` owns
// the arithmetic; this file owns what a real `NSWindow` actually builds.
//
// Run with `FM_RUN_HOME_DASHBOARD_VIEW_TESTS=1 .build/debug/GrandLine`.
//
// **Why this suite is window-backed.** Every case below reads a resolved
// `NSView.frame` or a real view tree after a real layout pass. That is the
// AGENTS.md test - what the suite *asserts*, not what it imports - so it is
// listed in `NEEDS_SESSION` and runs in CI's windowed lane, while the
// arithmetic it rests on runs in the blocking one.
//
// What it covers:
//
//   1. **The hub has one card at the top, not two.** The captain's reference
//      draws a single attention card carrying the Refresh button and the
//      fleet-freshness subline; the app drew a hero band over a separate
//      card. The check is that the band is gone *on Overview and only
//      there* - the four other spaces still head themselves with it, and a
//      change that hid it everywhere would leave them nameless.
//   2. **The five widgets are placed, not packed.** Two rows; the Claude
//      card beside a column of two; Merge queue beside Health. This is the
//      defect the captain reported - the wrapping grid packed the same five
//      cards 2+2+1 / 1+1 at his window size, leaving most of a row empty.
//   3. **The row really is 7:5 and really does fill the page.** Read off the
//      resolved frames, so a 499 width constraint that AppKit declined to
//      satisfy fails here rather than looking right in the arithmetic suite.
//   4. **It degrades.** Narrow the window past the point a 5-track card
//      fits and the hand-placed layout must hand back to the wrapping grid
//      rather than drawing two unreadably narrow columns.
//   5. **The two restyled bodies carry real numbers.** The Fleet card's
//      three tiles and the Merge queue's "Showing 3 of 33" footer are the
//      reference's own furniture, and both are the kind of thing that can
//      be configured and never painted.
//   6. **Both themes paint.** Daylight and Dusk, asserting the card surface
//      really changed between them - a theming check that cannot fail is
//      worse than none.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum HomeDashboardViewSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkTheHubHasOneHeaderCard(&ok)
        checkTheFiveWidgetsArePlaced(&ok)
        checkTheRowIsSevenToFive(&ok)
        checkItDegradesWhenNarrow(&ok)
        checkTheFleetTilesAndMergeFooter(&ok)
        checkBothThemesPaint(&ok)

        if ok {
            print("HomeDashboardViewSelfTest: all checks passed")
        } else {
            print("HomeDashboardViewSelfTest: FAILED")
        }
        return ok
    }

    // MARK: Fixtures

    /// The window width the captain uses, which is what the reference was
    /// drawn against.
    private static let wide = NSSize(width: 1512, height: 1000)

    /// One `ShiftStore` per case, pointed at its own scratch directory - the
    /// same arrangement `NeedsAttentionViewSelfTest` documents, and for its
    /// reason: every bare store in the process otherwise shares one
    /// directory, so one case's seeded rows become the next case's fixture.
    private static func withScratchShift(_ body: (ShiftStore) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-dashboard-shift-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    /// **Not a first-run app.** Review #3's UX13 gives the hub its own
    /// invitation copy when nothing at all has been saved locally, and every
    /// case here runs over empty scratch stores - which is exactly that
    /// state. One seeded task is what puts these cases in the state they are
    /// written for, and it is the same thing `CanvasListsControlsSelfTest`
    /// does for its own reason.
    private static func makeCanvas(_ shiftStore: ShiftStore) -> HomeCanvasController {
        var seeded = ShiftTask.fresh()
        seeded.title = "a task, so the hub is not in its first-run state"
        shiftStore.addTask(seeded)
        let canvas = HomeCanvasController(sources: .init(
            shiftStore: shiftStore,
            hostStore: HostStore(),
            scheduleStore: ScheduleStore(),
            logAnalyzerStore: LogAnalyzerStore(),
            docsRunbookStore: DocsRunbookStore(),
            codePreviewStore: CodePreviewStore(),
            notebookStore: NotebookStore(),
            readingListStore: ReadingListStore(),
            commandLibraryStore: CommandLibraryStore(),
            stickyBoardStore: StickyBoardStore()))
        _ = canvas.view
        return canvas
    }

    /// `OffScreenProbe.window(...)`, never a hand-rolled `NSWindow` - a
    /// hand-rolled one is not actually off-screen whatever origin it is
    /// given, and these have been caught live on the captain's own display.
    private static func mount(_ canvas: HomeCanvasController, size: NSSize = wide) -> NSWindow {
        let window = OffScreenProbe.window(size: size, styleMask: [.titled, .resizable])
        window.contentView = canvas.view
        window.orderFront(nil)
        canvas.debugRenderNow()
        canvas.view.layoutSubtreeIfNeeded()
        // A second pass: the grid is built from `scroll.contentView.bounds`,
        // which is only real after the first one - the same reason
        // `containerWidthMayHaveChanged` exists.
        canvas.debugRenderNow()
        canvas.view.layoutSubtreeIfNeeded()
        return window
    }

    /// A fleet that is reading, so the hub is not in its first-run state and
    /// the widgets have something to draw.
    private static func seedFleet(_ canvas: HomeCanvasController) {
        canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                  queuedCount: 17, doneCount: 20, projectsCount: 4,
                                                  watcher: WatcherHealth(status: "healthy")),
                          mergedPRs: [], prFetchFailure: nil)
    }

    // MARK: 1 - one card at the top

    private static func checkTheHubHasOneHeaderCard(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            check(canvas.heroCardHiddenForTests,
                  "the hub's hero band should be gone - the reference draws one card there", &ok)
            check(!canvas.attentionCardHiddenForTests,
                  "and the attention card should be the thing that replaced it", &ok)
            check(canvas.attentionCardForTests.debugRefreshButtonVisible,
                  "which means it carries the Refresh the band used to", &ok)
            // The subline is the fleet's freshness, which is the one fact
            // none of the cards below can state.
            check(canvas.attentionCardForTests.debugSubline.lowercased().contains("fleet read"),
                  "the subline should be the fleet's freshness, got "
                      + "\"\(canvas.attentionCardForTests.debugSubline)\"", &ok)

            // The other direction, which is what stops this being a check
            // that a view is simply never shown: a space that is not the hub
            // still heads itself with the band.
            canvas.select(space: .command)
            canvas.view.layoutSubtreeIfNeeded()
            check(!canvas.heroCardHiddenForTests,
                  "a non-hub space still needs the band to name itself", &ok)
            check(canvas.attentionCardHiddenForTests,
                  "and has no day of its own to report", &ok)
        }
    }

    // MARK: 2 - placement

    private static func checkTheFiveWidgetsArePlaced(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            check(canvas.usesDashboardLayoutForTests,
                  "the hub at \(Int(wide.width))pt should use the hand-placed dashboard", &ok)

            let rows = canvas.gridRowsForTests
            guard rows.count == 2 else {
                fail("the dashboard is two rows, got \(rows.count)", &ok)
                return
            }
            // Row 1 is a card beside a *column* of two, which is what makes
            // the tall Claude card and the two stacked beside it end on one
            // line. Asserted by shape, because that structure is the layout.
            let firstRow = rows[0].arrangedSubviews
            check(firstRow.count == 2, "row 1 holds two members, got \(firstRow.count)", &ok)
            check(firstRow.first is HelmModuleCard,
                  "row 1 leads with a card, got \(type(of: firstRow.first))", &ok)
            let stacked = firstRow.last as? NSStackView
            check(stacked?.arrangedSubviews.count == 2,
                  "row 1's trailing member is a column of two cards, got "
                      + "\(stacked?.arrangedSubviews.count.description ?? "not a stack")", &ok)

            let secondRow = rows[1].arrangedSubviews
            check(secondRow.count == 2 && secondRow.allSatisfy { $0 is HelmModuleCard },
                  "row 2 is two plain cards, got \(secondRow.map { type(of: $0) })", &ok)

            // Five cards, once - not four with one dropped, and not six.
            check(canvas.moduleCardsForTests.count == 5,
                  "the hub draws exactly five widgets, got \(canvas.moduleCardsForTests.count)", &ok)
        }
    }

    // MARK: 3 - the ratio, as resolved

    private static func checkTheRowIsSevenToFive(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            guard let row = canvas.gridRowsForTests.first,
                  row.arrangedSubviews.count == 2 else {
                fail("no two-member first row to measure", &ok)
                return
            }
            let wideWidth = row.arrangedSubviews[0].frame.width
            let narrowWidth = row.arrangedSubviews[1].frame.width
            // The fixture's own discriminating power: both must have really
            // laid out, or the ratio below is 0/0.
            guard wideWidth > 1, narrowWidth > 1 else {
                fail("row 1 never laid out (\(wideWidth) x \(narrowWidth)) - "
                        + "the ratio check would be vacuous", &ok)
                return
            }
            let expectedWide = HelmResponsiveGrid.proportionalWidth(
                containerWidth: wideWidth + narrowWidth + HomeCanvasController.gridSpacing,
                span: 7, spacing: HomeCanvasController.gridSpacing)
            // One device pixel of tolerance: AGENTS.md records that a CI
            // runner is 1x and a dev Mac 2x, so an ideal edge on a half point
            // rounds by up to `1 / backingScaleFactor`.
            let tolerance = 1.0 / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 1)
            check(abs(wideWidth - expectedWide) <= tolerance,
                  "the leading card should be 7 of 12 tracks (\(expectedWide)), got \(wideWidth)", &ok)
            check(wideWidth > narrowWidth,
                  "and wider than the column beside it, got \(wideWidth) vs \(narrowWidth)", &ok)
        }
    }

    // MARK: 4 - the narrow degrade

    private static func checkItDegradesWhenNarrow(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas, size: NSSize(width: 560, height: 900))
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            check(!canvas.usesDashboardLayoutForTests,
                  "at 560pt a 5-track card is under the module floor, so the hub must "
                      + "hand back to the wrapping grid", &ok)
            // And nothing is lost by doing so - the cards are all still there.
            check(canvas.moduleCardsForTests.count == 5,
                  "the degrade draws the same five widgets, got "
                      + "\(canvas.moduleCardsForTests.count)", &ok)
        }
    }

    // MARK: 5 - the two restyled bodies

    private static func checkTheFleetTilesAndMergeFooter(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }

            // Thirty-three open PRs, so the footer has something to say -
            // the card shows at most `maxPeekRows` of them.
            let prs = (1...33).map { index in
                MergedPR(source: "forge", taskID: nil, repo: "grand-line",
                         url: "https://example.invalid/\(index)", number: index,
                         title: "pull request \(index)",
                         checks: index == 2 ? "none" : "green", forge: "github")
            }
            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                      queuedCount: 17, doneCount: 20,
                                                      projectsCount: 4,
                                                      watcher: WatcherHealth(status: "healthy")),
                              mergedPRs: prs, prFetchFailure: nil)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            let tiles = canvas.moduleCardsForTests.flatMap { $0.debugTiles }
            check(tiles.count == 3,
                  "the Fleet card draws three tiles, got \(tiles.count)", &ok)
            // The numbers are the snapshot's own, so a card that drew three
            // tiles of zeroes fails here rather than looking right.
            check(tiles.map(\.value) == ["0", "20", "17"],
                  "the tiles carry the snapshot's own counts, got \(tiles.map(\.value))", &ok)
            check(tiles.map(\.caption) == ["Working", "Done today", "Queued"],
                  "under the reference's own captions, got \(tiles.map(\.caption))", &ok)

            let footers = canvas.moduleCardsForTests.compactMap { $0.debugFooter }
            guard footers.count == 1 else {
                fail("exactly one card carries a footer, got \(footers.count)", &ok)
                return
            }
            check(footers[0].caption == "Showing \(HelmModuleCard.maxPeekRows) of 33",
                  "the footer states the truncation, got \"\(footers[0].caption)\"", &ok)
            check(footers[0].action == "View all 33 open",
                  "and offers the whole queue, got \"\(footers[0].action)\"", &ok)
        }
    }

    // MARK: 6 - theming

    private static func checkBothThemesPaint(_ ok: inout Bool) {
        // AGENTS.md: a probe that changes the theme saves and restores it.
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }

        var surfaces: [String: NSColor] = [:]
        for id in ["daylight", "dusk"] {
            guard let theme = HelmTheme.theme(id: id) else {
                fail("theme \(id) should exist", &ok)
                continue
            }
            ThemeManager.shared.setTheme(theme)
            withScratchShift { store in
                let canvas = makeCanvas(store)
                let window = mount(canvas)
                defer { window.orderOut(nil) }
                seedFleet(canvas)
                canvas.debugApplyTheme(theme)
                canvas.debugRenderNow()
                canvas.view.layoutSubtreeIfNeeded()

                guard let card = canvas.moduleCardsForTests.first,
                      let fill = card.debugCardSurfaceColor else {
                    fail("\(id): a module card should report a painted surface", &ok)
                    return
                }
                surfaces[id] = fill
                check(canvas.gridRowsForTests.count == 2,
                      "\(id): the dashboard should still be two rows", &ok)
            }
        }
        // The discriminating half: the two palettes must actually differ, or
        // "both themes paint" is a check that cannot fail.
        if let light = surfaces["daylight"], let dark = surfaces["dusk"] {
            let a = HelmContrast.components(light)
            let b = HelmContrast.components(dark)
            let delta = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
            check(delta > 0.2,
                  "Daylight and Dusk should paint visibly different card surfaces, "
                      + "got a channel delta of \(delta)", &ok)
        } else {
            fail("both themes should have reported a card surface", &ok)
        }
    }
}
#endif
