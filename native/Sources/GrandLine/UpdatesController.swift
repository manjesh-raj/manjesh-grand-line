// Grand Line - native macOS app.
//
// "Firstmate Latest Updates" - the new `.updates` rail destination (rail icon
// pinned directly above Settings). Lists every tool in the captain's
// ecosystem, checks each for updates automatically on page load, and lets the
// captain apply an update with one explicit click per row. Laid out with the
// same card-section/row visual density as `SettingsController` (card chrome,
// row style, `FlippedView` + `scrollToTop()` for the same "empty gap above
// the header" fix that page already carries) rather than inventing a new
// layout language.
//
// Interaction flow (captain-specified):
//   1. Check (automatic on load, or the row's own button) runs the read-only
//      comparison and updates status. Update only appears when Check found a
//      genuine update available - see `DependencyStatus.showsUpdateButton`.
//      cockpit-bootstrap-software: `.notInstalled` is the one exception - it
//      no longer shows Update (which used to silently mean "install"); it
//      shows a distinct "Install in Bootstrap ->" action instead, which
//      navigates to the `.bootstrap` rail destination's own Software
//      checklist card (`onNavigateToBootstrap`, wired by
//      `AppShellController` to `show(.bootstrap)`) rather than running the
//      install here. Every other status's Update button is unchanged.
//   2. Update immediately shows an in-progress state (spinner + "Updating…",
//      row disabled) while the real command runs in the background.
//   3. On success: a `Toast` ("{tool} updated to {version}") plus the row
//      flips back to up to date (Update disappears again).
//   4. Also fires a macOS user notification for the same event, so the
//      captain can tell it finished even unfocused - permission requested
//      gracefully, and a denial only skips the notification, never the toast.
//   5. On failure the row shows a clear failure state with the real command
//      output (via the row's expandable log), never a silent revert.
//
// All `UpdatesSource.check`/`.update` calls run on a background queue
// (`DispatchQueue.global`), matching `FleetController.refresh`/`.mergePR`.

import AppKit
import UserNotifications

/// Mutable per-row state and the views it owns - one instance per
/// `DependencyItem`, built once in `loadView` and updated in place by
/// `render(_:)` rather than rebuilt on every check/update.
final class UpdateRow {
    let item: DependencyItem
    var status: DependencyStatus = .unknown
    var latestLabel: String?
    var detail: String = "Not checked yet"
    var log: String = ""
    /// The installed version the last check read, for the sidebar layout's
    /// Installed column (stage 7). `nil` until a check has answered.
    var installedLabel: String?
    /// Set when the last Update was not started because it needs the
    /// captain's password - `UpdateOutcome.terminalCommand`. Cleared by the
    /// next check, which re-asks the machine.
    var terminalCommand: String?
    var isLogExpanded = false
    var isBusy = false
    /// When the answer this row shows was gathered - a real check's own
    /// time, which for a kept or shared answer is earlier than when it was
    /// shown (R2-PERF-05).
    var checkedAt: Date?

    let iconTile = IconTileView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = HelmStatusPill()
    /// D3: the status column's placeholder is a redacted pill in the shape
    /// of the status that is coming, not a grey system spinner. The finding's
    /// own scope limit is kept - a spinner inside a button the captain just
    /// pressed is feedback for *their* action and stays - but this one was
    /// standing in for a *status* that had not arrived, which is exactly the
    /// case skeletons are for.
    let statusSkeleton = HelmSkeletonRow(shape: .pill)
    let progressLabel = NSTextField(labelWithString: "Updating\u{2026}")
    let checkButton = HelmButton(title: "Check", variant: .secondary, size: .small)
    let updateButton = HelmButton(title: "Update", variant: .primary, size: .small)
    /// `.notInstalled`-only action, styled deliberately unlike `updateButton`
    /// (inline/link-style rather than a bordered rounded button) so it reads
    /// as "go elsewhere," not "click to install here" - see the file header.
    let installInBootstrapButton = HelmButton(title: "Install in \(PlaceName.short(.bootstrap)) \u{2192}", variant: .quiet, size: .small)
    /// Shown in place of Update when the update needs a password: opens the
    /// exact command in a Console tab, where `sudo` has a terminal to ask in.
    let runInTerminalButton = HelmButton(title: "Run in Terminal", variant: .primary, size: .small)
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    /// Swapped between [pill, checkButton, updateButton] and
    /// [spinner, progressLabel] depending on `isBusy`.
    let trailingStack = ToolRowLayout.ActionStack()

    /// This row's fields, packaged for the shared `ToolRowLayout` assembly.
    var toolRowViews: ToolRowLayout.Views {
        ToolRowLayout.Views(
            iconTile: iconTile, nameLabel: nameLabel, detailLabel: detailLabel,
            pill: pill, trailingStack: trailingStack,
            detailsButton: detailsButton, logField: logField, logContainer: logContainer,
            rowContainer: rowContainer
        )
    }

    init(item: DependencyItem) { self.item = item }
}

final class UpdatesController: NSViewController, DaylightDrillActions {

    /// One category card's rows + the separators between them, kept so the
    /// search field can hide non-matching rows and collapse the separator
    /// that would otherwise sit next to a hidden row - see `applyFilter`.
    struct CategorySection {
        let background: NSView
        let rows: [UpdateRow]
        let separators: [NSView]
    }

    /// `String`-backed so it can be the id `HelmSegmentedTabs` hands back - the
    /// shared component deals in caller-owned ids rather than indices.
    private enum ToolFilterMode: String { case all, needsAttention }

    var rows: [UpdateRow] = DependencyCatalog.items.map(UpdateRow.init)
    /// Guards `updateAllPending` against a second press while a serial run is
    /// still walking the list.
    private var isUpdatingAll = false
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    var cards: [HelmCard] = []
    private var separators: [NSView] = []
    var categorySections: [CategorySection] = []

    /// The summary strip's four tiles. Each themes itself; this list is what
    /// `renderStats` writes the numbers into and `applyTheme` hands the theme to.
    /// UI-44: the page's four numbers as one flat strip, not four boxes.
    let summaryStrip = HelmKPIStrip()
    /// One per category card, themed with the page.
    var groupHeaders: [HelmSectionHeader] = []
    /// The tool filter, in the app's own search well (Phase 0's raw-input
    /// purge). This is the audit's screenshot-5 brown field: a stock
    /// `NSSearchField` whose only theming was a forced `appearance`, which
    /// selects the light-or-dark side of a *system* fill rather than a
    /// theme-derived one (D2).
    private let searchField = HelmSearchField(placeholder: "Filter tools\u{2026}")
    private var filterMode: ToolFilterMode = .all
    /// The All / Needs Attention filter, now the app's shared
    /// `HelmSegmentedTabs` (`HelmDesignSystem.swift`, audit §6.3 component 6) at
    /// its `.compact` size - this control sits in a toolbar beside a search
    /// field rather than under a page title, which is what `.compact` exists
    /// for. It was a third near-copy of Shift's and Docs' pill recipe, at
    /// radius 6 in a radius-8 container.
    private let filterTabs = HelmSegmentedTabs(items: [
        .init(id: ToolFilterMode.all.rawValue, title: "All"),
        .init(id: ToolFilterMode.needsAttention.rawValue, title: "Needs Attention"),
    ], selected: ToolFilterMode.all.rawValue, size: .compact)
    /// Set by `AppShellController` (mirrors `BootstrapController.onRunCommand`'s
    /// closure-injection pattern) so a `.notInstalled` row's action can select
    /// the Bootstrap rail destination without this controller knowing
    /// anything about `AppShellController`/`RailDestination` itself.
    var onNavigateToBootstrap: (() -> Void)?
    /// Set by `AppShellController` to its `runInConsole`, the same
    /// one-shot Console tab Bootstrap and Settings use for anything that
    /// needs a real `sudo` prompt. The completion carries the exit status.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?
    private var lastCheckedAt: Date?

