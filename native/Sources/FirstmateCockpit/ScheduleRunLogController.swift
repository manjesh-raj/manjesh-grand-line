// Manjesh Grand Line - native macOS app.
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

import AppKit

final class ScheduleRunLogController: NSViewController {

    private let entry: ScheduleRunHistoryEntry

    /// P3 (production review, section 21): stored and removed in `deinit`, the
    /// same fix `ScheduleHistoryController` and every `HelmFormSheet` editor
    /// already carry - a sheet built fresh on every presentation leaks a dead
    /// closure into `ThemeManager.observers` otherwise.
    private var themeObservation: ThemeObservation?
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let titleLabel = NSTextField(labelWithString: "Run Log")
    private let subtitleLabel = NSTextField(labelWithString: "")
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

        subtitleLabel.stringValue = "\(entry.actionTitle) \u{00B7} \(entry.verdict.label) \u{00B7} "
            + Self.headerFormatter.string(from: entry.at)
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        buildLogView()

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
        for button in [copy, close] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let footer = NSStackView(views: [copy, spacer, close])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, subtitleLabel, logScroll, footer])
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
        ])

        applyChromeTheme()
        logTextView.string = entry.log ?? entry.summary
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
        logTextView.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        logTextView.backgroundColor = HelmField.fill(theme)
        HelmSelection.apply(to: logTextView, theme: theme)
        logScroll.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(Self.fieldBorderAlpha).cgColor
    }

    @objc private func copyLogClicked() {
        let text = entry.log ?? entry.summary
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show(in: view, message: "Log copied")
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
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugFooterFrames: (footer: NSRect, close: NSRect)? {
        guard let close = closeButton, let footer = close.superview else { return nil }
        return (footer.frame, close.frame)
    }
    func debugCopyClicked() { copyLogClicked() }
    #endif
}
