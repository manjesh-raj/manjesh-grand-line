// Manjesh Grand Line - native macOS app.
//
// The "All Destinations" overlay - review #3's UX1.
//
// The finding: twenty-six `RailDestination`s reachable through three
// mechanisms that cover different subsets (canvas cards on five spaces, the
// quick-access icon row, ⌘K), and nothing anywhere that shows the whole set at
// once. "A captain learns where things are by exploration."
//
// This is the map. One grouped grid, every destination in it, grouped by the
// `DaylightSpace` that owns it - so the overlay teaches the app's own
// structure rather than presenting a flat alphabetical wall. Two things it is
// deliberately *not*:
//
//   - **Not a second ⌘K.** There is no query field. ⌘K is the app's verb
//     surface and already answers an empty query with a browsable list; a
//     second search box would be the duplication UX1 is complaining about.
//     This is the *visual* map, read with the eyes, and it is the one surface
//     where seeing all twenty-six at once is the point.
//   - **Not a replacement for the quick-access row.** It is where a captain
//     goes to find the thing they then pin - see `QuickAccessConfiguration`,
//     which this overlay's own context menu writes to.
//
// Chrome follows `UnifiedSearchController`'s panel exactly (a `.floating`,
// non-activating `NSPanel` with hidden titlebar chrome, outside-click
// dismissal, an `AppLockGate` registration and a Reduce-Motion-gated entrance),
// because that is this app's established overlay and a second recipe for the
// same idea is what the component index exists to prevent.

import AppKit

final class AllDestinationsOverlayController: NSWindowController {
    /// Four columns of 150pt tiles plus gutters. Wide enough that the two
    /// large spaces (Stores, Operations) do not wrap to five rows, narrow
    /// enough to sit inside a 1100pt window with room around it.
    static let panelWidth: CGFloat = 720
    static let tileWidth: CGFloat = 156
    static let columns = 4

    /// Raised with the destination the captain picked. The shell navigates;
    /// this overlay has no idea what navigation means, matching
    /// `DaylightBarController.onSelectDestination`'s own forward-don't-own
    /// wiring.
    var onSelect: ((RailDestination) -> Void)?

    /// Raised when a destination's context menu asks for it to be pinned to
    /// (or unpinned from) the quick-access row - UX1's "make the quick-access
    /// row user-configurable", reached from the one surface that shows every
    /// candidate.
    var onTogglePin: ((RailDestination) -> Void)?

    /// Asked, at build time for each tile, whether that destination is
    /// currently pinned - so the context menu's wording and its checkmark are
    /// read from the real configuration rather than from a copy this overlay
    /// would have to keep in step.
    var isPinned: ((RailDestination) -> Bool)?

