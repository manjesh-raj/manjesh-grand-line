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
// **The row has been rebuilt twice since, and only the current shape is
// described here** - see `docs/history/07-fleet-and-notifications.md` for what
// each pass tried and why it was replaced.
// `fm/grandline-notification-row-redesign` made each row a bordered "claim
// card"; G2 found that cramped in a narrow popover and flattened it to a hue
// dot plus a symbol; `fm/grandline-notification-center-redesign` rebuilt the
// whole panel to a full HTML/CSS/JS reference the captain hand-picked
// (`data/grandline-notification-center-redesign/captain-reference/`). What
// lives in this file now is described on `NotificationPanelViewController`
// itself, including which of the reference's own AppKit suggestions were
// deliberately not taken and why. `NotificationRowPresentation` at the bottom
// still owns the per-source icon mapping, still derived from each source's
// already-stable `id`.

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

    /// G2: "on new-notification arrival, a gentle bell symbol bounce".
    ///
    /// Hand-rolled rather than `NSImageView.addSymbolEffect(.bounce)`: symbol
    /// effects are macOS 14, and this package targets 13 (`Package.swift`).
    /// Two small scale beats on the glyph's own layer is what that effect
    /// does anyway, and it composes with the badge sitting on the same tile.
    ///
    /// Reduce Motion gets nothing at all - not a shorter bounce. A bounce
    /// carries no information the badge does not already carry, so the end
    /// state *is* the whole message.
    func playArrivalBounce() {
        guard !HelmMotion.isReduced else { return }
        iconImageView.wantsLayer = true
        guard let layer = iconImageView.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.18, 0.94, 1.06, 1.0]
        bounce.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bounce.duration = 0.42
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bounce, forKey: "arrival-bounce")
    }

    #if FM_SELFTESTS
    /// Whether the arrival bounce is on the glyph's layer right now.
    var debugIsBouncing: Bool { iconImageView.layer?.animation(forKey: "arrival-bounce") != nil }
    #endif

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
    /// What the badge last showed, so a *rise* can be told from a fall.
    private var lastBadgeCount = 0
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
            let count = GrandLineNotificationCenter.shared.badgeCount
            // G2: bounce on **arrival**, not on every publish. The store
            // re-notifies whenever any signal changes, including a count
            // falling as something resolves - a bell that bounced then would
            // be celebrating a thing going away.
            let arrived = count > self.lastBadgeCount
            self.lastBadgeCount = count
            self.bell.setBadgeCount(count)
            if arrived { self.bell.playArrivalBounce() }
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
    /// The real panel content, typed - so a check can read the grouping it
    /// actually built rather than re-deriving it from the store.
    var debugPanelContent: NotificationPanelViewController { content }
    var debugBell: NotificationBellButton { bell }
    var debugPanel: HelmBarPanel { panel }
    #endif
}

/// The relative timestamp a row shows where the reference shows "3h ago" /
/// "2h ago" / "Today".
///
/// A free function rather than a `DateFormatter`: `RelativeDateTimeFormatter`
/// says "in 0 seconds" for a just-arrived entry and localises into phrasings
/// ("1 hour ago") that do not fit a 40pt column beside a title. Pure and
/// injectable, so the suite asserts the boundaries rather than the wall clock.
enum NotificationTimeText {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return days > 9 ? "9d+" : "\(days)d ago"
    }
}

/// Which half of the two-tier list a row belongs in.
///
/// The store's `AppNotificationKind` already draws this line - an
/// `.actionNeeded` entry only ever clears when its condition resolves, an
/// `.informational` one can be put aside - so the redesign's "Needs action" /
/// "Available" headers are that same contract given a visible name rather than
/// a second, parallel classification the two could drift apart on.
enum NotificationGroup: CaseIterable {
    case needsAction
    case available

    var title: String {
        switch self {
        case .needsAction: return "Needs action"
        case .available: return "Available"
        }
    }

    init(_ kind: AppNotificationKind) {
        self = kind == .actionNeeded ? .needsAction : .available
    }
}

/// The two filter modes behind the segmented control.
enum NotificationFilter: String {
    case all
    case needsAction

    func admits(_ entry: AppNotification) -> Bool {
        self == .all || entry.kind == .actionNeeded
    }
}

