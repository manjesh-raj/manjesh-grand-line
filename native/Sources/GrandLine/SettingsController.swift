// Grand Line - native macOS app.
//
// The Settings page, rebuilt to the captain's own reference
// (`fm/grandline-settings-page-redesign`).
//
// He hand-built a complete, runnable HTML/CSS/JS mock of the page he wanted
// and asked for the real one to match it. It is a macOS System-Settings-shaped
// window, and four things about it are structural rather than cosmetic:
//
//   1. **A searchable, grouped sidebar.** Eight pages under three headings -
//      Personalize, Your day, System - with a live search field above them
//      and a persistent identity row. The page this replaces already had a
//      category column (`fm/grandline-settings-page-sidebar-redesign`), but
//      one flat, unsearchable list of eight.
//   2. **Back/forward history, with the page's title in a toolbar.** Settings
//      cross-references itself (the daily review's calendar row points at
//      Google Accounts), and a cross-reference you cannot come back from is a
//      dead end.
//   3. **Grouped cards of rows, not one card per topic.** A page is a hero
//      header then N sections; a section is a small heading above one group;
//      a group is hairline-separated rows of label-plus-control. That
//      vocabulary is `SettingsForm.swift`, and it is what makes sixty rows
//      read as one page instead of eight cards of loosely-related content.
//   4. **Dependent rows.** The reference's `data-dep`: a sub-row is indented,
//      and dimmed *and inert* while the switch it depends on is off.
//
// **Everything is wired to what this app really stores.** The reference's own
// data is illustrative - 26 named colours, five App Intents, an OAuth client
// ID, a backup inventory - and every one of those is read here from the real
// source instead: `HelmTheme.allThemes`, `GrandLineIntentCatalog.entries`,
// `GoogleOAuthClientStore`, the measured `BackupStoreSection` walk. Where the
// reference draws a control this app has no setting behind (a "Reduce
// transparency" switch, a per-intent enable toggle, a Spotlight switch), the
// control is **absent** rather than faked: a switch that changes nothing is
// worse than a missing one, and GL-14's spirit applies to controls as much as
// to numbers.
//
// The one place the reference asked for behaviour this app did not have is
// "Follow system appearance" and its light/dark pair, which is a real feature
// now - `SystemAppearanceFollower.swift`.

import AppKit

final class SettingsController: NSViewController, DaylightDrillActions {

    // MARK: - Structure

    /// The sidebar's three headings, in the reference's own order.
    ///
    /// The grouping is by *when* a captain comes here, which is why "Your
    /// day" holds Briefings and Google Accounts together: the only consumer
    /// of a connected Google account today is the daily review's calendar
    /// column, and a captain setting up their morning visits both.
    enum NavGroup: String, CaseIterable {
        case personalize
        case yourDay
        case system

        var title: String {
            switch self {
            case .personalize: return "Personalize"
            case .yourDay: return "Your day"
            case .system: return "System"
            }
        }
    }

    /// One page of the settings window.
    ///
    /// `allCases` order is the sidebar's reading order, and the groups run in
    /// `NavGroup.allCases` order - so the two can never disagree about where
    /// a page belongs, and adding one is a case here plus a `buildPage`
    /// branch.
    enum Category: String, CaseIterable {
        case appearance
        case terminal
        case capture
        case menuBar
        case briefings
        case gmail
        case intents
        case security
        case backup

        var navGroup: NavGroup {
            switch self {
            case .appearance, .terminal, .capture, .menuBar: return .personalize
            case .briefings, .gmail: return .yourDay
            case .intents, .security, .backup: return .system
            }
        }

