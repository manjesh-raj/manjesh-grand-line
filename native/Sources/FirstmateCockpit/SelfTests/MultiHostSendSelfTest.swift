// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for F9 (v1) - multi-host command execution.
// Run via `FM_RUN_MULTI_HOST_SEND_TESTS=1 .build/debug/FirstmateCockpit`, same
// convention as every other suite here.
//
// What it pins, and why each one is a test rather than a comment:
//
//  - **Nothing is ever preselected**, under any filter, including "All hosts".
//    This is the review's own literal security line for F9 ("default to opt-in
//    host selection, never 'all hosts' preselected") and the mockup repeats it
//    as on-screen copy. It is also the single easiest thing to break by
//    accident - one convenience "select everything visible" line and a
//    destructive command reaches every saved bastion because a captain
//    pressed Return.
//  - **The risk gate fires once per host.** Counted, not described. The
//    executor takes the gate as an injected closure precisely so this suite
//    can count invocations against a selection of three, and so it can decline
//    one of them and assert that *that* host is the one not delivered to. A
//    single blanket confirmation covering a selection is the failure mode the
//    review rules out, and it looks identical from the outside to the correct
//    behaviour unless something counts.
//  - **A host is never delivered to without its own accepted confirmation.**
//    The strong form of the above: `sent` and the recorded deliveries have to
//    agree, host for host.
//  - **An unfilled `{{token}}` refuses the whole send**, for every selected
//    host, not just the first. F5's rule does not weaken because N hosts are
//    selected - the mistake would simply land N times.
//  - **Tag matching**, including the case-insensitivity a free-text `Host.tags`
//    field makes necessary, and the fact that changing the filter neither adds
//    nor drops what is ticked.
//  - **A source guard** that the multi-host path routes through
//    `CommandRiskConfirmation` and that there is still exactly one definition
//    of it - the same guard shape `UnifiedSearchSelfTest` uses for F5's
//    palette, for the same reason: a faster way to reach an action must never
//    become a way around its confirmation.
//
// Deliberately *not* covered: the picker's own AppKit rendering. This app
// shares one bundle identity across builds, so a suite must never launch a
// window that could disturb the captain's running instance - and the picker is
// a thin reader of `MultiHostSendSelection`, which is what is tested here.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum MultiHostSendSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // MARK: Fixtures

        // Deliberately mixed-case tags: `Host.tags` is free text with nothing
        // normalising it at entry, so "prod" and "PROD" genuinely coexist in a
        // real store.
        let prodA = Host(label: "Prod Bastion", address: "prod-a.invalid", tags: ["PROD"])
        let prodB = Host(label: "EKS Prod Bastion", address: "prod-b.invalid", tags: ["prod", "eks"])
        let staging = Host(label: "Staging Bastion", address: "stg.invalid", tags: ["STAGING"])
        let untagged = Host(label: "Scratch Box", address: "scratch.invalid", group: "Lab")
        let hosts = [prodA, prodB, staging, untagged]

        let readOnly = DevOpsCommand(
            id: "k8s-get-pods", name: "List pods", description: "",
            category: "kubernetes", commandTemplate: "kubectl get pods -A", risk: .readOnly)
        let destructive = DevOpsCommand(
            id: "k8s-rollout-restart", name: "Restart deployment", description: "",
            category: "kubernetes",
            commandTemplate: "kubectl rollout restart deploy/payments-worker", risk: .destructive)
        let needsParam = DevOpsCommand(
            id: "k8s-get-ns", name: "List pods in namespace", description: "",
            category: "kubernetes", commandTemplate: "kubectl get pods -n {{namespace}}",
            parameters: [CommandParameter(name: "namespace", label: "Namespace")],
            risk: .readOnly)

        // MARK: Never preselected

        for filter in [MultiHostSendFilter.allHosts, .tag("PROD"), .tag("STAGING")] {
            let selection = MultiHostSendSelection(hosts: hosts, filter: filter)
            check(selection.selected.isEmpty,
                  "a picker opened on \(filter) must start with nothing ticked")
            check(!selection.canSend,
                  "Send must be disabled at zero selection (\(filter))")
            check(selection.selectedHosts.isEmpty,
                  "no host may be in the send set before the captain ticks one (\(filter))")
        }

        // Switching to "All hosts" is the one a convenience shortcut would
        // most plausibly hang itself off. It must still tick nothing.
        var switching = MultiHostSendSelection(hosts: hosts, filter: .tag("PROD"))
        switching.setFilter(.allHosts)
        check(switching.selected.isEmpty,
              "switching to All hosts must not select anything - the review's own security line")
        check(switching.visibleHosts.count == hosts.count,
              "All hosts should show every saved host")

        // MARK: Tag filtering

        check(MultiHostSendSelection.hosts(hosts, matching: .tag("PROD")).map(\.id) == [prodA.id, prodB.id],
              "a PROD pill must match both PROD and prod - tags are free text, nothing normalises their case")
        check(MultiHostSendSelection.hosts(hosts, matching: .tag("STAGING")).map(\.id) == [staging.id],
              "STAGING should match exactly its one host")
        check(MultiHostSendSelection.hosts(hosts, matching: .tag("eks")).map(\.id) == [prodB.id],
              "a second tag on the same host is matchable on its own")
        check(MultiHostSendSelection.hosts(hosts, matching: .allHosts).count == 4,
              "All hosts must include the untagged host too")

        let options = MultiHostSendSelection(hosts: hosts).filterOptions
        check(options.last?.filter == .allHosts, "the All hosts pill comes last, per the mockup")
        check(options.last?.title == "All hosts (4)", "the All hosts pill carries the real count")
        check(options.contains { $0.title == "tag: PROD (2)" },
              "a tag pill carries its own real match count, got \(options.map(\.title))")
        check(options.count == 5, "one pill per distinct tag (PROD, prod, eks, STAGING) plus All hosts")

        // A selection made under one filter survives looking at another - the
        // button's count and what actually gets sent must never disagree.
        var kept = MultiHostSendSelection(hosts: hosts, filter: .tag("PROD"))
        kept.toggle(prodA.id)
        kept.setFilter(.tag("STAGING"))
        check(kept.selectedCount == 1 && kept.isSelected(prodA.id),
              "changing the filter must not silently drop a ticked host")
        check(kept.sendButtonTitle == "Send to 1 host", "the button count follows the selection, not the filter")
        // ...and the picker can say so: the ticked host is not on screen under
        // STAGING, which is what the "N aren't shown by this filter" line
        // exists to explain.
        check(kept.visibleSelectedCount == 0,
              "a ticked host hidden by the active filter must be reported as not visible")
        kept.toggle(staging.id)
        check(kept.sendButtonTitle == "Send to 2 hosts", "the button count is live")
        check(kept.visibleSelectedCount == 1,
              "exactly the on-screen ticked host counts as visibly selected")
        check(kept.selectedHosts.map(\.id) == [prodA.id, staging.id],
              "selected hosts come back in store order, not Set order")
        kept.toggle(prodA.id)
        check(kept.selectedCount == 1, "toggling an already-ticked host unticks it")

        // MARK: Readiness

        check(MultiHostSend.readiness(for: readOnly, values: [:]) == .ready("kubectl get pods -A"),
              "a command with no parameters is ready as-is")
        check(MultiHostSend.readiness(for: needsParam, values: [:]) == .needsParameters(["namespace"]),
              "an unfilled token must be reported by name")
        check(MultiHostSend.readiness(for: needsParam, values: ["namespace": "prod"])
                == .ready("kubectl get pods -n prod"),
              "a filled token resolves once, to one string for every host")

        // MARK: The gate fires once per host

        // A recording gate: counts its invocations, remembers which hosts it
        // was shown for, and accepts every one.
        final class GateRecorder {
            var shownFor: [String] = []
            var contexts: [String] = []
            var delivered: [(host: String, text: String)] = []
            var decline: Set<String> = []
            func confirm(_ command: DevOpsCommand, _ text: String, _ host: Host,
                         _ context: String, _ proceed: () -> Void) {
                shownFor.append(host.label)
                contexts.append(context)
                if !decline.contains(host.label) { proceed() }
            }
            func deliver(_ host: Host, _ text: String) {
                delivered.append((host.label, text))
            }
        }

        let three = [prodA, prodB, staging]

        let allAccepted = GateRecorder()
        let acceptOutcome = MultiHostSendExecutor(
            confirm: allAccepted.confirm, deliver: allAccepted.deliver
        ).send(command: destructive, values: [:], to: three)

        check(acceptOutcome?.gateInvocations == 3,
              "the risk gate must be invoked once per selected host, got \(acceptOutcome?.gateInvocations ?? -1) for 3 hosts")
        check(allAccepted.shownFor == three.map(\.label),
              "the gate must be shown for each host by name, in selection order - got \(allAccepted.shownFor)")
        // Each alert says which host it is for, and where in the run it sits -
        // three identical alerts would read as one alert misfiring.
        check(allAccepted.contexts == ["Sending to Prod Bastion (1 of 3).",
                                       "Sending to EKS Prod Bastion (2 of 3).",
                                       "Sending to Staging Bastion (3 of 3)."],
              "each per-host confirmation must name its own host and position - got \(allAccepted.contexts)")
        check(Set(allAccepted.contexts).count == 3,
              "no two of the three confirmations may be indistinguishable")
        check(acceptOutcome?.sent.count == 3, "all three accepted hosts should be in `sent`")
        check(allAccepted.delivered.map(\.host) == three.map(\.label),
              "every accepted host receives the command")
        check(allAccepted.delivered.allSatisfy { $0.text == destructive.commandTemplate },
              "every host receives the identical, already-substituted text")

        // Declining one host's confirmation must skip exactly that host - the
        // gate being per host is only meaningful if answering it "no" is too.
        let oneDeclined = GateRecorder()
        oneDeclined.decline = [prodB.label]
        let declineOutcome = MultiHostSendExecutor(
            confirm: oneDeclined.confirm, deliver: oneDeclined.deliver
        ).send(command: destructive, values: [:], to: three)

        check(oneDeclined.shownFor.count == 3,
              "declining one host must not abort the remaining hosts' own confirmations")
        check(declineOutcome?.declined == [prodB.id], "the declined host is reported as declined")
        check(declineOutcome?.sent == [prodA.id, staging.id], "only the accepted hosts are sent to")
        check(!oneDeclined.delivered.contains { $0.host == prodB.label },
              "a host whose confirmation was declined must never receive the command")
        check(oneDeclined.delivered.count == 2, "exactly the two accepted hosts were delivered to")

        // Declining every host sends nothing at all, and says so.
        let allDeclined = GateRecorder()
        allDeclined.decline = Set(three.map(\.label))
        let noneOutcome = MultiHostSendExecutor(
            confirm: allDeclined.confirm, deliver: allDeclined.deliver
        ).send(command: destructive, values: [:], to: three)
        check(allDeclined.delivered.isEmpty, "declining every confirmation must deliver nothing")
        check(noneOutcome.map(MultiHostSend.resultMessage) == "Nothing sent - every host's confirmation was cancelled",
              "a fully-cancelled send must say so rather than reporting a silent success")

        // A read-only command still goes through the gate - `.readOnly`
        // proceeds without an alert, which is the gate's own decision, not a
        // branch that skips it.
        let readOnlyGate = GateRecorder()
        let readOnlyOutcome = MultiHostSendExecutor(
            confirm: readOnlyGate.confirm, deliver: readOnlyGate.deliver
        ).send(command: readOnly, values: [:], to: three)
        check(readOnlyOutcome?.gateInvocations == 3,
              "a read-only command still routes through the gate once per host")
        check(readOnlyGate.delivered.count == 3, "a read-only command reaches every selected host")

        // MARK: The unfilled-parameter refusal, across a multi-host selection

        let refused = GateRecorder()
        let refusedOutcome = MultiHostSendExecutor(
            confirm: refused.confirm, deliver: refused.deliver
        ).send(command: needsParam, values: [:], to: three)
        check(refusedOutcome == nil, "an unfilled parameter must refuse the whole send")
        check(refused.shownFor.isEmpty, "a refused send must not even reach the gate")
        check(refused.delivered.isEmpty,
              "a half-substituted template must reach no host - not the first one either")

        // ...and the same selection sends fine once the parameter is filled,
        // so the refusal is about the parameter and not about multi-host.
        let filled = GateRecorder()
        let filledOutcome = MultiHostSendExecutor(
            confirm: filled.confirm, deliver: filled.deliver
        ).send(command: needsParam, values: ["namespace": "payments"], to: three)
        check(filledOutcome?.sent.count == 3, "the same selection sends once the parameter is filled")
        check(filled.delivered.allSatisfy { $0.text == "kubectl get pods -n payments" },
              "every host gets the one substitution, not a per-host re-derivation")

        // A single-host selection gets no "(1 of 1)" noise.
        let single = GateRecorder()
        _ = MultiHostSendExecutor(confirm: single.confirm, deliver: single.deliver)
            .send(command: destructive, values: [:], to: [prodA])
        check(single.contexts == ["Sending to Prod Bastion."],
              "a one-host send should not read as \"1 of 1\" - got \(single.contexts)")

        check(MultiHostSend.unfilledParameterMessage(["namespace"]).contains("namespace"),
              "the refusal names the field to fill")
        check(MultiHostSend.unfilledParameterMessage(["namespace"]).contains("any host"),
              "the refusal makes clear nothing was sent anywhere")

        // MARK: Result messages

        check(MultiHostSend.resultMessage(MultiHostSendOutcome(sent: [prodA.id], declined: [], gateInvocations: 1))
                == "Sent to 1 host", "singular reads naturally")
        check(MultiHostSend.resultMessage(MultiHostSendOutcome(sent: [prodA.id, prodB.id], declined: [staging.id], gateInvocations: 3))
                == "Sent to 2 hosts \u{00B7} 1 cancelled",
              "a partial send reports the cancelled count rather than hiding it")

        // MARK: Source guard - one gate, and this path uses it

        if let files = SelfTestSources.appSourceFiles() {
            let texts = files.compactMap { url -> (String, String)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
            let definitions = texts.filter { $0.1.contains("enum CommandRiskConfirmation") }.map(\.0)
            check(definitions.count == 1,
                  "there must be exactly one CommandRiskConfirmation definition, found \(definitions)")
            let mainText = texts.first { $0.0 == "main.swift" }?.1 ?? ""
            check(mainText.contains("presentMultiHostSend"),
                  "the multi-host send should be wired from main.swift, where the host store lives")
            // The gate call has to be inside the multi-host wiring, not merely
            // somewhere else in the same (large) file.
            if let start = mainText.range(of: "private func presentMultiHostSend") {
                let body = mainText[start.lowerBound...].prefix(4000)
                check(body.contains("CommandRiskConfirmation.confirm"),
                      "the multi-host send must run the app's one risk gate, not a lookalike")
            } else {
                check(false, "could not locate presentMultiHostSend to check its gate")
            }
            // A "confirm everything up front" shortcut would show up as the
            // executor being handed a closure that ignores its host argument;
            // the strong version of that is already covered by the counting
            // checks above. What the source guard adds is that nothing has
            // introduced a *second* gate to call instead.
            let lookalikes = texts.filter {
                $0.0 != "CommandLibraryViews.swift" && $0.1.contains("alertStyle = .critical")
                    && $0.1.contains("Destructive command")
            }.map(\.0)
            check(lookalikes.isEmpty,
                  "a second destructive-command alert must not exist, found \(lookalikes)")
        } else {
            print("MultiHostSendSelfTest: SKIP source guard (sources not next to this binary)")
        }

        if failures.isEmpty {
            print("MultiHostSendSelfTest: all checks passed")
            return true
        }
        print("MultiHostSendSelfTest: FAILED")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
