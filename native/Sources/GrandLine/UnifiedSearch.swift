// Grand Line - native macOS app.
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
final class UnifiedSearchController: NSWindowController {
    /// §6.11's width. Was 580 before Daylight; one step wider gives the
    /// grouped rows their gradient tile and mono shortcut hint room.
    static let panelWidth: CGFloat = 600

    private let index: UnifiedSearchIndex

    /// The palette's query line, in the app's own search well (Phase 0's
    /// raw-input purge - this was the smallest, most-used surface in the app
    /// still wearing system chrome, audit Tier 3). Arrow/Return/Escape still
    /// arrive here, now through `HelmSearchField.onCommand`.
    ///
    /// K-2 (the hero restyle board's "Lit selection") puts it in a raised
    /// well with an `esc` keycap at its trailing edge, as the board draws it.
    private let searchField = HelmSearchField(
        placeholder: "Search hosts, commands, tasks, runbooks, actions\u{2026}",
        size: .prominent, shortcutHint: "esc")
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
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 60),
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
        // PF16: the token used to be discarded. This controller is
        // app-lifetime, so nothing accumulated in practice - but a
        // registration nothing can cancel is a leak waiting for the first
        // caller that does not live forever.
        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // Audit §5.1: gating `present()` only covers *opening* while locked.
        // This panel is `.floating`, so it renders above the lock overlay -
        // which is a subview of the main window, not a screen-level shield -
        // and the 12h session-expiry lock can fire mid-use, with the palette
        // already up and showing real host/task/runbook titles plus F5's live
        // action rows. Registered once, here, where the window is created;
        // the gate orders it out on every lock. Same shape as the Host Editor's
        // own registration in `main.swift`.
        AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.window }
    }

    private var themeObservation: ThemeObservation?

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
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

        searchField.wellSurface = .raised
        searchField.onTextChanged = { [weak self] query in self?.reload(query: query) }
        searchField.onCommand = { [weak self] selector in self?.handle(command: selector) ?? false }

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

        // K-2 (the hero restyle board's "Lit selection", the captain's pick)
        // took H1's `.menu` material away. The palette sits on the card
        // surface now, opaque, like every other surface in the hero language:
        // the system material was the one part of it that was neither the
        // app's nor the theme's, and the selected row is now the one lit
        // thing on the panel, which a blurred backdrop would compete with.

        // H1: "a persistent footer strip with key hints (⏎ to run, ⌘K to
        // close)". `HelmKeyHint` (F2c), so a keycap in the palette and a
        // keycap in a form footer are the same object. K-2's footer leads
        // with the arrows, as the board draws it.
        let footer = NSView()
        footer.wantsLayer = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        let moveHint = HelmKeyHint(keys: [Self.upKey, Self.downKey], caption: "to move")
        let runHint = HelmKeyHint(keys: [HelmKeyHint.returnKey], caption: "to run")
        let closeHint = HelmKeyHint(keys: [HelmKeyHint.command, "K"], caption: "to close")
        let footerRow = NSStackView(views: [moveHint, runHint, closeHint])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = HelmMetrics.s4
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerRow)
        let footerDivider = NSView()
        footerDivider.wantsLayer = true
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerDivider)
        self.footerRef = footer
        self.footerDividerRef = footerDivider

        content.addSubview(searchField)
        content.addSubview(divider)
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.fieldGutter),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.fieldGutter),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldInset),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Self.fieldInset),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            resultsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Self.fieldGutter),
            footerRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        self.dividerRef = divider
    }

    private var dividerRef: NSView?
    private var hasSizedOnce = false
    /// The frame the panel is settling toward. See `resizeToFit`.
    private var pendingFrame: NSRect?
    private var footerRef: NSView?
    private var footerDividerRef: NSView?

    /// H1's persistent footer strip, 32pt as K-2 draws it.
    static let footerHeight: CGFloat = 32
    /// The field's distance from the panel's top edge and from the divider
    /// under it, and the head's side gutter (K-2's 14pt by 16pt head).
    static let fieldInset: CGFloat = 14
    static let fieldGutter: CGFloat = HelmMetrics.s4
    /// Everything above the results: the field, its two insets and the
    /// divider. Derived rather than written out, because a literal here went
    /// stale once already: it read 61, which is a 32pt field, while the field
    /// has been `HelmField.prominentHeight` (40) since Phase 0 - so the
    /// results' scroll view came out 8pt shorter than its own content (366pt
    /// for 374pt of rows, measured by `UnifiedSearchLayoutSelfTest`), and the
    /// bottom of the last row needed a scroll to see.
    static var headerHeight: CGFloat { fieldInset + HelmField.prominentHeight + fieldInset + 1 }
    /// The footer's arrow keycaps.
    static let upKey = "\u{2191}"
    static let downKey = "\u{2193}"

    /// Centers the palette near the top of the main window, Spotlight-style,
    /// and focuses the search field so typing works immediately.
    func present() {
        // GL-09: this palette is a `.floating` `NSPanel`, so it renders above
        // the lock overlay (which only covers the main window's own view tree)
        // and its results disclose real host/task/runbook titles - and F5
        // gave every row a real action, so a locked app opening this would
        // hand out the app's whole verb surface. A locked app does not open
        // it.
        guard AppLockGate.shared.allows(.unifiedSearch) else {
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
        hasSizedOnce = false
        pendingFrame = nil
        window.makeKeyAndOrderFront(nil)
        playEntrance()
        searchField.focusEditor()
        installOutsideClickMonitors()
    }

    /// H1's "150ms scale-fade entrance".
    ///
    /// On the content view rather than the window: a `.floating` `NSPanel`
    /// shown with `makeKeyAndOrderFront` has no presentation animation of its
    /// own to compose with or replace, so the arrival *is* this. A plain
    /// scale, no anchor-point correction - AppKit gives a layer-backed view's
    /// layer an anchor point of (0.5, 0.5), the same assumption
    /// `HoverHighlightView`'s press compression relies on.
    private func playEntrance() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        guard let layer = content.layer, !HelmMotion.isReduced else {
            content.alphaValue = 1
            return
        }
        // About the centre: a view-backed layer's anchor is its bottom-left
        // corner (measured), so a bare scale would grow the palette out of
        // that corner.
        HelmMotion.withoutActions {
            layer.transform = HelmMotion.centredScale(Self.entranceScale, of: layer)
        }
        content.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.entranceDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().alphaValue = 1
            HelmMotion.animateLayers(duration: Self.entranceDuration, on: [layer]) {
                layer.transform = CATransform3DIdentity
            }
        }
    }

    static let entranceDuration: TimeInterval = HelmMotion.moveDuration
    static let entranceScale: CGFloat = 0.97

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

    // MARK: Key handling

    /// Arrow keys move the selection, Return picks the current row, Escape
    /// dismisses - the field editor forwards its command keys here rather
    /// than through a plain `keyDown` override, since AppKit routes an
    /// editing text field's key events to the shared field editor, not the
    /// `NSTextField` itself. `HelmSearchField` passes them straight along.
    private func handle(command commandSelector: Selector) -> Bool {
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
            addPaddedLabel("No matches.", font: .systemFont(ofSize: HelmType.scaled(13)))
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
                addPaddedLabel(group.overflowText,
                               font: .systemFont(ofSize: HelmType.scaled(11)), leading: 24, vertical: 5, muted: true)
            }
        }
    }

    /// A section header - the mockup's small uppercase group name.
    private func addGroupHeader(_ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        // §6.11's "10px uppercase" group label - one step down from the shared
        // kicker, which the twelve palettes keep.
        label.font = ThemeManager.shared.theme.isDaylight
            ? .systemFont(ofSize: HelmType.scaled(10), weight: .bold)
            : HelmType.kicker()
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
        // search field + divider + padding + H1's persistent footer strip
        let total = Self.headerHeight + resultsHeight + Self.footerHeight

        // **Compute from the pending target, not from the live frame.**
        // `window.animator().setFrame` does not apply immediately, so a second
        // resize arriving mid-animation - which is every keystroke - would
        // read a stale `maxY` and re-anchor the panel a little lower each
        // time. Keeping the target is what stops it creeping down the screen.
        let reference = pendingFrame ?? window.frame
        let target = NSRect(x: reference.minX, y: reference.maxY - total,
                            width: reference.width, height: total)
        guard abs(reference.height - total) > 0.5 else { return }
        pendingFrame = target

        // H1: "subtle height animation as results change". Skipped on the
        // first sizing of a presentation - a panel that grew into place as it
        // appeared would fight the scale-fade entrance rather than compose
        // with it - and instant under Reduce Motion.
        guard hasSizedOnce, !HelmMotion.isReduced else {
            hasSizedOnce = true
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HelmMotion.stateDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        }
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
        // K-2: the card surface, opaque, on every palette.
        window?.contentView?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        // §6.11: radius 16 on `card` with a raised shadow. A titled `NSPanel`
        // paints its own square background behind the content view, so the
        // corner radius only reads once the *window* stops drawing one -
        // hence `isOpaque = false` plus a clear window background, the
        // standard rounded-floating-panel arrangement. The shadow is the
        // window's own (`hasShadow`), because a layer shadow inside a
        // clipped, rounded content view would be drawn inside its own mask.
        if let panel = window {
            panel.isOpaque = !theme.isDaylight
            panel.backgroundColor = theme.isDaylight
                ? .clear
                : HelmTheme.nsColor(theme.chromeBackgroundHex)
            panel.hasShadow = true
            panel.invalidateShadow()
        }
        if let content = window?.contentView {
            content.layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dSurface : 0
            content.layer?.masksToBounds = theme.isDaylight
        }
        dividerRef?.wantsLayer = true
        dividerRef?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        footerDividerRef?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        // K-2: the footer is the card too, under its hairline, rather than a
        // strip of the inset well's colour.
        footerRef?.layer?.backgroundColor = NSColor.clear.cgColor
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
    /// The height the panel has settled on, or is settling toward.
    ///
    /// H1 made the resize animated, and `window.animator().setFrame` does not
    /// apply immediately - so `window.frame.height` read straight after a
    /// query change is the *previous* height. That is the same animator-proxy
    /// trap `HelmMotion.fade`'s header records, and it is also what production
    /// now reads `pendingFrame` for rather than the live frame.
    var debugPanelHeight: CGFloat { pendingFrame?.height ?? window?.frame.height ?? 0 }
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
    /// The real row views, in display order - K-2's recipe is read off them.
    var debugRows: [UnifiedSearchRowView] { rowViews }
    var debugSearchField: HelmSearchField { searchField }
    var debugFooterHints: [HelmKeyHint] {
        footerRef.map { Self.descendants(HelmKeyHint.self, in: $0) } ?? []
    }
    /// The results' scroll view and the height of what it holds, for the
    /// check that the panel's own arithmetic leaves room for every row.
    var debugResultsViewportHeight: CGFloat { scroll.frame.height }
    var debugResultsContentHeight: CGFloat {
        resultsStack.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
    }
    /// Whether anything in the panel is a system material (K-2 took H1's away).
    var debugHasMaterial: Bool {
        window?.contentView.map { !Self.descendants(NSVisualEffectView.self, in: $0).isEmpty } ?? false
    }
    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += descendants(type, in: sub) }
        return found
    }
    /// The panel chrome §6.11 specifies - radius/opacity/width, read live.
    var debugPanelChrome: (width: CGFloat, radius: CGFloat, masks: Bool,
                           opaque: Bool, hasShadow: Bool) {
        (window?.frame.width ?? 0,
         window?.contentView?.layer?.cornerRadius ?? 0,
         window?.contentView?.layer?.masksToBounds ?? false,
         window?.isOpaque ?? true,
         window?.hasShadow ?? false)
    }
    func debugApplyTheme(_ theme: HelmTheme) { applyTheme(theme) }
    /// Re-theme every row too - `applyTheme` already does, but a row also
    /// re-reads its own selection state, so this is the honest whole-panel
    /// refresh a real `ThemeManager` firing performs.
    func debugRefreshRows(_ theme: HelmTheme) { rowViews.forEach { $0.applyTheme(theme) } }
    #endif
}