        /// The sidebar row's label, the toolbar title, and the drill header's
        /// subtitle - one string, so they cannot drift.
        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .terminal: return "Terminal"
            case .capture: return "Capture"
            case .menuBar: return "Menu Bar"
            case .briefings: return "Briefings"
            case .gmail: return "Google Accounts"
            case .intents: return "App Intents & Shortcuts"
            case .security: return "Security"
            case .backup: return "Backup & Restore"
            }
        }

        /// The row's leading glyph and the hero's tile - the same symbol, so
        /// the nav row and the page it opens are visibly one thing.
        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .terminal: return "terminal"
            case .capture: return "square.and.pencil"
            case .menuBar: return "menubar.rectangle"
            case .briefings: return "sparkles"
            case .gmail: return "envelope"
            case .intents: return "sparkle"
            case .security: return "lock.shield"
            case .backup: return "tray.and.arrow.up.fill"
            }
        }

        /// The hue this page carries - the hero tile's, and (since
        /// `fm/grandline-settings-sidebar-differentiation-fix`) its sidebar
        /// row's tile too, so a row and the page it opens are one colour as
        /// well as one symbol.
        ///
        /// A `HelmTint`, never one of the reference's literal hexes - those
        /// are illustrative, and a hardcoded colour would be off-palette in
        /// twenty-five of the twenty-six themes.
        ///
        /// **Eight pages, seven tints, so hues repeat - and what matters is
        /// *where*.** A count of distinct colours is not the goal; a column
        /// you can scan is, and that only breaks when two rows the eye takes
        /// in together are the same colour. So every repeat is placed across
        /// a group boundary, with rows in between:
        ///
        ///   - `.violet` is Appearance (first row of Personalize) and
        ///     Security (second row of System), three rows and two headers
        ///     apart.
        ///   - `.accent` and `.info` are **the same hue in some palettes**
        ///     (measured: Dusk resolves both to `182/207/290`, its accent
        ///     being its own ANSI blue), so the two pages carrying them - Menu
        ///     Bar and App Intents - are likewise in different groups with
        ///     Briefings and Google Accounts between them. This is why
        ///     Terminal is not `.accent`: Terminal sits directly under Menu
        ///     Bar, and in Dusk the two tiles would have been identical.
        ///
        /// `checkEveryRowCarriesItsOwnColouredTile` asserts the placement
        /// rule (no two *adjacent* rows paint the same tile) rather than a
        /// distinct count, because the placement rule is the real
        /// requirement.
        ///
        /// A `HelmTint`, never one of the reference's literal hexes - those
        /// are illustrative, and a hardcoded colour would be off-palette in
        /// twenty-five of the twenty-six themes. The rest map onto the
        /// reference's own identity: Menu Bar blue, Briefings orange, Google
        /// Accounts red, Backup teal-green, Terminal slate.
        ///
        /// **`.terminal` is deliberately `.neutral`**, which AGENTS.md's
        /// colour rules otherwise warn off: washed as a tinted surface
        /// `.neutral` resolves to `chromeInkHex` and so lands a few percent
        /// off full ink rather than off the surface, which renders heavy.
        /// That warning is about `.neutral` as the *identity-less default* -
        /// the commonest chip on a page becoming its heaviest. Here it is one
        /// deliberate row of eight, drawing the reference's own dark slate
        /// Terminal tile, and `IconTileView` still corrects the glyph on it to
        /// the 3:1 icon floor.
        var tint: HelmTint {
            switch self {
            case .appearance: return .violet
            case .terminal: return .neutral
            // Between Terminal's slate and Menu Bar's blue, and not repeated
            // until Backup at the far end of the System group - the placement
            // rule `checkEveryRowCarriesItsOwnColouredTile` actually asserts.
            case .capture: return .good
            case .menuBar: return .info
            case .briefings: return .warn
            case .gmail: return .critical
            case .intents: return .accent
            case .security: return .violet
            case .backup: return .good
            }
        }

        /// The one sentence under the hero title.
        var heroDescription: String {
            switch self {
            case .appearance:
                return "\(HelmTheme.allThemes.count) instrument-panel palettes, each contrast-verified to WCAG AA. Picking one repaints the whole window."
            case .terminal:
                return "Where new tabs open, how their text looks, and the keys that move you between tabs and panes."
            case .capture:
                return "One chord, from any app, for anything you want to write down before it is gone. It files to tasks, notes, stickies, snippets or the vault."
            case .menuBar:
                return "Run Grand Line from the status item with no main window. Nothing gets turned off."
            case .briefings:
                return "Two cards at the top of Fleet: a generated morning summary, and a review of your own day assembled on this Mac."
            case .gmail:
                return "Connect work, personal, both or neither. Grand Line asks Google for read-only calendar access and your address, and for nothing else."
            case .intents:
                return "Actions Siri, Shortcuts, Spotlight and Raycast can run without bringing the window forward. Find them under \u{201C}Grand Line\u{201D}."
            case .security:
                return "Locking the app, the Poneglyph vault, and system-level conveniences."
            case .backup:
                return "Write everything Grand Line knows to one file, or merge one in from another Mac. A restore always previews and never deletes."
            }
        }

        /// Extra words the sidebar's search matches, beyond the title.
        ///
        /// The reference carries the same list, and it exists because a
        /// captain searches for the *setting* ("sudo", "font", "oauth"), not
        /// for the page that happens to hold it.
        var searchKeywords: String {
            switch self {
            case .appearance: return "theme dark light colour color palette font text size system pair"
            case .terminal: return "shell working directory font size shortcut split pane tab ssh reconnect notification bell"
            case .capture: return "capture quick capture hotkey shortcut global option space accessibility permission note task sticky"
            case .menuBar: return "compact dock status item hotkey shortcut overdue badge menubar"
            case .briefings: return "morning briefing daily review calendar eventkit claude summary"
            case .gmail: return "google gmail oauth calendar work personal account sign in client id secret"
            case .intents: return "siri spotlight raycast shortcuts automation app intents"
            case .security: return "touch id sudo pam lock vault poneglyph password credential"
            case .backup: return "export import restore glbackup archive move machine"
            }
        }

        /// The reference's `.page.wide`: the one page laid out in two columns.
        var isWide: Bool { self == .intents }

        /// How wide this page's content column is allowed to get - the
        /// reference's `max-width: 680px`, and `980px` for the wide one.
        ///
        /// A cap, not a width, and required is safe **because it is a
        /// maximum** (gotcha (17)'s footnote to gotcha (13)): a `<=` can
        /// never be a floor on how narrow the window may get, which a
        /// required `==` or `>=` at this width would be.
        var contentMaxWidth: CGFloat { isWide ? 980 : 680 }
    }

    /// One assembled page: what gets mounted, plus the pieces the controller
    /// has to reach afterwards (re-theme them, re-wrap their descriptions).
    private struct Page {
        let category: Category
        let container: NSView
        let hero: SettingsHero
        let sections: [SettingsSection]
        /// The wide page's two-column stack and the constraint that splits
        /// it, so the page can collapse to one column when it is too narrow
        /// to hold two. `nil` for every ordinary page.
        /// The wide page's two-column arrangement, as two complete sets of
        /// constraints - exactly one active at a time. Held rather than
        /// rebuilt on each change: a collapse that built constraints each
        /// time would leave the previous set active, and once the page
        /// widened again those stale ties would fight the new ones - a real
        /// conflict, and one that only appears after a resize back and forth.
        var sideBySide: [NSLayoutConstraint] = []
        var stacked: [NSLayoutConstraint] = []
        /// Whether the page is currently laid out side by side. `nil` for
        /// every ordinary page.
        var isSideBySide: Bool?
    }

    // MARK: - Injected dependencies

    /// The four stores Backup & Restore exports from / imports into
    /// (`BackupUI.swift`) - injected so this controller needs no persistence
    /// logic of its own.
    private let hostStore: HostStore
    private let keyStore: SSHKeyStore
    private let snippetStore: SnippetStore
    private let dictationStore: DictationStore

    init(hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore) {
        self.hostStore = hostStore
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        self.dictationStore = dictationStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Wired by the app delegate to `ConsoleController.stepFontSize`, since
    /// this page never holds a direct reference to the console.
    var onFontSizeStep: ((CGFloat) -> Void)?

    /// The Security page's sudo actions, run through the same Console tab
    /// Bootstrap's provisioning uses - never a silent background process.
    var onRunCommand: ((String, String) -> Void)?
    /// Same, with a completion callback so the row can re-check status when
    /// the command actually exits rather than on a fixed timer.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    /// "A terminal binding changed, tell the live monitor." Forwarded rather
    /// than reached for: this page knows nothing about `TabKeyboardShortcuts`,
    /// and a recorder the captain just used takes effect on the next keypress
    /// rather than the next launch.
    var onTerminalShortcutsChanged: ((TerminalShortcutSet) -> Void)?

    /// "The capture chord changed, tell the live monitor and the menu."
    /// Forwarded for the same reason as the line above - this page owns no
    /// `ShiftGlobalHotkey`, and a chord the captain just recorded has to take
    /// effect on the next keypress rather than the next launch.
    var onQuickCaptureShortcutChanged: ((KeyChord) -> Void)?

    /// Set by `AppShellController` so a sign-in that connects a calendar can
    /// make the Overview page re-read it. Optional: this page works with
    /// nothing wired, which every self-test that mounts it relies on.
    var onGoogleAccountsChanged: (() -> Void)?

    /// What compact mode is wired to. `nil` in every self-test that mounts
    /// this page without an app delegate, and in that case the toggles still
    /// persist - they simply have nothing to tell.
    var onCompactModeSettingsChanged: (() -> Void)?

    /// Set by `AppShellController` - "re-read my subtitle". The drill header
    /// belongs to the shell; a page writing into it directly is how two
    /// owners of one view start disagreeing.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Lets a cross-reference row ("1 account" on the daily review) jump to
    /// another destination. `nil` in a suite.
    var onNavigate: ((RailDestination) -> Void)?

    // MARK: - Drill header (Daylight §6.4)

    /// Nothing. Every action on this page belongs to one row, and none of
    /// them is the *page's* primary action - hoisting one into the header
    /// would promote it over its siblings for no reason.
    var drillHeaderActions: [NSView] { [] }

    var drillHeaderSubtitle: String? {
        "\(selectedCategory.title) \u{00B7} everything here is stored locally on this machine"
    }

    // MARK: - State

    private var theme: HelmTheme = ThemeManager.shared.theme

    private var selectedCategory: Category = .appearance

    /// The reference's back/forward stack. `historyIndex` points at the
    /// current entry, so Back is `index > 0` and Forward is
    /// `index < history.count - 1` - exactly the disabled conditions the
    /// reference's own two buttons carry.
    private var history: [Category] = [.appearance]
    private var historyIndex = 0

    private var pages: [Category: Page] = [:]
    private var mountedCategory: Category?

    private var sudoTouchIDStatus: SudoTouchIDStatus = .checking
    private var isHardeningSudo = false
    private var isDisablingSudo = false
    private var hasCheckedSudoTouchIDOnce = false

    // MARK: - Chrome

    /// The nav column: a search field, an identity row, the grouped page list
    /// and a footer - the reference's sidebar, in that order.
    /// The toned band behind the nav column, and the hairline closing it.
    ///
    /// `fm/grandline-settings-sidebar-differentiation-fix`: the captain's
    /// report was that the column and the content read as "literally nothing,
    /// no proper blocks at all which differentiate". They did:
    /// `HelmPageSidebar` is `.plain` here, which paints no fill of its own, so
    /// both regions were the page ground and the boundary was whatever the
    /// rows' own left edges implied.
    ///
    /// **Why this is the page's view and not `HelmPageSidebar.Surface.panel`.**
    /// That case exists and would have been one word, but it paints the *nav
    /// list* as a card - and the region the reference tones is the whole
    /// column, the search field and the identity row above the list and the
    /// version footer below it included. A `.panel` sidebar would have drawn a
    /// card around the middle third of the band and left the rest on the page
    /// ground, which is a different (and worse) shape than the one being
    /// asked for. The band is the page's own composition, so the page owns it.
    private let sidebarPanel = NSView()
    private let sidebarEdge = NSView()
    private let sidebarColumn = NSStackView()
    private let searchField = HelmSearchField(placeholder: "Search settings")
    private let sidebar = HelmPageSidebar()
    private let identityName = NSTextField(labelWithString: "")
    private let identityCaption = NSTextField(labelWithString: "Grand Line on this Mac")
    private let identityAvatar = NSView()
    private let identityInitial = NSTextField(labelWithString: "")
    private let sidebarFooter = NSTextField(labelWithString: "")
    /// Shown in place of the rows when the search matches nothing, which is
    /// the reference's own empty state - a filter that silently empties a
    /// list reads as a broken list.
    private let noMatchLabel = NSTextField(wrappingLabelWithString: "")

    private let toolbar = NSStackView()
    private let backButton = HelmButton(symbol: "chevron.left", variant: .quiet, target: nil, action: nil)
    private let forwardButton = HelmButton(symbol: "chevron.right", variant: .quiet, target: nil, action: nil)
    private let toolbarTitle = NSTextField(labelWithString: "")
    private let toolbarLocalLabel = NSTextField(labelWithString: "Saved on this Mac")
    private let toolbarLocalIcon = NSImageView()

    /// The detail pane's own column, holding exactly the selected page.
    private let pageContainer = LayoutReportingStack()
    private var pageWidthCap: NSLayoutConstraint!
    /// The toolbar's own copy of `pageWidthCap`, so the page header and the
    /// content column it heads share one right edge at every window width and
    /// on every category. Updated in the same place, for the same reason.
    private var toolbarWidthCap: NSLayoutConstraint!
    private var scrollView: NSScrollView!

    /// The container width the page's wrapping labels were last laid out
    /// against, so a resize that did not move it costs a float compare
    /// (GL-20).
    private var lastPageWidth: CGFloat = 0

    // MARK: - Controls (built once, reparented never rebuilt)

    private let shellCwdField = HelmTextField(placeholder: "~ (Home)")

    private let followSystemSwitch = HelmToggle()
    private let systemLightPopUp = HelmPopUpButton()
    private let systemDarkPopUp = HelmPopUpButton()
    private var themeFilterTabs: HelmSegmentedTabs!
    /// Which half of the catalogue the grid shows - the reference's
    /// All / Dark / Light segmented control.
    private var themeFilter: ThemeFilter = .all
    private let appearanceContainer = LayoutReportingStack()

    private var fontPresetButtons: [Int: HelmButton] = [:]
    /// Keyed by index into `ChromeTextScale.steps` (GL-32).
    private var uiScaleButtons: [Int: HelmButton] = [:]
    private let autoReconnectSwitch = HelmToggle()
    private let notifySwitch = HelmToggle()

    private var shortcutRecorders: [TerminalShortcutAction: KeyChordRecorderView] = [:]
    private var captureShortcutRecorder: KeyChordRecorderView?
    private var resetCaptureShortcutButton: HelmButton?
    private var captureAccessibilityButton: HelmButton?
    private var captureAccessibilityStatus: NSTextField?

    /// How this page asks whether the capture hotkey's global half is armed.
    ///
    /// Injected rather than read directly so a suite can drive both answers
    /// without a real Accessibility grant - `AXIsProcessTrusted()` is a
    /// property of the *process*, and a headless runner's answer is whatever
    /// the machine happens to say. Defaults to the real call.
    var quickCaptureAccessibilityTrusted: (() -> Bool)?
    private var resetShortcutsButton: HelmButton?

    private let morningBriefingSwitch = HelmToggle()
    private let dailyReviewSwitch = HelmToggle()
    private let dailyReviewCalendarSwitch = HelmToggle()
    private let googleCalendarInReviewButton = HelmButton(title: "Google Accounts",
                                                          variant: .quiet, target: nil, action: nil)

    private let compactModeSwitch = HelmToggle()
    private let compactDockSwitch = HelmToggle()
    private let compactBadgeSwitch = HelmToggle()

    private var gmailRows: [GoogleAccountSlot: GmailAccountRow] = [:]
    /// Both masked by default with their own Show toggle, through the one
    /// `HelmRevealableSecretField` the credential editor's Secret row also
    /// uses. The client ID is not a secret the way the client secret is - it
    /// travels in the authorization URL - but it identifies the captain's own
    /// Google Cloud project, and a Settings page read over a shoulder should
    /// not put either on display by default.
    private let gmailClientIDField =
        HelmRevealableSecretField(placeholder: "1234-abcd.apps.googleusercontent.com")
    private let gmailClientSecretField =
        HelmRevealableSecretField(placeholder: "Client secret (optional)")
    private let gmailCalendarSwitch = HelmToggle()
    private var gmailStatusSection: SettingsSection?

    private let backupContentsStack = NSStackView()
    private var backupSummaryRow: SettingsRow?

    private let securityStackHost = NSStackView()
    private var sudoRowHost: SettingsRow?

    // MARK: - Dependent rows (the reference's `data-dep`)

    /// A dependency key, so a sub-row says which switch it follows rather
    /// than the switch having to hold a list of views.
    private enum Dependency: String {
        case followSystemAppearance
        case morningBriefing
        case dailyReview
        case compactMode
    }

    private var dependentRows: [Dependency: [SettingsRow]] = [:]

    private func register(_ row: SettingsRow, dependingOn key: Dependency) -> SettingsRow {
        dependentRows[key, default: []].append(row)
        return row
    }

    /// Push every switch's state into the rows that depend on it.
    ///
    /// One function rather than four, called from the toggles' own actions
    /// and from `refreshFromSettings` - so a dependency can never be right
    /// after a click and wrong after a relaunch.
    private func syncDependentRows() {
        let states: [Dependency: Bool] = [
            .followSystemAppearance: followSystemSwitch.isOn,
            .morningBriefing: morningBriefingSwitch.isOn,
            .dailyReview: dailyReviewSwitch.isOn,
            .compactMode: compactModeSwitch.isOn,
        ]
        for (key, rows) in dependentRows {
            let enabled = states[key] ?? true
            for row in rows { row.isRowEnabled = enabled }
        }
    }

    // MARK: - Theming registries

    private var mutedLabels: [NSTextField] = []
    private var themeCards: [SettingsThemeCard] = []

    @discardableResult
    private func muted(_ label: NSTextField) -> NSTextField {
        mutedLabels.append(label)
        label.textColor = HelmTheme.mutedInk(theme)
        return label
    }

    // MARK: - Load

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root
        // GL-24: a theme observer repaints - it never fetches.
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.repaintForTheme()
        }

        buildSidebarColumn()
        buildToolbar()

        pageContainer.orientation = .vertical
        pageContainer.alignment = .leading
        pageContainer.spacing = 0
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.onLayout = { [weak self] in self?.pageWidthMayHaveChanged() }

        for category in Category.allCases { pages[category] = buildPage(category) }

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pageContainer)
        // `leading ==` plus `trailing <=` plus a required width cap, never a
        // required `==` width tie (gotcha (3)): the cap is what stops a
        // 1500pt window rendering a 1400pt-wide settings row, and the
        // inequality is what stops the cap becoming the window's own frame.
        pageWidthCap = pageContainer.widthAnchor
            .constraint(lessThanOrEqualToConstant: selectedCategory.contentMaxWidth)
        NSLayoutConstraint.activate([
            pageContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                   constant: HelmMetrics.pageGutter),
            pageContainer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                                    constant: -HelmMetrics.pageGutter),
            pageContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: HelmMetrics.s2),
            pageContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -HelmMetrics.s6),
            pageWidthCap,
        ])
        // "And otherwise be as wide as you are allowed to be." Below
        // `NSLayoutPriorityWindowSizeStayPut` (500) so it can never widen the
        // window (gotcha (13)); above the stack's own content, so the column
        // fills the pane rather than shrink-wrapping onto its widest group.
        let widthGrow = pageContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                                constant: -HelmMetrics.pageGutter)
        widthGrow.priority = HelmDaylightPriority.contentTie
        widthGrow.isActive = true

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollView = scroll

        // Added first, so they sit under the column rather than over it.
        // Gotcha (11): both are bare `NSView()`s given manual constraints, so
        // both have to clear `translatesAutoresizingMaskIntoConstraints`
        // before those constraints go on - an omission here synthesises a
        // required 0x0 frame and fights the fills below.
        sidebarPanel.wantsLayer = true
        sidebarPanel.translatesAutoresizingMaskIntoConstraints = false
        sidebarEdge.wantsLayer = true
        sidebarEdge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarPanel)
        root.addSubview(sidebarEdge)
        root.addSubview(sidebarColumn)
        root.addSubview(toolbar)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            // The band runs the page's full height and from its very edge, so
            // it reads as a region of the window rather than as a card that
            // happens to be tall. Its trailing edge lands a `pageGutter` past
            // the column, which is exactly where the content's own cards and
            // toolbar begin (both are inset `pageGutter + width + s5`) - so
            // the divider sits on the content's visual left edge and the
            // column keeps symmetric 24pt padding inside the band.
            //
            // Nothing here is a width floor: every constraint ties to `root`
            // or to the column's own already-fixed width, so gotcha (13)'s
            // "a required content constraint over priority 500 resizes the
            // window" does not apply.
            sidebarPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarPanel.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarPanel.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor,
                                                   constant: HelmMetrics.pageGutter),
            sidebarEdge.leadingAnchor.constraint(equalTo: sidebarPanel.trailingAnchor),
            sidebarEdge.widthAnchor.constraint(equalToConstant: 1),
            sidebarEdge.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarEdge.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // **The nav column sits outside the scroll view**, so scrolling a
            // long page (Terminal is nine recorders) never carries the page
            // list off the top with it.
            sidebarColumn.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                   constant: HelmMetrics.pageGutter),
            sidebarColumn.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            // Required, not `<=`: the column has a footer, and
            // `HelmPageSidebar.setFooter` pins that footer to the column's own
            // bottom edge - which only reaches the page's bottom if the page
            // says so (see that method's own note).
            sidebarColumn.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                  constant: -HelmMetrics.pageGutter),
            sidebarColumn.widthAnchor.constraint(equalToConstant: HelmPageSidebar.width),

            // Measured from the page, not from the column's trailing edge.
            // `HelmPageSidebar`'s own width constraint sits at `contentTie`
            // (499) so it can never be a window-width floor, which means it
            // merely *ties* with another 499 constraint rather than beating
            // it - and this page's content column is capped, so at a wide
            // window there is real slack in the row. Chaining the two let
            // that slack widen the column instead (measured at 303pt against
            // the component's own 208, `fm/grandline-settings-page-sidebar-
            // redesign`). A constant leaves the column's width uncontested.
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                             constant: HelmMetrics.pageGutter + HelmPageSidebar.width
                                                 + HelmMetrics.s5 - HelmMetrics.pageGutter
                                                 + HelmMetrics.pageGutter),
            // **The toolbar ends where the content column ends, not where
            // the page does.** The toolbar is this page's header - the
            // breadcrumb on its left, "Saved on this Mac" on its right - and
            // the thing it heads is the capped content column below it, not
            // the window. Pinned to `root.trailingAnchor` it spanned the
            // whole page while the column stopped at its cap, so on a wide
            // window the trailing item sat hundreds of points right of
            // everything it labels: measured 1488 against the column's own
            // 936 at a 1512pt window, a 552pt overhang. The captain's
            // reference puts the two on one right edge, which is also what
            // System Settings itself does.
            //
            // The shape is deliberately the *same* one `pageContainer` uses a
            // few lines up, so the two edges cannot drift: a required `<=`
            // against the clip view, a required width cap that moves with the
            // category, and a `contentTie` (499) equality that takes up any
            // remaining slack. Gotcha (13) does not apply - both required
            // constraints are maxima, which can never be a window-width
            // floor, and the only equality sits below
            // `NSLayoutPriorityWindowSizeStayPut`.
            //
            // Measured against the *clip* view rather than `root` (gotcha
            // (4)): with "Show scroll bars: Always" a non-overlay scroller
            // reserves a real ~15pt track that narrows the clip without
            // narrowing `scroll`, and the column is laid out inside that
            // narrower width. At a window narrow enough that the cap does not
            // bind, pinning the toolbar to `root` instead would leave it
            // exactly that track's width past the column.
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentView.trailingAnchor,
                                              constant: -HelmMetrics.pageGutter),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            toolbar.heightAnchor.constraint(equalToConstant: 30),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                            constant: HelmMetrics.pageGutter + HelmPageSidebar.width
                                                + HelmMetrics.s5 - HelmMetrics.pageGutter),
            sidebarColumn.trailingAnchor.constraint(lessThanOrEqualTo: scroll.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: HelmMetrics.s2),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Gotcha (4): pin the document to the *clip* view, never the
            // outer scroll view - a non-overlay scroller reserves a real
            // ~15pt track that narrows the clip view without narrowing
            // `scroll`'s own frame.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // See the toolbar's trailing constraint above: the same three-part
        // shape as the content column, so the header cannot drift off the
        // column it heads.
        toolbarWidthCap = toolbar.widthAnchor
            .constraint(lessThanOrEqualToConstant: selectedCategory.contentMaxWidth)
        toolbarWidthCap.isActive = true
        let toolbarWidthGrow = toolbar.trailingAnchor
            .constraint(equalTo: scroll.contentView.trailingAnchor,
                        constant: -HelmMetrics.pageGutter)
        toolbarWidthGrow.priority = HelmDaylightPriority.contentTie
        toolbarWidthGrow.isActive = true

        mountPage(selectedCategory)

        // The theme grid's column count comes from `appearanceContainer`'s
        // real width, so it has to be recomputed when that width changes.
        // Same hook and same reasoning as `ToolsController.
        // containerWidthMayHaveChanged`: a live window resize does not
        // reliably re-invoke a child view controller's own `viewDidLayout()`.
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(containerWidthMayHaveChanged),
                                              name: NSWindow.didResizeNotification,
                                              object: nil)

        refreshFromSettings()
    }

    // MARK: - The sidebar column

    private func buildSidebarColumn() {
        searchField.onTextChanged = { [weak self] text in self?.applySearchFilter(text) }

        identityAvatar.wantsLayer = true
        identityAvatar.translatesAutoresizingMaskIntoConstraints = false
        identityInitial.font = .systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        identityInitial.translatesAutoresizingMaskIntoConstraints = false
        identityAvatar.addSubview(identityInitial)

        // The captain's own account name, never a literal. `NSFullUserName()`
        // is the display name macOS itself shows; the short name is the
        // fallback for an account with no full name set.
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespaces)
        let displayName = fullName.isEmpty ? NSUserName() : fullName
        identityName.stringValue = displayName
        identityName.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        identityName.lineBreakMode = .byTruncatingTail
        identityInitial.stringValue = String(displayName.prefix(1)).uppercased()
        identityCaption.font = HelmType.caption()
        identityCaption.lineBreakMode = .byTruncatingTail
        muted(identityCaption)

        let identityText = NSStackView(views: [identityName, identityCaption])
        identityText.orientation = .vertical
        identityText.alignment = .leading
        identityText.spacing = 0
        identityText.translatesAutoresizingMaskIntoConstraints = false
        identityText.setHuggingPriority(.defaultLow, for: .horizontal)
        identityText.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let identityRow = NSStackView(views: [identityAvatar, identityText])
        identityRow.orientation = .horizontal
        identityRow.alignment = .centerY
        identityRow.spacing = HelmMetrics.s2 + 2
        identityRow.distribution = .fill
        identityRow.translatesAutoresizingMaskIntoConstraints = false

        noMatchLabel.font = HelmType.caption()
        noMatchLabel.isHidden = true
        noMatchLabel.translatesAutoresizingMaskIntoConstraints = false
        noMatchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        muted(noMatchLabel)

        sidebarFooter.stringValue = Self.storageFootnote()
        sidebarFooter.font = HelmType.caption()
        sidebarFooter.lineBreakMode = .byTruncatingTail
        muted(sidebarFooter)
        sidebar.setFooter(sidebarFooter)

        buildSidebarSections()
        sidebar.select(selectedCategory.rawValue)
        sidebar.onSelect = { [weak self] id in
            guard let self, let category = Category(rawValue: id) else { return }
            self.select(category)
        }

        sidebarColumn.orientation = .vertical
        sidebarColumn.alignment = .leading
        sidebarColumn.spacing = HelmMetrics.s2
        sidebarColumn.translatesAutoresizingMaskIntoConstraints = false
        for view in [searchField, identityRow, noMatchLabel, sidebar] as [NSView] {
            sidebarColumn.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sidebarColumn.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            identityAvatar.widthAnchor.constraint(equalToConstant: HelmMetrics.tileBase),
            identityAvatar.heightAnchor.constraint(equalToConstant: HelmMetrics.tileBase),
            identityInitial.centerXAnchor.constraint(equalTo: identityAvatar.centerXAnchor),
            identityInitial.centerYAnchor.constraint(equalTo: identityAvatar.centerYAnchor),
        ])
    }

    /// Rebuild the page list, keeping only the categories whose title or
    /// keywords match `filter`.
    ///
    /// Declarative (`setSections`) rather than the append API, because the
    /// component's declarative path is the one that carries a selection
    /// across a rebuild - which is what keeps the current page selected while
    /// the captain types.
    private func buildSidebarSections(filter: String = "") {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sections: [HelmPageSidebar.Section] = []
        for group in NavGroup.allCases {
            let matches = Category.allCases.filter { category in
                guard category.navGroup == group else { return false }
                guard !needle.isEmpty else { return true }
                return "\(category.title) \(category.searchKeywords)".lowercased().contains(needle)
            }
            guard !matches.isEmpty else { continue }
            sections.append(HelmPageSidebar.Section(header: group.title, rows: matches.map {
                // `.tile`, not `.symbol`: eight monochrome glyphs in one muted
                // ink are a list you have to read, and a column you can scan
                // is the reference's whole point. The hue is the page's own
                // `tint`, so a row and the hero it opens match.
                HelmPageSidebar.Row(id: $0.rawValue,
                                    indicator: .tile(symbol: $0.symbol, tint: $0.tint),
                                    title: $0.title, showsCount: false)
            }))
        }
        sidebar.setSections(sections)
        sidebar.select(selectedCategory.rawValue)

        let empty = sections.isEmpty
        sidebar.isHidden = empty
        noMatchLabel.isHidden = !empty
        if empty {
            noMatchLabel.stringValue = "No settings match \u{201C}\(filter)\u{201D}."
        }
        sidebar.applyTheme(theme)
    }

    private func applySearchFilter(_ text: String) {
        buildSidebarSections(filter: text)
    }

    /// The sidebar's footer line.
    ///
    /// GL-18: the version is whatever the bundle carries (written from
    /// `git describe` by `build_native_app.sh`), never a constant - and a
    /// plain `swift build` binary has no `Info.plist` at all, so it says so
    /// rather than inventing a number.
    static func storageFootnote() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, !version.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Stored locally \u{00B7} development build"
        }
        return "Stored locally \u{00B7} Grand Line \(version)"
    }

    // MARK: - The toolbar

    private func buildToolbar() {
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "Back"
        backButton.setAccessibilityLabel("Back")
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        forwardButton.toolTip = "Forward"
        forwardButton.setAccessibilityLabel("Forward")

        toolbarTitle.font = .systemFont(ofSize: HelmType.scaled(15), weight: .semibold)
        toolbarTitle.lineBreakMode = .byTruncatingTail
        toolbarTitle.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        toolbarLocalIcon.image = HelmSymbol.image("lock", pointSize: 10, weight: .medium)
        toolbarLocalIcon.translatesAutoresizingMaskIntoConstraints = false
        toolbarLocalIcon.setContentHuggingPriority(.required, for: .horizontal)
        toolbarLocalLabel.font = HelmType.caption()
        toolbarLocalLabel.lineBreakMode = .byTruncatingTail
        muted(toolbarLocalLabel)

        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = HelmMetrics.s1 + 2
        // Gotcha (10): without an explicit distribution the trailing caption
        // drifts with whatever the title happens to say.
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        for view in [backButton, forwardButton, toolbarTitle, spacer,
                     toolbarLocalIcon, toolbarLocalLabel] as [NSView] {
            toolbar.addArrangedSubview(view)
        }
        toolbar.setCustomSpacing(HelmMetrics.s2, after: forwardButton)
        toolbarTitle.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func refreshToolbar() {
        toolbarTitle.stringValue = selectedCategory.title
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex < history.count - 1
    }

    @objc private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        show(history[historyIndex])
    }

    @objc private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        show(history[historyIndex])
    }

    // MARK: - Navigation

    /// Move to `category` and record it in the history.
    ///
    /// The sidebar has already moved its own selection by the time its
    /// `onSelect` reaches here (a `.filter` row does that itself), so this is
    /// also the path a programmatic selection takes, and `sidebar.select` is
    /// idempotent on the row that is already selected.
    func select(_ category: Category) {
        guard selectedCategory != category else { return }
        // Truncate the forward stack, exactly as a browser does: navigating
        // somewhere new from the middle of the history discards what was
        // ahead of you rather than leaving a Forward button pointing at a
        // branch you left.
        history = Array(history.prefix(historyIndex + 1))
        history.append(category)
        historyIndex = history.count - 1
        show(category)
    }

    /// Put `category` on screen without touching the history - the path both
    /// `select(_:)` and the two history buttons funnel through, so there is
    /// exactly one place that knows how a page is mounted.
    private func show(_ category: Category) {
        selectedCategory = category
        sidebar.select(category.rawValue)
        mountPage(category)
        refreshToolbar()
        // The shell owns the drill header; this page only says "re-read me".
        onDrillSubtitleChanged?()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        // Arriving on Google Accounts is the moment the captain is asking
        // "is this working?", so that is when it is answered.
        if category == .gmail { checkGoogleCalendarsIfNeeded() }
    }

    /// Put exactly one page in the detail pane.
    ///
    /// **Reparenting, never rebuilding.** Every page and every control on it
    /// is constructed once in `loadView` and lives for the controller's
    /// lifetime, so a toggle keeps its state, its action and its place in
    /// `refreshFromSettings`'s sync whether or not its page is on screen.
    ///
    /// Leaving the other seven pages *out of the view tree* is what makes
    /// this cheap: gotcha (15) measured that a hidden view is still solved by
    /// the window's full-screen minimum-size derivation, so `isHidden` would
    /// have kept all eight pages' constraint chains live. A detached page has
    /// no path to the window at all.
    private func mountPage(_ category: Category) {
        guard mountedCategory != category, let page = pages[category] else { return }
        mountedCategory = category

        for view in pageContainer.arrangedSubviews {
            pageContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // A page is moving between parents, and the width tie its previous
        // mount gave it is held by *that* parent. `removeFromSuperview()` is
        // documented to drop any constraint referring to the view being
        // removed, so detaching is what actually clears the old tie.
        for other in pages.values { other.container.removeFromSuperview() }

        pageContainer.addArrangedSubview(page.container)
        page.container.widthAnchor.constraint(equalTo: pageContainer.widthAnchor).isActive = true
        pageWidthCap.constant = category.contentMaxWidth
        toolbarWidthCap.constant = category.contentMaxWidth
        // A cap that moved changes what the descriptions have to wrap
        // against, and the staleness check below would otherwise skip the
        // re-wrap because the *container* width did not move.
        lastPageWidth = 0
        applyTheme()
    }

    @objc private func containerWidthMayHaveChanged() {
        // Only while this destination is the visible one - every destination
        // is a permanently mounted, `isHidden`-toggled child of
        // `AppShellController`, so an un-gated handler would re-lay this page
        // out on every resize no matter what the captain is looking at.
        guard !view.isHidden else { return }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        pageWidthMayHaveChanged()
        appearanceGridWidthMayHaveChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        pageWidthMayHaveChanged()
    }

    /// Re-wrap the mounted page's descriptions against the width it actually
    /// has, if - and only if - that width has moved.
    ///
    /// A `preferredMaxLayoutWidth` guessed once is an *over*-estimate the
    /// moment the column is narrower than the guess, which is the dangerous
    /// direction: AppKit sizes a label's height for one line at the estimate,
    /// the text then wraps narrower, and the extra line draws outside the
    /// label's own bounds. The staleness check is GL-20's "cheap check first,
    /// then pay", and it is also what stops the re-wrap (which changes the
    /// subtree, and so schedules another layout pass) from looping.
    private func pageWidthMayHaveChanged() {
        let width = min(contentColumnWidth(), selectedCategory.contentMaxWidth)
        guard width > 0, abs(width - lastPageWidth) > 0.5 else { return }
        lastPageWidth = width
        guard let page = pages[selectedCategory] else { return }
        applyWideLayout(to: page, width: width)
        page.hero.relayoutDescription(pageWidth: width)
        // A wide page that is still two columns gives each section only about
        // 60% of the page; collapsed, it gives them all of it.
        let twoColumns = page.isSideBySide != nil && width >= Self.wideColumnBreakpoint
        let sectionWidth = twoColumns ? (width - HelmMetrics.s5) * 0.6 : width
        for section in page.sections { section.relayoutDescriptions(cardWidth: sectionWidth) }
        // Two groups build their rows outside a `SettingsSection`'s own list
        // (Backup's measured inventory and Security's status row are both
        // rebuilt as data arrives), so `section.relayoutDescriptions` cannot
        // see them. Without this they are the only wrapping labels on the
        // page with no `preferredMaxLayoutWidth` at all.
        for row in backupRows { row.relayoutDescription(cardWidth: sectionWidth) }
        sudoRowHost?.relayoutDescription(cardWidth: sectionWidth)
    }

    private func contentColumnWidth() -> CGFloat {
        guard let scrollView else { return HelmResponsiveGrid.fallbackContainerWidth }
        let usable = scrollView.contentView.bounds.width - HelmMetrics.pageGutter * 2
        return usable > 0 ? usable : HelmResponsiveGrid.fallbackContainerWidth
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
        if !hasCheckedSudoTouchIDOnce {
            hasCheckedSudoTouchIDOnce = true
            checkSudoTouchID()
        }
        if selectedCategory == .gmail { checkGoogleCalendarsIfNeeded() }
        scrollToTop()
    }

    /// The document view (`content`, a `FlippedView`) puts y=0 at its top,
    /// but a freshly laid-out `NSScrollView` can still leave the clip view's
    /// bounds wherever the last pass settled - so force it back explicitly.
    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Page assembly

    private func buildPage(_ category: Category) -> Page {
        let hero = SettingsHero(symbol: category.symbol, tint: category.tint,
                                title: category.title, description: category.heroDescription)
        let sections: [SettingsSection]
        switch category {
        case .appearance: sections = buildAppearanceSections()
        case .terminal: sections = buildTerminalSections()
        case .capture: sections = buildCaptureSections()
        case .menuBar: sections = buildMenuBarSections()
        case .briefings: sections = buildBriefingsSections()
        case .gmail: sections = buildGmailSections()
        case .intents: sections = buildIntentsSections()
        case .security: sections = buildSecuritySections()
        case .backup: sections = buildBackupSections()
        }

        guard category.isWide, sections.count > 1 else {
            return Page(category: category,
                        container: Self.singleColumn(sections: sections, hero: hero),
                        hero: hero, sections: sections)
        }
        let wide = Self.wideColumns(sections: sections, hero: hero)
        return Page(category: category, container: wide.container, hero: hero, sections: sections,
                    sideBySide: wide.sideBySide, stacked: wide.stacked, isSideBySide: true)
    }

    /// The ordinary page: hero, then every section stacked.
    private static func singleColumn(sections: [SettingsSection], hero: SettingsHero) -> NSView {
        let stack = NSStackView(views: [hero] + sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        // `.hero { padding: 6px 0 18px }` plus `.section { margin-bottom: 22 }`
        // collapse into one gap here, since the stack owns the spacing.
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [hero] + sections as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The reference's `.page.wide` two-column grid: every section but the
    /// last on the left, the last one in a narrower right-hand column.
    ///
    /// **A plain container with explicit constraints, not a horizontal
    /// `NSStackView`** - and that is review #3's B9, which regressed here and
    /// was caught by CI rather than locally.
    ///
    /// B9 is "a detail pane does not stretch a card past its own content". A
    /// horizontal stack holding two columns of unequal height has to decide
    /// how tall the short one is, and `alignment = .top` only says where it
    /// sits, not that it keeps its own height. On a GitHub runner the solver
    /// took the other option: the App Intents page's right-hand card resolved
    /// to **271pt against 134pt of content**, matching the left column. It
    /// did not reproduce on this machine at any width or across any resize
    /// sequence, so the fix is to remove the choice rather than re-tune an
    /// alignment that happened to work here.
    ///
    /// Two things were tried first and are recorded because both look
    /// plausible and neither works. A `.required` **stack** hugging priority
    /// (gotcha (12)'s correct API for a view with no intrinsic size) is not
    /// honoured by `NSStackView` - with it set, the section column still
    /// measured 342pt against 203pt of content, and on an *unpressured* page
    /// it introduced a stretch that had not been there. Making the card's own
    /// bottom pin an inequality moved the problem rather than fixing it,
    /// because a `HelmCard`'s body is pinned to all four of its edges and the
    /// body is itself a stack with the same weakness.
    ///
    /// So: each column's height is its own content's, each is pinned to the
    /// container's top and only *capped* at its bottom, and the container
    /// hugs the taller of the two through one low-priority zero height. No
    /// constraint anywhere says the columns are the same height, so none can
    /// be resolved into saying it.
    private static func wideColumns(sections: [SettingsSection],
                                    hero: SettingsHero) -> (container: NSView,
                                                            columns: NSView,
                                                            sideBySide: [NSLayoutConstraint],
                                                            stacked: [NSLayoutConstraint]) {
        let trailing = sections[sections.count - 1]
        let leading = Array(sections.dropLast())

        let leftColumn = NSStackView(views: leading)
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 20
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        for view in leading { view.widthAnchor.constraint(equalTo: leftColumn.widthAnchor).isActive = true }

        let rightColumn = NSStackView(views: [trailing])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 20
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        trailing.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true

        let columns = NSView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.addSubview(leftColumn)
        columns.addSubview(rightColumn)

        // True in both arrangements: each column starts at the container's
        // leading edge or is capped by its bottom, and the container collapses
        // onto whatever is tallest.
        let hug = columns.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            leftColumn.bottomAnchor.constraint(lessThanOrEqualTo: columns.bottomAnchor),
            rightColumn.bottomAnchor.constraint(lessThanOrEqualTo: columns.bottomAnchor),
            hug,
        ])

        // 0.6 of the row, below `NSLayoutPriorityWindowSizeStayPut` (500) so a
        // page that narrows past what two columns can hold never becomes a
        // floor on the window's own width (gotcha (13)). The page collapses
        // below `wideColumnBreakpoint` rather than leaning on this.
        let split = leftColumn.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.6,
                                                      constant: -HelmMetrics.s5 / 2)
        split.priority = HelmDaylightPriority.contentTie

        let sideBySide = [
            leftColumn.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: columns.topAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor,
                                                 constant: HelmMetrics.s5),
            rightColumn.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: columns.topAnchor),
            split,
        ]

        let stacked = [
            leftColumn.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            leftColumn.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            leftColumn.topAnchor.constraint(equalTo: columns.topAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            rightColumn.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: leftColumn.bottomAnchor, constant: 20),
        ]
        NSLayoutConstraint.activate(sideBySide)

        let stack = NSStackView(views: [hero, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [hero, columns] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return (stack, columns, sideBySide, stacked)
    }

    /// The width below which the wide page stops being two columns.
    ///
    /// The reference's own breakpoint is `@media (max-width: 980px)` on a
    /// 980pt page, i.e. "collapse as soon as the page is not at full width".
    /// 720 here is measured rather than copied: below it the right-hand
    /// column is narrower than the buttons and pills it carries, which is the
    /// state whose overflow the note on `split` above describes.
    private static let wideColumnBreakpoint: CGFloat = 720

    /// One column or two, decided by the width the page actually has.
    ///
    /// Exactly one constraint set is active at a time, and the swap
    /// deactivates before it activates - two sets that overlap for even one
    /// pass are a conflict, and the page would resolve it by breaking
    /// something.
    private func applyWideLayout(to page: Page, width: CGFloat) {
        guard let isSideBySide = page.isSideBySide else { return }
        let wantsTwo = width >= Self.wideColumnBreakpoint
        guard wantsTwo != isSideBySide else { return }
        NSLayoutConstraint.deactivate(wantsTwo ? page.stacked : page.sideBySide)
        NSLayoutConstraint.activate(wantsTwo ? page.sideBySide : page.stacked)
        pages[page.category]?.isSideBySide = wantsTwo
    }

    // MARK: - Appearance

    private enum ThemeFilter: String {
        case all, dark, light
    }

    private func buildAppearanceSections() -> [SettingsSection] {
        followSystemSwitch.onToggle = { [weak self] in self?.followSystemToggled() }
        let followRow = SettingsRow(
            title: "Follow system appearance",
            description: "Switch between your light and dark picks when macOS does, including its own sunrise/sunset schedule.",
            control: followSystemSwitch)

        for popUp in [systemLightPopUp, systemDarkPopUp] {
            popUp.target = self
            popUp.action = #selector(systemPairChanged)
        }
        systemLightPopUp.setAccessibilityLabel("Light theme")
        systemDarkPopUp.setAccessibilityLabel("Dark theme")
        let pairControls = NSStackView(views: [systemLightPopUp, systemDarkPopUp])
        pairControls.orientation = .horizontal
        pairControls.spacing = HelmMetrics.s2
        let pairRow = register(SettingsRow(
            title: "Light and dark pair",
            description: "Used only while following the system.",
            control: pairControls,
            isSubRow: true), dependingOn: .followSystemAppearance)

        themeFilterTabs = HelmSegmentedTabs(items: [
            .init(id: ThemeFilter.all.rawValue, title: "All"),
            .init(id: ThemeFilter.dark.rawValue, title: "Dark"),
            .init(id: ThemeFilter.light.rawValue, title: "Light"),
        ], selected: themeFilter.rawValue, size: .compact)
        themeFilterTabs.onSelect = { [weak self] id in
            guard let self, let filter = ThemeFilter(rawValue: id), filter != self.themeFilter else { return }
            self.themeFilter = filter
            self.rebuildAppearanceGrid()
        }

        appearanceContainer.onLayout = { [weak self] in self?.appearanceGridWidthMayHaveChanged() }
        appearanceContainer.orientation = .vertical
        appearanceContainer.alignment = .leading
        appearanceContainer.spacing = HelmMetrics.s3
        appearanceContainer.translatesAutoresizingMaskIntoConstraints = false

        let scaleButtons = ChromeTextScale.steps.enumerated().map { index, step -> HelmButton in
            let button = HelmButton(title: step.title, variant: .secondary,
                                    target: self, action: #selector(uiScaleClicked(_:)))
            button.tag = index
            uiScaleButtons[index] = button
            return button
        }
        let scaleRow = NSStackView(views: scaleButtons)
        scaleRow.orientation = .horizontal
        scaleRow.spacing = HelmMetrics.s1 + 2

        return [
            SettingsSection(group: SettingsGroup(rows: [followRow, pairRow])),
            SettingsSection(heading: "Theme", aside: themeFilterTabs,
                            group: SettingsGroup(custom: appearanceContainer)),
            SettingsSection(heading: "Text", group: SettingsGroup(rows: [
                SettingsRow(title: "Interface text size",
                            description: "Scales the app's own labels, captions and titles. Pages that set their fonts once pick this up after a relaunch.",
                            control: scaleRow),
            ])),
        ]
    }

    /// The width one theme card will not go below.
    ///
    /// 150 rather than a smaller number, and measured rather than picked: at
    /// 108 the longest names ("Catppuccin Mocha", "Tokyo Night Light") do not
    /// fit beside the active checkmark, and a real render showed one card in
    /// a row resolving to 130pt while its siblings sat at 107 - its own
    /// label's compression resistance winning over `.fillEqually`.
    private static let themeCardMinWidth: CGFloat = 152

    /// The container width the grid was last laid out against.
    private var lastAppearanceGridWidth: CGFloat = 0

    private func appearanceGridWidthMayHaveChanged() {
        let width = appearanceContainer.frame.width
        guard width > 0, abs(width - lastAppearanceGridWidth) > 0.5 else { return }
        lastAppearanceGridWidth = width
        rebuildAppearanceGrid()
    }

    private func rebuildAppearanceGrid() {
        themeCards.removeAll()
        for view in appearanceContainer.arrangedSubviews {
            appearanceContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        lastAppearanceGridWidth = appearanceContainer.frame.width
        let activeID = ThemeManager.shared.theme.id

        // **One grid, dark palettes first.** The card this replaces drew two
        // separate grids, and with an odd number of dark themes that leaves a
        // ragged partial row in the middle of the page - visible in the first
        // render of this redesign, where Oxocarbon sat alone on a row of
        // four. The dark/light distinction is still a real one a captain
        // scans by, and it is what the new All/Dark/Light filter is for; the
        // ordering keeps it legible under All without breaking the grid.
        let palettes: [HelmTheme]
        switch themeFilter {
        case .all:
            palettes = HelmTheme.allThemes.filter { $0.mode == .dark }
                + HelmTheme.allThemes.filter { $0.mode == .light }
        case .dark:
            palettes = HelmTheme.allThemes.filter { $0.mode == .dark }
        case .light:
            palettes = HelmTheme.allThemes.filter { $0.mode == .light }
        }

        if !palettes.isEmpty {
            let rows = HelmResponsiveGrid.rows(palettes,
                                               containerWidth: appearanceContainer.frame.width,
                                               minItemWidth: Self.themeCardMinWidth,
                                               spacing: HelmMetrics.s3) { palette, _ in
                let card = SettingsThemeCard(theme: palette, isActive: palette.id == activeID)
                card.onSelect = { ThemeManager.shared.setTheme(palette) }
                card.applyTheme(self.theme)
                self.themeCards.append(card)
                return card
            }
            for row in rows {
                appearanceContainer.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: appearanceContainer.widthAnchor).isActive = true
            }
        }
    }

    /// Fill both popups with the halves of the catalogue they are allowed to
    /// name, and select the stored pair.
    ///
    /// Rebuilt from `HelmTheme.allThemes` on every sync rather than once, so
    /// a palette added to the catalogue appears here with no second edit -
    /// the same reason the grid is derived rather than listed.
    private func refreshSystemPairPopUps() {
        for (popUp, mode, stored) in [
            (systemLightPopUp, HelmTheme.Mode.light, AppSettings.shared.systemLightThemeID),
            (systemDarkPopUp, HelmTheme.Mode.dark, AppSettings.shared.systemDarkThemeID),
        ] {
            let themes = HelmTheme.allThemes.filter { $0.mode == mode }
            if popUp.itemTitles != themes.map(\.name) {
                popUp.removeAllItems()
                for palette in themes {
                    popUp.addItem(withTitle: palette.name)
                    popUp.lastItem?.representedObject = palette.id
                }
            }
            if let index = themes.firstIndex(where: { $0.id == stored }) {
                popUp.selectItem(at: index)
            } else if !themes.isEmpty {
                popUp.selectItem(at: 0)
            }
        }
    }

    @objc private func followSystemToggled() {
        AppSettings.shared.followSystemAppearance = followSystemSwitch.isOn
        syncDependentRows()
        // Take effect now rather than on the next system-wide switch, which
        // could be hours away - a toggle that appears to do nothing is
        // indistinguishable from one that is broken.
        SystemAppearanceFollower.shared.start()
    }

    @objc private func systemPairChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        if sender === systemLightPopUp {
            AppSettings.shared.systemLightThemeID = id
        } else {
            AppSettings.shared.systemDarkThemeID = id
        }
        SystemAppearanceFollower.shared.applyIfFollowing()
    }

    // MARK: - Terminal

    private func buildTerminalSections() -> [SettingsSection] {
        configure(shellCwdField)
        shellCwdField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chooseCwd = HelmButton(title: "Choose\u{2026}", variant: .secondary,
                                   target: self, action: #selector(chooseShellCwd))
        let cwdControls = NSStackView(views: [shellCwdField, chooseCwd])
        cwdControls.orientation = .horizontal
        cwdControls.spacing = HelmMetrics.s2
        // A control, not text: a required width would be a window floor
        // (gotcha (13)), so this is a cap.
        cwdControls.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let sizes = [12, 13, 14, 16]
        let presetButtons = sizes.map { size -> HelmButton in
            let button = HelmButton(title: "\(size)", variant: .secondary,
                                    target: self, action: #selector(fontPresetClicked(_:)))
            button.tag = size
            fontPresetButtons[size] = button
            return button
        }
        let presetRow = NSStackView(views: presetButtons)
        presetRow.orientation = .horizontal
        presetRow.spacing = HelmMetrics.s1 + 2

        autoReconnectSwitch.onToggle = { [weak self] in self?.autoReconnectToggled() }
        notifySwitch.onToggle = { [weak self] in self?.notifyToggled() }

        var sections: [SettingsSection] = [
            SettingsSection(heading: "Connection", group: SettingsGroup(rows: [
                SettingsRow(title: "Working directory",
                            description: "Where new Shell and Firstmate tabs start.",
                            control: cwdControls),
                SettingsRow(title: "Reconnect automatically",
                            description: "If a tab's connection drops, restore it silently rather than waiting for \u{2318}R.",
                            control: autoReconnectSwitch),
            ])),
            SettingsSection(heading: "Text", group: SettingsGroup(rows: [
                SettingsRow(title: "Default font size",
                            description: "Also adjustable live in any tab with \u{2318}+ and \u{2318}\u{2212}.",
                            control: presetRow),
                SettingsRow(title: "Notify when the crew needs you",
                            description: "Surface a desktop notification the moment a crewmate is waiting on your decision.",
                            control: notifySwitch),
            ])),
        ]

        // One section per shortcut group, which is the reference's own
        // arrangement (Tab shortcuts / Split the terminal / Panes) and reads
        // as three ideas rather than nine rows under one heading.
        for group in TerminalShortcutAction.Group.allCases {
            var rows: [SettingsRow] = []
            for action in TerminalShortcutAction.allCases where action.group == group {
                // `.command`: a Console shortcut has to be a real key with a
                // modifier. See `KeyChordRecorderView.Mode`.
                let recorder = KeyChordRecorderView(shortcut: AppSettings.shared.terminalShortcuts[action],
                                                    mode: .command)
                // One width for all nine, so they read as a column: a
                // recorder sizes itself to whatever chord it shows, and
                // leaving them natural lands nine controls at nine widths.
                // Wide enough for the longest shipped default (⌃⌘Return) and
                // for the recording prompt to stay readable.
                recorder.widthAnchor.constraint(equalToConstant: 168).isActive = true
                recorder.onChange = { [weak self] chord in self?.shortcutChanged(action, to: chord) }
                shortcutRecorders[action] = recorder
                rows.append(SettingsRow(title: action.title, description: action.detail, control: recorder))
            }
            let isLast = group == TerminalShortcutAction.Group.allCases.last
            var aside: NSView?
            if isLast {
                let reset = HelmButton(title: "Restore Defaults", variant: .secondary,
                                       target: self, action: #selector(resetTerminalShortcuts))
                resetShortcutsButton = reset
                aside = reset
            }
            sections.append(SettingsSection(
                heading: group.title,
                aside: aside,
                group: SettingsGroup(rows: rows),
                foot: isLast ? "Click a shortcut, then press the new keys. Esc cancels, Delete clears." : nil))
        }
        refreshShortcutControls()
        return sections
    }

    @objc private func chooseShellCwd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the default working directory for new Shell/Firstmate tabs."
        if let current = AppSettings.shared.defaultShellCwd {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        shellCwdField.stringValue = url.path
        AppSettings.shared.defaultShellCwd = url.path
    }

    private func shortcutChanged(_ action: TerminalShortcutAction, to chord: KeyChord) {
        var set = AppSettings.shared.terminalShortcuts
        set[action] = chord
        AppSettings.shared.terminalShortcuts = set
        onTerminalShortcutsChanged?(set)
        refreshShortcutControls()
    }

    @objc private func resetTerminalShortcuts() {
        var set = AppSettings.shared.terminalShortcuts
        set.reset()
        AppSettings.shared.terminalShortcuts = set
        onTerminalShortcutsChanged?(set)
        // Every recorder, not only the ones the captain changed: `reset()`
        // clears the whole map, so a row still showing a custom chord would
        // be showing a binding that no longer exists.
        for (action, recorder) in shortcutRecorders { recorder.shortcut = set[action] }
        refreshShortcutControls()
    }

    private func refreshShortcutControls() {
        resetShortcutsButton?.isEnabled = AppSettings.shared.terminalShortcuts.hasCustomBindings
    }

    // MARK: - Capture (fm/grandline-capture-global-hotkey-configurable)

    /// Settings > Capture.
    ///
    /// Two rows, and the second one exists because of how this page came to
    /// be written. The captain reported ⌥Space working only while Grand Line
    /// was frontmost, and diagnosing that took a live `lldb` read of the
    /// running app to establish something the app could have said out loud:
    /// whether the global half of the hotkey is actually armed. A chord that
    /// silently works in one app and not the rest is exactly the failure a
    /// settings page should be able to explain, so the trust state is a real
    /// row here rather than a comment in `ShiftGlobalHotkey`.
    private func buildCaptureSections() -> [SettingsSection] {
        // `.command`: a capture trigger has to be a real key carrying a
        // modifier. A bare `Space` recorded here would open the panel every
        // time the captain pressed the space bar in any app on the machine,
        // and a modifier on its own would fire while they reached for ⌘ - see
        // `KeyChordRecorderView.Mode`.
        let recorder = KeyChordRecorderView(shortcut: AppSettings.shared.quickCaptureShortcut, mode: .command)
        recorder.widthAnchor.constraint(equalToConstant: 168).isActive = true
        recorder.onChange = { [weak self] chord in self?.quickCaptureShortcutChanged(chord) }
        captureShortcutRecorder = recorder

        let reset = HelmButton(title: "Restore Default", variant: .secondary,
                               target: self, action: #selector(resetQuickCaptureShortcut))
        resetCaptureShortcutButton = reset

        let grant = HelmButton(title: "Open Accessibility Settings", variant: .secondary,
                               target: self, action: #selector(openAccessibilitySettings))
        captureAccessibilityButton = grant

        let status = muted(NSTextField(labelWithString: ""))
        status.font = .systemFont(ofSize: HelmType.scaled(12))
        captureAccessibilityStatus = status

        let trustColumn = NSStackView(views: [status, grant])
        trustColumn.orientation = .vertical
        trustColumn.alignment = .trailing
        trustColumn.spacing = HelmMetrics.s1

        refreshCaptureControls()

        return [
            SettingsSection(heading: "Shortcut", aside: reset, group: SettingsGroup(rows: [
                SettingsRow(title: "Open the capture panel",
                            description: "Works from any app once Accessibility is granted, and from Grand Line itself either way. The Shift menu\u{2019}s Capture item follows whatever you record here.",
                            control: recorder),
            ]), foot: "Click the shortcut, then press the new keys. Esc cancels."),

            SettingsSection(heading: "System-wide access", group: SettingsGroup(rows: [
                SettingsRow(title: "Accessibility permission",
                            description: "macOS only delivers keystrokes from other apps to a trusted Accessibility client. Without it the chord still works while Grand Line is frontmost, which is why a missing grant reads as \u{201C}it only sometimes works\u{201D} rather than as an error.",
                            control: trustColumn),
            ]), foot: "Granting it while Grand Line is already running is enough - the monitors are reinstalled the next time you switch back to this app. No relaunch needed.")
        ]
    }

    private func refreshCaptureControls() {
        captureShortcutRecorder?.shortcut = AppSettings.shared.quickCaptureShortcut
        resetCaptureShortcutButton?.isEnabled =
            AppSettings.shared.quickCaptureShortcut != .quickCaptureDefault
        let trusted = quickCaptureAccessibilityTrusted?() ?? AXIsProcessTrusted()
        captureAccessibilityStatus?.stringValue = trusted ? "Granted" : "Not granted"
        captureAccessibilityButton?.isHidden = trusted
    }

    private func quickCaptureShortcutChanged(_ chord: KeyChord) {
        AppSettings.shared.quickCaptureShortcut = chord
        onQuickCaptureShortcutChanged?(chord)
        refreshCaptureControls()
    }

    @objc private func resetQuickCaptureShortcut() {
        quickCaptureShortcutChanged(.quickCaptureDefault)
    }

    /// Opens the exact pane the captain needs rather than "System Settings".
    /// The same URL `DictationController`'s own status action uses.
    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Menu Bar (F22)

    private func buildMenuBarSections() -> [SettingsSection] {
        for toggle in [compactModeSwitch, compactDockSwitch, compactBadgeSwitch] {
            toggle.onToggle = { [weak self] in self?.compactModeToggled() }
        }

        return [
            SettingsSection(heading: "Compact mode", group: SettingsGroup(rows: [
                SettingsRow(title: "Live in the menu bar",
                            description: "The main window stays closed. Tasks, notes, the vault and the crew are all reachable from the status item, which also takes a capture line.",
                            control: compactModeSwitch),
                register(SettingsRow(
                    title: "Hide the Dock icon",
                    description: "Runs as a menu-bar accessory (`LSUIElement`), applied immediately with no relaunch and reversed the moment compact mode goes off - so this can never leave you with no way back to the window.",
                    control: compactDockSwitch, isSubRow: true), dependingOn: .compactMode),
                register(SettingsRow(
                    title: "Show the overdue count on the icon",
                    description: "Off by default - a permanent red number is a bad neighbour in a menu bar. The count is one click away either way.",
                    control: compactBadgeSwitch, isSubRow: true), dependingOn: .compactMode),
            ]), foot: "Compact mode does not disable anything. The app lock, the dictation hotkey, Schedules and every background poller keep running in either mode."),

            // The reference's "Global shortcut" section. It is a *stated*
            // chord rather than a recorder, because this one really is fixed:
            // `CompactModeHotkey` matches one chord by construction and there
            // is no setting behind it. A recorder here would be a control
            // that either does nothing or silently disagrees with what the
            // app listens for - the same reason the App Intents page draws no
            // enable switches.
            SettingsSection(heading: "Global shortcut", group: SettingsGroup(rows: [
                SettingsRow(title: "Open Grand Line from anywhere",
                            description: "Shows the status item's popover in compact mode, or brings the window forward when it is off. Fixed, and not configurable.",
                            control: keyCapLabel(CompactModeHotkey.displayChord)),
            ])),
        ]
    }

    /// A chord printed the way a menu prints one - a key cap rather than a
    /// recorder, for a shortcut that has no setting behind it.
    private func keyCapLabel(_ chord: String) -> NSTextField {
        let label = NSTextField(labelWithString: chord)
        label.font = .monospacedSystemFont(ofSize: HelmType.scaled(12), weight: .medium)
        muted(label)
        return label
    }

    @objc private func compactModeToggled() {
        AppSettings.shared.compactModeEnabled = compactModeSwitch.isOn
        AppSettings.shared.compactModeHidesDockIcon = compactDockSwitch.isOn
        AppSettings.shared.compactModeBadgesOverdueCount = compactBadgeSwitch.isOn
        syncDependentRows()
        // One callback for all three rather than three: everything that
        // follows is `CompactModeController.refresh()`, which re-reads all of
        // them and is idempotent.
        onCompactModeSettingsChanged?()
    }

    // MARK: - Briefings (F12 and F20)

    private func buildBriefingsSections() -> [SettingsSection] {
        morningBriefingSwitch.onToggle = { [weak self] in self?.morningBriefingToggled() }
        dailyReviewSwitch.onToggle = { [weak self] in self?.dailyReviewToggled() }
        dailyReviewCalendarSwitch.onToggle = { [weak self] in self?.dailyReviewCalendarToggled() }

        googleCalendarInReviewButton.target = self
        googleCalendarInReviewButton.action = #selector(showGoogleAccounts)

        return [
            SettingsSection(heading: "Morning briefing", group: SettingsGroup(rows: [
                SettingsRow(title: "Show a morning briefing on Fleet",
                            description: "On the first visit to Fleet each day, one short generated paragraph over your fleet, PR queue, due tasks and drift - each clause linking to the page it came from.",
                            control: morningBriefingSwitch),
            ]), foot: "Uses your own `claude` login for one call per day. Only counts and titles already shown elsewhere in the app are sent - never terminal output or logs. With `claude` unavailable the card still appears as a plain, locally-computed stat line with no AI call at all."),

            SettingsSection(heading: "Daily review", group: SettingsGroup(rows: [
                SettingsRow(title: "Show the daily review on Fleet",
                            description: "What is due today, the follow-ups waiting on you, today's calendar, your habits, the top notes on your sticky board and what is unread in your reading list.",
                            control: dailyReviewSwitch),
                register(SettingsRow(
                    title: "Mac calendars",
                    description: "Read through EventKit and never written to. macOS asks for permission the first time; turning this off stops Grand Line reading your calendar at all.",
                    control: dailyReviewCalendarSwitch, isSubRow: true), dependingOn: .dailyReview),
                register(SettingsRow(
                    title: "Google Calendar",
                    description: "Events from accounts connected under Google Accounts. The switch for it lives on that page, beside the accounts it applies to.",
                    control: googleCalendarInReviewButton, isSubRow: true), dependingOn: .dailyReview),
            ]), foot: "The review itself is assembled on this Mac from records the app has already loaded, with no AI call. A section it cannot read says so instead of showing a zero."),
        ]
    }

    @objc private func morningBriefingToggled() {
        AppSettings.shared.morningBriefingEnabled = morningBriefingSwitch.isOn
        syncDependentRows()
    }

    @objc private func dailyReviewToggled() {
        AppSettings.shared.dailyReviewEnabled = dailyReviewSwitch.isOn
        syncDependentRows()
    }

    /// Turning the calendar on here does **not** prompt: the permission
    /// request belongs to a real click on the card's own button, where the
    /// captain can see what they are about to be asked for. This flag only
    /// says the column may read once access exists.
    @objc private func dailyReviewCalendarToggled() {
        AppSettings.shared.dailyReviewCalendarEnabled = dailyReviewCalendarSwitch.isOn
    }

    /// The reference's `data-go` cross-reference. It is a real navigation
    /// within this page, and it is what the back button exists for.
    @objc private func showGoogleAccounts() {
        select(.gmail)
    }

    // MARK: - Google Accounts

    private func buildGmailSections() -> [SettingsSection] {
        // The account row **is** the row. `GmailAccountRow` draws its own
        // avatar, title, address, status pill and button and has done since
        // the Gmail task, so wrapping it in a label/control `SettingsRow`
        // gives it a second title - which is what the first render of this
        // page showed, "Work mail" printed twice.
        var accountRows: [NSView] = []
        for slot in GoogleAccountSlot.allCases {
            let row = GmailAccountRow(slot: slot)
            row.onConnect = { [weak self] in self?.connectGoogle(slot) }
            row.onDisconnect = { [weak self] in self?.disconnectGoogle(slot) }
            row.onTest = { [weak self] in self?.checkGoogleCalendar(slot) }
            // Opened here rather than inside the row, so the row stays a view
            // and the one `NSWorkspace.open` this page performs is visible
            // where the rest of its side effects are.
            row.onOpenFixURL = { NSWorkspace.shared.open($0) }
            gmailRows[slot] = row
            accountRows.append(row)
        }

        // The reference puts this switch on this page, under its own Calendar
        // heading - which is where the setting belongs, since it is about the
        // account rather than about the review. Briefings carries a *link*
        // here rather than a second copy of the switch: one control, one
        // setting.
        gmailCalendarSwitch.onToggle = { [weak self] in self?.googleCalendarToggled() }
        let calendarSection = SettingsSection(heading: "Calendar", group: SettingsGroup(rows: [
            SettingsRow(title: "Use Google Calendar in the daily review",
                        description: "Adds a connected account's events to the review's calendar column, alongside your Mac's own calendars rather than instead of them. Read-only: the only scope Grand Line ever asks Google for cannot write.",
                        control: gmailCalendarSwitch),
        ]))

        // Through `configure(_:)`, never a hand-wired target/action pair.
        // Plain AppKit target/action fires on **Return** and on nothing else,
        // so a field wired by hand commits only for the captain who happens
        // to press it - paste a client ID, click Connect, and the value is
        // silently gone (gotcha (19),
        // `fm/grandline-gmail-oauth-field-not-saving`). `configure` also
        // wires the `delegate`, which is what carries
        // `controlTextDidEndEditing` into the same commit.
        //
        // **Both halves of each control**, never only the visible one: a
        // masked field that wired one half would reopen that same bug in the
        // other.
        for control in [gmailClientIDField, gmailClientSecretField] {
            control.editableFields.forEach(configure)
            // A field is a control, not text: a required width would be a
            // window floor (gotcha (13)), so this is a preference below 500.
            control.setPreferredFieldWidth(300)
        }
        gmailClientIDField.revealHint = "Show the OAuth client ID"
        gmailClientSecretField.revealHint = "Show the client secret"

        let statusSection = SettingsSection(
            heading: "OAuth client",
            group: SettingsGroup(rows: [
                SettingsRow(title: "Client ID",
                            description: "From your own Google Cloud project - create an OAuth client of type \u{201C}Desktop app\u{201D} and paste its ID here.",
                            control: gmailClientIDField),
                SettingsRow(title: "Client secret",
                            description: "Optional. Google issues one for a Desktop client and its token endpoint expects it back.",
                            control: gmailClientSecretField),
            ]),
            foot: Self.gmailStatusLine(for: GoogleOAuth.configuration()))
        gmailStatusSection = statusSection

        return [
            SettingsSection(heading: "Accounts", group: SettingsGroup(rowViews: accountRows),
                            foot: "Connect opens Google's own sign-in page in Safari, so Grand Line never sees your password. Signing out of one account leaves the other alone."),
            calendarSection,
            statusSection,
        ]
    }

    /// Repaint every Google surface from the store. One function, called from
    /// `refreshFromSettings` and after every sign-in or sign-out, so the two
    /// pages that show this state can never disagree with what is stored.
    private func refreshGmailSection() {
        let configuration = GoogleOAuth.configuration()
        for (slot, row) in gmailRows {
            row.render(record: GoogleAccountStore.shared.record(for: slot),
                       isConfigured: configuration != nil,
                       isBusy: GoogleSignInController.shared.inFlight.contains(slot),
                       health: GoogleCalendarHealthCheck.shared.result(for: slot),
                       theme: theme)
        }
        gmailCalendarSwitch.isOn = AppSettings.shared.googleCalendarEnabled
        let stored = GoogleOAuthClientStore.shared.configuration()
        if gmailClientIDField.stringValue != (stored?.clientID ?? "") {
            gmailClientIDField.stringValue = stored?.clientID ?? ""
        }
        if gmailClientSecretField.stringValue != (stored?.clientSecret ?? "") {
            gmailClientSecretField.stringValue = stored?.clientSecret ?? ""
        }
        gmailStatusSection?.footLabel?.stringValue = Self.gmailStatusLine(for: configuration)

        // The Briefings page's own cross-reference button says how many
        // accounts are actually connected, which is GL-14 in miniature: "1
        // account" and "no accounts" are different sentences, and a constant
        // label would make the row look the same either way.
        let connected = GoogleAccountSlot.allCases
            .filter { GoogleAccountStore.shared.record(for: $0) != nil }.count
        googleCalendarInReviewButton.title = connected == 0
            ? "No accounts"
            : "\(connected) account\(connected == 1 ? "" : "s")"
    }

    /// The one sentence under the client-ID field, and the honest statement
    /// of what is and is not set up.
    ///
    /// A stated gap in GL-14's own spirit: "no client ID" is not "sign-in is
    /// broken", and the captain should be able to read which of the two they
    /// are looking at.
    static func gmailStatusLine(for configuration: GoogleOAuthConfiguration?) -> String {
        guard let configuration else {
            return "No OAuth client ID yet, so Connect cannot run - Grand Line cannot create one "
                + "for you. Create a Google Cloud project, add an OAuth client of type "
                + "\u{201C}Desktop app\u{201D}, and paste its ID above. Both values are kept in the "
                + "Keychain, never on disk; FM_GOOGLE_OAUTH_CLIENT_ID overrides them."
        }
        guard configuration.looksWellFormed else {
            return "That does not look like a Google client ID - they end in "
                + "\u{201C}.apps.googleusercontent.com\u{201D}. Connect will use it anyway, but "
                + "Google will probably refuse it."
        }
        return "Ready. Connect opens Google\u{2019}s own sign-in page in Safari, so Grand Line "
            + "never sees your password. Both values are kept in the Keychain, never on disk."
    }

    @objc private func gmailClientChanged() {
        let id = gmailClientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = gmailClientSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // GL-10: the write is reported, never silently dropped.
            try GoogleOAuthClientStore.shared.setConfiguration(
                id.isEmpty ? nil : GoogleOAuthConfiguration(clientID: id,
                                                            clientSecret: secret.isEmpty ? nil : secret))
        } catch {
            Feedback.report("Grand Line could not store the Google client ID: "
                            + error.localizedDescription,
                            kind: .warning, persistence: .transient, in: view)
        }
        refreshGmailSection()
    }

    @objc private func googleCalendarToggled() {
        AppSettings.shared.googleCalendarEnabled = gmailCalendarSwitch.isOn
        if !gmailCalendarSwitch.isOn { DailyReviewCalendarSources.shared.forgetGoogle() }
        onGoogleAccountsChanged?()
    }

    /// Run one **real** calendar read for `slot` and repaint the row with
    /// whatever actually happened.
    ///
    /// The captain's own report is the reason this exists: OAuth succeeded,
    /// this page said "calendar readable", and the read failed every time
    /// with Google's "Calendar API has not been used in project N ... Enable
    /// it by visiting <url>". That sentence was already being captured by
    /// `GoogleCalendarSource`; the only place it ever surfaced was the daily
    /// review card's fine print, on the Overview page, days later. This puts
    /// it next to the account it is about, at the moment the captain is
    /// looking at that account.
    private func checkGoogleCalendar(_ slot: GoogleAccountSlot) {
        GoogleCalendarHealthCheck.shared.check(slot: slot) { [weak self] _ in
            self?.refreshGmailSection()
        }
    }

    /// Check every connected account that has no verdict yet.
    ///
    /// Called when the page appears and right after a connect, never on every
    /// repaint: `result(for:)` is `.notChecked` only until the first answer
    /// lands, so this costs one request per account per launch rather than
    /// one per render. "Test connection" is the way to ask again.
    private func checkGoogleCalendarsIfNeeded() {
        for slot in GoogleAccountSlot.allCases
        where GoogleAccountStore.shared.record(for: slot) != nil
            && GoogleCalendarHealthCheck.shared.result(for: slot) == .notChecked {
            checkGoogleCalendar(slot)
        }
    }

    private func connectGoogle(_ slot: GoogleAccountSlot) {
        refreshGmailSection()
        GoogleSignInController.shared.signIn(slot: slot, from: view.window) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record):
                if record.canReadCalendar {
                    Feedback.report("Connected \(record.email.isEmpty ? slot.title : record.email).",
                                    kind: .done, persistence: .transient, in: self.view)
                    // The whole point: "connected" is not "working", so the
                    // read is tried here rather than left for the daily
                    // review to discover days later.
                    GoogleCalendarHealthCheck.shared.forget(slot)
                    self.checkGoogleCalendar(slot)
                } else {
                    // Signed in, no calendar. A stated gap rather than a
                    // success that quietly does nothing.
                    Feedback.report("Connected, but that account did not grant calendar access - "
                                    + "the daily review will say so.",
                                    kind: .warning, persistence: .transient, in: self.view)
                }
            case .failure(.cancelled):
                break
            case .failure(let error):
                Feedback.report(error.errorDescription ?? "Google sign-in failed.",
                                kind: .warning, persistence: .transient, in: self.view)
            }
            self.refreshGmailSection()
            self.onGoogleAccountsChanged?()
        }
        refreshGmailSection()
    }

    private func disconnectGoogle(_ slot: GoogleAccountSlot) {
        // A sign-out is not destructive in GL-06's sense - nothing of the
        // captain's is deleted, and signing back in restores it - so it needs
        // no `DestructiveConfirm`. It does revoke the token with Google,
        // which is the part that cannot be undone from here, so the button
        // says "Disconnect" rather than "Remove".
        GoogleSignInController.shared.signOut(slot: slot)
        // A verdict about an account that is gone is a lie about the row it
        // sits under.
        GoogleCalendarHealthCheck.shared.forget(slot)
        // The cached day of events belongs to the account that just went
        // away; keeping it would render a disconnected account's calendar.
        DailyReviewCalendarSources.shared.forgetGoogle()
        refreshGmailSection()
        onGoogleAccountsChanged?()
    }

    // MARK: - App Intents & Shortcuts (F21)

    /// The reference's wide page: the real intent catalogue on the left, and
    /// an example shortcut built from that same catalogue on the right.
    ///
    /// **No per-intent enable switches**, unlike the reference's five. There
    /// is nothing to enable: an App Intent is published by the app bundle's
    /// metadata, and a switch here would be a control that either does
    /// nothing or - worse - reads as a security boundary while the real ones
    /// (the app lock, the vault's own lock, the per-credential Touch ID gate)
    /// sit elsewhere.
    private func buildIntentsSections() -> [SettingsSection] {
        var rows: [SettingsRow] = []
        for entry in GrandLineIntentCatalog.entries {
            let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.rChip)
            tile.configure(symbol: entry.symbol, tint: entry.tint)
            let trailing: NSView
            if let note = entry.guardNote {
                // Amber, and the one row on this page carrying a chip at all.
                // It is the single thing about this list a captain has to
                // read before wiring any of it into a shortcut.
                trailing = pillView(text: note, colorHex: HelmTint.warn.hex(in: theme))
            } else {
                trailing = rowLabel("action")
            }
            rows.append(SettingsRow(title: entry.title, description: entry.parameters,
                                    control: trailing, lead: tile))
        }

        let intentCountLabel = NSTextField(
            labelWithString: "\(GrandLineIntentCatalog.entries.count) actions")
        intentCountLabel.font = HelmType.caption()
        muted(intentCountLabel)

        // The reference's "Try it" card. Its own flow is illustrative; this
        // one is built from the real catalogue's own titles, and it says so -
        // an example a captain can copy into Shortcuts, not a thing this page
        // can run. There is no "Run" button for the same reason: nothing here
        // can invoke an App Intent on the captain's behalf, and a button that
        // pretended to would be exactly the control this page refuses to draw.
        let flowRows = GrandLineIntentCatalog.entries.prefix(3).enumerated().map { index, entry in
            SettingsRow(title: "\(index + 1). \(entry.title)",
                        description: nil,
                        control: rowLabel("Grand Line"))
        }
        let openShortcuts = HelmButton(title: "Open Shortcuts", variant: .secondary,
                                       target: self, action: #selector(openShortcutsApp))

        return [
            SettingsSection(heading: "Actions exposed to the system", aside: intentCountLabel,
                            group: SettingsGroup(rows: rows),
                            foot: Self.intentRegistrationStatusText()),
            SettingsSection(heading: "Build a shortcut",
                            aside: openShortcuts,
                            group: SettingsGroup(rows: Array(flowRows)),
                            foot: "An example: three of these actions in a row make a morning shortcut. Shortcuts is where you assemble one - Grand Line publishes the actions and does not run them for you."),
        ]
    }

    @objc private func openShortcutsApp() {
        // The system app, by its own bundle identifier rather than by a path
        // - `/System/Applications` is not where it lives on every macOS
        // version, and a missing path would open nothing silently.
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else {
            Feedback.report("Shortcuts is not available on this Mac.",
                            kind: .warning, persistence: .transient, in: view)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Whether *this* copy of the app publishes its intents to the system.
    ///
    /// A real check against the running bundle rather than a constant: the
    /// same source builds an unbundled `swift build` binary (no bundle at
    /// all, so nothing is registered) and a packaged `.app` that may or may
    /// not have had the metadata step run. GL-14: a page listing five actions
    /// while this copy publishes none would be "unknown rendered as
    /// available".
    static func intentRegistrationStatusText() -> String {
        guard let resources = Bundle.main.resourceURL,
              Bundle.main.bundleIdentifier != nil else {
            return "This copy is running unbundled (swift build / swift run), so nothing is registered with Shortcuts. The packaged app is what publishes these."
        }
        let metadata = resources.appendingPathComponent("Metadata.appintents")
        if FileManager.default.fileExists(atPath: metadata.path) {
            return "Registered with the system \u{2014} these appear in Shortcuts, Spotlight and Siri."
        }
        return "Not registered on this copy: the app bundle carries no Metadata.appintents. native/build_native_app.sh writes it only when Xcode's appintentsmetadataprocessor is present - rebuild the app on a Mac with Xcode installed to publish them."
    }

    // MARK: - Security

    private func buildSecuritySections() -> [SettingsSection] {
        securityStackHost.orientation = .vertical
        securityStackHost.alignment = .leading
        securityStackHost.spacing = 0
        securityStackHost.translatesAutoresizingMaskIntoConstraints = false

        let (idle, session) = AppLockController.configuredThresholds()
        let lockRows = [
            SettingsRow(title: "Lock when idle",
                        description: "The lock screen appears after this long with no keyboard or mouse anywhere on the Mac. Set with FM_APP_LOCK_IDLE_SECONDS.",
                        control: rowLabel(Self.durationText(idle))),
            SettingsRow(title: "Lock after a full session",
                        description: "A hard ceiling, regardless of activity. Set with FM_APP_LOCK_SESSION_SECONDS.",
                        control: rowLabel(Self.durationText(session))),
        ]

        // The vault's own settings (auto-lock, clipboard clear, Touch ID
        // unlock) are sealed **inside** the encrypted vault file, so this
        // page genuinely cannot read them without unlocking it - and
        // AGENTS.md is explicit that anything reaching the vault from outside
        // the vault page goes through the vault's own unlock. So this row
        // states what is true from here and sends the captain to the one
        // place that can change it, rather than drawing controls that would
        // need a Touch ID prompt to populate.
        let openVault = HelmButton(title: "Open Poneglyph", variant: .secondary,
                                   target: self, action: #selector(openVault))
        let vaultRows = [
            SettingsRow(title: "Vault settings live in the vault",
                        description: "Auto-lock, the clipboard-clear delay and Touch ID unlock are stored encrypted inside the vault file itself, so they are changed from Poneglyph after it is unlocked - never from here.",
                        control: openVault),
        ]

        return [
            SettingsSection(heading: "App lock", group: SettingsGroup(rows: lockRows),
                            foot: "Anything that runs while the main window is not frontmost and shows or writes your data consults the same lock (GL-09)."),
            SettingsSection(heading: "Poneglyph vault", group: SettingsGroup(rows: vaultRows)),
            SettingsSection(heading: "System", group: SettingsGroup(custom: securityStackHost,
                                                                    insets: NSEdgeInsets())),
        ]
    }

    /// Rebuilt (not only re-themed) on every status change, since the
    /// trailing control differs by status - a pill, a button, or plain text.
    private func rebuildSecuritySection() {
        for view in securityStackHost.arrangedSubviews {
            securityStackHost.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let row = sudoTouchIDRow()
        securityStackHost.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: securityStackHost.widthAnchor).isActive = true
        sudoRowHost = row
        applyTheme()
    }

    private func sudoTouchIDRow() -> SettingsRow {
        var desc = "Use your fingerprint instead of typing your password at a terminal prompt."
        let statusView: NSView
        switch sudoTouchIDStatus {
        case .checking:
            statusView = rowLabel("Checking\u{2026}")
        case .enabled:
            // The one enabled state with an action: the `pam_tid.so` line is
            // in a real `/etc/pam.d/sudo_local` this app can edit. The pill
            // stays - it states what is true - and the button sits beside it.
            let disable = HelmButton(title: isDisablingSudo ? "Disabling\u{2026}" : "Disable",
                                     variant: .secondary, target: self,
                                     action: #selector(disableSudoTouchIDClicked))
            disable.isEnabled = !isDisablingSudo
            disable.toolTip = "Remove the Touch ID line from /etc/pam.d/sudo_local (asks for your password)"
            let pair = NSStackView(views: [pillView(text: "On", colorHex: theme.ansiHex[2]), disable])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = HelmMetrics.s2
            statusView = pair
        case .enabledNixDarwin:
            // Enabled, and the same symlink-into-the-store wall the
            // not-enabled nix-darwin case hits - so the same answer, pointed
            // the other way. Deliberately no Disable button: the store is
            // read-only, and an edit that did land would be regenerated away
            // by the next rebuild.
            desc += " It is on, but this Mac is managed by nix-darwin, where /etc/pam.d/sudo_local is regenerated from your flake on every rebuild - set `security.pam.services.sudo_local.touchIdAuth = false;` in your dotfiles' configuration.nix, then run rebuild.sh."
            statusView = pillView(text: "On", colorHex: theme.ansiHex[2])
        case .enabledInSudoFile:
            // Turning this off means editing /etc/pam.d/sudo, the file Apple
            // ships and replaces on a system update. This app edits
            // sudo_local and nothing else, so it says where the line is
            // rather than offering a button that would press cleanly and
            // change nothing.
            desc += " It is on via a pam_tid.so line in /etc/pam.d/sudo itself, not /etc/pam.d/sudo_local - this app only ever edits sudo_local, so remove that line by hand to turn it off."
            statusView = pillView(text: "On", colorHex: theme.ansiHex[2])
        case .notEnabled:
            let button = HelmButton(title: isHardeningSudo ? "Enabling\u{2026}" : "Enable",
                                    variant: .primary, target: self,
                                    action: #selector(enableSudoTouchIDClicked))
            button.isEnabled = !isHardeningSudo
            statusView = button
        case .notEnabledNixDarwin:
            desc += " This Mac is managed by nix-darwin, where /etc/pam.d/sudo_local is regenerated from your flake on every rebuild - add `security.pam.services.sudo_local.touchIdAuth = true;` to your dotfiles' configuration.nix, then run rebuild.sh."
            statusView = rowLabel("Needs dotfiles change")
        case .pamNotConfigured:
            desc += " Not available on this Mac - /etc/pam.d/sudo doesn't include sudo_local."
            statusView = rowLabel("Unavailable")
        case .checkFailed(let reason):
            desc += " Could not check status: \(reason)."
            statusView = rowLabel("Unknown")
        }

        // A manual recheck for this one row: the automatic check runs once
        // per app launch (`hasCheckedSudoTouchIDOnce`), so a fix made outside
        // the app - editing dotfiles, running `rebuild.sh` in another
        // terminal - would otherwise leave this row stale until a relaunch.
        // Hidden while a check is in flight, since re-triggering one
        // mid-check would only race itself.
        let trailing: NSView
        if sudoTouchIDStatus == .checking {
            trailing = statusView
        } else {
            let refreshButton = HelmButton(symbol: "arrow.clockwise", variant: .quiet,
                                           target: self, action: #selector(recheckSudoTouchIDClicked))
            refreshButton.toolTip = "Recheck Touch ID for sudo status"
            let combined = NSStackView(views: [statusView, refreshButton])
            combined.orientation = .horizontal
            combined.alignment = .centerY
            combined.spacing = HelmMetrics.s1 + 2
            trailing = combined
        }
        let row = SettingsRow(title: "Touch ID for sudo", description: desc, control: trailing)
        row.applyTheme(theme)
        return row
    }

    @objc private func recheckSudoTouchIDClicked() { checkSudoTouchID() }

    private func checkSudoTouchID() {
        sudoTouchIDStatus = .checking
        rebuildSecuritySection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SudoTouchIDSource.checkStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sudoTouchIDStatus = status
                self.rebuildSecuritySection()
            }
        }
    }

    @objc private func enableSudoTouchIDClicked() {
        guard !isHardeningSudo, let onRunCommandTracked else {
            onRunCommand?("av harden sudo", "sudo av harden sudo")
            return
        }
        isHardeningSudo = true
        rebuildSecuritySection()
        onRunCommandTracked("av harden sudo", "sudo av harden sudo") { [weak self] _ in
            guard let self else { return }
            self.isHardeningSudo = false
            self.checkSudoTouchID()
        }
    }

    /// The reverse of `enableSudoTouchIDClicked`, and deliberately its twin:
    /// the same tracked Console tab (so macOS's own `sudo` prompt
    /// authenticates it), the same in-flight flag, and the same re-check on
    /// exit - which is what flips the row back with no second code path
    /// deciding that.
    @objc private func disableSudoTouchIDClicked() {
        let command = SudoTouchIDSource.disableCommand()
        guard !isDisablingSudo, let onRunCommandTracked else {
            onRunCommand?("Disable Touch ID", command)
            return
        }
        isDisablingSudo = true
        rebuildSecuritySection()
        onRunCommandTracked("Disable Touch ID", command) { [weak self] _ in
            guard let self else { return }
            self.isDisablingSudo = false
            self.checkSudoTouchID()
        }
    }

    @objc private func openVault() {
        onNavigate?(.poneglyph)
    }

    /// "1 hour", "5 minutes", "30 seconds" - a threshold a captain can read.
    ///
    /// Static and pure so a suite can assert the rounding without mounting
    /// the page.
    static func durationText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard whole > 0 else { return "never" }
        if whole % 3600 == 0 {
            let hours = whole / 3600
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        if whole % 60 == 0 {
            let minutes = whole / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(whole) second\(whole == 1 ? "" : "s")"
    }

    // MARK: - Backup & Restore

    private var backupMeasurements: [BackupStoreSection: (files: Int, bytes: Int, unreadable: Bool)] = [:]
    private var backupVaultMeasurement: (exists: Bool, credentials: Int, bytes: Int)?
    private var isMeasuringBackup = false

    /// Export/Import share one implementation (`BackupUI.swift`) with the
    /// Bootstrap page's "Restore Grand Line config" step - this page holds no
    /// logic of its own, only the two buttons and an honest inventory of what
    /// they would move.
    ///
    /// F24 turned that inventory from one counts line into a real per-store
    /// list, for the reason the reference's own note gives: a one-file move
    /// is only trustworthy if you can see what it leaves behind. So the two
    /// deliberate exclusions are rows on the list rather than an omission.
    private func buildBackupSections() -> [SettingsSection] {
        let exportButton = HelmButton(title: "Export\u{2026}", variant: .primary,
                                      target: self, action: #selector(exportBackupClicked))
        let importButton = HelmButton(title: "Import\u{2026}", variant: .secondary,
                                      target: self, action: #selector(importBackupClicked))
        let buttonRow = NSStackView(views: [importButton, exportButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = HelmMetrics.s2

        let summary = SettingsRow(title: "Currently saved",
                                  description: "Measuring\u{2026}",
                                  control: buttonRow)
        backupSummaryRow = summary

        backupContentsStack.orientation = .vertical
        backupContentsStack.alignment = .leading
        backupContentsStack.spacing = 0
        backupContentsStack.translatesAutoresizingMaskIntoConstraints = false

        let contentsGroup = SettingsGroup(custom: backupContentsStack, insets: NSEdgeInsets())

        return [
            SettingsSection(group: SettingsGroup(rows: [summary])),
            SettingsSection(heading: "What's in a backup", group: contentsGroup,
                            foot: "Private SSH key material never leaves the Keychain; only the metadata that points to it is exported. A restore is a merge with a preview, never a silent overwrite - nothing on this Mac is deleted by one."),
        ]
    }

    private func refreshBackupStatus() {
        let hosts = hostStore.hosts.count
        let snippets = snippetStore.snippets.count
        backupSummaryRow?.descriptionLabel?.stringValue =
            "\(hosts) host\(hosts == 1 ? "" : "s"), \(snippets) snippet\(snippets == 1 ? "" : "s"), "
            + "and everything listed below."
        rebuildBackupContents()
        measureBackupContents()
    }

    /// Walks the store roots for a file count and a size, off the main
    /// thread.
    ///
    /// Metadata only (`BackupFileArchiveBuilder.measure`), so this is a
    /// stat-per-file rather than a read - but a notebook is up to 2000 files
    /// and this runs on every visit to Settings, and "cheap enough" is
    /// exactly the reasoning behind the main-thread `gh auth token` call that
    /// used to beachball the Export button (GL-12).
    private func measureBackupContents() {
        guard !isMeasuringBackup, let roots = GrandLineServices.shared.backupRoots else { return }
        isMeasuringBackup = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var measured: [BackupStoreSection: (files: Int, bytes: Int, unreadable: Bool)] = [:]
            for section in BackupStoreSection.allCases {
                measured[section] = BackupFileArchiveBuilder.measure(root: roots.root(for: section))
            }
            // The vault is one file, and the count comes out of its plaintext
            // envelope - nothing here unlocks or decrypts anything.
            let vaultArchive = BackupVaultArchive.build(vaultFileURL: roots.vaultFile)
            let vault = (exists: vaultArchive != nil,
                         credentials: vaultArchive?.credentialCount ?? 0,
                         bytes: vaultArchive?.sealedData?.count ?? 0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMeasuringBackup = false
                self.backupMeasurements = measured
                self.backupVaultMeasurement = vault
                self.rebuildBackupContents()
            }
        }
    }

    private func rebuildBackupContents() {
        for view in backupContentsStack.arrangedSubviews {
            backupContentsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var rows: [SettingsRow] = []
        rows.append(SettingsRow(
            title: "Hosts, SSH keys, jump hosts",
            description: "\(hostStore.hosts.count) host(s) and the metadata for the keys they reference. Private key material never leaves the Keychain.",
            control: statusColumn(pillView(text: "Included", colorHex: theme.ansiHex[2]))))
        rows.append(SettingsRow(
            title: "Command snippets & dictation",
            description: "\(snippetStore.snippets.count) snippet(s), the dictation vocabulary and shortcut, and the preferences on these pages.",
            control: statusColumn(pillView(text: "Included", colorHex: theme.ansiHex[2]))))

        for section in BackupStoreSection.allCases {
            rows.append(SettingsRow(title: section.title,
                                    description: "\(section.detail). \(backupMeasurementText(for: section))",
                                    control: statusColumn(pillView(text: "Included",
                                                                    colorHex: theme.ansiHex[2]))))
        }

        rows.append(SettingsRow(
            title: "Poneglyph vault",
            description: backupVaultText(),
            // Amber, not green: "sealed" is a real caveat (the master
            // password does not travel with it), and painting it the same as
            // the rest would say there is nothing to know.
            control: statusColumn(pillView(text: "Sealed", colorHex: theme.ansiHex[3]))))

        rows.append(SettingsRow(
            title: "Terminal scrollback & session state",
            description: "Deliberately left out. Scrollback is machine-specific, and what was on a terminal is not configuration - a restore should not reopen someone else's session.",
            // A muted label rather than a pill, deliberately. Every pill here
            // goes through `HelmContrast.tintedSurface`, and AGENTS.md's
            // colour rules are explicit that washing a no-identity ink hue
            // that way produces a near-black chip - the heaviest thing on the
            // page would then be the one row that is *not* in the bundle.
            control: statusColumn(rowLabel("Excluded"))))

        // The separators belong to the group, and this stack is the group's
        // whole body - so they are drawn here rather than by `SettingsGroup`,
        // which never saw these rows.
        for (index, row) in rows.enumerated() {
            if index > 0 { backupContentsStack.addArrangedSubview(hairline(inset: row.separatorInset)) }
            backupContentsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: backupContentsStack.widthAnchor).isActive = true
            row.applyTheme(theme)
        }
        backupRows = rows
        lastPageWidth = 0
        pageWidthMayHaveChanged()
    }

    /// The rows inside `backupContentsStack`, which `SettingsGroup` does not
    /// own - kept so a re-theme and a re-wrap can still reach them.
    private var backupRows: [SettingsRow] = []
    private var hairlines: [NSView] = []

    private func hairline(inset: CGFloat) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        NSLayoutConstraint.activate([
            host.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            line.topAnchor.constraint(equalTo: host.topAnchor),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        hairlines.append(line)
        return host
    }

    /// `nil` measurement reads as "Measuring…"; an unreadable root says so
    /// (GL-21 - "could not be enumerated" is not "empty"); everything else is
    /// the real count.
    private func backupMeasurementText(for section: BackupStoreSection) -> String {
        guard GrandLineServices.shared.backupRoots != nil else {
            return "Not available until the app has finished starting up."
        }
        guard let measurement = backupMeasurements[section] else { return "Measuring\u{2026}" }
        if measurement.unreadable { return "\u{26A0} This folder could not be read, so its size is unknown." }
        if measurement.files == 0 { return "Nothing here yet." }
        return "\(measurement.files) file(s), \(SettingsController.byteText(measurement.bytes))."
    }

    private func backupVaultText() -> String {
        guard GrandLineServices.shared.backupRoots != nil else {
            return "Not available until the app has finished starting up."
        }
        guard let vault = backupVaultMeasurement else { return "Measuring\u{2026}" }
        guard vault.exists else { return "No vault on this Mac yet." }
        let count = vault.credentials < 0 ? "an unknown number of credentials" : "\(vault.credentials) credential(s)"
        return "\(count), \(SettingsController.byteText(vault.bytes)). Carried still encrypted - never re-wrapped, never readable by the export. "
            + "Restoring it needs the master password it had on the machine it came from; Touch ID does not travel."
    }

    static func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    @objc private func exportBackupClicked() {
        BackupUI.exportFlow(from: self, hostStore: hostStore, keyStore: keyStore,
                            snippetStore: snippetStore, dictationStore: dictationStore)
    }

    @objc private func importBackupClicked() {
        BackupUI.importFlow(from: self, hostStore: hostStore, keyStore: keyStore,
                            snippetStore: snippetStore, dictationStore: dictationStore) { [weak self] in
            self?.refreshFromSettings()
        }
    }

    // MARK: - Small shared pieces

    /// §6.7: the app's one chip. `ToolRowLayout.pill` corrects the label
    /// against whichever surface the chip lands on and makes it a capsule
    /// under Daylight.
    private func pillView(text: String, colorHex: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: text)
        ToolRowLayout.pill(text: text, colorHex: colorHex, into: container, label: label, theme: theme)
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)
        return container
    }

    /// The reference's `.status-col { width: 92px }`: a fixed-width,
    /// right-aligned column for a row whose trailing content is a *status*
    /// rather than a control.
    ///
    /// Without it the Backup page's one excluded row lands its plain
    /// "Excluded" label at a different x from the seven pills above it,
    /// because a label is narrower than a chip - visible in a real render.
    ///
    /// A required fixed width is safe at this size specifically: gotcha (13)
    /// is about a content constraint becoming a *floor* on the window, and 84
    /// is two orders of magnitude under the 680 this page's own column is
    /// already capped at.
    private func statusColumn(_ view: NSView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 84),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.caption()
        muted(label)
        return label
    }

    // MARK: - Actions

    @objc private func uiScaleClicked(_ sender: NSButton) {
        guard ChromeTextScale.steps.indices.contains(sender.tag) else { return }
        ChromeTextScale.shared.setScale(ChromeTextScale.steps[sender.tag].scale)
        refreshFromSettings()
    }

    @objc private func fontPresetClicked(_ sender: NSButton) {
        let target = CGFloat(sender.tag)
        onFontSizeStep?(target - AppSettings.shared.fontSize)
        refreshFromSettings()
    }

    @objc private func autoReconnectToggled() {
        AppSettings.shared.autoReconnect = autoReconnectSwitch.isOn
    }

    @objc private func notifyToggled() {
        let on = notifySwitch.isOn
        AppSettings.shared.notifyOnNeedsDecision = on
        FleetNotifier.shared.setEnabled(on)
    }

    // MARK: - Shared field plumbing

    /// Placeholder and chrome are `HelmTextField`'s own - this only wires the
    /// value back to `AppSettings`, and wires all three of `target`, `action`
    /// and `delegate` (gotcha (19)).
    private func configure(_ field: NSTextField) {
        field.target = self
        field.action = #selector(textFieldChanged(_:))
        field.delegate = self
    }

    @objc private func textFieldChanged(_ sender: NSTextField) {
        // The Google controls are checked before the switch because the
        // sender is one of a `HelmRevealableSecretField`'s two halves, never
        // the control itself - a `case` on the property would match neither.
        // Both fields write one stored pair, so either one committing
        // re-reads both, which is what makes the editing order irrelevant.
        if gmailClientIDField.owns(sender) || gmailClientSecretField.owns(sender) {
            gmailClientChanged()
            return
        }
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender {
        case shellCwdField:
            AppSettings.shared.defaultShellCwd = value.isEmpty ? nil : value
        default:
            break
        }
    }

    // MARK: - Sync

    private func refreshFromSettings() {
        guard isViewLoaded else { return }
        shellCwdField.stringValue = AppSettings.shared.defaultShellCwd ?? ""
        for (index, step) in ChromeTextScale.steps.enumerated() {
            uiScaleButtons[index]?.variant =
                abs(ChromeTextScale.shared.scale - step.scale) < 0.001 ? .primary : .secondary
        }
        for size in [12, 13, 14, 16] {
            fontPresetButtons[size]?.variant =
                Int(AppSettings.shared.fontSize) == size ? .primary : .secondary
        }
        autoReconnectSwitch.isOn = AppSettings.shared.autoReconnect
        notifySwitch.isOn = AppSettings.shared.notifyOnNeedsDecision
        morningBriefingSwitch.isOn = AppSettings.shared.morningBriefingEnabled
        dailyReviewSwitch.isOn = AppSettings.shared.dailyReviewEnabled
        dailyReviewCalendarSwitch.isOn = AppSettings.shared.dailyReviewCalendarEnabled
        compactModeSwitch.isOn = AppSettings.shared.compactModeEnabled
        compactDockSwitch.isOn = AppSettings.shared.compactModeHidesDockIcon
        compactBadgeSwitch.isOn = AppSettings.shared.compactModeBadgesOverdueCount
        followSystemSwitch.isOn = AppSettings.shared.followSystemAppearance
        refreshSystemPairPopUps()
        refreshGmailSection()
        refreshCaptureControls()
        syncDependentRows()

        rebuildAppearanceGrid()
        rebuildSecuritySection()
        refreshBackupStatus()
        refreshToolbar()
        applyTheme()
    }

    /// The repaint-only half of `refreshFromSettings` (GL-24). Re-reads
    /// nothing off disk, shells out to nothing, and rebuilds only what
    /// genuinely carries theme-derived colour it cannot re-derive itself -
    /// the theme grid's own cards, which draw every palette.
    private func repaintForTheme() {
        guard isViewLoaded else { return }
        rebuildAppearanceGrid()
        applyTheme()
    }

    private func applyTheme() {
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        // The band and its edge. `sidePanelFill` is derived from the page
        // ground rather than blended out of the card, because
        // `chromeBackgroundHex == backgroundHex` in several palettes and a
        // card/ground blend is the ground in those - see that method's own
        // note. Fill only: nothing here is drawn as text.
        sidebarPanel.layer?.backgroundColor = HelmTheme.sidePanelFill(theme).cgColor
        sidebarEdge.layer?.backgroundColor = HelmTheme.sidePanelEdge(theme).cgColor

        sidebar.applyTheme(theme)
        searchField.applyTheme(theme)
        identityAvatar.layer?.cornerRadius = HelmMetrics.tileBase / 2
        identityAvatar.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor
        identityInitial.textColor = HelmContrast.legibleOn(fill: HelmTheme.nsColor(theme.accentHex),
                                                   preferring: .white)
        identityName.textColor = ink
        toolbarTitle.textColor = ink
        toolbarLocalIcon.contentTintColor = muted

        for page in pages.values {
            page.hero.applyTheme(theme)
            for section in page.sections { section.applyTheme(theme) }
        }
        for row in backupRows { row.applyTheme(theme) }
        sudoRowHost?.applyTheme(theme)
        for card in themeCards { card.applyTheme(theme) }
        // Every recorder on this page, Capture's included - a
        // `KeyChordRecorderView` paints its own fill, border and ink from the
        // theme and renders as an unfilled rectangle with default ink until
        // this runs. Missed once while Capture's page was being added, and
        // nothing failed: the control worked perfectly and looked wrong.
        for recorder in shortcutRecorders.values + [captureShortcutRecorder].compactMap({ $0 }) {
            recorder.applyTheme(theme)
        }
        for toggle in [autoReconnectSwitch, notifySwitch, morningBriefingSwitch,
                       dailyReviewSwitch, dailyReviewCalendarSwitch, followSystemSwitch,
                       compactModeSwitch, compactDockSwitch, compactBadgeSwitch,
                       gmailCalendarSwitch] {
            toggle.applyTheme(theme)
        }
        themeFilterTabs?.applyTheme(theme)
        // The two popups are not in that loop: `HelmPopUpButton` observes the
        // theme itself, so a second push from here would be a duplicate.

        // Labels this file created outside a `SettingsRow` - every muted
        // caption on the page. Sections that rebuild rather than re-theme
        // register a fresh one each time, so the ones whose view is gone are
        // dropped; `muted(_:)` tints at creation too, so anything dropped
        // early is still correct.
        mutedLabels.removeAll { $0.superview == nil && $0 !== noMatchLabel }
        for label in mutedLabels { label.textColor = muted }

        for hairlineView in hairlines {
            hairlineView.layer?.backgroundColor = (theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.hairRow)
                : line.withAlphaComponent(0.5)).cgColor
        }
    }

    // MARK: - Self-test hooks (GL-27)

    #if FM_SELFTESTS
    /// The left navigation column, so a suite can read its selection and
    /// drive a real row press rather than only calling `select(_:)`.
    var debugSidebar: HelmPageSidebar { sidebar }
    /// The toned band behind the nav column and the hairline closing it, so a
    /// suite can find where to sample a real render rather than guessing at
    /// the page's own geometry.
    var debugSidebarPanel: NSView { sidebarPanel }
    /// The detail column's own content stack, in the page root's coordinates -
    /// what a render probe needs in order to sample page ground that is
    /// genuinely outside every card.
    var debugPageContainerFrameInRoot: NSRect {
        pageContainer.convert(pageContainer.bounds, to: view)
    }
    /// The page header (the breadcrumb row and "Saved on this Mac"), in the
    /// page root's coordinates. Paired with `debugPageContainerFrameInRoot`
    /// this is the alignment `fm/grandline-settings-alignment-regression-fix`
    /// exists to hold: the header ends where the column it heads ends.
    var debugToolbarFrameInRoot: NSRect {
        toolbar.convert(toolbar.bounds, to: view)
    }
    var debugSidebarEdge: NSView { sidebarEdge }
    var debugSearchField: HelmSearchField { searchField }
    var debugSelectedCategory: Category { selectedCategory }
    /// Which categories the sidebar currently offers, in its own order -
    /// what the search filter actually did.
    var debugVisibleCategories: [Category] {
        sidebar.debugRowIDs.compactMap { Category(rawValue: $0) }
    }
    var debugNoMatchVisible: Bool { !noMatchLabel.isHidden }
    /// Filter the page list the way typing in the field does, without a real
    /// field editor - the search *behaviour*, which is what a headless-safe
    /// half of the suite asserts.
    func debugSetSearchText(_ text: String) {
        searchField.stringValue = text
        applySearchFilter(text)
    }
    var debugToolbarTitle: String { toolbarTitle.stringValue }
    var debugCanGoBack: Bool { backButton.isEnabled }
    var debugCanGoForward: Bool { forwardButton.isEnabled }
    func debugGoBack() { goBack() }
    func debugGoForward() { goForward() }
    var debugHistory: [Category] { history }

    /// Every section on every page, not only the mounted one.
    var debugSections: [SettingsSection] {
        Category.allCases.flatMap { pages[$0]?.sections ?? [] }
    }
    func debugSections(in category: Category) -> [SettingsSection] { pages[category]?.sections ?? [] }
    /// Every row on every page, which is what "no setting became
    /// unreachable" is asserted against.
    var debugRows: [SettingsRow] {
        debugSections.flatMap { $0.group.rows } + backupRows
    }
    /// How many pages actually reached the detail pane's view tree - one,
    /// always, and the other seven deliberately detached (gotcha (15)).
    var debugPagesInTree: Int {
        pages.values.filter { $0.container.isDescendant(of: pageContainer) }.count
    }

    /// Every section's own `HelmCard`, across all eight pages.
    ///
    /// The page's structural unit used to be "a card per topic" and is now
    /// "a section per idea, each holding one card of rows" - so the suites
    /// that assert reach, partitioning and one-column geometry ask for these
    /// rather than for the old card list. Exactly one card per section, so
    /// the count is the section count.
    var debugGroupCards: [HelmCard] { debugSections.map { $0.group.card } }
    func debugGroupCards(in category: Category) -> [HelmCard] {
        debugSections(in: category).map { $0.group.card }
    }
    /// The cards currently in the detail pane, in the order it stacks them.
    var debugMountedGroupCards: [HelmCard] {
        guard let page = pages[selectedCategory] else { return [] }
        return page.sections.map { $0.group.card }
    }
    /// How many of the selected page's cards actually reached the view tree.
    /// Guards the "every card exists and none of them is on screen"
    /// regression the detail-pane rebuild could reintroduce.
    var debugGroupCardsInTree: Int {
        debugMountedGroupCards.filter { $0.isDescendant(of: pageContainer) }.count
    }
    var debugMountedCategory: Category? { mountedCategory }

    /// The theme grid's cards, in grid order.
    var debugThemeCards: [SettingsThemeCard] { themeCards }
    var debugThemeFilterTabs: HelmSegmentedTabs { themeFilterTabs }
    func debugSetThemeFilter(_ id: String) {
        guard let filter = ThemeFilter(rawValue: id) else { return }
        themeFilter = filter
        rebuildAppearanceGrid()
    }
    /// One entry per grid row, giving the column count `.fillEqually`
    /// actually divided that row into - so a suite can assert the grid's
    /// density is a pure function of layout width and never of which theme
    /// happens to be selected.
    var debugAppearanceGridColumnCounts: [Int] {
        appearanceContainer.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.count }
    }
    var debugThemeNameLabels: [NSTextField] {
        themeCards.map(\.nameLabel).filter { $0.window != nil || $0.superview != nil }
    }

    var debugFollowSystemSwitch: HelmToggle { followSystemSwitch }
    var debugSystemLightPopUp: HelmPopUpButton { systemLightPopUp }
    var debugSystemDarkPopUp: HelmPopUpButton { systemDarkPopUp }
    /// The rows that follow a given switch, so a suite can assert the
    /// reference's `data-dep` dimming against the real registry rather than
    /// re-deriving which rows ought to be in it.
    func debugDependentRows(of key: String) -> [SettingsRow] {
        guard let dependency = Dependency(rawValue: key) else { return [] }
        return dependentRows[dependency] ?? []
    }

    var debugGmailRows: [GmailAccountRow] {
        GoogleAccountSlot.allCases.compactMap { gmailRows[$0] }
    }
    var debugGmailStatusText: String { gmailStatusSection?.footLabel?.stringValue ?? "" }
    var debugGmailCalendarSwitch: HelmToggle { gmailCalendarSwitch }
    var debugGmailClientIDField: HelmRevealableSecretField { gmailClientIDField }
    var debugGmailClientSecretField: HelmRevealableSecretField { gmailClientSecretField }
    /// Calls the commit directly. Deliberately *not* a stand-in for the
    /// field's own wiring: it reaches past both the Return action and the
    /// end-editing delegate, which is exactly how
    /// `fm/grandline-gmail-oauth-field-not-saving` shipped a field that only
    /// ever committed on Return.
    func debugCommitGmailClient() { gmailClientChanged() }
    func debugRefreshGmail() { refreshGmailSection() }

    var debugAutoReconnectSwitch: HelmToggle { autoReconnectSwitch }
    var debugNotifySwitch: HelmToggle { notifySwitch }
    var debugMorningBriefingSwitch: HelmToggle { morningBriefingSwitch }
    var debugDailyReviewSwitch: HelmToggle { dailyReviewSwitch }
    var debugDailyReviewCalendarSwitch: HelmToggle { dailyReviewCalendarSwitch }
    var debugCompactModeSwitch: HelmToggle { compactModeSwitch }
    var debugCompactDockSwitch: HelmToggle { compactDockSwitch }
    var debugCompactBadgeSwitch: HelmToggle { compactBadgeSwitch }
    /// Every toggle on the page, in page order. A suite asserts the count, so
    /// a toggle added without coming here fails by name.
    var debugToggles: [HelmToggle] {
        [followSystemSwitch, autoReconnectSwitch, notifySwitch,
         morningBriefingSwitch, dailyReviewSwitch, dailyReviewCalendarSwitch,
         gmailCalendarSwitch, compactModeSwitch, compactDockSwitch, compactBadgeSwitch]
    }
    #endif
}

extension SettingsController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        textFieldChanged(field)
    }
}

/// A plain `NSView` used as a scroll view's document view puts y=0 at the
/// *bottom* (AppKit's default, unflipped coordinate space), so a fresh layout
/// can present as scrolled to the end. Flipping it is the standard fix - y=0
/// becomes the top, matching how the content's own constraints are written.
///
/// Not file-private: `HostEditorController`'s scroll view hits the same issue
/// and shares this type rather than keeping a second copy.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension Array {
    /// Split into fixed-size groups, last group possibly shorter. Used by
    /// `HelmResponsiveGrid` to wrap items into bounded-width rows.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// An `NSStackView` that tells its owner when it has been laid out.
///
/// A view whose *content* depends on its own width has to hear about its own
/// layout pass, and a view controller's `viewDidLayout` is not that signal
/// for a child controller (see `SettingsController.containerWidthMayHaveChanged`,
/// and `ToolsController`'s note before it) - while the window resize
/// notification only fires on a resize, never on a first visit at whatever
/// size the window was already at.
///
/// Deliberately a closure rather than a delegate protocol: there is one
/// listener, it is the view's own controller, and a protocol for one call
/// would be more ceremony than the thing it describes.
final class LayoutReportingStack: NSStackView {

    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