    private var outsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var themeObservation: ThemeObservation?
    private var tiles: [DestinationTileView] = []
    private var kickerLabels: [NSTextField] = []
    private let heading = NSTextField(labelWithString: "All destinations")
    private let subheading = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 520),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
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
        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // GL-09, the same registration `UnifiedSearchController` makes and for
        // the same reason: a `.floating` panel renders *above* the lock
        // overlay, which is a subview of the main window rather than a
        // screen-level shield. This one discloses no captain data at all - it
        // is a fixed list of page names - but it is a live navigation surface,
        // and a locked app handing out navigation is exactly what the gate is
        // for.
        AppLockGate.shared.registerSecondaryWindow { [weak self] in self?.window }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Grouping

    /// Every destination, grouped for display.
    ///
    /// Pure logic and `static`, so `AllDestinationsOverlaySelfTest` can assert
    /// the two properties that actually matter - that the grid is *complete*
    /// (UX1's whole complaint is that no surface shows all of them) and that no
    /// destination is listed twice - without a window.
    ///
    /// `DaylightModule.space(forDestination:)` is the one mapping in the app
    /// from a destination to its space, the same one `AppShellController.show`
    /// reads to keep the bar's selected pill honest. Reading it here rather
    /// than writing a second table is what stops this overlay from disagreeing
    /// with the space pills about where a page lives.
    ///
    /// A destination no module opens has no space, and rather than hide it -
    /// which would defeat the entire point of a complete map - it lands in a
    /// trailing "Elsewhere" group. Today that is `.homeCanvas` (the hub every
    /// space is *shown on*, so it belongs to none of them) and `.strawHat`
    /// (whose module appears on Overview and nowhere else).
    static func groups() -> [(title: String, destinations: [RailDestination])] {
        var bySpace: [DaylightSpace: [RailDestination]] = [:]
        var unspaced: [RailDestination] = []
        for destination in RailDestination.allCases {
            if let space = DaylightModule.space(forDestination: destination) {
                bySpace[space, default: []].append(destination)
            } else {
                unspaced.append(destination)
            }
        }
        var result = DaylightSpace.allCases.compactMap { space -> (String, [RailDestination])? in
            guard let destinations = bySpace[space], !destinations.isEmpty else { return nil }
            return (space.title, destinations)
        }
        if !unspaced.isEmpty { result.append(("Elsewhere", unspaced)) }
        return result
    }

    // MARK: Chrome

    private func buildUI(in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        // The same nil-layer trap `UnifiedSearchController.buildUI` documents:
        // `applyTheme` runs before any descendant has forced layer-backing.
        content.wantsLayer = true

        heading.font = HelmType.pageTitle()
        subheading.font = HelmType.caption()
        subheading.stringValue =
            "\(RailDestination.allCases.count) pages. Right-click one to pin it to the bar."

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for group in Self.groups() { stack.addArrangedSubview(makeGroup(group)) }

        let header = NSStackView(views: [heading, subheading])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(stack)

        let gutter = HelmMetrics.s5
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: gutter),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -gutter),
            // Room for the hidden titlebar's own height, matching the search
            // palette's own top inset.
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: gutter + 6),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: gutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -gutter),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s4),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -gutter),
        ])
    }

    private func makeGroup(_ group: (title: String, destinations: [RailDestination])) -> NSView {
        let kicker = NSTextField(labelWithString: group.title.uppercased())
        kicker.font = HelmType.kicker()
        kickerLabels.append(kicker)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = HelmMetrics.s2

        // A hand-rolled grid rather than `HelmResponsiveGrid`: that component
        // reflows against a live container width, and this panel's width is
        // fixed, so a fixed column count is both simpler and stable. Rows are
        // padded with real spacers so a short final row's tiles stay
        // left-aligned at their own column rather than stretching.
        for chunk in stride(from: 0, to: group.destinations.count, by: Self.columns) {
            let slice = group.destinations[chunk..<min(chunk + Self.columns, group.destinations.count)]
            var views: [NSView] = slice.map { destination in
                let tile = DestinationTileView(destination: destination)
                tile.onClick = { [weak self] in
                    self?.close()
                    self?.onSelect?(destination)
                }
                tile.isPinnedNow = { [weak self] in self?.isPinned?(destination) ?? false }
                tile.onTogglePin = { [weak self] in self?.onTogglePin?(destination) }
                tiles.append(tile)
                return tile
            }
            while views.count < Self.columns {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.widthAnchor.constraint(equalToConstant: Self.tileWidth).isActive = true
                views.append(spacer)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = HelmMetrics.s2
            row.distribution = .fill
            rows.addArrangedSubview(row)
        }

        let column = NSStackView(views: [kicker, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        return column
    }

    private func applyTheme(_ theme: HelmTheme) {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        content.layer?.cornerRadius = HelmMetrics.rCard
        heading.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subheading.textColor = HelmField.mutedInk(theme)
        for label in kickerLabels { label.textColor = HelmField.mutedInk(theme) }
        for tile in tiles { tile.applyTheme(theme) }
    }

    // MARK: Presentation

    func present() {
        guard AppLockGate.shared.allows(.allDestinations) else {
            AppLog.lifecycle.info("all-destinations overlay refused - app is locked (GL-09)")
            return
        }
        guard let window else { return }
        window.layoutIfNeeded()
        // The panel sizes itself to its content: the grid's height depends on
        // how many groups there are, which is a property of the enum rather
        // than a constant worth hard-coding here.
        let fitting = window.contentView?.fittingSize ?? NSSize(width: Self.panelWidth, height: 520)
        window.setContentSize(NSSize(width: Self.panelWidth, height: fitting.height))
        if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            let frame = main.frame
            window.setFrameTopLeftPoint(NSPoint(x: frame.midX - window.frame.width / 2,
                                                y: max(frame.maxY - 100, frame.minY + 40)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        playEntrance()
        installOutsideClickMonitors()
    }

    /// Escape and a second ⌘⇧D both close it, which is what "toggle" means for
    /// a map you glance at.
    func toggle() {
        if window?.isVisible == true { close() } else { present() }
    }

    override func close() {
        removeOutsideClickMonitors()
        super.close()
    }

    private func playEntrance() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        guard let layer = content.layer, !HelmMotion.isReduced else {
            content.alphaValue = 1
            return
        }
        layer.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        content.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            content.animator().alphaValue = 1
            layer.transform = CATransform3DIdentity
        }
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window { self?.close() }
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeOutsideClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let globalOutsideClickMonitor { NSEvent.removeMonitor(globalOutsideClickMonitor) }
        outsideClickMonitor = nil
        globalOutsideClickMonitor = nil
    }
}

/// One destination in the grid: its own gradient tile over its own name.
///
/// A `HoverHighlightView` rather than a hand-rolled clickable box, per GL-16 -
/// that component supplies the accessibility role, the label, the focus ring
/// and the keyboard press, which a bare `NSView` with a click gesture does not.
final class DestinationTileView: HoverHighlightView {
    let destination: RailDestination
    var onClick: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var isPinnedNow: (() -> Bool)?

    private let tile = HelmGradientTile(size: .module)
    private let label = NSTextField(labelWithString: "")

    init(destination: RailDestination) {
        self.destination = destination
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityLabelOverride = destination.title
        accessibilityRoleOverride = .button
        // `HoverHighlightView` treats `onAccessibilityPress` as the one
        // primary action - it is what `isActivatable`, the focus ring and the
        // keyboard Space/Return press all read - and a click gesture is what
        // routes a real mouse click into it.
        onAccessibilityPress = { [weak self] in self?.onClick?() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        cornerRadius = HelmMetrics.rCard

        tile.configure(for: destination)
        tile.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = destination.title
        label.font = HelmType.rowTitle()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AllDestinationsOverlayController.tileWidth),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: tile.topAnchor, constant: -HelmMetrics.s2),
            bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: HelmMetrics.s2),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pinned = isPinnedNow?() ?? false
        let menu = NSMenu()
        let item = NSMenuItem(title: pinned ? "Unpin from bar" : "Pin to bar",
                              action: #selector(togglePin), keyEquivalent: "")
        item.target = self
        item.state = pinned ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc private func clicked() { onClick?() }

    @objc private func togglePin() { onTogglePin?() }

    func applyTheme(_ theme: HelmTheme) {
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        normalColor = .clear
        hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
    }
}
