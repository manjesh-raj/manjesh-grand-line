// Grand Line - native macOS app.
//
// F4 of full review #3 §8 - the `.readingList` destination, in the Stores
// space beside Docs, the Notebook, Runbooks, Postmortems, Tools, the
// Whiteboard and the Sticky Board.
//
// The report's entry is one sentence ("paste a URL anywhere \u{2192} a card with
// title/favicon/summary via local `LinkPresentation`, tags, 'read', optional
// AI one-paragraph summary via `ClaudeOneShot`; Docs' `WKWebView` reader is
// there; adds a Stores card"), and the captain reviewed a mockup of the page
// before it existed. The arrangement below is that mockup's:
//
//   - a left column of inbox slices (Unread / Read / Added today) over a list
//     of tags with counts - `HelmPageSidebar`, not a fifth hand-rolled nav;
//   - no toolbar row of its own. It once carried a segmented All / Unread /
//     Summarised strip (UI-60 made the sidebar the one filter), then only a
//     paste icon and a refresh icon at the far right of an otherwise empty
//     band (R4-UI-05). Refresh is one of the page's own actions now, beside
//     Paste link, and the paste icon ran the very same `pasteTapped` as Paste
//     link, so it went rather than sitting next to its twin. Its drop hint
//     said what the drop card under the grid says;
//   - a responsive grid of cards, three states deep (summarised, awaiting a
//     summary, read) - `ReadingListCardView`;
//   - a dashed drop-zone card under the grid.
//
// ## What is reused rather than rebuilt
//
//   - **The reader is a `WKWebView` in a card, exactly as Docs does it** -
//     same locked navigation-delegate shape, same `HelmMetrics` surround, and
//     `WebNavigationPolicy` is asked the routing question rather than a second
//     copy of the rule. The one difference is deliberate and is the point of
//     this page: Docs is pinned to a folder on disk, so *everything* else goes
//     to `NSWorkspace`; a reading list is pinned to a saved http(s) link, so
//     that link and its own in-page navigation load here and everything else
//     goes to the system browser.
//   - **The AI summary is `ClaudeOneShot`** through `ReadingListAI`, opt-in
//     per card. That file's header has the three reasons it is not automatic.
//   - **The metadata is Apple's `LinkPresentation`**, locally, behind the
//     `ReadingListMetadataFetching` seam.
//   - **The storage is `StickyBoardStore`'s shape** - one batched YAML file on
//     `ShiftGitSync.shared`'s working tree and serial queue.
//   - **The paste route is `CaptureRouter`'s**, which already owned ⌥Space's
//     five destinations; this adds a sixth rather than a second panel.
//
// ## Gotchas this page is built against
//
// (8) the root is a plain layer-backed `NSView`, never `NSVisualEffectView`.
// (4) the grid's document view pins to the **clip** view. (9) that document is
// a `FlippedView`, or a short grid rests against the bottom of the viewport.
// (13) every fixed width here sits at `contentTie` (499), below
// `NSLayoutPriorityWindowSizeStayPut`, so no column of this page can cap the
// window. (16) the sidebar's height is tied to the page rather than left to a
// content preference.

import AppKit
import WebKit

final class ReadingListController: NSViewController, DaylightDrillActions, HelmSplitPageHosting {

    /// The bell entry a failed git sync leaves, cleared by the next sync that
    /// works. A stable id is what lets a recurring failure update one entry
    /// rather than stack a new one every attempt (GL-30 / `Feedback.clear`).
    private static let syncFailureNotificationID = "reading-list-sync-failed"

    private static let gutter: CGFloat = HelmMetrics.s3

    // MARK: State

    private let store: ReadingListStore
    private let fetcher: ReadingListMetadataFetching

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeObservation: ThemeObservation?

    /// UI-60: the sidebar is the one filter, so this has one writer.
    private var filter: ReadingListFilter = .all

    private var syncStatus: ReadingListGitSync.Status = .synced
    /// GL-14: "nothing loaded yet" and "nothing saved" are different states,
    /// and the drill subtitle says which.
    private var hasLoaded = false
    private var lastError: String?

    /// Ids with a `LinkPresentation` fetch in flight, so a re-render while one
    /// is running does not start a second.
    private var fetchesInFlight: Set<String> = []
    /// Ids with a `claude -p` turn in flight, same reason.
    private var summariesInFlight: Set<String> = []

    /// The link the reader is showing, or `nil` when the grid is.
    private var readingID: String?

    // MARK: Views

    /// UI-45: one sidebar shape across the app - `HelmPageSidebar` on the
    /// plain surface with muted counts, the Tasks sidebar the revamp kept.
    /// A boxed panel around the nav was a second bordered surface beside the
    /// page's own cards (Rule 1).
    private let sidebar = HelmPageSidebar()
    /// P9: the page's split view, which holds `sidebar` as a real sidebar.
    private(set) var splitPage: HelmSplitPage?

    private let gridScroll = NSScrollView()
    private let gridDocument = FlippedView()
    private let gridStack = NSStackView()
    private let dropHintCard = ReadingListDropHintView()
    private var emptyState: HelmEmptyState?
    /// The title the current empty state is showing, kept beside it so a suite
    /// can assert *which* of the three states is on screen - `HelmEmptyState`
    /// exposes no title of its own.
    private var emptyStateTitle: String?

    private let readerCard = NSView()
    private var readerWebView: WKWebView!
    /// F-03: the saved text as a clean page, over the original.
    let readerView = ReadingListReaderView()
    let articles = ReaderArticleQueue()
    private var showingOriginal = false
    private var readerModeButton: HelmButton!
    private let highlightsList = NSStackView()
    static let lastNotebookPageKey = "fm.readingList.lastHighlightPage"
    private let readerBar = HelmPageToolbar()
    private let readerTitle = NSTextField(labelWithString: "")
    private var readerBackButton: HelmButton!
    private var readerReloadButton: HelmButton!
    private var readerOpenButton: HelmButton!
    private var readerCloseButton: HelmButton!

