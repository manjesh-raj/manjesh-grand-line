// Grand Line - native macOS app.
//
// The render half of the Home page's Needs Attention card: the **real card on
// the real page**, in a real off-screen window.
//
// Run with `FM_RUN_NEEDS_ATTENTION_VIEW_TESTS=1 .build/debug/GrandLine`.
//
// **Window-backed**, so it lives in `run-all-tests.sh`'s `NEEDS_SESSION` list:
// every case here measures a laid-out frame, drives a real control's
// target/action through `performClick`, or reads a painted string out of a
// mounted view tree. `NeedsAttentionSelfTest` is the pure half and guards CI's
// blocking lane.
//
// What it covers:
//
//   1. **The card paints what the composer decided** - assert what is painted,
//      never what was computed. The wiring from `HomeCanvasController`'s
//      injected `ShiftStore` all the way to a label is what this proves, and a
//      model-level assertion is blind to a signal that never reaches the view.
//   2. **The controls are really wired.** The checkbox and the trailing button
//      are driven with `performClick`, which runs the exact target/action path
//      a captain's click does - AGENTS.md's own lesson about a `debug*` hook
//      that calls the helper the wiring reaches rather than the wiring.
//   3. **It does not cap the window** (gotcha (13)): the card spans the page
//      and ties every row's width to the list, so a real resize is the only
//      thing that can prove no constraint above 500 got in.
//   4. **It is on the hub and nowhere else** - the other Daylight spaces are
//      filters over the module grid and have no day of their own.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum NeedsAttentionViewSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkPaintsTheCaptainsRecords(&ok)
        checkTheActionButtonIsWired(&ok)
        checkTheCheckboxCompletesTheTask(&ok)
        checkAllClearState(&ok)
        checkDoesNotResizeTheWindow(&ok)
        checkOnlyOnTheHub(&ok)
        checkTheRevampRecipe(&ok)
        checkTheSublineTicks(&ok)
        checkTheListScrollsInsideTheCard(&ok)

        if ok {
            print("NeedsAttentionViewSelfTest: all checks passed")
        } else {
            print("NeedsAttentionViewSelfTest: FAILED")
        }
        return ok
    }

    // MARK: Fixtures

    /// One `ShiftStore` per case, pointed at its own scratch directory.
    ///
    /// `main.swift`'s `#if FM_SELFTESTS` block already redirects every `FM_*`
    /// store override process-wide, so a bare store reaches none of the
    /// captain's real data - but every bare store in the process then shares
    /// *one* directory, and these cases each seed the same two records.
    /// Measured: without this, case 4's "an empty day" ran over five
    /// accumulated rows and read "Five things are late", and case 3's
    /// completed task was still present because a second copy of it had been
    /// written. One directory per case is what makes each case's fixture its
    /// own.
    private static func withScratchShift(_ body: (ShiftStore) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-attention-shift-\(UUID().uuidString)",
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

    /// The two records from the captain's screenshots.
    private static func seed(_ store: ShiftStore) {
        var task = ShiftTask.fresh()
        task.title = "Standup Notes"
        task.dueDate = "2026-09-23"
        store.addTask(task)

        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Follow up with Nithin on SRE bot response reviews"
        followUp.followUpAt = "2026-09-18"
        store.addFollowUp(followUp)
    }

    private static func makeCanvas(_ shiftStore: ShiftStore) -> HomeCanvasController {
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
    /// hand-rolled one is not actually off-screen whatever origin it is given,
    /// and these have been caught live on the captain's own display.
    private static func mount(_ canvas: HomeCanvasController,
                              size: NSSize = NSSize(width: 1200, height: 900)) -> NSWindow {
        let window = OffScreenProbe.window(size: size, styleMask: [.titled, .resizable])
        window.contentView = canvas.view
        window.orderFront(nil)
        canvas.debugRenderNow()
        canvas.view.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: 1 - what is painted

    private static func checkPaintsTheCaptainsRecords(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }

            let card = canvas.attentionCardForTests
            check(!canvas.attentionCardHiddenForTests,
                  "the card should be on the hub", &ok)

            let painted = card.debugListText
            check(painted.contains(where: { $0.contains("Standup Notes") }),
                  "the overdue task should be painted, got \(painted)", &ok)
            check(painted.contains(where: { $0.contains("Nithin") }),
                  "the pending follow-up should be painted, got \(painted)", &ok)
            // N1 (`fm/grandline-home-fit-implement`): the kind and the state
            // share the meta line under the title - "Follow-up \u{00B7} Overdue
            // 27 days \u{00B7} since 18 Sep" - and there is no kicker line.
            check(painted.contains(where: { $0.contains("Overdue") && $0.contains("since") }),
                  "and a row should carry the overdue state, got \(painted)", &ok)
            let metas = card.debugAccentRows.map(\.debugMetaText)
            check(metas.contains(where: { $0.hasPrefix("Task \u{00B7} Overdue") })
                    && metas.contains(where: { $0.hasPrefix("Follow-up \u{00B7} Overdue") }),
                  "each row's second line should lead with its kind, then its state, got \(metas)", &ok)
            let kickers = card.debugAccentRows.map(\.debugKickerText)
            check(kickers.allSatisfy(\.isEmpty),
                  "an N1 row has no kicker line, got \(kickers)", &ok)

            check(card.debugEyebrow == "NEEDS ATTENTION \u{00B7} 2",
                  "the eyebrow should count the rows, got \"\(card.debugEyebrow)\"", &ok)
            check(card.debugHeadline == "Two things are late.",
                  "the headline should be the plain sentence, got \"\(card.debugHeadline)\"", &ok)
            // The subline is the **fleet's** freshness now, not the day and
            // time the digest was composed. `fm/grandline-home-page-visual-
            // overhaul` merged the hub's hero band into this card, and that
            // band's line is the one fact none of the cards below it can
            // state - a composed-at line, on a digest re-derived on every
            // render, could only ever say "a moment ago".
            //
            // Nothing has been pushed into this canvas here, so the honest
            // answer is the stated gap rather than a freshness for a reading
            // that never happened (GL-14).
            check(card.debugSubline.lowercased().contains("fleet"),
                  "the subline should speak about the fleet reading, got "
                      + "\"\(card.debugSubline)\"", &ok)

            // The rows really laid out, rather than collapsing to nothing
            // inside a `.leading`-aligned stack.
            let widths = card.debugRows.map(\.frame.width)
            check(widths.allSatisfy { $0 > 300 },
                  "every row should span the card, got \(widths)", &ok)
            check(card.frame.height > 120,
                  "the card should have a real height, got \(card.frame.height)", &ok)
        }
    }

    // MARK: 2 - the trailing action

    private static func checkTheActionButtonIsWired(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }

            var openedTasks: [String] = []
            var openedDestinations: [RailDestination] = []
            canvas.onOpenShiftTask = { openedTasks.append($0) }
            canvas.onOpenDestination = { openedDestinations.append($0) }

            let card = canvas.attentionCardForTests
            guard card.debugRows.count >= 2 else {
                fail("expected two rows to press, got \(card.debugRows.count)", &ok)
                return
            }
            // A real `performClick` on the real button, which is the whole
            // point: a hook that called the handler would stay green with the
            // target/action wiring deleted.
            card.debugPressAction(atRow: 0)
            check(openedTasks == [store.activeTasks.first?.id],
                  "pressing a task's action should open that task, got \(openedTasks)", &ok)

            card.debugPressAction(atRow: 1)
            check(openedDestinations == [.shift],
                  "pressing a follow-up's action should open Tasks, got \(openedDestinations)", &ok)
        }
    }

    // MARK: 3 - the checkbox

    private static func checkTheCheckboxCompletesTheTask(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }

            // Assert the fixture's own discriminating power: the task has to
            // be open before the click, or "it is not in `activeTasks`
            // afterwards" proves nothing.
            check(store.activeTasks.contains(where: { $0.title == "Standup Notes" }),
                  "the task should be open before the click, got \(store.activeTasks.map(\.title))",
                  &ok)

            canvas.attentionCardForTests.debugPressCheckbox(atRow: 0)

            check(!store.activeTasks.contains(where: { $0.title == "Standup Notes" }),
                  "ticking the checkbox should complete the task, got \(store.activeTasks.map(\.title))",
                  &ok)
            // And the card re-derives rather than keeping a row for something
            // that is no longer open.
            let painted = canvas.attentionCardForTests.debugListText
            check(!painted.contains(where: { $0.contains("Standup Notes") }),
                  "and the row should leave the list, got \(painted)", &ok)
        }
    }

    // MARK: 4 - the all-clear state

    private static func checkAllClearState(_ ok: inout Bool) {
        withScratchShift { store in
            // A task that is not due: the hub is then not in its first-run
            // state, and nothing needs the captain.
            var task = ShiftTask.fresh()
            task.title = "Something with no due date"
            store.addTask(task)

            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }

            let card = canvas.attentionCardForTests
            check(card.debugEyebrow == "ALL CLEAR",
                  "an empty day reads as all clear, got \"\(card.debugEyebrow)\"", &ok)
            // The all-clear sentence is the **host's** now, passed in as
            // `allClearHeadline`: this card took over the hub's hero, and
            // the app must have one all-clear sentence rather than a hero
            // saying "Nothing needs you right now" over a card saying
            // "Nothing is due". With no fleet reading pushed in, the hub
            // hands over `FleetGreeting.timeOfDay()`.
            //
            // Asserted against that function rather than against a literal,
            // so this case cannot pin a greeting that varies by hour.
            check(card.debugHeadline == FleetGreeting.timeOfDay(),
                  "with the host's own calm sentence, got \"\(card.debugHeadline)\"", &ok)
            check(card.debugAccentRows.isEmpty,
                  "and no rows, got \(card.debugAccentRows.count)", &ok)
            // The mockup's all-clear state: no list, and the sunk strip of
            // readings that are fine. With nothing read at all, the body
            // still says what the card is rather than rendering an empty box.
            check(!card.debugClearNotes.isEmpty
                      || card.debugListText.contains(where: { $0.contains("shows up here") }),
                  "but the body still says something rather than rendering an empty box, "
                      + "got \(card.debugListText)", &ok)
            check(card.debugCard.debugAttentionEdgeColor == nil,
                  "an all-clear card carries no attention edge (UI-4)", &ok)
            // And it must not simply repeat the headline - two renderings of
            // one sentence is what this line replaced.
            check(!card.debugListText.contains(card.debugHeadline),
                  "the body should not restate the headline, got \(card.debugListText)", &ok)
        }
    }

    // MARK: 5 - gotcha (13)

    /// A full-width card must not become a window-size floor. Behavioural
    /// rather than a source guard, because a required constraint above
    /// priority 500 resizes the window with nothing logged.
    private static func checkDoesNotResizeTheWindow(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas, size: NSSize(width: 1300, height: 900))
            defer { window.orderOut(nil) }

            let shrunk = NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                                width: 760, height: 620)
            window.setFrame(shrunk, display: true)
            canvas.view.layoutSubtreeIfNeeded()

            check(abs(window.frame.width - 760) < 2,
                  "the card must not hold the window open, got \(window.frame.width)", &ok)
            let card = canvas.attentionCardForTests
            check(card.frame.width <= window.frame.width,
                  "and the card should fit inside it, got \(card.frame.width) in \(window.frame.width)",
                  &ok)
            check(card.debugRows.allSatisfy { $0.frame.width <= card.frame.width + 1 },
                  "and so should every row, got \(card.debugRows.map(\.frame.width))", &ok)
        }
    }

    // MARK: 6 - the hub only

    private static func checkOnlyOnTheHub(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }

            check(!canvas.attentionCardHiddenForTests,
                  "the card is on the hub", &ok)

            // The fixture has to actually move, or the assertion below passes
            // for a space that was never selected.
            let other = DaylightSpace.allCases.first { $0 != .overview && $0.filtersCanvas }
            guard let other else {
                fail("no second canvas-filtering space to switch to - this check is vacuous", &ok)
                return
            }
            canvas.select(space: other)
            canvas.view.layoutSubtreeIfNeeded()
            check(canvas.selectedSpace == other,
                  "the fixture should have switched space, got \(canvas.selectedSpace)", &ok)
            check(canvas.attentionCardHiddenForTests,
                  "and the card should be hidden off the hub", &ok)
        }
    }

    // MARK: 9 - the list scrolls inside the card (`fm/grandline-home-fit-implement`)

    /// The real card, given less height than its rows need the way a page
    /// column gives it (a 499 tie, under the window's own 500), with the
    /// captain's ten-row worst case.
    private static func checkTheListScrollsInsideTheCard(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 700, height: 700, styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = host
        window.orderFront(nil)
        let card = NeedsAttentionCard()
        var opened: NeedsAttentionItem?
        card.onOpenItem = { opened = $0 }
        host.addSubview(card)
        let height = card.heightAnchor.constraint(equalToConstant: 460)
        height.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.widthAnchor.constraint(equalToConstant: 477),
            height,
        ])
        card.setLayoutWidth(477)
        card.render(ReviewTourLab.demoAttentionSummary(count: 10), subline: "Fleet read just now.",
                    theme: ThemeManager.shared.theme)
        host.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        // The cue is counted on the next main-queue turn, once the list's
        // stack has placed its rows.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let scroll = card.debugListScroll
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let visibleHeight = scroll.contentView.bounds.height
        // Discriminating power first: the fixture really is taller than the
        // room it was given, or every assertion below would pass vacuously.
        check(card.debugRows.count == 10, "the fixture should draw 10 rows, got \(card.debugRows.count)", &ok)
        check(documentHeight > visibleHeight + 50,
              "ten rows (\(documentHeight)pt) should not fit the \(visibleHeight)pt list", &ok)
        check(abs(card.frame.height - 460) < 1,
              "the card should take the height its host gave it, got \(card.frame.height)pt", &ok)
        check(card.debugEyebrow == "NEEDS ATTENTION \u{00B7} 10",
              "the eyebrow should carry the total, got \"\(card.debugEyebrow)\"", &ok)

        guard let hidden = card.debugMoreCount else {
            fail("rows are clipped but no \"+N more\" cue is shown", &ok)
            return
        }
        let fullyVisible = card.debugRows.filter { row in
            row.convert(row.bounds, to: scroll.documentView).maxY <= scroll.contentView.documentVisibleRect.maxY + 0.5
        }.count
        check(hidden == 10 - fullyVisible,
              "the cue says +\(hidden) more but \(10 - fullyVisible) rows are below the fold", &ok)
        check(card.debugListAccessibilityLabel == "Needs attention, 10 items, \(fullyVisible) visible",
              "VoiceOver should hear the list as one group with its counts, got "
              + "\(card.debugListAccessibilityLabel ?? "nothing")", &ok)
        check(scroll.verticalScroller?.controlSize == .small, "the list's scroller should be the small size", &ok)

        // The pill's own press pages down - through the accessibility press,
        // which is what VoiceOver and the pill's click both reach.
        let before = scroll.contentView.bounds.minY
        _ = card.debugMorePill.accessibilityPerformPress()
        check(scroll.contentView.bounds.minY > before + 1, "pressing the cue should scroll the list down", &ok)

        // Wheel routing: a clipped list keeps its wheel events. Asserted as
        // the scroll view's own decision rather than with a posted wheel
        // event, because a synthetic wheel event does not scroll an
        // off-screen window's scroll view even when delivered directly -
        // measured, so a check built on one could never fail.
        check(!scroll.forwardsWheelToPage, "a clipped list should keep its own wheel events", &ok)

        // Keyboard: with Full Keyboard Access, Tab lands on a row's checkbox
        // and its Open button (the row's own surface was never a key view).
        // Focus the last row's Open the way Tab does, and it must scroll its
        // row into view; then Space presses it.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let last = card.debugRows.last as? NeedsAttentionRowView {
            check(card.debugMoreCount != nil, "fixture: the last row should start below the fold", &ok)
            window.makeFirstResponder(last.debugActionButton)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let frame = last.convert(last.bounds, to: scroll.documentView)
            let visible = scroll.contentView.documentVisibleRect
            check(frame.maxY <= visible.maxY + 0.5 && frame.minY >= visible.minY - 0.5,
                  "a focused row should scroll into view - row \(frame), visible \(visible)", &ok)
            check(card.debugMoreCount == nil, "with the last row in view the cue should go away", &ok)
            if let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: " ", charactersIgnoringModifiers: " ",
                                            isARepeat: false, keyCode: 49) {
                window.sendEvent(space)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                check(opened?.id == "signal.claude",
                      "Space on the focused Open should open its row, opened \(opened?.id ?? "nothing")", &ok)
            }
            // VoiceOver reads the row's kind and state, not only its title.
            let label = last.debugRow.accessibilityLabel() ?? ""
            check(label.contains("Claude usage") && label.contains("92%"),
                  "the row's VoiceOver label should carry its kind and state, got \"\(label)\"", &ok)
        } else {
            fail("the last row is not an attention row", &ok)
        }

        // Three rows fit, so nothing is clipped and there is no cue.
        card.render(ReviewTourLab.demoAttentionSummary(count: 3), subline: "Fleet read just now.",
                    theme: ThemeManager.shared.theme)
        card.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(card.debugMoreCount == nil, "three rows in 460pt should show no cue", &ok)
        check(card.debugListScroll.forwardsWheelToPage,
              "a list with nothing to scroll should hand wheel events to the page", &ok)
        check(card.debugListAccessibilityLabel == "Needs attention, 3 items",
              "an unclipped list's label should not mention visibility, got "
              + "\(card.debugListAccessibilityLabel ?? "nothing")", &ok)
    }

    // MARK: 7 - the UI/UX revamp's recipe (UI-1 to UI-4)

    /// What the revamp changed, read off the painted card:
    ///
    ///   - UI-1: every row is `.flat` (no outline, no fill of its own), the
    ///     overdue fact is a red trailing caption rather than a pill, the
    ///     action is quiet until aimed at, and the row itself opens the item.
    ///   - UI-2: the clear strip's words are plain text, not pills.
    ///   - UI-3: Refresh is a line (secondary) button.
    ///   - UI-4: the card carries the attention edge while something is late.
    private static func checkTheRevampRecipe(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            let card = canvas.attentionCardForTests
            let theme = ThemeManager.shared.theme

            let rows = card.debugAccentRows
            check(!rows.isEmpty, "the seeded card should have rows", &ok)
            for row in rows {
                check(row.style == .flat, "every attention row should be flat", &ok)
                check(row.debugCardBorderWidth == 0, "a flat attention row draws no outline", &ok)
                check(row.debugChipText == nil, "an attention row carries no pill", &ok)
                check(row.actionReveal == .onAim, "the row's action is quiet until aimed at", &ok)
            }
            // N1: the state is a run on the meta line, in the critical tint
            // as legible text - read off the painted attributed string at the
            // state's own range, and the kind before it stays muted.
            if let late = rows.first(where: { $0.debugMetaText.contains("Overdue") }) {
                let meta = late.debugMetaAttributed
                let stateAt = (meta.string as NSString).range(of: "Overdue").location
                let red = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                                         over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                                         theme: theme)
                if let color = meta.attribute(.foregroundColor, at: stateAt, effectiveRange: nil) as? NSColor,
                   let kindColor = meta.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                    let a = HelmContrast.components(color), b = HelmContrast.components(red)
                    check(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) < 0.03,
                          "the overdue state should be the critical tint as legible text", &ok)
                    let k = HelmContrast.components(kindColor), m = HelmContrast.components(HelmTheme.mutedInk(theme))
                    check(abs(k.0 - m.0) + abs(k.1 - m.1) + abs(k.2 - m.2) < 0.03,
                          "the kind before the state should stay muted", &ok)
                } else {
                    fail("the overdue row's meta line carries no colours", &ok)
                }
                check(late.debugTrailingCaption == nil, "an N1 row paints no trailing caption", &ok)
            } else {
                fail("an overdue row should paint its state on the meta line", &ok)
            }

            // The row itself opens the item, through the row's own press.
            var opened: NeedsAttentionItem?
            card.onOpenItem = { opened = $0 }
            if let first = card.debugRows.first as? NeedsAttentionRowView {
                check(first.debugPressRow(), "pressing the row should be handled", &ok)
                check(opened != nil, "and pressing the row should open its item", &ok)
            }

            check(card.debugRefreshButton.variant == .secondary, "Refresh should be a line button (UI-3)", &ok)
            check(card.debugCard.debugAttentionEdgeColor != nil,
                  "a card with late rows carries the attention edge (UI-4)", &ok)
            for pill in Self.descendants(of: card.debugClearStrip).compactMap({ $0 as? HelmStatusPill }) {
                fail("the clear strip should hold words, not pills - found \(pill.text)", &ok)
            }
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: 8 - the freshness subline ticks (UI-13)

    /// The subline says how old the fleet reading is, so it has to stay true
    /// while the page sits open. The card re-reads it from its host once a
    /// minute while it is in a window; here the tick is fired through the
    /// same path the timer takes, and the phrase must move.
    private static func checkTheSublineTicks(_ ok: inout Bool) {
        withScratchShift { store in
            seed(store)
            let canvas = makeCanvas(store)
            let window = mount(canvas)
            defer { window.orderOut(nil) }
            let card = canvas.attentionCardForTests
            check(card.debugTickIsRunning, "the tick should run while the card is in a window", &ok)
            let before = card.debugSubline
            var phrase = "Fleet read 7 min ago."
            card.sublineProvider = { phrase }
            card.debugTickSubline()
            check(card.debugSubline == "Fleet read 7 min ago." && card.debugSubline != before,
                  "a tick should rewrite the subline from its provider, got \"\(card.debugSubline)\"", &ok)
            phrase = "Fleet read 8 min ago."
            card.debugTickSubline()
            check(card.debugSubline == phrase, "and keep tracking it", &ok)
            window.contentView = NSView()
            check(!card.debugTickIsRunning, "the tick should stop once the card leaves its window (GL-13)", &ok)
        }
    }
}

#endif
