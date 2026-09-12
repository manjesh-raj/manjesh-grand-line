// Manjesh Grand Line - native macOS app.
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
//  - `HelmComposerCard` (the focus-glowing sunken well), `HelmAccentRow` (the
//    accent-bar + badge + kicker card), `IconTileView`, `HelmButton`,
//    `HelmEmptyState`, `HelmType`, `HelmMetrics`, `HelmField`, `HelmSelection`.
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
    // A rounded, single-surface pill rather than `SRELeadChatView.
    // buildComposer`'s text-box-plus-toolbar-strip shape. The two composers
    // were never a shared component (each view hand-rolls its own `HelmComposerCard`
    // instance and its own text view - see this file's header), so this
    // redesign is scoped to this file alone: nothing here touches
    // `SRELeadChatView.swift`, and its own composer is unaffected.
    //
    // The captain's complaint (a screenshot of the old shape) was threefold:
    // a plain bordered box, raw keybinding text ("\u{21B5} to send \u{00B7} \u{21E7}\u{21B5}
    // for a new line") competing for attention below the field, and a small
    // square send button sitting in its own separate strip. The fix is
    // structural, not just a bigger corner radius: the text field and the
    // send button now live in one `NSStackView` row inside the same rounded
    // surface, bottom-aligned so the button tracks the text box's own bottom
    // edge as it grows - the same shape iMessage/WhatsApp/ChatGPT's input
    // bars use - and the keybinding hint moved to a tooltip instead of a
    // permanently-visible label.
    private let composerWrap = NSView()
    private let composerCard = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    /// `NSTextView` has no placeholder API - a muted label overlaid at the
    /// text container's inset, toggled on every edit.
    private let textPlaceholderLabel = NSTextField(labelWithString: "Message the crew\u{2026}")
    private let sendButton = HelmButton(symbol: "arrow.up", variant: .primary, size: .small)

    private var textScrollHeightConstraint: NSLayoutConstraint!

    /// The keybinding hint, now a tooltip rather than a permanent label -
    /// still discoverable on hover, no longer a strip of text competing with
    /// the send button for attention.
    private static let keybindingHint = "\u{21B5} to send  \u{00B7}  \u{21E7}\u{21B5} for a new line"

    /// A noticeably rounder pill than the app's generic `rRow` token, chosen
    /// for this one surface: with the toolbar strip gone, the composer is a
    /// single unbroken shape now, and a bigger radius is what actually reads
    /// as "pill" rather than "rounded rectangle" at the field's minimum
    /// height. Daylight keeps its own established `dWell` token unchanged -
    /// every other Daylight "well" (Console's composer, SRE Lead's,
    /// Whiteboard's) already uses it, and diverging here would make this the
    /// one composer in the app with a different Daylight radius for no
    /// reason.
    private static let composerCornerRadius: CGFloat = 18

    private static let minTextHeight: CGFloat = 34
    private static let maxTextHeight: CGFloat = 120

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
        ])
    }

    private func buildComposer() {
        composerWrap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composerWrap)

        composerCard.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(composerCard)

        buildTextView()
        buildSendButton()

        // One horizontal row, not a text box stacked over a toolbar strip:
        // the field and the button share the same rounded surface, and
        // `.bottom` alignment keeps the button pinned to the field's own
        // bottom edge as it grows - the shape a modern chat input uses.
        //
        // AGENTS.md gotcha (10): a horizontal `NSStackView` left at its
        // default `.gravityAreas` distribution ignores hugging/compression
        // priorities entirely, so `.fill` has to be set explicitly or
        // `textScroll`'s "grow to fill" priority below does nothing.
        let inputRow = NSStackView(views: [textScroll, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .bottom
        inputRow.distribution = .fill
        inputRow.spacing = HelmMetrics.s2
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        composerCard.contentContainer.addSubview(inputRow)

        textScrollHeightConstraint = textScroll.heightAnchor.constraint(equalToConstant: Self.minTextHeight)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Below the crew strip, not at this view's own top edge.
            scroll.topAnchor.constraint(equalTo: crewStripDivider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: composerWrap.topAnchor),

            composerWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerWrap.bottomAnchor.constraint(equalTo: bottomAnchor),

            composerCard.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: Self.contentInset),
            composerCard.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -Self.contentInset),
            composerCard.topAnchor.constraint(equalTo: composerWrap.topAnchor, constant: HelmMetrics.s2),
            composerCard.bottomAnchor.constraint(equalTo: composerWrap.bottomAnchor, constant: -Self.contentInset),

            // The row - and therefore the whole rounded surface - is sized
            // bottom-up from `textScroll`'s own dynamic height; nothing here
            // gives `composerCard` a height of its own.
            inputRow.leadingAnchor.constraint(equalTo: composerCard.contentContainer.leadingAnchor, constant: 14),
            inputRow.trailingAnchor.constraint(equalTo: composerCard.contentContainer.trailingAnchor, constant: -8),
            inputRow.topAnchor.constraint(equalTo: composerCard.contentContainer.topAnchor, constant: 6),
            inputRow.bottomAnchor.constraint(equalTo: composerCard.contentContainer.bottomAnchor, constant: -6),
            textScrollHeightConstraint,

            // Activated here, once `textScroll` is in the real tree - see
            // `SRELeadChatView.buildComposer`'s own note on the measured
            // layout bug that ordering caused there.
            textPlaceholderLabel.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 9),
            textPlaceholderLabel.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 9),
            textPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textScroll.trailingAnchor, constant: -9),
        ])
    }

    private func buildTextView() {
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = HelmType.body()
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.delegate = self
        // Phase 0's D1 fix: focus is sensed from the window's first responder,
        // never from `textDidBeginEditing` (which only fires on the first
        // keystroke, so a captain clicking in would see nothing).
        composerCard.senseFocus(on: textView)

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        // The one flexible element in `inputRow` - everything else
        // (`sendButton`) is fixed-size, so this is what absorbs the row's
        // leftover width under `.fill` distribution.
        textScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textScroll.toolTip = Self.keybindingHint

        textPlaceholderLabel.font = textView.font
        textPlaceholderLabel.isEditable = false
        textPlaceholderLabel.isBordered = false
        textPlaceholderLabel.isSelectable = false
        textPlaceholderLabel.drawsBackground = false
        textPlaceholderLabel.lineBreakMode = .byTruncatingTail
        textPlaceholderLabel.maximumNumberOfLines = 1
        // AGENTS.md gotcha (13): an `NSTextField` defaults to 750 horizontal
        // compression resistance, which is above
        // `NSLayoutPriorityWindowSizeStayPut` (500) - so its intrinsic width
        // would become a floor for the whole window through
        // textScroll -> card -> composer -> this view -> `bodyContainer`.
        // Short placeholder text makes that floor small rather than absent,
        // and "small" is not the property worth relying on.
        textPlaceholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textScroll.addSubview(textPlaceholderLabel)
    }

    /// The send button - fixed size, held at the trailing edge of `inputRow`
    /// by that row's own `.fill` distribution and required hugging below, so
    /// it never shrinks or grows past its own natural size regardless of how
    /// much room the text box takes.
    private func buildSendButton() {
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.target = self
        sendButton.action = #selector(submit)
        sendButton.isEnabled = false
        sendButton.toolTip = Self.keybindingHint
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // `HelmPageToolbar.iconButton`'s alignment-rect correction: a
        // `HelmButton` paints its chrome in its own layer, which fills the
        // *frame*, while Auto Layout constrains its *alignment rect* - so a
        // plain height constraint renders a visibly taller box. Slightly
        // larger than the old 28pt square (a more tactile, "this is the
        // thing you press" size once it sits beside the text rather than in
        // its own thin strip).
        let side: CGFloat = 32
        let insets = sendButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: side - insets.left - insets.right),
            sendButton.heightAnchor.constraint(equalToConstant: side - insets.top - insets.bottom),
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
    /// One caller today - `StrawHatController.startNewConversation(with:)`'s
    /// turn-already-in-flight branch (the review's L7), which hands the
    /// captain their own message back rather than dropping it.
    func setComposerText(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func updateEmptyState() {
        emptyState.isHidden = !messages.isEmpty
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
            "\u{26A0} \(plural) \u{2014} the crew isn't allowed to do that yet.")
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
            bullet.font = .systemFont(ofSize: 7)
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
        textView.string = ""
        updateTextPlaceholderVisibility()
        updateTextViewHeight()
        updateSendButtonEnabled()
        onSubmit?(text)
    }

    func textDidChange(_ notification: Notification) {
        updateTextPlaceholderVisibility()
        updateTextViewHeight()
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

    private func updateTextPlaceholderVisibility() {
        textPlaceholderLabel.isHidden = !textView.string.isEmpty
    }

    private func updateTextViewHeight() {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let desired = ceil(used) + textView.textContainerInset.height * 2
        let clamped = min(max(desired, Self.minTextHeight), Self.maxTextHeight)
        guard abs(clamped - textScrollHeightConstraint.constant) > 0.5 else { return }
        textScrollHeightConstraint.constant = clamped
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        HelmSelection.apply(to: textView, theme: theme)
        // `chromeBackgroundHex`, not `backgroundHex` - the latter is the
        // *terminal's* token. `SRELeadChatView` shipped that exact mix-up once
        // and it rendered as "a large black empty area"; see its `applyTheme`.
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        composerCard.domainHue = theme.isDaylight ? RailDestination.overview.domainHue : nil
        composerCard.cornerRadius = theme.isDaylight ? HelmMetrics.dWell : Self.composerCornerRadius
        composerCard.applyTheme(theme)
        let ink = HelmField.ink(theme)
        textView.textColor = ink
        textView.insertionPointColor = ink
        textPlaceholderLabel.textColor = HelmField.mutedInk(theme)
        emptyState.applyTheme(theme)
        crewStrip.applyTheme(theme)
        crewStripDivider.layer?.backgroundColor =
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor

        // Rebuild every block rather than re-deriving each one's role from its
        // current styling: `messages` is the source of truth and styling is a
        // pure function of it. Same call `SRELeadChatView.applyTheme` makes -
        // but through `rebuildTranscript()`, never `clearMessages()`, which
        // would also forget which proposals the captain has already confirmed
        // (see `proposalResolutions`).
        rebuildTranscript()
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
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
    /// The empty state's real frame - it is a sibling of the scroll view
    /// filling the whole transcript area, so it should be tall, not a card
    /// stranded at the top (which is what it was before a real render caught
    /// it).
    var debugEmptyStateFrame: NSRect { emptyState.frame }
    /// The transcript stack's leading edge inside this view - proves the
    /// message cards are inset from the bordered card's own edge rather than
    /// flush against it.
    var debugTranscriptLeadingInset: CGFloat { convert(stack.bounds, from: stack).minX }
    /// The composer card's leading edge inside this view, same reason.
    var debugComposerLeadingInset: CGFloat { convert(composerCard.bounds, from: composerCard).minX }
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
