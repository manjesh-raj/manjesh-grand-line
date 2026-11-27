// Grand Line - native macOS app.
//
// D-01 of full review 4: run mode for runbooks, with evidence. Extends
// UX-17's checklist run (`RunbookRun.swift`).
//
// While a run is on, the current step gets a panel under the checklist: its
// command, and three ways through it - "Run in Console" (sent through the
// Command Library's risk gate, with its output and exit code captured), "I
// ran it myself", or "Skip, with a reason". A failed step keeps its output
// and offers Retry, which is a second attempt under the same step rather
// than a new run. A finished run can be attached to a postmortem as
// evidence, or copied as Markdown.
//
// **How output is captured.** The same way SRE Lead's shared-terminal bridge
// reads a command's output (`SRELeadBridge`): the command is typed into the
// Console's active tab between two fresh marker lines, the viewport is
// polled for the end marker (GL-34: never a whole-buffer read per tick), and
// once it appears the lines between the markers are the output and the
// number after the end marker is the exit code. Nothing new runs a command:
// the terminal the captain already has does, exactly as "Send to terminal"
// did.
//
// **What is kept.** Output goes through `LogRedactor` before it is stored or
// shown, and each attempt keeps at most `outputLineLimit` lines. A run lives
// in memory until it is attached or copied; the runbook file is never
// written.

import AppKit

// MARK: - Evidence

struct RunbookStepAttempt: Equatable {
    var command: String
    var output: [String]
    var exitCode: Int32?
    var startedAt: Date
    var endedAt: Date
    var redactions: Int
    /// The marker never came back inside the timeout.
    var timedOut = false

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

struct RunbookStepEvidence: Equatable {
    enum Outcome: Equatable {
        case pending
        case done(manual: Bool)
        case failed
        case skipped(reason: String)
    }

    var title: String
    var command: String?
    var attempts: [RunbookStepAttempt] = []
    var outcome: Outcome = .pending
    var startedAt: Date?
    var endedAt: Date?

    var retries: Int { max(0, attempts.count - 1) }
}

struct RunbookRunEvidence: Equatable {
    let runbookID: String
    let runbookTitle: String
    let startedAt: Date
    var endedAt: Date?
    var steps: [RunbookStepEvidence]
    /// The incident this run attached itself to, if one was active.
    var incidentID: String?

    init(runbookID: String, title: String, steps: [RunbookSteps.Step], now: Date) {
        self.runbookID = runbookID
        runbookTitle = title
        startedAt = now
        self.steps = steps.map { RunbookStepEvidence(title: $0.title, command: $0.command) }
        if !self.steps.isEmpty { self.steps[0].startedAt = now }
    }

    var finishedCount: Int {
        steps.filter { if case .done = $0.outcome { return true }; if case .skipped = $0.outcome { return true }; return false }.count
    }
    var retriedSteps: [Int] { steps.indices.filter { steps[$0].retries > 0 } }
    var outputLineCount: Int { steps.flatMap(\.attempts).map(\.output.count).reduce(0, +) }

    mutating func record(_ attempt: RunbookStepAttempt, at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps[index].attempts.append(attempt)
        steps[index].outcome = attempt.succeeded ? .pending : .failed
    }

    mutating func finish(_ index: Int, _ outcome: RunbookStepEvidence.Outcome, now: Date) {
        guard steps.indices.contains(index) else { return }
        steps[index].outcome = outcome
        steps[index].endedAt = now
        if steps.indices.contains(index + 1) { steps[index + 1].startedAt = now }
    }

    // MARK: Words

