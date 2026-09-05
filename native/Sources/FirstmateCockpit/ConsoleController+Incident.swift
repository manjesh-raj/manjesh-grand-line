// Manjesh Grand Line - native macOS app.
//
// F8 - Incident mode, host-page side. The toolbar action, the card popover,
// and the three attach points that make an incident a *shared* record rather
// than a fifth surface.
//
// Sits alongside `ConsoleController+SRELead.swift` / `+LogCapture.swift` for
// the same reason those are extensions rather than free-standing
// coordinators (GL-36): everything here needs the current tab, the toolbar's
// own button and this page's host identity, and a coordinator would need all
// three handed to it and buy nothing beyond the file boundary an extension
// already gives.
//
// **The attach points, and the rule they all follow.** Each one is a *hook on
// an event that already happens*, never a new detection and never a second
// execution path:
//
//   - `noteSRELeadTurn`      called from `handleSRELeadSubmit`'s own reply
//                            completion - the same place the notification
//                            centre is already told about a background reply.
//   - `noteLogCapture`       called from `analyzeLogsTapped`, with the capture
//                            `LogTerminalCaptureBuilder` already built.
//   - `noteInvestigationSaved` forwarded from `LogAnalyzerController`'s own
//                            save, via `AppShellController`.
//   - `noteRunbookRun`       forwarded from `SRELeadBridge`, which reads the
//                            event file `sre_kubectl_mcp.py`'s existing
//                            `run_runbook` writes after it finishes. The
//                            runbook still executes exactly where it always
//                            did; this only observes the outcome.
//
// Every one of them writes through `IncidentStore.append`, which hits the
// disk before returning - see that file's header for what that buys and for
// the one thing it does not (F2's session restore).

import AppKit

/// Which saved host this console page belongs to. Set by
/// `AppShellController.connectHost`; `nil` on the shared Firstmate console,
/// which has no single host and therefore no incidents.
struct ConsoleHostIdentity {
    let id: String
    let label: String
}

extension ConsoleController {

    // MARK: Toolbar

    /// Rebuilds the incident button to match the record on disk. The button
    /// is the always-visible active-incident indicator (see
    /// `IncidentCardView`'s header for why the card itself is a popover): red
    /// "Start Incident" with nothing running, red "INC-014" while one is.
    func updateIncidentControls() {
        guard let button = incidentButton else { return }
        guard hostIdentity != nil else {
            button.isHidden = true
            incidentPopover.performClose(nil)
            return
        }
        button.isHidden = false
        if let incident = activeIncident() {
            button.title = incident.id
            button.symbolName = "bolt.fill"
            button.toolTip = "\(incident.id) - \(incident.title) (\(incident.subtitle()))"
        } else {
            button.title = "Start Incident"
            button.symbolName = "bolt"
            button.toolTip = "Start an incident on this host - SRE Lead turns, Log Analyzer captures "
                + "and runbook runs attach to it automatically."
        }
        // `.critical` throughout: an incident is the one thing on this
        // toolbar that is red whether or not it has started, because
        // "start an incident" is itself the alarming action.
        button.tint = .critical
    }

    /// The record's own answer, never a cached flag - so a relaunch, or a
    /// second page for the same host, sees the same truth.
    func activeIncident() -> Incident? {
        guard let hostIdentity else { return nil }
        return incidentStore.activeIncident(hostID: hostIdentity.id)
    }

    @objc func incidentButtonClicked() {
        guard hostIdentity != nil else { return }
        if incidentPopover.isShown {
            incidentPopover.performClose(nil)
            return
        }
        if activeIncident() == nil {
            promptForNewIncident()
        } else {
            showIncidentCard()
        }
    }

    // MARK: Starting

