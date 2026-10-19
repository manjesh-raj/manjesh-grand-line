// Grand Line - native macOS app.
//
// A short coalescing window over `FleetDataSource.parseTasks()` - the safe
// half of 3.5 in `data/grandline-full-app-audit/report.md`.
//
// **What this is, and what it deliberately is not.** `parseTasks()` spawns one
// real `bin/fm-crew-state.sh` per fleet task (bounded to 6 at a time since
// P6), and four independent callers ask for it: `FleetNotifier.start()`'s
// baseline, its 30s/120s `poll()`, `FleetController.refresh()` via
// `snapshot()`, and `ReviewController.refresh()`. Every one of those dispatches
// to its own global queue, so at launch - when Overview and Review are both
// eager-mounted and both `refreshIfNeeded()`, alongside the notifier priming
// its baseline - three genuinely concurrent fan-outs of the *identical* sweep
// land within a second or two of each other. With six tasks in flight that is
// 18 subprocess spawns to answer one question. This collapses them to 6.
//
// It is **not** a freshness cache, and the TTL is deliberately far shorter
// than `FleetNotifier.pollInterval` so that it cannot be one: every poll
// misses it by construction, so no state transition is ever detected later
// than it was before this file existed. `DependencyCheckCache` is the
// long-TTL cache in this codebase (15 minutes, for signals that genuinely
// change on that scale); this is the opposite end of the same idea - a
// window just wide enough to catch simultaneous askers.
//
// **Why the audit's own suggested 3.5 mechanism is not what shipped.** The
// report proposed caching each task's crew state keyed by its
// `state/<id>.meta` modification time and re-shelling only for tasks whose
// meta changed. That would freeze every task's reported state permanently:
// `fm-crew-state.sh` derives the current state from `state/<id>.status`, the
// no-mistakes ledger (`axi status`), the worktree HEAD, and the **live tmux/
// herdr pane busy signature** - never from `.meta`, which only supplies the
// fixed worktree/backend/kind identity and is written once at dispatch (the
// only two writers of a `.meta` anywhere in firstmate's `bin/` are dispatch
// itself and `fm-captain-hold.sh` appending `decisions_reviewed`, neither of
// them a state transition). A `.meta`-keyed cache would therefore never
// notice a crew going working -> parked -> done, which is precisely the
// signal `FleetNotifier` exists to surface and Overview's "Needs your call"
// section is built from. There is no *complete* cheap key available, because
// two of the script's four real inputs are themselves subprocesses.
//
// Thread-safety follows `DependencyCheckCache`/`ServiceHealthRegistry`: an
// `NSLock`-guarded value plus a `DispatchGroup` to coalesce a genuine race.
// `DispatchGroup.wait()` rather than a semaphore, for the reason
// `DependencyCheckCacheSelfTest` records: `signal()` releases exactly one
// blocked `wait()`, so N simultaneous waiters on one semaphore hang after the
// first is released, whereas every waiter may safely `wait()` on a group and
// all are released together.
//
// **Callers are expected to be off the main thread** - all four are today,
// each dispatching to a global queue itself. A waiter blocks for at most the
// length of one real sweep, which is strictly less than the fan-out it would
// otherwise have performed itself. Deliberately not enforced with a
// `dispatchPrecondition`: the cost of a main-thread caller here is a brief
// stall, and turning that into a crash would be the worse trade.

import Foundation

enum FleetTaskCache {
    /// The coalescing window. Comfortably shorter than
    /// `FleetNotifier.pollInterval` (30s active / 120s away) so a poll can
    /// never be served a cached answer, and long enough to span the
    /// launch-time pile-up of three concurrent callers.
    static let ttl: TimeInterval = 5

    /// How long a caller waits on another caller's sweep before running its
    /// own (REL-27), and how old an in-flight registration may be before a
    /// new caller stops treating it as live. A real sweep is about half a
    /// second; this only matters when one hangs.
    private(set) static var waitTimeout: TimeInterval = 10

    private static let lock = NSLock()
    private static var cached: (tasks: [FleetTask], at: Date, generation: UInt64)?
    private static var inFlight: (group: DispatchGroup, startedAt: Date)?
    /// REL-27, GL-03's pass id: every sweep takes the next number when it
    /// starts, and a finished sweep only replaces `cached` when it started
    /// after the one stored there. A forced sweep never registered in
    /// `inFlight` and always wrote `cached`, so an older forced sweep that
    /// finished late overwrote a newer result for the whole `ttl`.
    private static var nextGeneration: UInt64 = 0