    // MARK: The sidebar layout's state (stage 7)

    /// Set once, the first time the sidebar shell shows this page
    /// (`adoptSidebarLayout`). The floating bar never sets it.
    private var drawsSidebarLayout = false
    private var pageStack: NSStackView?
    private var statsRowView: NSView?
    /// Setup's five summary cards, shared with the module's other tabs.
    private lazy var setupSummary = SetupSummaryRow()
    /// Every tool in one table, grouped by where it comes from - the
    /// prototype's one table card, with the real groups.
    private lazy var toolsTable: HelmDataTable = {
        let table = HelmDataTable(columns: [
            .init(id: "tool", title: "Tool", width: 260, minWidth: 180, flexible: true),
            .init(id: "installed", title: "Installed", width: 130),
            .init(id: "available", title: "Available", width: 170),
            .init(id: "source", title: "Source", width: 120, hiddenBelow: 720),
        ], actionsWidth: 170)
        table.sizesToFitRows = true
        table.accessibilityName = "Tools"
        table.onSelect = { [weak self] key in
            self?.selectedToolID = key
            self?.onInspectorContentChanged?()
        }
        return table
    }()
    private let toolsLastChecked = NSTextField(labelWithString: "")
    /// The toolbar's primary action: Check all, by the prototype's name. The
    /// floating bar keeps its Check all pill.
    private lazy var checkForUpdatesButton: HelmButton = {
        let button = HelmButton(title: "Check for updates", variant: .secondary, size: .small,
                                symbol: "arrow.clockwise", target: self, action: #selector(checkAllTapped))
        button.toolTip = "Check every tool for updates"
        return button
    }()
    private var selectedToolID: String?
    private lazy var toolDetail = WorkspaceDetailView()
    var onInspectorContentChanged: (() -> Void)?
    var onShowInspector: (() -> Void)?
    private var lastCheckedTimer: Timer?
    private var hasCheckedOnce = false

    deinit {
        lastCheckedTimer?.invalidate()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        let statsRow = buildStatsRow()
        let toolbarRow = buildToolbarRow()
        var sections: [NSView] = [statsRow, toolbarRow]
        for category in DependencyCatalog.categoryOrder {
            let categoryRows = rows.filter { $0.item.category == category }
            guard !categoryRows.isEmpty else { continue }
            sections.append(card(icon: iconFor(category: category), title: category, rows: categoryRows))
        }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        // UI-33's scale: 16 between sections, 24 from the top.
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        pageStack = stack
        statsRowView = statsRow

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: HelmMetrics.s5),
            // U10's second half: a completion toast is a floating pill at the
            // bottom of the window, and this page's last card used to end
            // 20pt above that edge - so "Checked 13 tools" landed on top of
            // the "Other tools" section header and read as a collision
            // rather than as chrome. The page reserves the pill's own band
            // instead; `Toast.reservedBottomSpace` is the one number, so a
            // change to the pill's size or inset moves both together.
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                          constant: -Toast.reservedBottomSpace),
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        for row in rows { render(row) }
        applyFilter()
        applyTheme()
        renderStats()
    }

    private let scrollMemory = HelmScrollMemory()

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        // P3: keep the captain's place unless the page changed (`HelmScrollMemory`).
        scrollMemory.restore(scrollView) { scrollToTop() }
        renderStats()
        lastCheckedTimer?.invalidate()
        let ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.renderStats()
        }
        // 3.4: this only re-renders a relative-time label ("checked 2m ago"),
        // so it is the most tolerant timer in the app - a few seconds of
        // coalescing slack is invisible in that string.
        ticker.tolerance = 10
        lastCheckedTimer = ticker
        if !hasCheckedOnce {
            hasCheckedOnce = true
            checkAll()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scrollMemory.remember(scrollView)
        lastCheckedTimer?.invalidate()
        lastCheckedTimer = nil
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Toolbar (segmented filter + search + Refresh)

    /// A prominent, labeled, accent-colored pill (icon + "Refresh") - the
    /// captain's mockup showed this as the page's clear primary action, not a
    /// bare icon glyph, superseding cockpit-native-updates-polish's earlier
    /// borderless-icon-button decision for this control.
    ///
    /// The recipe itself now lives in `HelmRefreshPill` (which carries the
    /// rest of that history, including why it is a `HoverHighlightView`
    /// rather than an `NSButton`), extracted so Setup > GitHub Sync could
    /// carry "the same button" and have that stay true - see
    /// `fm/grand-line-github-sync-page-refresh-cleanup`. This page renders
    /// exactly as it did before that extraction; every metric moved rather
    /// than being re-chosen.
    /// X8 (review UX): titled "Check all", not "Refresh".
    ///
    /// The review asked for "a single Check all plus per-row actions only
    /// when something is available". U10 did the second half - a row that is
    /// up to date now carries no button at all - and this is the first. On a
    /// page where most rows deliberately offer nothing, the one bulk control
    /// has to say what it does on its face: "Refresh" named the gesture
    /// (re-draw this page) rather than the work (go and ask thirteen tools),
    /// and the only thing that said so was a tooltip nobody hovers when every
    /// row already looks settled.
    ///
    /// `HelmRefreshPill` is unchanged and GitHub Sync's own pill keeps
    /// "Refresh" - there the rows *are* the thing being refreshed, and this
    /// is a label decision per page rather than a component one.
    private let checkAllPill = HelmRefreshPill(
        title: "Check all", tooltip: "Check every tool for updates", prominent: true)
    private let checkAllProgressBar = HelmProgressBar()
    private let checkAllProgressLabel = NSTextField(labelWithString: "")
    private var isCheckingAll = false

    #if FM_SELFTESTS
    /// GL-16-style probe surface: exposes the exact view a self-test needs
    /// to read to prove the Refresh pill's fill survives a hover cycle,
    /// without loosening any of this file's own access levels for
    /// production callers.
    var checkAllPillForTests: HoverHighlightView { checkAllPill }

    /// X8: the page's one bulk control, by the label it wears.
    var debugCheckAllTitle: String { checkAllPill.debugTitle }
    var debugCheckAllIsVisible: Bool { !checkAllPill.isHidden }

    /// Set every row's status to `statuses` (by catalog order) and run the
    /// page's **real** `renderStats()` choke point.
    ///
    /// Deliberately drives the choke point rather than calling
    /// `publishToolUpdateSignal()` directly: the regression being guarded is
    /// that this page learns fresh truth and the Engineering hub never hears
    /// about it, so a test that skipped the wiring and called the publish
    /// method itself would pass with the wiring deleted.
    func debugApplyStatusesAndRender(_ statuses: [DependencyStatus]) {
        for (row, status) in zip(rows, statuses) { row.status = status }
        renderStats()
    }

    #endif

    /// The mockup's `.toolbar-row`: segmented "All / Needs attention" filter,
    /// the live search field, and the Refresh action (swapped for a progress
    /// bar+label while a check-all is running) pinned to the trailing edge.
    private func buildToolbarRow() -> NSView {
        filterTabs.onSelect = { [weak self] id in
            guard let self else { return }
            self.filterMode = ToolFilterMode(rawValue: id) ?? .all
            self.applyFilter()
        }

        searchField.onTextChanged = { [weak self] _ in self?.applyFilter() }
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        // AGENTS.md gotcha (12): `HelmSearchField` is a plain `NSView` with no
        // intrinsic content size, so a content-priority call would be a no-op -
        // the explicit width above is what holds this column, and the toolbar
        // stack's own `.fill` distribution does the rest.

        checkAllPill.setAction(target: self, action: #selector(checkAllTapped))

        // G4: the app's own bar, which already handles theme + tint - a stock
        // determinate `NSProgressIndicator` is the one control on this page
        // still drawing system chrome.
        checkAllProgressBar.isHidden = true
        checkAllProgressBar.setContentHuggingPriority(.required, for: .horizontal)
        checkAllProgressBar.widthAnchor.constraint(equalToConstant: 90).isActive = true

        checkAllProgressLabel.setScaledFont(ofSize: 11, weight: .medium)
        checkAllProgressLabel.isHidden = true
        checkAllProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        for v: NSView in [checkAllProgressLabel, checkAllProgressBar] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [
            filterTabs, searchField, spacer,
            checkAllProgressLabel, checkAllProgressBar, checkAllPill,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // The Refresh pill is this page's explicit re-check affordance - it must
    // always bypass `DependencyCheckCache` and run the real 13-item sweep,
    // never serve a hit that another page happened to cache moments ago.
    // `viewWillAppear`'s automatic first-visit call is the one place that
    // benefits from a cache hit (see `check(_:forceRefresh:completion:)`
    // below) - it passes `forceRefresh: false` (the default).
    @objc private func checkAllTapped() { checkAll(forceRefresh: true) }

    /// R2-PERF-05: how old a kept answer may be and still stand in for a
    /// visit's sweep. Twelve hours covers relaunching through a working day
    /// - the cost the review measured was every launch that opened Setup
    /// paying five `npm view`s and the rest again. An update published since
    /// is not missed for long: `BackgroundSignalsPoller` still runs its own
    /// sweep on its 15-minute cadence for the bell, with its own shorter
    /// limit, and Check for updates always runs the real thing.
    static let visitFreshness: TimeInterval = 12 * 60 * 60

    private func checkAll(forceRefresh: Bool = false) {
        guard !isCheckingAll else { return }
        // A visit shows each kept answer young enough to stand, and checks
        // only the rest.
        var toCheck = rows
        if !forceRefresh {
            toCheck = rows.filter { row in
                guard !row.isBusy,
                      let kept = DependencyCheckCache.shared.recentOutcome(for: row.item, maxAge: Self.visitFreshness)
                else { return true }
                apply(kept.outcome, gatheredAt: kept.gatheredAt, to: row)
                return false
            }
            guard !toCheck.isEmpty else {
                lastCheckedAt = rows.compactMap(\.checkedAt).min()
                renderStats()
                runPendingNotificationUpdates()
                return
            }
        }
        isCheckingAll = true
        checkAllPill.isHidden = true
        checkForUpdatesButton.isEnabled = false
        checkAllProgressBar.isHidden = false
        checkAllProgressLabel.isHidden = false

        let total = toCheck.count
        checkAllProgressBar.configure(fraction: 0)
        checkAllProgressLabel.stringValue = "Checking\u{2026} (0/\(total))"

        var completed = 0
        for row in toCheck {
            check(row, forceRefresh: forceRefresh) { [weak self] in
                guard let self else { return }
                completed += 1
                self.checkAllProgressBar.configure(
                    fraction: total == 0 ? 1 : Double(completed) / Double(total))
                self.checkAllProgressLabel.stringValue = "Checking\u{2026} (\(completed)/\(total))"
                if completed == total { self.finishCheckAll() }
            }
        }
    }

    private func finishCheckAll() {
        isCheckingAll = false
        // The sidebar layout's toolbar carries Check for updates instead.
        checkAllPill.isHidden = drawsSidebarLayout
        checkForUpdatesButton.isEnabled = true
        checkAllProgressBar.isHidden = true
        checkAllProgressLabel.isHidden = true
        // The oldest answer on the page, which is what "checked 2 h ago"
        // has to be true of.
        lastCheckedAt = rows.compactMap(\.checkedAt).min() ?? Date()
        renderStats()

        // R2-BUG-03: "updates available" counts updates, and the rest is
        // stated separately, from the one summary the header and strip read.
        showToastIfOnScreen(summary.completionMessage)
        // Anything the notification popover asked for while this sweep was
        // running now has a real, current status to act on.
        runPendingNotificationUpdates()
    }

    /// A toast, but only while this page is the one being looked at.
    ///
    /// Review #3's B8. A toast is presented on `window.contentView`, so it
    /// floats over the *window* rather than over the page that raised it - and
    /// this page's sweep is slow (13 real `brew`/`npm` checks), so a captain
    /// who starts one and navigates on gets "Checked 13 tools, 2 updates
    /// available" landing on Automation or GitHub Sync, pages that did no such
    /// thing. Every destination stays mounted and is only hidden (GL-37), so
    /// `!view.isHidden` is the exact question "is this page on screen".
    ///
    /// Nothing is lost by staying quiet: `renderStats` publishes the same
    /// count to `BackgroundSignalsPoller`, which is what puts it in the
    /// notification centre and on the Engineering hub card - GL-30's own rule
    /// that a result still true after a toast would have faded belongs there
    /// rather than in a pill on somebody else's page.
    #if FM_SELFTESTS
    /// Drive the real gate - B8's whole defect was *where* a toast was shown,
    /// so a test that called `Toast.show` itself would assert nothing.
    func debugShowCompletionToast(_ message: String) { showToastIfOnScreen(message) }
    #endif

    private func showToastIfOnScreen(_ message: String) {
        guard !view.isHidden, let container = view.window?.contentView else { return }
        Toast.show(in: container, message: message)
    }

    // MARK: Stats strip

    // MARK: Daylight §6.4 - the drill header's live line

    /// Read straight off the same `rows` array the four stat tiles above are
    /// built from, so the header and the tiles can never disagree.
    var drillHeaderSubtitle: String? {
        // Phase 3's honesty rule (a first pass still running is "checking",
        // not "0 updates") lives in `UpdatesSummary.subtitle` now.
        summary.subtitle
    }

    /// R2-BUG-03: the one count of this page's rows that its toast, header
    /// and strip all render.
    var summary: UpdatesSummary { UpdatesSummary(rows.map(\.status)) }

    var onDrillSubtitleChanged: (() -> Void)?

    /// **Deliberately empty.** This page carries its own actions in its own
    /// toolbar or card header a few points below the drill header -
    /// its Refresh pill, which swaps for a determinate progress bar and a live
    /// "Checking… (N/M)" count while a sweep runs. Hoisting a copy of one
    /// would either duplicate a control §6.4's cluster exists to
    /// de-duplicate, or separate the button from the state it reports. The
    /// header still earns its place through the live subtitle above, which is
    /// the signal this page states nowhere else in one line.
    ///
    /// Carried over verbatim from `SetupContainerController`'s own (equally
    /// empty) cluster, which made this same call for all four Engineering
    /// setup pages at once before `fm/grandline-separate-setup-destinations`
    /// gave each of them its own destination.
    var drillHeaderActions: [NSView] { [] }

    func renderStats() {
        // Every path that changes a row's status already lands here (initial
        // check, a single check/update, the check-all sweep), so this is the
        // one place the header's line has to be re-read from.
        onDrillSubtitleChanged?()
        publishToolUpdateSignal()
        let summary = self.summary
        // B9 (`data/grand-line-e2e-audit/report.md`): "0 Updates Available"
        // while 13 checks are still running is a confident claim about an
        // answer this page does not have yet - GL-14. Only the two *derived*
        // counts go unknown. "Tools installed" is the catalog's own size and
        // is true before any check runs. R2-BUG-03: "Need attention" is the
        // header's own count, not a second one that left out failed checks.
        let known = summary.isKnown
        summaryStrip.configure([
            .init(.value("\(summary.total)"), caption: "Tools installed"),
            known ? .count(summary.upToDate, caption: "Up to date") : .init(.unread, caption: "Up to date"),
            known ? .count(summary.needsAttention, caption: "Need attention", tintWhenNonZero: .warn)
                  : .init(.unread, caption: "Need attention"),
            .init(.value(relativeLastChecked()), caption: "Last checked"),
        ], theme: theme)
        if drawsSidebarLayout {
            toolsLastChecked.stringValue = lastCheckedAt == nil ? "not checked yet" : "checked \(relativeLastChecked())"
        }
    }

    /// `fm/grandline-engineering-cards-stale-counts`: hand the freshly-learned
    /// statuses to the one place that counts them.
    ///
    /// The captain updated every tool here and then watched the Engineering
    /// hub go on saying "3 updates" - because the hub renders
    /// `BackgroundSignalsPoller.lastCounts`, which only that poller's own
    /// 15-minute pass could write. This page holds the fresher truth the
    /// moment a check returns, so it publishes the **statuses**, never a
    /// count: the derivation (and its "a pending sweep is not an answer"
    /// rule) stays in one place, so this page cannot drift from the hub over
    /// what "needs an update" means.
    ///
    /// Gated on being on screen so that the hub agrees with what the captain
    /// last actually saw here. A page mounted but hidden is re-rendered by
    /// ordinary events (a theme change, a font-scale change) and its rows can
    /// be older than the poller's own last sweep - it has no business
    /// overwriting a fresher published number from behind another page.
    private func publishToolUpdateSignal() {
        guard isViewLoaded, !view.isHidden else { return }
        // `fm/grandline-notification-center-redesign`: the notification row for
        // this page expands into the tools themselves, so the statuses travel
        // with the names and version pairs that only this page holds - plus the
        // two real actions, per-tool and bulk. The counting rule above is
        // untouched; this is extra detail hung off the same publish, never a
        // second source of "how many need an update".
        //
        // `fm/grandline-notification-ambient-expand-fix`: built through
        // `NotificationSignalChildren`, which the poller's own ambient pass
        // also uses - the captain sees that one first (it is what populates
        // the popover at launch), and two mappings are how the same row comes
        // to read one way before this page is opened and another way after.
        let pending = rows.filter { $0.status.showsUpdateButton }
        let children = NotificationSignalChildren.tools(
            rows.map { .init(id: $0.item.id, name: $0.item.name, status: $0.status, detail: $0.detail) },
            perform: { [weak self] id in self?.requestUpdateFromNotification(toolID: id) })
        // R2-PERF-05: stamped with the newest answer on the page. A visit
        // that showed only answers kept from an earlier launch must not pass
        // for a fresh reading and displace the poller's newer one (PR #395's
        // rule). A row just checked or updated is now, as it always was.
        BackgroundSignalsPoller.shared.publishToolStatuses(
            rows.map { $0.status },
            children: children,
            updateAll: pending.isEmpty ? nil : { [weak self] in self?.updateAllPending() },
            gatheredAt: rows.compactMap(\.checkedAt).max() ?? Date()
        )
    }

    /// Update every tool currently offering an Update button, one at a time.
    ///
    /// Serial on purpose, matching `GitHubSyncController.syncAll` and
    /// `AutomationController.installAllMissing`: this page's standing rule is
    /// that two external-tool invocations never race. Reached only from the
    /// notification popover's "Update all" - the page's own rows each have
    /// their own button, and adding a second bulk control to the page is not
    /// what the redesign asked for.
    private func updateAllPending() {
        guard !isUpdatingAll else { return }
        let targets = rows.filter { $0.status.showsUpdateButton && !$0.isBusy }
        guard !targets.isEmpty else { return }
        isUpdatingAll = true
        func runNext(_ index: Int) {
            guard index < targets.count else {
                isUpdatingAll = false
                publishToolUpdateSignal()
                return
            }
            update(targets[index]) { runNext(index + 1) }
        }
        runNext(0)
    }

    private func relativeLastChecked() -> String {
        guard let lastCheckedAt else { return "\u{2014}" }
        let seconds = max(0, Int(Date().timeIntervalSince(lastCheckedAt)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    // MARK: Filtering

    /// Hides rows whose name doesn't match the live search field (case-
    /// insensitive substring) or, when the "Needs attention" segment is
    /// active, whose status isn't one that already surfaces an action
    /// (`DependencyStatus.showsUpdateButton` - the same set the stats strip's
    /// "Updates Available" tile counts) - collapses the separator that would
    /// otherwise sit next to a hidden row, and hides a whole category card
    /// once none of its rows match. An empty query with "All" selected shows
    /// everything.
    private func applyFilter() {
        // The sidebar layout filters its one table; the category cards are
        // the floating bar's and stay hidden there.
        if drawsSidebarLayout {
            renderToolsTable()
            return
        }
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for section in categorySections {
            var anyVisible = false
            for row in section.rows {
                let matchesQuery = q.isEmpty || row.item.name.lowercased().contains(q)
                let matchesMode = filterMode == .all || row.status.showsUpdateButton
                let matches = matchesQuery && matchesMode
                row.rowContainer.isHidden = !matches
                if matches { anyVisible = true }
            }
            section.background.isHidden = !anyVisible
            for i in section.separators.indices {
                let rowVisible = !section.rows[i].rowContainer.isHidden
                let laterVisible = section.rows[(i + 1)...].contains { !$0.rowContainer.isHidden }
                section.separators[i].isHidden = !(rowVisible && laterVisible)
            }
        }
    }

    // MARK: Card chrome

    func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(v)
        return v
    }

    // MARK: Row

    func row(for sender: NSButton) -> UpdateRow? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return rows.first { $0.item.id == raw }
    }

    // MARK: Check

    /// `completion` fires on the main queue once this row's check settles -
    /// `checkAll` uses it to drive the header's "Checking… (N/M)" progress
    /// and the completion toast without polling row state.
    ///
    /// Reads/writes the shared `DependencyCheckCache` instead of calling
    /// `UpdatesSource.check(row.item)` directly, so this row's first-visit
    /// check can come back from Bootstrap's or Automation's own earlier
    /// sweep of the same tool at no subprocess cost - `forceRefresh` is what
    /// every explicit "Check"/"Refresh" caller sets to `true` to bypass that
    /// and get the real, live answer.
    func check(_ row: UpdateRow, forceRefresh: Bool = false, completion: (() -> Void)? = nil) {
        guard !row.isBusy else {
            completion?()
            return
        }
        row.status = .checking
        row.detail = "Checking\u{2026}"
        row.checkButton.isEnabled = false
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checked = DependencyCheckCache.shared.checkDated(row.item, forceRefresh: forceRefresh)
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }
                self.apply(checked.outcome, gatheredAt: checked.gatheredAt, to: row)
                completion?()
            }
        }
    }

    /// One check's answer on its row.
    private func apply(_ outcome: CheckOutcome, gatheredAt: Date, to row: UpdateRow) {
        row.status = outcome.status
        row.latestLabel = outcome.latestLabel
        row.installedLabel = outcome.installedLabel
        row.detail = outcome.detail
        row.log = outcome.log
        row.terminalCommand = nil
        row.checkedAt = gatheredAt
        row.checkButton.isEnabled = true
        render(row)
    }

    // MARK: Update

    func runInTerminal(_ row: UpdateRow) {
        guard let command = row.terminalCommand, let onRunCommandTracked else { return }
        onRunCommandTracked("Update \(row.item.name)", command) { [weak self] _ in
            DispatchQueue.main.async { self?.check(row, forceRefresh: true) }
        }
    }

    /// Run one tool's real update, asked for from the notification popover's
    /// expanded row (`fm/grandline-notification-ambient-expand-fix`).
    ///
    /// Reached two ways, and deliberately the same way for both: this page's
    /// own publish routes its children here, and so does
    /// `AppShellController.updateToolFromNotification` for a press that
    /// happened before this page had ever been mounted. Everything below the
    /// entry point is the page's ordinary path - the same confirmation, the
    /// same busy state, the same log, toast and post-update re-check.
    ///
    /// The one wrinkle is timing. A first visit mounts this page and
    /// `viewWillAppear` immediately starts a 13-item sweep, so the request
    /// usually arrives mid-sweep - and `update(_:)` would read a row whose
    /// status is `.checking`. So a request that lands during a sweep is
    /// queued and run when the sweep settles, against the row's real,
    /// just-learned status: a tool that turned out to be up to date after all
    /// is quietly dropped rather than updated on the strength of a reading
    /// the popover took minutes ago.
    func requestUpdateFromNotification(toolID: String) {
        guard isViewLoaded else { return }
        guard !isCheckingAll else {
            if !pendingNotificationUpdates.contains(toolID) {
                pendingNotificationUpdates.append(toolID)
            }
            return
        }
        guard let row = rows.first(where: { $0.item.id == toolID }) else { return }
        confirmAndUpdate(row)
    }

    /// Tool ids whose Update was pressed while a check sweep was in flight.
    private var pendingNotificationUpdates: [String] = []

    private func runPendingNotificationUpdates() {
        let requested = pendingNotificationUpdates
        pendingNotificationUpdates = []
        for id in requested {
            guard let row = rows.first(where: { $0.item.id == id }),
                  row.status.showsUpdateButton else { continue }
            confirmAndUpdate(row)
        }
    }

    /// Firstmate's row gets an explicit before-acting summary (commit count +
    /// target) per the safety principle - every other row's summary is
    /// already visible in its subtitle (`row.detail`, e.g. "0.2.3 → 0.2.4"),
    /// so a second confirmation dialog for those would just repeat what Check
    /// already showed with no new information the captain needs to decide.
    func confirmAndUpdate(_ row: UpdateRow) {
        guard case .firstmate = row.item.kind else {
            update(row)
            return
        }
        // G3: themed. Return still performs it, as it did here.
        let fresh = row.status == .notInstalled
        guard HelmConfirm.confirm(
            title: fresh ? "Install firstmate from upstream?" : "Sync firstmate with upstream?",
            body: "\(row.detail)\n\nThis fast-forwards the local default branch to kunchenguid/firstmate's upstream, then pushes the result to origin (your fork). Never forced, never a merge commit.",
            confirmTitle: fresh ? "Install and Push" : "Sync and Push",
            symbol: "arrow.triangle.branch",
            hue: RailDestination.updates.domainHue) else { return }
        update(row)
    }

    /// `completion` fires once the update (and the confirming re-check it
    /// kicks off) has been dispatched for this row - what `updateAllPending`
    /// needs to run the next one rather than racing it.
    private func update(_ row: UpdateRow, completion: (() -> Void)? = nil) {
        guard !row.isBusy else {
            completion?()
            return
        }
        row.isBusy = true
        row.status = .updating
        render(row)
        // REL-05: a quit during an install asks first, and on yes stops the
        // install's subprocess (SIGTERM) instead of closing its pipes under it.
        let work = QuitGuard.shared.begin("Updating \(row.item.name)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = SubprocessCancellation.withScope(work.token) { UpdatesSource.update(row.item) }
            DispatchQueue.main.async {
                defer { QuitGuard.shared.end(work.id) }
                guard let self else { return }
                self.apply(outcome, to: row)
                completion?()
            }
        }
    }

    /// Where every finished update lands, success or not.
    private func apply(_ outcome: UpdateOutcome, to row: UpdateRow) {
        row.isBusy = false
        // What the row now says was just learned.
        row.checkedAt = Date()
        row.log = outcome.log
        row.terminalCommand = outcome.terminalCommand
        if outcome.ok {
            row.status = .upToDate
            row.detail = outcome.detail
            showSuccess(row: row, outcome: outcome)
        } else {
            row.status = .updateFailed
            row.detail = outcome.detail
        }
        render(row)
        // Re-run a real Check right after so the row's status/labels
        // reflect the machine's true state rather than the update
        // command's own self-report - matches every other row's
        // "Check is the source of truth for status" contract.
        // `forceRefresh: true`: this row's own cache entry is now
        // stale by definition (the tool just changed underneath it),
        // so this must never read it back - and forcing it here also
        // refreshes the shared cache with the truth for the other
        // two pages.
        if outcome.ok { check(row, forceRefresh: true) }
    }

    private func showSuccess(row: UpdateRow, outcome: UpdateOutcome) {
        let message = "\(row.item.name) updated to \(outcome.newVersionLabel ?? "latest")"
        // B8: same gate. An update is slower than a check, so this is the more
        // likely of the two to land on a page the captain has moved on to -
        // and the `notify` below is the off-screen half either way.
        showToastIfOnScreen(message)
        notify(title: "\(row.item.name) updated", body: message)
    }

    /// Step 4: a macOS notification for the same completion event, so the
    /// captain can tell it finished even while the app isn't focused.
    /// Permission is requested gracefully and a denial only skips the
    /// notification - the toast above already fired regardless.
    private func notify(title: String, body: String) {
        // `UNUserNotificationCenter.current()` throws an uncaught
        // NSException ("bundleProxyForCurrentProcess is nil") when the
        // running process has no real Info.plist/bundle identifier - true
        // for `swift run`/the bare `.build/debug/GrandLine` binary the
        // README documents as the normal dev workflow. Confirmed live: this
        // crashed every time under that workflow until this guard was added;
        // the packaged app (`build_native_app.sh`'s output, a real bundle)
        // is unaffected either way. The in-app toast already fired
        // regardless, matching the same "denial only skips the
        // notification" fallback this method already applies below.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.postNotification(title: title, body: body)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Self.postNotification(title: title, body: body) }
                }
            default:
                break // denied - the in-app toast already covered it.
            }
        }
    }

    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = NotificationBannerCopy.updatesSource
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fm.update.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Render

    /// UI-51: a row shows its status only when it differs from the page's
    /// most common quiet state, which the drill header already states once
    /// ("13 tools · not checked yet") - `ToolRowLayout.statusHidden`, the rule
    /// GitHub Sync uses. Re-decided for every row on any change, because one
    /// row's change can move the page's baseline.
    private func applyStatusVisibility() {
        let hidden = ToolRowLayout.statusHidden(rows.map { row in
            let (word, _, style) = pillVisuals(row)
            return (word, style, row.status == .checking || row.status == .updating)
        })
        for (row, hide) in zip(rows, hidden) { row.pill.isHidden = hide }
    }

    private func render(_ row: UpdateRow) {
        row.detailLabel.stringValue = row.detail
        row.logField.stringValue = row.log.isEmpty ? "No output yet." : row.log

        // The pill itself is painted by `applyThemeToRow` (called further
        // down this method), not here - see that method's own note for why
        // the theme pass has to be the single owner of it.
        let busy = row.status == .checking || row.status == .updating
        // U10: not in every state - see `DependencyStatus.showsCheckButton`.
        row.checkButton.isHidden = busy || !row.status.showsCheckButton
        // `.notInstalled` shows the distinct "Install in Bootstrap ->" link
        // instead of Update - every other status that `showsUpdateButton`
        // keeps its existing Update button unchanged.
        let needsTerminal = row.terminalCommand != nil
        row.updateButton.isHidden = busy || !row.status.showsUpdateButton || row.status == .notInstalled || needsTerminal
        row.runInTerminalButton.isHidden = busy || !needsTerminal
        row.installInBootstrapButton.isHidden = busy || row.status != .notInstalled
        row.statusSkeleton.isHidden = !busy
        row.progressLabel.isHidden = !busy
        row.progressLabel.stringValue = row.status == .updating ? "Updating\u{2026}" : "Checking\u{2026}"

        let disabled = row.isBusy
        row.checkButton.isEnabled = !disabled
        row.updateButton.isEnabled = !disabled
        row.installInBootstrapButton.isEnabled = !disabled
        row.runInTerminalButton.isEnabled = !disabled
        row.rowContainer.alphaValue = disabled ? 0.6 : 1.0

        applyThemeToRow(row)
        applyStatusVisibility()
        renderStats()
        // A status change can move this row in/out of the "Needs attention"
        // set - keep the current filter's visible rows in sync.
        if !categorySections.isEmpty { applyFilter() }
    }

    /// UI-43: a row's status is a dot and a word while it is the default
    /// ("Up to Date", "Not Checked") and a `HelmStatusPill` only when it is
    /// not. Tints, never the terminal's ANSI slots (UI-32).
    ///
    /// An update that was not started because it needs the captain's
    /// password has not failed, so it reads as a warning that asks for them
    /// rather than as a red failure.
    private func pillVisuals(_ row: UpdateRow) -> (String, HelmTint, HelmStatusPill.Style) {
        if row.status == .updateFailed, row.terminalCommand != nil { return ("Needs Password", .warn, .pill) }
        switch row.status {
        case .unknown: return ("Not Checked", .neutral, .dotWord)
        case .checking, .updating: return ("", .neutral, .dotWord)
        case .upToDate: return ("Up to Date", .good, .dotWord)
        case .updateAvailable: return ("Update Available", .warn, .pill)
        case .notInstalled: return ("Not Installed", .warn, .pill)
        case .checkFailed: return ("Check Failed", .critical, .pill)
        case .updateFailed: return ("Update Failed", .critical, .pill)
        }
    }

    // MARK: Theme

    private func applyTheme() {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        // The pill owns its own fill, and that is load-bearing rather than
        // tidy. The line this replaced wrote `checkAllPill.layer?
        // .backgroundColor` straight to the CALayer, bypassing
        // `HoverHighlightView`'s own `normalColor`/`hoverColor` tracking - so
        // the first hover cycle's `mouseExited` repainted from a `normalColor`
        // nobody had set, stranding the fill at `.clear` until the next theme
        // change wrote the accent straight back in. That was a real,
        // captain-reported light-mode bug (`UpdatesRefreshButtonThemeSelfTest`
        // carries the full account). It now lives inside `HelmRefreshPill`,
        // which is most of the reason that pill is a shared component: a
        // second page cannot re-derive it wrong.
        checkAllPill.applyTheme(theme)
        // G4: the shared bar carries its own theme + hue, so this page's own
        // theme pass has to hand it over - it does not observe on its own.
        checkAllProgressBar.applyTheme(theme, hue: RailDestination.updates.domainHue)
        checkAllProgressLabel.textColor = HelmTheme.mutedInk(theme)
        filterTabs.applyTheme(theme)
        for card in cards { card.applyTheme(theme) }
        for header in groupHeaders { header.applyTheme(theme) }
        for v in separators {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
        summaryStrip.applyTheme(theme)
        for row in rows { applyThemeToRow(row) }
        if drawsSidebarLayout {
            setupSummary.applyTheme(theme)
            toolsTable.applyTheme(theme)
            toolsLastChecked.textColor = HelmTheme.mutedInk(theme)
            renderToolsTable()
        }
    }

    private func applyThemeToRow(_ row: UpdateRow) {
        let failed = row.status == .checkFailed || (row.status == .updateFailed && row.terminalCommand == nil)
        // Reuses `showsUpdateButton` - the exact predicate already driving
        // the "Needs Attention" filter segment above - as "this row is
        // worth a card/accent-bar treatment," and `pillVisuals` for its
        // color, rather than inventing a second notion of "needs attention"
        // (`fm/grandline-setup-attention-row-style`). A healthy row
        // (`.upToDate`, `.unknown`, or a busy `.checking`/`.updating`) keeps
        // the exact flat/compact look it always has.
        let needsAttention = row.status.showsUpdateButton
        // UI-43: the row that asks the captain to act keeps its button at rest.
        ToolRowLayout.setActionsPinned(row.toolRowViews, needsAttention)
        let (pillText, pillTint, pillStyle) = pillVisuals(row)
        let pillColorHex = pillTint.hex(in: theme)
        // The status pill is painted HERE rather than in `render`, for the
        // reason `GitHubSyncController.applyThemeToRow` states in full: the
        // pill bakes one theme's fill and label tone into its layer, nothing
        // re-resolves them, and `ToolRowLayout.applyTheme` below never
        // touches it - so painting it only on a *status* change left a theme
        // switch mid-sweep with some rows' pills in the old palette and the
        // rest in the new one. The captain saw exactly that here: two rows
        // both reading "Update Available", one a light tan pill and the other
        // a solid dark one, while the amber card border they share (derived
        // from `attentionHex` below, which was already re-resolved on every
        // theme pass) matched correctly on both.
        row.pill.configure(text: pillText, tint: pillTint, style: pillStyle, theme: theme)
        let attentionHex = needsAttention ? pillColorHex : nil
        // §7's "the update row is a warn signal row with an amber primary
        // Update". The warn half was already true - `.updateAvailable`
        // resolves `ansiHex[3]`, the palette's own amber - and §6.5's Daylight
        // branch in `ToolRowLayout.applyTheme` is what turns the border tint
        // into the bar-plus-wash signal treatment. This is the button half:
        // Setup's own domain hue (§2.2 gives amber to Setup as one area), run
        // through `DaylightPalette.primaryButtonFill`'s §2.4 correction so the
        // white label clears 4.5:1.
        //
        // Set per theme rather than once, because `domainHue` also changes a
        // `.primary` button on the twelve palettes (from `accentHex` to the
        // fallback tint) - `nil` there keeps every other palette byte-identical.
        row.updateButton.domainHue = theme.isDaylight ? RailDestination.updates.domainHue : nil
        row.runInTerminalButton.domainHue = theme.isDaylight ? RailDestination.updates.domainHue : nil
        ToolRowLayout.applyTheme(
            row.toolRowViews, theme: theme, detailFailed: failed,
            cardStyle: needsAttention, attentionHex: attentionHex, accentBar: needsAttention
        )
        row.progressLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    // MARK: Probe surface (debug builds only, GL-27)

    var debugRowCount: Int { rows.count }

    /// What one row's action column is ACTUALLY painted with, for the
    /// regression guard on the captain-reported "the Check button is missing
    /// on some rows" bug (`UpdatesActionVisibilitySelfTest`).
    ///
    /// `actionsAlpha` is the reading that matters and is why this reads back
    /// rather than re-deriving: the bug hid the buttons with `alphaValue`,
    /// never `isHidden`, so every `isHidden`-shaped check - and every
    /// `cacheDisplay` render, which ignores `alphaValue` - passed while the
    /// captain was looking at an empty gap.
    struct DebugRowActionState {
        let id: String
        let name: String
        let category: String
        let actionsAlpha: CGFloat
        let checkHidden: Bool
        let updateHidden: Bool
    }

    var debugRowActionStates: [DebugRowActionState] {
        rows.map {
            DebugRowActionState(id: $0.item.id,
                                name: $0.item.name,
                                category: $0.item.category,
                                actionsAlpha: $0.toolRowViews.trailingStack.alphaValue,
                                checkHidden: $0.checkButton.isHidden,
                                updateHidden: $0.updateButton.isHidden)
        }
    }

    /// The summary strip's four figures, as rendered (UI-44).
    var debugSummaryValues: [String] { summaryStrip.debugValues }

    /// The row's hover target and its action column, so a suite can drive
    /// the real `HoverHighlightView` hover path (UI-43).
    func debugRowContainer(atRow index: Int) -> HoverHighlightView? {
        rows.indices.contains(index) ? rows[index].rowContainer : nil
    }
    func debugRowTrailingStack(atRow index: Int) -> NSStackView? {
        rows.indices.contains(index) ? rows[index].trailingStack : nil
    }

    /// The real Check button, so a test can drive its own hover feedback
    /// rather than asserting a colour it computed itself.
    func debugCheckButton(atRow index: Int) -> HelmButton? {
        rows.indices.contains(index) ? rows[index].checkButton : nil
    }

    /// Drives the real status-change path a completed check takes.
    func debugSetStatus(_ status: DependencyStatus, atRow index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].status = status
        rows[index].detail = "probe"
        render(rows[index])
    }

    /// Lands an update outcome on a row through the same `apply` a real
    /// Update's completion uses. Failure outcomes only - a success kicks off a
    /// real re-check, which a suite must not reach.
    func debugApplyFailedUpdate(_ outcome: UpdateOutcome, atRow index: Int) {
        guard rows.indices.contains(index), !outcome.ok else { return }
        apply(outcome, to: rows[index])
    }

    /// The row's real buttons and detail, as rendered.
    func debugRowButtons(atRow index: Int) -> (update: HelmButton, runInTerminal: HelmButton, detail: String)? {
        guard rows.indices.contains(index) else { return nil }
        return (rows[index].updateButton, rows[index].runInTerminalButton, rows[index].detailLabel.stringValue)
    }

    /// What the pill is ACTUALLY painted with - see
    /// `GitHubSyncController.debugPillPaint` for why this reads back rather
    /// than re-derives.
    func debugPillPaint(atRow index: Int) -> (fill: CGColor?, label: NSColor?, text: String)? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        return (row.pill.layer?.backgroundColor, row.pill.label.textColor, row.pill.label.stringValue)
    }
    #endif

}

