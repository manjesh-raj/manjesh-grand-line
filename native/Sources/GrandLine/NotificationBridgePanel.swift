// Grand Line - native macOS app.
//
// The sidebar layout's notification panel - what its bell opens. The floating
// bar is frozen (R2-ARCH-01), so it keeps `NotificationPanelViewController`
// exactly as it was, and the two panels read the one store.
//
// **The shape: triage cards** (`fm/grandline-notification-ui-designs-scout-
// 1793150000`, option D on the captain's redesign board). It replaced the
// Bridge layout (a hero "Now" card and flat rows), whose buttons crowded one
// line under each row: the snooze was a bare moon glyph after the pill and
// the "Show N" link, and a long primary label pushed it out of the row
// altogether. Now every item is its own small card on a tinted ground:
//
// - a top line with the source's tile, the source as a kicker, the unread
//   dot, the age, and - for an informational item - a Hide control;
// - the title, which wraps, and the detail, clamped to two lines with the
//   whole text in the tooltip and the VoiceOver label;
// - a footer bar: the item's own action first, "Show N" beside it, and a
//   labelled Snooze at the right that opens a native menu of the presets
//   with the time each one resolves to.
//
// The card boundary is what tells the captain which item a button belongs
// to, which the flat list never quite did. Action-needed items come first
// with an accent edge (`NotificationBridgeSections` is still the whole
// ordering rule); a segment at the top switches between the inbox and a
// Snoozed list, which is the first place a snooze can be seen or undone one
// item at a time.
//
// **Nothing can be pushed off a card's footer bar** (F6). The bar is pinned to
// the card's width, the snooze collapses to its glyph when its label would
// not fit, and the primary is the one control allowed to give up width.
//
// **Keyboard.** The list's document view is the first responder: ↑ ↓ select a
// card, → ← expand and collapse, Return runs the selected card's action, S
// opens its snooze menu, Delete hides an informational card, and ⌘[ ⌘]
// switch the segment. Escape is `HelmBarPanel`'s. Every button is a real key
// view, so Tab reaches each card's buttons and then the footer.
//
// **VoiceOver.** A card is a group whose label reads the whole item and whose
// buttons stay reachable inside it, and it carries custom actions (the
// primary, Snooze, Mark as read, Hide, Mute) so the rotor reaches every action
// without tabbing through the card (F8). Every button names its subject.

import AppKit

/// Which of the two panels a `NotificationCenterController` shows.
enum NotificationPanelStyle {
    /// The floating bar's panel, frozen with the floating bar (R2-ARCH-01).
    case classic
    /// The sidebar layout's triage-card panel. The case keeps the name the
    /// shell and the suites already use for it.
    case bridge
}

/// The three sections, from the store's own kinds. Pure, so the ordering rule
/// is asserted in CI's blocking lane rather than only through a window.
struct NotificationBridgeSections {
    /// The one item that needs the captain most.
    let now: AppNotification?
    /// The other action-needed items, most urgent first.
    let upNext: [AppNotification]
    /// The informational items, newest first.
    let later: [AppNotification]

    init(_ entries: [AppNotification]) {
        // Overdue (a warning) first, then the oldest: what has waited longest
        // is what the captain most needs to see, and a fresh arrival does not
        // push an overdue task off the top.
        let action = entries.filter { $0.kind == .actionNeeded }.sorted { a, b in
            if a.isWarning != b.isWarning { return a.isWarning }
            return a.date < b.date
        }
        now = action.first
        upNext = Array(action.dropFirst())
        later = entries.filter { $0.kind == .informational }.sorted { $0.date > $1.date }
    }

    /// The order the panel draws, which is the order the arrow keys walk.
    var ordered: [AppNotification] { (now.map { [$0] } ?? []) + upNext + later }

    var isEmpty: Bool { now == nil && later.isEmpty }
}

/// The panel's time strings, pure and injectable like `NotificationTimeText`.
enum NotificationBridgeTimeText {
    /// "Mon 26 Oct" under the panel title, in the captain's own locale.
    static func headerDate(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date)
    }

    /// A card's age: what the source states ("overdue"), else how long ago
    /// it arrived.
    static func age(for entry: AppNotification, now: Date) -> String {
        entry.timeText ?? NotificationTimeText.relative(entry.date, now: now)
    }

    /// When a snooze ends, as short as it can be said: the time alone for
    /// today ("6:00 PM"), the weekday within a week ("Thu 9:00 AM"), and the
    /// date beyond that ("Mon 2 Nov, 9:00 AM"), in the locale's own clock.
    static func snoozeTime(_ date: Date, now: Date, calendar: Calendar = .current,
                           locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: formatter.setLocalizedDateFormatFromTemplate("jmm")
        case 1...6: formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        default: formatter.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        }
        return formatter.string(from: date)
    }

    /// A Snoozed row's line: "Back at 6:00 PM", "Back tomorrow, 9:00 AM",
    /// "Back Mon 2 Nov, 9:00 AM".
    static func returns(_ date: Date, now: Date, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let time = snoozeTime(date, now: now, calendar: calendar, locale: locale)
        switch days {
        case ...0: return "Back at \(time)"
        case 1:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return "Back tomorrow, \(formatter.string(from: date))"
        default: return "Back \(time)"
        }
    }
}

/// The snooze presets. Every card's Snooze opens these as a menu, each with
/// the time it resolves to. Pure, so the dates are asserted against a fixed
/// instant rather than the wall clock.
enum NotificationSnoozePreset: CaseIterable {
    case oneHour
    case tonight
    case tomorrow
    case nextWeek

