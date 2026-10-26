// Grand Line - native macOS app.
//
// The sidebar layout's Run results dock: what a Code snippet's last run
// printed, at the foot of the editor card.
//
// It renders the same `CodeRunPaneState` the floating bar's
// `CodeRunOutputPane` renders, from the same outcome, and it is a separate
// view rather than a mode of that one because the floating bar is frozen: its
// pane keeps exactly the shape it had. What this one adds is the captain's
// reviewed concept for the Code page:
//
//   - a header naming the verdict as a chip ("SUCCEEDED · EXIT 0"), the
//     elapsed time, and Copy output and Clear;
//   - Standard output and Errors (stderr) as two tabs with their line counts,
//     which is honest because `CodeRunner` now captures the two streams apart;
//   - a note naming the interpreter and that the run had a temporary folder
//     and no network - both read from the outcome, never restated;
//   - a dark terminal surface that stays dark in a light theme, the way a
//     terminal pane does in every editor the captain uses.
//
// The view has no knowledge of `CodeRunner`. The controller decides what to
// run; this decides how it reads.

import AppKit

/// The dock's pure decisions - wording, counts, which tab opens - so they are
/// asserted without a window.
enum CodeRunResultsModel {

    enum Stream: String, CaseIterable {
        case standardOutput
        case standardError

        var title: String {
            switch self {
            case .standardOutput: return "Standard output"
            case .standardError: return "Errors (stderr)"
            }
        }
    }

    /// The header chip. Every outcome gets its own words, for the floating
    /// pane's GL-14 reason: killed, stopped, exited 1 and never started are
    /// four different things.
    static func chipText(_ state: CodeRunPaneState) -> String {
        switch state {
        case .idle: return ""
        case .running: return "RUNNING"
        case .finished(let outcome):
            switch outcome.kind {
            case .ok: return "SUCCEEDED \u{00B7} EXIT 0"
            case .failed: return "FAILED \u{00B7} EXIT \(outcome.status)"
            case .timedOut: return "TIMED OUT"
            case .cancelled: return "STOPPED"
            case .launchFailed: return "DID NOT START"
            case .sandboxUnavailable: return "REFUSED"
            }
        }
    }

    static func elapsedText(_ state: CodeRunPaneState) -> String {
        switch state {
        case .idle: return ""
        case .running: return "stops at \(CodeRunOutputPane.seconds(CodeRunner.wallClock))"
        case .finished(let outcome):
            guard outcome.kind != .launchFailed, outcome.kind != .sandboxUnavailable,
                  outcome.duration > 0 else { return "" }
            return "\(CodeRunOutputPane.seconds(outcome.duration)) elapsed"
        }
    }