// MARK: - The sidebar layout (stage 7)

// The prototype's Updates: Setup's summary cards, the filter row, and every
// tool in one table - name, installed version, the available version or "Up
// to date", where it comes from, and the row's own action where there is one.
// The rows are the page's own `UpdateRow`s and every action is the method the
// floating bar's row button reaches, so the two layouts check and update one
// way. A tool's detail and its last command output - the floating bar's
// expandable log - are the inspector's.

extension UpdatesController: SidebarLayoutAdopting, WorkspacePrimaryActionProviding, WorkspaceInspectorSource {

    func adoptSidebarLayout() {
        guard !drawsSidebarLayout else { return }
        _ = view
        drawsSidebarLayout = true
        guard let stack = pageStack else { return }
        statsRowView?.isHidden = true
        for card in cards { card.isHidden = true }
        checkAllPill.isHidden = true
        stack.insertArrangedSubview(setupSummary, at: 0)
        setupSummary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        toolsLastChecked.font = HelmType.caption()
        let title = NSTextField(labelWithString: "Tools")
        _ = toolsTable.card.setHeader(symbol: "shippingbox", titleLabel: title, subtitleLabel: toolsLastChecked)
        stack.addArrangedSubview(toolsTable.card)
        toolsTable.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        renderStats()
        applyTheme()
    }