    private let pasteButton = HelmButton(title: "Paste link", variant: .primary, symbol: "plus")
    /// R4-UI-05: re-reads titles for everything still waiting. One of the
    /// page's actions, where the empty band under the header used to hold it.
    private lazy var refreshButton = HelmPageToolbar.iconButton(
        symbol: "arrow.clockwise", tooltip: "Re-read titles for everything still waiting",
        target: self, action: #selector(refreshMetadataTapped))

    private var cards: [String: ReadingListCardView] = [:]
    private var lastGridWidth: CGFloat = 0
    private var tagPopover: NSPopover?

    // MARK: Init

    init(store: ReadingListStore,
         fetcher: ReadingListMetadataFetching = LinkPresentationMetadataFetcher()) {
        self.store = store
        self.fetcher = fetcher
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?
    var onDrillActionsChanged: (() -> Void)?

    var drillHeaderActions: [NSView] { [refreshButton, pasteButton] }

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        // GL-14: a list nobody has read off disk yet is not an empty list, and
        // neither of them is "0 saved".
        guard hasLoaded else { return "Opening the reading list\u{2026}" }
        // UX-13: the paste well says how a link is added, always, so the
        // line no longer carries R5-UX-10's quiet hint for it.
        return "\(ReadingListQuery.headline(store.links)) \u{00B7} \(syncSummary)"
    }

    /// One wording for the sync state, read by both the drill subtitle and the
    /// page's own status line, so the two can never disagree about whether the
    /// captain's list has reached GitHub.
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
        // `NSView` with a `HelmTheme` fill. `.behindWindow` vibrancy
        // composites against the desktop, not against this window, and has
        // shipped as a visible defect here four separate times.
        let root = ReadingListDropRootView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.wantsLayer = true
        root.onDropText = { [weak self] text in self?.capture(text, source: "drop") }
        view = root

        buildBody(in: root)
        buildReader(in: root)
        buildActions()

        themeObservation = ThemeManager.shared.observe { [weak self, weak root] theme in
            guard let self else { return }
            // `ThemeManager.swift`'s checklist item 2, the one most often
            // missed: force the appearance, or the scroller chrome, the shared
            // field editor and any menu follow the OS rather than the theme.
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self.theme = theme
            self.applyTheme()
        }

        // GL-09 / audit #2 §5.1(b): a popover left open when the app lock
        // fires stays readable and interactive *above* the lock overlay, so
        // every popover in this app registers to be dismissed on the way in.
        // The tag editor carries the captain's own data, which is exactly
        // what the lock exists to hide.
        // `LockGateCoverageSelfTest` is the source guard that caught this
        // missing.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.tagPopover }

        store.gitSync?.observeStatus { [weak self] status in
            guard let self else { return }
            self.syncStatus = status
            self.onDrillSubtitleChanged?()
            if case .failed(let why) = status {
                // GL-30: a failed sync is still true after a toast would have
                // faded, so it goes to the bell as well - with a stable id, so
                // a repeated failure updates one entry.
                Feedback.report("The reading list could not sync.",
                                kind: .failure,
                                persistence: .lasting,
                                in: nil,
                                id: Self.syncFailureNotificationID,
                                detail: why)
            } else {
                Feedback.clear(id: Self.syncFailureNotificationID)
            }
        }

        reload()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // P11: a revisit reads the list off the main thread and keeps the page
        // as it was until the read lands - and when the read finds nothing
        // changed, keeps the cards it has. Rebuilding 400 cards costs ~1.3s on
        // the main thread, which on an unchanged revisit bought nothing.
        let before = store.links
        let wasFailed = store.isInFailedLoadState
        store.reloadAllInBackground { [weak self] in
            guard let self else { return }
            if self.hasLoaded, self.store.links == before, self.store.isInFailedLoadState == wasFailed { return }
            self.renderAfterReload()
        }
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    /// Called by the app delegate on quit, so the last read-marks before ⌘Q are
    /// committed like every other edit.
    func shutdown(deadline: DispatchTime) {
        // PF12: a burst of metadata fetches writes once, shortly after it
        // settles - so quitting inside that window has to drain it first, or
        // the titles and icons just fetched are lost. Before the git flush,
        // deliberately: that flush is what pushes what this writes.
        store.flush()
        store.gitSync?.flushForTerminationNow(deadline: deadline)
    }

    // MARK: Building

    private func buildActions() {
        pasteButton.controlSize = .small
        pasteButton.target = self
        pasteButton.action = #selector(pasteTapped)
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        pasteButton.toolTip = "Save the link on the clipboard to the reading list"
    }

    private func buildBody(in root: NSView) {
        sidebar.onSelect = { [weak self] id in
            guard let self, let picked = ReadingListFilter.fromID(id) else { return }
            self.filter = picked
            self.rebuildGrid()
        }
        highlightsList.orientation = .vertical
        highlightsList.alignment = .leading
        highlightsList.spacing = HelmMetrics.s2
        highlightsList.translatesAutoresizingMaskIntoConstraints = false
        highlightsList.isHidden = true

        gridScroll.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.drawsBackground = false
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        // Gotcha (9): a plain `NSView()` document is **not** flipped, so a grid
        // shorter than the viewport rests against its *bottom* and leaves a
        // blank band above the first row. `FlippedView` is this app's fix, and
        // every scroll-backed page here uses it.
        gridDocument.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.documentView = gridDocument

        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = HelmResponsiveGrid.spacing
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridDocument.addSubview(gridStack)

        dropHintCard.translatesAutoresizingMaskIntoConstraints = false
        dropHintCard.onDropText = { [weak self] text in self?.capture(text, source: "drop") }
        dropHintCard.onSave = { [weak self] text in self?.saveFromWell(text) ?? false }
        gridDocument.addSubview(dropHintCard)
        gridDocument.addSubview(highlightsList)

        // P9: the column is a real split-view sidebar - draggable, collapsible
        // and answering Toggle Sidebar - at the place it was pinned before.
        // Gotcha (16): the column's height is still tied to the page (the
        // pane's top and bottom insets) rather than left to a low-priority
        // content preference - a container whose height nothing ties lets its
        // content escape it, and that shipped once as a panel drawn over the
        // app's top bar.
        // S04: Settings' band - the column's region in the side-panel fill,
        // edged by the divider, with Settings' padding.
        let split = HelmSplitPage(sidebarWidth: HelmPageSidebar.bandPaneWidth,
                                  minimum: HelmPageSidebar.bandPaneWidth - HelmPageSidebar.width * 0.2,
                                  maximum: HelmPageSidebar.bandPaneWidth + HelmPageSidebar.width * 0.6,
                                  surface: .sidePanel)
        addChild(split)
        root.addSubview(split.view)
        HelmSplitPage.pin(sidebar, in: split.sidebarPane, insets: HelmPageSidebar.bandInsets)
        // S03: the grid starts at the page frame's first-content line.
        HelmSplitPage.pin(gridScroll, in: split.contentPane,
                          insets: NSEdgeInsets(top: HelmMetrics.pageContentInset, left: Self.gutter - HelmSplitPage.dividerThickness,
                                               bottom: Self.gutter, right: Self.gutter))
        splitPage = split

        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Gotcha (4): the document pins to the **clip** view, never the
            // scroll view - a non-overlay scroller reserves a real ~15pt track
            // that narrows the clip view without narrowing `gridScroll`.
            gridDocument.widthAnchor.constraint(equalTo: gridScroll.contentView.widthAnchor),

            // UX-13: the paste well leads the page, and the list follows it.
            dropHintCard.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor),
            dropHintCard.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor),
            dropHintCard.topAnchor.constraint(equalTo: gridDocument.topAnchor),