    /// One short prompt for a title, then a real record. Deliberately an
    /// `NSAlert` with an accessory field rather than a whole editor sheet:
    /// this happens while something is on fire, and every other field an
    /// incident has (host, time, status) is already known.
    private func promptForNewIncident() {
        guard let hostIdentity else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Start an incident on \(hostIdentity.label)?"
        alert.informativeText = "SRE Lead turns, Log Analyzer captures and runbook runs on this host will "
            + "attach to it automatically until you end it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "What is happening? e.g. payments-worker OOMKilled"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start Incident")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.startIncident(title: field.stringValue)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func startIncident(title: String) {
        guard let hostIdentity else { return }
        switch incidentStore.start(title: title, hostID: hostIdentity.id, hostLabel: hostIdentity.label) {
        case .success(let incident):
            // Turn numbering is per incident, not per session: a tab that
            // answered six questions during the last incident starts this
            // one's timeline at "turn 1" again.
            sreLeadTurnCounts.removeAll()
            // F6 (fleet history / captain's log): appended here, from the one
            // code path that starts an incident, after the record genuinely
            // reached disk. Only the id, the title and the host label cross
            // this boundary.
            FleetLogStore.shared.append(FleetLogSources.incidentStarted(id: incident.id,
                                                                        title: incident.title,
                                                                        hostLabel: incident.hostLabel))
            updateIncidentControls()
            showIncidentCard()
        case .failure(.alreadyActive(let existingID)):
            // The store refuses even if a UI path ever forgets to check - see
            // `IncidentStore.StartFailure`.
            Toast.show(in: view, message: "\(existingID) is already active on this host")
            updateIncidentControls()
            showIncidentCard()
        case .failure(.couldNotWrite):
            Toast.show(in: view, message: "Couldn't write the incident record")
        }
    }

    // MARK: The card

