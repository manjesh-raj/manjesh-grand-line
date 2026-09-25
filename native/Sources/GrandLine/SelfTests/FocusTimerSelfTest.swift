// Grand Line - native macOS app.
//
// F7's pure logic: the start/pause/resume/extend/stop state machine, the two
// duration formats, the activity-log write, and the per-day aggregation
// Weekly Review's tile reads.
//
// **Why this is not window-backed** (AGENTS.md's classification rule):
// every check here is a value check on a `FocusSession`, a formatted string,
// or a real file written to a scratch `ShiftStore`. It builds no view,
// mounts no window and reads no rendered geometry, so it runs in CI's
// *blocking* lane. The chip, the ring and the row button are a real render
// and live in `FocusTimerViewSelfTest` instead.
//
// `FocusTimerEngine` takes its `now` on every method precisely so this suite
// needs no run loop and no wall-clock waiting - the whole matrix is asserted
// against fabricated instants, which is also the only way the "a paused
// session earns no minutes" claim can be made at all.
//
// Run with `FM_RUN_FOCUS_TIMER_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import Foundation

enum FocusTimerSelfTest {

    /// An arbitrary fixed instant. Every duration below is an offset from
    /// it, so nothing here depends on when the suite runs.
    private static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private static func at(_ seconds: Int) -> Date { t0.addingTimeInterval(TimeInterval(seconds)) }

    static func run() -> Bool {
        var ok = true

        checkFormatting(&ok)
        checkStartAndCountdown(&ok)
        checkPauseEarnsNoTime(&ok)
        checkExtend(&ok)
        checkCompletion(&ok)
        checkStopReturnsSpentTime(&ok)
        checkStartingASecondTaskDisplacesTheFirst(&ok)
        checkBackwardsClock(&ok)
        checkActivityLogWrite(&ok)
        checkShortSessionIsNotLogged(&ok)
        checkPerDayAggregation(&ok)
        checkActivityRoundTripKeepsTheDuration(&ok)
        checkSwitchingTasksLogsTheFirstOne(&ok)
        checkSleepEarnsNoFocusTime(&ok)
        checkACaptainsPauseSurvivesASleep(&ok)

        if ok { print("[FocusTimerSelfTest] all checks passed") }
        return ok
    }

    // MARK: Formatting

    private static func checkFormatting(_ ok: inout Bool) {
        check(FocusTimerFormat.countdown(1500) == "25:00",
              "25 minutes should read 25:00, got \(FocusTimerFormat.countdown(1500))", &ok)
        check(FocusTimerFormat.countdown(1044) == "17:24",
              "the mockup's own 17:24, got \(FocusTimerFormat.countdown(1044))", &ok)
        check(FocusTimerFormat.countdown(9) == "0:09",
              "seconds are zero-padded, got \(FocusTimerFormat.countdown(9))", &ok)
        // A negative is reachable only through a clock adjustment, and must
        // read as done rather than as a growing countdown.
        check(FocusTimerFormat.countdown(-5) == "0:00",
              "a negative countdown floors at zero, got \(FocusTimerFormat.countdown(-5))", &ok)
        // The mockup's own "2h 05m", which is what pins the zero-padding on
        // the minutes half.
        check(FocusTimerFormat.total(7500) == "2h 05m",
              "2h05 should read 2h 05m, got \(FocusTimerFormat.total(7500))", &ok)
        check(FocusTimerFormat.total(2880) == "48m",
              "under an hour drops the hours field, got \(FocusTimerFormat.total(2880))", &ok)
        check(FocusTimerFormat.total(59) == "0m",
              "under a minute rounds down, got \(FocusTimerFormat.total(59))", &ok)
        // The fixture's own discriminating power: these two must not be the
        // same string, or every assertion above about which format is used
        // where is vacuous.
        check(FocusTimerFormat.countdown(1500) != FocusTimerFormat.total(1500),
              "the countdown and total formats must be distinguishable", &ok)
    }

    // MARK: The state machine

