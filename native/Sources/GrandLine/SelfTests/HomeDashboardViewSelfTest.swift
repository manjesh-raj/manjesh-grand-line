// Grand Line - native macOS app.
//
// The render half of Home's card grid, as a real `NSWindow` builds it.
//
// Run with `FM_RUN_HOME_DASHBOARD_VIEW_TESTS=1 .build/debug/GrandLine`.
//
// **The name is older than the page it measures.** This suite was written
// for Overview's hand-placed dashboard (`fm/grandline-home-page-visual-
// overhaul`), which P-03 of the 2026-11-25 full review removed with the
// floating bar. The dashboard's own cases went with it: the hero band and
// attention card at the top, the three-column placement, the equal thirds,
// the narrow degrade, the probe-height memo and the shelf's live resize.
// What is left is what Home's arranged cards still draw, and the suite kept
// its name so its variable, its shard weight and its history still match.
//
// **Why this suite is window-backed.** Every case below reads a resolved
// `NSView.frame` or a real view tree after a real layout pass. That is the
// AGENTS.md test - what the suite *asserts*, not what it imports - so it is
// listed in `NEEDS_SESSION` and runs in CI's windowed lane.
//
// What it covers:
//
//   1. **R5-UI-08: the briefing is left off while it has nothing to say.**
//      Neither a card nor the hero, and the hero is back once it is on.
//   2. **The Merge queue's footer carries real numbers.** "Showing 3 of 33"
//      is the reference's own furniture, the kind of thing that can be
//      configured and never painted.
//   3. **Both themes paint.** Daylight and Dusk, asserting the card surface
//      really changed between them - a theming check that cannot fail is
//      worse than none.
//   4. **The card shadow is really painted (UI-5).** Sampled in pixels from a
//      real render, below a module card against the bare page ground: the
//      squared-alpha defect darkened that strip by 3/255 on Daylight, which
//      is what made every card read as a flat bordered box.
//   5. **The Merge queue's rows are links**, and an untitled PR is named.
//   6. **Unknown is never zero** on the Fleet and Merge queue cards.
//   7. **PERF-03: a live resize moves constants and rebuilds once.**

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum HomeDashboardViewSelfTest {

    @discardableResult
    static func run() -> Bool {
        // R5-UI-08: Home leaves the Morning briefing off while it is off and
        // has nothing on record. The checks here measure Home with the
        // briefing as its hero, so the briefing is on, in this process's own
        // suite domain, and put back after.
        let briefingWasOn = AppSettings.shared.morningBriefingEnabled
        AppSettings.shared.morningBriefingEnabled = true
        defer { AppSettings.shared.morningBriefingEnabled = briefingWasOn }
        var ok = true
        checkTheBriefingIsLeftOffWhileOff(&ok)
        checkTheMergeFooter(&ok)
        checkBothThemesPaint(&ok)
        checkTheCardShadowIsPainted(&ok)
        checkMergeQueueRowsAreClickable(&ok)
        checkAnUntitledPRIsNamed(&ok)
        checkUnknownStatesAreNeverZero(&ok)
        checkALiveResizeRebuildsOnceAtTheEnd(&ok)
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

    /// One seeded task, so Home is not over entirely empty stores. A bare
    /// canvas shows `HomeCardLayout.standard`: the briefing as the hero, then
    /// Fleet, Health, Claude and the Merge queue.
    private static func makeCanvas(_ shiftStore: ShiftStore) -> HomeCanvasController {
        var seeded = ShiftTask.fresh()
        seeded.title = "a task, so Home is not over empty stores"
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

    /// A fleet that is reading, so the cards have something to draw.
    private static func seedFleet(_ canvas: HomeCanvasController) {
        canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                  queuedCount: 17, doneCount: 20, projectsCount: 4,
                                                  watcher: WatcherHealth(status: "healthy")),
                          mergedPRs: [], prFetchFailure: nil)
    }

    private static func card(_ title: String, on canvas: HomeCanvasController) -> HelmModuleCard? {
        canvas.moduleCardsForTests.first { $0.anatomyForTests.title == title }
    }

    // MARK: 1 - the briefing while it is off

    /// R5-UI-08: with the briefing off and nothing on record, Home draws no
    /// briefing at all - neither a card that only says it is off, nor the
    /// hero - and the greeting heads the page on its own.
    private static func checkTheBriefingIsLeftOffWhileOff(_ ok: inout Bool) {
        let record = AppSettings.shared.morningBriefingRecord
        AppSettings.shared.morningBriefingEnabled = false
        AppSettings.shared.morningBriefingRecord = nil
        defer {
            AppSettings.shared.morningBriefingEnabled = true
            AppSettings.shared.morningBriefingRecord = record
        }
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            seedFleet(canvas)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            let titles = canvas.moduleCardsForTests.compactMap { $0.anatomyForTests.title }
            check(!titles.contains("Morning briefing") && titles.count == 4,
                  "R5-UI-08: with the briefing off Home draws \(titles), want the four others and no briefing", &ok)
            check(canvas.debugBriefingHero == nil && canvas.debugGreetingOnGround,
                  "R5-UI-08: with the briefing off Home still draws the briefing hero", &ok)

            // The other direction, so the check above is not one a hero that
            // never shows would pass.
            AppSettings.shared.morningBriefingEnabled = true
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            check(canvas.debugBriefingHero != nil,
                  "R5-UI-08: with the briefing on Home should draw it as the hero", &ok)
        }
    }

    // MARK: 2 - the Merge queue's footer

    private static func checkTheMergeFooter(_ ok: inout Bool) {
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

            let footers = canvas.moduleCardsForTests.compactMap { $0.debugFooter }
            guard footers.count == 1 else {
                fail("exactly one card carries a footer, got \(footers.count)", &ok)
                return
            }
            // R5-UI-03: the Merge queue shows `maxPeekRows` of them, and the
            // footer says exactly how many that is.
            let shown = canvas.moduleCardsForTests.first { $0.debugFooter != nil }?.debugPeekRows.count ?? 0
            check(shown == HelmModuleCard.maxPeekRows,
                  "the Merge queue should show \(HelmModuleCard.maxPeekRows) of 33 rows, got \(shown)", &ok)
            check(footers[0].caption == "Showing \(shown) of 33",
                  "the footer states the truncation, got \"\(footers[0].caption)\"", &ok)
            // UI-10: one link, which names the queue rather than repeating
            // the card's own click as "View all".
            check(footers[0].action == "All 33 open",
                  "and offers the whole queue, got \"\(footers[0].action)\"", &ok)
        }
    }

    // MARK: 3 - theming

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

                // The Merge queue: a plain card, which paints the theme's own
                // surface rather than a hero colour the captain chose.
                guard let card = card("Merge queue", on: canvas),
                      let fill = card.debugCardSurfaceColor else {
                    fail("\(id): the Merge queue card should report a painted surface", &ok)
                    return
                }
                surfaces[id] = fill
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
    // MARK: 4 - the card shadow is painted, measured in pixels (UI-5)

    /// The UI/UX revamp's H-01, as a pixel check rather than a reading of the
    /// code. `HelmModuleCard` used to hand `CALayer` a shadow colour that
    /// already carried the level's 0.10 alpha *and* set `shadowOpacity` to
    /// 0.10 again, so the compositor painted 0.01. Measured on the tour
    /// render: 3/255 of darkening under a Home card on Daylight and 0 on Dusk.
    ///
    /// The sample is the darkest pixel in the 2-10pt strip under the bottom
    /// edge of the lowest plain card, against the page ground at the same
    /// height in the page's right gutter, where no card's blur reaches. Both are read from
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
            // The lowest plain card, so the strip under it is page ground and
            // not the next row's card. A hero card paints its own colour.
            let plain = canvas.moduleCardsForTests.filter { $0.debugHeroSurface == nil }
            guard let card = plain.min(by: { $0.convert($0.bounds, to: root).minY < $1.convert($1.bounds, to: root).minY }),
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

    // MARK: 5 - merge queue rows are clickable (UI-10)

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
            // R5-UI-03: Home shows three of five PRs, with a footer saying
            // so. Uncapped, the floating bar's Home listed 20 of 22.
            check(card.debugPeekRows.count == HelmModuleCard.maxPeekRows,
                  "Home's Merge queue should show \(HelmModuleCard.maxPeekRows) of 5 PRs, "
                  + "got \(card.debugPeekRows.count)", &ok)
            check(card.debugFooter?.caption == "Showing \(HelmModuleCard.maxPeekRows) of 5",
                  "and say how many it is not showing, got \(card.debugFooter?.caption ?? "no footer")", &ok)
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

    /// A task's PR that the forge scan never returned has no title. Review
    /// names it by its number, and the Merge queue drew a blank line for it
    /// instead, which is what a captain saw on Home.
    private static func checkAnUntitledPRIsNamed(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            let prs = [
                MergedPR(source: "forge", taskID: nil, repo: "grand-line", url: "https://example.invalid/1",
                         number: 1, title: "pull request 1", checks: "green", forge: "github"),
                MergedPR(source: "work", taskID: "t42", repo: "grand-line", url: "https://example.invalid/42",
                         number: 42, title: "", checks: "none", forge: nil),
            ]
            canvas.applyFleet(snapshot: FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                                      queuedCount: 0, doneCount: 0, projectsCount: 1,
                                                      watcher: WatcherHealth(status: "healthy")),
                              mergedPRs: prs, prFetchFailure: nil)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            guard let card = canvas.moduleCardsForTests.first(where: { !$0.debugPeekRows.isEmpty }) else {
                fail("the merge queue card drew no rows, so the untitled PR check is vacuous", &ok)
                return
            }
            func labels(in view: NSView) -> [String] {
                ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { labels(in: $0) }
            }
            let rows = card.debugPeekRows.map { labels(in: $0) }
            check(rows.count == 2, "both PRs should be rows, got \(rows.count)", &ok)
            check(rows.contains { $0.contains("PR #42") }, "the untitled PR is not named \"PR #42\": \(rows)", &ok)
        }
    }

    // MARK: 6 - unknown is never zero, and one loading idiom (UI-9, UI-11, UI-12)

    /// The revamp's GL-14 pass over Home, read off the painted cards:
    ///
    ///   - nothing read yet: the Merge queue shows the skeleton, the one
    ///     loading idiom, and the Fleet hero says it is reading;
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
            func card(_ title: String) -> HelmModuleCard? { Self.card(title, on: canvas) }

            check(card("Fleet")?.anatomyForTests.subtitle == "reading",
                  "an unread fleet should say it is reading, got \(card("Fleet")?.anatomyForTests.subtitle ?? "no card")", &ok)
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
                // Its first three rows (R5-UI-03's cap), and the count of
                // all four, which is what says the list was kept.
                check(anatomy.peekRowCount == HelmModuleCard.maxPeekRows && anatomy.subtitle.hasPrefix("4 open"),
                      "a failed scan should keep the last list (4 open, \(HelmModuleCard.maxPeekRows) rows), "
                      + "got \(anatomy.peekRowCount) rows, \"\(anatomy.subtitle)\"", &ok)
                check(anatomy.chipText == "Can't reach", "and say it cannot reach GitHub", &ok)
                check(anatomy.subtitle.contains("as of"), "and how old the list is, got \"\(anatomy.subtitle)\"", &ok)
            } else {
                fail("the Merge queue card should be on Home", &ok)
            }

            let empty = HomeCanvasController.healthRingSummary(ServiceHealthSummary())
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
            guard !canvas.gridRowsForTests.isEmpty else {
                fail("PERF-03: the fixture drew no grid rows at \(Int(wide.width))pt", &ok)
                return
            }
            let cardsBefore = canvas.moduleCardsForTests.map(ObjectIdentifier.init)
            let rebuildsBefore = canvas.debugGridRebuilds
            let widths: [CGFloat] = (1...10).map { wide.width - CGFloat($0) * 12 }
            var stale: [String] = []
            liveResize(window, widths: widths, end: false) { width in
                // The cards follow the window during the drag: the first
                // row's last cell still reaches the row's trailing edge.
                let rows = canvas.gridRowsForTests
                guard let row = rows.first, let last = row.arrangedSubviews.last else { return }
                let trailing = last.convert(last.bounds, to: canvas.view).maxX
                let page = row.convert(row.bounds, to: canvas.view).maxX
                if abs(trailing - page) > 1.0 / window.backingScaleFactor + 0.01 {
                    stale.append("at \(Int(width))pt the last cell ends at \(trailing), the row at \(page)")
                }
            }
            check(canvas.debugGridRebuilds == rebuildsBefore,
                  "PERF-03: ten live-resize frames rebuilt the grid \(canvas.debugGridRebuilds - rebuildsBefore) time(s), "
                      + "expected none until the drag ends", &ok)
            check(canvas.moduleCardsForTests.map(ObjectIdentifier.init) == cardsBefore,
                  "PERF-03: the cards were replaced during the drag", &ok)
            check(stale.isEmpty, "PERF-03: the cards did not follow the drag: \(stale.prefix(3))", &ok)

            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            window.contentView?.layoutSubtreeIfNeeded()
            check(canvas.debugGridRebuilds == rebuildsBefore + 1,
                  "PERF-03: the end of the drag should rebuild once, rebuilt "
                      + "\(canvas.debugGridRebuilds - rebuildsBefore) time(s)", &ok)
        }
    }

    /// The resize path used to follow its rebuild with a whole-page
    /// `applyTheme`. Every card a rebuild builds themes itself, so a resize
    /// applies no theme.
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
