// Grand Line - native macOS app.
//
// UX-05 of full review 4: Weekly review becomes a review you do, not a
// dashboard you read.
//
// The tab opens on the Tasks hero's language (`ShiftReviewHeroBand`): the
// week, a verdict on how many things need a decision ("4 things to decide
// before next week.") and why, the week's done count and focus time, and a
// Start review button. The review (`ShiftReviewWalkCard`) then walks the
// overdue tasks, the ones pushed back more than once and the ones with no
// date, one at a time, with three decisions - Done, Reschedule and Drop it -
// and Skip. It ends on one sentence of summary, which can be saved to the
// Notebook, over next week's agenda.
//
// The words are `ShiftReviewWords`, pure, so the queue, the verdict and the
// summary are asserted without a window. The views report intents; every
// write is `ShiftController`'s.

import AppKit

// MARK: - The words

enum ShiftReviewWords {

    /// Why a task is in the review.
    enum Reason: Equatable { case overdue, pushedBack, noDate }

    /// One thing to decide.
    struct Decision: Equatable {
        let id: String
        let title: String
        let meta: String
        let reason: Reason
    }

    /// The review's queue: the overdue tasks oldest first, then the ones
    /// pushed back more than once, then the ones with no date. A task is
    /// asked about once, for the first reason it has.
    static func decisions(active: [ShiftTask], pushedBack: [ShiftPushedBackItem], projects: [ShiftProject],
                          now: Date, calendar: Calendar = .current) -> [Decision] {
        let pushes = Dictionary(pushedBack.map { ($0.id, $0.count) }, uniquingKeysWith: max)
        let open = active.filter { $0.status != .completed && $0.status != .cancelled }
        func meta(_ task: ShiftTask, _ reason: Reason) -> String {
            var parts: [String] = []
            if let name = task.projectID.flatMap({ pid in projects.first { $0.id == pid }?.name }) { parts.append(name) }
            switch reason {
            case .overdue:
                if let caption = ShiftTaskSignals.dueCaption(date: task.dueDate, time: task.dueTime, now: now,
                                                             calendar: calendar) {
                    parts.append(caption.text.prefix(1).lowercased() + caption.text.dropFirst())
                }
            case .pushedBack:
                if let day = task.dueDate { parts.append("due \(dueWords(day, now: now, calendar: calendar))") }
            case .noDate:
                parts.append("no date")
            }
            if let count = pushes[task.id], count >= 2 { parts.append(movedWords(count)) }
            return parts.joined(separator: " \u{00B7} ")
        }
        var seen = Set<String>()
        var out: [Decision] = []
        func add(_ task: ShiftTask, _ reason: Reason) {
            guard seen.insert(task.id).inserted else { return }
            out.append(Decision(id: task.id, title: task.title, meta: meta(task, reason), reason: reason))
        }
        open.filter { ShiftDue.isOverdue(date: $0.dueDate, time: $0.dueTime, now: now, calendar: calendar) }
            .sorted { ($0.dueDate ?? "", $0.dueTime ?? "") < ($1.dueDate ?? "", $1.dueTime ?? "") }
            .forEach { add($0, .overdue) }
        open.filter { (pushes[$0.id] ?? 0) >= 2 }
            .sorted { (pushes[$0.id] ?? 0) > (pushes[$1.id] ?? 0) }
            .forEach { add($0, .pushedBack) }
        open.filter { $0.dueDate == nil }.forEach { add($0, .noDate) }
        return out
    }

    static func movedWords(_ count: Int) -> String {
        switch count {
        case 1: return "moved once"
        case 2: return "moved twice"
        default: return "moved \(count) times"
        }
    }

    private static func dueWords(_ day: String, now: Date, calendar: Calendar) -> String {
        guard let date = ShiftDateFormatting.date(from: day) else { return day }
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return ShiftDateFormatting.monthDay(date)
    }

