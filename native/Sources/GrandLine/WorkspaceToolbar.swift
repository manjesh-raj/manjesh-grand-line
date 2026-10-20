// Grand Line - native macOS app.
//
// The Workspace shell's window toolbar.
//
// UX-12 of the 2026-10 review: the main window hid its title bar, moved the
// traffic lights by hand onto a floating bar, and had no `NSToolbar`, so the
// window did not behave like other Mac windows - Mission Control and the
// Window menu could not say which page it was on, and every system behaviour
// a toolbar brings had to be rebuilt by hand. This is the toolbar the window
// now carries. The system draws the title (the module) and the subtitle (the
// page's own live line) at its leading edge; the items are:
//
//   - Toggle Sidebar, with a tracking separator so the title sits over the
//     content column rather than over the sidebar;
//   - the showing page's own actions (`DaylightDrillActions.drillHeaderActions`,
//     unchanged - what used to sit in the floating bar's drill header);
//   - search (it opens the ⌘K palette), the focus timer while one runs,
//     Recently Visited, the light/dark toggle, and the notification bell.
//
// The page actions are a dynamic run of items: identifiers carry a generation
// number so a page's buttons are never handed back to the toolbar as a stale
// cached item from the previous page.
//
// The toolbar is hidden while the app is locked (`setLocked`), because it sits
// outside the content view the lock overlay covers - the bell and Recents
// would otherwise stay one click from the captain's data.

import AppKit

extension NSToolbarItem.Identifier {
    static let workspaceSidebarToggle = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.sidebar")
    static let workspaceSidebarSeparator = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.sidebarSeparator")
    static let workspaceSearch = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.search")
    static let workspaceFocus = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.focus")
    static let workspaceRecents = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.recents")
    static let workspaceTheme = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.theme")
    static let workspaceBell = NSToolbarItem.Identifier("com.manjesh.grandline.toolbar.bell")
    static let workspaceActionPrefix = "com.manjesh.grandline.toolbar.action."
}

/// A toolbar button in the system's own toolbar style: a template SF Symbol
/// on the bezel AppKit draws for toolbar buttons, monochrome at rest.
class WorkspaceToolbarButton: NSButton {
    init(symbol: String, tooltip: String, accessibilityLabel: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        title = ""
        bezelStyle = .texturedRounded
        isBordered = true
        imagePosition = .imageOnly
        setSymbol(symbol, accessibilityLabel: accessibilityLabel)
        toolTip = tooltip
        setAccessibilityLabel(accessibilityLabel)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setSymbol(_ symbol: String, accessibilityLabel: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
    }
}

/// The light/dark toggle.
final class WorkspaceThemeToggleButton: WorkspaceToolbarButton {
    static let lightSymbol = "sun.max"
    static let darkSymbol = "moon"

    init() {
        super.init(symbol: Self.darkSymbol, tooltip: "", accessibilityLabel: "Toggle Light/Dark")
    }

    func applyTheme(_ theme: HelmTheme) {
        let isDark = theme.mode == .dark
        setSymbol(isDark ? Self.darkSymbol : Self.lightSymbol, accessibilityLabel: "Toggle Light/Dark")
        toolTip = isDark ? "Dark appearance - switch to Light (⌘⌥T)" : "Light appearance - switch to Dark (⌘⌥T)"
        setAccessibilityValue(isDark ? "Dark" : "Light")
    }
}

/// The search field's place in the toolbar. It is a button that looks like a
/// field: the palette is where typing happens, so a real field here would be
/// a second, weaker search.
final class WorkspaceSearchPill: HoverHighlightView {
    static let preferredWidth: CGFloat = 260

    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Search Grand Line")
    private let badge = NSTextField(labelWithString: "\u{2318}K")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 28))
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = HelmMetrics.rControl

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = HelmMetrics.rChip - 1
        badge.alignment = .center
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, label, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s2
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let preferred = widthAnchor.constraint(equalToConstant: Self.preferredWidth)
        preferred.priority = NSLayoutConstraint.Priority(400)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            preferred,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        accessibilityLabelOverride = "Search Grand Line, Command K"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let fill = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.card)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)
        if #available(macOS 26.0, *) {
            // macOS 26 seats every toolbar view on its own glass capsule, so
            // a second field drawn inside it would be two borders for one
            // control. The glass is the field there.
            normalColor = .clear
            hoverColor = line.withAlphaComponent(0.18)
            layer?.borderWidth = 0
        } else {
            normalColor = fill
            hoverColor = line.withAlphaComponent(theme.isDaylight ? 0.35 : 0.25)
            layer?.borderWidth = 1
        }
        layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        iconView.contentTintColor = muted
        label.font = .systemFont(ofSize: HelmType.scaled(12.5))
        // Placeholder copy uses `muted`, never `faint` (2.04:1, decorative).
        label.textColor = muted
        badge.font = .monospacedSystemFont(ofSize: HelmType.scaled(10), weight: .medium)
        badge.textColor = muted
        badge.layer?.backgroundColor = line.withAlphaComponent(0.35).cgColor
    }
}

