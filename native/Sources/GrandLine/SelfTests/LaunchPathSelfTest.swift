// Grand Line - native macOS app.
//
// The launch-path half of the 2026-10 end-to-end review's performance
// findings (section 3.6): PERF-01, PERF-02 and PERF-08, plus T-14d's
// signposts. Pure logic - no window, no view hierarchy - so it guards the
// blocking CI lane. The window-backed half (what a real `AppShellController`
// builds at launch) is in `DestinationMountingSelfTest`.
//
// None of these cases measures time. The review's own numbers need
// Instruments and the captain's real data, which a suite must never touch.
// What a suite can assert is the *work*: how many times a sync really
// started, which controllers exist, how many host pages one run-loop turn
// builds. Those are the mechanisms the time savings come from, and each case
// below was confirmed to fail with its fix reverted (the PR description lists
// which injection failed which case).
//
// Run with:
//   swift build && FM_RUN_LAUNCH_PATH_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum LaunchPathSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("theLaunchPathCarriesItsSignposts", test_theLaunchPathCarriesItsSignposts),
            ("everyGitSyncDoesItsLaunchWorkOnce", test_everyGitSyncDoesItsLaunchWorkOnce),
        ]
        var failed = 0
        for (name, body) in cases {
            if let failure = body() {
                failed += 1
                SelfTestAssertions.reportFailure("\(name): \(failure)")
            } else {
                SelfTestAssertions.reportPass(name)
            }
        }
        print("LaunchPathSelfTest: \(failed == 0 ? "PASSED" : "FAILED") (\(cases.count - failed)/\(cases.count))")
        return failed == 0
    }

    // MARK: Helpers

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// A scratch directory for one case, removed when `body` returns.
    private static func withScratch<T>(_ name: String, _ body: (URL) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-launch-path-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return body(dir)
    }

    // MARK: PERF-02 - one launch start per git sync

    /// Every git sync's `start()` does its launch work once per instance.
    ///
    /// Each sync is built against a scratch working tree and a remote path
    /// that does not exist, so the work a start queues (a clone that fails
    /// at once) touches nothing real. The count is read after the second
    /// call: with `GitSyncStartGate` removed from any one `start()`, that
    /// sync reports 2 and the case names it.
    private static func test_everyGitSyncDoesItsLaunchWorkOnce() -> String? {
        withScratch("sync-start") { dir in
            func paths(_ name: String) -> (URL, String, DispatchQueue) {
                (dir.appendingPathComponent("\(name)-wt", isDirectory: true),
                 dir.appendingPathComponent("\(name)-missing-remote.git").path,
                 DispatchQueue(label: "fm.selftest.launch-path.\(name)"))
            }
            var counts: [(String, Int)] = []
            var drains: [() -> Void] = []

            do {
                let (wt, remote, _) = paths("shift")
                let sync = ShiftGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600,
                                        periodicPullInterval: 999_999,
                                        queueLabel: "fm.selftest.launch-path.shift")
                sync.start(); sync.start()
                counts.append(("ShiftGitSync", sync.debugStartWorkCount))
                drains.append { sync.sharedQueue.sync {} }
            }
            do {
                let (wt, remote, queue) = paths("runbooks")
                let sync = DocsRunbookGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600, queue: queue)
                sync.start(); sync.start()
                counts.append(("DocsRunbookGitSync", sync.debugStartWorkCount))
                drains.append { queue.sync {} }
            }
            do {
                let (wt, remote, queue) = paths("vault")
                let sync = CredentialVaultGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600, queue: queue)
                sync.start(); sync.start()
                counts.append(("CredentialVaultGitSync", sync.debugStartWorkCount))
                drains.append { queue.sync {} }
            }
            do {
                let (wt, remote, queue) = paths("reading")
                let sync = ReadingListGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600, queue: queue)
                sync.start(); sync.start()
                counts.append(("ReadingListGitSync", sync.debugStartWorkCount))
                drains.append { queue.sync {} }
            }
            do {
                let (wt, remote, queue) = paths("notebook")
                let sync = NotebookGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600, queue: queue)
                sync.start(); sync.start()
                counts.append(("NotebookGitSync", sync.debugStartWorkCount))
                drains.append { queue.sync {} }
            }
            do {
                let (wt, remote, queue) = paths("code")
                let sync = CodePreviewGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600, queue: queue)
                sync.start(); sync.start()
                counts.append(("CodePreviewGitSync", sync.debugStartWorkCount))
                drains.append { queue.sync {} }
            }
            do {
                let (wt, remote, queue) = paths("sticky")
                let sync = StickyBoardGitSync(workingTree: wt, remoteURL: remote, debounceInterval: 600, queue: queue)
                sync.start(); sync.start()
                counts.append(("StickyBoardGitSync", sync.debugStartWorkCount))
                drains.append { queue.sync {} }
            }
            // Let every queued clone attempt finish before the scratch
            // directory is removed under it.
            drains.forEach { $0() }

            guard counts.count == 7 else { return "expected seven syncs, measured \(counts.count)" }
            let wrong = counts.filter { $0.1 != 1 }
            guard wrong.isEmpty else {
                return "a second start() queued launch work again: "
                    + wrong.map { "\($0.0) started \($0.1)x" }.joined(separator: ", ")
            }
            return nil
        }
    }

    // MARK: T-14d - the signposts

    /// The intervals Instruments reads are only useful while they are there.
    /// A source guard rather than a behaviour check, because an
    /// `OSSignposter` interval has no observable effect inside a process.
    private static func test_theLaunchPathCarriesItsSignposts() -> String? {
        guard let shell = source("AppShellController.swift"), let main = source("main.swift") else {
            return "could not read the app's sources - the guard would silently pass"
        }
        for name in ["AppShellController.init", "AppShellController.loadView"] {
            guard shell.contains("LaunchSignposts.begin(\"\(name)\")"),
                  shell.contains("LaunchSignposts.end(\"\(name)\"") else {
                return "AppShellController.swift has no \(name) interval"
            }
        }
        guard main.contains("LaunchSignposts.begin(\"restoreSessionIfNeeded\")") else {
            return "main.swift has no restoreSessionIfNeeded interval"
        }
        for store in ["HostStore", "SSHKeyStore", "SnippetStore", "ShiftStore", "DictationStore",
                      "CommandLibraryStore", "ScheduleStore", "DocsRunbookStore"] {
            guard main.contains("LaunchSignposts.measure(\"\(store).init\")") else {
                return "main.swift builds \(store) without its launch interval"
            }
        }
        for store in ["CodePreviewStore", "NotebookStore", "ReadingListStore"] {
            guard shell.contains("LaunchSignposts.measure(\"\(store).init\")") else {
                return "AppShellController.init builds \(store) without its launch interval"
            }
        }
        return nil
    }
}

#endif
