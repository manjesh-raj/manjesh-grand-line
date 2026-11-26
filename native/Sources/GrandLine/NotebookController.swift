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

final class NotebookController: NSViewController, DaylightDrillActions, HelmSplitPageHosting {

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

    /// UX-12: Write is one pane that shows the page formatted as it is
    /// typed (`NotebookWriteView`). Split and Source keep the Monaco editor.
    /// Preview went: Write already shows the formatted page.
    enum ViewMode: String, CaseIterable {
        case write, split, edit

        var title: String {
            switch self {
            case .write: return "Write"
            case .edit: return "Source"
            case .split: return "Split"
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
    var mode: ViewMode = .write

    // MARK: Views

    /// UI-45: one sidebar shape across the app - `HelmPageSidebar` on the
    /// plain surface with muted counts, the Tasks sidebar the revamp kept.
    /// A boxed panel around the nav was a second bordered surface beside the
    /// page's own cards (Rule 1).
    private let sidebar = HelmPageSidebar()
    /// P9: the page's split view, which holds `sidebar` as a real sidebar.
    private(set) var splitPage: HelmSplitPage?
    /// Whether Delete Page is offered: false once the editor bundle is
    /// missing, since there is no page on screen to delete.
    private var canDeletePage = true

    /// The drill header's own cluster (Daylight §6.4) - the mockup's two top
    /// bar buttons, hoisted to where every other destination's page-level
    /// actions live.
    /// S12: the daily-note glyph from `HelmSymbol.Role`, never the light
    /// theme's sun, and a short label even where the toolbar is compact.
    private let todayButton = HelmButton(title: "Today's note", variant: .secondary,
                                         symbol: HelmSymbol.Role.dailyNote.name)
    private let newPageButton = HelmButton(title: "New page", variant: .primary, symbol: "plus")

    private let editorCard = HelmCard()
    /// PERF-01: `lazy`, so the web view - its configuration, its content
    /// controller and its non-persistent data store - is allocated by
    /// `loadView`, its first real use, rather than when this controller is
    /// constructed. `activate()` already deferred loading content; this
    /// defers the object as well.
    private lazy var webView = CodePreviewWebView()
    private let editorOverlay = NSView()
    private var editorOverlayState: HelmEmptyState?

    private let previewCard = HelmCard()
    private let previewScroll = NSScrollView()
    private let previewDocument = FlippedView()
    private let preview = NotebookPreviewView()

    /// UX-12: the Write pane, in a card of its own.
    private let writeCard = HelmCard()
    let writeView = NotebookWriteView()
    private let writeTitleLabel = NSTextField(labelWithString: "")
    /// F-05: a memo page's player and transcript actions, above the text.
    let memoStrip = VoiceMemoStrip()
    /// UX-12: the page's outline, first in the inspector.
    private let outlineCard = HelmCard()
    private let outlineStack = NSStackView()
    private var outlineSleeves: [ClosureSleeve] = []
    var onInspectorContentChanged: (() -> Void)?
    var onShowInspector: (() -> Void)?

    /// The page's details - its outline, the pages that link to it and its
    /// facts - shown in the shell's inspector (UX-12) rather than in a column
    /// of the page.
    private let rail = FlippedView()
    private let backlinksCard = HelmCard()
    private let backlinksStack = NSStackView()
    private let inspectorCard = HelmCard()
    private let inspectorStack = NSStackView()
    /// UI-54: Split means two panes. The page's details are an inspector the
    /// toolbar's `sidebar.right` button shows, hidden until the captain asks
    /// for it, and the choice is remembered. Since UX-12 that inspector is the
    /// shell's own (`WorkspaceInspectorSource`), not a column of the page.
    private var railVisible = AppDefaults.store.bool(forKey: NotebookController.inspectorDefaultsKey) {
        didSet { AppDefaults.store.set(railVisible, forKey: Self.inspectorDefaultsKey) }
    }
    static let inspectorDefaultsKey = "fm.notebook.inspectorVisible"
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

    /// R2-UX-06: the page has no toolbar row of its own. Its controls are
    /// the window toolbar's - the mode switch, Today's note, find, the details
    /// column and delete - so two toolbars no longer stack. New page is the
    /// far-right primary (R2-UX-04).
    ///
    /// Measured at 1512 with the sidebar showing: Knowledge's five tabs take
    /// 422pt, and the row's six controls beside them (342pt) pushed the
    /// crumb, Recents, Quick Connect and the inspector button out. So the
    /// three page utilities - find, the details column and delete - are one
    /// "More" menu here (`HelmOverflowMenu`, UI-47's rule), and the mode
    /// switch and Today's note stay on the toolbar.
    ///
    /// The labelled three-way switch does not fit either: at 1512 beside the
    /// five tabs about 50pt are left for it. So in the window toolbar the
    /// mode is one pop-up showing the mode it is in, with the same three
    /// choices (`toolbarModePopUp`).
    var drillHeaderActions: [NSView] {
        [toolbarModePopUp, todayButton, toolbarMoreMenu.button, newPageButton]
    }
    /// R2-UX-06: Source, Split or Preview, in the sidebar layout's toolbar.
    private lazy var toolbarModePopUp: HelmPopUpButton = {
        let popUp = HelmPopUpButton()
        popUp.addItems(withTitles: ViewMode.allCases.map(\.title))
        popUp.target = self
        popUp.action = #selector(toolbarModePicked(_:))
        popUp.toolTip = "Show the source, the preview, or both"
        popUp.setAccessibilityLabel("View")
        return popUp
    }()

    @objc private func toolbarModePicked(_ sender: NSPopUpButton) {
        guard ViewMode.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        mode = ViewMode.allCases[sender.indexOfSelectedItem]
        applyMode()
    }
    /// R2-UX-06: find, the details column and delete, in the sidebar
    /// layout's window toolbar - the same handlers the row's three buttons run.
    private lazy var toolbarMoreMenu = HelmOverflowMenu(items: [
        .init("Find in Page", symbol: "magnifyingglass") { [weak self] in self?.showFind() },
        .init("Show or Hide Page Details", symbol: "sidebar.right") { [weak self] in self?.toggleRail() },
        .init("Delete Page\u{2026}", symbol: "trash",
              isEnabled: { [weak self] in self?.canDeletePage ?? false }) { [weak self] in self?.deleteTapped() },
    ], tooltip: "More - find, page details or delete this page")
    /// The editor at the top of the page: its controls are the window
    /// toolbar's (R2-UX-06), so no row sits above it.
    private var splitAtTop: NSLayoutConstraint!
    /// F-05: the write view under the memo strip, or at the card's top.
    private var memoStripTies: (underStrip: NSLayoutConstraint, atTop: NSLayoutConstraint)?

    /// F-05: shows the memo strip for a memo page, and moves the text below
    /// it. Collapsing by swapping the text's top, never by a zero height on
    /// a view with real content (gotcha (17)'s footnote).
    func refreshMemoStrip(content: String) {
        memoStrip.show(content: content)
        guard let ties = memoStripTies else { return }
        ties.underStrip.isActive = !memoStrip.isHidden
        ties.atTop.isActive = memoStrip.isHidden
    }

    /// F-05: "Make a task from a line" on a memo page.
    private func makeTask(fromMemoLine line: String) {
        guard let store = GrandLineServices.shared.shiftStore else { return }
        var task = ShiftTask.fresh()
        task.title = line.count > 120 ? String(line.prefix(119)) + "\u{2026}" : line
        task.description = "From the voice memo \u{201C}\(currentTitle)\u{201D}."
        store.addTask(task)
        Toast.show(in: view, message: "Task added: \(task.title)")
    }

    /// F-05: an audio file dropped on the page becomes a memo page.
    func importDroppedAudio(_ urls: [URL]) -> Bool {
        guard let memos = GrandLineServices.shared.voiceMemos else { return false }
        var opened = false
        for url in urls where VoiceMemoFiles.audioExtensions.contains(url.pathExtension.lowercased()) {
            guard let id = memos.importAudio(url, progress: { [weak self] value in
                guard let self, value >= 1 else { return }
                self.reload()
                if let current = self.currentID, let page = self.store.page(id: current) {
                    self.open(pageID: page.id)
                }
            }) else { continue }
            reload()
            open(pageID: id)
            opened = true
        }
        if opened { Toast.show(in: view, message: "Transcribing on this Mac. The page fills in when it is done.") }
        return opened
    }

    // MARK: R2-BUG-07 - the toolbar's room at narrow widths

    /// Below this window width, the two actions the sidebar layout's toolbar
    /// carries for this page draw as their icons alone.
    ///
    /// At 1100 the toolbar needed about 147pt more than it had (the crumb,
    /// Recents and the inspector button all fell into the overflow menu),
    /// and these two labelled buttons were 222pt of it. As the sun and the
    /// plus they free about 140pt, which keeps those three on the toolbar.
    /// The label stays as each button's tooltip and accessibility label.
    ///
    /// 1600 since U-02 put Quick Connect's two icons on every module and U-03
    /// widened the sidebar by 28pt: measured at 1512, the labelled pair then
    /// pushed Recents and the inspector button into the overflow menu again.
    static let compactToolbarActionsBelow: CGFloat = 1600

    /// The two actions' titles for the window's current width.
    func applyToolbarActionWidth() {
        guard let window = view.window else { return }
        // In the window toolbar the buttons sit outside the window's content
        // view; a page mounted on its own (a suite, a probe) has them inside
        // it, with no toolbar to fit. Not `todayButton.window`, which a toolbar item's
        // view loses while the toolbar is re-fitting itself to a new width.
        let inToolbar = todayButton.superview != nil
            && !(window.contentView.map { todayButton.isDescendant(of: $0) } ?? true)
        let compact = inToolbar && window.frame.width < Self.compactToolbarActionsBelow
        // S12: Today's note keeps a short word when compact, so its glyph is
        // never the only thing saying what it does (the "Customize" shape on
        // Home). "New page" keeps its plus alone, which means one thing.
        for (button, label, short) in [(todayButton, "Today's note", "Today"), (newPageButton, "New page", "")] {
            let title = compact ? short : label
            if button.title != title { button.title = title }
            button.setAccessibilityLabel(label)
            button.menuFormTitle = label
        }
    }

    #if FM_SELFTESTS
    var debugToolbarActionTitles: [String] { [todayButton.title, newPageButton.title] }
    #endif

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        if !CodePreviewAssets.isAvailable { return "The Monaco bundle is missing" }
        let count = pages.count
        // GL-14: an empty notebook and a notebook that has not loaded yet are
        // different states, and neither is "0 pages".
        guard hasRestored else { return "Opening the notebook\u{2026}" }
        let noun = count == 1 ? "1 page" : "\(count) pages"
        let more = overflowPages > 0 ? " (+\(overflowPages) not shown)" : ""
        // R5-UX-10: one hint for the first few pages - how pages link up.
        return QuietHint.line("\(noun)\(more) \u{00B7} \(syncSummary)", count: count,
                              hint: "type [[ to link another page")
    }

    /// One wording for the sync state, read by both the drill subtitle and
    /// the page's own status line - so the two can never disagree about
    /// whether the captain's writing has reached GitHub.
    /// Where a page's markdown actually ends up, in words.
    ///
    /// **Review defect U9's second half.** The empty state said "a markdown
    /// file in your config repo" while the drill subtitle two lines above
    /// said "saved on this machine" - and on a Mac with no config repo the
    /// subtitle was the true one. Both sentences are built from this now, so
    /// they state one fact; `syncSummary` adds the *status* on top of it
    /// ("synced to", "saving..."), which is a different thing from the
    /// location and may legitimately read differently.
    ///
    /// Pure and static, so a test can assert both branches without a store.
    static func storageWording(isGitSynced: Bool) -> String {
        isGitSynced ? "in your manjesh-config repo" : "saved on this machine"
    }

    private var whereItGoes: String { Self.storageWording(isGitSynced: store.gitSync != nil) }

    private var syncSummary: String {
        switch syncStatus {
        case .synced: return store.gitSync == nil ? whereItGoes : "synced to manjesh-config"
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
        let root = NotebookRootView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.wantsLayer = true
        // F-05: drop an audio file on the Notebook to transcribe it.
        root.onDropAudio = { [weak self] urls in self?.importDroppedAudio(urls) ?? false }
        view = root

        buildBody(in: root)
        buildActions()

        webView.onReady = { [weak self] in self?.editorBecameReady() }
        webView.onPageError = { [weak self] message in self?.report(error: message) }
        webView.onSnippetChanged = { [weak self] id, content in self?.pageEdited(id: id, content: content) }
        writeView.onEdit = { [weak self] id, content in self?.pageEdited(id: id, content: content) }
        writeView.onOpenLink = { [weak self] target in self?.openLinkTarget(target) }

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
            canDeletePage = false
        }

        reload()
        applyTheme()
        applyMode()

        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the page builds its sidebar presentation as part of loading.
        buildSidebarPresentation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // P11: a revisit reads the folder off the main thread and keeps the
        // page as it was until the read lands. The first read is still the
        // synchronous one in `loadView`, which has nothing to show without it.
        reloadInBackground()
    }

    /// See `HelmBackgroundReload`. Every other caller of `reload()` is a
    /// write that needs its result at once, and runs it synchronously.
    private let backgroundReload = HelmBackgroundReload<NotebookFolderRead>(label: "notebook")

    private func reloadInBackground() {
        let store = self.store
        backgroundReload.run(read: { NotebookFolderRead(store: store) }) { [weak self] read in
            self?.apply(read)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A window resize lays the showing page out again, so the toolbar
        // actions follow the width without an observer of their own.
        applyToolbarActionWidth()
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
    func shutdown(deadline: DispatchTime) {
        flushPendingEdits(waitingUpTo: CodePreviewController.terminateEditFlushBudget)
        store.gitSync?.flushForTerminationNow(deadline: deadline)
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
        // **Review defect U9.** With no pages the column rendered as a blank
        // 275pt card - no heading, no sentence, no affordance. It says what
        // it is for and offers the one action that fills it.
        //
        // UXP-11: the column keeps its heading and a word, and the one empty
        // state - with both of its actions - is the editor's. The column used
        // to carry a second "No pages yet" with its own New page, beside the
        // editor's and a third in the preview.
        sidebar.setEmptyState(.init(header: "Pages", body: "None yet."))

        buildEditorCard()
        buildPreviewCard()
        buildWriteCard()
        buildRail()

        // P9: the page tree is a real split-view sidebar - draggable,
        // collapsible and answering Toggle Sidebar - where it was pinned
        // before. The cards and the rail are the content pane.
        // S04: Settings' band - the column's region in the side-panel fill,
        // edged by the divider, with Settings' padding.
        let split = HelmSplitPage(sidebarWidth: HelmPageSidebar.bandPaneWidth,
                                  minimum: HelmPageSidebar.bandPaneWidth - HelmPageSidebar.width * 0.2,
                                  maximum: HelmPageSidebar.bandPaneWidth + HelmPageSidebar.width * 0.6,
                                  surface: .sidePanel)
        addChild(split)
        root.addSubview(split.view)
        // Gotcha (16): the column's height is still tied to the page, through
        // the pane's top and bottom insets.
        HelmSplitPage.pin(sidebar, in: split.sidebarPane, insets: HelmPageSidebar.bandInsets)
        let pane = split.contentPane
        pane.addSubview(editorCard)
        pane.addSubview(previewCard)
        pane.addSubview(writeCard)
        splitPage = split

        // The two cards share the remaining width evenly in `.split`. The tie
        // is the one constraint `applyMode` swaps, so the three modes are one
        // activation each rather than three layouts.
        splitAtTop = split.view.topAnchor.constraint(equalTo: root.topAnchor)
        editorWidthTie = editorCard.widthAnchor.constraint(equalTo: previewCard.widthAnchor)
        editorWidthTie.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitAtTop,
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            editorCard.leadingAnchor.constraint(equalTo: pane.leadingAnchor,
                                                constant: Self.gutter - HelmSplitPage.dividerThickness),
            // S03: the page frame's first-content line.
            HelmPageScaffold.pinFirstContent(editorCard, in: pane),
            editorCard.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -Self.gutter),

            previewCard.leadingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: Self.gutter),
            previewCard.topAnchor.constraint(equalTo: editorCard.topAnchor),
            previewCard.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor),

            previewCard.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Self.gutter),

