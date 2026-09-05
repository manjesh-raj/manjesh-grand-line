// Manjesh Grand Line - native macOS app.
//
// Section 3 of `data/grandline-full-app-audit/report.md` - the standing
// per-session energy costs. Run with:
//
//   swift build && FM_RUN_AUDIT_ENERGY_FIXES_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
//   3.1  SRELeadBridge is event-driven, and its timer only runs fast while a
//        command is genuinely in flight
//   3.2  KubeContextBridge never refreshes - and never wakes - for a page
//        nobody is looking at, and waits one-shot for the next attempt rather
//        than spinning at 3.3Hz through a 300s window
//   3.4  every repeating timer in the app sets a `Timer.tolerance`
//   3.5  the per-task `fm-crew-state.sh` fan-out is coalesced across
//        simultaneous callers
//
// What is pinned is the *rule* in each case, never a stopwatch - a loaded
// machine makes a timing assertion flaky and it would say nothing about why.
// 3.1's and 3.2's own behavioural halves live in `SRELeadBridgeSelfTest` and
// `KubeContextBridgeSelfTest`, next to the fakes and harnesses those two
// bridges already have; this file owns the two findings with no existing home
// plus the cross-file source guards.
//
// Not window-backed: every case here is either pure logic or a source read.

#if FM_SELFTESTS

import Foundation

enum AuditEnergyFixesSelfTest {
    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("3.4_everyRepeatingTimerSetsATolerance", test_34_tolerance),
            ("3.5_simultaneousCallersCoalesceOntoOneSweep", test_35_coalesce),
            ("3.5_aHitInsideTheWindowIsReusedAndForceBypassesIt", test_35_window),
            ("3.5_theWindowIsShorterThanFleetNotifiersOwnPoll", test_35_shorterThanPoll),
            ("3.5_parseTasksGoesThroughTheCacheAndManualRefreshForces", test_35_sources),
            ("3.1_bridgeIsEventDrivenNotAPermanentFastPoll", test_31_sources),
            ("3.2_periodicRefreshIsGatedOnVisibilityAtTheAttempt", test_32_sources),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "AuditEnergyFixesSelfTest: all \(cases.count) cases passed"
              : "AuditEnergyFixesSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: 3.4 - kernel timer coalescing

