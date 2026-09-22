// Manjesh Grand Line - native macOS app.
//
// F20's card. `DailyReviewData.swift` owns what it says; this file owns how it
// looks, the same split `MorningBriefingData`/`MorningBriefingCard` already
// use - and for the same reason: every number and every sentence is decided by
// a composer a suite can drive with no window at all, so what is left here is
// only rendering.
//
// ## The mockup, and the two deviations from it
//
// The published mockup (F20 in the "Grand Line Futures" artifact) is a
// full-width card on Overview with a header sentence, three columns - due +
// follow-ups, calendar + habits, board + reading + "Not available" - and a
// footer carrying one primary action and the locality note. That shape is
// reproduced here, on the app's real components.
//
// Two deliberate differences:
//
//   1. **The header's title is the sentence, and the date is the subtitle.**
//      The mockup draws the date above the sentence. `HelmCard`'s structured
//      header is title-then-subtitle and owns both fonts, and a page must not
//      reach in and restyle them (the component index's own rule for
//      `HelmButton` applies to this card the same way). The sentence is the
//      thing being read, so it takes the title slot.
//   2. **No "Start on the TLS renewal" button when nothing is due.** The
//      mockup's primary action names a specific task; with nothing due there
//      is no task to name, so the footer keeps only "Plan the day in Tasks"
//      rather than showing a disabled button that says nothing.
//
// ## Rebuild-on-render, and why `applyTheme` re-renders
//
// The columns are rebuilt wholesale from the digest on every `render`, which
// is cheap (a few dozen labels, a handful of times a day) and removes a whole
// class of bug where a section that became unavailable keeps its old rows.
// `applyTheme` therefore re-renders from the **cached digest** rather than
// walking the tree re-colouring labels. That is still GL-24-compliant: it
// repaints from state already in hand and fetches nothing.
//
// ## Layout notes that matter if this is edited
//
//   - The three columns are tied equal-width at `HelmDaylightPriority.
//     contentTie` (499), never higher: AGENTS.md's gotcha (13) is that any
//     content constraint above 500 can resize the whole window, and a card
//     that spans the page is exactly the shape that does it.
//   - Every label in a column is `.defaultLow` compression resistance and
//     truncates, so a long task title yields instead of pushing the card
//     wider (gotcha (5)), and the column stacks use the **stack**-level
//     hugging/clipping APIs rather than the content ones, which are no-ops on
//     a view with no intrinsic size (gotcha (12)).
//   - The two column dividers are pinned top *and* bottom to the row so they
//     span the tallest column. Measured while confirming the suite catches a
//     real regression: a horizontal `NSStackView` does in fact stretch an
//     arranged subview with no intrinsic height to the row, so the pins are
//     belt-and-braces rather than load-bearing - they are kept because that
//     stretching is undocumented behaviour the layout should not depend on,
//     and `DailyReviewViewSelfTest` fails by name if a divider ever resolves
//     to a hairline (confirmed by injecting a `height == 1` on one of them).

import AppKit

final class DailyReviewCard: NSView {

    /// The X - hides the card for the rest of the day.
    var onDismiss: (() -> Void)?
    /// The header's gear - opens Settings, where the card can be turned off.
    var onOpenSettings: (() -> Void)?
    /// "Plan the day in Tasks".
    var onPlanDay: (() -> Void)?
    /// "Start on <task>" - carries the task id the digest chose.
    var onStartTask: ((String) -> Void)?
    /// "Show today's calendar" - the only thing in this app that asks for
    /// calendar access, and only ever from a real click.
    var onConnectCalendar: (() -> Void)?

    private let card = HelmCard()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let kickerLabel = NSTextField(labelWithString: "")
    private let settingsButton: HelmButton
    private let dismissButton: HelmButton

    private let columnsRow = NSStackView()
    private let dueColumn = NSStackView()
    private let middleColumn = NSStackView()
    private let boardColumn = NSStackView()
    private let firstDivider = NSView()
    private let secondDivider = NSView()
    private let footerDivider = NSView()

