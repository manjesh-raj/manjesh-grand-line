// Grand Line - native macOS app.
//
// The Straw Hat Pirates chat surface - phase 1's transcript + composer, living
// on Overview's "Crew" tab (`FleetController`).
//
// ## Why this is a new view and not a refactor of `SRELeadChatView`
//
// The plan's phase 1 says to "reuse `SRELeadChatView`'s rendering shape", and
// that is exactly what this does - the *shape*, not the file. Extracting a
// shared generic chat view out of `SRELeadChatView` would have meant
// refactoring the one pane in this app that is covered by four separate
// window-backed suites (`SRELeadPerTabSelfTest`, `NotificationCenterSRELead
// SelfTest`, `DaylightDrillPageSlice2SelfTest`, `ConsoleClaudeUsageSelfTest`),
// carries the Finding/Recommended-next-action contract with
// `SRELead.persona`, and answers to a live per-tab bridge - all to serve a
// feature whose phase 2 is about to make its message model genuinely
// different (several attributed speakers per reply, plus confirm cards). A
// premature merge of two things that are about to diverge is how this
// codebase ended up with the five card recipes its own UI audit spent seven
// phases undoing.
//
// What *is* shared is everything that carries the visual language, and it is
// shared by reuse rather than by copy:
//
//  - `SRELeadMarkdown.parse` - the whole markdown parser, verbatim. It is a
//    general paragraph/list/code-block parser with two app-specific callout
//    labels layered on; Luffy's persona never emits those labels, so the
//    callout case simply never fires and the general half does all the work.
//  - `HelmPromptWell` (the terminal-prompt composer Compose and SRE Lead
//    use), `HelmAccentRow` (the accent-bar + badge + kicker card),
//    `IconTileView`, `HelmButton`, `HelmEmptyState`, `HelmType`, `HelmMetrics`.
//
// ## The one deliberate difference from SRE Lead's transcript
//
// A reply block is **attributed** - an icon tile plus "Luffy · Crew" in its
// header - rather than a bare "SRE Lead" label. That is the captain's own
// approved mockup ("Nami · Tasks"), and it is the seam phase 2 needs: a
// second speaker is a second `StrawHatMessage.crew(member:)`, not a new view.
// Phase 1 has exactly one member, so today every block says Luffy.
//
// This view knows nothing about `claude`, sessions or resume - it renders
// `StrawHatMessage` values the controller appends and reports submitted text
// through `onSubmit`. Same seam `SRELeadChatView` documents.

import AppKit

enum StrawHatMessage {
    /// The captain's own typed words.
    case captain(String)
    /// One attributed block of a reply.
    ///
    /// Phase 1 carried `(StrawHatMember, String)`; phase 2 carries the whole
    /// parsed `StrawHatSection`, because a block now also holds its
    /// proposals, its dropped-proposal count and its follow-up line - and
    /// because a rung-2 section has *no* speaker, which a non-optional member
    /// could not express. One reply becomes several of these, appended in
    /// order, which is what makes "several crew voices from one call" a
    /// transcript rather than a new view.
    case crew(StrawHatSection)
    /// This view's own chrome - "the crew is thinking...", never content.
    case status(String)
    /// A turn that failed, rendered so the captain can see why and retry.
    case error(String)
}

final class StrawHatChatView: NSView, NSTextViewDelegate {

    /// Fires with the captain's trimmed, non-empty message.
    var onSubmit: ((String) -> Void)?
    /// Fires whenever `messages` changes - the controller's "New conversation"
    /// button is pointless on an empty thread.
    var onMessagesChanged: (() -> Void)?
    /// Fires when the captain presses a confirm card's button, and returns what
    /// actually happened so the card can render it.
    ///
    /// This view holds no store and cannot write: the whole point of the
    /// confirm card is that a human press is the only path from a model's
    /// proposal to the captain's data, and the write itself lives in
    /// `StrawHatProposalExecutor`, reached through `FleetController+Crew`.
    /// Unset (as in a bare view with no controller) means a press reports a
    /// real failure rather than silently doing nothing.
    var onConfirmProposal: ((StrawHatProposal, StrawHatConfirmChoices) -> StrawHatProposalOutcome)?

    /// Fires when the captain clicks a navigation handoff's link row, and
    /// returns a message to show *only* when the handoff could not be
    /// followed (no live session on that host, for instance) - nil means the
    /// app moved and there is nothing left to say.
    ///
    /// A separate closure from `onConfirmProposal` on purpose. Those two do
    /// genuinely different things - one writes to a store behind a confirm
    /// press, one selects a page on a click - and sharing a closure would
    /// make a self-test asserting "a handoff writes nothing" pass just as
    /// happily with the two paths crossed. Phase 3, M3.2.
    var onHandoff: ((StrawHatHandoff) -> String?)?

    /// M2.4's "contributing glow" surface - who is aboard, and who spoke in
    /// the reply that just landed. See `StrawHatCrewViews.swift`'s header for
    /// why the glow lives here rather than on the reply block itself.
    private let crewStrip = StrawHatCrewStrip()
    private let crewStripDivider = NSView()
    /// UX-08: the empty thread's starter questions.
    private let starterGrid = StrawHatStarterGrid()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()

    /// Shown while the thread is empty, in the transcript's own place. A chat
    /// pane whose entire content area is blank reads as broken rather than
    /// new, and this app has a shared component for exactly that.
    private let emptyState = HelmEmptyState(
        symbol: StrawHatCrew.speaker.symbol,
        title: "Talk to your crew",
        body: "The whole crew is aboard - tasks, docs, health, commands, ideas and automations. Ask them anything, or say what you need doing and they will draft it. Every write is a card you confirm.",
        size: .standard,
        boxed: true,
        hue: RailDestination.overview.domainHue)

