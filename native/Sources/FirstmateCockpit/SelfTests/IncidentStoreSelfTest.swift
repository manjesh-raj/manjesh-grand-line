// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for F8 (incident mode) - run via
// `FM_RUN_INCIDENT_TESTS=1 .build/debug/FirstmateCockpit`, same convention as
// every other suite here.
//
// What it pins, and why each one is worth a test rather than a reading of the
// code:
//
//  - **Create / append / end, re-read from disk.** The store memoises, so a
//    check that only reads `all()` back would pass even if nothing were ever
//    written. Every persistence case here constructs a *fresh* store over the
//    same directory, which is also the closest this suite can get to the real
//    "the app was relaunched mid-incident" case.
//  - **Written as it happens, not batched.** The whole durability claim of
//    this feature is that an append reaches disk before it returns, so a
//    crash costs at most one artifact. That is checked by reading the file
//    after each append rather than at the end.
//  - **One active incident per host.** The rule is enforced in the record
//    itself, not only in the UI, so that a future UI path which forgets to
//    check cannot create two overlapping incidents.
//  - **The redaction boundary.** The one piece of free text this feature
//    writes is an SRE Lead transcript snapshot. A planted credential is
//    grepped for in the *bytes* of every file under the incident directory -
//    the only form of this check that survives someone reordering the write
//    path, exactly as `LogAnalyzerSelfTest` does for investigations.
//  - **The F6 wiring**, both halves: that the event kinds/phrasing are right
//    and round-trip through a real `FleetLogStore`, and - by a source guard -
//    that the one code path which starts and ends an incident genuinely calls
//    them. A round-trip test alone would still pass if the call site were
//    deleted.
//  - **The aggregated transcript**, because it is what the existing
//    postmortem generator is fed instead of one tab's chat, and a silently
//    empty aggregate would produce a plausible-looking but content-free
//    postmortem.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum IncidentStoreSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let hostA = "11111111-1111-1111-1111-111111111111"
        let hostB = "22222222-2222-2222-2222-222222222222"

        // MARK: Create, and it really is on disk

        let store = IncidentStore(root: scratch)
        check(store.all().isEmpty, "a fresh store should hold no incidents")
        check(store.activeIncident(hostID: hostA) == nil, "a fresh store should have no active incident")

        guard case .success(let created) = store.start(title: "payments-worker OOMKilled",
                                                       hostID: hostA, hostLabel: "EKS Preprod Bastion") else {
            print("[incident] FAIL: could not start an incident at all")
            return false
        }
        check(created.id == "INC-001", "the first incident should be INC-001, got \(created.id)")
        check(created.isActive, "a new incident should be active")

        // A *fresh* store over the same directory - the record, not the cache.
        let reread = IncidentStore(root: scratch)
        check(reread.all().count == 1, "expected 1 incident read back from disk, got \(reread.all().count)")
        let loaded = reread.activeIncident(hostID: hostA)
        check(loaded?.id == created.id, "the active incident should be found by host id after a reload")
        check(loaded?.title == "payments-worker OOMKilled", "the title should survive a reload")
        check(loaded?.hostLabel == "EKS Preprod Bastion", "the host label should survive a reload")

        // MARK: One active incident per host, enforced by the record

        let second = store.start(title: "a second one", hostID: hostA, hostLabel: "EKS Preprod Bastion")
        if case .failure(.alreadyActive(let existing)) = second {
            check(existing == created.id, "the refusal should name the incident already running")
        } else {
            failures.append("starting a second incident on the same host must be refused")
        }
        check(store.incidents(hostID: hostA).count == 1,
              "a refused start must not leave a second record behind")

        // A *different* host is unaffected - the rule is per host, not global.
        guard case .success(let otherHost) = store.start(title: "unrelated",
                                                         hostID: hostB, hostLabel: "Prod Bastion") else {
            print("[incident] FAIL: a second host should be allowed its own incident")
            return false
        }
        check(otherHost.id == "INC-002", "ids should keep counting across hosts, got \(otherHost.id)")
        check(store.activeIncident(hostID: hostA)?.id == created.id,
              "host A's incident must be untouched by host B's")

        // MARK: Appends hit the disk immediately, one at a time

        let capture = IncidentSources.logCapture(tabName: "EKS Preprod Bastion",
                                                 lineCount: 42,
                                                 scopeDescription: "the last completed command's output")
        check(store.append(capture, to: created.id), "appending a capture entry should succeed")
        check(IncidentStore(root: scratch).load(id: created.id)?.entries.count == 1,
              "the capture entry should be on disk before append returned")

        let runbook = IncidentSources.runbookRun(name: "Restart OOMKilled pod", ran: 2, total: 2,
                                                 ok: true, refused: false)
        check(store.append(runbook, to: created.id), "appending a runbook entry should succeed")
        let afterTwo = IncidentStore(root: scratch).load(id: created.id)
        check(afterTwo?.entries.count == 2, "both entries should be on disk, got \(afterTwo?.entries.count ?? -1)")
        check(afterTwo?.entries.first?.kind == .logCapture, "entries should keep the order they happened in")
        check(afterTwo?.entries.last?.title.contains("Restart OOMKilled pod") == true,
              "the runbook entry should name the runbook")
        check(afterTwo?.entries.last?.detail == "2 steps · all green",
              "a fully green run should say so, got \(afterTwo?.entries.last?.detail ?? "nil")")

        // A refused runbook is a different sentence, and never claims steps ran.
        let refused = IncidentSources.runbookRun(name: "Dangerous one", ran: 0, total: 3, ok: false, refused: true)
        check(refused.detail?.contains("Refused") == true, "a refused runbook should say it was refused")

        // MARK: The redaction boundary - a planted credential never reaches disk

        let secret = "AKIAIOSFODNN7EXAMPLE"
        let transcript = """
        Captain: what is failing?

        SRE Lead: the pod cannot reach S3. Its env shows AWS_ACCESS_KEY_ID=\(secret) which is
        the wrong account.
        """
        let turn = IncidentSources.sreLeadTurn(question: "what is failing?",
                                               tabName: "EKS Preprod Bastion", turn: 1)
        check(store.append(turn, to: created.id, artifactText: transcript),
              "appending an SRE Lead turn with a transcript should succeed")

        let withArtifact = IncidentStore(root: scratch).load(id: created.id)
        let storedTurn = withArtifact?.entries.last
        check(storedTurn?.artifact != nil, "a turn with a transcript should record its artifact path")
        check(storedTurn?.title == "SRE Lead investigation started",
              "the first turn should read as the investigation starting")

        // Grep the real bytes of every file under the incident's own
        // directory, rather than reasoning about the write path.
        var scannedFiles = 0
        var leaked: [String] = []
        if let walker = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scannedFiles += 1
                if text.contains(secret) { leaked.append(url.lastPathComponent) }
            }
        }
        check(scannedFiles >= 2, "expected to scan at least the record and its artifact, saw \(scannedFiles)")
        check(leaked.isEmpty, "a credential reached disk in: \(leaked.joined(separator: ", "))")
        let artifactText = withArtifact.flatMap { incident in
            storedTurn.flatMap { IncidentStore(root: scratch).artifactText(incidentID: incident.id, entry: $0) }
        }
        check(artifactText?.contains(LogRedactor.placeholder) == true,
              "the transcript snapshot should carry the redaction placeholder where the secret was")
        check(artifactText?.contains("the pod cannot reach S3") == true,
              "redaction must keep the surrounding investigation text readable")

        // MARK: The one-line rule is structural, not a convention

        let multiline = IncidentTimelineEntry(kind: .note, title: "line one\nline two\r\nline three")
        check(!multiline.title.contains("\n") && !multiline.title.contains("\r"),
              "a multi-line title must be collapsed, got \(multiline.title)")
        let long = IncidentTimelineEntry(kind: .note, title: String(repeating: "x", count: 5000))
        check(long.title.count <= IncidentTimelineEntry.maxTextLength,
              "a pathological title must be bounded, got \(long.title.count) characters")

        // MARK: Evidence is the captures, not everything

        let evidence = IncidentStore(root: scratch).load(id: created.id)?.evidenceEntries ?? []
        check(evidence.count == 1, "only the capture should be evidence, got \(evidence.count)")
        check(evidence.first?.kind == .logCapture, "evidence rows should all be captures")

        // A saved investigation is the openable kind of evidence.
        let saved = IncidentSources.investigationSaved(title: "payments-worker crash loop", id: "inv-77")
        check(saved.reference == "inv-77", "a saved investigation should carry its id as the reference")
        check(store.append(saved, to: created.id), "appending a saved investigation should succeed")
        check(IncidentStore(root: scratch).load(id: created.id)?.evidenceEntries.count == 2,
              "a saved investigation should join the evidence list")

        // MARK: What the postmortem generator is actually fed

        guard let full = IncidentStore(root: scratch).load(id: created.id) else {
            print("[incident] FAIL: could not reload the incident for the aggregate check")
            return false
        }
        let aggregate = IncidentStore(root: scratch).aggregatedTranscript(for: full)
        check(aggregate.contains(created.id) && aggregate.contains("payments-worker OOMKilled"),
              "the aggregate should identify the incident")
        check(aggregate.contains("EKS Preprod Bastion"), "the aggregate should name the host")
        check(aggregate.contains("Restart OOMKilled pod"), "the aggregate should include the runbook run")
        check(aggregate.contains("Log Analyzer capture"), "the aggregate should include the capture")
        check(aggregate.contains("the pod cannot reach S3"),
              "the aggregate should include the SRE Lead transcript itself, not just a one-liner")
        check(!aggregate.contains(secret), "the aggregate handed to the generator must be redacted too")

        // MARK: Ending

        let ended = store.end(id: created.id)
        check(ended?.status == .ended, "ending should mark the incident ended")
        check(ended?.endedAt != nil, "ending should stamp a time")
        check(store.activeIncident(hostID: hostA) == nil, "an ended incident is no longer active")
        let endedOnDisk = IncidentStore(root: scratch).load(id: created.id)
        check(endedOnDisk?.status == .ended, "the ended status should be on disk")
        // Idempotent: ending twice must not move the stored timestamp.
        // Compared against what is on *disk* both times - the in-memory
        // `Date()` from the first call carries sub-second precision the ISO
        // round trip does not, so comparing those two would fail for a
        // formatting reason rather than a behavioural one.
        let storedEndBefore = endedOnDisk?.endedAt
        _ = store.end(id: created.id)
        let storedEndAfter = IncidentStore(root: scratch).load(id: created.id)?.endedAt
        check(storedEndBefore != nil && storedEndBefore == storedEndAfter,
              "ending an already-ended incident must not move its stored end time")

        check(store.setRCA(id: created.id, markdown: "# RCA\n\nIt was memory."),
              "storing the generated RCA should succeed")
        let withRCA = IncidentStore(root: scratch).load(id: created.id)
        check(withRCA?.rcaMarkdown?.contains("It was memory.") == true,
              "the RCA should survive a reload")
        // And it lives in its own file, not inline in the metadata. Found by
        // walking for the real `incident.yaml`, so this cannot pass simply by
        // failing to read anything.
        var yamlFilesRead = 0
        var rcaInlined = false
        if let walker = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent == "incident.yaml" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                yamlFilesRead += 1
                if text.contains("It was memory.") { rcaInlined = true }
            }
        }
        check(yamlFilesRead >= 1, "expected to read at least one incident.yaml, read \(yamlFilesRead)")
        check(!rcaInlined, "the RCA body must not be inlined in incident.yaml")

        // Once ended, the same host can start a fresh one.
        if case .failure = store.start(title: "a later, separate incident",
                                       hostID: hostA, hostLabel: "EKS Preprod Bastion") {
            failures.append("a host with no active incident should be able to start one")
        }
        check(store.incidents(hostID: hostA).count == 2, "the earlier incident should still be on record")

        // MARK: F6 (fleet history / captain's log) wiring

        let logDir = scratch.appendingPathComponent("fleet-log", isDirectory: true)
        let log = FleetLogStore(directory: logDir)
        log.append(FleetLogSources.incidentStarted(id: "INC-014", title: "payments-worker OOMKilled",
                                                   hostLabel: "EKS Preprod Bastion"))
        log.append(FleetLogSources.incidentEnded(id: "INC-014", title: "payments-worker OOMKilled",
                                                 hostLabel: "EKS Preprod Bastion",
                                                 startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                 endedAt: Date(timeIntervalSince1970: 1_700_001_920)))
        log.debugForgetCache()
        let events = log.events()
        check(events.count == 2, "both incident events should be on disk, got \(events.count)")
        check(events.allSatisfy { $0.kind == .incident }, "incident events should use the incident kind")
        check(events.last?.title.contains("Started incident INC-014") == true,
              "the start event should name the incident")
        check(events.first?.title.contains("after 32m") == true,
              "the end event should carry how long it ran, got \(events.first?.title ?? "nil")")
        check(events.allSatisfy { $0.reference == "INC-014" },
              "both events should reference the incident id")
        check(FleetLogFeed.filtered(events, kind: .incident).count == 2,
              "the Incidents filter pill should keep both")
        check(FleetLogFeed.filtered(events, kind: .merge).isEmpty,
              "another pill must not keep incident events")
        check(FleetLogEventKind.allCases.contains(.incident),
              "the incident kind must be in allCases, or the filter row has no pill for it")

        // The round trip above still passes if the call site were deleted, so
        // check that the one path which starts and ends an incident really
        // does append - the same source-guard shape `UnifiedSearchSelfTest`
        // and `Phase2HardeningSelfTest` already use.
        if let sources = SelfTestSources.appSourceDirectory() {
            let path = sources.appendingPathComponent("ConsoleController+Incident.swift")
            if let text = try? String(contentsOf: path, encoding: .utf8) {
                check(text.contains("FleetLogSources.incidentStarted"),
                      "starting an incident must append to the captain's log")
                check(text.contains("FleetLogSources.incidentEnded"),
                      "ending an incident must append to the captain's log")
                check(text.contains("SRELeadPostmortem.generate"),
                      "ending an incident must go through the existing postmortem generator")
                check(text.contains("aggregatedTranscript"),
                      "the generator must be fed the incident's aggregate, not one tab's chat")
            } else {
                failures.append("could not read ConsoleController+Incident.swift for the source guard")
            }
        }

        // MARK: `FM_SHIFT_DIR` is honoured, not just `FM_INCIDENTS_DIR`
        //
        // The lesson `CommandLibraryStore` learned the hard way: a store
        // inside `ShiftGitSync`'s subtree that ignores `FM_SHIFT_DIR` will
        // write into the captain's real synced clone from a suite that
        // correctly set only that variable.
        let savedIncidents = ProcessInfo.processInfo.environment["FM_INCIDENTS_DIR"]
        let savedShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let envScratch = scratch.appendingPathComponent("env-root", isDirectory: true)
        unsetenv("FM_INCIDENTS_DIR")
        setenv("FM_SHIFT_DIR", envScratch.path, 1)
        let envStore = IncidentStore()
        check(envStore.root.path == envScratch.path,
              "FM_SHIFT_DIR should redirect the store, got \(envStore.root.path)")
        check(envStore.gitSync == nil, "an env-overridden store must never reach git sync")
        if let savedIncidents { setenv("FM_INCIDENTS_DIR", savedIncidents, 1) }
        if let savedShift { setenv("FM_SHIFT_DIR", savedShift, 1) } else { unsetenv("FM_SHIFT_DIR") }

        // MARK: S6 - an artifact path read off disk cannot escape its incident
        //
        // `artifact` comes from the incident's own on-disk YAML, and it was
        // appended to the incident directory unvalidated - so a tampered
        // `incident.yaml` carrying `../../../../etc/passwd` would have made
        // `artifactText` read an arbitrary file and show it to the captain.
        for escape in ["../../../../etc/passwd",
                       "artifacts/../../../etc/passwd",
                       "/etc/passwd",
                       "~/.ssh/id_ed25519",
                       "artifacts/../../secret.md",
                       "a/b/c/d.md",
                       ".hidden",
                       ""] {
            check(IncidentStore.safeArtifactName(escape) == nil,
                  "S6: \(escape.debugDescription) should be refused as an artifact path")
        }
        // ... and the one shape this store actually writes must still work, or
        // the guard would have silently broken every real artifact.
        check(IncidentStore.safeArtifactName("artifacts/entry-1.md") == "artifacts/entry-1.md",
              "S6: the store's own artifact path shape was refused")

        // MARK: Report

        if failures.isEmpty {
            print("[incident] OK - all IncidentStore checks passed")
            return true
        }
        for failure in failures { print("[incident] FAIL: \(failure)") }
        return false
    }
}

#endif
