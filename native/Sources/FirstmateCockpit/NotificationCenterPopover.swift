// Manjesh Grand Line - native macOS app.
//
// The bar's bell + its dropdown panel (`fm/grandline-notification-center`,
// captain-approved design: `data/grandline-notification-center/design-
// reference.html`). Sits between the theme toggle and the avatar - the design
// doc's own annotated screenshot shows exactly this gap.
//
// **B5 (UI modernization audit §3B): the chrome is a `HelmBarPanel` now, not
// an `NSPopover`** - a borderless, radius-16, arrow-less panel anchored under
// the bell, styled like the ⌘K palette. The panel content below is unchanged;
// only what draws the box around it moved. See `HelmBarPanel`'s header for
// why, and for where the lock gate went.
//
// `NotificationBellButton` is a plain `NSButton` styled like `TopBarController.
// themeButton`, with a small badge overlay reusing `IconRailController.
// attachBadge`'s own fixed white-on-systemRed convention (never a theme-
// tinted badge - "reads as an alert the same way regardless of theme,"
// per that method's own doc comment) rather than inventing a second badge
// visual language.
//
// **The badge, and why it moved twice.** `fm/grandline-notification-bell-
// badge-fix` shipped it 2pt outside the button's own top-right corner (down
// from 5pt) and that still collided with the square's rounded curve: at a
// 34x34 box with a 9pt corner radius the curve starts well before the flat
// edges, so *any* small overlap positioned at that diagonal corner cuts
// across it. `fm/grandline-notification-bell-badge-fix-2` took the lesson
// `IconRailController.attachBadge` had already learned the hard way and
// stopped overlapping the square at all - widening the button's own frame
// (`controlWidth`) so the badge could sit entirely to the icon's right.
//
// **B2 (UI modernization audit §3B) moves it back inside, and the distinction
// that makes that work is the one both earlier fixes were missing**: the
// audit asks for "a Tahoe-style small dot/count attached to the **symbol's**
// corner", and a symbol's corner is not the square's corner. The glyph is a
// 14pt image centred in a 34pt tile, so its top-trailing corner sits well
// inside the tile's flat edges - nowhere near the radius that defeated both
// previous attempts. A 1.5pt ring in the tile's own fill separates the badge
// from whatever it overlaps, which is the standard treatment and is what lets
// it sit *on* the glyph rather than beside it.
//
// That also delivers the other half of B2 for free: with the outboard badge
// zone gone, `controlWidth == iconSize`, so the bell, the theme toggle and
// the Recents button are three identical 34x34 squares - "the History and
// theme buttons should match the bell's square", by construction rather than
// by three constants agreeing.
//
// The count is abbreviated at 10 ("9+") rather than 100 ("99+"): a badge that
// has to stay inside a 34pt tile has room for one digit, and the exact number
// is still spoken by the accessibility label and listed in full in the panel.
//
// The panel itself is a plain `NSStackView` of rows, rebuilt in place on
// every `GrandLineNotificationCenter.observe` firing (the list is always
// small by design - see the design doc's "avoid noise" section - so this
// app's usual `NSTableView`-for-large-lists convention doesn't apply here).
//
// `fm/grandline-notification-row-redesign` restyled each row from a flat,
// borderless dot+title+subtext line into its own bordered "claim card"
// (captain reference: a Slack-RCA claims panel - `data/grandline-
// notification-row-redesign/reference-target.png`) - a colored left accent
// bar, a small round icon badge, a bold uppercase kicker label, the body
// message, and a trailing chip carrying the entry's own source/clear-rule
// text. This is a rendering-only pass: `GrandLineNotificationCenter`'s store,
// the 9 signal adapters (`NotificationSources.swift`), dedup/clear
// semantics, and the bell's badge count are all untouched - only how each
// entry renders inside `rowsStack`. The reference's literal "numbered
// sequence" framing (steps 1-4 of one incident) doesn't apply to an
// unordered notification list, so only the *visual pattern* was carried
// over, not the numbering - see `NotificationRowPresentation` for the per-
// source icon/kicker mapping this needed (derived from each source's
// already-stable `id`, not a new field on `AppNotification`). The card
// border/fill mirrors `ToolRowLayout`'s existing `cardStyle` idiom
// (`HelmUIComponents.swift`, `fm/grandline-vault-row-polish`) rather than a
// second card mechanism, and the trailing chip reuses `ToolRowLayout.pill`
// directly - `ToolRowLayout.build`'s own icon-tile/trailing-stack/chevron/
// log assembly doesn't fit this row's shape (no expandable log, no button
// stack, needs a left accent bar `ToolRowLayout` has no concept of), so the
// row itself stays a bespoke view rather than forcing a mismatched fit.

