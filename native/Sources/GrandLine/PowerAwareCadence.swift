// Grand Line - native macOS app.
//
// R5 energy fix 5 (`data/grand-line-full-app-review/report.md`, section 2.6).
// The two periodic jobs that reach the network and spawn the most children,
// the background signals sweep (every 15 minutes) and the Tasks git pull
// (every 5), ran at the same cadence on battery as on AC. On battery each run
// is a radio wake-up plus a burst of child processes, which Activity Monitor
// charges to this app, and what they refresh is FYI: tool-update and drift
// counts, and a prefetch of another machine's task edits.
//
// So on battery, or with Low Power Mode on, each job stretches its cadence:
// the sweep to 60 minutes and the pull to 30. The timer itself keeps its
// period; a tick simply does nothing until the stretched interval has passed
// since the last run. That keeps the change in one place per job, and the
// moment the Mac is plugged in the very next tick runs as before. A manual
// "Check now" or Refresh never goes through this, so it always runs.

import Foundation
import IOKit.ps

enum PowerSource {

    /// Whether background work should slow down: the Mac is running on
    /// battery, or the captain turned on Low Power Mode (which macOS also
    /// offers on AC).
    static func prefersReducedBackgroundWork() -> Bool {
        #if FM_SELFTESTS
        if let override = reducedOverrideForTests { return override }
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled || isOnBattery()
    }

    /// `IOPSGetProvidingPowerSourceType` names what is powering the Mac right
    /// now. A desktop with no battery answers AC, and a read that fails is
    /// treated as AC, which is the cadence the app always had.
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    #if FM_SELFTESTS
    /// A suite pins the answer rather than inheriting the host's power state.
    static var reducedOverrideForTests: Bool?
    #endif
}

/// One periodic job's cadence on normal and reduced power. Pure, so a suite can
/// drive hours of ticks in a loop.
struct PowerAwareCadence {
    /// The timer's own period, which is the cadence on normal power.
    let interval: TimeInterval
    /// The cadence on battery or in Low Power Mode.
    let reducedInterval: TimeInterval
    /// When the job last did its work, from a tick or from a manual run.
    private(set) var lastRunAt: Date?

    init(interval: TimeInterval, reducedInterval: TimeInterval) {
        self.interval = interval
        self.reducedInterval = reducedInterval
    }

    /// Whether the tick at `now` should do the work. On normal power every
    /// tick does. On reduced power a tick does only once `reducedInterval` has
    /// passed since the last run, less half a period, so a timer that fires a
    /// few seconds early or late still lands on the stretched cadence rather
    /// than one tick after it.
    func isDue(now: Date, reduced: Bool) -> Bool {
        guard reduced, let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= reducedInterval - interval / 2
    }

    /// Record a run, whatever started it.
    mutating func noteRun(at date: Date) {
        lastRunAt = date
    }
}
