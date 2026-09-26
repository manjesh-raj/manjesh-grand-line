// Grand Line - native macOS app.
//
// The `.docs` rail destination - the embedded DevOps Playbook viewer.
//
// `fm/grandline-docs-knowledge-foundation` ("Knowledge and speed", phase 1)
// originally restructured this from a single embedded browser into a
// multi-tab page (Playbook / Runbooks / Postmortems), and several later
// tasks built real CRUD and rendering on top of the latter two - see
// AGENTS.md's "Knowledge" section for that history. `fm/grandline-docs-
// split-runbooks-postmortems` un-did the tabbing: Runbooks and Postmortems
// are now their own top-level destinations (`RunbooksController` /
// `PostmortemsController`, in the Stores space alongside this one, Vault,
// Tools and Dictation), and this page is back to being exactly what it
// started as - the locked-down embedded `WKWebView` onto the captain's real
// DevOps Playbook. Phase 7 of the UI audit moved its back/forward/reload/
// Open-Live-Site cluster out of a second 40pt bar of its own and into the
// shared `HelmPageToolbar` (see `buildToolbar()`); the web view, its
// navigation delegate, and the local-only load path are otherwise untouched
// by any of this history.
//
// Root view follows this app's own documented gotcha #8 (`AGENTS.md`): a
// plain `NSView` with `wantsLayer`/`HelmTheme` background, not
// `NSVisualEffectView` vibrancy.

import AppKit
import WebKit

final class DocsController: NSViewController, DaylightDrillActions {
    /// UX14: the bell entry a failed docs sync leaves, cleared by the next
    /// sync that works. A stable id is what lets a recurring failure update
    /// one entry rather than stack a new one every attempt.
    private static let syncFailureNotificationID = "docs-sync-failed"


    static let liveSiteURL = URL(string: "https://manjesh-raj.github.io/devops-playbook/")!

    /// The shared page toolbar (Phase 7) - see `buildToolbar()`. Its trailing
    /// slot holds the browser nav triplet (back/forward/reload); the
    /// page-level "Open Live Site" action lives in the shell's drill header
    /// cluster instead (§6.4).
    private let pageToolbar = HelmPageToolbar()
    private let playbookActions = NSStackView()

    private var webView: DocsWebView!
    private var backButton: HelmButton!
    private var forwardButton: HelmButton!
    private var reloadButton: HelmButton!
    private let openLiveButton = HelmButton(title: "", variant: .secondary, symbol: "arrow.up.forward.square")
    private let emptyStateContainer = NSView()
    /// §7's radius-16 card around the embedded playbook.
    private let playbookCard = NSView()
    private static let playbookCardInset: CGFloat = HelmMetrics.s3
    private var playbookEmptyState: HelmEmptyState?
    private let syncButton = HelmButton(title: "", variant: .primary)
    private let syncSpinner = HelmProgressBar.inlineActivity(hue: RailDestination.docs.domainHue)
    private var isSyncing = false

    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Drill header (Daylight §6.4)

    /// Set by `AppShellController`. Called - never written to the header
    /// directly - whenever this page's own live sync state changes: the
    /// header belongs to the shell, and two owners of one view is how they
    /// start disagreeing.
    var onDrillSubtitleChanged: (() -> Void)?

    /// §6.4's action cluster: this page's one page-level action, "Open Live
    /// Site". Back/forward/reload stay in the page toolbar rather than
    /// hoisted here, since they act on the embedded web view a few points
    /// below them.
    var drillHeaderActions: [NSView] { [openLiveButton] }

