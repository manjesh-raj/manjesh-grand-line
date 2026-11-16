// Grand Line - native macOS app.
//
// R5 energy fixes 2 and 3 (`data/grand-line-full-app-review/report.md`,
// section 2.6). The tool sweep used to ask npm and Homebrew one package at a
// time: five `npm ls` plus five `npm view`, and a `brew list` plus a
// `brew info` per formula. Both tools answer for every package in one call,
// so `UpdatesSource` now asks once and every package's check reads its own
// answer out of that one reply.
//
// The checks themselves stay per item, because every caller (the Updates,
// Setup and Automation pages, the background poller and the scheduled tool
// check) asks `DependencyCheckCache` for one item at a time, often from
// several queues at once. This is what lets those per-item checks share one
// subprocess: the first check of a sweep runs the batch read, a check that
// arrives while it runs waits for it, and a check that arrives shortly after
// reads the stored answer.
//
// `window` is deliberately short (seconds, not minutes). It only has to span
// one sweep's worth of items, which the sweep asks for back to back. It is
// not a freshness cache: `DependencyCheckCache` is that, with its own TTLs and
// its own `forceRefresh` rules, and a value kept here for minutes would let a
// forced re-check be answered from before the thing it is re-checking. An
// update invalidates the read outright, so the re-check after it always runs
// a new one.

import Foundation

final class CoalescedRead<Value> {

    /// How long a finished read is shared after it lands.
    let window: TimeInterval

    /// How long a caller waits on someone else's read before running its own.
    /// The read is itself bounded by its subprocesses' timeouts, so this only
    /// matters when one of those hangs.
    let waitBound: TimeInterval

    private let lock = NSLock()
    private var stored: (value: Value, at: Date, generation: UInt64)?
    private var inFlight: (group: DispatchGroup, generation: UInt64)?
    /// Bumped by every read that starts and by `invalidate()`. A read only
    /// stores its value when nothing has bumped it since it started, so a read
    /// that began before an update can never be served after it.
    private var generation: UInt64 = 0

    init(window: TimeInterval, waitBound: TimeInterval) {
        self.window = window
        self.waitBound = waitBound
    }

    /// A shared value, or `fetch`'s own. `accepts` lets a caller refuse a
    /// stored value that does not cover what it needs, such as a package the
    /// stored read did not ask about.
    ///
    /// Synchronous and blocking, like the checks that call it. Call it off the
    /// main thread.
    func value(accepts: (Value) -> Bool = { _ in true }, fetch: () -> Value) -> Value {
        lock.lock()
        if let hit = stored, Date().timeIntervalSince(hit.at) < window, accepts(hit.value) {
            lock.unlock()
            return hit.value
        }
        if let running = inFlight {
            lock.unlock()
            if running.group.wait(timeout: .now() + waitBound) == .success {
                lock.lock()
                let hit = stored
                lock.unlock()
                if let hit, hit.generation == running.generation, accepts(hit.value) { return hit.value }
            }
            // Timed out, invalidated while it ran, or it did not cover this
            // caller: read for ourselves rather than report nothing.
            return run(register: false, fetch: fetch)
        }
        lock.unlock()
        return run(register: true, fetch: fetch)
    }

    /// Forget the stored value and any read in progress. The next caller runs
    /// a new read.
    func invalidate() {
        lock.lock()
        generation &+= 1
        stored = nil
        inFlight = nil
        lock.unlock()
    }

    private func run(register: Bool, fetch: () -> Value) -> Value {
        lock.lock()
        generation &+= 1
        let mine = generation
        let group = DispatchGroup()
        group.enter()
        if register { inFlight = (group, mine) }
        lock.unlock()

        let value = fetch()

        lock.lock()
        if generation == mine { stored = (value, Date(), mine) }
        if inFlight?.group === group { inFlight = nil }
        lock.unlock()
        group.leave()
        return value
    }
}
