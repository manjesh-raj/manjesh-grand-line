// Grand Line - native macOS app.
//
// "Has the captain actually been away for a while?" - the one shared answer,
// for E3 of `data/grand-line-e2e-audit/report.md`.
//
// E3 is the app's idle floor: six pollers, each individually defensible (most
// are documented decisions), all of which kept running at full cadence while
// the app was backgrounded *and* while it was locked. Nothing in that table is
// wrong on its own; together they are what the app costs when nobody is
// looking at it.
//
// Two things this deliberately is NOT:
//
//   - **Not `NSApp.isActive`.** Clicking into another app for ten seconds is
//     not "away", and a poller that changed cadence on every focus change
//     would thrash. `backgroundThreshold` (5 minutes of continuous
//     inactivity, the report's own suggestion) is what separates "the captain
//     is working across two apps" from "the app is parked".
//   - **Not a kill switch.** Every gated poller still runs, just less often -
//     and which pollers are gated at all is a per-poller judgement, made at
//     each call site rather than here. Three are deliberately left at full
//     cadence: `ShiftNotificationScheduler` (an in-memory scan whose whole job
//     is telling the captain something is due *while they are away* -
//     delaying an alarm to save nothing is the wrong trade), `ScheduleRunner`
//     (a cheap due-calc that *runs the captain's scheduled work*; slowing it
//     delays the automation itself), and `AppLockController` (the security
//     timer - slowing it delays the auto-lock).

import AppKit

/// Tracks how long this app has been continuously inactive, and tells
/// interested pollers when that crosses the "backgrounded" line.
final class AppActivityState {
    static let shared = AppActivityState()

    /// How long the app must be continuously inactive before a gated poller
    /// drops to its slow cadence. The report's own suggestion.
    static let backgroundThreshold: TimeInterval = 300

    private var lastActiveAt = Date()
    private var pendingCrossing: DispatchWorkItem?
    private var handlers: [UUID: (Bool) -> Void] = [:]
    private var started = false

    private init() {}

    /// `true` once the app has been inactive for at least
    /// `backgroundThreshold`. Always `false` while the app is frontmost.
    var isBackgrounded: Bool {
        if NSApplication.shared.isActive { return false }
        return Date().timeIntervalSince(lastActiveAt) >= Self.backgroundThreshold
    }

    /// Registered once at launch from `main.swift`. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.becameActive() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resignedActive() }
        if NSApplication.shared.isActive { lastActiveAt = Date() } else { resignedActive() }
    }

    /// Notified with the new value whenever the backgrounded state changes -
    /// for a poller that wants to re-arm rather than skip ticks (nothing does
    /// today; `ShiftGitSync` pauses by checking `isBackgrounded` on its own
    /// tick, which cannot get stuck in the paused state the way a cancelled
    /// timer could).
    @discardableResult
    func observe(_ handler: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func unobserve(_ token: UUID) { handlers.removeValue(forKey: token) }

    private func becameActive() {
        pendingCrossing?.cancel()
        pendingCrossing = nil
        // The "came back" callback was unreachable: this runs from
        // `didBecomeActive`, where `NSApplication.shared.isActive` is already
        // `true`, so `isBackgrounded` short-circuits to `false` on its first
        // line and `notify(false)` never fired. Harmless today (nothing calls
        // `observe`, and the three pollers read `isBackgrounded` directly), but
        // the doc above advertises the callback and the first adopter would get
        // "went away" with no matching "came back".
        //
        // Computed from elapsed time *before* `lastActiveAt` is reset, which is
        // the only reading that still means anything once the app is active.
        let wasBackgrounded = Date().timeIntervalSince(lastActiveAt) >= Self.backgroundThreshold
        lastActiveAt = Date()
        if wasBackgrounded { notify(false) }
    }

    private func resignedActive() {
        // The crossing is a real event a poller may want, and it happens
        // `backgroundThreshold` *after* the app went away, not at that moment.
        pendingCrossing?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isBackgrounded else { return }
            self.notify(true)
        }
        pendingCrossing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundThreshold + 1, execute: item)
    }

    private func notify(_ backgrounded: Bool) {
        for handler in handlers.values { handler(backgrounded) }
    }

    #if FM_SELFTESTS
    /// Pretends the app has been inactive since `date`, so a suite can reach
    /// the backgrounded branch without waiting five real minutes. `nil`
    /// restores the real reading.
    static var backgroundedOverrideForTests: Bool?

    var isBackgroundedForTests: Bool {
        Self.backgroundedOverrideForTests ?? isBackgrounded
    }
    #endif
}