    var title: String {
        switch self {
        case .oneHour: return "1 hour"
        case .tonight: return "Tonight"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    /// What the footer says afterwards, and the tail of the menu item's
    /// plain title (which is what VoiceOver reads).
    var phrase: String {
        switch self {
        case .oneHour: return "for 1 hour"
        case .tonight: return "until tonight"
        case .tomorrow: return "until tomorrow"
        case .nextWeek: return "until next week"
        }
    }

    /// When the entry comes back. Tonight is 18:00 today, tomorrow is 09:00
    /// tomorrow, and next week is 09:00 on the next Monday that is at least a
    /// day away - so "next week" on a Monday morning never means an hour.
    func date(from now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        switch self {
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .tonight:
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(60 * 60)
        case .tomorrow:
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: startOfTomorrow) ?? startOfTomorrow
        case .nextWeek:
            return calendar.nextDate(after: startOfTomorrow,
                                     matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                     matchingPolicy: .nextTime) ?? startOfTomorrow.addingTimeInterval(7 * 86_400)
        }
    }

    /// The presets worth offering now. "Tonight" goes once it is within an
    /// hour of 18:00, where it would mean less than "1 hour" does.
    static func offered(at now: Date, calendar: Calendar = .current) -> [NotificationSnoozePreset] {
        allCases.filter { preset in
            preset != .tonight || preset.date(from: now, calendar: calendar).timeIntervalSince(now) > 60 * 60
        }
    }
}

/// The panel's two lists.
enum NotificationBridgeSegment: String {
    case inbox
    case snoozed
}

/// The geometry, named once because the wrapping labels' widths are computed
/// from it rather than read back from their own frames (gotcha (22)).
enum NotificationBridgeMetrics {
    static let sideInset: CGFloat = 16
    /// Between the panel's edge and a card.
    static let listInset: CGFloat = 10
    static let cardSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 12
    /// `HelmMetrics.dTileLarge` - one step tighter than a page card, because
    /// these sit inside a 16pt-radius panel.
    static let cardRadius: CGFloat = HelmMetrics.dTileLarge
    static let tileSide: CGFloat = 22
    static let dotSide: CGFloat = 7
    /// The accent edge on an action-needed card.
    static let edgeWidth: CGFloat = 3
    /// Past this many inbox cards, informational cards drop their detail line
    /// so the list stays scannable rather than becoming a column of cards
    /// three to a screen.
    static let compactThreshold = 6
}

// MARK: - The panel

final class NotificationBridgePanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    static let width: CGFloat = 384
    /// The list scrolls past this. Sized so the four cards of an ordinary day
    /// fit without scrolling - the captain's own screenshot measured 584pt as
    /// cards - and scaled, because at the Larger text size the same cards are
    /// 30% taller and a fixed cap would scroll sooner for exactly the captain
    /// who asked for bigger text.
    static var maxListHeight: CGFloat { HelmType.scaled(600) }
    /// What the list leaves of the screen's visible height: the bar above the
    /// panel, the panel's own header and footer, and a margin. A panel taller
    /// than the room below its bell would flip above it (`HelmBarPanel`), so
    /// the cap gives way to the screen rather than the other way round.
    static let screenReserve: CGFloat = 260

    /// `maxListHeight`, or less on a screen too short for it.
    private var listHeightLimit: CGFloat {
        guard let screen = view.window?.screen ?? NSScreen.main else { return Self.maxListHeight }
        return max(HelmType.scaled(240), min(Self.maxListHeight, screen.visibleFrame.height - Self.screenReserve))
    }

    private let titleLabel = NSTextField(labelWithString: "Waiting for you")
    private let dateLabel = NSTextField(labelWithString: "")
    /// Holds the segment, which is rebuilt when a count changes - the
    /// component's titles are fixed at construction.
    private let segmentHost = NSView()
    private var segmentTabs: HelmSegmentedTabs?
    private var segmentTitles: [String] = []
    private let headerSeparator = NSView()

    private let scroll = NSScrollView()
    private let listStack = NSStackView()
    private let listDocument = NotificationListDocumentView()
    private var listHeight: NSLayoutConstraint?
    private var emptyState: NotificationBridgeEmptyView?

    private let footerSeparator = NSView()
    /// Wraps to a second line rather than truncating: at the Larger text size
    /// a toast plus Undo, Mark all read and Open Home do not fit on one.
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let undoButton = HelmButton(title: "Undo", variant: .quiet, size: .small)
    private let markAllReadButton = HelmButton(title: "Mark all read", variant: .quiet, size: .small,
                                               symbol: "checkmark.circle")
    private let openHomeButton = HelmButton(title: "Open Home", variant: .quiet, size: .small,
                                            symbol: "chevron.right")

    private(set) var segment: NotificationBridgeSegment = .inbox
    private var selectedID: String?
    private var expandedIDs: Set<String> = []
    private var toastTimer: Timer?
    private var undoAction: (() -> Void)?
    private var toastMessage: String?
    private var lastRenderSignature: String?

    /// Injectable, as on the classic panel.
    var clock: () -> Date = { Date() }

    /// How a snooze menu is shown: popped up under the button that asked for
    /// it. A suite swaps this to read the menu, because a real pop-up enters
    /// AppKit's modal menu tracking and would never return.
    var presentMenu: (NSMenu, NSView) -> Void = { menu, view in
        let y = view.isFlipped ? view.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?
    /// The footer's way home. Set by the sidebar shell; the button hides when
    /// nothing is wired, rather than offering a button that does nothing.
    var onOpenHome: (() -> Void)? {
        didSet { openHomeButton.isHidden = onOpenHome == nil }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 320))
        root.wantsLayer = true
        view = root

