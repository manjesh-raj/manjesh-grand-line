// Grand Line - native macOS app.
//
// R5 energy fix 4: `GitFetchCoalescer`, the one decision about whether a
// `git fetch` of a clone is needed.
//
// Two halves. The coalescer's own rules (reuse inside the window, refetch
// after it, `force`, a failed fetch never reused, one clone however its path is
// spelled, concurrent callers sharing one fetch) run against a fake fetch. The
// wiring runs `ShiftGitSync.pullNow` against a real, disposable local bare
// repository, because "the second periodic pull reads the first one's refs"
// and "a push rejected after a reused fetch retries with a real one" are
// properties of the call site, which a fake fetch cannot see.
//
// Pure logic plus local `git` subprocesses: no window, no network, so it runs
// in CI's headless lane.
//
// Run with:
//   swift build && FM_RUN_GIT_FETCH_COALESCER_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum GitFetchCoalescerSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("aRecentSuccessfulFetchIsReused", test_reuseInsideWindow),
            ("aFetchOlderThanTheWindowRunsAgain", test_refetchAfterWindow),
            ("forceAlwaysFetches", test_force),
            ("aFailedFetchIsNeverReused", test_failureNotStored),
            ("invalidateDropsTheStoredFetch", test_invalidate),
            ("oneCloneIsOneKeyHoweverItsPathIsSpelled", test_keyNormalisesPath),
            ("concurrentCallersShareOneFetch", test_concurrentCallersShare),
            ("theSharedInstanceFetchesAboutSixTimesAnHourForThreeReaders", test_sharedWindowBudget),
            ("aSecondPeriodicPullReadsTheFirstPullsRefs", test_shiftPullReusesFetch),
            ("aPushRejectedAfterAReusedFetchRetriesWithARealOne", test_shiftPushRetryAfterReuse),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        try? FileManager.default.removeItem(at: scratch)
        print(failures == 0
            ? "GitFetchCoalescerSelfTest: all \(cases.count) cases passed"
            : "GitFetchCoalescerSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fakes

    private static func ok() -> SubprocessResult {
        SubprocessResult(outcome: .exited, status: 0, stdoutData: Data(), stderrData: Data(), duration: 0)
    }

    private static func failed() -> SubprocessResult {
        SubprocessResult(outcome: .exited, status: 128, stdoutData: Data(),
                         stderrData: Data("fatal: unable to access remote".utf8), duration: 0)
    }

    private static let clone = "/tmp/fm-coalescer-clone"

    // MARK: The coalescer's rules

    private static func test_reuseInsideWindow() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        let start = Date()
        var runs = 0
        _ = coalescer.fetch(clonePath: clone, branch: "main", now: start) { runs += 1; return ok() }
        let second = coalescer.fetch(clonePath: clone, branch: "main", now: start.addingTimeInterval(300)) { runs += 1; return ok() }
        guard runs == 1, second.wasReused, second.succeeded else {
            return "a fetch 5 minutes after a successful one ran \(runs) fetches (reused: \(second.wasReused)) - want 1, reused"
        }
        let other = coalescer.fetch(clonePath: clone, branch: "other", now: start.addingTimeInterval(300)) { runs += 1; return ok() }
        guard runs == 2, !other.wasReused else { return "another branch is not the same fetch and must run" }
        return nil
    }

    private static func test_refetchAfterWindow() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        let start = Date()
        var runs = 0
        _ = coalescer.fetch(clonePath: clone, branch: "main", now: start) { runs += 1; return ok() }
        let late = coalescer.fetch(clonePath: clone, branch: "main", now: start.addingTimeInterval(601)) { runs += 1; return ok() }
        guard runs == 2, !late.wasReused else { return "a fetch 10 minutes and a second after the last must run, ran \(runs)" }
        return nil
    }

    private static func test_force() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        var runs = 0
        _ = coalescer.fetch(clonePath: clone, branch: "main") { runs += 1; return ok() }
        let forced = coalescer.fetch(clonePath: clone, branch: "main", force: true) { runs += 1; return ok() }
        guard runs == 2, !forced.wasReused else { return "a forced fetch inside the window must still run, ran \(runs)" }
        return nil
    }

    private static func test_failureNotStored() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        var runs = 0
        let first = coalescer.fetch(clonePath: clone, branch: "main") { runs += 1; return failed() }
        guard !first.succeeded, first.stderr.contains("unable to access") else {
            return "a failed fetch must report its failure and git's own stderr"
        }
        let retry = coalescer.fetch(clonePath: clone, branch: "main") { runs += 1; return ok() }
        guard runs == 2, !retry.wasReused else { return "a failed fetch was reused - the next caller must retry, ran \(runs)" }
        return nil
    }

    private static func test_invalidate() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        var runs = 0
        _ = coalescer.fetch(clonePath: clone, branch: "main") { runs += 1; return ok() }
        coalescer.invalidate(clonePath: clone, branch: "main")
        _ = coalescer.fetch(clonePath: clone, branch: "main") { runs += 1; return ok() }
        guard runs == 2 else { return "a fetch after invalidate must run, ran \(runs)" }
        return nil
    }

    /// The dotfiles checkout reaches the coalescer from two readers with two
    /// spellings of one path. A temporary directory is the sharpest case:
    /// `/var/folders/...` is `/private/var/folders/...` underneath.
    private static func test_keyNormalisesPath() -> String? {
        let dir = scratch.appendingPathComponent("key-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.path
        let real = CodeSandbox.realPath(plain)
        guard plain != real || plain.hasPrefix("/private/") else {
            return "the fixture's two spellings are identical (\(plain)) - the case is vacuous"
        }
        let spellings = [plain, real, plain + "/", plain + "/./"]
        let keys = Set(spellings.map { GitFetchCoalescer.key(clonePath: $0, branch: "main") })
        guard keys.count == 1 else { return "one clone produced \(keys.count) keys from \(spellings)" }
        return nil
    }

    private static func test_concurrentCallersShare() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        let lock = NSLock()
        var runs = 0
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        var outcomes: [GitFetchCoalescer.Outcome] = []
        func call() {
            let outcome = coalescer.fetch(clonePath: clone, branch: "main") {
                lock.lock(); runs += 1; lock.unlock()
                started.signal()
                release.wait()
                return ok()
            }
            lock.lock(); outcomes.append(outcome); lock.unlock()
        }
        DispatchQueue.global().async(group: group) { call() }
        started.wait()
        for _ in 0..<4 { DispatchQueue.global().async(group: group) { call() } }
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        guard group.wait(timeout: .now() + 5) == .success else { return "concurrent callers did not finish" }
        guard runs == 1, outcomes.count == 5, outcomes.filter({ $0.wasReused }).count == 4 else {
            return "5 concurrent callers ran \(runs) fetches (\(outcomes.filter { $0.wasReused }.count) reused) - want 1 fetch, 4 reused"
        }
        return nil
    }

    /// The report's arithmetic, on `.shared`'s real window: three readers of
    /// one clone (a 300 s pull timer, a 600 s safety net, a sweep's drift read
    /// every 15 minutes) fetched 51 times in 65 minutes. Through the
    /// coalescer they fetch at most once per window.
    private static func test_sharedWindowBudget() -> String? {
        let coalescer = GitFetchCoalescer(freshnessWindow: 10 * 60)
        guard GitFetchCoalescer.shared.freshnessWindow == 0 || GitFetchCoalescer.shared.freshnessWindow == 600 else {
            return "the shared window should be 10 minutes (0 inside a self-test process), got \(GitFetchCoalescer.shared.freshnessWindow)"
        }
        let start = Date()
        var runs = 0
        var askers: [TimeInterval] = []
        for t in stride(from: 0, to: 3600, by: 300) { askers.append(TimeInterval(t)) }
        for t in stride(from: 0, to: 3600, by: 600) { askers.append(TimeInterval(t) + 7) }
        for t in stride(from: 0, to: 3600, by: 900) { askers.append(TimeInterval(t) + 13) }
        for offset in askers.sorted() {
            _ = coalescer.fetch(clonePath: clone, branch: "main", now: start.addingTimeInterval(offset)) {
                runs += 1
                return ok()
            }
        }
        guard askers.count > 20, runs <= 6 else {
            return "\(askers.count) fetch requests in an hour ran \(runs) real fetches - want at most 6"
        }
        return nil
    }

    // MARK: Wiring, against a real local repository

    private static let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-fetch-coalescer-selftest-\(UUID().uuidString)", isDirectory: true)

    private static func git(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// A bare remote with one commit, and a second clone that pushes to it as
    /// "the other machine" does.
    private static func makeRemote(_ name: String) -> (remote: URL, other: URL) {
        let remote = scratch.appendingPathComponent("\(name)-remote", isDirectory: true)
        let other = scratch.appendingPathComponent("\(name)-other", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = git(["init", "--bare", "-b", "main", remote.path])
        _ = git(["clone", remote.path, other.path])
        commit(in: other, file: "GrandLineDocs/personal-tasks/.keep", text: "seed")
        _ = git(["-C", other.path, "push", "origin", "HEAD:main"])
        return (remote, other)
    }

    private static func commit(in repo: URL, file: String, text: String) {
        let url = repo.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        _ = git(["-C", repo.path, "add", "-A"])
        _ = git(["-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=Coalescer Test",
                 "commit", "-q", "-m", "change \(UUID().uuidString.prefix(6))"])
    }

    private static func otherMachinePushes(_ other: URL) {
        commit(in: other, file: "GrandLineDocs/personal-tasks/other-\(UUID().uuidString.prefix(6)).txt", text: "x")
        _ = git(["-C", other.path, "push", "-q", "origin", "HEAD:main"])
    }

    /// The periodic pull's whole cost was its fetch. Inside the window a
    /// second pull reads the refs the first one left, so a commit pushed in
    /// between arrives on the next real fetch rather than this one.
    private static func test_shiftPullReusesFetch() -> String? {
        let (remote, other) = makeRemote("reuse")
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        let sync = ShiftGitSync(workingTree: scratch.appendingPathComponent("reuse-wt", isDirectory: true),
                                remoteURL: remote.path, debounceInterval: 600, periodicPullInterval: 999_999,
                                fetchCoalescer: coalescer)
        guard sync.ensureWorkingTreeNow() else { return "the fixture clone failed" }
        otherMachinePushes(other)
        guard sync.pullNow() == .fastForwarded else { return "the first pull should fetch and fast-forward" }
        otherMachinePushes(other)
        let reused = sync.pullNow()
        guard reused == .upToDate, coalescer.debugFetchCount == 1 else {
            return "a pull inside the window should reuse the first fetch (got \(reused), \(coalescer.debugFetchCount) fetches)"
        }
        let forced = sync.pullNow(forceFetch: true)
        guard forced == .fastForwarded, coalescer.debugFetchCount == 2 else {
            return "a forced pull must fetch and bring the second commit in (got \(forced), \(coalescer.debugFetchCount) fetches)"
        }
        return nil
    }

    /// The one way reuse could change what the captain sees: a local commit
    /// pushed against a stale remote-tracking ref is rejected. The pull must
    /// fetch for real and report what a fresh fetch would have - here, a
    /// divergence - never "git push failed".
    private static func test_shiftPushRetryAfterReuse() -> String? {
        let (remote, other) = makeRemote("retry")
        let coalescer = GitFetchCoalescer(freshnessWindow: 600)
        let tree = scratch.appendingPathComponent("retry-wt", isDirectory: true)
        let sync = ShiftGitSync(workingTree: tree, remoteURL: remote.path, debounceInterval: 600,
                                periodicPullInterval: 999_999, fetchCoalescer: coalescer)
        guard sync.ensureWorkingTreeNow() else { return "the fixture clone failed" }
        guard sync.pullNow() == .upToDate else { return "the first pull should be up to date" }
        otherMachinePushes(other)
        commit(in: tree, file: "GrandLineDocs/personal-tasks/local.txt", text: "local")
        let outcome = sync.pullNow()
        guard outcome == .diverged else {
            return "a push rejected after a reused fetch must retry with a real fetch and report .diverged, got \(outcome)"
        }
        guard coalescer.debugFetchCount == 2 else {
            return "the retry should have run exactly one real fetch, total \(coalescer.debugFetchCount)"
        }
        return nil
    }
}
#endif