/// A poller's own "should this tick do work?" decision while the app is
/// backgrounded.
///
/// Skipping ticks rather than re-scheduling the timer is deliberate: one timer
/// that always runs is self-correcting, whereas a cancelled/re-armed timer is
/// a state machine that can get stuck in the slow (or stopped) state - the
/// failure mode this app has already been bitten by twice (a stuck poll latch,
/// a stuck backend resolution). A no-op 30-second tick is ~0.03 wake-ups a
/// second; the cost E3 is about is the subprocess fan-out the tick *guards*,
/// not the tick.
struct BackgroundedPollGate {
    /// How many backgrounded ticks to skip for each one that runs - 3 skips
    /// turns a 30s cadence into 120s, the report's own suggested number.
    let skipsPerRun: Int
    private var skipped = 0

    init(skipsPerRun: Int) {
        self.skipsPerRun = max(0, skipsPerRun)
    }

    /// `true` when this tick should do its real work.
    mutating func shouldRun(backgrounded: Bool) -> Bool {
        guard backgrounded, skipsPerRun > 0 else {
            skipped = 0
            return true
        }
        if skipped >= skipsPerRun {
            skipped = 0
            return true
        }
        skipped += 1
        return false
    }
}

/// PF14 of the 2026-09-25 full review: the fleet poller spawns one
/// `fm-crew-state.sh` per tracked task every 30 seconds, and that script is
/// genuinely expensive - the review measured 423 worker samples in five
/// seconds **with a single task**, because it shells out to `no-mistakes`,
/// `git` and the forge on its own account.
///
/// **The review's proposed fix - batch every task into one call - is not
/// available from this repository, and would not help if it were.** The
/// script takes exactly one id and exits 2 without one, and it lives in the
/// captain's firstmate home rather than in this tree. Wrapping N invocations
/// in one `bash -c` would save N-1 pipe setups and give up the bounded
/// concurrency `parseTasks` already has; the cost the review measured is the
/// script's own work, once per task, which a batch does not change.
///
/// So the lever that is actually available is **how often** the fleet is
/// asked, not how many processes carry the asking. A fleet whose every task
/// reported the same state as last time is a fleet nothing is happening on,
/// and that is the common case for most of a day.
///
/// The gate backs the cadence off after a run of identical sweeps and snaps
/// straight back to every tick the moment anything differs. Nothing is ever
/// skipped permanently, and the worst case is a transition noticed one
/// backed-off interval late - the same trade, and the same "at worst two
/// minutes" number, `BackgroundedPollGate` above already makes for a
/// backgrounded app.
struct QuietFleetPollGate {
    /// How many identical sweeps before the cadence backs off at all.
    let quietSweepsBeforeBackoff: Int
    /// How many ticks to skip for each one that runs, once quiet.
    let skipsPerRun: Int

    private var quietSweeps = 0
    private var skipped = 0

    init(quietSweepsBeforeBackoff: Int, skipsPerRun: Int) {
        self.quietSweepsBeforeBackoff = max(0, quietSweepsBeforeBackoff)
        self.skipsPerRun = max(0, skipsPerRun)
    }

    /// `true` when this tick should do its real work.
    mutating func shouldRun() -> Bool {
        guard quietSweeps >= quietSweepsBeforeBackoff, skipsPerRun > 0 else {
            skipped = 0
            return true
        }
        if skipped >= skipsPerRun {
            skipped = 0
            return true
        }
        skipped += 1
        return false
    }

    /// Told after every sweep that actually ran, with whether the fleet looked
    /// any different from the sweep before it.
    mutating func noteSweep(changed: Bool) {
        if changed {
            quietSweeps = 0
            skipped = 0
        } else {
            quietSweeps += 1
        }
    }

    #if FM_SELFTESTS
    var debugQuietSweeps: Int { quietSweeps }
    #endif
}
