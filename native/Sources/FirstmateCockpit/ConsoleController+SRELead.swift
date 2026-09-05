// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition, and the single largest
// piece of it: the SRE Lead pane. Per-tab investigation state
// (`SRELeadTabState` on `TabModel`), the shared slide-open pane and its empty
// state, the concurrency cap, the chat wiring, postmortem generation, and the
// carded-terminal treatment the pane's presence switches on.
//
// The report's own framing (section 6) was that this is one of seven
// separable features living inside a 2,300-line object. It is separable in
// the sense that matters - nothing outside this file needs to know how any of
// it works - while still needing the current tab, the toolbar's status
// control and the terminal card's geometry, which is why it is an extension
// on the controller rather than a free-standing coordinator: a coordinator
// would need all three handed to it and would buy nothing beyond the file
// boundary this already gives.
//
// Split out verbatim; no statement here changed in the move. See
// `ConsoleController.swift`'s header.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: SRE Lead (`fm/grandline-sre-lead-per-tab`: per-tab state on
    // `TabModel.sreLead` - see `SRELeadTabState.swift`'s header. This
    // section owns only the shared chrome: the pill, the pane, the header,
    // and the empty state - every method below operates on a specific
    // `TabModel`, never a page-level phase.

    func buildSRELeadPane() {
        sreLeadPane.translatesAutoresizingMaskIntoConstraints = false
        sreLeadPane.wantsLayer = true
        sreLeadPane.clipsToBounds = true

        sreLeadCard.translatesAutoresizingMaskIntoConstraints = false
        sreLeadCard.wantsLayer = true
        // The card clips, which is what gives every child below rounded
        // corners for free. A layer that masks cannot also cast a shadow, so
        // this card's elevation is drawn by `cardChrome` underneath instead -
        // see `ConsoleCardChrome.paneCardRect`.
        sreLeadCard.clipsToBounds = true
        sreLeadPane.addSubview(sreLeadCard)

        sreLeadHeader.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeader.wantsLayer = true
        sreLeadCard.addSubview(sreLeadHeader)

        sreLeadHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeaderDivider.wantsLayer = true
        sreLeadCard.addSubview(sreLeadHeaderDivider)

        sreLeadHeaderIcon.configure(symbol: "sparkles", tint: .accent, pointSize: 12)
        sreLeadHeader.addSubview(sreLeadHeaderIcon)

        sreLeadHeaderLabel.font = HelmType.rowTitle()
        sreLeadHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeaderLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        sreLeadHeader.addSubview(sreLeadHeaderLabel)

        sreLeadHeader.addSubview(sreLeadStatusPill)

        sreLeadGeneratePostmortemButton.translatesAutoresizingMaskIntoConstraints = false
        sreLeadGeneratePostmortemButton.title = ""
        sreLeadGeneratePostmortemButton.isBordered = false
        sreLeadGeneratePostmortemButton.wantsLayer = true
        sreLeadGeneratePostmortemButton.toolTip = "Generate Postmortem"
        sreLeadGeneratePostmortemButton.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Generate Postmortem")
        sreLeadGeneratePostmortemButton.imageScaling = .scaleProportionallyDown
        sreLeadGeneratePostmortemButton.target = self
        sreLeadGeneratePostmortemButton.action = #selector(generatePostmortemClicked)
        sreLeadGeneratePostmortemButton.isHidden = true
        sreLeadHeader.addSubview(sreLeadGeneratePostmortemButton)

        NSLayoutConstraint.activate([
            // The card fills the backdrop apart from the workspace padding.
            // Its leading edge sits flush with the backdrop's, so the gap
            // between the two panels is entirely the terminal card's own
            // trailing inset (`ConsoleCardChrome.terminalCardRect`) - one
            // `HelmMetrics.s3` gap, not two stacked halves of one.
            sreLeadCard.leadingAnchor.constraint(equalTo: sreLeadPane.leadingAnchor),
            sreLeadCard.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor, constant: -HelmMetrics.s3),
            sreLeadCard.topAnchor.constraint(equalTo: sreLeadPane.topAnchor, constant: HelmMetrics.s3),
            sreLeadCard.bottomAnchor.constraint(equalTo: sreLeadPane.bottomAnchor, constant: -HelmMetrics.s3),

            sreLeadHeader.leadingAnchor.constraint(equalTo: sreLeadCard.leadingAnchor),
            sreLeadHeader.trailingAnchor.constraint(equalTo: sreLeadCard.trailingAnchor),
            sreLeadHeader.topAnchor.constraint(equalTo: sreLeadCard.topAnchor),
            sreLeadHeader.heightAnchor.constraint(equalToConstant: 46),

            sreLeadHeaderDivider.leadingAnchor.constraint(equalTo: sreLeadCard.leadingAnchor),
            sreLeadHeaderDivider.trailingAnchor.constraint(equalTo: sreLeadCard.trailingAnchor),
            sreLeadHeaderDivider.topAnchor.constraint(equalTo: sreLeadHeader.bottomAnchor),
            sreLeadHeaderDivider.heightAnchor.constraint(equalToConstant: 1),

            sreLeadHeaderIcon.leadingAnchor.constraint(equalTo: sreLeadHeader.leadingAnchor, constant: HelmMetrics.s3),
            sreLeadHeaderIcon.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),

            sreLeadHeaderLabel.leadingAnchor.constraint(equalTo: sreLeadHeaderIcon.trailingAnchor, constant: HelmMetrics.s2),
            sreLeadHeaderLabel.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),

            sreLeadStatusPill.leadingAnchor.constraint(greaterThanOrEqualTo: sreLeadHeaderLabel.trailingAnchor, constant: HelmMetrics.s2),
            sreLeadStatusPill.trailingAnchor.constraint(equalTo: sreLeadGeneratePostmortemButton.leadingAnchor, constant: -HelmMetrics.s2),
            sreLeadStatusPill.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),

            sreLeadGeneratePostmortemButton.trailingAnchor.constraint(equalTo: sreLeadHeader.trailingAnchor, constant: -HelmMetrics.s3),
            sreLeadGeneratePostmortemButton.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),
            sreLeadGeneratePostmortemButton.widthAnchor.constraint(equalToConstant: 22),
            sreLeadGeneratePostmortemButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        buildSRELeadEmptyState()
    }

    func buildSRELeadEmptyState() {
        sreLeadEmptyStateView.translatesAutoresizingMaskIntoConstraints = false
        sreLeadEmptyStateView.wantsLayer = true
        sreLeadEmptyStateView.isHidden = true
        sreLeadCard.addSubview(sreLeadEmptyStateView)

        sreLeadEmptyStateLabel.font = .systemFont(ofSize: 12)
        sreLeadEmptyStateLabel.alignment = .center
        sreLeadEmptyStateLabel.lineBreakMode = .byWordWrapping
        sreLeadEmptyStateLabel.maximumNumberOfLines = 0
        sreLeadEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        sreLeadEmptyStateView.addSubview(sreLeadEmptyStateLabel)

        sreLeadEmptyStateButton.title = "Start SRE Lead for This Tab"
        sreLeadEmptyStateButton.controlSize = .small
        sreLeadEmptyStateButton.target = self
        sreLeadEmptyStateButton.action = #selector(startSRELeadForCurrentTabClicked)
        sreLeadEmptyStateButton.translatesAutoresizingMaskIntoConstraints = false
        sreLeadEmptyStateView.addSubview(sreLeadEmptyStateButton)

        NSLayoutConstraint.activate([
            sreLeadEmptyStateView.leadingAnchor.constraint(equalTo: sreLeadCard.leadingAnchor),
            sreLeadEmptyStateView.trailingAnchor.constraint(equalTo: sreLeadCard.trailingAnchor),
            sreLeadEmptyStateView.topAnchor.constraint(equalTo: sreLeadHeaderDivider.bottomAnchor),
            sreLeadEmptyStateView.bottomAnchor.constraint(equalTo: sreLeadCard.bottomAnchor),

            sreLeadEmptyStateLabel.leadingAnchor.constraint(equalTo: sreLeadEmptyStateView.leadingAnchor, constant: 20),
            sreLeadEmptyStateLabel.trailingAnchor.constraint(equalTo: sreLeadEmptyStateView.trailingAnchor, constant: -20),
            sreLeadEmptyStateLabel.centerYAnchor.constraint(equalTo: sreLeadEmptyStateView.centerYAnchor, constant: -16),

            sreLeadEmptyStateButton.centerXAnchor.constraint(equalTo: sreLeadEmptyStateView.centerXAnchor),
            sreLeadEmptyStateButton.topAnchor.constraint(equalTo: sreLeadEmptyStateLabel.bottomAnchor, constant: 12),
        ])
    }

    /// How many tabs on this page currently have SRE Lead actively running
    /// (`.starting` or `.ready` - not `.notStarted`/`.failed`, neither of
    /// which holds a live bridge/process). Backs the 5-tab cap.
    func activeSRELeadTabCount() -> Int {
        tabs.reduce(into: 0) { count, tab in
            switch tab.sreLead?.phase {
            case .some(.starting), .some(.ready): count += 1
            default: break
            }
        }
    }

    /// The toolbar pill's click action - operates on `currentTab`, never a
    /// page-level phase (`fm/grandline-sre-lead-per-tab`). Dedups exactly
    /// like `connectSSHIfNeeded`'s `tabs.isEmpty` guard dedups a host
    /// reconnect: a click while a spawn is already in flight (`.starting`)
    /// is ignored rather than racing a second `SRELead.setUp` for this tab.
    @objc func toggleSRELead() {
        guard let tab = currentTab else { return }
        switch tab.sreLead?.phase ?? .notStarted {
        case .starting:
            return
        case .ready:
            tearDownSRELead(for: tab)
        case .notStarted, .failed:
            startSRELead(for: tab)
        }
    }

    /// The pane's own empty-state "Start SRE Lead for This Tab" button -
    /// the second entry point into `startSRELead(for:)` alongside the
    /// toolbar pill, so a captain who switches to a not-yet-started tab
    /// while the pane is already open (showing another tab's transcript)
    /// doesn't have to reach for the toolbar.
    @objc func startSRELeadForCurrentTabClicked() {
        guard let tab = currentTab, (tab.sreLead?.phase ?? .notStarted) != .starting else { return }
        startSRELead(for: tab)
    }

    /// Starts a brand-new, fully independent SRE Lead investigation for
    /// `tab` - its own `SRELeadSession`/`SRELeadBridge` (bridge target is
    /// `tab` itself, never any other tab's terminal) /`SRELeadRunner`, and
    /// its own chat view. Refuses to start a 6th concurrent session on this
    /// page (`sreLeadMaxConcurrent`) with a clear alert rather than silently
    /// queuing or silently refusing.
    func startSRELead(for tab: TabModel) {
        if activeSRELeadTabCount() >= sreLeadMaxConcurrent {
            showSRELeadCapReachedAlert()
            return
        }

        let state = tab.sreLead ?? SRELeadTabState()
        tab.sreLead = state

        guard let claude = SRELead.resolveClaude() else {
            state.phase = .failed
            updateSRELeadControls()
            showSRELeadError("claude CLI not found on PATH.", in: tab)
            return
        }

        state.phase = .starting
        updateSRELeadControls()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak tab] in
            let result = SRELead.setUp()
            DispatchQueue.main.async {
                guard let self, let tab, let state = tab.sreLead else { return }
                switch result {
                case .success(let session):
                    state.session = session
                    state.bridge = SRELeadBridge(bridgeDir: session.bridgeDir, target: tab)
                    // `fm/grandline-k8s-context-badge`: refuse rather than
                    // collide with the context/namespace badge's own
                    // in-flight command on this same tab - see
                    // `SRELeadBridge.isTerminalBusyElsewhere`'s doc comment.
                    state.bridge?.isTerminalBusyElsewhere = { [weak self, weak tab] in
                        guard let self, let tab else { return false }
                        return self.isTabBusy(tab.id, excluding: .sreLead)
                    }
                    // F8: a runbook that runs through this tab's bridge
                    // attaches itself to an active incident on this host. The
                    // bridge only *observes* the run - see its
                    // `onRunbookRun` doc comment.
                    state.bridge?.onRunbookRun = { [weak self] event in
                        self?.noteRunbookRun(name: event.name, ran: event.ran, total: event.total,
                                             ok: event.ok, refused: event.refused)
                    }
                    state.bridge?.start()
                    state.runner = SRELeadRunner(session: session, claude: claude)
                    let chat = state.chatView ?? self.makeSRELeadChat(for: tab)
                    state.chatView = chat
                    chat.clearMessages()
                    chat.append(SRELeadMessage(role: .status, text: "SRE Lead is ready. Ask a question about this cluster below."))
                    chat.setInputEnabled(true)
                    state.phase = .ready
                    self.updateSRELeadControls()
                case .failure(let error):
                    state.phase = .failed
                    self.updateSRELeadControls()
                    self.showSRELeadError(error.message, in: tab)
                }
            }
        }
    }

    /// The chat view's input submits here - the native equivalent of the
    /// old tmux pane's "just type into the terminal" entry point, now with a
    /// real input field instead of the captain having to click into a raw
    /// `claude` TUI first. Scoped to `tab`'s own runner/chat, so two tabs'
    /// turns can never cross-talk.
    func handleSRELeadSubmit(_ text: String, in tab: TabModel) {
        guard let state = tab.sreLead, let runner = state.runner, let chat = state.chatView else { return }
        chat.append(SRELeadMessage(role: .user, text: text))
        chat.setInputEnabled(false)
        runner.ask(text) { [weak self, weak chat, weak tab] result in
            guard let chat else { return }
            switch result {
            case .success(let reply):
                chat.append(SRELeadMessage(role: .assistant, text: reply))
                // F8 (incident mode): a completed turn is one of the three
                // things that attach themselves to an active incident on this
                // host. Only ever a real reply - a failed turn is an error in
                // this tab's own chat, not something that happened to the
                // cluster - and a no-op when no incident is running.
                if let self, let tab { self.noteSRELeadTurn(question: text, tab: tab) }
                // fm/grandline-notification-center (#7): a reply that lands
                // while this tab isn't the one on screen (a different tab
                // selected, or this whole host page hidden) is exactly the
                // "SRE Lead answered on a tab you're not looking at" signal
                // - a reply landing on the tab the captain is already
                // watching needs no notification at all.
                if let self, let tab, tab !== self.currentTab || self.view.isHidden {
                    self.onSRELeadReplyWhileBackground?(tab)
                }
            case .failure(let error):
                chat.append(SRELeadMessage(role: .error, text: error.message))
            }
            chat.setInputEnabled(true)
            // Only steal first responder back if the captain is still
            // looking at this same tab - a reply landing for a background
            // tab must never yank focus away from whatever is on screen.
            guard let self, let tab, tab === self.currentTab,
                  let window = self.view.window, window.firstResponder !== chat else { return }
            window.makeFirstResponder(chat)
        }
    }

    func showSRELeadError(_ message: String, in tab: TabModel) {
        let state = tab.sreLead ?? SRELeadTabState()
        tab.sreLead = state
        let chat = state.chatView ?? makeSRELeadChat(for: tab)
        state.chatView = chat
        chat.append(SRELeadMessage(role: .error, text: message))
        if tab === currentTab { updateSRELeadPaneContent() }
    }

    /// One alert for the 5-tab cap (task brief: "a clear, non-crashing
    /// message telling the captain to stop one of the other 5 first, rather
    /// than silently queuing or silently refusing").
    func showSRELeadCapReachedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "SRE Lead limit reached"
        alert.informativeText = "Up to \(sreLeadMaxConcurrent) tabs on this host page can run SRE Lead at the same time. Stop SRE Lead on another tab before starting a new one."
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Refreshes the toolbar button, the pane's visible content, the Generate
    /// Postmortem button, and the button's tooltip - all four always derived
    /// from `currentTab`, called from every place that changes which tab is
    /// selected or changes that tab's own SRE Lead phase.
    ///
    /// No `applyTheme` call for the button any more: a `HelmButton` owns its
    /// own `ThemeManager` observation and re-derives every colour itself, and
    /// `tint` is a `HelmTint` case rather than a resolved hex, so the phase's
    /// colour follows a theme change with nothing to push.
    func updateSRELeadControls() {
        guard let tab = currentTab else { return }
        let phase = tab.sreLead?.phase ?? .notStarted
        sreLeadButton?.title = phase.text
        sreLeadButton?.symbolName = phase.symbol
        sreLeadButton?.tint = phase.tint
        updateSRELeadPaneContent()
        updateGeneratePostmortemButton()
        updateSRELeadButtonTooltip(for: tab)
    }

    /// Explains the button's disabled-in-spirit cap state up front, rather
    /// than only after an attempt bounces off the alert above.
    func updateSRELeadButtonTooltip(for tab: TabModel) {
        let phase = tab.sreLead?.phase ?? .notStarted
        if (phase == .notStarted || phase == .failed), activeSRELeadTabCount() >= sreLeadMaxConcurrent {
            sreLeadButton?.toolTip = "SRE Lead limit reached (\(sreLeadMaxConcurrent) tabs) - stop SRE Lead on another tab first."
        } else {
            sreLeadButton?.toolTip = "Toggle the SRE Lead investigation pane"
        }
    }

    /// Shows whichever tab is currently selected inside `sreLeadPane`: its
    /// own chat (started/starting/failed-with-error) if it has one, or the
    /// shared empty state otherwise - never another tab's chat. Every other
    /// tab's chat is hidden, the same "hide, don't rebuild" convention this
    /// app uses everywhere else.
    ///
    /// This is also the single place that decides whether the pane is open
    /// at all: it tracks the *currently selected* tab's own `sreLead` state,
    /// not "does any tab on this page have SRE Lead state" - a fresh or
    /// duplicated tab with no `sreLead` state must show a fully closed pane
    /// (no pane, not even the empty state), regardless of what a sibling tab
    /// is doing. Called from every place that changes which tab is selected
    /// or changes that tab's own SRE Lead phase (`updateSRELeadControls`),
    /// plus directly wherever a tab's own state changes without also
    /// touching the currently-selected tab's controls.
    func updateSRELeadPaneContent() {
        guard let current = currentTab else {
            sreLeadEmptyStateView.isHidden = true
            setSRELeadPaneOpen(false)
            return
        }
        for tab in tabs {
            tab.sreLead?.chatView?.isHidden = (tab !== current)
        }
        sreLeadEmptyStateView.isHidden = (current.sreLead?.chatView != nil)
        updateSRELeadStatusPill(phase: current.sreLead?.phase ?? .notStarted)
        setSRELeadPaneOpen(current.sreLead != nil)
    }

    /// The panel header's phase chip. `.notStarted` never renders - the panel
    /// is only ever visible for a tab that has SRE Lead state at all, so
    /// there is no state where "not started" is the honest label for what the
    /// captain is looking at.
    func updateSRELeadStatusPill(phase: SRELeadPhase) {
        let text: String
        switch phase {
        case .notStarted: text = ""
        case .starting: text = "Starting\u{2026}"
        case .ready: text = "Ready"
        case .failed: text = "Failed"
        }
        sreLeadStatusPill.isHidden = text.isEmpty
        guard !text.isEmpty else { return }
        ToolRowLayout.pill(text: text.uppercased(),
                           colorHex: (phase.tint ?? .neutral).hex(in: theme),
                           into: sreLeadStatusPill,
                           label: sreLeadStatusLabel,
                           theme: theme)
    }

    /// Turns the bordered-terminal-card look on - one condition, evaluated in
    /// one place, for the one thing it decides.
    ///
    /// Two reasons the card shows. The pane being up is the original one
    /// (`fm/grandline-sre-lead-app-feel`). Daylight §6.13 is the second: that
    /// palette's page ground is warm `paper`, so a terminal with no card has
    /// no boundary at all, and the spec asks for the card permanently there.
    /// `terminalInset > 0` is what keeps the shared Firstmate console out of
    /// it in every palette - it has no margin for a card to live in, by
    /// design, so its own Shell tab stays flush at full column count.
    ///
    /// This is deliberately **not** a frame change: `terminalInset` is already
    /// permanent, so all that happens here is that a decorative overlay
    /// becomes visible and repaints (`ConsoleCardChrome.swift`'s header). No
    /// `TerminalView` is touched, which is what keeps a captain's scrollback
    /// intact across a toggle - covered by `SRELeadPerTabSelfTest`'s
    /// `scrollbackSurvivesSRELeadToggle` case. That stays true of the theme
    /// switch this now also reacts to, for exactly the same reason.
    func updateTerminalCardStyle(carded: Bool) {
        sreLeadPaneIsOpen = carded
        refreshTerminalCardChrome()
    }

    /// Re-evaluates the card's visibility and geometry from the state already
    /// recorded, so a theme change can reach it without pretending to know
    /// whether a pane is open.
    func refreshTerminalCardChrome() {
        cardChrome.pad = cardMargin
        cardChrome.paneStripWidth = sreLeadPaneIsOpen ? sreLeadPaneWidth : nil
        cardChrome.isHidden = !(sreLeadPaneIsOpen || (theme.isDaylight && terminalInset > 0))
        cardChrome.needsDisplay = true
    }

    /// The pane header's "Generate Postmortem" button is only ever shown
    /// once the *current* tab's chat has a real assistant reply to
    /// summarize (`SRELeadChatView.hasRealExchange`) - wired to fire on
    /// every `append`/`clearMessages` via `chat.onMessagesChanged` (see
    /// `makeSRELeadChat`), and called directly after `startSRELead`'s own
    /// session-open/session-fail transitions since those don't append
    /// through the normal submit path.
    func updateGeneratePostmortemButton() {
        sreLeadGeneratePostmortemButton.isHidden = !(currentTab?.sreLead?.chatView?.hasRealExchange ?? false)
    }

    /// "Generate Postmortem": summarizes the *current* tab's own
    /// investigation transcript into a structured markdown document via one
    /// non-interactive `claude -p` call (`SRELeadPostmortem.generate`), then
    /// saves it into the same `DocsRunbookStore` postmortems store phase 1
    /// built (`DocsRunbookStore.createPostmortem`) - browsable at the
    /// standalone Postmortems destination (`fm/grandline-docs-split-
    /// runbooks-postmortems`), not a Docs tab any more. A failure here only ever
    /// appends an error message to that tab's own chat feed - the
    /// investigation transcript itself is never touched, so the captain can
    /// retry with nothing lost.
    @objc func generatePostmortemClicked() {
        guard let tab = currentTab, let chat = tab.sreLead?.chatView, chat.hasRealExchange,
              sreLeadGeneratePostmortemButton.isEnabled else { return }
        let transcript = chat.transcriptForPostmortem
        let hostLabel = tab.name

        sreLeadGeneratePostmortemButton.isEnabled = false
        chat.append(SRELeadMessage(role: .status, text: "Generating postmortem\u{2026}"))

        SRELeadPostmortem.generate(hostLabel: hostLabel, transcript: transcript) { [weak self, weak chat] result in
            guard let self, let chat else { return }
            self.sreLeadGeneratePostmortemButton.isEnabled = true
            switch result {
            case .success(let markdown):
                let title = DocsRunbookStore.titleFromContent(markdown, fallback: "Postmortem - \(hostLabel)")
                let saved = self.docsRunbookStore.createPostmortem(title: title, content: markdown)
                chat.append(SRELeadMessage(role: .status, text: "Postmortem saved: \u{201C}\(saved.title)\u{201D} - see Postmortems."))
            case .failure(let error):
                chat.append(SRELeadMessage(role: .error, text: "Couldn't generate the postmortem: \(error.message). You can try again."))
            }
        }
    }

    /// Tears down `tab`'s own SRE Lead session (bridge, in-flight `claude`
    /// process, scratch dir) and removes its chat - never another tab's.
    /// Called from the pill's toggle-off click and, unconditionally, from
    /// `closeTab` for whichever tab is being closed. Whether the shared pane
    /// ends up open or closed is decided entirely by `updateSRELeadControls`/
    /// `updateSRELeadPaneContent` off the *currently selected* tab's own
    /// state (see that method's doc comment) - tearing down a background
    /// tab's session never touches the pane a captain is actually looking
    /// at, and tearing down the current tab's own session closes the pane
    /// immediately since its `sreLead` is now `nil`.
    func tearDownSRELead(for tab: TabModel) {
        guard let state = tab.sreLead else { return }
        state.tearDownSession()
        state.chatView?.removeFromSuperview()
        tab.sreLead = nil

        if tab === currentTab {
            sreLeadGeneratePostmortemButton.isEnabled = true
            updateSRELeadControls()
        }
    }

    func makeSRELeadChat(for tab: TabModel) -> SRELeadChatView {
        let chat = SRELeadChatView(frame: .zero)
        chat.isHidden = true
        chat.onSubmit = { [weak self, weak tab] text in
            guard let self, let tab else { return }
            self.handleSRELeadSubmit(text, in: tab)
        }
        chat.onMessagesChanged = { [weak self, weak tab] in
            guard let self, let tab, tab === self.currentTab else { return }
            self.updateGeneratePostmortemButton()
        }
        chat.setInputEnabled(false)
        sreLeadCard.addSubview(chat)
        NSLayoutConstraint.activate([
            chat.leadingAnchor.constraint(equalTo: sreLeadCard.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: sreLeadCard.trailingAnchor),
            chat.topAnchor.constraint(equalTo: sreLeadHeaderDivider.bottomAnchor),
            chat.bottomAnchor.constraint(equalTo: sreLeadCard.bottomAnchor),
        ])
        chat.applyTheme(theme)
        return chat
    }

    func setSRELeadPaneOpen(_ open: Bool) {
        // The card look and the pane are the same state, so they are switched
        // together. The chrome snaps to its final geometry rather than
        // interpolating with the 0.18s slide - the terminal card's trailing
        // edge is simply already where the pane is about to arrive, which
        // reads as the panel sliding into a space made for it.
        updateTerminalCardStyle(carded: open)
        sreLeadPaneWidthConstraint.constant = open ? sreLeadPaneWidth : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }
}
