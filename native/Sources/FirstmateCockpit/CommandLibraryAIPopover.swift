// Manjesh Grand Line - native macOS app.
//
// The one UI surface for Command Library Phase 3's AI actions
// (`CommandLibraryAI.swift`). Modelled on `ConsoleComposerPopover`, which is
// this app's established shape for "one `claude -p` call, shown for review,
// never applied on its own" - same `NSPopover` + plain `NSViewController`
// content, same `.transient` behaviour, same live `ThemeManager` observation
// (including forcing `popover.appearance`, which AppKit's vibrant material
// does NOT do for you - see `FullAppAuditUISelfTest.checkEveryPopoverForces
// Appearance`, the guard that exists because two popovers shipped without it).
//
// ## What it shows, and the one thing it can write
//
// Explain and Troubleshoot render prose and offer Copy. Only Improve can offer
// "Save as template", and only when `CommandLibraryAI.parse` actually
// recovered a template from the reply - a model that answered in prose leaves
// the button hidden rather than offering to write that prose over a working,
// possibly destructive command. The save itself goes through the caller's own
// closure (`onSaveTemplate`), which is wired to the same
// `CommandLibraryStore.updateCommand` the editor sheet uses; there is no
// second write path.
//
// Troubleshoot is the only action with an input: an optional box for the error
// or output the captain actually saw. Empty is a supported answer - the prompt
// says so explicitly rather than inventing an error to reason about.

import AppKit

