// Manjesh Grand Line - native macOS app.
//
// The app's `⌘K` command palette.
//
// Phase 4 of "Knowledge and speed" (fm/grandline-unified-search) built this
// as a runbook/postmortem search, expanding `⌘K` from its prior single job
// (`AppShellController.activateConsoleFind` - in-terminal find).
//
// **F5 (`fm/grandline-feature-f5-command-palette-expansion`) made it the
// app's verb surface**, per the production review's F5 entry (section 25 of
// `data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md`)
// and the captain-approved mockup in that review's `lavish-plan.html`: hosts
// (Connect), the command library (Send/open), tasks/follow-ups/projects,
// runbooks, postmortems and app actions/destinations, grouped by kind, in one
// list. It also **absorbed ⌘⇧P** - `ShiftSearch.swift`'s second, near-
// identical palette over the same Shift data is gone, its matcher living on
// as `UnifiedSearchShiftProvider`.
//
// This file owns the palette *UI and nothing else*. Every domain's matching
// and every row's action live behind `UnifiedSearchProvider`
// (`UnifiedSearchProviders.swift`) - read that file's header for the design,
// including why a command row sometimes sends and sometimes opens, and how
// the destructive-command confirmation gate is preserved when a command is
// reached from here. Grouping/capping is the only thing added on top, below.
//
// Terminal command history was investigated as a search domain (in phase 4,
// and unchanged by F5) and deliberately left out: the only structured record
// of "commands the captain has actually run" is Block View's
// `TerminalBlockTracker`, which is off by default and only active on hosts
// with `Host.blockViewOptIn` set (see AGENTS.md's "Block view" section -
// still an early "Stage 0" rollout). That's not a safe, already-real,
// app-wide data source to search against, and expanding its rollout scope to
// back a search feature is its own decision. Terminal-history search stays
// deferred until Block View matures past that stage.

import AppKit

/// Runs every registered provider and groups what they return.
///
/// Providers are registered once (`main.swift`), each already holding its own
/// store and its own real actions - so this type never learns what a host or
/// a command is, which is exactly the "provider protocol on the existing
/// palette" the review asked for.
final class UnifiedSearchIndex {
    /// Rows shown per group before the rest collapse into an explicit
    /// "N more…" line. A query like "e" genuinely matches most of the 70+
    /// seeded commands, and the palette renders rows as permanent
    /// `NSStackView` arranged subviews - the shape AGENTS.md has watched blow
    /// up into multi-second layout passes four times now. Capping keeps the
    /// stack small *and* keeps the palette readable; the overflow count is
    /// surfaced rather than silently dropped.
    static let maxPerGroup = 6

    private var providers: [UnifiedSearchProvider] = []

    func register(_ provider: UnifiedSearchProvider) { providers.append(provider) }

    /// Every provider's matches, bucketed by `UnifiedSearchKind.groupTitle`
    /// and ordered by `UnifiedSearchKind.groupOrder`. A group with no matches
    /// is omitted entirely (no empty headers).
    func groups(query: String) -> [UnifiedSearchGroup] {
        var buckets: [String: [UnifiedSearchItem]] = [:]
        for provider in providers {
            for item in provider.items(query: query) {
                buckets[item.kind.groupTitle, default: []].append(item)
            }
        }
        return UnifiedSearchKind.groupOrder.compactMap { title in
            guard let items = buckets[title], !items.isEmpty else { return nil }
            let shown = Array(items.prefix(Self.maxPerGroup))
            return UnifiedSearchGroup(title: title, items: shown, overflow: items.count - shown.count)
        }
    }

    /// The flat, in-display-order row list the palette's arrow keys move
    /// through - group headers and overflow lines are not selectable.
    func flatItems(query: String) -> [UnifiedSearchItem] {
        groups(query: query).flatMap(\.items)
    }
}

/// The palette itself - a small, non-activating, key-accepting panel so
/// typing works immediately without stealing focus from (or hiding) the main
/// window behind it.
///
/// F5 replaced its flat single-domain list with `UnifiedSearchIndex`'s
/// grouped output, and its result type with `UnifiedSearchItem` - so picking
/// a row is now `item.activate()` and this class dispatches nothing itself.
/// The old `onSelectRunbook`/`onSelectPostmortem` callbacks are gone with it;
/// `main.swift` wires those two actions into `UnifiedSearchDocsProvider`
/// instead, alongside every other domain's.
final class UnifiedSearchController: NSWindowController, NSTextFieldDelegate {
    private let index: UnifiedSearchIndex