    /// Serve `compute`'s result, reusing a hit inside `ttl` and coalescing a
    /// concurrent race onto one real run.
    ///
    /// `forceRefresh` always runs `compute` and refreshes the stored value -
    /// the captain's own Refresh click must never be answered from a cache,
    /// the same rule `DependencyCheckCache` states for its own explicit
    /// "Check"/"Re-check now" affordances.
    static func tasks(forceRefresh: Bool = false, compute: () -> [FleetTask]) -> [FleetTask] {
        lock.lock()
        if !forceRefresh, let hit = cached, Date().timeIntervalSince(hit.at) < ttl {
            lock.unlock()
            return hit.tasks
        }
        // REL-27's admission-time watchdog: a registration older than the
        // wait bound belongs to a sweep that is not coming back, so it is not
        // something a new caller parks on.
        if let running = inFlight, Date().timeIntervalSince(running.startedAt) >= waitTimeout {
            AppLog.store.error("fleet tasks: an in-flight sweep has run past \(waitTimeout, privacy: .public)s - no longer waiting on it")
            inFlight = nil
        }
        if !forceRefresh, let running = inFlight {
            // Someone else is already running exactly this sweep. Wait for
            // theirs instead of starting a second identical one - for a
            // bounded time (REL-27): an unbounded `wait()` parked every later
            // caller for as long as one sweep hung.
            lock.unlock()
            if running.group.wait(timeout: .now() + waitTimeout) == .success {
                lock.lock()
                let result = cached?.tasks
                lock.unlock()
                if let result { return result }
            } else {
                AppLog.store.error("fleet tasks: waited \(waitTimeout, privacy: .public)s on another sweep - running this one")
            }
            // The producer always stores before it leaves the group, so this
            // is the timeout path in practice. Run the real sweep rather than
            // reporting an empty fleet, which GL-14's rule says must never be
            // manufactured out of a failure.
            return runSweep(register: false, compute: compute)
        }
        lock.unlock()
        // A *forced* run deliberately does not register as the sweep others
        // may wait on: it exists to bypass the window, and offering itself as
        // the shared answer would also mean clobbering the registration of an
        // ordinary sweep already running (which is what waiters are parked
        // on). Waiters stay on the sweep they captured, which always
        // completes.
        return runSweep(register: !forceRefresh, compute: compute)
    }

    /// One real sweep, stored only if no newer sweep has stored since it
    /// started.
    private static func runSweep(register: Bool, compute: () -> [FleetTask]) -> [FleetTask] {
        lock.lock()
        nextGeneration &+= 1
        let generation = nextGeneration
        let group = DispatchGroup()
        group.enter()
        if register { inFlight = (group, Date()) }
        lock.unlock()

        let result = compute()

        lock.lock()
        if cached.map({ generation > $0.generation }) ?? true {
            cached = (result, Date(), generation)
        } else {
            AppLog.store.debug("fleet tasks: a sweep finished after a newer one - keeping the newer result")
        }
        // Identity-checked so a producer can only ever clear its *own*
        // registration - clearing unconditionally would let a run that
        // finished first drop a later one's, leaving a third caller to start
        // a redundant sweep.
        if inFlight?.group === group { inFlight = nil }
        lock.unlock()
        group.leave()
        return result
    }

    /// Drop any stored value. Nothing in the app calls this - a 5-second
    /// window heals itself - but a self-test needs each case to start from a
    /// known-cold cache rather than inheriting the previous case's.
    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    #if FM_SELFTESTS
    /// REL-27: a suite shortens the wait bound so a hung sweep is seconds,
    /// not ten of them, and restores it.
    static func debugSetWaitTimeout(_ seconds: TimeInterval) { waitTimeout = seconds }

    /// What is stored right now, regardless of age.
    static var debugCachedTasks: [FleetTask]? {
        lock.lock()
        defer { lock.unlock() }
        return cached?.tasks
    }

    /// Whether a value is currently stored and still inside `ttl` - so a
    /// suite can assert the window is real rather than that a call happened
    /// to be fast.
    static var debugHasFreshEntry: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = cached else { return false }
        return Date().timeIntervalSince(hit.at) < ttl
    }
    #endif
}