    /// §6.4's live subtitle - the real sync state, never fabricated: an
    /// unsynced playbook says so rather than claiming an offline copy exists.
    var drillHeaderSubtitle: String? {
        DocsStore.isSynced ? "DevOps Playbook \u{00B7} offline copy" : "Playbook not synced yet"
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        root.addSubview(pageToolbar)
        // `pageToolbar`'s own internal constraints are self-contained, but
        // these three reference `root`, so they can only be activated once it
        // is actually a subview.
        NSLayoutConstraint.activate([
            pageToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            pageToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        buildToolbar()

        buildPlaybookContainer(in: root)

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        DocsSyncCenter.observe { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.loadDocsIfAvailable()
        }

        applyTheme()
        loadDocsIfAvailable()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateNavButtons()
    }

    // MARK: Toolbar

    /// Phase 7, audit §3.2's "Page toolbars" / §4.10: `HelmPageToolbar` -
    /// one height, fill, hairline and inset shared with Console and Tools -
    /// carrying the browser nav triplet in its trailing slot. There is no
    /// leading content any more: the Playbook/Runbooks/Postmortems tab pills
    /// that used to live there are gone along with the two tabs they
    /// switched to (`fm/grandline-docs-split-runbooks-postmortems`) - a
    /// single-tab page has nothing left to switch between.
    private func buildToolbar() {
        backButton = HelmPageToolbar.iconButton(symbol: "chevron.left", tooltip: "Back",
                                                target: self, action: #selector(backTapped))
        forwardButton = HelmPageToolbar.iconButton(symbol: "chevron.right", tooltip: "Forward",
                                                   target: self, action: #selector(forwardTapped))
        reloadButton = HelmPageToolbar.iconButton(symbol: "arrow.clockwise",
                                                  tooltip: "Reload (local copy only)",
                                                  target: self, action: #selector(reloadTapped))

        openLiveButton.title = "Open Live Site"
        openLiveButton.controlSize = .small
        openLiveButton.target = self
        openLiveButton.action = #selector(openLiveTapped)
        openLiveButton.translatesAutoresizingMaskIntoConstraints = false

        playbookActions.setViews([backButton, forwardButton, reloadButton], in: .leading)
        playbookActions.orientation = .horizontal
        playbookActions.alignment = .centerY
        playbookActions.spacing = HelmMetrics.s1
        playbookActions.translatesAutoresizingMaskIntoConstraints = false

        pageToolbar.setTrailing(playbookActions)
    }

    // MARK: Playbook

    private func buildPlaybookContainer(in root: NSView) {
        let config = WKWebViewConfiguration()
        // PF5 of the 2026-09-25 full review also asked for a shared
        // `WKProcessPool` across this app's four web views. **That is not
        // actionable and deliberately was not done**: `WKProcessPool` has been
        // deprecated since macOS 12 with "creating and using multiple
        // instances of WKProcessPool no longer has any effect" - modern WebKit
        // decides process sharing itself - so setting one buys nothing and
        // costs a deprecation warning, which GL-07 fails the build on. This
        // app targets macOS 13. What is left of PF5 is real and is below.
        //
        // PF5: the playbook is a local, synced copy of a repo - every byte it
        // renders is already a file on this machine. A persistent store meant
        // WebKit kept its own second copy (disk cache, localStorage) of pages
        // nothing ever reads back, for the life of the install.
        config.websiteDataStore = .nonPersistent()
        webView = DocsWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.onVisibilityChanged = { [weak self] onScreen in
            self?.playbookVisibilityChanged(onScreen: onScreen)
        }

        buildEmptyState()

        // Daylight §7: "playbook webview untouched inside a radius-16 card".
        // The web view, its navigation delegate and the local-only load path
        // are byte-for-byte what they were - only the surround is new: the
        // page's own card (`HelmMetrics.dSurface` under Daylight, the shared
        // card radius elsewhere) instead of a full-bleed browser filling the
        // destination edge to edge.
        //
        // The card clips (a rounded fill has to), which is why it carries no
        // shadow: a clipping layer casts none, and the two-layer arrangement
        // that would fix it buys nothing here - this card is the whole page
        // body, so there is no sibling surface for it to float above.
        playbookCard.translatesAutoresizingMaskIntoConstraints = false
        playbookCard.wantsLayer = true
        playbookCard.layer?.masksToBounds = true
        root.addSubview(playbookCard)

        playbookCard.addSubview(webView)
        playbookCard.addSubview(emptyStateContainer)
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            playbookCard.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                  constant: Self.playbookCardInset),
            playbookCard.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                   constant: -Self.playbookCardInset),
            playbookCard.topAnchor.constraint(equalTo: pageToolbar.bottomAnchor,
                                              constant: Self.playbookCardInset),
            playbookCard.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                 constant: -Self.playbookCardInset),

            webView.leadingAnchor.constraint(equalTo: playbookCard.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: playbookCard.trailingAnchor),
            webView.topAnchor.constraint(equalTo: playbookCard.topAnchor),
            webView.bottomAnchor.constraint(equalTo: playbookCard.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: playbookCard.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: playbookCard.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: playbookCard.topAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: playbookCard.bottomAnchor),
        ])
    }

