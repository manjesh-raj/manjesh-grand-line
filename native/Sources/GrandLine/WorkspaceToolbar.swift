// Grand Line - native macOS app.
//
// The sidebar shell's window toolbar (stages 3 and 4 of the modular-shell
// migration).
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
//     same `RecentDestinationsController`), then the crumb - "Work › Crew",
//     the module and the group it sits in, as the prototype draws it,
//   - in the middle: the showing module's tabs, or on Home its five spaces,
//     which still filter Home's cards,
//   - the showing page's own actions (its `drillHeaderActions`, which the
//     floating bar drew in its drill header), and the module's one action
//     where a real verb has no other home in this layout (Home's Customize,
//     Connections' Activity),
//   - while a focus timer runs, F7's chip (the floating bar shows it beside
//     its search pill), just before the trailing cluster - it was on the
//     layout's status strip until the captain had the strip removed,
//   - Quick Connect, at the head of the trailing cluster on every module:
//     two separate icons, one for a Console terminal and one for a host, in a
//     capsule of their own (stage 7 drew them with a caption on Console only;
//     U-02, the captain's call, took the caption out and put them everywhere),
//   - the trailing cluster: the light/dark toggle and the notifications
//     button (the captain kept both), the calendar button (the Calendar page
//     from any page, the captain's ask), the inspector toggle, then Search,
//   - and last, at the far right after Search, the page's one primary action
//     where it has one (Add Host, Analyze, Copy diagnostics), as the
//     prototype draws it (stage 6, `WorkspacePrimaryActionProviding`).
//
// The toolbar draws state and forwards clicks; the shell decides what they
// mean.
//
// **The captain can customise it (R2-ARCH-06).** View > Customize Toolbar…
// (or a right click on the toolbar) moves, removes and adds back the items
// that are always there - Back and Forward, Recents, the crumb, the
// light/dark toggle, the bell, the calendar, the inspector button and Search - plus spaces,
// and picks the display mode. The items that come and go with the showing
// page - its tabs, its actions, the module's action, Quick Connect, the focus
// chip and the primary action - are not in the palette and cannot be dragged:
// `reconcileDynamicItems()` places them, and a palette-placed copy would
// fight it. The sidebar button and its tracking separator stay over the
// sidebar for the same reason.
//
// Nothing is autosaved by AppKit: `autosavesConfiguration` writes
// `UserDefaults.standard`, outside `AppDefaults.store`, which is the one thing
// this app's preferences must not do. The toolbar saves the customised items
// itself, to `AppSettings.workspaceToolbarItems`, and puts them back the
// first time it is in a window.

import AppKit

final class WorkspaceToolbar: NSObject, NSToolbarDelegate {

    enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("workspace.sidebar")
        static let navigation = NSToolbarItem.Identifier("workspace.navigation")
        static let recents = NSToolbarItem.Identifier("workspace.recents")
        static let crumb = NSToolbarItem.Identifier("workspace.crumb")
        static let tabs = NSToolbarItem.Identifier("workspace.tabs")
        static let pageActions = NSToolbarItem.Identifier("workspace.pageActions")
        static let moduleAction = NSToolbarItem.Identifier("workspace.moduleAction")
        static let theme = NSToolbarItem.Identifier("workspace.theme")
        static let notifications = NSToolbarItem.Identifier("workspace.notifications")
        static let calendar = NSToolbarItem.Identifier("workspace.calendar")
        static let inspector = NSToolbarItem.Identifier("workspace.inspector")
        static let search = NSToolbarItem.Identifier("workspace.search")
        static let primaryAction = NSToolbarItem.Identifier("workspace.primaryAction")
        static let focusTimer = NSToolbarItem.Identifier("workspace.focusTimer")
        /// Quick Connect's two icons, on every module (U-02).
        static let quickConnectConsole = NSToolbarItem.Identifier("workspace.quickConnect.console")
        static let quickConnectHosts = NSToolbarItem.Identifier("workspace.quickConnect.hosts")
        static let quickConnect = [quickConnectConsole, quickConnectHosts]
    }

    /// Quick Connect's two icons. Separate image items rather than one
    /// control with two segments, so each is its own button and the system
    /// groups them in one capsule the way it groups the light/dark toggle,
    /// the bell and the inspector toggle - two icons side by side, never one
    /// merged glyph (the captain's words: "lets not merge them").
    ///
    /// U-02: no caption. Each icon's label - what VoiceOver says and what the
    /// overflow menu lists - names Quick Connect and its target, since the
    /// word beside them is gone.
    enum QuickConnectIcon {
        static let consoleSymbol = "terminal"
        static let hostsSymbol = "server.rack"
        static let consoleLabel = "Quick Connect to Console"
        static let hostsLabel = "Quick Connect to a Host"
        static let consoleHelp = "Quick Connect to Console: go to your Console session, or open one if there is none"
        static let hostsHelp = "Quick Connect to a host: pick a saved host, or type ssh user@host"
    }

    /// The calendar button's glyph, shared by its live item and its palette
    /// copy. The Calendar's own sidebar glyph, so the button and the row it
    /// opens look like one thing.
    static var calendarSymbol: String { RailDestination.calendar.symbol }

    /// AppKit keeps every live toolbar with the same identifier in step -
    /// items and display mode alike - so a suite that stands a second one up
    /// beside the shell's (a "next launch") gives it an identifier of its own.
    static let identifier = "workspace.toolbar"
    let toolbar: NSToolbar

    // Forwarded, never owned.
    var onToggleSidebar: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onRecents: ((NSView) -> Void)?
    /// A tab was picked, by its index in what `setTabs` last showed.
    var onSelectTab: ((Int) -> Void)?
    var onModuleAction: (() -> Void)?
    /// Quick Connect's Console icon and its Hosts icon.
    var onQuickConnectConsole: (() -> Void)?
    var onQuickConnectHosts: (() -> Void)?
    var onToggleTheme: (() -> Void)?
    var onNotifications: ((NSView) -> Void)?
    /// The calendar button: the Calendar page, from whichever page is showing.
    var onCalendar: (() -> Void)?
    var onToggleInspector: (() -> Void)?
    var onSearch: (() -> Void)?
    /// R2-UX-10: the crumb's overflow form - show where you are in the sidebar.
    var onShowLocation: (() -> Void)?
    /// The focus timer chip was clicked; the view is where its popover hangs.
    var onFocusChip: ((NSView) -> Void)?

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
    private let crumb = NSTextField(labelWithString: "")
    private let tabs = NSSegmentedControl()
    private let pageActions = NSStackView()
    /// The page's primary action, after Search. A stack holding at most one
    /// view, so the toolbar item keeps one view while the page's button
    /// changes (Connections' three tabs each have their own).
    private let primaryActionHost = NSStackView()
    private var shownPrimary: NSView?
    private var primaryVisibilityObservation: NSKeyValueObservation?
    /// The tab names as the module declares them, without their counts -
    /// what `debugTabNames` reports and what a click is matched against.
    private var tabNames: [String] = []
    private let moduleActionButton = NSButton()
    /// Which of Quick Connect's two icons the toolbar shows, in order.
    private var wantedQuickConnect: [NSToolbarItem.Identifier] = []
    private var quickConnectConsoleItem: NSToolbarItem?
    private var quickConnectHostsItem: NSToolbarItem?
    private let bellButton = NSButton()
    /// The unread count on the bell's corner. Drawn here rather than with
    /// `NSToolbarItem.badge`, which is macOS 26 only and absent from the SDK
    /// CI builds against. R2-ARCH-06 re-measured that: CI's `macos-15` image
    /// builds with Swift 6.1.2 for `arm64-apple-macosx15.0`, where the symbol
    /// does not exist, so `#available(macOS 26, *)` around it would not
    /// compile there. Revisit when CI's toolchain moves to the macOS 26 SDK.
    private let bellBadge = NSView()
    private let bellBadgeLabel = NSTextField(labelWithString: "")
    private let searchButton = NSButton()
    /// F7's running timer. The floating bar's own chip; the toolbar draws it
    /// only while a session runs (`setFocusChip`).
    private let focusChip = FocusTimerChip()
    private var wantsFocusChip = false

    private var themeItem: NSToolbarItem?
    private var notificationsItem: NSToolbarItem?
    private var inspectorItem: NSToolbarItem?
    private var sidebarItem: NSToolbarItem?

    /// What the dynamic items should show. Reconciled against the toolbar's
    /// real items rather than cached as "done": a navigation before the
    /// toolbar is in a window (the launch landing) finds no items to insert
    /// beside, so `reconcileDynamicItems()` runs again once it is attached.
    private var wantsTabs = false
    private var wantsModuleAction = false
    private var crumbParts: (group: String?, module: String) = (nil, "")
    /// The prototype's narrow toolbar, below `compactWidth`: Search is its
    /// glyph, the crumb names only the module, and the focus chip shows its
    /// ring and countdown without the task's name.
    private var isCompact = false

    /// The prototype's own breakpoint. At 1100 a module with five tabs left no
    /// room for Search, the bell or the light/dark toggle, and AppKit put all
    /// three in the overflow menu (measured on Knowledge).
    static let compactWidth: CGFloat = 1240

    /// R4-UI-01: `compactWidth` at the chrome text scale. The breakpoint was
    /// measured at Default text, and at Larger every labelled item is wider
    /// (the crumb 137pt to 171pt and Search 107pt to 130pt on Connections),
    /// so at 1512 the full toolbar ran out of room on four modules and put the
    /// inspector button in the overflow menu. Scaled linearly, the same rule
    /// the content column's floor follows: at Larger the compact toolbar
    /// starts at 1612.
    static func compactWidth(scale: CGFloat) -> CGFloat { (compactWidth * scale).rounded(.up) }
    private var shownActions: [NSView] = []
    /// R2-UX-06: the page actions' overflow form.
    private var pageActionsMenu: NSMenu?
    /// A page hides and shows its own buttons as its state changes (a vault
    /// that is not set up offers none of its four), so the item follows each
    /// button's `isHidden` rather than only the list it was handed.
    private var actionVisibilityObservations: [NSKeyValueObservation] = []

    init(splitView: NSSplitView, identifier: String = WorkspaceToolbar.identifier) {
        self.splitView = splitView
        toolbar = NSToolbar(identifier: identifier)
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = AppSettings.shared.workspaceToolbarDisplayMode
            .flatMap { NSToolbar.DisplayMode(rawValue: UInt(clamping: $0)) } ?? .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifier = ItemID.tabs
        buildControls()
        // The customisation sheet ends: put the page's items back where
        // they belong (Use Default Set drops them) and save what it left.
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? NSWindow)?.toolbar === self.toolbar else { return }
            self.reconcileDynamicItems()
            self.saveConfiguration()
        }
    }

    deinit {
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    }

    // MARK: Customisation (R2-ARCH-06)

    /// The items the captain can move, remove and add back. Always present
    /// by default, and each one's own view or image.
    static let customizableItems: [NSToolbarItem.Identifier] = [
        ItemID.navigation, ItemID.recents, ItemID.crumb, ItemID.theme, ItemID.notifications, ItemID.calendar,
        ItemID.inspector, ItemID.search,
    ]

    /// The items the page and the module bring and take away. Placed only by
    /// `reconcileDynamicItems()`, so they are neither in the palette nor
    /// movable.
    static let dynamicItems: [NSToolbarItem.Identifier] = [
        ItemID.tabs, ItemID.pageActions, ItemID.moduleAction, ItemID.primaryAction, ItemID.focusTimer,
    ] + ItemID.quickConnect

    /// The two that sit over the sidebar and nowhere else.
    static let fixedItems: [NSToolbarItem.Identifier] = [ItemID.sidebar, .sidebarTrackingSeparator]

    private var sheetObserver: NSObjectProtocol?
    /// Set while this toolbar changes its own items, so only the captain's
    /// changes are saved.
    private var isArrangingItems = false
    /// Whether the saved items have been put back. Until then a change is
    /// the toolbar loading its default items, which must not overwrite them.
    private var savedConfigurationApplied = false

    /// The customisable items and spaces as they stand, in order - what is
    /// saved. The space `reconcileDynamicItems()` puts after Quick Connect
    /// is the toolbar's, not the captain's, so it is left out.
    var customizedIdentifiers: [NSToolbarItem.Identifier] {
        let ownSpace = quickConnectSpaceIndex
        return toolbar.items.enumerated().compactMap { index, item in
            let id = item.itemIdentifier
            guard index != ownSpace else { return nil }
            return Self.customizableItems.contains(id) || id == .space || id == .flexibleSpace ? id : nil
        }
    }

    /// The same list for the shipped default.
    static var defaultCustomizedIdentifiers: [NSToolbarItem.Identifier] {
        WorkspaceToolbar.defaultIdentifiers.filter { !fixedItems.contains($0) }
    }

    /// `saved`, with anything this build does not know dropped and no
    /// customisable item twice - `NSToolbar` raises on a duplicate item.
    static func sanitized(_ saved: [String]) -> [NSToolbarItem.Identifier] {
        var seen = Set<NSToolbarItem.Identifier>()
        var kept: [NSToolbarItem.Identifier] = []
        for raw in saved {
            let id = NSToolbarItem.Identifier(raw)
            if id == .space || id == .flexibleSpace {
                kept.append(id)
            } else if customizableItems.contains(id), seen.insert(id).inserted {
                kept.append(id)
            }
        }
        return kept
    }

    /// Save the customised items to `AppSettings`, or clear the setting when
    /// they are the default again.
    func saveConfiguration() {
        guard savedConfigurationApplied, !isArrangingItems else { return }
        let ids = customizedIdentifiers
        let customised: [String]? = ids == Self.defaultCustomizedIdentifiers ? nil : ids.map { $0.rawValue }
        AppSettings.shared.workspaceToolbarItems = customised
        AppSettings.shared.workspaceToolbarDisplayMode = toolbar.displayMode == .iconOnly ? nil
            : Int(toolbar.displayMode.rawValue)
    }

    /// Put the saved items back, once, the first time the toolbar has its
    /// default items. The page's items are placed after this by
    /// `reconcileDynamicItems()`, around whatever the captain kept.
    private func applySavedConfiguration() {
        guard !savedConfigurationApplied else { return }
        defer { savedConfigurationApplied = true }
        guard let saved = AppSettings.shared.workspaceToolbarItems else { return }
        let wanted = Self.sanitized(saved)
        isArrangingItems = true
        defer { isArrangingItems = false }
        for index in toolbar.items.indices.reversed() where !Self.fixedItems.contains(toolbar.items[index].itemIdentifier) {
            toolbar.removeItem(at: index)
        }
        for identifier in wanted { toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count) }
    }

    func toolbarWillAddItem(_ notification: Notification) { captainChangedItems() }
    func toolbarDidRemoveItem(_ notification: Notification) { captainChangedItems() }

    /// A change this toolbar did not make is the captain's: from the
    /// customisation sheet, or a ⌘-drag on the toolbar itself. Saved once it
    /// has landed.
    private func captainChangedItems() {
        guard savedConfigurationApplied, !isArrangingItems else { return }
        DispatchQueue.main.async { [weak self] in self?.saveConfiguration() }
    }

    // MARK: Build

    private func buildControls() {
        sidebarButton.image = symbol("sidebar.left")
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)
        applySidebarButtonState()

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

        crumb.lineBreakMode = .byTruncatingTail
        crumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crumb.setAccessibilityRole(.staticText)

        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabClicked(_:))

        moduleActionButton.imagePosition = .imageLeading
        moduleActionButton.target = self
        moduleActionButton.action = #selector(moduleActionClicked)

        pageActions.translatesAutoresizingMaskIntoConstraints = false
        pageActions.orientation = .horizontal
        pageActions.alignment = .centerY
        pageActions.spacing = HelmMetrics.s2
        pageActions.distribution = .fill
        pageActions.setHuggingPriority(.required, for: .horizontal)
        primaryActionHost.translatesAutoresizingMaskIntoConstraints = false
        primaryActionHost.orientation = .horizontal
        primaryActionHost.alignment = .centerY
        primaryActionHost.distribution = .fill
        primaryActionHost.setHuggingPriority(.required, for: .horizontal)

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

        // `HoverHighlightView` reads its primary action off a real click
        // recognizer (`performPrimaryAction`, which is also what makes the
        // chip keyboard-activatable under GL-16) - the floating bar wires it
        // the same way.
        focusChip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(focusChipClicked)))
    }

    private func symbol(_ name: String) -> NSImage? {
        HelmSymbol.image(name, pointSize: HelmType.scaled(14), weight: .medium)
    }

    /// "Search" and the ⌘K hint, the floating bar's search pill in system
    /// form: both in the theme's muted ink, the hint a step quieter, so the
    /// button still reads as one word.
    private func setSearchHint(_ theme: HelmTheme) {
        guard !isCompact else {
            searchButton.attributedTitle = NSAttributedString(string: "")
            return
        }
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

    /// Two flexible spaces, so the tabs - inserted between them - sit in the
    /// middle rather than against the trailing cluster.
    static let defaultIdentifiers: [NSToolbarItem.Identifier] = [
        ItemID.sidebar, .sidebarTrackingSeparator, ItemID.navigation, ItemID.recents, ItemID.crumb, .flexibleSpace,
        .flexibleSpace, ItemID.theme, ItemID.notifications, ItemID.calendar, ItemID.inspector, ItemID.search,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultIdentifiers
    }

    /// What the customisation palette offers. The page's own items are not
    /// here: `NSToolbar` inserts an identifier from code whether or not it is
    /// allowed (measured), so `reconcileDynamicItems()` still places them.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultIdentifiers + [.space]
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        Set(Self.fixedItems + Self.dynamicItems)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // The palette's copy of an item. Several items are a view this
        // toolbar owns, and an `NSView` has one superview, so a palette item
        // built around the live view would take it out of the toolbar.
        guard flag else { return paletteItem(identifier) }
        let item = makeItem(identifier)
        // When the toolbar runs out of room AppKit moves items into its
        // overflow menu, lowest priority first. The crumb (the module's
        // header names it too), Recents and the inspector toggle go first;
        // Search, the bell, the light/dark toggle, the tabs, the page's
        // primary action and the sidebar button never do. Between them, the
        // module's one action goes next (its menu form does what its button
        // does), then a running focus timer's chip (its menu form opens the
        // same popover), and the page's own actions last, whose overflow form
        // would do nothing - measured at 1100 on Knowledge, whose five tabs
        // leave room for the page's actions or the chip, and on Home, where
        // Customize and the chip did not both fit.
        // Quick Connect's icons (U-02) go after the chip and before the
        // page's actions: they are on every module now, so a narrow window
        // keeps them over the module's action and the chip, and their menu
        // forms work in the overflow menu, where the page's actions would not.
        switch identifier {
        case ItemID.recents: item?.visibilityPriority = .low
        case ItemID.inspector: item?.visibilityPriority = inspectorPriorityNow
        case ItemID.crumb: item?.visibilityPriority = crumbPriorityNow
        case ItemID.moduleAction: item?.visibilityPriority = Self.moduleActionPriority
        case ItemID.quickConnectConsole, ItemID.quickConnectHosts: item?.visibilityPriority = quickConnectPriorityNow
        case ItemID.focusTimer: item?.visibilityPriority = Self.focusChipPriority
        case ItemID.pageActions: item?.visibilityPriority = pageActionsPriorityNow
        case ItemID.search, ItemID.notifications, ItemID.theme, ItemID.tabs, ItemID.sidebar, ItemID.navigation,
             ItemID.primaryAction:
            item?.visibilityPriority = .high
        default: break
        }
        return item
    }

    private func makeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .sidebarTrackingSeparator:
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        case ItemID.sidebar:
            let item = viewItem(identifier, view: sidebarButton, label: Self.sidebarButtonLabel(shown: sidebarShown))
            item.paletteLabel = "Sidebar"
            sidebarItem = item
            return item
        case ItemID.navigation:
            let item = viewItem(identifier, view: navigation, label: "Back/Forward")
            item.isNavigational = true
            return item
        case ItemID.recents:
            let item = viewItem(identifier, view: recentsHost, label: "Recents")
            item.isNavigational = true
            // In the overflow menu a view item does nothing without a menu
            // form, and its button is out of the window, so the panel opens
            // under Back and Forward, which never overflow.
            let menuForm = NSMenuItem(title: "Recents", action: #selector(recentsFromOverflow), keyEquivalent: "")
            menuForm.target = self
            item.menuFormRepresentation = menuForm
            return item
        case ItemID.crumb:
            let item = viewItem(identifier, view: crumb, label: "Location")
            // R2-UX-10: beside a showing sidebar at a laptop width the crumb
            // is the first item to overflow, and a view item does nothing
            // from the overflow menu without a form of its own. Its form
            // shows the same place in the sidebar, as ⌘⇧D does.
            let form = NSMenuItem(title: "Show in Sidebar", action: #selector(showLocationFromOverflow), keyEquivalent: "")
            form.target = self
            item.menuFormRepresentation = form
            return item
        case ItemID.tabs:
            return viewItem(identifier, view: tabs, label: "Tabs")
        case ItemID.pageActions:
            let item = viewItem(identifier, view: pageActions, label: "Page actions")
            // R2-UX-06: Console, Code and Notebook moved their whole action
            // clusters up here, so on a narrow window this item can overflow
            // - and a view item in the overflow menu does nothing without a
            // menu form. The form is rebuilt from the page's visible controls
            // each time the overflow menu opens.
            let menuForm = NSMenuItem(title: "Page Actions", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Page Actions")
            submenu.delegate = self
            menuForm.submenu = submenu
            item.menuFormRepresentation = menuForm
            pageActionsMenu = submenu
            return item
        case ItemID.primaryAction:
            return viewItem(identifier, view: primaryActionHost, label: "Primary action")
        case ItemID.moduleAction:
            let item = viewItem(identifier, view: moduleActionButton, label: moduleActionButton.title)
            let menuForm = NSMenuItem(title: moduleActionButton.title, action: #selector(moduleActionClicked), keyEquivalent: "")
            menuForm.target = self
            item.menuFormRepresentation = menuForm
            return item
        case ItemID.quickConnectConsole:
            let item = imageItem(identifier, symbol: QuickConnectIcon.consoleSymbol, label: QuickConnectIcon.consoleLabel,
                                 help: QuickConnectIcon.consoleHelp, action: #selector(quickConnectConsoleClicked))
            item.image?.accessibilityDescription = QuickConnectIcon.consoleLabel
            quickConnectConsoleItem = item
            return item
        case ItemID.quickConnectHosts:
            let item = imageItem(identifier, symbol: QuickConnectIcon.hostsSymbol, label: QuickConnectIcon.hostsLabel,
                                 help: QuickConnectIcon.hostsHelp, action: #selector(quickConnectHostsClicked))
            item.image?.accessibilityDescription = QuickConnectIcon.hostsLabel
            quickConnectHostsItem = item
            return item
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
        case ItemID.calendar:
            let item = imageItem(identifier, symbol: Self.calendarSymbol, label: "Calendar",
                                 help: "Open the Calendar", action: #selector(calendarClicked))
            item.image?.accessibilityDescription = "Calendar"
            return item
        case ItemID.inspector:
            let item = imageItem(identifier, symbol: inspectorSymbolName, label: inspectorLabel,
                                 help: inspectorHelp, action: #selector(inspectorClicked))
            item.paletteLabel = "Inspector"
            inspectorItem = item
            return item
        case ItemID.search:
            return viewItem(identifier, view: searchButton, label: "Search")
        case ItemID.focusTimer:
            let item = viewItem(identifier, view: focusChip, label: "Focus timer")
            // Recents' reason: in the overflow menu a view item needs a menu
            // form, and its chip is out of the window, so the popover hangs
            // under Back and Forward, which never overflow.
            let menuForm = NSMenuItem(title: "Focus Timer", action: #selector(focusChipFromOverflow), keyEquivalent: "")
            menuForm.target = self
            item.menuFormRepresentation = menuForm
            return item
        default:
            return nil
        }
    }

    /// What the customisation palette draws for `identifier`: its symbol
    /// and its label, and nothing live.
    private func paletteItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let symbols: [NSToolbarItem.Identifier: (String, String)] = [
            ItemID.sidebar: ("sidebar.left", "Sidebar"),
            ItemID.navigation: ("chevron.left.chevron.right", "Back/Forward"),
            ItemID.recents: ("clock.arrow.circlepath", "Recents"),
            ItemID.crumb: ("signpost.right", "Location"),
            ItemID.theme: (DaylightThemeToggleButton.lightSymbol, "Appearance"),
            ItemID.notifications: ("bell", "Notifications"),
            ItemID.calendar: (Self.calendarSymbol, "Calendar"),
            ItemID.inspector: (Self.inspectorOnSymbol, "Inspector"),
            ItemID.search: ("magnifyingglass", "Search"),
        ]
        guard let (name, label) = symbols[identifier] else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = symbol(name)
        item.label = label
        item.paletteLabel = label
        return item
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

    /// The crumb: the module, after the group it sits in. Home has no group.
    func setCrumb(group: String?, module: String) {
        crumbParts = (group, module)
        applyCrumb(ThemeManager.shared.theme)
    }

    /// Narrow or not, from the window's width.
    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        for item in toolbar.items where ItemID.quickConnect.contains(item.itemIdentifier) {
            item.visibilityPriority = quickConnectPriorityNow
        }
        toolbar.items.first { $0.itemIdentifier == ItemID.pageActions }?.visibilityPriority = pageActionsPriorityNow
        toolbar.items.first { $0.itemIdentifier == ItemID.crumb }?.visibilityPriority = crumbPriorityNow
        searchButton.imagePosition = compact ? .imageOnly : .imageLeading
        focusChip.showsTitle = !compact
        setSearchHint(ThemeManager.shared.theme)
        applyCrumb(ThemeManager.shared.theme)
    }

    private func applyCrumb(_ theme: HelmTheme) {
        let text = NSMutableAttributedString()
        if let group = crumbParts.group, !isCompact {
            text.append(NSAttributedString(string: "\(group)  \u{203A}  ", attributes: [
                .font: NSFont.systemFont(ofSize: HelmType.scaled(13)),
                .foregroundColor: HelmTheme.mutedInk(theme),
            ]))
        }
        text.append(NSAttributedString(string: crumbParts.module, attributes: [
            .font: NSFont.systemFont(ofSize: HelmType.scaled(13.5), weight: .semibold),
            .foregroundColor: HelmTheme.nsColor(theme.chromeInkHex),
        ]))
        crumb.attributedStringValue = text
        crumb.setAccessibilityLabel(crumbParts.group.map { "\($0), \(crumbParts.module)" } ?? crumbParts.module)
    }

    /// The tabs in the toolbar's centre - a module's tabs, or Home's spaces -
    /// or none. `tooltips` and `counts` run parallel to `names`; a count is
    /// drawn after its tab's name, as the prototype's "Hosts 7" (stage 6).
    func setTabs(_ names: [String], counts: [Int?] = [], tooltips: [String?] = [], selected: Int?,
                 accessibilityLabel: String = "Tabs") {
        tabNames = names
        let labels = names.enumerated().map { index, name in
            Self.tabLabel(name, count: index < counts.count ? counts[index] : nil)
        }
        if tabs.segmentCount != labels.count || (0..<labels.count).contains(where: { tabs.label(forSegment: $0) != labels[$0] }) {
            tabs.segmentCount = labels.count
            for (index, label) in labels.enumerated() {
                tabs.setLabel(label, forSegment: index)
                tabs.setWidth(0, forSegment: index)
            }
        }
        for index in 0..<names.count {
            tabs.setToolTip(index < tooltips.count ? tooltips[index] : nil, forSegment: index)
        }
        tabs.selectedSegment = selected ?? -1
        tabs.setAccessibilityLabel(accessibilityLabel)
        wantsTabs = !names.isEmpty
        reconcileDynamicItems()
    }

    /// A tab's label: its name, then its count when it has one. A segment
    /// label is one plain string, so the count is set off by a figure space
    /// rather than drawn in a quieter ink.
    static func tabLabel(_ name: String, count: Int?) -> String {
        guard let count else { return name }
        return "\(name)\u{2002}\(count)"
    }

    /// The module's one action, or none.
    func setModuleAction(title: String?, symbol name: String? = nil, tooltip: String? = nil) {
        moduleActionButton.title = title ?? ""
        moduleActionButton.image = name.flatMap(symbol)
        moduleActionButton.toolTip = tooltip
        moduleActionButton.setAccessibilityLabel(title)
        if let item = toolbar.items.first(where: { $0.itemIdentifier == ItemID.moduleAction }) {
            item.label = title ?? ""
            item.menuFormRepresentation?.title = title ?? ""
        }
        wantsModuleAction = title != nil
        reconcileDynamicItems()
    }

    /// Quick Connect's icons: Console's, Hosts', both or neither. Every
    /// module shows both (U-02) unless the captain's profile hides the module
    /// an icon opens.
    func setQuickConnect(console: Bool, hosts: Bool) {
        let wanted = (console ? [ItemID.quickConnectConsole] : []) + (hosts ? [ItemID.quickConnectHosts] : [])
        guard wanted != wantedQuickConnect else { return }
        wantedQuickConnect = wanted
        reconcileDynamicItems()
    }

    /// The showing page's own actions, or none. The views are the page's -
    /// the same ones the floating bar's drill header held - so a page needs
    /// no change to put its buttons here.
    func setPageActions(_ views: [NSView]) {
        // R2-UX-04: one filled button per page, at the far right. A page
        // action is outlined however its page drew it in the floating bar.
        for case let button as HelmButton in views where button.variant == .primary { button.variant = .secondary }
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

    /// The page's primary action, after Search, or none. The view is the
    /// page's own, like `setPageActions`'.
    func setPrimaryAction(_ view: NSView?) {
        // R2-UX-04: the page's primary verb is the far-right filled button,
        // whatever variant the page gave it for the floating bar.
        if let button = view as? HelmButton, button.variant != .primary { button.variant = .primary }
        guard view !== shownPrimary else { return }
        shownPrimary = view
        for old in primaryActionHost.arrangedSubviews {
            primaryActionHost.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        if let view { primaryActionHost.addArrangedSubview(view) }
        primaryVisibilityObservation = view?.observe(\.isHidden) { [weak self] _, _ in self?.reconcileDynamicItems() }
        reconcileDynamicItems()
    }

    /// Put the spaces and the page actions in the toolbar, or take them out,
    /// to match what was last asked for. Does nothing until the toolbar has
    /// its default items, which it gets once it is in a window.
    func reconcileDynamicItems() {
        guard !toolbar.items.isEmpty else { return }
        applySavedConfiguration()
        isArrangingItems = true
        defer { isArrangingItems = false }
        let hasTabs = toolbar.items.contains { $0.itemIdentifier == ItemID.tabs }
        if wantsTabs, !hasTabs {
            // After the first flexible space, so the system centres it.
            let at = (toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace } ?? toolbar.items.count - 1) + 1
            toolbar.insertItem(withItemIdentifier: ItemID.tabs, at: at)
        } else if !wantsTabs, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == ItemID.tabs }) {
            toolbar.removeItem(at: index)
        }
        let actionsIndex = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.pageActions }
        if !shownActions.contains(where: { !$0.isHidden }) {
            // No visible button: an empty item would still draw an empty
            // capsule on macOS 26, and AppKit warns it measures as zero.
            if let actionsIndex { toolbar.removeItem(at: actionsIndex) }
        } else if actionsIndex == nil {
            toolbar.insertItem(withItemIdentifier: ItemID.pageActions, at: beforeTheFocusChipAndTheCluster)
        }
        let moduleActionIndex = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.moduleAction }
        if !wantsModuleAction {
            if let moduleActionIndex { toolbar.removeItem(at: moduleActionIndex) }
        } else if moduleActionIndex == nil {
            toolbar.insertItem(withItemIdentifier: ItemID.moduleAction, at: beforeTheFocusChipAndTheCluster)
        }
        // Quick Connect's icons go in together and in order, just before the
        // light/dark toggle, and a space follows them. Without it the system
        // draws adjacent icons as one capsule, and the two icons became the
        // first two of five with the trailing cluster's (measured in a real
        // render), which is not the one group of two the captain asked for.
        let shownQuickConnect = toolbar.items.filter { ItemID.quickConnect.contains($0.itemIdentifier) }
        if wantedQuickConnect.isEmpty {
            removeQuickConnect()
        } else if shownQuickConnect.map(\.itemIdentifier) != wantedQuickConnect || quickConnectSpaceIndex == nil {
            removeQuickConnect()
            let at = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.theme } ?? toolbar.items.count
            for (offset, identifier) in (wantedQuickConnect + [.space]).enumerated() {
                toolbar.insertItem(withItemIdentifier: identifier, at: at + offset)
            }
        }
        let focusIndex = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.focusTimer }
        if !wantsFocusChip {
            if let focusIndex { toolbar.removeItem(at: focusIndex) }
        } else if focusIndex == nil {
            // Just before the trailing cluster - Quick Connect's icons, then
            // the light/dark toggle - after the page's and the module's
            // actions.
            toolbar.insertItem(withItemIdentifier: ItemID.focusTimer, at: beforeQuickConnectAndTheCluster)
        }
        let primaryIndex = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.primaryAction }
        if shownPrimary.map({ $0.isHidden }) ?? true {
            if let primaryIndex { toolbar.removeItem(at: primaryIndex) }
        } else if primaryIndex == nil {
            // The far right: after Search, which is the last default item.
            let at = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.search }.map { $0 + 1 } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: ItemID.primaryAction, at: at)
        }
    }

    /// Where a page's or a module's action goes in: before the focus chip
    /// when it shows, and before the trailing cluster otherwise - so the
    /// chip stays beside the cluster whichever came into the toolbar first.
    private var beforeTheFocusChipAndTheCluster: Int {
        toolbar.items.firstIndex {
            $0.itemIdentifier == ItemID.focusTimer || ItemID.quickConnect.contains($0.itemIdentifier)
                || $0.itemIdentifier == ItemID.theme
        } ?? toolbar.items.count
    }

    /// Where the focus chip goes in: before Quick Connect's icons when they
    /// show, and before the light/dark toggle otherwise.
    private var beforeQuickConnectAndTheCluster: Int {
        toolbar.items.firstIndex {
            ItemID.quickConnect.contains($0.itemIdentifier) || $0.itemIdentifier == ItemID.theme
        } ?? toolbar.items.count
    }

    /// The space Quick Connect puts after its last icon, when it is there.
    /// Found by position, so a space anywhere else is never taken for it.
    private var quickConnectSpaceIndex: Int? {
        guard let last = toolbar.items.lastIndex(where: { ItemID.quickConnect.contains($0.itemIdentifier) }),
              last + 1 < toolbar.items.count, toolbar.items[last + 1].itemIdentifier == .space else { return nil }
        return last + 1
    }

    private func removeQuickConnect() {
        if let space = quickConnectSpaceIndex { toolbar.removeItem(at: space) }
        for index in toolbar.items.indices.reversed()
        where ItemID.quickConnect.contains(toolbar.items[index].itemIdentifier) {
            toolbar.removeItem(at: index)
        }
    }

    /// Between `.low` (-1000) and `.standard` (0), which the page's actions
    /// take: the module's action overflows before the chip.
    static let moduleActionPriority = NSToolbarItem.VisibilityPriority(rawValue: -750)
    static let focusChipPriority = NSToolbarItem.VisibilityPriority(rawValue: -500)
    /// U-02: above the chip, below the page's actions (`.standard`).
    static let quickConnectPriority = NSToolbarItem.VisibilityPriority(rawValue: -250)
    /// U-02, in the compact toolbar: first to the overflow menu, where both
    /// icons still work by their labels. Measured at 1100 on Knowledge's
    /// Notebook, the one module crowded enough to overflow there: at the
    /// full-width priority the two icons pushed Recents and the inspector
    /// button out, which R2-BUG-07 had just kept on the toolbar.
    static let quickConnectCompactPriority = NSToolbarItem.VisibilityPriority(rawValue: -1100)

    private var quickConnectPriorityNow: NSToolbarItem.VisibilityPriority {
        isCompact ? Self.quickConnectCompactPriority : Self.quickConnectPriority
    }

    /// R2-UX-06, in the compact toolbar: the page's actions yield before the
    /// crumb, now that their overflow form runs each of them. Measured at
    /// 1100 on Notebook, whose five tabs leave room for one of the two: the
    /// crumb is the module's one name (R2-UX-05), and the actions are one
    /// overflow menu away. At full width they stay `.standard`, above it.
    static let pageActionsCompactPriority = NSToolbarItem.VisibilityPriority(rawValue: -300)

    private var pageActionsPriorityNow: NSToolbarItem.VisibilityPriority {
        isCompact ? Self.pageActionsCompactPriority : .standard
    }
    /// The crumb names the module, and R2-UX-05 made it the one place that
    /// does, so it outlasts Quick Connect, the chip and the module's action -
    /// measured on Knowledge, whose five tabs left the crumb the first thing
    /// to go at 1512 once Quick Connect was on every module.
    static let crumbPriority = NSToolbarItem.VisibilityPriority(rawValue: -100)
    /// R2-UX-10: in the compact toolbar beside a showing sidebar, the
    /// sidebar's selection names the module and the tab, so the crumb says
    /// nothing it does not and is the first item to yield. Keeping the
    /// sidebar at laptop widths leaves the toolbar about 250pt less beside
    /// it, and measured at 1100 on Knowledge that is the crumb or the page's
    /// actions. At full width, and with the sidebar put away, the crumb keeps
    /// `crumbPriority`.
    static let crumbSidebarShownPriority = NSToolbarItem.VisibilityPriority(rawValue: -1200)

    private var sidebarShown = true
    private var crumbPriorityNow: NSToolbarItem.VisibilityPriority {
        sidebarShown && isCompact ? Self.crumbSidebarShownPriority : Self.crumbPriority
    }

    /// Whether the window's sidebar is showing (R2-UX-10).
    func setSidebarShown(_ shown: Bool) {
        guard shown != sidebarShown else { return }
        sidebarShown = shown
        toolbar.items.first { $0.itemIdentifier == ItemID.crumb }?.visibilityPriority = crumbPriorityNow
        applySidebarButtonState()
    }

    /// R2-A11Y-03: the sidebar button says what a click will do, in its
    /// label and its tooltip alike. It used to be "Sidebar" to VoiceOver
    /// whichever way it went, with only the tooltip saying "Show or hide".
    /// The item's label is what the overflow menu and the Icon and Text mode
    /// show, so it follows too. The customisation palette keeps "Sidebar".
    private func applySidebarButtonState() {
        let label = Self.sidebarButtonLabel(shown: sidebarShown)
        sidebarButton.toolTip = sidebarShown ? "Hide the sidebar" : "Show the sidebar"
        sidebarButton.setAccessibilityLabel(label)
        sidebarItem?.label = label
    }

    static func sidebarButtonLabel(shown: Bool) -> String { shown ? "Hide Sidebar" : "Show Sidebar" }

    static let badgeHeight: CGFloat = 15

    /// The notifications button carries the bell's own count - the number
    /// the floating bar's bell draws, from the same store.
    func setNotificationCount(_ count: Int) {
        bellBadge.isHidden = count <= 0
        bellBadgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
        bellButton.setAccessibilityLabel(count > 0 ? "Notifications, \(count) unread" : "Notifications")
    }

    /// F7's chip, from the running session, or no chip at all while nothing
    /// runs. The values are the `FocusTimerController`'s own, so the chip and
    /// every other surface read one clock.
    func setFocusChip(_ state: (fraction: Double, countdown: String, title: String, paused: Bool)?) {
        if let state {
            focusChip.configure(fraction: state.fraction, countdown: state.countdown, title: state.title,
                                paused: state.paused)
            focusChip.applyTheme(ThemeManager.shared.theme)
        }
        guard wantsFocusChip != (state != nil) else { return }
        wantsFocusChip = state != nil
        reconcileDynamicItems()
    }

    /// The inspector button while the inspector opens itself on a selection
    /// (a filled right-hand pane), and while the captain has turned that off
    /// (the outline).
    static let inspectorOnSymbol = "inset.filled.rightthird.rectangle"
    static let inspectorOffSymbol = "sidebar.right"
    private var inspectorSymbolName = WorkspaceToolbar.inspectorOnSymbol
    /// The pane starts closed and wanted (`MainSplitShellController`).
    private var inspectorLabel = WorkspaceToolbar.inspectorLabel(shown: false)
    private var inspectorHelp = "Show the inspector"

    /// R2-BUG-10: whether the pane is showing, and whether the captain's
    /// standing choice still opens it on a selection. Closing the inspector
    /// turns that choice off for the session, and nothing on screen used to
    /// say so: a credential selected an hour later simply showed nothing.
    /// The button now draws the choice, and its tooltip names it.
    ///
    /// R2-A11Y-03: the label flips with the tooltip. For an image item it is
    /// the label VoiceOver reads (measured: the item's viewer is the
    /// accessibility button and takes the item's `label`), so a fixed
    /// "Inspector" said nothing about what a press would do.
    func setInspectorState(shown: Bool, wanted: Bool) {
        inspectorSymbolName = wanted ? Self.inspectorOnSymbol : Self.inspectorOffSymbol
        inspectorLabel = Self.inspectorLabel(shown: shown)
        inspectorHelp = shown ? "Hide the inspector"
            : wanted ? "Show the inspector"
            : "The inspector is off, so selecting an item does not open it. Click to turn it back on."
        inspectorItem?.image = symbol(inspectorSymbolName)
        inspectorItem?.label = inspectorLabel
        inspectorItem?.toolTip = inspectorHelp
    }

    static func inspectorLabel(shown: Bool) -> String { shown ? "Hide Inspector" : "Show Inspector" }

    /// R4-UI-01: on a page that fills the inspector (Connections, Secrets,
    /// Setup, GitHub Sync) the inspector button is how the captain gets back
    /// to the editing surface, so it outlasts Quick Connect, the module's
    /// action and the crumb. Measured at 1512 on Connections, it was the first
    /// thing AppKit put in the overflow menu, ahead of Recents. On every other
    /// page it has nothing to open and keeps `.low`.
    private var pageHasInspectorContent = false
    private var inspectorPriorityNow: NSToolbarItem.VisibilityPriority {
        pageHasInspectorContent ? .high : .low
    }

    /// Whether the showing page fills the inspector.
    func setPageHasInspectorContent(_ has: Bool) {
        guard has != pageHasInspectorContent else { return }
        pageHasInspectorContent = has
        toolbar.items.first { $0.itemIdentifier == ItemID.inspector }?.visibilityPriority = inspectorPriorityNow
    }

    #if FM_SELFTESTS
    var debugInspectorItem: NSToolbarItem? { inspectorItem }
    var debugSidebarItem: NSToolbarItem? { sidebarItem }
    var debugInspectorSymbolName: String { inspectorSymbolName }
    #endif

    func applyThemeSymbol(_ theme: HelmTheme) {
        setSearchHint(theme)
        applyCrumb(theme)
        let isDark = theme.mode == .dark
        themeItem?.image = symbol(isDark ? DaylightThemeToggleButton.darkSymbol : DaylightThemeToggleButton.lightSymbol)
        themeItem?.toolTip = DaylightThemeToggleButton.tooltip(isDark: isDark)
        if wantsFocusChip { focusChip.applyTheme(theme) }
    }

    // MARK: Actions

    @objc private func sidebarClicked() { onToggleSidebar?() }
    @objc private func showLocationFromOverflow() { onShowLocation?() }
    @objc private func recentsClicked() { onRecents?(recentsButton) }
    @objc private func recentsFromOverflow() { onRecents?(navigation) }
    @objc private func themeClicked() { onToggleTheme?() }
    @objc private func notificationsClicked() { onNotifications?(bellButton) }
    @objc private func calendarClicked() { onCalendar?() }
    @objc private func inspectorClicked() { onToggleInspector?() }
    @objc private func searchClicked() { onSearch?() }
    @objc private func moduleActionClicked() { onModuleAction?() }
    @objc private func quickConnectConsoleClicked() { onQuickConnectConsole?() }
    @objc private func quickConnectHostsClicked() { onQuickConnectHosts?() }
    @objc private func focusChipClicked() { onFocusChip?(focusChip) }
    @objc private func focusChipFromOverflow() { onFocusChip?(navigation) }

    @objc private func navigationClicked(_ sender: NSSegmentedControl) {
        // A momentary control reports the segment being clicked; anything
        // else (no segment) is neither direction.
        switch sender.selectedSegment {
        case 0: onBack?()
        case 1: onForward?()
        default: break
        }
    }

    @objc private func tabClicked(_ sender: NSSegmentedControl) {
        // The index is what the shell matches, so a count in the label never
        // reaches it.
        guard sender.selectedSegment >= 0, sender.selectedSegment < sender.segmentCount else { return }
        onSelectTab?(sender.selectedSegment)
    }

    #if FM_SELFTESTS
    /// The item identifiers in toolbar order - what the suite asserts the
    /// trailing cluster against.
    var debugItemIdentifiers: [NSToolbarItem.Identifier] { toolbar.items.map(\.itemIdentifier) }
    var debugPageActions: [NSView] { pageActions.arrangedSubviews }
    var debugNavigation: NSSegmentedControl { navigation }
    var debugSidebarButton: NSButton { sidebarButton }
    var debugTabs: NSSegmentedControl { tabs }
    /// The tab labels, as the toolbar draws them.
    var debugTabNames: [String] { wantsTabs ? tabNames : [] }
    /// The tab labels as drawn, counts included.
    var debugTabLabels: [String] { wantsTabs ? (0..<tabs.segmentCount).compactMap { tabs.label(forSegment: $0) } : [] }
    var debugPrimaryAction: NSView? { shownPrimary }
    var debugCrumb: String { crumb.stringValue }
    var debugIsCompact: Bool { isCompact }
    var debugModuleActionButton: NSButton? { wantsModuleAction ? moduleActionButton : nil }
    var debugQuickConnectConsoleItem: NSToolbarItem? { quickConnectConsoleItem }
    var debugQuickConnectHostsItem: NSToolbarItem? { quickConnectHostsItem }
    var debugBellButton: NSButton { bellButton }
    var debugRecentsButton: NSButton { recentsButton }
    var debugSearchButton: NSButton { searchButton }
    var debugNotificationsItem: NSToolbarItem? { notificationsItem }
    var debugBadgeText: String? { bellBadge.isHidden ? nil : bellBadgeLabel.stringValue }
    var debugThemeItem: NSToolbarItem? { themeItem }
    var debugFocusChip: FocusTimerChip { focusChip }
    /// The chip is in the toolbar, not only asked for.
    var debugFocusChipIsShown: Bool { toolbar.items.contains { $0.itemIdentifier == ItemID.focusTimer } }
    /// Choose the chip's item from the overflow menu, the way a click on it
    /// does.
    func debugPerformFocusChipMenuForm() -> Bool {
        guard let menu = toolbar.items.first(where: { $0.itemIdentifier == ItemID.focusTimer })?.menuFormRepresentation,
              let action = menu.action, let target = menu.target as? NSObject else { return false }
        target.perform(action, with: menu)
        return true
    }
    /// Fire an image item's action the way a click does.
    func debugPerform(_ identifier: NSToolbarItem.Identifier) -> Bool {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == identifier }),
              let action = item.action, let target = item.target as? NSObject else { return false }
        target.perform(action, with: item)
        return true
    }
    #endif
}

