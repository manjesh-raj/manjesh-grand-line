// Manjesh Grand Line - native macOS app.
//
// The `.runbooks` rail destination.
//
// Split out of `DocsController.swift` by `fm/grandline-docs-split-runbooks-
// postmortems`, which promoted this tab (and its sibling `.postmortems`) into
// their own top-level destinations in the Stores space, alongside Docs,
// Vault, Tools and Dictation - see `DaylightSpace.swift`'s locked space
// table. Docs itself now shows only the Playbook content it always had.
//
// This is a navigation restructure, not a feature rewrite: every method
// below is the same CRUD/git-sync/UI logic `DocsController` used to run for
// this tab, ported verbatim onto a standalone `NSViewController` that fills
// the whole destination rather than one tab of a shared page. `DocsRunbookStore`
// itself, its git sync, and the on-disk file layout are all untouched.
//
// Root view follows AGENTS.md gotcha #8: a plain `NSView` with
// `wantsLayer`/`HelmTheme` background, not `NSVisualEffectView` vibrancy.

import AppKit

final class RunbooksController: NSViewController, DaylightDrillActions {

    private let runbookStore = DocsRunbookStore()

    /// The page-level primary action, now in the shell's drill header cluster
    /// (§6.4) rather than a page-local toolbar - see `drillHeaderActions`.
    private let newRunbookButton = HelmButton(title: "New Runbook", variant: .primary, symbol: "plus")

    /// Keeps `ClosureSleeve` targets alive for as long as the controls they
    /// are attached to exist - appended once, in `buildRunbookEditor`, for
    /// that editor's three buttons.
    private var rowSleeves: [ClosureSleeve] = []
    /// The plates built by `rebuildRunbookGrid`, kept so `applyTheme()` can
    /// re-tint a plate built between two theme changes. A `HelmPlateCard`
    /// themes itself, so this is not the paint path itself.
    private var runbookRowCards: [HelmPlateCard] = []

    private let runbookListScroll = NSScrollView()
    private let runbookListStack = NSStackView()
    /// `nil` = showing the list. `.some(id)` = editing an existing runbook. A
    /// brand-new (unsaved) runbook is represented separately - see
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
    /// shown (and vice versa). Both are pinned to the same full-bleed anchors,
    /// so without this the two views render on top of each other - see
    /// `fm/grandline-docs-runbook-editor-overlap-fix`'s AGENTS.md note for the
    /// real captain-reported bug this fixed (doubled title text, list content
    /// faintly visible under the editor).
    private let runbookListContainerStack = NSStackView()
    /// Only built while the runbook grid is genuinely empty, so it is
    /// optional rather than a stored instance.
    private var runbookGridEmptyState: HelmEmptyState?
    private var runbookGridItems: [DocGridItem] = []

    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Drill header (Daylight §6.4)

    /// Set by `AppShellController`. Called - never written to the header
    /// directly - whenever this page's own live numbers or action cluster
    /// change: the header belongs to the shell, and two owners of one view is
    /// how they start disagreeing.
    var onDrillSubtitleChanged: (() -> Void)?
    var onDrillActionsChanged: (() -> Void)?

    /// §6.4's action cluster: this page's page-level primary action. Empty
    /// while the runbook editor is open - "New Runbook" beside a form already
    /// creating one reads as a second, competing action.
    var drillHeaderActions: [NSView] {
        runbookEditorContainer.isHidden ? [newRunbookButton] : []
    }

    /// §6.4's live subtitle - the count the grid below is *actually*
    /// rendering, not a fresh directory scan, so the header and the grid
    /// cannot disagree. `viewWillAppear` reloads the list before this is ever
    /// read, so it is never stale.
    var drillHeaderSubtitle: String? {
        let count = runbookGridItems.count
        return count == 0 ? "No runbooks yet" : "\(count) \(count == 1 ? "runbook" : "runbooks")"
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        buildRunbookEditor()
        buildRunbooksContainer(in: root)
        buildRunbooksActions()

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        // Re-flow the grid's column count on window resize, mirroring
        // `ToolsController.containerWidthMayHaveChanged` - the window's own
        // resize notification, not `viewDidLayout()`, since this page is a
        // body child of `AppShellController`, not the window's own
        // contentViewController (the only one AppKit guarantees that hook
        // for).
        NotificationCenter.default.addObserver(self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil)

        // Populated here as well as on every `viewWillAppear` - a destination
        // reached before it is ever interactively shown (a deep link, a
        // programmatic `show(_:)` right after mounting) should still render
        // its real list immediately rather than waiting on an appearance
        // callback that may not fire promptly.
        reloadRunbooksList()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadRunbooksList()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Same reasoning as `ToolsController.viewDidAppear`: the grid's very
        // first build happens before the view has a real width to measure,
        // so refine it against the real width now that the view is actually
        // on screen, rather than waiting for the first resize.
        containerWidthMayHaveChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The real width the grid last laid itself out against -
    /// `containerWidthMayHaveChanged` re-flows the column count whenever it
    /// drifts by more than a point, tracked separately since resizing while
    /// the page isn't visible shouldn't force a rebuild.
    private var lastRunbookGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        if let note, let win = note.object as? NSWindow, win !== view.window { return }
        guard !view.isHidden else { return }
        view.layoutSubtreeIfNeeded()
        let width = runbookListStack.frame.width
        if width > 0, abs(width - lastRunbookGridWidth) > 1 {
            lastRunbookGridWidth = width
            rebuildRunbookGrid()
        }
    }