            gridStack.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor),
            gridStack.topAnchor.constraint(equalTo: dropHintCard.bottomAnchor, constant: HelmResponsiveGrid.spacing),
            gridStack.bottomAnchor.constraint(equalTo: gridDocument.bottomAnchor, constant: -Self.gutter),
            // F-03: the Highlights slice, in the grid's place.
            highlightsList.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor),
            highlightsList.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor),
            highlightsList.topAnchor.constraint(equalTo: dropHintCard.bottomAnchor, constant: HelmResponsiveGrid.spacing),
            gridDocument.bottomAnchor.constraint(greaterThanOrEqualTo: highlightsList.bottomAnchor, constant: Self.gutter),
        ])
    }

    private func buildReader(in root: NSView) {
        // Docs' own shape: the web view lives inside a rounded card that clips,
        // rather than filling the destination edge to edge.
        readerCard.translatesAutoresizingMaskIntoConstraints = false
        readerCard.wantsLayer = true
        readerCard.layer?.masksToBounds = true
        readerCard.isHidden = true
        root.addSubview(readerCard)

        let config = WKWebViewConfiguration()
        // S13 (review security finding). This reader loads **arbitrary
        // external pages** - whatever the captain saved a link to - and it
        // used the process-wide default data store, which is the same
        // cookie jar, localStorage and disk cache the app's other web
        // surfaces share and which outlives the launch.
        //
        // It is the one web view here that has a real reason to be isolated:
        // the other three render a fixed local bundle and set this for a
        // storage-cost reason (PF5). Here it is a boundary. A saved article
        // gets no session that persists, nothing it writes is readable by a
        // later page, and nothing about the captain's other browsing is
        // visible to it. Reading an article does not need a session, so
        // nothing is lost.
        config.websiteDataStore = .nonPersistent()
        readerWebView = WKWebView(frame: .zero, configuration: config)
        readerWebView.navigationDelegate = self
        readerWebView.translatesAutoresizingMaskIntoConstraints = false

        readerTitle.font = HelmType.rowTitle()
        readerTitle.lineBreakMode = .byTruncatingTail
        readerTitle.translatesAutoresizingMaskIntoConstraints = false
        readerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        readerBackButton = HelmPageToolbar.iconButton(symbol: "chevron.left",
                                                      tooltip: "Back",
                                                      target: self, action: #selector(readerBackTapped))
        readerReloadButton = HelmPageToolbar.iconButton(symbol: "arrow.clockwise",
                                                        tooltip: "Reload",
                                                        target: self, action: #selector(readerReloadTapped))
        readerOpenButton = HelmPageToolbar.iconButton(symbol: "arrow.up.forward.square",
                                                      tooltip: "Open in the system browser",
                                                      target: self, action: #selector(readerOpenExternallyTapped))
        readerModeButton = HelmButton(title: "Original", variant: .secondary, size: .small, symbol: "safari",
                                      target: self, action: #selector(readerModeTapped))
        readerModeButton.toolTip = "Switch between the saved text and the page itself"
        readerCloseButton = HelmPageToolbar.iconButton(symbol: "xmark",
                                                       tooltip: "Back to the reading list",
                                                       target: self, action: #selector(closeReaderTapped))

        readerBar.setLeading(HelmPageToolbar.group([readerCloseButton, readerTitle]))
        readerBar.setTrailing(HelmPageToolbar.group([readerModeButton, readerBackButton, readerReloadButton, readerOpenButton]))

        readerCard.addSubview(readerBar)
        readerCard.addSubview(readerWebView)
        readerCard.addSubview(readerView)
        readerView.onHighlight = { [weak self] block, range in self?.addHighlight(block: block, range: range) }
        readerView.onSendToNotebook = { [weak self] block, range, anchor in
            self?.showNotebookMenu(block: block, range: range, anchor: anchor)
        }
        readerView.onTryAgain = { [weak self] in
            guard let self, let id = self.readingID, let link = self.store.link(id: id) else { return }
            self.articles.enqueue(link, force: true)
        }
        readerView.onOpenOriginal = { [weak self] in self?.setShowingOriginal(true) }
        articles.onSaved = { [weak self] id in
            guard let self else { return }
            if self.readingID == id, !self.showingOriginal { self.showReaderText() }
            self.refreshCard(id: id)
        }
        NSLayoutConstraint.activate([
            readerCard.leadingAnchor.constraint(equalTo: gridScroll.leadingAnchor),
            readerCard.trailingAnchor.constraint(equalTo: gridScroll.trailingAnchor),
            readerCard.topAnchor.constraint(equalTo: gridScroll.topAnchor),
            readerCard.bottomAnchor.constraint(equalTo: gridScroll.bottomAnchor),

            readerBar.leadingAnchor.constraint(equalTo: readerCard.leadingAnchor),
            readerBar.trailingAnchor.constraint(equalTo: readerCard.trailingAnchor),
            readerBar.topAnchor.constraint(equalTo: readerCard.topAnchor),

            readerWebView.leadingAnchor.constraint(equalTo: readerCard.leadingAnchor),
            readerWebView.trailingAnchor.constraint(equalTo: readerCard.trailingAnchor),
            readerWebView.topAnchor.constraint(equalTo: readerBar.bottomAnchor),
            readerWebView.bottomAnchor.constraint(equalTo: readerCard.bottomAnchor),
            readerView.leadingAnchor.constraint(equalTo: readerCard.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: readerCard.trailingAnchor),
            readerView.topAnchor.constraint(equalTo: readerBar.bottomAnchor),
            readerView.bottomAnchor.constraint(equalTo: readerCard.bottomAnchor),
        ])
    }

    // MARK: F-03 - reader mode

    /// The saved text when there is some, and the page when asked for.
    func showReaderText() {
        guard let id = readingID else { return }
        let article = articles.store.article(id: id)
        readerView.show(article, theme: theme)
        readerView.isHidden = showingOriginal
    }

    func setShowingOriginal(_ original: Bool) {
        showingOriginal = original
        readerModeButton.title = original ? "Reader" : "Original"
        readerModeButton.symbolName = original ? "doc.plaintext" : "safari"
        readerView.isHidden = original
        readerBackButton.isHidden = !original
        readerReloadButton.isHidden = !original
        if original, let id = readingID, let link = store.link(id: id), let url = URL(string: link.url),
           readerWebView.url == nil || readerWebView.url?.absoluteString == "about:blank",
           NetworkGate.allowsOutOfProcessLoad(url) {
            readerWebView.load(URLRequest(url: url))
        }
        if !original { showReaderText() }
    }

    @objc private func readerModeTapped() { setShowingOriginal(!showingOriginal) }

    func addHighlight(block: Int, range: NSRange) {
        guard let id = readingID, var article = articles.store.article(id: id),
              let highlight = ReaderHighlights.make(article: article, block: block, range: range) else { return }
        article.highlights.append(highlight)
        articles.store.save(article)
        showReaderText()
        rebuildSidebar()
    }

    /// The last page a highlight went to, recent pages, and a new page.
    private func showNotebookMenu(block: Int, range: NSRange, anchor: NSView) {
        guard let notebook = GrandLineServices.shared.notebookStore else {
            Toast.show(in: view, message: "Open the Notebook once, then send highlights to it", kind: .warning)
            return
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: "Send this highlight to", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let last = AppDefaults.store.string(forKey: Self.lastNotebookPageKey)
        var pages = notebook.listPages().sorted { $0.modifiedAt > $1.modifiedAt }
        if let last, let index = pages.firstIndex(where: { $0.id == last }) { pages.insert(pages.remove(at: index), at: 0) }
        for page in pages.prefix(6) {
            let item = NSMenuItem(title: page.id == last ? "\(page.title) \u{00B7} used last" : page.title,
                                  action: #selector(notebookPagePicked(_:)), keyEquivalent: "")
            item.representedObject = [page.id, block, range.location, range.length] as [Any]
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "A new page", action: #selector(notebookPagePicked(_:)), keyEquivalent: "")
        new.representedObject = ["", block, range.location, range.length] as [Any]
        new.target = self
        menu.addItem(new)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func notebookPagePicked(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [Any], values.count == 4,
              let pageID = values[0] as? String, let block = values[1] as? Int,
              let location = values[2] as? Int, let length = values[3] as? Int else { return }
        sendHighlight(block: block, range: NSRange(location: location, length: length), toPage: pageID.isEmpty ? nil : pageID)
    }

    /// Highlights the passage if it is not already, appends it to the page
    /// (or a new one named after the article) with its source, and answers
    /// the page's id.
    @discardableResult
    func sendHighlight(block: Int, range: NSRange, toPage pageID: String?) -> String? {
        guard let notebook = GrandLineServices.shared.notebookStore, let id = readingID,
              var article = articles.store.article(id: id) else { return nil }
        var highlight = article.highlights.first { $0.block == block && $0.start == range.location && $0.length == range.length }
            ?? ReaderHighlights.make(article: article, block: block, range: range)
        guard highlight != nil else { return nil }
        let quote = ReaderHighlights.notebookQuote(highlight!, article: article)
        let target: NotebookPage
        if let pageID, let page = notebook.page(id: pageID) {
            notebook.updatePage(id: page.id, content: page.content + (page.content.hasSuffix("\n") ? "\n" : "\n\n") + quote)
            target = page
        } else {
            target = notebook.createPage(title: "Reading notes \u{203A} \(article.title)", content: "# Reading notes\n\n" + quote)
        }
        highlight!.sentToPageID = target.id
        article.highlights.removeAll { $0.id == highlight!.id }
        article.highlights.append(highlight!)
        articles.store.save(article)
        AppDefaults.store.set(target.id, forKey: Self.lastNotebookPageKey)
        showReaderText()
        rebuildSidebar()
        Toast.show(in: view, message: "Sent to \(target.title)")
        return target.id
    }

    /// The Highlights slice: every highlight, newest first, as quote rows.
    private func rebuildHighlightsList() {
        highlightsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = articles.store.allHighlights()
        if all.isEmpty {
            let empty = HelmEmptyState(symbol: "highlighter", title: "No highlights yet",
                                       body: "Open a saved article, select a passage and choose Highlight.")
            empty.applyTheme(theme)
            highlightsList.addArrangedSubview(empty)
            return
        }
        for (article, highlight) in all {
            let row = HelmAccentRow(chipPlacement: .trailing, trailingAccessory: nil, hover: false)
            row.configure(HelmAccentRow.Content(tint: .warn, kicker: article.site.uppercased(),
                                                title: "\u{201C}\(highlight.text)\u{201D}",
                                                meta: article.title + (highlight.sentToPageID != nil ? " \u{00B7} in Notebook" : ""),
                                                badgeSymbol: "highlighter", titleWraps: true), theme: theme)
            highlightsList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: highlightsList.widthAnchor).isActive = true
        }
    }

    // MARK: Loading

    private func reload() {
        store.reloadAll()
        renderAfterReload()
    }

    /// Everything `reload` does once the store holds a fresh read - shared by
    /// the synchronous reload and the background one (P11).
    private func renderAfterReload() {
        hasLoaded = true
        lastError = store.isInFailedLoadState
            ? "The reading list file could not be read - nothing new will be written until it is fixed."
            : nil
        rebuildSidebar()
        rebuildGrid()
        onDrillSubtitleChanged?()
        fetchMissingMetadata()
    }

    /// Ask `LinkPresentation` about everything still `.pending`.
    ///
    /// Bounded: `maximumConcurrentFetches` at a time, because a captain who
    /// drops twenty tabs at once should not open twenty simultaneous
    /// connections from this app (GL-35, nothing unbounded). The rest are
    /// picked up by the next pass, which every completion triggers.
    private static let maximumConcurrentFetches = 3

    private func fetchMissingMetadata() {
        guard !store.isInFailedLoadState else { return }
        let pending = store.links.filter {
            $0.metadataState == .pending && !fetchesInFlight.contains($0.id)
        }
        let slots = Self.maximumConcurrentFetches - fetchesInFlight.count
        guard slots > 0 else { return }
        for link in pending.prefix(slots) {
            fetchesInFlight.insert(link.id)
            let id = link.id
            fetcher.fetch(url: link.url) { [weak self] result in
                guard let self else { return }
                self.fetchesInFlight.remove(id)
                switch result {
                case .success(let metadata):
                    self.store.applyMetadata(id: id, metadata)
                    // F-03: keep the article's text once its link is known good.
                    if let link = self.store.link(id: id) { self.articles.enqueue(link) }
                case .failure(let error):
                    self.store.applyMetadataFailure(id: id, reason: error.message)
                }
                self.refreshCard(id: id)
                self.rebuildSidebar()
                self.onDrillSubtitleChanged?()
                self.fetchMissingMetadata()
            }
        }
    }

    // MARK: Capture

    /// The one place a captured string becomes a card. Every entry point -
    /// ⌘V, a drop on the page, a drop on the hint card, ⌥Space's ⌘6, the File
    /// menu - lands here, so they cannot disagree about what was saved or
    /// about what the captain is told.
    @discardableResult
    func capture(_ raw: String, source: String) -> Bool {
        switch store.add(raw) {
        case .added(let link):
            rebuildSidebar()
            rebuildGrid()
            onDrillSubtitleChanged?()
            fetchMissingMetadata()
            AppLog.store.debug("reading list: saved a link from \(source, privacy: .public)")
            // GL-30: a save is used and gone before the pill is, so it is a
            // toast and nothing else.
            Feedback.report("Saved \(link.host) to the reading list.",
                            kind: .done, persistence: .transient, in: isViewLoaded ? view : nil)
            return true
        case .duplicate(let link):
            // Not silence: a captain who pasted something and saw nothing
            // happen cannot tell a duplicate from a bug.
            Feedback.report("\(link.host) is already on the reading list.",
                            kind: .warning, persistence: .transient, in: isViewLoaded ? view : nil)
            scrollToCard(id: link.id)
            return false
        case .rejected(let why):
            Feedback.report(why, kind: .failure, persistence: .transient, in: isViewLoaded ? view : nil)
            return false
        }
    }

    /// UX-13: the paste well's Save. A field the captain pasted into with
    /// \u{2318}V read the pasteboard through the field editor, not this page,
    /// so the concealed rule is asked here too: a Poneglyph secret on the
    /// pasteboard that is exactly what the field holds is refused.
    private func saveFromWell(_ text: String) -> Bool {
        if CredentialVaultClipboard.isConcealed(.general),
           NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            Feedback.report("That clipboard entry came from Poneglyph, so it was not saved.",
                            kind: .warning, persistence: .transient, in: isViewLoaded ? view : nil)
            return false
        }
        return capture(text, source: "well")
    }

    /// The File menu's "New Link" and the drill header's Paste button.
    func newLinkFromMenu() { pasteTapped() }

    @objc private func addExampleLinkTapped() {
        _ = store.add(SeedExamples.readingListURL)
    }

    @objc private func pasteTapped() {
        // The concealed-pasteboard rule, asked **before** the string is read:
        // `CredentialVaultClipboard.isConcealed` is this app's one definition
        // of "a secret is on the pasteboard", and checking it first makes
        // "a vault secret never reaches this store" a property of the control
        // flow rather than of a filter somebody could reorder.
        guard !CredentialVaultClipboard.isConcealed(.general) else {
            Feedback.report("That clipboard entry came from Poneglyph, so it was not saved.",
                            kind: .warning, persistence: .transient, in: isViewLoaded ? view : nil)
            return
        }
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Feedback.report("There is no text on the clipboard to save.",
                            kind: .warning, persistence: .transient, in: isViewLoaded ? view : nil)
            return
        }
        capture(raw, source: "clipboard")
    }

    @objc private func refreshMetadataTapped() {
        // Everything that failed goes back in the queue. A `.resolved` link is
        // left alone - re-fetching a title this app already has would spend
        // the captain's bandwidth to change nothing.
        for link in store.links where link.metadataState.failureReason != nil {
            store.markMetadataPending(id: link.id)
            refreshCard(id: link.id)
        }
        fetchMissingMetadata()
    }

    // MARK: Card actions

    private func toggleRead(id: String) {
        guard let before = store.link(id: id) else { return }
        guard let after = store.setRead(id: id, read: !before.isRead) else { return }
        refreshCard(id: id)
        rebuildSidebar()
        onDrillSubtitleChanged?()
        // The grid's order depends on read state, so the card has to move -
        // but only when the current filter would no longer show it, which is
        // what keeps a click on a pill from reshuffling the whole page.
        if !ReadingListQuery.matches(filter, after) { rebuildGrid() }
    }

    private func summarise(id: String) {
        guard let link = store.link(id: id), !summariesInFlight.contains(id) else { return }
        summariesInFlight.insert(id)
        cards[id]?.setSummarising(true)
        ReadingListAI.summarise(link) { [weak self] result in
            guard let self else { return }
            self.summariesInFlight.remove(id)
            switch result {
            case .success(let paragraph):
                self.store.setAISummary(id: id, summary: paragraph)
                self.refreshCard(id: id)
                self.rebuildSidebar()
            case .failure(let error):
                self.cards[id]?.setSummarising(false)
                Feedback.report("Could not summarise that link: \(error.message)",
                                kind: .failure, persistence: .transient, in: self.isViewLoaded ? self.view : nil)
            }
        }
    }

    private func retryMetadata(id: String) {
        store.markMetadataPending(id: id)
        refreshCard(id: id)
        fetchMissingMetadata()
    }

    private func delete(id: String) {
        guard let link = store.link(id: id) else { return }
        // GL-06: one confirmation for an irreversible delete. It is not
        // irreversible here - the Undo below restores the exact record - so
        // this asks once and offers the way back rather than doing both.
        guard let removed = store.delete(id: id) else { return }
        rebuildSidebar()
        rebuildGrid()
        onDrillSubtitleChanged?()
        // GL-33: an undo restores the value the caller already had in hand.
        Toast.showUndo(in: view, message: "Removed \(link.host).") { [weak self] in
            guard let self else { return }
            self.store.restore(removed)
            self.rebuildSidebar()
            self.rebuildGrid()
            self.onDrillSubtitleChanged?()
        }
    }

    private func editTags(id: String) {
        guard let link = store.link(id: id), let anchor = cards[id] else { return }
        tagPopover?.close()

        let input = HelmChipInput(placeholder: "tag, then Return")
        input.setTokens(link.tags)
        input.domainHue = ReadingListHostHue.hue(for: link.url)
        input.onTokensChanged = { [weak self] tokens in
            guard let self else { return }
            self.store.setTags(id: id, tags: tokens)
            self.refreshCard(id: id)
            self.rebuildSidebar()
        }
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        input.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(input)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: HelmMetrics.s3),
            input.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -HelmMetrics.s3),
            input.topAnchor.constraint(equalTo: body.topAnchor, constant: HelmMetrics.s3),
            input.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -HelmMetrics.s3),
            body.widthAnchor.constraint(equalToConstant: 300),
        ])

        let holder = NSViewController()
        holder.view = body
        let popover = NSPopover()
        popover.contentViewController = holder
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        tagPopover = popover
    }

    // MARK: The reader

    /// Open one link in the page's own `WKWebView`, and mark it read.
    ///
    /// Marking on open rather than on close is the honest reading of the
    /// state: "read" here means "you have opened this and it is no longer
    /// waiting for you", and a captain who bounces straight back out has still
    /// dealt with it. The pill is one click away either way.
    func openReader(id: String) {
        guard let link = store.link(id: id), let url = URL(string: link.url) else { return }
        readingID = id
        readerTitle.stringValue = link.displayTitle
        readerCard.isHidden = false
        gridScroll.isHidden = true
        // F-03: the saved text first, when there is some. The page itself
        // loads only when Original is asked for.
        let article = articles.store.article(id: id)
        if article == nil { articles.enqueue(link) }
        let readsOriginal = article == nil && !articles.isWorking
        showingOriginal = readsOriginal
        setShowingOriginal(readsOriginal)
        // R2-SEC-01: WebKit fetches from its own process, where the network
        // gate's URLProtocol cannot see, so a test or tour asks first.
        if readsOriginal, NetworkGate.allowsOutOfProcessLoad(url) {
            readerWebView.load(URLRequest(url: url))
        }
        if !link.isRead {
            store.setRead(id: id, read: true)
            refreshCard(id: id)
            rebuildSidebar()
            onDrillSubtitleChanged?()
        }
        applyTheme()
    }

    @objc private func closeReaderTapped() {
        readingID = nil
        readerCard.isHidden = true
        gridScroll.isHidden = false
        // Stop the page rather than leaving it running behind a hidden view -
        // GL-13's rule: background work stops when nobody can see it.
        readerWebView.load(URLRequest(url: URL(string: "about:blank")!))
        rebuildGrid()
    }

    @objc private func readerBackTapped() { readerWebView.goBack() }
    @objc private func readerReloadTapped() { readerWebView.reload() }

    @objc private func readerOpenExternallyTapped() {
        guard let id = readingID, let link = store.link(id: id), let url = URL(string: link.url) else { return }
        WebNavigationPolicy.openExternally(url, from: "the reading-list reader")
    }

    // MARK: Rendering

    private func rebuildSidebar() {
        let links = store.links
        let calendar = Calendar.current
        let now = Date()
        let inbox: [ReadingListFilter] = [.unread, .read, .summarised, .addedToday]
        var counts: [String: Int] = [ReadingListFilter.all.id: links.count]
        for slice in inbox {
            counts[slice.id] = links.filter {
                ReadingListQuery.matches(slice, $0, now: now, calendar: calendar)
            }.count
        }
        counts[ReadingListFilter.highlights.id] = articles.store.highlightCount()
        let tagCounts = ReadingListTags.counts(in: links)
        for entry in tagCounts { counts[ReadingListFilter.tag(entry.tag).id] = entry.count }

        var sections: [HelmPageSidebar.Section] = [
            .init(header: "Inbox", rows: [
                .init(id: ReadingListFilter.all.id, indicator: .symbol("tray.full"), title: "Everything"),
                .init(id: ReadingListFilter.unread.id, indicator: .symbol("book"), title: "Unread"),
                .init(id: ReadingListFilter.read.id, indicator: .symbol("checkmark.circle"), title: "Read"),
                .init(id: ReadingListFilter.summarised.id, indicator: .symbol("sparkles"), title: "Summarised"),
                .init(id: ReadingListFilter.addedToday.id, indicator: .symbol("bolt"), title: "Added today"),
                .init(id: ReadingListFilter.highlights.id, indicator: .symbol("highlighter"), title: "Highlights"),
            ]),
        ]
        if !tagCounts.isEmpty {
            // The mockup's own coloured dot per tag. A `HelmTint` here, not a
            // domain hue: `HelmPageSidebar.RowIndicator.dot` takes a tint, and
            // the rotation below is a stable function of the tag's own text so
            // one tag keeps one colour across launches.
            let palette: [HelmTint] = [.info, .accent, .good, .warn, .violet, .critical]
            sections.append(.init(header: "Tags", rows: tagCounts.map { entry in
                let index = abs(ReadingListTags.stableIndex(of: entry.tag)) % palette.count
                return .init(id: ReadingListFilter.tag(entry.tag).id,
                             indicator: .dot(palette[index]),
                             title: entry.tag)
            }))
        }
        sidebar.setSections(sections)
        sidebar.setCounts(counts)
        sidebar.select(filter.id)
    }

    #if FM_SELFTESTS
    /// How many times the card grid has been rebuilt, for
    /// `PageLoadOffMainSelfTest`'s unchanged-revisit check.
    private(set) var debugGridRebuildCount = 0
    #endif

    /// The grid's rows, keyed (PERF-05).
    ///
    /// **The 2026-10 end-to-end review's PERF-05.** Every store publish and
    /// every filter change used to empty this grid and build one card per
    /// link again. Rows are keyed by what they hold now - the column count
    /// and their links' ids, in order - so a row whose links did not change
    /// keeps its cards and only re-renders them in place, exactly as
    /// `refreshCard` already did for one card. A row whose membership did
    /// change (a link marked read moves below the unread ones, a filter, a
    /// width that changes the column count) is a new row - but it is built
    /// from the cards already on screen where it can, so a reshuffle moves
    /// cards rather than rebuilding them.
    private lazy var gridRows = HelmKeyedRows(stack: gridStack)

    private func rebuildGrid() {
        #if FM_SELFTESTS
        debugGridRebuildCount += 1
        #endif
        let visible = ReadingListQuery.apply(filter, to: store.links)
        lastGridWidth = gridScroll.contentView.bounds.width
        let columns = HelmResponsiveGrid.columns(containerWidth: lastGridWidth,
                                                 minItemWidth: ReadingListCardView.minimumWidth)
        let chunks = visible.chunked(into: columns)
        let onScreen = cards
        var nextCards: [String: ReadingListCardView] = [:]
        gridRows.reconcile(chunks,
                           key: { chunk in "\(columns):" + chunk.map(\.id).joined(separator: ",") },
                           make: { [unowned self] chunk in
                               // One chunk is one row: `rows(_:)` on exactly
                               // the links that fit is the same row, with the
                               // same partial-row padding, it always built.
                               HelmResponsiveGrid.rows(chunk,
                                                       containerWidth: self.lastGridWidth,
                                                       minItemWidth: ReadingListCardView.minimumWidth,
                                                       // PF2's rule: these cards are
                                                       // content-sized (a summary well is
                                                       // three lines taller than none), so
                                                       // each row equalises to its own
                                                       // tallest rather than the grid
                                                       // reading as ragged.
                                                       equalHeights: true) { link, _ in
                                   // A card already on screen moves into
                                   // this row; `update` below re-renders it.
                                   onScreen[link.id] ?? self.makeCard(link)
                               }.first ?? NSStackView()
                           },
                           update: { [unowned self] row, chunk in
                               let rowCards = (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? ReadingListCardView } ?? []
                               for (card, link) in zip(rowCards, chunk) {
                                   card.render(link, iconPNG: self.store.iconPNG(forHost: link.host))
                                   card.setSummarising(self.summariesInFlight.contains(link.id))
                                   nextCards[link.id] = card
                               }
                           })
        cards = nextCards
        // F-03: the Highlights slice shows highlights, not an empty grid.
        let showsHighlights = filter == .highlights
        highlightsList.isHidden = !showsHighlights
        if showsHighlights { rebuildHighlightsList() }
        refreshEmptyState(visibleCount: showsHighlights ? 1 : visible.count)
        applyTheme()
    }

    private func makeCard(_ link: ReadingLink) -> NSView {
        let card = ReadingListCardView(link: link, iconPNG: store.iconPNG(forHost: link.host))
        card.onOpen = { [weak self] id in self?.openReader(id: id) }
        card.onToggleRead = { [weak self] id in self?.toggleRead(id: id) }
        card.onSummarise = { [weak self] id in self?.summarise(id: id) }
        card.onRetryMetadata = { [weak self] id in self?.retryMetadata(id: id) }
        card.onEditTags = { [weak self] id in self?.editTags(id: id) }
        card.onDelete = { [weak self] id in self?.delete(id: id) }
        card.setSummarising(summariesInFlight.contains(link.id))
        cards[link.id] = card
        return card
    }

    /// Re-render one card in place, without rebuilding the grid around it.
    ///
    /// Which matters more than it looks: a metadata fetch landing while the
    /// captain is reading the grid must not move every other card out from
    /// under the pointer.
    private func refreshCard(id: String) {
        guard let card = cards[id], let link = store.link(id: id) else { return }
        card.render(link, iconPNG: store.iconPNG(forHost: link.host))
        card.setSummarising(summariesInFlight.contains(id))
        card.applyTheme(theme)
    }

    private func scrollToCard(id: String) {
        guard let card = cards[id] else { return }
        gridScroll.contentView.scrollToVisible(
            card.convert(card.bounds, to: gridDocument))
    }

    /// GL-14 again, and the reason there are three empty states rather than
    /// one: nothing saved, nothing matching this filter, and a file that could
    /// not be read are three different situations and a captain needs to know
    /// which one they are looking at.
    ///
    /// UXP-12: with nothing listed the empty state is the page's one
    /// instruction. The dashed drop card (and a toolbar hint, until R4-UI-05)
    /// used to say the same thing beside it, so the card stands down until
    /// there is a list for it to sit under. The whole page is a drop
    /// target (`ReadingListDropRootView`) either way.
    ///
    /// UXP-13: placed by `HelmEmptyState.placeAsPageEmptyState`, centred in
    /// the content pane, rather than top-aligned above the drop card.
    private func refreshEmptyState(visibleCount: Int) {
        emptyState?.removeFromSuperview()
        emptyState = nil
        emptyStateTitle = nil
        // UX-13: the paste well is always there, so the list's way in is
        // never a paragraph.
        dropHintCard.isHidden = store.isInFailedLoadState
        guard visibleCount == 0, let contentPane = splitPage?.contentPane else { return }

        let state: HelmEmptyState
        if store.isInFailedLoadState {
            state = HelmEmptyState(
                symbol: "exclamationmark.triangle",
                title: "The reading list could not be read",
                body: "Its file is on disk and has been backed up, but this build could not parse it. "
                    + "Nothing new will be saved until it is fixed.",
                size: .standard,
                hue: .rose)
        } else if store.links.isEmpty {
            // R2-UX-07: the shape every module's empty state takes - the
            // page's own artwork and one example to start from - where this
            // one drew a tile of its own and offered nothing to press.
            let example = HelmButton(title: "Add an example link", variant: .secondary, symbol: "plus")
            example.target = self
            example.action = #selector(addExampleLinkTapped)
            state = HelmEmptyState(
                symbol: "link",
                title: "Nothing saved yet",
                body: "Links you save appear here as soon as they are pasted, with their titles read on this machine.",
                size: .standard,
                accessory: example,
                hue: RailDestination.readingList.domainHue,
                symbolWatermark: true)
        } else {
            state = HelmEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing under \u{201C}\(filter.title)\u{201D}",
                body: "There are \(store.links.count) saved links; none of them match this filter.",
                size: .standard,
                hue: .slate)
        }
        state.placeAsPageEmptyState(in: contentPane)
        state.applyTheme(theme)
        emptyState = state
        emptyStateTitle = emptyStateTitleForCurrentState()
    }

    /// The three empty-state titles, named once. `refreshEmptyState` builds the
    /// view from the same branch, so a suite asserting which state is on screen
    /// is asserting the real decision rather than a second copy of it.
    private func emptyStateTitleForCurrentState() -> String {
        if store.isInFailedLoadState { return "The reading list could not be read" }
        if store.links.isEmpty { return "Nothing saved yet" }
        return "Nothing under \u{201C}\(filter.title)\u{201D}"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // GL-20: a cheap staleness check first, and only then the layout pass.
        // Not a debounce - the grid has to be right by the time this returns,
        // which is the synchronous guarantee the repair exists for.
        let width = gridScroll.contentView.bounds.width
        guard width > 0 else { return }
        let columnsNow = HelmResponsiveGrid.columns(containerWidth: width,
                                                    minItemWidth: ReadingListCardView.minimumWidth)
        let columnsBefore = HelmResponsiveGrid.columns(containerWidth: lastGridWidth,
                                                       minItemWidth: ReadingListCardView.minimumWidth)
        guard columnsNow != columnsBefore else {
            lastGridWidth = width
            return
        }
        rebuildGrid()
    }

    // MARK: Theme

    private func applyTheme() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        readerBar.applyTheme(theme)
        sidebar.applyTheme(theme)
        readerTitle.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        HelmCard.applyCardSurface(to: readerCard, theme: theme)
        dropHintCard.applyTheme(theme)
        emptyState?.applyTheme(theme)
        for card in cards.values { card.applyTheme(theme) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugCards: [ReadingListCardView] {
        // Grid order, not dictionary order - a suite asserting "the first card"
        // has to mean the first one on screen.
        gridStack.arrangedSubviews
            .flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }
            .compactMap { $0 as? ReadingListCardView }
    }
    var debugCard: (String) -> ReadingListCardView? { { [weak self] id in self?.cards[id] } }
    var debugSidebar: HelmPageSidebar { sidebar }
    var debugFilter: ReadingListFilter { filter }
    var debugReaderIsShowing: Bool { !readerCard.isHidden }

    /// S13: the reader's own data store, so a suite can assert the isolation
    /// rather than the source line that sets it.
    var debugReaderDataStore: WKWebsiteDataStore { readerWebView.configuration.websiteDataStore }
    var debugEmptyStateTitle: String? { emptyState == nil ? nil : emptyStateTitle }
    var debugGridDocument: NSView { gridDocument }
    var debugDropHint: ReadingListDropHintView { dropHintCard }
    /// UXP-12: the two places the page gives its paste-or-drop instruction,
    /// as drawn (R4-UI-05 took out the toolbar hint, the third).
    /// UX-13: whether the paste well shows, whether an empty state shows,
    /// and whether that empty state repeats the well's instruction.
    var debugInstructionCopies: (dropCard: Bool, emptyState: Bool) {
        (!dropHintCard.isHidden, emptyState != nil)
    }
    var debugEmptyStateRepeatsTheInstruction: Bool {
        emptyState.map { state in
            func texts(_ view: NSView) -> [String] {
                view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? texts($0) }
            }
            return texts(state).contains { $0.contains("\u{2318}V") || $0.lowercased().contains("drop") }
        } ?? false
    }
    /// R4-UI-05: every subview of the page's root, which no longer holds a
    /// toolbar row of its own.
    var debugRootHoldsAPageToolbar: Bool { view.subviews.contains { $0 is HelmPageToolbar } }
    var debugRefreshButton: HelmButton { refreshButton }
    var debugRoot: NSView { view }
    func debugReload() { reload() }
    func debugSelectFilter(_ filter: ReadingListFilter) {
        self.filter = filter
        rebuildGrid()
        rebuildSidebar()
    }
    /// UI-60: the strip is gone, so a "tab" is a sidebar slice, selected
    /// through the sidebar's own path.
    func debugSelectTab(_ id: String) {
        guard let picked = ReadingListFilter.fromID(id) else { return }
        filter = picked
        sidebar.select(picked.id)
        rebuildGrid()
        rebuildSidebar()
    }
    func debugOpenReader(id: String) { openReader(id: id) }
    func debugCloseReader() { closeReaderTapped() }
    func debugCapture(_ text: String) -> Bool { capture(text, source: "test") }
    func debugRefreshFailedMetadata() { refreshMetadataTapped() }
    func debugApplyTheme(_ theme: HelmTheme) {
        self.theme = theme
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        applyTheme()
    }
    #endif
}

