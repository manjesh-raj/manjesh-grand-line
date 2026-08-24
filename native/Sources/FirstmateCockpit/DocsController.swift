// Manjesh Grand Line - native macOS app.
//
// The `.docs` rail destination. `fm/grandline-docs-knowledge-foundation`
// ("Knowledge and speed", phase 1) restructured this from a single embedded
// browser into a multi-tab page - see AGENTS.md's "Knowledge" section for the
// full shape and what's explicitly deferred to later phases. The tab bar
// mirrors Shift's own fixed two-tab switcher (`ShiftController.buildTabRow`)
// - clickable `HoverHighlightView` pills, not `NSSegmentedControl` - since
// these 4 tabs are fixed and always present, not user-creatable/closeable
// like the Tools page's own multi-instance `TabChipView` strip.
//
// Tab 1, Playbook, is still the same locked-down embedded `WKWebView` onto
// the captain's real DevOps Playbook this page always was - Phase 7 of the
// UI audit moved its back/forward/reload/Open-Live-Site cluster out of a
// second 40pt bar of its own and into the one shared `HelmPageToolbar` (see
// `buildTabBar()`), but the web view, its navigation delegate, and the
// local-only load path are untouched. Tabs 2-3 are new: Runbooks (real
// CRUD, git-synced) and Postmortems (list/display only - generation is a
// later task). The original phase-1 build also shipped a 5th "Command
// Composer" tab that only ever showed an explanatory pointer at the real
// feature (Console's own "✨ Compose" toolbar button, see
// `ConsoleCommandComposer.swift` / `ConsoleComposerPopover.swift`) -
// `fm/grandline-composer-cleanup-and-polish` removed it outright once the
// captain confirmed it added nothing beyond that redirect message. This
// page's own in-page "Search" tab (real, scoped to Runbooks + Postmortems)
// was removed the same way by `fm/grandline-unified-search-fixes`, once
// phase 4's real, working `⌘K` unified search palette (`UnifiedSearch.swift`)
// made it a second, weaker entry point to the exact same content - the
// underlying `DocsKnowledgeSearch`/`UnifiedSearchIndex` logic that `⌘K`
// depends on is untouched, only this page's own duplicate UI is gone.
//
// Root view follows this app's own documented gotcha #8 (`AGENTS.md`): a
// plain `NSView` with `wantsLayer`/`HelmTheme` background, not
// `NSVisualEffectView` vibrancy.

import AppKit
import WebKit

final class DocsController: NSViewController, DaylightDrillActions {

    static let liveSiteURL = URL(string: "https://manjesh-raj.github.io/devops-playbook/")!

    /// `String`-backed so it can be the id `HelmSegmentedTabs` hands back - the
    /// shared component deals in caller-owned ids rather than indices.
    private enum DocsTab: String, CaseIterable {
        case playbook, runbooks, postmortems

        var title: String {
            switch self {
            case .playbook: return "Playbook"
            case .runbooks: return "Runbooks"
            case .postmortems: return "Postmortems"
            }
        }
    }

    private var activeTab: DocsTab = .playbook

    /// The shared page toolbar (Phase 7) - see `buildTabBar()`.
    private let pageToolbar = HelmPageToolbar()
    /// The Playbook tab's own *browser* navigation, in that toolbar's
    /// trailing slot. Deliberately the only thing left there: back / forward /
    /// reload act on the embedded web view a few points below them, so
    /// hoisting them into the shell's drill header would separate them from
    /// the thing they drive. Every page-*level* action (Open Live Site, New
    /// Runbook) moved into that header instead - §6.4's action cluster.
    private let playbookActions = NSStackView()
    /// The Runbooks tab's primary action, now in the drill header's cluster
    /// rather than this page's toolbar - see `drillHeaderActions`.
    private let newRunbookButton = HelmButton(title: "New Runbook", variant: .primary, symbol: "plus")
    /// The tab switcher, now the app's shared `HelmSegmentedTabs`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 6). This page used to
    /// build **bare pills** on a 44pt divider bar - and the audit's finding was
    /// that the pill construction here and Shift's segmented capsule were
    /// already byte-for-byte identical code (12pt medium label, radius 7, 10/6
    /// insets, accent wash when active); only the wrapper differed, so one
    /// recipe rendered as two different-looking controls a rail click apart.
    /// Adopting the capsule is §6.4's own recommended direction for this page.
    private let tabs = HelmSegmentedTabs(items: DocsTab.allCases.map {
        .init(id: $0.rawValue, title: $0.title)
    }, selected: DocsTab.playbook.rawValue)
    /// Keeps `ClosureSleeve` targets alive for as long as the controls they
    /// are attached to exist. Since Daylight Phase 4 slice 5 this holds only
    /// the runbook editor's three buttons, appended once in
    /// `buildRunbookEditor` - the grid's cards used to append one per card on
    /// every rebuild and nothing ever cleared it, so it grew for the life of
    /// the process. `HelmPlateCard` takes its actions as plain closures, so
    /// there is nothing per-card to retain any more.
    private var rowSleeves: [ClosureSleeve] = []
    /// The plates built by `buildDocCard`, one list per tab so reloading one
    /// tab's grid never drops the other's references. Each list is emptied by
    /// its own tab's `rebuild*Grid`, which also removes the rows holding them -
    /// so the plates deallocate and unregister their own theme observations.
    /// A `HelmPlateCard` themes itself, so this exists to re-theme a plate
    /// built between two theme changes, not to paint one.
    private var runbookRowCards: [HelmPlateCard] = []
    private var postmortemRowCards: [HelmPlateCard] = []

    private let runbookStore = DocsRunbookStore()

    // MARK: Drill header (Daylight §6.4)

    /// Set by `AppShellController`. Called - never written to the header
    /// directly - whenever this page's own live numbers or action cluster
    /// change: the header belongs to the shell, and two owners of one view is
    /// how they start disagreeing.
    var onDrillSubtitleChanged: (() -> Void)?
    var onDrillActionsChanged: (() -> Void)?

