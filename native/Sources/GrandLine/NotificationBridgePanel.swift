// Grand Line - native macOS app.
//
// The Bridge notification panel (`fm/grandline-notification-bridge`), the
// captain-approved style A from the notification-styles board. It is what the
// sidebar layout's bell opens. The floating bar is frozen (R2-ARCH-01), so it
// keeps `NotificationPanelViewController` exactly as it was, and the two
// panels read the one store.
//
// **The shape.** One hero "Now" card for the single most urgent item that
// needs the captain, with its buttons visible at rest. Then "Up next" for the
// other action-needed items, and "When you have a minute" for the
// informational ones. The store's own `AppNotificationKind` split is the whole
// classification, so there is no new data and no second rule that could drift
// from the first (`NotificationBridgeSections`).
//
// **What it fixes, from the before renders.** Titles truncated at about four
// words because the classic row's trailing column reserved room for a
// hover-only button. Here titles and details wrap, and every row carries its
// action at rest, under the text, where it never competes with the title for
// width. One item gets visual priority instead of every row weighing the same.
//
// **Keyboard.** The list's document view is the first responder, the same as
// the classic panel: ↑ ↓ select (the Now card counts as the first item), → ←
// expand and collapse, Return runs the selected item's primary action, and
// Escape is `HelmBarPanel`'s. Every button is also a real key view, so Tab
// reaches the Now card's buttons, each row's buttons, then the footer.
//
// **VoiceOver.** The Now card and each row are groups whose label reads the
// whole item ("Now: Tasks, 2 tasks due or overdue, 1 is overdue, overdue"),
// and whose children stay reachable - unlike an activatable
// `HoverHighlightView`, which hides its children because it *is* the button.
// Every button names its subject ("Answer 1 task needs your decision"), since
// a list of five "Open" buttons is no list at all.

import AppKit

/// Which of the two panels a `NotificationCenterController` shows.
enum NotificationPanelStyle {
    /// The floating bar's panel, frozen with the floating bar (R2-ARCH-01).
    case classic
    /// The sidebar layout's Bridge panel.
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
        // push an overdue task out of the hero slot.
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

    /// An Up next row's leading time: what the source states ("overdue"),
    /// else the time of day it arrived, in the locale's own clock.
    static func leading(for entry: AppNotification, locale: Locale = .current) -> String {
        if let stated = entry.timeText { return stated }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: entry.date)
    }

    /// The Now card's pill: the source's own time if it states one, else how
    /// long ago it arrived.
    static func nowPill(for entry: AppNotification, now: Date) -> String {
        entry.timeText ?? NotificationTimeText.relative(entry.date, now: now)
    }
}

/// The geometry, named once because the wrapping labels' widths are computed
/// from it rather than read back from their own frames (gotcha (22)).
enum NotificationBridgeMetrics {
    static let sideInset: CGFloat = 16
    static let gutter: CGFloat = 10
    static let tileSide: CGFloat = 28
    static let dotSide: CGFloat = 7
    static let nowCardMargin: CGFloat = 12
    static let nowCardPadding: CGFloat = 14
    static let nowCardRadius: CGFloat = 14
    /// The Up next time column's floor, scaled. It grows to fit a longer
    /// locale clock ("11:21 AM") rather than truncating it.
    static var timeColumn: CGFloat { HelmType.scaled(52) }
}

// MARK: - The panel

