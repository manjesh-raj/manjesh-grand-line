// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition, and the single largest
// piece of it: the SRE Lead pane. The shared slide-open pane and its empty
// state, the chat wiring, postmortem generation, and the carded-terminal
// treatment the pane's presence switches on - all now scoped to this
// console's one session (`ConsoleSession.sreLead`, née per-tab state on
// `TabModel` before `fm/grandline-menubar-remove-items` collapsed the
// console to one session per host/window).
//
// The 5-concurrent-tab cap the original per-tab design needed
// (`sreLeadMaxConcurrent`/`showSRELeadCapReachedAlert`) is gone outright,
// not merely raised to 1: a console can have at most one session, so it can
// have at most one SRE Lead investigation, and a cap that can never bind is
// not worth keeping around to explain.
//
// See `ConsoleController.swift`'s header for the rest of what changed.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: SRE Lead (`ConsoleSession.sreLead` - see `SRELeadTabState.swift`'s
    // header. This section owns only the shared chrome: the pill, the pane,
    // the header, and the empty state - every method below operates on the
    // console's one session, never a page-level phase of its own.)

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

        sreLeadEmptyStateButton.title = "Start SRE Lead"
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

    /// The toolbar pill's click action - operates on `session`, which is the
    /// only investigation this console can ever have. Dedups exactly like
    /// `connectSSHIfNeeded`'s `session == nil` guard dedups a host reconnect:
    /// a click while a spawn is already in flight (`.starting`) is ignored
    /// rather than racing a second `SRELead.setUp`.
    @objc func toggleSRELead() {
        guard let target = session else { return }
        switch target.sreLead?.phase ?? .notStarted {
        case .starting:
            return
        case .ready:
            tearDownSRELead(for: target)
        case .notStarted, .failed:
            startSRELead(for: target)
        }
    }

    /// The pane's own empty-state "Start SRE Lead" button - the second
    /// entry point into `startSRELead(for:)` alongside the toolbar pill.
    @objc func startSRELeadForCurrentTabClicked() {
        guard let target = session, (target.sreLead?.phase ?? .notStarted) != .starting else { return }
        startSRELead(for: target)
    }

    /// Starts a brand-new SRE Lead investigation for this console's session
    /// - its own `SRELeadSession`/`SRELeadBridge`/`SRELeadRunner` and its own
    /// chat view.
    func startSRELead(for target: ConsoleSession) {
        let state = target.sreLead ?? SRELeadTabState()
        target.sreLead = state

        guard let claude = SRELead.resolveClaude() else {
            state.phase = .failed
            updateSRELeadControls()
            showSRELeadError("claude CLI not found on PATH.", in: target)
            return
        }

        state.phase = .starting
        updateSRELeadControls()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak target] in
            let result = SRELead.setUp()
            DispatchQueue.main.async {
                guard let self, let target, let state = target.sreLead, self.session === target else { return }
                switch result {
                case .success(let sreSession):
                    state.session = sreSession
                    state.bridge = SRELeadBridge(bridgeDir: sreSession.bridgeDir, target: target)
                    // F8: a runbook that runs through this session's bridge
                    // attaches itself to an active incident on this host. The
                    // bridge only *observes* the run - see its
                    // `onRunbookRun` doc comment.
                    state.bridge?.onRunbookRun = { [weak self] event in
                        self?.noteRunbookRun(name: event.name, ran: event.ran, total: event.total,
                                             ok: event.ok, refused: event.refused)
                    }
                    state.bridge?.start()
                    state.runner = SRELeadRunner(session: sreSession, claude: claude)
                    let chat = state.chatView ?? self.makeSRELeadChat(for: target)
                    state.chatView = chat
                    chat.clearMessages()
                    chat.append(SRELeadMessage(role: .status, text: "SRE Lead is ready. Ask a question about this cluster below."))
                    chat.setInputEnabled(true)
                    state.phase = .ready
                    self.updateSRELeadControls()
                case .failure(let error):
                    state.phase = .failed
                    self.updateSRELeadControls()
                    self.showSRELeadError(error.message, in: target)
                }
            }
        }
    }

    /// The chat view's input submits here - the native equivalent of the
    /// old tmux pane's "just type into the terminal" entry point, now with a
    /// real input field instead of the captain having to click into a raw
    /// `claude` TUI first.
    func handleSRELeadSubmit(_ text: String, in target: ConsoleSession) {
        guard let state = target.sreLead, let runner = state.runner, let chat = state.chatView else { return }
        chat.append(SRELeadMessage(role: .user, text: text))
        chat.setInputEnabled(false)
        runner.ask(text) { [weak self, weak chat, weak target] result in
            guard let chat else { return }
            switch result {
            case .success(let reply):
                chat.append(SRELeadMessage(role: .assistant, text: reply))
                // F8 (incident mode): a completed turn is one of the things
                // that attach themselves to an active incident on this
                // host. Only ever a real reply - a failed turn is an error
                // in this chat, not something that happened to the cluster
                // - and a no-op when no incident is running.
                if let self, let target { self.noteSRELeadTurn(question: text, session: target) }
                // fm/grandline-notification-center: a reply that lands
                // while this console isn't the one on screen is exactly the
                // "SRE Lead answered on a page you're not looking at"
                // signal - a reply landing while the captain is already
                // watching needs no notification at all.
                if let self, let target, self.view.isHidden {
                    self.onSRELeadReplyWhileBackground?(target)
                }
            case .failure(let error):
                chat.append(SRELeadMessage(role: .error, text: error.message))
            }
            chat.setInputEnabled(true)
            // Only steal first responder back if the captain is still
            // looking at this console - a reply landing while it's hidden
            // must never yank focus away from whatever is on screen.
            guard let self, let window = self.view.window, !self.view.isHidden,
                  window.firstResponder !== chat else { return }
            window.makeFirstResponder(chat)
        }
    }

    func showSRELeadError(_ message: String, in target: ConsoleSession) {
        let state = target.sreLead ?? SRELeadTabState()
        target.sreLead = state
        let chat = state.chatView ?? makeSRELeadChat(for: target)
        state.chatView = chat
        chat.append(SRELeadMessage(role: .error, text: message))
        if target === session { updateSRELeadPaneContent() }
    }

    /// Refreshes the toolbar button, the pane's visible content, the Generate
    /// Postmortem button, and the button's tooltip - all four derived from
    /// `session`, called from every place that changes this console's
    /// session or that session's own SRE Lead phase.
    ///
    /// No `applyTheme` call for the button any more: a `HelmButton` owns its
    /// own `ThemeManager` observation and re-derives every colour itself, and
    /// `tint` is a `HelmTint` case rather than a resolved hex, so the phase's
    /// colour follows a theme change with nothing to push.
    func updateSRELeadControls() {
        guard let target = session else {
            updateSRELeadPaneContent()
            return
        }
        let phase = target.sreLead?.phase ?? .notStarted
        sreLeadButton?.title = phase.text
        sreLeadButton?.symbolName = phase.symbol
        sreLeadButton?.tint = phase.tint
        updateSRELeadPaneContent()
        updateGeneratePostmortemButton()
        sreLeadButton?.toolTip = "Toggle the SRE Lead investigation pane"
    }

    /// Shows the console's own session's SRE Lead chat (started/starting/
    /// failed-with-error) if it has one, or the shared empty state
    /// otherwise. This is also the single place that decides whether the
    /// pane is open at all: no session at all, or a session with no SRE
    /// Lead state yet, both show a fully closed pane (no pane, not even the
    /// empty state).
    func updateSRELeadPaneContent() {
        guard let target = session else {
            sreLeadEmptyStateView.isHidden = true
            setSRELeadPaneOpen(false)
            return
        }
        target.sreLead?.chatView?.isHidden = false
        sreLeadEmptyStateView.isHidden = (target.sreLead?.chatView != nil)
        updateSRELeadStatusPill(phase: target.sreLead?.phase ?? .notStarted)
        setSRELeadPaneOpen(target.sreLead != nil)
    }

    /// The panel header's phase chip. `.notStarted` never renders - the panel
    /// is only ever visible for a session that has SRE Lead state at all, so
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
    /// design, so its own Shell session stays flush at full column count.
    ///
    /// This is deliberately **not** a frame change: `terminalInset` is already
    /// permanent, so all that happens here is that a decorative overlay
    /// becomes visible and repaints (`ConsoleCardChrome.swift`'s header). No
    /// `TerminalView` is touched, which is what keeps a captain's scrollback
    /// intact across a toggle - covered by `SRELeadSessionSelfTest`'s
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
    /// once this console's session has a real assistant reply to summarize
    /// (`SRELeadChatView.hasRealExchange`) - wired to fire on every
    /// `append`/`clearMessages` via `chat.onMessagesChanged` (see
    /// `makeSRELeadChat`), and called directly after `startSRELead`'s own
    /// session-open/session-fail transitions since those don't append
    /// through the normal submit path.
    func updateGeneratePostmortemButton() {
        sreLeadGeneratePostmortemButton.isHidden = !(session?.sreLead?.chatView?.hasRealExchange ?? false)
    }

    /// "Generate Postmortem": summarizes this console's own investigation
    /// transcript into a structured markdown document via one
    /// non-interactive `claude -p` call (`SRELeadPostmortem.generate`), then
    /// saves it into the same `DocsRunbookStore` postmortems store phase 1
    /// built (`DocsRunbookStore.createPostmortem`) - browsable at the
    /// standalone Postmortems destination (`fm/grandline-docs-split-
    /// runbooks-postmortems`), not a Docs tab any more. A failure here only ever
    /// appends an error message to the chat feed - the investigation
    /// transcript itself is never touched, so the captain can retry with
    /// nothing lost.
    @objc func generatePostmortemClicked() {
        guard let target = session, let chat = target.sreLead?.chatView, chat.hasRealExchange,
              sreLeadGeneratePostmortemButton.isEnabled else { return }
        let transcript = chat.transcriptForPostmortem
        let hostLabel = target.name

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

    /// Tears down `target`'s own SRE Lead session (bridge, in-flight `claude`
    /// process, scratch dir) and removes its chat. Called from the pill's
    /// toggle-off click and, unconditionally, from `closeCurrentTab` for the
    /// session being closed. Whether the shared pane ends up open or closed
    /// is decided entirely by `updateSRELeadControls`/`updateSRELeadPaneContent`
    /// off `session`'s own state (see that method's doc comment).
    func tearDownSRELead(for target: ConsoleSession) {
        guard let state = target.sreLead else { return }
        state.tearDownSession()
        state.chatView?.removeFromSuperview()
        target.sreLead = nil

        if target === session {
            sreLeadGeneratePostmortemButton.isEnabled = true
            updateSRELeadControls()
        }
    }

    func makeSRELeadChat(for target: ConsoleSession) -> SRELeadChatView {
        let chat = SRELeadChatView(frame: .zero)
        chat.isHidden = true
        chat.onSubmit = { [weak self, weak target] text in
            guard let self, let target else { return }
            self.handleSRELeadSubmit(text, in: target)
        }
        chat.onMessagesChanged = { [weak self, weak target] in
            guard let self, let target, target === self.session else { return }
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
