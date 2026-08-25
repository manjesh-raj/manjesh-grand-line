// Manjesh Grand Line - native macOS app.
//
// The Whiteboard's "Generate diagram" popover: describe a diagram in plain
// English, get it drawn on the canvas.
//
// Shape and conventions are `ConsoleComposerPopover.swift`'s, deliberately -
// same `NSPopover` + plain content controller, same violet `IconTileView`
// header (this app's own "AI feature" tint, established by Dictation's
// clean-up card), same `HelmComposerCard` well, same `⌘⏎` key equivalent, and
// the same live `ThemeManager` observation plus forced `popover.appearance`
// that file's own header explains at length (a popover with no explicit fill
// falls back to system vibrancy and ignores the in-app theme). What differs is
// only what it does with the answer: Console's composer shows a command for
// review and never runs anything, because a shell command is dangerous;
// a diagram is drawn immediately, because drawing on a whiteboard is the
// harmless, reversible thing the captain asked for (and Excalidraw's own undo
// takes it back).

import AppKit

final class WhiteboardComposerController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = WhiteboardComposerViewController()
    private var themeObservation: ThemeObservation?

    /// Set by `WhiteboardController`: hand the parsed elements to the canvas.
    /// The controller answers with `nil` on success or a message on failure, so
    /// a canvas-side rejection lands in the popover the captain is looking at
    /// rather than somewhere behind it.
    var onGenerated: (([[String: Any]], Bool, @escaping (String?) -> Void) -> Void)?

    override init() {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onGenerated = { [weak self] elements, append, done in
            // A `nil` `onGenerated` has to answer, not go quiet: the popover
            // shows "Asking Claude…" until its completion fires, so an
            // unwired canvas would otherwise leave that spinner up forever
            // with no way to tell it from a slow model. (Found by injecting
            // exactly that break - see `WhiteboardViewSelfTest`'s composer
            // case.)
            guard let handler = self?.onGenerated else {
                done("the canvas isn't connected")
                return
            }
            handler(elements, append, done)
        }
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            content.focusPromptField()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Drives the popover's real controls - the field, the checkbox and the
    /// Generate button's own target/action - rather than calling
    /// `WhiteboardDiagram.generate` behind them, so the UI path itself (which
    /// is where a layout or wiring mistake actually lives) is what gets
    /// exercised.
    func debugPrepare(prompt: String, appends: Bool) { content.debugPrepare(prompt: prompt, appends: appends) }
    func debugClickGenerate() { content.debugClickGenerate() }
    var debugStatus: String { content.debugStatusText }
    var debugContentView: NSView { content.view }
    #endif

    /// Mirrors `ConsoleComposerController.shutdown()`: this controller belongs
    /// to a destination that is only built on first visit and is otherwise
    /// app-lifetime, but the observer is unregistered explicitly all the same
    /// so a future teardown cannot leak a dead closure into
    /// `ThemeManager.observers`.
    func shutdown() {
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }
}

private final class WhiteboardComposerViewController: NSViewController, NSTextViewDelegate {

    static let width: CGFloat = 420
    static let promptHeight: CGFloat = 84

