// Grand Line - native macOS app.
//
// The Tasks popover in the Bridge shape: a header with Today, the date, the
// "2 of 6 done today" count and the streak, a hero Now card with Check off,
// Start focus and Open, an Up next timeline, a backlog to claim from, and a
// footer whose main action is Open Tasks.
//
// This is what the captain approved as the notification redesign's style A,
// applied to Tasks in the feel of the Tootask menu-bar popover they showed.
// It renders a `TasksBridgeDigest` and computes nothing: every string, every
// order and every count comes from `TasksBridge.digest`, which takes an
// injected clock and is asserted in CI's blocking lane.
//
// **Two surfaces host it**, and that is why it is one view rather than two:
//
//   * The compact-mode popover's Today tab (`CompactTodayPane`), at 330pt.
//   * The Tasks menu-bar item (`ShiftMenuBarPopoverController`), at the same
//     width, with the header's pin and the footer's Settings shown.
//
// **Local on purpose.** The notification panel's own Bridge restyle is being
// built in parallel, and main has no shared Now card yet. So this file owns
// its pieces and depends on nothing that panel will change; the Now card is a
// self-contained view the panel can adopt later. Every colour comes from the
// theme through `HelmContrast`, so it holds on all 26 palettes, and every
// size goes through `HelmType`, so it follows the chrome text scale.

import AppKit

// MARK: - The pane

final class TasksBridgePane: NSView {

    /// Check off one task (the Now card's primary button and an Up next
    /// task row's check).
    var onCheckOffTask: ((String) -> Void)?
    /// Mark one follow-up done (an Up next follow-up row's check).
    var onCompleteFollowUp: ((String) -> Void)?
    /// Claim a backlog task: set it to the existing In progress status.
    var onClaimTask: ((String) -> Void)?
    /// Start the focus timer on a task. Nil hides the Now card's button.
    var onStartFocus: ((String) -> Void)? {
        didSet { nowCard.showsStartFocus = onStartFocus != nil }
    }
    var onOpenTask: ((String) -> Void)?
    var onOpenFollowUp: ((String) -> Void)?

    let header: TasksBridgeHeader
    private let nowCard = TasksBridgeNowCard()
    private let upNextKicker = TasksBridgePane.makeKicker("Up next")
    private let upNextStack = NSStackView()
    private let backlogKicker = TasksBridgePane.makeKicker("Backlog \u{00B7} claim to start")
    private let backlogStack = NSStackView()
    private let chipsRow = NSStackView()
    private let focusChip = CompactChip()
    private let followUpChip = CompactChip()
    private let column = NSStackView()

    private lazy var timelineRows = HelmKeyedRows(stack: upNextStack)
    private lazy var backlogRowsKeyed = HelmKeyedRows(stack: backlogStack)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private(set) var digest: TasksBridgeDigest = .empty

