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
        checkLatchRelease(&ok)
        checkHealthVerdicts(&ok)
        checkNoUnattendedAvList(&ok)
        checkVaultToolsPublish(&ok)
        checkAppPasswordRetryBackoff(&ok)
        print(ok ? "BackgroundSignalsSelfTest: all checks passed" : "BackgroundSignalsSelfTest: FAILED")
        return ok
    }


    // MARK: GL-03 - the latch

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
            fail("a pass 30s into a 300s watchdog was superseded - that is just piling on", &ok)
        }
        // Exactly at the watchdog is still young: strictly greater, so the
        // boundary can never flap between two ticks landing on the same second.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-watchdog),
                                         now: now, watchdog: watchdog) != .refused {
            fail("the watchdog boundary is inclusive - it should need to be genuinely exceeded", &ok)
        }
        // Busy and hung: supersede, and report how long it has been.
        switch BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-601),
                                             now: now, watchdog: watchdog) {
        case .supersede(let age):
            if age < 600 { fail("superseded pass reported an age of \(age)s, want ~601", &ok) }
        default:
            fail("a pass hung for 601s past a 300s watchdog was not superseded - this is the GL-03 bug", &ok)
        }
        // Busy with no start time at all is a broken state, not a licence.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: nil, now: now, watchdog: watchdog) != .refused {
            fail("a held latch with no start time started another pass anyway", &ok)
        }
        print("  OK - idle starts, young refuses, hung supersedes with a real age")
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
        check(source.contains("private func checkVault()"),
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

    // MARK: The lock screen's `av list` retry backs off
    //
    // Every retry is an `av list`, i.e. an approval-service round trip. The
    // flat 1.5s-forever cadence it replaced asked an unresponsive approval
    // helper ~2,400 times an hour for as long as the lock screen was up.

    private static func checkAppPasswordRetryBackoff(_ ok: inout Bool) {
        print("\n-- lock screen `av list` retry backs off --")
        let base = AppShellController.appPasswordRetryBaseDelay
        let ceiling = AppShellController.appPasswordRetryCeiling

        // The fixture has to be able to tell the two apart, or "starts at base"
        // and "stops at ceiling" are the same assertion.
        check(ceiling > base, "fixture: the ceiling (\(ceiling)) is not above the base (\(base))", &ok)

        check(AppShellController.appPasswordRetryDelay(attempt: 0) == base,
              "first retry is \(AppShellController.appPasswordRetryDelay(attempt: 0))s, expected \(base)s - the common 'the helper is still starting' case must still recover fast", &ok)

        var previous = AppShellController.appPasswordRetryDelay(attempt: 0)
        var reachedCeiling = false
        for attempt in 1...12 {
            let delay = AppShellController.appPasswordRetryDelay(attempt: attempt)
            check(delay >= previous, "retry \(attempt) got faster (\(previous)s -> \(delay)s)", &ok)
            check(delay <= ceiling, "retry \(attempt) is \(delay)s, above the \(ceiling)s ceiling", &ok)
            if delay == ceiling { reachedCeiling = true }
            previous = delay
        }
        check(reachedCeiling, "the backoff never reaches its \(ceiling)s ceiling within 12 retries", &ok)

        // The whole point is that it is not flat: a schedule that never grows
        // would satisfy every assertion above.
        check(AppShellController.appPasswordRetryDelay(attempt: 3) > base,
              "the retry delay never grows past \(base)s - this is still the flat cadence the fix replaced", &ok)
    }

}

#endif