    /// §6.4's action cluster: the showing tab's *page-level* primary action.
    /// The same button instance moves in and out (Hosts' precedent) rather
    /// than a copy being built, so the target and tooltip this page set on it
    /// survive every tab switch.
    ///
    /// Empty while the runbook editor is open: "New Runbook" beside a form
    /// that is already creating one reads as a second, competing action - the
    /// exact rule the toolbar gate it replaces already encoded. Postmortems
    /// has no page-level action at all (generation happens in SRE Lead), so it
    /// answers empty rather than being given an invented one.
    var drillHeaderActions: [NSView] {
        switch activeTab {
        case .playbook: return [openLiveButton]
        case .runbooks: return runbookEditorContainer.isHidden ? [newRunbookButton] : []
        case .postmortems: return []
        }
    }

    /// §6.4's live subtitle - the counts this page already reads off
    /// `DocsRunbookStore`, plus the Playbook tab's real sync state. Nothing
    /// new is collected, and nothing is fabricated: an unsynced playbook says
    /// so rather than claiming an offline copy exists.
    var drillHeaderSubtitle: String? {
        func plural(_ n: Int, _ one: String, _ many: String) -> String {
            "\(n) \(n == 1 ? one : many)"
        }
        switch activeTab {
        case .playbook:
            return DocsStore.isSynced ? "DevOps Playbook \u{00B7} offline copy" : "Playbook not synced yet"
        case .runbooks:
            // The list the grid below is *actually* rendering, not a fresh
            // directory scan - so the header and the grid cannot disagree, and
            // reading the subtitle costs no disk. `showTab` reloads the list
            // before it asks for the subtitle, so this is never stale.
            let count = runbookGridItems.count
            return count == 0 ? "No runbooks yet" : plural(count, "runbook", "runbooks")
        case .postmortems:
            let count = postmortemGridItems.count
            return count == 0 ? "No postmortems yet" : plural(count, "postmortem", "postmortems")
        }
    }

    // MARK: Playbook (unchanged from before this task)

    private var webView: WKWebView!
    private var backButton: HelmButton!
    private var forwardButton: HelmButton!
    private var reloadButton: HelmButton!
    private let openLiveButton = HelmButton(title: "", variant: .secondary, symbol: "arrow.up.forward.square")
    private let emptyStateContainer = NSView()
    /// §7's radius-16 card around the embedded playbook - see
    /// `buildPlaybookContainer()`.
    private let playbookCard = NSView()
    private static let playbookCardInset: CGFloat = HelmMetrics.s3
    private var playbookEmptyState: HelmEmptyState?
    private let syncButton = HelmButton(title: "", variant: .primary)
    private let syncSpinner = NSProgressIndicator()
    private var isSyncing = false
    private let playbookContainer = NSView()

    // MARK: Runbooks

    private let runbooksContainer = NSView()
    private let runbookListScroll = NSScrollView()
    private let runbookListStack = NSStackView()
    /// `nil` = showing the list. `.some(id)` = editing an existing runbook.
    /// A brand-new (unsaved) runbook is represented separately - see
    /// `editingIsNew`.
    private var editingRunbookID: String?
    private var editingIsNew = false
    private let runbookEditorContainer = NSView()
    private let runbookTitleField = HelmTextField(placeholder: "Title")
    private let runbookBodyScroll = NSScrollView()
    private let runbookBodyTextView = NSTextView()
    private let runbookSaveButton = HelmButton(title: "", variant: .primary)
    private let runbookCancelButton = HelmButton(title: "", variant: .secondary)
    private let runbookDeleteButton = HelmButton(title: "", variant: .destructive)
    private let runbookEditorTitleLabel = NSTextField(labelWithString: "")
    /// The list-state container (header row + scrollable list) - kept as a
    /// property so it can be hidden whenever `runbookEditorContainer` is
    /// shown (and vice versa). Both are pinned to the same full-bleed
    /// anchors inside `runbooksContainer`, so without this the two views
    /// render on top of each other - see `fm/grandline-docs-runbook-editor-
    /// overlap-fix`'s AGENTS.md note for the real captain-reported bug this
    /// fixed (doubled title text, list content faintly visible under the
    /// editor).
    private let runbookListContainerStack = NSStackView()

    // MARK: Postmortems

