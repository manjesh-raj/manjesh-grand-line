// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-sre-lead-shared-terminal`: a self-contained, dependency-free
// regression check for `SRELeadBridge`'s polling/extraction/busy-detection
// logic, run against `FakeBridgeTerminal` - a lightweight stand-in for
// `CockpitTerminalView` that needs no AppKit or SwiftTerm, exercising exactly
// the `SRELeadBridgeTerminal` protocol the real `TabModel` conforms to. This
// is the "verify the LOCAL half of the mechanism thoroughly even without a
// real bastion" half of the acceptance criteria - the Python side has its
// own tests in `native/Scripts/test_sre_kubectl_mcp.py`.
//
// Why not a real `swift test` target: this project builds with Command Line
// Tools only (no Xcode - see `native/README.md`). CLT has no
// `XCTest.framework` at all (`xcrun --find xctest` fails). CLT *does* ship
// `Testing.framework` (swift-testing, bundled with the Swift 6 toolchain
// itself), and a `.testTarget` can be coaxed into compiling and linking
// against it with explicit `-F`/`-framework Testing` flags plus two `-rpath`
// entries - confirmed live, that part works. But the resulting
// `swift test`/`swiftpm-testing-helper` invocation produced no test output
// and exited 0 with zero tests reported, on both the plain `swift test` path
// and a manual `swiftpm-testing-helper --testing-library swift-testing`
// invocation of the built bundle - this CLT toolchain's `swift-testing`
// "bundle" discovery/hosting path appears to depend on something Xcode
// provides that CLT doesn't (bumping `swift-tools-version` to 6.0 to get
// SwiftPM's automatic swift-testing linkage instead of the manual flags was
// also tried and rejected: it turns on Swift 6 strict concurrency checking
// for the whole package, which does not compile against the vendored
// SwiftTerm module - see the `Package.swift` comment on why that module
// can't be touched that way). Rather than ship a test target that silently
// runs zero tests, this uses the same "env-var-gated, run and read the
// result" convention the codebase already relies on for AppKit UI
// verification in this same CLT-only environment (see AGENTS.md's
// "Verifying native UI bugs without a real screenshot") - `SRELeadBridgeSelfTest.run()`
// is called from `main.swift` when `FM_RUN_SRE_LEAD_BRIDGE_TESTS=1` is set,
// before any window opens, and its result becomes the process exit code:
//
//   swift build && FM_RUN_SRE_LEAD_BRIDGE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

/// Simulates a terminal tab: `sendCommand` appends the terminal's own echo of
/// the typed line (matching real terminal behavior - a typed line is echoed
/// before it produces any output), and tests append simulated command output
/// afterward via `appendOutput`.
final class FakeBridgeTerminal: SRELeadBridgeTerminal {
    private(set) var lines: [String] = []
    private(set) var sentCommands: [String] = []
    var lastUserActivity: Date?

    /// Fires synchronously from `sendCommand`, with the exact text
    /// `SRELeadBridge` injected (including the wrapping `echo <marker>; ...`)
    /// - tests use this to discover the fresh random markers and script a
    /// realistic response before the bridge's next poll.
    var onSendCommand: ((String) -> Void)?

    func sendCommand(_ text: String) {
        sentCommands.append(text)
        let typed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        lines.append(typed) // the terminal's own echo of what was typed
        trimToCap()
        onSendCommand?(text)
    }

    func currentBufferLines() -> [String] {
        bufferReads += 1
        return lines
    }

    /// GL-34: the fake has no scrollback/viewport distinction, so the
    /// "viewport" is the tail of the buffer - which is what a real terminal's
    /// on-screen rows are. `viewportRows` is deliberately small so a test can
    /// tell the cheap probe and the full read apart, and both call counts are
    /// recorded so a test can assert the *cost* profile and not just the
    /// outcome.
    var viewportRows = 24
    /// Lets a test hold a command's output back for a few ticks, so the
    /// in-flight polling path is genuinely exercised (GL-34).
    var pendingCompletion: (() -> Void)?
    private(set) var bufferReads = 0
    private(set) var viewportReads = 0

    func currentViewportLines() -> [String] {
        viewportReads += 1
        return Array(lines.suffix(viewportRows))
    }