/// The panel content, rebuilt to the captain's reference
/// (`data/grandline-notification-center-redesign/captain-reference/`).
///
/// **What changed and what did not.** The chrome is still a `HelmBarPanel` and
/// the list is still an `NSStackView` of rows rebuilt in place - the reference's
/// own AppKit note suggests `NSPopover` + `NSOutlineView`, and this file's
/// header already records why the panel is a `HelmBarPanel` (B5) and why a
/// small list is a stack rather than a table. Replacing either wholesale would
/// have thrown away two working mechanisms to arrive at the same pixels, so
/// what was rebuilt is everything the reference is actually *about*: the
/// information architecture.
///
/// That is, in the reference's own order:
///   - two-tier grouping under "Needs action" / "Available" headers, with an
///     **inset** hairline between rows inside a group that starts at the text
///     column rather than the panel edge (`NotificationRowMetrics.textColumn`);
///   - a per-source colour tile, so the list is scannable by shape and colour
///     before it is read - painted from this app's own `HelmTint` tokens
///     against the live theme, never the reference's literal hexes;
///   - the blue dot demoted to meaning *unread* and nothing else;
///   - a timestamp that swaps for the row's one real action on hover, on
///     keyboard selection, and on the row being selected by a right-click;
///   - rows with sub-items (tools, forks, drifted checks) expanding in place,
///     each child carrying its own action, over a "clears when…" line;
///   - a segmented All / Needs-action filter carrying live counts;
///   - a context menu with snooze, read/unread, copy and mute;
///   - a footer that is a toast slot, an undo, and a "N snoozed" restore.
///
/// **The two the captain struck out are absent by construction, not hidden**:
/// there is no Settings button and no Reset-demo button anywhere in this file,
/// and `NotificationCenterRedesignSelfTest.checkFooterOmitsTheStruckButtons`
/// walks the real footer's view tree to keep it that way.
///
/// Undo follows GL-33 rather than the reference: it is offered for the things
/// that can genuinely be put back (read state, a snooze, a mute) and withheld
/// for the ones that cannot (an update or a sync that has already started).
/// A pretend Undo beside a running `brew upgrade` is worse than none.
final class NotificationPanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    /// The reference's own popover width. One step up from the 360 the flat
    /// list wore, which is what the icon tile plus a real trailing action
    /// button need before the title starts truncating at four words.
    static let width: CGFloat = 384
    /// The list scrolls past this, exactly as the reference's does. A popover
    /// that grows to twenty rows stops being a popover.
    static let maxListHeight: CGFloat = 420

    private let titleLabel = NSTextField(labelWithString: "Waiting for you")
    private let markAllReadButton = HelmButton(title: "Mark all read", variant: .quiet, size: .small)

    /// Rebuilt whenever either count changes, because `HelmSegmentedTabs`
    /// takes its titles at init and the reference carries live counts in them.
    /// Kept across an unchanged reload so the selection thumb still *slides*
    /// on a real selection change rather than being recreated mid-animation.
    private var filterTabs: HelmSegmentedTabs?
    private let filterHost = NSView()
    private var filterTitles: [String] = []
    private var filter: NotificationFilter = .all

    private let scroll = NSScrollView()
    private let listStack = NSStackView()
    private let listDocument = NotificationListDocumentView()
    private var listHeight: NSLayoutConstraint?

    /// Two instances rather than one with a rewritten body: `HelmEmptyState`
    /// takes its copy at init, and "nothing at all" and "nothing that needs
    /// you" are genuinely different sentences - the reference writes both.
    private let emptyStateAll = HelmEmptyState(symbol: "checkmark.circle",
                                               title: "You're all caught up",
                                               body: "Follow-ups, updates, forks and setup drift show up here.")
    private let emptyStateAction = HelmEmptyState(symbol: "checkmark.circle",
                                                  title: "Nothing needs action",
                                                  body: "Everything still waiting is in the Available list.")

    private let footerSeparator = NSView()
    private let footerLabel = NSTextField(labelWithString: "Updated just now")
    private let undoButton = HelmButton(title: "Undo", variant: .quiet, size: .small)
    private let snoozedButton = HelmButton(title: "", variant: .quiet, size: .small)

    private let headerSeparator = NSView()

    /// Theme-following labels with no repaint path of their own.
    private var groupHeaders: [NSTextField] = []
    private var separators: [NSView] = []

    /// Which row is selected - the keyboard's cursor, and what a right-click
    /// moves before it opens a menu (the reference does the same, so the menu
    /// is visibly attached to a row).
    private var selectedID: String?
    /// Which expandable rows are open. Keyed by id and kept across reloads, so
    /// a poll landing while the captain has the tool list open does not fold it.
    private var expandedIDs: Set<String> = []

    private var toastTimer: Timer?
    private var undoAction: (() -> Void)?

    /// Injectable, for the same reason `FocusTimerController.clock` is: a suite
    /// that drives a fabricated "3h ago" must not be reading the wall clock.
    var clock: () -> Date = { Date() }

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 320))
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

        filterHost.translatesAutoresizingMaskIntoConstraints = false

        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // AGENTS.md gotcha (9): a plain `NSView` document view is not flipped,
        // so a list shorter than the viewport would rest against its bottom and
        // leave a gap above the first group header.
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(listStack)
        listDocument.onKey = { [weak self] event in self?.handleListKey(event) ?? false }

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listDocument
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyStateAll.translatesAutoresizingMaskIntoConstraints = false
        emptyStateAction.translatesAutoresizingMaskIntoConstraints = false
        emptyStateAction.isHidden = true

        footerSeparator.wantsLayer = true
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
        undoButton.isHidden = true

        snoozedButton.translatesAutoresizingMaskIntoConstraints = false
        snoozedButton.target = self
        snoozedButton.action = #selector(restoreSnoozedClicked)
        snoozedButton.setContentHuggingPriority(.required, for: .horizontal)
        snoozedButton.isHidden = true

        // The footer is the toast slot and nothing else: no Settings, no Reset.
        // See this type's header.
        let footerRow = NSStackView(views: [footerLabel, undoButton, snoozedButton])
        footerRow.orientation = .horizontal
        footerRow.distribution = .fill
        footerRow.alignment = .centerY
        footerRow.spacing = HelmMetrics.s2
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerRow)
        root.addSubview(filterHost)
        root.addSubview(headerSeparator)
        root.addSubview(scroll)
        root.addSubview(emptyStateAll)
        root.addSubview(emptyStateAction)
        root.addSubview(footerSeparator)
        root.addSubview(footerRow)

        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 120)
        self.listHeight = listHeight

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),

            headerRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            headerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            headerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            filterHost.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),
            filterHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            filterHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            headerSeparator.topAnchor.constraint(equalTo: filterHost.bottomAnchor, constant: 8),
            headerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,

            emptyStateAll.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyStateAll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            emptyStateAll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            emptyStateAll.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            emptyStateAction.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyStateAction.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            emptyStateAction.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            emptyStateAction.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),

            footerSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerRow.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 8),
            footerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footerRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            // AGENTS.md gotcha (4): the document view pins to the **clip**
            // view, not the scroll view - with scrollbars set to Always, a
            // non-overlay scroller narrows the clip view without narrowing
            // `scroll` itself.
            listDocument.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: listDocument.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor),
        ])

        applyTheme(theme)
        reload()
    }

    // MARK: - Building the list

    /// Rebuilds every row from the current store state. Always small by design
    /// (see this file's header), so a full rebuild on every change stays
    /// simpler and cheaper than an incremental diff - what the redesign added
    /// is that selection and expansion survive it, because both live in this
    /// controller rather than in the views being thrown away.
    func reload() {
        guard isViewLoaded else { return }
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        groupHeaders.removeAll()
        separators.removeAll()
        clearsLabels.removeAll()

        let center = GrandLineNotificationCenter.shared
        let all = center.entries
        let visible = all.filter { filter.admits($0) }

        // Prune state that no longer names anything, so a resolved row cannot
        // leave the selection pointing at a gap or an expansion pinned open.
        let liveIDs = Set(all.map(\.id))
        expandedIDs.formIntersection(liveIDs)
        if let selectedID, !visible.contains(where: { $0.id == selectedID }) { self.selectedID = nil }

        markAllReadButton.isEnabled = center.unreadCount > 0
        updateFilterTabs(all: all.count, action: all.filter { $0.kind == .actionNeeded }.count)

        // "Nothing needs action" only when there genuinely is something else
        // still waiting - with an empty store both filters mean the same
        // thing, and the caught-up copy is the truthful one.
        let actionCopy = visible.isEmpty && filter == .needsAction && !all.isEmpty
        emptyStateAll.isHidden = !visible.isEmpty || actionCopy
        emptyStateAction.isHidden = !actionCopy
        scroll.isHidden = visible.isEmpty

        for group in NotificationGroup.allCases {
            let rows = visible.filter { NotificationGroup($0.kind) == group }
            guard !rows.isEmpty else { continue }
            addGroupHeader(group.title)
            for (index, entry) in rows.enumerated() {
                addRow(entry, isRead: center.isRead(entry))
                if expandedIDs.contains(entry.id), !entry.children.isEmpty {
                    addChildren(of: entry)
                }
                // The reference's inset hairline: between rows of one group
                // only, never after the last one and never between groups
                // (the next group's own header is the division there).
                if index < rows.count - 1 { addSeparator() }
            }
        }

        renderFooter()
        applyTheme(theme)
        updateSize()
    }

    private func addGroupHeader(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let rule = NSView()
        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(rule)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            rule.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        groupHeaders.append(label)
        separators.append(rule)
        listStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    private func addSeparator() {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            // The inset: starts at the text column, the way `NSTableView`'s
            // inset style reads. A full-width rule between every row makes a
            // popover read as a form.
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                          constant: NotificationRowMetrics.textColumn),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        separators.append(line)
        listStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    private func addRow(_ entry: AppNotification, isRead: Bool) {
        let row = NotificationRowView(entry: entry,
                                      isRead: isRead,
                                      isExpanded: expandedIDs.contains(entry.id),
                                      isSelected: selectedID == entry.id,
                                      timeText: entry.timeText ?? NotificationTimeText.relative(entry.date, now: clock()),
                                      theme: theme)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.onActivate = { [weak self] in self?.select(entry.id, markingRead: true) }
        row.onToggleExpanded = { [weak self] in self?.toggleExpanded(entry.id) }
        row.onPrimaryAction = { [weak self] in self?.performPrimaryAction(entry) }
        row.onBuildMenu = { [weak self] in self?.contextMenu(for: entry) }
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    private func addChildren(of entry: AppNotification) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, child) in entry.children.enumerated() {
            if index > 0 {
                let rule = NSView()
                rule.wantsLayer = true
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                separators.append(rule)
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let view = NotificationChildRowView(child: child, theme: theme)
            view.onAction = { [weak self] in self?.performChildAction(child, of: entry) }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // The reference's "clears when…" line: the explanation moved out of the
        // row and under the disclosure, which is the whole point of expanding.
        let clears = NSTextField(wrappingLabelWithString: entry.clearCondition)
        clears.translatesAutoresizingMaskIntoConstraints = false
        clears.font = HelmType.captionSmall()
        clears.textColor = HelmTheme.mutedInk(theme)
        clears.isHidden = entry.clearCondition.isEmpty
        stack.addArrangedSubview(clears)
        clears.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        clearsLabels.append(clears)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: NotificationRowMetrics.textColumn),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        listStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    private var clearsLabels: [NSTextField] = []

    /// Built once and **retitled** on every reload - `HelmSegmentedTabs`
    /// already owns `setTitle(_:forID:)` "for a tab carrying a live count",
    /// which is exactly this. Rebuilding the control instead would throw away
    /// its sliding selection thumb every time a count moved.
    private func updateFilterTabs(all: Int, action: Int) {
        let titles = ["All  \(all)", "Needs action  \(action)"]
        if filterTabs == nil {
            let tabs = HelmSegmentedTabs(
                items: [.init(id: NotificationFilter.all.rawValue, title: titles[0]),
                        .init(id: NotificationFilter.needsAction.rawValue, title: titles[1])],
                selected: filter.rawValue,
                size: .compact,
                equalWidths: true)
            tabs.translatesAutoresizingMaskIntoConstraints = false
            tabs.onSelect = { [weak self] id in
                guard let self, let mode = NotificationFilter(rawValue: id), mode != self.filter else { return }
                self.filter = mode
                self.reload()
            }
            filterHost.addSubview(tabs)
            NSLayoutConstraint.activate([
                tabs.leadingAnchor.constraint(equalTo: filterHost.leadingAnchor),
                tabs.trailingAnchor.constraint(equalTo: filterHost.trailingAnchor),
                tabs.topAnchor.constraint(equalTo: filterHost.topAnchor),
                tabs.bottomAnchor.constraint(equalTo: filterHost.bottomAnchor),
            ])
            tabs.applyTheme(theme)
            filterTabs = tabs
        }
        guard titles != filterTitles else { return }
        filterTitles = titles
        filterTabs?.setTitle(titles[0], forID: NotificationFilter.all.rawValue)
        filterTabs?.setTitle(titles[1], forID: NotificationFilter.needsAction.rawValue)
    }

    // MARK: - Actions

    private func select(_ id: String, markingRead: Bool) {
        selectedID = id
        if markingRead { GrandLineNotificationCenter.shared.setRead(true, id: id) }
        reload()
        listDocument.window?.makeFirstResponder(listDocument)
    }

    private func toggleExpanded(_ id: String) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        selectedID = id
        reload()
    }

    private func performPrimaryAction(_ entry: AppNotification) {
        GrandLineNotificationCenter.shared.setRead(true, id: entry.id)
        guard let action = entry.primaryAction else {
            entry.navigate()
            onRequestClose?()
            return
        }
        action.perform()
        // GL-33: no Undo here. Whatever this started - a navigation, an
        // update, a sync - is not something this panel can take back, and an
        // Undo that only *looks* like it could is worse than none.
        showToast(action.doneMessage, undo: nil)
        reload()
    }

    private func performChildAction(_ child: AppNotificationChild, of entry: AppNotification) {
        guard let perform = child.perform else { return }
        perform()
        showToast("\(child.actionLabel ?? "Started"): \(child.name)", undo: nil)
    }

    /// The reference's own menu, item for item, minus nothing.
    private func contextMenu(for entry: AppNotification) -> NSMenu {
        selectedID = entry.id
        reload()
        let center = GrandLineNotificationCenter.shared
        let menu = NSMenu()
        menu.addItem(menuItem("Snooze for 1 hour") { [weak self] in
            self?.snooze(entry, by: 60 * 60, message: "Snoozed for 1 hour")
        })
        menu.addItem(menuItem("Snooze until tomorrow") { [weak self] in
            guard let self else { return }
            let tomorrow = Calendar.current.startOfDay(for: self.clock().addingTimeInterval(24 * 60 * 60))
            self.snooze(entry, until: tomorrow, message: "Snoozed until tomorrow")
        })
        menu.addItem(.separator())
        let isRead = center.isRead(entry)
        menu.addItem(menuItem(isRead ? "Mark as unread" : "Mark as read") { [weak self] in
            center.setRead(!isRead, id: entry.id)
            self?.showToast(isRead ? "Marked unread" : "Marked read", undo: {
                center.setRead(isRead, id: entry.id)
            })
            self?.reload()
        })
        menu.addItem(menuItem("Copy details") { [weak self] in
            let text = entry.subtext.isEmpty ? entry.title : "\(entry.title) \u{2014} \(entry.subtext)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.showToast("Copied details", undo: nil)
        })
        if !entry.source.isEmpty {
            menu.addItem(.separator())
            menu.addItem(menuItem("Mute \(entry.source)") { [weak self] in
                center.mute(source: entry.source)
                self?.showToast("Muted \(entry.source)", undo: nil)
                self?.reload()
            })
        }
        return menu
    }

    private func snooze(_ entry: AppNotification, by seconds: TimeInterval, message: String) {
        snooze(entry, until: clock().addingTimeInterval(seconds), message: message)
    }

    private func snooze(_ entry: AppNotification, until date: Date, message: String) {
        GrandLineNotificationCenter.shared.snooze(id: entry.id, until: date)
        // No Undo: the footer's own "N snoozed" is the restore, and it is a
        // standing control rather than one that fades in four seconds.
        showToast(message, undo: nil)
        reload()
    }

    private func menuItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NotificationMenuAction.fire(_:)), keyEquivalent: "")
        let box = NotificationMenuAction(run)
        item.target = box
        item.representedObject = box
        return item
    }

    @objc private func markAllReadClicked() {
        let center = GrandLineNotificationCenter.shared
        let wasUnread = center.entries.filter { !center.isRead($0) }.map(\.id)
        guard !wasUnread.isEmpty else { return }
        center.markAllRead()
        showToast(wasUnread.count == 1 ? "Marked 1 as read" : "Marked \(wasUnread.count) as read", undo: {
            for id in wasUnread { center.setRead(false, id: id) }
        })
        reload()
    }

    @objc private func undoClicked() {
        guard let undoAction else { return }
        self.undoAction = nil
        toastTimer?.invalidate()
        undoAction()
        showToast(nil, undo: nil)
        reload()
    }

    @objc private func restoreSnoozedClicked() {
        GrandLineNotificationCenter.shared.restoreHidden()
        showToast("Restored", undo: nil)
        reload()
    }

    // MARK: - Footer

    private var toastMessage: String?

    private func showToast(_ message: String?, undo: (() -> Void)?) {
        toastTimer?.invalidate()
        toastMessage = message
        undoAction = undo
        renderFooter()
        guard message != nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.toastMessage = nil
            self?.undoAction = nil
            self?.renderFooter()
        }
        // Audit 3.4: a toast that fades at 4.0s and one that fades at 4.4s are
        // the same toast, and the slack lets the OS coalesce this wake with
        // whatever else it was going to do.
        timer.tolerance = 0.5
        toastTimer = timer
    }

    private func renderFooter() {
        let snoozed = GrandLineNotificationCenter.shared.snoozedCount
        if let toastMessage {
            footerLabel.stringValue = toastMessage
            undoButton.isHidden = undoAction == nil
            snoozedButton.isHidden = true
        } else if snoozed > 0 {
            footerLabel.stringValue = ""
            undoButton.isHidden = true
            snoozedButton.title = snoozed == 1 ? "1 snoozed" : "\(snoozed) snoozed"
            snoozedButton.isHidden = false
        } else {
            footerLabel.stringValue = "Updated just now"
            undoButton.isHidden = true
            snoozedButton.isHidden = true
        }
    }

    // MARK: - Keyboard

    /// ↑ ↓ select, → ← expand and collapse, Return acts. The reference's own
    /// four bindings; Escape is `HelmBarPanel`'s already.
    private func handleListKey(_ event: NSEvent) -> Bool {
        let order = orderedVisibleEntries()
        guard !order.isEmpty else { return false }
        let index = order.firstIndex { $0.id == selectedID }
        switch event.keyCode {
        case 125: // down
            let next = index.map { min($0 + 1, order.count - 1) } ?? 0
            select(order[next].id, markingRead: false)
        case 126: // up
            let next = index.map { max($0 - 1, 0) } ?? 0
            select(order[next].id, markingRead: false)
        case 124: // right
            guard let index, !order[index].children.isEmpty else { return false }
            expandedIDs.insert(order[index].id)
            reload()
        case 123: // left
            guard let index else { return false }
            expandedIDs.remove(order[index].id)
            reload()
        case 36, 76: // return, enter
            guard let index else { return false }
            performPrimaryAction(order[index])
        default:
            return false
        }
        return true
    }

    /// The list in the order it is drawn - "Needs action" first, then
    /// "Available" - so the arrow keys walk what the captain sees rather than
    /// the store's own insertion order.
    private func orderedVisibleEntries() -> [AppNotification] {
        let visible = GrandLineNotificationCenter.shared.entries.filter { filter.admits($0) }
        return NotificationGroup.allCases.flatMap { group in
            visible.filter { NotificationGroup($0.kind) == group }
        }
    }

    // MARK: - Size and theme

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        let content = listStack.fittingSize.height
        let floor = emptyStateAll.isHidden && emptyStateAction.isHidden
            ? 0
            : max(emptyStateAll.fittingSize.height, emptyStateAction.fittingSize.height)
        listHeight?.constant = min(max(content, floor), Self.maxListHeight)
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = ink
        headerSeparator.layer?.backgroundColor = line.cgColor
        footerSeparator.layer?.backgroundColor = line.cgColor
        footerLabel.font = HelmType.caption()
        footerLabel.textColor = muted
        emptyStateAll.applyTheme(theme)
        emptyStateAction.applyTheme(theme)
        filterTabs?.applyTheme(theme)

        for header in groupHeaders {
            header.font = HelmType.kicker()
            header.textColor = muted
        }
        for separator in separators {
            separator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        }
        for label in clearsLabels {
            label.font = HelmType.captionSmall()
            label.textColor = muted
        }
        for case let row as NotificationRowView in listStack.arrangedSubviews {
            row.applyTheme(theme)
        }
        for container in listStack.arrangedSubviews {
            for case let child as NotificationChildRowView in allSubviews(of: container) {
                child.applyTheme(theme)
            }
        }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    #if FM_SELFTESTS
    var debugRowTitles: [String] { debugRows.map(\.debugTitle) }
    var debugGroupHeaders: [String] { groupHeaders.map(\.stringValue) }
    var debugRows: [NotificationRowView] { listStack.arrangedSubviews.compactMap { $0 as? NotificationRowView } }
    var debugChildRows: [NotificationChildRowView] {
        listStack.arrangedSubviews.flatMap { allSubviews(of: $0) }.compactMap { $0 as? NotificationChildRowView }
    }
    var debugFooterText: String { footerLabel.stringValue }
    var debugFooterButtonTitles: [String] {
        guard let footerRow = footerSeparator.superview?.subviews
            .compactMap({ $0 as? NSStackView })
            .first(where: { $0.arrangedSubviews.contains(footerLabel) }) else { return [] }
        return footerRow.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .filter { !$0.isHidden }
            .map { $0.title }
    }
    /// Every button title anywhere in the panel's real view tree - what the
    /// "Settings…"/"Reset demo" absence check reads, so it cannot be satisfied
    /// by a footer that simply moved them elsewhere.
    var debugAllButtonTitles: [String] {
        allSubviews(of: view).compactMap { ($0 as? NSButton)?.title }
    }
    var debugFilterTitles: [String] { filterTitles }
    var debugSelectedID: String? { selectedID }
    var debugExpandedIDs: Set<String> { expandedIDs }
    var debugMarkAllReadEnabled: Bool { markAllReadButton.isEnabled }
    var debugEmptyStateShowing: Bool { !emptyStateAll.isHidden || !emptyStateAction.isHidden }
    func debugSetFilter(_ mode: NotificationFilter) { filter = mode; reload() }
    func debugContextMenu(for entry: AppNotification) -> NSMenu { contextMenu(for: entry) }
    func debugSendKey(_ keyCode: UInt16) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: keyCode) else { return false }
        return handleListKey(event)
    }
    #endif
}

