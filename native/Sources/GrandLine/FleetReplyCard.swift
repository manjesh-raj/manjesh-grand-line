// Grand Line - native macOS app.
//
// RP-2 Question head, the captain's pick for the Needs you reply composer on
// the hero restyle board (`data/grandline-hero-restyle-designs-scout/`, stage
// `stage-reply`).
//
// **What it replaces.** On Needs you, Reply used to open
// `FleetMessageComposer` under its decision row: a "Replying to task · note"
// line over a `HelmComposerCard`. That line carried the open decision's note,
// which the row above already showed as its second line, so the question
// showed twice and was clipped both times (the row truncates at one line, the
// address at three). Now the row and the composer become this one card:
//
//   - **The head** is the question, in full, on the hero gradient. The kicker
//     is the row's own ("Needs decision · task-142"), the headline is the
//     decision's note wrapping to as many lines as it needs, and the second
//     line names the repo and the decision or decisions the answer is
//     addressed to. The ghost × at its top right is the row's Cancel: the same
//     button identity and action (`fleet.reply.<task>`, `replyTapped`), built
//     by `FleetController+Reply` and handed in.
//   - **The body** is the `HelmPromptWell` Compose, SRE Lead and the Crew
//     input already use, with no hint line because the head says what is
//     being answered, then today's caption, then the status, the keys, Cancel
//     and Send.
//
// Words, keys and outcomes are today's: ⌘↩ sends, ↩ is a new line, Esc
// cancels, and the three outcomes say what `FleetReplyOutcome.message` says.
// The floating bar's dashboard keeps `FleetMessageComposer` as it was.
//
// **The palette.** The head paints `HelmHeroSurface` through
// `HelmHeroColumn.palette(for:in:)`, the quiet-ink rule, because its second
// line and its kicker are the ink at `HelmHeroColumn.quietInkAlpha`. A task
// waiting on a decision takes the theme's hero accent and a blocked one the
// theme's amber - `HelmTint.warn`, the colour `DictationController.heroTone`
// gives Dictation's amber tone, so the app has one amber hero. The tile's
// glyph is the state's hue lifted onto the gradient
// (`HelmHeroSurface.signalColor`), as a ring's arc is.
//
// **Gotchas (13) and (22).** Nothing in the card decides its width: the rows
// stack ties it, and every wrapping label (the headline, the second line, the
// caption and the status) gives way horizontally at `.defaultLow`. Each one's
// `preferredMaxLayoutWidth` comes from the card's own width, which the stack
// decides, minus fixed insets - never from the label's resolved frame. The
// status shares its row with the keys and the buttons, so its width is the
// row's less their `fittingSize`, as `SettingsRow.relayoutDescription` does.
//
// **⌘↩ through `performKeyEquivalent`.** AppKit offers a ⌘-chord to the key
// window's views before the first responder sees it, which is the same route
// `ConsoleComposerPopover`'s Generate and `HelmFormSheet`'s confirm take. The
// card answers only while its own text view is the first responder, so ⌘↩
// elsewhere on the page sends nothing, as before. A plain Return is the text
// view's own new line, and Esc reaches `textView(_:doCommandBy:)` as
// `cancelOperation:`.

import AppKit

final class FleetReplyCard: NSView, NSTextViewDelegate {

    /// The captain pressed Send (or ⌘↩) with real text.
    var onSend: ((String) -> Void)?
    /// The captain dismissed the card without sending.
    var onCancel: (() -> Void)?

    // MARK: Metrics

