// Manjesh Grand Line - native macOS app.
//
// The "Video" Stores destination (fm/grandline-videogen-feasibility-scout,
// promoted from a scout to a ship task after that report's own live
// validation on this exact hardware succeeded - see the report for the full
// evidence behind every choice below, and `VideoGenEnvironment.swift`'s
// header for why setup runs through a real Console tab rather than a custom
// Swift download manager).
//
// Follows `DictationController.swift`'s established shape closely: the same
// "hide, don't rebuild" body-child convention, the same `HelmCard`-based
// section layout, the same row-building rules this codebase's AppKit gotcha
// catalogue documents repeatedly (`.fill` distribution + stack-level
// hugging on the text column - gotchas #10/#12; see `DictationController
// .viewDidLayout`'s own doc comment for the fullest write-up of why).
//
// Two cards: Setup (state + one action button, mirrors `WhisperModelManager`
// -driven UI but with no progress bar - see the file header on
// `VideoGenEnvironment` for why) and Generate (a prompt field, an optional
// "Enhance with Claude" toggle, a Generate button, and the result of the
// last run). Status is re-read from real on-disk state on every
// `viewWillAppear`, matching `VaultController`/`DictationController`'s own
// "refresh on appear, no polling" convention.

import AppKit

final class VideoGenController: NSViewController, DaylightDrillActions {

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let refreshButton = HelmButton(symbol: "arrow.clockwise", variant: .quiet)

    // MARK: Setup card

    private let setupPanel = HelmCard()
    private let setupIconTile = IconTileView(size: 40, cornerRadius: 10)
    private let setupTitleLabel = NSTextField(labelWithString: "")
    private let setupDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var setupTextStack = NSStackView()
    private let setupActionButton = HelmButton(title: "", variant: .primary)
    private let setupProgress = NSProgressIndicator()

    // MARK: Generate card

    private let generatePanel = HelmCard()
    private let promptField = HelmTextField(placeholder: "Describe the shot you want, e.g. \u{201C}a calm ocean at sunset\u{201D}")
    private let enhanceSwitch = NSSwitch()
    private let enhanceTitleLabel = NSTextField(labelWithString: "")
    private let enhanceDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var enhanceTextStack = NSStackView()
    private let generateButton = HelmButton(title: "Generate", variant: .primary)
    private let generateProgress = NSProgressIndicator()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let revealButton = HelmButton(title: "Reveal in Finder", variant: .secondary)

    private let footnoteLabel = NSTextField(wrappingLabelWithString: "")