    private func buildRunbooksActions() {
        newRunbookButton.controlSize = .small
        newRunbookButton.target = self
        newRunbookButton.action = #selector(newRunbookTapped)
        newRunbookButton.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func newRunbookTapped() { beginNewRunbook() }

    private func notifyDrillChanged() {
        onDrillActionsChanged?()
        onDrillSubtitleChanged?()
    }

    // MARK: Layout

    private func buildRunbooksContainer(in root: NSView) {
        runbookListStack.orientation = .vertical
        runbookListStack.alignment = .leading
        runbookListStack.spacing = DocsGridSupport.cardSpacing
        runbookListStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView()` - see AppKit gotcha (9): a
        // non-flipped document view puts y=0 at the *bottom*, so content
        // shorter than the viewport (the common case here) rests against the
        // bottom of the scroll area instead of the top, leaving a large empty
        // gap above the rows.
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
        // `==`, not `>=` - the grid's cards are sized responsively to
        // whatever width is actually available, so there's no fixed-width
        // card that could need the document view to grow past the viewport.
        listContent.widthAnchor.constraint(equalTo: runbookListScroll.contentView.widthAnchor).isActive = true

        let listStack = runbookListContainerStack
        listStack.setViews([runbookListScroll], in: .leading)
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        // `runbookEditorContainer` is a bare `NSView()` that never had this
        // set - see AGENTS.md's "AppKit gotchas" entry (3)/(11) for the full
        // mechanism: left at its default `true`, AppKit also synthesizes
        // required constraints pinning the view to its zero-size initial
        // frame, which fight the explicit fill constraints below the moment
        // the window tries to grow.
        runbookEditorContainer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(listStack)
        root.addSubview(runbookEditorContainer)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            listStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            listStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            listStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            runbookListScroll.widthAnchor.constraint(equalTo: listStack.widthAnchor),

            runbookEditorContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            runbookEditorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            runbookEditorContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            runbookEditorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
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
        // §6.9: the well *is* the input surface, so the scroll view carries
        // the fill/border/radius and the text view inside paints nothing of
        // its own beyond matching that fill (`applyTheme`).
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

    // MARK: Data

    private func reloadRunbooksList() {
        let runbooks = runbookStore.listRunbooks()
        runbookGridItems = runbooks.map { runbook in
            // The card's own metadata line - "Kubernetes \u{00B7} 3 steps" -
            // read out of the runbook's own fenced steps
            // (`DocsRunbookMetadata`). "Updated N ago" is the fallback for a
            // document with no steps yet, and stays on the card's tooltip
            // either way so the timestamp is never lost.
            let updated = "Updated \(DocsGridSupport.relativeDate(runbook.modifiedAt))"
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
    /// to whatever width `runbookListStack` actually has.
    private func rebuildRunbookGrid() {
        runbookListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runbookRowCards.removeAll()
        if runbookGridItems.isEmpty {
            let empty = HelmEmptyState(symbol: "list.bullet.rectangle",
                                       body: "No runbooks yet. Create one to get started.",
                                       hue: RailDestination.runbooks.domainHue)
            empty.heightAnchor.constraint(equalToConstant: 110).isActive = true
            runbookGridEmptyState = empty
            runbookListStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
            applyTheme()
            return
        }
        runbookGridEmptyState = nil
        let (rows, cards) = DocsGridSupport.layoutGrid(items: runbookGridItems, containerWidth: runbookListStack.frame.width)
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
        notifyDrillChanged()
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
        notifyDrillChanged()
    }

    private func cancelRunbookEditor() {
        runbookEditorContainer.isHidden = true
        runbookListContainerStack.isHidden = false
        notifyDrillChanged()
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
        notifyDrillChanged()
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
            notifyDrillChanged()
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

    /// Entry point for the unified `⌘K` search palette (`UnifiedSearchController`,
    /// owned outside this page) and for Log Analyzer's "Create Runbook"
    /// action - the one "open this runbook" behavior everywhere in the app.
    func openRunbook(id: String) {
        beginEditRunbook(id)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRunbookPlates: [HelmPlateCard] { runbookRowCards }
    var debugRunbookEditorIsOpen: Bool { !runbookEditorContainer.isHidden }
    func debugBeginNewRunbook() { beginNewRunbook() }
    func debugCancelRunbookEditor() { cancelRunbookEditor() }
    func debugReloadRunbooks() { reloadRunbooksList() }
    #endif

    // MARK: Theme

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)

        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        runbookEditorTitleLabel.textColor = ink
        // The editor reads as a §6.9 well: the scroll view owns the fill and
        // border, and the text view matches that fill rather than the card
        // surface (which under Daylight is white and would show the well's
        // own border wrapping a differently-coloured interior).
        HelmField.applySunken(to: runbookBodyScroll, theme: theme)
        runbookBodyTextView.textColor = HelmField.ink(theme)
        runbookBodyTextView.backgroundColor = HelmField.fill(theme)
        runbookGridEmptyState?.applyTheme(theme)

        // A `HelmPlateCard` themes itself end to end - fill, border, ribbon,
        // shadow, both labels and (via `HelmGradientTile`'s own observation)
        // its tile. This call is only here to keep a plate built *between*
        // two theme changes correct on the very next render.
        for plate in runbookRowCards { plate.applyTheme(theme) }
    }
}

/// Retains a closure so it can be used as an `NSButton` target/action without
/// needing a dedicated `@objc` method per row - callers keep the sleeve alive
/// (e.g. `RunbooksController.rowSleeves`) for as long as the control it's
/// attached to exists.
final class ClosureSleeve: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}