/// Carries a closure into an `NSMenuItem`'s target, which AppKit requires to
/// be an object. One box per item, retained by the item's own
/// `representedObject` - a menu built fresh per right-click has no other owner.
private final class NotificationMenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

/// The scrolling list's document view: flipped (gotcha (9)) and the first
/// responder that turns the reference's four key bindings into selection.
final class NotificationListDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// The geometry the reference's row grid describes - `8px 28px 1fr auto 16px`
/// with a 10pt gutter - named once because the inset separator and the child
/// block both have to start exactly where the text column starts.
enum NotificationRowMetrics {
    static let leadingInset: CGFloat = 10
    static let dotColumn: CGFloat = 8
    static let tileSide: CGFloat = 28
    static let gutter: CGFloat = 10
    /// Where the title starts, measured from the panel's leading edge. The
    /// inset hairline and the expanded child block both align to it.
    static let textColumn: CGFloat = leadingInset + dotColumn + gutter + tileSide + gutter
}

/// One notification row, rebuilt to the reference.
///
/// A `HoverHighlightView`, which is what supplies the hover fill, the `.button`
/// accessibility role, the focus ring and the keyboard press (GL-16) - and
/// `onHoverChange`, which is what swaps the timestamp for the action button
/// without a second tracking area of its own.
final class NotificationRowView: HoverHighlightView {
    private static let dotSide: CGFloat = 7