    private static func checkStartAndCountdown(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        check(!engine.isRunning, "a fresh engine is not running", &ok)

        engine.start(taskID: "t1", title: "Rotate prod SSH keys", minutes: 25, now: t0)
        guard let session = engine.session else {
            fail("start should produce a session", &ok)
            return
        }
        check(engine.isRunning, "the engine is running after start", &ok)
        check(session.plannedSeconds == 1500,
              "25 minutes is 1500 seconds, got \(session.plannedSeconds)", &ok)
        check(session.elapsed(at: t0) == 0, "nothing has elapsed at t0", &ok)
        check(session.remaining(at: at(456)) == 1044,
              "7:36 in leaves 17:24, got \(session.remaining(at: at(456)))", &ok)
        check(abs(session.fraction(at: at(750)) - 0.5) < 0.001,
              "half way through is fraction 0.5, got \(session.fraction(at: at(750)))", &ok)
        check(!session.isPaused, "a started session is not paused", &ok)
    }

    /// The claim the whole `accumulatedSeconds` design exists for.
    private static func checkPauseEarnsNoTime(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        engine.start(taskID: "t1", title: "Task", minutes: 25, now: t0)

        engine.pause(now: at(300))            // 5 minutes in
        check(engine.session?.isPaused == true, "the session reads paused", &ok)
        check(engine.session?.elapsed(at: at(300)) == 300,
              "5 minutes were banked at the pause", &ok)

        // An hour passes while paused. None of it is focus time.
        check(engine.session?.elapsed(at: at(3900)) == 300,
              "an hour paused must add nothing, got "
              + "\(engine.session?.elapsed(at: at(3900)) ?? -1)", &ok)
        check(engine.session?.remaining(at: at(3900)) == 1200,
              "20 minutes are still owed after an hour paused", &ok)

        engine.resume(now: at(3900))
        check(engine.session?.isPaused == false, "the session reads running after resume", &ok)
        check(engine.session?.elapsed(at: at(4020)) == 420,
              "2 more minutes on top of the banked 5, got "
              + "\(engine.session?.elapsed(at: at(4020)) ?? -1)", &ok)

        // Pause/resume are idempotent rather than errors - the chip, the
        // popover and the row can each reach them, and a double-click must
        // not double-bank a segment.
        engine.resume(now: at(4200))
        check(engine.session?.elapsed(at: at(4020)) == 420,
              "resuming an already-running session changes nothing", &ok)
        engine.pause(now: at(4200))
        engine.pause(now: at(4800))
        check(engine.session?.elapsed(at: at(4800)) == 600,
              "pausing twice banks the segment once, got "
              + "\(engine.session?.elapsed(at: at(4800)) ?? -1)", &ok)
    }

    private static func checkExtend(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        engine.start(taskID: "t1", title: "Task", minutes: 25, now: t0)
        engine.extend()
        check(engine.session?.plannedSeconds == 1800,
              "+5 min makes 30 minutes, got \(engine.session?.plannedSeconds ?? -1)", &ok)

        // Extending a session that has already run out is the case a captain
        // actually reaches for, so it has to work rather than be refused.
        var expired = FocusTimerEngine()
        expired.start(taskID: "t1", title: "Task", minutes: 1, now: t0)
        check(expired.session?.isComplete(at: at(60)) == true,
              "a 1-minute session is complete at 60s", &ok)
        expired.extend()
        check(expired.session?.isComplete(at: at(60)) == false,
              "extending an expired session puts time back on the clock", &ok)
        check(expired.session?.remaining(at: at(60)) == 300,
              "5 more minutes, got \(expired.session?.remaining(at: at(60)) ?? -1)", &ok)
    }

    private static func checkCompletion(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        engine.start(taskID: "t1", title: "Task", minutes: 25, now: t0)
        check(engine.session?.isComplete(at: at(1499)) == false,
              "one second short is not complete", &ok)
        check(engine.session?.isComplete(at: at(1500)) == true,
              "exactly 25 minutes is complete", &ok)
        // Past the end the ring is full and the countdown is zero - never a
        // fraction above 1 (which would draw a second lap) or a negative
        // countdown.
        check(engine.session?.fraction(at: at(9000)) == 1,
              "the fraction never exceeds 1", &ok)
        check(engine.session?.remaining(at: at(9000)) == 0,
              "the countdown never goes negative", &ok)
    }

    private static func checkStopReturnsSpentTime(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        check(engine.stop(now: t0) == nil, "stopping nothing returns nothing", &ok)

        engine.start(taskID: "t1", title: "Task", minutes: 25, now: t0)
        let finished = engine.stop(now: at(372))
        check(finished?.accumulatedSeconds == 372,
              "stop banks the live segment, got \(finished?.accumulatedSeconds ?? -1)", &ok)
        check(!engine.isRunning, "the engine is idle after stop", &ok)

        // Stopping while paused must return the banked figure, not zero.
        var paused = FocusTimerEngine()
        paused.start(taskID: "t1", title: "Task", minutes: 25, now: t0)
        paused.pause(now: at(240))
        let afterPause = paused.stop(now: at(9000))
        check(afterPause?.accumulatedSeconds == 240,
              "stopping a paused session returns what was banked, got "
              + "\(afterPause?.accumulatedSeconds ?? -1)", &ok)
    }

