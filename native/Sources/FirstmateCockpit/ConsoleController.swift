// Manjesh Grand Line - native macOS app.
//
// The console: one surface hosting a **flexible collection of tabs**, each a
// SwiftTerm terminal. This is Phase 0 of the connection-manager work (design
// report `data/cockpit-ssh-manager-research/report.md`, Section A4/A5 + Section D
// Phase 0): the old fixed `enum Tab { case shell, mirror }` is gone, replaced by
// `[TabModel]` rendered in a dynamic tab bar that grows and shrinks.
//
// What the tab model buys us:
//   - **New tab** (⌘T / the "+" button): a fresh login shell.
//   - **Duplicate** (⌘D): a new tab running the *same* argv as the current one -
//     the primitive that will later duplicate a host session.
//   - **Rename** (double-click a tab, ⌘⇧R, or right-click -> Rename): per-tab
//     name that never touches the process.
//   - **Close** (⌘W / the "×"): with the last-tab edge case handled - closing the
//     final tab opens a fresh shell so the window is never empty.
//
// The pinned Firstmate host opens with a single Shell tab
// (`fm/grand-line-remove-firstmate-mirror` deleted the herdr-attached tab
// this console used to open alongside it - see that file's PR for the full
// removal and why). Every tab is a paste-hardening `CockpitTerminalView`, so
// screenshot-paste into Claude works on all of them, and every terminal gets
// Helm theming, font zoom, find, copy, a
// generous scrollback, and smooth native scrolling.

//
// **GL-36: where the rest of this controller lives.** This file used to be
// 2,297 lines holding seven separable features at once. It is now the core -
// the stored state, `init`, `loadView` and the view lifecycle - and the
// features it hosts sit in one file each, split verbatim along the `// MARK:`
// seams this file already had:
//
//   - `ConsoleController+Tabs.swift`       tab lifecycle, selection, rename,
//                                          close, reconnect, window title,
//                                          `LocalProcessTerminalViewDelegate`
//   - `ConsoleController+Sessions.swift`   what a tab runs: the Firstmate
//                                          host's own shell, one-shot
//                                          command tabs, `ssh` + key unlock
//   - `ConsoleController+Toolbar.swift`    the page toolbar, the Compose
//                                          popover, theme/font/find/copy
//                                          actions
//   - `ConsoleController+SRELead.swift`    the whole per-tab SRE Lead pane
//   - `ConsoleController+LogCapture.swift` Block View + the Log Analyzer
//                                          capture bridge
//   - `ConsoleController+TestSupport.swift` the `debug*` hooks the console's
//                                          self-tests drive - now behind
//                                          `FM_SELFTESTS`, so unlike before
//                                          they no longer ship in the `.app`
//
// Nothing moved changed: the split was verified to be line-for-line verbatim
// against the pre-split file (modulo the access change below), and every
// console-touching suite - block view restart, SRE Lead per-tab, the SRE Lead
// bridge, notification-center SRE Lead - passes unchanged.
//
// **The one real cost, stated plainly.** Swift's `private` is file-scoped, so
// members this controller's own extensions reach across those file
// boundaries are now internal rather than `private`. They are still
// module-internal and nothing outside this app can see them, but the compiler
// no longer enforces "only the console touches this". That is the price of
// the split; the alternative was either leaving one 2,300-line file or
// inventing coordinator objects that would need the current tab, the toolbar
// and the terminal card handed to them and would buy nothing beyond the file
// boundary an extension already gives. Treat every member below as private to
// the `ConsoleController*.swift` family.

import AppKit
import SwiftTerm

final class ConsoleController: NSViewController, LocalProcessTerminalViewDelegate, DaylightDrillActions {

    /// The saved-keys Keychain (Phase 2) - consulted only to resolve a host's
    /// `.ssh` tab into a live `-i <path>` at start/reconnect time
    /// (`connectSSH`); everything secret stays inside `KeychainKeyStore` /
    /// `SSHKeyMaterializer`.
    let keyStore: SSHKeyStore

    /// The snippet library (Phase 3, B2/B5) - consulted to resolve a host's
    /// startup-snippet id, and by `runSnippetInActiveTab` for the Snippets
    /// panel's "Run" action.
    let snippetStore: SnippetStore

