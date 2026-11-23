// Grand Line - native macOS app.
//
// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-composer`):
// the "✨ Compose" popover a plain `.shell` tab's toolbar opens. Mirrors
// `ShiftMenuBarController`'s popover shape (`ShiftMenuBar.swift`) - a small
// `NSPopover` + a plain `NSViewController` content - but (unlike
// `ShiftMenuBarController`'s popover, which only ever shows plain
// system-label-colored text) this content has its own `HelmTheme`-derived
// colors, so it needs the real live-theme treatment described below rather
// than AppKit's own default vibrant background.
//
// `fm/grandline-composer-cleanup-and-polish` gave the content view its own
// visual treatment, since the original build was a bare label/field/button
// with no styling matching the rest of this app: a tinted `IconTileView`
// (`HelmUIComponents.swift`, `.violet` - the same "AI feature" treatment
// Dictation's "Clean up my sentences" card already established, see
// `DictationController.buildCleanupSection`) next to the title, a real
// monospace code-block presentation for the generated command (mirroring
// the Tools page's own `ToolInstance.codeEditor` - a bordered, corner-radius
// `NSScrollView`/`NSTextView` in the active `HelmTheme`'s colors, not a
// plain `NSTextField`), Copy/Run buttons following this app's established
// small pill-button convention (the same one Vault's "Run injected…"/"Copy
// Name" row buttons use - all of them `HelmButton` since the design system's
// phase 2), and a
// `⌘⏎` shortcut hint next to the intent field.
//
// `fm/grandline-composer-theme-and-width` fixed two real captain-reported
// bugs in that polish pass: (1) the popover rendered as plain, unthemed dark
// gray regardless of the app's actual active Helm theme - the "read once at
// construction, no live observer" comment above was simply wrong for a
// popover that can stay open across a theme change, and worse, this view had
// no explicit background fill at all, so it fell back to `NSPopover`'s own
// system vibrancy (following the OS's light/dark setting, not this app's
// in-app theme) - the same root cause `ThemeManager.swift`'s own checklist
// warns about and the same class of bug `grandline-unified-search-fixes`
// fixed concurrently for the `⌘K` palette. Fixed the same way every other
// themed window in this app is: a live `ThemeManager.shared.observe`
// registration (owned by `ConsoleComposerController`, which is itself an
// app-lifetime property of `ConsoleController` - unobserved from
// `ConsoleController.shutdown()`, mirroring that controller's own theme
// token), a plain `wantsLayer`-backed root view with an explicit
// `HelmTheme`-derived `backgroundColor` fill (never `NSVisualEffectView`,
// per this file's AppKit gotcha #8), and `popover.appearance` forced to the
// theme's own light/dark mode so any leftover system-semantic color resolves
// against the in-app theme, not the OS's. (2) The popover was a fixed 380pt
// wide regardless of the generated command's length, because `root`'s width
// was never tied to a constraint at all - only its initial `loadView` frame
// size, which nothing ever changed. `rootWidthConstraint` now grows to fit
// the longest line of the generated command (measured against the code
// block's own font), capped at `maxWidth` so it can never run off-screen,
// floored at `minWidth` so a short command (or the empty/intent-only state)
// doesn't leave an oversized empty box - `updateWidth`'s resulting fitting
// size is handed to the popover explicitly (`onSizeChanged`), the same
// "compute and set the frame explicitly" style `ShiftSearchController.
// resizeToFit()` already uses, rather than relying on `NSPopover`'s
// occasionally-inconsistent automatic Auto-Layout-driven resize.
//
// `fm/grandline-shift-side-by-side-composer-height` gave the intent field
// real multi-line height (captain: "increase the vertical view... so the
// user can see the text more and have a better visibility") - the field was
// a single-line `NSTextField` that scrolled its own content sideways as you
// typed. `intentTextView`/`intentScroll` (a bordered, corner-radius
// `NSScrollView`/`NSTextView` pair, mirroring the code block's own
// `codeScroll`/`codeTextView` styling below rather than inventing a new
// look) replace it - `NSTextView` has no built-in placeholder API the way
// `NSTextField`'s cell does, so `intentPlaceholderLabel` is a plain muted
// label overlaid at the text container's own inset, toggled by
// `NSTextViewDelegate.textDidChange(_:)`. `⌘⏎` still fires Generate: that
// shortcut was already handled by `generateButton`'s own `keyEquivalent`,
// which `NSWindow`'s `performKeyEquivalent:` traversal reaches before an
// event ever gets to whichever view is first responder - unaffected by
// swapping the field for a text view. A plain Return now inserts a newline
// (the field's own former submit-on-Return action only ever existed because
// a single-line field has no better use for Return) rather than submitting,
// which is the expected behavior for a field that's now genuinely
// multi-line.
//
// Nothing here ever runs a generated command automatically - see
// `ConsoleCommandComposer.swift`'s header and this task's PR description for
// the full design-constraint reasoning (SRE Lead's own approval-gated
// posture, the captain's explicit "look before you run" expectation). The
// generated command is only ever shown for review; `onRunInTerminal` is the
// one explicit action that sends anything to a real terminal, wired by
// `ConsoleController` to `currentTab?.terminal.send(txt:)` - the same call a
// Snippet's own "Run" action already uses.
//
// `fm/grandline-composer-input-styling` fixed a real captain-reported bug:
// the intent field read as plain, undifferentiated text with no visible
// field boundary, since `intentTextView.drawsBackground` was `false` and
// `intentScroll` never had a background fill of its own - only a barely-
// visible 1pt/50%-alpha border. Fixed by giving both `intentTextView` and
// `codeTextView` a real, shared "sunken field" fill
// (now `HelmField.fill(_:)`, Phase 6 of the UI audit) and bumping the
// border alpha (`Self.fieldBorderAlpha`, 0.5 -> 0.7) on both scroll views -
// see that method's own doc comment for why it blends `chromeInkHex` into
// `chromeBackgroundHex` rather than reusing `backgroundHex` directly (the
// two are numerically identical in 3 of 12 `HelmTheme.allThemes`, which
// would have silently reproduced the same invisible-field bug in exactly
// those themes).
//
// `fm/grandline-popover-redesign` (Comp-1 of the console popovers board,
// `data/grand-line-console-popovers-sre-mockups/`): the popover opens on the
// hero gradient every hero card paints, with a white sparkle tile and one line
// saying nothing runs on its own. The intent well is a raised `HelmComposerCard`
// (white on the card rather than the inset `side` colour, which read as a
// flat lavender box on the Lavender palette), and its footer adds "↩ new
// line" and a character count. The examples are raised chips with a leading
// symbol; they still only fill the field. The result is a section card with
// the command in the terminal scheme's own colours, Copy with a two-second
// "Copied" state, and Run in Terminal naming the tab it sends to. Generating
// shows a working card with the elapsed time, and a failure is a critical
// `HelmAccentRow` with Try again. The popover is a fixed 420pt and a long
// command wraps, so it no longer jumps between 380 and 640pt - the
// `fm/grandline-composer-theme-and-width` grow-to-fit described above is gone.
//
// `fm/grandline-console-fixes` (C1 of the Console fixes board): the intent is
// typed at a terminal prompt (`HelmPromptWell`) in the terminal scheme's
// colours - a "~" hint line, a "❯" prompt and a block cursor - so the input
// and the generated `$ command` read as one terminal. The footer is the
// target tab, a ⌘↩ key cap and Generate; the kicker, the hint sentence and
// the character count are gone. It also fixes the captain's "no cursor until
// I type": the old placeholder was a subview of the text view at the text's
// own origin, so its first glyph drew over AppKit's caret.

