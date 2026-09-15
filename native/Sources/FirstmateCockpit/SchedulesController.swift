// Manjesh Grand Line - native macOS app.
//
// The `.schedules` rail destination (fm/grandline-schedules-sidebar-move).
//
// F11 originally shipped the "Schedules" card nested inside the Automation
// page, itself only reachable via the Setup flyout - two hops from the rail
// (hover/click Setup, then scroll past the pipeline stepper). The captain's
// own correction: a captain who wants to check on a schedule, or add one,
// should not have to know a flyout exists. This gives Schedules its own rail
// icon, directly visible in the sidebar, with no flyout or sub-page step.
//
// This is a presentation-layer move, not a rewrite: `SchedulesCardView`,
// `ScheduleStore`, `ScheduleRunner` and `AutomationSchedule` are all
// untouched. `AutomationController`'s "Run Automation" pipeline stepper
// (Firstmate home / Dotfiles / Agent instructions / Software checklist /
// Restore config) is unaffected and stays exactly where it was, behind the
// Setup flyout.
//
// **`fm/grand-line-schedules-page-redesign` rebuilt what this page renders**,
// against two captain-supplied references - see `SchedulesCardView`'s own
// header for the two structural decisions (grouped-by-status rather than a
// flat filtered list; no in-page hero title, because the drill header above
// already is one) and `SchedulesInsights.swift`'s for why every number on the
// page comes from real recorded runs rather than the references' demo data.
// What this controller gained: the summary tiles above the list, the two
// run-history panels below it, a page-level Refresh, and the one read of
// `ScheduleRunHistoryStore` that feeds all three plus every row's sparkline.
//
// Placement: the utility group (`RailDestination.isDailyUse == false`),
// alongside Tools/Vault/Dictation/Docs - a schedule "runs itself and reports
// to Health" (per `ScheduleRunner.swift`'s own header) rather than something
// a captain checks in on daily, which is the same criterion that already
// keeps Vault/Docs/Tools out of the daily-use `navStack` group.

import AppKit

final class SchedulesController: NSViewController, DaylightDrillActions {

    private let scheduleStore: ScheduleStore