        for label in [titleLabel, dateLabel, footerLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.lineBreakMode = .byTruncatingTail
        dateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleStack = NSStackView(views: [titleLabel, dateLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = HelmMetrics.s0
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        segmentHost.translatesAutoresizingMaskIntoConstraints = false

        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = NotificationBridgeMetrics.cardSpacing
        listStack.edgeInsets = NSEdgeInsets(top: NotificationBridgeMetrics.listInset, left: 0,
                                            bottom: NotificationBridgeMetrics.listInset, right: 0)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(listStack)
        listDocument.onKey = { [weak self] event in self?.handleListKey(event) ?? false }
        listDocument.setAccessibilityElement(true)
        listDocument.setAccessibilityRole(.list)
        listDocument.setAccessibilityLabel("Notifications")

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.documentView = listDocument
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footerSeparator.wantsLayer = true
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        footerLabel.maximumNumberOfLines = 2
        footerLabel.isSelectable = false
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openHomeButton.symbolTrailing = true
        for (button, action) in [(undoButton, #selector(undoClicked)),
                                 (markAllReadButton, #selector(markAllReadClicked)),
                                 (openHomeButton, #selector(openHomeClicked))] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = action
            button.followsTextScale = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        undoButton.isHidden = true
        openHomeButton.isHidden = onOpenHome == nil
        openHomeButton.accessibilityLabelOverride = "Open Home"
        markAllReadButton.accessibilityLabelOverride = "Mark every notification as read"
        let footerRow = NSStackView(views: [markAllReadButton, footerLabel, undoButton, openHomeButton])
        footerRow.orientation = .horizontal
        footerRow.distribution = .fill
        footerRow.alignment = .centerY
        footerRow.spacing = HelmMetrics.s2
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleStack)
        root.addSubview(segmentHost)
        root.addSubview(headerSeparator)
        root.addSubview(scroll)
        root.addSubview(footerSeparator)
        root.addSubview(footerRow)

        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 120)
        self.listHeight = listHeight
        let inset = NotificationBridgeMetrics.sideInset

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),

            titleStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            titleStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),

            segmentHost.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 10),
            segmentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            segmentHost.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),

            headerSeparator.topAnchor.constraint(equalTo: segmentHost.bottomAnchor, constant: 12),
            headerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,

            footerSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerRow.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 10),
            footerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset - 6),
            footerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -(inset - 6)),
            footerRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            // Gotcha (4): the document view pins to the clip view.
            listDocument.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: listDocument.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor),
        ])

        applyTheme(theme)
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Tab walks each card's buttons, then the footer, in drawn order.
        view.window?.autorecalculatesKeyViewLoop = true
        view.window?.makeFirstResponder(listDocument)
    }

    // MARK: Building

    /// The width the list's content is laid out in: the clip view's, once it
    /// has one, which is narrower than the panel when a legacy scroller is
    /// showing. Never read off a label (gotcha (22)).
    private var contentWidth: CGFloat {
        let clip = scroll.contentView.bounds.width
        return clip > 0 ? clip : Self.width
    }

    private var cardWidth: CGFloat { contentWidth - 2 * NotificationBridgeMetrics.listInset }

    private func renderSignature(_ inbox: [AppNotification],
                                 snoozed: [(entry: AppNotification, until: Date)],
                                 center: GrandLineNotificationCenter) -> String {
        let now = clock()
        var parts = [
            "theme:\(theme.id)", "scale:\(ChromeTextScale.shared.scale)",
            "width:\(contentWidth)", "segment:\(segment.rawValue)",
            "unread:\(center.unreadCount)", "held:\(center.heldCount)",
            "muted:\(center.mutedSourceNames)",
            "selected:\(selectedID ?? "-")",
            "day:\(NotificationBridgeTimeText.headerDate(now))",
        ]
        for (index, entry) in inbox.enumerated() {
            let children = entry.children
                .map { "\($0.id)/\($0.name)/\($0.meta)/\($0.actionLabel ?? "-")/\($0.isMonospaced)" }
                .joined(separator: ",")
            parts.append([
                "\(index)", entry.id, entry.title, entry.subtext, entry.source, entry.clearCondition,
                "\(entry.kind)", "\(entry.tint)", NotificationBridgeTimeText.age(for: entry, now: now),
                "\(entry.isWarning)", "\(center.isRead(entry))", "\(expandedIDs.contains(entry.id))",
                entry.primaryAction?.label ?? "-", children,
            ].joined(separator: "\u{1f}"))
        }
        for item in snoozed {
            parts.append("snoozed\u{1f}\(item.entry.id)\u{1f}\(item.entry.title)\u{1f}"
                         + NotificationBridgeTimeText.returns(item.until, now: now))
        }
        return parts.joined(separator: "\u{1e}")
    }

    func reload() {
        guard isViewLoaded else { return }
        let center = GrandLineNotificationCenter.shared
        let inbox = NotificationBridgeSections(center.entries).ordered
        let snoozed = center.snoozedEntries
        let liveIDs = Set(inbox.map(\.id))
        expandedIDs.formIntersection(liveIDs)
        if let selectedID, !liveIDs.contains(selectedID) { self.selectedID = nil }

        let signature = renderSignature(inbox, snoozed: snoozed, center: center)
        if signature == lastRenderSignature { return }
        lastRenderSignature = signature

        let now = clock()
        dateLabel.stringValue = NotificationBridgeTimeText.headerDate(now)
        updateSegment(inbox: inbox.count, snoozed: snoozed.count)
        markAllReadButton.isHidden = segment != .inbox || inbox.isEmpty
        markAllReadButton.isEnabled = center.unreadCount > 0

        // Rebuilt rather than reconciled: the list is a handful of items by
        // design, and the signature above already skips every reload that
        // would draw the same thing - which is all PF3 measured.
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        emptyState = nil
        switch segment {
        case .inbox:
            if inbox.isEmpty {
                addEmptyState(title: "You\u{2019}re all caught up", body: "Nothing needs you right now.",
                              symbol: "checkmark", tint: .good)
            }
            let compact = inbox.count > NotificationBridgeMetrics.compactThreshold
            for entry in inbox { addCard(entry, compact: compact, center: center, now: now) }
        case .snoozed:
            if snoozed.isEmpty {
                addEmptyState(title: "Nothing snoozed",
                              body: "A snoozed notification comes back here on its own.",
                              symbol: "moon.zzz", tint: .info)
            }
            for item in snoozed {
                let row = NotificationSnoozedRow(entry: item.entry, theme: theme, width: cardWidth,
                                                 returnText: NotificationBridgeTimeText.returns(item.until, now: now))
                let id = item.entry.id
                row.onUnsnooze = { [weak self] in self?.unsnooze(id) }
                add(row, inset: NotificationBridgeMetrics.listInset)
            }
            let muted = center.mutedSourceNames
            if !muted.isEmpty {
                let note = NotificationMutedNote(sources: muted, theme: theme,
                                                 width: contentWidth - 2 * NotificationBridgeMetrics.sideInset)
                add(note, inset: NotificationBridgeMetrics.sideInset)
            }
        }

        renderFooter()
        applyTheme(theme)
        updateSize()
    }

    private func updateSegment(inbox: Int, snoozed: Int) {
        let titles = [inbox > 0 ? "Inbox \(inbox)" : "Inbox", snoozed > 0 ? "Snoozed \(snoozed)" : "Snoozed"]
        guard titles != segmentTitles || segmentTabs == nil else {
            segmentTabs?.select(segment.rawValue)
            return
        }
        segmentTitles = titles
        segmentTabs?.removeFromSuperview()
        let tabs = HelmSegmentedTabs(items: [.init(id: NotificationBridgeSegment.inbox.rawValue, title: titles[0]),
                                             .init(id: NotificationBridgeSegment.snoozed.rawValue, title: titles[1])],
                                     selected: segment.rawValue, size: .compact)
        tabs.onSelect = { [weak self] id in
            self?.switchSegment(to: NotificationBridgeSegment(rawValue: id) ?? .inbox)
        }
        segmentHost.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: segmentHost.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: segmentHost.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: segmentHost.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: segmentHost.bottomAnchor),
        ])
        tabs.applyTheme(theme)
        segmentTabs = tabs
    }

    private func addEmptyState(title: String, body: String, symbol: String, tint: HelmTint) {
        let empty = NotificationBridgeEmptyView(title: title, body: body, symbol: symbol, tint: tint)
        empty.applyTheme(theme)
        emptyState = empty
        add(empty, inset: NotificationBridgeMetrics.sideInset)
    }

    private func add(_ view: NSView, inset: CGFloat) {
        listStack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: listStack.leadingAnchor, constant: inset).isActive = true
        view.trailingAnchor.constraint(equalTo: listStack.trailingAnchor, constant: -inset).isActive = true
    }

    private func addCard(_ entry: AppNotification, compact: Bool, center: GrandLineNotificationCenter, now: Date) {
        let card = NotificationTriageCard(entry: entry, theme: theme, width: cardWidth,
                                          isRead: center.isRead(entry),
                                          isSelected: selectedID == entry.id,
                                          isExpanded: expandedIDs.contains(entry.id),
                                          isCompact: compact && entry.kind == .informational,
                                          ageText: NotificationBridgeTimeText.age(for: entry, now: now))
        let id = entry.id
        card.onSelect = { [weak self] in self?.select(id, markingRead: true) }
        card.onBuildMenu = { [weak self] in self?.contextMenu(for: entry) }
        card.onPrimary = { [weak self] in self?.performPrimaryAction(entry) }
        card.onToggleExpanded = { [weak self] in self?.toggleExpanded(id) }
        card.onSnooze = { [weak self, weak card] in
            guard let self, let card else { return }
            self.showSnoozeMenu(for: entry, from: card.snooze)
        }
        card.onHide = { [weak self] in self?.hide(entry) }
        card.onMute = { [weak self] in self?.mute(entry) }
        card.onMarkRead = { [weak self] in self?.toggleRead(entry) }
        card.onChildAction = { [weak self] childID in self?.performChildAction(childID: childID, ofEntryID: id) }
        add(card, inset: NotificationBridgeMetrics.listInset)
    }

    // MARK: Actions

    private func select(_ id: String, markingRead: Bool) {
        selectedID = id
        if markingRead { GrandLineNotificationCenter.shared.setRead(true, id: id) }
        reload()
        listDocument.window?.makeFirstResponder(listDocument)
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        guard let card = card(for: selectedID) else { return }
        card.scrollToVisible(card.bounds)
    }

    private func card(for id: String?) -> NotificationTriageCard? {
        guard let id else { return nil }
        return listStack.arrangedSubviews.lazy.compactMap { $0 as? NotificationTriageCard }.first { $0.entryID == id }
    }

    private func switchSegment(to segment: NotificationBridgeSegment) {
        guard segment != self.segment else { return }
        self.segment = segment
        selectedID = nil
        reload()
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
        // GL-33: no Undo for something this panel cannot take back.
        showToast(action.doneMessage, undo: nil)
        reload()
    }

    private func performChildAction(childID: String, ofEntryID entryID: String) {
        guard let entry = GrandLineNotificationCenter.shared.entries.first(where: { $0.id == entryID }),
              let child = entry.children.first(where: { $0.id == childID }),
              let perform = child.perform else { return }
        perform()
        showToast("\(child.actionLabel ?? "Started"): \(child.name)", undo: nil)
    }

    private func showSnoozeMenu(for entry: AppNotification, from button: NSView) {
        selectedID = entry.id
        presentMenu(snoozeMenu(for: entry), button)
    }

    /// The Snooze button's menu: the presets with the time each resolves to,
    /// then the two ways of putting an item away for longer.
    func snoozeMenu(for entry: AppNotification) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Snooze until", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        addSnoozeItems(for: entry, to: menu)
        addPutAwayItems(for: entry, to: menu)
        return menu
    }

    private func addSnoozeItems(for entry: AppNotification, to menu: NSMenu) {
        let now = clock()
        for preset in NotificationSnoozePreset.offered(at: now) {
            // The attributed title draws the time right-aligned, the way the
            // board showed it. It also replaces the item's plain `title`, so
            // the preset is found by its identifier, never by its text.
            let item = HelmMenuAction.item(preset.title) { [weak self] in
                self?.snooze(entry, preset: preset)
            }
            item.attributedTitle = Self.presetTitle(
                preset.title, time: NotificationBridgeTimeText.snoozeTime(preset.date(from: now), now: now))
            item.identifier = Self.presetIdentifier(preset)
            item.toolTip = "Snooze \(preset.phrase)"
            menu.addItem(item)
        }
    }

    private func addPutAwayItems(for entry: AppNotification, to menu: NSMenu) {
        guard entry.kind == .informational || !entry.source.isEmpty else { return }
        menu.addItem(.separator())
        if entry.kind == .informational {
            menu.addItem(HelmMenuAction.item("Hide until it changes") { [weak self] in self?.hide(entry) })
        }
        if !entry.source.isEmpty {
            menu.addItem(HelmMenuAction.item("Mute \(entry.source)") { [weak self] in self?.mute(entry) })
        }
    }

    /// How a snooze preset's menu item is found, by a suite or anything else.
    static func presetIdentifier(_ preset: NotificationSnoozePreset) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("notification.snooze.\(preset)")
    }

    private static func presetTitle(_ title: String, time: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 210)]
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: "\(title)\t",
                                             attributes: [.font: font, .paragraphStyle: paragraph])
        // No colour of its own: the menu draws in the system's material and
        // appearance, which a theme colour cannot know, and the system's
        // secondary label colour fails the contrast floor (`HelmContrastSelfTest`).
        // The right-aligned tab stop is what sets the time apart.
        text.append(NSAttributedString(string: time, attributes: [.font: font, .paragraphStyle: paragraph]))
        return text
    }

    /// The card's right-click menu: the same presets, then read state and
    /// copy, then Hide and Mute.
    private func contextMenu(for entry: AppNotification) -> NSMenu {
        selectedID = entry.id
        reload()
        let center = GrandLineNotificationCenter.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        addSnoozeItems(for: entry, to: menu)
        menu.addItem(.separator())
        let isRead = center.isRead(entry)
        menu.addItem(HelmMenuAction.item(isRead ? "Mark as unread" : "Mark as read") { [weak self] in
            self?.toggleRead(entry)
        })
        menu.addItem(HelmMenuAction.item("Copy details") { [weak self] in
            let text = entry.subtext.isEmpty ? entry.title : "\(entry.title) - \(entry.subtext)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.showToast("Copied details", undo: nil)
        })
        addPutAwayItems(for: entry, to: menu)
        return menu
    }

    private func toggleRead(_ entry: AppNotification) {
        let center = GrandLineNotificationCenter.shared
        let isRead = center.isRead(entry)
        center.setRead(!isRead, id: entry.id)
        showToast(isRead ? "Marked unread" : "Marked read", undo: { center.setRead(isRead, id: entry.id) })
        reload()
    }

    private func snooze(_ entry: AppNotification, preset: NotificationSnoozePreset) {
        GrandLineNotificationCenter.shared.snooze(id: entry.id, until: preset.date(from: clock()))
        // The Snoozed list is the standing undo, one item at a time.
        showToast("Snoozed \(preset.phrase)", undo: { GrandLineNotificationCenter.shared.unsnooze(id: entry.id) })
        reload()
    }

    private func unsnooze(_ id: String) {
        GrandLineNotificationCenter.shared.unsnooze(id: id)
        showToast("Back in your inbox", undo: nil)
        reload()
    }

    /// "Hide until it changes" - the store's `dismiss`, informational only.
    /// No Undo (GL-33): the store keeps no way to take a dismissal back, and
    /// the item returns by itself the moment its detail changes.
    private func hide(_ entry: AppNotification) {
        guard entry.kind == .informational else { return }
        GrandLineNotificationCenter.shared.dismiss(id: entry.id)
        showToast("Hidden until it changes", undo: nil)
        reload()
    }

    private func mute(_ entry: AppNotification) {
        guard !entry.source.isEmpty else { return }
        let center = GrandLineNotificationCenter.shared
        center.mute(source: entry.source)
        showToast("Muted \(entry.source)", undo: { center.setMuted(false, source: entry.source) })
        reload()
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

    @objc private func openHomeClicked() {
        onOpenHome?()
        onRequestClose?()
    }

    // MARK: Footer

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
        timer.tolerance = 0.5
        toastTimer = timer
    }

    /// One line, in priority order: a toast, then what a focus session is
    /// holding, then nothing. There is no resting "Up to date" any more: it
    /// was a fixed string, and beside four open items it read as "nothing to
    /// do" (F7). What is snoozed is counted on the segment instead.
    private func renderFooter() {
        let center = GrandLineNotificationCenter.shared
        let held = center.heldCount
        undoButton.isHidden = true
        if let toastMessage {
            footerLabel.stringValue = toastMessage
            undoButton.isHidden = undoAction == nil
        } else if held > 0 {
            footerLabel.stringValue = held == 1
                ? "1 held until your focus session ends"
                : "\(held) held until your focus session ends"
        } else if center.isFocusQuietActive {
            footerLabel.stringValue = "Quiet while you focus"
        } else {
            footerLabel.stringValue = ""
        }
        // The label's width from the buttons beside it, never from its own
        // frame (gotcha (22)).
        let buttons = [markAllReadButton, undoButton, openHomeButton].filter { !$0.isHidden }
        let taken = buttons.reduce(CGFloat(0)) { $0 + ceil($1.fittingSize.width) + HelmMetrics.s2 }
        footerLabel.preferredMaxLayoutWidth = max(60, Self.width - 2 * NotificationBridgeMetrics.sideInset - taken)
        footerLabel.textColor = toastMessage != nil
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.good.hex(in: theme),
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            : HelmTheme.mutedInk(theme)
    }

    // MARK: Keyboard

    private func handleListKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(KeyChord.relevantModifierMask) == .command
        if command {
            switch event.keyCode {
            case 33: switchSegment(to: .inbox); return true    // ⌘[
            case 30: switchSegment(to: .snoozed); return true  // ⌘]
            default: return false
            }
        }
        guard segment == .inbox else { return false }
        let order = NotificationBridgeSections(GrandLineNotificationCenter.shared.entries).ordered
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
        case 1: // S - the selected card's snooze menu
            guard let index, let card = card(for: order[index].id) else { return false }
            showSnoozeMenu(for: order[index], from: card.snooze)
        case 51, 117: // delete, forward delete - hide an informational card
            guard let index, order[index].kind == .informational else { return false }
            hide(order[index])
        default:
            return false
        }
        return true
    }

    // MARK: Size and theme

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        let content = listStack.fittingSize.height
        listHeight?.constant = min(content, listHeightLimit)
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    func applyTheme(_ theme: HelmTheme) {
        let changed = theme.id != self.theme.id
        self.theme = theme
        guard isViewLoaded else { return }
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        // The cards float on the side-panel step of the ground, which is
        // bisected to clear `sidePanelSeparation` from the card in every
        // palette - the ground itself equals the card in several.
        scroll.backgroundColor = HelmTheme.sidePanelFill(theme)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(17), weight: .bold)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        dateLabel.font = HelmType.caption()
        dateLabel.textColor = muted
        segmentTabs?.applyTheme(theme)
        headerSeparator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        footerSeparator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        footerLabel.font = HelmType.caption()
        for view in listStack.arrangedSubviews {
            (view as? NotificationBridgeThemed)?.applyTheme(theme)
        }
        renderFooter()
        if changed { lastRenderSignature = nil }
    }

    #if FM_SELFTESTS
    var debugCards: [NotificationTriageCard] {
        listStack.arrangedSubviews.compactMap { $0 as? NotificationTriageCard }
    }
    var debugSnoozedRows: [NotificationSnoozedRow] {
        listStack.arrangedSubviews.compactMap { $0 as? NotificationSnoozedRow }
    }
    var debugMutedNote: String? {
        listStack.arrangedSubviews.compactMap { $0 as? NotificationMutedNote }.first?.text
    }
    var debugHeaderTitle: String { titleLabel.stringValue }
    var debugSegmentTitles: [String] { segmentTitles }
    var debugSegmentTabs: HelmSegmentedTabs? { segmentTabs }
    var debugFooterText: String { footerLabel.stringValue }
    var debugFooterButtons: [HelmButton] {
        [markAllReadButton, undoButton, openHomeButton].filter { !$0.isHidden }
    }
    var debugMarkAllReadEnabled: Bool { markAllReadButton.isEnabled }
    var debugEmptyState: NotificationBridgeEmptyView? { emptyState }
    var debugSelectedID: String? { selectedID }
    var debugExpandedIDs: Set<String> { expandedIDs }
    var debugListDocument: NSView { listDocument }
    var debugScroll: NSScrollView { scroll }
    var debugListHeight: CGFloat { listHeight?.constant ?? 0 }
    /// The list's limit in force here: `maxListHeight`, or less on a short screen.
    var debugListHeightLimit: CGFloat { listHeightLimit }
    func debugContextMenu(for entry: AppNotification) -> NSMenu { contextMenu(for: entry) }
    func debugClickMarkAllRead() { markAllReadButton.performClick(nil) }
    func debugClickUndo() { undoButton.performClick(nil) }
    func debugClickOpenHome() { openHomeButton.performClick(nil) }
    /// Clears a toast the way its timer would, so a suite can read what the
    /// footer says at rest without waiting four seconds.
    func debugShowToast(_ message: String?) { showToast(message, undo: nil) }
    func debugSendKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: keyCode) else { return false }
        // Through the list's own `keyDown`, the entry point AppKit calls.
        listDocument.keyDown(with: event)
        return true
    }
    #endif
}

