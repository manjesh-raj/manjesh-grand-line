// Manjesh Grand Line - native macOS app.
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

    static let liveSiteURL = URL(string: "https://manjesh-raj.github.io/devops-playbook/")!

    /// The shared page toolbar (Phase 7) - see `buildToolbar()`. Its trailing
    /// slot holds the browser nav triplet (back/forward/reload); the
    /// page-level "Open Live Site" action lives in the shell's drill header
    /// cluster instead (§6.4).
    private let pageToolbar = HelmPageToolbar()
    private let playbookActions = NSStackView()

    private var webView: WKWebView!
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
    private let syncSpinner = NSProgressIndicator()
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
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

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

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isIndeterminate = true
        syncSpinner.isHidden = true
        syncSpinner.translatesAutoresizingMaskIntoConstraints = false

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
                                   hue: RailDestination.docs.domainHue)
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
        syncSpinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DocsSyncSource.update()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSyncing = false
                self.syncButton.isEnabled = true
                self.syncSpinner.isHidden = true
                self.syncSpinner.stopAnimation(nil)
                if outcome.ok {
                    self.loadDocsIfAvailable()
                } else if let container = self.view.window?.contentView {
                    Toast.show(in: container, message: "Docs sync failed: \(outcome.detail)")
                }
            }
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
        if webView.url == nil {
            webView.loadFileURL(DocsStore.indexURL, allowingReadAccessTo: DocsStore.folderURL)
        } else {
            webView.reload()
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugPlaybookCard: NSView { playbookCard }
    var debugWebView: NSView { webView }
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
        if url.isFileURL {
            let docsPath = DocsStore.folderURL.standardizedFileURL.path
            if url.standardizedFileURL.path.hasPrefix(docsPath) {
                decisionHandler(.allow)
                return
            }
        }
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
