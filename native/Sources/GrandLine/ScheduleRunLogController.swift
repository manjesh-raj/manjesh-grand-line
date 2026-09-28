// Grand Line - native macOS app.
//
// The Run History sheet's "View Log" action (`ScheduleHistoryController`'s
// own trailing button on each row) - a small, read-only sheet showing one
// run's real output.
//
// Presented as a nested sheet on `ScheduleHistoryController`, itself already
// a sheet on the Schedules page - `HostEditorController.editPortForwarding`'s
// own precedent: "a sheet-on-sheet, which AppKit supports".
//
// Same minimal, non-form shape `ScheduleHistoryController` and
// `ShiftSnoozeCustomController` already established (forced appearance only,
// no explicit themed root layer - a real `NSWindow` sheet already paints its
// own background once appearance is forced): there is nothing to save here,
// this only reads.
//
// The log body reuses `ConsoleComposerPopover`'s own established "code block"
// recipe (a bordered, corner-radius `NSScrollView`/`NSTextView`, `HelmField
// .fill` background, `HelmType.code()` font) rather than inventing a new way
// to show raw output - the same styling `ToolInstance.codeEditor`'s Tools-
// page code editors use.
//
// **This is a Run *Report* now, not a Run Log**
// (`fm/grandline-schedule-status-clarity`). The captain's report was that the
// sheet answered the wrong question: it opened straight onto raw `brew`/`gh`
// output and left him to work out from it what had happened and whether he
// needed to do anything. The raw log is exactly as useful as it was - it is
// the evidence, it is kept verbatim, and it is what an agent debugging this
// actually reads - but it is no longer the *answer*.
//
// So the sheet now leads with a headline sentence and a three-field
// explanation block, and the raw log sits underneath behind a disclosure
// that states its own size. Three rules that shaped it:
//
//  - **The explanation is shown for a successful run too.** A sheet that only
//    explains failures still leaves "it said Done, what did it do?"
//    unanswered, and that question is most of the captain's confusion.
//    For a success the block is built from the run's own summary sentence.
//  - **The disclosure states the line count** ("Show raw output - 24 lines").
//    A collapsed section whose size is not stated reads as "there is nothing
//    here", which is the one thing this sheet must never imply about a log.
//  - **Collapsed by default, expanded when there is nothing better to show.**
//    An entry an older build wrote has no `failure` triple, and a run whose
//    log is only its own summary has nothing to reveal - in both cases
//    hiding the one piece of real content behind a click would be worse.

import AppKit

final class ScheduleRunLogController: NSViewController {

    private let entry: ScheduleRunHistoryEntry

    /// P3 (production review, section 21): stored and removed in `deinit`, the
    /// same fix `ScheduleHistoryController` and every `HelmFormSheet` editor
    /// already carry - a sheet built fresh on every presentation leaks a dead
    /// closure into `ThemeManager.observers` otherwise.
    private var themeObservation: ThemeObservation?
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let titleLabel = NSTextField(wrappingLabelWithString: "Run Report")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// The three-field explanation, or the one-field success equivalent.
    private let explainStack = NSStackView()
    private var explainRows: [(caption: NSTextField, body: NSTextField)] = []
    /// The disclosure that reveals the raw log. An `NSButton` in the app's
    /// own quiet variant rather than a bare `NSTextField`, so it carries a
    /// real role, a focus ring and keyboard activation for free (GL-16).
    private let rawToggle = HelmButton(title: "", variant: .quiet, size: .small)
    private var rawIsVisible = false
    private let logScroll = NSScrollView()
    private let logTextView = NSTextView()
    /// M5: the real Close button, kept so a self-test can measure where it
    /// actually lands rather than trusting the constraints that declared it -
    /// the exact class of bug `ScheduleHistoryController`'s own footer fix
    /// records (gotchas 10 + 12).
    private weak var closeButton: HelmButton?

    /// Fixed border alpha for the code block, matching `ConsoleComposerPopover
    /// .fieldBorderAlpha` (0.5 -> 0.7 after that file's own live-theme-check
    /// correction) rather than a fresh guess.
    private static let fieldBorderAlpha: CGFloat = 0.7

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(entry: ScheduleRunHistoryEntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        view = root
        themeObservation = ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.theme = theme
            self?.applyChromeTheme()
        }

        titleLabel.font = HelmType.sectionTitle()
        titleLabel.stringValue = Self.headline(for: entry)
        titleLabel.maximumNumberOfLines = 2

        // The verdict word stays on the supporting line, where it belongs
        // once the headline says what happened in a sentence.
        subtitleLabel.stringValue = "\(entry.actionTitle) \u{00B7} \(entry.verdict.label) \u{00B7} "
            + Self.headerFormatter.string(from: entry.at)
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        buildExplainBlock()
        buildLogView()

