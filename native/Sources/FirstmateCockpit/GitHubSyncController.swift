// Manjesh Grand Line - native macOS app.
//
// "GitHub Sync" - a new `.githubSync` rail destination, reachable only via the
// Setup flyout's fourth row (alongside Updates, Bootstrap, Automation - see
// `IconRailController.showSetupFlyout()`). Pulls the latest upstream changes
// into each of the captain's personal forks from inside the app, rather than
// by hand per repo (`git fetch upstream && git merge` per clone).
//
// Visual/interaction pattern copied deliberately, not invented:
//   - Page shape (a "sync all" action card + a repo-list card, both built
//     with the same rounded `card(icon:title:content:)` chrome, inside a
//     `FlippedView` + `NSScrollView` for the "empty gap above the header"
//     fix): `AutomationController.swift:179-241` (`loadView`) and its `card`
//     helper at `AutomationController.swift:258-296`. The page led with a
//     wrapping subtitle until the captain had it removed - it restated what
//     the page's own rows already show, and the drill header names the
//     destination one line above it. The Refresh pill took that space.
//   - Per-repo row: `ToolRowLayout` (`HelmUIComponents.swift:176-408`), the
//     exact shared "icon tile + name/detail text + trailing pill/buttons +
//     expandable command-output log" assembly `UpdatesController`'s per-tool
//     rows already use (`UpdatesController.swift:643-692` builds a row;
//     `UpdatesController.swift:715-740`/`778-805` is the check/update
//     busy-state and re-check-after-action pattern this file's `check(_:)`/
//     `sync(_:)` mirror for check/sync instead).
//   - "Sync all" progress reporting: `UpdatesController.checkAll()`
//     (`UpdatesController.swift:389-428`) - a running "N/M" count while a
//     bulk action is in flight, then a `Toast` summary on completion.
//
// Every actual GitHub operation goes through `GitHubSyncSource`
// (`GitHubSyncData.swift`) - this file only renders state and dispatches
// background-queue calls, exactly like `UpdatesController`/`FleetController`.

import AppKit

private final class GitHubSyncRow {
    let repo: GitHubSyncRepoConfig
    var status: GitHubSyncStatus = .unknown
    var upstreamFullName: String?
    var detail: String = "Not checked yet"
    var log: String = ""
    var isLogExpanded = false
    /// True while either a check or a sync is running for this row - guards
    /// against double-firing the same row from two places (a row's own
    /// button and "Sync all" running concurrently).
    var isBusy = false

    let iconTile = IconTileView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = NSView()
    let pillLabel = NSTextField(labelWithString: "")
    /// D3: a redacted pill in the shape of the status that is coming - see
    /// `UpdatesController`'s own `statusSkeleton` for the reasoning.
    let statusSkeleton = HelmSkeletonRow(shape: .pill)
    let progressLabel = NSTextField(labelWithString: "")
    let syncButton = HelmButton(title: "", variant: .secondary)
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    let trailingStack = NSStackView()

    var toolRowViews: ToolRowLayout.Views {
        ToolRowLayout.Views(
            iconTile: iconTile, nameLabel: nameLabel, detailLabel: detailLabel,
            pill: pill, pillLabel: pillLabel, trailingStack: trailingStack,
            detailsButton: detailsButton, logField: logField, logContainer: logContainer,
            rowContainer: rowContainer
        )
    }

    init(repo: GitHubSyncRepoConfig) { self.repo = repo }
}

final class GitHubSyncController: NSViewController, DaylightDrillActions {

    private var rows: [GitHubSyncRow] = GitHubSyncCatalog.repos.map(GitHubSyncRow.init)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    private var cards: [HelmCard] = []
    private var separators: [NSView] = []
    private var hasCheckedOnce = false
    private var isSyncingAll = false

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

