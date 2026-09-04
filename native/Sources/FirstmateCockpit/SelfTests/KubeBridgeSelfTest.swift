#if FM_SELFTESTS
// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_KUBE_BRIDGE_TESTS=1 .build/debug/FirstmateCockpit`
//
// `fm/grandline-k8s-cluster-tail`'s pure-logic half: the shared `KubeBridge`
// queue plumbing (single-flight, serialized batches, both guards, the
// queue deadline, and - the case the task brief singles out - **backoff and
// a real give-up**), plus `KubeResourceParser`'s column parsing and
// `KubeLogMerger`'s ordering/dedupe.
//
// Everything here runs against `FakeBridgeTerminal` (`SRELeadBridgeSelfTest`'s
// own lightweight stand-in) and literal command output, so this suite needs
// no window, no cluster and no subprocess - it runs in CI. The window-backed
// half (mounting the real destination, the empty state, real handler drives)
// is `KubernetesDestinationSelfTest`.
//
// **`tick()` is driven by hand, never by `KubeBridge`'s real `Timer`** - a
// headless self-test binary never pumps a run loop, the same reason
// `SRELeadBridgeSelfTest` and `KubeContextBridgeSelfTest` both do this.

import AppKit

enum KubeBridgeSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            // KubeCommand - the read-only-by-construction half.
            ("command_buildsEveryReadOnlyForm", test_command_buildsEveryReadOnlyForm),
            ("command_refusesUnsafeTokens", test_command_refusesUnsafeTokens),
            ("command_neverBuildsAMutatingVerb", test_command_neverBuildsAMutatingVerb),

            // KubeBridge - the queue and its guards.
            ("bridge_runsOneCommandAndReturnsItsOutput", test_bridge_runsOneCommandAndReturnsItsOutput),
            ("bridge_serializesABatchOneCommandAtATime", test_bridge_serializesABatchOneCommandAtATime),
            ("bridge_batchReportsEveryResultEvenWhenOneFails", test_bridge_batchReportsEveryResultEvenWhenOneFails),
            ("bridge_neverInjectsWhileCaptainIsTyping", test_bridge_neverInjectsWhileCaptainIsTyping),
            ("bridge_neverInjectsWhileSiblingBridgeHoldsTheTab", test_bridge_neverInjectsWhileSiblingBridgeHoldsTheTab),
            ("bridge_discardsOutputWhenCaptainTypesMidCommand", test_bridge_discardsOutputWhenCaptainTypesMidCommand),
            ("bridge_timesOutWhenEndMarkerNeverArrives", test_bridge_timesOutWhenEndMarkerNeverArrives),
            ("bridge_expiresARequestThatWaitedTooLongBehindContention", test_bridge_expiresARequestThatWaitedTooLongBehindContention),
            ("bridge_refusesAnUnsafeCommandWithoutInjectingAnything", test_bridge_refusesAnUnsafeCommandWithoutInjectingAnything),

            // `fm/grandline-k8s-refresh-stuck-audit`: the actual root cause of
            // the captain's second real stall - `stop()` used to drop an
            // in-flight request's own completion.
            ("bridge_stopResolvesAnInFlightRequestRatherThanDroppingIt", test_bridge_stopResolvesAnInFlightRequestRatherThanDroppingIt),
            ("bridge_stopResolvesAWholeBatchEvenWithOneCommandInFlight", test_bridge_stopResolvesAWholeBatchEvenWithOneCommandInFlight),
            ("bridge_stopWithNothingInFlightStillFailsQueuedWork", test_bridge_stopWithNothingInFlightStillFailsQueuedWork),
            ("bridge_stopNeverCountsTowardGivingUp", test_bridge_stopNeverCountsTowardGivingUp),

            // `fm/grandline-k8s-feed-tab-stall-fix`: the pending-reason
            // distinction that makes "waiting on contention" tell apart from
            // "genuinely running" or "nothing queued".
            ("pendingReason_reflectsWaitingForQuietTab", test_pendingReason_reflectsWaitingForQuietTab),
            ("pendingReason_reflectsBusyElsewhere", test_pendingReason_reflectsBusyElsewhere),
            ("pendingReason_isNilWithAnEmptyQueue", test_pendingReason_isNilWithAnEmptyQueue),
            ("pendingReason_isNilWhileGenuinelyInFlight", test_pendingReason_isNilWhileGenuinelyInFlight),
            ("pendingReason_clearsAndInjectsOnceContentionEnds", test_pendingReason_clearsAndInjectsOnceContentionEnds),

            // The task brief's own named requirement.
            ("backoff_stopsAfterRepeatedGenuineFailures", test_backoff_stopsAfterRepeatedGenuineFailures),
            ("backoff_contentionNeverCountsTowardGivingUp", test_backoff_contentionNeverCountsTowardGivingUp),
            ("backoff_queuedWorkIsFailedNotLeftDanglingOnGiveUp", test_backoff_queuedWorkIsFailedNotLeftDanglingOnGiveUp),
            ("backoff_resumeClearsTheGiveUpAndTriesAgain", test_backoff_resumeClearsTheGiveUpAndTriesAgain),
            ("backoff_successResetsTheFailureCount", test_backoff_successResetsTheFailureCount),

            // KubeResourceParser - kubectl's own column output.
            ("parse_podsWideWithMetrics", test_parse_podsWideWithMetrics),
            ("parse_podsWithoutMetricsServer", test_parse_podsWithoutMetricsServer),
            ("parse_podsReadsColumnsByNameNotPosition", test_parse_podsReadsColumnsByNameNotPosition),
            ("parse_podsSkipsKubectlWarningLinesBeforeTheHeader", test_parse_podsSkipsKubectlWarningLinesBeforeTheHeader),
            ("parse_emptyNamespaceIsNotAFailure", test_parse_emptyNamespaceIsNotAFailure),
            ("parse_shellErrorIsAFailureNotAnEmptyList", test_parse_shellErrorIsAFailureNotAnEmptyList),
            ("parse_deployments", test_parse_deployments),
            ("parse_eventsKeepsTheWholeMessageColumn", test_parse_eventsKeepsTheWholeMessageColumn),
            ("parse_podHealthClassification", test_parse_podHealthClassification),

            // KubeLogParser / KubeLogMerger - the tail's own logic.
            ("log_parsesTimestampedLines", test_log_parsesTimestampedLines),
            ("log_keepsALineWithNoTimestamp", test_log_keepsALineWithNoTimestamp),
            ("log_mergesTwoPodsInTimestampOrder", test_log_mergesTwoPodsInTimestampOrder),
            ("log_dedupesOverlappingPolls", test_log_dedupesOverlappingPolls),
            ("log_capsTheWindow", test_log_capsTheWindow),
            ("log_assignsStableColoursByFirstAppearance", test_log_assignsStableColoursByFirstAppearance),
            ("log_errorsOnlyFilter", test_log_errorsOnlyFilter),
            ("log_sinceWindowIsWiderThanThePollInterval", test_log_sinceWindowIsWiderThanThePollInterval),
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
        print(failures == 0
            ? "KubeBridgeSelfTest: all \(cases.count) cases passed"
            : "KubeBridgeSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func tickUntil(_ bridge: KubeBridge, maxTicks: Int = 60, _ condition: () -> Bool) {
        for _ in 0..<maxTicks where !condition() { bridge.tick() }
    }

    private static func markers(in injected: String) -> (start: String, end: String)? {
        func find(_ prefix: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "\(prefix)_[0-9a-fA-F]+") else { return nil }
            let ns = injected as NSString
            guard let m = regex.firstMatch(in: injected, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: m.range)
        }
        guard let start = find("GL_KUBE_START"), let end = find("GL_KUBE_END") else { return nil }
        return (start, end)
    }

    /// Scripts the fake to answer every injected command with `output`.
    private static func answerAll(_ fake: FakeBridgeTerminal, with output: @escaping (String) -> String) {
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\n\(output(injected))\n\(end)")
        }
    }

    /// Scripts the fake to *never* answer - the timeout shape.
    private static func answerNothing(_ fake: FakeBridgeTerminal) {
        fake.onSendCommand = { _ in }
    }

    /// Scripts the fake to answer with the end marker but no start marker -
    /// a real, **deterministic** genuine failure (`markersNotFound`).
    ///
    /// The backoff cases use this rather than a timeout: a timeout needs a
    /// `commandTimeout` small enough to fire inside a test that never sleeps,
    /// and a zero ceiling then also preempts the *success* those same cases
    /// need afterwards to prove the count resets. `markersNotFound` counts
    /// toward the give-up threshold identically (`countsAsGenuineFailure`) and
    /// needs no clock at all.
    private static func answerBroken(_ fake: FakeBridgeTerminal) {
        fake.onSendCommand = { injected in
            guard let (_, end) = markers(in: injected) else { return }
            fake.appendOutput("-bash: kubectl: command not found\n\(end)")
        }
    }

    // MARK: KubeCommand

    private static func test_command_buildsEveryReadOnlyForm() -> String? {
        let expectations: [(KubeCommand, String)] = [
            (.getPods(namespace: "raas-prod"), "kubectl get pods -n raas-prod -o wide"),
            (.topPods(namespace: "raas-prod"), "kubectl top pods -n raas-prod"),
            (.getDeployments(namespace: "raas-prod"), "kubectl get deployments -n raas-prod"),
            (.getServices(namespace: "raas-prod"), "kubectl get services -n raas-prod"),
            (.getEvents(namespace: "raas-prod"), "kubectl get events -n raas-prod --sort-by=.lastTimestamp"),
            (.describePod(name: "api-0", namespace: "raas-prod"), "kubectl describe pod api-0 -n raas-prod"),
            (.podLogs(pod: "api-0", namespace: "raas-prod", sinceSeconds: 15),
             "kubectl logs api-0 -n raas-prod --since=15s --timestamps"),
        ]
        for (command, expected) in expectations {
            guard command.commandText == expected else {
                return "\(command.shortLabel) built \(command.commandText ?? "nil"), expected \(expected)"
            }
        }
        return nil
    }

    private static func test_command_refusesUnsafeTokens() -> String? {
        // Every one of these is a real shell-injection shape reaching a real,
        // already-authenticated bastion session - refusing to build the
        // command at all is the only acceptable outcome.
        let hostile = ["prod; rm -rf /", "prod && curl evil", "prod`whoami`", "prod$(id)", "prod|tee /tmp/x",
                       "prod\nrm", "prod ", "", "pro'd", "prod\"x"]
        for token in hostile {
            guard KubeCommand.getPods(namespace: token).commandText == nil else {
                return "namespace \(token.debugDescription) was accepted"
            }
            guard KubeCommand.describePod(name: token, namespace: "ok").commandText == nil else {
                return "pod name \(token.debugDescription) was accepted"
            }
            guard KubeCommand.podLogs(pod: token, namespace: "ok", sinceSeconds: 15).commandText == nil else {
                return "logs pod \(token.debugDescription) was accepted"
            }
        }
        // A negative or absurd `--since` is refused too, so nothing can ask
        // the cluster for an unbounded history through this path.
        guard KubeCommand.podLogs(pod: "api-0", namespace: "ok", sinceSeconds: 0).commandText == nil,
              KubeCommand.podLogs(pod: "api-0", namespace: "ok", sinceSeconds: 999_999).commandText == nil else {
            return "an out-of-range --since window was accepted"
        }
        return nil
    }

    /// The structural guarantee: `KubeCommand` is a closed enum of read-only
    /// forms, so no built command can ever carry a mutating verb. Asserted
    /// against every case rather than by reading the enum, so a case added
    /// later without thinking fails here.
    private static func test_command_neverBuildsAMutatingVerb() -> String? {
        let all: [KubeCommand] = [
            .getPods(namespace: "ns"), .topPods(namespace: "ns"), .getDeployments(namespace: "ns"),
            .getServices(namespace: "ns"), .getEvents(namespace: "ns"),
            .describePod(name: "p", namespace: "ns"), .podLogs(pod: "p", namespace: "ns", sinceSeconds: 15),
        ]
        let banned = ["exec", "edit", "delete", "scale", "apply", "patch", "replace", "rollout",
                      "cordon", "drain", "annotate", "label", "create", "run", "cp", "port-forward", "attach"]
        for command in all {
            guard let text = command.commandText else { return "\(command.shortLabel) failed to build" }
            for verb in banned where text.contains(verb) {
                return "\(command.shortLabel) built a command containing \(verb): \(text)"
            }
            guard text.hasPrefix("kubectl ") else { return "\(command.shortLabel) is not a kubectl command: \(text)" }
        }
        return nil
    }

    // MARK: KubeBridge

    private static func test_bridge_runsOneCommandAndReturnsItsOutput() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        answerAll(fake) { _ in "NAME   READY\napi-0  1/1" }
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        tickUntil(bridge) { result != nil }
        guard let result else { return "completion never fired" }
        guard case .success(let raw) = result else { return "expected success, got \(result)" }
        guard raw.contains("api-0") else { return "output did not contain the command's own text: \(raw)" }
        guard fake.sentCommands.count == 1 else { return "expected 1 injected command, got \(fake.sentCommands.count)" }
        guard fake.sentCommands[0].contains("kubectl get pods -n ns -o wide") else {
            return "injected the wrong command: \(fake.sentCommands[0])"
        }
        return nil
    }

    /// The single-flight constraint, asserted where it actually matters: a
    /// batch of three must never put two commands in the tab at once.
    private static func test_bridge_serializesABatchOneCommandAtATime() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        var maxConcurrent = 0
        var open = 0
        fake.onSendCommand = { injected in
            open += 1
            maxConcurrent = max(maxConcurrent, open)
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nNAME\nrow\n\(end)")
            open -= 1
        }
        var done: [(KubeCommand, Result<String, KubeBridgeError>)]?
        bridge.enqueueBatch([.getPods(namespace: "ns"), .topPods(namespace: "ns"), .getEvents(namespace: "ns")]) {
            done = $0
        }
        tickUntil(bridge) { done != nil }
        guard let done else { return "batch never completed" }
        guard done.count == 3 else { return "expected 3 results, got \(done.count)" }
        guard maxConcurrent == 1 else { return "two commands were in the tab at once (max \(maxConcurrent))" }
        guard fake.sentCommands.count == 3 else { return "expected 3 injections, got \(fake.sentCommands.count)" }
        return nil
    }

    /// `top pods` legitimately fails on a cluster with no metrics-server, and
    /// that must not blank out the pod list `get pods` returned perfectly
    /// well - so a batch reports every result rather than failing whole.
    private static func test_bridge_batchReportsEveryResultEvenWhenOneFails() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            if injected.contains("get pods") {
                fake.appendOutput("\(start)\nNAME\napi-0\n\(end)")
            } else {
                // A reply whose start marker never arrived - a real,
                // deterministic `markersNotFound` failure, standing in for the
                // `top pods` a cluster with no metrics-server refuses.
                fake.appendOutput("error: Metrics API not available\n\(end)")
            }
        }
        var done: [(KubeCommand, Result<String, KubeBridgeError>)]?
        bridge.enqueueBatch([.getPods(namespace: "ns"), .topPods(namespace: "ns")]) { done = $0 }
        tickUntil(bridge) { done != nil }
        guard let done, done.count == 2 else { return "expected both results, got \(done?.count ?? 0)" }
        let podResult = done.first { if case .getPods = $0.0 { return true }; return false }
        guard case .success? = podResult?.1 else { return "the pod list did not succeed alongside a failing top" }
        return nil
    }

    private static func test_bridge_neverInjectsWhileCaptainIsTyping() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date()
        let bridge = KubeBridge(target: fake, userActivityQuietWindow: 30)
        bridge.enqueue(.getPods(namespace: "ns")) { _ in }
        for _ in 0..<5 { bridge.tick() }
        guard fake.sentCommands.isEmpty else { return "injected into a tab the captain is typing in" }
        guard bridge.queueDepth == 1 else { return "the request was dropped rather than kept queued" }
        return nil
    }

    private static func test_bridge_neverInjectsWhileSiblingBridgeHoldsTheTab() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        bridge.isTerminalBusyElsewhere = { true }
        bridge.enqueue(.getPods(namespace: "ns")) { _ in }
        for _ in 0..<5 { bridge.tick() }
        guard fake.sentCommands.isEmpty else { return "injected while a sibling bridge held the tab" }
        return nil
    }

    private static func test_bridge_discardsOutputWhenCaptainTypesMidCommand() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nNAME\napi-0\n\(end)")
            // The captain typed after injection: the shell's own input and
            // ours could have interleaved, so this output cannot be trusted.
            fake.lastUserActivity = Date()
        }
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        tickUntil(bridge) { result != nil }
        guard case .failure(.discarded)? = result else { return "expected .discarded, got \(String(describing: result))" }
        return nil
    }

    private static func test_bridge_timesOutWhenEndMarkerNeverArrives() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake, commandTimeout: 0)
        answerNothing(fake)
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        tickUntil(bridge) { result != nil }
        guard case .failure(.timeout)? = result else { return "expected .timeout, got \(String(describing: result))" }
        return nil
    }

    /// Without a deadline, a captain typing for a minute builds a backlog of
    /// stale polls that all fire at once when they stop.
    private static func test_bridge_expiresARequestThatWaitedTooLongBehindContention() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date()
        let bridge = KubeBridge(target: fake, queueDeadline: 0, userActivityQuietWindow: 30)
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        tickUntil(bridge) { result != nil }
        guard case .failure(.busy)? = result else { return "expected .busy, got \(String(describing: result))" }
        guard bridge.queueDepth == 0 else { return "the expired request was left queued" }
        // Contention must never count toward the give-up threshold.
        guard !bridge.hasStoppedRetrying else { return "an expired-behind-contention request tripped give-up" }
        return nil
    }

    private static func test_bridge_refusesAnUnsafeCommandWithoutInjectingAnything() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns; rm -rf /")) { result = $0 }
        guard case .failure(.unsafeCommand)? = result else {
            return "expected .unsafeCommand, got \(String(describing: result))"
        }
        guard fake.sentCommands.isEmpty else { return "an unsafe command reached the terminal" }
        guard !bridge.hasStoppedRetrying else { return "an unsafe command counted toward give-up" }
        return nil
    }

    // MARK: `fm/grandline-k8s-refresh-stuck-audit` - stop() dropping an in-flight completion
    //
    // This is the actual root cause of the captain's second real stall, found
    // by reading `KubeBridge.stop()` line by line rather than assumed: it set
    // `inFlight = nil` without ever calling that request's own `completion`,
    // only failing what was still sitting in `queue`. Reachable any time the
    // captain switches the feed-tab picker or the scope strip mid-sweep
    // (`KubernetesController.teardownFeed()` -> `bridge.stop()`) - a real
    // discovery sweep against a real cluster easily takes long enough for a
    // command to still be in flight at that moment.

    /// The narrowest possible repro: one command, genuinely in flight
    /// (`inFlightLabel != nil`, never answered), then `stop()`. Before the
    /// fix this hung forever - `result` stayed `nil`.
    private static func test_bridge_stopResolvesAnInFlightRequestRatherThanDroppingIt() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        fake.onSendCommand = { _ in } // never answers - stays genuinely in flight
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        for _ in 0..<3 { bridge.tick() }
        guard bridge.inFlightLabel != nil else { return "the command was never actually issued - test setup is wrong" }
        guard result == nil else { return "the completion fired before stop() was even called - test setup is wrong" }

        bridge.stop()

        guard let result else {
            return "stop() silently dropped the in-flight request's own completion - this is the exact bug that " +
                   "leaves a caller's own counter (e.g. KubernetesController.isRefreshingCluster) stuck true forever, " +
                   "with nothing queued or pending to explain why"
        }
        guard case .failure(.unavailable) = result else {
            return "expected .unavailable once stopped mid-flight, got \(result)"
        }
        return nil
    }

    /// The shape that actually matters: `KubernetesController.refreshCluster()`
    /// tracks its own "how many of these N commands are still outstanding"
    /// counter via `enqueueBatch`'s single outer completion. If the ONE
    /// command that happened to be in flight at the moment `stop()` ran is
    /// the one whose completion gets dropped, that counter never reaches
    /// zero and the outer completion - the thing that flips
    /// `isRefreshingCluster` back to `false` - never fires, no matter how
    /// many of the batch's other commands already succeeded.
    private static func test_bridge_stopResolvesAWholeBatchEvenWithOneCommandInFlight() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        fake.onSendCommand = { _ in } // the batch's first command never answers
        var done: [(KubeCommand, Result<String, KubeBridgeError>)]?
        bridge.enqueueBatch([.getPods(namespace: "ns"), .topPods(namespace: "ns")]) { done = $0 }
        for _ in 0..<3 { bridge.tick() }
        guard bridge.inFlightLabel != nil else { return "the batch's first command was never issued - test setup is wrong" }
        guard bridge.queueDepth == 1 else { return "expected the second command still queued, got depth \(bridge.queueDepth)" }
        guard done == nil else { return "the batch completed before stop() was even called - test setup is wrong" }

        bridge.stop()

        guard let done else {
            return "the batch's own completion never fired after stop() - a caller like " +
                   "KubernetesController.refreshCluster() would be left with isRefreshingCluster stuck true forever"
        }
        guard done.count == 2 else { return "expected 2 results even for a stopped batch, got \(done.count)" }
        for (_, result) in done {
            guard case .failure(.unavailable) = result else {
                return "expected every leg of a stopped batch to fail .unavailable, got \(result)"
            }
        }
        return nil
    }

    /// The half `stop()` always got right, unaffected by this fix: nothing
    /// in flight, but something still queued behind it.
    private static func test_bridge_stopWithNothingInFlightStillFailsQueuedWork() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date() // keeps the request queued, never issued
        let bridge = KubeBridge(target: fake, userActivityQuietWindow: 30)
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        for _ in 0..<3 { bridge.tick() }
        guard bridge.inFlightLabel == nil, bridge.queueDepth == 1 else {
            return "expected the request queued but not issued - test setup is wrong"
        }
        bridge.stop()
        guard case .failure(.unavailable)? = result else {
            return "expected the queued request to fail .unavailable on stop(), got \(String(describing: result))"
        }
        return nil
    }

    /// `stop()` is "pause" (the feed tab changed), never "give up" - resolving
    /// the dropped in-flight request must not itself start counting toward
    /// the give-up threshold, exactly like the already-queued failures below
    /// it never did.
    private static func test_bridge_stopNeverCountsTowardGivingUp() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake, maxConsecutiveFailures: 1)
        fake.onSendCommand = { _ in } // never answers - stays in flight
        bridge.enqueue(.getPods(namespace: "ns")) { _ in }
        for _ in 0..<3 { bridge.tick() }
        guard bridge.inFlightLabel != nil else { return "the command was never issued - test setup is wrong" }
        bridge.stop()
        guard !bridge.hasStoppedRetrying else { return "stopping mid-flight tripped the give-up threshold" }
        guard bridge.consecutiveFailureCount == 0 else {
            return "stopping mid-flight incremented the genuine-failure count to \(bridge.consecutiveFailureCount)"
        }
        return nil
    }

    // MARK: Pending reason (`fm/grandline-k8s-feed-tab-stall-fix`)

    /// The captain's own real repro: checking on the feed tab by typing a
    /// manual login directly into it. `pendingReason` must say so - and stop
    /// saying so, and inject, the moment activity genuinely clears - with no
    /// weakening of the underlying refusal (nothing is ever injected while
    /// blocked).
    private static func test_pendingReason_reflectsWaitingForQuietTab() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date()
        let bridge = KubeBridge(target: fake, userActivityQuietWindow: 30)
        var stateChanges = 0
        bridge.onStateChanged = { stateChanges += 1 }
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        for _ in 0..<5 { bridge.tick() }
        guard bridge.pendingReason == .waitingForQuietTab else {
            return "expected .waitingForQuietTab while the captain is typing, got \(String(describing: bridge.pendingReason))"
        }
        guard bridge.pendingSince != nil else { return "pendingSince was nil while genuinely pending" }
        guard fake.sentCommands.isEmpty else { return "injected into the tab while the captain was typing" }
        guard stateChanges >= 1 else { return "onStateChanged never fired for the new pending reason" }

        // Being blocked on the *same* reason tick after tick must not keep
        // re-firing onStateChanged - only a genuine transition should.
        let settled = stateChanges
        for _ in 0..<5 { bridge.tick() }
        guard stateChanges == settled else {
            return "onStateChanged fired \(stateChanges - settled) extra times with no real state change"
        }

        // Once the captain genuinely stops typing, the reason clears and the
        // queued command is finally issued with no further nudging.
        fake.lastUserActivity = nil
        answerAll(fake) { _ in "NAME\napi-0" }
        tickUntil(bridge) { result != nil }
        guard case .success? = result else {
            return "the request was never issued once activity cleared: \(String(describing: result))"
        }
        guard bridge.pendingReason == nil else { return "pendingReason did not clear once issued" }
        return nil
    }

    private static func test_pendingReason_reflectsBusyElsewhere() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        bridge.isTerminalBusyElsewhere = { true }
        bridge.enqueue(.getPods(namespace: "ns")) { _ in }
        for _ in 0..<5 { bridge.tick() }
        guard bridge.pendingReason == .busyElsewhere else {
            return "expected .busyElsewhere, got \(String(describing: bridge.pendingReason))"
        }
        guard fake.sentCommands.isEmpty else { return "injected while a sibling bridge held the tab" }
        return nil
    }

    private static func test_pendingReason_isNilWithAnEmptyQueue() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        for _ in 0..<3 { bridge.tick() }
        guard bridge.pendingReason == nil else {
            return "pendingReason was set with an empty queue: \(String(describing: bridge.pendingReason))"
        }
        guard bridge.pendingSince == nil else { return "pendingSince was set with nothing pending" }
        return nil
    }

    /// While something is genuinely in flight (`inFlightLabel`), pending
    /// reason must be nil - the two are mutually exclusive by construction,
    /// so the UI never has to reconcile a "pending" and a "running" signal
    /// at once.
    private static func test_pendingReason_isNilWhileGenuinelyInFlight() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        fake.onSendCommand = { _ in } // never answers - stays in flight
        bridge.enqueue(.getPods(namespace: "ns")) { _ in }
        for _ in 0..<5 { bridge.tick() }
        guard bridge.inFlightLabel != nil else { return "the command was never issued" }
        guard bridge.pendingReason == nil else {
            return "pendingReason was set while genuinely in flight: \(String(describing: bridge.pendingReason))"
        }
        return nil
    }

    /// The queued command is never abandoned by contention alone - once the
    /// sibling bridge releases the tab, it proceeds on the very next tick,
    /// with no separate nudge required.
    private static func test_pendingReason_clearsAndInjectsOnceContentionEnds() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake)
        var busy = true
        bridge.isTerminalBusyElsewhere = { busy }
        answerAll(fake) { _ in "NAME\napi-0" }
        var result: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { result = $0 }
        for _ in 0..<5 { bridge.tick() }
        guard bridge.pendingReason == .busyElsewhere else { return "expected busyElsewhere first" }
        busy = false
        tickUntil(bridge) { result != nil }
        guard case .success? = result else { return "never issued once the sibling released the tab" }
        guard bridge.pendingReason == nil else { return "pendingReason did not clear" }
        return nil
    }

    // MARK: Backoff / give-up (the task brief's named requirement)

    /// The exact shape `fm/grandline-k8s-badge-fixes` had to fix in the
    /// context badge after the captain's first real use: a tab whose `kubectl`
    /// can never succeed must stop being asked, not be hammered forever.
    private static func test_backoff_stopsAfterRepeatedGenuineFailures() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake, maxConsecutiveFailures: 3)
        answerBroken(fake)
        var outcomes: [Result<String, KubeBridgeError>] = []
        for _ in 0..<3 {
            bridge.enqueue(.getPods(namespace: "ns")) { outcomes.append($0) }
            tickUntil(bridge) { outcomes.count > 0 && bridge.queueDepth == 0 && !bridge.isBusy }
        }
        guard bridge.hasStoppedRetrying else {
            return "still retrying after 3 genuine failures (count \(bridge.consecutiveFailureCount))"
        }
        let injectedWhenStopped = fake.sentCommands.count
        // A further request is refused outright, and nothing more reaches the
        // tab - the whole point of giving up.
        var afterStop: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { afterStop = $0 }
        for _ in 0..<10 { bridge.tick() }
        guard case .failure(.stopped)? = afterStop else {
            return "expected .stopped after give-up, got \(String(describing: afterStop))"
        }
        guard fake.sentCommands.count == injectedWhenStopped else {
            return "kept typing into the tab after giving up (\(injectedWhenStopped) -> \(fake.sentCommands.count))"
        }
        return nil
    }

    private static func test_backoff_contentionNeverCountsTowardGivingUp() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date()
        let bridge = KubeBridge(target: fake, queueDeadline: 0,
                                userActivityQuietWindow: 30, maxConsecutiveFailures: 2)
        for _ in 0..<6 {
            var done = false
            bridge.enqueue(.getPods(namespace: "ns")) { _ in done = true }
            tickUntil(bridge) { done }
        }
        guard !bridge.hasStoppedRetrying else { return "contention alone tripped the give-up threshold" }
        guard bridge.consecutiveFailureCount == 0 else {
            return "contention incremented the genuine-failure count to \(bridge.consecutiveFailureCount)"
        }
        return nil
    }

    /// A caller that never hears back cannot tell "gave up" from "still
    /// running", so giving up fails everything still queued.
    private static func test_backoff_queuedWorkIsFailedNotLeftDanglingOnGiveUp() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake, maxConsecutiveFailures: 1)
        answerBroken(fake)
        var results: [Result<String, KubeBridgeError>] = []
        bridge.enqueueBatch([.getPods(namespace: "ns"), .topPods(namespace: "ns"), .getEvents(namespace: "ns")]) {
            results = $0.map(\.1)
        }
        tickUntil(bridge) { results.count == 3 }
        guard results.count == 3 else { return "only \(results.count)/3 completions fired after give-up" }
        guard bridge.hasStoppedRetrying else { return "did not give up after its first genuine failure" }
        return nil
    }

    private static func test_backoff_resumeClearsTheGiveUpAndTriesAgain() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake, maxConsecutiveFailures: 1)
        answerBroken(fake)
        var first: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { first = $0 }
        tickUntil(bridge) { first != nil }
        guard bridge.hasStoppedRetrying else { return "did not give up" }

        // The captain's own explicit retry - the way back in.
        answerAll(fake) { _ in "NAME\napi-0" }
        bridge.resume()
        guard !bridge.hasStoppedRetrying else { return "resume() did not clear the give-up state" }
        var second: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { second = $0 }
        tickUntil(bridge) { second != nil }
        guard case .success? = second else { return "expected success after resume, got \(String(describing: second))" }
        return nil
    }

    private static func test_backoff_successResetsTheFailureCount() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeBridge(target: fake, maxConsecutiveFailures: 3)
        answerBroken(fake)
        for _ in 0..<2 {
            var done = false
            bridge.enqueue(.getPods(namespace: "ns")) { _ in done = true }
            tickUntil(bridge) { done }
        }
        guard bridge.consecutiveFailureCount == 2 else {
            return "expected 2 failures, got \(bridge.consecutiveFailureCount)"
        }
        answerAll(fake) { _ in "NAME\napi-0" }
        var ok: Result<String, KubeBridgeError>?
        bridge.enqueue(.getPods(namespace: "ns")) { ok = $0 }
        tickUntil(bridge) { ok != nil }
        guard bridge.consecutiveFailureCount == 0 else {
            return "a success left the failure count at \(bridge.consecutiveFailureCount)"
        }
        return nil
    }

    // MARK: KubeResourceParser

    /// Real `kubectl get pods -o wide` shape, including a modern
    /// `4 (2m ago)` restarts field.
    private static let podsWide = """
    NAME                              READY   STATUS             RESTARTS      AGE     IP            NODE
    search-api-7f9c6d5b4-x2x8p        1/1     Running            0             2d4h    10.40.3.17    ip-10-40-3-112
    contract-ingest-worker-0          1/1     Running            4 (2m ago)    6h12m   10.40.7.22    ip-10-40-7-201
    billing-cron-29471120-tzkkd       0/1     ImagePullBackOff   0             14m     10.40.5.9     ip-10-40-5-88
    """

    private static let topPods = """
    NAME                              CPU(CORES)   MEMORY(BYTES)
    search-api-7f9c6d5b4-x2x8p        120m         512Mi
    contract-ingest-worker-0          640m         1922Mi
    """

    private static func test_parse_podsWideWithMetrics() -> String? {
        guard case .rows(let pods) = KubeResourceParser.parsePods(getRaw: podsWide, topRaw: topPods) else {
            return "expected rows"
        }
        guard pods.count == 3 else { return "expected 3 pods, got \(pods.count)" }
        guard pods[0].name == "search-api-7f9c6d5b4-x2x8p", pods[0].ready == "1/1",
              pods[0].status == "Running", pods[0].restarts == 0, pods[0].age == "2d4h" else {
            return "pod 0 parsed wrong: \(pods[0])"
        }
        guard pods[0].cpu == "120m", pods[0].memory == "512Mi" else {
            return "metrics were not joined onto pod 0: \(String(describing: pods[0].cpu))"
        }
        // `4 (2m ago)` - the leading integer, not the whole field.
        guard pods[1].restarts == 4 else { return "restarts parsed as \(pods[1].restarts), expected 4" }
        guard pods[2].status == "ImagePullBackOff" else { return "pod 2 status: \(pods[2].status)" }
        // A pod with no `top` row keeps `nil` metrics rather than a fake zero.
        guard pods[2].cpu == nil else { return "pod 2 invented metrics: \(String(describing: pods[2].cpu))" }
        return nil
    }

    private static func test_parse_podsWithoutMetricsServer() -> String? {
        let noMetrics = "error: Metrics API not available"
        guard case .rows(let pods) = KubeResourceParser.parsePods(getRaw: podsWide, topRaw: noMetrics) else {
            return "a failing `top` blanked out the pod list"
        }
        guard pods.count == 3 else { return "expected 3 pods, got \(pods.count)" }
        guard pods.allSatisfy({ $0.cpu == nil }) else { return "metrics were invented from an error message" }
        return nil
    }

    /// The point of reading by column *name*: a kubectl that reorders or adds
    /// columns must not mis-assign values.
    private static func test_parse_podsReadsColumnsByNameNotPosition() -> String? {
        let reordered = """
        STATUS    NAME        AGE    READY   RESTARTS   NOMINATED NODE
        Running   api-0       9d     1/1     2          <none>
        """
        guard case .rows(let pods) = KubeResourceParser.parsePods(getRaw: reordered) else { return "expected rows" }
        guard pods.count == 1, pods[0].name == "api-0", pods[0].status == "Running",
              pods[0].ready == "1/1", pods[0].restarts == 2, pods[0].age == "9d" else {
            return "column-name lookup failed: \(pods)"
        }
        return nil
    }

    private static func test_parse_podsSkipsKubectlWarningLinesBeforeTheHeader() -> String? {
        let noisy = "W0904 11:02:31.482913 1 warnings.go:70] v1 Endpoints is deprecated\n" + podsWide
        guard case .rows(let pods) = KubeResourceParser.parsePods(getRaw: noisy) else {
            return "a stderr warning ahead of the table turned a good result into a failure"
        }
        guard pods.count == 3 else { return "expected 3 pods, got \(pods.count)" }
        return nil
    }

    /// GL-14's rule: an empty namespace and a failed fetch must not render
    /// the same.
    private static func test_parse_emptyNamespaceIsNotAFailure() -> String? {
        guard case .empty = KubeResourceParser.parsePods(getRaw: "No resources found in raas-prod namespace.") else {
            return "an empty namespace was not reported as empty"
        }
        return nil
    }

    private static func test_parse_shellErrorIsAFailureNotAnEmptyList() -> String? {
        for raw in ["-bash: kubectl: command not found",
                    "error: You must be logged in to the server (Unauthorized)",
                    "The connection to the server localhost:8080 was refused - did you specify the right host or port?"] {
            guard case .failed(let message) = KubeResourceParser.parsePods(getRaw: raw) else {
                return "\(raw.prefix(30))\u{2026} was not reported as a failure"
            }
            guard !message.isEmpty else { return "a failure carried no message" }
        }
        return nil
    }

    private static func test_parse_deployments() -> String? {
        let raw = """
        NAME             READY   UP-TO-DATE   AVAILABLE   AGE
        search-api       2/2     2            2           31d
        contract-ingest  1/3     3            1           31d
        """
        guard case .rows(let deployments) = KubeResourceParser.parseDeployments(raw) else { return "expected rows" }
        guard deployments.count == 2 else { return "expected 2, got \(deployments.count)" }
        guard deployments[0].isFullyReady, !deployments[1].isFullyReady else {
            return "readiness classification wrong: \(deployments)"
        }
        return nil
    }

    /// `MESSAGE` is a trailing free-text column: without treating it as one,
    /// "Failed to pull image" is split on its own spaces and truncated at the
    /// first word.
    private static func test_parse_eventsKeepsTheWholeMessageColumn() -> String? {
        let raw = """
        LAST SEEN   TYPE      REASON      OBJECT                            MESSAGE
        2m          Warning   Failed      pod/billing-cron-29471120-tzkkd   Failed to pull image "registry.example/billing-cron:9.1.4":  not found
        14m         Normal    Scheduled   pod/search-api-7f9c6d5b4-x2x8p    Successfully assigned raas-prod/search-api to ip-10-40-3-112
        """
        guard case .rows(let events) = KubeResourceParser.parseEvents(raw) else { return "expected rows" }
        guard events.count == 2 else { return "expected 2 events, got \(events.count)" }
                // The doubled space before "not found" is deliberate and is what
        // makes `lastColumnIsFreeText` load-bearing: without it the message is
        // split on that run and truncated at "…:". Real kubelet messages do
        // carry doubled spaces, so this is the fixture's own shape, not a
        // contrivance.
        guard events[0].message == "Failed to pull image \"registry.example/billing-cron:9.1.4\":  not found" else {
            return "message truncated: \(events[0].message)"
        }
        guard events[0].lastSeen == "2m", events[0].reason == "Failed",
              events[0].object == "pod/billing-cron-29471120-tzkkd", events[0].isWarning else {
            return "event 0 parsed wrong: \(events[0])"
        }
        guard !events[1].isWarning else { return "a Normal event was flagged as a warning" }
        return nil
    }

    private static func test_parse_podHealthClassification() -> String? {
        func pod(_ ready: String, _ status: String) -> KubePod {
            KubePod(name: "p", ready: ready, status: status, restarts: 0, age: "1h", node: nil)
        }
        let expectations: [(KubePod, KubePod.Health, String)] = [
            (pod("1/1", "Running"), .healthy, "a fully-ready Running pod"),
            // A finished Job pod is terminal-and-fine, not broken.
            (pod("0/1", "Completed"), .healthy, "a Completed job pod"),
            (pod("1/2", "Running"), .warning, "Running but not all containers ready"),
            (pod("0/1", "Pending"), .warning, "Pending"),
            (pod("0/1", "ContainerCreating"), .warning, "ContainerCreating"),
            (pod("0/1", "CrashLoopBackOff"), .bad, "CrashLoopBackOff"),
            (pod("0/1", "ImagePullBackOff"), .bad, "ImagePullBackOff"),
            (pod("0/1", "Error"), .bad, "Error"),
        ]
        for (candidate, expected, label) in expectations where candidate.health != expected {
            return "\(label) classified as \(candidate.health), expected \(expected)"
        }
        return nil
    }

    // MARK: Log tail

    private static func test_log_parsesTimestampedLines() -> String? {
        let raw = "2026-09-04T11:02:31.482913204Z starting up\n2026-09-04T11:02:32.100000000Z ERROR upstream timed out"
        let lines = KubeLogParser.parseBlock(raw, pod: "api-0")
        guard lines.count == 2 else { return "expected 2 lines, got \(lines.count)" }
        guard lines[0].text == "starting up", lines[0].timestamp != nil, !lines[0].isError else {
            return "line 0 parsed wrong: \(lines[0])"
        }
        guard lines[1].isError else { return "an ERROR line was not flagged" }
        guard let a = lines[0].timestamp, let b = lines[1].timestamp, b > a else {
            return "timestamps did not order correctly"
        }
        return nil
    }

    /// A triage tool that silently discards the one line explaining why there
    /// are no lines is worse than useless.
    private static func test_log_keepsALineWithNoTimestamp() -> String? {
        let raw = "unable to retrieve container logs for containerd://abc"
        let lines = KubeLogParser.parseBlock(raw, pod: "api-0")
        guard lines.count == 1 else { return "the line was dropped" }
        guard lines[0].timestamp == nil, lines[0].text == raw else { return "line parsed wrong: \(lines[0])" }
        return nil
    }

    private static func test_log_mergesTwoPodsInTimestampOrder() -> String? {
        let merger = KubeLogMerger()
        merger.append(KubeLogParser.parseBlock(
            "2026-09-04T11:00:03.000000000Z b-second\n2026-09-04T11:00:05.000000000Z b-fourth", pod: "pod-b"))
        merger.append(KubeLogParser.parseBlock(
            "2026-09-04T11:00:01.000000000Z a-first\n2026-09-04T11:00:04.000000000Z a-third", pod: "pod-a"))
        let texts = merger.lines.map(\.text)
        guard texts == ["a-first", "b-second", "a-third", "b-fourth"] else {
            return "merged out of order: \(texts)"
        }
        return nil
    }

    /// The `--since` window deliberately overlaps consecutive polls so no line
    /// falls in the gap - which guarantees duplicates, and this is what
    /// collapses them.
    private static func test_log_dedupesOverlappingPolls() -> String? {
        let merger = KubeLogMerger()
        let block = "2026-09-04T11:00:01.000000000Z one\n2026-09-04T11:00:02.000000000Z two"
        let firstAdded = merger.append(KubeLogParser.parseBlock(block, pod: "api"))
        let secondAdded = merger.append(KubeLogParser.parseBlock(
            block + "\n2026-09-04T11:00:03.000000000Z three", pod: "api"))
        guard firstAdded == 2 else { return "first poll added \(firstAdded), expected 2" }
        guard secondAdded == 1 else { return "overlapping poll added \(secondAdded) lines, expected only the new one" }
        guard merger.lines.count == 3 else { return "window holds \(merger.lines.count) lines, expected 3" }
        // The same text from a *different* pod is genuinely a different line.
        let other = merger.append(KubeLogParser.parseBlock(block, pod: "worker"))
        guard other == 2 else { return "another pod's identical lines were deduped away" }
        return nil
    }

    private static func test_log_capsTheWindow() -> String? {
        let merger = KubeLogMerger(maxLines: 50)
        for i in 0..<200 {
            let stamp = String(format: "2026-09-04T11:00:%02d.%06d000Z", i / 1000, i)
            merger.append(KubeLogParser.parseBlock("\(stamp) line-\(i)", pod: "api"))
        }
        guard merger.lines.count == 50 else { return "window is \(merger.lines.count) lines, expected 50" }
        guard merger.lines.last?.text == "line-199" else {
            return "the cap dropped the newest instead of the oldest: last is \(merger.lines.last?.text ?? "nil")"
        }
        return nil
    }

    /// Stable by first appearance, never by hash and never re-sorted - a
    /// colour that moved when an unrelated pod appeared would break the mental
    /// map the captain builds within seconds.
    private static func test_log_assignsStableColoursByFirstAppearance() -> String? {
        let merger = KubeLogMerger()
        merger.registerPod("alpha")
        merger.registerPod("beta")
        let alphaTint = merger.tint(for: "alpha")
        let betaTint = merger.tint(for: "beta")
        guard alphaTint != betaTint else { return "two pods got the same colour" }
        merger.registerPod("gamma")
        merger.append(KubeLogParser.parseBlock("2026-09-04T11:00:01.000000000Z x", pod: "delta"))
        guard merger.tint(for: "alpha") == alphaTint, merger.tint(for: "beta") == betaTint else {
            return "an existing pod's colour moved when new pods appeared"
        }
        // A clear empties the window but must not reshuffle the colour map -
        // the captain's selection has not changed.
        merger.clear()
        guard merger.tint(for: "alpha") == alphaTint else { return "clear() reshuffled the colour map" }
        // `.critical` is reserved for error lines and `.neutral` is the ink,
        // so neither may ever be handed to a pod.
        for index in 0..<20 {
            let tint = KubeLogPalette.tint(forPodAt: index)
            guard tint != .critical, tint != .neutral else { return "pod colour \(index) used a reserved tint" }
        }
        return nil
    }

    private static func test_log_errorsOnlyFilter() -> String? {
        let merger = KubeLogMerger()
        merger.append(KubeLogParser.parseBlock("""
        2026-09-04T11:00:01.000000000Z all good
        2026-09-04T11:00:02.000000000Z ERROR upstream timed out
        2026-09-04T11:00:03.000000000Z still fine
        """, pod: "api"))
        guard merger.visibleLines(errorsOnly: false).count == 3 else { return "unfiltered view is wrong" }
        let errors = merger.visibleLines(errorsOnly: true)
        guard errors.count == 1, errors[0].text.contains("upstream timed out") else {
            return "errors-only filter returned \(errors.map(\.text))"
        }
        return nil
    }

    /// Sampling exactly one poll interval every poll interval loses every line
    /// that lands in the gap between one command finishing and the next
    /// starting - and the bridge's own queueing makes that gap variable.
    private static func test_log_sinceWindowIsWiderThanThePollInterval() -> String? {
        guard Double(KubeLogTailSession.sinceSeconds) > KubeLogTailSession.pollInterval else {
            return "the --since window (\(KubeLogTailSession.sinceSeconds)s) does not overlap the "
                + "\(KubeLogTailSession.pollInterval)s poll, so lines can fall between polls"
        }
        // The scout report's own reasoned range for the cadence.
        guard (5.0...10.0).contains(KubeLogTailSession.pollInterval) else {
            return "poll interval \(KubeLogTailSession.pollInterval)s is outside the report's 5-10s range"
        }
        guard KubeLogTailSession.limitsNote.lowercased().contains("not live streaming") else {
            return "the UI's own limits note no longer says this is not live streaming"
        }
        return nil
    }
}
#endif
