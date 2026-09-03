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
// `VideoGenEnvironment` for why) and Generate (a prompt field, the real
// generation settings below - see `fm/grandline-videogen-settings-fix`'s own
// bullet just below - an optional "Enhance with Claude" toggle, a Generate
// button, and the result of the last run). Status is re-read from real
// on-disk state on every `viewWillAppear`, matching `VaultController`/
// `DictationController`'s own "refresh on appear, no polling" convention.
//
// `fm/grandline-videogen-settings-fix` added the four settings rows between
// the prompt field and the "Enhance with Claude" toggle - Reference type,
// Duration, Resolution and Clarity - after a captain comparison against the
// original mockup found the shipped v1 offered only a prompt field, with
// every generated clip coming out ~4s long regardless of what was asked for
// (a hardcoded frame count in `VideoGenEngine`, fixed there - see that
// file's own header). Each row follows this file's own existing row-building
// idiom (`HelmSegmentedTabs`/`HelmButton` for a small, fixed choice set - see
// `HelmForm.swift`'s and `HelmDesignSystem.swift`'s own components, and
// `SettingsController.buildTerminalSection`'s font-size preset row for the
// "row of `HelmButton`s, `.primary` when selected" idiom this file's
// duration stepper follows). Deliberately no "Shot type" row and no
// "Video-link" reference option - see `VideoGenEngine.swift`'s header for
// why: this CLI has no video-URL conditioning flag, and a shot-type control
// has no clean CLI primitive behind it.

import AppKit

/// One generated clip in this session's iteration history - never persisted
/// across a relaunch (per the task's own ask: "this session only"). `feedback`
/// is `nil` for the first version and for any later version produced by a
/// plain Generate click (a hand-edited prompt, not a feedback revision).
struct VideoGenVersion: Equatable {
    let number: Int
    let prompt: String
    let feedback: String?
    let outputPath: URL