    var workspacePrimaryAction: NSView? { drawsSidebarLayout ? checkForUpdatesButton : nil }

    var inspectorContent: WorkspaceInspectorContent? {
        guard drawsSidebarLayout, let id = selectedToolID, let row = rows.first(where: { $0.item.id == id }) else {
            return nil
        }
        toolDetail.show(toolDetail(for: row))
        return WorkspaceInspectorContent(title: row.item.name, view: toolDetail)
    }

    var inspectorEmptyText: (title: String, body: String) {
        ("No tool selected", "Select a tool to see its versions and the output of its last check or update.")
    }

    /// The tools that pass the filter row, grouped as the floating bar's
    /// cards are.
    fileprivate func renderToolsTable() {
        guard drawsSidebarLayout else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var tableRows: [HelmDataTable.Row] = []
        for category in DependencyCatalog.categoryOrder {
            let matching = rows.filter { row in
                row.item.category == category
                    && (query.isEmpty || row.item.name.lowercased().contains(query))
                    && (filterMode == .all || row.status.showsUpdateButton)
            }
            guard !matching.isEmpty else { continue }
            tableRows.append(.group(category))
            tableRows += matching.map(toolRow)
        }
        if tableRows.isEmpty {
            tableRows = [filterMode == .needsAttention && query.isEmpty
                ? .empty(symbol: "checkmark.seal", title: "Nothing needs attention",
                         body: "Every tool that has been checked is up to date.")
                : .empty(symbol: "magnifyingglass", title: "No tools match",
                         body: "No tool's name contains \u{201C}\(query)\u{201D}.")]
        }
        toolsTable.setRows(tableRows)
        onInspectorContentChanged?()
    }

