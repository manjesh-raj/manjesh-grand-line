// Manjesh Grand Line - native macOS app.
//
// The `.whiteboard` destination: a real, embedded Excalidraw canvas, plus one
// AI action that draws a diagram onto it from a plain-English description.
//
// ## Why the canvas is embedded rather than built
//
// Excalidraw (MIT) already is an infinite hand-drawn canvas with the whole
// toolset - shapes, arrows with real bindings, text, freehand, multi-select,
// grouping, undo, export, a library. Reimplementing that in AppKit would be a
// large, permanently-behind effort for something a mature library does well, so
// this destination hosts the real thing in a `WKWebView` and adds only what
// this app can uniquely contribute: the theme, the chrome, and the Claude call.
// The bundle is vendored and loaded from disk - see
// `native/Vendor/Excalidraw/README.md` for provenance and
// `WhiteboardAssets.swift` for how it is found. There is no CDN and no network
// path; the page's own CSP makes that structural rather than a promise.
//
// ## The page has no chrome of its own, on purpose
//
// Excalidraw owns the entire body, edge to edge inside one card. There is no
// `HelmPageToolbar` here: every canvas action (tools, colours, zoom, undo,
// export, the context menu) is already in Excalidraw's own toolbar a few
// points below, and a second strip repeating it is exactly the duplication
// §6.4 exists to remove. This page's three *page-level* actions - Generate
// diagram, Fit to content, Clear - are hoisted into the shell's drill header
// cluster instead, like Review's Refresh and Hosts' add buttons.
//
// ## What it does not do, stated rather than left to be discovered
//
// A board is not persisted to disk. It survives navigating away and coming
// back - the destination stays mounted for the process's life, which is the
// case that matters in a session - but a relaunch starts a fresh board.
// Persisting it would mean choosing a store, a format and a backup story
// (`BackupData`'s bundle) for a scratch surface, and half-persistence (a board
// that sometimes comes back) would be worse than none. Excalidraw's own
// "Save to file"/"Open" actions are available in the canvas for a board worth
// keeping, and that is the honest answer until the captain asks for more.

import AppKit

final class WhiteboardController: NSViewController, DaylightDrillActions {

    private var theme: HelmTheme = ThemeManager.shared.theme

    private let webView = WhiteboardWebView()
    /// Daylight §7's card around an embedded surface - the same treatment (and
    /// the same reason it carries no shadow: a clipping layer casts none) as
    /// Docs' playbook card.
    private let canvasCard = NSView()
    private static let cardInset: CGFloat = HelmMetrics.s3

    /// Shown until the canvas reports ready, and again - with different words -
    /// if the vendored bundle is missing entirely.
    private let overlay = NSView()
    private var overlayState: HelmEmptyState?

    private let composer = WhiteboardComposerController()
    /// The deterministic sibling of `composer` - same canvas, same sink, no
    /// model. See `WhiteboardDSLPopover.swift`'s header for why it is a second
    /// popover on this page rather than a destination of its own.
    private let dsl = WhiteboardDSLController()