    private let postmortemsContainer = NSView()
    private let postmortemListScroll = NSScrollView()
    private let postmortemListStack = NSStackView()
    private let postmortemDetailScroll = NSScrollView()
    private let postmortemDetailTextView = NSTextView()
    private let postmortemEmptyState = HelmEmptyState(
        symbol: "doc.text.magnifyingglass",
        body: "No postmortems yet. Generate one from an SRE Lead investigation and it will appear here.",
        hue: RailDestination.docs.domainHue)
    /// Only built while the runbook grid is genuinely empty, so it is optional
    /// rather than a stored instance.
    private var runbookGridEmptyState: HelmEmptyState?
    private var selectedPostmortemID: String?

    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        root.addSubview(pageToolbar)
        // `pageToolbar`'s own internal constraints are self-contained, but
        // these three reference `root`, so they can only be activated once it
        // is actually a subview - see `buildTabBar()`'s doc comment for the
        // "no common ancestor" exception this file threw once before.
        NSLayoutConstraint.activate([
            pageToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            pageToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        buildTabBar()

        buildPlaybookContainer()
        buildRunbooksContainer()
        buildPostmortemsContainer()

        for container in [playbookContainer, runbooksContainer, postmortemsContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                container.topAnchor.constraint(equalTo: pageToolbar.bottomAnchor),
                container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        DocsSyncCenter.observe { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.loadDocsIfAvailable()
        }

        // Re-flow the Runbooks/Postmortems grids' column count on window
        // resize, mirroring `ToolsController.containerWidthMayHaveChanged` -
        // the window's own resize notification, not `viewDidLayout()`, since
        // this page is a body child of `AppShellController`, not the
        // window's own contentViewController (the only one AppKit guarantees
        // that hook for).
        NotificationCenter.default.addObserver(self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil)

        applyTheme()
        loadDocsIfAvailable()
        showTab(.playbook)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateNavButtons()
        if activeTab == .runbooks { reloadRunbooksList() }
        if activeTab == .postmortems { reloadPostmortemsList() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Same reasoning as `ToolsController.viewDidAppear`: the grids'
        // very first build happens before the view has a real width to
        // measure, so refine it against the real width now that the view is
        // actually on screen, rather than waiting for the first resize.
        containerWidthMayHaveChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Real widths the Runbooks/Postmortems grids last laid themselves out
    /// against - `containerWidthMayHaveChanged` re-flows the column count
    /// whenever either drifts by more than a point, tracked separately since
    /// resizing while the grid isn't visible shouldn't force a rebuild.
    private var lastRunbookGridWidth: CGFloat = 0
    private var lastPostmortemGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        if let note, let win = note.object as? NSWindow, win !== view.window { return }
        guard !view.isHidden else { return }
        if activeTab == .runbooks {
            view.layoutSubtreeIfNeeded()
            let width = runbookListStack.frame.width
            if width > 0, abs(width - lastRunbookGridWidth) > 1 {
                lastRunbookGridWidth = width
                rebuildRunbookGrid()
            }
        } else if activeTab == .postmortems {
            view.layoutSubtreeIfNeeded()
            let width = postmortemListStack.frame.width
            if width > 0, abs(width - lastPostmortemGridWidth) > 1 {
                lastPostmortemGridWidth = width
                rebuildPostmortemGrid()
            }
        }
    }

    // MARK: Tab bar

    /// Phase 7, audit §3.2's "Page toolbars" / §4.10. Two things changed here,
    /// and the second is why this page ended up with the largest diff of the
    /// three:
    ///
    /// 1. The bar itself is `HelmPageToolbar` - one height, fill, hairline and
    ///    inset shared with Console and Tools, rather than this page's own
    ///    hand-rolled 44pt `NSView` and divider.
    /// 2. **This page's second bar is gone.** The Playbook tab carried its own
    ///    40pt toolbar *inside* the tab (back / forward / reload, a title
    ///    reading "DevOps Playbook", and "Open Live Site"), stacked directly
    ///    under the tab bar - the audit's "Console adds a second horizontal
    ///    chrome bar; Tools adds a third" finding, in its worst form, since
    ///    here both bars belonged to the same page. Those controls now live in
    ///    this one toolbar's trailing slot, shown only while their own tab is
    ///    active (`updateToolbarActions`). The "DevOps Playbook" label went
    ///    with the bar: the tab pill two inches to its left already says
    ///    "Playbook".
    ///
    /// The Runbooks tab's own "+ New Runbook" and count moved the same way,
    /// which is what let its in-page "Runbooks" heading go - a heading that
    /// restated the active tab pill directly above it. Same for Postmortems.
    private func buildTabBar() {
        tabs.onSelect = { [weak self] id in
            guard let self, let tab = DocsTab(rawValue: id) else { return }
            self.showTab(tab)
        }
        pageToolbar.setLeading(tabs)

        buildPlaybookToolbarActions()
        buildRunbooksToolbarActions()

        // Hidden arranged subviews of an `NSStackView` drop out of layout
        // entirely (unlike an ordinary hidden `NSView` - AGENTS.md gotcha
        // (11)), so the inactive tabs' action groups take up no width.
        let actions = NSStackView(views: [playbookActions])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        pageToolbar.setTrailing(actions)
        updateToolbarActions()
    }

    /// The Playbook tab's own actions, in the shared toolbar's trailing slot.
    private func buildPlaybookToolbarActions() {
        backButton = HelmPageToolbar.iconButton(symbol: "chevron.left", tooltip: "Back",
                                                target: self, action: #selector(backTapped))
        forwardButton = HelmPageToolbar.iconButton(symbol: "chevron.right", tooltip: "Forward",
                                                   target: self, action: #selector(forwardTapped))
        reloadButton = HelmPageToolbar.iconButton(symbol: "arrow.clockwise",
                                                  tooltip: "Reload (local copy only)",
                                                  target: self, action: #selector(reloadTapped))

        openLiveButton.title = "Open Live Site"
        openLiveButton.controlSize = .small
        openLiveButton.target = self
        openLiveButton.action = #selector(openLiveTapped)
        openLiveButton.translatesAutoresizingMaskIntoConstraints = false

        playbookActions.setViews([backButton, forwardButton, reloadButton], in: .leading)
        playbookActions.orientation = .horizontal
        playbookActions.alignment = .centerY
        playbookActions.spacing = HelmMetrics.s1
        playbookActions.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The Runbooks tab's primary action. It lives in the shell's drill
    /// header now (§6.4), so this only builds it - `drillHeaderActions`
    /// decides when it is on screen. The "N runbooks" count that used to sit
    /// beside it moved into `drillHeaderSubtitle`, where it reads as the
    /// destination's own live line rather than a label floating in a toolbar.
    private func buildRunbooksToolbarActions() {
        newRunbookButton.controlSize = .small
        newRunbookButton.target = self
        newRunbookButton.action = #selector(newRunbookTapped)
        newRunbookButton.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func newRunbookTapped() { beginNewRunbook() }

    /// The browser nav triplet is only meaningful on the tab that owns a
    /// browser. Everything else the toolbar used to gate now lives in the
    /// drill header, which re-reads `drillHeaderActions` on the same events.
    private func updateToolbarActions() {
        playbookActions.isHidden = activeTab != .playbook
        onDrillActionsChanged?()
        onDrillSubtitleChanged?()
    }

    private func showTab(_ tab: DocsTab) {
        activeTab = tab
        // A no-op on a real pill click (which has already moved it), needed for
        // `openRunbook(id:)`/`openPostmortem(id:)` and the ⌘K palette, which
        // reach a tab without one.
        tabs.select(tab.rawValue)
        playbookContainer.isHidden = tab != .playbook
        runbooksContainer.isHidden = tab != .runbooks
        postmortemsContainer.isHidden = tab != .postmortems
        if tab == .runbooks { reloadRunbooksList() }
        if tab == .postmortems { reloadPostmortemsList() }
        updateToolbarActions()
        applyTheme()
    }

    // MARK: Playbook (unchanged behavior from before this task)

    private func buildPlaybookContainer() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        buildEmptyState()

        // Daylight §7: "playbook webview untouched inside a radius-16 card".
        // The web view, its navigation delegate and the local-only load path
        // are byte-for-byte what they were - only the surround is new: the
        // page's own card (`HelmMetrics.dSurface` under Daylight, the shared
        // card radius elsewhere) instead of a full-bleed browser filling the
        // destination edge to edge.
        //
        // The card clips (a rounded fill has to), which is why it carries no
        // shadow: a clipping layer casts none, and the two-layer arrangement
        // that would fix it buys nothing here - this card is the whole tab
        // body, so there is no sibling surface for it to float above.
        playbookCard.translatesAutoresizingMaskIntoConstraints = false
        playbookCard.wantsLayer = true
        playbookCard.layer?.masksToBounds = true
        playbookContainer.addSubview(playbookCard)

        playbookCard.addSubview(webView)
        playbookCard.addSubview(emptyStateContainer)
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            playbookCard.leadingAnchor.constraint(equalTo: playbookContainer.leadingAnchor,
                                                  constant: Self.playbookCardInset),
            playbookCard.trailingAnchor.constraint(equalTo: playbookContainer.trailingAnchor,
                                                   constant: -Self.playbookCardInset),
            playbookCard.topAnchor.constraint(equalTo: playbookContainer.topAnchor,
                                              constant: Self.playbookCardInset),
            playbookCard.bottomAnchor.constraint(equalTo: playbookContainer.bottomAnchor,
                                                 constant: -Self.playbookCardInset),

            webView.leadingAnchor.constraint(equalTo: playbookCard.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: playbookCard.trailingAnchor),
            webView.topAnchor.constraint(equalTo: playbookCard.topAnchor),
            webView.bottomAnchor.constraint(equalTo: playbookCard.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: playbookCard.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: playbookCard.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: playbookCard.topAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: playbookCard.bottomAnchor),
        ])
    }

    @objc private func backTapped() { webView.goBack() }
    @objc private func forwardTapped() { webView.goForward() }
    @objc private func reloadTapped() { loadDocsIfAvailable() }
    @objc private func openLiveTapped() { NSWorkspace.shared.open(Self.liveSiteURL) }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    /// The Playbook's own empty state, now the app's shared `HelmEmptyState`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 5). This state was §3.2's
    /// "most complete one" and is what the shared component's `.standard` size
    /// *is* - a 40pt glyph over a real title, body copy and an action. The
    /// action row stays caller-owned, so "Sync Now" is still the same
    /// `HelmButton` this page enables/disables around its own async sync, with
    /// the same spinner beside it.
    private func buildEmptyState() {
        syncButton.title = "Sync Now"
        syncButton.controlSize = .regular
        syncButton.target = self
        syncButton.action = #selector(syncNowTapped)
        syncButton.translatesAutoresizingMaskIntoConstraints = false

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isIndeterminate = true
        syncSpinner.isHidden = true
        syncSpinner.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [syncButton, syncSpinner])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let empty = HelmEmptyState(symbol: "book.closed",
                                   title: "Docs not synced yet",
                                   body: "The DevOps Playbook hasn't been synced to this Mac yet. Sync it once to browse it here, fully offline afterward.",
                                   size: .standard,
                                   accessory: actionRow,
                                   hue: RailDestination.docs.domainHue)
        playbookEmptyState = empty
        emptyStateContainer.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: emptyStateContainer.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: emptyStateContainer.trailingAnchor),
            empty.topAnchor.constraint(equalTo: emptyStateContainer.topAnchor),
            empty.bottomAnchor.constraint(equalTo: emptyStateContainer.bottomAnchor),
        ])
    }

    @objc private func syncNowTapped() {
        guard !isSyncing else { return }
        isSyncing = true
        syncButton.isEnabled = false
        syncSpinner.isHidden = false
        syncSpinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DocsSyncSource.update()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSyncing = false
                self.syncButton.isEnabled = true
                self.syncSpinner.isHidden = true
                self.syncSpinner.stopAnimation(nil)
                if outcome.ok {
                    self.loadDocsIfAvailable()
                } else if let container = self.view.window?.contentView {
                    Toast.show(in: container, message: "Docs sync failed: \(outcome.detail)")
                }
            }
        }
    }

    private func loadDocsIfAvailable() {
        defer { onDrillSubtitleChanged?() }
        guard DocsStore.isSynced else {
            webView.isHidden = true
            emptyStateContainer.isHidden = false
            return
        }
        emptyStateContainer.isHidden = true
        webView.isHidden = false
        if webView.url == nil {
            webView.loadFileURL(DocsStore.indexURL, allowingReadAccessTo: DocsStore.folderURL)
        } else {
            webView.reload()
        }
    }

    // MARK: Runbooks

    private func buildRunbooksContainer() {
        // No in-page "Runbooks" heading: it restated the active tab pill
        // directly above it (audit §4.10 / Phase 7). Its row's two real
        // contents - the count and "New Runbook" - are in the shared page
        // toolbar now, see `buildRunbooksToolbarActions()`.
        runbookListStack.orientation = .vertical
        runbookListStack.alignment = .leading
        runbookListStack.spacing = Self.docCardSpacing
        runbookListStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView()` - see AGENTS.md's Docs section
        // and AppKit gotcha (9): a non-flipped document view puts y=0 at the
        // *bottom*, so content shorter than the viewport (the common case
        // here) rests against the bottom of the scroll area instead of the
        // top, leaving a large empty gap above the rows.
        let listContent = FlippedView()
        listContent.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(runbookListStack)
        NSLayoutConstraint.activate([
            runbookListStack.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            runbookListStack.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            runbookListStack.topAnchor.constraint(equalTo: listContent.topAnchor),
            runbookListStack.bottomAnchor.constraint(lessThanOrEqualTo: listContent.bottomAnchor),
        ])

        runbookListScroll.documentView = listContent
        runbookListScroll.hasVerticalScroller = true
        runbookListScroll.drawsBackground = false
        runbookListScroll.translatesAutoresizingMaskIntoConstraints = false
        // `==`, not `>=` - the grid's cards are now sized responsively to
        // whatever width is actually available (`rebuildRunbookGrid`,
        // matching `ToolsController.rebuildGrid`'s own approach), so there's
        // no fixed-width card that could need the document view to grow past
        // the viewport.
        listContent.widthAnchor.constraint(equalTo: runbookListScroll.contentView.widthAnchor).isActive = true

        let listStack = runbookListContainerStack
        listStack.setViews([runbookListScroll], in: .leading)
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        buildRunbookEditor()

        // `runbookEditorContainer` is a bare `NSView()` that never had this
        // set - see AGENTS.md's "AppKit gotchas" entry (3)/(11) for the full
        // mechanism: left at its default `true`, AppKit also synthesizes
        // required constraints pinning the view to its zero-size initial
        // frame, which fight the explicit fill constraints below the moment
        // the window tries to grow, and a contentViewController-driven
        // window resolves that by snapping its own frame back down instead
        // of breaking either required constraint.
        runbookEditorContainer.translatesAutoresizingMaskIntoConstraints = false

        runbooksContainer.addSubview(listStack)
        runbooksContainer.addSubview(runbookEditorContainer)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: runbooksContainer.leadingAnchor, constant: 18),
            listStack.trailingAnchor.constraint(equalTo: runbooksContainer.trailingAnchor, constant: -18),
            listStack.topAnchor.constraint(equalTo: runbooksContainer.topAnchor, constant: 16),
            listStack.bottomAnchor.constraint(equalTo: runbooksContainer.bottomAnchor, constant: -16),
            runbookListScroll.widthAnchor.constraint(equalTo: listStack.widthAnchor),

            runbookEditorContainer.leadingAnchor.constraint(equalTo: runbooksContainer.leadingAnchor, constant: 18),
            runbookEditorContainer.trailingAnchor.constraint(equalTo: runbooksContainer.trailingAnchor, constant: -18),
            runbookEditorContainer.topAnchor.constraint(equalTo: runbooksContainer.topAnchor, constant: 16),
            runbookEditorContainer.bottomAnchor.constraint(equalTo: runbooksContainer.bottomAnchor, constant: -16),
        ])
        runbookEditorContainer.isHidden = true
    }

    private func buildRunbookEditor() {
        runbookEditorTitleLabel.font = HelmType.sectionTitle()
        runbookEditorTitleLabel.translatesAutoresizingMaskIntoConstraints = false


        runbookBodyTextView.isRichText = false
        runbookBodyTextView.font = HelmType.code()
        runbookBodyTextView.isEditable = true
        runbookBodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        runbookBodyTextView.isAutomaticDashSubstitutionEnabled = false
        runbookBodyTextView.textContainerInset = NSSize(width: 8, height: 8)
        runbookBodyScroll.documentView = runbookBodyTextView
        runbookBodyScroll.hasVerticalScroller = true
        runbookBodyScroll.borderType = .noBorder
        runbookBodyScroll.drawsBackground = false
        // §6.9: the well *is* the input surface, so the scroll view carries the
        // fill/border/radius and the text view inside paints nothing of its
        // own beyond matching that fill (`applyTheme`).
        HelmField.makeSunken(runbookBodyScroll)
        runbookBodyScroll.translatesAutoresizingMaskIntoConstraints = false

        runbookSaveButton.title = "Save"
        runbookSaveButton.keyEquivalent = "\r"
        let saveSleeve = ClosureSleeve { [weak self] in self?.saveRunbookEditor() }
        rowSleeves.append(saveSleeve)
        runbookSaveButton.target = saveSleeve
        runbookSaveButton.action = #selector(ClosureSleeve.invoke)
        runbookSaveButton.translatesAutoresizingMaskIntoConstraints = false

        runbookCancelButton.title = "Cancel"
        let cancelSleeve = ClosureSleeve { [weak self] in self?.cancelRunbookEditor() }
        rowSleeves.append(cancelSleeve)
        runbookCancelButton.target = cancelSleeve
        runbookCancelButton.action = #selector(ClosureSleeve.invoke)
        runbookCancelButton.translatesAutoresizingMaskIntoConstraints = false

        runbookDeleteButton.title = "Delete"
        let deleteSleeve = ClosureSleeve { [weak self] in self?.confirmDeleteEditingRunbook() }
        rowSleeves.append(deleteSleeve)
        runbookDeleteButton.target = deleteSleeve
        runbookDeleteButton.action = #selector(ClosureSleeve.invoke)
        runbookDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [runbookDeleteButton, NSView(), runbookCancelButton, runbookSaveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [runbookEditorTitleLabel, runbookTitleField, runbookBodyScroll, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        runbookEditorContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: runbookEditorContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: runbookEditorContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: runbookEditorContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: runbookEditorContainer.bottomAnchor),
            runbookTitleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            runbookBodyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            runbookBodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reloadRunbooksList() {
        let runbooks = runbookStore.listRunbooks()
        runbookGridItems = runbooks.map { runbook in
            // The card's own metadata line - "Kubernetes \u{00B7} 3 steps" -
            // read out of the runbook's own fenced steps
            // (`DocsRunbookMetadata`), matching the prototype
            // (`11-proposed-docs-runbooks.png`). "Updated N ago" is the
            // fallback for a document with no steps yet, and stays on the
            // card's tooltip either way so the timestamp is never lost.
            let updated = "Updated \(Self.relativeDate(runbook.modifiedAt))"
            let subtitle = DocsRunbookMetadata.runbookSubtitle(runbook) ?? updated
            return DocGridItem(
                title: runbook.title,
                subtitle: subtitle,
                tooltip: subtitle == updated ? runbook.title : "\(runbook.title) \u{2014} \(updated)",
                icon: "doc.text",
                tint: .info,
                onOpen: { [weak self] in self?.beginEditRunbook(runbook.id) },
                onDelete: { [weak self] in self?.confirmDeleteRunbook(id: runbook.id, title: runbook.title) }
            )
        }
        rebuildRunbookGrid()
        onDrillSubtitleChanged?()
    }

    /// Re-flows `runbookGridItems` into a wrapping multi-column grid, sized
    /// to whatever width `runbookListStack` actually has - the same
    /// columns-from-container-width + `.fillEqually` approach as
    /// `ToolsController.rebuildGrid()`, including its partial-last-row
    /// padding fix (`fm/cockpit-tools-page-partial-row-fix`): a row with
    /// fewer cards than a full row is padded out with invisible spacers so
    /// `.fillEqually` always divides by the same column count and a lone
    /// leftover card never stretches to fill the whole row.
    private func rebuildRunbookGrid() {
        runbookListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runbookRowCards.removeAll()
        if runbookGridItems.isEmpty {
            // Was a bare left-aligned `NSTextField` with no icon and no
            // container - one of the four §3.2 called out. This grid is the
            // whole tab body, so it gets the real treatment rather than a
            // sentence floating at the top-left.
            let empty = HelmEmptyState(symbol: "list.bullet.rectangle",
                                       body: "No runbooks yet. Create one to get started.",
                                       hue: RailDestination.docs.domainHue)
            empty.heightAnchor.constraint(equalToConstant: 110).isActive = true
            runbookGridEmptyState = empty
            runbookListStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
            applyTheme()
            return
        }
        runbookGridEmptyState = nil
        let (rows, cards) = layoutDocGrid(items: runbookGridItems, containerWidth: runbookListStack.frame.width)
        for row in rows {
            runbookListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
        }
        runbookRowCards = cards
        applyTheme()
    }

    private func beginNewRunbook() {
        editingIsNew = true
        editingRunbookID = nil
        runbookEditorTitleLabel.stringValue = "New Runbook"
        runbookTitleField.stringValue = ""
        runbookBodyTextView.string = ""
        runbookDeleteButton.isHidden = true
        runbookListContainerStack.isHidden = true
        runbookEditorContainer.isHidden = false
        updateToolbarActions()
        view.window?.makeFirstResponder(runbookTitleField)
    }

    private func beginEditRunbook(_ id: String) {
        guard let runbook = runbookStore.listRunbooks().first(where: { $0.id == id }) else { return }
        editingIsNew = false
        editingRunbookID = id
        runbookEditorTitleLabel.stringValue = "Edit Runbook"
        runbookTitleField.stringValue = runbook.title
        runbookBodyTextView.string = runbook.content
        runbookDeleteButton.isHidden = false
        runbookListContainerStack.isHidden = true
        runbookEditorContainer.isHidden = false
        updateToolbarActions()
    }

    private func cancelRunbookEditor() {
        runbookEditorContainer.isHidden = true
        runbookListContainerStack.isHidden = false
        updateToolbarActions()
        editingRunbookID = nil
        editingIsNew = false
    }

    private func saveRunbookEditor() {
        let title = runbookTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = runbookBodyTextView.string
        guard !title.isEmpty else {
            if let container = view.window?.contentView { Toast.show(in: container, message: "A runbook needs a title") }
            return
        }
        // Keep the stored markdown's own leading "# Title" in sync with the
        // title field, so `DocsRunbookStore.titleFromContent` (and this
        // page's list) reflect a rename without a stale heading.
        let content = Self.contentWithHeading(title: title, body: body)
        if editingIsNew {
            runbookStore.createRunbook(title: title, content: content)
        } else if let id = editingRunbookID {
            runbookStore.updateRunbook(id: id, content: content)
        }
        runbookEditorContainer.isHidden = true
        runbookListContainerStack.isHidden = false
        updateToolbarActions()
        editingRunbookID = nil
        editingIsNew = false
        reloadRunbooksList()
        if let container = view.window?.contentView { Toast.show(in: container, message: "Runbook saved") }
    }

    private func confirmDeleteEditingRunbook() {
        guard let id = editingRunbookID else { return }
        confirmDeleteRunbook(id: id, title: runbookTitleField.stringValue, dismissingEditor: true)
    }

    private func confirmDeleteRunbook(id: String, title: String, dismissingEditor: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(title)\"?"
        alert.informativeText = "This removes the runbook file and syncs the deletion."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runbookStore.deleteRunbook(id: id)
        if dismissingEditor {
            runbookEditorContainer.isHidden = true
            runbookListContainerStack.isHidden = false
            editingRunbookID = nil
        }
        reloadRunbooksList()
    }

    /// Ensures `content` starts with `# title` - replaces an existing leading
    /// heading, or prepends one if the body has none, so the title field is
    /// always the source of truth for what's shown in the list.
    private static func contentWithHeading(title: String, body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            lines[0] = "# \(title)"
        } else {
            lines.insert("# \(title)", at: 0)
            lines.insert("", at: 1)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Postmortems

    private func buildPostmortemsContainer() {
        // No in-page "Postmortems" heading either - same reason as Runbooks
        // above.
        postmortemListStack.orientation = .vertical
        postmortemListStack.alignment = .leading
        postmortemListStack.spacing = Self.docCardSpacing
        postmortemListStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView()` - same top-anchoring fix as
        // the Runbooks list above (AppKit gotcha (9) in AGENTS.md).
        let listContent = FlippedView()
        listContent.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(postmortemListStack)
        NSLayoutConstraint.activate([
            postmortemListStack.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            postmortemListStack.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            postmortemListStack.topAnchor.constraint(equalTo: listContent.topAnchor),
            postmortemListStack.bottomAnchor.constraint(lessThanOrEqualTo: listContent.bottomAnchor),
        ])
        postmortemListScroll.documentView = listContent
        postmortemListScroll.hasVerticalScroller = true
        postmortemListScroll.drawsBackground = false
        postmortemListScroll.translatesAutoresizingMaskIntoConstraints = false
        // `==`, not `>=` - see the matching comment on the Runbooks list's
        // own document-view width constraint above.
        listContent.widthAnchor.constraint(equalTo: postmortemListScroll.contentView.widthAnchor).isActive = true

        postmortemEmptyState.heightAnchor.constraint(equalToConstant: 110).isActive = true

        postmortemDetailTextView.isEditable = false
        postmortemDetailTextView.isRichText = false
        postmortemDetailTextView.font = HelmType.code()
        postmortemDetailTextView.textContainerInset = NSSize(width: 8, height: 8)
        postmortemDetailScroll.documentView = postmortemDetailTextView
        postmortemDetailScroll.hasVerticalScroller = true
        postmortemDetailScroll.borderType = .noBorder
        postmortemDetailScroll.drawsBackground = false
        HelmField.makeSunken(postmortemDetailScroll)
        postmortemDetailScroll.translatesAutoresizingMaskIntoConstraints = false
        postmortemDetailScroll.isHidden = true

        let stack = NSStackView(views: [postmortemEmptyState, postmortemListScroll, postmortemDetailScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        postmortemsContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: postmortemsContainer.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: postmortemsContainer.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: postmortemsContainer.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: postmortemsContainer.bottomAnchor, constant: -16),
            postmortemListScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            postmortemListScroll.heightAnchor.constraint(equalToConstant: 220),
            postmortemDetailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reloadPostmortemsList() {
        let postmortems = runbookStore.listPostmortems()
        postmortemEmptyState.isHidden = !postmortems.isEmpty
        postmortemListScroll.isHidden = postmortems.isEmpty
        postmortemGridItems = postmortems.map { postmortem in
            // A postmortem's own `## Root Cause` section is what its card
            // says (prototype `13-proposed-docs-postmortems.png`); the
            // timestamp falls back in when the document has no root cause
            // written yet.
            let updated = "Updated \(Self.relativeDate(postmortem.modifiedAt))"
            let subtitle = DocsRunbookMetadata.postmortemSubtitle(postmortem) ?? updated
            return DocGridItem(
                title: postmortem.title,
                subtitle: subtitle,
                tooltip: subtitle == updated ? postmortem.title : "\(postmortem.title) \u{2014} \(updated)",
                icon: "exclamationmark.triangle",
                tint: .warn,
                onOpen: { [weak self] in self?.showPostmortem(postmortem.id) },
                onDelete: nil
            )
        }
        rebuildPostmortemGrid()
        if selectedPostmortemID == nil {
            postmortemDetailScroll.isHidden = true
        }
        applyTheme()
        onDrillSubtitleChanged?()
    }

    /// Re-flows `postmortemGridItems` - see `rebuildRunbookGrid`'s doc
    /// comment, which this mirrors exactly.
    private func rebuildPostmortemGrid() {
        postmortemListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        postmortemRowCards.removeAll()
        guard !postmortemGridItems.isEmpty else { return }
        let (rows, cards) = layoutDocGrid(items: postmortemGridItems, containerWidth: postmortemListStack.frame.width)
        for row in rows {
            postmortemListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: postmortemListStack.widthAnchor).isActive = true
        }
        postmortemRowCards = cards
        applyTheme()
    }

    private func showPostmortem(_ id: String) {
        guard let postmortem = runbookStore.listPostmortems().first(where: { $0.id == id }) else { return }
        selectedPostmortemID = id
        postmortemDetailTextView.string = postmortem.content
        postmortemDetailScroll.isHidden = false
    }

    /// Entry points for the unified `⌘K` search palette
    /// (`UnifiedSearchController`, owned outside this page) - the one "open
    /// this runbook/postmortem" behavior, now that this page's own in-page
    /// Search tab (which used to duplicate this) is gone.
    func openRunbook(id: String) {
        showTab(.runbooks)
        beginEditRunbook(id)
    }

    func openPostmortem(id: String) {
        showTab(.postmortems)
        showPostmortem(id)
    }

    // MARK: Shared grid builder (Runbooks/Postmortems)

    /// One card's content, independent of layout - built fresh from disk on
    /// every `reloadRunbooksList`/`reloadPostmortemsList`, then re-laid-out
    /// (with no disk re-read) by `rebuildRunbookGrid`/`rebuildPostmortemGrid`
    /// on every window resize.
    private struct DocGridItem {
        let title: String
        let subtitle: String
        /// Hover text for the whole card. Carries what the one-line subtitle
        /// no longer has room for once it shows real metadata - the full
        /// title and the "Updated N ago" timestamp.
        var tooltip: String? = nil
        let icon: String
        let tint: HelmTint
        let onOpen: () -> Void
        let onDelete: (() -> Void)?
    }

    private var runbookGridItems: [DocGridItem] = []
    private var postmortemGridItems: [DocGridItem] = []

    /// A compact card - `IconTileView` + title + a short secondary line -
    /// laid out as a wrapping multi-column grid sized to the space actually
    /// available, matching the Tools page's own landing-grid treatment
    /// (`ToolsController.rebuildGrid()`) per the captain's explicit request
    /// to use that page's layout as the reference (`fm/grandline-docs-
    /// runbook-grid-layout`, superseding the prior single-column stacked-
    /// list shape from `fm/grandline-docs-runbook-list-compact-fix`).
    private static let docMinCardWidth: CGFloat = 260
    private static let docCardSpacing: CGFloat = 14
    /// Lays `items` out as a grid of rows, each row a `.fillEqually`
    /// horizontal stack of cards sized to `containerWidth` - byte-for-byte
    /// the same columns-from-width + partial-last-row-padding approach as
    /// `ToolsController.rebuildGrid()`. Returns the built rows (to add as
    /// arranged subviews of the caller's own vertical list stack) and the
    /// cards themselves (for `applyTheme()`'s re-tint pass).
    /// This page's own copy of Tools' column-count/spacer-padding math (its
    /// original doc comment said as much: "a direct port of
    /// `ToolsController.rebuildGrid`") is gone - Phase 7 moved that one
    /// definition into `HelmResponsiveGrid`. What is left here is what is
    /// genuinely this page's: which card to build, and collecting the built
    /// cards so `applyTheme` can re-tint their borders.
    private func layoutDocGrid(items: [DocGridItem], containerWidth: CGFloat) -> (rows: [NSView], cards: [HelmPlateCard]) {
        var cards: [HelmPlateCard] = []
        let rows = HelmResponsiveGrid.rows(items,
                                           containerWidth: containerWidth,
                                           minItemWidth: Self.docMinCardWidth,
                                           spacing: Self.docCardSpacing) { item, _ in
            // The width the grid computed is unused: a plate takes its width
            // from the row's `.fillEqually` distribution and its height from
            // its own constant, and it reads the real text-column width back
            // in `layout()` rather than being told an estimate up front.
            let card = self.buildDocCard(item)
            cards.append(card)
            return card
        }
        return (rows, cards)
    }

    /// Daylight §7: a "module-style plate" - `HelmPlateCard`, the shared
    /// sibling of the canvas's own `HelmModuleCard` (see that file's header
    /// for why it is a separate type). The compact `IconTileView` card this
    /// replaces had no visible affordance at all: the whole surface was a
    /// click target and nothing said so. The plate keeps that whole-surface
    /// click and adds §7's explicit Open button.
    ///
    /// The per-kind hue comes from the item's own `HelmTint` through
    /// `HelmDomainHue(tint:)` rather than a second mapping, so a runbook
    /// stays blue (Docs' own domain hue) and a postmortem stays amber exactly
    /// as they did before, in every palette.
    private func buildDocCard(_ item: DocGridItem) -> HelmPlateCard {
        let plate = HelmPlateCard()
        plate.configure(.init(title: item.title,
                              subtitle: item.subtitle,
                              symbol: item.icon,
                              hue: HelmDomainHue(tint: item.tint),
                              tooltip: item.tooltip,
                              onOpen: item.onOpen,
                              onDelete: item.onDelete,
                              deleteTooltip: "Delete"))
        return plate
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Daylight Phase 4 slice 5's suite reaches the real page rather than
    /// building components standalone - a plate built by a probe cannot prove
    /// this page wires one.
    func debugSelectTab(_ raw: String) {
        guard let tab = DocsTab(rawValue: raw) else { return }
        showTab(tab)
    }

    var debugActiveTabID: String { activeTab.rawValue }
    var debugRunbookPlates: [HelmPlateCard] { runbookRowCards }
    var debugPostmortemPlates: [HelmPlateCard] { postmortemRowCards }
    var debugPlaybookCard: NSView { playbookCard }
    var debugWebView: NSView { webView }
    var debugRunbookEditorIsOpen: Bool { !runbookEditorContainer.isHidden }
    func debugBeginNewRunbook() { beginNewRunbook() }
    func debugCancelRunbookEditor() { cancelRunbookEditor() }
    func debugReloadRunbooks() { reloadRunbooksList() }
    #endif

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Theme

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)

        for container in [playbookContainer, runbooksContainer, postmortemsContainer] {
            container.wantsLayer = true
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        // The page toolbar owns its own fill and hairline, and every button
        // in it is a `HelmButton` that re-derives its own tint - so there is
        // nothing here to re-colour for either.
        pageToolbar.applyTheme(theme)
        HelmCard.applyCardSurface(to: playbookCard, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        playbookEmptyState?.applyTheme(theme)
        emptyStateContainer.wantsLayer = true
        // Transparent, so the card's own fill shows through rather than a
        // second, differently-coloured rectangle inside it.
        emptyStateContainer.layer?.backgroundColor = NSColor.clear.cgColor

        tabs.applyTheme(theme)

        runbookEditorTitleLabel.textColor = ink
        // Both editors read as §6.9 wells: the scroll view owns the fill and
        // border, and the text view matches that fill rather than the card
        // surface (which under Daylight is white and would show the well's
        // own border wrapping a differently-coloured interior).
        HelmField.applySunken(to: runbookBodyScroll, theme: theme)
        runbookBodyTextView.textColor = HelmField.ink(theme)
        runbookBodyTextView.backgroundColor = HelmField.fill(theme)
        postmortemEmptyState.applyTheme(theme)
        runbookGridEmptyState?.applyTheme(theme)
        HelmField.applySunken(to: postmortemDetailScroll, theme: theme)
        postmortemDetailTextView.textColor = HelmField.ink(theme)
        postmortemDetailTextView.backgroundColor = HelmField.fill(theme)

        // A `HelmPlateCard` themes itself end to end - fill, border, ribbon,
        // shadow, both labels and (via `HelmGradientTile`'s own observation)
        // its tile. It also carries its own `ThemeManager` observation, so
        // this call is only here to keep a plate built *between* two theme
        // changes correct on the very next render; the hand-walk over each
        // card's subview tree that used to live here is gone with the bespoke
        // card it was reaching into.
        for cards in [runbookRowCards, postmortemRowCards] {
            for plate in cards { plate.applyTheme(theme) }
        }
    }
}

/// Retains a closure so it can be used as an `NSButton`/gesture-recognizer
/// target/action without needing a dedicated `@objc` method per row -
/// callers keep the sleeve alive (e.g. `DocsController.rowSleeves`) for as
/// long as the control it's attached to exists.
final class ClosureSleeve: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

extension DocsController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL {
            let docsPath = DocsStore.folderURL.standardizedFileURL.path
            if url.standardizedFileURL.path.hasPrefix(docsPath) {
                decisionHandler(.allow)
                return
            }
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavButtons()
    }
}
