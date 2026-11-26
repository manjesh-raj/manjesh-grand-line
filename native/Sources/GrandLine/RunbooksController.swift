// Grand Line - native macOS app.
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

    private let runbookStore: DocsRunbookStore

    /// PERF-02: the shell hands down its one `DocsRunbookStore` rather than
    /// this page building a second (whose `init` used to start another git
    /// sync at launch). The default keeps a page built on its own working.
    init(runbookStore: DocsRunbookStore = DocsRunbookStore()) {
        self.runbookStore = runbookStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
    /// UX-17: the list's rows, one per runbook.
    private var runbookRows: [RunbookRowView] = []
    /// UX-17: the chosen runbook, on the right.
    private let detailView = RunbookDetailView()
    private var runbooks: [DocsRunbook] = []
    private(set) var selectedRunbookID: String?
    /// The run in progress, if any. One at a time.
    private(set) var session: RunbookSession?
    private var sessionTimer: Timer?
    /// The list column's width.
    static let listWidth: CGFloat = 300
    /// Keeps the rows' menu targets alive.
    private var menuSleeves: [ClosureSleeve] = []
    /// Sends a step's command to the Console, wired by the workspace.
    var onSendCommand: ((String) -> Void)?

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
        // R5-UX-10: the empty state's New Runbook, kept for the first few.
        return count == 0 ? "No runbooks yet"
            : QuietHint.line("\(count) \(count == 1 ? "runbook" : "runbooks")", count: count,
                             hint: "\u{2318}N adds another")
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
        reloadRunbooksListAsync()
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

    /// UX4: the File menu's contextual ⌘N on this page.
    func newRunbookFromMenu() { beginNewRunbook() }

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

        // UX-17: the list on the left, the chosen runbook on the right.
        let browser = NSStackView(views: [runbookListScroll, detailView])
        browser.orientation = .horizontal
        browser.alignment = .top
        browser.distribution = .fill
        browser.spacing = HelmMetrics.s4
        browser.translatesAutoresizingMaskIntoConstraints = false
        runbookListScroll.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true
        runbookListScroll.heightAnchor.constraint(equalTo: browser.heightAnchor).isActive = true
        detailView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The card is as tall as its steps: a pull toward no height at all
        // just above the stack's own 250 pull toward its foot, and well under
        // gotcha (13)'s 500.
        let hug = detailView.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(260)
        hug.isActive = true
        detailView.onRun = { [weak self] in self?.startRun() }
        detailView.onStop = { [weak self] in self?.endRun() }
        detailView.onTick = { [weak self] in self?.tickStep() }
        detailView.onEdit = { [weak self] in
            guard let self, let id = self.selectedRunbookID else { return }
            self.beginEditRunbook(id)
        }
        detailView.onSendCommand = { [weak self] command in self?.sendStepCommand(command) }

        let listStack = runbookListContainerStack
        listStack.setViews([browser], in: .leading)
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
        // S03: the page frame's gutter and first-content line.
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter),
            listStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.pageGutter),
            HelmPageScaffold.pinFirstContent(listStack, in: root),
            listStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            browser.widthAnchor.constraint(equalTo: listStack.widthAnchor),
            browser.heightAnchor.constraint(equalTo: listStack.heightAnchor),

            runbookEditorContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter),
            runbookEditorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.pageGutter),
            HelmPageScaffold.pinFirstContent(runbookEditorContainer, in: root),
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

    /// M4: the per-visit reload, off the main thread.
    ///
    /// `listRunbooks()` reads the *whole content* of every markdown file plus
    /// its attributes, and the visit path ran that synchronously on main on
    /// every navigation - linear in total markdown bytes, per visit.
    /// `ShiftController` got `reloadAllAsync` for exactly this shape; these
    /// pages didn't. `loadView` keeps the synchronous call so a destination
    /// reached before it is ever interactively shown still renders real
    /// content immediately.
    ///
    /// The generation guard is M2's: an edit (create/save/delete) that lands
    /// while a visit reload is reading must not be reverted by the older
    /// snapshot, and two overlapping reloads must not apply out of order.
    private var reloadGeneration = 0

    private func reloadRunbooksListAsync() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let store = runbookStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let runbooks = store.listRunbooks()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.applyRunbooks(runbooks)
            }
        }
    }

    private func reloadRunbooksList() {
        reloadGeneration &+= 1
        applyRunbooks(runbookStore.listRunbooks())
    }

    private func applyRunbooks(_ runbooks: [DocsRunbook]) {
        self.runbooks = runbooks
        // `runbookGridItems` still counts what the list shows, for the
        // header's subtitle.
        runbookGridItems = runbooks.map { runbook in
            DocGridItem(title: runbook.title, subtitle: "", tooltip: runbook.title, icon: "doc.text", tint: .info,
                        onOpen: {}, onDelete: {}, onDuplicate: {})
        }
        if selectedRunbookID.flatMap({ id in runbooks.first { $0.id == id } }) == nil {
            selectedRunbookID = runbooks.first?.id
        }
        rebuildRunbookGrid()
        onDrillSubtitleChanged?()
    }

    /// UX-17: the list's rows and the chosen runbook's detail.
    private func rebuildRunbookGrid() {
        runbookListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runbookRows.removeAll()
        menuSleeves.removeAll()
        if runbooks.isEmpty {
            // **UX issue X5.** This page opened on one sentence and nothing
            // to press. The seeded example is opt-in rather than shipped
            // (see `SeedExamples`' header for why a runbook is not the
            // Command Library), and it sits beside the page's own "New
            // Runbook" rather than replacing it.
            let seed = HelmButton(title: "Add an example runbook", variant: .secondary,
                                  target: self, action: #selector(seedExampleRunbookTapped))
            seed.controlSize = .small
            seed.toolTip = "Writes one short example runbook you can edit or delete."
            let empty = HelmEmptyState(symbol: "list.bullet.rectangle",
                                       title: "No runbooks yet",
                                       body: "Create one with New Runbook, or start from an example.",
                                       size: .standard,
                                       accessory: seed,
                                       hue: RailDestination.runbooks.domainHue,
                                       artwork: RailDestination.runbooks.drillHeaderArtwork)
            runbookGridEmptyState?.removeFromSuperview()
            runbookGridEmptyState = empty
            runbookListContainerStack.addSubview(empty)
            empty.placeAsPageEmptyState(in: runbookListContainerStack)
            runbookListScroll.isHidden = true
            detailView.isHidden = true
            applyTheme()
            return
        }
        runbookGridEmptyState?.removeFromSuperview()
        runbookGridEmptyState = nil
        runbookListScroll.isHidden = false
        detailView.isHidden = false
        let runs = RunbookRunLog.all()
        let now = Date()
        for runbook in runbooks {
            let row = RunbookRowView(runbookID: runbook.id, target: self, action: #selector(rowClicked(_:)))
            row.configure(title: runbook.title,
                          subtitle: RunbookWords.rowSubtitle(steps: RunbookSteps.parse(runbook.content).count,
                                                             last: runs[runbook.id], now: now),
                          width: Self.listWidth, theme: theme)
            row.isSelected = runbook.id == selectedRunbookID
            row.menu = rowMenu(for: runbook)
            runbookListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
            runbookRows.append(row)
        }
        renderDetail()
        applyTheme()
    }

    private func rowMenu(for runbook: DocsRunbook) -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, () -> Void)] = [
            ("Duplicate", { [weak self] in self?.duplicateRunbook(runbook) }),
            ("Delete\u{2026}", { [weak self] in self?.confirmDeleteRunbook(id: runbook.id, title: runbook.title) }),
        ]
        for (title, run) in entries {
            let sleeve = ClosureSleeve(run)
            menuSleeves.append(sleeve)
            let item = NSMenuItem(title: title, action: #selector(ClosureSleeve.invoke), keyEquivalent: "")
            item.target = sleeve
            menu.addItem(item)
        }
        return menu
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let row = sender.view as? RunbookRowView else { return }
        select(runbookID: row.runbookID)
    }

    private func select(runbookID id: String) {
        selectedRunbookID = id
        for row in runbookRows { row.isSelected = row.runbookID == id }
        renderDetail()
    }

    private func renderDetail() {
        guard let id = selectedRunbookID, let runbook = runbooks.first(where: { $0.id == id }) else { return }
        detailView.configure(title: runbook.title, steps: RunbookSteps.parse(runbook.content),
                             session: session?.runbookID == id ? session : nil, now: Date(), theme: theme)
    }

    // MARK: UX-17 - a run

    private func startRun() {
        guard let id = selectedRunbookID, let runbook = runbooks.first(where: { $0.id == id }) else { return }
        if session != nil { endRun() }
        let steps = RunbookSteps.parse(runbook.content)
        guard !steps.isEmpty else { return }
        session = RunbookSession(runbookID: id, total: steps.count, now: Date())
        startSessionTimer()
        renderDetail()
    }

    /// The step on screen is done; the last one ends the run.
    private func tickStep(now: Date = Date()) {
        guard var current = session else { return }
        current.tick(now: now)
        session = current
        if current.isFinished {
            endRun(now: now)
        } else {
            renderDetail()
        }
    }

    /// Ends the run where it is and keeps how far it got.
    private func endRun(now: Date = Date()) {
        guard let current = session else { return }
        RunbookRunLog.record(current.record(now: now), for: current.runbookID)
        session = nil
        sessionTimer?.invalidate()
        sessionTimer = nil
        rebuildRunbookGrid()
        if let container = view.window?.contentView {
            Toast.show(in: container, message: current.isFinished
                ? "Run finished in \(RunbookWords.minutes(current.elapsed(now: now)))"
                : "Run stopped at step \(current.index + 1) of \(current.total)")
        }
    }

    /// "4 min so far" moves while the page shows (GL-13), once a minute is
    /// enough for a figure counted in minutes.
    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.isViewLoaded, !self.view.isHiddenOrHasHiddenAncestor else { return }
            self.renderDetail()
        }
    }

    /// The Command Library's own risk gate decides whether a step's command
    /// needs a confirmation before it reaches the terminal.
    private func sendStepCommand(_ command: String) {
        let asCommand = DevOpsCommand(id: "runbook-step", name: "Runbook step", description: "", category: "",
                                      commandTemplate: command)
        CommandRiskConfirmation.confirm(command: asCommand, generatedText: command, actionVerb: "send to the terminal") {
            onSendCommand?(command)
        }
    }

    /// X5: writes the one example and opens it, so the affordance ends
    /// somewhere rather than silently changing a list behind the captain.
    @objc private func seedExampleRunbookTapped() {
        let created = runbookStore.createRunbook(title: SeedExamples.runbookTitle,
                                                 content: SeedExamples.runbookContent)
        reloadRunbooksList()
        openRunbook(id: created.id)
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
            if let container = view.window?.contentView { Toast.show(in: container, message: "A runbook needs a title", kind: .warning) }
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

    #if FM_SELFTESTS
    /// G3: drive the real delete path, confirmation and all.
    func debugConfirmDeleteRunbook(id: String, title: String) {
        confirmDeleteRunbook(id: id, title: title)
    }
    #endif

    /// S07: a copy beside the original, titled "<title> copy" so the two are
    /// told apart on the grid, through the store's own create (a new file,
    /// synced like any other).
    private func duplicateRunbook(_ runbook: DocsRunbook) {
        let title = "\(runbook.title) copy"
        let body = runbook.content
        runbookStore.createRunbook(title: title, content: Self.contentWithHeading(title: title, body: body))
        reloadRunbooksList()
        if let container = view.window?.contentView { Toast.show(in: container, message: "Runbook duplicated") }
    }

    #if FM_SELFTESTS
    func debugDuplicateRunbook(_ runbook: DocsRunbook) { duplicateRunbook(runbook) }
    #endif

    private func confirmDeleteRunbook(id: String, title: String, dismissingEditor: Bool = false) {
        // G3: themed; Return still deletes, as it did here.
        guard HelmConfirm.confirm(
            title: "Delete \"\(title)\"?",
            body: "This removes the runbook file and syncs the deletion.",
            confirmTitle: "Delete",
            destructive: true,
            symbol: "trash.fill",
            hue: .rose) else { return }
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
        // UX-17: the runbook opens in the list's detail, ready to run.
        if !runbookEditorContainer.isHidden { cancelRunbookEditor() }
        if !runbooks.contains(where: { $0.id == id }) { reloadRunbooksList() }
        select(runbookID: id)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRunbookRows: [RunbookRowView] { runbookRows }
    var debugDetail: RunbookDetailView { detailView }
    func debugTick(now: Date) { tickStep(now: now) }
    var debugRunbookEditorIsOpen: Bool { !runbookEditorContainer.isHidden }
    func debugBeginNewRunbook() { beginNewRunbook() }
    func debugCancelRunbookEditor() { cancelRunbookEditor() }
    func debugReloadRunbooks() { reloadRunbooksList() }
    /// X5: the real button's action, so a check drives what a click drives.
    func debugSeedExampleRunbook() { seedExampleRunbookTapped() }
    var debugRunbookEmptyState: HelmEmptyState? { runbookGridEmptyState }
    #endif

    // MARK: Theme

    private func applyTheme() {
        HelmSelection.apply(to: runbookBodyTextView, theme: theme)
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

        if !runbooks.isEmpty, runbookRows.first?.debugTitle != nil {
            let runs = RunbookRunLog.all()
            for (row, runbook) in zip(runbookRows, runbooks) {
                row.configure(title: runbook.title,
                              subtitle: RunbookWords.rowSubtitle(steps: RunbookSteps.parse(runbook.content).count,
                                                                 last: runs[runbook.id], now: Date()),
                              width: Self.listWidth, theme: theme)
            }
        }
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

// R2-UX-04: New Runbook is the page's primary verb, at the toolbar's far
// right in the sidebar layout. The editor showing takes it away, as before.
extension RunbooksController: WorkspacePrimaryActionProviding {
    var workspacePrimaryAction: NSView? { runbookEditorContainer.isHidden ? newRunbookButton : nil }
}
