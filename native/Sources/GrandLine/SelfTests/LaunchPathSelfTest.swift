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
            ("aBackgroundLoadedStoreIsNeverReadAsEmpty", test_aBackgroundLoadedStoreIsNeverReadAsEmpty),
            ("aWriteBeforeTheFirstLoadKeepsTheFile", test_aWriteBeforeTheFirstLoadKeepsTheFile),
            ("theBackgroundFirstLoadLandsOffMain", test_theBackgroundFirstLoadLandsOffMain),
            ("aLockedWidgetPublishDoesNotReadTheBoard", test_aLockedWidgetPublishDoesNotReadTheBoard),
            ("sessionRestoreQueuesBackgroundHostPages", test_sessionRestoreQueuesBackgroundHostPages),
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

    // MARK: PERF-01 - the two YAML stores load off the main thread

    /// Runs `body` with `key` pointing at `value`, then puts it back.
    private static func withEnv<T>(_ key: String, _ value: String, _ body: () -> T) -> T {
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        return body()
    }

    /// Two notes and two links on disk, written by the synchronous test seam.
    private static func seedStores(in dir: URL) -> (notes: URL, links: URL) {
        let notes = dir.appendingPathComponent("sticky", isDirectory: true)
        let links = dir.appendingPathComponent("reading", isDirectory: true)
        let sticky = StickyBoardStore(root: notes)
        sticky.addNote(text: "first", color: .yellow, x: 10, y: 10, rotationDegrees: 0)
        sticky.addNote(text: "second", color: .blue, x: 40, y: 40, rotationDegrees: 0)
        sticky.flushPendingWrite()
        let reading = ReadingListStore(root: links)
        _ = reading.add("https://example.com/one")
        _ = reading.add("https://example.com/two")
        reading.flush()
        return (notes, links)
    }

    /// An unloaded store is not an empty one. Reading its contents before the
    /// background read lands reads the file there and then - so the canvas,
    /// ⌘K or the crew can never be handed an empty board or list.
    ///
    /// Injection: make the `notes`/`links` getters return the stored array
    /// without `ensureLoaded()` and this reports zero rows.
    private static func test_aBackgroundLoadedStoreIsNeverReadAsEmpty() -> String? {
        withScratch("never-empty") { dir in
            let (notesDir, linksDir) = seedStores(in: dir)
            return withEnv("FM_STICKY_BOARD_DIR", notesDir.path) {
                withEnv("FM_READING_LIST_DIR", linksDir.path) {
                    let sticky = StickyBoardStore(loadsInBackground: true)
                    let reading = ReadingListStore(loadsInBackground: true)
                    defer {
                        sticky.debugBackgroundReload.debugDrainQueue()
                        reading.debugBackgroundReload.debugDrainQueue()
                    }
                    guard !sticky.isLoaded, !reading.isLoaded else {
                        return "a store built with loadsInBackground had already read its file in init"
                    }
                    guard sticky.notes.count == 2 else {
                        return "an unloaded sticky board read as \(sticky.notes.count) notes, expected 2"
                    }
                    guard reading.links.count == 2 else {
                        return "an unloaded reading list read as \(reading.links.count) links, expected 2"
                    }
                    guard sticky.isLoaded, reading.isLoaded else {
                        return "reading the contents did not mark the store loaded"
                    }
                    return nil
                }
            }
        }
    }

    /// The data-loss case the whole design has to rule out: a write that
    /// lands before the first load must add to the file, never replace it
    /// with only the new record.
    private static func test_aWriteBeforeTheFirstLoadKeepsTheFile() -> String? {
        withScratch("write-first") { dir in
            let (notesDir, linksDir) = seedStores(in: dir)
            return withEnv("FM_STICKY_BOARD_DIR", notesDir.path) {
                withEnv("FM_READING_LIST_DIR", linksDir.path) {
                    let sticky = StickyBoardStore(loadsInBackground: true)
                    sticky.addNote(text: "third", color: .green, x: 70, y: 70, rotationDegrees: 0)
                    sticky.flushPendingWrite()
                    let reading = ReadingListStore(loadsInBackground: true)
                    _ = reading.add("https://example.com/three")
                    reading.flush()
                    sticky.debugBackgroundReload.debugDrainQueue()
                    reading.debugBackgroundReload.debugDrainQueue()

                    let notesOnDisk = StickyBoardStore(root: notesDir).notes.map(\.text).sorted()
                    guard notesOnDisk == ["first", "second", "third"] else {
                        return "a note added before the first load left the file holding \(notesOnDisk)"
                    }
                    let linksOnDisk = ReadingListStore(root: linksDir).links.count
                    guard linksOnDisk == 3 else {
                        return "a link added before the first load left the file holding \(linksOnDisk) links, expected 3"
                    }
                    return nil
                }
            }
        }
    }

    /// The point of it: left alone, the first load reads on the parse thread,
    /// applies on main, and tells whoever asked (`whenLoaded`) exactly once.
    /// The Home canvas re-renders its two cards from that callback.
    private static func test_theBackgroundFirstLoadLandsOffMain() -> String? {
        withScratch("lands") { dir in
            let (notesDir, linksDir) = seedStores(in: dir)
            let reads = ReadLog()
            StickyBoardStore.debugOnRead = { onMain in reads.record(onMain: onMain) }
            ReadingListStore.debugOnRead = { onMain in reads.record(onMain: onMain) }
            defer {
                StickyBoardStore.debugOnRead = nil
                ReadingListStore.debugOnRead = nil
            }
            return withEnv("FM_STICKY_BOARD_DIR", notesDir.path) {
                withEnv("FM_READING_LIST_DIR", linksDir.path) {
                    let sticky = StickyBoardStore(loadsInBackground: true)
                    let reading = ReadingListStore(loadsInBackground: true)
                    var callbacks = 0
                    sticky.whenLoaded { callbacks += 1 }
                    reading.whenLoaded { callbacks += 1 }
                    sticky.debugBackgroundReload.debugDrainQueue()
                    reading.debugBackgroundReload.debugDrainQueue()
                    let deadline = Date().addingTimeInterval(5)
                    while callbacks < 2, Date() < deadline {
                        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    }
                    guard callbacks == 2 else {
                        return "whenLoaded ran \(callbacks) time(s) for two stores"
                    }
                    guard reads.onMain == 0, reads.offMain == 2 else {
                        return "the first load read \(reads.onMain) file(s) on main and \(reads.offMain) off it, "
                            + "expected 0 and 2"
                    }
                    guard sticky.notes.count == 2, reading.links.count == 2, reads.onMain == 0 else {
                        return "the background load applied \(sticky.notes.count) notes and \(reading.links.count) links"
                    }
                    var late = 0
                    sticky.whenLoaded { late += 1 }
                    guard late == 1 else { return "whenLoaded on a loaded store did not run at once" }
                    return nil
                }
            }
        }
    }

    /// The widget publisher starts right after the launch lock, before the
    /// first frame is drawn. A locked snapshot carries no notes, so reading
    /// the board for it would be a main-thread YAML read for nothing - and
    /// would undo the background load at the one moment it matters.
    private static func test_aLockedWidgetPublishDoesNotReadTheBoard() -> String? {
        withScratch("widget") { dir in
            let (notesDir, _) = seedStores(in: dir)
            let reads = ReadLog()
            StickyBoardStore.debugOnRead = { onMain in reads.record(onMain: onMain) }
            defer { StickyBoardStore.debugOnRead = nil }
            let wasLocked = AppLockGate.shared.isLocked
            AppLockGate.shared.setLocked(true)
            defer { AppLockGate.shared.setLocked(wasLocked) }
            return withEnv("FM_STICKY_BOARD_DIR", notesDir.path) {
                let sticky = StickyBoardStore(loadsInBackground: true)
                defer { sticky.debugBackgroundReload.debugDrainQueue() }
                let shift = withEnv("FM_SHIFT_DIR", dir.appendingPathComponent("shift", isDirectory: true).path) { ShiftStore() }
                let publisher = WidgetSnapshotPublisher(
                    shiftStore: shift, stickyStore: sticky,
                    directory: dir.appendingPathComponent("widget", isDirectory: true),
                    reloadTimelines: {})
                publisher.publishNow()
                guard reads.onMain == 0, !sticky.isLoaded else {
                    return "a locked publish read the sticky board on the main thread (\(reads.onMain) read(s))"
                }
                return nil
            }
        }
    }

    /// Counts a `debugOnRead` hook's calls, which arrive on the parse thread
    /// as well as on main.
    private final class ReadLog {
        private let lock = NSLock()
        private var main = 0
        private var background = 0
        func record(onMain: Bool) {
            lock.lock(); defer { lock.unlock() }
            if onMain { main += 1 } else { background += 1 }
        }
        var onMain: Int { lock.lock(); defer { lock.unlock() }; return main }
        var offMain: Int { lock.lock(); defer { lock.unlock() }; return background }
    }

    // MARK: PERF-08 - the app delegate's half

    /// `SessionRestoreSelfTest` proves the shell's queue builds one page per
    /// turn; this proves the launch path uses it. `applicationDidFinishLaunching`
    /// cannot run in a suite, so it is a source guard on the function body.
    private static func test_sessionRestoreQueuesBackgroundHostPages() -> String? {
        guard let main = source("main.swift"),
              let start = main.range(of: "private func restoreSessionIfNeeded(") else {
            return "could not find restoreSessionIfNeeded in main.swift - the guard would silently pass"
        }
        let rest = main[start.upperBound...]
        let body = String(rest.prefix(upTo: rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex))
        guard body.contains("appShell.queueRestoredHostConsoles(") else {
            return "restoreSessionIfNeeded no longer queues the background host pages"
        }
        guard !body.contains("appShell.connectHost(") else {
            return "restoreSessionIfNeeded connects background host pages directly again"
        }
        return nil
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
        for store in ["CodePreviewStore", "NotebookStore", "ReadingListStore", "StickyBoardStore", "LogAnalyzerStore"] {
            guard shell.contains("LaunchSignposts.measure(\"\(store).init\")") else {
                return "AppShellController.init builds \(store) without its launch interval"
            }
        }
        return nil
    }
}

#endif
