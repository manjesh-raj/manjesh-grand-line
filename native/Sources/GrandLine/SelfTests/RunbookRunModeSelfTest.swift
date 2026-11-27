// Grand Line - native macOS app.
//
// D-01 of full review 4: run mode for runbooks, with evidence.
// Run with `FM_RUN_RUNBOOK_RUN_MODE_TESTS=1 .build/debug/GrandLine`.
//
// Headless. The Console's tab is a fake `SRELeadBridgeTerminal` that answers
// the way a shell would: it echoes what is typed and, when the end marker's
// line is typed, prints the command's output and the marker with a status.
//
// What it pins:
//
//  - **Capture**: the output between the markers, not the echo of the typed
//    lines; the exit code; redaction; a run that never answers times out
//    rather than hanging.
//  - **The evidence**: retries under one step, skips with their reason, the
//    summary line and the Markdown a postmortem gets.
//  - **The page, end to end**: Run starts a run with a step panel, a captured
//    success offers "Mark done, next step", a failure keeps its output and
//    offers Retry, a skip moves on, and the finished run attaches to a
//    postmortem through the real store.

#if FM_SELFTESTS

import AppKit

enum RunbookRunModeSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("capture reads output and the exit code", test_capture),
            ("capture redacts and bounds", test_captureRedacts),
            ("a capture that never answers times out", test_captureTimeout),
            ("the evidence and its Markdown", test_evidence),
            ("the page, end to end", test_page),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[runbook-run] \(name): \(failure)", &ok) } else { print("[runbook-run] PASS \(name)") }
        }
        print(ok ? "[runbook-run] ALL PASS" : "[runbook-run] FAILED")
        return ok
    }

    static let token = "ghp_1234567890abcdefghijklmnopqrstuvwxyz"

    /// A shell-ish terminal: typed lines are echoed after a prompt, `echo X`
    /// prints X, and the end marker line prints the marker and `status`.
    final class FakeShell: SRELeadBridgeTerminal {
        var buffer: [String] = ["ops@bastion ~ $ ls", "old-output"]
        var output: [String]
        var status: Int32
        var answers = true
        var sent: [String] = []
        init(output: [String], status: Int32) { self.output = output; self.status = status }

        func sendCommand(_ text: String) {
            sent.append(text)
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                buffer.append("ops@bastion ~ $ \(line)")
                if line.hasPrefix("echo __GL_RUNBOOK_"), line.hasSuffix("_START__") {
                    buffer.append(String(line.dropFirst(5)))
                } else if line.hasPrefix("echo \"__GL_RUNBOOK_") {
                    guard answers else { continue }
                    let marker = line.dropFirst(6).prefix { $0 != ":" }
                    buffer.append("\(marker):\(status)")
                } else if !line.hasPrefix("echo") {
                    buffer.append(contentsOf: output)
                }
            }
        }
        func currentBufferLines() -> [String] { buffer }
        func currentViewportLines() -> [String] { Array(buffer.suffix(24)) }
        var lastUserActivity: Date? { nil }
        func setMachineReadableGeometry(_ enabled: Bool) {}
    }

    static func capture(_ shell: FakeShell, command: String, timeout: TimeInterval = 5) -> RunbookStepCapture.Result? {
        let capture = RunbookStepCapture(terminal: shell, command: command, id: "test1234")
        capture.timeout = timeout
        var result: RunbookStepCapture.Result?
        capture.start { result = $0 }
        let deadline = Date().addingTimeInterval(timeout + 3)
        while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result
    }

    // MARK: Cases

    static func test_capture() -> String? {
        let shell = FakeShell(output: ["edge.pem 100% 3.2KB", "notAfter=Feb 23 10:44:02 2027 GMT"], status: 0)
        guard let result = capture(shell, command: "scp edge.pem ops@edge-01:/etc/ssl/edge.pem") else { return "no result" }
        guard result.output == ["edge.pem 100% 3.2KB", "notAfter=Feb 23 10:44:02 2027 GMT"] else {
            return "output \(result.output) from buffer \(shell.buffer)"
        }
        guard result.exitCode == 0, !result.timedOut else { return "exit \(String(describing: result.exitCode))" }
        // A multi-line command: both typed lines are echoed, neither is output.
        let multi = FakeShell(output: [], status: 0)
        multi.output = ["reloaded"]
        guard let two = capture(multi, command: "scp edge.pem ops@edge-01:/etc/ssl/\nssh ops@edge-01 'sudo systemctl reload haproxy'"),
              !two.output.contains(where: { $0.contains("ssh ops@edge-01") || $0.contains("scp edge.pem") }) else {
            return "a multi-line command's echo was kept as output"
        }
        let failing = FakeShell(output: ["unable to load SSL certificate"], status: 1)
        guard let failed = capture(failing, command: "sudo systemctl reload haproxy"), failed.exitCode == 1 else {
            return "a failing command did not report exit 1"
        }
        return nil
    }

    static func test_captureRedacts() -> String? {
        // The token is last, so the 400-line bound keeps it and redaction has
        // something to do.
        let shell = FakeShell(output: (0..<600).map { "line \($0)" } + ["Authorization: Bearer \(token)"], status: 0)
        guard let result = capture(shell, command: "curl -v https://api.example.test") else { return "no result" }
        guard !result.output.joined().contains(token), result.redactions > 0 else { return "the token was kept" }
        return result.output.count <= RunbookStepCapture.outputLineLimit ? nil : "kept \(result.output.count) lines"
    }

    static func test_captureTimeout() -> String? {
        let shell = FakeShell(output: [], status: 0)
        shell.answers = false
        guard let result = capture(shell, command: "sleep 9999", timeout: 0.6) else { return "it never finished" }
        return result.timedOut && result.exitCode == nil ? nil : "result \(result)"
    }

    static func test_evidence() -> String? {
        let steps = [RunbookSteps.Step(title: "Check the expiry", command: "openssl x509 -enddate"),
                     RunbookSteps.Step(title: "Deploy to edge-proxy-02", command: "systemctl reload haproxy"),
                     RunbookSteps.Step(title: "Verify from outside", command: nil)]
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)
        var run = RunbookRunEvidence(runbookID: "rb", title: "Rotate a TLS certificate", steps: steps, now: t0)
        run.record(RunbookStepAttempt(command: "openssl x509 -enddate", output: ["notAfter=Feb 23"], exitCode: 0,
                                      startedAt: t0, endedAt: t0.addingTimeInterval(41), redactions: 0), at: 0)
        run.finish(0, .done(manual: false), now: t0.addingTimeInterval(41))
        run.record(RunbookStepAttempt(command: "systemctl reload haproxy", output: ["Job failed"], exitCode: 1,
                                      startedAt: t0, endedAt: t0, redactions: 0), at: 1)
        guard run.steps[1].outcome == .failed else { return "a failed attempt should fail the step" }
        run.record(RunbookStepAttempt(command: "systemctl reload haproxy", output: ["reloaded"], exitCode: 0,
                                      startedAt: t0, endedAt: t0, redactions: 0), at: 1)
        run.finish(1, .done(manual: false), now: t0.addingTimeInterval(200))
        run.finish(2, .skipped(reason: "the outside probe is down"), now: t0.addingTimeInterval(300))
        run.endedAt = t0.addingTimeInterval(1080)
        guard run.summary == "3 of 3 steps \u{00B7} step 2 retried once \u{00B7} 3 lines of output kept" else {
            return "summary \(run.summary)"
        }
        guard run.headline(now: Date()) == "Rotate a TLS certificate: done in 18 min" else { return "headline \(run.headline(now: Date()))" }
        let md = run.markdown(timeZone: TimeZone(identifier: "UTC")!)
        for needle in ["### Runbook run: Rotate a TLS certificate", "1. **Check the expiry** - done, exit 0, 41s",
                       "2. **Deploy to edge-proxy-02** - done after a retry, exit 0", "Attempt 1", "exit 1",
                       "3. **Verify from outside** - skipped: the outside probe is down", "   $ openssl x509 -enddate"]
        where !md.contains(needle) {
            return "the Markdown is missing \(needle):\n\(md)"
        }
        return nil
    }

    static func test_page() -> String? {
        autoreleasepool { () -> String? in
            let store = DocsRunbookStore()
            let content = "# Rotate a TLS certificate\n\n1. Check the current expiry\n```\nopenssl x509 -enddate -noout -in edge.pem\n```\n2. Reload HAProxy\n```\nsudo systemctl reload haproxy\n```\n3. Verify from outside\n"
            let runbook = store.createRunbook(title: "Rotate a TLS certificate", content: content)
            let page = RunbooksController(runbookStore: store)
            _ = page.view
            page.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            page.debugReloadRunbooks()
            page.debugSelect(runbook.id)
            let shell = FakeShell(output: ["notAfter=Feb 23 10:44:02 2027 GMT"], status: 0)
            page.stepTerminal = { (shell, "DEV Bastion") }
            page.debugStartRun()
            let panel = page.debugDetail.stepPanel
            guard panel.debugButtonTitles == ["Run in Console", "I ran it myself", "Skip, with a reason"] else {
                return "step 1 offers \(panel.debugButtonTitles)"
            }
            // Past the risk gate: the gate itself is the Command Library's,
            // with its own suite.
            page.startCapture(command: "openssl x509 -enddate -noout -in edge.pem", index: 0, terminal: shell)
            let deadline = Date().addingTimeInterval(4)
            while page.evidence?.steps[0].attempts.isEmpty != false, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard panel.debugButtonTitles.first == "Mark done, next step",
                  panel.debugOutput == "notAfter=Feb 23 10:44:02 2027 GMT" else {
                return "after a capture: \(panel.debugButtonTitles) / \(panel.debugOutput)"
            }
            panel.debugPress("Mark done, next step")
            guard page.session?.index == 1 else { return "the run did not move to step 2" }
            shell.status = 1
            shell.output = ["Job for haproxy.service failed."]
            page.startCapture(command: "sudo systemctl reload haproxy", index: 1, terminal: shell)
            let deadline2 = Date().addingTimeInterval(4)
            while page.evidence?.steps[1].attempts.isEmpty != false, Date() < deadline2 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard panel.debugButtonTitles == ["Retry", "Open Console", "Stop the run"],
                  panel.debugOutputHead == "FAILED \u{00B7} EXIT 1" else {
                return "a failure offers \(panel.debugButtonTitles) under \(panel.debugOutputHead)"
            }
            page.debugTick(now: Date())  // the captain did it by hand after all
            page.skipCurrentStep(reason: "probe host is down")
            guard page.session == nil, let evidence = page.evidence, evidence.endedAt != nil else {
                return "the run did not finish"
            }
            guard panel.debugButtonTitles == ["Attach to a postmortem", "Copy as Markdown"] else {
                return "a finished run offers \(panel.debugButtonTitles)"
            }
            guard let pmID = page.attachRun(toPostmortem: nil),
                  let pm = store.listPostmortems().first(where: { $0.id == pmID }) else { return "no postmortem was made" }
            guard pm.content.contains("## Evidence"), pm.content.contains("### Runbook run: Rotate a TLS certificate"),
                  pm.content.contains("skipped: probe host is down") else { return "the postmortem reads:\n\(pm.content)" }
            // Attaching again appends under the same heading.
            guard page.attachRun(toPostmortem: pmID) == pmID,
                  let again = store.listPostmortems().first(where: { $0.id == pmID }),
                  again.content.components(separatedBy: "## Evidence").count == 2,
                  again.content.components(separatedBy: "### Runbook run").count == 3 else {
                return "a second attach did not append under the one Evidence heading"
            }
            return nil
        }
    }
}

#endif
