// Grand Line - native macOS app.
//
// F11's "Schedules" list, redesigned in `fm/grand-line-schedules-page-redesign`
// against two captain-supplied references (a standalone HTML mockup at
// `data/grand-line-schedules-page-redesign/reference-design.html`, plus a
// screenshot of a denser status-grouped variant).
//
// **The references are design references, not a data model to port.** Both
// carry fabricated demo content - a fictional "Daily workspace report"
// schedule, a hardcoded 24-run chart, an invented activity feed. Everything
// rendered here comes from the real `ScheduleStore` and the real
// `ScheduleRunHistoryStore`; where a reference idea had no real data behind it
// the idea was adapted or scoped out rather than filled with placeholders. See
// `SchedulesInsights.swift`'s header for the two honesty caveats that shaped
// the sparkline, and `ScheduledActionKind.reviewDestination` for why the
// "Review 2 changes" button lost its count.
//
// **What the redesign changed, and the two structural decisions behind it:**
//
//  1. **Grouped by status, not a flat list with a filter dropdown.** The brief
//     offered either (reference 1 filters a flat list; reference 2 groups into
//     "NEEDS YOU" / "RUNNING CLEAN" sections) and asked for one, consistently.
//     Grouping won because the groups *are* the filter: with a schedule list
//     bounded by `ScheduledActionKind.allCases` times a handful of cadences -
//     realistically under ten rows - a dropdown asks the captain to perform an
//     interaction to reveal something a section header already states, and a
//     needs-you row ends up sorted to the top either way. The dropdown is
//     therefore deliberately absent; the search field is not, because it
//     narrows rather than re-states and keeps earning its place as the action
//     set grows.
//
//  2. **No in-page hero title.** Reference 1 opens with an eyebrow, a 28pt
//     "Schedules" and a subtitle. This app's shell already renders exactly
//     that: `HelmDrillHeader` carries the destination name plus
//     `SchedulesController.drillHeaderSubtitle`'s live counts, and Daylight
//     §6.4's "a page never repeats its own destination name" has been a
//     correction applied to Review, Docs and Health in turn. So the reference's
//     page header maps onto the drill header rather than being rebuilt beneath
//     it, and the stat tiles carry the summary the eyebrow row would have.
//
// **A plain view class rather than an extension on the controller**, and
// **rows are `HelmAccentRow`, and the list is a plain `NSStackView`** - all
// three for the reasons this file has always carried: a Swift extension cannot
// hold stored properties, a schedule reads as a record rather than a
// fixed-column checklist item (`ToolRowLayout`'s own distinction), and the list
// is bounded well under the row count that makes a demand-driven table
// necessary (`ShiftListViews.swift`'s measured blowup).

import AppKit

final class SchedulesCardView: NSObject {

    /// The card to drop into the page's stack.
    let card = HelmCard()

    // MARK: Callbacks - the view decides nothing

    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((AutomationSchedule) -> Void)?
    var onDeleteSchedule: ((AutomationSchedule) -> Void)?
    var onRunNow: ((AutomationSchedule) -> Void)?
    var onToggleEnabled: ((AutomationSchedule, Bool) -> Void)?
    /// "View History...", the browsable last-7-days list behind the "..."
    /// menu - see `ScheduleHistoryController`.
    var onViewHistory: ((AutomationSchedule) -> Void)?
    /// The row's "Review" hand-off and the overflow's "Open ..." item - see
    /// `ScheduledActionKind.reviewDestination`. The card names a destination;
    /// the shell decides what showing one means.
    var onOpenDestination: ((RailDestination) -> Void)?

    // MARK: State

    private var schedules: [AutomationSchedule] = []
    private var history: [ScheduleRunHistoryEntry] = []
    private var runningScheduleID: UUID?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var searchQuery: String = ""
    /// Which sidebar collection is showing. `.all` is the no-filter state, so
    /// a page that never sets one behaves exactly as this card always did.
    private var statusFilter: StatusFilter = .all