final class NotificationBridgePanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    static let width: CGFloat = 384
    /// The footer at rest. Shorter than the classic panel's "Updated just
    /// now", which truncated beside the two buttons at the Larger text size.
    static let restingFooter = "Up to date"
    /// The list scrolls past this. Scaled, because at the Larger text size the
    /// same five items are 30% taller and a fixed cap would scroll sooner for
    /// exactly the captain who asked for bigger text.
    static var maxListHeight: CGFloat { HelmType.scaled(520) }

    private let titleLabel = NSTextField(labelWithString: "Waiting for you")
    private let dateLabel = NSTextField(labelWithString: "")
    private let needYouPill = HelmStatusPill(style: .pill)
    private let laterLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSView()

    private let scroll = NSScrollView()
    private let listStack = NSStackView()
    private let listDocument = NotificationListDocumentView()
    private var listHeight: NSLayoutConstraint?

    private let emptyState = NotificationBridgeEmptyView()

    private let footerSeparator = NSView()
    /// Wraps to a second line rather than truncating: at the Larger text size
    /// a toast plus Undo, Mark all read and Open Home do not fit on one.
    private let footerLabel = NSTextField(wrappingLabelWithString: NotificationBridgePanelViewController.restingFooter)
    private let undoButton = HelmButton(title: "Undo", variant: .quiet, size: .small)
    private let restoreButton = HelmButton(title: "", variant: .quiet, size: .small)
    private let markAllReadButton = HelmButton(title: "Mark all read", variant: .quiet, size: .small)
    private let openHomeButton = HelmButton(title: "Open Home", variant: .primary, size: .small)

    private var selectedID: String?
    private var expandedIDs: Set<String> = []
    private var toastTimer: Timer?
    private var undoAction: (() -> Void)?
    private var toastMessage: String?
    private var lastRenderSignature: String?

    /// Injectable, as on the classic panel.
    var clock: () -> Date = { Date() }

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?
    /// The footer's main action. Set by the sidebar shell; the button hides
    /// when nothing is wired, rather than offering a button that does nothing.
    var onOpenHome: (() -> Void)? {
        didSet { openHomeButton.isHidden = onOpenHome == nil }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 320))
        root.wantsLayer = true
        view = root

        for label in [titleLabel, dateLabel, laterLabel, footerLabel] {
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
        titleStack.setHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        laterLabel.setContentHuggingPriority(.required, for: .horizontal)
        laterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let headerRow = NSStackView(views: [titleStack, needYouPill, laterLabel])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY
        headerRow.spacing = HelmMetrics.s2
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 10, right: 0)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(listStack)
        listDocument.onKey = { [weak self] event in self?.handleListKey(event) ?? false }
        listDocument.setAccessibilityElement(true)
        listDocument.setAccessibilityRole(.list)
        listDocument.setAccessibilityLabel("Notifications")

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listDocument
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        footerSeparator.wantsLayer = true
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        footerLabel.maximumNumberOfLines = 2
        footerLabel.isSelectable = false
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for (button, action) in [(undoButton, #selector(undoClicked)),
                                 (restoreButton, #selector(restoreClicked)),
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
        restoreButton.isHidden = true
        openHomeButton.isHidden = onOpenHome == nil
        openHomeButton.accessibilityLabelOverride = "Open Home"
        let footerRow = NSStackView(views: [footerLabel, undoButton, restoreButton, markAllReadButton, openHomeButton])
        footerRow.orientation = .horizontal
        footerRow.distribution = .fill
        footerRow.alignment = .centerY
        footerRow.spacing = HelmMetrics.s2
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerRow)
        root.addSubview(headerSeparator)
        root.addSubview(scroll)
        root.addSubview(emptyState)
        root.addSubview(footerSeparator)
        root.addSubview(footerRow)

        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 120)
        self.listHeight = listHeight
        let inset = NotificationBridgeMetrics.sideInset

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),

            headerRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            headerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            headerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            headerSeparator.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 12),
            headerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,

            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),

            footerSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerRow.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 10),
            footerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            footerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
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
        // Tab walks the Now card's buttons, each row's buttons, then the
        // footer, in the order they are drawn.
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

    private func renderSignature(_ sections: NotificationBridgeSections,
                                 center: GrandLineNotificationCenter) -> String {
        var parts = [
            "theme:\(theme.id)", "scale:\(ChromeTextScale.shared.scale)",
            "width:\(contentWidth)",
            "unread:\(center.unreadCount)", "snoozed:\(center.snoozedCount)", "held:\(center.heldCount)",
            "selected:\(selectedID ?? "-")",
            "day:\(NotificationBridgeTimeText.headerDate(clock()))",
        ]
        let now = clock()
        for (index, entry) in sections.ordered.enumerated() {
            let children = entry.children
                .map { "\($0.id)/\($0.name)/\($0.meta)/\($0.actionLabel ?? "-")/\($0.isMonospaced)" }
                .joined(separator: ",")
            parts.append([
                "\(index)", entry.id, entry.title, entry.subtext, entry.source, entry.clearCondition,
                "\(entry.kind)", "\(entry.tint)", entry.timeText ?? NotificationTimeText.relative(entry.date, now: now),
                "\(entry.isWarning)", "\(center.isRead(entry))", "\(expandedIDs.contains(entry.id))",
                entry.primaryAction?.label ?? "-", children,
            ].joined(separator: "\u{1f}"))
        }
        return parts.joined(separator: "\u{1e}")
    }

    func reload() {
        guard isViewLoaded else { return }
        let center = GrandLineNotificationCenter.shared
        let sections = NotificationBridgeSections(center.entries)
        let liveIDs = Set(sections.ordered.map(\.id))
        expandedIDs.formIntersection(liveIDs)
        if let selectedID, !liveIDs.contains(selectedID) { self.selectedID = nil }

        let signature = renderSignature(sections, center: center)
        if signature == lastRenderSignature { return }
        lastRenderSignature = signature

        dateLabel.stringValue = NotificationBridgeTimeText.headerDate(clock())
        let actionCount = sections.upNext.count + (sections.now == nil ? 0 : 1)
        needYouPill.isHidden = actionCount == 0
        needYouPill.configure(text: "\(actionCount) need\(actionCount == 1 ? "s" : "") you", tint: .warn, theme: theme)
        laterLabel.stringValue = "\(sections.later.count) later"
        laterLabel.isHidden = sections.later.isEmpty
        markAllReadButton.isEnabled = center.unreadCount > 0
        markAllReadButton.isHidden = sections.isEmpty

        emptyState.isHidden = !sections.isEmpty
        scroll.isHidden = sections.isEmpty

        // Rebuilt rather than reconciled: the list is a handful of items by
        // design, and the signature above already skips every reload that
        // would draw the same thing - which is all PF3 measured.
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let width = contentWidth
        if let now = sections.now {
            let card = NotificationBridgeNowCard(entry: now, theme: theme, contentWidth: width,
                                                 isRead: center.isRead(now),
                                                 isSelected: selectedID == now.id,
                                                 isExpanded: expandedIDs.contains(now.id),
                                                 pillText: NotificationBridgeTimeText.nowPill(for: now, now: clock()))
            wire(card.actions, entry: now)
            add(card, inset: NotificationBridgeMetrics.nowCardMargin)
        }
        if !sections.upNext.isEmpty {
            add(NotificationBridgeSectionHeader(title: "Up next", theme: theme), inset: 0)
            for entry in sections.upNext { addRow(entry, timed: true, width: width, center: center) }
        }
        if !sections.later.isEmpty {
            add(NotificationBridgeSectionHeader(title: "When you have a minute", theme: theme), inset: 0)
            for entry in sections.later { addRow(entry, timed: false, width: width, center: center) }
        }

        renderFooter()
        applyTheme(theme)
        updateSize()
    }

    private func add(_ view: NSView, inset: CGFloat) {
        listStack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: listStack.leadingAnchor, constant: inset).isActive = true
        view.trailingAnchor.constraint(equalTo: listStack.trailingAnchor, constant: -inset).isActive = true
    }

    private func addRow(_ entry: AppNotification, timed: Bool, width: CGFloat, center: GrandLineNotificationCenter) {
        let row = NotificationBridgeRowView(entry: entry, timed: timed, theme: theme, contentWidth: width,
                                            isRead: center.isRead(entry),
                                            isSelected: selectedID == entry.id,
                                            isExpanded: expandedIDs.contains(entry.id),
                                            timeText: timed
                                                ? NotificationBridgeTimeText.leading(for: entry)
                                                : (entry.timeText ?? NotificationTimeText.relative(entry.date, now: clock())))
        wire(row.actions, entry: entry)
        let id = entry.id
        row.onSelect = { [weak self] in self?.select(id, markingRead: true) }
        row.onBuildMenu = { [weak self] in self?.contextMenu(for: entry) }
        add(row, inset: 0)
    }

    /// The item's buttons, wherever they are drawn. Looked up by id at click
    /// time for the children, so a child acts on the entry as the store has it.
    private func wire(_ actions: NotificationBridgeItemActions, entry: AppNotification) {
        let id = entry.id
        actions.onPrimary = { [weak self] in self?.performPrimaryAction(entry) }
        actions.onToggleExpanded = { [weak self] in self?.toggleExpanded(id) }
        actions.onSnooze = { [weak self] in
            self?.snooze(entry, by: 60 * 60, message: "Snoozed for 1 hour")
        }
        actions.onChildAction = { [weak self] childID in self?.performChildAction(childID: childID, ofEntryID: id) }
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
        guard let selectedID,
              let view = listStack.arrangedSubviews.first(where: { ($0 as? NotificationBridgeItemView)?.entryID == selectedID })
        else { return }
        view.scrollToVisible(view.bounds)
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

    /// The classic panel's menu, kept: right-click is still the place for
    /// read/unread, copy and mute.
    private func contextMenu(for entry: AppNotification) -> NSMenu {
        selectedID = entry.id
        reload()
        let center = GrandLineNotificationCenter.shared
        let menu = NSMenu()
        menu.addItem(HelmMenuAction.item("Snooze for 1 hour") { [weak self] in
            self?.snooze(entry, by: 60 * 60, message: "Snoozed for 1 hour")
        })
        menu.addItem(.separator())
        let isRead = center.isRead(entry)
        menu.addItem(HelmMenuAction.item(isRead ? "Mark as unread" : "Mark as read") { [weak self] in
            center.setRead(!isRead, id: entry.id)
            self?.showToast(isRead ? "Marked unread" : "Marked read", undo: {
                center.setRead(isRead, id: entry.id)
            })
            self?.reload()
        })
        menu.addItem(HelmMenuAction.item("Copy details") { [weak self] in
            let text = entry.subtext.isEmpty ? entry.title : "\(entry.title) - \(entry.subtext)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.showToast("Copied details", undo: nil)
        })
        if !entry.source.isEmpty {
            menu.addItem(.separator())
            menu.addItem(HelmMenuAction.item("Mute \(entry.source)") { [weak self] in
                center.mute(source: entry.source)
                self?.showToast("Muted \(entry.source)", undo: { center.setMuted(false, source: entry.source) })
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
        // The footer's "N snoozed · Restore" is the standing undo.
        showToast(message, undo: nil)
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

    @objc private func restoreClicked() {
        GrandLineNotificationCenter.shared.restoreHidden()
        showToast("Restored", undo: nil)
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

    /// One line, in priority order: a toast, then what is hidden and how to
    /// get it back, then what a focus session is holding, then the resting
    /// "Updated just now".
    private func renderFooter() {
        let center = GrandLineNotificationCenter.shared
        let snoozed = center.snoozedCount
        let held = center.heldCount
        undoButton.isHidden = true
        restoreButton.isHidden = true
        if let toastMessage {
            footerLabel.stringValue = toastMessage
            undoButton.isHidden = undoAction == nil
        } else if snoozed > 0 {
            footerLabel.stringValue = snoozed == 1 ? "1 snoozed" : "\(snoozed) snoozed"
            restoreButton.title = "Restore"
            restoreButton.accessibilityLabelOverride = "Restore \(snoozed) snoozed or muted"
            restoreButton.isHidden = false
        } else if held > 0 {
            footerLabel.stringValue = held == 1
                ? "1 held until your focus session ends"
                : "\(held) held until your focus session ends"
        } else if center.isFocusQuietActive {
            footerLabel.stringValue = "Quiet while you focus"
        } else {
            footerLabel.stringValue = Self.restingFooter
        }
        // The label's width from the buttons beside it, never from its own
        // frame (gotcha (22)).
        let buttons = [undoButton, restoreButton, markAllReadButton, openHomeButton].filter { !$0.isHidden }
        let taken = buttons.reduce(CGFloat(0)) { $0 + ceil($1.fittingSize.width) + HelmMetrics.s2 }
        footerLabel.preferredMaxLayoutWidth = max(60, Self.width - 2 * NotificationBridgeMetrics.sideInset - taken)
        footerLabel.textColor = toastMessage != nil
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.good.hex(in: theme),
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            : HelmTheme.mutedInk(theme)
    }

    // MARK: Keyboard

    private func handleListKey(_ event: NSEvent) -> Bool {
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
        default:
            return false
        }
        return true
    }

    // MARK: Size and theme

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        let content = listStack.fittingSize.height
        let floor = emptyState.isHidden ? 0 : emptyState.fittingSize.height
        listHeight?.constant = min(max(content, floor), Self.maxListHeight)
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
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(17), weight: .bold)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        dateLabel.font = HelmType.caption()
        dateLabel.textColor = muted
        laterLabel.font = HelmType.chip()
        laterLabel.textColor = muted
        needYouPill.applyTheme(theme)
        headerSeparator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        footerSeparator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        footerLabel.font = HelmType.caption()
        emptyState.applyTheme(theme)
        for view in listStack.arrangedSubviews {
            (view as? NotificationBridgeThemed)?.applyTheme(theme)
        }
        renderFooter()
        if changed { lastRenderSignature = nil }
    }

    #if FM_SELFTESTS
    var debugItems: [NotificationBridgeItemView] {
        listStack.arrangedSubviews.compactMap { $0 as? NotificationBridgeItemView }
    }
    var debugNowCard: NotificationBridgeNowCard? {
        listStack.arrangedSubviews.compactMap { $0 as? NotificationBridgeNowCard }.first
    }
    var debugRows: [NotificationBridgeRowView] {
        listStack.arrangedSubviews.compactMap { $0 as? NotificationBridgeRowView }
    }
    var debugSectionHeaders: [String] {
        listStack.arrangedSubviews.compactMap { ($0 as? NotificationBridgeSectionHeader)?.title }
    }
    var debugHeaderTitle: String { titleLabel.stringValue }
    var debugNeedYouText: String? { needYouPill.isHidden ? nil : needYouPill.text }
    var debugLaterText: String? { laterLabel.isHidden ? nil : laterLabel.stringValue }
    var debugFooterText: String { footerLabel.stringValue }
    var debugFooterButtons: [HelmButton] {
        [undoButton, restoreButton, markAllReadButton, openHomeButton].filter { !$0.isHidden }
    }
    var debugMarkAllReadEnabled: Bool { markAllReadButton.isEnabled }
    var debugEmptyStateShowing: Bool { !emptyState.isHidden }
    var debugEmptyState: NotificationBridgeEmptyView { emptyState }
    var debugSelectedID: String? { selectedID }
    var debugExpandedIDs: Set<String> { expandedIDs }
    var debugListDocument: NSView { listDocument }
    var debugListHeight: CGFloat { listHeight?.constant ?? 0 }
    func debugContextMenu(for entry: AppNotification) -> NSMenu { contextMenu(for: entry) }
    func debugClickMarkAllRead() { markAllReadButton.performClick(nil) }
    func debugClickRestore() { restoreButton.performClick(nil) }
    func debugClickOpenHome() { openHomeButton.performClick(nil) }
    /// Clears a toast the way its timer would, so a suite can read what the
    /// footer says at rest without waiting four seconds.
    func debugShowToast(_ message: String?) { showToast(message, undo: nil) }
    func debugSendKey(_ keyCode: UInt16) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: keyCode) else { return false }
        return handleListKey(event)
    }
    #endif
}