// MARK: - Pieces

/// Anything in the list that repaints on a theme change.
protocol NotificationBridgeThemed: AnyObject {
    func applyTheme(_ theme: HelmTheme)
}

/// Builds the wrapping label every card uses. `wrappingLabelWithString`
/// rather than `labelWithString`, whose cell does not wrap at all (gotcha
/// (22)'s second half), and an explicit width so the label never sizes itself
/// from its own frame.
private func bridgeWrappingLabel(_ text: String, width: CGFloat, maxLines: Int = 0) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isSelectable = false
    label.maximumNumberOfLines = maxLines
    label.lineBreakMode = .byWordWrapping
    label.cell?.truncatesLastVisibleLine = maxLines > 0
    label.preferredMaxLayoutWidth = max(40, width)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
}

/// One notification as a triage card.
///
/// A plain view, **not** a `HoverHighlightView` and with no click recognizer:
/// its buttons stay real, reachable children for VoiceOver and for a real
/// click (an ancestor recognizer is gotcha (20)'s trap). A click on the card's
/// own surface selects it through `mouseDown`, which AppKit only delivers here
/// when no nested button was hit.
final class NotificationTriageCard: NSView, NotificationBridgeThemed {
    let entryID: String
    let primary: HelmButton
    let expand: HelmButton
    let snooze: HelmButton
    let hide: HelmButton