// MARK: - R2-UX-06: the page actions' overflow menu

/// A toolbar control that knows its own menu form - a segmented switch, a
/// stepper - for when the page-actions item overflows. A plain button needs
/// nothing: it is listed by its title, or its accessibility label.
protocol WorkspaceToolbarMenuRepresentable: AnyObject {
    func workspaceToolbarMenuItems() -> [NSMenuItem]
}

extension WorkspaceToolbar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === pageActionsMenu else { return }
        menu.removeAllItems()
        for item in Self.menuItems(for: shownActions.filter { !$0.isHidden }) { menu.addItem(item) }
    }

    /// The overflow menu's rows for `views`, in toolbar order, separated per
    /// control that brings several. Each row runs the control's own action.
    static func menuItems(for views: [NSView]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for view in views {
            if let representable = view as? WorkspaceToolbarMenuRepresentable {
                if !items.isEmpty { items.append(.separator()) }
                items += representable.workspaceToolbarMenuItems()
                continue
            }
            if let popUp = view as? NSPopUpButton {
                let row = NSMenuItem(title: popUp.accessibilityLabel() ?? popUp.toolTip ?? "Choose", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for (index, choice) in popUp.itemArray.enumerated() where !choice.isSeparatorItem {
                    let entry = closureItem(choice.title) { [weak popUp] in
                        guard let popUp else { return }
                        popUp.selectItem(at: index)
                        popUp.sendAction(popUp.action, to: popUp.target)
                    }
                    entry.state = index == popUp.indexOfSelectedItem ? .on : .off
                    submenu.addItem(entry)
                }
                row.submenu = submenu
                items.append(row)
                continue
            }
            if let button = view as? NSButton, let overflow = button.target as? HelmOverflowMenu {
                // A page's "More" button: its own menu, as a submenu.
                let row = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
                row.submenu = overflow.makeMenu()
                items.append(row)
                continue
            }
            if let button = view as? NSButton {
                let title = [button.title, (button as? HelmButton)?.menuFormTitle ?? "", button.accessibilityLabel() ?? "",
                             button.toolTip ?? ""].first { !$0.isEmpty } ?? "Action"
                let entry = closureItem(title) { [weak button] in button?.performClick(nil) }
                entry.isEnabled = button.isEnabled
                items.append(entry)
            }
        }
        return items
    }

    static func closureItem(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = WorkspaceSidebarMenuItem(title: title, action: #selector(WorkspaceSidebarMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = action
        return item
    }

    #if FM_SELFTESTS
    /// The page actions' overflow menu, built as the overflow menu builds it.
    var debugPageActionsMenuTitles: [String] {
        Self.menuItems(for: shownActions.filter { !$0.isHidden }).filter { !$0.isSeparatorItem }.map(\.title)
    }
    #endif
}