import AppKit

/// The bell icon itself - lives in `TopBarController`, badge count driven by
/// `NotificationCenterController`.
///
/// B2: the button's frame *is* the 34x34 square, the same shape every other
/// icon control on the bar wears, and the badge sits on the glyph's own
/// top-trailing corner inside it - see the file header for why that corner
/// works where the tile's own corner did not.
final class NotificationBellButton: NSButton {
    /// The visible, bordered icon square's fixed size - matches
    /// `DaylightBarIconButton.side` exactly.
    static let iconSize: CGFloat = 34
    /// B2: the button *is* the square now. The outboard badge zone this used
    /// to reserve is gone, which is what makes the bell, the theme toggle and
    /// the Recents button one shape rather than three that happen to share a
    /// fill. Kept as its own name because `DaylightBarController` sizes the
    /// bell by it and reads better saying what it means.
    static let controlWidth: CGFloat = iconSize
    /// The badge's diameter. Small enough to sit on the glyph's corner inside
    /// a 34pt tile and still carry a digit at `badgeFontSize`.
    static let badgeSide: CGFloat = 15
    private static let badgeFontSize: CGFloat = 9
    /// The ring that separates the badge from whatever it overlaps, drawn in
    /// the tile's own fill. Without it a red disc on a bell glyph reads as
    /// part of the glyph.
    private static let badgeRingWidth: CGFloat = 1.5
    /// How far the badge is inset from the tile's top/trailing edges. Puts it
    /// on the *symbol's* corner - the 14pt glyph's own bounds - rather than on
    /// the tile's 9pt radius, which is what defeated both previous attempts at
    /// an attached badge (see the file header).
    private static let badgeInset: CGFloat = 3

    private let iconBackground = NSView()
    private let iconImageView = NSImageView()
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        image = nil
        toolTip = "Notifications"
        setAccessibilityLabel("Notifications")
        translatesAutoresizingMaskIntoConstraints = false

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 9
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        // Decorative only - clicks are handled by the button itself, and
        // this view never needs to intercept them ahead of that.
        addSubview(iconBackground)

        iconImageView.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        badgeLabel.font = .monospacedDigitSystemFont(ofSize: Self.badgeFontSize, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = Self.badgeSide / 2
        // Fixed white-on-systemRed, never a theme tint - `IconRailController.
        // attachBadge`'s own convention, kept verbatim: an alert should read
        // the same way regardless of which of the 14 palettes is active, the
        // way macOS never re-tints a Dock badge either.
        badgeContainer.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeContainer.layer?.borderWidth = Self.badgeRingWidth
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.isHidden = true
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconBackground.heightAnchor.constraint(equalToConstant: Self.iconSize),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),

