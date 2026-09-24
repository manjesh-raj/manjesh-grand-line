// Grand Line - native macOS app.
//
// F7 of full review #3 §8: a Pomodoro-style focus timer bound to one Shift
// task. See `docs/history/36-focus-timer.md` for the build's own account.
//
// This file is the whole of the feature's *logic*, deliberately split from
// every view that renders it:
//
//   - `FocusSession` is the running state - which task, how long was asked
//     for, how much of it has actually been spent focusing.
//   - `FocusTimerEngine` is a pure state machine over that. It owns no
//     `Timer`, reads no clock of its own and touches no store: every method
//     takes the `now` it should reason from. That is what lets the whole
//     start/pause/resume/extend/finish matrix be asserted in CI's *blocking*
//     lane (`FocusTimerSelfTest`) instead of only in a windowed one.
//   - `FocusTimerController` is the app-facing half: it owns the one real
//     repeating `Timer`, hands the engine a real `Date`, notifies observers
//     and writes the finished session into Shift's own activity log.
//
// **Why elapsed time is accumulated rather than derived from `startedAt`.**
// A session can be paused, and a paused session must not keep earning
// minutes the captain did not spend. Deriving `now - startedAt` would credit
// the whole lunch break to the task. So the engine banks `accumulated`
// seconds at every pause and measures only the *current* run segment from
// `segmentStartedAt` - which also makes a wall-clock jump (a sleep, a
// timezone change) cost at most the one segment it happened in rather than
// the entire session.
//
// **Why the logged duration is focused seconds, not planned minutes.**
// "Start 25 min" is a request, not a record. A session stopped at 6 minutes
// logs 6 minutes; one extended twice and run to the end logs 35. The Weekly
// Review tile is a claim about time actually spent, and a tile that reports
// what was *intended* is GL-14's "unknown rendered as a number" in a
// different costume.

import Foundation

// MARK: - The session

/// One focus run: which task, how much was asked for, how much has been
/// spent. Value type on purpose - the engine replaces it wholesale rather
/// than mutating shared state behind an observer's back.
struct FocusSession: Equatable {
    /// The `ShiftTask.id` this session is bound to.
    var taskID: String
    /// The task's title *as it was when the session started*, kept so the
    /// bar chip and the activity summary can name the task without the
    /// timer holding a reference to the store (and so a session survives the
    /// task being renamed or completed mid-run).
    var taskTitle: String
    /// What the captain asked for, in seconds. Grows with `extend`.
    var plannedSeconds: Int
    /// Focused seconds banked by every *completed* run segment. The live
    /// segment is not in here - see `elapsed(at:)`.
    var accumulatedSeconds: Int
    /// When the current run segment began, or `nil` while paused.
    var segmentStartedAt: Date?
    /// When the session first started. Only ever used for the log line's own
    /// timestamp; never for arithmetic - see the file header.
    var startedAt: Date

    var isPaused: Bool { segmentStartedAt == nil }

    /// Focused seconds as of `now`, banked plus the live segment.
    ///
    /// Clamped at zero because a backwards clock adjustment can otherwise
    /// make the live segment negative, and a negative elapsed reads as a
    /// *growing* remaining time on the chip.
    func elapsed(at now: Date) -> Int {
        guard let segmentStartedAt else { return accumulatedSeconds }
        let live = Int(now.timeIntervalSince(segmentStartedAt).rounded(.down))
        return accumulatedSeconds + max(0, live)
    }

    /// Seconds still to go, floored at zero.
    func remaining(at now: Date) -> Int { max(0, plannedSeconds - elapsed(at: now)) }

    /// How much of the planned time has been served, in `0...1` - what
    /// `HelmRingGauge` draws.
    ///
    /// A zero (or negative) plan would divide by zero; it reads as complete
    /// rather than as empty, since there is no time left to serve.
    func fraction(at now: Date) -> Double {
        guard plannedSeconds > 0 else { return 1 }
        return min(1, max(0, Double(elapsed(at: now)) / Double(plannedSeconds)))
    }

    func isComplete(at now: Date) -> Bool { remaining(at: now) == 0 }
}

