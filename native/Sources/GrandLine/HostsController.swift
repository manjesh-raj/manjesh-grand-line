// Grand Line - native macOS app.
//
// The Hosts destination: saved SSH hosts, SSH keys and command snippets, as
// three scopes of one full-width page, switched by Connections' tabs in the
// toolbar. (They were a `HelmSegmentedTabs` strip *and* a left nav column until
// review #3's UI1, and that column until P-03 of the 2026-11-25 review: the
// toolbar's tabs switch them now.)
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
// **What it is built out of.** Nothing new: the page is the shared
// components assembled. Each scope is one `HelmDataTable`, and Hosts and Keys
// also draw their records as `HelmCardGrid` cards (the Grid / List switch).
// The split's pane holds the `HelmHeroColumn` (`HostsController+HeroColumn.swift`),
// and the selected record's details are the shell's inspector
// (`WorkspaceInspectorSource`, at the end of this file).
//
// **Where the actions went.** The footer strip is gone. A row's own actions
// (Connect / Edit / Run, plus a menu carrying the rest) live in that row's
// actions column, and the "add" action is the toolbar's primary action. So no
// action is ever a 370pt-wide button, and no action depends on the list
// having a selection first.
//
// This view stays decoupled from the terminal exactly as its three
// predecessors were: it takes the three stores plus `onConnect` /
// `onConnectPinned` / `onAddOrEdit` / `onRunSnippet` closures, and never
// touches `ConsoleController` or SwiftTerm.

import AppKit

/// Which of the destination's three scopes is showing. The toolbar draws them
/// as Connections' Hosts, Keys and Snippets tabs (`ModuleTabHosting`, at the
/// end of this file). The name is kept: it is the vocabulary ~30 call sites
/// across the menu bar, the search palette and the shell already speak.
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

final class HostsController: NSViewController, DaylightDrillActions, HelmSplitPageHosting {

    let hostStore: HostStore
    let keyStore: SSHKeyStore
    let snippetStore: SnippetStore

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

    // MARK: F12 - the expander

    /// The live expansion state, read fresh on every visit and every store
    /// change rather than cached: the master toggle, whether this process is
    /// really a trusted Accessibility client, and how many saved snippets have
    /// a usable trigger. Wired in `main.swift` to the one `SnippetExpander`.
    /// Absent (the page mounted standalone in a suite), the panel reads off.
    var snippetExpansionState: (() -> (enabled: Bool, trusted: Bool, armed: Bool, triggerCount: Int))?

    /// The master switch was flipped. The delegate persists it and starts or
    /// stops the live monitors - a settings write alone would leave them
    /// installed, the same trap `DictationHotkey.updateShortcut` records.
    var onSnippetExpansionToggled: ((Bool) -> Void)?

    /// "Grant access…" - the one Accessibility prompt Dictation and ⌥Space
    /// already use, never a second one.
    var onRequestAccessibilityTrust: (() -> Void)?

    // MARK: Views


    var activeTab: HostsTab = .hosts
    /// The toolbar draws the three tabs as Connections' Hosts, Keys and
    /// Snippets (`ModuleTabHosting`, at the end of this file).
    var onModuleTabChanged: (() -> Void)?

    let hostsTabView = NSView()
    let keysTabView = NSView()
    private let snippetsTabView = NSView()

