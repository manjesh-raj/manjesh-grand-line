// Manjesh Grand Line - native macOS app.
//
// The Hosts destination: saved SSH hosts, SSH keys and command snippets, as
// three scopes of one full-width page, switched by the page's own left nav
// column. (They were a `HelmSegmentedTabs` strip *and* that column until
// review #3's UI1 - see `HostsSidebar.swift`'s header.)
//
// **Why this file replaces three.** The full-app UI audit
// (`data/grandline-full-ui-audit/report.md`, §4.4/§4.5, §6.4 and §7's Phase 5)
// found Hosts, SSH Keys and Snippets were "three views of one concern in three
// different presentation modes": a rail destination that was still laid out as
// the 220-260pt Termius-style sidebar it had been before
// `fm/cockpit-native-ui-fixes2` promoted it to a full-size body destination,
// plus a 380x520 floating window and a 360x480 floating window. The two
// windows (`KeysSidebarController`, `SnippetsController`) were near-identical
// twins - same footer-button helper, same table setup, same title/caption
// treatment - and the Hosts page was the audit's single worst-rendering
// surface, with three ~370pt `.fillEqually` footer buttons and one 78pt row
// above ~800pt of empty space.
//
// The captain approved the structural change (registered decision
// `grandline-full-ui-audit-decision-hosts-keys-snippets-merge`): the two
// windows are gone, and their content is one scope of this destination. Everything they did still happens here - add/edit/delete a
// host, key or snippet; connect; quick-connect; key generation and import;
// snippet run; the pinned "Firstmate" entry's connect - only the presentation
// changed.
//
// **What it is built out of.** Nothing new: the page is Phase 1-4's shared
// components (`HelmDesignSystem.swift`) assembled - `HelmPageSidebar` for the
// nav column, one `HelmCard` per scope, `HelmAccentRow` cards for every list
// row, `HelmEmptyState` for every "nothing here yet", `HelmButton` for every
// action. The three per-list bodies are one `HostsListSection`, fed a
// `[HostsListSection.Item]` array, which is what actually deletes the
// duplication rather than moving it.
//
// **Where the actions went.** The footer strip is gone. A row's own actions
// (Connect / Edit / Run, plus an overflow menu carrying the rest) live in that
// row, in `HelmAccentRow`'s `trailingAccessory` slot; the "add" action lives
// in its card's header. So no action is ever a 370pt-wide button, and no
// action depends on the list having a selection first.
//
// This view stays decoupled from the terminal exactly as its three
// predecessors were: it takes the three stores plus `onConnect` /
// `onConnectPinned` / `onAddOrEdit` / `onRunSnippet` closures, and never
// touches `ConsoleController` or SwiftTerm.

import AppKit

/// Which of the destination's three scopes is showing. Raw values are the ids
/// `HelmPageSidebar` deals in (the component switches nothing itself - it hands
/// an id back and this controller's own switch does the work). The name is
/// kept: it is the vocabulary ~30 call sites across the menu bar, the search
/// palette and `AppShellController` already speak, and review #3's UI1 removed
/// a duplicate control, not the three scopes.
enum HostsTab: String, CaseIterable {
    case hosts, keys, snippets

    var title: String {
        switch self {
        case .hosts: return "Hosts"
        case .keys: return "SSH Keys"
        case .snippets: return "Snippets"
        }
    }
}

final class HostsController: NSViewController, DaylightDrillActions {

    private let hostStore: HostStore
    private let keyStore: SSHKeyStore
    private let snippetStore: SnippetStore

    // MARK: Callbacks (unchanged from the three controllers this replaces)

    /// Open an ssh session: (saved host id - `nil` for an ad-hoc quick
    /// connect with no saved identity, tab label, ssh argv, host accent hex,
    /// saved-key id, startup-snippet id). Wired by the app delegate to the
    /// same per-host dedicated-page connect the rail's pinned host icons use.
    var onConnect: ((UUID?, String, [String], String?, UUID?, UUID?) -> Void)?

    /// Connect the pinned "Firstmate" entry. Wired to
    /// `ConsoleController.openFirstmateHost`.
    var onConnectPinned: (() -> Void)?

    // MARK: Live sessions (`fm/grandline-session-switcher`)

    /// Is this host already connected, and since when? Answered by
    /// `AppShellController`'s `HostSessionRegistry` through a closure, so this
    /// page reads the app's one notion of liveness without learning what a
    /// `ConsoleController` is - the same forward-don't-own shape as
    /// `onConnect`/`onAddOrEdit` above. `nil` (the default) means "nothing
    /// wired liveness up", which renders exactly the pre-switcher rows.
    var liveSession: ((UUID) -> HostSession?)?
    /// Jump back into an existing session rather than opening a connection.
    var onSwitchToSession: ((UUID) -> Void)?
    /// End a live session (the shell owns the confirm).
    var onEndSession: ((UUID) -> Void)?

    /// Re-render the host rows so their live state is current. Called by the
    /// shell whenever the registry changes, and on this page's own
    /// `viewWillAppear`.
    ///
    /// Deliberately **not** on a timer: a row's "Connected · 14m" would then
    /// need the whole table reloaded every minute while this page is open,
    /// which resets scroll and selection for a string that is honest for a
    /// whole minute anyway. It is recomputed on every visit and on every real
    /// session change, which is when it can actually be wrong.
    func refreshLiveSessionState() {
        guard isViewLoaded else { return }
        applyHostFilter(searchField.stringValue)
    }

    /// Add (`nil`) or edit (a host) - the host editor is a dedicated window
    /// owned by the app delegate, not a sheet on this page.
    var onAddOrEdit: ((Host?) -> Void)?

    /// Run a snippet in the console's active/frontmost tab. Wired to
    /// `ConsoleController.runSnippetInActiveTab`.
    var onRunSnippet: ((Snippet) -> Void)?

    // MARK: Views


    private var activeTab: HostsTab = .hosts

    private let hostsTabView = NSView()
    private let keysTabView = NSView()
    private let snippetsTabView = NSView()

    /// Quick connect / live filter, in the app's own search well
    /// (Phase 0's raw-input purge). An `NSSearchField` paints its own system
    /// chrome and system fill, which is what the audit measured as the
    /// wallpaper-tinted field on this page (D2) - forcing its `appearance`
    /// only picks the light-or-dark side of that system colour.
    private let searchField = HelmSearchField(
        placeholder: "Find a host, or type ssh user@host to connect")
    private let tagsScroll = NSScrollView()
    private let tagsStack = NSStackView()
    private var tagButtons: [String: HelmButton] = [:]
    private var selectedTags: Set<String> = []

    private let hostsList = HostsListSection()
    private let keysList = HostsListSection()
    private let snippetsList = HostsListSection()

    /// The reference mockup's right-hand column: Workspace, Selected, Quick
    /// actions (`HostsSidePanels.swift`). One instance shared by all three
    /// scopes rather than one per scope - the Workspace counts are page-wide
    /// (and, since UI1, the page's one statement of them), and the detail
    /// panel simply re-fills from whichever list is showing.
    private let sideStack = HostsSideStack()