    private let searchField = NSTextField()
    private let resultsStack = NSStackView()
    private let scroll = NSScrollView()
    private var groups: [UnifiedSearchGroup] = []
    /// The selectable rows, flattened in display order - group headers and
    /// "N more…" lines are skipped, so arrow keys never land on one.
    private var items: [UnifiedSearchItem] = []
    private var selectedIndex = 0
    private var rowViews: [UnifiedSearchRowView] = []
    private var groupHeaderLabels: [NSTextField] = []
    // Fix (dismiss bug): a click anywhere outside the palette - on the main
    // window, or in another app entirely (the panel floats at `.floating`
    // level above everything) - should close it, same as Spotlight/any
    // command palette. A bare `NSPanel` (unlike `NSPopover`) has no built-in
    // outside-click dismissal. A local monitor covers a click landing in a
    // different window of this same app; a global monitor covers a click in
    // a different app - mirrors `ShiftGlobalHotkey`'s established
    // local+global monitor pair (`ShiftQuickCapture.swift`), just for mouse
    // clicks instead of a hotkey.
    private var outsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?

    init(index: UnifiedSearchIndex) {
        self.index = index
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 60),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)

        buildUI(in: panel)
        _ = panel.followHelmTheme()
        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildUI(in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        // Fix (theme bug): without this, the content view has no layer at
        // all until a descendant view (e.g. a result row's `HoverHighlightView`)
        // is added and forces layer-backing on its ancestor chain - which
        // hasn't happened yet the first time `applyTheme` runs (called
        // immediately by `ThemeManager.shared.observe` below, before
        // `present()` has ever built a row). That first call's
        // `contentView.layer?.backgroundColor = ...` silently no-ops against
        // a nil layer, so the palette renders as plain unthemed system gray
        // until some *later* theme change happens to re-run `applyTheme`
        // after rows exist. Setting `wantsLayer` here guarantees the layer
        // exists before `applyTheme` is ever called. See AGENTS.md's
        // `ThemeManager`/`HelmTheme` checklist, gotcha #8.
        content.wantsLayer = true

        searchField.placeholderString = "Search hosts, commands, tasks, runbooks, actions\u{2026}"
        searchField.font = .systemFont(ofSize: 16)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 0
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = resultsStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchField)
        content.addSubview(divider)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            resultsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        self.dividerRef = divider
    }

    private var dividerRef: NSView?

    /// Centers the palette near the top of the main window, Spotlight-style,
    /// and focuses the search field so typing works immediately.
    func present() {
        // GL-09: this palette is a `.floating` `NSPanel`, so it renders above
        // the lock overlay (which only covers the main window's own view tree)
        // and its results disclose real host/task/runbook titles - and F5
        // gave every row a real action, so a locked app opening this would
        // hand out the app's whole verb surface. A locked app does not open
        // it.
        guard AppLockGate.shared.allows(.quickCapture) else {
            AppLog.lifecycle.info("search palette refused - app is locked (GL-09)")
            return
        }
        guard let window else { return }
        searchField.stringValue = ""
        reload(query: "")
        if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            let mainFrame = main.frame
            let x = mainFrame.midX - window.frame.width / 2
            let y = mainFrame.maxY - 120
            window.setFrameTopLeftPoint(NSPoint(x: x, y: max(y, mainFrame.minY + 40)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        installOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window { self?.dismiss() }
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeOutsideClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let globalOutsideClickMonitor { NSEvent.removeMonitor(globalOutsideClickMonitor) }
        outsideClickMonitor = nil
        globalOutsideClickMonitor = nil
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        reload(query: searchField.stringValue)
    }

    /// Arrow keys move the selection, Return picks the current row, Escape
    /// dismisses - the field editor forwards its command keys here rather
    /// than through a plain `keyDown` override, since AppKit routes an
    /// editing text field's key events to the shared field editor, not the
    /// `NSTextField` itself.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            selectCurrent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    private func reload(query: String) {
        groups = index.groups(query: query)
        items = groups.flatMap(\.items)
        selectedIndex = 0
        rebuildRows()
        resizeToFit()
    }

    private func rebuildRows() {
        for v in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()
        groupHeaderLabels.removeAll()
        guard !items.isEmpty else {
            addPaddedLabel("No matches.", font: .systemFont(ofSize: 13))
            return
        }
        var flatIndex = 0
        for group in groups {
            addGroupHeader(group.title)
            for item in group.items {
                let row = UnifiedSearchRowView()
                row.configure(item: item, theme: ThemeManager.shared.theme, selected: flatIndex == selectedIndex)
                let capturedIndex = flatIndex
                row.onClick = { [weak self] in
                    self?.selectedIndex = capturedIndex
                    self?.selectCurrent()
                }
                row.translatesAutoresizingMaskIntoConstraints = false
                resultsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
                rowViews.append(row)
                flatIndex += 1
            }
            // "No silent caps" - say what was left out rather than letting a
            // capped group look complete.
            if group.overflow > 0 {
                addPaddedLabel("\(group.overflow) more \(group.title.lowercased()) match\(group.overflow == 1 ? "" : "es") - keep typing to narrow it down",
                               font: .systemFont(ofSize: 11), leading: 24, vertical: 5, muted: true)
            }
        }
    }

    /// A section header - the mockup's small uppercase group name.
    private func addGroupHeader(_ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = HelmType.kicker()
        label.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        label.translatesAutoresizingMaskIntoConstraints = false
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -4),
        ])
        resultsStack.addArrangedSubview(padded)
        padded.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        groupHeaderLabels.append(label)
    }

    private func addPaddedLabel(_ text: String, font: NSFont, leading: CGFloat = 18,
                               vertical: CGFloat = 14, muted: Bool = true) {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = muted ? HelmTheme.mutedInk(ThemeManager.shared.theme)
                                : HelmTheme.nsColor(ThemeManager.shared.theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: leading),
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: vertical),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -vertical),
        ])
        resultsStack.addArrangedSubview(padded)
        padded.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        groupHeaderLabels.append(label)
    }

    private func resizeToFit() {
        guard let window else { return }
        // Summed from each arranged subview's own fitting height rather than
        // one per-row constant, since a grouped list mixes three different row
        // shapes (result rows, section headers, overflow lines). Measured per
        // child rather than off the stack, so it cannot be thrown off by the
        // stack's own width tie to the clip view - every child here is a
        // padded, single-line, non-wrapping label, so its fitting height is
        // exact and width-independent.
        resultsStack.layoutSubtreeIfNeeded()
        let measured = resultsStack.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
        let contentHeight = items.isEmpty ? 46 : max(measured, 46)
        let resultsHeight = min(contentHeight, 420)
        let total = 61 + resultsHeight // search field + divider + padding
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - total, width: frame.width, height: total), display: true)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + delta))
        for (index, row) in rowViews.enumerated() {
            row.setSelected(index == selectedIndex)
        }
        scrollSelectionIntoView()
    }

    /// Keeps the arrow-key selection on screen once a grouped list is taller
    /// than the palette's 420pt cap. `scrollToVisible` is called *on the row*
    /// with its own `bounds` - the rect argument is in the receiver's own
    /// coordinate space, so handing a clip view a rect in document
    /// coordinates would scroll to the wrong place.
    private func scrollSelectionIntoView() {
        guard selectedIndex >= 0, selectedIndex < rowViews.count else { return }
        resultsStack.layoutSubtreeIfNeeded()
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    /// F5: the palette no longer knows what any row *is* - the provider that
    /// produced it already closed over the real action (see
    /// `UnifiedSearchProviders.swift`). Dismiss first so an action that opens
    /// a sheet or an `NSAlert` (a destructive command's confirmation, say) is
    /// not fighting this panel for key window.
    private func selectCurrent() {
        guard selectedIndex >= 0, selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        dismiss()
        item.activate()
    }

    func dismiss() {
        window?.orderOut(nil)
        removeOutsideClickMonitors()
    }

    private func applyTheme(_ theme: HelmTheme) {
        window?.contentView?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        searchField.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        dividerRef?.wantsLayer = true
        dividerRef?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        for label in groupHeaderLabels { label.textColor = HelmTheme.mutedInk(theme) }
        for row in rowViews { row.applyTheme(theme) }
    }

    // MARK: - Probe / self-test surface
    //
    // `UnifiedSearchSelfTest` drives the real grouping + selection + dispatch
    // path rather than re-deriving it. Guarded like every other such hook.
    #if FM_SELFTESTS
    func debugReload(query: String) { reload(query: query) }
    var debugGroupTitles: [String] { groups.map(\.title) }
    var debugItemTitles: [String] { items.map(\.title) }
    var debugSelectedIndex: Int { selectedIndex }
    var debugRowCount: Int { rowViews.count }
    func debugMoveSelection(by delta: Int) { moveSelection(by: delta) }
    func debugActivateSelection() { selectCurrent() }
    /// The panel height `resizeToFit()` settled on - the measurement that
    /// proves a grouped list of mixed row shapes is not collapsed to one
    /// row's worth of height.
    var debugPanelHeight: CGFloat { window?.frame.height ?? 0 }
    var debugContentWidth: CGFloat { window?.contentView?.bounds.width ?? 0 }
    func debugLayoutNow() { window?.contentView?.layoutSubtreeIfNeeded() }
    /// Per-row geometry for the layout checks: the chip must stay at its own
    /// natural width instead of absorbing the row's slack, and must sit to the
    /// right of the title rather than on top of it.
    func debugRowGeometry(at index: Int) -> (rowWidth: CGFloat, chipWidth: CGFloat, chipHidden: Bool,
                                             titleMaxX: CGFloat, chipMinX: CGFloat)? {
        guard index >= 0, index < rowViews.count else { return nil }
        return rowViews[index].debugGeometry
    }
    #endif
}

