// Grand Line - native macOS app.
//
// UX-17 of full review 4: Runbooks as a list you can run.
//
// The page is a list on the left and the chosen runbook on the right, its
// steps a checklist. Run starts a session: each tick finishes the step on
// screen, records how long it took and moves to the next, and the step with
// a command can send it to the terminal through the Command Library's own
// risk gate. When the session ends, how it went - when, how long, and
// whether every step was done - is the list row's second line.
//
// Steps come from the runbook's own Markdown, so nothing new is written to
// the runbook file: a numbered or bulleted line is a step, and a fenced
// block is the command of the step above it (or, with no step above it, a
// step of its own). The last run is this machine's, kept in the app's own
// preferences (`AppDefaults`), not in the git-synced runbook.

import AppKit

// MARK: - Steps

enum RunbookSteps {

    struct Step: Equatable {
        let title: String
        var command: String?
    }

    static func parse(_ content: String) -> [Step] {
        var steps: [Step] = []
        var fence: [String]?
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = fence {
                    let command = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                        .joined(separator: "\n")
                    if !command.isEmpty {
                        if var last = steps.last, last.command == nil {
                            last.command = command
                            steps[steps.count - 1] = last
                        } else {
                            for single in command.components(separatedBy: "\n") { steps.append(Step(title: single, command: single)) }
                        }
                    }
                    fence = nil
                } else {
                    fence = []
                }
                continue
            }
            if fence != nil { fence?.append(raw); continue }
            if let title = listItem(line) { steps.append(Step(title: title, command: nil)) }
        }
        return steps
    }

    /// "1. Do this", "- Do this", "- [ ] Do this" -> "Do this".
    private static func listItem(_ line: String) -> String? {
        var rest = Substring(line)
        if let dot = rest.firstIndex(of: "."), rest[..<dot].allSatisfy(\.isNumber), !rest[..<dot].isEmpty {
            rest = rest[rest.index(after: dot)...]
        } else if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            rest = rest.dropFirst()
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[ ]") || trimmed.hasPrefix("[x]") || trimmed.hasPrefix("[X]") {
                rest = Substring(trimmed.dropFirst(3))
            }
        } else {
            return nil
        }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

// MARK: - The last run

struct RunbookRunRecord: Codable, Equatable {
    var endedAt: Date
    var seconds: Int
    var done: Int
    var total: Int
    var isClean: Bool { done == total }
}

/// This machine's last run of each runbook, by id.
enum RunbookRunLog {
    static let defaultsKey = "fm.runbooks.lastRuns"

    static func all() -> [String: RunbookRunRecord] {
        guard let data = AppDefaults.store.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RunbookRunRecord].self, from: data)) ?? [:]
    }

    static func record(_ record: RunbookRunRecord, for id: String) {
        var runs = all()
        runs[id] = record
        if let data = try? JSONEncoder().encode(runs) { AppDefaults.store.set(data, forKey: defaultsKey) }
    }
}

// MARK: - The words

enum RunbookWords {

    /// "6 steps · last run 12 Nov, 14 min, clean" / "1 step · never run".
    static func rowSubtitle(steps: Int, last: RunbookRunRecord?, now: Date, calendar: Calendar = .current) -> String {
        let count = steps == 1 ? "1 step" : "\(steps) steps"
        guard let last else { return "\(count) \u{00B7} never run" }
        return "\(count) \u{00B7} \(lastRun(last, now: now, calendar: calendar))"
    }

    static func lastRun(_ run: RunbookRunRecord, now: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(run.endedAt, inSameDayAs: now) {
            day = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(run.endedAt, inSameDayAs: yesterday) {
            day = "yesterday"
        } else {
            day = ShiftDateFormatting.monthDay(run.endedAt)
        }
        let result = run.isClean ? "clean" : "stopped at step \(run.done + 1) of \(run.total)"
        return "last run \(day), \(minutes(run.seconds)), \(result)"
    }

    /// "14 min", "under a minute".
    static func minutes(_ seconds: Int) -> String {
        seconds < 60 ? "under a minute" : "\(seconds / 60) min"
    }

    /// "1m 10s", "45s".
    static func stepTime(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }

    static func soFar(_ seconds: Int) -> String {
        seconds < 60 ? "under a minute so far" : "\(seconds / 60) min so far"
    }
}

// MARK: - A session

/// A run in progress: which step is on screen, when it started, and how long
/// each finished step took. Every method takes its own `now`.
struct RunbookSession: Equatable {
    let runbookID: String
    let total: Int
    let startedAt: Date
    private(set) var index = 0
    private(set) var stepStartedAt: Date
    private(set) var durations: [Int] = []

    init(runbookID: String, total: Int, now: Date) {
        self.runbookID = runbookID
        self.total = total
        startedAt = now
        stepStartedAt = now
    }