            // UX-12: Write spans the two cards' room. In Write the editor
            // collapses and the preview stands hidden behind it.
            writeCard.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor),
            writeCard.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            writeCard.topAnchor.constraint(equalTo: editorCard.topAnchor),
            writeCard.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor),
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
        // Opaque, in the card's own surface: transparent, it let Monaco's
        // editor background show through under the empty state, which on Dusk
        // put a page-ground body under a card-coloured header.
        editorOverlay.wantsLayer = true
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

    private func buildWriteCard() {
        writeCard.translatesAutoresizingMaskIntoConstraints = false
        writeCard.setHeader(symbol: "doc.text", tint: .info, titleLabel: writeTitleLabel, subtitleLabel: nil)
        // F-05: the memo strip sits above the text, hidden on an ordinary
        // page, so the write view keeps the rest of the card.
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        writeView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(memoStrip)
        body.addSubview(writeView)
        memoStrip.isHidden = true
        let textUnderStrip = writeView.topAnchor.constraint(equalTo: memoStrip.bottomAnchor, constant: HelmMetrics.s2)
        let textAtTop = writeView.topAnchor.constraint(equalTo: body.topAnchor)
        memoStripTies = (textUnderStrip, textAtTop)
        NSLayoutConstraint.activate([
            memoStrip.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: HelmMetrics.s4),
            memoStrip.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -HelmMetrics.s4),
            memoStrip.topAnchor.constraint(equalTo: body.topAnchor, constant: HelmMetrics.s3),
            writeView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            writeView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            writeView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            textAtTop,
        ])
        memoStrip.onCopyText = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.memoStrip.transcriptText, forType: .string)
            Toast.show(in: self.view, message: "Transcript copied")
        }
        memoStrip.onMakeTask = { [weak self] line in self?.makeTask(fromMemoLine: line) }
        writeCard.setBody(body)
        writeCard.isHidden = true
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
        for stack in [backlinksStack, inspectorStack, outlineStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = HelmMetrics.s2
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        outlineStack.spacing = HelmMetrics.s0
        outlineCard.translatesAutoresizingMaskIntoConstraints = false
        outlineCard.setHeader(symbol: "list.bullet.indent", tint: .info, title: "Outline")
        outlineCard.setBody(outlineStack, insets: HelmCard.contentInsets)

        backlinksCard.translatesAutoresizingMaskIntoConstraints = false
        backlinksCard.setHeader(symbol: "arrow.turn.up.left", tint: .violet,
                                titleLabel: backlinksTitleLabel, subtitleLabel: nil)
        backlinksCard.setBody(backlinksStack, insets: HelmCard.contentInsets)

        inspectorCard.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.setHeader(symbol: "info.circle", tint: .neutral,
                                title: "Page")
        inspectorCard.setBody(inspectorStack, insets: HelmCard.contentInsets)

        // UX-12: the shell's inspector hosts this column, at its width.
        let column = NSStackView(views: [outlineCard, backlinksCard, inspectorCard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: HelmMetrics.s3),
            column.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -HelmMetrics.s3),
            column.topAnchor.constraint(equalTo: rail.topAnchor, constant: HelmMetrics.s3),
            column.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -HelmMetrics.s3),
            outlineCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            backlinksCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            inspectorCard.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private let backlinksTitleLabel = NSTextField(labelWithString: "Linked from")

    // MARK: Modes

    func applyMode() {
        // The toolbar's pop-up says the mode however it was chosen.
        if let index = ViewMode.allCases.firstIndex(of: mode),
           toolbarModePopUp.indexOfSelectedItem != index {
            toolbarModePopUp.selectItem(at: index)
        }
        // UXP-11: a notebook with no page open has nothing to preview, so the
        // preview card stands down and the editor's empty state is the one
        // thing on the page.
        let hasPage = currentID != nil
        let showWrite = mode == .write && hasPage
        let showEditor = !showWrite
        let showPreview = mode == .split && hasPage
        // Leaving Write hands its words to Monaco, and entering it takes
        // Monaco's: each editor is ahead of the other by at most a debounce.
        if showWrite != !writeCard.isHidden {
            if showWrite {
                flushPendingEdits()
                if let currentID { writeView.show(id: currentID, content: currentContent) }
            } else {
                writeView.flush()
                if webView.isReady, let currentID {
                    webView.call("openSnippet", payload: ["id": currentID, "language": "markdown", "content": currentContent])
                }
                refreshPreview()
            }
        }
        writeCard.isHidden = !showWrite
        editorCard.isHidden = !showEditor
        // In Write the preview stands behind the Write card, sized but
        // hidden, so the card has the two cards' room to span.
        previewCard.isHidden = !showPreview
        // Full review #3's PF1 in miniature: a hidden view still participates
        // fully in Auto Layout, so the *tie* between the two cards has to go
        // with the hidden card, not merely its visibility.
        editorWidthTie.isActive = showEditor && showPreview
        hiddenCardCollapse(editorCard, collapsed: !showEditor, stored: &editorCollapse)
        hiddenCardCollapse(previewCard, collapsed: !showPreview && !showWrite, stored: &previewCollapse)
        view.layoutSubtreeIfNeeded()
        if showWrite, view.window != nil, view.window?.firstResponder === view.window { view.window?.makeFirstResponder(writeView.textView) }
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
        // A synchronous reload is newer than any read in flight.
        backgroundReload.invalidate()
        apply(NotebookFolderRead(store: store))
    }

    private func apply(_ read: NotebookFolderRead) {
        pages = read.pages
        overflowPages = read.overflow
        resolver = read.resolver
        index = read.index
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
        applyMode()
        showEditorOverlay(symbol: "book.pages",
                          title: "Your notebook is empty",
                          // **Review defect U9's second half.** This said
                          // "a markdown file in your config repo" while the
                          // header two lines above said "saved on this
                          // machine" - and on a Mac with no config repo the
                          // header was the true one. It asks `whereItGoes`
                          // now, which is derived from the same
                          // `store.gitSync` the header's own `syncSummary`
                          // reads, so the two cannot contradict each other
                          // again.
                          body: "Start with today's note, or add a page. "
                              + "Everything you write here is a markdown file \(whereItGoes).",
                          // X5: the Welcome page, offered where the captain
                          // is actually looking.
                          // R2-UX-07: New page is the toolbar's far-right
                          // primary, so the page offers its one example, like
                          // every module's empty state.
                          actions: [("Add a Welcome page", #selector(seedWelcomePageTapped))])
    }

    private func open(pageID: String) {
        guard let page = store.page(id: pageID) else {
            // A stale sidebar row (a page deleted on another machine). Redraw
            // rather than opening nothing.
            reload()
            return
        }
        let hadPage = currentID != nil
        currentID = page.id
        currentContent = page.content
        editorTitleLabel.stringValue = "\(page.slug).md"
        writeTitleLabel.stringValue = "\(page.slug).md"
        writeView.show(id: page.id, content: page.content)
        refreshMemoStrip(content: page.content)
        if !hadPage { applyMode() }
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
            // **Review bug B7.** This used to set `currentID`, `reload()` and
            // then `sidebar.select(renamed)` - and `select` moves the
            // selection without firing `onSelect`, so `open(pageID:)` never
            // ran. Monaco therefore kept posting `change` under the **old**
            // id, and the next debounce hit `pageEdited`'s own
            // `guard store.exists(id:)` and dropped every keystroke on the
            // floor. Repro: new page, type `# Title`, wait for the debounce,
            // keep typing, click the page - the paragraph is gone.
            //
            // `open(pageID:)` is the one path that re-registers the page with
            // the editor (`openSnippet` with the new id), and it selects the
            // sidebar row itself. `reload()` first, so the row it selects
            // exists.
            reload()
            open(pageID: renamed)
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

    /// PF11 of the 2026-09-25 full review: the daily-notes section was already
    /// capped (a year of them is 365 rows and a nav column is not an archive,
    /// GL-35) and the other two were not - so a notebook with three hundred
    /// top-level pages, or one crowded folder, put three hundred rows into a
    /// 208pt column and paid to rebuild every one of them on every publish.
    /// The same cap and the same honest header count apply to all three now.
    private static func section(header: String,
                                pages: [NotebookPage],
                                cap: Int) -> HelmPageSidebar.Section {
        let shown = Array(pages.prefix(cap))
        let title = pages.count > cap ? "\(header) (\(pages.count))" : header
        return .init(header: title, rows: shown.map(Self.row(for:)))
    }

    private func rebuildSidebar() {
        var sections: [HelmPageSidebar.Section] = []
        let topLevel = pages.filter { $0.folder.isEmpty }
        if !topLevel.isEmpty {
            sections.append(Self.section(header: "Pages", pages: topLevel, cap: Self.folderRowsShown))
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
            sections.append(Self.section(header: NotebookStore.humanise(lastComponentOf: folder),
                                         pages: inFolder,
                                         cap: Self.folderRowsShown))
        }
        sidebar.setSections(sections)
        if let currentID { sidebar.select(currentID) }
    }

    /// How many dated pages the sidebar lists. Thirty-one is one month, which
    /// is the window a daily note is actually reached backwards through.
    static let dailyRowsShown = 31
    /// PF11: the same ceiling for the "Pages" run and for each folder. Chosen
    /// to match `dailyRowsShown`'s own reasoning rather than a second number -
    /// a 208pt nav column that needs more than this is a search box's job, and
    /// the header states the real total whenever rows are being held back.
    static let folderRowsShown = 31

    private static func row(for page: NotebookPage) -> HelmPageSidebar.Row {
        .init(id: page.id,
              indicator: .symbol(page.isDailyNote ? HelmSymbol.Role.dailyNote.name : "doc.text"),
              title: page.title,
              showsCount: false)
    }

    private func refreshPreview() {
        preview.render(currentContent, resolver: resolver, sourcePageID: currentID, theme: theme)
        previewTitleLabel.stringValue = "Preview"
    }

    private func refreshRail() {
        refreshOutline()
        refreshBacklinks()
        refreshInspector()
    }

    /// UX-12: the page's headings, set in by level. A click takes the Write
    /// pane (or Source) to that heading.
    static func outline(of content: String) -> [(level: Int, title: String, line: Int)] {
        var out: [(Int, String, Int)] = []
        var inFence = false
        for (n, line) in content.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { continue }
            let title = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { out.append((hashes, title, n)) }
        }
        return out
    }

    private func refreshOutline() {
        outlineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        outlineSleeves.removeAll()
        let entries = Self.outline(of: currentContent)
        guard !entries.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No headings yet. A line starting with # becomes one.")
            empty.font = HelmType.caption()
            empty.textColor = HelmTheme.mutedInk(theme)
            outlineStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: outlineStack.widthAnchor).isActive = true
            return
        }
        let top = entries.map(\.level).min() ?? 1
        for entry in entries.prefix(40) {
            let row = HoverHighlightView()
            row.cornerRadius = HelmMetrics.rControl
            row.hoverColor = HelmPageSidebar.rowPalette(theme).hoverFill
            let label = NSTextField(labelWithString: entry.title)
            label.font = entry.level == top ? .systemFont(ofSize: HelmType.caption().pointSize, weight: .semibold) : HelmType.caption()
            label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                               constant: HelmMetrics.s1 + CGFloat(entry.level - top) * HelmMetrics.s3),
                label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -HelmMetrics.s1),
                label.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3),
            ])
            let line = entry.line
            let sleeve = ClosureSleeve { [weak self] in self?.revealOutlineLine(line) }
            outlineSleeves.append(sleeve)
            row.addGestureRecognizer(NSClickGestureRecognizer(target: sleeve, action: #selector(ClosureSleeve.invoke)))
            row.toolTip = "Go to \u{201C}\(entry.title)\u{201D}"
            outlineStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: outlineStack.widthAnchor).isActive = true
        }
    }

    /// Scrolls the Write pane to a heading's line and puts the caret there.
    private func revealOutlineLine(_ line: Int) {
        guard mode == .write else { return }
        let lines = writeView.textView.string.components(separatedBy: "\n")
        guard line < lines.count else { return }
        let location = lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let range = NSRange(location: location, length: 0)
        view.window?.makeFirstResponder(writeView.textView)
        writeView.textView.setSelectedRange(range)
        writeView.textView.scrollRangeToVisible(range)
    }

    private func refreshBacklinks() {
        backlinksStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        backlinkSleeves.removeAll()
        let links = currentID.map { index.backlinks(to: $0) } ?? []
        backlinksTitleLabel.stringValue = links.isEmpty ? "Linked from" : "Linked from \u{00B7} \(links.count)"
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

    /// The sync state's one reader on this page is the drill subtitle, so a
    /// change only has to refresh the inspector's own sync row.
    private func refreshStatusLine() {
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

    /// X5: writes the Welcome page and opens it.
    @objc private func seedWelcomePageTapped() {
        let created = store.createPage(title: SeedExamples.notebookTitle,
                                       content: SeedExamples.notebookContent)
        reload()
        open(pageID: created.id)
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
        refreshRail()
        onInspectorContentChanged?()
        if railVisible { onShowInspector?() }
    }

    /// A `[[link]]` clicked in the Write pane: the page it names, or a new
    /// page by that name, exactly as the preview's links do.
    private func openLinkTarget(_ target: String) {
        if let id = resolver.resolve(target, from: currentID) {
            open(pageID: id)
        } else {
            createMissingPage(named: target)
        }
    }

    /// The Edit menu's ⌘F while this destination is showing - Monaco's own
    /// find widget, exactly as Code Preview routes it.
    @objc func showFind() {
        guard mode == .write else { return webView.call("find") }
        // UX-12: the Write pane's own find bar.
        writeView.textView.usesFindBar = true
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.window?.makeFirstResponder(writeView.textView)
        writeView.textView.performTextFinderAction(item)
    }

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

    /// - Parameter action: an optional call to action under the copy.
    ///   **UX issue X5**: a blank editor gives no clue that `[[two
    ///   brackets]]` makes a link, or that the Backlinks panel on the right
    ///   will then have something in it - which is the one mechanic here
    ///   that nothing else in the app hints at. The review asked for a
    ///   Welcome page demonstrating exactly that, and it is opt-in rather
    ///   than seeded on first launch (see `SeedExamples`' header).
    private func showEditorOverlay(symbol: String, title: String, body: String,
                                   actions: [(title: String, selector: Selector)] = []) {
        editorOverlayState?.removeFromSuperview()
        let buttons = actions.map { spec -> NSView in
            let button = HelmButton(title: spec.title, variant: .secondary,
                                    target: self, action: spec.selector)
            button.controlSize = .small
            return button
        }
        let accessory: NSView?
        if buttons.count > 1 {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = HelmMetrics.s2
            accessory = row
        } else {
            accessory = buttons.first
        }
        // R2-UX-07: the page's own artwork, as Runbooks', Postmortems' and the
        // Sticky Board's empty states draw it - one empty state, one look.
        let state = HelmEmptyState(symbol: symbol, title: title, body: body,
                                   size: .standard, accessory: accessory,
                                   hue: RailDestination.notebook.domainHue,
                                   symbolWatermark: true)
        state.translatesAutoresizingMaskIntoConstraints = false
        // The card's width is the page's, never the sentence's: the one-line
        // copy at compression 750 held the editor card - and through the
        // equal-width tie, the preview - wide enough at the 960pt minimum to
        // squeeze the page tree's column (to 192pt on `main`, and to its
        // split-view minimum after P9).
        state.letBodyWrapToContainer()
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
        sidebar.applyTheme(theme)
        editorCard.applyTheme(theme)
        previewCard.applyTheme(theme)
        editorOverlay.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        backlinksCard.applyTheme(theme)
        inspectorCard.applyTheme(theme)
        outlineCard.applyTheme(theme)
        writeCard.applyTheme(theme)
        writeView.applyTheme(theme)
        memoStrip.applyTheme(theme)
        writeTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
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
    var debugRailHidden: Bool { !railVisible || inspectorContent == nil }
    var debugWriteCard: NSView { writeCard }
    var debugWriteCardHidden: Bool { writeCard.isHidden }
    var debugOutlineRowCount: Int { outlineStack.arrangedSubviews.filter { $0 is HoverHighlightView }.count }
    var debugEditorCard: NSView { editorCard }
    var debugPreviewCard: NSView { previewCard }
    var debugRail: NSView { rail }
    func debugSetMode(_ mode: ViewMode) {
        self.mode = mode
        applyMode()
    }
    func debugToggleRail() { toggleRail() }
    func debugOpen(pageID: String) { open(pageID: pageID) }
    func debugReload() { reload() }
    func debugReloadInBackground() { reloadInBackground() }
    var debugBackgroundReload: HelmBackgroundReload<NotebookFolderRead> { backgroundReload }
    func debugNewPage() { newPageTapped() }
    /// X5: the real button's action, so a check drives what a click drives.
    func debugSeedWelcomePage() { seedWelcomePageTapped() }
    var debugEditorOverlayState: HelmEmptyState? { editorOverlayState }
    func debugToday() { todayTapped() }
    /// Drives the same path the editor's own debounce does, so a suite can
    /// assert the write/rename/index behaviour without a live web page.
    func debugEdit(id: String, content: String) { pageEdited(id: id, content: content) }
    func debugCreateMissingPage(named target: String) { createMissingPage(named: target) }
    /// The editor's own readiness and bridge, so the window-backed suite can
    /// read Monaco's tokenizer output back rather than asserting that a
    /// palette was sent.
    var debugEditorIsReady: Bool { webView.isReady }
    /// The "<slug>.md" caption over the editor, which only `open(pageID:)`
    /// writes - review bug B7's one observable witness that the rename
    /// re-pointed the editor, in a headless suite where the web view is never
    /// ready and so no `openSnippet` is sent at all.
    var debugEditorTitle: String { editorTitleLabel.stringValue }
    /// The bridge's own call log, for review bug B7 - see
    /// `CodePreviewWebView.debugCalls` for why nothing else can see that
    /// defect.
    var debugBridgeCalls: [(name: String, payload: [String: Any])] { webView.debugCalls }
    func debugResetBridgeCalls() { webView.debugResetCalls() }
    func debugEditorCall(_ name: String, payload: [String: Any],
                         completion: @escaping (Result<[String: Any], CodePreviewBridgeError>) -> Void) {
        webView.call(name, payload: payload, completion: completion)
    }
    #endif
}

// R2-UX-04: New page is the page's primary verb, so the sidebar layout draws
// it at the toolbar's far right; Today's note stays an outlined page action.
extension NotebookController: WorkspacePrimaryActionProviding {
    var workspacePrimaryAction: NSView? { newPageButton }
}

// R5-UI-01: Source, Split or Preview changes how this page lays itself out,
// so in the sidebar layout it sits on the page's own row, at the trailing end
// of the header's subtitle line. In the window toolbar, beside Knowledge's
// five tabs, it pushed the inspector button into the overflow menu at the
// captain's 1512pt. It stays one of `drillHeaderActions`, which the shell
// leaves out of the toolbar for it, so the pop-up's state has one owner.
extension NotebookController: WorkspaceHeaderAccessoryProviding {
    var workspaceHeaderAccessory: NSView? { toolbarModePopUp }
}

// R2-UX-06: the Notebook has no page toolbar row. Its controls are the
// window toolbar's (`drillHeaderActions`), keeping R2-BUG-07's icon-only
// actions below `compactToolbarActionsBelow`. P-03 of the 2026-11-25 review
// removed the floating bar, the one layout that drew the row.
extension NotebookController {
    func buildSidebarPresentation() {
        toolbarModePopUp.selectItem(at: ViewMode.allCases.firstIndex(of: mode) ?? 0)
        onDrillActionsChanged?()
    }
}

#if FM_SELFTESTS
extension NotebookController {
    var debugToolbarModePopUp: HelmPopUpButton { toolbarModePopUp }
    var debugMode: ViewMode { mode }
}
#endif

// MARK: - UX-12: the page's details in the shell's inspector

extension NotebookController: WorkspaceInspectorSource {
    /// The outline, the pages that link here and the page's facts, once the
    /// captain asks for them (the toolbar's inspector button, or Show Page
    /// Details). Never before: a page with details is a page the shell makes
    /// room for.
    var inspectorContent: WorkspaceInspectorContent? {
        guard isViewLoaded, railVisible, currentID != nil else { return nil }
        return WorkspaceInspectorContent(title: "Page details", view: rail)
    }

    var inspectorEmptyText: (title: String, body: String) {
        ("No page open", "Open a page to see its outline and the pages that link to it.")
    }

    func inspectorShouldClose() -> Bool {
        railVisible = false
        return true
    }

    func inspectorWillOpen() {
        guard !railVisible else { return }
        railVisible = true
        refreshRail()
        // The shell is mid-way through opening the pane, so it hears about
        // the details on the next turn rather than from inside its own call.
        DispatchQueue.main.async { [weak self] in self?.onInspectorContentChanged?() }
    }
}



/// F-05: the Notebook's root, which takes an audio file dropped anywhere on
/// the page.
final class NotebookRootView: NSView {

    var onDropAudio: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func audioURLs(in pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { VoiceMemoFiles.audioExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.audioURLs(in: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.audioURLs(in: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onDropAudio?(urls) ?? false
    }
}
