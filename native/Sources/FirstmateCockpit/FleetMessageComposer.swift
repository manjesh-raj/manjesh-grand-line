// Manjesh Grand Line - native macOS app.
//
// F7's composer: the small inline "type an answer and send it" card Overview
// shows under a needs-decision row.
//
// Built on `HelmComposerCard` (`HelmUIComponents.swift`) rather than a fourth
// hand-rolled input surface - the spec is explicit about reusing it, and this
// is its third caller after `SRELeadChatView` and `ConsoleComposerPopover`.
// The auto-resizing `NSTextView` inside it follows `SRELeadChatView`'s own
// shape, including the two mechanics that are easy to get wrong there:
// `NSTextView` has no placeholder API (hence the overlaid muted label) and no
// grow-with-content behaviour (hence the height constraint this view updates
// by hand on every edit).
//
// It renders only; it never sends anything itself - `onSend` hands the text
// back to whoever owns the channel (`FleetActions.reply`, which shells out to
// `fm-send.sh`). This view used to also serve a second, unaddressed channel
// (the header's "Message first mate" action, typed into the herdr-attached
// "Mirror" tab); `fm/grand-line-remove-firstmate-mirror` removed that channel
// whole, along with the tab it sent into.

import AppKit

final class FleetMessageComposer: NSView, NSTextViewDelegate {

    /// The captain pressed Send (or Return) with real text.
    var onSend: ((String) -> Void)?
    /// The captain dismissed the composer without sending.
    var onCancel: (() -> Void)?

    private let addressLabel = NSTextField(labelWithString: "")
    private let card = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholderLabel: NSTextField
    private let captionLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")
    private let sendButton: HelmButton
    private let cancelButton = HelmButton(title: "Cancel", variant: .quiet, size: .small)
    private let spinner = NSProgressIndicator()

    private var textScrollHeight: NSLayoutConstraint!
    private static let minTextHeight: CGFloat = 46
    private static let maxTextHeight: CGFloat = 140

    private var theme: HelmTheme = ThemeManager.shared.theme
    /// `nil` while the composer has nothing to say; otherwise the last send's
    /// real outcome, tinted by how good that outcome actually was.
    private var statusTint: HelmTint?

