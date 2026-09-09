// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates phase 1: Overview's "Crew" tab.
//
// Split out of `FleetController.swift` for the reason GL-36 split
// `ConsoleController` into six files - that one is already ~1100 lines and
// carries four unrelated features (the fleet dashboard, F6's log, F7's reply
// composers, F12's morning briefing). The Swift consequence is the same one
// GL-36 documents: `private` is file-scoped, so the members this file reaches
// are `internal` on the core type. Treat the `FleetController*.swift` family
// as private to itself.
//
// What lives here: the tab's view tree, the height derivation that lets a
// chat pane sit inside a scrolling page without nesting two scrollers, and
// the turn cycle (append the captain's message, show a status line, ask
// `StrawHatRunner`, replace the status with the reply). What does not: the
// persona (`StrawHatCrew`), the `claude` plumbing (`StrawHatRunner`), and the
// rendering (`StrawHatChatView`).

import AppKit

extension FleetController {

    /// The smallest the chat is ever allowed to be, if the window is short
    /// enough that the derived height would go below it. Below this the
    /// transcript shows less than one exchange and the pane reads as broken;
    /// at this size the page's own scroll view takes over, which is the
    /// correct degradation.
    static var crewChatMinHeight: CGFloat { HelmType.scaledRowHeight(320) }

    /// This page's own `DocsRunbookStore`, for Robin's half of the context
    /// snapshot and for a confirmed runbook draft.
    ///
    /// A per-page instance rather than a shared one, which is the established
    /// convention for *this* store specifically: it is uncached (every call
    /// re-reads its folder), so two instances cannot diverge the way two
    /// `CommandLibraryStore`s once did - and `RunbooksController`,
    /// `PostmortemsController`, `LogAnalyzerController` and
    /// `CommandLibraryPageView` each already hold their own.
    ///
    /// Built lazily so a captain who never opens the Crew tab never pays for
    /// it, and so the store's own `init` (which can reach `ShiftGitSync` when
    /// no override is set) is not run at page construction. `FM_SHIFT_DIR`
    /// and `FM_DOCS_RUNBOOKS_DIR` both redirect it, and `main.swift`'s
    /// self-test block sets both.
    var crewDocsStore: DocsRunbookStore {
        if let existing = crewDocs { return existing }
        let store = DocsRunbookStore()
        crewDocs = store
        return store
    }

    // MARK: Building

