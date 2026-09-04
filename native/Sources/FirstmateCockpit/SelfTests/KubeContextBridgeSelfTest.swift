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

// GL-27: compiled into debug builds only - see `SRELeadBridgeSelfTest.swift`'s
// header for the full reasoning. Do not remove this guard: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

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
}

#endif
