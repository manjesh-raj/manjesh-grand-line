// Grand Line - native macOS app.
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
//
// **Two composers, one path (RP-2).** The sidebar layout's Needs you opens a
// `FleetReplyCard` in the decision row's place: the question in full on a hero
// head, over the prompt well the other composers use. The floating bar's
// dashboard keeps `FleetMessageComposer` under the row, as it was. Both are a
// `FleetReplyInput`, so opening, sending, the three outcomes and closing are
// one code path whichever layout drew the composer.

import AppKit

/// What this file needs from an open reply composer, whichever layout drew it.
protocol FleetReplyInput: NSView {
    var onSend: ((String) -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var text: String { get }
    func focusInput()
    func clear()
    func setBusy(_ busy: Bool)
    func setStatus(_ message: String?, tint: HelmTint?)
    func applyTheme(_ theme: HelmTheme)
}

extension FleetMessageComposer: FleetReplyInput {}
extension FleetReplyCard: FleetReplyInput {}

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

    /// Show the needs-decision/blocked rows. A parked task keeps its row,
    /// and an already-open composer keeps its place under it, so a refresh
    /// landing mid-sentence (Refresh, or simply navigating back to Overview)
    /// never discards what the captain has typed.
    func rebuildNeedsRows(_ tasks: [FleetTask]) {
        needsCountLabel.stringValue = "\(tasks.count)"
        // The section is a list of things needing an answer; with none, the
        // banner directly above already says "nothing needs you right now",
        // so a second empty state under it would be noise (this app's own
        // "quiet until it matters" rule).
        needsSectionView.isHidden = tasks.isEmpty
        if tasks.isEmpty {
            closeReplyComposer()
        }
        // A composer whose task is no longer parked has nothing to answer.
        if let open = openReplyTaskID, !tasks.contains(where: { $0.id == open }) {
            closeReplyComposer()
        }
        // P2: keyed by task id, with the open composer as its own entry right
        // under its task. A task still parked keeps its row - and an open
        // composer keeps whatever the captain has typed into it - across a
        // refresh, rather than every row being rebuilt (`HelmKeyedRows`).
        // RP-2: on Needs you the card takes its row's place instead, so the
        // question shows once.
        var items: [NeedsItem] = []
        for task in tasks {
            guard task.id == openReplyTaskID, let composer = openReplyComposer else {
                items.append(.task(task))
                continue
            }
            if !(composer is FleetReplyCard) { items.append(.task(task)) }
            items.append(.composer(taskID: task.id, view: composer))
        }
        needsRows.reconcile(items, key: \.key, make: { [weak self] item in
            switch item {
            case .task(let task): return self?.needsRowView(task) ?? NSView()
            case .composer(_, let view): return view
            }
        }, update: { [weak self] view, item in
            guard let self, case .task(let task) = item, let row = view as? HelmAccentRow else { return }
            self.configureNeedsRow(row, task)
        })
        needsAccentRows = needsRows.orderedRows.compactMap { $0 as? HelmAccentRow }
        let listed = Set(tasks.map(\.id))
        needsReplyButtons = needsReplyButtons.filter { listed.contains($0.key) }
    }

    enum NeedsItem {
        case task(FleetTask)
        case composer(taskID: String, view: NSView)

        var key: String {
            switch self {
            case .task(let task): return "task:\(task.id)"
            // The task's, and the view's own identity: a composer closed and
            // reopened between two refreshes is a new view, and a key by task
            // alone would hand back the old one.
            case .composer(let taskID, let view): return "composer:\(taskID):\(ObjectIdentifier(view))"
            }
        }
    }

    private func needsRowView(_ task: FleetTask) -> NSView {
        let reply = HelmButton(title: "Reply", variant: .secondary, size: .small,
                               symbol: "arrowshape.turn.up.left")
        reply.identifier = NSUserInterfaceItemIdentifier("fleet.reply.\(task.id)")
        reply.toolTip = "Answer \(task.id) in the crew's own session"
        reply.target = self
        reply.action = #selector(replyTapped(_:))
        reply.setContentHuggingPriority(.required, for: .horizontal)
        reply.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = HelmAccentRow(trailingAccessory: reply, hover: false)
        needsReplyButtons[task.id] = reply
        return row
    }

