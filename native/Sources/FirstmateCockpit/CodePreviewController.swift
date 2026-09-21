// Manjesh Grand Line - native macOS app.
//
// The `.codePreview` destination: paste code, see it highlighted properly,
// keep as many snippets open as you like, and have every one of them still be
// there - and on GitHub - next time.
//
// ## What it is
//
// A real, vendored Monaco Editor (the engine behind VS Code) in a `WKWebView`,
// fully offline - see `native/Vendor/Monaco/README.md` for provenance and
// `CodePreviewAssets.swift` for how the bundle is found. The captain chose
// Monaco specifically, over a lighter CodeMirror embed and over a native
// `NSTextView` highlighter, after reviewing all three.
//
// ## What it deliberately is not
//
// Not an IDE. No language servers, no IntelliSense, no completion, no
// project awareness, no network of any kind. The page imports Monaco's
// *editor* contributions (find, folding, bracket matching, multi-cursor, the
// context menu) and a hand-picked set of Monarch tokenizers, and none of its
// `vs/language/*` services. "Read and highlight, plus basic editing" is the
// bar, and the omissions are enforced at the bundle level rather than by
// turning features off at runtime.
//
// ## Why the chrome around the editor is AppKit
//
// The page is the editor surface and nothing more: the tab bar, the toolbar,
// the language picker and the status line are all real AppKit here, built out
// of this app's own components.
//
// That is the opposite call from `WhiteboardController`, which gives Excalidraw
// the whole body and hoists its three page actions into the drill header - and
// the difference is what each library ships. Excalidraw ships a complete
// toolbar, so re-drawing it natively would be pure duplication. `monaco-editor`
// ships **no** tab bar and **no** status bar (those are VS Code *workbench*
// features), so they have to be built either way; building them in HTML would
// put a second, un-themed visual language inside an app whose own self-tests
// ban a stock button bezel. Building them in AppKit also means `TabChipView`
// gives this page the same chips, the same right-click rename, and the same
// accessibility treatment Console's tabs already have.
//
// The drill header's action cluster is therefore empty, exactly like Console's
// and for the same stated reason: every action lives in this page's own
// toolbar a few points below, and hoisting copies is the duplication §6.4
// exists to remove. What the header does carry is the live subtitle.
//
// ## Persistence
//
// Automatic, with no Save button anywhere: an edit reaches disk when the
// page's 500ms debounce fires and reaches GitHub a few seconds after that. See
// `CodePreviewStore`'s header for the on-disk layout and why a snippet is a
// real file rather than a row in a YAML document.
//
// One behaviour worth knowing: a brand-new tab is **not** written until it has
// content. Opening the destination and looking at it must not commit an empty
// file to the captain's config repo.

import AppKit

final class CodePreviewController: NSViewController, DaylightDrillActions {

    // MARK: One open tab

    /// A snippet the captain has open.
    ///
    /// `key` and `name` are two different identities on purpose. The page keys
    /// its editor models by `key`, which is minted once and never changes, so
    /// Monaco keeps a snippet's undo history and scroll position across a
    /// rename. `name` is the filename *and* the tab label *and* (through its
    /// extension) the language - see `CodePreviewStore`'s header - so it
    /// changes whenever the captain renames a tab or picks a language, and
    /// nothing page-side has to care.
    private final class OpenSnippet {
        let key: String
        var name: String
        var content: String
        /// `false` until this snippet has had real content and been written.
        /// A tab opened and never typed into leaves nothing on disk.
        var persisted: Bool
        /// Set once the captain picks a language by hand. Detection never
        /// overrides a deliberate choice, however plain the file looks
        /// afterwards.
        var languageOverridden = false
        let chip: TabChipView

        init(key: String, name: String, content: String, persisted: Bool, chip: TabChipView) {
            self.key = key
            self.name = name
            self.content = content
            self.persisted = persisted
            self.chip = chip
        }

        var language: CodePreviewLanguage { CodePreviewLanguage.forFilename(name) }
    }

    // MARK: State

    private let store: CodePreviewStore
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var open: [OpenSnippet] = []
    private var currentKey: String?
    private var cursor = CodePreviewCursor(line: 1, column: 1, selected: 0, lines: 0)
    private var syncStatus: CodePreviewGitSync.Status = .synced
    private var lastError: String?
    /// Loaded from disk exactly once, on the destination's first mount. A
    /// later re-read would fight whatever the captain has open.
    private var hasRestored = false
    /// True only while `restoreSnippetsIfNeeded` is building the strip, so
    /// its per-snippet `addTab` calls do not each write a partial tab order.
    private var isRestoring = false
    /// How many snippets the first restore found. Zero is the one reading that
    /// can legitimately be stale - see `retryRestoreIfCloneArrivedLate`.
    private var restoredCount = 0

    // MARK: Views