        // Review #3's UI5. Two separate findings on this page, and one
        // rearrangement answers both:
        //
        //  - A whole card titled "Sync All" whose entire content was a button
        //    titled "Sync All". A card is a container for a *section*; when the
        //    section is one control, the card is the control's label written
        //    twice with a border round it.
        //  - "Checking\u{2026} (0/8)" floating alone in an otherwise empty
        //    40pt row. That row is this page's toolbar, and `beginCheckingAll`
        //    hides the Refresh pill while a sweep runs - so for the length of
        //    the sweep the row holds one small string and nothing else.
        //
        // Both actions belong to the repo list: Sync All syncs the rows below
        // it, and Refresh re-checks those same rows. So they move into the
        // Repos card's own header, which is where this app puts a section's
        // actions everywhere else (Vault's "+ Add Secret", Poneglyph's list
        // header). The page then has one card, the actions are attached to
        // what they act on, and there is no row left for anything to float in.
        buildToolbarControls()
        let syncAllSummary = buildSyncAllSummary()

        var rowViews: [NSView] = []
        for (index, row) in rows.enumerated() {
            rowViews.append(buildRow(row))
            if index < rows.count - 1 {
                rowViews.append(separator())
            }
        }
        let rowsStack = NSStackView(views: rowViews)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for v in rowViews { v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true }

        // The summary line Sync All writes sits at the top of the list it
        // describes, where the "Sync All" card used to carry it.
        let reposBody = NSStackView(views: [syncAllSummary, rowsStack])
        reposBody.orientation = .vertical
        reposBody.alignment = .leading
        reposBody.spacing = 10
        reposBody.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.widthAnchor.constraint(equalTo: reposBody.widthAnchor).isActive = true
        syncAllSummary.widthAnchor.constraint(equalTo: reposBody.widthAnchor).isActive = true

        let reposCard = HelmCard()
        _ = reposCard.setHeader(symbol: "point.3.connected.trianglepath.dotted",
                                title: "Repos (\(rows.count))",
                                actions: [refreshProgressLabel, refreshPill, syncAllButton])
        reposCard.setBody(reposBody, insets: HelmCard.contentInsets)
        cards.append(reposCard)