    private static func checkStartingASecondTaskDisplacesTheFirst(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        engine.start(taskID: "t1", title: "First", minutes: 25, now: t0)
        let displaced = engine.start(taskID: "t2", title: "Second", minutes: 25, now: at(600))
        check(displaced?.taskID == "t1",
              "the displaced session is handed back so its time can be logged", &ok)
        check(engine.session?.taskID == "t2", "the new session is the running one", &ok)
        check(engine.session?.elapsed(at: at(600)) == 0,
              "the new session starts from zero, not from the old one's clock", &ok)
        // The displaced session's own elapsed is readable at the switch
        // instant - which is what `FocusTimerController` logs.
        check(displaced?.elapsed(at: at(600)) == 600,
              "the displaced session had 10 minutes on it, got "
              + "\(displaced?.elapsed(at: at(600)) ?? -1)", &ok)
    }

    /// A machine that sleeps and wakes, or a clock corrected backwards, must
    /// not produce a growing countdown.
    private static func checkBackwardsClock(_ ok: inout Bool) {
        var engine = FocusTimerEngine()
        engine.start(taskID: "t1", title: "Task", minutes: 25, now: at(1000))
        check(engine.session?.elapsed(at: at(400)) == 0,
              "a `now` before the segment start reads as zero elapsed, got "
              + "\(engine.session?.elapsed(at: at(400)) ?? -1)", &ok)
        check(engine.session?.remaining(at: at(400)) == 1500,
              "and the countdown is the full plan, never more", &ok)
    }


    // MARK: Review bug B9

    /// **Switching tasks logged nothing for the first one.**
    ///
    /// `FocusTimerEngine.start` handed the displaced session back with its
    /// live segment unbanked, so `accumulatedSeconds` was 0 for any session
    /// that had never been paused - which is every ordinary one - and
    /// `FocusTimerController.logIfWorthLogging` reads exactly that field.
    /// Twenty minutes of real work on the first task evaporated, while
    /// `start`'s own doc comment promised "the minutes already spent on the
    /// first task are real and must not evaporate".
    ///
    /// The existing displacement case reads `displaced?.elapsed(at:)`, which
    /// recomputes from the segment and so passed throughout. What must be
    /// asserted is the **logged** figure.
    private static func checkSwitchingTasksLogsTheFirstOne(_ ok: inout Bool) {
        withScratchStore { store in
            var first = ShiftTask.fresh()
            first.title = "Rotate the prod bastion SSH keys"
            store.addTask(first)
            var second = ShiftTask.fresh()
            second.title = "Renew the wildcard cert"
            store.addTask(second)

            let timer = FocusTimerController(store: store)
            var clock = t0
            timer.clock = { clock }

            timer.start(task: first, minutes: 25)
            clock = at(1200)          // 20 real minutes on the first task
            timer.start(task: second, minutes: 25)

            let entries = store.recentActivity(reference: at(1200))
                .filter { $0.kind == FocusActivityLog.kind }
            check(entries.count == 1,
                  "switching tasks must log the displaced session - got \(entries.count) entries. "
                  + "The twenty minutes spent on the first task are simply gone otherwise (B9)", &ok)
            check(entries.first?.targetID == first.id,
                  "and the entry names the first task, got \(entries.first?.targetID ?? "nil")", &ok)
            check(entries.first?.durationSeconds == 1200,
                  "and carries the twenty minutes actually spent, got "
                  + "\(entries.first?.durationSeconds.map(String.init) ?? "nil")", &ok)

            // Discriminating power: the new session really is running and
            // really did start from zero, so the entry above is the old one.
            check(timer.session?.taskID == second.id,
                  "the second task is the one now running", &ok)
            check(timer.session?.elapsed(at: at(1200)) == 0,
                  "and it started from zero", &ok)
        }
    }