    /// Fix 1 (dedicated host pages): `false` for a per-host console
    /// (`AppShellController.connectHost`'s `makeHostConsole` factory), which
    /// governs two related behaviours instead of one - both express "this is
    /// the one shared, general-purpose console, not a page dedicated to a
    /// single host": (1) `loadView` only opens the Shell tab on
    /// launch when this is `true`; (2) `closeTab`'s "never leave the window
    /// empty" fallback only applies when this is `true` - a dedicated host
    /// page is allowed to end up with zero tabs after its one ssh tab is
    /// closed, since `ConsoleController.connectSSHIfNeeded` re-opens it the
    /// next time the host is connected to. Getting (2) wrong was a real bug:
    /// falling back to a generic shell tab left `tabs` non-empty, which made
    /// `connectSSHIfNeeded`'s `tabs.isEmpty` guard permanently skip
    /// reconnecting that host.
    let isFirstmateConsole: Bool

    init(keyStore: SSHKeyStore, snippetStore: SnippetStore, isFirstmateConsole: Bool = true) {
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        self.isFirstmateConsole = isFirstmateConsole
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `fm/grandline-notification-center`: fired when an SRE Lead reply
    /// lands on a tab that isn't the one currently visible to the captain
    /// (a different tab selected, or this whole host page not the currently
    /// shown destination). `AppShellController.connectHost` wires this to
    /// build the in-app notification and its own navigate-back-to-this-tab
    /// closure - this controller only reports the event, it doesn't know
    /// about rail destinations or other host pages.
    var onSRELeadReplyWhileBackground: ((TabModel) -> Void)?

    // MARK: Tabs

    var tabs: [TabModel] = []
    var currentTab: TabModel?
    var hasAppeared = false

    /// Scrollback retained per normal-screen terminal. SwiftTerm defaults to 500
    /// lines; a shell session wants much more so history that scrolls off the top
    /// stays reachable.
    let scrollbackLines = 10_000

    /// GL-36: lives here rather than in `ConsoleController+LogCapture.swift`
    /// with the rest of Block View, because a Swift extension cannot declare
    /// a stored property.
    /// Whether the current tab is showing parsed blocks instead of raw
    /// scrollback right now - a per-console, session-only toggle (not
    /// persisted, not a process-wide flag like the original PR #79/#83
    /// attempts' `BlockViewManager`) since Stage 0 only ever has at most one
    /// opted-in tab per console to toggle at all. Only ever visibly matters
    /// for a tab with a `blockContainer` - see `updateTabViewVisibility`.
    var blockViewShowing = false

    // MARK: Theme + font

    /// Mirrors `ThemeManager.shared.theme` - kept as a local var so the many
    /// call sites below don't all become `ThemeManager.shared.theme`, but the
    /// manager (not this property) is the source of truth: the light/dark
    /// toggle (moved onto `DaylightBarController` -
    /// `fm/grandline-daylight-theme-toggle-relocate` - since it's an app-wide
    /// preference, not Console-specific) writes through it directly, and
    /// every window that needs to match (Hosts/Keys/Snippets) observes the
    /// same manager instead of tracking its own copy.
    var theme: HelmTheme = ThemeManager.shared.theme
    /// Mirrors `FontSizeManager.shared.size` (`fm/cockpit-tools-page-ui-polish`) -
    /// same "local var kept live via `observe`" convention as `theme` above,
    /// so every open tab's font stays in sync with Settings' presets and the
    /// Tools page's own monospace text, regardless of which one changed it.
    var fontSize: CGFloat = FontSizeManager.shared.size

    func currentFont() -> NSFont {
        NSFont(name: "Menlo", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: Chrome views

    /// The shared page toolbar (Phase 7, audit §3.2's "Page toolbars"). This
    /// bar used to be a hand-rolled 42pt `NSView` with its own separator, and
    /// Tools' own comment said it was a copy of this one - `HelmPageToolbar`
    /// is now the single definition of the height, fill, hairline and insets
    /// for all three pages that have such a bar.
    let tabBar = HelmPageToolbar()
    let content = NSView()
    let tabsStack = NSStackView()

    /// The bordered-terminal-card chrome (`fm/grandline-sre-lead-app-feel`) -
    /// see `ConsoleCardChrome.swift`'s header for the whole mechanism and why
    /// it is drawn over the terminal rather than wrapped around it. Always the
    /// topmost subview of `content`, hidden unless the current tab has SRE
    /// Lead active.
    let cardChrome = ConsoleCardChrome(frame: .zero)

    /// Set by `AppShellController`: "my live numbers changed, re-read my
    /// subtitle" (Daylight §6.4). Fired from `styleChips()`, which is already
    /// the one place every tab add / close / rename / selection funnels
    /// through, so the header line and the tab strip cannot disagree.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Whether the SRE Lead pane is currently up. Recorded rather than
    /// re-derived so `refreshTerminalCardChrome()` - which a theme change also
    /// calls - has one answer for "is a pane open" instead of inferring it
    /// from a constraint's constant.
    var sreLeadPaneIsOpen = false

    /// The workspace margin: how far the drawn card sits from `content`'s
    /// edges, and the gap between the terminal card and the SRE Lead panel.
    /// Zero on the shared Firstmate console, which can never show the card -
    /// see `terminalInset`.
    var cardMargin: CGFloat { isFirstmateConsole ? 0 : HelmMetrics.s3 }

    /// Breathing room between the card's drawn border and the terminal's own
    /// first glyph column, the mockup's `.terminal { padding }`. Without it
    /// the 1pt border lands directly on the leading edge of the first
    /// character cell - seen in a real render, where it clipped the left edge
    /// of every line's first glyph.
    var cardInnerPadding: CGFloat { isFirstmateConsole ? 0 : HelmMetrics.s2 }

    /// How far every terminal on this page is inset from `content`, for the
    /// whole controller's lifetime.
    ///
    /// **Fixed, never toggled - that is the point.** This is what gives the
    /// card its margin *and* its inner padding, and the only way to have
    /// either without ever changing a `TerminalView`'s frame
    /// (`ConsoleCardChrome.swift`'s header, and the scrollback-truncation bug
    /// `fm/cockpit-sre-lead-ux-fixes` fixed) is for the inset to exist from
    /// the moment the terminal is created and stay put. With SRE Lead closed
    /// the band is `content`'s own `backgroundHex` - the terminal's own
    /// background colour - so it reads as ordinary terminal padding rather
    /// than a card.
    ///
    /// The cost is real and bounded: 20pt each side of a ~9.5pt cell is about
    /// 4 of ~145 columns on a laptop-width window, and no output is ever
    /// hidden - the terminal simply lays out at the narrower width from the
    /// start, rather than being reflowed into it later.
    ///
    /// **Zero on the shared Firstmate console.** SRE Lead is a dedicated-host-
    /// page-only affordance (`buildTabBar` only builds its button when
    /// `!isFirstmateConsole`), so that console can never show the card and has
    /// no reason to pay for its margin. That keeps its Shell tab byte-for-byte
    /// flush and at its full column count, exactly as before this change.
    var terminalInset: CGFloat { cardMargin + cardInnerPadding }
    /// Every toolbar glyph is a bordered icon square now
    /// (`HelmPageToolbar.iconButton`, i.e. `HelmButton(.secondary)`), not a
    /// bare borderless image button. That was the audit's "two icon-button
    /// languages, 40pt apart" finding: the app top bar renders its icons as
    /// bordered squares, and this bar - one bar below it - rendered up to
    /// eleven chrome-less glyphs at identical weight.
    ///
    /// Typed `HelmButton` rather than `NSButton` specifically so the one
    /// state-coloured glyph below can set `tint` (Block View's accent while
    /// showing - see `updateBlockViewControls`). `HelmButton.restyle()` owns
    /// `contentTintColor`, so assigning that directly would be silently
    /// overwritten on the next theme change - `tint` is the seam.
    var plusButton: HelmButton!
    var findButton: HelmButton!
    var zoomInButton: HelmButton!
    var zoomOutButton: HelmButton!
    /// `fm/cockpit-block-view-stage0` - only ever shown for the one opted-in
    /// host's tab, see `updateBlockViewControls`.
    var blockViewToggleButton: HelmButton!
    var blockViewRefreshButton: HelmButton!
    /// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-
    /// composer`) - only ever shown for a plain `.shell` tab that isn't a
    /// one-shot command, see `updateComposeControls`.
    /// `fm/grandline-log-analyzer-build`, spec §2's "Send from Terminal":
    /// captures this tab's most recent completed command (or the captain's
    /// current selection) and hands it to the Log Analyzer. A peer of SRE
    /// Lead and Compose in the same toolbar cluster, and - like SRE Lead -
    /// a dedicated-host-page affordance only (`!isFirstmateConsole`): the
    /// shared Firstmate console's own Shell tab is this app's own
    /// session, not infrastructure output an investigation would be built
    /// from. See `LogAnalyzerCapture.swift` for exactly what gets captured
    /// and what happens on a host without per-command block tracking.
    var analyzeLogsButton: HelmButton?

    /// Fired by "Analyze Logs" with an already-built capture plus this
    /// tab's label. Forwarded (never handled here) exactly like every other
    /// cross-destination action this controller exposes - the console knows
    /// nothing about the Log Analyzer destination.
    var onAnalyzeLogs: ((LogTerminalCapture, String) -> Void)?

    /// F8 (incident mode): forwarded to `AppShellController`, which opens the
    /// Log Analyzer on a saved investigation. Fired only from the incident
    /// card's Evidence tab, for a row that carries a real investigation id.
    var onOpenInvestigation: ((String) -> Void)?

    // MARK: F8 - incident mode (dedicated host pages only)
    //
    // GL-36: stored here rather than in `ConsoleController+Incident.swift`
    // with the rest of the feature, because a Swift extension cannot declare
    // a stored property.

    /// Which saved host this page belongs to, set by
    /// `AppShellController.connectHost`. `nil` on the shared Firstmate
    /// console, which has no single host and therefore no incidents - the
    /// toolbar button hides itself in that case (`updateIncidentControls`).
    var hostIdentity: ConsoleHostIdentity? {
        didSet { updateIncidentControls() }
    }

    /// One store per page. It re-reads its own directory on demand and
    /// memoises, so a second instance is cheap and never a second source of
    /// truth - the same "each page keeps an independent copy of the same
    /// underlying check" convention `UpdatesController`/`BootstrapController`
    /// already use for `DependencyCatalog`.
    lazy var incidentStore = IncidentStore()

    /// The red toolbar action, and the always-visible active-incident
    /// indicator - see `IncidentCardView`'s header for why the card itself is
    /// a popover rather than an inline strip.
    var incidentButton: HelmButton?
    let incidentPopover = NSPopover()
    let incidentCard = IncidentCardView()

    /// How many SRE Lead turns each tab has completed during the current
    /// incident, so a timeline entry can say "turn 3" without re-deriving it
    /// from a chat view that may since have been torn down. Keyed by
    /// `TabModel.id`, exactly like every other per-tab bookkeeping here.
    var sreLeadTurnCounts: [UUID: Int] = [:]

    var composeButton: HelmButton!
    let composer = ConsoleComposerController()

    /// The "Claude usage" popover trigger, restored per captain request
    /// beside Compose - the toolbar prototype's own original pairing (see
    /// this file's own comment above `sreLeadButton`, and
    /// `ConsoleController+Toolbar.swift`'s header). Removed along with the
    /// herdr-attached "Mirror" tab it used to live on
    /// (`fm/grand-line-remove-firstmate-mirror`); `QuotaUsagePopover.swift`'s
    /// header has the full history. Availability mirrors `composeButton`
    /// byte-for-byte (`updateQuotaUsageControls`) - it's the same shape of
    /// feature (a plain `.shell`/`.ssh` tab, never a one-shot command), on
    /// both the shared Firstmate console and every dedicated host page.
    var quotaUsageButton: HelmButton!
    let quotaUsage = QuotaUsageController()

    // MARK: SRE Lead (dedicated host pages only - see `SRELead.swift`)

    /// `fm/grandline-sre-lead-per-tab`: SRE Lead's own state (session,
    /// bridge, runner, chat, phase) lives on each `TabModel.sreLead`, not
    /// here - see `SRELeadTabState.swift`'s header. `ConsoleController` only
    /// owns the shared chrome: the toolbar button, the pane, and the header -
    /// every started tab's chat is added as a hidden sibling inside
    /// `sreLeadPane` and shown/hidden to match whichever tab is currently
    /// selected (`updateSRELeadPaneContent`).
    ///
    /// A plain `HelmButton` from the same `makeLabeledButton` factory as Find
    /// / Compose / Blocks / Claude usage - it used to be a bespoke dot-plus-
    /// label view, see `SRELeadPhase.swift`'s header.
    var sreLeadButton: HelmButton?

    /// The full-height strip overlaying `content`'s trailing edge. It is the
    /// **clipping backdrop**, not the visible panel: transparent, so the
    /// workspace floor and the pane card's own drop shadow (both painted by
    /// `cardChrome` underneath) show through its padding, and clipping so the
    /// card inside it is cut off cleanly while the width animates from zero.
    let sreLeadPane = NSView()
    /// The visible SRE Lead panel - a real `HelmCard` surface (fill, 1pt
    /// border, `rPanel` radius) that clips its own children, so the header and
    /// the chat below it inherit the card's rounded corners with no
    /// per-child corner masking (`fm/grandline-sre-lead-app-feel`).
    ///
    /// This replaced the 3pt `accentHex` separator bar that used to run down
    /// the pane's leading edge. That bar existed because `chromeBackgroundHex
    /// == backgroundHex` in three of the twelve palettes, so the pane's fill
    /// alone could not prove it was a separate surface from the terminal
    /// (`fm/grandline-sre-lead-polish`). That reasoning is satisfied more
    /// strongly here and in every theme: the two panels are now separated by a
    /// real `HelmMetrics.s3` gap of workspace floor with a 1pt outline on each
    /// side of it, which no palette can collapse - a fill coincidence cannot
    /// hide two borders and the space between them.
    let sreLeadCard = NSView()
    let sreLeadHeader = NSView()
    /// The panel's identity block, mirroring the reference mockup's `sre-head`:
    /// the same `sparkles` glyph in a tinted tile that `SRELeadChatView`
    /// already puts on every assistant reply, so the panel and its messages
    /// read as one agent rather than two unrelated treatments.
    let sreLeadHeaderIcon = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.rChip)
    /// Live phase readout ("Ready" / "Starting…" / "Failed"), the mockup's
    /// `status` chip. Uses the shared `ToolRowLayout.pill`, so its hue is
    /// contrast-corrected against the card fill like every other pill in the
    /// app rather than being a raw tint used as text (Phase 0's rule).
    let sreLeadStatusPill = NSView()
    let sreLeadStatusLabel = NSTextField(labelWithString: "")
    /// Separates the header bar from the body below it - needed once the
    /// pane's body switched from `backgroundHex` to `chromeBackgroundHex`
    /// (matching the header's own long-standing fill) so the two don't read
    /// as one indistinguishable block (`fm/grandline-sre-lead-polish`).
    let sreLeadHeaderDivider = NSView()
    let sreLeadHeaderLabel = NSTextField(labelWithString: "SRE Lead")
    /// "Generate Postmortem" (`fm/grandline-sre-lead-postmortem`) - hidden
    /// until `updateGeneratePostmortemButton()` sees a real assistant reply
    /// in the current tab's chat (see `SRELeadChatView.hasRealExchange`), so
    /// it never appears over an empty/just-opened session.
    let sreLeadGeneratePostmortemButton = NSButton()
    /// Shown inside `sreLeadPane` whenever the currently selected tab has no
    /// `sreLead` state yet - "started, running, or not-yet-started, never
    /// another tab's" (design doc). Lets a captain start SRE Lead for
    /// whichever tab is on screen without reaching for the toolbar pill.
    let sreLeadEmptyStateView = NSView()
    let sreLeadEmptyStateLabel = NSTextField(wrappingLabelWithString: "SRE Lead hasn't been started for this tab yet.")
    let sreLeadEmptyStateButton = HelmButton(title: "", variant: .primary)
    /// Only ever created on demand (`generatePostmortemClicked`) - a fresh
    /// `DocsRunbookStore()` shares `DocsRunbookGitSync.shared`'s singleton
    /// clone/queue exactly like `DocsController`'s own instance does (see
    /// that type's header), so this never opens a second clone of the repo.
    lazy var docsRunbookStore = DocsRunbookStore()
    var sreLeadPaneWidthConstraint: NSLayoutConstraint!
    let sreLeadPaneWidth: CGFloat = 380

    /// Captain-specified cap (task brief): at most this many tabs on one
    /// host page may have SRE Lead running (`.starting`/`.ready`)
    /// simultaneously. Attempting to start a 6th shows a clear alert instead
    /// of silently queuing or silently refusing.
    let sreLeadMaxConcurrent = 5

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 660))
        root.wantsLayer = true
        view = root