    private func toolRow(_ row: UpdateRow) -> HelmDataTable.Row {
        var tableRow = HelmDataTable.Row.record(row.item.id)
        let failed = row.status == .checkFailed || row.status == .updateFailed
        tableRow.cells["tool"] = .title(row.item.name, subtitle: failed ? row.detail : nil, subtitleIsCode: false,
                                        symbol: row.item.kind.symbol,
                                        tint: DependencyCatalog.tint(for: row.item.category), tintHex: nil)
        if let installed = row.installedLabel, row.status != .notInstalled {
            tableRow.cells["installed"] = .code(installed)
        } else {
            tableRow.cells["installed"] = HelmDataTable.Cell.none
        }
        tableRow.cells["available"] = availableCell(row)
        tableRow.cells["source"] = .muted(row.item.kind.sourceName)
        let busy = row.status == .checking || row.status == .updating
        if !busy {
            if row.terminalCommand != nil {
                tableRow.primary = .init(title: "Run in Terminal", symbol: "terminal") { [weak self] in
                    self?.runInTerminal(row)
                }
            } else if row.status == .notInstalled {
                tableRow.primary = .init(title: "Install in \(PlaceName.short(.bootstrap))", symbol: "arrow.right") { [weak self] in
                    self?.onNavigateToBootstrap?()
                }
            } else if row.status == .updateAvailable || row.status == .updateFailed {
                tableRow.primary = .init(title: "Update", symbol: "arrow.down.circle") { [weak self] in
                    self?.confirmAndUpdate(row)
                }
            } else if row.status.showsCheckButton {
                tableRow.primary = .init(title: "Check", symbol: "arrow.clockwise") { [weak self] in
                    self?.check(row, forceRefresh: true)
                }
            }
            // The row that asks the captain to act keeps its button in sight.
            tableRow.pinsPrimary = row.status.showsUpdateButton
            var menu: [HelmDataTable.Action] = []
            if tableRow.primary?.title != "Check" {
                menu.append(.init(title: "Check Now", symbol: "arrow.clockwise") { [weak self] in
                    self?.check(row, forceRefresh: true)
                })
            }
            if row.status == .checkFailed {
                menu.append(.init(title: "Update", symbol: "arrow.down.circle") { [weak self] in
                    self?.confirmAndUpdate(row)
                })
            }
            menu.append(.init(title: "Show Details", symbol: "sidebar.right") { [weak self] in
                self?.showDetails(row)
            })
            tableRow.menu = menu
        }
        tableRow.activate = { [weak self] in self?.showDetails(row) }
        return tableRow
    }