// MARK: - Formatting

/// The feature's two duration formats, in one place because three surfaces
/// render them (the chip, the ring, the Weekly Review tile) and a chip
/// reading `17:24` beside a tile reading `17m 24s` would read as two
/// different numbers.
enum FocusTimerFormat {

    /// `mm:ss`, for a countdown. Hours roll into the minutes column
    /// (`65:00`) rather than growing an `h:mm:ss` field the chip has no room
    /// for - a focus session long enough for that is not a Pomodoro.
    static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `2h 05m` / `48m` / `0m`, for a total. Seconds are deliberately absent:
    /// a day's total is not a stopwatch reading, and rounding down is the
    /// honest direction for a claim about time spent.
    static func total(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return "\(minutes)m"
    }
}

// MARK: - The state machine

/// The pure half. Every method takes its own `now`; nothing here reads a
/// clock, starts a timer or writes a file.
struct FocusTimerEngine {

    /// The default Pomodoro. The captain can pick another before starting
    /// (`durationChoices`) and extend a running one (`extensionMinutes`),
    /// but the one-click action on a task row is this.
    static let defaultMinutes = 25

    /// What the "Focus for…" submenu offers. A Pomodoro (25), its short and
    /// long variants, and the two round numbers a captain reaches for when
    /// the task is either a quick sweep or a deep block.
    static let durationChoices = [10, 15, 25, 45, 50]

    /// What one "+5 min" press adds.
    static let extensionMinutes = 5

    /// A session shorter than this is not logged.
    ///
    /// Stopping a timer ten seconds after starting it is a misclick, and
    /// writing `Focused 0m` into a task's permanent activity log turns the
    /// log into a record of the captain's mouse rather than of their work.
    /// The floor is one whole minute because that is the smallest thing the
    /// Weekly Review tile can display - anything under it would be counted
    /// and then rendered as nothing, which is worse than not counting it.
    static let minimumLoggedSeconds = 60

    /// `nil` when no session is running.
    private(set) var session: FocusSession?

    var isRunning: Bool { session != nil }

    /// Begin a session on `taskID`, replacing any running one.
    ///
    /// Returns the session the new one displaced, so the caller can log it
    /// before it is gone. Starting a second timer is not an error the
    /// captain should have to dismiss - one focus at a time is the whole
    /// point - but the minutes already spent on the first task are real and
    /// must not evaporate.
    @discardableResult
    mutating func start(taskID: String, title: String, minutes: Int, now: Date) -> FocusSession? {
        let displaced = session
        session = FocusSession(
            taskID: taskID,
            taskTitle: title,
            plannedSeconds: max(1, minutes) * 60,
            accumulatedSeconds: 0,
            segmentStartedAt: now,
            startedAt: now
        )
        return displaced
    }

    /// Bank the live segment and stop counting. A no-op on an already-paused
    /// or absent session.
    mutating func pause(now: Date) {
        guard var current = session, !current.isPaused else { return }
        current.accumulatedSeconds = current.elapsed(at: now)
        current.segmentStartedAt = nil
        session = current
    }

    /// Start a new run segment. A no-op on a running or absent session.
    mutating func resume(now: Date) {
        guard var current = session, current.isPaused else { return }
        current.segmentStartedAt = now
        session = current
    }

    /// Add `minutes` to what was asked for. Used by the "+5 min" button, and
    /// legitimate on a session that has already run out - which is exactly
    /// when a captain reaches for it.
    mutating func extend(byMinutes minutes: Int = FocusTimerEngine.extensionMinutes) {
        guard var current = session else { return }
        current.plannedSeconds += max(0, minutes) * 60
        session = current
    }

    /// End the session and hand back what was spent on it.
    ///
    /// Returns `nil` when there was nothing running. The returned session's
    /// `accumulatedSeconds` is the final figure (the live segment is banked
    /// first), so a caller never has to know whether it ended paused.
    @discardableResult
    mutating func stop(now: Date) -> FocusSession? {
        guard var current = session else { return nil }
        current.accumulatedSeconds = current.elapsed(at: now)
        current.segmentStartedAt = nil
        session = nil
        return current
    }
}