    /// The reference mockup's **left** navigation column.
    ///
    /// `fm/grand-line-hosts-page-redesign` scoped one out by name ("this
    /// page's nav is its three tabs, and a `HelmPageSidebar` duplicating them
    /// would be the same control twice, a row apart"); the captain used what
    /// that shipped, put it beside his own reference, and asked for the column
    /// back - the same correction Schedules already took in
    /// `fm/grand-line-schedules-sidebar-fullwidth-fix`. See
    /// `HostsSidebar.swift`'s header for the full note, including why review
    /// #3's UI1 then removed the tab strip this column used to sit beside.
    private let sidebar = HelmPageSidebar(surface: .panel)
    private let keychainCard = HostsKeychainCard()
    private let userRow = HostsUserRow()

    /// The sidebar's TOOLS rows. Both forwarded rather than reached for - this
    /// page has never known what an `AppShellController` is, and a nav row
    /// must not be the first thing to teach it (the same shape as
    /// `onOpenCommandPalette` above).
    ///
    /// **Both point at something real**, which is the rule a nav row lives or
    /// dies by here: `onOpenActivity` opens the app's own captain's log (the
    /// one activity feed it has, and the one that carries the host-scoped
    /// incident and investigation events), and `onOpenCommands` opens the
    /// DevOps Commands destination. The reference's other sidebar entries have
    /// nothing behind them and are absent rather than drawn inert, exactly as
    /// `CredentialVaultSidebar` and `SchedulesController` each decided for
    /// their own reference's extra rows.
    var onOpenActivity: (() -> Void)?
    var onOpenCommands: (() -> Void)?
    /// The user row's two menu items, routed by the shell into the *same*
    /// `show(.settings)` and the same single logout confirmation the floating
    /// bar's avatar uses - never a second copy of either.
    var onOpenSettings: (() -> Void)?
    var onLogout: (() -> Void)?

    /// The reference's `.filterbar`. "Online" is the one of its three chips
    /// this app can actually answer - the app's `HostSessionRegistry` knows
    /// which hosts have a live session (`liveSession`). Its "All environments"
    /// is what the tag chips beside it already are, and "Recently used" has
    /// nothing behind it: no store here records when a host was last
    /// connected to, and inventing a timestamp would be a new field masquerading
    /// as a filter.
    private lazy var onlineChip: HelmButton = {
        let b = HelmButton(title: "Online", variant: .secondary, size: .small,
                           symbol: "bolt.fill", target: self, action: #selector(onlineChipClicked(_:)))
        b.setButtonType(.pushOnPushOff)
        b.toolTip = "Show only hosts with a live session"
        return b
    }()
    private var onlineOnly = false

    /// Open the ⌘K command palette. Forwarded rather than reached for - this
    /// page has never known what an `AppDelegate` is, and the quick-actions
    /// panel must not be the first thing to teach it.
    var onOpenCommandPalette: (() -> Void)?

    /// The three "add" actions. Daylight §6.4 hoists a page's primary action
    /// into the shell's drill header, and this page has one per tab - so they
    /// are built here (rather than inline in each `build*Tab`) and handed over
    /// through `drillHeaderActions`, which re-reads whichever tab is showing.
    /// Caller-owned, exactly as `HelmDrillHeader.setActions` requires: this
    /// page keeps the tooltips and the target/action it already set.
    private lazy var addHostButton: HelmButton = {
        let b = HelmButton(title: "Add Host", variant: .primary, size: .small,
                           symbol: "plus", target: self, action: #selector(newHost))
        b.toolTip = "Add Host (⌘N)"
        return b
    }()
    private lazy var addKeyButton: HelmButton = {
        let b = HelmButton(title: "New Key", variant: .primary, size: .small,
                           symbol: "plus", target: self, action: #selector(newKey))
        b.toolTip = "New Key (⌘⇧N)"
        return b
    }()
    private lazy var addSnippetButton: HelmButton = {
        let b = HelmButton(title: "New Snippet", variant: .primary, size: .small,
                           symbol: "plus", target: self, action: #selector(newSnippet))
        b.toolTip = "New Snippet (⌘⌥N)"
        return b
    }()

    /// Set by `AppShellController` - "re-read my subtitle" / "re-read my
    /// actions". The drill header belongs to the shell; a page writing into it
    /// directly is how two owners of one view start disagreeing.
    var onDrillSubtitleChanged: (() -> Void)?
    var onDrillActionsChanged: (() -> Void)?

    private var hostsTitleLabel = NSTextField(labelWithString: HostsTab.hosts.title)
    private var keysTitleLabel = NSTextField(labelWithString: HostsTab.keys.title)
    private var snippetsTitleLabel = NSTextField(labelWithString: HostsTab.snippets.title)

    init(hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore) {
        self.hostStore = hostStore
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    /// `fm/grandline-session-switcher`: a session may have started or ended
    /// while this page was hidden (the shell skips rebuilding rows nobody can
    /// see), so the live state is re-derived on every visit. Cheap - a
    /// handful of rows and no I/O.
    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLiveSessionState()
    }

    override func loadView() {
        // A plain, layer-backed, theme-filled root - never an
        // `NSVisualEffectView`. AGENTS.md gotcha #8: `.behindWindow` blending
        // composites against what is behind the *window*, which is wrong for
        // a full-size destination.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1136, height: 660))
        root.wantsLayer = true
        view = root

        // Review #3's UI1: **there is no tab strip any more.**
        //
        // This page carried two controls that did the same thing, one row
        // apart: a `HelmSegmentedTabs` strip reading Hosts / SSH Keys /
        // Snippets over the content column, and a `HelmPageSidebar` WORKSPACE
        // section reading Hosts / SSH Keys / Snippets immediately to its left.
        // They were wired as one mechanism, so they could never *disagree* -
        // which was the risk `HostsSidebar.swift`'s header was written about -
        // but they were still the same three words twice on one screen.
        //
        // The sidebar is the one that stays, because it is strictly the richer
        // of the two: it carries each scope's glyph, it continues into a TOOLS
        // section and the keychain footer, and it is this page's navigation in
        // the same place every other sidebar-bearing destination puts it. That
        // reverses the "the tab strip stays, the captain's own target
        // screenshot shows both" note this file's sibling records - see this
        // task's PR for the captain instruction that supersedes it.
        //
        // Added before the constraint block below, which references its
        // anchors: activating a constraint between two views with no common
        // ancestor throws (`fm/grandline-docs-no-window-fix`'s own finding).
        root.addSubview(sideStack)
        root.addSubview(sidebar)
        buildSidebar()

        buildHostsTab()
        buildKeysTab()
        buildSnippetsTab()

        // The content column: gutter to gutter, exactly like every other
        // card-bearing destination in this app. An `NSLayoutGuide` rather
        // than a spacer view, so nothing renders it and nothing can
        // accidentally pick up a background from it.
        //
        // **There is no width cap any more.** Phase 5 built this column as
        // `leading >= / trailing <= / centerX ==`, floating the page in the
        // middle of a wide window with a mirrored dead gutter either side;
        // `fm/grandline-design-fidelity-fixes` dropped the `centerX` tie so
        // the page is left-aligned, but kept a 1120pt maximum, reasoning that
        // "a very wide window still doesn't stretch a host row's two short
        // strings across 1500pt". Live, that cap is what the captain reported
        // next (`04-hosts-page-right-gap.png`): on a laptop-width window the
        // cards stop about four fifths of the way across and the rest of the
        // page is empty. The reasoning was also already handled one level
        // down - a host row is a `HelmAccentRow` whose Connect / `...`
        // controls sit in its own right-anchored `trailingAccessory` slot, so
        // a wider card puts the extra width *between* the two short strings
        // and the actions rather than stretching either, which is precisely
        // how Updates', GitHub Sync's and Vault's rows already behave at any
        // width.
        //
        // `FleetController`, `ReviewController`, `UpdatesController`,
        // `GitHubSyncController` and `VaultController` all pin
        // `leading == +pageGutter` / `trailing == -pageGutter` with no cap.
        // Hosts was the only exception; it no longer is.
        let column = NSLayoutGuide()
        root.addLayoutGuide(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.pageGutter),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s5),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.pageGutter),

            // The nav column sits at the page's leading edge; everything else
            // starts after it. A `HelmPageSidebar` is deliberately **outside**
            // any scroll view the page has, for the reason `SchedulesController`
            // records: it is navigation, so it has to stay reachable.
            sidebar.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: column.topAnchor),
            // A **required** `==`, not the `<=` Poneglyph and Schedules use:
            // this column carries a bottom-anchored footer (the keychain card
            // and the user row), and that footer only reaches the page's
            // bottom if the column does - see `HelmPageSidebar.setFooter`.
            sidebar.bottomAnchor.constraint(equalTo: column.bottomAnchor),

        ])

