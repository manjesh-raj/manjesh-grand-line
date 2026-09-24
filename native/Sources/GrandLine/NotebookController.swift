// Grand Line - native macOS app.
//
// The `.notebook` destination: F1 of full review #3 §8, the captain's own
// first pick out of that section's twenty-four recommendations.
//
// ## What it is
//
// Markdown pages in a tree, a Monaco-backed source editor, a live rendered
// preview beside it, `[[wiki-links]]` that navigate, a backlink panel, and a
// one-click dated note. Every page is a real `.md` file under
// `GrandLineDocs/notebook/` on the same git sync Runbooks and Postmortems
// already use - see `NotebookStore.swift` for the layout and why there is no
// index file.
//
// ## Three things it deliberately reuses rather than rebuilds
//
//   - **The editor is `CodePreviewWebView`, unchanged.** The vendored Monaco
//     bundle is already in this repo, already offline, already themed from
//     `HelmTheme`, already gated so a hidden destination costs nothing, and
//     already recovers from a jettisoned web content process. Its bridge is
//     content-agnostic - "here is an id, a language and some text" - so a
//     notebook page is a snippet whose language is `markdown`. Two instances
//     are safe: each owns its own `WKUserContentController`, so the handler
//     name they share is registered once per configuration, and
//     `window.GrandLineCodePreview` is a per-page global. Nothing about the
//     bundle changed for this feature.
//   - **The page tree is `HelmPageSidebar`**, the same column Poneglyph,
//     Schedules, Hosts and Tasks carry, with one section per folder.
//   - **The storage is `DocsRunbookStore`'s shape**, subtree and commit
//     message apart.
//
// ## The layout, and where it comes from
//
// The captain reviewed a mockup of this page before it was built (the F1
// panel of the `grandline-future-features-mockups-artifact` deck), and the
// arrangement here is that mockup's: the page tree on the left, the source
// and the preview as two equal cards, and a narrow right rail carrying
// Backlinks over a Page inspector. The two deliberate departures are stated
// where they happen - a view-mode switch the mockup does not show (a 1410pt
// window cannot hold three columns and two editors), and the "Saved"/"Live"
// chips folded into one status line rather than one chip per card.
//
// ## Persistence
//
// No Save button, exactly like Code Preview: the page's own 500ms debounce
// posts an edit, this controller writes the file, and the git debounce
// commits a few seconds later.

import AppKit

final class NotebookController: NSViewController, DaylightDrillActions {

    // MARK: State

    private let store: NotebookStore
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// The corpus this page is currently rendering. Re-read on appearance and
    /// after a write, never per keystroke - the whole point of holding it is
    /// that the resolver and the backlink index are built over it once.
    private var pages: [NotebookPage] = []
    private var resolver = NotebookLinkResolver(pages: [])
    private var index = NotebookBacklinkIndex(pages: [], resolver: NotebookLinkResolver(pages: []))
    private var overflowPages = 0

    /// The page open in the editor, or `nil` before the first load (and for a
    /// genuinely empty notebook).
    private var currentID: String?
    /// The live text of the open page - the editor's copy, which is ahead of
    /// disk by at most one debounce.
    private var currentContent = ""

    private var syncStatus: NotebookGitSync.Status = .synced
    private var lastError: String?
    private var hasRestored = false

    enum ViewMode: String, CaseIterable {
        case edit, split, preview

        var title: String {
            switch self {
            case .edit: return "Source"
            case .split: return "Split"
            case .preview: return "Preview"
            }
        }
    }

    /// **A departure from the mockup, and the reason for it.** The mockup
    /// draws source, preview and the right rail side by side. That is the
    /// right *default*, and it is what `.split` renders - but gotcha (13)'s
    /// own measurement is that this app's window is routinely 1033-1410pt
    /// wide, and three columns plus a 208pt page tree leaves each text column
    /// around 300pt, which is under the measure prose needs. So the shape is
    /// a switch with `.split` as the default, and the two single-pane modes
    /// exist for the width the captain actually has.
    private var mode: ViewMode = .split

    // MARK: Views