    private let rowsStack = NSStackView()
    private let countBadge = NSTextField(labelWithString: "")
    private let searchField = HelmSearchField(placeholder: "Search schedules\u{2026}")
    /// "+ New Schedule", owned here and *positioned* by whoever hosts the card
    /// - Daylight §6.4 hoists it into the drill header, the same
    /// caller-owned-action arrangement `HealthCardView.diagnosticsButton`
    /// already uses. Still this view's button with this view's handler.
    let addButton = HelmButton(title: "+ New Schedule", variant: .secondary)

    /// Fired whenever the rendered set of schedules changes, so a host page's
    /// own live header line can follow the same signal the rows do rather than
    /// polling.
    var onStateChanged: (() -> Void)?

    /// The search field's width. Fixed rather than flexible because
    /// `HelmCard.setHeader` gives every action view `.required` compression
    /// resistance (so the title truncates first, not the controls) - a
    /// flexible field there would simply never shrink anyway.
    private static let searchWidth: CGFloat = 190

    override init() {
        super.init()
        buildCard()
    }

    private func buildCard() {
        countBadge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(newScheduleClicked)
        addButton.toolTip = "Schedule one of the app's existing actions to run on its own"

        // Below `NSLayoutPriorityWindowSizeStayPut` (AGENTS.md gotcha (13)):
        // this chain reaches `AppShellController.bodyContainer`, so a *required*
        // fixed width here is a floor on how narrow the whole window may get.
        // It still beats the header title's own 250 hugging, so at any real
        // width the field is exactly `searchWidth` and the title is what
        // truncates - which is the behaviour `HelmCard.setHeader` documents.
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: Self.searchWidth)
        searchWidth.priority = HelmDaylightPriority.contentTie
        searchWidth.isActive = true
        searchField.onTextChanged = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != self.searchQuery else { return }
            self.searchQuery = trimmed
            self.rebuild()
            // The sidebar's counts are "how many match *under the current
            // search*", so typing has to move them - the same contract
            // `CredentialVaultSidebar.setCounts` already carries.
            self.onStateChanged?()
        }

        card.setHeader(
            symbol: "calendar",
            tint: .info,
            title: "Schedules",
            // Both halves are literally true and both are worth stating: a run
            // is always recorded (Health), and a run only ever interrupts you
            // when its own notify setting says so.
            subtitle: "Runs log to Health \u{00B7} notify only when something needs you",
            // §6.4 hoists the add action into the drill header, so the card
            // header keeps the count, the explanatory subtitle and the search.
            // The button instance itself is unchanged and is still this view's.
            actions: [searchField, countBadge]
        )

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(rowsStack, insets: HelmCard.contentInsets)
    }

    // MARK: Rendering

    /// The one render path. Rows carry theme-derived colours and are rebuilt
    /// from scratch here (the list is under ten rows - see the file header),
    /// so a theme change and a data change are the same operation and there is
    /// no second path that could paint a row with a stale palette.
    ///
    /// - Parameter history: every recorded run across every schedule, newest
    ///   first. Read **once, by the controller**, and handed down rather than
    ///   fetched per row: `ScheduleRunHistoryStore` is a file-backed singleton,
    ///   and a per-row read would turn one render into one store hit per
    ///   schedule. It also keeps this view decision-free and drivable from a
    ///   self-test with no store at all.
    func setSchedules(_ schedules: [AutomationSchedule],
                      runningID: UUID?,
                      history: [ScheduleRunHistoryEntry] = [],
                      theme: HelmTheme) {
        self.schedules = schedules
        self.history = history
        self.runningScheduleID = runningID
        self.theme = theme
        card.applyTheme(theme)
        rebuild()
        onStateChanged?()
    }

    // MARK: Grouping and filtering

    /// The three groups, in the order a captain reads them: what wants them
    /// first, what is looking after itself, and what they switched off.
    enum Group: CaseIterable {
        case needsYou
        case healthy
        case paused

        var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .healthy: return "Running on their own"
            case .paused: return "Paused"
            }
        }

        /// The section dot, and the hue the group's rows already carry.
        var tint: HelmTint {
            switch self {
            case .needsYou: return .warn
            case .healthy: return .good
            case .paused: return .neutral
            }
        }
    }

    /// The sidebar's WORKSPACE collections. Deliberately *not* the same type
    /// as `Group`: a group is how the list is sectioned (three sections, always
    /// all three when non-empty), a filter is which schedules are on the page
    /// at all, and `.active` deliberately spans two groups (a needs-you row is
    /// still an active schedule). Collapsing them into one enum would make
    /// "Active" mean "healthy", which is a different and wrong claim.
    enum StatusFilter: String, CaseIterable {
        case all
        case needsYou
        case active
        case paused

        /// The sidebar row's own label.
        var title: String {
            switch self {
            case .all: return "All Schedules"
            case .needsYou: return "Needs You"
            case .active: return "Active"
            case .paused: return "Paused"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2.fill"
            case .needsYou: return "exclamationmark.circle.fill"
            case .active: return "bolt.horizontal.circle.fill"
            case .paused: return "pause.circle.fill"
            }
        }

        func accepts(_ schedule: AutomationSchedule) -> Bool {
            switch self {
            case .all: return true
            case .needsYou: return SchedulesCardView.group(for: schedule) == .needsYou
            case .active: return schedule.isEnabled
            case .paused: return !schedule.isEnabled
            }
        }
    }

    /// Each collection's count, computed against the *current* search - so the
    /// sidebar says where the matches are rather than only what exists, which
    /// is the same contract `CredentialVaultSidebar.setCounts` already has.
    ///
    /// Counted off the very array the rows render, so a count and its list can
    /// never disagree within a frame.
    static func filterCounts(_ schedules: [AutomationSchedule], query: String) -> [StatusFilter: Int] {
        let searched = schedules.filter { matches($0, query: query) }
        var counts: [StatusFilter: Int] = [:]
        for filter in StatusFilter.allCases {
            counts[filter] = searched.filter { filter.accepts($0) }.count
        }
        return counts
    }

    /// Set by the page's sidebar. Re-renders only on a real change, so a
    /// caller restoring state costs nothing.
    func setStatusFilter(_ filter: StatusFilter) {
        guard filter != statusFilter else { return }
        statusFilter = filter
        rebuild()
    }

    var currentSearchQuery: String { searchQuery }

    /// A schedule's group. A never-run schedule counts as healthy rather than
    /// as needing you: it has not asked for anything, and putting it under
    /// "Needs you" would be a claim about a run that has not happened.
    static func group(for schedule: AutomationSchedule) -> Group {
        guard schedule.isEnabled else { return .paused }
        switch schedule.lastRun?.verdict {
        case .changed, .failed: return .needsYou
        case .clean, nil: return .healthy
        }
    }

    /// Search over everything the row actually shows - the action name, the
    /// cadence, the notify setting and the last run's own sentence - so a
    /// captain can find a schedule by the words in front of them rather than
    /// having to guess the title.
    static func matches(_ schedule: AutomationSchedule, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [
            schedule.action.title,
            schedule.action.pickerTitle,
            schedule.cadence.displayString,
            schedule.notifyOn.displayString(for: schedule.action),
            schedule.lastRun?.summary ?? "",
            group(for: schedule).title,
        ].joined(separator: " ")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func rebuild() {
        for v in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        #if FM_SELFTESTS
        debugColumns.removeAll()
        debugSparklines.removeAll()
        #endif
        countBadge.stringValue = schedules.isEmpty ? "" : "\(schedules.count)"
        countBadge.textColor = HelmTheme.mutedInk(theme)

        guard !schedules.isEmpty else {
            addFullWidth(HelmEmptyState(
                symbol: "calendar.badge.plus",
                body: "No schedules yet. Pick one of the app's existing actions and a cadence, "
                    + "and it will run on its own \u{2014} reporting to Health, and telling you only when it matters."
            ))
            return
        }

        let visible = schedules.filter {
            Self.matches($0, query: searchQuery) && statusFilter.accepts($0)
        }
        guard !visible.isEmpty else {
            // Say which of the two narrowings actually emptied the list. A
            // "no match for ..." sentence on a page emptied by the *filter*
            // would point the captain at a search box that is doing nothing.
            if searchQuery.isEmpty {
                addFullWidth(HelmEmptyState(
                    symbol: statusFilter.symbol,
                    body: "No schedule is \u{201C}\(statusFilter.title)\u{201D} right now. "
                        + "Pick \u{201C}All Schedules\u{201D} to see every one."
                ))
            } else {
                addFullWidth(HelmEmptyState(
                    symbol: "magnifyingglass",
                    body: "No schedule matches \u{201C}\(searchQuery)\u{201D}"
                        + (statusFilter == .all ? ". " : " under \u{201C}\(statusFilter.title)\u{201D}. ")
                        + "Search covers the action name, the cadence, the notify setting and the last run."
                ))
            }
            return
        }

        // Both shared slot widths are computed across the whole visible set,
        // once, before any row is built - see `ScheduleRunSparkline`'s header
        // for why a per-row width would break the time column.
        let slots = min(ScheduleRunSparkline.maxBars,
                        visible.map { runCount(for: $0) }.max() ?? 0)
        let needsReviewSlot = visible.contains { reviewLabel(for: $0) != nil }

        let now = Date()
        for group in Group.allCases {
            let rows = visible.filter { Self.group(for: $0) == group }
            guard !rows.isEmpty else { continue }
            addFullWidth(sectionHeader(group, count: rows.count))
            for schedule in rows {
                addFullWidth(buildRow(schedule, now: now, slots: slots, reviewSlot: needsReviewSlot))
            }
        }
    }

    private func addFullWidth(_ view: NSView) {
        rowsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    /// How many real runs this schedule has on record. `lastRun` counts as one
    /// when the store has nothing - see `ScheduleRunSparkline.setRuns`'s
    /// `fallback` parameter for why that is a real run rather than a stand-in.
    private func runCount(for schedule: AutomationSchedule) -> Int {
        let recorded = history.filter { $0.scheduleID == schedule.id }.count
        if recorded > 0 { return min(ScheduleRunSparkline.maxBars, recorded) }
        return schedule.lastRun == nil ? 0 : 1
    }

    // MARK: Section headers

    /// A tinted dot, the group's name, and its count - reference 2's own
    /// "● NEEDS YOU" shape, in this app's kicker voice.
    private func sectionHeader(_ group: Group, count: Int) -> NSView {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.layer?.backgroundColor = HelmTheme.nsColor(group.tint.hex(in: theme)).cgColor
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
        ])

        let label = NSTextField(labelWithString: "")
        // The kicker voice - uppercase, kern'd, `mutedInk`. Never the group's
        // own hue as text: `HelmContrast`'s §5.7 rule is that a tint is safe as
        // a fill (the dot) and not automatically as a label.
        label.attributedStringValue = NSAttributedString(
            string: group.title.uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        label.lineBreakMode = .byTruncatingTail
        // The one view in this row allowed to flex. A bare `NSView()` spacer
        // would be the obvious way to push the count right, and is the wrong
        // one here: a view with no intrinsic content size ignores a hugging
        // priority outright (AGENTS.md gotcha (12)), so which view absorbs the
        // slack would come down to the solver's own tie-break. A label has an
        // intrinsic width, so lowering *its* hugging is a real instruction.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = HelmType.code()
        countLabel.textColor = HelmTheme.mutedInk(theme)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, label, countLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (10): `.gravityAreas` honours no hugging priority,
        // so the count would drift with the label instead of pinning right.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 0, right: 2)
        return row
    }

    private static let dotSide: CGFloat = 7

    // MARK: Rows

    private func buildRow(_ schedule: AutomationSchedule,
                          now: Date,
                          slots: Int,
                          reviewSlot: Bool) -> NSView {
        let isRunning = schedule.id == runningScheduleID

        // The toggle. B7 (`data/grand-line-e2e-audit/report.md`): `HelmToggle`,
        // the app's own toggle, not a raw `NSSwitch` - which genuinely cannot
        // be tinted (Phase 2 measured it answering `false` to every tint setter
        // tried) and would show system-accent chrome next to otherwise fully
        // themed rows.
        let toggle = HelmToggle()
        toggle.isOn = schedule.isEnabled
        toggle.applyTheme(theme)
        toggle.onToggle = { [weak self] in self?.toggleChanged(toggle) }
        toggle.identifier = NSUserInterfaceItemIdentifier("schedule-toggle:\(schedule.id.uuidString)")
        toggle.toolTip = schedule.isEnabled ? "Pause this schedule" : "Resume this schedule"
        toggle.setAccessibilityLabel("\(schedule.action.title): \(schedule.isEnabled ? "enabled" : "paused")")

        let overflow = HelmButton(title: "", variant: .quiet, size: .small, symbol: "ellipsis")
        overflow.target = self
        overflow.action = #selector(overflowClicked(_:))
        overflow.identifier = NSUserInterfaceItemIdentifier("schedule-overflow:\(schedule.id.uuidString)")
        overflow.toolTip = "More actions"

        // §7's "mono time column". It lives in the row's own trailing cluster,
        // which `HelmAccentRow` right-pins - which is what makes the time
        // genuinely read as a *column* (one constant x across every row) rather
        // than as a label that drifts with the title beside it.
        let timeColumn = timeColumnLabel(schedule)
        let sparkline = ScheduleRunSparkline()
        sparkline.setRuns(history.filter { $0.scheduleID == schedule.id },
                          fallback: schedule.lastRun,
                          slots: slots,
                          theme: theme)
        let review = reviewSlotView(schedule, reserved: reviewSlot)
        #if FM_SELFTESTS
        debugColumns[schedule.id] = timeColumn
        debugSparklines[schedule.id] = sparkline
        #endif

        let controls: [NSView] = [review, sparkline, timeColumn, overflow, toggle]
        let actions = NSStackView(views: controls)
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (12): a content-priority call is a no-op on an
        // `NSStackView`, and `.gravityAreas` (the default) honours no hugging
        // priority at all - so without `.fill` plus stack-level hugging here
        // AND required content hugging on each control, the solver's tie-break
        // can stretch whichever of them it likes across the row.
        // `HostsListSection`'s identical `actions` stack is the reference.
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        for control in controls {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // **No `maxContentWidth` here, deliberately - this is the width half of
        // `fm/grand-line-schedules-sidebar-fullwidth-fix`.**
        //
        // The row opted into D2's `recordContentWidth` (900) when the redesign
        // landed. That cap's own doc comment reasons that "the captain's own
        // 1512pt window is essentially unaffected" - true of the pages it was
        // measured against, every one of which already has a list column near
        // 900 (Poneglyph's three-column page, Hosts' capped column). This page
        // is a *single* gutter-to-gutter column, so the same 900 left the
        // trailing cluster stranded mid-row: measured at a 1512pt window, the
        // toggle sat at x=1265 inside a row running to x=1943 - some 680pt of
        // dead space in every row, which is what the captain reported as the
        // page not using its width. That is also markedly more than the ~370pt
        // of dead gutter he had a page-level cap removed from Hosts over.
        //
        // The sidebar is what keeps the line length honest without a cap: it
        // takes `HelmPageSidebar.width` plus a column gap out of the content
        // before a row ever sees it. So the row fills the column it is given,
        // and the column is narrower than the window.
        let row = HelmAccentRow(trailingAccessory: actions, hover: false)
        row.configure(rowContent(schedule, now: now, isRunning: isRunning), theme: theme)
        if let next = ScheduleDueCalculator.nextOccurrence(of: schedule.cadence, after: now, calendar: .current),
           schedule.isEnabled {
            row.toolTip = "Next run: \(Self.tooltipFormatter.string(from: next))"
        } else if !schedule.isEnabled {
            row.toolTip = "Paused \u{2014} the toggle resumes it without losing the schedule."
        }
        return row
    }

    // MARK: The "Review" hand-off

    /// The button's label, or `nil` for a row that has nothing to review.
    ///
    /// Only a run that actually surfaced something gets one: a clean run, a
    /// never-run schedule and a paused one all have nothing to act on, and a
    /// button offering to "review" a clean result would be noise on every row.
    private func reviewLabel(for schedule: AutomationSchedule) -> String? {
        guard schedule.isEnabled,
              schedule.id != runningScheduleID,
              let last = schedule.lastRun else { return nil }
        switch last.verdict {
        case .clean: return nil
        case .changed: return "Review"
        case .failed: return "Why?"
        }
    }

    /// A fixed-width slot so the columns to its right stay columns.
    ///
    /// Reserved (empty) on rows with nothing to review whenever *any* visible
    /// row has something - the same shared-slot arrangement the sparkline uses,
    /// and for the same reason. When no row needs one the slot collapses to
    /// zero on every row at once, so an all-clean list has no dead gap.
    private func reviewSlotView(_ schedule: AutomationSchedule, reserved: Bool) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let width = slot.widthAnchor.constraint(equalToConstant: reserved ? Self.reviewSlotWidth : 0)
        // Below `NSLayoutPriorityWindowSizeStayPut` (gotcha (13)).
        width.priority = HelmDaylightPriority.contentTie
        width.isActive = true
        guard reserved, let title = reviewLabel(for: schedule), let last = schedule.lastRun else { return slot }

        let button = HelmButton(title: title, variant: .secondary, size: .small)
        button.target = self
        button.action = #selector(reviewClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier("schedule-review:\(schedule.id.uuidString)")
        // The run's own sentence, verbatim - the real detail the reference's
        // fabricated "Review 2 changes" count was standing in for.
        button.toolTip = "\(last.summary)\n\nOpens \(schedule.action.reviewDestination.title)."
        slot.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        return slot
    }

    private static let reviewSlotWidth: CGFloat = 74

    // MARK: §7's time column

    /// A fixed-width column so a `2:00 AM` and a `10:30 PM` line up down the
    /// list. Mono for the same reason Console's and Log Analyzer's timestamps
    /// are: proportional digits in a column read as ragged even when the
    /// frames are identical.
    static let timeColumnWidth: CGFloat = 62

    /// The cadence's own clock time - `ScheduleCadence.clockString`, the exact
    /// string `displayString` already puts in the meta line, not a second
    /// formatting of the same two integers.
    private func timeColumnLabel(_ schedule: AutomationSchedule) -> NSTextField {
        let cadence = schedule.cadence.normalized
        let label = NSTextField(labelWithString: ScheduleCadence.clockString(hour: cadence.hour,
                                                                            minute: cadence.minute))
        label.font = HelmType.code()
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.textColor = schedule.isEnabled
            ? HelmTheme.nsColor(theme.chromeInkHex)
            : HelmTheme.mutedInk(theme)
        label.toolTip = schedule.cadence.displayString
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.timeColumnWidth).isActive = true
        return label
    }

    /// "in 13h" - reference 2's countdown to the next run, from the same
    /// `ScheduleDueCalculator` occurrence search the runner itself uses.
    /// Deliberately not `RelativeDateTimeFormatter`, whose "in 13 hours" is
    /// longer than a chip has room for - the same call
    /// `AutomationSchedule.relativeAge` already made for the past tense.
    static func relativeUntil(_ date: Date, from now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "in \(hours)h" }
        return "in \(hours / 24)d"
    }

    /// The kicker carries the run verdict (the most glanceable signal, and the
    /// one that drives the row's hue), the meta line carries the
    /// "cadence · notify-on · last run" trio, and the chip carries the
    /// countdown to the next run.
    private func rowContent(_ schedule: AutomationSchedule, now: Date, isRunning: Bool) -> HelmAccentRow.Content {
        let kicker: String
        let tint: HelmTint
        if isRunning {
            kicker = "Running"
            tint = .accent
        } else if !schedule.isEnabled {
            kicker = "Paused"
            tint = .neutral
        } else if let last = schedule.lastRun {
            kicker = last.verdict.label
            tint = last.verdict.tint
        } else {
            kicker = "Not run yet"
            tint = schedule.action.tint
        }

        var meta = schedule.metaLine(now: now)
        if isRunning {
            meta = "\(schedule.cadence.displayString) \u{00B7} running now\u{2026}"
        } else if let last = schedule.lastRun, last.verdict != .clean {
            // A failure or a "found something" run has a reason worth reading
            // on the row itself, not two clicks away.
            meta += " \u{00B7} \(last.summary)"
        }

        // Paused gets no chip: the kicker already says so, and a countdown to
        // a run that will not happen would be a false statement.
        var chip: String?
        if isRunning {
            chip = "running"
        } else if schedule.isEnabled,
                  let next = ScheduleDueCalculator.nextOccurrence(of: schedule.cadence,
                                                                  after: now,
                                                                  calendar: .current) {
            chip = Self.relativeUntil(next, from: now)
        }

        return HelmAccentRow.Content(
            tint: tint,
            kicker: kicker,
            title: schedule.action.title,
            meta: meta,
            badgeSymbol: schedule.action.symbol,
            chipText: chip,
            // The chip is a *when*, not a *state* - it must not repeat the
            // kicker's hue and imply a second verdict.
            chipTint: .neutral,
            // Daylight §6.5's signal wash, opt-in per call site: only a row
            // that genuinely wants the captain now, never every `.warn` row.
            isSignal: Self.group(for: schedule) == .needsYou
        )
    }

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: Actions

    @objc private func newScheduleClicked() {
        onNewSchedule?()
    }

    /// B7: takes a `HelmToggle` now. `onToggle` fires only for a real user
    /// interaction (its own `isOn` setter deliberately does not re-enter the
    /// handler), which is the same contract `NSSwitch`'s target/action had.
    private func toggleChanged(_ sender: HelmToggle) {
        guard let schedule = schedule(from: sender.identifier?.rawValue, prefix: "schedule-toggle:") else { return }
        onToggleEnabled?(schedule, sender.isOn)
    }

    @objc private func reviewClicked(_ sender: NSButton) {
        guard let schedule = schedule(from: sender.identifier?.rawValue, prefix: "schedule-review:") else { return }
        onOpenDestination?(schedule.action.reviewDestination)
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        guard let schedule = schedule(from: sender.identifier?.rawValue, prefix: "schedule-overflow:") else { return }
        let menu = buildOverflowMenu(for: schedule)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    /// One array builds both the overflow menu and (were a context menu added)
    /// any other presentation of the same actions, so the two cannot drift -
    /// the same reasoning `HostsListSection` records for its own rows.
    private func buildOverflowMenu(for schedule: AutomationSchedule) -> NSMenu {
        let menu = NSMenu()
        // AppKit auto-enables a menu item whose target responds to its action,
        // which would silently undo the explicit disable on "Run Now" below.
        menu.autoenablesItems = false
        let runNow = NSMenuItem(title: "Run Now", action: #selector(runNowPicked(_:)), keyEquivalent: "").withSymbol("play.circle")
        runNow.target = self
        runNow.representedObject = schedule.id.uuidString
        // A manual run while another is in flight would break the "one at a
        // time" guarantee the runner makes, so it is disabled rather than
        // silently dropped.
        runNow.isEnabled = ScheduleRunner.shared.isBusy == false
        menu.addItem(runNow)

        let edit = NSMenuItem(title: "Edit\u{2026}", action: #selector(editPicked(_:)), keyEquivalent: "").withSymbol("pencil")
        edit.target = self
        edit.representedObject = schedule.id.uuidString
        menu.addItem(edit)

        let history = NSMenuItem(title: "View History\u{2026}", action: #selector(viewHistoryPicked(_:)), keyEquivalent: "").withSymbol("clock.arrow.circlepath")
        history.target = self
        history.representedObject = schedule.id.uuidString
        menu.addItem(history)

        // The same hand-off the row's "Review" button makes, offered on every
        // row rather than only the ones needing attention - a captain wanting
        // the page this action belongs to should not have to wait for a run to
        // go sideways to be offered it.
        let destination = schedule.action.reviewDestination
        let open = NSMenuItem(title: "Open \(destination.title)",
                              action: #selector(openDestinationPicked(_:)),
                              keyEquivalent: "").withSymbol(destination.symbol)
        open.target = self
        open.representedObject = schedule.id.uuidString
        menu.addItem(open)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete", action: #selector(deletePicked(_:)), keyEquivalent: "").withSymbol("trash")
        delete.target = self
        delete.representedObject = schedule.id.uuidString
        menu.addItem(delete)
        return menu
    }

    @objc private func runNowPicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onRunNow?(schedule)
    }

    @objc private func editPicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onEditSchedule?(schedule)
    }

    @objc private func viewHistoryPicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onViewHistory?(schedule)
    }

    @objc private func openDestinationPicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onOpenDestination?(schedule.action.reviewDestination)
    }

    @objc private func deletePicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onDeleteSchedule?(schedule)
    }

    private func schedule(from identifier: String?, prefix: String) -> AutomationSchedule? {
        guard let identifier, identifier.hasPrefix(prefix) else { return nil }
        return schedule(fromID: String(identifier.dropFirst(prefix.count)))
    }

    private func schedule(fromID raw: String?) -> AutomationSchedule? {
        guard let raw, let id = UUID(uuidString: raw) else { return nil }
        return schedules.first { $0.id == id }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    private var debugColumns: [UUID: NSTextField] = [:]
    private var debugSparklines: [UUID: ScheduleRunSparkline] = [:]
    var debugRowCount: Int { rowsStack.arrangedSubviews.filter { $0 is HelmAccentRow }.count }
    var debugSectionTitles: [String] {
        rowsStack.arrangedSubviews.compactMap { view -> String? in
            guard !(view is HelmAccentRow), let stack = view as? NSStackView else { return nil }
            return stack.arrangedSubviews
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .first { !$0.isEmpty && $0 == $0.uppercased() }
        }
    }
    /// §7's time column and the run sparkline, as actually rendered - the frame
    /// so a check can prove the column really is a column (one constant x down
    /// the list), the bar count so it can prove a never-run schedule gets no
    /// fabricated history. Recorded at build time rather than dug back out of
    /// the view tree, which is both cheaper and impossible to mis-index.
    func debugTrailingColumns(for id: UUID) -> (time: String, timeFrameInCard: NSRect, runBars: Int)? {
        guard let time = debugColumns[id] else { return nil }
        return (time.stringValue,
                time.convert(time.bounds, to: card),
                debugSparklines[id]?.debugBarCount ?? 0)
    }
    func debugSparkline(for id: UUID) -> ScheduleRunSparkline? { debugSparklines[id] }
    var debugShowsEmptyState: Bool { rowsStack.arrangedSubviews.contains { $0 is HelmEmptyState } }
    func debugMenu(for schedule: AutomationSchedule) -> NSMenu { buildOverflowMenu(for: schedule) }
    func debugMetaLine(for schedule: AutomationSchedule, now: Date) -> String {
        rowContent(schedule, now: now, isRunning: schedule.id == runningScheduleID).meta ?? ""
    }
    func debugSetSearch(_ query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuild()
    }
    func debugToggle(for id: UUID) -> HelmToggle? {
        rowsStack.arrangedSubviews
            .compactMap { $0 as? HelmAccentRow }
            .flatMap { Self.allSubviews(of: $0) }
            .compactMap { $0 as? HelmToggle }
            .first { $0.identifier?.rawValue == "schedule-toggle:\(id.uuidString)" }
    }
    func debugReviewButton(for id: UUID) -> NSButton? {
        rowsStack.arrangedSubviews
            .compactMap { $0 as? HelmAccentRow }
            .flatMap { Self.allSubviews(of: $0) }
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "schedule-review:\(id.uuidString)" }
    }
    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
    #endif
}