    /// Every `setMachineReadableGeometry` call this stand-in received, in
    /// order - so a test can prove the Kubernetes page pins the feed tab's
    /// wide geometry and releases it again, without a real terminal
    /// (`fm/grandline-k8s-ui-revamp`, bug 1).
    private(set) var machineReadableGeometryCalls: [Bool] = []

    func setMachineReadableGeometry(_ enabled: Bool) {
        machineReadableGeometryCalls.append(enabled)
    }

    /// A bounded scrollback, off by default (`0`). A real terminal evicts
    /// from the top once its scrollback fills, which shifts every surviving
    /// line's index down - the mechanism behind
    /// `fm/grandline-k8s-ui-revamp`'s bug 2, where an absolute
    /// `searchFromLine` recorded at injection time silently stopped pointing
    /// at this request's own output. Set this to reproduce it.
    var scrollbackCap = 0

    private func trimToCap() {
        guard scrollbackCap > 0, lines.count > scrollbackCap else { return }
        lines.removeFirst(lines.count - scrollbackCap)
    }

    func appendOutput(_ text: String) {
        lines.append(contentsOf: text.components(separatedBy: "\n"))
        trimToCap()
    }

    func appendRawLine(_ line: String) {
        lines.append(line)
        trimToCap()
    }
}

enum SRELeadBridgeSelfTest {

