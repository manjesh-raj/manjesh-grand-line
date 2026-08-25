// Manjesh Grand Line - native macOS app.
//
// F7's Overview surface: the "Needs your call" list and each row's inline
// reply composer.
//
// Split out of `FleetController.swift` (already ~1000 lines) along the same
// seam `ConsoleController`'s own six files use - a Swift extension cannot hold
// stored properties, so this feature's few live views are declared in the main
// file's "F7" block and everything that *does* something with them is here.
//
// Nothing in this file talks to a channel: a row's Send calls
// `FleetActions.reply`, which shells out to `bin/fm-send.sh`.
//
// This file used to also hold the header's unaddressed "Message first mate"
// composer - a general (not task-addressed) message typed into the
// herdr-attached "Mirror" tab, via `AppShellController.sendToFirstmate` ->
// `ConsoleController.sendToFirstmateMirror`. `fm/grand-line-remove-firstmate-
// mirror` removed it whole, along with that tab: with no embedded herdr
// session to type into, the feature had nowhere left to send. The captain's
// own words on why the tab is gone at all: he'll watch/drive firstmate's own
// session in his own terminal, not embedded in this app. The per-task Reply
// path below is untouched - it never went through the Mirror tab.

import AppKit

extension FleetController {

    // MARK: The "Needs your call" section

    /// Same shape as `buildSection(title:)`'s "In flight" heading - a round
    /// glyph, a title, a count chip - over a stack of `HelmAccentRow` cards.
    func buildNeedsSection() -> NSView {
        needsHeaderLabel.font = HelmType.sectionTitle()
        needsHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        needsGlyph.configure(symbol: "exclamationmark.bubble.fill", tint: .warn, pointSize: 11)
        needsGlyph.setContentHuggingPriority(.required, for: .horizontal)

        needsCountLabel.font = HelmType.metric(11, weight: .medium)
        needsCountLabel.translatesAutoresizingMaskIntoConstraints = false
        needsCountChip.wantsLayer = true
        needsCountChip.layer?.cornerRadius = 5
        needsCountChip.translatesAutoresizingMaskIntoConstraints = false
        needsCountChip.addSubview(needsCountLabel)
        NSLayoutConstraint.activate([
            needsCountLabel.leadingAnchor.constraint(equalTo: needsCountChip.leadingAnchor, constant: 6),
            needsCountLabel.trailingAnchor.constraint(equalTo: needsCountChip.trailingAnchor, constant: -6),
            needsCountLabel.topAnchor.constraint(equalTo: needsCountChip.topAnchor, constant: 1),
            needsCountLabel.bottomAnchor.constraint(equalTo: needsCountChip.bottomAnchor, constant: -1),
        ])
        needsCountChip.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [needsGlyph, needsHeaderLabel, needsCountChip, spacer])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.distribution = .fill
        heading.spacing = HelmMetrics.s2
        heading.translatesAutoresizingMaskIntoConstraints = false

