// Grand Line - native macOS app.
//
// Two layers over `FleetDataSource.parseTasks()`: a short coalescing window -
// the safe half of 3.5 in `data/grandline-full-app-audit/report.md` - and,
// since R4-PERF-01, the per-task readings behind it.
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
// The window is **not** a freshness cache, and its TTL is deliberately far
// shorter than `FleetNotifier.pollInterval` so that it cannot be one: every
// poll misses it by construction. `DependencyCheckCache` is the long-TTL cache
// in this codebase (15 minutes, for signals that genuinely change on that
// scale); the window is the opposite end of the same idea - just wide enough
// to catch simultaneous askers.
//
// ## Per-task readings (R4-PERF-01)
//
// The fourth full review measured the captain's instance at 10-14 % idle CPU
// and pinned the recurring work on this sweep: every poll ran the script once
// per task, including for tasks whose crew had long since stopped. It asked
// for a cache keyed by each `.meta`'s modification time. **A cache keyed by
// the `.meta` alone would freeze every task's state**, which is why the 3.5
// audit's identical proposal was declined here before:
// `fm-crew-state.sh` derives the current state from `state/<id>.status`, the
// no-mistakes ledger (`axi status`), the worktree HEAD, and the live tmux/
// herdr pane busy signature - never from `.meta`, which only supplies the
// fixed worktree/backend/kind identity and is written once at dispatch. A
// `.meta`-keyed cache would never notice a crew going working -> parked ->
// done, which is precisely the signal `FleetNotifier` exists to surface.
//
// What shipped keeps the review's mechanism and fixes its key, in two parts.
//
// 1. **The key is every file the task owns in `state/`, not only its
//    `.meta`.** `FleetTaskFingerprint` is the modification date and size of
//    each `state/<id>.*` entry - the `.meta`, the `.status` log a crew appends
//    every transition to, the `.busy-state` record the harness hooks replace
//    on every turn, the `.inbox` folder firstmate steers it through, and the
//    rest. All of it comes from the one directory listing the sweep already
//    made, with `.contentModificationDateKey` asked for up front.
// 2. **Only a settled reading is reused.** Two of the script's inputs (the run
//    ledger and the pane) live outside `state/`, so a fingerprint alone still
//    cannot prove a *live* crew has not moved. `isSettled` names the readings
//    that cannot move without the crew or firstmate writing to one of those
//    files first: a finished task (done, failed) and a dead endpoint (no
//    backend target, its pane gone). A crew that comes back from either does
//    so by taking a turn, which replaces its `.busy-state`, or by being
//    re-dispatched, which rewrites its `.meta`. Everything else - working,
//    parked, blocked, paused, an unreachable backend - is read again on every
//    sweep, exactly as before.
//
// Two bounds keep the reuse honest. A settled reading is re-verified after
// `settledMaxAge` (5 minutes) even with an unchanged fingerprint, so a
// transition no file announced - a merge changing a done crew's detail, a
// captain typing into a finished crew's pane under a harness without hooks -
// is still seen, just later. And the captain's own Refresh (`forceRefresh`)
// reuses nothing.
//
// `FleetStateWatcher` is the other half: a state-file change asks for a sweep
// at once, and that sweep (`Reuse.unchanged`) also reuses a *live* reading
// whose files did not change, provided it is younger than the notifier's own
// tick. So an event costs one script run for the task that changed, while the
// 30-second tick is still what re-reads every live crew.
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

    /// Drop every stored value, the window's and every task's reading.
    /// Nothing in the app calls this - the window heals itself in 5 seconds and
    /// a reading is keyed by its files - but a self-test needs each case to
    /// start from a known-cold cache rather than inheriting the previous case's.
    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
        readingsLock.lock()
        readings = [:]
        readingsLock.unlock()
    }

    // MARK: Per-task readings (R4-PERF-01)

    /// What a sweep may reuse instead of running the script for a task.
    enum Reuse {
        /// Nothing: the captain's own Refresh.
        case none
        /// A settled reading whose files have not changed - every ordinary
        /// sweep.
        case settled
        /// Also a live reading whose files have not changed, up to
        /// `liveMaxAge` old - the sweep a state-file change asks for.
        case unchanged(liveMaxAge: TimeInterval)
    }

    /// How long a settled reading is trusted on an unchanged fingerprint
    /// before the script is asked again anyway. See the file header.
    private(set) static var settledMaxAge: TimeInterval = 300

    private static let readingsLock = NSLock()
    private static var readings: [String: (fingerprint: FleetTaskFingerprint, reading: FleetCrewReading, at: Date)] = [:]

    /// The readings that need no live input to stay true. See the file
    /// header for why each is here, and why nothing else is.
    static func isSettled(_ reading: FleetCrewReading) -> Bool {
        switch reading.state {
        case "done", "failed":
            return true
        case "unknown":
            guard reading.source == "none" else { return false }
            return ["backend target gone", "no backend target recorded", "worktree gone"]
                .contains { reading.detail.hasPrefix($0) }
        default:
            return false
        }
    }

    /// `id`'s crew reading: a stored one when `reuse` allows it, otherwise
    /// `compute`'s, which is then stored against `fingerprint`.
    static func reading(for id: String, fingerprint: FleetTaskFingerprint, reuse: Reuse,
                        compute: () -> FleetCrewReading) -> FleetCrewReading {
        let now = Date()
        readingsLock.lock()
        let stored = readings[id]
        readingsLock.unlock()
        if let stored, stored.fingerprint == fingerprint, fingerprint != .missing {
            let age = now.timeIntervalSince(stored.at)
            let settled = isSettled(stored.reading)
            switch reuse {
            case .none:
                break
            case .settled:
                if settled, age < settledMaxAge { return stored.reading }
            case .unchanged(let liveMaxAge):
                if age < (settled ? settledMaxAge : liveMaxAge) { return stored.reading }
            }
        }
        let fresh = compute()
        readingsLock.lock()
        readings[id] = (fingerprint, fresh, Date())
        readingsLock.unlock()
        return fresh
    }

    /// Forget the readings of tasks that are no longer in the fleet, so the
    /// store is bounded by today's task list (GL-35).
    static func retainReadings(for ids: Set<String>) {
        readingsLock.lock()
        readings = readings.filter { ids.contains($0.key) }
        readingsLock.unlock()
    }

    #if FM_SELFTESTS
    /// REL-27: a suite shortens the wait bound so a hung sweep is seconds,
    /// not ten of them, and restores it.
    static func debugSetWaitTimeout(_ seconds: TimeInterval) { waitTimeout = seconds }

    /// Shortens (or restores) how long a settled reading is trusted.
    static func debugSetSettledMaxAge(_ seconds: TimeInterval) { settledMaxAge = seconds }

    /// Expires the window but keeps every task's reading, which is what the
    /// next ordinary sweep after a real poll interval sees.
    static func debugExpireWindow() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// The ids that hold a stored reading.
    static var debugReadingIDs: Set<String> {
        readingsLock.lock()
        defer { readingsLock.unlock() }
        return Set(readings.keys)
    }

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