    /// "5 of 5 steps · step 4 retried once · 14 lines of output kept".
    var summary: String {
        var parts = ["\(finishedCount) of \(steps.count) steps"]
        let retried = retriedSteps
        if retried.count == 1, let only = retried.first {
            let n = steps[only].retries
            parts.append("step \(only + 1) retried \(n == 1 ? "once" : "\(n) times")")
        } else if retried.count > 1 {
            parts.append("\(retried.count) steps retried")
        }
        let lines = outputLineCount
        parts.append(lines == 1 ? "1 line of output kept" : "\(lines) lines of output kept")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Rotate a TLS certificate: done in 18 minutes" / ": stopped at step 3".
    func headline(now: Date) -> String {
        let seconds = Int((endedAt ?? now).timeIntervalSince(startedAt))
        if finishedCount == steps.count { return "\(runbookTitle): done in \(RunbookWords.minutes(seconds))" }
        return "\(runbookTitle): stopped at step \(finishedCount + 1) of \(steps.count)"
    }

    /// The run as a postmortem's evidence section, or for the clipboard.
    func markdown(timeZone: TimeZone = .current) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_GB")
        day.timeZone = timeZone
        day.dateFormat = "d MMM yyyy"
        var lines: [String] = []
        lines.append("### Runbook run: \(runbookTitle)")
        lines.append("")
        let end = endedAt.map { " to \(clock.string(from: $0))" } ?? ", still running"
        var meta = "\(day.string(from: startedAt)), \(clock.string(from: startedAt))\(end) \u{00B7} \(summary)"
        if let incidentID { meta += " \u{00B7} attached to \(incidentID)" }
        lines.append(meta)
        lines.append("")
        for (i, step) in steps.enumerated() {
            let state: String
            switch step.outcome {
            case .pending: state = "not reached"
            case .done(let manual):
                if manual { state = "done by hand" } else {
                    let code = step.attempts.last?.exitCode.map { ", exit \($0)" } ?? ""
                    state = (step.retries > 0 ? "done after \(step.retries == 1 ? "a retry" : "\(step.retries) retries")" : "done") + code
                }
            case .failed: state = "failed"
            case .skipped(let reason): state = "skipped: \(reason)"
            }
            var duration = ""
            if let start = step.startedAt, let stop = step.endedAt {
                duration = ", " + RunbookWords.stepTime(max(0, Int(stop.timeIntervalSince(start))))
            }
            lines.append("\(i + 1). **\(step.title)** - \(state)\(duration)")
            for (n, attempt) in step.attempts.enumerated() {
                if step.attempts.count > 1 {
                    let code = attempt.timedOut ? "no exit code (timed out)" : "exit \(attempt.exitCode.map(String.init) ?? "?")"
                    lines.append("   Attempt \(n + 1), \(clock.string(from: attempt.startedAt)), \(code):")
                }
                lines.append("   ```")
                lines.append("   $ \(attempt.command.replacingOccurrences(of: "\n", with: "\n   $ "))")
                for out in attempt.output { lines.append("   \(out)") }
                lines.append("   ```")
            }
        }
        lines.append("")
        return LogRedactor.redact(lines.joined(separator: "\n")).text
    }
}

// MARK: - Capture

/// One command typed into a terminal between markers, and its output read
/// back. Mirrors `SRELeadBridge`'s request handling for one command.
final class RunbookStepCapture {

    static let outputLineLimit = 400
    static let timeout: TimeInterval = 600
    static let pollInterval: TimeInterval = 0.5

    struct Result: Equatable {
        var output: [String]
        var exitCode: Int32?
        var redactions: Int
        var timedOut: Bool
    }

    private let terminal: SRELeadBridgeTerminal
    private let command: String
    let startMarker: String
    let endMarker: String
    private var timer: Timer?
    private var startedAt = Date()
    private var completion: ((Result) -> Void)?
    var timeout: TimeInterval = RunbookStepCapture.timeout

    init(terminal: SRELeadBridgeTerminal, command: String, id: String = UUID().uuidString.prefix(8).lowercased()) {
        self.terminal = terminal
        self.command = command
        startMarker = "__GL_RUNBOOK_\(id)_START__"
        endMarker = "__GL_RUNBOOK_\(id)_END__"
    }

    /// What is typed: the start marker, the command as written, then the end
    /// marker with the command's status. Three lines, so a multi-line
    /// command keeps its own line breaks.
    var typedText: String {
        "echo \(startMarker)\n\(command)\necho \"\(endMarker):$?\"\n"
    }

    func start(completion: @escaping (Result) -> Void) {
        self.completion = completion
        startedAt = Date()
        terminal.sendCommand(typedText)
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        completion = nil
    }

    /// The exit code on an end-marker line: exactly `<marker>:<digits>`. The
    /// terminal's echo of the typed line contains the marker too, but never
    /// equals this shape.
    func exitCode(onMarkerLine line: String) -> Int32? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(endMarker + ":") else { return nil }
        return Int32(trimmed.dropFirst(endMarker.count + 1))
    }

    func poll() {
        // GL-34: the viewport first; the whole buffer only once it is done.
        let done = terminal.currentViewportLines().contains { exitCode(onMarkerLine: $0) != nil }
        if !done {
            if Date().timeIntervalSince(startedAt) > timeout {
                finish(Result(output: ["(no end marker after \(Int(timeout / 60)) minutes - the command may still be running)"],
                              exitCode: nil, redactions: 0, timedOut: true))
            }
            return
        }
        finish(Self.extract(lines: terminal.currentBufferLines(), capture: self))
    }

