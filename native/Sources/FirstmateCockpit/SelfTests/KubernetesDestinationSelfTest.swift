#if FM_SELFTESTS
// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_KUBERNETES_DESTINATION_TESTS=1 .build/debug/FirstmateCockpit`
//
// `fm/grandline-k8s-cluster-tail`'s window-backed half: the real
// `KubernetesController` mounted in a real `NSWindow`, driven through its own
// real handlers - the scope strip and its honest empty state, feed-tab
// adoption, a full Cluster sweep landing real parsed rows in the real table,
// the describe drawer, a real Log Tail poll producing merged coloured lines,
// the deep link, and the give-up state's own UI.
//
// **Every "cluster" here is a `FakeBridgeTerminal` scripted with real
// `kubectl` output text.** No cluster is reachable from this sandbox (and none
// could be: the credential is a password-gated hop by policy - see
// `sre_kubectl_mcp.py`'s header and the five failed attempts it records), so
// what is proven is the whole path from an injected command's raw text through
// `KubeResourceParser`/`KubeLogMerger` into the rendered rows. The one thing
// this cannot prove is that a real bastion's `kubectl` prints the shapes the
// fixtures use; those are taken verbatim from the scout report's own captured
// output.
//
// Window-backed, so this belongs in `run-all-tests.sh`'s `NEEDS_SESSION` list.
// The pure-logic half (`FM_RUN_KUBE_BRIDGE_TESTS`) runs in CI.

import AppKit

