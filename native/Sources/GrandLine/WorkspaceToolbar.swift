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
//     Connections' Activity) - or, on Console, Quick Connect: the caption
//     and two separate icons beside it, one for a Console terminal and one
//     for a host (stage 7, the captain's call),
//   - while a focus timer runs, F7's chip (the floating bar shows it beside
//     its search pill), just before the trailing cluster - it was on the
//     layout's status strip until the captain had the strip removed,
//   - the trailing cluster: the light/dark toggle and the notifications
//     button (the captain kept both), the inspector toggle, then Search,
//   - and last, at the far right after Search, the page's one primary action
//     where it has one (Add Host, Analyze, Copy diagnostics), as the
//     prototype draws it (stage 6, `WorkspacePrimaryActionProviding`).
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
        static let crumb = NSToolbarItem.Identifier("workspace.crumb")
        static let tabs = NSToolbarItem.Identifier("workspace.tabs")
        static let pageActions = NSToolbarItem.Identifier("workspace.pageActions")
        static let moduleAction = NSToolbarItem.Identifier("workspace.moduleAction")
        static let theme = NSToolbarItem.Identifier("workspace.theme")
        static let notifications = NSToolbarItem.Identifier("workspace.notifications")
        static let inspector = NSToolbarItem.Identifier("workspace.inspector")
        static let search = NSToolbarItem.Identifier("workspace.search")
        static let primaryAction = NSToolbarItem.Identifier("workspace.primaryAction")
        static let focusTimer = NSToolbarItem.Identifier("workspace.focusTimer")
        /// Console's Quick Connect: the caption, then its two icons.
        static let quickConnectCaption = NSToolbarItem.Identifier("workspace.quickConnect.caption")
        static let quickConnectConsole = NSToolbarItem.Identifier("workspace.quickConnect.console")
        static let quickConnectHosts = NSToolbarItem.Identifier("workspace.quickConnect.hosts")
        static let quickConnect = [quickConnectCaption, quickConnectConsole, quickConnectHosts]
    }

    /// Quick Connect's two icons. Separate image items rather than one
    /// control with two segments, so each is its own button and the system
    /// groups them in one capsule the way it groups the light/dark toggle,
    /// the bell and the inspector toggle - two icons side by side, never one
    /// merged glyph (the captain's words: "lets not merge them").
    enum QuickConnectIcon {
        static let consoleSymbol = "terminal"
        static let hostsSymbol = "server.rack"
        static let caption = "Quick Connect"
        static let consoleLabel = "Console"
        static let hostsLabel = "Hosts"
        static let consoleHelp = "Go to your Console session, or open one if there is none"
        static let hostsHelp = "Connect to a saved host, or type ssh user@host"
    }

    let toolbar = NSToolbar(identifier: "workspace.toolbar")

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
    var onToggleInspector: (() -> Void)?
    var onSearch: (() -> Void)?
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
    /// Quick Connect's caption: plain text, like the crumb, so the system
    /// draws no capsule around it.
    private let quickConnectCaption = NSTextField(labelWithString: QuickConnectIcon.caption)
    private var wantsQuickConnect = false
    private var quickConnectConsoleItem: NSToolbarItem?
    private var quickConnectHostsItem: NSToolbarItem?
    private let bellButton = NSButton()
    /// The unread count on the bell's corner. Drawn here rather than with
    /// `NSToolbarItem.badge`, which is macOS 26 only and absent from the SDK
    /// CI builds against.
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
        toolbar.centeredItemIdentifier = ItemID.tabs
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

        crumb.lineBreakMode = .byTruncatingTail
        crumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crumb.setAccessibilityRole(.staticText)

        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabClicked(_:))

        moduleActionButton.imagePosition = .imageLeading
        moduleActionButton.target = self
        moduleActionButton.action = #selector(moduleActionClicked)

        quickConnectCaption.lineBreakMode = .byClipping
        quickConnectCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        quickConnectCaption.setAccessibilityRole(.staticText)
        applyQuickConnectCaption(ThemeManager.shared.theme)

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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Two flexible spaces, so the tabs - inserted between them - sit in
        // the middle rather than against the trailing cluster.
        [ItemID.sidebar, .sidebarTrackingSeparator, ItemID.navigation, ItemID.recents, ItemID.crumb, .flexibleSpace,
         .flexibleSpace, ItemID.theme, ItemID.notifications, ItemID.inspector, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ItemID.tabs, ItemID.pageActions, ItemID.moduleAction, ItemID.primaryAction,
                                                  ItemID.focusTimer, .space] + ItemID.quickConnect
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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
        // Quick Connect's caption says what its icons are for, so it goes
        // before them; the icons themselves are the module's action.
        switch identifier {
        case ItemID.crumb, ItemID.recents, ItemID.inspector, ItemID.quickConnectCaption: item?.visibilityPriority = .low
        case ItemID.moduleAction, ItemID.quickConnectConsole, ItemID.quickConnectHosts:
            item?.visibilityPriority = Self.moduleActionPriority
        case ItemID.focusTimer: item?.visibilityPriority = Self.focusChipPriority
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
            return viewItem(identifier, view: sidebarButton, label: "Sidebar")
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
            return viewItem(identifier, view: crumb, label: "Location")
        case ItemID.tabs:
            return viewItem(identifier, view: tabs, label: "Tabs")
        case ItemID.pageActions:
            return viewItem(identifier, view: pageActions, label: "Page actions")
        case ItemID.primaryAction:
            return viewItem(identifier, view: primaryActionHost, label: "Primary action")
        case ItemID.moduleAction:
            let item = viewItem(identifier, view: moduleActionButton, label: moduleActionButton.title)
            let menuForm = NSMenuItem(title: moduleActionButton.title, action: #selector(moduleActionClicked), keyEquivalent: "")
            menuForm.target = self
            item.menuFormRepresentation = menuForm
            return item
        case ItemID.quickConnectCaption:
            let item = viewItem(identifier, view: quickConnectCaption, label: QuickConnectIcon.caption)
            // In the overflow menu the caption is the old single action, so
            // choosing it does what clicking Quick Connect always did.
            let menuForm = NSMenuItem(title: QuickConnectIcon.caption, action: #selector(quickConnectHostsClicked),
                                      keyEquivalent: "")
            menuForm.target = self
            item.menuFormRepresentation = menuForm
            return item
        case ItemID.quickConnectConsole:
            let item = imageItem(identifier, symbol: QuickConnectIcon.consoleSymbol, label: QuickConnectIcon.consoleLabel,
                                 help: QuickConnectIcon.consoleHelp, action: #selector(quickConnectConsoleClicked))
            item.paletteLabel = "Quick Connect: Console"
            quickConnectConsoleItem = item
            return item
        case ItemID.quickConnectHosts:
            let item = imageItem(identifier, symbol: QuickConnectIcon.hostsSymbol, label: QuickConnectIcon.hostsLabel,
                                 help: QuickConnectIcon.hostsHelp, action: #selector(quickConnectHostsClicked))
            item.paletteLabel = "Quick Connect: Hosts"
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
        case ItemID.inspector:
            let item = imageItem(identifier, symbol: "sidebar.right", label: "Inspector",
                                 help: "Show or hide the inspector", action: #selector(inspectorClicked))
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

    /// Console's Quick Connect - the caption and its Console and Hosts icons -
    /// or none.
    func setQuickConnect(_ shown: Bool) {
        guard shown != wantsQuickConnect else { return }
        wantsQuickConnect = shown
        reconcileDynamicItems()
    }

    /// The caption in the toolbar's text style: the crumb's module ink, at
    /// the size the toolbar's other words use.
    private func applyQuickConnectCaption(_ theme: HelmTheme) {
        quickConnectCaption.font = .systemFont(ofSize: HelmType.scaled(13), weight: .medium)
        quickConnectCaption.textColor = HelmTheme.nsColor(theme.chromeInkHex)
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

    /// The page's primary action, after Search, or none. The view is the
    /// page's own, like `setPageActions`'.
    func setPrimaryAction(_ view: NSView?) {
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
        // Quick Connect's three go in together and in order, so the caption
        // always sits just before its two icons, and a space follows them.
        // Without it the system draws adjacent icons as one capsule, and the
        // two icons became the first two of five with the trailing cluster's
        // (measured in a real render) - the caption then read as the label
        // for all five.
        let shownQuickConnect = toolbar.items.filter { ItemID.quickConnect.contains($0.itemIdentifier) }
        if !wantsQuickConnect {
            removeQuickConnect()
        } else if shownQuickConnect.map(\.itemIdentifier) != ItemID.quickConnect || quickConnectSpaceIndex == nil {
            removeQuickConnect()
            for identifier in ItemID.quickConnect + [.space] {
                toolbar.insertItem(withItemIdentifier: identifier, at: beforeTheFocusChipAndTheCluster)
            }
        }
        let focusIndex = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.focusTimer }
        if !wantsFocusChip {
            if let focusIndex { toolbar.removeItem(at: focusIndex) }
        } else if focusIndex == nil {
            // Just before the trailing cluster, after the page's and the
            // module's actions.
            let at = toolbar.items.firstIndex { $0.itemIdentifier == ItemID.theme } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: ItemID.focusTimer, at: at)
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
        toolbar.items.firstIndex { $0.itemIdentifier == ItemID.focusTimer || $0.itemIdentifier == ItemID.theme }
            ?? toolbar.items.count
    }

    /// The space Quick Connect puts after its Hosts icon, when it is there.
    /// Found by position, so a space anywhere else is never taken for it.
    private var quickConnectSpaceIndex: Int? {
        guard let hosts = toolbar.items.firstIndex(where: { $0.itemIdentifier == ItemID.quickConnectHosts }),
              hosts + 1 < toolbar.items.count, toolbar.items[hosts + 1].itemIdentifier == .space else { return nil }
        return hosts + 1
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

    func setInspectorShown(_ shown: Bool) {
        inspectorItem?.toolTip = shown ? "Hide the inspector" : "Show the inspector"
    }

    func applyThemeSymbol(_ theme: HelmTheme) {
        setSearchHint(theme)
        applyCrumb(theme)
        applyQuickConnectCaption(theme)
        let isDark = theme.mode == .dark
        themeItem?.image = symbol(isDark ? DaylightThemeToggleButton.darkSymbol : DaylightThemeToggleButton.lightSymbol)
        themeItem?.toolTip = DaylightThemeToggleButton.tooltip(isDark: isDark)
        if wantsFocusChip { focusChip.applyTheme(theme) }
    }

    // MARK: Actions

    @objc private func sidebarClicked() { onToggleSidebar?() }
    @objc private func recentsClicked() { onRecents?(recentsButton) }
    @objc private func recentsFromOverflow() { onRecents?(navigation) }
    @objc private func themeClicked() { onToggleTheme?() }
    @objc private func notificationsClicked() { onNotifications?(bellButton) }
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
    /// Quick Connect's caption as drawn, or `nil` while it is not in the
    /// toolbar.
    var debugQuickConnectCaption: NSTextField? {
        toolbar.items.contains { $0.itemIdentifier == ItemID.quickConnectCaption } ? quickConnectCaption : nil
    }
    var debugQuickConnectConsoleItem: NSToolbarItem? { quickConnectConsoleItem }
    var debugQuickConnectHostsItem: NSToolbarItem? { quickConnectHostsItem }
    /// Choose the caption's overflow menu form, the way a click on it does.
    func debugPerformQuickConnectMenuForm() -> Bool {
        guard let menu = toolbar.items.first(where: { $0.itemIdentifier == ItemID.quickConnectCaption })?
                .menuFormRepresentation,
              let action = menu.action, let target = menu.target as? NSObject else { return false }
        target.perform(action, with: menu)
        return true
    }
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