    private let dot = NSView()
    private let tile = IconTileView(size: NotificationRowMetrics.tileSide, cornerRadius: 7)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let actionButton = HelmButton(title: "", variant: .primary, size: .small)
    private let disclosure = NSButton()

    private let tint: HelmTint
    private let isWarning: Bool
    private let isRead: Bool
    private var isSelected: Bool
    private let hasChildren: Bool

    var onActivate: (() -> Void)?
    var onToggleExpanded: (() -> Void)?
    var onPrimaryAction: (() -> Void)?
    /// Built on demand so the menu reflects the row's state at right-click
    /// time - "Mark as read" and "Mark as unread" are the same item.
    var onBuildMenu: (() -> NSMenu?)?

    init(entry: AppNotification, isRead: Bool, isExpanded: Bool, isSelected: Bool,
         timeText: String, theme: HelmTheme) {
        self.tint = entry.tint
        self.isWarning = entry.isWarning
        self.isRead = isRead
        self.isSelected = isSelected
        self.hasChildren = !entry.children.isEmpty
        super.init(frame: .zero)
        let presentation = NotificationRowPresentation(for: entry)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        // The dot means unread and nothing else now - the reference's own
        // demotion. The source's hue moved to the tile beside it, where a
        // colour can carry a shape as well.
        dot.isHidden = isRead

        tile.configure(symbol: presentation.icon, tint: entry.tint, pointSize: 14)

        titleLabel.stringValue = entry.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The reference's "Source: detail" - the page's name in front of the
        // line, which is what lets four rows from four pages read as four
        // different things at a glance.
        let detail = entry.source.isEmpty
            ? entry.subtext
            : (entry.subtext.isEmpty ? entry.source : "\(entry.source): \(entry.subtext)")
        detailLabel.stringValue = detail
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.isHidden = detail.isEmpty
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level priority is the one that
        // decides anything for a view with no intrinsic content size.
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.stringValue = timeText
        timeLabel.font = HelmType.captionSmall()
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        actionButton.title = entry.primaryAction?.label ?? "Open"
        actionButton.target = self
        actionButton.action = #selector(primaryActionClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        disclosure.isBordered = false
        disclosure.title = ""
        disclosure.imagePosition = .imageOnly
        disclosure.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: isExpanded ? "Hide details" : "Show details")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.isHidden = !hasChildren
        disclosure.setAccessibilityLabel(isExpanded ? "Hide details" : "Show details")

