// Grand Line - native macOS app.
//
// PERF-02 of the 2026-10 end-to-end review (section 3.6): one `start()` per
// git sync instance, however many stores ask for it.
//
// **What it fixes.** Every git-synced store calls its sync's `start()` from
// its own `init`, and the syncs are `.shared` singletons - so a second store
// instance meant a second `start()`. None of them had an "already started"
// guard. `ShiftGitSync.start()` guarded only its pull timer, so each call
// still queued a working-tree check plus a full `pullNow()` (a fetch, two
// merge-base checks and a fast-forward); `DocsRunbookGitSync.start()` queued
// another `ensureReadyNow()` and `git status`. At launch that was five
// `DocsRunbookStore`s, two `LogAnalyzerStore`s and the four other stores
// that start `ShiftGitSync` - roughly four fetch-and-merge rounds and eleven
// status passes serialised on the one shared git queue, all ahead of the first
// real sync and the first task write that needed that queue.
//
// **Why a gate and not "construct each store once".** The shell now passes one
// `DocsRunbookStore` and one `LogAnalyzerStore` down instead of building four,
// but a store is still free to be built twice - `GL-23`'s rule is about stores
// that cache, and several of these re-read their folder per call precisely so
// a second instance is harmless. The gate is what makes that true of the sync
// as well: the first `start()` does the launch work, every later one is a
// no-op. A later sync is still reached through `markDirty()` and the periodic
// pull, which is what kept data moving before a second `start()` existed.
//
// Thread-safe, because a store can be constructed on any queue.

import Foundation

final class GitSyncStartGate {

    private let lock = NSLock()
    private var started = false

    /// `true` exactly once - for the call that should do the launch work.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }

    #if FM_SELFTESTS
    /// Whether a `start()` has been accepted, so a suite can assert the gate
    /// was claimed by the first call rather than read the private flag.
    var debugHasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
    #endif
}
