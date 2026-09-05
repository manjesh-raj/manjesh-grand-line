// Manjesh Grand Line - native macOS app.
//
// The topbar "Recents" button + its dropdown panel
// (`fm/grandline-recents-navigation`). Structurally mirrors
// `NotificationCenterPopover.swift` (transient `NSPopover`, live
// `ThemeManager` observation, a `wantsLayer` root with an explicit theme
// background per AGENTS.md gotcha #8) - the same "small card off a topbar
// icon" idiom this app already uses more than once, not a new UI pattern.
//
// The one structural difference from the notification popover: that one
// reads a global singleton (`GrandLineNotificationCenter.shared`, fed by many
// independent subsystems across the app) directly, with no wiring needed at
// all. `RecentDestinations` is scoped to exactly one shell controller's own
// navigation (`AppShellController.show(_:)`/`revealHostConsole`), so it is
// instance-owned rather than a singleton - matching `HostSessionRegistry`'s
// own choice for the identical reason ("A second writer would be a second
// source of truth again"). `configure(registry:onSelect:)` is the one late-
// binding call `AppShellController` makes, the same "forward, never own"
// shape `KubeSessionAccess`/`onSelectDestination` already establish - the bar
// draws the button and hosts the popover, it never learns what a
// `RecentDestinations` is or what "navigate" means.

import AppKit

/// The Recents button - a plain bordered icon square, the same visible
/// chrome every other icon-square control on this bar shares
/// (`DaylightBarIconButton`).
final class RecentDestinationsButton: DaylightBarIconButton {
    init() {
        super.init(symbol: "clock.arrow.circlepath",
                   tooltip: "Recently Visited",
                   accessibilityLabel: "Recently Visited")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Owns the button, the popover, and the panel content - the bar's
/// counterpart to `NotificationCenterController`/`ConsoleComposerController`/
/// `QuotaUsageController`.
final class RecentDestinationsController: NSObject, NSPopoverDelegate {
    let button = RecentDestinationsButton()

    private let popover = NSPopover()
    private let content = RecentDestinationsPanelViewController()
    private var themeObservation: ThemeObservation?
    private var registryToken: UUID?
    private weak var registry: RecentDestinations?

    override init() {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        button.target = self
        button.action = #selector(buttonClicked)
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
        content.onRequestClose = { [weak self] in self?.popover.performClose(nil) }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    /// Wired once by `AppShellController` - see this file's header for why
    /// this is dependency injection rather than a global singleton read.
    func configure(registry: RecentDestinations, onSelect: @escaping (RecentDestinationKind) -> Void) {
        self.registry = registry
        content.registry = registry
        content.onSelect = onSelect
        registryToken = registry.observe { [weak self] _ in
            self?.content.reload()
        }
    }

    @objc private func buttonClicked() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {}

    #if FM_SELFTESTS
    /// The panel content itself, so a suite can drive the real rows without
    /// having to show a popover (popovers do not reliably render off-screen).
    var debugPanelController: NSViewController { content }
    #endif
}

/// The panel content: a header ("Recents"), one row per entry, and an empty
/// state when nothing has been recorded yet.
final class RecentDestinationsPanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    /// Narrower than the notification panel (360) - a Recents row carries a
    /// short destination name plus a relative time, not wrapping prose.
    static let width: CGFloat = 260

    private let titleLabel = NSTextField(labelWithString: "Recents")
    private let emptyState = HelmEmptyState(symbol: "clock.arrow.circlepath",
                                            body: "Nowhere else visited yet.")
    private let rowsStack = NSStackView()
    private let separator = NSView()

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?
    var onSelect: ((RecentDestinationKind) -> Void)?

    /// Set once by `RecentDestinationsController.configure(registry:onSelect:)`
    /// and read fresh on every `reload()` - matching
    /// `NotificationPanelViewController.reload()` reading `GrandLineNotification
    /// Center.shared` directly rather than being handed a snapshot.
    var registry: RecentDestinations?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        root.wantsLayer = true
        view = root

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        emptyState.heightAnchor.constraint(equalToConstant: 80).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, separator, emptyState, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(10, after: separator)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyState.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            emptyState.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        applyTheme(theme)
        reload()
    }

    /// Rebuilds every row from the registry's current entries - always at
    /// most `RecentDestinations.capacity` (5), so a full rebuild on every
    /// change is simpler than an incremental diff, matching
    /// `NotificationPanelViewController.reload()`'s own reasoning.
    func reload() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let entries = registry?.entries ?? []
        emptyState.isHidden = !entries.isEmpty
        for entry in entries {
            let row = Self.makeRow(for: entry, theme: theme)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onClick = { [weak self] in
                self?.onSelect?(entry.kind)
                self?.onRequestClose?()
            }
            rowsStack.addArrangedSubview(row)
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

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = ink
        separator.layer?.backgroundColor = line.cgColor
        emptyState.applyTheme(theme)
        for case let row as HelmAccentRow in rowsStack.arrangedSubviews {
            row.applyTheme(theme)
        }
    }

    /// One Recents row, built from the app's shared accent row - the same
    /// component the notification panel's own rows use.
    ///
    /// `.belowBody` because this panel (260pt) is even narrower than the
    /// notification one - no room for a chip beside the title.
    static func makeRow(for entry: RecentDestinationEntry, theme: HelmTheme) -> HelmAccentRow {
        let row = HelmAccentRow(chipPlacement: .belowBody)
        row.configure(HelmAccentRow.Content(
            tint: entry.kind.hue.fallbackTint,
            kicker: entry.kind.kicker,
            title: entry.kind.title,
            badgeSymbol: entry.kind.symbol,
            chipText: entry.relativeTimeText()
        ), theme: theme)
        return row
    }

    #if FM_SELFTESTS
    /// The real rendered rows, in display order - lets a suite read exactly
    /// what the popover shows (title/kicker/chip) and drive a real click via
    /// each row's own `onClick`, rather than reaching into the registry
    /// directly.
    func debugRows() -> [HelmAccentRow] {
        rowsStack.arrangedSubviews.compactMap { $0 as? HelmAccentRow }
    }

    var debugEmptyStateIsHidden: Bool { emptyState.isHidden }
    #endif
}
