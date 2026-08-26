// Manjesh Grand Line - native macOS app.
//
// A scout investigation (`data/grand-line-energy-regression-scout/report.md`,
// section 2) traced "clicking through several pages in one session feels
// disproportionately expensive" to a real, pre-existing gap PR #291's own
// P2/P3/P4 pass never touched: `DependencyCatalog.items` (`UpdatesData.swift`)
// lists 13 real, subprocess-backed checks, and `UpdatesController`,
// `BootstrapController` and `AutomationController` each independently run the
// entire sweep on their own first mount - three real, uncached sweeps of the
// identical 13 tools for one captain visiting Updates, then Bootstrap, then
// Automation in one sitting. This file is the shared cache those three pages
// now read from instead.
//
// Keyed by `DependencyItem.id` (the same identity `UpdatesSource.check`/
// `.update` already dispatch on) rather than by controller or page, since the
// whole point is that the same tool's check means the same thing regardless
// of which page asked for it.
//
// `defaultTTL` matches `BackgroundSignalsPoller.pollInterval` (15 minutes) -
// this codebase's own existing answer to "how fresh does a tool-update/drift
// signal need to be" (see that poller and `HealthService.backgroundSignals`'s
// own description). Comfortably longer than a captain paging through
// Updates/Bootstrap/Automation in one sitting (which is what this cache
// exists to stop costing three real sweeps), and short enough that a tool
// installed or updated outside the app - a captain running `brew upgrade`
// themselves in a terminal - is picked up within one session, no relaunch
// needed.
//
// Every explicit "Check"/"Refresh"/"Re-check now" affordance on the three
// pages passes `forceRefresh: true`, which always runs the real
// subprocess-backed check and refreshes the shared entry (so the other two
// pages benefit from it too) rather than ever serving a stale hit back to a
// captain who explicitly asked "is this still true right now?".
//
// Thread-safety follows this file's own `ServiceHealthRegistry` convention
// (`ServiceHealth.swift`): an `NSLock`-guarded dictionary, since the three
// controllers each dispatch their checks to `DispatchQueue.global` themselves
// (unchanged by this file) and can genuinely race for the same item - e.g.
// Updates and Bootstrap both mounting within the same few hundred
// milliseconds of app launch. A per-item `DispatchGroup` coalesces that race
// (see `inFlight`'s own doc comment for why a group rather than a semaphore):
// only the first caller for a not-yet-fresh item actually runs the subprocess
// sweep, and every other concurrent caller for that same item waits on the
// winner's result instead of starting a second one - which is what makes
// "the underlying sweep runs once, not three times" true even under real
// concurrent first-mount timing, not just under sequential navigation.

import Foundation

/// Drop-in shared cache for `UpdatesSource.check(_:)` - `check(_:forceRefresh:)`
/// has the exact same synchronous, blocking signature as the function it
/// replaces (plus the two cache-control parameters), so every existing
/// caller's own background-queue dispatch is unchanged; only the direct
/// `UpdatesSource.check($0)` call inside that dispatch becomes
/// `DependencyCheckCache.shared.check($0, forceRefresh: ...)`.
///
/// `init()` is not private - a self-test constructs its own disposable
/// instance to exercise the caching/coalescing logic in isolation, rather
/// than reaching into `.shared`'s persistent state and needing a reset step
/// between cases.
final class DependencyCheckCache {

    static let shared = DependencyCheckCache()

    static let defaultTTL: TimeInterval = 15 * 60

    private struct Entry {
        let outcome: CheckOutcome
        let checkedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// One real check in flight per item id at a time. A second (or third,
    /// or fifth) caller racing for the same item waits on this group rather
    /// than starting a second subprocess sweep, then loops back around to
    /// either read the entry the winner just wrote (the common case) or - if
    /// this call was itself a forced refresh that arrived while someone
    /// else's *unforced* check was already running - become the new runner
    /// itself.
    ///
    /// A `DispatchGroup` rather than a `DispatchSemaphore`: exactly one
    /// caller ever calls `enter()`/`leave()` (the winner, once), and any
    /// number of other callers may safely call `wait()` on the same group at
    /// once - every one of them is released together when `leave()` matches
    /// `enter()`. A semaphore's `signal()` only wakes a single blocked
    /// `wait()` per call, so with N concurrent waiters only one would ever
    /// have woken up and the rest would block forever - confirmed live via
    /// this file's own self-test hanging under exactly that shape before this
    /// fix.
    private var inFlight: [String: DispatchGroup] = [:]

