// Manjesh Grand Line - native macOS app.
//
// F5's calendar view: a real `ShiftController` mounted in a real window over
// a scratch store, with the Calendar pill genuinely clicked.
//
// **Why this is window-backed and separate from `ShiftRecurrenceSelfTest`.**
// Everything here is a question about a render: whether the third pill
// reaches the page, whether the grid's 42 cells actually lay themselves out
// (the grid sizes its own cells in `layout()`, so a cell with a zero frame is
// a real and otherwise-invisible failure), whether a projected occurrence is
// drawn faintly, and whether the day cells re-theme. The rule maths runs in
// CI's blocking lane in its sibling suite; this one sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

#if FM_SELFTESTS

import AppKit

enum ShiftCalendarViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        let themeBefore = ThemeManager.shared.theme
        // AGENTS.md's hermeticity rule: this suite changes the theme, so it
        // captures and restores it. `Phase3PolishSelfTest` fails the run on a
        // suite that calls `setTheme` without reading `theme` first.
        defer { ThemeManager.shared.setTheme(themeBefore) }

        withScratchStore { store in
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let todayDay = ShiftDateFormatting.components(from: today).0
            // Two days out, so the projected chips land inside the same month
            // grid as the anchor for all but the last two days of a month -
            // and when they do not, the anchor's own chip still does, which
            // is what the first assertions below read.
            let anchorDay = todayDay

            let repeating = seed(store, title: "Standup notes", due: anchorDay, time: "09:30",
                                 rule: ShiftRecurrence(frequency: .daily))
            let single = seed(store, title: "Renew wildcard TLS", due: anchorDay, time: nil, rule: nil)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            // MARK: The third pill reaches the page

            check(!controller.debugBoardIsVisible == false,
                  "the board should be the page's default view")
            check(!controller.debugCalendarIsVisible,
                  "the calendar must not be showing before it is selected")

            controller.debugSelectTasksView("calendar")
            controller.view.layoutSubtreeIfNeeded()

            check(controller.debugCalendarIsVisible,
                  "clicking the Calendar pill should show the calendar")
            check(!controller.debugBoardIsVisible,
                  "the board should hide when the calendar is showing")
            check(controller.debugTaskPanelIsVisible == false,
                  "the flat task panel should hide when the calendar is showing")

            let view = controller.debugCalendarView

            // MARK: The grid really laid out
            //
            // The grid computes its own cell frames, so "42 cells exist" and
            // "42 cells have a size" are different claims and only the second
            // one means the month is on screen.

            let cells = view.debugCells
            check(cells.count == 42,
                  "a month grid is six weeks of seven days, got \(cells.count)")
            let sized = cells.filter { $0.frame.width > 20 && $0.frame.height > 20 }
            check(sized.count == cells.count,
                  "every cell should have a real frame, \(cells.count - sized.count) did not")
            // The cells tile with exactly the 1pt hairline between them - the
            // gap the grid's own background is seen through, and the thing
            // that makes a day boundary visible at all (measured: with the
            // cells edge to edge, a light theme's month read as one
            // undifferentiated field). Asserted as a *number* rather than
            // "greater than zero", so a cell inset that drifts to 4pt fails
            // here rather than quietly becoming spacing.
            if cells.count >= 8 {
                check(abs(cells[7].frame.minY - cells[0].frame.maxY - 1) < 0.6,
                      "rows should be separated by exactly the 1pt hairline, got "
                      + "\(cells[7].frame.minY - cells[0].frame.maxY)")
                check(abs(cells[1].frame.minX - cells[0].frame.maxX - 1) < 0.6,
                      "columns should be separated by exactly the 1pt hairline, got "
                      + "\(cells[1].frame.minX - cells[0].frame.maxX)")
            }

            check(cells.filter(\.debugIsToday).count == 1,
                  "exactly one cell is today, got \(cells.filter(\.debugIsToday).count)")

            // MARK: Both tasks landed on the right day

            guard let anchorCell = view.debugCell(day: anchorDay) else {
                failures.append("the grid has no cell for \(anchorDay)")
                return
            }
            let titles = anchorCell.debugChipTitles
            check(titles.contains(where: { $0.contains("Renew wildcard TLS") }),
                  "a one-off task should appear on its own due day, got \(titles)")
            check(titles.contains(where: { $0.contains("Standup notes") }),
                  "a recurring task's own instance should appear on its due day, got \(titles)")
            check(anchorCell.debugProjectedFlags.allSatisfy { $0 == false },
                  "neither chip on the anchor day is a projection - both are real records")

            // MARK: A projected occurrence is drawn as a projection
            //
            // GL-14 in a new place: an occurrence that has no task record yet
            // must not render identically to one that does.

            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            let tomorrowDay = ShiftDateFormatting.components(from: tomorrow).0
            if let tomorrowCell = view.debugCell(day: tomorrowDay) {
                check(tomorrowCell.debugChipTitles.contains(where: { $0.contains("Standup notes") }),
                      "a daily rule should project onto tomorrow, got \(tomorrowCell.debugChipTitles)")
                check(tomorrowCell.debugProjectedFlags.contains(true),
                      "tomorrow's chip must be flagged as projected")
                check(!tomorrowCell.debugChipTitles.contains(where: { $0.contains("Renew wildcard TLS") }),
                      "a task with no rule must not appear on any day but its own")
                let alphas = tomorrowCell.debugChipAlphas
                check(alphas.allSatisfy { $0 < 1 },
                      "a projected chip should be drawn faint, got \(alphas)")
                // The discriminating half: the anchor day's own chips are
                // fully opaque, so "faint" is a real difference rather than
                // the whole grid being dim.
                check(anchorCell.debugChipAlphas.allSatisfy { $0 == 1 },
                      "a real task's chip is fully opaque, got \(anchorCell.debugChipAlphas)")
            } else {
                failures.append("the grid has no cell for tomorrow (\(tomorrowDay))")
            }

            // MARK: The subtitle states what is on screen (GL-14)

            check(!view.debugSubtitle.isEmpty, "the calendar should always state its own contents")
            check(view.debugSubtitle.contains("projected"),
                  "a month carrying projections should say so, got \"\(view.debugSubtitle)\"")

            // MARK: Paging and the week scale

            let monthTitle = view.debugTitle
            view.debugStep(1)
            controller.view.layoutSubtreeIfNeeded()
            check(view.debugTitle != monthTitle,
                  "stepping forward a month should change the title, still \"\(monthTitle)\"")
            view.debugStep(-1)
            controller.view.layoutSubtreeIfNeeded()
            check(view.debugTitle == monthTitle,
                  "stepping back should return to the same month, got \"\(view.debugTitle)\"")

            view.debugSelectScale(.week)
            controller.view.layoutSubtreeIfNeeded()
            check(view.debugCells.count == 7,
                  "the week scale shows seven days, got \(view.debugCells.count)")
            check(view.debugCells.first.map { $0.frame.height > 100 } ?? false,
                  "a week cell should be taller than a month cell, got "
                  + "\(view.debugCells.first?.frame.height ?? 0)")
            view.debugSelectScale(.month)
            controller.view.layoutSubtreeIfNeeded()

            // MARK: Overflow is stated rather than silently dropped

            for index in 0..<5 {
                _ = seed(store, title: "Extra \(index)", due: anchorDay, time: "1\(index):00", rule: nil)
            }
            controller.debugRender()
            controller.view.layoutSubtreeIfNeeded()
            if let busy = view.debugCell(day: anchorDay) {
                check(busy.debugChipTitles.count == 3,
                      "a month cell shows three chips, got \(busy.debugChipTitles.count)")
                check(busy.debugOverflowText.hasPrefix("+"),
                      "the rest must be counted, not dropped - got \"\(busy.debugOverflowText)\"")
            } else {
                failures.append("the busy day's cell disappeared after a re-render")
            }

            // MARK: The grid re-themes
            //
            // A theme observer repaints (GL-24), and a grid whose cells were
            // themed once at build time would keep the old theme's fills.

            guard let latte = HelmTheme.theme(id: "catppuccin-latte"),
                  let dusk = HelmTheme.theme(id: "dusk") else {
                failures.append("the two fixture themes are no longer in HelmTheme.allThemes")
                return
            }
            ThemeManager.shared.setTheme(latte)
            controller.view.layoutSubtreeIfNeeded()
            let lightFill = view.debugCells.first?.layer?.backgroundColor
            ThemeManager.shared.setTheme(dusk)
            controller.view.layoutSubtreeIfNeeded()
            let darkFill = view.debugCells.first?.layer?.backgroundColor
            check(lightFill != nil && darkFill != nil && lightFill != darkFill,
                  "a day cell should repaint when the theme changes")

            _ = repeating
            _ = single
        }

        return report(failures)
    }

    // MARK: Helpers

    @discardableResult
    private static func seed(_ store: ShiftStore, title: String, due: String?, time: String?,
                             rule: ShiftRecurrence?) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.dueDate = due
        task.dueTime = time
        task.recurrence = rule
        store.addTask(task)
        return task.id
    }

    private static func mount(store: ShiftStore) -> (ShiftController, NSWindow) {
        let controller = ShiftController(store: store)
        let window = OffScreenProbe.window(width: 1300, height: 950,
                                           styleMask: [.titled, .resizable])
        window.contentView = controller.view
        window.orderFront(nil)
        controller.viewWillAppear()
        drainMainQueue()
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// `reloadAllAsync` renders on completion, so the queue is drained
    /// before anything reads the grid - the same shape and the same turn
    /// count `ShiftBoardViewSelfTest` uses.
    private static func drainMainQueue(turns: Int = 40) {
        for _ in 0..<turns {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-calendar-view-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftCalendarViewSelfTest] all checks passed")
            return true
        }
        print("[ShiftCalendarViewSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