        needsStack.orientation = .vertical
        needsStack.alignment = .leading
        needsStack.spacing = HelmMetrics.s2
        needsStack.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [heading, needsStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = HelmMetrics.s3
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: section.widthAnchor),
            needsStack.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        return section
    }

    /// Rebuild the needs-decision/blocked rows. An already-open composer is
    /// re-inserted rather than rebuilt, so a refresh landing mid-sentence
    /// (Refresh, or simply navigating back to Overview) never discards what
    /// the captain has typed.
    func rebuildNeedsRows(_ tasks: [FleetTask]) {
        for v in needsStack.arrangedSubviews {
            needsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        needsAccentRows.removeAll()
        needsCountLabel.stringValue = "\(tasks.count)"
        // The section is a list of things needing an answer; with none, the
        // banner directly above already says "nothing needs you right now",
        // so a second empty state under it would be noise (this app's own
        // "quiet until it matters" rule).
        needsSectionView.isHidden = tasks.isEmpty
        if tasks.isEmpty {
            closeReplyComposer()
            return
        }
        // A composer whose task is no longer parked has nothing to answer.
        if let open = openReplyTaskID, !tasks.contains(where: { $0.id == open }) {
            closeReplyComposer()
        }
        for task in tasks {
            let row = needsRowView(task)
            needsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: needsStack.widthAnchor).isActive = true
            if task.id == openReplyTaskID, let composer = openReplyComposer {
                needsStack.addArrangedSubview(composer)
                composer.widthAnchor.constraint(equalTo: needsStack.widthAnchor).isActive = true
            }
        }
    }

    private func needsRowView(_ task: FleetTask) -> NSView {
        let blocked = task.status == "blocked"
        let reply = HelmButton(title: openReplyTaskID == task.id ? "Cancel" : "Reply",
                               variant: .secondary, size: .small,
                               symbol: openReplyTaskID == task.id ? "xmark" : "arrowshape.turn.up.left")
        reply.identifier = NSUserInterfaceItemIdentifier("fleet.reply.\(task.id)")
        reply.toolTip = "Answer \(task.id) in the crew's own session"
        reply.target = self
        reply.action = #selector(replyTapped(_:))
        reply.setContentHuggingPriority(.required, for: .horizontal)
        reply.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = HelmAccentRow(trailingAccessory: reply, hover: false)
        row.configure(HelmAccentRow.Content(
            tint: blocked ? .critical : .warn,
            kicker: blocked ? "Blocked \u{00B7} \(task.id)" : "Needs decision \u{00B7} \(task.id)",
            title: task.repo ?? task.id,
            meta: replyRowMeta(task),
            badgeSymbol: blocked ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
            chipText: blocked ? "blocked" : "needs you"
        ), theme: currentTheme)
        needsAccentRows.append(row)
        return row
    }

    /// The row's second line: the crew's own words where there are any (the
    /// open decision's note, which is literally the question being asked),
    /// falling back to `fm-crew-state.sh`'s detail. Never invented text.
    ///
    /// This reads the task's status file on the main thread. That is a small
    /// bounded cost paid only for the handful of *parked* tasks this section
    /// lists (never the whole fleet), and it has to be live rather than
    /// cached: the note is the question the composer opens pre-addressed to,
    /// and the key derived from the same fold is what `fm-send` validates
    /// before it will send anything.
    private func replyRowMeta(_ task: FleetTask) -> String {
        let open = FleetActions.openDecisions(taskID: task.id)
        if let note = open.last?.note, !note.isEmpty { return note }
        return task.detail.isEmpty ? "source: \(task.source)" : task.detail
    }

    // MARK: The per-row reply composer

    @objc func replyTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("fleet.reply.") else { return }
        let taskID = String(raw.dropFirst("fleet.reply.".count))
        if openReplyTaskID == taskID {
            closeReplyComposer()
            refreshNeedsRows()
            return
        }
        openReplyComposer(for: taskID)
    }

    private func openReplyComposer(for taskID: String) {
        closeReplyComposer()
        // Read live rather than from whatever the last render cached: a key
        // that closed in between would make `fm-send` refuse the whole send
        // (it validates before typing anything - see `FleetActions.resolveKey`).
        let decisions = FleetActions.openDecisions(taskID: taskID)
        let composer = FleetMessageComposer(
            address: replyAddressLine(taskID: taskID, decisions: decisions),
            caption: replyCaption(decisions: decisions),
            placeholder: "Type your answer\u{2026}",
            sendTitle: "Send")
        composer.onSend = { [weak self] text in self?.sendReply(taskID: taskID, text: text) }
        composer.onCancel = { [weak self] in
            self?.closeReplyComposer()
            self?.refreshNeedsRows()
        }
        composer.applyTheme(currentTheme)
        openReplyTaskID = taskID
        openReplyComposer = composer
        refreshNeedsRows()
        composer.focusInput()
    }

    func closeReplyComposer() {
        openReplyComposer?.removeFromSuperview()
        openReplyComposer = nil
        openReplyTaskID = nil
    }

    /// Re-lay the rows against the tasks currently on screen, without a fetch.
    private func refreshNeedsRows() {
        rebuildNeedsRows(currentNeedsTasks)
        applyThemeFromReply()
    }

    /// "Replying to **task-142** · <the question>", the mockup's own
    /// pre-addressed line, built only from real data: the task id, and the
    /// open decision's own note where there is one.
    private func replyAddressLine(taskID: String, decisions: [FleetDecision]) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: "Replying to ",
            attributes: [.font: HelmType.caption()])
        out.append(NSAttributedString(string: taskID,
                                      attributes: [.font: HelmType.code()]))
        if let note = decisions.last?.note, !note.isEmpty {
            out.append(NSAttributedString(string: " \u{00B7} \(note)",
                                          attributes: [.font: HelmType.caption()]))
        }
        return out
    }

    /// The mockup's caption, plus - only when it is actually true - the fact
    /// that this answer also closes the captain-facing decision record.
    private func replyCaption(decisions: [FleetDecision]) -> String {
        let base = "Sent as a reply into the firstmate session for this crew, same as answering in a terminal."
        switch decisions.count {
        case 1:
            return base + " Closes the open \(decisions[0].verb) \u{201C}\(decisions[0].key)\u{201D}."
        case let n where n > 1:
            // Which of several a given answer settles is genuinely ambiguous,
            // so nothing is closed and the captain is told so rather than
            // having one picked for them.
            return base + " \(n) decisions are open on this task, so none is closed automatically - resolve the right one from the crew's session."
        default:
            return base
        }
    }

    private func sendReply(taskID: String, text: String) {
        guard let composer = openReplyComposer else { return }
        composer.setBusy(true)
        composer.setStatus("Sending\u{2026}", tint: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = FleetActions.reply(taskID: taskID, text: text)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                composer.setBusy(false)
                switch outcome {
                case .confirmed:
                    Toast.show(in: self.view, message: outcome.message)
                    self.closeReplyComposer()
                    self.refreshNeedsRows()
                    // The crew's state has just changed (an answered decision
                    // is closed by `fm-send` itself), so re-read it rather
                    // than leaving a row saying it still needs a call.
                    self.refreshAfterReply()
                case .sentUnconfirmed:
                    // Delivered but unproven: say exactly that, and clear the
                    // box so nothing invites a blind resend - which is the one
                    // thing `fm-send.sh`'s own header warns against here.
                    Toast.show(in: self.view, message: outcome.message)
                    composer.clear()
                    composer.setStatus(outcome.message, tint: .warn)
                case .failed:
                    // Keep the text: a failed send is the case where retyping
                    // it would be pure loss.
                    composer.setStatus(outcome.message, tint: .critical)
                }
            }
        }
    }

}