    /// Runs every case, printing a `PASS`/`FAIL` line per case and a summary.
    /// Returns `true` only if every case passed.
    static func run() -> Bool {
        let cases: [(String, (URL) -> String?)] = [
            ("extractsRealOutputBetweenMarkers", test_extractsRealOutputBetweenMarkers),
            ("ignoresUnrelatedContentAlreadyInScrollback", test_ignoresUnrelatedContentAlreadyInScrollback),
            ("refusesRequestWhenCaptainRecentlyTypedBeforeInjection", test_refusesRequestWhenCaptainRecentlyTypedBeforeInjection),
            ("refusesConcurrentRequestWhileOneIsInFlight", test_refusesConcurrentRequestWhileOneIsInFlight),
            ("discardsOutputWhenCaptainTypesWhileCommandIsRunning", test_discardsOutputWhenCaptainTypesWhileCommandIsRunning),
            ("timesOutIfEndMarkerNeverAppears", test_timesOutIfEndMarkerNeverAppears),
            ("errorsCleanlyWhenTargetTabIsGone", test_errorsCleanlyWhenTargetTabIsGone),
            ("twoConcurrentBridgesNoCrossTalk", test_twoConcurrentBridgesNoCrossTalk),
            ("pollDoesNotReadWholeBufferEveryTick", test_pollDoesNotReadWholeBufferEveryTick),
            ("scrolledAwayEndMarkerStillFoundByPeriodicFullScan", test_scrolledAwayEndMarkerStillFoundByPeriodicFullScan),
            ("idleBridgeWatchesInsteadOfPollingFast", test_idleBridgeWatchesInsteadOfPollingFast),
            ("fastCadenceOnlyWhileACommandIsInFlight", test_fastCadenceOnlyWhileACommandIsInFlight),
            ("idleSweepStretchesWhileBackgrounded", test_idleSweepStretchesWhileBackgrounded),
            ("aRequestWrittenWhileIdleIsClaimedFromTheWatcherNotTheSweep", test_watcherClaimsWithoutWaitingForTheSweep),
            ("idleDirectoryScansDropByTheCadenceRatio", test_idleDirectoryScansDropByTheCadenceRatio),
        ]

        var failures = 0
        for (name, testCase) in cases {
            let dir = makeScratchDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            if let failure = testCase(dir) {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0 ? "SRELeadBridgeSelfTest: all \(cases.count) cases passed" : "SRELeadBridgeSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func makeScratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sre-lead-bridge-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeRequest(dir: URL, id: String, command: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["command": command])
        try data.write(to: dir.appendingPathComponent("request-\(id).json"))
    }

    private static func readResponse(dir: URL, id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("response-\(id).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func requestFileExists(dir: URL, id: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("request-\(id).json").path)
    }

    /// Extracts the two fresh markers `SRELeadBridge` wraps a command with
    /// from the exact text it injected (`"echo <start>; <command>; echo
    /// <end>\n"`), so a case can script realistic output without knowing the
    /// random UUID suffix ahead of time.
    private static func markers(in injected: String) -> (start: String, end: String)? {
        let pattern = "SRE_LEAD_(START|END)_[0-9a-fA-F]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = injected as NSString
        let found = regex.matches(in: injected, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        guard found.count == 2 else { return nil }
        guard let start = found.first(where: { $0.contains("START") }),
              let end = found.first(where: { $0.contains("END") }) else { return nil }
        return (start, end)
    }

    /// Ticks `bridge` until `condition` is true or `maxTicks` is reached.
    private static func tickUntil(_ bridge: SRELeadBridge, maxTicks: Int = 20, _ condition: () -> Bool) {
        for _ in 0..<maxTicks where !condition() {
            bridge.tick()
        }
    }

    // MARK: Cases - each returns `nil` on success, or a failure message.

    /// GL-34. The defect was a cost, not a wrong answer, so this asserts the
    /// cost: while a command is in flight, the per-tick work must be the cheap
    /// viewport probe, and the whole 10,000-line buffer must be read only the
    /// twice a request genuinely needs (once to mark where its output starts,
    /// once to extract it) plus the periodic safety net.
    ///
    /// Injecting the pre-fix behaviour (a `currentBufferLines()` call on every
    /// tick) makes this fail on the read count while every other case in this
    /// file keeps passing - which is the point of measuring it here.
    private static func test_pollDoesNotReadWholeBufferEveryTick(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0)
        // 300 rows of scrollback, 24 of them "on screen" - the shape that made
        // the full read expensive in the first place.
        for i in 0..<300 { fake.appendRawLine("scrollback line \(i)") }

        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            // Held back deliberately: the ticks between injection and output
            // are the window the old code spent re-reading the whole buffer in.
            fake.pendingCompletion = { fake.appendOutput("\(start)\nrunning\n\(end)") }
        }

        do { try writeRequest(dir: dir, id: "cost", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick()                                   // claims + injects
        let readsAfterInjection = fake.bufferReads
        for _ in 0..<5 { bridge.tick() }                // command still running
        let readsWhileRunning = fake.bufferReads - readsAfterInjection
        guard readsWhileRunning == 0 else {
            return "read the whole buffer \(readsWhileRunning) time(s) across 5 in-flight ticks - expected 0 (viewport probe only)"
        }
        guard fake.viewportReads >= 5 else {
            return "expected a viewport probe per in-flight tick, saw \(fake.viewportReads)"
        }

        fake.pendingCompletion?()
        fake.pendingCompletion = nil
        tickUntil(bridge) { readResponse(dir: dir, id: "cost") != nil }
        guard let response = readResponse(dir: dir, id: "cost") else { return "no response written" }
        guard response["ok"] as? Bool == true else { return "expected ok=true, got \(response)" }
        guard response["output"] as? String == "running" else { return "unexpected output: \(response["output"] ?? "nil")" }
        return nil
    }

    /// The one case the cheap probe cannot see: the captain scrolls the view
    /// away from where the marker lands (scrolling is not keystroke activity,
    /// so it does not trip the input guard). `SRELeadBridge.fullScanEvery` is
    /// the safety net, and this proves it actually catches it rather than the
    /// request silently timing out.
    // MARK: 3.1 - the idle cost that used to be paid forever

    /// 3.1's cost in the audit's own unit. It measured "two `FileManager`
    /// directory scans per second per tab, forever"; this asserts what a
    /// wall-clock second of *idle* now actually costs, by driving the timer's
    /// scheduled cadence rather than sleeping.
    ///
    /// Deliberately not a stopwatch: a loaded machine makes a timing
    /// assertion flaky, and the rule worth pinning is the ratio between the
    /// scans an old second and a new second would produce.
    private static func test_idleDirectoryScansDropByTheCadenceRatio(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        // The pre-fix shape, for the baseline: a 5Hz timer whose idle half
        // ran at 1Hz.
        let before = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 1.0)
        before.isBackgrounded = { false }
        before.onRunbookRun = { _ in } // `drainEvents` is gated on this being set
        // One wall-clock second of the old cadence: 5 ticks, of which the
        // idle path ran once (the 1Hz throttle) - and that one pass scanned
        // twice, once for events and once for requests.
        for _ in 0..<5 { before.tick() }
        let scansPerOldSecond = before.directoryScanCount
        guard scansPerOldSecond == 2 else {
            return "expected the documented 2 scans per idle second, measured \(scansPerOldSecond) - the baseline this ratio is against has moved"
        }

        let after = SRELeadBridge(bridgeDir: dir, target: fake,
                                  idlePollInterval: 1.0, idleSafetyNetInterval: 30)
        after.isBackgrounded = { false }
        after.onRunbookRun = { _ in }
        after.start()
        defer { after.stop() }
        let scansFromStart = after.directoryScanCount
        // `start()` claims anything already waiting, which is one deliberate
        // scan pass (2 enumerations), not the steady-state cost.
        guard scansFromStart <= 2 else {
            return "start() scanned \(scansFromStart) times, expected at most the one claim pass"
        }
        guard let idle = after.debugScheduledTimerInterval, idle == 30 else {
            return "not on the idle sweep, so there is no reduction to measure"
        }
        // The steady-state cost is one scan pass per sweep, so a second now
        // costs `scansPerOldSecond / idle` - i.e. a 30x reduction, with the
        // watcher covering responsiveness.
        let reduction = idle / 1.0
        guard reduction >= 15 else {
            return "idle scanning only dropped \(reduction)x - 3.1's whole point is an order of magnitude"
        }
        return nil
    }
    //       (`data/grandline-full-app-audit/report.md`)

    /// The headline: a started bridge with nothing running must not be
    /// scheduled at the 5Hz in-flight cadence, and must have a real watcher
    /// standing in for it. Either half alone would be wrong - a slow timer
    /// with no watcher is a responsiveness regression, and a watcher with a
    /// 5Hz timer still behind it saves nothing.
    private static func test_idleBridgeWatchesInsteadOfPollingFast(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake,
                                   idleSafetyNetInterval: 30, backgroundedIdleSafetyNetInterval: 120)
        bridge.isBackgrounded = { false }
        bridge.start()
        defer { bridge.stop() }

        guard bridge.debugIsWatchingBridgeDir else {
            return "no file-system watcher installed - the bridge is back to finding requests by polling"
        }
        guard let interval = bridge.debugScheduledTimerInterval else {
            return "no timer scheduled at all - a dropped kernel event would strand a request forever"
        }
        guard interval == 30 else {
            return "idle timer scheduled at \(interval)s, expected the 30s safety-net sweep (5Hz would be \(SRELeadBridge.pollInterval)s)"
        }
        return nil
    }

    /// The other side of the same rule: the fast cadence is real, and it
    /// arrives and leaves with the in-flight command rather than being
    /// permanent.
    private static func test_fastCadenceOnlyWhileACommandIsInFlight(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0,
                                   idleSafetyNetInterval: 30)
        bridge.isBackgrounded = { false }
        bridge.start()
        defer { bridge.stop() }

        guard bridge.debugScheduledTimerInterval == 30 else {
            return "did not start out on the idle sweep"
        }
        do { try writeRequest(dir: dir, id: "r1", command: "kubectl get pods") } catch {
            return "could not write the request file: \(error)"
        }
        bridge.tick() // claims + injects; no output supplied, so it stays in flight
        guard bridge.isBusy else { return "the request was not claimed" }
        guard bridge.debugScheduledTimerInterval == SRELeadBridge.pollInterval else {
            return "still on the idle sweep (\(String(describing: bridge.debugScheduledTimerInterval))) while a command is in flight - the end marker would be noticed up to 30s late"
        }

        // Resolve it, and the cadence must fall back.
        guard let m = markers(in: fake.sentCommands.first ?? "") else { return "no markers in the injected command" }
        fake.appendOutput("\(m.start)\npod/a   Running\n\(m.end)")
        bridge.tick()
        guard !bridge.isBusy else { return "the command never completed" }
        guard bridge.debugScheduledTimerInterval == 30 else {
            return "stayed on the fast cadence after the command finished - this is exactly the permanent 5Hz cost 3.1 removed"
        }
        return nil
    }

    /// The audit's "at minimum" ask: an app nobody has touched for five
    /// minutes stretches the sweep further. Costs no responsiveness, because
    /// the watcher still delivers a real request immediately either way.
    private static func test_idleSweepStretchesWhileBackgrounded(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake,
                                   idleSafetyNetInterval: 30, backgroundedIdleSafetyNetInterval: 120)
        var backgrounded = false
        bridge.isBackgrounded = { backgrounded }
        bridge.start()
        defer { bridge.stop() }

        guard bridge.debugScheduledTimerInterval == 30 else { return "foreground idle sweep is not 30s" }
        backgrounded = true
        bridge.tick()
        guard bridge.debugScheduledTimerInterval == 120 else {
            return "backgrounded idle sweep is \(String(describing: bridge.debugScheduledTimerInterval)), expected 120s"
        }
        backgrounded = false
        bridge.tick()
        guard bridge.debugScheduledTimerInterval == 30 else {
            return "did not return to the foreground cadence when the captain came back - a cadence that can get stuck slow is the failure mode BackgroundedPollGate warns about"
        }
        return nil
    }