/// One palette row, matching the mockup's shape: a small tinted icon tile,
/// the title over a muted meta line, and an optional trailing chip carrying
/// what Return will do ("Connect ↵").
private final class UnifiedSearchRowView: NSView {
    private let tile = IconTileView(size: 24, cornerRadius: 6)
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let hintBackground = NSView()
    private let background = HoverHighlightView()
    var onClick: (() -> Void)?
    private var isSelected = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        background.cornerRadius = 6
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.font = HelmType.caption()
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textColumn = NSStackView(views: [titleLabel, metaLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level priority is the one that
        // bites for a view with no intrinsic content size - the text column
        // is the one thing allowed to flex, so the tile and the chip keep
        // their natural widths and the title truncates instead.
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.font = HelmType.caption()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12) again, and the reason this chip is sized by a
        // *width constraint* rather than by hugging priority: `hintBackground`
        // is a bare `NSView`, so it has no intrinsic content size, so
        // `setContentHuggingPriority` on it is a no-op - which under the row's
        // `.fill` distribution leaves it a candidate to absorb the row's whole
        // slack width (this codebase has shipped a 90pt button rendered ~900pt
        // wide exactly that way). Tying its width to the label's own intrinsic
        // width plus the chip insets makes stretching structurally impossible
        // instead of merely deprioritised. The stack-level
        // `setHuggingPriority` fix does not apply here - that API only exists
        // on `NSStackView`.
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintBackground.wantsLayer = true
        hintBackground.layer?.cornerRadius = 4
        hintBackground.translatesAutoresizingMaskIntoConstraints = false
        hintBackground.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: hintBackground.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: hintBackground.centerYAnchor),
            hintBackground.widthAnchor.constraint(equalTo: hintLabel.widthAnchor, constant: 12),
            hintBackground.heightAnchor.constraint(equalTo: hintLabel.heightAnchor, constant: 4),
        ])

        let row = NSStackView(views: [tile, textColumn, hintBackground])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        // AGENTS.md gotcha (10): the AppKit default `.gravityAreas` honours
        // no hugging priority at all, so slack width is resolved by Auto
        // Layout's own tie-breaking and the chip drifts row to row.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        background.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func configure(item: UnifiedSearchItem, theme: HelmTheme, selected: Bool) {
        self.theme = theme
        tile.configure(symbol: item.kind.symbol, tint: item.kind.tint, pointSize: 11)
        titleLabel.stringValue = item.title
        metaLabel.stringValue = item.meta
        metaLabel.isHidden = item.meta.isEmpty
        hintLabel.stringValue = item.actionHint ?? ""
        hintBackground.isHidden = (item.actionHint ?? "").isEmpty
        setSelected(selected)
        applyTheme(theme)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        titleLabel.textColor = ink
        metaLabel.textColor = muted
        hintLabel.textColor = muted
        hintBackground.layer?.backgroundColor = line.withAlphaComponent(0.35).cgColor
        tile.applyTheme(theme)
        background.normalColor = isSelected ? line.withAlphaComponent(0.3) : .clear
        background.hoverColor = line.withAlphaComponent(0.3)
    }

    #if FM_SELFTESTS
    var debugGeometry: (rowWidth: CGFloat, chipWidth: CGFloat, chipHidden: Bool,
                        titleMaxX: CGFloat, chipMinX: CGFloat) {
        let titleInRow = titleLabel.convert(titleLabel.bounds, to: self)
        let chipInRow = hintBackground.convert(hintBackground.bounds, to: self)
        return (rowWidth: bounds.width,
                chipWidth: hintBackground.frame.width,
                chipHidden: hintBackground.isHidden,
                titleMaxX: titleInRow.maxX,
                chipMinX: chipInRow.minX)
    }
    #endif
}
