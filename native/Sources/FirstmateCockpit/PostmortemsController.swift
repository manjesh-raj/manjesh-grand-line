// Manjesh Grand Line - native macOS app.
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
    private let postmortemEmptyState = HelmEmptyState(
        symbol: "doc.text.magnifyingglass",
        body: "No postmortems yet. Generate one from an SRE Lead investigation and it will appear here.",
        hue: RailDestination.postmortems.domainHue)
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
        reloadPostmortemsList()
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

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            postmortemListScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            postmortemListScroll.heightAnchor.constraint(equalToConstant: 220),
            postmortemDetailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Data

    private func reloadPostmortemsList() {
        let postmortems = runbookStore.listPostmortems()
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
        postmortemDetailTextView.textColor = HelmField.ink(theme)
        postmortemDetailTextView.backgroundColor = HelmField.fill(theme)

        // A `HelmPlateCard` themes itself end to end - see
        // `RunbooksController.applyTheme`'s matching comment.
        for plate in postmortemRowCards { plate.applyTheme(theme) }
    }
}
