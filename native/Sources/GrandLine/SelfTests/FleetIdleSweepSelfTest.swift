// Grand Line - native macOS app.
//
// R4-PERF-01 of the fourth full review: what an idle fleet costs. The review
// measured the captain's instance at 10-14 % CPU and pinned the recurring work
// on the fleet sweep running `fm-crew-state.sh` once per task every 30
// seconds, finished tasks included.
//
// No case here measures time. What a suite can assert is the work: which tasks
// a sweep spawned the script for. Every sweep below goes through the real
// `FleetDataSource` path, against a scratch firstmate home whose
// `bin/fm-crew-state.sh` is a stub that prints a canned line per task, and
// `FleetDataSource.debugTakeScriptRuns()` names each spawn.
//
// The cases, and what each would catch:
//
//   - a finished or dead task is not re-read while its files are unchanged,
//     and a live one is re-read on every sweep, as before;
//   - an append to a task's `.status` re-reads it - the case a `.meta`-only
//     key (the review's literal proposal) gets wrong, and the reason the key
//     is every file the task owns;
//   - a state-change sweep re-reads only the task whose files changed;
//   - the captain's Refresh and an expired settled reading re-read everything;
//   - the watcher's filter, and a real FSEvents stream that reports a `>>`
//     append and stays quiet for a dot-file;
//   - a burst of changes costs the notifier one sweep, and a change before
//     the launch baseline lands costs none;
//   - the watchdog tick slows down when no window is on screen (GL-13).
//
// Pure logic and a real FSEvents stream, no window, so it guards the blocking
// CI lane.
//
// Run with:
//   swift build && FM_RUN_FLEET_IDLE_SWEEP_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import CoreServices
import Foundation

enum FleetIdleSweepSelfTest {

    static func run() -> Bool {
        var ok = true
        let home = pinAScratchFirstmateHome()
        // Never write anything unless the home really is the scratch one:
        // otherwise this would be the captain's state folder.
        guard FirstmateHome.root.standardizedFileURL.path == home.standardizedFileURL.path else {
            fail("the firstmate home resolved to \(FirstmateHome.root.path) before this suite could pin a scratch one", &ok)
            return false
        }
        defer { try? FileManager.default.removeItem(at: home) }

        checkSettledReadingsAreReused(home: home, &ok)
        checkTheSettledClassification(&ok)
        checkTheWatcherFilter(&ok)
        checkARealStreamReportsAnAppend(home: home, &ok)
        checkABurstCostsOneSweep(&ok)
        checkTheTickSlowsDownWithNoWindowOnScreen(&ok)

        print("FleetIdleSweepSelfTest: \(ok ? "PASSED" : "FAILED")")
        return ok
    }

    // MARK: The scratch fleet

    private static let doneLine = "state: done \u{00B7} source: status-log \u{00B7} handed off to firstmate"
    private static let deadLine = "state: unknown \u{00B7} source: none \u{00B7} backend target gone: default:w5V:p2"
    private static let liveLine = "state: working \u{00B7} source: pane \u{00B7} harness busy (claude-hook)"