    // MARK: Composer
    //
    // The terminal-prompt well Compose and SRE Lead already use
    // (`HelmPromptWell`, C1 of the Console fixes board): a "❯" prompt, typed
    // text in the terminal's monospaced font and colours, a block cursor, and
    // the send button at the trailing end of the prompt line. The captain
    // asked for this input to be as simple to type into as Compose's, and to
    // look like it (`fm/grandline-widget-polish`). It replaces the rounded
    // pill that copied the ⌘K query well.
    //
    // What did not move: plain Return sends and Shift-Return inserts a new
    // line (`textView(_:doCommandBy:)` below), the keybinding hint stays a
    // tooltip, and the data line stays under the well.
    private let composerWrap = NSView()
    /// One line tall when empty, growing to five before it scrolls - the same
    /// shape as SRE Lead's composer.
    private let well = HelmPromptWell(minLines: 1, maxLines: 5)
    private var textView: HelmPromptTextView { well.textView }
    private let sendButton = HelmButton(symbol: "arrow.up", variant: .primary, size: .small)
    static let placeholder = "Message the crew\u{2026}"

    /// The keybinding hint, now a tooltip rather than a permanent label -
    /// still discoverable on hover, no longer a strip of text competing with
    /// the send button for attention.
    private static let keybindingHint = "\u{21B5} to send  \u{00B7}  \u{21E7}\u{21B5} for a new line"

    /// X11: the crew's answers come from Claude, and so does everything the
    /// crew read to write them.
    ///
    /// A permanent line rather than a tooltip, unlike the keybinding hint
    /// above - and for the opposite reason to the one that demoted that hint.
    /// A shortcut is a convenience a captain discovers once; where their
    /// notes, tasks and hosts go is a claim the app owes them every time,
    /// and the daily review states its own version permanently on the card.
    /// It is `captionSmall` and muted, below the composer, so it sits under
    /// the surface rather than beside the send button.
    private let dataFootnote = NSTextField(labelWithString:
        AITransparency.sentToClaude("what you type, and what the crew reads from your stores,"))

    /// The send button's side: SRE Lead's own, so it sits inside a one-line
    /// prompt well with room around it.
    private static let sendSide: CGFloat = SRELeadChatView.sendSide

    /// This whole view is a bordered card (the controller paints the border),
    /// so its own content has to be inset from that edge - without it the
    /// message cards and the composer sit flush against the border, which a
    /// real off-screen render of this pane showed reading as cramped.
    private static let contentInset: CGFloat = HelmMetrics.s3

    private var isInputEnabled = true
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var messages: [StrawHatMessage] = []

    /// What has already been done to each proposal in the transcript, keyed by
    /// `StrawHatProposal.id`.
    ///
    /// **Why this lives on the view and not on the card.** `applyTheme` rebuilds
    /// every block from `messages` (styling is a pure function of the data), so
    /// a confirmed card's state cannot live on the card - it is thrown away and
    /// a fresh, armed one takes its place. That was a real HIGH-severity defect:
    /// a theme or chrome-font-scale change re-armed an already-confirmed
    /// proposal and a second press wrote a duplicate record. Keyed by the
    /// model's own id, so it survives the rebuild that replays the same
    /// `messages`.
    ///
    /// This is the *render* half. The write half is
    /// `StrawHatController.resolvedProposals`, and the two are deliberately
    /// separate guarantees rather than redundancy: this one is "the card comes
    /// back in its done state", that one is "no second write can happen at all"
    /// - which still has to hold for a keyboard activation racing a rebuild, or
    /// for a bare view with no controller behind it.
    private var proposalResolutions: [UUID: StrawHatConfirmCard.Resolution] = [:]

    /// Which project the captain picked on a still-unconfirmed task card,
    /// keyed by `StrawHatProposal.id`.
    ///
    /// The same rebuild problem `proposalResolutions` solves, one step earlier:
    /// a selection made and then lost to a theme change would file the task
    /// somewhere the captain did not choose, with nothing on screen to say so.
    /// `[UUID: String?]` rather than `[UUID: String]` because "they explicitly
    /// picked No project" and "they have not picked yet" are different states -
    /// only the second should fall back to the crew's own hint.
    private var proposalProjectSelections: [UUID: String?] = [:]

