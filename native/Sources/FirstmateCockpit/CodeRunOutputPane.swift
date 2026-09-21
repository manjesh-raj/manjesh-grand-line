// Manjesh Grand Line - native macOS app.
//
// Code Preview's bottom pane: what a run printed (F11 of full review #3 §8).
//
// One card under the editor, hidden until the first Run, carrying a header
// that states the outcome and a monospaced body holding stdout and stderr as
// the child interleaved them. It is the reviewed mockup's lower half, and it is
// also where this feature keeps its promises honest: the wall clock, the
// scratch directory and the denials are printed rather than described in a
// release note nobody reads.
//
// ## Why it is a view and not another controller
//
// `CodePreviewController` already owns a toolbar, a tab strip, a web view, an
// overlay and a status bar, and GL-36 is about not letting one of those grow
// past its seams. The pane has real state of its own - a running phase, a
// finished phase, an empty phase - and every one of them is a rendering
// question, so it is a view with one `render(_:)` entry point and no knowledge
// of `CodeRunner` at all. The controller decides what to run; this decides how
// it reads.

import AppKit

/// The pane's three states.
enum CodeRunPaneState: Equatable {
    /// Nothing has been run in this tab yet - the pane is hidden entirely
    /// rather than showing an empty box, because a pane that is always there
    /// costs the editor 180pt for no information.
    case idle
    /// A run is in flight. Carries what is running, for the header.
    case running(tool: String)
    /// A run finished, one way or another.
    case finished(CodeRunOutcome)
}

final class CodeRunOutputPane: NSView {

    /// Tall enough for a stack trace's first frames without taking the editor's
    /// half of the page. Resizable is a later slice; the reviewed mockup shows
    /// a fixed pane and the editor above it is what the captain is reading.
    static let preferredHeight: CGFloat = 188

    /// Stop, while something is running.
    var onStop: (() -> Void)?
    /// Copy the pane's text.
    var onCopy: (() -> Void)?
    /// Dismiss the pane and forget the last run.
    var onClear: (() -> Void)?