    private static func pinAScratchFirstmateHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-fleet-idle-home-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: home)
        for folder in ["bin", "state", "responses", "worktree"] {
            try? fm.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
        // A stub with the real script's contract: one id in, one line out.
        let stub = home.appendingPathComponent("bin/fm-crew-state.sh")
        fm.createFile(atPath: stub.path, contents: Data("""
            #!/bin/bash
            cat "$FM_HOME/responses/$1"

            """.utf8))
        let worktree = home.appendingPathComponent("worktree").path
        let gone = home.appendingPathComponent("no-such-worktree").path
        for (id, worktreePath, line) in [("torn", gone, ""), ("done", worktree, doneLine),
                                         ("dead", worktree, deadLine), ("live", worktree, liveLine)] {
            write(home, "state/\(id).meta", "worktree=\(worktreePath)\nkind=ship\nbackend=herdr\n")
            write(home, "state/\(id).status", "working [at=1793251216]: setup done\n")
            if !line.isEmpty { write(home, "responses/\(id)", line + "\n") }
        }
        write(home, "state/live.busy-state", "busy claude-hook\n")
        setenv("FM_HOME", home.path, 1)
        return home
    }

    private static func write(_ home: URL, _ path: String, _ text: String) {
        FileManager.default.createFile(atPath: home.appendingPathComponent(path).path, contents: Data(text.utf8))
    }

    private static func append(_ home: URL, _ path: String, _ text: String) {
        guard let handle = FileHandle(forWritingAtPath: home.appendingPathComponent(path).path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        handle.closeFile()
    }

    /// The spawns since the last call, sorted so a concurrent sweep's order
    /// does not matter and a duplicate still shows.
    private static func spawns() -> [String] { FleetDataSource.debugTakeScriptRuns().sorted() }

    /// What a sweep shows, one line per task, so two sweeps can be compared.
    private static func shown(_ tasks: [FleetTask]) -> [String] {
        tasks.map { "\($0.id) | \($0.state) | \($0.source) | \($0.detail) | \($0.status)" }
    }

    /// An ordinary sweep as the notifier's next tick sees it: the window long
    /// expired, every task's reading kept.
    private static func ordinarySweep() -> [FleetTask] {
        FleetTaskCache.debugExpireWindow()
        return FleetDataSource.parseTasks()
    }

    /// File modification dates have a resolution the next write can land
    /// inside; this keeps a "changed" fixture from looking unchanged.
    private static func letTheClockMove() { Thread.sleep(forTimeInterval: 1.1) }

    // MARK: Cases

    private static func checkSettledReadingsAreReused(home: URL, _ ok: inout Bool) {
        print("\n-- a settled task is not re-read while its files are unchanged --")
        FleetTaskCache.invalidate()
        _ = spawns()

        let cold = FleetDataSource.parseTasks()
        check(spawns() == ["dead", "done", "live"],
              "a cold sweep should run the script for every task but the torn-down one", &ok)
        let expected = [
            "dead | unknown | none | backend target gone: default:w5V:p2 | unknown",
            "done | done | status-log | handed off to firstmate | done",
            "live | working | pane | harness busy (claude-hook) | working",
            "torn | unknown | none | worktree gone (torn down?) | unknown",
        ]
        check(shown(cold) == expected, "the cold sweep should show the script's lines, got \(shown(cold))", &ok)

        let next = ordinarySweep()
        check(spawns() == ["live"], "the next sweep should re-read only the live task", &ok)
        check(shown(next) == expected, "a reused reading must show exactly what the script said, got \(shown(next))", &ok)

        // A `.status` append is how a crew records a transition. Change what
        // the script would say first, so the fixture can tell a reuse from a
        // re-read.
        write(home, "responses/done", "state: failed \u{00B7} source: status-log \u{00B7} gave up\n")
        _ = ordinarySweep()
        check(spawns() == ["live"], "with the files unchanged the done task should still be reused", &ok)
        letTheClockMove()
        append(home, "state/done.status", "failed [at=1793251300]: gave up\n")
        let afterAppend = ordinarySweep()
        check(spawns() == ["done", "live"], "an append to the task's .status must re-read it", &ok)
        check(afterAppend.first { $0.id == "done" }?.state == "failed",
              "the re-read should show the script's new line", &ok)

        print("\n-- a state-change sweep re-reads only the task whose files changed --")
        _ = FleetDataSource.parseTasksAfterStateChange()
        check(spawns() == [], "with no file changed a state-change sweep should run nothing", &ok)
        letTheClockMove()
        write(home, "state/live.busy-state", "idle claude-hook\n")
        _ = FleetDataSource.parseTasksAfterStateChange()
        check(spawns() == ["live"], "a changed .busy-state should re-read that task alone", &ok)

        print("\n-- the captain's Refresh and an expired reading re-read everything --")
        _ = FleetDataSource.parseTasks(forceRefresh: true)
        check(spawns() == ["dead", "done", "live"], "Refresh must reuse nothing", &ok)
        let maxAge = FleetTaskCache.settledMaxAge
        FleetTaskCache.debugSetSettledMaxAge(0)
        _ = ordinarySweep()
        FleetTaskCache.debugSetSettledMaxAge(maxAge)
        check(spawns() == ["dead", "done", "live"], "a settled reading past its age must be re-read", &ok)

        print("\n-- a task that leaves the fleet leaves the cache --")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("state/dead.meta"))
        _ = ordinarySweep()
        _ = spawns()
        check(!FleetTaskCache.debugReadingIDs.contains("dead"), "a removed task's reading should be dropped", &ok)
        write(home, "state/dead.meta", "worktree=\(home.appendingPathComponent("worktree").path)\nkind=ship\n")
        FleetTaskCache.invalidate()
    }

    private static func checkTheSettledClassification(_ ok: inout Bool) {
        print("\n-- which readings count as settled --")
        func reading(_ state: String, _ source: String, _ detail: String) -> FleetCrewReading {
            FleetCrewReading(state: state, source: source, detail: detail)
        }
        let settled = [
            reading("done", "status-log", "handed off"),
            reading("done", "run-step", "passed"),
            reading("failed", "run-step", "tests failed"),
            reading("unknown", "none", "backend target gone: default:w5V:p2"),
            reading("unknown", "none", "backend target gone: default:w5V:p2 (agent gone, pane shell remains)"),
            reading("unknown", "none", "no backend target recorded"),
            reading("unknown", "none", "worktree gone (torn down?)"),
        ]
        let live = [
            reading("working", "pane", "harness busy (claude-hook)"),
            reading("parked", "run-step", "awaiting approval"),
            reading("blocked", "status-log", "daemon socket down"),
            reading("paused", "status-log", "waiting on CI"),
            reading("unknown", "none", "backend unreachable (herdr endpoint state: timeout)"),
            reading("unknown", "pane", "harness state unavailable (no record)"),
            reading("unknown", "run-step", "selected run unreadable; run ids: 1"),
            reading("unknown", "none", "no current-state source available"),
        ]
        for item in settled where !FleetTaskCache.isSettled(item) {
            fail("\(item.state) / \(item.source) / \(item.detail) should be settled", &ok)
        }
        for item in live where FleetTaskCache.isSettled(item) {
            fail("\(item.state) / \(item.source) / \(item.detail) must be read again on every sweep", &ok)
        }
    }

    private static func checkTheWatcherFilter(_ ok: inout Bool) {
        print("\n-- the watcher wakes the notifier only for a task's own files --")
        let state = "/Users/captain/firstmate/state"
        let known: Set<String> = ["grandline-review4-archperf-1793251195"]
        func relevant(_ path: String, flags: FSEventStreamEventFlags = 0) -> Bool {
            FleetStateWatcher.isRelevant(paths: [path], flags: [flags], stateDirectory: state, knownTaskIDs: known)
        }
        let task = "\(state)/grandline-review4-archperf-1793251195"
        check(relevant("\(task).status"), "a known task's .status should wake it", &ok)
        check(relevant("\(task).busy-state"), "a known task's .busy-state should wake it", &ok)
        check(relevant("\(task).inbox/001.msg"), "a message in a known task's inbox should wake it", &ok)
        check(relevant("\(state)/brand-new-task-1793260000.meta"), "a new task's .meta should wake it", &ok)
        check(!relevant("\(state)/.contributions.lock.owner.u5EaMv"), "firstmate's own dot-file churn must not", &ok)
        check(!relevant("\(state)/procevent/1793251216.json"), "a file in firstmate's own subfolder must not", &ok)
        check(!relevant("\(state)/someone-else-1790000000.status"), "an unknown task's .status must not", &ok)
        check(!relevant("/Users/captain/firstmate/data/\(known.first!).status"), "a path outside state/ must not", &ok)
        check(relevant("\(state)/.x", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)),
              "a delivery that dropped events should wake it", &ok)
    }

    private static func checkARealStreamReportsAnAppend(home: URL, _ ok: inout Bool) {
        print("\n-- a real FSEvents stream reports a >> append, and not a dot-file --")
        var fired = 0
        let watcher = FleetStateWatcher(stateDirectory: FirstmateHome.state) { fired += 1 }
        watcher.setKnownTaskIDs(["live", "done", "dead", "torn"])
        guard watcher.start() else {
            fail("FSEvents refused to watch the scratch state folder", &ok)
            return
        }
        defer { watcher.stop() }
        // The previous case's own writes can reach a stream that started just
        // after them, so let one full delivery go by before counting.
        spin(FleetStateWatcher.latency + 1.5)
        fired = 0
        write(home, "state/.watch.lock.owner.ab12cd", "123\n")
        spin(FleetStateWatcher.latency + 1.5)
        check(fired == 0, "a dot-file write should not wake the notifier, it fired \(fired) time(s)", &ok)
        append(home, "state/live.status", "needs-decision [at=1793251400]: which option\n")
        let deadline = Date().addingTimeInterval(10)
        while fired == 0, Date() < deadline { spin(0.1) }
        check(fired > 0, "an append to a known task's .status should wake the notifier within 10s", &ok)
    }

    private static func checkABurstCostsOneSweep(_ ok: inout Bool) {
        print("\n-- a burst of state-file changes costs one sweep --")
        let notifier = FleetNotifier.shared
        // Before `start()`'s baseline lands, a sweep would banner every
        // decision already open at launch, so a change must not cost one.
        let unprimed = notifier.debugStateChangeSweeps
        for _ in 0..<3 { notifier.stateFilesChanged() }
        spin(FleetNotifier.stateChangeSettle + 1.5)
        check(notifier.debugStateChangeSweeps == unprimed,
              "a change before the launch baseline should not sweep, it cost "
              + "\(notifier.debugStateChangeSweeps - unprimed)", &ok)
        notifier.debugPrimeBaseline()
        let before = notifier.debugStateChangeSweeps
        for _ in 0..<5 { notifier.stateFilesChanged() }
        let deadline = Date().addingTimeInterval(10)
        while notifier.debugStateChangeSweeps == before, Date() < deadline { spin(0.1) }
        spin(FleetNotifier.stateChangeSettle + 1)
        check(notifier.debugStateChangeSweeps - before == 1,
              "five changes in a burst should cost one sweep, cost \(notifier.debugStateChangeSweeps - before)", &ok)
    }

    private static func checkTheTickSlowsDownWithNoWindowOnScreen(_ ok: inout Bool) {
        print("\n-- the watchdog tick slows down when no window is on screen (GL-13) --")
        typealias Presence = AppActivityState.WindowPresence
        let shown = Presence(isVisible: true, canBecomeMain: true, isUnoccluded: true)
        let covered = Presence(isVisible: true, canBecomeMain: true, isUnoccluded: false)
        let minimised = Presence(isVisible: false, canBecomeMain: true, isUnoccluded: false)
        let statusItem = Presence(isVisible: true, canBecomeMain: false, isUnoccluded: true)
        check(AppActivityState.anyWindowOnScreen([statusItem, shown]), "a shown main window is on screen", &ok)
        check(!AppActivityState.anyWindowOnScreen([covered, minimised]), "covered and minimised are not", &ok)
        check(!AppActivityState.anyWindowOnScreen([statusItem]), "a menu-bar item's window is not", &ok)
        check(!AppActivityState.anyWindowOnScreen([]), "no window at all is not", &ok)
        check(FleetNotifier.shouldSlowDown(backgrounded: false, windowOnScreen: false), "no window slows the tick", &ok)
        check(FleetNotifier.shouldSlowDown(backgrounded: true, windowOnScreen: true), "backgrounded slows it", &ok)
        check(!FleetNotifier.shouldSlowDown(backgrounded: false, windowOnScreen: true),
              "a frontmost, visible app runs every tick", &ok)
        // The decision above is only worth something if the tick asks it.
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("FleetNotifier.swift"), encoding: .utf8),
              let poll = source.range(of: "private func poll()") else {
            print("  SKIP: FleetNotifier.swift not found - the tick's own wiring is unchecked")
            return
        }
        let body = String(source[poll.lowerBound...].prefix(600))
        check(body.contains("windowOnScreen: AppActivityState.shared.hasWindowOnScreen")
              && body.contains("backgroundedGate.shouldRun(backgrounded: slow)"),
              "FleetNotifier.poll() no longer slows its tick when no window is on screen", &ok)
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

#endif