    /// The note beside the tabs: what ran, and where. Only what the outcome
    /// says - a refused run had no folder and claims none.
    static func noteText(_ state: CodeRunPaneState) -> String {
        switch state {
        case .idle: return ""
        case .running(let tool): return "\(tool) \u{00B7} temporary folder, no network"
        case .finished(let outcome):
            var parts: [String] = []
            if !outcome.toolDescription.isEmpty { parts.append(outcome.toolDescription) }
            if !outcome.sandboxPath.isEmpty { parts.append("temporary folder, no network") }
            if outcome.truncated { parts.append("cut at \(CodeRunner.maximumOutputBytes / 1024) KB") }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    /// The raw text of one stream.
    static func text(_ stream: Stream, in state: CodeRunPaneState) -> String {
        guard case .finished(let outcome) = state else { return "" }
        switch stream {
        case .standardOutput: return outcome.standardOutput
        case .standardError: return outcome.standardError
        }
    }

    /// Lines a stream holds. A trailing newline ends the last line rather than
    /// starting an empty one, so `"Hello\nManjesh\n"` is two.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if text.hasSuffix("\n") { lines -= 1 }
        return lines
    }

    static func countText(_ count: Int, unit: Bool) -> String {
        guard unit else { return "\(count)" }
        return count == 1 ? "1 line" : "\(count) lines"
    }

    /// What the body shows for a stream, substituting a sentence for an empty
    /// one (GL-14: a blank pane says neither "it printed nothing" nor "it
    /// never ran").
    static func displayText(_ stream: Stream, in state: CodeRunPaneState) -> String {
        switch state {
        case .idle: return ""
        case .running: return stream == .standardOutput ? "Running\u{2026}" : ""
        case .finished(let outcome):
            let text = Self.text(stream, in: state)
            guard text.isEmpty else { return text }
            switch stream {
            case .standardOutput: return CodeRunner.emptyOutputNote(outcome.kind)
            case .standardError: return "(nothing on stderr)"
            }
        }
    }

    /// Which tab a finished run opens on: Errors when the run failed and said
    /// why there, or when stderr is all it printed; otherwise Standard output.
    static func preferredStream(_ state: CodeRunPaneState) -> Stream {
        guard case .finished(let outcome) = state, !outcome.standardError.isEmpty else { return .standardOutput }
        if outcome.kind != .ok || outcome.standardOutput.isEmpty { return .standardError }
        return .standardOutput
    }

    /// The dock's one colour decision, shared with the floating pane so the
    /// two layouts can never disagree about whether a run went well.
    static func tint(_ state: CodeRunPaneState) -> HelmTint { CodeRunOutputPane.tint(for: state) }

    /// The terminal surface: dark in every theme. A dark palette's own page
    /// ground, taken a step further toward black so it reads as a well under
    /// the card; a light palette's own ink, which is its darkest colour. Both
    /// come from the theme, so a palette keeps its own temperature.
    ///
    /// Several light palettes' ink is a soft slate rather than near-black
    /// (Ayu Light's measures 0.14 luminance), so the result is then stepped
    /// toward black until it is genuinely a terminal's darkness - measured
    /// across every palette by `CodePreviewWorkbenchSelfTest`.
    static func terminalGround(_ theme: HelmTheme) -> NSColor {
        var ground: (Double, Double, Double)
        if theme.mode == .dark {
            ground = HelmContrast.mix(HelmContrast.components(HelmTheme.nsColor(theme.backgroundHex)), (0, 0, 0), 0.78)
        } else {
            let ink = HelmContrast.components(HelmTheme.nsColor(theme.chromeInkHex))
            let paper = HelmContrast.components(HelmTheme.nsColor(theme.backgroundHex))
            ground = HelmContrast.mix(ink, paper, 0.94)
        }
        var steps = 0
        while HelmContrast.relativeLuminance(ground) > terminalLuminanceCeiling, steps < 20 {
            ground = HelmContrast.mix(ground, (0, 0, 0), 0.85)
            steps += 1
        }
        return HelmContrast.color(ground)
    }

    /// How light the output surface may be: dark enough to read as a
    /// terminal in every palette.
    static let terminalLuminanceCeiling = 0.04

    /// Text on the terminal surface: the light end of the palette for plain
    /// output, the critical hue for stderr - each corrected to clear 4.5:1
    /// against the ground it actually sits on.
    static func terminalInk(_ stream: Stream, theme: HelmTheme) -> NSColor {
        let ground = terminalGround(theme)
        let preferred: NSColor
        switch stream {
        case .standardOutput:
            preferred = HelmTheme.nsColor(theme.mode == .dark ? theme.foregroundHex : theme.backgroundHex)
        case .standardError:
            preferred = HelmTheme.nsColor(HelmTint.critical.hex(in: theme))
        }
        return HelmContrast.legibleOn(fill: ground, preferring: preferred)
    }
}

final class CodeRunResultsDock: NSView {

    /// Header, tab row and a body tall enough for a short trace.
    static let preferredHeight: CGFloat = 236

    var onStop: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClear: (() -> Void)?

