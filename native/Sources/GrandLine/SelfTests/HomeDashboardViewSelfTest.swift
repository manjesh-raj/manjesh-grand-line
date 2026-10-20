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
//   2. **The five widgets are placed, not packed.** Since
//      `fm/grandline-home-fit-implement` the hub is one row of three columns:
//      the attention card, then Claude over Fleet over Health, then the
//      Morning briefing over the Merge queue. Before that it was two 7:5
//      rows, and before *that* the wrapping grid packed the same five cards
//      2+2+1 / 1+1 at the captain's window size.
//   3. **The columns really are equal thirds and really do fill the page.**
//      Read off the resolved frames, so a 499 width constraint that AppKit
//      declined to satisfy fails here rather than looking right in the
//      arithmetic suite.
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
//   7. **The card shadow is really painted (UI-5).** Sampled in pixels from a
//      real render, below a module card against the bare page ground: the
//      squared-alpha defect darkened that strip by 3/255 on Daylight, which
//      is what made every card read as a flat bordered box.

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
        checkTheColumnsAreEqualThirds(&ok)
        checkItDegradesWhenNarrow(&ok)
        checkTheFleetTilesAndMergeFooter(&ok)
        checkBothThemesPaint(&ok)
        checkTheCardShadowIsPainted(&ok)
        checkMergeQueueRowsAreClickable(&ok)
        checkUnknownStatesAreNeverZero(&ok)
        checkALiveResizeRebuildsOnceAtTheEnd(&ok)
        checkASettledRenderReusesItsProbes(&ok)
        checkLiveResizeFramesShareProbes(&ok)
        checkAShelfLiveResizeRebuildsOnlyForNewColumns(&ok)
        checkAResizeRebuildDoesNotReapplyTheTheme(&ok)

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
    private static let wide = NSSize(width: 1512, height: 945)

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
            guard rows.count == 1 else {
                fail("the hub is one row of three columns, got \(rows.count) rows", &ok)
                return
            }
            // Asserted by shape, because that structure is the layout.
            let columns = rows[0].arrangedSubviews
            check(columns.count == 3, "the row holds three columns, got \(columns.count)", &ok)
            check(columns.first === canvas.attentionCardForTests,
                  "column 1 is the attention card itself, got \(type(of: columns.first))", &ok)
            func titles(_ view: NSView?) -> [String] {
                ((view as? NSStackView)?.arrangedSubviews ?? []).compactMap {
                    ($0 as? HelmModuleCard)?.anatomyForTests.title
                }
            }
            if columns.count == 3 {
                check(titles(columns[1]) == ["Claude", "Fleet", "Health"],
                      "column 2 is Claude over Fleet over Health, got \(titles(columns[1]))", &ok)
                check(titles(columns[2]) == ["Morning briefing", "Merge queue"],
                      "column 3 is the briefing over the Merge queue, got \(titles(columns[2]))", &ok)
            }

            // Five cards, once - not four with one dropped, and not six.
            check(canvas.moduleCardsForTests.count == 5,
                  "the hub draws exactly five widgets, got \(canvas.moduleCardsForTests.count)", &ok)
        }
    }

    // MARK: 3 - equal thirds, as resolved

    private static func checkTheColumnsAreEqualThirds(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            guard let row = canvas.gridRowsForTests.first, row.arrangedSubviews.count == 3 else {
                fail("no three-column row to measure", &ok)
                return
            }
            let widths = row.arrangedSubviews.map(\.frame.width)
            // The fixture's own discriminating power: every column must have
            // really laid out, or the comparison below is between zeroes.
            guard widths.allSatisfy({ $0 > 1 }) else {
                fail("the columns never laid out (\(widths)) - the check would be vacuous", &ok)
                return
            }
            let total = widths.reduce(0, +) + HomeCanvasController.gridSpacing * 2
            let expected = HelmResponsiveGrid.proportionalWidth(containerWidth: total, span: 4,
                                                                spacing: HomeCanvasController.gridSpacing)
            // One device pixel of tolerance: AGENTS.md records that a CI
            // runner is 1x and a dev Mac 2x, so an ideal edge on a half point
            // rounds by up to `1 / backingScaleFactor`.
            let tolerance = 1.0 / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 1)
            for (index, width) in widths.enumerated() {
                check(abs(width - expected) <= tolerance,
                      "column \(index + 1) should be 4 of 12 tracks (\(expected)), got \(width)", &ok)
            }
            // And the three columns end on one line - the page's whole height.
            let heights = row.arrangedSubviews.map(\.frame.height)
            check((heights.max() ?? 0) - (heights.min() ?? 0) <= tolerance,
                  "the three columns should be one height, got \(heights)", &ok)
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
                  "at 560pt a 4-track column is under the module floor, so the hub must "
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

            // UI-9: one KPI strip, no boxed tiles.
            let strips = canvas.moduleCardsForTests.compactMap { $0.debugKPIStrip }
            guard strips.count == 1, let strip = strips.first else {
                fail("the Fleet card draws exactly one KPI strip, got \(strips.count)", &ok)
                return
            }
            // The numbers are the snapshot's own, so a card that drew three
            // zeroes fails here rather than looking right.
            check(strip.debugValues == ["0", "20", "17"],
                  "the strip carries the snapshot's own counts, got \(strip.debugValues)", &ok)
            check(strip.debugCaptions == ["Working", "Done today", "Queued"],
                  "under the reference's own captions, got \(strip.debugCaptions)", &ok)
            check(!strip.debugHasBorder, "the strip draws no box of its own", &ok)

            let footers = canvas.moduleCardsForTests.compactMap { $0.debugFooter }
            guard footers.count == 1 else {
                fail("exactly one card carries a footer, got \(footers.count)", &ok)
                return
            }
            // The Merge queue shows as many rows as its column holds, and the
            // footer says exactly how many that is.
            let shown = canvas.moduleCardsForTests.first { $0.debugFooter != nil }?.debugPeekRows.count ?? 0
            check(shown >= HomeCanvasController.mergeQueueMinimumRows && shown < 33,
                  "the Merge queue should show between its minimum and all 33 rows, got \(shown)", &ok)
            check(footers[0].caption == "Showing \(shown) of 33",
                  "the footer states the truncation, got \"\(footers[0].caption)\"", &ok)
            // UI-10: one link, which names the queue rather than repeating
            // the card's own click as "View all".
            check(footers[0].action == "All 33 open",
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
                check(canvas.gridRowsForTests.count == 1
                        && canvas.gridRowsForTests.first?.arrangedSubviews.count == 3,
                      "\(id): the hub should still be one row of three columns", &ok)
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
    // MARK: 7 - the card shadow is painted, measured in pixels (UI-5)

    /// The UI/UX revamp's H-01, as a pixel check rather than a reading of the
    /// code. `HelmModuleCard` used to hand `CALayer` a shadow colour that
    /// already carried the level's 0.10 alpha *and* set `shadowOpacity` to
    /// 0.10 again, so the compositor painted 0.01. Measured on the tour
    /// render: 3/255 of darkening under a Home card on Daylight and 0 on Dusk.
    ///
    /// The sample is the darkest pixel in the 2-10pt strip under the card's
    /// bottom edge, against the page ground at the same height in the
    /// page's right gutter, where no card's blur reaches. Both are read from
    /// the same rep in its own colour space (AGENTS.md's probe rule), and the
    /// rep is in pixels, so every coordinate is scaled by its backing factor.
    ///
    /// The floor is 6/255 on Daylight: twice what the defect painted, and
    /// well under what one application of the alpha paints (about 10-14).
    private static func checkTheCardShadowIsPainted(_ ok: inout Bool) {
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        guard let theme = HelmTheme.theme(id: "daylight") else {
            fail("theme daylight should exist", &ok)
            return
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

            let root = canvas.view
            guard let card = canvas.moduleCardsForTests.first,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                fail("the shadow probe needs a module card and a rep to render into", &ok)
                return
            }
            root.cacheDisplay(in: root.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, root.bounds.width)
            let frame = card.convert(card.bounds, to: root)

            // The alpha is applied once, as the compositor reads it.
            if let layer = card.layer {
                let effective = HelmCard.debugEffectiveShadowAlpha(of: layer)
                check(abs(effective - 0.10) < 0.005,
                      "a resting module card's shadow should composite at alpha 0.10, got \(effective)", &ok)
            }

            func luma(_ x: CGFloat, _ yFromBottom: CGFloat) -> CGFloat? {
                let px = Int((x * scale).rounded(.down))
                let py = Int(((root.bounds.height - yFromBottom) * scale).rounded(.down))
                guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                      let c = rep.colorAt(x: px, y: py) else { return nil }
                return (c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255
            }
            var darkest: CGFloat = .greatestFiniteMagnitude
            var groundAtDarkest: CGFloat = 0
            for offset in stride(from: CGFloat(2), through: 10, by: 1) {
                let y = frame.minY - offset
                guard let under = luma(frame.midX, y),
                      let ground = luma(root.bounds.width - 3, y) else { continue }
                if under < darkest {
                    darkest = under
                    groundAtDarkest = ground
                }
            }
            guard darkest < .greatestFiniteMagnitude else {
                fail("the strip under the card was outside the render", &ok)
                return
            }
            let darkening = groundAtDarkest - darkest
            check(darkening >= 6,
                  "the page under a Daylight module card should darken by at least 6/255 "
                      + "from its resting shadow, got \(darkening)", &ok)
        }
    }

    // MARK: 8 - merge queue rows are clickable (UI-10)

    /// UI-10: the merge queue's peek rows were inert text, and the card's
    /// "View all" repeated the card's own click. Each row is now a real hover
    /// target with a chevron on aim, and the card's own click steps aside for
    /// it - otherwise a click on a row would also open the queue (gotcha
    /// (20)'s shape). The row's own open is not fired here: it opens a URL.
    private static func checkMergeQueueRowsAreClickable(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            let prs = (1...5).map { (index: Int) -> MergedPR in
                MergedPR(source: "forge", taskID: nil, repo: "grand-line",
                         url: "https://example.invalid/\(index)", number: index,
                         title: "pull request \(index)", checks: "green", forge: "github")
            }
            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                      queuedCount: 0, doneCount: 0, projectsCount: 1,
                                                      watcher: WatcherHealth(status: "healthy")),
                              mergedPRs: prs, prFetchFailure: nil)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            guard let card = canvas.moduleCardsForTests.first(where: { !$0.debugPeekRows.isEmpty }) else {
                fail("the merge queue card should draw clickable peek rows", &ok)
                return
            }
            // Five PRs all fit the captain's window, so all five are rows.
            check(card.debugPeekRows.count == 5,
                  "every shown PR should be a clickable row, got \(card.debugPeekRows.count)", &ok)
            check(card.debugPeekRows.allSatisfy(\.isActivatable), "each row should be a button to VoiceOver", &ok)
            check(card.debugPeekChevronAlphas.allSatisfy { $0 == 0 }, "the chevron is hidden at rest", &ok)
            card.debugHoverPeekRow(0, true)
            HelmMotion.reducedOverrideForTests = true
            card.debugHoverPeekRow(0, true)
            HelmMotion.reducedOverrideForTests = nil
            check((card.debugPeekChevronAlphas.first ?? 0) > 0.99, "the chevron appears on aim", &ok)
            let frame = card.debugPeekRowFrameInCard(1)
            check(card.debugCardClickWouldBeDeclined(at: NSPoint(x: frame.midX, y: frame.midY)),
                  "a click on a row must not also open the card", &ok)
            // A point in the header band, above the first row whichever way
            // the card's coordinates run - the card now ends at its last row,
            // so its bottom edge is no longer bare surface.
            let firstRow = card.debugPeekRowFrameInCard(0)
            let headerY = card.isFlipped ? firstRow.minY / 2 : (firstRow.maxY + card.bounds.height) / 2
            check(!card.debugCardClickWouldBeDeclined(at: NSPoint(x: 40, y: headerY)),
                  "a click on the card's own surface still opens it, or the check above cannot fail", &ok)
        }
    }

    // MARK: 9 - unknown is never zero, and one loading idiom (UI-9, UI-11, UI-12)

    /// The revamp's GL-14 pass over Home, read off the painted cards:
    ///
    ///   - nothing read yet: the Fleet and Merge queue cards show the
    ///     skeleton, the one loading idiom, not a sentence each;
    ///   - a missing firstmate home: Fleet draws dashes under a "Not read"
    ///     pill, never 0/0/0 under "All clear";
    ///   - a failed PR scan after a good one: the last list stays, the pill
    ///     says "Can't reach" and the subtitle says how old the list is;
    ///   - nothing reported to Health: the title is "Not read", not "Healthy".
    private static func checkUnknownStatesAreNeverZero(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            func card(_ title: String) -> HelmModuleCard? {
                canvas.moduleCardsForTests.first { $0.anatomyForTests.title == title }
            }

            check(card("Fleet")?.debugBodyIsSkeleton == true, "an unread fleet should show the skeleton", &ok)
            check(card("Merge queue")?.debugBodyIsSkeleton == true,
                  "an unread merge queue should show the skeleton", &ok)

            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: false, captain: "Manjesh", tasks: [],
                                                      queuedCount: 0, doneCount: 0, projectsCount: 0,
                                                      watcher: WatcherHealth(status: "off")),
                              mergedPRs: nil, prFetchFailure: "no firstmate home")
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            if let fleet = card("Fleet"), let strip = fleet.debugKPIStrip {
                check(strip.debugValues.allSatisfy { $0 == HelmReading<String>.dash },
                      "a fleet with no home should draw dashes, got \(strip.debugValues)", &ok)
                check(!strip.debugValues.contains("0"), "and never a zero", &ok)
                check(fleet.anatomyForTests.chipText == "Not read" && fleet.debugChipIsPill,
                      "under a 'Not read' pill, got \(fleet.anatomyForTests.chipText ?? "nil")", &ok)
            } else {
                fail("the Fleet card should still draw its strip when the home is missing", &ok)
            }

            let prs = (1...4).map { (index: Int) -> MergedPR in
                MergedPR(source: "forge", taskID: nil, repo: "grand-line",
                         url: "https://example.invalid/\(index)", number: index,
                         title: "pull request \(index)", checks: "green", forge: "github")
            }
            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                      queuedCount: 1, doneCount: 2, projectsCount: 1,
                                                      watcher: WatcherHealth(status: "healthy")),
                              mergedPRs: prs, prFetchFailure: nil)
            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                      queuedCount: 1, doneCount: 2, projectsCount: 1,
                                                      watcher: WatcherHealth(status: "healthy")),
                              mergedPRs: nil, prFetchFailure: "GitHub timed out")
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            if let queue = card("Merge queue") {
                let anatomy = queue.anatomyForTests
                check(anatomy.peekRowCount == 4,
                      "a failed scan should keep the last list (4 rows), got \(anatomy.peekRowCount) rows", &ok)
                check(anatomy.chipText == "Can't reach", "and say it cannot reach GitHub", &ok)
                check(anatomy.subtitle.contains("as of"), "and how old the list is, got \"\(anatomy.subtitle)\"", &ok)
            } else {
                fail("the Merge queue card should be on the hub", &ok)
            }

            let empty = HomeCanvasController.healthRingSummary([])
            check(empty.title == "Not read" && empty.total == 0,
                  "nothing reported is 'Not read', never 'Healthy', got \(empty.title)", &ok)
        }
    }

    // MARK: PERF-03 - a live resize moves constants, and rebuilds once

    /// What AppKit does around a drag, in the order it does it: the start
    /// notification, a resize per frame, the end notification.
    private static func liveResize(_ window: NSWindow, widths: [CGFloat], end: Bool = true,
                                   perFrame: ((CGFloat) -> Void)? = nil) {
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        for width in widths {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            perFrame?(width)
        }
        if end {
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// The review's PERF-03: every frame of a drag used to tear the grid
    /// down and rebuild it. Inside a live resize the cards must survive and
    /// follow the width; the end of the drag rebuilds exactly once.
    ///
    /// Injection: make `containerWidthMayHaveChanged` skip the
    /// `resizeGridInPlace` branch and this counts one rebuild per frame.
    private static func checkALiveResizeRebuildsOnceAtTheEnd(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            guard canvas.usesDashboardLayoutForTests else {
                fail("PERF-03: the fixture needs the hub's dashboard at \(Int(wide.width))pt", &ok)
                return
            }
            let cardsBefore = canvas.moduleCardsForTests.map(ObjectIdentifier.init)
            let rebuildsBefore = canvas.debugGridRebuilds
            let widths: [CGFloat] = (1...10).map { wide.width - CGFloat($0) * 12 }
            var stale: [String] = []
            liveResize(window, widths: widths, end: false) { width in
                // The columns follow the window during the drag - the hub's
                // first column is the attention card, the last is the briefing
                // column, and together they reach the page's trailing edge.
                let rows = canvas.gridRowsForTests
                guard let row = rows.first, let last = row.arrangedSubviews.last else { return }
                let trailing = last.convert(last.bounds, to: canvas.view).maxX
                let page = row.convert(row.bounds, to: canvas.view).maxX
                if abs(trailing - page) > 1.0 / window.backingScaleFactor + 0.01 {
                    stale.append("at \(Int(width))pt the last column ends at \(trailing), the row at \(page)")
                }
            }
            check(canvas.debugGridRebuilds == rebuildsBefore,
                  "PERF-03: ten live-resize frames rebuilt the grid \(canvas.debugGridRebuilds - rebuildsBefore) time(s), "
                      + "expected none until the drag ends", &ok)
            check(canvas.moduleCardsForTests.map(ObjectIdentifier.init) == cardsBefore,
                  "PERF-03: the cards were replaced during the drag", &ok)
            check(stale.isEmpty, "PERF-03: the columns did not follow the drag: \(stale.prefix(3))", &ok)

            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            window.contentView?.layoutSubtreeIfNeeded()
            check(canvas.debugGridRebuilds == rebuildsBefore + 1,
                  "PERF-03: the end of the drag should rebuild once, rebuilt "
                      + "\(canvas.debugGridRebuilds - rebuildsBefore) time(s)", &ok)
        }
    }

    /// A render whose content did not change re-reads every probe height
    /// from the memo; a changed reading re-measures only what it changed.
    ///
    /// Injection: return the measured height without storing it and the
    /// second render measures every probe again.
    private static func checkASettledRenderReusesItsProbes(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()

            let measuredBefore = canvas.debugProbeMeasurements
            let hitsBefore = canvas.debugProbeMemoHits
            canvas.debugRenderNow()
            check(canvas.debugProbeMeasurements == measuredBefore,
                  "PERF-03: an unchanged render measured \(canvas.debugProbeMeasurements - measuredBefore) "
                      + "probe card(s), expected none", &ok)
            check(canvas.debugProbeMemoHits > hitsBefore,
                  "PERF-03: an unchanged render did not read the memo at all - the check would be vacuous", &ok)

            // A different fleet reading changes the Fleet card and nothing
            // in column 3, so some probes are re-measured and some are not.
            let before = canvas.debugProbeMeasurements
            let hitsBeforeChange = canvas.debugProbeMemoHits
            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                      queuedCount: 3, doneCount: 41, projectsCount: 9,
                                                      watcher: WatcherHealth(status: "healthy")),
                              mergedPRs: [], prFetchFailure: nil)
            canvas.debugRenderNow()
            check(canvas.debugProbeMeasurements > before,
                  "PERF-03: a changed fleet reading re-measured nothing - a stale height would be reused", &ok)
            check(canvas.debugProbeMemoHits > hitsBeforeChange,
                  "PERF-03: a changed fleet reading re-measured every probe, including unchanged cards", &ok)
        }
    }

    /// Within one 8pt bucket, the frames of a drag share their measurements.
    private static func checkLiveResizeFramesShareProbes(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            // Two frames 2pt apart, inside one bucket (1440 and 1442 both
            // floor to 1440 once the page's own insets are taken off, which
            // keeps them together whichever side of the bucket they land).
            let bucket = HomeCanvasController.liveResizeProbeBucket
            let base = (wide.width / bucket).rounded(.down) * bucket - 40
            var measuredPerFrame: [Int] = []
            var last = canvas.debugProbeMeasurements
            liveResize(window, widths: [base, base + 1, base + 2]) { _ in
                measuredPerFrame.append(canvas.debugProbeMeasurements - last)
                last = canvas.debugProbeMeasurements
            }
            check(measuredPerFrame.count == 3 && measuredPerFrame.dropFirst().contains(0),
                  "PERF-03: frames 1pt apart inside a drag should share probe heights, measured \(measuredPerFrame)", &ok)
        }
    }

    /// A shelf (any space but the hub) moves its card widths during a drag,
    /// and rebuilds only when the column count changes - that is a different
    /// grid, not a resized one.
    private static func checkAShelfLiveResizeRebuildsOnlyForNewColumns(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            canvas.select(space: .stores)
            canvas.view.layoutSubtreeIfNeeded()
            let columnsAt: (CGFloat) -> Int = { width in
                (canvas.gridRowsForTests.first?.arrangedSubviews.count) ?? 0
            }
            let startColumns = columnsAt(wide.width)
            let rebuildsBefore = canvas.debugGridRebuilds
            // Small steps first: same column count, so no rebuild.
            liveResize(window, widths: [wide.width - 4, wide.width - 8], end: false)
            check(canvas.debugGridRebuilds == rebuildsBefore,
                  "PERF-03: a shelf drag that kept its \(startColumns) columns rebuilt "
                      + "\(canvas.debugGridRebuilds - rebuildsBefore) time(s)", &ok)
            // Then far enough to lose a column, which must rebuild.
            liveResize(window, widths: [1000], end: false)
            check(canvas.debugGridRebuilds > rebuildsBefore,
                  "PERF-03: a shelf drag that changed the column count did not rebuild", &ok)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        }
    }

    /// The resize path used to follow its rebuild with a whole-page
    /// `applyTheme`, which rebuilt the attention card a second time. Every
    /// card a rebuild builds themes itself, so a resize applies no theme.
    private static func checkAResizeRebuildDoesNotReapplyTheTheme(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            let themesBefore = canvas.debugApplyThemeCount
            let rebuildsBefore = canvas.debugGridRebuilds
            var frame = window.frame
            frame.size.width -= 60
            window.setFrame(frame, display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            check(canvas.debugGridRebuilds > rebuildsBefore,
                  "PERF-03: the fixture's resize did not rebuild the grid - the check would be vacuous", &ok)
            check(canvas.debugApplyThemeCount == themesBefore,
                  "PERF-03: a resize applied the theme \(canvas.debugApplyThemeCount - themesBefore) time(s), expected none", &ok)
        }
    }
}

#endif
