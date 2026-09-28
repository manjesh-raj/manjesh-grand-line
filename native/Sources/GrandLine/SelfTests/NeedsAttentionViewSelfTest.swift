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
            check(painted.contains(where: { $0.hasPrefix("Overdue") && $0.contains("since") }),
                  "and a row should carry the overdue chip, got \(painted)", &ok)

            // The source labels are `HelmAccentRow` kickers, rendered
            // uppercase by the component - the mockup's small all-caps label.
            let kickers = card.debugAccentRows.map(\.debugKickerText)
            check(kickers.contains("TASK") && kickers.contains("FOLLOW-UP"),
                  "each row should name its source in caps, got \(kickers)", &ok)

            check(card.debugEyebrow == "NEEDS ATTENTION, 2",
                  "the eyebrow should count the rows, got \"\(card.debugEyebrow)\"", &ok)
            check(card.debugHeadline == "Two things are late.",
                  "the headline should be the plain sentence, got \"\(card.debugHeadline)\"", &ok)
            check(card.debugSubline.contains("\u{00B7}"),
                  "the subline should name the day and the time, got \"\(card.debugSubline)\"", &ok)

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
            check(card.debugHeadline == "Nothing is due, and nobody is waiting on you.",
                  "with the calm sentence, got \"\(card.debugHeadline)\"", &ok)
            check(card.debugAccentRows.isEmpty,
                  "and no rows, got \(card.debugAccentRows.count)", &ok)
            check(card.debugListText.contains(where: { $0.contains("shows up here") }),
                  "but the body still says what the card is rather than rendering an empty box, "
                      + "got \(card.debugListText)", &ok)
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
}

#endif
