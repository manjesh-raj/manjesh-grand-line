// Grand Line - native macOS app.
//
// The SRE Lead pane's native message feed - replaces the tmux-mirrored
// interactive `claude` TUI (raw ANSI chrome, permission-mode banner,
// box-drawing borders) with a plain scrollable stack of message blocks plus
// a single-line input field, matching this app's existing visual language
// (`HelmTheme`, `HelmUIComponents.swift`'s hover/tint helpers) instead of
// showing someone else's CLI. See `SRELead.swift`'s header and the AGENTS.md
// "SRE Lead" bullet for why this replaced the terminal-based pane.
//
// This view knows nothing about `claude`, MCP, or the bridge - it only
// renders `SRELeadMessage` values `ConsoleController` appends (from
// `SRELeadRunner`'s callbacks) and reports submitted text via `onSubmit`.
//
// `fm/cockpit-sre-lead-reply-formatting`: an assistant message used to be one
// plain `NSTextField(wrappingLabelWithString:)` - no bold, no code, no lists,
// even when the reply text already contained that markdown, which was the
// captain's exact complaint ("no highlights, no bold, no blocks"). An
// assistant message's text is now parsed by `SRELeadMarkdown.parse` into
// blocks (paragraph/bulletList/codeBlock/callout) and each block gets its own
// small AppKit view - see `renderBlock(_:)` below. User/status/error messages
// carry no markdown (a captain's own typed question, or a short internal
// status/error string), so they render as plain text.
//
// `fm/grandline-sre-lead-chat-redesign`: a visual-quality-bar pass (see
// `data/grandline-sre-lead-chat-redesign/` for the captain's reference) that
// gave every message type a considered card treatment - see `accentCard(_:)`,
// `sectionLabel(_:)`, and `assistantBlock(for:)`'s header - without touching
// what SRE Lead says or how the Finding/Recommended-next-action contract is
// parsed (`SRELeadMarkdown.swift`, `SRELead.persona`). New structured fields
// like the reference's severity/downtime/confidence chips were deliberately
// NOT added - that's a behavior change to the persona's required output, not
// a rendering change, and needs its own explicit sign-off.
//
// `fm/grandline-popover-redesign` (Sre-2 of the console popovers board,
// `data/grand-line-console-popovers-sre-mockups/`): the pane reads as a chat
// thread. A question is a right-aligned accent bubble under "You · 10:42". An
// answer is one card beside the sparkle tile, with its Finding and its
// Recommended next action as sections separated by hairlines and a coloured
// dot in each kicker, rather than accent cards nested inside a bordered
// container. A Finding longer than six lines collapses with Show more, a code
// block has Copy, and the answer's foot says how long it took and offers Copy
// answer. While a turn runs a working card shows the elapsed time and the
// send button becomes Stop. An error offers Try again, which asks the last
// question again. Starter and follow-up questions sit in a chip row above a
// rounded pill composer; a chip fills the composer and never sends.
//
// The runner still answers in one piece (`claude -p --output-format json`),
// so there is no streamed text: the working card is what a turn shows until
// the reply arrives. Streaming needs `SRELeadRunner` on `stream-json`, which
// its header chose not to do; that is a follow-up, not part of this pass.

import AppKit

struct SRELeadMessage {
    enum Role { case user, assistant, status, error }
    let role: Role
    let text: String
    /// How long an answer took, for its foot ("18s"). `nil` for anything else.
    var elapsed: TimeInterval? = nil
    /// When the message was added, for a question's "You · 10:42".
    var date: Date = Date()
    /// An error from a turn, which Try again can ask again. A postmortem
    /// failure is not one: the header button is its retry.
    var retryable: Bool = false
}