    func buildCrewSection() -> NSView {
        let title = NSTextField(labelWithString: "Straw Hat Pirates")
        title.font = HelmType.sectionTitle()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crewTitleLabel = title

        let subtitle = NSTextField(labelWithString: "Luffy, Nami, Chopper and Robin \u{00B7} every write is yours to confirm")
        subtitle.font = HelmType.captionSmall()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crewSubtitleLabel = subtitle

        let titleColumn = NSStackView(views: [title, subtitle])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2
        titleColumn.translatesAutoresizingMaskIntoConstraints = false

        crewNewButton.target = self
        crewNewButton.action = #selector(newCrewConversationTapped)
        crewNewButton.isEnabled = false
        crewNewButton.toolTip = "Start a new conversation - the crew forgets what was said before"
        crewNewButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        crewNewButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // A bare `NSView` has no intrinsic content size, so a hugging priority
        // on it is a no-op (AGENTS.md gotcha (12)) - holding it collapsed
        // needs a real `width == 0` constraint below stay-put.
        let collapse = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapse.priority = NSLayoutConstraint.Priority(499)
        collapse.isActive = true

        let headerRow = NSStackView(views: [titleColumn, spacer, crewNewButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        // `.fill`, never the `.gravityAreas` default: under that default
        // nothing defines who absorbs the row's slack, so the button drifts
        // (AGENTS.md gotcha (10)).
        headerRow.distribution = .fill
        headerRow.spacing = HelmMetrics.s2
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        crewChat.translatesAutoresizingMaskIntoConstraints = false
        crewChat.wantsLayer = true
        crewChat.layer?.cornerRadius = HelmMetrics.rCard
        crewChat.layer?.masksToBounds = true
        crewChat.layer?.borderWidth = 1
        crewChat.onSubmit = { [weak self] text in self?.sendToCrew(text) }
        // The single path from a proposal to a store. Set once here so there
        // is one wiring to audit rather than one per rendered card.
        crewChat.onConfirmProposal = { [weak self] proposal in
            guard let self else {
                return .failed(message: "This page went away before that could be saved.")
            }
            return self.confirmCrewProposal(proposal)
        }
        crewChat.onMessagesChanged = { [weak self] in
            guard let self else { return }
            self.crewNewButton.isEnabled = self.crewChat.hasRealExchange && !self.crewTurnInFlight
        }

        crewContainer.orientation = .vertical
        crewContainer.alignment = .leading
        crewContainer.spacing = HelmMetrics.s3
        crewContainer.translatesAutoresizingMaskIntoConstraints = false
        crewContainer.addArrangedSubview(headerRow)
        crewContainer.addArrangedSubview(crewChat)

        crewChatHeight = crewChat.heightAnchor.constraint(equalToConstant: Self.crewChatMinHeight)
        // Below `NSLayoutPriorityWindowSizeStayPut` (500) so this page can
        // never drive the window's own size - the recurring gotcha (13)/(14)
        // failure this codebase has shipped five separate routes to.
        crewChatHeight.priority = NSLayoutConstraint.Priority(499)

        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: crewContainer.widthAnchor),
            crewChat.widthAnchor.constraint(equalTo: crewContainer.widthAnchor),
            crewChatHeight,
        ])
        return crewContainer
    }

    // MARK: Height
    //
    // A chat pane owns its own scroller; this page owns another. Nesting them
    // is the annoyance where the wheel is captured by whichever one the
    // pointer happens to be over. The fix is to make the outer one have
    // nothing to scroll while this tab is showing: give the chat exactly the
    // height left over in the viewport, so the document's total height equals
    // the viewport's and the outer scroller never engages.
    //
    // Derived from the chat's own laid-out origin rather than by adding up
    // the header/tab-strip/inset constants, so it cannot drift when any of
    // those change. It converges because the chat is the last thing in the
    // stack: changing its height cannot move its own top edge.

    func updateCrewChatHeight() {
        guard crewChatHeight != nil, !crewContainer.isHidden else { return }
        guard let document = crewScrollDocumentView else { return }
        let viewportHeight = crewScrollViewportHeight
        guard viewportHeight > 0 else { return }

        let topInDocument = document.convert(crewChat.bounds, from: crewChat).minY
        let available = viewportHeight - topInDocument - crewDocumentBottomInset
        let target = max(Self.crewChatMinHeight, available)
        // Epsilon guard: assigning a constraint constant from a layout pass
        // re-triggers layout, and without this the two would ping-pong on
        // sub-point differences forever.
        guard abs(target - crewChatHeight.constant) > 0.5 else { return }
        crewChatHeight.constant = target
    }

    // MARK: The turn cycle

    @objc func newCrewConversationTapped() {
        crewRunner?.reset()
        crewTurnInFlight = false
        crewChat.clearMessages()
        crewChat.setInputEnabled(true)
        crewNewButton.isEnabled = false
        crewChat.focusComposer()
    }

    /// One turn: the captain's message, a status line while `claude` runs, then
    /// the reply's sections in its place.
    ///
    /// The composer is disabled for the whole turn - `StrawHatRunner` is not
    /// built for concurrent `ask` calls and says so, the same contract
    /// `SRELeadChatView` enforces for SRE Lead.
    func sendToCrew(_ text: String) {
        guard !crewTurnInFlight else { return }

        crewChat.append(.captain(text))

        if crewRunner == nil { crewRunner = StrawHatRunner() }
        guard let runner = crewRunner else {
            // Not a crash and not a silent no-op: the one thing this feature
            // needs that the app cannot install for the captain.
            crewChat.append(.error("I can't find the `claude` command on this Mac. Install Claude Code and sign in, then try again \u{2014} Grand Line uses your own CLI login, so there's no API key to set up."))
            return
        }

        crewTurnInFlight = true
        crewChat.setInputEnabled(false)
        crewNewButton.isEnabled = false
        crewChat.append(.status("The crew is thinking\u{2026}"))

        // M2.3: captured here, fresh, once per turn - not inside the runner
        // (which owns `claude` and should not reach into stores) and not
        // cached (a snapshot from three turns ago would tell the crew a task
        // is due that the captain has since completed).
        let context = StrawHatContextSnapshot.capture(shift: crewShiftStore, docs: crewDocsStore)

        runner.ask(text, context: context) { [weak self] result in
            guard let self else { return }
            self.crewTurnInFlight = false
            self.crewChat.removeTrailingStatus()
            switch result {
            case .success(let reply):
                self.renderCrewReply(reply)
            case .failure(let error):
                AppLog.ai.error("straw hat: turn failed: \(error.message, privacy: .public)")
                self.crewChat.append(.error(error.message))
            }
            self.crewChat.setInputEnabled(true)
            self.crewNewButton.isEnabled = self.crewChat.hasRealExchange
        }
    }

    /// M2.1's three rungs, at their one call site.
    ///
    /// The rungs themselves are `StrawHatEnvelope.parse`'s; all this does is
    /// append what came back. Note there is **no** failure branch: the parser
    /// cannot fail, by design - rung 3 renders the reply verbatim as one Luffy
    /// block, which is exactly phase 1's behaviour. That is what makes a model
    /// that stops emitting the envelope a cosmetic regression rather than a
    /// chat that silently stops answering.
    private func renderCrewReply(_ reply: String) {
        switch StrawHatEnvelope.parse(reply) {
        case .envelope(let sections):
            for section in sections {
                crewChat.append(.crew(section))
            }
        case .plain(let text):
            crewChat.append(.crew(.text(StrawHatCrew.speaker, text)))
        }
    }

    /// M2.2: the captain pressed a confirm card's button.
    ///
    /// The write itself is `StrawHatProposalExecutor`'s; this owns only the
    /// stores it hands over and the feedback afterwards. Wired to the chat view
    /// once, in `buildCrewSection` - so there is exactly one path from a
    /// proposal to a store, and it starts at a real button press.
    func confirmCrewProposal(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        let outcome = StrawHatProposalExecutor.execute(proposal,
                                                       shift: crewShiftStore,
                                                       docs: crewDocsStore)
        switch outcome {
        case .written(let message, let undo):
            // GL-33 / the house convention: a toast for a transient
            // confirmation, and `showUndo` only where the undo genuinely
            // restores. Two of the three kinds have no undo, and
            // `StrawHatProposalExecutor`'s header records why (`ShiftStore` has
            // no delete for a task or a follow-up, so an "Undo" there could
            // only pretend). The card's own confirmed state names where the
            // record went either way.
            if let undo {
                Toast.showUndo(in: view, message: message, onUndo: undo)
            } else {
                Toast.show(in: view, message: message)
            }
        case .failed(let message):
            AppLog.ai.error("straw hat: a confirmed proposal failed: \(message, privacy: .public)")
            Toast.show(in: view, message: message)
        }
        return outcome
    }

    // MARK: Lifecycle

    /// Called from `switchTab` when the Crew tab becomes / stops being the
    /// visible one.
    func crewTabDidChangeVisibility(showing: Bool) {
        crewContainer.isHidden = !showing
        guard showing else { return }
        view.layoutSubtreeIfNeeded()
        updateCrewChatHeight()
        crewChat.focusComposer()
    }

    /// GL-13: a turn in flight when the page goes away would render into a
    /// pane nobody is looking at, and its `claude` process would keep running.
    func shutdownCrew() {
        crewRunner?.cancel()
        crewTurnInFlight = false
    }

    func applyThemeToCrew(_ theme: HelmTheme) {
        crewTitleLabel?.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        crewSubtitleLabel?.textColor = HelmTheme.mutedInk(theme)
        crewChat.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        crewChat.applyTheme(theme)
        // `crewNewButton` is a `HelmButton` and themes itself - never set
        // `contentTintColor`/`attributedTitle` on one, `restyle()` owns them.
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugCrewTabHidden: Bool { crewContainer.isHidden }
    var debugCrewChat: StrawHatChatView { crewChat }
    var debugCrewChatHeight: CGFloat { crewChatHeight?.constant ?? 0 }
    var debugCrewNewButton: HelmButton { crewNewButton }
    var debugCrewTurnInFlight: Bool { crewTurnInFlight }
    /// Renders a raw reply through the real three-rung path, so a suite can
    /// drive rung 2 and rung 3 without a fake `claude` able to produce them.
    func debugRenderCrewReply(_ reply: String) { renderCrewReply(reply) }
    /// Confirms a proposal through the real executor + toast path.
    func debugConfirmCrewProposal(_ proposal: StrawHatProposal) -> StrawHatProposalOutcome {
        confirmCrewProposal(proposal)
    }
    var debugCrewContext: StrawHatContextSnapshot {
        StrawHatContextSnapshot.capture(shift: crewShiftStore, docs: crewDocsStore)
    }
    /// Selects a tab through the same method a real pill click reaches.
    func debugSelectTab(_ id: String) { debugSwitchTab(id) }
    #endif
}
