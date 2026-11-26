// Grand Line - native macOS app.
//
// D-05 of full review 4: Incident mode's timeline, the commands sent and the
// Log Analyzer's findings, exported as one Markdown postmortem draft.
// Run with `FM_RUN_INCIDENT_EXPORT_TESTS=1 .build/debug/GrandLine`.
//
// Headless: the card is built and rendered without a window, and its buttons
// are pressed with `performClick`, which runs the real target/action.
//
// What it pins:
//
//  - **A sent command is a timeline entry, redacted, and survives a reload.**
//    The new `.command` kind is written and read back by a fresh store, and a
//    planted bearer token never reaches the bytes on disk.
//  - **The draft carries facts and leaves judgement as prompts.** The
//    timeline table, the commands block, the likely cause from a saved
//    investigation and the runbook run are all in it; the summary, root cause
//    and action items are prompts.
//  - **An unticked section is left out**, and an investigation with no
//    analysis gives no finding rather than an empty one (GL-14).
//  - **Redaction is always on**, for free text a note carries too.
//  - **The card's Export button opens the panel and "Create draft" hands the
//    chosen options back**, through the real buttons.
//  - **Source guards** on the send paths that attach a command, because a
//    behavioural check of the store passes with those call sites deleted.

#if FM_SELFTESTS

import AppKit