import AppKit

final class ConsoleComposerController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = ConsoleComposerViewController()
    private var themeObservation: ThemeObservation?

    /// Set by `ConsoleController` to `currentTab?.terminal.send(txt:)`.
    var onRunInTerminal: ((String) -> Void)?
    /// The name of the tab Run in Terminal sends to, read on every open so
    /// the popover can say where the command will land.
    var targetTabName: (() -> String?)?

    override init() {
        super.init()
        // Audit 2 §2.7/§6.2: a popover is its own window, layered above the
        // lock overlay, so anything open when the lock fires would stay
        // readable and interactive over the lock screen (§5.1(b)'s harm, of
        // which the incident card was one instance). Weak, because there is
        // no unregister.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.popover }
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onRunInTerminal = { [weak self] command in
            self?.onRunInTerminal?(command)
            self?.popover.performClose(nil)
        }
        content.onSizeChanged = { [weak self] size in
            self?.popover.contentSize = size
        }
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
            content.reset()
            content.setTargetTabName(targetTabName?())
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            content.focusIntentField()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Called from `ConsoleController.shutdown()`, mirroring that
    /// controller's own `themeObservation` teardown - `ConsoleComposerController`
    /// is a per-console (not strictly app-lifetime) property, and a host
    /// page's `ConsoleController` can be deallocated mid-session (see
    /// "Dedicated host pages" in AGENTS.md), so this observer needs the same
    /// explicit unregistration or it leaks a dead closure into
    /// `ThemeManager.observers`.
    func shutdown() {
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }
}