/// R4-PERF-01: what a task's reading is keyed by - the modification date and
/// size of every entry in `state/` named `<id>.<anything>`. See
/// `FleetTaskCache`'s header for why it is all of them and not the `.meta`.
struct FleetTaskFingerprint: Equatable {
    struct Entry: Equatable {
        let name: String
        let modified: Date?
        let size: Int?
    }

    let entries: [Entry]

    /// A task with no entry at all (its files vanished mid-sweep). Never
    /// matches a stored reading, so such a task is always read for real.
    static let missing = FleetTaskFingerprint(entries: [])

    /// Every task's fingerprint, from one directory listing that already
    /// carries `.contentModificationDateKey` and `.fileSizeKey`.
    ///
    /// An entry belongs to a task when its name is the task id followed by a
    /// dot. Each dot in a name is tried as the end of an id, so an id that
    /// itself contains a dot still finds its files.
    static func all(in listing: [URL], taskIDs: [String]) -> [String: FleetTaskFingerprint] {
        let ids = Set(taskIDs)
        var entries: [String: [Entry]] = [:]
        for url in listing {
            let name = url.lastPathComponent
            for dot in name.indices where name[dot] == "." {
                let id = String(name[..<dot])
                guard ids.contains(id) else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                entries[id, default: []].append(
                    Entry(name: name, modified: values?.contentModificationDate, size: values?.fileSize))
            }
        }
        return entries.mapValues { FleetTaskFingerprint(entries: $0.sorted { $0.name < $1.name }) }
    }
}