// MARK: - Navigation policy

extension ReadingListController: WKNavigationDelegate {

    /// The reader loads the saved link and whatever that page navigates to on
    /// the same site; anything else goes to the system browser. The rule is
    /// `ReadingListNavigation.decide`, and it applies to the **main frame**
    /// only - see that type for why a sub-frame must not take it.
    ///
    /// Deliberately narrower than Docs', which hosts a browsable local site
    /// and hands *everything* else to `NSWorkspace`. The difference is what
    /// this page is: following an article's own in-page anchors and its site's
    /// own pagination is reading, and following a link off to somewhere else
    /// is a new thing the captain should decide about in a real browser - and
    /// can then paste back here.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let savedHost = readingID.flatMap { store.link(id: $0) }.map { $0.host } ?? ""
        // A nil target frame is a navigation into a frame that does not exist
        // yet (`target="_blank"`), which is a new top-level page rather than
        // an embed - so it takes the strict path.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch ReadingListNavigation.decide(url: url, savedHost: savedHost, isMainFrame: isMainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally:
            decisionHandler(.cancel)
            WebNavigationPolicy.openExternally(url, from: "the reading-list reader")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readerBackButton.isEnabled = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        readerBackButton.isEnabled = webView.canGoBack
        Feedback.report("That page could not be loaded: \(error.localizedDescription)",
                        kind: .failure, persistence: .transient, in: isViewLoaded ? view : nil)
    }
}