final class WorkspaceToolbarController: NSObject, NSToolbarDelegate {

    let toolbar: NSToolbar
    let notificationCenter = NotificationCenterController()
    let recentDestinations = RecentDestinationsController()
    let clipboardHistory = ClipboardHistoryController()
    let searchPill = WorkspaceSearchPill()
    let themeButton = WorkspaceThemeToggleButton()

    var onSearchTapped: (() -> Void)?
    /// The sidebar button's action (the shell's own Toggle Sidebar).
    var onToggleSidebar: (() -> Void)?
    /// The split view whose first divider the title tracks, so it sits over
    /// the content column rather than over the sidebar.
    weak var trackedSplitView: NSSplitView?
    let sidebarButton = WorkspaceToolbarButton(symbol: "sidebar.left", tooltip: "Toggle Sidebar (⌥⌘S)",
                                                       accessibilityLabel: "Toggle Sidebar")

    /// The showing page's own action views, and the generation they were
    /// installed under.
    private(set) var moduleActions: [NSView] = []
    private var actionGeneration = 0
    private var themeToken: ThemeObservation?

    // F7 - the focus timer's chip, an item only while a session runs.
    private let focusChip = FocusTimerChip()
    private weak var focusTimer: FocusTimerController?
    private var focusTimerToken: UUID?
    private var focusPopover: NSPopover?