/// One palette row, matching the mockup's shape: a small tinted icon tile,
/// the title over a muted meta line, and an optional trailing chip carrying
/// what Return will do ("Connect ↵").
/// Internal rather than `private` so the §3H suite can build one directly and
/// read what its icon really resolved to - the same reason
/// `RecentDestinationsPanelViewController` is internal.
///
/// **K-2, the Lit selection** (the hero restyle board, the captain's pick).
/// A row rests on the card surface with a faint wash tile of its own hue, and
/// the selected row is the one lit thing on the panel: the hero's quiet-ink
/// gradient (`HelmHeroColumn.palette`, the toasts' and the notifications
/// head's), its words in the hero's ink with the meta line at the quiet
/// alpha, its tile a glass tile, and its hint a shade pill drawn for the
/// gradient. Only the selected row shows its hint, because only that row is
/// what Return runs. The hint stays in the row at zero alpha rather than
/// leaving the stack, so a title truncates at the same point whichever row
/// is lit, and VoiceOver still reads it.
///
/// §6.11's gradient tile on every Daylight row went with it: a column of
/// full-saturation gradient squares beside one gradient row is a dozen lit
/// things rather than one. The board draws the faint wash tile instead, which
/// is `IconTileView`, the tile the twelve pre-Daylight palettes always had.
final class UnifiedSearchRowView: NSView {
    /// The board's 26pt tile on an 8pt radius.
    static let tileSide: CGFloat = 26
    static let glyphPointSize: CGFloat = 12

