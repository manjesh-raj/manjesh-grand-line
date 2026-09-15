// Manjesh Grand Line - native macOS app.
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
private final class UpdateRow {
    let item: DependencyItem
    var status: DependencyStatus = .unknown
    var latestLabel: String?
    var detail: String = "Not checked yet"
    var log: String = ""
    var isLogExpanded = false
    var isBusy = false

    let iconTile = IconTileView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = NSView()
    let pillLabel = NSTextField(labelWithString: "")
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
    let installInBootstrapButton = HelmButton(title: "Install in Bootstrap \u{2192}", variant: .quiet, size: .small)
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    /// Swapped between [pill, checkButton, updateButton] and
    /// [spinner, progressLabel] depending on `isBusy`.
    let trailingStack = NSStackView()

    /// This row's fields, packaged for the shared `ToolRowLayout` assembly.
    var toolRowViews: ToolRowLayout.Views {
        ToolRowLayout.Views(
            iconTile: iconTile, nameLabel: nameLabel, detailLabel: detailLabel,
            pill: pill, pillLabel: pillLabel, trailingStack: trailingStack,
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
    private struct CategorySection {
        let background: NSView
        let rows: [UpdateRow]
        let separators: [NSView]
    }

    /// `String`-backed so it can be the id `HelmSegmentedTabs` hands back - the
    /// shared component deals in caller-owned ids rather than indices.
    private enum ToolFilterMode: String { case all, needsAttention }

    private var rows: [UpdateRow] = DependencyCatalog.items.map(UpdateRow.init)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    private var cards: [HelmCard] = []
    private var separators: [NSView] = []
    private var categorySections: [CategorySection] = []

    /// The summary strip's four tiles. Each themes itself; this list is what
    /// `renderStats` writes the numbers into and `applyTheme` hands the theme to.
    private var statTiles: [HelmStatTile] = []
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
    private var lastCheckedAt: Date?
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

        let header = buildHeader()
        let statsRow = buildStatsRow()
        let toolbarRow = buildToolbarRow()
        var sections: [NSView] = [header, statsRow, toolbarRow]
        for category in DependencyCatalog.categoryOrder {
            let categoryRows = rows.filter { $0.item.category == category }
            guard !categoryRows.isEmpty else { continue }
            sections.append(card(icon: iconFor(category: category), title: category, rows: categoryRows))
        }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(18, after: statsRow)
        stack.setCustomSpacing(18, after: toolbarRow)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
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

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
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
        lastCheckedTimer?.invalidate()
        lastCheckedTimer = nil
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Header

    private let subtitleLabel = NSTextField(labelWithString: "Every tool in the fleet, checked against its real source - npm, Homebrew, herdr, no-mistakes, and firstmate's own upstream.")

    private func buildHeader() -> NSView {
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.preferredMaxLayoutWidth = 560
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        return subtitleLabel
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
    private let checkAllPill = HelmRefreshPill(
        title: "Refresh", tooltip: "Check all tools for updates")
    private let checkAllProgressBar = HelmProgressBar()
    private let checkAllProgressLabel = NSTextField(labelWithString: "")
    private var isCheckingAll = false

    #if FM_SELFTESTS
    /// GL-16-style probe surface: exposes the exact view a self-test needs
    /// to read to prove the Refresh pill's fill survives a hover cycle,
    /// without loosening any of this file's own access levels for
    /// production callers.
    var checkAllPillForTests: HoverHighlightView { checkAllPill }

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

        checkAllProgressLabel.font = .systemFont(ofSize: 11, weight: .medium)
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

    private func checkAll(forceRefresh: Bool = false) {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        checkAllPill.isHidden = true
        checkAllProgressBar.isHidden = false
        checkAllProgressLabel.isHidden = false

        let total = rows.count
        checkAllProgressBar.configure(fraction: 0)
        checkAllProgressLabel.stringValue = "Checking\u{2026} (0/\(total))"

        var completed = 0
        for row in rows {
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
        checkAllPill.isHidden = false
        checkAllProgressBar.isHidden = true
        checkAllProgressLabel.isHidden = true
        lastCheckedAt = Date()
        renderStats()

        let updateCount = rows.filter { $0.status.showsUpdateButton }.count
        let message = updateCount > 0
            ? "Checked \(rows.count) tools, \(updateCount) update\(updateCount == 1 ? "" : "s") available"
            : "Checked \(rows.count) tools - all up to date"
        if let container = view.window?.contentView {
            Toast.show(in: container, message: message)
        }
    }

    // MARK: Stats strip

    /// The four-tile summary strip, built from the app's shared `HelmStatTile`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 4). This page's own copy
    /// was the loudest of the three the audit measured - a 19pt **bold** metric
    /// at 15/13 padding on a `surface @ 0.60` fill, 67pt tall against Overview's
    /// 50 - for the same job. Two behaviours are unchanged: the per-tile
    /// neutral/success/warning signal (now a `HelmTint`, and contrast-corrected
    /// rather than painted as the raw hue - audit §5.7), and `renderStats`
    /// writing only the numbers.
    private func buildStatsRow() -> NSView {
        statTiles = [
            HelmStatTile(symbol: "shippingbox", value: "0", caption: "Tools Installed"),
            HelmStatTile(symbol: "checkmark.circle", value: "0", caption: "Up to Date", tint: .good),
            HelmStatTile(symbol: "arrow.up.circle", value: "0", caption: "Updates Available", tint: .warn),
            HelmStatTile(symbol: "clock", value: "0", caption: "Last Checked"),
        ]

        let row = NSStackView(views: statTiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }


    // MARK: Daylight §6.4 - the drill header's live line

    /// Read straight off the same `rows` array the four stat tiles above are
    /// built from, so the header and the tiles can never disagree.
    var drillHeaderSubtitle: String? {
        let total = rows.count
        guard total > 0 else { return "No tools in the catalog" }
        // Phase 3's honesty rule: a first pass still running is "checking",
        // not "0 updates". `.unknown` is the never-checked state.
        if rows.contains(where: { $0.status == .checking || $0.status == .updating }) {
            return "\(total) tools \u{00B7} checking\u{2026}"
        }
        if rows.allSatisfy({ $0.status == .unknown }) { return "\(total) tools \u{00B7} not checked yet" }
        let needsUpdate = rows.filter { $0.status.showsUpdateButton }.count
        if needsUpdate > 0 { return "\(total) tools \u{00B7} \(needsUpdate) need attention" }
        return "\(total) tools \u{00B7} all up to date"
    }

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

    private func renderStats() {
        // Every path that changes a row's status already lands here (initial
        // check, a single check/update, the check-all sweep), so this is the
        // one place the header's line has to be re-read from.
        onDrillSubtitleChanged?()
        publishToolUpdateSignal()
        let total = rows.count
        let upToDate = rows.filter { $0.status == .upToDate }.count
        let needsUpdate = rows.filter { $0.status == .updateAvailable || $0.status == .notInstalled }.count
        guard statTiles.count == 4 else { return }
        // B9 (`data/grand-line-e2e-audit/report.md`): "0 Updates Available"
        // while 13 checks are still running is a confident claim about an
        // answer this page does not have yet - the same GL-14 shape as B1,
        // just quieter (the adjacent "Checking… (1/13)" mitigates it, which is
        // why this is the audit's lowest-severity item rather than a
        // non-issue). `drillHeaderSubtitle` right above already applies exactly
        // this rule to the header; the tiles never followed.
        //
        // Only the two *derived* counts go unknown. "Tools Installed" is the
        // catalog's own size and is true before any check runs.
        let pending = rows.contains { $0.status == .checking || $0.status == .updating }
        let neverChecked = !rows.isEmpty && rows.allSatisfy { $0.status == .unknown }
        let unknown = "\u{2014}"
        statTiles[0].value = "\(total)"
        statTiles[1].value = (pending || neverChecked) ? unknown : "\(upToDate)"
        statTiles[2].value = (pending || neverChecked) ? unknown : "\(needsUpdate)"
        statTiles[3].value = relativeLastChecked()
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
        BackgroundSignalsPoller.shared.publishToolStatuses(rows.map { $0.status })
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

    private func iconFor(category: String) -> String {
        switch category {
        case "npm packages": return "shippingbox"
        case "Homebrew": return "wrench.and.screwdriver"
        case "Other tools": return "gearshape.2"
        case "Documentation": return "book.closed"
        default: return "sailboat"
        }
    }

    /// A per-category tint for each row's `IconTileView` (mirrors the
    /// mockup's blue/red/violet tool-row tiles) - resolved through the shared
    /// `HelmTint` enum (phase 1's `HelmUIComponents.swift`) rather than a raw
    /// hex, so it stays correct across all 8 Helm palettes.
    private func categoryTint(for category: String) -> HelmTint {
        DependencyCatalog.tint(for: category)
    }

    /// One `HelmCard` per tool category - the shared container from
    /// `HelmDesignSystem.swift`, replacing this file's own copy of a card
    /// helper that was byte-for-byte identical in four controllers, plus its
    /// own copy of the theming loop (audit §3.2).
    private func card(icon: String, title: String, rows categoryRows: [UpdateRow]) -> HelmCard {
        var rowViews: [NSView] = []
        var sectionSeparators: [NSView] = []
        for (index, row) in categoryRows.enumerated() {
            // Every row keeps its Check/Update button at rest - see
            // `buildRow`'s own note for the captain report that retired D1's
            // hover-reveal on this page.
            rowViews.append(buildRow(row))
            if index < categoryRows.count - 1 {
                let sep = separator()
                rowViews.append(sep)
                sectionSeparators.append(sep)
            }
        }
        let rowsStack = NSStackView(views: rowViews)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for v in rowViews { v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true }

        let card = HelmCard()
        card.setHeader(symbol: icon, tint: DependencyCatalog.tint(for: title), title: title)
        card.setBody(rowsStack, insets: HelmCard.contentInsets)
        cards.append(card)
        categorySections.append(CategorySection(background: card, rows: categoryRows, separators: sectionSeparators))
        return card
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(v)
        return v
    }

    // MARK: Row

    /// Builds one tool row. Its Check/Update buttons are **always** visible,
    /// never hover-revealed - see the `actionReveal` argument below.
    private func buildRow(_ row: UpdateRow) -> NSView {
        // Check / Update
        row.checkButton.target = self
        row.checkButton.action = #selector(checkTapped(_:))
        row.checkButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)

        row.updateButton.target = self
        row.updateButton.action = #selector(updateTapped(_:))
        row.updateButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.updateButton.isHidden = true

        // `.notInstalled` only - `.quiet` + an accent `tint`, so it reads as
        // "navigate elsewhere" and is never confusable with the accent-filled
        // `.primary` `updateButton` used for every other status. Its label
        // colour used to be a hand-rolled `attributedTitle` in `applyThemeToRow`
        // (`contentTintColor` does not colour a string title) - `tint` is that
        // same idea, shared and contrast-corrected.
        row.installInBootstrapButton.tint = .accent
        row.installInBootstrapButton.target = self
        row.installInBootstrapButton.action = #selector(installInBootstrapTapped(_:))
        row.installInBootstrapButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.installInBootstrapButton.isHidden = true

        // Busy state
        row.progressLabel.font = .systemFont(ofSize: 11, weight: .medium)

        let view = ToolRowLayout.build(
            row.toolRowViews,
            iconSymbol: row.item.kind.symbol,
            tint: categoryTint(for: row.item.category),
            name: row.item.name,
            // Status column: the pill, and the spinner/label that replace
            // it while a check or update runs. Actions stay in their own
            // trailing column (audit §5.4).
            statusViews: [row.pill, row.statusSkeleton, row.progressLabel],
            trailingViews: [row.checkButton, row.updateButton, row.installInBootstrapButton],
            detailsTarget: self,
            detailsAction: #selector(detailsTapped(_:)),
            // This page deliberately opts OUT of D1's hover-reveal
            // (`ToolRowLayout.ActionReveal.onAim`), and must keep doing so.
            //
            // It used to pass `ReviewPRListView.actionReveal(row:of:)`, whose
            // discoverability rule is "a category of three rows or fewer keeps
            // every row's buttons, a longer one keeps only its first row's".
            // On this page's real catalog that resolves to a split the captain
            // reported as broken: "npm packages" has five rows, so `tasks-axi`
            // showed its Check button while `gh-axi`, `chrome-devtools-axi`,
            // `lavish-axi` and `quota-axi` rendered an empty gap beside their
            // status pill - directly above "Homebrew", whose three rows all
            // showed theirs. Two treatments for one kind of row, side by side
            // in one list, with nothing on screen explaining the difference.
            //
            // It also made this page the odd one out among the five that share
            // `ToolRowLayout`: Bootstrap, Automation, GitHub Sync and Vault all
            // take the `.always` default, so a captain moving between them saw
            // the same row component behave two different ways.
            //
            // D1 itself is untouched where it was approved - `HelmAccentRow`'s
            // own mirror of this policy still backs Review's PR list and the
            // Hosts/Keys/Snippets lists.
            actionReveal: .always,
            identifier: row.item.id
        )
        row.logContainer.isHidden = true // collapsed until the details chevron is tapped.
        return view
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(row.toolRowViews, expanded: row.isLogExpanded, log: row.log)
    }

    private func row(for sender: NSButton) -> UpdateRow? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return rows.first { $0.item.id == raw }
    }

    // MARK: Check

    // The row's own "Check" button is this row's explicit re-check
    // affordance, so it always forces a real check rather than serving
    // whatever another page's sweep happened to cache.
    @objc private func checkTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        check(row, forceRefresh: true)
    }

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
    private func check(_ row: UpdateRow, forceRefresh: Bool = false, completion: (() -> Void)? = nil) {
        guard !row.isBusy else {
            completion?()
            return
        }
        row.status = .checking
        row.detail = "Checking\u{2026}"
        row.checkButton.isEnabled = false
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = DependencyCheckCache.shared.check(row.item, forceRefresh: forceRefresh)
            DispatchQueue.main.async {
                guard self != nil else {
                    completion?()
                    return
                }
                row.status = outcome.status
                row.latestLabel = outcome.latestLabel
                row.detail = outcome.detail
                row.log = outcome.log
                row.checkButton.isEnabled = true
                self?.render(row)
                completion?()
            }
        }
    }

    // MARK: Update

    @objc private func updateTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        confirmAndUpdate(row)
    }

    @objc private func installInBootstrapTapped(_ sender: NSButton) {
        onNavigateToBootstrap?()
    }

    /// Firstmate's row gets an explicit before-acting summary (commit count +
    /// target) per the safety principle - every other row's summary is
    /// already visible in its subtitle (`row.detail`, e.g. "0.2.3 → 0.2.4"),
    /// so a second confirmation dialog for those would just repeat what Check
    /// already showed with no new information the captain needs to decide.
    private func confirmAndUpdate(_ row: UpdateRow) {
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

    private func update(_ row: UpdateRow) {
        guard !row.isBusy else { return }
        row.isBusy = true
        row.status = .updating
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = UpdatesSource.update(row.item)
            DispatchQueue.main.async {
                guard let self else { return }
                row.isBusy = false
                row.log = outcome.log
                if outcome.ok {
                    row.status = .upToDate
                    row.detail = outcome.detail
                    self.showSuccess(row: row, outcome: outcome)
                } else {
                    row.status = .updateFailed
                    row.detail = outcome.detail
                }
                self.render(row)
                // Re-run a real Check right after so the row's status/labels
                // reflect the machine's true state rather than the update
                // command's own self-report - matches every other row's
                // "Check is the source of truth for status" contract.
                // `forceRefresh: true`: this row's own cache entry is now
                // stale by definition (the tool just changed underneath it),
                // so this must never read it back - and forcing it here also
                // refreshes the shared cache with the truth for the other
                // two pages.
                if outcome.ok { self.check(row, forceRefresh: true) }
            }
        }
    }

    private func showSuccess(row: UpdateRow, outcome: UpdateOutcome) {
        let message = "\(row.item.name) updated to \(outcome.newVersionLabel ?? "latest")"
        if let container = view.window?.contentView {
            Toast.show(in: container, message: message)
        }
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
        // for `swift run`/the bare `.build/debug/FirstmateCockpit` binary the
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
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fm.update.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Render

    private func render(_ row: UpdateRow) {
        row.detailLabel.stringValue = row.detail
        row.logField.stringValue = row.log.isEmpty ? "No output yet." : row.log

        // The pill itself is painted by `applyThemeToRow` (called further
        // down this method), not here - see that method's own note for why
        // the theme pass has to be the single owner of it.
        let busy = row.status == .checking || row.status == .updating
        row.pill.isHidden = busy
        row.checkButton.isHidden = busy
        // `.notInstalled` shows the distinct "Install in Bootstrap ->" link
        // instead of Update - every other status that `showsUpdateButton`
        // keeps its existing Update button unchanged.
        row.updateButton.isHidden = busy || !row.status.showsUpdateButton || row.status == .notInstalled
        row.installInBootstrapButton.isHidden = busy || row.status != .notInstalled
        row.statusSkeleton.isHidden = !busy
        row.progressLabel.isHidden = !busy
        row.progressLabel.stringValue = row.status == .updating ? "Updating\u{2026}" : "Checking\u{2026}"

        let disabled = row.isBusy
        row.checkButton.isEnabled = !disabled
        row.updateButton.isEnabled = !disabled
        row.installInBootstrapButton.isEnabled = !disabled
        row.rowContainer.alphaValue = disabled ? 0.6 : 1.0

        applyThemeToRow(row)
        renderStats()
        // A status change can move this row in/out of the "Needs attention"
        // set - keep the current filter's visible rows in sync.
        if !categorySections.isEmpty { applyFilter() }
    }

    private func pillVisuals(_ status: DependencyStatus) -> (String, String) {
        switch status {
        case .unknown: return ("Not Checked", theme.chromeInkHex)
        case .checking, .updating: return ("", theme.chromeInkHex)
        case .upToDate: return ("Up to Date", theme.ansiHex[2])
        case .updateAvailable: return ("Update Available", theme.ansiHex[3])
        case .notInstalled: return ("Not Installed", theme.ansiHex[3])
        case .checkFailed: return ("Check Failed", theme.ansiHex[1])
        case .updateFailed: return ("Update Failed", theme.ansiHex[1])
        }
    }

    // MARK: Theme

    private func applyTheme() {
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
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
        for v in separators {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
        for tile in statTiles { tile.applyTheme(theme) }
        for row in rows { applyThemeToRow(row) }
    }

    private func applyThemeToRow(_ row: UpdateRow) {
        let failed = row.status == .checkFailed || row.status == .updateFailed
        // Reuses `showsUpdateButton` - the exact predicate already driving
        // the "Needs Attention" filter segment above - as "this row is
        // worth a card/accent-bar treatment," and `pillVisuals` for its
        // color, rather than inventing a second notion of "needs attention"
        // (`fm/grandline-setup-attention-row-style`). A healthy row
        // (`.upToDate`, `.unknown`, or a busy `.checking`/`.updating`) keeps
        // the exact flat/compact look it always has.
        let needsAttention = row.status.showsUpdateButton
        let (pillText, pillColorHex) = pillVisuals(row.status)
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
        ToolRowLayout.pill(text: pillText, colorHex: pillColorHex,
                           into: row.pill, label: row.pillLabel, theme: theme)
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

    /// What the pill is ACTUALLY painted with - see
    /// `GitHubSyncController.debugPillPaint` for why this reads back rather
    /// than re-derives.
    func debugPillPaint(atRow index: Int) -> (fill: CGColor?, label: NSColor?, text: String)? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        return (row.pill.layer?.backgroundColor, row.pillLabel.textColor, row.pillLabel.stringValue)
    }
    #endif

}
