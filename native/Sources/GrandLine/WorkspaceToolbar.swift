// Grand Line - native macOS app.
//
// The sidebar shell's window toolbar (stage 3 of the modular-shell migration).
//
// The floating bar draws its own chrome; this shell lets the system draw it.
// Every control is a standard `NSToolbarItem` - an image item, or a view item
// whose view is a plain `NSButton` or `NSSegmentedControl` - so the toolbar
// looks like the system's on every macOS this app runs on (Liquid Glass
// capsules on macOS 26), and nothing here repaints a bezel of its own.
//
// What sits where, left to right:
//
//   - over the sidebar: the sidebar toggle,
//   - Back and Forward, then Recents (the floating bar's Recents panel, the
//     same `RecentDestinationsController`); the window title and subtitle
//     follow, drawn by the system - the page's name and its live subtitle,
//   - in the middle, on Home only: the five spaces, which still filter
//     Home's cards,
//   - the showing page's own actions (its `drillHeaderActions`, which the
//     floating bar drew in its drill header),
//   - the trailing cluster: the light/dark toggle and the notifications
//     button (the captain kept both), the inspector toggle, then Search.
//
// The toolbar draws state and forwards clicks; the shell decides what they
// mean. Nothing is customisable and nothing is autosaved: the configuration
// would otherwise be written to `UserDefaults.standard`, outside
// `AppDefaults.store`, which is the one thing this app's preferences must not
// do.

import AppKit

final class WorkspaceToolbar: NSObject, NSToolbarDelegate {

    enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("workspace.sidebar")
        static let navigation = NSToolbarItem.Identifier("workspace.navigation")
        static let recents = NSToolbarItem.Identifier("workspace.recents")
        static let spaces = NSToolbarItem.Identifier("workspace.spaces")
        static let pageActions = NSToolbarItem.Identifier("workspace.pageActions")
        static let theme = NSToolbarItem.Identifier("workspace.theme")
        static let notifications = NSToolbarItem.Identifier("workspace.notifications")
        static let inspector = NSToolbarItem.Identifier("workspace.inspector")
        static let search = NSToolbarItem.Identifier("workspace.search")
    }

    let toolbar = NSToolbar(identifier: "workspace.toolbar")

    // Forwarded, never owned.
    var onToggleSidebar: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onRecents: ((NSView) -> Void)?
    var onSelectSpace: ((DaylightSpace) -> Void)?
    var onToggleTheme: (() -> Void)?
    var onNotifications: ((NSView) -> Void)?
    var onToggleInspector: (() -> Void)?
    var onSearch: (() -> Void)?

    private weak var splitView: NSSplitView?

    private let sidebarButton = NSButton()
    private let navigation = NSSegmentedControl()
    private let recentsButton = NSButton()
    /// Where the clipboard history panel drops down from: a zero-width view
    /// on Recents' trailing edge, so the panel lands where the floating bar's
    /// did. Zero width for the bar's reason - `HelmBarPanel`'s outside-click
    /// monitor lets clicks inside the anchor's bounds through, so anchoring
    /// on Recents itself would leave the clipboard panel open under a click
    /// that opens Recents' panel on top of it.
    let clipboardAnchor = NSView()
    private let recentsHost = NSView()
    private let spaces = NSSegmentedControl()
    private let pageActions = NSStackView()
    private let bellButton = NSButton()
    /// The unread count on the bell's corner. Drawn here rather than with
    /// `NSToolbarItem.badge`, which is macOS 26 only and absent from the SDK
    /// CI builds against.
    private let bellBadge = NSView()
    private let bellBadgeLabel = NSTextField(labelWithString: "")
    private let searchButton = NSButton()

    private var themeItem: NSToolbarItem?
    private var notificationsItem: NSToolbarItem?
    private var inspectorItem: NSToolbarItem?

    /// What the dynamic items should show. Reconciled against the toolbar's
    /// real items rather than cached as "done": a navigation before the
    /// toolbar is in a window (the launch landing) finds no items to insert
    /// beside, so `reconcileDynamicItems()` runs again once it is attached.
    private var wantsSpaces = false
    private var shownActions: [NSView] = []
    /// A page hides and shows its own buttons as its state changes (a vault
    /// that is not set up offers none of its four), so the item follows each
    /// button's `isHidden` rather than only the list it was handed.
    private var actionVisibilityObservations: [NSKeyValueObservation] = []

    init(splitView: NSSplitView) {
        self.splitView = splitView
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifier = ItemID.spaces
        buildControls()
    }

    // MARK: Build

    private func buildControls() {
        sidebarButton.image = symbol("sidebar.left")
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)
        sidebarButton.toolTip = "Show or hide the sidebar"
        sidebarButton.setAccessibilityLabel("Sidebar")

        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.setImage(symbol("chevron.left"), forSegment: 0)
        navigation.setImage(symbol("chevron.right"), forSegment: 1)
        navigation.setToolTip("Back", forSegment: 0)
        navigation.setToolTip("Forward", forSegment: 1)
        navigation.setWidth(32, forSegment: 0)
        navigation.setWidth(32, forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigationClicked(_:))
        navigation.setAccessibilityLabel("Back and Forward")
        setHistory(canGoBack: false, canGoForward: false)

        recentsButton.image = symbol("clock.arrow.circlepath")
        recentsButton.imagePosition = .imageOnly
        recentsButton.target = self
        recentsButton.action = #selector(recentsClicked)
        recentsButton.toolTip = "Recents"
        recentsButton.setAccessibilityLabel("Recents")
        recentsButton.translatesAutoresizingMaskIntoConstraints = false
        clipboardAnchor.translatesAutoresizingMaskIntoConstraints = false
        // Measured by its constraints, like every view item here - a
        // frame-sized host is what AppKit warns has "an ambiguous height or
        // width" and measures as zero.
        recentsHost.translatesAutoresizingMaskIntoConstraints = false
        recentsHost.addSubview(recentsButton)
        recentsHost.addSubview(clipboardAnchor)
        NSLayoutConstraint.activate([
            recentsButton.leadingAnchor.constraint(equalTo: recentsHost.leadingAnchor),
            recentsButton.trailingAnchor.constraint(equalTo: recentsHost.trailingAnchor),
            recentsButton.topAnchor.constraint(equalTo: recentsHost.topAnchor),
            recentsButton.bottomAnchor.constraint(equalTo: recentsHost.bottomAnchor),
            clipboardAnchor.leadingAnchor.constraint(equalTo: recentsButton.trailingAnchor),
            clipboardAnchor.trailingAnchor.constraint(equalTo: recentsButton.trailingAnchor),
            clipboardAnchor.topAnchor.constraint(equalTo: recentsButton.topAnchor),
            clipboardAnchor.bottomAnchor.constraint(equalTo: recentsButton.bottomAnchor),
        ])

        spaces.segmentCount = DaylightSpace.allCases.count
        for (index, space) in DaylightSpace.allCases.enumerated() {
            spaces.setLabel(space.title, forSegment: index)
            spaces.setToolTip("\(space.subtitle) (\u{2318}\(space.shortcutIndex))", forSegment: index)
        }
        spaces.trackingMode = .selectOne
        spaces.target = self
        spaces.action = #selector(spaceClicked(_:))
        spaces.setAccessibilityLabel("Home spaces")

        pageActions.translatesAutoresizingMaskIntoConstraints = false
        pageActions.orientation = .horizontal
        pageActions.alignment = .centerY
        pageActions.spacing = HelmMetrics.s2
        pageActions.distribution = .fill
        pageActions.setHuggingPriority(.required, for: .horizontal)

        bellButton.image = symbol("bell")
        bellButton.imagePosition = .imageOnly
        bellButton.target = self
        bellButton.action = #selector(notificationsClicked)
        bellButton.toolTip = "Notifications"
        bellButton.setAccessibilityLabel("Notifications")
        bellBadge.wantsLayer = true
        bellBadge.layer?.cornerRadius = Self.badgeHeight / 2
        bellBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        bellBadge.translatesAutoresizingMaskIntoConstraints = false
        bellBadge.isHidden = true
        bellBadgeLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(10), weight: .bold)
        bellBadgeLabel.textColor = .white
        bellBadgeLabel.alignment = .center
        bellBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        bellBadge.addSubview(bellBadgeLabel)
        bellButton.addSubview(bellBadge)
        NSLayoutConstraint.activate([
            bellBadge.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
            bellBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.badgeHeight),
            bellBadge.topAnchor.constraint(equalTo: bellButton.topAnchor, constant: -2),
            bellBadge.trailingAnchor.constraint(equalTo: bellButton.trailingAnchor, constant: 2),
            bellBadgeLabel.leadingAnchor.constraint(equalTo: bellBadge.leadingAnchor, constant: 3),
            bellBadgeLabel.trailingAnchor.constraint(equalTo: bellBadge.trailingAnchor, constant: -3),
            bellBadgeLabel.centerYAnchor.constraint(equalTo: bellBadge.centerYAnchor),
        ])

        searchButton.title = "Search"
        searchButton.image = symbol("magnifyingglass")
        searchButton.imagePosition = .imageLeading
        searchButton.target = self
        searchButton.action = #selector(searchClicked)
        searchButton.toolTip = "Search and commands (\u{2318}K)"
        searchButton.setAccessibilityLabel("Search")
        setSearchHint(ThemeManager.shared.theme)
    }

    private func symbol(_ name: String) -> NSImage? {
        HelmSymbol.image(name, pointSize: HelmType.scaled(14), weight: .medium)
    }

    /// "Search" and the ⌘K hint, the floating bar's search pill in system
    /// form: both in the theme's muted ink, the hint a step quieter, so the
    /// button still reads as one word.
    private func setSearchHint(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        let title = NSMutableAttributedString(string: "Search  ", attributes: [
            .font: NSFont.systemFont(ofSize: HelmType.scaled(13)),
            .foregroundColor: muted,
        ])
        title.append(NSAttributedString(string: "\u{2318}K", attributes: [
            .font: NSFont.systemFont(ofSize: HelmType.scaled(11.5)),
            .foregroundColor: muted.withAlphaComponent(muted.alphaComponent * 0.75),
        ]))
        searchButton.attributedTitle = title
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Two flexible spaces, so Home's spaces - inserted between them - sit
        // in the middle rather than against the trailing cluster.
        [ItemID.sidebar, .sidebarTrackingSeparator, ItemID.navigation, ItemID.recents, .flexibleSpace,
         .flexibleSpace, ItemID.theme, ItemID.notifications, ItemID.inspector, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ItemID.spaces, ItemID.pageActions]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .sidebarTrackingSeparator:
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        case ItemID.sidebar:
            return viewItem(identifier, view: sidebarButton, label: "Sidebar")
        case ItemID.navigation:
            let item = viewItem(identifier, view: navigation, label: "Back/Forward")
            item.isNavigational = true
            return item
        case ItemID.recents:
            let item = viewItem(identifier, view: recentsHost, label: "Recents")
            item.isNavigational = true
            return item
        case ItemID.spaces:
            return viewItem(identifier, view: spaces, label: "Spaces")
        case ItemID.pageActions:
            return viewItem(identifier, view: pageActions, label: "Page actions")
        case ItemID.theme:
            let item = imageItem(identifier, symbol: DaylightThemeToggleButton.lightSymbol, label: "Appearance",
                                 help: "", action: #selector(themeClicked))
            themeItem = item
            applyThemeSymbol(ThemeManager.shared.theme)
            return item
        case ItemID.notifications:
            let item = viewItem(identifier, view: bellButton, label: "Notifications")
            notificationsItem = item
            return item
        case ItemID.inspector:
            let item = imageItem(identifier, symbol: "sidebar.right", label: "Inspector",
                                 help: "Show or hide the inspector", action: #selector(inspectorClicked))
            inspectorItem = item
            return item
        case ItemID.search:
            return viewItem(identifier, view: searchButton, label: "Search")
        default:
            return nil
        }
    }

    private func imageItem(_ identifier: NSToolbarItem.Identifier, symbol name: String, label: String,
                           help: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = symbol(name)
        item.label = label
        item.paletteLabel = label
        item.toolTip = help
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private func viewItem(_ identifier: NSToolbarItem.Identifier, view: NSView, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        item.label = label
        item.paletteLabel = label
        return item
    }

    // MARK: State the shell pushes

    func setHistory(canGoBack: Bool, canGoForward: Bool) {
        navigation.setEnabled(canGoBack, forSegment: 0)
        navigation.setEnabled(canGoForward, forSegment: 1)
    }

    /// The spaces sit in the toolbar's centre on Home and nowhere else, which
    /// is where the floating bar showed its pills.
    func setSpaces(visible: Bool, selected: DaylightSpace) {
        if let index = DaylightSpace.allCases.firstIndex(of: selected) {
            spaces.selectedSegment = index
        }
        wantsSpaces = visible
        reconcileDynamicItems()
    }

    /// The showing page's own actions, or none. The views are the page's -
    /// the same ones the floating bar's drill header held - so a page needs
    /// no change to put its buttons here.
    func setPageActions(_ views: [NSView]) {
        guard views.map(ObjectIdentifier.init) != shownActions.map(ObjectIdentifier.init) else { return }
        shownActions = views
        for view in pageActions.arrangedSubviews {
            pageActions.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views { pageActions.addArrangedSubview(view) }
        actionVisibilityObservations = views.map { view in
            view.observe(\.isHidden) { [weak self] _, _ in self?.reconcileDynamicItems() }
        }
        reconcileDynamicItems()
    }

    /// Put the spaces and the page actions in the toolbar, or take them out,
    /// to match what was last asked for. Does nothing until the toolbar has
    /// its default items, which it gets once it is in a window.
    func reconcileDynamicItems() {
        guard !toolbar.items.isEmpty else { return }
        let hasSpaces = toolbar.items.contains { $0.itemIdentifier == ItemID.spaces }
        if wantsSpaces, !hasSpaces {
            // After the first flexible space, so the system centres it.
            let at = (toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace } ?? toolbar.items.count - 1) + 1
            toolbar.insertItem(withItemIdentifier: ItemID.spaces, at: at)
        } else if !wantsSpaces, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == ItemID.spaces }) {
            toolbar.removeItem(at: index)
        }
        let actionsIndex = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.pageActions }
        if !shownActions.contains(where: { !$0.isHidden }) {
            // No visible button: an empty item would still draw an empty
            // capsule on macOS 26, and AppKit warns it measures as zero.
            if let actionsIndex { toolbar.removeItem(at: actionsIndex) }
        } else if actionsIndex == nil {
            let at = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.theme } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: ItemID.pageActions, at: at)
        }
    }

    static let badgeHeight: CGFloat = 15

    /// The notifications button carries the bell's own count - the number
    /// the floating bar's bell draws, from the same store.
    func setNotificationCount(_ count: Int) {
        bellBadge.isHidden = count <= 0
        bellBadgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
        bellButton.setAccessibilityLabel(count > 0 ? "Notifications, \(count) unread" : "Notifications")
    }

    func setInspectorShown(_ shown: Bool) {
        inspectorItem?.toolTip = shown ? "Hide the inspector" : "Show the inspector"
    }

    func applyThemeSymbol(_ theme: HelmTheme) {
        setSearchHint(theme)
        let isDark = theme.mode == .dark
        themeItem?.image = symbol(isDark ? DaylightThemeToggleButton.darkSymbol : DaylightThemeToggleButton.lightSymbol)
        themeItem?.toolTip = DaylightThemeToggleButton.tooltip(isDark: isDark)
    }

    // MARK: Actions

    @objc private func sidebarClicked() { onToggleSidebar?() }
    @objc private func recentsClicked() { onRecents?(recentsButton) }
    @objc private func themeClicked() { onToggleTheme?() }
    @objc private func notificationsClicked() { onNotifications?(bellButton) }
    @objc private func inspectorClicked() { onToggleInspector?() }
    @objc private func searchClicked() { onSearch?() }

    @objc private func navigationClicked(_ sender: NSSegmentedControl) {
        // A momentary control reports the segment being clicked; anything
        // else (no segment) is neither direction.
        switch sender.selectedSegment {
        case 0: onBack?()
        case 1: onForward?()
        default: break
        }
    }

    @objc private func spaceClicked(_ sender: NSSegmentedControl) {
        let all = DaylightSpace.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < all.count else { return }
        onSelectSpace?(all[sender.selectedSegment])
    }

    #if FM_SELFTESTS
    /// The item identifiers in toolbar order - what the suite asserts the
    /// trailing cluster against.
    var debugItemIdentifiers: [NSToolbarItem.Identifier] { toolbar.items.map(\.itemIdentifier) }
    var debugPageActions: [NSView] { pageActions.arrangedSubviews }
    var debugNavigation: NSSegmentedControl { navigation }
    var debugSidebarButton: NSButton { sidebarButton }
    var debugSpaces: NSSegmentedControl { spaces }
    var debugBellButton: NSButton { bellButton }
    var debugRecentsButton: NSButton { recentsButton }
    var debugSearchButton: NSButton { searchButton }
    var debugNotificationsItem: NSToolbarItem? { notificationsItem }
    var debugBadgeText: String? { bellBadge.isHidden ? nil : bellBadgeLabel.stringValue }
    var debugThemeItem: NSToolbarItem? { themeItem }
    /// Fire an image item's action the way a click does.
    func debugPerform(_ identifier: NSToolbarItem.Identifier) -> Bool {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == identifier }),
              let action = item.action, let target = item.target as? NSObject else { return false }
        target.perform(action, with: item)
        return true
    }
    #endif
}
