// Manjesh Grand Line - native macOS app.
//
// F7's render: a real `DaylightBarController` and a real `ShiftController`
// mounted in real windows, over a scratch store, with the real timer driving
// them.
//
// **Why this is window-backed and separate from `FocusTimerSelfTest`.**
// Everything here is a question about a render or about real laid-out
// geometry: whether the chip actually *appears on the bar* when a session
// starts and actually leaves it again (an arranged subview's width, which is
// the whole reason the chip is wrapped in a stack - AGENTS.md gotcha (11)),
// whether the chip's own text tracks the countdown, whether the ring's arc
// fraction follows the session, whether the popover's Pause button relabels,
// and whether the chip and the Weekly Review chart re-theme. The state
// machine itself runs in CI's *blocking* lane in the sibling suite; this one
// sits in `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with `FM_RUN_FOCUS_TIMER_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

#if FM_SELFTESTS

import AppKit

enum FocusTimerViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        let themeBefore = ThemeManager.shared.theme
        // AGENTS.md's hermeticity rule: this suite changes the theme, so it
        // captures it first and restores it. `Phase3PolishSelfTest` fails
        // the run on a suite that calls `setTheme` without reading `theme`.
        defer { ThemeManager.shared.setTheme(themeBefore) }

        withScratchStore { store in
            checkBarChip(store: store, check: check)
            checkPopoverPanel(store: store, check: check)
            checkWeeklyReviewTile(store: store, check: check)
        }

        return report(failures)
    }

    // MARK: The bar chip

    private static func checkBarChip(store: ShiftStore, check: (Bool, String) -> Void) {
        autoreleasepool {
            let timer = FocusTimerController(store: store)
            var clock = Date(timeIntervalSince1970: 1_750_000_000)
            timer.clock = { clock }

            let bar = DaylightBarController()
            let window = OffScreenProbe.window(width: 1500, height: 120,
                                               styleMask: [.titled, .resizable])
            window.contentView = bar.view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            bar.attachFocusTimer(timer)
            bar.view.layoutSubtreeIfNeeded()

            // MARK: The bar with no session is the bar that existed before F7

            check(!bar.debugFocusChipIsVisible,
                  "the chip must not be on the bar before anything is running")
            let idleChipWidth = bar.debugFocusChipHostWidth
            // The whole point of hiding an *arranged* subview: a hidden
            // ordinary `NSView` would keep its width on the bar forever.
            check(idleChipWidth < 1,
                  "a hidden chip must take no width on the bar, got \(idleChipWidth)")

            // MARK: Starting a session puts it there

            var task = ShiftTask.fresh()
            task.title = "Rotate the prod bastion SSH keys"
            store.addTask(task)
            timer.start(task: task, minutes: 25)
            bar.view.layoutSubtreeIfNeeded()

            check(bar.debugFocusChipIsVisible, "the chip should appear when a session starts")
            let runningWidth = bar.debugFocusChipHostWidth
            check(runningWidth > 80,
                  "the chip should have a real laid-out width, got \(runningWidth)")
            check(bar.debugFocusChip.debugCountdownText == "25:00",
                  "the chip starts at the full 25:00, got \(bar.debugFocusChip.debugCountdownText)")
            check(bar.debugFocusChip.debugTitleText == task.title,
                  "the chip names the task, got \(bar.debugFocusChip.debugTitleText)")
            check(bar.debugFocusChip.debugRingFraction < 0.01,
                  "the ring starts empty, got \(bar.debugFocusChip.debugRingFraction)")

            // MARK: It counts down
            //
            // Driven through the controller's own tick rather than by
            // waiting on the wall clock - the numbers are all derived from
            // the injected `Date`, so this is the same code path a real
            // second takes.

            clock = clock.addingTimeInterval(456)
            timer.debugTick()
            bar.view.layoutSubtreeIfNeeded()
            check(bar.debugFocusChip.debugCountdownText == "17:24",
                  "7:36 in the chip should read 17:24, got \(bar.debugFocusChip.debugCountdownText)")
            check(abs(bar.debugFocusChip.debugRingFraction - 456.0 / 1500.0) < 0.01,
                  "the ring tracks the session, got \(bar.debugFocusChip.debugRingFraction)")

            // MARK: The chip re-themes
            //
            // Both directions of the Daylight split `FocusTint` makes, since
            // the two branches resolve different hues entirely.

            let daylight = HelmTheme.allThemes.first(where: { $0.isDaylight })
                ?? ThemeManager.shared.theme
            let legacy = HelmTheme.allThemes.first(where: { !$0.isDaylight })
                ?? ThemeManager.shared.theme
            ThemeManager.shared.setTheme(daylight)
            bar.view.layoutSubtreeIfNeeded()
            let daylightFill = bar.debugFocusChip.layer?.backgroundColor
            ThemeManager.shared.setTheme(legacy)
            bar.view.layoutSubtreeIfNeeded()
            let legacyFill = bar.debugFocusChip.layer?.backgroundColor
            check(daylightFill != nil && legacyFill != nil,
                  "the chip should paint a real fill in both registers")
            check(daylightFill != legacyFill,
                  "the chip's fill should differ between a Daylight and a legacy palette")

            // MARK: The chip cannot cap the window
            //
            // `DaylightModuleSelfTest.checkBarDoesNotCapWindow` skips this
            // chip's subtree, on the same "a content-sized cluster yields
            // before the window does" ground the bell and the drill header
            // are skipped on. A source skip and a behavioural check catch
            // different things (AGENTS.md), so this is the behavioural half:
            // a real window, really shrunk, with the chip really on the bar.
            //
            // 700 is the bar's own stated comfortable floor
            // (`DaylightBarController.comfortableWidth`), so a bar that
            // cannot reach it is capping the window in the way gotcha (13)
            // describes.
            let wide = window.frame
            window.setFrame(NSRect(x: wide.minX, y: wide.minY, width: 700, height: wide.height),
                            display: true)
            bar.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - 700) < 1,
                  "the window should hold 700pt with the chip on the bar, got \(window.frame.width)")
            check(bar.debugFocusChipHostWidth <= 700,
                  "and the chip should have yielded rather than overflowed, got "
                  + "\(bar.debugFocusChipHostWidth)")
            window.setFrame(wide, display: true)
            bar.view.layoutSubtreeIfNeeded()

            // MARK: Finishing takes it off the bar again

            clock = clock.addingTimeInterval(200)
            _ = timer.stop()
            bar.view.layoutSubtreeIfNeeded()
            check(!bar.debugFocusChipIsVisible,
                  "the chip should leave the bar when the session ends")
            check(bar.debugFocusChipHostWidth < 1,
                  "and give its width back, got \(bar.debugFocusChipHostWidth)")
        }
    }

    // MARK: The popover panel

    private static func checkPopoverPanel(store: ShiftStore, check: (Bool, String) -> Void) {
        autoreleasepool {
            let timer = FocusTimerController(store: store)
            var clock = Date(timeIntervalSince1970: 1_750_000_000)
            timer.clock = { clock }

            var task = ShiftTask.fresh()
            task.title = "Renew wildcard TLS certificate"
            store.addTask(task)
            timer.start(task: task, minutes: 25)

            let panel = FocusTimerPanelController(timer: timer)
            let window = OffScreenProbe.window(width: 260, height: 260,
                                               styleMask: [.titled])
            window.contentView = panel.view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            panel.viewWillAppear()
            panel.view.layoutSubtreeIfNeeded()

            check(panel.debugTaskTitle == task.title,
                  "the panel names the focused task, got \(panel.debugTaskTitle)")
            check(panel.debugRing.centreLabelForTests == "25:00",
                  "the ring's centre reads the countdown, got \(panel.debugRing.centreLabelForTests)")
            check(panel.debugRing.fractionForTests < 0.01,
                  "the ring starts empty, got \(panel.debugRing.fractionForTests)")
            // The gauge lays its own arc out, so a ring with no frame is a
            // real and otherwise-invisible failure.
            check(panel.debugRing.frame.width >= HelmRingGauge.side - 0.5,
                  "the ring should be laid out at its own size, got \(panel.debugRing.frame.width)")

            clock = clock.addingTimeInterval(750)
            panel.viewWillAppear()
            check(panel.debugRing.centreLabelForTests == "12:30",
                  "half way through reads 12:30, got \(panel.debugRing.centreLabelForTests)")
            check(abs(panel.debugRing.fractionForTests - 0.5) < 0.01,
                  "and the arc is half, got \(panel.debugRing.fractionForTests)")

            // MARK: Pause relabels and stops the clock

            check(panel.debugPauseButtonTitle == "Pause",
                  "a running session offers Pause, got \(panel.debugPauseButtonTitle)")
            panel.debugTapPause()
            check(panel.debugPauseButtonTitle == "Resume",
                  "a paused session offers Resume, got \(panel.debugPauseButtonTitle)")
            clock = clock.addingTimeInterval(600)
            panel.viewWillAppear()
            check(panel.debugRing.centreLabelForTests == "12:30",
                  "ten minutes paused must not move the countdown, got "
                  + "\(panel.debugRing.centreLabelForTests)")

            // MARK: +5 min puts time back on the ring

            panel.debugTapExtend()
            check(panel.debugRing.centreLabelForTests == "17:30",
                  "+5 min on 12:30 is 17:30, got \(panel.debugRing.centreLabelForTests)")

            _ = timer.stop()
        }
    }

    // MARK: Weekly Review's tile

    private static func checkWeeklyReviewTile(store: ShiftStore, check: (Bool, String) -> Void) {
        autoreleasepool {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date()).addingTimeInterval(11 * 3600)
            store.logFocusSession(taskID: "a", taskTitle: "A", seconds: 1500, now: today)
            store.logFocusSession(taskID: "b", taskTitle: "B", seconds: 5940, now: today)

            let timer = FocusTimerController(store: store)
            let controller = ShiftController(store: store, focusTimer: timer)
            let window = OffScreenProbe.window(width: 1300, height: 950,
                                               styleMask: [.titled, .resizable])
            window.contentView = controller.view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            controller.viewWillAppear()
            drainMainQueue()
            controller.showWeeklyReview()
            controller.view.layoutSubtreeIfNeeded()

            let chart = controller.debugFocusChart
            check(controller.debugFocusPanelIsVisible,
                  "the Time on tasks panel should be on Weekly Review")
            check(chart.debugBars.count == 7,
                  "the chart is a week of bars, got \(chart.debugBars.count)")
            check(chart.frame.width > 40 && chart.frame.height > 20,
                  "the chart should have a real frame, got \(chart.frame)")

            // GL-14: a day with nothing logged is present as a measured
            // zero, not omitted - which is exactly what makes the "7 bars"
            // count above meaningful rather than coincidental.
            let today7 = chart.debugBars.last
            check(today7?.isToday == true, "the last bar is today")
            check(today7?.seconds == 7440,
                  "today sums both sessions, got \(today7?.seconds ?? -1)")
            check(chart.debugBars.first?.seconds == 0,
                  "six days back is a real zero bar, got \(chart.debugBars.first?.seconds ?? -1)")

            check(controller.debugFocusHeadline == "2h 04m",
                  "the headline reads the day's total, got \(controller.debugFocusHeadline)")
            check(controller.debugFocusCaption.contains("2 task"),
                  "the caption counts the distinct tasks, got \(controller.debugFocusCaption)")

            // MARK: The chart re-themes

            let daylight = HelmTheme.allThemes.first(where: { $0.isDaylight })
                ?? ThemeManager.shared.theme
            let legacy = HelmTheme.allThemes.first(where: { !$0.isDaylight })
                ?? ThemeManager.shared.theme
            ThemeManager.shared.setTheme(daylight)
            controller.view.layoutSubtreeIfNeeded()
            let daylightRender = renderPixel(of: chart)
            ThemeManager.shared.setTheme(legacy)
            controller.view.layoutSubtreeIfNeeded()
            let legacyRender = renderPixel(of: chart)
            check(daylightRender != nil && legacyRender != nil,
                  "the chart should render in both registers")
            check(daylightRender != legacyRender,
                  "the chart's bars should repaint when the theme changes")
        }
    }

    /// The colour of the tallest bar, sampled out of a real render.
    ///
    /// AGENTS.md's probe rules: `bitmapImageRepForCachingDisplay` hands back
    /// a rep measured in **pixels**, which on a retina machine is twice the
    /// view's own points - so the sample point is scaled before indexing.
    /// The comparison here is render-against-render rather than
    /// render-against-an-expected-colour, so no colour-space conversion is
    /// involved (which is the other half of that rule).
    private static func renderPixel(of view: NSView) -> [CGFloat]? {
        guard view.bounds.width > 4, view.bounds.height > 4,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / view.bounds.height
        // The last bar is today's and is the tallest here; sample a little
        // way up its column. The view is unflipped, so a low y in points is
        // a high row in the rep - mirror it.
        let pointX = view.bounds.width - 6
        let pointY = FocusWeekBarView.barAreaHeight * 0.3 + 20
        let x = Int(pointX * scaleX)
        let y = rep.pixelsHigh - 1 - Int(pointY * scaleY)
        guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh,
              let colour = rep.colorAt(x: x, y: y) else { return nil }
        return [colour.redComponent, colour.greenComponent, colour.blueComponent,
                colour.alphaComponent]
    }

    // MARK: Helpers

    /// `reloadAllAsync` renders on completion, so the queue is drained
    /// before anything reads the page - the same shape and the same turn
    /// count `ShiftCalendarViewSelfTest` uses.
    private static func drainMainQueue(turns: Int = 40) {
        for _ in 0..<turns {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-timer-view-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[FocusTimerViewSelfTest] all checks passed")
            return true
        }
        print("[FocusTimerViewSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