    var isFinished: Bool { index >= total }

    /// The step on screen is done.
    mutating func tick(now: Date) {
        guard !isFinished else { return }
        durations.append(max(0, Int(now.timeIntervalSince(stepStartedAt).rounded())))
        index += 1
        stepStartedAt = now
    }

    func elapsed(now: Date) -> Int { max(0, Int(now.timeIntervalSince(startedAt))) }

    func record(now: Date) -> RunbookRunRecord {
        RunbookRunRecord(endedAt: now, seconds: elapsed(now: now), done: index, total: total)
    }
}

// MARK: - A row

/// One runbook in the list: its title and what its runs say. The row is the
/// control (a `HoverHighlightView`, GL-16), and its menu duplicates or
/// deletes.
final class RunbookRowView: HoverHighlightView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    let runbookID: String
    var isSelected = false { didSet { restyle() } }
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(runbookID: String, target: AnyObject, action: Selector) {
        self.runbookID = runbookID
        super.init(frame: .zero)
        cornerRadius = HelmMetrics.rCard
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(14), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = HelmType.caption()
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: target, action: action))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(title: String, subtitle: String, width: CGFloat, theme: HelmTheme) {
        self.theme = theme
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        // Gotcha (22): the column's own width, less the padding.
        subtitleLabel.preferredMaxLayoutWidth = max(60, width - 2 * HelmMetrics.s4)
        accessibilityLabelOverride = "\(title), \(subtitle)"
        restyle()
    }

    private func restyle() {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rCard, daylightRadius: HelmMetrics.rCard)
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        normalColor = card
        hoverColor = card.blended(withFraction: 0.04, of: HelmTheme.nsColor(theme.chromeInkHex)) ?? card
        if isSelected {
            layer?.borderColor = HelmTheme.nsColor(theme.accentHex).cgColor
            layer?.borderWidth = 1.5
        }
        accessibilityValueOverride = isSelected ? "selected" : nil
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
    }

    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.stringValue }
}

// MARK: - The chosen runbook

/// The runbook on the right: its title, Run (or Stop) and Edit, the run's
/// progress while one is on, and the steps as a checklist.
final class RunbookDetailView: NSView {