    /// "Weekly review · 22 to 28 November".
    static func kicker(now: Date, calendar: Calendar = .current) -> String {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let last = calendar.date(byAdding: .day, value: -1, to: week.end) else { return "Weekly review" }
        let sameMonth = calendar.component(.month, from: week.start) == calendar.component(.month, from: last)
        let start = sameMonth ? dayFormatter.string(from: week.start) : dayMonthFormatter.string(from: week.start)
        return "Weekly review \u{00B7} \(start) to \(dayMonthFormatter.string(from: last))"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter
    }()

    /// The verdict and why: "4 things to decide before next week." over "1
    /// overdue, 2 pushed back more than once, 1 with no date. About two
    /// minutes."
    static func verdict(_ decisions: [Decision]) -> (headline: String, body: String) {
        guard !decisions.isEmpty else {
            return ("Nothing to decide before next week.", "Nothing is late, nothing keeps moving, and every task has a date.")
        }
        let headline = decisions.count == 1 ? "1 thing to decide before next week."
            : "\(decisions.count) things to decide before next week."
        let overdue = decisions.filter { $0.reason == .overdue }.count
        let pushed = decisions.filter { $0.reason == .pushedBack }.count
        let undated = decisions.filter { $0.reason == .noDate }.count
        var parts: [String] = []
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if pushed > 0 { parts.append("\(pushed) pushed back more than once") }
        if undated > 0 { parts.append("\(undated) with no date") }
        return (headline, parts.joined(separator: ", ") + ". " + duration(decisions.count))
    }

    /// About half a minute a decision.
    static func duration(_ count: Int) -> String {
        let minutes = max(1, Int((Double(count) / 2).rounded()))
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        if minutes == 1 { return "About a minute." }
        return "About \(minutes <= words.count ? words[minutes - 1] : "\(minutes)") minutes."
    }

    /// The review's last sentence.
    static func summary(done: Int, moved: Int, dropped: Int, skipped: Int, nextWeek: Int) -> String {
        var parts: [String] = []
        if done > 0 { parts.append("finished \(done)") }
        if moved > 0 { parts.append("moved \(moved)") }
        if dropped > 0 { parts.append("dropped \(dropped)") }
        if skipped > 0 { parts.append("left \(skipped) for later") }
        let decided: String
        switch parts.count {
        case 0: decided = "You changed nothing this time."
        case 1: decided = "You \(parts[0])."
        default: decided = "You " + parts.dropLast().joined(separator: ", ") + " and \(parts.last ?? "")."
        }
        let ahead = nextWeek == 0 ? "Nothing is due next week yet."
            : nextWeek == 1 ? "1 thing is due next week." : "\(nextWeek) things are due next week."
        return "\(decided) \(ahead)"
    }

    /// The note the summary becomes in the Notebook.
    static func notebookTitle(now: Date, calendar: Calendar = .current) -> String {
        kicker(now: now, calendar: calendar).replacingOccurrences(of: " \u{00B7} ", with: ", ")
    }
}

// MARK: - The band

/// Weekly review's hero, in the Tasks band's language: the week and the
/// verdict on the left, the week's done count and focus time as figures, and
/// Start review as the band's one solid pill.
final class ShiftReviewHeroBand: NSView {

    static let wordsMinimumWidth: CGFloat = 260

    var onStart: (() -> Void)?

    private let surface = HelmHeroSurface()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let words = NSStackView()
    private let doneFigure = ShiftHeroFigureButton(caption: "Done this week")
    private let focusFigure = ShiftHeroFigureButton(caption: "Focus time")
    let startButton = HelmButton(title: "Start review", variant: .secondary, size: .small, symbol: "play.fill")
    private let trailing = NSStackView()
    private let row = NSStackView()
    private let column = NSStackView()
    private(set) var trailingStacked = false
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ShiftTasksHeroBand.cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addSubview(surface)

        kickerLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.font = .systemFont(ofSize: HelmType.scaled(ShiftTasksHeroBand.headlineSize), weight: .bold)
        bodyLabel.font = .systemFont(ofSize: HelmType.scaled(HelmHeroColumn.bodySize))
        for label in [kickerLabel, headlineLabel, bodyLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            words.addArrangedSubview(label)
        }
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = HelmMetrics.s1
        words.setCustomSpacing(HelmMetrics.s1 + 2, after: kickerLabel)
        words.setHuggingPriority(.defaultLow, for: .horizontal)
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)

        doneFigure.setAction(nil)
        focusFigure.setAction(nil)
        startButton.heroProminent = true
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.toolTip = "Decide each one in turn: Done, Reschedule or Drop it"
        startButton.setContentHuggingPriority(.required, for: .horizontal)
        startButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [doneFigure, focusFigure, startButton] as [NSView] { trailing.addArrangedSubview(view) }
        trailing.orientation = .horizontal
        trailing.spacing = ShiftTasksHeroBand.figureGap
        trailing.setCustomSpacing(HelmMetrics.s3, after: focusFigure)
        trailing.alignment = .centerY
        trailing.detachesHiddenViews = true
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)

        for view in [words, trailing] { row.addArrangedSubview(view) }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s5
        row.distribution = .fill
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)

        column.addArrangedSubview(row)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let insets = ShiftTasksHeroBand.insets
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            column.topAnchor.constraint(equalTo: topAnchor, constant: insets.top + 2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(insets.bottom + 4)),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// The week, the verdict, the two figures, and whether there is anything
    /// to start. GL-14: a focus total that could not be read is a dash.
    func configure(kicker: String, headline: String, body: String, done: Int, focus: String, canStart: Bool) {
        kickerLabel.stringValue = kicker.uppercased()
        headlineLabel.stringValue = headline
        bodyLabel.stringValue = body
        doneFigure.configure(count: "\(done)")
        focusFigure.configure(count: focus)
        startButton.isHidden = !canStart
        setAccessibilityLabel("\(kicker). \(headline) \(body)")
        applyTheme(theme)
        needsLayout = true
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex))
        let palette = HelmHeroSurface.palette(accent: accent, quietInk: 0.85)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        let quiet = ink.withAlphaComponent(0.85)
        appearance = NSAppearance(named: HelmContrast.relativeLuminance(palette.ink) < 0.5 ? .aqua : .darkAqua)
        kickerLabel.attributedStringValue = NSAttributedString(string: kickerLabel.stringValue,
                                                               attributes: HelmType.kickerAttributes(color: quiet))
        headlineLabel.textColor = ink
        bodyLabel.textColor = quiet
        let wash = HelmHeroCard.tileWash(for: palette)
        let hover = HelmHeroCard.tileWash(for: palette, hovered: true)
        let deep = ShiftTasksHeroBand.deepStop(of: palette)
        for figure in [doneFigure, focusFigure] {
            figure.apply(ink: ink, fill: HelmContrast.color(wash.rgb).withAlphaComponent(wash.alpha),
                         hoverFill: HelmContrast.color(hover.rgb).withAlphaComponent(hover.alpha), selectedLabel: deep)
        }
        startButton.heroInk = ink
        startButton.heroSelection = deep
    }

    override func layout() {
        super.layout()
        let available = bounds.width - ShiftTasksHeroBand.insets.left - ShiftTasksHeroBand.insets.right
        guard available > 0 else { return }
        // The figures and the button keep their width: when they do not fit
        // beside the words, they drop to a row of their own under them.
        let stack = Self.wordsMinimumWidth + row.spacing + trailing.fittingSize.width > available
        if stack != trailingStacked {
            trailingStacked = stack
            if stack {
                row.removeArrangedSubview(trailing)
                column.addArrangedSubview(trailing)
            } else {
                column.removeArrangedSubview(trailing)
                row.addArrangedSubview(trailing)
            }
        }
        // Gotcha (22): the words' width comes from the band, never the label.
        let wordsWidth = max(120, stack ? available : available - row.spacing - trailing.fittingSize.width)
        for label in [headlineLabel, bodyLabel] where abs(label.preferredMaxLayoutWidth - wordsWidth) > 0.5 {
            label.preferredMaxLayoutWidth = wordsWidth
            needsLayout = true
        }
    }

    @objc private func startTapped() { onStart?() }

    #if FM_SELFTESTS
    var debugKicker: String { kickerLabel.stringValue }
    var debugHeadline: String { headlineLabel.stringValue }
    var debugBody: String { bodyLabel.stringValue }
    var debugFigures: [(caption: String, count: String)] { [doneFigure, focusFigure].map { ($0.caption, $0.debugCount) } }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugHeadlineColor: NSColor? { headlineLabel.textColor }
    #endif
}