    /// - Parameter showsPin: the menu-bar item's "keep this open" pin. The
    ///   compact popover has no use for one, so it passes false.
    init(showsPin: Bool) {
        header = TasksBridgeHeader(showsPin: showsPin)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for stack in [upNextStack, backlogStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = HelmMetrics.s0
            stack.translatesAutoresizingMaskIntoConstraints = false
        }

        // A real low-priority zero-width spacer, never a hugging priority on a
        // bare `NSView` (gotcha (12)).
        let chipSpacer = NSView()
        chipSpacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = chipSpacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        chipsRow.setViews([focusChip, followUpChip, chipSpacer], in: .leading)
        chipsRow.orientation = .horizontal
        chipsRow.alignment = .centerY
        chipsRow.distribution = .fill
        chipsRow.spacing = HelmMetrics.s1 + 2
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        nowCard.onCheckOff = { [weak self] id in self?.onCheckOffTask?(id) }
        nowCard.onStartFocus = { [weak self] id in self?.onStartFocus?(id) }
        nowCard.onOpen = { [weak self] id in self?.onOpenTask?(id) }
        nowCard.showsStartFocus = false

        column.setViews([header, nowCard, upNextKicker, upNextStack, backlogKicker, backlogStack, chipsRow],
                        in: .leading)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.setCustomSpacing(HelmMetrics.s3, after: header)
        column.setCustomSpacing(HelmMetrics.s4, after: nowCard)
        column.setCustomSpacing(HelmMetrics.s1, after: upNextKicker)
        column.setCustomSpacing(HelmMetrics.s3, after: upNextStack)
        column.setCustomSpacing(HelmMetrics.s1, after: backlogKicker)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            column.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The uppercase section label, through the app's one kicker recipe.
    private static func makeKicker(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(text)
        return label
    }

    func present(_ digest: TasksBridgeDigest, theme: HelmTheme) {
        self.digest = digest
        self.theme = theme
        header.configure(dateText: digest.dateText, progress: digest.progress, streakDays: digest.streakDays)
        nowCard.configure(now: digest.now, nothingDueCaption: digest.nothingDueCaption)

        // `autoreleasepool` around a repeated AppKit construct/teardown loop in
        // a process that may have no run loop turning (AGENTS.md).
        autoreleasepool {
            // P2: keyed by id, so a refresh updates rows in place rather than
            // rebuilding them under the captain's pointer.
            timelineRows.reconcile(digest.upNext, key: { "\($0.kind):\($0.id)" }, make: { model in
                let row = TasksBridgeTimelineRow(model: model)
                row.onCheck = { [weak self] model in
                    switch model.kind {
                    case .task: self?.onCheckOffTask?(model.id)
                    case .followUp: self?.onCompleteFollowUp?(model.id)
                    }
                }
                row.onOpen = { [weak self] model in
                    switch model.kind {
                    case .task: self?.onOpenTask?(model.id)
                    case .followUp: self?.onOpenFollowUp?(model.id)
                    }
                }
                return row
            }, update: { view, model in
                (view as? TasksBridgeTimelineRow)?.configure(model)
            })
            backlogRowsKeyed.reconcile(digest.backlog, key: { $0.id }, make: { model in
                let row = TasksBridgeBacklogRow(model: model)
                row.onClaim = { [weak self] id in self?.onClaimTask?(id) }
                row.onOpen = { [weak self] id in self?.onOpenTask?(id) }
                return row
            }, update: { view, model in
                (view as? TasksBridgeBacklogRow)?.configure(model)
            })
        }

        upNextKicker.isHidden = digest.upNext.isEmpty
        upNextStack.isHidden = digest.upNext.isEmpty
        backlogKicker.isHidden = digest.backlog.isEmpty
        backlogStack.isHidden = digest.backlog.isEmpty

        focusChip.isHidden = digest.focusChip == nil
        followUpChip.isHidden = digest.followUpChip == nil
        if let focus = digest.focusChip { focusChip.configure(symbol: "clock", text: focus) }
        if let followUp = digest.followUpChip { followUpChip.configure(symbol: "bell", text: followUp) }
        chipsRow.isHidden = digest.focusChip == nil && digest.followUpChip == nil

        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        for (kicker, text) in [(upNextKicker, "Up next"), (backlogKicker, "Backlog \u{00B7} claim to start")] {
            kicker.attributedStringValue = NSAttributedString(string: text.uppercased(),
                                                              attributes: HelmType.kickerAttributes(color: muted))
        }
        header.applyTheme(theme)
        nowCard.applyTheme(theme)
        // The focus chip carries the accent as identity; the follow-up chip is
        // a no-identity chip (`HelmField.fill` plus ink), never a
        // `HelmTint.neutral` wash - see `CompactChip.applyTheme`.
        focusChip.applyTheme(theme, tint: .accent)
        followUpChip.applyTheme(theme, tint: nil)
        for row in timelineRows.orderedRows { (row as? TasksBridgeTimelineRow)?.applyTheme(theme) }
        for row in backlogRowsKeyed.orderedRows { (row as? TasksBridgeBacklogRow)?.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugNowCard: TasksBridgeNowCard { nowCard }
    var debugTimelineRows: [TasksBridgeTimelineRow] {
        timelineRows.orderedRows.compactMap { $0 as? TasksBridgeTimelineRow }
    }
    var debugBacklogRows: [TasksBridgeBacklogRow] {
        backlogRowsKeyed.orderedRows.compactMap { $0 as? TasksBridgeBacklogRow }
    }
    var debugUpNextIsHidden: Bool { upNextStack.isHidden }
    var debugBacklogIsHidden: Bool { backlogStack.isHidden }
    var debugChipsAreHidden: Bool { chipsRow.isHidden }
    var debugChipTexts: [String] {
        [focusChip, followUpChip].filter { !$0.isHidden }.map { $0.debugText }
    }
    var debugChips: [CompactChip] { [focusChip, followUpChip].filter { !$0.isHidden } }
    #endif
}

// MARK: - The header

/// "Today  Mon 26 Oct", a thin progress bar, and the done-today and streak
/// chips. The menu-bar item adds a pin that keeps the popover open.
final class TasksBridgeHeader: NSView {
    var onTogglePin: ((Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Today")
    private let dateLabel = NSTextField(labelWithString: "")
    private let bar = TasksBridgeProgressBar()
    private let progressChip = CompactChip()
    private let streakChip = CompactChip()
    private let pinButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "pin")
    private var isPinned = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(showsPin: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.drillTitle()
        titleLabel.setAccessibilityRole(.staticText)
        dateLabel.font = HelmType.caption()
        dateLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, dateLabel] { label.translatesAutoresizingMaskIntoConstraints = false }

        let titleRow = NSStackView(views: [titleLabel, dateLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = HelmMetrics.s2
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSStackView(views: [titleRow, bar])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = HelmMetrics.s1 + 2
        left.translatesAutoresizingMaskIntoConstraints = false

        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.isHidden = !showsPin
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        updatePinChrome()

        progressChip.setAccessibilityElement(true)
        progressChip.setAccessibilityRole(.staticText)
        streakChip.setAccessibilityElement(true)
        streakChip.setAccessibilityRole(.staticText)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true

        // Gotcha (10): `.fill`, with every fixed piece at required hugging and
        // compression resistance, so only the spacer and the date flex.
        let row = NSStackView(views: [left, spacer, progressChip, streakChip, pinButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s1 + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        for fixed in [progressChip, streakChip, pinButton] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 120),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(dateText: String, progress: TasksBridgeDigest.Progress?, streakDays: Int) {
        dateLabel.stringValue = dateText
        dateLabel.isHidden = dateText.isEmpty
        // GL-14: no progress is not "0/0". Bar and chip go together.
        bar.isHidden = progress == nil
        progressChip.isHidden = progress == nil
        if let progress {
            bar.fraction = progress.fraction
            progressChip.configure(symbol: "checkmark.circle", text: progress.shortText)
            progressChip.setAccessibilityLabel(progress.spokenText)
            progressChip.toolTip = progress.spokenText
            bar.setAccessibilityLabel(progress.spokenText)
        }
        streakChip.isHidden = streakDays <= 0
        let streakText = "\(streakDays)-day streak"
        streakChip.configure(symbol: "flame.fill", text: "\(streakDays)")
        streakChip.setAccessibilityLabel(streakText)
        streakChip.toolTip = "\(streakText): a task finished every day"
        applyTheme(theme)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        updatePinChrome()
    }

    @objc private func pinTapped() {
        setPinned(!isPinned)
        onTogglePin?(isPinned)
    }

    private func updatePinChrome() {
        pinButton.symbolName = isPinned ? "pin.fill" : "pin"
        pinButton.toolTip = isPinned ? "Unpin: close when you click away" : "Pin: keep this open"
        pinButton.tint = isPinned ? .accent : nil
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        dateLabel.textColor = HelmTheme.mutedInk(theme)
        bar.applyTheme(theme)
        progressChip.applyTheme(theme, tint: nil)
        streakChip.applyTheme(theme, tint: .warn)
    }

    #if FM_SELFTESTS
    var debugProgressText: String? { progressChip.isHidden ? nil : progressChip.debugText }
    var debugStreakText: String? { streakChip.isHidden ? nil : streakChip.debugText }
    var debugBarIsHidden: Bool { bar.isHidden }
    var debugBarFraction: Double { bar.fraction }
    var debugPinButton: HelmButton { pinButton }
    var debugIsPinned: Bool { isPinned }
    var debugChips: [CompactChip] { [progressChip, streakChip].filter { !$0.isHidden } }
    #endif
}

/// A thin track with the done-today fraction filled in the accent.
///
/// A bar is a fill, never text, so the raw accent is safe here (AGENTS.md's
/// `HelmTint` rule). Not interactive, so it carries a label and no action.
final class TasksBridgeProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsLayout = true } }
    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        // No implicit animation: the bar re-renders on every refresh, and a
        // fill sliding into place on each open is motion nobody asked for.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(1, fraction))),
                            height: bounds.height)
        CATransaction.commit()
    }

    override func accessibilityValue() -> Any? { NSNumber(value: fraction) }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.dividerAlpha).cgColor
        fill.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor
    }
}