    init(scheduleStore: ScheduleStore) {
        self.scheduleStore = scheduleStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!

    /// The card itself - see `SchedulesCardView`'s own header for why it is a
    /// self-contained view (owning rendering, deciding nothing) rather than
    /// business logic that belongs on this controller.
    private let schedulesCard = SchedulesCardView()

    /// Set by `AppShellController` - "re-read my subtitle". The header is the
    /// shell's; this page only says when its numbers moved.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Set by `AppShellController` - "show that destination". Forwarded, never
    /// owned: this page names a `RailDestination` and the shell decides what
    /// showing one means, exactly as `FleetController.onNavigateToDestination`
    /// already does.
    var onNavigateToDestination: ((RailDestination) -> Void)?

    // MARK: Drill header (Daylight §6.4)

    /// Counted off the same `ScheduleStore` array the rows below render, and
    /// off `ScheduleRunner`'s own "is one running" state - so the header and
    /// the rows can never disagree, and nothing new is read to produce it.
    var drillHeaderSubtitle: String? {
        let all = scheduleStore.schedules
        guard !all.isEmpty else { return "No schedules yet" }
        let noun = all.count == 1 ? "1 schedule" : "\(all.count) schedules"
        if ScheduleRunner.shared.runningScheduleID != nil { return "\(noun) \u{00B7} one running now" }
        let paused = all.filter { !$0.isEnabled }.count
        let failing = all.filter { $0.isEnabled && $0.lastRun?.verdict == .failed }.count
        let needsYou = all.filter { $0.isEnabled && $0.lastRun?.verdict == .changed }.count
        var parts = [noun]
        if failing > 0 { parts.append("\(failing) failing") }
        if needsYou > 0 { parts.append("\(needsYou) needs you") }
        if paused > 0 { parts.append("\(paused) paused") }
        if failing == 0 && needsYou == 0 && paused == 0 { parts.append("all running on their own") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// §6.4's action cluster: this page's one primary action, hoisted out of
    /// the card header. Caller-owned - `SchedulesCardView` still owns the
    /// button and its handler.
    ///
    /// Refresh is `HelmButton(.primary)` with the `arrow.clockwise` glyph, the
    /// app-wide shape `fm/grandline-refresh-button-consistency` settled on -
    /// not a second recipe invented here. It re-reads the store and the run
    /// history and re-renders: on this page that is worth an affordance
    /// because half of what a row says is *relative* ("in 13h", "6h ago",
    /// "3 runs recorded"), and a page left open goes quietly stale between the
    /// events that already trigger a rebuild.
    var drillHeaderActions: [NSView] { [schedulesCard.addButton, refreshButton] }

    private let refreshButton = HelmButton(title: "Refresh", variant: .primary,
                                           symbol: "arrow.clockwise")

    // MARK: The summary tiles and the two run-history panels

    /// Reference 1's three stat cards, on `HelmStatTile` - the app's own tile,
    /// which is what makes them read as this app's rather than the mockup's.
    ///
    /// Reference 2 offers the same three numbers as a compact inline summary
    /// bar instead (title + subtitle + stats + button in one row). That shape
    /// was deliberately not taken: its title-and-subtitle half is exactly what
    /// `HelmDrillHeader` already renders directly above this page, so adopting
    /// it would re-introduce the duplicate-title defect §6.4 exists to remove.
    /// The tiles carry the counts and leave the naming to the header.
    private let activeTile = HelmStatTile(symbol: "bolt.horizontal.circle.fill",
                                          caption: "Active schedules")
    private let attentionTile = HelmStatTile(symbol: "exclamationmark.circle.fill",
                                             caption: "Needs your attention")
    private let runsTile = HelmStatTile(symbol: "chart.bar.fill", caption: "Runs \u{00B7} last 7 days")

    /// The page's own left navigation column - the captain's correction after
    /// using the redesign (`fm/grand-line-schedules-sidebar-fullwidth-fix`).
    ///
    /// **Why this is not the rail coming back.** Daylight Phase 2 deliberately
    /// deleted the app-wide `IconRailController` and made `bodyContainer` span
    /// the window; this is a column *inside* this one destination's body, the
    /// same page-scoped arrangement Poneglyph has had since
    /// `fm/grand-line-roomier-poneglyph-vault-ui-li-0f`, and it is the same
    /// `HelmPageSidebar` component - so the two cannot drift.
    ///
    /// **Why a sidebar rather than the filter dropdown the redesign turned
    /// down.** That decision stands on its own terms: a dropdown asks for an
    /// interaction to reveal what a section header already states. A sidebar is
    /// a different control - always visible, and carrying each collection's
    /// live count, which is the thing a dropdown could not say. It also gives
    /// the page a second column, which is what keeps a row's line length
    /// readable now that the row itself is no longer capped.
    private let sidebar = HelmPageSidebar()

    /// The one id that is an *action* rather than a filter. `StatusFilter`'s
    /// own raw values cover the rest, so the sidebar and the card agree on
    /// what a row means without a second mapping.
    private static let runHistoryRowID = "run-history"

    private let activityCard = HelmCard()
    private let activityStack = NSStackView()
    private let overviewCard = HelmCard()
    private let overviewSummary = NSTextField(labelWithString: "")
    private let overviewChart = ScheduleRunOverviewChart()
    private let overviewNote = NSTextField(wrappingLabelWithString: "")

    /// The most activity rows the feed shows before saying how many it left
    /// out. A cap that is not stated reads as "that is all there is", which is
    /// the one thing this page must never imply about a run log.
    private static let activityRowLimit = 6

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root

        // The page-level explanatory line is gone (Daylight §6.4): the drill
        // header above now names the destination and carries its live numbers,
        // the card header states where runs are logged, and the empty state
        // says the same sentence this label did, verbatim, at the one moment a
        // captain actually needs it.
        let schedulesCardView = buildSchedulesCard()
        let statsRow = buildStatsRow()
        let insightsRow = buildInsightsRow()

        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Re-read the schedules and their run history, and re-time every "
            + "\u{201C}in 13h\u{201D} / \u{201C}6h ago\u{201D} on this page"

        let stack = NSStackView(views: [statsRow, schedulesCardView, insightsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        buildSidebar()

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            schedulesCardView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            insightsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            // **The nav column sits outside the scroll view, deliberately.**
            // It is navigation, so it has to stay reachable - and "Run History"
            // scrolls the content to the activity panel, which with the column
            // inside the document would have scrolled the filters themselves
            // off the top (seen in a real render before this was moved out).
            // `CredentialVaultController` pins its own sidebar to the page for
            // the same reason.
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                             constant: HelmMetrics.pageGutter),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                            constant: -HelmMetrics.pageGutter),
        ])
        NSLayoutConstraint.activate([
            // The content takes every point the window gains beyond the column.
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                            constant: HelmMetrics.s5 - HelmMetrics.pageGutter),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // AGENTS.md gotcha #4: pin the document view to the *clip* view,
            // never the outer scroll view - see `AutomationController`'s
            // identical comment for the full reasoning.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        // **Registered last, after every view this page paints exists.**
        //
        // `ThemeManager.observe` fires its closure *synchronously at
        // registration* - the trap this codebase has been bitten by four times
        // (see `HelmFormSheet`'s header and PR #278's blank Settings page).
        // Registering at the top of `loadView`, as this page used to, meant the
        // first render ran before the cards below the list had been given their
        // headers and bodies, and - worse - consumed `hasRenderedOnce`, the
        // flag whose whole job is to guarantee the *first* render is never
        // deferred by the visibility gate. Nothing was visibly broken, because
        // every view it touches is a stored `let`; it was one reordering away
        // from being exactly that bug. Registering here makes the synchronous
        // first fire a genuine, fully-assembled render.
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.refreshSchedules()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshSchedulesIfNeeded()
        scrollToTop()
    }

    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: The sidebar

    /// WORKSPACE (the four collections) over MANAGE (the one real entry).
    ///
    /// **"Preferences" is deliberately absent.** The reference lists it, and
    /// this app has no schedule-preferences surface at all - the only
    /// schedule-shaped setting anywhere is `AppSettings`'
    /// `didSeedDailyGitHubSyncSchedule`, a one-time seed guard rather than
    /// anything a captain sets. A nav row that opens nothing is a control that
    /// lies about what it does, which is the same call
    /// `CredentialVaultSidebar` already made about the reference's own
    /// `Favorites` and `Recently deleted` rows. The section stays, so a real
    /// preferences surface has an obvious place to land.
    private func buildSidebar() {
        sidebar.appendHeader("Workspace")
        for filter in SchedulesCardView.StatusFilter.allCases {
            sidebar.appendRow(id: filter.rawValue, symbol: filter.symbol, title: filter.title)
        }
        sidebar.appendSpacer()
        sidebar.appendHeader("Manage")
        // An *action*, not a filter: it reveals the run-history panel this page
        // already renders rather than narrowing the list, so it must not latch
        // selected - see `HelmPageSidebar.RowKind`.
        sidebar.appendRow(id: Self.runHistoryRowID, symbol: "clock.arrow.circlepath",
                          title: "Run History", kind: .action, showsCount: false)
        sidebar.select(SchedulesCardView.StatusFilter.all.rawValue)

        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            if id == Self.runHistoryRowID {
                self.revealRunHistory()
                return
            }
            guard let filter = SchedulesCardView.StatusFilter(rawValue: id) else { return }
            self.schedulesCard.setStatusFilter(filter)
            self.onDrillSubtitleChanged?()
        }
    }

