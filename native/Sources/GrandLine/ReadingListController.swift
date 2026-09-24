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
//   - a segmented All / Unread / Summarised strip over the grid, with the
//     "drop a URL anywhere in the window" hint beside it;
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

final class ReadingListController: NSViewController, DaylightDrillActions {

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

    private var filter: ReadingListFilter = .all
    /// The segmented strip and the sidebar are two views of one question, so
    /// the sidebar's slices and the strip's tabs both write `filter` - and
    /// whichever did not fire is re-synced afterwards, so the page never shows
    /// two different answers at once.
    private var tabFilter: ReadingListFilter = .all

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

    private let toolbar = HelmPageToolbar()
    private let tabs = HelmSegmentedTabs(items: ReadingListFilter.tabs.map {
        HelmSegmentedTabs.Item(id: $0.id, title: $0.title)
    }, size: .compact)
    private let statusLabel = NSTextField(labelWithString: "")

    private let sidebar = HelmPageSidebar(surface: .panel, countStyle: .badge)

    private let gridScroll = NSScrollView()
    private let gridDocument = FlippedView()
    private let gridStack = NSStackView()
    private let hintLabel = NSTextField(labelWithString: "Drop a URL anywhere in the window to add it.")
    private let dropHintCard = ReadingListDropHintView()
    private var emptyState: HelmEmptyState?
    /// The title the current empty state is showing, kept beside it so a suite
    /// can assert *which* of the three states is on screen - `HelmEmptyState`
    /// exposes no title of its own.
    private var emptyStateTitle: String?
    private let emptyStateHost = NSView()

    private let readerCard = NSView()
    private var readerWebView: WKWebView!
    private let readerBar = HelmPageToolbar()
    private let readerTitle = NSTextField(labelWithString: "")
    private var readerBackButton: HelmButton!
    private var readerReloadButton: HelmButton!
    private var readerOpenButton: HelmButton!
    private var readerCloseButton: HelmButton!

    private let pasteButton = HelmButton(title: "Paste link", variant: .primary, symbol: "plus")

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

    var drillHeaderActions: [NSView] { [pasteButton] }

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        // GL-14: a list nobody has read off disk yet is not an empty list, and
        // neither of them is "0 saved".
        guard hasLoaded else { return "Opening the reading list\u{2026}" }
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