    /// H3's Connect button, beside the find-or-connect field. It runs exactly
    /// what Return in the field runs.
    private lazy var findOrConnectButton: HelmButton = {
        let b = HelmButton(title: "Connect", variant: .secondary, size: .small, symbol: "bolt.fill",
                           target: self, action: #selector(findOrConnectClicked))
        b.isEnabled = false
        return b
    }()

    /// Quick connect / live filter, in the app's own search well
    /// (Phase 0's raw-input purge). An `NSSearchField` paints its own system
    /// chrome and system fill, which is what the audit measured as the
    /// wallpaper-tinted field on this page (D2) - forcing its `appearance`
    /// only picks the light-or-dark side of that system colour.
    let searchField = HelmSearchField(placeholder: HostsController.findOrConnectPlaceholder)
    private let tagsScroll = NSScrollView()
    private let tagsStack = NSStackView()
    private var tagButtons: [String: HelmButton] = [:]
    private(set) var selectedTags: Set<String> = []

    /// X4: the chips match a host carrying every selected tag, or any one of
    /// them. Read once from `AppSettings` and written back on every change.
    private var tagMatchAll = AppSettings.shared.hostTagMatchAll

    /// X4's switch, in the filter row. It only means
    /// anything with two or more tags selected, so it shows only then.
    private lazy var tagMatchControl: HelmSegmentedTabs = {
        let tabs = HelmSegmentedTabs(items: [.init(id: Self.tagMatchAnyID, title: "Any tag"),
                                            .init(id: Self.tagMatchAllID, title: "All tags")],
                                     selected: tagMatchAll ? Self.tagMatchAllID : Self.tagMatchAnyID,
                                     size: .compact)
        tabs.onSelect = { [weak self] id in self?.setTagMatchAll(id == Self.tagMatchAllID) }
        tabs.setAccessibilityLabel("Show hosts with any of the selected tags, or with all of them")
        tabs.toolTip = "Match any selected tag, or all of them"
        return tabs
    }()
    static let tagMatchAnyID = "any"
    static let tagMatchAllID = "all"

    /// H9: the tags that do not fit the filter row, behind one "+N" chip
    /// rather than cut off at the row's edge.
    private lazy var tagOverflowChip: HelmButton = {
        let b = HelmButton(title: "+0", variant: .secondary, size: .small,
                           target: self, action: #selector(tagOverflowClicked(_:)))
        b.toolTip = "More tags"
        b.isHidden = true
        return b
    }()
    /// How many of the sorted tag chips the row is showing (H9).
    private var visibleTagChipCount = Int.max
    /// The widest "+N" can draw, by tag count and text scale - see
    /// `reservedOverflowWidth`.
    private var overflowWidthCache: [String: CGFloat] = [:]

    /// The content column's inset from the split's content pane: the gap
    /// beside the hero column, or the page gutter while the column is put away
    /// (`refreshContentLeading`).
    private var contentLeading: NSLayoutConstraint?
    /// The Hosts tab's one row over its records: the search, H3's Connect,
    /// All / Online and the group and tag filters (`buildHostsTab`).
    let hostsFilterRow = NSStackView()

    /// P9: the page's split view. Its pane holds the hero column (C-4).
    private(set) var splitPage: HelmSplitPage?

    /// Whether the hosts are filtered to those with a live session - the
    /// All / Online segments (`onlineFilter`).
    private(set) var onlineOnly = false

    /// Review #3's UX6: "the Hosts sidebar should carry *filters* (Online, by
    /// tag, by group)".
    ///
    /// Two of those three already existed when this was written - the Online
    /// filter and the tag chips - and they live in this filter row rather
    /// than in a column of their own deliberately: they are list-scoped, and
    /// they compose with the search field beside them.
    ///
    /// **Group was the one genuinely missing filter**, and it is the one the
    /// captain's own data wants: `buildHostsTab`'s own comment records that
    /// "his hosts record an environment in `group`, not in `tags`" - so the
    /// tag chips are empty for him and the list has no way to narrow to one
    /// environment at all.
    ///
    /// A popup rather than chips, because the two filters differ in kind: a
    /// host carries many tags (so tags are a multi-select chip row) and
    /// exactly one group (so group is a single-select list). Drawing a
    /// single-select choice as a row of toggles would invite a captain to pick
    /// two and get nothing.
    private(set) lazy var groupPicker: HelmPopUpButton = {
        let picker = HelmPopUpButton()
        picker.target = self
        picker.action = #selector(groupPicked)
        picker.toolTip = "Show only hosts in one group"
        return picker
    }()

    /// `nil` is "every group", which is the resting state and the first item
    /// in the popup. A group that stops existing (its last host was edited or
    /// deleted) clears this rather than leaving the list filtered to nothing -
    /// see `rebuildGroupPicker`.
    private(set) var selectedGroup: String?

    /// The popup's "no filter" row. A literal rather than an empty string so
    /// it can never collide with a real group of that name - a host group is
    /// trimmed non-empty text, and this is a marker held in
    /// `representedObject`, not a title match.
    private static let allGroupsMarker = "\u{0000}all"

    /// H8: Add Host - the main action, and a menu of the other ways to add a
    /// host. The toolbar's primary action on the Hosts tab.
    private lazy var addHostSplit = HelmSplitButton(
        title: "Add Host", symbol: "plus", menuLabel: "More ways to add a host",
        items: [
            .init("New Host\u{2026}", symbol: "plus") { [weak self] in self?.newHost() },
            .init("Quick Connect", symbol: "bolt") { [weak self] in self?.focusQuickConnect() },
            .separator,
            .init("Import from SSH Config\u{2026}", symbol: "square.and.arrow.down") { [weak self] in
                self?.openSSHConfigImport()
            },
        ]) { [weak self] in self?.newHost() }

    /// K2: New Key's ways in, each straight to the right form.
    private lazy var addKeySplit = HelmSplitButton(
        title: "New Key", symbol: "plus", menuLabel: "More ways to add a key",
        items: [
            .init("Generate Ed25519 Key\u{2026}", symbol: "wand.and.stars") { [weak self] in
                self?.openNewKey(preset: .generate(.ed25519))
            },
            .init("Generate RSA 3072 Key\u{2026}", symbol: "wand.and.stars") { [weak self] in
                self?.openNewKey(preset: .generate(.rsa))
            },
            .separator,
            .init("Import Key File\u{2026}", symbol: "doc.badge.plus") { [weak self] in self?.openNewKey(preset: .importFile) },
            .init("Paste a Key\u{2026}", symbol: "doc.on.clipboard") { [weak self] in self?.openNewKey(preset: .paste) },
            .separator,
            .init("Attach Certificate to Selected Key\u{2026}", symbol: "checkmark.seal",
                  isEnabled: { [weak self] in self?.selectedSSHKey != nil }) { [weak self] in
                guard let self, let key = self.selectedSSHKey else { return }
                self.presentKeyEditor(for: key, preset: .certificate)
            },
        ]) { [weak self] in self?.newKey() }

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

    // MARK: The presentation (`buildSidebarPresentation`, at the end of this file)

    private(set) lazy var hostsTable = Self.makeHostsTable()
    /// H1: the hosts as cards, the page's default view (C4).
    /// `HostsController+Cards.swift` fills it. C-1's roomy card: 98pt tall,
    /// at least 280pt wide, so two sit beside the hero column.
    private(set) lazy var hostsGrid = HelmCardGrid(cardHeight: HelmCardGrid.roomyCardHeight,
                                                   minimumCardWidth: HelmCardGrid.roomyMinimumCardWidth,
                                                   maximumColumns: 2)
    /// C-4: the hero column in the split's sidebar pane
    /// (`HostsController+HeroColumn.swift`).
    var heroColumn: HelmHeroColumn?
    /// UX-27: where the hero column goes as a band while its pane is put
    /// away, and the gaps under it that open only while it holds the band.
    let bandHost = NSView()
    var bandGaps: [NSLayoutConstraint] = []
    /// The column's Recent pills' runs, by tag.
    var heroRecentRuns: [() -> Void] = []
    /// The column's Quick connect field. One instance, so its text survives
    /// a re-render.
    private(set) lazy var heroQuickConnectField = HelmSearchField(placeholder: "user@host", symbol: "bolt.fill")
    /// H6: the host form in the side panel, and which record it is for -
    /// a host's id, or `newHostPanelKey` (H10). `HostsController+Panel.swift`.
    var hostPanel: HostEditorController?
    /// UX-26: the Add or Edit Host sheet while it is up.
    weak var hostSheet: HostEditorController?
    var hostPanelKey: String?
    /// Set while the panel's save writes the store, whose reload must not
    /// rebuild the form mid-save.
    var hostPanelIsSaving = false
    /// X1: the SSH config import's preview, while it is open.
    var importPanel: SSHConfigImportPanelController?
    /// R4-UX-04: how the panel's Test runs ssh. A suite answers for it,
    /// because a self-test process never starts the real tool.
    var connectionTestRunner: HostConnectionTest.Runner = HostConnectionTest.subprocessRunner
    /// K7 and K8: the key form in the side panel, and which key it is for -
    /// an id, or `newKeyPanelKey`. `HostsController+KeyPanel.swift`.
    var keyPanel: KeyEditorController?
    var keyPanelKey: String?
    /// H2: Grid or List, over the hosts. One stored choice
    /// (`AppSettings.connectionsShowList`) for Hosts and Keys.
    lazy var hostsViewModeControl = makeViewModeControl()
    private(set) lazy var keysTable = Self.makeKeysTable()
    /// K1: the keys as cards, the same component as the hosts'.
    /// C-1's roomy card, two to a row beside the hero column, like the hosts.
    private(set) lazy var keysGrid = HelmCardGrid(cardHeight: HelmCardGrid.roomyCardHeight,
                                                  minimumCardWidth: HelmCardGrid.roomyMinimumCardWidth,
                                                  maximumColumns: 2)
    /// H2's switch on the Keys tab - the same stored choice.
    lazy var keysViewModeControl = makeViewModeControl()
    /// K3: key search, by name, type or fingerprint.
    let keySearchField = HelmSearchField(placeholder: "Find a key by name, type or fingerprint")
    /// The Keys tab's row over its keys: the search, Touch ID, Grid / List.
    let keysTopRow = NSStackView()
    private lazy var snippetsTable = Self.makeSnippetsTable()
    /// The inspector's body for whichever table is showing.
    private lazy var inspectorDetail = WorkspaceDetailView()
    /// F12's switch, as a plain row over the Snippets table (stage 6: no
    /// card).
    private lazy var expansionStrip = SnippetExpansionPanel()
    private lazy var snippetsTableUnderStrip = snippetsTable.card.topAnchor.constraint(
        equalTo: expansionStrip.bottomAnchor, constant: HelmMetrics.s3)
    private lazy var snippetsTableAtTop = snippetsTable.card.topAnchor.constraint(equalTo: snippetsTabView.topAnchor)
    /// The prototype's All / Online filter over the hosts, with each count.
    /// There is no Problems segment: nothing records a host's reachability
    /// (the later page work's decision).
    private lazy var onlineFilter: HelmSegmentedTabs = {
        let tabs = HelmSegmentedTabs(items: [.init(id: Self.allFilterID, title: "All"),
                                            .init(id: Self.onlineFilterID, title: "Online")],
                                     selected: Self.allFilterID, size: .compact)
        tabs.onSelect = { [weak self] id in self?.setOnlineOnly(id == Self.onlineFilterID) }
        tabs.setAccessibilityLabel("Show all hosts, or only hosts with a live session")
        return tabs
    }()
    static let allFilterID = "all"
    static let onlineFilterID = "online"
    /// Touch ID's state in the Keys row: it is a fact about where keys are
    /// kept.
    private(set) lazy var keysTouchID = HelmStatusPill(style: .dotWord)
    /// The selected record's name, or `nil` with nothing selected - what
    /// `inspectorContent` hands the shell.
    private var inspectorTitle: String?
    var onInspectorContentChanged: (() -> Void)?
    var onShowInspector: (() -> Void)?

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
        // F12: `AXIsProcessTrusted` can change while this app is running (the
        // captain granting it in System Settings is the whole point), so the
        // switch re-reads it on every visit rather than caching what it found at
        // launch - the same "read the real permission fresh" rule
        // `DictationController` follows.
        refreshExpansionPanel()
        // The Touch ID probe, re-read on every visit for the same reason.
        refreshKeysTouchID()
    }

    override func loadView() {
        // A plain, layer-backed, theme-filled root - never an
        // `NSVisualEffectView`. AGENTS.md gotcha #8: `.behindWindow` blending
        // composites against what is behind the *window*, which is wrong for
        // a full-size destination.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1136, height: 660))
        root.wantsLayer = true
        view = root

        // The page draws no scope control of its own. Review #3's UI1 took
        // away its tab strip, and P-03 of the 2026-11-25 review its nav
        // column: the toolbar's Hosts, Keys and Snippets tabs are the only
        // ones (`ModuleTabHosting`, at the end of this file).
        buildHostsTab()

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
        // down - a host row's Connect and `...` sit in their own
        // right-anchored slot, so a wider row puts the extra width *between*
        // the short strings and the actions rather than stretching either.
        // The table's actions column does the same today.
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
            // S03: the page frame's first-content line, where the search
            // and filter row sits.
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.pageContentInset),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.pageGutter),

        ])

        // P9: the page is a split view whose pane holds the hero column (C-4,
        // `adoptHeroColumn`) - draggable, collapsible and answering Toggle
        // Sidebar. Everything else starts after the split's content pane, so
        // the page follows the divider.
        //
        // The split sits *under* the page's own views, which keep their
        // layout guides on `root`; only the hero column moves into it.
        //
        // The pane is the column and its gutter, and its minimum is low so the
        // content's floor squeezes it rather than growing the window; the
        // width rule then puts the column away (`HelmSplitPage` 1.2.0).
        let pane = HelmMetrics.pageGutter + HelmHeroColumn.width
        let split = HelmSplitPage(sidebarWidth: pane, minimum: HelmSplitPage.yieldingMinimumThickness,
                                  maximum: pane, surface: .pageGround)
        addChild(split)
        root.addSubview(split.view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        splitPage = split

        // The content column, from the split's content pane to the page
        // gutter. The three tab views fill it, and only the showing one is
        // visible.
        let content = NSLayoutGuide()
        root.addLayoutGuide(content)
        let leading = content.leadingAnchor.constraint(equalTo: split.contentPane.leadingAnchor,
                                                       constant: HelmMetrics.s5 - HelmSplitPage.dividerThickness)
        contentLeading = leading
        NSLayoutConstraint.activate([
            leading,
            content.topAnchor.constraint(equalTo: column.topAnchor),
            content.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            content.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])

        // UX-27: a narrow page keeps its hero as a band over the tabs, as
        // Health does. Empty, the host is zero tall and the tabs start where
        // they always did.
        bandHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bandHost)
        let bandEmpty = bandHost.heightAnchor.constraint(equalToConstant: 0)
        bandEmpty.priority = .defaultLow
        NSLayoutConstraint.activate([
            bandHost.topAnchor.constraint(equalTo: content.topAnchor),
            bandHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bandHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bandEmpty,
        ])
        for tabView in [hostsTabView, keysTabView, snippetsTabView] {
            tabView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(tabView)
            let top = tabView.topAnchor.constraint(equalTo: bandHost.bottomAnchor)
            bandGaps.append(top)
            NSLayoutConstraint.activate([
                top,
                tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }

        // **Window-floor discipline** (gotchas (13)/(14)): the flexible column
        // is the content, and its minimum sits at
        // `HelmDaylightPriority.contentTie` (499), below
        // `NSLayoutPriorityWindowSizeStayPut`. `AppShellBodyWidthSelfTest`
        // sweeps every destination for exactly that.
        let contentMinimum = hostsTabView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.contentMinimumWidth)
        contentMinimum.priority = HelmDaylightPriority.contentTie
        contentMinimum.isActive = true

        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }

        hostStore.observe { [weak self] in self?.reloadHosts() }
        keyStore.observe { [weak self] in self?.reloadKeysAndCounts() }
        snippetStore.observe { [weak self] in self?.reloadSnippetsAndCounts() }

        select(tab: .hosts, moveTabControl: true)
        reloadHosts()
        reloadKeys()
        reloadSnippets()
        // The `ThemeManager.observe` closure above fires synchronously at
        // registration - before the tables had any rows - so re-apply once the
        // page is fully built (`ThemeManager.swift`'s checklist item 4, the
        // trap this codebase has now hit four times).
        applyTheme(ThemeManager.shared.theme)

        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the page builds its sidebar presentation as part of loading.
        buildSidebarPresentation()
    }

    /// The narrowest the tab's own content column is allowed to get before the
    /// window itself has to give. Held *below* `NSLayoutPriorityWindowSizeStayPut`
    /// at the one place it is applied, so it can never become a window floor.
    static let contentMinimumWidth: CGFloat = 360

    // MARK: Counts and the expansion switch

    /// F12's switch over the Snippets table. It sits in the Snippets tab view,
    /// so it shows on that tab only.
    func refreshExpansionPanel() {
        let state = snippetExpansionState?()
            ?? (enabled: false, trusted: false, armed: false, triggerCount: 0)
        expansionStrip.setState(enabled: state.enabled, trusted: state.trusted,
                                armed: state.armed, triggerCount: state.triggerCount)
        // UI-10: the column carries the same switch while Snippets shows.
        if activeTab == .snippets, heroColumn != nil { renderHeroColumn() }
    }

    /// UI-10: the switch lives in the hero column while the column shows,
    /// and the strip over the table comes back whenever it is put away (a
    /// narrow page, Toggle Sidebar), so it is never out of reach.
    func refreshExpansionStripPlacement() {
        let inColumn = heroColumnShowing
        guard expansionStrip.isHidden != inColumn || snippetsTableAtTop.isActive != inColumn else { return }
        expansionStrip.isHidden = inColumn
        if inColumn {
            snippetsTableUnderStrip.isActive = false
            snippetsTableAtTop.isActive = true
        } else {
            snippetsTableAtTop.isActive = false
            snippetsTableUnderStrip.isActive = true
        }
    }

    /// "All 7" and "Online 5": the saved hosts, and those the app's one
    /// session registry has a live session for - read where the table is
    /// rendered, so the segments and the rows can never disagree within a
    /// frame.
    private func refreshHostCounts() {
        let live = hostStore.hosts.reduce(0) { $0 + (liveSession?($1.id) != nil ? 1 : 0) }
        refreshSidebarFilterCounts(all: hostStore.hosts.count, online: live)
    }

    /// Fill (or empty) the shell's inspector from the showing tab's own
    /// selection.
    func refreshDetailPanel() {
        refreshSidebarInspector()
    }

    /// The saved key's own label, never a path or key material - the same
    /// thing `Host.keyID` stores and the host editor shows.
    func credentialName(for host: Host) -> String {
        guard let keyID = host.keyID else { return "ssh agent" }
        return keyStore.key(id: keyID)?.label ?? "Missing key"
    }

    /// The Hosts tab's filter row, over its cards and its table. The cards
    /// and the table hang under it (`adoptHostsGrid`, `buildSidebarPresentation`).
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

        // One row: the search and H3's Connect, then All / Online and the
        // group and tag filters. The search keeps every behaviour it had - live
        // filtering, and Return connecting to a typed `ssh user@host`.
        //
        // `filterSpacer` is a flexible trailing member that is ALWAYS in
        // layout, and it is load-bearing rather than tidiness.
        //
        // `rebuildTagChips` hides the tag strip whenever no host carries a tag.
        // That is the common case, and it is the captain's own data: his hosts
        // record an environment in `group`, not in `tags`. An `NSStackView`
        // drops a hidden arranged subview out of layout entirely (gotcha
        // (11)'s own stack exemption), so the row's slack needs a home that is
        // always there. Before this spacer existed, the row's one remaining
        // member hugged at `.required`, and since the row is pinned to both
        // edges of `hostsTabView`, that one control's intrinsic width became a
        // *required* ceiling on the entire content column. Measured on a real
        // shell at the captain's own 1467pt window: the content column
        // collapsed to 74pt. That is exactly his report: no host list at all.
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

        let row = hostsFilterRow
        for member in [searchField, findOrConnectButton, onlineFilter, groupPicker,
                       tagMatchControl, tagsScroll, tagOverflowChip, filterSpacer] as [NSView] {
            row.addArrangedSubview(member)
        }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (10): at the default `.gravityAreas` no hugging
        // priority is honoured at all, so the strip would not take the slack
        // the fixed controls leave.
        row.distribution = .fill
        row.setCustomSpacing(HelmMetrics.s1, after: searchField)
        row.setCustomSpacing(HelmMetrics.s3, after: findOrConnectButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        groupPicker.translatesAutoresizingMaskIntoConstraints = false
        // H3's Connect, All / Online, the group filter, X4's switch and H9's
        // "+N" are fixed-size chrome, so `tagsScroll` (and then
        // `filterSpacer`) must be what absorbs the row's slack - gotcha (5).
        for fixed in [findOrConnectButton, onlineFilter, groupPicker, tagMatchControl, tagOverflowChip] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // Those two are no-ops on a view with no intrinsic size (gotcha
        // (12)), and All / Online's pills can stretch, so with no tag strip to
        // take the row's slack (the captain's own hosts carry none) All /
        // Online took it: measured 307pt wide, which pushed the group filter
        // to the far end of the row. A real hug, just above the spacer's
        // collapse (250), so the spacer is what stretches.
        let hug = onlineFilter.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(252)
        hug.isActive = true
        // The search is wide enough for its placeholder, and the first thing
        // to give way.
        let width = searchField.widthAnchor.constraint(equalToConstant: Self.sidebarSearchWidth)
        width.priority = HelmDaylightPriority.columnHug
        width.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sidebarSearchMinimumWidth).isActive = true
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // X4 shows only with two or more tags selected (`refreshTagMatchControl`).
        tagMatchControl.isHidden = true
        refreshFindOrConnectButton()
        // H9: the strip refits its chips whenever its width changes.
        tagsScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tagStripResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: tagsScroll.contentView)

        hostsTabView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: hostsTabView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: hostsTabView.trailingAnchor),
            row.topAnchor.constraint(equalTo: hostsTabView.topAnchor),
        ])
    }

    // MARK: Tabs

    /// Switch scopes.
    ///
    /// `moveTabControl` is kept as a parameter and deliberately ignored: the
    /// page draws no tab control of its own to move, and several callers (the
    /// menu bar, the search palette, the shell) pass it explicitly. The
    /// toolbar follows through `onModuleTabChanged`, so a switch from anywhere
    /// lands here exactly once.
    func select(tab: HostsTab, moveTabControl: Bool = true) {
        _ = moveTabControl
        activeTab = tab
        hostsTabView.isHidden = tab != .hosts
        keysTabView.isHidden = tab != .keys
        snippetsTabView.isHidden = tab != .snippets
        // The inspector follows the showing tab, so a selection left behind
        // on a hidden table is never what it displays.
        if isViewLoaded {
            refreshDetailPanel()
            refreshExpansionPanel()
        }
        // C-4: the column's room depends on the showing tab's top row, and
        // its words follow the showing tab (Hosts or Keys).
        if heroColumn != nil {
            refreshSplitColumn()
            renderHeroColumn()
        }
        // §6.4: both halves of the header describe the tab that is showing.
        onDrillActionsChanged?()
        onDrillSubtitleChanged?()
        onModuleTabChanged?()
    }

    // MARK: Drill header (Daylight §6.4)

    /// The showing tab's own add action. Re-read (not rebuilt) on every tab
    /// switch through `onDrillActionsChanged`, so the same three instances -
    /// with the tooltips and targets this page set on them - move in and out
    /// of the header. For Hosts and Keys they are H8's and K2's split buttons.
    var drillHeaderActions: [NSView] {
        return [workspacePrimaryAction].compactMap { $0 }
    }

    /// §6.4's live subtitle - what the showing scope *is*, not how much of it
    /// there is.
    ///
    /// **Review #3's UI1.** This used to read "3 saved hosts \u{00B7} 0 keys",
    /// which made the number 3 one of several statements of the same fact on
    /// one screen. The finding's own remedy is one authoritative statement per
    /// concern, and the counts live on the toolbar's tabs (`moduleTabCounts`)
    /// and the All / Online segments.
    ///
    /// The empty case is kept and is not a count: "no saved hosts yet" is a
    /// *state* the captain acts on, and it is the one thing this line can say
    /// that a tab's missing count does not.
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
            // F12: the one count that is not stated anywhere else on this
            // page, and the only one a captain cannot see by looking - a
            // snippet that expands system-wide behaves differently from one
            // that does not, and the table's Expands in column says which per
            // row but never how many.
            let expanding = snippetStore.snippets.filter { $0.expandsSystemWide }.count
            if snippetStore.snippets.isEmpty { return "No snippets yet" }
            return expanding == 0
                ? "Commands you run often"
                : "Commands you run often \u{00b7} \(expanding) expand system-wide"
        }
    }

    var currentTab: HostsTab { activeTab }

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // A forced appearance is still right for the one stock control left on
        // this page (the quick-connect `NSSearchField`, which Phase 6's
        // `HelmField` owns) - see `ThemeManager.swift`'s checklist rule 2.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        hostsTable.applyTheme(theme)
        keysTable.applyTheme(theme)
        snippetsTable.applyTheme(theme)
        expansionStrip.applyTheme(theme)
        onlineFilter.applyTheme(theme)
        tagMatchControl.applyTheme(theme)
        hostsGrid.applyTheme(theme)
        hostsViewModeControl.applyTheme(theme)
        keysGrid.applyTheme(theme)
        keysViewModeControl.applyTheme(theme)
        keysTouchID.applyTheme(theme)
    }

    // MARK: Hosts data

    private func reloadHosts() {
        rebuildTagChips()
        rebuildGroupPicker()
        applyHostFilter(searchField.stringValue)
        moduleTabCountsMayHaveChanged()
    }

    /// One toggle button per distinct tag across all hosts, sorted for a
    /// stable layout, kept in sync with host edits with no change tracking.
    ///
    /// PERF-05: reconciled by tag through `HelmKeyedRows` rather than emptied
    /// and refilled on every reload. The host table itself is an `NSTableView`
    /// (`HelmDataTable`) that reuses its cells, so this strip is the one
    /// part of `reloadHosts` that still built a view per item of the
    /// captain's data. A tag that is still in use keeps its button; only a
    /// new tag builds one.
    private lazy var tagChips = HelmKeyedRows(stack: tagsStack)

    private func rebuildTagChips() {
        let allTags = Set(hostStore.hosts.flatMap(\.tags)).sorted()
        selectedTags.formIntersection(allTags)
        var buttons: [String: HelmButton] = [:]
        tagChips.reconcile(allTags,
                           key: { $0 },
                           make: { [unowned self] tag in
                               // `.pushOnPushOff` still tracks `state` (which
                               // `tagChipClicked` reads), but nothing draws that
                               // state now the stock bezel is gone - the
                               // `.primary` variant is what shows it.
                               let b = HelmButton(title: tag, variant: .secondary, size: .small,
                                                  target: self, action: #selector(self.tagChipClicked(_:)))
                               b.setButtonType(.pushOnPushOff)
                               b.identifier = NSUserInterfaceItemIdentifier(tag)
                               return b
                           },
                           update: { [unowned self] view, tag in
                               guard let b = view as? HelmButton else { return }
                               b.state = self.selectedTags.contains(tag) ? .on : .off
                               b.variant = b.state == .on ? .primary : .secondary
                               buttons[tag] = b
                           },
                           // A horizontal strip: each chip keeps its own width.
                           tiesWidth: false)
        tagButtons = buttons
        // Only the tag strip collapses when there are no tags - the "Online"
        // chip beside it is always meaningful.
        tagsScroll.isHidden = allTags.isEmpty
        visibleTagChipCount = Int.max
        refreshTagMatchControl()
        refitTagChips()
    }

    /// One row per distinct group across all hosts, plus "All groups" and -
    /// when some host has none - "Ungrouped", which are the same two buckets
    /// the host table already draws as group headers. Rebuilt on every
    /// reload, exactly like `rebuildTagChips`, so it stays in sync with host
    /// edits with no change tracking.
    ///
    /// **The picker hides entirely when every host shares one group** (or none
    /// has one), matching the table's own rule (`renderHostsTable`): group
    /// headers are skipped entirely when every visible host shares one group. A
    /// filter that can only ever produce the list you are already looking at
    /// is noise.
    private func rebuildGroupPicker() {
        let groups = Set(hostStore.hosts.compactMap { normalizedGroup($0) }).sorted()
        let hasUngrouped = hostStore.hosts.contains { normalizedGroup($0) == nil }
        // Hidden is a real removal from layout here - `filterRow` is an
        // `NSStackView` and this is an arranged subview (the stack exemption
        // to gotcha (11)), which is the same mechanism `tagsScroll` relies on.
        groupPicker.isHidden = groups.count < 2 && !(groups.count == 1 && hasUngrouped)
        if groupPicker.isHidden {
            selectedGroup = nil
            return
        }
        // A group the captain had selected that no longer exists clears the
        // filter rather than leaving the list narrowed to nothing with a
        // control that no longer names it.
        if let selected = selectedGroup, selected != Self.ungroupedMarker, !groups.contains(selected) {
            selectedGroup = nil
        }

        groupPicker.removeAllItems()
        let all = NSMenuItem(title: "All groups", action: nil, keyEquivalent: "")
        all.representedObject = Self.allGroupsMarker
        groupPicker.menu?.addItem(all)
        for group in groups {
            let item = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            item.representedObject = group
            groupPicker.menu?.addItem(item)
        }
        if hasUngrouped {
            let item = NSMenuItem(title: "Ungrouped", action: nil, keyEquivalent: "")
            item.representedObject = Self.ungroupedMarker
            groupPicker.menu?.addItem(item)
        }
        groupPicker.selectItem(at: groupFilterIndex)
        // The host cards' Grouped choice - `HostsController+Cards.swift`.
        refreshGroupedChoice()
    }

    /// The menu item naming the group filter as it stands.
    private var groupFilterIndex: Int {
        let wanted = selectedGroup ?? Self.allGroupsMarker
        return groupPicker.menu?.items.firstIndex { $0.representedObject as? String == wanted } ?? 0
    }

    /// The "has no group at all" bucket, matching the list's own "Ungrouped"
    /// header. A marker rather than `nil`, because `selectedGroup == nil`
    /// already means "do not filter".
    private static let ungroupedMarker = "\u{0000}ungrouped"

    @objc private func groupPicked() {
        let marker = groupPicker.selectedItem?.representedObject as? String
        if marker == Self.groupedChoiceMarker {
            groupedChoicePicked(restoring: groupFilterIndex)
            return
        }
        selectedGroup = (marker == Self.allGroupsMarker) ? nil : marker
        applyHostFilter(searchField.stringValue)
    }

    /// The All / Online filter. The segments follow, so they cannot disagree
    /// with the rows.
    private func setOnlineOnly(_ on: Bool) {
        onlineOnly = on
        onlineFilter.select(on ? Self.onlineFilterID : Self.allFilterID)
        applyHostFilter(searchField.stringValue)
    }

    @objc private func tagChipClicked(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        if sender.state == .on { selectedTags.insert(tag) } else { selectedTags.remove(tag) }
        (sender as? HelmButton)?.variant = sender.state == .on ? .primary : .secondary
        refreshTagMatchControl()
        applyHostFilter(searchField.stringValue)
    }

    /// X4: switch between matching any selected tag and all of them.
    private func setTagMatchAll(_ all: Bool) {
        tagMatchAll = all
        AppSettings.shared.hostTagMatchAll = all
        tagMatchControl.select(all ? Self.tagMatchAllID : Self.tagMatchAnyID)
        applyHostFilter(searchField.stringValue)
    }

    /// X4's switch shows only while it can change the result.
    private func refreshTagMatchControl() {
        tagMatchControl.isHidden = selectedTags.count < 2
        refreshTagOverflowChip()
    }

    // MARK: H9 - tag chips that do not fit

    /// How many of `chipWidths` (in order) the row shows, given the tag
    /// strip's current width and whether the "+N" chip is showing now.
    ///
    /// The overflow chip sits beside the strip, so showing it takes its own
    /// width out of the strip's. Every chip fits when the strip would hold
    /// them all with the overflow chip gone; otherwise the count is the most
    /// that fit beside it. Never fewer than zero, and pure, so a suite can
    /// assert the arithmetic at any width.
    static func fittingTagCount(chipWidths: [CGFloat], spacing: CGFloat, stripWidth: CGFloat,
                                overflowWidth: CGFloat, overflowShown: Bool) -> Int {
        func span(_ count: Int) -> CGFloat {
            guard count > 0 else { return 0 }
            return chipWidths.prefix(count).reduce(0, +) + spacing * CGFloat(count - 1)
        }
        let withoutOverflow = overflowShown ? stripWidth + overflowWidth + spacing : stripWidth
        if span(chipWidths.count) <= withoutOverflow + 0.5 { return chipWidths.count }
        let besideOverflow = overflowShown ? stripWidth : stripWidth - overflowWidth - spacing
        var count = 0
        while count < chipWidths.count, span(count + 1) <= besideOverflow + 0.5 { count += 1 }
        return count
    }

    /// The count the strip settles on, from what the strip and "+N" hold
    /// between them, with "+N" reserved at `reservedOverflowWidth` - the
    /// widest its label can be - rather than at the width it has now.
    ///
    /// The strip takes whatever width the row leaves it, so it absorbs any
    /// change in "+N"'s own width. Measured from "+N"'s *current* width the
    /// count fed back on itself: hiding one more chip turned "+4" into "+5",
    /// a point narrower, the strip grew by that point, the chip fitted again,
    /// and round it went - 37pt, 38pt, 37pt - until AppKit threw "more Layout
    /// Window passes than there are views in the window". It needed a strip
    /// within a point of one chip, which a crowded filter row at 1100 with the
    /// inspector open reached. What the two share does not move when the
    /// label does, so a count read from it cannot flip.
    static func settledTagCount(chipWidths: [CGFloat], spacing: CGFloat, stripWidth: CGFloat,
                                overflowShown: Bool, shownOverflowWidth: CGFloat,
                                reservedOverflowWidth: CGFloat) -> Int {
        let shared = overflowShown ? stripWidth + shownOverflowWidth + spacing : stripWidth
        return fittingTagCount(chipWidths: chipWidths, spacing: spacing, stripWidth: shared,
                               overflowWidth: reservedOverflowWidth, overflowShown: false)
    }

    /// The widest "+1" ... "+`tagCount`" draws in the overflow chip's own
    /// style, measured once per count and text scale.
    private func reservedOverflowWidth(tagCount: Int) -> CGFloat {
        let key = "\(tagCount)|\(ChromeTextScale.shared.scale)"
        if let cached = overflowWidthCache[key] { return cached }
        let probe = HelmButton(title: "+0", variant: .secondary, size: .small)
        var widest: CGFloat = 0
        for hidden in 1...max(1, tagCount) {
            probe.title = "+\(hidden)"
            widest = max(widest, probe.fittingSize.width)
        }
        overflowWidthCache[key] = widest
        return widest
    }

    /// Show the chips that fit the strip and put the rest behind "+N".
    /// Runs whenever the strip changes width and whenever the chips change.
    private func refitTagChips() {
        guard !tagsScroll.isHidden else { return }
        let chips = tagsStack.arrangedSubviews
        let widths = chips.map { $0.fittingSize.width }
        let count = Self.settledTagCount(chipWidths: widths, spacing: tagsStack.spacing,
                                         stripWidth: tagsScroll.contentView.bounds.width,
                                         overflowShown: !tagOverflowChip.isHidden,
                                         shownOverflowWidth: tagOverflowChip.fittingSize.width,
                                         reservedOverflowWidth: reservedOverflowWidth(tagCount: chips.count))
        guard count != visibleTagChipCount || chips.enumerated().contains(where: { $0.element.isHidden != ($0.offset >= count) })
        else { return }
        visibleTagChipCount = count
        for (index, chip) in chips.enumerated() { chip.isHidden = index >= count }
        refreshTagOverflowChip()
    }

    /// "+N", filled while any tag behind it is selected - so a filter the
    /// captain set is never hidden from them.
    private func refreshTagOverflowChip() {
        let hidden = hiddenTags
        tagOverflowChip.isHidden = hidden.isEmpty || tagsScroll.isHidden
        tagOverflowChip.title = "+\(hidden.count)"
        tagOverflowChip.variant = hidden.contains(where: selectedTags.contains) ? .primary : .secondary
        tagOverflowChip.setAccessibilityLabel("\(hidden.count) more tags")
    }

    /// The tags whose chips the row is not showing, in chip order.
    private var hiddenTags: [String] {
        tagsStack.arrangedSubviews.filter(\.isHidden).compactMap { $0.identifier?.rawValue }
    }

    @objc private func tagOverflowClicked(_ sender: NSButton) {
        makeTagOverflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + HelmMetrics.s1), in: sender)
    }

    /// "+N"'s menu: one item per hidden tag, ticked while it is selected.
    private func makeTagOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        for tag in hiddenTags {
            let item = NSMenuItem(title: tag, action: #selector(tagOverflowItemPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag
            item.state = selectedTags.contains(tag) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// A tag picked from "+N" toggles exactly as its chip would.
    @objc private func tagOverflowItemPicked(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String, let chip = tagButtons[tag] else { return }
        chip.state = chip.state == .on ? .off : .on
        tagChipClicked(chip)
    }

    /// Text filter (label/address/username/tags) plus the tag, Online and
    /// group filters, drawn as the host cards and the host table
    /// (`renderHostsTable`), with the built-in "Firstmate" entry always first
    /// and unaffected by any filter - it is a permanent fixture, not a saved
    /// host.
    func applyHostFilter(_ query: String) {
        let hosts = filteredHosts(query)
        renderHostsTable(hosts, query: query)
        renderHeroColumn()
        refreshHostCounts()
        refreshDetailPanel()
        refreshFindOrConnectButton()
        onDrillSubtitleChanged?()
    }

    func filteredHosts(_ query: String) -> [Host] {
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
            // X4: "all" narrows to hosts carrying every selected tag; "any",
            // the default, is how the chips have always matched.
            hosts = tagMatchAll
                ? hosts.filter { selectedTags.isSubset(of: Set($0.tags)) }
                : hosts.filter { !$0.tags.isEmpty && !selectedTags.isDisjoint(with: $0.tags) }
        }
        if onlineOnly {
            hosts = hosts.filter { liveSession?($0.id) != nil }
        }
        // UX6's group filter. `normalizedGroup` is the same trim-and-nil the
        // list's own group headers use, so "Ungrouped" here selects exactly
        // the rows that header collects.
        if let selectedGroup {
            hosts = selectedGroup == Self.ungroupedMarker
                ? hosts.filter { normalizedGroup($0) == nil }
                : hosts.filter { normalizedGroup($0) == selectedGroup }
        }
        return hosts
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Select the showing tab's record titled `title`, through its grid's or
    /// table's own selection path - what the tour lab's `select` verb drives.
    @discardableResult
    func debugSelectRecord(titled title: String) -> Bool {
        if let grid = visibleGrid(for: activeTab) { return grid.debugSelect(titled: title) }
        return table(for: activeTab).debugSelect(titled: title)
    }
    var debugHostsTable: HelmDataTable { hostsTable }
    var debugKeysTable: HelmDataTable { keysTable }
    var debugSnippetsTable: HelmDataTable { snippetsTable }
    var debugInspectorDetail: WorkspaceDetailView { inspectorDetail }
    var debugExpansionStrip: SnippetExpansionPanel { expansionStrip }
    var debugOnlineFilter: HelmSegmentedTabs { onlineFilter }
    var debugKeysTouchID: HelmStatusPill { keysTouchID }
    var debugSearchField: NSView { searchField }
    var debugSearchPlaceholder: String { searchField.placeholderText }
    var debugFindOrConnectButton: HelmButton { findOrConnectButton }
    /// Type into the find-or-connect field as the captain would: the text,
    /// then the field's own change callback.
    func debugTypeInSearch(_ text: String) {
        searchField.stringValue = text
        searchField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    var debugFilterRow: NSStackView? { hostsFilterRow }
    var debugTabView: NSView {
        switch activeTab {
        case .hosts: return hostsTabView
        case .keys: return keysTabView
        case .snippets: return snippetsTabView
        }
    }
    #endif

    func normalizedGroup(_ host: Host) -> String? {
        let g = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return g.isEmpty ? nil : g
    }

    /// A host's kicker: what kind of box this is, in the captain's own words.
    /// The prototype's Hosts page reads LOCAL / PREPROD / PROD / CI rather
    /// than "SSH" four times, and this app already stores exactly that - a
    /// host's first tag, or its group when it has no tags. Falls back to
    /// "SSH" for a host with neither.
    ///
    /// The view that draws it styles it, so this returns the captain's own
    /// casing untouched.
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

    private func reloadKeysAndCounts() {
        reloadKeys()
        moduleTabCountsMayHaveChanged()
    }

    private func reloadSnippetsAndCounts() {
        reloadSnippets()
        moduleTabCountsMayHaveChanged()
    }

    private func reloadKeys() {
        renderKeysTable()
        renderHeroColumn()
        refreshDetailPanel()
        onDrillSubtitleChanged?()
    }

    // MARK: Snippets data

    private func reloadSnippets() {
        renderSnippetsTable()
        renderHeroColumn()
        refreshExpansionPanel()
        refreshDetailPanel()
        onDrillSubtitleChanged?()
    }

    // MARK: Host actions

    func connect(_ host: Host) {
        onConnect?(host.id, host.label, host.sshArguments(allHosts: hostStore.hosts),
                   host.accentHex, host.keyID, host.startupSnippetID)
    }

    func duplicate(_ host: Host) {
        var copy = host
        copy.id = UUID()
        copy.label = host.label + " copy"
        // A copy has never been connected to (X2).
        copy.lastConnectedAt = nil
        hostStore.add(copy)
    }

    /// ⌘N / the toolbar's Add Host: add a new host.
    @objc func newHost() {
        select(tab: .hosts)
        // UX-26: a new host is a 560pt sheet over the page, with room for
        // its fields. The inspector stays for reading a host.
        presentHostSheet(for: nil)
    }

    /// The Hosts menu's Quick Connect: focus the quick-connect field.
    @objc func focusQuickConnect() {
        select(tab: .hosts)
        searchField.focusEditor()
    }

    /// What the quick-connect field would connect to.
    enum QuickConnectTarget {
        case saved(Host)
        case adHoc(label: String, args: [String])

        var name: String {
            switch self {
            case .saved(let host): return host.label
            case .adHoc(let label, _): return label
            }
        }
    }

    /// The field's text resolved the way Return always has: an exact label
    /// match wins, then a single filtered result, then an ad-hoc
    /// `[user@]host[:port]`.
    ///
    /// `explicitAddressOnly` is H3's Connect button. It lights up on a single
    /// match or a typed `user@host` (or `ssh ...`), not on any word at all -
    /// Return still connects a bare word as a hostname, exactly as before,
    /// but a lit button beside a half-typed search would read as "this is a
    /// host".
    func quickConnectTarget(for text: String, explicitAddressOnly: Bool = false) -> QuickConnectTarget? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let exact = hostStore.hosts.first(where: { $0.label.caseInsensitiveCompare(raw) == .orderedSame }) {
            return .saved(exact)
        }
        let visible = filteredHosts(raw)
        if visible.count == 1 { return .saved(visible[0]) }
        if explicitAddressOnly, !raw.contains("@"), !raw.lowercased().hasPrefix("ssh ") { return nil }
        if let parsed = HostCatalog.parseQuickConnect(raw) { return .adHoc(label: parsed.label, args: parsed.args) }
        return nil
    }

    /// Return in the quick-connect field (and H3's Connect button): match a
    /// saved host, else parse an ad-hoc `[user@]host[:port]`.
    private func quickConnectFromField() {
        switch quickConnectTarget(for: searchField.stringValue) {
        case .saved(let host)?:
            connect(host)
        case .adHoc(let label, let args)?:
            onConnect?(nil, label, args, nil, nil, nil)
            searchField.stringValue = ""
            applyHostFilter("")
        case nil:
            NSSound.beep()
        }
    }

    @objc private func findOrConnectClicked() { quickConnectFromField() }

    /// H3: the Connect button beside the field lights up when the text names
    /// one host to connect to, and says which.
    /// The width H3's Connect button takes in the filter row while it
    /// shows, with its spacing - what the row's floor loses beside the hero
    /// column, which hides it.
    var findOrConnectRoom: CGFloat {
        findOrConnectButton.isHidden ? 0 : ceil(findOrConnectButton.fittingSize.width) + HelmMetrics.s3
    }

    func refreshFindOrConnectButton() {
        // C-4: while the hero column shows, its Quick connect is where a
        // typed user@host goes; Return in this field still connects.
        findOrConnectButton.isHidden = heroColumnWanted
        let target = quickConnectTarget(for: searchField.stringValue, explicitAddressOnly: true)
        findOrConnectButton.isEnabled = target != nil
        let words = target.map { "Connect to \($0.name)" } ?? "Type a host's name, or ssh user@hostname, to connect"
        findOrConnectButton.toolTip = words
        findOrConnectButton.setAccessibilityLabel(target.map { "Connect to \($0.name)" } ?? "Connect")
    }

    func confirmDeleteHost(_ host: Host) {
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

    /// ⌘⇧N / the toolbar's New Key.
    @objc func newKey() {
        openNewKey(preset: nil)
    }

    /// K2: New Key, opened in the mode one of its menu items names.
    func openNewKey(preset: KeyEditorController.Preset?) {
        select(tab: .keys)
        presentKeyEditor(for: nil, preset: preset)
    }

    /// The key the Keys tab has selected, if any.
    var selectedSSHKey: SSHKey? {
        guard let key = keysTable.selectedKey, let id = UUID(uuidString: key) else { return nil }
        return keyStore.key(id: id)
    }

    func presentKeyEditor(for key: SSHKey?, preset: KeyEditorController.Preset? = nil) {
        // UX-26: a new key is made in a sheet over the page. Editing a key
        // keeps K7's form in the side panel, which reads its details.
        if let key { openKeyPanel(forEditing: key, preset: preset) } else { presentKeySheet(preset: preset) }
    }

    /// Create mode: `SSHKeyStore.addNew` writes the Keychain secrets before
    /// adding the metadata.
    func persistNewKey(_ key: SSHKey, privateKeyData: Data, passphrase: String?) {
        #if FM_SELFTESTS
        // A suite never writes a Keychain item, even a scratch-prefixed one.
        if let writer = Self.newKeyWriterForTests {
            writer(key, privateKeyData, passphrase)
            keyStore.add(key)
            return
        }
        #endif
        do {
            try keyStore.addNew(key, privateKeyData: privateKeyData, passphrase: passphrase)
            Toast.show(in: view, message: "\u{201C}\(key.label)\u{201D} saved")
        } catch {
            presentError(error, context: "Couldn't save \"\(key.label)\" to the Keychain")
        }
    }

    /// Edit mode never touches the private key; a new passphrase (when typed)
    /// overwrites the existing Keychain entry for it.
    func persistUpdatedKey(_ key: SSHKey, newPassphrase: String?) {
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

    func confirmDeleteKey(_ key: SSHKey) {
        guard confirm(message: "Delete \u{201C}\(key.label)\u{201D}?",
                      detail: "This removes the key's Keychain entry (private key and passphrase). "
                            + "Any host still referencing it will fall back to the system ssh agent.")
        else { return }
        keyStore.delete(id: key.id)
    }

    // MARK: Snippet actions

    /// ⌘⌥N / the toolbar's New Snippet.
    @objc func newSnippet() {
        select(tab: .snippets)
        presentSnippetEditor(for: nil)
    }

    func presentSnippetEditor(for snippet: Snippet?) {
        let editor = SnippetEditorController(snippet: snippet,
                                             existingSnippets: snippetStore.snippets)
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

    func confirmDeleteSnippet(_ snippet: Snippet) {
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

    #if FM_SELFTESTS
    /// Whether the tag strip has left the filter row's layout.
    ///
    /// The vacuity guard for `checkTheListSurvivesUntaggedHosts`: that
    /// case only exercises the collapse it exists for while this is `true`, so
    /// a fixture that drifts back to tagged hosts has to fail loudly rather
    /// than pass while testing nothing.
    var debugTagStripIsHidden: Bool { tagsScroll.isHidden }
    /// The tag chips, in strip order - PERF-05's identity check.
    var debugTagChips: [NSView] { tagsStack.arrangedSubviews }
    var debugAddHostSplit: HelmSplitButton { addHostSplit }
    var debugAddKeySplit: HelmSplitButton { addKeySplit }
    /// The last key editor this page built, and a switch that builds it
    /// without presenting it, so a suite can read what a menu item opened.
    var lastKeyEditorForTests: KeyEditorController?
    static var suppressesKeyEditorPresentationForTests = false
    /// Stands in for the Keychain write a new key's save makes.
    static var newKeyWriterForTests: ((SSHKey, Data, String?) -> Void)?
    /// X4 and H9's controls, as the filter row holds them.
    var debugTagMatchControl: HelmSegmentedTabs { tagMatchControl }
    var debugTagOverflowChip: HelmButton { tagOverflowChip }
    var debugTagStripWidth: CGFloat { tagsScroll.contentView.bounds.width }
    /// The tag chips the row shows, by tag, in strip order.
    var debugVisibleTags: [String] {
        tagsStack.arrangedSubviews.filter { !$0.isHidden }.compactMap { $0.identifier?.rawValue }
    }
    var debugHiddenTags: [String] { hiddenTags }
    func debugTagChip(_ tag: String) -> HelmButton? { tagButtons[tag] }
    /// The overflow menu's own item for `tag`, fired through its target and
    /// action - what picking it from "+N" does.
    @discardableResult
    func debugPickOverflowTag(_ tag: String) -> Bool {
        guard let item = makeTagOverflowMenu().items.first(where: { $0.title == tag }),
              let action = item.action, let target = item.target as? NSObject else { return false }
        target.perform(action, with: item)
        return true
    }
    var debugOverflowMenuTitles: [String] { makeTagOverflowMenu().items.map(\.title) }
    /// The labels of the hosts the filters leave, in store order.
    func debugFilteredHostLabels() -> [String] { filteredHosts(searchField.stringValue).map(\.label) }
    #endif
}

func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - Connections' tabs in the toolbar

extension HostsController: ModuleTabHosting {
    var moduleTabNames: [String] { ["Hosts", "Keys", "Snippets"] }

    var selectedModuleTabName: String {
        switch activeTab {
        case .hosts: return "Hosts"
        case .keys: return "Keys"
        case .snippets: return "Snippets"
        }
    }

    func selectModuleTab(named name: String) {
        switch name {
        case "Keys": select(tab: .keys)
        case "Snippets": select(tab: .snippets)
        default: select(tab: .hosts)
        }
    }

    /// The prototype's "Hosts 7": the saved records each tab lists, read
    /// from the stores the tables render. The built-in Firstmate row is not a
    /// saved host, so it is not counted.
    ///
    /// A `hosts.json` that could not be read has no count: the tab shows none
    /// rather than "Hosts 0" (GL-14), the way the toolbar omits any missing key.
    var moduleTabCounts: [String: Int] {
        var counts = ["Keys": keyStore.keys.count, "Snippets": snippetStore.snippets.count]
        if hostStore.loadStatus == .clean { counts["Hosts"] = hostStore.hosts.count }
        return counts
    }

    /// A store changed under one of the three counts; the toolbar re-reads
    /// them.
    fileprivate func moduleTabCountsMayHaveChanged() {
        onModuleTabChanged?()
    }

    /// Nothing to put away: the page draws no tab control of its own, so the
    /// toolbar's tabs are its only ones. The split's pane holds the hero
    /// column (C-4, `refreshSplitColumn`).
    func setModuleTabControlHidden(_ hidden: Bool) {
        _ = hidden
    }

    /// With the hero column put away the content starts at the page gutter,
    /// like every other page's; beside the column it is the board's 20pt past
    /// it.
    func refreshContentLeading() {
        let collapsed = splitPage.map(\.isSidebarCollapsed) ?? true
        contentLeading?.constant = collapsed ? HelmMetrics.pageGutter : HelmMetrics.s5 - HelmSplitPage.dividerThickness
    }
}

// MARK: - The presentation

// Connections' Hosts, Keys and Snippets are the prototype's tables (and, for
// Hosts and Keys, cards), and the selected row's details are in the shell's
// inspector (`WorkspaceInspectorSource`).
//
// Stage 6 laid the page out as the prototype draws it, at the captain's
// request ("the button to add host is not in proper position and the UI is
// messed up"):
//
//   - the tab's primary action is one button at the toolbar's far right,
//     after Search (`WorkspacePrimaryActionProviding`),
//   - the toolbar's tabs carry the counts (`moduleTabCounts`), and the Hosts
//     tab's All / Online segments carry its live-session count,
//   - Hosts opens on one filter row - the search, All / Online, the group
//     and tag filters - directly under the toolbar, and Snippets on the
//     expansion switch's plain row,
//   - each table is one card that ends under its last row,
//   - there is no stat strip and no shortcut footer. Touch ID's state is in
//     the Keys row, and every shortcut is a menu item (Hosts menu, ⌘K) with
//     its chord beside it.
//
// **One set of actions.** Every table row, card and inspector button runs the
// same method - `connect`, `duplicate`, `confirmDeleteHost`,
// `presentKeyEditor` and the rest - so no two of them can drift apart in what
// a host, a key or a snippet can do.

extension HostsController: WorkspaceInspectorSource, WorkspacePrimaryActionProviding {

    func buildSidebarPresentation() {
        rebuildTagChips()
        // Each table card spans its tab view and ends under its last row; the
        // `<=` caps it at the page's foot, where its rows scroll instead. Its
        // top is the row over it: the filter row on Hosts, the Keys row
        // (`adoptKeysGrid`), and the expansion switch on Snippets.
        for (table, container) in [(hostsTable, hostsTabView), (keysTable, keysTabView),
                                   (snippetsTable, snippetsTabView)] {
            table.card.translatesAutoresizingMaskIntoConstraints = false
            table.hugsRows = true
            container.addSubview(table.card)
            NSLayoutConstraint.activate([
                table.card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                table.card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                table.card.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            ])
            table.onSelect = { [weak self] _ in self?.refreshDetailPanel() }
        }
        snippetsTabView.addSubview(expansionStrip)
        NSLayoutConstraint.activate([
            hostsTable.card.topAnchor.constraint(equalTo: hostsFilterRow.bottomAnchor, constant: HelmMetrics.s3),
            expansionStrip.leadingAnchor.constraint(equalTo: snippetsTabView.leadingAnchor),
            expansionStrip.trailingAnchor.constraint(equalTo: snippetsTabView.trailingAnchor),
            expansionStrip.topAnchor.constraint(equalTo: snippetsTabView.topAnchor),
            snippetsTableUnderStrip,
        ])
        hostsTable.accessibilityName = "Hosts"
        adoptHostsGrid()
        adoptKeysGrid()
        adoptHeroColumn()
        keysTable.accessibilityName = "SSH keys"
        snippetsTable.accessibilityName = "Snippets"
        // The prototype's Keys card names what it holds and where it is kept.
        let keysSubtitle = NSTextField(labelWithString: "Private keys and passphrases stay in the macOS Keychain, gated by Touch ID")
        keysSubtitle.lineBreakMode = .byTruncatingTail
        keysSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keysTable.card.setHeader(symbol: "key.fill", tint: .violet,
                                 titleLabel: NSTextField(labelWithString: "SSH keys"),
                                 subtitleLabel: keysSubtitle)
        let snippetsSubtitle = NSTextField(labelWithString: "Run sends a snippet's command, then Enter, to the active terminal tab")
        snippetsSubtitle.lineBreakMode = .byTruncatingTail
        snippetsSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snippetsTable.card.setHeader(symbol: "chevron.left.forwardslash.chevron.right", tint: .info,
                                     titleLabel: NSTextField(labelWithString: "Snippets"),
                                     subtitleLabel: snippetsSubtitle)
        expansionStrip.onToggle = { [weak self] isOn in
            self?.onSnippetExpansionToggled?(isOn)
            self?.refreshExpansionPanel()
        }
        expansionStrip.onRequestPermission = { [weak self] in
            self?.onRequestAccessibilityTrust?()
            self?.refreshExpansionPanel()
        }
        applyTheme(ThemeManager.shared.theme)
        applyHostFilter(searchField.stringValue)
        renderKeysTable()
        renderSnippetsTable()
        refreshExpansionPanel()
        refreshDetailPanel()
        refreshKeysTouchID()
        // The primary action moves to the toolbar's far right.
        onDrillActionsChanged?()
    }

    @objc private func tagStripResized() { refitTagChips() }

    /// The prototype's search field width, and the least it is squeezed to.
    /// H3 widened it from 400, for the longer find-or-connect words.
    static let sidebarSearchWidth: CGFloat = 460
    static let findOrConnectPlaceholder = "Find a host or ssh user@hostname"
    static let sidebarSearchMinimumWidth: CGFloat = 200

    /// "All 7" and "Online 5" (`refreshHostCounts`).
    fileprivate func refreshSidebarFilterCounts(all: Int, online: Int) {
        onlineFilter.setTitle("All\u{2002}\(all)", forID: Self.allFilterID)
        onlineFilter.setTitle("Online\u{2002}\(online)", forID: Self.onlineFilterID)
    }

    /// The Keys row's Touch ID reading, from the `LAContext` probe. A dot and
    /// a word while it is ready, which is the default; a capsule when it is
    /// not.
    fileprivate func refreshKeysTouchID() {
        let available = CredentialVaultKeyStore.biometryAvailable
        keysTouchID.style = available ? .dotWord : .pill
        keysTouchID.configure(text: Self.biometryPhrase(available, capitalized: true),
                              tint: available ? .good : .warn)
    }

    /// The one wording for "can this Mac use Touch ID", read by both places
    /// that state it: the Keys row here, and the key form's facts
    /// (`KeyEditorController`).
    ///
    /// **Review #3's UI1.** The page once said it twice, in two vocabularies
    /// ("Touch ID enabled" beside "Touch ID ready"), from the same
    /// `CredentialVaultKeyStore.biometryAvailable` probe. Two phrasings of one
    /// fact invite the reading that they are two different facts, so one
    /// function owns the words.
    static func biometryPhrase(_ available: Bool, capitalized: Bool = false) -> String {
        let phrase = available ? "Touch ID ready" : "no biometry on this Mac"
        guard capitalized else { return phrase }
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    /// The showing tab's add action, at the toolbar's far right: H8's and
    /// K2's split buttons for Hosts and Keys.
    var workspacePrimaryAction: NSView? {
        switch activeTab {
        case .hosts: return addHostSplit
        case .keys: return addKeySplit
        case .snippets: return addSnippetButton
        }
    }

    var inspectorContent: WorkspaceInspectorContent? {
        guard let inspectorTitle else { return nil }
        // H6: a saved host, or a new one, is its form in the panel.
        if activeTab == .hosts, let panel = importPanel {
            return WorkspaceInspectorContent(title: inspectorTitle, view: panel.view, fillsPane: true)
        }
        if activeTab == .hosts, let panel = hostPanel {
            return WorkspaceInspectorContent(title: inspectorTitle, view: panel.view, fillsPane: true)
        }
        // K7: a key, or a new one, is its form in the panel.
        if activeTab == .keys, let panel = keyPanel {
            return WorkspaceInspectorContent(title: inspectorTitle, view: panel.view, fillsPane: true)
        }
        return WorkspaceInspectorContent(title: inspectorTitle, view: inspectorDetail)
    }

    var inspectorEmptyText: (title: String, body: String) {
        switch activeTab {
        case .hosts: return ("No host selected", "Select a host to see how it connects, and everything you can do with it.")
        case .keys: return ("No key selected", "Select a key to see its fingerprint and which hosts use it.")
        case .snippets: return ("No snippet selected", "Select a snippet to see its command, its trigger and where it expands.")
        }
    }

    // MARK: Tables

    func table(for tab: HostsTab) -> HelmDataTable {
        switch tab {
        case .hosts: return hostsTable
        case .keys: return keysTable
        case .snippets: return snippetsTable
        }
    }

    static let firstmateRowKey = "firstmate"

    private static func makeHostsTable() -> HelmDataTable {
        HelmDataTable(columns: [
            .init(id: "host", title: "Host", width: 200),
            .init(id: "address", title: "Address", width: 180, minWidth: 150, flexible: true),
            .init(id: "group", title: "Group", width: 120, hiddenBelow: 720),
            .init(id: "tags", title: "Tags", width: 170, hiddenBelow: 960),
            .init(id: "session", title: "Session", width: 150, hiddenBelow: 640),
            .init(id: "lastConnected", title: "Last connected", width: 140, hiddenBelow: 1100),
        ], actionsWidth: 140)
    }

    private static func makeKeysTable() -> HelmDataTable {
        HelmDataTable(columns: [
            .init(id: "key", title: "Key", width: 200),
            .init(id: "type", title: "Type", width: 100, hiddenBelow: 640),
            .init(id: "fingerprint", title: "Fingerprint", width: 260, minWidth: 150, flexible: true),
            .init(id: "usedBy", title: "Used by", width: 100, hiddenBelow: 720),
            .init(id: "passphrase", title: "Passphrase", width: 120, hiddenBelow: 840),
        ], actionsWidth: 120)
    }

    private static func makeSnippetsTable() -> HelmDataTable {
        HelmDataTable(columns: [
            .init(id: "snippet", title: "Snippet", width: 200),
            .init(id: "command", title: "Command", width: 260, minWidth: 150, flexible: true),
            .init(id: "trigger", title: "Trigger", width: 120, hiddenBelow: 660),
            .init(id: "where", title: "Expands in", width: 130, hiddenBelow: 780),
        ], actionsWidth: 120)
    }

    /// The hosts the filters leave, under the built-in Firstmate row, with a
    /// header per group. Group headers are skipped entirely when every
    /// visible host shares one group (the "I haven't set up groups yet" case),
    /// so a flat host list never gains visual noise.
    private func renderHostsTable(_ hosts: [Host], query: String) {
        var rows: [HelmDataTable.Row] = [firstmateRow()]
        let groupKeys = Set(hosts.map { normalizedGroup($0) })
        if groupKeys.count <= 1 {
            rows += hosts.map(hostRow)
        } else {
            for name in groupKeys.compactMap({ $0 }).sorted() {
                rows.append(.group(name))
                rows += hosts.filter { normalizedGroup($0) == name }.map(hostRow)
            }
            let ungrouped = hosts.filter { normalizedGroup($0) == nil }
            if !ungrouped.isEmpty {
                rows.append(.group("Ungrouped"))
                rows += ungrouped.map(hostRow)
            }
        }
        if hosts.isEmpty {
            let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedTags.isEmpty || onlineOnly || selectedGroup != nil
            rows.append(.empty(
                symbol: filtering ? "line.3.horizontal.decrease.circle" : "server.rack",
                title: filtering ? "No matching hosts" : "No saved hosts yet",
                body: filtering
                    ? "Nothing matches the current search or filters. Clear them to see every saved host."
                    : "Save a host's connection details, or type ssh user@host in the field above to connect right now.",
                action: filtering ? nil : .init(title: "Add Host", symbol: "plus") { [weak self] in self?.newHost() }))
        }
        hostsTable.setRows(rows)
        renderHostsGrid(hosts, query: query)
    }

    private func firstmateRow() -> HelmDataTable.Row {
        var row = HelmDataTable.Row.record(Self.firstmateRowKey)
        row.cells = [
            "host": .title("Firstmate", subtitle: nil, subtitleIsCode: false, symbol: "sailboat", tint: .accent, tintHex: nil),
            "address": .muted("Built-in shell"),
            "group": .none,
            "tags": .tags([]),
            "session": .none,
        ]
        row.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.onConnectPinned?() }
        row.activate = { [weak self] in self?.onConnectPinned?() }
        return row
    }

    private func hostRow(_ host: Host) -> HelmDataTable.Row {
        var row = HelmDataTable.Row.record(host.id.uuidString)
        let session = liveSession?(host.id)
        row.cells = [
            "host": .title(host.label, subtitle: nil, subtitleIsCode: false, symbol: host.iconSymbol,
                           tint: .accent, tintHex: host.accentHex),
            "address": .code(host.subtitle),
            "group": normalizedGroup(host).map { .text($0) } ?? .none,
            "tags": .tags(host.tags),
            "session": session.map { .status($0.stateText, tint: $0.isConnected ? .good : .warn) } ?? .none,
            // X2.
            "lastConnected": host.lastConnectedAt.map { .muted(Self.lastConnectedText($0)) } ?? .none,
        ]
        if session != nil {
            row.primary = .init(title: "Switch", symbol: "arrow.right.circle.fill") { [weak self] in
                self?.onSwitchToSession?(host.id)
            }
            row.activate = { [weak self] in self?.onSwitchToSession?(host.id) }
        } else {
            row.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) }
            row.activate = { [weak self] in self?.connect(host) }
        }
        row.menu = hostMenuActions(host, live: session != nil).map { action in
            HelmDataTable.Action(title: action.title, symbol: action.symbol, run: action.run)
        }
        return row
    }

    /// The host's actions after its headline one - the same list the row's
    /// menu, its ⋯ button and the inspector show.
    func hostMenuActions(_ host: Host, live: Bool) -> [WorkspaceDetail.Action] {
        var actions: [WorkspaceDetail.Action] = []
        if live {
            actions.append(.init("End Session", symbol: "xmark.circle") { [weak self] in self?.onEndSession?(host.id) })
        }
        actions += [
            .init("Edit\u{2026}", symbol: "pencil") { [weak self] in self?.editHost(host) },
            .init("Duplicate\u{2026}", symbol: "plus.square.on.square") { [weak self] in self?.duplicate(host) },
            .init("Delete\u{2026}", symbol: "trash", role: .destructive) { [weak self] in self?.confirmDeleteHost(host) },
        ]
        return actions
    }

    /// K3: the search changed - re-render both key views.
    func reloadKeysForSearch() { renderKeysTable() }

    private func renderKeysTable() {
        let keys = filteredKeys(keySearchField.stringValue)
        var rows = keys.map { key -> HelmDataTable.Row in
            var row = HelmDataTable.Row.record(key.id.uuidString)
            let usedBy = hostStore.hosts.filter { $0.keyID == key.id }.count
            row.cells = [
                "key": .title(key.label, subtitle: nil, subtitleIsCode: false, symbol: "key.fill",
                              tint: key.type.tint, tintHex: nil),
                "type": .text(key.type.displayName),
                "fingerprint": .code(key.fingerprint),
                "usedBy": .muted(usedBy == 1 ? "1 host" : "\(usedBy) hosts"),
                "passphrase": key.hasPassphrase ? .status("In Keychain", tint: .good) : .muted("None"),
            ]
            row.primary = .init(title: "Edit", symbol: "pencil") { [weak self] in self?.presentKeyEditor(for: key) }
            row.activate = { [weak self] in self?.presentKeyEditor(for: key) }
            row.menu = [
                .init(title: "Copy Public Key", symbol: "doc.on.doc") { copyToPasteboard(key.publicKey) },
                .init(title: "Delete\u{2026}", symbol: "trash") { [weak self] in self?.confirmDeleteKey(key) },
            ]
            return row
        }
        if rows.isEmpty, !keyStore.keys.isEmpty {
            rows = [.empty(symbol: "line.3.horizontal.decrease.circle", title: "No matching keys",
                           body: "Nothing matches the search. Clear it to see every saved key.")]
        } else if rows.isEmpty {
            rows = [.empty(symbol: "key.fill", title: "No saved keys yet",
                           body: "Generate a key, or import an existing PEM or OpenSSH one. Private key material stays in the macOS Keychain.",
                           action: .init(title: "New Key", symbol: "plus") { [weak self] in self?.newKey() })]
        }
        keysTable.setRows(rows)
        renderKeysGrid(keys)
    }

    private func renderSnippetsTable() {
        var rows = snippetStore.snippets.map { snippet -> HelmDataTable.Row in
            var row = HelmDataTable.Row.record(snippet.id.uuidString)
            row.cells = [
                "snippet": .title(snippet.label, subtitle: nil, subtitleIsCode: false,
                                  symbol: "chevron.left.forwardslash.chevron.right", tint: .info, tintHex: nil),
                "command": .code(snippet.subtitle),
                "trigger": snippet.triggerDisplay.map { .code($0) } ?? .none,
                // GL-14: a Console-only snippet must not read like an armed one.
                "where": snippet.triggerDisplay == nil
                    ? .none
                    : (snippet.expandsSystemWide ? .status(snippet.scope.title, tint: .good) : .muted(snippet.scope.title)),
            ]
            row.primary = .init(title: "Run", symbol: "play.fill") { [weak self] in self?.onRunSnippet?(snippet) }
            row.activate = { [weak self] in self?.onRunSnippet?(snippet) }
            row.menu = [
                .init(title: "Edit\u{2026}", symbol: "pencil") { [weak self] in self?.presentSnippetEditor(for: snippet) },
                .init(title: "Copy Command", symbol: "doc.on.doc") { copyToPasteboard(snippet.command) },
                .init(title: "Delete\u{2026}", symbol: "trash") { [weak self] in self?.confirmDeleteSnippet(snippet) },
            ]
            return row
        }
        if rows.isEmpty {
            rows = [.empty(symbol: "chevron.left.forwardslash.chevron.right", title: "No snippets yet",
                           body: "Save a command you run often, then send it to any terminal tab in one click.",
                           action: .init(title: "New Snippet", symbol: "plus") { [weak self] in self?.newSnippet() })]
        }
        snippetsTable.setRows(rows)
    }

    // MARK: The inspector

    /// Fill the inspector from the showing table's selection, and tell the
    /// shell.
    private func refreshSidebarInspector() {
        if let title = activeTab == .hosts ? syncHostPanel() : activeTab == .keys ? syncKeyPanel() : nil {
            inspectorTitle = title
            onInspectorContentChanged?()
            return
        }
        let detail = currentWorkspaceDetail()
        if let detail { inspectorDetail.show(detail) }
        inspectorTitle = detail?.title
        onInspectorContentChanged?()
    }

    private func currentWorkspaceDetail() -> WorkspaceDetail? {
        guard let key = table(for: activeTab).selectedKey else { return nil }
        switch activeTab {
        case .hosts:
            if key == Self.firstmateRowKey { return firstmateDetail() }
            guard let id = UUID(uuidString: key), let host = hostStore.host(id: id) else { return nil }
            return workspaceDetail(for: host)
        case .keys:
            guard let id = UUID(uuidString: key), let sshKey = keyStore.key(id: id) else { return nil }
            return workspaceDetail(for: sshKey)
        case .snippets:
            guard let id = UUID(uuidString: key), let snippet = snippetStore.snippet(id: id) else { return nil }
            return workspaceDetail(for: snippet)
        }
    }

    private func firstmateDetail() -> WorkspaceDetail {
        WorkspaceDetail(symbol: "sailboat", tint: .accent, kicker: "Built-in", title: "Firstmate",
                        subtitle: "The shared Firstmate shell. It is always here, and it cannot be edited or deleted.",
                        fields: [.init("Kind", "Local shell")],
                        actions: [.init("Connect", symbol: "bolt.fill", role: .primary) { [weak self] in
                            self?.onConnectPinned?()
                        }])
    }

    /// Everything the saved `Host` holds, read straight off it - nothing here
    /// is derived or invented. A field with nothing in it is left out.
    private func workspaceDetail(for host: Host) -> WorkspaceDetail {
        var fields: [WorkspaceDetail.Field] = [
            .init("Environment", Self.roleKicker(for: host)),
            .init("Endpoint", host.port == 22 ? host.address : "\(host.address):\(host.port)", isCode: true),
            .init("User", host.username.isEmpty ? "Your local user" : host.username),
            .init("Credential", credentialName(for: host)),
        ]
        if host.agentForward { fields.append(.init("Agent", "Forwarded")) }
        if let jump = host.jumpVia?.trimmingCharacters(in: .whitespacesAndNewlines), !jump.isEmpty {
            fields.append(.init("Jump via", jump))
        }
        if let group = normalizedGroup(host) { fields.append(.init("Group", group)) }
        if !host.tags.isEmpty { fields.append(.init("Tags", host.tags.joined(separator: ", "))) }
        if let snippetID = host.startupSnippetID {
            fields.append(.init("On connect", snippetStore.snippet(id: snippetID)?.label ?? "Missing snippet"))
        }
        let session = liveSession?(host.id)
        if let session { fields.append(.init("Session", session.stateText)) }

        var actions: [WorkspaceDetail.Action] = []
        if session != nil {
            actions.append(.init("Switch to Session", symbol: "arrow.right.circle.fill", role: .primary) { [weak self] in
                self?.onSwitchToSession?(host.id)
            })
        } else {
            actions.append(.init("Connect", symbol: "bolt.fill", role: .primary) { [weak self] in self?.connect(host) })
        }
        actions += hostMenuActions(host, live: session != nil)

        return WorkspaceDetail(symbol: host.iconSymbol, tint: .accent, tintHex: host.accentHex,
                               kicker: Self.roleKicker(for: host), title: host.label, subtitle: host.subtitle,
                               fields: fields,
                               sections: [.init("Port forwarding", host.portForwards.map(\.summary), isCode: true)],
                               actions: actions)
    }

    private func workspaceDetail(for key: SSHKey) -> WorkspaceDetail {
        let users = hostStore.hosts.filter { $0.keyID == key.id }.map(\.label)
        var fields: [WorkspaceDetail.Field] = [
            .init("Type", key.type.displayName),
            .init("Fingerprint", key.fingerprint, isCode: true),
            .init("Passphrase", key.hasPassphrase ? "In Keychain" : "None"),
            .init("Used by", users.count == 1 ? "1 host" : "\(users.count) hosts"),
        ]
        if key.certificate?.isEmpty == false { fields.append(.init("Certificate", "Present")) }
        return WorkspaceDetail(
            symbol: "key.fill", tint: key.type.tint, kicker: key.type.displayName, title: key.label,
            subtitle: "Private key material stays in the macOS Keychain.",
            fields: fields,
            sections: [.init("Hosts using it", users)],
            actions: [
                .init("Edit", symbol: "pencil", role: .primary) { [weak self] in self?.presentKeyEditor(for: key) },
                .init("Copy Public Key", symbol: "doc.on.doc") { copyToPasteboard(key.publicKey) },
                .init("Delete\u{2026}", symbol: "trash", role: .destructive) { [weak self] in self?.confirmDeleteKey(key) },
            ])
    }

    private func workspaceDetail(for snippet: Snippet) -> WorkspaceDetail {
        var fields: [WorkspaceDetail.Field] = [
            .init("Trigger", snippet.triggerDisplay ?? "None", isCode: snippet.triggerDisplay != nil),
        ]
        // F12: stated as separate readings, because they fail independently.
        if snippet.triggerDisplay != nil {
            fields.append(.init("Expands in", snippet.scope.title))
            if !snippet.excludedApps.isEmpty {
                fields.append(.init("Never in", snippet.excludedApps.joined(separator: ", ")))
            }
        }
        let lines = snippet.command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return WorkspaceDetail(
            symbol: "chevron.left.forwardslash.chevron.right", tint: .info,
            kicker: snippet.triggerDisplay ?? "Snippet", title: snippet.label,
            subtitle: snippet.expandsSystemWide
                ? "Expands wherever you type it, and runs in a terminal tab."
                : "Sent to the active terminal tab, then Enter.",
            fields: fields,
            sections: [.init("Command", lines, isCode: true)],
            actions: [
                .init("Run", symbol: "play.fill", role: .primary) { [weak self] in self?.onRunSnippet?(snippet) },
                .init("Edit\u{2026}", symbol: "pencil") { [weak self] in self?.presentSnippetEditor(for: snippet) },
                .init("Copy Command", symbol: "doc.on.doc") { copyToPasteboard(snippet.command) },
                .init("Delete\u{2026}", symbol: "trash", role: .destructive) { [weak self] in
                    self?.confirmDeleteSnippet(snippet)
                },
            ])
    }
}