enum KubernetesDestinationSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("emptyStateWhenNoSessionIsLive", test_emptyStateWhenNoSessionIsLive),
            ("scopeStripAppearsWhenASessionGoesLive", test_scopeStripAppearsWhenASessionGoesLive),
            ("scopeIsDroppedWhenItsSessionEnds", test_scopeIsDroppedWhenItsSessionEnds),
            ("feedTabIsNeverAdoptedSilentlyWhenSeveralExist", test_feedTabIsNeverAdoptedSilentlyWhenSeveralExist),
            ("clusterSweepRendersRealParsedPods", test_clusterSweepRendersRealParsedPods),
            ("clusterSweepSurvivesAFailingTopPods", test_clusterSweepSurvivesAFailingTopPods),
            ("clusterRefreshShowsWhyItIsWaitingOnFeedTabActivity", test_clusterRefreshShowsWhyItIsWaitingOnFeedTabActivity),
            ("feedCardCopyWarnsAgainstTypingIntoIt", test_feedCardCopyWarnsAgainstTypingIntoIt),
            ("discardOnMidCommandActivityIsUnchanged", test_discardOnMidCommandActivityIsUnchanged),
            ("emptyNamespaceSaysSoRatherThanLookingBroken", test_emptyNamespaceSaysSoRatherThanLookingBroken),
            ("describeDrawerRunsOneCommandForTheClickedPod", test_describeDrawerRunsOneCommandForTheClickedPod),
            ("eventsTabFetchesOnlyWhenOpened", test_eventsTabFetchesOnlyWhenOpened),
            ("namespaceFieldRefusesAnUnsafeValue", test_namespaceFieldRefusesAnUnsafeValue),
            ("logTailRendersMergedColouredLines", test_logTailRendersMergedColouredLines),
            ("logTailCapsHowManyPodsMayBeSelected", test_logTailCapsHowManyPodsMayBeSelected),
            ("deepLinkOpensPreScopedOnTheTail", test_deepLinkOpensPreScopedOnTheTail),
            ("feedGivesUpAndSaysSoInsteadOfSpammingTheTab", test_feedGivesUpAndSaysSoInsteadOfSpammingTheTab),
            ("givingUpIsNeverADeadEnd", test_givingUpIsNeverADeadEnd),
            ("duplicateButtonAdoptsTheNewTabAsTheFeed", test_duplicateButtonAdoptsTheNewTabAsTheFeed),
            ("noMutatingCommandIsEverInjected", test_noMutatingCommandIsEverInjected),
        ]

        var failures = 0
        for (name, testCase) in cases {
            autoreleasepool {
                if let failure = testCase() {
                    print("FAIL \(name): \(failure)")
                    failures += 1
                } else {
                    print("PASS \(name)")
                }
            }
        }
        print(failures == 0
            ? "KubernetesDestinationSelfTest: all \(cases.count) cases passed"
            : "KubernetesDestinationSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fixtures (verbatim shapes from the scout report's own captures)

    private static let podsWide = """
    NAME                              READY   STATUS             RESTARTS   AGE     IP           NODE
    search-api-7f9c6d5b4-x2x8p        1/1     Running            0          2d4h    10.40.3.17   ip-10-40-3-112
    contract-ingest-worker-0          1/1     Running            4          6h12m   10.40.7.22   ip-10-40-7-201
    billing-cron-29471120-tzkkd       0/1     ImagePullBackOff   0          14m     10.40.5.9    ip-10-40-5-88
    """

    private static let topPods = """
    NAME                              CPU(CORES)   MEMORY(BYTES)
    search-api-7f9c6d5b4-x2x8p        120m         512Mi
    contract-ingest-worker-0          640m         1922Mi
    """

    private static let eventsTable = """
    LAST SEEN   TYPE      REASON      OBJECT                            MESSAGE
    2m          Warning   Failed      pod/billing-cron-29471120-tzkkd   Failed to pull image "registry.example/billing-cron:9.1.4": not found
    """

    private static let describeOutput = """
    Node:         ip-10-40-5-88.ec2.internal
    Controlled By:  Job/billing-cron-29471120
    Events:
      Warning  Failed   2m  kubelet  Failed to pull image
    """

    // MARK: Harness

    /// A mounted page plus the pieces a test drives: the shell-side registry,
    /// the fake feed terminal, and the tabs the access closures hand back.
    private final class Harness {
        let window: NSWindow
        let sessions = HostSessionRegistry()
        let controller: KubernetesController
        let fake = FakeBridgeTerminal()
        let hostID = UUID()
        let feedTabID = UUID()
        var extraTabs: [KubeFeedTab] = []
        private(set) var duplicateCalls = 0
        private(set) var openHostsCalls = 0

        init(offerTabs: Bool = true) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            controller = KubernetesController(sessions: sessions)
            let feedTab = KubeFeedTab(id: feedTabID, name: "EKS Bastion \u{00B7} k8s feed", terminal: fake)
            var access = KubeSessionAccess()
            access.tabs = { [weak self] _ in
                guard let self, offerTabs else { return [] }
                return [feedTab] + self.extraTabs
            }
            access.duplicateTabForFeed = { [weak self] _ in
                self?.duplicateCalls += 1
                return feedTab
            }
            access.openHosts = { [weak self] in self?.openHostsCalls += 1 }
            controller.configure(access: access)
            window.contentView = controller.view
            controller.view.frame = window.contentView?.bounds ?? .zero
            controller.view.layoutSubtreeIfNeeded()
        }

        func goLive(label: String = "EKS Preprod Bastion") {
            sessions.register(hostID: hostID, label: label, accentHex: "6cd7e3")
        }

        func adoptFeed() {
            controller.debugAdoptFeedTab(KubeFeedTab(id: feedTabID, name: "EKS Bastion \u{00B7} k8s feed", terminal: fake))
        }

        /// Scripts the fake to answer each injected command from `answers`,
        /// matched on a substring of the real command text.
        func answer(_ answers: [(match: String, output: String)]) {
            fake.onSendCommand = { [fake] injected in
                guard let (start, end) = markers(in: injected) else { return }
                let body = answers.first { injected.contains($0.match) }?.output
                    ?? "error: the command \(injected) was not scripted"
                fake.appendOutput("\(start)\n\(body)\n\(end)")
            }
        }

        func drain(_ ticks: Int = 80) { controller.debugTick(ticks) }
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

    /// A live scope with a feed already adopted and the whole sweep scripted -
    /// the state most cases start from.
    private static func liveHarness() -> Harness {
        let harness = Harness()
        // Scripted *before* `goLive()`: a host with exactly one tab is
        // auto-adopted as the feed the moment its session registers, and that
        // fires a real sweep - so an unscripted fake would leave that first
        // batch outstanding for the bridge's full 20s ceiling.
        harness.answer([("get pods", podsWide), ("top pods", topPods),
                        ("get events", eventsTable), ("describe pod", describeOutput)])
        harness.goLive()
        harness.drain()
        return harness
    }

    // MARK: Scope

    /// The scout report is blunt that a standalone page cannot escape host
    /// scoping - so with nothing live it must say so plainly and point at
    /// Hosts, never show an empty table that reads as an empty cluster.
    private static func test_emptyStateWhenNoSessionIsLive() -> String? {
        let harness = Harness()
        guard harness.controller.debugEmptyStateVisible else { return "the empty state was not shown" }
        guard !harness.controller.debugScopeStripVisible else { return "a scope strip was shown with no live session" }
        guard !harness.controller.debugFeedCardVisible else { return "the feed card was shown with no scope" }
        guard !harness.controller.debugWorkAreaVisible else { return "the work area was shown with no feed" }
        guard harness.controller.debugSubtitle?.contains("No live host session") == true else {
            return "the drill subtitle did not say there is no session: \(harness.controller.debugSubtitle ?? "nil")"
        }
        // The empty state's one action must actually reach Hosts.
        guard let button = findButton(titled: "Open Hosts", in: harness.controller.view) else {
            return "the empty state had no Open Hosts button"
        }
        button.performClick(nil)
        guard harness.openHostsCalls == 1 else { return "Open Hosts fired \(harness.openHostsCalls) times" }
        return nil
    }

    private static func test_scopeStripAppearsWhenASessionGoesLive() -> String? {
        let harness = Harness()
        harness.goLive()
        guard harness.controller.debugScopeStripVisible else { return "no scope strip after a session went live" }
        guard !harness.controller.debugEmptyStateVisible else { return "the empty state stayed up" }
        guard harness.controller.debugScopeHostID == harness.hostID else { return "the live session was not auto-scoped" }
        // Exactly one tab is offered, so it is adopted without asking - there
        // is no ambiguity to resolve.
        guard harness.controller.debugFeedTabID == harness.feedTabID else {
            return "a lone tab was not adopted as the feed"
        }
        guard harness.controller.debugWorkAreaVisible else { return "the work area stayed hidden with a feed adopted" }
        return nil
    }

    private static func test_scopeIsDroppedWhenItsSessionEnds() -> String? {
        let harness = liveHarness()
        guard harness.controller.debugScopeHostID != nil else { return "no scope to begin with" }
        harness.sessions.unregister(hostID: harness.hostID)
        guard harness.controller.debugScopeHostID == nil else {
            return "a scope survived its own session ending - it would offer a feed that can never work"
        }
        guard harness.controller.debugFeedTabID == nil else { return "the feed survived the session ending" }
        guard harness.controller.debugEmptyStateVisible else { return "the empty state did not come back" }
        return nil
    }

    /// The captain's working tab must never be commandeered. With several
    /// tabs there is no unambiguous choice, so the page waits for a pick.
    private static func test_feedTabIsNeverAdoptedSilentlyWhenSeveralExist() -> String? {
        let harness = Harness()
        harness.extraTabs = [KubeFeedTab(id: UUID(), name: "EKS Bastion", terminal: FakeBridgeTerminal())]
        harness.goLive()
        guard harness.controller.debugFeedTabID == nil else {
            return "a feed tab was adopted silently while the host had several tabs open"
        }
        guard harness.controller.debugFeedCardVisible else { return "the feed card was not offered" }
        guard !harness.controller.debugWorkAreaVisible else { return "the work area opened with no feed chosen" }
        guard harness.fake.sentCommands.isEmpty else { return "a command was typed before a feed was chosen" }
        // The status has to explain the one manual beat, not just sit blank.
        let status = harness.controller.debugFeedStatusText.lowercased()
        guard status.contains("kubectl"), status.contains("log") else {
            return "the feed card did not explain the manual login: \(harness.controller.debugFeedStatusText)"
        }
        return nil
    }

    // MARK: Cluster browser

    private static func test_clusterSweepRendersRealParsedPods() -> String? {
        let harness = liveHarness()
        harness.controller.debugRefreshCluster()
        harness.drain()
        let pods = harness.controller.debugPods
        guard pods.count == 3 else { return "expected 3 pods, got \(pods.count)" }
        guard pods[0].name == "search-api-7f9c6d5b4-x2x8p", pods[0].cpu == "120m", pods[0].memory == "512Mi" else {
            return "pod 0 did not carry its joined metrics: \(pods[0])"
        }
        guard pods[2].health == .bad else { return "an ImagePullBackOff pod was not flagged: \(pods[2].health)" }
        guard pods[1].restarts == 4 else { return "restarts not parsed: \(pods[1].restarts)" }
        // Every command that ran was one of the read-only sweep's own.
        guard harness.fake.sentCommands.contains(where: { $0.contains("kubectl get pods -n default -o wide") }) else {
            return "the pod sweep never ran: \(harness.fake.sentCommands)"
        }
        guard harness.controller.debugSubtitle?.contains("3 pods") == true else {
            return "the drill subtitle did not pick up the count: \(harness.controller.debugSubtitle ?? "nil")"
        }
        // What the captain actually sees: the rendered rows, not just the
        // parsed model. A signal that never reaches the table is invisible to
        // a model-level check.
        let rendered = harness.controller.debugClusterRows
        guard rendered.count == 3 else { return "the table was handed \(rendered.count) rows" }
        guard rendered[0].tint == nil else { return "a healthy pod's row carried a signal tint" }
        guard rendered[2].tint == .critical else {
            return "the ImagePullBackOff row rendered with tint \(String(describing: rendered[2].tint)), expected .critical"
        }
        guard rendered[2].key == "billing-cron-29471120-tzkkd" else { return "row key wrong: \(rendered[2].key)" }
        // The metrics columns appear only because `top` succeeded.
        guard harness.controller.debugClusterColumns.contains("CPU") else {
            return "no CPU column despite metrics: \(harness.controller.debugClusterColumns)"
        }
        return nil
    }

    /// A cluster with no metrics-server is a normal configuration, not a
    /// failure - it must cost the cpu/mem columns and nothing else.
    private static func test_clusterSweepSurvivesAFailingTopPods() -> String? {
        let harness = Harness()
        harness.answer([("get pods", podsWide), ("top pods", "error: Metrics API not available")])
        harness.goLive()
        harness.controller.debugRefreshCluster()
        harness.drain()
        let pods = harness.controller.debugPods
        guard pods.count == 3 else { return "a failing `top` blanked the pod list (\(pods.count) rows)" }
        guard pods.allSatisfy({ $0.cpu == nil }) else { return "metrics were invented from an error" }
        // Without metrics the table swaps the cpu/mem pair for NODE rather
        // than rendering two empty columns.
        guard !harness.controller.debugClusterColumns.contains("CPU"),
              harness.controller.debugClusterColumns.contains("NODE") else {
            return "columns did not fall back to NODE: \(harness.controller.debugClusterColumns)"
        }
        guard !(harness.controller.debugClusterStatusText.lowercased().contains("metrics api")) else {
            return "a normal missing metrics-server was reported as a page-level failure"
        }
        return nil
    }

    // MARK: `fm/grandline-k8s-feed-tab-stall-fix`

    /// The captain's own real repro, verified against the **rendered**
    /// state, not just the bridge's own `pendingReason`: checking on the feed
    /// tab by typing into it directly used to render as an indistinguishable
    /// "Refreshing…" spinner, with no indication that the captain's own
    /// typing was what was pausing it.
    private static func test_clusterRefreshShowsWhyItIsWaitingOnFeedTabActivity() -> String? {
        let harness = liveHarness()
        // `liveHarness()` already ran one successful sweep to get here -
        // measure new commands from this point, not the whole history.
        let before = harness.fake.sentCommands.count
        // The captain typed directly into the feed tab, as reported.
        harness.fake.lastUserActivity = Date()
        harness.controller.debugRefreshCluster()
        harness.drain(4)
        let status = harness.controller.debugClusterStatusText
        guard status != "Refreshing\u{2026}" else {
            return "the pending status still rendered as the generic \u{201C}Refreshing\u{2026}\u{201D} while blocked on feed-tab activity"
        }
        guard status.lowercased().contains("idle") else {
            return "the pending status did not explain that the feed tab's own activity is the cause: \(status)"
        }
        // The feed card's own status line says the same thing.
        guard harness.controller.debugFeedStatusText.lowercased().contains("idle") else {
            return "the feed card status did not surface the waiting reason: \(harness.controller.debugFeedStatusText)"
        }
        // The safety property is unweakened: nothing new was injected while
        // blocked, regardless of how confusing the wait looked.
        guard harness.fake.sentCommands.count == before else {
            return "a command reached the tab while it was supposed to be waiting for quiet"
        }
        // Once activity genuinely clears, the sweep proceeds and lands real
        // data - this fix only changes what's shown while it waits.
        harness.fake.lastUserActivity = nil
        harness.drain()
        guard harness.controller.debugPods.count == 3 else {
            return "the sweep never completed once activity cleared: \(harness.controller.debugPods.count) pods"
        }
        return nil
    }

    /// The feed tab card's own explanatory copy must warn up front that
    /// typing into it pauses automated commands - exactly the behaviour the
    /// captain hit and had to discover by confusion.
    private static func test_feedCardCopyWarnsAgainstTypingIntoIt() -> String? {
        let harness = liveHarness()
        guard findLabel(containing: "pauses automated commands", in: harness.controller.view) else {
            return "the feed tab card's copy does not warn that typing into it pauses automated commands"
        }
        return nil
    }

    /// The genuine safety property this task must never touch: a real
    /// keystroke arriving after a command was injected but before it
    /// completed means the captain's own input and the shell's output could
    /// have interleaved, so the result is discarded rather than trusted -
    /// unchanged by this task's pending-reason work, and driven here through
    /// the real page's own `describePod` rather than the bridge directly.
    private static func test_discardOnMidCommandActivityIsUnchanged() -> String? {
        let harness = liveHarness()
        harness.fake.onSendCommand = { [fake = harness.fake] injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nNode: ip-10-40-5-88\n\(end)")
            // The captain typed while this command was still running - the
            // shell's input and ours could have interleaved.
            fake.lastUserActivity = Date()
        }
        harness.controller.describePod("billing-cron-29471120-tzkkd")
        harness.drain()
        guard harness.controller.debugDescribeText.contains("received input while the command was running") else {
            return "mid-command activity did not discard the output: \(harness.controller.debugDescribeText)"
        }
        return nil
    }

    /// GL-14's rule on this page: "no pods" and "kubectl failed" must not
    /// render identically.
    private static func test_emptyNamespaceSaysSoRatherThanLookingBroken() -> String? {
        let harness = Harness()
        harness.answer([("get pods", "No resources found in default namespace."),
                        ("top pods", "No resources found in default namespace.")])
        harness.goLive()
        harness.controller.debugRefreshCluster()
        harness.drain()
        guard harness.controller.debugPods.isEmpty else { return "invented pods for an empty namespace" }
        guard harness.controller.debugClusterStatusText.contains("No pods in default") else {
            return "an empty namespace did not say so: \(harness.controller.debugClusterStatusText)"
        }
        return nil
    }

    /// Nothing is prefetched: a row click costs exactly one more command, for
    /// that pod only.
    private static func test_describeDrawerRunsOneCommandForTheClickedPod() -> String? {
        let harness = liveHarness()
        harness.controller.debugRefreshCluster()
        harness.drain()
        let before = harness.fake.sentCommands.count
        guard !harness.controller.debugDescribeVisible else { return "the drawer was open before any row was clicked" }
        harness.controller.describePod("billing-cron-29471120-tzkkd")
        harness.drain()
        guard harness.controller.debugDescribeVisible else { return "the drawer did not open" }
        let added = harness.fake.sentCommands.count - before
        guard added == 1 else { return "a row click cost \(added) commands, expected exactly 1" }
        guard harness.fake.sentCommands.last?.contains("kubectl describe pod billing-cron-29471120-tzkkd") == true else {
            return "described the wrong pod: \(harness.fake.sentCommands.last ?? "nil")"
        }
        guard harness.controller.debugDescribeText.contains("Controlled By") else {
            return "the drawer did not render the command's real output: \(harness.controller.debugDescribeText)"
        }
        return nil
    }

    /// The mockup's own rule: a table nobody is looking at costs no command.
    private static func test_eventsTabFetchesOnlyWhenOpened() -> String? {
        let harness = liveHarness()
        harness.controller.debugRefreshCluster()
        harness.drain()
        guard !harness.fake.sentCommands.contains(where: { $0.contains("get events") }) else {
            return "events were fetched while the Pods tab was showing"
        }
        harness.controller.debugSelectClusterTab("events")
        harness.controller.debugRefreshCluster()
        harness.drain()
        guard harness.fake.sentCommands.contains(where: { $0.contains("kubectl get events -n default") }) else {
            return "opening the Events tab did not fetch events"
        }
        guard harness.controller.debugEvents.count == 1,
              harness.controller.debugEvents[0].isWarning,
              harness.controller.debugEvents[0].message.contains("Failed to pull image") else {
            return "events did not parse: \(harness.controller.debugEvents)"
        }
        return nil
    }

    /// A namespace this app will not type is refused visibly, not silently
    /// corrected into a different query.
    private static func test_namespaceFieldRefusesAnUnsafeValue() -> String? {
        let harness = liveHarness()
        harness.controller.debugSetNamespace("prod; rm -rf /")
        harness.drain()
        guard harness.controller.debugNamespace == "default" else {
            return "an unsafe namespace was accepted: \(harness.controller.debugNamespace)"
        }
        guard harness.controller.debugClusterStatusText.contains("isn't a namespace name") else {
            return "the refusal was silent: \(harness.controller.debugClusterStatusText)"
        }
        guard !harness.fake.sentCommands.contains(where: { $0.contains("rm -rf") }) else {
            return "an unsafe namespace reached the terminal"
        }
        // A legitimate namespace still works.
        harness.controller.debugSetNamespace("raas-prod")
        harness.drain()
        guard harness.controller.debugNamespace == "raas-prod" else { return "a safe namespace was refused" }
        return nil
    }

    // MARK: Log tail

    private static func test_logTailRendersMergedColouredLines() -> String? {
        let harness = liveHarness()
        harness.controller.debugRefreshCluster()
        harness.drain()
        // Re-scripted before the first pod is ticked: ticking one starts a
        // poll straight away, so scripting afterwards would leave the first
        // cycle answered by the sweep's own fixtures.
        harness.answer([
            ("logs search-api-7f9c6d5b4-x2x8p",
             "2026-09-04T11:00:01.000000000Z serving on :8080\n2026-09-04T11:00:03.000000000Z ERROR upstream timed out"),
            ("logs contract-ingest-worker-0",
             "2026-09-04T11:00:02.000000000Z ingested 41 contracts"),
        ])
        harness.controller.debugTogglePod("search-api-7f9c6d5b4-x2x8p")
        harness.controller.debugTogglePod("contract-ingest-worker-0")
        harness.drain()
        // Ticking a pod starts tailing it straight away, so measure one
        // deliberate cycle from here rather than counting every command the
        // page has ever run.
        let beforeCycle = harness.fake.sentCommands.count
        harness.controller.debugPollTail()
        harness.drain()

        let lines = harness.controller.debugLogLines
        guard lines.count == 3 else { return "expected 3 merged lines, got \(lines.count): \(lines.map(\.text))" }
        // Merged across pods by timestamp, not concatenated per pod.
        guard lines.map(\.text) == ["serving on :8080", "ingested 41 contracts", "upstream timed out"]
                || lines.map(\.text) == ["serving on :8080", "ingested 41 contracts", "ERROR upstream timed out"] else {
            return "lines were not merged in timestamp order: \(lines.map(\.text))"
        }
        guard lines[1].pod == "contract-ingest-worker-0" else { return "the middle line came from the wrong pod" }
        guard lines[2].isError else { return "the ERROR line was not flagged" }
        // Each pod carries its own stable colour.
        let tint = harness.controller.debugPodTint
        guard tint("search-api-7f9c6d5b4-x2x8p") != tint("contract-ingest-worker-0") else {
            return "both pods were given the same colour"
        }
        // One bounded command per selected pod, with the honest window.
        let cycle = Array(harness.fake.sentCommands[beforeCycle...])
        guard cycle.count == 2 else { return "one cycle ran \(cycle.count) commands for 2 pods" }
        let logCommands = harness.fake.sentCommands.filter { $0.contains("kubectl logs") }
        guard logCommands.allSatisfy({ $0.contains("--since=\(KubeLogTailSession.sinceSeconds)s") && $0.contains("--timestamps") }) else {
            return "a log command was unbounded or untimestamped: \(logCommands)"
        }
        guard !logCommands.contains(where: { $0.contains("-f") }) else {
            return "a follow flag reached the tab - that would wedge the single-flight bridge forever"
        }
        // The UI states the limit rather than implying live streaming.
        guard harness.controller.debugTailStatusText.lowercased().contains("not live streaming") else {
            return "the tail did not state its own limits: \(harness.controller.debugTailStatusText)"
        }
        return nil
    }

    /// Each selected pod costs its own serialized command per cycle, so the
    /// cap is refused with a reason rather than silently ignored.
    private static func test_logTailCapsHowManyPodsMayBeSelected() -> String? {
        let harness = liveHarness()
        for index in 0...KubeLogTailSession.maxSelectedPods {
            harness.controller.debugTogglePod("pod-\(index)")
        }
        guard harness.controller.debugSelectedPods.count == KubeLogTailSession.maxSelectedPods else {
            return "selected \(harness.controller.debugSelectedPods.count), cap is \(KubeLogTailSession.maxSelectedPods)"
        }
        guard harness.controller.debugTailStatusText.contains("At most") else {
            return "the cap was enforced silently: \(harness.controller.debugTailStatusText)"
        }
        return nil
    }

    // MARK: Deep link + give-up

    /// Shape C: the host page's "Tail Logs" lands here pre-scoped, on the tail.
    private static func test_deepLinkOpensPreScopedOnTheTail() -> String? {
        let harness = Harness()
        harness.answer([("get pods", podsWide), ("top pods", topPods)])
        harness.goLive()
        harness.controller.openScoped(hostID: harness.hostID, showTail: true)
        harness.drain()
        guard harness.controller.debugScopeHostID == harness.hostID else { return "the deep link did not scope" }
        guard harness.controller.debugTailVisible else { return "the deep link did not land on the Log Tail" }
        guard !harness.controller.debugClusterVisible else { return "both tabs were showing" }
        return nil
    }

    /// The exact failure `fm/grandline-k8s-badge-fixes` had to fix once
    /// already: a tab where `kubectl` can never work must stop being asked,
    /// and the page must say so rather than looking merely stale.
    private static func test_feedGivesUpAndSaysSoInsteadOfSpammingTheTab() -> String? {
        let harness = Harness()
        // A plain entry-hop bastion: `kubectl` isn't on PATH at all. Scripted
        // before `goLive()` for the same reason `liveHarness` is.
        harness.fake.onSendCommand = { [fake = harness.fake] injected in
            guard let (_, end) = markers(in: injected) else { return }
            fake.appendOutput("-bash: kubectl: command not found\n\(end)")
        }
        harness.goLive()
        for _ in 0..<8 {
            harness.controller.debugRefreshCluster()
            harness.drain()
        }
        guard harness.controller.debugBridge?.hasStoppedRetrying == true else {
            return "kept retrying a tab where kubectl can never succeed"
        }
        let injectedWhenStopped = harness.fake.sentCommands.count
        for _ in 0..<5 {
            harness.controller.debugRefreshCluster()
            harness.drain()
        }
        guard harness.fake.sentCommands.count == injectedWhenStopped else {
            return "kept typing after giving up (\(injectedWhenStopped) -> \(harness.fake.sentCommands.count))"
        }
        guard harness.controller.debugFeedStatusText.contains("stopped retrying") else {
            return "the page did not say the feed had given up: \(harness.controller.debugFeedStatusText)"
        }
        guard harness.controller.debugSubtitle?.contains("feed unavailable") == true else {
            return "the drill subtitle did not report the give-up: \(harness.controller.debugSubtitle ?? "nil")"
        }
        return nil
    }

    /// Giving up is a pause, not a dead end: the page offers a real retry and
    /// the captain's own click gets a working feed back.
    private static func test_givingUpIsNeverADeadEnd() -> String? {
        let harness = Harness()
        var kubectlWorks = false
        harness.fake.onSendCommand = { [fake = harness.fake] injected in
            guard let (start, end) = markers(in: injected) else { return }
            if kubectlWorks {
                fake.appendOutput("\(start)\n\(podsWide)\n\(end)")
            } else {
                fake.appendOutput("-bash: kubectl: command not found\n\(end)")
            }
        }
        harness.goLive()
        for _ in 0..<8 {
            harness.controller.debugRefreshCluster()
            harness.drain()
        }
        guard harness.controller.debugBridge?.hasStoppedRetrying == true else { return "did not give up" }
        guard harness.controller.debugRetryVisible else {
            return "gave up without offering any way back in - that is a dead end"
        }
        guard let retry = findButton(titled: "Try again", in: harness.controller.view) else {
            return "the retry control is not a real button"
        }
        // The captain logs in on the feed tab, then clicks.
        kubectlWorks = true
        retry.performClick(nil)
        harness.drain()
        guard harness.controller.debugBridge?.hasStoppedRetrying == false else { return "the retry did not clear the give-up" }
        guard harness.controller.debugPods.count == 3 else {
            return "the retry did not produce a working feed (\(harness.controller.debugPods.count) pods)"
        }
        guard !harness.controller.debugRetryVisible else { return "the retry button stayed up beside a healthy feed" }
        return nil
    }

    /// The report's accepted cost, made a step the captain takes: duplicate a
    /// tab, log in once by hand, and it becomes the feed.
    private static func test_duplicateButtonAdoptsTheNewTabAsTheFeed() -> String? {
        let harness = Harness()
        harness.extraTabs = [KubeFeedTab(id: UUID(), name: "EKS Bastion", terminal: FakeBridgeTerminal())]
        harness.answer([("get pods", podsWide), ("top pods", topPods)])
        harness.goLive()
        guard harness.controller.debugFeedTabID == nil else { return "a feed was adopted before the click" }
        guard let button = findButton(titled: "Duplicate a tab for the feed", in: harness.controller.view) else {
            return "no duplicate button on the feed card"
        }
        button.performClick(nil)
        harness.drain()
        guard harness.duplicateCalls == 1 else { return "duplicate fired \(harness.duplicateCalls) times" }
        guard harness.controller.debugFeedTabID == harness.feedTabID else {
            return "the duplicated tab was not adopted as the feed"
        }
        guard harness.controller.debugWorkAreaVisible else { return "the work area stayed hidden after adopting a feed" }
        guard harness.controller.debugPods.count == 3 else { return "adopting a feed did not sweep the cluster" }
        return nil
    }

    /// The security property, asserted against everything the page ever typed
    /// across a full exercise rather than by reading `KubeCommand`.
    private static func test_noMutatingCommandIsEverInjected() -> String? {
        let harness = liveHarness()
        harness.controller.debugRefreshCluster()
        harness.drain()
        harness.controller.debugSelectClusterTab("events")
        harness.controller.debugRefreshCluster()
        harness.drain()
        harness.controller.describePod("search-api-7f9c6d5b4-x2x8p")
        harness.drain()
        harness.controller.debugTogglePod("search-api-7f9c6d5b4-x2x8p")
        harness.controller.debugPollTail()
        harness.drain()

        guard harness.fake.sentCommands.count >= 5 else {
            return "the exercise only produced \(harness.fake.sentCommands.count) commands - too few to be meaningful"
        }
        let banned = ["exec", "edit", "delete", "scale", "apply", "patch", "replace", "rollout",
                      "cordon", "drain", "annotate", "label", "create", "port-forward", "attach", "rm "]
        for injected in harness.fake.sentCommands {
            // Strip this bridge's own `echo <marker>;` wrapper before judging.
            for verb in banned where injected.contains(verb) {
                return "a command containing \(verb) reached the tab: \(injected)"
            }
            guard injected.contains("kubectl ") else { return "a non-kubectl command reached the tab: \(injected)" }
        }
        return nil
    }

    // MARK: View walking

    private static func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = findButton(titled: title, in: subview) { return found }
        }
        return nil
    }

    /// Walks the real view tree for a label whose text contains `substring` -
    /// used to prove a piece of card copy is actually present on screen
    /// rather than reaching into `HelmCard`'s own private label properties.
    private static func findLabel(containing substring: String, in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.stringValue.contains(substring) { return true }
        for subview in view.subviews {
            if findLabel(containing: substring, in: subview) { return true }
        }
        return false
    }
}
#endif