    /// What the history row's caption shows.
    var historyLabel: String {
        if let feedback, !feedback.isEmpty { return feedback }
        return number == 1 ? "Original" : "Prompt edited"
    }
}

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

    // MARK: Generate card - settings (fm/grandline-videogen-settings-fix)

    private let referenceLabel = NSTextField(labelWithString: "Reference")
    private lazy var referenceTabs = HelmSegmentedTabs(
        items: [.init(id: "text", title: "Text"), .init(id: "image", title: "Image")],
        selected: "text", size: .compact)
    private let imageWell = ShiftImageAttachmentWell()
    private let chooseImageButton = HelmButton(title: "Choose Image\u{2026}", variant: .secondary, size: .small)
    private var imageWellRow = NSStackView()

    private let durationLabel = NSTextField(labelWithString: "Duration")
    private let durationMinusButton = HelmButton(symbol: "minus", variant: .secondary, size: .small)
    private let durationValueLabel = NSTextField(labelWithString: "")
    private let durationPlusButton = HelmButton(symbol: "plus", variant: .secondary, size: .small)
    private let durationEstimateLabel = NSTextField(wrappingLabelWithString: "")

    private let resolutionLabel = NSTextField(labelWithString: "Resolution")
    private lazy var resolutionTabs = HelmSegmentedTabs(
        items: VideoGenResolutionPreset.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: VideoGenResolutionPreset.standard.rawValue, size: .compact)

    private let clarityLabel = NSTextField(labelWithString: "Clarity")
    private lazy var clarityTabs = HelmSegmentedTabs(
        items: VideoGenClarity.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: VideoGenClarity.standard.rawValue, size: .compact)
    private let clarityCaptionLabel = NSTextField(wrappingLabelWithString: "")

    private let enhanceSwitch = NSSwitch()
    private let enhanceTitleLabel = NSTextField(labelWithString: "")
    private let enhanceDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var enhanceTextStack = NSStackView()
    private let generateButton = HelmButton(title: "Generate", variant: .primary)
    private let generateProgress = NSProgressIndicator()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let revealButton = HelmButton(title: "Reveal in Finder", variant: .secondary)

    private let footnoteLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: Iterate card - feedback-driven regeneration loop
    //
    // A captain-approved addition to this same task/PR (see this file's own
    // header): after a clip exists, feed back on it and regenerate without
    // re-typing the whole prompt or re-picking duration/resolution/clarity.
    // Its own `HelmCard`, hidden until at least one version exists, appended
    // below the Generate card rather than folded into it - the settings work
    // above already filled that card, and a third card keeps each concern on
    // its own visual unit rather than one increasingly dense one.

    private let iteratePanel = HelmCard()
    private let activePromptLabel = NSTextField(wrappingLabelWithString: "")
    private let feedbackField = HelmTextField(placeholder: "What should change? e.g. \u{201C}the water is too still, make it choppier\u{201D}")
    private let regenerateButton = HelmButton(title: "Regenerate", variant: .primary)
    private let regenerateProgress = NSProgressIndicator()
    private let revisedPromptLabel = NSTextField(wrappingLabelWithString: "")
    private let historyHeaderLabel = NSTextField(labelWithString: "History (this session)")
    private let historyStack = NSStackView()

    /// Suggestion chips - a nice-to-have, per the task's own ask: click to
    /// fill (not append to) the feedback field rather than invent a second
    /// "combine chips" interaction.
    private static let feedbackSuggestions = ["Too dark", "Slower camera", "More motion", "Different lighting"]
    private var suggestionButtons: [HelmButton] = []

    private var state: VideoGenState = .notSetUp
    private var isGenerating = false
    private var isEnhancing = false
    private var lastOutputPath: URL?
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Settings state (fm/grandline-videogen-settings-fix)

    /// Bounds match the task brief's own "e.g. 2-15 seconds" - realistic
    /// against the scout report's validated ~86s/4s-clip baseline; see
    /// `VideoGenEngine.estimatedSeconds`.
    private static let durationRange = 2...15
    private var referenceIsImage = false
    private var referenceImagePath: String?
    private var durationSeconds = 5
    private var resolution: VideoGenResolutionPreset = .standard
    private var clarity: VideoGenClarity = .standard

    // MARK: Iterate state (feedback-driven regeneration loop)

    private var versions: [VideoGenVersion] = []
    private var activeVersionIndex: Int?
    private var isRevising = false

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
        _ = buildIterateSection()
        buildFootnote()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(setupPanel)
        contentStack.addArrangedSubview(generatePanel)
        contentStack.addArrangedSubview(iteratePanel)
        contentStack.addArrangedSubview(footnoteLabel)
        iteratePanel.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            setupPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            generatePanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            iteratePanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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

        let settingsSection = buildSettingsSection()

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

        let column = NSStackView(views: [promptField, settingsSection, enhanceRow, actionRow, resultRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptField.widthAnchor.constraint(equalTo: column.widthAnchor),
            settingsSection.widthAnchor.constraint(equalTo: column.widthAnchor),
            enhanceRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        generatePanel.setBody(column, insets: HelmCard.contentInsets)
        return generatePanel
    }

    /// The four generation-settings rows (fm/grandline-videogen-settings-fix)
    /// - Reference type, Duration, Resolution, Clarity. Each row is a
    /// caption label + a fixed, small choice control (`HelmSegmentedTabs` for
    /// a named set, a `HelmButton` stepper for duration - see this file's own
    /// header for why no raw `NSSlider`/`NSStepper` was introduced).
    private func buildSettingsSection() -> NSView {
        // MARK: Reference

        referenceLabel.font = HelmType.rowTitle()
        referenceLabel.translatesAutoresizingMaskIntoConstraints = false
        referenceTabs.onSelect = { [weak self] id in self?.referenceTypeChanged(id) }
        referenceTabs.translatesAutoresizingMaskIntoConstraints = false

        let referenceSpacer = NSView()
        let referenceHeaderRow = NSStackView(views: [referenceLabel, referenceSpacer, referenceTabs])
        referenceHeaderRow.orientation = .horizontal
        referenceHeaderRow.alignment = .centerY
        referenceHeaderRow.distribution = .fill
        referenceHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        referenceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        imageWell.onImageChosen = { [weak self] data in self?.referenceImageChosen(data: data) }
        imageWell.onRemove = { [weak self] in self?.referenceImageRemoved() }
        imageWell.translatesAutoresizingMaskIntoConstraints = false

        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImageTapped)
        chooseImageButton.translatesAutoresizingMaskIntoConstraints = false

        imageWellRow = NSStackView(views: [imageWell, chooseImageButton])
        imageWellRow.orientation = .vertical
        imageWellRow.alignment = .leading
        imageWellRow.spacing = 8
        imageWellRow.translatesAutoresizingMaskIntoConstraints = false
        imageWellRow.isHidden = true

        let referenceSection = NSStackView(views: [referenceHeaderRow, imageWellRow])
        referenceSection.orientation = .vertical
        referenceSection.alignment = .leading
        referenceSection.spacing = 10
        referenceSection.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Duration

        durationLabel.font = HelmType.rowTitle()
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        durationMinusButton.target = self
        durationMinusButton.action = #selector(durationMinusTapped)
        durationMinusButton.translatesAutoresizingMaskIntoConstraints = false

        durationValueLabel.font = HelmType.rowTitle()
        durationValueLabel.alignment = .center
        durationValueLabel.translatesAutoresizingMaskIntoConstraints = false
        durationValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        durationPlusButton.target = self
        durationPlusButton.action = #selector(durationPlusTapped)
        durationPlusButton.translatesAutoresizingMaskIntoConstraints = false

        let durationStepper = NSStackView(views: [durationMinusButton, durationValueLabel, durationPlusButton])
        durationStepper.orientation = .horizontal
        durationStepper.alignment = .centerY
        durationStepper.spacing = 8
        durationStepper.translatesAutoresizingMaskIntoConstraints = false

        let durationSpacer = NSView()
        let durationHeaderRow = NSStackView(views: [durationLabel, durationSpacer, durationStepper])
        durationHeaderRow.orientation = .horizontal
        durationHeaderRow.alignment = .centerY
        durationHeaderRow.distribution = .fill
        durationHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        durationSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        durationEstimateLabel.font = HelmType.caption()
        durationEstimateLabel.preferredMaxLayoutWidth = 520
        durationEstimateLabel.translatesAutoresizingMaskIntoConstraints = false

        let durationSection = NSStackView(views: [durationHeaderRow, durationEstimateLabel])
        durationSection.orientation = .vertical
        durationSection.alignment = .leading
        durationSection.spacing = 4
        durationSection.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Resolution

        resolutionLabel.font = HelmType.rowTitle()
        resolutionLabel.translatesAutoresizingMaskIntoConstraints = false
        resolutionTabs.onSelect = { [weak self] id in self?.resolutionChanged(id) }
        resolutionTabs.translatesAutoresizingMaskIntoConstraints = false

        let resolutionSpacer = NSView()
        let resolutionRow = NSStackView(views: [resolutionLabel, resolutionSpacer, resolutionTabs])
        resolutionRow.orientation = .horizontal
        resolutionRow.alignment = .centerY
        resolutionRow.distribution = .fill
        resolutionRow.translatesAutoresizingMaskIntoConstraints = false
        resolutionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // MARK: Clarity

        clarityLabel.font = HelmType.rowTitle()
        clarityLabel.translatesAutoresizingMaskIntoConstraints = false
        clarityTabs.onSelect = { [weak self] id in self?.clarityChanged(id) }
        clarityTabs.translatesAutoresizingMaskIntoConstraints = false

        let claritySpacer = NSView()
        let clarityHeaderRow = NSStackView(views: [clarityLabel, claritySpacer, clarityTabs])
        clarityHeaderRow.orientation = .horizontal
        clarityHeaderRow.alignment = .centerY
        clarityHeaderRow.distribution = .fill
        clarityHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        claritySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clarityCaptionLabel.stringValue = VideoGenClarity.standard.subtitle
        clarityCaptionLabel.font = HelmType.caption()
        clarityCaptionLabel.preferredMaxLayoutWidth = 520
        clarityCaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let claritySection = NSStackView(views: [clarityHeaderRow, clarityCaptionLabel])
        claritySection.orientation = .vertical
        claritySection.alignment = .leading
        claritySection.spacing = 4
        claritySection.translatesAutoresizingMaskIntoConstraints = false

        let settings = NSStackView(views: [referenceSection, durationSection, resolutionRow, claritySection])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 16
        settings.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            referenceSection.widthAnchor.constraint(equalTo: settings.widthAnchor),
            referenceHeaderRow.widthAnchor.constraint(equalTo: settings.widthAnchor),
            imageWellRow.widthAnchor.constraint(equalTo: settings.widthAnchor),
            durationSection.widthAnchor.constraint(equalTo: settings.widthAnchor),
            durationHeaderRow.widthAnchor.constraint(equalTo: settings.widthAnchor),
            resolutionRow.widthAnchor.constraint(equalTo: settings.widthAnchor),
            claritySection.widthAnchor.constraint(equalTo: settings.widthAnchor),
            clarityHeaderRow.widthAnchor.constraint(equalTo: settings.widthAnchor),
        ])

        updateDurationDisplay()
        return settings
    }

    /// The Iterate card - feedback field, Regenerate, and the session's
    /// version history. Hidden until `versions` is non-empty.
    private func buildIterateSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Iterate")
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        iteratePanel.setHeader(sectionLabel)

        activePromptLabel.font = HelmType.caption()
        activePromptLabel.preferredMaxLayoutWidth = 620
        activePromptLabel.translatesAutoresizingMaskIntoConstraints = false

        feedbackField.translatesAutoresizingMaskIntoConstraints = false

        suggestionButtons = Self.feedbackSuggestions.map { title in
            let b = HelmButton(title: title, variant: .quiet, size: .small)
            b.target = self
            b.action = #selector(suggestionTapped(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let suggestionRow = NSStackView(views: suggestionButtons)
        suggestionRow.orientation = .horizontal
        suggestionRow.spacing = 6
        suggestionRow.translatesAutoresizingMaskIntoConstraints = false

        regenerateProgress.style = .spinning
        regenerateProgress.controlSize = .small
        regenerateProgress.isDisplayedWhenStopped = false
        regenerateProgress.setContentHuggingPriority(.required, for: .horizontal)
        regenerateProgress.setContentCompressionResistancePriority(.required, for: .horizontal)
        regenerateProgress.translatesAutoresizingMaskIntoConstraints = false

        regenerateButton.controlSize = .regular
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerateTapped)
        regenerateButton.setContentHuggingPriority(.required, for: .horizontal)
        regenerateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        regenerateButton.translatesAutoresizingMaskIntoConstraints = false

        let regenerateSpacer = NSView()
        let regenerateRow = NSStackView(views: [regenerateProgress, regenerateSpacer, regenerateButton])
        regenerateRow.orientation = .horizontal
        regenerateRow.alignment = .centerY
        regenerateRow.spacing = 10
        regenerateRow.distribution = .fill
        regenerateRow.translatesAutoresizingMaskIntoConstraints = false
        regenerateSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        revisedPromptLabel.font = HelmType.caption()
        revisedPromptLabel.preferredMaxLayoutWidth = 620
        revisedPromptLabel.isHidden = true
        revisedPromptLabel.translatesAutoresizingMaskIntoConstraints = false

        historyHeaderLabel.font = HelmType.rowTitle()
        historyHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 8
        historyStack.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [
            activePromptLabel, feedbackField, suggestionRow, regenerateRow,
            revisedPromptLabel, historyHeaderLabel, historyStack,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            activePromptLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            feedbackField.widthAnchor.constraint(equalTo: column.widthAnchor),
            regenerateRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            revisedPromptLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            historyStack.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        iteratePanel.setBody(column, insets: HelmCard.contentInsets)
        return iteratePanel
    }

    /// Names exactly what this page offers - Text or Image reference,
    /// duration, resolution, and clarity - and nothing it doesn't (no
    /// shot-type control, no video-link reference; see this file's header).
    private func buildFootnote() {
        footnoteLabel.stringValue = "Generation runs entirely on this Mac. Choose a Text or Image reference, duration, resolution, and clarity above. Clips are saved to \u{2039}\(VideoGenEnvironment.outputDir().path)\u{203A}."
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
        let idle = ready && !isGenerating
        promptField.isEnabled = idle
        enhanceSwitch.isEnabled = idle
        generateButton.isEnabled = idle && !isEnhancing
        generateButton.title = isEnhancing ? "Enhancing..." : "Generate"
        generateProgress.isHidden = !(isGenerating || isEnhancing)
        if isGenerating || isEnhancing { generateProgress.startAnimation(nil) } else { generateProgress.stopAnimation(nil) }

        // Settings row controls - a captain can still browse/change these
        // while a run is in flight (the run already captured its own
        // snapshot of them), but the stepper/file-picker buttons follow the
        // same idle gate as the rest of the form for visual consistency.
        durationMinusButton.isEnabled = idle && durationSeconds > Self.durationRange.lowerBound
        durationPlusButton.isEnabled = idle && durationSeconds < Self.durationRange.upperBound
        chooseImageButton.isEnabled = idle

        // Iterate card
        iteratePanel.isHidden = versions.isEmpty
        feedbackField.isEnabled = idle && !isRevising
        regenerateButton.isEnabled = idle && !isRevising && !isEnhancing
        regenerateButton.title = isRevising ? "Revising..." : "Regenerate"
        regenerateProgress.isHidden = !isRevising
        if isRevising { regenerateProgress.startAnimation(nil) } else { regenerateProgress.stopAnimation(nil) }
        for button in suggestionButtons { button.isEnabled = idle && !isRevising }
        renderHistory()

        applyTheme()
    }

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        setupPanel.applyTheme(theme)
        generatePanel.applyTheme(theme)
        iteratePanel.applyTheme(theme)
        setupIconTile.applyTheme(theme)
        setupTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        setupDetailLabel.textColor = HelmTheme.mutedInk(theme)
        referenceLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        durationLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        durationValueLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        durationEstimateLabel.textColor = HelmTheme.mutedInk(theme)
        resolutionLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        clarityLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        clarityCaptionLabel.textColor = HelmTheme.mutedInk(theme)
        referenceTabs.applyTheme(theme)
        resolutionTabs.applyTheme(theme)
        clarityTabs.applyTheme(theme)
        imageWell.applyTheme(theme)
        enhanceTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        enhanceDetailLabel.textColor = HelmTheme.mutedInk(theme)
        resultLabel.textColor = HelmTheme.mutedInk(theme)
        footnoteLabel.textColor = HelmTheme.mutedInk(theme)
        promptField.domainHue = RailDestination.videoGen.domainHue
        feedbackField.domainHue = RailDestination.videoGen.domainHue
        activePromptLabel.textColor = HelmTheme.mutedInk(theme)
        revisedPromptLabel.textColor = HelmTheme.mutedInk(theme)
        historyHeaderLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
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

    /// `feedback` is `nil` for a plain Generate click and the captain's own
    /// text for a Regenerate click - `runGeneration` doesn't care which; it
    /// only threads it through to `recordVersion` on success, since a version
    /// is a version either way.
    private func runGeneration(prompt: String, feedback: String? = nil) {
        isGenerating = true
        render()
        VideoGenEngine.generate(
            prompt: prompt,
            durationSeconds: Double(durationSeconds),
            resolution: resolution,
            clarity: clarity,
            reference: currentReference()
        ) { [weak self] result in
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
                self.recordVersion(prompt: prompt, feedback: feedback, outputPath: generated.outputPath)
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

    // MARK: Settings actions (fm/grandline-videogen-settings-fix)

    @objc private func durationMinusTapped() {
        durationSeconds = max(Self.durationRange.lowerBound, durationSeconds - 1)
        updateDurationDisplay()
        render() // refreshes the stepper buttons' own enabled state at the range's edges
    }

    @objc private func durationPlusTapped() {
        durationSeconds = min(Self.durationRange.upperBound, durationSeconds + 1)
        updateDurationDisplay()
        render()
    }

    /// Recomputes the frame count/actual-duration/estimated-time caption
    /// under the Duration row - called whenever duration, resolution, or
    /// clarity changes, since the estimate depends on all three.
    private func updateDurationDisplay() {
        durationValueLabel.stringValue = "\(durationSeconds)s"
        let frames = VideoGenEngine.frameCount(forSeconds: Double(durationSeconds), frameRate: VideoGenEngine.frameRateValue)
        let actual = VideoGenEngine.actualSeconds(forFrameCount: frames)
        let estimate = VideoGenEngine.estimatedSeconds(forFrameCount: frames, width: resolution.width, height: resolution.height, clarity: clarity)
        let hedge = (clarity == .standard && resolution == .standard && durationSeconds == 4)
            ? "" : " (estimate, not independently measured for this exact combination)"
        durationEstimateLabel.stringValue = String(
            format: "Renders as \u{2248}%.1fs (%d frames). Estimated generation time: \u{2248}%@%@.",
            actual, frames, Self.formatEstimate(estimate), hedge)
    }

    private static func formatEstimate(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainder = Int(seconds) % 60
            return "\(minutes)m \(remainder)s"
        }
        return "\(Int(seconds.rounded()))s"
    }

    private func referenceTypeChanged(_ id: String) {
        referenceIsImage = id == "image"
        imageWellRow.isHidden = !referenceIsImage
        view.layoutSubtreeIfNeeded()
        render()
    }

    @objc private func chooseImageTapped() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            self?.imageWell.handle(image: image)
        }
    }

    /// The well hands back already-normalized PNG bytes, not a file path -
    /// `--image` needs a real path on disk, so this writes them into a
    /// scratch directory alongside the rest of this feature's own state
    /// (`VideoGenEnvironment.rootDir()`), never the captain's own Pictures/
    /// wherever the original file lived.
    private func referenceImageChosen(data: Data) {
        let dir = VideoGenEnvironment.rootDir().appendingPathComponent("reference-images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("ref-\(UUID().uuidString).png")
            try data.write(to: path)
            referenceImagePath = path.path
        } catch {
            referenceImagePath = nil
            showResult("Couldn't save the reference image: \(error.localizedDescription)", isError: true)
        }
        render()
    }

    private func referenceImageRemoved() {
        if let path = referenceImagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        referenceImagePath = nil
        render()
    }

    private func currentReference() -> VideoGenReferenceType {
        if referenceIsImage, let path = referenceImagePath { return .image(path: path) }
        return .text
    }

    private func resolutionChanged(_ id: String) {
        guard let preset = VideoGenResolutionPreset(rawValue: id) else { return }
        resolution = preset
        updateDurationDisplay()
    }

    private func clarityChanged(_ id: String) {
        guard let picked = VideoGenClarity(rawValue: id) else { return }
        clarity = picked
        clarityCaptionLabel.stringValue = clarity.subtitle
        updateDurationDisplay()
    }

    // MARK: Iterate actions (feedback-driven regeneration loop)

    @objc private func suggestionTapped(_ sender: HelmButton) {
        guard let index = suggestionButtons.firstIndex(of: sender) else { return }
        feedbackField.stringValue = Self.feedbackSuggestions[index]
    }

    /// Folds the feedback into a revised prompt via one Claude call
    /// (`VideoPromptEnhancer.reviseForFeedback` - the exact same one-shot
    /// mechanism `enhance` above uses, a different prompt template only),
    /// shows the revision to the captain, then regenerates with it - the
    /// same duration/resolution/clarity/reference settings already selected,
    /// never re-asked for.
    @objc private func regenerateTapped() {
        let feedback = feedbackField.stringValue
        let currentPrompt = promptField.stringValue
        isRevising = true
        revisedPromptLabel.isHidden = true
        render()
        VideoPromptEnhancer.reviseForFeedback(currentPrompt: currentPrompt, feedback: feedback) { [weak self] result in
            guard let self else { return }
            self.isRevising = false
            switch result {
            case .success(let revised):
                self.promptField.stringValue = revised
                self.revisedPromptLabel.stringValue = "Revised prompt: \(revised)"
                self.revisedPromptLabel.isHidden = false
                self.feedbackField.stringValue = ""
                self.runGeneration(prompt: revised, feedback: feedback)
            case .failure(let error):
                self.render()
                self.showResult("Couldn't revise the prompt (\(error.message)).", isError: true)
            }
        }
    }

    /// Appends a new version and makes it the active one - called on every
    /// successful generation (plain Generate or Regenerate alike), so the
    /// history reflects every clip this session actually produced.
    private func recordVersion(prompt: String, feedback: String?, outputPath: URL) {
        let version = VideoGenVersion(number: versions.count + 1, prompt: prompt, feedback: feedback, outputPath: outputPath)
        versions.append(version)
        activeVersionIndex = versions.count - 1
        render()
    }

    /// Makes an earlier version's prompt/clip the active one again -
    /// deliberately WITHOUT regenerating. Every prior clip stays on disk;
    /// this only changes which one this page is currently pointing at.
    @objc private func restoreVersionTapped(_ sender: HelmButton) {
        guard let index = versions.firstIndex(where: { $0.number == sender.tag }) else { return }
        activeVersionIndex = index
        let version = versions[index]
        promptField.stringValue = version.prompt
        lastOutputPath = version.outputPath
        revisedPromptLabel.isHidden = true
        showResult("Restored v\(version.number) - \u{2039}\(version.outputPath.lastPathComponent)\u{203A}.", isError: false)
        revealButton.isHidden = false
        render()
    }

    private func renderHistory() {
        activePromptLabel.stringValue = activeVersion.map { "Current prompt: \($0.prompt)" } ?? ""
        historyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, version) in versions.enumerated().reversed() {
            let row = buildHistoryRow(version: version, isActive: index == activeVersionIndex)
            historyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
        }
    }

    private var activeVersion: VideoGenVersion? {
        guard let index = activeVersionIndex, versions.indices.contains(index) else { return nil }
        return versions[index]
    }

    private func buildHistoryRow(version: VideoGenVersion, isActive: Bool) -> NSView {
        let accent = NSView()
        accent.wantsLayer = true
        accent.layer?.backgroundColor = HelmTheme.nsColor(isActive ? theme.accentHex : theme.chromeLineHex).cgColor
        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let titleLabel = NSTextField(labelWithString: "v\(version.number)\(isActive ? " (active)" : "")")
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(wrappingLabelWithString: version.historyLabel)
        detailLabel.font = HelmType.caption()
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        detailLabel.preferredMaxLayoutWidth = 420
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let restoreButton = HelmButton(title: "Restore", variant: .secondary, size: .small)
        restoreButton.isEnabled = !isActive
        restoreButton.target = self
        restoreButton.action = #selector(restoreVersionTapped(_:))
        restoreButton.tag = version.number
        restoreButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [accent, textStack, restoreButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accent.topAnchor.constraint(equalTo: row.topAnchor),
            accent.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
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

    // MARK: Settings/iterate probe surface (fm/grandline-videogen-settings-fix)

    var debugDurationSeconds: Int { durationSeconds }
    func debugSetDurationSeconds(_ seconds: Int) { durationSeconds = seconds; updateDurationDisplay() }
    func debugDurationMinusTapped() { durationMinusTapped() }
    func debugDurationPlusTapped() { durationPlusTapped() }
    var debugDurationEstimateLabel: NSTextField { durationEstimateLabel }
    var debugDurationValueLabel: NSTextField { durationValueLabel }

    var debugResolution: VideoGenResolutionPreset { resolution }
    func debugSelectResolution(_ id: String) { resolutionChanged(id) }
    var debugClarity: VideoGenClarity { clarity }
    func debugSelectClarity(_ id: String) { clarityChanged(id) }

    var debugReferenceIsImage: Bool { referenceIsImage }
    var debugReferenceImagePath: String? { referenceImagePath }
    func debugSelectReferenceType(_ id: String) { referenceTypeChanged(id) }
    func debugChooseReferenceImage(data: Data) { referenceImageChosen(data: data) }
    func debugRemoveReferenceImage() { referenceImageRemoved() }
    func debugCurrentReference() -> VideoGenReferenceType { currentReference() }
    var debugImageWellRowHidden: Bool { imageWellRow.isHidden }

    var debugVersions: [VideoGenVersion] { versions }
    var debugActiveVersionIndex: Int? { activeVersionIndex }
    var debugActiveVersion: VideoGenVersion? { activeVersion }
    var debugFeedbackField: HelmTextField { feedbackField }
    var debugRegenerateButton: HelmButton { regenerateButton }
    var debugRevisedPromptLabel: NSTextField { revisedPromptLabel }
    func debugTriggerRegenerate() { regenerateTapped() }
    /// Seeds a version directly (no real generation) - what
    /// `VideoGenSelfTest`'s restore-without-regenerating case drives, since
    /// the point of that test is `restoreVersionTapped`'s own behavior, not
    /// a second real subprocess run.
    func debugRecordVersion(prompt: String, feedback: String?, outputPath: URL) {
        recordVersion(prompt: prompt, feedback: feedback, outputPath: outputPath)
    }
    func debugRestoreVersion(number: Int) {
        let button = HelmButton(title: "Restore", variant: .secondary)
        button.tag = number
        restoreVersionTapped(button)
    }
    static var durationRangeForTests: ClosedRange<Int> { durationRange }
    #endif
}