    /// Configure a "needs you" row for `task` - new or reused - including
    /// its Reply / Cancel button, which follows whether its composer is open.
    private func configureNeedsRow(_ row: HelmAccentRow, _ task: FleetTask) {
        let blocked = ReplyHeroWords.isBlocked(status: task.status)
        if let reply = needsReplyButtons[task.id] {
            let open = openReplyTaskID == task.id
            reply.title = open ? "Cancel" : "Reply"
            reply.symbolName = open ? "xmark" : "arrowshape.turn.up.left"
        }
        row.configure(HelmAccentRow.Content(
            tint: blocked ? .critical : .warn,
            kicker: ReplyHeroWords.kicker(taskID: task.id, blocked: blocked),
            title: task.repo ?? task.id,
            meta: replyRowMeta(task),
            badgeSymbol: ReplyHeroWords.symbol(blocked: blocked),
            chipText: blocked ? "blocked" : "needs you"
        ), theme: currentTheme)
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
        ReplyHeroWords.question(decisions: FleetActions.openDecisions(taskID: task.id),
                                detail: task.detail, source: task.source)
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
        let composer: FleetReplyInput
        if drawsSidebarLayout, let task = currentNeedsTasks.first(where: { $0.id == taskID }) {
            // RP-2: the row's Reply, now its Cancel, rides on the card's head
            // as the ghost × - the same identifier and the same action, so a
            // second press closes it exactly as the row's did.
            let close = HelmButton(symbol: "xmark", variant: .quiet, size: .small)
            close.identifier = NSUserInterfaceItemIdentifier("fleet.reply.\(taskID)")
            close.accessibilityLabelOverride = ReplyHeroWords.cancelTitle
            close.toolTip = ReplyHeroWords.cancelTitle
            close.target = self
            close.action = #selector(replyTapped(_:))
            composer = FleetReplyCard(
                head: ReplyHeroWords.head(taskID: taskID, repo: task.repo, status: task.status,
                                          detail: task.detail, source: task.source, decisions: decisions),
                caption: ReplyHeroWords.caption(decisions: decisions),
                closeButton: close)
        } else {
            composer = FleetMessageComposer(
                address: replyAddressLine(taskID: taskID, decisions: decisions),
                caption: ReplyHeroWords.caption(decisions: decisions),
                placeholder: ReplyHeroWords.placeholder,
                sendTitle: ReplyHeroWords.sendTitle)
        }
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

    private func sendReply(taskID: String, text: String) {
        guard let composer = openReplyComposer else { return }
        composer.setBusy(true)
        composer.setStatus("Sending\u{2026}", tint: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = FleetActions.reply(taskID: taskID, text: text)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                composer.setBusy(false)
                switch outcome {
                case .confirmed:
                    Toast.show(in: self.view, message: outcome.message)
                    // Only if this send's composer is still the open one: the
                    // captain may have opened another task's reply while it
                    // was out, and that one is not answered by this.
                    if self.openReplyComposer === composer {
                        self.closeReplyComposer()
                        self.refreshNeedsRows()
                    }
                    // The crew's state has just changed (an answered decision
                    // is closed by `fm-send` itself), so re-read it rather
                    // than leaving a row saying it still needs a call.
                    self.refreshAfterReply()
                case .sentUnconfirmed:
                    // Delivered but unproven: say exactly that, and clear the
                    // box so nothing invites a blind resend - which is the one
                    // thing `fm-send.sh`'s own header warns against here.
                    Toast.show(in: self.view, message: outcome.message, kind: .warning)
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

    /// The page's real render against a fabricated snapshot, skipping the
    /// fetch - the whole page (banner, stats, needs rows) rather than only the
    /// needs section, so a tour renders what the captain sees.
    func debugRender(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?) {
        debugRendersPinned = true
        debugRenderInProgress = true
        render(snapshot: snapshot, mergedPRs: mergedPRs)
        debugRenderInProgress = false
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

    /// The floating bar's composer currently expanded under a row, if any.
    var debugOpenReplyComposerView: FleetMessageComposer? { openReplyComposer as? FleetMessageComposer }

    /// RP-2: Needs you's card currently open in a row's place, if any.
    var debugOpenReplyCard: FleetReplyCard? { openReplyComposer as? FleetReplyCard }

    /// Whether the open card is genuinely an arranged subview of the rows
    /// stack at `index`, with no row of its own task left anywhere in it -
    /// the row turned into the card, which a card merely *held* in a
    /// property, or one stacked under its row, would not satisfy.
    func debugCardTakesItsRowsPlace(taskID: String, at index: Int) -> Bool {
        guard let card = openReplyComposer as? FleetReplyCard,
              needsStack.arrangedSubviews.firstIndex(of: card) == index else { return false }
        // A row of this task would carry a Reply button with its identifier.
        func carriesReply(_ view: NSView) -> Bool {
            if (view as? NSButton)?.identifier?.rawValue == "fleet.reply.\(taskID)" { return true }
            return view.subviews.contains(where: carriesReply)
        }
        return !needsStack.arrangedSubviews.contains { $0 is HelmAccentRow && carriesReply($0) }
    }

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