            badgeLabel.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: Self.badgeSide),
            badgeContainer.widthAnchor.constraint(equalToConstant: Self.badgeSide),
            // B2: on the glyph's corner, inside the tile. A fixed square
            // (rather than a width that grows with the label) is what keeps it
            // a *badge* - the count is abbreviated to fit, see `setBadgeCount`.
            badgeContainer.trailingAnchor.constraint(equalTo: iconBackground.trailingAnchor,
                                                     constant: -Self.badgeInset),
            badgeContainer.topAnchor.constraint(equalTo: iconBackground.topAnchor,
                                                constant: Self.badgeInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The visible icon square's frame, in the button's own coordinate space -
    /// used to anchor the popover on the icon itself, not the wider control.
    var visibleIconFrame: NSRect { iconBackground.frame }

    func setBadgeCount(_ count: Int) {
        badgeContainer.isHidden = count <= 0
        if count > 0 {
            // One digit is what fits on a 15pt badge sitting inside a 34pt
            // tile; the exact count is spoken below and listed in full in the
            // panel, so nothing is lost that the captain cannot reach.
            badgeLabel.stringValue = count > 9 ? "9+" : "\(count)"
        }
        // A1: the badge is the app's primary "something needs you" signal, and
        // it used to be sighted-only - the label was set once at construction,
        // so VoiceOver said "Notifications, button" whether nothing or 99+
        // items were waiting. Updated alongside the visible count, the same
        // pattern `MultiHostSendPicker`'s row already uses.
        //
        // The label carries the count too, not just the value: a value alone
        // is easy to miss when a button is reached by tabbing rather than read
        // outright, and this is the one control whose whole point is the count.
        let spoken: String
        switch count {
        case ..<1: spoken = "Notifications, none waiting"
        case 1: spoken = "Notifications, 1 waiting"
        default: spoken = "Notifications, \(count) waiting"
        }
        setAccessibilityLabel(spoken)
        setAccessibilityValue(count)
        // The badge itself is decoration on top of that label - left as its own
        // element it surfaces a stray "5, text" beside the button.
        badgeLabel.setAccessibilityElement(false)
        badgeContainer.setAccessibilityElement(false)
    }

    func applyTheme(ink: NSColor, line: NSColor, surface: NSColor) {
        iconImageView.contentTintColor = ink.withAlphaComponent(DaylightBarIconButton.restingGlyphAlpha)
        iconBackground.layer?.backgroundColor = surface.cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        // The badge's ring is the tile it sits on, so the badge reads as
        // floating above the glyph rather than merged into it. Theme-derived
        // for that reason only - the disc itself stays systemRed on all 14.
        badgeContainer.layer?.borderColor = surface.cgColor
    }

    #if FM_SELFTESTS
    /// B2: the badge's real frame in the button's own coordinates, so a suite
    /// can assert it sits inside the tile rather than beside it.
    var debugBadgeFrame: NSRect { badgeContainer.frame }
    var debugBadgeIsHidden: Bool { badgeContainer.isHidden }
    var debugBadgeText: String { badgeLabel.stringValue }
    var debugIconFrame: NSRect { iconBackground.frame }
    var debugIconFrameRadius: CGFloat { iconBackground.layer?.cornerRadius ?? -1 }
    #endif
}

/// Owns the popover, the bell's live badge count, and the panel content -
/// the topbar's counterpart to `ConsoleComposerController`/
/// `QuotaUsageController`.
final class NotificationCenterController: NSObject {
    let bell = NotificationBellButton()

    /// B5: a borderless `HelmBarPanel` rather than a stock `NSPopover` - see
    /// that type's header. It owns the window chrome, the theme, the lock
    /// registration and dismissal; this controller keeps what it always
    /// had - the bell, its badge count, and the panel content.
    private let panel: HelmBarPanel
    private let content = NotificationPanelViewController()
    private var themeObservation: ThemeObservation?
    private var storeObservation: NotificationCenterObservation?

    override init() {
        panel = HelmBarPanel(content: content)
        super.init()
        bell.target = self
        bell.action = #selector(bellClicked)
        content.onSizeChanged = { [weak self] size in
            self?.panel.setContentSize(size)
        }
        content.onRequestClose = { [weak self] in
            self?.panel.close()
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.content.applyTheme(theme)
        }
        // Fires immediately on registration too, so the bell's badge is
        // correct before the captain ever opens the panel - every source's
        // own initial check (fired on launch/page-visit/poll) lands here
        // the same way.
        storeObservation = GrandLineNotificationCenter.shared.observe { [weak self] in
            guard let self else { return }
            self.bell.setBadgeCount(GrandLineNotificationCenter.shared.badgeCount)
            if self.panel.isShown { self.content.reload() }
        }
    }

