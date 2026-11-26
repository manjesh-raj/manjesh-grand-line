// Grand Line - native macOS app.
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

final class GitHubSyncRow {
    let repo: GitHubSyncRepoConfig
    var status: GitHubSyncStatus = .unknown
    var upstreamFullName: String?
    var detail: String = "Not checked yet"
    var log: String = ""
    /// When the reading this row shows was taken - the sidebar layout's Last
    /// checked column (stage 7), and the stamp this row's reading is
    /// published with. Set when a check *starts*, the same way the poller
    /// stamps its own sweep, and also by a failed sync (whose "Sync Failed"
    /// is a reading of its own) and by adopting a newer reading another
    /// producer took.
    var checkedAt: Date?
    /// Why the last sync or merge could not be done, and what to do instead.
    /// Kept across the re-check that follows a refusal, which would otherwise
    /// replace the reason with a bare "Diverged" - and cleared by the next
    /// action, or by a check that finds nothing left to sync.
    var problem: GitHubSyncProblem?
    /// True while either a check or a sync is running for this row - guards
    /// against double-firing the same row from two places (a row's own
    /// button and "Sync all" running concurrently).
    var isBusy = false

    init(repo: GitHubSyncRepoConfig) { self.repo = repo }
}

/// The three GitHub operations this page runs, as one injectable value. The
/// app always uses `GitHubSyncSource`; a self-test substitutes fixtures so the
/// page's real confirm, busy, re-check and publish paths run without `gh`.
struct GitHubSyncActions {
    var check: (GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome = GitHubSyncSource.check
    var sync: (GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome = GitHubSyncSource.sync
    var mergeUpstream: (GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome = GitHubSyncSource.mergeUpstream
}

final class GitHubSyncController: NSViewController, DaylightDrillActions {

    var rows: [GitHubSyncRow] = GitHubSyncCatalog.repos.map(GitHubSyncRow.init)
    var actions = GitHubSyncActions()
    private var readingsToken: BackgroundSignalsPoller.CountsObservation?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    private var hasCheckedOnce = false
    private var isSyncingAll = false

    // MARK: The sidebar layout's state (stage 7)

    private var pageStack: NSStackView?
    /// Sup-1: Setup's hero, with this tab's verdict over the module's five
    /// figures. Sync All and Refresh are its pills.
    private lazy var setupSummary: SetupHeroRow = {
        let hero = SetupHeroRow(page: .github) { [weak self] in
            let rows = self?.rows ?? []
            let own: [(name: String, count: Int)] = rows.compactMap { row in
                switch row.status {
                case let .ahead(count): return (row.repo.name, count)
                case let .diverged(localOnly, _): return (row.repo.name, localOnly)
                default: return nil
                }
            }
            return SetupHeroWords.github(BackgroundSignalsPoller.shared.lastCounts,
                                         configRepo: SetupSummaryFeed.shared.configRepo,
                                         checkedAt: rows.compactMap(\.checkedAt).max(), ownCommits: own)
        }
        hero.setActions([.mirroring(syncAllButton), .mirroring(refreshButton)])
        return hero
    }()
    /// The forks, one row each: the fork, its upstream, how far behind it
    /// is, and when it was last read.
    private lazy var forksTable: HelmDataTable = {
        let table = HelmDataTable(columns: [
            .init(id: "fork", title: "Fork", width: 280, minWidth: 200, flexible: true),
            .init(id: "upstream", title: "Upstream", width: 270, hiddenBelow: 760),
            .init(id: "behind", title: "Behind", width: 150),
            .init(id: "checked", title: "Last checked", width: 120, hiddenBelow: 640),
        ], actionsWidth: 120)
        table.sizesToFitRows = true
        table.accessibilityName = "Forks"
        table.onSelect = { [weak self] key in
            self?.selectedForkName = key
            self?.onInspectorContentChanged?()
        }
        return table
    }()
    private let forksSubtitle = NSTextField(labelWithString: "")
    /// The toolbar's Refresh: the pill's re-check, as a toolbar button.
    private lazy var refreshButton: HelmButton = {
        let button = HelmButton.refresh(size: .small)
        button.target = self
        button.action = #selector(refreshTapped)
        button.toolTip = "Re-check every fork's sync status"
        return button
    }()
    /// "Pushing is paused": shown while the config repo is confirmed public.
    /// S17: a `HelmNotice` in `.critical`, which carries the attention edge.
    private lazy var pausedCard = HelmNotice(actions: [openOnGitHubButton, checkAgainButton])
    private lazy var openOnGitHubButton = HelmButton(title: "Open on GitHub", variant: .primary, size: .small,
                                                     target: self, action: #selector(openConfigRepoSettings))
    private lazy var checkAgainButton = HelmButton(title: "Check again", variant: .secondary, size: .small,
                                                   target: self, action: #selector(checkConfigRepoAgain))
    private var configRepo: ConfigRepoPrivacy.Reading?
    private var configRepoToken: UUID?
    private var isCheckingConfigRepo = false
    private var selectedForkName: String?
    private lazy var forkDetail = WorkspaceDetailView()
    var onInspectorContentChanged: (() -> Void)?
    var onShowInspector: (() -> Void)?

    deinit {
        if let configRepoToken { ConfigRepoPrivacy.unobserve(configRepoToken) }
        if let readingsToken { BackgroundSignalsPoller.shared.unobserveForkReadings(readingsToken) }
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

        configureSyncAllButton()

        // S03: the page frame - scroll, flipped document, gutter and the
        // first-content line - is `HelmPageScaffold`'s. The page's cards are
        // the sidebar presentation's (`buildSidebarPresentation`).
        let scaffold = HelmPageScaffold(spacing: 14, bottomInset: 20)
        scaffold.install(in: root)
        pageStack = scaffold.stack
        scrollView = scaffold.scrollView

        for row in rows { render(row) }
        applyTheme()
        // A reading another producer takes while this page is mounted - the
        // poller's pass, a scheduled fork sync - lands in these rows too, so
        // the list never disagrees with the card above it. Async so a publish
        // this page made from inside `render` never re-enters it.
        readingsToken = BackgroundSignalsPoller.shared.observeForkReadings { [weak self] in
            DispatchQueue.main.async { self?.adoptNewerReadings() }
        }

        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the page builds its sidebar presentation as part of loading.
        buildSidebarPresentation()
    }

    /// Take every reading the poller holds that is newer than the row's own.
    /// A busy row is left alone: its own check or sync is about to answer.
    func adoptNewerReadings() {
        guard isViewLoaded else { return }
        let held = BackgroundSignalsPoller.shared.forkReadings
        for row in rows where !row.isBusy {
            guard let reading = held[row.repo.fullName],
                  reading.gatheredAt > (row.checkedAt ?? .distantPast) else { continue }
            row.status = reading.status
            row.upstreamFullName = reading.upstreamFullName
            row.detail = reading.detail
            row.log = reading.log
            row.checkedAt = reading.gatheredAt
            if !reading.status.needsSync && reading.status != .checkFailed { row.problem = nil }
            render(row)
        }
    }

    private let scrollMemory = HelmScrollMemory()

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scrollMemory.remember(scrollView)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        // P3: keep the captain's place unless the page changed (`HelmScrollMemory`).
        scrollMemory.restore(scrollView) { scrollToTop() }
        // Anything read while this page was hidden, and "just now" re-said
        // as the age it really is.
        adoptNewerReadings()
        renderForksTable()
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

    /// Refresh, from the window toolbar: re-check every fork. A sweep that
    /// shells out to `gh` per repo takes a while, so its progress is the
    /// Forks card's subtitle until it finishes.
    private var isCheckingAll = false

    @objc private func refreshTapped() { checkAll() }

    // MARK: Sync All

    private let syncAllButton = HelmButton(title: "", variant: .primary)
    /// What the last Sync All run said, which its toast repeats.
    private var syncAllSummary = ""

    private func configureSyncAllButton() {
        syncAllButton.title = "Sync All"
        syncAllButton.target = self
        syncAllButton.action = #selector(syncAllTapped)
        syncAllButton.setContentHuggingPriority(.required, for: .horizontal)
        // U11: the page opens with every row `.unknown`, so the button starts
        // disabled rather than waiting for the first `render(_:)` to notice.
        updateSyncAllEnablement()
    }

    private func setSyncAllSummary(_ text: String) { syncAllSummary = text }

    @objc private func syncAllTapped() { requestSyncAll() }

    /// "Sync all", asked for by a person: the button, or the notification's
    /// own "Sync all". Says which forks it will fast-forward, and that a
    /// diverged one is left for its own row, before anything is pushed.
    func requestSyncAll() {
        guard !isSyncingAll else { return }
        let targets = rows.filter { $0.status.showsSyncButton }
        guard !targets.isEmpty else {
            syncAll()
            return
        }
        guard HelmConfirm.confirm(Self.syncAllConfirmation(targets: targets, rows: rows)) == .confirm else { return }
        syncAll()
    }

    /// The copy for "Sync all", as a value so a self-test can assert it.
    static func syncAllConfirmation(targets: [GitHubSyncRow], rows: [GitHubSyncRow]) -> HelmConfirm.Request {
        let names = targets.map(\.repo.fullName)
        let listed = names.count <= 4 ? names.joined(separator: ", ")
            : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        var body = "Fast-forwards \(listed) to their upstreams and pushes each one to GitHub. "
            + "None of them has commits of its own, so nothing is replaced, and nothing is force-pushed."
        let diverged = rows.filter { $0.status.showsMergeUpstream }.count
        if diverged > 0 {
            body += " \(diverged == 1 ? "The diverged fork is" : "The \(diverged) diverged forks are") left alone: "
                + "a merge is done one fork at a time, from its own row."
        }
        var request = HelmConfirm.Request(title: "Sync \(targets.count) fork\(targets.count == 1 ? "" : "s")?", body: body)
        request.confirmTitle = targets.count == 1 ? "Sync" : "Sync \(targets.count)"
        request.symbol = "arrow.triangle.2.circlepath"
        return request
    }

    /// Syncs every repo currently showing "behind upstream" - skips a repo
    /// already in sync (nothing to do) and skips (never touches) a diverged
    /// repo, reporting it distinctly rather than silently doing nothing.
    /// Runs one at a time, matching `AutomationController.installAllMissing`'s
    /// own "never race two external-tool invocations concurrently" reasoning.
    ///
    /// Unconfirmed: `requestSyncAll` is the entry point for a person.
    private func syncAll() {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        syncAllButton.isEnabled = false
        setupSummary.render()
        let targets = rows.filter { $0.status.showsSyncButton }
        guard !targets.isEmpty else {
            isSyncingAll = false
            setSyncAllSummary("Nothing behind upstream right now.")
            updateSyncAllEnablement()
            return
        }
        presentsProblems = false
        var synced = 0
        var alreadyInSync = 0
        var refused: [String] = []
        var failed: [String] = []
        func runNext(_ index: Int) {
            guard index < targets.count else {
                isSyncingAll = false
                presentsProblems = true
                updateSyncAllEnablement()
                var parts: [String] = []
                if synced > 0 { parts.append("\(synced) synced") }
                if alreadyInSync > 0 { parts.append("\(alreadyInSync) already in sync") }
                if !refused.isEmpty { parts.append("\(refused.count) diverged (left untouched)") }
                if !failed.isEmpty { parts.append("\(failed.count) failed") }
                setSyncAllSummary(parts.isEmpty ? "Nothing to sync." : parts.joined(separator: ", "))
                if let container = view.window?.contentView {
                    // TO-1: a run where nothing failed or diverged is done, one
                    // where nothing went through is a failure, and anything
                    // between is a warning.
                    let kind: Feedback.Kind
                    if failed.isEmpty && refused.isEmpty {
                        kind = .done
                    } else if synced == 0 && alreadyInSync == 0 && refused.isEmpty {
                        kind = .failure
                    } else {
                        kind = .warning
                    }
                    Toast.show(in: container, message: "GitHub Sync: \(syncAllSummary)", kind: kind)
                }
                return
            }
            let row = targets[index]
            setSyncAllSummary("Syncing \(row.repo.fullName)\u{2026} (\(index + 1)/\(targets.count))")
            sync(row) { ok in
                if ok {
                    if row.status == .inSync { alreadyInSync += 1 } else { synced += 1 }
                } else if row.status.hasOwnCommits {
                    // Refused because it has commits of its own after all.
                    refused.append(row.repo.fullName)
                } else {
                    failed.append(row.repo.fullName)
                }
                runNext(index + 1)
            }
        }
        runNext(0)
    }

    // MARK: Check

    /// Re-checks every repo. Reached both from `viewWillAppear`'s first-visit
    /// sweep and from the toolbar's Refresh, so the two can never drift apart
    /// about what a "check" is.
    ///
    /// A row already busy (its own Sync now, or a Sync All in flight) is
    /// skipped by `check(_:)`'s own guard rather than interrupted - a
    /// read-only refresh must never disturb a mutating sync that is already
    /// running.
    private func checkAll() {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        refreshButton.isEnabled = false
        setupSummary.render()

        let total = rows.count
        forksSubtitle.stringValue = "Checking\u{2026} (0/\(total))"
        guard total > 0 else {
            finishCheckAll()
            return
        }

        var completed = 0
        for row in rows {
            check(row) { [weak self] in
                guard let self else { return }
                completed += 1
                self.forksSubtitle.stringValue = "Checking\u{2026} (\(completed)/\(total))"
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
        refreshButton.isEnabled = true
        renderForksSubtitle()
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
        let startedAt = Date()
        let check = actions.check
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = check(row.repo)
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
                row.checkedAt = startedAt
                // A refusal's reason stays while the fork is still in the
                // state it was refused for; anything else has moved on.
                // A failed action's reason stays while the fork still has
                // something to pull; once nothing is left, it is history.
                if !outcome.status.needsSync && outcome.status != .checkFailed { row.problem = nil }
                self?.render(row)
                completion?()
            }
        }
    }

    // MARK: Sync

    /// A row's sync or merge, asked for by a person - its button, its menu,
    /// the inspector, or a notification's child row. Confirms first, because
    /// both push to GitHub, and says what will happen. The fork's state picks
    /// the action: a fast-forward for one that is only behind, a merge for a
    /// diverged one. Anything else has nothing to pull and does nothing.
    func requestSync(_ row: GitHubSyncRow) {
        guard !row.isBusy else { return }
        if row.status.showsMergeUpstream {
            guard HelmConfirm.confirm(Self.mergeConfirmation(row)) == .confirm else { return }
            mergeUpstream(row)
        } else if row.status.showsSyncButton {
            guard HelmConfirm.confirm(Self.syncConfirmation(row)) == .confirm else { return }
            sync(row)
        }
    }

    private static func commits(_ n: Int) -> String { "\(n) commit\(n == 1 ? "" : "s")" }

    /// The copy for a fast-forward, as a value so a self-test can assert it.
    static func syncConfirmation(_ row: GitHubSyncRow) -> HelmConfirm.Request {
        let upstream = row.upstreamFullName ?? row.repo.manualUpstreamFullName ?? "its upstream"
        let what: String
        if case .behind(let n) = row.status {
            what = "Adds \(commits(n)) from \(upstream) to \(row.repo.fullName)'s default branch"
        } else {
            what = "Retries bringing \(row.repo.fullName)'s default branch up to date with \(upstream)"
        }
        var request = HelmConfirm.Request(
            title: "Sync \(row.repo.fullName)?",
            body: "\(what) and pushes it to GitHub. The fork has no commits of its own, so this is a "
                + "fast-forward: nothing is replaced, and nothing is force-pushed.")
        request.confirmTitle = "Sync"
        request.symbol = "arrow.triangle.2.circlepath"
        return request
    }

    /// The copy for a merge into a diverged fork.
    static func mergeConfirmation(_ row: GitHubSyncRow) -> HelmConfirm.Request {
        let upstream = row.upstreamFullName ?? row.repo.manualUpstreamFullName ?? "its upstream"
        var own = 0, behind = 0
        if case .diverged(let localOnly, let upstreamAhead) = row.status { own = localOnly; behind = upstreamAhead }
        let how = row.repo.manualUpstreamFullName == nil
            ? "GitHub merges them on its side, the same as the \u{201c}Sync fork\u{201d} button on github.com."
            : "Grand Line merges them in its own scratch clone and pushes the result."
        var request = HelmConfirm.Request(
            title: "Merge \(upstream) into \(row.repo.fullName)?",
            body: "\(row.repo.fullName) has \(commits(own)) of its own and is \(commits(behind)) behind \(upstream). "
                + "This adds one merge commit that brings in those \(commits(behind)) and pushes it. \(how) "
                + "The fork's own \(commits(own)) stay exactly as they are, and nothing is force-pushed or reset. "
                + "If the two sides conflict, nothing is changed and you get the steps to merge by hand.")
        request.confirmTitle = "Merge"
        request.symbol = "arrow.triangle.merge"
        return request
    }

    /// `completion(ok)` fires on the main queue once this row's sync settles;
    /// `syncAll()` uses it to sequence one repo at a time. A real Check runs
    /// right after a successful sync so the row's status reflects the fork's
    /// true, live state rather than the sync command's own self-report -
    /// mirrors `UpdatesController.update(_:)`'s identical "Check is the
    /// source of truth" contract.
    func sync(_ row: GitHubSyncRow, completion: ((Bool) -> Void)? = nil) {
        guard !row.isBusy else {
            completion?(false)
            return
        }
        run(row, actions.sync, presentsProblem: presentsProblems, completion: completion)
    }

    /// Merge upstream into a diverged fork - `GitHubSyncSource.mergeUpstream`,
    /// unconfirmed. `requestSync` is the entry point for a person.
    func mergeUpstream(_ row: GitHubSyncRow, completion: ((Bool) -> Void)? = nil) {
        run(row, actions.mergeUpstream, presentsProblem: presentsProblems, completion: completion)
    }

    /// False while "Sync all" runs: its own summary names every fork that
    /// failed, and a notice per fork would stack one modal on another.
    private var presentsProblems = true

    /// The one busy / outcome / re-check path a sync and a merge share.
    private func run(_ row: GitHubSyncRow, _ action: @escaping (GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome,
                     presentsProblem: Bool, completion: ((Bool) -> Void)?) {
        guard !row.isBusy else {
            completion?(false)
            return
        }
        row.isBusy = true
        row.status = .syncing
        row.problem = nil
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = action(row.repo)
            DispatchQueue.main.async {
                guard let self else {
                    completion?(false)
                    return
                }
                row.isBusy = false
                row.log = outcome.log
                // Every failure carries a reason. One the action did not
                // explain (a network error, an expired login) still says what
                // happened and that nothing changed - never a silent failure.
                let problem = outcome.ok ? nil : outcome.problem ?? GitHubSyncProblem(
                    reason: outcome.detail,
                    nextStep: "Nothing was changed. The output in the fork's details has gh's or git's own reason. "
                        + "Check the fork again, then retry.",
                    compareURL: nil)
                row.problem = problem
                if outcome.ok {
                    row.detail = outcome.detail
                    self.render(row)
                    // Re-check to get the real post-sync ahead/behind numbers.
                    self.check(row) { completion?(true) }
                    return
                }
                row.detail = outcome.detail
                // Re-check right after, so the row shows the fork's real
                // state and offers the action that state allows, with the
                // reason (`problem`) beside it. Never a placeholder status:
                // a `.syncFailed` here once offered a fast-forward on a
                // diverged fork whose merge had failed.
                self.check(row) { completion?(false) }
                if presentsProblem, let problem { self.presentProblem(problem, for: row) }
            }
        }
    }

    /// Say why the action stopped and what to do next, right away - the row
    /// and the inspector keep saying it afterwards. Offers the compare page
    /// when GitHub can draw one.
    private func presentProblem(_ problem: GitHubSyncProblem, for row: GitHubSyncRow) {
        var request = HelmConfirm.Request(title: "\(row.repo.fullName) was not changed",
                                          body: "\(problem.reason)\n\n\(problem.nextStep)")
        request.symbol = "exclamationmark.triangle.fill"
        request.hue = .rose
        if let url = problem.compareURL {
            request.confirmTitle = "Open compare page"
            request.cancelTitle = "Close"
            request.confirmIsDefault = false
            if HelmConfirm.confirm(request) == .confirm {
                WebNavigationPolicy.openExternally(url, from: "GitHub sync's merge notice")
            }
        } else {
            request.confirmTitle = "OK"
            request.cancelTitle = nil
            _ = HelmConfirm.confirm(request)
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
        // Stage 7, GL-14: a check that failed is not "in sync". This said
        // "all in sync" whenever nothing was behind or diverged, including
        // a sweep where every check failed - measured on a tour, where `gh`
        // is refused and all eight rows read Check Failed under it.
        let failed = rows.filter { $0.status == .checkFailed }.count
        let notForks = rows.filter { $0.status == .notAFork }.count
        var parts: [String] = ["\(total) forks"]
        if behind > 0 { parts.append("\(behind) behind upstream") }
        if diverged > 0 { parts.append("\(diverged) diverged") }
        // R5-UX-02: the rows' own word for it (`StateVocabulary`).
        if failed > 0 { parts.append(failed == total ? "every check failed" : StateWord.checkFailed.counted(failed)) }
        if notForks > 0 { parts.append("\(notForks) not a fork") }
        // A fork that is ahead has nothing to pull, so it is in sync with
        // upstream for every purpose this line serves.
        if rows.allSatisfy({ $0.status.isUpToDate }) {
            parts.append("all in sync")
        }
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
    var drillHeaderActions: [NSView] { [refreshButton] }

    #if FM_SELFTESTS
    /// Set every row's status to `statuses` (by catalog order) and run the
    /// page's **real** `render(_:)` choke point - see
    /// `UpdatesController.debugApplyStatusesAndRender` for why this drives the
    /// choke point rather than the publish method.
    ///
    /// Each status lands as a check that just answered, stamped now - an
    /// unstamped row is not a reading and is never published.
    func debugApplyStatusesAndRender(_ statuses: [GitHubSyncStatus]) {
        let now = Date()
        for (row, status) in zip(rows, statuses) {
            row.status = status
            row.checkedAt = now
        }
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
    /// `fm/grandline-github-sync-counts`: no longer gated on being on screen.
    /// That gate dropped every check and sync that finished behind another
    /// page, so the card kept an older count than the list it sat above. Each
    /// row now publishes its own reading with the time it was taken, and the
    /// poller keeps the newest per fork - so a hidden page re-rendering old
    /// rows cannot displace anything newer, which is what the gate was for.
    private func publishForkDriftSignal() {
        guard isViewLoaded else { return }
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
        //
        // The children are built by the poller from what it holds, through
        // the same `NotificationSignalChildren.forks`, and their buttons reach
        // `requestSyncFromNotification` below by way of the shell.
        let pending = rows.filter { $0.status.showsSyncButton }
        let readings = rows.compactMap { row -> BackgroundSignalsPoller.ForkReading? in
            guard let at = row.checkedAt, row.status.isSettled else { return nil }
            return .init(fullName: row.repo.fullName, status: row.status, upstreamFullName: row.upstreamFullName,
                         detail: row.detail, log: row.log, gatheredAt: at)
        }
        BackgroundSignalsPoller.shared.publishForkReadings(
            readings,
            syncAll: pending.isEmpty ? nil : { [weak self] in self?.requestSyncAll() })
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
        requestSync(row)
    }

    /// Repos whose Sync was pressed while a check sweep was in flight.
    private var pendingNotificationSyncs: [String] = []

    private func runPendingNotificationSyncs() {
        let requested = pendingNotificationSyncs
        pendingNotificationSyncs = []
        for fullName in requested {
            guard let row = rows.first(where: { $0.repo.fullName == fullName }),
                  row.status.needsSync else { continue }
            requestSync(row)
        }
    }

    /// **Review defect U11.** "Sync All" rendered as an enabled, filled
    /// primary button on a page where every row still said "Not Checked" -
    /// so the loudest control on the page advertised work that did not exist
    /// yet, and pressing it wrote "Nothing behind upstream right now." It
    /// already filtered on `showsSyncButton`; what it did not do was *say*
    /// so before being pressed.
    ///
    /// It is enabled only while at least one row is genuinely behind (or
    /// failed a sync and deserves a retry) - the same predicate `syncAll()`
    /// itself targets, read from one place so the button and the run can
    /// never disagree. The tooltip carries the reason, because a disabled
    /// control with no explanation is its own defect.
    private func updateSyncAllEnablement() {
        guard !isSyncingAll else { return }
        let targets = rows.filter { $0.status.showsSyncButton }
        let checking = rows.contains { $0.status == .checking }
        syncAllButton.isEnabled = !targets.isEmpty
        if !targets.isEmpty {
            syncAllButton.toolTip = "Sync the \(targets.count) fork\(targets.count == 1 ? "" : "s") "
                + "behind upstream."
        } else if checking {
            syncAllButton.toolTip = "Still checking which forks are behind upstream."
        } else if rows.allSatisfy({ $0.status == .unknown }) {
            syncAllButton.toolTip = "Nothing has been checked yet - press Refresh first."
        } else if rows.contains(where: { $0.status.showsMergeUpstream }) {
            syncAllButton.toolTip = "Nothing can be fast-forwarded. A diverged fork is merged from its own row."
        } else {
            syncAllButton.toolTip = "Nothing is behind upstream right now."
        }
        setupSummary.render()
    }

    private func render(_ row: GitHubSyncRow) {
        // Every status change for every row lands here. In the order the
        // `defer`s this replaced ran in, last declared first: the sidebar
        // layout's one table, which lists every row (Stage 7); U11's
        // page-level action, whose enablement is re-derived here; the
        // fork-drift signal; and the header's line.
        renderForksTable()
        updateSyncAllEnablement()
        publishForkDriftSignal()
        onDrillSubtitleChanged?()
    }

    /// UI-43 / UI-52: a dot and a word for a default state, a pill only for
    /// one that is not. Tints, never the terminal's ANSI slots (UI-32).
    private func pillVisuals(_ status: GitHubSyncStatus) -> (String, HelmTint, HelmStatusPill.Style) {
        switch status {
        // R5-UX-02: one word per state, the table cells' sentence case.
        case .unknown: return (StateWord.notChecked.label, .neutral, .dotWord)
        case .checking, .syncing: return ("", .neutral, .dotWord)
        case .inSync: return ("In sync", .good, .dotWord)
        case .behind(let n): return ("\(n) behind", .warn, .pill)
        case .diverged: return ("Diverged", .critical, .pill)
        case .ahead: return ("Ahead", .good, .dotWord)
        case .notAFork: return ("Not a fork", .neutral, .dotWord)
        case .checkFailed: return (StateWord.checkFailed.label, .critical, .pill)
        case .syncFailed: return ("Sync failed", .critical, .pill)
        }
    }

    // MARK: Theme

    private func applyTheme() {
        guard isViewLoaded else { return }
        forksTable.applyTheme(theme)
        forksSubtitle.textColor = HelmTheme.mutedInk(theme)
        applyPausedCard()
        renderForksTable()
    }

    #if FM_SELFTESTS
    // MARK: Probe surface (debug builds only, GL-27)

    var debugRowCount: Int { rows.count }

    /// Review defect U11: whether the page's one loud action is offered, and
    /// what it says about why. Read off the button rather than re-derived -
    /// the defect was a button that was enabled while the predicate behind
    /// it had nothing to act on.
    var debugSyncAllEnabled: Bool { isViewLoaded && syncAllButton.isEnabled }
    var debugSyncAllTooltip: String? { isViewLoaded ? syncAllButton.toolTip : nil }

    /// Drives the real status-change path a completed check takes.
    func debugSetStatus(_ status: GitHubSyncStatus, atRow index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].status = status
        rows[index].detail = "probe"
        render(rows[index])
    }

    #endif

}

// MARK: - The sidebar layout (stage 7)

// The prototype's GitHub sync: Setup's hero (Sup-1), a stated pause when the
// config repo is public (every push to it is refused until it is private
// again, GL-22), and the forks as one table. Every row and toolbar action is
// the method the floating bar's own buttons reach; a fork's detail and its
// last `gh` output are the inspector's.

extension GitHubSyncController: WorkspacePrimaryActionProviding, WorkspaceInspectorSource {

    func buildSidebarPresentation() {
        guard let stack = pageStack else { return }
        stack.insertArrangedSubview(setupSummary, at: 0)
        pausedCard.isHidden = true
        stack.insertArrangedSubview(pausedCard, at: 1)
        forksSubtitle.font = HelmType.caption()
        _ = forksTable.card.setHeader(symbol: "point.3.connected.trianglepath.dotted",
                                      titleLabel: NSTextField(labelWithString: "Forks"), subtitleLabel: forksSubtitle)
        stack.addArrangedSubview(forksTable.card)
        for view in [setupSummary, pausedCard, forksTable.card] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        configRepo = ConfigRepoPrivacy.lastReading
        configRepoToken = ConfigRepoPrivacy.observe { [weak self] reading in
            self?.configRepo = reading
            self?.applyPausedCard()
        }
        renderForksSubtitle()
        applyTheme()
    }

    var workspacePrimaryAction: NSView? { syncAllButton }

    var inspectorContent: WorkspaceInspectorContent? {
        guard let name = selectedForkName,
              let row = rows.first(where: { $0.repo.fullName == name }) else { return nil }
        forkDetail.show(forkDetail(for: row))
        return WorkspaceInspectorContent(title: row.repo.name, view: forkDetail)
    }

    var inspectorEmptyText: (title: String, body: String) {
        ("No fork selected", "Select a fork to see its upstream and the output of its last check or sync.")
    }

    /// Shown only for a confirmed public repo: an unknown answer (no `gh`,
    /// offline) never blocks a push, so it never claims a pause either.
    fileprivate func applyPausedCard() {
        let paused = configRepo?.visibility == .publicRepo
        pausedCard.isHidden = !paused
        guard paused else { return }
        let repo = ConfigRepoPrivacy.repoFullName ?? "The config repository"
        var subline = "\(repo) is public on GitHub. Grand Line will not push dotfiles, tasks, notes, runbooks "
            + "or backups to a public repository. Make it private to resume."
        if let at = configRepo?.at { subline += " Checked \(Self.relative(at))." }
        pausedCard.configure(.init(tint: .critical, symbol: "exclamationmark.triangle.fill",
                                   title: "Pushing is paused", body: subline), theme: theme)
        openOnGitHubButton.isHidden = ConfigRepoPrivacy.settingsURL == nil
        checkAgainButton.title = isCheckingConfigRepo ? "Checking\u{2026}" : "Check again"
        checkAgainButton.isEnabled = !isCheckingConfigRepo
        pausedCard.applyTheme(theme)
    }

    @objc fileprivate func openConfigRepoSettings() {
        guard let url = ConfigRepoPrivacy.settingsURL else { return }
        WebNavigationPolicy.openExternally(url, from: "GitHub sync's config repo")
    }

    /// The same check every push runs first, run now. Off the main thread:
    /// it asks GitHub through `gh`.
    @objc fileprivate func checkConfigRepoAgain() {
        guard !isCheckingConfigRepo else { return }
        isCheckingConfigRepo = true
        applyPausedCard()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ConfigRepoPrivacy.check()
            DispatchQueue.main.async {
                self?.isCheckingConfigRepo = false
                self?.applyPausedCard()
            }
        }
    }

    fileprivate func renderForksSubtitle() {
        guard !isCheckingAll else { return }
        let checked = rows.compactMap(\.checkedAt).max()
        forksSubtitle.stringValue = checked.map { "checked \(Self.relative($0))" } ?? "not checked yet"
        setupSummary.render()
    }

    fileprivate func renderForksTable() {
        forksTable.setRows(rows.map(forkRow))
        renderForksSubtitle()
        onInspectorContentChanged?()
    }

    private func forkRow(_ row: GitHubSyncRow) -> HelmDataTable.Row {
        var tableRow = HelmDataTable.Row.record(row.repo.fullName)
        let failed = row.status == .checkFailed || row.status == .syncFailed || row.status.isDiverged
        // The reason an action stopped outranks the status line: "Diverged"
        // is already in the Behind column, and the conflict is the news.
        // S24: a failed check or sync says what failed, why and what to do -
        // the shape Health and Updates already use - and keeps the raw
        // command for Show Details.
        let explained = (row.status == .checkFailed || row.status == .syncFailed)
            ? Self.failureExplanation(detail: row.detail, syncing: row.status == .syncFailed).sentence : nil
        let subtitle = row.problem.map { "Not changed: \($0.reason)" }
            ?? explained ?? (failed || row.status.hasOwnCommits ? row.detail : nil)
        tableRow.cells["fork"] = .title(row.repo.fullName, subtitle: subtitle, subtitleIsCode: false,
                                        symbol: "point.3.connected.trianglepath.dotted", tint: .neutral, tintHex: nil)
        if let upstream = row.upstreamFullName ?? row.repo.manualUpstreamFullName {
            tableRow.cells["upstream"] = .code(upstream)
        } else {
            tableRow.cells["upstream"] = HelmDataTable.Cell.none
        }
        tableRow.cells["behind"] = behindCell(row.status)
        tableRow.cells["checked"] = row.checkedAt.map { .muted(Self.relative($0)) } ?? HelmDataTable.Cell.none
        let busy = row.status == .checking || row.status == .syncing
        if !busy {
            if let action = Self.syncAction(row.status) {
                tableRow.primary = .init(title: action.title, symbol: action.symbol) { [weak self] in
                    self?.requestSync(row)
                }
                tableRow.pinsPrimary = true
            }
            var menu: [HelmDataTable.Action] = []
            if let action = Self.syncAction(row.status) {
                menu.append(.init(title: action.menuTitle, symbol: action.symbol) { [weak self] in self?.requestSync(row) })
            }
            menu += [
                .init(title: "Check Now", symbol: "arrow.clockwise") { [weak self] in self?.check(row) },
                .init(title: "Show Details", symbol: "sidebar.right") { [weak self] in self?.showForkDetails(row) },
                .init(title: "Open on GitHub", symbol: "safari") { Self.openOnGitHub(row.repo.fullName) },
            ]
            if let url = row.problem?.compareURL {
                menu.append(.init(title: "Open Compare Page", symbol: "arrow.left.arrow.right") {
                    WebNavigationPolicy.openExternally(url, from: "GitHub sync's fork list")
                })
            }
            tableRow.menu = menu
        }
        tableRow.activate = { [weak self] in self?.showForkDetails(row) }
        return tableRow
    }

    /// S24: the gh failure a fork row shows, as what failed, why and what to
    /// do (`ScheduleFailureExplanation`, R5-UX-08's shape), from the cases gh
    /// actually reports. The raw output stays in Show Details.
    static func failureExplanation(detail: String, syncing: Bool) -> ScheduleFailureExplanation {
        let text = detail.lowercased()
        let what = syncing ? "Couldn't sync with upstream" : "Couldn't reach GitHub"
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["auth login", "not logged", "authentication", "http 401", "bad credentials"]) {
            return .init(whatFailed: what, why: "gh is not signed in on this Mac",
                         whatToDo: "run gh auth login, then Check again")
        }
        if has(["command not found", "no such file", "not installed", "executable"]) {
            return .init(whatFailed: what, why: "gh is not installed",
                         whatToDo: "install it from \(PlaceName.of(.updates)), then Check again")
        }
        if has(["rate limit", "http 403", "secondary rate"]) {
            return .init(whatFailed: what, why: "GitHub's API rate limit was reached",
                         whatToDo: "wait a few minutes, then Check again")
        }
        if has(["http 404", "not found", "could not resolve to a repository"]) {
            return .init(whatFailed: what, why: "GitHub does not know this repository, or it is private to another account",
                         whatToDo: "check its name, then Check again")
        }
        if has(["could not resolve host", "network", "offline", "timed out", "timeout", "connection"]) {
            return .init(whatFailed: what, why: "this Mac could not reach github.com",
                         whatToDo: "check the network, then Check again")
        }
        // Short enough that the next step survives the fork column's width.
        return .init(whatFailed: what, why: "no answer from gh", whatToDo: "Show Details, then Check again")
    }

    private func behindCell(_ status: GitHubSyncStatus) -> HelmDataTable.Cell {
        switch status {
        case .behind(let n): return .status("\(n) commit\(n == 1 ? "" : "s")", tint: .warn)
        case .inSync, .ahead: return .muted(StateWord.upToDate.label)
        case .diverged: return .status("Diverged", tint: .critical)
        case .notAFork: return .muted("Not a fork")
        case .checkFailed: return .status(StateWord.checkFailed.label, tint: .critical)
        case .syncFailed: return .status("Sync failed", tint: .critical)
        case .checking: return .muted(StateWord.checking.label)
        case .syncing: return .muted("Syncing\u{2026}")
        case .unknown: return .muted("Not checked")
        }
    }

    /// The one action a row offers to catch up with upstream, or `nil` when
    /// there is nothing to pull. One definition for the table's button, its
    /// menu and the inspector, so the three can never offer different things.
    static func syncAction(_ status: GitHubSyncStatus) -> (title: String, menuTitle: String, symbol: String)? {
        if status.showsMergeUpstream { return ("Merge", "Merge Upstream\u{2026}", "arrow.triangle.merge") }
        if status.showsSyncButton { return ("Sync", "Sync\u{2026}", "arrow.triangle.2.circlepath") }
        return nil
    }

    private func showForkDetails(_ row: GitHubSyncRow) {
        forksTable.select(key: row.repo.fullName)
        selectedForkName = row.repo.fullName
        onInspectorContentChanged?()
        onShowInspector?()
    }

    private func forkDetail(for row: GitHubSyncRow) -> WorkspaceDetail {
        var detail = WorkspaceDetail(symbol: "point.3.connected.trianglepath.dotted", kicker: "Fork",
                                     title: row.repo.fullName, subtitle: row.detail)
        detail.tint = .neutral
        if let upstream = row.upstreamFullName ?? row.repo.manualUpstreamFullName {
            detail.fields.append(.init("Upstream", upstream, isCode: true))
        }
        let (word, _, _) = pillVisuals(row.status)
        if !word.isEmpty { detail.fields.append(.init("Status", word)) }
        if let at = row.checkedAt { detail.fields.append(.init("Last checked", Self.relative(at))) }
        let lines = row.log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        detail.sections.append(.init("Output", row.log.isEmpty ? ["No output yet."] : lines, isCode: !row.log.isEmpty))
        if let problem = row.problem {
            detail.sections.append(.init("Why it was not changed", [problem.reason, problem.nextStep]))
        }
        if !(row.status == .checking || row.status == .syncing) {
            if let action = Self.syncAction(row.status) {
                detail.actions.append(.init(action.menuTitle, symbol: action.symbol, role: .primary) {
                    [weak self] in self?.requestSync(row)
                })
            }
            if let url = row.problem?.compareURL {
                detail.actions.append(.init("Open Compare Page", symbol: "arrow.left.arrow.right") {
                    WebNavigationPolicy.openExternally(url, from: "GitHub sync's fork details")
                })
            }
            detail.actions.append(.init("Check Now", symbol: "arrow.clockwise") { [weak self] in self?.check(row) })
            detail.actions.append(.init("Open on GitHub", symbol: "safari") { Self.openOnGitHub(row.repo.fullName) })
        }
        return detail
    }

    private static func openOnGitHub(_ fullName: String) {
        guard let url = URL(string: "https://github.com/\(fullName)") else { return }
        WebNavigationPolicy.openExternally(url, from: "GitHub sync's fork list")
    }

    /// "just now", "5m ago", "2h ago", the way Updates says when it checked.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

#if FM_SELFTESTS
extension GitHubSyncController {
    var debugIsCheckingAll: Bool { isCheckingAll }
    var debugForksTable: HelmDataTable { forksTable }
    var debugSetupSummary: SetupHeroRow { setupSummary }
    /// Mounted and not hidden: the floating bar never mounts the card at all.
    var debugPausedCardIsShown: Bool { pausedCard.superview != nil && !pausedCard.isHidden }
    var debugPausedTitle: String { pausedCard.debugTitle }
    var debugPausedBody: String { pausedCard.debugBody }
    var debugPausedNotice: HelmNotice { pausedCard }
    var debugPausedActions: [HelmButton] { [openOnGitHubButton, checkAgainButton] }
    var debugRefreshButton: HelmButton { refreshButton }
    var debugSyncAllButton: HelmButton { syncAllButton }
    /// Land a fixture check on a row through the same fields a real check
    /// writes, then the page's own render.
    func debugApplyCheck(index: Int, status: GitHubSyncStatus, upstream: String?, detail: String = "fixture",
                         log: String = "", at: Date = Date()) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        row.status = status
        row.upstreamFullName = upstream
        row.detail = detail
        row.log = log
        row.checkedAt = at
        render(row)
    }
}
#endif