/// Owns the popover. One per `CommandLibraryPageView`.
final class CommandLibraryAIController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = CommandLibraryAIViewController()
    private var themeObservation: ThemeObservation?

    /// Fires when the captain presses "Save as template" on an Improve
    /// result. The page wires this to the real store write.
    var onSaveTemplate: ((String) -> Void)?

    override init() {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onSaveTemplate = { [weak self] template in
            self?.onSaveTemplate?(template)
            self?.popover.performClose(nil)
        }
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    var isShown: Bool { popover.isShown }

    /// Opens the popover for one action against one command and starts the
    /// call (or, for Troubleshoot, waits for the captain to press Ask).
    func present(action: CommandLibraryAIAction, command: DevOpsCommand, relativeTo view: NSView) {
        content.configure(action: action, command: command)
        if !popover.isShown {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        content.startIfImmediate()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Mirrors `ConsoleComposerController.shutdown()` - this observer belongs
    /// to a page that can be torn down, so the token is unregistered rather
    /// than leaking a dead closure into `ThemeManager.observers`.
    func shutdown() {
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }

    /// Belt to `shutdown()`'s braces. `CommandLibraryPageView` is
    /// app-lifetime today (it hangs off the permanently-mounted `.shift`
    /// destination), so nothing calls `shutdown()` yet and nothing leaks -
    /// but a page view that becomes destroyable later should not have to
    /// remember, which is exactly the trap `ConsoleController` had to unpick
    /// once its own pages became per-host.
    deinit { shutdown() }

    #if FM_SELFTESTS
    var debugContent: CommandLibraryAIViewController { content }
    #endif
}

/// The popover's content. Internal rather than private only so the self-test
/// can drive the real buttons; nothing outside this file constructs one.
final class CommandLibraryAIViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    static let width: CGFloat = 460
    private static let inputHeight: CGFloat = 64
    private static let resultHeight: CGFloat = 190

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private let inputScroll = NSScrollView()
    private let inputTextView = NSTextView()
    private let askButton = HelmButton(title: "Ask", variant: .primary, target: nil, action: nil)

    private let statusLabel = NSTextField(labelWithString: "")
    private let resultScroll = NSScrollView()
    private let resultTextView = NSTextView()
    private let copyButton = HelmButton(title: "Copy", variant: .secondary, target: nil, action: nil)
    private let saveTemplateButton = HelmButton(title: "Save as template", variant: .primary, target: nil, action: nil)
    private let resultStack = NSStackView()
    private let inputStack = NSStackView()

    private var action: CommandLibraryAIAction = .explain
    private var command: DevOpsCommand?
    private var suggestedTemplate: String?
    private var statusIsError = false

    var onSaveTemplate: ((String) -> Void)?
    var onSizeChanged: ((NSSize) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 240))
        root.wantsLayer = true
        view = root

        iconTile.configure(symbol: "sparkles", tint: .violet)

        titleLabel.font = HelmType.rowTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleColumn = NSStackView(views: [titleLabel, subtitleLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 1
        titleColumn.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [iconTile, titleColumn])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        buildTextArea(inputScroll, inputTextView, editable: true, height: Self.inputHeight)
        buildTextArea(resultScroll, resultTextView, editable: false, height: Self.resultHeight)

        askButton.controlSize = .small
        askButton.target = self
        askButton.action = #selector(askClicked)
        askButton.keyEquivalent = "\r"
        askButton.keyEquivalentModifierMask = [.command]
        askButton.setContentHuggingPriority(.required, for: .horizontal)

        let askSpacer = NSView()
        askSpacer.translatesAutoresizingMaskIntoConstraints = false
        askSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let askRow = NSStackView(views: [askSpacer, askButton])
        askRow.orientation = .horizontal
        askRow.distribution = .fill
        askRow.alignment = .centerY
        askRow.translatesAutoresizingMaskIntoConstraints = false

        inputStack.orientation = .vertical
        inputStack.alignment = .leading
        inputStack.spacing = HelmMetrics.s2
        inputStack.translatesAutoresizingMaskIntoConstraints = false
        inputStack.setViews([inputScroll, askRow], in: .leading)

        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        saveTemplateButton.controlSize = .small
        saveTemplateButton.target = self
        saveTemplateButton.action = #selector(saveTemplateClicked)
        saveTemplateButton.setContentHuggingPriority(.required, for: .horizontal)
        saveTemplateButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actionSpacer = NSView()
        actionSpacer.translatesAutoresizingMaskIntoConstraints = false
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [actionSpacer, copyButton, saveTemplateButton])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fill
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        resultStack.orientation = .vertical
        resultStack.alignment = .leading
        resultStack.spacing = HelmMetrics.s2
        resultStack.translatesAutoresizingMaskIntoConstraints = false
        resultStack.setViews([resultScroll, actionRow], in: .leading)

        let stack = NSStackView(views: [titleRow, inputStack, statusLabel, resultStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputScroll.widthAnchor.constraint(equalTo: inputStack.widthAnchor),
            askRow.widthAnchor.constraint(equalTo: inputStack.widthAnchor),
            resultScroll.widthAnchor.constraint(equalTo: resultStack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: resultStack.widthAnchor),
        ])

        applyTheme(theme)
    }

    /// A themed, sunken text area - `HelmField`'s own recipe, so these match
    /// every other well in the app rather than carrying a fourth hand-rolled
    /// copy of the fill/border (the duplication Phase 6 removed).
    private func buildTextArea(_ scroll: NSScrollView, _ textView: NSTextView, editable: Bool, height: CGFloat) {
        textView.isEditable = editable
        textView.isSelectable = true
        // Rich text is the default, which means `font`/`textColor` only touch
        // the *typing* attributes and text already in the view keeps whatever
        // it had - invisible glyphs on a dark card. See AGENTS.md's Kubernetes
        // describe-panel findings.
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        HelmField.makeSunken(scroll)
    }

    // MARK: Configuration

    func configure(action: CommandLibraryAIAction, command: DevOpsCommand) {
        self.action = action
        self.command = command
        self.suggestedTemplate = nil

        titleLabel.stringValue = action.title.replacingOccurrences(of: "\u{2026}", with: "")
        subtitleLabel.stringValue = command.name

        inputStack.isHidden = !action.takesErrorInput
        inputTextView.string = ""
        resultTextView.string = ""
        resultStack.isHidden = true
        saveTemplateButton.isHidden = true
        setStatus(action.takesErrorInput
                  ? "Paste the error or output you saw, then press Ask. Leaving it empty is fine."
                  : "", isError: false)
        applyTheme(theme)
        notifySize()
    }

    /// Explain and Improve need no input, so they start the moment the
    /// popover opens; Troubleshoot waits for Ask.
    func startIfImmediate() {
        if action.takesErrorInput {
            view.window?.makeFirstResponder(inputTextView)
        } else {
            runAction()
        }
    }

    @objc private func askClicked() { runAction() }

    private func runAction() {
        guard let command else { return }
        askButton.isEnabled = false
        resultStack.isHidden = true
        saveTemplateButton.isHidden = true
        setStatus("Asking Claude\u{2026}", isError: false)
        notifySize()

        CommandLibraryAI.run(action: action, command: command, errorText: inputTextView.string) { [weak self] result in
            guard let self else { return }
            self.askButton.isEnabled = true
            switch result {
            case .success(let reply):
                self.suggestedTemplate = reply.suggestedTemplate
                self.resultTextView.string = reply.suggestedTemplate.map { "\($0)\n\n\(reply.text)" } ?? reply.text
                self.resultStack.isHidden = false
                // Offered only when a template was genuinely recovered - see
                // this file's header and `CommandLibraryAI.parse`.
                self.saveTemplateButton.isHidden = !(self.action.offersSaveAsTemplate && reply.suggestedTemplate != nil)
                self.setStatus(self.action.resultHeading, isError: false)
            case .failure(let error):
                self.setStatus(error.message, isError: true)
            }
            self.applyTheme(self.theme)
            self.notifySize()
        }
    }

    @objc private func copyClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resultTextView.string, forType: .string)
        Toast.show(in: view, message: "Copied")
    }

    @objc private func saveTemplateClicked() {
        guard let template = suggestedTemplate, !template.isEmpty else { return }
        onSaveTemplate?(template)
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusIsError = isError
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        statusLabel.textColor = isError
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                             theme: theme)
            : HelmTheme.mutedInk(theme)
    }

    private func notifySize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(NSSize(width: Self.width, height: view.fittingSize.height))
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // `ThemeManager.swift`'s checklist item 2. A popover's vibrant
        // material follows the OS, not this app's theme, unless told.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        setStatus(statusLabel.stringValue, isError: statusIsError)

        for (scroll, textView) in [(inputScroll, inputTextView), (resultScroll, resultTextView)] {
            HelmField.applySunken(to: scroll, theme: theme)
            textView.font = HelmType.code()
            textView.textColor = HelmField.ink(theme)
            textView.insertionPointColor = HelmField.ink(theme)
            HelmSelection.apply(to: textView, theme: theme)
        }
    }

    #if FM_SELFTESTS
    var debugStatus: String { statusLabel.stringValue }
    var debugStatusIsError: Bool { statusIsError }
    var debugResult: String { resultTextView.string }
    var debugResultIsVisible: Bool { !resultStack.isHidden }
    var debugSaveTemplateVisible: Bool { !saveTemplateButton.isHidden }
    var debugInputIsVisible: Bool { !inputStack.isHidden }
    var debugSuggestedTemplate: String? { suggestedTemplate }
    func debugSetErrorText(_ text: String) { inputTextView.string = text }
    func debugAsk() { askClicked() }
    func debugSaveTemplate() { saveTemplateClicked() }
    #endif
}