    /// The output between the last start marker and the end marker after it.
    static func extract(lines: [String], capture: RunbookStepCapture) -> Result {
        guard let endIndex = lines.lastIndex(where: { capture.exitCode(onMarkerLine: $0) != nil }) else {
            return Result(output: [], exitCode: nil, redactions: 0, timedOut: true)
        }
        let code = capture.exitCode(onMarkerLine: lines[endIndex])
        let startIndex = lines[..<endIndex].lastIndex { $0.trimmingCharacters(in: .whitespaces) == capture.startMarker }
        var body = Array(lines[(startIndex.map { $0 + 1 } ?? endIndex)..<endIndex])
        // The terminal's echo of the typed command and the end marker's echo
        // are not output.
        body.removeAll { $0.contains(capture.endMarker) || $0.contains(capture.startMarker) }
        // Every line of the command is echoed after a prompt, the first and
        // the rest of a multi-line command alike.
        let typed = capture.command.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        body.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return typed.contains { trimmed == $0 || (trimmed.hasSuffix(" " + $0) && trimmed.count > $0.count) }
        }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        if body.count > outputLineLimit { body = Array(body.suffix(outputLineLimit)) }
        let redacted = LogRedactor.redact(body.joined(separator: "\n"))
        let output = redacted.text.isEmpty ? [] : redacted.text.components(separatedBy: "\n")
        return Result(output: output, exitCode: code, redactions: redacted.count, timedOut: false)
    }

    private func finish(_ result: Result) {
        timer?.invalidate()
        timer = nil
        let done = completion
        completion = nil
        done?(result)
    }
}

// MARK: - The step panel

/// The panel under the checklist while a run is on: the current step with
/// its command and ways through it, the captured output, a failure with
/// Retry, and the finished run with Attach and Copy.
final class RunbookStepPanel: NSView {

    enum State: Equatable {
        case hidden
        case step(index: Int, total: Int, step: RunbookStepEvidence, target: String, capturing: Bool)
        case finished(RunbookRunEvidence)
    }

    var onRunInConsole: (() -> Void)?
    var onRanMyself: (() -> Void)?
    var onSkip: (() -> Void)?
    var onNext: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenConsole: (() -> Void)?
    var onStopRun: (() -> Void)?
    var onAttach: ((NSView) -> Void)?
    var onCopy: (() -> Void)?