    private let startButton = HelmButton(title: "Start on it", variant: .primary, symbol: "play.fill")
    private let planButton = HelmButton(title: "Plan the day in Tasks", variant: .secondary,
                                        symbol: "checklist")
    private let calendarButton = HelmButton(title: "Show today\u{2019}s calendar", variant: .quiet,
                                            symbol: "calendar")
    private let footnote = NSTextField(labelWithString: "")

    private var theme: HelmTheme = ThemeManager.shared.theme
    /// The last rendered digest - what `applyTheme` repaints from.
    private var digest: DailyReviewDigest?
    /// Whether the calendar column's gap is one the captain can act on (the
    /// "not connected yet" state) rather than one they cannot (denied,
    /// restricted, an unbundled build).
    private var calendarIsConnectable = false

    /// The surface a column's text actually lands on, for the contrast
    /// correction - this is a `HelmCard`, so it is the chrome surface.
    private var surface: NSColor { HelmTheme.nsColor(theme.chromeBackgroundHex) }

    override init(frame frameRect: NSRect) {
        settingsButton = HelmPageToolbar.iconButton(symbol: "gearshape",
                                                    tooltip: "Daily review settings",
                                                    target: nil, action: nil)
        dismissButton = HelmPageToolbar.iconButton(symbol: "xmark",
                                                   tooltip: "Dismiss until tomorrow",
                                                   target: nil, action: nil)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Building the static chrome

    private func build() {
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        startButton.target = self
        startButton.action = #selector(startClicked)
        planButton.target = self
        planButton.action = #selector(planClicked)
        calendarButton.target = self
        calendarButton.action = #selector(connectCalendarClicked)

        card.setHeader(symbol: "sun.max", tint: .accent,
                       titleLabel: headlineLabel, subtitleLabel: kickerLabel,
                       actions: [settingsButton, dismissButton])

        let dueContainer = wrap(dueColumn)
        let middleContainer = wrap(middleColumn)
        let boardContainer = wrap(boardColumn)

        for divider in [firstDivider, secondDivider, footerDivider] {
            divider.wantsLayer = true
            divider.translatesAutoresizingMaskIntoConstraints = false
        }

        columnsRow.orientation = .horizontal
        columnsRow.alignment = .top
        columnsRow.spacing = 0
        // gotcha (10): the default `.gravityAreas` honours no priority at all,
        // so the columns would be laid out at their natural widths and the
        // slack resolved by Auto Layout's own tie-breaking.
        columnsRow.distribution = .fill
        columnsRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [dueContainer, firstDivider, middleContainer, secondDivider, boardContainer] {
            columnsRow.addArrangedSubview(view)
        }

        footnote.font = HelmType.caption()
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnote.lineBreakMode = .byTruncatingTail
        footnote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12): a bare `NSView` has no intrinsic size, so a hugging
        // priority on it is a no-op - a spacer that must be able to collapse
        // needs a real low-priority `width == 0`.
        let collapse = footerSpacer.widthAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        collapse.isActive = true

        let footerRow = NSStackView(views: [startButton, planButton, footerSpacer, footnote])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = HelmMetrics.s2
        footerRow.distribution = .fill
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        for control in [startButton, planButton] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let footerContainer = NSView()
        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(footerRow)
        NSLayoutConstraint.activate([
            footerRow.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: HelmMetrics.s4),
            footerRow.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -HelmMetrics.s4),
            footerRow.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: HelmMetrics.s3 - 2),
            footerRow.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -(HelmMetrics.s3 - 2)),
        ])

        let body = NSStackView(views: [columnsRow, footerDivider, footerContainer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        // A flush body: each part carries its own padding, so the two
        // dividers are full-bleed the way the mockup draws them.
        card.setBody(body)

        addSubview(card)

        let equalMiddle = middleContainer.widthAnchor.constraint(equalTo: dueContainer.widthAnchor)
        let equalBoard = boardContainer.widthAnchor.constraint(equalTo: dueContainer.widthAnchor)
        // gotcha (13): 499, below `NSLayoutPriorityWindowSizeStayPut`. These
        // are equalities between siblings, so they cannot themselves be a
        // floor - but the card spans the page, and this is the one place a
        // future edit could quietly make it one.
        equalMiddle.priority = HelmDaylightPriority.contentTie
        equalBoard.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            columnsRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            footerDivider.widthAnchor.constraint(equalTo: body.widthAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerContainer.widthAnchor.constraint(equalTo: body.widthAnchor),

            firstDivider.widthAnchor.constraint(equalToConstant: 1),
            secondDivider.widthAnchor.constraint(equalToConstant: 1),
            // `.top` alignment pins only the top; without these the dividers
            // resolve to zero height and the columns run together.
            firstDivider.topAnchor.constraint(equalTo: columnsRow.topAnchor),
            firstDivider.bottomAnchor.constraint(equalTo: columnsRow.bottomAnchor),
            secondDivider.topAnchor.constraint(equalTo: columnsRow.topAnchor),
            secondDivider.bottomAnchor.constraint(equalTo: columnsRow.bottomAnchor),

            equalMiddle, equalBoard,
        ])

        applyTheme(theme)
    }

    /// One column: a vertical stack inside a padded container, with the
    /// stack-level priorities gotcha (12) requires.
    private func wrap(_ column: NSStackView) -> NSView {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1 + 1
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        column.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: HelmMetrics.s4),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.s4),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s3),
            column.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -HelmMetrics.s3),
        ])
        return container
    }

    // MARK: Rendering

    func render(_ digest: DailyReviewDigest, theme: HelmTheme) {
        self.digest = digest
        self.theme = theme
        rebuild()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        paintChrome()
        // The five `HelmButton`s are deliberately *not* touched here: a
        // `HelmButton` registers its own `ThemeManager` observer and restyles
        // itself, and the component index's rule is that a page never reaches
        // into one.
        // The columns are rebuilt rather than re-tinted - see the file header.
        if digest != nil { rebuild() }
    }

    /// The card's own chrome - everything that is not a column row. Called
    /// from both `applyTheme` and `rebuild`, because either can be the one
    /// that runs last.
    private func paintChrome() {
        card.applyTheme(theme)
        let hair = Self.hairColor(theme)
        for divider in [firstDivider, secondDivider, footerDivider] {
            divider.layer?.backgroundColor = hair.cgColor
        }
        footnote.textColor = HelmTheme.mutedInk(theme)
    }

    private func rebuild() {
        guard let digest else { return }
        headlineLabel.stringValue = digest.headline
        kickerLabel.stringValue = digest.kicker
        footnote.stringValue = "Generated locally \u{00B7} no data left this Mac"

        for column in [dueColumn, middleColumn, boardColumn] {
            for view in column.arrangedSubviews {
                column.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }

        buildDueColumn(digest)
        buildMiddleColumn(digest)
        buildBoardColumn(digest)

        if let title = digest.primaryTaskTitle {
            startButton.title = "Start on \u{201C}\(Self.shorten(title))\u{201D}"
            startButton.isHidden = false
        } else {
            startButton.isHidden = true
        }
        // Every child was rebuilt, so re-apply the card's own chrome colours.
        paintChrome()
        needsLayout = true
    }

    // MARK: The three columns

    private func buildDueColumn(_ digest: DailyReviewDigest) {
        let tasksUnavailable = digest.gaps.contains(where: { $0.section == "Tasks" })
        dueColumn.addArrangedSubview(sectionHead(tasksUnavailable
            ? "Due today"
            : "Due today \u{00B7} \(digest.dueTasks.count + digest.hiddenDueTaskCount)"))
        if tasksUnavailable {
            dueColumn.addArrangedSubview(unavailableLine())
        } else if digest.dueTasks.isEmpty {
            dueColumn.addArrangedSubview(quietLine("Nothing is due today."))
        } else {
            for task in digest.dueTasks { dueColumn.addArrangedSubview(taskRow(task)) }
            if digest.hiddenDueTaskCount > 0 {
                dueColumn.addArrangedSubview(quietLine("+\(digest.hiddenDueTaskCount) more in Tasks"))
            }
        }

        let followUpsUnavailable = digest.gaps.contains(where: { $0.section == "Follow-ups" })
        let followUpTotal = digest.followUps.count + digest.hiddenFollowUpCount
        dueColumn.addArrangedSubview(sectionHead(followUpsUnavailable
            ? "Follow-ups"
            : "Follow-ups \u{00B7} \(followUpTotal) pending"))
        if followUpsUnavailable {
            dueColumn.addArrangedSubview(unavailableLine())
        } else if digest.followUps.isEmpty {
            dueColumn.addArrangedSubview(quietLine("None waiting on you."))
        } else {
            for item in digest.followUps {
                dueColumn.addArrangedSubview(detailLine(item.title,
                                                        detail: item.whenText,
                                                        isAlarming: item.isOverdue))
            }
            if digest.hiddenFollowUpCount > 0 {
                dueColumn.addArrangedSubview(quietLine("+\(digest.hiddenFollowUpCount) more in Tasks"))
            }
        }
    }

    private func buildMiddleColumn(_ digest: DailyReviewDigest) {
        middleColumn.addArrangedSubview(sectionHead("Calendar \u{00B7} read-only"))
        if digest.gaps.contains(where: { $0.section == "Calendar" }) {
            middleColumn.addArrangedSubview(unavailableLine())
        } else if digest.events.isEmpty {
            middleColumn.addArrangedSubview(quietLine("Nothing on your calendar today."))
        } else {
            for event in digest.events { middleColumn.addArrangedSubview(eventRow(event)) }
            if digest.hiddenEventCount > 0 {
                middleColumn.addArrangedSubview(quietLine("+\(digest.hiddenEventCount) more today"))
            }
        }

        middleColumn.addArrangedSubview(sectionHead("Habits"))
        if digest.gaps.contains(where: { $0.section == "Habits" }) {
            middleColumn.addArrangedSubview(unavailableLine())
        } else if digest.habits.isEmpty {
            middleColumn.addArrangedSubview(quietLine("No habits tracked yet."))
        } else {
            middleColumn.addArrangedSubview(habitChips(digest.habits))
        }
    }

    private func buildBoardColumn(_ digest: DailyReviewDigest) {
        boardColumn.addArrangedSubview(sectionHead("On your board"))
        if digest.gaps.contains(where: { $0.section == "Sticky board" }) {
            boardColumn.addArrangedSubview(unavailableLine())
        } else if digest.stickies.isEmpty {
            boardColumn.addArrangedSubview(quietLine("Your board is clear."))
        } else {
            for sticky in digest.stickies {
                boardColumn.addArrangedSubview(detailLine(sticky.title, detail: sticky.detail,
                                                          isAlarming: false))
            }
        }

        boardColumn.addArrangedSubview(sectionHead("Reading list"))
        if digest.gaps.contains(where: { $0.section == "Reading list" }) {
            boardColumn.addArrangedSubview(unavailableLine())
        } else if let reading = digest.reading {
            if reading.unreadCount == 0 {
                boardColumn.addArrangedSubview(quietLine("Nothing unread."))
            } else {
                let summary = reading.oldestText.isEmpty
                    ? "\(reading.unreadCount) unread"
                    : "\(reading.unreadCount) unread \u{00B7} \(reading.oldestText)"
                boardColumn.addArrangedSubview(bodyLine(summary))
                if let title = reading.topTitle {
                    boardColumn.addArrangedSubview(quietLine(title))
                }
            }
        }

        // GL-14's block, and the mockup's own closing note: a section that
        // could not be read says so *once*, here, with the reason in full.
        // Its own column carries a one-word "not available" so the column
        // structure never changes shape - the reason lives in exactly one
        // place rather than being repeated in two.
        guard !digest.gaps.isEmpty else { return }
        boardColumn.addArrangedSubview(sectionHead("Not available"))
        for gap in digest.gaps {
            boardColumn.addArrangedSubview(gapRow(gap, naming: true))
            // The one actionable gap. Offered only when asking is possible,
            // so a denied grant never shows a button that cannot change
            // anything, and an unbundled build never shows one that would be
            // refused (see `EventKitDailyReviewCalendar.canPrompt`).
            if gap.section == "Calendar", calendarIsConnectable {
                boardColumn.addArrangedSubview(calendarButton)
            }
        }
    }

    // MARK: Row builders

    private func sectionHead(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = HelmType.kicker()
        label.textColor = HelmTheme.mutedInk(theme)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A little air above a heading that is not the column's first.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    private func taskRow(_ task: DailyReviewTaskRow) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer?.cornerRadius = 4
        box.layer?.borderWidth = 1.6
        box.layer?.borderColor = task.isOverdue
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: surface, theme: theme).cgColor
            : Self.hairColor(theme).withAlphaComponent(0.9).cgColor
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 14),
            box.heightAnchor.constraint(equalToConstant: 14),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: task.title)
        title.font = HelmType.rowTitle()
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let meta = NSTextField(labelWithString: task.overdueText ?? task.meta)
        meta.font = HelmType.captionSmall()
        meta.textColor = task.isOverdue
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: surface, theme: theme)
            : HelmTheme.mutedInk(theme)
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [box, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // The box is 14pt tall and the title's first line is taller; nudge the
        // box down so it reads as aligned with the text rather than with the
        // line box.
        box.topAnchor.constraint(equalTo: row.topAnchor, constant: 2).isActive = true
        return row
    }

    private func eventRow(_ event: DailyReviewEventRow) -> NSView {
        let time = NSTextField(labelWithString: event.timeText)
        time.font = HelmType.code()
        time.textColor = HelmTheme.mutedInk(theme)
        time.translatesAutoresizingMaskIntoConstraints = false
        time.lineBreakMode = .byTruncatingTail
        time.widthAnchor.constraint(equalToConstant: 48).isActive = true
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = NSView()
        bar.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        // The calendar's own colour when it has one - corrected against this
        // card's surface, because a calendar colour is chosen in Calendar.app
        // against a white sheet and can be invisible on a dark card.
        let hex = event.colorHex ?? HelmTint.violet.hex(in: theme)
        bar.layer?.backgroundColor = HelmContrast.legibleTintedText(tintHex: hex,
                                                                    over: surface,
                                                                    theme: theme).cgColor
        bar.layer?.cornerRadius = 1
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 2),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])
        bar.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: event.title)
        title.font = HelmType.rowTitle()
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var textViews: [NSView] = [title]
        if !event.detail.isEmpty {
            let detail = NSTextField(labelWithString: event.detail)
            detail.font = HelmType.captionSmall()
            detail.textColor = HelmTheme.mutedInk(theme)
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textViews.append(detail)
        }
        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [time, bar, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 1).isActive = true
        bar.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor).isActive = true
        return row
    }

    private func habitChips(_ habits: [DailyReviewHabitRow]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s1 + 2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        for habit in habits {
            let chip = NSView()
            let label = NSTextField(labelWithString: "")
            let text = habit.streak.map { "\(habit.title) \u{00B7} \($0)" } ?? habit.title
            // The app's one chip recipe, contrast-corrected for this theme -
            // never a hand-rolled tinted pill (the component index's rule).
            ToolRowLayout.pill(text: text,
                               colorHex: (habit.doneToday ? HelmTint.good : HelmTint.neutral).hex(in: theme),
                               into: chip, label: label, theme: theme)
            chip.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(chip)
        }
        return row
    }

    private func detailLine(_ title: String, detail: String, isAlarming: Bool) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = HelmType.caption()
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = HelmType.captionSmall()
        detailLabel.textColor = isAlarming
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: surface, theme: theme)
            : HelmTheme.mutedInk(theme)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func bodyLine(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.caption()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// What a section whose source could not be read shows in its own column.
    /// Deliberately not the reason: that is stated once, in the "Not
    /// available" block, and a reason repeated twice on one card is a reason
    /// that will eventually disagree with itself.
    private func unavailableLine() -> NSView {
        quietLine("not available - see below")
    }

    private func quietLine(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.captionSmall()
        label.textColor = HelmTheme.mutedInk(theme)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// GL-14's own rendering: a warn glyph, the section, and the reason in
    /// plain words. Wrapping, because a reason that truncates is a reason
    /// nobody can act on.
    private func gapRow(_ gap: DailyReviewGap, naming: Bool = false) -> NSView {
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "exclamationmark.shield",
                              accessibilityDescription: nil)
        glyph.contentTintColor = HelmContrast.legibleTintedText(tintHex: HelmTint.warn.hex(in: theme),
                                                                over: surface, theme: theme)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: naming ? "\(gap.section) - \(gap.reason)" : gap.reason)
        label.font = HelmType.captionSmall()
        label.textColor = HelmTheme.mutedInk(theme)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s1 + 2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    // MARK: Small shared bits

    /// The card's own hairline, matching `HelmCard`'s internal divider - the
    /// lighter `hairRow` under Daylight, a damped `chromeLineHex` elsewhere.
    static func hairColor(_ theme: HelmTheme) -> NSColor {
        theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.hairRow)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)
    }

    /// A button title is not a place for a 90-character task name.
    static func shorten(_ title: String, limit: Int = 32) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "\u{2026}"
    }

    /// Whether the calendar's gap is one the captain can do something about.
    /// Set by the page before `render`.
    func setCalendarConnectable(_ connectable: Bool) {
        calendarIsConnectable = connectable
    }

    // MARK: Actions

    @objc private func dismissClicked() { onDismiss?() }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func planClicked() { onPlanDay?() }
    @objc private func connectCalendarClicked() { onConnectCalendar?() }
    @objc private func startClicked() {
        guard let id = digest?.primaryTaskID else { return }
        onStartTask?(id)
    }

    // MARK: Probe / self-test surface
    //
    // GL-27: debug builds only, like every other `debug*` hook in this app.

    #if FM_SELFTESTS
    var debugHeadline: String { headlineLabel.stringValue }
    var debugKicker: String { kickerLabel.stringValue }
    var debugStartButtonVisible: Bool { !startButton.isHidden }
    var debugStartButtonTitle: String { startButton.title }
    var debugCalendarButtonMounted: Bool { calendarButton.superview != nil }
    var debugColumns: [NSStackView] { [dueColumn, middleColumn, boardColumn] }
    /// The two vertical rules between the columns - the ones whose *height*
    /// is the interesting question.
    var debugColumnDividers: [NSView] { [firstDivider, secondDivider] }
    /// The horizontal rule above the footer, whose *width* is.
    var debugFooterDivider: NSView { footerDivider }

    /// Every string any column is currently painting, top to bottom - which is
    /// what lets a suite assert that a section really says what the digest
    /// decided rather than that the digest was merely computed.
    func debugText(inColumn index: Int) -> [String] {
        guard debugColumns.indices.contains(index) else { return [] }
        return Self.collectText(debugColumns[index])
    }

    static func collectText(_ view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            out.append(field.stringValue)
        }
        for subview in view.subviews { out.append(contentsOf: collectText(subview)) }
        return out
    }

    func debugPressDismiss() { dismissClicked() }
    func debugPressStart() { startClicked() }
    func debugPressPlanDay() { planClicked() }
    func debugPressConnectCalendar() { connectCalendarClicked() }
    #endif
}
