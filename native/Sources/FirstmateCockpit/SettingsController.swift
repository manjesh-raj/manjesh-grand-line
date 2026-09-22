// Manjesh Grand Line - native macOS app.
//
// The native Settings panel (Fix 3) - rebuilt to match the richer web
// cockpit layout (`backend/static/index.html`'s Settings screen): icon +
// title section headers, generous spacing, and grouped cards rather than a
// flat list of rows. Three sections (Sign-in is skipped - native has no
// login):
//
//   - Connection: the working-directory chooser. E1 removed the mirror-target
//     field and its `TmuxMirror.listSessions()` "Detect" tmux-pane picker
//     along with the whole Mirror abstraction (both symbols are gone from the
//     tree - this is history, not a live pointer); `fm/grand-line-remove-
//     firstmate-mirror` later removed the herdr-attached tab that
//     abstraction had been simplified down to, outright - see that task's
//     PR for what went and why.
//   - Appearance: the theme picker (12 as of cockpit-theme-overhaul) as a
//     wrapping grid of preview cards (colour-bar swatch + name + checkmark),
//     reusing `HelmTheme.allThemes` - the same source of truth the topbar's
//     `ThemeMenu` picker uses.
//   - Terminal: font-size presets (12/13/14/16, routed through
//     `ConsoleController.stepFontSize` via `onFontSizeStep` as before), plus
//     two toggles with real behaviour behind them: "Reconnect automatically"
//     (`AppSettings.autoReconnect`, read by `ConsoleController.
//     processTerminated`) and "Bell & notifications" (`AppSettings.
//     notifyOnNeedsDecision`, driving `FleetNotifier`).
//
// Like before, fields persist immediately on change rather than batching
// into a Save button.

import AppKit

final class SettingsController: NSViewController, DaylightDrillActions {

    /// One row of the page's left navigation column, and the set of cards its
    /// detail pane shows.
    ///
    /// `fm/grandline-settings-page-sidebar-redesign`. This page used to be one
    /// continuously-scrolling column of ten cards, which is how it grew: every
    /// feature that needed a preference added a card to the bottom, and the
    /// captain ended up scrolling past the theme grid to reach Backup. The
    /// shape is now the one macOS System Settings uses - a category list on
    /// the left, one category's cards on the right.
    ///
    /// **The cards themselves did not change.** A category is a grouping of
    /// the existing `HelmCard`s and nothing else, which is what keeps this a
    /// navigation change: every toggle, picker and button is the same object,
    /// built by the same `build*Section()` method, wired to the same action.
    ///
    /// The grouping is by *what the captain came here to change*, not by
    /// which feature shipped it:
    ///
    ///   - `.terminal` holds Connection, Terminal and Terminal Shortcuts.
    ///     All three are "how a terminal tab opens and behaves"; splitting the
    ///     working directory away from the font size would make the captain
    ///     visit two panes to set up one tab.
    ///   - `.briefings` holds Morning briefing and Daily review, which are two
    ///     cards of the same kind - what Fleet generates for you each morning
    ///     - and were already written as siblings (see each card's own comment
    ///     at its construction site).
    ///   - Every other card is its own category, because each is already the
    ///     only thing of its kind on the page.
    enum Category: String, CaseIterable {
        case appearance
        case terminal
        case briefings
        /// `fm/grandline-overview-layout-fix-gmail-settings`: Google sign-in
        /// for up to two accounts. Its own category rather than a card under
        /// `.briefings`, even though its one consumer today is the daily
        /// review's calendar column - it is an *account* connection, which is
        /// the thing the captain comes here to change, and a second consumer
        /// would not move it.
        case gmail
        case menuBar
        case intents
        case security
        case backup