    var onSelect: (() -> Void)?
    var onBuildMenu: (() -> NSMenu?)?
    var onPrimary: (() -> Void)?
    var onToggleExpanded: (() -> Void)?
    var onSnooze: (() -> Void)?
    var onHide: (() -> Void)?
    var onMute: (() -> Void)?
    var onMarkRead: (() -> Void)?
    var onChildAction: ((String) -> Void)?

    private let entry: AppNotification
    private let isRead: Bool
    private let isSelected: Bool
    private let isCompact: Bool
    private let tile = IconTileView(size: NotificationBridgeMetrics.tileSide, cornerRadius: HelmMetrics.dLogoDot)
    private let kicker = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let ageLabel = NSTextField(labelWithString: "")
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let rule = NSView()
    private let edge = NSView()
    private var childrenView: NotificationChildrenView?
    /// Whether the snooze kept its label, or collapsed to its glyph (F6).
    private(set) var snoozeIsLabelled = true

    init(entry: AppNotification, theme: HelmTheme, width: CGFloat, isRead: Bool,
         isSelected: Bool, isExpanded: Bool, isCompact: Bool, ageText: String) {
        self.entry = entry
        self.entryID = entry.id
        self.isRead = isRead
        self.isSelected = isSelected
        self.isCompact = isCompact
        let pad = NotificationBridgeMetrics.cardPadding
        let inner = width - 2 * pad
        titleLabel = bridgeWrappingLabel(entry.title, width: inner)
        detailLabel = bridgeWrappingLabel(entry.subtext, width: inner, maxLines: 2)
        detailLabel.isHidden = entry.subtext.isEmpty || isCompact
        detailLabel.toolTip = entry.subtext.isEmpty ? nil : entry.subtext

        let label = entry.primaryAction?.label ?? "Open"
        primary = HelmButton(title: label, variant: .secondary, size: .regular)
        primary.accessibilityLabelOverride = "\(label) \(entry.title)"
        let count = entry.children.count
        expand = HelmButton(title: isExpanded ? "Hide \(count)" : "Show \(count)", variant: .quiet, size: .regular,
                            symbol: isExpanded ? "chevron.down" : "chevron.right")
        expand.symbolTrailing = true
        expand.accessibilityLabelOverride = isExpanded
            ? "Hide the \(count) items in \(entry.title)"
            : "Show the \(count) items in \(entry.title)"
        expand.setAccessibilityExpanded(isExpanded)
        expand.isHidden = entry.children.isEmpty
        snooze = HelmButton(title: "Snooze", variant: .quiet, size: .regular, symbol: "moon.zzz")
        snooze.toolTip = "Snooze (S)"
        snooze.accessibilityLabelOverride = "Snooze \(entry.title)"
        hide = HelmButton(symbol: "xmark", variant: .quiet, size: .small)
        hide.toolTip = "Hide until it changes (\u{232B})"
        hide.accessibilityLabelOverride = "Hide \(entry.title) until it changes"
        hide.isHidden = entry.kind != .informational
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tile.configure(symbol: NotificationRowPresentation(for: entry).icon, tint: entry.tint, pointSize: 11)
        kicker.translatesAutoresizingMaskIntoConstraints = false
        kicker.stringValue = (entry.source.isEmpty ? NotificationRowPresentation(for: entry).kicker : entry.source)
            .uppercased()
        kicker.lineBreakMode = .byTruncatingTail
        kicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = NotificationBridgeMetrics.dotSide / 2
        dot.isHidden = isRead
        ageLabel.translatesAutoresizingMaskIntoConstraints = false
        ageLabel.stringValue = ageText
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = NSStackView(views: [tile, kicker, dot, ageLabel, hide])
        top.orientation = .horizontal
        top.distribution = .fill
        top.alignment = .centerY
        top.spacing = HelmMetrics.s2
        top.setCustomSpacing(6, after: dot)
        top.setCustomSpacing(HelmMetrics.s1, after: ageLabel)
        top.translatesAutoresizingMaskIntoConstraints = false

        for button in [primary, expand, snooze, hide] {
            button.followsTextScale = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.target = self
        }
        // The primary is the one control allowed to give up width, so a
        // label too long for the bar truncates instead of evicting the
        // snooze (F6).
        primary.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(740), for: .horizontal)
        primary.action = #selector(primaryClicked)
        expand.action = #selector(expandClicked)
        snooze.action = #selector(snoozeClicked)
        hide.action = #selector(hideClicked)