enum IncidentExportSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("command entry is redacted and round-trips", test_commandEntryRoundTrip),
            ("draft carries facts, prompts for judgement", test_draftContent),
            ("unticked sections are left out", test_optionsOmitSections),
            ("redaction is always on", test_redactionAlwaysOn),
            ("unanalysed investigation gives no finding", test_findingsSkipUnanalysed),
            ("card export button and panel", test_cardExportFlow),
            ("send paths attach the command", test_sendPathsAttach),
        ]
        for (name, body) in cases {
            if let failure = body() {
                fail("[incident-export] \(name): \(failure)", &ok)
            } else {
                print("[incident-export] PASS \(name)")
            }
        }
        print(ok ? "[incident-export] ALL PASS" : "[incident-export] FAILED")
        return ok
    }

    // MARK: Fixtures

    static let token = "ghp_1234567890abcdefghijklmnopqrstuvwxyz"

    private static func withScratch<T>(_ body: (URL) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return body(dir)
    }

    /// A fixed incident with one entry of every kind, at fixed times in UTC.
    static func fixture(ended: Bool = true) -> Incident {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        func at(_ minutes: Int) -> Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
        return Incident(id: "INC-014", title: "checkout-worker crash loop", hostID: "h", hostLabel: "DEV Bastion",
                        startedAt: start, endedAt: ended ? at(34) : nil, status: ended ? .ended : .active,
                        entries: [
                            IncidentTimelineEntry(at: at(0), kind: .sreLead, title: "SRE Lead investigation started",
                                                  detail: "turn 1 on DEV Bastion"),
                            IncidentTimelineEntry(at: at(2), kind: .logCapture, title: "Saved investigation",
                                                  reference: "inv-1"),
                            IncidentSources.commandSent("kubectl -n prod set env deploy/checkout-worker EXPORT_BUCKET=exports-prod",
                                                        tabName: "DEV Bastion", via: "Compose"),
                            IncidentSources.runbookRun(name: "Restart a deployment", ran: 3, total: 3,
                                                       ok: true, refused: false),
                            IncidentSources.note("502s stopped at 10:50"),
                        ],
                        rcaMarkdown: nil)
    }

    static func investigation(analysed: Bool) -> LogInvestigation {
        var inv = LogInvestigation(id: "inv-1", title: "checkout-worker logs")
        guard analysed else { return inv }
        let detection = LogSourceDetection(kind: .genericText, severity: .high, confidence: 0.5)
        let local = LogLocalAnalysis(detection: detection, groups: [],
                                     timeline: .unavailable(reason: "fixture"),
                                     observedCorrelation: [], lineCount: 40,
                                     findings: [LogFinding(severity: .high, title: "KeyError EXPORT_BUCKET",
                                                           detail: "43 occurrences", meta: nil)])
        let cause = LogRootCause(summary: "EXPORT_BUCKET is not set", explanation: "", confidence: .medium,
                                 evidence: [], missingEvidence: [], contradictingEvidence: [])
        let ai = LogAIAnalysis(findings: [], rootCause: cause, nextSteps: [], suggestedCommands: [],
                               correlation: [], neededEvidence: [], summary: "")
        inv.analysis = LogAnalysis(local: local, ai: ai, aiFailure: nil, mode: .analyze, analyzedAt: Date())
        return inv
    }

    // MARK: Cases

    static func test_commandEntryRoundTrip() -> String? {
        withScratch { root in
            let store = IncidentStore(root: root)
            guard case .success(let incident) = store.start(title: "t", hostID: "h", hostLabel: "Host") else {
                return "could not start an incident"
            }
            let entry = IncidentSources.commandSent("curl -H \"Authorization: Bearer \(token)\" https://api.example.test\nsecond line",
                                                    tabName: "Bastion", via: "Command Library")
            guard entry.kind == .command else { return "commandSent should make a .command entry" }
            guard !entry.title.contains(token) else { return "the token reached the entry title: \(entry.title)" }
            guard entry.detail?.contains("2 lines") == true, entry.detail?.contains("secrets redacted") == true else {
                return "the detail should say the line count and that secrets were redacted: \(entry.detail ?? "nil")"
            }
            guard store.append(entry, to: incident.id) else { return "append failed" }
            let reloaded = IncidentStore(root: root).load(id: incident.id)
            guard let back = reloaded?.entries.first(where: { $0.kind == .command }) else {
                return "the command entry did not survive a reload (kind not decoded?)"
            }
            guard back.title == entry.title else { return "title changed on reload: \(back.title)" }
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(token) {
                    return "the token is in the bytes of \(url.lastPathComponent)"
                }
            }
            return nil
        }
    }

    static func test_draftContent() -> String? {
        let incident = fixture()
        let findings = IncidentPostmortemExport.findings(for: incident) { $0 == "inv-1" ? investigation(analysed: true) : nil }
        guard findings.count == 1 else { return "expected one finding, got \(findings.count)" }
        let md = IncidentPostmortemExport.markdown(for: incident, findings: findings, options: .init(),
                                                   timeZone: TimeZone(identifier: "UTC")!)
        let expected = [
            "# Postmortem: checkout-worker crash loop",
            "INC-014 \u{00B7} ",
            "| Time | Event |",
            "Command: `kubectl -n prod set env deploy/checkout-worker EXPORT_BUCKET=exports-prod`",
            "## Commands\n\n```\nkubectl -n prod set env deploy/checkout-worker EXPORT_BUCKET=exports-prod\n```",
            "- **Likely cause:** EXPORT_BUCKET is not set (medium confidence)",
            "KeyError EXPORT_BUCKET: 43 occurrences",
            "Ran runbook: \u{201C}Restart a deployment\u{201D}",
            "Note: 502s stopped at 10:50",
            "_What happened, in two sentences._",
            "## Root cause",
            "- [ ] _to fill_",
        ]
        for needle in expected where !md.contains(needle) {
            return "the draft is missing \"\(needle)\":\n\(md)"
        }
        // The fixture's own discriminating power: a timeline row per entry.
        let rows = md.components(separatedBy: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Time") }
        guard rows.count == incident.entries.count else {
            return "expected \(incident.entries.count) timeline rows, got \(rows.count)"
        }
        let counts = IncidentPostmortemExport.counts(for: incident, findings: findings)
        guard counts == .init(timeline: 5, commands: 1, findings: 1, runbookRuns: 1) else {
            return "counts are wrong: \(counts)"
        }
        return nil
    }

    static func test_optionsOmitSections() -> String? {
        let incident = fixture()
        var options = IncidentPostmortemExport.Options()
        options.commands = false
        options.timeline = false
        let md = IncidentPostmortemExport.markdown(for: incident, findings: [], options: options,
                                                   timeZone: TimeZone(identifier: "UTC")!)
        if md.contains("## Commands") { return "commands were unticked but the section is there" }
        if md.contains("## Timeline") { return "timeline was unticked but the section is there" }
        guard md.contains("## Runbook runs") else { return "a ticked section went missing" }
        return nil
    }

    static func test_redactionAlwaysOn() -> String? {
        var incident = fixture()
        incident.entries.append(IncidentSources.note("used token \(token) to check"))
        let md = IncidentPostmortemExport.markdown(for: incident, findings: [], options: .init(),
                                                   timeZone: TimeZone(identifier: "UTC")!)
        guard md.contains("used token") else { return "the note itself is missing, so this check is vacuous" }
        return md.contains(token) ? "a token in a note reached the draft" : nil
    }

    static func test_findingsSkipUnanalysed() -> String? {
        let findings = IncidentPostmortemExport.findings(for: fixture()) { _ in investigation(analysed: false) }
        guard findings.isEmpty else { return "an unanalysed investigation produced a finding" }
        let none = IncidentPostmortemExport.findings(for: fixture()) { _ in nil }
        return none.isEmpty ? nil : "an unreadable investigation produced a finding"
    }

    static func test_cardExportFlow() -> String? {
        let card = IncidentCardView()
        let theme = ThemeManager.shared.theme
        card.render(nil, theme: theme)
        guard card.debugExportButton.isHidden else { return "export should be hidden with no incident" }

        card.render(fixture(ended: false), theme: theme)
        guard !card.debugExportButton.isHidden, !card.debugEndButton.isHidden else {
            return "an active incident should show both End and Export"
        }
        card.render(fixture(ended: true), theme: theme)
        guard !card.debugExportButton.isHidden else { return "an ended incident should still offer Export" }

        var received: (IncidentPostmortemExport.Options, IncidentPostmortemExport.Destination)?
        card.onExport = { _, options, destination in received = (options, destination) }
        card.debugExportButton.performClick(nil)
        guard card.isShowingExport, !card.debugExportPanel.isHidden else {
            return "clicking Export did not show the export panel"
        }
        guard card.debugExportPanel.debugCountTexts["timeline"] == "5 events",
              card.debugExportPanel.debugCountTexts["commands"] == "1 command" else {
            return "panel counts are wrong: \(card.debugExportPanel.debugCountTexts)"
        }
        card.debugExportPanel.debugSetSection("commands", on: false)
        card.debugExportPanel.debugSelectDestination(.copy)
        card.debugExportPanel.debugCreate()
        guard let (options, destination) = received else { return "Create draft did not reach onExport" }
        guard !options.commands, options.timeline, destination == .copy else {
            return "onExport got the wrong choices: \(options), \(destination)"
        }
        guard !card.isShowingExport else { return "the panel should close after Create draft" }
        return nil
    }

    static func test_sendPathsAttach() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("[incident-export] SKIP send-path guard: could not find the app sources")
            return nil
        }
        func read(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let sessions = read("ConsoleController+Sessions.swift")
        guard let send = sessions.range(of: "func sendCommandLibraryTextToActiveTab"),
              sessions[send.upperBound...].prefix(400).contains("noteCommandSent(") else {
            return "sendCommandLibraryTextToActiveTab no longer attaches the command"
        }
        guard let snippet = sessions.range(of: "func runSnippetInActiveTab"),
              sessions[snippet.upperBound...].prefix(400).contains("noteCommandSent(") else {
            return "runSnippetInActiveTab no longer attaches the command"
        }
        let console = read("ConsoleController.swift")
        guard let compose = console.range(of: "composer.onRunInTerminal"),
              console[compose.upperBound...].prefix(900).contains("noteCommandSent(") else {
            return "Compose's run no longer attaches the command"
        }
        return nil
    }
}

#endif