    /// "Run History" scrolls the page to the activity panel it already has.
    ///
    /// Deliberately **not** a second history view: `fm/grand-line-schedules-page-redesign`
    /// already shipped "Recent activity", reading the real
    /// `ScheduleRunHistoryStore`, and a per-schedule log already exists behind
    /// every row's "View History...". A third surface over the same JSONL would
    /// be one more place for the same numbers to disagree.
    private func revealRunHistory() {
        guard let scroll = scrollView, let documentView = scroll.documentView else { return }
        view.layoutSubtreeIfNeeded()
        let target = activityCard.convert(activityCard.bounds, to: documentView)
        // A little headroom above the card, so it lands under the header rather
        // than flush against it.
        let y = max(0, target.minY - HelmMetrics.s4)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Schedules (F11)

    /// Wires `SchedulesCardView`'s closures - every one of them is a decision
    /// that needs either a store write or a sheet presentation, which is
    /// exactly the split between that view and this controller. Moved here
    /// verbatim from `AutomationController.buildSchedulesCard()`.
    private func buildSchedulesCard() -> NSView {
        schedulesCard.onNewSchedule = { [weak self] in self?.presentScheduleEditor(editing: nil) }
        schedulesCard.onEditSchedule = { [weak self] schedule in self?.presentScheduleEditor(editing: schedule) }
        schedulesCard.onDeleteSchedule = { [weak self] schedule in self?.confirmDeleteSchedule(schedule) }
        schedulesCard.onViewHistory = { [weak self] schedule in self?.presentScheduleHistory(schedule) }
        // The row's "Review" hand-off. `AppShellController` wires this to
        // `show(_:)` - the same forward-don't-own seam Overview's own
        // `onNavigateToDestination` already uses, rather than this page
        // learning what a destination is.
        schedulesCard.onOpenDestination = { [weak self] dest in self?.onNavigateToDestination?(dest) }
        schedulesCard.onRunNow = { [weak self] schedule in
            ScheduleRunner.shared.runNow(schedule)
            self?.refreshSchedules()
        }
        schedulesCard.onToggleEnabled = { [weak self] schedule, enabled in
            guard let self else { return }
            self.scheduleStore.setEnabled(enabled, id: schedule.id)
            // Pausing a schedule should also retire whatever its last run left
            // in the notification center - a paused schedule reporting drift
            // it will not re-check is a stale claim.
            if !enabled {
                NotificationSources.clearScheduleResult(scheduleID: schedule.id)
            }
            self.refreshSchedules()
        }
        // The runner is what knows a run just finished; the card re-reads the
        // store rather than being handed a result, so there is one source of
        // truth for what a row shows.
        // The card re-renders on every store change and every run-state
        // change; the header's own line has to follow the same signal.
        schedulesCard.onStateChanged = { [weak self] in
            guard let self else { return }
            self.onDrillSubtitleChanged?()
            // Typing in the card's own search box changes what each collection
            // matches, and the card is what knows the query - so the counts
            // follow the same signal the rows do rather than being recomputed
            // on a timer or left stale until the next full render.
            self.refreshSidebarCounts()
        }
        ScheduleRunner.shared.onRunStateChanged = { [weak self] _ in self?.refreshSchedules() }
        scheduleStore.onChange = { [weak self] in self?.refreshSchedules() }
        refreshSchedules()
        return schedulesCard.card
    }

    // MARK: The summary tiles

    /// Three tiles, `.fillEqually`, exactly as reference 1 lays them out.
    private func buildStatsRow() -> NSView {
        let row = NSStackView(views: [activeTile, attentionTile, runsTile])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: The two run-history panels

    /// Reference 1's bottom pair: "Recent activity" and "Run overview".
    ///
    /// Both are real (`ScheduleRunHistoryStore`), which is the only reason
    /// either was built - the reference backs them with a hardcoded 24-run
    /// chart and an invented feed, and the brief's instruction for a piece with
    /// no real data behind it was to scope it out rather than fill it in.
    private func buildInsightsRow() -> NSView {
        activityStack.orientation = .vertical
        activityStack.alignment = .leading
        activityStack.spacing = HelmMetrics.s2
        activityStack.translatesAutoresizingMaskIntoConstraints = false
        activityCard.setHeader(symbol: "clock.arrow.circlepath",
                               tint: .info,
                               title: "Recent activity",
                               subtitle: "Every recorded run, newest first")
        activityCard.setBody(activityStack, insets: HelmCard.contentInsets)

        overviewSummary.translatesAutoresizingMaskIntoConstraints = false
        overviewSummary.lineBreakMode = .byTruncatingTail
        overviewSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overviewNote.translatesAutoresizingMaskIntoConstraints = false
        overviewNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let overviewStack = NSStackView(views: [overviewSummary, overviewChart, overviewNote])
        overviewStack.orientation = .vertical
        overviewStack.alignment = .leading
        overviewStack.spacing = HelmMetrics.s2
        overviewStack.translatesAutoresizingMaskIntoConstraints = false
        overviewCard.setHeader(symbol: "chart.bar.xaxis",
                               tint: .accent,
                               title: "Run overview",
                               subtitle: "Last 7 days")
        overviewCard.setBody(overviewStack, insets: HelmCard.contentInsets)
        NSLayoutConstraint.activate([
            overviewSummary.widthAnchor.constraint(equalTo: overviewStack.widthAnchor),
            overviewChart.widthAnchor.constraint(equalTo: overviewStack.widthAnchor),
            overviewNote.widthAnchor.constraint(equalTo: overviewStack.widthAnchor),
        ])

        let row = NSStackView(views: [activityCard, overviewCard])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Repaints the tiles and both panels from the same `schedules` + `history`
    /// pair the rows were built from, so a number in a tile and a bar in the
    /// chart can never disagree with the list they sit around.
    private func renderInsights(_ schedules: [AutomationSchedule],
                                history: [ScheduleRunHistoryEntry]) {
        let active = schedules.filter(\.isEnabled).count
        let attention = schedules.filter { SchedulesCardView.group(for: $0) == .needsYou }.count
        activeTile.value = "\(active)"
        activeTile.setTint(nil, theme: theme)
        attentionTile.value = "\(attention)"
        attentionTile.setTint(attention > 0 ? .warn : nil, theme: theme)
        runsTile.value = "\(history.count)"
        runsTile.setTint(nil, theme: theme)
        activeTile.toolTip = "\(active) of \(schedules.count) schedules are running on their own"
        attentionTile.toolTip = attention == 0
            ? "Nothing is waiting on you"
            : "Their last run found something - each one has a Review button on its row"
        runsTile.toolTip = "Runs recorded in the past 7 days, across every schedule"

        activityCard.applyTheme(theme)
        overviewCard.applyTheme(theme)
        renderActivity(history)
        renderOverview(history)
    }

    private func renderActivity(_ history: [ScheduleRunHistoryEntry]) {
        for view in activityStack.arrangedSubviews {
            activityStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        func add(_ view: NSView) {
            activityStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: activityStack.widthAnchor).isActive = true
        }
        guard !history.isEmpty else {
            add(HelmEmptyState(symbol: "clock.badge.questionmark",
                               body: "No runs recorded yet. A schedule's runs show up here as they happen, "
                                   + "and are kept for seven days."))
            return
        }
        let now = Date()
        for entry in history.prefix(Self.activityRowLimit) {
            add(activityRow(entry, now: now))
        }
        // "no silent caps": say how many were left out rather than implying
        // the six shown are all there is.
        if history.count > Self.activityRowLimit {
            let more = history.count - Self.activityRowLimit
            let note = NSTextField(labelWithString: "+\(more) more in the past 7 days \u{2014} open a schedule\u{2019}s \u{201C}View History\u{2026}\u{201D} for its own log")
            note.font = HelmType.captionSmall()
            note.textColor = HelmTheme.mutedInk(theme)
            note.lineBreakMode = .byTruncatingTail
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            note.translatesAutoresizingMaskIntoConstraints = false
            add(note)
        }
    }

    private func activityRow(_ entry: ScheduleRunHistoryEntry, now: Date) -> NSView {
        let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.tileSmall / 2)
        tile.configure(symbol: entry.verdict.symbol, tint: entry.verdict.tint)
        tile.applyTheme(theme)

        let title = NSTextField(labelWithString: entry.actionTitle)
        title.font = HelmType.caption()
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: entry.summary)
        detail.font = HelmType.captionSmall()
        detail.textColor = HelmTheme.mutedInk(theme)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let age = NSTextField(labelWithString: AutomationSchedule.relativeAge(from: entry.at, to: now))
        age.font = HelmType.code()
        age.textColor = HelmTheme.mutedInk(theme)
        age.alignment = .right
        age.translatesAutoresizingMaskIntoConstraints = false
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [tile, text, age])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        // gotcha (10): without `.fill` the age would drift with the title
        // rather than pinning to the row's trailing edge.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.toolTip = "\(entry.verdict.outcomeChipText) \u{00B7} \(Self.activityTooltipFormatter.string(from: entry.at))"
        return row
    }