        let copyReport = HelmButton(title: "Copy Report", variant: .secondary, target: self,
                                    action: #selector(copyReportClicked))
        let copy = HelmButton(title: "Copy Log", variant: .secondary, target: self, action: #selector(copyLogClicked))
        let close = HelmButton(title: "Close", variant: .primary, target: self, action: #selector(closeClicked))
        closeButton = close
        close.keyEquivalent = "\r"
        // The same `[fixed, flexible spacer, fixed]` recipe
        // `ScheduleHistoryController`'s own footer fix documents (gotchas 10 +
        // 12): `.fill` distribution plus a real, low-priority zero-width
        // constraint on the spacer plus `.required` hugging on both buttons is
        // what keeps their widths their own, rather than Auto Layout's
        // tie-break stretching one of them across the row.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        for button in [copyReport, copy, close] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let footer = NSStackView(views: [copyReport, copy, spacer, close])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, subtitleLabel, explainStack, rawToggle, logScroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explainStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        applyChromeTheme()
        logTextView.string = Self.rawText(for: entry)
        // Collapsed by default - unless the explanation block has nothing of
        // its own to say, in which case hiding the only real content behind a
        // click would be worse than showing it. See this file's header.
        setRawVisible(!hasExplanation)
    }

    /// Whether this entry carries anything worth leading with other than the
    /// raw log. `false` only for an entry an older build wrote with no
    /// `failure` triple *and* no summary worth restating.
    private var hasExplanation: Bool {
        entry.failure != nil || !entry.summary.isEmpty
    }

    /// The sheet's opening sentence: what happened, in the captain's terms.
    ///
    /// For a failure or a partial this is the explanation's own `whatFailed`,
    /// which is already written as a sentence about the task rather than the
    /// code. For a success it is the run's own composed summary - the same
    /// sentence the Schedules row and the history row show, which is the
    /// point: three surfaces, one sentence, no third phrasing to reconcile.
    static func headline(for entry: ScheduleRunHistoryEntry) -> String {
        if let failure = entry.failure, !failure.whatFailed.isEmpty {
            return failure.whatFailed
        }
        if !entry.summary.isEmpty { return entry.summary }
        return entry.verdict.label
    }

    /// The raw output, verbatim. Falls back to the summary for an entry whose
    /// action had no deeper transcript, exactly as before.
    static func rawText(for entry: ScheduleRunHistoryEntry) -> String {
        entry.log ?? entry.summary
    }

    /// The explanation block: a caption column and a wrapping body column,
    /// one row per field.
    ///
    /// An `NSGridView` rather than nested stacks, for gotcha (2)'s reason -
    /// the caption column must stay narrow and the body column must absorb
    /// the width, and that only works when the *narrow* column carries the
    /// explicit width and the filling one is left free.
    private func buildExplainBlock() {
        explainStack.orientation = .vertical
        explainStack.alignment = .leading
        explainStack.spacing = 8
        explainStack.translatesAutoresizingMaskIntoConstraints = false
        explainStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        explainStack.wantsLayer = true
        explainStack.layer?.cornerRadius = 8
        explainStack.layer?.borderWidth = 1

        for field in Self.fields(for: entry) {
            let caption = NSTextField(labelWithString: field.caption)
            caption.font = HelmType.captionSmall()
            caption.alignment = .left
            caption.lineBreakMode = .byClipping
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.setContentHuggingPriority(.required, for: .horizontal)
            caption.setContentCompressionResistancePriority(.required, for: .horizontal)
            caption.widthAnchor.constraint(equalToConstant: Self.captionColumnWidth).isActive = true

            // `wrappingLabelWithString`, never `labelWithString`: gotcha (22)
            // - a label built by the latter has `wraps == false`, so
            // `maximumNumberOfLines = 0` does nothing and a real
            // three-sentence explanation would truncate with no ellipsis.
            let body = NSTextField(wrappingLabelWithString: field.body)
            body.font = HelmType.caption()
            body.translatesAutoresizingMaskIntoConstraints = false
            body.setContentHuggingPriority(.defaultLow, for: .horizontal)
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [caption, body])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            // gotcha (10): `.gravityAreas` honours no hugging priority, so
            // the body column would not reliably be the one that grows.
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            explainStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: explainStack.widthAnchor,
                                       constant: -(explainStack.edgeInsets.left + explainStack.edgeInsets.right)).isActive = true
            explainRows.append((caption, body))
        }

        rawToggle.target = self
        rawToggle.action = #selector(toggleRawClicked)
        rawToggle.title = Self.rawToggleTitle(showing: false, entry: entry)
    }

    private static let captionColumnWidth: CGFloat = 92