// MARK: - Activity-log wording

/// How a finished session is written into Shift's activity log.
///
/// Its own type rather than a string built at the call site, because the
/// same two values are read back by `ShiftStore.focusSeconds(...)` to build
/// the Weekly Review tile - and the summary line is what the Overview log
/// feed renders. One place decides both.
enum FocusActivityLog {

    /// The `ShiftActivityEntry.kind` every focus session is filed under.
    /// Read back by `ShiftStore.focusSecondsByDay`.
    static let kind = "task_focus_logged"

    /// The human line. Names the task, because the log feed shows the
    /// summary without the task beside it.
    static func summary(seconds: Int, taskTitle: String) -> String {
        "Focused \(FocusTimerFormat.total(seconds)) on \(taskTitle)"
    }
}

// MARK: - The app-facing controller

/// Owns the one real `Timer`, the engine, and the write into the store.
///
/// One instance per app, built by `AppShellController` from the shared
/// `ShiftStore` and handed to both the bar chip and the Tasks page - never a
/// second instance, for the same reason GL-23 gives for a caching store: two
/// timers would each think they were the only one running.
final class FocusTimerController {

    /// How often the chip and the ring re-read the clock.
    ///
    /// One second, not less: everything on screen is rendered to the second,
    /// so a faster tick would repaint identical text. Everything *derived*
    /// still comes from a real `Date` rather than from a tick count, so a
    /// dropped or coalesced tick costs a late repaint and never a wrong
    /// number.
    private static let tickInterval: TimeInterval = 1

    /// The bell entry a finished session files. One stable id, so a second
    /// completed session replaces the first rather than stacking - and so
    /// `start` can clear it.
    private static let completionNotificationID = "focus.completed"

    private let store: ShiftStore
    private var engine = FocusTimerEngine()
    private var timer: Timer?
    private var observers: [(UUID, () -> Void)] = []

    /// Swappable so a self-test can drive the whole matrix without waiting
    /// on wall-clock seconds.
    var clock: () -> Date = { Date() }

    init(store: ShiftStore) {
        self.store = store
    }

    deinit { timer?.invalidate() }

    // MARK: Reading

    var session: FocusSession? { engine.session }
    var isRunning: Bool { engine.isRunning }

    /// The chip's own text: `17:24` while running, `nil` when nothing is.
    var countdownText: String? {
        guard let session else { return nil }
        return FocusTimerFormat.countdown(session.remaining(at: clock()))
    }

    /// How much of the session has been served, in `0...1`, or `nil` when
    /// nothing is running.
    ///
    /// Every rendered surface reads its numbers from here rather than
    /// calling `session.fraction(at: Date())` for itself. That is not
    /// tidiness: a view that reaches for a real `Date()` is reading a
    /// *different clock* from the one the controller is counting on, which
    /// makes the whole feature untestable against a fabricated instant and
    /// would leave the chip and the ring free to disagree by a tick.
    var fraction: Double? {
        guard let session else { return nil }
        return session.fraction(at: clock())
    }

    /// Whether the running session is paused. `false` when none is.
    var isPaused: Bool { session?.isPaused ?? false }

    /// The full plan, formatted - the popover's "of 25:00" line.
    var plannedText: String? {
        guard let session else { return nil }
        return FocusTimerFormat.countdown(session.plannedSeconds)
    }