        // The page is two columns: the tab's own content, and the permanent
        // right-hand panel stack - the reference mockup's own `.grid`
        // (`1.55fr .8fr`), which is what fills the dead middle of every row.
        //
        // The stack is a sibling of the three tab views rather than a child of
        // each, so it survives a tab switch (its Workspace counts are page-wide
        // and its detail panel simply re-fills from whichever list is showing),
        // and so there is one instance rather than three.
        //
        // **Window-floor discipline** (gotchas (13)/(14)): the flexible column
        // is the content, and the only two constraints that could resist a
        // narrowing window - the stack's own width and the content's minimum -
        // both sit at `HelmDaylightPriority.contentTie` (499), below
        // `NSLayoutPriorityWindowSizeStayPut`. `AppShellBodyWidthSelfTest`
        // sweeps every destination for exactly that.
        let contentMinimum = hostsTabView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.contentMinimumWidth)
        contentMinimum.priority = HelmDaylightPriority.contentTie

        for tabView in [hostsTabView, keysTabView, snippetsTabView] {
            tabView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(tabView)
            NSLayoutConstraint.activate([
                tabView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                                 constant: HelmMetrics.s4),
                tabView.trailingAnchor.constraint(equalTo: sideStack.leadingAnchor,
                                                  constant: -HelmMetrics.s4),
                // UI1: the content column starts at the top of the page now
                // that the duplicate tab strip above it is gone.
                tabView.topAnchor.constraint(equalTo: column.topAnchor),
                tabView.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            sideStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            sideStack.topAnchor.constraint(equalTo: hostsTabView.topAnchor),
            sideStack.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor),
            contentMinimum,
        ])

        buildSidePanels()

        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }

        hostStore.observe { [weak self] in self?.reloadHosts() }
        keyStore.onChange = { [weak self] in self?.reloadKeys() }
        snippetStore.onChange = { [weak self] in self?.reloadSnippets() }

        select(tab: .hosts, moveTabControl: true)
        reloadHosts()
        reloadKeys()
        reloadSnippets()
        // The `ThemeManager.observe` closure above fires synchronously at
        // registration - before the lists had any rows - so re-apply once the
        // page is fully built (`ThemeManager.swift`'s checklist item 4, the
        // trap this codebase has now hit four times).
        applyTheme(ThemeManager.shared.theme)
    }

    /// The narrowest the tab's own content column is allowed to get before the
    /// window itself has to give. Held *below* `NSLayoutPriorityWindowSizeStayPut`
    /// at the one place it is applied, so it can never become a window floor.
    static let contentMinimumWidth: CGFloat = 360

    // MARK: The sidebar

    /// Row ids. The three WORKSPACE rows reuse `HostsTab`'s own raw values, so
    /// the sidebar and the tab strip are keyed by one vocabulary and a switch
    /// from either control resolves to the same `HostsTab` - that shared key is
    /// what makes them one mechanism rather than two controls that have to be
    /// remembered to agree.
    private static let activityRowID = "tools.activity"
    private static let commandsRowID = "tools.commands"

    private func buildSidebar() {
        sidebar.appendHeader("Workspace")
        for tab in HostsTab.allCases {
            // UI1: `showsCount: false`. These rows used to carry a count badge
            // each, which - with the Workspace panel's inventory tiles two
            // columns over, the card header's own "Hosts (3)" and the drill
            // subtitle - made three the fourth statement of one number on one
            // screen. The count is stated once, by the panel whose subtitle is
            // literally "At-a-glance inventory"; these rows are navigation.
            sidebar.appendRow(id: tab.rawValue, symbol: Self.sidebarSymbol(for: tab),
                              title: tab.title, showsCount: false)
        }
        sidebar.appendSpacer()
        sidebar.appendHeader("Tools")
        // **Actions, not filters**: neither narrows the list below, so neither
        // may latch selected - a row that stayed lit would claim the list had
        // been filtered to something (`HelmPageSidebar.RowKind`).
        sidebar.appendRow(id: Self.activityRowID, symbol: "clock.arrow.circlepath",
                          title: "Activity", kind: .action, showsCount: false)
        sidebar.appendRow(id: Self.commandsRowID, symbol: "list.bullet.rectangle",
                          title: "Commands", kind: .action, showsCount: false)
        sidebar.select(activeTab.rawValue)

        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            switch id {
            case Self.activityRowID: self.onOpenActivity?()
            case Self.commandsRowID: self.onOpenCommands?()
            default:
                guard let tab = HostsTab(rawValue: id) else { return }
                self.select(tab: tab)
            }
        }

        userRow.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        userRow.onLogout = { [weak self] in self?.onLogout?() }

        let footer = NSStackView(views: [keychainCard, userRow])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = HelmMetrics.s2
        footer.translatesAutoresizingMaskIntoConstraints = false
        for row in [keychainCard, userRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        sidebar.setFooter(footer)
    }

    /// Each row takes the glyph its own card header already uses, so one
    /// concept is not drawn two ways a column apart.
    private static func sidebarSymbol(for tab: HostsTab) -> String {
        switch tab {
        case .hosts: return "server.rack"
        case .keys: return "key.fill"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The keychain card, from the same stores the lists render and the same
    /// biometry probe the Workspace panel reads - so the two columns either
    /// side of the page can never disagree within a frame.
    ///
    /// UI1: no `setCounts` any more. See `buildSidebar`.
    private func refreshSidebar() {
        let hosts = hostStore.hosts
        keychainCard.setState(keys: keyStore.keys.count,
                              hostsOnManagedKeys: hosts.filter { $0.keyID != nil }.count,
                              hosts: hosts.count,
                              touchIDAvailable: CredentialVaultKeyStore.biometryAvailable)
    }

    // MARK: Side panels

    private func buildSidePanels() {
        // Each list reports its own selection; the detail panel re-fills from
        // whichever tab is showing, so a stale selection on a hidden tab can
        // never be what the panel displays.
        hostsList.onSelectRecord = { [weak self] _ in self?.refreshDetailPanel() }
        keysList.onSelectRecord = { [weak self] _ in self?.refreshDetailPanel() }
        snippetsList.onSelectRecord = { [weak self] _ in self?.refreshDetailPanel() }

        // Every one of these is a real, bound menu item in `main.swift` -
        // the brief's own rule, and why the reference's `⌘ ↵ Connect selected`
        // and `⌘ ⇧ P Run snippet` are absent rather than drawn inert.
        sideStack.quickActions.setItems([
            .init(shortcut: "\u{2318}K", title: "Command palette") { [weak self] in
                self?.onOpenCommandPalette?()
            },
            .init(shortcut: "\u{2318}\u{2303}N", title: "Add host") { [weak self] in self?.newHost() },
            .init(shortcut: "\u{2318}\u{21E7}N", title: "New key") { [weak self] in self?.newKey() },
            .init(shortcut: "\u{2318}\u{2325}N", title: "New snippet") { [weak self] in self?.newSnippet() },
        ])
    }

    /// The Workspace card's four numbers, read from the same three stores the
    /// lists beside it render and from the app's one session registry - so the
    /// panel and the list can never disagree within a frame.
    private func refreshWorkspacePanel() {
        let live = hostStore.hosts.reduce(0) { $0 + (liveSession?($1.id) != nil ? 1 : 0) }
        sideStack.workspace.setCounts(hosts: hostStore.hosts.count,
                                      keys: keyStore.keys.count,
                                      snippets: snippetStore.snippets.count,
                                      live: live,
                                      touchIDAvailable: CredentialVaultKeyStore.biometryAvailable)
    }

    /// Fill (or empty) the detail panel from the showing tab's own selection.
    private func refreshDetailPanel() {
        guard let detail = currentDetail() else {
            sideStack.detail.clear()
            return
        }
        sideStack.detail.show(detail)
    }

    private func currentDetail() -> HostsDetailContent? {
        switch activeTab {
        case .hosts:
            guard let key = hostsList.selectedRecordKey,
                  let id = UUID(uuidString: key),
                  let host = hostStore.host(id: id) else { return nil }
            return detail(for: host)
        case .keys:
            guard let key = keysList.selectedRecordKey,
                  let id = UUID(uuidString: key),
                  let sshKey = keyStore.key(id: id) else { return nil }
            return detail(for: sshKey)
        case .snippets:
            guard let key = snippetsList.selectedRecordKey,
                  let id = UUID(uuidString: key),
                  let snippet = snippetStore.snippet(id: id) else { return nil }
            return detail(for: snippet)
        }
    }

    /// The reference's Environment / Endpoint / User / Credential list, read
    /// straight off the saved `Host` - nothing here is derived or invented.
    private func detail(for host: Host) -> HostsDetailContent {
        var fields: [HostsDetailContent.Field] = [
            .init("Environment", Self.roleKicker(for: host)),
            .init("Endpoint", host.port == 22 ? host.address : "\(host.address):\(host.port)", isCode: true),
            .init("User", host.username.isEmpty ? "\u{2014}" : host.username),
            .init("Credential", credentialName(for: host)),
        ]
        if let jump = host.jumpVia?.trimmingCharacters(in: .whitespacesAndNewlines), !jump.isEmpty {
            fields.append(.init("Jump via", jump))
        }
        if !host.portForwards.isEmpty {
            fields.append(.init("Forwards", "\(host.portForwards.count)"))
        }
        let session = liveSession?(host.id)
        if let session { fields.append(.init("Session", session.stateText)) }

        var actions: [HostsListSection.Action] = []
        if session != nil {
            actions.append(.init(title: "Switch", symbol: "arrow.right.circle.fill") { [weak self] in
                self?.onSwitchToSession?(host.id)
            })
        } else {
            actions.append(.init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) })
        }
        actions.append(.init(title: "Edit\u{2026}", symbol: "pencil") { [weak self] in self?.onAddOrEdit?(host) })

        return HostsDetailContent(symbol: host.iconSymbol,
                                  tint: .accent,
                                  tintHex: host.accentHex,
                                  kicker: Self.roleKicker(for: host),
                                  title: host.label,
                                  subtitle: host.subtitle,
                                  fields: fields,
                                  actions: actions)
    }

    /// The saved key's own label, never a path or key material - the same
    /// thing `Host.keyID` stores and the host editor shows.
    private func credentialName(for host: Host) -> String {
        guard let keyID = host.keyID else { return "ssh agent" }
        return keyStore.key(id: keyID)?.label ?? "Missing key"
    }

    private func detail(for key: SSHKey) -> HostsDetailContent {
        let usedBy = hostStore.hosts.filter { $0.keyID == key.id }.count
        var fields: [HostsDetailContent.Field] = [
            .init("Type", key.type.displayName),
            .init("Fingerprint", key.fingerprint, isCode: true),
            .init("Passphrase", key.hasPassphrase ? "In Keychain" : "None"),
            .init("Used by", usedBy == 1 ? "1 host" : "\(usedBy) hosts"),
        ]
        if key.certificate?.isEmpty == false { fields.append(.init("Certificate", "Present")) }
        return HostsDetailContent(symbol: "key.fill",
                                  tint: key.type.tint,
                                  kicker: key.type.displayName,
                                  title: key.label,
                                  subtitle: "Private key material stays in the macOS Keychain.",
                                  fields: fields,
                                  actions: [
                                    .init(title: "Edit", symbol: "pencil") { [weak self] in
                                        self?.presentKeyEditor(for: key)
                                    },
                                    .init(title: "Copy key", symbol: "doc.on.doc") {
                                        copyToPasteboard(key.publicKey)
                                    },
                                  ])
    }

    private func detail(for snippet: Snippet) -> HostsDetailContent {
        let lines = snippet.command.split(separator: "\n", omittingEmptySubsequences: false).count
        return HostsDetailContent(symbol: "chevron.left.forwardslash.chevron.right",
                                  tint: .info,
                                  kicker: "Snippet",
                                  title: snippet.label,
                                  subtitle: "Sent to the active terminal tab, then Enter.",
                                  fields: [
                                    .init("Command", snippet.subtitle, isCode: true),
                                    .init("Lines", "\(lines)"),
                                  ],
                                  actions: [
                                    .init(title: "Run", symbol: "play.fill") { [weak self] in
                                        self?.onRunSnippet?(snippet)
                                    },
                                    .init(title: "Edit\u{2026}", symbol: "pencil") { [weak self] in
                                        self?.presentSnippetEditor(for: snippet)
                                    },
                                  ])
    }

    private func buildHostsTab() {
        // Typing filters the list live; Return connects. Both arrive through
        // `HelmSearchField`'s own closures, which is also why this page no
        // longer needs to be an `NSSearchFieldDelegate`.
        searchField.onTextChanged = { [weak self] query in self?.applyHostFilter(query) }
        searchField.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            self?.quickConnectFromField()
            return true
        }

        tagsStack.orientation = .horizontal
        tagsStack.spacing = HelmMetrics.s1
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        tagsScroll.documentView = tagsStack
        tagsScroll.hasHorizontalScroller = false
        tagsScroll.hasVerticalScroller = false
        tagsScroll.drawsBackground = false
        tagsScroll.translatesAutoresizingMaskIntoConstraints = false
        // No trailing constraint - the stack sizes to its content and the clip
        // view scrolls horizontally once that content overflows.
        NSLayoutConstraint.activate([
            tagsStack.leadingAnchor.constraint(equalTo: tagsScroll.contentView.leadingAnchor),
            tagsStack.topAnchor.constraint(equalTo: tagsScroll.contentView.topAnchor),
            tagsStack.bottomAnchor.constraint(equalTo: tagsScroll.contentView.bottomAnchor),
            tagsScroll.heightAnchor.constraint(equalToConstant: 24),
        ])

        // The reference's `.filterbar`, beside the tag chips it already had:
        // one real toggle ("Online"), and no invented ones - see `onlineChip`.
        //
        // `filterSpacer` is a flexible trailing member that is ALWAYS in
        // layout, and it is load-bearing rather than tidiness.
        //
        // Without it the row's only flexible member is `tagsScroll` - which
        // `rebuildTagChips` hides whenever no host carries a tag. That is the
        // common case, and it is the captain's own data: his hosts record an
        // environment in `group`, not in `tags`. An `NSStackView` drops a
        // hidden arranged subview out of layout entirely (gotcha (11)'s own
        // stack exemption), so the row becomes just `onlineChip` - whose
        // horizontal hugging is `.required` two lines below. `filterRow`'s
        // width is tied to `top`'s, and `top` is pinned to both edges of
        // `hostsTabView`, all at required priority, so that one chip's
        // intrinsic width became a *required* ceiling on the entire content
        // column. Measured on a real shell at the captain's own 1467pt
        // window: the content column collapsed to 74pt - the chip - while the
        // side stack took the remaining 1329pt. That is exactly his report:
        // no host list at all, and the rail stretched across the page.
        //
        // The collapse constraint is a real low-priority `width == 0`, never a
        // hugging priority: a bare `NSView` has no intrinsic content size, so
        // `setContentHuggingPriority` on one is a documented no-op (gotcha
        // (12), and `fm/grandline-visual-polish-round2` paid for that lesson
        // once already). Being optional, it yields when the spacer is the only
        // thing left to stretch, and holds the spacer collapsed the rest of
        // the time so the tag strip keeps the slack it had before.
        let filterSpacer = NSView()
        filterSpacer.translatesAutoresizingMaskIntoConstraints = false
        let spacerCollapsed = filterSpacer.widthAnchor.constraint(equalToConstant: 0)
        spacerCollapsed.priority = .defaultLow
        spacerCollapsed.isActive = true

        let filterRow = NSStackView(views: [onlineChip, tagsScroll, filterSpacer])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (10): at the default `.gravityAreas` no hugging
        // priority is honoured at all, so the scroll would not take the slack
        // the chip leaves.
        filterRow.distribution = .fill
        onlineChip.setContentHuggingPriority(.required, for: .horizontal)
        onlineChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterRow.translatesAutoresizingMaskIntoConstraints = false

        // A vertical `NSStackView`, not manual constraints, specifically so
        // hiding the tag row (no tags on any host - the common case) removes
        // it from layout instead of leaving a 24pt gap.
        let top = NSStackView(views: [searchField, filterRow])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = HelmMetrics.s2
        top.translatesAutoresizingMaskIntoConstraints = false

        // No `actions:` - §6.4 puts this page's primary action in the drill
        // header, and a copy in the card header too would be the same button
        // twice, a row apart.
        hostsList.card.setHeader(symbol: "server.rack",
                                 titleLabel: hostsTitleLabel,
                                 subtitleLabel: NSTextField(wrappingLabelWithString:
                                    "Saved SSH connections. Connect opens the host's own page."))

        hostsTabView.addSubview(top)
        hostsTabView.addSubview(hostsList.card)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: hostsTabView.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: hostsTabView.trailingAnchor),
            top.topAnchor.constraint(equalTo: hostsTabView.topAnchor),
            searchField.widthAnchor.constraint(equalTo: top.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: top.widthAnchor),

            hostsList.card.leadingAnchor.constraint(equalTo: hostsTabView.leadingAnchor),
            hostsList.card.trailingAnchor.constraint(equalTo: hostsTabView.trailingAnchor),
            hostsList.card.topAnchor.constraint(equalTo: top.bottomAnchor, constant: HelmMetrics.s3),
            hostsList.card.bottomAnchor.constraint(equalTo: hostsTabView.bottomAnchor),
        ])
    }

    private func buildKeysTab() {
        keysList.card.setHeader(symbol: "key.fill", tint: .violet,
                                titleLabel: keysTitleLabel,
                                subtitleLabel: NSTextField(wrappingLabelWithString:
                                    "Private key material and passphrases are stored in the macOS Keychain, gated by Touch ID."))
        fill(keysTabView, with: keysList.card)
    }

    private func buildSnippetsTab() {
        snippetsList.card.setHeader(symbol: "chevron.left.forwardslash.chevron.right", tint: .info,
                                    titleLabel: snippetsTitleLabel,
                                    subtitleLabel: NSTextField(wrappingLabelWithString:
                                        "Run sends a snippet's command, then Enter, to the active terminal tab."))
        fill(snippetsTabView, with: snippetsList.card)
    }

    private func fill(_ container: NSView, with child: NSView) {
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Tabs

    /// Switch scopes.
    ///
    /// `moveTabControl` is kept as a parameter and deliberately ignored: UI1
    /// removed the tab strip it used to move, and several callers (the menu
    /// bar, the search palette, `AppShellController`) pass it explicitly.
    /// `HelmPageSidebar.select(_:)` moves the row without firing `onSelect`,
    /// so a switch from anywhere lands here exactly once.
    func select(tab: HostsTab, moveTabControl: Bool = true) {
        _ = moveTabControl
        activeTab = tab
        sidebar.select(tab.rawValue)
        hostsTabView.isHidden = tab != .hosts
        keysTabView.isHidden = tab != .keys
        snippetsTabView.isHidden = tab != .snippets
        // The panel follows the showing tab, so a selection left behind on a
        // hidden list is never what it displays.
        if isViewLoaded { refreshDetailPanel() }
        // §6.4: both halves of the header describe the tab that is showing.
        onDrillActionsChanged?()
        onDrillSubtitleChanged?()
    }

    // MARK: Drill header (Daylight §6.4)

    /// The showing tab's own add action. Re-read (not rebuilt) on every tab
    /// switch through `onDrillActionsChanged`, so the same three button
    /// instances - with the tooltips and targets this page set on them - move
    /// in and out of the header.
    var drillHeaderActions: [NSView] {
        switch activeTab {
        case .hosts: return [addHostButton]
        case .keys: return [addKeyButton]
        case .snippets: return [addSnippetButton]
        }
    }

    /// §6.4's live subtitle - what the showing scope *is*, not how much of it
    /// there is.
    ///
    /// **Review #3's UI1.** This used to read "3 saved hosts \u{00B7} 0 keys",
    /// which made the number 3 the fourth statement of the same fact on one
    /// screen: this line, the sidebar's own badge, the card header "Hosts (3)"
    /// and the Workspace panel's "3 Hosts" tile. The finding's own remedy is
    /// one authoritative statement per concern, and the Workspace panel is
    /// where it lives - its whole subtitle is "At-a-glance inventory", it is
    /// visible at the same time as all three of the others, and it is the only
    /// one of the four that also reports live sessions.
    ///
    /// The empty case is kept and is not a count: "no saved hosts yet" is a
    /// *state* the captain acts on, and it is the one thing this line can say
    /// that the inventory tile's `0` does not.
    var drillHeaderSubtitle: String? {
        switch activeTab {
        case .hosts:
            return hostStore.hosts.isEmpty
                ? "No saved hosts yet"
                : "Saved SSH connections"
        case .keys:
            return keyStore.keys.isEmpty
                ? "No saved keys yet"
                : "Private key material, in the macOS Keychain"
        case .snippets:
            return snippetStore.snippets.isEmpty
                ? "No snippets yet"
                : "Commands you run often"
        }
    }

    var currentTab: HostsTab { activeTab }

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // A forced appearance is still right for the one stock control left on
        // this page (the quick-connect `NSSearchField`, which Phase 6's
        // `HelmField` owns) - see `ThemeManager.swift`'s checklist rule 2.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        hostsList.applyTheme(theme)
        keysList.applyTheme(theme)
        snippetsList.applyTheme(theme)
        sideStack.applyTheme(theme)
        sidebar.applyTheme(theme)
        keychainCard.applyTheme(theme)
        userRow.applyTheme(theme)
    }

    // MARK: Hosts data

    private func reloadHosts() {
        refreshSidebar()
        rebuildTagChips()
        applyHostFilter(searchField.stringValue)
    }

    /// One toggle button per distinct tag across all hosts, sorted for a
    /// stable layout. Rebuilt on every reload (a handful of hosts, a handful
    /// of tags) so it stays in sync with host edits with no change tracking.
    private func rebuildTagChips() {
        for v in tagsStack.arrangedSubviews {
            tagsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        tagButtons.removeAll()
        let allTags = Set(hostStore.hosts.flatMap(\.tags)).sorted()
        selectedTags.formIntersection(allTags)
        for tag in allTags {
            // `.pushOnPushOff` still tracks `state` (which `tagChipClicked`
            // reads), but nothing draws that state now the stock bezel is
            // gone - the `.primary` variant is what shows it.
            let b = HelmButton(title: tag, variant: .secondary, size: .small,
                               target: self, action: #selector(tagChipClicked(_:)))
            b.setButtonType(.pushOnPushOff)
            b.state = selectedTags.contains(tag) ? .on : .off
            b.variant = b.state == .on ? .primary : .secondary
            b.identifier = NSUserInterfaceItemIdentifier(tag)
            tagButtons[tag] = b
            tagsStack.addArrangedSubview(b)
        }
        // Only the tag strip collapses when there are no tags - the "Online"
        // chip beside it is always meaningful.
        tagsScroll.isHidden = allTags.isEmpty
    }

    @objc private func onlineChipClicked(_ sender: NSButton) {
        onlineOnly = sender.state == .on
        (sender as? HelmButton)?.variant = onlineOnly ? .primary : .secondary
        applyHostFilter(searchField.stringValue)
    }

    @objc private func tagChipClicked(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        if sender.state == .on { selectedTags.insert(tag) } else { selectedTags.remove(tag) }
        (sender as? HelmButton)?.variant = sender.state == .on ? .primary : .secondary
        applyHostFilter(searchField.stringValue)
    }

    /// Text filter (label/address/username/tags) + the tag-chip filter,
    /// grouped into header/host rows, with the pinned "Firstmate" entry always
    /// first and unaffected by either filter - it is a permanent fixture, not
    /// a saved host. Group headers are skipped entirely when every visible
    /// host shares one group (the "I haven't set up groups yet" case), so a
    /// flat host list never gains visual noise.
    private func applyHostFilter(_ query: String) {
        let hosts = filteredHosts(query)
        var items: [HostsListSection.Item] = [pinnedItem()]

        let groupKeys = Set(hosts.map { normalizedGroup($0) })
        if groupKeys.count <= 1 {
            items += hosts.map { hostItem($0) }
        } else {
            for name in groupKeys.compactMap({ $0 }).sorted() {
                items.append(.group(name))
                items += hosts.filter { normalizedGroup($0) == name }.map { hostItem($0) }
            }
            let ungrouped = hosts.filter { normalizedGroup($0) == nil }
            if !ungrouped.isEmpty {
                items.append(.group("Ungrouped"))
                items += ungrouped.map { hostItem($0) }
            }
        }

        if hosts.isEmpty {
            let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedTags.isEmpty || onlineOnly
            items.append(.empty(
                symbol: filtering ? "line.3.horizontal.decrease.circle" : "server.rack",
                title: filtering ? "No matching hosts" : "No saved hosts yet",
                body: filtering
                    ? "Nothing matches the current search or filters. Clear them to see every saved host."
                    : "Add a host to save its connection details, or type ssh user@host in the field above to connect right now."))
        }

        // Review #3's UI1: the count came off this header. It is stated once
        // on the page, by the Workspace panel - see `refreshWorkspacePanel`.
        hostsTitleLabel.stringValue = HostsTab.hosts.title
        #if FM_SELFTESTS
        lastHostItems = items
        #endif
        hostsList.setItems(items)
        refreshWorkspacePanel()
        refreshDetailPanel()
        onDrillSubtitleChanged?()
    }

    private func filteredHosts(_ query: String) -> [Host] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hosts = hostStore.hosts
        if !q.isEmpty {
            hosts = hosts.filter { host in
                host.label.lowercased().contains(q)
                    || host.address.lowercased().contains(q)
                    || host.username.lowercased().contains(q)
                    || host.tags.contains { $0.lowercased().contains(q) }
            }
        }
        if !selectedTags.isEmpty {
            hosts = hosts.filter { !$0.tags.isEmpty && !selectedTags.isDisjoint(with: $0.tags) }
        }
        if onlineOnly {
            hosts = hosts.filter { liveSession?($0.id) != nil }
        }
        return hosts
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// The last set of rows this page rendered - recorded only in a debug
    /// build, so the shipped binary carries neither the array nor the write.
    private var lastHostItems: [HostsListSection.Item] = []

    /// The real `Item` this page built for a host, so a suite can assert what
    /// a row *says and does* rather than re-deriving it. Reads the last
    /// rendered set, so a caller must have driven a real
    /// `refreshLiveSessionState()`/filter pass first.
    func debugHostRowItem(labelled label: String) -> HostsListSection.Item? {
        lastHostItems.first { $0.isRecord && $0.content.title == label }
    }

    /// The nav column and its footer, so a suite can assert what they are
    /// really showing rather than re-deriving it from the stores.
    var debugSidebar: HelmPageSidebar { sidebar }
    var debugKeychainCard: HostsKeychainCard { keychainCard }
    var debugUserRow: HostsUserRow { userRow }
    #endif

    private func normalizedGroup(_ host: Host) -> String? {
        let g = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return g.isEmpty ? nil : g
    }

    /// The permanent, non-deletable first row. It has no `Host` behind it, so
    /// it can only be connected to - no edit, duplicate or delete. Its glyph
    /// is `sailboat`, the mark this app already uses for itself (and not
    /// `anchor`, which is not an SF Symbol on macOS at all and so rendered as
    /// nothing for as long as this row existed - fixed in Phase 0).
    private func pinnedItem() -> HostsListSection.Item {
        var item = HostsListSection.Item(content: .init(tint: .accent,
                                                        kicker: "Built-in",
                                                        title: "Firstmate",
                                                        meta: "Shell",
                                                        badgeSymbol: "sailboat"))
        item.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.onConnectPinned?() }
        item.activate = { [weak self] in self?.onConnectPinned?() }
        return item
    }

    private func hostItem(_ host: Host) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: .accent,
                                            kicker: Self.roleKicker(for: host),
                                            title: host.label,
                                            meta: host.subtitle,
                                            badgeSymbol: host.iconSymbol)
        // A host's accent is picked per host in the host editor, so it is a
        // literal hue rather than a semantic `HelmTint` - see
        // `HelmAccentRow.Content.tintHex`. Together with the role kicker
        // above, that is the prototype's "PREPROD / PROD / CI" row: the bar
        // and badge carry the captain's own colour for that host, the kicker
        // names the role.
        content.tintHex = host.accentHex
        // The first tag is the kicker now, so the chip only carries what the
        // kicker could not - "+2 more". A chip repeating the kicker was the
        // same signal twice.
        if host.tags.count > 1 {
            content.chipText = "+\(host.tags.count - 1) more"
        }
        // `fm/grandline-session-switcher`, item 1: a host that already has a
        // live session reads as connected and its headline action resumes that
        // session rather than looking identical to a fresh connect. The chip
        // carries it (`chipTint: .good`) rather than a new component or a
        // hand-coloured meta line - `ToolRowLayout.pill` behind it is the app's
        // one contrast-corrected chip, so this is legible in all 14 palettes
        // without this page picking a green of its own.
        let session = liveSession?(host.id)
        if let session {
            // Audit 2 §4.6: `stateText` rather than an unconditional
            // "Connected", so an F2-restored page the captain has not opened
            // yet says so instead of claiming a connection it does not have.
            content.chipText = session.stateText
            content.chipTint = .good
        }
        var item = HostsListSection.Item(content: content)
        item.recordKey = host.id.uuidString
        if session != nil {
            item.primary = .init(title: "Switch to session", symbol: "arrow.right.circle.fill") { [weak self] in
                self?.onSwitchToSession?(host.id)
            }
            item.activate = { [weak self] in self?.onSwitchToSession?(host.id) }
        } else {
            item.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) }
            item.activate = { [weak self] in self?.connect(host) }
        }
        var overflow: [HostsListSection.Action] = []
        if session != nil {
            // The one place a captain can end the session they are *currently
            // looking at* - the strip's own ✕ deliberately never appears on the
            // active pill, so a mis-click cannot close it (mockup callout c).
            overflow.append(.init(title: "End Session") { [weak self] in self?.onEndSession?(host.id) })
        }
        overflow += [
            .init(title: "Edit…") { [weak self] in self?.onAddOrEdit?(host) },
            .init(title: "Duplicate…") { [weak self] in self?.duplicate(host) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteHost(host) },
        ]
        item.overflow = overflow
        return item
    }

    /// A host row's kicker: what kind of box this is, in the captain's own
    /// words. The prototype's Hosts page reads LOCAL / PREPROD / PROD / CI
    /// down the left of the list rather than "SSH" four times, and this app
    /// already stores exactly that - a host's first tag, or its group when it
    /// has no tags. Falls back to "SSH" for a host with neither, which is
    /// what every row said before.
    ///
    /// `HelmAccentRow` uppercases and kerns the kicker itself, so this returns
    /// the captain's own casing untouched.
    static func roleKicker(for host: Host) -> String {
        if let tag = host.tags.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return tag
        }
        if let group = host.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
            return group
        }
        return "SSH"
    }

    // MARK: Keys data

    private func reloadKeys() {
        refreshSidebar()
        var items = keyStore.keys.map { keyItem($0) }
        if items.isEmpty {
            items = [.empty(symbol: "key.fill",
                            title: "No saved keys yet",
                            body: "Generate a key, or import an existing PEM or OpenSSH one. Private key material stays in the macOS Keychain.")]
        }
        keysTitleLabel.stringValue = HostsTab.keys.title
        keysList.setItems(items)
        refreshWorkspacePanel()
        refreshDetailPanel()
        onDrillSubtitleChanged?()
    }

    private func keyItem(_ key: SSHKey) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: key.type.tint,
                                            kicker: key.type.displayName,
                                            title: key.label,
                                            meta: key.fingerprint,
                                            badgeSymbol: "key.fill")
        content.metaIsCode = true
        if key.hasPassphrase { content.chipText = "Passphrase" }
        var item = HostsListSection.Item(content: content)
        item.recordKey = key.id.uuidString
        item.primary = .init(title: "Edit", symbol: "pencil") { [weak self] in self?.presentKeyEditor(for: key) }
        item.activate = { [weak self] in self?.presentKeyEditor(for: key) }
        item.overflow = [
            .init(title: "Copy Public Key") { copyToPasteboard(key.publicKey) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteKey(key) },
        ]
        return item
    }

    // MARK: Snippets data

    private func reloadSnippets() {
        refreshSidebar()
        var items = snippetStore.snippets.map { snippetItem($0) }
        if items.isEmpty {
            items = [.empty(symbol: "chevron.left.forwardslash.chevron.right",
                            title: "No snippets yet",
                            body: "Save a command you run often, then send it to any terminal tab in one click.")]
        }
        snippetsTitleLabel.stringValue = HostsTab.snippets.title
        snippetsList.setItems(items)
        refreshWorkspacePanel()
        refreshDetailPanel()
        onDrillSubtitleChanged?()
    }

    private func snippetItem(_ snippet: Snippet) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: .info,
                                            kicker: "Snippet",
                                            title: snippet.label,
                                            meta: snippet.subtitle,
                                            badgeSymbol: "chevron.left.forwardslash.chevron.right")
        content.metaIsCode = true
        var item = HostsListSection.Item(content: content)
        item.recordKey = snippet.id.uuidString
        item.primary = .init(title: "Run", symbol: "play.fill") { [weak self] in self?.onRunSnippet?(snippet) }
        item.activate = { [weak self] in self?.onRunSnippet?(snippet) }
        item.overflow = [
            .init(title: "Edit…") { [weak self] in self?.presentSnippetEditor(for: snippet) },
            .init(title: "Copy Command") { copyToPasteboard(snippet.command) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteSnippet(snippet) },
        ]
        return item
    }

    // MARK: Host actions

    private func connect(_ host: Host) {
        onConnect?(host.id, host.label, host.sshArguments(allHosts: hostStore.hosts),
                   host.accentHex, host.keyID, host.startupSnippetID)
    }

    private func duplicate(_ host: Host) {
        var copy = host
        copy.id = UUID()
        copy.label = host.label + " copy"
        hostStore.add(copy)
    }

    /// ⌘N / the card header's "Add Host": add a new host.
    @objc func newHost() {
        select(tab: .hosts)
        onAddOrEdit?(nil)
    }

    /// The Hosts menu's Quick Connect: focus the quick-connect field.
    @objc func focusQuickConnect() {
        select(tab: .hosts)
        searchField.focusEditor()
    }

    /// Return in the quick-connect field: match a saved host, else parse an
    /// ad-hoc `[user@]host[:port]`.
    private func quickConnectFromField() {
        let raw = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { NSSound.beep(); return }
        // Exact label match wins; otherwise a single filtered result is
        // treated as the intended host.
        if let exact = hostStore.hosts.first(where: { $0.label.caseInsensitiveCompare(raw) == .orderedSame }) {
            connect(exact)
            return
        }
        let visible = filteredHosts(raw)
        if visible.count == 1 {
            connect(visible[0])
            return
        }
        if let parsed = HostCatalog.parseQuickConnect(raw) {
            onConnect?(nil, parsed.label, parsed.args, nil, nil, nil)
            searchField.stringValue = ""
            applyHostFilter("")
            return
        }
        NSSound.beep()
    }

    private func confirmDeleteHost(_ host: Host) {
        guard confirm(message: "Delete \u{201C}\(host.label)\u{201D}?",
                      detail: "This removes the saved host. It does not affect any running session.")
        else { return }
        hostStore.delete(id: host.id)
        // GL-33: the record is still in hand right here, so restoring it is a
        // real `add` of the same value - not a reconstruction.
        Toast.showUndo(in: view, message: "Deleted \u{201C}\(host.label)\u{201D}") { [weak self] in
            self?.hostStore.add(host)
        }
    }

    // MARK: Key actions

    /// ⌘⇧N / the card header's "New Key".
    @objc func newKey() {
        select(tab: .keys)
        presentKeyEditor(for: nil)
    }

    private func presentKeyEditor(for key: SSHKey?) {
        let usedByHostCount = key.map { targetKey in hostStore.hosts.filter { $0.keyID == targetKey.id }.count } ?? 0
        let editor = KeyEditorController(key: key, usedByHostCount: usedByHostCount)
        editor.onSave = { [weak self] newKey, privateKeyData, passphrase in
            self?.persistNewKey(newKey, privateKeyData: privateKeyData, passphrase: passphrase)
        }
        editor.onUpdate = { [weak self] updatedKey, newPassphrase in
            self?.persistUpdatedKey(updatedKey, newPassphrase: newPassphrase)
        }
        // GL-06: the sheet's own Delete button used to call `keyStore.delete`
        // straight through - unconfirmed, and that call removes the Keychain
        // private key and passphrase, which exist nowhere else (key material is
        // deliberately excluded from `.glbackup` exports). It now goes through
        // the exact same `confirmDeleteKey` the row-level `⋯` menu uses, whose
        // copy already spells out the Keychain consequence.
        //
        // Deferred to the next runloop turn on purpose: the editor dismisses
        // itself immediately after this closure returns, so running a modal
        // here would stack an alert on a sheet that is mid-teardown.
        editor.onDelete = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, let key = self.keyStore.key(id: id) else { return }
                self.confirmDeleteKey(key)
            }
        }
        presentAsSheet(editor)
    }

    /// Create mode: `SSHKeyStore.addNew` writes the Keychain secrets before
    /// adding the metadata.
    private func persistNewKey(_ key: SSHKey, privateKeyData: Data, passphrase: String?) {
        do {
            try keyStore.addNew(key, privateKeyData: privateKeyData, passphrase: passphrase)
            Toast.show(in: view, message: "\u{201C}\(key.label)\u{201D} saved")
        } catch {
            presentError(error, context: "Couldn't save \"\(key.label)\" to the Keychain")
        }
    }

    /// Edit mode never touches the private key; a new passphrase (when typed)
    /// overwrites the existing Keychain entry for it.
    private func persistUpdatedKey(_ key: SSHKey, newPassphrase: String?) {
        if let newPassphrase {
            do {
                try KeychainKeyStore.savePassphrase(id: key.id, passphrase: newPassphrase)
            } catch {
                presentError(error, context: "Couldn't update the passphrase for \"\(key.label)\"")
                return
            }
        }
        keyStore.update(key)
        Toast.show(in: view, message: "\u{201C}\(key.label)\u{201D} saved")
    }

    private func confirmDeleteKey(_ key: SSHKey) {
        guard confirm(message: "Delete \u{201C}\(key.label)\u{201D}?",
                      detail: "This removes the key's Keychain entry (private key and passphrase). "
                            + "Any host still referencing it will fall back to the system ssh agent.")
        else { return }
        keyStore.delete(id: key.id)
    }

    // MARK: Snippet actions

    /// ⌘⌥N / the card header's "New Snippet".
    @objc func newSnippet() {
        select(tab: .snippets)
        presentSnippetEditor(for: nil)
    }

    private func presentSnippetEditor(for snippet: Snippet?) {
        let editor = SnippetEditorController(snippet: snippet)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.snippetStore.snippet(id: saved.id) != nil {
                self.snippetStore.update(saved)
            } else {
                self.snippetStore.add(saved)
            }
        }
        // GL-06: same fix as the key editor above - route the sheet's Delete
        // through the row-level confirmation instead of deleting outright.
        editor.onDelete = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, let snippet = self.snippetStore.snippet(id: id) else { return }
                self.confirmDeleteSnippet(snippet)
            }
        }
        presentAsSheet(editor)
    }

    private func confirmDeleteSnippet(_ snippet: Snippet) {
        guard confirm(message: "Delete \u{201C}\(snippet.label)\u{201D}?",
                      detail: "Any host using this as its startup snippet will fall back to no startup command.")
        else { return }
        snippetStore.delete(id: snippet.id)
        Toast.showUndo(in: view, message: "Deleted \u{201C}\(snippet.label)\u{201D}") { [weak self] in
            self?.snippetStore.add(snippet)
        }
    }

    // MARK: Shared alerts

    /// GL-06: one implementation, shared with the host editor window in
    /// `main.swift`. Note the button order changed with it - the destructive
    /// action is no longer the default, so Return cancels.
    private func confirm(message: String, detail: String) -> Bool {
        DestructiveConfirm.confirm(message: message, detail: detail)
    }

    private func presentError(_ error: Error, context: String) {
        HelmConfirm.problem(title: context, body: error.localizedDescription)
    }

    // MARK: Probe / self-test surface

    /// Real, resolved state for a live page, so a probe can assert the merge
    /// without eyeballing a screenshot.
    struct Debug {
        let activeTab: String
        let hostRowCount: Int
        let keyRowCount: Int
        let snippetRowCount: Int
        let hostsCardFrame: NSRect
        let rootWidth: CGFloat
        let hostsTabVisible: Bool
        let keysTabVisible: Bool
        let snippetsTabVisible: Bool
    }

    func debugState() -> Debug {
        view.layoutSubtreeIfNeeded()
        return Debug(activeTab: activeTab.rawValue,
                     hostRowCount: hostsList.debugRowCount,
                     keyRowCount: keysList.debugRowCount,
                     snippetRowCount: snippetsList.debugRowCount,
                     hostsCardFrame: hostsList.card.convert(hostsList.card.bounds, to: view),
                     rootWidth: view.bounds.width,
                     hostsTabVisible: !hostsTabView.isHidden,
                     keysTabVisible: !keysTabView.isHidden,
                     snippetsTabVisible: !snippetsTabView.isHidden)
    }

    #if FM_SELFTESTS
    var debugSideStack: HostsSideStack { sideStack }
    /// UI1: the Hosts card header as rendered, so a suite can assert the count
    /// really came off it rather than trusting the format string.
    var debugHostsTitle: String { hostsTitleLabel.stringValue }
    /// Whether the tag strip has left the filter row's layout.
    ///
    /// The vacuity guard for `checkTwoColumnLayoutSurvivesUntaggedHosts`: that
    /// case only exercises the collapse it exists for while this is `true`, so
    /// a fixture that drifts back to tagged hosts has to fail loudly rather
    /// than pass while testing nothing.
    var debugTagStripIsHidden: Bool { tagsScroll.isHidden }
    var debugOnlineChip: HelmButton { onlineChip }
    func debugSetOnlineOnly(_ on: Bool) {
        onlineChip.state = on ? .on : .off
        onlineChipClicked(onlineChip)
    }
    #endif

    func debugList(_ tab: HostsTab) -> HostsListSection {
        switch tab {
        case .hosts: return hostsList
        case .keys: return keysList
        case .snippets: return snippetsList
        }
    }
}

private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