        let stack = NSStackView(views: [reposCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            reposCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

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
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        if !hasCheckedOnce {
            hasCheckedOnce = true
            checkAll()
        }
    }

    private func scrollToTop() {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Card chrome

    /// One `HelmCard` per page section - the shared container from
    /// `HelmDesignSystem.swift`, replacing this file's own copy of a helper
    /// that was byte-for-byte identical in four controllers (audit §3.2).
    private func card(icon: String, title: String, content: NSView) -> HelmCard {
        let card = HelmCard()
        card.setHeader(symbol: icon, title: title)
        card.setBody(content, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(v)
        return v
    }

    // MARK: Toolbar

    /// This page's read-only "re-check every fork" affordance.
    ///
    /// Deliberately the shared `HelmRefreshPill` rather than a second copy of
    /// Setup > Updates' own recipe: the captain asked for "the same refresh
    /// button as Updates", and one definition is what makes that true a
    /// release from now. It sits at the trailing edge of the page's first
    /// row - the position Updates' own pill holds in its toolbar row, and the
    /// space this page's deleted subtitle used to occupy.
    ///
    /// **It is not a quieter "Sync All".** That button is this page's one
    /// mutating action (it fast-forwards real forks on GitHub); this one only
    /// re-runs `GitHubSyncSource.check` per repo, which is exactly what
    /// `viewWillAppear` already does on a first visit. Keeping the two
    /// visually distinct is why this is a small trailing pill and Sync All
    /// stays the labelled primary button inside its own card.
    private let refreshPill = HelmRefreshPill(
        title: "Refresh", tooltip: "Re-check every fork's sync status")

    /// Swapped in for the pill while a re-check is in flight, the same way
    /// `UpdatesController` swaps its own pill for a progress readout - a
    /// sweep that shells out to `gh` per repo takes long enough that a
    /// button which merely stopped responding would read as broken.
    private let refreshProgressLabel = NSTextField(labelWithString: "")
    private var isCheckingAll = false

    /// UI5: the page's two actions, configured for the Repos card header's own
    /// trailing action cluster rather than for a toolbar row of their own.
    ///
    /// `HelmCard.setHeader(actions:)` owns the placement now, which is what
    /// removes the row this page used to hand-lay-out for gotcha (10)/(12)'s
    /// reasons (a `.gravityAreas` stack has no rule for who absorbs the slack,
    /// and a bare `NSView()` spacer has no intrinsic size to hug with). The
    /// progress readout still yields and truncates rather than becoming a
    /// window-width floor - see its compression resistance below.
    private func buildToolbarControls() {
        refreshPill.setAction(target: self, action: #selector(refreshTapped))

        refreshProgressLabel.font = .systemFont(ofSize: 11, weight: .medium)
        refreshProgressLabel.isHidden = true
        refreshProgressLabel.lineBreakMode = .byTruncatingTail
        refreshProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        // `fm/grandline-bootstrap-window-shrink`: a single-line label whose
        // text is data, left at `NSTextField`'s default 750 compression
        // resistance, is a hard floor on the whole window's width - above
        // `NSLayoutPriorityWindowSizeStayPut` (500). It yields and truncates.
        refreshProgressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func refreshTapped() { checkAll() }

    // MARK: Sync All

    private let syncAllButton = HelmButton(title: "", variant: .primary)
    private let syncAllSummaryLabel = NSTextField(wrappingLabelWithString: "")

    /// UI5: what the Sync All button leaves behind - the run's own summary
    /// sentence, now at the top of the list it is about. The button itself
    /// moved into that list's card header; see `loadView`.
    ///
    /// Hidden until a run has actually written something, so an untouched page
    /// does not carry an empty line where a sentence will one day be.
    private func buildSyncAllSummary() -> NSView {
        syncAllButton.title = "Sync All"
        syncAllButton.target = self
        syncAllButton.action = #selector(syncAllTapped)
        syncAllButton.setContentHuggingPriority(.required, for: .horizontal)

        syncAllSummaryLabel.font = .systemFont(ofSize: 11.5)
        syncAllSummaryLabel.preferredMaxLayoutWidth = 500
        syncAllSummaryLabel.isHidden = syncAllSummaryLabel.stringValue.isEmpty
        syncAllSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        return syncAllSummaryLabel
    }

    /// UI5: the summary line lives in the repo list's body now, so it has to
    /// appear with its first sentence rather than reserving an empty line for
    /// one. Every write goes through here so that stays true.
    private func setSyncAllSummary(_ text: String) {
        syncAllSummaryLabel.stringValue = text
        syncAllSummaryLabel.isHidden = text.isEmpty
    }

    @objc private func syncAllTapped() { syncAll() }

    /// Syncs every repo currently showing "behind upstream" - skips a repo
    /// already in sync (nothing to do) and skips (never touches) a diverged
    /// repo, reporting it distinctly rather than silently doing nothing.
    /// Runs one at a time, matching `AutomationController.installAllMissing`'s
    /// own "never race two external-tool invocations concurrently" reasoning.
    private func syncAll() {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        syncAllButton.isEnabled = false
        let targets = rows.filter { $0.status.showsSyncButton }
        guard !targets.isEmpty else {
            isSyncingAll = false
            syncAllButton.isEnabled = true
            setSyncAllSummary("Nothing behind upstream right now.")
            return
        }
        var synced = 0
        var alreadyInSync = 0
        var refused: [String] = []
        var failed: [String] = []
        func runNext(_ index: Int) {
            guard index < targets.count else {
                isSyncingAll = false
                syncAllButton.isEnabled = true
                var parts: [String] = []
                if synced > 0 { parts.append("\(synced) synced") }
                if alreadyInSync > 0 { parts.append("\(alreadyInSync) already in sync") }
                if !refused.isEmpty { parts.append("\(refused.count) diverged (left untouched)") }
                if !failed.isEmpty { parts.append("\(failed.count) failed") }
                setSyncAllSummary(parts.isEmpty ? "Nothing to sync." : parts.joined(separator: ", "))
                if let container = view.window?.contentView {
                    Toast.show(in: container, message: "GitHub Sync: \(syncAllSummaryLabel.stringValue)")
                }
                return
            }
            let row = targets[index]
            setSyncAllSummary("Syncing \(row.repo.fullName)\u{2026} (\(index + 1)/\(targets.count))")
            sync(row) { ok in
                if ok {
                    if row.status == .inSync { alreadyInSync += 1 } else { synced += 1 }
                } else if row.status.isDiverged {
                    refused.append(row.repo.fullName)
                } else {
                    failed.append(row.repo.fullName)
                }
                runNext(index + 1)
            }
        }
        runNext(0)
    }

    // MARK: Row building

    private func buildRow(_ row: GitHubSyncRow) -> NSView {
        row.syncButton.title = "Sync now"
        row.syncButton.controlSize = .small
        row.syncButton.target = self
        row.syncButton.action = #selector(syncTapped(_:))
        row.syncButton.identifier = NSUserInterfaceItemIdentifier(row.repo.fullName)

        row.progressLabel.font = .systemFont(ofSize: 11, weight: .medium)

        let view = ToolRowLayout.build(
            row.toolRowViews,
            iconSymbol: "point.3.connected.trianglepath.dotted",
            tint: .neutral,
            name: row.repo.fullName,
            statusViews: [row.pill, row.statusSkeleton, row.progressLabel],
            trailingViews: [row.syncButton],
            detailsTarget: self,
            detailsAction: #selector(detailsTapped(_:)),
            identifier: row.repo.fullName
        )
        row.logContainer.isHidden = true
        return view
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(row.toolRowViews, expanded: row.isLogExpanded, log: row.log)
    }

    private func row(for sender: NSButton) -> GitHubSyncRow? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return rows.first { $0.repo.fullName == raw }
    }

    // MARK: Check

    /// Re-checks every repo. Reached both from `viewWillAppear`'s first-visit
    /// sweep and from the Refresh pill, so the two can never drift apart
    /// about what a "check" is.
    ///
    /// A row already busy (its own Sync now, or a Sync All in flight) is
    /// skipped by `check(_:)`'s own guard rather than interrupted - a
    /// read-only refresh must never disturb a mutating sync that is already
    /// running.
    private func checkAll() {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        refreshPill.isHidden = true
        refreshProgressLabel.isHidden = false

        let total = rows.count
        refreshProgressLabel.stringValue = "Checking\u{2026} (0/\(total))"
        guard total > 0 else {
            finishCheckAll()
            return
        }

        var completed = 0
        for row in rows {
            check(row) { [weak self] in
                guard let self else { return }
                completed += 1
                self.refreshProgressLabel.stringValue = "Checking\u{2026} (\(completed)/\(total))"
                if completed == total { self.finishCheckAll() }
            }
        }
    }

    /// No `Toast` here, unlike `UpdatesController.finishCheckAll()`. This
    /// page already states the outcome in those exact words a few points
    /// above, in the drill header's own live subtitle ("8 forks - all in
    /// sync"), and its one existing toast is reserved for Sync All - the
    /// mutating action, which has no other summary of its own. Keeping the
    /// toast exclusively on Sync All is also part of what keeps the two
    /// actions visibly distinct.
    private func finishCheckAll() {
        isCheckingAll = false
        refreshPill.isHidden = false
        refreshProgressLabel.isHidden = true
        // Anything the notification popover asked for while this sweep was
        // running now has a real, current status to act on.
        runPendingNotificationSyncs()
    }

    private func check(_ row: GitHubSyncRow, completion: (() -> Void)? = nil) {
        guard !row.isBusy else {
            completion?()
            return
        }
        row.isBusy = true
        row.status = .checking
        row.detail = "Checking\u{2026}"
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = GitHubSyncSource.check(row.repo)
            DispatchQueue.main.async {
                guard self != nil else {
                    completion?()
                    return
                }
                row.isBusy = false
                row.status = outcome.status
                row.upstreamFullName = outcome.upstreamFullName
                row.detail = outcome.detail
                row.log = outcome.log
                self?.render(row)
                completion?()
            }
        }
    }

    @objc private func syncTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        sync(row)
    }

    // MARK: Sync

    /// `completion(ok)` fires on the main queue once this row's sync settles;
    /// `syncAll()` uses it to sequence one repo at a time. A real Check runs
    /// right after a successful sync so the row's status reflects the fork's
    /// true, live state rather than the sync command's own self-report -
    /// mirrors `UpdatesController.update(_:)`'s identical "Check is the
    /// source of truth" contract.
    private func sync(_ row: GitHubSyncRow, completion: ((Bool) -> Void)? = nil) {
        guard !row.isBusy else {
            completion?(false)
            return
        }
        row.isBusy = true
        row.status = .syncing
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = GitHubSyncSource.sync(row.repo)
            DispatchQueue.main.async {
                guard let self else {
                    completion?(false)
                    return
                }
                row.isBusy = false
                row.log = outcome.log
                if outcome.ok {
                    row.detail = outcome.detail
                    self.render(row)
                    // Re-check to get the real post-sync ahead/behind numbers.
                    self.check(row) { completion?(true) }
                    return
                }
                row.status = outcome.refusedDiverged ? .diverged(localOnly: 0, upstreamAhead: 0) : .syncFailed
                row.detail = outcome.detail
                self.render(row)
                if outcome.refusedDiverged {
                    // A refusal is a real, meaningful signal, not a silent
                    // no-op - re-check right after so the row shows the
                    // fork's actual diverged-commit counts instead of the
                    // placeholder zeros above.
                    self.check(row) { completion?(false) }
                } else {
                    completion?(false)
                }
            }
        }
    }

    // MARK: Render

    // MARK: Daylight §6.4 - the drill header's live line

    /// Counted off the same `rows` array the page renders, and off the same
    /// `showsSyncButton` / `isDiverged` predicates the rows' own buttons and
    /// signal treatment already use - never a second notion of "behind".
    var drillHeaderSubtitle: String? {
        let total = rows.count
        guard total > 0 else { return "No forks in the catalog" }
        if rows.contains(where: { $0.status == .checking || $0.status == .syncing }) {
            return "\(total) forks \u{00B7} checking\u{2026}"
        }
        if rows.allSatisfy({ $0.status == .unknown }) { return "\(total) forks \u{00B7} not checked yet" }
        let behind = rows.filter { $0.status.showsSyncButton }.count
        let diverged = rows.filter { $0.status.isDiverged }.count
        var parts: [String] = ["\(total) forks"]
        if behind > 0 { parts.append("\(behind) behind upstream") }
        if diverged > 0 { parts.append("\(diverged) diverged") }
        if behind == 0 && diverged == 0 { parts.append("all in sync") }
        return parts.joined(separator: " \u{00B7} ")
    }

    var onDrillSubtitleChanged: (() -> Void)?

    /// **Deliberately empty.** This page carries its own actions in its own
    /// toolbar or card header a few points below the drill header -
    /// its "Sync All" button, which sits above the summary line it writes
    /// into. Hoisting a copy of one
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

    #if FM_SELFTESTS
    /// Set every row's status to `statuses` (by catalog order) and run the
    /// page's **real** `render(_:)` choke point - see
    /// `UpdatesController.debugApplyStatusesAndRender` for why this drives the
    /// choke point rather than the publish method.
    func debugApplyStatusesAndRender(_ statuses: [GitHubSyncStatus]) {
        for (row, status) in zip(rows, statuses) { row.status = status }
        for row in rows { render(row) }
    }
    #endif

    /// `fm/grandline-engineering-cards-stale-counts`: hand the freshly-learned
    /// statuses to the one place that counts them.
    ///
    /// The captain synced every fork here and then watched the Engineering hub
    /// go on saying "6 behind, of 8 tracked" - because the hub renders
    /// `BackgroundSignalsPoller.lastCounts`, which only that poller's own
    /// 15-minute pass could write. This page holds the fresher truth the
    /// moment a check returns, so it publishes the **statuses**, never a
    /// count: `showsSyncButton` (which deliberately excludes a diverged repo
    /// and a non-fork) is applied in one place, so this page's rows and the
    /// hub's card cannot disagree about what "behind" means.
    ///
    /// Gated on being on screen for the same reason as the Updates page's -
    /// see `UpdatesController.publishToolUpdateSignal`.
    private func publishForkDriftSignal() {
        guard isViewLoaded, !view.isHidden else { return }
        // `fm/grandline-notification-center-redesign`: the forks themselves
        // travel with the statuses so the notification row can expand into
        // them, furthest behind first - which is also what its detail line
        // names. The counting rule (`showsSyncButton`, applied in the poller)
        // is untouched.
        //
        // `fm/grandline-notification-ambient-expand-fix`: built through
        // `NotificationSignalChildren`, shared with the poller's own ambient
        // pass - see `UpdatesController.publishToolUpdateSignal` for why the
        // two producers must not each own a mapping.
        let pending = rows.filter { $0.status.showsSyncButton }
        let children = NotificationSignalChildren.forks(
            rows.map { .init(id: $0.repo.fullName, name: $0.repo.name, status: $0.status, detail: $0.detail) },
            perform: { [weak self] id in self?.requestSyncFromNotification(repoFullName: id) })
        BackgroundSignalsPoller.shared.publishForkStatuses(
            rows.map { $0.status },
            children: children,
            syncAll: pending.isEmpty ? nil : { [weak self] in self?.syncAll() }
        )
    }

    /// Run one repo's real sync, asked for from the notification popover's
    /// expanded row - the mirror of
    /// `UpdatesController.requestUpdateFromNotification`, including its
    /// queue-while-a-sweep-is-running rule and why it exists. Reached both
    /// from this page's own children and, for a press that happened before
    /// this page was ever mounted, from
    /// `AppShellController.syncForkFromNotification`.
    func requestSyncFromNotification(repoFullName: String) {
        guard isViewLoaded else { return }
        guard !isCheckingAll else {
            if !pendingNotificationSyncs.contains(repoFullName) {
                pendingNotificationSyncs.append(repoFullName)
            }
            return
        }
        guard let row = rows.first(where: { $0.repo.fullName == repoFullName }) else { return }
        sync(row)
    }

    /// Repos whose Sync was pressed while a check sweep was in flight.
    private var pendingNotificationSyncs: [String] = []

    private func runPendingNotificationSyncs() {
        let requested = pendingNotificationSyncs
        pendingNotificationSyncs = []
        for fullName in requested {
            guard let row = rows.first(where: { $0.repo.fullName == fullName }),
                  row.status.showsSyncButton else { continue }
            sync(row)
        }
    }

    private func render(_ row: GitHubSyncRow) {
        // Every status change for every row lands here, so this is the one
        // place the header's line has to be re-read from.
        defer { onDrillSubtitleChanged?() }
        defer { publishForkDriftSignal() }
        row.detailLabel.stringValue = row.detail
        row.logField.stringValue = row.log.isEmpty ? "No output yet." : row.log

        // The pill itself is painted by `applyThemeToRow` (called at the end
        // of this method), not here - see that method's own note for why the
        // theme pass has to be the single owner of it.
        let busy = row.status == .checking || row.status == .syncing
        row.pill.isHidden = busy
        row.syncButton.isHidden = busy || !row.status.showsSyncButton
        row.statusSkeleton.isHidden = !busy
        row.progressLabel.isHidden = !busy
        row.progressLabel.stringValue = row.status == .syncing ? "Syncing\u{2026}" : "Checking\u{2026}"

        row.syncButton.isEnabled = !row.isBusy
        row.rowContainer.alphaValue = row.isBusy ? 0.6 : 1.0

        applyThemeToRow(row)
    }

    private func pillVisuals(_ status: GitHubSyncStatus) -> (String, String) {
        switch status {
        case .unknown: return ("Not Checked", theme.chromeInkHex)
        case .checking, .syncing: return ("", theme.chromeInkHex)
        case .inSync: return ("In Sync", theme.ansiHex[2])
        case .behind(let n): return ("\(n) behind", theme.ansiHex[3])
        case .diverged: return ("Diverged", theme.ansiHex[1])
        case .notAFork: return ("Not a Fork", theme.chromeInkHex)
        case .checkFailed: return ("Check Failed", theme.ansiHex[1])
        case .syncFailed: return ("Sync Failed", theme.ansiHex[1])
        }
    }

    // MARK: Theme

    private func applyThemeToRow(_ row: GitHubSyncRow) {
        let failed = row.status == .checkFailed || row.status == .syncFailed || row.status.isDiverged
        // "Needs attention" = the existing `failed`/diverged signal above,
        // plus `showsSyncButton`'s own `.behind` case - a fork genuinely
        // behind upstream is worth a look even before any sync attempt has
        // failed (`fm/grandline-setup-attention-row-style`). Both
        // predicates already exist; this only composes them, no new
        // detection. `.inSync`/`.notAFork`/`.unknown` (and a busy
        // `.checking`/`.syncing`) keep today's flat/compact look.
        let needsAttention = failed || row.status.showsSyncButton
        let (pillText, pillColorHex) = pillVisuals(row.status)
        // The status pill is painted HERE rather than in `render` - a real,
        // captain-reported bug lived on that split. `ToolRowLayout.pill`
        // resolves a fill and a label tone for one specific theme and bakes
        // both into the layer; nothing re-resolves them later, and
        // `ToolRowLayout.applyTheme` below deliberately never touches the
        // pill (it is passed as one of `build`'s `statusViews`, not as part
        // of `Views`' own chrome). So while the pill was painted only from
        // `render` - i.e. only when a row's *status* changed - a theme switch
        // left every pill wearing the palette it was last painted in, and
        // because each repo's check completes on its own schedule, a switch
        // mid-sweep left the rows that had already reported wearing the old
        // theme and the rest wearing the new one: eight rows all reading
        // "In Sync", rendered in two different treatments at once. Painting
        // it from the theme pass closes that by construction, since `render`
        // ends by calling this method - one owner, reached by both a status
        // change and a theme change.
        //
        // `theme:` is passed explicitly rather than left to the parameter's
        // `ThemeManager.shared.theme` default: this controller keeps its own
        // `theme` copy, and a pill resolved against a different theme than
        // the row around it is exactly the class of split this fixes.
        ToolRowLayout.pill(text: pillText, colorHex: pillColorHex,
                           into: row.pill, label: row.pillLabel, theme: theme)
        let attentionHex = needsAttention ? pillColorHex : nil
        ToolRowLayout.applyTheme(
            row.toolRowViews, theme: theme, detailFailed: failed,
            cardStyle: needsAttention, attentionHex: attentionHex, accentBar: needsAttention
        )
        row.progressLabel.textColor = HelmTheme.mutedInk(theme)
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        for card in cards { card.applyTheme(theme) }
        for v in separators {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
        syncAllSummaryLabel.textColor = HelmTheme.mutedInk(theme)
        refreshPill.applyTheme(theme)
        refreshProgressLabel.textColor = HelmTheme.mutedInk(theme)
        for row in rows { applyThemeToRow(row) }
    }

    #if FM_SELFTESTS
    // MARK: Probe surface (debug builds only, GL-27)

    var debugRowCount: Int { rows.count }

    /// Drives the real status-change path a completed check takes.
    func debugSetStatus(_ status: GitHubSyncStatus, atRow index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].status = status
        rows[index].detail = "probe"
        render(rows[index])
    }

    /// What the pill is ACTUALLY painted with, read back off the layer and the
    /// label rather than re-derived - the whole bug was that the painted value
    /// and the current theme had drifted apart, so a check that re-derives
    /// cannot see it.
    func debugPillPaint(atRow index: Int) -> (fill: CGColor?, label: NSColor?, text: String)? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        return (row.pill.layer?.backgroundColor, row.pillLabel.textColor, row.pillLabel.stringValue)
    }
    #endif

}