        /// The sidebar row's label, and the drill header's subtitle.
        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .terminal: return "Terminal"
            case .briefings: return "Briefings"
            case .gmail: return "Gmail"
            case .menuBar: return "Menu bar"
            case .intents: return "Shortcuts & Siri"
            case .security: return "Security"
            case .backup: return "Backup"
            }
        }

        /// The row's leading glyph. Each one is the symbol its own card
        /// header already carries, so the nav row and the card it reveals are
        /// visibly the same thing.
        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .terminal: return "terminal"
            case .briefings: return "sparkles"
            case .gmail: return "envelope"
            case .menuBar: return "menubar.rectangle"
            case .intents: return "sparkle"
            case .security: return "lock.shield"
            case .backup: return "tray.and.arrow.up.fill"
            }
        }
    }

    /// Set by `AppShellController` - "re-read my subtitle". The drill header
    /// belongs to the shell; a page writing into it directly is how two owners
    /// of one view start disagreeing.
    var onDrillSubtitleChanged: (() -> Void)?

    // MARK: Drill header (Daylight §6.4)

    /// Nothing. Every action on this page belongs to one card - Detect to
    /// Connection, Export/Import to Backup - and none of them is the *page's*
    /// primary action, so hoisting any one of them into the header would
    /// promote it over its five siblings for no reason.
    var drillHeaderActions: [NSView] { [] }

    /// §6.4's live subtitle - and the home of what the page's own caption used
    /// to say.
    ///
    /// That caption read "Connection, appearance, and terminal - stored
    /// locally on this machine", sitting one row under a drill header already
    /// reading "Settings / Connection, appearance, terminal, security and
    /// backup": the duplicate-title defect §6.4 exists to remove, and the
    /// same one Review and Health were corrected for in slices 1 and 2. The
    /// label is deleted; the one fact it carried that the header did not - that
    /// none of this leaves the machine - is here, alongside a real number this
    /// page owns.
    ///
    /// It now leads with the selected category, which is what makes the
    /// shell's own header read "Settings / Appearance" the way the reference
    /// mockup does - the page has sub-navigation, and the header is where a
    /// captain reads where they are. The locality fact stays: it is the one
    /// thing this page says that the header otherwise would not, and it is
    /// true of every category rather than of the one being shown.
    var drillHeaderSubtitle: String? {
        "\(selectedCategory.title) \u{00B7} everything here is stored locally on this machine"
    }

    /// The four stores the "Backup & Restore" card exports from / imports
    /// into (`BackupUI.swift`) - injected so this controller doesn't need any
    /// persistence logic of its own, matching how `onPresentHostEditor`
    /// keeps `AppShellController` ignorant of `HostStore`.
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

    /// The Terminal section's font-size presets. Wired by the app delegate to
    /// `ConsoleController.stepFontSize`, since this panel never holds a
    /// direct reference to the console.
    var onFontSizeStep: ((CGFloat) -> Void)?

    /// The Security card's "Enable" action, requiring a `sudo` prompt - wired
    /// by the app delegate to the same `AppShellController.runInConsole`
    /// Bootstrap's own provisioning actions use (cockpit-settings-sudo-
    /// touchid), never a silent background process.
    var onRunCommand: ((String, String) -> Void)?

    /// Same wiring as `onRunCommand`, but with a completion callback so the
    /// row can re-check status once the Console tab's `av harden sudo`
    /// actually exits, rather than on a fixed timer.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private var theme: HelmTheme = ThemeManager.shared.theme

    private var sudoTouchIDStatus: SudoTouchIDStatus = .checking
    private var isHardeningSudo = false
    private var isDisablingSudo = false

    // Connection
    private let shellCwdField = HelmTextField(placeholder: "~ (Home)")

    // Appearance
    private let appearanceContainer = LayoutReportingStack()

    // Terminal
    private var fontPresetButtons: [Int: HelmButton] = [:]
    /// Keyed by index into `ChromeTextScale.steps` (GL-32).
    private var uiScaleButtons: [Int: HelmButton] = [:]
    /// §6.9's toggle. `HelmToggle` renders the prototype's pill under Daylight
    /// and keeps a real `NSSwitch` on the other twelve palettes - see that
    /// class's own header for why the fallback is deliberate rather than
    /// transitional.
    private let autoReconnectSwitch = HelmToggle()
    private let notifySwitch = HelmToggle()
    /// F12's opt-in. Off by default - see `AppSettings.morningBriefingEnabled`.
    private let morningBriefingSwitch = HelmToggle()
    /// F20's card. **On** by default, unlike F12's - see
    /// `AppSettings.dailyReviewEnabled` for why the two differ.
    private let dailyReviewSwitch = HelmToggle()
    /// F20's calendar column, which is the half that needs consent.
    private let dailyReviewCalendarSwitch = HelmToggle()
    /// F22's three. Off by default - see `AppSettings.compactModeEnabled` and
    /// its two neighbours for why each one is.
    private let compactModeSwitch = HelmToggle()
    private let compactDockSwitch = HelmToggle()
    private let compactBadgeSwitch = HelmToggle()

    /// Every section card, keyed by the category whose detail pane shows it,
    /// in the order that pane stacks them.
    ///
    /// Built once in `loadView` and never rebuilt: navigating between
    /// categories reparents cards, it does not recreate them, so a toggle the
    /// captain flipped is the same object whichever pane it is currently in.
    private var cardsByCategory: [Category: [HelmCard]] = [:]

    /// Every section card in reading order, which is the concatenation of
    /// `cardsByCategory` over `Category.allCases`. Separate from `cards` (the
    /// re-theming registry) because that list is append-on-create and says
    /// nothing about arrangement.
    private var cardsInOrder: [HelmCard] = []

    /// The page's left navigation column - one row per `Category`.
    ///
    /// The shared component, not a second copy (AGENTS.md's component index):
    /// `HelmPageSidebar` already carries the row's `HoverHighlightView`
    /// hover/press/focus-ring treatment, GL-16's radio-button role for a
    /// one-of-many filter, the accent-wash selected fill and the corrected
    /// selected ink. A count would claim each category holds some number of
    /// things, which is not true of a settings pane, so every row is built
    /// with `showsCount: false`.
    private let sidebar = HelmPageSidebar()

    /// The detail pane's own vertical stack. Holds exactly the selected
    /// category's cards.
    private let cardsContainer = NSStackView()

    /// Which category's cards `cardsContainer` currently holds, so a resize
    /// or a theme change that did not move the selection costs nothing.
    private var mountedCategory: Category?

    private var selectedCategory: Category = .appearance

    /// How wide the detail pane's card column is allowed to get.
    ///
    /// A cap, not a width. The page used to answer a wide window by splitting
    /// its ten cards into two columns; with a category on screen at a time
    /// there are rarely enough cards for a second column to be anything but a
    /// ragged gap, so the detail pane is one column and simply stops widening
    /// - the same answer System Settings gives, and the reason a 1500pt
    /// window does not render a 1200pt-wide row with a toggle stranded at its
    /// far edge.
    ///
    /// Required is safe here **because it is a maximum** (gotcha (17)'s
    /// footnote to gotcha (13)): a `<=` can never be a floor on how narrow
    /// the window may get, which a required `==` or `>=` at this width would
    /// be.
    private static let detailMaxWidth: CGFloat = 900

    /// Every `HelmCard` on this page, re-themed together. The card owns its own
    /// header icon tile and subtitle label, so neither needs a registry here.
    private var cards: [HelmCard] = []

    /// Row containers using the shared `HoverHighlightView` hover helper -
    /// re-colored on every theme change alongside `cards`.
    private var hoverRows: [HoverHighlightView] = []

    /// Fix 4: kept so `viewWillAppear` can force the scroll position back to
    /// the top on every visit - see `FlippedView` below for why a fresh
    /// layout can otherwise land scrolled to the bottom.
    private var scrollView: NSScrollView!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        // GL-24: a theme observer repaints - it never fetches. This used to
        // call `refreshFromSettings()`, which synchronously shells out to
        // `tmux list-panes` and rebuilds the appearance grid, on *every* theme
        // change whether or not Settings was even the visible destination.
        // `repaintForTheme()` is the repaint-only half.
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.repaintForTheme()
        }

        let connection = card(icon: "network", tint: .info, title: "Connection", subtitle: "Where new terminal tabs open", content: buildConnectionSection())
        let appearance = card(icon: "paintpalette", tint: .violet, title: "Appearance", subtitle: "\(HelmTheme.allThemes.count) Helm themes, light and dark", content: buildAppearanceSection())
        let terminal = card(icon: "terminal", tint: .warn, title: "Terminal", subtitle: "Font size and behavior", content: buildTerminalSection())
        // Immediately after Terminal, and its own card rather than four more
        // rows inside that one: these are nine bindings with a recorder each,
        // which is a different kind of thing from a font size and two
        // toggles, and burying them under "Font size and behavior" would make
        // the card's own subtitle untrue.
        let shortcuts = card(icon: "command", tint: .accent, title: "Terminal Shortcuts",
                             subtitle: "Move between tabs, and split a terminal into panes",
                             content: buildTerminalShortcutsSection())
        // F12. Its own card rather than a fourth row inside Terminal: this is
        // not a terminal preference, it is the one place in the app that opts
        // into a daily `claude -p` call, and the card's subtitle is where that
        // gets said.
        let briefing = card(icon: "sparkles", tint: .accent, title: "Morning briefing",
                            subtitle: "One generated summary of your fleet, PRs, tasks, drift and quota",
                            content: buildMorningBriefingSection())
        // F20. Its own card beside F12's for the same reason that one has
        // one: they are two different briefings over two different sets of
        // data, and a captain turning one off usually wants the other left
        // alone.
        let dailyReview = card(icon: "sun.max", tint: .accent, title: "Daily review",
                               subtitle: "Your own day on Fleet - tasks due, follow-ups, calendar, board and reading list",
                               content: buildDailyReviewSection())
        // F22. Its own card rather than three rows inside Appearance, on the
        // same reasoning F12's briefing card records: this is not a look-and-
        // feel preference, it is a switch that hides the main window and
        // changes what the menu bar contains, and the card's subtitle is
        // where that gets said. It sits immediately before Security because
        // both are about how the app behaves when nobody is looking at it.
        let compact = card(icon: "menubar.rectangle", tint: .info, title: "Compact mode",
                           subtitle: "Live in the menu bar, with no main window",
                           content: buildCompactModeSection())
        // F21. Its own card rather than rows inside Security: these are not
        // toggles, they are five actions this app publishes to the rest of the
        // system, and the one thing a captain needs from this card is to see
        // what those five are before wiring one into a shortcut - especially
        // the guarded one.
        let gmail = card(icon: "envelope", tint: .violet, title: "Gmail",
                         subtitle: "Sign in to Google for work, for personal, for both, or for neither",
                         content: buildGmailSection())
        let intents = card(icon: "sparkle", tint: .info, title: "Shortcuts & Siri",
                           subtitle: "Five actions Siri, Shortcuts, Spotlight and Raycast can run",
                           content: buildIntentsSection())
        let security = card(icon: "lock.shield", tint: .violet, title: "Security", subtitle: "System-level convenience toggles", content: buildSecuritySection())
        // F1 / GL-11's Health card moved off this page entirely, onto its own
        // rail destination (`fm/grandline-health-sidebar-move`,
        // `HealthController.swift`) - the same correction F11's Schedules
        // card already got. Backup & Restore is the last card here now.
        let backup = card(icon: "tray.and.arrow.up.fill", tint: .info, title: "Backup & Restore", subtitle: "Move saved hosts, snippets, and preferences between machines", content: buildBackupSection())

        // The category map is the page's structure now, and `cardsInOrder`
        // is derived from it so the two can never disagree about which cards
        // exist. Reading order within a category is the order the cards were
        // built in above.
        cardsByCategory = [
            .appearance: [appearance],
            .terminal: [connection, terminal, shortcuts],
            .briefings: [briefing, dailyReview],
            .gmail: [gmail],
            .menuBar: [compact],
            .intents: [intents],
            .security: [security],
            .backup: [backup],
        ]
        cardsInOrder = Category.allCases.flatMap { cardsByCategory[$0] ?? [] }

        let stack = cardsContainer
        stack.orientation = .vertical
        stack.alignment = .leading
        // 14 - unchanged from the flat stack this replaced, so a captain on any
        // of the twelve pre-Daylight palettes sees the same page they always
        // did.
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // `leading ==` plus `trailing <=` plus a required width cap, never a
        // required `==` width tie (gotcha (3)): the cap is what stops a
        // 1500pt window rendering a 1200pt-wide settings row, and the
        // inequality is what stops the cap becoming the window's own frame.
        let widthCap = stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.detailMaxWidth)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            widthCap,
        ])
        // "And otherwise be as wide as you are allowed to be." Below
        // `NSLayoutPriorityWindowSizeStayPut` (500), so it can never widen
        // the window (gotcha (13)); above the stack's own content, so the
        // column fills the pane rather than shrink-wrapping onto its widest
        // card.
        let widthGrow = stack.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                        constant: -HelmMetrics.pageGutter)
        widthGrow.priority = HelmDaylightPriority.contentTie
        widthGrow.isActive = true

        buildSidebar()
        rebuildDetailPane()

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            // **The nav column sits outside the scroll view**, the same
            // arrangement `SchedulesController` and `CredentialVaultController`
            // use and for the same reason: it is navigation, so scrolling a
            // long category (Terminal Shortcuts is nine rows) must not carry
            // the category list off the top of the page with it.
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                             constant: HelmMetrics.pageGutter),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                            constant: -HelmMetrics.pageGutter),
        ])
        NSLayoutConstraint.activate([
            // **Measured from the page, not from the column's trailing edge**,
            // and the difference is visible. `HelmPageSidebar`'s own width
            // constraint sits at `contentTie` (499) so it can never be a
            // window-width floor (gotcha (13)), which means it yields to
            // anything that outranks it - and it also merely *ties* with
            // another 499 constraint rather than beating it. This page's
            // detail column is capped at `detailMaxWidth`, so at a wide
            // window there is real slack in the row, and with the scroll
            // view's leading tied to `sidebar.trailingAnchor` Auto Layout
            // resolved that slack by widening the column: measured at a
            // 1400pt window, the nav rows rendered 303pt wide against the
            // component's own 208. Pinning the scroll view to the page by a
            // constant leaves the column's width uncontested, and the slack
            // lands where it belongs - to the right of the detail pane.
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                            constant: HelmMetrics.pageGutter + HelmPageSidebar.width
                                                + HelmMetrics.s5 - HelmMetrics.pageGutter),
            sidebar.trailingAnchor.constraint(lessThanOrEqualTo: scroll.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // AGENTS.md gotcha #4: pin the document view to the *clip*
            // view, never the outer scroll view. With "Show scroll bars:
            // Always" (the default with a mouse attached) a non-overlay
            // vertical scroller reserves a real ~15pt track that narrows the
            // clip view without narrowing `scroll`'s own frame, so pinning to
            // `scroll.widthAnchor` renders the content's trailing edge
            // underneath that track.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        // The theme grid's column count now comes from `appearanceContainer`'s
        // real width (Phase 7, see `rebuildAppearanceGrid`), so it has to be
        // recomputed when that width changes. Same hook and same reasoning as
        // `ToolsController.containerWidthMayHaveChanged`: a live window resize
        // does not reliably re-invoke this child view controller's own
        // `viewDidLayout()` (only the window's own content view controller is
        // guaranteed that), so listen for the window's resize notification.
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(containerWidthMayHaveChanged),
                                              name: NSWindow.didResizeNotification,
                                              object: nil)

        refreshFromSettings()
    }

    /// The container width the theme grid was last laid out against, so a
    /// resize that does not actually change it costs nothing.
    private var lastAppearanceGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged() {
        // Only while this destination is the visible one - every destination is
        // a permanently mounted, `isHidden`-toggled child of
        // `AppShellController`, so an un-gated handler here would rebuild this
        // grid on every resize no matter which page the captain is looking at
        // (the measured regression `fm/cockpit-tools-yaml-quotes-diff-perf`
        // fixed on the Tools page).
        guard !view.isHidden else { return }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        layoutDidChangeWidths()
        appearanceGridWidthMayHaveChanged()
    }

    // MARK: Navigation (the category list and the detail pane)

    /// Build the left column, once.
    ///
    /// Declarative (`setSections`) rather than the append API, because the
    /// component's declarative path is the one that carries a selection
    /// across a rebuild - and because one array here is easier to read
    /// against `Category.allCases` than seven `appendRow` calls.
    private func buildSidebar() {
        sidebar.setSections([
            HelmPageSidebar.Section(header: "Settings", rows: Category.allCases.map {
                HelmPageSidebar.Row(id: $0.rawValue, indicator: .symbol($0.symbol),
                                    title: $0.title, showsCount: false)
            })
        ])
        sidebar.select(selectedCategory.rawValue)
        sidebar.onSelect = { [weak self] id in
            guard let self, let category = Category(rawValue: id) else { return }
            self.select(category)
        }
        sidebar.applyTheme(theme)
    }

    /// Move the detail pane to `category`.
    ///
    /// The sidebar has already moved its own selection by the time its
    /// `onSelect` reaches here (a `.filter` row does that itself), so this is
    /// also the path a programmatic selection takes and `sidebar.select` is
    /// idempotent on the row that is already selected.
    func select(_ category: Category) {
        guard selectedCategory != category else { return }
        selectedCategory = category
        sidebar.select(category.rawValue)
        rebuildDetailPane()
        // The shell owns the drill header; this page only says "re-read me"
        // (see `onDrillSubtitleChanged`). Without this the header would keep
        // naming whichever category the captain arrived on.
        onDrillSubtitleChanged?()
        // A category the captain has never opened starts at its own top, and
        // one they scrolled through last time should not hand its offset to
        // the next one - the pane is a different document now.
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    /// Put exactly the selected category's cards in the detail pane.
    ///
    /// **Reparenting, never rebuilding.** Every card is constructed once in
    /// `loadView` and lives for the controller's lifetime, so a toggle keeps
    /// its state, its target/action and its place in `refreshFromSettings`'s
    /// sync whether or not its card is currently on screen. What changes here
    /// is only which of them `cardsContainer` holds.
    ///
    /// Leaving the other categories' cards *out of the view tree* is also
    /// what makes this cheap: gotcha (15) measured that a hidden view is
    /// still solved by the window's full-screen minimum-size derivation, so
    /// `isHidden` would have kept all ten cards' constraint chains live. A
    /// detached card has no path to the window at all.
    private func rebuildDetailPane() {
        guard !cardsByCategory.isEmpty else { return }
        guard mountedCategory != selectedCategory else { return }
        mountedCategory = selectedCategory

        for v in cardsContainer.arrangedSubviews {
            cardsContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        // A card is moving between parents, and the width tie its previous
        // pane gave it is held by *that* parent. `removeFromSuperview()` is
        // documented to drop any constraint referring to the view being
        // removed, so detaching is what actually clears the old tie - the
        // same step the two-column arrangement this replaced needed.
        for card in cardsInOrder { card.removeFromSuperview() }

        for card in cardsByCategory[selectedCategory] ?? [] {
            cardsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardsContainer.widthAnchor).isActive = true
        }
        layoutDidChangeWidths()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutDidChangeWidths()
    }

    /// Rebuild the theme grid if - and only if - the width it was laid out
    /// against has actually moved.
    ///
    /// **Review #3's UI11.** The grid's column count is derived from
    /// `appearanceContainer`'s real width, but the only thing that ever
    /// re-derived it was `NSWindow.didResizeNotification` - and that handler
    /// is (correctly) gated on this page being visible. So a captain who
    /// launched the app at 1100 and then opened Settings got the grid built
    /// during `loadView`, when the container's frame is still zero and
    /// `HelmResponsiveGrid` falls back to its 860pt guess: five columns of
    /// ~84pt in a ~482pt container, and "Solarized Light" rendered as
    /// "Solarized\u{2026}".
    ///
    /// The container's **own** `layout()` is what drives this now (see
    /// `LayoutReportingStack`), not this controller's `viewDidLayout` - which
    /// is the same conclusion `containerWidthMayHaveChanged` records for the
    /// resize case: a child view controller is not reliably told when its
    /// subtree is laid out, and only the window's own content view controller
    /// is. The view being measured always knows.
    ///
    /// The staleness check is the one the resize handler already did, so an
    /// ordinary layout pass that changed nothing costs a float compare -
    /// GL-20's "cheap check first, then pay". It also stops the rebuild
    /// (which changes the subtree, and so schedules another layout pass) from
    /// looping.
    private func appearanceGridWidthMayHaveChanged() {
        let width = appearanceContainer.frame.width
        guard width > 0, abs(width - lastAppearanceGridWidth) > 0.5 else { return }
        lastAppearanceGridWidth = width
        rebuildAppearanceGrid()
    }

    /// Re-wrap every wrapping description on this page against the width it
    /// actually has.
    ///
    /// The same fix `HealthCardView.layoutDidChange` carries, and needed for
    /// the same reason plus one more. A `preferredMaxLayoutWidth` guessed once
    /// (this file had 360 and 520 hardcoded) is an *over*-estimate the moment a
    /// card is narrower than the guess - the dangerous direction, since AppKit
    /// computes a one-line intrinsic height at the estimate and the text then
    /// draws outside its own frame. Two-column mode halves every card, so the
    /// old constants would have clipped. It is also what lets those labels sit
    /// at `.defaultLow` compression resistance (see `wrapping(_:)`), which is
    /// what stops a 520pt guess becoming a window-width floor.
    private func layoutDidChangeWidths() {
        let card = availableCardWidth()
        for (label, reserve) in wrappingLabels {
            let available = max(200, card - HelmCard.contentInsets.left - HelmCard.contentInsets.right - reserve)
            guard abs(label.preferredMaxLayoutWidth - available) > 0.5 else { continue }
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
        }
    }

    /// The width the six cards have to share.
    ///
    /// Read from the scroll view's own **clip** view rather than from
    /// `cardsContainer.frame`, for two reasons: the clip view's width is set by
    /// the window and is therefore stable even while the card tree is being
    /// rebuilt underneath it (`cardsContainer.frame` mid-rebuild is whatever
    /// the half-built tree happened to resolve to), and gotcha #4's scroller
    /// track is already subtracted from it.
    private func contentColumnWidth() -> CGFloat {
        guard let scrollView else { return HelmResponsiveGrid.fallbackContainerWidth }
        let usable = scrollView.contentView.bounds.width - HelmMetrics.pageGutter * 2
        return usable > 0 ? usable : HelmResponsiveGrid.fallbackContainerWidth
    }

    /// How wide one card actually is - the detail pane's whole column, capped
    /// at `detailMaxWidth`.
    ///
    /// The cap has to be applied here as well as in the constraint, because
    /// this is what `layoutDidChangeWidths` re-wraps the description labels
    /// against, and over-estimating that width is the dangerous direction:
    /// AppKit sizes a label's height for one line at
    /// `preferredMaxLayoutWidth`, the text then wraps narrower, and the extra
    /// line draws outside the label's own bounds.
    private func availableCardWidth() -> CGFloat {
        min(contentColumnWidth(), Self.detailMaxWidth)
    }

    /// Wrapping description labels, each with how much of its card's body
    /// width is spoken for by chrome it sits beside (a `descRow`'s own padding,
    /// its trailing control column). Zero for a label that spans the body.
    private var wrappingLabels: [(NSTextField, CGFloat)] = []

    /// Registers a wrapping description label for the width handling above and
    /// drops its compression-resistance floor.
    ///
    /// Both halves are needed together. Dropping the floor alone would let a
    /// narrow column squeeze the label's *frame* below the width its intrinsic
    /// height was computed at, and the second line would draw outside its own
    /// bounds (the Docs-card defect). Re-wrapping alone would leave the label's
    /// 750-priority intrinsic width as a real minimum - above
    /// `NSLayoutPriorityWindowSizeStayPut` (500), i.e. a window-width floor of
    /// exactly the class AGENTS.md gotcha (13) describes, and doubled by two
    /// columns.
    @discardableResult
    private func wrapping(_ label: NSTextField, reserve: CGFloat = 0) -> NSTextField {
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrappingLabels.append((label, reserve))
        return label
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
        if !hasCheckedSudoTouchIDOnce {
            hasCheckedSudoTouchIDOnce = true
            checkSudoTouchID()
        }
        scrollToTop()
    }

    /// Guards the initial background PAM-file check to once per app launch
    /// (re-checked explicitly after the Enable action completes) rather than
    /// on every visit to Settings - same convention as Bootstrap's
    /// `hasCheckedGhHardeningOnce`.
    private var hasCheckedSudoTouchIDOnce = false

    /// Fix 4: the document view (`content`, a `FlippedView`) puts y=0 at its
    /// top, but a freshly laid-out `NSScrollView` can still leave the clip
    /// view's bounds wherever the last layout pass settled - so force it
    /// back explicitly on every appearance rather than trusting the default.
    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Card chrome

    /// A section's card shell: an icon tile + title/subtitle header, then its
    /// content, generously padded and given a rounded, bordered background -
    /// matching the mockup's `.card`/`.card-head` structure (icon-in-tile
    /// rather than a plain glyph, a muted subtitle under the title).
    /// One `HelmCard` per settings section - the shared container from
    /// `HelmDesignSystem.swift`. The icon-tile + title + subtitle header this
    /// file used to build by hand is now that component's own structured
    /// header, so the tile and the subtitle re-theme themselves and this file
    /// no longer keeps registries for either (audit §6.3 component 1).
    private func card(icon: String, tint: HelmTint, title: String, subtitle: String, content: NSView) -> HelmCard {
        let card = HelmCard()
        card.setHeader(symbol: icon, tint: tint, title: title, subtitle: subtitle)
        card.setBody(content, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    /// Muted supporting text inside a card's body, re-colored alongside
    /// `cards` on every theme change. A card *header*'s own subtitle is the
    /// `HelmCard`'s business, not this list's.
    private var subtitleViews: [NSTextField] = []

    /// Registers `label` in the shared `subtitleViews` re-theming list **and**
    /// tints it for the current theme right away.
    ///
    /// Both halves matter. Registering alone is not enough: sections that
    /// rebuild rather than re-theme (`rebuildSecuritySection`) create fresh
    /// labels without necessarily re-running
    /// `applyTheme()`, so a label that was only registered would render in
    /// the default `.labelColor` until the next theme change. Tinting alone
    /// is not enough either, since it would then go stale on that change.
    ///
    /// This replaced `.secondaryLabelColor` at every muted-text site in this
    /// file - a fixed system grey knows nothing about which of the 12 Helm
    /// palettes is active, so it is both off-palette and (for the tertiary
    /// variant) below the 4.5:1 contrast floor in every one of them
    /// (audit §5.3).
    @discardableResult
    private func mutedLabel(_ label: NSTextField) -> NSTextField {
        subtitleViews.append(label)
        label.textColor = HelmTheme.mutedInk(theme)
        return label
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        mutedLabel(l)
        return l
    }

    /// `alignsTrailingToEdge` pins the trailing control to the row's own
    /// trailing edge instead of letting it sit wherever the description text
    /// happens to end.
    ///
    /// This is AGENTS.md's gotcha (10) in the shipped helper: `row` below is a
    /// horizontal `NSStackView` left at the default `.gravityAreas`
    /// distribution, which has no rule for who absorbs the leftover width -
    /// so the hugging priorities set on `textStack` and `trailing` do nothing,
    /// and a short description leaves its control stranded mid-row. Every
    /// card on this page has always looked that way and with four rows of
    /// similar-length copy it reads fine.
    ///
    /// Terminal Shortcuts is nine rows whose descriptions vary from four words
    /// to two lines, where the same behaviour puts nine recorders at nine
    /// different x positions and reads as broken - seen in a real render. So
    /// it opts in, and the default is deliberately left alone rather than
    /// quietly restyling the four cards nobody asked about.
    private func descRow(title: String, desc: String, trailing: NSView,
                         alignsTrailingToEdge: Bool = false) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        mutedLabel(descLabel)
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        // 16 for the row container's own padding, 12 for the row spacing, and
        // the trailing control column measured rather than guessed - the same
        // shape as `HealthCardView.descriptionWidth`, which the previous
        // comment here already cited as the model while still carrying a
        // hardcoded ~160 for "three preset buttons, the widest one on this
        // page". That number had drifted: the font-size presets measure 221pt
        // and the Security row's Enabled + Disable + recheck 187. Under-
        // reserving is the dangerous direction - AppKit sizes the label's
        // height for one line at `preferredMaxLayoutWidth`, the text then
        // wraps narrower than that, and the extra line draws outside the
        // label's own bounds (the same defect the Docs cards were fixed for).
        // Floored at the old 160 so no row can ever reserve less than it did.
        wrapping(descLabel, reserve: 16 + 12 + max(160, ceil(trailing.fittingSize.width)))

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        if alignsTrailingToEdge {
            // With a rule for who stretches, the priorities already set above
            // finally bite: `textStack` is `.defaultLow` and takes the slack,
            // `trailing` is `.required` and stays its own size, at the edge.
            row.distribution = .fill
        }

        // Shared hover helper (task brief #2): a subtle highlight on mouse
        // enter/exit, both colors theme-derived - see `applyTheme` for the
        // actual color assignment.
        let container = HoverHighlightView()
        container.cornerRadius = 8
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        hoverRows.append(container)
        return container
    }

    /// §6.7: the app's one chip.
    ///
    /// This used to be a private copy - a hue painted as its own label over a
    /// 15% wash of itself, which is the audit's §5.7 contrast defect and
    /// measured as low as 1.93:1 across the twelve palettes before
    /// `HelmContrast.tintedSurface` fixed it *in the shared component*. Health
    /// carried the identical copy and slice 2 deleted it; this is the last one.
    /// `ToolRowLayout.pill` corrects the label against whichever surface the
    /// chip lands on and makes it a capsule under Daylight.
    private func pillView(text: String, colorHex: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: text)
        ToolRowLayout.pill(text: text, colorHex: colorHex, into: container, label: label, theme: theme)
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)
        return container
    }

    // MARK: Connection

    private func buildConnectionSection() -> NSView {
        let chooseCwd = HelmButton(title: "Choose\u{2026}", variant: .secondary, target: self, action: #selector(chooseShellCwd))
        configure(shellCwdField)
        shellCwdField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cwdRow = NSStackView(views: [shellCwdField, chooseCwd])
        cwdRow.orientation = .horizontal
        cwdRow.spacing = 8

        let cwdGroup = descRow(title: "Working directory", desc: "Where new Shell/Firstmate tabs open.", trailing: cwdRow)
        cwdRow.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let section = NSStackView(views: [cwdGroup])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        cwdGroup.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separatorViews.append(v)
        return v
    }

    private var separatorViews: [NSView] = []

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

    // MARK: Appearance

    private func buildAppearanceSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "A curated set of light and dark instrument-panel palettes, each contrast-verified to WCAG AA.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        wrapping(desc)

        appearanceContainer.onLayout = { [weak self] in self?.appearanceGridWidthMayHaveChanged() }
        appearanceContainer.orientation = .vertical
        appearanceContainer.alignment = .leading
        appearanceContainer.spacing = 8
        appearanceContainer.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [desc, appearanceContainer])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        appearanceContainer.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// The width one theme card will not go below - the only parameter this
    /// page owns in the shared grid math.
    ///
    /// 150, not the 108 this card used to be *fixed* at, and the reason is
    /// measured rather than picked: at 108 the longest theme names
    /// ("Catppuccin Mocha", "Tokyo Night Light") do not fit beside the active
    /// checkmark, and a real render showed one card in the row resolving to
    /// 130pt while its siblings sat at 107 - its own label's compression
    /// resistance winning over `.fillEqually`. 150 is what the widest name
    /// plus the checkmark and the card's insets actually need.
    private static let themeCardMinWidth: CGFloat = 150

    #if FM_SELFTESTS
    /// UI11's probe surface - see `debugThemeNameLabels`. Rebuilt with the
    /// grid, so it never holds a label from a previous layout. GL-27: a
    /// debug-only accessor's storage is debug-only too.
    private var themeNameLabels: [NSTextField] = []
    #endif

    private func rebuildAppearanceGrid() {
        #if FM_SELFTESTS
        themeNameLabels.removeAll()
        #endif
        for v in appearanceContainer.arrangedSubviews {
            appearanceContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let activeID = ThemeManager.shared.theme.id
        lastAppearanceGridWidth = appearanceContainer.frame.width
        // Phase 7 (audit §4.8 / §6.4's Settings row): this used to chunk into
        // a **fixed** `columnsPerRow = 4` of **fixed** 108pt cards, which is
        // what left the audit's ragged 4/2/4/2 last row and never responded to
        // window width at all. It now runs on `HelmResponsiveGrid` - Tools'
        // own column-count-from-real-width plus partial-row spacer padding,
        // shared rather than re-derived - so the theme grid re-flows on a
        // window resize and its last row's cards stay the same width as every
        // other row's.
        //
        // Still two groups (dark, then light), because that split is a real
        // distinction a captain scans by, not an artefact of the old chunking.
        for group in [HelmTheme.allThemes.filter { $0.mode == .dark }, HelmTheme.allThemes.filter { $0.mode == .light }] {
            let rows = HelmResponsiveGrid.rows(group,
                                               containerWidth: appearanceContainer.frame.width,
                                               minItemWidth: Self.themeCardMinWidth,
                                               spacing: HelmMetrics.s2) { t, _ in
                // This card takes no width: unlike a Tools landing card (whose
                // wrapping description needs a `preferredMaxLayoutWidth` up
                // front) it has only fixed-size content, so the row's
                // `.fillEqually` distribution is the only thing that needs to
                // know how wide it is.
                self.themeCard(t, active: t.id == activeID)
            }
            for row in rows {
                appearanceContainer.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: appearanceContainer.widthAnchor).isActive = true
            }
        }
    }

    private func themeCard(_ t: HelmTheme, active: Bool) -> NSView {
        // A 3-color swatch (bg / surface / accent), matching the mockup's
        // `.theme-swatch` structure - all three pulled from this theme's real
        // values, never the mockup's placeholder hexes.
        let preview = NSStackView()
        preview.orientation = .horizontal
        preview.spacing = 0
        preview.distribution = .fillEqually
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        for hex in [t.backgroundHex, t.chromeBackgroundHex, t.accentHex] {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
            preview.addArrangedSubview(swatch)
        }
        preview.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let nameLabel = NSTextField(labelWithString: t.name)
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        // Otherwise the longest name's own compression resistance beats the
        // row's `.fillEqually` distribution and that one card comes out wider
        // than its siblings (measured: 130 against 107). A truncated name is
        // the right trade - the swatch identifies the theme too.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        #if FM_SELFTESTS
        themeNameLabels.append(nameLabel)
        #endif

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        check.contentTintColor = HelmTheme.nsColor(t.accentHex)
        check.isHidden = !active
        check.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = NSView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addSubview(nameLabel)
        nameRow.addSubview(check)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: nameRow.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -4),
            check.trailingAnchor.constraint(equalTo: nameRow.trailingAnchor, constant: -8),
            check.centerYAnchor.constraint(equalTo: nameRow.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            check.heightAnchor.constraint(equalToConstant: 12),
            nameRow.heightAnchor.constraint(equalToConstant: 24),
        ])

        let stack = NSStackView(views: [preview, nameRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = HoverHighlightView()
        // §7: the grid mechanics stay exactly as they are - only the card
        // chrome becomes Daylight's. That means `dTileSmall`'s radius (the same
        // 10 this card already used, so nothing moves), a **full-strength**
        // `hair` border rather than a damped one, and `inset` as the resting
        // fill: a theme card sits on the Appearance card's own white, so a
        // transparent card would be a swatch strip floating with no plate under
        // it, and `chromeBackgroundHex` would be that same white again.
        card.cornerRadius = theme.isDaylight ? HelmMetrics.dTileSmall : 10
        card.layer?.borderWidth = active ? 1.5 : 1
        card.layer?.borderColor = (active
            ? HelmTheme.nsColor(t.accentHex)
            : (theme.isDaylight
                ? HelmTheme.nsColor(theme.chromeLineHex)
                : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5))).cgColor
        card.layer?.masksToBounds = true
        let base = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let resting: NSColor = theme.isDaylight ? HelmField.fill(theme) : .clear
        card.normalColor = active ? HelmTheme.nsColor(t.accentHex).withAlphaComponent(0.08) : resting
        card.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
            : base.hoverShifted(by: 0.06, forMode: theme.mode)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(themeCardClicked(_:)))
        card.addGestureRecognizer(click)
        card.identifier = NSUserInterfaceItemIdentifier(t.id)
        return card
    }

    @objc private func themeCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue, let t = HelmTheme.theme(id: id) else { return }
        ThemeManager.shared.setTheme(t)
        // `refreshFromSettings()` also runs via the `ThemeManager.observe`
        // callback registered in `loadView`, so nothing else is needed here.
    }

    // MARK: Terminal

    private func buildTerminalSection() -> NSView {
        let sizes = [12, 13, 14, 16]
        let buttons = sizes.map { size -> HelmButton in
            let b = HelmButton(title: "\(size)", variant: .secondary, target: self, action: #selector(fontPresetClicked(_:)))
            b.tag = size
            fontPresetButtons[size] = b
            return b
        }
        let presetRow = NSStackView(views: buttons)
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        let fontRow = descRow(title: "Default font size", desc: "Also adjustable live with \u{2318}+ / \u{2318}\u{2212} in the console.", trailing: presetRow)

        // GL-32. The row above is the *terminal* size (`FontSizeManager`);
        // this one is the app's own interface text (`ChromeTextScale`), which
        // had no control at all before - `HelmType`'s sizes were fixed, which
        // is what the accessibility review measured. Pages that derive their
        // fonts inside `applyTheme` (the shared components, and every page
        // built on them) pick a change up live; anything whose font is set
        // once in its own `loadView` follows on relaunch, which is why the
        // description says so rather than pretending otherwise.
        let scaleButtons = ChromeTextScale.steps.enumerated().map { index, step -> HelmButton in
            let b = HelmButton(title: step.title, variant: .secondary, target: self, action: #selector(uiScaleClicked(_:)))
            b.tag = index
            uiScaleButtons[index] = b
            return b
        }
        let scaleRow = NSStackView(views: scaleButtons)
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 6
        let interfaceRow = descRow(title: "Interface text", desc: "Scales the app's own labels, captions and titles. Some pages pick this up after a relaunch.", trailing: scaleRow)

        autoReconnectSwitch.onToggle = { [weak self] in self?.autoReconnectToggled() }
        let reconnectRow = descRow(title: "Reconnect automatically", desc: "If a tab's connection drops, restore it silently rather than waiting for \u{2318}R.", trailing: autoReconnectSwitch)

        notifySwitch.onToggle = { [weak self] in self?.notifyToggled() }
        let notifyRow = descRow(title: "Bell & notifications", desc: "Surface a desktop notification the moment a crewmate needs your decision.", trailing: notifySwitch)

        let section = NSStackView(views: [fontRow, separator(), interfaceRow, separator(), reconnectRow, separator(), notifyRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        for row in [fontRow, interfaceRow, reconnectRow, notifyRow] {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    // MARK: Terminal shortcuts

    /// One recorder per action, so a change can be pushed straight back into
    /// the row that made it (a reset has to move all nine labels at once).
    private var shortcutRecorders: [TerminalShortcutAction: KeyChordRecorderView] = [:]
    private var resetShortcutsButton: HelmButton?

    /// Set by the app delegate: "a binding changed, tell the live monitor".
    ///
    /// Forwarded rather than reached for, the same shape
    /// `onDictationShortcutChanged` already has one feature over - this page
    /// knows nothing about `TabKeyboardShortcuts`, and a recorder the captain
    /// just used takes effect on the next keypress rather than the next
    /// launch.
    var onTerminalShortcutsChanged: ((TerminalShortcutSet) -> Void)?

    private func buildTerminalShortcutsSection() -> NSView {
        var views: [NSView] = []

        for group in TerminalShortcutAction.Group.allCases {
            if !views.isEmpty { views.append(separator()) }
            views.append(groupHeading(group.title))
            for action in TerminalShortcutAction.allCases where action.group == group {
                // `.command`: a Console shortcut has to be a real key with a
                // modifier. See `KeyChordRecorderView.Mode`.
                let recorder = KeyChordRecorderView(shortcut: AppSettings.shared.terminalShortcuts[action],
                                                    mode: .command)
                // One width for all nine, so they read as a column.
                //
                // `descRow` reserves room for its trailing control by
                // measuring that control's own fitting size, and a recorder
                // sizes itself to whatever chord it is showing - so leaving
                // them to their natural widths gives every row a different
                // reserve and lands nine controls at nine different x
                // positions. Seen in a real render before it was fixed. Wide
                // enough for the longest shipped default (⌃⌘Return) and for
                // the recording prompt to stay readable.
                recorder.widthAnchor.constraint(equalToConstant: 168).isActive = true
                recorder.onChange = { [weak self] chord in self?.shortcutChanged(action, to: chord) }
                shortcutRecorders[action] = recorder
                views.append(descRow(title: action.title, desc: action.detail, trailing: recorder,
                                     alignsTrailingToEdge: true))
            }
        }

        let reset = HelmButton(title: "Reset to defaults", variant: .secondary,
                               target: self, action: #selector(resetTerminalShortcuts))
        resetShortcutsButton = reset
        views.append(separator())
        views.append(descRow(title: "Defaults",
                             desc: "Put all nine back to the bindings this app ships with.",
                             trailing: reset, alignsTrailingToEdge: true))

        let section = NSStackView(views: views)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        for row in views {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        refreshShortcutControls()
        return section
    }

    /// A small muted heading so the nine rows read as three ideas.
    private func groupHeading(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = HelmType.kicker()
        mutedLabel(label)
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
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
        // Every recorder, not just the ones the captain changed: `reset()`
        // clears the whole map, so a row still showing a custom chord would
        // be showing a binding that no longer exists.
        for (action, recorder) in shortcutRecorders { recorder.shortcut = set[action] }
        refreshShortcutControls()
    }

    private func refreshShortcutControls() {
        resetShortcutsButton?.isEnabled = AppSettings.shared.terminalShortcuts.hasCustomBindings
    }

    // MARK: Morning briefing (F12)

    private func buildMorningBriefingSection() -> NSView {
        morningBriefingSwitch.onToggle = { [weak self] in self?.morningBriefingToggled() }
        let toggleRow = descRow(
            title: "Show a morning briefing on Fleet",
            desc: "On the first visit to Fleet each day, generate one short paragraph from the fleet snapshot, PR queue, due tasks, drift and quota - each clause linking to the page it came from.",
            trailing: morningBriefingSwitch)

        // Stated plainly rather than left to be discovered: this is the one
        // feature here that reaches the network, and what it sends is worth
        // being specific about.
        let note = NSTextField(wrappingLabelWithString:
            "Uses your own `claude` login for one call per day. Only counts and titles already shown elsewhere in the app are sent - never terminal output or logs. With `claude` unavailable the card still appears as a plain, locally-computed stat line with no AI call at all.")
        note.font = .systemFont(ofSize: 11)
        mutedLabel(note)
        wrapping(note)

        let section = NSStackView(views: [toggleRow, separator(), note])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        toggleRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func morningBriefingToggled() {
        AppSettings.shared.morningBriefingEnabled = morningBriefingSwitch.isOn
    }

    // MARK: Daily review (F20)

    private func buildDailyReviewSection() -> NSView {
        dailyReviewSwitch.onToggle = { [weak self] in self?.dailyReviewToggled() }
        let toggleRow = descRow(
            title: "Show the daily review on Fleet",
            desc: "A second card under the morning briefing: what is due today, the follow-ups waiting on you, today's calendar, your habits, the top notes on your sticky board and what is unread in your reading list.",
            trailing: dailyReviewSwitch)

        dailyReviewCalendarSwitch.onToggle = { [weak self] in self?.dailyReviewCalendarToggled() }
        let calendarRow = descRow(
            title: "Include today's calendar",
            desc: "Reads today's events through EventKit and never writes to them. macOS asks for permission the first time; turning this off stops Grand Line reading your calendar.",
            trailing: dailyReviewCalendarSwitch)

        // The counterpart of the morning briefing card's network note, and
        // the opposite claim: this one never leaves the machine.
        let note = NSTextField(wrappingLabelWithString:
            "Nothing here is sent anywhere. The card is assembled on this Mac from records the app has already loaded, with no AI call. A section it cannot read says so instead of showing a zero.")
        note.font = .systemFont(ofSize: 11)
        mutedLabel(note)
        wrapping(note)

        let section = NSStackView(views: [toggleRow, calendarRow, separator(), note])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        toggleRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        calendarRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func dailyReviewToggled() {
        AppSettings.shared.dailyReviewEnabled = dailyReviewSwitch.isOn
    }

    /// Turning the calendar on here does **not** prompt: the permission
    /// request belongs to a real click on the card's own button, where the
    /// captain can see what they are about to be asked for. This flag only
    /// says the column may read once access exists.
    @objc private func dailyReviewCalendarToggled() {
        AppSettings.shared.dailyReviewCalendarEnabled = dailyReviewCalendarSwitch.isOn
    }

    // MARK: Gmail (Google sign-in)

    /// One row per slot, plus the client-id field and the calendar toggle.
    ///
    /// Held as properties rather than rebuilt, for this page's own reason:
    /// every card is constructed once in `loadView` and reparented between
    /// categories, so a row that rebuilt itself would lose its place in
    /// `refreshFromSettings`'s sync.
    private var gmailRows: [GoogleAccountSlot: GmailAccountRow] = [:]
    private let gmailClientIDField = HelmTextField(placeholder: "1234-abcd.apps.googleusercontent.com")
    private let gmailClientSecretField = HelmTextField(placeholder: "Client secret (optional)")
    private let gmailCalendarSwitch = HelmToggle()
    private let gmailStatusLabel = NSTextField(wrappingLabelWithString: "")

    /// Set by `AppShellController` so a sign-in that connects a calendar can
    /// make the Overview page re-read it. Optional: this page works with
    /// nothing wired, which is what every self-test that mounts it relies on.
    var onGoogleAccountsChanged: (() -> Void)?

    private func buildGmailSection() -> NSView {
        // **Neither account is mandatory**, and the copy says so before the
        // captain has to infer it from two buttons.
        let intro = NSTextField(wrappingLabelWithString:
            "Connect a Google account to read its calendar into your daily review. "
            + "Work and personal are completely independent - sign in to one, both or "
            + "neither, and signing out of one leaves the other alone. Grand Line asks "
            + "Google for read-only calendar access and your address, and for nothing else.")
        intro.font = .systemFont(ofSize: 11)
        mutedLabel(intro)
        wrapping(intro)

        var rowViews: [NSView] = [intro]
        for slot in GoogleAccountSlot.allCases {
            // A rule between them, so two independent accounts read as two
            // things rather than as one group - which is the whole point of
            // there being two.
            if slot != GoogleAccountSlot.allCases.first { rowViews.append(separator()) }
            let row = GmailAccountRow(slot: slot)
            row.onConnect = { [weak self] in self?.connectGoogle(slot) }
            row.onDisconnect = { [weak self] in self?.disconnectGoogle(slot) }
            gmailRows[slot] = row
            rowViews.append(row)
        }

        gmailCalendarSwitch.onToggle = { [weak self] in self?.googleCalendarToggled() }
        let calendarRow = descRow(
            title: "Use Google Calendar in the daily review",
            desc: "Adds a connected account\u{2019}s events to the review\u{2019}s calendar column, "
                + "alongside your Mac\u{2019}s own calendars rather than instead of them. Read-only: "
                + "the only scope Grand Line ever asks Google for cannot write.",
            trailing: gmailCalendarSwitch)

        // The client id. This is the captain-owned half, and the reason it is
        // a field at all rather than a constant: an OAuth client id is issued
        // by a Google Cloud project, and this app cannot create one. There is
        // deliberately no built-in default - a fake id would put a Connect
        // button on the page that always fails with an opaque Google error.
        gmailClientIDField.target = self
        gmailClientIDField.action = #selector(gmailClientChanged)
        gmailClientSecretField.target = self
        gmailClientSecretField.action = #selector(gmailClientChanged)
        let idRow = descRow(title: "Google OAuth client ID",
                            desc: "From your own Google Cloud project - create an OAuth client of "
                                + "type \u{201C}Desktop app\u{201D} and paste its ID here. Stored in the "
                                + "Keychain, never on disk. FM_GOOGLE_OAUTH_CLIENT_ID overrides it.",
                            trailing: gmailClientIDField, alignsTrailingToEdge: true)
        let secretRow = descRow(title: "Client secret",
                                desc: "Optional. Google issues one for a Desktop client and its "
                                    + "token endpoint expects it back.",
                                trailing: gmailClientSecretField, alignsTrailingToEdge: true)

        gmailStatusLabel.font = .systemFont(ofSize: 11)
        mutedLabel(gmailStatusLabel)
        wrapping(gmailStatusLabel)

        rowViews.append(separator())
        rowViews.append(calendarRow)
        rowViews.append(separator())
        rowViews.append(idRow)
        rowViews.append(secretRow)
        rowViews.append(gmailStatusLabel)

        let section = NSStackView(views: rowViews)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        for view in rowViews {
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        // A field is a control, not text: a required width would be a window
        // floor (gotcha (13)), so both get a generous preferred width below
        // `NSLayoutPriorityWindowSizeStayPut`.
        for field in [gmailClientIDField, gmailClientSecretField] {
            let width = field.widthAnchor.constraint(equalToConstant: 280)
            width.priority = HelmDaylightPriority.contentTie
            width.isActive = true
        }
        return section
    }

    /// Repaint every Gmail surface from the store. One function, called from
    /// `refreshFromSettings` and after every sign-in or sign-out, so the two
    /// cards can never disagree with what is stored.
    private func refreshGmailSection() {
        let configuration = GoogleOAuth.configuration()
        for (slot, row) in gmailRows {
            row.render(record: GoogleAccountStore.shared.record(for: slot),
                       isConfigured: configuration != nil,
                       isBusy: GoogleSignInController.shared.inFlight.contains(slot),
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
        gmailStatusLabel.stringValue = Self.gmailStatusLine(for: configuration)
    }

    /// The one sentence under the client-id field, and the honest statement
    /// of what is and is not set up.
    ///
    /// A stated gap, in GL-14's own spirit: "no client ID" is not "sign-in is
    /// broken", and the captain should be able to read which of the two they
    /// are looking at.
    static func gmailStatusLine(for configuration: GoogleOAuthConfiguration?) -> String {
        guard let configuration else {
            return "No OAuth client ID yet, so Connect cannot run - Grand Line cannot create one "
                + "for you. Create a Google Cloud project, add an OAuth client of type "
                + "\u{201C}Desktop app\u{201D}, and paste its ID above."
        }
        guard configuration.looksWellFormed else {
            return "That does not look like a Google client ID - they end in "
                + "\u{201C}.apps.googleusercontent.com\u{201D}. Connect will use it anyway, but "
                + "Google will probably refuse it."
        }
        return "Ready. Connect opens Google\u{2019}s own sign-in page in Safari, so Grand Line "
            + "never sees your password."
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

    private func connectGoogle(_ slot: GoogleAccountSlot) {
        refreshGmailSection()
        GoogleSignInController.shared.signIn(slot: slot, from: view.window) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record):
                if record.canReadCalendar {
                    Feedback.report("Connected \(record.email.isEmpty ? slot.title : record.email).",
                                    kind: .done, persistence: .transient, in: self.view)
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
        // The cached day of events belongs to the account that just went
        // away; keeping it would render a disconnected account's calendar.
        DailyReviewCalendarSources.shared.forgetGoogle()
        refreshGmailSection()
        onGoogleAccountsChanged?()
    }

    // MARK: Compact mode (F22)

    /// What the mode is wired to. `nil` in every self-test that mounts this
    /// page without an app delegate, and in that case the toggles still
    /// persist their settings - they simply have nothing to tell. Better than
    /// reaching for `NSApp.delegate` here, which is nil in a headless suite
    /// and would make this page crash rather than fail.
    var onCompactModeSettingsChanged: (() -> Void)?

    private func buildCompactModeSection() -> NSView {
        compactModeSwitch.onToggle = { [weak self] in self?.compactModeToggled() }
        compactDockSwitch.onToggle = { [weak self] in self?.compactModeToggled() }
        compactBadgeSwitch.onToggle = { [weak self] in self?.compactModeToggled() }

        let modeRow = descRow(
            title: "Compact (menu bar) mode",
            desc: "The main window stays closed. Tasks, notes, the vault and the crew are all "
                + "reachable from the status item, which also takes a capture line - and \u{2303}\u{2325}G "
                + "opens it from anywhere.",
            trailing: compactModeSwitch)
        let dockRow = descRow(
            title: "Hide the Dock icon",
            desc: "Runs the app as a menu-bar accessory (`LSUIElement`) while compact mode is on. "
                + "Applied immediately, with no relaunch, and reversed the moment compact mode is "
                + "switched off - so this can never leave you with no way back to the window.",
            trailing: compactDockSwitch)
        let badgeRow = descRow(
            title: "Badge the status item with the overdue count",
            desc: "Off by default \u{2014} a permanent red number is a bad neighbour in a menu bar. "
                + "The count is one click away either way.",
            trailing: compactBadgeSwitch)

        let note = NSTextField(wrappingLabelWithString:
            "Compact mode does not disable anything. The full window is one click or \u{2303}\u{2325}G away, "
            + "and the app lock, the dictation hotkey, Schedules and every background poller keep "
            + "running either way.")
        note.font = .systemFont(ofSize: 11)
        mutedLabel(note)
        wrapping(note)

        let section = NSStackView(views: [modeRow, dockRow, badgeRow, separator(), note])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        for row in [modeRow, dockRow, badgeRow, note] as [NSView] {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    @objc private func compactModeToggled() {
        AppSettings.shared.compactModeEnabled = compactModeSwitch.isOn
        AppSettings.shared.compactModeHidesDockIcon = compactDockSwitch.isOn
        AppSettings.shared.compactModeBadgesOverdueCount = compactBadgeSwitch.isOn
        // One callback for all three rather than three: everything that
        // follows from the settings is `CompactModeController.refresh()`,
        // which re-reads all of them and is idempotent. Three separate
        // notifications would invite three separate partial applications.
        onCompactModeSettingsChanged?()
    }


    // MARK: Security

    private let securityStack = NSStackView()

    private func buildSecuritySection() -> NSView {
        securityStack.orientation = .vertical
        securityStack.alignment = .leading
        securityStack.spacing = 12
        securityStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSecuritySection()
        return securityStack
    }

    /// Rebuilt (not just re-themed) on every status change, since the
    /// trailing control differs by status (a pill, a button, or plain text) -
    /// same convention as Bootstrap's `ghAuthRow`. `descRow` registers a
    /// fresh `HoverHighlightView` into the shared `hoverRows` re-theming list
    /// on every call, so the just-removed row's now-orphaned entry is pruned
    /// first rather than left to accumulate.
    private func rebuildSecuritySection() {
        for v in securityStack.arrangedSubviews {
            securityStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        hoverRows.removeAll { $0.superview == nil }
        let row = sudoTouchIDRow()
        securityStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: securityStack.widthAnchor).isActive = true
        applyTheme()
    }

    private func sudoTouchIDRow() -> NSView {
        var desc = "Use your fingerprint instead of typing your password at a terminal prompt."
        let statusView: NSView
        switch sudoTouchIDStatus {
        case .checking:
            statusView = rowLabel("Checking\u{2026}")
        case .enabled:
            // The one enabled state with an action: the `pam_tid.so` line is
            // in a real `/etc/pam.d/sudo_local` this app can edit. The pill
            // stays - it states what is true - and the button sits beside it,
            // the same shape the Enable direction has.
            let disable = HelmButton(title: isDisablingSudo ? "Disabling\u{2026}" : "Disable",
                                     variant: .secondary, target: self,
                                     action: #selector(disableSudoTouchIDClicked))
            disable.isEnabled = !isDisablingSudo
            disable.toolTip = "Remove the Touch ID line from /etc/pam.d/sudo_local (asks for your password)"
            let pair = NSStackView(views: [pillView(text: "Enabled", colorHex: theme.ansiHex[2]), disable])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 8
            statusView = pair
        case .enabledNixDarwin:
            // Enabled, and the same symlink-into-the-store wall the
            // not-enabled nix-darwin case hits - so the same answer, pointed
            // the other way. Deliberately no Disable button: the store is
            // read-only, and an edit that did land would be regenerated away
            // by the next rebuild.
            desc += " It is on, but this Mac is managed by nix-darwin, where /etc/pam.d/sudo_local is regenerated from your flake on every rebuild - set `security.pam.services.sudo_local.touchIdAuth = false;` (or drop the option) in your dotfiles' configuration.nix, then run rebuild.sh."
            statusView = pillView(text: "Enabled", colorHex: theme.ansiHex[2])
        case .enabledInSudoFile:
            // Turning this off means editing /etc/pam.d/sudo, the file Apple
            // ships and replaces on a system update. This app edits
            // sudo_local and nothing else, so it says where the line is
            // rather than offering a button that would press cleanly and
            // change nothing.
            desc += " It is on via a pam_tid.so line in /etc/pam.d/sudo itself, not /etc/pam.d/sudo_local - this app only ever edits sudo_local, so remove that line by hand to turn it off."
            statusView = pillView(text: "Enabled", colorHex: theme.ansiHex[2])
        case .notEnabled:
            let button = HelmButton(title: isHardeningSudo ? "Enabling\u{2026}" : "Enable", variant: .primary, target: self, action: #selector(enableSudoTouchIDClicked))
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

        // A manual recheck affordance for this one row: the automatic check
        // only ever runs once per app launch (`hasCheckedSudoTouchIDOnce`,
        // see `viewWillAppear`), so a fix made outside the app (editing
        // dotfiles, running `rebuild.sh` in another terminal) leaves this
        // row showing stale status until the captain restarts the whole app.
        // Hidden while a check is already in flight, since re-triggering one
        // mid-check would just race itself.
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
            combined.spacing = 6
            trailing = combined
        }
        return descRow(title: "Touch ID for sudo", desc: desc, trailing: trailing)
    }

    @objc private func recheckSudoTouchIDClicked() {
        checkSudoTouchID()
    }

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
    /// the same `onRunCommandTracked` Console tab (so macOS's own `sudo`
    /// prompt authenticates it), the same in-flight flag disabling the button
    /// while it runs, and the same re-check on exit - which is what flips the
    /// row back to `.notEnabled` and its Enable button with no second code
    /// path deciding that. The command is
    /// `SudoTouchIDSource.disableCommand()`; see it for why the edit is
    /// scoped the way it is.
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

    // MARK: Shortcuts & Siri (F21)

    /// The five App Intents, listed from `GrandLineIntentCatalog` rather than
    /// hardcoded here - so a sixth intent cannot be added without this card
    /// gaining a row (and `AppIntentActionsSelfTest` fails the run if the
    /// catalogue and the intent types in `GrandLineAppIntents.swift` disagree).
    ///
    /// The card says nothing about *enabling* anything, unlike the mockup's
    /// five toggles. There is nothing to enable: an App Intent is published by
    /// the app bundle's metadata, and a per-intent switch here would be a
    /// control that either does nothing or - worse - reads as a security
    /// boundary while the real ones (the app lock, the vault's own lock, the
    /// per-credential Touch ID gate) sit elsewhere. Each row states what it
    /// takes and, for Copy Credential, what it deliberately will not do.
    private func buildIntentsSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "These run without bringing the window forward. Find them in Shortcuts under \u{201C}Manjesh Grand Line\u{201D}, or say them to Siri.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        wrapping(desc)

        var rows: [NSView] = []
        for entry in GrandLineIntentCatalog.entries {
            let trailing: NSView
            if let note = entry.guardNote {
                // Amber, and the one row on this card carrying a chip at all.
                // "Guarded" is the mockup's own word for it, and it is the
                // single thing about this list a captain has to read before
                // wiring any of it into a shortcut.
                trailing = pillView(text: note, colorHex: HelmTint.warn.hex(in: theme))
            } else {
                trailing = rowLabel("action")
            }
            rows.append(descRow(title: entry.title, desc: entry.parameters, trailing: trailing,
                                alignsTrailingToEdge: true))
        }

        // GL-14, and the honest half of F21: the types are in the binary
        // either way, but Shortcuts only finds them when the packaged app
        // carries `Metadata.appintents` - which `build_native_app.sh` writes
        // only on a machine with Xcode's `appintentsmetadataprocessor`. A card
        // listing five actions while this copy publishes none would be exactly
        // the "unknown rendered as available" defect, so it says which of the
        // two this copy is.
        let status = NSTextField(wrappingLabelWithString: SettingsController.intentRegistrationStatusText())
        status.font = .systemFont(ofSize: 11)
        mutedLabel(status)
        wrapping(status)

        let section = NSStackView(views: [desc] + rows + [status])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        for row in rows {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    /// Whether *this* copy of the app publishes its intents to the system.
    ///
    /// A real check against the running bundle rather than a constant: the
    /// same source builds an unbundled `swift build` binary (no bundle at all,
    /// so nothing is registered) and a packaged `.app` that may or may not
    /// have had the metadata step run.
    static func intentRegistrationStatusText() -> String {
        guard let resources = Bundle.main.resourceURL,
              Bundle.main.bundleIdentifier != nil else {
            return "This copy is running unbundled (swift build / swift run), so nothing is registered with Shortcuts. The packaged app is what publishes these."
        }
        let metadata = resources.appendingPathComponent("Metadata.appintents")
        if FileManager.default.fileExists(atPath: metadata.path) {
            return "Registered with the system \u{2014} these five appear in Shortcuts and Spotlight."
        }
        return "Not registered on this copy: the app bundle carries no Metadata.appintents. native/build_native_app.sh writes it only when Xcode's appintentsmetadataprocessor is present - rebuild the app on a Mac with Xcode installed to publish them."
    }

    // MARK: Backup & Restore

    private let backupStatusLabel = NSTextField(wrappingLabelWithString: "")
    /// F24's "what goes in the bundle" list. Rebuilt rather than re-themed,
    /// like `securityStack`, because each row's trailing control differs by
    /// what the measurement found.
    private let backupContentsStack = LayoutReportingStack()

    /// F24: one measurement per file-backed section, `nil` until the
    /// off-main-thread walk lands. `nil` renders as "Measuring…", never as a
    /// confident zero (GL-14) - an unmeasured store and an empty one are
    /// different things and the row that conflates them is the one that makes
    /// a captain skip the export.
    private var backupMeasurements: [BackupStoreSection: (files: Int, bytes: Int, unreadable: Bool)] = [:]
    /// Whether a vault file exists on this machine, and how big. `nil` until
    /// measured, same contract as above.
    private var backupVaultMeasurement: (exists: Bool, credentials: Int, bytes: Int)?
    private var isMeasuringBackup = false

    /// Export/Import share one implementation (`BackupUI.swift`) with the
    /// Bootstrap page's "Restore Grand Line config" step - this card holds no
    /// logic of its own, only the two buttons and an honest inventory of what
    /// they would move.
    ///
    /// F24 turned that inventory from one counts line into a real per-store
    /// list, for the reason the mockup's own note gives: a one-file move is
    /// only trustworthy if you can see what it leaves behind. So the two
    /// deliberate exclusions are rows on this list rather than an omission -
    /// terminal scrollback and session state, which are machine-specific, and
    /// SSH private key material, which never leaves the Keychain.
    private func buildBackupSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "Write everything this app knows locally to a single file, or bring one in from another machine. A restore is a merge with a preview, never a silent overwrite - nothing on this Mac is deleted by one.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        wrapping(desc)

        backupContentsStack.orientation = .vertical
        backupContentsStack.alignment = .leading
        backupContentsStack.spacing = 10
        backupContentsStack.translatesAutoresizingMaskIntoConstraints = false

        backupStatusLabel.font = .systemFont(ofSize: 11)
        mutedLabel(backupStatusLabel)

        let exportButton = HelmButton(title: "Export\u{2026}", variant: .secondary, target: self, action: #selector(exportBackupClicked))
        let importButton = HelmButton(title: "Import\u{2026}", variant: .secondary, target: self, action: #selector(importBackupClicked))

        let buttonRow = NSStackView(views: [exportButton, importButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let section = NSStackView(views: [desc, backupContentsStack, backupStatusLabel, buttonRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        backupContentsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        rebuildBackupContents()
        return section
    }

    private func refreshBackupStatus() {
        let hostCount = hostStore.hosts.count
        let snippetCount = snippetStore.snippets.count
        backupStatusLabel.stringValue = "Currently saved: \(hostCount) host\(hostCount == 1 ? "" : "s"), \(snippetCount) snippet\(snippetCount == 1 ? "" : "s")."
        rebuildBackupContents()
        measureBackupContents()
    }

    /// Walks the four store roots for a file count and a size, off the main
    /// thread.
    ///
    /// Metadata only (`BackupFileArchiveBuilder.measure`), so this is a
    /// stat-per-file rather than a read - but a notebook is up to 2000 files
    /// and this runs on every visit to Settings, and "cheap enough" is exactly
    /// the reasoning behind the main-thread `gh auth token` call that used to
    /// beachball the Export button (T2, `BackupUI.resolveGitHubAvailability`).
    /// Off-main from the start rather than after the same measurement.
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
        for v in backupContentsStack.arrangedSubviews {
            backupContentsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        hoverRows.removeAll { $0.superview == nil }

        var rows: [NSView] = []
        rows.append(backupRow(title: "Hosts, SSH keys, jump hosts",
                              desc: "\(hostStore.hosts.count) host(s) and the metadata for the keys they reference. Private key material never leaves the Keychain.",
                              trailing: pillView(text: "included", colorHex: theme.ansiHex[2])))
        rows.append(backupRow(title: "Command snippets & dictation",
                              desc: "\(snippetStore.snippets.count) snippet(s), the dictation vocabulary and shortcut, and the preferences above.",
                              trailing: pillView(text: "included", colorHex: theme.ansiHex[2])))

        for section in BackupStoreSection.allCases {
            rows.append(backupRow(title: section.title,
                                  desc: "\(section.detail). \(backupMeasurementText(for: section))",
                                  trailing: pillView(text: "included", colorHex: theme.ansiHex[2])))
        }

        rows.append(backupRow(title: "Poneglyph vault",
                              desc: backupVaultText(),
                              // Amber, not green: "sealed" is a real caveat
                              // (the master password does not travel with it),
                              // and painting it the same as the rest would
                              // tell the captain there is nothing to know.
                              trailing: pillView(text: "sealed", colorHex: theme.ansiHex[3])))

        rows.append(backupRow(title: "Terminal scrollback & session state",
                              desc: "Deliberately left out. Scrollback is machine-specific, and what was on a terminal is not configuration - a restore should not reopen someone else's session.",
                              // A muted label rather than a pill, deliberately.
                              // Every pill on this page goes through
                              // `HelmContrast.tintedSurface`, and AGENTS.md's
                              // colour rules are explicit that washing a
                              // no-identity/ink hue that way produces a
                              // near-black chip - the heaviest thing on the
                              // card would then be the one row that is *not*
                              // in the bundle.
                              trailing: rowLabel("excluded")))

        for row in rows {
            backupContentsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: backupContentsStack.widthAnchor).isActive = true
        }
        applyTheme()
    }

    /// `nil` measurement reads as "Measuring…"; an unreadable root says so
    /// (GL-21 - "could not be enumerated" is not "empty"); everything else is
    /// the real count.
    private func backupMeasurementText(for section: BackupStoreSection) -> String {
        guard GrandLineServices.shared.backupRoots != nil else { return "Not available until the app has finished starting up." }
        guard let m = backupMeasurements[section] else { return "Measuring\u{2026}" }
        if m.unreadable { return "\u{26A0} This folder could not be read, so its size is unknown." }
        if m.files == 0 { return "Nothing here yet." }
        return "\(m.files) file(s), \(SettingsController.byteText(m.bytes))."
    }

    private func backupVaultText() -> String {
        guard GrandLineServices.shared.backupRoots != nil else { return "Not available until the app has finished starting up." }
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

    /// The same `descRow` every other card uses, with the trailing pill pinned
    /// to the row's own edge - these are seven rows of very different
    /// description lengths, which is exactly the case AGENTS.md gotcha (10)
    /// says `.gravityAreas` renders as seven pills at seven x positions.
    private func backupRow(title: String, desc: String, trailing: NSView) -> NSView {
        descRow(title: title, desc: desc, trailing: trailing, alignsTrailingToEdge: true)
    }

    @objc private func exportBackupClicked() {
        BackupUI.exportFlow(from: self, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
    }

    @objc private func importBackupClicked() {
        BackupUI.importFlow(from: self, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore) { [weak self] in
            self?.refreshFromSettings()
        }
    }

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

    // MARK: Shared field plumbing

    /// Placeholder and chrome are `HelmTextField`'s own now (Phase 0's raw-input
    /// purge) - this only wires the value back to `AppSettings`.
    private func configure(_ field: NSTextField) {
        field.target = self
        field.action = #selector(textFieldChanged(_:))
        field.delegate = self
    }

    @objc private func textFieldChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender {
        case shellCwdField:
            AppSettings.shared.defaultShellCwd = value.isEmpty ? nil : value
        default:
            break
        }
    }

    // MARK: Sync

    private func refreshFromSettings() {
        guard isViewLoaded else { return }
        shellCwdField.stringValue = AppSettings.shared.defaultShellCwd ?? ""
        for (index, step) in ChromeTextScale.steps.enumerated() {
            uiScaleButtons[index]?.variant =
                abs(ChromeTextScale.shared.scale - step.scale) < 0.001 ? .primary : .secondary
        }
        for size in [12, 13, 14, 16] {
            // `NSButton.state`'s on-look was the stock bezel's; the selected
            // preset now reads as the accent-filled `.primary` variant, which
            // is both on-palette and a stronger signal than the bezel ever was.
            fontPresetButtons[size]?.variant = Int(AppSettings.shared.fontSize) == size ? .primary : .secondary
        }
        autoReconnectSwitch.isOn = AppSettings.shared.autoReconnect
        notifySwitch.isOn = AppSettings.shared.notifyOnNeedsDecision
        morningBriefingSwitch.isOn = AppSettings.shared.morningBriefingEnabled
        dailyReviewSwitch.isOn = AppSettings.shared.dailyReviewEnabled
        dailyReviewCalendarSwitch.isOn = AppSettings.shared.dailyReviewCalendarEnabled
        refreshGmailSection()
        compactModeSwitch.isOn = AppSettings.shared.compactModeEnabled
        compactDockSwitch.isOn = AppSettings.shared.compactModeHidesDockIcon
        compactBadgeSwitch.isOn = AppSettings.shared.compactModeBadgesOverdueCount

        rebuildAppearanceGrid()
        refreshBackupStatus()
        applyTheme()
    }

    /// The repaint-only half of `refreshFromSettings` (GL-24). Re-reads nothing
    /// off disk, shells out to nothing, and rebuilds only what genuinely
    /// carries theme-derived colour it cannot re-derive itself (the theme grid's
    /// own cards, which show every palette's swatches).
    private func repaintForTheme() {
        guard isViewLoaded else { return }
        // Which cards are in the detail pane is a function of the captain's
        // selection and of nothing else - a theme change never moves it. What
        // a theme change does move is the grid's own swatches, below.
        rebuildAppearanceGrid()
        applyTheme()
    }

    #if FM_SELFTESTS
    /// Probe surface for `DaylightDrillPageSlice6SelfTest`. Every card the
    /// page owns, across all seven categories - not only the mounted ones.
    var debugCards: [HelmCard] { cardsInOrder }
    /// The left navigation column, so a suite can read its selection and
    /// drive a real row click rather than only calling `select(_:)`.
    var debugSidebar: HelmPageSidebar { sidebar }
    var debugSelectedCategory: Category { selectedCategory }
    /// The Gmail card's two slot rows, in card order.
    var debugGmailRows: [GmailAccountRow] {
        GoogleAccountSlot.allCases.compactMap { gmailRows[$0] }
    }
    var debugGmailStatusText: String { gmailStatusLabel.stringValue }
    var debugGmailCalendarSwitch: HelmToggle { gmailCalendarSwitch }
    var debugGmailClientIDField: HelmTextField { gmailClientIDField }
    /// Drives the field's real target/action, the way a commit from the field
    /// editor does - never the private method, so the wiring is under test too.
    func debugCommitGmailClient() { gmailClientChanged() }
    func debugRefreshGmail() { refreshGmailSection() }
    /// The cards currently in the detail pane, in the order it stacks them.
    var debugMountedCards: [HelmCard] {
        cardsContainer.arrangedSubviews.compactMap { $0 as? HelmCard }
    }
    /// What each category is expected to show, so a suite can assert the
    /// mapping itself rather than re-deriving it from the thing under test.
    func debugCards(in category: Category) -> [HelmCard] { cardsByCategory[category] ?? [] }
    /// Every toggle on the page, in card order: Terminal's two, F12's
    /// briefing, F20's daily review and its calendar column, then F22's
    /// three. `DaylightDrillPageSlice6SelfTest` asserts the count, so a
    /// toggle added without coming here fails by name.
    var debugToggles: [HelmToggle] {
        [autoReconnectSwitch, notifySwitch, morningBriefingSwitch,
         dailyReviewSwitch, dailyReviewCalendarSwitch,
         compactModeSwitch, compactDockSwitch, compactBadgeSwitch]
    }
    var debugCompactModeSwitch: HelmToggle { compactModeSwitch }
    var debugCompactDockSwitch: HelmToggle { compactDockSwitch }
    var debugCompactBadgeSwitch: HelmToggle { compactBadgeSwitch }
    /// How many cards actually reached `cardsContainer`'s own view tree.
    /// Exists for `checkSettingsRendersOnFirstLoad`, which guards the
    /// "every card exists and none of them is on screen" regression this
    /// file's detail-pane rebuild could reintroduce - now the selected
    /// category's count rather than all ten, since the other six categories
    /// are deliberately detached.
    var debugCardsInTree: Int { cardsInOrder.filter { $0.isDescendant(of: cardsContainer) }.count }
    /// The Appearance card's own theme-picker grid, one entry per row
    /// (`HelmResponsiveGrid.rows`'s dark-theme rows first, then the light
    /// ones), giving the column count `.fillEqually` actually divided that
    /// row into. Used by `SettingsThemeLayoutParitySelfTest` to assert the
    /// grid's own density is a pure function of layout width and never of
    /// which theme happens to be selected - the second half of the bug
    /// `fm/grandline-settings-layout-theme-dependent-fix` closed, since this
    /// grid's own column count is derived from `appearanceContainer`'s real
    /// width.
    var debugAppearanceGridColumnCounts: [Int] {
        appearanceContainer.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.count }
    }

    /// UI11: every theme card's own name label, so a suite can ask the one
    /// question the column count cannot answer - whether the name actually
    /// *fits* the card it was laid into. A column count that looks sensible
    /// still truncates if the container was narrower than the grid believed.
    var debugThemeNameLabels: [NSTextField] { themeNameLabels.filter { $0.window != nil || $0.superview != nil } }
    #endif

    private func applyTheme() {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)
        sidebar.applyTheme(theme)
        for card in cards { card.applyTheme(theme) }
        // The recorders paint their own chrome and their own recording state,
        // so they take the theme directly rather than through any of the
        // label/hover registries below.
        for recorder in shortcutRecorders.values { recorder.applyTheme(theme) }
        // Sections that rebuild rather than re-theme register a fresh label
        // every time, so drop the ones whose view is gone - same convention
        // `rebuildSecuritySection` already applies to `hoverRows`. Safe to do
        // here rather than at each rebuild site because `mutedLabel` tints a
        // label at creation too, so anything dropped early is still correct.
        subtitleViews.removeAll { $0.superview == nil }
        for label in subtitleViews {
            label.textColor = muted
        }
        for toggle in [autoReconnectSwitch, notifySwitch, morningBriefingSwitch,
                       dailyReviewSwitch, dailyReviewCalendarSwitch] {
            toggle.applyTheme(theme)
        }
        for row in hoverRows {
            row.normalColor = .clear
            // §6.5's `rowHover` - a warm near-white, not a wash of the outline
            // colour, which on paper reads as grey grime rather than a hover.
            row.hoverColor = theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
                : line.withAlphaComponent(0.18)
        }
        for v in separatorViews {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
    }
}

extension SettingsController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        textFieldChanged(field)
    }
}

/// Fix 4: a plain `NSView` used as a scroll view's document view puts y=0 at
/// the *bottom* (AppKit's default, unflipped coordinate space), so a fresh
/// layout can present as scrolled to the end. Flipping the document view is
/// the standard fix - y=0 becomes the top, matching how the content's own
/// Auto Layout constraints are written (top-down, via `stack.topAnchor`).
/// Not file-private: `HostEditorController`'s scroll view (cockpit-native-
/// host-pages Fix 2) hits the exact same issue and shares this type rather
/// than a second copy.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension Array {
    /// Split into fixed-size groups, last group possibly shorter. Used by
    /// the Appearance grid to wrap theme cards into bounded-width rows.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// An `NSStackView` that tells its owner when it has been laid out.
///
/// Review #3's UI11. A view whose *content* depends on its own width has to
/// hear about its own layout pass; a view controller's `viewDidLayout` is not
/// that signal for a child controller (see
/// `SettingsController.containerWidthMayHaveChanged`'s own note, and
/// `ToolsController`'s before it), and the window resize notification only
/// fires on a resize - never on a first visit at whatever size the window was
/// already at.
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
