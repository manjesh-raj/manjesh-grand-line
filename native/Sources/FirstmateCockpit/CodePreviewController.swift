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
    private lazy var copyButton = HelmPageToolbar.labeledButton(
        symbol: "doc.on.doc", title: "Copy",
        tooltip: "Copy this snippet to the clipboard",
        target: self, action: #selector(copyTapped))
    private lazy var clearButton = HelmPageToolbar.labeledButton(
        symbol: "eraser", title: "Clear",
        tooltip: "Empty this snippet, keeping the tab",
        target: self, action: #selector(clearTapped))

    private let editorCard = NSView()
    private let webView = CodePreviewWebView()
    private let overlay = NSView()
    private var overlayState: HelmEmptyState?

    private let statusBar = NSView()
    private let statusSeparator = NSView()
    private let cursorLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let encodingLabel = NSTextField(labelWithString: "UTF-8")
    private let syncLabel = NSTextField(labelWithString: "")

    private var wrapOn = false
    private var themeObservation: ThemeObservation?
    private var fontObservation: FontSizeObservation?

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        root.wantsLayer = true
        view = root

        buildToolbar(in: root)
        buildEditor(in: root)
        buildStatusBar(in: root)

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
            for control in [plusButton, findButton, wrapButton, copyButton, clearButton] {
                control.isEnabled = false
            }
            languagePicker.isEnabled = false
        }
        rebuildLanguagePicker()
        applyTheme()
        refreshStatusBar()
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

    /// Called by the app delegate on quit, so the last few keystrokes before
    /// ⌘Q are written and committed like every other edit.
    func shutdown() {
        flushPendingEdits()
        store.gitSync?.commitAndPushNow()
    }

    private func flushPendingEdits() {
        guard webView.isReady else { return }
        webView.call("flush")
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

        toolbar.setTrailing(HelmPageToolbar.group([
            languagePicker, findButton, wrapButton, copyButton, clearButton,
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
            statusBar.topAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: Self.cardInset),

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

        let saved = store.list()
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
        return snippet
    }

    private func select(key: String) {
        guard snippet(for: key) != nil else { return }
        currentKey = key
        webView.call("selectSnippet", payload: ["id": key])
        styleChips()
        rebuildLanguagePicker()
        refreshStatusBar()
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
        store.save(name: snippet.name, content: content)
        snippet.persisted = true
        refreshStatusBar()
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
        }
        if overridden { snippet.languageOverridden = true }
        webView.call("setLanguage", payload: ["id": snippet.key, "language": language.id])
        rebuildLanguagePicker()
        refreshStatusBar()
    }

    // MARK: Actions

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

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(snippet.name)?"
        alert.informativeText = "This empties the snippet but keeps the tab. \u{2318}Z in the editor can undo it."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        snippet.content = ""
        webView.call("openSnippet", payload: [
            "id": snippet.key, "language": snippet.language.id, "content": "", "select": true,
        ])
        if snippet.persisted { store.save(name: snippet.name, content: "") }
        refreshStatusBar()
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
                                   hue: RailDestination.codePreview.domainHue)
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
    private func pushTheme() {
        guard webView.isReady else { return }
        webView.call("setTheme", payload: ["theme": CodePreviewTheme.palette(for: theme)])
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
    func debugRename(from: String, to: String) {
        guard let snippet = open.first(where: { $0.name == from }) else { return }
        renameTab(key: snippet.key, to: to)
    }
    #endif
}
