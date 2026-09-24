// Grand Line - native macOS app.
//
// The `.postmortems` rail destination.
//
// Split out of `DocsController.swift` by `fm/grandline-docs-split-runbooks-
// postmortems`, which promoted this tab (and its sibling `.runbooks`) into
// their own top-level destinations in the Stores space, alongside Docs,
// Vault, Tools and Dictation - see `DaylightSpace.swift`'s locked space
// table. Docs itself now shows only the Playbook content it always had.
//
// This is a navigation restructure, not a feature rewrite: every method
// below is the same list/display logic `DocsController` used to run for this
// tab, ported verbatim onto a standalone `NSViewController` that fills the
// whole destination rather than one tab of a shared page. Postmortems are
// still list/display only here - generation lives in SRE Lead
// (`ConsoleController+SRELead.swift`) and the Log Analyzer
// (`LogAnalyzerController.createIncident`), both of which write straight
// into `DocsRunbookStore` and are untouched by this split.
//
// Root view follows AGENTS.md gotcha #8: a plain `NSView` with
// `wantsLayer`/`HelmTheme` background, not `NSVisualEffectView` vibrancy.

import AppKit

final class PostmortemsController: NSViewController, DaylightDrillActions {

    private let runbookStore = DocsRunbookStore()

    /// The plates built by `rebuildPostmortemGrid`, kept so `applyTheme()`
    /// can re-tint a plate built between two theme changes.
    private var postmortemRowCards: [HelmPlateCard] = []

    private let postmortemListScroll = NSScrollView()
    private let postmortemListStack = NSStackView()
    private let postmortemDetailScroll = NSScrollView()
    private let postmortemDetailTextView = NSTextView()
    /// Review #3's UI12: the empty state was a single sentence with nothing to
    /// press - it named the two places a postmortem comes from and then left
    /// the captain to find them. It carries the app's established
    /// call-to-action shape now (`HelmEmptyState`'s `accessory` slot, the same
    /// one Docs' "Sync Now" and Kubernetes' "Open Hosts" use), and
    /// `.standard` rather than the default `.compact` because a state with an
    /// action is a wall the page is showing on purpose, not a note in a cell.
    ///
    /// The Log Analyzer is the button rather than SRE Lead because it is a
    /// real `RailDestination` this page can navigate to in one call, and its
    /// "Create RCA" mode writes into the same `DocsRunbookStore` this list
    /// reads. SRE Lead lives inside a Console tab and has no destination of
    /// its own, so it stays named in the copy where it is accurate.
    private lazy var postmortemEmptyState = HelmEmptyState(
        symbol: "doc.text.magnifyingglass",
        title: "No postmortems yet",
        body: "Postmortems are written for you from an SRE Lead investigation, or from the Log Analyzer's own \u{201C}Create RCA\u{201D} mode. Whichever writes one, it appears here.",
        size: .standard,
        accessory: {
            let button = HelmButton(title: "Open Log Analyzer", variant: .secondary)
            button.target = self
            button.action = #selector(openLogAnalyzerTapped)
            button.toolTip = "Analyze captured output and turn it into an RCA."
            return button
        }(),
        hue: RailDestination.postmortems.domainHue,
        // D4: this is the whole content area of a full-width page - the "big
        // pages open onto beige silence" case that watermark exists for.
        artwork: RailDestination.postmortems.drillHeaderArtwork)

    /// Where this page hands a destination change up, exactly the shape
    /// `FleetController` and `SchedulesController` already use.
    var onNavigateToDestination: ((RailDestination) -> Void)?

    @objc private func openLogAnalyzerTapped() { onNavigateToDestination?(.logAnalyzer) }
    private var selectedPostmortemID: String?
    private var postmortemGridItems: [DocGridItem] = []

    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?
    var onDrillActionsChanged: (() -> Void)?

    /// Postmortems has no page-level action (generation happens in SRE Lead
    /// or the Log Analyzer), so it answers empty rather than being given an
    /// invented one.
    var drillHeaderActions: [NSView] { [] }

    var drillHeaderSubtitle: String? {
        let count = postmortemGridItems.count
        return count == 0 ? "No postmortems yet" : "\(count) \(count == 1 ? "postmortem" : "postmortems")"
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        buildPostmortemsContainer(in: root)

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        // Re-flow the grid's column count on window resize - see
        // `RunbooksController.containerWidthMayHaveChanged`'s own doc comment
        // for why this is the window's own resize notification rather than
        // `viewDidLayout()`.
        NotificationCenter.default.addObserver(self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil)

        // See `RunbooksController.loadView`'s matching comment - populated
        // here too, not only on `viewWillAppear`.
        reloadPostmortemsList()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadPostmortemsListAsync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        containerWidthMayHaveChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var lastPostmortemGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        if let note, let win = note.object as? NSWindow, win !== view.window { return }
        guard !view.isHidden else { return }
        view.layoutSubtreeIfNeeded()
        let width = postmortemListStack.frame.width
        if width > 0, abs(width - lastPostmortemGridWidth) > 1 {
            lastPostmortemGridWidth = width
            rebuildPostmortemGrid()
        }
    }

