// Grand Line - native macOS app.
//
// GL-29: permanent coverage for `BackgroundSignalsPoller`'s pass latch and for
// `ServiceHealthRegistry`'s verdict/threshold logic.
//
// Why the latch specifically. GL-03's shipped bug was that `isChecking` was a
// one-way door: one hung child process meant every later tick returned on
// `guard !isChecking`, and four of the Notification Center's nine signals went
// dark for the rest of the session with nothing anywhere saying so. Phase 2
// fixed it with a wall-clock watchdog and a pass id - and neither could be
// tested, because the decision was three inline lines wrapped around sixty
// subprocesses. `admit`/`mayReleaseLatch` are that decision, lifted out.
//
// Why the health registry. It is what turns a repeated failure into something
// the captain sees, and `failureThreshold` is the whole difference between
// "the network blipped once" and "this gauge is broken" - so the counter
// resetting on success is load-bearing, not incidental.
//
// Run: `FM_RUN_BACKGROUND_SIGNALS_TESTS=1 .build/debug/GrandLine`
//
// Nothing here spawns a subprocess or touches the network. The registry cases
// use a service case that no shipping code reports into during a headless run,
// so they cannot race a real reporter.

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

enum BackgroundSignalsSelfTest {

    static func run() -> Bool {
        var ok = true
        checkPassAdmission(&ok)
        checkAHungPassIsCancelledNotOverlapped(&ok)
        checkSetupCountsNeverLoadAStore(&ok)
        checkLatchRelease(&ok)
        checkHealthVerdicts(&ok)
        checkNoUnattendedAvList(&ok)
        checkVaultToolsPublish(&ok)
        checkLockScreenHasNoRetryTimer(&ok)
        checkPowerAwareCadence(&ok)
        checkPowerCadenceIsWired(&ok)
        print(ok ? "BackgroundSignalsSelfTest: all checks passed" : "BackgroundSignalsSelfTest: FAILED")
        return ok
    }


    // MARK: GL-03 - the latch