/// The popover's content (Comp-1): the hero header, the intent well with its
/// footer, then one of the working card, the result card or the error row,
/// and the example chips. No history is kept - this is a one-shot
/// generate-review-run per open, and closing and reopening the popover always
/// starts fresh (`reset()`).
private final class ConsoleComposerViewController: NSViewController, NSTextViewDelegate {
    private var theme = ThemeManager.shared.theme

    /// Comp-1: one width, so the popover never jumps while a command arrives.
    /// A long command wraps inside the result card instead.
    static let width: CGFloat = 420
    static let inset: CGFloat = 14
    static let cardRadius: CGFloat = 12
    /// How long Copy says "Copied".
    static let copiedDuration: TimeInterval = 2

    /// What the popover is showing under the well.
    enum Phase: Equatable {
        case idle
        case generating(started: Date)
        case result(command: String, seconds: TimeInterval)
        case failed(message: String)
    }
    private(set) var phase: Phase = .idle

    private let header = PopoverHeroHeader(symbol: "sparkles", tileStyle: .white)

    private var targetTabName: String?

    /// C1: the intent is typed at a terminal prompt, in the terminal
    /// scheme's colours, three lines tall.
    private let well = HelmPromptWell(hint: "describe it in plain words",
                                      minLines: 3, maxLines: 3)
    private var intentTextView: HelmPromptTextView { well.textView }
    /// "runs in Shell", in the well's footer.
    private let targetLabel = HelmPromptWell.footnote()
    private let shortcutCap = HelmPromptWell.keycap(" \u{2318}\u{21A9} ")
    private let generateButton = HelmButton(title: "Generate", variant: .primary, size: .small)

    /// Static, generic example intents for the natural-language field - not
    /// fabricated command output, and not tied to any host this app does not
    /// know about. A click fills the field; it never generates.
    static let exampleIntents: [(symbol: String, text: String)] = [
        ("list.bullet", "List pods in a namespace"),
        ("internaldrive", "Check disk usage on a host"),
        ("doc.text.magnifyingglass", "Tail the most recent log file"),
    ]
    private let examplesKicker = NSTextField(labelWithString: "")
    private let examplesFlow = ChipFlowView(frame: .zero)
    private var exampleButtons: [HelmButton] = []

    // Working card.
    private let workingCard = DashedCardView()
    private let workingGlyph = NSImageView()
    private let workingLabel = NSTextField(labelWithString: "Claude is writing the command\u{2026}")
    private let workingElapsed = NSTextField(labelWithString: "")
    private let workingBars = [NSView(), NSView()]
    private var workingTimer: Timer?

    // Result card.
    private let resultCard = NSView()
    private let resultKicker = NSTextField(labelWithString: "")
    private let resultMeta = NSTextField(labelWithString: "")
    private let codePanel = NSView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let reviewLabel = NSTextField(labelWithString: "")
    private let copyButton = HelmButton(title: "Copy", variant: .secondary, size: .small, symbol: "doc.on.doc")
    private let runButton = HelmButton(title: "Run in Terminal", variant: .primary, size: .small, symbol: "play.fill")
    private var copiedReset: DispatchWorkItem?

    // Error row.
    private let errorBody = NSTextField(wrappingLabelWithString: "")
    private let retryButton = HelmButton(title: "Try again", variant: .quiet, size: .small)
    private lazy var errorRow = HelmAccentRow(contentView: errorBody, trailingAccessory: retryButton, hover: false)