// MARK: - The page-wide drop target

/// The destination's root, which accepts a dropped URL anywhere on it - the
/// mockup's "Drop a URL anywhere in the window to add it."
///
/// The four overrides are this app's own drop-zone shape verbatim
/// (`CodePreviewDropView`, `ShiftBoardViews`' columns), with one difference:
/// those accept `.fileURL`, and this accepts a *web* URL plus plain text,
/// because what a browser puts on the dragging pasteboard for a dragged tab or
/// address bar is `public.url` and a string, never a file.
final class ReadingListDropRootView: NSView {
    var onDropText: ((String) -> Void)?

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The dragged URL, or `nil`. The **decision** rather than the side effect,
    /// so a suite can drive the real accept/refuse without a live drag session
    /// - which needs a window server and a mouse this app's agents do not have
    /// (AGENTS.md's "Verifying native UI bugs" convention).
    static func acceptableURL(fromPasteboard pasteboard: NSPasteboard) -> String? {
        // A secret on the *general* pasteboard is not on the dragging one, but
        // the same rule is asked anyway: it costs nothing and it means no
        // reader of pasteboard content in this app skips the check.
        guard !CredentialVaultClipboard.isConcealed(pasteboard) else { return nil }
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: false]) as? [URL],
           let first = objects.first,
           let detected = ReadingListURL.detect(first.absoluteString) {
            return detected
        }
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return ReadingListURL.detect(text)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = Self.acceptableURL(fromPasteboard: sender.draggingPasteboard) != nil
        isHighlighted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = Self.acceptableURL(fromPasteboard: sender.draggingPasteboard) else { return false }
        onDropText?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        let accent = HelmTheme.nsColor(ThemeManager.shared.theme.accentHex)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3),
                                xRadius: HelmMetrics.rCard, yRadius: HelmMetrics.rCard)
        accent.withAlphaComponent(0.06).setFill()
        path.fill()
        accent.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