    @objc private func backTapped() { webView.goBack() }
    @objc private func forwardTapped() { webView.goForward() }
    @objc private func reloadTapped() { loadDocsIfAvailable() }
    @objc private func openLiveTapped() { NSWorkspace.shared.open(Self.liveSiteURL) }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    /// The Playbook's own empty state, the app's shared `HelmEmptyState`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 5). This state was
    /// §3.2's "most complete one" and is what the shared component's
    /// `.standard` size *is* - a 40pt glyph over a real title, body copy and
    /// an action. The action row stays caller-owned, so "Sync Now" is still
    /// the same `HelmButton` this page enables/disables around its own async
    /// sync, with the same spinner beside it.
    private func buildEmptyState() {
        syncButton.title = "Sync Now"
        syncButton.controlSize = .regular
        syncButton.target = self
        syncButton.action = #selector(syncNowTapped)
        syncButton.translatesAutoresizingMaskIntoConstraints = false

        syncSpinner.isHidden = true

        let actionRow = NSStackView(views: [syncButton, syncSpinner])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let empty = HelmEmptyState(symbol: "book.closed",
                                   title: "Docs not synced yet",
                                   body: "The DevOps Playbook hasn't been synced to this Mac yet. Sync it once to browse it here, fully offline afterward.",
                                   size: .standard,
                                   accessory: actionRow,
                                   hue: RailDestination.docs.domainHue,
                                   artwork: RailDestination.docs.drillHeaderArtwork)
        playbookEmptyState = empty
        emptyStateContainer.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: emptyStateContainer.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: emptyStateContainer.trailingAnchor),
            empty.topAnchor.constraint(equalTo: emptyStateContainer.topAnchor),
            empty.bottomAnchor.constraint(equalTo: emptyStateContainer.bottomAnchor),
        ])
    }

    @objc private func syncNowTapped() {
        guard !isSyncing else { return }
        isSyncing = true
        syncButton.isEnabled = false
        syncSpinner.isHidden = false
        syncSpinner.startAnimation()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DocsSyncSource.update()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSyncing = false
                self.syncButton.isEnabled = true
                self.syncSpinner.isHidden = true
                self.syncSpinner.stopAnimation()
                if outcome.ok {
                    // UX14's other half, and the one that is easy to forget:
                    // a bell that only ever accumulates is a bell nobody
                    // reads. A sync that succeeds clears the entry a previous
                    // failure left.
                    Feedback.clear(id: Self.syncFailureNotificationID)
                    self.loadDocsIfAvailable()
                } else if let container = self.view.window?.contentView {
                    // UX14: a failed sync is still true after the toast has
                    // gone - the docs on screen are stale until someone acts.
                    // GL-30's "Notification Center for anything still true
                    // after the toast fades", routed through the one place
                    // that decides that (`Feedback`).
                    Feedback.report("Docs sync failed", kind: .failure, persistence: .lasting,
                                    in: container, id: Self.syncFailureNotificationID,
                                    detail: outcome.detail)
                }
            }
        }
    }

    // MARK: PF5 - unload the playbook while it is off screen

    /// PF5 of the 2026-09-25 full review: the Docs page is the app's largest
    /// web surface (the review measured roughly 12MB of JavaScript still
    /// parsed after one tour), it stays mounted for the process's life like
    /// every other destination (GL-37), and unlike the Whiteboard and Code
    /// Preview it had no gating of any kind - so everything it parsed stayed
    /// resident for as long as the app ran.
    ///
    /// WebKit offers no "purge this view" call, so the only real lever is to
    /// stop hosting the document: going off screen loads `about:blank`, which
    /// tears the page's JavaScript heap and DOM down, and coming back loads
    /// the page the captain was on. Two things make that safe rather than
    /// merely cheaper. `loadDocsIfAvailable` already **reloads** on every
    /// sync, so a freshly loaded page is this page's normal state rather than
    /// a new behaviour. And the URL is remembered, so returning lands where
    /// you left rather than back at the index.
    ///
    /// What is genuinely lost is the web view's own back/forward list, which
    /// the toolbar's nav triplet reads; it is rebuilt from the restored page
    /// onwards. That is the deliberate trade.
    private var unloadedPlaybookURL: URL?

    private func playbookVisibilityChanged(onScreen: Bool) {
        guard isViewLoaded, DocsStore.isSynced else { return }
        if onScreen {
            guard let restore = unloadedPlaybookURL else { return }
            unloadedPlaybookURL = nil
            webView.loadFileURL(restore, allowingReadAccessTo: DocsStore.folderURL)
            updateNavButtons()
        } else {
            guard unloadedPlaybookURL == nil,
                  let current = webView.url, current.isFileURL else { return }
            unloadedPlaybookURL = current
            // `about:blank`, not `loadHTMLString("")` - an empty string is a
            // no-op in WebKit and leaves the old document (and its JavaScript
            // heap) exactly where it was, which is the whole thing being
            // released here. Measured: the suite below still read
            // `window.__playbookVersion` back off the "unloaded" view.
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    private func loadDocsIfAvailable() {
        defer { onDrillSubtitleChanged?() }
        guard DocsStore.isSynced else {
            webView.isHidden = true
            emptyStateContainer.isHidden = false
            return
        }
        emptyStateContainer.isHidden = true
        webView.isHidden = false
        // PF5: a sync can land while the page is parked off screen. Loading
        // it back in here would undo the parking for a page nobody is looking
        // at - so record that the restore should land on the freshly synced
        // index instead, and stay unloaded.
        if unloadedPlaybookURL != nil, !webView.isOnScreen {
            unloadedPlaybookURL = DocsStore.indexURL
            return
        }
        // PF5: a page that was unloaded while off screen has a non-nil, non
        // -file `url`, so `reload()` would reload `about:blank`. Treat it as
        // "nothing loaded" and load the document again.
        if webView.url == nil || unloadedPlaybookURL != nil {
            unloadedPlaybookURL = nil
            webView.loadFileURL(DocsStore.indexURL, allowingReadAccessTo: DocsStore.folderURL)
        } else {
            webView.reload()
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugPlaybookCard: NSView { playbookCard }
    var debugWebView: NSView { webView }
    /// The Playbook web view as itself, so a suite can read real state back
    /// out of the loaded page (`evaluateJavaScript`) rather than only
    /// measuring the view. Used by `DocsPlaybookReloadSelfTest` to prove the
    /// subresource-cache fix in `loadDocsIfAvailable` still holds.
    var debugPlaybookWebView: DocsWebView { webView }
    /// PF5: the page the gate parked while off screen, so a suite can tell an
    /// unloaded playbook from one that merely navigated somewhere.
    var debugUnloadedPlaybookURL: URL? { unloadedPlaybookURL }
    /// The toolbar's real Reload control, so a suite drives the same
    /// target/action a click does instead of calling the handler directly.
    var debugReloadButton: NSButton { reloadButton }
    #endif

    // MARK: Theme

    private func applyTheme() {
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        // The page toolbar owns its own fill and hairline, and every button
        // in it is a `HelmButton` that re-derives its own tint - so there is
        // nothing here to re-colour for either.
        pageToolbar.applyTheme(theme)
        HelmCard.applyCardSurface(to: playbookCard, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        playbookEmptyState?.applyTheme(theme)
        emptyStateContainer.wantsLayer = true
        // Transparent, so the card's own fill shows through rather than a
        // second, differently-coloured rectangle inside it.
        emptyStateContainer.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

extension DocsController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Audit §5.4: this was `path.hasPrefix(docsPath)` - a *string* prefix,
        // so a sibling directory named `…/docs-evil/` matched `…/docs` and was
        // treated as inside the synced folder. `WebNavigationPolicy` compares
        // path components instead, which a longer sibling name cannot defeat.
        // Shared with the Whiteboard and Code Preview bundles so the check has
        // one definition rather than three that can drift.
        if WebNavigationPolicy.allowsFileURL(url, under: DocsStore.folderURL) {
            decisionHandler(.allow)
            return
        }
        // PF5: the gate parks this view on `about:blank` while the page is off
        // screen. Without this the refusal below would cancel that navigation
        // and hand `about:blank` to the *system browser* - so the page would
        // never be released and a blank tab would open in Safari.
        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        // Unchanged: Docs hosts a browsable site, so anything it refuses is
        // handed to the system browser. (The two vendored-bundle hosts are
        // deliberately stricter - see `WebNavigationPolicy.opensExternally`.)
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavButtons()
    }
}

// MARK: - The playbook's web view

/// PF5: the Docs playbook's `WKWebView`, with the same effective-visibility
/// gate `WhiteboardWebView` and `CodePreviewWebView` already carry.
///
/// The derivation is deliberately identical to theirs (and to
/// `CockpitTerminalView.refreshDisplayGating`), including reading occlusion
/// from the notification rather than live: a process the window server does
/// not composite reports "not visible" for a perfectly fine window, and a
/// headless self-test must not be told its page is hidden.
final class DocsWebView: WKWebView {

    /// Called whenever effective visibility changes, with the new state.
    var onVisibilityChanged: ((Bool) -> Void)?

    private var occlusionObserver: NSObjectProtocol?
    private var windowOccluded = false
    private var lastReportedOnScreen: Bool?

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// Is this view genuinely on screen right now?
    ///
    /// Deliberately **not** `window.isVisible`, which the two peers read: a
    /// window has a content view controller before it is ordered in, so the
    /// ordinary mounting sequence passes through "has a window, not visible
    /// yet" and a gate that believed it would unload a page nobody had
    /// navigated away from. What this gate actually cares about is the
    /// destination model hiding the view, which is `isHiddenOrHasHiddenAncestor`;
    /// a minimised or fully covered window arrives through the occlusion
    /// notification instead, and a view with no window at all has nothing on
    /// screen by definition.
    var isOnScreen: Bool {
        guard window != nil else { return false }
        return !windowOccluded && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerOcclusionObserver()
        refreshVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshVisibility()
    }

    private func registerOcclusionObserver() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        windowOccluded = false
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let w = note.object as? NSWindow {
                self.windowOccluded = !w.occlusionState.contains(.visible)
            }
            self.refreshVisibility()
        }
    }

    /// Report a *change* only.
    ///
    /// A view that has not been on screen yet is recorded silently: the first
    /// state a freshly built view has is "no window", and treating that as a
    /// transition to hidden would unload a page that was never shown - which
    /// is exactly what it did to `DocsPlaybookReloadSelfTest`, a suite that
    /// drives the controller before mounting it.
    func refreshVisibility() {
        let onScreen = isOnScreen
        guard onScreen != lastReportedOnScreen else { return }
        let wasNeverOnScreen = lastReportedOnScreen == nil
        lastReportedOnScreen = onScreen
        guard onScreen || !wasNeverOnScreen else { return }
        onVisibilityChanged?(onScreen)
    }

    #if FM_SELFTESTS
    /// Drive the gate without a real window-server transition, so a suite can
    /// assert the unload/restore behaviour rather than only the derivation.
    func debugReportVisibility(_ onScreen: Bool) {
        guard onScreen != lastReportedOnScreen else { return }
        lastReportedOnScreen = onScreen
        onVisibilityChanged?(onScreen)
    }
    var debugIsOnScreen: Bool { isOnScreen }
    #endif
}