    /// The report's fields. Three for anything that did not finish, one for a
    /// run that did - a success has no "why" or "what to do" that is not
    /// invented, and this app does not invent one.
    static func fields(for entry: ScheduleRunHistoryEntry) -> [(caption: String, body: String)] {
        if let failure = entry.failure {
            return [
                ("What failed", failure.whatFailed),
                ("Why", failure.why),
                ("What to do", failure.whatToDo),
            ]
        }
        guard !entry.summary.isEmpty else { return [] }
        return [("What happened", entry.summary)]
    }

    /// States the log's own size, so a collapsed section never reads as an
    /// empty one - see this file's header.
    static func rawToggleTitle(showing: Bool, entry: ScheduleRunHistoryEntry) -> String {
        let lines = rawText(for: entry).split(separator: "\n", omittingEmptySubsequences: false).count
        let noun = lines == 1 ? "1 line" : "\(lines) lines"
        return showing
            ? "Hide raw output - \(noun)"
            : "Show raw output - \(noun), for debugging"
    }

    private func setRawVisible(_ visible: Bool) {
        rawIsVisible = visible
        logScroll.isHidden = !visible
        rawToggle.title = Self.rawToggleTitle(showing: visible, entry: entry)
    }

    @objc private func toggleRawClicked() {
        setRawVisible(!rawIsVisible)
    }

    private func buildLogView() {
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isRichText = false
        logTextView.font = HelmType.code()
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.widthTracksTextView = true
        // Every app-owned `NSTextView` must reach `HelmSelection` -
        // `HelmContrastSelfTest.checkEveryTextViewIsThemed`'s own source
        // guard fails the build otherwise (a raw AppKit selection paints
        // `selectedTextBackgroundColor` with no themed foreground, which is
        // how a severity-tinted run ends up on a dark blue block).
        HelmSelection.apply(to: logTextView, theme: theme)

        logScroll.documentView = logTextView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 8
        logScroll.layer?.borderWidth = 1
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    private func applyChromeTheme() {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        explainStack.layer?.backgroundColor = HelmField.fill(theme).cgColor
        explainStack.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(Self.fieldBorderAlpha).cgColor
        for row in explainRows {
            row.caption.textColor = HelmTheme.mutedInk(theme)
            row.body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        }
        logTextView.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        logTextView.backgroundColor = HelmField.fill(theme)
        HelmSelection.apply(to: logTextView, theme: theme)
        logScroll.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(Self.fieldBorderAlpha).cgColor
    }

    @objc private func copyLogClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.rawText(for: entry), forType: .string)
        Toast.show(in: view, message: "Log copied")
    }

    /// The plain-English half, for pasting into a message to someone who is
    /// not looking at this Mac. Deliberately separate from Copy Log: the two
    /// answer different questions and concatenating them would make the
    /// common case (paste the explanation) drag a subprocess transcript
    /// along with it.
    @objc private func copyReportClicked() {
        var lines = [Self.headline(for: entry),
                     "\(entry.actionTitle) \u{00B7} \(entry.verdict.label) \u{00B7} "
                        + Self.headerFormatter.string(from: entry.at)]
        for field in Self.fields(for: entry) {
            lines.append("")
            lines.append("\(field.caption): \(field.body)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        Toast.show(in: view, message: "Report copied")
    }

    @objc private func closeClicked() {
        #if FM_SELFTESTS
        debugCloseRequests += 1
        #endif
        // `dismiss(_:)` raises rather than no-opping when nothing presented
        // this controller (the same AGENTS.md gotcha 6 correction
        // `ScheduleHistoryController.closeClicked` already carries).
        guard presentingViewController != nil else { return }
        dismiss(self)
    }

    /// M6's pairing, carried over from `ScheduleHistoryController`: every
    /// sibling sheet in this app pairs Return with Escape, and this one -
    /// deliberately not a `HelmFormSheet`, since it is read-only - gets it
    /// from `cancelOperation` alone.
    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugCloseRequests = 0
    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.stringValue }
    var debugLogText: String { logTextView.string }
    /// The report half, so a suite can assert the sheet leads with a sentence
    /// rather than with raw output.
    var debugHeadline: String { titleLabel.stringValue }
    var debugExplainFields: [(caption: String, body: String)] {
        explainRows.map { ($0.caption.stringValue, $0.body.stringValue) }
    }
    var debugRawIsVisible: Bool { !logScroll.isHidden }
    var debugRawToggleTitle: String { rawToggle.title }
    func debugToggleRaw() { toggleRawClicked() }
    func debugCopyReportClicked() { copyReportClicked() }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugFooterFrames: (footer: NSRect, close: NSRect)? {
        guard let close = closeButton, let footer = close.superview else { return nil }
        return (footer.frame, close.frame)
    }
    func debugCopyClicked() { copyLogClicked() }
    #endif
}