    override init() {
        // One identifier per controller: toolbars that share an identifier
        // form a "family" AppKit keeps in sync, so removing a page's action
        // item from one would try to remove it from every other window's
        // toolbar too - and trap when that index does not exist there. The
        // toolbar is not user-customised, so nothing is lost by not sharing a
        // saved configuration.
        toolbar = NSToolbar(identifier: "com.manjesh.grandline.workspace.\(UUID().uuidString)")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false

        searchPill.onClick = { [weak self] in self?.onSearchTapped?() }
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarButtonClicked)
        themeButton.target = self
        themeButton.action = #selector(themeToggleClicked)
        clipboardHistory.anchor = recentDestinations.button
        focusChip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(focusChipClicked)))
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.focusPopover }

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let focusTimerToken { focusTimer?.unobserve(focusTimerToken) }
    }

    // MARK: Page actions

    /// Show `views` as the page's actions, replacing the previous page's.
    func setModuleActions(_ views: [NSView]) {
        let same = views.count == moduleActions.count && zip(views, moduleActions).allSatisfy { $0 === $1 }
        guard !same else { return }
        for index in toolbar.items.indices.reversed()
        where toolbar.items[index].itemIdentifier.rawValue.hasPrefix(NSToolbarItem.Identifier.workspaceActionPrefix) {
            toolbar.removeItem(at: index)
        }
        for view in moduleActions where !views.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        moduleActions = views
        actionGeneration += 1
        guard let searchIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .workspaceSearch }) else { return }
        for (offset, _) in views.enumerated() {
            toolbar.insertItem(withItemIdentifier: actionIdentifier(offset), at: searchIndex + 1 + offset)
        }
    }

    private func actionIdentifier(_ index: Int) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("\(NSToolbarItem.Identifier.workspaceActionPrefix)\(actionGeneration).\(index)")
    }

    // MARK: Lock

    func setLocked(_ locked: Bool) {
        toolbar.isVisible = !locked
        if locked {
            focusPopover?.performClose(nil)
        }
    }

    // MARK: Focus timer

    func attachFocusTimer(_ timer: FocusTimerController) {
        if let focusTimerToken, let previous = focusTimer { previous.unobserve(focusTimerToken) }
        focusTimer = timer
        focusTimerToken = timer.observe { [weak self] in self?.renderFocusChip() }
        renderFocusChip()
    }

    private var focusItemIsInstalled: Bool {
        toolbar.items.contains { $0.itemIdentifier == .workspaceFocus }
    }

    private func renderFocusChip() {
        guard let session = focusTimer?.session else {
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .workspaceFocus }) {
                toolbar.removeItem(at: index)
            }
            focusPopover?.performClose(nil)
            focusPopover = nil
            return
        }
        focusChip.configure(fraction: focusTimer?.fraction ?? 0,
                            countdown: focusTimer?.countdownText ?? "0:00",
                            title: session.taskTitle,
                            paused: focusTimer?.isPaused ?? false)
        focusChip.applyTheme(ThemeManager.shared.theme)
        if !focusItemIsInstalled,
           let recentsIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .workspaceRecents }) {
            toolbar.insertItem(withItemIdentifier: .workspaceFocus, at: recentsIndex)
        }
    }

    @objc private func focusChipClicked() {
        guard let focusTimer, focusTimer.isRunning else { return }
        if let focusPopover, focusPopover.isShown {
            focusPopover.performClose(nil)
            self.focusPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        let panel = FocusTimerPanelController(timer: focusTimer)
        panel.onRequestClose = { [weak self, weak popover] in
            popover?.performClose(nil)
            self?.focusPopover = nil
        }
        popover.contentViewController = panel
        popover.show(relativeTo: focusChip.bounds, of: focusChip, preferredEdge: .minY)
        focusPopover = popover
    }

    // MARK: Actions

    @objc private func sidebarButtonClicked() { onToggleSidebar?() }

    @objc private func themeToggleClicked() {
        ThemeManager.shared.toggle()
    }

    private func applyTheme(_ theme: HelmTheme) {
        searchPill.applyTheme(theme)
        themeButton.applyTheme(theme)
        notificationCenter.bell.applyTheme(theme)
        if focusTimer?.session != nil { focusChip.applyTheme(theme) }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.workspaceSidebarToggle, .workspaceSidebarSeparator, .flexibleSpace,
         .workspaceSearch, .workspaceRecents, .workspaceTheme, .workspaceBell]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.workspaceFocus, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .workspaceSidebarToggle:
            return viewItem(identifier, view: sidebarButton, label: "Sidebar", priority: .high)
        case .workspaceSidebarSeparator:
            guard let split = trackedSplitView else { return NSToolbarItem(itemIdentifier: .space) }
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split, dividerIndex: 0)
        case .workspaceSearch:
            return viewItem(identifier, view: searchPill, label: "Search", priority: .high)
        case .workspaceRecents:
            return viewItem(identifier, view: recentDestinations.button, label: "Recently Visited", priority: .low)
        case .workspaceTheme:
            return viewItem(identifier, view: themeButton, label: "Appearance", priority: .low)
        case .workspaceBell:
            return viewItem(identifier, view: notificationCenter.bell, label: "Notifications", priority: .high)
        case .workspaceFocus:
            return viewItem(identifier, view: focusChip, label: "Focus Timer", priority: .high)
        default:
            let raw = identifier.rawValue
            guard raw.hasPrefix(NSToolbarItem.Identifier.workspaceActionPrefix),
                  let index = raw.split(separator: ".").last.flatMap({ Int($0) }),
                  moduleActions.indices.contains(index) else { return nil }
            let view = moduleActions[index]
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            let label = view.accessibilityLabel() ?? (view as? NSButton)?.title ?? "Action"
            return viewItem(identifier, view: view, label: label, priority: .standard)
        }
    }

    private func viewItem(_ identifier: NSToolbarItem.Identifier, view: NSView, label: String,
                          priority: NSToolbarItem.VisibilityPriority) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        item.label = label
        item.paletteLabel = label
        item.toolTip = view.toolTip
        item.visibilityPriority = priority
        return item
    }

    // MARK: Probe surface

    #if FM_SELFTESTS
    /// Every panel the toolbar's controls drop down, for the suites that
    /// assert their chrome and their lock registration.
    func debugBarPanels() -> [(String, HelmBarPanel)] {
        [("notifications", notificationCenter.debugPanel),
         ("recents", recentDestinations.debugPanel),
         ("clipboard", clipboardHistory.debugPanel)]
    }
    var debugItemIdentifiers: [String] { toolbar.items.map(\.itemIdentifier.rawValue) }
    var debugFocusChip: FocusTimerChip { focusChip }
    var debugFocusChipIsInstalled: Bool { focusItemIsInstalled }
    /// The chip's laid-out width while its item is in the toolbar, and 0
    /// while it is not - a removed item takes no room at all.
    var debugFocusChipWidth: CGFloat { focusItemIsInstalled ? focusChip.fittingSize.width : 0 }
    func debugClickFocusChip() { focusChipClicked() }
    var debugFocusPopoverIsShown: Bool { focusPopover?.isShown ?? false }
    var debugFocusPanel: FocusTimerPanelController? {
        focusPopover?.contentViewController as? FocusTimerPanelController
    }
    #endif
}