    private var theme = ThemeManager.shared.theme

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "Generate a diagram")
    private let kicker = NSTextField(labelWithString: "")
    private let composerCard = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let promptField = HelmTextView(height: WhiteboardComposerViewController.promptHeight)
    private let placeholderLabel = NSTextField(labelWithString: "A three-tier web app with a load balancer, two app servers and a database…")
    private let hintLabel = NSTextField(labelWithString: "\u{2318}\u{23ce} to generate")
    private let generateButton = HelmButton(title: "Generate", variant: .primary, target: nil, action: nil)
    private let appendToggle = NSButton(checkboxWithTitle: "Add to what's already on the board", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    /// A few generic starting points, exactly as `ConsoleComposerViewController`
    /// frames its own: static example *intents*, not fabricated output, and not
    /// derived from anything this app knows about the captain's systems.
    private static let examples = [
        "Kubernetes request path",
        "CI/CD pipeline",
        "Incident escalation flow",
    ]
    private let examplesFlow = ChipFlowView(frame: .zero)
    private var exampleButtons: [HelmButton] = []

    var onGenerated: (([[String: Any]], Bool, @escaping (String?) -> Void) -> Void)?
    var onSizeChanged: ((NSSize) -> Void)?

    private var isGenerating = false
    private var statusIsError = false

    override func loadView() {
        // A generous first frame: `presentAsSheet`-style sizing does not apply
        // to a popover, and `reportSize` hands the real fitting height over on
        // load - this only has to be big enough that the first frame is not
        // visibly clipped before that lands.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 320))
        root.wantsLayer = true
        view = root

        iconTile.configure(symbol: "sparkles", tint: .violet)

        titleLabel.font = HelmType.rowTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [iconTile, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        kicker.translatesAutoresizingMaskIntoConstraints = false
        // The colour goes *into* the attributed string, not onto `textColor`
        // afterwards: an `NSTextField` showing an `attributedStringValue`
        // ignores a later `textColor`, so the first draft of this rendered an
        // invisible kicker (default `labelColor` - black - on a dark card),
        // caught in a real off-screen render rather than by reading the code.
        // `HelmType.kickerAttributes(color:)` exists for exactly this, and
        // `applyTheme` rebuilds the string rather than re-colouring it.

        promptField.textView.delegate = self
        promptField.domainHue = RailDestination.whiteboard.domainHue
        composerCard.domainHue = RailDestination.whiteboard.domainHue
        composerCard.senseFocus(on: promptField.textView)

        placeholderLabel.font = HelmType.body()
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        generateButton.controlSize = .small
        // Reaches Generate from anywhere in the popover - `NSWindow`'s
        // `performKeyEquivalent:` traversal runs before the first responder
        // sees the event - so a plain Return stays a newline in a field that is
        // genuinely multi-line.
        generateButton.keyEquivalent = "\r"
        generateButton.keyEquivalentModifierMask = [.command]
        generateButton.setContentHuggingPriority(.required, for: .horizontal)
        generateButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        hintLabel.font = HelmType.caption()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // "Hint left, action right" needs a flexible spacer plus `.fill` -
        // gotcha (10): a `.gravityAreas` row stretches nothing on its own.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerRow = NSStackView(views: [hintLabel, spacer, spinner, generateButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.distribution = .fill
        footerRow.spacing = HelmMetrics.s2
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = NSStackView(views: [promptField, footerRow])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = HelmMetrics.s2
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        composerCard.contentContainer.addSubview(cardStack)
        composerCard.translatesAutoresizingMaskIntoConstraints = false

        exampleButtons = Self.examples.map { example in
            let button = HelmButton(title: example, variant: .secondary, size: .small)
            button.target = self
            button.action = #selector(exampleClicked(_:))
            return button
        }
        examplesFlow.translatesAutoresizingMaskIntoConstraints = false
        examplesFlow.setChips(exampleButtons)

        appendToggle.target = self
        appendToggle.action = #selector(appendToggled)
        appendToggle.font = HelmType.caption()
        appendToggle.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, kicker, composerCard, examplesFlow, appendToggle, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.setCustomSpacing(6, after: titleRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),

            composerCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            examplesFlow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),

            cardStack.leadingAnchor.constraint(equalTo: composerCard.contentContainer.leadingAnchor, constant: HelmMetrics.s2),
            cardStack.trailingAnchor.constraint(equalTo: composerCard.contentContainer.trailingAnchor, constant: -HelmMetrics.s2),
            cardStack.topAnchor.constraint(equalTo: composerCard.contentContainer.topAnchor, constant: HelmMetrics.s2),
            cardStack.bottomAnchor.constraint(equalTo: composerCard.contentContainer.bottomAnchor, constant: -HelmMetrics.s2),
            promptField.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),

            // `NSTextView` has no placeholder of its own, so this is a muted
            // label pinned at the text container's own inset, toggled from
            // `textDidChange` - the same arrangement `ConsoleComposerPopover`
            // uses, including constructing it with its final text (see this
            // app's own note about a later `stringValue =` on a scroll view's
            // floating label resolving to a near-zero width).
            placeholderLabel.leadingAnchor.constraint(equalTo: promptField.leadingAnchor, constant: 10),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: promptField.trailingAnchor, constant: -8),
            placeholderLabel.topAnchor.constraint(equalTo: promptField.topAnchor, constant: 8),
        ])

        applyTheme(theme)
        DispatchQueue.main.async { [weak self] in self?.reportSize() }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        kicker.attributedStringValue = NSAttributedString(
            string: "What should it show".uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        placeholderLabel.textColor = HelmTheme.mutedInk(theme)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        appendToggle.attributedTitle = NSAttributedString(
            string: appendToggle.title,
            attributes: [.font: HelmType.caption(),
                         .foregroundColor: HelmTheme.mutedInk(theme)])
        statusLabel.textColor = statusIsError
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                          over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            : HelmTheme.mutedInk(theme)
        composerCard.applyTheme(theme)
        promptField.applyTheme(theme)
    }

    func focusPromptField() {
        view.window?.makeFirstResponder(promptField.textView)
    }

    // MARK: Actions

    @objc private func exampleClicked(_ sender: HelmButton) {
        promptField.string = sender.title
        updatePlaceholder()
        focusPromptField()
    }

    @objc private func appendToggled() {}

    @objc private func generateClicked() {
        guard !isGenerating else { return }
        let description = promptField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            show(status: "Describe the diagram you want first.", isError: true)
            return
        }
        setGenerating(true)
        show(status: "Asking Claude for a diagram…", isError: false)
        WhiteboardDiagram.generate(description: description) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.setGenerating(false)
                self.show(status: error.message, isError: true)
            case .success(let elements):
                guard let onGenerated = self.onGenerated else {
                    self.setGenerating(false)
                    self.show(status: "The canvas isn't connected.", isError: true)
                    return
                }
                onGenerated(elements, self.appendsToBoard) { [weak self] failure in
                    guard let self else { return }
                    self.setGenerating(false)
                    if let failure {
                        self.show(status: failure, isError: true)
                    } else {
                        let noun = elements.count == 1 ? "1 element" : "\(elements.count) elements"
                        self.show(status: "Drew \(noun) on the board.", isError: false)
                    }
                }
            }
        }
    }

    /// Whether a generated diagram is added to the board or replaces it. Read
    /// at generate time rather than tracked, so the checkbox is the only state.
    var appendsToBoard: Bool { appendToggle.state == .on }

    private func setGenerating(_ generating: Bool) {
        isGenerating = generating
        generateButton.isEnabled = !generating
        for button in exampleButtons { button.isEnabled = !generating }
        if generating { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func show(status: String, isError: Bool) {
        statusIsError = isError
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        statusLabel.textColor = isError
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                          over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            : HelmTheme.mutedInk(theme)
        reportSize()
    }

    /// Sizes the content to what it actually needs, and tells the popover.
    ///
    /// **Both halves matter**, for the reason `ShiftTaskEditorController`'s own
    /// `resizeToFitContent` records: the root's height is a real frame, the
    /// stack is pinned to its top *and* bottom, and any mismatch between the
    /// two is slack that a `.gravityAreas` vertical stack hands to an
    /// arbitrary, sibling-dependent row - which showed up in a real render as
    /// dead space inside the composer card. Setting the frame from
    /// `fittingSize` leaves no slack to distribute.
    private func reportSize() {
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        let size = NSSize(width: Self.width, height: max(fitting.height, 240))
        view.setFrameSize(size)
        onSizeChanged?(size)
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !promptField.string.isEmpty
    }

    func textDidChange(_ notification: Notification) { updatePlaceholder() }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugStatusText: String { statusLabel.isHidden ? "" : statusLabel.stringValue }

    func debugPrepare(prompt: String, appends: Bool) {
        _ = view  // force `loadView` for a popover that has never been shown
        promptField.string = prompt
        appendToggle.state = appends ? .on : .off
        updatePlaceholder()
    }

    /// Fires the button's own target/action, the way a click does - not
    /// `generateClicked()` directly, so a button that lost its wiring fails
    /// this rather than passing.
    func debugClickGenerate() {
        _ = view
        generateButton.performClick(nil)
    }
    #endif
}