    private let kicker = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let commandWell = NSView()
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let outputHead = NSTextField(labelWithString: "")
    private let outputWell = NSView()
    private let outputLabel = NSTextField(wrappingLabelWithString: "")
    private let outputFoot = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let stack = NSStackView()
    private var actions: [() -> Void] = []
    private var theme = ThemeManager.shared.theme
    private(set) var state: State = .hidden

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        kicker.font = HelmType.chip()
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(15), weight: .semibold)
        detailLabel.font = HelmType.caption()
        for (well, label) in [(commandWell, commandLabel), (outputWell, outputLabel)] {
            well.wantsLayer = true
            well.layer?.cornerRadius = HelmMetrics.rControl
            well.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: HelmType.scaled(12), weight: .regular)
            label.isSelectable = true
            label.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: well.topAnchor, constant: 9),
                label.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -9),
            ])
        }
        outputHead.font = HelmType.chip()
        outputFoot.font = HelmType.caption()
        buttons.orientation = .horizontal
        buttons.spacing = HelmMetrics.s2
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s4, bottom: HelmMetrics.s3, right: HelmMetrics.s4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [kicker, titleLabel, detailLabel, commandWell, buttons, outputHead, outputWell, outputFoot] as [NSView] {
            stack.addArrangedSubview(v)
        }
        stack.setCustomSpacing(HelmMetrics.s3, after: commandWell)
        stack.setCustomSpacing(HelmMetrics.s3, after: buttons)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            commandWell.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * HelmMetrics.s4),
            outputWell.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * HelmMetrics.s4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func render(_ state: State, theme: HelmTheme, now: Date = Date()) {
        self.state = state
        self.theme = theme
        actions.removeAll()
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = state == .hidden
        for v in [commandWell, outputHead, outputWell, outputFoot, detailLabel] as [NSView] { v.isHidden = true }
        switch state {
        case .hidden:
            return
        case .step(let index, let total, let step, let target, let capturing):
            kicker.stringValue = "STEP \(index + 1) OF \(total)"
            titleLabel.stringValue = step.title
            if let command = step.command {
                commandWell.isHidden = false
                commandLabel.stringValue = command.components(separatedBy: "\n").map { "$ \($0)" }.joined(separator: "\n")
                detailLabel.isHidden = false
                detailLabel.stringValue = "Runs in \(target), through the Command Library\u{2019}s risk gate."
            } else {
                detailLabel.isHidden = false
                detailLabel.stringValue = "No command for this step. Do it, then mark it done."
            }
            let last = step.attempts.last
            if step.outcome == .failed, let last {
                showOutput(last, failed: true)
                addButton("Retry", "arrow.clockwise", .primary) { [weak self] in self?.onRetry?() }
                addButton("Open Console", "terminal", .secondary) { [weak self] in self?.onOpenConsole?() }
                addButton("Stop the run", "stop.fill", .quiet) { [weak self] in self?.onStopRun?() }
            } else if let last, last.succeeded {
                showOutput(last, failed: false)
                addButton("Mark done, next step", "checkmark", .primary) { [weak self] in self?.onNext?() }
                addButton("Run again", "arrow.clockwise", .secondary) { [weak self] in self?.onRetry?() }
            } else if capturing {
                outputHead.isHidden = false
                outputHead.stringValue = "RUNNING IN CONSOLE\u{2026}"
                addButton("I ran it myself", "hand.raised", .secondary) { [weak self] in self?.onRanMyself?() }
            } else {
                if step.command != nil {
                    addButton("Run in Console", "play.fill", .primary) { [weak self] in self?.onRunInConsole?() }
                    addButton("I ran it myself", "hand.raised", .secondary) { [weak self] in self?.onRanMyself?() }
                } else {
                    addButton("Mark done, next step", "checkmark", .primary) { [weak self] in self?.onRanMyself?() }
                }
                addButton("Skip, with a reason", "forward", .quiet) { [weak self] in self?.onSkip?() }
            }
        case .finished(let run):
            kicker.stringValue = "RUN FINISHED \u{00B7} \(ExpiryWords.dayMonth(run.endedAt ?? now))"
            titleLabel.stringValue = run.headline(now: now)
            detailLabel.isHidden = false
            detailLabel.stringValue = run.summary + (run.incidentID.map { " \u{00B7} on \($0)'s timeline" } ?? "")
            addButton("Attach to a postmortem", "paperclip", .primary) { [weak self] in
                guard let self else { return }
                self.onAttach?(self.buttons.arrangedSubviews.first ?? self)
            }
            addButton("Copy as Markdown", "doc.on.doc", .secondary) { [weak self] in self?.onCopy?() }
        }
        applyTheme(theme)
    }

    private func showOutput(_ attempt: RunbookStepAttempt, failed: Bool) {
        outputHead.isHidden = false
        outputWell.isHidden = false
        outputFoot.isHidden = false
        outputHead.stringValue = failed ? "FAILED \u{00B7} EXIT \(attempt.exitCode.map(String.init) ?? "?")" : "CAPTURED OUTPUT"
        outputLabel.stringValue = attempt.output.isEmpty ? "(no output)" : attempt.output.joined(separator: "\n")
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        var foot = "Captured \(clock.string(from: attempt.endedAt))"
        if let code = attempt.exitCode { foot += " \u{00B7} exit \(code)" }
        foot += " \u{00B7} \(attempt.output.count) line\(attempt.output.count == 1 ? "" : "s")"
        foot += attempt.redactions > 0 ? " \u{00B7} \(attempt.redactions) secret\(attempt.redactions == 1 ? "" : "s") redacted" : " \u{00B7} secrets redacted"
        outputFoot.stringValue = foot
        outputHeadIsFailure = failed
    }

    private var outputHeadIsFailure = false

    private func addButton(_ title: String, _ symbol: String, _ variant: HelmButton.Variant, run: @escaping () -> Void) {
        actions.append(run)
        let button = HelmButton(title: title, variant: variant, size: .small, symbol: symbol,
                                target: self, action: #selector(tapped(_:)))
        button.tag = actions.count - 1
        buttons.addArrangedSubview(button)
    }

    @objc private func tapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    override func layout() {
        super.layout()
        let width = max(120, bounds.width - 2 * HelmMetrics.s4)
        for label in [titleLabel, detailLabel] where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
        }
        for label in [commandLabel, outputLabel] where abs(label.preferredMaxLayoutWidth - (width - 24)) > 0.5 {
            label.preferredMaxLayoutWidth = width - 24
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        layer?.cornerRadius = HelmMetrics.rCard
        layer?.borderWidth = 1
        let accent = HelmTheme.nsColor(theme.heroAccentHex)
        layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = accent.withAlphaComponent(0.05).cgColor
        let ground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        kicker.textColor = HelmContrast.legibleTintedText(tintHex: HelmTint.accent.hex(in: theme), over: ground, theme: theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        commandWell.layer?.backgroundColor = HelmField.fill(theme).cgColor
        commandLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        outputWell.layer?.backgroundColor = HelmField.fill(theme).cgColor
        outputLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        outputHead.textColor = outputHeadIsFailure
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: ground, theme: theme)
            : HelmTheme.mutedInk(theme)
        outputFoot.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugButtonTitles: [String] { buttons.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    func debugPress(_ title: String) {
        (buttons.arrangedSubviews.first { ($0 as? NSButton)?.title == title } as? NSButton)?.performClick(nil)
    }
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugOutput: String { outputLabel.stringValue }
    var debugOutputHead: String { outputHead.stringValue }
    #endif
}

// MARK: - A small helper

extension Array where Element == RunbookStepEvidence {
    /// The step at `index`, or nil past either end.
    subscript(step index: Int) -> RunbookStepEvidence? { indices.contains(index) ? self[index] : nil }
}