    private let headerRow = NSStackView()
    private let dot = HelmSignalDot()
    private let titleLabel = NSTextField(labelWithString: "Output")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var stopButton = HelmPageToolbar.labeledButton(
        symbol: "stop.fill", title: "Stop",
        tooltip: "Stop this run", target: self, action: #selector(stopTapped))
    private lazy var copyButton = HelmPageToolbar.labeledButton(
        symbol: "doc.on.doc", title: "Copy",
        tooltip: "Copy this output to the clipboard", target: self, action: #selector(copyTapped))
    private lazy var clearButton = HelmPageToolbar.labeledButton(
        symbol: "xmark", title: "Clear",
        tooltip: "Hide this pane", target: self, action: #selector(clearTapped))

    private let separator = NSView()
    private let scroll = NSScrollView()
    private let textView = NSTextView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var state: CodeRunPaneState = .idle

    // MARK: Build

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
        applyTheme(theme)
        render(.idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        for label in [titleLabel, statusLabel, detailLabel, pathLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        titleLabel.font = HelmType.cardTitle()
        statusLabel.font = HelmType.chip()
        detailLabel.font = HelmType.code()
        pathLabel.font = HelmType.code()
        // **Two labels rather than one, and the render probe is what decided
        // it.** A single label holding "1.84 s · python3 3.12.4 · no network ·
        // temp cwd /private/…/gl-run-9f2a/work" is longer than the row at any
        // realistic width, and `byTruncatingMiddle` on the whole string ate
        // the middle of the *sentence* - it rendered as "no net…cwd
        // /private/…", which reads as a bug rather than as a truncation.
        //
        // So the sentence never truncates and the path does, which is
        // gotcha (5)'s rule applied properly: the fixed chrome keeps its size
        // and the one genuinely unbounded string is the one that shrinks.
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [dot, titleLabel, statusLabel, detailLabel] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        // `isDisplayedWhenStopped = false` stops it *drawing* and leaves its
        // 16pt frame in the row - measured in the render probe as a gap after
        // the status word. A hidden **arranged subview** is the one thing an
        // `NSStackView` genuinely excludes from layout (gotcha (11) notes the
        // same asymmetry from the other side), so it is hidden, not merely
        // undrawn.
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        // GL-16: a looping animation is gated on Reduce Motion, and the
        // spinner is the only animation this pane has.
        spinner.usesThreadedAnimation = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): a bare `NSView` has no intrinsic size, so a hugging
        // priority on it is a no-op. A spacer that must collapse needs a real
        // low-priority zero width, which is what lets the buttons sit hard
        // against the trailing edge.
        let collapse = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        collapse.isActive = true

        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = HelmMetrics.s2
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [dot, titleLabel, statusLabel, spinner, detailLabel, pathLabel, spacer,
                     stopButton, copyButton, clearButton] {
            headerRow.addArrangedSubview(view)
        }
        // Gotcha (10): the row's distribution is `.fill` and only one view is
        // allowed to flex, which is the truncating path label.
        headerRow.setHuggingPriority(.required, for: .horizontal)
        // The status word is a bold chip and the detail beside it is mono
        // caption; at the row's uniform 8pt they read as one crowded phrase
        // ("EXIT 1 0.21 s"), which the render probe showed plainly. The verdict
        // and the measurements are two different things, so the boundary
        // between them gets the wider step.
        headerRow.setCustomSpacing(HelmMetrics.s3, after: statusLabel)
        headerRow.setCustomSpacing(HelmMetrics.s3, after: spinner)
        addSubview(headerRow)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        addSubview(separator)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = HelmType.code()
        textView.textContainerInset = NSSize(width: HelmMetrics.s3, height: HelmMetrics.s2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        // Every app-owned `NSTextView` reaches `HelmSelection`, which
        // `HelmContrastSelfTest.checkEveryTextViewIsThemed` enforces as a
        // source guard.
        HelmSelection.apply(to: textView, theme: theme)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: HelmMetrics.s2),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // Gotcha (4): the document view is pinned to the **clip** view, and
            // the scroll view itself fills the card exactly - gotcha (16)'s
            // rule about a container whose height nothing ties.
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Render

    /// The one entry point. Everything the pane shows is derived from `state`,
    /// so there is no way to leave it half-updated.
    func render(_ state: CodeRunPaneState) {
        self.state = state
        switch state {
        case .idle:
            isHidden = true
            spinner.stopAnimation(nil)
            textView.string = ""
            statusLabel.stringValue = ""
            detailLabel.stringValue = ""
            pathLabel.stringValue = ""
            spinner.isHidden = true

        case .running(let tool):
            isHidden = false
            statusLabel.stringValue = "RUNNING"
            detailLabel.stringValue = "\(tool) \u{00B7} stops at \(Self.seconds(CodeRunner.wallClock))"
            pathLabel.stringValue = ""
            // GL-16 again: with Reduce Motion on, the spinner is not started
            // and the RUNNING chip is what says a run is in flight. A pane
            // whose only "something is happening" signal is an animation says
            // nothing at all to a captain who turned animation off.
            if HelmMotion.isReduced {
                spinner.isHidden = true
                spinner.stopAnimation(nil)
            } else {
                spinner.isHidden = false
                spinner.startAnimation(nil)
            }
            stopButton.isHidden = false
            copyButton.isHidden = true
            clearButton.isHidden = true
            textView.string = ""

        case .finished(let outcome):
            isHidden = false
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            stopButton.isHidden = true
            copyButton.isHidden = false
            clearButton.isHidden = false
            statusLabel.stringValue = Self.statusText(outcome)
            detailLabel.stringValue = Self.detailText(outcome)
            pathLabel.stringValue = Self.pathText(outcome)
            // GL-14 is enforced *here*, at the paint, rather than only where
            // the outcome is built: a blank pane says neither "it printed
            // nothing" nor "it never ran", and the pane is the thing the
            // captain reads. So an empty output is substituted whoever
            // produced it.
            textView.string = outcome.output.isEmpty
                ? CodeRunner.emptyOutputNote(outcome.kind)
                : outcome.output
            scrollToTop()
        }
        applyTheme(theme)
    }

    var currentState: CodeRunPaneState { state }

    var outputText: String { textView.string }

    private func scrollToTop() {
        layoutSubtreeIfNeeded()
        // A run's first line is the interesting one (a traceback's summary is
        // its last, but the pane is scrollable and the top is where reading
        // starts). The document view is a real `NSTextView`, which is flipped,
        // so gotcha (9)'s unflipped-document trap does not apply here.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The header's short verdict.
    ///
    /// Every outcome gets its own wording. GL-14's rule is the reason: a run
    /// that was killed, one that was stopped by the captain, one that exited 1
    /// and one that never started are four different things, and a single
    /// "failed" would make the pane lie about three of them.
    static func statusText(_ outcome: CodeRunOutcome) -> String {
        switch outcome.kind {
        case .ok: return "EXIT 0"
        case .failed: return "EXIT \(outcome.status)"
        case .timedOut: return "TIMED OUT"
        case .cancelled: return "STOPPED"
        case .launchFailed: return "DID NOT START"
        case .sandboxUnavailable: return "REFUSED"
        }
    }

    /// The line that states what this feature actually did - the wall clock it
    /// ran under, the directory it ran in, and the denials. Printed rather than
    /// promised, because "sandboxed" is the claim most worth being able to
    /// check.
    static func detailText(_ outcome: CodeRunOutcome) -> String {
        var parts: [String] = []
        if outcome.kind != .launchFailed, outcome.kind != .sandboxUnavailable {
            parts.append(seconds(outcome.duration))
        }
        if !outcome.toolDescription.isEmpty { parts.append(outcome.toolDescription) }
        if !outcome.sandboxPath.isEmpty { parts.append("no network \u{00B7} temp cwd") }
        if outcome.truncated {
            parts.append("output cut at \(CodeRunner.maximumOutputBytes / 1024) KB")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The scratch directory, as its own label so it is the only thing in the
    /// header that ever truncates.
    static func pathText(_ outcome: CodeRunOutcome) -> String {
        outcome.sandboxPath.isEmpty ? "" : abbreviate(outcome.sandboxPath)
    }

    /// `/var/folders/…/gl-run-9f2a/work`, which is what the mockup shows: the
    /// full path is 70 characters of machine noise, and the part that means
    /// something is the run's own directory name.
    static func abbreviate(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 3 else { return path }
        return "/\(parts[0])/\u{2026}/\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    static func seconds(_ interval: TimeInterval) -> String {
        interval < 10
            ? String(format: "%.2f s", interval)
            : String(format: "%.0f s", interval)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        HelmCard.applyCardSurface(to: self, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        layer?.masksToBounds = true
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        pathLabel.textColor = HelmTheme.mutedInk(theme)
        separator.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor

        let tint = Self.tint(for: state)
        dot.configure(tint: tint, theme: theme)
        // A hue is a safe fill and never automatically safe as text, so the
        // status word goes through `HelmContrast` rather than taking the raw
        // hue - the rule `FM_RUN_CONTRAST_TESTS` sweeps.
        statusLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: tint.hex(in: theme),
            over: HelmTheme.nsColor(theme.chromeBackgroundHex),
            theme: theme)
        // **The editor's own ground, not `HelmField.fill`.** The first version
        // used the form-well token and the render probe showed the output body
        // and the card as one flat surface in both registers - `HelmField.fill`
        // is a *well on a card*, separated by its own hairline border, and this
        // body has no border of its own.
        //
        // `backgroundHex` is the right token for a second reason: it is the
        // ground Monaco is painted on directly above (see
        // `CodePreviewTheme.palette`, where every syntax colour is
        // contrast-verified against it), so the output reads as a continuation
        // of the code surface rather than as a form field below it. The
        // foreground is the matching `foregroundHex`, corrected for that ground
        // the same way the editor's ink is.
        let ground = HelmTheme.nsColor(theme.backgroundHex)
        textView.textColor = HelmContrast.legibleOn(
            fill: ground, preferring: HelmTheme.nsColor(theme.foregroundHex))
        textView.backgroundColor = ground
        scroll.backgroundColor = ground
        scroll.drawsBackground = true
        HelmSelection.apply(to: textView, theme: theme)
        textView.font = HelmType.code()
        detailLabel.font = HelmType.code()
        pathLabel.font = HelmType.code()
    }

    /// The pane's one colour decision, kept next to the wording so the two can
    /// never disagree about whether a run went well.
    static func tint(for state: CodeRunPaneState) -> HelmTint {
        switch state {
        case .idle: return .neutral
        case .running: return .info
        case .finished(let outcome):
            switch outcome.kind {
            case .ok: return .good
            case .failed: return .critical
            case .timedOut: return .warn
            case .cancelled: return .neutral
            case .launchFailed: return .warn
            case .sandboxUnavailable: return .critical
            }
        }
    }

    // MARK: Actions

    @objc private func stopTapped() { onStop?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func clearTapped() { onClear?() }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugStatusText: String { statusLabel.stringValue }
    var debugDetailText: String { "\(detailLabel.stringValue) \(pathLabel.stringValue)" }
    var debugPathText: String { pathLabel.stringValue }
    var debugSpinnerHidden: Bool { spinner.isHidden }
    var debugOutputBackground: NSColor? { textView.backgroundColor }
    var debugOutputForeground: NSColor? { textView.textColor }
    var debugStopVisible: Bool { !stopButton.isHidden }
    var debugCopyVisible: Bool { !copyButton.isHidden }
    var debugStatusColor: NSColor? { statusLabel.textColor }
    var debugDotFill: NSColor? { dot.fillForTests }
    var debugTextView: NSTextView { textView }
    func debugStop() { stopTapped() }
    func debugCopy() { copyTapped() }
    func debugClear() { clearTapped() }
    #endif
}