        // F6: the bar's width is known, so decide here whether the snooze
        // keeps its label - from the buttons' own fitting widths, never from
        // a frame.
        let spacing = HelmMetrics.s1
        let needed = ceil(primary.fittingSize.width)
            + (expand.isHidden ? 0 : spacing + ceil(expand.fittingSize.width))
            + spacing + ceil(snooze.fittingSize.width)
        if needed > inner {
            snooze.title = ""
            snoozeIsLabelled = false
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [primary, expand, spacer, snooze])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        footer.spacing = spacing
        footer.translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = NSStackView(views: [top, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s0
        stack.setCustomSpacing(7, after: top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if isExpanded, !entry.children.isEmpty {
            let children = NotificationChildrenView(entry: entry, theme: theme, leadingInset: 0, trailingInset: 0) { [weak self] id in
                self?.onChildAction?(id)
            }
            childrenView = children
            stack.addArrangedSubview(children)
            stack.setCustomSpacing(6, after: detailLabel.isHidden ? titleLabel : detailLabel)
            children.widthAnchor.constraint(equalToConstant: max(40, inner)).isActive = true
        }
        stack.addArrangedSubview(rule)
        stack.addArrangedSubview(footer)
        let lastContent: NSView = childrenView ?? (detailLabel.isHidden ? titleLabel : detailLabel)
        stack.setCustomSpacing(9, after: lastContent)
        stack.setCustomSpacing(8, after: rule)

        edge.wantsLayer = true
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.isHidden = entry.kind != .actionNeeded
        layer?.masksToBounds = true

        addSubview(stack)
        addSubview(edge)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            stack.widthAnchor.constraint(equalToConstant: max(40, inner)),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // The hide glyph is drawn in the top line, so its square must not
            // grow the line past the tile.
            hide.heightAnchor.constraint(lessThanOrEqualToConstant: HelmType.scaledRowHeight(HelmButton.Size.small.minHeight)),
            dot.widthAnchor.constraint(equalToConstant: NotificationBridgeMetrics.dotSide),
            dot.heightAnchor.constraint(equalToConstant: NotificationBridgeMetrics.dotSide),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: NotificationBridgeMetrics.edgeWidth),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.spokenLabel(entry: entry, ageText: ageText, isRead: isRead))
        setAccessibilityCustomActions(customActions())
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static func spokenLabel(entry: AppNotification, ageText: String, isRead: Bool) -> String {
        [entry.kind == .actionNeeded ? "Needs you" : "", entry.source, entry.title, entry.subtext,
         ageText, isRead ? "" : "unread"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// F8: every action a VoiceOver user can reach from the card itself,
    /// without tabbing through its buttons.
    private func customActions() -> [NSAccessibilityCustomAction] {
        var actions = [
            NSAccessibilityCustomAction(name: primary.title) { [weak self] in self?.onPrimary?(); return true },
            NSAccessibilityCustomAction(name: "Snooze") { [weak self] in self?.onSnooze?(); return true },
            NSAccessibilityCustomAction(name: isRead ? "Mark as unread" : "Mark as read") { [weak self] in
                self?.onMarkRead?(); return true
            },
        ]
        if entry.kind == .informational {
            actions.append(NSAccessibilityCustomAction(name: "Hide until it changes") { [weak self] in
                self?.onHide?(); return true
            })
        }
        if !entry.source.isEmpty {
            actions.append(NSAccessibilityCustomAction(name: "Mute \(entry.source)") { [weak self] in
                self?.onMute?(); return true
            })
        }
        return actions
    }

    @objc private func primaryClicked() { onPrimary?() }
    @objc private func expandClicked() { onToggleExpanded?() }
    @objc private func snoozeClicked() { onSnooze?() }
    @objc private func hideClicked() { onHide?() }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildMenu?() ?? super.menu(for: event)
    }

    func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: NotificationBridgeMetrics.cardRadius,
                                  daylightRadius: NotificationBridgeMetrics.cardRadius)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        if isSelected {
            let hair = HelmTheme.nsColor(theme.chromeLineHex)
            layer?.borderColor = (hair.blended(withFraction: 0.65, of: accent) ?? accent).cgColor
            layer?.borderWidth = 1.5
        }
        let edgeHex = entry.isWarning ? HelmTint.critical.hex(in: theme) : theme.accentHex
        edge.layer?.backgroundColor = HelmTheme.nsColor(edgeHex).cgColor
        let kickerColor = entry.kind == .actionNeeded
            ? HelmContrast.legibleTintedText(tintHex: edgeHex, over: surface, theme: theme)
            : muted
        kicker.attributedStringValue = NSAttributedString(
            string: kicker.stringValue, attributes: HelmType.kickerAttributes(color: kickerColor))
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(14), weight: isRead ? .medium : .semibold)
        titleLabel.textColor = ink
        let warning = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
        detailLabel.font = HelmType.body()
        detailLabel.textColor = entry.isWarning ? warning : muted
        ageLabel.font = HelmType.caption()
        ageLabel.textColor = entry.isWarning ? warning : muted
        dot.layer?.backgroundColor = accent.cgColor
        rule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.7).cgColor
        tile.applyTheme(theme)
        childrenView?.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugDetailLabel: NSTextField { detailLabel }
    var debugDetail: String { detailLabel.stringValue }
    var debugKicker: String { kicker.stringValue }
    var debugAgeText: String { ageLabel.stringValue }
    var debugIsCompact: Bool { isCompact }
    var debugHasAccentEdge: Bool { !edge.isHidden }
    var debugUnreadDotVisible: Bool { !dot.isHidden }
    var debugChildRows: [NotificationChildRowView] { childrenView?.debugChildRows ?? [] }
    /// A click on the card's own surface, through the real `mouseDown` entry
    /// point AppKit calls when no nested button was hit.
    func debugSelectByClick() {
        let point = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        mouseDown(with: event)
    }
    #endif
}