    /// Every `Timer` this app schedules must set a tolerance. A
    /// zero-tolerance repeating timer is a hard wake-up the kernel cannot
    /// batch with anything else, which is precisely the cost 3.4 measured
    /// across the eight sites that had none.
    ///
    /// A *count* comparison rather than a per-site pattern match, because the
    /// interesting regression is "a new timer was added without one" and a
    /// new timer is by definition a site this test has never seen.
    private static func test_34_tolerance() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return "could not enumerate the app sources"
        }
        var offenders: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scheduled = occurrences(of: "Timer.scheduledTimer", in: text)
                + occurrences(of: "Timer(timeInterval", in: text)
            guard scheduled > 0 else { continue }
            let tolerances = occurrences(of: ".tolerance =", in: text)
            if tolerances < scheduled {
                offenders.append("\(file.lastPathComponent) schedules \(scheduled) timer(s) but sets \(tolerances) tolerance(s)")
            }
        }
        guard offenders.isEmpty else {
            return "3.4 regressed - " + offenders.joined(separator: "; ")
        }
        return nil
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var idx = text.startIndex
        while let found = text.range(of: needle, range: idx..<text.endIndex) {
            count += 1
            idx = found.upperBound
        }
        return count
    }

    // MARK: 3.5 - one sweep for simultaneous askers

    /// The launch-time shape: three independent callers, each on its own
    /// global queue, all asking for the identical sweep within a moment of
    /// each other. Before the coalescing window that was three real fan-outs
    /// (~3x the `fm-crew-state.sh` spawns); it must now be one.
    ///
    /// The counted `compute` closure stands in for the real fan-out
    /// deliberately: `parseTasksUncached()` shells out to the captain's own
    /// live fleet, which a self-test must never drive.
    private static func test_35_coalesce() -> String? {
        FleetTaskCache.invalidate()
        let lock = NSLock()
        var computeCount = 0
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let compute: () -> [FleetTask] = {
            lock.lock(); computeCount += 1; lock.unlock()
            // Hold the first caller inside the sweep so the other two are
            // genuinely concurrent with it rather than arriving after it
            // finished (which the plain freshness window would also serve).
            started.signal()
            release.wait()
            return [FleetTask(id: "alpha", repo: nil, kind: "ship", pr: nil)]
        }

        var results = [Int?](repeating: nil, count: 3)
        let resultLock = NSLock()
        let group = DispatchGroup()
        for i in 0..<3 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                if i > 0 { started.wait(); started.signal() }
                let tasks = FleetTaskCache.tasks(compute: compute)
                resultLock.lock(); results[i] = tasks.count; resultLock.unlock()
            }
        }
        // Let the two waiters reach the cache, then let the producer finish.
        started.wait()
        started.signal()
        Thread.sleep(forTimeInterval: 0.2)
        // One signal per caller that could possibly be inside `compute`.
        // With coalescing exactly one is, so the extras are harmless - but
        // releasing only once would make a *missing* coalescer show up as a
        // hang rather than as the real "three sweeps instead of one" count.
        for _ in 0..<3 { release.signal() }
        guard group.wait(timeout: .now() + 10) == .success else {
            return "callers never completed - a coalescing wait is stuck (a semaphore instead of a DispatchGroup would hang exactly here)"
        }

        lock.lock(); let count = computeCount; lock.unlock()
        guard count == 1 else {
            return "three simultaneous callers ran \(count) real sweeps, expected exactly 1 - 3.5's coalescing is gone"
        }
        guard results.allSatisfy({ $0 == 1 }) else {
            return "a coalesced caller got \(results.map { $0.map(String.init) ?? "nil" }) tasks instead of the sweep's real result"
        }
        return nil
    }

    /// The window itself: a second ask inside `ttl` reuses, and an explicit
    /// Refresh always runs for real.
    private static func test_35_window() -> String? {
        FleetTaskCache.invalidate()
        var computeCount = 0
        let compute: () -> [FleetTask] = {
            computeCount += 1
            return [FleetTask(id: "alpha", repo: nil, kind: "ship", pr: nil)]
        }

        _ = FleetTaskCache.tasks(compute: compute)
        guard computeCount == 1 else { return "the first ask did not run the sweep" }
        guard FleetTaskCache.debugHasFreshEntry else { return "nothing was stored after a real sweep" }

        _ = FleetTaskCache.tasks(compute: compute)
        guard computeCount == 1 else {
            return "a second ask inside the window ran a second sweep (\(computeCount) total)"
        }

        _ = FleetTaskCache.tasks(forceRefresh: true, compute: compute)
        guard computeCount == 2 else {
            return "forceRefresh was answered from the window - the captain's own Refresh click must always run for real"
        }
        return nil
    }

    /// The load-bearing property that makes this behaviour-preserving: the
    /// window must be far shorter than `FleetNotifier`'s own poll, so every
    /// poll misses it and no state transition is ever detected later than it
    /// was before 3.5. A window that grew past the poll would silently turn a
    /// coalescer into a staleness cache.
    private static func test_35_shorterThanPoll() -> String? {
        guard FleetTaskCache.ttl < FleetNotifier.pollInterval / 2 else {
            return """
                FleetTaskCache.ttl (\(FleetTaskCache.ttl)s) is no longer comfortably \
                shorter than FleetNotifier.pollInterval (\(FleetNotifier.pollInterval)s) - \
                a poll could now be served a cached answer, which delays exactly the \
                transitions FleetNotifier exists to surface
                """
        }
        return nil
    }

    /// Source guards for the wiring the behavioural cases above cannot see:
    /// that `parseTasks` actually goes through the cache, and that both
    /// pages' explicit Refresh clicks force.
    private static func test_35_sources() -> String? {
        guard let fleet = source("FleetData.swift") else { return nil }
        guard fleet.contains("FleetTaskCache.tasks(forceRefresh: forceRefresh)") else {
            return "FleetDataSource.parseTasks no longer goes through FleetTaskCache"
        }
        // The argument, not just the call: a cache handed a hardcoded `false`
        // compiles, reads plausibly, and quietly makes every Refresh click a
        // no-op.
        for (file, needle) in [
            ("FleetController.swift", "@objc private func refreshTapped() { refresh(forceRefresh: true) }"),
            ("ReviewController.swift", "@objc private func refreshTapped() { refresh(forceRefresh: true) }"),
        ] {
            guard let text = source(file) else { return nil }
            guard text.contains(needle) else {
                return "\(file)'s Refresh button no longer forces a real sweep - it can now be answered from the coalescing window"
            }
        }
        return nil
    }

    // MARK: 3.1 / 3.2 source guards

    /// 3.1's structural half. The behavioural half - which cadence is
    /// actually scheduled, and that the watcher is installed - is in
    /// `SRELeadBridgeSelfTest`.
    private static func test_31_sources() -> String? {
        guard let text = source("SRELeadBridge.swift") else { return nil }
        guard text.contains("DispatchSource.makeFileSystemObjectSource") else {
            return "SRELeadBridge no longer watches its bridge directory - it is back to polling for requests"
        }
        guard text.contains("queue: .main") else {
            return "the bridge-directory watcher no longer delivers on the main queue, which every step of handling a request requires (AppKit/SwiftTerm)"
        }
        guard text.contains("O_EVTONLY") else {
            return "the watcher's descriptor is no longer opened O_EVTONLY"
        }
        // The idle sweep is the bounded fallback behind the watcher; without
        // it a dropped kernel event means SRE Lead hangs forever rather than
        // for one interval.
        guard text.contains("idleSafetyNetInterval") else {
            return "the watcher's safety-net sweep is gone - a dropped event would now strand a request permanently"
        }
        return nil
    }

    /// 3.2's structural half - specifically that the visibility check happens
    /// at the *attempt*, which is what makes "no command is injected into an
    /// unseen session" true even if every visibility notification is missed.
    private static func test_32_sources() -> String? {
        guard let bridge = source("KubeContextBridge.swift") else { return nil }
        guard bridge.contains("guard !shouldPauseRefreshes() else { return }") else {
            return "KubeContextBridge no longer checks visibility at the moment of a periodic attempt - a missed notification can leak a visible kubectl command into a hidden session"
        }
        guard bridge.contains("case dueAt(Date)") else {
            return "KubeContextBridge is back to a fixed repeating poll rather than a one-shot at the next attempt"
        }
        guard let console = source("ConsoleController+Tabs.swift") else { return nil }
        guard console.contains("bridge.shouldPauseRefreshes = {") else {
            return "ConsoleController no longer tells the badge whether its page is on screen, so it would never pause"
        }
        guard let controller = source("ConsoleController.swift") else { return nil }
        guard controller.contains("AppActivityState.shared.isBackgrounded") else {
            return "the console's on-screen test no longer consults the backgrounded tier - a parked app would keep typing into the captain's session"
        }
        return nil
    }
}

#endif