    /// **A session left running across a closed lid logged the whole sleep.**
    ///
    /// `stop()` banks `elapsed(at: now)`, which is wall-clock arithmetic from
    /// `segmentStartedAt` and has no idea the machine was not awake. A
    /// 25-minute Pomodoro started before the lid closed and stopped the next
    /// morning wrote sixteen hours into the task's permanent activity log and
    /// into the Weekly Review's "time on tasks" tile.
    ///
    /// `handleWillSleep`/`handleDidWake` are the real notification handlers -
    /// driving them directly is the only way to test this, since a suite
    /// cannot make the machine sleep, and `NSWorkspace` notifications cannot
    /// be synthesised meaningfully without one.
    private static func checkSleepEarnsNoFocusTime(_ ok: inout Bool) {
        withScratchStore { store in
            var task = ShiftTask.fresh()
            task.title = "Renew the wildcard cert"
            store.addTask(task)

            let timer = FocusTimerController(store: store)
            var clock = t0
            timer.clock = { clock }
            timer.start(task: task, minutes: 25)

            clock = at(300)                 // five minutes of real focus
            timer.handleWillSleep()
            check(timer.isPaused, "the session is paused while the machine sleeps", &ok)

            clock = at(300 + 8 * 3600)      // the lid was shut for eight hours
            check(timer.session?.elapsed(at: clock) == 300,
                  "a sleeping machine earns no focus time - got "
                  + "\(timer.session?.elapsed(at: clock) ?? -1)s across an eight-hour sleep (B9)", &ok)

            timer.handleDidWake()
            check(!timer.isPaused, "and waking resumes the session the captain left running", &ok)
            clock = at(300 + 8 * 3600 + 120)
            let logged = timer.stop()
            check(logged == 420,
                  "the logged total is the five minutes before the sleep plus the two after - "
                  + "got \(logged ?? -1)s (B9)", &ok)
        }
    }

    /// The other half of the sleep latch: a session the *captain* paused must
    /// still be paused when the machine wakes, or sleeping would silently
    /// restart their timer.
    private static func checkACaptainsPauseSurvivesASleep(_ ok: inout Bool) {
        withScratchStore { store in
            var task = ShiftTask.fresh()
            task.title = "Chase the vendor invoice"
            store.addTask(task)

            let timer = FocusTimerController(store: store)
            var clock = t0
            timer.clock = { clock }
            timer.start(task: task, minutes: 25)

            clock = at(300)
            timer.togglePauseByHand()
            check(timer.isPaused, "the captain paused it", &ok)

            clock = at(600)
            timer.handleWillSleep()
            clock = at(600 + 3600)
            timer.handleDidWake()
            check(timer.isPaused,
                  "a sleep must not resume a session the captain paused by hand (B9)", &ok)
            check(timer.session?.elapsed(at: clock) == 300,
                  "and no time was earned while it was paused, got "
                  + "\(timer.session?.elapsed(at: clock) ?? -1)", &ok)
        }
    }

    // MARK: The activity log

    private static func checkActivityLogWrite(_ ok: inout Bool) {
        withScratchStore { store in
            var task = ShiftTask.fresh()
            task.title = "Rotate the prod bastion SSH keys"
            store.addTask(task)

            let timer = FocusTimerController(store: store)
            var clock = t0
            timer.clock = { clock }
            timer.start(task: task, minutes: 25)
            clock = at(1500)
            let logged = timer.stop()

            check(logged == 1500, "a full session logs its 1500 seconds, got \(logged ?? -1)", &ok)

            let entries = store.recentActivity(reference: at(1500))
                .filter { $0.kind == FocusActivityLog.kind }
            check(entries.count == 1,
                  "exactly one focus entry should have been written, got \(entries.count)", &ok)
            guard let entry = entries.first else { return }
            check(entry.targetID == task.id,
                  "the entry names the task it was bound to", &ok)
            check(entry.durationSeconds == 1500,
                  "the duration rides its own field, got \(entry.durationSeconds.map(String.init) ?? "nil")", &ok)
            check(entry.summary.contains("25m") && entry.summary.contains(task.title),
                  "the summary names the duration and the task, got \(entry.summary)", &ok)
        }
    }

