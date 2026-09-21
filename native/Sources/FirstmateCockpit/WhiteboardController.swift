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
    /// F15's capture verb. Labeled rather than an icon because it is the one
    /// action on this page that reaches *outside* the app, and a camera glyph
    /// alone does not say that it is a region drag rather than a photo picker.
    private lazy var captureButton = HelmPageToolbar.labeledButton(
        symbol: "camera.viewfinder", title: "Capture region",
        tooltip: "Drag a region of the screen onto this board (\u{2318}\u{21E7}S)",
        target: self, action: #selector(captureTapped))
    /// The other end of F15: flatten the board - the capture plus every
    /// annotation over it - and put it on the clipboard.
    private lazy var copyButton = HelmPageToolbar.labeledButton(
        symbol: "doc.on.doc", title: "Copy image",
        tooltip: "Copy the whole board to the clipboard as a PNG",
        target: self, action: #selector(copyImageTapped))
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
    /// `captureButton` sits between the two authoring buttons and the two icon
    /// ones: it is a labeled verb like them, and a capture is where an F15
    /// board starts, so the cluster reads capture -> copy alongside the
    /// canvas's own tools rather than burying either in an icon.
    var drillHeaderActions: [NSView] {
        [dslButton, generateButton, captureButton, copyButton, fitButton, clearButton]
    }

    var drillHeaderSubtitle: String? {
        if let lastError { return lastError }
        if !WhiteboardAssets.isAvailable { return "The Excalidraw bundle is missing" }
        guard webView.isReady else { return "Starting the canvas…" }
        if elementCount == 0 { return "An empty board \u{00B7} everything stays on this machine" }
        let noun = elementCount == 1 ? "1 element" : "\(elementCount) elements"
        // F15: once something has been captured onto this board, the thing
        // worth saying is what was captured - the size the captain dragged,
        // and whether it carries Retina detail - beside the count they can
        // already see. The standing "stays on this machine" clause sharpens
        // into the promise that actually matters for a screenshot, which is
        // the one the captain's own reviewed mockup prints.
        if let lastCapture {
            return "\(lastCapture) \u{00B7} \(noun) \u{00B7} the original is never written to disk"
        }
        return "\(noun) \u{00B7} everything stays on this machine"
    }

    /// `WhiteboardCaptureScene.summary` for the most recent capture on this
    /// board, or `nil` when nothing has been captured this session. Cleared by
    /// Clear, because the subtitle would otherwise go on describing an image
    /// that is no longer on the board.
    private var lastCapture: String?
    /// Guards a second `screencapture` from being launched while the first is
    /// still waiting for a drag. Two system region pickers at once is a state
    /// macOS handles badly and the captain cannot reason about.
    private var captureInFlight = false

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
        dsl.onInsert = { [weak self] elements, files, append, done in
            self?.load(elements: elements, files: files, append: append, completion: done)
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

    private func load(elements: [[String: Any]],
                      files: [[String: Any]] = [],
                      append: Bool,
                      completion: @escaping (String?) -> Void) {
        var payload: [String: Any] = ["elements": elements, "mode": append ? "append" : "replace"]
        // Only sent when there is artwork to send, so a build with no icons -
        // and every pre-icon saved board reloaded through this path - hands the
        // page exactly the payload it always got.
        if !files.isEmpty { payload["files"] = files }
        webView.call("loadScene", payload: payload) { [weak self] result in
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

    // MARK: F15 - capture and copy

    /// The seam every self-test replaces: how a region actually gets captured.
    /// Production leaves it `nil` and the real `ScreenRegionCapture` runs; a
    /// suite installs a closure and drives the whole pipeline with bytes it
    /// made itself, so nothing about the flow needs a screen to be exercised.
    var captureProvider: ((@escaping (ScreenRegionCapture.Result) -> Void) -> Void)?

    /// Where a copied image is written. Injectable for the same reason - a
    /// suite must never clobber the captain's real clipboard.
    var copyPasteboard: NSPasteboard = .general

    @objc func captureTapped() {
        // GL-09. `screencapture -i` draws its crosshair over the whole display,
        // including this app's own lock overlay - see `AppLockedSurface.
        // screenCapture`.
        guard AppLockGate.shared.allows(.screenCapture) else { return }
        guard !captureInFlight else { return }
        guard webView.isReady else {
            Feedback.report("The canvas is still starting up - try that again in a moment.",
                            kind: .warning, persistence: .transient, in: view)
            return
        }
        captureInFlight = true
        captureButton.isEnabled = false

        let provider = captureProvider ?? { done in ScreenRegionCapture.capture(completion: done) }
        provider { [weak self] result in
            guard let self else { return }
            self.captureInFlight = false
            self.captureButton.isEnabled = true
            switch result.outcome {
            case .cancelled:
                // Deliberately silent. Escaping out of a region drag is a
                // decision, not an error, and a toast for it would fire every
                // time the captain changed their mind.
                break
            case .failed(let message):
                // `.lasting`: a capture that could not run is still true after
                // a toast fades, and the captain will want to know why the
                // board stayed empty (GL-30's own dividing line).
                Feedback.report(message, kind: .failure, persistence: .lasting,
                                in: self.view, id: "whiteboard.capture.failed")
                AppLog.ui.error("whiteboard capture failed: \(message, privacy: .public)")
            case .captured:
                guard let image = result.image else { return }
                self.place(capture: image)
            }
        }
    }

    /// Encode, find the bottom of what is already on the board, and insert.
    ///
    /// The board is read back first rather than assumed empty: a capture
    /// appends *below* whatever is there, so a captain who already drew
    /// something does not have it overwritten by a screenshot dropped at the
    /// origin. A snapshot that fails is not fatal - the capture still lands, at
    /// the origin, which is what an empty board would have done anyway.
    private func place(capture image: NSImage) {
        guard let encoded = WhiteboardCaptureScene.pngCapture(from: image) else {
            Feedback.report("That capture could not be read as an image.",
                            kind: .failure, persistence: .lasting,
                            in: view, id: "whiteboard.capture.failed")
            return
        }
        snapshotBoard { [weak self] result in
            guard let self else { return }
            let bottom: Double?
            switch result {
            case .success(let elements): bottom = WhiteboardCaptureScene.boardBottom(of: elements)
            case .failure: bottom = nil
            }
            let fileID = WhiteboardCaptureScene.fileID()
            let payload = WhiteboardCaptureScene.payload(for: encoded, fileID: fileID, boardBottom: bottom)
            self.load(elements: payload.elements, files: payload.files, append: true) { error in
                if let error {
                    Feedback.report("The capture could not be placed on the board - \(error)",
                                    kind: .failure, persistence: .lasting,
                                    in: self.view, id: "whiteboard.capture.failed")
                    return
                }
                Feedback.clear(id: "whiteboard.capture.failed")
                self.lastCapture = WhiteboardCaptureScene.summary(for: encoded)
                self.onDrillSubtitleChanged?()
                Feedback.report("Captured - annotate it, then Copy image.",
                                kind: .done, persistence: .transient, in: self.view)
            }
        }
    }

    @objc func copyImageTapped() {
        // GL-09: the board behind the lock overlay is still the captain's, and
        // this writes it to a clipboard anything can read.
        guard AppLockGate.shared.allows(.whiteboardCopy) else { return }
        guard webView.isReady else {
            Feedback.report("The canvas is still starting up - try that again in a moment.",
                            kind: .warning, persistence: .transient, in: view)
            return
        }
        // `maxWidthOrHeight` is bounded from here rather than left to the page:
        // the PNG comes back base64-encoded inside one bridge reply, so an
        // unbounded export is an unbounded string (GL-35).
        webView.call("exportImage", payload: ["maxWidthOrHeight": 4096, "padding": 16]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Feedback.report("The board could not be copied - \(error.message)",
                                kind: .failure, persistence: .transient, in: self.view)
            case .success(let body):
                guard let url = body["dataURL"] as? String,
                      let png = WhiteboardCaptureScene.png(fromDataURL: url) else {
                    Feedback.report("The board exported something that was not a PNG.",
                                    kind: .failure, persistence: .transient, in: self.view)
                    return
                }
                let written = WhiteboardCaptureScene.writeToPasteboard(png: png, pasteboard: self.copyPasteboard)
                guard written > 0 else {
                    Feedback.report("The image could not be written to the clipboard.",
                                    kind: .failure, persistence: .transient, in: self.view)
                    return
                }
                let width = (body["width"] as? Int) ?? 0
                let height = (body["height"] as? Int) ?? 0
                let size = (width > 0 && height > 0) ? " (\(width) \u{00D7} \(height))" : ""
                Feedback.report("Board copied as a PNG\(size).",
                                kind: .done, persistence: .transient, in: self.view)
            }
        }
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
        // G3: themed; Return still clears, as it did here.
        guard HelmConfirm.confirm(
            title: "Clear the whiteboard?",
            body: elementCount > 0
                ? "This removes all \(elementCount) elements from the board. \u{2318}Z on the canvas can undo it."
                : "The board is already empty.",
            confirmTitle: "Clear",
            destructive: true,
            symbol: "eraser.fill",
            hue: .rose) else { return }
        webView.call("clear") { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.elementCount = 0
                // The capture is gone with everything else, so the subtitle
                // must stop describing it (GL-14: a stale reading is worse
                // than none).
                self.lastCapture = nil
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
        webView.call("setTheme", payload: [
            "theme": theme.mode == .dark ? "dark" : "light",
            "island": Self.islandTokens(for: theme),
        ])
    }

    /// M1 of the UI modernization audit (§3M): "match Excalidraw's island
    /// radius/fill via its CSS custom properties if exposed".
    ///
    /// They are exposed - `.Island` reads `--island-bg-color`,
    /// `--border-radius-lg` and `--shadow-island` off the document root - so
    /// this is the cheap seam-hider that finding asks for and needed no patch
    /// to the vendored bundle. Excalidraw's zoom pill, its library panel and
    /// its stats panel are all `.Island`s, which is the chrome the report
    /// measured as "differing" beside a themed native page.
    ///
    /// Three deliberate calls in here:
    ///
    /// - **The fill is `chromeBackgroundHex`, this app's own card token**, so
    ///   an island reads as the same surface as every `HelmCard` around it -
    ///   in all fourteen palettes, not just the Daylight family, because it
    ///   resolves through `HelmTheme` rather than a literal.
    /// - **The radius is `rCard` (12), not `dSurface` (16).** `--border-radius-lg`
    ///   is Excalidraw's own *large* radius token and has 47 usages inside
    ///   that bundle, several of them small controls; 12 is this app's card
    ///   radius and a modest, coherent step up from Excalidraw's own 8, where
    ///   16 would visibly bloat its smaller buttons. Excalidraw's
    ///   `--border-radius-md` is left alone - a third-party widget's own
    ///   small-control radius is its business.
    /// - **The shadow is `HelmCard.elevation`'s resting level, re-expressed as
    ///   CSS**, so an island floats by the same amount a card does rather than
    ///   by Excalidraw's own three-layer stack. Two numbers rather than a
    ///   faithful port: an `NSShadow`'s blur radius is roughly twice a CSS
    ///   blur, which is the one conversion this mapping has to make.
    static func islandTokens(for theme: HelmTheme) -> [String: String] {
        let shadow = HelmCard.elevation(for: theme)
        let blur = shadow.shadowBlurRadius / 2
        let dy = -shadow.shadowOffset.height
        let colour = shadow.shadowColor ?? .black
        return [
            "bg": cssHex(theme.chromeBackgroundHex),
            "radius": "\(HelmMetrics.rCard)px",
            "shadow": "0px \(fmt(dy))px \(fmt(blur))px 0px \(cssRGBA(colour))",
        ]
    }

    private static func cssHex(_ hex: String) -> String {
        hex.hasPrefix("#") ? hex : "#" + hex
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func cssRGBA(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return "rgba(\(r), \(g), \(b), \(fmt(c.alphaComponent)))"
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugWebView: WhiteboardWebView { webView }
    var debugCanvasCard: NSView { canvasCard }
    var debugOverlayVisible: Bool { !overlay.isHidden }
    var debugComposer: WhiteboardComposerController { composer }
    /// F15: what the drill subtitle is saying about the last capture, which is
    /// also the signal `WhiteboardCaptureViewSelfTest` waits on to know a
    /// capture finished landing.
    var debugLastCaptureSummary: String? { lastCapture }
    func debugLoad(elements: [[String: Any]], append: Bool, completion: @escaping (String?) -> Void) {
        load(elements: elements, append: append, completion: completion)
    }
    func debugLoadWithFiles(elements: [[String: Any]], files: [[String: Any]], append: Bool,
                            completion: @escaping (String?) -> Void) {
        load(elements: elements, files: files, append: append, completion: completion)
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