final class SRELeadChatView: NSView, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    /// Sre-2: the send button's Stop, while a turn runs.
    var onStop: (() -> Void)?
    /// Sre-2: an error card's Try again - asks the last question again.
    var onRetry: (() -> Void)?

    /// Fired whenever `messages` changes (append or clear) - "Generate
    /// Postmortem"'s visibility (`ConsoleController.updateGeneratePostmortemButton`)
    /// depends on `hasRealExchange`, which only this view can evaluate.
    var onMessagesChanged: (() -> Void)?

    /// The host the empty state names ("Ask about DEV Bastion").
    var hostLabel = "this cluster" {
        didSet { if hostLabel != oldValue { emptyTitle.stringValue = "Ask about \(hostLabel)" } }
    }

    // MARK: Geometry

    /// The pane is a fixed 380pt and its card 368pt (`ConsoleController.
    /// sreLeadPaneWidth`), so a wrapping label's width is known without
    /// asking its own frame (gotcha (22)).
    static let threadInset: CGFloat = HelmMetrics.s3
    static let paneCardWidth: CGFloat = 368
    static let answerTileSide: CGFloat = 24
    static let bubbleWidthFraction: CGFloat = 0.84
    static let cardPadding: CGFloat = HelmMetrics.s3
    /// A Finding longer than this collapses behind Show more.
    static let collapsedLines = 6
    static let composerRadius: CGFloat = 18
    static let sendSide: CGFloat = 28
    static var threadWidth: CGFloat { paneCardWidth - 2 * threadInset }
    static var answerTextWidth: CGFloat {
        threadWidth - answerTileSide - HelmMetrics.s2 - 2 * cardPadding
    }
    static var bubbleTextWidth: CGFloat { (threadWidth * bubbleWidthFraction).rounded(.down) - 2 * cardPadding }

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()

    // Empty state.
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "Ask about this cluster")
    private let emptyBody = NSTextField(wrappingLabelWithString: "Answers come back with a Finding and a next action.")

    // Working card.
    private var workingCard: SRELeadWorkingCard?
    private var workingSince: Date?

    // Suggested questions.
    private let chipsFlow = ChipFlowView(frame: .zero)
    private var chipButtons: [HelmButton] = []
    private var chipQuestions: [String] = []
    /// Shown before the first question, to start somewhere.
    static let starterQuestions: [(label: String, question: String)] = [
        ("Why are pods restarting?", "Why are pods restarting?"),
        ("What changed?", "What changed in the last hour?"),
        ("Node pressure", "Is any node under memory or disk pressure?"),
    ]
    /// Shown under an answer, to go one step further.
    static let followUpQuestions: [(label: String, question: String)] = [
        ("Recent events", "Show the most recent warning events in this namespace."),
        ("Describe the deployment", "Describe the deployment behind this."),
        ("Compare replicas", "Compare the replicas - is one behaving differently?"),
    ]

    // MARK: Composer

    private let composerWrap = NSView()
    private let composerKicker = NSTextField(labelWithString: "Ask a question")
    private let composerCard = HelmComposerCard(cornerRadius: SRELeadChatView.composerRadius)
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let textPlaceholderLabel = NSTextField(labelWithString: "Ask SRE Lead\u{2026}")
    private let sendButton = HelmButton(symbol: "arrow.up", variant: .primary, size: .small)
    private var textScrollHeightConstraint: NSLayoutConstraint!

    private static let minTextHeight: CGFloat = 34
    private static let maxTextHeight: CGFloat = 120

    /// Whether the composer may take input at all right now - independent of
    /// whether it holds text. Send is enabled only when both are true.
    private var isInputEnabled = true

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var messages: [SRELeadMessage] = []
    /// What each Copy button in the thread copies, and each Show more's
    /// label - keyed by the button, rebuilt with the thread.
    private var copyTexts: [ObjectIdentifier: String] = [:]
    private var expandLabels: [ObjectIdentifier: NSTextField] = [:]
    private var copyResets: [ObjectIdentifier: DispatchWorkItem] = [:]
    static let collapsedTitle = "Show more"
    static let expandedTitle = "Show less"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildScroll()
        buildEmptyState()
        buildComposer()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildScroll() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.threadInset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.threadInset),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.threadInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Self.threadInset),
            // Gotcha (4): the clip view, never the scroll view.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    /// Before the first question: what this pane is for, centred in the
    /// thread.
    private func buildEmptyState() {
        emptyTitle.font = .systemFont(ofSize: HelmType.scaled(14), weight: .semibold)
        emptyTitle.alignment = .center
        emptyBody.font = HelmType.caption()
        emptyBody.alignment = .center
        emptyBody.preferredMaxLayoutWidth = Self.threadWidth - 2 * HelmMetrics.s5
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = HelmMetrics.s1
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptyBody)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: HelmMetrics.s5),
        ])
    }

    /// The composer: the chip row, a small kicker, and a rounded pill well
    /// holding the auto-growing text view and the send button.
    private func buildComposer() {
        composerWrap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composerWrap)

        composerKicker.attributedStringValue = NSAttributedString(
            string: "Ask a question".uppercased(), attributes: [.font: HelmType.kicker(), .kern: HelmType.kickerKern])
        composerCard.surface = .raised

        buildTextView()
        sendButton.toolTip = AITransparency.willSendToClaude("your question and the cluster output it reads")
        sendButton.setAccessibilityLabel("Send")
        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        sendButton.isEnabled = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        composerCard.contentContainer.addSubview(textScroll)
        composerCard.contentContainer.addSubview(sendButton)

        let composerStack = NSStackView(views: [chipsFlow, composerKicker, composerCard])
        composerStack.orientation = .vertical
        composerStack.alignment = .leading
        composerStack.spacing = HelmMetrics.s2
        composerStack.setCustomSpacing(HelmMetrics.s1 + HelmMetrics.s0, after: composerKicker)
        composerStack.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(composerStack)

        let rule = NSView()
        rule.wantsLayer = true
        rule.identifier = NSUserInterfaceItemIdentifier("sre.composer.rule")
        rule.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(rule)

        textScrollHeightConstraint = textScroll.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        // The same alignment-rect correction `HelmPageToolbar.iconButton`
        // uses, so the button measures `sendSide` square.
        let insets = sendButton.alignmentRectInsets
        let container = composerCard.contentContainer
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: composerWrap.topAnchor),

            composerWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerWrap.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor),
            rule.topAnchor.constraint(equalTo: composerWrap.topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            composerStack.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: HelmMetrics.s3),
            composerStack.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -HelmMetrics.s3),
            composerStack.topAnchor.constraint(equalTo: composerWrap.topAnchor, constant: HelmMetrics.s3 - 2),
            composerStack.bottomAnchor.constraint(equalTo: composerWrap.bottomAnchor, constant: -HelmMetrics.s3),
            chipsFlow.widthAnchor.constraint(equalTo: composerStack.widthAnchor),
            composerCard.widthAnchor.constraint(equalTo: composerStack.widthAnchor),

            textScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: HelmMetrics.s1),
            textScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s0),
            textScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s0),
            textScroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -HelmMetrics.s1),
            textScrollHeightConstraint,
            sendButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(HelmMetrics.s1 + 1)),
            sendButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -(HelmMetrics.s1 + 1)),
            sendButton.widthAnchor.constraint(equalToConstant: Self.sendSide - insets.left - insets.right),
            sendButton.heightAnchor.constraint(equalToConstant: Self.sendSide - insets.top - insets.bottom),
        ])
    }

    /// The auto-growing text view. Plain Return sends and Shift-Return
    /// inserts a new line, as before.
    private func buildTextView() {
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = HelmType.body()
        textView.textContainerInset = NSSize(width: HelmMetrics.s2, height: HelmMetrics.s2 + 1)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // The card's own layer paints the well; the text view shows it through.
        textView.drawsBackground = false
        textView.delegate = self
        composerCard.senseFocus(on: textView)

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        textPlaceholderLabel.font = textView.font
        textPlaceholderLabel.lineBreakMode = .byTruncatingTail
        textPlaceholderLabel.maximumNumberOfLines = 1
        // A subview of the text view at its own text origin, so it never
        // drifts from where the first typed character lands.
        textView.addSubview(textPlaceholderLabel)
    }

    // MARK: Messages

    func append(_ message: SRELeadMessage) {
        messages.append(message)
        let block = messageBlock(for: message, isLatest: true)
        stack.addArrangedSubview(block)
        block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let workingCard {
            // The working card stays the last thing in the thread.
            stack.removeArrangedSubview(workingCard)
            stack.addArrangedSubview(workingCard)
        }
        refreshThreadChrome()
        scrollToBottom()
        onMessagesChanged?()
    }

    func clearMessages() {
        messages.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        copyTexts = [:]
        expandLabels = [:]
        workingCard = nil
        if let workingSince { setWorking(since: workingSince) }
        refreshThreadChrome()
        onMessagesChanged?()
    }

    /// "Generate Postmortem" is only offered once an investigation has
    /// produced real content - a bare "SRE Lead is ready" status message with
    /// no actual question asked yet doesn't count.
    var hasRealExchange: Bool {
        messages.contains { $0.role == .assistant }
    }

    /// The investigation transcript so far, as plain question/answer text -
    /// `SRELeadPostmortem.generate`'s prompt input. Only user/assistant turns
    /// are investigation content; status and error lines are this pane's own
    /// chrome.
    var transcriptForPostmortem: String {
        messages.compactMap { message -> String? in
            switch message.role {
            case .user: return "Captain: \(message.text)"
            case .assistant: return "SRE Lead: \(message.text)"
            case .status, .error: return nil
            }
        }.joined(separator: "\n\n")
    }

    /// `fm/grandline-sre-lead-per-tab`: the exact text of every message in
    /// this chat, in order.
    func debugMessageTexts() -> [String] { messages.map { $0.text } }

    /// Disables input while a turn is in flight - `SRELeadRunner` is not
    /// built to handle concurrent `ask` calls.
    func setInputEnabled(_ enabled: Bool) {
        isInputEnabled = enabled
        textView.isEditable = enabled
        updateComposerState()
    }

    /// Sre-2: a turn started at `since`, or `nil` when it ended. Shows or
    /// removes the working card, and turns the send button into Stop.
    func setWorking(since: Date?) {
        workingSince = since
        if let since {
            if workingCard == nil {
                let card = SRELeadWorkingCard()
                card.applyTheme(theme)
                workingCard = card
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            workingCard?.start(since: since)
            scrollToBottom()
        } else if let workingCard {
            workingCard.stop()
            workingCard.removeFromSuperview()
            self.workingCard = nil
        }
        updateComposerState()
        refreshThreadChrome()
    }

    private var isWorking: Bool { workingSince != nil }

    /// The send button: grey with nothing to send, the accent with text, and
    /// Stop while a turn runs. The placeholder says which.
    private func updateComposerState() {
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isWorking {
            sendButton.symbolName = "stop.fill"
            sendButton.toolTip = "Stop SRE Lead"
            sendButton.setAccessibilityLabel("Stop")
            sendButton.isEnabled = true
        } else {
            sendButton.symbolName = "arrow.up"
            sendButton.toolTip = AITransparency.willSendToClaude("your question and the cluster output it reads")
            sendButton.setAccessibilityLabel("Send")
            sendButton.isEnabled = isInputEnabled && hasText
        }
        textPlaceholderLabel.stringValue = isWorking ? "SRE Lead is working\u{2026}" : "Ask SRE Lead\u{2026}"
        textPlaceholderLabel.isHidden = !textView.string.isEmpty
        placePlaceholder()
    }

    /// The placeholder where the text view draws its first character. Also
    /// run after every layout pass: before the first one the text view has
    /// not worked out its container origin yet.
    private func placePlaceholder() {
        let origin = textView.textContainerOrigin
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let size = textPlaceholderLabel.fittingSize
        textPlaceholderLabel.frame = NSRect(x: origin.x + padding - 2, y: origin.y, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        placePlaceholder()
    }

    /// Whether the thread has anything the captain or SRE Lead said in it.
    private var hasConversation: Bool {
        messages.contains { $0.role != .status }
    }

    /// The empty state, and the chip row: starter questions before the first
    /// one, follow-ups after an answer, nothing while a turn runs or after an
    /// error.
    private func refreshThreadChrome() {
        let conversation = hasConversation || isWorking
        emptyState.isHidden = conversation
        stack.isHidden = !conversation
        let suggestions: [(label: String, question: String)]
        if isWorking || !isInputEnabled {
            suggestions = []
        } else if !hasConversation {
            suggestions = Self.starterQuestions
        } else if messages.last(where: { $0.role != .status })?.role == .assistant {
            suggestions = Self.followUpQuestions
        } else {
            suggestions = []
        }
        guard suggestions.map(\.question) != chipQuestions else { return }
        chipQuestions = suggestions.map(\.question)
        chipButtons = suggestions.map { suggestion in
            let button = HelmButton(title: suggestion.label, variant: .secondary, size: .small)
            button.surface = .raised
            button.toolTip = "Fill the question box with \u{201C}\(suggestion.question)\u{201D}"
            button.target = self
            button.action = #selector(chipClicked(_:))
            return button
        }
        chipsFlow.setChips(chipButtons)
        chipsFlow.isHidden = chipButtons.isEmpty
    }

    @objc private func chipClicked(_ sender: HelmButton) {
        guard let index = chipButtons.firstIndex(where: { $0 === sender }) else { return }
        textView.string = chipQuestions[index]
        textDidChange(Notification(name: NSText.didChangeNotification))
        window?.makeFirstResponder(textView)
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func messageBlock(for message: SRELeadMessage, isLatest: Bool) -> NSView {
        switch message.role {
        case .assistant: return assistantBlock(for: message)
        case .user: return userBlock(for: message)
        case .status: return statusBlock(for: message.text)
        case .error: return errorBlock(for: message)
        }
    }

    /// A question: "You · 10:42" over a right-aligned accent bubble.
    private func userBlock(for message: SRELeadMessage) -> NSView {
        let meta = NSTextField(labelWithString: "You \u{00B7} \(message.date.formatted(date: .omitted, time: .shortened))")
        meta.font = HelmType.caption()
        meta.textColor = HelmTheme.mutedInk(theme)
        let bubble = SRELeadBubbleView(text: message.text, theme: theme)
        let column = NSStackView(views: [meta, bubble])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = HelmMetrics.s1 - 1
        column.translatesAutoresizingMaskIntoConstraints = false
        bubble.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, multiplier: Self.bubbleWidthFraction).isActive = true
        return column
    }

    /// A short internal status line ("SRE Lead is ready...", "Stopped") as a
    /// centred muted label between two hairlines - this pane's own chrome,
    /// not investigation content.
    private func statusBlock(for text: String) -> NSView {
        func hairline() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return line
        }
        let label = NSTextField(wrappingLabelWithString: text)
        label.setScaledFont(ofSize: 11)
        label.textColor = HelmTheme.mutedInk(theme)
        label.alignment = .center
        // A wrapping label with no width of its own resolved to zero between
        // two flexible hairlines, which left the divider with no words.
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.threadWidth - 2 * HelmMetrics.s5,
                                                             height: .greatestFiniteMagnitude)) ?? .zero
        label.widthAnchor.constraint(equalToConstant: ceil(measured.width) + 1).isActive = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A line that wraps is centred on its own: two hairlines squeezed
        // beside two lines of words read as a rendering fault.
        let oneLine = measured.height <= ceil(label.font?.boundingRectForFont.height ?? 16) + 2
        let row = NSStackView(views: oneLine ? [hairline(), label, hairline()] : [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// A failed turn: a critical `HelmAccentRow`, with Try again when it
    /// answers a question (a postmortem failure has its own retry: the
    /// header button).
    private func errorBlock(for message: SRELeadMessage) -> NSView {
        let body = NSTextField(wrappingLabelWithString: message.text)
        body.setScaledFont(ofSize: 12.5)
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.translatesAutoresizingMaskIntoConstraints = false
        var retry: HelmButton?
        if message.retryable {
            let button = HelmButton(title: "Try again", variant: .quiet, size: .small)
            button.tint = .accent
            button.toolTip = "Ask the last question again"
            button.target = self
            button.action = #selector(retryClicked)
            retry = button
        }
        let row = HelmAccentRow(contentView: body, trailingAccessory: retry, hover: false)
        row.actionReveal = .always
        row.configure(HelmAccentRow.Content(tint: .critical, kicker: "Error",
                                            badgeSymbol: "exclamationmark.triangle.fill"), theme: theme)
        return row
    }

    @objc private func retryClicked() { onRetry?() }

    // MARK: The answer card

    /// An answer: the sparkle tile beside one card. Each callout is a section
    /// with a coloured dot in its kicker, separated from the next by a
    /// hairline; paragraphs, lists and code blocks render between them as
    /// before. The foot says how long it took and offers Copy answer.
    private func assistantBlock(for message: SRELeadMessage) -> NSView {
        let tile = IconTileView(size: Self.answerTileSide, cornerRadius: HelmMetrics.rChip)
        tile.configure(symbol: "sparkles", tint: .accent, pointSize: 11)
        tile.applyTheme(theme)

        let card = SRELeadThreadCard()
        card.applyTheme(theme)
        let sections = NSStackView()
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = HelmMetrics.s2 + 1
        sections.translatesAutoresizingMaskIntoConstraints = false
        var previousWasCallout = false
        for block in SRELeadMarkdown.parse(message.text) {
            var isCallout = false
            if case .callout = block { isCallout = true }
            if isCallout && previousWasCallout { sections.addArrangedSubview(hairline()) }
            let view = renderBlock(block)
            sections.addArrangedSubview(view)
            previousWasCallout = isCallout
        }
        sections.addArrangedSubview(answerFoot(for: message))
        for view in sections.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
        card.addSubview(sections)
        NSLayoutConstraint.activate([
            sections.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.cardPadding),
            sections.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.cardPadding),
            sections.topAnchor.constraint(equalTo: card.topAnchor, constant: HelmMetrics.s2 + 2),
            sections.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(HelmMetrics.s2 + 2)),
        ])

        let row = NSStackView(views: [tile, card])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// "18s · Copy answer".
    private func answerFoot(for message: SRELeadMessage) -> NSView {
        var parts: [NSView] = []
        if let elapsed = message.elapsed {
            let time = NSTextField(labelWithString: "Answered in \(max(1, Int(elapsed.rounded())))s")
            time.font = HelmType.caption()
            time.textColor = HelmTheme.mutedInk(theme)
            parts.append(time)
        }
        let copy = makeCopyButton(title: "Copy answer", text: message.text)
        parts.append(copy)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parts.append(spacer)
        let row = NSStackView(views: parts)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s1
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func renderBlock(_ block: SRELeadMarkdownBlock) -> NSView {
        switch block {
        case .paragraph(let runs):
            return wrappingLabel(attributedInline(runs))
        case .bulletList(let items):
            return bulletListView(items)
        case .codeBlock(let code):
            return codeBlockView(code)
        case .callout(let kind, let runs):
            return calloutSection(kind: kind, runs: runs)
        }
    }

    /// A non-editable but selectable, word-wrapping label for pre-built
    /// attributed text, wrapped at the answer card's own width.
    private func wrappingLabel(_ text: NSAttributedString, width: CGFloat = SRELeadChatView.answerTextWidth) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = true
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Inline runs as one attributed string: bold is semibold, code is
    /// monospace on a soft accent wash, everything else the base ink.
    private func attributedInline(_ runs: [SRELeadInlineRun], designedSize: CGFloat = 12.5) -> NSAttributedString {
        let baseSize = HelmType.scaled(designedSize)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let codeBackground = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink, .paragraphStyle: paragraph]
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
        list.spacing = HelmMetrics.s1 + HelmMetrics.s0
        list.translatesAutoresizingMaskIntoConstraints = false
        for item in items {
            let bullet = NSTextField(labelWithString: "\u{25CF}")
            bullet.setScaledFont(ofSize: 7)
            bullet.textColor = HelmTheme.nsColor(theme.accentHex)
            bullet.setContentHuggingPriority(.required, for: .horizontal)
            bullet.setContentCompressionResistancePriority(.required, for: .horizontal)
            let body = wrappingLabel(attributedInline(item), width: Self.answerTextWidth - HelmMetrics.s3)
            let row = NSStackView(views: [bullet, body])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = HelmMetrics.s1 + HelmMetrics.s0
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        return list
    }

    /// A fenced code block in the terminal scheme's own colours, with Copy.
    private func codeBlockView(_ code: String) -> NSView {
        let scheme = ThemeManager.shared.terminalScheme
        let fill = HelmTheme.nsColor(scheme.backgroundHex)
        let label = NSTextField(wrappingLabelWithString: code)
        label.setScaledFont(ofSize: 11, weight: .regular, voice: .monospaced)
        label.textColor = HelmTheme.nsColor(scheme.foregroundHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byCharWrapping
        label.isSelectable = true
        let copy = makeCopyButton(title: "Copy", text: code)
        copy.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = Self.answerTextWidth - 2 * HelmMetrics.s3 - copy.fittingSize.width - HelmMetrics.s1

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = HelmMetrics.rControl
        panel.layer?.backgroundColor = fill.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = (fill.blended(withFraction: 0.1, of: theme.mode == .dark ? .white : .black) ?? fill).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        panel.addSubview(copy)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: HelmMetrics.s3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: copy.leadingAnchor, constant: -HelmMetrics.s1),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: HelmMetrics.s2 + 1),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -(HelmMetrics.s2 + 1)),
            copy.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -(HelmMetrics.s1 + 2)),
            copy.topAnchor.constraint(equalTo: panel.topAnchor, constant: HelmMetrics.s1 + 2),
        ])
        return panel
    }

    /// A Finding or a Recommended next action: a kicker with a coloured dot
    /// over the body. A Finding longer than `collapsedLines` collapses
    /// behind Show more.
    private func calloutSection(kind: SRELeadCalloutKind, runs: [SRELeadInlineRun]) -> NSView {
        let tint: HelmTint = kind == .finding ? .good : .warn
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = HelmMetrics.s1 - 1
        dot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        let kicker = NSTextField(labelWithString: "")
        kicker.attributedStringValue = NSAttributedString(
            string: kind.label.uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        let kickerRow = NSStackView(views: [dot, kicker])
        kickerRow.orientation = .horizontal
        kickerRow.alignment = .centerY
        kickerRow.spacing = HelmMetrics.s1 + 1
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 2 * (HelmMetrics.s1 - 1)),
            dot.heightAnchor.constraint(equalToConstant: 2 * (HelmMetrics.s1 - 1)),
        ])

        let text = attributedInline(runs)
        let body = wrappingLabel(text)
        var views: [NSView] = [kickerRow, body]
        if kind == .finding, Self.lineCount(of: text, width: Self.answerTextWidth) > Self.collapsedLines {
            views.append(makeExpandToggle(for: body))
        }
        let section = NSStackView(views: views)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = HelmMetrics.s1 - 1
        section.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        section.setAccessibilityElement(false)
        return section
    }

    /// How many lines `text` takes at `width`.
    static func lineCount(of text: NSAttributedString, width: CGFloat) -> Int {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines = 0
        var index = 0
        let glyphs = layout.numberOfGlyphs
        while index < glyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            lines += 1
        }
        return lines
    }

    /// A quiet Copy that says "Copied" for two seconds.
    private func makeCopyButton(title: String, text: String) -> HelmButton {
        let button = HelmButton(title: title, variant: .quiet, size: .small, symbol: "doc.on.doc")
        button.toolTip = title == "Copy" ? "Copy this command" : "Copy the whole answer as text"
        button.target = self
        button.action = #selector(copyClicked(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyTexts[ObjectIdentifier(button)] = text
        return button
    }

    @objc private func copyClicked(_ sender: HelmButton) {
        let key = ObjectIdentifier(sender)
        guard let text = copyTexts[key] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let rest = sender.title
        guard rest != "Copied" else { return }
        sender.title = "Copied"
        sender.symbolName = "checkmark"
        copyResets[key]?.cancel()
        let work = DispatchWorkItem { [weak sender] in
            sender?.title = rest
            sender?.symbolName = "doc.on.doc"
        }
        copyResets[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// A long Finding's Show more / Show less, collapsed to start.
    private func makeExpandToggle(for label: NSTextField) -> HelmButton {
        let button = HelmButton(title: Self.collapsedTitle, variant: .quiet, size: .small, symbol: "chevron.down")
        button.symbolTrailing = true
        button.tint = .accent
        button.target = self
        button.action = #selector(expandClicked(_:))
        expandLabels[ObjectIdentifier(button)] = label
        setExpanded(false, label: label, button: button)
        return button
    }

    @objc private func expandClicked(_ sender: HelmButton) {
        guard let label = expandLabels[ObjectIdentifier(sender)] else { return }
        setExpanded(sender.title == Self.collapsedTitle, label: label, button: sender)
    }

    private func setExpanded(_ expanded: Bool, label: NSTextField, button: HelmButton) {
        label.maximumNumberOfLines = expanded ? 0 : Self.collapsedLines
        label.cell?.truncatesLastVisibleLine = !expanded
        label.invalidateIntrinsicContentSize()
        button.title = expanded ? Self.expandedTitle : Self.collapsedTitle
        button.symbolName = expanded ? "chevron.up" : "chevron.down"
    }

    // MARK: Sending

    @objc private func sendOrStop() {
        if isWorking {
            onStop?()
            return
        }
        submit()
    }

    private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isInputEnabled, !isWorking else { return }
        textView.string = ""
        updateTextViewHeight()
        updateComposerState()
        onSubmit?(text)
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        updateTextViewHeight()
        updateComposerState()
    }

    /// Plain Return sends; Shift-Return inserts a new line.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        submit()
        return true
    }

    /// Grows or shrinks the text view to its content, clamped to
    /// `[minTextHeight, maxTextHeight]`.
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
        // **`chromeBackgroundHex`, not `backgroundHex`** - this view fills the
        // pane once a tab has a chat, and `backgroundHex` is the terminal's
        // token (`fm/grandline-sre-lead-polish`).
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        composerKicker.textColor = HelmTheme.mutedInk(theme)
        composerWrap.subviews.first { $0.identifier?.rawValue == "sre.composer.rule" }?
            .layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        composerCard.domainHue = theme.isDaylight ? RailDestination.console.domainHue : nil
        composerCard.applyTheme(theme)
        let ink = HelmField.ink(theme, surface: .raised)
        textView.textColor = ink
        textView.insertionPointColor = ink
        textPlaceholderLabel.textColor = HelmField.mutedInk(theme, surface: .raised)
        emptyTitle.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        emptyBody.textColor = HelmTheme.mutedInk(theme)
        workingCard?.applyTheme(theme)

        // Rebuild every block: `messages` is the source of truth for what each
        // one looks like, and styling is a pure function of it.
        let saved = messages
        let working = workingSince
        clearMessages()
        for message in saved { append(message) }
        if let working { setWorking(since: working) }
    }

    #if FM_SELFTESTS
    var debugIsWorking: Bool { workingCard != nil && !(workingCard?.isHidden ?? true) }
    var debugSendSymbol: String? { sendButton.symbolName }
    var debugSendEnabled: Bool { sendButton.isEnabled }
    func debugClickSend() { sendButton.performClick(nil) }
    var debugChipTitles: [String] { chipsFlow.isHidden ? [] : chipButtons.map(\.title) }
    func debugClickChip(_ index: Int) { chipButtons[index].performClick(nil) }
    var debugComposerText: String { textView.string }
    var debugEmptyStateVisible: Bool { !emptyState.isHidden }
    var debugComposerCard: HelmComposerCard { composerCard }
    func debugSetComposerText(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification))
    }
    /// The Try again buttons in the thread, newest last.
    var debugRetryButtons: [HelmButton] {
        func walk(_ view: NSView) -> [HelmButton] {
            view.subviews.flatMap { sub -> [HelmButton] in
                if let button = sub as? HelmButton, button.title == "Try again" { return [button] }
                return walk(sub)
            }
        }
        return walk(stack)
    }
    /// The expand toggles in the thread (a long Finding's Show more).
    var debugExpandToggles: [HelmButton] {
        func walk(_ view: NSView) -> [HelmButton] {
            view.subviews.flatMap { sub -> [HelmButton] in
                if let button = sub as? HelmButton, expandLabels[ObjectIdentifier(button)] != nil { return [button] }
                return walk(sub)
            }
        }
        return walk(stack)
    }
    func debugExpandedLabelLines(_ toggle: HelmButton) -> Int? {
        expandLabels[ObjectIdentifier(toggle)]?.maximumNumberOfLines
    }
    var debugBubbleCount: Int {
        func walk(_ view: NSView) -> Int {
            view.subviews.reduce(0) { $0 + (($1 is SRELeadBubbleView) ? 1 : walk($1)) }
        }
        return walk(stack)
    }
    #endif
}