    /// GL-24's shape: an observer repaints, it never fetches. Fires on every
    /// tick and on every state change.
    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers.append((token, handler))
        return token
    }

    func unobserve(_ token: UUID) {
        observers.removeAll { $0.0 == token }
    }

    // MARK: Driving

    /// Start (or restart) a session on a task.
    ///
    /// A session already running on a *different* task is stopped and logged
    /// first - see `FocusTimerEngine.start`. Re-starting the task that is
    /// already focused restarts its clock, which is what "Start 25 min"
    /// means when the captain clicks it again.
    func start(task: ShiftTask, minutes: Int = FocusTimerEngine.defaultMinutes) {
        // GL-30's other half: a `lasting` report is paired with a `clear` on
        // the path that resolves it. "Your last session finished" stops
        // being worth the captain's bell the moment they start the next one.
        Feedback.clear(id: Self.completionNotificationID)
        let displaced = engine.start(taskID: task.id, title: task.title,
                                     minutes: minutes, now: clock())
        if let displaced { logIfWorthLogging(displaced) }
        startTicking()
        notify()
    }

    func pause() {
        engine.pause(now: clock())
        stopTicking()
        notify()
    }

    func resume() {
        engine.resume(now: clock())
        startTicking()
        notify()
    }

    func togglePause() {
        guard let session else { return }
        if session.isPaused { resume() } else { pause() }
    }

    func extend(byMinutes minutes: Int = FocusTimerEngine.extensionMinutes) {
        engine.extend(byMinutes: minutes)
        notify()
    }

    /// Finish the session and write it to the task's activity log.
    ///
    /// Returns the seconds logged, or `nil` when there was nothing running
    /// or the session was too short to record
    /// (`FocusTimerEngine.minimumLoggedSeconds`). The caller uses that to
    /// decide what to say - "Logged 25m" and "Stopped" are different events.
    @discardableResult
    func stop() -> Int? {
        guard let finished = engine.stop(now: clock()) else { return nil }
        stopTicking()
        notify()
        return logIfWorthLogging(finished)
    }

    /// Whether the session that is running is bound to this task.
    func isFocusing(taskID: String) -> Bool { engine.session?.taskID == taskID }

    // MARK: Ticking

    private func startTicking() {
        stopTicking()
        // `.common` so the chip keeps counting while a menu is open or the
        // window is being dragged - a timer that freezes during a menu is
        // the one that is wrong when the menu closes.
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Audit 3.4: a zero-tolerance repeating timer is a hard wake-up the
        // kernel cannot batch. A quarter-second of slack costs nothing here,
        // because every number on screen is re-derived from a real `Date` at
        // paint time rather than counted in ticks.
        timer.tolerance = Self.tickInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let session = engine.session else { stopTicking(); return }
        let wasComplete = session.isComplete(at: clock())
        notify()
        // Completion ends the session on its own: the captain asked for 25
        // minutes and got them, and a countdown that silently runs past zero
        // into negative territory logs time nobody was focusing.
        if wasComplete { finishOnCompletion(session) }
    }

    /// The zero-crossing. Split out from `tick` so a self-test can reach it
    /// without a run loop.
    func completeIfElapsed() {
        guard let session = engine.session, session.isComplete(at: clock()) else { return }
        finishOnCompletion(session)
    }

    private func finishOnCompletion(_ session: FocusSession) {
        let logged = stop()
        // GL-30: a finished Pomodoro is still true after a toast fades - the
        // captain may well have been in another app for the last ten minutes
        // of it, which is the entire point of a focus timer. So it goes to
        // the bell as well, with a stable id so a second completed session
        // replaces the first rather than stacking.
        Feedback.report(
            "Focus session finished \u{00B7} \(session.taskTitle)",
            kind: .done,
            persistence: .lasting,
            in: nil,
            id: Self.completionNotificationID,
            detail: logged.map { "\(FocusTimerFormat.total($0)) logged to the task's activity" }
                ?? "Nothing was logged - the session was under a minute"
        )
    }

    // MARK: Writing

    /// Writes the session to the task's activity log, unless it was too
    /// short to mean anything. Returns the seconds written.
    @discardableResult
    private func logIfWorthLogging(_ session: FocusSession) -> Int? {
        let seconds = session.accumulatedSeconds
        guard seconds >= FocusTimerEngine.minimumLoggedSeconds else { return nil }
        store.logFocusSession(taskID: session.taskID, taskTitle: session.taskTitle,
                              seconds: seconds, now: clock())
        return seconds
    }

    private func notify() {
        for (_, handler) in observers { handler() }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Drives one tick without a run loop, so a windowed suite can advance
    /// the chip deterministically.
    func debugTick() { tick() }
    #endif
}