    private static let activityTooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func renderOverview(_ history: [ScheduleRunHistoryEntry]) {
        let now = Date()
        let buckets = ScheduleRunStats.dailyBuckets(entries: history, now: now)
        overviewChart.setBuckets(buckets, theme: theme)

        let attention = history.filter { $0.verdict != .clean }.count
        let runs = history.count == 1 ? "1 run" : "\(history.count) runs"
        overviewSummary.stringValue = attention == 0
            ? "\(runs) \u{00B7} all clean"
            : "\(runs) \u{00B7} \(attention) needed you"
        overviewSummary.font = HelmType.rowTitle()
        overviewSummary.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        overviewNote.stringValue = history.isEmpty
            ? "Nothing has run in the past seven days. Bars appear here as runs are recorded."
            : "Each bar is one day. The green share ran clean; the amber share found something worth your attention."
        overviewNote.font = HelmType.captionSmall()
        overviewNote.textColor = HelmTheme.mutedInk(theme)
    }

    /// Rebuilds every row. P2/P3 (`data/grand-line-e2e-audit/report.md`):
    /// **skipped while this page is not the one showing** - it would rebuild
    /// again on its next appearance anyway, and with every destination mounted
    /// for the session (GL-37) that waste is a real part of what made ⌘⌥T
    /// stall the main thread for ~0.7-1.0s. What was missed is remembered
    /// (`needsRefreshOnAppear`) rather than dropped.
    private func refreshSchedules() {
        guard isViewLoaded else { return }
        // The very first render is never deferred. A page that is mounted but
        // has never been populated renders as a blank body - the exact
        // "mounted, visible, but empty" shape PR #278 fixed for Settings, and
        // `DestinationMountingSelfTest` catches it. After that, deferring is
        // safe: `refreshSchedulesIfNeeded` settles it on the next appearance.
        guard hasRenderedOnce else {
            needsRefreshOnAppear = false
            lastRefreshedAt = Date()
            hasRenderedOnce = true
            renderAll()
            return
        }
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else {
            needsRefreshOnAppear = true
            // The header's live line is a string, not a view tree - it stays
            // current either way.
            onDrillSubtitleChanged?()
            return
        }
        needsRefreshOnAppear = false
        lastRefreshedAt = Date()
        hasRenderedOnce = true
        renderAll()
    }