// MARK: - The walk

/// The review, one decision at a time: "2 of 4" and a progress bar, the
/// task's title and why it is here, then Done, Reschedule…, Drop it and Skip.
/// Once the queue is through, the summary and Save to Notebook.
///
/// Takes the keyboard while it shows: D, R and X are the three decisions,
/// S or → skips, and Escape stops the review.
final class ShiftReviewWalkCard: NSView {

    enum State: Equatable {
        case deciding(index: Int, total: Int, decision: ShiftReviewWords.Decision)
        case finished(summary: String, saved: Bool)
    }

    var onDone: (() -> Void)?
    var onReschedule: ((NSView) -> Void)?
    var onDrop: (() -> Void)?
    var onSkip: (() -> Void)?
    var onStop: (() -> Void)?
    var onSaveToNotebook: (() -> Void)?

    private let countLabel = NSTextField(labelWithString: "")
    private let countChip = NSView()
    private let track = NSView()
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    let doneButton = HelmButton(title: "Done", variant: .primary, size: .small, symbol: "checkmark")
    let rescheduleButton = HelmButton(title: "Reschedule\u{2026}", variant: .secondary, size: .small)
    let dropButton = HelmButton(title: "Drop it", variant: .secondary, size: .small)
    let skipButton = HelmButton(title: "Skip", variant: .quiet, size: .small)
    let saveButton = HelmButton(title: "Save to Notebook", variant: .secondary, size: .small, symbol: "book")
    let closeButton = HelmButton(title: "Close", variant: .quiet, size: .small)
    private let progressRow = NSStackView()
    private let decisionRow = NSStackView()
    private let finishedRow = NSStackView()
    private let stack = NSStackView()
    private(set) var state: State?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

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
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: countChip.leadingAnchor, constant: 9),
            countLabel.trailingAnchor.constraint(equalTo: countChip.trailingAnchor, constant: -9),
            countLabel.topAnchor.constraint(equalTo: countChip.topAnchor, constant: 3),
            countLabel.bottomAnchor.constraint(equalTo: countChip.bottomAnchor, constant: -3),
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
        countChip.setContentHuggingPriority(.required, for: .horizontal)
        for view in [countChip, track] as [NSView] { progressRow.addArrangedSubview(view) }
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = HelmMetrics.s3
        progressRow.distribution = .fill
        track.setContentHuggingPriority(.defaultLow, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(17), weight: .semibold)
        metaLabel.font = HelmType.caption()

        for (button, key, tip) in [(doneButton, "D", "Mark it done"), (rescheduleButton, "R", "Give it a new date"),
                                   (dropButton, "X", "Delete it, after you confirm"), (skipButton, "S", "Leave it for now")] {
            button.toolTip = "\(tip) (\(key))"
            button.target = self
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        doneButton.action = #selector(doneTapped)
        rescheduleButton.action = #selector(rescheduleTapped)
        dropButton.action = #selector(dropTapped)
        skipButton.action = #selector(skipTapped)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [doneButton, rescheduleButton, dropButton, spacer, skipButton] as [NSView] {
            decisionRow.addArrangedSubview(view)
        }
        decisionRow.orientation = .horizontal
        decisionRow.alignment = .centerY
        decisionRow.spacing = HelmMetrics.s2 + 2
        decisionRow.distribution = .fill

        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.toolTip = "Keep this summary as a note in the Notebook"
        closeButton.target = self
        closeButton.action = #selector(stopTapped)
        let finishedSpacer = NSView()
        finishedSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [saveButton, finishedSpacer, closeButton] as [NSView] { finishedRow.addArrangedSubview(view) }
        finishedRow.orientation = .horizontal
        finishedRow.alignment = .centerY
        finishedRow.spacing = HelmMetrics.s2
        finishedRow.distribution = .fill

        for view in [progressRow, titleLabel, metaLabel, decisionRow, finishedRow] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.setCustomSpacing(HelmMetrics.s4, after: progressRow)
        stack.setCustomSpacing(HelmMetrics.s4, after: metaLabel)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s4),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            decisionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            finishedRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(_ state: State) {
        self.state = state
        switch state {
        case let .deciding(index, total, decision):
            countLabel.stringValue = "\(index + 1) of \(total)"
            titleLabel.stringValue = decision.title
            metaLabel.stringValue = decision.meta
            metaLabel.isHidden = decision.meta.isEmpty
            progressRow.isHidden = false
            decisionRow.isHidden = false
            finishedRow.isHidden = true
            setAccessibilityLabel("Review, \(index + 1) of \(total): \(decision.title)")
        case let .finished(summary, saved):
            titleLabel.stringValue = summary
            metaLabel.stringValue = saved ? "Saved to the Notebook." : "Next week\u{2019}s list is below."
            metaLabel.isHidden = false
            progressRow.isHidden = true
            decisionRow.isHidden = true
            finishedRow.isHidden = false
            saveButton.isEnabled = !saved
            setAccessibilityLabel("Review done. \(summary)")
        }
        needsLayout = true
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        HelmCard.applyCardSurface(to: self, theme: theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.heroAccentHex)
        titleLabel.textColor = ink
        metaLabel.textColor = HelmTheme.mutedInk(theme)
        countChip.layer?.cornerRadius = HelmMetrics.rChip + 3
        countChip.layer?.backgroundColor = HelmField.fill(theme).cgColor
        countLabel.textColor = ink
        track.layer?.cornerRadius = 3
        track.layer?.backgroundColor = HelmField.fill(theme).cgColor
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = accent.cgColor
    }

    override func layout() {
        super.layout()
        let width = max(120, bounds.width - 2 * HelmMetrics.s4)
        for label in [titleLabel, metaLabel] where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            needsLayout = true
        }
        if case let .deciding(index, total, _) = state {
            track.layoutSubtreeIfNeeded()
            fillWidth?.constant = track.bounds.width * CGFloat(index + 1) / CGFloat(max(1, total))
        }
    }

    override var acceptsFirstResponder: Bool { state != nil }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        if event.keyCode == 53 { onStop?(); return }
        guard mods.isEmpty, case .deciding = state else { return super.keyDown(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "d": doneTapped()
        case "r": rescheduleTapped()
        case "x": dropTapped()
        case "s": skipTapped()
        default:
            if event.keyCode == 124 { skipTapped() } else { super.keyDown(with: event) }
        }
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func rescheduleTapped() { onReschedule?(rescheduleButton) }
    @objc private func dropTapped() { onDrop?() }
    @objc private func skipTapped() { onSkip?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func saveTapped() { onSaveToNotebook?() }

    #if FM_SELFTESTS
    var debugCount: String { countLabel.stringValue }
    var debugTitle: String { titleLabel.stringValue }
    var debugMeta: String { metaLabel.stringValue }
    var debugFillFraction: CGFloat { track.bounds.width > 0 ? fill.frame.width / track.bounds.width : 0 }
    #endif
}