    @objc private func bellClicked() {
        if panel.isShown {
            panel.close()
        } else {
            content.reload()
            panel.show(under: bell)
        }
    }

    #if FM_SELFTESTS
    /// The panel content itself, so a suite can drive the real header action
    /// and the real rows without having to put a real window on screen.
    var debugPanelController: NSViewController { content }
    var debugPanel: HelmBarPanel { panel }
    #endif
}

/// The panel content: a header ("Notifications" + "Mark all read"), one row
/// per entry, and an empty state when there is nothing to show.
final class NotificationPanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    // Widened from the original flat-list width (320) to give the card
    // treatment (left accent bar + icon badge + trailing chip) room to
    // breathe without feeling cramped - still a modest popover width, not a
    // dramatic widening. Daylight §6.12 puts it at 360, one more step for the
    // same reason.
    static let width: CGFloat = 360

    /// Daylight §6.12's exact header copy. "Notifications" named the
    /// mechanism; this names what is in the list, which is the only reason a
    /// captain opens it - and it matches the store's own contract, where an
    /// `.actionNeeded` entry clears itself the moment its condition resolves.
    private let titleLabel = NSTextField(labelWithString: "Waiting for you")
    /// §6.12's "ghost 'Mark all read'" - the app's own `.quiet` button, which
    /// is what "ghost" resolves to under Daylight (§6.6) and what keeps this
    /// control on the shared button recipe in the other twelve palettes too.
    /// The label-in-a-`HoverHighlightView` this replaced predates
    /// `HelmButton`'s existence.
    private let markAllReadButton = HelmButton(title: "Mark all read", variant: .quiet, size: .small)
    /// GL-16: the click recognizer used to sit on the label itself, which
    /// VoiceOver reads as static text with no way to activate it. A
    /// clear-coloured `HoverHighlightView` wrapper (visually identical - it
    /// paints nothing) carries the recognizer instead, so this reads and
    /// behaves as the button it always was.
    /// Was a bare wrapping `NSTextField` - one of the four §3.2 called out.
    /// This panel is 340pt wide, so `.compact` is the right size; the glyph and
    /// the centred copy now match every other empty list in the app.
    private let emptyState = HelmEmptyState(symbol: "checkmark.circle",
                                            body: "You're all caught up.")
    private let rowsStack = NSStackView()
    private let separator = NSView()

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        root.wantsLayer = true
        view = root

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        markAllReadButton.translatesAutoresizingMaskIntoConstraints = false
        markAllReadButton.target = self
        markAllReadButton.action = #selector(markAllReadClicked)
        markAllReadButton.setContentHuggingPriority(.required, for: .horizontal)
        markAllReadButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [titleLabel, markAllReadButton])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        emptyState.heightAnchor.constraint(equalToConstant: 96).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        // Cards are now separated by visible gaps (each has its own border/
        // fill), not a hairline divider baked into each row - see
        // `HelmAccentRow`.
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerRow, separator, emptyState, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: headerRow)
        stack.setCustomSpacing(10, after: separator)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyState.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            emptyState.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        // The header row sits directly against the top edge; give it its
        // own top inset via the stack's own top anchor plus a fixed spacer -
        // simplest is just an explicit constant on the header's containing
        // insets via the stack's edgeInsets.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        applyTheme(theme)
        reload()
    }

    /// Rebuilds every row from the current store state - always small (see
    /// this file's header), so a full rebuild on every change is simpler
    /// and cheap, matching `BootstrapController`'s own "card, rebuilt in
    /// place" sections rather than an incremental diff.
    func reload() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let entries = GrandLineNotificationCenter.shared.entries
        emptyState.isHidden = !entries.isEmpty
        markAllReadButton.isHidden = !entries.contains { $0.kind == .informational }
        for entry in entries {
            let row = Self.makeRow(for: entry, theme: theme)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onClick = { [weak self] in
                entry.navigate()
                self?.onRequestClose?()
            }
            rowsStack.addArrangedSubview(row)
            // Each card gets its own margin from the panel's edges (unlike
            // the old full-bleed row, whose hover fill ran edge to edge) -
            // an explicit leading/trailing offset from `rowsStack`, not a
            // width-equal-to-stack constraint, is what creates that margin.
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor, constant: -14),
            ])
        }
        applyTheme(theme)
        updateSize()
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    @objc private func markAllReadClicked() {
        GrandLineNotificationCenter.shared.markAllRead()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        // §6.12's header is "13 semibold" - the shared row-title role.
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = ink
        separator.layer?.backgroundColor = line.cgColor
        emptyState.applyTheme(theme)
        for case let row as HelmAccentRow in rowsStack.arrangedSubviews {
            row.applyTheme(theme)
        }
    }

    /// One notification row, built from the app's shared accent row.
    ///
    /// This row *is* `HelmAccentRow`'s source: the component
    /// (`HelmDesignSystem.swift`, audit §6.3 component 2) is the recipe that
    /// used to live here, promoted so Shift's task and follow-up lists, SRE
    /// Lead's findings and Overview's "In flight" rows could stop
    /// re-implementing it. What is left here is the part that is genuinely
    /// about notifications: which glyph and kicker a given source gets
    /// (`NotificationRowPresentation`), and what the chip says.
    ///
    /// `.belowBody` because this panel is narrow (`Self.width`) - too narrow
    /// for a chip beside wrapping body text.
    static func makeRow(for entry: AppNotification, theme: HelmTheme) -> HelmAccentRow {
        let presentation = NotificationRowPresentation(for: entry)
        let row = HelmAccentRow(chipPlacement: .belowBody)
        row.configure(HelmAccentRow.Content(tint: entry.tint,
                                            kicker: presentation.kicker,
                                            title: entry.title,
                                            badgeSymbol: presentation.icon,
                                            chipText: entry.subtext,
                                            titleWraps: true),
                      theme: theme)
        return row
    }
}