    /// The one place the page's three surfaces are painted, from **one** read
    /// of each store.
    ///
    /// `ScheduleRunHistoryStore` is a file-backed singleton, so the rows'
    /// sparklines, the "runs last 7 days" tile, the activity feed and the chart
    /// all take the same array rather than each asking for their own - which
    /// both keeps the page's numbers consistent within a frame and keeps a
    /// render to a single store hit.
    private func renderAll() {
        let schedules = scheduleStore.schedules
        let history = ScheduleRunHistoryStore.shared.allEntries()
        schedulesCard.setSchedules(schedules,
                                   runningID: ScheduleRunner.shared.runningScheduleID,
                                   history: history,
                                   theme: theme)
        refreshSidebarCounts()
        sidebar.applyTheme(theme)
        renderInsights(schedules, history: history)
    }

    /// Counted off the very array the rows render, against the card's own
    /// current search - so a sidebar count and the list beneath it can never
    /// disagree within a frame.
    private func refreshSidebarCounts() {
        guard isViewLoaded else { return }
        let counts = SchedulesCardView.filterCounts(scheduleStore.schedules,
                                                    query: schedulesCard.currentSearchQuery)
        sidebar.setCounts(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }))
    }

    /// The page-level Refresh. Nothing here re-runs a schedule - it re-reads
    /// and re-times, which is what goes stale on a page left open.
    @objc private func refreshTapped() {
        refreshSchedules()
        Toast.show(in: view, message: drillHeaderSubtitle ?? "Schedules refreshed")
    }

    /// Something changed (a store write, a run starting or finishing, a theme
    /// switch) while this page was hidden.
    private var needsRefreshOnAppear = true
    private var lastRefreshedAt: Date?
    /// Whether this page has ever rendered its rows. Until it has, the
    /// visibility gate must not apply - see `refreshSchedules`.
    private var hasRenderedOnce = false

    /// How long before a row's relative wording ("in 3 hours", "not run yet")
    /// is worth re-rendering for.
    private static let relativeWordingStaleAfter: TimeInterval = 60

    /// P3: rebuild on a visit only when it would change what is on screen -
    /// something moved while this page was hidden, or the rows' own relative
    /// wording has gone stale. Every real data change already reaches
    /// `refreshSchedules` directly through `scheduleStore.onChange` /
    /// `ScheduleRunner.onRunStateChanged`, so a visit that follows a visit
    /// costs nothing.
    private func refreshSchedulesIfNeeded() {
        let stale = lastRefreshedAt.map { Date().timeIntervalSince($0) >= Self.relativeWordingStaleAfter } ?? true
        guard needsRefreshOnAppear || stale else { return }
        refreshSchedules()
    }

    private func presentScheduleEditor(editing: AutomationSchedule?) {
        let editor = ScheduleEditorController(schedule: editing)
        editor.onSave = { [weak self] schedule in
            guard let self else { return }
            if editing == nil {
                self.scheduleStore.add(schedule)
                Toast.show(in: self.view, message: "Schedule created")
            } else {
                self.scheduleStore.update(schedule)
                Toast.show(in: self.view, message: "Schedule saved")
            }
            self.refreshSchedules()
        }
        editor.onDelete = { [weak self] id in
            guard let self else { return }
            self.scheduleStore.delete(id: id)
            NotificationSources.clearScheduleResult(scheduleID: id)
            self.refreshSchedules()
        }
        presentAsSheet(editor)
    }

    /// "View History..." - the last 7 days of runs for one schedule
    /// (`ScheduleRunHistoryStore`), read-only.
    private func presentScheduleHistory(_ schedule: AutomationSchedule) {
        presentAsSheet(ScheduleHistoryController(schedule: schedule))
    }

    /// A schedule is cheap to recreate, but deleting one silently on a menu
    /// click would still be a surprise - and this app confirms every other
    /// record delete (see `HostsController`'s own confirm alert).
    #if FM_SELFTESTS
    var debugSidebar: HelmPageSidebar { sidebar }
    var debugScrollOffsetY: CGFloat { scrollView?.contentView.bounds.origin.y ?? -1 }
    var debugVisibleScheduleRowCount: Int { schedulesCard.debugRowCount }

    /// The three summary tiles' rendered values - read off the tiles rather
    /// than recomputed, so a check can see a tile that stopped being repainted.
    var debugStatValues: (active: String, attention: String, runs: String) {
        (activeTile.value, attentionTile.value, runsTile.value)
    }
    /// Whether the activity feed is showing its honest "nothing recorded yet"
    /// state rather than an empty stack that merely looks like one.
    var debugActivityShowsEmptyState: Bool {
        activityStack.arrangedSubviews.contains { $0 is HelmEmptyState }
    }
    var debugOverviewChartAxis: [String] { overviewChart.debugAxisLabels }
    /// The card this page renders - so a suite can read the real time column
    /// and run sparkline it built rather than re-deriving them.
    var debugSchedulesCard: SchedulesCardView? { isViewLoaded ? schedulesCard : nil }
    /// G3: drive the real delete path, confirmation and all.
    func debugConfirmDeleteSchedule(_ schedule: AutomationSchedule) {
        confirmDeleteSchedule(schedule)
    }
    #endif

    private func confirmDeleteSchedule(_ schedule: AutomationSchedule) {
        // G3: themed; Return still deletes, as it did here.
        guard HelmConfirm.confirm(
            title: "Delete this schedule?",
            body: "\(schedule.action.title) will stop running on its own. "
                + "The action itself stays available to run by hand on its own page.",
            confirmTitle: "Delete",
            destructive: true,
            symbol: "trash.fill",
            hue: .rose) else { return }
        scheduleStore.delete(id: schedule.id)
        NotificationSources.clearScheduleResult(scheduleID: schedule.id)
        refreshSchedules()
    }
}
