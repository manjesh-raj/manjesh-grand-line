// Grand Line - native macOS app.
//
// R5 energy fix 4 (`data/grand-line-full-app-review/report.md`, sections 2.2
// and 2.6). Three code paths ran `git fetch origin main` against the same
// `manjesh-config` remote without knowing the others just had:
//
// - `ShiftGitSync.pullNow`, on its 300-second pull timer.
// - `DotfilesAutoSync.syncNow`, before every push of a dotfiles change.
// - `DotfilesSource.repoState`'s `behindOrigin`, from every background sweep,
//   every Setup and Automation visit, and every scheduled drift check.
//
// The review counted 51 fetches in 65 minutes, one every 76 seconds. Each is a
// TLS handshake plus `git remote-https`, `rev-list` and `git maintenance`
// children, and on battery each is a radio wake-up.
//
// This is the one place that decides whether a fetch is needed. It is keyed
// by the clone's real path and the branch, so the dotfiles checkout's two
// readers share one answer, and a fetch that succeeded inside
// `freshnessWindow` (10 minutes) is reused instead of repeated. A caller that
// arrives while a fetch for the same clone is running waits for that one.
//
// What reuse costs is bounded by the window: a commit pushed from another
// machine can take up to 10 minutes longer to arrive (it took up to 5 with the
// Tasks pull timer alone). Three things stay exact:
//
// - **A captain's own action forces a fetch.** "Sync now" and Setup's
//   "Re-check now" pass `force`, so an explicit refresh is never answered
//   from a fetch made minutes ago.
// - **A failed fetch is never reused.** Only a successful one is stored, so the
//   next caller retries, exactly as before.
// - **A push rejected after a reused fetch retries with a real one.** Both
//   sync classes check `wasReused` and fetch for real before reporting the
//   rejection, so a stale remote-tracking ref can never surface as a
//   "git push failed" the old code would not have shown.

import Foundation

final class GitFetchCoalescer {

    static let shared = GitFetchCoalescer(freshnessWindow: 10 * 60)

    /// How long a successful fetch of one clone and branch is reused.
    private(set) var freshnessWindow: TimeInterval

    /// How long a caller waits on someone else's fetch of the same clone
    /// before running its own. The fetch is itself bounded by its caller's
    /// git timeout, so this only matters when one hangs.
    let waitBound: TimeInterval

    /// What `fetch` did.
    struct Outcome {
        /// The fetch that ran, or `nil` when a recent one was reused.
        let result: SubprocessResult?
        /// When the fetch whose refs the caller will read started.
        let fetchedAt: Date

        var wasReused: Bool { result == nil }
        var succeeded: Bool { result.map { $0.status == 0 } ?? true }
        var stderr: String { result?.stderr ?? "" }
    }

    private let lock = NSLock()
    private var lastSuccess: [String: Date] = [:]
    private var inFlight: [String: (group: DispatchGroup, box: ResultBox)] = [:]

    private final class ResultBox {
        var outcome: Outcome?
    }

    #if FM_SELFTESTS
    /// How many real fetches this instance ran, for a suite.
    private(set) var debugFetchCount = 0
    #endif

    init(freshnessWindow: TimeInterval, waitBound: TimeInterval = 240) {
        self.freshnessWindow = freshnessWindow
        self.waitBound = waitBound
    }

    /// Fetch `branch` of the clone at `clonePath` by calling `run`, unless a
    /// fetch of the same clone and branch succeeded within `freshnessWindow`
    /// or is running right now. `force` always runs it.
    ///
    /// Synchronous and blocking, like the git calls around it. Each caller
    /// already runs on its own background queue.
    func fetch(clonePath: String, branch: String, force: Bool = false,
               now: Date = Date(), run: () -> SubprocessResult) -> Outcome {
        let key = Self.key(clonePath: clonePath, branch: branch)
        lock.lock()
        if !force, let last = lastSuccess[key], now.timeIntervalSince(last) < freshnessWindow {
            lock.unlock()
            return Outcome(result: nil, fetchedAt: last)
        }
        if !force, let running = inFlight[key] {
            lock.unlock()
            if running.group.wait(timeout: .now() + waitBound) == .success,
               let shared = running.box.outcome, shared.succeeded {
                return Outcome(result: nil, fetchedAt: shared.fetchedAt)
            }
            // It failed or hung. Fetch for ourselves rather than report a
            // failure we did not see.
            return runFetch(key: key, register: false, startedAt: now, run: run)
        }
        lock.unlock()
        return runFetch(key: key, register: !force, startedAt: now, run: run)
    }

    /// Forget any successful fetch of this clone and branch, so the next
    /// caller fetches for real.
    func invalidate(clonePath: String, branch: String) {
        let key = Self.key(clonePath: clonePath, branch: branch)
        lock.lock()
        lastSuccess.removeValue(forKey: key)
        lock.unlock()
    }

    /// A fetch's age is counted from when it started, since the refs it
    /// leaves are at least that new.
    private func runFetch(key: String, register: Bool, startedAt: Date, run: () -> SubprocessResult) -> Outcome {
        let group = DispatchGroup()
        let box = ResultBox()
        group.enter()
        lock.lock()
        if register { inFlight[key] = (group, box) }
        #if FM_SELFTESTS
        debugFetchCount += 1
        #endif
        lock.unlock()

        let result = run()
        let outcome = Outcome(result: result, fetchedAt: startedAt)

        lock.lock()
        if outcome.succeeded { lastSuccess[key] = outcome.fetchedAt }
        if inFlight[key]?.group === group { inFlight.removeValue(forKey: key) }
        box.outcome = outcome
        lock.unlock()
        group.leave()
        return outcome
    }

    /// One clone is one key however its path was spelled: the dotfiles
    /// checkout reaches here as `~/.dotfiles`'s target from one caller and as
    /// a `URL` from another, and `/var` is `/private/var` underneath.
    static func key(clonePath: String, branch: String) -> String {
        let standardized = URL(fileURLWithPath: clonePath).standardizedFileURL.path
        return CodeSandbox.realPath(standardized) + "\u{1f}" + branch
    }

    #if FM_SELFTESTS
    /// A self-test process turns reuse off for `.shared`, so the sync suites
    /// that pull the same scratch clone twice in a row still fetch twice.
    /// `GitFetchCoalescerSelfTest` drives its own instance.
    func debugSetFreshnessWindow(_ seconds: TimeInterval) {
        lock.lock()
        freshnessWindow = seconds
        lock.unlock()
    }
    #endif
}