// MARK: - Probe / self-test surface

// GL-27: debug builds only, so none of this reaches the shipped binary.
// `FleetReplyLayoutSelfTest` needs to render the F7 rows against synthetic
// tasks and drive the real buttons; every hook here is a thin passthrough to
// the production path, never a parallel implementation of it.
#if FM_SELFTESTS
extension FleetController {
    /// Render the needs-your-call section against `tasks`, skipping the fleet
    /// fetch (which would read the captain's real state).
    func debugRenderNeeds(_ tasks: [FleetTask]) {
        currentNeedsTasks = tasks
        rebuildNeedsRows(tasks)
        applyThemeFromReply()
        view.layoutSubtreeIfNeeded()
    }

    var debugNeedsSectionHidden: Bool { needsSectionView.isHidden }
    var debugNeedsRowCount: Int { needsAccentRows.count }
    var debugOpenReplyTaskID: String? { openReplyTaskID }

    /// The real Reply button for `taskID`, found the same way a click finds
    /// it - by walking the rendered stack, not by a cached reference.
    func debugReplyButton(taskID: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.identifier?.rawValue == "fleet.reply.\(taskID)" { return button }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(needsStack)
    }

    /// The composer currently expanded under a row, if any.
    var debugOpenReplyComposerView: FleetMessageComposer? { openReplyComposer }

    /// Whether that composer is genuinely an arranged subview of the rows
    /// stack, immediately after its own row - the mockup's expand-in-place
    /// shape, which a composer merely *held* in a property would not satisfy.
    func debugComposerFollowsItsRow(taskID: String) -> Bool {
        guard let composer = openReplyComposer,
              let composerIndex = needsStack.arrangedSubviews.firstIndex(of: composer),
              composerIndex > 0,
              let row = needsStack.arrangedSubviews[composerIndex - 1] as? HelmAccentRow
        else { return false }
        return debugReplyButton(taskID: taskID).map { $0.isDescendant(of: row) } ?? false
    }
}

extension FleetMessageComposer {
    var debugSendEnabled: Bool { debugSendButton.isEnabled }
    func debugType(_ text: String) {
        debugTextView.string = text
        debugNotifyTextChanged()
    }
}
#endif