/// One row of the Snoozed list: what it is, when it comes back, and a way to
/// bring it back now.
final class NotificationSnoozedRow: NSView, NotificationBridgeThemed {
    let entryID: String
    let unsnoozeButton = HelmButton(title: "Unsnooze", variant: .secondary, size: .regular)
    var onUnsnooze: (() -> Void)?

    private let entry: AppNotification
    private let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.dLogoDot)
    private let titleLabel: NSTextField
    private let returnLabel: NSTextField

    init(entry: AppNotification, theme: HelmTheme, width: CGFloat, returnText: String) {
        self.entry = entry
        self.entryID = entry.id
        let pad = NotificationBridgeMetrics.cardPadding
        unsnoozeButton.followsTextScale = true
        let textWidth = width - 2 * pad - HelmMetrics.tileSmall - 2 * HelmMetrics.s3
            - ceil(unsnoozeButton.fittingSize.width)
        titleLabel = bridgeWrappingLabel(entry.title, width: textWidth)
        returnLabel = bridgeWrappingLabel(returnText, width: textWidth)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        tile.configure(symbol: NotificationRowPresentation(for: entry).icon, tint: entry.tint, pointSize: 12)
        unsnoozeButton.translatesAutoresizingMaskIntoConstraints = false
        unsnoozeButton.setContentHuggingPriority(.required, for: .horizontal)
        unsnoozeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        unsnoozeButton.accessibilityLabelOverride = "Unsnooze \(entry.title)"
        unsnoozeButton.target = self
        unsnoozeButton.action = #selector(unsnoozeClicked)

        let text = NSStackView(views: [titleLabel, returnLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        addSubview(text)
        addSubview(unsnoozeButton)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            tile.topAnchor.constraint(equalTo: text.topAnchor),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s3),
            text.widthAnchor.constraint(equalToConstant: max(40, textWidth)),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            unsnoozeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            unsnoozeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Snoozed, \(entry.title), \(returnText)")
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func unsnoozeClicked() { onUnsnooze?() }

    func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: NotificationBridgeMetrics.cardRadius,
                                  daylightRadius: NotificationBridgeMetrics.cardRadius)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(14), weight: .medium)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        returnLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        returnLabel.textColor = HelmContrast.legibleTintedText(tintHex: theme.accentHex, over: surface, theme: theme)
        tile.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugReturnText: String { returnLabel.stringValue }
    #endif
}