    var onRun: (() -> Void)?
    var onStop: (() -> Void)?
    var onEdit: (() -> Void)?
    /// The step on screen is done.
    var onTick: (() -> Void)?

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    let runButton = HelmButton(title: "Run", variant: .primary, size: .small, symbol: "play.fill")
    let editButton = HelmButton(title: "Edit", variant: .secondary, size: .small)
    private let progressRow = NSStackView()
    private let countChip = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint?
    private let soFarLabel = NSTextField(labelWithString: "")
    private let stepsStack = NSStackView()
    /// D-01: the current step's panel, and the finished run's.
    let stepPanel = RunbookStepPanel()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var fraction: CGFloat = 0
    private(set) var stepRows: [NSView] = []
    private var sleeves: [ClosureSleeve] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(18), weight: .bold)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        runButton.target = self
        runButton.action = #selector(runTapped)
        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.toolTip = "Edit this runbook's Markdown"
        for button in [runButton, editButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let header = NSStackView(views: [titleLabel, runButton, editButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = HelmMetrics.s2
        header.distribution = .fill

        countLabel.font = HelmType.chip()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countChip.wantsLayer = true
        countChip.translatesAutoresizingMaskIntoConstraints = false
        countChip.addSubview(countLabel)
        track.wantsLayer = true
        fill.wantsLayer = true
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        let fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        self.fillWidth = fillWidth
        soFarLabel.font = HelmType.caption()
        soFarLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: countChip.leadingAnchor, constant: 9),
            countLabel.trailingAnchor.constraint(equalTo: countChip.trailingAnchor, constant: -9),
            countLabel.topAnchor.constraint(equalTo: countChip.topAnchor, constant: 3),
            countLabel.bottomAnchor.constraint(equalTo: countChip.bottomAnchor, constant: -3),
            track.heightAnchor.constraint(equalToConstant: ShiftReviewWalkCard.trackHeight),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
        countChip.setContentHuggingPriority(.required, for: .horizontal)
        track.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [countChip, track, soFarLabel] as [NSView] { progressRow.addArrangedSubview(view) }
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = HelmMetrics.s3
        progressRow.distribution = .fill

        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = HelmMetrics.s1 + 2
        emptyLabel.font = HelmType.caption()
        emptyLabel.stringValue = "This runbook has no steps yet. A numbered or bulleted line in its Markdown is a step, "
            + "and a fenced block under a step is its command."

        stepPanel.render(.hidden, theme: theme)
        let stack = NSStackView(views: [header, progressRow, stepsStack, stepPanel, emptyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The card is as tall as its steps, not the page (gotcha (12): the
        // stack's own priority).
        stack.setHuggingPriority(.required, for: .vertical)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s4),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show `title` and `steps`, and the session when one is on for it.
    func configure(title: String, steps: [RunbookSteps.Step], session: RunbookSession?, now: Date, theme: HelmTheme) {
        self.theme = theme
        HelmCard.applyCardSurface(to: self, theme: theme)
        titleLabel.stringValue = title
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        let running = session != nil
        runButton.title = running ? "Stop" : "Run"
        runButton.variant = running ? .secondary : .primary
        runButton.symbolName = running ? "stop.fill" : "play.fill"
        runButton.toolTip = running ? "End this run where it is, and keep how far it got"
            : "Start a run: tick each step as it is done, and each one is timed"
        runButton.isEnabled = !steps.isEmpty
        editButton.isEnabled = !running
        progressRow.isHidden = !running
        emptyLabel.isHidden = !steps.isEmpty
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
        if let session {
            countLabel.stringValue = "\(min(session.index + 1, session.total)) of \(session.total)"
            soFarLabel.stringValue = RunbookWords.soFar(session.elapsed(now: now))
            fraction = CGFloat(session.index) / CGFloat(max(1, session.total))
        }
        countChip.layer?.cornerRadius = HelmMetrics.rChip + 3
        countChip.layer?.backgroundColor = HelmField.fill(theme).cgColor
        countLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        soFarLabel.textColor = HelmTheme.mutedInk(theme)
        track.layer?.cornerRadius = ShiftReviewWalkCard.trackHeight / 2
        track.layer?.backgroundColor = HelmField.fill(theme).cgColor
        fill.layer?.cornerRadius = ShiftReviewWalkCard.trackHeight / 2
        fill.layer?.backgroundColor = HelmTheme.nsColor(theme.heroAccentHex).cgColor
        rebuildSteps(steps, session: session)
        needsLayout = true
    }

    private func rebuildSteps(_ steps: [RunbookSteps.Step], session: RunbookSession?) {
        stepsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sleeves.removeAll()
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        stepRows = steps.enumerated().map { index, step in
            let done = session.map { index < $0.index } ?? false
            let current = session.map { index == $0.index } ?? false
            let check = ShiftTaskCheckBadge(size: 16)
            check.setChecked(done, tint: HelmTheme.nsColor(theme.accentHex))
            check.isEnabled = current
            check.setAccessibilityLabel(step.title)
            if current {
                let sleeve = ClosureSleeve { [weak self] in self?.onTick?() }
                sleeves.append(sleeve)
                check.target = sleeve
                check.action = #selector(ClosureSleeve.invoke)
                check.toolTip = "This step is done"
            }
            let label = NSTextField(wrappingLabelWithString: step.title)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: current ? NSFont.systemFont(ofSize: HelmType.scaled(14), weight: .semibold) : HelmType.body(),
                .foregroundColor: done || (session != nil && !current) ? muted : ink,
            ]
            if done { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            label.attributedStringValue = NSAttributedString(string: step.title, attributes: attributes)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [check, label]
            if done, let session, index < session.durations.count {
                let chip = HelmStatusPill(style: .pill)
                chip.configure(text: RunbookWords.stepTime(session.durations[index]), tint: .good, theme: theme)
                views.append(chip)
            }
            // D-01: the step panel under the checklist carries the step's
            // command and "Run in Console", so the row has no send button.
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = HelmMetrics.s2
            row.distribution = .fill
            stepsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(lessThanOrEqualTo: stepsStack.widthAnchor).isActive = true
            return row
        }
    }

    override func layout() {
        super.layout()
        if !progressRow.isHidden {
            track.layoutSubtreeIfNeeded()
            fillWidth?.constant = track.bounds.width * fraction
        }
        let width = max(120, bounds.width - 2 * HelmMetrics.s4)
        if abs(titleLabel.preferredMaxLayoutWidth - (width - 160)) > 0.5 { titleLabel.preferredMaxLayoutWidth = width - 160 }
        if abs(emptyLabel.preferredMaxLayoutWidth - width) > 0.5 { emptyLabel.preferredMaxLayoutWidth = width }
    }

    @objc private func runTapped() {
        if runButton.title == "Stop" { onStop?() } else { onRun?() }
    }

    @objc private func editTapped() { onEdit?() }

    var debugTitle: String { titleLabel.stringValue }
    var debugCount: String { progressRow.isHidden ? "" : countLabel.stringValue }
    /// The current step's check, as a click reaches it.
    var debugCurrentCheck: ShiftTaskCheckBadge? {
        stepRows.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? ShiftTaskCheckBadge }.first { $0.isEnabled }
    }
}