// MARK: - Pieces

/// A question's bubble: the accent, with its corner by the edge it comes from
/// drawn tighter, as a chat client draws it.
final class SRELeadBubbleView: NSView {
    static let radius: CGFloat = 14
    static let tailRadius: CGFloat = 4
    private let shape = CAShapeLayer()
    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String, theme: HelmTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = .systemFont(ofSize: HelmType.scaled(12.5))
        label.isSelectable = true
        label.preferredMaxLayoutWidth = SRELeadChatView.bubbleTextWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // The question never changes, so its size is measured once, from the
        // cell that draws it and rounded up. The label's own intrinsic width
        // can sit a fraction under what the cell needs, and where layout
        // rounds to whole points the last word wrapped onto a line the
        // height had no room for.
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: SRELeadChatView.bubbleTextWidth,
                                                             height: .greatestFiniteMagnitude)) ?? .zero
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: ceil(measured.width) + 1),
            label.heightAnchor.constraint(equalToConstant: ceil(measured.height)),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            label.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
        let accent = HelmTheme.nsColor(theme.accentHex)
        shape.fillColor = accent.cgColor
        label.textColor = HelmContrast.legibleOn(fill: accent, preferring: HelmTheme.nsColor(theme.selectionTextHex))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("You asked: \(text)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        HelmMotion.withoutActions {
            shape.frame = bounds
            shape.path = Self.path(in: bounds, isFlipped: isFlipped, tight: .bottomRight)
        }
    }

    enum Corner { case topLeft, bottomRight }

    /// A rounded rect with `tight` drawn at `tailRadius`.
    static func path(in rect: CGRect, isFlipped: Bool, tight: Corner) -> CGPath {
        let r = min(radius, rect.height / 2)
        let t = min(tailRadius, r)
        // Unflipped: y grows upward, so the visual bottom is minY.
        let bottomRightIsMinY = !isFlipped
        var radii = (tl: r, tr: r, br: r, bl: r)
        switch tight {
        case .bottomRight: radii.br = t
        case .topLeft: radii.tl = t
        }
        let path = CGMutablePath()
        let minX = rect.minX, maxX = rect.maxX
        let top = bottomRightIsMinY ? rect.maxY : rect.minY
        let bottom = bottomRightIsMinY ? rect.minY : rect.maxY
        let dir: CGFloat = bottomRightIsMinY ? -1 : 1
        path.move(to: CGPoint(x: minX + radii.tl, y: top))
        path.addLine(to: CGPoint(x: maxX - radii.tr, y: top))
        path.addArc(tangent1End: CGPoint(x: maxX, y: top), tangent2End: CGPoint(x: maxX, y: top + dir * radii.tr), radius: radii.tr)
        path.addLine(to: CGPoint(x: maxX, y: bottom - dir * radii.br))
        path.addArc(tangent1End: CGPoint(x: maxX, y: bottom), tangent2End: CGPoint(x: maxX - radii.br, y: bottom), radius: radii.br)
        path.addLine(to: CGPoint(x: minX + radii.bl, y: bottom))
        path.addArc(tangent1End: CGPoint(x: minX, y: bottom), tangent2End: CGPoint(x: minX, y: bottom - dir * radii.bl), radius: radii.bl)
        path.addLine(to: CGPoint(x: minX, y: top + dir * radii.tl))
        path.addArc(tangent1End: CGPoint(x: minX, y: top), tangent2End: CGPoint(x: minX + radii.tl, y: top), radius: radii.tl)
        path.closeSubpath()
        return path
    }
}