    /// The available version, or what stands in its place: "Up to date", or
    /// the row's state while it has no version to offer.
    private func availableCell(_ row: UpdateRow) -> HelmDataTable.Cell {
        switch row.status {
        case .upToDate: return .muted("Up to date")
        case .updateAvailable:
            return .status("\u{2191} \(row.latestLabel ?? "newer version")", tint: .warn)
        case .notInstalled:
            return .status(row.latestLabel.map { "Not installed \u{00B7} \($0)" } ?? "Not installed", tint: .warn)
        case .checking: return .muted("Checking\u{2026}")
        case .updating: return .muted("Updating\u{2026}")
        case .checkFailed: return .status("Check failed", tint: .critical)
        case .updateFailed:
            return row.terminalCommand != nil ? .status("Needs password", tint: .warn)
                                              : .status("Update failed", tint: .critical)
        case .unknown: return .muted("Not checked")
        }
    }

    private func showDetails(_ row: UpdateRow) {
        toolsTable.select(key: row.item.id)
        selectedToolID = row.item.id
        onInspectorContentChanged?()
        onShowInspector?()
    }

    private func toolDetail(for row: UpdateRow) -> WorkspaceDetail {
        var detail = WorkspaceDetail(symbol: row.item.kind.symbol, kicker: row.item.category, title: row.item.name,
                                     subtitle: row.detail)
        detail.tint = DependencyCatalog.tint(for: row.item.category)
        if let installed = row.installedLabel, row.status != .notInstalled {
            detail.fields.append(.init("Installed", installed, isCode: true))
        }
        if let latest = row.latestLabel { detail.fields.append(.init("Latest", latest, isCode: true)) }
        detail.fields.append(.init("Source", row.item.kind.sourceName))
        let (word, _, _) = pillVisuals(row)
        if !word.isEmpty { detail.fields.append(.init("Status", word)) }
        if let command = row.terminalCommand { detail.sections.append(.init("Command", [command], isCode: true)) }
        let lines = row.log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        detail.sections.append(.init("Output", row.log.isEmpty ? ["No output yet."] : lines, isCode: !row.log.isEmpty))
        let busy = row.status == .checking || row.status == .updating
        if !busy {
            if row.terminalCommand != nil {
                detail.actions.append(.init("Run in Terminal", symbol: "terminal", role: .primary) { [weak self] in
                    self?.runInTerminal(row)
                })
            } else if row.status == .notInstalled {
                detail.actions.append(.init("Install in \(PlaceName.short(.bootstrap))", symbol: "arrow.right", role: .primary) { [weak self] in
                    self?.onNavigateToBootstrap?()
                })
            } else if row.status.showsUpdateButton {
                detail.actions.append(.init("Update", symbol: "arrow.down.circle", role: .primary) { [weak self] in
                    self?.confirmAndUpdate(row)
                })
            }
            detail.actions.append(.init("Check Now", symbol: "arrow.clockwise") { [weak self] in
                self?.check(row, forceRefresh: true)
            })
        }
        return detail
    }
}

