// Grand Line - native macOS app.
//
// The notifications panel's controller, and the row pieces the panel shares
// (`fm/grandline-notification-center`, captain-approved design:
// `data/grandline-notification-center/design-reference.html`).
//
// **B5 (UI modernization audit §3B): the chrome is a `HelmBarPanel`, not an
// `NSPopover`** - a borderless, radius-16, arrow-less panel anchored under the
// toolbar's notifications button, styled like the ⌘K palette. See
// `HelmBarPanel`'s header for why, and for where the lock gate went.
//
// The panel is N-1's Bridge panel (`NotificationBridgePanel.swift`). P-03 of
// the 2026-11-25 full review removed the floating bar, and with it the bar's
// bell (`NotificationBellButton`) and the classic grouped panel it opened
// (`NotificationPanelViewController` and its row views).
// `docs/history/07-fleet-and-notifications.md` records what each of those
// passes was and why it was replaced. What stays here is what the Bridge
// panel reads: the relative timestamp, the list's document view, the child
// rows and their metrics, and `NotificationRowPresentation`, which still owns
// the per-source icon mapping, derived from each source's stable `id`.

import AppKit

/// Owns the popover, the bell's live badge count, and the panel content -
/// the topbar's counterpart to `ConsoleComposerController`/
/// `QuotaUsageController`.
final class NotificationCenterController: NSObject {
    /// B5: a borderless `HelmBarPanel` rather than a stock `NSPopover` - see
    /// that type's header. It owns the window chrome, the theme, the lock
    /// registration and dismissal; this controller keeps the badge count and
    /// the panel content.
    private let panel: HelmBarPanel
    /// N-1's Bridge panel (`NotificationBridgePanel.swift`). P-03 of the
    /// 2026-11-25 review removed the floating bar and with it the classic
    /// panel its bell opened, so this is the only panel.
    private let bridgeContent: NotificationBridgePanelViewController
    /// What the badge last showed.
    private var lastBadgeCount = 0
    private var themeObservation: ThemeObservation?
    private var storeObservation: NotificationCenterObservation?

    /// The badge count, for the sidebar shell's toolbar button, which draws
    /// it. Fires on every change, and once with the current count when it is
    /// assigned.
    var onBadgeCountChanged: ((Int) -> Void)? {
        didSet { onBadgeCountChanged?(lastBadgeCount) }
    }

    /// The Bridge panel's footer action.
    var onOpenHome: (() -> Void)? {
        didSet { bridgeContent.onOpenHome = onOpenHome }
    }

    override init() {
        bridgeContent = NotificationBridgePanelViewController()
        panel = HelmBarPanel(content: bridgeContent)
        super.init()
        bridgeContent.onSizeChanged = { [weak self] size in
            self?.panel.setContentSize(size)
        }
        bridgeContent.onRequestClose = { [weak self] in
            self?.panel.close()
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.bridgeContent.applyTheme(theme)
        }
        // Fires immediately on registration too, so the badge is correct
        // before the captain ever opens the panel - every source's own
        // initial check (fired on launch/page-visit/poll) lands here the same
        // way.
        storeObservation = GrandLineNotificationCenter.shared.observe { [weak self] in
            guard let self else { return }
            let count = GrandLineNotificationCenter.shared.badgeCount
            self.lastBadgeCount = count
            self.onBadgeCountChanged?(count)
            if self.panel.isShown { self.bridgeContent.reload() }
        }
    }

    /// Open or close the panel under `anchor`, the sidebar shell's toolbar
    /// notifications button.
    func togglePanel(under anchor: NSView) {
        if panel.isShown {
            panel.close()
        } else {
            bridgeContent.reload()
            panel.show(under: anchor)
        }
    }

    #if FM_SELFTESTS
    /// The panel content itself, so a suite can drive the real header action
    /// and the real rows without having to put a real window on screen.
    var debugPanelController: NSViewController { bridgeContent }
    /// The Bridge panel, typed.
    var debugBridgeContent: NotificationBridgePanelViewController { bridgeContent }
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

/// An expanded row's block: its children, each with its own action, and the
/// "clears when..." line under them.
final class NotificationChildrenView: NSView {
    private var rules: [NSView] = []
    private var childRows: [NotificationChildRowView] = []
    private let clears: NSTextField

    /// `leadingInset` defaults to the classic row's text column; the Bridge
    /// panel nests the block inside its own text column and passes 0.
    init(entry: AppNotification, theme: HelmTheme,
         leadingInset: CGFloat = NotificationRowMetrics.textColumn, trailingInset: CGFloat = 14,
         onAction: @escaping (String) -> Void) {
        clears = NSTextField(wrappingLabelWithString: entry.clearCondition)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
                rules.append(rule)
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let view = NotificationChildRowView(child: child, theme: theme)
            let childID = child.id
            view.onAction = { onAction(childID) }
            childRows.append(view)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // The reference's "clears when..." line: the explanation moved out of
        // the row and under the disclosure, which is the whole point of
        // expanding.
        clears.translatesAutoresizingMaskIntoConstraints = false
        clears.isHidden = entry.clearCondition.isEmpty
        stack.addArrangedSubview(clears)
        clears.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme(_ theme: HelmTheme) {
        for rule in rules {
            rule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        }
        for row in childRows { row.applyTheme(theme) }
        clears.font = HelmType.captionSmall()
        clears.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugChildRows: [NotificationChildRowView] { childRows }
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
    /// The button's real frame, for a suite aiming a real click at it.
    var debugActionButtonFrameInRow: NSRect? {
        actionButton.isHidden ? nil : actionButton.convert(actionButton.bounds, to: self)
    }
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
struct NotificationRowPresentation {
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
        case NotificationSources.persistenceFailureID:
            icon = "externaldrive.badge.exclamationmark"
            kicker = "Not Saved"
        case BackupUI.exportReportID:
            // R4-UX-08: a finished backup is a lasting report.
            icon = "externaldrive.badge.checkmark"
            kicker = "Backup Saved"
        default:
            if entry.id.hasPrefix("service-failing.") {
                // One entry per health service, so a prefix like SRE Lead's.
                // It used to fall through to the generic bell.
                icon = "exclamationmark.arrow.triangle.2.circlepath"
                kicker = "Service Failing"
                return
            }
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