    private let toolbar = HelmPageToolbar()
    private let tabsStack = NSStackView()
    private lazy var plusButton = HelmPageToolbar.iconButton(
        symbol: "plus", tooltip: "New snippet",
        target: self, action: #selector(newSnippetTapped))
    private let languagePicker = HelmPopUpButton()
    private lazy var findButton = HelmPageToolbar.iconButton(
        symbol: "magnifyingglass", tooltip: "Find in this snippet (⌘F)",
        target: self, action: #selector(showFind))
    private lazy var wrapButton = HelmPageToolbar.iconButton(
        symbol: "text.alignleft", tooltip: "Toggle soft wrap",
        target: self, action: #selector(toggleWrapTapped))
    // Font size is the app's own shared monospace size, not a Code Preview
    // setting: this page already *observed* `FontSizeManager` (that is how the
    // editor picks up a change made in Settings), it simply had no way to
    // change it from here. So the two buttons below are the same one-line
    // action `ConsoleController.zoomIn`/`zoomOut` already use, and persistence
    // comes free via `AppSettings.fontSize` - a second per-feature preference
    // would mean the terminals and the editor could disagree about "the
    // monospace size", which is exactly what `FontSizeManager` exists to stop.
    //
    // The tooltips name no keyboard shortcut, deliberately: the zoom keys
    // were View-menu items, and `fm/grandline-console-tabs-restore-tabmenu-fix`
    // removed that whole menu - nothing in `main.swift` binds either key any
    // more. (Console's own two zoom tooltips still promise them and are stale
    // for the same reason; left alone here rather than edited in passing.)
    /// E7: the shared stepper capsule, so Console and this page show the
    /// same zoom idiom (and a readout) instead of two bare glyph squares
    /// each.
    private lazy var zoomStepper = HelmZoomStepper()
    private lazy var copyButton = HelmPageToolbar.labeledButton(
        symbol: "doc.on.doc", title: "Copy",
        tooltip: "Copy this snippet to the clipboard",
        target: self, action: #selector(copyTapped))
    private lazy var clearButton = HelmPageToolbar.labeledButton(
        symbol: "eraser", title: "Clear",
        tooltip: "Empty this snippet, keeping the tab",
        target: self, action: #selector(clearTapped))

    private let editorCard = NSView()
    /// M2: the scroll-edge hairline, driven by Monaco's own scroll position
    /// rather than by an `NSScrollView` this page does not have. Built in
    /// `loadView` once `editorCard` exists.
    private var scrollEdge: HelmScrollEdgeHairline?
    private let webView = CodePreviewWebView()
    private let overlay = NSView()
    private var overlayState: HelmEmptyState?

    private lazy var runButton = HelmPageToolbar.labeledButton(
        symbol: "play.fill", title: "Run",
        tooltip: "Run this snippet in a sandboxed temp directory (\u{2318}R)",
        target: self, action: #selector(runTapped))
    private lazy var formatButton = HelmPageToolbar.labeledButton(
        symbol: "text.alignleft", title: "Format",
        tooltip: "Format this snippet with the formatter installed for its language",
        target: self, action: #selector(formatTapped))
    private lazy var runnersButton = HelmPageToolbar.iconButton(
        symbol: "cpu", tooltip: "Which runners and formatters this machine has",
        target: self, action: #selector(runnersTapped))
    /// Retained rather than local, so `AppLockGate` can find it: GL-09 / audit
    /// §5.1(b) - a popover left open when the app lock fires stays readable and
    /// interactive *above* the lock overlay unless the gate can close it, and
    /// `LockGateCoverageSelfTest` fails the run on an unregistered one.
    private var runnersPopover: NSPopover?
    private let outputPane = CodeRunOutputPane()
    private var outputPaneHeight: NSLayoutConstraint?
    private var outputPaneTopGap: NSLayoutConstraint?
    /// The status bar hangs off the pane when it is showing and off the editor
    /// card when it is not - see `renderPane` for why swapping the constraint
    /// is the only shape that works here.
    private var statusBarBelowPane: NSLayoutConstraint?
    private var statusBarBelowEditor: NSLayoutConstraint?

    private let statusBar = NSView()
    private let statusSeparator = NSView()
    private let cursorLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let encodingLabel = NSTextField(labelWithString: "UTF-8")
    private let syncLabel = NSTextField(labelWithString: "")

    private var wrapOn = false
    private var themeObservation: ThemeObservation?
    private var fontObservation: FontSizeObservation?

    // MARK: Run and format (F11)

    private let runner = CodeRunner()
    /// Live only while a run is in flight - this is what Stop cancels, and
    /// what makes a second Run while one is running impossible.
    private var activeRun: SubprocessCancellation?
    /// Which snippet the pane is showing, keyed by snippet. A run belongs to
    /// the tab it was started from, so switching tabs shows that tab's own last
    /// output rather than the neighbour's - the same per-tab independence the
    /// editor's models already have.
    private var paneStates: [String: CodeRunPaneState] = [:]
    /// True while a format is in flight, so the button cannot be pressed twice
    /// and apply an older result over a newer one.
    private var isFormatting = false

    private static let cardInset: CGFloat = HelmMetrics.s3
    private static let statusBarHeight: CGFloat = 26

    // MARK: Init

    init(store: CodePreviewStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?

    /// Empty on purpose - see the file header. Console makes the same call.
    var drillHeaderActions: [NSView] { [] }

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        if !CodePreviewAssets.isAvailable { return "The Monaco bundle is missing" }
        guard webView.isReady else { return "Starting the editor…" }
        let count = open.count
        let noun = count == 1 ? "1 snippet" : "\(count) snippets"
        return "\(noun) \u{00B7} \(syncSummary)"
    }

    /// The sync half of the subtitle *and* the status bar's own label - one
    /// wording, so the two can never disagree about whether the captain's code
    /// has reached GitHub.
    private var syncSummary: String {
        switch syncStatus {
        case .synced: return store.gitSync == nil ? "saved on this machine" : "synced to manjesh-config"
        case .localChanges: return "saving…"
        case .syncing: return "syncing…"
        case .failed(let why): return "sync failed: \(why)"
        }
    }

    // MARK: Lifecycle

    override func loadView() {
        // UX11: the page's own root accepts a dropped file, so a captain can
        // drag a file onto the page from anywhere on it rather than hunting
        // for a well. A `WKWebView` swallows its own drags, so the editor
        // rectangle itself is not a drop target - dropping onto the toolbar,
        // the status bar or the page's margins is what works, which is why the
        // highlight is drawn around the whole page rather than around a zone.
        let root = CodePreviewDropView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        root.onDropFiles = { [weak self] urls in self?.openDroppedFiles(urls) }
        root.wantsLayer = true
        view = root

        buildToolbar(in: root)
        buildEditor(in: root)
        buildOutputPane(in: root)
        buildStatusBar(in: root)
        buildStatusBarPlacement()

        webView.onReady = { [weak self] in self?.editorBecameReady() }
        webView.onPageError = { [weak self] message in self?.report(error: message) }
        webView.onSnippetChanged = { [weak self] key, content in self?.snippetChanged(key: key, content: content) }
        webView.onCursorMoved = { [weak self] cursor in
            self?.cursor = cursor
            self?.refreshStatusBar()
        }

        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
        // The editor's font size follows the app's own monospace size, like
        // every other code surface here (`ToolInstance.codeEditor`, the
        // terminals) - one setting, one place to change it.
        fontObservation = FontSizeManager.shared.observe { [weak self] size in
            self?.pushFontSize(size)
        }

        store.gitSync?.observeStatus { [weak self] status in
            guard let self else { return }
            self.syncStatus = status
            self.refreshStatusBar()
            self.onDrillSubtitleChanged?()
            // A status change is the one signal this page gets that the git
            // working tree moved - which on a fresh machine is when the
            // captain's snippets first exist at all.
            self.retryRestoreIfCloneArrivedLate()
        }

        // The page is only loaded here, on the destination's first mount, and
        // never restarted afterwards - so a session that never opens Code
        // Preview never starts a web content process at all.
        if webView.activate() {
            showOverlay(symbol: "chevron.left.forwardslash.chevron.right",
                        title: "Starting the editor\u{2026}",
                        body: "Monaco is loading from this machine. Nothing is fetched from the network.")
        } else {
            showOverlay(symbol: "exclamationmark.triangle",
                        title: "No editor bundle",
                        body: CodePreviewAssets.missingBundleMessage)
            for control in [plusButton, findButton, wrapButton, copyButton, clearButton,
                            runButton, formatButton, runnersButton] {
                control.isEnabled = false
            }
            languagePicker.isEnabled = false
        }
        rebuildLanguagePicker()
        applyTheme()
        refreshStatusBar()
        refreshRunControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Both halves of the gate re-derive themselves from live state, so a
        // visit only ever corrects a stale reading.
        webView.refreshDisplayGating()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Belt and braces alongside `suspend()`, which already flushes: this
        // fires on the way *out* of the destination even in the cases where
        // the gate has not yet noticed the view is hidden.
        flushPendingEdits()
    }

    /// How long the quit path may wait for the page's own debounced edit to
    /// come back over the bridge. Sized off the page's `CHANGE_DEBOUNCE_MS`
    /// (500ms) plus room for one `WKWebView` round trip - long enough that the
    /// keystrokes this exists to save actually arrive, short enough to be
    /// invisible on ⌘Q.
    static let terminateEditFlushBudget: TimeInterval = 1.0

    /// Called by the app delegate on quit, so the last few keystrokes before
    /// ⌘Q are written and committed like every other edit (audit 2 §6.8 /
    /// §2.8 - this method had *zero* callers until then, which is why the
    /// promise in this comment was not true).
    ///
    /// The ordering is the whole point and is why this cannot just be two
    /// fire-and-forget calls. A pending edit lives only in the page's own JS
    /// debounce until `flush` posts it back over the bridge, and that reply is
    /// what runs `snippetChanged` -> `store.save` -> `markDirty()`. So the git
    /// flush has to happen *after* the bridge round trip has landed, or it
    /// commits a working tree that does not yet contain the very keystrokes
    /// this method exists to save.
    func shutdown() {
        flushPendingEdits(waitingUpTo: Self.terminateEditFlushBudget)
        // Never `commitAndPushNow()` directly - see
        // `CodePreviewGitSync.flushForTerminationNow()` for why (it is §4.3's
        // fix, applied to this store as its call site finally appeared).
        store.gitSync?.flushForTerminationNow()
    }

    /// Posts whatever the page still has debounced.
    ///
    /// `wait` is `nil` everywhere except the quit path: while the app is still
    /// running the reply lands on its own a moment later and the write
    /// happens then, which is all `viewWillDisappear`/`suspend()` need. On
    /// quit there is no "a moment later", so the caller has to hold the
    /// process open for the round trip.
    ///
    /// Held by pumping the main run loop rather than blocking it: the reply
    /// arrives as a `WKScriptMessageHandler` callback delivered *on* the main
    /// queue, so a `DispatchSemaphore.wait()` here would deadlock against the
    /// very thing it is waiting for. `applicationWillTerminate` is a
    /// synchronous last-chance hook, which is exactly the situation this is
    /// for. The bound is what keeps a wedged or never-loaded page from
    /// blocking the quit at all, and anything it abandons is only the last
    /// sub-second of typing - every earlier edit is already on disk.
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
                code preview: the page did not acknowledge its quit-time edit flush within \
                \(wait, privacy: .public)s - letting the app quit; every edit older than the \
                page's own debounce is already on disk
                """)
        }
    }

    // MARK: Building

    private func buildToolbar(in root: NSView) {
        root.addSubview(toolbar)

        tabsStack.orientation = .horizontal
        tabsStack.spacing = 4
        tabsStack.alignment = .centerY
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.setLeading(tabsStack)

        languagePicker.translatesAutoresizingMaskIntoConstraints = false
        languagePicker.target = self
        languagePicker.action = #selector(languagePicked)
        languagePicker.toolTip = "The language this snippet is highlighted as"
        // Wide enough for the longest entry ("HCL / Terraform") without the
        // popup resizing as the selection changes, which reads as the toolbar
        // twitching every time a language is detected.
        languagePicker.widthAnchor.constraint(equalToConstant: 150).isActive = true

        // F11's two verbs lead the action cluster, and the reviewed mockup's
        // order is kept (Format, then Run): Run is the one the captain reaches
        // for, so it sits closest to the utilities it is not one of.
        // `runnersButton` is the mockup's "Runners found" sidebar list, which
        // this page has nowhere to put - it has tab chips where the mockup
        // drew a snippet sidebar - so the same information is one click away
        // in a popover rather than permanently occupying 180pt of editor.
        toolbar.setTrailing(HelmPageToolbar.group([
            runnersButton, formatButton, runButton,
            languagePicker, findButton, wrapButton, zoomStepper, copyButton, clearButton,
        ]))

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
        ])
    }

    private func buildEditor(in root: NSView) {
        editorCard.translatesAutoresizingMaskIntoConstraints = false
        editorCard.wantsLayer = true
        editorCard.layer?.masksToBounds = true
        root.addSubview(editorCard)
        editorCard.addSubview(webView)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        editorCard.addSubview(overlay)

        // M2 (§3M): the same hairline every native page gets, at the one
        // boundary this page's content genuinely slides under.
        //
        // **Why the card's top edge and not the app's floating bar.** A3's
        // shell-level edge is deliberately withheld from a page whose own top
        // is a static strip - `ScrollEdgeObserver`'s header lists Console,
        // Tools and Docs by name for exactly this - and this page's top is a
        // `HelmPageToolbar` that never moves. What scrolls under it is the
        // editor, so the boundary is the card's own top edge, which is the
        // treatment D5(a) already gives a card-hosted list (`HostsListSection`
        // is the reference). Adding it to the bar instead would draw a line
        // at an edge nothing passes.
        scrollEdge = HelmScrollEdgeHairline(atTopOf: editorCard, in: editorCard)
        webView.onScrolledAwayFromTop = { [weak self] scrolled in
            self?.scrollEdge?.setScrolled(scrolled)
        }

        NSLayoutConstraint.activate([
            editorCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardInset),
            editorCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardInset),
            editorCard.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: Self.cardInset),

            webView.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor),
            webView.topAnchor.constraint(equalTo: editorCard.topAnchor),
            webView.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor),

            overlay.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: editorCard.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor),
        ])
    }

    /// The bottom pane (F11).
    ///
    /// **Hiding it is not enough, and neither is collapsing its height** -
    /// both were measured, in that order, by the suite that now guards this.
    ///
    /// AppKit gotchas (11) and (15): a hidden `NSView` participates in Auto
    /// Layout exactly as much as a visible one, so `isHidden = true` alone left
    /// the editor 188pt shorter with nothing to show for it. Collapsing the
    /// height constraint is not enough either, and this is the part that is
    /// easy to get wrong: the pane's own header row is a real 28pt button row
    /// with required constraints, so a **`height == 0` at `contentTie` (499)
    /// loses to its own content** and the pane still resolves to 45pt -
    /// measured exactly that way (the editor gave up 155pt where 200 was
    /// expected). Raising that constraint above 499 is not the fix either;
    /// gotcha (13) is about what a content constraint above 500 does to the
    /// captain's window.
    ///
    /// So the status bar's own top constraint is what moves: it hangs off the
    /// **pane** while the pane is showing and off the **editor card** while it
    /// is not, and nothing then derives from a hidden pane's height at all.
    /// The hidden state reproduces the page's pre-F11 geometry exactly, which
    /// `CodeRunnerViewSelfTest` asserts to the point.
    private func buildOutputPane(in root: NSView) {
        root.addSubview(outputPane)
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.runnersPopover }
        outputPane.onStop = { [weak self] in self?.stopRun() }
        outputPane.onCopy = { [weak self] in self?.copyOutput() }
        outputPane.onClear = { [weak self] in self?.clearOutput() }

        let height = outputPane.heightAnchor.constraint(equalToConstant: 0)
        // Below `NSLayoutPriorityWindowSizeStayPut` (500), per gotcha (13):
        // anything above it can resize the captain's whole window, and this
        // page is mounted for the process's life whether or not it is showing.
        height.priority = HelmDaylightPriority.contentTie
        height.isActive = true
        outputPaneHeight = height

        // Always active, so a hidden pane still has a defined vertical
        // position and Auto Layout has nothing to call ambiguous.
        let gap = outputPane.topAnchor.constraint(equalTo: editorCard.bottomAnchor,
                                                  constant: Self.cardInset)
        gap.isActive = true
        outputPaneTopGap = gap

        NSLayoutConstraint.activate([
            outputPane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardInset),
            outputPane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardInset),
        ])
    }

    /// The status bar's two alternative top constraints. Built after both the
    /// pane and the status bar exist, and only one is ever active.
    private func buildStatusBarPlacement() {
        statusBarBelowEditor = statusBar.topAnchor.constraint(
            equalTo: editorCard.bottomAnchor, constant: Self.cardInset)
        statusBarBelowPane = statusBar.topAnchor.constraint(
            equalTo: outputPane.bottomAnchor, constant: Self.cardInset)
        statusBarBelowEditor?.isActive = true
    }

    private func buildStatusBar(in root: NSView) {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        root.addSubview(statusBar)

        statusSeparator.translatesAutoresizingMaskIntoConstraints = false
        statusSeparator.wantsLayer = true
        statusBar.addSubview(statusSeparator)

        // Ln/Col leading; language, encoding and the sync state trailing -
        // VS Code's own arrangement, which is what the reviewed mockup shows.
        let leading = NSStackView(views: [cursorLabel])
        let trailing = NSStackView(views: [languageLabel, encodingLabel, syncLabel])
        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = HelmMetrics.s3
            stack.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(stack)
        }
        // The sync line is the one label here whose text length is
        // unbounded (a git error message), so it is the one allowed to
        // truncate rather than push its siblings out of the bar.
        syncLabel.lineBreakMode = .byTruncatingTail
        syncLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [cursorLabel, languageLabel, encodingLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
            // Deliberately absent here: the status bar's top constraint is one
            // of the two `buildOutputPane` owns and swaps, because a page that
            // has never run anything must have exactly the geometry it had
            // before F11 existed.

            statusSeparator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            statusSeparator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            statusSeparator.heightAnchor.constraint(equalToConstant: 1),

            leading.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor,
                                             constant: HelmPageToolbar.leadingInset),
            leading.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor,
                                               constant: -HelmPageToolbar.trailingInset),
            trailing.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor,
                                              constant: -HelmMetrics.s2),
        ])
    }

    // MARK: The editor coming up

    private func editorBecameReady() {
        hideOverlay()
        lastError = nil
        pushTheme()
        pushFontSize(FontSizeManager.shared.size)
        restoreSnippetsIfNeeded()
        refreshRunControls()
        // F11 / GL-12: asking "what interpreters and formatters does this
        // machine have" means resolving ~15 executables and running
        // `--version` on each, so it happens off the main thread and the two
        // buttons are re-derived when the answer lands. Started here rather
        // than in `loadView` for the same reason the page itself is: a session
        // that never opens Code Preview pays nothing.
        runner.warmUp { [weak self] in
            self?.refreshRunControls()
            self?.onDrillSubtitleChanged?()
        }
        onDrillSubtitleChanged?()
    }

    /// Reads every snippet off disk and opens one tab per file - the whole of
    /// "it is still there next time".
    ///
    /// Runs once in the ordinary case. A destination stays mounted for the
    /// process's life (`DestinationRegistry`), so re-reading on a later visit
    /// could only fight the captain's own in-memory edits - which is exactly
    /// why the one case that *does* re-read is guarded so tightly; see
    /// `retryRestoreIfCloneArrivedLate`.
    private func restoreSnippetsIfNeeded() {
        guard !hasRestored else { return }
        hasRestored = true
        isRestoring = true
        defer { isRestoring = false }

        // Audit §6.6a: the captain's own tab order, not filename order - so
        // renaming a tab no longer moves it on the next launch.
        let saved = store.listInTabOrder()
        restoredCount = saved.count
        for snippet in saved {
            addTab(name: snippet.id, content: snippet.content, persisted: true, select: false)
        }
        // A brand-new profile gets one empty tab to paste into rather than an
        // empty state with a button - the whole feature is "paste code and see
        // it", and making that one click shorter is the point. Nothing is
        // written to disk until it has content (see `snippetChanged`).
        if open.isEmpty {
            addTab(name: nextUntitledName(), content: "", persisted: false, select: false)
        }
        if let first = open.first { select(key: first.key) }
        refreshTabBar()
        onDrillSubtitleChanged?()
    }

    /// The one case where reading the folder a second time is right.
    ///
    /// `CodePreviewStore.init` kicks off `ShiftGitSync`'s clone asynchronously,
    /// so on a fresh machine - or any launch where the working tree is not
    /// there yet - the first restore can genuinely run against an empty
    /// directory and find nothing. Without this, the captain's snippets land
    /// on disk seconds later and the panel keeps showing one blank tab until
    /// the app is relaunched.
    ///
    /// Deliberately the narrowest possible retry: only when the first restore
    /// found **nothing**, only when the folder now has something, and only
    /// while every open tab is still an untouched placeholder. If the captain
    /// has typed a single character, this does nothing - re-reading over their
    /// work is a far worse failure than the blank panel it would be fixing.
    private func retryRestoreIfCloneArrivedLate() {
        guard hasRestored, restoredCount == 0 else { return }
        guard open.allSatisfy({ !$0.persisted && $0.content.isEmpty }) else { return }
        guard !store.names().isEmpty else { return }

        for snippet in open {
            webView.call("closeSnippet", payload: ["id": snippet.key])
        }
        open.removeAll()
        currentKey = nil
        hasRestored = false
        restoreSnippetsIfNeeded()
    }

    // MARK: Tabs

    @discardableResult
    private func addTab(name: String, content: String, persisted: Bool, select shouldSelect: Bool) -> OpenSnippet {
        let key = UUID().uuidString
        let chip = TabChipView(tabID: UUID(), name: name)
        let snippet = OpenSnippet(key: key, name: name, content: content, persisted: persisted, chip: chip)

        chip.onSelect = { [weak self] in self?.select(key: key) }
        chip.onClose = { [weak self] in self?.closeTab(key: key) }
        chip.onDuplicate = { [weak self] in self?.duplicateTab(key: key) }
        chip.onRename = { [weak self] newName in self?.renameTab(key: key, to: newName) }

        open.append(snippet)
        webView.call("openSnippet", payload: [
            "id": key,
            "language": snippet.language.id,
            "content": content,
            "select": shouldSelect,
        ])
        if shouldSelect { select(key: key) }
        refreshTabBar()
        persistTabOrder()
        return snippet
    }

    private func select(key: String) {
        guard snippet(for: key) != nil else { return }
        currentKey = key
        webView.call("selectSnippet", payload: ["id": key])
        styleChips()
        rebuildLanguagePicker()
        refreshStatusBar()
        // F11: the pane belongs to a tab, so selecting one shows that tab's
        // own last run - never the neighbour's.
        renderPane()
        refreshRunControls()
    }

    private func closeTab(key: String) {
        guard let snippet = snippet(for: key) else { return }

        // Closing a tab genuinely deletes the snippet: tabs *are* the folder,
        // so a tab that closed without deleting would simply come back on the
        // next launch, which is worse than either honest answer.
        //
        // `Toast.showUndo` rather than a modal (GL-33): the content is right
        // here in memory, so undo can restore it exactly - which is the one
        // condition that file's own rule sets for offering an undo at all.
        let name = snippet.name
        let content = snippet.content
        let wasPersisted = snippet.persisted

        open.removeAll { $0.key == key }
        // F11: a closed tab's output goes with it. Stop first if it is the one
        // running - a run whose tab is gone has nowhere to report.
        if currentKey == key, activeRun != nil { activeRun?.cancel() }
        paneStates.removeValue(forKey: key)
        webView.call("closeSnippet", payload: ["id": key])
        if wasPersisted { store.delete(name: name) }

        if currentKey == key { currentKey = nil }
        // Never leave the panel with nothing to paste into - the same rule
        // Console applies when its last tab closes.
        if open.isEmpty {
            addTab(name: nextUntitledName(), content: "", persisted: false, select: true)
        } else if currentKey == nil, let first = open.first {
            select(key: first.key)
        }
        refreshTabBar()
        persistTabOrder()
        onDrillSubtitleChanged?()

        guard wasPersisted, !content.isEmpty else { return }
        Toast.showUndo(in: view, message: "Closed \(name)") { [weak self] in
            guard let self else { return }
            let restored = self.store.create(name: name, content: content)
            self.addTab(name: restored.id, content: content, persisted: true, select: true)
            self.onDrillSubtitleChanged?()
        }
    }

    private func duplicateTab(key: String) {
        guard let snippet = snippet(for: key) else { return }
        let copy = store.create(name: snippet.name, content: snippet.content)
        addTab(name: copy.id, content: snippet.content, persisted: true, select: true)
        onDrillSubtitleChanged?()
    }

    private func renameTab(key: String, to newName: String) {
        guard let snippet = snippet(for: key) else { return }
        let target = CodePreviewStore.sanitize(newName)
        guard !target.isEmpty, target != snippet.name else {
            // Put the chip back to the real name: the captain may have typed
            // something the store would have changed, and a chip showing a
            // name no file has is the start of the two-sources-of-truth bug.
            snippet.chip.setName(snippet.name)
            return
        }
        let landed = snippet.persisted
            ? store.rename(from: snippet.name, to: target)
            : uniqueName(target, excluding: key)
        snippet.name = landed
        snippet.chip.setName(landed)
        // The order file holds names, so a rename has to update it - and this
        // is the whole point of §6.6a: the tab keeps its slot instead of
        // jumping to wherever its new name sorts.
        persistTabOrder()
        // A rename can change the extension, which is what decides the
        // language - so re-push it, and stop auto-detecting for this snippet:
        // naming a file `.py` by hand is as deliberate a choice as picking
        // Python from the menu.
        if (target as NSString).pathExtension != "" { snippet.languageOverridden = true }
        webView.call("setLanguage", payload: ["id": key, "language": snippet.language.id])
        rebuildLanguagePicker()
        refreshStatusBar()
        onDrillSubtitleChanged?()
    }

    /// Record the current tab order (audit §6.6a).
    ///
    /// Only *persisted* snippets: a brand-new empty tab has no file yet, so
    /// naming it here would record an entry with nothing behind it - and,
    /// because `saveOrder` is a no-op when nothing changed, that also means
    /// opening a scratch tab never dirties the git subtree.
    ///
    /// Not called during restore: `addTab` runs once per snippet there, and
    /// each intermediate call would write a partial order.
    private func persistTabOrder() {
        guard !isRestoring else { return }
        store.saveOrder(open.filter(\.persisted).map(\.name))
    }

    private func refreshTabBar() {
        for v in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for snippet in open { tabsStack.addArrangedSubview(snippet.chip) }
        tabsStack.addArrangedSubview(plusButton)
        styleChips()
    }

    private func styleChips() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = theme.isDaylight ? HelmTheme.mutedInk(theme) : ink.withAlphaComponent(0.55)
        let tint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        for snippet in open {
            snippet.chip.applyStyle(selected: snippet.key == currentKey,
                                    accent: accent, muted: muted, tint: tint)
        }
    }

    /// A name no other open tab and no file on disk is already using.
    ///
    /// `CodePreviewStore.rename`/`create` already disambiguate against **disk**,
    /// which covers every snippet that has been written. It does not cover a
    /// tab that is open but still empty - and those are exactly the ones a
    /// captain renames before typing into. Two such tabs sharing a name is
    /// real data loss rather than a cosmetic clash: neither has a file yet, so
    /// nothing complains, and then the second one to receive content silently
    /// overwrites the first one's.
    private func uniqueName(_ target: String, excluding key: String) -> String {
        var taken = Set(store.names())
        taken.formUnion(open.filter { $0.key != key }.map(\.name))
        guard taken.contains(target) else { return target }
        let ns = target as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// The store's own next free name, told about the tabs this controller has
    /// open but has not written yet - see `CodePreviewStore.nextUntitledName`
    /// for why the disk alone is not enough.
    private func nextUntitledName() -> String {
        store.nextUntitledName(avoiding: Set(open.map(\.name)))
    }

    private func snippet(for key: String) -> OpenSnippet? {
        open.first { $0.key == key }
    }

    private var currentSnippet: OpenSnippet? {
        currentKey.flatMap { snippet(for: $0) }
    }

    // MARK: Edits

    /// The page's debounced "this snippet changed" message - the one path from
    /// a keystroke to the disk, and to git.
    private func snippetChanged(key: String, content: String) {
        guard let snippet = snippet(for: key) else { return }
        snippet.content = content

        // An empty, never-saved tab stays off disk. Visiting this destination
        // must not commit a file to the captain's config repo.
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snippet.persisted else {
            return
        }

        autoDetectLanguageIfNeeded(for: snippet)
        autoTitleIfNeeded(for: snippet)
        store.save(name: snippet.name, content: content)
        let wasPersisted = snippet.persisted
        snippet.persisted = true
        // A scratch tab that just earned a file joins the order for the first
        // time (and auto-detection above may have renamed it). Guarded on the
        // transition so ordinary typing does not re-write the sidecar on
        // every keystroke - `saveOrder` would no-op anyway, but not reading
        // the file at all is cheaper still.
        if !wasPersisted { persistTabOrder() }
        refreshStatusBar()
        refreshRunControls()
        onDrillSubtitleChanged?()
    }

    /// Names a pasted snippet's language, if it is still unnamed.
    ///
    /// Only fires while the snippet is genuinely undecided: still plain text,
    /// and never renamed or picked by hand. Once detection succeeds the file
    /// gains a real extension, so `language` stops being plain text and this
    /// stops firing on its own - there is no "already detected" flag to keep
    /// in step, and pasting more into a snippet cannot make its language
    /// flip-flop under the captain.
    private func autoDetectLanguageIfNeeded(for snippet: OpenSnippet) {
        guard !snippet.languageOverridden, snippet.language.id == CodePreviewLanguage.plainText.id else { return }
        guard let detected = CodePreviewLanguageDetector.detect(snippet.content) else { return }
        guard detected.id != snippet.language.id else { return }
        apply(language: detected, to: snippet, overridden: false)
    }

    /// Names a pasted snippet from its own first line, if it is still unnamed -
    /// review #3's UX11.
    ///
    /// The same three-part guard `autoDetectLanguageIfNeeded` above uses, and
    /// for the same reason: this must never overwrite a name the captain
    /// chose, and it must not be able to fire twice and make a snippet's name
    /// flip-flop as they keep typing.
    ///
    ///   - `languageOverridden` also covers a hand rename (`renameTab` sets
    ///     it), so a deliberately named tab is out of scope immediately;
    ///   - `isUntitled` is the positive test - only a `snippet-N` stem is
    ///     eligible, and the derived stem can never itself look like one;
    ///   - once it has fired, the stem is no longer `snippet-N`, so it cannot
    ///     fire again. There is no "already titled" flag to keep in step.
    ///
    /// Runs **after** language detection, deliberately: detection renames the
    /// extension, and doing it the other way round would rename the file
    /// twice for one paste.
    private func autoTitleIfNeeded(for snippet: OpenSnippet) {
        guard !snippet.languageOverridden, CodePreviewAutoTitle.isUntitled(snippet.name) else { return }
        guard let stem = CodePreviewAutoTitle.stem(fromFirstLineOf: snippet.content) else { return }
        let ext = (snippet.name as NSString).pathExtension
        let target = ext.isEmpty ? stem : "\(stem).\(ext)"
        guard target != snippet.name else { return }
        let landed = snippet.persisted
            ? store.rename(from: snippet.name, to: target)
            : uniqueName(target, excluding: snippet.key)
        snippet.name = landed
        snippet.chip.setName(landed)
        // The order sidecar holds names, so a rename has to update it or the
        // tab jumps to wherever its new name sorts on the next launch - §6.6a.
        persistTabOrder()
        refreshStatusBar()
    }

    /// Moves a snippet onto `language` - which, because the extension is the
    /// language, means renaming its file. `overridden` records whether the
    /// captain asked for this or the detector guessed.
    private func apply(language: CodePreviewLanguage, to snippet: OpenSnippet, overridden: Bool) {
        let target = CodePreviewLanguage.filename(snippet.name, as: language)
        if target != snippet.name {
            let landed = snippet.persisted
                ? store.rename(from: snippet.name, to: target)
                : uniqueName(target, excluding: snippet.key)
            snippet.name = landed
            snippet.chip.setName(landed)
            // Picking a language renames the file (the extension *is* the
            // language here), so the order sidecar has to follow or the tab
            // moves on the next launch - the exact thing §6.6a is about.
            persistTabOrder()
        }
        if overridden { snippet.languageOverridden = true }
        webView.call("setLanguage", payload: ["id": snippet.key, "language": language.id])
        rebuildLanguagePicker()
        refreshStatusBar()
        // A language change is a change of interpreter and formatter, so
        // both buttons have to be re-derived.
        refreshRunControls()
    }

    // MARK: Actions

    /// Open (or reveal) one saved snippet by name - ⌘K's landing action
    /// (audit §6.6b).
    ///
    /// A snippet's filename *is* its identity here (see `CodePreviewStore`'s
    /// header), so the name is the whole key. An already-open tab is selected
    /// rather than duplicated; anything else is loaded from the store into a
    /// new tab. A name the store no longer holds does nothing rather than
    /// opening an empty tab under a dead name.
    func openSnippet(named name: String) {
        if let existing = open.first(where: { $0.name == name }) {
            select(key: existing.key)
            return
        }
        guard let snippet = store.list().first(where: { $0.id == name }) else { return }
        _ = addTab(name: snippet.id, content: snippet.content, persisted: true, select: true)
    }

    /// UX4: the File menu's contextual ⌘N on this page, and `⌘K`'s "New Code
    /// Snippet" verb - the page's own toolbar action, not a second copy.
    func newSnippetFromMenu() { newSnippetTapped() }

    /// UX11's drag-and-drop file open: "the page has no […] drop-a-file-to-
    /// open".
    ///
    /// Each file becomes a tab named after the file, carrying the file's own
    /// extension - so the language is right for free (the extension *is* the
    /// language here, see `CodePreviewStore`'s header) and the auto-title above
    /// never fires on it, because the name is not a `snippet-N` placeholder.
    ///
    /// **Bounded, and it says so when it refuses.** A dropped file is
    /// arbitrary - a 2GB core dump, a JPEG, something unreadable - and this
    /// page keeps every open snippet's text in memory and writes it to a
    /// git-synced repo. So a file is read only when it is within
    /// `maximumDroppedFileBytes` and decodes as UTF-8 text, and a refusal is
    /// stated rather than silent (GL-14's spirit: a file that did not open and
    /// a file that opened empty are different things, and must read
    /// differently).
    private func openDroppedFiles(_ urls: [URL]) {
        var opened = 0
        var refused: [String] = []
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maximumDroppedFileBytes else {
                refused.append("\(url.lastPathComponent) is too large to open here")
                continue
            }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                refused.append("\(url.lastPathComponent) is not a text file")
                continue
            }
            // "" excludes nothing, which is right: this is a brand new tab,
            // so every already-open name is genuinely taken.
            let name = uniqueName(CodePreviewStore.sanitize(url.lastPathComponent), excluding: "")
            let snippet = addTab(name: name, content: text, persisted: false, select: true)
            // Dropped, not pasted: the captain named this by choosing a file,
            // so neither the auto-title nor the language detector should ever
            // second-guess it.
            snippet.languageOverridden = true
            snippetChanged(key: snippet.key, content: text)
            opened += 1
        }
        if !refused.isEmpty {
            Toast.show(in: view, message: refused.joined(separator: " \u{00B7} "))
        } else if opened > 0 {
            onDrillSubtitleChanged?()
        }
    }

    /// The largest file this page will read from a drop.
    ///
    /// 2 MB: comfortably past any source file a person reads, and far short of
    /// the log and dump sizes that would otherwise land in memory, in Monaco
    /// and in the captain's synced config repo. The Log Analyzer is where a
    /// large file belongs.
    static let maximumDroppedFileBytes = 2 * 1024 * 1024

    @objc private func newSnippetTapped() {
        addTab(name: nextUntitledName(), content: "", persisted: false, select: true)
        onDrillSubtitleChanged?()
        webView.call("focusEditor")
    }

    /// ⌘F. The Edit menu's "Find…" item is `nil`-target and routes through the
    /// responder chain, so this method's *name* is what makes the shortcut
    /// work here - `ConsoleController` and `ToolsController` share selector
    /// names for exactly this reason (see AGENTS.md's note on that holdover).
    @objc func showFind() {
        webView.call("find")
    }

    /// Both zoom actions go straight through `FontSizeManager`, which clamps
    /// to its own `minSize...maxSize`, persists to `AppSettings.fontSize` and
    /// notifies every observer - including this page's own, which is what
    /// actually pushes the new size into Monaco. Nothing here tracks a size of
    /// its own.
    @objc private func zoomInTapped() { FontSizeManager.shared.step(by: 1) }
    @objc private func zoomOutTapped() { FontSizeManager.shared.step(by: -1) }

    @objc private func toggleWrapTapped() {
        wrapOn.toggle()
        wrapButton.tint = wrapOn ? .accent : nil
        webView.call("setWordWrap", payload: ["on": wrapOn])
    }

    @objc private func copyTapped() {
        guard let snippet = currentSnippet, !snippet.content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.content, forType: .string)
        Toast.show(in: view, message: "Copied \(snippet.name)")
    }

    @objc private func clearTapped() {
        guard let snippet = currentSnippet else { return }
        guard !snippet.content.isEmpty else { return }

        // G3: themed; Return still clears, as it did here.
        guard HelmConfirm.confirm(
            title: "Clear \(snippet.name)?",
            body: "This empties the snippet but keeps the tab. \u{2318}Z in the editor can undo it.",
            confirmTitle: "Clear",
            destructive: true,
            symbol: "eraser.fill",
            hue: .rose) else { return }

        snippet.content = ""
        webView.call("openSnippet", payload: [
            "id": snippet.key, "language": snippet.language.id, "content": "", "select": true,
        ])
        if snippet.persisted { store.save(name: snippet.name, content: "") }
        refreshStatusBar()
        refreshRunControls()
    }

    // MARK: Run and format (F11)

    /// ⌘R, and the toolbar's Run button.
    ///
    /// One run at a time, on purpose: a second Run while one is in flight
    /// would give the pane two writers and the captain no way to tell whose
    /// output they are reading.
    @objc func runCodeSnippet() { runTapped() }

    @objc private func runTapped() {
        guard activeRun == nil else { return }
        guard let snippet = currentSnippet else { return }
        let content = snippet.content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.show(in: view, message: "There is nothing in this snippet to run")
            return
        }
        let languageID = snippet.language.id
        guard let presence = runner.runner(for: languageID) else {
            // Not a toast: this is a state the pane exists to explain, and it
            // names the interpreters it looked for so the captain knows what
            // to install. A toast would fade before they read it.
            show(state: .finished(CodeRunOutcome(
                kind: .launchFailed, status: -1,
                output: CodeRunner.noRunnerMessage(for: languageID),
                duration: 0, sandboxPath: "", truncated: false, toolDescription: "")),
                 for: snippet.key)
            return
        }

        let key = snippet.key
        show(state: .running(tool: presence.version.map { "\(presence.tool.displayName) \($0)" }
                                ?? presence.tool.displayName),
             for: key)
        refreshRunControls()
        activeRun = runner.run(content: content, languageID: languageID) { [weak self] outcome in
            guard let self else { return }
            self.activeRun = nil
            self.show(state: .finished(outcome), for: key)
            self.refreshRunControls()
            AppLog.lifecycle.info("""
                code preview: ran a \(languageID, privacy: .public) snippet - \
                \(String(describing: outcome.kind), privacy: .public) in \
                \(outcome.duration, privacy: .public)s
                """)
        }
        // `run` answers immediately when it refuses, in which case the handle
        // is nil and the completion above has already put the reason in the
        // pane - so there is nothing to correct here, only the controls.
        refreshRunControls()
    }

    private func stopRun() {
        activeRun?.cancel()
    }

    private func copyOutput() {
        let text = outputPane.outputText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show(in: view, message: "Copied the output")
    }

    private func clearOutput() {
        guard let key = currentKey else { return }
        show(state: .idle, for: key)
    }

    /// The toolbar's Format button.
    ///
    /// The formatted text replaces the snippet's content wholesale, which
    /// Monaco's own `setValue` does - and `setValue` **resets Monaco's undo
    /// stack**, so ⌘Z in the editor cannot take a format back. Rather than
    /// leave the captain with an irreversible transformation of their own
    /// code, the app supplies the undo itself: the pre-format text is right
    /// here in memory, which is exactly the condition GL-33 sets for offering
    /// an Undo at all.
    @objc private func formatTapped() {
        guard !isFormatting else { return }
        guard let snippet = currentSnippet else { return }
        let before = snippet.content
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.show(in: view, message: "There is nothing in this snippet to format")
            return
        }
        let languageID = snippet.language.id
        guard runner.formatter(for: languageID) != nil else {
            Toast.show(in: view, message: CodeRunner.noFormatterMessage(for: languageID))
            return
        }

        isFormatting = true
        refreshRunControls()
        let key = snippet.key
        runner.format(content: before, languageID: languageID) { [weak self] result in
            guard let self else { return }
            self.isFormatting = false
            self.refreshRunControls()
            // The snippet may have been closed, or a different one selected,
            // while the formatter was thinking. Applying the result to
            // whatever happens to be showing now would overwrite the wrong
            // file, so it is dropped instead.
            guard let target = self.snippet(for: key) else { return }
            switch result {
            case .failure(let failure):
                // The formatter's own complaint is the useful half - a syntax
                // error's line and column - so it goes in the pane rather than
                // a toast that truncates it.
                self.show(state: .finished(CodeRunOutcome(
                    kind: .failed, status: 1, output: failure.combined,
                    duration: 0, sandboxPath: "", truncated: false,
                    toolDescription: "")), for: key)
            case .success(let formatted):
                guard formatted != target.content else {
                    Toast.show(in: self.view, message: "Already formatted")
                    return
                }
                self.replaceContent(of: target, with: formatted)
                Toast.showUndo(in: self.view, message: "Formatted \(target.name)") { [weak self] in
                    guard let self, let restored = self.snippet(for: key) else { return }
                    self.replaceContent(of: restored, with: before)
                }
            }
        }
    }

    /// Puts `content` into a snippet, in the editor and on disk.
    ///
    /// `openSnippet` is how the page is told about a wholesale replacement -
    /// the same call `clearTapped` uses, and the only one the vendored bundle
    /// exposes for it (adding a `replaceContent` bridge command would mean
    /// regenerating the 3.8MB Monaco bundle, which needs node and network; see
    /// `Vendor/Monaco/README.md`). `snippetChanged` is then called by hand
    /// because a native-side replacement produces no page-side change event.
    private func replaceContent(of snippet: OpenSnippet, with content: String) {
        snippet.content = content
        webView.call("openSnippet", payload: [
            "id": snippet.key, "language": snippet.language.id,
            "content": content, "select": snippet.key == currentKey,
        ])
        snippetChanged(key: snippet.key, content: content)
    }

    /// The mockup's "Runners found" list, as a popover.
    ///
    /// One row per runnable language with its interpreter and version, then
    /// the formatter for the language on screen. Absent tools are **listed as
    /// absent** rather than left out - the mockup's own `ruby · absent` row,
    /// and GL-14's rule: "this app cannot run Python" and "Python is not
    /// installed here" are different sentences.
    @objc private func runnersTapped() {
        if let existing = runnersPopover, existing.isShown {
            existing.performClose(nil)
            return
        }
        let language = currentSnippet?.language ?? CodePreviewLanguage.plainText
        // Both reads are cache-only (GL-12), and the button is disabled until
        // the warm-up has landed, so this cannot show an empty list.
        let content = CodeRunnersPopoverView(
            runners: CodeToolInventory.shared.runnerInventory(),
            currentLanguage: language,
            formatter: runner.formatter(for: language.id),
            theme: theme)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = content
        content.layoutSubtreeIfNeeded()
        popover.contentSize = content.fittingSize
        runnersPopover = popover
        popover.show(relativeTo: runnersButton.bounds, of: runnersButton, preferredEdge: .maxY)
    }

    /// Records a pane state against a snippet and shows it if that snippet is
    /// the one on screen.
    private func show(state: CodeRunPaneState, for key: String) {
        if case .idle = state {
            paneStates.removeValue(forKey: key)
        } else {
            paneStates[key] = state
        }
        guard key == currentKey else { return }
        renderPane()
    }

    /// Draws whatever the selected tab's last run was - or hides the pane.
    private func renderPane() {
        let state = currentKey.flatMap { paneStates[$0] } ?? .idle
        outputPane.render(state)
        let showing: Bool
        if case .idle = state { showing = false } else { showing = true }
        outputPaneHeight?.constant = showing ? CodeRunOutputPane.preferredHeight : 0
        // Deactivate before activating: two active `statusBar.top ==` ties are
        // a required conflict, and AppKit resolves those by breaking one and
        // quietly resizing something - see gotcha (13).
        if showing {
            statusBarBelowEditor?.isActive = false
            statusBarBelowPane?.isActive = true
        } else {
            statusBarBelowPane?.isActive = false
            statusBarBelowEditor?.isActive = true
        }
        // A tie does not re-derive itself on every change (gotcha (14)), and
        // this one changes the editor's own height - so the pass is forced
        // rather than hoped for.
        view.layoutSubtreeIfNeeded()
    }

    /// Enables Run and Format for what the current snippet can actually do.
    ///
    /// A disabled button with a tooltip that says why beats a button that
    /// fails - which is the whole of F11's "handle the case where the
    /// interpreter isn't installed".
    private func refreshRunControls() {
        let language = currentSnippet?.language ?? CodePreviewLanguage.plainText
        let hasContent = !(currentSnippet?.content.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty ?? true)
        let runnerPresence = runner.runner(for: language.id)
        let formatterPresence = runner.formatter(for: language.id)
        // "Not probed yet" is a third state, and GL-14's rule applies to it:
        // it is not "not installed". Both buttons stay off and say so until
        // the warm-up lands, which is a fraction of a second after the page
        // first appears.
        let known = runner.isWarm

        runButton.isEnabled = known && runnerPresence != nil && hasContent
            && activeRun == nil && CodeSandbox.isAvailable
        formatButton.isEnabled = known && formatterPresence != nil && hasContent && !isFormatting
        runnersButton.isEnabled = known

        if !known {
            let waiting = "Checking which interpreters and formatters this machine has\u{2026}"
            runButton.toolTip = waiting
            formatButton.toolTip = waiting
            runnersButton.toolTip = waiting
            return
        }
        runnersButton.toolTip = "Which runners and formatters this machine has"

        if !CodeSandbox.isAvailable {
            runButton.toolTip = CodeRunner.sandboxMissingMessage
        } else if let runnerPresence {
            let tool = runnerPresence.version.map { "\(runnerPresence.tool.displayName) \($0)" }
                ?? runnerPresence.tool.displayName
            runButton.toolTip = "Run this snippet with \(tool), sandboxed to a temp directory "
                + "with no network and a \(Int(CodeRunner.wallClock))s limit (\u{2318}R)"
        } else {
            runButton.toolTip = CodeRunner.noRunnerMessage(for: language.id)
        }
        formatButton.toolTip = formatterPresence
            .map { "Format this snippet with \($0.tool.displayName)" }
            ?? CodeRunner.noFormatterMessage(for: language.id)
    }

    @objc private func languagePicked() {
        guard let snippet = currentSnippet else { return }
        let index = languagePicker.indexOfSelectedItem
        guard index >= 0, index < CodePreviewLanguage.all.count else { return }
        let language = CodePreviewLanguage.all[index]
        // Marked overridden **before** the no-op check, not after. Picking the
        // language a snippet is already on is not a no-op: it is the captain
        // saying "yes, really" - and the one case where that matters is
        // choosing Plain Text on a snippet that is already plain text, which
        // is exactly when detection would otherwise re-fire on the next paste
        // and overrule them.
        snippet.languageOverridden = true
        guard language.id != snippet.language.id else { return }
        apply(language: language, to: snippet, overridden: true)
        onDrillSubtitleChanged?()
    }

    // MARK: Rendering

    private func rebuildLanguagePicker() {
        let titles = CodePreviewLanguage.all.map(\.displayName)
        if languagePicker.itemTitles != titles {
            languagePicker.removeAllItems()
            languagePicker.addItems(withTitles: titles)
        }
        let current = currentSnippet?.language ?? CodePreviewLanguage.plainText
        if let index = CodePreviewLanguage.all.firstIndex(where: { $0.id == current.id }) {
            languagePicker.selectItem(at: index)
        }
    }

    private func refreshStatusBar() {
        let language = currentSnippet?.language ?? CodePreviewLanguage.plainText
        if cursor.selected > 0 {
            cursorLabel.stringValue = "Ln \(cursor.line), Col \(cursor.column)  (\(cursor.selected) selected)"
        } else {
            cursorLabel.stringValue = "Ln \(cursor.line), Col \(cursor.column)"
        }
        languageLabel.stringValue = language.displayName
        syncLabel.stringValue = syncSummary
        styleStatusLabels()
    }

    private func report(error: String) {
        lastError = error
        AppLog.lifecycle.error("code preview page error: \(error, privacy: .public)")
        onDrillSubtitleChanged?()
    }

    // MARK: Overlay

    private func showOverlay(symbol: String, title: String, body: String) {
        overlayState?.removeFromSuperview()
        let state = HelmEmptyState(symbol: symbol, title: title, body: body,
                                   size: .standard, boxed: false,
                                   hue: RailDestination.codePreview.domainHue,
                                   artwork: RailDestination.codePreview.drillHeaderArtwork)
        state.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(state)
        NSLayoutConstraint.activate([
            state.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            state.topAnchor.constraint(equalTo: overlay.topAnchor),
            state.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])
        overlayState = state
        overlay.isHidden = false
        state.applyTheme(theme)
        onDrillSubtitleChanged?()
    }

    private func hideOverlay() {
        overlay.isHidden = true
        onDrillSubtitleChanged?()
    }

    // MARK: Theme

    private func applyTheme() {
        // **`ThemeManager.swift`'s checklist item 2 - the root cause of the
        // captain's "Code Preview only half re-themes" report**, and the same
        // one-line omission `StickyBoardController` had. Without it, every
        // system-semantic colour in this subtree resolves against the OS's own
        // light/dark rather than the active Helm theme: the language popup's
        // menu, the find widget's field editor, focus rings, and - most
        // visibly on this page - the scroller chrome. The layer-backed fills
        // below always tracked the theme, which is why the page looked
        // half-right rather than plainly wrong. Every other destination in the
        // app has done this for years.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        toolbar.applyTheme(theme)
        HelmCard.applyCardSurface(to: editorCard, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        statusBar.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        statusSeparator.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        // Opaque, unlike a page's own empty-state container: this one sits
        // *over* a live web view rather than beside it, so it has to hide what
        // is behind it.
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        overlayState?.applyTheme(theme)
        outputPane.applyTheme(theme)
        styleChips()
        styleStatusLabels()
        pushTheme()
    }

    private func styleStatusLabels() {
        let muted = HelmTheme.mutedInk(theme)
        for label in [cursorLabel, languageLabel, encodingLabel, syncLabel] {
            label.font = HelmType.caption()
            label.textColor = muted
        }
        // A sync failure is the one thing in this bar the captain has to act
        // on, so it is the one thing allowed to shout.
        if case .failed = syncStatus {
            syncLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: HelmTint.critical.hex(in: theme),
                over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                theme: theme)
        }
    }

    /// Monaco has its own theme concept, and it follows this app's rather than
    /// the OS's - the whole point of the destination is that pasted code reads
    /// as part of the app. See `CodePreviewTheme` for where the colours come
    /// from and why they are the theme's own ANSI set.
    ///
    /// GL-11: log before degrading. A JS-side `setTheme` failure (the
    /// `Key.operatorToken` wire-name mismatch this exact call site once hit,
    /// see `CodePreviewTheme.Key`'s own doc comment) replies `{ok: false}`
    /// rather than crashing the page, so a fire-and-forget call here would
    /// leave Monaco silently stuck on whatever theme it last had - which is
    /// precisely what shipped undetected before. This is not fatal (the
    /// editor stays usable, just visually out of sync with the app), so it is
    /// logged rather than surfaced as an error banner.
    private func pushTheme() {
        guard webView.isReady else { return }
        webView.call("setTheme", payload: ["theme": CodePreviewTheme.palette(for: theme)]) { result in
            if case .failure(let error) = result {
                AppLog.lifecycle.error("code preview: theme push failed: \(error.message, privacy: .public)")
            }
        }
    }

    private func pushFontSize(_ size: CGFloat) {
        guard webView.isReady else { return }
        webView.call("setFontSize", payload: ["size": Double(size)])
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugWebView: CodePreviewWebView { webView }
    var debugOverlayVisible: Bool { !overlay.isHidden }
    var debugTabNames: [String] { open.map(\.name) }
    var debugCurrentName: String? { currentSnippet?.name }
    var debugCurrentLanguage: String? { currentSnippet?.language.id }
    var debugStatusLine: String { "\(cursorLabel.stringValue) | \(languageLabel.stringValue) | \(encodingLabel.stringValue) | \(syncLabel.stringValue)" }
    var debugEditorCard: NSView { editorCard }
    var debugZoomStepper: HelmZoomStepper { zoomStepper }
    func debugRestore() { restoreSnippetsIfNeeded() }
    func debugNewSnippet() { newSnippetTapped() }
    func debugSimulateEdit(name: String, content: String) {
        guard let snippet = open.first(where: { $0.name == name }) else { return }
        snippetChanged(key: snippet.key, content: content)
    }
    func debugPickLanguage(_ id: String) {
        guard let index = CodePreviewLanguage.all.firstIndex(where: { $0.id == id }) else { return }
        languagePicker.selectItem(at: index)
        languagePicked()
    }
    func debugCloseCurrent() {
        guard let key = currentKey else { return }
        closeTab(key: key)
    }
    func debugSelect(name: String) {
        guard let snippet = open.first(where: { $0.name == name }) else { return }
        select(key: snippet.key)
    }
    /// Drives the late-clone retry directly. The real trigger is a git status
    /// change, which a scratch-rooted store never produces (it has no git sync
    /// at all) - so a suite has to call the decision rather than wait for a
    /// signal that cannot arrive.
    func debugRetryRestoreAfterLateClone() { retryRestoreIfCloneArrivedLate() }
    var debugOutputPane: CodeRunOutputPane { outputPane }
    var debugCurrentSnippetKey: String? { currentKey }
    var debugStatusBarFrame: NSRect { statusBar.frame }
    static var debugCardInset: CGFloat { cardInset }
    var debugRunButtonEnabled: Bool { runButton.isEnabled }
    var debugFormatButtonEnabled: Bool { formatButton.isEnabled }
    var debugRunButtonTooltip: String? { runButton.toolTip }
    var debugFormatButtonTooltip: String? { formatButton.toolTip }
    var debugOutputPaneHeight: CGFloat { outputPaneHeight?.constant ?? -1 }
    var debugOutputPaneTopGap: CGFloat { outputPaneTopGap?.constant ?? -1 }
    var debugIsRunning: Bool { activeRun != nil }
    func debugRun() { runTapped() }
    func debugFormat() { formatTapped() }
    func debugStopRun() { stopRun() }
    func debugClearOutput() { clearOutput() }
    func debugRefreshRunControls() { refreshRunControls() }
    var debugRunnersPopover: NSPopover? { runnersPopover }
    func debugShowRunners() { runnersTapped() }
    /// Drives the pane through a state without running anything, so a suite
    /// can assert every rendering - including the ones that need a tool this
    /// machine may not have.
    func debugShowPane(_ state: CodeRunPaneState) {
        guard let key = currentKey else { return }
        show(state: state, for: key)
    }
    func debugRename(from: String, to: String) {
        guard let snippet = open.first(where: { $0.name == from }) else { return }
        renameTab(key: snippet.key, to: to)
    }
    #endif
}

// MARK: - The page's file-drop root (review #3's UX11)

/// The Code Preview page's root view, which accepts dropped files.
///
/// The same four-override recipe `LogAnalyzerController`'s own drop well uses,
/// and deliberately the same shape rather than a second one - a drop target
/// that highlighted differently on two pages of one app would read as two
/// different affordances.
///
/// It accepts **any** file and lets the controller decide: the filter that
/// matters is "is this readable text, and is it small enough", which cannot be
/// answered from an extension. Refusing by extension would also mean refusing
/// the extension-less files (`Makefile`, `Dockerfile`, a shell script) that are
/// exactly what someone drags onto a code viewer.
final class CodePreviewDropView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL] ?? []).filter { url in
            // A directory is not something this page can open, and dropping a
            // folder of 400 files would open 400 tabs.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !urls(from: sender).isEmpty
        isHighlighted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        let files = urls(from: sender)
        guard !files.isEmpty else { return false }
        onDropFiles?(files)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        let accent = HelmTheme.nsColor(ThemeManager.shared.theme.accentHex)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                xRadius: HelmMetrics.rCard, yRadius: HelmMetrics.rCard)
        accent.withAlphaComponent(0.08).setFill()
        path.fill()
        accent.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    #if FM_SELFTESTS
    /// So a suite can drive the real accept/refuse decision without a live
    /// drag session, which needs a window server and a mouse.
    func debugAcceptedURLs(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    }
    #endif
}