    private lazy var generateButton = HelmPageToolbar.labeledButton(
        symbol: "sparkles", title: "Generate diagram",
        tooltip: "Describe a diagram and have Claude draw it here",
        target: self, action: #selector(generateTapped))
    private lazy var dslButton = HelmPageToolbar.labeledButton(
        symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Draw from text",
        tooltip: "Type a flowchart or sequence diagram and draw it instantly - no model, no waiting",
        target: self, action: #selector(dslTapped))
    private lazy var fitButton = HelmPageToolbar.iconButton(
        symbol: "arrow.up.left.and.arrow.down.right",
        tooltip: "Fit the board to the window",
        target: self, action: #selector(fitTapped))
    private lazy var clearButton = HelmPageToolbar.iconButton(
        symbol: "trash", tooltip: "Clear the board",
        target: self, action: #selector(clearTapped))

    /// The live element count, refreshed whenever something changes it. Read by
    /// the drill subtitle; never polled.
    private var elementCount = 0
    private var lastError: String?

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?

    /// `dslButton` leads, ahead of its AI sibling: it is the faster path and
    /// the one that works offline, so it is the one to reach for first when
    /// the captain already knows what connects to what.
    var drillHeaderActions: [NSView] { [dslButton, generateButton, fitButton, clearButton] }

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        if !WhiteboardAssets.isAvailable { return "The Excalidraw bundle is missing" }
        guard webView.isReady else { return "Starting the canvas…" }
        if elementCount == 0 { return "An empty board \u{00B7} everything stays on this machine" }
        let noun = elementCount == 1 ? "1 element" : "\(elementCount) elements"
        return "\(noun) \u{00B7} everything stays on this machine"
    }

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        root.wantsLayer = true
        view = root

        canvasCard.translatesAutoresizingMaskIntoConstraints = false
        canvasCard.wantsLayer = true
        canvasCard.layer?.masksToBounds = true
        root.addSubview(canvasCard)
        canvasCard.addSubview(webView)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        canvasCard.addSubview(overlay)

        NSLayoutConstraint.activate([
            canvasCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardInset),
            canvasCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardInset),
            canvasCard.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardInset),
            canvasCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardInset),

            webView.leadingAnchor.constraint(equalTo: canvasCard.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: canvasCard.trailingAnchor),
            webView.topAnchor.constraint(equalTo: canvasCard.topAnchor),
            webView.bottomAnchor.constraint(equalTo: canvasCard.bottomAnchor),

            overlay.leadingAnchor.constraint(equalTo: canvasCard.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: canvasCard.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: canvasCard.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: canvasCard.bottomAnchor),
        ])

        webView.onReady = { [weak self] in self?.canvasBecameReady() }
        webView.onPageError = { [weak self] message in self?.report(error: message) }

        composer.onGenerated = { [weak self] elements, append, done in
            self?.load(elements: elements, append: append, completion: done)
        }
        composer.onBoardSnapshot = { [weak self] done in
            self?.snapshotBoard(completion: done)
        }
        // The *same* sink the AI path uses, deliberately: one place turns a
        // skeleton into elements on this canvas, so the two paths cannot drift
        // apart about what "insert" means or how a canvas-side refusal is
        // reported.
        dsl.onInsert = { [weak self] elements, append, done in
            self?.load(elements: elements, append: append, completion: done)
        }

        ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }

        // The page is only loaded here, on the destination's first mount, and
        // never restarted afterwards - so a session that never opens the
        // Whiteboard never starts a web content process at all, and a second
        // visit never discards the captain's board.
        if webView.activate() {
            showOverlay(symbol: "scribble.variable",
                        title: "Starting the canvas\u{2026}",
                        body: "Excalidraw is loading from this machine. Nothing is fetched from the network.")
        } else {
            showOverlay(symbol: "exclamationmark.triangle",
                        title: "No whiteboard bundle",
                        body: WhiteboardAssets.missingBundleMessage)
            dslButton.isEnabled = false
            generateButton.isEnabled = false
            fitButton.isEnabled = false
            clearButton.isEnabled = false
        }
        applyTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Both halves of the gate re-derive themselves from live state, so a
        // visit only ever corrects a stale reading.
        webView.refreshDisplayGating()
        refreshElementCount()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        composer.close()
        dsl.close()
    }

    // MARK: Canvas

    private func canvasBecameReady() {
        hideOverlay()
        lastError = nil
        pushTheme()
        refreshElementCount()
    }

    private func load(elements: [[String: Any]], append: Bool, completion: @escaping (String?) -> Void) {
        webView.call("loadScene", payload: ["elements": elements, "mode": append ? "append" : "replace"]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let body):
                self.elementCount = (body["count"] as? Int) ?? self.elementCount
                self.lastError = nil
                self.onDrillSubtitleChanged?()
                self.refreshElementCount()
                completion(nil)
            case .failure(let error):
                completion(error.message)
            }
        }
    }

    /// Reads the live board back as element skeletons, for a refine turn.
    ///
    /// Taken fresh on every turn rather than cached from the last generation:
    /// the captain can move, delete and draw with Excalidraw's own tools
    /// between two AI turns, and a refinement built from a stale copy would
    /// silently undo whatever they did in between.
    private func snapshotBoard(completion: @escaping (Result<[[String: Any]], WhiteboardBridgeError>) -> Void) {
        guard webView.isReady else {
            completion(.failure(WhiteboardBridgeError(message: "the canvas is still starting up")))
            return
        }
        webView.call("snapshot") { result in
            switch result {
            case .success(let body):
                let elements = (body["elements"] as? [[String: Any]]) ?? []
                completion(.success(elements))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func refreshElementCount() {
        guard webView.isReady else { return }
        webView.call("stats") { [weak self] result in
            guard let self, case .success(let body) = result else { return }
            let count = (body["count"] as? Int) ?? 0
            guard count != self.elementCount else { return }
            self.elementCount = count
            self.onDrillSubtitleChanged?()
        }
    }

    private func report(error: String) {
        lastError = error
        AppLog.lifecycle.error("whiteboard page error: \(error, privacy: .public)")
        onDrillSubtitleChanged?()
    }

    // MARK: Actions

    @objc private func generateTapped() {
        // One popover at a time: they write to the same board and both want
        // the keyboard, so a second one opening over the first is confusing
        // rather than useful.
        dsl.close()
        composer.toggle(relativeTo: generateButton)
    }

    @objc private func dslTapped() {
        composer.close()
        dsl.toggle(relativeTo: dslButton)
    }

    /// The Straw Hat crew's "draw it out" handoff (phase 3, M3.1 / M3.2) -
    /// Usopp pointing an idea at this page's own diagram generator.
    ///
    /// **The same entry point the toolbar button uses**, not a second one:
    /// one `composer.toggle(relativeTo:)` call, the same popover, the same
    /// Generate button, the same `WhiteboardDiagram.run`. All this adds is
    /// arriving with the description already typed in - which is the app's
    /// own convention for a deep link (every `open*(id:)` wrapper in
    /// `AppShellController` reveals the record rather than only selecting its
    /// page), and is what stops a handoff from discarding the very idea it
    /// was about.
    ///
    /// Nothing is generated: the prefill is text in a field the captain reads
    /// and edits, and Generate is still their own press.
    /// Returns whether the composer actually opened. A caller that only
    /// wanted the page (or arrived while this destination is not showing) is
    /// told rather than left assuming.
    @discardableResult
    func openDiagramComposer(prefill: String?) -> Bool {
        // **`NSPopover.show(relativeTo:of:preferredEdge:)` raises
        // `NSInvalidArgumentException` - "view has no window" - rather than
        // no-opping**, and `generateButton` lives in the shell's *drill
        // header*, which carries the actions of whichever destination is
        // currently showing. So it genuinely has no window whenever this page
        // is not the one on screen.
        //
        // Found by an injected regression rather than by reading the code: a
        // deliberately broken version of `AppShellController.
        // openDestinationForCrew` reached here for a non-Whiteboard handoff
        // and took the whole process down with an uncaught exception. In
        // production that path is guarded (`dest == .whiteboard` plus a
        // `show(.whiteboard)` immediately before), but "should be in a window
        // by now" is not a safe assumption to hand an API that throws - this
        // app has crashed on that exact class once before (a cross-view
        // constraint activated one line too early, `fm/grandline-docs-no-window-fix`).
        //
        // The prefill still lands either way, so a captain who navigates here
        // themselves finds the idea already typed in.
        if let prefill, !prefill.isEmpty {
            composer.setPrompt(prefill)
        }
        guard generateButton.window != nil else {
            AppLog.ui.info("whiteboard: diagram composer asked for while the page is not showing - left closed")
            return false
        }
        // Idempotent for the handoff's sake: `toggle` would *close* a composer
        // that a captain already had open, which is the opposite of what a
        // "draw it out" link says it does.
        if !composer.isShown {
            composer.toggle(relativeTo: generateButton)
        }
        return true
    }

    @objc private func fitTapped() {
        webView.call("fitToContent")
    }

    @objc private func clearTapped() {
        // A board can hold real work, and unlike Excalidraw's own in-canvas
        // "Reset the canvas" this button is one click from a header, so it asks
        // first. `Toast.showUndo` is deliberately not used: the elements are
        // gone from the page's memory once cleared, so an "Undo" here could
        // only lie - Excalidraw's own ⌘Z is the real undo and still works.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear the whiteboard?"
        alert.informativeText = elementCount > 0
            ? "This removes all \(elementCount) elements from the board. \u{2318}Z on the canvas can undo it."
            : "The board is already empty."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        webView.call("clear") { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.elementCount = 0
                self.onDrillSubtitleChanged?()
                // A cleared board has nothing left to refine, so the diagram
                // conversation ends with it - otherwise the next visit to the
                // composer would offer to revise a diagram that is gone.
                self.composer.endSession(
                    note: "Board cleared. The next diagram starts a new conversation.")
            }
        }
    }

    // MARK: Overlay

    private func showOverlay(symbol: String, title: String, body: String) {
        overlayState?.removeFromSuperview()
        let state = HelmEmptyState(symbol: symbol, title: title, body: body,
                                   size: .standard, boxed: false,
                                   hue: RailDestination.whiteboard.domainHue,
                                   artwork: RailDestination.whiteboard.drillHeaderArtwork)
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
        // `ThemeManager.swift`'s checklist item 2 - Sticky Board and Code
        // Preview shipped this same gap and it produced the identical "half
        // themed" report: layer-backed fills (this page's root, card,
        // overlay) already tracked the theme, so a self-test asserting only
        // those colours would still pass, while every system-semantic colour
        // in this subtree (the composer's scroller/field editor/checkbox
        // chrome, focus rings) followed the OS's own light/dark instead of
        // the in-app one. Force it here too.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        HelmCard.applyCardSurface(to: canvasCard, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        overlay.wantsLayer = true
        // Opaque, unlike Docs' transparent empty-state container: this one sits
        // *over* a live web view rather than beside it, so it has to hide what
        // is behind it.
        overlay.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        overlayState?.applyTheme(theme)
        pushTheme()
    }

    /// Excalidraw has its own light/dark concept, and it follows this app's
    /// rather than the OS's - a light Helm theme with a dark canvas (or the
    /// reverse) is the jarring outcome, and the whole point of the destination
    /// is that it reads as part of the app.
    private func pushTheme() {
        guard webView.isReady else { return }
        webView.call("setTheme", payload: ["theme": theme.mode == .dark ? "dark" : "light"])
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugWebView: WhiteboardWebView { webView }
    var debugCanvasCard: NSView { canvasCard }
    var debugOverlayVisible: Bool { !overlay.isHidden }
    var debugComposer: WhiteboardComposerController { composer }
    func debugLoad(elements: [[String: Any]], append: Bool, completion: @escaping (String?) -> Void) {
        load(elements: elements, append: append, completion: completion)
    }
    func debugSnapshotBoard(completion: @escaping (Result<[[String: Any]], WhiteboardBridgeError>) -> Void) {
        snapshotBoard(completion: completion)
    }
    /// Re-themes this instance directly, bypassing `ThemeManager.shared.
    /// setTheme` - which persists to real `UserDefaults` - so a self-test
    /// theme sweep never clobbers the captain's own saved preference on a
    /// shared dev machine (`StickyBoardController.debugApplyTheme`/
    /// `UnifiedSearch.swift`'s own `debugApplyTheme` establish this pattern).
    func debugApplyTheme(_ theme: HelmTheme) {
        self.theme = theme
        applyTheme()
    }
    #endif
}