    private let tile = IconTileView(size: UnifiedSearchRowView.tileSide, cornerRadius: HelmMetrics.rControl)
    /// The lit row's tile: a translucent shade of the hero's ink with an ink
    /// glyph and an ink hairline, the glass tile every hero surface draws
    /// (`PopoverHeroHeader`'s `.glass`, the toast's and the HUD's circles).
    private let glassTile = NSView()
    private let glassGlyph = NSImageView()
    /// The lit row's gradient, under everything else in `background`.
    private let hero = HelmHeroSurface()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let hintBackground = HintPill()
    private let background = HoverHighlightView()
    var onClick: (() -> Void)?
    private var isSelected = false
    /// The glyph the row's tile carries, kept so the glass tile can draw the
    /// same one.
    private var glyphSymbol = "circle"
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// The lit row's palette: the theme's hero colour through the quiet-ink
    /// rule, so the 80% meta line clears the text floor too.
    static func palette(in theme: HelmTheme) -> HelmHeroSurface.Palette {
        HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        background.cornerRadius = HelmMetrics.dTileSmall
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        // The gradient is the background's first subview, so the row's own
        // content draws over it, and it takes no clicks
        // (`HelmHeroSurface.hitTest`), so a click on the lit row still lands
        // on the background's recognizer. The board's glow is an ellipse
        // sized from the row itself, which is `.capsule`'s shape: the card's
        // 220pt circle would cover most of a 44pt row.
        hero.glowShape = .capsule
        hero.isHidden = true
        hero.layer?.cornerRadius = HelmMetrics.dTileSmall
        background.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hero.topAnchor.constraint(equalTo: background.topAnchor),
            hero.bottomAnchor.constraint(equalTo: background.bottomAnchor),
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

        hintLabel.font = HelmType.chip()
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
        hintBackground.translatesAutoresizingMaskIntoConstraints = false
        hintBackground.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: hintBackground.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: hintBackground.centerYAnchor),
            // The board's pill: 8pt either side, 2pt above and below.
            hintBackground.widthAnchor.constraint(equalTo: hintLabel.widthAnchor, constant: 2 * HelmMetrics.s2),
            hintBackground.heightAnchor.constraint(equalTo: hintLabel.heightAnchor, constant: HelmMetrics.s1),
        ])

        glassTile.wantsLayer = true
        glassTile.layer?.cornerRadius = HelmMetrics.rControl
        glassTile.layer?.borderWidth = 1
        glassTile.isHidden = true
        glassTile.translatesAutoresizingMaskIntoConstraints = false
        glassGlyph.translatesAutoresizingMaskIntoConstraints = false
        glassGlyph.imageScaling = .scaleNone
        glassTile.addSubview(glassGlyph)

        let tileBox = NSView()
        tileBox.translatesAutoresizingMaskIntoConstraints = false
        tileBox.addSubview(tile)
        tileBox.addSubview(glassTile)
        NSLayoutConstraint.activate([
            tile.centerXAnchor.constraint(equalTo: tileBox.centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: tileBox.centerYAnchor),
            glassTile.centerXAnchor.constraint(equalTo: tileBox.centerXAnchor),
            glassTile.centerYAnchor.constraint(equalTo: tileBox.centerYAnchor),
            glassTile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            glassTile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            glassGlyph.centerXAnchor.constraint(equalTo: glassTile.centerXAnchor),
            glassGlyph.centerYAnchor.constraint(equalTo: glassTile.centerYAnchor),
            tileBox.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tileBox.heightAnchor.constraint(equalToConstant: Self.tileSide),
        ])
        tileBox.setContentHuggingPriority(.required, for: .horizontal)
        tileBox.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [tileBox, textColumn, hintBackground])
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

    /// The hint's pill. Its radius follows its own height, so it stays a pill
    /// at any interface text size. Set where the size lands rather than in
    /// the row's `layout()`, which runs before a view two stacks down has a
    /// frame: the first render drew the pill with square corners that way.
    private final class HintPill: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            layer?.cornerRadius = newSize.height / 2
        }
    }

    func configure(item: UnifiedSearchItem, theme: HelmTheme, selected: Bool) {
        self.theme = theme
        // H1: "per-kind icons (destinations use their real artwork/hue,
        // commands use their category tint, hosts their accent)". The row's
        // own identity where it has one, `kind`'s where it does not - which is
        // right for a task or a note, whose identity genuinely *is* its kind.
        let glyph: String
        switch item.icon {
        case .destination(let destination):
            // **I1 narrows H1 here, and the two findings genuinely
            // contradict.** H1 asks for "destinations use their real
            // artwork/hue"; I1 - which is the report's *policy* statement for
            // where each icon language lives - says "raster app-icons only as
            // page identity (drill header + canvas card tile) ... palette rows
            // use symbol + hue". Implementing both literally is not possible,
            // and the policy wins: a palette row is not page identity, and a
            // list of full-colour app squares beside tinted symbol rows is
            // precisely the "five apps" mix I1 exists to end.
            //
            // The *hue* half of H1 survives intact - which is what actually
            // fixed its complaint that every action row wore the same square.
            glyph = destination.symbol
            tile.configure(symbol: glyph, tint: destination.domainHue.fallbackTint, pointSize: Self.glyphPointSize)
        case .tinted(let tint, let symbol):
            glyph = symbol ?? item.kind.symbol
            tile.configure(symbol: glyph, tint: tint, pointSize: Self.glyphPointSize)
        case .literal(let hex, let symbol):
            // A hue the captain picked, so it is used literally - the same
            // distinction `HelmAccentRow.Content.tintHex` draws.
            glyph = symbol
            tile.configure(symbol: symbol, tint: item.kind.tint, pointSize: Self.glyphPointSize)
            tile.overrideFill(hex: hex)
        case nil:
            glyph = item.kind.symbol
            tile.configure(symbol: glyph, tint: item.kind.tint, pointSize: Self.glyphPointSize)
        }
        glyphSymbol = glyph
        titleLabel.stringValue = item.title
        metaLabel.stringValue = item.meta
        metaLabel.isHidden = item.meta.isEmpty
        hintLabel.stringValue = item.actionHint ?? ""
        hintBackground.isHidden = (item.actionHint ?? "").isEmpty
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        hintLabel.font = HelmType.chip()
        tile.applyTheme(theme)
        background.normalColor = .clear
        HelmMotion.withoutActions {
            if isSelected {
                let palette = Self.palette(in: theme)
                let ink = HelmContrast.color(palette.ink)
                hero.apply(palette)
                hero.isHidden = false
                // The gradient is the row's surface, so a hover wash under it
                // would never show and must not be what paints a lit row.
                background.hoverColor = .clear
                titleLabel.textColor = ink
                metaLabel.textColor = ink.withAlphaComponent(HelmHeroColumn.quietInkAlpha)
                tile.isHidden = true
                glassTile.isHidden = false
                glassTile.layer?.backgroundColor = ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
                glassTile.layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
                glassGlyph.image = HelmSymbol.image(glyphSymbol, pointSize: Self.glyphPointSize,
                                                    weight: .semibold, hierarchicalColor: ink)
                // The ghost pill's recipe (`HelmButton.heroPalette`): a shade
                // of the ink's opposite under the words, which can only add
                // contrast, and an ink hairline.
                hintLabel.textColor = ink
                hintBackground.layer?.backgroundColor = HelmButton.heroShade(for: ink)
                    .withAlphaComponent(HelmButton.heroFillAlpha).cgColor
                hintBackground.layer?.borderColor = ink.withAlphaComponent(HelmButton.heroBorderAlpha).cgColor
                hintBackground.layer?.borderWidth = 1
                hintBackground.alphaValue = 1
            } else {
                hero.isHidden = true
                background.hoverColor = theme.isDaylight
                    ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
                    : line.withAlphaComponent(0.3)
                titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
                metaLabel.textColor = HelmTheme.mutedInk(theme)
                tile.isHidden = false
                glassTile.isHidden = true
                hintLabel.textColor = HelmTheme.mutedInk(theme)
                hintBackground.layer?.backgroundColor = line.withAlphaComponent(0.35).cgColor
                hintBackground.layer?.borderWidth = 0
                hintBackground.alphaValue = 0
            }
        }
    }

    #if FM_SELFTESTS
    /// What the row's icon actually resolved to - read off the real views, so
    /// a check cannot pass by repeating this file's own mapping.
    var debugFlatTileFill: NSColor? {
        tile.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    /// K-2's recipe, read off the real views.
    var debugIsLit: Bool { !hero.isHidden }
    var debugHeroPalette: HelmHeroSurface.Palette? { hero.palette }
    var debugHeroGradient: [CGColor] { hero.debugGradientColors }
    var debugHeroGlowShape: HelmHeroSurface.GlowShape { hero.glowShape }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugMetaColor: NSColor? { metaLabel.textColor }
    var debugHintColor: NSColor? { hintLabel.textColor }
    var debugHintAlpha: CGFloat { hintBackground.alphaValue }
    var debugHintFill: NSColor? { hintBackground.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    var debugHintFont: NSFont? { hintLabel.font }
    var debugFlatTileHidden: Bool { tile.isHidden }
    var debugGlassTileHidden: Bool { glassTile.isHidden }
    var debugGlassFill: NSColor? { glassTile.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    var debugBackgroundFill: NSColor { background.normalColor }
    /// The row's rounded surface, for a probe that samples what is painted.
    var debugSurfaceView: NSView { background }

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