    init() {}

    /// A cached, still-fresh outcome for `item`, with no subprocess work at
    /// all. `nil` when there is no entry yet or it has aged past `maxAge`.
    /// Not used by any controller today (they all go through `check(_:)`,
    /// which already serves a fresh hit for free) - kept as the read-only
    /// half of this type's contract, and useful for a future caller that
    /// only wants to know "do we already have a fresh answer" without
    /// risking triggering a real check.
    func cachedOutcome(for item: DependencyItem, maxAge: TimeInterval = defaultTTL) -> CheckOutcome? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[item.id], Date().timeIntervalSince(entry.checkedAt) < maxAge else { return nil }
        return entry.outcome
    }

    /// Synchronous and blocking, exactly like the `UpdatesSource.check(_:)`
    /// call it replaces - call it from a background queue, same as every
    /// existing caller already does.
    ///
    /// `forceRefresh: false` (every page's automatic first-mount sweep)
    /// returns a still-fresh cached outcome when one exists, from *any*
    /// page's earlier check of the same item - this is the whole fix.
    /// `forceRefresh: true` (every page's explicit "Check"/"Refresh"/
    /// "Re-check now" action, and every post-update recheck) always runs the
    /// real check and overwrites the cache, so a captain who explicitly asked
    /// for the truth never gets served a stale answer, and the refreshed
    /// truth is what every other page sees next.
    /// How long a coalesced waiter blocks on the in-flight runner before
    /// giving up and checking for itself. Comfortably longer than a real
    /// check; short enough that a wedged one cannot park a pool thread
    /// indefinitely.
    static let inFlightWaitTimeout: TimeInterval = 120

    func check(_ item: DependencyItem, forceRefresh: Bool = false, maxAge: TimeInterval = defaultTTL) -> CheckOutcome {
        while true {
            lock.lock()
            if !forceRefresh, let entry = entries[item.id], Date().timeIntervalSince(entry.checkedAt) < maxAge {
                lock.unlock()
                return entry.outcome
            }
            if let group = inFlight[item.id] {
                lock.unlock()
                // Bounded rather than an open `wait()`: the runner in front of
                // us is only transitively bounded by the per-subprocess timeout,
                // and an unbounded wait parks a pool thread for however long
                // that takes with no watchdog of its own. Timing out just
                // re-reads the cache on the next turn - the runner still
                // publishes its result, so nothing is lost, and a waiter that
                // gives up runs its own check rather than hanging.
                _ = group.wait(timeout: .now() + Self.inFlightWaitTimeout)
                continue
            }
            let group = DispatchGroup()
            group.enter()
            inFlight[item.id] = group
            lock.unlock()

            let runner = Self.checkOverrideForTests ?? UpdatesSource.check
            let outcome = runner(item)

            lock.lock()
            entries[item.id] = Entry(outcome: outcome, checkedAt: Date())
            inFlight.removeValue(forKey: item.id)
            lock.unlock()
            group.leave()
            return outcome
        }
    }

    /// Drops a single item's cached entry, if any - not called by any
    /// controller today (every write path already overwrites the entry it
    /// cares about via a forced `check(_:forceRefresh: true)`), kept as a
    /// small, obviously-correct escape hatch rather than something a future
    /// caller has to fake by passing `maxAge: 0`.
    func invalidate(_ itemID: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: itemID)
    }

    // MARK: - Test seam

    /// Replaces the real `UpdatesSource.check` call with a fake for the
    /// duration of a self-test - same convention as `DictationCleanup.
    /// claudePathOverrideForTests`/`SRELead.claudePathOverrideForTests`.
    /// `nil` (the production default) means "call the real thing".
    static var checkOverrideForTests: ((DependencyItem) -> CheckOutcome)?
}