/// Per-source icon + kicker label for a notification row - derived from each
/// source's own stable `id` (see `NotificationSources.swift`), not a new
/// field on `AppNotification` (this is a rendering-only pass; the store
/// stays untouched). Falls back to a generic bell/kind-based kicker for any
/// id this mapping doesn't recognize, so a future signal added without a
/// matching case here still renders sensibly rather than crashing or
/// showing nothing.
private struct NotificationRowPresentation {
    let icon: String
    let kicker: String

    init(for entry: AppNotification) {
        switch entry.id {
        case NotificationSources.fleetDecisionsID:
            icon = "person.crop.circle.badge.exclamationmark"
            kicker = "Decision Needed"
        case NotificationSources.prReadyID:
            icon = "checkmark.circle.fill"
            kicker = "PR Ready"
        case NotificationSources.toolUpdatesID:
            icon = "arrow.down.circle.fill"
            kicker = "Update Available"
        case NotificationSources.githubSyncID:
            icon = "arrow.triangle.branch"
            kicker = "Fork Behind"
        case NotificationSources.vaultAttentionID:
            icon = "lock.shield.fill"
            kicker = "Needs Attention"
        case NotificationSources.setupDriftID:
            icon = "wrench.and.screwdriver.fill"
            kicker = "Setup Drifted"
        case NotificationSources.shiftDueID:
            icon = "clock.fill"
            kicker = "Due Or Overdue"
        case NotificationSources.fleetFinishedID:
            icon = "flag.checkered"
            kicker = "Task Finished"
        default:
            if entry.id.hasPrefix("sre-lead.") {
                icon = "bubble.left.fill"
                kicker = "SRE Lead Reply"
            } else if entry.id.hasPrefix("schedule-result.") {
                // F11. One entry per schedule, so this is a prefix match like
                // SRE Lead's per-tab entries rather than a fixed id.
                icon = "calendar.badge.clock"
                kicker = "Scheduled Run"
            } else {
                icon = "bell.fill"
                kicker = entry.kind == .actionNeeded ? "Action Needed" : "Update"
            }
        }
    }
}