    func showIncidentCard() {
        guard let button = incidentButton, !button.isHidden else { return }
        renderIncidentCard()
        if !incidentPopover.isShown {
            // `ThemeManager.swift`'s checklist item 2, the same line the
            // avatar / notification / Claude-usage / Console-composer /
            // Recents / Whiteboard popovers have all carried for years, and
            // the one this newer popover was built without. `IncidentCardView`
            // derives every colour it paints itself from `theme`, so the card
            // body was already right - what was not is everything AppKit
            // resolves semantically inside it (the notes field's editor, the
            // evidence list's scroller chrome, focus rings), which follows the
            // OS's own light/dark setting until the popover's appearance says
            // otherwise. Set on every open, not once at build time: an
            // incident card outlives several theme changes.
            incidentPopover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            incidentPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    func renderIncidentCard(busyText: String? = nil) {
        incidentCard.render(activeIncident() ?? mostRecentIncident(), theme: theme, busyText: busyText)
    }

    /// What the card shows once an incident has been ended: the one just
    /// finished, so the generated RCA is readable without hunting for it.
    private func mostRecentIncident() -> Incident? {
        guard let hostIdentity else { return nil }
        return incidentStore.incidents(hostID: hostIdentity.id).first
    }

    func buildIncidentCard() {
        incidentCard.onEndIncident = { [weak self] in self?.endIncidentClicked() }
        incidentCard.onAddNote = { [weak self] text in
            guard let self, let incident = self.activeIncident() else { return }
            self.incidentStore.append(IncidentSources.note(text), to: incident.id)
            self.renderIncidentCard()
        }
        incidentCard.onOpenEvidence = { [weak self] reference in
            self?.incidentPopover.performClose(nil)
            self?.onOpenInvestigation?(reference)
        }

        let controller = NSViewController()
        controller.view = incidentCard
        incidentPopover.contentViewController = controller
        incidentPopover.contentSize = NSSize(width: IncidentCardView.cardWidth, height: IncidentCardView.cardHeight)
        incidentPopover.behavior = .transient
    }

    // MARK: Ending

    /// Marks the incident ended, then feeds the **incident's own aggregated
    /// content** to the existing postmortem generator.
    ///
    /// This is the one place F8 touches `SRELeadPostmortem`, and it calls the
    /// same `generate(hostLabel:transcript:)` the pane's own button calls -
    /// there is no second generator and no second prompt. What changes is
    /// only what is handed in: `IncidentStore.aggregatedTranscript` assembles
    /// every SRE Lead turn's real text plus a one-line account of every
    /// capture and runbook run, in order, instead of one tab's chat.
    ///
    /// A generation failure never un-ends the incident or loses the record:
    /// the incident is already `ended` on disk by then, and the captain can
    /// still read the whole timeline. The postmortem is the only thing missing.
    @objc func endIncidentClicked() {
        guard let incident = activeIncident() else { return }
        guard let ended = incidentStore.end(id: incident.id) else {
            Toast.show(in: view, message: "Couldn't write the incident record")
            return
        }
        FleetLogStore.shared.append(FleetLogSources.incidentEnded(id: ended.id,
                                                                  title: ended.title,
                                                                  hostLabel: ended.hostLabel,
                                                                  startedAt: ended.startedAt,
                                                                  endedAt: ended.endedAt ?? Date()))
        updateIncidentControls()
        renderIncidentCard(busyText: "Generating postmortem\u{2026}")

        let transcript = incidentStore.aggregatedTranscript(for: ended)
        SRELeadPostmortem.generate(hostLabel: ended.hostLabel, transcript: transcript) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let markdown):
                self.incidentStore.setRCA(id: ended.id, markdown: markdown)
                let title = DocsRunbookStore.titleFromContent(markdown,
                                                              fallback: "\(ended.id) - \(ended.title)")
                let saved = self.docsRunbookStore.createPostmortem(title: title, content: markdown)
                Toast.show(in: self.view, message: "Postmortem saved: \(saved.title)")
            case .failure(let error):
                Toast.show(in: self.view, message: "Couldn't generate the postmortem: \(error.message)")
            }
            self.renderIncidentCard()
        }
    }

    // MARK: Attach points

    /// One completed SRE Lead turn. Called from `handleSRELeadSubmit`'s reply
    /// handler, so it only ever fires for a turn that genuinely produced an
    /// answer - a failed turn is an error in that tab's own chat, not
    /// something that happened to the cluster.
    ///
    /// The transcript *as of this turn* is snapshotted into the incident's
    /// own artifact directory (redacted on the way in - see
    /// `IncidentStore.append`), which is the durability the review's F8 entry
    /// asks for: the record does not depend on the tab still being open, or
    /// on the app still running, to say what SRE Lead found.
    func noteSRELeadTurn(question: String, tab: TabModel) {
        guard let incident = activeIncident() else { return }
        let turn = (sreLeadTurnCounts[tab.id] ?? 0) + 1
        sreLeadTurnCounts[tab.id] = turn
        let transcript = tab.sreLead?.chatView?.transcriptForPostmortem
        incidentStore.append(IncidentSources.sreLeadTurn(question: question, tabName: tab.name, turn: turn),
                             to: incident.id,
                             artifactText: transcript)
        renderIncidentCardIfShown()
    }

    /// The Analyze Logs capture. Only the capture's *shape* is recorded - the
    /// line count and the scope sentence the builder already wrote for the
    /// captain - never `capture.text`, which at this point has not been
    /// through `LogRedactor` yet (that happens inside
    /// `LogAnalyzerController.addEvidence`).
    func noteLogCapture(_ capture: LogTerminalCapture, tabName: String) {
        guard let incident = activeIncident() else { return }
        let lines = capture.text.split(separator: "\n", omittingEmptySubsequences: false).count
        incidentStore.append(IncidentSources.logCapture(tabName: tabName,
                                                        lineCount: lines,
                                                        scopeDescription: capture.scopeDescription),
                             to: incident.id)
        renderIncidentCardIfShown()
    }

    /// A Log Analyzer investigation that was saved while this incident was
    /// active - the evidence row the captain can reopen later. Idempotent:
    /// `LogAnalyzerController.persistIfNeeded` runs on every storage-choice
    /// change for the same investigation, and the timeline wants one row per
    /// investigation, not one per edit.
    func noteInvestigationSaved(id: String, title: String) {
        guard let incident = activeIncident() else { return }
        guard !incident.entries.contains(where: { $0.reference == id }) else { return }
        incidentStore.append(IncidentSources.investigationSaved(title: title, id: id), to: incident.id)
        renderIncidentCardIfShown()
    }

    /// A runbook that ran through SRE Lead's MCP bridge. The values come
    /// straight from `run_runbook`'s own result - see
    /// `SRELeadBridge.onRunbookRun`.
    func noteRunbookRun(name: String, ran: Int, total: Int, ok: Bool, refused: Bool) {
        guard let incident = activeIncident() else { return }
        incidentStore.append(IncidentSources.runbookRun(name: name, ran: ran, total: total,
                                                        ok: ok, refused: refused),
                             to: incident.id)
        renderIncidentCardIfShown()
    }

    private func renderIncidentCardIfShown() {
        guard incidentPopover.isShown else { return }
        renderIncidentCard()
    }
}