// MARK: - The Now card

/// The hero card: the one task due now, its time pill, its subtask progress,
/// and Check off, Start focus and Open right on it.
///
/// Self-contained, so the notification panel's Bridge restyle can adopt it
/// later without taking anything else from this file.
final class TasksBridgeNowCard: NSView {
    var onCheckOff: ((String) -> Void)?
    var onStartFocus: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var showsStartFocus = true { didSet { focusButton.isHidden = !showsStartFocus || model == nil } }

    private let boltIcon = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "NOW")
    private let pill = CompactChip()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let checkOffButton = HelmButton(title: "Check off", variant: .primary, size: .regular)
    private let focusButton = HelmButton(title: "Start focus", variant: .secondary, size: .regular)
    private let openButton = HelmButton(title: "Open", variant: .secondary, size: .regular)
    private let actions = NSStackView()
    private let stack = NSStackView()
    private var model: TasksBridgeDigest.NowCard?
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 1

        boltIcon.translatesAutoresizingMaskIntoConstraints = false
        kickerLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false

        let kickerSpacer = NSView()
        kickerSpacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = kickerSpacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        let kickerRow = NSStackView(views: [boltIcon, kickerLabel, kickerSpacer, pill])
        kickerRow.orientation = .horizontal
        kickerRow.alignment = .centerY
        kickerRow.distribution = .fill
        kickerRow.spacing = HelmMetrics.s1 + 1
        kickerRow.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Titles wrap instead of truncating - one of the three things the
        // captain's "old school" read was about. Capped, so a pasted
        // paragraph cannot push the buttons out of the card.
        titleLabel.font = HelmType.sectionTitle()
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = HelmType.caption()
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [(checkOffButton, #selector(checkOffTapped)),
                                 (focusButton, #selector(focusTapped)),
                                 (openButton, #selector(openTapped))] {
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // The board's soft secondaries: the accent as the label hue, routed
        // through `HelmContrast` by `HelmButton` itself.
        focusButton.tint = .accent
        openButton.tint = .accent
        checkOffButton.toolTip = "Mark this task done"
        focusButton.toolTip = "Start a focus session on this task"
        openButton.toolTip = "Open this task in Tasks"
        let actionsSpacer = NSView()
        actionsSpacer.translatesAutoresizingMaskIntoConstraints = false
        let actionsCollapsed = actionsSpacer.widthAnchor.constraint(equalToConstant: 0)
        actionsCollapsed.priority = .defaultLow
        actionsCollapsed.isActive = true
        actions.setViews([checkOffButton, focusButton, openButton, actionsSpacer], in: .leading)
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.spacing = HelmMetrics.s1 + 2
        actions.translatesAutoresizingMaskIntoConstraints = false

        stack.setViews([kickerRow, titleLabel, detailLabel, actions], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.setCustomSpacing(HelmMetrics.s2, after: kickerRow)
        stack.setCustomSpacing(HelmMetrics.s3, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3 + 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HelmMetrics.s3 + 2)),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3 + 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s3 + 2)),
            kickerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            boltIcon.widthAnchor.constraint(equalToConstant: 12),
            boltIcon.heightAnchor.constraint(equalToConstant: 12),
        ])

        // GL-16: one group VoiceOver names after the task, so "Check off" is
        // heard as "Now: Rotate the staging certificate, ... Check off".
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Gotcha (22): a wrapping label's width comes from the card's own
    /// resolved width minus its padding, never from the label itself.
    override func layout() {
        super.layout()
        let width = max(40, bounds.width - 2 * (HelmMetrics.s3 + 2))
        if titleLabel.preferredMaxLayoutWidth != width {
            titleLabel.preferredMaxLayoutWidth = width
            detailLabel.preferredMaxLayoutWidth = width
            super.layout()
        }
    }

    func configure(now: TasksBridgeDigest.NowCard?, nothingDueCaption: String) {
        model = now
        if let now {
            titleLabel.stringValue = now.title
            detailLabel.stringValue = now.detail
            detailLabel.isHidden = now.detail.isEmpty
            pill.configure(symbol: now.isLate ? "exclamationmark.circle" : "clock", text: now.whenText)
            pill.isHidden = false
            actions.isHidden = false
            focusButton.isHidden = !showsStartFocus
            let late = now.isLate ? ", \(now.whenText)" : ", due \(now.whenText)"
            setAccessibilityLabel("Now: \(now.title)\(late)")
        } else {
            // Never a blank card (GL-14): it says there is nothing due, and
            // what comes next.
            titleLabel.stringValue = "Nothing due right now"
            detailLabel.stringValue = nothingDueCaption
            detailLabel.isHidden = false
            pill.isHidden = true
            actions.isHidden = true
            setAccessibilityLabel("Now: nothing due right now. \(nothingDueCaption)")
        }
        applyTheme(theme)
    }

    @objc private func checkOffTapped() { if let id = model?.id { onCheckOff?(id) } }
    @objc private func focusTapped() { if let id = model?.id { onStartFocus?(id) } }
    @objc private func openTapped() { if let id = model?.id { onOpen?(id) } }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accentHex = theme.accentHex
        // A soft accent wash, solved for a legible foreground against both
        // the card and the page ground.
        let surface = HelmContrast.tintedSurface(tintHex: accentHex, theme: theme,
                                                 target: HelmContrast.textTarget)
        let fill = surface.fill
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = HelmTheme.nsColor(accentHex).withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dSurface : HelmMetrics.rCard

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.textColor = HelmContrast.legibleOn(fill: fill, preferring: ink)
        detailLabel.textColor = HelmContrast.legibleOn(fill: fill, preferring: HelmTheme.mutedInk(theme))
        let kickerColor = HelmContrast.legibleTintedText(tintHex: accentHex, over: fill, theme: theme)
        kickerLabel.attributedStringValue = NSAttributedString(
            string: "NOW", attributes: HelmType.kickerAttributes(color: kickerColor))
        boltIcon.image = HelmSymbol.image("bolt.fill", pointSize: 11, weight: .bold)
        boltIcon.contentTintColor = kickerColor
        pill.applyTheme(theme, tint: model?.isLate == true ? .critical : .accent)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugPillText: String? { pill.isHidden ? nil : pill.debugText }
    var debugPill: CompactChip { pill }
    var debugActionsAreHidden: Bool { actions.isHidden }
    var debugCheckOffButton: HelmButton { checkOffButton }
    var debugFocusButton: HelmButton { focusButton }
    var debugOpenButton: HelmButton { openButton }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugTitleColor: NSColor { titleLabel.textColor ?? .clear }
    var debugDetailColor: NSColor { detailLabel.textColor ?? .clear }
    var debugFillColor: NSColor {
        guard let cg = layer?.backgroundColor else { return .clear }
        return NSColor(cgColor: cg) ?? .clear
    }
    #endif
}