    private var state: VideoGenState = .notSetUp
    private var isGenerating = false
    private var isEnhancing = false
    private var lastOutputPath: URL?
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Forwarded to `AppShellController`, exactly like `bootstrap
    /// .onRunCommand`/`vault.onRunCommand` - this controller owns no Console
    /// tab of its own, only what command to run in one.
    var onRunCommand: ((String, String) -> Void)?
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        root.wantsLayer = true
        view = root

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        buildDrillActions()
        _ = buildSetupSection()
        _ = buildGenerateSection()
        buildFootnote()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(setupPanel)
        contentStack.addArrangedSubview(generatePanel)
        contentStack.addArrangedSubview(footnoteLabel)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            setupPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            generatePanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footnoteLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        for (stack, label) in [
            (setupTextStack, setupDetailLabel),
            (enhanceTextStack, enhanceDetailLabel),
        ] {
            let available = stack.bounds.width
            guard available > 0, label.preferredMaxLayoutWidth != available else { continue }
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
        }
    }

    /// Re-reads real on-disk state - see `VideoGenEnvironment.currentState()`'s
    /// own doc comment for why this is a cheap file check, not a poll.
    func refresh() {
        setState(VideoGenEnvironment.currentState())
    }

    private func setState(_ newState: VideoGenState) {
        state = newState
        render()
        onDrillSubtitleChanged?()
    }

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?
    var drillHeaderActions: [NSView] { [refreshButton] }

    var drillHeaderSubtitle: String? {
        switch state {
        case .notSetUp: return "Not set up"
        case .settingUp: return "Setting up..."
        case .ready: return isGenerating ? "Generating..." : "Ready"
        case .failed: return "Setup failed"
        }
    }

    private func buildDrillActions() {
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Re-check the video model's setup state"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Building the static chrome

    private func buildSetupSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Setup")
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        setupPanel.setHeader(sectionLabel)

        setupTitleLabel.font = HelmType.cardTitle()
        setupTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        setupDetailLabel.font = HelmType.caption()
        setupDetailLabel.preferredMaxLayoutWidth = 520
        setupDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        setupTextStack = NSStackView(views: [setupTitleLabel, setupDetailLabel])
        setupTextStack.orientation = .vertical
        setupTextStack.alignment = .leading
        setupTextStack.spacing = 3
        setupTextStack.translatesAutoresizingMaskIntoConstraints = false
        setupTextStack.setHuggingPriority(.defaultLow, for: .horizontal)
        setupTextStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        setupProgress.style = .spinning
        setupProgress.controlSize = .small
        setupProgress.isDisplayedWhenStopped = false
        setupProgress.setContentHuggingPriority(.required, for: .horizontal)
        setupProgress.setContentCompressionResistancePriority(.required, for: .horizontal)
        setupProgress.translatesAutoresizingMaskIntoConstraints = false

        setupActionButton.controlSize = .regular
        setupActionButton.target = self
        setupActionButton.action = #selector(setupActionTapped)
        setupActionButton.setContentHuggingPriority(.required, for: .horizontal)
        setupActionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        setupActionButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [setupIconTile, setupTextStack, setupProgress, setupActionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        setupPanel.setBody(row, insets: HelmCard.contentInsets)
        return setupPanel
    }

    private func buildGenerateSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Generate")
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        generatePanel.setHeader(sectionLabel)

        promptField.translatesAutoresizingMaskIntoConstraints = false

        enhanceTitleLabel.stringValue = "Enhance with Claude"
        enhanceTitleLabel.font = HelmType.rowTitle()
        enhanceTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        enhanceDetailLabel.stringValue = "Rewrites your idea into a detailed, cinematic prompt before generating."
        enhanceDetailLabel.font = HelmType.caption()
        enhanceDetailLabel.preferredMaxLayoutWidth = 460
        enhanceDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        enhanceTextStack = NSStackView(views: [enhanceTitleLabel, enhanceDetailLabel])
        enhanceTextStack.orientation = .vertical
        enhanceTextStack.alignment = .leading
        enhanceTextStack.spacing = 3
        enhanceTextStack.translatesAutoresizingMaskIntoConstraints = false
        enhanceTextStack.setHuggingPriority(.defaultLow, for: .horizontal)
        enhanceTextStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        enhanceSwitch.target = self
        enhanceSwitch.action = #selector(enhanceToggled)
        enhanceSwitch.setContentHuggingPriority(.required, for: .horizontal)
        enhanceSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        enhanceSwitch.translatesAutoresizingMaskIntoConstraints = false

        let enhanceRow = NSStackView(views: [enhanceTextStack, enhanceSwitch])
        enhanceRow.orientation = .horizontal
        enhanceRow.alignment = .top
        enhanceRow.spacing = 14
        enhanceRow.distribution = .fill
        enhanceRow.translatesAutoresizingMaskIntoConstraints = false

        generateProgress.style = .spinning
        generateProgress.controlSize = .small
        generateProgress.isDisplayedWhenStopped = false
        generateProgress.setContentHuggingPriority(.required, for: .horizontal)
        generateProgress.setContentCompressionResistancePriority(.required, for: .horizontal)
        generateProgress.translatesAutoresizingMaskIntoConstraints = false

        generateButton.controlSize = .regular
        generateButton.target = self
        generateButton.action = #selector(generateTapped)
        generateButton.setContentHuggingPriority(.required, for: .horizontal)
        generateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        generateButton.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [generateProgress, NSView(), generateButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        actionRow.distribution = .fill
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        // The middle spacer absorbs leftover width so the button stays
        // pinned to the trailing edge - AGENTS.md gotcha #10.
        actionRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        resultLabel.font = HelmType.caption()
        resultLabel.preferredMaxLayoutWidth = 520
        resultLabel.isHidden = true
        resultLabel.translatesAutoresizingMaskIntoConstraints = false

        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        revealButton.isHidden = true
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        let resultRow = NSStackView(views: [resultLabel, revealButton])
        resultRow.orientation = .horizontal
        resultRow.alignment = .centerY
        resultRow.spacing = 10
        resultRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [promptField, enhanceRow, actionRow, resultRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptField.widthAnchor.constraint(equalTo: column.widthAnchor),
            enhanceRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        generatePanel.setBody(column, insets: HelmCard.contentInsets)
        return generatePanel
    }

    private func buildFootnote() {
        footnoteLabel.stringValue = "Generation runs entirely on this Mac. Clips are saved to \u{2039}\(VideoGenEnvironment.outputDir().path)\u{203A}."
        footnoteLabel.font = HelmType.caption()
        footnoteLabel.preferredMaxLayoutWidth = 620
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Rendering

    private func render() {
        switch state {
        case .notSetUp:
            setupIconTile.configure(symbol: "arrow.down.circle", tint: .info)
            setupTitleLabel.stringValue = "Video model not set up"
            setupDetailLabel.stringValue = "Downloads LTX-2 (~27GB) and installs a local Python environment. Takes about 15 minutes."
            setupActionButton.title = "Set Up"
            setupActionButton.isHidden = false
            setupActionButton.isEnabled = VideoGenEnvironment.resolveSetupScript() != nil
            setupProgress.isHidden = true
            setupProgress.stopAnimation(nil)
        case .settingUp:
            setupIconTile.configure(symbol: "arrow.down.circle", tint: .info)
            setupTitleLabel.stringValue = "Setting up..."
            setupDetailLabel.stringValue = "Watch progress in the Console tab that just opened. This page updates once it finishes."
            setupActionButton.isHidden = true
            setupProgress.isHidden = false
            setupProgress.startAnimation(nil)
        case .ready:
            setupIconTile.configure(symbol: "checkmark.circle", tint: .good)
            setupTitleLabel.stringValue = "Ready"
            setupDetailLabel.stringValue = "The local video model is downloaded and ready to generate."
            setupActionButton.title = "Re-run Setup"
            setupActionButton.isHidden = false
            setupActionButton.isEnabled = VideoGenEnvironment.resolveSetupScript() != nil
            setupProgress.isHidden = true
            setupProgress.stopAnimation(nil)
        case .failed(let message):
            setupIconTile.configure(symbol: "exclamationmark.triangle", tint: .critical)
            setupTitleLabel.stringValue = "Setup failed"
            setupDetailLabel.stringValue = message
            setupActionButton.title = "Retry Setup"
            setupActionButton.isHidden = false
            setupActionButton.isEnabled = VideoGenEnvironment.resolveSetupScript() != nil
            setupProgress.isHidden = true
            setupProgress.stopAnimation(nil)
        }

        let ready: Bool
        if case .ready = state { ready = true } else { ready = false }
        promptField.isEnabled = ready && !isGenerating
        enhanceSwitch.isEnabled = ready && !isGenerating
        generateButton.isEnabled = ready && !isGenerating && !isEnhancing
        generateButton.title = isEnhancing ? "Enhancing..." : "Generate"
        generateProgress.isHidden = !(isGenerating || isEnhancing)
        if isGenerating || isEnhancing { generateProgress.startAnimation(nil) } else { generateProgress.stopAnimation(nil) }

        applyTheme()
    }

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        setupPanel.applyTheme(theme)
        generatePanel.applyTheme(theme)
        setupIconTile.applyTheme(theme)
        setupTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        setupDetailLabel.textColor = HelmTheme.mutedInk(theme)
        enhanceTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        enhanceDetailLabel.textColor = HelmTheme.mutedInk(theme)
        resultLabel.textColor = HelmTheme.mutedInk(theme)
        footnoteLabel.textColor = HelmTheme.mutedInk(theme)
        promptField.domainHue = RailDestination.videoGen.domainHue
    }

    // MARK: Actions

    @objc private func refreshTapped() { refresh() }

    @objc private func setupActionTapped() {
        guard let command = VideoGenEnvironment.setupCommand() else { return }
        setState(.settingUp)
        if let onRunCommandTracked {
            onRunCommandTracked("Set up video generation", command) { [weak self] _ in
                self?.refresh()
            }
        } else {
            onRunCommand?("Set up video generation", command)
        }
    }

    @objc private func enhanceToggled() {}

    @objc private func generateTapped() {
        let idea = promptField.stringValue
        resultLabel.isHidden = true
        revealButton.isHidden = true

        if enhanceSwitch.state == .on {
            isEnhancing = true
            render()
            VideoPromptEnhancer.enhance(idea) { [weak self] result in
                guard let self else { return }
                self.isEnhancing = false
                switch result {
                case .success(let enhanced):
                    self.promptField.stringValue = enhanced
                    self.runGeneration(prompt: enhanced)
                case .failure(let error):
                    self.render()
                    self.showResult("Couldn't enhance the prompt (\(error.message)) - generating with your original text instead.", isError: false)
                    self.runGeneration(prompt: idea)
                }
            }
        } else {
            runGeneration(prompt: idea)
        }
    }

    private func runGeneration(prompt: String) {
        isGenerating = true
        render()
        VideoGenEngine.generate(prompt: prompt) { [weak self] result in
            guard let self else { return }
            self.isGenerating = false
            self.render()
            switch result {
            case .success(let generated):
                self.lastOutputPath = generated.outputPath
                self.showResult(
                    "Saved \u{2039}\(generated.outputPath.lastPathComponent)\u{203A} in \(Int(generated.durationSeconds))s.",
                    isError: false)
                self.revealButton.isHidden = false
            case .failure(let error):
                self.showResult(error.message, isError: true)
            }
        }
    }

    private func showResult(_ message: String, isError: Bool) {
        resultLabel.stringValue = message
        resultLabel.textColor = isError ? HelmTheme.nsColor(theme.ansiHex[1]) : HelmTheme.mutedInk(theme)
        resultLabel.isHidden = false
    }

    @objc private func revealTapped() {
        guard let path = lastOutputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    func debugSetState(_ newState: VideoGenState) { setState(newState) }
    var debugState: VideoGenState { state }
    var debugIsGenerating: Bool { isGenerating }
    var debugSetupActionButton: HelmButton { setupActionButton }
    var debugGenerateButton: HelmButton { generateButton }
    var debugPromptField: HelmTextField { promptField }
    var debugEnhanceSwitch: NSSwitch { enhanceSwitch }
    var debugResultLabel: NSTextField { resultLabel }
    var debugRevealButton: HelmButton { revealButton }
    func debugTriggerGenerate() { generateTapped() }
    func debugSetLastOutputPath(_ url: URL) { lastOutputPath = url }
    #endif
}
