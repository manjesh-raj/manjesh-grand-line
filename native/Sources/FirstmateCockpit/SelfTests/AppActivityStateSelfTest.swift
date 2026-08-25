// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for E3's backgrounded tier
// (`data/grand-line-e2e-audit/report.md`). Run with:
//
//   swift build && FM_RUN_APP_ACTIVITY_STATE_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Two halves, because the failure modes are opposite:
//
//   1. `BackgroundedPollGate`'s arithmetic - a gate that skips too much turns
//      a notifier into a no-op, and one that skips nothing is the bug this
//      fixes. Pure logic, so it is checked rather than described.
//   2. A source guard that the three pollers E3 gates still consult it, and -
//      just as important - that the three deliberately *left alone* still do
//      not. Slowing the due-item alarm, the schedule runner, or the auto-lock
//      to save nothing would be a regression that no timing test would catch.

#if FM_SELFTESTS

import AppKit

enum AppActivityStateSelfTest {

    static func run() -> Bool {
        var ok = true
        checkGateArithmetic(&ok)
        checkForegroundIsNeverGated(&ok)
        checkThresholdIsNotTrigger(&ok)
        checkGatedPollers(&ok)
        checkUngatedPollersStayUngated(&ok)
        print(ok ? "AppActivityStateSelfTest: all checks passed"
                 : "AppActivityStateSelfTest: FAILED")
        return ok
    }

    private static func fail(_ ok: inout Bool, _ message: String) {
        print("  FAIL: \(message)")
        ok = false
    }

    /// Runs `ticks` ticks through a gate and reports how many did real work.
    private static func runs(skipsPerRun: Int, ticks: Int, backgrounded: Bool) -> Int {
        var gate = BackgroundedPollGate(skipsPerRun: skipsPerRun)
        var count = 0
        for _ in 0..<ticks where gate.shouldRun(backgrounded: backgrounded) { count += 1 }
        return count
    }

    private static func checkGateArithmetic(_ ok: inout Bool) {
        print("AppActivityStateSelfTest: a gated poller runs at the slow cadence, not never")
        // FleetNotifier's shape: 30s ticks, 3 skips -> one real pass per 120s.
        let fleet = runs(skipsPerRun: 3, ticks: 12, backgrounded: true)
        if fleet != 3 {
            fail(&ok, "3-skip gate did \(fleet) passes in 12 ticks, expected 3 (a 30s timer at a 120s cadence)")
        }
        // BackgroundSignalsPoller's shape: 15min ticks, 1 skip -> 30min.
        let signals = runs(skipsPerRun: 1, ticks: 10, backgrounded: true)
        if signals != 5 {
            fail(&ok, "1-skip gate did \(signals) passes in 10 ticks, expected 5")
        }
        // The failure that matters most: it must never stop entirely.
        if fleet == 0 || signals == 0 {
            fail(&ok, "a gated poller stopped completely - a decision parked while the captain is away would never surface")
        }
        if ok { print("  3-skip -> 3/12 ticks, 1-skip -> 5/10 ticks, neither ever zero") }
    }

    private static func checkForegroundIsNeverGated(_ ok: inout Bool) {
        print("AppActivityStateSelfTest: nothing is skipped while the captain is here")
        let foreground = runs(skipsPerRun: 3, ticks: 12, backgrounded: false)
        if foreground != 12 {
            fail(&ok, "a foreground poller ran \(foreground)/12 ticks - the gate is leaking into normal use")
        }
        // Coming back must take effect on the very next tick, not after the
        // skip counter happens to roll over.
        var gate = BackgroundedPollGate(skipsPerRun: 3)
        _ = gate.shouldRun(backgrounded: true)   // consumes a skip
        _ = gate.shouldRun(backgrounded: true)
        if !gate.shouldRun(backgrounded: false) {
            fail(&ok, "the first tick after the captain came back was still skipped")
        }
        if ok { print("  12/12 in the foreground, and returning takes effect on the next tick") }
    }

    private static func checkThresholdIsNotTrigger(_ ok: inout Bool) {
        print("AppActivityStateSelfTest: \"backgrounded\" means away for a while, not merely not-frontmost")
        if AppActivityState.backgroundThreshold < 60 {
            fail(&ok, "backgroundThreshold is \(AppActivityState.backgroundThreshold)s - clicking into another app for a moment would re-cadence every poller")
        }
        if NSApplication.shared.isActive, AppActivityState.shared.isBackgrounded {
            fail(&ok, "the frontmost app reported itself as backgrounded")
        }
        if ok { print("  threshold \(Int(AppActivityState.backgroundThreshold))s, app-active=\(NSApplication.shared.isActive) -> backgrounded=\(AppActivityState.shared.isBackgrounded)") }
    }

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private static func checkGatedPollers(_ ok: inout Bool) {
        print("AppActivityStateSelfTest: the three pollers E3 gates still consult the gate")
        // The needle carries the *argument*, not just the call: a gate handed
        // a hardcoded `true` compiles, reads plausibly, and permanently
        // slows a poller the captain is watching.
        for (file, needle) in [("FleetNotifier.swift", "backgroundedGate.shouldRun(backgrounded: AppActivityState.shared.isBackgrounded)"),
                               ("BackgroundSignalsPoller.swift", "backgroundedGate.shouldRun(backgrounded: AppActivityState.shared.isBackgrounded)"),
                               ("ShiftGitSync.swift", "!AppActivityState.shared.isBackgrounded")] {
            guard let text = source(file) else {
                print("  SKIP: app sources not reachable from here")
                return
            }
            if !text.contains(needle) {
                fail(&ok, "\(file) no longer consults the backgrounded tier - E3's idle floor is back")
            }
        }
        if ok { print("  FleetNotifier, BackgroundSignalsPoller, ShiftGitSync all gated") }
    }

    private static func checkUngatedPollersStayUngated(_ ok: inout Bool) {
        print("AppActivityStateSelfTest: the three left at full cadence are still at full cadence")
        // Each of these is a deliberate exception with a stated reason - see
        // `AppActivityState.swift`'s header. Gating one later would be a
        // product decision, not a tidy-up, so it should have to argue with a
        // failing test first.
        for file in ["ShiftNotifications.swift", "ScheduleRunner.swift", "AppLock.swift"] {
            guard let text = source(file) else {
                print("  SKIP: app sources not reachable from here")
                return
            }
            if text.contains("AppActivityState") || text.contains("BackgroundedPollGate") {
                fail(&ok, "\(file) started gating itself - the due-item alarm, the schedule runner and the auto-lock are the three that must not slow down while the captain is away")
            }
        }
        if ok { print("  ShiftNotifications, ScheduleRunner, AppLock untouched") }
    }
}

#endif