    // MARK: Layout

    private func buildPostmortemsContainer(in root: NSView) {
        postmortemListStack.orientation = .vertical
        postmortemListStack.alignment = .leading
        postmortemListStack.spacing = DocsGridSupport.cardSpacing
        postmortemListStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView()` - same top-anchoring fix as
        // Runbooks' own list (AppKit gotcha (9) in AGENTS.md).
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
        // `==`, not `>=` - see the matching comment on Runbooks' own
        // document-view width constraint.
        listContent.widthAnchor.constraint(equalTo: postmortemListScroll.contentView.widthAnchor).isActive = true

        // UI12: `.standard` with an action button is taller than the 110pt the
        // one-line `.compact` state fitted in. A floor rather than a fixed
        // height, so the copy and the button decide the rest - a fixed height
        // is what clips a wrapped body at a narrower window.
        postmortemEmptyState.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true


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

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            // The state is centred copy, so it needs the page's width to
            // centre *in*; in a `.leading`-aligned stack it would otherwise
            // sit at its natural width hard against the gutter. A width tie
            // rather than a hugging priority, because `HelmEmptyState` has no
            // intrinsic content size and a content-priority API is a no-op on
            // a view that does not (AGENTS.md gotcha (12)).
            postmortemEmptyState.widthAnchor.constraint(equalTo: stack.widthAnchor),
            postmortemListScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            postmortemListScroll.heightAnchor.constraint(equalToConstant: 220),
            postmortemDetailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Data

    /// M4: the per-visit reload, off the main thread - see
    /// `RunbooksController.reloadRunbooksListAsync` for the full reasoning
    /// (`listPostmortems()` reads the whole content of every markdown file,
    /// and this ran synchronously on main on every navigation).
    private var reloadGeneration = 0

    private func reloadPostmortemsListAsync() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let store = runbookStore
        DispatchQueue.global(qos: .userInitiated).async {
            let postmortems = store.listPostmortems()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.applyPostmortems(postmortems)
            }
        }
    }

    private func reloadPostmortemsList() {
        reloadGeneration &+= 1
        applyPostmortems(runbookStore.listPostmortems())
    }

    private func applyPostmortems(_ postmortems: [DocsRunbook]) {
        postmortemEmptyState.isHidden = !postmortems.isEmpty
        postmortemListScroll.isHidden = postmortems.isEmpty
        postmortemGridItems = postmortems.map { postmortem in
            // A postmortem's own `## Root Cause` section is what its card
            // says; the timestamp falls back in when the document has no
            // root cause written yet.
            let updated = "Updated \(DocsGridSupport.relativeDate(postmortem.modifiedAt))"
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

    /// Re-flows `postmortemGridItems` - see `RunbooksController.rebuildRunbookGrid`'s
    /// doc comment, which this mirrors exactly.
    private func rebuildPostmortemGrid() {
        postmortemListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        postmortemRowCards.removeAll()
        guard !postmortemGridItems.isEmpty else { return }
        let (rows, cards) = DocsGridSupport.layoutGrid(items: postmortemGridItems, containerWidth: postmortemListStack.frame.width)
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

    /// Entry point for the unified `⌘K` search palette (`UnifiedSearchController`,
    /// owned outside this page) and for the Log Analyzer's/SRE Lead's
    /// "Generate Postmortem" actions - the one "open this postmortem"
    /// behavior everywhere in the app.
    func openPostmortem(id: String) {
        showPostmortem(id)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugPostmortemPlates: [HelmPlateCard] { postmortemRowCards }
    func debugReloadPostmortems() { reloadPostmortemsList() }
    #endif

    // MARK: Theme

    private func applyTheme() {
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        postmortemEmptyState.applyTheme(theme)
        HelmField.applySunken(to: postmortemDetailScroll, theme: theme)
        HelmSelection.apply(to: postmortemDetailTextView, theme: theme)
        postmortemDetailTextView.textColor = HelmField.ink(theme)
        postmortemDetailTextView.backgroundColor = HelmField.fill(theme)

        // A `HelmPlateCard` themes itself end to end - see
        // `RunbooksController.applyTheme`'s matching comment.
        for plate in postmortemRowCards { plate.applyTheme(theme) }
    }
}