    var onRunInTerminal: ((String) -> Void)?
    /// Fires whenever the content's fitting height may have changed;
    /// `ConsoleComposerController` hands it to `popover.contentSize`.
    var onSizeChanged: ((NSSize) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        root.wantsLayer = true
        view = root

        header.set(title: "Compose a command", subtitle: "Describe it, review it, then run it. Nothing runs on its own.")

        buildWell()
        buildChips()
        buildWorkingCard()
        buildResultCard()
        buildErrorRow()

        let body = NSStackView(views: [well, workingCard, resultCard, errorRow, examplesKicker, examplesFlow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.setCustomSpacing(HelmMetrics.s3, after: well)
        body.setCustomSpacing(HelmMetrics.s3, after: workingCard)
        body.setCustomSpacing(HelmMetrics.s3, after: resultCard)
        body.setCustomSpacing(HelmMetrics.s3, after: errorRow)
        body.setCustomSpacing(6, after: examplesKicker)
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in body.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        root.addSubview(header)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.inset),
        ] + body.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: body.widthAnchor) })

        render()
        applyTheme(theme)
    }

    // MARK: Building

    /// C1's prompt well, with the footer (the target tab, the shortcut and
    /// Generate) inside it.
    private func buildWell() {
        well.placeholder = "e.g. list pods in kube-system"
        intentTextView.delegate = self
        intentTextView.setAccessibilityLabel("Command intent")

        generateButton.toolTip = AITransparency.willSendToClaude("what you typed, with secrets redacted,")
        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        // `⌘⏎` fires Generate whatever has focus: `NSWindow`'s
        // `performKeyEquivalent:` reaches this button before the key event
        // reaches the text view, where a plain Return inserts a new line.
        generateButton.keyEquivalent = "\r"
        generateButton.keyEquivalentModifierMask = [.command]

        generateButton.setContentHuggingPriority(.required, for: .horizontal)
        generateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Gotcha (10)/(12): the target line is the one flexible piece.
        let footer = NSStackView(views: [targetLabel, shortcutCap, generateButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = HelmMetrics.s2
        footer.setCustomSpacing(HelmMetrics.s3, after: targetLabel)
        well.setFooter(footer)
    }

    private func buildChips() {
        exampleButtons = Self.exampleIntents.map { example in
            let button = HelmButton(title: example.text, variant: .secondary, size: .small, symbol: example.symbol)
            button.surface = .raised
            button.target = self
            button.action = #selector(exampleClicked(_:))
            button.toolTip = "Fill the field with \u{201C}\(example.text)\u{201D}"
            return button
        }
        examplesFlow.setChips(exampleButtons)
    }

    /// Comp-1's generating state: a dashed card with an hourglass, what is
    /// happening, the elapsed time and two placeholder lines where the
    /// command will land.
    private func buildWorkingCard() {
        workingGlyph.translatesAutoresizingMaskIntoConstraints = false
        workingLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        workingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workingElapsed.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11), weight: .regular)
        workingElapsed.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The ticking elapsed time is the live signal: the kit has no spinner
        // (UI-61), and a static glyph needs no Reduce Motion gate.
        let top = NSStackView(views: [workingGlyph, workingLabel, spacer, workingElapsed])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.distribution = .fill
        top.spacing = HelmMetrics.s2
        let stack = NSStackView(views: [top] + workingBars)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        workingCard.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: workingCard.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: workingCard.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: workingCard.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: workingCard.bottomAnchor, constant: -12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        for (bar, fraction) in zip(workingBars, [0.92, 0.64]) {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 4.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            constraints += [
                bar.heightAnchor.constraint(equalToConstant: 9),
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: fraction),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        workingCard.setAccessibilityElement(true)
        workingCard.setAccessibilityRole(.staticText)
        workingCard.setAccessibilityLabel("Claude is writing the command")
    }

    /// The generated command on a section card: the command in the terminal
    /// scheme's own colours behind a `$` prompt, then Copy and Run in Terminal
    /// with where Run sends it.
    private func buildResultCard() {
        resultCard.wantsLayer = true
        resultCard.layer?.cornerRadius = Self.cardRadius
        resultCard.layer?.borderWidth = 1
        resultKicker.attributedStringValue = NSAttributedString(
            string: "Generated command".uppercased(), attributes: [.font: HelmType.kicker(), .kern: HelmType.kickerKern])
        resultMeta.font = HelmType.caption()
        resultMeta.alignment = .right
        resultMeta.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resultKicker.setContentHuggingPriority(.required, for: .horizontal)
        resultKicker.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [resultKicker, resultMeta])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.distribution = .fill

        codePanel.wantsLayer = true
        codePanel.layer?.cornerRadius = 10
        codePanel.layer?.borderWidth = 1
        codeLabel.isSelectable = true
        codeLabel.lineBreakMode = .byWordWrapping
        codeLabel.maximumNumberOfLines = 0
        codeLabel.cell?.wraps = true
        codeLabel.cell?.isScrollable = false
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        codePanel.addSubview(codeLabel)

        reviewLabel.font = HelmType.caption()
        reviewLabel.maximumNumberOfLines = 2
        reviewLabel.lineBreakMode = .byWordWrapping
        reviewLabel.cell?.wraps = true
        reviewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reviewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.surface = .raised
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.keyEquivalent = "\r"
        for button in [copyButton, runButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let actions = NSStackView(views: [reviewLabel, copyButton, runButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.spacing = 6
        actions.setCustomSpacing(HelmMetrics.s2, after: reviewLabel)

        let stack = NSStackView(views: [top, codePanel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.setCustomSpacing(9, after: codePanel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        resultCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: resultCard.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: resultCard.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: resultCard.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: resultCard.bottomAnchor, constant: -10),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codePanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeLabel.leadingAnchor.constraint(equalTo: codePanel.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: codePanel.trailingAnchor, constant: -12),
            codeLabel.topAnchor.constraint(equalTo: codePanel.topAnchor, constant: 10),
            codeLabel.bottomAnchor.constraint(equalTo: codePanel.bottomAnchor, constant: -10),
        ])
        // Gotcha (22): the wrap width comes from what this label does not
        // decide - the popover's fixed width less the insets around it.
        codeLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset - 2 * 10 - 2 * 12
        reviewLabel.preferredMaxLayoutWidth = 170
    }

    private func buildErrorRow() {
        errorBody.font = .systemFont(ofSize: HelmType.scaled(12.5))
        errorBody.isSelectable = true
        errorBody.translatesAutoresizingMaskIntoConstraints = false
        retryButton.tint = .accent
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.toolTip = "Generate again from the same intent"
        errorRow.actionReveal = .always
    }

    // MARK: State

    func setTargetTabName(_ name: String?) {
        targetTabName = name?.isEmpty == false ? name : nil
        applyTargetName()
    }

    func reset() {
        intentTextView.string = ""
        intentTextView.isEditable = true
        stopWorkingTimer()
        copiedReset?.cancel()
        phase = .idle
        render()
        updateIntentFeedback()
    }

    /// Shows `phase`: one of the working card, the result card and the error
    /// row (or none), the examples under them, and the controls' enablement.
    private func render() {
        guard isViewLoaded else { return }
        var generating = false
        if case .generating = phase { generating = true }
        workingCard.isHidden = !generating
        resultCard.isHidden = true
        errorRow.isHidden = true
        switch phase {
        case .idle, .generating:
            break
        case let .result(command, seconds):
            resultCard.isHidden = false
            resultMeta.stringValue = String(format: "claude \u{00B7} %.1fs", seconds)
            setCode(command)
            setCopied(false)
        case let .failed(message):
            errorRow.isHidden = false
            errorBody.stringValue = message
            errorRow.configure(HelmAccentRow.Content(tint: .critical, kicker: "Couldn't generate",
                                                     badgeSymbol: "exclamationmark.triangle.fill"), theme: theme)
        }
        examplesKicker.attributedStringValue = NSAttributedString(
            string: (resultCard.isHidden ? "Suggestions" : "Try another").uppercased(),
            attributes: [.font: HelmType.kicker(), .kern: HelmType.kickerKern,
                         .foregroundColor: HelmTheme.mutedInk(theme)])
        // C1: the examples carry no kicker under an empty well; "Try another" names them under a result.
        examplesKicker.isHidden = generating || resultCard.isHidden
        examplesFlow.isHidden = generating
        intentTextView.isEditable = !generating
        generateButton.title = generating ? "Generating\u{2026}" : "Generate"
        exampleButtons.forEach { $0.isEnabled = !generating }
        updateIntentFeedback()
        applyTargetName()
        updateSize()
    }

    private func updateIntentFeedback() {
        var generating = false
        if case .generating = phase { generating = true }
        generateButton.isEnabled = !generating
            && !intentTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyTargetName() {
        well.setFootnote(targetLabel, "runs in ", emphasis: targetTabName ?? "this tab")
        targetLabel.toolTip = "Run in Terminal sends the command to \(targetTabName ?? "the tab in front")"
        reviewLabel.stringValue = targetTabName.map { "Review it first.\nRun sends it to \($0)." } ?? "Review it first.\nRun sends it to this tab."
    }

    private func setCode(_ command: String) {
        let scheme = ThemeManager.shared.terminalScheme
        let font = NSFont.monospacedSystemFont(ofSize: HelmType.scaled(11.5), weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        let prompt = HelmTheme.nsColor(scheme.ansiHex.count > 4 ? scheme.ansiHex[4] : scheme.cursorHex)
        let text = NSMutableAttributedString(string: "$ ", attributes: [.font: font, .foregroundColor: prompt,
                                                                        .paragraphStyle: paragraph])
        text.append(NSAttributedString(string: command, attributes: [
            .font: font, .foregroundColor: HelmTheme.nsColor(scheme.foregroundHex), .paragraphStyle: paragraph]))
        codeLabel.attributedStringValue = text
        codeLabel.setAccessibilityLabel("Generated command: \(command)")
    }

    private func setCopied(_ copied: Bool) {
        copyButton.title = copied ? "Copied" : "Copy"
        copyButton.symbolName = copied ? "checkmark" : "doc.on.doc"
        copyButton.tint = copied ? .good : nil
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(NSSize(width: Self.width, height: view.fittingSize.height))
    }

    private func startWorkingTimer(from start: Date) {
        stopWorkingTimer()
        workingElapsed.stringValue = "0s"
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.workingElapsed.stringValue = "\(Int(Date().timeIntervalSince(start)))s"
        }
        timer.tolerance = 0.2
        workingTimer = timer
    }

    private func stopWorkingTimer() {
        workingTimer?.invalidate()
        workingTimer = nil
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        view.layer?.backgroundColor = surface.cgColor
        header.applyTheme(theme)
        well.domainHue = theme.isDaylight ? RailDestination.console.domainHue : nil
        well.applyTheme(theme)

        let raisedEdge = HelmField.border(theme, surface: .raised)
        workingCard.dashColor = raisedEdge
        workingLabel.textColor = ink
        workingElapsed.textColor = muted
        workingGlyph.image = HelmSymbol.image("hourglass", pointSize: HelmType.scaled(11), weight: .semibold)
        workingGlyph.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        let track = theme.mode == .dark ? surface.blended(withFraction: 0.14, of: ink) ?? line
                                        : line.blended(withFraction: 0.25, of: surface) ?? line
        workingBars.forEach { $0.layer?.backgroundColor = track.cgColor }

        resultCard.layer?.backgroundColor = surface.cgColor
        resultCard.layer?.borderColor = line.cgColor
        resultKicker.textColor = muted
        resultMeta.textColor = muted
        reviewLabel.textColor = muted
        let scheme = ThemeManager.shared.terminalScheme
        let codeFill = HelmTheme.nsColor(scheme.backgroundHex)
        codePanel.layer?.backgroundColor = codeFill.cgColor
        let codeEdge = codeFill.blended(withFraction: 0.1, of: theme.mode == .dark ? .white : .black) ?? line
        codePanel.layer?.borderColor = codeEdge.cgColor
        if case let .result(command, _) = phase { setCode(command) }

        errorBody.textColor = ink
        if case .failed = phase {
            errorRow.configure(HelmAccentRow.Content(tint: .critical, kicker: "Couldn't generate",
                                                     badgeSymbol: "exclamationmark.triangle.fill"), theme: theme)
        }
        examplesKicker.textColor = muted
        render()
        // `HelmButton` themes itself.
    }

    // MARK: Actions

    func focusIntentField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.intentTextView)
        }
    }

    func textDidChange(_ notification: Notification) {
        updateIntentFeedback()
    }

    /// One of `Self.exampleIntents`: fills and focuses the field. Never
    /// generates - the field is filled for the captain to review or edit.
    @objc private func exampleClicked(_ sender: HelmButton) {
        guard let index = exampleButtons.firstIndex(where: { $0 === sender }) else { return }
        intentTextView.string = Self.exampleIntents[index].text
        updateIntentFeedback()
        view.window?.makeFirstResponder(intentTextView)
    }

    @objc private func generateClicked() {
        let intent = intentTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return }
        if case .generating = phase { return }
        let started = Date()
        phase = .generating(started: started)
        startWorkingTimer(from: started)
        render()
        ConsoleCommandComposer.generate(intent: intent) { [weak self] result in
            guard let self else { return }
            self.stopWorkingTimer()
            switch result {
            case .success(let command):
                self.phase = .result(command: command, seconds: Date().timeIntervalSince(started))
            case .failure(let error):
                self.phase = .failed(message: Self.sentence(error.message))
            }
            self.render()
        }
    }

    /// A failure message as a sentence: capitalised, with a full stop.
    static func sentence(_ message: String) -> String {
        guard let first = message.first else { return message }
        var text = first.uppercased() + message.dropFirst()
        if !text.hasSuffix(".") { text += "." }
        return text
    }

    @objc private func retryClicked() {
        generateClicked()
    }

    @objc private func copyClicked() {
        guard case let .result(command, _) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        setCopied(true)
        copiedReset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setCopied(false) }
        copiedReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedDuration, execute: work)
    }

    /// The only path that ever sends the generated command anywhere - never
    /// called automatically, only from this explicit button click (or its
    /// ⏎ key equivalent).
    @objc private func runClicked() {
        guard case let .result(command, _) = phase else { return }
        onRunInTerminal?(command)
    }

    #if FM_SELFTESTS
    /// Sets a state directly, for a render or a suite: no `claude` runs.
    func debugShow(intent: String, phase: Phase, focused: Bool = false) {
        intentTextView.string = intent
        self.phase = phase
        stopWorkingTimer()
        if case .generating = phase { workingElapsed.stringValue = "3s" }
        render()
        if focused { view.window?.makeFirstResponder(intentTextView) }
    }
    var debugWell: HelmPromptWell { well }
    var debugExampleButtons: [HelmButton] { exampleButtons }
    var debugCopyButton: HelmButton { copyButton }
    var debugRetryButton: HelmButton { retryButton }
    var debugTargetText: String { targetLabel.isHidden ? "" : targetLabel.stringValue }
    var debugVisibleSections: [String] {
        [("working", workingCard), ("result", resultCard), ("error", errorRow)]
            .filter { !$0.1.isHidden }.map(\.0)
    }
    func debugClickCopy() { copyButton.performClick(nil) }
    var debugIntentTextView: NSTextView { intentTextView }
    #endif
}