    /// The board's `.qh`: 16pt rounded bold.
    static let headlineSize: CGFloat = 16
    /// The board's `.qhead` padding. The right inset is smaller because the
    /// ghost × sits there, and the words keep `HelmMetrics.s1` more.
    static let headInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 10)
    /// The board's `.qbody` padding.
    static let bodyInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    /// The band's kicker tile (`HelmHeroColumn`), so the card's kicker reads
    /// as the band's directly above it does.
    static let kickerTileSide: CGFloat = 20
    static let kickerGlyphSize: CGFloat = 11
    /// The hero's own rounding.
    static var cornerRadius: CGFloat { HelmHeroColumn.cornerRadius }
    /// The board's `.pwell.busy`: the well steps back while a send is out.
    static let busyWellAlpha: CGFloat = 0.7

    // MARK: Views

    let head: ReplyHeroWords.Head
    /// The card's surface. It clips, so the head's gradient takes the card's
    /// top corners. The card itself carries only the shadow.
    private let clip = NSView()
    private let headView = NSView()
    private let surface = HelmHeroSurface()
    private let kickerTile = NSView()
    private let kickerGlyph = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let closeButton: HelmButton
    private let well = HelmPromptWell(minLines: 1, maxLines: 5)
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = HelmProgressBar.inlineActivity(hue: RailDestination.overview.domainHue)
    private let sendKeys = HelmKeyHint(keys: HelmKeyHint.keys(for: .command, key: HelmKeyHint.returnKey),
                                       caption: "send")
    private let cancelKeys = HelmKeyHint(keys: [HelmKeyHint.escape], caption: "cancel")
    private let cancelButton = HelmButton(title: ReplyHeroWords.cancelTitle, variant: .quiet, size: .small)
    private let sendButton = HelmButton(title: ReplyHeroWords.sendTitle, variant: .primary, size: .small,
                                        symbol: "paperplane.fill")
    private let footer = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    /// The last send's real outcome, tinted by how good that outcome was, or
    /// `nil` while the card has nothing to say.
    private var statusTint: HelmTint?
    private var isBusy = false
    private(set) var palette: HelmHeroSurface.Palette?

    /// - Parameters:
    ///   - head: the question and what it is addressed to.
    ///   - caption: where the text goes, today's words.
    ///   - closeButton: the row's Reply/Cancel button, as the head's ghost ×.
    init(head: ReplyHeroWords.Head, caption: String, closeButton: HelmButton) {
        self.head = head
        self.closeButton = closeButton
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build(caption: caption)
        // One group, named for the task, read head first and then the well
        // (the board's `role="group" aria-label="Answer task"`).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(head.groupLabel)
        applyTheme(theme)
        updateSendEnabled()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Building

    private func build(caption: String) {
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        headView.wantsLayer = true
        headView.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(headView)
        // The board's `.hero.q` glow, an ellipse sized from the head's own
        // bounds at its top-right corner: the head is far wider than it is
        // tall, the shape `HelmHeroSurface`'s capsule glow exists for.
        surface.glowShape = .capsule
        headView.addSubview(surface)
        let words = buildHeadWords()
        headView.addSubview(words)

        let body = buildBody(caption: caption)
        clip.addSubview(body)

        let head = Self.headInsets
        let inset = Self.bodyInsets
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),

            headView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            headView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            headView.topAnchor.constraint(equalTo: clip.topAnchor),
            surface.leadingAnchor.constraint(equalTo: headView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: headView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: headView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: headView.bottomAnchor),
            words.leadingAnchor.constraint(equalTo: headView.leadingAnchor, constant: head.left),
            words.trailingAnchor.constraint(equalTo: headView.trailingAnchor, constant: -head.right),
            words.topAnchor.constraint(equalTo: headView.topAnchor, constant: head.top),
            words.bottomAnchor.constraint(equalTo: headView.bottomAnchor, constant: -head.bottom),

            body.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: inset.left),
            body.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -inset.right),
            body.topAnchor.constraint(equalTo: headView.bottomAnchor, constant: inset.top),
            body.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -inset.bottom),
        ])
    }

    private func buildHeadWords() -> NSView {
        kickerTile.wantsLayer = true
        kickerTile.layer?.cornerRadius = HelmMetrics.rChip
        kickerTile.layer?.borderWidth = 1
        kickerTile.translatesAutoresizingMaskIntoConstraints = false
        kickerTile.setAccessibilityElement(false)
        kickerGlyph.translatesAutoresizingMaskIntoConstraints = false
        kickerGlyph.imageScaling = .scaleNone
        kickerTile.addSubview(kickerGlyph)
        NSLayoutConstraint.activate([
            kickerTile.widthAnchor.constraint(equalToConstant: Self.kickerTileSide),
            kickerTile.heightAnchor.constraint(equalToConstant: Self.kickerTileSide),
            kickerGlyph.centerXAnchor.constraint(equalTo: kickerTile.centerXAnchor),
            kickerGlyph.centerYAnchor.constraint(equalTo: kickerTile.centerYAnchor),
        ])

        kickerLabel.lineBreakMode = .byTruncatingTail
        kickerLabel.maximumNumberOfLines = 1
        kickerLabel.cell?.usesSingleLineMode = true
        kickerLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // Gotcha (10): `.fill`, with the kicker the one view that gives way.
        let kickerRow = NSStackView(views: [kickerTile, kickerLabel, closeButton])
        kickerRow.orientation = .horizontal
        kickerRow.alignment = .centerY
        kickerRow.distribution = .fill
        kickerRow.spacing = HelmMetrics.s2
        kickerRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [kickerTile, closeButton] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // Never clipped: the headline and the second line wrap to as many
        // lines as they need. Neither sets the card's width (gotcha (13)).
        for label in [kickerLabel, headlineLabel, detailLabel] {
            label.isSelectable = false
            label.setAccessibilityElement(false)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        for label in [headlineLabel, detailLabel] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        let words = NSStackView(views: [kickerRow, headlineLabel, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = HelmMetrics.s1
        words.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            kickerRow.widthAnchor.constraint(equalTo: words.widthAnchor),
            // The board's `.qh` keeps 4pt off the right edge the × sits on.
            headlineLabel.widthAnchor.constraint(equalTo: words.widthAnchor, constant: -HelmMetrics.s1),
            detailLabel.widthAnchor.constraint(equalTo: words.widthAnchor, constant: -HelmMetrics.s1),
        ])

        // The head is one element: the question as VoiceOver reads it, with
        // the × as its child.
        headView.setAccessibilityElement(true)
        headView.setAccessibilityRole(.group)
        return words
    }

    private func buildBody(caption: String) -> NSView {
        well.placeholder = ReplyHeroWords.placeholder
        well.textView.delegate = self
        well.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.stringValue = caption
        statusLabel.stringValue = ""
        statusLabel.setAccessibilityElement(false)
        for label in [captionLabel, statusLabel] {
            label.isSelectable = false
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.toolTip = "Send (\u{2318}\u{21A9})"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        for button in [cancelButton, sendButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // A key hint has no intrinsic size of its own (gotcha (12)), so it is
        // held at its content's width by a collapse just above the status's
        // hugging: the status is the one thing in the row that takes slack.
        for hint in [sendKeys, cancelKeys] {
            let hug = hint.widthAnchor.constraint(equalToConstant: 0)
            hug.priority = HelmDaylightPriority.columnHug
            hug.isActive = true
        }

        // The status leads the row, as the board draws it, so the keys and
        // the two buttons keep the trailing edge whatever it says. It stays
        // arranged while empty: it is the view that takes the row's slack.
        for view in [spinner, statusLabel, sendKeys, cancelKeys, cancelButton, sendButton] as [NSView] {
            footer.addArrangedSubview(view)
        }
        footer.orientation = .horizontal
        footer.alignment = .centerY
        // Gotcha (10).
        footer.distribution = .fill
        footer.spacing = HelmMetrics.s2
        footer.setCustomSpacing(HelmMetrics.s3, after: sendKeys)
        footer.setCustomSpacing(HelmMetrics.s3, after: cancelKeys)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [well, captionLabel, footer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.setCustomSpacing(HelmMetrics.s1 + HelmMetrics.s0, after: well)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalTo: body.widthAnchor),
            captionLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            footer.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        return body
    }

    /// Every wrapping label's width, from the card's own width (gotcha (22)).
    override func layout() {
        super.layout()
        let width = floor(bounds.width)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
        guard width > 0 else { return }
        let headWidth = width - Self.headInsets.left - Self.headInsets.right - HelmMetrics.s1
        let bodyWidth = width - Self.bodyInsets.left - Self.bodyInsets.right
        // The keys and the buttons, each with the gap before it, and the two
        // wider gaps after the key hints.
        let rigid = footer.arrangedSubviews.filter { $0 !== statusLabel && !$0.isHidden }
        let rigidWidth = rigid.reduce(CGFloat(0)) { $0 + ceil($1.fittingSize.width) + footer.spacing }
            + 2 * (HelmMetrics.s3 - HelmMetrics.s2)
        Self.wrap(headlineLabel, at: headWidth)
        Self.wrap(detailLabel, at: headWidth)
        Self.wrap(captionLabel, at: bodyWidth)
        Self.wrap(statusLabel, at: bodyWidth - rigidWidth)
    }

    private static func wrap(_ label: NSTextField, at width: CGFloat) {
        let wrap = max(0, floor(width))
        guard abs(label.preferredMaxLayoutWidth - wrap) > 0.5 else { return }
        label.preferredMaxLayoutWidth = wrap
        label.invalidateIntrinsicContentSize()
    }

    // MARK: State

    var text: String { well.textView.string }

    func focusInput() {
        window?.makeFirstResponder(well.textView)
    }

    func clear() {
        well.textView.string = ""
        updateSendEnabled()
        setStatus(nil, tint: nil)
    }

    /// Disables input while a send is in flight - the send is a real
    /// subprocess that verifies its own submit, so it is not instant. The ×
    /// waits too, as the board's does: closing the card mid-send would leave
    /// the outcome nowhere to land.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        well.textView.isEditable = !busy
        well.alphaValue = busy ? Self.busyWellAlpha : 1
        cancelButton.isEnabled = !busy
        closeButton.isEnabled = !busy
        if busy { spinner.startAnimation() } else { spinner.stopAnimation() }
        updateSendEnabled()
    }

    /// The honest per-send feedback line. `nil` clears it.
    func setStatus(_ message: String?, tint: HelmTint?) {
        statusTint = tint
        statusLabel.stringValue = message ?? ""
        statusLabel.setAccessibilityElement(!(message ?? "").isEmpty)
        applyStatusColor()
        needsLayout = true
    }

    private func updateSendEnabled() {
        let hasText = !well.textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isBusy
    }

    @objc private func sendTapped() {
        let trimmed = well.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        onSend?(trimmed)
    }

    @objc private func cancelTapped() {
        guard !isBusy else { return }
        onCancel?()
    }

    // MARK: Keys

    /// ⌘↩ (or ⌘ and the keypad's Enter) with no other modifier, masked the
    /// way every chord in the app is (gotcha (21)).
    static func isSendChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 else { return false }
        return event.modifierFlags.intersection(KeyChord.relevantModifierMask) == .command
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isSendChord(event), let window, window.firstResponder === well.textView {
            sendTapped()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func textDidChange(_ notification: Notification) {
        updateSendEnabled()
    }

    /// Esc cancels, as Cancel does. A plain Return is left to the text view,
    /// which inserts a new line: an answer to a parked decision is often a
    /// paragraph, and losing it to a stray Return is the worse failure.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTapped()
            return true
        }
        return false
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        HelmCard.applyCardSurface(to: clip, theme: theme, cornerRadius: Self.cornerRadius,
                                  daylightRadius: Self.cornerRadius)
        clip.layer?.masksToBounds = true
        if let layer {
            HelmCard.applyElevation(.resting, to: layer, theme: theme,
                                    path: CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                                 cornerHeight: Self.cornerRadius, transform: nil))
        }
        paintHead(theme)
        well.applyTheme(theme)
        captionLabel.font = HelmType.caption()
        captionLabel.textColor = HelmTheme.mutedInk(theme)
        statusLabel.font = HelmType.caption()
        applyStatusColor()
        // `HelmButton` and `HelmKeyHint` theme themselves.
    }

    /// The head's colours for `tone` in `theme`: the quiet-ink rule on the
    /// theme's hero accent, or on its amber for a blocked task.
    static func palette(for tone: ReplyHeroWords.Tone, in theme: HelmTheme) -> HelmHeroSurface.Palette {
        switch tone {
        case .accent:
            return HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
        case .amber:
            let rgb = HelmContrast.components(HelmTheme.nsColor(HelmTint.warn.hex(in: theme)))
            return HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .fixed(red: rgb.0, green: rgb.1,
                                                                                    blue: rgb.2)), in: theme)
        }
    }

    /// The state the tile's glyph shows: amber for a decision, red for a block.
    private var glyphTint: HelmTint { head.tone == .amber ? .critical : .warn }

    private func paintHead(_ theme: HelmTheme) {
        let palette = Self.palette(for: head.tone, in: theme)
        self.palette = palette
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        // A white-ink hero is a dark surface, so the × resolves the dark
        // appearance's system colours (its focus ring), whatever the page is.
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        headView.appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        let quiet = ink.withAlphaComponent(HelmHeroColumn.quietInkAlpha)

        kickerTile.layer?.backgroundColor = ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
        kickerTile.layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
        // A template in one colour, as the band's kicker glyph is.
        kickerGlyph.image = HelmSymbol.image(head.symbol, pointSize: HelmType.scaled(Self.kickerGlyphSize),
                                             weight: .semibold)
        kickerGlyph.contentTintColor = HelmHeroSurface.signalColor(tintHex: glyphTint.hex(in: theme), on: palette)
        kickerLabel.attributedStringValue = NSAttributedString(string: head.kicker.uppercased(),
                                                               attributes: HelmType.kickerAttributes(color: quiet))
        headlineLabel.stringValue = head.headline
        headlineLabel.font = HelmType.rounded(HelmType.scaled(Self.headlineSize), .bold)
        headlineLabel.textColor = ink
        detailLabel.stringValue = head.detail
        detailLabel.font = HelmType.caption()
        detailLabel.textColor = quiet
        closeButton.heroInk = ink
        headView.setAccessibilityLabel([head.kicker, head.headline, head.detail].joined(separator: ". "))
    }

    private func applyStatusColor() {
        guard let statusTint else {
            statusLabel.textColor = HelmTheme.mutedInk(theme)
            return
        }
        // A hue is never safe as text on its own (`HelmContrast`'s own rule) -
        // corrected against the card this line sits on.
        statusLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: statusTint.hex(in: theme), over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
    }

    // MARK: Self-test surface

    #if FM_SELFTESTS
    var debugHeadView: NSView { headView }
    var debugKickerLabel: NSTextField { kickerLabel }
    var debugHeadlineLabel: NSTextField { headlineLabel }
    var debugDetailLabel: NSTextField { detailLabel }
    var debugCaptionLabel: NSTextField { captionLabel }
    var debugStatusLabel: NSTextField { statusLabel }
    var debugStatusText: String? { statusLabel.stringValue.isEmpty ? nil : statusLabel.stringValue }
    var debugWell: HelmPromptWell { well }
    var debugTextView: HelmPromptTextView { well.textView }
    var debugSendButton: HelmButton { sendButton }
    var debugCancelButton: HelmButton { cancelButton }
    var debugCloseButton: HelmButton { closeButton }
    var debugKeyHints: [HelmKeyHint] { [sendKeys, cancelKeys] }
    var debugTileFill: CGColor? { kickerTile.layer?.backgroundColor }
    var debugSurface: HelmHeroSurface { surface }
    var debugIsBusy: Bool { isBusy }
    /// The colour the tile's glyph is drawn in, by the rule `paintHead` uses.
    var debugGlyphColor: NSColor? {
        palette.map { HelmHeroSurface.signalColor(tintHex: glyphTint.hex(in: theme), on: $0) }
    }
    #endif
}