    private static func checkShortSessionIsNotLogged(_ ok: inout Bool) {
        withScratchStore { store in
            var task = ShiftTask.fresh()
            task.title = "Misclick"
            store.addTask(task)

            let timer = FocusTimerController(store: store)
            var clock = t0
            timer.clock = { clock }
            timer.start(task: task, minutes: 25)
            clock = at(12)                     // stopped 12 seconds in
            let logged = timer.stop()

            check(logged == nil, "a 12-second session logs nothing, got \(logged.map(String.init) ?? "nil")", &ok)
            let entries = store.recentActivity(reference: at(12))
                .filter { $0.kind == FocusActivityLog.kind }
            check(entries.isEmpty,
                  "and writes no activity entry at all, got \(entries.count)", &ok)

            // The floor's own discriminating power: one second over it does
            // get written, so the assertion above is about the threshold
            // rather than about the write path being broken.
            timer.start(task: task, minutes: 25)
            clock = at(12 + FocusTimerEngine.minimumLoggedSeconds)
            check(timer.stop() == FocusTimerEngine.minimumLoggedSeconds,
                  "a session exactly at the floor is logged", &ok)
        }
    }

    private static func checkPerDayAggregation(_ ok: inout Bool) {
        withScratchStore { store in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else {
                fail("could not build yesterday", &ok)
                return
            }

            store.logFocusSession(taskID: "a", taskTitle: "A", seconds: 1500, now: today)
            store.logFocusSession(taskID: "b", taskTitle: "B", seconds: 900, now: today)
            store.logFocusSession(taskID: "a", taskTitle: "A", seconds: 600, now: yesterday)

            let week = store.focusSecondsByDay(days: 7, reference: today)
            check(week.count == 7,
                  "a week is seven days including the empty ones, got \(week.count)", &ok)
            check(week.last?.seconds == 2400,
                  "today is the last entry and sums both sessions, got \(week.last?.seconds ?? -1)", &ok)
            check(week[week.count - 2].seconds == 600,
                  "yesterday carries its own 600, got \(week[week.count - 2].seconds)", &ok)
            // GL-14: a day with nothing logged is a measured zero, present
            // in the series - not a missing entry the chart would skip.
            check(week[0].seconds == 0,
                  "six days back is a real zero, got \(week[0].seconds)", &ok)
            check(week.map(\.day) == week.map(\.day).sorted(),
                  "the series is oldest-first", &ok)

            check(store.focusSecondsToday(reference: today) == 2400,
                  "today's total, got \(store.focusSecondsToday(reference: today))", &ok)
            check(store.focusTaskCountToday(reference: today) == 2,
                  "two distinct tasks were focused today, got "
                  + "\(store.focusTaskCountToday(reference: today))", &ok)

            // A second session on a task already counted must not make it
            // two tasks - the caption says "on N tasks", not "N sessions".
            store.logFocusSession(taskID: "a", taskTitle: "A", seconds: 300, now: today)
            check(store.focusTaskCountToday(reference: today) == 2,
                  "a repeat session on the same task does not raise the count, got "
                  + "\(store.focusTaskCountToday(reference: today))", &ok)
            check(store.focusSecondsToday(reference: today) == 2700,
                  "but its seconds do add, got \(store.focusSecondsToday(reference: today))", &ok)
        }
    }

    /// GL-01's shape for a hand-written serialiser: a new field has to
    /// survive the file, and an old file without it has to still decode.
    private static func checkActivityRoundTripKeepsTheDuration(_ ok: inout Bool) {
        let entry = ShiftActivityEntry(id: "e1", timestamp: ShiftStore.iso8601(t0),
                                       kind: FocusActivityLog.kind,
                                       summary: "Focused 25m on X", targetID: "t1",
                                       durationSeconds: 1500)
        guard let decoded = ShiftYaml.activity(from: ShiftYaml.toYaml(entry)) else {
            fail("a focus entry should round-trip through YAML", &ok)
            return
        }
        check(decoded.durationSeconds == 1500,
              "the duration survives the round trip, got "
              + "\(decoded.durationSeconds.map(String.init) ?? "nil")", &ok)
        check(decoded.targetID == "t1", "and so does the target id", &ok)

        // An entry written before F7 has no `duration_seconds` key at all.
        let legacy = ShiftActivityEntry(id: "e0", timestamp: ShiftStore.iso8601(t0),
                                        kind: "task_completed", summary: "Completed X",
                                        targetID: "t1")
        guard let legacyDecoded = ShiftYaml.activity(from: ShiftYaml.toYaml(legacy)) else {
            fail("a pre-F7 entry must still decode", &ok)
            return
        }
        check(legacyDecoded.durationSeconds == nil,
              "a missing duration decodes as nil rather than as zero", &ok)
        check(legacyDecoded.kind == "task_completed",
              "and the rest of the entry is untouched", &ok)
    }

    // MARK: Helpers

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-timer-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }
}

#endif