        cornerRadius = HelmMetrics.rRow
        addSubview(dot)
        addSubview(tile)
        addSubview(text)
        // The timestamp and the action occupy the same place and are never
        // both visible - but they are two siblings of the row rather than two
        // children of a wrapper view. A wrapper here was a real bug: a plain
        // `NSView` has no intrinsic size, so neither a content- nor a
        // stack-priority API decides its width (AGENTS.md gotcha (12)), and
        // nothing tied its leading edge - so it absorbed the row's slack and
        // squeezed the title down to "Renew staging wild…" with 100pt of empty
        // space beside it. Caught in a real off-screen render, not by reading
        // the constraints.
        addSubview(timeLabel)
        addSubview(actionButton)
        addSubview(disclosure)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            dot.centerXAnchor.constraint(equalTo: leadingAnchor,
                                         constant: NotificationRowMetrics.leadingInset
                                             + NotificationRowMetrics.dotColumn / 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            tile.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: NotificationRowMetrics.leadingInset
                                              + NotificationRowMetrics.dotColumn
                                              + NotificationRowMetrics.gutter),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: NotificationRowMetrics.textColumn),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            // Bounded by **both**, so the text column is the same width
            // whether the row is showing its timestamp or its action. Bounding
            // it by only the visible one would reflow the title on every hover,
            // which is a worse defect than a title that truncates one word
            // earlier - and the reference's own screenshot truncates here too.
            text.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor,
                                           constant: -NotificationRowMetrics.gutter),
            text.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor,
                                           constant: -NotificationRowMetrics.gutter),

            timeLabel.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -6),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -6),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 16),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])

        // The reference's hover-reveal, both directions. `onHoverChange` rather
        // than a colour-derived hook: this row's own fill is a hover
        // highlight, so a colour hook would fire for the wrong reason.
        onHoverChange = { [weak self] hovering in self?.setActionVisible(hovering) }
        // The initial state goes through the same one function rather than
        // being set by hand beside it: a selected row has to open already
        // showing its action *and* already hiding its timestamp, and two
        // places setting the same pair is how those two halves drift apart.
        setActionVisible(false)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activate)))
        accessibilityLabelOverride = [entry.title, detail, isRead ? "" : "unread"]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The one swap the reference is built around: the row shows when it
    /// arrived until you can act on it, and then it shows the action.
    private func setActionVisible(_ visible: Bool) {
        let showAction = visible || isSelected
        actionButton.isHidden = !showAction
        timeLabel.isHidden = showAction
    }

    /// Right-click. `menu(for:)` rather than a stored `menu`, so the items are
    /// built against the row's state at the moment of the click.
    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildMenu?() ?? super.menu(for: event)
    }

    @objc private func activate() { onActivate?() }
    @objc private func disclosureClicked() { onToggleExpanded?() }
    @objc private func primaryActionClicked() { onPrimaryAction?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        HelmMotion.withoutImplicitAnimation {
            dot.layer?.backgroundColor = accent.cgColor
        }
        tile.applyTheme(theme)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: isRead ? .medium : .semibold)
        titleLabel.textColor = ink
        detailLabel.font = HelmType.caption()
        // A tint is safe as a fill and is not automatically safe as text
        // (`HelmContrast`'s own rule), so an overdue line goes through the
        // legibility helper rather than straight to the critical hue.
        detailLabel.textColor = isWarning
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: surface, theme: theme)
            : HelmTheme.mutedInk(theme)
        timeLabel.textColor = isWarning
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: surface, theme: theme)
            : HelmTheme.mutedInk(theme)
        disclosure.contentTintColor = HelmTheme.mutedInk(theme)
        normalColor = isSelected
            ? accent.withAlphaComponent(0.14)
            : .clear
        hoverColor = isSelected
            ? accent.withAlphaComponent(0.18)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugTimeText: String { timeLabel.stringValue }
    var debugActionTitle: String { actionButton.title }
    var debugActionVisible: Bool { !actionButton.isHidden }
    var debugTimeVisible: Bool { !timeLabel.isHidden }
    var debugUnreadDotVisible: Bool { !dot.isHidden }
    var debugHasDisclosure: Bool { !disclosure.isHidden }
    var debugTileImage: NSImage? { tile.debugRenderedImage }
    /// Drives the real hover path the tracking area would, so a headless suite
    /// can assert the swap without a mouse.
    ///
    /// Goes through `HoverHighlightView.mouseEntered`/`mouseExited` - the
    /// actual AppKit entry points - rather than calling `setActionVisible`
    /// directly. Calling the private helper made the check **unable to fail**:
    /// deleting the `onHoverChange` wiring entirely left it green, because it
    /// was asserting the helper rather than the hook that reaches it.
    func debugSetHovering(_ hovering: Bool) {
        guard let event = NSEvent.enterExitEvent(
            with: hovering ? .mouseEntered : .mouseExited,
            location: NSPoint(x: bounds.midX, y: bounds.midY),
            modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        if hovering { mouseEntered(with: event) } else { mouseExited(with: event) }
    }
    func debugClickDisclosure() { disclosureClicked() }
    func debugClickAction() { primaryActionClicked() }
    func debugActivate() { activate() }
    func debugBuildMenu() -> NSMenu? { onBuildMenu?() }
    #endif
}