/// Under the Snoozed list: which sources are muted, and where that is
/// changed. Mutes are a setting, so this panel lists them and leaves them
/// alone (F3); un-snoozing never un-mutes.
final class NotificationMutedNote: NSView, NotificationBridgeThemed {
    let text: String
    private let label: NSTextField

    init(sources: [String], theme: HelmTheme, width: CGFloat) {
        text = "Muted: \(sources.joined(separator: ", ")). Change this in \(PlaceName.of(.settings)) \u{203A} Notifications."
        label = bridgeWrappingLabel(text, width: width)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme(_ theme: HelmTheme) {
        label.font = HelmType.caption()
        label.textColor = HelmContrast.legible(HelmTheme.mutedInk(theme), over: HelmTheme.sidePanelFill(theme))
    }
}

/// An empty list: a tile and two sentences.
final class NotificationBridgeEmptyView: NSView, NotificationBridgeThemed {
    private let tile = IconTileView(size: 46, cornerRadius: 14)
    private let titleLabel: NSTextField
    private let bodyLabel: NSTextField

    init(title: String, body: String, symbol: String, tint: HelmTint) {
        titleLabel = NSTextField(labelWithString: title)
        bodyLabel = NSTextField(wrappingLabelWithString: body)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tile.configure(symbol: symbol, tint: tint, pointSize: 20)
        for label in [titleLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.isSelectable = false
        }
        let stack = NSStackView(views: [tile, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = HelmMetrics.s1
        stack.setCustomSpacing(12, after: tile)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 16, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        bodyLabel.preferredMaxLayoutWidth = NotificationBridgePanelViewController.width - 4 * NotificationBridgeMetrics.sideInset
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title). \(body)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme(_ theme: HelmTheme) {
        let ground = HelmTheme.sidePanelFill(theme)
        tile.applyTheme(theme)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(18), weight: .bold)
        titleLabel.textColor = HelmContrast.legible(HelmTheme.nsColor(theme.chromeInkHex), over: ground)
        bodyLabel.font = HelmType.body()
        bodyLabel.textColor = HelmContrast.legible(HelmTheme.mutedInk(theme), over: ground)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    #endif
}
