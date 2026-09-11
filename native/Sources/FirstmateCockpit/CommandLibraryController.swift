// Manjesh Grand Line - native macOS app.
//
// The `.commandLibrary` rail destination: "DevOps Commands".
//
// **A navigation change, not a feature.** The Command Library itself
// (`CommandLibraryModels.swift`, `CommandLibraryStore.swift`,
// `CommandLibraryViews.swift`) has been fully built since
// `fm/grandline-devops-command-library` Phase 1 - what it never had was a
// destination of its own. It shipped as the third tab of `ShiftController`'s
// "My Tasks / Weekly Review / DevOps Commands" switcher, so the only way to
// reach a saved command was to first open a page about something else. The
// captain's own correction (`fm/grandline-tasks-kanban-devops-split`) is that
// it should be its own top-level card, exactly like Tasks is.
//
// This is the same promotion `fm/grandline-docs-split-runbooks-postmortems`
// gave the Runbooks and Postmortems tabs out of `DocsController`, and it is
// deliberately as thin: `CommandLibraryPageView` is unchanged and unmoved,
// and this controller exists only to give it a root view, a theme observer
// and a drill header. Every behaviour a captain already knew - search,
// category drill-down, favourites, recents, the parameter form, Copy, Send to
// Terminal, Send to hosts, the AI actions and their risk gate, the editor
// sheet - is byte-for-byte what it was, because none of that code is touched.
//
// `CommandLibraryPageView` is an `NSObject` owning a plain `NSView` rather
// than being an `NSViewController` itself, so this pins that view into a root
// of its own rather than assigning it as `self.view`: the root is what
// carries the destination's `HelmTheme` background and its forced
// appearance, and a page view designed to be embedded should not have to
// grow a second identity to be mounted.
//
// Root view follows AGENTS.md gotcha #8: a plain `NSView` with
// `wantsLayer`/`HelmTheme` background, not `NSVisualEffectView` vibrancy.
// And it forces its own `appearance` - the half a layer-colour self-test
// cannot see, and the one three recent destinations each shipped without
// (see `ThemeManager.swift`'s checklist item 2).

import AppKit

final class CommandLibraryController: NSViewController, DaylightDrillActions {

    /// GL-23: the shared instance, never a second one. Two `CommandLibraryStore`s
    /// each cached the library *and* wrote `recent.yaml` from that stale cache,
    /// so an edit in one was invisible to the other until relaunch and whichever
    /// saved last silently dropped the other's recency data.
    private let store: CommandLibraryStore
    private lazy var page = CommandLibraryPageView(store: store)

    private let scroll = NSScrollView()

    /// Forward-don't-own, inherited verbatim from `ShiftController`, which
    /// held these while the library was a tab there: this page knows nothing
    /// about the console or the host store, and `AppShellController` wires
    /// both onward exactly as it did before.
    var onSendCommandToTerminal: ((String) -> Void)?
    var onSendCommandToHosts: ((DevOpsCommand, [String: String], String) -> Void)?

    init(store: CommandLibraryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?

    /// The page carries its own search field, its own filter chips and its own
    /// per-command actions, all a few points below the header - hoisting a
    /// copy of any of them would be the duplication §6.4 exists to remove.
    /// Same call `ConsoleController` and `PostmortemsController` already make.
    var drillHeaderActions: [NSView] { [] }

    var drillHeaderSubtitle: String? {
        let count = store.commands.count
        guard count > 0 else { return "No saved commands yet" }
        let favourites = store.favoriteCommands().count
        var parts = ["\(count) command\(count == 1 ? "" : "s")"]
        if favourites > 0 { parts.append("\(favourites) favourite\(favourites == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        page.onSendToTerminal = { [weak self] text in self?.onSendCommandToTerminal?(text) }
        page.onSendToHosts = { [weak self] command, values, generated in
            self?.onSendCommandToHosts?(command, values, generated)
        }
        page.onPresentEditor = { [weak self] editor in self?.presentAsSheet(editor) }

        // The page keeps the scroll wrapper it always had. Inside
        // `ShiftController` it was an arranged subview of that page's own
        // scrolling content stack, and `CommandLibraryPageView` has no
        // internal scroller of its own - its category list and its detail
        // pane both grow to fit their content - so dropping the scroll view
        // on the way out of Tasks would have quietly turned "a long category
        // scrolls" into "a long category is clipped".
        //
        // `FlippedView`, not a plain `NSView`: an unflipped document view
        // shorter than the viewport rests against the *bottom* of the clip
        // view, leaving a blank gap above the content (AGENTS.md gotcha (9)).
        // And the document's width is pinned to `scroll.contentView` (the
        // clip view), never `scroll` itself - a non-overlay scroller reserves
        // a real track that narrows the clip view without narrowing the
        // scroll view (gotcha (4)).
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            page.view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            page.view.topAnchor.constraint(equalTo: content.topAnchor, constant: HelmMetrics.s5),
            page.view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -HelmMetrics.s5),
        ])

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            guard let self else { return }
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self.page.applyTheme(theme)
        }

        page.reloadAndRender()
        onDrillSubtitleChanged?()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        page.reloadAndRender()
        onDrillSubtitleChanged?()
    }

    /// F5 (`fm/grandline-feature-f5-command-palette-expansion`): reveal one
    /// saved command from the command palette. Was `ShiftController.
    /// openCommandLibraryCommand`, which had to switch tabs first; now that
    /// this is a destination of its own, `AppShellController` does the
    /// navigating and this is only the selection half - the same selection a
    /// real row click performs, never a second one.
    func openCommand(id: String) {
        page.reloadAndRender()
        page.openCommand(id: id)
    }
}