// MARK: - Pieces

/// Anything in the list that repaints on a theme change.
protocol NotificationBridgeThemed: AnyObject {
    func applyTheme(_ theme: HelmTheme)
}

/// The Now card and a row, as the list's selection and keyboard see them.
protocol NotificationBridgeItemView: NSView, NotificationBridgeThemed {
    var entryID: String { get }
    var actions: NotificationBridgeItemActions { get }
}

/// A section's kicker - "UP NEXT", "WHEN YOU HAVE A MINUTE".
final class NotificationBridgeSectionHeader: NSView, NotificationBridgeThemed {
    private let label: NSTextField
    /// The section's name as written; the label draws it as a kicker.
    let title: String

    init(title: String, theme: HelmTheme) {
        self.title = title
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NotificationBridgeMetrics.sideInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -NotificationBridgeMetrics.sideInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        // A heading, so the VoiceOver rotor can jump between sections.
        label.setAccessibilityRole(.staticText)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme(_ theme: HelmTheme) {
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
    }

}

/// One item's buttons and the callbacks they reach, shared by the Now card
/// and the rows so both offer the same actions the same way.
final class NotificationBridgeItemActions {
    let primary: HelmButton
    let expand: HelmButton
    let snooze: HelmButton
    let row: NSStackView