    /// REL-29: the poller counts saved hosts and snippets on its background
    /// queue. It used to build a `HostStore()` and a `SnippetStore()` there,
    /// whose load backs up an undecodable file (and chmods it) from the
    /// wrong thread while the live store owns it. The count must leave a
    /// corrupt file exactly as it found it.
    private static func checkSetupCountsNeverLoadAStore(_ ok: inout Bool) {
        print("\n-- REL-29: the setup counts read the files without loading a store --")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-rel29-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appendingPathComponent("hosts.json")
        let snippets = dir.appendingPathComponent("snippets.json")
        try? Data(#"[{"label":"truncated"#.utf8).write(to: hosts)
        try? Data(#"[{"label":"a","command":"ls"},{"label":"b","command":"pwd"}]"#.utf8).write(to: snippets)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hosts.path)

        let names = ["FM_HOSTS_FILE": hosts.path, "FM_SNIPPETS_FILE": snippets.path]
        var previous: [String: String?] = [:]
        for (key, value) in names {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        let counts = BackgroundSignalsPoller.restoredConfigCounts()
        for (key, old) in previous {
            if let old { setenv(key, old, 1) } else { unsetenv(key) }
        }

        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if siblings.contains(where: { $0.hasPrefix("hosts.json.corrupt-") }) {
            fail("REL-29: counting backed up the corrupt hosts.json - it loaded a store, got \(siblings)", &ok)
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: hosts.path)[.posixPermissions] as? NSNumber)?.intValue
        if mode != 0o644 {
            fail("REL-29: counting changed the mode of hosts.json to \(String(describing: mode).description) - it loaded a store", &ok)
        }
        if counts.hosts != 0 || counts.snippets != 2 {
            fail("REL-29: expected 0 hosts (unreadable) and 2 snippets, got \(counts)", &ok)
        }
    }

    private static func checkPassAdmission(_ ok: inout Bool) {
        print("\n-- pass admission (GL-03: the latch is not a one-way door) --")
        let watchdog: TimeInterval = 300
        let now = Date()

        // Idle: go.
        if BackgroundSignalsPoller.admit(isChecking: false, passStartedAt: nil, now: now, watchdog: watchdog) != .start {
            fail("an idle poller refused to start a pass", &ok)
        }
        // Idle but with a stale start time recorded: still go. The two are set
        // together, so this is only reachable after a release, and refusing
        // here would reintroduce the stuck latch by a different route.
        if BackgroundSignalsPoller.admit(isChecking: false, passStartedAt: now.addingTimeInterval(-9999),
                                         now: now, watchdog: watchdog) != .start {
            fail("an idle poller with a stale timestamp refused to start", &ok)
        }
        // Busy and young: the ordinary skip.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-30),
                                         now: now, watchdog: watchdog) != .refused {
            fail("a pass 30s into a 300s watchdog was cancelled - it is just slow", &ok)
        }
        // Exactly at the watchdog is still young: strictly greater, so the
        // boundary can never flap between two ticks landing on the same second.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-watchdog),
                                         now: now, watchdog: watchdog) != .refused {
            fail("the watchdog boundary is inclusive - it should need to be genuinely exceeded", &ok)
        }
        // Busy and hung: cancel it, and report how long it has been.
        switch BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-601),
                                             now: now, watchdog: watchdog) {
        case .cancelHung(let age):
            if age < 600 { fail("the hung pass reported an age of \(age)s, want ~601", &ok) }
        default:
            fail("a pass hung for 601s past a 300s watchdog was not cancelled - this is the GL-03 bug", &ok)
        }
        // Busy with no start time at all is a broken state, not a licence.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: nil, now: now, watchdog: watchdog) != .refused {
            fail("a held latch with no start time started another pass anyway", &ok)
        }
        print("  OK - idle starts, young refuses, hung is cancelled with a real age")
    }

    /// R5 energy fix 6: a hung pass is cancelled, and nothing starts beside
    /// it. The old supersede started a second pass at once, and the review's
    /// child log caught two sweeps checking the same npm package 148 s apart.
    /// Driven on the shared poller with a simulated running pass, so no real
    /// pass (and no subprocess) ever starts here.
    private static func checkAHungPassIsCancelledNotOverlapped(_ ok: inout Bool) {
        print("\n-- R5 energy fix 6: a hung pass is cancelled, never run beside --")
        let poller = BackgroundSignalsPoller.shared
        let token = poller.debugSimulateRunningPass(
            startedAt: Date().addingTimeInterval(-(BackgroundSignalsPoller.passWatchdog + 60)))
        defer { poller.debugEndSimulatedPass() }
        let passID = poller.debugCurrentPassID
        let cancelledBefore = poller.cancelledPassCount
        poller.checkNow()
        check(token.isCancelled, "the hung pass's token should be cancelled, so its running child is terminated", &ok)
        check(poller.debugCurrentPassID == passID,
              "a new pass started beside the hung one (pass id \(passID) -> \(poller.debugCurrentPassID)) - passes overlap", &ok)
        check(poller.debugPassRequestedAfterCancel,
              "the requested pass should be queued to start when the cancelled one returns", &ok)
        poller.checkNow()
        check(poller.cancelledPassCount == cancelledBefore + 1 && poller.debugCurrentPassID == passID,
              "a second request while the hung pass winds down should neither cancel again nor start a pass", &ok)
    }

    private static func checkLatchRelease(_ ok: inout Bool) {
        print("\n-- latch release (only the pass that owns it) --")
        if !BackgroundSignalsPoller.mayReleaseLatch(finishingPassID: 7, currentPassID: 7) {
            fail("the pass that owns the latch could not release it - it would stay stuck forever", &ok)
        }
        if BackgroundSignalsPoller.mayReleaseLatch(finishingPassID: 6, currentPassID: 7) {
            fail("a superseded pass released the latch out from under its replacement", &ok)
        }
        print("  OK - a superseded pass finishing cannot clear its replacement's latch")
    }

    // MARK: F1 - health verdicts

    private static func checkHealthVerdicts(_ ok: inout Bool) {
        print("\n-- service health verdicts and the failure threshold --")
        let registry = ServiceHealthRegistry.shared
        // `.docsSync` is not reported into by anything during a headless run
        // (no window, no sync started), so this cannot race a real reporter.
        let service = HealthService.docsSync

        if registry.state(service).verdict != .unknown {
            fail("a service that has never reported should read .unknown, got \(registry.state(service).verdict)", &ok)
        }
        registry.register(service)
        if registry.state(service).hasReported {
            fail("registering a service made it look like it had already reported", &ok)
        }
        if !registry.knownServices().contains(service) {
            fail("a registered service is missing from knownServices() - its row would not appear", &ok)
        }

        registry.markRunning(service)
        if registry.state(service).verdict != .running {
            fail("a running pass should read .running, got \(registry.state(service).verdict)", &ok)
        }

        registry.recordSuccess(service)
        if registry.state(service).verdict != .healthy {
            fail("a success should read .healthy, got \(registry.state(service).verdict)", &ok)
        }

        // One and two failures are "degraded"; the threshold is what escalates.
        registry.recordFailure(service, "first")
        if registry.state(service).verdict != .degraded {
            fail("one failure should read .degraded, got \(registry.state(service).verdict)", &ok)
        }
        registry.recordFailure(service, "second")
        if registry.state(service).verdict != .degraded {
            fail("two failures (threshold \(ServiceHealthRegistry.failureThreshold)) should still read .degraded", &ok)
        }
        registry.recordFailure(service, "third")
        if registry.state(service).verdict != .failing {
            fail("\(ServiceHealthRegistry.failureThreshold) failures should read .failing, got \(registry.state(service).verdict)", &ok)
        }
        if registry.state(service).lastFailureDetail != "third" {
            fail("the most recent failure detail was not retained", &ok)
        }

        // The reset is the point: "still broken" must not survive a success.
        registry.recordSuccess(service)
        if registry.state(service).consecutiveFailures != 0 {
            fail("a success did not reset the consecutive-failure count", &ok)
        }
        if registry.state(service).verdict != .healthy {
            fail("a success after crossing the threshold should read .healthy again", &ok)
        }
        if registry.state(service).lastFailureDetail != nil {
            fail("a success left a stale failure detail behind", &ok)
        }
        print("  OK - unknown -> running -> healthy -> degraded -> failing, and a success resets it")
    }

    // MARK: The approval-prompt rule - no unattended `av list`
    //
    // `av list` is the only `av` read this app makes that goes through Automic
    // Vault's approval service, so on a timer it can raise Automic Vault's own
    // modal dialog over whatever the captain is doing, unprovoked. That is a
    // property of *which function the poller calls*, and nothing behavioural
    // can see it: the poller's vault check spawns a real subprocess, so a
    // suite can neither run it nor observe which subcommand it chose.
    //
    // A source guard is therefore the only check that can fail here, and it is
    // the right shape anyway - the regression this catches is somebody
    // reaching for `loadSnapshot()` again because it is the obvious call.

    private static func checkNoUnattendedAvList(_ ok: inout Bool) {
        print("\n-- no unattended `av list` (the approval-prompt rule) --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            fail("source root not found - this check cannot run", &ok)
            return
        }
        let file = root.appendingPathComponent("BackgroundSignalsPoller.swift")
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            fail("BackgroundSignalsPoller.swift could not be read", &ok)
            return
        }
        // Discriminating power first: if the fixture ever stops being the file
        // this check thinks it is, every assertion below passes vacuously.
        check(source.contains("private func checkVault("),
              "the poller's vault check is not in this file any more - this guard is pointing at the wrong place",
              &ok)

        // `loadSnapshot` runs `av list`. Comments are stripped first, for the
        // same reason `FM_RUN_VENDORED_PATCHES_TESTS` strips them: the call
        // site is discussed at length in the comments right above it, and this
        // has to fail on the *code* coming back, not on the prose staying.
        let code = strippingComments(source)
        check(!code.contains("VaultSource.loadSnapshot"),
              "the poller calls VaultSource.loadSnapshot, which runs `av list` - that is an unattended call to the one `av` read that can raise Automic Vault's approval dialog. Use VaultSource.loadToolStatus().",
              &ok)
        check(code.contains("VaultSource.loadToolStatus"),
              "the poller no longer calls VaultSource.loadToolStatus - if the vault check was removed outright, remove this guard too and say so",
              &ok)
    }

    // MARK: R5 energy fix 5 - power-aware cadence

    /// Ticks of `period` for `hours`, each up to 30 s late (the timers'
    /// tolerance), counting the ones a cadence lets run.
    private static func runs(of cadence: PowerAwareCadence, period: TimeInterval,
                             hours: Double, reduced: Bool) -> Int {
        var cadence = cadence
        let start = Date()
        var count = 0
        var tick = 1
        while Double(tick) * period <= hours * 3600 {
            let now = start.addingTimeInterval(Double(tick) * period + Double(tick % 3) * 15)
            if cadence.isDue(now: now, reduced: reduced) {
                cadence.noteRun(at: now)
                count += 1
            }
            tick += 1
        }
        return count
    }

    private static func checkPowerAwareCadence(_ ok: inout Bool) {
        print("\n-- R5 energy fix 5: the sweep and the Tasks pull slow down on battery --")
        let sweep = PowerAwareCadence(interval: BackgroundSignalsPoller.pollInterval,
                                      reducedInterval: BackgroundSignalsPoller.reducedPowerPollInterval)
        check(BackgroundSignalsPoller.reducedPowerPollInterval == 60 * 60,
              "the battery sweep cadence should be 60 minutes, is \(BackgroundSignalsPoller.reducedPowerPollInterval)s", &ok)
        let sweepAC = runs(of: sweep, period: BackgroundSignalsPoller.pollInterval, hours: 4, reduced: false)
        let sweepBattery = runs(of: sweep, period: BackgroundSignalsPoller.pollInterval, hours: 4, reduced: true)
        check(sweepAC == 16, "on AC the sweep should run every 15-minute tick: 16 in 4 hours, got \(sweepAC)", &ok)
        check(sweepBattery == 4, "on battery the sweep should run hourly: 4 in 4 hours, got \(sweepBattery)", &ok)

        let pull = PowerAwareCadence(interval: 300, reducedInterval: ShiftGitSync.reducedPowerPullInterval)
        check(ShiftGitSync.reducedPowerPullInterval == 30 * 60,
              "the battery pull cadence should be 30 minutes, is \(ShiftGitSync.reducedPowerPullInterval)s", &ok)
        let pullAC = runs(of: pull, period: 300, hours: 2, reduced: false)
        let pullBattery = runs(of: pull, period: 300, hours: 2, reduced: true)
        check(pullAC == 24, "on AC the Tasks pull should run every 5-minute tick: 24 in 2 hours, got \(pullAC)", &ok)
        check(pullBattery == 4, "on battery the Tasks pull should run every 30 minutes: 4 in 2 hours, got \(pullBattery)", &ok)

        // A manual "Check now" counts as a run, so the next battery tick waits
        // a full hour after it rather than repeating it.
        var manual = sweep
        let start = Date()
        manual.noteRun(at: start)
        check(!manual.isDue(now: start.addingTimeInterval(45 * 60), reduced: true),
              "a battery tick 45 minutes after a manual check should wait", &ok)
        check(manual.isDue(now: start.addingTimeInterval(45 * 60), reduced: false),
              "plugged in, the same tick should run - the stretch is battery-only", &ok)
        check(manual.isDue(now: start.addingTimeInterval(60 * 60), reduced: true),
              "a battery tick an hour after the last run should run", &ok)

        // The poller's own tick decision, on the shared instance: on reduced
        // power the hourly cadence alone decides, whatever the backgrounded
        // gate would have said.
        let poller = BackgroundSignalsPoller.shared
        check(poller.timerTickShouldRun(now: Date(), reducedPower: true, backgrounded: true),
              "the first battery tick of a session (no pass yet) should run", &ok)

        PowerSource.reducedOverrideForTests = true
        check(PowerSource.prefersReducedBackgroundWork(), "the test override should read as reduced power", &ok)
        PowerSource.reducedOverrideForTests = false
        check(!PowerSource.prefersReducedBackgroundWork(), "the test override should read as normal power", &ok)
        PowerSource.reducedOverrideForTests = nil
    }

    /// Both timers have to ask. A cadence nobody consults is the failure this
    /// guards against, and no headless suite can fire a 15-minute timer.
    private static func checkPowerCadenceIsWired(_ ok: inout Bool) {
        print("\n-- R5 energy fix 5: both timers consult the power cadence --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            fail("source root not found - this check cannot run", &ok)
            return
        }
        let poller = (try? String(contentsOf: root.appendingPathComponent("BackgroundSignalsPoller.swift"), encoding: .utf8))
            .map(strippingComments) ?? ""
        let shift = (try? String(contentsOf: root.appendingPathComponent("ShiftGitSync.swift"), encoding: .utf8))
            .map(strippingComments) ?? ""
        check(poller.contains("Timer.scheduledTimer") && shift.contains("Timer.scheduledTimer"),
              "the poller or the Tasks sync no longer has its timer here - this guard is pointing at the wrong place", &ok)
        check(poller.contains("timerTickShouldRun(now: Date(), reducedPower: PowerSource.prefersReducedBackgroundWork()"),
              "the poller's timer tick no longer asks the power cadence", &ok)
        check(poller.contains("powerCadence.noteRun("),
              "the poller no longer notes its passes, so a manual check would not reset the battery cadence", &ok)
        check(shift.contains("pullCadence.isDue(now: now, reduced: PowerSource.prefersReducedBackgroundWork())"),
              "the Tasks pull timer no longer asks the power cadence", &ok)
    }

    /// Drops `//` line comments and `/* */` blocks so a source guard matches
    /// code rather than the paragraph explaining the code. Deliberately naive
    /// about string literals containing `//` - nothing in the guarded file has
    /// one, and a false *failure* here is loud rather than silent.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var inBlock = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            if inBlock {
                guard let end = text.range(of: "*/") else { continue }
                text = String(text[end.upperBound...])
                inBlock = false
            }
            if let start = text.range(of: "/*") {
                if let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
                    text = String(text[..<start.lowerBound]) + String(text[end.upperBound...])
                } else {
                    text = String(text[..<start.lowerBound])
                    inBlock = true
                }
            }
            if let slashes = text.range(of: "//") {
                text = String(text[..<slashes.lowerBound])
            }
            out += text + "\n"
        }
        return out
    }

    // MARK: A tools-only reading must not invent a secrets count
    //
    // The poller has `av doctor --json` and deliberately does not have
    // `av list`, so it can say how many launchers need attention and can say
    // nothing at all about how many secrets exist. GL-14: writing a zero there
    // would be the same lie the B1 fix removed from the other field.

    private static func checkVaultToolsPublish(_ ok: inout Bool) {
        print("\n-- publishVaultTools: attention updates, the secrets count is left alone --")
        let poller = BackgroundSignalsPoller.shared

        // Seed both fields from a full reading, the way a Vault-page visit
        // does, so the check below has a real previous value to preserve
        // rather than a `nil` that would make it vacuous.
        let seededAt = Date()
        poller.publishVaultRead(secrets: [VaultSecret(name: "A"), VaultSecret(name: "B")],
                                tools: [VaultTool(name: "brew", commands: ["brew"], status: .hardened)],
                                gatheredAt: seededAt)
        check(poller.lastCounts.vaultSecrets == 2,
              "seed: expected 2 secrets, got \(String(describing: poller.lastCounts.vaultSecrets))", &ok)
        check(poller.lastCounts.vaultAttention == 0,
              "seed: expected 0 needing attention, got \(String(describing: poller.lastCounts.vaultAttention))", &ok)

        // A tools-only reading moves the attention count...
        poller.publishVaultTools([
            VaultTool(name: "brew", commands: ["brew"], status: .needsAttention(issueCount: 2)),
            VaultTool(name: "gh", commands: ["gh"], status: .hardened),
        ], gatheredAt: seededAt.addingTimeInterval(1))
        check(poller.lastCounts.vaultAttention == 1,
              "tools-only publish: expected 1 needing attention, got \(String(describing: poller.lastCounts.vaultAttention))", &ok)
        // ...and leaves the one it has no reading for exactly as it was.
        check(poller.lastCounts.vaultSecrets == 2,
              "tools-only publish overwrote the secrets count with \(String(describing: poller.lastCounts.vaultSecrets)) - it had no `av list` result to write", &ok)

        // A failed `av doctor` read is not "nothing needs attention" (B1).
        poller.publishVaultTools(nil, gatheredAt: seededAt.addingTimeInterval(2))
        check(poller.lastCounts.vaultAttention == 1,
              "a failed tools read changed the attention count to \(String(describing: poller.lastCounts.vaultAttention)) - a read that failed says nothing", &ok)
        check(poller.lastCounts.vaultSecrets == 2,
              "a failed tools read changed the secrets count to \(String(describing: poller.lastCounts.vaultSecrets))", &ok)
    }

    // MARK: The lock screen never re-asks `av list` on a timer
    //
    // Every retry was an `av list`, i.e. an approval-service round trip that
    // is entitled to raise Automic Vault's own dialog. The flat 1.5s cadence
    // asked an unresponsive helper ~2,400 times an hour; the backoff that
    // replaced it still answered a Deny with the same dialog seconds later.
    // `fm/grand-line-vault-no-launch-prompt` removed the timer outright:
    // Check again and the next typed password are the only re-asks. The
    // behaviour is `VaultReadSessionSelfTest`'s; this is the source half.

    private static func checkLockScreenHasNoRetryTimer(_ ok: inout Bool) {
        print("\n-- the lock screen never re-runs `av list` on a timer --")
        guard let root = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: root.appendingPathComponent("LockPresenter.swift"), encoding: .utf8) else {
            fail("LockPresenter.swift could not be read - this check cannot run", &ok)
            return
        }
        let code = strippingComments(source)
        check(code.contains("func checkAppPasswordAvailability("),
              "fixture: LockPresenter no longer has checkAppPasswordAvailability - this guard is pointing at the wrong place", &ok)
        for banned in ["asyncAfter", "Timer.scheduledTimer", "Timer("] {
            check(!code.contains(banned),
                  "LockPresenter schedules work (\(banned)) - a timed re-run of the `av list` check is what put Automic Vault's dialog back on screen after a Deny", &ok)
        }
    }

}

#endif
