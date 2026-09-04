// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-context-badge`: a self-contained, dependency-free
// regression check for `KubeContextParser`'s parsing logic and
// `KubeContextBridge`'s polling/extraction/busy-detection/cross-bridge-guard
// logic, run against `FakeBridgeTerminal` - the same lightweight
// `SRELeadBridgeTerminal` stand-in `SRELeadBridgeSelfTest.swift` already
// defines (reused here rather than duplicated; both files are compiled
// together under `#if FM_SELFTESTS`). See that file's header for why this
// project has no `swift test`/XCTest story at all and uses this "env-var-
// gated, run and read the result" convention instead:
//
//   swift build && FM_RUN_KUBE_CONTEXT_BRIDGE_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// This is the "verify the local Swift-side mechanism thoroughly" half of the
// acceptance bar - the Python allowlist widening (`config get-contexts`/
// `current-context` only, every write form of `config` still refused) has
// its own tests in `native/Scripts/test_sre_kubectl_mcp.py`'s
// `ConfigSubcommandTests`/`BridgeRequestTests`.
//
// A real, generation-equivalent end-to-end check (this badge's own marker-
// injection mechanism running against a real `TabModel`/`CockpitTerminalView`
// child process, not `FakeBridgeTerminal`) was also run once by hand against
// a faked `kubectl` shim - this sandbox has neither a real Kubernetes host
// nor a real `kubectl` binary on PATH - and is not part of this permanent
// suite; see this task's PR description for that transcript.
//
// `fm/grandline-k8s-badge-fixes` extended this file rather than replacing it,
// per that task's own instruction, with three more groups of cases for the
// captain's three reported issues:
//
//   - `bridge_*GiveUp*`/`bridge_*Retry*`/`bridge_busyRefusalsNeverCountTowardGiveUp`
//     (issue 1, backoff/stop-retrying) - still `FakeBridgeTerminal`-driven,
//     same shape as the existing `bridge_*` cases above.
//   - `parser_shortLabel*`/`kubeContextInfo_shortLabelMatchesParser`
//     (issue 2, short-label extraction) - pure logic, no terminal at all.
//   - `perTab_*` (issue 3, per-tab-not-per-host activation) - the one group
//     that needs more than `FakeBridgeTerminal`: proving the toolbar toggle
//     genuinely activates only the tab a captain is looking at needs a real
//     `ConsoleController`/`TabModel`, so these drive the real
//     `toggleKubeContextBadge()`/`activateKubeContextBadge(for:)` through a
//     real (if unreachable, per this file's own existing convention -
//     127.0.0.1 with a 1s connect timeout) `.ssh` tab, exactly the way
//     `SRELeadPerTabSelfTest.swift` proves SRE Lead's own per-tab isolation.
//     No real `kubectl` round trip is needed for this: the isolation claim
//     is "did activating tab A ever construct/start a bridge object for tab
//     B" - a synchronous, object-level fact checked immediately after the
//     real toggle click, not something a completed command result is needed
//     to observe.