    private let toolbar = HelmPageToolbar()
    private let sidebar = HelmPageSidebar(surface: .panel, countStyle: .badge)
    private lazy var modeTabs = HelmSegmentedTabs(
        items: ViewMode.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: mode.rawValue, size: .compact)
    private lazy var findButton = HelmPageToolbar.iconButton(
        symbol: "magnifyingglass", tooltip: "Find in this page (\u{2318}F)",
        target: self, action: #selector(showFind))
    private lazy var railButton = HelmPageToolbar.iconButton(
        symbol: "sidebar.right", tooltip: "Show or hide backlinks and page details",
        target: self, action: #selector(toggleRail))
    private lazy var deleteButton = HelmPageToolbar.iconButton(
        symbol: "trash", tooltip: "Delete this page",
        target: self, action: #selector(deleteTapped))

    /// The drill header's own cluster (Daylight §6.4) - the mockup's two top
    /// bar buttons, hoisted to where every other destination's page-level
    /// actions live.
    private let todayButton = HelmButton(title: "Today's note", variant: .secondary, symbol: "sun.max")
    private let newPageButton = HelmButton(title: "New page", variant: .primary, symbol: "plus")

    private let editorCard = HelmCard()
    private let webView = CodePreviewWebView()
    private let editorOverlay = NSView()
    private var editorOverlayState: HelmEmptyState?

    private let previewCard = HelmCard()
    private let previewScroll = NSScrollView()
    private let previewDocument = FlippedView()
    private let preview = NotebookPreviewView()

    private let rail = NSView()
    private let backlinksCard = HelmCard()
    private let backlinksStack = NSStackView()
    private let inspectorCard = HelmCard()
    private let inspectorStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var railVisible = true
    private var railWidth: NSLayoutConstraint!
    /// The collapsed state's own constraint. Separate from `railWidth`, and
    /// **required**, for a reason gotcha (13) makes precise: a required
    /// *equality* on a fixed column is a floor on how narrow the window may
    /// get, which is why the visible width sits at 499 - but a required
    /// `width == 0` is a *maximum*, so it can never be a floor and it does
    /// beat the column's own content. Measured: at 499 alone the hidden rail
    /// still resolved to 154.5pt, because the cards inside it outrank it.
    private var railCollapse: NSLayoutConstraint!
    private var editorWidthTie: NSLayoutConstraint!
    private var themeObservation: ThemeObservation?
    private var fontObservation: FontSizeObservation?

    /// Keeps the backlink rows' click targets alive.
    private var backlinkSleeves: [ClosureSleeve] = []

    private static let gutter: CGFloat = HelmMetrics.s3
    static let railColumnWidth: CGFloat = 200

    // MARK: Init

    init(store: NotebookStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?
    var onDrillActionsChanged: (() -> Void)?

    var drillHeaderActions: [NSView] { [todayButton, newPageButton] }

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        if !CodePreviewAssets.isAvailable { return "The Monaco bundle is missing" }
        let count = pages.count
        // GL-14: an empty notebook and a notebook that has not loaded yet are
        // different states, and neither is "0 pages".
        guard hasRestored else { return "Opening the notebook\u{2026}" }
        let noun = count == 1 ? "1 page" : "\(count) pages"
        let more = overflowPages > 0 ? " (+\(overflowPages) not shown)" : ""
        return "\(noun)\(more) \u{00B7} \(syncSummary)"
    }

    /// One wording for the sync state, read by both the drill subtitle and
    /// the page's own status line - so the two can never disagree about
    /// whether the captain's writing has reached GitHub.
    private var syncSummary: String {
        switch syncStatus {
        case .synced: return store.gitSync == nil ? "saved on this machine" : "synced to manjesh-config"
        case .localChanges: return "saving\u{2026}"
        case .syncing: return "syncing\u{2026}"
        case .failed(let why): return "sync failed: \(why)"
        }
    }

    // MARK: Lifecycle

    override func loadView() {
        // Gotcha (8): a full-size destination's root is a plain layer-backed
        // `NSView` with a `HelmTheme` fill, never `NSVisualEffectView`
        // vibrancy - that material composites against the desktop, not
        // against this window.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.wantsLayer = true
        view = root

        buildToolbar(in: root)
        buildBody(in: root)
        buildActions()

        webView.onReady = { [weak self] in self?.editorBecameReady() }
        webView.onPageError = { [weak self] message in self?.report(error: message) }
        webView.onSnippetChanged = { [weak self] id, content in self?.pageEdited(id: id, content: content) }

        themeObservation = ThemeManager.shared.observe { [weak self, weak root] theme in
            guard let self else { return }
            // `ThemeManager.swift`'s checklist item 2, the one most often
            // missed: force the appearance so the field editor, the scroller
            // chrome and any menu follow the theme rather than the OS.
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self.theme = theme
            self.applyTheme()
        }
        fontObservation = FontSizeManager.shared.observe { [weak self] size in
            self?.webView.call("setFontSize", payload: ["size": size])
        }

        store.gitSync?.observeStatus { [weak self] status in
            guard let self else { return }
            self.syncStatus = status
            self.refreshStatusLine()
            self.onDrillSubtitleChanged?()
            // The one signal this page gets that the working tree moved,
            // which on a fresh machine is when the notebook first exists at
            // all. Same shape as `CodePreviewController`'s own late-clone
            // retry.
            self.retryLoadIfCloneArrivedLate()
        }

        if webView.activate() {
            showEditorOverlay(symbol: "book.pages",
                              title: "Opening the notebook\u{2026}",
                              body: "Monaco is loading from this machine. Nothing is fetched from the network.")
        } else {
            showEditorOverlay(symbol: "exclamationmark.triangle",
                              title: "No editor bundle",
                              body: CodePreviewAssets.missingBundleMessage)
            for control in [findButton, deleteButton] { control.isEnabled = false }
        }

        reload()
        applyTheme()
        applyMode()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        webView.refreshDisplayGating()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flushPendingEdits()
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    /// Called by the app delegate on quit, so the last keystrokes before ⌘Q
    /// are written and committed like every other edit. The ordering is the
    /// whole point, and is `CodePreviewController.shutdown`'s: the bridge
    /// round trip has to land *before* the git flush, or the commit misses
    /// the very keystrokes this exists to save.
    func shutdown() {
        flushPendingEdits(waitingUpTo: CodePreviewController.terminateEditFlushBudget)
        store.gitSync?.flushForTerminationNow()
    }

    private func flushPendingEdits(waitingUpTo wait: TimeInterval? = nil) {
        guard webView.isReady else { return }
        guard let wait else {
            webView.call("flush")
            return
        }
        var landed = false
        webView.call("flush") { _ in landed = true }
        let deadline = Date().addingTimeInterval(wait)
        while !landed, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if !landed {
            AppLog.lifecycle.info("""
                notebook: the page did not acknowledge its quit-time edit flush within \
                \(wait, privacy: .public)s - letting the app quit; every edit older than the \
                page's own debounce is already on disk
                """)
        }
    }

    // MARK: Building

    private func buildToolbar(in root: NSView) {
        root.addSubview(toolbar)
        modeTabs.translatesAutoresizingMaskIntoConstraints = false
        modeTabs.onSelect = { [weak self] id in
            guard let self, let picked = ViewMode(rawValue: id) else { return }
            self.mode = picked
            self.applyMode()
        }
        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toolbar.setLeading(HelmPageToolbar.group([modeTabs, statusLabel]))
        toolbar.setTrailing(HelmPageToolbar.group([findButton, railButton, deleteButton]))

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
        ])
    }

    private func buildActions() {
        todayButton.controlSize = .small
        todayButton.target = self
        todayButton.action = #selector(todayTapped)
        todayButton.translatesAutoresizingMaskIntoConstraints = false
        todayButton.toolTip = "Open today's dated page, creating it if it does not exist yet"

        newPageButton.controlSize = .small
        newPageButton.target = self
        newPageButton.action = #selector(newPageTapped)
        newPageButton.translatesAutoresizingMaskIntoConstraints = false
        newPageButton.toolTip = "Add a page to the folder you are in"
    }

    private func buildBody(in root: NSView) {
        sidebar.onSelect = { [weak self] id in self?.open(pageID: id) }
        root.addSubview(sidebar)

        buildEditorCard()
        buildPreviewCard()
        buildRail()

        root.addSubview(editorCard)
        root.addSubview(previewCard)
        root.addSubview(rail)

        railWidth = rail.widthAnchor.constraint(equalToConstant: Self.railColumnWidth)
        // Gotcha (13): a fixed column's width reaches `bodyContainer` through
        // this page, so a *required* one is a floor on how narrow the whole
        // window may get. 499 is below `NSLayoutPriorityWindowSizeStayPut` and
        // still beats every label beside it at any real width.
        railWidth.priority = HelmDaylightPriority.contentTie
        railCollapse = rail.widthAnchor.constraint(equalToConstant: 0)
        railCollapse.isActive = false

        // The two cards share the remaining width evenly in `.split`. The tie
        // is the one constraint `applyMode` swaps, so the three modes are one
        // activation each rather than three layouts.
        editorWidthTie = editorCard.widthAnchor.constraint(equalTo: previewCard.widthAnchor)
        editorWidthTie.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.gutter),
            sidebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: Self.gutter),
            // Gotcha (16): the column's own height is tied to the page, not
            // left to a low-priority content preference - a container whose
            // height nothing ties lets its content escape it.
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.gutter),