        buildToolbar(in: root)
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
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.tagPopover }

        store.gitSync?.observeStatus { [weak self] status in
            guard let self else { return }
            self.syncStatus = status
            self.refreshStatusLine()
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
        reload()
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    /// Called by the app delegate on quit, so the last read-marks before ⌘Q are
    /// committed like every other edit.
    func shutdown() {
        store.gitSync?.flushForTerminationNow()
    }

    // MARK: Building

    private func buildToolbar(in root: NSView) {
        root.addSubview(toolbar)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.onSelect = { [weak self] id in
            guard let self, let picked = ReadingListFilter.fromID(id) else { return }
            self.tabFilter = picked
            self.filter = picked
            // The sidebar and the strip are two views of one question. Picking
            // a tab clears the sidebar's own slice rather than leaving a row
            // highlighted that no longer describes the grid.
            self.sidebar.select(picked.id)
            self.rebuildGrid()
            self.rebuildSidebar()
        }

        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.font = HelmType.captionSmall()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toolbar.setLeading(HelmPageToolbar.group([tabs, statusLabel]))
        toolbar.setTrailing(HelmPageToolbar.group([
            hintLabel,
            HelmPageToolbar.iconButton(symbol: "doc.on.clipboard",
                                       tooltip: "Save the link on the clipboard (\u{2318}V)",
                                       target: self, action: #selector(pasteTapped)),
            HelmPageToolbar.iconButton(symbol: "arrow.clockwise",
                                       tooltip: "Re-read titles for everything still waiting",
                                       target: self, action: #selector(refreshMetadataTapped)),
        ]))

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
        ])
    }

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
            // A sidebar slice that is not one of the strip's three leaves the
            // strip on All rather than lighting a tab that is not what the grid
            // is showing.
            self.tabFilter = ReadingListFilter.tabs.contains(picked) ? picked : .all
            self.tabs.select(self.tabFilter.id)
            self.rebuildGrid()
        }
        root.addSubview(sidebar)

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
        root.addSubview(gridScroll)

        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = HelmResponsiveGrid.spacing
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridDocument.addSubview(gridStack)

        emptyStateHost.translatesAutoresizingMaskIntoConstraints = false
        gridDocument.addSubview(emptyStateHost)

        dropHintCard.translatesAutoresizingMaskIntoConstraints = false
        dropHintCard.onDropText = { [weak self] text in self?.capture(text, source: "drop") }
        dropHintCard.onClick = { [weak self] in self?.pasteTapped() }
        gridDocument.addSubview(dropHintCard)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.gutter),
            sidebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: Self.gutter),
            // Gotcha (16): the column's own height is tied to the page rather
            // than left to a low-priority content preference - a container
            // whose height nothing ties lets its content escape it, and that
            // shipped once as a panel drawn over the app's top bar.
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.gutter),

            gridScroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: Self.gutter),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.gutter),
            gridScroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            // Gotcha (4): the document pins to the **clip** view, never the
            // scroll view - a non-overlay scroller reserves a real ~15pt track
            // that narrows the clip view without narrowing `gridScroll`.
            gridDocument.widthAnchor.constraint(equalTo: gridScroll.contentView.widthAnchor),

            gridStack.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor),
            gridStack.topAnchor.constraint(equalTo: gridDocument.topAnchor),

            emptyStateHost.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor),
            emptyStateHost.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor),
            emptyStateHost.topAnchor.constraint(equalTo: gridStack.bottomAnchor),

            dropHintCard.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor),
            dropHintCard.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor),
            dropHintCard.topAnchor.constraint(equalTo: emptyStateHost.bottomAnchor,
                                              constant: HelmResponsiveGrid.spacing),
            dropHintCard.bottomAnchor.constraint(equalTo: gridDocument.bottomAnchor,
                                                 constant: -Self.gutter),
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
        readerCloseButton = HelmPageToolbar.iconButton(symbol: "xmark",
                                                       tooltip: "Back to the reading list",
                                                       target: self, action: #selector(closeReaderTapped))

        readerBar.setLeading(HelmPageToolbar.group([readerCloseButton, readerTitle]))
        readerBar.setTrailing(HelmPageToolbar.group([readerBackButton, readerReloadButton, readerOpenButton]))

        readerCard.addSubview(readerBar)
        readerCard.addSubview(readerWebView)
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
        ])
    }

    // MARK: Loading

    private func reload() {
        store.reloadAll()
        hasLoaded = true
        lastError = store.isInFailedLoadState
            ? "The reading list file could not be read - nothing new will be written until it is fixed."
            : nil
        rebuildSidebar()
        rebuildGrid()
        refreshStatusLine()
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

    /// The File menu's "New Link" and the drill header's Paste button.
    func newLinkFromMenu() { pasteTapped() }

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
        readerWebView.load(URLRequest(url: url))
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
        NSWorkspace.shared.open(url)
    }

    // MARK: Rendering

    private func rebuildSidebar() {
        let links = store.links
        let calendar = Calendar.current
        let now = Date()
        let inbox: [ReadingListFilter] = [.unread, .read, .addedToday]
        var counts: [String: Int] = [ReadingListFilter.all.id: links.count]
        for slice in inbox {
            counts[slice.id] = links.filter {
                ReadingListQuery.matches(slice, $0, now: now, calendar: calendar)
            }.count
        }
        let tagCounts = ReadingListTags.counts(in: links)
        for entry in tagCounts { counts[ReadingListFilter.tag(entry.tag).id] = entry.count }

        var sections: [HelmPageSidebar.Section] = [
            .init(header: "Inbox", rows: [
                .init(id: ReadingListFilter.all.id, indicator: .symbol("tray.full"), title: "Everything"),
                .init(id: ReadingListFilter.unread.id, indicator: .symbol("book"), title: "Unread"),
                .init(id: ReadingListFilter.read.id, indicator: .symbol("checkmark.circle"), title: "Read"),
                .init(id: ReadingListFilter.addedToday.id, indicator: .symbol("bolt"), title: "Added today"),
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

    private func rebuildGrid() {
        for row in gridStack.arrangedSubviews {
            gridStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        cards.removeAll()

        let visible = ReadingListQuery.apply(filter, to: store.links)
        lastGridWidth = gridScroll.contentView.bounds.width
        let rows = HelmResponsiveGrid.rows(visible,
                                           containerWidth: lastGridWidth,
                                           minItemWidth: ReadingListCardView.minimumWidth,
                                           // PF2's rule: these cards are
                                           // content-sized (a summary well is
                                           // three lines taller than none), so
                                           // each row equalises to its own
                                           // tallest rather than the grid
                                           // reading as ragged.
                                           equalHeights: true) { link, _ in
            self.makeCard(link)
        }
        for row in rows {
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
        }
        refreshEmptyState(visibleCount: visible.count)
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
    private func refreshEmptyState(visibleCount: Int) {
        emptyState?.removeFromSuperview()
        emptyState = nil
        emptyStateTitle = nil
        guard visibleCount == 0 else { return }

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
            state = HelmEmptyState(
                symbol: "link",
                title: "Nothing saved yet",
                body: "Paste a URL here, drop one from any browser, or press \u{2318}6 in the "
                    + "\u{2325}Space capture panel. Titles are read on this machine.",
                size: .standard,
                hue: RailDestination.readingList.domainHue)
        } else {
            state = HelmEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing under \u{201C}\(filter.title)\u{201D}",
                body: "There are \(store.links.count) saved links; none of them match this filter.",
                size: .standard,
                hue: .slate)
        }
        state.translatesAutoresizingMaskIntoConstraints = false
        emptyStateHost.addSubview(state)
        NSLayoutConstraint.activate([
            state.leadingAnchor.constraint(equalTo: emptyStateHost.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: emptyStateHost.trailingAnchor),
            state.topAnchor.constraint(equalTo: emptyStateHost.topAnchor, constant: HelmMetrics.s5),
            state.bottomAnchor.constraint(equalTo: emptyStateHost.bottomAnchor, constant: -HelmMetrics.s5),
        ])
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

    private func refreshStatusLine() {
        guard isViewLoaded else { return }
        statusLabel.stringValue = hasLoaded ? syncSummary : "opening\u{2026}"
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
        toolbar.applyTheme(theme)
        readerBar.applyTheme(theme)
        tabs.applyTheme(theme)
        sidebar.applyTheme(theme)
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
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
    var debugEmptyStateTitle: String? { emptyState == nil ? nil : emptyStateTitle }
    var debugGridDocument: NSView { gridDocument }
    var debugDropHint: ReadingListDropHintView { dropHintCard }
    var debugRoot: NSView { view }
    func debugReload() { reload() }
    func debugSelectFilter(_ filter: ReadingListFilter) {
        self.filter = filter
        rebuildGrid()
        rebuildSidebar()
    }
    func debugSelectTab(_ id: String) {
        tabs.select(id)
        guard let picked = ReadingListFilter.fromID(id) else { return }
        tabFilter = picked
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
    /// the same site; anything else goes to the system browser.
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
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            // A `file:` or a custom-scheme redirect from a remote page is not
            // something a reading list should follow at all - not to the web
            // view, and not to the system browser either.
            decisionHandler(.cancel)
            return
        }
        let savedHost = readingID.flatMap { store.link(id: $0) }.map { $0.host } ?? ""
        let targetHost = ReadingListURL.host(of: url.absoluteString)
        if !savedHost.isEmpty, targetHost == savedHost {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
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

/// The mockup's dashed card under the grid: "\u{2318}V here, or drop a link from
/// any browser."
final class ReadingListDropHintView: NSView {
    var onDropText: ((String) -> Void)?
    var onClick: (() -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString:
        "\u{2318}V here, or drop a link from any browser.")
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
        wantsLayer = true

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        glyph.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.caption()
        label.alignment = .center
        addSubview(glyph)
        addSubview(label)

        setAccessibilityRole(.button)
        setAccessibilityLabel("Save the link on the clipboard to the reading list")
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s4),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: HelmMetrics.s3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s3),
            label.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: HelmMetrics.s1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        label.textColor = muted
        glyph.contentTintColor = muted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let line = isHighlighted ? accent : HelmTheme.nsColor(theme.chromeLineHex)
        let radius = theme.isDaylight ? HelmMetrics.dModule : HelmMetrics.rCard
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: radius, yRadius: radius)
        if isHighlighted {
            accent.withAlphaComponent(0.08).setFill()
            path.fill()
        }
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
    var debugLabel: String { label.stringValue }
    var debugLabelColor: NSColor? { label.textColor }
    #endif
}