// MARK: - Rows

/// One Up next row: the time, the title, its caption, and a check.
///
/// A `HoverHighlightView` because the row opens its task (GL-16: that one
/// component supplies the role, the label, the focus ring and the keyboard
/// press). The check is a real button nested inside it, and
/// `HoverHighlightView` arbitrates the two clicks (gotcha (20)).
final class TasksBridgeTimelineRow: HoverHighlightView {
    var onCheck: ((TasksBridgeDigest.TimelineRow) -> Void)?
    var onOpen: ((TasksBridgeDigest.TimelineRow) -> Void)?

    private let timeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let checkButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "checkmark")
    private var timeWidth: NSLayoutConstraint?
    private(set) var model: TasksBridgeDigest.TimelineRow
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(model: TasksBridgeDigest.TimelineRow) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rChip + 1
        onAccessibilityPress = { [weak self] in self?.openTapped() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openTapped)))

        timeLabel.font = HelmType.metric(12, weight: .bold)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = HelmType.rowTitle()
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = HelmType.caption()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        checkButton.target = self
        checkButton.action = #selector(checkTapped)
        checkButton.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(timeLabel)
        addSubview(text)
        addSubview(checkButton)
        let timeWidth = timeLabel.widthAnchor.constraint(equalToConstant: Self.timeColumnWidth())
        self.timeWidth = timeWidth
        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1 + 2),
            timeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            timeWidth,
            text.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: HelmMetrics.s2),
            text.trailingAnchor.constraint(equalTo: checkButton.leadingAnchor, constant: -HelmMetrics.s2),
            text.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1 + 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s1 + 2)),
            checkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),
            checkButton.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1 + 1),
        ])
        // Gotcha (5): only the text may give up width.
        for fixed in [timeLabel, checkButton] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Wide enough for the widest time this column shows ("10:50 PM" in a
    /// 12-hour locale), measured in the scaled font so Larger text widens it.
    static func timeColumnWidth() -> CGFloat {
        let font = HelmType.metric(12, weight: .bold)
        let widest = ["10:50 PM", "22:50", "16 Sep", "Today", "Tmrw", "Wed"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 52
        return ceil(widest) + 2
    }

    /// Gotcha (22): the row's own width minus its rigid siblings, never the
    /// label's own width.
    override func layout() {
        super.layout()
        let rigid = (timeWidth?.constant ?? 0) + checkButton.fittingSize.width
            + HelmMetrics.s1 + 2 + HelmMetrics.s1 + 2 * HelmMetrics.s2
        let width = max(40, floor(bounds.width - rigid))
        if titleLabel.preferredMaxLayoutWidth != width {
            titleLabel.preferredMaxLayoutWidth = width
            super.layout()
        }
    }

    func configure(_ model: TasksBridgeDigest.TimelineRow) {
        self.model = model
        timeLabel.stringValue = model.timeText
        titleLabel.stringValue = model.title
        detailLabel.stringValue = model.detail
        detailLabel.isHidden = model.detail.isEmpty
        let verb = model.kind == .task ? "Check off" : "Mark done"
        checkButton.toolTip = "\(verb) \(model.title)"
        let detail = model.detail.isEmpty ? "" : ", \(model.detail)"
        accessibilityLabelOverride = "\(model.timeText), \(model.title)\(detail)"
        applyTheme(theme)
    }

    @objc private func openTapped() { onOpen?(model) }
    @objc private func checkTapped() { onCheck?(model) }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        normalColor = .clear
        hoverColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.06)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        // The time is text in a hue, so it goes through `HelmContrast`. Late
        // is red and also says "Overdue" in the caption (GL-16: never colour
        // alone); everything else takes the accent.
        let hue = model.urgency == .overdue ? HelmTint.critical : HelmTint.accent
        timeLabel.textColor = HelmContrast.legibleTintedText(tintHex: hue.hex(in: theme), over: ground,
                                                             theme: theme)
    }

    #if FM_SELFTESTS
    var debugTimeText: String { timeLabel.stringValue }
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugTimeColor: NSColor { timeLabel.textColor ?? .clear }
    var debugCheckButton: HelmButton { checkButton }
    var debugTitleLabel: NSTextField { titleLabel }
    func debugClick() { openTapped() }
    #endif
}