    var onPrimary: (() -> Void)?
    var onToggleExpanded: (() -> Void)?
    var onSnooze: (() -> Void)?
    var onChildAction: ((String) -> Void)?

    init(entry: AppNotification, primaryVariant: HelmButton.Variant, size: HelmButton.Size,
         isExpanded: Bool, showsSnooze: Bool) {
        let label = entry.primaryAction?.label ?? "Open"
        primary = HelmButton(title: label, variant: primaryVariant, size: size)
        primary.accessibilityLabelOverride = "\(label) \(entry.title)"
        let count = entry.children.count
        expand = HelmButton(title: isExpanded ? "Hide \(count)" : "Show \(count)", variant: .quiet, size: .small)
        expand.accessibilityLabelOverride = isExpanded
            ? "Hide the \(count) items in \(entry.title)"
            : "Show the \(count) items in \(entry.title)"
        expand.setAccessibilityExpanded(isExpanded)
        expand.isHidden = entry.children.isEmpty
        snooze = HelmButton(symbol: "moon.zzz", variant: .quiet, size: size)
        snooze.toolTip = "Snooze for 1 hour"
        snooze.accessibilityLabelOverride = "Snooze \(entry.title) for 1 hour"
        snooze.isHidden = !showsSnooze
        row = NSStackView(views: [primary, expand, snooze])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        for button in [primary, expand, snooze] {
            button.followsTextScale = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.target = self
        }
        primary.action = #selector(primaryClicked)
        expand.action = #selector(expandClicked)
        snooze.action = #selector(snoozeClicked)
    }