            editorCard.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: Self.gutter),
            editorCard.topAnchor.constraint(equalTo: sidebar.topAnchor),
            editorCard.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            previewCard.leadingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: Self.gutter),
            previewCard.topAnchor.constraint(equalTo: sidebar.topAnchor),
            previewCard.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            rail.leadingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: Self.gutter),
            rail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.gutter),
            rail.topAnchor.constraint(equalTo: sidebar.topAnchor),
            rail.bottomAnchor.constraint(lessThanOrEqualTo: sidebar.bottomAnchor),
            railWidth,
        ])
    }

    private func buildEditorCard() {
        editorCard.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.addSubview(webView)
        editorOverlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(editorOverlay)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            editorOverlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            editorOverlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            editorOverlay.topAnchor.constraint(equalTo: host.topAnchor),
            editorOverlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        editorCard.setHeader(symbol: "square.and.pencil", tint: .info,
                             titleLabel: editorTitleLabel, subtitleLabel: nil)
        editorCard.setBody(host)
    }

    private let editorTitleLabel = NSTextField(labelWithString: "Source")
    private let previewTitleLabel = NSTextField(labelWithString: "Preview")

    private func buildPreviewCard() {
        previewCard.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        // Gotcha (9): a plain `NSView()` document is not flipped, so content
        // shorter than the viewport rests against the *bottom* and leaves a
        // gap above the first heading. Every scroll-backed surface in this app
        // uses `FlippedView` for exactly this.
        previewDocument.translatesAutoresizingMaskIntoConstraints = false
        previewDocument.addSubview(preview)
        previewScroll.documentView = previewDocument

        NSLayoutConstraint.activate([
            // Gotcha (4): the document pins to the **clip** view, never to the
            // scroll view - a non-overlay scroller reserves a real ~15pt track
            // that narrows the clip view without narrowing `scroll`.
            previewDocument.widthAnchor.constraint(equalTo: previewScroll.contentView.widthAnchor),
            preview.leadingAnchor.constraint(equalTo: previewDocument.leadingAnchor, constant: HelmMetrics.s4),
            preview.trailingAnchor.constraint(equalTo: previewDocument.trailingAnchor, constant: -HelmMetrics.s4),
            preview.topAnchor.constraint(equalTo: previewDocument.topAnchor, constant: HelmMetrics.s3),
            preview.bottomAnchor.constraint(equalTo: previewDocument.bottomAnchor, constant: -HelmMetrics.s4),
        ])

        preview.onOpenPage = { [weak self] id in self?.open(pageID: id) }
        preview.onCreateMissingPage = { [weak self] target in self?.createMissingPage(named: target) }

        previewCard.setHeader(symbol: "doc.richtext", tint: .accent,
                              titleLabel: previewTitleLabel, subtitleLabel: nil)
        previewCard.setBody(previewScroll)
    }

    private func buildRail() {
        rail.translatesAutoresizingMaskIntoConstraints = false
        // The column inside keeps its designed width and is clipped when the
        // rail collapses, rather than being pinned to both of the rail's
        // edges - a trailing tie would make `railCollapse`'s required zero
        // unsatisfiable against the cards' own content.
        rail.wantsLayer = true
        rail.layer?.masksToBounds = true
        for stack in [backlinksStack, inspectorStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = HelmMetrics.s2
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        backlinksCard.translatesAutoresizingMaskIntoConstraints = false
        backlinksCard.setHeader(symbol: "arrow.turn.up.left", tint: .violet,
                                titleLabel: backlinksTitleLabel, subtitleLabel: nil)
        backlinksCard.setBody(backlinksStack, insets: HelmCard.contentInsets)

        inspectorCard.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.setHeader(symbol: "info.circle", tint: .neutral,
                                title: "Page")
        inspectorCard.setBody(inspectorStack, insets: HelmCard.contentInsets)

        let column = NSStackView(views: [backlinksCard, inspectorCard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.railColumnWidth),
            column.topAnchor.constraint(equalTo: rail.topAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: rail.bottomAnchor),
            backlinksCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            inspectorCard.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private let backlinksTitleLabel = NSTextField(labelWithString: "Backlinks")

    // MARK: Modes

    private func applyMode() {
        let showEditor = mode != .preview
        let showPreview = mode != .edit
        editorCard.isHidden = !showEditor
        previewCard.isHidden = !showPreview
        rail.isHidden = !railVisible
        railCollapse.isActive = !railVisible
        // Full review #3's PF1 in miniature: a hidden view still participates
        // fully in Auto Layout, so the *tie* between the two cards has to go
        // with the hidden card, not merely its visibility.
        editorWidthTie.isActive = showEditor && showPreview
        // Exactly one of the two carries the leading edge and one the
        // trailing, whichever are showing.
        hiddenCardCollapse(editorCard, collapsed: !showEditor, stored: &editorCollapse)
        hiddenCardCollapse(previewCard, collapsed: !showPreview, stored: &previewCollapse)
        railButton.state = railVisible ? .on : .off
        view.layoutSubtreeIfNeeded()
    }

    private var editorCollapse: NSLayoutConstraint?
    private var previewCollapse: NSLayoutConstraint?

    /// Collapses a hidden card to zero width rather than leaving it at its
    /// natural one. Required priority is safe here because zero can never be
    /// a floor on the window (gotcha (13) is about *minimums*, and this is a
    /// maximum of nothing).
    private func hiddenCardCollapse(_ card: NSView, collapsed: Bool, stored: inout NSLayoutConstraint?) {
        if collapsed {
            if stored == nil { stored = card.widthAnchor.constraint(equalToConstant: 0) }
            stored?.isActive = true
        } else {
            stored?.isActive = false
        }
    }

    // MARK: Loading

    /// Re-reads the corpus, rebuilds the resolver and the index, and redraws
    /// everything that depends on them.
    private func reload() {
        var overflow = 0
        pages = store.listPages(overflow: &overflow)
        overflowPages = overflow
        resolver = NotebookLinkResolver(pages: pages)
        index = NotebookBacklinkIndex(pages: pages, resolver: resolver)
        hasRestored = true

        rebuildSidebar()
        if let currentID, store.exists(id: currentID) {
            // The open page may have changed under us (a git pull, another
            // machine). The editor's own copy wins while it is being typed
            // into, which is what `currentContent` is.
            refreshRail()
            refreshPreview()
        } else {
            openInitialPage()
        }
        refreshStatusLine()
        onDrillSubtitleChanged?()
    }

    /// The clone can land after this page first mounted, exactly as it can
    /// for Code Preview. Only ever *widens* what is shown - it never replaces
    /// an open page.
    private func retryLoadIfCloneArrivedLate() {
        guard pages.isEmpty, store.gitSync != nil else { return }
        reload()
    }

    private func openInitialPage() {
        // The most recently touched page is what a notebook should open on -
        // it is almost always what the captain was last writing.
        if let latest = pages.max(by: { $0.modifiedAt < $1.modifiedAt }) {
            open(pageID: latest.id)
            return
        }
        currentID = nil
        currentContent = ""
        editorTitleLabel.stringValue = "No page open"
        preview.render("", resolver: resolver, sourcePageID: nil, theme: theme)
        refreshRail()
        showEditorOverlay(symbol: "book.pages",
                          title: "Your notebook is empty",
                          body: "Start with today's note, or add a page. "
                              + "Everything you write here is a markdown file in your config repo.")
    }

    private func open(pageID: String) {
        guard let page = store.page(id: pageID) else {
            // A stale sidebar row (a page deleted on another machine). Redraw
            // rather than opening nothing.
            reload()
            return
        }
        currentID = page.id
        currentContent = page.content
        editorTitleLabel.stringValue = "\(page.slug).md"
        sidebar.select(page.id)
        // Only once the page is live. Before that the bridge answers "the
        // editor is still starting up", which is not an error worth showing
        // in the drill subtitle - and `editorBecameReady` re-opens whatever
        // is current the moment it can. Without this guard the very first
        // load always reported a failure the captain then had to navigate
        // away from to clear.
        if webView.isReady {
            hideEditorOverlay()
            webView.call("openSnippet", payload: [
                "id": page.id,
                "language": "markdown",
                "content": page.content,
            ]) { [weak self] result in
                if case .failure(let error) = result { self?.report(error: error.message) }
            }
        }
        refreshPreview()
        refreshRail()
        refreshStatusLine()
        onDrillSubtitleChanged?()
    }

    // MARK: Editing

    /// The page's debounce fired: write the file, redraw the preview, and -
    /// only when the link graph could actually have changed - rebuild the
    /// index.
    private func pageEdited(id: String, content: String) {
        guard store.exists(id: id) else { return }
        let linksChanged = NotebookLinks.parse(content) != NotebookLinks.parse(currentContent)
        currentContent = content
        store.updatePage(id: id, content: content)

        if let renamed = autoTitleIfUntitled(id: id, content: content) {
            currentID = renamed
            reload()
            sidebar.select(renamed)
            return
        }

        refreshPreview()
        refreshInspector()
        if linksChanged {
            // Cheap because the corpus is already in memory apart from this
            // one page - and necessary, because a link the captain just typed
            // has to resolve without a page switch.
            for i in pages.indices where pages[i].id == id { pages[i].content = content }
            resolver = NotebookLinkResolver(pages: pages)
            index = NotebookBacklinkIndex(pages: pages, resolver: resolver)
            refreshRail()
            refreshPreview()
        }
    }

    /// A page created as `untitled` takes the name of its own first heading,
    /// the moment it has one.
    ///
    /// `CodePreviewAutoTitle`'s idea applied to a notebook, and for the same
    /// stated reason: the slug lands in a **filename in a git repo**, so
    /// "forgot to rename it" is permanent and visible to everyone who clones.
    /// Only a placeholder is eligible - a name the captain chose is never
    /// overwritten.
    private func autoTitleIfUntitled(id: String, content: String) -> String? {
        guard let page = store.page(id: id), Self.isPlaceholderSlug(page.slug) else { return nil }
        let heading = NotebookStore.titleFromContent(content, fallback: "")
        guard !heading.isEmpty else { return nil }
        let slug = NotebookStore.slugify(heading)
        guard slug != page.slug, !Self.isPlaceholderSlug(slug) else { return nil }
        let target = NotebookStore.join(folder: page.folder, slug: slug)
        guard let landed = store.renamePage(id: id, to: target), landed != id else { return nil }
        retargetLinks(from: page.slug, to: heading, skipping: landed)
        return landed
    }

    /// Anything already pointing at the old placeholder name follows the
    /// rename. A page that was never linked to costs one `parse` and no
    /// write.
    private func retargetLinks(from oldTarget: String, to newTarget: String, skipping: String) {
        for page in pages where page.id != skipping {
            let rewritten = NotebookLinks.retarget(page.content, from: oldTarget, to: newTarget)
            guard rewritten != page.content else { continue }
            store.updatePage(id: page.id, content: rewritten)
        }
    }

    static func isPlaceholderSlug(_ slug: String) -> Bool {
        guard slug.hasPrefix("untitled") else { return false }
        let rest = slug.dropFirst("untitled".count)
        if rest.isEmpty { return true }
        guard rest.hasPrefix("-") else { return false }
        let digits = rest.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    // MARK: Rendering the three panels

    private func rebuildSidebar() {
        var sections: [HelmPageSidebar.Section] = []
        let topLevel = pages.filter { $0.folder.isEmpty }
        if !topLevel.isEmpty {
            sections.append(.init(header: "Pages", rows: topLevel.map(Self.row(for:))))
        }
        let daily = pages.filter(\.isDailyNote).sorted { $0.id > $1.id }
        if !daily.isEmpty {
            // Newest first, and capped: a notebook kept for a year has 365 of
            // these, and a nav column is not an archive (GL-35). The count in
            // the header is the honest total.
            let shown = Array(daily.prefix(Self.dailyRowsShown))
            sections.append(.init(header: "Daily notes (\(daily.count))", rows: shown.map(Self.row(for:))))
        }
        for folder in store.folders(in: pages) where folder != NotebookStore.dailyFolder {
            let inFolder = pages.filter { $0.folder == folder }
            guard !inFolder.isEmpty else { continue }
            sections.append(.init(header: NotebookStore.humanise(lastComponentOf: folder),
                                  rows: inFolder.map(Self.row(for:))))
        }
        sidebar.setSections(sections)
        if let currentID { sidebar.select(currentID) }
    }

    /// How many dated pages the sidebar lists. Thirty-one is one month, which
    /// is the window a daily note is actually reached backwards through.
    static let dailyRowsShown = 31

    private static func row(for page: NotebookPage) -> HelmPageSidebar.Row {
        .init(id: page.id,
              indicator: .symbol(page.isDailyNote ? "sun.max" : "doc.text"),
              title: page.title,
              showsCount: false)
    }

    private func refreshPreview() {
        preview.render(currentContent, resolver: resolver, sourcePageID: currentID, theme: theme)
        previewTitleLabel.stringValue = "Preview"
    }

    private func refreshRail() {
        refreshBacklinks()
        refreshInspector()
    }

    private func refreshBacklinks() {
        backlinksStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        backlinkSleeves.removeAll()
        let links = currentID.map { index.backlinks(to: $0) } ?? []
        backlinksTitleLabel.stringValue = links.isEmpty ? "Backlinks" : "Backlinks \u{00B7} \(links.count)"
        guard !links.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString:
                "Nothing links here yet. Write [[\(currentTitle)]] on another page.")
            empty.font = HelmType.caption()
            empty.textColor = HelmTheme.mutedInk(theme)
            empty.translatesAutoresizingMaskIntoConstraints = false
            backlinksStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: backlinksStack.widthAnchor).isActive = true
            return
        }
        for link in links.prefix(Self.backlinkRowsShown) {
            let row = backlinkRow(link)
            backlinksStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: backlinksStack.widthAnchor).isActive = true
        }
        if links.count > Self.backlinkRowsShown {
            // GL-35's cap with GL-14's honesty: never a silent truncation.
            let more = NSTextField(labelWithString: "\(links.count - Self.backlinkRowsShown) more\u{2026}")
            more.font = HelmType.caption()
            more.textColor = HelmTheme.mutedInk(theme)
            more.translatesAutoresizingMaskIntoConstraints = false
            backlinksStack.addArrangedSubview(more)
        }
    }

    static let backlinkRowsShown = 8

    private var currentTitle: String {
        guard let currentID, let page = pages.first(where: { $0.id == currentID }) else { return "this page" }
        return page.title
    }

    private func backlinkRow(_ link: NotebookBacklink) -> NSView {
        let title = NSTextField(labelWithString: link.sourceTitle)
        title.font = HelmType.rowTitle()
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let context = NSTextField(wrappingLabelWithString: "\u{201C}\(link.context)\u{201D}")
        context.font = HelmType.caption()
        context.maximumNumberOfLines = 2
        context.lineBreakMode = .byTruncatingTail
        context.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [title, context])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false

        // GL-16: a clickable row is a `HoverHighlightView`, which supplies the
        // role, the label, the focus ring and the keyboard press. Never a
        // hand-rolled click target.
        let row = HoverHighlightView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: HelmMetrics.s2),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -HelmMetrics.s2),
            column.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
        ])
        // The click and the accessibility press are attached exactly the way
        // `HelmPageSidebar` attaches its own rows' - a gesture recogniser plus
        // the two overrides - so this row announces and behaves like every
        // other clickable row in the app.
        let sleeve = ClosureSleeve { [weak self] in self?.open(pageID: link.sourceID) }
        backlinkSleeves.append(sleeve)
        row.addGestureRecognizer(NSClickGestureRecognizer(target: sleeve, action: #selector(ClosureSleeve.invoke)))
        row.accessibilityRoleOverride = .button
        row.accessibilityLabelOverride = "\(link.sourceTitle): \(link.context)"
        row.wantsLayer = true
        row.cornerRadius = HelmMetrics.rControl
        row.normalColor = .clear
        row.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        context.textColor = HelmTheme.mutedInk(theme)
        return row
    }

    private func refreshInspector() {
        inspectorStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard currentID != nil else { return }
        let words = currentContent.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        var rows: [(String, String, NSColor)] = [
            ("Words", "\(words)", HelmTheme.nsColor(theme.chromeInkHex)),
        ]
        let progress = NotebookMarkdown.taskProgress(in: currentContent)
        // GL-14 again: a page with no checklist shows no checklist row, not
        // "0 of 0".
        if progress.total > 0 {
            rows.append(("Tasks", "\(progress.done)/\(progress.total)", HelmTheme.nsColor(theme.chromeInkHex)))
        }
        if let page = pages.first(where: { $0.id == currentID }) {
            rows.append(("Updated", Self.relative(page.modifiedAt), HelmTheme.nsColor(theme.chromeInkHex)))
        }
        rows.append(("Sync", syncWord, syncColor))

        for (label, value, color) in rows {
            inspectorStack.addArrangedSubview(inspectorRow(label: label, value: value, color: color))
            inspectorStack.arrangedSubviews.last?.widthAnchor
                .constraint(equalTo: inspectorStack.widthAnchor).isActive = true
        }

        let tags = NotebookMarkdown.tags(in: currentContent)
        guard !tags.isEmpty else { return }
        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = HelmMetrics.s1
        chips.alignment = .centerY
        chips.translatesAutoresizingMaskIntoConstraints = false
        for tag in tags.prefix(Self.tagChipsShown) {
            chips.addArrangedSubview(tagChip("#\(tag)"))
        }
        inspectorStack.addArrangedSubview(chips)
    }

    static let tagChipsShown = 6

    private var syncWord: String {
        switch syncStatus {
        case .synced: return store.gitSync == nil ? "local" : "clean"
        case .localChanges: return "saving"
        case .syncing: return "syncing"
        case .failed: return "failed"
        }
    }

    private var syncColor: NSColor {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        switch syncStatus {
        case .failed:
            return HelmContrast.legibleOn(fill: surface, preferring: HelmTheme.nsColor(theme.ansiHex[1]))
        case .synced:
            return HelmContrast.legibleOn(fill: surface, preferring: HelmTheme.nsColor(theme.ansiHex[2]))
        case .localChanges, .syncing:
            return HelmTheme.mutedInk(theme)
        }
    }

    private func inspectorRow(label: String, value: String, color: NSColor) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = HelmType.caption()
        name.textColor = HelmTheme.mutedInk(theme)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.required, for: .horizontal)

        let reading = NSTextField(labelWithString: value)
        reading.font = HelmType.metric(11.5)
        reading.textColor = color
        reading.alignment = .right
        reading.lineBreakMode = .byTruncatingTail
        reading.translatesAutoresizingMaskIntoConstraints = false
        reading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): a bare `NSView()` has no intrinsic size, so a hugging
        // priority on it is a no-op - a spacer that must stay collapsed needs
        // a real low-priority `width == 0`.
        let collapse = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        collapse.isActive = true

        let row = NSStackView(views: [name, spacer, reading])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = HelmMetrics.s2
        // Gotcha (10): `.gravityAreas` honours no priority at all.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func tagChip(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.caption()
        label.translatesAutoresizingMaskIntoConstraints = false
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = HelmMetrics.rChip
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
        ])
        // A tinted fill is safe; the *text* on it is not automatically, so it
        // goes through `HelmContrast` like every other tinted label here.
        let fill = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.14)
        chip.layer?.backgroundColor = fill.cgColor
        label.textColor = HelmContrast.legibleTintedText(
            tintHex: theme.accentHex,
            over: HelmTheme.nsColor(theme.chromeBackgroundHex),
            theme: theme)
        return chip
    }

    private func refreshStatusLine() {
        statusLabel.stringValue = syncSummary
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        refreshInspector()
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    // MARK: Actions

    /// UX4's contextual ⌘N on this page.
    func newPageFromMenu() { newPageTapped() }

    /// ⌘K's deep link, and the shell's own entry point. Re-reads the corpus
    /// first so a page created since the last visit is genuinely there.
    func openPage(id: String) {
        if !pages.contains(where: { $0.id == id }) { reload() }
        open(pageID: id)
    }

    @objc private func newPageTapped() {
        // Created in the folder the open page lives in, which is what "add a
        // page here" means when a tree is on screen. No modal: the page is
        // named by its own first heading the moment it has one (see
        // `autoTitleIfUntitled`), exactly as Code Preview names a snippet.
        let folder = pages.first(where: { $0.id == currentID })?.folder ?? ""
        let created = store.createPage(title: "Untitled", folder: folder, content: "# ")
        reload()
        open(pageID: created.id)
        webView.call("focusEditor")
    }

    @objc private func todayTapped() {
        let note = store.openDailyNote()
        reload()
        open(pageID: note.id)
        webView.call("focusEditor")
    }

    private func createMissingPage(named target: String) {
        // Created at the top level rather than beside the linking page: a
        // forward link most often names something general, and a page in the
        // wrong folder is harder to notice than one in none.
        let created = store.createPage(title: target, content: "# \(target)\n\n")
        reload()
        open(pageID: created.id)
        Feedback.report("Created \(created.title)", kind: .done, persistence: .transient, in: view)
    }

    @objc private func deleteTapped() {
        guard let currentID, let page = pages.first(where: { $0.id == currentID }) else { return }
        let incoming = index.count(to: currentID)
        // GL-06: one confirmation for an irreversible delete, and it names
        // what will break - a page three others link to is not the same
        // decision as an orphan.
        let detail = incoming == 0
            ? "This deletes \(page.slug).md from your config repo. The git history keeps it."
            : "\(incoming) other page\(incoming == 1 ? "" : "s") link\(incoming == 1 ? "s" : "") here, and "
                + "those links will stop resolving. The git history keeps the file."
        guard DestructiveConfirm.confirm(message: "Delete \u{201C}\(page.title)\u{201D}?",
                                         detail: detail,
                                         confirmTitle: "Delete page") else { return }
        webView.call("closeSnippet", payload: ["id": currentID])
        store.deletePage(id: currentID)
        self.currentID = nil
        currentContent = ""
        reload()
    }

    @objc private func toggleRail() {
        railVisible.toggle()
        applyMode()
    }

    /// The Edit menu's ⌘F while this destination is showing - Monaco's own
    /// find widget, exactly as Code Preview routes it.
    @objc func showFind() { webView.call("find") }

    // MARK: Editor plumbing

    private func editorBecameReady() {
        hideEditorOverlay()
        pushTheme()
        webView.call("setFontSize", payload: ["size": FontSizeManager.shared.size])
        // Soft wrap is right for prose and wrong for code, and this editor is
        // only ever holding prose.
        webView.call("setWordWrap", payload: ["on": true])
        if let currentID, let page = store.page(id: currentID) {
            webView.call("openSnippet", payload: [
                "id": page.id, "language": "markdown", "content": page.content,
            ])
        } else {
            openInitialPage()
        }
        onDrillSubtitleChanged?()
    }

    private func pushTheme() {
        guard webView.isReady else { return }
        // A completion handler, never fire-and-forget:
        // `CodePreviewTheme.Key.operatorToken`'s own history is a theme push
        // that threw page-side and was silently dropped on every theme change
        // for the life of that feature.
        webView.call("setTheme", payload: ["theme": NotebookEditorTheme.palette(for: theme)]) { result in
            if case .failure(let error) = result {
                AppLog.lifecycle.error("notebook: theme push failed - \(error.message, privacy: .public)")
            }
        }
    }

    private func report(error: String) {
        lastError = error
        onDrillSubtitleChanged?()
        AppLog.lifecycle.error("notebook: \(error, privacy: .public)")
    }

    private func showEditorOverlay(symbol: String, title: String, body: String) {
        editorOverlayState?.removeFromSuperview()
        let state = HelmEmptyState(symbol: symbol, title: title, body: body,
                                   size: .standard, hue: RailDestination.notebook.domainHue)
        state.translatesAutoresizingMaskIntoConstraints = false
        editorOverlay.addSubview(state)
        NSLayoutConstraint.activate([
            state.centerXAnchor.constraint(equalTo: editorOverlay.centerXAnchor),
            state.centerYAnchor.constraint(equalTo: editorOverlay.centerYAnchor),
            state.leadingAnchor.constraint(greaterThanOrEqualTo: editorOverlay.leadingAnchor, constant: HelmMetrics.s4),
            state.trailingAnchor.constraint(lessThanOrEqualTo: editorOverlay.trailingAnchor, constant: -HelmMetrics.s4),
        ])
        state.applyTheme(theme)
        editorOverlayState = state
        editorOverlay.isHidden = false
    }

    private func hideEditorOverlay() {
        editorOverlay.isHidden = true
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        toolbar.applyTheme(theme)
        modeTabs.applyTheme(theme)
        sidebar.applyTheme(theme)
        editorCard.applyTheme(theme)
        previewCard.applyTheme(theme)
        backlinksCard.applyTheme(theme)
        inspectorCard.applyTheme(theme)
        editorOverlayState?.applyTheme(theme)
        editorTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        previewTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        backlinksTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        preview.applyTheme(theme)
        refreshStatusLine()
        // The rail's rows carry theme-derived ink of their own and are rebuilt
        // rather than re-tinted - they are a handful of labels, and rebuilding
        // is what keeps one paint path instead of two.
        refreshRail()
        pushTheme()
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugPages: [NotebookPage] { pages }
    var debugCurrentPageID: String? { currentID }
    var debugPreview: NotebookPreviewView { preview }
    var debugSidebar: HelmPageSidebar { sidebar }
    var debugBacklinkRowCount: Int { backlinksStack.arrangedSubviews.count }
    var debugBacklinksTitle: String { backlinksTitleLabel.stringValue }
    var debugInspectorRowCount: Int { inspectorStack.arrangedSubviews.count }
    var debugEditorCardHidden: Bool { editorCard.isHidden }
    var debugPreviewCardHidden: Bool { previewCard.isHidden }
    var debugRailHidden: Bool { rail.isHidden }
    var debugEditorCard: NSView { editorCard }
    var debugPreviewCard: NSView { previewCard }
    var debugRail: NSView { rail }
    func debugSetMode(_ mode: ViewMode) {
        self.mode = mode
        modeTabs.select(mode.rawValue)
        applyMode()
    }
    func debugToggleRail() { toggleRail() }
    func debugOpen(pageID: String) { open(pageID: pageID) }
    func debugReload() { reload() }
    func debugNewPage() { newPageTapped() }
    func debugToday() { todayTapped() }
    /// Drives the same path the editor's own debounce does, so a suite can
    /// assert the write/rename/index behaviour without a live web page.
    func debugEdit(id: String, content: String) { pageEdited(id: id, content: content) }
    func debugCreateMissingPage(named target: String) { createMissingPage(named: target) }
    /// The editor's own readiness and bridge, so the window-backed suite can
    /// read Monaco's tokenizer output back rather than asserting that a
    /// palette was sent.
    var debugEditorIsReady: Bool { webView.isReady }
    func debugEditorCall(_ name: String, payload: [String: Any],
                         completion: @escaping (Result<[String: Any], CodePreviewBridgeError>) -> Void) {
        webView.call(name, payload: payload, completion: completion)
    }
    #endif
}