    /// - Parameters:
    ///   - address: the "Replying to …" line, or `nil` for the unaddressed
    ///     general-message composer.
    ///   - caption: the footer line explaining where this text actually goes.
    ///     Never decorative - it is the one place the captain is told which of
    ///     F7's two channels they are about to use.
    init(address: NSAttributedString?, caption: String, placeholder: String, sendTitle: String) {
        placeholderLabel = NSTextField(labelWithString: placeholder)
        captionLabel = NSTextField(labelWithString: caption)
        sendButton = HelmButton(title: sendTitle, variant: .primary, size: .small, symbol: "paperplane.fill")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(address: address)
        applyTheme(theme)
        updateSendEnabled()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func build(address: NSAttributedString?) {
        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        addressLabel.lineBreakMode = .byTruncatingTail
        addressLabel.maximumNumberOfLines = 1
        if let address {
            addressLabel.attributedStringValue = address
        } else {
            addressLabel.isHidden = true
        }

        buildTextView()
        let footer = buildFooter()

        let cardStack = NSStackView(views: [textScroll, footer])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(cardStack)

        let outer = NSStackView(views: address == nil ? [card] : [addressLabel, card])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = HelmMetrics.s1 + 2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        textScrollHeight = textScroll.heightAnchor.constraint(equalToConstant: Self.minTextHeight)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: outer.widthAnchor),

            cardStack.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
            textScroll.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            textScrollHeight,
            footer.widthAnchor.constraint(equalTo: cardStack.widthAnchor),

            // Activated here, once `textScroll` is in the real tree - not in
            // `buildTextView()`, where it is still an orphan. Same ordering
            // lesson `SRELeadChatView.buildComposer` documents: a required
            // content-size constraint on an orphaned label can resolve to a
            // stale (near-zero) intrinsic width and never re-derive.
            placeholderLabel.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 9),
            placeholderLabel.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 9),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textScroll.trailingAnchor, constant: -9),
        ])

        // Only when the label is genuinely in the tree. With no address (the
        // general "message first mate" composer) it is never added to `outer`,
        // and a constraint between two views with no common ancestor is a hard
        // AppKit exception, not a warning - it took the whole process down the
        // first time `FleetReplyLayoutSelfTest` opened that composer.
        if address != nil {
            addressLabel.widthAnchor.constraint(lessThanOrEqualTo: outer.widthAnchor).isActive = true
        }
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
        // Transparent: the card's own layer paints the sunken fill, and a
        // second identical fill on top is what makes a text area and its
        // toolbar read as two surfaces instead of one.
        textView.drawsBackground = false
        textView.delegate = self
        // Phase 0's D1 fix - see `HelmComposerCard.senseFocus(on:)`.
        card.senseFocus(on: textView)

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = textView.font
        placeholderLabel.isEditable = false
        placeholderLabel.isBordered = false
        placeholderLabel.isSelectable = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textScroll.addSubview(placeholderLabel)
    }

    private func buildFooter() -> NSView {
        captionLabel.font = HelmType.caption()
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.maximumNumberOfLines = 2
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textColumn = NSStackView(views: [captionLabel, statusLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): stack-level priorities on a stack, content
        // priorities on a leaf. This column is the one thing that may flex.
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textColumn, spinner, cancelButton, sendButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        // AGENTS.md gotcha (10): without `.fill` the buttons' hugging
        // priorities do nothing and the row's slack lands wherever Auto
        // Layout's tie-break puts it.
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: State

    var text: String { textView.string }

#if FM_SELFTESTS
    var sendButtonForTests: HelmButton { sendButton }
    var textViewForTests: NSTextView { textView }
    var statusTextForTests: String? { statusLabel.isHidden ? nil : statusLabel.stringValue }
    /// The same work `textDidChange` does - an `NSTextView` mutated in code
    /// posts no change notification, so a test typing into it must say so.
    func notifyTextChangedForTests() {
        updatePlaceholder()
        updateTextHeight()
        updateSendEnabled()
    }
#endif

    func focusInput() {
        window?.makeFirstResponder(textView)
    }

    func clear() {
        textView.string = ""
        updatePlaceholder()
        updateTextHeight()
        updateSendEnabled()
        setStatus(nil, tint: nil)
    }

    /// Disables input while a send is in flight - the send itself is a real
    /// subprocess that verifies its own submit, so it is not instant.
    func setBusy(_ busy: Bool) {
        textView.isEditable = !busy
        cancelButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateSendEnabled(busy: busy)
    }

    /// The honest per-send feedback line. `nil` clears it.
    func setStatus(_ message: String?, tint: HelmTint?) {
        statusTint = tint
        statusLabel.stringValue = message ?? ""
        statusLabel.isHidden = (message ?? "").isEmpty
        applyStatusColor()
    }

    private var isBusy = false

    private func updateSendEnabled(busy: Bool? = nil) {
        if let busy { isBusy = busy }
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isBusy
    }

    @objc private func sendTapped() {
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        onSend?(trimmed)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        updateTextHeight()
        updateSendEnabled()
    }

    /// ⌘Return sends; a plain Return inserts a newline. The opposite of
    /// `SRELeadChatView`, deliberately: that pane is a chat, where a one-line
    /// turn is the norm, while an answer to a parked decision is often a
    /// paragraph, and losing it to a stray Return would be the worse failure.
    /// ⌘Return matches the six editor sheets (`HelmFormSheet`) and the Console
    /// composer, which is where a captain typing prose in this app already is.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            sendTapped()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    private func updateTextHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let desired = ceil(used) + textView.textContainerInset.height * 2
        let clamped = min(max(desired, Self.minTextHeight), Self.maxTextHeight)
        guard abs(clamped - textScrollHeight.constant) > 0.5 else { return }
        textScrollHeight.constant = clamped
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        addressLabel.textColor = HelmTheme.mutedInk(theme)
        captionLabel.textColor = HelmTheme.mutedInk(theme)
        HelmSelection.apply(to: textView, theme: theme)
        let ink = HelmField.ink(theme)
        textView.textColor = ink
        textView.insertionPointColor = ink
        placeholderLabel.textColor = HelmField.mutedInk(theme)
        applyStatusColor()
        // `HelmButton` themes itself - never set its font/title/tint here.
    }

    private func applyStatusColor() {
        guard let statusTint else {
            statusLabel.textColor = HelmTheme.mutedInk(theme)
            return
        }
        // A hue is never safe as text on its own (`HelmContrast`'s own rule,
        // audit §5.7) - correct it against the surface this label sits on.
        statusLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: statusTint.hex(in: theme), over: HelmField.fill(theme), theme: theme)
    }
}


// GL-27: debug builds only - the seams `FleetReplyLayoutSelfTest` drives the
// real composer through. Thin accessors onto the production views, so a test
// exercising them is exercising what ships.
#if FM_SELFTESTS
extension FleetMessageComposer {
    var debugSendButton: HelmButton { sendButtonForTests }
    var debugTextView: NSTextView { textViewForTests }
    var debugStatusText: String? { statusTextForTests }
    func debugNotifyTextChanged() { notifyTextChangedForTests() }
}
#endif