/// A card drawn with a dashed hairline - Comp-1's "the command will land
/// here" placeholder while Claude writes it.
private final class DashedCardView: NSView {
    private let border = CAShapeLayer()
    var dashColor: NSColor = .separatorColor {
        didSet { HelmMotion.withoutActions { border.strokeColor = dashColor.cgColor } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        border.fillColor = nil
        border.lineWidth = 1
        border.lineDashPattern = [4, 3]
        layer?.addSublayer(border)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        HelmMotion.withoutActions {
            border.frame = bounds
            border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 cornerWidth: ConsoleComposerViewController.cardRadius,
                                 cornerHeight: ConsoleComposerViewController.cardRadius, transform: nil)
        }
    }
}

#if FM_SELFTESTS
extension ConsoleComposerController {
    /// The popover's content view, laid out at its own size, for a render or
    /// a suite. Nothing is shown in a window.
    var debugContentView: NSView { content.view }
    func debugShow(intent: String, phase: ConsoleComposerDebugPhase, target: String?, focused: Bool = false) {
        content.setTargetTabName(target)
        let mapped: ConsoleComposerViewController.Phase
        switch phase {
        case .idle: mapped = .idle
        case .generating: mapped = .generating(started: Date())
        case let .result(command): mapped = .result(command: command, seconds: 2.4)
        case let .failed(message): mapped = .failed(message: message)
        }
        content.debugShow(intent: intent, phase: mapped, focused: focused)
    }
    var debugWell: HelmPromptWell { content.debugWell }
    var debugExampleButtons: [HelmButton] { content.debugExampleButtons }
    var debugCopyButton: HelmButton { content.debugCopyButton }
    var debugTargetText: String { content.debugTargetText }
    var debugVisibleSections: [String] { content.debugVisibleSections }
    func debugClickCopy() { content.debugClickCopy() }
    func debugApplyTheme(_ theme: HelmTheme) { content.applyTheme(theme) }
    var debugIntentTextView: NSTextView { content.debugIntentTextView }
}

/// The states a suite or a render can put the Compose popover in.
enum ConsoleComposerDebugPhase {
    case idle
    case generating
    case result(String)
    case failed(String)
}
#endif