extension DependencyKind {
    /// Where the tool comes from, as the sidebar layout's Source column says
    /// it - read off how `UpdatesSource` checks and updates it.
    var sourceName: String {
        switch self {
        case .npmGlobal: return "npm"
        case .brewFormula, .brewCask, .herdr: return "Homebrew"
        case .noMistakes: return "no-mistakes"
        case .firstmate: return "GitHub"
        case .docs: return "GitHub Pages"
        }
    }
}

#if FM_SELFTESTS
extension UpdatesController {
    var debugDrawsSidebarLayout: Bool { drawsSidebarLayout }
    /// Whether any of the floating bar's category cards, or its stat strip,
    /// is drawn.
    var debugCategoryCardsShown: Bool { cards.contains { !$0.isHidden } }
    var debugStatsStripShown: Bool { !(statsRowView?.isHidden ?? true) }
    var debugToolsTable: HelmDataTable { toolsTable }
    var debugSetupSummary: SetupSummaryRow { setupSummary }
    var debugCheckForUpdatesButton: HelmButton { checkForUpdatesButton }
    var debugToolsLastChecked: String { toolsLastChecked.stringValue }
    /// The filter row's two controls, driven through their own paths.
    func debugSetFilter(needsAttention: Bool) {
        filterTabs.debugClickTab(id: needsAttention ? "needsAttention" : "all")
    }
    /// "2h ago" - the Last checked figure, as the page draws it.
    var debugLastCheckedText: String { relativeLastChecked() }
    var debugIsCheckingAll: Bool { isCheckingAll }
    var debugRowStatuses: [String: DependencyStatus] {
        Dictionary(rows.map { ($0.item.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }
    func debugSetQuery(_ query: String) {
        searchField.stringValue = query
        searchField.onTextChanged?(query)
    }
    /// Land a fixture check result on a row through the same fields a real
    /// check writes, then the page's own render.
    func debugApplyOutcome(id: String, status: DependencyStatus, installed: String?, latest: String?,
                           detail: String = "fixture", log: String = "") {
        guard let row = rows.first(where: { $0.item.id == id }) else { return }
        row.status = status
        row.installedLabel = installed
        row.latestLabel = latest
        row.detail = detail
        row.log = log
        render(row)
    }
}
#endif