    private let headerRow = NSStackView()
    private let dot = HelmSignalDot()
    private let titleLabel = NSTextField(labelWithString: "Run results")
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let spinner = HelmProgressBar.inlineActivity(hue: RailDestination.codePreview.domainHue)
    private lazy var stopButton = HelmButton(title: "Stop", variant: .secondary, size: .small,
                                             symbol: "stop.fill", target: self, action: #selector(stopTapped))
    private lazy var copyButton = HelmButton(title: "Copy output", variant: .secondary, size: .small,
                                             symbol: "doc.on.doc", target: self, action: #selector(copyTapped))
    private lazy var clearButton = HelmButton(title: "Clear", variant: .secondary, size: .small,
                                              symbol: "xmark", target: self, action: #selector(clearTapped))

    private let tabRow = NSView()
    private var streamTabs: [CodeRunResultsModel.Stream: CodeRunStreamTab] = [:]
    private let noteLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSView()
    private let tabSeparator = NSView()

    private let scroll = NSScrollView()
    private let textView = NSTextView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private(set) var state: CodeRunPaneState = .idle
    private(set) var stream: CodeRunResultsModel.Stream = .standardOutput

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Run results")
        build()
        render(.idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        titleLabel.font = HelmType.rowTitle()
        chipLabel.font = HelmType.chip()
        elapsedLabel.font = HelmType.captionSmall()
        noteLabel.font = HelmType.captionSmall()
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chip.wantsLayer = true
        chip.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)
        NSLayoutConstraint.activate([
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
        ])

        spinner.hidesWhenStopped = true
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): a spacer that must collapse needs a real low-priority
        // zero width, not a hugging priority it has no intrinsic size for.
        let collapse = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        collapse.isActive = true

        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.spacing = HelmMetrics.s2
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [dot, titleLabel, chip, elapsedLabel, spinner, spacer, stopButton, copyButton, clearButton] {
            headerRow.addArrangedSubview(view)
        }
        // Gotcha (5) and (10): the fixed chrome never compresses; only the
        // spacer gives.
        for view in [dot, titleLabel, chip, elapsedLabel, stopButton, copyButton, clearButton] as [NSView] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        headerRow.setCustomSpacing(HelmMetrics.s3, after: chip)
        addSubview(headerRow)

        for view in [headerSeparator, tabSeparator] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.wantsLayer = true
        addSubview(tabRow)
        var previous: NSView?
        for kind in CodeRunResultsModel.Stream.allCases {
            let tab = CodeRunStreamTab(stream: kind)
            tab.onSelect = { [weak self] in self?.select(kind) }
            tabRow.addSubview(tab)
            NSLayoutConstraint.activate([
                tab.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? tabRow.leadingAnchor,
                                             constant: previous == nil ? HelmMetrics.s3 : HelmMetrics.s1),
                tab.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor),
            ])
            streamTabs[kind] = tab
            previous = tab
        }
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        tabRow.addSubview(noteLabel)
        if let previous {
            NSLayoutConstraint.activate([
                noteLabel.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: HelmMetrics.s3),
                noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: tabRow.trailingAnchor, constant: -HelmMetrics.s3),
                noteLabel.centerYAnchor.constraint(equalTo: previous.centerYAnchor),
            ])
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = HelmType.code()
        textView.textContainerInset = NSSize(width: HelmMetrics.s3, height: HelmMetrics.s3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.setAccessibilityLabel("Run output")
        HelmSelection.apply(to: textView, theme: theme)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
            headerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: HelmPageToolbar.iconButtonSide),

            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerSeparator.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: HelmMetrics.s2),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),

            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRow.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: CodeRunStreamTab.height + HelmMetrics.s2),

            tabSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabSeparator.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            tabSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Gotcha (4) and (16): the scroll view fills what is left exactly.
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tabSeparator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Render

    /// The one entry point. A finished run opens on the tab that explains it.
    func render(_ state: CodeRunPaneState) {
        self.state = state
        stream = CodeRunResultsModel.preferredStream(state)
        switch state {
        case .idle:
            isHidden = true
            spinner.stopAnimation()
        case .running:
            isHidden = false
            // GL-16: the RUNNING chip, not the bar, is what says a run is in
            // flight to a captain who turned animation off; `HelmProgressBar`
            // gates its own motion on Reduce Motion.
            spinner.startAnimation()
        case .finished:
            isHidden = false
            spinner.stopAnimation()
        }
        let running: Bool
        if case .running = state { running = true } else { running = false }
        stopButton.isHidden = !running
        copyButton.isHidden = running
        clearButton.isHidden = running
        chipLabel.stringValue = CodeRunResultsModel.chipText(state)
        elapsedLabel.stringValue = CodeRunResultsModel.elapsedText(state)
        elapsedLabel.isHidden = elapsedLabel.stringValue.isEmpty
        noteLabel.stringValue = CodeRunResultsModel.noteText(state)
        setAccessibilityValue(chipLabel.stringValue)
        refreshBody()
        applyTheme(theme)
    }

    func select(_ stream: CodeRunResultsModel.Stream) {
        self.stream = stream
        refreshBody()
        applyTheme(theme)
    }

    private func refreshBody() {
        for (kind, tab) in streamTabs {
            let count = CodeRunResultsModel.lineCount(CodeRunResultsModel.text(kind, in: state))
            tab.configure(count: count, selected: kind == stream)
        }
        textView.string = CodeRunResultsModel.displayText(stream, in: state)
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// What Copy output copies: the tab the captain is looking at.
    var visibleText: String { CodeRunResultsModel.text(stream, in: state) }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        layer?.backgroundColor = surface.cgColor
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        headerSeparator.layer?.backgroundColor = line.withAlphaComponent(HelmCard.dividerAlpha).cgColor
        tabSeparator.layer?.backgroundColor = line.withAlphaComponent(HelmCard.dividerAlpha).cgColor
        tabRow.layer?.backgroundColor = HelmField.fill(theme).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        elapsedLabel.textColor = HelmTheme.mutedInk(theme)
        noteLabel.textColor = HelmContrast.legibleOn(fill: HelmField.fill(theme), preferring: HelmTheme.mutedInk(theme))

        let tint = CodeRunResultsModel.tint(state)
        dot.configure(tint: tint, theme: theme)
        // A hue is a safe fill and never automatically safe as text: the chip
        // is a wash of the verdict's hue with its label corrected against it.
        let wash = HelmContrast.tintedSurface(tintHex: tint.hex(in: theme), theme: theme,
                                              target: HelmContrast.textTarget)
        chip.layer?.backgroundColor = wash.fill.cgColor
        chip.layer?.cornerRadius = HelmMetrics.rControl
        chipLabel.textColor = wash.foreground

        for tab in streamTabs.values { tab.applyTheme(theme) }

        let ground = CodeRunResultsModel.terminalGround(theme)
        textView.backgroundColor = ground
        scroll.backgroundColor = ground
        textView.textColor = CodeRunResultsModel.terminalInk(stream, theme: theme)
        textView.font = HelmType.code()
        // The surface is dark in every theme, so the selection and the
        // scroller follow it rather than the page.
        textView.appearance = NSAppearance(named: .darkAqua)
        scroll.appearance = NSAppearance(named: .darkAqua)
        HelmSelection.apply(to: textView, theme: theme)
    }

    // MARK: Actions

    @objc private func stopTapped() { onStop?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func clearTapped() { onClear?() }

    #if FM_SELFTESTS
    var debugChipText: String { chipLabel.stringValue }
    var debugElapsedText: String { elapsedLabel.stringValue }
    var debugNoteText: String { noteLabel.stringValue }
    var debugBodyText: String { textView.string }
    var debugBodyGround: NSColor? { textView.backgroundColor }
    var debugBodyInk: NSColor? { textView.textColor }
    var debugChipFill: NSColor? { chip.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    var debugChipInk: NSColor? { chipLabel.textColor }
    var debugStopVisible: Bool { !stopButton.isHidden }
    var debugCopyButton: HelmButton { copyButton }
    var debugClearButton: HelmButton { clearButton }
    func debugTab(_ stream: CodeRunResultsModel.Stream) -> CodeRunStreamTab? { streamTabs[stream] }
    #endif
}

/// One of the dock's two stream tabs: a title and a count badge, selected or
/// not. A `HoverHighlightView`, so it carries GL-16's role, label, focus ring
/// and keyboard press.
final class CodeRunStreamTab: HoverHighlightView {
    static let height: CGFloat = 26

    let stream: CodeRunResultsModel.Stream
    var onSelect: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let countBadge = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private var selected = false
    private var count = 0

    init(stream: CodeRunResultsModel.Stream) {
        self.stream = stream
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rControl
        titleLabel.stringValue = stream.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countBadge.wantsLayer = true
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.addSubview(countLabel)
        addSubview(titleLabel)
        addSubview(countBadge)
        for view in [titleLabel, countLabel] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2 + 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: HelmMetrics.s1 + 2),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HelmMetrics.s2 + 2)),
            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 5),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -5),
            countLabel.topAnchor.constraint(equalTo: countBadge.topAnchor, constant: 1),
            countLabel.bottomAnchor.constraint(equalTo: countBadge.bottomAnchor, constant: -1),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        accessibilityRoleOverride = .radioButton
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onSelect?() }

    func configure(count: Int, selected: Bool) {
        self.count = count
        self.selected = selected
        // The Standard output tab counts in words ("2 lines") the way the
        // concept does; the Errors tab's bare number reads as a tally.
        countLabel.stringValue = CodeRunResultsModel.countText(count, unit: stream == .standardOutput)
        accessibilityLabelOverride = "\(stream.title), \(CodeRunResultsModel.countText(count, unit: true))"
        accessibilityValueOverride = selected ? "selected" : nil
        applyTheme(ThemeManager.shared.theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let well = HelmField.fill(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let fill = selected ? card : well
        normalColor = selected ? card : .clear
        hoverColor = selected ? card : HelmFlatList.rowHoverColor(theme, over: well)
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        titleLabel.font = selected
            ? .systemFont(ofSize: HelmType.captionSmall().pointSize, weight: .bold)
            : HelmType.captionSmall()
        titleLabel.textColor = selected ? ink : HelmContrast.legibleOn(fill: fill, preferring: HelmTheme.mutedInk(theme))
        countLabel.font = .systemFont(ofSize: HelmType.scaled(10), weight: .semibold)
        countBadge.layer?.cornerRadius = 5
        countBadge.layer?.backgroundColor = (selected ? well : card).cgColor
        countLabel.textColor = HelmContrast.legibleOn(fill: selected ? well : card, preferring: HelmTheme.mutedInk(theme))
    }

    #if FM_SELFTESTS
    var debugCountText: String { countLabel.stringValue }
    var debugIsSelected: Bool { selected }
    func debugClick() { _ = performPrimaryAction() }
    #endif
}
