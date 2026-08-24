// Manjesh Grand Line - native macOS app.
//
// The native Settings panel (Fix 3) - rebuilt to match the richer web
// cockpit layout (`backend/static/index.html`'s Settings screen): icon +
// title section headers, generous spacing, and grouped cards rather than a
// flat list of rows. Three sections (Sign-in is skipped - native has no
// login):
//
//   - Connection: the mirror-target field, upgraded with a live "Detect"
//     session picker (`TmuxMirror.listSessions()`) showing every discovered
//     tmux pane as a selectable card (target, command/cwd, a "home" badge
//     when its cwd is inside the firstmate home) - clicking one sets it as
//     the mirror target. The working-directory chooser (previously under
//     "General") lives here too.
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
    var drillHeaderSubtitle: String? {
        "\(HelmTheme.allThemes.count) themes \u{00B7} everything here is stored locally on this machine"
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

    // Connection
    private let mirrorTargetField = HelmTextField(placeholder: "firstmate")
    private let sessionsStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionsStack = NSStackView()
    private let shellCwdField = HelmTextField(placeholder: "~ (Home)")

    // Appearance
    private let appearanceContainer = NSStackView()

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

    /// The six section cards in reading order - the input to
    /// `rebuildCardLayout()`, which decides whether they sit in one column or
    /// two. Separate from `cards` (the re-theming registry) because that list
    /// is append-on-create and says nothing about arrangement.
    private var cardsInOrder: [HelmCard] = []

    /// The page's own vertical stack. Holds either the six cards directly (one
    /// column) or a single horizontal two-column row.
    private let cardsContainer = NSStackView()

    /// Which arrangement is currently built, so a resize or a theme change that
    /// does not cross a boundary costs nothing.
    private var lastLayoutWasTwoColumn: Bool?

    /// The narrowest content width two columns are allowed at.
    ///
    /// Not a taste value: below this each card's own rows (a title, a wrapping
    /// description and a trailing control cluster) start fighting for the same
    /// ~400pt, and the honest fallback is one full-width column. It also keeps
    /// this page clear of the window-width floor `AppShellBodyWidthSelfTest`
    /// guards - two columns simply do not engage at the narrow end of its
    /// sweep, rather than engaging and then having to be pried back open.
    private static let twoColumnMinWidth: CGFloat = 940

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

        let connection = card(icon: "network", tint: .info, title: "Connection", subtitle: "Mirror target and working directory", content: buildConnectionSection())
        let appearance = card(icon: "paintpalette", tint: .violet, title: "Appearance", subtitle: "\(HelmTheme.allThemes.count) Helm themes, light and dark", content: buildAppearanceSection())
        let terminal = card(icon: "terminal", tint: .warn, title: "Terminal", subtitle: "Font size and behavior", content: buildTerminalSection())
        // F12. Its own card rather than a fourth row inside Terminal: this is
        // not a terminal preference, it is the one place in the app that opts
        // into a daily `claude -p` call, and the card's subtitle is where that
        // gets said.
        let briefing = card(icon: "sparkles", tint: .accent, title: "Morning briefing",
                            subtitle: "One generated summary of your fleet, PRs, tasks, drift and quota",
                            content: buildMorningBriefingSection())
        let security = card(icon: "lock.shield", tint: .violet, title: "Security", subtitle: "System-level convenience toggles", content: buildSecuritySection())
        // F1 / GL-11's Health card moved off this page entirely, onto its own
        // rail destination (`fm/grandline-health-sidebar-move`,
        // `HealthController.swift`) - the same correction F11's Schedules
        // card already got. Backup & Restore is the last card here now.
        let backup = card(icon: "tray.and.arrow.up.fill", tint: .info, title: "Backup & Restore", subtitle: "Move saved hosts, snippets, and preferences between machines", content: buildBackupSection())

        // §7's "two-column cards" is a *layout* decision taken per pass rather
        // than a fixed stack, so `cardsInOrder` is the content and
        // `rebuildCardLayout()` is the arrangement. Order is the reading order
        // in one column and the round-robin source in two.
        cardsInOrder = [connection, appearance, terminal, briefing, security, backup]

        let stack = cardsContainer
        stack.orientation = .vertical
        stack.alignment = .leading
        // 14 - unchanged from the flat stack this replaced, so a captain on any
        // of the twelve pre-Daylight palettes sees the same page they always
        // did. The two-column arrangement uses §2.7's own 16pt gap instead.
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        rebuildCardLayout()

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
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
        // §7's two-column arrangement is width-driven, so it re-decides on the
        // same signal the theme grid's column count already did.
        rebuildCardLayout()
        layoutDidChangeWidths()
        let width = appearanceContainer.frame.width
        guard width > 0, abs(width - lastAppearanceGridWidth) > 0.5 else { return }
        lastAppearanceGridWidth = width
        rebuildAppearanceGrid()
    }

    // MARK: Card layout (Daylight §7's "two-column cards")

    /// One column or two, decided from the container's real width.
    ///
    /// **Daylight only.** Two columns is this design's own arrangement for
    /// this page; the twelve pre-Daylight palettes keep the single column they
    /// have always had, which is the same rule slices 1 and 2 held to - a
    /// half-migrated look is worse for a captain on another palette than no
    /// migration at all.
    ///
    /// The split is a plain round robin over `cardsInOrder` rather than any
    /// attempt to balance heights. Heights here are genuinely data-dependent
    /// (the Appearance card grows with the theme grid's row count, Security
    /// with its status, Connection with however many tmux panes Detect found),
    /// so a balancing pass would reshuffle the cards under the captain as that
    /// data changed - which is worse than a slightly uneven pair of columns
    /// that always holds the same card in the same place.
    private func rebuildCardLayout() {
        // Re-entrancy guard - defence in depth, and honestly labelled as such.
        // Reparenting six cards mutates the view tree, which can drive a layout
        // pass, which calls `viewDidLayout`, which lands back here mid-teardown.
        // The failure that was actually *measured* (all six cards left detached,
        // no superview, the page stuck in one column at 1500pt) was fixed by
        // reading the width from a source that does not move mid-rebuild - see
        // `contentColumnWidth()`; re-checked by injection, this guard alone does
        // not fix it and that fix alone does. It stays because a re-entrant
        // rebuild is a real hazard on its own terms, not because it is what
        // closed the bug.
        guard !isRebuildingCardLayout else { return }
        let twoColumn = theme.isDaylight && contentColumnWidth() >= Self.twoColumnMinWidth
        guard lastLayoutWasTwoColumn != twoColumn else { return }
        isRebuildingCardLayout = true
        defer { isRebuildingCardLayout = false }
        lastLayoutWasTwoColumn = twoColumn

        for v in cardsContainer.arrangedSubviews {
            cardsContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        // A card may be moving from one parent stack to another. The width tie
        // its previous arrangement gave it is held by *that* parent, not by the
        // card, and `removeFromSuperview()` is documented to drop any
        // constraint referring to the view being removed - so detaching each
        // card is what actually clears the old tie. Doing it explicitly (rather
        // than relying on the column stacks above being discarded) also covers
        // the one-column case, where the tie lives on `cardsContainer`, which
        // survives.
        for card in cardsInOrder { card.removeFromSuperview() }

        guard twoColumn else {
            for card in cardsInOrder {
                cardsContainer.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: cardsContainer.widthAnchor).isActive = true
            }
            layoutDidChangeWidths()
            return
        }

        let columns = (0..<2).map { index -> NSStackView in
            let column = NSStackView(views: cardsInOrder.enumerated()
                .filter { $0.offset % 2 == index }
                .map { $0.element })
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = HelmMetrics.s4
            column.translatesAutoresizingMaskIntoConstraints = false
            // AGENTS.md gotcha (12) + (13): an `NSStackView` resists clipping
            // below its arranged subviews at `.defaultHigh` (750) by default,
            // which is *above* `NSLayoutPriorityWindowSizeStayPut` (500) - so a
            // column of cards left at the default is a window-width floor,
            // doubled by `.fillEqually`. The stack-level API is the one that
            // bites here; the content-level one is a no-op on a view with no
            // intrinsic size.
            column.setClippingResistancePriority(.defaultLow, for: .horizontal)
            for card in column.arrangedSubviews {
                card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            return column
        }

        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = HelmMetrics.s4
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        cardsContainer.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: cardsContainer.widthAnchor).isActive = true
        layoutDidChangeWidths()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        rebuildCardLayout()
        layoutDidChangeWidths()
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

    /// How wide one card actually is - the whole content column in one-column
    /// mode, half of it (less the gap) in two.
    private func availableCardWidth() -> CGFloat {
        let container = contentColumnWidth()
        guard lastLayoutWasTwoColumn == true else { return container }
        return (container - HelmMetrics.s4) / 2
    }

    private var isRebuildingCardLayout = false

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
    /// rebuild rather than re-theme (`rebuildSecuritySection`,
    /// `refreshSessions`) create fresh labels without necessarily re-running
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

    private func descRow(title: String, desc: String, trailing: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        mutedLabel(descLabel)
        // 16 for the row container's own padding, 12 for the row spacing and
        // ~160 for the trailing control column (three preset buttons is the
        // widest one on this page) - the same shape as
        // `HealthCardView.descriptionWidth`, re-derived on every layout pass
        // rather than guessed once at 360.
        wrapping(descLabel, reserve: 16 + 12 + 160)

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

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
        let label = NSTextField(labelWithString: "Mirror target")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)

        let desc = NSTextField(wrappingLabelWithString: "The tmux target the console's Mirror tab attaches to. Detect lists every discovered session below - click one to select it.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        wrapping(desc)

        configure(mirrorTargetField)
        let detectButton = HelmButton(title: "Detect", variant: .secondary, symbol: "arrow.triangle.2.circlepath", target: self, action: #selector(detectClicked))

        let fieldRow = NSStackView(views: [mirrorTargetField, detectButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        mirrorTargetField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sessionsStatusLabel.font = .systemFont(ofSize: 11)
        mutedLabel(sessionsStatusLabel)

        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 4
        sessionsStack.translatesAutoresizingMaskIntoConstraints = false

        let mirrorGroup = NSStackView(views: [label, desc, fieldRow, sessionsStatusLabel, sessionsStack])
        mirrorGroup.orientation = .vertical
        mirrorGroup.alignment = .leading
        mirrorGroup.spacing = 6
        fieldRow.widthAnchor.constraint(equalTo: mirrorGroup.widthAnchor).isActive = true
        sessionsStack.widthAnchor.constraint(equalTo: mirrorGroup.widthAnchor).isActive = true

        let chooseCwd = HelmButton(title: "Choose\u{2026}", variant: .secondary, target: self, action: #selector(chooseShellCwd))
        configure(shellCwdField)
        shellCwdField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cwdRow = NSStackView(views: [shellCwdField, chooseCwd])
        cwdRow.orientation = .horizontal
        cwdRow.spacing = 8

        let cwdGroup = descRow(title: "Working directory", desc: "Where new Shell/Firstmate tabs open.", trailing: cwdRow)
        cwdRow.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let section = NSStackView(views: [mirrorGroup, separator(), cwdGroup])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        mirrorGroup.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
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

    @objc private func detectClicked() {
        refreshSessions()
    }

    /// GL-04: this used to run `TmuxMirror.listSessions()` synchronously - and
    /// it was reached from `loadView`, which runs inside `AppShellController`'s
    /// eager embed loop at launch, *before* `makeKeyAndOrderFront`. A wedged
    /// tmux server therefore meant the app never showed a window at all. The
    /// listing is bounded now (`TmuxMirror.commandTimeout`) and runs off the
    /// main thread; the rows appear when it answers.
    private func refreshSessions() {
        sessionsStatusLabel.stringValue = "Looking for tmux panes\u{2026}"
        sessionsStatusLabel.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = TmuxMirror.listSessions()
            DispatchQueue.main.async { self?.renderSessions(sessions) }
        }
    }

    private func renderSessions(_ sessions: [TmuxMirror.SessionInfo]?) {
        for v in sessionsStack.arrangedSubviews {
            sessionsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard let sessions else {
            sessionsStatusLabel.stringValue = "No tmux server running - start your first mate in tmux, then Detect."
            sessionsStatusLabel.isHidden = false
            return
        }
        if sessions.isEmpty {
            sessionsStatusLabel.stringValue = "No tmux panes found."
            sessionsStatusLabel.isHidden = false
            return
        }
        sessionsStatusLabel.isHidden = true
        let current = AppSettings.shared.mirrorTarget ?? ""
        for s in sessions {
            let card = sessionCard(s, isSelected: s.target == current)
            sessionsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: sessionsStack.widthAnchor).isActive = true
        }
    }

    private func sessionCard(_ s: TmuxMirror.SessionInfo, isSelected: Bool) -> NSView {
        let targetLabel = NSTextField(labelWithString: s.target)
        targetLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)

        var titleViews: [NSView] = [targetLabel]
        if s.isHome { titleViews.append(pillView(text: "home", colorHex: theme.accentHex)) }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .firstBaseline

        var subBits = [s.command]
        if !s.path.isEmpty { subBits.append(s.path) }
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        mutedLabel(subLabel)
        subLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleRow, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        check.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        check.isHidden = !isSelected
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, check])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = HoverHighlightView()
        // A session card is a row *inside* the Connection card, so under
        // Daylight it takes the well treatment (§6.5/§6.9) rather than the card
        // treatment: `chromeBackgroundHex` there is the same white the card
        // behind it already is, and a white row on a white card is invisible.
        card.cornerRadius = theme.isDaylight ? HelmField.rowCornerRadius(for: theme) : 8
        card.layer?.borderWidth = isSelected ? 1.5 : HelmField.hairlineBorderWidth
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])
        let base = theme.isDaylight
            ? HelmField.fill(theme)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)
        card.normalColor = base
        card.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.rowHover)
            : base.hoverShifted(by: 0.08, forMode: theme.mode)
        card.layer?.borderColor = (isSelected
            ? HelmTheme.nsColor(theme.accentHex)
            : HelmField.border(theme)).cgColor

        let click = NSClickGestureRecognizer(target: self, action: #selector(sessionCardClicked(_:)))
        card.addGestureRecognizer(click)
        card.identifier = NSUserInterfaceItemIdentifier(s.target)
        return card
    }

    @objc private func sessionCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        mirrorTargetField.stringValue = id
        AppSettings.shared.mirrorTarget = id
        refreshSessions()
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

    // MARK: Appearance

    private func buildAppearanceSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "A curated set of light and dark instrument-panel palettes, each contrast-verified to WCAG AA.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        wrapping(desc)

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

    private func rebuildAppearanceGrid() {
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
            ? HelmTheme.nsColor(DaylightPalette.rowHover)
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

    // MARK: Morning briefing (F12)

    private func buildMorningBriefingSection() -> NSView {
        morningBriefingSwitch.onToggle = { [weak self] in self?.morningBriefingToggled() }
        let toggleRow = descRow(
            title: "Show a morning briefing on Overview",
            desc: "On the first visit to Overview each day, generate one short paragraph from the fleet snapshot, PR queue, due tasks, drift and quota - each clause linking to the page it came from.",
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

    // MARK: Backup & Restore

    private let backupStatusLabel = NSTextField(wrappingLabelWithString: "")

    /// Export/Import share one implementation (`BackupUI.swift`) with the
    /// Bootstrap page's "Restore Grand Line config" step - this card is just
    /// the two buttons plus a live counts line, never its own logic.
    private func buildBackupSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "Write everything this app knows locally - saved hosts, snippets, and the preferences above - to a single file, or bring one in from another machine. SSH private keys never leave the Keychain; a restored host referencing a key not on this machine needs that key re-added from the Keys screen.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        wrapping(desc)

        backupStatusLabel.font = .systemFont(ofSize: 11)
        mutedLabel(backupStatusLabel)

        let exportButton = HelmButton(title: "Export\u{2026}", variant: .secondary, target: self, action: #selector(exportBackupClicked))
        let importButton = HelmButton(title: "Import\u{2026}", variant: .secondary, target: self, action: #selector(importBackupClicked))

        let buttonRow = NSStackView(views: [exportButton, importButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let section = NSStackView(views: [desc, backupStatusLabel, buttonRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    private func refreshBackupStatus() {
        let hostCount = hostStore.hosts.count
        let snippetCount = snippetStore.snippets.count
        backupStatusLabel.stringValue = "Currently saved: \(hostCount) host\(hostCount == 1 ? "" : "s"), \(snippetCount) snippet\(snippetCount == 1 ? "" : "s")."
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
        case mirrorTargetField:
            AppSettings.shared.mirrorTarget = value.isEmpty ? nil : value
            refreshSessions()
        default:
            break
        }
    }

    // MARK: Sync

    private func refreshFromSettings() {
        guard isViewLoaded else { return }
        mirrorTargetField.stringValue = AppSettings.shared.mirrorTarget ?? ""
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

        rebuildAppearanceGrid()
        refreshSessions()
        refreshBackupStatus()
        applyTheme()
    }

    /// The repaint-only half of `refreshFromSettings` (GL-24). Re-reads nothing
    /// off disk, shells out to nothing, and rebuilds only what genuinely
    /// carries theme-derived colour it cannot re-derive itself (the theme grid's
    /// own cards, which show every palette's swatches).
    private func repaintForTheme() {
        guard isViewLoaded else { return }
        // Crossing the Daylight boundary changes the *arrangement*, not just
        // the colours - one column becomes two. `rebuildCardLayout` no-ops
        // unless that boundary actually moved.
        rebuildCardLayout()
        rebuildAppearanceGrid()
        applyTheme()
    }

    #if FM_SELFTESTS
    /// Probe surface for `DaylightDrillPageSlice6SelfTest`.
    var debugCards: [HelmCard] { cardsInOrder }
    var debugIsTwoColumn: Bool { lastLayoutWasTwoColumn == true }
    var debugToggles: [HelmToggle] { [autoReconnectSwitch, notifySwitch, morningBriefingSwitch] }
    #endif

    private func applyTheme() {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)
        for card in cards { card.applyTheme(theme) }
        // Sections that rebuild rather than re-theme register a fresh label
        // every time, so drop the ones whose view is gone - same convention
        // `rebuildSecuritySection` already applies to `hoverRows`. Safe to do
        // here rather than at each rebuild site because `mutedLabel` tints a
        // label at creation too, so anything dropped early is still correct.
        subtitleViews.removeAll { $0.superview == nil }
        for label in subtitleViews {
            label.textColor = muted
        }
        for toggle in [autoReconnectSwitch, notifySwitch, morningBriefingSwitch] {
            toggle.applyTheme(theme)
        }
        for row in hoverRows {
            row.normalColor = .clear
            // §6.5's `rowHover` - a warm near-white, not a wash of the outline
            // colour, which on paper reads as grey grime rather than a hover.
            row.hoverColor = theme.isDaylight
                ? HelmTheme.nsColor(DaylightPalette.rowHover)
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