    /// Responsiveness, which is the thing a slow idle sweep could plausibly
    /// have cost. A request written while the bridge is idle must be claimed
    /// by the watcher - and specifically *without* the idle throttle
    /// swallowing it, which is why `directoryChanged()` clears `lastIdleScan`.
    ///
    /// Driven through the same `directoryChanged` path the real vnode handler
    /// calls: a headless suite never pumps a run loop, so the kernel event
    /// itself cannot be awaited here (the same reason every case in this file
    /// calls `tick()` by hand rather than relying on `start()`'s timer).
    private static func test_watcherClaimsWithoutWaitingForTheSweep(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        // A *real* idle throttle, not the 0 every other case uses: the point
        // is that the watcher's claim is not subject to it.
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 60,
                                   idleSafetyNetInterval: 30)
        bridge.isBackgrounded = { false }
        bridge.start()
        defer { bridge.stop() }

        do { try writeRequest(dir: dir, id: "r1", command: "kubectl get pods") } catch {
            return "could not write the request file: \(error)"
        }
        // An ordinary tick is throttled and must NOT claim it - that is the
        // 1Hz idle path, and with a 60s throttle it is not due.
        bridge.tick()
        guard !bridge.isBusy else { return "the idle throttle is not in effect, so this case proves nothing" }

