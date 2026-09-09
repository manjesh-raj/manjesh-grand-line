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
    /// A crew member's reply. Carries the member so phase 2's multi-speaker
    /// replies need no new case.
    case crew(StrawHatMember, String)
    /// This view's own chrome - "Luffy is thinking...", never content.
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

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()

    /// Shown while the thread is empty, in the transcript's own place. A chat
    /// pane whose entire content area is blank reads as broken rather than
    /// new, and this app has a shared component for exactly that.
    private let emptyState = HelmEmptyState(
        symbol: StrawHatCrew.speaker.symbol,
        title: "Talk to your crew",
        body: "Luffy is aboard. Ask him anything - think a problem through, draft some wording, or get a second opinion. He has no access to your tasks, hosts or files yet.",
        size: .standard,
        boxed: true,
        hue: RailDestination.overview.domainHue)

    // MARK: Composer - `SRELeadChatView.buildComposer`'s shape

    private let composerWrap = NSView()
    private let composerKicker = NSTextField(labelWithString: "")
    private let composerCard = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    /// `NSTextView` has no placeholder API - a muted label overlaid at the
    /// text container's inset, toggled on every edit.
    private let textPlaceholderLabel = NSTextField(labelWithString: "Message Luffy\u{2026}")
    private let toolbarRow = NSView()
    /// The Shift+Return hint, so the one non-obvious key is discoverable
    /// without a tooltip.
    private let hintLabel = NSTextField(labelWithString: "\u{21B5} to send \u{00B7} \u{21E7}\u{21B5} for a new line")
    private let sendButton = HelmButton(symbol: "arrow.up", variant: .primary, size: .small)

    private var textScrollHeightConstraint: NSLayoutConstraint!

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildScroll()
        buildComposer()
        applyTheme(theme)
        updateEmptyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

        composerKicker.translatesAutoresizingMaskIntoConstraints = false
        composerKicker.attributedStringValue = NSAttributedString(
            string: "Ask the crew".uppercased(),
            attributes: [.font: HelmType.kicker(), .kern: HelmType.kickerKern])

        composerCard.translatesAutoresizingMaskIntoConstraints = false

        let composerStack = NSStackView(views: [composerKicker, composerCard])
        composerStack.orientation = .vertical
        composerStack.alignment = .leading
        composerStack.spacing = HelmMetrics.s1 + 2
        composerStack.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(composerStack)

        buildTextView()
        buildToolbar()

        let cardStack = NSStackView(views: [textScroll, toolbarRow])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        composerCard.contentContainer.addSubview(cardStack)

        textScrollHeightConstraint = textScroll.heightAnchor.constraint(equalToConstant: Self.minTextHeight)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: composerWrap.topAnchor),

            composerWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerWrap.bottomAnchor.constraint(equalTo: bottomAnchor),

            composerStack.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: Self.contentInset),
            composerStack.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -Self.contentInset),
            composerStack.topAnchor.constraint(equalTo: composerWrap.topAnchor, constant: HelmMetrics.s2),
            composerStack.bottomAnchor.constraint(equalTo: composerWrap.bottomAnchor, constant: -Self.contentInset),
            composerCard.widthAnchor.constraint(equalTo: composerStack.widthAnchor),

            cardStack.leadingAnchor.constraint(equalTo: composerCard.contentContainer.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: composerCard.contentContainer.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: composerCard.contentContainer.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: composerCard.contentContainer.bottomAnchor),
            textScroll.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            textScrollHeightConstraint,
            toolbarRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            toolbarRow.heightAnchor.constraint(equalToConstant: 36),

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

    private func buildToolbar() {
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = HelmType.captionSmall()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.lineBreakMode = .byTruncatingTail
        // The hint yields first: the send button must never be squeezed.
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarRow.addSubview(hintLabel)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.target = self
        sendButton.action = #selector(submit)
        sendButton.isEnabled = false
        sendButton.toolTip = "Send to Luffy"
        toolbarRow.addSubview(sendButton)

        // `HelmPageToolbar.iconButton`'s alignment-rect correction: a
        // `HelmButton` paints its chrome in its own layer, which fills the
        // *frame*, while Auto Layout constrains its *alignment rect* - so a
        // plain 28pt height constraint renders a visibly taller box.
        let side: CGFloat = 28
        let insets = sendButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: toolbarRow.leadingAnchor, constant: HelmMetrics.s2 + 2),
            hintLabel.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -HelmMetrics.s2),
            sendButton.trailingAnchor.constraint(equalTo: toolbarRow.trailingAnchor, constant: -HelmMetrics.s2),
            sendButton.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
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
        onMessagesChanged?()
    }

    func clearMessages() {
        messages.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updateEmptyState()
        onMessagesChanged?()
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

    private func updateEmptyState() {
        emptyState.isHidden = !messages.isEmpty
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
        case .crew(let member, let text): return crewBlock(member: member, text: text)
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

    /// An attributed reply card: an icon tile plus "Luffy \u{00B7} Crew" over a
    /// hairline, then the parsed markdown. The attribution header is the
    /// captain's own approved mockup, and the seam phase 2's several-speakers
    /// -per-reply needs.
    private func crewBlock(member: StrawHatMember, text: String) -> NSView {
        let icon = IconTileView(size: 22, cornerRadius: 11)
        icon.configure(symbol: member.symbol, tint: .accent, pointSize: 11)

        let name = NSTextField(labelWithString: member.displayName)
        name.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .semibold)
        name.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.required, for: .horizontal)

        let role = NSTextField(labelWithString: "\u{00B7} \(member.role)")
        role.font = HelmType.captionSmall()
        role.textColor = HelmTheme.mutedInk(theme)
        role.translatesAutoresizingMaskIntoConstraints = false
        role.lineBreakMode = .byTruncatingTail
        role.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Without this spacer the row's slack goes to `role` (`.fill` stretches
        // whichever view hugs least), which a real render showed as the role
        // label pinned to the far right of the card, a hundred points away
        // from the name it belongs to. The spacer absorbs the slack instead.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        role.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [icon, name, role, spacer])
        headerRow.orientation = .horizontal
        headerRow.spacing = 7
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let blockStack = NSStackView()
        blockStack.orientation = .vertical
        blockStack.alignment = .leading
        blockStack.spacing = HelmMetrics.s2
        blockStack.translatesAutoresizingMaskIntoConstraints = false
        // The whole markdown parser, reused - see this file's header.
        for block in SRELeadMarkdown.parse(text) {
            let view = renderBlock(block)
            blockStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: blockStack.widthAnchor).isActive = true
        }

        let contentStack = NSStackView(views: [headerRow, divider, blockStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = HelmMetrics.s2
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        blockStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = HelmMetrics.rCard
        container.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: HelmMetrics.s3),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.s3),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s3),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s3),
        ])
        return container
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
        composerKicker.textColor = HelmTheme.mutedInk(theme)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        composerCard.domainHue = theme.isDaylight ? RailDestination.overview.domainHue : nil
        composerCard.cornerRadius = theme.isDaylight ? HelmMetrics.dWell : HelmMetrics.rRow
        composerCard.applyTheme(theme)
        let ink = HelmField.ink(theme)
        textView.textColor = ink
        textView.insertionPointColor = ink
        textPlaceholderLabel.textColor = HelmField.mutedInk(theme)
        emptyState.applyTheme(theme)

        // Rebuild every block rather than re-deriving each one's role from its
        // current styling: `messages` is the source of truth and styling is a
        // pure function of it. Same call `SRELeadChatView.applyTheme` makes.
        let saved = messages
        clearMessages()
        for message in saved { append(message) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Every message's rendered text, in order - lets the view suite assert
    /// what the transcript actually holds without reaching into AppKit.
    func debugMessageTexts() -> [String] {
        messages.map {
            switch $0 {
            case .captain(let t), .status(let t), .error(let t): return t
            case .crew(_, let t): return t
            }
        }
    }

    /// The speaker names shown on reply blocks, in order.
    func debugCrewSpeakers() -> [String] {
        messages.compactMap {
            if case .crew(let member, _) = $0 { return member.displayName }
            return nil
        }
    }

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
