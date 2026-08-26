// Manjesh Grand Line - native macOS app.
//
// The Whiteboard's "Generate diagram" popover: describe a diagram in plain
// English, get it drawn on the canvas - and then keep talking to it.
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
//
// ## The two modes, and why the popover changes shape between them
//
// This started as a one-shot box: type, Generate, done - and a follow-up
// ("make this bigger") was read as a completely fresh, context-free request,
// so the only way to adjust a diagram was to rewrite the original description
// and regenerate from nothing. It is a conversation now, and the popover says
// so rather than leaving the captain to infer it from behaviour:
//
//  - **Fresh** (no session yet): the title reads "Generate a diagram", the
//    example chips are offered, and "Add to what's already on the board" is
//    available - that checkbox decides whether the *canvas* is added to or
//    replaced, which is a question only a first generation has (see
//    `appendsToBoard`).
//  - **Refining** (at least one turn): the title reads "Refine the diagram",
//    the turns so far are listed above the field, the button says "Refine",
//    the placeholder asks for a change rather than a description, and "Start
//    over" appears. The append checkbox is hidden, because a refinement
//    inherently replaces the board with its revision - it is the *same*
//    diagram, edited.
//
// The session (the instruction list plus `claude`'s own session id) lives
// here, in the one place that also owns the field the captain types into.
// `WhiteboardController` ends it in the one case where it obviously must - the
// board being cleared, since a board with nothing on it has nothing to refine.

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

    /// Set by `WhiteboardController`: read back what is actually on the board
    /// right now, as element skeletons. A refine turn cannot be built without
    /// it, so a nil handler is a real failure the captain is told about rather
    /// than a silently context-free regeneration.
    var onBoardSnapshot: ((@escaping (Result<[[String: Any]], WhiteboardBridgeError>) -> Void) -> Void)?

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
        content.onBoardSnapshot = { [weak self] done in
            guard let handler = self?.onBoardSnapshot else {
                done(.failure(WhiteboardBridgeError(message: "the canvas isn't connected")))
                return
            }
            handler(done)
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

    /// Drop the conversation and go back to the fresh, first-generation shape.
    /// Called by the captain's own "Start over", and by `WhiteboardController`
    /// when the board is cleared out from under it.
    func endSession(note: String? = nil) { content.endSession(note: note) }

    /// Whether a diagram conversation is in progress. Read by the destination
    /// so its own actions can stay consistent with what the popover shows.
    var hasSession: Bool { content.hasSession }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Drives the popover's real controls - the field, the checkbox and the
    /// Generate button's own target/action - rather than calling
    /// `WhiteboardDiagram.run` behind them, so the UI path itself (which is
    /// where a layout or wiring mistake actually lives) is what gets exercised.
    func debugPrepare(prompt: String, appends: Bool) { content.debugPrepare(prompt: prompt, appends: appends) }
    func debugClickGenerate() { content.debugClickGenerate() }
    func debugClickStartOver() { content.debugClickStartOver() }
    func debugClearStatus() { content.debugClearStatus() }
    var debugStatus: String { content.debugStatusText }
    var debugContentView: NSView { content.view }
    var debugTurns: [String] { content.debugTurns }
    var debugSessionID: String? { content.debugSessionID }
    var debugIsRefining: Bool { content.hasSession }
    var debugTitle: String { content.debugTitleText }
    var debugGenerateButtonTitle: String { content.debugGenerateButtonTitle }
    var debugAppendToggleVisible: Bool { content.debugAppendToggleVisible }
    var debugStartOverVisible: Bool { content.debugStartOverVisible }
    var debugHistoryLines: [String] { content.debugHistoryLines }
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

    /// How many turns the history lists in full before collapsing the rest into
    /// a "+N earlier" line. A popover is a lightweight surface and this is a
    /// lightweight tool - an unbounded transcript would make it as tall as the
    /// window, which is exactly the "heavy" outcome a diagram composer should
    /// not have. The count is what matters most anyway: a captain needs to see
    /// that this is a conversation and what they last asked for, not to re-read
    /// turn one.
    static let maxVisibleTurns = 3

    private var theme = ThemeManager.shared.theme

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "Generate a diagram")
    private let kicker = NSTextField(labelWithString: "")
    private let historyStack = NSStackView()
    private let composerCard = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let promptField = HelmTextView(height: WhiteboardComposerViewController.promptHeight)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "\u{2318}\u{23ce} to generate")
    private let generateButton = HelmButton(title: "Generate", variant: .primary, target: nil, action: nil)
    private let appendToggle = NSButton(checkboxWithTitle: "Add to what's already on the board", target: nil, action: nil)
    private let startOverButton = HelmButton(title: "Start over", variant: .quiet, size: .small)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private static let freshPlaceholder = "A three-tier web app with a load balancer, two app servers and a database…"
    private static let refinePlaceholder = "Make the database box bigger, and colour the cache layer amber…"

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
    private var historyLabels: [NSTextField] = []

    var onGenerated: (([[String: Any]], Bool, @escaping (String?) -> Void) -> Void)?
    var onBoardSnapshot: ((@escaping (Result<[[String: Any]], WhiteboardBridgeError>) -> Void) -> Void)?
    var onSizeChanged: ((NSSize) -> Void)?

    private var isGenerating = false
    private var statusIsError = false

    /// The conversation so far: what the captain asked for, in order. The first
    /// entry is the original description; every later one is a refinement.
    private var turns: [String] = []
    /// `claude`'s own session id, threaded into the next turn's `--resume`.
    /// Nil until the model reports one, and nil again after "Start over".
    private var sessionID: String?

    var hasSession: Bool { !turns.isEmpty }

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

        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 3
        historyStack.translatesAutoresizingMaskIntoConstraints = false
        historyStack.isHidden = true

        promptField.textView.delegate = self
        promptField.domainHue = RailDestination.whiteboard.domainHue
        composerCard.domainHue = RailDestination.whiteboard.domainHue
        composerCard.senseFocus(on: promptField.textView)

        placeholderLabel.font = HelmType.body()
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.stringValue = Self.freshPlaceholder
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
        appendToggle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        startOverButton.target = self
        startOverButton.action = #selector(startOverClicked)
        startOverButton.toolTip = "Forget this conversation and start a brand-new diagram"
        startOverButton.isHidden = true
        startOverButton.setContentHuggingPriority(.required, for: .horizontal)
        startOverButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Same "left thing, spacer, right thing" arrangement as the footer, and
        // for the same gotcha (10) reason. Exactly one of the two ends is
        // visible at a time today (the checkbox belongs to a fresh generation,
        // "Start over" to a session), and the row is laid out to survive either.
        let optionsSpacer = NSView()
        optionsSpacer.translatesAutoresizingMaskIntoConstraints = false
        optionsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let optionsRow = NSStackView(views: [appendToggle, optionsSpacer, startOverButton])
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.distribution = .fill
        optionsRow.spacing = HelmMetrics.s2
        optionsRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, kicker, historyStack, composerCard,
                                        examplesFlow, optionsRow, statusLabel])
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

            historyStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            composerCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            examplesFlow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
            // uses.
            placeholderLabel.leadingAnchor.constraint(equalTo: promptField.leadingAnchor, constant: 10),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: promptField.trailingAnchor, constant: -8),
            placeholderLabel.topAnchor.constraint(equalTo: promptField.topAnchor, constant: 8),
        ])

        applyMode()
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
            string: kickerText.uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        placeholderLabel.textColor = HelmTheme.mutedInk(theme)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        for label in historyLabels { label.textColor = HelmTheme.mutedInk(theme) }
        appendToggle.attributedTitle = NSAttributedString(
            string: appendToggle.title,
            attributes: [.font: HelmType.caption(),
                         .foregroundColor: HelmTheme.mutedInk(theme)])
        statusLabel.textColor = statusColor
        composerCard.applyTheme(theme)
        promptField.applyTheme(theme)
    }

    func focusPromptField() {
        view.window?.makeFirstResponder(promptField.textView)
    }

    // MARK: Mode

    private var kickerText: String {
        guard hasSession else { return "What should it show" }
        let noun = turns.count == 1 ? "1 turn so far" : "\(turns.count) turns so far"
        return "Refining \u{00B7} \(noun)"
    }

    /// Re-derives every piece of chrome that differs between a fresh
    /// generation and a refinement, from `turns` alone. One function rather
    /// than a flag set at each transition: "Start over" and a completed turn
    /// change the same six things, and two places deciding them is how a
    /// popover ends up saying "Refine" over an empty session.
    private func applyMode() {
        let refining = hasSession
        titleLabel.stringValue = refining ? "Refine the diagram" : "Generate a diagram"
        generateButton.title = refining ? "Refine" : "Generate"
        hintLabel.stringValue = refining ? "\u{2318}\u{23ce} to refine" : "\u{2318}\u{23ce} to generate"
        placeholderLabel.stringValue = refining ? Self.refinePlaceholder : Self.freshPlaceholder
        // A refinement replaces the board with its own revision by definition -
        // it is the same diagram, edited - so the add-or-replace question the
        // checkbox asks only exists for a first generation.
        appendToggle.isHidden = refining
        // The examples are starting points for a diagram that does not exist
        // yet; offered mid-conversation they read as "click to throw this away".
        examplesFlow.isHidden = refining
        startOverButton.isHidden = !refining
        rebuildHistory()
        applyTheme(theme)
    }

    private func rebuildHistory() {
        for view in historyStack.arrangedSubviews {
            historyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        historyLabels = []
        guard hasSession else {
            historyStack.isHidden = true
            return
        }
        var lines: [String] = []
        let hidden = max(0, turns.count - Self.maxVisibleTurns)
        if hidden > 0 {
            // Stated, never silently dropped - this app's own "no silent caps"
            // rule, applied to a transcript.
            lines.append(hidden == 1 ? "+1 earlier turn" : "+\(hidden) earlier turns")
        }
        for (offset, turn) in turns.enumerated() where offset >= hidden {
            lines.append("\(offset + 1). \(turn)")
        }
        for line in lines {
            let label = NSTextField(labelWithString: line)
            label.font = HelmType.caption()
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 2
            label.textColor = HelmTheme.mutedInk(theme)
            label.translatesAutoresizingMaskIntoConstraints = false
            historyStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
            historyLabels.append(label)
        }
        historyStack.isHidden = false
    }

    /// Drops the conversation. The board is deliberately left alone: clearing
    /// it is the destination's own Clear action, which asks first, and a
    /// popover button that silently wiped real work would be the worse
    /// surprise. The status line says so rather than leaving it to be guessed.
    func endSession(note: String? = nil) {
        _ = view
        turns = []
        sessionID = nil
        promptField.string = ""
        updatePlaceholder()
        applyMode()
        show(status: note ?? "Started over. The next diagram is generated from scratch; what's on the board is untouched.",
             isError: false)
    }

    // MARK: Actions

    @objc private func exampleClicked(_ sender: HelmButton) {
        promptField.string = sender.title
        updatePlaceholder()
        focusPromptField()
    }

    @objc private func appendToggled() {}

    @objc private func startOverClicked() {
        guard !isGenerating else { return }
        endSession()
        focusPromptField()
    }

    @objc private func generateClicked() {
        guard !isGenerating else { return }
        let instruction = promptField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            show(status: hasSession ? "Describe the change you want first."
                                    : "Describe the diagram you want first.", isError: true)
            return
        }
        setGenerating(true)
        guard hasSession else {
            show(status: "Asking Claude for a diagram…", isError: false)
            runTurn(.fresh(description: instruction), instruction: instruction, append: appendsToBoard)
            return
        }
        // A refinement is only honest if it is built from the board as it
        // stands *now* - so the snapshot is taken per turn, immediately before
        // the model is asked, never cached from the last one.
        show(status: "Reading the board…", isError: false)
        guard let snapshot = onBoardSnapshot else {
            setGenerating(false)
            show(status: "The canvas isn't connected.", isError: true)
            return
        }
        snapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.setGenerating(false)
                self.show(status: error.message, isError: true)
            case .success(let board):
                guard !board.isEmpty else {
                    // Nothing to refine is not a failure of the model or the
                    // bridge - it is a session pointing at a board that is no
                    // longer there, so say which and offer the way out.
                    self.setGenerating(false)
                    self.show(status: "The board is empty, so there's nothing to refine. Start over to generate a new diagram.",
                              isError: true)
                    return
                }
                self.show(status: "Asking Claude to refine the diagram…", isError: false)
                self.runTurn(.refine(instruction: instruction, board: board),
                             instruction: instruction, append: false)
            }
        }
    }

    private func runTurn(_ turn: WhiteboardDiagram.Turn, instruction: String, append: Bool) {
        WhiteboardDiagram.run(turn: turn, resumeSessionID: sessionID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.setGenerating(false)
                self.show(status: error.message, isError: true)
            case .success(let reply):
                guard let onGenerated = self.onGenerated else {
                    self.setGenerating(false)
                    self.show(status: "The canvas isn't connected.", isError: true)
                    return
                }
                onGenerated(reply.elements, append) { [weak self] failure in
                    guard let self else { return }
                    self.setGenerating(false)
                    if let failure {
                        // The board never changed, so neither does the session:
                        // recording a turn the canvas refused would leave the
                        // conversation claiming an edit that is not there.
                        self.show(status: failure, isError: true)
                        return
                    }
                    let wasRefinement = self.hasSession
                    self.turns.append(instruction)
                    // Nil only when `claude` reported no session id; the next
                    // turn then starts a fresh conversation and still refines
                    // correctly, because the board travels in the prompt.
                    self.sessionID = reply.sessionID
                    self.promptField.string = ""
                    self.updatePlaceholder()
                    self.applyMode()
                    let noun = reply.elements.count == 1 ? "1 element" : "\(reply.elements.count) elements"
                    self.show(status: wasRefinement
                                ? "Refined the diagram - \(noun) on the board. Ask for another change, or start over."
                                : "Drew \(noun) on the board. Ask for a change to refine it.",
                              isError: false)
                }
            }
        }
    }

    /// Whether a generated diagram is added to the board or replaces it. Read
    /// at generate time rather than tracked, so the checkbox is the only state.
    /// Only ever consulted for a first generation - see `applyMode`.
    var appendsToBoard: Bool { appendToggle.state == .on }

    private func setGenerating(_ generating: Bool) {
        isGenerating = generating
        generateButton.isEnabled = !generating
        startOverButton.isEnabled = !generating
        for button in exampleButtons { button.isEnabled = !generating }
        if generating { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var statusColor: NSColor {
        statusIsError
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            : HelmTheme.mutedInk(theme)
    }

    private func show(status: String, isError: Bool) {
        statusIsError = isError
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        statusLabel.textColor = statusColor
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
    var debugTurns: [String] { turns }
    var debugSessionID: String? { sessionID }
    var debugTitleText: String { titleLabel.stringValue }
    var debugGenerateButtonTitle: String { generateButton.title }
    var debugAppendToggleVisible: Bool { !appendToggle.isHidden }
    var debugStartOverVisible: Bool { !startOverButton.isHidden }
    var debugHistoryLines: [String] {
        historyStack.isHidden ? [] : historyLabels.map(\.stringValue)
    }

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

    func debugClickStartOver() {
        _ = view
        startOverButton.performClick(nil)
    }

    /// Blanks the status line so a test can wait for a *transition* rather
    /// than for a string. Without it, the interim status a click sets
    /// synchronously ("Asking Claude…") is indistinguishable from a stale one
    /// left by whatever ran before, and a wait can return before the turn it
    /// is waiting for has even started - the exact trap this suite's own
    /// composer case already records.
    func debugClearStatus() {
        _ = view
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
    }
    #endif
}