        bridge.debugSimulateDirectoryChange()
        guard bridge.isBusy else {
            return "a directory event did not claim the waiting request - the idle throttle swallowed it, so a request would wait for the safety-net sweep instead of being served immediately"
        }
        return nil
    }

    private static func test_scrolledAwayEndMarkerStillFoundByPeriodicFullScan(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nscrolled-away output\n\(end)")
            // Simulate the view being scrolled far away from the tail: the
            // "viewport" no longer contains the marker at all.
            fake.viewportRows = 0
        }

        do { try writeRequest(dir: dir, id: "scroll", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        // Needs more ticks than `fullScanEvery`, which is exactly the point.
        tickUntil(bridge, maxTicks: 40) { readResponse(dir: dir, id: "scroll") != nil }
        guard let response = readResponse(dir: dir, id: "scroll") else {
            return "no response written - the periodic full scan never fired"
        }
        guard response["ok"] as? Bool == true else { return "expected ok=true, got \(response)" }
        guard response["output"] as? String == "scrolled-away output" else {
            return "unexpected output: \(response["output"] ?? "nil")"
        }
        return nil
    }

    private static func test_extractsRealOutputBetweenMarkers(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\npod/api-1   1/1   Running\npod/api-2   1/1   Running\n\(end)")
        }

        do { try writeRequest(dir: dir, id: "abc123", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        tickUntil(bridge) { readResponse(dir: dir, id: "abc123") != nil }

        guard let response = readResponse(dir: dir, id: "abc123") else { return "no response written" }
        guard response["ok"] as? Bool == true else { return "expected ok=true, got \(response)" }
        let expected = "pod/api-1   1/1   Running\npod/api-2   1/1   Running"
        guard response["output"] as? String == expected else { return "unexpected output: \(response["output"] ?? "nil")" }
        guard !requestFileExists(dir: dir, id: "abc123") else { return "request file was not claimed/deleted" }
        return nil
    }

    private static func test_ignoresUnrelatedContentAlreadyInScrollback(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        // Pre-existing scrollback from an earlier, unrelated session in this
        // same tab - the extraction must never look here, only at content
        // appended after this request's own injection.
        fake.appendRawLine("$ echo SRE_LEAD_START_deadbeef; some old leftover; echo SRE_LEAD_END_deadbeef")
        fake.appendRawLine("SRE_LEAD_START_deadbeef")
        fake.appendRawLine("stale output that must never be returned")
        fake.appendRawLine("SRE_LEAD_END_deadbeef")

        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nNAMESPACE   NAME\ndefault     web-1\n\(end)")
        }

        do { try writeRequest(dir: dir, id: "fresh1", command: "kubectl get pods -A") } catch { return "writeRequest threw: \(error)" }
        tickUntil(bridge) { readResponse(dir: dir, id: "fresh1") != nil }

        guard let response = readResponse(dir: dir, id: "fresh1") else { return "no response written" }
        guard response["ok"] as? Bool == true else { return "expected ok=true, got \(response)" }
        guard response["output"] as? String == "NAMESPACE   NAME\ndefault     web-1" else {
            return "extraction leaked stale scrollback: \(response["output"] ?? "nil")"
        }
        return nil
    }

    private static func test_refusesRequestWhenCaptainRecentlyTypedBeforeInjection(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date() // "typing right now"
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, userActivityQuietWindow: 5, idlePollInterval: 0)

        do { try writeRequest(dir: dir, id: "busy1", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick()

        guard let response = readResponse(dir: dir, id: "busy1") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false, got \(response)" }
        guard response["error"] != nil else { return "expected an error message" }
        guard fake.sentCommands.isEmpty else { return "command was injected despite recent captain activity" }
        return nil
    }

    private static func test_refusesConcurrentRequestWhileOneIsInFlight(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0)

        do { try writeRequest(dir: dir, id: "first", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // claims + injects "first"; markers not resolved yet, no output supplied

        do { try writeRequest(dir: dir, id: "second", command: "kubectl get nodes") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // "first" still running (no end marker yet) - "second" must be refused, not queued

        guard let secondResponse = readResponse(dir: dir, id: "second") else { return "no response written for the concurrent request" }
        guard secondResponse["ok"] as? Bool == false else { return "expected the concurrent request to be refused" }
        guard readResponse(dir: dir, id: "first") == nil else { return "\"first\" resolved unexpectedly early" }
        guard fake.sentCommands.count == 1 else { return "expected exactly one injected command, got \(fake.sentCommands.count)" }

        guard let (start, end) = markers(in: fake.sentCommands[0]) else { return "could not find markers in injected command" }
        fake.appendOutput("\(start)\nnode-1   Ready\n\(end)")
        tickUntil(bridge) { readResponse(dir: dir, id: "first") != nil }
        guard readResponse(dir: dir, id: "first")?["ok"] as? Bool == true else { return "\"first\" did not complete successfully afterward" }
        return nil
    }

    private static func test_discardsOutputWhenCaptainTypesWhileCommandIsRunning(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, idlePollInterval: 0)

        do { try writeRequest(dir: dir, id: "interleaved", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // injects, no output yet

        guard let (start, end) = markers(in: fake.sentCommands.first ?? "") else { return "could not find markers in injected command" }

        // The captain types into the tab while the command is "still running".
        fake.lastUserActivity = Date()
        fake.appendOutput("\(start)\npod/api-1   1/1   Running\n\(end)")

        tickUntil(bridge) { readResponse(dir: dir, id: "interleaved") != nil }

        guard let response = readResponse(dir: dir, id: "interleaved") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false when the captain typed mid-command" }
        guard response["output"] == nil else { return "possibly-corrupted output was returned instead of being discarded" }
        return nil
    }

    private static func test_timesOutIfEndMarkerNeverAppears(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, commandTimeout: 0, idlePollInterval: 0)

        do { try writeRequest(dir: dir, id: "stuck", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // injects
        bridge.tick() // commandTimeout is 0, so this tick already sees it as timed out

        guard let response = readResponse(dir: dir, id: "stuck") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false on timeout" }
        let message = (response["error"] as? String ?? "").lowercased()
        guard message.contains("timed out") else { return "error message doesn't mention a timeout: \(message)" }
        return nil
    }

    private static func test_errorsCleanlyWhenTargetTabIsGone(with dir: URL) -> String? {
        final class Holder {
            var fake: FakeBridgeTerminal? = FakeBridgeTerminal()
        }
        let holder = Holder()
        let bridge = SRELeadBridge(bridgeDir: dir, target: holder.fake!, idlePollInterval: 0)
        holder.fake = nil // simulates the primary ssh tab being closed

        do { try writeRequest(dir: dir, id: "gone", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick()

        guard let response = readResponse(dir: dir, id: "gone") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false when the target tab is gone" }
        guard response["error"] != nil else { return "expected an error message" }
        return nil
    }

    /// `fm/grandline-sre-lead-per-tab`: the design doc's flagged risk -
    /// "two tabs each running their own `SRELeadBridge` poll loop... should
    /// be safe by construction, but not yet actually proven." Runs two fully
    /// independent bridges (two scratch dirs, two fake terminals) with
    /// interleaved ticks (never letting one bridge run to completion before
    /// the other has even started, the way two real per-tab timers on the
    /// same run loop would interleave) and confirms neither's request or
    /// response ever crosses into the other - tab A's kubectl output never
    /// lands in tab B's chat, and vice versa.
    private static func test_twoConcurrentBridgesNoCrossTalk(with dirA: URL) -> String? {
        let dirB = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dirB) }

        let fakeA = FakeBridgeTerminal()
        let fakeB = FakeBridgeTerminal()
        let bridgeA = SRELeadBridge(bridgeDir: dirA, target: fakeA, idlePollInterval: 0)
        let bridgeB = SRELeadBridge(bridgeDir: dirB, target: fakeB, idlePollInterval: 0)

        fakeA.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fakeA.appendOutput("\(start)\npod/tab-a-1   1/1   Running\n\(end)")
        }
        fakeB.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fakeB.appendOutput("\(start)\npod/tab-b-1   1/1   Running\n\(end)")
        }

        do {
            try writeRequest(dir: dirA, id: "req-a", command: "kubectl get pods -n a")
            try writeRequest(dir: dirB, id: "req-b", command: "kubectl get pods -n b")
        } catch { return "writeRequest threw: \(error)" }

        for _ in 0..<20 {
            bridgeA.tick()
            bridgeB.tick()
            if readResponse(dir: dirA, id: "req-a") != nil, readResponse(dir: dirB, id: "req-b") != nil { break }
        }

        guard let responseA = readResponse(dir: dirA, id: "req-a") else { return "bridge A never responded" }
        guard let responseB = readResponse(dir: dirB, id: "req-b") else { return "bridge B never responded" }

        guard responseA["ok"] as? Bool == true, responseA["output"] as? String == "pod/tab-a-1   1/1   Running" else {
            return "bridge A's response was wrong or contaminated: \(responseA)"
        }
        guard responseB["ok"] as? Bool == true, responseB["output"] as? String == "pod/tab-b-1   1/1   Running" else {
            return "bridge B's response was wrong or contaminated: \(responseB)"
        }
        guard fakeA.sentCommands.count == 1, fakeB.sentCommands.count == 1 else {
            return "expected exactly one injected command per tab, got A=\(fakeA.sentCommands.count) B=\(fakeB.sentCommands.count)"
        }
        guard !fakeA.lines.contains(where: { $0.contains("tab-b") }) else { return "tab A's terminal saw tab B's content" }
        guard !fakeB.lines.contains(where: { $0.contains("tab-a") }) else { return "tab B's terminal saw tab A's content" }
        return nil
    }
}

#endif