/// One backlog row: a dot, the title, its caption, and Claim - or "In
/// progress" once it has been claimed.
final class TasksBridgeBacklogRow: HoverHighlightView {
    var onClaim: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    private let dot = NSView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let claimButton = HelmButton(title: "Claim", variant: .primary, size: .small)
    private let claimedLabel = NSTextField(labelWithString: "In progress")
    private let trailing = NSStackView()
    private(set) var model: TasksBridgeDigest.BacklogRow
    private var theme: HelmTheme = ThemeManager.shared.theme
    private static let dotSize: CGFloat = 6

    init(model: TasksBridgeDigest.BacklogRow) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rChip + 1
        onAccessibilityPress = { [weak self] in self?.openTapped() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openTapped)))

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = HelmType.rowTitle()
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = HelmType.caption()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        claimButton.target = self
        claimButton.action = #selector(claimTapped)
        claimButton.translatesAutoresizingMaskIntoConstraints = false
        claimedLabel.font = HelmType.caption()
        claimedLabel.translatesAutoresizingMaskIntoConstraints = false

        trailing.setViews([claimButton, claimedLabel], in: .leading)
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(text)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            dot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor, constant: 0),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s2 + 2),
            text.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -HelmMetrics.s2),
            text.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1 + 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s1 + 2)),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),
            trailing.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1 + 1),
        ])
        for fixed in [claimButton, claimedLabel] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Gotcha (22), as on the timeline row.
    override func layout() {
        super.layout()
        let rigid = Self.dotSize + HelmMetrics.s2 + HelmMetrics.s2 + 2 + HelmMetrics.s2 + HelmMetrics.s1
            + trailing.fittingSize.width
        let width = max(40, floor(bounds.width - rigid))
        if titleLabel.preferredMaxLayoutWidth != width {
            titleLabel.preferredMaxLayoutWidth = width
            super.layout()
        }
    }

    func configure(_ model: TasksBridgeDigest.BacklogRow) {
        self.model = model
        titleLabel.stringValue = model.title
        detailLabel.stringValue = model.detail
        claimButton.isHidden = model.isClaimed
        claimedLabel.isHidden = !model.isClaimed
        claimButton.toolTip = "Claim \(model.title): set it In progress"
        accessibilityLabelOverride = "\(model.title), \(model.detail)"
            + (model.isClaimed ? ", in progress" : "")
        applyTheme(theme)
    }

    @objc private func openTapped() { onOpen?(model.id) }
    @objc private func claimTapped() { onClaim?(model.id) }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        normalColor = .clear
        hoverColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.06)
        dot.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        claimedLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.good.hex(in: theme), over: HelmTheme.nsColor(theme.chromeBackgroundHex),
            theme: theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugClaimButton: HelmButton { claimButton }
    var debugClaimedIsShowing: Bool { !claimedLabel.isHidden }
    var debugClaimedColor: NSColor { claimedLabel.textColor ?? .clear }
    func debugClick() { openTapped() }
    #endif
}

// MARK: - The footer

/// The footer's one main action, Open Tasks, plus a quiet Settings where the
/// host has somewhere for it to go.
final class TasksBridgeFooter: NSView {
    var onOpenTasks: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let openTasksButton = HelmButton(title: "Open Tasks", variant: .primary, size: .small)
    private let settingsButton = HelmButton(title: "Settings", variant: .quiet, size: .small)

    init(showsSettings: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        openTasksButton.target = self
        openTasksButton.action = #selector(openTasksTapped)
        openTasksButton.toolTip = "Open the Tasks page"
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "Menu bar settings"
        settingsButton.isHidden = !showsSettings

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        let row = NSStackView(views: [openTasksButton, spacer, settingsButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        for fixed in [openTasksButton, settingsButton] {
            fixed.translatesAutoresizingMaskIntoConstraints = false
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func openTasksTapped() { onOpenTasks?() }
    @objc private func settingsTapped() { onOpenSettings?() }

    #if FM_SELFTESTS
    var debugOpenTasksButton: HelmButton { openTasksButton }
    var debugSettingsButton: HelmButton { settingsButton }
    #endif
}