/// UX-13: the paste well across the top of the page, always there: a link
/// glyph, a field that says "Paste or drop a link here", and Save. It is
/// where a link is pasted, typed or dropped, so an empty list needs no
/// paragraph about three ways to add one. The dashed edge is the app's one
/// signal for "this is a place to put something", and it lights while a
/// link is dragged over it.
final class ReadingListDropHintView: NSView, NSTextFieldDelegate {
    var onDropText: ((String) -> Void)?
    /// Save with the field's text. Returns whether the link was saved, so
    /// the field empties only then.
    var onSave: ((String) -> Bool)?

    static let placeholder = "Paste or drop a link here \u{00B7} \u{2318}V"
    static let height: CGFloat = 60
    static let tileSide: CGFloat = 30
    /// The glyph tile's wash of the accent over the card.
    static let tileWash: CGFloat = 0.14

    private let tile = NSView()
    private let glyph = NSImageView()
    let field = HelmTextField(placeholder: ReadingListDropHintView.placeholder)
    let saveButton = HelmButton(title: "Save", variant: .primary, size: .small)
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
        wantsLayer = true

        tile.wantsLayer = true
        tile.layer?.cornerRadius = HelmMetrics.rChip
        glyph.image = HelmSymbol.image("link", pointSize: 13, weight: .semibold)
        glyph.imageScaling = .scaleNone
        tile.addSubview(glyph)
        field.delegate = self
        field.target = self
        field.action = #selector(saveTapped)
        field.setAccessibilityLabel("Link to save")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.toolTip = "Save the link to the reading list"
        // Gotcha (5): only the field gives way.
        saveButton.setContentHuggingPriority(.required, for: .horizontal)
        saveButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [tile, glyph, field, saveButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [tile, field, saveButton] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s3),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            saveButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: HelmMetrics.s3),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s4),
            saveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func saveTapped() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            window?.makeFirstResponder(field)
            return
        }
        if onSave?(text) == true { field.stringValue = "" }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accent = HelmTheme.nsColor(theme.accentHex)
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let wash = card.blended(withFraction: Self.tileWash, of: accent) ?? card
        tile.layer?.backgroundColor = wash.cgColor
        glyph.contentTintColor = HelmContrast.legibleOn(fill: wash, preferring: accent, target: HelmContrast.nonTextTarget)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let line = isHighlighted ? accent : HelmTheme.nsColor(theme.chromeLineHex)
        let radius = theme.isDaylight ? HelmMetrics.dModule : HelmMetrics.rCard
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: radius, yRadius: radius)
        (isHighlighted ? accent.withAlphaComponent(0.08) : HelmTheme.nsColor(theme.chromeBackgroundHex)).setFill()
        path.fill()
        path.lineWidth = isHighlighted ? 2 : 1
        // Dashed, which is the mockup's own border-style and the app's one
        // signal for "this is a place to put something" rather than a card
        // holding something.
        path.setLineDash([5, 4], count: 2, phase: 0)
        line.withAlphaComponent(isHighlighted ? 0.9 : 0.55).setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = ReadingListDropRootView.acceptableURL(fromPasteboard: sender.draggingPasteboard) != nil
        isHighlighted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = ReadingListDropRootView.acceptableURL(fromPasteboard: sender.draggingPasteboard) else {
            return false
        }
        onDropText?(url)
        return true
    }

    #if FM_SELFTESTS
    var debugLabel: String { field.placeholderAttributedString?.string ?? field.placeholderString ?? "" }
    func debugSave(_ text: String) {
        field.stringValue = text
        saveTapped()
    }
    #endif
}

// R2-UX-04: Paste link is the page's primary verb - the far-right filled
// button in the sidebar layout, not a filled button before the cluster.
extension ReadingListController: WorkspacePrimaryActionProviding {
    var workspacePrimaryAction: NSView? { pasteButton }
}