// GL-27: compiled into debug builds only - see `SRELeadBridgeSelfTest.swift`'s
// header for the full reasoning. Do not remove this guard: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum KubeContextBridgeSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            // KubeContextParser - pure logic, no terminal at all.
            ("parser_parsesCurrentContextAndNamespace", test_parser_parsesCurrentContextAndNamespace),
            ("parser_defaultsNamespaceWhenColumnIsBlank", test_parser_defaultsNamespaceWhenColumnIsBlank),
            ("parser_defaultsNamespaceWhenRowNotFound", test_parser_defaultsNamespaceWhenRowNotFound),
            ("parser_failsCleanlyWhenNoCurrentContextIsSet", test_parser_failsCleanlyWhenNoCurrentContextIsSet),
            ("parser_failsCleanlyWhenKubectlIsNotFound", test_parser_failsCleanlyWhenKubectlIsNotFound),
            ("parser_looksLikeProductionMatchesCaseInsensitiveSubstring", test_parser_looksLikeProductionMatchesCaseInsensitiveSubstring),
            ("parser_preprodAlsoFlagsAsLooksLikeProduction", test_parser_preprodAlsoFlagsAsLooksLikeProduction),

            // Issue 2: short-label extraction - pure logic, no terminal at all.
            ("parser_shortLabelExtractsEksArnClusterName", test_parser_shortLabelExtractsEksArnClusterName),
            ("parser_shortLabelFallsBackVerbatimForNonArnShapes", test_parser_shortLabelFallsBackVerbatimForNonArnShapes),
            ("parser_shortLabelFallsBackForArnWithNoClusterSegment", test_parser_shortLabelFallsBackForArnWithNoClusterSegment),
            ("kubeContextInfo_shortLabelMatchesParser", test_kubeContextInfo_shortLabelMatchesParser),

            // KubeContextBridge - the marker-injection mechanism, via FakeBridgeTerminal.
            ("bridge_refreshInjectsOneCombinedCommandAndParsesResult", test_bridge_refreshInjectsOneCombinedCommandAndParsesResult),
            ("bridge_refusesWhenCaptainRecentlyTyped", test_bridge_refusesWhenCaptainRecentlyTyped),
            ("bridge_neverInjectsWhenCaptainRecentlyTyped", test_bridge_neverInjectsWhenCaptainRecentlyTyped),
            ("bridge_refusesWhenSiblingBridgeIsBusy", test_bridge_refusesWhenSiblingBridgeIsBusy),
            ("bridge_refusesConcurrentRefreshWhileOneIsInFlight", test_bridge_refusesConcurrentRefreshWhileOneIsInFlight),
            ("bridge_discardsOutputWhenCaptainTypesWhileRefreshing", test_bridge_discardsOutputWhenCaptainTypesWhileRefreshing),
            ("bridge_timesOutIfEndMarkerNeverAppears", test_bridge_timesOutIfEndMarkerNeverAppears),
            ("bridge_errorsCleanlyWhenTargetTabIsGone", test_bridge_errorsCleanlyWhenTargetTabIsGone),
            ("bridge_doesNotRetryImmediatelyAfterASuccess", test_bridge_doesNotRetryImmediatelyAfterASuccess),
            ("bridge_retriesSoonerAfterABusyRefusalThanAfterSuccess", test_bridge_retriesSoonerAfterABusyRefusalThanAfterSuccess),

            // Issue 1: backoff and a real give-up state.
            ("bridge_stopsRetryingAfterConsecutiveGenuineFailures", test_bridge_stopsRetryingAfterConsecutiveGenuineFailures),
            ("bridge_manualRetryAfterGivingUpResetsAndTriesAgain", test_bridge_manualRetryAfterGivingUpResetsAndTriesAgain),
            ("bridge_busyRefusalsNeverCountTowardGiveUp", test_bridge_busyRefusalsNeverCountTowardGiveUp),
            ("bridge_successResetsFailureCount", test_bridge_successResetsFailureCount),

            // Issue 3: per-tab, not per-host, activation - drives a real
            // ConsoleController/TabModel, not FakeBridgeTerminal.
            ("perTab_activatingOnOneTabNeverActivatesAnother", test_perTab_activatingOnOneTabNeverActivatesAnother),
            ("perTab_closingOneActivatedTabLeavesSiblingUntouched", test_perTab_closingOneActivatedTabLeavesSiblingUntouched),
            ("perTab_duplicateNeverInheritsAnAlreadyActivatedBridge", test_perTab_duplicateNeverInheritsAnAlreadyActivatedBridge),
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
            ? "KubeContextBridgeSelfTest: all \(cases.count) cases passed"
            : "KubeContextBridgeSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// Ticks `bridge` until `condition` is true or `maxTicks` is reached.
    private static func tickUntil(_ bridge: KubeContextBridge, maxTicks: Int = 20, _ condition: () -> Bool) {
        for _ in 0..<maxTicks where !condition() {
            bridge.tick()
        }
    }

    private static func markers(in injected: String) -> (start: String, end: String, sep: String)? {
        func find(_ prefix: String) -> String? {
            let pattern = "\(prefix)_[0-9a-fA-F]+"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = injected as NSString
            guard let match = regex.firstMatch(in: injected, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: match.range)
        }
        guard let start = find("GL_KUBECTX_START"), let end = find("GL_KUBECTX_END"), let sep = find("GL_KUBECTX_SEP") else {
            return nil
        }
        return (start, end, sep)
    }

    // MARK: KubeContextParser cases

    private static func test_parser_parsesCurrentContextAndNamespace() -> String? {
        let sep = "SEP123"
        let raw = """
        preprod-eks
        \(sep)
        CURRENT   NAME           CLUSTER        AUTHINFO   NAMESPACE
        *         preprod-eks    preprod-eks    aws        raas-uat
                  dev-eks        dev-eks        aws        default
        """
        switch KubeContextParser.parse(rawCombinedOutput: raw, separator: sep) {
        case .success(let info):
            guard info.contextName == "preprod-eks" else { return "wrong context name: \(info.contextName)" }
            guard info.namespace == "raas-uat" else { return "wrong namespace: \(info.namespace)" }
            return nil
        case .failure(let error):
            return "expected success, got \(error)"
        }
    }

    private static func test_parser_defaultsNamespaceWhenColumnIsBlank() -> String? {
        let sep = "SEP"
        let raw = """
        dev-eks
        \(sep)
        CURRENT   NAME       CLUSTER    AUTHINFO
        *         dev-eks    dev-eks    aws
        """
        switch KubeContextParser.parse(rawCombinedOutput: raw, separator: sep) {
        case .success(let info):
            guard info.namespace == "default" else { return "expected 'default' for a blank namespace column, got \(info.namespace)" }
            return nil
        case .failure(let error):
            return "expected success, got \(error)"
        }
    }

    private static func test_parser_defaultsNamespaceWhenRowNotFound() -> String? {
        // The `get-contexts` half is missing/unparseable (e.g. that command
        // itself failed) - `current-context` alone must still produce a
        // usable badge rather than a total failure.
        let sep = "SEP"
        let raw = "my-context\n\(sep)\nerror: something went wrong"
        switch KubeContextParser.parse(rawCombinedOutput: raw, separator: sep) {
        case .success(let info):
            guard info.contextName == "my-context" else { return "wrong context name: \(info.contextName)" }
            guard info.namespace == "default" else { return "expected 'default' fallback, got \(info.namespace)" }
            return nil
        case .failure(let error):
            return "expected success (current-context alone is enough), got \(error)"
        }
    }

    private static func test_parser_failsCleanlyWhenNoCurrentContextIsSet() -> String? {
        let sep = "SEP"
        let raw = "error: current-context is not set\n\(sep)\nerror: current-context is not set"
        switch KubeContextParser.parse(rawCombinedOutput: raw, separator: sep) {
        case .success(let info):
            return "expected failure, got a fabricated context name: \(info.contextName)"
        case .failure(let error):
            guard case .commandFailed(let message) = error, message.contains("current-context") else {
                return "expected a .commandFailed mentioning current-context, got \(error)"
            }
            return nil
        }
    }

    private static func test_parser_failsCleanlyWhenKubectlIsNotFound() -> String? {
        let sep = "SEP"
        let raw = "zsh: command not found: kubectl\n\(sep)\nzsh: command not found: kubectl"
        switch KubeContextParser.parse(rawCombinedOutput: raw, separator: sep) {
        case .success(let info):
            return "expected failure, got a fabricated context name: \(info.contextName)"
        case .failure:
            return nil
        }
    }

    private static func test_parser_looksLikeProductionMatchesCaseInsensitiveSubstring() -> String? {
        let prod = KubeContextInfo(contextName: "PROD-eks-cluster", namespace: "default")
        guard prod.looksLikeProduction else { return "expected 'PROD-eks-cluster' to match (case-insensitive)" }
        let dev = KubeContextInfo(contextName: "dev-eks", namespace: "default")
        guard !dev.looksLikeProduction else { return "expected 'dev-eks' to NOT match" }
        return nil
    }

    private static func test_parser_preprodAlsoFlagsAsLooksLikeProduction() -> String? {
        // Documented, deliberate behavior: "preprod-eks" contains "prod" as a
        // substring - erring toward caution on a preprod cluster is judged
        // better than a false sense of safety, per this heuristic's own doc
        // comment. This case exists so that behavior can't silently change
        // without someone noticing.
        let preprod = KubeContextInfo(contextName: "preprod-eks", namespace: "raas-uat")
        guard preprod.looksLikeProduction else { return "expected 'preprod-eks' to also match the heuristic" }
        return nil
    }

    // MARK: Issue 2 - short-label extraction

    private static func test_parser_shortLabelExtractsEksArnClusterName() -> String? {
        // The captain's own real, reported shape.
        let arn = "arn:aws:eks:us-east-1:682528822458:cluster/raas-prod"
        let got = KubeContextParser.shortLabel(for: arn)
        guard got == "raas-prod" else { return "expected 'raas-prod', got '\(got)'" }
        return nil
    }

    private static func test_parser_shortLabelFallsBackVerbatimForNonArnShapes() -> String? {
        // None of these are the ARN shape - every one must come back
        // byte-for-byte unchanged rather than being mangled or guessed at.
        let names = ["dev-eks", "minikube", "preprod-eks", "docker-desktop", ""]
        for name in names {
            let got = KubeContextParser.shortLabel(for: name)
            guard got == name else { return "expected '\(name)' unchanged, got '\(got)'" }
        }
        return nil
    }

    private static func test_parser_shortLabelFallsBackForArnWithNoClusterSegment() -> String? {
        // A real ARN this app has never seen (no "cluster/" segment at all) -
        // starting with "arn:" alone must not be enough to trigger shortening.
        let arn = "arn:aws:iam::682528822458:role/some-role"
        let got = KubeContextParser.shortLabel(for: arn)
        guard got == arn else { return "expected the raw ARN unchanged, got '\(got)'" }
        return nil
    }

    private static func test_kubeContextInfo_shortLabelMatchesParser() -> String? {
        let info = KubeContextInfo(contextName: "arn:aws:eks:us-east-1:682528822458:cluster/raas-prod", namespace: "default")
        guard info.shortLabel == "raas-prod" else {
            return "expected KubeContextInfo.shortLabel to match the parser, got '\(info.shortLabel)'"
        }
        return nil
    }

    // MARK: KubeContextBridge cases

    private static func test_bridge_refreshInjectsOneCombinedCommandAndParsesResult() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        fake.onSendCommand = { injected in
            guard let (start, end, sep) = markers(in: injected) else { return }
            let output = "preprod-eks\n\(sep)\nCURRENT   NAME           CLUSTER   AUTHINFO   NAMESPACE\n*         preprod-eks    x         aws        raas-uat\n"
            fake.appendOutput("\(start)\n\(output)\(end)")
        }

        bridge.refreshNow()
        tickUntil(bridge) { !results.isEmpty }

        guard fake.sentCommands.count == 1 else { return "expected exactly one injected command, got \(fake.sentCommands.count)" }
        let injected = fake.sentCommands[0]
        guard injected.contains("kubectl config current-context") else { return "injected command missing current-context: \(injected)" }
        guard injected.contains("kubectl config get-contexts") else { return "injected command missing get-contexts: \(injected)" }
        guard let result = results.first else { return "onUpdate never fired" }
        switch result {
        case .success(let info):
            guard info.contextName == "preprod-eks", info.namespace == "raas-uat" else {
                return "unexpected parsed info: \(info)"
            }
            return nil
        case .failure(let error):
            return "expected success, got \(error)"
        }
    }

    private static func test_bridge_refusesWhenCaptainRecentlyTyped() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date()
        let bridge = KubeContextBridge(target: fake, userActivityQuietWindow: 5)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.refreshNow()

        guard let result = results.first else { return "onUpdate never fired" }
        guard case .failure(.busy) = result else { return "expected .busy, got \(result)" }
        return nil
    }

    private static func test_bridge_neverInjectsWhenCaptainRecentlyTyped() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date()
        let bridge = KubeContextBridge(target: fake, userActivityQuietWindow: 5)
        bridge.refreshNow()
        guard fake.sentCommands.isEmpty else { return "command was injected despite recent captain activity" }
        return nil
    }

    private static func test_bridge_refusesWhenSiblingBridgeIsBusy() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake)
        bridge.isTerminalBusyElsewhere = { true } // simulates SRE Lead's own bridge mid-command
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.refreshNow()

        guard fake.sentCommands.isEmpty else { return "command was injected despite the sibling bridge being busy" }
        guard let result = results.first, case .failure(.busy) = result else {
            return "expected .busy, got \(String(describing: results.first))"
        }
        return nil
    }

    private static func test_bridge_refusesConcurrentRefreshWhileOneIsInFlight() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.refreshNow() // injects, markers not resolved yet
        guard fake.sentCommands.count == 1 else { return "expected exactly one injected command after the first refreshNow(), got \(fake.sentCommands.count)" }

        bridge.refreshNow() // must be refused, not queued and not double-injected
        guard fake.sentCommands.count == 1 else {
            return "a second refreshNow() while one was in flight injected a second command (count=\(fake.sentCommands.count))"
        }
        guard let second = results.first, case .failure(.busy) = second else {
            return "expected the concurrent refreshNow() to report .busy, got \(String(describing: results.first))"
        }

        // The original request can still complete normally afterward.
        guard let (start, end, sep) = markers(in: fake.sentCommands[0]) else { return "could not find markers in injected command" }
        fake.appendOutput("\(start)\nmy-ctx\n\(sep)\n\(end)")
        tickUntil(bridge) { results.count >= 2 }
        guard results.count >= 2, case .success = results[1] else {
            return "the original in-flight refresh did not complete successfully afterward: \(results)"
        }
        return nil
    }

    private static func test_bridge_discardsOutputWhenCaptainTypesWhileRefreshing() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.refreshNow()
        guard let (start, end, sep) = markers(in: fake.sentCommands.first ?? "") else { return "could not find markers in injected command" }

        fake.lastUserActivity = Date() // the captain types mid-refresh
        fake.appendOutput("\(start)\nmy-ctx\n\(sep)\n\(end)")

        tickUntil(bridge) { !results.isEmpty }
        guard let result = results.first else { return "onUpdate never fired" }
        guard case .failure(.discarded) = result else { return "expected .discarded, got \(result)" }
        return nil
    }

    private static func test_bridge_timesOutIfEndMarkerNeverAppears() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake, commandTimeout: 0)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.refreshNow() // injects
        bridge.tick()       // commandTimeout is 0, so this tick already sees it as timed out

        guard let result = results.first else { return "onUpdate never fired" }
        guard case .failure(.timeout) = result else { return "expected .timeout, got \(result)" }
        return nil
    }

    private static func test_bridge_errorsCleanlyWhenTargetTabIsGone() -> String? {
        final class Holder { var fake: FakeBridgeTerminal? = FakeBridgeTerminal() }
        let holder = Holder()
        let bridge = KubeContextBridge(target: holder.fake!)
        holder.fake = nil // simulates the tab being closed

        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.refreshNow()

        guard let result = results.first else { return "onUpdate never fired" }
        guard case .failure(.unavailable) = result else { return "expected .unavailable, got \(result)" }
        return nil
    }

    private static func test_bridge_doesNotRetryImmediatelyAfterASuccess() -> String? {
        let fake = FakeBridgeTerminal()
        // A long refreshInterval - if the cooldown weren't respected, a
        // second `tick()` right after a success would inject again.
        let bridge = KubeContextBridge(target: fake, refreshInterval: 100)
        fake.onSendCommand = { injected in
            guard let (start, end, sep) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nmy-ctx\n\(sep)\n\(end)")
        }

        bridge.refreshNow()
        tickUntil(bridge) { fake.sentCommands.count >= 1 } // let it complete
        guard fake.sentCommands.count == 1 else { return "expected exactly one command before the cooldown check" }

        for _ in 0..<10 { bridge.tick() } // idle ticks - none of these should inject again
        guard fake.sentCommands.count == 1 else {
            return "retried before refreshInterval elapsed - sentCommands.count=\(fake.sentCommands.count)"
        }
        return nil
    }

    private static func test_bridge_retriesSoonerAfterABusyRefusalThanAfterSuccess() -> String? {
        let fake = FakeBridgeTerminal()
        // A short busy-retry window and a much longer ordinary refresh
        // interval - proves the two cadences genuinely differ, without
        // sleeping for the production 30s/5s defaults.
        let bridge = KubeContextBridge(target: fake, refreshInterval: 100, busyRetryInterval: 0.05)
        fake.lastUserActivity = Date() // busy on the first attempt

        bridge.refreshNow()
        guard fake.sentCommands.isEmpty else { return "expected the first attempt to be refused as busy, not injected" }

        // Once the captain stops "typing" and the short busy-retry window
        // has elapsed, the next tick should try again for real.
        fake.lastUserActivity = nil
        Thread.sleep(forTimeInterval: 0.1)
        bridge.tick()

        guard fake.sentCommands.count == 1 else {
            return "expected a retry after the busy window elapsed, got \(fake.sentCommands.count) injected command(s)"
        }
        return nil
    }

    // MARK: Issue 1 - backoff and a real give-up state

    private static func kubectlNotFoundOutput(start: String, sep: String, end: String) -> String {
        // Matches `test_parser_failsCleanlyWhenKubectlIsNotFound`'s own
        // shape - a real, common failure with no `kubectl` on PATH at all,
        // which is exactly the captain's own reported case (a plain
        // entry-hop bastion) - see `KubeContextBridge.swift`'s header, issue 3.
        "\(start)\nzsh: command not found: kubectl\n\(sep)\nzsh: command not found: kubectl\n\(end)"
    }

    private static func test_bridge_stopsRetryingAfterConsecutiveGenuineFailures() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake, failureRetryInterval: 0.05, maxConsecutiveFailures: 2)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }
        fake.onSendCommand = { injected in
            guard let (start, end, sep) = markers(in: injected) else { return }
            fake.appendOutput(kubectlNotFoundOutput(start: start, sep: sep, end: end))
        }

        bridge.start()
        tickUntil(bridge) { results.count >= 1 }
        guard results.count == 1, case .failure(.commandFailed) = results[0] else {
            return "expected the first attempt to be a genuine command failure, got \(results)"
        }
        guard !bridge.hasStoppedRetrying else { return "should not give up after only 1 of 2 allowed failures" }
        guard fake.sentCommands.count == 1 else { return "expected exactly 1 injected command so far, got \(fake.sentCommands.count)" }

        // Let the short failure-retry cooldown elapse and drive the poll
        // loop by hand, per this suite's own convention.
        Thread.sleep(forTimeInterval: 0.1)
        bridge.tick()
        tickUntil(bridge) { results.count >= 2 }
        guard fake.sentCommands.count == 2 else { return "expected a second attempt after the retry cooldown elapsed, got \(fake.sentCommands.count) injected command(s)" }
        guard bridge.hasStoppedRetrying else { return "expected the bridge to give up after 2 consecutive genuine failures" }
        guard let last = bridge.lastFailureMessage, last.contains("kubectl") else {
            return "expected lastFailureMessage to carry the real failure text, got \(String(describing: bridge.lastFailureMessage))"
        }

        // Issue 1's own acceptance bar: no further automatic retry, ever -
        // not even once the retry cooldown would ordinarily have elapsed
        // again, and not even across a dozen further idle ticks.
        Thread.sleep(forTimeInterval: 0.1)
        for _ in 0..<10 { bridge.tick() }
        guard fake.sentCommands.count == 2, results.count == 2 else {
            return "the bridge kept retrying after giving up - sentCommands=\(fake.sentCommands.count) results=\(results.count)"
        }
        return nil
    }

    private static func test_bridge_manualRetryAfterGivingUpResetsAndTriesAgain() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake, failureRetryInterval: 0.05, maxConsecutiveFailures: 1)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }
        var succeed = false
        fake.onSendCommand = { injected in
            guard let (start, end, sep) = markers(in: injected) else { return }
            if succeed {
                fake.appendOutput("\(start)\nmy-ctx\n\(sep)\n\(end)")
            } else {
                fake.appendOutput(kubectlNotFoundOutput(start: start, sep: sep, end: end))
            }
        }

        bridge.start()
        tickUntil(bridge) { results.count >= 1 }
        guard bridge.hasStoppedRetrying else { return "expected the bridge to give up after the one allowed failure (maxConsecutiveFailures=1)" }
        guard fake.sentCommands.count == 1 else { return "expected exactly 1 injected command before the retry click" }

        // Even a long wait with several idle ticks must never retry on its
        // own once given up.
        Thread.sleep(forTimeInterval: 0.1)
        for _ in 0..<5 { bridge.tick() }
        guard fake.sentCommands.count == 1 else { return "the bridge retried automatically after giving up" }

        // The captain's own explicit "try again" click -
        // `ConsoleController.activateKubeContextBadge` calls exactly this
        // (`bridge.start()`) on an already-`hasStoppedRetrying` badge.
        succeed = true
        bridge.start()
        guard !bridge.hasStoppedRetrying else { return "start() should clear hasStoppedRetrying immediately, before any result comes back" }
        tickUntil(bridge) { results.count >= 2 }
        guard fake.sentCommands.count == 2 else { return "the manual retry should have injected a fresh command, got \(fake.sentCommands.count)" }
        guard case .success(let info) = results[1], info.contextName == "my-ctx" else {
            return "expected the manual retry to succeed this time, got \(results[1])"
        }
        guard !bridge.hasStoppedRetrying else { return "a successful manual retry should leave hasStoppedRetrying cleared" }
        return nil
    }

    private static func test_bridge_busyRefusalsNeverCountTowardGiveUp() -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date() // "busy" for the whole test - never actually injected
        let bridge = KubeContextBridge(target: fake, busyRetryInterval: 0.02, maxConsecutiveFailures: 2, userActivityQuietWindow: 1000)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }

        bridge.start()
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.03)
            bridge.tick()
        }
        guard fake.sentCommands.isEmpty else { return "a persistently busy tab should never have a command injected, got \(fake.sentCommands.count)" }
        guard results.count >= 5 else { return "expected several .busy refusals to have been reported, got \(results.count)" }
        for result in results {
            guard case .failure(.busy) = result else { return "expected every result to be .busy, got \(result)" }
        }
        guard !bridge.hasStoppedRetrying else { return "repeated .busy refusals (maxConsecutiveFailures=2) must never trip give-up on their own" }
        return nil
    }

    private static func test_bridge_successResetsFailureCount() -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = KubeContextBridge(target: fake, failureRetryInterval: 0.05, maxConsecutiveFailures: 2)
        var results: [Result<KubeContextInfo, KubeContextError>] = []
        bridge.onUpdate = { results.append($0) }
        // Fails once, then succeeds forever after - one failure alone must
        // never linger and contribute to a LATER, unrelated run of failures.
        var attempt = 0
        fake.onSendCommand = { injected in
            guard let (start, end, sep) = markers(in: injected) else { return }
            attempt += 1
            if attempt == 1 {
                fake.appendOutput(kubectlNotFoundOutput(start: start, sep: sep, end: end))
            } else {
                fake.appendOutput("\(start)\nmy-ctx\n\(sep)\n\(end)")
            }
        }

        bridge.start()
        tickUntil(bridge) { results.count >= 1 }
        guard !bridge.hasStoppedRetrying else { return "a single failure alone (below maxConsecutiveFailures=2) should not give up" }

        Thread.sleep(forTimeInterval: 0.1)
        bridge.tick()
        tickUntil(bridge) { results.count >= 2 }
        guard case .success = results[1] else { return "expected the second attempt to succeed, got \(results[1])" }
        guard !bridge.hasStoppedRetrying else { return "a success must clear any prior failure count" }
        return nil
    }

    // MARK: Issue 3 - per-tab, not per-host, activation
    //
    // Drives a real `ConsoleController`/`TabModel` through the real
    // `openSSH`/`toggleKubeContextBadge()` machinery - not `FakeBridgeTerminal`
    // - the same way `SRELeadPerTabSelfTest.swift` proves SRE Lead's own
    // per-tab isolation. No real Kubernetes host or `kubectl` binary is
    // needed: the claim under test is purely structural (did activating one
    // tab ever construct/start a bridge object for another), which is a
    // synchronous, object-level fact right after the real toggle click - see
    // this file's own header for why that's sufficient, concrete proof
    // rather than an assumption.

    /// A real, non-Firstmate `ConsoleController` (a dedicated host page)
    /// mounted in a real `NSWindow`, with `tabCount` real `.ssh` tabs opened
    /// via the real `openSSH` path, every one of them eligible for the badge
    /// toggle (`kubeContextBadgeOptIn: true`) - mirrors
    /// `SRELeadPerTabSelfTest.makeStartedTestConsole()`.
    private static func makeStartedKubeContextTestConsole(tabCount: Int) -> (window: NSWindow, controller: ConsoleController, tabIDs: [UUID]) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        for i in 0..<tabCount {
            controller.openSSH(
                label: "Kube Badge Test Host \(i + 1)",
                args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
                accentHex: nil, keyID: nil, startupSnippetID: nil, kubeContextBadgeOptIn: true
            )
        }
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller, controller.debugAllTabIDs())
    }

    private static func test_perTab_activatingOnOneTabNeverActivatesAnother() -> String? {
        let (window, controller, ids) = makeStartedKubeContextTestConsole(tabCount: 2)
        _ = window
        guard ids.count == 2 else { return "expected 2 tabs, got \(ids.count)" }
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugSelectTab(tabA)
        guard controller.debugKubeContextBridgeExists(forTabID: tabA) == false else { return "tab A should start unactivated" }
        guard controller.debugKubeContextBridgeExists(forTabID: tabB) == false else { return "tab B should start unactivated" }
        guard controller.debugKubeContextBadgeStatus(forTabID: tabA) == .notStarted else { return "tab A should start .notStarted" }
        guard controller.debugKubeContextBadgeStatus(forTabID: tabB) == .notStarted else { return "tab B should start .notStarted" }

        // The real toolbar toggle's own click path - operates on whichever
        // tab is `currentTab`, exactly like a captain clicking the toolbar
        // button while looking at tab A. Only tab A is ever selected here.
        controller.debugToggleKubeContextBadge()

        guard controller.debugKubeContextBridgeExists(forTabID: tabA) == true else {
            return "activating the toggle while tab A is current should create tab A's own bridge"
        }
        guard controller.debugKubeContextBadgeStatus(forTabID: tabA) != .notStarted else {
            return "tab A's status should have moved out of .notStarted"
        }
        guard controller.debugKubeContextBridgeExists(forTabID: tabB) == false else {
            return "activating tab A's badge incorrectly created a bridge for tab B too - per-tab activation is broken"
        }
        guard controller.debugKubeContextBadgeStatus(forTabID: tabB) == .notStarted else {
            return "tab B's status should be completely untouched, got \(String(describing: controller.debugKubeContextBadgeStatus(forTabID: tabB)))"
        }

        // Switching to tab B and activating IT must, symmetrically, never
        // disturb tab A's already-active bridge - two independently
        // activated tabs must coexist without sharing any state.
        controller.debugSelectTab(tabB)
        controller.debugToggleKubeContextBadge()
        guard controller.debugKubeContextBridgeExists(forTabID: tabB) == true else {
            return "activating the toggle while tab B is current should create tab B's own bridge"
        }
        guard controller.debugKubeContextBridgeExists(forTabID: tabA) == true else {
            return "activating tab B's badge must not tear down tab A's already-active bridge"
        }
        return nil
    }

    private static func test_perTab_closingOneActivatedTabLeavesSiblingUntouched() -> String? {
        let (window, controller, ids) = makeStartedKubeContextTestConsole(tabCount: 2)
        _ = window
        guard ids.count == 2 else { return "expected 2 tabs, got \(ids.count)" }
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugSelectTab(tabA)
        controller.debugToggleKubeContextBadge() // activates A
        controller.debugSelectTab(tabB)
        controller.debugToggleKubeContextBadge() // activates B

        guard controller.debugKubeContextBridgeExists(forTabID: tabA) == true, controller.debugKubeContextBridgeExists(forTabID: tabB) == true else {
            return "both tabs should be activated before this test closes one of them"
        }

        controller.debugCloseTab(id: tabA)

        guard controller.debugKubeContextBridgeExists(forTabID: tabA) == nil else {
            return "tab A no longer exists after being closed, so it should report no bridge at all"
        }
        guard controller.debugKubeContextBridgeExists(forTabID: tabB) == true else {
            return "closing tab A must not disturb tab B's own still-active bridge"
        }
        guard controller.debugKubeContextBadgeStatus(forTabID: tabB) != .notStarted else {
            return "closing tab A reset tab B's own badge status"
        }
        return nil
    }

    private static func test_perTab_duplicateNeverInheritsAnAlreadyActivatedBridge() -> String? {
        let (window, controller, ids) = makeStartedKubeContextTestConsole(tabCount: 1)
        _ = window
        guard let source = ids.first else { return "expected 1 tab, got \(ids.count)" }

        controller.debugSelectTab(source)
        controller.debugToggleKubeContextBadge() // activates the source tab
        guard controller.debugKubeContextBridgeExists(forTabID: source) == true else {
            return "the source tab should be activated before duplicating it"
        }

        controller.duplicateTab(id: source)
        let allIDs = controller.debugAllTabIDs()
        guard let duplicate = allIDs.first(where: { $0 != source }) else { return "duplicateTab did not add a new tab" }

        // Eligibility (the toggle being offered at all) IS carried forward -
        // it's still a tab of the same opted-in host - but activation is
        // not, matching `sreLead`'s own "never inherited by a duplicate" rule.
        guard controller.debugKubeContextBridgeExists(forTabID: duplicate) == false else {
            return "a freshly duplicated tab must start unactivated, even though its source tab was already active"
        }
        guard controller.debugKubeContextBadgeStatus(forTabID: duplicate) == .notStarted else {
            return "a freshly duplicated tab's badge status should be .notStarted, got \(String(describing: controller.debugKubeContextBadgeStatus(forTabID: duplicate)))"
        }
        guard controller.debugKubeContextBridgeExists(forTabID: source) == true else {
            return "duplicating the source tab must not disturb its own already-active bridge"
        }
        return nil
    }
}

#endif