    @objc private func primaryClicked() { onPrimary?() }
    @objc private func expandClicked() { onToggleExpanded?() }
    @objc private func snoozeClicked() { onSnooze?() }
}

/// Builds the wrapping label every Bridge item uses. `wrappingLabelWithString`
/// rather than `labelWithString`, whose cell does not wrap at all (gotcha
/// (22)'s second half), and an explicit width so the label never sizes itself
/// from its own frame.
private func bridgeWrappingLabel(_ text: String, width: CGFloat) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isSelectable = false
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.preferredMaxLayoutWidth = max(40, width)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
}

/// The hero card.
final class NotificationBridgeNowCard: NSView, NotificationBridgeItemView {
    let entryID: String
    let actions: NotificationBridgeItemActions
    private let entry: AppNotification
    private let kicker = NSTextField(labelWithString: "")
    private let bolt = NSImageView()
    private let pill = HelmStatusPill(style: .pill)
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let dot = NSView()
    private var childrenView: NotificationChildrenView?
    private let isRead: Bool
    private let isSelected: Bool

    init(entry: AppNotification, theme: HelmTheme, contentWidth: CGFloat, isRead: Bool,
         isSelected: Bool, isExpanded: Bool, pillText: String) {
        self.entry = entry
        self.entryID = entry.id
        self.isRead = isRead
        self.isSelected = isSelected
        let inner = contentWidth - 2 * NotificationBridgeMetrics.nowCardMargin - 2 * NotificationBridgeMetrics.nowCardPadding
        titleLabel = bridgeWrappingLabel(entry.title, width: inner)
        detailLabel = bridgeWrappingLabel(entry.subtext, width: inner)
        detailLabel.isHidden = entry.subtext.isEmpty
        actions = NotificationBridgeItemActions(entry: entry, primaryVariant: .primary, size: .regular,
                                                isExpanded: isExpanded, showsSnooze: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = NotificationBridgeMetrics.nowCardRadius
        layer?.borderWidth = 1

        kicker.translatesAutoresizingMaskIntoConstraints = false
        kicker.stringValue = entry.source.isEmpty ? "NOW" : "NOW \u{00B7} \(entry.source.uppercased())"
        kicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kicker.lineBreakMode = .byTruncatingTail
        bolt.image = HelmSymbol.image("bolt.fill", pointSize: HelmType.scaled(10), weight: .bold)
        bolt.translatesAutoresizingMaskIntoConstraints = false
        bolt.setContentHuggingPriority(.required, for: .horizontal)
        pill.configure(text: pillText, tint: entry.isWarning ? .critical : .accent, theme: theme)
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = NotificationBridgeMetrics.dotSide / 2
        dot.isHidden = isRead
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [bolt, kicker, spacer, dot, pill])
        top.orientation = .horizontal
        top.distribution = .fill
        top.alignment = .centerY
        top.spacing = HelmMetrics.s2
        top.translatesAutoresizingMaskIntoConstraints = false

        // The snooze glyph sits at the trailing end, as on the board.
        actions.row.removeArrangedSubview(actions.snooze)
        let actionSpacer = NSView()
        actionSpacer.translatesAutoresizingMaskIntoConstraints = false
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.row.addArrangedSubview(actionSpacer)
        actions.row.addArrangedSubview(actions.snooze)
        actions.row.distribution = .fill

        let stack = NSStackView(views: [top, titleLabel, detailLabel, actions.row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.setCustomSpacing(10, after: top)
        stack.setCustomSpacing(12, after: detailLabel.isHidden ? titleLabel : detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if isExpanded, !entry.children.isEmpty {
            let children = NotificationChildrenView(entry: entry, theme: theme, leadingInset: 0, trailingInset: 0) { [weak self] id in
                self?.actions.onChildAction?(id)
            }
            childrenView = children
            stack.addArrangedSubview(children)
            children.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        let pad = NotificationBridgeMetrics.nowCardPadding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dot.widthAnchor.constraint(equalToConstant: NotificationBridgeMetrics.dotSide),
            dot.heightAnchor.constraint(equalToConstant: NotificationBridgeMetrics.dotSide),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.spokenLabel(entry: entry, pillText: pillText, isRead: isRead))
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static func spokenLabel(entry: AppNotification, pillText: String, isRead: Bool) -> String {
        (["Now:", entry.source, entry.title, entry.subtext, pillText, isRead ? "" : "unread"])
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .replacingOccurrences(of: "Now:, ", with: "Now: ")
    }

    func applyTheme(_ theme: HelmTheme) {
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        // The board's recipe: a wash of the accent over the card, stronger in
        // the dark palettes, with a border of the accent over the hairline.
        let wash: CGFloat = theme.mode == .dark ? 0.12 : 0.08
        let fill = card.blended(withFraction: isSelected ? wash + 0.06 : wash, of: accent) ?? card
        layer?.backgroundColor = fill.cgColor
        let hair = HelmTheme.nsColor(theme.chromeLineHex)
        layer?.borderColor = (hair.blended(withFraction: isSelected ? 0.6 : 0.3, of: accent) ?? hair).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
        let accentText = HelmContrast.legibleTintedText(tintHex: theme.accentHex, over: fill, theme: theme)
        kicker.attributedStringValue = NSAttributedString(
            string: kicker.stringValue, attributes: HelmType.kickerAttributes(color: accentText))
        bolt.contentTintColor = accentText
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(18), weight: .bold)
        // Corrected against the washed fill, not the panel: a low-contrast
        // palette's ink (Solarized Dark measured 3.98:1) loses the margin the
        // accent wash takes.
        titleLabel.textColor = HelmContrast.legible(HelmTheme.nsColor(theme.chromeInkHex), over: fill)
        detailLabel.font = HelmType.body()
        detailLabel.textColor = entry.isWarning
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: fill, theme: theme)
            : HelmContrast.legible(HelmTheme.mutedInk(theme), over: fill)
        dot.layer?.backgroundColor = accent.cgColor
        pill.applyTheme(theme)
        childrenView?.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugDetail: String { detailLabel.stringValue }
    var debugKicker: String { kicker.stringValue }
    var debugPillText: String { pill.text }
    var debugUnreadDotVisible: Bool { !dot.isHidden }
    var debugChildRows: [NotificationChildRowView] { childrenView?.debugChildRows ?? [] }
    #endif
}

/// One Up next or "When you have a minute" row.
///
/// A `HoverHighlightView` for the hover fill, but **not an activatable one**:
/// it has no click recognizer, so its buttons stay real, reachable children
/// for VoiceOver and for a real click (an ancestor recognizer is gotcha (20)'s
/// trap, and an activatable `HoverHighlightView` hides its children because it
/// is the button). A click on the row's own surface selects it through
/// `mouseDown`, which AppKit only delivers here when no nested button was hit.
final class NotificationBridgeRowView: HoverHighlightView, NotificationBridgeItemView {
    let entryID: String
    let actions: NotificationBridgeItemActions
    private let entry: AppNotification
    private let timed: Bool
    private let isRead: Bool
    private let isSelected: Bool
    private let timeLabel = NSTextField(labelWithString: "")
    private let tile = IconTileView(size: NotificationBridgeMetrics.tileSide, cornerRadius: 8)
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let dot = NSView()
    private let trailingTime = NSTextField(labelWithString: "")
    private var childrenView: NotificationChildrenView?

    var onSelect: (() -> Void)?
    var onBuildMenu: (() -> NSMenu?)?

    init(entry: AppNotification, timed: Bool, theme: HelmTheme, contentWidth: CGFloat, isRead: Bool,
         isSelected: Bool, isExpanded: Bool, timeText: String) {
        self.entry = entry
        self.entryID = entry.id
        self.timed = timed
        self.isRead = isRead
        self.isSelected = isSelected
        actions = NotificationBridgeItemActions(entry: entry, primaryVariant: .secondary, size: .small,
                                                isExpanded: isExpanded, showsSnooze: false)

        // The text column's width, from quantities the labels do not decide:
        // the panel's content width, the insets, the leading column and the
        // trailing column's own fitting width (gotcha (22)).
        let leadingColumn: CGFloat
        if timed {
            timeLabel.stringValue = timeText
            timeLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(12.5), weight: .bold)
            leadingColumn = max(NotificationBridgeMetrics.timeColumn, ceil(timeLabel.fittingSize.width))
        } else {
            trailingTime.stringValue = timeText
            trailingTime.font = HelmType.caption()
            leadingColumn = NotificationBridgeMetrics.tileSide
        }
        let trailingColumn = NotificationBridgeMetrics.dotSide
            + (timed ? 0 : 6 + ceil(trailingTime.fittingSize.width))
        let textWidth = contentWidth - 2 * NotificationBridgeMetrics.sideInset - leadingColumn
            - 2 * NotificationBridgeMetrics.gutter - trailingColumn
        titleLabel = bridgeWrappingLabel(entry.title, width: textWidth)
        let detail = timed && !entry.source.isEmpty
            ? (entry.subtext.isEmpty ? entry.source : "\(entry.source) \u{00B7} \(entry.subtext)")
            : entry.subtext
        detailLabel = bridgeWrappingLabel(detail, width: textWidth)
        detailLabel.isHidden = detail.isEmpty
        super.init(frame: .zero)
        cornerRadius = 0

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.isHidden = !timed
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tile.isHidden = timed
        tile.configure(symbol: NotificationRowPresentation(for: entry).icon, tint: entry.tint, pointSize: 14)
        trailingTime.translatesAutoresizingMaskIntoConstraints = false
        trailingTime.isHidden = timed
        trailingTime.setContentHuggingPriority(.required, for: .horizontal)
        trailingTime.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = NotificationBridgeMetrics.dotSide / 2
        dot.isHidden = isRead

        let text = NSStackView(views: [titleLabel, detailLabel, actions.row])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.setCustomSpacing(8, after: detailLabel.isHidden ? titleLabel : detailLabel)
        text.translatesAutoresizingMaskIntoConstraints = false
        if isExpanded, !entry.children.isEmpty {
            let children = NotificationChildrenView(entry: entry, theme: theme, leadingInset: 0, trailingInset: 0) { [weak self] id in
                self?.actions.onChildAction?(id)
            }
            childrenView = children
            text.addArrangedSubview(children)
            children.widthAnchor.constraint(equalToConstant: max(40, textWidth)).isActive = true
        }

        let leading: NSView = timed ? timeLabel : tile
        addSubview(leading)
        addSubview(text)
        addSubview(dot)
        addSubview(trailingTime)
        let inset = NotificationBridgeMetrics.sideInset
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            leading.topAnchor.constraint(equalTo: text.topAnchor, constant: timed ? 1 : 0),
            text.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: inset + leadingColumn + NotificationBridgeMetrics.gutter),
            text.widthAnchor.constraint(equalToConstant: max(40, textWidth)),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            dot.widthAnchor.constraint(equalToConstant: NotificationBridgeMetrics.dotSide),
            dot.heightAnchor.constraint(equalToConstant: NotificationBridgeMetrics.dotSide),
            dot.trailingAnchor.constraint(equalTo: timed ? trailingAnchor : trailingTime.leadingAnchor,
                                          constant: timed ? -inset : -6),
            dot.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -4),
            trailingTime.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            trailingTime.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
        if timed {
            timeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor).isActive = true
        }