/// The answer's card: the card surface with a hairline edge, its top-left
/// corner tight against the sparkle tile beside it.
final class SRELeadThreadCard: NSView {
    private let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.lineWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        HelmMotion.withoutActions {
            shape.fillColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            shape.strokeColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        }
    }

    override func layout() {
        super.layout()
        HelmMotion.withoutActions {
            shape.frame = bounds
            shape.path = SRELeadBubbleView.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), isFlipped: isFlipped, tight: .topLeft)
        }
    }
}

/// While a turn runs: the sparkle tile beside a card with an hourglass, "SRE
/// Lead is working", the elapsed time and two placeholder lines.
final class SRELeadWorkingCard: NSView {
    private let tile = IconTileView(size: SRELeadChatView.answerTileSide, cornerRadius: HelmMetrics.rChip)
    private let card = SRELeadThreadCard()
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "SRE Lead is working")
    private let elapsed = NSTextField(labelWithString: "0s")
    private let bars = [NSView(), NSView()]
    private var timer: Timer?
    private var since: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        tile.configure(symbol: "sparkles", tint: .accent, pointSize: 11)
        label.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        elapsed.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11), weight: .regular)
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The ticking elapsed time is the live signal: the kit has no spinner
        // (UI-61), and a static glyph needs no Reduce Motion gate.
        let top = NSStackView(views: [glyph, label, spacer, elapsed])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.distribution = .fill
        top.spacing = HelmMetrics.s2
        let inner = NSStackView(views: [top] + bars)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = HelmMetrics.s2
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        var constraints = [
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: SRELeadChatView.cardPadding),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -SRELeadChatView.cardPadding),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: HelmMetrics.s2 + 2),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(HelmMetrics.s2 + 2)),
            top.widthAnchor.constraint(equalTo: inner.widthAnchor),
        ]
        for (bar, fraction) in zip(bars, [0.86, 0.58]) {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = HelmMetrics.s1
            bar.translatesAutoresizingMaskIntoConstraints = false
            constraints += [
                bar.heightAnchor.constraint(equalToConstant: HelmMetrics.s2 + 1),
                bar.widthAnchor.constraint(equalTo: inner.widthAnchor, multiplier: fraction),
            ]
        }
        let row = NSStackView(views: [tile, card])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        constraints += [
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("SRE Lead is working")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func start(since: Date) {
        self.since = since
        tick()
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let since else { return }
        elapsed.stringValue = "\(Int(Date().timeIntervalSince(since)))s"
    }

    func applyTheme(_ theme: HelmTheme) {
        tile.applyTheme(theme)
        card.applyTheme(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        label.textColor = ink
        elapsed.textColor = HelmTheme.mutedInk(theme)
        glyph.image = HelmSymbol.image("hourglass", pointSize: HelmType.scaled(11), weight: .semibold)
        glyph.contentTintColor = HelmTheme.nsColor(HelmTint.warn.hex(in: theme))
        let track = theme.mode == .dark ? surface.blended(withFraction: 0.14, of: ink) ?? line
                                        : line.blended(withFraction: 0.25, of: surface) ?? line
        bars.forEach { $0.layer?.backgroundColor = track.cgColor }
    }

    deinit { timer?.invalidate() }
}
