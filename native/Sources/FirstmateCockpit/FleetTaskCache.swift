// Manjesh Grand Line - native macOS app.
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

    private static let lock = NSLock()
    private static var cached: (tasks: [FleetTask], at: Date)?
    private static var inFlight: DispatchGroup?

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
        if !forceRefresh, let group = inFlight {
            // Someone else is already running exactly this sweep. Wait for
            // theirs instead of starting a second identical one.
            lock.unlock()
            group.wait()
            lock.lock()
            let result = cached?.tasks
            lock.unlock()
            if let result { return result }
            // Unreachable in practice - the producer always stores before it
            // leaves the group - but if it somehow did not, run the real
            // sweep rather than reporting an empty fleet, which GL-14's rule
            // says must never be manufactured out of a failure.
            return compute()
        }
        let group = DispatchGroup()
        group.enter()
        // A *forced* run deliberately does not register as the sweep others
        // may wait on: it exists to bypass the window, and offering itself as
        // the shared answer would also mean clobbering the registration of an
        // ordinary sweep already running (which is what waiters are parked
        // on). Waiters stay on the sweep they captured, which always
        // completes.
        if !forceRefresh { inFlight = group }
        lock.unlock()

        let result = compute()

        lock.lock()
        cached = (result, Date())
        // Identity-checked so a producer can only ever clear its *own*
        // registration - clearing unconditionally would let a run that
        // finished first drop a later one's, leaving a third caller to start
        // a redundant sweep.
        if inFlight === group { inFlight = nil }
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