/// One sub-item under an expanded row - the reference's `.kid`: a name, a meta
/// line under it, and its own small action on the right.
final class NotificationChildRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let actionButton = HelmButton(title: "", variant: .quiet, size: .small)
    private let isMonospaced: Bool

    var onAction: (() -> Void)?

    init(child: AppNotificationChild, theme: HelmTheme) {
        self.isMonospaced = child.isMonospaced
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = child.name
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.stringValue = child.meta
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.isHidden = child.meta.isEmpty
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [nameLabel, metaLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        actionButton.title = child.actionLabel ?? ""
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isHidden = child.actionLabel == nil || child.perform == nil
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(text)
        addSubview(actionButton)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            // An **equality**, not a cap. With a cap the stack's width came
            // from whichever of its two labels Auto Layout happened to settle
            // on, and a short name over a long meta line rendered "helm" over
            // "3.1…" while "kubectl" over its full version pair fitted in the
            // same row - measured in a real off-screen render. A definite
            // column truncates the same way for every child.
            text.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func actionClicked() { onAction?() }

    func applyTheme(_ theme: HelmTheme) {
        // A version pair reads as a version pair in a monospaced face and as
        // prose in anything else, which is why the source states it rather
        // than this view guessing from the string.
        let size = HelmType.scaled(12)
        nameLabel.font = isMonospaced
            ? .monospacedSystemFont(ofSize: size, weight: .medium)
            : .systemFont(ofSize: size, weight: .medium)
        nameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        let metaSize = HelmType.scaled(11)
        metaLabel.font = isMonospaced
            ? .monospacedSystemFont(ofSize: metaSize, weight: .regular)
            : .systemFont(ofSize: metaSize, weight: .regular)
        metaLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugName: String { nameLabel.stringValue }
    var debugMeta: String { metaLabel.stringValue }
    var debugActionTitle: String? { actionButton.isHidden ? nil : actionButton.title }
    func debugClickAction() { actionClicked() }
    #endif
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