        buildTabBar()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        root.addSubview(content)

        // Added before any tab exists, and kept topmost: every terminal /
        // block container below is inserted with `positioned: .below,
        // relativeTo: cardChrome`, so a tab opened later can never end up
        // drawing over the card's own border.
        cardChrome.pad = cardMargin
        cardChrome.isHidden = true
        content.addSubview(cardChrome)

        buildSRELeadPane()
        root.addSubview(sreLeadPane)

        buildIncidentCard()

        // The one path that ever sends a composed command anywhere - see
        // `ConsoleComposerPopover.swift`'s header for why this is never
        // triggered automatically.
        // S2: the composed command is written by a model (`claude -p`) and runs
        // the instant this fires - the *intent* is the captain's, but the shell
        // command is not, and it used to reach the terminal with no gate at all
        // while the DevOps Command Library's own send has always confirmed.
        // Same asymmetry as S1, one path over.
        composer.onRunInTerminal = { [weak self] command in
            CommandRiskConfirmation.confirmAIAuthored(command: command,
                                                      source: "Compose") {
                self?.currentTab?.terminal.send(txt: command + "\n")
            }
        }

        sreLeadPaneWidthConstraint = sreLeadPane.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),

            // `content` (and therefore every tab's terminal inside it,
            // including the primary interactive tab SRE Lead's bridge
            // injects into) is pinned to the root's full width, never to
            // `sreLeadPane`'s leading edge. Opening/closing the SRE Lead
            // pane only changes `sreLeadPaneWidthConstraint` below - it used
            // to also resize `content` (trailing was pinned to
            // `sreLeadPane.leadingAnchor`), and any frame change on a
            // SwiftTerm view triggers `resize(cols:rows:)`, which reflows
            // the buffer at the new column count and can truncate/garble
            // scrollback the captain had already built up logging into a
            // bastion. The pane now overlays the right edge of `content`
            // (it's added after `content`, so it already renders on top)
            // instead of pushing it - a real width change on `content` only
            // ever happens from an actual window resize now, not from
            // toggling this pane.
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            cardChrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cardChrome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cardChrome.topAnchor.constraint(equalTo: content.topAnchor),
            cardChrome.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            sreLeadPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sreLeadPane.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sreLeadPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sreLeadPaneWidthConstraint,
        ])

        // The starting set: the pinned "Firstmate" host's own Shell tab,
        // matching the previous fixed-tabs behaviour (Fix 4: this is now also
        // reachable from the Hosts sidebar's pinned entry, but the app still
        // lands here automatically on launch). Its process starts in
        // `viewDidAppear` (once the view is on screen). A per-host console
        // (Fix 1) opts out - its one tab is added on demand by
        // `connectSSHIfNeeded` instead.
        if isFirstmateConsole {
            openFirstmateHost(focus: false)
        }

        // Follow the shared Helm theme (Fix 2) rather than a private copy, so
        // toggling it from the toolbar, ⌘⌥T, or Settings all land here. The
        // token is kept (not discarded, unlike every other observer in this
        // app) because - since Fix 1 - a `ConsoleController` isn't
        // necessarily permanent: a per-host page is deallocated when its
        // host is deleted, and without unregistering here that would leak a
        // dead closure into `ThemeManager` forever (see `shutdown()`).
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }

        // Follow the shared font size (`fm/cockpit-tools-page-ui-polish`) the
        // same way - a per-host page can be torn down mid-session, so the
        // token is kept and unregistered in `shutdown()`, not discarded.
        fontSizeObservation = FontSizeManager.shared.observe { [weak self] size in
            guard let self else { return }
            self.fontSize = size
            let f = self.currentFont()
            for tab in self.tabs { tab.terminal.font = f }
        }
    }

    var themeObservation: ThemeObservation?
    var fontSizeObservation: FontSizeObservation?

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        for tab in tabs where !tab.started { startTab(tab) }
        if let tab = currentTab { view.window?.makeFirstResponder(tab.terminal) }
    }
}