    /// The captain's real projects, for a task card's own inline picker. Set
    /// by the page; empty until then, which simply means no card asks.
    private var projects: [ShiftProject] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildCrewStrip()
        buildScroll()
        buildComposer()
        applyTheme(theme)
        updateEmptyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildCrewStrip() {
        crewStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crewStrip)
        crewStripDivider.wantsLayer = true
        crewStripDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crewStripDivider)
        NSLayoutConstraint.activate([
            crewStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
            crewStrip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.contentInset),
            crewStrip.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2 + 2),

            crewStripDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            crewStripDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            crewStripDivider.topAnchor.constraint(equalTo: crewStrip.bottomAnchor, constant: HelmMetrics.s2),
            crewStripDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func buildScroll() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        // A sibling of the scroll view, filling the same area, rather than a
        // row inside the transcript stack. As a row it would sit at the *top*
        // of a tall, otherwise-empty transcript - which a real render showed
        // as a card stranded above a large blank area. `HelmEmptyState`
        // centres its own content in whatever height it is given, so handing
        // it the whole area is all that is needed.
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        starterGrid.translatesAutoresizingMaskIntoConstraints = false
        starterGrid.onPick = { [weak self] starter in
            self?.setComposerText(starter.question)
            self?.focusComposer()
        }
        addSubview(starterGrid)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.contentInset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.contentInset),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.contentInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Self.contentInset),
            // Pinned to the *clip* view, never the scroll view (AGENTS.md
            // gotcha (4)): a non-overlay scroller reserves a real track that
            // narrows the clip view without narrowing `scroll` itself, and a
            // document pinned to the outer width renders underneath it.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: Self.contentInset),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -Self.contentInset),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor, constant: Self.contentInset),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -Self.contentInset),

            starterGrid.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: Self.contentInset),
            starterGrid.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -Self.contentInset),
            starterGrid.topAnchor.constraint(equalTo: scroll.topAnchor, constant: Self.contentInset),
            starterGrid.bottomAnchor.constraint(lessThanOrEqualTo: scroll.bottomAnchor, constant: -Self.contentInset),
        ])
    }

    private func buildComposer() {
        composerWrap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composerWrap)

        well.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(well)

        dataFootnote.font = HelmType.captionSmall()
        dataFootnote.lineBreakMode = .byTruncatingTail
        dataFootnote.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(dataFootnote)

        buildTextView()
        buildSendButton()

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Below the crew strip, not at this view's own top edge.
            scroll.topAnchor.constraint(equalTo: crewStripDivider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: composerWrap.topAnchor),

            composerWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerWrap.bottomAnchor.constraint(equalTo: bottomAnchor),

            well.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: Self.contentInset),
            well.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -Self.contentInset),
            well.topAnchor.constraint(equalTo: composerWrap.topAnchor, constant: HelmMetrics.s2),
            well.bottomAnchor.constraint(equalTo: dataFootnote.topAnchor, constant: -4),

            // Under the prompt, where the well's own text column starts.
            dataFootnote.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: HelmPromptWell.edgeInset),
            dataFootnote.trailingAnchor.constraint(lessThanOrEqualTo: well.trailingAnchor),
            dataFootnote.bottomAnchor.constraint(equalTo: composerWrap.bottomAnchor,
                                                 constant: -Self.contentInset),
        ])
    }

    /// The well's text view. The well owns its font, colours, placeholder,
    /// cursor and growth; this view owns its delegate - Return to send.
    private func buildTextView() {
        textView.delegate = self
        textView.setAccessibilityLabel("Message the crew")
        textView.toolTip = Self.keybindingHint
        well.placeholder = Self.placeholder
    }

    /// The send button, on the trailing end of the prompt line.
    private func buildSendButton() {
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setAccessibilityLabel("Send")
        sendButton.target = self
        sendButton.action = #selector(submit)
        sendButton.isEnabled = false
        // R2-SEC-05: the button that starts the `claude -p` call says what it
        // sends. The keybinding hint is the text view's own tooltip.
        sendButton.toolTip = AITransparency.willSendToClaude("your message, and what the crew reads from your stores,")
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        well.setTrailingAccessory(sendButton)

        // `HelmPageToolbar.iconButton`'s alignment-rect correction: a
        // `HelmButton` paints its chrome in its own layer, which fills the
        // *frame*, while Auto Layout constrains its *alignment rect* - so a
        // plain size constraint renders a visibly larger box.
        let insets = sendButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: Self.sendSide - insets.left - insets.right),
            sendButton.heightAnchor.constraint(equalToConstant: Self.sendSide - insets.top - insets.bottom),
        ])
    }

    // MARK: Messages

    func append(_ message: StrawHatMessage) {
        messages.append(message)
        let block = messageBlock(for: message)
        stack.addArrangedSubview(block)
        block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updateEmptyState()
        refreshCrewStrip()
        scrollToBottom()
        onMessagesChanged?()
    }

    /// Drops the last message if it is a `.status` - how "Luffy is
    /// thinking\u{2026}" is replaced by the real reply rather than left above it.
    func removeTrailingStatus() {
        guard case .status = messages.last else { return }
        messages.removeLast()
        // The stack holds exactly one block per message and nothing else (the
        // empty state is a sibling of the scroll view, not a row), so the last
        // arranged subview is the block for the message just dropped.
        stack.arrangedSubviews.last.map { $0.removeFromSuperview() }
        updateEmptyState()
        refreshCrewStrip()
        onMessagesChanged?()
    }

    /// Drops the whole thread - the controller's "New conversation".
    ///
    /// Clears `proposalResolutions` too, which is exactly what separates it
    /// from `rebuildTranscript()`: a *new* conversation has no confirmed
    /// proposals to remember, while a theme change must remember every one.
    func clearMessages() {
        messages.removeAll()
        proposalResolutions.removeAll()
        proposalProjectSelections.removeAll()
        removeAllBlocks()
        updateEmptyState()
        refreshCrewStrip()
        onMessagesChanged?()
    }

    private func removeAllBlocks() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    /// Re-render every block from `messages` without touching the thread
    /// itself. What `applyTheme` calls - `clearMessages()` would drop the
    /// confirmed-proposal record along with the views and re-arm every card
    /// the captain had already pressed.
    private func rebuildTranscript() {
        let saved = messages
        messages.removeAll()
        removeAllBlocks()
        for message in saved { append(message) }
    }

    /// Whether the captain and the crew have actually exchanged anything -
    /// a lone status/error line does not count.
    var hasRealExchange: Bool {
        messages.contains {
            switch $0 {
            case .captain, .crew: return true
            case .status, .error: return false
            }
        }
    }

    /// The captain's projects, for a task card's own inline project picker.
    ///
    /// Pushed by the page rather than read from a store here: this view holds
    /// no store (see this file's header), and the list is small enough that
    /// re-rendering the transcript on a change is cheaper than the plumbing to
    /// avoid it. Only re-renders when the list genuinely differs, so an
    /// ordinary refresh does not churn every card.
    func setProjects(_ projects: [ShiftProject]) {
        guard projects != self.projects else { return }
        self.projects = projects
        rebuildTranscript()
    }

    func setInputEnabled(_ enabled: Bool) {
        isInputEnabled = enabled
        textView.isEditable = enabled
        updateSendButtonEnabled()
    }

    /// Puts the caret in the composer - called when the Crew tab is shown, so
    /// the captain can just type.
    @discardableResult
    func focusComposer() -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

    /// Put text into the composer as though the captain had typed it.
    ///
    /// The notification is not decoration: the send button's enablement and
    /// the placeholder's visibility are both driven from `textDidChange`, so
    /// setting `string` alone leaves a composer holding real text with a
    /// disabled Send beside it.
    ///
    /// **No production caller since review #3 §7.** Its one caller was
    /// `StrawHatController.startNewConversation(with:)`, the seam that
    /// carried a message typed on the fleet dashboard over to this page; that
    /// composer is gone and so is the seam, which takes the review's L7
    /// defect (a message silently dropped when a turn was already running)
    /// with it - there is no longer an off-page message to drop. Kept as this
    /// view's supported way to seed its own composer, and still exercised by
    /// `StrawHatViewSelfTest`, because a chat view that cannot be handed text
    /// is the wrong shape for the next caller that needs it.
    func setComposerText(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func updateEmptyState() {
        // UX-08: an empty thread offers its starters, top-aligned, in the
        // transcript's place; the paragraph is for a page given none.
        starterGrid.isHidden = !messages.isEmpty || starterGrid.starters.isEmpty
        emptyState.isHidden = !messages.isEmpty || !starterGrid.starters.isEmpty
    }

    /// UX-08: the six starters, from the page's own data.
    func setStarters(_ starters: [StrawHatStarters.Starter]) {
        starterGrid.setStarters(starters, theme: theme)
        updateEmptyState()
    }

    /// Lights the strip for whoever spoke in the *most recent* reply.
    ///
    /// Derived from `messages` rather than pushed in by the controller, so the
    /// strip cannot disagree with the transcript beside it - and so a theme
    /// rebuild (which replays every message) lands back on the same state. A
    /// reply is a contiguous run of `.crew` blocks at the tail, since one turn
    /// appends its sections together; anything before the captain's last
    /// message belongs to an older turn and must not stay lit.
    private func refreshCrewStrip() {
        var contributors: Set<StrawHatMember> = []
        for message in messages.reversed() {
            switch message {
            case .crew(let section):
                if let speaker = section.speaker { contributors.insert(speaker) }
            case .status:
                // A turn in flight. Nobody has answered yet, and lighting a
                // guess is exactly what this must never do.
                contributors.removeAll()
                crewStrip.setContributors([])
                return
            case .captain, .error:
                // Reached the start of this reply's own turn.
                crewStrip.setContributors(contributors)
                return
            }
        }
        crewStrip.setContributors(contributors)
    }

    private func updateSendButtonEnabled() {
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = isInputEnabled && hasText
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Blocks

    private func messageBlock(for message: StrawHatMessage) -> NSView {
        switch message {
        case .captain(let text): return captainBlock(text)
        case .crew(let section): return crewBlock(section)
        case .status(let text): return statusBlock(text)
        case .error(let text): return errorBlock(text)
        }
    }

    /// `SRELeadChatView.accentRow`'s shape: the app's one accent-bar card,
    /// `hover: false` because a transcript block is content, not a control -
    /// a hover highlight on something that does nothing is a lie.
    private func accentRow(kicker: String, tint: HelmTint, badgeSymbol: String, content: NSView) -> NSView {
        let row = HelmAccentRow(contentView: content, hover: false)
        row.configure(HelmAccentRow.Content(tint: tint, kicker: kicker, badgeSymbol: badgeSymbol), theme: theme)
        return row
    }

    private func captainBlock(_ text: String) -> NSView {
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .medium)
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        // `HelmAccentRow` caps its *own* labels' width, and deliberately skips
        // that for a caller-owned `contentView` (it never adds those labels to
        // the tree) - so the cap is this view's job. Without it one long
        // unbroken token in a message is a window-width floor, gotcha (13).
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.translatesAutoresizingMaskIntoConstraints = false
        return accentRow(kicker: "You", tint: .accent, badgeSymbol: "person.fill", content: body)
    }

    private func errorBlock(_ text: String) -> NSView {
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: HelmType.scaled(12.5))
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.translatesAutoresizingMaskIntoConstraints = false
        return accentRow(kicker: "Couldn't reach the crew", tint: .critical,
                         badgeSymbol: "exclamationmark.triangle.fill", content: body)
    }

    /// A centred system-message divider - a muted label between two hairlines
    /// - rather than a card, since this is the pane's own chrome and not
    /// something anybody said.
    private func statusBlock(_ text: String) -> NSView {
        func hairline() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return line
        }

        let label = NSTextField(labelWithString: text)
        label.font = HelmType.caption()
        label.textColor = HelmTheme.mutedInk(theme)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [hairline(), label, hairline()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// An attributed reply card: a portrait tile plus "Nami \u{00B7} Tasks" over
    /// a hairline, then the parsed markdown, then a confirm card per proposal,
    /// then an optional follow-up line.
    ///
    /// A section with **no** speaker (the parser's rung 2 - the model named a
    /// voice that is not aboard) deliberately gets no attribution header at
    /// all: its text still renders, because the ladder's invariant is that a
    /// reply is never dropped, but crediting it to a crew member who did not
    /// say it would be exactly the plausible-but-wrong this feature exists to
    /// avoid. `StrawHatEnvelope` also refuses to carry that section's
    /// proposals, so there is nothing to confirm on it either.
    private func crewBlock(_ section: StrawHatSection) -> NSView {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = HelmMetrics.s2
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // Every row is width-tied to the block, so a long markdown paragraph
        // and a confirm card line up on both edges.
        func add(_ view: NSView) {
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        if let member = section.speaker {
            add(attributionHeader(for: member))
            add(hairlineDivider())
        }

        if !section.text.isEmpty {
            let blockStack = NSStackView()
            blockStack.orientation = .vertical
            blockStack.alignment = .leading
            blockStack.spacing = HelmMetrics.s2
            blockStack.translatesAutoresizingMaskIntoConstraints = false
            // The whole markdown parser, reused - see this file's header.
            for block in SRELeadMarkdown.parse(section.text) {
                let view = renderBlock(block)
                blockStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: blockStack.widthAnchor).isActive = true
            }
            add(blockStack)
        }

        // M2.2 / M3.2: one row per validated proposal, and *which* row is
        // decided by `StrawHatProposalKind.isNavigation` rather than by a
        // list here - so a kind added to that enum cannot land on the wrong
        // side of the write/link split by omission.
        //
        // Nothing in either branch writes: a card's press goes up through
        // `onConfirmProposal` and a link's through `onHandoff`.
        for proposal in section.proposals {
            if proposal.kind.isNavigation, let handoff = proposal.handoff {
                let row = StrawHatHandoffRow(handoff: handoff, kind: proposal.kind, theme: theme)
                row.onActivate = { [weak self] handoff in
                    guard let handler = self?.onHandoff else {
                        return "This chat isn't connected to the rest of the app right now."
                    }
                    return handler(handoff)
                }
                add(row)
                continue
            }
            // A proposal the captain already dealt with is built in its done
            // state rather than armed - `proposalResolutions`' own note has the
            // defect this closes.
            let card = StrawHatConfirmCard(proposal: proposal, theme: theme,
                                           resolution: proposalResolutions[proposal.id],
                                           projects: projects,
                                           selectedProjectID: proposalProjectSelections[proposal.id])
            card.onConfirm = { [weak self] proposal, choices in
                guard let handler = self?.onConfirmProposal else {
                    return .failed(message: "This chat isn't connected to your stores right now.")
                }
                return handler(proposal, choices)
            }
            card.onResolved = { [weak self] proposal, resolution in
                self?.proposalResolutions[proposal.id] = resolution
            }
            card.onProjectSelectionChanged = { [weak self] proposal, projectID in
                self?.proposalProjectSelections[proposal.id] = projectID
            }
            add(card)
        }

        // The "no silent caps" rule: a proposal the parser refused is stated
        // rather than vanishing, because a card that never appears is
        // indistinguishable from the crew not having offered anything.
        if section.droppedProposalCount > 0 {
            add(droppedProposalNote(section.droppedProposalCount))
        }

        if let followup = section.followup {
            add(followupRow(followup))
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = HelmMetrics.rCard
        container.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)
        // An attributed block leaves room for its accent bar on the leading
        // edge; an unattributed one has none, so its text starts where every
        // other block's does.
        let leading: CGFloat = section.speaker == nil ? HelmMetrics.s3 : HelmMetrics.s3 + 6
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.s3),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s3),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s3),
        ])

        // The block's own accent, in the speaking member's colour - what makes
        // three voices in one turn readable at a glance rather than three
        // identical cards.
        if let member = section.speaker {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.backgroundColor = member.accentColor(in: theme).cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
                bar.widthAnchor.constraint(equalToConstant: 3),
                bar.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s2),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s2),
            ])
        }
        return container
    }

    private func hairlineDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    /// "<portrait> Nami \u{00B7} Tasks" - the captain's own approved mockup.
    private func attributionHeader(for member: StrawHatMember) -> NSView {
        let portrait = StrawHatPortraitTile(member: member, side: StrawHatPortraitTile.replySize)
        portrait.applyTheme(theme)

        let name = NSTextField(labelWithString: member.displayName)
        name.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .semibold)
        name.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)

        let role = NSTextField(labelWithString: "\u{00B7} \(member.role)")
        role.font = HelmType.captionSmall()
        role.textColor = HelmTheme.mutedInk(theme)
        role.translatesAutoresizingMaskIntoConstraints = false
        role.lineBreakMode = .byTruncatingTail
        role.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        role.setContentHuggingPriority(.required, for: .horizontal)

        // Without this spacer the row's slack goes to whichever label hugs
        // least (`.fill` stretches it), which a real render showed as the role
        // label pinned to the far right of the card, a hundred points from the
        // name it belongs to. The spacer absorbs the slack instead.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [portrait, name, role, spacer])
        headerRow.orientation = .horizontal
        headerRow.spacing = 7
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        return headerRow
    }

    private func droppedProposalNote(_ count: Int) -> NSView {
        let plural = count == 1
            ? "1 suggestion in this reply couldn't be offered as a card"
            : "\(count) suggestions in this reply couldn't be offered as cards"
        let note = NSTextField(wrappingLabelWithString:
            "\u{26A0} \(plural) - the crew isn't allowed to do that yet.")
        note.font = HelmType.captionSmall()
        note.textColor = HelmTheme.mutedInk(theme)
        note.lineBreakMode = .byWordWrapping
        note.isSelectable = true
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.translatesAutoresizingMaskIntoConstraints = false
        return note
    }

    /// A section's closing question - a muted line with a leading glyph, never
    /// a card. It asks; it does not write, and nothing about it is clickable.
    private func followupRow(_ text: String) -> NSView {
        let glyph = NSImageView()
        glyph.image = HelmSymbol.image("arrow.turn.down.right", pointSize: 11,
                               weight: HelmSymbol.weight(for: .regular))
        glyph.contentTintColor = HelmTheme.mutedInk(theme)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: HelmType.scaled(11.5))
        label.textColor = HelmTheme.mutedInk(theme)
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: Markdown block rendering (`SRELeadChatView`'s, reused in shape)

    private func renderBlock(_ block: SRELeadMarkdownBlock) -> NSView {
        switch block {
        case .paragraph(let runs): return wrappingLabel(attributedInline(runs))
        case .bulletList(let items): return bulletListView(items)
        case .codeBlock(let code): return codeBlockView(code)
        // Luffy's persona never asks for the Finding/Recommended-next-action
        // labels, so this only fires if a reply happens to open with that
        // exact bold prefix. Rendering it as a plain paragraph rather than a
        // callout is the honest answer: the callout means something specific
        // in SRE Lead's contract and nothing at all in this one.
        case .callout(_, let runs): return wrappingLabel(attributedInline(runs))
        }
    }

    private func wrappingLabel(_ text: NSAttributedString) -> NSTextField {
        // `labelWithString:` rather than the bare initializer - the bare one
        // is an *input* construction and `checkNoRawTextInputs` bans it.
        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = true
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.attributedStringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func attributedInline(_ runs: [SRELeadInlineRun]) -> NSAttributedString {
        let baseSize = HelmType.scaled(12.5)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let codeBackground = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.14)
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
            if run.code {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .medium)
                attributes[.backgroundColor] = codeBackground
            } else if run.bold {
                attributes[.font] = NSFont.systemFont(ofSize: baseSize, weight: .semibold)
            } else {
                attributes[.font] = NSFont.systemFont(ofSize: baseSize)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func bulletListView(_ items: [[SRELeadInlineRun]]) -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let bullet = NSTextField(labelWithString: "\u{25CF}")
            bullet.setScaledFont(ofSize: 7)
            bullet.textColor = HelmTheme.nsColor(theme.accentHex)
            bullet.translatesAutoresizingMaskIntoConstraints = false
            bullet.setContentHuggingPriority(.required, for: .horizontal)
            bullet.setContentCompressionResistancePriority(.required, for: .horizontal)

            let row = NSStackView(views: [bullet, wrappingLabel(attributedInline(item))])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 6
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false

            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        return list
    }

    private func codeBlockView(_ code: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: code)
        label.font = HelmType.code()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true
        // Same gotcha (13) reasoning as the message bodies above, and more
        // likely to bite here: a generated code block can legitimately hold
        // one long unbroken line.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = HelmMetrics.rChip
        panel.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.22).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        return panel
    }

    // MARK: Input

    @objc private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isInputEnabled else { return }
        // The well re-fits its height and shows its placeholder again on
        // its own when `string` changes.
        textView.string = ""
        updateSendButtonEnabled()
        onSubmit?(text)
    }

    func textDidChange(_ notification: Notification) {
        updateSendButtonEnabled()
    }

    /// Plain Return sends, Shift+Return inserts a newline - the same mapping
    /// `SRELeadChatView` uses, so the app's two chat composers behave alike.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        submit()
        return true
    }

    // MARK: Theming

    // MARK: PF10 - a theme change repaints; it rebuilds at most once, and never
    //       for a page nobody is looking at
    //
    // PF10 of the 2026-09-25 full review: `applyTheme` tore the whole
    // transcript down and re-rendered it on every call, against GL-24 ("a
    // theme observer repaints - it never fetches", and its companion rule that
    // an observer must not rebuild a page that is not on screen). Two things
    // made that expensive out of all proportion to a theme change:
    //
    //   1. `ThemeManager.observe`'s closure fires **synchronously at
    //      registration** and again on anything that re-pushes the same
    //      palette, so most calls here changed nothing at all and rebuilt
    //      everything anyway.
    //   2. The crew chat is one of twenty-seven destinations and stays mounted
    //      for the process's life (GL-37). A theme change rebuilt its entire
    //      transcript - every markdown block, every confirm card, every
    //      handoff row - whether or not that page was the one on screen.
    //
    // **What this deliberately does not do is repaint each block in place.**
    // That is the shape GL-24 actually asks for, and it is a bigger change
    // than it looks: `StrawHatConfirmCard`, `StrawHatHandoffRow`, the
    // attribution header and every `SRELeadMarkdown` block kind bake their
    // colours at construction and expose no repaint seam, so giving them one
    // means touching all of them - and a colour missed on the way is the
    // "half-themed" defect this project has already shipped four times. What
    // is here removes the cost for a no-op call and for a hidden page, and
    // leaves exactly one rebuild for a real theme change on the page the
    // captain is looking at.
    private var appliedThemeID: String?
    private var transcriptNeedsRebuildForTheme = false

    private var isOnScreenForTheme: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        rebuildTranscriptIfThemeChangedWhileHidden()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildTranscriptIfThemeChangedWhileHidden()
    }

    private func rebuildTranscriptIfThemeChangedWhileHidden() {
        guard transcriptNeedsRebuildForTheme, isOnScreenForTheme else { return }
        transcriptNeedsRebuildForTheme = false
        rebuildTranscript()
    }

    func applyTheme(_ theme: HelmTheme) {
        let themeChanged = appliedThemeID != theme.id
        appliedThemeID = theme.id
        self.theme = theme
        dataFootnote.textColor = HelmTheme.mutedInk(theme)
        // `chromeBackgroundHex`, not `backgroundHex` - the latter is the
        // *terminal's* token. `SRELeadChatView` shipped that exact mix-up once
        // and it rendered as "a large black empty area"; see its `applyTheme`.
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        // This page's own hue, not Overview's - a leftover from when the crew
        // chat was a tab on `FleetController`'s page, before
        // `fm/polish-straw-hat-overview-card-and-voice-c8d3` gave it a
        // destination of its own. §6.9 lights a page's well with that page's
        // domain hue (which is why `SRELeadChatView` uses Console's), and
        // `RailDestination.domainHue`'s own comment already names violet as
        // "what the page's focus ring and primary button take". The well
        // paints everything else - its fill, prompt, text, cursor and
        // selection - from the terminal scheme.
        well.domainHue = theme.isDaylight ? RailDestination.strawHat.domainHue : nil
        well.applyTheme(theme)
        emptyState.applyTheme(theme)
        starterGrid.applyTheme(theme)
        crewStrip.applyTheme(theme)
        crewStripDivider.layer?.backgroundColor =
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor

        // Rebuild every block rather than re-deriving each one's role from its
        // current styling: `messages` is the source of truth and styling is a
        // pure function of it. Same call `SRELeadChatView.applyTheme` makes -
        // but through `rebuildTranscript()`, never `clearMessages()`, which
        // would also forget which proposals the captain has already confirmed
        // (see `proposalResolutions`).
        //
        // PF10: only when the palette actually moved, and only for a page on
        // screen. A hidden page remembers that it owes one and pays it when it
        // is next shown, so it can never be seen in the old theme.
        guard themeChanged else { return }
        guard isOnScreenForTheme else {
            transcriptNeedsRebuildForTheme = true
            return
        }
        transcriptNeedsRebuildForTheme = false
        rebuildTranscript()
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// X11: the data-transparency line under the composer, and where it sits.
    ///
    /// `isMounted` rather than a size check, and the reason is measured (X9
    /// hit it in the notification panel): `NSTextField(labelWithString:)`
    /// sizes itself at init, so a label built and never added to the tree
    /// still reports a perfectly good non-zero `frame`.
    var debugDataFootnote: (text: String, frame: NSRect, isMounted: Bool) {
        (dataFootnote.stringValue, dataFootnote.frame, dataFootnote.isDescendant(of: self))
    }
    var debugComposerFrame: NSRect { well.frame }
    var debugComposerWrapFrame: NSRect { composerWrap.frame }
    var debugDataFootnoteFittingWidth: CGFloat { dataFootnote.fittingSize.width }

    /// PF10: the transcript's own block views, so a suite can tell a repaint
    /// from a rebuild by object identity.
    var debugTranscriptBlocks: [NSView] { stack.arrangedSubviews }
    /// PF10: whether a theme change landed while this page was off screen and
    /// is still owed.
    var debugTranscriptRebuildIsOwed: Bool { transcriptNeedsRebuildForTheme }

    /// Every message's rendered text, in order - lets the view suite assert
    /// what the transcript actually holds without reaching into AppKit.
    func debugMessageTexts() -> [String] {
        messages.map {
            switch $0 {
            case .captain(let t), .status(let t), .error(let t): return t
            case .crew(let section): return section.text
            }
        }
    }

    /// The speaker names shown on reply blocks, in order. An unattributed
    /// (rung-2) section reports `"-"` rather than being skipped, so a suite
    /// can tell "no header was rendered" from "no block was rendered".
    func debugCrewSpeakers() -> [String] {
        messages.compactMap {
            if case .crew(let section) = $0 { return section.speaker?.displayName ?? "-" }
            return nil
        }
    }

    /// Every confirm card currently in the transcript, in order - the only way
    /// a suite can press the real button on the real card.
    /// Every handoff link row currently in the transcript, in order.
    func debugHandoffRows() -> [StrawHatHandoffRow] {
        var found: [StrawHatHandoffRow] = []
        func walk(_ view: NSView) {
            if let row = view as? StrawHatHandoffRow { found.append(row) }
            view.subviews.forEach(walk)
        }
        walk(stack)
        return found
    }

    func debugConfirmCards() -> [StrawHatConfirmCard] {
        var found: [StrawHatConfirmCard] = []
        func walk(_ view: NSView) {
            if let card = view as? StrawHatConfirmCard { found.append(card) }
            view.subviews.forEach(walk)
        }
        stack.arrangedSubviews.forEach(walk)
        return found
    }

    var debugCrewStrip: StrawHatCrewStrip { crewStrip }

    var debugMessageCount: Int { messages.count }
    var debugEmptyStateHidden: Bool { emptyState.isHidden }
    var debugStarterGrid: StrawHatStarterGrid { starterGrid }
    /// The empty state's real frame - it is a sibling of the scroll view
    /// filling the whole transcript area, so it should be tall, not a card
    /// stranded at the top (which is what it was before a real render caught
    /// it).
    var debugEmptyStateFrame: NSRect { emptyState.frame }
    /// The transcript stack's leading edge inside this view - proves the
    /// message cards are inset from the bordered card's own edge rather than
    /// flush against it.
    var debugTranscriptLeadingInset: CGFloat { convert(stack.bounds, from: stack).minX }
    /// The composer well's leading edge inside this view, same reason.
    var debugComposerLeadingInset: CGFloat { convert(well.bounds, from: well).minX }

    /// The terminal-prompt well itself, for `ConsolePopoversSelfTest.
    /// checkPromptWell`, the check Compose and SRE Lead already answer to.
    var debugWell: HelmPromptWell { well }

    /// The whole well's height, so a suite can see it grow with real text.
    var debugComposerHeight: CGFloat { well.frame.height }

    /// The send button's frame inside the well, so a suite can assert it sits
    /// on the prompt line rather than in a strip of its own.
    var debugSendButtonFrameInWell: NSRect { well.convert(sendButton.bounds, from: sendButton) }

    /// The view rendered for the last appended message, so a suite can measure
    /// real, laid-out geometry inside a reply block.
    var debugLastBlockView: NSView? { stack.arrangedSubviews.last }
    var debugSendEnabled: Bool { sendButton.isEnabled }
    var debugInputEnabled: Bool { isInputEnabled }
    var debugSendButton: HelmButton { sendButton }

    /// Types into the real text view through the real delegate path, so the
    /// send button's enablement is driven exactly as a keystroke would.
    func debugType(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// The composer's current text - proves a submit really cleared it.
    var debugComposerText: String { textView.string }
    #endif
}

/// UX-08: the empty thread's starters, two to a row: a sparkle and the
/// question, the detail under it. A card is a `HoverHighlightView` (GL-16),
/// and picking one fills the composer.
final class StrawHatStarterGrid: NSView {
    private(set) var starters: [StrawHatStarters.Starter] = []
    var onPick: ((StrawHatStarters.Starter) -> Void)?
    private let grid = NSStackView()
    private var cards: [(view: HoverHighlightView, question: NSTextField, detail: NSTextField, glyph: NSImageView)] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = HelmMetrics.s3
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Things to ask")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setStarters(_ starters: [StrawHatStarters.Starter], theme: HelmTheme) {
        guard starters != self.starters else { return }
        self.starters = starters
        for row in grid.arrangedSubviews { grid.removeArrangedSubview(row); row.removeFromSuperview() }
        cards = []
        for start in stride(from: 0, to: starters.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = HelmMetrics.s3
            row.alignment = .top
            row.translatesAutoresizingMaskIntoConstraints = false
            for starter in starters[start..<min(start + 2, starters.count)] {
                row.addArrangedSubview(makeCard(starter))
            }
            if starters.count - start == 1 { row.addArrangedSubview(NSView()) }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        applyTheme(theme)
    }

    private func makeCard(_ starter: StrawHatStarters.Starter) -> NSView {
        let card = HoverHighlightView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = HelmMetrics.rRow
        card.accessibilityRoleOverride = .button
        card.accessibilityLabelOverride = "\(starter.question). \(starter.detail)"
        let glyph = NSImageView(image: HelmSymbol.image("sparkle", pointSize: HelmType.scaled(11), weight: .semibold) ?? NSImage())
        let question = NSTextField(wrappingLabelWithString: starter.question)
        question.font = .systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        question.maximumNumberOfLines = 2
        let detail = NSTextField(labelWithString: starter.detail)
        detail.font = HelmType.caption()
        detail.lineBreakMode = .byTruncatingTail
        for view in [glyph, question, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        question.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = HelmMetrics.s3 + 2
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            glyph.heightAnchor.constraint(equalToConstant: Self.glyphSide),
            // Gotcha (23): no baseline tie in a view that can be hidden.
            glyph.topAnchor.constraint(equalTo: question.topAnchor, constant: 3),
            question.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: HelmMetrics.s1 + 2),
            question.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            question.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            detail.leadingAnchor.constraint(equalTo: glyph.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -inset),
            detail.topAnchor.constraint(equalTo: question.bottomAnchor, constant: 2),
            detail.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
        let index = cards.count
        // GL-16: the click recognizer is also Return, Space and VoiceOver's press.
        card.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:))))
        card.identifier = NSUserInterfaceItemIdentifier("starter-\(index)")
        cards.append((card, question, detail, glyph))
        return card
    }

    static let glyphSide: CGFloat = 12

    @objc private func cardClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue, let index = Int(id.dropFirst("starter-".count)),
              starters.indices.contains(index) else { return }
        onPick?(starters[index])
    }

    override func layout() {
        super.layout()
        // Gotcha (22): the question wraps at its card's width, less its insets.
        for card in cards {
            let width = max(80, card.view.bounds.width - 2 * (HelmMetrics.s3 + 2) - 18)
            if abs(card.question.preferredMaxLayoutWidth - width) > 0.5 { card.question.preferredMaxLayoutWidth = width }
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        for card in cards {
            HelmCard.applyCardSurface(to: card.view, theme: theme, cornerRadius: HelmMetrics.rRow,
                                      daylightRadius: HelmMetrics.rRow)
            // The hover view paints its own fill, so it is handed the card's.
            let fill = HelmTheme.nsColor(theme.chromeBackgroundHex)
            card.view.normalColor = fill
            card.view.hoverColor = fill.blended(withFraction: 0.06, of: HelmTheme.nsColor(theme.accentHex)) ?? fill
            card.question.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            card.detail.textColor = HelmTheme.mutedInk(theme)
            card.glyph.contentTintColor = HelmTheme.nsColor(theme.chromeInkHex)
        }
    }

    #if FM_SELFTESTS
    func debugPick(_ index: Int) { if starters.indices.contains(index) { onPick?(starters[index]) } }
    var debugCards: [HoverHighlightView] { cards.map(\.view) }
    #endif
}
