// Manjesh Grand Line - native macOS app.
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
        let wasBackgrounded = isBackgrounded
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