        setAccessibilityElement(true)
        accessibilityRoleOverride = .group
        accessibilityLabelOverride = Self.spokenLabel(entry: entry, timeText: timeText, isRead: isRead)
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static func spokenLabel(entry: AppNotification, timeText: String, isRead: Bool) -> String {
        [entry.source, entry.title, entry.subtext, timeText, isRead ? "" : "unread"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // The row is a group with reachable children, not a button: see the
    // type's header. `HoverHighlightView` only treats an *activatable* view
    // as an element, so this says so explicitly.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildMenu?() ?? super.menu(for: event)
    }

    func applyTheme(_ theme: HelmTheme) {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(14), weight: isRead ? .medium : .semibold)
        titleLabel.textColor = ink
        detailLabel.font = HelmType.body()
        detailLabel.textColor = entry.isWarning
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
            : HelmTheme.mutedInk(theme)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(12.5), weight: .bold)
        timeLabel.textColor = entry.isWarning
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
            : HelmContrast.legibleTintedText(tintHex: theme.accentHex, over: surface, theme: theme)
        trailingTime.font = HelmType.caption()
        trailingTime.textColor = HelmTheme.mutedInk(theme)
        tile.applyTheme(theme)
        dot.layer?.backgroundColor = accent.cgColor
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        normalColor = isSelected ? accent.withAlphaComponent(0.12) : .clear
        hoverColor = isSelected ? accent.withAlphaComponent(0.16) : line.withAlphaComponent(0.35)
        childrenView?.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugDetail: String { detailLabel.stringValue }
    var debugTimeText: String { timed ? timeLabel.stringValue : trailingTime.stringValue }
    var debugIsTimed: Bool { timed }
    var debugUnreadDotVisible: Bool { !dot.isHidden }
    var debugChildRows: [NotificationChildRowView] { childrenView?.debugChildRows ?? [] }
    /// A click on the row's own surface, through the real `mouseDown` entry
    /// point AppKit calls when no nested button was hit.
    func debugSelectByClick() {
        let point = convert(NSPoint(x: bounds.maxX - 4, y: bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        mouseDown(with: event)
    }
    #endif
}

/// The empty state: a check in the good hue and two sentences.
final class NotificationBridgeEmptyView: NSView, NotificationBridgeThemed {
    private let tile = IconTileView(size: 46, cornerRadius: 14)
    private let titleLabel = NSTextField(labelWithString: "You\u{2019}re all caught up")
    private let bodyLabel = NSTextField(labelWithString: "Nothing needs you right now.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        tile.configure(symbol: "checkmark", tint: .good, pointSize: 20)
        for label in [titleLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
        }
        let stack = NSStackView(views: [tile, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = HelmMetrics.s1
        stack.setCustomSpacing(12, after: tile)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 26, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("You\u{2019}re all caught up. Nothing needs you right now.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme(_ theme: HelmTheme) {
        tile.applyTheme(theme)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(18), weight: .bold)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        bodyLabel.font = HelmType.body()
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    #endif
}
